extends Node
## Autoload "Net": owns the SpacetimeDB connection flow and turns table events
## into simple signals keyed by identity hex strings.
##
## Command line (after `--`, or as plain args from "Customize Run Instances"):
##   --instance=N   use a separate saved identity (user://token_N.dat)
##   --local        use the local development server instead of Maincloud
##   --server=URL   server base URL
##   --db=NAME      database name
##   --offline      do not connect at all

signal status_changed(text: String)
## Subscription applied: tables are filled and local_id is valid. Fires again after a reconnect.
signal ready_to_play
signal went_offline
signal transform_changed(id: String, row: GameSlimeTransform)
signal transform_removed(id: String)
signal state_changed(id: String, row: GameSlimeState)
signal state_removed(id: String)
signal player_changed(id: String, row: GamePlayer)
signal stats_changed(id: String, row: GameSlimeStats)

## Where the game connects by default: the public Maincloud database.
const DEFAULT_URL := "https://maincloud.spacetimedb.com"
const DEFAULT_DB := "slimecrime-justfordoener"
## The development server (`spacetime start` + tools/publish.sh); selected with --local.
const LOCAL_URL := "http://127.0.0.1:3000"
const LOCAL_DB := "slimecrime"
const RETRY_SECONDS := 3.0
const QUERIES: PackedStringArray = [
	"SELECT * FROM player",
	"SELECT * FROM slime_transform",
	"SELECT * FROM slime_state",
	"SELECT * FROM slime_stats",
]

var url := DEFAULT_URL
var database := DEFAULT_DB
var token_path := "user://token.dat"
## false keeps the same identity (and name) across launches.
var one_time_token := false
var offline := false

var game: GameModuleClient
var local_identity := PackedByteArray()
var local_id := ""
var is_ready := false
var status := "offline"
## Latest player rows by identity hex.
var players: Dictionary[String, GamePlayer] = {}
## Latest interaction rows by identity hex, for slimes currently in the world.
var states: Dictionary[String, GameSlimeState] = {}
## Latest physics parameter rows by identity hex.
var stats: Dictionary[String, GameSlimeStats] = {}

## Diagnostics for the debug overlay (F3).
## Smoothed time from sending a reducer call to the server's answer; -1 = unknown.
var rtt_ms := -1.0
## Time.get_ticks_msec() of our last throw request; cleared when its launch arrives.
var throw_sent_at := 0.0
const PING_SECONDS := 0.5
var _ping_timer := 0.0
var _ping_pending := false
var _last_transform: Array = []

var _started := false
var _retry: Timer

func _ready() -> void:
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with("--instance="):
			token_path = "user://token_%s.dat" % arg.get_slice("=", 1)
		elif arg.begins_with("--server="):
			url = arg.get_slice("=", 1)
		elif arg.begins_with("--db="):
			database = arg.get_slice("=", 1)
		elif arg == "--local":
			url = LOCAL_URL
			database = LOCAL_DB
		elif arg == "--offline":
			offline = true

static func id_of(identity: PackedByteArray) -> String:
	return identity.hex_encode()

## Begins connecting. Call from a scene (not from an autoload's _ready): the
## SpacetimeDB client node must already be in the tree.
func start() -> void:
	if _started or offline:
		return
	_started = true
	game = SpacetimeDB.Game
	game.token_save_path = token_path

	_retry = Timer.new()
	_retry.one_shot = true
	_retry.wait_time = RETRY_SECONDS
	_retry.timeout.connect(_reconnect)
	add_child(_retry)

	var options := SpacetimeDBConnectionOptions.new()
	options.threading = false
	options.one_time_token = one_time_token
	options.compression = SpacetimeDBConnection.CompressionPreference.NONE

	game.connected.connect(_on_connected)
	game.disconnected.connect(_on_lost.bind("disconnected"))
	game.connection_error.connect(func(_code: int, reason: String) -> void: _on_lost(reason))
	_set_status("connecting to %s" % url)
	game.connect_db(url, database, options)

	# connect_db creates the local database synchronously, so listeners can be registered now.
	var db := game.db
	db.slime_transform.on_insert(_on_transform)
	db.slime_transform.on_update(func(_old: GameSlimeTransform, row: GameSlimeTransform) -> void: _on_transform(row))
	db.slime_transform.on_delete(func(row: GameSlimeTransform) -> void: transform_removed.emit(id_of(row.identity)))
	db.slime_state.on_insert(_on_state)
	db.slime_state.on_update(func(_old: GameSlimeState, row: GameSlimeState) -> void: _on_state(row))
	db.slime_state.on_delete(_on_state_removed)
	db.slime_stats.on_insert(_on_stats)
	db.slime_stats.on_update(func(_old: GameSlimeStats, row: GameSlimeStats) -> void: _on_stats(row))
	db.slime_stats.on_delete(func(row: GameSlimeStats) -> void: stats.erase(id_of(row.identity)))
	db.player.on_insert(_on_player)
	db.player.on_update(func(_old: GamePlayer, row: GamePlayer) -> void: _on_player(row))

func _on_transform(row: GameSlimeTransform) -> void:
	transform_changed.emit(id_of(row.identity), row)

