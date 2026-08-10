## DrawableTexture2D / BlitMaterial gate -- 4.7's new texture-authoring API on WebGPU.
##
## `blit_rect()` and `blit_rect_multi()` run through `tex_blit.glsl`, a shader that is new in 4.7
## and that no browser run has ever compiled: every other new shader this port carried surfaced at
## least one Tint translation problem (RL-015, RL-020, RL-023, RL-024, RL-025), and there is no
## build-time WGSL table to fall back on any more -- every shader takes live Tint at runtime. Three
## questions, one scene:
##
##   blend modes   Blend mode is fixed-function pipeline state, not shader text
##                 (`material_storage.cpp:651`), so all five modes share one WGSL translation and
##                 differ only in the blend attachment WebGPU is handed.
##   formats       DRAWABLE_FORMAT_RGBAF is rgba32float. The driver skips the
##                 float32-filterable downgrade for render-attachment textures
##                 (`rendering_device_driver_webgpu.cpp:1803`), but a missing `float32-blendable`
##                 adapter feature makes it drop blend state silently and log
##                 `[FLOAT32-BLEND-SKIP]` (`:8525`). Either outcome passes; a validation error
##                 does not.
##   4 attachments `blit_rect_multi` binds up to four color attachments in one render pass -- the
##                 widest framebuffer this engine builds outside the renderer proper.
##
## Expected swatches, derived from `blend_mode_to_blend_attachment()` rather than guessed. Source
## is opaque red, modulate is `Color(1, 1, 1, 0.5)`, so the shader emits src = (1, 0, 0) at alpha
## 0.5 over a mid-gray (0.5, 0.5, 0.5) opaque backdrop:
##
##   MIX       (0.75, 0.25, 0.25) opaque  -- dusty pink
##   ADD       (1.0,  0.5,  0.5)  opaque  -- salmon, brighter than MIX
##   SUB       (0.0,  0.5,  0.5)  opaque  -- cyan (reverse subtract: dst - src)
##   MUL       (0.5,  0.0,  0.0)  opaque  -- dark red (src factor is DST_COLOR, dst factor ZERO)
##   DISABLED  (1.0,  0.0,  0.0)  at alpha 0.5 -- pure red, and the ONLY swatch that keeps the
##             source's alpha, because a disabled blend writes the fragment through untouched.
##             It therefore reads darker than MIX over the dark backdrop rather than brighter;
##             that alpha is the tell, not a defect.
##
## ⚠ The DISABLED expectation the design doc predicted ("hard, fully opaque red") assumed the blit
## preserved the backdrop's alpha. It does not. Corrected here from the blend-factor table.
##
## The format row blits the same red through MIX onto one texture per DrawableFormat; RGBA8_SRGB
## converts on write and is expected to read back visibly lighter than plain RGBA8. The multi row
## blits four different sources through one `blit_rect_multi` onto four same-format targets --
## target i receives source i -- so four differently coloured swatches prove all four attachments
## were written, and a black swatch means one was not.
##
## ⚠ `blit_rect_multi`'s extra targets must share the original's size AND DrawableFormat
## (doc/classes/DrawableTexture2D.xml), so the multi row cannot also be the format spread. They are
## deliberately separate rows.
##
## No 3D, no WorldEnvironment, no glow: the swatches are judged by colour and a post-process would
## change every one of them.
##
## Bounded by default: renders FRAMES_TO_RENDER frames, prints one RESULT line, quits. Pass
## `-- --hold` natively or `?hold` in the URL on web to keep the grid on screen.

extends Node

const FRAMES_TO_RENDER := 10
const REPORT_PREFIX := "[DRAWABLE_BLIT]"
const NATIVE_CAPTURE_PATH := "user://drawable_blit_native.png"

const TEXTURE_SIZE := 256
const SOURCE_SIZE := 64
const SWATCH_SIZE := 150.0
const SWATCH_GAP := 14.0
const GRID_ORIGIN := Vector2(40.0, 60.0)
const ROW_HEIGHT := SWATCH_SIZE + 46.0

const BACKDROP := Color(0.5, 0.5, 0.5, 1.0)
const MODULATE := Color(1.0, 1.0, 1.0, 0.5)

const BLEND_MODES := {
	"MIX": BlitMaterial.BLEND_MODE_MIX,
	"ADD": BlitMaterial.BLEND_MODE_ADD,
	"SUB": BlitMaterial.BLEND_MODE_SUB,
	"MUL": BlitMaterial.BLEND_MODE_MUL,
	"DISABLED": BlitMaterial.BLEND_MODE_DISABLED,
}

