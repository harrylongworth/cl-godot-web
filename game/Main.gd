extends Node2D

# Minimal interactive scene: a bouncing icon + an FPS/size readout.
# Just enough to confirm the engine actually runs in the browser.

var velocity := Vector2(180, 140)
@onready var sprite: Sprite2D = $Sprite
@onready var label: Label = $Label

func _process(delta: float) -> void:
	var rect := get_viewport_rect()
	sprite.position += velocity * delta

	if sprite.position.x < 32 or sprite.position.x > rect.size.x - 32:
		velocity.x = -velocity.x
	if sprite.position.y < 32 or sprite.position.y > rect.size.y - 32:
		velocity.y = -velocity.y

	sprite.position.x = clamp(sprite.position.x, 32, rect.size.x - 32)
	sprite.position.y = clamp(sprite.position.y, 32, rect.size.y - 32)

	label.text = "cl-godot-web · Godot %s\n%d FPS" % [
		Engine.get_version_info().string,
		Engine.get_frames_per_second(),
	]
