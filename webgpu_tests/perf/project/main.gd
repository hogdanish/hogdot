## Router for the hogdot perf bed.
##
## Picks a scene from `?scene=<key>` on web (`-- --scene=<key>` natively), hands it every other
## query parameter as `params`, and adds it to the tree. Every scene extends `bench_scene.gd`,
## builds itself in code, and prints `[CGBENCH]` lines the runner parses. No scene file needs
## importing, so the same project exports from a 4.6 editor and a 4.7 editor alike.
extends Node

const SCENES := {
	"world": "res://scenes/world.gd",
	"sprites3d": "res://scenes/sprites3d.gd",
	"particles": "res://scenes/particles.gd",
	"draws": "res://scenes/draws.gd",
	"ui": "res://scenes/ui.gd",
	"postfx": "res://scenes/postfx.gd",
	"shadows": "res://scenes/shadows.gd",
	"spawn": "res://scenes/spawn.gd",
}


func _ready() -> void:
	var params := _params()
	var key := String(params.get("scene", "world"))
	if not SCENES.has(key):
		push_error("[CGBENCH] FAIL unknown scene '%s' (have %s)" % [key, ", ".join(SCENES.keys())])
		get_tree().quit(1)
		return
	var script: GDScript = load(SCENES[key])
	var scene: Node = script.new()
	scene.set("params", params)
	scene.name = key
	add_child(scene)


## Query string on web, `--k=v` user args natively. Values are strings; scenes coerce.
func _params() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			var kv := arg.trim_prefix("--").split("=", true, 1)
			out[kv[0]] = kv[1] if kv.size() > 1 else ""
	if OS.has_feature("web"):
		var raw: Variant = JavaScriptBridge.eval(
			"JSON.stringify(Object.fromEntries(new URLSearchParams(location.search)))", true
		)
		if raw != null:
			var parsed: Variant = JSON.parse_string(String(raw))
			if parsed is Dictionary:
				out.merge(parsed, true)
	return out
