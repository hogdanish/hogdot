## Clearcoat x area-light gate -- the combination that reaches `ltc_evaluate_specular` from a
## third static call site.
##
## 4.7 rewrote the clearcoat/reflection block (GH-111464 and its follow-ups) and the port carried
## it at patch-application level only. Two clearcoat paths exist and they are not equally proven:
##
##   reflection-probe clearcoat  scene_forward_mobile.glsl, samples radiance_octmap, no LTC.
##                               Already live on WebGPU -- shader_coverage.gd has rendered a
##                               clearcoat sphere since the first gate run.
##   area-light clearcoat        scene_forward_lights_inc.glsl:1267, `ltc_evaluate_specular` inside
##                               `#ifdef LIGHT_CLEARCOAT_USED`. Never compiled anywhere in this
##                               fork's history: the coverage scene has no AreaLight3D, and
##                               light_culling_stress.tscn has no clearcoat material.
##
## `ltc_evaluate_specular` calls `ltc_evaluate`, which calls
## `fetch_ltc_filtered_texture_with_form_factor` -- the exact function whose called-from-more-than-
## one-site shape triggered RL-023's Tint internal compiler error. Enabling LIGHT_CLEARCOAT_USED on
## a shader that also processes area lights adds a third such site, behind a material `#ifdef` the
## RL-023 repro never turned on. Tint patch 0007 sweeps unreachable functions generally rather than
## by call site, so it *should* cover this; this scene is the measurement that turns "should" into
## an observation.
##
## The scene is two spheres under one AreaLight3D:
##
##   ClearcoatSphere  the same base material with `clearcoat_enabled = true`, near-mirror
##                    (`clearcoat_roughness = 0.05`) so the LTC specular lobe is the dominant
##                    feature rather than a highlight lost in a rough surface.
##   ControlSphere    the same base material, clearcoat off. The A/B control: if BOTH spheres are
##                    wrong the pre-existing area-light path is at fault and this gate is not the
##                    owner; if only the clearcoat sphere is wrong, the defect is in the
##                    clearcoat-specific LTC call site.
##
## A ReflectionProbe keeps the already-proven reflection-probe clearcoat path exercised in the same
## frame, so a regression there cannot hide behind the new path's result.
##
## What to look for: a tight, bright, rectangular specular reflection of the light on the clearcoat
## sphere, positioned where the light is. The control sphere shows the same broad diffuse pool with
## no such second lobe. Identical spheres mean the clearcoat block did not run.
##
## Bounded by default: renders FRAMES_TO_RENDER frames, prints one RESULT line, quits. Pass
## `-- --hold` natively or `?hold` in the URL on web to keep it on screen.

extends Node3D

const FRAMES_TO_RENDER := 10
const REPORT_PREFIX := "[CLEARCOAT_AREALIGHT]"
const NATIVE_CAPTURE_PATH := "user://clearcoat_arealight_native.png"

const SPHERE_RADIUS := 1.1
const CLEARCOAT_POSITION := Vector3(-1.5, 0.0, 0.0)
const CONTROL_POSITION := Vector3(1.5, 0.0, 0.0)
const CAMERA_POSITION := Vector3(0.0, 1.0, 5.5)
const CAMERA_LOOK_AT := Vector3(0.0, 0.0, 0.0)

const LIGHT_POSITION := Vector3(0.0, 3.2, 2.6)
const LIGHT_SIZE := Vector2(2.0, 2.0)
const LIGHT_RANGE := 12.0
const LIGHT_ENERGY := 8.0
const LIGHT_ATTENUATION := 0.0

var _frame_count := 0
var _hold := false
var _errors: Array[String] = []
var _clearcoat_material: StandardMaterial3D = null
var _control_material: StandardMaterial3D = null


