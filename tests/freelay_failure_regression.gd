extends Node
var failures = 0
var checks = 0

func _ready():
	var main = load("res://engine/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(0.7).timeout
	main.connect_lobby("", "auto")
	check(main.get_node("message").visible, "An empty lobby must show an error")
	check(main.relay_session == null, "Invalid lobby attempts must be cleaned up")
	check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "Invalid lobbies must keep offline authority")
	main.host_server(false, 0, "failure-regression")
	while !is_instance_valid(network.current_map):
		await get_tree().process_frame
	print("BROKER_LOSS_READY")
	# The Python runner now terminates the broker.
	while is_instance_valid(network.current_map):
		await get_tree().process_frame
	await get_tree().create_timer(1.2).timeout
	check(main.visible, "Broker loss must return to the menu")
	check(main.get_node("message").visible, "Broker loss must explain the failure")
	check(multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "Broker loss must restore offline authority")
	check(network.player_data.is_empty(), "Broker loss must clear the old session")
	main.start_singleplayer()
	await get_tree().create_timer(0.7).timeout
	check(is_instance_valid(global.player), "Offline play must still work after broker loss")
	main.end_game()
	await get_tree().create_timer(0.2).timeout
	main.queue_free()
	sfx.stop_all()
	await get_tree().create_timer(0.2).timeout
	print("Freelay failure regression: %d checks, %d failures" % [checks, failures])
	get_tree().quit(1 if failures else 0)

func check(condition: bool, message: String):
	checks += 1
	if !condition:
		failures += 1
		push_error(message)
