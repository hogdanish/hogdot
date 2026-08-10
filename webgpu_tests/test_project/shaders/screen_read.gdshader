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
// How to read it, because it is a *visual* gate and cannot self-report: WebGPU canvases
// read back all black under drawImage/getImageData, and there is no synchronous GPU
// readback on this backend, so nothing in script can assert on the result. Open the held
// run (`?hold`) and look at the panel:
//   - shows the scene behind it, wobbling, with a depth-derived tint  → the copy works.
//   - flat black or flat magenta                                     → the copy is empty
//     or unbound, and every hint_screen_texture consumer in every project is affected.
// The magenta border is drawn unconditionally, so a panel that is entirely magenta means
// the mesh drew and the sample failed, not that the mesh is missing.

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform float wobble_strength = 0.02;

void fragment() {
	vec2 uv = SCREEN_UV;
	uv.x += sin(uv.y * 24.0 + TIME * 1.5) * wobble_strength;

	vec3 behind = texture(screen_tex, uv).rgb;

	// Read depth as well, so a driver that binds the screen texture but not the depth
	// texture (or vice versa) still fails one half of the gate visibly.
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
	vec3 depth_tint = vec3(0.0, clamp(raw_depth * 4.0, 0.0, 1.0), 0.0);

	// Unconditional border: proves the mesh rasterized even when the samples are empty.
	vec2 edge = abs(UV - vec2(0.5)) * 2.0;
	float border = step(0.9, max(edge.x, edge.y));

	ALBEDO = mix(behind * 0.85 + depth_tint * 0.15, vec3(1.0, 0.0, 1.0), border);
	ALPHA = 1.0;
}
