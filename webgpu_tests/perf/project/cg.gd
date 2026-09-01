## Builders for the CommonGrounds-shaped pieces every perf scene is assembled from.
##
## Derived 2026-09-01 from a read-only survey of commongrounds/godot: sky + glow + depth fog + AgX,
## one hard-shadow DirectionalLight3D, transient OmniLight3D bursts from VFX, GPUParticles3D with
## proximity fade (soft particles), 2D puppets rendered in 600×600 SubViewports and shown as
## billboards (two draws each: body + outline), water reading depth and screen textures, and a
## CanvasLayer HUD. Everything is procedural so the project needs no imported assets and exports
## from a 4.6 editor as well as a 4.7 one.
extends RefCounted



static func environment(p_sky: bool, p_glow: bool, p_fog: bool) -> WorldEnvironment:
	var env := Environment.new()
	if p_sky:
		var sky_mat := ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = Color(0.25, 0.45, 0.8)
		sky_mat.sky_horizon_color = Color(0.7, 0.75, 0.85)
		sky_mat.ground_bottom_color = Color(0.2, 0.17, 0.13)
		var sky := Sky.new()
		sky.sky_material = sky_mat
		env.background_mode = Environment.BG_SKY
		env.sky = sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.3, 0.4, 0.6)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.4, 0.4, 0.5)
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 2.0
	env.glow_enabled = p_glow
	env.glow_normalized = true
	env.glow_intensity = 0.18
	env.fog_enabled = p_fog
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = 20.0
	env.fog_depth_end = 90.0
	env.fog_aerial_perspective = 0.437
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.1
	env.adjustment_saturation = 1.1
	var node := WorldEnvironment.new()
	node.environment = env
	node.name = "Env"
	return node


static func sun(p_shadows: bool) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 35, 0)
	light.shadow_enabled = p_shadows
	light.directional_shadow_max_distance = 45.0
	light.directional_shadow_blend_splits = true
	light.name = "Sun"
	return light


static func camera(p_pos: Vector3, p_look: Vector3) -> Camera3D:
	var cam := Camera3D.new()
	cam.position = p_pos
	cam.far = 200.0
	cam.current = true
	cam.name = "Camera"
	cam.look_at_from_position(p_pos, p_look, Vector3.UP)
	return cam


static func ground(p_size: float) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2(p_size, p_size)
	var inst := MeshInstance3D.new()
	inst.mesh = plane
	var mat: StandardMaterial3D = load("res://materials/textured.tres").duplicate()
	mat.albedo_color = Color(0.45, 0.5, 0.35)
	mat.albedo_texture = checker(256, Color(0.5, 0.55, 0.4), Color(0.4, 0.45, 0.32))
	mat.uv1_scale = Vector3(p_size / 4.0, p_size / 4.0, 1.0)
	inst.material_override = mat
	inst.name = "Ground"
	return inst


static func checker(p_size: int, p_a: Color, p_b: Color) -> ImageTexture:
	var img := Image.create(p_size, p_size, true, Image.FORMAT_RGBA8)
	var cell := maxi(p_size / 8, 1)
	for y in p_size:
		for x in p_size:
			var on := ((x / cell) + (y / cell)) % 2 == 0
			img.set_pixel(x, y, p_a if on else p_b)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Radial soft blob, the shape a smoke/spark sprite has.
