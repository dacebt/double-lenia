#version 450

// Compute shader for particle Lenia simulation
// Each thread processes one particle

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Input: particle positions
layout(set = 0, binding = 0) readonly buffer Positions {
	vec2 positions[];
};

// Output: particle velocities
layout(set = 0, binding = 1) writeonly buffer Velocities {
	vec2 velocities[];
};

// Input: per-particle mu_local values
layout(set = 0, binding = 2, std430) readonly buffer MuLocals {
	float mu_locals[];
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
	float delta_time;
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
	
	// Fetch local μ for this particle (index is passed as parameter)
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
	
	float mu_local = mu_locals[i];
	
	vec2 pos = positions[i];
	
	// Calculate gradient with per-particle mu_local
	vec2 gradient = calculate_gradient(pos, int(i));
	
	// Calculate repulsion
	vec2 repulsion = calculate_repulsion(int(i));
	
	// Temporary boost factor to make environment effect visible
	// Map mu_local from [0, 1] into [0.5, 1.5] factor
	float mu_factor = 0.5 + 1.0 * clamp(mu_local, 0.0, 1.0);
	
	// Output velocity with mu_factor boost
	vec2 v = gradient * gradient_strength * mu_factor;
	if (repulsion_strength > 0.0) {
		v += repulsion * repulsion_strength;
	}
	
	velocities[i] = v;
}

