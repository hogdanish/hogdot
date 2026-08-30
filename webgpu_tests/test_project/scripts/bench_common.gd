## Shared plumbing for the `[CGBENCH]` driver microbenches.
##
## These benches answer "what does the WebGPU driver cost" — a pipeline create, a draw call, an
## encoder split. They do NOT answer "why is a game slow"; anything gameplay-shaped belongs in
## CommonGrounds' own /bench, not here.
##
## ⚠ Everything driver-side is read from `window.__cgPerf`, the fork's always-on telemetry channel
## (see the `godotwebgpu` skill). A native run has no such channel, so every bench still runs and
## reports its engine-visible half with the driver-only fields printed as `na`. **`na` means NOT
## MEASURED, never zero** — a consumer that reads it as 0 will conclude the driver is free.
##
## ⚠ `JavaScriptBridge.eval` can only bring back null, bool, number, string and PackedByteArray —
## a JS object or array comes back as `null`. So every query below returns a JSON *string* built
## on the JS side and parsed here. The companion trap, documented in `shader_coverage.gd` and paid
## for once already: a JS `true` arrives as a Variant of type FLOAT, so ask for a number, never a
## boolean.
##
## ⚠ `__cgPerf.frames.buf` is a live view over the wasm heap and `-sALLOW_MEMORY_GROWTH=1` detaches
## any cached view when the heap grows. `__cgBench` therefore re-reads `__cgPerf.frames` on every
## call and caches nothing.

extends RefCounted

## Every line these benches print. `smoke_test.mjs --expect-prefix='[CGBENCH]'` keys on it, so
## `<PREFIX> Starting` / `<PREFIX> PASS` / `<PREFIX> FAIL` are the lifecycle contract.
const PREFIX := "[CGBENCH]"

## The JS-side reader, installed once. Kept in one string so the whole driver-facing surface of
## these benches is auditable in one place.
##
## `frames_tail` walks the ring oldest→newest with the documented index formula
## `buf[((head - count + i) % cap) * stride + f]`; the schema is fetched separately so a consumer
## keys by name and cannot be silently mislabelled if a column moves.
const JS_HELPERS := """
(function () {
	var g = window;
	var b = {};
	b.present = function () { return g.__cgPerf ? 1 : 0; };
	b.schema = function () {
		if (!g.__cgPerf) { return 'null'; }
		return JSON.stringify(g.__cgPerf.frames_schema);
	};
	b.counters = function () {
		if (!g.__cgPerf) { return 'null'; }
		return JSON.stringify(g.__cgPerf.counters);
	};
	b.ts = function () {
		if (!g.__cgPerf) { return 'null'; }
		return JSON.stringify(g.__cgPerf.ts);
	};
	b.compiles_len = function () {
		if (!g.__cgPerf) { return -1; }
		return g.__cgPerf.compiles.length;
	};
	b.compiles_slice = function (from, to) {
		if (!g.__cgPerf) { return 'null'; }
		return JSON.stringify(g.__cgPerf.compiles.slice(from, to));
	};
	b.events = function () {
		if (!g.__cgPerf) { return 'null'; }
		return JSON.stringify(g.__cgPerf.events);
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
	g.__cgBench = b;
})();
"""

var _web := false
var _present := false
var _schema: Array = []


func _init() -> void:
	_web = OS.has_feature("web")
	if not _web:
		return
	JavaScriptBridge.eval(JS_HELPERS, true)
	# ⚠ Number, not boolean — a JS `true` arrives as FLOAT and a TYPE_BOOL guard rejects it.
	var p: Variant = JavaScriptBridge.eval("window.__cgBench.present()", true)
	_present = p != null and int(p) == 1
	if _present:
		var s: Variant = _eval_json("window.__cgBench.schema()")
		if s is Array:
			_schema = s


## Is the fork's driver channel readable? False natively, and false on a web build whose driver
## does not publish it (an OpenGL/Compatibility export, or a template older than 2026-08-30).
func has_cgperf() -> bool:
	return _present


func _eval_json(expr: String) -> Variant:
	if not _web:
		return null
	var raw: Variant = JavaScriptBridge.eval(expr, true)
	if raw == null:
		return null
	return JSON.parse_string(String(raw))


## Monotonic counters, name → number. Empty without the channel.
func counters() -> Dictionary:
	var v: Variant = _eval_json("window.__cgBench.counters()")
	return v if v is Dictionary else {}


## `{supported, requested, degraded_frames}`. ⚠ `degraded_frames > 0` means the driver skipped
## timestamp resolves and any GPU number from this run is incomplete — say so, do not average it.
func timestamps() -> Dictionary:
	var v: Variant = _eval_json("window.__cgBench.ts()")
	return v if v is Dictionary else {}


## How many compile records exist so far. Phases bracket a window with two of these and read the
## slice between them; see `compiles_slice`.
func compiles_len() -> int:
	if not _present:
		return -1
	var v: Variant = JavaScriptBridge.eval("window.__cgBench.compiles_len()", true)
	return int(v) if v != null else -1


## The compile records in `[from, to)`.
##
## ⚠ The ring is capped at 512 and `shift()`s past it, so `from` silently drifts if more than 512
## compiles happen inside one window. Every caller reports the count it saw against the cap.
func compiles_slice(p_from: int, p_to: int) -> Array:
	var v: Variant = _eval_json("window.__cgBench.compiles_slice(%d, %d)" % [p_from, p_to])
	return v if v is Array else []


