class_name FreelayPresenceManager
extends RefCounted
## Global presence tracking (spec §6): signed online/offline envelopes,
## heartbeat, staleness, pre-signed Last Will validation and self-healing.
##
## Owned and ticked by RelayClient; publishes go through the client so they
## respect outbound rate limiting.

signal peer_online(peer_id: String, public_key: PackedByteArray)
signal peer_offline(peer_id: String)

var _client # RelayClient (untyped to avoid a cyclic class_name reference)
var _heartbeat_accum := 0.0

## Watched peers, refcounted: peer_id -> int
var _watch_refs: Dictionary = {}
## peer_id -> { pk, online: bool, connection_id, ts }
var _state: Dictionary = {}

## Own state for self-healing: topic -> raw bytes of our last publish
var _own_published: Dictionary = {}
var _own_heal_last_ms: Dictionary = {}
var connection_id := PackedByteArray()


func _init(client) -> void:
	_client = client


static func encode_presence_body(status: int, conn_id: PackedByteArray) -> PackedByteArray:
	var body := PackedByteArray([status])
	body.append_array(conn_id)
	return body


static func decode_presence_body(body: PackedByteArray) -> Dictionary:
	if body.size() != 9:
		return {}
	return {"status": body[0], "connection_id": body.slice(1, 9)}


# ---------------------------------------------------------------------------
# Own presence lifecycle
# ---------------------------------------------------------------------------

## Called by the client right before every (re)connect: fresh connection_id
## and a freshly pre-signed offline Will (§6.3). mqtt-node 0.2.0 reads the
## will_* properties live at CONNECT-build time, so updating them in the
## `reconnecting` signal is race-free.
func prepare_connect(mqtt) -> void:
	connection_id = FreelayCrypto.random_bytes(8)
	var topic: String = Freelay.topic_presence(_client._root, _client.profile.peer_id)
	var body := encode_presence_body(Freelay.PRESENCE_OFFLINE, connection_id)
	var env := FreelayEnvelope.encode(topic, Freelay.MSG_PRESENCE, _client.profile._seed(), _client.profile.public_key, 0, body)
	mqtt.will_topic = topic
	mqtt.will_payload = env.raw
	mqtt.will_retain = true
	mqtt.will_qos = 0


## Called after `connected`: announce ourselves and subscribe to our own
## topic for self-healing (§6.4).
func on_connected() -> void:
	var topic: String = Freelay.topic_presence(_client._root, _client.profile.peer_id)
	_client._mqtt.subscribe(topic)
	publish_own_presence()
	_heartbeat_accum = 0.0


func publish_own_presence() -> void:
	var topic: String = Freelay.topic_presence(_client._root, _client.profile.peer_id)
	var body := encode_presence_body(Freelay.PRESENCE_ONLINE, connection_id)
	var raw: PackedByteArray = _client._publish_envelope(topic, Freelay.MSG_PRESENCE, body, true, RelayRateLimit.OutboundQueue.PRIO_CONTROL)
	if not raw.is_empty():
		_own_published[topic] = raw


## Track a raw publish we made to a retained topic we own (channel
## membership uses this too), so self-healing can compare against it.
func track_own_publish(topic: String, raw: PackedByteArray) -> void:
	_own_published[topic] = raw


func untrack_own_publish(topic: String) -> void:
	_own_published.erase(topic)


## Publish the signed offline for clean disconnects (§6.3).
func publish_own_offline() -> void:
	var topic: String = Freelay.topic_presence(_client._root, _client.profile.peer_id)
	var body := encode_presence_body(Freelay.PRESENCE_OFFLINE, connection_id)
	_client._publish_envelope(topic, Freelay.MSG_PRESENCE, body, true, RelayRateLimit.OutboundQueue.PRIO_CONTROL)
	_own_published.erase(topic)


func tick(delta: float) -> void:
	_heartbeat_accum += delta
	if _heartbeat_accum >= Freelay.HEARTBEAT_INTERVAL_S:
		_heartbeat_accum = 0.0
		if _client.is_open():
			publish_own_presence()
	# staleness sweep (§6.2)
	var now := Freelay.now_ms()
	for peer_id in _state.keys():
		var st: Dictionary = _state[peer_id]
		if st.online and now - st.ts > Freelay.STALE_AFTER_MS:
			st.online = false
			peer_offline.emit(peer_id)


