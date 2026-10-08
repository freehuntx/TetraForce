class_name FreelayMultiplayerPeer
extends MultiplayerPeerExtension
## Godot's scene/RPC protocol transported over encrypted Freelay sessions.
## SceneMultiplayer handles client-to-client relaying through peer 1.

signal admitted
signal connection_lost(reason: String)
signal rejected(reason: String)
signal control_message(id: int, data: Dictionary)

const MAX_PACKET_SIZE = 60000
const PROTOCOL_VERSION = 4
const RELIABLE_RETRY_MS = 500
const RELIABLE_WINDOW = 4096
# SceneMultiplayer's relay wire header (scene_multiplayer.h).
const SCENE_COMMAND_MASK = 7
const SCENE_COMMAND_SYSTEM = 7
const SCENE_SYSTEM_DEL_PEER = 2
const SCENE_SYSTEM_RELAY = 3
const SCENE_SYSTEM_HEADER_SIZE = 6
var connections: Dictionary = {}
var identities: Dictionary = {}
var max_players = 16
var game_version = ""
var lobby_name = ""
var _server = false
var _id = 1
var _next_id = 2
var _status = MultiplayerPeer.CONNECTION_CONNECTING
var _target = 0
var _mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _channel = 0
var _refuse = false
var _packets: Array = []
var _events: Array = []
var _pending: Array = []
var _departed_relay_peers: Dictionary = {}
var _send_sequences: Dictionary = {}
var _receive_sequences: Dictionary = {}
var _reliable_pending: Dictionary = {}
var _reliable_received: Dictionary = {}
var _acks_due: Dictionary = {}
var session_id = ""
var host_epoch = 0
var reserved_ids: Dictionary = {}
var suspended = false

func is_host() -> bool:
	return _server

func configure_host(version: String, lobby: String, capacity: int):
	_server = true
	_status = MultiplayerPeer.CONNECTION_CONNECTED
	game_version = version
	lobby_name = lobby
	max_players = capacity

func configure_client(conn: RelayPeerConnection, version: String, lobby: String):
	_configure_rtc(conn)
	game_version = version
	lobby_name = lobby
	connections[1] = conn
	identities[1] = conn.remote_peer_id
	conn.message.connect(_client_message)
	conn.closed.connect(_host_closed)
	conn.ready.connect(_send_join)

func _send_join():
	connections[1].send({"kind": "join", "version": game_version, "lobby": lobby_name, "protocol": PROTOCOL_VERSION, "session": session_id, "epoch": host_epoch})

func send_control(data: Dictionary, id = 0):
	for remote in connections:
		if (id == 0 or remote == id) and connections[remote].state == RelayPeerConnection.State.READY:
			connections[remote].send_relay({"kind": "control", "data": data})

func accept_connection(conn: RelayPeerConnection):
	var duplicate_peer = identities.values().has(conn.remote_peer_id)
	for pending in _pending:
		duplicate_peer = duplicate_peer or pending.remote_peer_id == conn.remote_peer_id
	if !_server or _refuse or duplicate_peer or connections.size() + _pending.size() >= max_players - 1:
		conn.reject()
		return
	_pending.append(conn)
	_configure_rtc(conn)
	conn.peer.meta["join_started"] = Time.get_ticks_msec()
	conn.message.connect(_incoming_message.bind(conn.remote_peer_id))
	conn.closed.connect(_client_closed.bind(conn.remote_peer_id))
	conn.accept()

func _configure_rtc(conn: RelayPeerConnection):
	conn.rtc_enabled = ProjectSettings.get_setting("freelay/webrtc_enabled", true)
	conn.rtc_ice_servers = ProjectSettings.get_setting("freelay/ice_servers", [{"urls": ["stun:stun.l.google.com:19302"]}])

