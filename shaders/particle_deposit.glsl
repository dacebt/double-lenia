#version 450

// Particle Deposit Compute Shader
// Each thread processes one grid cell (x, y)
// Accumulates Gaussian splats from all particles into the field

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Field buffer (read-write)
layout(set = 0, binding = 0, std430) buffer FieldData {
	float field_data[];
};

// Particle positions (read-only)
layout(set = 0, binding = 1, std430) readonly buffer Positions {
	vec2 positions[];
};

layout(set = 0, binding = 2, std140) uniform Params {
	float grid_size;
	float particle_count;
	float deposit_amount;
	float deposit_radius;
	float viewport_width;
	float viewport_height;
	float field_baseline;
	float field_decay;
};

// Helper to convert 2D coords to 1D index
int idx(int x, int y) {
	int size = int(grid_size);
	return y * size + x;
}

void main() {
	ivec2 cell = ivec2(gl_GlobalInvocationID.xy);
	int size = int(grid_size);
	
	if (cell.x >= size || cell.y >= size) return;
	
	// Convert cell to world position (center of cell)
	vec2 world_pos = vec2(
		(float(cell.x) + 0.5) / grid_size * viewport_width,
		(float(cell.y) + 0.5) / grid_size * viewport_height
	);
	
	// Accumulate deposits from all nearby particles
	float deposit = 0.0;
	float radius_sq = deposit_radius * deposit_radius;
	float search_radius_sq = radius_sq * 4.0;  // Check particles within 2*radius
	
	for (int i = 0; i < int(particle_count); i++) {
		vec2 particle_pos = positions[i];
		vec2 diff = world_pos - particle_pos;
		float dist_sq = dot(diff, diff);
		
		// Only process particles within search radius
		if (dist_sq < search_radius_sq) {
			// Gaussian splat: deposit_amount * exp(-dist^2/(2*radius^2))
			deposit += deposit_amount * exp(-dist_sq / (2.0 * radius_sq));
		}
	}
	
	// Add to field with decay toward baseline
	int field_idx = idx(cell.x, cell.y);
	float current = field_data[field_idx];
	float new_value = current + deposit - field_decay * (current - field_baseline);
	new_value = clamp(new_value, 0.0, 1.0);
	field_data[field_idx] = new_value;
}

