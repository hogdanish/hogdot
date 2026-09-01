## Base class for every perf-bed scene.
##
## A scene is a list of phases. For each phase the base class calls `enter_phase(i)`, discards
## `warm` frames (pipeline compiles, node settling), measures `frames` frames, and prints one
## `[CGBENCH] <scene> phase=<label> k=v …` line. The lifecycle lines are
## `[CGBENCH] Starting <scene>` and `[CGBENCH] PASS|FAIL <scene>`.
##
## Three clocks, deliberately:
##  - `frame_ms`  — `_process` delta, rAF-to-rAF on web. Under budget this is the display's
##                  refresh period, not a cost. Only its overrun and its tail (p95/p99/max) say
##                  anything below budget.
##  - `busy_ms`   — how long the browser's rAF callback ran (the `__bench` head-include wraps
##                  `requestAnimationFrame`). This is the CPU cost of an engine iteration and is
##                  NOT clamped by vsync. It is the number to compare across builds on web. `na`
##                  natively.
##  - `drv_*`     — the driver's own `window.__cgPerf` ring (hogdot only). `na` on a build that
##                  does not publish it, including GodotWebGPU 4.6.2. `na` means not measured.
##
## `warm_max_ms` is the largest frame seen during the warm-up of the phase — that is where a
## first-use pipeline compile lands, so it is the hitch metric, kept separate from steady state.
##
## Compatible with Godot 4.6 (the GodotWebGPU baseline exports this same project).
extends Node3D

const PREFIX := "[CGBENCH]"

const JS_HELPERS := """
(function () {
	var g = window;
	var b = {};
	b.present = function () { return g.__cgPerf ? 1 : 0; };
	b.schema = function () { return g.__cgPerf ? JSON.stringify(g.__cgPerf.frames_schema) : 'null'; };
	b.counters = function () { return g.__cgPerf ? JSON.stringify(g.__cgPerf.counters) : 'null'; };
	b.compiles_len = function () { return g.__cgPerf ? g.__cgPerf.compiles.length : -1; };
	b.compiles_ms = function (from) {
		if (!g.__cgPerf) { return 'null'; }
		var a = g.__cgPerf.compiles; var s = 0, n = 0, mx = 0;
		for (var i = Math.max(0, from); i < a.length; i++) { s += a[i].ms; n++; if (a[i].ms > mx) { mx = a[i].ms; } }
		return JSON.stringify([n, s, mx]);
	};
	b.frames_tail = function (n) {
		if (!g.__cgPerf) { return 'null'; }
		var f = g.__cgPerf.frames;
		var take = Math.min(n, f.count);
		var out = [];
		for (var i = f.count - take; i < f.count; i++) {
			var base = ((f.head - f.count + i) % f.cap) * f.stride;
			var row = [];
			for (var k = 0; k < f.stride; k++) { row.push(f.buf[base + k]); }
			out.push(row);
		}
		return JSON.stringify(out);
	};
	b.raf_count = function () { return g.__bench ? g.__bench.rafCount() : -1; };
	b.raf_tail = function (n) { return g.__bench ? g.__bench.rafTail(n) : 'null'; };
	b.api_keys = function () { return g.__bench ? JSON.stringify(g.__bench.API_KEYS) : 'null'; };
	b.api_tail = function (n) { return g.__bench ? g.__bench.apiTail(n) : 'null'; };
	b.long_tasks = function (t) { return g.__bench ? g.__bench.longTasks(t) : 'null'; };
	b.now = function () { return performance.now(); };
	b.visible = function () { return document.visibilityState === 'visible' ? 1 : 0; };
	g.__cgBench = b;
})();
"""

var params := {}
var bench_name := "unnamed"
var warm_frames := 40
var measure_frames := 240

var _web := false
var _cgperf := false
var _schema: Array = []
var _hold := false
var _phase := -1
var _phase_frames := 0
var _frame_ms: Array[float] = []
var _warm_max_ms := 0.0
var _warm_raf_start := -1
var _warm_compiles_start := -1
var _raf_start := -1
var _compiles_start := -1
var _counters_start := {}
var _measure_t0 := 0.0
var _first_frame_done := false
var _failed := false
var _fail_note := ""