func _incoming_message(data: Variant, remote_id: String):
	if !(data is Dictionary):
		return
	var id = identities.find_key(remote_id)
	var conn: RelayPeerConnection = connections.get(id)
	for pending in _pending:
		if pending.remote_peer_id == remote_id:
			conn = pending
			break
	if conn == null:
		return
	if conn in _pending:
		if data.get("kind") != "join":
			return
		if data.get("protocol") != PROTOCOL_VERSION:
			conn.send({"kind": "reject", "reason": "Different multiplayer build. Update/reload both desktop and browser versions."})
			conn.close()
			return
		if data.get("version") != game_version or data.get("lobby") != lobby_name:
			conn.send({"kind": "reject", "reason": "Lobby or game version does not match."})
			conn.close()
			return
		if data.get("session", "") != "" and (data.session != session_id or data.get("epoch") != host_epoch):
			conn.send({"kind": "reject", "reason": "This host belongs to an older session epoch."})
			conn.close()
			return
		if id != null:
			conn.close()
			return
		_pending.erase(conn)
		id = reserved_ids.get(remote_id, _next_id)
		_next_id = maxi(_next_id, id + 1)
		connections[id] = conn
		identities[id] = conn.remote_peer_id
		conn.send({"kind": "welcome", "id": id, "protocol": PROTOCOL_VERSION, "session": session_id, "epoch": host_epoch, "capacity": max_players})
		_events.append([true, id])
	elif id != null:
		_receive_transport_data(id, data)

func _client_message(data: Variant):
	if !(data is Dictionary):
		return
	if data.get("kind") == "welcome" and _status == MultiplayerPeer.CONNECTION_CONNECTING:
		if data.get("protocol") != PROTOCOL_VERSION:
			_host_closed("Different multiplayer build. Update/reload both desktop and browser versions.")
			return
		if !session_id.is_empty() and (data.get("session") != session_id or data.get("epoch") != host_epoch):
			_host_closed("The successor belongs to a different session epoch.")
			return
		var assigned_id = data.get("id", 0)
		if !(assigned_id is int) or assigned_id < 2 or assigned_id > 2147483647:
			return
		_id = assigned_id
		var capacity = data.get("capacity", 16)
		if !(capacity is int) or capacity < 1 or capacity > 2147483647:
			_host_closed("Invalid session capacity.")
			return
		max_players = capacity
		session_id = data.get("session", "")
		host_epoch = data.get("epoch", 0)
		_status = MultiplayerPeer.CONNECTION_CONNECTED
		_events.append([true, 1])
		admitted.emit()
		# Only the client offers, after the game/version handshake has succeeded.
		if connections[1].rtc_enabled:
			connections[1].upgrade_to_rtc(connections[1].rtc_ice_servers)
	elif data.get("kind") in ["reject", "kick"]:
		# An intentional rejection is not an election trigger.
		rejected.emit(str(data.get("reason", "Connection rejected.")))
	else:
		_receive_transport_data(1, data)

func _receive_transport_data(id: int, data: Dictionary):
	if data.get("kind") == "control" and data.get("data") is Dictionary:
		control_message.emit(id, data.data)
		return
	if suspended:
		return
	if data.get("kind") == "ack":
		var acknowledged = data.get("sequence", -1)
		if !(acknowledged is int) or acknowledged < 0 or acknowledged > _send_sequences.get(id, 0):
			return
		var pending: Dictionary = _reliable_pending.get(id, {})
		for sequence in pending.keys():
			if sequence <= acknowledged:
				pending.erase(sequence)
		return
	if data.get("kind") != "packet":
		return
	var mode = data.get("mode", -1)
	var received: int = _receive_sequences.get(id, 0)
	if mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE:
		var sequence = data.get("sequence", -1)
		if !(sequence is int) or sequence <= 0 or sequence > received + RELIABLE_WINDOW:
			return
		if sequence > received:
			if !_reliable_received.has(id):
				_reliable_received[id] = {}
			_reliable_received[id][sequence] = data
			_drain_reliable(id)
		_acks_due[id] = _receive_sequences.get(id, 0)
	else:
		var basis = data.get("basis", -1)
		if !(basis is int) or basis < 0 or basis > received:
			return # Drop transient updates that overtake roster/path-cache setup.
		_queue_packet(id, data)

