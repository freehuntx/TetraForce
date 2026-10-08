class_name RelayRateLimit
extends Resource
## Rate limit configuration (spec §9). Disabled by default.
## 0 means "unlimited" for the individual budgets.

@export var enabled := false
@export var max_publishes_per_sec := 0
@export var max_bytes_per_sec := 0


## Token bucket + 3-class priority queue used by RelayClient for outbound
## traffic. Control is never dropped, but paced, reliable is queued, unreliable keeps
## only the newest message per stream_key.
class OutboundQueue:
	extends RefCounted

	const PRIO_CONTROL := 0
	const PRIO_RELIABLE := 1
	const PRIO_UNRELIABLE := 2

	var config: RelayRateLimit
	var _tokens_pub := 0.0
	var _tokens_bytes := 0.0
	var _control: Array = [] # [topic, payload, retain, qos, priority, stream_key]
	var _reliable: Array = []
	var _unreliable: Dictionary = {} # stream_key -> entry (latest wins)
	var _unreliable_order: Array[String] = []

	func _init(p_config: RelayRateLimit) -> void:
		config = p_config
		_refill_full()

	func _refill_full() -> void:
		_tokens_pub = float(maxi(config.max_publishes_per_sec, 1))
		_tokens_bytes = float(maxi(config.max_bytes_per_sec, 1))

	func tick(delta: float) -> void:
		if config.max_publishes_per_sec > 0:
			_tokens_pub = minf(_tokens_pub + config.max_publishes_per_sec * delta, float(config.max_publishes_per_sec))
		if config.max_bytes_per_sec > 0:
			_tokens_bytes = minf(_tokens_bytes + config.max_bytes_per_sec * delta, float(config.max_bytes_per_sec))

	func _can_afford(size: int) -> bool:
		if config.max_publishes_per_sec > 0 and _tokens_pub < 1.0:
			return false
		if config.max_bytes_per_sec > 0 and _tokens_bytes < float(size):
			return false
		return true

	func _spend(size: int) -> void:
		_tokens_pub -= 1.0
		_tokens_bytes -= float(size)

	func queued_count() -> int:
		return _control.size() + _reliable.size() + _unreliable.size()

	## Enqueue a publish. Returns entries ready to send right now (fast path
	## bypasses the queue entirely when nothing is pending and budget allows).
	func push(topic: String, payload: PackedByteArray, retain: bool, qos: int, priority: int, stream_key := "") -> Array:
		var entry := [topic, payload, retain, qos, priority, stream_key]
		if queued_count() == 0 and _can_afford(payload.size()):
			_spend(payload.size())
			return [entry]
		match priority:
			PRIO_CONTROL:
				_control.append(entry)
			PRIO_RELIABLE:
				_reliable.append(entry)
			_:
				var key := stream_key if not stream_key.is_empty() else topic
				if not _unreliable.has(key):
					_unreliable_order.append(key)
				_unreliable[key] = entry # newest wins, older dropped (§9)
		return []

	## Restore a batch rejected by the transport, preserving reliable order and
	## preferring newer transient updates already queued for the same stream.
	func requeue(entries: Array) -> void:
		for i in range(entries.size() - 1, -1, -1):
			var entry: Array = entries[i]
			match entry[4]:
				PRIO_CONTROL:
					_control.push_front(entry)
				PRIO_RELIABLE:
					_reliable.push_front(entry)
				_:
					var key: String = entry[5] if not entry[5].is_empty() else entry[0]
					if not _unreliable.has(key):
						_unreliable[key] = entry
						_unreliable_order.push_front(key)

	## Dequeue everything affordable this tick, control first.
	func drain() -> Array:
		var out: Array = []
		while not _control.is_empty():
			# Control is never dropped: send even if the byte budget is
			# exhausted (it is tiny and protocol-critical).
			var entry: Array = _control.pop_front()
			_spend(entry[1].size())
			out.append(entry)
			if config.max_publishes_per_sec > 0 and _tokens_pub < 1.0:
				break
		while not _reliable.is_empty() and _can_afford(_reliable[0][1].size()):
			var entry: Array = _reliable.pop_front()
			_spend(entry[1].size())
			out.append(entry)
		while not _unreliable_order.is_empty():
			var key: String = _unreliable_order[0]
			var entry: Array = _unreliable[key]
			if not _can_afford(entry[1].size()):
				break
			_unreliable_order.pop_front()
			_unreliable.erase(key)
			_spend(entry[1].size())
			out.append(entry)
		return out


## Inbound token bucket per verified sender (spec §9).
class InboundGuard:
	extends RefCounted

	var config: RelayRateLimit
	var _buckets: Dictionary = {} # pk_hex -> [tokens_pub, tokens_bytes, last_ms]

	func _init(p_config: RelayRateLimit) -> void:
		config = p_config

	func allow(pk_hex: String, size: int) -> bool:
		if not config.enabled:
			return true
		var now := Freelay.now_ms()
		var bucket: Array = _buckets.get(pk_hex, [float(maxi(config.max_publishes_per_sec, 1)), float(maxi(config.max_bytes_per_sec, 1)), now])
		var delta := float(now - bucket[2]) / 1000.0
		if config.max_publishes_per_sec > 0:
			bucket[0] = minf(bucket[0] + config.max_publishes_per_sec * delta, float(config.max_publishes_per_sec))
		if config.max_bytes_per_sec > 0:
			bucket[1] = minf(bucket[1] + config.max_bytes_per_sec * delta, float(config.max_bytes_per_sec))
		bucket[2] = now
		var ok := true
		if config.max_publishes_per_sec > 0 and bucket[0] < 1.0:
			ok = false
		if config.max_bytes_per_sec > 0 and bucket[1] < float(size):
			ok = false
		if ok:
			bucket[0] -= 1.0
			bucket[1] -= float(size)
		_buckets[pk_hex] = bucket
		return ok
