class_name EnvironmentField
extends Node2D

# Environment Field for spatial mu variation
# GPU-evolved living field with Lenia dynamics
# Provides field values M in [-1, 1] that evolve over time

@export_group("Grid")
## Resolution of the field grid (width × height cells)
@export var grid_resolution: int = 256


@export_group("Field Evolution")
## Center of the Lenia growth curve. Field density grows toward this target value.
@export var field_mu: float = 0.25

## Width of the Lenia growth function. Controls how sharply field responds to density differences.
@export var field_sigma: float = 0.03

## Radius of ring kernel used for field convolution (r0 parameter). Distance from center where kernel peaks.
@export var field_kernel_radius: float = 13.0

## Width of ring kernel used for field convolution (s parameter). Controls how spread out the kernel is.
@export var field_kernel_width: float = 3.0

## Evolution speed multiplier. Higher values = faster field changes. Includes time scaling.
@export var field_dt: float = 0.05

@export_group("Particle Coupling")
## Amount of density each particle deposits into the field per frame.
@export var deposit_amount: float = 0.001

## Radius of Gaussian splat when particles deposit into field.
@export var deposit_radius: float = 20.0

## Natural resting state of field. Field decays toward this value when no particles are present.
@export var field_baseline: float = 0.3

## Decay rate toward baseline. Higher values = faster decay back to baseline.
@export var field_decay: float = 0.01

@export_group("Visualization")
## Enable field visualization background
@export var show_field: bool = true
## Frames between visualization updates (higher = better performance)
@export var vis_update_interval: int = 3

# CPU fallback (for reading)
var values: PackedFloat32Array
var field_min: float = 0.0
var field_max: float = 0.0

# Pre-allocated buffers for uniform uploads
var uniform_bytes_buffer: PackedByteArray  # For field evolution uniforms (32 bytes)
var deposit_uniform_bytes_buffer: PackedByteArray  # For deposit uniforms (32 bytes)
var vis_uniform_bytes_buffer: PackedByteArray  # For visualization uniforms (8 bytes)

# Noise generator (for initial condition)
var noise: FastNoiseLite

# GPU resources
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var field_buffers: Array[RID] = [RID(), RID()]  # ping-pong storage buffers
var uniform_buffer: RID
var uniform_sets: Array[RID] = [RID(), RID()]  # one for each ping-pong direction
var current_buffer: int = 0  # which buffer to read from
var use_gpu: bool = false  # whether GPU is available

# GPU visualization resources
var texture_shader: RID
var texture_pipeline: RID
var vis_texture_rid: RID  # GPU texture
var vis_texture: ImageTexture  # Godot texture wrapper
var vis_texture_uniform_set: RID
var vis_texture_uniform_buffer: RID
var vis_last_buffer_index: int = -1  # Track last buffer index to avoid recreating uniform set
var field_sprite: Sprite2D

# GPU deposit resources
var deposit_shader: RID
var deposit_pipeline: RID
var deposit_uniform_buffer: RID
var deposit_uniform_set: RID
var deposit_last_buffer_index: int = -1  # Track last buffer index to avoid recreating uniform set

func _ready() -> void:
	# Create and configure FastNoiseLite (currently unused, field initialized with Gaussian blobs)
	noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 1.0
	noise.seed = 0
	# GPU init happens later via initialize_gpu()

func initialize_gpu(rendering_device: RenderingDevice) -> void:
	## Initialize GPU compute with a shared RenderingDevice from particle system.
	rd = rendering_device
	if rd != null:
		_setup_compute_shader()
		_create_buffers()
		_initialize_field_from_noise()
		_setup_deposit_shader()
		use_gpu = true
		
		# Pre-allocate uniform buffers
		uniform_bytes_buffer.resize(32)  # Field evolution uniforms
		deposit_uniform_bytes_buffer.resize(32)  # Deposit uniforms
		vis_uniform_bytes_buffer.resize(8)  # Visualization uniforms
		# Ensure visualization exists after we're in-tree (viewport size non-zero)
		if show_field:
			call_deferred("_ensure_visualization_ready")
	else:
		push_error("No RenderingDevice provided")
		_generate_field()  # Fallback to CPU-only mode

