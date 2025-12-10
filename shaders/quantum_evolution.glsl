#version 450

// Quantum Wave Field Evolution Compute Shader
// Each thread processes one grid cell (x, y)
// Evolves wave function psi = real + i*imag according to nonlinear Schrodinger equation

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Storage buffers instead of images
layout(set = 0, binding = 0, std430) readonly buffer PsiIn {
	vec2 psi_in[];
};

layout(set = 0, binding = 1, std430) writeonly buffer PsiOut {
	vec2 psi_out[];
};

layout(set = 0, binding = 2) uniform Params {
	float grid_size;
	float diffusion;
	float mu;
	float sigma;
	float dt;
};

// Helper to convert 2D coords to 1D index
int idx(int x, int y) {
	int size = int(grid_size);
	return y * size + x;
}

// Helper to wrap coordinates (toroidal boundary)
int wrap(int val, int size) {
	return (val + size) % size;
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	int size = int(grid_size);
	
	if (pos.x >= size || pos.y >= size) return;
	
	// Read current psi
	vec2 psi = psi_in[idx(pos.x, pos.y)];
	float real_part = psi.x;
	float imag_part = psi.y;
	
	// Read neighbors with wrapping
	vec2 psi_left  = psi_in[idx(wrap(pos.x - 1, size), pos.y)];
	vec2 psi_right = psi_in[idx(wrap(pos.x + 1, size), pos.y)];
	vec2 psi_up    = psi_in[idx(pos.x, wrap(pos.y - 1, size))];
	vec2 psi_down  = psi_in[idx(pos.x, wrap(pos.y + 1, size))];
	
	// Laplacian
	float laplacian_real = psi_left.x + psi_right.x + psi_up.x + psi_down.x - 4.0 * real_part;
	float laplacian_imag = psi_left.y + psi_right.y + psi_up.y + psi_down.y - 4.0 * imag_part;
	
	// Probability density
	float density = real_part * real_part + imag_part * imag_part;
	
	// Growth function (Lenia-style)
	float diff_g = density - mu;
	float G = 2.0 * exp(-(diff_g * diff_g) / (2.0 * sigma * sigma)) - 1.0;
	
	// Calculate density gradient (for flow toward density)
	float density_left  = psi_left.x * psi_left.x + psi_left.y * psi_left.y;
	float density_right = psi_right.x * psi_right.x + psi_right.y * psi_right.y;
	float density_up    = psi_up.x * psi_up.x + psi_up.y * psi_up.y;
	float density_down  = psi_down.x * psi_down.x + psi_down.y * psi_down.y;
	
	// Laplacian of density (positive = local minimum, negative = local maximum)
	float density_laplacian = density_left + density_right + density_up + density_down - 4.0 * density;
	
	// Evolution with three terms:
	// 1. Wave spreading (quantum diffusion)
	// 2. Growth/decay based on density sweet spot
	// 3. Localization (resist spreading from high density regions)
	float growth_strength = 0.5;
	float localization = 0.2;
	
	float d_real = -diffusion * laplacian_imag 
	             + G * growth_strength * real_part
	             + localization * density_laplacian * real_part;
	             
	float d_imag = diffusion * laplacian_real 
	             + G * growth_strength * imag_part
	             + localization * density_laplacian * imag_part;
	
	// Euler integration with gentle damping
	float damping = 0.9999;
	float new_real = (real_part + dt * d_real) * damping;
	float new_imag = (imag_part + dt * d_imag) * damping;
	
	// Clamp to prevent numerical explosion
	float max_amplitude = 10.0;
	new_real = clamp(new_real, -max_amplitude, max_amplitude);
	new_imag = clamp(new_imag, -max_amplitude, max_amplitude);
	
	psi_out[idx(pos.x, pos.y)] = vec2(new_real, new_imag);
}
