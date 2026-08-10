## Live thread evidence — does this build actually run engine work in parallel?
##
## ⚠ "It ran" is not "it ran threaded". A `threads=yes` web export boots, renders and
## reports PASS on a machine where every `WorkerThreadPool` task silently executed on
## the calling thread, because that is exactly what a `threads=no` build does: the
## nothreads `WorkerThreadPool` runs group tasks inline and `wait_for_group_task_completion`
## returns after they are already done. Nothing in the render path can tell the two apart.
##
## So this asserts on the one thing that cannot be faked: whether any of the work ran on
## a thread that is not the caller. `OS.get_thread_caller_id()` is recorded from inside
## each unit under a mutex and compared against the caller's own id — counting *distinct*
## ids is not enough, since one id might be a single worker doing everything.
##
## Two dispatches are measured, because they fail differently: `WorkerThreadPool`, which
## is what the engine itself uses, and a raw `Thread`, which bypasses the pool. If the raw
## threads run off-caller and the pool does not, the platform is fine and the pool is the
## thing to look at; if neither does, the build cannot thread at all.
##
## ⚠ Keep the raw thread count low. Emscripten pre-allocates `emscriptenPoolSize` (8)
## workers and Godot's own pool takes `godotPoolSize` (4) of them; asking for more than
## the remainder makes Emscripten create a fresh Worker, which needs the main-thread event
## loop — and joining from the main thread has already blocked it. That deadlocks the tab
## hard, as it did here on 2026-08-10 with four raw threads. See RL-044.
##
## Runs after the render frames, so it cannot perturb the frame timings the gate reads.

extends RefCounted

## Enough elements to spread over any core count this runs on, and enough work per
## element that scheduling overhead is not the thing being measured.
const TASK_COUNT := 32
const ITERATIONS_PER_TASK := 900000

var _mutex := Mutex.new()
var _thread_ids := {}
var _checksum := 0


## Runs the serial, pool and raw-Thread passes and prints the comparison. Returns the
## findings as a Dictionary so the caller can fold them into its JSON report.
func run() -> Dictionary:
	var caller_id := OS.get_thread_caller_id()
	var serial_usec := _run_serial()
	var parallel_usec := _run_parallel()
	var pool_ids := _thread_ids.keys()
	var raw := _run_raw_threads()

	var distinct_threads: int = pool_ids.size()
	var speedup := float(serial_usec) / float(maxi(parallel_usec, 1))
	# ⚠ The load-bearing question is not "how many IDs" but "were any of them somebody
	# else". One distinct ID equal to the caller means the pool ran inline; one distinct
	# ID that is not the caller means a real worker did all the work. The first version of
	# this script counted only distinctness and could not tell those apart.
	var pool_ran_off_caller := false
	for id in pool_ids:
		if id != caller_id:
			pool_ran_off_caller = true
	# THREADS_ENABLED is what the build was compiled with; the thread count is what the
	# runtime actually delivered. Reporting both is the point — a build that has the
	# feature and still runs everything on one thread is the failure this gate exists for.
	var feature_threads := OS.has_feature("threads")

	print("\n[ThreadStress] ═══════════════════════════════════════════")
	print("[ThreadStress] OS.has_feature(\"threads\"): %s" % feature_threads)
	# ⚠ Upstream clamps this to 2 on web on purpose — see godot_js_os_hw_concurrency_get()
	# in platform/web/js/libs/library_godot_os.js. It is NOT the pool size, which comes
	# from GodotConfig.godot_pool_size (engine config `godotPoolSize`, default 4).
	print("[ThreadStress] processors: %d (web clamps to 2)" % OS.get_processor_count())
	print("[ThreadStress] caller thread id: %d" % caller_id)
	print("[ThreadStress] --- WorkerThreadPool group task ---")
	print("[ThreadStress]   ids: %d  off-caller: %s  %s" % [
		distinct_threads, pool_ran_off_caller, pool_ids
	])
	print("[ThreadStress]   serial %.1f ms / parallel %.1f ms  (%.2fx)" % [
		serial_usec / 1000.0, parallel_usec / 1000.0, speedup
	])
	print("[ThreadStress] --- raw Thread ---")
	print("[ThreadStress]   started: %d  ids: %d  off-caller: %s" % [
		raw.started, raw.distinct_ids, raw.ran_off_caller
	])
	print("[ThreadStress]   serial %.1f ms / %d-thread %.1f ms  (%.2fx)" % [
		raw.serial_msec, raw.started, raw.parallel_msec, raw.speedup
	])
	if pool_ran_off_caller or raw.ran_off_caller:
		print("[ThreadStress] THREADED — work ran on a thread other than the caller.")
	else:
		print("[ThreadStress] SINGLE-THREADED — everything ran on the calling thread.")
	print("[ThreadStress] ═══════════════════════════════════════════\n")

	return {
		"feature_threads": feature_threads,
		"processor_count": OS.get_processor_count(),
		"caller_thread_id": caller_id,
		"pool_distinct_thread_ids": distinct_threads,
		"pool_ran_off_caller": pool_ran_off_caller,
		"serial_msec": serial_usec / 1000.0,
		"parallel_msec": parallel_usec / 1000.0,
		"speedup": speedup,
		"raw_thread": raw,
		"threaded": pool_ran_off_caller or raw.ran_off_caller,
	}


