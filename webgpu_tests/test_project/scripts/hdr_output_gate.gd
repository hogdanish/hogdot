## HDR display-output gate -- does an extended-range canvas actually reach the panel?
##
## The engine's HDR path is entirely 4.7's; the web backend's job is only to report the truth about
## the canvas and to hand the compositor a swap chain that can carry a value above 1.0. That makes
## the whole feature observable from one number, `Window.get_output_max_linear_value()`: it is 1.0
## when HDR is off or was refused, and the reference/max luminance ratio when it was granted.
##
## The scene is a row of emissive swatches at fixed multiples of SDR white, beside a reference quad
## at exactly `get_output_max_linear_value()`:
##
##   0.5x  1.0x  2.0x  4.0x  |  MAX
##
## On an SDR canvas everything from 1.0x up is clamped and the last three swatches are the same
## white. On a granted HDR canvas 2.0x and 4.0x are visibly brighter than 1.0x -- that difference,
## by eye on an HDR panel, is the entire acceptance test. It cannot be captured in a screenshot:
## a screenshot is an SDR image and shows all four clamped, whatever the panel is doing.
##
## ⚠ Requirements the 4.7 docs impose on any HDR scene, all satisfied below:
##   - Tonemapper must be AGX or LINEAR. FILMIC and ACES "do not support HDR output because they
##     produce output in the SDR range" (doc/classes/Environment.xml) and would clamp the swatches
##     back to white no matter what the canvas can carry.
##   - `Viewport.use_hdr_2d` must be on. `display/window/hdr/request_hdr_output` forces it for the
##     main viewport; this scene requests HDR at runtime instead of through the project setting, so
##     it sets `use_hdr_2d` itself. Every SubViewport would need its own.
##   - Glow SOFTLIGHT and colour correction do not support HDR output. Neither is used here.
##
## ⚠ `request_hdr_output` is read only at startup, so this scene calls
## `DisplayServer.window_request_hdr_output()` directly rather than shipping a project setting the
## other five gate scenes would then inherit.
##
## Bounded by default: renders FRAMES_TO_RENDER frames, prints one RESULT line, quits. Pass
## `-- --hold` natively or `?hold` in the URL on web to keep it on screen for the by-eye check --
## which on web is the only check that means anything.

extends Node

const FRAMES_TO_RENDER := 10
const REPORT_PREFIX := "[HDR_OUTPUT]"

## Multiples of SDR white. Everything at or above 1.0 is identical on an SDR canvas and must
## separate on an HDR one.
const SWATCH_MULTIPLIERS: Array[float] = [0.5, 1.0, 2.0, 4.0]

const SWATCH_SIZE := Vector2(190.0, 260.0)
const SWATCH_GAP := 18.0
const GRID_ORIGIN := Vector2(60.0, 120.0)

var _frame_count := 0
var _hold := false
var _errors: Array[String] = []
var _requested := false
var _supported := false
var _enabled := false
var _max_linear_value := 1.0


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


## `?sdr` requests no HDR at all, which is how the SDR-fallback criterion is checked: the same
## build, the same scene, one query parameter apart.
func _wants_sdr() -> bool:
	if "--sdr" in OS.get_cmdline_user_args():
		return true
	if OS.has_feature("web"):
		var res: Variant = JavaScriptBridge.eval(
			"location.search.indexOf('sdr') >= 0 ? 1 : 0", true
		)
		return res != null and bool(res)
	return false


func _ready() -> void:
	_hold = _wants_hold()
	print("%s Building the HDR output gate..." % REPORT_PREFIX)

	_request_hdr()
	_setup_viewport()
	_setup_swatches()

	print("%s Scene built. Rendering %d frames..." % [REPORT_PREFIX, FRAMES_TO_RENDER])


func _process(_delta: float) -> void:
	_frame_count += 1
	if _frame_count < FRAMES_TO_RENDER:
		return
	_report()
	if _hold:
		print("%s Holding for inspection - the swatches keep rendering." % REPORT_PREFIX)
		set_process(false)
		return
	get_tree().quit(0 if _errors.is_empty() else 1)


# ═══════════════════════════════════════════════════════════════════════════════
# SETUP
# ═══════════════════════════════════════════════════════════════════════════════


func _request_hdr() -> void:
	var want_hdr := not _wants_sdr()
	DisplayServer.window_request_hdr_output(want_hdr)

	_read_hdr_state()
	print(
		(
			"  [OK] HDR at request time: requested=%s supported=%s enabled=%s"
			% [str(_requested), str(_supported), str(_enabled)]
		)
	)


## ⚠ Read again at report time, never only at request time. `window_request_hdr_output()` sets the
## surface's flag; the canvas is not actually reconfigured until the swap chain next resizes, so
## `enabled` is still false for a frame or two afterwards. Querying once in _ready() reports a
## working HDR canvas as broken.
func _read_hdr_state() -> void:
	_supported = DisplayServer.window_is_hdr_output_supported()
	_requested = DisplayServer.window_is_hdr_output_requested()
	_enabled = DisplayServer.window_is_hdr_output_enabled()
	_max_linear_value = get_window().get_output_max_linear_value()


