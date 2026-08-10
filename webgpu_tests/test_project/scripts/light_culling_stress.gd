## Per-mesh area-light culling stress scene (GH-107234, plus the fork's batch-split fix).
##
## Three identical boxes A, B and C share one BoxMesh and one StandardMaterial3D and are added
## consecutively, so the Mobile renderer's instance-batching predicate
## (`render_forward_mobile.cpp:2756-2848`) sees them as merge candidates. They differ only in how
## many AreaLight3D nodes reach them:
##
##   A   0 area lights  -> shader_count_for() bucket NONE
##   B   1 area light   -> bucket SINGLE, cyan, B's only real illumination
##   C  10 area lights  -> bucket MULTIPLE, 8 near warm-white + 2 far magenta
##
## Every area light sets uses_softshadow unconditionally (renderer_scene_cull.cpp:1795), so the
## batch predicate's use_soft_shadow clause already separates A from any area-lit neighbor. The
## RL-046 area_light_count clause is what separates B (SINGLE) from C (MULTIPLE): the pair agree
## on soft shadows and every other count. B and C share a depth bucket (A sits nearer, alone),
## and within a bucket the render list runs in reverse creation order (probe-verified
## 2026-08-10), so B is CREATED LAST below to lead any wrongly merged B+C batch: the merge then
## bakes B's one-light loop bound and C loses seven of its eight lights. Reproduced 2026-08-10
## on a fix-reverted build -- C dims to a faint gradient with no error anywhere.
##
## What to look for, in order of what each failure means:
##
##   - C shows no magenta. MAX_RDL_CULL is 8 and the 8 near lights score about 3x better than
##     the magenta pair, so the culler must discard exactly those two. Magenta on C means the
##     wrong lights were kept; a dark C means too few were.
##   - C is bright warm. A dim C is the RL-046 regression: without the area_light_count bucket
##     check, B+C merge and C's sc_area_lights loop bound bakes to B's single light.
##   - B is lit cyan. Its one light is cull-masked to render layer 2, which only B carries; a
##     dark B means the light_cull_mask x layers path broke.
##
## The RESULT line's instances field is RenderingServer render info, which forward-mobile fills
## with the visible instance count (render_forward_mobile.cpp:965) -- it cannot see batching.
##
## Relevance is `distance(mesh_center, light_aabb_center) / (range * energy)`, lower wins
## (`renderer_scene_cull.cpp:3049-3054`), and a light's AABB center sits half a range in front of
## it (`scene/3d/light_3d.cpp:180-187`). `_relevance_score()` recomputes it from the live nodes and
## fails the run if a magenta light ever outscores a near one, so editing a position below cannot
## silently invert the ranking this scene depends on.
##
## Per-mesh culling is Mobile-only -- `RenderForwardClustered::get_max_lights_per_mesh()` returns 0
## -- so the RESULT line carries the active rendering method. This project runs forward_plus
## natively and mobile on web.
##
## Bounded by default: renders FRAMES_TO_RENDER frames, prints one RESULT line, quits. Pass
## `-- --hold` natively or `?hold` in the URL on web to keep it on screen instead.

extends Node3D

const FRAMES_TO_RENDER := 10
## `MAX_RDL_CULL`, `render_forward_mobile.h:62` -- the per-mesh cap this scene overshoots on C.
const MAX_RDL_CULL := 8
const REPORT_PREFIX := "[LIGHT_CULLING]"

const BOX_SIZE := 3.0
## A sits at the origin, B at -BOX_X (pushed back by BOX_B_Z), C at +BOX_X. Wide enough that
## every light's pairing AABB (half-extent `area_size / 2 + area_range`) reaches exactly one
## box. BOX_B_Z keeps B in C's depth bucket while the reverse-creation tiebreak (see header)
## makes B the representative of any wrongly merged batch.
const BOX_X := 12.0
const BOX_B_Z := -2.0
const CAMERA_Z := 13.0

const LAYER_ALL := 0xFFFFFFFF
const LAYER_SHARED := 1 << 0
const LAYER_B_ONLY := 1 << 1

