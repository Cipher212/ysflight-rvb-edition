extends Control

# Wireframe terrain flyby (home screen background), ported from C:\rvb\site\js\fx-terrain.js.
# Continuous forward flight over procedural low-poly islands, mountains, flat sea,
# airfield island (runway, hangars, tower, ships), carrier group, and rotating wind turbines.
# Uses PackedVector2Array and batch drawing for optimal 60+ FPS performance.

const SPEED := 60.0
const CAM_Y := 250.0
const CAM_X := 45.0
const CS := 90.0
const DZ := 90.0
const NEAR := 10.0
const ROWS := 24
const COLS := 42
const FAR_Z := ROWS * DZ

const AF_EVERY := 110
const AF_FIRST := 16
const AF_LEN := 13
const AF_COL := -7
const AF_H := 40.0
const QUAY_H := 14.0

const NV_EVERY := 150
const NV_FIRST := 46
const NV_LEN := 10

const TURBINES_CHANCE := 0.018
const SUN_DIR := Vector3(-0.6, 0.7, -0.35)

const COLOR_RED := Color(1.0, 0.43, 0.39)
const COLOR_PALE := Color(0.69, 0.75, 0.88)
const COLOR_BLUE := Color(0.43, 0.57, 1.0)
const SEA_COLOR := Color(0.031, 0.063, 0.102)
const RUNWAY_COLOR := Color(0.106, 0.122, 0.153)
const RUNWAY_MARK := Color(0.875, 0.894, 0.933)

var _cz: float = 0.0
var _time: float = 0.0
var _cache: Dictionary = {}
var _sun: Vector3 = SUN_DIR.normalized()
var _land_colors: Array[Color] = []
var _made_colors: Array[Color] = []

func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	for s in range(7):
		var t := float(s) / 6.0
		_land_colors.append(Color(
			lerpf(0.031, 0.118, t),
			lerpf(0.059, 0.180, t),
			lerpf(0.071, 0.169, t)
		))
		_made_colors.append(Color(
			lerpf(0.063, 0.204, t),
			lerpf(0.078, 0.227, t),
			lerpf(0.110, 0.282, t)
		))

func _process(delta: float) -> void:
	_cz += delta * SPEED
	_time += delta
	queue_redraw()

func _hash_noise(i: int, j: int) -> float:
	var h := (i * 374761393 + j * 668265263) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return float(h ^ (h >> 16)) / 2147483648.0

func _smooth_noise(u: float, v: float) -> float:
	var i := int(floorf(u))
	var j := int(floorf(v))
	var fu := u - float(i)
	var fv := v - float(j)
	fu = fu * fu * (3.0 - 2.0 * fu)
	fv = fv * fv * (3.0 - 2.0 * fv)
	var a := _hash_noise(i, j)
	var b := _hash_noise(i + 1, j)
	var c := _hash_noise(i, j + 1)
	var d := _hash_noise(i + 1, j + 1)
	return a + (b - a) * fu + (c - a) * fv + (a - b - c + d) * fu * fv

func _cycle(j: int, first: int, every: int) -> int:
	var k := j - first
	return k - int(floorf(float(k) / float(every))) * every

func _height(i: int, j: int) -> float:
	var k := _cycle(j, AF_FIRST, AF_EVERY)
	var di := i - AF_COL
	if k <= AF_LEN and di >= -1 and di <= 2:
		return AF_H
	if k >= 5 and k <= 9 and i >= -4 and i <= -2:
		return QUAY_H
	if k >= 2 and k <= AF_LEN - 1 and i >= -1 and i <= 3:
		return 0.0
	if _cycle(j, NV_FIRST, NV_EVERY) <= NV_LEN and i >= 3 and i <= 13:
		return 0.0

	var n := _smooth_noise(float(i) / 10.0 + 7.0, float(j) / 10.0) * 0.62 \
		+ _smooth_noise(float(i) / 4.0 + 31.0, float(j) / 4.0 + 17.0) * 0.28 \
		+ _hash_noise(i, j) * 0.10
	var land := (n - 0.52) / 0.48
	if (k <= AF_LEN + 3 or k >= AF_EVERY - 3) and di >= -4 and di <= 5:
		land = maxf(land, 0.22)
	return minf(220.0, 18.0 + pow(land, 1.4) * 290.0) if land > 0.0 else 0.0

