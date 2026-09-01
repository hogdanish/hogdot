shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float scene_depth = -view.z;
	float d = clamp((scene_depth + VERTEX.z) * 0.5, 0.0, 1.0);
	vec2 wobble = vec2(sin(TIME * 1.3 + VERTEX.x * 0.7), cos(TIME * 0.9 + VERTEX.y * 0.5)) * 0.008;
	vec3 refr = texture(screen_tex, SCREEN_UV + wobble).rgb;
	ALBEDO = mix(refr, vec3(0.08, 0.28, 0.45), 0.35 + d * 0.5);
	ALPHA = 0.85;
	ROUGHNESS = 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
