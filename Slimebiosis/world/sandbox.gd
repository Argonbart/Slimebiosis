extends Node2D
## The shared sandbox level. The local slime is playable immediately; once the
## server connection is ready it moves to its assigned spawn point and other
## players' slimes appear through the SlimeSpawner.

const SLIME := preload("res://slime/slime.tscn")
const KILL_Y := 4200.0

## Set to false (before adding to the tree) to run without networking, e.g. in tests.
@export var online := true

var local_slime: VerletSlime
var spawner: SlimeSpawner
var _spawn_index := 0
var _placed := false

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.09, 0.1, 0.15))
	local_slime = SLIME.instantiate()
	local_slime.name = "LocalSlime"
	local_slime.position = spawn_position(0)
	local_slime.radius = SlimeSpawner.DEFAULT_RADIUS
	local_slime.follow_center = true
	local_slime.show_face = true
	local_slime.add_child(LocalController.new())
	add_child(local_slime)

	if not online:
		return
	local_slime.add_child(NetSender.new())
	spawner = SlimeSpawner.new()
	spawner.name = "SlimeSpawner"
	add_child(spawner)
	add_child(Hud.new())
	Net.ready_to_play.connect(_on_ready_to_play)
	Net.player_changed.connect(_on_player)
	Net.went_offline.connect(local_slime.clear_state)
	Net.start()

func _on_ready_to_play() -> void:
	local_slime.set_identity(Net.local_identity)
	var state := Net.local_state()
	if state != null:
		_spawn_index = state.spawn_index
		local_slime.apply_state(state)
	if not _placed: # only on the first connect, not on reconnects
		_placed = true
		local_slime.teleport(spawn_position(_spawn_index))
	if Net.stats.has(Net.local_id):
		local_slime.apply_stats(Net.stats[Net.local_id])
	if Net.players.has(Net.local_id):
		SlimeSpawner.apply_player(local_slime, Net.players[Net.local_id])

func _on_player(id: String, row: GamePlayer) -> void:
	if id == Net.local_id:
		SlimeSpawner.apply_player(local_slime, row)

func spawn_position(index: int) -> Vector2:
	var points := $SpawnPoints.get_children()
	return (points[index % points.size()] as Node2D).position

func _physics_process(_delta: float) -> void:
	if local_slime.get_center().y > KILL_Y and not local_slime.is_held():
		local_slime.teleport(spawn_position(_spawn_index))