func _drain_reliable(id: int):
	var packets: Dictionary = _reliable_received.get(id, {})
	var next: int = _receive_sequences.get(id, 0) + 1
	while packets.has(next):
		if !_queue_packet(id, packets[next]):
			break
		packets.erase(next)
		_receive_sequences[id] = next
		_acks_due[id] = next
		next += 1

func _queue_packet(id: int, data: Dictionary) -> bool:
	if data.get("kind") != "packet" or !(data.get("bytes") is PackedByteArray):
		return false
	var mode = data.get("mode", -1)
	var channel = data.get("channel", -1)
	if !(mode is int) or mode < 0 or mode > 2 or !(channel is int) or channel < 0:
		return false
	if data.bytes.size() > MAX_PACKET_SIZE or _packets.size() >= 4096:
		return false
	if !_server and id == 1:
		var bytes: PackedByteArray = data.bytes
		if bytes.size() >= SCENE_SYSTEM_HEADER_SIZE and (bytes[0] & SCENE_COMMAND_MASK) == SCENE_COMMAND_SYSTEM:
			var logical_peer = bytes.decode_u32(2)
			if bytes[1] == SCENE_SYSTEM_DEL_PEER:
				_departed_relay_peers[logical_peer] = true
				# RTC reliable control and unordered movement use separate channels.
				# Discard already queued and future traffic from the departed sender
				# before SceneMultiplayer removes that sender's RPC/path cache.
				_packets = _packets.filter(func(packet): return _relay_sender(packet.bytes) != logical_peer)
			elif bytes[1] == SCENE_SYSTEM_RELAY and _departed_relay_peers.has(logical_peer):
				return true # Intentionally consumed stale traffic; do not retry it.
	_packets.append({"peer": id, "bytes": data.bytes, "mode": mode, "channel": channel})
	return true

func _relay_sender(bytes: PackedByteArray) -> int:
	if bytes.size() >= SCENE_SYSTEM_HEADER_SIZE and (bytes[0] & SCENE_COMMAND_MASK) == SCENE_COMMAND_SYSTEM and bytes[1] == SCENE_SYSTEM_RELAY:
		return bytes.decode_u32(2)
	return 0

func _client_closed(_reason: String, remote_id: String):
	_pending = _pending.filter(func(conn): return conn.remote_peer_id != remote_id)
	var id = identities.find_key(remote_id)
	if id != null:
		connections.erase(id)
		identities.erase(id)
		_send_sequences.erase(id)
		_receive_sequences.erase(id)
		_reliable_pending.erase(id)
		_reliable_received.erase(id)
		_acks_due.erase(id)
		_packets = _packets.filter(func(packet): return packet.peer != id)
		_events.append([false, id])

func _host_closed(reason: String):
	if _status == MultiplayerPeer.CONNECTION_DISCONNECTED or suspended:
		return
	# Give the session a chance to migrate before SceneMultiplayer tears down.
	suspended = true
	connection_lost.emit(reason)

func _poll() -> void:
	if suspended:
		return
	_service_reliable_packets()
	for conn in _pending.duplicate():
		if Time.get_ticks_msec() - conn.peer.meta.get("join_started", 0) > 10000:
			conn.close()
	var events = _events.duplicate()
	_events.clear()
	for event in events:
		if event[0]:
			peer_connected.emit(event[1])
		else:
			peer_disconnected.emit(event[1])

