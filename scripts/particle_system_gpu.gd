extends Node2D

const PARTICLE_RADIUS = 2.0
const LOCAL_GROUP_SIZE = 64

@export_group("Particles")
## Number of particles in the simulation.
@export var particle_count: int = 50

## Minimum distance between particles. Repulsion activates below this.
@export var min_dist: float = 10.0

@export_group("Particle Interactions")
## Radius of ring kernel for particle-particle interactions (r0 parameter).
@export var particle_kernel_radius: float = 50.0

## Width of ring kernel for particle-particle interactions (s parameter).
@export var particle_kernel_width: float = 15.0

## Width of growth function for particles. Controls response to density differences.
@export var particle_sigma: float = 0.02

@export_group("Environment Coupling")
## Base mu value for particles. Combined with environment field to set per-particle mu.
## NOTE: Will be deprecated in Phase 3 when particles follow field gradient directly.
@export var mu_base: float = 0.04

## Range of mu variation from environment field. mu = mu_base ± mu_range.
## NOTE: Will be deprecated in Phase 3.
@export var mu_range: float = 0.02

## Reference to the environment field that particles interact with.
@export var environment_field: EnvironmentField = null

@export_group("Forces")
## Strength of gradient-based movement force.
@export var gradient_strength: float = 100.0

## Strength of particle repulsion force.
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
var field_buffer: RID
var uniform_buffer: RID
var uniform_set: RID

var particles: Array[Particle] = []
var positions_data: PackedFloat32Array
var velocities_data: PackedFloat32Array
var mu_data: PackedFloat32Array

func _ready():
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Failed to create RenderingDevice")
		return
	
	_setup_compute_shader()
	spawn_particles()
	_update_buffers()

func _setup_compute_shader():
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

func _create_buffers():
	# Calculate buffer sizes
	var vec2_size = 2 * 4  # 2 floats * 4 bytes each
	var buffer_size = particle_count * vec2_size
	var float_size = 4  # 1 float * 4 bytes
	
	# Create position buffer
	positions_data.resize(particle_count * 2)
	position_buffer = rd.storage_buffer_create(buffer_size)
	
	# Create velocity buffer
	velocities_data.resize(particle_count * 2)
	velocity_buffer = rd.storage_buffer_create(buffer_size)
	
	# Create mu buffer (one float per particle)
	mu_data.resize(particle_count)
	var mu_buffer_size = particle_count * float_size
	mu_buffer = rd.storage_buffer_create(mu_buffer_size)
	
	# Create field buffer (read-only, will be resized when field is available)
	# Initial size: 0, will be resized in _upload_field() when environment_field is set
	field_buffer = rd.storage_buffer_create(0)
	
	# Create uniform buffer (48 bytes = 12 floats for std140 alignment)
	var uniform_data = PackedByteArray()
	uniform_data.resize(48)  # 12 floats * 4 bytes
	uniform_buffer = rd.uniform_buffer_create(48)
	
	# Create uniform set with updated bindings:
	# binding 0: positions
	# binding 1: velocities
	# binding 2: mu_locals
	# binding 3: params (uniform buffer)
	# binding 4: field (read-only storage buffer)
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
	field_uniform.add_id(field_buffer)
	
	uniform_set = rd.uniform_set_create([pos_uniform, vel_uniform, mu_uniform, params_uniform, field_uniform], shader, 0)

func _update_buffers():
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
	
	# Field buffer will be resized in _upload_field() if environment_field is available
	# Don't recreate it here, just ensure it exists
	if not field_buffer.is_valid():
		field_buffer = rd.storage_buffer_create(0)
	
	# Recreate uniform set with updated bindings
	if uniform_set.is_valid():
		rd.free_rid(uniform_set)
	
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
	field_uniform.add_id(field_buffer)
	
	uniform_set = rd.uniform_set_create([pos_uniform, vel_uniform, mu_uniform, params_uniform, field_uniform], shader, 0)

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

func _upload_positions():
	# Pack positions into float array
	for i in range(particles.size()):
		positions_data[i * 2] = particles[i].position.x
		positions_data[i * 2 + 1] = particles[i].position.y
	
	# Upload to GPU
	var position_bytes = positions_data.to_byte_array()
	rd.buffer_update(position_buffer, 0, position_bytes.size(), position_bytes)

func _upload_mu_locals():
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

func _upload_uniforms(delta: float):
	# Pack uniforms into byte array (48 bytes = 12 floats for std140 alignment)
	var uniform_bytes = PackedByteArray()
	uniform_bytes.resize(48)
	
	var viewport_size = get_viewport_rect().size
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

func _upload_field():
	## Upload field data from environment_field to GPU buffer.
	if not environment_field:
		return
	
	var field_data = environment_field.get_field_data()
	if field_data.is_empty():
		return
	
	var grid_res = environment_field.grid_resolution
	var buffer_size = grid_res * grid_res * 4  # 1 float per cell * 4 bytes
	
	# Resize buffer if needed
	if not field_buffer.is_valid() or buffer_size != rd.buffer_get_size(field_buffer):
		if field_buffer.is_valid():
			rd.free_rid(field_buffer)
		field_buffer = rd.storage_buffer_create(buffer_size)
		
		# Recreate uniform set with new field buffer
		if uniform_set.is_valid():
			rd.free_rid(uniform_set)
		
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
		field_uniform.add_id(field_buffer)
		
		uniform_set = rd.uniform_set_create([pos_uniform, vel_uniform, mu_uniform, params_uniform, field_uniform], shader, 0)
	
	# Upload field data
	var field_bytes = field_data.to_byte_array()
	rd.buffer_update(field_buffer, 0, field_bytes.size(), field_bytes)

func _dispatch_compute(delta: float):
	_upload_uniforms(delta)
	
	# Calculate workgroup count
	var workgroups = int(ceil(float(particle_count) / float(LOCAL_GROUP_SIZE)))
	
	# Begin compute list
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	rd.compute_list_dispatch(compute_list, workgroups, 1, 1)
	rd.compute_list_end()
	
	# Submit and sync
	rd.submit()
	rd.sync()

func _read_velocities():
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

func _update_particles(delta: float):
	# Update positions based on velocities
	var viewport_size = get_viewport_rect().size
	
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

func _process(delta):
	if not rd:
		return
	if not shader.is_valid():
		return
	if not pipeline.is_valid():
		return
	
	if particles.size() != particle_count:
		spawn_particles()
		_update_buffers()
	
	# 1. Upload field to GPU (BEFORE compute so particles see current field)
	_upload_field()
	
	# 2-4. Upload particle data and dispatch compute
	_upload_positions()
	_upload_mu_locals()
	_dispatch_compute(delta)
	
	# 5-6. Read results and update positions
	_read_velocities()
	_update_particles(delta)
	
	# 7-8. Deposit particles to field and sync back to GPU
	if environment_field:
		var positions = PackedVector2Array()
		for p in particles:
			positions.append(p.position)
		environment_field.deposit_particles(positions)
		environment_field.sync_field_to_gpu()
	
	queue_redraw()

func _exit_tree():
	# Cleanup
	if uniform_set.is_valid():
		rd.free_rid(uniform_set)
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