func _on_state(row: GameSlimeState) -> void:
	var id := id_of(row.identity)
	states[id] = row
	state_changed.emit(id, row)

func _on_state_removed(row: GameSlimeState) -> void:
	var id := id_of(row.identity)
	states.erase(id)
	state_removed.emit(id)

func _on_stats(row: GameSlimeStats) -> void:
	var id := id_of(row.identity)
	stats[id] = row
	stats_changed.emit(id, row)

func _on_player(row: GamePlayer) -> void:
	var id := id_of(row.identity)
	players[id] = row
	player_changed.emit(id, row)

func _on_connected(identity: PackedByteArray, _token: String) -> void:
	local_identity = identity
	local_id = id_of(identity)
	_set_status("connected, subscribing")
	var sub := game.subscribe(QUERIES)
	if sub.error != OK:
		_on_lost("subscribe failed")
		return
	sub.applied.connect(_on_applied, CONNECT_ONE_SHOT)
	# A rejected subscription only emits `end`.
	sub.end.connect(func() -> void:
		if not is_ready:
			_on_lost("subscription rejected"), CONNECT_ONE_SHOT)

func _on_applied() -> void:
	# Seed from the cache too, in case initial rows did not go through the insert listeners.
	for row in game.db.player.iter():
		_on_player(row)
	for row in game.db.slime_stats.iter():
		_on_stats(row)
	for row in game.db.slime_state.iter():
		_on_state(row)
	for row in game.db.slime_transform.iter():
		_on_transform(row)
	is_ready = true
	_set_status("online")
	ready_to_play.emit()

func _on_lost(reason: String) -> void:
	var was_ready := is_ready
	is_ready = false
	_ping_pending = false
	_set_status("%s, retrying" % reason)
	if game.get_local_database():
		game.get_local_database().clear_local_db() # fires the delete listeners
	if was_ready:
		went_offline.emit()
	if _retry.is_stopped():
		_retry.start()

func _reconnect() -> void:
	if game.is_connected_db():
		return
	_set_status("reconnecting to %s" % url)
	game.reconnect_db()

func _set_status(text: String) -> void:
	status = text
	status_changed.emit(text)

## The local player's interaction row, or null when not in the world.
func local_state() -> GameSlimeState:
	if not is_ready:
		return null
	return game.db.slime_state.identity.find(local_identity)

func send_transform(pos: Vector2, vel: Vector2, angle: float, spin: float, shape: PackedByteArray) -> void:
	if is_ready and game.is_connected_db():
		_last_transform = [pos, vel, angle, spin, shape]
		game.reducers.update_slime(pos, vel, angle, spin, shape)

## Measures the round trip by timing a repeat of the last transform (a no-op for
## everyone else: the row does not change).
func _process(delta: float) -> void:
	_ping_timer += delta
	if _ping_timer < PING_SECONDS or _ping_pending or _last_transform.is_empty() or not (is_ready and game.is_connected_db()):
		return
	_ping_timer = 0.0
	_ping_pending = true
	var sent := Time.get_ticks_msec()
	var call: SpacetimeDBReducerCall = game.reducers.update_slime.callv(_last_transform)
	call.response.connect(func(_r: Variant) -> void:
		_ping_pending = false
		var ms := float(Time.get_ticks_msec() - sent)
		rtt_ms = ms if rtt_ms < 0.0 else lerpf(rtt_ms, ms, 0.3), CONNECT_ONE_SHOT)

## Debug tuning of our own slime; the server clamps the values and the result
## comes back through stats_changed.
func set_stats(weight: float, size: float, rotation_speed: float, throw_strength: float, jump_strength: float, softness: float) -> SpacetimeDBReducerCall:
	if not (is_ready and game.is_connected_db()):
		return null
	return game.reducers.set_stats(weight, size, rotation_speed, throw_strength, jump_strength, softness)

func set_player_name(new_name: String) -> void:
	if not (is_ready and game.is_connected_db()):
		_set_status("cannot rename while offline")
		return
	var call := game.reducers.set_name(new_name)
	call.on_error.connect(func(err: String) -> void: _set_status("rename failed: %s" % err))

# --- interactions. The server referees these; a refusal (out of reach, target
# already held, ...) is a normal outcome, so errors are only logged.

## `attach_angle`: where the target sits on our body, in our body frame.
func grab(target: PackedByteArray, attach_angle: float) -> SpacetimeDBReducerCall:
	return _interact("grab", func() -> SpacetimeDBReducerCall: return game.reducers.grab(target, attach_angle))

func throw_held(dir: Vector2) -> SpacetimeDBReducerCall:
	throw_sent_at = float(Time.get_ticks_msec())
	return _interact("throw", func() -> SpacetimeDBReducerCall: return game.reducers.throw_held(dir))

func break_free() -> SpacetimeDBReducerCall:
	return _interact("break free", func() -> SpacetimeDBReducerCall: return game.reducers.break_free())

func _interact(what: String, send: Callable) -> SpacetimeDBReducerCall:
	if not (is_ready and game.is_connected_db()):
		return null
	var call: SpacetimeDBReducerCall = send.call()
	call.on_error.connect(func(err: String) -> void: print_verbose("Net: %s refused: %s" % [what, err]))
	return call
