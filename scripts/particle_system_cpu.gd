extends Node2D

const PARTICLE_RADIUS = 2.0

@export_group("Particles")
@export var particle_count: int = 50
@export var min_dist: float = 10.0

@export_group("Field")
@export var kernel_radius: float = 50.0
@export var mu: float = 0.04
@export var sigma: float = 0.02

@export_group("Forces")
@export var gradient_strength: float = 100.0
@export var repulsion_strength: float = 50.0
@export var time_scale: float = 1.0

var particles: Array[Particle] = []

func _ready():
	spawn_particles()

func spawn_particles():
	particles.clear()
	var viewport_size = get_viewport_rect().size
	
	for i in range(particle_count):
		var random_pos = Vector2(
			randf() * viewport_size.x,
			randf() * viewport_size.y
		)
		var particle = Particle.new(random_pos, Vector2.ZERO)
		particles.append(particle)

func calculate_field(pos: Vector2) -> float:
	var U: float = 0.0
	for particle in particles:
		var dist = pos.distance_to(particle.position)
		var dist_squared = dist * dist
		var kernel_radius_squared = kernel_radius * kernel_radius
		U += exp(-dist_squared / (2.0 * kernel_radius_squared))
	return U / float(particle_count)

func calculate_growth(u: float) -> float:
	var diff = u - mu
	var diff_squared = diff * diff
	var sigma_squared = sigma * sigma
	return 2.0 * exp(-(diff_squared / (2.0 * sigma_squared))) - 1.0

func calculate_gradient(pos: Vector2) -> Vector2:
	var delta: float = 1.0
	
	var u_plus_x = calculate_field(pos + Vector2(delta, 0.0))
	var u_minus_x = calculate_field(pos - Vector2(delta, 0.0))
	var gx = calculate_growth(u_plus_x) - calculate_growth(u_minus_x)
	
	var u_plus_y = calculate_field(pos + Vector2(0.0, delta))
	var u_minus_y = calculate_field(pos - Vector2(0.0, delta))
	var gy = calculate_growth(u_plus_y) - calculate_growth(u_minus_y)
	
	return Vector2(gx, gy) / (2.0 * delta)

func calculate_repulsion(particle_index: int) -> Vector2:
	var repulsion = Vector2.ZERO
	var particle = particles[particle_index]
	
	for j in range(particles.size()):
		if j == particle_index:
			continue
		
		var other = particles[j]
		var diff = particle.position - other.position
		var dist = diff.length()
		
		if dist < min_dist and dist > 0:
			var strength = pow(1.0 - dist / min_dist, 2.0)
			repulsion += diff.normalized() * strength
	
	return repulsion

func _draw():
	for particle in particles:
		draw_circle(particle.position, PARTICLE_RADIUS, Color.WHITE)

func _process(delta):
	if particles.size() > 0:
		var sample_u = calculate_field(particles[0].position)
		if Engine.get_process_frames() % 60 == 0:
			print("Field U sample: ", sample_u)
	
	for i in range(particles.size()):
		var particle = particles[i]
		var gradient = calculate_gradient(particle.position)
		var repulsion = calculate_repulsion(i)
		particle.velocity = (gradient * gradient_strength) + (repulsion * repulsion_strength)
		particle.position += particle.velocity * delta * time_scale
	
	queue_redraw()

