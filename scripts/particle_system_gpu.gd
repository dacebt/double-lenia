extends Node2D

const PARTICLE_RADIUS = 2.0
const LOCAL_GROUP_SIZE = 64

enum SimulationMode {
	FIELD_ONLY,
	SWARM_ON_FROZEN_FIELD,
	COUPLED
}

@export_group("Simulation")
## Simulation mode: FIELD_ONLY (field evolves, no particles), SWARM_ON_FROZEN_FIELD (particles on static field), COUPLED (full interaction)
@export var simulation_mode: SimulationMode = SimulationMode.COUPLED

@export_group("Particles")
## Number of particles in the simulation.
@export var particle_count: int = 50

## Minimum distance between particles. Repulsion activates below this.
@export var min_dist: float = 10.0

@export_group("Particle Interactions")
## Radius of ring kernel for particle-particle interactions (r0 parameter). Distance where interaction peaks.
@export var particle_kernel_radius: float = 50.0

## Width of ring kernel for particle-particle interactions (s parameter). Controls interaction spread.
@export var particle_kernel_width: float = 15.0

## Width of growth function for particles. Controls how sharply particles respond to density differences.
@export var particle_sigma: float = 0.02

@export_group("Field Coupling")
## Reference to the environment field that particles interact with.
@export var environment_field: EnvironmentField = null

## Base mu value for particles. Combined with environment field to set per-particle mu.
## NOTE: Will be deprecated in Phase 3 when particles follow field gradient directly.
@export var mu_base: float = 0.04

## Range of mu variation from environment field. mu = mu_base ± mu_range.
## NOTE: Will be deprecated in Phase 3.
@export var mu_range: float = 0.02

@export_group("Forces")
## Strength of gradient-based movement force. Controls how strongly particles follow the field gradient.
@export var gradient_strength: float = 100.0

## Strength of particle repulsion force. Prevents particles from clustering too closely.
@export var repulsion_strength: float = 50.0

## Global time scaling for particle movement.
@export var time_scale: float = 1.0

## Maximum particle speed (0 = unlimited).
@export var max_speed: float = 0.0

## Velocity smoothing factor (0-1). Higher = smoother velocity changes.
@export var velocity_smoothing: float = 0.0

var rd: RenderingDevice
var shader: RID
var pipeline: RID
var position_buffer: RID
var velocity_buffer: RID
var mu_buffer: RID
var field_buffer: RID  # Placeholder only if environment buffers unavailable
var uniform_buffer: RID
var uniform_sets: Array[RID] = [RID(), RID()]  # Two sets, one per field buffer
var current_field_index: int = 0

var particles: Array[Particle] = []
var positions_data: PackedFloat32Array
var velocities_data: PackedFloat32Array
var mu_data: PackedFloat32Array
var uniform_bytes_buffer: PackedByteArray  # Pre-allocated buffer for uniform uploads

func _ready() -> void:
	# If the exported reference wasn't set in the scene, fall back to groups.
	if environment_field == null:
		var gf = get_tree().get_first_node_in_group("environment_field")
		if gf is EnvironmentField:
			environment_field = gf

	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Failed to create RenderingDevice")
		return
	
	# Initialize environment field with our RenderingDevice
	if environment_field:
		environment_field.initialize_gpu(rd)
	
	_setup_compute_shader()
	spawn_particles()
	
	# Defer buffer creation to ensure environment_field is ready
	call_deferred("_deferred_init")

func _deferred_init() -> void:
	_update_buffers()

func _setup_compute_shader() -> void:
	# Load shader file as text
	var shader_file := FileAccess.open("res://shaders/particle_compute.glsl", FileAccess.READ)
	if shader_file == null:
		push_error("Failed to load shader file")
		return
	
	var shader_code := shader_file.get_as_text()
	shader_file.close()
	
	if shader_code.is_empty():
		push_error("Shader source is empty")
		return
	
	# Create RDShaderSource object
	var shader_source := RDShaderSource.new()
	shader_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, shader_code)
	
	# Compile shader to SPIR-V
	var shader_spirv := rd.shader_compile_spirv_from_source(shader_source)
	var compile_error := shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	
	if compile_error != "":
		push_error("Shader compile error: " + compile_error)
		return
	
	# Create shader from SPIR-V
	shader = rd.shader_create_from_spirv(shader_spirv)
	if not shader.is_valid():
		push_error("Failed to create shader")
		return
	
	# Create compute pipeline
	pipeline = rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		push_error("Failed to create compute pipeline")
		return
	
	# Create storage buffers (will be resized in _update_buffers)
	_create_buffers()
	
	# Pre-allocate uniform buffer (48 bytes = 12 floats for std140 alignment)
	uniform_bytes_buffer.resize(48)

