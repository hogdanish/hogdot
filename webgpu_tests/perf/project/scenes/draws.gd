## `draws` — per-draw cost ramp. N props the renderer cannot merge (unique materials by default),
## rotating every frame so transforms stay dirty, under one shadowless sun. On WebGPU each draw
## is a handful of wasm→JS calls, so this is the IPC cost curve.
##
## Params: steps (128,512,2048,4096) mats (0 = one material per instance; N = N shared)
##         spin (1) shadows (0)
extends "res://bench_scene.gd"

const CG := preload("res://cg.gd")

var _steps: Array[int] = [128, 512, 2048, 4096]
var _spawned := 0
var _mats: Array[StandardMaterial3D] = []
var _insts: Array[MeshInstance3D] = []
var _mesh: Mesh
var _spin := true


func _init() -> void:
	bench_name = "draws"


func phase_count() -> int:
	return _steps.size()


func phase_label(p_index: int) -> String:
	return "n%d" % _steps[p_index]


func enter_phase(p_index: int) -> void:
	if p_index == 0:
		if params.has("steps"):
			_steps.clear()
			for s in String(params["steps"]).split(","):
				_steps.append(int(s))
		_spin = pint("spin", 1) == 1
		add_child(CG.environment(false, false, false))
		add_child(CG.sun(pint("shadows", 0) == 1))
		add_child(CG.camera(Vector3(0, 10, 34), Vector3(0, 2, 0)))
		var box := BoxMesh.new()
		box.size = Vector3(0.6, 0.6, 0.6)
		_mesh = box
		var shared := pint("mats", 0)
		if shared > 0:
			_mats = CG.materials(shared)
	var side := 24
	while _spawned < _steps[p_index]:
		var i := _spawned
		var inst := MeshInstance3D.new()
		inst.mesh = _mesh
		if _mats.is_empty():
			var m := StandardMaterial3D.new()
			m.albedo_color = Color.from_hsv(fmod(float(i) * 0.013, 1.0), 0.6, 0.9)
			inst.material_override = m
		else:
			inst.material_override = _mats[i % _mats.size()]
		inst.position = Vector3((i % side - side / 2) * 0.9, ((i / side) % side) * 0.8 - 6.0, (i / (side * side)) * -1.6)
		add_child(inst)
		_insts.append(inst)
		_spawned += 1


func tick(delta: float) -> void:
	if not _spin:
		return
	for inst in _insts:
		inst.rotation.y += delta


func extra_fields(p_index: int) -> Dictionary:
	return {"n": _steps[p_index], "mats": pint("mats", 0)}
