extends Node2D

# Environment Field for spatial mu variation
# Provides Perlin noise-based environment values M in [-1, 1]
# Used to modulate particle Lenia growth parameter mu

@export_group("Grid")
@export var grid_resolution: int = 256

@export_group("Noise")
@export var noise_frequency: float = 0.02
@export var noise_octaves: int = 3
@export var noise_seed: int = 0

# Field data storage: M values in [-1, 1]
var values: PackedFloat32Array = PackedFloat32Array()

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

func _generate_field() -> void:
	values.resize(grid_resolution * grid_resolution)
	var min_v: float = 999.0
	var max_v: float = -999.0
	
	for y in range(grid_resolution):
		for x in range(grid_resolution):
			var nx: float = float(x) * noise_frequency
			var ny: float = float(y) * noise_frequency
			var v: float = noise.get_noise_2d(nx, ny)
			var idx: int = y * grid_resolution + x
			values[idx] = v
			
			if v < min_v:
				min_v = v
			if v > max_v:
				max_v = v
	
	print("EnvironmentField: noise value range = [", min_v, ", ", max_v, "]")

func sample(world_pos: Vector2) -> float:
	if grid_resolution <= 1 or values.size() == 0:
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
	
	var v00: float = values[idx00]
	var v10: float = values[idx10]
	var v01: float = values[idx01]
	var v11: float = values[idx11]
	
	var v0: float = lerp(v00, v10, tx)
	var v1: float = lerp(v01, v11, tx)
	var v_final: float = lerp(v0, v1, ty)
	
	return v_final

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
			var value = values[index]
			
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