func _ensure_visualization_ready() -> void:
	# Must be safe to call multiple times.
	_setup_visualization()
	_apply_show_field_visibility()

func _generate_field() -> void:
	# Generate initial field with multiple Gaussian blob seeds (CPU fallback)
	var size = grid_resolution * grid_resolution
	values.resize(size)
	
	# Start with small baseline
	for i in range(size):
		values[i] = 0.02
	
	# Add multiple Gaussian blobs at random positions
	var num_blobs = 5
	var blob_radius = float(grid_resolution) / 10.0
	
	for b in range(num_blobs):
		var cx = randf() * float(grid_resolution)
		var cy = randf() * float(grid_resolution)
		
		for y in range(grid_resolution):
			for x in range(grid_resolution):
				var dx = float(x) - cx
				var dy = float(y) - cy
				var dist_sq = dx * dx + dy * dy
				var value = 0.8 * exp(-dist_sq / (2.0 * blob_radius * blob_radius))
				var idx = y * grid_resolution + x
				values[idx] += value
	
	# Clamp to [0, 1]
	for i in range(size):
		values[i] = clamp(values[i], 0.0, 1.0)
	
	# Update field range
	var min_v: float = 1e20
	var max_v: float = -1e20
	for v in values:
		if v < min_v:
			min_v = v
		if v > max_v:
			max_v = v
	field_min = min_v
	field_max = max_v

func _setup_compute_shader():
	# Load shader file as text
	var shader_file := FileAccess.open("res://shaders/field_evolution.glsl", FileAccess.READ)
	if shader_file == null:
		push_error("Failed to load field_evolution.glsl")
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

func _create_buffers():
	# Calculate buffer size: grid_resolution * grid_resolution * 1 float * 4 bytes
	var buffer_size = grid_resolution * grid_resolution * 4
	
	# Create two storage buffers for ping-pong
	for i in range(2):
		field_buffers[i] = rd.storage_buffer_create(buffer_size)
		if not field_buffers[i].is_valid():
			push_error("Failed to create field buffer " + str(i))
			return
	
	# Create uniform buffer (6 floats: grid_size, kernel_radius, kernel_width, mu, sigma, dt)
	# std140 alignment requires 32-byte alignment, so we use 32 bytes
	var uniform_buffer_size = 32
	uniform_buffer = rd.uniform_buffer_create(uniform_buffer_size)
	if not uniform_buffer.is_valid():
		push_error("Failed to create uniform buffer")
		return
	
	# Create uniform sets for both ping-pong directions
	# Set 0: read from buffer[0], write to buffer[1]
	var read_uniform_0 := RDUniform.new()
	read_uniform_0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	read_uniform_0.binding = 0
	read_uniform_0.add_id(field_buffers[0])
	
	var write_uniform_0 := RDUniform.new()
	write_uniform_0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	write_uniform_0.binding = 1
	write_uniform_0.add_id(field_buffers[1])
	
	var params_uniform_0 := RDUniform.new()
	params_uniform_0.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform_0.binding = 2
	params_uniform_0.add_id(uniform_buffer)
	
	uniform_sets[0] = rd.uniform_set_create([read_uniform_0, write_uniform_0, params_uniform_0], shader, 0)
	if not uniform_sets[0].is_valid():
		push_error("Failed to create uniform set 0")
		return
	
	# Set 1: read from buffer[1], write to buffer[0]
	var read_uniform_1 := RDUniform.new()
	read_uniform_1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	read_uniform_1.binding = 0
	read_uniform_1.add_id(field_buffers[1])
	
	var write_uniform_1 := RDUniform.new()
	write_uniform_1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	write_uniform_1.binding = 1
	write_uniform_1.add_id(field_buffers[0])
	
	var params_uniform_1 := RDUniform.new()
	params_uniform_1.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform_1.binding = 2
	params_uniform_1.add_id(uniform_buffer)
	
	uniform_sets[1] = rd.uniform_set_create([read_uniform_1, write_uniform_1, params_uniform_1], shader, 0)
	if not uniform_sets[1].is_valid():
		push_error("Failed to create uniform set 1")
		return

