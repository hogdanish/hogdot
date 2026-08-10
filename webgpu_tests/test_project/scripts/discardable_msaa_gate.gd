## Discardable-flag MSAA gate — the ghost-trail probe.
##
## Godot 4.7's "discardable" rework changes render-pass load/store ops, not texture usage
## bits. Two sites reach a WebGPU frame. The root viewport's `color_multisample` resolve
## source is new in 4.7 and sits in a single-subpass pass, so the driver really does emit
## `WGPUStoreOp_Discard` there. The `RB_TEX_COLOR_MSAA` / `RB_TEX_DEPTH_MSAA` pair is
## pre-existing and is what fork commit 653e1e9878 fixed, by forcing `Store` on every
## attachment of a multi-subpass pass. No other gate reaches either one: `project.godot`
## keeps `msaa_2d` and `msaa_3d` at 0, and this scene deliberately leaves that alone and
## raises MSAA on its own Viewport instead.
##
## ⚠ This script cannot decide the result. The bug 653e1e9878 fixed emitted zero errors of
## any kind — it was a stale MSAA read, visible only as a trailing ghost behind a moving
## transparent object. All this script does is put that probe on screen on a fixed,
## repeatable path and confirm MSAA was really enabled. A human eye or a screenshot pair
## judges the ghost; a silent console is necessary but not sufficient.
##
## ⚠ No TAA, no FSR2, no glow, no SSAO, no fog. Each of those smears or ghosts on its own
## and would be indistinguishable from the artifact being hunted.
##
## The moving object is a Label3D with `alpha_cut` disabled, so it stays in the transparent
## pass. That is the fork author's own repro case, not a stand-in.

extends Node3D

const FRAMES_TO_RENDER := 10
const FLOOR_SIZE := Vector3(48.0, 0.5, 30.0)
const PROP_COUNT := 9
const PROP_SPAN := 14.0
const PROP_Z := -4.0
const LABEL_HEIGHT := 1.1
const TRAVERSAL_AMPLITUDE := 10.0
const TRAVERSAL_PERIOD := 4.0

var frame_count := 0
var _hold := false
var _reported := false
var _elapsed := 0.0
var _label: Label3D = null


## Whether to keep the scene on screen after reporting instead of quitting.
## Pass `?hold` in the URL on web, or `-- --hold` natively.
func _wants_hold() -> bool:
	if "--hold" in OS.get_cmdline_user_args():
		return true
	if OS.has_feature("web"):
		# ⚠ Ask for a number, not a boolean. `JavaScriptBridge.eval` hands a JS `true`
		# back as a Variant of type FLOAT, so a `typeof(res) == TYPE_BOOL` guard
		# silently rejects every hold request.
		var res: Variant = JavaScriptBridge.eval(
			"location.search.indexOf('hold') >= 0 ? 1 : 0", true
		)
		return res != null and bool(res)
	return false


func _ready() -> void:
	_hold = _wants_hold()
	print("[DiscardableGate] Building the MSAA discardable gate scene...")

	_setup_viewport_msaa()
	_setup_environment()
	_setup_camera()
	_setup_light()
	_setup_floor()
	_setup_props()
	_setup_label()

	print("[DiscardableGate] Scene built. Rendering %d frames..." % FRAMES_TO_RENDER)


func _process(delta: float) -> void:
	_elapsed += delta
	_move_label()

	# ⚠ Unlike `shader_coverage.gd`, holding does NOT stop `_process`. The animation is the
	# whole gate, so the label has to keep crossing after the report is printed.
	if _reported:
		return

	frame_count += 1
	if frame_count < FRAMES_TO_RENDER:
		return

	_reported = true
	var ok := _report()
	if _hold:
		print("[DiscardableGate] Holding — the label keeps crossing for screenshots.")
		return
	get_tree().quit(0 if ok else 1)


# ═══════════════════════════════════════════════════════════════════════════════
# VIEWPORT — MSAA on, per-Viewport, at runtime
# ═══════════════════════════════════════════════════════════════════════════════


## ⚠ Never move this into `project.godot`. Flipping the project settings would put every
## other gate scene on a different rendering path and invalidate their "no new errors
## versus vanilla" comparisons from that point on.
func _setup_viewport_msaa() -> void:
	var viewport := get_viewport()
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.msaa_2d = Viewport.MSAA_4X
	print("  [OK] Viewport MSAA: msaa_3d=%d msaa_2d=%d" % [viewport.msaa_3d, viewport.msaa_2d])


