extends Node
## Three real game instances against an MQTT-over-WebSocket broker.
var main: Main
var role = "auto"
var saved_count = 0
var failures = 0
var checks = 0
var reports: Dictionary = {}
var probes: Array = []
var _running = false
var _finished = false
var _require_rtc = true
var fallback_probes: Array = []
var _loss_peer: FreelayMultiplayerPeer
var _dropped_reliable = false
var pot_ready: Dictionary = {}
var pot_done: Dictionary = {}
var _pots_complete = false

class PotTestMap extends Node2D:
	signal player_entered(id)
	func is_game():
		return true

func _ready():
	var args = {}
	for argument in OS.get_cmdline_user_args():
		var parts = argument.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	role = args.get("role", "auto")
	_require_rtc = args.get("rtc", "true") == "true"
	ProjectSettings.set_setting("freelay/webrtc_enabled", _require_rtc)
	# LAN candidates exercise direct connections without depending on a public STUN service.
	ProjectSettings.set_setting("freelay/ice_servers", [])
	ProjectSettings.set_setting("freelay/broker_urls", PackedStringArray([args.get("broker", "ws://127.0.0.1:18983/mqtt")]))
	main = load("res://engine/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(0.7).timeout
	main.connect_lobby(args.get("lobby", "freelay-regression"), role)
	get_tree().create_timer(35.0).timeout.connect(func():
		if _finished:
			return
		push_error("Freelay regression timed out (%s)" % role)
		get_tree().quit(1)
	)
	while !is_instance_valid(network.current_map):
		await get_tree().process_frame
	check(multiplayer.multiplayer_peer is FreelayMultiplayerPeer, "Gameplay must use Freelay")
	if multiplayer.is_server():
		network.persistent_set_state(str(get_path()), {"saved_count": 7})
		network.states.regression = []
		while network.player_list.size() < 3:
			await get_tree().process_frame
		if _require_rtc:
			var deadline = Time.get_ticks_msec() + 5000
			while !_rtc_ready() and Time.get_ticks_msec() < deadline:
				await get_tree().process_frame
		await get_tree().create_timer(1.5).timeout
		_begin.rpc()

@rpc("authority", "call_local", "reliable") func _begin():
	if _running:
		return
	_running = true
	check(network.current_players.size() == 3, "All three players must share the map")
	check(network.player_data.size() == 3, "Player data must reach late joiners")
	check(network.map_peers.size() == 2, "Each player must see two remote peers")
	check(_rtc_ready() if _require_rtc else _relay_ready(), "Connections must use the requested transport")
	if !multiplayer.is_server():
		# Deliberately lose one real reliable packet. Later packets must wait
		# for its retransmission, rather than overtaking it or remaining lost.
		_loss_peer = multiplayer.multiplayer_peer
		var conn = _loss_peer.connections[1]
		conn.message.disconnect(_loss_peer._client_message)
		conn.message.connect(_intercept_host_message)
	var initial_positions = {}
	for id in network.current_players:
		check(network.current_map.has_node(str(id)), "Player puppet must exist")
		check(network.current_map.get_node(str(id)).get_multiplayer_authority() == id, "Player authority must match Freelay-assigned ID")
		initial_positions[id] = network.current_map.get_node(str(id)).position
	if multiplayer.is_server():
		var fixture = preload("res://tests/freelay_sync_fixture.tscn").instantiate()
		network.current_map.add_child(fixture)
		fixture.value = 42
		for id in network.map_peers:
			network.peer_create_id(id, fixture.scene_file_path, fixture.name, network.current_map.get_path())
	network.request_persistent_state(self)
	var state_deadline = Time.get_ticks_msec() + 2500
	while saved_count != 7 and Time.get_ticks_msec() < state_deadline:
		await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout
	check(saved_count == 7, "Late joiners must receive persistent world state")
	network.add_to_state("regression", str(network.pid))
	for id in multiplayer.get_peers():
		_relay_probe.rpc_id(id, network.pid)
	var previous_position = global.player.position
	Input.action_press("RIGHT")
	await get_tree().create_timer(0.2).timeout
	Input.action_release("RIGHT")
	check(global.player.position.x > previous_position.x, "Local player authority must allow movement")
	await get_tree().create_timer(1.0).timeout
	for id in network.map_peers:
		check(network.current_map.get_node(str(id)).position.x > initial_positions[id].x, "Remote player movement must synchronize")
	var received_fixture = network.current_map.get_node_or_null("FreelayFixture")
	check(received_fixture != null and received_fixture.value == 42, "Dynamic objects and their enter properties must synchronize")
	check(probes.size() == 2, "RPCs must work host-to-client and client-to-client")
	check(network.states.regression.size() == 3, "Shared state updates must converge through the host")
	if _loss_peer != null:
		check(_dropped_reliable, "The transport test must actually drop a reliable packet")
		var conn = _loss_peer.connections[1]
		conn.message.disconnect(_intercept_host_message)
		conn.message.connect(_loss_peer._client_message)
	await _test_pots()
	if _require_rtc:
		# Simulate loss of the direct connection while MQTT remains connected.
		network.tick.stop()
		global.player.set_physics_process(false)
		for conn in multiplayer.multiplayer_peer.connections.values():
			if conn._rtc != null:
				conn._rtc_teardown(true)
		await get_tree().create_timer(0.5).timeout
		check(_relay_ready(), "A failed WebRTC connection must fall back to MQTT")
		for id in multiplayer.get_peers():
			_fallback_probe.rpc_id(id, network.pid)
		var fallback_deadline = Time.get_ticks_msec() + 2500
		while fallback_probes.size() < 2 and Time.get_ticks_msec() < fallback_deadline:
			await get_tree().process_frame
		check(fallback_probes.size() == 2, "RPCs must continue working after WebRTC fallback")
	if multiplayer.is_server():
		_report(network.pid, failures)
	else:
		_report.rpc_id(1, network.pid, failures)

func _test_pots():
	var fixture = PotTestMap.new()
	fixture.name = "PotTestMap"
	network.current_map.add_child(fixture)
	for pot_name in ["Sword1", "Sword2", "Sword3", "Bomb"]:
		var pot = preload("res://tiles/pot.tscn").instantiate()
		pot.name = pot_name
		pot.position = Vector2(10000, 10000)
		fixture.add_child(pot)
	if multiplayer.is_server():
		_pots_ready(network.pid)
	else:
		_pots_ready.rpc_id(1, network.pid)
	var deadline = Time.get_ticks_msec() + 5000
	while !_all_pots_broken(fixture) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	check(_all_pots_broken(fixture), "Host and client sword hits and bomb blasts must break pots on every peer")
	for pot in fixture.get_children():
		check(pot.get_node("Sprite2D").frame == 4 and pot.get_node("CollisionShape2D").disabled, "Broken pots must finish their animation and become passable on every peer")
		pot.cut(null)
		pot.bombed()
		check(!pot.animation.is_playing(), "Repeated hits must not restart a broken pot's animation")
	if !multiplayer.is_server():
		# Recreate an intact local vase, then use the same enter-property path
		# as a player arriving in a map after its vases have been smashed.
		fixture.get_node("Sword1").free()
		var pot = preload("res://tiles/pot.tscn").instantiate()
		pot.name = "Sword1"
		pot.position = Vector2(10000, 10000)
		fixture.add_child(pot)
		network.peer_call_id(network.get_map_host(), fixture, "emit_signal", ["player_entered", network.pid])
		deadline = Time.get_ticks_msec() + 5000
		while !pot.broken and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
		await get_tree().process_frame
		check(pot.broken and pot.get_node("Sprite2D").frame == 4 and pot.get_node("CollisionShape2D").disabled, "Map entrants must receive already-broken pots without replaying the break")
		check(!pot.animation.is_playing(), "Restoring a broken pot must not replay its animation")
	if multiplayer.is_server():
		_pots_done(network.pid)
	else:
		_pots_done.rpc_id(1, network.pid)
	while !_pots_complete:
		await get_tree().process_frame

func _all_pots_broken(fixture):
	for pot in fixture.get_children():
		if !pot.broken:
			return false
	return true

@rpc("any_peer", "call_remote", "reliable") func _pots_ready(id: int):
	pot_ready[id] = true
	if pot_ready.size() == 3:
		_break_test_pots.rpc()

@rpc("any_peer", "call_remote", "reliable") func _pots_done(id: int):
	pot_done[id] = true
	if pot_done.size() == 3:
		_complete_pots.rpc()

@rpc("authority", "call_local", "reliable") func _complete_pots():
	_pots_complete = true

@rpc("authority", "call_local", "reliable") func _break_test_pots():
	var fixture = network.current_map.get_node("PotTestMap")
	var pot = fixture.get_node("Sword%s" % network.pid)
	pot.cut(null)
	pot.cut(null)
	if multiplayer.is_server():
		pot = fixture.get_node("Bomb")
		pot.bombed()
		pot.bombed()
		network.peer_call(pot, "bombed")
		network.peer_call(pot, "bombed")

func _intercept_host_message(data: Variant):
	if !_dropped_reliable and data is Dictionary and data.get("kind") == "packet" and data.get("mode") == MultiplayerPeer.TRANSFER_MODE_RELIABLE:
		_dropped_reliable = true
		return
	_loss_peer._client_message(data)

@rpc("any_peer", "call_remote", "reliable") func _relay_probe(source: int):
	check(multiplayer.get_remote_sender_id() == source, "Encrypted sessions must preserve RPC sender identity")
	probes.append(source)
	# The remote player position is a real NetworkObject update over Freelay.
	check(network.current_map.has_node(str(source)), "Relayed peer must have a puppet")

@rpc("any_peer", "call_remote", "reliable") func _fallback_probe(source: int):
	check(multiplayer.get_remote_sender_id() == source, "MQTT fallback must preserve sender identity")
	fallback_probes.append(source)

func _rtc_ready() -> bool:
	for conn in multiplayer.multiplayer_peer.connections.values():
		if conn.transport != RelayPeerConnection.TRANSPORT_RTC:
			return false
	return true

func _relay_ready() -> bool:
	for conn in multiplayer.multiplayer_peer.connections.values():
		if conn.transport != RelayPeerConnection.TRANSPORT_RELAY:
			return false
	return true

@rpc("any_peer", "call_remote", "reliable") func _report(id: int, count: int):
	reports[id] = count
	if reports.size() != 3:
		return
	for report in reports.values():
		failures += report
	# Exercise map-host reassignment when its owner leaves.
	network.map_hosts[network.current_map.name] = 2
	network.broadcast_player_roster()
	_leave.rpc_id(2)
	while network.player_list.has(2):
		await get_tree().process_frame
	check(network.map_hosts.get(network.current_map.name) == 1, "A departing map host must be reassigned")
	check(!network.player_data.has(2), "Departed player metadata must be removed")
	await get_tree().create_timer(0.5).timeout
	_finish.rpc()
	await get_tree().create_timer(1.0).timeout
	_finish()

@rpc("authority", "call_remote", "reliable") func _leave():
	await _shutdown()

@rpc("authority", "call_remote", "reliable") func _finish():
	if !multiplayer.is_server():
		check(network.player_list.size() == 2, "Departures must propagate to the remaining client")
	await _shutdown()

func _shutdown():
	_finished = true
	print("Freelay shutdown: peer %s" % network.pid)
	main.end_game()
	await get_tree().create_timer(1.2).timeout
	check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "Leaving a lobby must restore offline authority")
	check(network.player_data.is_empty(), "Leaving a lobby must clear metadata")
	main.queue_free()
	sfx.stop_all()
	await get_tree().create_timer(0.2).timeout
	print("Freelay regression (%s): %d checks, %d failures" % [role, checks, failures])
	if !OS.has_feature("web"):
		get_tree().quit(1 if failures else 0)

func check(condition: bool, message: String):
	checks += 1
	if !condition:
		failures += 1
		push_error(message)
