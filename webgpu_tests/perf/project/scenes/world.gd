## `world` — the composite CommonGrounds-shaped frame: full environment stack, sun shadows,
## props, puppets in SubViewports, soft particles with omni bursts, water, HUD, orbiting camera.
##
## Params: chars (40) vp (600) particles (12) lights (6) props (120) hud (40) water (1)
##         puppet_always (1: SubViewports update every frame; 0: when visible)
extends "res://bench_scene.gd"

const CG := preload("res://cg.gd")

var _cam: Camera3D
var _lights: Array[OmniLight3D] = []
var _labels: Array[Label] = []
var _props: Array[MeshInstance3D] = []
var _t := 0.0


func _init() -> void:
	bench_name = "world"


func enter_phase(_p_index: int) -> void:
	add_child(CG.environment(true, true, true))
	add_child(CG.sun(true))
	_cam = CG.camera(Vector3(0, 9, 22), Vector3(0, 1, 0))
	add_child(_cam)
	add_child(CG.ground(80.0))

	var mats := CG.materials(24)
	_props = CG.props(self, pint("props", 120), 44.0, mats)

	var chars := pint("chars", 40)
	var vp := pint("vp", 600)
	var always := pint("puppet_always", 1) == 1
	var body := CG.sprite_frames(8, 128, Color(0.85, 0.3, 0.3))
	var head := CG.sprite_frames(8, 128, Color(0.95, 0.75, 0.6))
	var side := int(ceil(sqrt(float(chars))))
	for i in chars:
		var p := CG.puppet(vp, body, head, always)
		p.position = Vector3((i % side - side / 2) * 2.2, 0.0, (i / side - side / 2) * 2.2 + 2.0)
		add_child(p)

	var blob_a := CG.blob(64, Color(0.9, 0.9, 0.9))
	var blob_b := CG.blob(64, Color(1.0, 0.6, 0.2))
	var emitters := pint("particles", 12)
	for i in emitters:
		var p := CG.particles(64, blob_b if i % 2 == 0 else blob_a, i % 2 == 0)
		p.position = Vector3(sin(i * 1.7) * 14.0, 0.5, cos(i * 1.7) * 10.0)
		add_child(p)
	for i in pint("lights", 6):
		var l := OmniLight3D.new()
		l.omni_range = 7.0
		l.light_energy = 2.0
		l.light_color = Color.from_hsv(float(i) / 6.0, 0.6, 1.0)
		l.position = Vector3(sin(i * 1.1) * 12.0, 2.0, cos(i * 1.1) * 8.0)
		add_child(l)
		_lights.append(l)

	if pint("water", 1) == 1:
		var w := CG.water(30.0)
		w.position = Vector3(0, 0.25, -6.0)
		add_child(w)

	var hud := CG.hud(pint("hud", 40))
	add_child(hud)
	for n in hud.get_child(0).get_children():
		if n is Label:
			_labels.append(n)


func tick(delta: float) -> void:
	_t += delta
	var r := 22.0
	_cam.look_at_from_position(Vector3(sin(_t * 0.15) * r, 9.0, cos(_t * 0.15) * r), Vector3(0, 1, 0), Vector3.UP)
	for i in _lights.size():
		var l := _lights[i]
		l.position.x = sin(_t * 0.8 + i) * 12.0
		l.light_energy = 1.0 + sin(_t * 3.0 + i) * 0.8
	for i in _labels.size():
		_labels[i].text = "HP %d" % int(fmod(_t * 37.0 + i * 13, 100.0))
	for i in range(0, _props.size(), 5):
		_props[i].rotation.y += delta


func extra_fields(_p_index: int) -> Dictionary:
	return {
		"chars": pint("chars", 40),
		"vp": pint("vp", 600),
		"particles": pint("particles", 12),
		"props": pint("props", 120),
	}
