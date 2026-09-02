/**************************************************************************/
/*  rendering_shader_container_webgpu.cpp                                 */
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

#include "rendering_shader_container_webgpu.h"

#include "core/io/compression.h"

#include <cstdlib>

// =========================================================================
// SPIR-V Storage
// =========================================================================
//
// This container stores raw SPIR-V, one blob per stage.
//
// ⚠ The comment that used to sit here claimed "Dawn's emdawnwebgpu port natively
// supports WGPUShaderSourceSPIRV; no WGSL/Tint translation step is needed." That is
// false and has been since before the port started. emdawnwebgpu does NOT accept
// WGPUShaderSourceSPIRV — see the note beside the _spv_to_wgsl_cached() call in
// RenderingDeviceDriverWebGPU::shader_create_from_container() — and the driver
// translates SPIR-V to WGSL with Tint at runtime, on first use of each pipeline, on
// the main thread.
//
// The practical consequence is the one to keep in mind when reading this file: what
// is stored here is an *input* to that translation, not something the browser can
// consume. The shader baker now stores these containers at export time (see
// ShaderBakerExportPluginPlatformWebGPU), which removes glslang from the runtime
// path; the SPIR-V must stay at version 1.3 because Tint's runtime reader rejects
// anything newer. Storing WGSL instead would also move Tint to bake time and is the
// structural answer to first-use pipeline cost, but it requires Tint compiled into
// the editor. See RL-042 and feature-shader-baker.md.
//
// Push constant handling:
//   Godot's push constants are emulated via a uniform buffer at a fixed
//   bind group slot (default: group 3, binding 0).
//   The bind group slot is recorded in HeaderData and used by the driver
//   to create the pipeline layout and bind the ring buffer at draw time.

bool RenderingShaderContainerWebGPU::_set_code_from_spirv(const ReflectShader &p_shader) {
	const uint32_t stage_count = p_shader.shader_stages.size();
	shaders.resize(stage_count);

	for (uint32_t i = 0; i < stage_count; i++) {
		const ReflectShaderStage &stage = p_shader.shader_stages[i];
		// Store raw SPIR-V bytes directly — no translation.
		Vector<uint8_t> spirv_bytes = stage.spirv_data();
		shaders.write[i].shader_stage = stage.shader_stage;
		shaders.write[i].code_compression_flags = 0; // No compression.
		shaders.write[i].code_decompressed_size = 0; // 0 = not compressed (use raw bytes).
		shaders.write[i].code_compressed_bytes = spirv_bytes;
	}

	// Decide push constant bind group slot.
	if (p_shader.push_constant_size > 0) {
		// Convention: push constants use bind group 3, binding PUSH_CONSTANT_RING_BINDING (120).
		// Chosen high enough to avoid collision with split combined-sampler bindings
		// (original binding N → sampler@N*2, image@N*2+1; max reasonable N ~20 → max~41).
		// Must match the binding in spirv_preprocess::convert_push_constants_to_uniforms()
		// and PUSH_CONSTANT_RING_BINDING in rendering_device_driver_webgpu.h.
		header_data.push_constant_bind_group = 3;
		header_data.push_constant_binding = 120; // PUSH_CONSTANT_RING_BINDING
	} else {
		header_data.push_constant_bind_group = RenderingShaderContainerWebGPU::NO_PUSH_CONSTANTS;
		header_data.push_constant_binding = 120; // PUSH_CONSTANT_RING_BINDING
	}

	return true;
}

// =========================================================================
// Serialization
// =========================================================================

uint32_t RenderingShaderContainerWebGPU::_from_bytes_header_extra_data(const uint8_t *p_bytes) {
	if (p_bytes) {
		memcpy(&header_data, p_bytes, sizeof(HeaderData));
	}
	return sizeof(HeaderData);
}

uint32_t RenderingShaderContainerWebGPU::_to_bytes_header_extra_data(uint8_t *p_bytes) const {
	if (p_bytes) {
		memcpy(p_bytes, &header_data, sizeof(HeaderData));
	}
	return sizeof(HeaderData);
}

// Per-stage baked WGSL block, present only when FLAG_HAS_BAKED_WGSL is set:
// u32 decompressed_size, u32 compression_flags, u32 stored_size, bytes,
// padded to 4 — the base serializer reads the next ShaderHeader immediately
// after this block, so it must preserve 4-byte alignment.
static uint32_t _aligned4(uint32_t p_size) {
	return (p_size + 3u) & ~3u;
}

uint32_t RenderingShaderContainerWebGPU::_from_bytes_shader_extra_data(const uint8_t *p_bytes, uint32_t p_index) {
	if (!has_baked_wgsl()) {
		return 0;
	}
	if (stage_wgsl.size() != shaders.size()) {
		stage_wgsl.resize(shaders.size());
	}
	ERR_FAIL_COND_V(p_index >= (uint32_t)stage_wgsl.size(), 0);

	BakedStageWGSL &stage = stage_wgsl.ptrw()[p_index];
	uint32_t header[3];
	memcpy(header, p_bytes, sizeof(header));
	stage.decompressed_size = header[0];
	stage.compression_flags = header[1];
	const uint32_t stored_size = header[2];
	stage.bytes.resize(stored_size);
	memcpy(stage.bytes.ptrw(), p_bytes + sizeof(header), stored_size);
	return sizeof(header) + _aligned4(stored_size);
}