const COLOR_CYAN := Color(0.2, 0.85, 1.0)
const COLOR_WARM := Color(1.0, 0.93, 0.82)
const COLOR_MAGENTA := Color(1.0, 0.0, 1.0)

const NEAR_RANGE := 6.0
const NEAR_ENERGY := 1.2
const NEAR_ATTENUATION := 2.0
const NEAR_RING_RADIUS := 1.8
const NEAR_Z := 3.0

const FAR_RANGE := 8.0
const FAR_ENERGY := 0.5
## A far light keeps close to full brightness across its whole range at attenuation 0.0, so a
## wrongly kept magenta light is unmistakable. Attenuation is absent from the relevance score,
## which is why brightness can be tuned here without moving any light's rank.
const FAR_ATTENUATION := 0.0
const FAR_Y := 2.2
const FAR_Z := 6.0

const C_NEAR_COUNT := 8
const C_FAR_COUNT := 2

var _frame_count := 0
var _hold := false
var _errors: Array[String] = []
var _masked_light_count := 0
var _b_lights: Array[AreaLight3D] = []
var _c_near_lights: Array[AreaLight3D] = []
var _c_far_lights: Array[AreaLight3D] = []


## Whether to keep the scene on screen after reporting instead of quitting.
## Pass `?hold` in the URL on web, or `-- --hold` natively.
func _wants_hold() -> bool:
	if "--hold" in OS.get_cmdline_user_args():
		return true
	if OS.has_feature("web"):
		# Ask for a number, not a boolean. `JavaScriptBridge.eval` hands a JS `true` back as a
		# Variant of type FLOAT, so a `typeof(res) == TYPE_BOOL` guard rejects every hold request.
		var res: Variant = JavaScriptBridge.eval(
			"location.search.indexOf('hold') >= 0 ? 1 : 0", true
		)
		return res != null and bool(res)
	return false


func _ready() -> void:
	_hold = _wants_hold()
	print("%s Building the per-mesh area-light culling stress scene..." % REPORT_PREFIX)

	_setup_environment()
	_setup_camera()
	_setup_instances()
	_setup_b_lights()
	_setup_c_lights()
	_check_relevance_ranking()

	print("%s Scene built. Rendering %d frames..." % [REPORT_PREFIX, FRAMES_TO_RENDER])


func _process(_delta: float) -> void:
	_frame_count += 1
	if _frame_count < FRAMES_TO_RENDER:
		return
	_report()
	if _hold:
		print("%s Holding for inspection - the scene keeps rendering." % REPORT_PREFIX)
		set_process(false)
		return
	get_tree().quit(0 if _errors.is_empty() else 1)


# ═══════════════════════════════════════════════════════════════════════════════
# SCENE
# ═══════════════════════════════════════════════════════════════════════════════


## Flat background and a dim ambient fill, so an unlit face is still a readable silhouette.
## No glow, no DOF (no CameraAttributes at all) and no sky: every one of those would mix light
## into the boxes from somewhere other than the area lights under test.
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.04)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.65)
	env.ambient_light_energy = 0.12
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.glow_enabled = false

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	print("  [OK] Environment: flat background, dim ambient fill, no glow, no DOF")


func _setup_camera() -> void:
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.position = Vector3(0.0, 0.0, CAMERA_Z)
	camera.current = true
	add_child(camera)

	# TAA blends neighbouring frames, which would smear the single frame the report reads.
	get_viewport().use_taa = false

	print("  [OK] Camera: head-on at z=%.1f, TAA off" % CAMERA_Z)


