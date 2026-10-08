class_name RelayPeerConnection
extends RefCounted
## Private 1:1 connection (spec §7 + §8): Noise-style handshake over the
## relay, XChaCha20-Poly1305 frames, optional WebRTC upgrade with the
## encrypted session as authenticated signaling channel.

signal ready
signal message(data: Variant)
signal transport_changed(kind: String) # "relay" | "rtc"
signal closed(reason: String)

enum State {NEW, HELLO_SENT, PENDING_ACCEPT, WELCOME_SENT, READY, CLOSED}

const TRANSPORT_RELAY := "relay"
const TRANSPORT_RTC := "rtc"
const RTC_MAX_PAYLOAD := 16000 # Portable SCTP message size; larger messages stay on MQTT.
const RTC_LEAVE_GRACE_SECONDS := 2.0

var peer: RelayPeer # remote peer; public_key empty until learned
var remote_peer_id: String
var is_initiator := false
var state: int = State.NEW
var transport: String = TRANSPORT_RELAY
var rtc_enabled := true
var rtc_ice_servers: Array = [{"urls": ["stun:stun.l.google.com:19302"]}]
## Monotonic receive time; only authenticated relay/DTLS traffic updates it.
var last_received_msec := 0

var _client # RelayClient
var _session_id: PackedByteArray
var _session_id_b32: String
var _eph: X25519Keypair
var _remote_eph_pub: PackedByteArray
var _key_send: PackedByteArray
var _key_recv: PackedByteArray
var _send_counter := 0
var _recv_high := 0
var _recv_mask := 0
var _hello_retries_left := Freelay.HELLO_RETRIES
var _retry_accum := 0.0
var _handshake_age := 0.0
var _welcome_raw := PackedByteArray() # cached for HELLO retransmits (§7.2)

# WebRTC
var _rtc: Object = null # WebRTCPeerConnection
var _rtc_ch_r: Object = null
var _rtc_ch_u: Object = null
var _rtc_is_offerer := false


func _init(client, p_remote_peer_id: String) -> void:
	_client = client
	remote_peer_id = p_remote_peer_id
	peer = RelayPeer.new()
	peer.peer_id = p_remote_peer_id


func session_topic_out() -> String:
	return Freelay.topic_session(_client._root, remote_peer_id, _session_id_b32)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func send(data: Variant, reliable := true) -> bool:
	if state != State.READY:
		push_warning("RelayPeerConnection.send before ready")
		return false
	var payload := var_to_bytes(data)
	# Observe queued close events before attempting a native SCTP send.
	if _rtc != null:
		_rtc_poll()
	if state != State.READY:
		return false
	if transport == TRANSPORT_RTC and _rtc != null and _rtc.get_connection_state() == 2:
		var ch: Object = _rtc_ch_r if reliable else _rtc_ch_u
		if ch != null and ch.get_ready_state() == 1 and payload.size() <= RTC_MAX_PAYLOAD:
			if ch.put_packet(payload) == OK: # DTLS already encrypts (§8.2)
				return true
			# A concurrent remote close can race the ready-state check. Stop using
			# this channel after the first failure instead of retrying every tick.
			_rtc_teardown()
		# fall through to relay when the channel is not usable
	return _send_relay_payload(payload, reliable)


## Control acknowledgements must survive a direct-transport transition.
func send_relay(data: Variant) -> bool:
	if state == State.READY and _client.is_open():
		return _send_relay_payload(var_to_bytes(data), true)
	return false


func _send_relay_payload(payload: PackedByteArray, reliable: bool) -> bool:
	var ftype := Freelay.FRAME_DATA if reliable else Freelay.FRAME_DATA_UNRELIABLE
	var prio := RelayRateLimit.OutboundQueue.PRIO_RELIABLE if reliable else RelayRateLimit.OutboundQueue.PRIO_UNRELIABLE
	return _send_frame(ftype, payload, prio)


## Accept an incoming connection (only meaningful in PENDING_ACCEPT).
func accept() -> void:
	if state != State.PENDING_ACCEPT:
		return
	_eph = FreelayCrypto.x25519_generate()
	var body := _session_id + FreelayCrypto.x25519_public(_eph) + PackedByteArray([0])
	var topic: String = Freelay.topic_inbox(_client._root, remote_peer_id)
	var raw: PackedByteArray = _client._publish_envelope(topic, Freelay.MSG_WELCOME, body, false, RelayRateLimit.OutboundQueue.PRIO_CONTROL)
	_welcome_raw = raw
	var keys := FreelayCrypto.derive_session_keys(
		FreelayCrypto.x25519_private(_eph), _remote_eph_pub,
		peer.public_key, _client.profile.public_key, # initiator pk, responder pk
		_session_id, false)
	if keys.is_empty():
		_close_internal("key derivation failed")
		return
	_key_send = keys.send
	_key_recv = keys.recv
	state = State.WELCOME_SENT
	_handshake_age = 0.0


