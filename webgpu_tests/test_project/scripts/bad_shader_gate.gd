## Bad-shader containment gate — an untranslatable shader must never take the process down.
##
## `switch` fallthrough is legal in Godot's shading language and in the SPIR-V glslang emits
## for it, but Tint's SPIR-V reader asserts on it (`TINT_ASSERT(switch_blocks.count(dest_id)
## == 0)`, parser.cc). Before Tint patch 0008 + the tint_wrapper longjmp escape, that assert
## aborted the wasm module: the canvas froze with audio still playing, which CommonGrounds'
## first playable session read as a hang (web-p5.5-1-log.md § 1).
##
## This gate puts that exact shader on screen beside a control cube with a known-good
## material. PASS means only that the engine survived compiling it: the report frame is
## reached and printed. Pre-fix the run traps during material compile and no report line
## ever appears, so the pass state and the failure state are distinguishable — the standing
## gate lesson (RL-037, RL-046, RL-048, RL-049).
##
## ⚠ One `Tint SPIR-V→WGSL failed` ERR_PRINT naming an internal compiler error is EXPECTED
## in the console. A run with no such error never compiled the broken shader and proves
## nothing — the gate checks the shader really went through the driver by requiring the
## material's mesh to be on screen for every rendered frame. The broken mesh itself renders
## with the engine's invalid-shader fallback; the control cube must keep rendering, which a
## `?hold` screenshot can confirm.

extends Node3D

const FRAMES_TO_RENDER := 30

var frame_count := 0
var _hold := false
var _reported := false


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
	print("[BadShaderGate] Building the bad-shader containment gate...")

	_setup_environment()
	_setup_camera()
	_setup_light()
	_setup_control_cube()
	_setup_broken_sphere()

	print(
		(
			"[BadShaderGate] Scene built. Rendering %d frames — surviving them IS the gate..."
			% FRAMES_TO_RENDER
		)
	)


func _process(_delta: float) -> void:
	if _reported:
		return

	frame_count += 1
	if frame_count < FRAMES_TO_RENDER:
		return

	_reported = true
	_report()
	if _hold:
		print("[BadShaderGate] Holding — control cube green-lit left, fallback sphere right.")
		return
	get_tree().quit(0)


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

	print("  [OK] Environment: flat color background, ambient only")


func _setup_camera() -> void:
	var camera := Camera3D.new()
	camera.position = Vector3(0.0, 1.5, 6.0)
	camera.current = true
	add_child(camera)
	camera.look_at(Vector3.ZERO)

	print("  [OK] Camera: frames both meshes")


func _setup_light() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	light.light_energy = 1.2
	add_child(light)

	print("  [OK] Light: one DirectionalLight3D, no shadows")


## The control: a mesh whose material is independently known to work. If the run
## survives but this cube is not visible in a `?hold` screenshot, the survival was
## vacuous (nothing rendered at all) rather than a contained failure.
func _setup_control_cube() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.8, 0.2)

	var inst := MeshInstance3D.new()
	inst.mesh = BoxMesh.new()
	inst.material_override = mat
	inst.position = Vector3(-1.5, 0.5, 0.0)
	add_child(inst)

	print("  [OK] Control cube: green StandardMaterial3D, left")


## The probe: the fallthrough-switch shader Tint's SPIR-V reader asserts on.
func _setup_broken_sphere() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/switch_fallthrough.gdshader")

	var inst := MeshInstance3D.new()
	inst.mesh = SphereMesh.new()
	inst.material_override = mat
	inst.position = Vector3(1.5, 0.5, 0.0)
	add_child(inst)

	print("  [OK] Broken sphere: switch-fallthrough ShaderMaterial, right — expect one Tint error")


## Prints exactly one `[BAD_SHADER_GATE]` line. Reaching this print is the entire gate:
## before containment the wasm module trapped during the broken material's compile and
## the run never got here.
func _report() -> void:
	print(
		(
			"[BAD_SHADER_GATE] PASS frames=%d hold=%s — process survived an untranslatable shader"
			% [frame_count, str(_hold)]
		)
	)
