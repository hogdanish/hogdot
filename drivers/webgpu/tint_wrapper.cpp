/**************************************************************************/
/*  tint_wrapper.cpp                                                      */
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

#include "tint_wrapper.h"

#include "src/tint/api/tint.h"
#include "src/tint/lang/wgsl/writer/common/options.h"
#include "src/tint/utils/ice/ice.h"

#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

void tint_wrapper_initialize() {
	tint::Initialize();
}

// A TINT_ASSERT / TINT_ICE / TINT_UNREACHABLE ends in a [[noreturn]] destructor that
// traps the process; on web that aborts the wasm module and permanently kills the
// browser main loop, so an untranslatable shader would take the whole tab down.
// Vendored patch 0008 adds a process-global ICE handler that may transfer control
// away instead of returning; this one longjmps back to the SpirvToWgsl call site so
// an ICE surfaces as an ordinary translation failure. Shader translation is
// main-thread-only on this backend (RL-043), so one static jmp_buf suffices.
// Objects alive inside Tint when the ICE fires are leaked — accepted: this is a
// should-never-happen escape from a path that used to kill the process.
static std::jmp_buf s_ice_escape;
static char s_ice_message[2048];

static void _ice_escape_handler(std::string p_err, void *) {
	snprintf(s_ice_message, sizeof(s_ice_message), "%s", p_err.c_str());
	std::longjmp(s_ice_escape, 1);
}

char *tint_wrapper_spirv_to_wgsl(const uint32_t *p_spirv_words, size_t p_word_count, char **r_error) {
	std::vector<uint32_t> words(p_spirv_words, p_spirv_words + p_word_count);

	// Allow all WGSL extensions and language features so Tint can emit
	// constructs like readonly storage textures without validation errors.
	tint::wgsl::writer::Options wgsl_options;
	wgsl_options.allowed_features = tint::wgsl::AllowedFeatures::Everything();
	// Godot's GLSL shaders use textureSample/dpdx in non-uniform control flow
	// (valid in Vulkan, but WGSL requires uniform control flow for derivatives).
	// This inserts `diagnostic(off, derivative_uniformity)` in the output.
	wgsl_options.allow_non_uniform_derivatives = true;

	if (setjmp(s_ice_escape) != 0) {
		// An internal compiler error escaped here through the handler.
		tint::SetInternalCompilerErrorHandler({});
		if (r_error) {
			size_t len = strlen(s_ice_message) + 1;
			char *err = (char *)malloc(len);
			if (err) {
				memcpy(err, s_ice_message, len);
			}
			*r_error = err;
		}
		return nullptr;
	}

	tint::SetInternalCompilerErrorHandler({ &_ice_escape_handler, nullptr });
	auto result = tint::SpirvToWgsl(words, wgsl_options);
	tint::SetInternalCompilerErrorHandler({});
	if (result != tint::Success) {
		if (r_error) {
			const std::string &reason = result.Failure().reason;
			char *err = (char *)malloc(reason.size() + 1);
			if (err) {
				memcpy(err, reason.c_str(), reason.size() + 1);
			}
			*r_error = err;
		}
		return nullptr;
	}

	const std::string &wgsl = result.Get();
	char *out = (char *)malloc(wgsl.size() + 1);
	if (!out) {
		return nullptr;
	}
	memcpy(out, wgsl.c_str(), wgsl.size() + 1);
	return out;
}