static func blob(p_size: int, p_tint: Color) -> ImageTexture:
	var img := Image.create(p_size, p_size, true, Image.FORMAT_RGBA8)
	var half := float(p_size) * 0.5
	for y in p_size:
		for x in p_size:
			var d := Vector2(x - half, y - half).length() / half
			var a := clampf(1.0 - d * d, 0.0, 1.0)
			img.set_pixel(x, y, Color(p_tint.r, p_tint.g, p_tint.b, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Procedural walk cycle: `p_frames` frames of a wobbling figure on transparent background.
static func sprite_frames(p_frames: int, p_size: int, p_tint: Color) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.set_animation_speed("default", 12.0)
	for f in p_frames:
		var img := Image.create(p_size, p_size, false, Image.FORMAT_RGBA8)
		var phase := float(f) / float(p_frames) * TAU
		var cx := float(p_size) * 0.5 + sin(phase) * float(p_size) * 0.08
		var cy := float(p_size) * 0.55 + absf(cos(phase)) * float(p_size) * 0.05
		var r := float(p_size) * 0.3
		for y in p_size:
			for x in p_size:
				var d := Vector2(x - cx, y - cy).length()
				if d < r:
					var shade := 1.0 - d / r * 0.4
					img.set_pixel(x, y, Color(p_tint.r * shade, p_tint.g * shade, p_tint.b * shade, 1.0))
				elif d < r + 2.0:
					img.set_pixel(x, y, Color(0, 0, 0, 1))
		frames.add_frame("default", ImageTexture.create_from_image(img))
	return frames


## One CommonGrounds-style puppet: a SubViewport rendering two AnimatedSprite2D layers plus a
## Sprite2D face, shown on a billboard Sprite3D, with a second Sprite3D as the outline pass.
static func puppet(p_vp: int, p_body: SpriteFrames, p_head: SpriteFrames, p_always: bool) -> Node3D:
	var root := Node3D.new()
	var vp := SubViewport.new()
	vp.size = Vector2i(p_vp, p_vp)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if p_always else SubViewport.UPDATE_WHEN_VISIBLE
	root.add_child(vp)
	var canvas := Node2D.new()
	vp.add_child(canvas)
	var body := AnimatedSprite2D.new()
	body.sprite_frames = p_body
	body.position = Vector2(p_vp * 0.5, p_vp * 0.62)
	body.scale = Vector2.ONE * (float(p_vp) / 200.0)
	body.play("default")
	canvas.add_child(body)
	var head := AnimatedSprite2D.new()
	head.sprite_frames = p_head
	head.position = Vector2(p_vp * 0.5, p_vp * 0.3)
	head.scale = Vector2.ONE * (float(p_vp) / 320.0)
	head.play("default")
	canvas.add_child(head)
	var face := Sprite2D.new()
	face.texture = p_head.get_frame_texture("default", 0)
	face.scale = Vector2.ONE * 0.3
	face.modulate = Color(1, 0.9, 0.8)
	head.add_child(face)

	var sprite := Sprite3D.new()
	sprite.texture = vp.get_texture()
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.pixel_size = 1.8 / float(p_vp)
	sprite.position.y = 0.9
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	root.add_child(sprite)
	var outline := Sprite3D.new()
	outline.texture = vp.get_texture()
	outline.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	outline.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	outline.pixel_size = sprite.pixel_size * 1.06
	outline.modulate = Color(0, 0, 0, 1)
	outline.position.y = 0.9
	outline.render_priority = -1
	outline.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	root.add_child(outline)
	return root


## A soft-particle burst: billboard quads with proximity fade (reads the depth texture).
static func particles(p_amount: int, p_tex: Texture2D, p_additive: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = p_amount
	p.lifetime = 1.6
	p.explosiveness = 0.2
	p.randomness = 0.4
	# Resource-backed (see water()): same flags as the .tres, so the baked shader serves it.
	p.process_material = load("res://materials/particle_process.tres").duplicate()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.8, 0.8)
	var mat: StandardMaterial3D = load("res://materials/particle_add.tres" if p_additive else "res://materials/particle_mix.tres").duplicate()
	mat.albedo_texture = p_tex
	quad.material = mat
	p.draw_pass_1 = quad
	return p


static func water(p_size: float) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2(p_size, p_size)
	plane.subdivide_depth = 8
	plane.subdivide_width = 8
	var inst := MeshInstance3D.new()
	inst.mesh = plane
	# Loaded, not built: the export-time shader baker only bakes shaders it finds in exported
	# resources, so every shader the bed draws with must exist as a .tres/.gdshader file.
	var mat: ShaderMaterial = load("res://materials/water.tres").duplicate()
	inst.material_override = mat
	inst.name = "Water"
	return inst


## `p_count` HUD widgets: labels, panels and texture rects on a grid.
static func hud(p_count: int) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var tex := checker(32, Color(0.9, 0.3, 0.2), Color(0.2, 0.3, 0.9))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.7)
	style.corner_radius_top_left = 6
	style.corner_radius_bottom_right = 6
	style.border_width_bottom = 2
	style.border_color = Color(0.9, 0.8, 0.3)
	var cols := 32
	for i in p_count:
		var x := float(i % cols) * 30.0 + 4.0
		var y := float(i / cols) * 16.0 + 4.0
		match i % 3:
			0:
				var l := Label.new()
				l.text = "HP %d" % i
				l.position = Vector2(x, y)
				l.add_theme_font_size_override("font_size", 10)
				l.name = "L%d" % i
				root.add_child(l)
			1:
				var p := Panel.new()
				p.add_theme_stylebox_override("panel", style)
				p.position = Vector2(x, y)
				p.size = Vector2(26, 12)
				root.add_child(p)
				var bar := ColorRect.new()
				bar.color = Color(0.3, 0.9, 0.4)
				bar.position = Vector2(2, 2)
				bar.size = Vector2(22, 8)
				bar.name = "B%d" % i
				p.add_child(bar)
			_:
				var t := TextureRect.new()
				t.texture = tex
				t.position = Vector2(x, y)
				t.size = Vector2(12, 12)
				t.stretch_mode = TextureRect.STRETCH_SCALE
				t.name = "T%d" % i
				root.add_child(t)
	return layer


## `p_count` distinct StandardMaterial3Ds covering the feature mix CommonGrounds uses.
static func materials(p_count: int) -> Array[StandardMaterial3D]:
	var out: Array[StandardMaterial3D] = []
	var tex := checker(64, Color(0.8, 0.8, 0.85), Color(0.5, 0.5, 0.6))
	# One resource-backed base per instance (feature flags decide the shader; colors, roughness
	# and metallic are parameters), duplicated so the baked shader serves every copy.
	var bases := {
		"plain": load("res://materials/plain.tres"),
		"textured": load("res://materials/textured.tres"),
		"emission": load("res://materials/emission.tres"),
		"rim": load("res://materials/rim.tres"),
	}
	for i in p_count:
		var kind := "plain"
		if i % 4 == 0:
			kind = "emission"
		elif i % 3 == 0:
			kind = "textured"
		elif i % 5 == 0:
			kind = "rim"
		var m: StandardMaterial3D = (bases[kind] as StandardMaterial3D).duplicate()
		m.albedo_color = Color.from_hsv(fmod(float(i) * 0.137, 1.0), 0.55, 0.85)
		m.roughness = 0.3 + 0.6 * fmod(float(i) * 0.31, 1.0)
		m.metallic = 0.6 if i % 7 == 0 else 0.0
		if kind == "textured":
			m.albedo_texture = tex
		elif kind == "emission":
			m.emission = m.albedo_color
		out.append(m)
	return out


static func meshes() -> Array[Mesh]:
	var box := BoxMesh.new()
	box.size = Vector3(1.2, 1.2, 1.2)
	var cyl := CylinderMesh.new()
	cyl.height = 1.6
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.6
	var sph := SphereMesh.new()
	sph.radius = 0.7
	sph.height = 1.4
	var cap := CapsuleMesh.new()
	return [box, cyl, sph, cap]


## Scatter `p_count` props on a grid of `p_span` meters, cycling meshes and materials.
static func props(p_parent: Node, p_count: int, p_span: float, p_mats: Array[StandardMaterial3D]) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var ms := meshes()
	var side := int(ceil(sqrt(float(p_count))))
	for i in p_count:
		var inst := MeshInstance3D.new()
		inst.mesh = ms[i % ms.size()]
		inst.material_override = p_mats[i % p_mats.size()]
		var gx := float(i % side) / float(maxi(side - 1, 1)) - 0.5
		var gz := float(i / side) / float(maxi(side - 1, 1)) - 0.5
		inst.position = Vector3(gx * p_span, 0.7 + (i % 3) * 0.4, gz * p_span)
		inst.rotation.y = float(i) * 0.7
		p_parent.add_child(inst)
		out.append(inst)
	return out
