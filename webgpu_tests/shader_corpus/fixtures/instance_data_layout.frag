#version 450

// ─── SceneState::InstanceData std430 layout fixture ────────────────────────
//
// Purpose: prove that the WebGPU SPIR-V preprocessing pipeline preserves the
// natural std430 member offsets of the forward-mobile per-instance SSBO struct
// after `flatten_binding_arrays` runs on the module. That pass does a raw
// word-by-word ID substitution over every instruction; ledger RL-028 caught it
// rewriting an `OpMemberDecorate ... Offset <literal>` on an unrelated struct
// when the literal collided numerically with a substituted ID. 4.7.1 grew this
// struct by `area_lights` + `padding` (16 bytes), which renumbers IDs across the
// whole module, so the check is rerun here rather than inherited.
//
// The pass only fires on a module that contains an array of handle types, so the
// `shadow_atlas` sampler array below is load-bearing, not decoration: without it
// `flatten_binding_arrays` returns the module untouched and the offset check is
// vacuous. Production carries `texture2DArray lightmap_textures[...]`
// (scene_forward_mobile_inc.glsl:390); a combined `sampler2D` array is used here
// because `split_combined_samplers` runs first and turns it into BOTH a texture
// array and a sampler array, so flattening is exercised on both handle kinds.
//
// ─── Sources this file is transcribed from — keep all three in step ─────────
//
// GLSL (field order and types copied verbatim):
//   servers/rendering/renderer_rd/shaders/forward_mobile/scene_forward_mobile_inc.glsl:344-371
//   (`struct InstanceData` + the `instances` SSBO at set 1, binding 1)
//
// C++ (the struct this must stay byte-paired with):
//   servers/rendering/renderer_rd/forward_mobile/render_forward_mobile.h:222-243
//   (`SceneState::InstanceData`)
//
// Expected std430 offsets, non-REAL_T_IS_DOUBLE build, 224 bytes total:
//   transform                    mat3x4 / float[12]  @   0  (48 B)
//   compressed_aabb_position_pad vec4   / float[4]   @  48  (16 B)
//   compressed_aabb_size_pad     vec4   / float[4]   @  64  (16 B)
//   uv_scale                     vec4   / float[4]   @  80  (16 B)
//   flags                        uint               @  96  ( 4 B)
//   instance_uniforms_ofs        uint               @ 100  ( 4 B)
//   gi_offset                    uint               @ 104  ( 4 B)
//   layer_mask                   uint               @ 108  ( 4 B)
//   prev_transform               mat3x4 / float[12]  @ 112  (48 B)
//   lightmap_uv_scale            vec4   / float[4]   @ 160  (16 B)
//   reflection_probes            uvec2  / uint[2]    @ 176  ( 8 B)
//   omni_lights                  uvec2  / uint[2]    @ 184  ( 8 B)
//   spot_lights                  uvec2  / uint[2]    @ 192  ( 8 B)
//   area_lights                  uvec2  / uint[2]    @ 200  ( 8 B)  NEW in 4.7.1
//   decals                       uvec2  / uint[2]    @ 208  ( 8 B)
//   padding                      uvec2  / uint[2]    @ 216  ( 8 B)  NEW in 4.7.1
//
// Every field is naturally aligned, so the passing result in
// results/instance_data_layout.wgsl is a WGSL struct whose members appear in this
// order with NO Tint-emitted @size or @align override — in particular none on
// area_lights, decals or padding. An override on a member means the recorded
// offset of the member after it no longer matches natural packing: that is the
// RL-028 symptom. Stop and file a ledger entry rather than adjusting this file.
//
// The `#ifdef USE_DOUBLE_PRECISION` tail of the production struct
// (model_precision, prev_model_precision) is deliberately omitted — this fixture
// pins the non-double build, which is what the web export ships.
// ────────────────────────────────────────────────────────────────────────────

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 frag_color;