func _setup_deposit_shader() -> void:
	## Load and compile particle deposit compute shader.
	var shader_file := FileAccess.open("res://shaders/particle_deposit.glsl", FileAccess.READ)
	if shader_file == null:
		push_error("Failed to load particle_deposit.glsl")
		return
	
	var shader_code := shader_file.get_as_text()
	shader_file.close()
	
	if shader_code.is_empty():
		push_error("Deposit shader source is empty")
		return
	
	var shader_source := RDShaderSource.new()
	shader_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, shader_code)
	
	var shader_spirv := rd.shader_compile_spirv_from_source(shader_source)
	var compile_error := shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	
	if compile_error != "":
		push_error("Deposit shader compile error: " + compile_error)
		return
	
	deposit_shader = rd.shader_create_from_spirv(shader_spirv)
	if not deposit_shader.is_valid():
		push_error("Failed to create deposit shader")
		return
	
	deposit_pipeline = rd.compute_pipeline_create(deposit_shader)
	if not deposit_pipeline.is_valid():
		push_error("Failed to create deposit pipeline")
		return
	
	# Create uniform buffer for deposit shader (8 floats: grid_size, particle_count, deposit_amount, deposit_radius, viewport_width, viewport_height, field_baseline, field_decay)
	# std140 alignment: 8 floats = 32 bytes (exactly 2 vec4s)
	deposit_uniform_buffer = rd.uniform_buffer_create(32)
	if not deposit_uniform_buffer.is_valid():
		push_error("Failed to create deposit uniform buffer")
		return

func _initialize_field_from_noise():
	# Generate initial field with multiple Gaussian blob seeds
	var size = grid_resolution * grid_resolution
	values.resize(size)
	
	# Start with small baseline
	for i in range(size):
		values[i] = 0.02
	
	# Add multiple Gaussian blobs at random positions
	var num_blobs = 5
	var blob_radius = float(grid_resolution) / 10.0
	
	for b in range(num_blobs):
		var cx = randf() * float(grid_resolution)
		var cy = randf() * float(grid_resolution)
		
		for y in range(grid_resolution):
			for x in range(grid_resolution):
				var dx = float(x) - cx
				var dy = float(y) - cy
				var dist_sq = dx * dx + dy * dy
				var value = 0.8 * exp(-dist_sq / (2.0 * blob_radius * blob_radius))
				var idx = y * grid_resolution + x
				values[idx] += value
	
	# Clamp to [0, 1]
	for i in range(size):
		values[i] = clamp(values[i], 0.0, 1.0)
	
	# Update field range
	var min_v: float = 1e20
	var max_v: float = -1e20
	for v in values:
		if v < min_v:
			min_v = v
		if v > max_v:
			max_v = v
	field_min = min_v
	field_max = max_v
	
	# Upload to GPU buffer 0
	var initial_data := PackedByteArray()
	initial_data.resize(grid_resolution * grid_resolution * 4)
	
	for i in range(values.size()):
		initial_data.encode_float(i * 4, values[i])
	
	rd.buffer_update(field_buffers[0], 0, initial_data.size(), initial_data)

func _upload_uniforms(delta: float):
	# Pack uniform buffer with parameters using pre-allocated buffer
	var uniform_bytes := uniform_bytes_buffer
	
	var offset = 0
	uniform_bytes.encode_float(offset, float(grid_resolution))
	offset += 4
	uniform_bytes.encode_float(offset, field_kernel_radius)
	offset += 4
	uniform_bytes.encode_float(offset, field_kernel_width)
	offset += 4
	uniform_bytes.encode_float(offset, field_mu)
	offset += 4
	uniform_bytes.encode_float(offset, field_sigma)
	offset += 4
	uniform_bytes.encode_float(offset, delta * field_dt)
	
	rd.buffer_update(uniform_buffer, 0, uniform_bytes.size(), uniform_bytes)

