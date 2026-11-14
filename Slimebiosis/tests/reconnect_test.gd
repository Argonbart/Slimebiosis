extends Node
## Headless check of the connection-loss path: the game keeps running when the
## server dies, drops remote slimes, and comes back by itself when it returns.
## Starts its own private server so it never touches the development one.
## Run through tools/test_reconnect.sh (it provides the data directory).

const PORT := 3111
const TIMEOUT := 30.0

var _failures: Array[String] = []
var _data_dir := ""
var _server_pid := -1

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--data-dir="):
			_data_dir = arg.get_slice("=", 1)
	if _data_dir.is_empty():
		_failures.append("missing --data-dir=")
	else:
		await _run()
	_stop_server()
	for f in _failures:
		printerr("FAIL: ", f)
	print("reconnect_test: %s" % ("PASSED" if _failures.is_empty() else "FAILED"))
	get_tree().quit(0 if _failures.is_empty() else 1)

func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures.append(what)

func _until(cond: Callable, what: String) -> bool:
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await get_tree().process_frame
	_failures.append("timeout: " + what)
	return false

func _start_server() -> void:
	_server_pid = OS.create_process("spacetime", [
		"start", "-l", "127.0.0.1:%d" % PORT, "--data-dir", _data_dir, "--non-interactive"])
	var http := HTTPRequest.new()
	http.timeout = 1.0
	add_child(http)
	var deadline := Time.get_ticks_msec() + int(TIMEOUT * 1000)
	var up := false
	while not up and Time.get_ticks_msec() < deadline:
		if http.request("http://127.0.0.1:%d/v1/ping" % PORT) == OK:
			var res: Array = await http.request_completed
			up = res[1] == 200
		if not up:
			await get_tree().create_timer(0.2).timeout
	http.queue_free()
	_check(up, "private server did not come up")

func _stop_server() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		_server_pid = -1

func _run() -> void:
	var url := "http://127.0.0.1:%d" % PORT
	await _start_server()
	var out := []
	var code := OS.execute("spacetime", ["publish", "-s", url, "-p",
		ProjectSettings.globalize_path("res://server"), "--yes", "slimecrime"], out, true)
	if code != 0:
		_failures.append("publish failed: %s" % str(out))
		return

	Net.url = url
	Net.database = Net.LOCAL_DB
	Net.token_path = "user://token_reconnect_test_a.dat"
	Net.one_time_token = true
	Net.offline = false
	var statuses: Array[String] = []
	Net.status_changed.connect(func(s: String) -> void: statuses.append(s))
	var sandbox: Node2D = load("res://world/sandbox.tscn").instantiate()
	add_child(sandbox)
	if not await _until(func() -> bool: return Net.is_ready, "Net ready"):
		return
	var a: VerletSlime = sandbox.local_slime
	var spawner: SlimeSpawner = sandbox.spawner
	var first_identity := Net.local_identity

	# a second player, so there is a remote slime to lose
	var b: GameModuleClient = load("res://spacetime_bindings/schema/module_game_client.gd").new()
	b.token_save_path = "user://token_reconnect_test_b.dat"
	add_child(b)
	var options := SpacetimeDBConnectionOptions.new()
	options.threading = false
	options.one_time_token = true
	b.connect_db(url, Net.database, options)
	await _until(func() -> bool: return b.is_connected_db(), "B connected")
	b.reducers.update_slime(a.position + Vector2(40, 0), Vector2.ZERO, 0.0, 0.0, a.pack_shape())
	await _until(func() -> bool: return spawner.puppets.size() == 1, "puppet B present")

	# --- server dies
	_stop_server()
	await _until(func() -> bool: return not Net.is_ready, "Net notices the loss")
	await _until(func() -> bool: return spawner.puppets.is_empty(), "remote slimes removed while offline")
	_check(statuses.any(func(s: String) -> bool: return "retrying" in s), "status should mention retrying, got %s" % str(statuses))
	# the local slime stays playable
	var x0 := a.position.x
	Input.action_press("move_right")
	for i in 60:
		await get_tree().physics_frame
	Input.action_release("move_right")
	_check(a.position.x > x0 + 50.0, "local slime still moves while offline, moved %.1f" % (a.position.x - x0))
	# several failed retries must not break anything
	await get_tree().create_timer(Net.RETRY_SECONDS * 2.0 + 1.0, true, false, true).timeout
	_check(not Net.is_ready, "still offline while the server is down")
	var moved_to := a.position # it has rolled to a stop by now
	_check(moved_to.x > x0 + 50.0, "slime rested away from where it started")

	# --- server returns
	await _start_server()
	if not await _until(func() -> bool: return Net.is_ready, "Net reconnects by itself"):
		return
	_check(Net.local_identity == first_identity, "identity is kept across the reconnect")
	_check(a.position.distance_to(moved_to) < 60.0, "reconnect must not teleport the local slime back to spawn")
	await _until(func() -> bool:
		var t: GameSlimeTransform = Net.game.db.slime_transform.identity.find(Net.local_identity)
		return t != null and t.pos.distance_to(a.position) < 2.0, "local slime is announced to the server again")
	_check(Net.local_state() != null, "slime_state exists again after reconnect")
	_check(spawner.puppets.is_empty(), "B did not reconnect, so no stale puppet")
