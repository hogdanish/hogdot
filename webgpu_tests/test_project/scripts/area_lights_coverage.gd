## Area-light shadow gate -- the first AreaLight3D scene in this project that casts shadows.
##
## `light_culling_stress.tscn` already renders area lights and proved the RL-046 batch predicate,
## but every light in it sets `shadow_enabled = false`: the shadow atlas, the LTC texture path and
## the shadow-pass merge have never been reached by an area light on either backend. This scene
## reaches all three.
##
## Three shadow-casting AreaLight3D nodes stand over one ground plane and three props of differing
## height:
##
##   L0  untextured, warm      -- the plain `ltc_evaluate` path
##   L1  textured, white       -- `fetch_ltc_filtered_texture_with_form_factor`, the function
##                               RL-023's vendored Tint patch was written for
##   L2  untextured, cyan      -- a third shadow pass, so a merged run is 3 passes long, not 2
##
## A fourth prop nearer the camera is lit by a shadow-casting SpotLight3D, the control: an old,
## well-exercised light type whose shadows this backend has always drawn. It is what separates
## "this backend draws no shadows" from "this backend draws no AREA-light shadows".
##
## All four lights are positional, so all four shadow passes land in the one shadow atlas
## framebuffer back to back -- the precondition `_render_shadow_end()`'s merge needs before it can
## collapse anything. That is what makes this scene the RL-010 experiment's measuring instrument:
## run it with `--verbose` and read the engine's `Shadow Render: N passes in M draw lists` line.
## With the exclusion in place the area passes stay unmerged; with it lifted they collapse.
##
## ⚠ The script cannot read that number itself. Forward-mobile fills
## VIEWPORT_RENDER_INFO_TYPE_SHADOW's draw-call slot with the last shadow pass's instance count
## (`render_forward_mobile.cpp:1629`), not with issued draw lists, so no RenderingServer counter
## observes the merge. The RESULT line below reports the atlas configuration and the shadow-pass
## count this scene *builds*; the merge itself is read from the engine's verbose line.
##
## What to look for in the render, in order of what each failure means:
##
##   - The two control shadows first: the spot control's hard shadow beside PropControl, and the
##     directional control's long shadows off every prop. If both are missing, nothing below is
##     about area lights. If only the spot's is missing, the positional shadow atlas is at fault.
##   - Three more distinct shadows on the ground, one per area light. A missing shadow means the
##     area-light shadow atlas path did not run for that light.
##   - L1's pool is tinted green on one side and magenta on the other, from its green/magenta
##     emitter texture. A plain white L1 pool means the area-texture path silently fell back to
##     the untextured one.
##   - Shadow edges are soft and get softer with distance from the caster. ⚠ On Mobile the
##     penumbra does NOT widen correctly with PCSS (doc/classes/AreaLight3D.xml:10) -- that is a
##     pre-existing Godot limitation, present natively too, and is not a WebGPU defect.
##
## Bounded by default: renders FRAMES_TO_RENDER frames, prints one RESULT line, quits. Pass
## `-- --hold` natively or `?hold` in the URL on web to keep it on screen instead. On native only
## it also writes NATIVE_CAPTURE_PATH, the reference image for the native-vs-web comparison; the
## web side is captured with the browser's own tab screenshot, never with `getImageData`.

extends Node3D

const FRAMES_TO_RENDER := 10
const REPORT_PREFIX := "[AREA_LIGHTS]"
const NATIVE_CAPTURE_PATH := "user://area_lights_native.png"

## 128 is a multiple of 128 in both dimensions, which is the size class AreaLight3D documents as
## needing no scaling pass when it uploads into the area-light atlas.
const AREA_TEXTURE_SIZE := 128

const GROUND_SIZE := 24.0
const CAMERA_POSITION := Vector3(0.0, 7.5, 13.0)
const CAMERA_LOOK_AT := Vector3(0.0, 1.0, 0.0)

