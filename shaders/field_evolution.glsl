#version 450

// Field Evolution Compute Shader for Living Field
// Each thread processes one grid cell (x, y)
// Evolves scalar field M via ring kernel convolution + Lenia growth function

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Ping-pong storage buffers for field state
layout(set = 0, binding = 0, std430) readonly buffer FieldIn {
	float field_in[];
};

layout(set = 0, binding = 1, std430) writeonly buffer FieldOut {
	float field_out[];
};

// Uniform parameters
layout(set = 0, binding = 2, std140) uniform Params {
	float grid_size;
	float kernel_radius;    // r0
	float kernel_width;      // s
	float mu;               // target density
	float sigma;            // growth function width
	float dt;               // time step
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

// Ring kernel: exp(-(r - r0)^2 / (2 * s^2))
float ring_kernel(float r) {
	float r0 = kernel_radius;
	float s = max(kernel_width, 0.0001); // avoid divide-by-zero
	float dr = r - r0;
	return exp(-(dr * dr) / (2.0 * s * s));
}

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	int size = int(grid_size);
	
	if (pos.x >= size || pos.y >= size) return;
	
	// Read current field value at this cell
	float M_current = field_in[idx(pos.x, pos.y)];
	
	// Compute convolution U(x,y) = sum over nearby cells of field[j] * K(dist)
	// We sample cells within a reasonable radius around kernel_radius
	float U = 0.0;
	float kernel_sum = 0.0; // for normalization
	
	// Determine search radius: kernel_radius + margin (3 * kernel_width should cover most of kernel)
	float search_radius = kernel_radius + 3.0 * kernel_width;
	int search_pixels = int(ceil(search_radius));
	
	// Convolve field with ring kernel
	for (int dy = -search_pixels; dy <= search_pixels; dy++) {
		for (int dx = -search_pixels; dx <= search_pixels; dx++) {
			// Get neighbor position with wrapping
			int nx = wrap(pos.x + dx, size);
			int ny = wrap(pos.y + dy, size);
			
			// Distance from center cell
			float dist = length(vec2(float(dx), float(dy)));
			
			// Skip if beyond search radius
			if (dist > search_radius) continue;
			
			// Sample field at neighbor
			float M_neighbor = field_in[idx(nx, ny)];
			
			// Evaluate ring kernel
			float k = ring_kernel(dist);
			
			// Accumulate
			U += M_neighbor * k;
			kernel_sum += k;
		}
	}
	
	// Normalize by kernel sum (ensures convolution preserves field magnitude)
	if (kernel_sum > 0.0) {
		U /= kernel_sum;
	}
	
	// Lenia growth function: G(U) = 2·exp(-(U-μ)²/(2σ²)) - 1
	float diff = U - mu;
	float diff_sq = diff * diff;
	float sigma_sq = sigma * sigma;
	float G = 2.0 * exp(-(diff_sq / (2.0 * sigma_sq))) - 1.0;
	
	// Euler integration: M_new = M_old + dt * G(U)
	float M_new = M_current + dt * G;
	
	// Clamp to reasonable range to prevent numerical issues
	// Field values should stay in [-1, 1] range (matching Perlin noise output)
	M_new = clamp(M_new, -2.0, 2.0);
	
	// Write output
	field_out[idx(pos.x, pos.y)] = M_new;
}