func evolve(delta: float) -> void:
	## Evolve the field one time step. Called by particle system to control frame order.
	if not use_gpu:
		return
	if not shader.is_valid() or not pipeline.is_valid():
		return
	
	_upload_uniforms(delta)
	
	# Calculate workgroups (8x8 local size from shader)
	var workgroups = int(ceil(float(grid_resolution) / 8.0))
	
	# Begin compute list
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_sets[current_buffer], 0)
	rd.compute_list_dispatch(compute_list, workgroups, workgroups, 1)  # 2D dispatch
	rd.compute_list_end()
	
	# Submit and sync
	rd.submit()
	rd.sync()
	
	# Swap buffers
	current_buffer = 1 - current_buffer

func sync_to_cpu() -> void:
	## Sync field from GPU to CPU for sampling. Called by particle system.
	## NOTE: Visualization is now GPU-only, no CPU sync needed for that.
	## NOTE: This should only be called for debug/sampling, not in hot path.
	if not use_gpu:
		return
	_read_field_to_cpu()

func update_display() -> void:
	## Update visualization (GPU-only, minimal CPU sync for display).
	## Called occasionally, not every frame.
	if not show_field or not use_gpu:
		return
	# Ensure visualization exists
	if field_sprite == null or vis_texture == null:
		_setup_visualization()
	_apply_show_field_visibility()
	if field_sprite == null or vis_texture == null:
		return
	_update_visualization()

func _read_field_to_cpu():
	# Read current field buffer to CPU for sampling
	var output_buf = field_buffers[current_buffer]
	var byte_data = rd.buffer_get_data(output_buf)
	var float_data = byte_data.to_float32_array()
	
	# Update values array
	values.resize(grid_resolution * grid_resolution)
	for i in range(min(values.size(), float_data.size())):
		values[i] = float_data[i]
	
	# Update min/max for color mapping
	var min_v: float = 1e20
	var max_v: float = -1e20
	for v in values:
		if v < min_v:
			min_v = v
		if v > max_v:
			max_v = v
	field_min = min_v
	field_max = max_v

func get_field_data() -> PackedFloat32Array:
	## Get the current field data array (for particle shader upload).
	## NOTE: Deprecated - use get_current_field_buffer() for GPU access instead.
	return values

func get_current_field_buffer() -> RID:
	## Get the current field buffer RID for direct GPU access.
	## Returns the buffer that will be read from (current_buffer after evolution).
	return field_buffers[current_buffer]

func get_field_buffer(index: int) -> RID:
	## Get a specific field buffer by index (0 or 1 for ping-pong buffers).
	if index >= 0 and index < field_buffers.size():
		return field_buffers[index]
	return RID()

func deposit_particles(positions: PackedVector2Array) -> void:
	## Deposit particle density into the field (CPU fallback).
	## NOTE: Use deposit_particles_gpu() for GPU-based deposits.
	if not use_gpu:
		# If GPU not available, deposit directly to CPU values
		_deposit_to_cpu(positions)
		return
	
	# Ensure we have latest field data on CPU
	if values.size() != grid_resolution * grid_resolution:
		_read_field_to_cpu()
	
	# Deposit to CPU field
	_deposit_to_cpu(positions)
	
	# Update min/max after deposits
	var min_v: float = 1e20
	var max_v: float = -1e20
	for v in values:
		if v < min_v:
			min_v = v
		if v > max_v:
			max_v = v
	field_min = min_v
	field_max = max_v