const LIGHT_HEIGHT := 5.0
const LIGHT_RANGE := 14.0
## Tuned down from a first pass at 6.0, which saturated all three pools of light to flat white and
## made the textured light indistinguishable from the two untextured ones -- the exact comparison
## this scene exists to make.
const LIGHT_ENERGY := 2.0
## 0.0 holds near-full brightness across the range and only rolls off at its edge, which keeps the
## three pools of light readable against each other instead of collapsing into the floor.
const LIGHT_ATTENUATION := 0.0
const LIGHT_SIZE := Vector2(2.5, 2.5)

const COLOR_WARM := Color(1.0, 0.86, 0.7)
const COLOR_WHITE := Color(1.0, 1.0, 1.0)
const COLOR_CYAN := Color(0.45, 0.9, 1.0)

## The control light: a shadow-casting SpotLight3D over a fourth prop nearer the camera. It is the
## difference between "this backend renders no shadows" and "this backend renders no AREA-light
## shadows", and the first browser run of this scene needed exactly that distinction.
const CONTROL_PROP_POSITION := Vector3(0.0, 1.1, 6.5)
const CONTROL_LIGHT_POSITION := Vector3(-3.5, 5.5, 8.5)
const CONTROL_LIGHT_ENERGY := 3.0
const CONTROL_LIGHT_RANGE := 16.0
const CONTROL_LIGHT_ANGLE := 30.0

## The second control. Directional shadows live in their own PSSM texture and take a different
## sampling path from the positional shadow atlas, so running both control types splits the answer
## three ways instead of two: no shadow anywhere, only the atlas path dead, or only area lights.
## Its energy stays low and its colour pale, so it reads as a separate long shadow rather than
## washing out the three area-light pools this scene is otherwise about.
const DIRECTIONAL_ENERGY := 0.55
const DIRECTIONAL_ROTATION := Vector3(-38.0, 35.0, 0.0)

var _frame_count := 0
var _hold := false
var _errors: Array[String] = []
var _lights: Array[AreaLight3D] = []
var _textured_light_count := 0
var _prop_count := 0


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
	print("%s Building the area-light shadow scene..." % REPORT_PREFIX)
	# Printed, never assumed: the user:// mapping is machine and version dependent, and the
	# native-vs-web comparison needs the real path of the capture written below.
	print("%s user_data_dir=%s" % [REPORT_PREFIX, OS.get_user_data_dir()])

	_setup_environment()
	_setup_camera()
	_setup_ground_and_props()
	_setup_lights()

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


## No sky, no glow, no DOF and no CameraAttributes. Every one of those mixes light into the scene
## from somewhere other than the three lights under test, and the native-vs-web comparison this
## scene exists for cannot attribute a difference it cannot isolate.
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.015, 0.025)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.65)
	env.ambient_light_energy = 0.06
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.glow_enabled = false

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	print("  [OK] Environment: flat background, faint ambient fill, no glow, no DOF, no sky")


func _setup_camera() -> void:
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.current = true
	add_child(camera)
	# ⚠ look_at() needs the node inside the tree: it works in global space and a detached node has
	# no global transform. The main coverage scene carried this bug for the whole port.
	camera.position = CAMERA_POSITION
	camera.look_at(CAMERA_LOOK_AT)

	# TAA blends neighbouring frames, which would smear both the captured reference and the
	# soft shadow edges this scene is judged on.
	get_viewport().use_taa = false
	_apply_debug_draw()

	print("  [OK] Camera: raised and angled down at the ground, TAA off")


## `?debug=atlas` draws the positional shadow atlas over the frame, `?debug=directional` the PSSM
## texture (`-- --debug=atlas` natively). A missing shadow has two very different causes -- the
## atlas was never written, or it was written and sampled wrong -- and nothing else in reach of a
## script tells the two apart. This is how the first web run of this scene was diagnosed.
func _apply_debug_draw() -> void:
	var wanted := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--debug="):
			wanted = arg.trim_prefix("--debug=")
	if wanted == "" and OS.has_feature("web"):
		var res: Variant = JavaScriptBridge.eval(
			"new URLSearchParams(location.search).get('debug') || ''", true
		)
		if res != null:
			wanted = String(res)

	match wanted:
		"":
			return
		"atlas":
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_SHADOW_ATLAS
		"directional":
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_DIRECTIONAL_SHADOW_ATLAS
		_:
			_errors.append("unknown debug view '%s'" % wanted)
			return

	print("  [OK] Debug draw: %s" % wanted)


