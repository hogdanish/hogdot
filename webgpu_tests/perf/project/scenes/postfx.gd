## `postfx` — the per-pixel cost of CommonGrounds' environment stack over fixed geometry:
## bare colour background → procedural sky → +glow → +depth fog → the same at 3D scale 1.0.
## Everything else is constant, so a phase's delta is that feature's cost.
extends "res://bench_scene.gd"

const CG := preload("res://cg.gd")
const LABELS: Array[String] = ["bare", "sky", "sky_glow", "sky_glow_fog", "full_scale1"]

var _env: WorldEnvironment
var _base_scale := 0.5


func _init() -> void:
	bench_name = "postfx"


func phase_count() -> int:
	return LABELS.size()


func phase_label(p_index: int) -> String:
	return LABELS[p_index]


func enter_phase(p_index: int) -> void:
	if p_index == 0:
		add_child(CG.sun(true))
		add_child(CG.camera(Vector3(0, 8, 24), Vector3(0, 1, 0)))
		add_child(CG.ground(60.0))
		CG.props(self, 80, 36.0, CG.materials(16))
		_base_scale = get_viewport().scaling_3d_scale
	if _env:
		_env.queue_free()
	match p_index:
		0:
			_env = CG.environment(false, false, false)
		1:
			_env = CG.environment(true, false, false)
		2:
			_env = CG.environment(true, true, false)
		3:
			_env = CG.environment(true, true, true)
		_:
			_env = CG.environment(true, true, true)
			get_viewport().scaling_3d_scale = 1.0
	add_child(_env)


func extra_fields(_p_index: int) -> Dictionary:
	return {"scale": get_viewport().scaling_3d_scale}
