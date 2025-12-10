extends Node2D

const PARTICLE_RADIUS = 2.0

@export_group("Particles")
@export var particle_count: int = 50
@export var min_dist: float = 10.0

@export_group("Field")
@export var kernel_radius: float = 50.0
@export var mu: float = 0.04  # Legacy, kept for compatibility
@export var mu_base: float = 0.04
@export var mu_range: float = 0.02
@export var sigma: float = 0.02
@export var environment_field: Node2D = null

@export_group("Forces")
@export var gradient_strength: float = 100.0
@export var repulsion_strength: float = 50.0
@export var time_scale: float = 1.0
@export var max_speed: float = 0.0
@export var velocity_smoothing: float = 0.0

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

func calculate_growth_with_mu(u: float, mu_local: float) -> float:
	var diff = u - mu_local
	var diff_squared = diff * diff
	var sigma_squared = sigma * sigma
	return 2.0 * exp(-(diff_squared / (2.0 * sigma_squared))) - 1.0

func calculate_gradient(pos: Vector2) -> Vector2:
	# Legacy version using global mu
	return calculate_gradient_with_mu(pos, mu)

func calculate_gradient_with_mu(pos: Vector2, mu_local: float) -> Vector2:
	var U: float = 0.0
	var gradU: Vector2 = Vector2.ZERO
	var kernel_radius_squared = kernel_radius * kernel_radius
	
	# Compute U and gradU in one loop
	for particle in particles:
		var diff = pos - particle.position
		var dist_sq = diff.length_squared()
		var k = exp(-dist_sq / (2.0 * kernel_radius_squared))
		
		U += k
		gradU += (-1.0 / kernel_radius_squared) * diff * k
	
	# Normalize by particle count
	U /= float(particle_count)
	gradU /= float(particle_count)
	
	# Compute growth function G(U) with local mu
	var G = calculate_growth_with_mu(U, mu_local)
	var G_plus_one = G + 1.0
	var sigma_squared = sigma * sigma
	
	# Compute derivative dG/dU
	var dG_dU = (mu_local - U) / sigma_squared * G_plus_one
	
	# Final gradient: gradG = (dG/dU) * gradU
	var gradG = gradU * dG_dU
	
	return gradG

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
	
	var viewport_size = get_viewport_rect().size
	
	for i in range(particles.size()):
		var particle = particles[i]
		
		# Sample environment to get M_norm in [-1, 1]
		var m_norm := 0.0
		if environment_field and environment_field.has_method("sample"):
			m_norm = environment_field.sample(particle.position)
			# Ensure m_norm is in [-1, 1] range (should already be, but clamp for safety)
			m_norm = clamp(m_norm, -1.0, 1.0)
		
		# Compute local μ
		var mu_local = mu_base + mu_range * m_norm
		
		# Calculate gradient with local μ
		var gradient = calculate_gradient_with_mu(particle.position, mu_local)
		var repulsion = calculate_repulsion(i)
		
		# Compute target velocity
		var target = gradient * gradient_strength
		if repulsion_strength > 0.0:
			target += repulsion * repulsion_strength
		
		# Apply velocity smoothing if enabled
		if velocity_smoothing <= 0.0:
			particle.velocity = target
		else:
			var s = clamp(velocity_smoothing, 0.0, 1.0)
			particle.velocity = particle.velocity.lerp(target, s)
		
		# Clamp to max speed if enabled
		if max_speed > 0.0:
			var speed = particle.velocity.length()
			if speed > max_speed:
				particle.velocity = particle.velocity * (max_speed / speed)
		
		particle.position += particle.velocity * delta * time_scale
		
		if particle.position.x < 0.0:
			particle.position.x += viewport_size.x
		elif particle.position.x >= viewport_size.x:
			particle.position.x -= viewport_size.x
		
		if particle.position.y < 0.0:
			particle.position.y += viewport_size.y
		elif particle.position.y >= viewport_size.y:
			particle.position.y -= viewport_size.y
	
	queue_redraw()

