## User-authored rendering paths — the coverage the gate scene did not have.
##
## ⚠ Everything in this file exists because of one fact: phases 4 through 6 went green
## while three defects sat in paths no gate scene touched, and CommonGrounds found all
## three in its first hour. `shader_coverage.gd` exercises the *engine's own* shaders
## exhaustively; nothing exercised what a project writes itself. These three do:
##
##   - `user_compute.glsl`      an imported RDShaderFile driven through RenderingDevice
##                              from script       → RL-036, RL-038, RL-040
##   - `stencil_write.gdshader` a stencil_mode material on a shadow-casting mesh
##                                                → RL-037
##   - `screen_read.gdshader`   SCREEN_TEXTURE + DEPTH_TEXTURE through the Mobile
##                              renderer's back-buffer copy   → no ledger entry at all
##
## Kept separate from `shader_coverage.gd` so the split stays legible and neither file
## outgrows the lint ceiling. Call `run()` with the scene root; it returns the errors it
## found, for the caller to fold into its own report.

extends RefCounted

const COMPUTE_TEX_SIZE := 64

var _errors: Array[String] = []


## Builds all three gates under `p_root` and returns any errors as messages.
func run(p_root: Node3D) -> Array[String]:
	_errors = []
	_setup_stencil_material(p_root)
	_setup_screen_read(p_root)
	_run_user_compute()
	return _errors


func _fail(p_message: String) -> void:
	_errors.append(p_message)
	push_error("[ShaderCoverage] %s" % p_message)


# ═══════════════════════════════════════════════════════════════════════════════
# STENCIL MATERIAL — gates RL-037 (stencil state on a depth-only attachment)
# ═══════════════════════════════════════════════════════════════════════════════

## Puts a `stencil_mode` material on a shadow-casting mesh.
##
## ⚠ The defect this gates lives in the *shadow-pass* variant, not the colour pass, so
## the mesh must cast shadows into the D16/D32 shadow atlas. `shader_coverage.gd`'s
## `_setup_lights()` supplies three shadow-casting lights; the gate needs all of:
## a declared stencil_mode, a shadow-casting mesh, and a shadow-casting light. Remove
## any one and the shadow-pass variant is never built and this goes green while broken.
func _setup_stencil_material(p_root: Node3D) -> void:
	var shader: Shader = load("res://shaders/stencil_write.gdshader")
	if shader == null:
		_fail("stencil_write.gdshader failed to load")
		return

	var mat := ShaderMaterial.new()
	mat.shader = shader

	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.2, 1.2, 1.2)
	mesh_inst.mesh = box
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(-7, 1.2, -3)
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	p_root.add_child(mesh_inst)

	# A BaseMaterial3D stencil mode as well — the engine reaches stencil state through a
	# different route there (`BaseMaterial3D::_update_shader`) than a hand-written one.
	var outline_mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.6
	sphere.height = 1.2
	outline_mesh.mesh = sphere
	var std_mat := StandardMaterial3D.new()
	std_mat.albedo_color = Color(0.2, 0.9, 0.7)
	std_mat.stencil_mode = BaseMaterial3D.STENCIL_MODE_OUTLINE
	std_mat.stencil_outline_thickness = 0.03
	outline_mesh.material_override = std_mat
	outline_mesh.position = Vector3(-7, 1.2, -5)
	outline_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	p_root.add_child(outline_mesh)

	print("  [OK] Stencil: custom stencil_mode shader + BaseMaterial3D outline, shadow-casting")


# ═══════════════════════════════════════════════════════════════════════════════
# SCREEN READ — gates the back-buffer copy (SCREEN_TEXTURE + DEPTH_TEXTURE)
# ═══════════════════════════════════════════════════════════════════════════════

