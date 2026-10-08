extends Node
## Two hosts and two clients; the switching client visits both hosts three times.
var main: Main
var role = "steady"
var lobby_a = ""
var lobby_b = ""
var checks = 0
var failures = 0
var roles: Dictionary = {}
var visits = 0
var departures = 0
var finished = false

func _ready():
	var args = {}
	for argument in OS.get_cmdline_user_args():
		var parts = argument.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	role = args.get("role", "steady")
	lobby_a = args.get("lobby", "switching-regression") + "-a"
	lobby_b = args.get("lobby", "switching-regression") + "-b"
	ProjectSettings.set_setting("freelay/broker_urls", PackedStringArray([args.get("broker", "ws://127.0.0.1:18983/mqtt")]))
	ProjectSettings.set_setting("freelay/ice_servers", [])
	main = load("res://engine/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(0.7).timeout
	main.connect_lobby(lobby_b if role == "host-b" else lobby_a, "host" if role.begins_with("host") else "join")
	get_tree().create_timer(75.0).timeout.connect(func():
		if !finished:
			push_error("Lobby switching regression timed out: " + role)
			get_tree().quit(1)
	)
	await _wait_for_game()
	if role == "host-b":
		multiplayer.peer_connected.connect(func(_id): visits += 1)
		multiplayer.peer_disconnected.connect(_host_b_departure)
	elif role == "host-a":
		while roles.size() < 2:
			await get_tree().process_frame
		await _wait_for_rtc()
		_exercise_switching.rpc_id(roles.find_key("switcher"))
	else:
		_register_role.rpc_id(1, role)

func _wait_for_game():
	while !is_instance_valid(network.current_map) or !is_instance_valid(global.player):
		await get_tree().process_frame
	await get_tree().create_timer(0.7).timeout

func _wait_for_rtc():
	var deadline = Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var ready = true
		for conn in multiplayer.multiplayer_peer.connections.values():
			ready = ready and conn.transport == RelayPeerConnection.TRANSPORT_RTC
		if ready:
			return
		await get_tree().process_frame
	check(false, "A rejoined lobby must establish WebRTC")

@rpc("any_peer", "call_remote", "reliable") func _register_role(player_role: String):
	roles[multiplayer.get_remote_sender_id()] = player_role

@rpc("authority", "call_remote", "reliable") func _exercise_switching():
	for destination in [lobby_b, lobby_a, lobby_b, lobby_a, lobby_b, lobby_a]:
		var old_map = network.current_map
		var old_tick = network.tick
		main.connect_lobby(destination + "-cancelled", "join")
		var cancelled = main.relay_session
		await get_tree().create_timer(0.15).timeout
		main.connect_lobby(destination, "join")
		# A cancelled attempt must not be able to fail the newly active join.
		cancelled.failed.emit("Late failure from the previous lobby")
		await get_tree().process_frame
		check(!is_instance_valid(old_map), "Switching directly must free the previous map")
		check(!is_instance_valid(old_tick), "Switching directly must free the previous tick timer")
		check(network.player_data.is_empty(), "Switching must clear previous player metadata")
		check(!main.get_node("message").visible, "An old session's failure must not interrupt the new join")
		await _wait_for_game()
		await _wait_for_rtc()
		check(main.relay_session.lobby == destination, "Only the requested lobby may become active")
		check(network.current_players.size() == (3 if destination == lobby_a else 2), "Rejoining must rebuild the correct puppet roster")
		check(network.player_data.size() == network.current_players.size(), "Old lobby metadata must not leak into the new roster")
		var position = global.player.position
		Input.action_press("RIGHT")
		await get_tree().create_timer(0.1).timeout
		Input.action_release("RIGHT")
		check(global.player.position.x > position.x, "Player input must work after switching lobbies")
	_switching_done.rpc_id(1, failures)

func _host_b_departure(_id):
	departures += 1
	if departures == 3:
		check(visits == 3, "The second host must accept three fresh sessions")
		check(network.player_list.size() == 1, "The second host must remove every departed client")
		check(network.player_data.size() == 1, "Departed metadata must be cleared on the second host")
		_shutdown()

@rpc("any_peer", "call_remote", "reliable") func _switching_done(client_failures: int):
	failures += client_failures
	check(network.player_list.size() == 3, "The first host must retain the steady client and accept the returning one")
	_finish.rpc()
	await get_tree().create_timer(0.2).timeout
	await _shutdown()

@rpc("authority", "call_remote", "reliable") func _finish():
	if role == "steady":
		check(network.current_players.size() >= 2, "A steady client must survive other players changing lobbies")
	await _shutdown()

func _shutdown():
	if finished:
		return
	finished = true
	main.end_game()
	await get_tree().create_timer(2.3).timeout
	check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "Shutdown must restore offline authority")
	main.queue_free()
	sfx.stop_all()
	await get_tree().create_timer(0.2).timeout
	print("Freelay switching regression (%s): %d checks, %d failures" % [role, checks, failures])
	if !OS.has_feature("web"):
		get_tree().quit(1 if failures else 0)

func check(condition: bool, message: String):
	checks += 1
	if !condition:
		failures += 1
		push_error(message)
