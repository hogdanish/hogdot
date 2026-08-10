shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

// Gate for RL-037 — stencil state against a depth-only attachment.
//
// ⚠ Declaring any stencil_mode makes Godot build stencil state into *every* variant of
// this material, including the shadow-pass ones. The shadow atlas is D16_UNORM or
// D32_SFLOAT (light_storage.cpp) and has no stencil aspect; WebGPU rejects a non-Keep
// stencil op against such an attachment and the whole pipeline is invalid. An invalid
// pipeline then poisons its render pass, its command encoder and the Queue.Submit — one
// material was killing whole frames at hundreds of validation errors per second, and
// native Vulkan and Metal tolerate it, so no native regression run could ever catch it.
//
// This is a near-copy of CommonGrounds' `stencil_writer.gdshader`, which is the material
// that found the defect. The gate needs three things to be true at once, so do not
// "simplify" any of them away:
//   1. a stencil_mode is declared here,
//   2. the mesh carrying it casts shadows, and
//   3. the scene has at least one shadow-casting light (it has three).
// Drop any one and the shadow-pass variant is never built and the gate goes green.

stencil_mode write, compare_always, 1;

uniform vec3 marker_color : source_color = vec3(0.95, 0.25, 0.55);
uniform float visibility = 0.35;

void fragment() {
	// Kept faintly visible rather than ALPHA = 0.0, so a held run shows the gate is
	// actually drawing and not silently culled.
	ALBEDO = marker_color;
	ALPHA = visibility;
}