## Number of phases. Override.
func phase_count() -> int:
	return 1


## Human label for phase `p_index`. Override.
func phase_label(_p_index: int) -> String:
	return "steady"


## Build (or grow) the scene for phase `p_index`. Override. Called before its warm-up.
func enter_phase(_p_index: int) -> void:
	pass


## Scene-specific `k=v` fields for the phase line. Override.
func extra_fields(_p_index: int) -> Dictionary:
	return {}


func _ready() -> void:
	_web = OS.has_feature("web")
	_hold = params.has("hold")
	warm_frames = int(params.get("warm", warm_frames))
	measure_frames = int(params.get("frames", measure_frames))
	if _web:
		JavaScriptBridge.eval(JS_HELPERS, true)
		_cgperf = _eval_int("window.__cgBench.present()") == 1
		if _cgperf:
			var s: Variant = _eval_json("window.__cgBench.schema()")
			if s is Array:
				_schema = s
	# Not honored on web (rAF drives the loop) but keeps native runs from sleeping on vsync.
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if params.has("scale"):
		get_viewport().scaling_3d_scale = float(params["scale"])
	print("%s Starting %s" % [PREFIX, bench_name])
	_emit("context", {
		"web": _web,
		"cgperf": _cgperf,
		"method": RenderingServer.get_current_rendering_method(),
		"debug": OS.is_debug_build(),
		"version": Engine.get_version_info().get("string", "?"),
		"scale": get_viewport().scaling_3d_scale,
		"win": "%dx%d" % [get_viewport().size.x, get_viewport().size.y],
		"visible": _visible(),
	})
	_next_phase()


## Per-frame animation hook for subclasses (keeps `_process` owned by the harness).
func tick(_delta: float) -> void:
	pass


func _process(delta: float) -> void:
	if _phase < 0 or _phase >= phase_count():
		return
	tick(delta)
	var ms := delta * 1000.0
	if not _first_frame_done:
		_first_frame_done = true
		# Boot cost: navigation start to the first engine frame, plus every compile so far.
		var f := {"first_frame_ms": _eval_float("window.__cgBench.now()") if _web else NAN}
		var c := _compiles_since(0)
		f["compiles"] = c[0]
		f["compile_ms"] = c[1]
		f["compile_max_ms"] = c[2]
		_emit("load", f)
		return
	_phase_frames += 1
	if _phase_frames <= warm_frames:
		# Frame 1 of a phase carries the previous phase's report (JSON round trips through
		# JavaScriptBridge, ~130 ms) plus enter_phase()'s node building; it is harness cost,
		# not a hitch, so it stays out of warm_max_ms.
		if _phase_frames > 1:
			_warm_max_ms = maxf(_warm_max_ms, ms)
		if _phase_frames == warm_frames:
			_begin_measure()
		return
	_frame_ms.append(ms)
	if _frame_ms.size() >= measure_frames:
		_report_phase()
		_next_phase()


func _begin_measure() -> void:
	_measure_t0 = _eval_float("window.__cgBench.now()") if _web else Time.get_ticks_msec()
	_raf_start = _eval_int("window.__cgBench.raf_count()") if _web else -1
	_compiles_start = _eval_int("window.__cgBench.compiles_len()") if _cgperf else -1
	_counters_start = _counters()


func _next_phase() -> void:
	_phase += 1
	_phase_frames = 0
	_frame_ms.clear()
	_warm_max_ms = 0.0
	if _phase < phase_count():
		_warm_raf_start = _eval_int("window.__cgBench.raf_count()") if _web else -1
		_warm_compiles_start = _eval_int("window.__cgBench.compiles_len()") if _cgperf else -1
		enter_phase(_phase)
		return
	if _failed:
		print("%s FAIL %s — %s" % [PREFIX, bench_name, _fail_note])
	else:
		print("%s PASS %s" % [PREFIX, bench_name])
	if not _hold:
		get_tree().quit(1 if _failed else 0)


