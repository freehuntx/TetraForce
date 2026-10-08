class_name Main
extends Control

const DIRECT_PORT = 7777

var default_map = "res://maps/shrine.tmx"
var default_entrance = "player_start"
var relay_session: Node
var default_lobby = "tetraforce"
var _hosting_dedicated = false
var _hosting_empty_timeout = 0
var _quitting = false
var _ending = false

@onready var address_line = $multiplayer/Direct/address
@onready var lobby_line = $multiplayer/Automatic/lobby
@onready var singleplayer_focus = $top/VBoxContainer/singleplayer
@onready var loading_screen = $loading_screen_layer/loading_screen

func _ready():
	$AnimatedSprite2D.play()
	global.load_options()
	hide_menus()
	$top.show()
	configure_direct_menu(OS.has_feature("web"))
	
	multiplayer.connected_to_server.connect(_client_connect_ok)
	multiplayer.connection_failed.connect(_client_connect_fail)
	multiplayer.server_disconnected.connect(_client_disconnect)
	
	get_tree().set_auto_accept_quit(false)
	
	#For server commandline arguments. Searches for ones passed, then tries to set ones that exist.
	#Puts arguments passed as "--example=value" in a dictionary.
	var arguments = {}
	for argument in OS.get_cmdline_user_args():
		if argument.find("=") > -1:
			var key_value = argument.split("=", true, 1)
			arguments[key_value[0].lstrip("--")] = key_value[1]
	
	if "map" in arguments:
		var map_arg = arguments.get("map").rsplit("/maps/")[1]
		var map_path = str("res://maps/", map_arg)
		default_map = map_path
		default_entrance = arguments.get("entrance", "")
		await get_tree().process_frame
		start_singleplayer()
		
	
	if "lobby" in arguments:
		default_lobby = arguments["lobby"]
		lobby_line.text = default_lobby
	if "broker" in arguments:
		ProjectSettings.set_setting("freelay/broker_urls", PackedStringArray([arguments["broker"]]))
	
	if OS.has_feature("dedicated_server") || arguments.get("dedicatedserver") == "true":
		var empty_timeout = get_empty_server_timeout(arguments)
		set_dedicated_server(empty_timeout)
	
	await get_tree().create_timer(0.5).timeout
	if _quitting:
		return
	sfx.set_music("shrine", "quiet")
	singleplayer_focus.grab_focus()

func get_empty_server_timeout(arguments):
	var empty_timeout
	
	var empty_timeout_arg = arguments.get("empty-server-timeout") # don't set default here
	if empty_timeout_arg != null:
		if empty_timeout_arg.is_valid_int():
			var empty_timeout_arg_int = int(empty_timeout_arg)
			if empty_timeout_arg_int >= 0:
				empty_timeout = empty_timeout_arg_int
			else:
				print("invalid value for empty-server-timeout - must be an integer >= 0")
		else:
			print("invalid value for empty-server-timeout - must be an integer >= 0")
	
	if empty_timeout == null:
		empty_timeout = 0 # set default here
		print("defaulting empty-server-timeout to %d" % empty_timeout)
	
	if empty_timeout > 0:
		print("empty-server-timeout set to %d seconds" % empty_timeout)
	else:
		print("empty-server-timeout set to 0 - server will not stop when empty")
	
	return empty_timeout

func start_game(dedicated = false, empty_timeout = 0, map = null, entrance = null):
	loading_screen.stop_loading()
	if dedicated:
		network.dedicated = true
		network.empty_timeout = empty_timeout
	
	network.initialize()
	
	if !dedicated:
		if entrance:
			global.next_entrance = entrance
		else:
			global.next_entrance = default_entrance
		var level
		if map:
			level = load(map).instantiate()
		else:
			level = load(default_map).instantiate()
		get_tree().get_root().add_child(level)
		hide()

