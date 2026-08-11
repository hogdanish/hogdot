/* clang-format off */
#[vertex]

#version 450

#VERSION_DEFINES

layout(location = 0) out vec2 uv_interp;
/* clang-format on */

void main() {
	vec2 base_arr[3] = vec2[](vec2(-1.0, -1.0), vec2(-1.0, 3.0), vec2(3.0, -1.0));
	gl_Position = vec4(base_arr[gl_VertexIndex], 0.0, 1.0);
	uv_interp = clamp(gl_Position.xy, vec2(0.0, 0.0), vec2(1.0, 1.0)) * 2.0; // saturate(x) * 2.0
}

/* clang-format off */
#[fragment]

#version 450

#VERSION_DEFINES

layout(location = 0) in vec2 uv_interp;

#ifdef MODE_COPY_DEPTH
// Single-sample depth copy. Declared separately from the multisampled resolve because a
// sampler2DMS binding cannot accept a single-sample texture, and read with texelFetch for
// the same reason the resolve below is: a 1:1 depth copy wants no filtering, and asking
// for a filterable sample of a depth format is not expressible on every backend. See
// WA-18 — hogdot's WebGPU driver has no legal bind-group layout for a depth texture
// paired with a filtering sampler, and the generic copy_to_fb path this replaced was
// silently handed a blank texture there.
layout(set = 0, binding = 0) uniform sampler2D source_depth;
#else
layout(set = 0, binding = 0) uniform sampler2DMS source_depth;
#endif

layout(push_constant, std430) uniform Params {
    ivec2 pad;
	int sample_count;
    int pad2;
}
params;

layout (location = 0) out float out_depth;

void main() {
    ivec2 pos = ivec2(gl_FragCoord.xy);

#ifdef MODE_COPY_DEPTH
	out_depth = texelFetch(source_depth, pos, 0).r;
#else
	float depth_avg = 0.0;
	for (int i = 0; i < params.sample_count; i++) {
		depth_avg += texelFetch(source_depth, pos, i).r;
	}
	depth_avg /= float(params.sample_count);
	out_depth = depth_avg;
#endif
}
