shader_type canvas_item;

// Quantum Wave Field Visualization Shader
// Reads wave function texture (RG = real, imag) and renders probability density |psi|^2
// Multiple visualization modes available

uniform sampler2D wave_texture : filter_nearest;
uniform float brightness : hint_range(0.1, 50.0) = 5.0;
uniform float contrast : hint_range(0.1, 5.0) = 1.0;
uniform int color_mode : hint_range(0, 2) = 0;
// 0 = phase as hue, density as brightness
// 1 = density only (heat map)
// 2 = real/imag as red/blue

void fragment() {
	vec2 psi = texture(wave_texture, UV).rg;
	float real_part = psi.r;
	float imag_part = psi.g;
	
	float density = real_part * real_part + imag_part * imag_part;
	float phase = atan(imag_part, real_part);
	
	vec3 color;
	
	if (color_mode == 0) {
		// Phase as hue, density as brightness
		float hue = (phase + 3.14159265) / (2.0 * 3.14159265);
		
		// HSV to RGB
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
		
		color = rgb * pow(density * brightness, contrast);
		
	} else if (color_mode == 1) {
		// Heat map based on density
		float d = pow(density * brightness, contrast);
		// Black -> Blue -> Cyan -> Green -> Yellow -> Red -> White
		if (d < 0.2) {
			color = mix(vec3(0.0), vec3(0.0, 0.0, 1.0), d * 5.0);
		} else if (d < 0.4) {
			color = mix(vec3(0.0, 0.0, 1.0), vec3(0.0, 1.0, 1.0), (d - 0.2) * 5.0);
		} else if (d < 0.6) {
			color = mix(vec3(0.0, 1.0, 1.0), vec3(0.0, 1.0, 0.0), (d - 0.4) * 5.0);
		} else if (d < 0.8) {
			color = mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 1.0, 0.0), (d - 0.6) * 5.0);
		} else {
			color = mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), min((d - 0.8) * 5.0, 1.0));
		}
		
	} else {
		// Real as red, imaginary as blue, overlap as purple
		float r = abs(real_part) * brightness;
		float b = abs(imag_part) * brightness;
		color = vec3(pow(r, contrast), 0.0, pow(b, contrast));
	}
	
	COLOR = vec4(color, 1.0);
}