const FORMATS := {
	"RGBA8": DrawableTexture2D.DRAWABLE_FORMAT_RGBA8,
	"RGBA8_SRGB": DrawableTexture2D.DRAWABLE_FORMAT_RGBA8_SRGB,
	"RGBAH": DrawableTexture2D.DRAWABLE_FORMAT_RGBAH,
	"RGBAF": DrawableTexture2D.DRAWABLE_FORMAT_RGBAF,
}

const MULTI_COLORS: Array[Color] = [
	Color(1.0, 0.15, 0.15, 1.0),
	Color(0.15, 1.0, 0.15, 1.0),
	Color(0.25, 0.4, 1.0, 1.0),
	Color(1.0, 1.0, 1.0, 1.0),
]

var _frame_count := 0
var _hold := false
var _errors: Array[String] = []
var _grid: Control = null
var _blend_swatches := 0
var _format_swatches := 0
var _multi_swatches := 0


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
	print("%s Building the DrawableTexture2D blit grid..." % REPORT_PREFIX)
	print("%s user_data_dir=%s" % [REPORT_PREFIX, OS.get_user_data_dir()])

	_setup_canvas()
	_run_blend_mode_row()
	_run_format_row()
	_run_multi_target_row()

	print("%s Scene built. Rendering %d frames..." % [REPORT_PREFIX, FRAMES_TO_RENDER])


func _process(_delta: float) -> void:
	_frame_count += 1
	if _frame_count < FRAMES_TO_RENDER:
		return
	_capture_native_reference()
	_report()
	if _hold:
		print("%s Holding for inspection - the grid keeps rendering." % REPORT_PREFIX)
		set_process(false)
		return
	get_tree().quit(0 if _errors.is_empty() else 1)


# ═══════════════════════════════════════════════════════════════════════════════
# CANVAS
# ═══════════════════════════════════════════════════════════════════════════════


## An opaque dark backdrop under the grid, because one swatch (DISABLED) legitimately carries
## alpha 0.5 and would otherwise be judged against whatever the clear colour happens to be.
func _setup_canvas() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Swatches"
	add_child(layer)

	var background := ColorRect.new()
	background.name = "Backdrop"
	background.color = Color(0.08, 0.08, 0.1, 1.0)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(background)

	_grid = Control.new()
	_grid.name = "Grid"
	_grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_grid)

	print("  [OK] Canvas: opaque backdrop plus the swatch grid, no 3D and no post-processing")


func _add_swatch(p_texture: Texture2D, p_label: String, p_row: int, p_column: int) -> void:
	var origin := (
		GRID_ORIGIN
		+ Vector2(float(p_column) * (SWATCH_SIZE + SWATCH_GAP), float(p_row) * ROW_HEIGHT)
	)

	var rect := TextureRect.new()
	rect.name = "Swatch_%s" % p_label
	rect.texture = p_texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.position = origin
	rect.size = Vector2(SWATCH_SIZE, SWATCH_SIZE)
	_grid.add_child(rect)

	var label := Label.new()
	label.name = "Label_%s" % p_label
	label.text = p_label
	label.position = origin + Vector2(0.0, SWATCH_SIZE + 2.0)
	label.size = Vector2(SWATCH_SIZE, 24.0)
	_grid.add_child(label)


# ═══════════════════════════════════════════════════════════════════════════════
# SOURCES AND TARGETS
# ═══════════════════════════════════════════════════════════════════════════════