func start_singleplayer():
	# Local play needs server authority, but must not open a listening socket.
	if is_instance_valid(relay_session):
		await relay_session.prepare_leave()
		network.complete(false)
	close_relay_session()
	network.reset_to_offline_peer()
	network.pid = MultiplayerPeer.TARGET_PEER_SERVER
	network.dedicated = false
	network.empty_timeout = 0
	start_game()

func host_server(dedicated = false, empty_timeout = 0, lobby_name = default_lobby, max_players = 16):
	_hosting_dedicated = dedicated
	_hosting_empty_timeout = empty_timeout
	connect_lobby(lobby_name, "host", max_players)

func join_lobby(lobby_name):
	_hosting_dedicated = false
	_hosting_empty_timeout = 0
	connect_lobby(lobby_name, "auto")

func configure_direct_menu(web: bool):
	$multiplayer/Direct/host.visible = !web
	$multiplayer/Direct/host.disabled = web

func connect_direct(hosting: bool, address = "", port = DIRECT_PORT):
	if hosting and OS.has_feature("web"):
		open_error_message("Hosting is desktop-only.")
		return
	address = address.strip_edges()
	if !hosting and !address.is_valid_ip_address():
		open_error_message("Enter a valid host IP.")
		return
	if is_instance_valid(relay_session):
		await relay_session.prepare_leave()
	loading_screen.stop_loading()
	network.complete(false)
	close_relay_session()
	network.reset_to_offline_peer()
	_hosting_dedicated = false
	_hosting_empty_timeout = 0
	# Godot's WebSocket multiplayer transport uses TCP and relays client RPCs.
	var peer = WebSocketMultiplayerPeer.new()
	var endpoint = "[%s]" % address if ":" in address else address
	var error = peer.create_server(port) if hosting else peer.create_client("ws://%s:%d" % [endpoint, port])
	if error != OK:
		peer.close()
		open_error_message("Could not host on port %d." % port if hosting else "Connection failed.")
		return
	multiplayer.multiplayer_peer = peer
	if hosting:
		start_game()
	else:
		loading_screen.with_load("Connecting to %s" % address, 25)

func connect_lobby(lobby_name, mode = "auto", max_players = 16):
	if is_instance_valid(relay_session):
		await relay_session.prepare_leave()
	loading_screen.stop_loading()
	network.complete(false)
	close_relay_session()
	network.reset_to_offline_peer()
	network.dedicated = false
	network.empty_timeout = 0
	loading_screen.with_load("Connecting to '%s'" % lobby_name, 25)
	relay_session = preload("res://engine/freelay_session.gd").new()
	add_child(relay_session)
	relay_session.session_ready.connect(_relay_ready.bind(relay_session))
	relay_session.failed.connect(_relay_failed.bind(relay_session))
	relay_session.disconnected.connect(_relay_failed.bind(relay_session))
	relay_session.migration_started.connect(_migration_started)
	relay_session.migration_peer_ready.connect(_migration_peer_ready)
	relay_session.migration_state_ready.connect(_migration_state_ready)
	relay_session.migration_finished.connect(_migration_finished)
	relay_session.open(lobby_name, mode, max_players)

func _relay_ready(peer: FreelayMultiplayerPeer, session: Node):
	if session != relay_session:
		return
	multiplayer.multiplayer_peer = peer
	if peer.is_host():
		start_game(_hosting_dedicated, _hosting_empty_timeout)
	# Clients start when SceneMultiplayer admits peer 1 on its next poll.

func _relay_failed(reason: String, session: Node):
	if session != relay_session:
		return
	loading_screen.stop_loading()
	end_game()
	open_error_message(reason)

func close_relay_session():
	if is_instance_valid(relay_session):
		relay_session.close()
	relay_session = null

func _physics_process(_delta):
	var peer = multiplayer.multiplayer_peer
	if peer is WebSocketMultiplayerPeer and !multiplayer.is_server() and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		# WebSocket enters CLOSING one poll before server_disconnected. Stop
		# gameplay now so physics RPCs cannot send into that closing socket.
		if peer.get_peer(1).get_ready_state() != WebSocketPeer.STATE_OPEN:
			peer.close()
			_client_disconnect()