## One BoxMesh and one StandardMaterial3D for all three instances, assigned as `material_override`
## so the batching predicate compares the same surface and the same material uniform set and has
## nothing but the area-light bucket left to split on.
func _setup_instances() -> void:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(BOX_SIZE, BOX_SIZE, BOX_SIZE)

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.8, 0.8, 0.8)
	material.roughness = 0.85
	material.metallic = 0.0

	_add_box("BoxA", Vector3(0.0, 0.0, 0.0), LAYER_SHARED, mesh, material)
	_add_box("BoxC", Vector3(BOX_X, 0.0, 0.0), LAYER_SHARED, mesh, material)
	_add_box("BoxB", Vector3(-BOX_X, 0.0, BOX_B_Z), LAYER_SHARED | LAYER_B_ONLY, mesh, material)

	print("  [OK] Instances: A/B/C consecutive, one shared BoxMesh and StandardMaterial3D")
	print("       B also carries render layer 2, which one of its lights is masked to.")


func _add_box(
	p_name: String,
	p_position: Vector3,
	p_layers: int,
	p_mesh: BoxMesh,
	p_material: StandardMaterial3D
) -> void:
	var instance := MeshInstance3D.new()
	instance.name = p_name
	instance.mesh = p_mesh
	instance.material_override = p_material
	instance.position = p_position
	instance.layers = p_layers
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


# ═══════════════════════════════════════════════════════════════════════════════
# LIGHTS
# ═══════════════════════════════════════════════════════════════════════════════


## Shadows stay off on every light: this is a data-path test, and a shadow pass would add a second
## batching decision on top of the colour-pass one under test.
func _add_area_light(
	p_name: String,
	p_position: Vector3,
	p_color: Color,
	p_energy: float,
	p_range: float,
	p_attenuation: float,
	p_cull_mask: int
) -> AreaLight3D:
	var light := AreaLight3D.new()
	light.name = p_name
	light.position = p_position
	light.light_color = p_color
	light.light_energy = p_energy
	light.area_size = Vector2(1.0, 1.0)
	light.area_range = p_range
	light.area_attenuation = p_attenuation
	light.shadow_enabled = false
	light.light_cull_mask = p_cull_mask
	add_child(light)
	if p_cull_mask != LAYER_ALL:
		_masked_light_count += 1
	return light


## B's one cyan light, cull-masked to render layer 2 -- the layer only B carries
## (`renderer_scene_cull.cpp:3041` tests `light_cull_mask` against the instance's `layers`
## before scoring). One light keeps B in shader_count_for bucket SINGLE, one bucket away from
## C with use_soft_shadow equal: the pair only the RL-046 clause can split. The light's pairing
## AABB stops 2.6 units short of A.
func _setup_b_lights() -> void:
	_b_lights.append(
		_add_area_light(
			"AreaB0",
			Vector3(-BOX_X, 1.2, BOX_B_Z + NEAR_Z),
			COLOR_CYAN,
			NEAR_ENERGY,
			NEAR_RANGE,
			NEAR_ATTENUATION,
			LAYER_B_ONLY
		)
	)

	print("  [OK] B: 1 cyan area light, cull mask %d (B's second render layer)" % LAYER_B_ONLY)


## C's ten candidates: a tight ring of 8 warm lights that the culler must keep, and 2 magenta
## lights placed farther out and given a lower range-times-energy product so they lose the score
## comparison. Every one of the ten overlaps C and nothing else. Two ring lights are cull-masked
## to the shared layer 1 -- no reach change (C carries layer 1), a positive mask expectation.
func _setup_c_lights() -> void:
	for i in C_NEAR_COUNT:
		var angle := TAU * float(i) / float(C_NEAR_COUNT)
		var offset := Vector3(cos(angle), sin(angle), 0.0) * NEAR_RING_RADIUS
		_c_near_lights.append(
			_add_area_light(
				"AreaCNear%d" % i,
				Vector3(BOX_X, 0.0, NEAR_Z) + offset,
				COLOR_WARM,
				NEAR_ENERGY,
				NEAR_RANGE,
				NEAR_ATTENUATION,
				LAYER_SHARED if i < 2 else LAYER_ALL
			)
		)

	for i in C_FAR_COUNT:
		var side := 1.0 if i == 0 else -1.0
		_c_far_lights.append(
			_add_area_light(
				"AreaCFar%d" % i,
				Vector3(BOX_X, side * FAR_Y, FAR_Z),
				COLOR_MAGENTA,
				FAR_ENERGY,
				FAR_RANGE,
				FAR_ATTENUATION,
				LAYER_ALL
			)
		)

	print(
		(
			"  [OK] C: %d near warm lights + %d far magenta lights = %d candidates for %d slots"
			% [
				_c_near_lights.size(),
				_c_far_lights.size(),
				_c_near_lights.size() + _c_far_lights.size(),
				MAX_RDL_CULL
			]
		)
	)


