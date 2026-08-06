/**************************************************************************/
/*  fuzz_preprocess_passes.cpp                                            */
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

// Fuzz all 13 SPIR-V preprocessing passes in sequence.
//
// Exercises the passes without Tint parsing, catching crashes in the
// raw SPIR-V manipulation code (out-of-bounds, integer overflow, etc.).

#include "drivers/webgpu/spirv_preprocess.h"

#include <cstddef>
#include <cstdint>
#include <cstring>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	Vector<uint8_t> spv;
	spv.resize((int64_t)size);
	if (size > 0) {
		memcpy(spv.ptrw(), data, size);
	}

	// Run each pass in the same order as tint_convert_cli/main.cpp.
	// Each pass must handle arbitrary byte sequences without crashing.
	spv = spirv_preprocess::freeze_spec_constant_ops(spv);
	spv = spirv_preprocess::rewrite_copy_logical(spv);
	spv = spirv_preprocess::rewrite_terminate_invocation(spv);
	spv = spirv_preprocess::convert_push_constants_to_uniforms(spv);
	spv = spirv_preprocess::split_combined_samplers(spv);
	auto depth_result = spirv_preprocess::fix_depth2_images(spv);
	spv = depth_result.bytes;
	spv = spirv_preprocess::negate_position_y(spv);
	spv = spirv_preprocess::strip_restrict_decoration(spv);
	spv = spirv_preprocess::strip_memory_barrier(spv);
	spv = spirv_preprocess::fix_nonfinite_literals(spv);
	spv = spirv_preprocess::flatten_binding_arrays(spv);
	spv = spirv_preprocess::strip_writeonly_storage(spv);
	spv = spirv_preprocess::infer_readonly_storage(spv);

	return 0;
}
