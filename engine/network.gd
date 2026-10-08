extends Node

const CONNECTION_TIMEOUT = 5

var pid = 1

var dedicated = false

var current_map = null
var player_list = {} # player, map -- every active player and what map they're in
var map_hosts = {} # map, player -- every active map and which player is hosting it

var validated_players = []
var current_players = []
var map_peers = []

var tick
var tick_time = 0.05

var empty_timeout = 0
var empty_timeout_timer

signal received_player_list
signal refresh_player_request(player_id)

var player_data = {}
var player_identities = {}
var _roster_revision = 0
var _received_roster_revision = -1
var migrating = false
var _migration_process_mode = Node.PROCESS_MODE_INHERIT

var state

# save stuff
# states[nodepath] = properties
@export var states = {
	weapons = [],
	items = [],
	pearl = [],
	collectables = [],
}

func _ready():
	set_process(false)
	multiplayer.peer_connected.connect(_player_connected)
	multiplayer.peer_disconnected.connect(_player_disconnected)
	states.weapons = global.weapons
	states.items = global.items
	states.pearl = global.pearl



func clean_session_data():
	migrating = false
	global.clean_session_data()
	states = {
		weapons = global.weapons,
		items = global.items,
		pearl = global.pearl,
		collectables = [],
	}
	current_players = []
	map_peers = []
	player_list = {}
	map_hosts = {}
	validated_players.clear()
	player_data.clear()
	player_identities.clear()
	_roster_revision = 0
	_received_roster_revision = -1

func reset_to_offline_peer():
	if multiplayer.multiplayer_peer is FreelayMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func complete(include_network = true):
	stop_empty_timeout()
	for child in get_children():
		if child.name.begins_with("connection_timer_"):
			child.queue_free()
	if is_instance_valid(tick):
		tick.stop()
		tick.queue_free()
	if is_instance_valid(current_map):
		current_map.process_mode = Node.PROCESS_MODE_DISABLED
		current_map.queue_free()
	if include_network:
		call_deferred("reset_to_offline_peer")
	clean_session_data()
	current_map = null
	dedicated = false
	empty_timeout = 0
	pid = MultiplayerPeer.TARGET_PEER_SERVER

func initialize():
	if !multiplayer.has_multiplayer_peer():
		reset_to_offline_peer()
	tick = Timer.new()
	add_child(tick)
	tick.wait_time = tick_time # 1/20 of a second
	tick.one_shot = false
	tick.start()
	
	if multiplayer.is_server() && !dedicated:
		player_data[1] = global.options.player_data.duplicate(true)
	elif !dedicated:
		pid = multiplayer.get_unique_id()
		rpc_id(1, "_receive_my_player_data", global.options.player_data)
	
	start_empty_timeout()
	
	await get_tree().create_timer(0.1).timeout
	
	global.emit_signal("debug_update")
	
@rpc("any_peer", "call_remote", "reliable") func _receive_my_player_data(data):
	if !multiplayer.is_server() or !(data is Dictionary):
		return
	var player_id = multiplayer.get_remote_sender_id()
	if !(data.get("name") is String) or !(data.get("skin") is String):
		kick_player(player_id, "Invalid player data.")
		return
	if !(data.skin in ["res://entities/player/chain.png", "res://entities/player/knot.png", "res://entities/player/key.png"]):
		data.skin = global.options.player_data.skin
	data.name = global.filter_value(data.name.left(64))
	player_data[player_id] = data.duplicate(true)
	refresh_player_request.emit(player_id)
	validated_players.append(player_id)
	broadcast_player_roster()
	rpc_id(player_id, "_receive_session_states", states)
	print(str(get_player_tag(player_id), " joined the game."))

@rpc("authority", "call_remote", "reliable") func _receive_session_states(data):
	states = data
	for key in ["weapons", "items", "pearl"]:
		global.set(key, states.get(key, []))
	if is_instance_valid(current_map):
		for node in get_tree().get_nodes_in_group("maphost"):
			if node.has_node("NetworkObject") and node.get_node("NetworkObject").persistent:
				request_persistent_state(node)

func get_player_tag(id):
	return str(player_data.get(id, {}).get("name", "Player"), " (", id, ")")
	
func kick_player(id, reason):
	if is_multiplayer_authority():
		print(get_player_tag(id), " kicked: ", reason)
		multiplayer.multiplayer_peer.disconnect_peer(id)
	else:
		print("Tried to kick as a client?")

