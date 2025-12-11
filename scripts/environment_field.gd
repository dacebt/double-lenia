class_name EnvironmentField
extends Node2D

# Environment Field for spatial mu variation
# Provides Perlin noise-based environment values M in [-1, 1]
# Used to modulate particle Lenia growth parameter mu

@export var grid_resolution: int = 256
@export var noise_frequency: float = 3.0  # bump this to see more blobs

var values: PackedFloat32Array
var field_min: float = 0.0
var field_max: float = 0.0

# Noise generator
var noise: FastNoiseLite

func _ready() -> void:
	# Create and configure FastNoiseLite
	noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 1.0  # Use 1.0 as base, we multiply by noise_frequency in sampling
	noise.seed = 0
	
	_generate_field()

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
