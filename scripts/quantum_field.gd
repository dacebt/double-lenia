extends Node2D

# Quantum Wave Field Controller
# Manages 2D grid of complex wave functions psi(x,y) = real + i*imag
# Uses GPU compute shaders for evolution and fragment shader for visualization

@export_group("Grid")
@export var grid_size: int = 512

@export_group("Evolution")
@export var diffusion: float = 1.0
@export var mu: float = 0.3
@export var sigma: float = 0.1
@export var time_scale: float = 1.0

# GPU resources
var rd: RenderingDevice
var shader: RID
var pipeline: RID
var psi_buffers: Array[RID] = [RID(), RID()]  # ping-pong storage buffers
var uniform_buffer: RID
var uniform_sets: Array[RID] = [RID(), RID()]  # one for each direction
var current_buffer: int = 0  # which buffer to read from

# Visualization
var display_texture: ImageTexture
var sprite: Sprite2D
var display_material: ShaderMaterial

func _ready():
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Failed to create RenderingDevice")
		return
	
	_setup_compute_shader()
	_create_buffers()
	_initialize_wave_function()
	_setup_display()

func _setup_compute_shader():
	# Load shader file as text
	var shader_file := FileAccess.open("res://shaders/quantum_evolution.glsl", FileAccess.READ)
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
	
	print("QUANTUM: Shader compiled successfully")
	
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
	
	print("QUANTUM: Pipeline created: ", pipeline.is_valid())

func _create_buffers():
	# Calculate buffer size: grid_size * grid_size * 2 floats * 4 bytes
	var buffer_size = grid_size * grid_size * 8  # 2 floats (real, imag) * 4 bytes each
	
	# Create two storage buffers for ping-pong
	for i in range(2):
		psi_buffers[i] = rd.storage_buffer_create(buffer_size)
		if not psi_buffers[i].is_valid():
			push_error("Failed to create buffer " + str(i))
			return
	
	print("QUANTUM: Buffers created: ", psi_buffers[0].is_valid(), ", ", psi_buffers[1].is_valid())
	
	# Create uniform buffer (5 floats: grid_size, diffusion, mu, sigma, dt)
	var uniform_buffer_size = 32  # 5 floats padded to 32 bytes (std140 alignment)
	uniform_buffer = rd.uniform_buffer_create(uniform_buffer_size)
	if not uniform_buffer.is_valid():
		push_error("Failed to create uniform buffer")
		return
	
	print("QUANTUM: Uniform buffer created: ", uniform_buffer.is_valid())
	
	# Create uniform sets for both ping-pong directions
	# Set 0: read from buffer[0], write to buffer[1]
	print("QUANTUM: Creating uniform set 0...")
	var read_uniform_0 := RDUniform.new()
	read_uniform_0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	read_uniform_0.binding = 0
	read_uniform_0.add_id(psi_buffers[0])
	
	var write_uniform_0 := RDUniform.new()
	write_uniform_0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	write_uniform_0.binding = 1
	write_uniform_0.add_id(psi_buffers[1])
	
	var params_uniform_0 := RDUniform.new()
	params_uniform_0.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform_0.binding = 2
	params_uniform_0.add_id(uniform_buffer)
	
	uniform_sets[0] = rd.uniform_set_create([read_uniform_0, write_uniform_0, params_uniform_0], shader, 0)
	print("QUANTUM: Uniform set 0 created, valid: ", uniform_sets[0].is_valid())
	if not uniform_sets[0].is_valid():
		push_error("Failed to create uniform set 0")
		return
	
	# Set 1: read from buffer[1], write to buffer[0]
	print("QUANTUM: Creating uniform set 1...")
	var read_uniform_1 := RDUniform.new()
	read_uniform_1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	read_uniform_1.binding = 0
	read_uniform_1.add_id(psi_buffers[1])
	
	var write_uniform_1 := RDUniform.new()
	write_uniform_1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	write_uniform_1.binding = 1
	write_uniform_1.add_id(psi_buffers[0])
	
	var params_uniform_1 := RDUniform.new()
	params_uniform_1.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform_1.binding = 2
	params_uniform_1.add_id(uniform_buffer)
	
	uniform_sets[1] = rd.uniform_set_create([read_uniform_1, write_uniform_1, params_uniform_1], shader, 0)
	print("QUANTUM: Uniform set 1 created, valid: ", uniform_sets[1].is_valid())
	if not uniform_sets[1].is_valid():
		push_error("Failed to create uniform set 1")
		return
	
	print("QUANTUM: Uniform sets created: ", uniform_sets[0].is_valid(), ", ", uniform_sets[1].is_valid())

func _initialize_wave_function():
	# Initialize buffer 0 with Gaussian blob
	var initial_data := PackedByteArray()
	initial_data.resize(grid_size * grid_size * 8)  # 2 floats (real, imag) * 4 bytes each
	
	var center = float(grid_size) / 2.0
	var radius_sq = 50.0 * 50.0
	
	for y in range(grid_size):
		for x in range(grid_size):
			var dx = float(x) - center
			var dy = float(y) - center
			var dist_sq = dx * dx + dy * dy
			var amplitude = exp(-dist_sq / (2.0 * radius_sq))
			
			# Pack as two float32s: real = amplitude, imag = 0.0
			var offset = (y * grid_size + x) * 8
			initial_data.encode_float(offset, amplitude)  # real part
			initial_data.encode_float(offset + 4, 0.0)     # imaginary part
	
	# Upload to buffer 0
	rd.buffer_update(psi_buffers[0], 0, initial_data.size(), initial_data)