### PLAYER LIST UPDATES ###
# super important. list of every player in the game & what map they're in
#
# 1) client connects
# 2) client sends id and map to server
# 3) server adds id and map as a key/value pair in player_list dictionary
# 4) server sends player_list to every client
# 5) update_players() gives network.gd a list of all players in current room
#    and a list of all OTHER players in current room (current_players & map peers)
# 6) game.gd then takes this list of players, compares it to the player nodes
#    it has in the room, removes the ones that are no longer there, and adds
#    the ones that have just entered

func send_current_map(): # called when a player enters a new map
	if multiplayer.is_server():
		if !dedicated:
			# server adds itself to the list and updates everyone
			_receive_current_map(1, current_map.name)
	else:
		# every one else first sends their information to the server, and then it updates everyone
		rpc_id(1, "_receive_current_map", pid, current_map.name)

@rpc("any_peer", "call_remote", "reliable") func _receive_current_map(id, map): # server receives map from client
	if !multiplayer.is_server():
		return
	var sender = multiplayer.get_remote_sender_id()
	if sender != 0 and (id != sender or !(id in validated_players)):
		return
	player_list[id] = map
	stop_empty_timeout()
	update_map_hosts()
	update_players() # server updates its own map peers
	emit_signal("received_player_list")
	broadcast_player_roster()

func broadcast_player_roster():
	if !multiplayer.is_server():
		return
	_roster_revision += 1
	# The map roster and its profiles must arrive as one snapshot. MQTT/RTC
	# upgrades can delay an older reliable message behind a newer one.
	rpc("_receive_player_list", player_list, map_hosts, player_data, _roster_revision)

@rpc("authority", "call_remote", "reliable") func _receive_player_list(list, hosts, profiles, revision):
	if revision <= _received_roster_revision:
		return
	_received_roster_revision = revision
	player_list = list.duplicate(true)
	map_hosts = hosts.duplicate(true)
	player_data = profiles.duplicate(true)
	update_players() # client updates map peers
	emit_signal("received_player_list")

func update_players(): # gets list of all players in map AND all other players
	if dedicated or !is_instance_valid(current_map):
		return
	current_players = []
	map_peers = []
	# get all players in current_map
	for id in player_list:
		if player_list.get(id) == player_list.get(pid):
			current_players.append(id)
	# get all players besides self in current_map
	for player in current_players:
		if player != pid:
			map_peers.append(player)
	
	# *** IMPORTANT *** #
	# this is where game.gd gets that information and updates the puppets
	current_map.update_puppets()
	
	# set network masters
	for node in get_tree().get_nodes_in_group("maphost"):
		node.set_multiplayer_authority(map_hosts.get(network.current_map.name, pid))

func update_map_hosts():
	for map in player_list.values():
		if !map_hosts.keys().has(map):
			map_hosts[map] = player_list.keys()[player_list.values().find(map)]
	
	# remove old maps
	for map in map_hosts.keys():
		if !player_list.values().has(map):
			map_hosts.erase(map)
	
	# reassign owners
	for map in map_hosts.keys():
		var map_host = map_hosts.get(map)
		if player_list.get(map_host) != map:
			map_hosts[map] = player_list.keys()[player_list.values().find(map)]

func _player_disconnected(id): # remove disconnected players from player_list
	if migrating:
		return
	if multiplayer.is_server():
		print(str(get_player_tag(id), " left the game."))
		player_list.erase(id)
		player_data.erase(id)
		player_identities.erase(id)
		validated_players.erase(id)
		start_empty_timeout()
		update_map_hosts()
		broadcast_player_roster()
		update_players()
	else:
		player_data.erase(id)
		player_identities.erase(id)

func _player_connected(id):
	if migrating:
		return
	if multiplayer.is_server():
		if multiplayer.multiplayer_peer is FreelayMultiplayerPeer:
			player_identities[id] = multiplayer.multiplayer_peer.identities.get(id, "")
		start_connection_timeout(id)

func is_map_host():
	if not current_map:
		return false

	if !map_hosts.keys().has(current_map.name):
		return false
	if map_hosts.get(current_map.name) == pid:
		return true
	return false

func get_map_host():
	return map_hosts.get(current_map.name)
	
func persistent_set_state(object, properties):
	var nodepath = object
	if pid == 1:
		states[nodepath] = properties
		rpc("_receive_state_change", nodepath, properties)
		global.emit_signal("debug_update")
	else:
		rpc_id(1, "_receive_state_change", nodepath, properties)