## Whether to keep the scene on screen after reporting instead of quitting.
## Pass `?hold` in the URL on web, or `-- --hold` natively.
func _wants_hold() -> bool:
	if "--hold" in OS.get_cmdline_user_args():
		return true
	if OS.has_feature("web"):
		# Ask for a number, not a boolean. `JavaScriptBridge.eval` hands a JS `true` back as a
		# Variant of type FLOAT, so a `typeof(res) == TYPE_BOOL` guard rejects every hold request.
		var res: Variant = JavaScriptBridge.eval(
			"location.search.indexOf('hold') >= 0 ? 1 : 0", true
		)
		return res != null and bool(res)
	return false


func _ready() -> void:
	_hold = _wants_hold()
	print("%s Building the clearcoat x area-light scene..." % REPORT_PREFIX)
	print("%s user_data_dir=%s" % [REPORT_PREFIX, OS.get_user_data_dir()])

	_setup_environment()
	_setup_camera()
	_setup_spheres()
	_setup_light()
	_setup_reflection_probe()
	_check_material_configuration()

	print("%s Scene built. Rendering %d frames..." % [REPORT_PREFIX, FRAMES_TO_RENDER])


func _process(_delta: float) -> void:
	_frame_count += 1
	if _frame_count < FRAMES_TO_RENDER:
		return
	_capture_native_reference()
	_report()
	if _hold:
		print("%s Holding for inspection - the scene keeps rendering." % REPORT_PREFIX)
		set_process(false)
		return
	get_tree().quit(0 if _errors.is_empty() else 1)


# ═══════════════════════════════════════════════════════════════════════════════
# SCENE
# ═══════════════════════════════════════════════════════════════════════════════


## A sky is deliberately kept here, unlike the other gate scenes: the reflection-probe clearcoat
## path samples radiance, and against a black environment it has nothing to reflect and cannot be
## judged at all. Glow and DOF stay off -- both would blur the specular lobe under test.
func _setup_environment() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.16, 0.26, 0.5)
	sky_material.sky_horizon_color = Color(0.5, 0.58, 0.72)
	sky_material.ground_bottom_color = Color(0.09, 0.08, 0.07)
	sky_material.ground_horizon_color = Color(0.3, 0.28, 0.26)

	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	var env := Environment.new()
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.35
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = false

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	print("  [OK] Environment: procedural sky for radiance, ACES tonemap, no glow, no DOF")


func _setup_camera() -> void:
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.current = true
	add_child(camera)
	# look_at() works in global space, so the node has to be in the tree before it is called.
	camera.position = CAMERA_POSITION
	camera.look_at(CAMERA_LOOK_AT)

	get_viewport().use_taa = false

	print("  [OK] Camera: both spheres in frame, TAA off")


## Two spheres, one material difference. Everything else -- albedo, metallic, roughness, mesh,
## radius -- is identical, so any difference in the render is attributable to the clearcoat block
## and to nothing else.
func _setup_spheres() -> void:
	_clearcoat_material = _make_base_material()
	_clearcoat_material.clearcoat_enabled = true
	_clearcoat_material.clearcoat = 1.0
	_clearcoat_material.clearcoat_roughness = 0.05

	_control_material = _make_base_material()
	_control_material.clearcoat_enabled = false

	_add_sphere("ClearcoatSphere", CLEARCOAT_POSITION, _clearcoat_material)
	_add_sphere("ControlSphere", CONTROL_POSITION, _control_material)

	print("  [OK] Two spheres: clearcoat on (roughness 0.05) and the clearcoat-off control")


func _make_base_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.85, 0.1, 0.1)
	material.metallic = 0.0
	material.roughness = 0.35
	return material


func _add_sphere(p_name: String, p_position: Vector3, p_material: StandardMaterial3D) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = SPHERE_RADIUS
	mesh.height = SPHERE_RADIUS * 2.0
	mesh.radial_segments = 64
	mesh.rings = 32

	var instance := MeshInstance3D.new()
	instance.name = p_name
	instance.mesh = mesh
	instance.material_override = p_material
	instance.position = p_position
	add_child(instance)