# ═══════════════════════════════════════════════════════════════════════════════
# SCENE — flat background, one light, opaque floor and props, moving Label3D
# ═══════════════════════════════════════════════════════════════════════════════


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.35, 0.42)
	env.ambient_light_energy = 0.6

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	print("  [OK] Environment: flat color background, ambient only, no post-processing")


## ⚠ `look_at` runs after `add_child`, not before. Outside the tree it fails with
## "Node not inside tree", leaving the camera at its default -Z heading — an error that
## scrolls past in the boot log while the framing is silently wrong.
func _setup_camera() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 4.0, 13.0)
	camera.near = 0.1
	camera.far = 200.0
	camera.current = true
	add_child(camera)
	camera.look_at(Vector3(0.0, 1.2, PROP_Z + 2.0))

	print("  [OK] Camera: frames the floor and the label's whole traversal path")


func _setup_light() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	light.light_color = Color(1.0, 0.97, 0.92)
	light.light_energy = 1.4
	light.shadow_enabled = true
	add_child(light)

	print("  [OK] Light: one shadow-casting DirectionalLight3D")


func _setup_floor() -> void:
	var mesh := BoxMesh.new()
	mesh.size = FLOOR_SIZE

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.35, 0.39)
	mat.roughness = 0.85
	mat.metallic = 0.0

	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	inst.position = Vector3(0.0, -FLOOR_SIZE.y * 0.5, 0.0)
	add_child(inst)

	print("  [OK] Floor: opaque %dx%d box" % [int(FLOOR_SIZE.x), int(FLOOR_SIZE.z)])


## Opaque pillars behind the label's path, in alternating colors. The label crosses all of
## them, so a stale-MSAA trail shows up against several different backgrounds in one pass
## instead of only against the flat floor.
func _setup_props() -> void:
	for i in PROP_COUNT:
		var t := float(i) / float(PROP_COUNT - 1)
		var height := 3.0 + 1.5 * sin(float(i))

		var mesh := BoxMesh.new()
		mesh.size = Vector3(1.6, height, 1.6)

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.15 + 0.7 * t, 0.22, 0.78 - 0.6 * t)
		mat.roughness = 0.6

		var inst := MeshInstance3D.new()
		inst.mesh = mesh
		inst.material_override = mat
		inst.position = Vector3(lerpf(-PROP_SPAN, PROP_SPAN, t), height * 0.5, PROP_Z)
		add_child(inst)

	print("  [OK] Props: %d opaque pillars behind the label's path" % PROP_COUNT)


## ⚠ `alpha_cut` stays DISABLED and `modulate` stays below full alpha. Either an alpha
## scissor or an opaque prepass would move the label out of the transparent pass, and the
## transparent pass is the second subpass whose stale load was the whole bug.
func _setup_label() -> void:
	var label := Label3D.new()
	label.text = "DISCARDABLE GATE"
	label.font_size = 96
	label.pixel_size = 0.008
	label.modulate = Color(1.0, 0.94, 0.25, 0.85)
	label.outline_size = 16
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.9)
	label.alpha_cut = Label3D.ALPHA_CUT_DISABLED
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.shaded = false
	label.no_depth_test = false
	label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	label.position = Vector3(0.0, LABEL_HEIGHT, 0.0)
	add_child(label)
	_label = label

	print(
		(
			"  [OK] Label3D: transparent, +/-%.0f units every %.0fs"
			% [TRAVERSAL_AMPLITUDE, TRAVERSAL_PERIOD]
		)
	)


func _move_label() -> void:
	if _label == null:
		return
	var phase := TAU * _elapsed / TRAVERSAL_PERIOD
	_label.position = Vector3(sin(phase) * TRAVERSAL_AMPLITUDE, LABEL_HEIGHT, 0.0)


# ═══════════════════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════════════════


## Prints exactly one `[DISCARDABLE_GATE]` line, so a console capture can grep for that
## prefix and get a single machine-readable record. PASS here means only "MSAA was really
## enabled and the scene rendered its frames" — it says nothing about ghosting.
func _report() -> bool:
	var viewport := get_viewport()
	var msaa_3d: int = viewport.msaa_3d
	var msaa_2d: int = viewport.msaa_2d
	var ok := msaa_3d == Viewport.MSAA_4X and msaa_2d == Viewport.MSAA_4X
	print(
		(
			"[DISCARDABLE_GATE] %s msaa_3d=%d msaa_2d=%d expected=%d frames=%d hold=%s"
			% [
				"PASS" if ok else "FAIL",
				msaa_3d,
				msaa_2d,
				Viewport.MSAA_4X,
				frame_count,
				str(_hold),
			]
		)
	)
	return ok