func _client_connect_ok():
	if network.migrating:
		return
	loading_screen.stop_loading(100)
	start_game()

func _client_connect_fail():
	if network.migrating:
		return
	print("Failed to connect!")
	loading_screen.stop_loading()
	end_game()
	open_error_message("Connection failed.")

func _client_disconnect(code = OK, reason = "Server disconnected"):
	if network.migrating:
		return
	print("Disconnected from server: %s, %s" % [code, reason])
	network.complete()
	close_relay_session()
	show()
	if code != OK:
		open_error_message(reason)

func end_game():
	if _ending:
		return
	_ending = true
	if is_instance_valid(relay_session):
		await relay_session.prepare_leave()
	loading_screen.stop_loading()
	network.complete(false)
	close_relay_session()
	network.reset_to_offline_peer()
	show()
	screenfx.play("default")
	_ending = false

func quit_program():
	if _quitting:
		return
	_quitting = true
	if is_instance_valid(relay_session):
		await relay_session.prepare_leave()
	network.complete(false)
	close_relay_session()
	# Audio playback is released on the audio thread. Stop it before the
	# shutdown wait, rather than only in the autoload's late _exit_tree().
	sfx.stop_all()
	await get_tree().create_timer(RelayPeerConnection.RTC_LEAVE_GRACE_SECONDS + 0.1).timeout
	get_tree().quit()

func _migration_started():
	network.begin_migration()
	loading_screen.with_load("Host left - transferring the session", 25)

func _migration_peer_ready(peer: FreelayMultiplayerPeer):
	# Replacing the peer clears SceneMultiplayer's old path/relay caches.
	multiplayer.multiplayer_peer = peer

func _migration_state_ready(snapshot: Dictionary, remap: Dictionary):
	if is_instance_valid(relay_session):
		network.restore_migration(snapshot, remap, relay_session.peer)

func _migration_finished():
	loading_screen.stop_loading(100)
	network.finish_migration()

func set_dedicated_server(empty_timeout):
	hide_menus()
	host_server(true, empty_timeout)

func hide_menus():
	for node in get_tree().get_nodes_in_group("menu"):
		node.hide()

func _notification(n):
	if n == NOTIFICATION_WM_CLOSE_REQUEST:
		quit_program()

func _on_connect_pressed():
	join_lobby(lobby_line.text)

func _on_host_pressed():
	connect_direct(true)

func _on_join_pressed():
	connect_direct(false, address_line.text)

func _on_quit_pressed():
	quit_program()

func _on_quickstart_pressed():
	hide_menus()
	$top.show()
	singleplayer_focus.grab_focus()
	start_singleplayer()

func open_error_message(message):
	hide_menus()
	$message/Label.text = message
	$message.show()
	$message/Button.grab_focus()

func _on_load_pressed():
	hide_menus()
	$player_select/saves.refresh_saves()
	$player_select.show()
	$player_select.show()
	$back.show()
	$back.grab_focus()

func _on_multiplayer_pressed():
	hide_menus()
	$multiplayer.show()
	$back.show()
	$back.grab_focus()

func _on_options_pressed():
	hide_menus()
	$options.show()
	$back.show()
	$back.grab_focus()

func _on_back_pressed():
	if !is_instance_valid(network.current_map):
		close_relay_session()
		network.reset_to_offline_peer()
		loading_screen.stop_loading()
	if $options.is_visible_in_tree():
		global.save_options()
	hide_menus()
	$top.show()
	singleplayer_focus.grab_focus()

func _on_returned_pressed():
	hide()

func _on_save_pressed():
	global.save_options()

func _on_mouse_entered():
	sfx.play("item_select")


func _on_credits_pressed():
	hide_menus()
	$credits.show()
	$back.show()
	$back.grab_focus()