struct InstanceData {
	highp mat3x4 transform;
	vec4 compressed_aabb_position_pad; // Only .xyz is used. .w is padding.
	vec4 compressed_aabb_size_pad; // Only .xyz is used. .w is padding.
	vec4 uv_scale;
	uint flags;
	uint instance_uniforms_ofs; // Base offset in global buffer for instance variables.
	uint gi_offset; // GI information when using lightmapping (VCT or lightmap index).
	uint layer_mask;
	highp mat3x4 prev_transform;

	vec4 lightmap_uv_scale; // Doubles as uv_offset when needed.
	uvec2 reflection_probes;
	uvec2 omni_lights;
	uvec2 spot_lights;
	uvec2 area_lights;
	uvec2 decals;
	uvec2 padding;
};

layout(set = 1, binding = 1, std430) buffer restrict readonly InstanceDataBuffer {
	InstanceData data[];
}
instances;

// The array of handles that makes flatten_binding_arrays run on this module.
// Indexed dynamically (dynamically uniform, from the push constant) exactly as
// production indexes lightmap_textures[ofs].
layout(set = 1, binding = 6) uniform sampler2D shadow_atlas[4];

layout(push_constant) uniform PushConstants {
	uint instance_index;
	uint atlas_index;
}
pc;

void main() {
	uint idx = pc.instance_index;

	// Read every member exactly once and fold it into the output so that no
	// member can be dead-stripped before the OpMemberDecorate Offset entries are
	// emitted. A stripped member is a silently vacuous offset check.
	mat3x4 transform = instances.data[idx].transform;
	vec3 aabb_position = instances.data[idx].compressed_aabb_position_pad.xyz;
	vec3 aabb_size = instances.data[idx].compressed_aabb_size_pad.xyz;
	vec4 uv_scale = instances.data[idx].uv_scale;
	uint flags = instances.data[idx].flags;
	uint instance_uniforms_ofs = instances.data[idx].instance_uniforms_ofs;
	uint gi_offset = instances.data[idx].gi_offset;
	uint layer_mask = instances.data[idx].layer_mask;
	mat3x4 prev_transform = instances.data[idx].prev_transform;
	vec4 lightmap_uv_scale = instances.data[idx].lightmap_uv_scale;
	uvec2 reflection_probes = instances.data[idx].reflection_probes;
	uvec2 omni_lights = instances.data[idx].omni_lights;
	uvec2 spot_lights = instances.data[idx].spot_lights;
	uvec2 area_lights = instances.data[idx].area_lights;
	uvec2 decals = instances.data[idx].decals;
	uvec2 padding = instances.data[idx].padding;

	// Float members.
	vec4 acc = transform[0] + transform[1] + transform[2];
	acc += prev_transform[0] + prev_transform[1] + prev_transform[2];
	acc += vec4(aabb_position, 1.0) + vec4(aabb_size, 1.0);
	acc += uv_scale + lightmap_uv_scale;

	// Integer members, including the two 4.7.1 additions. Packed light indices
	// are folded the same way the production shader unpacks them, so the read is
	// a real byte-offset-sensitive load and not a whole-struct copy.
	uint bits = flags;
	bits += instance_uniforms_ofs;
	bits += gi_offset;
	bits += layer_mask;
	bits += reflection_probes.x + reflection_probes.y;
	bits += omni_lights.x + omni_lights.y;
	bits += spot_lights.x + spot_lights.y;
	bits += area_lights.x + area_lights.y;
	bits += decals.x + decals.y;
	bits += padding.x + padding.y;

	// One byte out of each packed light word, matching the 0xFF-per-light
	// unpacking in scene_forward_mobile.glsl:2271-2276.
	uint area_light_0 = area_lights.x & 0xFFu;
	uint area_light_1 = (area_lights.x >> 8) & 0xFFu;

	vec4 atlas = texture(shadow_atlas[pc.atlas_index], v_uv);

	frag_color = acc + atlas + vec4(float(bits), float(area_light_0), float(area_light_1), 1.0);
}