# ---------------------------------------------------------------------------
# Watching remote peers
# ---------------------------------------------------------------------------

func watch(peer_id: String) -> void:
	var refs: int = _watch_refs.get(peer_id, 0)
	_watch_refs[peer_id] = refs + 1
	if refs == 0:
		_client._mqtt.subscribe(Freelay.topic_presence(_client._root, peer_id))


func unwatch(peer_id: String) -> void:
	var refs: int = _watch_refs.get(peer_id, 0) - 1
	if refs <= 0:
		_watch_refs.erase(peer_id)
		_state.erase(peer_id)
		if _client.is_open():
			_client._mqtt.unsubscribe(Freelay.topic_presence(_client._root, peer_id))
	else:
		_watch_refs[peer_id] = refs


func is_online(peer_id: String) -> bool:
	var st: Dictionary = _state.get(peer_id, {})
	return not st.is_empty() and st.online


func resubscribe_all() -> void:
	for peer_id in _watch_refs.keys():
		_client._mqtt.subscribe(Freelay.topic_presence(_client._root, peer_id))


# ---------------------------------------------------------------------------
# Incoming presence handling
# ---------------------------------------------------------------------------

## Handles a message on any `presence/{peer_id}` topic.
func handle_message(topic: String, topic_peer_id: String, payload: PackedByteArray) -> void:
	# Self-healing (§6.4): anything on our own topic that is not our own
	# current publish gets overwritten (rate-limited).
	if topic_peer_id == _client.profile.peer_id:
		var own: PackedByteArray = _own_published.get(topic, PackedByteArray())
		if payload != own:
			var now := Freelay.now_ms()
			if now - int(_own_heal_last_ms.get(topic, 0)) >= int(Freelay.SELF_HEAL_MIN_INTERVAL_S * 1000.0):
				_own_heal_last_ms[topic] = now
				publish_own_presence()
		return

	if payload.is_empty():
		return # cleanup hint only, never an authenticated state change (§6.4)

	var env := FreelayEnvelope.decode_and_verify(topic, payload)
	if env == null or env.msg_type != Freelay.MSG_PRESENCE:
		return
	# Topic binding (§4.2 rule 3): sender must own the topic's peer id.
	if env.sender_peer_id != topic_peer_id:
		return
	var presence := decode_presence_body(env.body)
	if presence.is_empty():
		return

	var st: Dictionary = _state.get(topic_peer_id, { "pk": env.sender_pk, "online": false, "connection_id": PackedByteArray(), "ts": 0, "seq": -1 })

	if presence.status == Freelay.PRESENCE_ONLINE:
		# Monotonicity (§4.2 rule 5) - freshness replaced by staleness (§6.2).
		if env.timestamp < st.ts or (env.timestamp == st.ts and env.seq <= st.seq):
			return
		# A retained online from a dead peer (lost LWT, broker kept the
		# retained message) must not count as online: check staleness on
		# arrival, not just in the periodic sweep.
		var fresh := Freelay.now_ms() - env.timestamp <= Freelay.STALE_AFTER_MS
		var was_online: bool = st.online
		st.pk = env.sender_pk
		st.online = fresh
		st.connection_id = presence.connection_id
		st.ts = env.timestamp
		st.seq = env.seq
		_state[topic_peer_id] = st
		if fresh and not was_online:
			peer_online.emit(topic_peer_id, env.sender_pk)
		elif not fresh and was_online:
			peer_offline.emit(topic_peer_id)
	else:
		# Offline (§6.3): valid regardless of age iff connection_id matches
		# the current online session (or the peer was never seen online).
		if st.online and presence.connection_id != st.connection_id:
			return # stale/replayed offline for an older connection
		st.pk = env.sender_pk
		st.online = false
		st.ts = env.timestamp
		_state[topic_peer_id] = st
		# Always emit (idempotent for consumers): channels also use this to
		# drop pending membership candidates of peers that were never online.
		peer_offline.emit(topic_peer_id)
