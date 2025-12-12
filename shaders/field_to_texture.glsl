#version 450

// Field to Texture Compute Shader
// Reads field buffer and writes color-mapped texture for visualization

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer FieldData {
	float field_data[];
};

layout(set = 0, binding = 1, rgba8) writeonly uniform image2D output_texture;

layout(set = 0, binding = 2, std140) uniform Params {
	float grid_size;
	float field_mu;
};

void main() {
	ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
	int size = int(grid_size);
	
	if (pos.x >= size || pos.y >= size) return;
	
	int idx = pos.y * size + pos.x;
	float value = field_data[idx];
	
	// Color mapping: dark -> green (at mu) -> yellow -> red
	// NOTE: This must match the color mapping in EnvironmentField.get_environment_color()
	vec3 color;
	
	if (value < field_mu) {
		float t = value / max(field_mu, 0.001);
		color = mix(vec3(0.0, 0.0, 0.1), vec3(0.0, 0.7, 0.2), t);
	} else {
		float t = (value - field_mu) / max(1.0 - field_mu, 0.001);
		vec3 green = vec3(0.0, 0.7, 0.2);
		vec3 yellow = vec3(0.9, 0.9, 0.0);
		vec3 red = vec3(1.0, 0.2, 0.0);
		
		if (t < 0.5) {
			color = mix(green, yellow, t * 2.0);
		} else {
			color = mix(yellow, red, (t - 0.5) * 2.0);
		}
	}
	
	imageStore(output_texture, pos, vec4(color, 1.0));
}
