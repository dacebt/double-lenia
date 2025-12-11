shader_type canvas_item;

uniform sampler2D field_texture : filter_nearest;
uniform float field_mu : hint_range(0.0, 1.0) = 0.15;

void fragment() {
	float value = texture(field_texture, UV).r;
	
	// Color mapping: dark → green (at mu) → yellow → red
	vec3 color;
	
	if (value < field_mu) {
		// Dark blue/black to green
		float t = value / field_mu;
		color = mix(vec3(0.0, 0.0, 0.1), vec3(0.0, 0.7, 0.2), t);
	} else {
		// Green to yellow to red
		float t = (value - field_mu) / (1.0 - field_mu);
		vec3 green = vec3(0.0, 0.7, 0.2);
		vec3 yellow = vec3(0.9, 0.9, 0.0);
		vec3 red = vec3(1.0, 0.2, 0.0);
		
		if (t < 0.5) {
			color = mix(green, yellow, t * 2.0);
		} else {
			color = mix(yellow, red, (t - 0.5) * 2.0);
		}
	}
	
	COLOR = vec4(color, 1.0);
}
