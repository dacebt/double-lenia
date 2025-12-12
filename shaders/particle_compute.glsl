#version 450

// Compute shader for particle Lenia simulation
// Each thread processes one particle

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Input: particle positions
layout(set = 0, binding = 0) readonly buffer Positions {
	vec2 positions[];
};

// Particle velocities (persist across frames).
// Convention: shader writes velocity in world units / second (NOT pre-multiplied by dt).
// CPU integrates: position += velocity * delta * time_scale (delta applied exactly once on CPU).
layout(set = 0, binding = 1, std430) buffer Velocities {
	vec2 velocities[];
};

// Input: per-particle mu_local values
layout(set = 0, binding = 2, std430) readonly buffer MuLocals {
	float mu_locals[];
};

// Input: environment field data (read-only)
layout(set = 0, binding = 4, std430) readonly buffer FieldData {
	float field_data[];
};

// Uniforms
layout(set = 0, binding = 3, std140) uniform ParamsBlock {
	float particle_count;
	float particle_kernel_radius;       // r0
	float particle_kernel_width;        // s
	float particle_sigma;
	float gradient_strength;
	float repulsion_strength;
	float min_dist;
	float velocity_smoothing;           // 0 = snap to target velocity (no smoothing); >0 blends previous->target
	float field_grid_size;
	float viewport_width;
	float viewport_height;
	float _padding;  // std140 alignment
};

int wrap_index(int v, int size) {
	// Wrap index into [0, size). Use this instead of clamping for toroidal topology.
	// (We keep explicit wrapping even though particle positions are wrapped on CPU, because
	// central-difference sampling can probe outside the viewport.)
	return ((v % size) + size) % size;
}

vec2 wrap_world_pos(vec2 p) {
	// Wrap into [0, viewport) to match CPU toroidal world.
	// NOTE: viewport_width/height are expected > 0 for a valid simulation.
	return vec2(mod(p.x, viewport_width), mod(p.y, viewport_height));
}

// Ring kernel: exp(-(r - r0)^2 / (2 * s^2))
float ring_kernel(float r) {
	float r0 = particle_kernel_radius;
	float s = max(particle_kernel_width, 0.0001); // avoid divide-by-zero
	float dr = r - r0;
	return exp(-(dr * dr) / (2.0 * s * s));
}

// Derivative of ring kernel with respect to r
float ring_kernel_deriv(float r) {
	float r0 = particle_kernel_radius;
	float s = max(particle_kernel_width, 0.0001);
	float dr = r - r0;
	// d/dr of ring_kernel(r)
	return -(dr / (s * s)) * ring_kernel(r);
}

// Sample environment field at world position with bilinear interpolation
float sample_field(vec2 world_pos) {
	if (field_grid_size <= 0.0 || viewport_width <= 0.0 || viewport_height <= 0.0) {
		return 0.0;
	}
	
	// Compute field buffer size explicitly from grid_size^2.
	// We avoid buffer `.length()` bounds checks because Metal can report 0 for SSBO length;
	// keep this identifier in the same scope as the bounds checks (some drivers are picky about scope/SSA).
	int field_buffer_size = int(field_grid_size * field_grid_size);
	int size = int(field_grid_size);
	
	// Toroidal topology: wrap world coordinates instead of clamping UVs.
	// This keeps central differences symmetric near viewport edges.
	vec2 p = wrap_world_pos(world_pos);
	
	// Convert wrapped world position to UV in [0,1)
	vec2 uv = p / vec2(viewport_width, viewport_height);
	
	// Convert UV to grid coordinates
	float grid_x = uv.x * field_grid_size;
	float grid_y = uv.y * field_grid_size;
	
	// Get integer grid coordinates
	int x0 = int(floor(grid_x));
	int y0 = int(floor(grid_y));
	int x1 = x0 + 1;
	int y1 = y0 + 1;
	
	// Wrap indices (toroidal)
	int wx0 = wrap_index(x0, size);
	int wy0 = wrap_index(y0, size);
	int wx1 = wrap_index(x1, size);
	int wy1 = wrap_index(y1, size);
	
	// Interpolation factors
	float tx = grid_x - float(x0);
	float ty = grid_y - float(y0);
	
	// Get field values at corners
	int idx00 = wy0 * size + wx0;
	int idx10 = wy0 * size + wx1;
	int idx01 = wy1 * size + wx0;
	int idx11 = wy1 * size + wx1;
	
	// Bounds check using calculated buffer size instead of .length()
	float v00 = (idx00 >= 0 && idx00 < field_buffer_size) ? field_data[idx00] : 0.0;
	float v10 = (idx10 >= 0 && idx10 < field_buffer_size) ? field_data[idx10] : 0.0;
	float v01 = (idx01 >= 0 && idx01 < field_buffer_size) ? field_data[idx01] : 0.0;
	float v11 = (idx11 >= 0 && idx11 < field_buffer_size) ? field_data[idx11] : 0.0;
	
	// Bilinear interpolation
	float v0 = mix(v00, v10, tx);
	float v1 = mix(v01, v11, tx);
	float v_final = mix(v0, v1, ty);
	
	return v_final;
}

