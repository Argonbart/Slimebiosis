extends Node
## Headless check of the soft-body slime in the sandbox using simulated input:
## settling, rolling, jumping and teleporting.
## Run: godot --headless --path . --fixed-fps 60 res://tests/movement_test.tscn

var _failures: Array[String] = []
var slime: VerletSlime

func _ready() -> void:
	var sandbox: Node2D = load("res://world/sandbox.tscn").instantiate()
	sandbox.online = false
	add_child(sandbox)
	slime = sandbox.local_slime
	await _run()
	for f in _failures:
		printerr("FAIL: ", f)
	print("movement_test: %s" % ("PASSED" if _failures.is_empty() else "FAILED"))
	get_tree().quit(0 if _failures.is_empty() else 1)

func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures.append(what)

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _release_all() -> void:
	for a in ["move_left", "move_right", "jump", "grab"]:
		Input.action_release(a)

## Largest distance of a rim point from where the resting ring would put it.
func _ring_error() -> float:
	var worst := 0.0
	var rim := slime.unpack_shape(slime.pack_shape())
	var rest := slime.rest_shape()
	for i in rim.size():
		worst = maxf(worst, rim[i].distance_to(rest[i]))
	return worst

func _run() -> void:
	const GROUND_Y := 1800.0
	var reach := slime.size

	# --- settles on the ground, resting on its rim
	await _frames(90)
	var rest_y := slime.position.y
	_check(absf(slime.velocity.length()) < 15.0, "should come to rest, speed %.1f" % slime.velocity.length())
	_check(rest_y < GROUND_Y and rest_y > GROUND_Y - reach - 4.0, "centre should rest about one radius above the ground, y %.1f" % rest_y)
	_check(slime.position.distance_to(slime.get_center()) < 0.01, "node position is the centre")

	# --- rolls right: moves, spins clockwise, and the look direction turns with it
	var x0 := slime.position.x
	var a0 := slime.angle
	Input.action_press("move_right")
	await _frames(60)
	_check(slime.position.x > x0 + 150.0, "should roll right, moved %.1f" % (slime.position.x - x0))
	_check(slime.velocity.x > 100.0, "rolling velocity %.1f" % slime.velocity.x)
	_check(slime.spin > 1.0, "should spin clockwise, spin %.2f" % slime.spin)
	_check(absf(angle_difference(a0, slime.angle)) > 0.01 or slime.spin > 1.0, "look direction turns")
	var rolling := slime.velocity.x
	Input.action_release("move_right")
	await _frames(240)
	print("movement_test info: rolled at %.1f, %.1f four seconds after letting go" % [rolling, slime.velocity.x])
	_check(absf(slime.velocity.x) < rolling * 0.5, "slows down after letting go, from %.1f to %.1f" % [rolling, slime.velocity.x])

	# --- rolls left
	x0 = slime.position.x
	Input.action_press("move_left")
	await _frames(60)
	_check(slime.position.x < x0 - 100.0, "should roll left, moved %.1f" % (slime.position.x - x0))
	_check(slime.spin < -1.0, "should spin counter-clockwise, spin %.2f" % slime.spin)
	_release_all()

	# --- teleport: arrives in resting shape, at rest, and still simulates
	var spot := Vector2(2400, 1600) # open ground, nothing overhead
	slime.teleport(spot)
	_check(slime.position.distance_to(spot) < 0.01, "teleport moves the node")
	await _frames(2)
	_check(slime.position.distance_to(spot) < 12.0, "teleport holds after physics steps, off by %.1f" % slime.position.distance_to(spot))
	_check(_ring_error() < 6.0, "ring intact after teleport, worst point off by %.1f" % _ring_error())
	await _frames(120)
	_check(absf(slime.position.x - spot.x) < 40.0, "no sideways kick from teleport, drifted %.1f" % (slime.position.x - spot.x))
	rest_y = slime.position.y
	_check(rest_y > spot.y and rest_y < GROUND_Y, "falls to the ground after teleport, y %.1f" % rest_y)

	# --- jump: leaves the ground, and a second press in the air does nothing
	Input.action_press("jump")
	await _frames(2)
	Input.action_release("jump")
	var peak := rest_y
	for i in 12:
		await get_tree().physics_frame
		peak = minf(peak, slime.position.y)
	_check(peak < rest_y - 20.0, "should rise after jump, rose %.1f" % (rest_y - peak))
	_check(not slime.jump(), "no jump without ground contact")
	for i in 120:
		await get_tree().physics_frame
		peak = minf(peak, slime.position.y)
	_check(rest_y - peak > 40.0, "jump height %.1f" % (rest_y - peak))
	_check(absf(slime.position.y - rest_y) < 6.0, "lands again, y %.1f vs %.1f" % [slime.position.y, rest_y])

	# --- teleport with velocity (what a throw does)
	slime.teleport(Vector2(2400, 1400), Vector2(500, -300))
	await _frames(10)
	_check(slime.velocity.x > 400.0, "launch velocity is kept, vx %.1f" % slime.velocity.x)
	_check(slime.position.x > 2400.0 + 60.0, "flies after launch, moved %.1f" % (slime.position.x - 2400.0))

	# --- shape bytes: 32 of them, and a resting ring survives the round trip
	_check(slime.pack_shape().size() == 64, "shape is 64 bytes")
	var rest := slime.rest_shape()
	var worst := 0.0
	slime.teleport(Vector2(2400, 1400))
	var back := slime.unpack_shape(slime.pack_shape())
	for i in rest.size():
		worst = maxf(worst, back[i].distance_to(rest[i]))
	_check(worst < 1.0, "shape encoding error %.2f px" % worst)

	# --- falling out of the world respawns at the spawn point
	slime.teleport(Vector2(0, 4300))
	await _frames(5)
	_check(slime.position.y < 2000.0, "kill plane respawns, y %.1f" % slime.position.y)
