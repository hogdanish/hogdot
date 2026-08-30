## `[CGBENCH] submits` — encoder splits and queue-submit cost against ramped render-target count.
##
## Instruments the mid-frame encoder split. When a render pass would use a texture that the same
## command buffer has already written, the driver cannot keep encoding: it ends the encoder, issues
## a `wgpuQueueSubmit` right there, and starts a new one. Each split is an extra submit inside the
## frame, and until `__cgPerf` counted them the only way to see one was a `WEBGPU_VERBOSE` build —
## i.e. nobody has ever seen one in a normal run.
##
## The ramp is `SubViewport`s with `UPDATE_ALWAYS`, each drawing its own little 3D scene and each
## displayed by a `TextureRect` in the main viewport. That is the dual-usage shape: written as an
## attachment, sampled in the same frame.
##
## ⚠ **`splits_p50=0` is a real and useful result, not a broken scene.** It means this arrangement
## does not reach the driver's dual-usage condition, and the encoder-split cost is not what a
## SubViewport-heavy scene pays. The submit and render-pass columns are measured either way, and
## `submit_ms` vs. `rp` is the actual per-pass overhead — which is worth having on its own.
##
## ⚠ Every SubViewport is small (192×108). The variable under test is the NUMBER of passes and
## submits, not fill rate; large targets would make this a bandwidth benchmark instead.
##
## Run: `?scene=benchsubmits` in the URL on web, `-- --scene=benchsubmits` natively.

extends Node3D

const Bench := preload("res://scripts/bench_common.gd")

const BENCH := "submits"
## Cumulative, like the draw ramp — nothing is freed inside a measurement window.
const STEPS: Array[int] = [0, 2, 8, 32]
const WARM_FRAMES := 20
const MEASURE_FRAMES := 60
const RT_SIZE := Vector2i(192, 108)

var _bench: Bench = null
var _step := 0
var _frames_in_step := 0
var _frame_ms: Array[float] = []
var _spawned := 0
var _root: Node3D = null
var _layer: CanvasLayer = null
var _stale_steps := 0
var _prev_objects := -1
var _prev_spawned := -1


func _ready() -> void:
	_bench = Bench.new()
	Bench.started(BENCH)
	Bench.unlock_frame_rate()
	_bench.emit_context(BENCH)

	_root = Node3D.new()
	add_child(_root)
	_layer = CanvasLayer.new()
	add_child(_layer)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 2, 6)
	cam.current = true
	_root.add_child(cam)
	cam.look_at(Vector3.ZERO)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 20, 0)
	light.shadow_enabled = false
	_root.add_child(light)

	var inst := MeshInstance3D.new()
	inst.mesh = SphereMesh.new()
	_root.add_child(inst)

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
		# Same rule as the draw ramp: a step the compositor never presented poisons the line it
		# produced, so the run fails rather than reporting a plausible flat curve.
		var ok := _stale_steps == 0
		var note := "" if ok else "%d step(s) not presented — numbers discarded" % _stale_steps
		Bench.finished(BENCH, ok, note)
		get_tree().quit(0 if ok else 1)


## One SubViewport per unit: its own camera, its own spinning mesh, redrawn every frame, and its
## texture shown in the main viewport so the frame both writes and reads it.
func _grow_to(p_target: int) -> void:
	while _spawned < p_target:
		var vp := SubViewport.new()
		vp.size = RT_SIZE
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.transparent_bg = false

		var vcam := Camera3D.new()
		vcam.position = Vector3(0, 0, 3)
		vcam.current = true
		vp.add_child(vcam)

		var vlight := DirectionalLight3D.new()
		vlight.rotation_degrees = Vector3(-45, 15, 0)
		vlight.shadow_enabled = false
		vp.add_child(vlight)

		var vmesh := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.3
		torus.outer_radius = 0.7
		vmesh.mesh = torus
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(fmod(float(_spawned) * 0.11, 1.0), 0.6, 0.9)
		vmesh.material_override = mat
		vp.add_child(vmesh)

		_layer.add_child(vp)

		var rect := TextureRect.new()
		rect.texture = vp.get_texture()
		rect.size = Vector2(96, 54)
		# Tile the previews across the screen; overlap past the edge is harmless, the point is
		# that the texture is sampled in the same frame the SubViewport wrote it.
		rect.position = Vector2(float(_spawned % 12) * 100.0, float(_spawned / 12) * 58.0)
		_layer.add_child(rect)

		_spawned += 1


func _report_step() -> void:
	# There is no draw-count identity to check here the way the draw ramp has one, so staleness is
	# detected by the renderer's visible-object count refusing to move while the scene grew. Same
	# failure it guards against: an occluded window or a hidden tab stops being asked for frames,
	# every counter freezes, and the result looks like a scene that costs nothing.
	var eng_objects := int(
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	)
	var fields := {
		"n": _spawned,
		"cpu_ms_p50": Bench.percentile(_frame_ms, 0.5),
		"cpu_ms_p95": Bench.percentile(_frame_ms, 0.95),
		"eng_objects": eng_objects,
	}
	if _prev_objects >= 0 and _spawned > _prev_spawned and eng_objects <= _prev_objects:
		fields["stale"] = 1
		_stale_steps += 1
	_prev_objects = eng_objects
	_prev_spawned = _spawned

	var rows := _bench.frames_tail(MEASURE_FRAMES)
	if rows.is_empty():
		for key in ["drv_cpu_ms_p50", "rp_p50", "splits_p50", "splits_max", "submit_ms_p50"]:
			fields[key] = "na"
	else:
		var splits := Bench.column(rows, "encoder_splits")
		fields["drv_cpu_ms_p50"] = Bench.percentile(Bench.column(rows, "cpu_frame_ms"), 0.5)
		fields["rp_p50"] = Bench.percentile(Bench.column(rows, "render_passes"), 0.5)
		fields["splits_p50"] = Bench.percentile(splits, 0.5)
		fields["splits_max"] = Bench.percentile(splits, 1.0)
		fields["submit_ms_p50"] = Bench.percentile(Bench.column(rows, "submit_ms"), 0.5)

	var counters := _bench.counters()
	if counters.is_empty():
		fields["splits_total"] = "na"
	else:
		fields["splits_total"] = int(counters.get("encoder_splits", 0.0))

	Bench.emit(BENCH, fields)
