class_name RelayClient
extends Node
## Freelay client (spec §3): owns the MqttNode (mqtt-node ≥ 0.2.0), the identity
## profile, presence, channels and peer connections.
##
## Usage:
##   var client := RelayClient.new()
##   client.app_id = "my-game"
##   client.broker_urls = ["wss://broker.hivemq.com:8884/mqtt"]
##   add_child(client)
##   client.open()
##   await client.opened

signal opened
signal reconnected
signal closed(reason: String)
signal peer_connection_requested(conn: RelayPeerConnection)
signal outbound_throttled(queued_count: int)

## Application namespace string (§2.2). Must be set before open().
@export var app_id := ""
## Broker fallback list; tried in order on connect failure.
@export var broker_urls: PackedStringArray = PackedStringArray()
## Automatically accept incoming peer connections (spam-unsafe; default off).
@export var auto_accept_peers := false
## Outbound budget so we do not trip broker-side limits (§9). Disabled by default.
@export var outbound_limit := RelayRateLimit.new()
## Inbound per-peer budget (§9). Disabled by default.
@export var inbound_limit_per_peer := RelayRateLimit.new()

## Identity. Assign a loaded RelayProfile before open() to reuse an identity;
## otherwise an ephemeral one is generated.
var profile: RelayProfile

var _mqtt: MqttNode
var _root := ""
var _open := false
var _closing := false
var _ever_connected := false
var _broker_index := 0
var _seq: Dictionary = {} # topic -> next seq (reset per connection, §4.2)
var _channels: Dictionary = {} # channel_id -> RelayChannel
var _connections: Dictionary = {} # session_id_b32 -> RelayPeerConnection
var _presence: FreelayPresenceManager
var _inbox_replay := FreelayEnvelope.ReplayGuard.new()
var _outbound: RelayRateLimit.OutboundQueue
var _inbound: RelayRateLimit.InboundGuard
var _muted: Dictionary = {} # peer_id -> true


func is_open() -> bool:
	return _open


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func open() -> void:
	if _mqtt != null:
		push_warning("RelayClient.open: already opened")
		return
	if app_id.is_empty() or broker_urls.is_empty():
		push_error("RelayClient: app_id and broker_urls must be set before open()")
		return
	if profile == null:
		profile = RelayProfile.generate()
	_root = Freelay.make_root(app_id)
	_presence = FreelayPresenceManager.new(self)
	_presence.peer_online.connect(_on_peer_online)
	_presence.peer_offline.connect(_on_peer_offline)
	_outbound = RelayRateLimit.OutboundQueue.new(outbound_limit)
	_inbound = RelayRateLimit.InboundGuard.new(inbound_limit_per_peer)

	_mqtt = MqttNode.new()
	_mqtt.broker = broker_urls[_broker_index]
	_mqtt.client_id = "" # empty → cryptographically random per connect (§3)
	_presence.prepare_connect(_mqtt)

	_mqtt.connected.connect(_on_mqtt_connected)
	_mqtt.disconnected.connect(_on_mqtt_disconnected)
	_mqtt.connecting_failed.connect(_on_mqtt_connecting_failed)
	_mqtt.reconnecting.connect(_on_mqtt_reconnecting)
	_mqtt.subscribed.connect(_on_mqtt_subscribed)
	_mqtt.message.connect(_on_mqtt_message)

	_mqtt.auto_connect = true
	add_child(_mqtt)


func close() -> void:
	if _mqtt == null or _closing:
		return
	_closing = true
	for sid in _connections.keys().duplicate():
		_connections[sid].close(Freelay.REASON_SHUTTING_DOWN)
	for cid in _channels.keys().duplicate():
		_channels[cid].leave()
	if _open:
		_presence.publish_own_offline()
	_open = false
	_mqtt.auto_reconnect = false
	_mqtt.disconnect_from_broker()
	closed.emit("closed locally")


