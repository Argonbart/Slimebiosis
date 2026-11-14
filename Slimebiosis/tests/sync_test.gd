extends Node
## Headless end-to-end sync check: the real sandbox (client A, through Net)
## plus a second raw client B in the same process.
## Run: godot --headless --path . --fixed-fps 60 res://tests/sync_test.tscn
## Requires a local server with the module published as "slimecrime".

const TIMEOUT := 10.0

var _failures: Array[String] = []

func _ready() -> void:
	await _run()
	for f in _failures:
		printerr("FAIL: ", f)
	print("sync_test: %s" % ("PASSED" if _failures.is_empty() else "FAILED"))
	get_tree().quit(0 if _failures.is_empty() else 1)

func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures.append(what)

## Polls `cond` every frame; records a failure on timeout.
func _until(cond: Callable, what: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await get_tree().process_frame
	_failures.append("timeout: " + what)
	return false

## A recognisable squashed ring in the wire format: 32 points, 2 signed bytes each.
func _squashed_shape() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(64)
	for i in 32:
		var p := Vector2.from_angle(TAU * i / 32.0) * Vector2(70.0, 40.0)
		bytes.encode_s8(i * 2, roundi(p.x))
		bytes.encode_s8(i * 2 + 1, roundi(p.y))
	return bytes

## Largest difference between two shapes in wire units. The soft body never
## rests completely, so a sent shape is compared loosely.
func _shape_error(a: PackedByteArray, b: PackedByteArray) -> int:
	if a.size() != b.size():
		return 255
	var worst := 0
	for i in a.size():
		worst = maxi(worst, absi(a.decode_s8(i) - b.decode_s8(i)))
	return worst

func _run() -> void:
	# --- client A: the real game
	Net.token_path = "user://token_sync_test_a.dat"
	Net.one_time_token = true
	Net.offline = false
	Net.url = Net.LOCAL_URL
	Net.database = Net.LOCAL_DB
	var sandbox: Node2D = load("res://world/sandbox.tscn").instantiate()
	add_child(sandbox)
	if not await _until(func() -> bool: return Net.is_ready, "Net ready"):
		return
	var a_slime: VerletSlime = sandbox.local_slime
	_check(Net.local_state() != null, "A should have a slime_state row")
	_check(not a_slime.display_name.is_empty(), "A's slime should show its player name")
	_check(Net.stats.has(Net.local_id), "A should have a slime_stats row")
	_check(a_slime.radius == 40.0 and a_slime.drive_acceleration == 5000.0 and a_slime.jump_strength == 400.0
		and a_slime.weight == 1.0 and a_slime.throw_strength == 780.0 and a_slime.edge_strength == 0.5,
		"A's slime takes its parameters from slime_stats")

	# --- client B: a bare module client
	var b: GameModuleClient = load("res://spacetime_bindings/schema/module_game_client.gd").new()
	b.token_save_path = "user://token_sync_test_b.dat"
	add_child(b)
	var options := SpacetimeDBConnectionOptions.new()
	options.threading = false
	options.one_time_token = true
	var b_connected := {"v": false}
	b.connected.connect(func(_i, _t) -> void: b_connected.v = true)
	b.connect_db(Net.url, Net.database, options)
	if not await _until(func() -> bool: return b_connected.v, "B connected"):
		return
	var b_id := Net.id_of(b.get_local_identity())
	_check(b_id != Net.local_id, "A and B must have different identities")
	var sub := b.subscribe(Net.QUERIES)
	if not await _until(func() -> bool: return sub.active, "B subscribed"):
		return

	# --- B sees A's slime where A actually is
	var a_row_ok := func() -> bool:
		var row: GameSlimeTransform = b.db.slime_transform.identity.find(Net.local_identity)
		return row != null and row.pos.distance_to(a_slime.position) < 3.0 and _shape_error(row.shape, a_slime.pack_shape()) <= 3 \
			and absf(angle_difference(row.angle, a_slime.angle)) < 0.05
	await _until(a_row_ok, "B sees A's resting transform")

	# --- A moves: B's copy follows
	var a_x0 := a_slime.position.x
	Input.action_press("move_right")
	await get_tree().create_timer(0.5).timeout
	Input.action_release("move_right")
	_check(a_slime.position.x > a_x0 + 30.0, "A rolled away from its spawn point, moved %.1f" % (a_slime.position.x - a_x0))
	await _until(a_row_ok, "B sees A's transform after A moved")

	# --- B moves: a puppet appears in A's world and follows with interpolation
	var spawner: SlimeSpawner = sandbox.spawner
	_check(not spawner.puppets.has(b_id), "no puppet for B before B sends a transform")
	var p := Vector2(500.0, 300.0)
	var shape := _squashed_shape()
	b.reducers.update_slime(p, Vector2(200, 0), 0.0, 4.0, shape)
	await _until(func() -> bool: return spawner.puppets.has(b_id), "puppet for B spawned")
	for i in 10:
		await get_tree().create_timer(0.05).timeout
		p.x += 10.0
		b.reducers.update_slime(p, Vector2(200, 0), 0.2 * (i + 1), 4.0, shape)
	b.reducers.update_slime(p, Vector2.ZERO, 2.5, 0.0, shape)
	if spawner.puppets.has(b_id):
		var puppet: VerletSlime = spawner.puppets[b_id]
		_check(not puppet.simulated, "remote slimes are not simulated")
		_check(puppet.radius == 40.0, "puppet takes its radius from slime_stats")
		await _until(func() -> bool: return puppet.position.distance_to(p) < 1.0 and absf(angle_difference(puppet.angle, 2.5)) < 0.01,
			"puppet settles at B's last position and rotation")
		_check(puppet.pack_shape() == shape, "puppet shows the shape B sent")
		_check(puppet.display_name.begins_with("slime-"), "puppet shows default name, got '%s'" % puppet.display_name)

		# --- rename propagates
		b.reducers.set_name("  Bob  ")
		await _until(func() -> bool: return puppet.display_name == "Bob", "rename reaches A's puppet")

		# --- debug tuning: B resizes itself, A's puppet of B follows
		b.reducers.set_stats(1.0, 60.0, 5000.0, 780.0, 400.0, 0.5)
		await _until(func() -> bool: return puppet.radius == 60.0, "B's new radius reaches A's puppet")

	# --- debug tuning of the own slime, as the HUD sliders do it; out-of-range values are clamped
	Net.set_stats(2.5, 52.0, 7000.0, 1200.0, 5000.0, -3.0)
	await _until(func() -> bool: return a_slime.radius == 52.0, "A's slime takes the new radius")
	_check(a_slime.weight == 2.5, "A's weight changed, got %.1f" % a_slime.weight)
	_check(a_slime.drive_acceleration == 7000.0, "A's rotation speed changed, got %.1f" % a_slime.drive_acceleration)
	_check(a_slime.jump_strength == 1000.0, "jump is clamped to the maximum, got %.1f" % a_slime.jump_strength)
	_check(a_slime.edge_strength == 1.0, "softness is clamped to the minimum (a stiff rim), got %.2f" % a_slime.edge_strength)
	var a_stats: GameSlimeStats = b.db.slime_stats.identity.find(Net.local_identity)
	_check(a_stats != null and a_stats.throw_strength == 1200.0, "B sees A's new throw strength")
	var hud: Hud = sandbox.find_children("*", "", false, false).filter(func(n: Node) -> bool: return n is Hud)[0]
	_check(hud._sliders["size"].value == 52.0 and hud._sliders["size"].editable, "the size slider follows the server row")
	hud._sliders["rotation_speed"].value = 3000.0 # as if dragged
	await _until(func() -> bool: return a_slime.drive_acceleration == 3000.0, "moving a slider changes the slime")
	_check(a_slime.radius == 52.0, "the other parameters stay as they were")
	for i in 90: # the bigger body settles without falling apart
		await get_tree().physics_frame
	_check(a_slime.position.y < 1800.0 and a_slime.position.y > 1800.0 - 52.0 * 1.3, "resized slime rests on the ground, y %.1f" % a_slime.position.y)

	# --- invalid input is rejected
	var err := {"v": ""}
	var bad := b.reducers.set_name("this name is far too long to be allowed")
	bad.on_error.connect(func(e: String) -> void: err.v = e)
	await _until(func() -> bool: return not err.v.is_empty(), "long name rejected")
	var err2 := {"v": ""}
	var bad2 := b.reducers.update_slime(Vector2(NAN, 0), Vector2.ZERO, 0.0, 0.0, _squashed_shape())
	bad2.on_error.connect(func(e: String) -> void: err2.v = e)
	await _until(func() -> bool: return not err2.v.is_empty(), "NaN transform rejected")
	var err3 := {"v": ""}
	var bad3 := b.reducers.update_slime(Vector2.ZERO, Vector2.ZERO, 0.0, 0.0, PackedByteArray([1, 2, 3]))
	bad3.on_error.connect(func(e: String) -> void: err3.v = e)
	await _until(func() -> bool: return not err3.v.is_empty(), "wrong shape length rejected")

	# --- A's own echo must not move A or create a puppet for itself
	_check(not spawner.puppets.has(Net.local_id), "A must not get a puppet of itself")

	# --- B disconnects: its slime disappears from A's world
	b.disconnect_db()
	await _until(func() -> bool: return not spawner.puppets.has(b_id), "puppet removed after B disconnects")
	_check(Net.game.db.slime_state.identity.find(b.get_local_identity()) == null, "B's slime_state row should be gone")
	_check(Net.game.db.slime_stats.identity.find(b.get_local_identity()) == null, "B's slime_stats row should be gone")
	_check(Net.players.has(b_id), "B's player row persists")
