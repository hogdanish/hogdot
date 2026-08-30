/**************************************************************************/
/*  shader_baker_export_plugin.h                                          */
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

#include "core/object/object.h"
#include "core/object/worker_thread_pool.h"
#include "core/os/condition_variable.h"
#include "core/templates/rb_set.h"
#include "editor/export/editor_export_plugin.h"

class ShaderRD;
class RenderingShaderContainerFormat;

class ShaderBakerExportPluginPlatform : public RefCounted {
	GDCLASS(ShaderBakerExportPluginPlatform, RefCounted);

public:
	virtual RenderingShaderContainerFormat *create_shader_container_format(const Ref<EditorExportPlatform> &p_platform, const Ref<EditorExportPreset> &p_preset) = 0;
	virtual bool matches_driver(const String &p_driver) = 0;

	// Whether this export target's rendering driver can ever report
	// RD::SUPPORTS_HALF_FLOAT. Answered by the platform rather than compared against a
	// driver name at the call site, so the baker's view and the driver's own
	// has_feature() cannot drift apart. True for every driver but one, hence the
	// default — see ShaderBakerExportPluginPlatformWebGPU.
	virtual bool supports_half_float() const { return true; }

	virtual ~ShaderBakerExportPluginPlatform() {}
};

class ShaderBakerExportPlugin : public EditorExportPlugin {
	GDSOFTCLASS(ShaderBakerExportPlugin, EditorExportPlugin);

protected:
	struct WorkItem {
		String cache_path;
		String shader_name;
		Vector<String> stage_sources;
		Vector<uint64_t> dynamic_buffers;
		int64_t variant = 0;
	};

	struct WorkResult {
		// Since this result is per group, this vector will have gaps in the data it covers as the indices must stay relative to all variants.
		Vector<PackedByteArray> variant_data;
	};

	struct ShaderGroupItem {
		String cache_path;
		LocalVector<int> variants;
		LocalVector<WorkerThreadPool::TaskID> variant_tasks;
	};

	String shader_cache_platform_name;
	String shader_cache_renderer_name;
	String shader_cache_export_path;
	RBSet<String> shader_paths_processed;
	// The `<shader name>/<group sha256>` directories of every group skipped this export.
	// ⚠ Skipping the bake is not enough on its own: `file_cache` is an append-only
	// ledger of everything ever baked into this export path, and _end_customize_resources()
	// re-packs any listed file it did not bake this run straight off disk — so a group
	// dropped here would keep shipping from the previous export's leftovers forever.
	// Matching on the group directory (not the per-version file) also covers versions
	// that existed in an earlier export and no longer do.
	RBSet<String> shader_group_dirs_excluded;
	HashMap<String, WorkResult> shader_work_results;
	Mutex shader_work_results_mutex;
	LocalVector<ShaderGroupItem> shader_group_items;
	RenderingShaderContainerFormat *shader_container_format = nullptr;
	String shader_container_driver;
	// The matched platform's answer, captured in _initialize_container_format() because
	// the feature block that reads it runs later in _begin_customize_resources().
	bool shader_container_half_float = true;
	Vector<Ref<ShaderBakerExportPluginPlatform>> platforms;
	uint64_t customization_configuration_hash = 0;
	uint32_t tasks_processed = 0;
	uint32_t tasks_total = 0;
	std::atomic<bool> tasks_cancelled;
	BinaryMutex tasks_mutex;
	ConditionVariable tasks_condition;

	virtual String get_name() const override;
	virtual bool _is_active(const Vector<String> &p_features) const;
	virtual bool _initialize_container_format(const Ref<EditorExportPlatform> &p_platform, const Ref<EditorExportPreset> &p_preset);
	String _get_registered_platform_drivers() const;
	bool _is_shader_path_excluded(const String &p_cache_path) const;
	virtual void _cleanup_container_format();
	virtual bool _initialize_cache_directory();
	virtual bool _begin_customize_resources(const Ref<EditorExportPlatform> &p_platform, const Vector<String> &p_features) override;
	virtual bool _begin_customize_scenes(const Ref<EditorExportPlatform> &p_platform, const Vector<String> &p_features) override;
	virtual void _end_customize_resources() override;
	virtual Ref<Resource> _customize_resource(const Ref<Resource> &p_resource, const String &p_path) override;
	virtual Node *_customize_scene(Node *p_root, const String &p_path) override;
	virtual uint64_t _get_customization_configuration_hash() const override;
	virtual void _customize_shader_version(ShaderRD *p_shader, RID p_version);
	void _process_work_item(WorkItem p_work_item);

public:
	ShaderBakerExportPlugin();
	virtual ~ShaderBakerExportPlugin() override;
	void add_platform(Ref<ShaderBakerExportPluginPlatform> p_platform);
	void remove_platform(Ref<ShaderBakerExportPluginPlatform> p_platform);
};
