/**************************************************************************/
/*  shader_baker_export_plugin_platform_webgpu.h                          */
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

#include "drivers/webgpu/rendering_shader_container_webgpu.h"
#include "editor/export/shader_baker_export_plugin.h"

// Bake-time container: after storing SPIR-V (base class), translates every
// stage to override-constant WGSL by shelling out to bin/tint_convert_cli
// (--overrides --batch) and stores the result beside the SPIR-V (container v2).
// With an empty CLI path it degrades to the base SPIR-V-only bake.
class RenderingShaderContainerWebGPUBaked : public RenderingShaderContainerWebGPU {
	GDSOFTCLASS(RenderingShaderContainerWebGPUBaked, RenderingShaderContainerWebGPU);

	String cli_path;

	void _bake_wgsl();

protected:
	virtual bool _set_code_from_spirv(const ReflectShader &p_shader) override;

public:
	void set_cli_path(const String &p_cli_path) { cli_path = p_cli_path; }
};

class RenderingShaderContainerFormatWebGPUBaked : public RenderingShaderContainerFormatWebGPU {
	GDSOFTCLASS(RenderingShaderContainerFormatWebGPUBaked, RenderingShaderContainerFormatWebGPU);

	// Empty when WGSL baking is unavailable (missing or stale CLI) — containers
	// then bake SPIR-V only.
	String cli_path;

public:
	explicit RenderingShaderContainerFormatWebGPUBaked(const String &p_cli_path) :
			cli_path(p_cli_path) {}
	virtual Ref<RenderingShaderContainer> create_container() const override;
};

class ShaderBakerExportPluginPlatformWebGPU : public ShaderBakerExportPluginPlatform {
	GDCLASS(ShaderBakerExportPluginPlatformWebGPU, ShaderBakerExportPluginPlatform);

public:
	virtual RenderingShaderContainerFormat *create_shader_container_format(const Ref<EditorExportPlatform> &p_platform, const Ref<EditorExportPreset> &p_preset) override;
	virtual bool matches_driver(const String &p_driver) override;

	// The one platform that can never take the FP16 shader groups:
	// RenderingDeviceDriverWebGPU::has_feature(SUPPORTS_HALF_FLOAT) returns false
	// unconditionally, because WebGPU's shader-f16 extension is not reliably available
	// and the driver deliberately keeps f16 out of the SPIR-V it generates. ⚠ Enabling
	// f16 for WebGPU means flipping that has_feature() **and** this override together —
	// they are one decision, and the export would otherwise ship no FP16 shaders for a
	// runtime that had started asking for them.
	virtual bool supports_half_float() const override { return false; }
	virtual String get_cache_key_suffix() const override { return cache_key_suffix; }

private:
	// "wgsl-<pipeline id>" when the CLI can bake WGSL, "spv" when the bake degrades.
	String cache_key_suffix;

	// WebGPU has no input attachments and no subpass reads — the driver flattens
	// subpasses, RenderForwardMobile refuses subpass post-processing under WEB_ENABLED,
	// and ToneMapper disables its subpass variants there. Saying so here keeps a desktop
	// editor from baking (and failing to translate) shaders the browser can never run.
	virtual bool supports_input_attachments() const override { return false; }

	// WebGPU cannot use the octmap color format as a storage image, so the browser
	// runtime takes the RASTER octmap path (RendererSceneRenderRD::init()) while the
	// desktop editor doing the bake takes the compute one. Without this the three
	// Octmap*Raster versions are absent from every export and Tint translates them on
	// the browser main thread at first sky radiance update, every boot.
	virtual bool uses_raster_octmap() const override { return true; }
};