func _create_buffers() -> void:
	# Calculate buffer sizes
	var vec2_size = 2 * 4  # 2 floats * 4 bytes each
	var buffer_size = particle_count * vec2_size
	var float_size = 4  # 1 float * 4 bytes
	
	# Create position buffer
	positions_data.resize(particle_count * 2)
	position_buffer = rd.storage_buffer_create(buffer_size)
	if not position_buffer.is_valid():
		push_error("Failed to create position buffer")
		return
	
	# Create velocity buffer
	velocities_data.resize(particle_count * 2)
	velocity_buffer = rd.storage_buffer_create(buffer_size)
	if not velocity_buffer.is_valid():
		push_error("Failed to create velocity buffer")
		return
	
	# Create mu buffer (one float per particle)
	mu_data.resize(particle_count)
	var mu_buffer_size = particle_count * float_size
	mu_buffer = rd.storage_buffer_create(mu_buffer_size)
	if not mu_buffer.is_valid():
		push_error("Failed to create mu buffer")
		return
	
	# Create field buffer (read-only, will be resized when field is available)
	# Initial size: 4 bytes (1 float) as placeholder, will be resized in _upload_field() when environment_field is set
	field_buffer = rd.storage_buffer_create(4)
	if not field_buffer.is_valid():
		push_error("Failed to create field buffer")
		return
	
	# Create uniform buffer (48 bytes = 12 floats for std140 alignment)
	var uniform_data = PackedByteArray()
	uniform_data.resize(48)  # 12 floats * 4 bytes
	uniform_buffer = rd.uniform_buffer_create(48)
	if not uniform_buffer.is_valid():
		push_error("Failed to create uniform buffer")
		return
	
	# Create two uniform sets, one for each field buffer (ping-pong)
	# This avoids recreating uniform sets every frame
	# Validate all buffers before creating uniform sets
	if not position_buffer.is_valid():
		push_error("Position buffer is not valid")
		return
	if not velocity_buffer.is_valid():
		push_error("Velocity buffer is not valid")
		return
	if not mu_buffer.is_valid():
		push_error("Mu buffer is not valid")
		return
	if not uniform_buffer.is_valid():
		push_error("Uniform buffer is not valid")
		return
	
	for buffer_index in range(2):
		var pos_uniform := RDUniform.new()
		pos_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		pos_uniform.binding = 0
		pos_uniform.add_id(position_buffer)
		
		var vel_uniform := RDUniform.new()
		vel_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		vel_uniform.binding = 1
		vel_uniform.add_id(velocity_buffer)
		
		var mu_uniform := RDUniform.new()
		mu_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		mu_uniform.binding = 2
		mu_uniform.add_id(mu_buffer)
		
		var params_uniform := RDUniform.new()
		params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		params_uniform.binding = 3
		params_uniform.add_id(uniform_buffer)
		
		# Get field buffer directly from environment (no copy needed)
		var field_buffer_rid: RID = RID()
		
		# Try to get field buffer from environment
		if environment_field and environment_field.has_method("get_field_buffer"):
			field_buffer_rid = environment_field.get_field_buffer(buffer_index)
		
		# Fallback to placeholder if field buffer not available
			if not field_buffer_rid.is_valid():
				push_warning("Environment field buffer %d not ready, using placeholder" % buffer_index)
				if not field_buffer.is_valid():
					field_buffer = rd.storage_buffer_create(4)  # Minimal placeholder
				field_buffer_rid = field_buffer
		
		if not field_buffer_rid.is_valid():
			push_error("Field buffer RID %d is not valid" % buffer_index)
			continue
		
		var field_uniform := RDUniform.new()
		field_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		field_uniform.binding = 4
		field_uniform.add_id(field_buffer_rid)
		
		uniform_sets[buffer_index] = rd.uniform_set_create([pos_uniform, vel_uniform, mu_uniform, params_uniform, field_uniform], shader, 0)
		if not uniform_sets[buffer_index].is_valid():
			push_error("Failed to create uniform set %d" % buffer_index)