func deposit_particles_gpu(position_buffer: RID, particle_count: int, viewport_size: Vector2) -> void:
	## GPU-based particle deposit. No CPU sync required.
	if not use_gpu:
		return
	if not deposit_pipeline.is_valid():
		return
	
	# Update uniform buffer using pre-allocated buffer
	var uniform_bytes := deposit_uniform_bytes_buffer
	var offset = 0
	uniform_bytes.encode_float(offset, float(grid_resolution))
	offset += 4
	uniform_bytes.encode_float(offset, float(particle_count))
	offset += 4
	uniform_bytes.encode_float(offset, deposit_amount)
	offset += 4
	uniform_bytes.encode_float(offset, deposit_radius)
	offset += 4
	uniform_bytes.encode_float(offset, viewport_size.x)
	offset += 4
	uniform_bytes.encode_float(offset, viewport_size.y)
	offset += 4
	uniform_bytes.encode_float(offset, field_baseline)
	offset += 4
	uniform_bytes.encode_float(offset, field_decay)
	rd.buffer_update(deposit_uniform_buffer, 0, uniform_bytes.size(), uniform_bytes)
	
	# Create/update uniform set only if buffer index changed or doesn't exist
	if deposit_last_buffer_index != current_buffer or not deposit_uniform_set.is_valid():
		if deposit_uniform_set.is_valid():
			rd.free_rid(deposit_uniform_set)
		
		var field_uniform := RDUniform.new()
		field_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		field_uniform.binding = 0
		field_uniform.add_id(field_buffers[current_buffer])  # Write to current buffer
		
		var position_uniform := RDUniform.new()
		position_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		position_uniform.binding = 1
		position_uniform.add_id(position_buffer)
		
		var params_uniform := RDUniform.new()
		params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		params_uniform.binding = 2
		params_uniform.add_id(deposit_uniform_buffer)
		
		deposit_uniform_set = rd.uniform_set_create([field_uniform, position_uniform, params_uniform], deposit_shader, 0)
		deposit_last_buffer_index = current_buffer
	
	# Dispatch compute shader
	var workgroups = int(ceil(float(grid_resolution) / 8.0))
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, deposit_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, deposit_uniform_set, 0)
	rd.compute_list_dispatch(compute_list, workgroups, workgroups, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()

func _deposit_to_cpu(positions: PackedVector2Array) -> void:
	## Internal method to deposit particles into CPU field buffer.
	if values.size() != grid_resolution * grid_resolution:
		values.resize(grid_resolution * grid_resolution)
	
	var viewport_size: Vector2 = _get_sim_viewport_size()
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	
	var deposit_radius_sq = deposit_radius * deposit_radius
	var search_pixels = int(ceil(deposit_radius * 2.0))
	
	for pos in positions:
		# Convert world position to grid coordinates
		var u: float = clamp(pos.x / viewport_size.x, 0.0, 1.0)
		var v: float = clamp(pos.y / viewport_size.y, 0.0, 1.0)
		
		var grid_x: float = u * float(grid_resolution - 1)
		var grid_y: float = v * float(grid_resolution - 1)
		
		var center_x: int = int(round(grid_x))
		var center_y: int = int(round(grid_y))
		
		# Deposit Gaussian splat to nearby cells
		for dy in range(-search_pixels, search_pixels + 1):
			for dx in range(-search_pixels, search_pixels + 1):
				var cell_x = center_x + dx
				var cell_y = center_y + dy
				
				# Wrap coordinates (toroidal)
				cell_x = (cell_x + grid_resolution) % grid_resolution
				cell_y = (cell_y + grid_resolution) % grid_resolution
				
				# Distance from particle center
				var dist_x = float(dx)
				var dist_y = float(dy)
				var dist_sq = dist_x * dist_x + dist_y * dist_y
				
				# Skip if beyond deposit radius
				if dist_sq > deposit_radius_sq:
					continue
				
				# Gaussian splat: deposit_amount * exp(-dist²/(2*radius²))
				var splat = deposit_amount * exp(-dist_sq / (2.0 * deposit_radius_sq))
				
				# Add to field
				var idx = cell_y * grid_resolution + cell_x
				if idx >= 0 and idx < values.size():
					values[idx] += splat

func sync_field_to_gpu() -> void:
	## Upload CPU field data back to GPU buffer after deposits.
	if not use_gpu:
		return
	
	# Upload to current buffer (the one we'll read from next)
	var field_data := PackedByteArray()
	field_data.resize(grid_resolution * grid_resolution * 4)
	
	for i in range(values.size()):
		field_data.encode_float(i * 4, values[i])
	
	rd.buffer_update(field_buffers[current_buffer], 0, field_data.size(), field_data)

func sample(world_pos: Vector2) -> float:
	if grid_resolution <= 1:
		return 0.0
	
	# If using GPU, ensure we have latest data
	if use_gpu and values.size() != grid_resolution * grid_resolution:
		_read_field_to_cpu()
	
	if values.size() == 0:
		return 0.0
	
	var viewport_size: Vector2 = _get_sim_viewport_size()
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return 0.0
	
	var u: float = clamp(world_pos.x / viewport_size.x, 0.0, 1.0)
	var v: float = clamp(world_pos.y / viewport_size.y, 0.0, 1.0)
	
	var fx: float = u * float(grid_resolution - 1)
	var fy: float = v * float(grid_resolution - 1)
	
	var x0: int = int(fx)
	var y0: int = int(fy)
	var x1: int = min(x0 + 1, grid_resolution - 1)
	var y1: int = min(y0 + 1, grid_resolution - 1)
	
	var tx: float = fx - float(x0)
	var ty: float = fy - float(y0)
	
	var idx00: int = y0 * grid_resolution + x0
	var idx10: int = y0 * grid_resolution + x1
	var idx01: int = y1 * grid_resolution + x0
	var idx11: int = y1 * grid_resolution + x1
	
	if idx00 >= values.size() or idx11 >= values.size():
		return 0.0
	
	var v00: float = values[idx00]
	var v10: float = values[idx10]
	var v01: float = values[idx01]
	var v11: float = values[idx11]
	
	var v0: float = lerp(v00, v10, tx)
	var v1: float = lerp(v01, v11, tx)
	var v_final: float = lerp(v0, v1, ty)
	
	return v_final

func get_environment_color(world_pos: Vector2) -> Color:
	if values.is_empty():
		return Color.WHITE
	
	var vp_size: Vector2 = _get_sim_viewport_size()
	
	var u: float = clamp(world_pos.x / vp_size.x, 0.0, 1.0)
	var v: float = clamp(world_pos.y / vp_size.y, 0.0, 1.0)
	
	var gx: float = u * float(grid_resolution - 1)
	var gy: float = v * float(grid_resolution - 1)
	
	var x0: int = int(floor(gx))
	var y0: int = int(floor(gy))
	var x1: int = min(x0 + 1, grid_resolution - 1)
	var y1: int = min(y0 + 1, grid_resolution - 1)
	
	var tx: float = gx - float(x0)
	var ty: float = gy - float(y0)
	
	var idx00: int = y0 * grid_resolution + x0
	var idx10: int = y0 * grid_resolution + x1
	var idx01: int = y1 * grid_resolution + x0
	var idx11: int = y1 * grid_resolution + x1
	
	var v00: float = values[idx00]
	var v10: float = values[idx10]
	var v01: float = values[idx01]
	var v11: float = values[idx11]
	
	var v0: float = lerp(v00, v10, tx)
	var v1: float = lerp(v01, v11, tx)
	var v_sample: float = lerp(v0, v1, ty)
	
	# Color mapping: dark -> green (at mu) -> yellow -> red
	# NOTE: This must match the color mapping in field_to_texture.glsl
	var value: float = clamp(v_sample, 0.0, 1.0)
	var color: Vector3
	
	if value < field_mu:
		var t: float = value / max(field_mu, 0.001)
		var dark: Vector3 = Vector3(0.0, 0.0, 0.1)
		var green: Vector3 = Vector3(0.0, 0.7, 0.2)
		color = dark.lerp(green, t)
	else:
		var t: float = (value - field_mu) / max(1.0 - field_mu, 0.001)
		var green: Vector3 = Vector3(0.0, 0.7, 0.2)
		var yellow: Vector3 = Vector3(0.9, 0.9, 0.0)
		var red: Vector3 = Vector3(1.0, 0.2, 0.0)
		
		if t < 0.5:
			color = green.lerp(yellow, t * 2.0)
		else:
			color = yellow.lerp(red, (t - 0.5) * 2.0)
	
	return Color(color.x, color.y, color.z, 1.0)

# _process() removed - field evolution is now driven by particle system
# This ensures explicit frame ordering: field evolves -> particles compute -> particles deposit

func _setup_visualization() -> void:
	## Set up GPU-based field visualization.
	if not show_field or not use_gpu:
		return
	
	_setup_texture_shader()
	_create_texture()
	_setup_field_sprite()
	_update_field_sprite_scale()
	_apply_show_field_visibility()

func _setup_texture_shader() -> void:
	## Load and compile field-to-texture compute shader.
	var shader_file := FileAccess.open("res://shaders/field_to_texture.glsl", FileAccess.READ)
	if shader_file == null:
		push_error("Failed to load field_to_texture.glsl")
		return
	
	var shader_code := shader_file.get_as_text()
	shader_file.close()
	
	if shader_code.is_empty():
		push_error("Texture shader source is empty")
		return
	
	var shader_source := RDShaderSource.new()
	shader_source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, shader_code)
	
	var shader_spirv := rd.shader_compile_spirv_from_source(shader_source)
	var compile_error := shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	
	if compile_error != "":
		push_error("Texture shader compile error: " + compile_error)
		return
	
	texture_shader = rd.shader_create_from_spirv(shader_spirv)
	if not texture_shader.is_valid():
		push_error("Failed to create texture shader")
		return
	
	texture_pipeline = rd.compute_pipeline_create(texture_shader)
	if not texture_pipeline.is_valid():
		push_error("Failed to create texture pipeline")
		return

