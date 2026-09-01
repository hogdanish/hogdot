## `shadows` — shadow-casting positional lights ramp over 300 props under a shadowed sun.
## Every omni light adds shadow passes and their draws (RL-048 made these real for the first
## time on this backend; this scene keeps them measured).
##
## Params: steps (0,2,4,8) props (300)
extends "res://bench_scene.gd"

const CG := preload("res://cg.gd")

var _steps: Array[int] = [0, 2, 4, 8]
var _lights: Array[OmniLight3D] = []
var _t := 0.0


func _init() -> void:
	bench_name = "shadows"


func phase_count() -> int:
	return _steps.size()


func phase_label(p_index: int) -> String:
	return "omni%d" % _steps[p_index]


func enter_phase(p_index: int) -> void:
	if p_index == 0:
		if params.has("steps"):
			_steps.clear()
			for s in String(params["steps"]).split(","):
				_steps.append(int(s))
		add_child(CG.environment(false, false, false))
		add_child(CG.sun(true))
		add_child(CG.camera(Vector3(0, 12, 28), Vector3(0, 1, 0)))
		add_child(CG.ground(60.0))
		CG.props(self, pint("props", 300), 40.0, CG.materials(12))
	while _lights.size() < _steps[p_index]:
		var i := _lights.size()
		var l := OmniLight3D.new()
		l.omni_range = 12.0
		l.light_energy = 1.5
		l.shadow_enabled = true
		l.light_color = Color.from_hsv(float(i) / 8.0, 0.5, 1.0)
		l.position = Vector3(sin(i * 0.8) * 14.0, 4.0, cos(i * 0.8) * 10.0)
		add_child(l)
		_lights.append(l)


func tick(delta: float) -> void:
	_t += delta
	for i in _lights.size():
		_lights[i].position.x = sin(_t * 0.5 + i * 0.8) * 14.0


func extra_fields(p_index: int) -> Dictionary:
	return {"omni": _steps[p_index], "props": pint("props", 300)}
