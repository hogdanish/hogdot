## `sprites3d` — ramp of CommonGrounds puppets: one SubViewport (default 600×600) rendering
## AnimatedSprite2D layers, shown on two billboard Sprite3Ds (body + outline). Each puppet is
## at least one extra render pass per frame plus two alpha-scissor draws.
##
## Params: steps (0,27,81,162) vp (600) puppet_always (1)
extends "res://bench_scene.gd"

const CG := preload("res://cg.gd")

var _steps: Array[int] = [0, 27, 81, 162]
var _body: SpriteFrames
var _head: SpriteFrames
var _spawned := 0


func _init() -> void:
	bench_name = "sprites3d"


func phase_count() -> int:
	return _steps.size()


func phase_label(p_index: int) -> String:
	return "chars%d" % _steps[p_index]


func enter_phase(p_index: int) -> void:
	if p_index == 0:
		if params.has("steps"):
			_steps.clear()
			for s in String(params["steps"]).split(","):
				_steps.append(int(s))
		add_child(CG.environment(false, false, false))
		add_child(CG.sun(true))
		add_child(CG.camera(Vector3(0, 12, 26), Vector3(0, 1, 0)))
		add_child(CG.ground(60.0))
		_body = CG.sprite_frames(8, 128, Color(0.85, 0.3, 0.3))
		_head = CG.sprite_frames(8, 128, Color(0.95, 0.75, 0.6))
	var vp := pint("vp", 600)
	var always := pint("puppet_always", 1) == 1
	var side := 18
	while _spawned < _steps[p_index]:
		var i := _spawned
		var p := CG.puppet(vp, _body, _head, always)
		p.position = Vector3((i % side - side / 2) * 1.6, 0.0, (i / side) * 1.8 - 6.0)
		add_child(p)
		_spawned += 1


func extra_fields(p_index: int) -> Dictionary:
	return {"chars": _steps[p_index], "vp": pint("vp", 600)}
