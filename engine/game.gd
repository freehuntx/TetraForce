extends Node

signal player_entered

var camera: Camera2D
@export var music = ""
@export var musicfx = ""
@export var light = "default"

var current_enemies = []

func is_game():
	return true

func _ready():
	network.current_map = self
	camera = preload("res://entities/player/camera.tscn").instantiate()
	add_child(camera)
	network.map_peers = []
	network.connect("refresh_player_request", Callable(self, "refresh_player"))
	
	if global.next_entrance == "":
		screenfx.play("fadewhite")
		screenfx.seek(10)
		var entrance_picker = preload("res://ui/main/entrances.tscn").instantiate()
		add_child(entrance_picker)
		entrance_picker.get_entrances(get_tree().get_nodes_in_group("entrances"))
		await entrance_picker.entrance_chosen
		entrance_picker.queue_free()
	
	add_new_player(network.pid)
	for player in network.player_list.keys():
		if player != network.pid and network.player_list[player] == name:
			add_new_player(player)
	# force the server to acknowledge this player's presence
	network.send_current_map() # starts player list updates
	screenfx.play("fadein")
	player_entered.connect(_on_player_entered)

func _process(delta): # can be on screen change instead of process
	if !network.is_map_host():
		return
	
	update_spiritpearls()
	
	var active_zones = []
	var active_enemies = []
	
	for player in get_tree().get_nodes_in_group("player"):
		var handler = player.get_node("ZoneHandler")
		if handler.get_overlapping_areas().size() > 0: 
			var player_zone = handler.get_overlapping_areas()[0]
			if !active_zones.has(player_zone):
				active_zones.append(player_zone)
	
	for zone in active_zones:
		for enemy in zone.get_enemies():
			active_enemies.append(enemy)
	
	for entity in get_tree().get_nodes_in_group("entity"):
		if entity is Player:
			continue
		if active_enemies.has(entity):
			entity.set_physics_process(true)
		else:
			entity.set_physics_process(false)
			if entity is Enemy:
				entity.position = entity.home_position

func add_new_player(id):
	if has_node(str(id)):
		refresh_player(id)
		return
	var new_player = preload("res://entities/player/player.tscn").instantiate()
	new_player.name = str(id)
	new_player.set_multiplayer_authority(id, true)
	
	add_child(new_player)
	new_player.camera = camera
	new_player.initialize()

	refresh_player(id)

func refresh_player(id):
	var player = get_node_or_null(str(id))
	if player == null or !(player is Player) or player.is_queued_for_deletion():
		return
	var profile = network.player_data.get(id)
	# Only the local avatar may use local options while awaiting its first
	# authoritative snapshot. Never apply them to somebody else's puppet.
	if profile == null and id == network.pid:
		profile = global.options.player_data
	if profile is Dictionary:
		player.sprite.texture = load(profile.skin)
		player.nametag.text = global.filter_value(profile.name)

func remove_player(id):
	if has_node(str(id)):
		get_node(str(id)).queue_free()
	for node in get_tree().get_nodes_in_group(str(id)):
		node.queue_free()

func update_puppets():
	var player_nodes = get_tree().get_nodes_in_group("player")
	var player_names = []
	for player in player_nodes:
		# first remove old players
		var id = int(player.name)
		if !network.map_peers.has(int(id)) && id != network.pid:
			remove_player(id)
		
		# add player names to array
		player_names.append(int(player.name))
	
	# match network peers to this new list of names
	for id in network.map_peers:
		if !player_names.has(id): # if there's fewer names than peers
			add_new_player(id) # add a new node for that name
	# A departure changes the roster without recreating surviving nodes.
	# Re-apply each survivor's own authoritative profile by its numeric ID.
	for id in network.current_players:
		refresh_player(id)

func _on_player_entered(id):
	return
	if id != network.pid:
		print("player ", id, " entered")

func pick_collectable():
	var choice = randi() % 4
	match choice:
		0:
			return "tetran"
		1:
			return "arrow"
		2:
			return "bomb"
		3:
			return "heart"

func spawn_collectable(collectable, pos, chance):
		if randi() % chance == 0:
			var path = str("res://entities/collectables/", pick_collectable(), ".tscn")
			if network.is_map_host():
				create_collectable(path, pos)
				network.peer_call(self, "create_collectable", [path, pos])
			
func create_collectable(path, pos):
		var new_collectable = load(path).instantiate()
		call_deferred("add_child", new_collectable)
		new_collectable.position = pos
		new_collectable.item_position.append(pos)
		network.add_to_state("collectables", str(pos))
		
func update_spiritpearls():
	if global.pearl.size() >= 4:
		global.max_health += 1
		global.player.hud.on_full_slate()
		network.states["pearl"].clear()
		global.pearl.clear()
		network.peer_call(self, "update_spiritpearls")
	global.emit_signal("debug_update")


