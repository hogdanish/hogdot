shader_type spatial;
uniform vec4 tint : source_color = vec4(1.0);
uniform float speed = 1.0;
void vertex() {
	VERTEX.y += sin(TIME * speed + VERTEX.x * 3.0) * 0.1;
}
void fragment() {
	ALBEDO = tint.rgb * (0.6 + 0.4 * sin(TIME * speed + UV.x * 10.0));
	ROUGHNESS = 0.4;
	ALPHA = 0.7;
}