func _setup_display():
	# Create Sprite2D as child
	sprite = Sprite2D.new()
	add_child(sprite)
	
	# Load shader and create material
	var shader_resource = load("res://shaders/quantum_render.gdshader")
	if shader_resource == null:
		push_error("Failed to load quantum_render.gdshader")
		return
	
	display_material = ShaderMaterial.new()
	display_material.shader = shader_resource
	
	# Set default shader parameters
	display_material.set_shader_parameter("brightness", 5.0)
	display_material.set_shader_parameter("contrast", 1.0)
	display_material.set_shader_parameter("color_mode", 1)  # Heat map by default
	
	# Create ImageTexture for display
	display_texture = ImageTexture.new()
	
	# Set sprite properties
	sprite.texture = display_texture
	sprite.material = display_material
	
	# Position sprite to fill viewport (will be updated in _update_display)
	sprite.position = Vector2.ZERO

func _upload_uniforms(delta: float):
	# Pack uniform buffer with parameters
	var uniform_bytes := PackedByteArray()
	uniform_bytes.resize(32)  # 5 floats padded to 32 bytes (std140 alignment)
	
	var offset = 0
	uniform_bytes.encode_float(offset, float(grid_size))
	offset += 4
	uniform_bytes.encode_float(offset, diffusion)
	offset += 4
	uniform_bytes.encode_float(offset, mu)
	offset += 4
	uniform_bytes.encode_float(offset, sigma)
	offset += 4
	uniform_bytes.encode_float(offset, delta * time_scale)
	
	rd.buffer_update(uniform_buffer, 0, uniform_bytes.size(), uniform_bytes)

func _dispatch_compute(delta: float):
	_upload_uniforms(delta)
	
	# Calculate workgroups (8x8 local size from shader)
	var workgroups = int(ceil(float(grid_size) / 8.0))
	
	# Begin compute list
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_sets[current_buffer], 0)
	rd.compute_list_dispatch(compute_list, workgroups, workgroups, 1)  # 2D dispatch
	rd.compute_list_end()
	
	# Submit and sync
	rd.submit()
	rd.sync()

func _update_display():
	# Get output buffer (the one we just wrote to)
	var output_buf = psi_buffers[current_buffer]
	
	# Read buffer data (2 floats per cell: real, imag)
	var byte_data = rd.buffer_get_data(output_buf)
	
	# Convert to RGBA8 for display
	# Create new image with RGBA8 format
	var image = Image.create(grid_size, grid_size, false, Image.FORMAT_RGBA8)
	
	# Convert buffer bytes to RGBA8
	var float_data = byte_data.to_float32_array()
	for y in range(grid_size):
		for x in range(grid_size):
			var idx = (y * grid_size + x) * 2
			if idx + 1 < float_data.size():
				var real = float_data[idx]
				var imag = float_data[idx + 1]
				var density = real * real + imag * imag
				# Clamp density and convert to color
				var intensity = clamp(density * 10.0, 0.0, 1.0)  # Scale for visibility
				image.set_pixel(x, y, Color(intensity, intensity, intensity, 1.0))
	
	# Update display texture
	display_texture.set_image(image)
	
	# Update sprite scale to fill viewport while maintaining aspect ratio
	var viewport_size = get_viewport_rect().size
	if viewport_size.x > 0 and viewport_size.y > 0:
		# Use the smaller dimension to maintain square aspect
		var scale_factor = min(viewport_size.x, viewport_size.y) / float(grid_size)
		sprite.scale = Vector2(scale_factor, scale_factor)
		sprite.position = viewport_size / 2.0
	
	# Update shader material to use the texture
	display_material.set_shader_parameter("wave_texture", display_texture)

func _process(delta: float):
	if not rd:
		return
	if not shader.is_valid():
		return
	if not pipeline.is_valid():
		return
	
	_dispatch_compute(delta)
	
	# Swap buffers
	current_buffer = 1 - current_buffer
	
	_update_display()
	
	# Debug: sample values every 60 frames
	if Engine.get_process_frames() % 60 == 0:
		var output_buf = psi_buffers[current_buffer]
		var byte_data = rd.buffer_get_data(output_buf)
		
		# Sample center pixel instead of corner
		var center_offset = (int(grid_size / 2.0) * grid_size + int(grid_size / 2.0)) * 8
		if byte_data.size() > center_offset + 8:
			var real = byte_data.decode_float(center_offset)
			var imag = byte_data.decode_float(center_offset + 4)
			var density = real * real + imag * imag
			print("Center - real: ", real, " imag: ", imag, " density: ", density)

func _exit_tree():
	# Cleanup all RIDs
	if uniform_sets.size() > 0:
		for i in range(2):
			if uniform_sets[i].is_valid():
				rd.free_rid(uniform_sets[i])
	
	# Free storage buffers
	if psi_buffers.size() > 0:
		for i in range(2):
			if psi_buffers[i].is_valid():
				rd.free_rid(psi_buffers[i])
	
	if uniform_buffer.is_valid():
		rd.free_rid(uniform_buffer)
	
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	
	if shader.is_valid():
		rd.free_rid(shader)
