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

// Uniforms
layout(set = 0, binding = 3, std140) uniform ParamsBlock {
	float particle_count;
	float particle_kernel_radius;       // r0: ring radius for particle Lenia
	float particle_kernel_width;        // s: ring width for particle Lenia
	float particle_sigma;                // growth function width for particle Lenia
	float gradient_strength;             // strength multiplier for particle Lenia gradient
	float repulsion_strength;
	float min_dist;
	float velocity_smoothing;           // 0 = snap to target velocity (no smoothing); >0 blends previous->target
	float viewport_width;
	float viewport_height;
	float _padding1;  // std140 alignment
	float _padding2;  // std140 alignment (maintain 48 bytes = 12 floats)
};

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
		
		// Minimum-image convention for toroidal world: remap diff into [-W/2, W/2] and [-H/2, H/2].
		// This makes particle Lenia interactions consistent across wrap boundaries.
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
	
	// Calculate particle Lenia analytic gradient (primary driver)
	// This uses ring kernel + mu_locals + particle_sigma to form Lenia structures (rings/blobs)
	vec2 particle_lenia_gradient = calculate_gradient(pos, int(i));
	
	// Calculate repulsion (stabilizer to prevent collapse)
	vec2 repulsion = calculate_repulsion(int(i));
	
	// Compose velocity from particle Lenia term + repulsion term
	// gradient_strength now controls particle Lenia strength (not field gradient)
	vec2 v_target = particle_lenia_gradient * gradient_strength;
	
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
