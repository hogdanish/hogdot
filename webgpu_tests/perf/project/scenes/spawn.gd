## `spawn` — the hitch scene. Each phase introduces material/shader variants the frame has never
## drawn before, mid-run, the way a VFX burst or a new vehicle does in CommonGrounds. The
## per-phase `warm_max_ms` (largest frame during the phase's warm-up) is the hitch; `compiles`
## and `compile_ms` (hogdot only) say how much of it was pipeline creation on the render thread.
##
## Phases: base → 8 new StandardMaterial feature combos → soft particles → custom shaders →
## puppets. Use `warm=15 frames=60` for a fast run; the steady numbers are not the point here.
extends "res://bench_scene.gd"

const CG := preload("res://cg.gd")
## Phases with a `_hidden` suffix add the nodes invisible, so the engine's load-time pipeline
## precompilation runs (ubershader first); the following phase makes them visible — the pattern a
## game has when it preloads a VFX scene and instantiates it later. The hitch on the reveal phase is
## what deferred pipeline creation can remove; the hitch on a same-frame create+draw it cannot.
const LABELS: Array[String] = ["base", "materials_hidden", "materials", "particles", "shaders_hidden", "shaders", "puppets"]


var _mesh: Mesh
var _n := 0
var _hidden: Array[Node3D] = []


func _init() -> void:
	bench_name = "spawn"
	warm_frames = 20
	measure_frames = 90


func phase_count() -> int:
	return LABELS.size()


func phase_label(p_index: int) -> String:
	return LABELS[p_index]


func enter_phase(p_index: int) -> void:
	match p_index:
		2, 5:
			for n in _hidden:
				n.visible = true
			_hidden.clear()
		0:
			add_child(CG.environment(true, true, true))
			add_child(CG.sun(true))
			add_child(CG.camera(Vector3(0, 8, 22), Vector3(0, 1, 0)))
			add_child(CG.ground(50.0))
			var box := BoxMesh.new()
			_mesh = box
			CG.props(self, 40, 24.0, CG.materials(6))
		1:
			# Eight feature combinations, resource-backed so the baker can serve them:
			# bit0 transparency, bit1 emission, bit2 rim; 5 also cull-disabled, 6 normal-mapped,
			# 7 clearcoat. See materials/spawn_*.tres.
			var combos: Array[StandardMaterial3D] = []
			for i in 8:
				var m: StandardMaterial3D = load("res://materials/spawn_%d.tres" % i).duplicate()
				m.albedo_color = Color.from_hsv(i / 8.0, 0.7, 0.9)
				if m.normal_enabled:
					m.normal_texture = CG.checker(32, Color(0.5, 0.5, 1.0), Color(0.6, 0.4, 1.0))
				combos.append(m)
			_place(combos)
		3:
			var blob := CG.blob(64, Color(1.0, 0.7, 0.3))
			for i in 6:
				var p := CG.particles(48, blob, i % 2 == 0)
				p.position = Vector3(i * 2.5 - 7.0, 0.5, 4.0)
				add_child(p)
		4:
			for i in 6:
				var sm: ShaderMaterial = load("res://materials/wobble_alpha.tres" if i % 2 == 1 else "res://materials/wobble.tres").duplicate()
				sm.set_shader_parameter("speed", 1.0 + i)
				sm.set_shader_parameter("tint", Color.from_hsv(i / 6.0, 0.8, 1.0))
				var inst := MeshInstance3D.new()
				inst.mesh = _mesh
				inst.material_override = sm
				inst.position = Vector3(i * 2.0 - 5.0, 1.0, -4.0)
				inst.visible = false
				_hidden.append(inst)
				add_child(inst)
		_:
			var body := CG.sprite_frames(6, 96, Color(0.3, 0.6, 0.9))
			var head := CG.sprite_frames(6, 96, Color(0.9, 0.8, 0.7))
			for i in 4:
				var p := CG.puppet(300, body, head, true)
				p.position = Vector3(i * 2.0 - 3.0, 0.0, 8.0)
				add_child(p)


func _place(p_mats: Array[StandardMaterial3D]) -> void:
	for m in p_mats:
		var inst := MeshInstance3D.new()
		inst.mesh = _mesh
		inst.material_override = m
		inst.position = Vector3(_n * 1.6 - 6.0, 1.0, 0.0)
		inst.visible = false
		_hidden.append(inst)
		add_child(inst)
		_n += 1