@rpc("any_peer", "call_remote", "reliable") func set_state(path, properties):
	if pid == 1:
		states[path] = properties
		rpc("_receive_state_array", path, properties)
		if path in ["weapons", "items", "pearl"]:
			global.set(path, properties)
		global.emit_signal("debug_update")
	else:
		rpc_id(1, "set_state", path, properties)

@rpc("any_peer", "call_remote", "reliable") func add_to_state(state, value):
	if migrating:
		return
	if pid != 1:
		rpc_id(1, "add_to_state", state, value)
		return
	if !(states.get(state) is Array):
		return
	if !states.get(state).has(value) || states.get(state).has("Spiritpearl"):
		states.get(state).append(value)
		set_state(state, states.get(state))

@rpc("any_peer", "call_remote", "reliable") func _receive_state_change(nodepath, properties):
	if !multiplayer.is_server() and multiplayer.get_remote_sender_id() != 1:
		return
	states[nodepath] = properties
	if multiplayer.is_server():
		rpc("_receive_state_change", nodepath, properties)
	global.emit_signal("debug_update")
	
@rpc("authority", "call_remote", "reliable") func _receive_state_array(state, value):
	states[state] = value
	if state in ["weapons", "items", "pearl"]:
		global.set(state, value)
	global.emit_signal("debug_update")

func request_persistent_state(object):
	if migrating:
		return
	var nodepath = str(object.get_path())
	if pid == 1:
		var properties = states.get(nodepath, {})
		update_state(nodepath, properties)
	else:
		rpc_id(1, "_receive_state_request", nodepath)

@rpc("any_peer", "call_remote", "reliable") func _receive_state_request(nodepath):
	if !multiplayer.is_server():
		return
	var properties = states.get(nodepath, {})
	rpc_id(multiplayer.get_remote_sender_id(), "_receive_state", nodepath, properties)

@rpc("authority", "call_remote", "reliable") func _receive_state(nodepath, properties):
	update_state(nodepath, properties)

func update_state(nodepath, properties):
	var node = get_node_or_null(nodepath)
	if node == null or !(properties is Dictionary):
		return
	for property in properties.keys():
		node.set(property, properties[property])

func peer_call(object, function, arguments = []):
	for peer in map_peers:
		peer_call_id(peer, object, function, arguments)

func peer_call_unreliable(object, function, arguments = []):
	if migrating:
		return
	for peer in map_peers:
		if peer in multiplayer.get_peers():
			rpc_id(peer, "_pc_unreliable", object.get_path(), function, arguments)

func peer_call_id(id, object, function, arguments = []):
	if migrating:
		return
	if !(arguments is Array):
		arguments = [arguments]
	if id == pid:
		_call_network_method(object.get_path(), function, arguments)
		return
	if !(id in multiplayer.get_peers()):
		return
	rpc_id(id, "_pc", object.get_path(), function, arguments)

func peer_create_id(id, object_path, object_name, object_parent):
	if migrating or !(id in multiplayer.get_peers()):
		return
	rpc_id(id, "_create_object", object_path, object_name, object_parent)

@rpc("any_peer", "call_remote", "reliable") func _create_object(object_path, object_name, object_parent):
	var parent = get_node_or_null(object_parent)
	if not parent or parent.has_node(NodePath(object_name)):
		return
	var new_object = load(object_path).instantiate()
	new_object.name = object_name
	new_object.set_multiplayer_authority(multiplayer.get_remote_sender_id())
	parent.add_child(new_object)
	peer_call_id(multiplayer.get_remote_sender_id(), new_object.get_node("NetworkObject"), "update_enter_properties", [pid])

func validate_object_id(id, object, question, function):
	rpc_id(id, "_check_object", object.get_path(), question, function)

@rpc("any_peer", "call_remote", "reliable") func _check_object(object, question, function):
	if has_node(object) == question:
		rpc_id(multiplayer.get_remote_sender_id(), "_pc", object, function)

@rpc("any_peer", "call_remote", "reliable") func _pc(object, function, arguments = []):
	_call_network_method(object, function, arguments)

@rpc("any_peer", "call_remote", "unreliable") func _pc_unreliable(object, function, arguments = []):
	_call_network_method(object, function, arguments)

func _call_network_method(object, function, arguments = []):
	if has_node(object):
		if get_node(object).has_method(function):
			get_node(object).callv(function, arguments)
		else:
			print("object ", get_node(object).name, " does not have method ", function)

