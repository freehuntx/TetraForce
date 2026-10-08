class_name RelayChannel
extends RefCounted
## Public broadcast channel (spec §5). Created via RelayClient.join().

signal joined
signal left(reason: String)
signal message(peer: RelayPeer, data: Variant)
signal peer_joined(peer: RelayPeer)
signal peer_left(peer: RelayPeer)

var channel_name: String
var channel_id: String
var peers: Dictionary = {} # peer_id -> RelayPeer (live members, excl. self)

var _client # RelayClient
var _joined := false
var _closed := false
var _replay := FreelayEnvelope.ReplayGuard.new()
var _member_topic: String
var _msg_topic: String
var _heal_last_ms := 0
## Membership candidates: retained membership seen, but global presence not
## (yet) confirmed online (§5.3). peer_id -> {peer: RelayPeer, since: int}
var _pending: Dictionary = {}


func _init(client, p_name: String) -> void:
	_client = client
	channel_name = p_name
	channel_id = Freelay.derive_channel_id(p_name)
	_msg_topic = Freelay.topic_channel_msg(_client._root, channel_id)
	_member_topic = Freelay.topic_channel_member(_client._root, channel_id, _client.profile.peer_id)


func is_joined() -> bool:
	return _joined and not _closed


## Broadcast to all members (§5.2). `reliable=false` marks the message as
## droppable under outbound rate limiting; reliable traffic uses MQTT QoS 1.
func send(data: Variant, reliable := true) -> void:
	if _closed:
		push_warning("RelayChannel.send on an already-left channel")
		return
	var body := var_to_bytes(data)
	var prio := RelayRateLimit.OutboundQueue.PRIO_RELIABLE if reliable else RelayRateLimit.OutboundQueue.PRIO_UNRELIABLE
	_client._publish_envelope(_msg_topic, Freelay.MSG_CHANNEL_DATA, body, false, prio, "ch:" + channel_id)


func leave() -> void:
	if _closed:
		return
	_closed = true
	if _client.is_open():
		# Signed offline on the membership topic, then a zero-length retained
		# cleanup publish (§5.3).
		var body := FreelayPresenceManager.encode_presence_body(Freelay.PRESENCE_OFFLINE, _client._presence.connection_id)
		_client._publish_envelope(_member_topic, Freelay.MSG_PRESENCE, body, true, RelayRateLimit.OutboundQueue.PRIO_CONTROL)
		_client._publish_raw(_member_topic, PackedByteArray(), true, RelayRateLimit.OutboundQueue.PRIO_CONTROL)
		_client._mqtt.unsubscribe(_msg_topic)
		_client._mqtt.unsubscribe("%s/ch/%s/p/+" % [_client._root, channel_id])
	_client._presence.untrack_own_publish(_member_topic)
	for peer_id in peers.keys():
		_client._presence.unwatch(peer_id)
	for peer_id in _pending.keys():
		_client._presence.unwatch(peer_id)
	peers.clear()
	_pending.clear()
	_client._channels.erase(channel_id)
	left.emit("left")


# ---------------------------------------------------------------------------
# Internal - driven by RelayClient
# ---------------------------------------------------------------------------

func _subscribe_and_announce() -> void:
	_client._mqtt.subscribe(_msg_topic, 1)
	_client._mqtt.subscribe("%s/ch/%s/p/+" % [_client._root, channel_id])
	_announce_membership()


func _announce_membership() -> void:
	var body := FreelayPresenceManager.encode_presence_body(Freelay.PRESENCE_ONLINE, _client._presence.connection_id)
	var raw: PackedByteArray = _client._publish_envelope(_member_topic, Freelay.MSG_PRESENCE, body, true, RelayRateLimit.OutboundQueue.PRIO_CONTROL)
	if not raw.is_empty():
		_client._presence.track_own_publish(_member_topic, raw)


func _on_subscribed(topic: String) -> void:
	if topic == _msg_topic and not _joined:
		_joined = true
		joined.emit()