## Puts an opaque panel reading SCREEN_TEXTURE and DEPTH_TEXTURE in front of the scene.
##
## ⚠ Visual gate only — see the shader's header for how to read it. Nothing here can
## assert on the result: a WebGPU canvas reads back all black under getImageData, and
## there is no synchronous GPU readback on this backend.
##
## ⚠ The backer below is what makes the depth half able to fail. Without it the panel can
## face open sky, where reverse-Z depth is legitimately 0.0 and a driver that hands the
## depth copy a blank texture reads exactly the same thing as one that works. That is how
## WA-18 survived every run of this gate.
func _setup_screen_read(p_root: Node3D) -> void:
	var shader: Shader = load("res://shaders/screen_read.gdshader")
	if shader == null:
		_fail("screen_read.gdshader failed to load")
		return

	var mat := ShaderMaterial.new()
	mat.shader = shader

	var panel := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(3.0, 2.0)
	panel.mesh = quad
	panel.material_override = mat
	# Between the camera (0, 3, 8) and the scene it looks at, so the panel always covers
	# real content and an empty back-buffer copy is unmistakable.
	panel.position = Vector3(0.0, 2.4, 5.0)
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p_root.add_child(panel)

	# Opaque backer, parented to the panel and 0.8 m behind it. The camera sits 3 m in
	# front of the panel, so a quad 0.8 m further away needs to be 3.8 / 3.0 ≈ 1.27× the
	# panel to cover its whole footprint; 4.0 × 2.7 leaves margin for the panel sitting
	# slightly above the view axis. It writes depth, so every texel the panel samples has
	# a non-zero reverse-Z depth when the copy works.
	var backer := MeshInstance3D.new()
	var backer_quad := QuadMesh.new()
	backer_quad.size = Vector2(4.0, 2.7)
	backer.mesh = backer_quad
	# Two flat colors rather than one: the left half of the panel wobbles its sample, and
	# a single flat colour would hide whether the screen copy is live or frozen.
	var backer_mat := StandardMaterial3D.new()
	backer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	backer_mat.albedo_color = Color(1.0, 0.55, 0.0)
	backer.material_override = backer_mat
	backer.position = Vector3(0.0, 0.0, -0.8)
	backer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	panel.add_child(backer)

	var stripe := MeshInstance3D.new()
	var stripe_quad := QuadMesh.new()
	stripe_quad.size = Vector2(0.6, 2.7)
	stripe.mesh = stripe_quad
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	stripe_mat.albedo_color = Color(0.05, 0.05, 0.4)
	stripe.material_override = stripe_mat
	# In front of the backer and behind the panel, so it also gives the depth half two
	# distinct non-zero depths instead of one.
	stripe.position = Vector3(-0.7, 0.0, -0.4)
	stripe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	panel.add_child(stripe)

	print("  [OK] Screen read: SCREEN_TEXTURE + DEPTH_TEXTURE panel over an opaque backer (visual — inspect with ?hold)")


# ═══════════════════════════════════════════════════════════════════════════════
# USER COMPUTE — gates RL-038 / RL-040 (imported RDShaderFile via RenderingDevice)
# ═══════════════════════════════════════════════════════════════════════════════

## Loads an imported `.glsl` and dispatches it through the main RenderingDevice.
##
## ⚠ This must go through the *imported* resource. `load()` on a .glsl returns what the
## editor's importer baked at import time — headless, with no RenderingDevice — and that
## is the artifact a shipped pack carries and the path that was broken. Compiling the
## same source at runtime through `shader_compile_spirv_from_source` would pass while the
## shipped path stayed broken, which is exactly how RL-038 read as fixed when it was not.
func _run_user_compute() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_fail("no RenderingDevice — the RDShaderFile gate could not run")
		return

	var shader_file: RDShaderFile = load("res://shaders/user_compute.glsl")
	if shader_file == null:
		_fail("user_compute.glsl failed to load as an RDShaderFile")
		return

	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if spirv == null:
		_fail("user_compute.glsl has no baked SPIR-V")
		return

	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_error != "":
		_fail("user_compute.glsl compile error: %s" % compile_error)
		return

	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		_fail("shader_create_from_spirv failed for user_compute.glsl")
		return

	_dispatch_user_compute(rd, shader)
	rd.free_rid(shader)


