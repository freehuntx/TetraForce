extends StaticBody2D

@export var color = "blue"

@onready var animation = $AnimationPlayer

var _broken = false
var broken:
	get:
		return _broken
	set(value):
		if value:
			_broken = true
			animation.stop()
			$Sprite2D.frame = 4
			$CollisionShape2D.set_deferred("disabled", true)

func _ready():
	add_to_group("bombable")
	match color:
		"blue":
			$Sprite2D.texture = preload("res://tiles/post_smash_blue.png")
		"red":
			$Sprite2D.texture = preload("res://tiles/post_smash_red.png")
		"yellow":
			$Sprite2D.texture = preload("res://tiles/post_smash_yellow.png")

func cut(_hitbox):
	if _broken:
		return
	var foreground = global.player.spritedir != "Up"
	break_pot(foreground)
	network.peer_call(self, "break_pot", [foreground])

func bombed():
	break_pot()

func break_pot(foreground = false):
	if _broken:
		return
	_broken = true
	if foreground:
		z_index = 500
	animation.play("break")
	sfx.play("pot")
	network.current_map.spawn_collectable("tetran", position, 6)