func _get_row(j: int) -> PackedFloat32Array:
	if _cache.has(j):
		return _cache[j]
	var r := PackedFloat32Array()
	r.resize(COLS + 1)
	var half := COLS / 2
	for c in range(COLS + 1):
		r[c] = _height(c - half, j)
	_cache[j] = r
	return r

func _project(j: int, d: float, h: PackedFloat32Array, cx: float, hz: float, f: float) -> Dictionary:
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	xs.resize(COLS + 1)
	ys.resize(COLS + 1)
	var half := COLS / 2
	var inv_d := f / d
	for c in range(COLS + 1):
		xs[c] = cx + (float(c - half) * CS - CAM_X) * inv_d
		ys[c] = hz + (CAM_Y - h[c]) * inv_d
	return {"j": j, "d": d, "h": h, "xs": xs, "ys": ys}

func _proj_pt(p: Vector3, cx: float, hz: float, f: float) -> Vector2:
	var d := p.z - _cz
	return Vector2(cx + (p.x - CAM_X) * f / d, hz + (CAM_Y - p.y) * f / d)

func _wire_color(screen_x: float, width: float, alpha: float) -> Color:
	var t := clampf(screen_x / width, 0.0, 1.0)
	var c: Color = COLOR_RED.lerp(COLOR_PALE, t * 2.0) if t < 0.5 else COLOR_PALE.lerp(COLOR_BLUE, (t - 0.5) * 2.0)
	c.a = alpha
	return c

func _shade_index(n: Vector3) -> int:
	var d := n.normalized().dot(_sun)
	return clampi(int((d * 0.5 + 0.5) * 7.0), 0, 6)

func _draw_solid_box(pos: Vector3, sz: Vector3, fog: float, cx: float, hz: float, f: float) -> void:
	if pos.z - sz.z * 0.5 <= _cz + NEAR or pos.z - _cz >= FAR_Z:
		return
	var x0 := pos.x - sz.x * 0.5
	var x1 := pos.x + sz.x * 0.5
	var y0 := pos.y
	var y1 := pos.y + sz.y
	var z0 := pos.z - sz.z * 0.5
	var z1 := pos.z + sz.z * 0.5

	var p000 := _proj_pt(Vector3(x0, y0, z0), cx, hz, f)
	var p100 := _proj_pt(Vector3(x1, y0, z0), cx, hz, f)
	var p101 := _proj_pt(Vector3(x1, y0, z1), cx, hz, f)
	var p001 := _proj_pt(Vector3(x0, y0, z1), cx, hz, f)
	var p010 := _proj_pt(Vector3(x0, y1, z0), cx, hz, f)
	var p110 := _proj_pt(Vector3(x1, y1, z0), cx, hz, f)
	var p111 := _proj_pt(Vector3(x1, y1, z1), cx, hz, f)
	var p011 := _proj_pt(Vector3(x0, y1, z1), cx, hz, f)

	var top_col: Color = _made_colors[5]
	top_col.a = fog
	var side_col: Color = _made_colors[2]
	side_col.a = fog
	var wire_col := COLOR_PALE
	wire_col.a = fog * 0.4

	# Top face
	draw_colored_polygon(PackedVector2Array([p010, p110, p111, p011]), top_col)
	# Near face
	draw_colored_polygon(PackedVector2Array([p000, p100, p110, p010]), side_col)
	draw_polyline(PackedVector2Array([p010, p110, p111, p011, p010]), wire_col, 1.0)