func start_empty_timeout():
	if empty_timeout == 0 || player_list.size() > 0 || empty_timeout_timer:
		#print("not starting empty_timeout timer")
		return
	
	print("starting empty_timeout timer")

	empty_timeout_timer = Timer.new()
	add_child(empty_timeout_timer)
	empty_timeout_timer.wait_time = empty_timeout
	empty_timeout_timer.connect("timeout", Callable(self, "_empty_timeout"))
	empty_timeout_timer.start()

func stop_empty_timeout():
	if !empty_timeout_timer:
		#print("not stopping empty_timeout timer")
		return

	print("stopping empty_timeout timer")
	
	empty_timeout_timer.stop()
	empty_timeout_timer.queue_free()
	empty_timeout_timer = null

func _empty_timeout():
	print("empty_timeout timer timed out")
	if player_list.size() > 0:
		stop_empty_timeout()
		return
	
	print("no players after empty-server-timeout=%d, stopping server" % empty_timeout)
	get_tree().quit()

func start_connection_timeout(id):
	var connection_timer = Timer.new()
	connection_timer.name = "connection_timer_%s" % id
	connection_timer.connect("timeout", Callable(self, "_connection_timer_timeout").bind(id))
	add_child(connection_timer)
	connection_timer.start(CONNECTION_TIMEOUT)

func _connection_timer_timeout(id):
	var connection_timer = get_node_or_null("connection_timer_%s" % id)
	if connection_timer:
		if id in multiplayer.get_peers():
			if not id in validated_players:
				kick_player(id, "Did not receive player data!")
			if not id in player_data:
				kick_player(id, "Did not receive player data!")
			if not id in player_identities:
				kick_player(id, "Did not receive Freelay identity!")
		connection_timer.queue_free()
	else:
		if id in multiplayer.get_peers():
			kick_player(id, "Failed to find connection timer!")

# Migration snapshots use map-relative paths so player IDs can be remapped
# without touching SceneMultiplayer's old RPC/path caches.
func capture_migration_world() -> Dictionary:
	if !is_instance_valid(current_map):
		return {}
	var objects = {}
	_capture_migration_nodes(current_map, objects)
	return {"map": str(current_map.name), "objects": objects}

func _capture_migration_nodes(parent: Node, objects: Dictionary):
	for node in parent.get_children():
		if node.has_node("NetworkObject"):
			var sync = node.get_node("NetworkObject")
			var properties = {}
			for key in sync.enter_properties.keys() + sync.update_properties.keys():
				properties[str(key)] = node.get(str(key))
			if node is Node2D:
				properties.position = node.position
			if node is Entity:
				properties.merge({"_health": node._health, "MAX_HEALTH": node.MAX_HEALTH, "home_position": node.home_position, "last_safe_pos": node.last_safe_pos}, true)
			objects[str(current_map.get_path_to(node))] = {"scene": node.scene_file_path, "properties": properties, "authority": node.get_multiplayer_authority()}
		_capture_migration_nodes(node, objects)

func capture_migration_snapshot(worlds: Dictionary) -> Dictionary:
	return {"players": player_list.duplicate(true), "profiles": player_data.duplicate(true), "map_hosts": map_hosts.duplicate(true), "states": states.duplicate(true), "worlds": worlds.duplicate(true)}

func begin_migration():
	if migrating:
		return
	migrating = true
	if is_instance_valid(tick):
		tick.stop()
	if is_instance_valid(current_map):
		_migration_process_mode = current_map.process_mode
		current_map.process_mode = Node.PROCESS_MODE_DISABLED
	for child in get_children():
		if child.name.begins_with("connection_timer_"):
			child.queue_free()

