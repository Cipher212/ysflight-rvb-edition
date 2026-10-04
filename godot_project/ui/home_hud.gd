extends Control

# Tactical HUD overlay for the home screen: corner brackets, rolling compass tape,
# and subtle background tactical coordinate grid.
# Ported directly from C:\rvb\site\css\home.css and C:\rvb\site\js\page-home.js.

const FONT_ACES := preload("res://ui/fonts/ACES07_Regular.ttf")

const CORNER_LEN := 46.0
const CORNER_MARGIN := 24.0
const TAPE_WIDTH := 380.0
const TAPE_HEIGHT := 28.0
const DEG_STEP_PX := 26.0 # pixels per 10 degrees

var _time: float = 0.0
var _heading: float = 0.0

func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE

func _process(delta: float) -> void:
	_time += delta
	# Sweeps gently left and right like on the website
	_heading = wrapf(38.0 + 42.0 * sin(_time * 0.11) + 16.0 * sin(_time * 0.37 + 1.0), 0.0, 360.0)
	queue_redraw()

func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 10.0 or h <= 10.0:
		return

	_draw_tactical_grid(w, h)
	_draw_corner_brackets(w, h)
	_draw_compass_tape(w, h)

func _draw_tactical_grid(w: float, h: float) -> void:
	var grid_step := 56.0
	var grid_col := Color(0.67, 0.75, 1.0, 0.032)
	var max_y := h * 0.65

	# Vertical grid lines
	var x := 0.0
	while x <= w:
		draw_line(Vector2(x, 0), Vector2(x, max_y), grid_col, 1.0)
		x += grid_step

	# Horizontal grid lines with fading alpha
	var y := 0.0
	while y <= max_y:
		var alpha := (1.0 - y / max_y) * 0.04
		var c := grid_col
		c.a = alpha
		draw_line(Vector2(0, y), Vector2(w, y), c, 1.0)
		y += grid_step

func _draw_corner_brackets(w: float, h: float) -> void:
	var col := Color(0.90, 0.93, 1.0, 0.35)
	var m := CORNER_MARGIN
	var l := CORNER_LEN

	# Top-Left
	draw_line(Vector2(m, m + l), Vector2(m, m), col, 2.0)
	draw_line(Vector2(m, m), Vector2(m + l, m), col, 2.0)

	# Top-Right
	draw_line(Vector2(w - m - l, m), Vector2(w - m, m), col, 2.0)
	draw_line(Vector2(w - m, m), Vector2(w - m, m + l), col, 2.0)

	# Bottom-Left
	draw_line(Vector2(m, h - m - l), Vector2(m, h - m), col, 2.0)
	draw_line(Vector2(m, h - m), Vector2(m + l, h - m), col, 2.0)

	# Bottom-Right
	draw_line(Vector2(w - m - l, h - m), Vector2(w - m, h - m), col, 2.0)
	draw_line(Vector2(w - m, h - m), Vector2(w - m, h - m - l), col, 2.0)

func _draw_compass_tape(w: float, _h: float) -> void:
	var cx := w * 0.5
	var cy := 52.0
	var half_w := TAPE_WIDTH * 0.5

	# Window clipping area bounds
	var x_left := cx - half_w
	var x_right := cx + half_w

	# Faint border on top/bottom of tape window
	var border_col := Color(0.86, 0.90, 1.0, 0.16)
	draw_line(Vector2(x_left, cy - 14), Vector2(x_right, cy - 14), border_col, 1.0)
	draw_line(Vector2(x_left, cy + 14), Vector2(x_right, cy + 14), border_col, 1.0)

	# Draw tick marks & headings within visible window
	# Tape offset: current heading is centered at cx
	var base_deg := floorf(_heading / 10.0) * 10.0
	for deg_offset in range(-200, 210, 10):
		var cur_deg := base_deg + float(deg_offset)
		var diff := cur_deg - _heading
		var tx := cx + diff * (DEG_STEP_PX / 10.0)
		if tx < x_left - 10.0 or tx > x_right + 10.0:
			continue

		var norm_deg := int(wrapf(cur_deg, 0.0, 360.0))
		var is_major := (norm_deg % 30 == 0)
		var tick_h := 12.0 if is_major else 6.0

		var edge_dist := minf(tx - x_left, x_right - tx)
		var fade := clampf(edge_dist / 40.0, 0.0, 1.0)
		var tick_col := Color(0.85, 0.90, 1.0, (0.75 if is_major else 0.40) * fade)
		draw_line(Vector2(tx, cy + 13 - tick_h), Vector2(tx, cy + 13), tick_col, 1.0)

		if is_major and fade > 0.1:
			var label_str: String = ""
			match norm_deg:
				0: label_str = "N"
				90: label_str = "E"
				180: label_str = "S"
				270: label_str = "W"
				_: label_str = "%02d" % (norm_deg / 10)
			var text_col := Color(0.86, 0.91, 1.0, 0.9 * fade)
			draw_string(FONT_ACES, Vector2(tx - 6, cy - 2), label_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 11, text_col)

	# Central indicator triangle pointing up
	var tri_pts := PackedVector2Array([
		Vector2(cx, cy + 14),
		Vector2(cx - 5, cy + 22),
		Vector2(cx + 5, cy + 22)
	])
	draw_colored_polygon(tri_pts, Color(0.9, 0.94, 1.0, 0.85))

	# Dynamic 3-digit heading readout box
	var box_rect := Rect2(cx - 24, cy + 24, 48, 20)
	draw_rect(box_rect, Color(0.02, 0.04, 0.09, 0.85), true)
	draw_rect(box_rect, Color(0.90, 0.93, 1.0, 0.5), false, 1.0)
	var hdg_str := "%03d" % int(_heading)
	draw_string(FONT_ACES, Vector2(cx - 14, cy + 38), hdg_str, HORIZONTAL_ALIGNMENT_CENTER, -1, 13, Color.WHITE)
