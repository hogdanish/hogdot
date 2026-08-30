## `[CGBENCH] pipeline_compile` — first-use pipeline/shader-module cost, by shader class.
##
## This is the microbench the browser symptoms actually need: the game's boot and first-encounter
## freezes are inline pipeline compiles paid inside the frame, and until `window.__cgPerf.compiles`
## existed nothing anywhere measured a single one of them. This scene reduces that to a table.
##
## Method — **attribution is by time window, not by label.** The obvious approach, grouping
## `compiles` records by their label prefix, does not work: Godot's engine shaders share one name
## (`pipe#N:SceneForwardMobileShaderRD`) across every material feature class, so the label cannot
## tell an unshaded material's pipeline from a screen-reading one. Instead each class is added to
## the scene in its own phase, and the slice of `__cgPerf.compiles` that appears during that phase
## is that class's cost. The baseline phase renders an empty scene first so the boot compiles land
## there and not on the first class.
##
## What each number means, and what it does not:
##
##   - `ms_sum` / `ms_max` are the **synchronous** cost of the `wgpuDevice*Create*` calls — exactly
##     what an inline `PipelineHashMapRD` compile spends inside the frame. ⚠ They are NOT the GPU's
##     compile: Dawn defers real backend compilation to first draw. A fully baked project has
##     measured ≈0 s of JS-visible GPU compile while the stall reappeared at first draw. Do not read
##     a small `ms_sum` as "compiling is free" — read `cpu_ms_max` beside it.
##   - `cpu_ms_max` is the worst frame in the phase. That is the number a player feels, and the one
##     to compare against `ms_sum` to see how much of the hitch the driver's own compile explains.
##   - `pc_delta` is the engine's five `PIPELINE_COMPILATIONS_*` monitors summed. It counts
##     compilations the *renderer* asked for; `render`/`compute`/`module` count what the *driver*
##     actually created. They are different questions and a gap between them is informative.
##   - `baked_wgsl_hit` / `baked_wgsl_miss` are the pck's baked-WGSL outcomes over the phase. Running this
##     scene against the checked-in `export/` and `export-unbaked/` directories is the baked A/B,
##     for free.
##
## Run: `?scene=benchcompile` in the URL on web, `-- --scene=benchcompile` natively.

extends Node3D

const Bench := preload("res://scripts/bench_common.gd")

const BENCH := "pipeline_compile"
## Frames each phase renders before its slice is read. Generous on purpose: a pipeline is created
## lazily at first draw, and a class whose compile lands one frame after its objects appear would
## otherwise be attributed to the NEXT class.
const PHASE_FRAMES := 45
## The order is the run order, and it matters — later phases inherit every module the earlier ones
## already compiled, so a class's cost here is its *marginal* cost given the ones above it.
const PHASES: Array[String] = ["baseline", "unshaded", "spatial", "screenread", "particle"]

var _bench: Bench = null
var _phase := 0
var _frames_in_phase := 0
var _phase_started := false

var _compiles_mark := 0
var _counters_mark := {}
var _pc_mark := 0
var _frame_ms: Array[float] = []
var _errors: Array[String] = []

var _root: Node3D = null


func _ready() -> void:
	_bench = Bench.new()
	Bench.started(BENCH)
	Bench.unlock_frame_rate()
	_bench.emit_context(BENCH)
	if not _bench.has_cgperf():
		print(
			(
				"%s note: no __cgPerf channel — compile counts and timings report `na`. "
				+ "Frame times and the engine's PIPELINE_COMPILATIONS monitors are still real."
			)
			% Bench.PREFIX
		)

	_root = Node3D.new()
	add_child(_root)
	_setup_stage()


## Camera, one light, one ground plane. Deliberately minimal: everything here compiles during the
## baseline phase so it is never charged to a material class.
func _setup_stage() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(0, 2.5, 7)
	cam.current = true
	_root.add_child(cam)
	cam.look_at(Vector3(0, 1, 0))

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 25, 0)
	light.shadow_enabled = true
	_root.add_child(light)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30, 30)
	ground.mesh = plane
	_root.add_child(ground)