func _report_phase() -> void:
	var f := {"phase": phase_label(_phase)}
	f.merge(extra_fields(_phase))
	var sum := 0.0
	var hitch := 0
	for v in _frame_ms:
		sum += v
		if v > 50.0:
			hitch += 1
	f["frames"] = _frame_ms.size()
	f["fps"] = 1000.0 * _frame_ms.size() / sum if sum > 0.0 else NAN
	f["frame_p50"] = percentile(_frame_ms, 0.5)
	f["frame_p95"] = percentile(_frame_ms, 0.95)
	f["frame_p99"] = percentile(_frame_ms, 0.99)
	f["frame_max"] = percentile(_frame_ms, 1.0)
	f["hitch50"] = hitch
	f["warm_max_ms"] = _warm_max_ms
	# Warm-up attribution: the largest rAF busy time during warm-up (frame 1 excluded, see
	# _process) says whether a warm hitch was main-thread work; the compile records made during
	# warm-up say how much of it was pipeline/module creation on hogdot.
	if _web and _warm_raf_start >= 0 and _raf_start > _warm_raf_start + 1:
		var wrows: Variant = _eval_json("window.__cgBench.raf_tail(%d)" % (_eval_int("window.__cgBench.raf_count()") - _warm_raf_start))
		var wbusy := 0.0
		if wrows is Array:
			var arr := wrows as Array
			var n_warm := _raf_start - _warm_raf_start
			for i in range(1, mini(n_warm, arr.size())):
				if arr[i] is Array and (arr[i] as Array).size() == 2:
					wbusy = maxf(wbusy, float((arr[i] as Array)[1]))
		f["warm_busy_max"] = wbusy
	else:
		f["warm_busy_max"] = NAN
	var wc := _compiles_since(_warm_compiles_start)
	f["warm_compiles"] = wc[0]
	f["warm_compile_ms"] = wc[1]
	f["eng_draws"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	f["eng_objects"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	f["eng_prims"] = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	f["vram_mb"] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0

	# CPU busy time inside the rAF callback — the un-clamped cost on web.
	var busy: Array[float] = []
	if _web and _raf_start >= 0:
		var n := _eval_int("window.__cgBench.raf_count()") - _raf_start
		var rows: Variant = _eval_json("window.__cgBench.raf_tail(%d)" % n)
		if rows is Array:
			for r: Variant in rows:
				if r is Array and (r as Array).size() == 2:
					busy.append(float((r as Array)[1]))
	f["busy_p50"] = percentile(busy, 0.5)
	f["busy_p95"] = percentile(busy, 0.95)
	f["busy_max"] = percentile(busy, 1.0)
	# WebGPU API calls per frame, counted at the browser's own GPU* prototypes (any build).
	var api_keys: Variant = _eval_json("window.__cgBench.api_keys()") if _web else null
	var api_rows: Variant = _eval_json("window.__cgBench.api_tail(%d)" % _frame_ms.size()) if _web else null
	if api_keys is Array and api_rows is Array:
		for k in (api_keys as Array).size():
			var col: Array[float] = []
			for r: Variant in api_rows:
				if r is Array and (r as Array).size() > k:
					col.append(float((r as Array)[k]))
			var key := String((api_keys as Array)[k])
			if key.ends_with("_bytes"):
				f["api_" + key.replace("_bytes", "_kb")] = percentile(col, 0.5) / 1024.0
			else:
				f["api_" + key] = percentile(col, 0.5)
	var lt: Variant = _eval_json("window.__cgBench.long_tasks(%f)" % _measure_t0) if _web else null
	if lt is Array and (lt as Array).size() == 3:
		f["longtasks"] = int((lt as Array)[0])
		f["longtask_ms"] = float((lt as Array)[1])
	else:
		f["longtasks"] = NAN
		f["longtask_ms"] = NAN

	# Driver ring (hogdot only).
	var drv := _frames_tail(_frame_ms.size())
	if drv.is_empty():
		for k in ["drv_cpu_p50", "drv_draws", "drv_setbg", "drv_rp", "drv_submit_p50", "drv_submit_p95", "drv_fence_neg", "drv_pipes"]:
			f[k] = NAN
	else:
		f["drv_cpu_p50"] = percentile(column(drv, "cpu_frame_ms"), 0.5)
		f["drv_draws"] = percentile(column(drv, "draw_calls"), 0.5)
		f["drv_setbg"] = percentile(column(drv, "bindgroup_sets"), 0.5)
		f["drv_rp"] = percentile(column(drv, "render_passes"), 0.5)
		f["drv_submit_p50"] = percentile(column(drv, "submit_ms"), 0.5)
		f["drv_submit_p95"] = percentile(column(drv, "submit_ms"), 0.95)
		var neg := 0
		for v in column(drv, "fence_lag"):
			if v < 0.0:
				neg += 1
		f["drv_fence_neg"] = neg
		var c0 := _counters_start
		var c1 := _counters()
		f["drv_pipes"] = float(c1.get("render_pipelines_created", 0)) - float(c0.get("render_pipelines_created", 0))
	var comp := _compiles_since(_compiles_start)
	f["compiles"] = comp[0]
	f["compile_ms"] = comp[1]
	f["visible"] = _visible()
	if _web and _visible() == 0:
		_failed = true
		_fail_note = "page not visible during phase %s" % phase_label(_phase)
		f["stale"] = 1
	_emit(bench_name, f)


# --- helpers ---------------------------------------------------------------------------------


func _emit(p_tag: String, p_fields: Dictionary) -> void:
	var parts: Array[String] = []
	for key: Variant in p_fields:
		parts.append("%s=%s" % [String(key), fmt(p_fields[key])])
	print("%s %s %s" % [PREFIX, p_tag, " ".join(parts)])


static func fmt(p_value: Variant) -> String:
	if p_value is float:
		var f := float(p_value)
		if is_nan(f):
			return "na"
		return "%.3f" % f
	if p_value is bool:
		return "1" if p_value else "0"
	return str(p_value)


static func percentile(p_values: Array[float], p_pct: float) -> float:
	if p_values.is_empty():
		return NAN
	var sorted := p_values.duplicate()
	sorted.sort()
	var idx := int(round(p_pct * float(sorted.size() - 1)))
	return sorted[clampi(idx, 0, sorted.size() - 1)]


static func column(p_rows: Array[Dictionary], p_field: String) -> Array[float]:
	var out: Array[float] = []
	for row in p_rows:
		if row.has(p_field):
			out.append(float(row[p_field]))
	return out


func _eval_json(p_expr: String) -> Variant:
	if not _web:
		return null
	var raw: Variant = JavaScriptBridge.eval(p_expr, true)
	if raw == null:
		return null
	return JSON.parse_string(String(raw))


func _eval_int(p_expr: String) -> int:
	if not _web:
		return -1
	var v: Variant = JavaScriptBridge.eval(p_expr, true)
	return int(v) if v != null else -1


func _eval_float(p_expr: String) -> float:
	if not _web:
		return NAN
	var v: Variant = JavaScriptBridge.eval(p_expr, true)
	return float(v) if v != null else NAN


func _visible() -> int:
	return _eval_int("window.__cgBench.visible()") if _web else -1


func _counters() -> Dictionary:
	if not _cgperf:
		return {}
	var v: Variant = _eval_json("window.__cgBench.counters()")
	return v if v is Dictionary else {}


## [count, total_ms, max_ms] of driver compile records since index `p_from`.
func _compiles_since(p_from: int) -> Array:
	if not _cgperf or p_from < 0:
		return [NAN, NAN, NAN]
	var v: Variant = _eval_json("window.__cgBench.compiles_ms(%d)" % p_from)
	if v is Array and (v as Array).size() == 3:
		return [float((v as Array)[0]), float((v as Array)[1]), float((v as Array)[2])]
	return [NAN, NAN, NAN]


func _frames_tail(p_count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _cgperf or _schema.is_empty():
		return out
	var v: Variant = _eval_json("window.__cgBench.frames_tail(%d)" % p_count)
	if not (v is Array):
		return out
	for row: Variant in v:
		if not (row is Array):
			continue
		var d := {}
		for i in range(mini(_schema.size(), (row as Array).size())):
			d[String(_schema[i])] = float((row as Array)[i])
		out.append(d)
	return out


## Integer parameter with a default.
func pint(p_key: String, p_default: int) -> int:
	return int(params.get(p_key, p_default))


func pfloat(p_key: String, p_default: float) -> float:
	return float(params.get(p_key, p_default))