## `use_hdr_2d` is what keeps the 2D swatches in a float render target instead of being quantised
## to 8 bits before they ever reach the blit; without it every swatch above 1.0 is clamped inside
## the engine and the canvas never gets the chance to show the difference.
func _setup_viewport() -> void:
	get_viewport().use_hdr_2d = true
	get_viewport().use_taa = false

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.03)
	# AGX is one of the two tonemappers the 4.7 docs say support HDR output. ACES and FILMIC would
	# clamp the swatches back into the SDR range before the canvas ever saw them.
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.glow_enabled = false
	env.adjustment_enabled = false

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)

	print("  [OK] Viewport: use_hdr_2d on, AGX tonemap, no glow, no colour adjustment")


## ColorRects are drawn straight to the canvas, which is what this gate wants: the swatch values
## must reach the final blit unmodified by lighting or post-processing, so that what the eye judges
## is the canvas's range and nothing else.
func _setup_swatches() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Swatches"
	add_child(layer)

	var background := ColorRect.new()
	background.name = "Backdrop"
	background.color = Color(0.02, 0.02, 0.03, 1.0)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(background)

	var column := 0
	for multiplier in SWATCH_MULTIPLIERS:
		_add_swatch(layer, "%.1fx SDR white" % multiplier, multiplier, column)
		column += 1
	_add_swatch(layer, "MAX (%.2f)" % _max_linear_value, _max_linear_value, column)

	var caption := Label.new()
	caption.name = "Caption"
	caption.text = (
		"requested=%s  supported=%s  enabled=%s  max_linear_value=%.3f"
		% [str(_requested), str(_supported), str(_enabled), _max_linear_value]
	)
	caption.position = Vector2(GRID_ORIGIN.x, GRID_ORIGIN.y - 60.0)
	layer.add_child(caption)

	print(
		(
			"  [OK] %d swatches, max_linear_value=%.3f"
			% [SWATCH_MULTIPLIERS.size() + 1, _max_linear_value]
		)
	)


## The colour is written in LINEAR space on purpose. A `Color` above 1.0 is only meaningful before
## the sRGB encode; `use_hdr_2d` keeps it that way through the render target, and blit.glsl's
## unclamped `linear_to_srgb` carries it past 1.0 into the extended-sRGB the canvas decodes.
func _add_swatch(p_layer: CanvasLayer, p_label: String, p_value: float, p_column: int) -> void:
	var origin := GRID_ORIGIN + Vector2(float(p_column) * (SWATCH_SIZE.x + SWATCH_GAP), 0.0)

	var rect := ColorRect.new()
	rect.name = "Swatch%d" % p_column
	rect.color = Color(p_value, p_value, p_value, 1.0)
	rect.position = origin
	rect.size = SWATCH_SIZE
	p_layer.add_child(rect)

	var label := Label.new()
	label.name = "Label%d" % p_column
	label.text = p_label
	label.position = origin + Vector2(0.0, SWATCH_SIZE.y + 6.0)
	label.size = Vector2(SWATCH_SIZE.x, 24.0)
	p_layer.add_child(label)


# ═══════════════════════════════════════════════════════════════════════════════
# REPORT
# ═══════════════════════════════════════════════════════════════════════════════


## Everything a machine can check about this feature is on one line. Whether the bright swatches
## are actually brighter is a human judgment on an HDR panel and is not claimed here.
func _report() -> void:
	var want_hdr := not _wants_sdr()
	_read_hdr_state()
	if want_hdr and _supported and not _enabled:
		_errors.append("the browser reports an extended canvas is available but HDR never engaged")
	if not want_hdr and _enabled:
		_errors.append("HDR reports enabled on a run that never asked for it")
	if _enabled and _max_linear_value <= 1.0:
		(
			_errors
			. append(
				(
					"HDR reports enabled but max_linear_value is %.3f, so nothing above SDR white can be expressed"
					% _max_linear_value
				)
			)
		)
	if not _enabled and not is_equal_approx(_max_linear_value, 1.0):
		_errors.append("HDR is off but max_linear_value is %.3f instead of 1.0" % _max_linear_value)

	var fields := PackedStringArray()
	fields.append("frames=%d" % _frame_count)
	fields.append("driver=%s" % RenderingServer.get_current_rendering_driver_name())
	fields.append("requested=%s" % str(_requested))
	fields.append("supported=%s" % str(_supported))
	fields.append("enabled=%s" % str(_enabled))
	fields.append("max_linear_value=%.3f" % _max_linear_value)
	fields.append("hdr_2d=%s" % str(get_viewport().use_hdr_2d))
	fields.append("pass=%s" % ("true" if _errors.is_empty() else "false"))

	print("%s RESULT %s" % [REPORT_PREFIX, " ".join(fields)])
	for error in _errors:
		print("%s ERROR %s" % [REPORT_PREFIX, error])