## The one node that makes the shader variant under test exist. Light leaves an AreaLight3D along
## its local -Z; -50 degrees about X aims it down at the spheres from above and in front, so its
## rectangular reflection lands on the upper front of each sphere where the camera sees it.
func _setup_light() -> void:
	var light := AreaLight3D.new()
	light.name = "AreaLight"
	light.position = LIGHT_POSITION
	light.rotation_degrees = Vector3(-50.0, 0.0, 0.0)
	light.light_color = Color(1.0, 0.97, 0.92)
	light.light_energy = LIGHT_ENERGY
	light.area_size = LIGHT_SIZE
	light.area_range = LIGHT_RANGE
	light.area_attenuation = LIGHT_ATTENUATION
	# Shadows stay off: the area-light shadow path has its own gate (area_lights_coverage.gd) and
	# a shadow pass here would only add an unrelated failure mode to a shader-translation test.
	light.shadow_enabled = false
	add_child(light)

	print(
		(
			"  [OK] AreaLight3D %.0fx%.0f at energy %.0f -- the LIGHT_CLEARCOAT_USED trigger"
			% [LIGHT_SIZE.x, LIGHT_SIZE.y, LIGHT_ENERGY]
		)
	)


## Keeps the already-proven reflection-probe clearcoat path in the same frame as the new one, so
## the render distinguishes "the clearcoat block broke" from "the area-light call site broke".
func _setup_reflection_probe() -> void:
	var probe := ReflectionProbe.new()
	probe.name = "ReflectionProbe"
	probe.update_mode = ReflectionProbe.UPDATE_ALWAYS
	probe.box_projection = true
	probe.size = Vector3(12.0, 8.0, 12.0)
	probe.position = Vector3(0.0, 1.0, 0.0)
	add_child(probe)

	print("  [OK] ReflectionProbe (UPDATE_ALWAYS, box projection) over both spheres")


## Guards against a silently vacuous pass. If the clearcoat feature flag ever stops sticking, the
## scene would render two identical spheres, no shader variant under test would be compiled, and
## every error-count criterion would still be met.
func _check_material_configuration() -> void:
	if not _clearcoat_material.clearcoat_enabled:
		var message := "clearcoat_enabled did not stick on the test material"
		_errors.append(message)
		push_error("%s %s" % [REPORT_PREFIX, message])
	if _control_material.clearcoat_enabled:
		var message := "the control material has clearcoat enabled -- there is no A/B left"
		_errors.append(message)
		push_error("%s %s" % [REPORT_PREFIX, message])


# ═══════════════════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════════════════


## Native only -- a direct RD readback. The web side is captured with the browser tab screenshot.
func _capture_native_reference() -> void:
	if OS.has_feature("web"):
		return

	var image := get_viewport().get_texture().get_image()
	if image == null:
		_errors.append("viewport readback returned no image")
		return

	var status := image.save_png(NATIVE_CAPTURE_PATH)
	if status != OK:
		_errors.append("save_png(%s) failed with error %d" % [NATIVE_CAPTURE_PATH, status])
		return

	print("%s Wrote the native reference to %s" % [REPORT_PREFIX, NATIVE_CAPTURE_PATH])


func _report() -> void:
	var visible_instances := RenderingServer.viewport_get_render_info(
		get_viewport().get_viewport_rid(),
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
	)
	if visible_instances == 0:
		_errors.append("render info reported 0 visible instances")

	var fields := PackedStringArray()
	fields.append("frames=%d" % _frame_count)
	fields.append("method=%s" % RenderingServer.get_current_rendering_method())
	fields.append("driver=%s" % RenderingServer.get_current_rendering_driver_name())
	fields.append("clearcoat=%s" % ("true" if _clearcoat_material.clearcoat_enabled else "false"))
	fields.append(
		"control_clearcoat=%s" % ("true" if _control_material.clearcoat_enabled else "false")
	)
	fields.append("area_lights=1")
	fields.append("instances=%d" % visible_instances)
	fields.append("pass=%s" % ("true" if _errors.is_empty() else "false"))

	print("%s RESULT %s" % [REPORT_PREFIX, " ".join(fields)])
	for error in _errors:
		print("%s ERROR %s" % [REPORT_PREFIX, error])
