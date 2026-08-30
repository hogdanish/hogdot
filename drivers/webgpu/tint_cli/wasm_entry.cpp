/**************************************************************************/
/*  wasm_entry.cpp                                                        */
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

// Entry point of tint_convert.wasm — the Tint translation core as a standalone
// module a Web Worker can load.
//
// ⚠ This is a SECOND copy of Tint and SPIRV-Tools. It has to be: a Web Worker is
// a separate JS realm with its own wasm instance, so it cannot reach the copy
// already linked into the engine module. That download is the whole cost of the
// worker approach and is the number the ship decision turns on — build.sh
// --wasm prints it.
//
// ⚠ It must produce BYTE-IDENTICAL WGSL to the main thread, or a shader
// translated by the worker renders differently from the same shader translated
// synchronously after a fallback — a difference that would appear only under
// load and would look like a flake. That is why the pass pipeline is
// spirv_preprocess::run_translation_passes() and not a copy of the list.

#include "drivers/webgpu/spirv_preprocess.h"
#include "drivers/webgpu/tint_wrapper.h"

#include <emscripten/emscripten.h>

#include <cstdlib>
#include <cstring>

namespace {

// The most recent translation's outputs, owned by this module until the next
// call. The worker copies them out through the accessors below before posting.
char *g_result_wgsl = nullptr;
char *g_result_error = nullptr;

void clear_result() {
	free(g_result_wgsl);
	free(g_result_error);
	g_result_wgsl = nullptr;
	g_result_error = nullptr;
}

bool g_initialized = false;

} // namespace

extern "C" {

// Allocate a buffer for the worker to write SPIR-V into. Plain malloc so the
// worker can use Module.HEAPU8.set() and free it with tint_wasm_free().
EMSCRIPTEN_KEEPALIVE void *tint_wasm_alloc(int p_size) {
	if (p_size <= 0) {
		return nullptr;
	}
	return malloc((size_t)p_size);
}

EMSCRIPTEN_KEEPALIVE void tint_wasm_free(void *p_ptr) {
	free(p_ptr);
}

// Translate SPIR-V to WGSL. Returns 1 on success, 0 on failure; the result (or
// the error text) is read with the accessors below and stays valid until the
// next call.
//
// ⚠ p_keep_overrides must match what the main thread would have passed for the
// same shader, or the worker's WGSL and the main thread's disagree about
// whether `@id(N) override` declarations exist — which decides, per shader,
// whether specialization takes the pipeline-constants path or the module
// fan-out.
EMSCRIPTEN_KEEPALIVE int tint_wasm_translate(const uint8_t *p_spv, int p_size, int p_keep_overrides) {
	clear_result();

	if (!g_initialized) {
		tint_wrapper_initialize();
		g_initialized = true;
	}

	if (!p_spv || p_size < 20 || (p_size % 4) != 0) {
		g_result_error = strdup("Invalid SPIR-V: too small or not aligned to 4 bytes");
		return 0;
	}

	Vector<uint8_t> spv;
	spv.resize((int64_t)p_size);
	memcpy(spv.ptrw(), p_spv, (size_t)p_size);

	spv = spirv_preprocess::run_translation_passes(spv, p_keep_overrides != 0);

	// Ensure the SPIR-V version is at least 1.3, exactly as tint_convert_cli does
	// and for the same reason: convert_push_constants_to_uniforms emits the
	// StorageBuffer storage class, which older SPIR-V cannot express, and Tint
	// rejects the module with "2nd operand of TypePointer: operand StorageBuffer
	// requires SPIR-V version 1.3".
	//
	// ⚠ NOT byte-affecting for anything the driver would ever post: engine SPIR-V
	// is already >= 1.3, so this rewrites nothing and the worker's WGSL stays
	// identical to the main thread's. It exists so this module can also be driven
	// against the 1.0 fixtures in webgpu_tests/shader_corpus/, which is how the
	// build target is verified without a browser. It is deliberately NOT inside
	// run_translation_passes(): folding it in there would change what the runtime
	// driver emits, which has never done this bump.
	if (spv.size() >= 20) {
		uint32_t version = 0;
		memcpy(&version, spv.ptr() + 4, 4);
		if (version < 0x00010300) {
			version = 0x00010300;
			memcpy(spv.ptrw() + 4, &version, 4);
		}
	}

	const int word_count = (int)(spv.size() / 4);
	const uint32_t *words = reinterpret_cast<const uint32_t *>(spv.ptr());

	char *error_msg = nullptr;
	char *wgsl = tint_wrapper_spirv_to_wgsl(words, (size_t)word_count, &error_msg);
	if (!wgsl) {
		g_result_error = error_msg ? error_msg : strdup("Tint SPIR-V to WGSL failed (unknown error)");
		return 0;
	}

	g_result_wgsl = wgsl;
	return 1;
}

EMSCRIPTEN_KEEPALIVE const char *tint_wasm_result() {
	return g_result_wgsl ? g_result_wgsl : "";
}

EMSCRIPTEN_KEEPALIVE const char *tint_wasm_error() {
	return g_result_error ? g_result_error : "";
}

// The translation-pipeline stamp this module was built from. The worker reports
// it at startup and the driver refuses the worker when it disagrees with the
// engine's own — a worker translating differently from the main thread is
// exactly the failure this whole file is written to avoid.
EMSCRIPTEN_KEEPALIVE const char *tint_wasm_pipeline_id() {
#ifdef TINT_CLI_PIPELINE_ID
	return TINT_CLI_PIPELINE_ID;
#else
	return "unstamped";
#endif
}

} // extern "C"
