shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

// Gate for RL-029 — the inter-stage varying ceiling.
//
// Four user varyings, which is the worst case measured across CommonGrounds'
// spatial shaders (`city_windows_glow.gdshader` and `city_windows.gdshader` both
// declare vec3, vec3, float, float). Each varying costs one inter-stage location
// regardless of width, so this needs four locations above `base_varying_index`.
//
// ⚠ This is the coverage the test project was missing. WebGPU guarantees only 16
// inter-stage variables, and the mobile renderer used to reserve 15 of them, so a
// shader like this failed with "Too many varyings used in shader (17 used, maximum
// supported is 16)" followed by cascading [Invalid RenderPipeline] errors. Nothing
// else here uses a custom spatial shader with varyings at all, which is why phases
// 4 and 5 went green with that defect fully present. Do not reduce the count.

varying vec3 v_world_pos;
varying vec3 v_object_normal;
varying float v_facing;
varying float v_wave;

uniform vec3 tint_a : source_color = vec3(0.9, 0.35, 0.2);
uniform vec3 tint_b : source_color = vec3(0.2, 0.5, 0.95);
uniform float wave_speed = 1.7;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_object_normal = NORMAL;
	v_facing = dot(normalize(NORMAL), vec3(0.0, 1.0, 0.0));
	v_wave = sin(TIME * wave_speed + v_world_pos.x + v_world_pos.z) * 0.5 + 0.5;
}

void fragment() {
	// Read every varying, so none can be optimized out before the location count
	// is what the gate is measuring.
	vec3 base = mix(tint_a, tint_b, clamp(v_facing * 0.5 + 0.5, 0.0, 1.0));
	base *= 0.6 + 0.4 * v_wave;
	base += 0.15 * abs(v_object_normal);
	base += 0.05 * fract(v_world_pos);

	ALBEDO = base;
	ROUGHNESS = clamp(0.25 + 0.5 * v_wave, 0.0, 1.0);
	METALLIC = 0.1;
	EMISSION = tint_b * v_wave * 0.2;
}