## The last `p_count` frame-ring rows, each a Dictionary keyed by `frames_schema`.
##
## ⚠ A row for frame N is written at the START of frame N+1, so the newest row always describes the
## last *completed* frame — call this after the phase's frames have actually run.
func frames_tail(p_count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var v: Variant = _eval_json("window.__cgBench.frames_tail(%d)" % p_count)
	if not (v is Array) or _schema.is_empty():
		return out
	for row: Variant in v:
		if not (row is Array):
			continue
		var d := {}
		for i in range(min(_schema.size(), (row as Array).size())):
			d[String(_schema[i])] = float((row as Array)[i])
		out.append(d)
	return out


## Percentile of a float array, nearest-rank. Returns NAN for an empty sample so it prints as `na`
## rather than as a confident 0.
static func percentile(p_values: Array[float], p_pct: float) -> float:
	if p_values.is_empty():
		return NAN
	var sorted := p_values.duplicate()
	sorted.sort()
	var idx := int(round(p_pct * float(sorted.size() - 1)))
	return sorted[clampi(idx, 0, sorted.size() - 1)]


## Pull one column out of `frames_tail()` rows.
static func column(p_rows: Array[Dictionary], p_field: String) -> Array[float]:
	var out: Array[float] = []
	for row in p_rows:
		if row.has(p_field):
			out.append(float(row[p_field]))
	return out


## Format one value for a `k=v` field. NAN becomes `na` — not measured, not zero.
static func fmt(p_value: Variant) -> String:
	if p_value is float:
		var f := float(p_value)
		if is_nan(f):
			return "na"
		return "%.3f" % f
	if p_value is bool:
		return "1" if p_value else "0"
	return str(p_value)


## Emit one result line: `[CGBENCH] <bench> k=v k=v …`.
##
## ⚠ Bare `print`, never a logging category — the driver's own `[PERF]` / `[CGPERF]` lines are
## parsed by prefix and a second bracketed tag on the same line collides with them.
static func emit(p_bench: String, p_fields: Dictionary) -> void:
	var parts: Array[String] = []
	for key: Variant in p_fields:
		parts.append("%s=%s" % [String(key), fmt(p_fields[key])])
	print("%s %s %s" % [PREFIX, p_bench, " ".join(parts)])


## Take the frame rate off the display's cadence, so a throughput ramp measures cost instead of
## measuring vsync.
##
## ⚠ This was not optional and the first native run proved it: every step of the draw ramp reported
## `cpu_ms_p50=8.333` — exactly 120 Hz — from 64 instances to 4096, because the frame was sleeping
## on the presenter, not working. A ramp that flat reads as "draw calls are free".
##
## ⚠ **It does nothing on web, and cannot.** The browser drives the engine from
## `requestAnimationFrame`; there is no way to ask it to run faster than the display. So on the
## target platform `cpu_frame_ms` only becomes a cost signal once the frame OVERRUNS the refresh
## budget, and below that it is a flat line by construction. The driver-side `submit_ms` column from
## the `__cgPerf` ring is the per-frame cost that is *not* clamped that way — read that one first on
## web, and treat a flat `cpu_ms` as "under budget", never as "free".
static func unlock_frame_rate() -> void:
	Engine.max_fps = 0
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)


## Lifecycle lines. `smoke_test.mjs` waits on PASS/FAIL and starts its clock on Starting.
static func started(p_bench: String) -> void:
	print("%s Starting %s" % [PREFIX, p_bench])


static func finished(p_bench: String, p_ok: bool, p_note: String = "") -> void:
	var verdict := "PASS" if p_ok else "FAIL"
	if p_note.is_empty():
		print("%s %s %s" % [PREFIX, verdict, p_bench])
	else:
		print("%s %s %s — %s" % [PREFIX, verdict, p_bench, p_note])


## One line per bench recording what the run can and cannot claim. ⚠ Print it before the results,
## not after: a reader who stops at the first number must already know whether the driver channel
## was there and whether GPU timings were degraded.
func emit_context(p_bench: String) -> void:
	var fields := {
		"cgperf": has_cgperf(),
		"web": _web,
		"method": RenderingServer.get_current_rendering_method(),
		"debug": OS.is_debug_build(),
	}
	var ts := timestamps()
	if ts.is_empty():
		fields["ts"] = "na"
	else:
		fields["ts_supported"] = 1 if ts.get("supported", false) else 0
		fields["ts_degraded"] = ts.get("degraded_frames", 0)
	fields["visible"] = page_visible()
	emit(p_bench, fields)


## Is the page actually being presented? `1` yes, `0` no, `-1` unknown (native — the OS gives no
## portable occlusion signal here).
##
## ⚠ A run that is not presented measures nothing while looking perfectly healthy: the compositor
## stops asking for frames, the renderer's counters freeze at their last value, and the frame delta
## drops to the cost of an idle loop. That produced a flat, plausible draw ramp on this machine
## once already. A hidden browser tab does the same thing — `requestAnimationFrame` simply stops.
func page_visible() -> int:
	if not _web:
		return -1
	# ⚠ Number, not boolean: a JS `true` arrives as a Variant of type FLOAT.
	var v: Variant = JavaScriptBridge.eval(
		"(document.visibilityState === 'visible') ? 1 : 0", true
	)
	return int(v) if v != null else -1