func reject(reason := Freelay.REASON_DECLINED) -> void:
	if state != State.PENDING_ACCEPT:
		return
	var body := _session_id + PackedByteArray([reason])
	var topic: String = Freelay.topic_inbox(_client._root, remote_peer_id)
	_client._publish_envelope(topic, Freelay.MSG_REJECT, body, false, RelayRateLimit.OutboundQueue.PRIO_CONTROL)
	_close_internal("rejected locally")


func close(reason := Freelay.REASON_UNSPECIFIED) -> void:
	if state == State.CLOSED:
		return
	var graceful = state == State.READY and _client.is_open()
	if graceful:
		_send_frame(Freelay.FRAME_FIN, PackedByteArray([reason]), RelayRateLimit.OutboundQueue.PRIO_CONTROL)
	_close_internal("closed locally", graceful)


## Try to upgrade to a direct WebRTC connection (§8).
## ice_servers example: [{"urls": ["stun:stun.l.google.com:19302"]}]
func upgrade_to_rtc(ice_servers: Array = [ {"urls": ["stun:stun.l.google.com:19302"]}]) -> void:
	if state != State.READY:
		push_warning("upgrade_to_rtc before ready")
		return
	if not rtc_enabled or not _rtc_available():
		return
	if _rtc != null:
		return
	_rtc_is_offerer = true
	if not _rtc_setup(ice_servers):
		return
	_rtc_ch_r = _rtc.create_data_channel("fl-r", {"ordered": true})
	_rtc_ch_u = _rtc.create_data_channel("fl-u", {"ordered": false, "maxRetransmits": 0})
	if _rtc_ch_r == null or _rtc_ch_u == null or _rtc.create_offer() != OK:
		_rtc_teardown()


# ---------------------------------------------------------------------------
# Handshake - outgoing side
# ---------------------------------------------------------------------------

func _start_outgoing() -> void:
	is_initiator = true
	_session_id = FreelayCrypto.random_bytes(16)
	_session_id_b32 = Freelay.base32(_session_id)
	_eph = FreelayCrypto.x25519_generate()
	state = State.HELLO_SENT
	_send_hello()


func _send_hello() -> void:
	var body := _session_id + FreelayCrypto.x25519_public(_eph) + PackedByteArray([0])
	var topic: String = Freelay.topic_inbox(_client._root, remote_peer_id)
	_client._publish_envelope(topic, Freelay.MSG_HELLO, body, false, RelayRateLimit.OutboundQueue.PRIO_CONTROL)


func _handle_welcome(env: FreelayEnvelope) -> void:
	if state != State.HELLO_SENT:
		return
	if env.body.size() != 49:
		return
	if env.body.slice(0, 16) != _session_id:
		return
	# §2.1: the responder's pk must hash to the peer_id we dialed.
	if env.sender_peer_id != remote_peer_id:
		return
	_remote_eph_pub = env.body.slice(16, 48)
	peer.public_key = env.sender_pk
	peer.last_seen_ms = Freelay.now_ms()
	var keys := FreelayCrypto.derive_session_keys(
		FreelayCrypto.x25519_private(_eph), _remote_eph_pub,
		_client.profile.public_key, env.sender_pk, # initiator pk, responder pk
		_session_id, true)
	if keys.is_empty():
		_close_internal("key derivation failed")
		return
	_key_send = keys.send
	_key_recv = keys.recv
	_eph = null # ephemeral no longer needed (§7.2)
	state = State.READY
	_send_frame(Freelay.FRAME_CONFIRM, PackedByteArray(), RelayRateLimit.OutboundQueue.PRIO_CONTROL)
	ready.emit()


func _handle_reject(env: FreelayEnvelope) -> void:
	if state != State.HELLO_SENT or env.body.size() != 17:
		return
	if env.body.slice(0, 16) != _session_id:
		return
	if env.sender_peer_id != remote_peer_id:
		return
	_close_internal("rejected by peer (reason %d)" % env.body[16])


# ---------------------------------------------------------------------------
# Handshake - incoming side (constructed by RelayClient on HELLO)
# ---------------------------------------------------------------------------

