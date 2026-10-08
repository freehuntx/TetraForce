extends Node
## Four distinct profiles, including a browser observer, survive a native departure.
const PROFILES = {
	"host": {"name": "AppearanceHost", "skin": "res://entities/player/key.png"},
	"leaver": {"name": "LeavingNative", "skin": "res://entities/player/knot.png"},
	"native": {"name": "RemainingNative", "skin": "res://entities/player/chain.png"},
	"browser": {"name": "BrowserObserver", "skin": "res://entities/player/key.png"},
}
var main: Main
var role = "browser"
var checks = 0
var failures = 0
var expected: Dictionary = {}
var roles: Dictionary = {}
var reports: Dictionary = {}
var finished = false
var puppet_instances: Dictionary = {}

func _ready():
	var args = {}
	for argument in OS.get_cmdline_user_args():
		var parts = argument.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	role = args.get("role", "browser")
	ProjectSettings.set_setting("freelay/broker_urls", PackedStringArray([args.get("broker", "ws://127.0.0.1:18983/mqtt")]))
	ProjectSettings.set_setting("freelay/ice_servers", [])
	main = load("res://engine/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(0.7).timeout
	global.options.player_data = PROFILES[role].duplicate(true)
	main.connect_lobby(args.get("lobby", "appearance-regression"), "host" if role == "host" else "join")
	get_tree().create_timer(45.0).timeout.connect(func():
		if !finished:
			push_error("Appearance regression timed out: " + role)
			get_tree().quit(1)
	)
	while !is_instance_valid(network.current_map):
		await get_tree().process_frame
	if role == "host":
		expected[network.pid] = PROFILES[role].duplicate(true)
		while expected.size() != 4 or network.player_list.size() != 4:
			await get_tree().process_frame
		await get_tree().create_timer(1.0).timeout
		_check_appearance.rpc(expected, "before")
	else:
		_register.rpc_id(1, role)

@rpc("any_peer", "call_remote", "reliable") func _register(player_role: String):
	var id = multiplayer.get_remote_sender_id()
	roles[id] = player_role
	expected[id] = PROFILES[player_role].duplicate(true)

@rpc("authority", "call_local", "reliable") func _check_appearance(profiles: Dictionary, stage: String):
	# Wait for the game's actual roster snapshot, not this test RPC: the two
	# can cross transports during the initial WebRTC upgrade.
	var deadline = Time.get_ticks_msec() + 5000
	while !_roster_ready(profiles) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if OS.has_feature("web"):
		print("Appearance diagnostics %s: pid=%s map=%s players=%s roster=%s revision=%s" % [stage, network.pid, network.current_map.name, network.current_players, network.player_list, network._received_roster_revision])
	check(network.current_players.size() == profiles.size(), "The appearance roster must match the live players (%s)" % stage)
	check(global.options.player_data == PROFILES[role], "Remote lifecycle events must not change the local selected profile (%s)" % stage)
	for id in profiles:
		check(network.player_data.get(id) == profiles[id], "Player %s metadata must retain its own profile (%s)" % [id, stage])
		var player = network.current_map.get_node_or_null(str(id))
		check(player != null, "Player %s must retain its puppet (%s)" % [id, stage])
		if player != null:
			if stage == "before":
				puppet_instances[id] = player.get_instance_id()
			else:
				check(player.get_instance_id() == puppet_instances.get(id), "A departure must not recreate player %s (%s)" % [id, stage])
			check(player.nametag.text == profiles[id].name, "Player %s must retain its own displayed name (%s): got %s" % [id, stage, player.nametag.text])
			check(player.sprite.texture.resource_path == profiles[id].skin, "Player %s must retain its own displayed skin (%s): got %s" % [id, stage, player.sprite.texture.resource_path])
	if multiplayer.is_server():
		_report(network.pid, failures, stage)
	else:
		_report.rpc_id(1, network.pid, failures, stage)

func _roster_ready(profiles: Dictionary) -> bool:
	if network.current_players.size() != profiles.size():
		return false
	for id in profiles:
		if !network.current_map.has_node(str(id)):
			return false
	return true

@rpc("any_peer", "call_remote", "reliable") func _report(id: int, count: int, stage: String):
	reports[id] = count
	if reports.size() != expected.size():
		return
	if stage == "before":
		reports.clear()
		var leaver = roles.find_key("leaver")
		_leave.rpc_id(leaver)
		while network.player_list.has(leaver):
			await get_tree().process_frame
		expected.erase(leaver)
		await get_tree().create_timer(1.0).timeout
		_check_appearance.rpc(expected, "after")
	elif stage == "after":
		reports.clear()
		# Replay an older authoritative snapshot with every profile replaced by
		# the browser's. It must not undo the more recent departure snapshot.
		var stale_profiles = {}
		for peer_id in expected:
			stale_profiles[peer_id] = PROFILES.browser.duplicate(true)
		network.rpc("_receive_player_list", network.player_list, network.map_hosts, stale_profiles, network._roster_revision - 1)
		_check_appearance.rpc(expected, "stale")
	else:
		for peer_id in reports:
			if peer_id != network.pid:
				failures += reports[peer_id]
		_finish.rpc()
		await get_tree().create_timer(0.2).timeout
		await _shutdown()

@rpc("authority", "call_remote", "reliable") func _leave():
	finished = true
	main.end_game()
	await get_tree().create_timer(0.2).timeout
	check(global.options.player_data == PROFILES[role], "Returning to the menu must preserve the selected profile")
	print("Freelay appearance regression (%s): %d checks, %d failures" % [role, checks, failures])
	# Exercise the real menu quit path, including audio/resource cleanup.
	main.quit_program()

@rpc("authority", "call_remote", "reliable") func _finish():
	await _shutdown()

func _shutdown():
	finished = true
	main.end_game()
	await get_tree().create_timer(2.3).timeout
	main.queue_free()
	sfx.stop_all()
	await get_tree().create_timer(0.2).timeout
	print("Freelay appearance regression (%s): %d checks, %d failures" % [role, checks, failures])
	if !OS.has_feature("web"):
		get_tree().quit(1 if failures else 0)

func check(condition: bool, message: String):
	checks += 1
	if !condition:
		failures += 1
		push_error(message)
