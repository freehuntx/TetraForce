extends Node
## Three real desktop instances, with no broker or WebRTC.

var main: Main
var role = "client"
var port = Main.DIRECT_PORT
var failures = 0
var checks = 0
var probes: Array = []
var reports: Dictionary = {}
var leaving = false
var finished = false

func _ready():
	for argument in OS.get_cmdline_user_args():
		var parts = argument.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			if parts[0] == "role":
				role = parts[1]
			elif parts[0] == "port":
				port = int(parts[1])
	get_tree().create_timer(20.0).timeout.connect(func():
		if !finished:
			push_error("Direct regression timed out (%s)" % role)
			get_tree().quit(1)
	)
	main = load("res://engine/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(0.6).timeout
	check(main.address_line.text == "127.0.0.1", "Direct must default to an IP, not a lobby")
	main.configure_direct_menu(true)
	check(main.get_node("multiplayer/Direct/Label").text == "TCP / Port 7777", "Web must retain the Direct connection label")
	check(main.address_line.visible and main.get_node("multiplayer/Direct/IPLabel").visible, "Web must keep the IP field available")
	check(main.get_node("multiplayer/Direct/host").disabled and !main.get_node("multiplayer/Direct/host").visible, "Web must disable and hide Direct hosting")
	check(!main.get_node("multiplayer/Direct/join").disabled and main.get_node("multiplayer/Direct/join").visible, "Web must keep Direct joining enabled and visible")
	main.configure_direct_menu(false)
	check(main.address_line.visible and !main.get_node("multiplayer/Direct/host").disabled, "Desktop must expose IP-based Direct play")
	main.connect_direct(false, "a-lobby-name", port)
	check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "A lobby name must not open a Direct connection")
	check(main.get_node("message/Label").text == "Enter a valid host IP.", "Invalid IP must show a concise error")
	main._on_back_pressed()
	main.connect_direct(role == "host", " 127.0.0.1 ", port)
	while !is_instance_valid(network.current_map):
		await get_tree().process_frame
	check(multiplayer.multiplayer_peer is WebSocketMultiplayerPeer, "Direct must use the TCP-backed multiplayer peer")
	check(!is_instance_valid(main.relay_session), "Direct must work without a Freelay session")
	if role == "host":
		network.states.direct = ["snapshot"]
		while network.player_list.size() < 3:
			await get_tree().process_frame
		await get_tree().create_timer(0.5).timeout
		_begin.rpc()

@rpc("authority", "call_local", "reliable") func _begin():
	check(network.current_players.size() == 3 and network.player_data.size() == 3, "Direct must synchronize all players and profiles")
	check(network.states.get("direct") == ["snapshot"], "Direct late joiners must receive shared state")
	var positions = {}
	for id in network.current_players:
		var player = network.current_map.get_node_or_null(str(id))
		check(player != null, "Direct must spawn remote player puppets")
		if player != null:
			positions[id] = player.position
	for id in multiplayer.get_peers():
		_probe.rpc_id(id, network.pid)
	Input.action_press("RIGHT")
	await get_tree().create_timer(0.2).timeout
	Input.action_release("RIGHT")
	await get_tree().create_timer(0.8).timeout
	for id in positions:
		check(network.current_map.get_node(str(id)).position.x > positions[id].x, "Direct must synchronize local and remote movement")
	check(probes.size() == 2, "Direct must relay host/client and client/client RPCs")
	if role != "host":
		_report.rpc_id(1, network.pid, failures)
		while !leaving or is_instance_valid(network.current_map):
			await get_tree().process_frame
		await get_tree().process_frame
		check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "Host departure must reset clients to offline")
		check(main.visible and network.player_list.is_empty(), "Host departure must restore the client menu and clear the roster")
		main.connect_direct(false, "127.0.0.1", port)
		main._on_back_pressed()
		check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "Back must cancel a pending TCP join")
		main.connect_direct(false, "127.0.0.1", port)
		while multiplayer.multiplayer_peer is WebSocketMultiplayerPeer:
			await get_tree().process_frame
		check(main.visible and main.get_node("message/Label").text == "Connection failed.", "A refused TCP join must restore the menu and explain the failure")
	else:
		_report(network.pid, failures)
		while reports.size() < 3:
			await get_tree().process_frame
		check(reports.values().all(func(count): return count == 0), "All Direct peers must pass their gameplay checks")
		_leave.rpc()
		await get_tree().create_timer(0.2).timeout
		main.end_game()
		await get_tree().process_frame
		var listener = TCPServer.new()
		check(listener.listen(port) == OK, "Ending Direct must release its TCP listening port")
		listener.stop()
		main.start_singleplayer()
		await get_tree().create_timer(0.2).timeout
		check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer and is_instance_valid(global.player), "Quickstart must work after Direct hosting")
		main.end_game()
	await get_tree().process_frame
	main.queue_free()
	sfx.stop_all()
	await get_tree().create_timer(0.1).timeout
	finished = true
	print("Direct regression (%s): %d checks, %d failures" % [role, checks, failures])
	get_tree().quit(1 if failures else 0)

@rpc("any_peer", "call_remote", "reliable") func _probe(id):
	probes.append(id)

@rpc("any_peer", "call_remote", "reliable") func _report(id, count):
	reports[id] = count

@rpc("authority", "call_remote", "reliable") func _leave():
	leaving = true

func check(condition: bool, message: String):
	checks += 1
	if !condition:
		failures += 1
		push_error(message)
