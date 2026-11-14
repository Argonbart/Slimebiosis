class_name SlimeTestLevel
extends Node2D
## Runs the slime test level with camera tracking and live Verlet tuning.



@export_category("Components")
@export var camera: Camera2D = null
@export var slime: VerletSlime = null
@export var thrown_slime: VerletSlime = null

@export_category("Settings")
@export var camera_min_x: float = 380.0
@export var camera_max_x: float = 2100.0
@export var follow_elevation: bool = false



# -------------------------------- GODOT FUNCTIONS ----------------------------------------


func _ready() -> void:
	_build_debug_menu()


func _physics_process(_delta: float) -> void:
	camera.position.x = clampf(slime.get_center().x + 100.0, camera_min_x, camera_max_x)
	if follow_elevation:
		camera.position.y = slime.get_center().y - 100.0

# -------------------------------- LOCAL FUNCTIONS ----------------------------------------


func _build_debug_menu() -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	add_child(layer)
	var column: VBoxContainer = VBoxContainer.new()
	layer.add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	column.offset_left = -280.0
	column.offset_right = -16.0
	column.offset_top = 16.0
	
	var toggle: Button = Button.new()
	toggle.text = "Slime settings"
	toggle.toggle_mode = true
	column.add_child(toggle)
	
	var panel: PanelContainer = PanelContainer.new()
	panel.hide()
	column.add_child(panel)
	toggle.toggled.connect(panel.set_visible)
	
	var rows: VBoxContainer = VBoxContainer.new()
	panel.add_child(rows)
	_add_slider(rows, "Points", "points", 8.0, 64.0, 1.0, "More points give finer contact with terrain.")
	_add_slider(rows, "Size", "size", 12.0, 500.0, 1.0, "Changes the target size and area.")
	_add_slider(rows, "Rigidity", "rigidity", 0.0, 1.0, 0.01, "Lower values let the slime squeeze and bend.")
	_add_slider(rows, "Speed", "speed", 0.0, 5000.0, 50.0, "Higher values build rolling speed faster.")
	_add_slider(rows, "Weight", "weight", 0.25, 4.0, 0.05, "How hard this slime is to rotate or throw when grabbed.")
	if thrown_slime != null:
		_add_slider(rows, "Held slime weight", "weight", 0.25, 4.0, 0.05, "Higher weight makes the held slime harder to rotate and throw.", thrown_slime)
	_add_slider(rows, "Strength", "strength", 0.0, 1500.0, 10.0, "More strength helps rotate held slimes and throw them faster.")


func _add_slider(rows: VBoxContainer, caption: String, property: StringName, minimum: float, maximum: float, step: float, help: String, target: VerletSlime = null) -> void:
	if target == null:
		target = slime
	
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
	if property == &"points":
		target.points = int(value)
	else:
		target.set(property, value)
	label.text = "%s  %s" % [caption, value]