// Calculate field U at position pos
float calculate_field(vec2 pos) {
	float U = 0.0;
	
	for (int j = 0; j < int(particle_count); j++) {
		vec2 diff = pos - positions[j];
		float r2 = dot(diff, diff);
		float r = sqrt(r2);
		float k = ring_kernel(r);
		U += k;
	}
	
	return U / particle_count;
}

// Calculate growth function G(u) with local mu
float calculate_growth_mu(float u, float mu_local_val) {
	float diff = u - mu_local_val;
	float diff_sq = diff * diff;
	float sigma_sq = particle_sigma * particle_sigma;
	return 2.0 * exp(-(diff_sq / (2.0 * sigma_sq))) - 1.0;
}

// Calculate analytic gradient of G(U) at position pos with per-particle mu_local
vec2 calculate_gradient(vec2 pos, int index) {
	float U = 0.0;
	vec2 gradU = vec2(0.0);
	
	// Compute U and gradU in one loop
	for (int j = 0; j < int(particle_count); j++) {
		vec2 diff = pos - positions[j];
		float r2 = dot(diff, diff);
		float r = sqrt(r2);
		
		float k = ring_kernel(r);
		U += k;
		
		if (r > 0.0) {
			float dk_dr = ring_kernel_deriv(r);
			// grad k_j = dk/dr * (x - p_j)/r
			gradU += (dk_dr / r) * diff;
		}
	}
	
	// Normalize by particle count
	U /= particle_count;
	gradU /= particle_count;
	
	// Fetch local mu for this particle (index is passed as parameter)
	float mu_loc = mu_locals[index];
	
	// Compute growth function G(U) with local mu
	float G = calculate_growth_mu(U, mu_loc);
	float G_plus_one = G + 1.0;
	float sigma_sq = particle_sigma * particle_sigma;
	
	// Compute derivative dG/dU
	float dG_dU = (mu_loc - U) / sigma_sq * G_plus_one;
	
	// Final gradient: gradG = (dG/dU) * gradU
	vec2 gradG = gradU * dG_dU;
	
	return gradG;
}

// Calculate repulsion force for particle at index i
vec2 calculate_repulsion(int i) {
	vec2 repulsion = vec2(0.0);
	vec2 pos_i = positions[i];
	
	for (int j = 0; j < int(particle_count); j++) {
		if (j == i) {
			continue;
		}
		
		vec2 diff = pos_i - positions[j];
		
		// Minimum-image convention for toroidal world: remap diff into [-W/2, W/2] and [-H/2, H/2].
		// This makes neighbor interactions consistent with CPU wrap-around.
		if (viewport_width > 0.0) {
			float half_w = 0.5 * viewport_width;
			if (diff.x > half_w) diff.x -= viewport_width;
			else if (diff.x < -half_w) diff.x += viewport_width;
		}
		if (viewport_height > 0.0) {
			float half_h = 0.5 * viewport_height;
			if (diff.y > half_h) diff.y -= viewport_height;
			else if (diff.y < -half_h) diff.y += viewport_height;
		}
		float dist = length(diff);
		
		if (dist < min_dist && dist > 0.0) {
			float strength = pow(1.0 - dist / min_dist, 2.0);
			repulsion += normalize(diff) * strength;
		}
	}
	
	return repulsion;
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	
	if (i >= uint(particle_count)) {
		return;
	}
	
	vec2 pos = positions[i];
	
	// Calculate repulsion
	vec2 repulsion = calculate_repulsion(int(i));
	
	// Compute field gradient via central differences (toroidal sample_field wraps at boundaries).
	vec2 field_gradient = vec2(0.0);
	if (field_grid_size > 0.0) {
		// Epsilon scales with viewport/grid ratio to span multiple grid cells
		float epsilon = max(viewport_width, viewport_height) / field_grid_size * 2.0;
		epsilon = max(epsilon, 0.0001);
		
		float field_right = sample_field(pos + vec2(epsilon, 0.0));
		float field_left = sample_field(pos - vec2(epsilon, 0.0));
		float field_up = sample_field(pos + vec2(0.0, epsilon));
		float field_down = sample_field(pos - vec2(0.0, epsilon));
		
		field_gradient = vec2(
			(field_right - field_left) / (2.0 * epsilon),
			(field_up - field_down) / (2.0 * epsilon)
		);
	}
	
	// Apply gradient and repulsion
	vec2 v_target = field_gradient * gradient_strength;
	
	if (repulsion_strength > 0.0) {
		v_target += repulsion * repulsion_strength;
	}
	
	// Optional inertia/damping: blend previous velocity toward the target velocity.
	// Matches the previous CPU-side smoothing behavior:
	// - velocity_smoothing <= 0: snap to target (no smoothing)
	// - 0 < velocity_smoothing <= 1: velocities = lerp(prev, target, velocity_smoothing)
	if (velocity_smoothing <= 0.0) {
		velocities[i] = v_target;
	} else {
		float s = clamp(velocity_smoothing, 0.0, 1.0);
		vec2 v_prev = velocities[i];
		velocities[i] = mix(v_prev, v_target, s);
	}
}
