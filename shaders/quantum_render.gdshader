shader_type canvas_item;

// Quantum Wave Field Visualization Shader
// Reads wave function texture (RG = real, imag) and renders probability density |psi|^2
// Optionally uses phase for color mapping

uniform sampler2D wave_texture : filter_nearest;
uniform float brightness : hint_range(0.1, 10.0) = 1.0;
uniform bool show_phase = true;

void fragment() {
	// Sample wave function (r = real, g = imaginary)
	vec2 psi = texture(wave_texture, UV).rg;
	float real_part = psi.r;
	float imag_part = psi.g;
	
	// Probability density |psi|^2
	float density = real_part * real_part + imag_part * imag_part;
	
	// Phase angle
	float phase = atan(imag_part, real_part);
	
	vec3 color;
	
	if (show_phase) {
		// Phase as hue, density as brightness
		// Convert phase from [-PI, PI] to [0, 1]
		float hue = (phase + 3.14159265) / (2.0 * 3.14159265);
		
		// HSV to RGB conversion
		float h = hue * 6.0;
		float c = 1.0;
		float x = c * (1.0 - abs(mod(h, 2.0) - 1.0));
		
		vec3 rgb;
		if (h < 1.0) rgb = vec3(c, x, 0.0);
		else if (h < 2.0) rgb = vec3(x, c, 0.0);
		else if (h < 3.0) rgb = vec3(0.0, c, x);
		else if (h < 4.0) rgb = vec3(0.0, x, c);
		else if (h < 5.0) rgb = vec3(x, 0.0, c);
		else rgb = vec3(c, 0.0, x);
		
		// Apply density as brightness
		color = rgb * density * brightness;
	} else {
		// Simple grayscale density
		color = vec3(density * brightness);
	}
	
	COLOR = vec4(color, 1.0);
}