func _create_texture() -> void:
	## Create GPU texture for visualization.
	# Check if field buffers are valid
	if not field_buffers[current_buffer].is_valid():
		push_error("Field buffer is not valid, cannot create texture")
		return
	
	# Create RGBA8 texture using RDTextureFormat
	var texture_format := RDTextureFormat.new()
	texture_format.width = grid_resolution
	texture_format.height = grid_resolution
	texture_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	
	var texture_view := RDTextureView.new()
	vis_texture_rid = rd.texture_create(texture_format, texture_view)
	if not vis_texture_rid.is_valid():
		push_error("Failed to create visualization texture")
		return
	
	# Create ImageTexture wrapper for display
	# Create empty image first, will be updated by compute shader
	var image = Image.create(grid_resolution, grid_resolution, false, Image.FORMAT_RGBA8)
	vis_texture = ImageTexture.create_from_image(image)
	
	# Create uniform buffer for texture shader
	# std140 alignment: 2 floats = 8 bytes, but must be padded to 16 bytes for std140 alignment
	vis_texture_uniform_buffer = rd.uniform_buffer_create(16)  # 2 floats: grid_size, field_mu (padded to 16 bytes)
	if not vis_texture_uniform_buffer.is_valid():
		push_error("Failed to create texture uniform buffer")
		return
	
	# Create uniform set for texture shader
	var field_uniform := RDUniform.new()
	field_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	field_uniform.binding = 0
	field_uniform.add_id(field_buffers[current_buffer])
	
	var texture_uniform := RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	texture_uniform.binding = 1
	texture_uniform.add_id(vis_texture_rid)
	
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 2
	params_uniform.add_id(vis_texture_uniform_buffer)
	
	vis_texture_uniform_set = rd.uniform_set_create([field_uniform, texture_uniform, params_uniform], texture_shader, 0)
	if not vis_texture_uniform_set.is_valid():
		push_error("Failed to create texture uniform set")
		return

