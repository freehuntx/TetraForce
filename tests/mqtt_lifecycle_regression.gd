extends Node
## Real WebSocket transport with a tiny MQTT CONNECT/CONNACK fixture.
const PacketStream = preload("res://addons/mqtt-node/packet-stream.gd")
var server = TCPServer.new()
var sockets: Array[WebSocketPeer] = []
var port = 0
var reply_to_connect = true
var failures = 0
var checks = 0
var publications: Array[int] = []
var streams: Dictionary = {}
var largest_publish_frame = 0

class CongestedConnection extends RelayPeerConnection:
	var accept_sends := false
	var send_attempts := 0
	var last_ack := -1

	func _init():
		super(null, "backpressure-fixture")
		state = State.READY

	func send(_data: Variant, _reliable := true) -> bool:
		send_attempts += 1
		return accept_sends

	func send_relay(data: Variant) -> bool:
		last_ack = data.sequence
		return accept_sends

func _ready():
	for attempt in range(20):
		port = randi_range(20000, 50000)
		if server.listen(port, "127.0.0.1") == OK:
			break
	check(server.is_listening(), "MQTT fixture must listen")
	_ack_backpressure()
	await _buffered_connack()
	await _outbound_backpressure()
	await _cancel_pending_connect()
	await _missing_connack()
	server.stop()
	for socket in sockets:
		socket.close()
	await get_tree().create_timer(0.2).timeout
	print("MQTT lifecycle regression: %d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures else 0)

func _process(_delta):
	while server.is_connection_available():
		var socket = WebSocketPeer.new()
		socket.supported_protocols = PackedStringArray(["mqtt"])
		socket.inbound_buffer_size = 1024 * 1024
		socket.max_queued_packets = 4096
		socket.accept_stream(server.take_connection())
		sockets.append(socket)
		streams[socket.get_instance_id()] = PacketStream.new()
	for socket in sockets:
		socket.poll()
		if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		while socket.get_available_packet_count() > 0:
			var frame = socket.get_packet()
			if !frame.is_empty() and frame[0] >> 4 == MqttNode.PacketType.PUBLISH:
				largest_publish_frame = maxi(largest_publish_frame, frame.size())
			streams[socket.get_instance_id()].append_data(frame)
		var stream: PacketStream = streams[socket.get_instance_id()]
		while stream.get_available_bytes() > 0:
			var start = stream.get_position()
			stream.get_u8()
			var remaining = stream.get_dynamic_int()
			if remaining < 0 or stream.get_available_bytes() < remaining:
				stream.seek(start)
				break
			var end = stream.get_position() + remaining
			var packet = stream.data_array.slice(start, end)
			stream.seek(end)
			if !packet.is_empty() and packet[0] == 0x10 and reply_to_connect:
				socket.put_packet(PackedByteArray([0x20, 0x02, 0x00, 0x00]))
			elif !packet.is_empty() and packet[0] >> 4 == MqttNode.PacketType.PUBLISH:
				var published = MqttNode.parse_publish(packet)
				if published != null:
					publications.append(published.payload.decode_u32(0))
					if published.qos == 1:
						var id: int = published.packet_id
						socket.send(PackedByteArray([0x40, 0x02, id >> 8, id & 0xff]))
		if stream.get_position() > 0:
			stream.data_array = stream.data_array.slice(stream.get_position())
			stream.seek(0)

func _new_client(buffer_size := 1024 * 1024, queue_bytes := 1024 * 1024) -> MqttNode:
	var client = MqttNode.new()
	client.auto_connect = false
	client.auto_reconnect = false
	client.broker = "ws://127.0.0.1:%d/mqtt" % port
	client.outbound_buffer_size = buffer_size
	client.outbound_queue_bytes = queue_bytes
	add_child(client)
	client.set_process(false)
	client.connect_to_broker()
	return client

func _wait_for_connect(client: MqttNode):
	var deadline = Time.get_ticks_msec() + 3000
	while !client._connect_sent and Time.get_ticks_msec() < deadline:
		client._process(0.0)
		await get_tree().process_frame
	check(client._connect_sent, "WebSocket must send MQTT CONNECT")

func _wait_for_close(client: MqttNode):
	var deadline = Time.get_ticks_msec() + 3000
	while client.socket != null and Time.get_ticks_msec() < deadline:
		client._process(0.0)
		await get_tree().process_frame
	check(client.socket == null, "WebSocket close must complete")

func _buffered_connack():
	reply_to_connect = true
	var client = _new_client()
	var errors = []
	client.error.connect(func(reason): errors.append(reason))
	await _wait_for_connect(client)
	var deadline = Time.get_ticks_msec() + 3000
	while client.socket.get_available_packet_count() == 0 and Time.get_ticks_msec() < deadline:
		client.socket.poll()
		await get_tree().process_frame
	check(client.socket.get_available_packet_count() > 0, "CONNACK must be buffered before resuming MQTT processing")
	client._connect_sent_at = Time.get_unix_time_from_system() - 11.0
	client._process(0.0)
	check(client.connection_established, "A buffered CONNACK must be read before checking the deadline")
	check(errors.is_empty(), "Resuming a backgrounded connection must not report a false timeout")
	client.disconnect_from_broker()
	await _wait_for_close(client)
	client.queue_free()

func _ack_backpressure():
	var peer = FreelayMultiplayerPeer.new()
	peer.configure_host("test", "test", 2)
	var conn = CongestedConnection.new()
	peer.connections[2] = conn
	peer._receive_sequences[2] = 4
	peer._acks_due[2] = 4
	var previous_send = Time.get_ticks_msec() - FreelayMultiplayerPeer.RELIABLE_RETRY_MS
	peer._reliable_pending[2] = {
		1: {"packet": {"kind": "packet"}, "sent_at": previous_send},
		2: {"packet": {"kind": "packet"}, "sent_at": previous_send},
	}
	peer._service_reliable_packets()
	check(peer._acks_due.has(2), "Rejected ACKs must remain pending")
	check(peer._reliable_pending[2][1].sent_at == previous_send, "Rejected retries must not advance their timer")
	check(conn.send_attempts == 1, "A full transport must stop the retry batch")
	peer._receive_sequences[2] = 6
	conn.accept_sends = true
	peer._service_reliable_packets()
	check(!peer._acks_due.has(2) and conn.last_ack == 6, "Resumed ACKs must coalesce to the newest received sequence")
	check(conn.send_attempts == 3, "Rejected reliable packets must retry once capacity returns")

func _outbound_backpressure():
	reply_to_connect = true
	publications.clear()
	largest_publish_frame = 0
	var client = _new_client(16384, 32768)
	await _wait_for_connect(client)
	var deadline = Time.get_ticks_msec() + 3000
	while !client.connection_established and Time.get_ticks_msec() < deadline:
		client._process(0.0)
		await get_tree().process_frame
	check(client.connection_established, "Backpressure fixture must complete MQTT handshake")
	var oversized = PackedByteArray()
	oversized.resize(16385)
	check(!client.publish("burst", oversized, false, 1), "A packet larger than socket capacity must be rejected without a native send")
	check(client.packet_ack_queue.is_empty(), "Rejected publishes must not allocate pending MQTT acknowledgements")
	var payload = PackedByteArray()
	payload.resize(8000)
	var accepted = 0
	# Do not poll the receiver during this burst, forcing real TCP/WebSocket congestion.
	for sequence in range(5000):
		payload.encode_u32(0, sequence)
		if !client.publish("burst", payload, false, 1):
			break
		accepted += 1
	check(accepted > 0 and accepted < 5000, "A stalled transport must eventually apply backpressure")
	check(!client._outgoing.is_empty(), "Reliable publishes must wait in the connected-state queue")
	check(client._outgoing_bytes <= client.outbound_queue_bytes, "Connected-state buffering must remain bounded")
	check(client.packet_ack_queue.size() == accepted, "Only accepted QoS 1 publishes may await PUBACK")
	check(!client.publish("burst", payload, false, 0), "Transient updates must be dropped during congestion")
	# The optional relay rate limiter must also retain a publish rejected by MQTT.
	var relay = RelayClient.new()
	relay._mqtt = client
	relay.outbound_limit.enabled = true
	relay._outbound = RelayRateLimit.OutboundQueue.new(relay.outbound_limit)
	payload.encode_u32(0, accepted)
	check(relay._publish_raw("burst", payload, false, RelayRateLimit.OutboundQueue.PRIO_RELIABLE), "Rate-limited publishes must be accepted for retry")
	check(relay._outbound.queued_count() == 1, "The rate limiter must restore a transport-rejected publish")
	deadline = Time.get_ticks_msec() + 10000
	while (publications.size() < accepted + 1 or !client.packet_ack_queue.is_empty()) and Time.get_ticks_msec() < deadline:
		client._process(0.0)
		relay._publish_entries(relay._outbound.drain())
		await get_tree().process_frame
	check(publications.size() == accepted + 1, "All accepted reliable publishes must arrive after congestion clears")
	var ordered = publications.size() == accepted + 1
	for i in range(publications.size()):
		ordered = ordered and publications[i] == i
	check(ordered, "Backpressure must preserve reliable publish order and payloads")
	check(largest_publish_frame > 10000, "Queued MQTT publishes must share a WebSocket frame instead of being capped at one publish per game frame")
	check(client._outgoing.is_empty() and client._outgoing_bytes == 0, "The connected-state queue must drain after polling resumes")
	check(client.packet_ack_queue.is_empty(), "Successful sends must receive their MQTT acknowledgements")
	relay.free()
	# Fill it again and leave with no room even for MQTT DISCONNECT.
	for sequence in range(5000):
		payload.encode_u32(0, accepted + 1 + sequence)
		if !client.publish("burst", payload, false, 1):
			break
	check(!client._outgoing.is_empty(), "Disconnect fixture must have queued reliable traffic")
	client.outbound_queue_bytes = client._outgoing_bytes
	client.disconnect_from_broker()
	check(client._disconnect_packet_pending, "A full queue must defer MQTT DISCONNECT until it has capacity")
	check(!client._is_connected(), "Disconnecting clients must stop accepting new publishes")
	await _wait_for_close(client)
	check(client._outgoing.is_empty(), "Session reset must clear queued packets")
	check(client.packet_ack_queue.is_empty(), "Session reset must clear pending MQTT acknowledgements")
	client.queue_free()

func _cancel_pending_connect():
	reply_to_connect = false
	var client = _new_client()
	var errors = []
	var disconnects = []
	var failed_connects = []
	client.error.connect(func(reason): errors.append(reason))
	client.disconnected.connect(func(reason): disconnects.append(reason))
	client.connecting_failed.connect(func(): failed_connects.append(true))
	await _wait_for_connect(client)
	client._connect_sent_at = Time.get_unix_time_from_system() - 11.0
	client.disconnect_from_broker()
	await _wait_for_close(client)
	check(errors.is_empty(), "A cancelled join must not run the CONNACK timeout")
	check(disconnects == ["client disconnect"], "Intentional disconnect must survive session reset")
	check(failed_connects.is_empty(), "Cancellation must not masquerade as a failed connection")
	check(client._connection_state == MqttNode.State.IDLE, "Cancellation must not schedule a reconnect")
	client.queue_free()

func _missing_connack():
	reply_to_connect = false
	var client = _new_client()
	var errors = []
	client.error.connect(func(reason): errors.append(reason))
	await _wait_for_connect(client)
	client._connect_sent_at = Time.get_unix_time_from_system() - 11.0
	client._process(0.0)
	check(errors == ["CONNACK timeout (no broker response)"], "A genuinely silent broker must still report its timeout")
	check(!client.connection_established, "A silent broker must never be treated as connected")
	await _wait_for_close(client)
	client.queue_free()

func check(condition: bool, message: String):
	checks += 1
	if !condition:
		failures += 1
		push_error(message)
