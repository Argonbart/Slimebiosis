extends Node2D

const SLIME := preload("res://slime/slime.tscn")
const SETTINGS := [
	["Ground friction", "friction", 0.0, 1.0, 0.01, "More grip converts spin into forward speed faster and increases rolling resistance."],
	["Movement speed", "move_speed", 50.0, 1000.0, 5.0, "Higher values let the slime build up more rolling speed."],
	["Jump bounce", "jump_speed", 150.0, 650.0, 5.0, "How high the slime jumps when you press Space."],
	["Stiffness", "shape_stiffness", 100.0, 700.0, 5.0, "Lower lets the slime deform more when squeezing through gaps."],
	["Size (on respawn)", "radius", 24.0, 100.0, 1.0, "Changes the body and its colliders when you respawn."],
]

@export var camera_min_x := 380.0
@export var camera_max_x := 2100.0
@export var fall_limit := 740.0
@export var follow_elevation := false

var slime
var restart_held := false
var tuning: Dictionary = {}

func _ready() -> void:
	spawn_slime()
	build_tuning_panel()

func spawn_slime() -> void:
	if is_instance_valid(slime):
		remove_child(slime)
		slime.queue_free()
	slime = SLIME.instantiate()
	slime.position = $Start.position
	for key in tuning:
		var target = slime.get_node("Controls") if key in ["move_speed", "jump_speed"] else slime
		target.set(key, tuning[key])
	add_child(slime)

func _physics_process(_delta: float) -> void:
	var restart := Input.is_physical_key_pressed(KEY_R)
	if slime.center.y > fall_limit or (restart and not restart_held):
		spawn_slime()
	restart_held = restart
	$Camera2D.position.x = clampf(slime.center.x + 100.0, camera_min_x, camera_max_x)
	if follow_elevation:
		$Camera2D.position.y = slime.center.y - 100.0

func build_tuning_panel() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var column := VBoxContainer.new()
	layer.add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	column.offset_left = -268
	column.offset_right = -16
	column.offset_top = 16

	var toggle := Button.new()
	toggle.text = "Slime settings"
	toggle.toggle_mode = true
	toggle.focus_mode = Control.FOCUS_NONE
	column.add_child(toggle)

	var panel := PanelContainer.new()
	panel.hide()
	column.add_child(panel)
	toggle.toggled.connect(panel.set_visible)

	var rows := VBoxContainer.new()
	panel.add_child(rows)
	for setting in SETTINGS:
		var caption: String = setting[0]
		var key: String = setting[1]
		var target = slime.get_node("Controls") if key in ["move_speed", "jump_speed"] else slime

		var label := Label.new()
		rows.add_child(label)
		var slider := HSlider.new()
		slider.focus_mode = Control.FOCUS_NONE
		var current: float = target.get(key)
		slider.min_value = minf(setting[2], current)
		slider.max_value = maxf(setting[3], current)
		slider.step = setting[4]
		slider.value = current
		label.text = "%s  %s" % [caption, slider.value]
		rows.add_child(slider)
		var description := Label.new()
		description.text = setting[5]
		description.custom_minimum_size.x = 232
		description.add_theme_font_size_override("font_size", 13)
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rows.add_child(description)
		slider.value_changed.connect(update_setting.bind(key, caption, label))

	var respawn := Button.new()
	respawn.text = "Respawn slime"
	respawn.focus_mode = Control.FOCUS_NONE
	respawn.pressed.connect(func(): spawn_slime.call_deferred())
	rows.add_child(respawn)

func update_setting(value: float, key: String, caption: String, label: Label) -> void:
	tuning[key] = value
	label.text = "%s  %s" % [caption, value]
	match key:
		"radius":
			pass
		"move_speed", "jump_speed":
			slime.get_node("Controls").set(key, value)
		_:
			slime.set(key, value)
