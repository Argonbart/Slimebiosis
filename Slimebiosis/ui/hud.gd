class_name Hud extends CanvasLayer
## Connection status, name entry, a network debug overlay (F3) and a debug
## panel with sliders for the local slime's synced parameters.

## Slider rows: caption, slime_stats column, min, max, step, description.
## The ranges mirror the *_RANGE constants on the server.
const STATS: Array[Array] = [
	["Weight", "weight", 0.2, 5.0, 0.1, "Heavy slimes are thrown less far and slow down whoever carries them."],
	["Size", "size", 24.0, 100.0, 1.0, "Radius of the body."],
	["Rotation speed", "rotation_speed", 500.0, 10000.0, 50.0, "Higher values push harder against surfaces and build rolling speed faster."],
	["Throw strength", "throw_strength", 100.0, 2000.0, 10.0, "Launch speed of a slime you throw (divided by its weight)."],
	["Jump strength", "jump_strength", 100.0, 1000.0, 5.0, "How hard the slime pushes off the ground."],
	["Softness", "softness", 0.0, 1.0, 0.01, "Soft slimes squash and wobble; stiff ones keep their round shape."],
]
## Slider changes are sent at most this often while dragging.
const STATS_SEND_INTERVAL := 0.1

var _status: Label
var _name: LineEdit
var _debug: Label
var _sliders: Dictionary[String, HSlider] = {}
var _slider_labels: Dictionary[String, Label] = {}
var _stats_dirty := false
var _stats_timer := 0.0
var _applying_stats := false # true while sliders are set from the server row

func _ready() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(12, 10)
	add_child(box)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 14)
	box.add_child(_status)

	_name = LineEdit.new()
	_name.placeholder_text = "your name (Enter)"
	_name.max_length = 16
	_name.custom_minimum_size = Vector2(170, 0)
	_name.text_submitted.connect(_on_name_submitted)
	box.add_child(_name)

	var hint := Label.new()
	hint.text = "roll A/D   jump Space   stiffen Shift   grab/throw E (with your face)   held: mash jump   net stats F3"
	hint.modulate = Color(1, 1, 1, 0.5)
	hint.add_theme_font_size_override("font_size", 12)
	box.add_child(hint)

	_debug = Label.new()
	_debug.add_theme_font_size_override("font_size", 12)
	_debug.visible = false
	box.add_child(_debug)

	_build_stats_panel()
	Net.stats_changed.connect(_on_stats)
	Net.status_changed.connect(_show_status)
	Net.player_changed.connect(_on_player)
	_show_status("offline (--offline)" if Net.offline else Net.status)

func _show_status(text: String) -> void:
	_status.text = "server: " + text

func _on_player(id: String, row: GamePlayer) -> void:
	if id == Net.local_id and not _name.has_focus():
		_name.text = row.name

func _on_name_submitted(text: String) -> void:
	_name.release_focus()
	Net.set_player_name(text)

func _build_stats_panel() -> void:
	var column := VBoxContainer.new()
	add_child(column)
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
	for stat: Array in STATS:
		var key: String = stat[1]
		var label := Label.new()
		rows.add_child(label)
		var slider := HSlider.new()
		slider.focus_mode = Control.FOCUS_NONE
		slider.min_value = stat[2]
		slider.max_value = stat[3]
		slider.step = stat[4]
		slider.editable = false # until the server row arrives
		rows.add_child(slider)
		var description := Label.new()
		description.text = stat[5]
		description.custom_minimum_size.x = 232
		description.add_theme_font_size_override("font_size", 12)
		description.modulate = Color(1, 1, 1, 0.6)
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rows.add_child(description)
		_sliders[key] = slider
		_slider_labels[key] = label
		label.text = "%s  -" % stat[0]
		slider.value_changed.connect(_on_slider.bind(stat[0], key))

func _on_slider(value: float, caption: String, key: String) -> void:
	_slider_labels[key].text = "%s  %s" % [caption, value]
	if not _applying_stats:
		_stats_dirty = true

## The server's row for our slime: the sliders follow it, except while the
## player is still changing them.
func _on_stats(id: String, row: GameSlimeStats) -> void:
	if id != Net.local_id or _stats_dirty:
		return
	_applying_stats = true
	for key: String in _sliders:
		_sliders[key].editable = true
		_sliders[key].value = row.get(key)
	_applying_stats = false

func _process(delta: float) -> void:
	_stats_timer += delta
	if _stats_dirty and _stats_timer >= STATS_SEND_INTERVAL:
		_stats_timer = 0.0
		_stats_dirty = false
		Net.set_stats(_sliders["weight"].value, _sliders["size"].value, _sliders["rotation_speed"].value,
			_sliders["throw_strength"].value, _sliders["jump_strength"].value, _sliders["softness"].value)
	if not _debug.visible:
		return
	var lines: PackedStringArray = []
	lines.append("round trip to server: %s   (we send up to every %d ms)" % [
		"measuring" if Net.rtt_ms < 0.0 else "%d ms" % Net.rtt_ms, NetSender.SEND_INTERVAL * 1000.0])
	for id in VerletSlime.registry:
		var slime := VerletSlime.registry[id]
		var puppet := slime.get_node_or_null("RemotePuppet") as RemotePuppet
		if puppet != null:
			lines.append("%s: %s" % [slime.display_name if slime.display_name != "" else id.left(8), puppet.debug_text()])
	_debug.text = "\n".join(lines)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_debug.visible = not _debug.visible
	# Clicking outside the name field gives the keyboard back to the slime.
	if event is InputEventMouseButton and event.pressed:
		_name.release_focus()
