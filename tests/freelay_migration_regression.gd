extends Node
## Real game worlds and encrypted sessions, including SIGKILL recovery.
var main: Main
var role = "join"
var scenario = "graceful"
var failures = 0
var checks = 0
var started = false
var initial_host = false
var original_player: Player
var original_position = Vector2.ZERO
var previous_epoch = 0
var expected_players = 2
var _finished = false
var _rejected_once = false
var _was_authorized = false

func _ready():
	var args = {}
	for argument in OS.get_cmdline_user_args():
		var parts = argument.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	role = args.get("role", "join")
	scenario = args.get("scenario", "graceful")
	expected_players = 4 if scenario == "repeated" else (3 if scenario == "crash" else 2)
	expected_players = int(args.get("players", expected_players))
	ProjectSettings.set_setting("freelay/webrtc_enabled", args.get("rtc", "false") == "true")
	ProjectSettings.set_setting("freelay/ice_servers", [])
	ProjectSettings.set_setting("freelay/broker_urls", PackedStringArray([args.get("broker")]))
	main = load("res://engine/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(0.7).timeout
	global.options.player_data.name = args.get("name", role)
	main.connect_lobby(args.get("lobby"), role, expected_players + 1 if role == "host" else 16)
	get_tree().create_timer(65.0).timeout.connect(func():
		if !_finished:
			if is_instance_valid(main.relay_session):
				var migration = main.relay_session.migration
				print("Migration timeout state: epoch=%s active=%s winner=%s term=%s installed=%s votes=%s" % [migration.epoch, migration.active, migration.winner, migration.term, migration.installed, migration.votes])
			else:
				print("Migration timeout state: session already ended")
			push_error("Host migration regression timed out (%s/%s)" % [scenario, role])
			get_tree().quit(1)
	)
	while !is_instance_valid(network.current_map):
		await get_tree().process_frame
	initial_host = multiplayer.is_server()
	main.relay_session.migration_peer_ready.connect(func(_peer):
		_was_authorized = !main.relay_session.migration.authorization.is_empty()
	)
	if !initial_host:
		var client = main.relay_session.client
		client.peer_connection_requested.disconnect(main.relay_session._incoming_connection)
		client.peer_connection_requested.connect(_reject_first_reconnect)
	if initial_host:
		while main.relay_session.migration.members.size() < expected_players:
			await get_tree().process_frame
		var fixture = preload("res://tests/freelay_sync_fixture.tscn").instantiate()
		network.current_map.add_child(fixture)
		fixture.value = 42
		var pot = preload("res://tiles/pot.tscn").instantiate()
		pot.name = "MigrationPot"
		pot.position = Vector2(10000, 10000)
		network.current_map.add_child(pot)
		pot.broken = true
		for id in network.map_peers:
			network.peer_create_id(id, fixture.scene_file_path, fixture.name, network.current_map.get_path())
			network.peer_create_id(id, pot.scene_file_path, pot.name, network.current_map.get_path())
		network.states.migration_marker = [77]
		network.set_state("migration_marker", [77])
		await get_tree().create_timer(2.0).timeout
		await _test_signed_outsider()
		_begin.rpc()
		await get_tree().create_timer(1.5).timeout
		if scenario == "host-connection-loss":
			for conn in main.relay_session.peer.connections.values().duplicate():
				conn.close()
			while is_instance_valid(main.relay_session):
				await get_tree().process_frame
			check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "A live old host steps down after its clients start crash voting")
			await _shutdown()
			return
		if scenario in ["crash", "no-quorum", "candidate-loss"]:
			print("MIGRATION_KILL_READY")
			return
		await main.end_game()
		await _shutdown()
		return
	while !started:
		await get_tree().process_frame
	if scenario == "candidate-loss" and main.relay_session.migration._candidates()[0] == main.relay_session.client.profile.peer_id:
		print("MIGRATION_KILL_READY")
		return
	if scenario == "no-quorum":
		while !network.migrating:
			await get_tree().process_frame
		check(is_instance_valid(network.current_map), "No-quorum migration preserves the world while waiting")
		while is_instance_valid(main.relay_session):
			await get_tree().process_frame
		check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "No-quorum recovery fails cleanly rather than electing a second host")
		await _shutdown()
		return
	var goal = 2 if scenario == "repeated" else 1
	while previous_epoch < goal:
		while !is_instance_valid(main.relay_session) or main.relay_session.migration.epoch <= previous_epoch or network.migrating:
			await get_tree().process_frame
		previous_epoch = main.relay_session.migration.epoch
		await get_tree().create_timer(0.8).timeout
		await _validate()
		if scenario == "repeated" and previous_epoch == 1 and multiplayer.is_server():
			while main.relay_session.migration.members.size() != 3:
				await get_tree().process_frame
			await get_tree().create_timer(1.0).timeout
			print("MIGRATION_KILL_READY")
			return
	await get_tree().create_timer(1.0).timeout
	await _shutdown()

@rpc("authority", "call_local", "reliable") func _begin():
	check(!main.relay_session.migration.active, "Signed lobby outsiders cannot initiate an election")
	started = true
	original_player = global.player
	original_position = global.player.position
	if !multiplayer.is_server():
		# Restore must recreate missing synchronized objects and remove stale
		# local objects, not just preserve whatever happens to be on screen.
		network.current_map.get_node("FreelayFixture").free()
		var phantom = preload("res://tests/freelay_sync_fixture.tscn").instantiate()
		phantom.name = "MigrationPhantom"
		network.current_map.add_child(phantom)
	# Idle positions and a live dynamic node make rollback/restoration visible.
	network.tick.start()