uint32_t RenderingShaderContainerWebGPU::_to_bytes_shader_extra_data(uint8_t *p_bytes, uint32_t p_index) const {
	if (!has_baked_wgsl()) {
		return 0;
	}
	ERR_FAIL_COND_V(p_index >= (uint32_t)stage_wgsl.size(), 0);

	const BakedStageWGSL &stage = stage_wgsl[p_index];
	const uint32_t stored_size = (uint32_t)stage.bytes.size();
	const uint32_t total = sizeof(uint32_t) * 3 + _aligned4(stored_size);
	if (p_bytes) {
		uint32_t header[3] = { stage.decompressed_size, stage.compression_flags, stored_size };
		memcpy(p_bytes, header, sizeof(header));
		memcpy(p_bytes + sizeof(header), stage.bytes.ptr(), stored_size);
		// The pad bytes are already zero: to_bytes() resize_initialized()s the buffer.
	}
	return total;
}

// =========================================================================
// Baked WGSL (shader baker step 2)
// =========================================================================

bool RenderingShaderContainerWebGPU::bake_stage_wgsl(uint32_t p_index, const String &p_wgsl) {
	if (stage_wgsl.size() != shaders.size()) {
		stage_wgsl.resize(shaders.size());
	}
	ERR_FAIL_COND_V(p_index >= (uint32_t)stage_wgsl.size(), false);
	ERR_FAIL_COND_V(p_wgsl.is_empty(), false);

	const CharString utf8 = p_wgsl.utf8();
	const uint32_t raw_size = (uint32_t)utf8.length();

	PackedByteArray compressed;
	compressed.resize(Compression::get_max_compressed_buffer_size(raw_size, Compression::MODE_ZSTD));
	uint32_t compressed_size = 0;
	uint32_t compression_flags = 0;
	if (!compress_code((const uint8_t *)utf8.get_data(), raw_size, compressed.ptrw(), &compressed_size, &compression_flags)) {
		return false;
	}
	compressed.resize(compressed_size);

	BakedStageWGSL &stage = stage_wgsl.ptrw()[p_index];
	stage.decompressed_size = raw_size;
	stage.compression_flags = compression_flags;
	stage.bytes = compressed;
	return true;
}

void RenderingShaderContainerWebGPU::finalize_baked_wgsl() {
	bool all_baked = shaders.size() > 0 && stage_wgsl.size() == shaders.size();
	for (int64_t i = 0; all_baked && i < stage_wgsl.size(); i++) {
		all_baked = stage_wgsl[i].decompressed_size > 0 && !stage_wgsl[i].bytes.is_empty();
	}

	if (all_baked) {
		header_data.flags |= FLAG_HAS_BAKED_WGSL;
		if (wgsl_only) {
			// ⚠ Drops the SPIR-V for every stage. Legal only because the baker translates
			// with `--overrides`, so this container's WGSL carries `@id(N) override`
			// declarations and the driver specializes at pipeline creation
			// (`has_override_declarations`) rather than by patching SPIR-V and re-running
			// Tint. The only consumer of `WGShader::stage_spirv` is
			// `_create_module_with_spec_constants`, which that path never reaches.
			//
			// ⚠ And it removes the fallback: a stage whose WGSL fails to decompress at
			// runtime has nothing left to translate from, and the shader fails to create
			// rather than degrading. FLAG_WGSL_ONLY is what tells the driver to say so.
			header_data.flags |= FLAG_WGSL_ONLY;
			for (int64_t i = 0; i < shaders.size(); i++) {
				shaders.write[i].code_compressed_bytes = PackedByteArray();
				shaders.write[i].code_compression_flags = 0;
				shaders.write[i].code_decompressed_size = 0;
			}
		}
	} else {
		header_data.flags &= ~(FLAG_HAS_BAKED_WGSL | FLAG_WGSL_ONLY);
		stage_wgsl.clear();
	}
}

char *RenderingShaderContainerWebGPU::get_stage_wgsl_alloc(uint32_t p_index) const {
	if (!has_baked_wgsl() || p_index >= (uint32_t)stage_wgsl.size()) {
		return nullptr;
	}

	const BakedStageWGSL &stage = stage_wgsl[p_index];
	if (stage.decompressed_size == 0 || stage.bytes.is_empty()) {
		return nullptr;
	}

	char *out = (char *)malloc((size_t)stage.decompressed_size + 1);
	if (out == nullptr) {
		return nullptr;
	}
	if (!decompress_code(stage.bytes.ptr(), (uint32_t)stage.bytes.size(), stage.compression_flags, (uint8_t *)out, stage.decompressed_size)) {
		free(out);
		return nullptr;
	}
	out[stage.decompressed_size] = '\0';
	return out;
}

// =========================================================================
// Public API
// =========================================================================

RenderingShaderContainerWebGPU::RenderingShaderContainerWebGPU() {
}

RenderingShaderContainerWebGPU::~RenderingShaderContainerWebGPU() {
}
