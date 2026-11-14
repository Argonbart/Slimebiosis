class_name SlimeTestLevel
extends Node2D
## Runs the slime test level with camera tracking and tuning controls.



const SETTINGS: Array[Array] = [
	["Ground friction", "friction", 0.0, 1.0, 0.01, "More grip converts spin into forward speed faster and increases rolling resistance."],
	["Movement speed", "move_speed", 50.0, 1000.0, 5.0, "Higher values let the slime build up more rolling speed."],
	["Jump bounce", "jump_speed", 100.0, 800.0, 5.0, "How high the slime jumps when you press Space."],
	["Stiffness", "shape_stiffness", 100.0, 800.0, 5.0, "Lower lets the slime deform more when squeezing through gaps."],
	["Size", "radius", 10.0, 100.0, 1.0, "Changes the body and its colliders."],
]

@export_category("Components")
@export var camera: Camera2D = null
@export var slime: Slime = null

@export_category("Settings")
@export var camera_min_x: float = 380.0
@export var camera_max_x: float = 2100.0
@export var follow_elevation: bool = false



# -------------------------------- GODOT FUNCTIONS ----------------------------------------


func _ready() -> void:
	_build_tuning_panel()


func _physics_process(_delta: float) -> void:
	camera.position.x = clampf(slime.get_center().x + 100.0, camera_min_x, camera_max_x)
	if follow_elevation:
		camera.position.y = slime.get_center().y - 100.0


# -------------------------------- LOCAL FUNCTIONS ----------------------------------------


func _build_tuning_panel() -> void:
	var layer: CanvasLayer = CanvasLayer.new()
	add_child(layer)
	var column: VBoxContainer = VBoxContainer.new()
	layer.add_child(column)
	column.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	column.offset_left = -268
	column.offset_right = -16
	column.offset_top = 16
	
	var toggle: Button = Button.new()
	toggle.text = "Slime settings"
	toggle.toggle_mode = true
	toggle.focus_mode = Control.FOCUS_NONE
	column.add_child(toggle)
	
	var panel: PanelContainer = PanelContainer.new()
	panel.hide()
	column.add_child(panel)
	toggle.toggled.connect(panel.set_visible)
	
	var rows: VBoxContainer = VBoxContainer.new()
	panel.add_child(rows)
	for setting: Array in SETTINGS:
		var caption: String = setting[0]
		var key: String = setting[1]
		var target: Node = slime.controls if key in ["move_speed", "jump_speed"] else slime
		
		var label: Label = Label.new()
		rows.add_child(label)
		var slider: HSlider = HSlider.new()
		slider.focus_mode = Control.FOCUS_NONE
		var current: float = target.get(key)
		slider.min_value = minf(setting[2], current)
		slider.max_value = maxf(setting[3], current)
		slider.step = setting[4]
		slider.value = current
		label.text = "%s  %s" % [caption, slider.value]
		rows.add_child(slider)
		var description: Label = Label.new()
		description.text = setting[5]
		description.custom_minimum_size.x = 232
		description.add_theme_font_size_override("font_size", 13)
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rows.add_child(description)
		slider.value_changed.connect(_update_setting.bind(key, caption, label))
	


func _update_setting(value: float, key: String, caption: String, label: Label) -> void:
	label.text = "%s  %s" % [caption, value]
	match key:
		"move_speed", "jump_speed":
			slime.controls.set(key, value)
		_:
			slime.set(key, value)
