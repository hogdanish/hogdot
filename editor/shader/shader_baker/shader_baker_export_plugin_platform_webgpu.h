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
};