func _update_buffers() -> void:
	# Resize buffers if particle count changed
	var vec2_size = 2 * 4
	var buffer_size = particle_count * vec2_size
	var float_size = 4
	var mu_buffer_size = particle_count * float_size
	
	if position_buffer.is_valid():
		rd.free_rid(position_buffer)
	if velocity_buffer.is_valid():
		rd.free_rid(velocity_buffer)
	if mu_buffer.is_valid():
		rd.free_rid(mu_buffer)
	
	positions_data.resize(particle_count * 2)
	velocities_data.resize(particle_count * 2)
	mu_data.resize(particle_count)
	
	position_buffer = rd.storage_buffer_create(buffer_size)
	velocity_buffer = rd.storage_buffer_create(buffer_size)
	mu_buffer = rd.storage_buffer_create(mu_buffer_size)
	
	# Field buffer is now accessed directly from environment_field (no local copy needed)
	# Recreate both uniform sets with updated particle buffers
	for buffer_index in range(2):
		if uniform_sets[buffer_index].is_valid():
			rd.free_rid(uniform_sets[buffer_index])
		
		var field_buffer_rid: RID = RID()
		if environment_field and environment_field.has_method("get_field_buffer"):
			field_buffer_rid = environment_field.get_field_buffer(buffer_index)
		
			if not field_buffer_rid.is_valid():
				if not field_buffer.is_valid():
					field_buffer = rd.storage_buffer_create(4)
				field_buffer_rid = field_buffer
		
		var pos_uniform := RDUniform.new()
		pos_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		pos_uniform.binding = 0
		pos_uniform.add_id(position_buffer)
		
		var vel_uniform := RDUniform.new()
		vel_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		vel_uniform.binding = 1
		vel_uniform.add_id(velocity_buffer)
		
		var mu_uniform := RDUniform.new()
		mu_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		mu_uniform.binding = 2
		mu_uniform.add_id(mu_buffer)
		
		var params_uniform := RDUniform.new()
		params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		params_uniform.binding = 3
		params_uniform.add_id(uniform_buffer)
		
		var field_uniform := RDUniform.new()
		field_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		field_uniform.binding = 4
		field_uniform.add_id(field_buffer_rid)
		
		uniform_sets[buffer_index] = rd.uniform_set_create([pos_uniform, vel_uniform, mu_uniform, params_uniform, field_uniform], shader, 0)

func spawn_particles() -> void:
	particles.clear()
	var viewport_size: Vector2 = _get_sim_viewport_size()
	
	for i in range(particle_count):
		var random_pos = Vector2(
			randf() * viewport_size.x,
			randf() * viewport_size.y
		)
		var particle = Particle.new(random_pos, Vector2.ZERO)
		particles.append(particle)

func _upload_positions() -> void:
	# Pack positions into float array
	for i in range(particles.size()):
		positions_data[i * 2] = particles[i].position.x
		positions_data[i * 2 + 1] = particles[i].position.y
	
	# Upload to GPU
	var position_bytes = positions_data.to_byte_array()
	rd.buffer_update(position_buffer, 0, position_bytes.size(), position_bytes)

func _upload_mu_locals() -> void:
	for i in range(particles.size()):
		var pos: Vector2 = particles[i].position

		var m_norm: float = 0.0
		if environment_field:
			m_norm = environment_field.sample(pos)  # ~[-1, 1]

		# map noise to [-1, 1] (already), then scale by mu_range
		var mu_val: float = mu_base + mu_range * m_norm

		# keep mu in a sane range
		mu_val = clamp(mu_val, 0.0, 1.0)

		mu_data[i] = mu_val
	
	var mu_bytes: PackedByteArray = mu_data.to_byte_array()
	rd.buffer_update(mu_buffer, 0, mu_bytes.size(), mu_bytes)

func _upload_uniforms(delta: float) -> void:
	# Pack uniforms into pre-allocated byte array (48 bytes = 12 floats for std140 alignment)
	var uniform_bytes = uniform_bytes_buffer
	
	var viewport_size: Vector2 = _get_sim_viewport_size()
	var field_grid_size: float = 0.0
	if environment_field:
		field_grid_size = float(environment_field.grid_resolution)
	
	var offset = 0
	uniform_bytes.encode_float(offset, float(particle_count))
	offset += 4
	uniform_bytes.encode_float(offset, particle_kernel_radius)
	offset += 4
	uniform_bytes.encode_float(offset, particle_kernel_width)
	offset += 4
	uniform_bytes.encode_float(offset, particle_sigma)
	offset += 4
	uniform_bytes.encode_float(offset, gradient_strength)
	offset += 4
	uniform_bytes.encode_float(offset, repulsion_strength)
	offset += 4
	uniform_bytes.encode_float(offset, min_dist)
	offset += 4
	uniform_bytes.encode_float(offset, delta * time_scale)
	offset += 4
	uniform_bytes.encode_float(offset, field_grid_size)
	offset += 4
	uniform_bytes.encode_float(offset, viewport_size.x)
	offset += 4
	uniform_bytes.encode_float(offset, viewport_size.y)
	offset += 4
	# Padding for std140 alignment (12th float)
	uniform_bytes.encode_float(offset, 0.0)
	
	rd.buffer_update(uniform_buffer, 0, uniform_bytes.size(), uniform_bytes)

