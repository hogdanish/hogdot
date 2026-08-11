// ⚠ The fallthrough from `case 1` into `case 0` is the whole point of this file.
// It is legal in Godot's shading language and in the SPIR-V glslang emits for it,
// but Tint's SPIR-V reader asserts on it ("switch fallthrough not supported by the
// SPIR-V reader", parser.cc) — the exact shape CommonGrounds' tank_tread.gdshader
// shipped. The selector is a uniform so no constant-folding can delete the switch.
// Do not "fix" the missing break.
shader_type spatial;

uniform float selector : hint_range(0.0, 2.0) = 1.0;

void fragment() {
	vec3 col = vec3(0.2, 0.2, 0.2);
	switch (int(selector)) {
		case 1:
			col.r = 1.0;
		case 0:
			col.g = 0.6;
			break;
		default:
			col.b = 1.0;
			break;
	}
	ALBEDO = col;
}