func _process(delta: float) -> void:
	if _phase >= PHASES.size():
		return

	if not _phase_started:
		_phase_started = true
		_frames_in_phase = 0
		_frame_ms.clear()
		_compiles_mark = _bench.compiles_len()
		_counters_mark = _bench.counters()
		_pc_mark = _pipeline_compilations()
		_build_phase(PHASES[_phase])
		return

	_frame_ms.append(delta * 1000.0)
	_frames_in_phase += 1
	if _frames_in_phase < PHASE_FRAMES:
		return

	_report_phase(PHASES[_phase])
	_phase += 1
	_phase_started = false
	if _phase >= PHASES.size():
		_finish()


## Sum of the engine's five PIPELINE_COMPILATIONS monitors. Renderer-layer, and therefore the one
## number here that exists on every platform including a native run.
func _pipeline_compilations() -> int:
	var total := 0
	for m in [
		Performance.PIPELINE_COMPILATIONS_CANVAS,
		Performance.PIPELINE_COMPILATIONS_MESH,
		Performance.PIPELINE_COMPILATIONS_SURFACE,
		Performance.PIPELINE_COMPILATIONS_DRAW,
		Performance.PIPELINE_COMPILATIONS_SPECIALIZATION,
	]:
		total += int(Performance.get_monitor(m))
	return total


func _build_phase(p_phase: String) -> void:
	match p_phase:
		"baseline":
			pass
		"unshaded":
			_spawn_grid(Vector3(-4, 1, 0), p_phase)
		"spatial":
			_spawn_grid(Vector3(-1.5, 1, 0), p_phase)
		"screenread":
			_spawn_grid(Vector3(1, 1, 0), p_phase)
		"particle":
			_spawn_particles(Vector3(3.5, 1.5, 0))
		_:
			_errors.append("unknown phase '%s'" % p_phase)


## Three meshes per class. More would not add compiles — a pipeline is created once per
## (shader, variant, render-pass) — but three defeats any single-instance fast path and keeps the
## class on screen for the frames that follow.
func _spawn_grid(p_origin: Vector3, p_phase: String) -> void:
	for i in 3:
		var mat := _make_material(p_phase)
		if mat == null:
			return
		var inst := MeshInstance3D.new()
		inst.mesh = SphereMesh.new() if i % 2 == 0 else BoxMesh.new()
		inst.position = p_origin + Vector3(0.0, 0.0, -1.2 * float(i))
		inst.material_override = mat
		_root.add_child(inst)


## One fresh material per instance, so nothing here is shared and the renderer cannot collapse the
## class into a single already-compiled pipeline from an earlier phase.
func _make_material(p_phase: String) -> Material:
	match p_phase:
		"unshaded":
			var unlit := StandardMaterial3D.new()
			unlit.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			unlit.albedo_color = Color(1, 0.2, 0.8)
			return unlit
		"spatial":
			var pbr := StandardMaterial3D.new()
			pbr.albedo_color = Color(0.8, 0.7, 0.2)
			pbr.metallic = 0.6
			pbr.roughness = 0.25
			pbr.normal_enabled = true
			pbr.normal_texture = _noise()
			return pbr
		"screenread":
			var shader: Shader = load("res://shaders/screen_read.gdshader")
			if shader == null:
				_errors.append("screen_read.gdshader failed to load")
				return null
			var sm := ShaderMaterial.new()
			sm.shader = shader
			return sm
	_errors.append("no material for phase '%s'" % p_phase)
	return null


func _spawn_particles(p_origin: Vector3) -> void:
	var particles := GPUParticles3D.new()
	particles.position = p_origin
	particles.amount = 256
	particles.lifetime = 2.0
	var pmat := ParticleProcessMaterial.new()
	pmat.direction = Vector3(0, 1, 0)
	pmat.spread = 25.0
	pmat.initial_velocity_min = 1.5
	pmat.initial_velocity_max = 3.0
	pmat.gravity = Vector3(0, -6.0, 0)
	pmat.turbulence_enabled = true
	particles.process_material = pmat
	var pmesh := SphereMesh.new()
	pmesh.radius = 0.06
	pmesh.height = 0.12
	particles.draw_pass_1 = pmesh
	_root.add_child(particles)