func _dispatch_compute(delta: float) -> void:
	_upload_uniforms(delta)
	
	# Calculate workgroup count
	var workgroups = int(ceil(float(particle_count) / float(LOCAL_GROUP_SIZE)))
	
	# Begin compute list
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_sets[current_field_index], 0)
	rd.compute_list_dispatch(compute_list, workgroups, 1, 1)
	rd.compute_list_end()
	
	# Submit and sync
	rd.submit()
	rd.sync()

func _read_velocities() -> void:
	# Read velocities from GPU
	var output_bytes = rd.buffer_get_data(velocity_buffer)
	var output_floats = output_bytes.to_float32_array()
	
	# Unpack velocities and apply smoothing if enabled
	for i in range(particles.size()):
		if i * 2 + 1 < output_floats.size():
			var new_velocity = Vector2(
				output_floats[i * 2],
				output_floats[i * 2 + 1]
			)
			
			if velocity_smoothing <= 0.0:
				particles[i].velocity = new_velocity
			else:
				var s = clamp(velocity_smoothing, 0.0, 1.0)
				particles[i].velocity = particles[i].velocity.lerp(new_velocity, s)

func _update_particles(delta: float) -> void:
	# Update positions based on velocities
	var viewport_size: Vector2 = _get_sim_viewport_size()
	
	for particle in particles:
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

func _draw() -> void:
	if particles.is_empty():
		return

	var radius: float = PARTICLE_RADIUS

	for particle in particles:
		var pos: Vector2 = particle.position
		var col: Color = Color.WHITE

		if environment_field:
			col = environment_field.get_environment_color(pos)

		draw_circle(pos, radius, col)

func _process(delta: float) -> void:
	if not rd:
		return
	if not shader.is_valid():
		return
	if not pipeline.is_valid():
		return
	
	if particles.size() != particle_count:
		spawn_particles()
		_update_buffers()
	
	# 1. Evolve field first (GPU evolution) - enabled in FIELD_ONLY and COUPLED
	if environment_field and (simulation_mode == SimulationMode.FIELD_ONLY or simulation_mode == SimulationMode.COUPLED):
		environment_field.evolve(delta)
		# Update field index to match environment's current buffer
		current_field_index = environment_field.current_buffer
	
	# 2. Particle compute/movement - enabled in SWARM_ON_FROZEN_FIELD and COUPLED
	if simulation_mode == SimulationMode.SWARM_ON_FROZEN_FIELD or simulation_mode == SimulationMode.COUPLED:
		# Upload particle data and dispatch compute
		_upload_positions()
		_upload_mu_locals()
		_dispatch_compute(delta)
		
		# Read results and move particles
		_read_velocities()
		_update_particles(delta)
	
	# 3. GPU deposits (no CPU sync) - enabled only in COUPLED
	if environment_field and simulation_mode == SimulationMode.COUPLED:
		environment_field.deposit_particles_gpu(position_buffer, particle_count, _get_sim_viewport_size())
	
	# 6. Update visualization occasionally (minimal CPU sync only for display)
	# Always update if field exists and should be shown (works in all modes including SWARM_ON_FROZEN_FIELD)
	if environment_field and environment_field.show_field:
		if Engine.get_process_frames() % environment_field.vis_update_interval == 0:
			environment_field.update_display()
	
	queue_redraw()

func _exit_tree() -> void:
	# Cleanup
	for i in range(uniform_sets.size()):
		if uniform_sets[i].is_valid():
			rd.free_rid(uniform_sets[i])
	if uniform_buffer.is_valid():
		rd.free_rid(uniform_buffer)
	if field_buffer.is_valid():
		rd.free_rid(field_buffer)
	if mu_buffer.is_valid():
		rd.free_rid(mu_buffer)
	if velocity_buffer.is_valid():
		rd.free_rid(velocity_buffer)
	if position_buffer.is_valid():
		rd.free_rid(position_buffer)
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)

func _get_sim_viewport_size() -> Vector2:
	## Source of truth for simulation size under SubViewport.
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	var s: Vector2i = vp.size
	return Vector2(float(s.x), float(s.y))
