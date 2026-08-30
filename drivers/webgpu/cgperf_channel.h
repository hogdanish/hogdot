/**************************************************************************/
/*  cgperf_channel.h                                                      */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#pragma once

#include <stdint.h>

// =============================================================================
// window.__cgPerf — always-on, release-safe driver telemetry channel
// =============================================================================
//
// Backing storage for the browser-side telemetry channel the WebGPU driver
// publishes at `window.__cgPerf`. One file-scope instance lives in
// rendering_device_driver_webgpu.cpp; JS reads it as a live view over the wasm
// heap, so nothing here is ever allocated, resized or copied per frame.
//
// ⚠ -sALLOW_MEMORY_GROWTH=1 is set for every web build, which DETACHES any
// Float64Array/Uint32Array view over the wasm heap the moment the heap grows.
// The JS side must therefore re-derive its views from Module['HEAPF64'] /
// Module['HEAPU32'] on every read and must never cache one. The install in
// rendering_device_driver_webgpu.cpp does this through property getters.
//
// Field order in `frames` is a cross-repo contract and must not be reordered;
// consumers read the flat buffer by index. See the frames_schema names below.
//
// ⚠ Slots 2..6 are a documented deviation (D-3). The contract asked for the
// five RENDERING_INFO_PIPELINE_COMPILATIONS_* deltas, which live in the
// renderer layer (servers/rendering/rendering_server_default.cpp) and are not
// reachable from a RenderingDeviceDriver without inverting the RD layering.
// The game samples those five itself, per frame, at identical granularity
// (one engine iteration == one begin_segment == one rAF on web). The five
// slots instead carry driver-local creation counts, which nothing else can
// see, and frames_schema names them honestly rather than by the contract's
// labels.

struct CGPerfChannel {
	// Per-frame ring row layout. The enum's order IS the wire order.
	enum FrameField {
		F_FRAME_IDX = 0,
		F_CPU_FRAME_MS,
		F_RENDER_PIPELINES_CREATED, // contract slot pc_canvas_d — see D-3 above.
		F_COMPUTE_PIPELINES_CREATED, // contract slot pc_mesh_d
		F_SHADER_MODULES_CREATED, // contract slot pc_surface_d
		F_BINDGROUP_LAYOUTS_CREATED, // contract slot pc_draw_d
		F_BINDGROUPS_CREATED, // contract slot pc_spec_d
		F_RENDER_PASSES,
		F_DRAW_CALLS,
		F_BINDGROUP_SETS,
		F_ENCODER_SPLITS,
		F_SUBMIT_MS,
		F_FENCE_LAG,
		FRAME_STRIDE, // Must stay last.
	};

	// Monotonic-since-boot counters. Order matches COUNTER_NAMES below.
	enum Counter {
		C_BAKED_WGSL_HIT = 0,
		C_BAKED_WGSL_MISS,
		C_SPV_WGSL_CACHE_HIT,
		C_SPV_WGSL_CACHE_MISS,
		C_ACQUIRE_FAIL,
		C_RESIZE_SKIP,
		C_RECONFIGURE,
		C_DEVICE_LOST,
		C_UNCAPTURED_ERROR,
		C_RENDER_PIPELINES_CREATED,
		C_COMPUTE_PIPELINES_CREATED,
		C_SHADER_MODULES_CREATED,
		C_BINDGROUP_LAYOUTS_CREATED,
		C_BINDGROUPS_CREATED,
		C_ENCODER_SPLITS,
		COUNTER_COUNT, // Must stay last.
	};

	// 3600 rows == 30 s at 120 Hz (contract §1). 3600 * 13 * 8 B ≈ 375 KB of
	// .bss, noise against the 256 MiB initial heap of a release web build.
	static constexpr uint32_t FRAME_CAP = 3600;

	double frames[FRAME_CAP * FRAME_STRIDE] = {};
	double counters[COUNTER_COUNT] = {};

	// Monotonic count of rows ever written; the live slot is frame_head % FRAME_CAP.
	// Read by JS as a u32 so a consumer can tell how much of the ring is valid
	// and detect wraparound between two reads.
	uint32_t frame_head = 0;

	// performance.timeOrigin, captured once. Every timestamp published on the
	// channel is emscripten_get_now() - time_origin_ms, which is exactly
	// performance.now() — the clock the in-page harness stamps its own records
	// with. emscripten_get_now() is `timeOrigin + now()`, so mixing the two
	// desyncs the fork's rings from the page's timeline by ~timeOrigin.
	double time_origin_ms = 0.0;

	bool installed = false;

	// Advance the ring and return the row to write. Never allocates.
	double *frame_row_advance() {
		double *row = &frames[(frame_head % FRAME_CAP) * FRAME_STRIDE];
		frame_head++;
		return row;
	}

	void count(Counter p_counter) { counters[p_counter] += 1.0; }
};

// Newline-joined field names handed to the JS install. Kept beside the enums so
// the two can only drift if someone edits one line and not the one below it.
//
// ⚠ Newline-joined, not comma-joined: EM_ASM is a preprocessor macro whose body
// is split on every top-level comma, and the install marshals these as one
// string across a single boundary crossing.
#define CGPERF_FRAME_SCHEMA_JOINED \
	"frame_idx\ncpu_frame_ms\nrender_pipelines_created\n" \
	"compute_pipelines_created\nshader_modules_created\n" \
	"bindgroup_layouts_created\nbindgroups_created\nrender_passes\n" \
	"draw_calls\nbindgroup_sets\nencoder_splits\nsubmit_ms\nfence_lag"

#define CGPERF_COUNTER_NAMES_JOINED \
	"baked_wgsl_hit\nbaked_wgsl_miss\nspv_wgsl_cache_hit\n" \
	"spv_wgsl_cache_miss\nacquire_fail\nresize_skip\nreconfigure\n" \
	"device_lost\nuncaptured_error\nrender_pipelines_created\n" \
	"compute_pipelines_created\nshader_modules_created\n" \
	"bindgroup_layouts_created\nbindgroups_created\nencoder_splits"

// Drift guard. The JS side sizes its heap views from `names.length`, so a name
// list that disagrees with its enum reads short (missing counters) or past the
// block (garbage) — silently, in the browser, with nothing to catch it. Make it
// a build error instead.
constexpr uint32_t cgperf_count_joined_fields(const char *p_joined) {
	uint32_t n = 1;
	for (const char *c = p_joined; *c != '\0'; c++) {
		if (*c == '\n') {
			n++;
		}
	}
	return n;
}

static_assert(cgperf_count_joined_fields(CGPERF_FRAME_SCHEMA_JOINED) == CGPerfChannel::FRAME_STRIDE,
		"CGPERF_FRAME_SCHEMA_JOINED must name exactly one field per CGPerfChannel::FrameField.");
static_assert(cgperf_count_joined_fields(CGPERF_COUNTER_NAMES_JOINED) == CGPerfChannel::COUNTER_COUNT,
		"CGPERF_COUNTER_NAMES_JOINED must name exactly one counter per CGPerfChannel::Counter.");