## Mirrors `renderer_scene_cull.cpp:3049-3054`, where a lower score wins. The light's transformed
## AABB center sits half a range along its -Z (`scene/3d/light_3d.cpp:180-187`); every light here
## is unrotated and parented to a scene root at the origin, so local position is world position.
func _relevance_score(p_mesh_center: Vector3, p_light: AreaLight3D) -> float:
	var light_range: float = p_light.area_range
	var aabb_center := p_light.position + Vector3(0.0, 0.0, -light_range * 0.5)
	return p_mesh_center.distance_to(aabb_center) / maxf(0.01, light_range * p_light.light_energy)


## Fails the run if the two magenta lights are no longer the worst-scoring pair around C. Without
## this the scene could pass vacuously after a position edit, with the culler correctly keeping 8
## lights that simply happen to include a magenta one.
func _check_relevance_ranking() -> void:
	var c_center := Vector3(BOX_X, 0.0, 0.0)
	var kept_worst := 0.0
	for light in _c_near_lights:
		kept_worst = maxf(kept_worst, _relevance_score(c_center, light))
	var discarded_best := INF
	for light in _c_far_lights:
		discarded_best = minf(discarded_best, _relevance_score(c_center, light))

	if discarded_best <= kept_worst:
		var message := (
			(
				"scene misconfigured: a far magenta light scores %.3f, no worse than the %.3f of a "
				% [discarded_best, kept_worst]
			)
			+ "near light, so the expected selection is not the one this scene asserts"
		)
		_errors.append(message)
		push_error("%s %s" % [REPORT_PREFIX, message])
		return

	print(
		(
			"  [OK] Relevance around C: worst kept %.3f, best discarded %.3f, margin %.2fx"
			% [kept_worst, discarded_best, discarded_best / kept_worst]
		)
	)


# ═══════════════════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════════════════


## One machine-readable line of configured counts plus the frame's visible instance count. The
## counts are what this script built; nothing in GDScript can read back the culler's per-mesh
## selection, so the selection itself is judged from the render, per this file's header.
func _report() -> void:
	# Render info needs two rendered frames before it reports anything; FRAMES_TO_RENDER covers
	# it. Forward-mobile fills this slot with the visible instance count
	# (render_forward_mobile.cpp:965), not issued draws -- it cannot observe batching.
	var visible_instances := RenderingServer.viewport_get_render_info(
		get_viewport().get_viewport_rid(),
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
	)
	if visible_instances == 0:
		_errors.append("render info reported 0 visible instances")

	var c_total := _c_near_lights.size() + _c_far_lights.size()
	var fields := PackedStringArray()
	fields.append("frames=%d" % _frame_count)
	fields.append("method=%s" % RenderingServer.get_current_rendering_method())
	fields.append("driver=%s" % RenderingServer.get_current_rendering_driver_name())
	fields.append("max_rdl_cull=%d" % MAX_RDL_CULL)
	fields.append("a_area=0")
	fields.append("b_area=%d" % _b_lights.size())
	fields.append("c_area=%d" % c_total)
	fields.append("c_near=%d" % _c_near_lights.size())
	fields.append("c_far=%d" % _c_far_lights.size())
	fields.append("masked_lights=%d" % _masked_light_count)
	fields.append("instances=%d" % visible_instances)
	fields.append("pass=%s" % ("true" if _errors.is_empty() else "false"))

	print("%s RESULT %s" % [REPORT_PREFIX, " ".join(fields)])
	for error in _errors:
		print("%s ERROR %s" % [REPORT_PREFIX, error])
