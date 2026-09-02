/**************************************************************************/
/*  shader_baker_export_plugin_platform_webgpu.cpp                        */
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

#include "shader_baker_export_plugin_platform_webgpu.h"

#include "core/config/project_settings.h"
#include "core/io/dir_access.h"
#include "core/io/file_access.h"
#include "core/io/json.h"
#include "core/os/os.h"
#include "editor/shader/shader_baker/tint_pipeline_id.gen.h"

bool RenderingShaderContainerWebGPUBaked::_set_code_from_spirv(const ReflectShader &p_shader) {
	if (!RenderingShaderContainerWebGPU::_set_code_from_spirv(p_shader)) {
		return false;
	}
	if (!cli_path.is_empty()) {
		_bake_wgsl();
	}
	return true;
}

void RenderingShaderContainerWebGPUBaked::_bake_wgsl() {
	// Runs on a WorkerThreadPool task (one per shader variant); everything here
	// must be thread-safe. OS::execute and the temp-dir API are.
	Error err = OK;
	Ref<DirAccess> temp_dir = DirAccess::create_temp("shader_baker_webgpu", false, &err);
	if (err != OK || temp_dir.is_null()) {
		WARN_PRINT_ONCE("Shader baker: cannot create a temporary directory; baking SPIR-V only.");
		return;
	}

	const String dir_path = temp_dir->get_current_dir();
	List<String> args;
	args.push_back("--overrides");
	args.push_back("--batch");

	Vector<String> stage_files;
	for (int64_t i = 0; i < shaders.size(); i++) {
		const String stage_file = dir_path.path_join(vformat("stage_%d.spv", (int)i));
		Ref<FileAccess> f = FileAccess::open(stage_file, FileAccess::WRITE);
		if (f.is_null()) {
			WARN_PRINT_ONCE("Shader baker: cannot write a temporary SPIR-V file; baking SPIR-V only.");
			return;
		}
		f->store_buffer(shaders[i].code_compressed_bytes);
		f.unref();
		stage_files.push_back(stage_file);
		args.push_back(stage_file);
	}

	String output;
	int exit_code = -1;
	err = OS::get_singleton()->execute(cli_path, args, &output, &exit_code);
	if (err != OK || exit_code != 0 || output.is_empty()) {
		WARN_PRINT(vformat("Shader baker: tint_convert_cli failed for shader '%s' (exit %d); baking SPIR-V only for it.", String(shader_name.ptr()), exit_code));
		return;
	}

	const Variant parsed = JSON::parse_string(output);
	if (parsed.get_type() != Variant::DICTIONARY) {
		WARN_PRINT(vformat("Shader baker: unparsable tint_convert_cli output for shader '%s'; baking SPIR-V only for it.", String(shader_name.ptr())));
		return;
	}

	const Dictionary results = parsed;
	for (int64_t i = 0; i < shaders.size(); i++) {
		const Variant stage_result = results.get(stage_files[i], Variant());
		if (stage_result.get_type() == Variant::STRING && !String(stage_result).is_empty()) {
			bake_stage_wgsl(i, stage_result);
		} else {
			// Translation failures degrade this shader to SPIR-V-only
			// (finalize_baked_wgsl drops partial bakes); the runtime then
			// translates it live, exactly as before step 2.
			String error_desc = "no output";
			if (stage_result.get_type() == Variant::DICTIONARY) {
				error_desc = String(Dictionary(stage_result).get("error", "unknown error"));
			}
			WARN_PRINT(vformat("Shader baker: WGSL translation failed for shader '%s' stage %d (%s); baking SPIR-V only for it.", String(shader_name.ptr()), (int)i, error_desc));
		}
	}

	finalize_baked_wgsl();
}

Ref<RenderingShaderContainer> RenderingShaderContainerFormatWebGPUBaked::create_container() const {
	Ref<RenderingShaderContainerWebGPUBaked> container;
	container.instantiate();
	container->set_cli_path(cli_path);
	container->set_wgsl_only(wgsl_only);
	return container;
}

RenderingShaderContainerFormat *ShaderBakerExportPluginPlatformWebGPU::create_shader_container_format(const Ref<EditorExportPlatform> &p_platform, const Ref<EditorExportPreset> &p_preset) {
	// WGSL baking shells out to tint_convert_cli, which must sit beside the
	// editor binary and match the translation pipeline this editor was built
	// with — a stale CLI would bake WGSL that diverges from what the runtime
	// would have produced (the RL-009 failure shape), so a mismatch loudly
	// degrades the bake to SPIR-V-only instead.
	String cli_path = OS::get_singleton()->get_executable_path().get_base_dir().path_join("tint_convert_cli");
	String unavailable_reason;
	if (!FileAccess::exists(cli_path)) {
		unavailable_reason = vformat("'%s' does not exist", cli_path);
	} else {
		String output;
		int exit_code = -1;
		Error err = OS::get_singleton()->execute(cli_path, { "--pipeline-id" }, &output, &exit_code);
		const String cli_id = output.strip_edges();
		if (err != OK || exit_code != 0) {
			unavailable_reason = vformat("'%s --pipeline-id' failed (exit %d)", cli_path, exit_code);
		} else if (cli_id != TINT_BAKE_PIPELINE_ID) {
			unavailable_reason = vformat("'%s' is stale (its pipeline id %s != this editor's %s)", cli_path, cli_id, String(TINT_BAKE_PIPELINE_ID));
		}
	}

	// ⚠ Opt-in, and it removes the runtime's only fallback: a WGSL-only container whose
	// baked text fails to decompress cannot create its shader at all. It is worth roughly
	// half the baked bytes in a pack, so it is a size decision, not a speed one. Only
	// honored when WGSL baking is actually available — a SPIR-V-only bake with its SPIR-V
	// dropped would be an empty container.
	bool wgsl_only = GLOBAL_DEF("rendering/rendering_device/webgpu_wgsl_only_containers", false);

	if (!unavailable_reason.is_empty()) {
		WARN_PRINT(vformat("Shader baker: baking SPIR-V only, without WGSL — %s. Rebuild the CLI with drivers/webgpu/tint_cli/build.sh to bake WGSL and remove runtime shader translation.", unavailable_reason));
		cli_path = String();
		cache_key_suffix = "spv";
		if (wgsl_only) {
			WARN_PRINT("Shader baker: 'rendering/rendering_device/webgpu_wgsl_only_containers' is on but WGSL baking is unavailable; keeping the SPIR-V (a container with neither would be empty).");
			wgsl_only = false;
		}
	} else {
		cache_key_suffix = "wgsl-" + String(TINT_BAKE_PIPELINE_ID);
		if (wgsl_only) {
			// ⚠ Part of the cache key, not just a flag: the export platform caches
			// customized resources by a per-plugin hash and never re-validates them, so a
			// shared key would serve a SPIR-V-carrying container to a WGSL-only export or
			// the reverse, forever and silently.
			cache_key_suffix += "-wgslonly";
		}
		print_line(vformat("Shader baker: baking WGSL with %s (pipeline id %s)%s.", cli_path, String(TINT_BAKE_PIPELINE_ID), wgsl_only ? String(", WGSL only (SPIR-V dropped)") : String()));
	}

	return memnew(RenderingShaderContainerFormatWebGPUBaked(cli_path, wgsl_only));
}

bool ShaderBakerExportPluginPlatformWebGPU::matches_driver(const String &p_driver) {
	return p_driver == "webgpu";
}
