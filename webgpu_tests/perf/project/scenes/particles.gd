## `particles` — ramp of GPUParticles3D soft-particle bursts (proximity fade reads the depth
## texture; half additive, half alpha-mix) with a few unshadowed omni lights, like CommonGrounds'
## explosion/hit/smoke VFX.
##
## Params: steps (8,32,96) amount (64) lights (6)
extends "res://bench_scene.gd"

const CG := preload("res://cg.gd")

var _steps: Array[int] = [8, 32, 96]
var _spawned := 0
var _blob_a: ImageTexture
var _blob_b: ImageTexture
var _t := 0.0
var _lights: Array[OmniLight3D] = []


func _init() -> void:
	bench_name = "particles"


func phase_count() -> int:
	return _steps.size()


func phase_label(p_index: int) -> String:
	return "emitters%d" % _steps[p_index]


func enter_phase(p_index: int) -> void:
	if p_index == 0:
		if params.has("steps"):
			_steps.clear()
			for s in String(params["steps"]).split(","):
				_steps.append(int(s))
		add_child(CG.environment(true, true, true))
		add_child(CG.sun(false))
		add_child(CG.camera(Vector3(0, 8, 20), Vector3(0, 1, 0)))
		add_child(CG.ground(60.0))
		CG.props(self, 40, 30.0, CG.materials(8))
		_blob_a = CG.blob(64, Color(0.9, 0.9, 0.9))
		_blob_b = CG.blob(64, Color(1.0, 0.6, 0.2))
		for i in pint("lights", 6):
			var l := OmniLight3D.new()
			l.omni_range = 6.0
			l.light_energy = 2.0
			l.light_color = Color.from_hsv(float(i) / 6.0, 0.6, 1.0)
			add_child(l)
			_lights.append(l)
	var amount := pint("amount", 64)
	var side := 12
	while _spawned < _steps[p_index]:
		var i := _spawned
		var p := CG.particles(amount, _blob_b if i % 2 == 0 else _blob_a, i % 2 == 0)
		p.position = Vector3((i % side - side / 2) * 2.4, 0.4, (i / side) * 2.4 - 6.0)
		add_child(p)
		_spawned += 1


func tick(delta: float) -> void:
	_t += delta
	for i in _lights.size():
		_lights[i].position = Vector3(sin(_t * 0.9 + i) * 10.0, 1.5, cos(_t * 0.7 + i * 1.3) * 6.0)


func extra_fields(p_index: int) -> Dictionary:
	return {"emitters": _steps[p_index], "amount": pint("amount", 64)}