func _validate():
	print("Migrated roster: epoch=%s digest=%s members=%s" % [previous_epoch, main.relay_session.migration.roster, main.relay_session.migration.members])
	check(main.relay_session.peer == multiplayer.multiplayer_peer, "SceneMultiplayer uses the successor's new transport")
	check(main.relay_session.peer.host_epoch == previous_epoch, "Every peer adopts the same host epoch")
	check(main.relay_session.peer.max_players == expected_players + 1 and main.relay_session.capacity == expected_players + 1, "The original room capacity survives migration")
	var expected_authorization = scenario == "graceful" or (scenario == "repeated" and previous_epoch == 1)
	check(_was_authorized == expected_authorization, "A graceful handover waits for the departing host's final checkpoint authorization")
	check(main.relay_session.migration.members.find_key(1) == (main.relay_session.client.profile.peer_id if multiplayer.is_server() else main.relay_session.peer.identities.get(1)), "Every peer agrees on the successor identity")
	check(network.pid == multiplayer.get_unique_id(), "The local ID follows the rebuilt transport")
	check(global.player == original_player, "Local avatar, HUD and camera survive handover")
	check(original_player.get_multiplayer_authority() == network.pid and str(original_player.name) == str(network.pid), "Local authority and node name are remapped")
	check(original_player.position.distance_to(original_position) < 1.0, "Player position survives migration")
	var departures = previous_epoch + (1 if scenario == "candidate-loss" else 0)
	check(network.player_list.size() == expected_players - departures, "Departed hosts are removed from the roster")
	check(network.player_data.size() == network.player_list.size(), "Profiles survive migration without the departed host")
	check(network.states.get("migration_marker", []).has(77), "Shared persistent state survives host loss")
	var fixture = network.current_map.get_node_or_null("FreelayFixture")
	check(fixture != null and fixture.value == 42, "Live dynamic object state survives host loss")
	check(!network.current_map.has_node("MigrationPhantom"), "Objects absent from the authoritative checkpoint are removed")
	var pot = network.current_map.get_node_or_null("MigrationPot")
	check(pot != null and pot.broken and pot.get_node("CollisionShape2D").disabled, "Broken map objects remain broken after migration")
	check(network.map_hosts.get(network.current_map.name) in network.current_players, "Map authority belongs to a surviving player")
	if multiplayer.is_server() and network.player_list.size() > 1:
		check(_rejected_once, "Clients recover from a rejected first successor handshake")
	var position = original_player.position
	Input.action_press("RIGHT")
	await get_tree().create_timer(0.1).timeout
	Input.action_release("RIGHT")
	check(original_player.position.x > position.x, "Gameplay resumes after handover")
	original_position = original_player.position
	if !multiplayer.is_server():
		var token = "rpc/%s/%s" % [main.relay_session.client.profile.peer_id, previous_epoch]
		network.add_to_state("migration_marker", token)
		await get_tree().create_timer(0.5).timeout
		check(network.states.migration_marker.has(token), "RPCs and state writes work through the new host")
	var migration = main.relay_session.migration
	main.relay_session.channel.send({"kind": "migration_vote", "session": migration.session_id, "epoch": migration.epoch - 1, "roster": migration.roster, "term": 99, "candidate": main.relay_session.client.profile.peer_id})
	await get_tree().create_timer(0.2).timeout
	check(!network.migrating and migration.epoch == previous_epoch, "Stale signed election traffic cannot restart a completed migration")

func _test_signed_outsider():
	var outsider = RelayClient.new()
	outsider.app_id = ProjectSettings.get_setting("freelay/app_id", "tetraforce")
	outsider.broker_urls = ProjectSettings.get_setting("freelay/broker_urls")
	add_child(outsider)
	outsider.open()
	await outsider.opened
	var channel = outsider.join("lobby/" + main.relay_session.lobby)
	await channel.joined
	var migration = main.relay_session.migration
	channel.send({"kind": "migration_vote", "session": migration.session_id, "epoch": migration.epoch, "roster": migration.roster, "term": 99, "candidate": migration._candidates()[0]})
	await get_tree().create_timer(0.4).timeout
	check(!migration.active, "Unadmitted signed identities have no voting rights")
	outsider.close()
	await get_tree().create_timer(0.3).timeout
	outsider.queue_free()

func _reject_first_reconnect(conn: RelayPeerConnection):
	if !_rejected_once and main.relay_session.migration.installed and main.relay_session.peer.is_host():
		_rejected_once = true
		conn.reject()
	else:
		main.relay_session._incoming_connection(conn)

func _shutdown():
	_finished = true
	await main.end_game()
	await get_tree().create_timer(1.2).timeout
	main.queue_free()
	sfx.stop_all()
	await get_tree().create_timer(0.2).timeout
	print("Host migration (%s/%s): %d checks, %d failures" % [scenario, role, checks, failures])
	get_tree().quit(1 if failures else 0)

func check(condition: bool, message: String):
	checks += 1
	if !condition:
		failures += 1
		push_error(message)
