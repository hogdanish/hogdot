#[compute]
#version 450

// Gate for RL-038 / RL-040 — a project's *own* GLSL, imported as an RDShaderFile and
// driven straight through RenderingDevice from script.
//
// ⚠ This is the coverage that phases 4 through 7 never had, and its absence is the
// single reason RL-036 (draw_list_draw arity), RL-037 (stencil on depth-only) and
// RL-038 (SPIR-V version) all shipped. Every other shader in this project is one of
// the engine's own, compiled through ShaderRD; nothing exercised the import path, so
// the fact that user GLSL was rejected outright on WebGPU could not be seen from here.
//
// Do not replace this with a runtime `shader_compile_spirv_from_source` call. The
// point is the *imported* path: .glsl is compiled to SPIR-V at import time, headless,
// with no RenderingDevice, and baked into the pack. That is the path that was broken,
// and it is the only one a shipped game uses.
//
// Deliberately exercises, in one dispatch:
//   - a read-only storage image  → the driver's read-only/read-write storage texture
//     handling and, on adapters without `readonly-and-readwrite-storage-textures`, the
//     write+shadow split. This is the shape CommonGrounds' jump-flood pass takes once
//     its qualifiers are correct.
//   - a write-only storage image → strip_writeonly_storage()
//   - a storage buffer with an atomic → SSBO binding and WGSL atomics via Tint
//   - a push constant block       → convert_push_constants_to_uniforms() and the ring
//                                   buffer, on a user shader rather than an engine one

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform readonly image2D u_src_image;
layout(set = 0, binding = 1, rgba16f) uniform writeonly image2D u_dst_image;

layout(set = 0, binding = 2, std430) buffer CounterBuffer {
	uint hits;
	uint pad0;
	uint pad1;
	uint pad2;
}
counter;

layout(push_constant, std430) uniform Params {
	vec2 size;
	float threshold;
	float pad;
}
params;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	if (coord.x >= int(params.size.x) || coord.y >= int(params.size.y)) {
		return;
	}

	vec4 src = imageLoad(u_src_image, coord);
	float luma = dot(src.rgb, vec3(0.2126, 0.7152, 0.0722));

	vec4 result;
	if (luma > params.threshold) {
		result = vec4(1.0, 0.0, 0.0, 1.0);
		atomicAdd(counter.hits, 1u);
	} else {
		result = src * 0.5;
	}

	imageStore(u_dst_image, coord, result);
}