func _process(delta: float) -> void:
	if _mqtt == null or _closing:
		return
	if _presence != null:
		_presence.tick(delta)
	for sid in _connections.keys().duplicate():
		_connections[sid]._tick(delta)
	for cid in _channels.keys().duplicate():
		_channels[cid]._tick(delta)
	# Outbound budget (§9)
	if outbound_limit.enabled:
		_outbound.tick(delta)
		if _mqtt._is_connected():
			_publish_entries(_outbound.drain())


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Join a public channel (§5). Returns immediately; await channel.joined.
func join(channel_name: String) -> RelayChannel:
	if _mqtt == null:
		push_error("RelayClient.join: call open() first")
		return null

	var cid := Freelay.derive_channel_id(channel_name)
	if _channels.has(cid):
		return _channels[cid]
	var channel := RelayChannel.new(self, channel_name)
	_channels[cid] = channel
	if _open:
		channel._subscribe_and_announce()
	return channel


## Open a private encrypted connection to a peer id (§7).
## Returns immediately; await conn.ready (or conn.closed on failure).
func connect_peer(peer_id: String) -> RelayPeerConnection:
	if not _open:
		push_error("RelayClient.connect_peer: not connected")
		return null
	var conn := RelayPeerConnection.new(self, peer_id)
	conn._start_outgoing()
	_connections[conn._session_id_b32] = conn
	return conn


func mute_peer(peer_id: String) -> void:
	_muted[peer_id] = true


func unmute_peer(peer_id: String) -> void:
	_muted.erase(peer_id)


# ---------------------------------------------------------------------------
# MQTT event handling
# ---------------------------------------------------------------------------

func _on_mqtt_connected(reconnection: bool) -> void:
	_open = true
	_seq.clear() # seq restarts per connection (§4.2)
	_mqtt.subscribe(Freelay.topic_inbox(_root, profile.peer_id), 1)
	_mqtt.subscribe("%s/peer/%s/s/+" % [_root, profile.peer_id], 1)
	_presence.on_connected()
	for cid in _channels:
		var ch: RelayChannel = _channels[cid]
		if not ch._joined:
			ch._subscribe_and_announce() # never (successfully) subscribed
		else:
			ch._on_client_reconnected()

	var is_recon := reconnection or _ever_connected
	if is_recon:
		_presence.resubscribe_all()
		reconnected.emit()
	else:
		_ever_connected = true
		opened.emit()


func _on_mqtt_reconnecting(_attempt: int, _delay: float) -> void:
	_open = false
	# Fresh connection_id + freshly signed Will before the next CONNECT (§6.3).
	_presence.prepare_connect(_mqtt)


func _on_mqtt_connecting_failed() -> void:
	# Rotate through the fallback broker list.
	if broker_urls.size() > 1:
		_broker_index = (_broker_index + 1) % broker_urls.size()
		_mqtt.broker = broker_urls[_broker_index]


func _on_mqtt_disconnected(reason: String) -> void:
	_open = false
	if _closing and _mqtt != null:
		_mqtt.queue_free()
		_mqtt = null
		return
	# mqtt-node auto-reconnects; only surface terminal closes.
	if _mqtt == null:
		closed.emit(reason)


func _on_mqtt_subscribed(topic: String, _qos: int) -> void:
	for cid in _channels:
		_channels[cid]._on_subscribed(topic)


func _on_mqtt_message(topic: String, payload: PackedByteArray, _retained: bool) -> void:
	if _closing:
		return
	if payload.size() > Freelay.MAX_MESSAGE_SIZE:
		return
	if not topic.begins_with(_root + "/"):
		return
	var parts := topic.substr(_root.length() + 1).split("/")
	match parts[0]:
		"presence":
			if parts.size() == 2:
				_presence.handle_message(topic, parts[1], payload)
		"ch":
			if parts.size() < 3:
				return
			var channel: RelayChannel = _channels.get(parts[1])
			if channel == null:
				return
			if parts[2] == "msg" and parts.size() == 3:
				channel._handle_msg(topic, payload)
			elif parts[2] == "p" and parts.size() == 4:
				channel._handle_member(topic, parts[3], payload)
		"peer":
			if parts.size() < 3 or parts[1] != profile.peer_id:
				return
			if parts[2] == "inbox" and parts.size() == 3:
				_handle_inbox(topic, payload)
			elif parts[2] == "s" and parts.size() == 4:
				var conn: RelayPeerConnection = _connections.get(parts[3])
				if conn != null:
					conn._handle_frame(topic, payload)