## ⚠ Bypasses WorkerThreadPool entirely. If raw Threads run off-caller and the pool does
## not, the platform is fine and the pool is the thing to investigate; if neither does,
## the build cannot thread at all. Without this second signal the two are inseparable.
func _run_raw_threads() -> Dictionary:
	var caller_id := OS.get_thread_caller_id()
	var count := 2
	var threads: Array[Thread] = []
	var ids := {}
	var ids_mutex := Mutex.new()

	var body := func(p_index: int) -> void:
		ids_mutex.lock()
		ids[OS.get_thread_caller_id()] = true
		ids_mutex.unlock()
		for i in TASK_COUNT / count:
			_burn_only(p_index * 100 + i)

	var serial_start := Time.get_ticks_usec()
	for i in TASK_COUNT:
		_burn_only(i)
	var serial_usec := Time.get_ticks_usec() - serial_start

	var start := Time.get_ticks_usec()
	for i in count:
		var t := Thread.new()
		if t.start(body.bind(i)) == OK:
			threads.append(t)
	for t in threads:
		t.wait_to_finish()
	var parallel_usec := Time.get_ticks_usec() - start

	var ran_off_caller := false
	for id in ids.keys():
		if id != caller_id:
			ran_off_caller = true

	return {
		"started": threads.size(),
		"distinct_ids": ids.size(),
		"ran_off_caller": ran_off_caller,
		"serial_msec": serial_usec / 1000.0,
		"parallel_msec": parallel_usec / 1000.0,
		"speedup": float(serial_usec) / float(maxi(parallel_usec, 1)),
	}


## ⚠ Same work, same order, same call — only the dispatch differs. Timing the parallel
## pass against a *different* workload would measure nothing.
func _run_serial() -> int:
	_checksum = 0
	var start := Time.get_ticks_usec()
	for i in TASK_COUNT:
		_burn(i)
	return Time.get_ticks_usec() - start


func _run_parallel() -> int:
	_checksum = 0
	_thread_ids.clear()
	var start := Time.get_ticks_usec()
	var group := WorkerThreadPool.add_group_task(_burn, TASK_COUNT, -1, true, "webgpu_thread_stress")
	WorkerThreadPool.wait_for_group_task_completion(group)
	return Time.get_ticks_usec() - start


## Integer-only, so no float determinism question, and unpredictable enough that the
## optimizer cannot fold it away.
func _burn(p_index: int) -> void:
	var acc := _burn_only(p_index)

	_mutex.lock()
	_thread_ids[OS.get_thread_caller_id()] = true
	_checksum = _checksum ^ acc
	_mutex.unlock()


## The work without the bookkeeping, so the raw-Thread pass measures the same load
## without contending on this object's mutex.
func _burn_only(p_index: int) -> int:
	var acc := 1469598103934665603
	var seed_value := p_index * 2654435761
	for i in ITERATIONS_PER_TASK:
		acc = (acc ^ (seed_value + i)) * 1099511628211
	return acc
