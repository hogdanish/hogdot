## `[CGBENCH] draws_per_sec` — raw driver draw throughput against a ramped instance count.
##
## The `godotwebgpu` skill argues from an IPC-bound cost model — that on this backend eliminating a
## draw call beats almost anything else, because every command crosses the wasm→JS boundary. That
## model has never had a measurement behind it. This scene is the measurement: ramp N identical
## meshes, and watch what `cpu_frame_ms` does as `draw_calls` climbs.
##
## ⚠ Every instance gets its **own** `StandardMaterial3D`. Forward-mobile batches consecutive
## instances that share a mesh and material, which would collapse the ramp into a flat line and make
## the scene look like it proved draw calls are free. Distinct materials defeat that. The ramp is
## therefore "N objects the renderer cannot merge", which is the shape a real scene has.
##
## ⚠ `draws_p50` is **read back from the driver**, not assumed from N. If the two disagree, the
## renderer merged or culled something and the throughput figure must be computed from the measured
## draws — which is why the line prints both.
##
## `cpu_ms_p50` is the script-side frame delta and exists on every platform; `drv_cpu_ms_p50` is the
## driver's own `begin_segment`-to-`begin_segment` measurement from the `__cgPerf` ring. The two
## should agree closely on web, and a persistent gap is itself a finding — it means time is being
## spent outside the engine iteration the driver can see.
##
## Run: `?scene=benchdraws` in the URL on web, `-- --scene=benchdraws` natively.

extends Node3D

const Bench := preload("res://scripts/bench_common.gd")

const BENCH := "draws_per_sec"
## Instance counts, in run order. Cumulative — each step ADDS to the scene, so the ramp is
## monotonic and nothing is destroyed mid-run (freeing 4096 nodes inside the measurement window
## would show up as a phantom stall).
## ⚠ The top step is deliberately past what a 120 Hz frame can absorb. On web the engine tick is
## driven by requestAnimationFrame and cannot run faster than the display, so every step under the
## refresh budget reports the same `cpu_ms` by construction; the ramp only becomes a cost curve
## once it overruns. `submit_ms` from the driver ring is the column that is not clamped that way.
const STEPS: Array[int] = [64, 256, 1024, 4096, 8192]
## Frames discarded at the start of a step, then frames measured. The discard covers the first-use
## pipeline compile and the renderer settling; without it step 1 measures compilation, not drawing.
const WARM_FRAMES := 20
const MEASURE_FRAMES := 60

var _bench: Bench = null
var _step := 0
var _frames_in_step := 0
var _frame_ms: Array[float] = []
var _spawned := 0
var _root: Node3D = null
var _mesh: Mesh = null
var _stale_steps := 0


func _ready() -> void:
	_bench = Bench.new()
	Bench.started(BENCH)
	Bench.unlock_frame_rate()
	_bench.emit_context(BENCH)

	_root = Node3D.new()
	add_child(_root)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 6, 26)
	cam.far = 400.0
	cam.current = true
	_root.add_child(cam)
	cam.look_at(Vector3.ZERO)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 30, 0)
	# ⚠ No shadows. A shadow map adds a whole extra render pass per light and its own draw per
	# instance, which would double the ramp and put the cost somewhere this scene is not measuring.
	light.shadow_enabled = false
	_root.add_child(light)

	# One shared mesh: the variable under test is the draw count, not vertex processing.
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 0.6, 0.6)
	_mesh = box

	_grow_to(STEPS[0])


func _process(delta: float) -> void:
	if _step >= STEPS.size():
		return

	_frames_in_step += 1
	if _frames_in_step <= WARM_FRAMES:
		return
	_frame_ms.append(delta * 1000.0)
	if _frame_ms.size() < MEASURE_FRAMES:
		return

	_report_step()
	_step += 1
	_frames_in_step = 0
	_frame_ms.clear()
	if _step < STEPS.size():
		_grow_to(STEPS[_step])
	else:
		# ⚠ A run with a stale step FAILS. Its numbers look like a flat, well-behaved ramp, which
		# is the most dangerous shape a bad measurement can take — an automated consumer would
		# record it as evidence that draw calls are cheap. Better a red run than a quiet lie.
		var ok := _stale_steps == 0
		var note := "" if ok else "%d step(s) not presented — numbers discarded" % _stale_steps
		Bench.finished(BENCH, ok, note)
		get_tree().quit(0 if ok else 1)


## Add instances until the scene holds `p_target` of them, on a cube lattice around the origin.
func _grow_to(p_target: int) -> void:
	while _spawned < p_target:
		var i := _spawned
		var side := 16
		var x := float(i % side) - float(side) * 0.5
		var y := float((i / side) % side) * 0.8 - 6.0
		var z := float(i / (side * side)) * -1.4
		var inst := MeshInstance3D.new()
		inst.mesh = _mesh
		inst.position = Vector3(x, y, z)
		var mat := StandardMaterial3D.new()
		# Distinct albedo per instance: see the batching note in the header.
		mat.albedo_color = Color(fmod(float(i) * 0.017, 1.0), 0.55, 0.85)
		inst.material_override = mat
		_root.add_child(inst)
		_spawned += 1


func _report_step() -> void:
	var eng_draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var fields := {
		"n": _spawned,
		"cpu_ms_p50": Bench.percentile(_frame_ms, 0.5),
		"cpu_ms_p95": Bench.percentile(_frame_ms, 0.95),
		"eng_draws": eng_draws,
	}
	# ⚠ `stale=1` means the frame did not draw what the scene contains, and EVERY number on this
	# line is then meaningless. It is not hypothetical: a native run in an occluded window produced
	# a perfect-looking flat ramp — `eng_draws` frozen at the first step's value and `cpu_ms` pinned
	# at ~6.9 ms from 64 instances to 8192 — because the compositor had stopped asking for frames.
	# The browser does the same to a hidden tab. A bench with no staleness check cannot tell that
	# apart from "draw calls are free", which is the exact wrong conclusion.
	if eng_draws < _spawned:
		fields["stale"] = 1
		_stale_steps += 1

	var rows := _bench.frames_tail(MEASURE_FRAMES)
	if rows.is_empty():
		for key in [
			"drv_cpu_ms_p50", "draws_p50", "setbg_p50", "rp_p50", "submit_ms_p50", "draws_per_ms"
		]:
			fields[key] = "na"
	else:
		var drv_cpu := Bench.percentile(Bench.column(rows, "cpu_frame_ms"), 0.5)
		var draws := Bench.percentile(Bench.column(rows, "draw_calls"), 0.5)
		fields["drv_cpu_ms_p50"] = drv_cpu
		fields["draws_p50"] = draws
		fields["setbg_p50"] = Bench.percentile(Bench.column(rows, "bindgroup_sets"), 0.5)
		fields["rp_p50"] = Bench.percentile(Bench.column(rows, "render_passes"), 0.5)
		fields["submit_ms_p50"] = Bench.percentile(Bench.column(rows, "submit_ms"), 0.5)
		# The headline: draws the driver actually issued, per millisecond of CPU frame time.
		# Computed from the MEASURED draw count, never from N — see the header.
		if drv_cpu > 0.0 and not is_nan(draws):
			fields["draws_per_ms"] = draws / drv_cpu
		else:
			fields["draws_per_ms"] = "na"

	Bench.emit(BENCH, fields)
