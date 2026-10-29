class_name RemotePlayer
extends Node2D
## Visual puppet for another player in an online co-op session.
## The local client owns its own Player; this node only mirrors the state that
## the remote peer sends over the network.

const SPRITE_SCRIPT := preload("res://Scripts/Parts/PlayerSprite.gd")
const NAME_FONT_SIZE := 8

var peer_id := 0
var display_name := "PLAYER"
var character := "Mario"
var power_state := "Small"
var reference: Player = null

var _sprite: AnimatedSprite2D
var _name_label: Label
var _resource_setter: ResourceSetterNew
var _target := Vector2.ZERO
var _has_target := false


func _ready() -> void:
	z_as_relative = false

	_resource_setter = ResourceSetterNew.new()
	_resource_setter.name = "ResourceSetter"
	add_child(_resource_setter)

	_sprite = AnimatedSprite2D.new()
	_sprite.name = "Sprite"
	_sprite.set_script(SPRITE_SCRIPT)
	_sprite.position = Vector2(0, -16)
	_sprite.resource_setter = _resource_setter
	add_child(_sprite)

	_name_label = Label.new()
	_name_label.name = "Name"
	_name_label.position = Vector2(-32, -46)
	_name_label.size = Vector2(64, 12)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
	_name_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_name_label.add_theme_constant_override("outline_size", 4)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_name_label)


func setup(id: int, pname: String) -> void:
	peer_id = id
	display_name = pname if pname != "" else "PLAYER"
	_name_label.text = display_name
	_refresh_sprite(true)


func _process(delta: float) -> void:
	if not _has_target:
		return
	if global_position.distance_to(_target) > 64.0:
		global_position = _target
	else:
		global_position = global_position.lerp(_target, clampf(delta * 22.0, 0.0, 1.0))


func apply_state(data: Dictionary) -> void:
	var new_name := str(data.get("n", display_name))
	if new_name != "" and new_name != display_name:
		display_name = new_name
		_name_label.text = display_name

	var new_character := str(data.get("c", character))
	var new_power := str(data.get("s", power_state))
	if new_character != character or new_power != power_state:
		character = new_character
		power_state = new_power
		_refresh_sprite(false)

	_target = Vector2(float(data.get("x", _target.x)), float(data.get("y", _target.y)))
	if not _has_target:
		global_position = _target
		_has_target = true

	_sprite.visible = int(data.get("v", 1)) == 1
	var flip := -1.0 if float(data.get("fx", 1)) < 0.0 else 1.0
	_sprite.scale.x = absf(_sprite.scale.x) * flip

	if _sprite.sprite_frames != null:
		var anim := StringName(str(data.get("a", "Idle")))
		if _sprite.sprite_frames.has_animation(anim):
			_sprite.animation = anim
		_sprite.frame = int(data.get("f", 0))

func _refresh_sprite(force_load: bool) -> void:
	if _sprite == null:
		return
	# PlayerSprite indexes Player.POWER_STATES with int(force_power_state), so we
	# have to hand it the numeric index ("1" for Big), not the name.
	var power_index := Player.POWER_STATES.find(power_state)
	if power_index < 0:
		power_index = 0
	_sprite.force_character = character
	_sprite.force_power_state = str(power_index)
	_sprite.update()
	# PlayerSprite computes its own offset from the texture height, which does
	# not match how the real player is drawn. Copy the local player's transform
	# so the puppet stands exactly where it should.
	if reference != null and is_instance_valid(reference) and reference.sprite != null:
		_sprite.position = reference.sprite.position
		_sprite.offset = reference.sprite.offset