func _handle_inbox(topic: String, payload: PackedByteArray) -> void:
	var env := FreelayEnvelope.decode_and_verify(topic, payload)
	if env == null:
		return
	if not _inbound_allow(env):
		return
	if not _inbox_replay.check(env, topic):
		return
	match env.msg_type:
		Freelay.MSG_HELLO:
			_handle_hello(env)
		Freelay.MSG_WELCOME:
			var conn := _find_connection_by_session(env.body.slice(0, 16))
			if conn != null:
				conn._handle_welcome(env)
		Freelay.MSG_REJECT:
			if env.body.size() == 17:
				var conn := _find_connection_by_session(env.body.slice(0, 16))
				if conn != null:
					conn._handle_reject(env)


func _handle_hello(env: FreelayEnvelope) -> void:
	if env.body.size() != 49:
		return
	var session_id := env.body.slice(0, 16)
	var existing := _find_connection_by_session(session_id)
	if existing != null:
		existing._handle_hello_retransmit(env)
		return
	var conn := RelayPeerConnection.new(self, env.sender_peer_id)
	conn._start_incoming(env)
	_connections[conn._session_id_b32] = conn
	if auto_accept_peers:
		conn.accept()
	else:
		peer_connection_requested.emit(conn)


func _find_connection_by_session(session_id: PackedByteArray) -> RelayPeerConnection:
	return _connections.get(Freelay.base32(session_id))


func _on_peer_online(peer_id: String, _pk: PackedByteArray) -> void:
	for cid in _channels:
		_channels[cid]._on_global_online(peer_id)


func _on_peer_offline(peer_id: String) -> void:
	for cid in _channels:
		_channels[cid]._on_global_offline(peer_id)
	for sid in _connections.keys().duplicate():
		var conn: RelayPeerConnection = _connections[sid]
		if conn.remote_peer_id == peer_id:
			conn._on_remote_offline()


# ---------------------------------------------------------------------------
# Publishing (all outbound traffic funnels through here)
# ---------------------------------------------------------------------------

## Builds, signs and publishes an envelope. Returns the raw bytes (empty on
## failure) so callers can track retained self-heal state.
func _publish_envelope(topic: String, msg_type: int, body: PackedByteArray, retain: bool, priority: int, stream_key := "") -> PackedByteArray:
	var seq: int = _seq.get(topic, 0) + 1
	_seq[topic] = seq
	var env := FreelayEnvelope.encode(topic, msg_type, profile._seed(), profile.public_key, seq, body)
	if env == null:
		return PackedByteArray()
	_publish_raw(topic, env.raw, retain, priority, stream_key)
	return env.raw


func _publish_raw(topic: String, payload: PackedByteArray, retain: bool, priority: int, stream_key := "") -> bool:
	if _mqtt == null:
		return false
	var qos := 0 if priority == RelayRateLimit.OutboundQueue.PRIO_UNRELIABLE else 1
	if not outbound_limit.enabled:
		return _mqtt.publish(topic, payload, retain, qos)
	_publish_entries(_outbound.push(topic, payload, retain, qos, priority, stream_key))
	var queued := _outbound.queued_count()
	if queued > 0:
		outbound_throttled.emit(queued)
	return true


func _publish_entries(entries: Array) -> void:
	for i in range(entries.size()):
		var entry: Array = entries[i]
		if not _mqtt.publish(entry[0], entry[1], entry[2], entry[3]):
			_outbound.requeue(entries.slice(i))
			return


## Inbound checks shared by all validated envelope paths: mute list + per-peer
## token bucket (§9). Called AFTER signature verification.
func _inbound_allow(env: FreelayEnvelope) -> bool:
	if _muted.has(env.sender_peer_id):
		return false
	return _inbound.allow(env.sender_pk.hex_encode(), env.raw.size())