## ⚠ Deliberately no readback. `buffer_get_data()` is a synchronous GPU readback and
## there is none on this backend. The assertion is "the dispatch raised no errors",
## which is what the console capture reads — so run the bounded page, not `?hold`.
func _dispatch_user_compute(p_rd: RenderingDevice, p_shader: RID) -> void:
	var src_tex := _create_compute_texture(p_rd, true)
	var dst_tex := _create_compute_texture(p_rd, false)
	if not src_tex.is_valid() or not dst_tex.is_valid():
		_fail("compute storage textures could not be created")
		return

	# 16 bytes: one atomic counter plus padding, clearing the 16-byte SSBO floor.
	var counter_bytes := PackedByteArray()
	counter_bytes.resize(16)
	var counter_buf := p_rd.storage_buffer_create(counter_bytes.size(), counter_bytes)

	var u_src := RDUniform.new()
	u_src.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_src.binding = 0
	u_src.add_id(src_tex)

	var u_dst := RDUniform.new()
	u_dst.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_dst.binding = 1
	u_dst.add_id(dst_tex)

	var u_counter := RDUniform.new()
	u_counter.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_counter.binding = 2
	u_counter.add_id(counter_buf)

	var uniform_set := p_rd.uniform_set_create([u_src, u_dst, u_counter], p_shader, 0)
	if not uniform_set.is_valid():
		_fail("uniform_set_create failed for user_compute.glsl")
		return

	var pipeline := p_rd.compute_pipeline_create(p_shader)
	if not pipeline.is_valid():
		_fail("compute_pipeline_create failed for user_compute.glsl")
		return

	# vec2 size, float threshold, float pad — 16 bytes, the push-constant alignment floor.
	var push := PackedFloat32Array([float(COMPUTE_TEX_SIZE), float(COMPUTE_TEX_SIZE), 0.5, 0.0])
	var push_bytes := push.to_byte_array()

	var compute_list := p_rd.compute_list_begin()
	p_rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	p_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	p_rd.compute_list_set_push_constant(compute_list, push_bytes, push_bytes.size())
	var groups := COMPUTE_TEX_SIZE / 8
	p_rd.compute_list_dispatch(compute_list, groups, groups, 1)
	p_rd.compute_list_end()

	print("  [OK] User compute: imported RDShaderFile dispatched (%dx%d, %d groups sq.)" % [
		COMPUTE_TEX_SIZE, COMPUTE_TEX_SIZE, groups
	])

	# ⚠ Free what this gate allocated. Without it shutdown reports leaked Compute,
	# UniformSet, StorageBuffer, Shader and Texture RIDs, and those warnings then sit in
	# every future run's log looking like an engine defect rather than this script's.
	# The uniform set is freed first: it references the textures and the buffer.
	p_rd.free_rid(uniform_set)
	p_rd.free_rid(pipeline)
	p_rd.free_rid(counter_buf)
	p_rd.free_rid(dst_tex)
	p_rd.free_rid(src_tex)


func _create_compute_texture(p_rd: RenderingDevice, p_with_data: bool) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	fmt.width = COMPUTE_TEX_SIZE
	fmt.height = COMPUTE_TEX_SIZE
	fmt.depth = 1
	fmt.array_layers = 1
	fmt.mipmaps = 1
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)

	var view := RDTextureView.new()
	if not p_with_data:
		return p_rd.texture_create(fmt, view, [])

	# A gradient, so the shader's threshold branch is taken on some invocations and not
	# others and both sides of the atomic get exercised.
	var texel_count := COMPUTE_TEX_SIZE * COMPUTE_TEX_SIZE
	var data := PackedByteArray()
	data.resize(texel_count * 4 * 2)  # 4 channels x 2 bytes (half float)
	for i in texel_count:
		var v := float(i) / float(texel_count)
		var base := i * 8
		data.encode_half(base + 0, v)
		data.encode_half(base + 2, v)
		data.encode_half(base + 4, v)
		data.encode_half(base + 6, 1.0)

	return p_rd.texture_create(fmt, view, [data])