## Solid colours, not the noise textures the 3D coverage scene uses: a blend mode is judged by the
## colour it produces, and noise averages every mode into the same muddy grey.
func _make_source(p_color: Color) -> ImageTexture:
	var image := Image.create_empty(SOURCE_SIZE, SOURCE_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(p_color)
	return ImageTexture.create_from_image(image)


func _make_target(p_format: int) -> DrawableTexture2D:
	var texture := DrawableTexture2D.new()
	texture.setup(TEXTURE_SIZE, TEXTURE_SIZE, p_format, BACKDROP)
	return texture


func _full_rect() -> Rect2i:
	return Rect2i(0, 0, TEXTURE_SIZE, TEXTURE_SIZE)


# ═══════════════════════════════════════════════════════════════════════════════
# THE THREE ROWS
# ═══════════════════════════════════════════════════════════════════════════════


## Five RGBA8 targets, one blend mode each, one shared red source. Same everything else, so the
## row reads as a direct comparison of the five blend attachments.
func _run_blend_mode_row() -> void:
	var source := _make_source(Color(1.0, 0.0, 0.0, 1.0))
	var column := 0

	for mode_name in BLEND_MODES:
		var material := BlitMaterial.new()
		material.blend_mode = BLEND_MODES[mode_name]

		var target := _make_target(DrawableTexture2D.DRAWABLE_FORMAT_RGBA8)
		target.blit_rect(_full_rect(), source, MODULATE, 0, material)

		_add_swatch(target, mode_name, 0, column)
		_blend_swatches += 1
		column += 1

	print(
		(
			"  [OK] Blend row: %d modes on RGBA8, red source at modulate alpha %.1f"
			% [_blend_swatches, MODULATE.a]
		)
	)


## One target per DrawableFormat, all through MIX. RGBAF is the row that matters: it is the format
## the `float32-blendable` gap degrades, and the console says which way this adapter went.
func _run_format_row() -> void:
	var source := _make_source(Color(1.0, 0.0, 0.0, 1.0))
	var column := 0

	for format_name in FORMATS:
		var material := BlitMaterial.new()
		material.blend_mode = BlitMaterial.BLEND_MODE_MIX

		var target := _make_target(FORMATS[format_name])
		target.blit_rect(_full_rect(), source, MODULATE, 0, material)

		_add_swatch(target, format_name, 1, column)
		_format_swatches += 1
		column += 1

	print("  [OK] Format row: %d DrawableFormats through MIX" % _format_swatches)


## The 4-attachment path. All four targets share one size and one format, as the class doc
## requires, and each receives its own source colour -- target i takes source i.
func _run_multi_target_row() -> void:
	var sources: Array[Texture2D] = []
	for color in MULTI_COLORS:
		sources.append(_make_source(color))

	var primary := _make_target(DrawableTexture2D.DRAWABLE_FORMAT_RGBA8)
	var extra_targets: Array[DrawableTexture2D] = []
	for i in 3:
		extra_targets.append(_make_target(DrawableTexture2D.DRAWABLE_FORMAT_RGBA8))

	# Source count equals target count on purpose. `texture_drawable_blit_rect()` picks the shader
	# variant from `p_source_textures.size() - 1` but the pipeline from `p_textures.size()`
	# (texture_storage.cpp:1745 vs :1795), so a mismatched pair would test an engine-level
	# inconsistency instead of the 4-attachment path this row exists for.
	var material := BlitMaterial.new()
	material.blend_mode = BlitMaterial.BLEND_MODE_DISABLED
	primary.blit_rect_multi(_full_rect(), sources, extra_targets, Color.WHITE, 0, material)

	_add_swatch(primary, "MULTI 0", 2, 0)
	_multi_swatches += 1
	var column := 1
	for target in extra_targets:
		_add_swatch(target, "MULTI %d" % column, 2, column)
		_multi_swatches += 1
		column += 1

	print(
		(
			"  [OK] Multi row: one blit_rect_multi into %d attachments, %d sources"
			% [_multi_swatches, sources.size()]
		)
	)


# ═══════════════════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════════════════


## Native only -- a direct RD readback. The web side is captured with the browser tab screenshot,
## never with `getImageData`.
func _capture_native_reference() -> void:
	if OS.has_feature("web"):
		return

	var image := get_viewport().get_texture().get_image()
	if image == null:
		_errors.append("viewport readback returned no image")
		return

	var status := image.save_png(NATIVE_CAPTURE_PATH)
	if status != OK:
		_errors.append("save_png(%s) failed with error %d" % [NATIVE_CAPTURE_PATH, status])
		return

	print("%s Wrote the native reference to %s" % [REPORT_PREFIX, NATIVE_CAPTURE_PATH])


## The swatch colours themselves are judged from the render: this backend has no synchronous GPU
## readback, so nothing in GDScript can sample a DrawableTexture2D after a blit.
func _report() -> void:
	if _blend_swatches != BLEND_MODES.size():
		_errors.append(
			"built %d blend swatches, expected %d" % [_blend_swatches, BLEND_MODES.size()]
		)
	if _format_swatches != FORMATS.size():
		_errors.append("built %d format swatches, expected %d" % [_format_swatches, FORMATS.size()])
	if _multi_swatches != MULTI_COLORS.size():
		_errors.append(
			"built %d multi swatches, expected %d" % [_multi_swatches, MULTI_COLORS.size()]
		)

	var fields := PackedStringArray()
	fields.append("frames=%d" % _frame_count)
	fields.append("method=%s" % RenderingServer.get_current_rendering_method())
	fields.append("driver=%s" % RenderingServer.get_current_rendering_driver_name())
	fields.append("blend_swatches=%d" % _blend_swatches)
	fields.append("format_swatches=%d" % _format_swatches)
	fields.append("multi_swatches=%d" % _multi_swatches)
	fields.append("pass=%s" % ("true" if _errors.is_empty() else "false"))

	print("%s RESULT %s" % [REPORT_PREFIX, " ".join(fields)])
	for error in _errors:
		print("%s ERROR %s" % [REPORT_PREFIX, error])