func _start_incoming(env: FreelayEnvelope) -> void:
	is_initiator = false
	_session_id = env.body.slice(0, 16)
	_session_id_b32 = Freelay.base32(_session_id)
	_remote_eph_pub = env.body.slice(16, 48)
	peer.public_key = env.sender_pk
	peer.peer_id = env.sender_peer_id
	remote_peer_id = env.sender_peer_id
	state = State.PENDING_ACCEPT


## Retransmitted HELLO for a known session (§7.2): resend cached WELCOME.
func _handle_hello_retransmit(env: FreelayEnvelope) -> void:
	if env.body.slice(16, 48) != _remote_eph_pub:
		return # different ephemeral for the same session id: ignore
	if state == State.WELCOME_SENT and not _welcome_raw.is_empty():
		var topic: String = Freelay.topic_inbox(_client._root, remote_peer_id)
		_client._publish_raw(topic, _welcome_raw, false, RelayRateLimit.OutboundQueue.PRIO_CONTROL)


# ---------------------------------------------------------------------------
# Session frames (§7.4)
# ---------------------------------------------------------------------------

func _send_frame(frame_type: int, plaintext: PackedByteArray, prio: int) -> bool:
	_send_counter += 1
	var header := StreamPeerBuffer.new()
	header.big_endian = true
	header.put_u8(Freelay.FRAME_VERSION)
	header.put_u8(frame_type)
	header.put_u64(_send_counter)
	var head := header.data_array
	var topic := session_topic_out()
	var ad := "FLAEAD".to_utf8_buffer() + topic.to_utf8_buffer() + head
	var ct := FreelayCrypto.aead_encrypt(plaintext, _key_send, FreelayCrypto.frame_nonce(_send_counter), ad)
	var stream_key := "s:%s:%d" % [_session_id_b32, frame_type]
	return _client._publish_raw(topic, head + ct, false, prio, stream_key)


## Called by RelayClient for messages on our own session topic.
func _handle_frame(topic: String, data: PackedByteArray) -> void:
	if state != State.READY and state != State.WELCOME_SENT:
		return
	if data.size() < 10 + 16 or data.size() > Freelay.MAX_MESSAGE_SIZE:
		return
	if data[0] != Freelay.FRAME_VERSION:
		return
	var frame_type := data[1]
	var buf := StreamPeerBuffer.new()
	buf.big_endian = true
	buf.data_array = data
	buf.seek(2)
	var counter := buf.get_u64()
	var head := data.slice(0, 10)
	var ct := data.slice(10)
	var ad := "FLAEAD".to_utf8_buffer() + topic.to_utf8_buffer() + head
	var pt = FreelayCrypto.aead_decrypt(ct, _key_recv, FreelayCrypto.frame_nonce(counter), ad)
	if pt == null:
		return # bad tag
	if not _replay_accept(counter):
		return
	last_received_msec = Time.get_ticks_msec()

	# Responder becomes READY on the first valid frame (§7.2).
	if state == State.WELCOME_SENT:
		state = State.READY
		_welcome_raw = PackedByteArray()
		_eph = null
		ready.emit()

	match frame_type:
		Freelay.FRAME_CONFIRM:
			pass
		Freelay.FRAME_DATA, Freelay.FRAME_DATA_UNRELIABLE:
			message.emit(bytes_to_var(pt))
		Freelay.FRAME_FIN:
			var reason := int(pt[0]) if pt.size() >= 1 else Freelay.REASON_UNSPECIFIED
			_close_internal("closed by peer (reason %d)" % reason)
		Freelay.FRAME_RTC_OFFER:
			_handle_rtc_offer(pt)
		Freelay.FRAME_RTC_ANSWER:
			_handle_rtc_answer(pt)
		Freelay.FRAME_RTC_ICE:
			_handle_rtc_ice(pt)
		_:
			pass # unknown frame types are ignored (§10.2)


## Sliding-window anti-replay (§7.4): highest counter + 64-bit bitmap.
func _replay_accept(counter: int) -> bool:
	if counter <= 0:
		return false
	if counter > _recv_high:
		var shift := counter - _recv_high
		_recv_mask = 1 if shift >= Freelay.REPLAY_WINDOW else ((_recv_mask << shift) | 1)
		_recv_high = counter
		return true
	var offset := _recv_high - counter
	if offset >= Freelay.REPLAY_WINDOW:
		return false
	var bit := 1 << offset
	if _recv_mask & bit:
		return false # duplicate
	_recv_mask |= bit
	return true


