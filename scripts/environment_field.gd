extends Node2D

# Environment Field for spatial μ variation
# Provides Perlin noise-based environment values M in [-1, 1]
# Used to modulate particle Lenia growth parameter μ

@export_group("Grid")
@export var grid_resolution: int = 256

@export_group("Noise")
@export var noise_frequency: float = 0.02
@export var noise_octaves: int = 3
@export var noise_seed: int = 0

# Field data storage: M values in [-1, 1]
var field_data: PackedFloat32Array = PackedFloat32Array()

# Noise generator
var noise: FastNoiseLite

# Visualization
var field_texture: ImageTexture
var sprite: Sprite2D

func _ready():
	# Create and configure FastNoiseLite
	noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = noise_frequency
	noise.seed = noise_seed
	noise.fractal_octaves = noise_octaves
	
	# Generate the field
	_generate_field()
	
	# Create visualization
	_create_visualization()
	
	# Connect to viewport size changes
	var vp := get_viewport()
	if vp:
		vp.size_changed.connect(_on_viewport_size_changed)
		_on_viewport_size_changed()  # initial setup

func _generate_field():
	# Resize field_data to grid_resolution × grid_resolution
	field_data.resize(grid_resolution * grid_resolution)
	
	# Generate noise values for each grid cell
	for y in range(grid_resolution):
		for x in range(grid_resolution):
			# Sample noise (already returns roughly [-1, 1])
			var noise_value = noise.get_noise_2d(float(x), float(y))
			
			# Store in field_data (row-major order: y * width + x)
			var index = y * grid_resolution + x
			field_data[index] = noise_value

func sample(world_pos: Vector2) -> float:
	# Get viewport size
	var viewport_size = get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return 0.0
	
	# Convert world position to normalized UV coordinates
	var uv = world_pos / viewport_size
	
	# Clamp UV to [0, 1] range
	uv.x = clamp(uv.x, 0.0, 1.0)
	uv.y = clamp(uv.y, 0.0, 1.0)
	
	# Convert UV to grid coordinates
	var gx = uv.x * float(grid_resolution)
	var gy = uv.y * float(grid_resolution)
	
	# Get integer grid coordinates for bilinear interpolation
	var g0x = int(floor(gx))
	var g0y = int(floor(gy))
	var g1x = min(g0x + 1, grid_resolution - 1)
	var g1y = min(g0y + 1, grid_resolution - 1)
	
	# Get fractional parts for interpolation
	var fx = gx - float(g0x)
	var fy = gy - float(g0y)
	
	# Clamp grid coordinates to valid range
	g0x = clamp(g0x, 0, grid_resolution - 1)
	g0y = clamp(g0y, 0, grid_resolution - 1)
	
	# Sample four corner values
	var v00 = field_data[g0y * grid_resolution + g0x]  # bottom-left
	var v10 = field_data[g0y * grid_resolution + g1x]  # bottom-right
	var v01 = field_data[g1y * grid_resolution + g0x]  # top-left
	var v11 = field_data[g1y * grid_resolution + g1x]  # top-right
	
	# Bilinear interpolation
	# First interpolate along x-axis
	var v0 = lerp(v00, v10, fx)  # bottom edge
	var v1 = lerp(v01, v11, fx)  # top edge
	
	# Then interpolate along y-axis
	var result = lerp(v0, v1, fy)
	
	return result

func _create_visualization():
	# Create Image for visualization
	var image = Image.create(grid_resolution, grid_resolution, false, Image.FORMAT_RGB8)
	
	# Map field values [-1, 1] to colors
	# -1 → blue (0.2, 0.2, 0.8)
	# 0 → gray (0.5, 0.5, 0.5)
	# +1 → red (0.8, 0.2, 0.2)
	for y in range(grid_resolution):
		for x in range(grid_resolution):
			var index = y * grid_resolution + x
			var value = field_data[index]
			
			# Map [-1, 1] to color
			# For negative values: interpolate from blue to gray
			# For positive values: interpolate from gray to red
			var color: Color
			if value < 0.0:
				# Blue to gray: value goes from -1 to 0
				var t = (value + 1.0)  # maps -1→0 to 0→1
				color = Color(0.2, 0.2, 0.8).lerp(Color(0.5, 0.5, 0.5), t)
			else:
				# Gray to red: value goes from 0 to 1
				var t = value  # maps 0→1 to 0→1
				color = Color(0.5, 0.5, 0.5).lerp(Color(0.8, 0.2, 0.2), t)
			
			image.set_pixel(x, y, color)
	
	# Create ImageTexture from Image
	field_texture = ImageTexture.new()
	field_texture.set_image(image)
	
	# Create Sprite2D child for display
	sprite = Sprite2D.new()
	sprite.texture = field_texture
	add_child(sprite)
	
	# Scale sprite to fill viewport
	_update_sprite_scale()
	
	# Set z_index to -1 (behind particles)
	sprite.z_index = -1

func _update_sprite_scale():
	if not sprite or not field_texture:
		return
	
	var viewport_size = get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	
	# Scale sprite to fill viewport
	var texture_size = field_texture.get_size()
	if texture_size.x > 0.0 and texture_size.y > 0.0:
		var scale_x = viewport_size.x / texture_size.x
		var scale_y = viewport_size.y / texture_size.y
		sprite.scale = Vector2(scale_x, scale_y)
		sprite.position = viewport_size / 2.0

func _on_viewport_size_changed() -> void:
	_update_sprite_scale()
