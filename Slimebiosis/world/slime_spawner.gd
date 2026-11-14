class_name SlimeSpawner extends Node
## Creates, updates and removes other players' slimes from Net table events.

const SLIME := preload("res://slime/slime.tscn")
## Size of a slime before its slime_stats row arrives. Mirrors DEFAULT_SIZE on the server.
const DEFAULT_RADIUS := 40.0

## Remote slimes by identity hex.
var puppets: Dictionary[String, VerletSlime] = {}

func _ready() -> void:
	Net.transform_changed.connect(_on_transform)
	Net.transform_removed.connect(_remove)
	Net.state_removed.connect(_remove)
	Net.player_changed.connect(_on_player)
	Net.state_changed.connect(_on_state)
	Net.stats_changed.connect(_on_stats)

func _on_state(id: String, row: GameSlimeState) -> void:
	var slime: VerletSlime = VerletSlime.registry.get(id)
	if slime != null:
		slime.apply_state(row)

func _on_stats(id: String, row: GameSlimeStats) -> void:
	var slime: VerletSlime = VerletSlime.registry.get(id)
	if slime != null:
		slime.apply_stats(row)

func _on_transform(id: String, row: GameSlimeTransform) -> void:
	if id == Net.local_id:
		return # our own echo: the local controller is the authority
	var slime: VerletSlime = puppets.get(id)
	if slime == null:
		slime = SLIME.instantiate()
		slime.name = "Remote_" + id.left(8)
		slime.simulated = false
		slime.follow_center = true
		slime.show_face = true
		slime.radius = Net.stats[id].size if Net.stats.has(id) else DEFAULT_RADIUS
		slime.position = row.pos
		var puppet := RemotePuppet.new()
		puppet.name = "RemotePuppet"
		slime.add_child(puppet)
		slime.set_identity(row.identity)
		get_parent().add_child(slime)
		if Net.stats.has(id):
			slime.apply_stats(Net.stats[id])
		if Net.states.has(id):
			slime.apply_state(Net.states[id])
		puppets[id] = slime
		if Net.players.has(id):
			apply_player(slime, Net.players[id])
	(slime.get_node("RemotePuppet") as RemotePuppet).push(row)

func _remove(id: String) -> void:
	var slime: VerletSlime = puppets.get(id)
	if slime != null:
		puppets.erase(id)
		slime.queue_free()

func _on_player(id: String, row: GamePlayer) -> void:
	if puppets.has(id):
		apply_player(puppets[id], row)

static func apply_player(slime: VerletSlime, row: GamePlayer) -> void:
	slime.body_color = Color.from_hsv(row.hue, 0.6, 0.92)
	slime.queue_redraw()
	slime.display_name = row.name