func restore_migration(snapshot: Dictionary, remap: Dictionary, peer: FreelayMultiplayerPeer):
	begin_migration()
	# Remove the old host before renaming the successor to 1. Keep the local
	# player node (and its HUD/camera) alive throughout the handover.
	if is_instance_valid(current_map):
		for node in get_tree().get_nodes_in_group("player"):
			var old_id = int(node.name)
			if !remap.has(old_id):
				node.free()
		for node in get_tree().get_nodes_in_group("player"):
			var old_id = int(node.name)
			if remap.has(old_id):
				node.name = str(remap[old_id])
				node.set_multiplayer_authority(remap[old_id], true)
		_remap_migration_groups(get_tree().root, remap)
	pid = peer.get_unique_id()
	dedicated = false
	empty_timeout = 0
	player_list = _remap_migration_dictionary(snapshot.get("players", {}), remap)
	player_data = _remap_migration_dictionary(snapshot.get("profiles", {}), remap)
	# reserved_ids is identity -> ID; network exposes the inverse.
	player_identities.clear()
	for identity in peer.reserved_ids:
		player_identities[peer.reserved_ids[identity]] = identity
	validated_players = player_data.keys()
	map_hosts = snapshot.get("map_hosts", {}).duplicate(true)
	for map in map_hosts:
		map_hosts[map] = remap.get(map_hosts[map], 0)
	update_map_hosts()
	states = snapshot.get("states", {}).duplicate(true)
	for key in ["weapons", "items", "pearl"]:
		global.set(key, states.get(key, []))
	_roster_revision = 0
	_received_roster_revision = -1
	if is_instance_valid(current_map):
		var world = snapshot.get("worlds", {}).get(str(current_map.name), {})
		_restore_migration_world(world, remap)
		update_players()
		for node in get_tree().get_nodes_in_group("maphost"):
			node.set_multiplayer_authority(map_hosts.get(str(current_map.name), pid))

func _remap_migration_dictionary(source: Dictionary, remap: Dictionary) -> Dictionary:
	var result = {}
	for id in source:
		if remap.has(id):
			result[remap[id]] = source[id]
	return result

func _remap_migration_groups(node: Node, remap: Dictionary):
	for group in node.get_groups():
		if str(group).is_valid_int():
			node.remove_from_group(group)
			if remap.has(int(group)):
				node.add_to_group(str(remap[int(group)]))
	for child in node.get_children():
		_remap_migration_groups(child, remap)

func _restore_migration_world(world: Dictionary, remap: Dictionary):
	var objects: Dictionary = world.get("objects", {})
	var paths = objects.keys()
	paths.sort() # Parents precede children.
	var expected = {}
	for old_path in paths:
		var parts = str(old_path).split("/")
		if parts[0].is_valid_int():
			if !remap.has(int(parts[0])):
				continue
			parts[0] = str(remap[int(parts[0])])
		expected["/".join(parts)] = true
	if !objects.is_empty():
		var existing = {}
		_capture_migration_nodes(current_map, existing)
		for path in existing:
			if !expected.has(path):
				var node = current_map.get_node_or_null(NodePath(path))
				if node != null:
					node.free()
	for old_path in paths:
		var parts = str(old_path).split("/")
		if parts[0].is_valid_int():
			if !remap.has(int(parts[0])):
				continue
			parts[0] = str(remap[int(parts[0])])
		var path = "/".join(parts)
		var node = current_map.get_node_or_null(NodePath(path))
		var entry: Dictionary = objects[old_path]
		if node == null and !str(entry.get("scene", "")).is_empty():
			var parent_path = path.get_base_dir()
			var parent = current_map if parent_path.is_empty() else current_map.get_node_or_null(NodePath(parent_path))
			if parent != null and ResourceLoader.exists(entry.scene):
				node = load(entry.scene).instantiate()
				node.name = NodePath(path).get_name(NodePath(path).get_name_count() - 1)
				node.set_multiplayer_authority(remap.get(entry.get("authority", 1), pid), true)
				parent.add_child(node)
		if node != null:
			if !(node is Player):
				node.set_multiplayer_authority(map_hosts.get(str(current_map.name), pid), true)
			for key in entry.get("properties", {}):
				node.set(key, entry.properties[key])
			if node is Entity:
				node._pos = node.position
				if node == global.player:
					global.health = node._health
					global.max_health = node.MAX_HEALTH
					node.health_changed.emit()
					node.update_count.emit()

func finish_migration():
	migrating = false
	if is_instance_valid(current_map):
		current_map.process_mode = _migration_process_mode
	if is_instance_valid(tick):
		tick.start()
	if multiplayer.is_server():
		broadcast_player_roster()
	global.emit_signal("debug_update")

func trim_migration_players(ids: Array):
	for id in player_list.keys():
		if !(id in ids):
			player_list.erase(id)
			player_data.erase(id)
			player_identities.erase(id)
			validated_players.erase(id)
	update_map_hosts()
	update_players()
	if is_instance_valid(current_map):
		_set_migration_map_authorities(current_map)

func _set_migration_map_authorities(parent: Node):
	for node in parent.get_children():
		if node is Player:
			continue
		if node.has_node("NetworkObject"):
			node.set_multiplayer_authority(map_hosts.get(str(current_map.name), pid), true)
		_set_migration_map_authorities(node)