## A large matte ground plane plus three props of differing height, so each light's shadow lands on
## a flat receiver and the penumbra has room to be judged.
func _setup_ground_and_props() -> void:
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.72, 0.72, 0.75)
	ground_material.roughness = 0.95
	ground_material.metallic = 0.0

	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(GROUND_SIZE, GROUND_SIZE)

	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = ground_mesh
	ground.material_override = ground_material
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)

	var prop_material := StandardMaterial3D.new()
	prop_material.albedo_color = Color(0.85, 0.83, 0.8)
	prop_material.roughness = 0.6
	prop_material.metallic = 0.0

	_add_prop("PropLeft", Vector3(-7.0, 1.1, 0.0), 2.2, prop_material)
	_add_prop("PropCenter", Vector3(0.0, 1.6, 0.5), 3.2, prop_material)
	_add_prop("PropRight", Vector3(7.0, 0.8, -0.5), 1.6, prop_material)
	_add_prop("PropControl", CONTROL_PROP_POSITION, 2.2, prop_material)

	print(
		(
			"  [OK] Ground plane %.0fx%.0f and %d shadow-casting props"
			% [GROUND_SIZE, GROUND_SIZE, _prop_count]
		)
	)


func _add_prop(
	p_name: String, p_position: Vector3, p_height: float, p_material: StandardMaterial3D
) -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.4, p_height, 1.4)
	# Subdivision matters here: AreaLight3D documents that a low-poly caster very close to the
	# light produces wrong-looking shadows, and these props sit under the lights.
	mesh.subdivide_width = 2
	mesh.subdivide_height = 2
	mesh.subdivide_depth = 2

	var prop := MeshInstance3D.new()
	prop.name = p_name
	prop.mesh = mesh
	prop.material_override = p_material
	prop.position = p_position
	prop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(prop)
	_prop_count += 1


# ═══════════════════════════════════════════════════════════════════════════════
# LIGHTS
# ═══════════════════════════════════════════════════════════════════════════════


## Three shadow-casting area lights, one per prop. All three are positional, so their shadow
## passes share the one shadow-atlas framebuffer and land back to back -- the merge precondition.
## Only L1 carries an area texture; L0 and L2 take the uniform-emitter path, which makes the
## texture's effect on L1 a within-frame comparison rather than a between-run one.
func _setup_lights() -> void:
	_add_area_light("AreaL0", Vector3(-7.0, LIGHT_HEIGHT, 1.5), COLOR_WARM, null)
	_add_area_light(
		"AreaL1", Vector3(0.0, LIGHT_HEIGHT, 2.0), COLOR_WHITE, _generate_area_texture()
	)
	_add_area_light("AreaL2", Vector3(7.0, LIGHT_HEIGHT, 1.5), COLOR_CYAN, null)
	_add_control_spot_light()
	_add_control_directional_light()

	print(
		(
			"  [OK] %d shadow-casting area lights (%d textured) + spot and directional controls"
			% [_lights.size(), _textured_light_count]
		)
	)


## Light leaves an AreaLight3D along its local -Z, so an unrotated light shines at the camera.
## -75 degrees about X aims it down and slightly forward, onto the props and the ground behind them.
func _add_area_light(
	p_name: String, p_position: Vector3, p_color: Color, p_texture: Texture2D
) -> void:
	var light := AreaLight3D.new()
	light.name = p_name
	light.position = p_position
	light.rotation_degrees = Vector3(-75.0, 0.0, 0.0)
	light.light_color = p_color
	light.light_energy = LIGHT_ENERGY
	light.area_size = LIGHT_SIZE
	light.area_range = LIGHT_RANGE
	light.area_attenuation = LIGHT_ATTENUATION
	light.shadow_enabled = true
	light.shadow_bias = 0.05
	if p_texture != null:
		light.area_texture = p_texture
		_textured_light_count += 1
	add_child(light)
	_lights.append(light)


