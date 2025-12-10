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

// Uniforms
layout(set = 0, binding = 2) uniform Uniforms {
	float particle_count;  // cast to int when using
	float kernel_radius;
	float mu;
	float sigma;
	float gradient_strength;
	float repulsion_strength;
	float min_dist;
	float delta_time;
};

// Calculate field U at position pos
float calculate_field(vec2 pos) {
	float U = 0.0;
	float kernel_radius_sq = kernel_radius * kernel_radius;
	
	for (int j = 0; j < int(particle_count); j++) {
		vec2 diff = pos - positions[j];
		float dist_sq = dot(diff, diff);
		U += exp(-dist_sq / (2.0 * kernel_radius_sq));
	}
	
	return U / particle_count;
}

// Calculate growth function G(u)
float calculate_growth(float u) {
	float diff = u - mu;
	float diff_sq = diff * diff;
	float sigma_sq = sigma * sigma;
	return 2.0 * exp(-(diff_sq / (2.0 * sigma_sq))) - 1.0;
}

// Calculate analytic gradient of G(U) at position pos
vec2 calculate_gradient(vec2 pos) {
	float U = 0.0;
	vec2 gradU = vec2(0.0);
	float kernel_radius_sq = kernel_radius * kernel_radius;
	
	// Compute U and gradU in one loop
	for (int j = 0; j < int(particle_count); j++) {
		vec2 diff = pos - positions[j];
		float dist_sq = dot(diff, diff);
		float k = exp(-dist_sq / (2.0 * kernel_radius_sq));
		
		U += k;
		gradU += (-1.0 / kernel_radius_sq) * diff * k;
	}
	
	// Normalize by particle count
	U /= particle_count;
	gradU /= particle_count;
	
	// Compute growth function G(U)
	float G = calculate_growth(U);
	float G_plus_one = G + 1.0;
	float sigma_sq = sigma * sigma;
	
	// Compute derivative dG/dU
	float dG_dU = (mu - U) / sigma_sq * G_plus_one;
	
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
	uint index = gl_GlobalInvocationID.x;
	
	if (index >= uint(int(particle_count))) {
		return;
	}
	
	vec2 pos = positions[index];
	
	// Calculate gradient
	vec2 gradient = calculate_gradient(pos);
	
	// Calculate repulsion
	vec2 repulsion = calculate_repulsion(int(index));
	
	// Output velocity
	vec2 v = gradient * gradient_strength;
	if (repulsion_strength > 0.0) {
		v += repulsion * repulsion_strength;
	}
	
	velocities[index] = v;
}