func _setup_field_sprite() -> void:
	## Create Sprite2D for displaying field visualization in world-space.
	if vis_texture == null:
		return
	if field_sprite == null:
		field_sprite = Sprite2D.new()
		field_sprite.name = "FieldSprite"
		field_sprite.centered = false
		field_sprite.position = Vector2.ZERO
		field_sprite.z_index = -100
		add_child(field_sprite)

	field_sprite.texture = vis_texture

	# Handle resize (once)
	if get_viewport() and not get_viewport().size_changed.is_connected(_on_viewport_resize):
		get_viewport().size_changed.connect(_on_viewport_resize)

func _on_viewport_resize() -> void:
	## Handle viewport resize for visualization scaling.
	_update_field_sprite_scale()

func _update_field_sprite_scale() -> void:
	if field_sprite == null or vis_texture == null:
		return
	var vp_size: Vector2 = _get_sim_viewport_size()
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return
	var tex_size: Vector2 = vis_texture.get_size()
	if tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return
	field_sprite.scale = Vector2(vp_size.x / tex_size.x, vp_size.y / tex_size.y)

func _apply_show_field_visibility() -> void:
	if field_sprite != null:
		field_sprite.visible = show_field

func _update_visualization() -> void:
	## Update visualization texture from GPU field buffer (GPU-only, no CPU sync).
	if not show_field or not use_gpu:
		return
	if not texture_pipeline.is_valid() or not vis_texture_rid.is_valid():
		return
	
	# Update uniform buffer using pre-allocated buffer
	var uniform_bytes := vis_uniform_bytes_buffer
	uniform_bytes.encode_float(0, float(grid_resolution))
	uniform_bytes.encode_float(4, field_mu)
	rd.buffer_update(vis_texture_uniform_buffer, 0, uniform_bytes.size(), uniform_bytes)
	
	# Update uniform set with current field buffer only if buffer index changed or doesn't exist
	if vis_last_buffer_index != current_buffer or not vis_texture_uniform_set.is_valid():
		if vis_texture_uniform_set.is_valid():
			rd.free_rid(vis_texture_uniform_set)
		
		var field_uniform := RDUniform.new()
		field_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		field_uniform.binding = 0
		field_uniform.add_id(field_buffers[current_buffer])
		
		var texture_uniform := RDUniform.new()
		texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		texture_uniform.binding = 1
		texture_uniform.add_id(vis_texture_rid)
		
		var params_uniform := RDUniform.new()
		params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		params_uniform.binding = 2
		params_uniform.add_id(vis_texture_uniform_buffer)
		
		vis_texture_uniform_set = rd.uniform_set_create([field_uniform, texture_uniform, params_uniform], texture_shader, 0)
		vis_last_buffer_index = current_buffer
	
	# Dispatch compute shader
	var workgroups = int(ceil(float(grid_resolution) / 8.0))
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, texture_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, vis_texture_uniform_set, 0)
	rd.compute_list_dispatch(compute_list, workgroups, workgroups, 1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()
	
	# Copy GPU texture to ImageTexture for display (minimal CPU sync)
	_sync_texture_to_display()

func _sync_texture_to_display() -> void:
	## Copy GPU texture to ImageTexture for display (called after compute shader writes).
	if not vis_texture_rid.is_valid() or vis_texture == null:
		return
	
	# Read texture data from GPU
	var image_data = rd.texture_get_data(vis_texture_rid, 0)
	if image_data.size() > 0:
		var image = Image.create_from_data(grid_resolution, grid_resolution, false, Image.FORMAT_RGBA8, image_data)
		vis_texture.update(image)
		if field_sprite != null:
			field_sprite.texture = vis_texture
			_update_field_sprite_scale()

func _exit_tree():
	# Cleanup GPU resources
	if use_gpu and rd != null:
		if uniform_sets.size() > 0:
			for i in range(2):
				if uniform_sets[i].is_valid():
					rd.free_rid(uniform_sets[i])
		
		if field_buffers.size() > 0:
			for i in range(2):
				if field_buffers[i].is_valid():
					rd.free_rid(field_buffers[i])
		
		if uniform_buffer.is_valid():
			rd.free_rid(uniform_buffer)
		
		if pipeline.is_valid():
			rd.free_rid(pipeline)
		
		if shader.is_valid():
			rd.free_rid(shader)
		
		# Cleanup deposit resources
		if deposit_uniform_set.is_valid():
			rd.free_rid(deposit_uniform_set)
		if deposit_uniform_buffer.is_valid():
			rd.free_rid(deposit_uniform_buffer)
		if deposit_pipeline.is_valid():
			rd.free_rid(deposit_pipeline)
		if deposit_shader.is_valid():
			rd.free_rid(deposit_shader)
		
		# Cleanup visualization resources
		if vis_texture_uniform_set.is_valid():
			rd.free_rid(vis_texture_uniform_set)
		if vis_texture_uniform_buffer.is_valid():
			rd.free_rid(vis_texture_uniform_buffer)
		if vis_texture_rid.is_valid():
			rd.free_rid(vis_texture_rid)
		if texture_pipeline.is_valid():
			rd.free_rid(texture_pipeline)
		if texture_shader.is_valid():
			rd.free_rid(texture_shader)

func _get_sim_viewport_size() -> Vector2:
	## Source of truth for simulation size under SubViewport.
	var vp := get_viewport()
	if vp == null:
		return Vector2.ZERO
	var s: Vector2i = vp.size
	return Vector2(float(s.x), float(s.y))