## The control. A SpotLight3D is an old, well-exercised light type whose shadows this backend has
## rendered since the first gate run, so its shadow under PropControl answers the one question the
## three area lights cannot answer about themselves: whether the backend draws shadows at all. A
## frame with the control's shadow present and the three area shadows absent is a defect in the
## area-light shadow path; a frame with no shadow anywhere is a defect in the shadow path.
func _add_control_spot_light() -> void:
	var light := SpotLight3D.new()
	light.name = "SpotControl"
	light.light_color = Color(1.0, 0.98, 0.95)
	light.light_energy = CONTROL_LIGHT_ENERGY
	light.spot_range = CONTROL_LIGHT_RANGE
	light.spot_angle = CONTROL_LIGHT_ANGLE
	# Unlike the area lights, the control gets a real inverse falloff: at attenuation 0.0 its pool
	# saturated to flat white and swallowed the very shadow it exists to show.
	light.spot_attenuation = 1.0
	light.shadow_enabled = true
	light.shadow_bias = 0.05
	add_child(light)
	# look_at() is global-space, so it only works once the node is in the tree.
	light.position = CONTROL_LIGHT_POSITION
	light.look_at(CONTROL_PROP_POSITION)


## The second control. A DirectionalLight3D writes into the PSSM directional shadow texture, not
## the positional shadow atlas the other four lights share, and the fragment shader samples the two
## through different code. Present-vs-absent across the two control types localises a missing
## shadow to one of those paths without any engine instrumentation.
func _add_control_directional_light() -> void:
	var light := DirectionalLight3D.new()
	light.name = "DirectionalControl"
	light.rotation_degrees = DIRECTIONAL_ROTATION
	light.light_color = Color(1.0, 0.98, 0.9)
	light.light_energy = DIRECTIONAL_ENERGY
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	add_child(light)


## A hard green/magenta vertical split, chosen for one reason: the tell has to survive the LTC
## filter. `fetch_ltc_filtered_texture_with_form_factor` integrates the texture over the light's
## solid angle, so any fine pattern -- a cross, noise -- averages into a flat pool that looks
## exactly like the untextured path. Two saturated hues cannot average into the light's own white:
## L1's pool is green-and-magenta if the texture was sampled and plain white if it was not.
func _generate_area_texture() -> ImageTexture:
	var image := Image.create_empty(AREA_TEXTURE_SIZE, AREA_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)

	var half := AREA_TEXTURE_SIZE / 2
	for y in AREA_TEXTURE_SIZE:
		for x in AREA_TEXTURE_SIZE:
			image.set_pixel(x, y, Color(0.05, 1.0, 0.15) if x < half else Color(1.0, 0.1, 0.8))

	return ImageTexture.create_from_image(image)


# ═══════════════════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════════════════


## The native reference for the native-vs-web comparison. Native only, on purpose: this is a direct
## RD texture readback, and the web backend has no sanctioned canvas readback -- the browser side is
## captured with the tab screenshot instead, never with `getImageData`.
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


## One machine-readable line. The shadow-pass count is what this scene configured; how many draw
## lists the engine collapsed those passes into is only visible in the engine's own verbose
## `Shadow Render` line, per this file's header.
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
	fields.append("area_lights=%d" % _lights.size())
	fields.append("textured=%d" % _textured_light_count)
	fields.append("spot_controls=1")
	fields.append("directional_controls=1")
	fields.append("shadow_passes=%d" % (_lights.size() + 1))
	fields.append("props=%d" % _prop_count)
	fields.append("instances=%d" % visible_instances)
	fields.append("pass=%s" % ("true" if _errors.is_empty() else "false"))

	print("%s RESULT %s" % [REPORT_PREFIX, " ".join(fields)])
	for error in _errors:
		print("%s ERROR %s" % [REPORT_PREFIX, error])