# ---------------------------------------------------------------------------
# WebRTC (§8)
# ---------------------------------------------------------------------------

static func _rtc_available() -> bool:
	# The base class exists even when its desktop implementation is absent.
	return OS.has_feature("web") or ClassDB.class_exists("WebRTCLibPeerConnection")


func _rtc_setup(ice_servers: Array) -> bool:
	_rtc = ClassDB.instantiate("WebRTCPeerConnection")
	if _rtc == null or _rtc.initialize({"iceServers": ice_servers}) != OK:
		_rtc_teardown()
		return false
	_rtc.session_description_created.connect(_on_rtc_session_created)
	_rtc.ice_candidate_created.connect(_on_rtc_ice_created)
	_rtc.data_channel_received.connect(_on_rtc_channel_received)
	return true


func _on_rtc_session_created(type: String, sdp: String) -> void:
	if _rtc == null or state != State.READY:
		return
	_rtc.set_local_description(type, sdp)
	var frame_type := Freelay.FRAME_RTC_OFFER if type == "offer" else Freelay.FRAME_RTC_ANSWER
	var json := JSON.stringify({"sdp": sdp}).to_utf8_buffer()
	_send_frame(frame_type, json, RelayRateLimit.OutboundQueue.PRIO_CONTROL)


func _on_rtc_ice_created(mid: String, index: int, sdp: String) -> void:
	if _rtc == null or state != State.READY:
		return
	var json := JSON.stringify({"candidate": sdp, "mid": mid, "index": index}).to_utf8_buffer()
	_send_frame(Freelay.FRAME_RTC_ICE, json, RelayRateLimit.OutboundQueue.PRIO_CONTROL)


func _on_rtc_channel_received(channel: Object) -> void:
	if _rtc == null or state != State.READY:
		channel.close()
		return
	match channel.get_label():
		"fl-r":
			_rtc_ch_r = channel
		"fl-u":
			_rtc_ch_u = channel
		_:
			channel.close()