func _noise() -> NoiseTexture2D:
	var tex := NoiseTexture2D.new()
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.05
	tex.noise = noise
	tex.width = 64
	tex.height = 64
	return tex


func _report_phase(p_phase: String) -> void:
	var fields := {
		"phase": p_phase,
		"frames": _frames_in_phase,
		"cpu_ms_p50": Bench.percentile(_frame_ms, 0.5),
		"cpu_ms_max": Bench.percentile(_frame_ms, 1.0),
		"pc_delta": _pipeline_compilations() - _pc_mark,
	}

	if _compiles_mark < 0:
		fields["compiles"] = "na"
		fields["ms_sum"] = "na"
		fields["ms_max"] = "na"
		fields["top"] = "na"
	else:
		var now := _bench.compiles_len()
		var records := _bench.compiles_slice(_compiles_mark, now)
		var ms_sum := 0.0
		var ms_max := 0.0
		var top := "-"
		var kinds := {"render": 0, "compute": 0, "module": 0}
		var baked_records := 0
		for rec: Variant in records:
			if not (rec is Dictionary):
				continue
			var ms := float((rec as Dictionary).get("ms", 0.0))
			ms_sum += ms
			if ms > ms_max:
				ms_max = ms
				top = String((rec as Dictionary).get("label", "-"))
			var kind := String((rec as Dictionary).get("kind", ""))
			if kinds.has(kind):
				kinds[kind] += 1
			if bool((rec as Dictionary).get("baked", false)):
				baked_records += 1
		fields["compiles"] = records.size()
		fields["ms_sum"] = ms_sum
		fields["ms_max"] = ms_max
		fields["render"] = kinds["render"]
		fields["compute"] = kinds["compute"]
		fields["module"] = kinds["module"]
		fields["baked_records"] = baked_records
		fields["top"] = top
		# ⚠ The compiles ring is capped at 512 and shift()s past it. Beyond that the slice's low
		# end has silently moved and the phase's cost is understated, so say so rather than print
		# a number that looks fine.
		if now - _compiles_mark >= 512:
			fields["truncated"] = 1
		_add_counter_deltas(fields)

	Bench.emit(BENCH, fields)


## Baked-WGSL and SPIRV→WGSL cache outcomes over the phase. This is the half of the baked/unbaked
## A/B that lives in the driver rather than in the export preset.
func _add_counter_deltas(p_fields: Dictionary) -> void:
	var now := _bench.counters()
	if now.is_empty() or _counters_mark.is_empty():
		return
	for key in ["baked_wgsl_hit", "baked_wgsl_miss", "spv_wgsl_cache_hit", "spv_wgsl_cache_miss"]:
		p_fields[key] = int(float(now.get(key, 0.0)) - float(_counters_mark.get(key, 0.0)))


func _finish() -> void:
	var totals := _bench.counters()
	if not totals.is_empty():
		Bench.emit(
			BENCH,
			{
				"phase": "TOTAL",
				"baked_wgsl_hit": int(totals.get("baked_wgsl_hit", 0.0)),
				"baked_wgsl_miss": int(totals.get("baked_wgsl_miss", 0.0)),
				"render_pipelines_created": int(totals.get("render_pipelines_created", 0.0)),
				"compute_pipelines_created": int(totals.get("compute_pipelines_created", 0.0)),
				"shader_modules_created": int(totals.get("shader_modules_created", 0.0)),
			}
		)
	Bench.finished(BENCH, _errors.is_empty(), "; ".join(_errors))
	# ⚠ Exiting prints `1 shaders of type ParticlesShaderRD were never freed` and a leaked-RID
	# error. That is PRE-EXISTING engine exit-order noise, not this bench: the checked-in
	# `main.tscn` coverage scene prints the same two lines (plus 14 leaked Textures) on this build,
	# and freeing the scene tree before quitting does not suppress it. Recorded here so the next
	# reader does not spend the afternoon on it, and so nobody "fixes" it by deleting the particle
	# phase — which is the one phase that exercises a compute pipeline.
	get_tree().quit(0 if _errors.is_empty() else 1)
