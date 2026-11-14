class_name SlimeTestLevel
extends Node2D
## Runs the slime test level with camera tracking and live Verlet tuning.



@export_category("Components")
@export var camera: Camera2D = null
@export var slime: VerletSlime = null
@export var npc_slime: VerletSlime = null

@export_category("Settings")
@export var camera_min_x: float = 380.0
@export var camera_max_x: float = 2100.0
@export var follow_elevation: bool = false



# -------------------------------- GODOT FUNCTIONS ----------------------------------------


func _ready() -> void:
	_build_debug_menu(slime, "Slime settings", false)
	if npc_slime != null:
		_build_debug_menu(npc_slime, "NPC slime settings", true)


func _physics_process(_delta: float) -> void:
	camera.position.x = clampf(slime.get_center().x + 100.0, camera_min_x, camera_max_x)
	if follow_elevation:
		camera.position.y = slime.get_center().y - 100.0

# -------------------------------- LOCAL FUNCTIONS ----------------------------------------


func _build_debug_menu(target: VerletSlime, title: String, is_npc: bool) -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	add_child(layer)
	var column: VBoxContainer = VBoxContainer.new()
	layer.add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	column.offset_left = -280.0
	column.offset_right = -16.0
	column.offset_top = 16.0
	if is_npc:
		column.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		column.offset_left = 16.0
		column.offset_right = 280.0
		column.offset_top = 16.0
	
	var toggle: Button = Button.new()
	toggle.text = title
	toggle.toggle_mode = true
	column.add_child(toggle)
	
	var panel: PanelContainer = PanelContainer.new()
	panel.hide()
	column.add_child(panel)
	toggle.toggled.connect(panel.set_visible)
	
	var rows: VBoxContainer = VBoxContainer.new()
	panel.add_child(rows)
	_add_slider(rows, target, "Point count", "point_count", 8.0, 64.0, 1.0, "More points give the edge finer contact with terrain and cost more to simulate.")
	_add_slider(rows, target, "Movement speed", "drive_acceleration", 0.0, 5000.0, 50.0, "Higher values push harder against surfaces and build rolling speed faster.")
	_add_slider(rows, target, "Size", "radius", 12.0, 100.0, 1.0, "Changes the target radius and area.")
	_add_slider(rows, target, "Edge stiffness", "edge_strength", 0.0, 1.0, 0.01, "Higher values keep neighboring points closer to their resting distance.")
	var boost_key: String = "Up" if is_npc else "W"
	_add_slider(rows, target, "Edge boost (%s)" % boost_key, "edge_boost_multiplier", 0.01, 5000.0, 0.1, "Multiplies edge stiffness while you hold %s." % boost_key)


func _add_slider(rows: VBoxContainer, target: VerletSlime, caption: String, property: StringName, minimum: float, maximum: float, step: float, help: String) -> void:
	var label: Label = Label.new()
	rows.add_child(label)
	
	var slider: HSlider = HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = target.get(property)
	slider.focus_mode = Control.FOCUS_NONE
	rows.add_child(slider)
	label.text = "%s  %s" % [caption, slider.value]
	slider.value_changed.connect(_update_setting.bind(target, property, caption, label))
	
	var description: Label = Label.new()
	description.text = help
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.custom_minimum_size.x = 240.0
	rows.add_child(description)


func _update_setting(value: float, target: VerletSlime, property: StringName, caption: String, label: Label) -> void:
	if property == &"point_count":
		target.point_count = int(value)
	else:
		target.set(property, value)
	label.text = "%s  %s" % [caption, value]