func _handle_rtc_offer(pt: PackedByteArray) -> void:
	var parsed = JSON.parse_string(pt.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("sdp"):
		return
	if not rtc_enabled or not _rtc_available():
		return
	# Glare resolution (§8.1): smaller raw peer-id digest wins as offerer.
	if _rtc != null and _rtc_is_offerer:
		var own: PackedByteArray = _client.profile.peer_id_digest
		var theirs := Freelay.peer_id_digest(peer.public_key)
		if _digest_less(own, theirs):
			return # our offer wins; ignore theirs, they will answer ours
		_rtc_teardown() # their offer wins; discard our attempt and answer
	if _rtc == null:
		_rtc_is_offerer = false
		if not _rtc_setup(rtc_ice_servers):
			return
	_rtc.set_remote_description("offer", _supported_sdp(parsed.sdp))


func _handle_rtc_answer(pt: PackedByteArray) -> void:
	if _rtc == null:
		return
	var parsed = JSON.parse_string(pt.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("sdp"):
		return
	_rtc.set_remote_description("answer", _supported_sdp(parsed.sdp))


func _handle_rtc_ice(pt: PackedByteArray) -> void:
	if _rtc == null:
		return
	var parsed = JSON.parse_string(pt.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var cand: String = parsed.get("candidate", "")
	if cand.is_empty():
		return # end-of-candidates marker (§8.1)
	if _native_ignores_tcp() and _is_tcp_candidate(cand):
		return # libjuice cannot use browser ICE-TCP candidates; retain the UDP ones.
	_rtc.add_ice_candidate(parsed.get("mid", ""), int(parsed.get("index", 0)), cand)


func _native_ignores_tcp() -> bool:
	return _rtc != null and _rtc.is_class("WebRTCLibPeerConnection")


static func _is_tcp_candidate(candidate: String) -> bool:
	var parts := candidate.strip_edges().trim_prefix("a=").split(" ", false)
	return parts.size() >= 3 and parts[0].begins_with("candidate:") and parts[2].to_lower() == "tcp"


func _supported_sdp(sdp: String) -> String:
	if not _native_ignores_tcp():
		return sdp
	var lines := PackedStringArray()
	for line in sdp.split("\n"):
		if not _is_tcp_candidate(line):
			lines.append(line)
	return "\n".join(lines)


static func _digest_less(a: PackedByteArray, b: PackedByteArray) -> bool:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return a[i] < b[i]
	return a.size() < b.size()


func _rtc_poll() -> void:
	if _rtc == null:
		return
	var rtc = _rtc
	rtc.poll()
	if _rtc != rtc or state != State.READY:
		return
	for ch in [_rtc_ch_r, _rtc_ch_u]:
		if ch == null or ch.get_ready_state() != 1:
			continue
		while _rtc == rtc and state == State.READY and ch.get_ready_state() == 1 and ch.get_available_packet_count() > 0:
			last_received_msec = Time.get_ticks_msec()
			message.emit(bytes_to_var(ch.get_packet()))
	if _rtc != rtc or state != State.READY:
		return # A message callback can close or replace this connection.
	var channels_open: bool = _rtc != null and _rtc.get_connection_state() == 2 and _rtc_ch_r != null and _rtc_ch_r.get_ready_state() == 1 and _rtc_ch_u != null and _rtc_ch_u.get_ready_state() == 1
	if channels_open and transport != TRANSPORT_RTC:
		transport = TRANSPORT_RTC
		transport_changed.emit(transport)
	elif not channels_open and transport == TRANSPORT_RTC:
		# Connection degraded: fall back to relay (§8.3).
		transport = TRANSPORT_RELAY
		transport_changed.emit(transport)
	if _rtc != null and _rtc.get_connection_state() >= 4: # FAILED / CLOSED
		_rtc_teardown()


func _rtc_teardown(graceful := false) -> void:
	var rtc = _rtc
	var channels = [_rtc_ch_r, _rtc_ch_u]
	_rtc = null
	_rtc_ch_r = null
	_rtc_ch_u = null
	_rtc_is_offerer = false
	if transport != TRANSPORT_RELAY:
		transport = TRANSPORT_RELAY
		transport_changed.emit(transport)
	if rtc == null:
		return
	if rtc.session_description_created.is_connected(_on_rtc_session_created):
		rtc.session_description_created.disconnect(_on_rtc_session_created)
	if rtc.ice_candidate_created.is_connected(_on_rtc_ice_created):
		rtc.ice_candidate_created.disconnect(_on_rtc_ice_created)
	if rtc.data_channel_received.is_connected(_on_rtc_channel_received):
		rtc.data_channel_received.disconnect(_on_rtc_channel_received)
	if graceful and is_instance_valid(_client) and _client.is_inside_tree():
		# FIN travels via MQTT. Keep DTLS/SCTP alive long enough for the remote
		# game to process that leave before its next send sees a broken pipe.
		var tree = _client.get_tree()
		# WebRTCDataChannelJS receives packets even after our logical session
		# closes. Drain/discard them during the FIN grace period instead of
		# retaining unpolled channels that overflow the browser's ring buffer.
		var drain = func():
			for channel in channels:
				if channel != null and channel.get_ready_state() == 1:
					while channel.get_available_packet_count() > 0:
						channel.get_packet()
		tree.process_frame.connect(drain)
		tree.create_timer(RTC_LEAVE_GRACE_SECONDS).timeout.connect(func():
			tree.process_frame.disconnect(drain)
			_close_rtc_resources(rtc, channels)
		)
	else:
		_close_rtc_resources(rtc, channels)

func _close_rtc_resources(rtc: Object, channels: Array):
	# Closing the peer connection alone does not detach JS onmessage handlers.
	for channel in channels:
		if channel != null:
			channel.close()
	rtc.close()
	channels.clear()


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _tick(delta: float) -> void:
	match state:
		State.HELLO_SENT:
			_handshake_age += delta
			_retry_accum += delta
			if _retry_accum >= Freelay.HELLO_RETRY_INTERVAL_S and _hello_retries_left > 0:
				_retry_accum = 0.0
				_hello_retries_left -= 1
				_send_hello()
			if _handshake_age >= Freelay.HANDSHAKE_TIMEOUT_S:
				_close_internal("handshake timeout")
		State.WELCOME_SENT:
			_handshake_age += delta
			if _handshake_age >= Freelay.HANDSHAKE_TIMEOUT_S:
				_close_internal("handshake timeout")
		State.READY:
			_rtc_poll()


func _on_remote_offline() -> void:
	if state == State.READY and transport == TRANSPORT_RELAY:
		_close_internal("peer went offline")


func _close_internal(reason: String, graceful := false) -> void:
	if state == State.CLOSED:
		return
	state = State.CLOSED
	_rtc_teardown(graceful)
	_key_send = PackedByteArray() # erase keys (§7.4 FIN semantics)
	_key_recv = PackedByteArray()
	_eph = null
	_client._connections.erase(_session_id_b32)
	closed.emit(reason)
