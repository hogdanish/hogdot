/**************************************************************************/
/*  rendering_shader_container_webgpu.h                                   */
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

// ⚠ Deliberately not guarded by WEBGPU_ENABLED: the container only depends on
// servers/rendering and is compiled into every editor build so the shader baker
// can bake WebGPU shaders for web exports (see drivers/SCsub). The other
// container headers (Vulkan, Metal, D3D12) are unguarded for the same reason.
#include "servers/rendering/rendering_shader_container.h"

class RenderingShaderContainerWebGPU : public RenderingShaderContainer {
	GDSOFTCLASS(RenderingShaderContainerWebGPU, RenderingShaderContainer);

public:
	// Format identifier for WebGPU shader containers.
	static constexpr uint32_t FORMAT_WEBGPU = 0x57475055; // "WGPU"
	// Version 2 adds optional baked per-stage WGSL (shader baker step 2).
	// A version-1 runtime rejects version-2 containers cleanly (format_version
	// check) and falls back to runtime compilation; a version-2 runtime reads
	// version-1 containers as SPIR-V-only (flags bit absent).
	static constexpr uint32_t FORMAT_VERSION = 2;
	static constexpr uint32_t NO_PUSH_CONSTANTS = UINT32_MAX;

	// header_data.flags bit: every stage carries a baked WGSL block after its
	// SPIR-V payload. Set only when all stages baked (all-or-nothing — RL-027
	// requires the BGLs and modules of one shader to come from consistent WGSL).
	static constexpr uint32_t FLAG_HAS_BAKED_WGSL = 0x1;

	struct HeaderData {
		uint32_t push_constant_bind_group = NO_PUSH_CONSTANTS; // UINT32_MAX = no push constants.
		uint32_t push_constant_binding = 0;
		// ⚠ HeaderData must keep this exact size: from_bytes() parses the header
		// extra block before it validates format_version, so both versions must
		// read it identically.
		uint32_t flags = 0;
	};

	struct BakedStageWGSL {
		uint32_t decompressed_size = 0; // UTF-8 byte length, no null terminator.
		uint32_t compression_flags = 0; // CompressionFlags (zstd or raw).
		PackedByteArray bytes;
	};

protected:
	HeaderData header_data;
	Vector<BakedStageWGSL> stage_wgsl;

	// --- RenderingShaderContainer overrides ---

	virtual uint32_t _format() const override { return FORMAT_WEBGPU; }
	virtual uint32_t _format_version() const override { return FORMAT_VERSION; }

	/// Called by set_code_from_spirv() — stores raw SPIR-V bytes per stage,
	/// which the runtime driver translates to WGSL (preprocess + Tint) on
	/// first use, unless a baked WGSL block is present.
	virtual bool _set_code_from_spirv(const ReflectShader &p_shader) override;

	// Serialization overrides for extra header data and per-stage WGSL.
	virtual uint32_t _from_bytes_header_extra_data(const uint8_t *p_bytes) override;
	virtual uint32_t _to_bytes_header_extra_data(uint8_t *p_bytes) const override;
	virtual uint32_t _from_bytes_shader_extra_data(const uint8_t *p_bytes, uint32_t p_index) override;
	virtual uint32_t _to_bytes_shader_extra_data(uint8_t *p_bytes, uint32_t p_index) const override;

public:
	uint32_t get_push_constant_bind_group() const { return header_data.push_constant_bind_group; }
	uint32_t get_push_constant_binding() const { return header_data.push_constant_binding; }
	bool has_push_constants() const { return header_data.push_constant_bind_group != NO_PUSH_CONSTANTS; }

	// --- Baked WGSL (shader baker step 2) ---

	// Store bake-time WGSL for one stage (editor side). Compresses with zstd.
	bool bake_stage_wgsl(uint32_t p_index, const String &p_wgsl);
	// Set FLAG_HAS_BAKED_WGSL if and only if every stage has WGSL; otherwise
	// drop any partial bakes (all-or-nothing per shader).
	void finalize_baked_wgsl();
	bool has_baked_wgsl() const { return (header_data.flags & FLAG_HAS_BAKED_WGSL) != 0; }
	// Malloc'd, null-terminated WGSL for a stage, or nullptr when absent or
	// corrupt. The caller owns the allocation (free()).
	char *get_stage_wgsl_alloc(uint32_t p_index) const;

	RenderingShaderContainerWebGPU();
	virtual ~RenderingShaderContainerWebGPU();
};

// =============================================================================
// Format Factory
// =============================================================================

class RenderingShaderContainerFormatWebGPU : public RenderingShaderContainerFormat {
	GDSOFTCLASS(RenderingShaderContainerFormatWebGPU, RenderingShaderContainerFormat);

public:
	virtual Ref<RenderingShaderContainer> create_container() const override {
		return Ref<RenderingShaderContainerWebGPU>(memnew(RenderingShaderContainerWebGPU));
	}

	virtual ShaderLanguageVersion get_shader_language_version() const override {
		// Vulkan-flavour GLSL 1.1 — same as the Vulkan driver.
		return SHADER_LANGUAGE_VULKAN_VERSION_1_1;
	}

	virtual ShaderSpirvVersion get_shader_spirv_version() const override {
		// SPIR-V 1.3 — required so glslang emits SSBOs as StorageClass::StorageBuffer
		// (not the old-style StorageClass::Uniform + BufferBlock used in SPIR-V 1.0).
		// Tint correctly converts StorageClass::StorageBuffer → var<storage, read/read_write>.
		// SPIR-V 1.3 requires Vulkan 1.1 client, which matches our language version.
		return SHADER_SPIRV_VERSION_1_3;
	}
};
