class_name EnvironmentField
extends Node2D

# Environment Field for spatial mu variation
# GPU-evolved living field with Lenia dynamics
# Provides field values M in [-1, 1] that evolve over time

@export_group("Grid")
## Resolution of the field grid (width × height cells)
@export var grid_resolution: int = 256

## Frequency of Perlin noise used for initial field condition (not used during evolution)
@export var noise_frequency: float = 3.0

@export_group("Field Evolution")
## Target density for Lenia growth function. Field grows toward this value.
@export var field_mu: float = 0.04

## Width of growth function. Controls how sharply field responds to density differences.
@export var field_sigma: float = 0.02

## Radius of ring kernel used for field convolution (r0 parameter).
@export var field_kernel_radius: float = 50.0

## Width of ring kernel used for field convolution (s parameter).
@export var field_kernel_width: float = 15.0

## Evolution speed multiplier. Higher values = faster field changes. Includes time scaling.
@export var field_dt: float = 0.1

## Amount of density each particle deposits into the field per frame.
@export var deposit_amount: float = 0.01

## Radius of Gaussian splat when particles deposit into field.
@export var deposit_radius: float = 20.0

# CPU fallback (for reading)
var values: PackedFloat32Array
var field_min: float = 0.0
var field_max: float = 0.0

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

func _ready() -> void:
	# Create and configure FastNoiseLite
	noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 1.0  # Use 1.0 as base, we multiply by noise_frequency in sampling
	noise.seed = 0
	
	# Try to initialize GPU compute
	rd = RenderingServer.create_local_rendering_device()
	if rd != null:
		_setup_compute_shader()
		_create_buffers()
		_initialize_field_from_noise()
		use_gpu = true
		print("ENV_FIELD: GPU compute initialized")
	else:
		push_error("Failed to create RenderingDevice, falling back to CPU")
		_generate_field()  # Fallback to CPU-only mode

func _generate_field() -> void:
	values.resize(grid_resolution * grid_resolution)
	
	var min_v: float = 1e20
	var max_v: float = -1e20
	
	for y in range(grid_resolution):
		for x in range(grid_resolution):
			var nx: float = float(x) / float(grid_resolution)
			var ny: float = float(y) / float(grid_resolution)
			
			var v: float = noise.get_noise_2d(nx * noise_frequency, ny * noise_frequency)
			var idx: int = y * grid_resolution + x
			values[idx] = v
			
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

func _initialize_field_from_noise():
	# Generate initial field from Perlin noise (same as _generate_field but upload to GPU)
	values.resize(grid_resolution * grid_resolution)
	
	var min_v: float = 1e20
	var max_v: float = -1e20
	
	for y in range(grid_resolution):
		for x in range(grid_resolution):
			var nx: float = float(x) / float(grid_resolution)
			var ny: float = float(y) / float(grid_resolution)
			
			var v: float = noise.get_noise_2d(nx * noise_frequency, ny * noise_frequency)
			var idx: int = y * grid_resolution + x
			values[idx] = v
			
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
	# Pack uniform buffer with parameters
	var uniform_bytes := PackedByteArray()
	uniform_bytes.resize(32)  # 6 floats padded to 32 bytes (std140 alignment)
	
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

func _dispatch_compute(delta: float):
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
	return values

func deposit_particles(positions: PackedVector2Array) -> void:
	## Deposit particle density into the field.
	## Takes array of particle world positions and adds Gaussian splats to field.
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

func _deposit_to_cpu(positions: PackedVector2Array) -> void:
	## Internal method to deposit particles into CPU field buffer.
	if values.size() != grid_resolution * grid_resolution:
		values.resize(grid_resolution * grid_resolution)
	
	var viewport_size: Vector2 = get_viewport_rect().size
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
	
	var viewport_size: Vector2 = get_viewport_rect().size
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
	
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	
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
	
	var range_v: float = max(field_max - field_min, 0.0001)
	var t: float = clamp((v_sample - field_min) / range_v, 0.0, 1.0)
	
	return Color.from_hsv(
		lerp(0.65, 0.05, t),
		0.7,
		0.9,
		1.0
	)

func _process(delta: float):
	if not use_gpu:
		return
	if not shader.is_valid() or not pipeline.is_valid():
		return
	
	# Evolve field on GPU
	_dispatch_compute(delta)
	
	# Periodically read field to CPU for sampling (every few frames to avoid overhead)
	# Or read every frame if needed - can optimize later
	if Engine.get_process_frames() % 5 == 0:  # Read every 5 frames
		_read_field_to_cpu()

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
