extends Node

# Run with: godot --headless --path . res://tests/quickstart_regression.tscn
var failures := 0
var checks := 0

func _ready():
	var main = load("res://engine/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(0.6).timeout
	check(!main.get_node("multiplayer/Direct/host").disabled, "Freelay hosting must be available on desktop and web")

	main.get_node("top/VBoxContainer/singleplayer").pressed.emit()
	await get_tree().create_timer(1.2).timeout
	check_local_game(main)
	if is_instance_valid(global.player):
		var previous_position = global.player.position
		Input.action_press("RIGHT")
		await get_tree().create_timer(0.2).timeout
		Input.action_release("RIGHT")
		check(global.player.position.x > previous_position.x, "Offline Quickstart must allow the local player to move")

	var previous_map = network.current_map
	main.end_game()
	await get_tree().process_frame
	check(!is_instance_valid(previous_map), "Ending Quickstart must free its map")
	check(main.visible, "Ending Quickstart must restore the menu")
	check(network.player_list.is_empty(), "Ending Quickstart must clear its player list")

	# New Game and loaded saves share this startup path.
	main.get_node("player_select/saves").on_new()
	await get_tree().create_timer(0.2).timeout
	check_local_game(main)
	main.end_game()
	await get_tree().process_frame
	main.queue_free()
	sfx.stop_all()
	await get_tree().create_timer(0.1).timeout
	print("Quickstart regression: %d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures else 0)

func check_local_game(main):
	check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "Single-player must start without a listening socket")
	check(multiplayer.is_server() and network.pid == 1, "Offline play must retain local server authority")
	check(!network.dedicated, "Offline play must spawn a local player")
	check(is_instance_valid(network.current_map), "Quickstart must load its map")
	check(is_instance_valid(global.player), "Quickstart must spawn its player")
	check(network.current_players == [1] and network.map_peers.is_empty(), "Offline play must register only the local player")
	check(network.is_map_host(), "The local player must own the map simulation")
	check(!main.visible, "Quickstart must hide the menu")

func check(condition: bool, message: String):
	checks += 1
	if !condition:
		failures += 1
		push_error(message)
