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
	
	// Growth function
	float diff = density - mu;
	float G = 2.0 * exp(-(diff * diff) / (2.0 * sigma * sigma)) - 1.0;
	
	// Evolution
	float d_real = -diffusion * laplacian_imag + G * real_part;
	float d_imag =  diffusion * laplacian_real + G * imag_part;
	
	// Euler integration
	float new_real = real_part + dt * d_real;
	float new_imag = imag_part + dt * d_imag;
	
	psi_out[idx(pos.x, pos.y)] = vec2(new_real, new_imag);
}
