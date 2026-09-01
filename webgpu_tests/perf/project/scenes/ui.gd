## `ui` — CanvasLayer HUD ramp over a light 3D scene, with `hdr_2d` on as CommonGrounds has it.
## Labels change text every frame (relayout + glyph re-upload), panels and texture rects are
## static.
##
## Params: steps (64,256,1024)
extends "res://bench_scene.gd"

const CG := preload("res://cg.gd")

var _steps: Array[int] = [64, 256, 1024]
var _layer: CanvasLayer
var _labels: Array[Label] = []
var _t := 0.0


func _init() -> void:
	bench_name = "ui"


func phase_count() -> int:
	return _steps.size()


func phase_label(p_index: int) -> String:
	return "widgets%d" % _steps[p_index]


func enter_phase(p_index: int) -> void:
	if p_index == 0:
		if params.has("steps"):
			_steps.clear()
			for s in String(params["steps"]).split(","):
				_steps.append(int(s))
		add_child(CG.environment(true, false, false))
		add_child(CG.sun(false))
		add_child(CG.camera(Vector3(0, 6, 16), Vector3(0, 1, 0)))
		add_child(CG.ground(40.0))
		CG.props(self, 30, 20.0, CG.materials(8))
	if _layer:
		_layer.queue_free()
	_labels.clear()
	_layer = CG.hud(_steps[p_index])
	add_child(_layer)
	for n in _layer.get_child(0).get_children():
		if n is Label:
			_labels.append(n)


func tick(delta: float) -> void:
	_t += delta
	for i in _labels.size():
		_labels[i].text = "HP %d" % int(fmod(_t * 37.0 + i * 13, 100.0))


func extra_fields(p_index: int) -> Dictionary:
	return {"widgets": _steps[p_index]}
