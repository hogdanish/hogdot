shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

// Gate for the back-buffer copy — SCREEN_TEXTURE and DEPTH_TEXTURE on Mobile + WebGPU.
//
// ⚠ No RL entry from RL-001 to RL-038 touches screen texture, back buffer or blit. This
// is another path CommonGrounds turned out to be the first consumer of, exactly like
// RDShaderFile and stencil_mode were, and its water renders fully opaque there.
//
// ⚠ The common misreading is that this is about subpass input attachments. It is not.
// RenderForwardMobile::_render_buffers_can_be_storage() returns false unconditionally,
// so the Mobile renderer *never* uses input attachments for this — it always takes the
// ordinary _render_buffers_copy_screen_texture() → copy_to_fb_rect() path, a separate
// pass writing a plain sampled texture. That pattern is portable to WebGPU in principle;
// whether hogdot's driver executes it correctly is what this gate is for.
//
// ⚠ THE PREVIOUS VERSION OF THIS GATE COULD NOT FAIL ON ITS DEPTH HALF, and WA-18 walked
// straight through it: it folded depth into `mix(behind * 0.85 + depth_tint * 0.15, …)`
// at 15 % weight, and the panel could face open sky, where `raw_depth == 0` is the
// *correct* answer. A gate whose pass state is also its failure state proves nothing.
// Each half is now binary, and `_setup_screen_read()` puts a known opaque backer behind
// the panel so a zero depth is always wrong.
//
// How to read it, because it is a *visual* gate and cannot self-report: WebGPU canvases
// read back all black under drawImage/getImageData, and there is no synchronous GPU
// readback on this backend, so nothing in script can assert on the result. Open the held
// run (`?hold`) and look at the panel:
//   - LEFT half  — the backer, wobbling. Flat black means the screen copy is dead.
//   - RIGHT half — solid green. **Solid red means the depth copy is dead**, and nothing
//     else in this shader produces red.
// The magenta border is drawn unconditionally, so an all-magenta panel means the mesh
// drew and both samples failed, not that the mesh is missing.

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform float wobble_strength = 0.02;

void fragment() {
	vec2 uv = SCREEN_UV;
	uv.x += sin(uv.y * 24.0 + TIME * 1.5) * wobble_strength;

	// Left half: the screen copy, undiluted. Black means it is empty.
	vec3 behind = texture(screen_tex, uv).rgb;

	// Right half: the depth copy, as a pass/fail colour. Godot 4.7 uses reverse-Z and
	// clears depth to 0.0, so zero means the far plane — which the backer makes
	// impossible. A blank fallback texture reads zero everywhere and shows solid red.
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
	vec3 depth_result = raw_depth > 0.0 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);

	vec3 body = UV.x < 0.5 ? behind : depth_result;

	// Unconditional border: proves the mesh rasterized even when both samples are empty.
	vec2 edge = abs(UV - vec2(0.5)) * 2.0;
	float border = step(0.9, max(edge.x, edge.y));

	ALBEDO = mix(body, vec3(1.0, 0.0, 1.0), border);
	ALPHA = 1.0;
}
