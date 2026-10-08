extends Control

const SERVER_NAMES = [
	"Tetra-Force",
	"Sword-and-Bow",
	"Dungeon-of-Doom",
	"Pirate-Village",
	"Fire-and-Chain",
]

@export var _main: NodePath
@export var _button_container: NodePath

var main : Main
var button_container : Control

func _ready():
	main = get_node(_main)
	button_container = get_node(_button_container)
	
	for child in button_container.get_children():
		child.queue_free()
	
	for i in range(SERVER_NAMES.size()):
		var server_name = SERVER_NAMES[i]
		button_container.add_child(create_server_button("#%s %s" % [i+1, server_name],server_name))

func create_server_button(server_label : String, server_name : String) -> Node:
	var button = Button.new()
	button.connect("button_down", Callable(main, "join_lobby").bind(server_name))
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.text = server_label
	return button