func _service_reliable_packets():
	if _status != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	for id in connections.keys():
		var conn: RelayPeerConnection = connections.get(id)
		if conn == null or conn.state != RelayPeerConnection.State.READY:
			continue
		_drain_reliable(id)
		if _acks_due.has(id):
			var acknowledged: int = _receive_sequences.get(id, 0)
			if conn.send_relay({"kind": "ack", "sequence": acknowledged}):
				_acks_due.erase(id)
		var pending: Dictionary = _reliable_pending.get(id, {})
		var now = Time.get_ticks_msec()
		for sequence in pending.keys():
			var entry = pending.get(sequence)
			if entry != null and now - entry.sent_at >= RELIABLE_RETRY_MS:
				if not conn.send(entry.packet):
					break # Retry after the transport has capacity; do not spin on a full queue.
				entry.sent_at = now

func _put_packet_script(buffer: PackedByteArray) -> Error:
	if suspended:
		return OK
	if _status != MultiplayerPeer.CONNECTION_CONNECTED:
		return ERR_UNCONFIGURED
	if buffer.size() > MAX_PACKET_SIZE:
		return ERR_INVALID_DATA
	var packet = {"kind": "packet", "bytes": buffer, "mode": _mode, "channel": _channel}
	if _target > 0:
		if !connections.has(_target):
			return ERR_DOES_NOT_EXIST
		if connections[_target].state != RelayPeerConnection.State.READY:
			return OK # A leaving peer can remain in SceneMultiplayer until the next poll.
		_send_scene_packet(_target, packet)
	else:
		for id in connections:
			if id != -_target and connections[id].state == RelayPeerConnection.State.READY:
				_send_scene_packet(id, packet)
	return OK

func _send_scene_packet(id: int, packet: Dictionary):
	var outgoing = packet.duplicate()
	var reliable = outgoing.mode == MultiplayerPeer.TRANSFER_MODE_RELIABLE
	if reliable:
		var sequence: int = _send_sequences.get(id, 0) + 1
		_send_sequences[id] = sequence
		outgoing.sequence = sequence
		if !_reliable_pending.has(id):
			_reliable_pending[id] = {}
		_reliable_pending[id][sequence] = {"packet": outgoing, "sent_at": Time.get_ticks_msec()}
	else:
		outgoing.basis = _send_sequences.get(id, 0)
	if not connections[id].send(outgoing, reliable) and reliable:
		_reliable_pending[id][outgoing.sequence].sent_at = 0

func _get_packet_script() -> PackedByteArray:
	return _packets.pop_front().bytes if !_packets.is_empty() else PackedByteArray()

func _get_available_packet_count() -> int:
	return _packets.size()

func _get_packet_peer() -> int:
	return _packets[0].peer if !_packets.is_empty() else 0

func _get_packet_channel() -> int:
	return _packets[0].channel if !_packets.is_empty() else 0

func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return _packets[0].mode if !_packets.is_empty() else MultiplayerPeer.TRANSFER_MODE_RELIABLE

func _get_max_packet_size() -> int:
	return MAX_PACKET_SIZE

func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return _status

func _get_unique_id() -> int:
	return _id

func _is_server() -> bool:
	return _server

func _is_server_relay_supported() -> bool:
	return true

func _set_target_peer(peer: int) -> void:
	_target = peer

func _set_transfer_channel(channel: int) -> void:
	_channel = channel

func _get_transfer_channel() -> int:
	return _channel

func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_mode = mode

func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _mode

func _set_refuse_new_connections(enable: bool) -> void:
	_refuse = enable

func _is_refusing_new_connections() -> bool:
	return _refuse

func _disconnect_peer(peer: int, _force: bool) -> void:
	if connections.has(peer):
		connections[peer].close()

func kick_peer(id: int, reason: String):
	if connections.has(id):
		connections[id].send_relay({"kind": "kick", "reason": reason})
		connections[id].close()

func _close() -> void:
	_status = MultiplayerPeer.CONNECTION_DISCONNECTED
	for conn in connections.values() + _pending:
		conn.close()
	connections.clear()
	identities.clear()
	_pending.clear()
	_departed_relay_peers.clear()
	_send_sequences.clear()
	_receive_sequences.clear()
	_reliable_pending.clear()
	_reliable_received.clear()
	_acks_due.clear()
	_packets.clear()
	_events.clear()