## Message on the broadcast topic.
func _handle_msg(topic: String, payload: PackedByteArray) -> void:
	var env := FreelayEnvelope.decode_and_verify(topic, payload)
	if env == null or env.msg_type != Freelay.MSG_CHANNEL_DATA:
		return
	if env.sender_pk == _client.profile.public_key:
		return # our own echo
	if not _client._inbound_allow(env):
		return
	if not _replay.check(env, topic):
		return
	var peer: RelayPeer = peers.get(env.sender_peer_id)
	if peer == null:
		# Sender is not a (known) member: still deliver, but as a transient
		# peer object - membership is advisory, signatures are the truth.
		peer = RelayPeer.from_public_key(env.sender_pk)
	if peer.muted:
		return
	peer.last_seen_ms = Freelay.now_ms()
	var data: Variant = bytes_to_var(env.body)
	message.emit(peer, data)


## Message on a membership topic ch/{cid}/p/{peer_id}.
func _handle_member(topic: String, topic_peer_id: String, payload: PackedByteArray) -> void:
	if topic_peer_id == _client.profile.peer_id:
		# Self-healing for our own retained membership (§6.4).
		if _closed:
			return
		var own: PackedByteArray = _client._presence._own_published.get(_member_topic, PackedByteArray())
		if payload != own:
			var now := Freelay.now_ms()
			if now - _heal_last_ms >= int(Freelay.SELF_HEAL_MIN_INTERVAL_S * 1000.0):
				_heal_last_ms = now
				_announce_membership()
		return

	if payload.is_empty():
		return # cleanup hint (§6.4)

	var env := FreelayEnvelope.decode_and_verify(topic, payload)
	if env == null or env.msg_type != Freelay.MSG_PRESENCE:
		return
	if env.sender_peer_id != topic_peer_id:
		return # topic binding (§4.2 rule 3)
	var presence := FreelayPresenceManager.decode_presence_body(env.body)
	if presence.is_empty():
		return

	if presence.status == Freelay.PRESENCE_ONLINE:
		if peers.has(topic_peer_id):
			return
		if not _pending.has(topic_peer_id):
			# Candidate only (§5.3): a retained membership message from a
			# dead instance must not produce a ghost join. Watch the global
			# presence and promote once it confirms the peer is live.
			_pending[topic_peer_id] = {"peer": RelayPeer.from_public_key(env.sender_pk), "since": Freelay.now_ms()}
			_client._presence.watch(topic_peer_id)
		if _client._presence.is_online(topic_peer_id):
			_promote(topic_peer_id)
	else:
		_drop_pending(topic_peer_id)
		_remove_member(topic_peer_id)


func _promote(peer_id: String) -> void:
	var entry: Dictionary = _pending.get(peer_id, {})
	if entry.is_empty() or peers.has(peer_id):
		return
	_pending.erase(peer_id)
	# The presence watch stays: members keep being watched (refcount was
	# taken when the candidate was created).
	peers[peer_id] = entry.peer
	peer_joined.emit(entry.peer)


func _drop_pending(peer_id: String) -> void:
	if _pending.erase(peer_id):
		_client._presence.unwatch(peer_id)


func _remove_member(peer_id: String) -> void:
	var peer: RelayPeer = peers.get(peer_id)
	if peer == null:
		return
	peers.erase(peer_id)
	_client._presence.unwatch(peer_id)
	peer_left.emit(peer)


## Global presence of a candidate/member changed (§5.3 liveness).
func _on_global_online(peer_id: String) -> void:
	_promote(peer_id)


func _on_global_offline(peer_id: String) -> void:
	_drop_pending(peer_id)
	_remove_member(peer_id)


## Expire candidates whose global presence never confirmed within the
## staleness horizon; a live peer re-announces membership on reconnect, so
## expiring is safe and frees the presence subscription.
func _tick(_delta: float) -> void:
	if _pending.is_empty():
		return
	var now := Freelay.now_ms()
	for peer_id in _pending.keys().duplicate():
		if now - int(_pending[peer_id].since) > Freelay.STALE_AFTER_MS:
			_drop_pending(peer_id)


func _on_client_reconnected() -> void:
	# mqtt-node re-subscribes automatically; we must re-announce because the
	# connection_id changed and retained state may have been lost.
	if not _closed:
		_announce_membership()


func _on_client_closed(reason: String) -> void:
	if not _closed:
		_closed = true
		left.emit(reason)
