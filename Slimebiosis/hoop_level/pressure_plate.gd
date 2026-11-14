extends AnimatableBody2D
## The custom Verlet slimes don't transfer rigid-body forces. Their supported
## weight drives this spring, while the moving collision surface supports them.

@export var travel: float = 28.0
@export var raised_height: float = 36.0
@export var spring_stiffness: float = 160.0
@export var spring_damping: float = 72.0
@export var plate_mass: float = 8.0

var compression: float = 0.0
var _velocity: float = 0.0
var _rest_position: Vector2


func _ready() -> void:
	sync_to_physics = false
	_rest_position = position
	_update_visual()


func apply_weight(weight: float, delta: float) -> void:
	var force: float = weight * spring_stiffness * travel
	var acceleration: float = (force - spring_stiffness * compression - spring_damping * _velocity) / plate_mass
	_velocity += acceleration * delta
	compression += _velocity * delta
	if compression <= 0.0:
		compression = 0.0
		_velocity = maxf(_velocity, 0.0)
	elif compression >= travel:
		compression = travel
		_velocity = minf(_velocity, 0.0)
	position = _rest_position + Vector2.DOWN * compression
	_update_visual()


func _update_visual() -> void:
	# Hide the part of the plunger inside the floor as it compresses.
	var outline: PackedVector2Array = $Visual.polygon
	outline[3].y = raised_height - compression
	outline[4].y = raised_height - compression
	$Visual.polygon = outline
	$Visual.color = Color("ff5963").lerp(Color("a94750"), compression / travel)
