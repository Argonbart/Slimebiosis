extends Node
## Headless check that every column/argument type the game uses survives a
## round trip through the plugin and the server.
## Run: godot --headless --path . res://tests/roundtrip_test.tscn
## Requires a local server with the module published as "slimecrime".

const URL := "http://127.0.0.1:3000"
const DB := "slimecrime"
const TIMEOUT := 10.0

var _failures: Array[String] = []

func _ready() -> void:
	var code := await _run()
	for f in _failures:
		printerr("FAIL: ", f)
	print("roundtrip_test: %s" % ("PASSED" if code == 0 else "FAILED"))
	get_tree().quit(code)

func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures.append(what)

## Awaits `sig`, returns false on timeout.
func _wait(sig: Signal, what: String) -> bool:
	var state := {"done": false}
	sig.connect(func(..._args) -> void: state.done = true, CONNECT_ONE_SHOT)
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	while not state.done and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not state.done:
		_failures.append("timeout waiting for " + what)
	return state.done

func _run() -> int:
	var game := SpacetimeDB.Game
	game.token_save_path = "user://token_roundtrip_test.dat"
	var options := SpacetimeDBConnectionOptions.new()
	options.threading = false
	options.one_time_token = true

	game.connection_error.connect(func(c, r) -> void: _failures.append("connection_error %s %s" % [c, r]))
	game.connect_db(URL, DB, options)
	if not await _wait(game.connected, "connected"):
		return 1
	var me := game.get_local_identity()
	_check(me.size() == 32, "identity should be 32 bytes, got %d" % me.size())

	var sub := game.subscribe(["SELECT * FROM type_probe"])
	if not await _wait(sub.applied, "subscription applied"):
		return 1

	var id := randi() % 1000000 + 1
	var seen: Array[GameTypeProbe] = []
	var on_row := func(row: GameTypeProbe) -> void:
		if row.id == id:
			seen.append(row)
	game.db.type_probe.on_insert(on_row)
	game.db.type_probe.on_update(func(_old: GameTypeProbe, row: GameTypeProbe) -> void: on_row.call(row))

	# 1. insert with Some(identity)
	var target := PackedByteArray()
	target.resize(32)
	for i in 32:
		target[i] = i + 1
	var pos := Vector2(123.5, -45.25)
	var before_us := int(Time.get_unix_time_from_system() * 1_000_000)
	var shape := PackedByteArray()
	for i in 32:
		shape.append((i * 17 + 200) % 256) # includes bytes above 127
	var call1 := game.reducers.probe(id, pos, -1, 3, 4000000000, target, true, -2.5, shape)
	var errors: Array[String] = []
	call1.on_error.connect(func(e: String) -> void: errors.append(e))
	if not await _wait_rows(seen, 1):
		return 1
	var row := seen[0]
	_check(errors.is_empty(), "probe returned error: %s" % str(errors))
	_check(row.owner == me, "owner != local identity")
	_check(row.pos == pos, "pos %s != %s" % [row.pos, pos])
	_check(row.facing == -1, "facing %d != -1" % row.facing)
	_check(row.mode == 3, "mode %d != 3" % row.mode)
	_check(row.seq == 4000000000, "seq %d != 4000000000" % row.seq)
	_check(row.held_by != null and row.held_by.is_some(), "held_by should be Some")
	if row.held_by != null and row.held_by.is_some():
		_check(row.held_by.unwrap() == target, "held_by payload mismatch")
	_check(row.angle == -2.5, "angle %s != -2.5" % row.angle)
	_check(row.shape is PackedByteArray and row.shape == shape, "shape bytes mismatch: %s" % str(row.shape))
	_check(absi(row.at - before_us) < 60_000_000, "timestamp off: %d vs %d" % [row.at, before_us])

	# 2. same primary key again with None -> must arrive as a row for the same id
	game.reducers.probe(id, Vector2.ZERO, 1, 0, 0, target, false, 0.0, PackedByteArray())
	if not await _wait_rows(seen, 2):
		return 1
	row = seen[1]
	_check(row.held_by != null and row.held_by.is_none(), "held_by should be None")
	_check(row.pos == Vector2.ZERO and row.facing == 1 and row.mode == 0, "second write fields wrong")
	_check(row.shape.is_empty(), "empty shape should stay empty")
	_check(game.db.type_probe.id.find(id) != null, "unique index find() returned null")

	# 3. reducer error surfaces through on_error
	var call3 := game.reducers.probe(id, Vector2.ZERO, 1, 9, 0, target, false, 0.0, PackedByteArray())
	var err_text := {"v": ""}
	call3.on_error.connect(func(e: String) -> void: err_text.v = e)
	await _wait(call3.response, "error response")
	_check("invalid mode" in err_text.v, "expected 'invalid mode' error, got '%s'" % err_text.v)

	game.disconnect_db()
	return 0 if _failures.is_empty() else 1

func _wait_rows(seen: Array, count: int) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	while seen.size() < count and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if seen.size() < count:
		_failures.append("timeout waiting for row #%d" % count)
		return false
	return true