func _draw() -> void:
	var w := size.x
	var h_screen := size.y
	if w <= 1.0 or h_screen <= 1.0:
		return

	var cx := w * 0.5
	var hz := h_screen * 0.52
	var f := h_screen * 0.70

	var j0 := int(floorf((_cz + NEAR) / DZ))
	var rows_data: Array[Dictionary] = []

	var h0 := _get_row(j0)
	var h1 := _get_row(j0 + 1)
	var t_near := (NEAR - (float(j0) * DZ - _cz)) / DZ
	var hc := PackedFloat32Array()
	hc.resize(COLS + 1)
	for c in range(COLS + 1):
		hc[c] = h0[c] + (h1[c] - h0[c]) * t_near

	rows_data.append(_project(j0, NEAR, hc, cx, hz, f))
	for k in range(1, ROWS + 1):
		var j := j0 + k
		var d := float(j) * DZ - _cz
		rows_data.append(_project(j, d, _get_row(j), cx, hz, f))

	# Clean stale cache rows
	var stale_keys: Array = []
	for k in _cache.keys():
		if int(k) < j0 - 2:
			stale_keys.append(k)
	for k in stale_keys:
		_cache.erase(k)

	# Faint horizon line
	var horiz_col := COLOR_PALE
	horiz_col.a = 0.14
	draw_line(Vector2(0, hz), Vector2(w, hz), horiz_col, 1.0)

	var sea_lines := PackedVector2Array()
	var sea_colors := PackedColorArray()
	var land_lines := PackedVector2Array()
	var land_colors := PackedColorArray()

	# Draw bands from far to near
	for k in range(ROWS - 1, -1, -1):
		var row_a: Dictionary = rows_data[k]
		var row_b: Dictionary = rows_data[k + 1]
		var fog := clampf((FAR_Z - float(row_b.d)) / (FAR_Z * 0.55), 0.0, 1.0)
		if fog <= 0.001:
			continue

		var ha: PackedFloat32Array = row_a.h
		var hb: PackedFloat32Array = row_b.h
		var axs: PackedFloat32Array = row_a.xs
		var ays: PackedFloat32Array = row_a.ys
		var bxs: PackedFloat32Array = row_b.xs
		var bys: PackedFloat32Array = row_b.ys

		var ra := _cycle(row_a.j, AF_FIRST, AF_EVERY)
		var on_runway := ra >= 1 and ra < AF_LEN - 1
		var half_cols := COLS / 2

		for c in range(COLS):
			var ax := axs[c]
			var ay := ays[c]
			var bx := axs[c + 1]
			var by := ays[c + 1]
			var ex := bxs[c]
			var ey := bys[c]
			var fx := bxs[c + 1]
			var fy := bys[c + 1]

			if maxf(bx, fx) < 0.0 or minf(ax, ex) > w or minf(ay, minf(by, minf(ey, fy))) > h_screen:
				continue

			var h_a := ha[c]
			var h_b := ha[c + 1]
			var h_e := hb[c]
			var h_f := hb[c + 1]
			var is_sea := (h_a <= 0.0 and h_b <= 0.0 and h_e <= 0.0 and h_f <= 0.0)

			if is_sea:
				var wc := _wire_color((ax + fx) * 0.5, w, fog * 0.12)
				sea_lines.append(Vector2(ax, ay))
				sea_lines.append(Vector2(ex, ey))
				sea_colors.append(wc)

				sea_lines.append(Vector2(ex, ey))
				sea_lines.append(Vector2(fx, fy))
				sea_colors.append(wc)

				if c == COLS - 1:
					sea_lines.append(Vector2(bx, by))
					sea_lines.append(Vector2(fx, fy))
					sea_colors.append(wc)
			else:
				var cross1 := (bx - ax) * (fy - ay) - (by - ay) * (fx - ax)
				if absf(cross1) > 1.5:
					var norm1 := Vector3(-(h_b - h_a) * DZ, CS * DZ, -CS * (h_f - h_b))
					var col1: Color = _land_colors[_shade_index(norm1)]
					col1.a = fog
					draw_colored_polygon(PackedVector2Array([Vector2(ax, ay), Vector2(bx, by), Vector2(fx, fy)]), col1)

				var cross2 := (fx - ax) * (ey - ay) - (fy - ay) * (ex - ax)
				if absf(cross2) > 1.5:
					var norm2 := Vector3(-DZ * (h_f - h_e), CS * DZ, -CS * (h_e - h_a))
					var col2: Color = _land_colors[_shade_index(norm2)]
					col2.a = fog
					draw_colored_polygon(PackedVector2Array([Vector2(ax, ay), Vector2(fx, fy), Vector2(ex, ey)]), col2)

				if on_runway and (c - half_cols) == AF_COL and absf(cross1) > 1.5:
					var r_poly := PackedVector2Array([Vector2(ax, ay), Vector2(bx, by), Vector2(fx, fy), Vector2(ex, ey)])
					draw_colored_polygon(r_poly, RUNWAY_COLOR)
					var mx := (ax + bx) * 0.5
					var my := (ay + by) * 0.5
					var nx := (ex + fx) * 0.5 - mx
					var ny := (ey + fy) * 0.5 - my
					var mark_col := RUNWAY_MARK
					mark_col.a = fog * 0.7
					draw_line(Vector2(mx + nx * 0.25, my + ny * 0.25), Vector2(mx + nx * 0.75, my + ny * 0.75), mark_col, 1.5)

				var lwc := _wire_color((ax + fx) * 0.5, w, fog * 0.32)
				land_lines.append(Vector2(ax, ay))
				land_lines.append(Vector2(ex, ey))
				land_colors.append(lwc)

				land_lines.append(Vector2(ex, ey))
				land_lines.append(Vector2(fx, fy))
				land_colors.append(lwc)

				if c == COLS - 1:
					land_lines.append(Vector2(bx, by))
					land_lines.append(Vector2(fx, fy))
					land_colors.append(lwc)

		# Scenery: airfield hangars & tower when near airfield island
		if ra >= 3 and ra <= 8:
			var z_af := float(row_a.j) * DZ
			if ra == 4:
				_draw_solid_box(Vector3(-675.0, AF_H, z_af), Vector3(56.0, 24.0, 66.0), fog, cx, hz, f) # Hangar 1
			elif ra == 6:
				_draw_solid_box(Vector3(-675.0, AF_H, z_af), Vector3(56.0, 24.0, 66.0), fog, cx, hz, f) # Hangar 2
				_draw_solid_box(Vector3(-495.0, AF_H, z_af), Vector3(14.0, 48.0, 14.0), fog, cx, hz, f) # Control Tower
			elif ra == 7:
				_draw_solid_box(Vector3(20.0, 0.0, z_af), Vector3(24.0, 16.0, 120.0), fog, cx, hz, f)   # Destroyer moored

		# Scenery: naval carrier group in open water
		var r_nv := _cycle(row_a.j, NV_FIRST, NV_EVERY)
		if r_nv >= 2 and r_nv <= 8:
			var z_nv := float(row_a.j) * DZ
			if r_nv == 5:
				_draw_solid_box(Vector3(720.0, 0.0, z_nv), Vector3(64.0, 22.0, 260.0), fog, cx, hz, f) # Carrier
				_draw_solid_box(Vector3(745.0, 22.0, z_nv - 20.0), Vector3(14.0, 24.0, 36.0), fog, cx, hz, f) # Carrier Island
			elif r_nv == 3:
				_draw_solid_box(Vector3(470.0, 0.0, z_nv), Vector3(20.0, 12.0, 130.0), fog, cx, hz, f) # Escort 1
			elif r_nv == 7:
				_draw_solid_box(Vector3(960.0, 0.0, z_nv), Vector3(18.0, 11.0, 110.0), fog, cx, hz, f) # Escort 2

		# Scenery: wind turbines on high ridge ground
		if k % 2 == 0:
			for tc in range(half_cols - 16, half_cols + 16, 2):
				var j_idx: int = row_a.j
				if ha[tc] > 115.0 and _hash_noise((tc - half_cols) * 3 + 101, j_idx * 7 + 57) < TURBINES_CHANCE:
					var base_pt := Vector2(axs[tc], ays[tc])
					var inv_turb_d := f / float(row_a.d)
					var hub_y := ays[tc] - 90.0 * inv_turb_d
					var hub_pt := Vector2(axs[tc], hub_y)
					var turb_col := COLOR_PALE
					turb_col.a = fog * 0.5
					draw_line(base_pt, hub_pt, turb_col, 1.0)
					var blade_len := 42.0 * inv_turb_d
					for b in range(3):
						var ang: float = _time * 0.8 + float(tc) * 1.5 + float(b) * 2.094
						var tip := hub_pt + Vector2(cos(ang) * blade_len, sin(ang) * blade_len)
						draw_line(hub_pt, tip, turb_col, 1.0)

	# Batch draw wireframe lines
	if sea_lines.size() >= 2:
		draw_multiline_colors(sea_lines, sea_colors, 1.0)
	if land_lines.size() >= 2:
		draw_multiline_colors(land_lines, land_colors, 1.0)
