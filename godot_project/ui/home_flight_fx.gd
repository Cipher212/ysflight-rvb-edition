extends Control

# 2D Jet flybys, dogfights, afterburner trails, missiles, and flares for the home screen.
# Ported directly from C:\rvb\site\js\fx-flight.js.
# Features traced poster jet silhouettes, Catmull-Rom flight splines, afterburners,
# and choreographed ambient dogfight scenarios (formation, chase, missiles, lock reticles).

signal intro_merged

const FONT_ACES := preload("res://ui/fonts/ACES07_Regular.ttf")

const TEAM_BLUE := {
	"light": Color("#9db8ff"),
	"main": Color("#2f62ff"),
	"deep": Color("#0c2bbf"),
	"glow": Color(0.31, 0.51, 1.0, 0.7),
	"name": "BLUE"
}
const TEAM_RED := {
	"light": Color("#ffa08a"),
	"main": Color("#ff2d2d"),
	"deep": Color("#a30000"),
	"glow": Color(1.0, 0.27, 0.22, 0.7),
	"name": "RED"
}

var _poly_blue: PackedVector2Array = []
var _poly_red: PackedVector2Array = []

var _jets: Array = []
var _missiles: Array = []
var _tracers: Array = []
var _flares: Array = []
var _booms: Array = []
var _reticles: Array = []

var _clock: float = 0.0
var _next_scenario_at: float = 4.0
var _last_team: String = "red"
var _intro_active: bool = false
var _intro_callback: Callable = Callable()

class CatmullSpline extends RefCounted:
	var total: float = 0.0
	var samples: Array[Vector2] = []
	var lengths: PackedFloat32Array = []

	func build(pts: Array[Vector2]) -> void:
		if pts.size() < 2:
			return
		var p: Array[Vector2] = [pts[0]]
		p.append_array(pts)
		p.append(pts[-1])
		samples.clear()
		for i in range(1, p.size() - 2):
			var p0: Vector2 = p[i - 1]
			var p1: Vector2 = p[i]
			var p2: Vector2 = p[i + 1]
			var p3: Vector2 = p[i + 2]
			for s in range(24):
				var t := float(s) / 24.0
				var t2 := t * t
				var t3 := t2 * t
				var pt := 0.5 * (2.0 * p1 + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
				samples.append(pt)
		samples.append(pts[-1])

		lengths.clear()
		lengths.append(0.0)
		for j in range(1, samples.size()):
			var seg := samples[j].distance_to(samples[j - 1])
			lengths.append(lengths[j - 1] + seg)
		total = lengths[-1]

	func at(u: float) -> Dictionary:
		var s := clampf(u, 0.0, 1.0) * total
		var lo := 0
		var hi := lengths.size() - 1
		while hi - lo > 1:
			var m := (lo + hi) >> 1
			if lengths[m] < s:
				lo = m
			else:
				hi = m
		var span := lengths[hi] - lengths[lo]
		var f := (s - lengths[lo]) / (span if span > 0.001 else 1.0)
		var a_pt := samples[lo]
		var b_pt := samples[hi]
		var pos := a_pt.lerp(b_pt, f)
		var ang := (b_pt - a_pt).angle()
		return {"pos": pos, "angle": ang}

class JetInstance extends RefCounted:
	var team: String = "blue"
	var size: float = 100.0
	var speed: float = 600.0
	var spline: CatmullSpline = null
	var dur: float = 1.0
	var t: float = 0.0
	var trail: Array[Dictionary] = []
	var trail_life: float = 1.2
	var trail_w: float = 8.0
	var bank: float = 0.0
	var prev_ang: float = 0.0
	var has_prev_ang: bool = false
	var pos: Vector2 = Vector2.ZERO
	var angle: float = 0.0
	var dead: bool = false
	var done: bool = false
	var on_cross: Callable = Callable()
	var cross_at: float = 0.5
	var crossed: bool = false

func _init() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_init_polygons()

func _init_polygons() -> void:
	var b_coords := [-6.5, -29.1, -5.6, -28.8, -7.4, -28.2, -14.1, -28.0, -11.5, -23.5, -1.9, -23.6, 2.1, -22.6, 1.9, -21.6, -0.2, -21.3, -10.3, -21.0, -8.5, -17.5, -0.4, -17.4, 2.1, -16.6, 2.0, -15.8, -0.8, -15.2, -7.0, -14.9, -4.4, -10.2, -0.8, -10.0, 2.1, -9.2, 4.2, -7.4, 8.5, -7.0, 11.8, -3.8, 23.6, -4.0, 36.4, -3.4, 49.2, -1.5, 50.0, -0.2, 49.8, 0.6, 48.4, 1.6, 33.8, 3.7, 11.9, 3.8, 8.7, 6.9, 4.4, 7.3, 0.9, 9.7, -4.4, 10.1, -6.7, 15.0, 0.4, 15.3, 2.1, 15.8, 2.0, 16.7, -0.6, 17.4, -8.2, 17.4, -10.3, 20.9, 0.9, 21.5, 2.1, 21.8, 2.2, 22.7, -2.0, 23.5, -11.8, 23.6, -13.9, 28.2, -7.6, 28.0, -5.7, 28.5, -5.6, 29.1, -20.4, 29.0, -22.9, 6.2, -31.8, 5.4, -38.4, 15.0, -42.2, 15.1, -43.0, 4.9, -46.5, 4.0, -49.6, 4.0, -49.9, -3.2, -49.6, -4.0, -45.1, -4.1, -43.0, -4.8, -42.2, -15.1, -38.3, -14.8, -32.3, -5.4, -22.8, -6.1, -20.3, -27.1, -20.6, -29.0]
	var r_coords := [-22.7, 34.7, -23.8, 34.6, -23.7, 32.9, -1.4, 8.4, -0.2, 6.5, -4.9, 5.8, -19.0, 5.4, -38.6, 17.5, -40.6, 18.5, -42.5, 18.6, -45.4, 17.2, -45.5, 16.5, -35.4, 3.5, -36.3, 1.5, -39.4, 0.4, -46.8, -0.1, -48.4, 0.3, -50.0, -0.2, -39.2, -0.4, -36.2, -1.6, -35.4, -3.5, -45.6, -16.9, -42.8, -18.5, -39.2, -18.0, -19.6, -5.6, -10.9, -5.5, -0.2, -6.4, -0.4, -7.3, -3.4, -10.7, -23.4, -32.9, -24.0, -34.0, -23.3, -34.7, -16.1, -35.6, -11.8, -34.5, 9.2, -19.5, 15.7, -18.8, 15.5, -17.6, 13.0, -16.9, 21.7, -10.9, 26.1, -10.2, 26.1, -9.1, 25.0, -8.7, 29.1, -5.7, 43.8, -5.2, 49.7, -3.5, 49.6, 3.7, 43.3, 5.5, 29.3, 5.7, 25.0, 8.6, 26.1, 9.6, 26.0, 10.3, 21.5, 11.2, 13.2, 16.9, 15.5, 17.6, 15.7, 18.8, 9.1, 19.7, -12.1, 34.5, -17.7, 35.5]
	for i in range(0, b_coords.size(), 2):
		_poly_blue.append(Vector2(b_coords[i], b_coords[i + 1]))
	for i in range(0, r_coords.size(), 2):
		_poly_red.append(Vector2(r_coords[i], r_coords[i + 1]))

func play_intro(on_merged: Callable = Callable()) -> void:
	_intro_active = true
	_intro_callback = on_merged
	_jets.clear()
	_missiles.clear()
	_tracers.clear()
	_flares.clear()
	_booms.clear()
	_reticles.clear()

	var w := size.x if size.x > 1.0 else 1920.0
	var h := size.y if size.y > 1.0 else 1080.0
	var center := Vector2(w * 0.48, h * 0.42)

	var b_pts: Array[Vector2] = [
		center + Vector2(-1200, 480),
		center + Vector2(-580, 240),
		center,
		center + Vector2(580, -240),
		center + Vector2(1200, -480)
	]
	var r_pts: Array[Vector2] = [
		center + Vector2(1200, -340),
		center + Vector2(580, -140),
		center,
		center + Vector2(-580, 140),
		center + Vector2(-1200, 340)
	]

	var j_blue := _spawn_jet("blue", b_pts, 280.0, 1600.0, 0.0)
	j_blue.cross_at = 0.5
	j_blue.on_cross = func() -> void:
		_trigger_sonic_boom(center)
		intro_merged.emit()
		if _intro_callback.is_valid():
			_intro_callback.call()

	var j_red := _spawn_jet("red", r_pts, 280.0, 1600.0, 0.0)
	_next_scenario_at = _clock + 4.5

func skip_intro() -> void:
	_intro_active = false
	_jets.clear()
	_missiles.clear()
	_tracers.clear()
	_flares.clear()
	_booms.clear()
	_reticles.clear()
	_next_scenario_at = _clock + 1.5

func _trigger_sonic_boom(pos: Vector2) -> void:
	_booms.append({"pos": pos, "t": 0.0, "life": 0.8, "r_max": 240.0})

func _spawn_jet(team: String, pts: Array[Vector2], jet_size: float, speed: float, delay: float) -> JetInstance:
	var j := JetInstance.new()
	j.team = team
	j.size = jet_size
	j.speed = speed
	j.t = -delay
	j.spline = CatmullSpline.new()
	j.spline.build(pts)
	j.dur = j.spline.total / speed
	_jets.append(j)
	return j

func _process(delta: float) -> void:
	_clock += delta

	if _clock >= _next_scenario_at and not _intro_active:
		_run_ambient_scenario()

	# Update jets
	var keep_jets: Array = []
	for j_item in _jets:
		var j: JetInstance = j_item
		j.t += delta
		var u := j.t / j.dur
		if u >= 0.0 and u <= 1.0 and not j.dead:
			var res: Dictionary = j.spline.at(u)
			j.pos = res.pos
			j.angle = res.angle
			if j.has_prev_ang and delta > 0.0:
				var da := wrapf(j.angle - j.prev_ang, -PI, PI)
				j.bank = lerpf(j.bank, clampf(da / delta * 0.45, -1.0, 1.0), delta * 5.0)
			j.prev_ang = j.angle
			j.has_prev_ang = true

			var tl := j.size * 0.46
			var tail_pt := j.pos - Vector2(cos(j.angle), sin(j.angle)) * tl
			j.trail.append({"pos": tail_pt, "t": j.t})

			if j.on_cross.is_valid() and not j.crossed and u >= j.cross_at:
				j.crossed = true
				j.on_cross.call()
		else:
			j.pos = Vector2(-9999, -9999)

		while j.trail.size() > 0 and (j.t - float(j.trail[0]["t"])) > j.trail_life:
			j.trail.pop_front()

		if (u > 1.0 or j.dead) and j.trail.is_empty():
			j.done = true
		if not j.done:
			keep_jets.append(j)
	_jets = keep_jets

	# Update tracers
	var keep_tracers: Array = []
	for tr in _tracers:
		tr.pos += tr.vel * delta
		tr.t += delta
		if tr.t < tr.life:
			keep_tracers.append(tr)
	_tracers = keep_tracers

	# Update flares
	var keep_flares: Array = []
	for fl in _flares:
		fl.pos += fl.vel * delta
		fl.vel *= 0.95
		fl.t += delta
		if fl.t < fl.life:
			keep_flares.append(fl)
	_flares = keep_flares

	# Update missiles
	var keep_missiles: Array = []
	for m in _missiles:
		m.t += delta
		if not m.dead:
			var m_pos: Vector2 = m.pos
			var target_pos: Vector2 = m.target.pos if is_instance_valid(m.target) and not m.target.dead else m_pos + Vector2(cos(float(m.ang)), sin(float(m.ang))) * 200.0
			var diff: Vector2 = target_pos - m_pos
			var target_ang: float = diff.angle()
			var da := wrapf(target_ang - float(m.ang), -PI, PI)
			m.ang += clampf(da, -3.2 * delta, 3.2 * delta)
			m.speed = minf(1300.0, float(m.speed) + 1200.0 * delta)
			var old_pos: Vector2 = m_pos
			m.pos = m_pos + Vector2(cos(float(m.ang)), sin(float(m.ang))) * float(m.speed) * delta
			m.smoke.append({"pos": old_pos, "t": m.t})

			if diff.length() < 24.0 or m.t >= m.life:
				m.dead = true
				_trigger_sonic_boom(m.pos)
				if diff.length() < 24.0 and is_instance_valid(m.target):
					m.target.dead = true
					_spawn_flares(m.pos, 8)

		while m.smoke.size() > 0 and (m.t - float(m.smoke[0]["t"])) > 1.4:
			m.smoke.pop_front()
		if not (m.dead and m.smoke.is_empty()):
			keep_missiles.append(m)
	_missiles = keep_missiles

	# Update sonic booms
	var keep_booms: Array = []
	for b in _booms:
		b.t += delta
		if b.t < b.life:
			keep_booms.append(b)
	_booms = keep_booms

	# Update reticles
	var keep_reticles: Array = []
	for r in _reticles:
		r.t += delta
		if r.t < r.life and is_instance_valid(r.jet) and not r.jet.dead:
			keep_reticles.append(r)
	_reticles = keep_reticles

	queue_redraw()

func _spawn_flares(pos: Vector2, count: int) -> void:
	for i in range(count):
		var ang := randf_range(0, TAU)
		var sp := randf_range(80, 240)
		_flares.append({
			"pos": pos,
			"vel": Vector2(cos(ang), sin(ang)) * sp,
			"t": 0.0,
			"life": randf_range(0.8, 1.4)
		})

func _run_ambient_scenario() -> void:
	var w := size.x if size.x > 1.0 else 1920.0
	var h := size.y if size.y > 1.0 else 1080.0
	_last_team = "blue" if _last_team == "red" else "red"

	var scn_type := randi() % 4
	if scn_type == 0:
		# Formation flyby (3 aircraft)
		var dir := 1.0 if randf() < 0.5 else -1.0
		var x0 := -200.0 if dir > 0.0 else w + 200.0
		var x1 := w + 200.0 if dir > 0.0 else -200.0
		var base_y := randf_range(h * 0.55, h * 0.85)
		var pts: Array[Vector2] = [
			Vector2(x0, base_y),
			Vector2(lerpf(x0, x1, 0.35), base_y - randf_range(20, 60)),
			Vector2(lerpf(x0, x1, 0.70), base_y + randf_range(10, 40)),
			Vector2(x1, base_y - randf_range(10, 50))
		]
		var sp := randf_range(480, 580)
		for i in range(3):
			var offset := Vector2(-dir * float(i) * 22.0, float(i) * 36.0)
			var cur_pts: Array[Vector2] = []
			for p in pts:
				cur_pts.append(p + offset)
			_spawn_jet(_last_team, cur_pts, randf_range(88, 102), sp, float(i) * 0.16)
		_next_scenario_at = _clock + 8.0
	elif scn_type == 1:
		# High speed crossing pass
		var y := randf_range(h * 0.15, h * 0.35)
		var pts_a: Array[Vector2] = [Vector2(-200, y + 80), Vector2(w * 0.5, y), Vector2(w + 200, y - 60)]
		var pts_b: Array[Vector2] = [Vector2(w + 200, y - 40), Vector2(w * 0.5, y + 10), Vector2(-200, y + 50)]
		_spawn_jet("blue", pts_a, 76.0, 750.0, 0.0)
		_spawn_jet("red", pts_b, 76.0, 750.0, 0.0)
		_next_scenario_at = _clock + 6.5
	elif scn_type == 2:
		# Dogfight Chase (Lead + Chaser + Tracers + Missile)
		var dir := 1.0 if randf() < 0.5 else -1.0
		var x0 := -200.0 if dir > 0.0 else w + 200.0
		var x1 := w + 200.0 if dir > 0.0 else -200.0
		var base_y := randf_range(h * 0.60, h * 0.80)
		var pts_lead: Array[Vector2] = [
			Vector2(x0, base_y),
			Vector2(lerpf(x0, x1, 0.30), base_y - 70),
			Vector2(lerpf(x0, x1, 0.60), base_y + 40),
			Vector2(x1, base_y - 40)
		]
		var lead_team := _last_team
		var chaser_team := "red" if lead_team == "blue" else "blue"
		var j_lead := _spawn_jet(lead_team, pts_lead, 100.0, 480.0, 0.0)

		var pts_chaser: Array[Vector2] = []
		for p in pts_lead:
			pts_chaser.append(p + Vector2(-dir * 70.0, 15.0))
		var j_chase := _spawn_jet(chaser_team, pts_chaser, 100.0, 490.0, 0.25)

		# Reticle and gun burst
		get_tree().create_timer(1.2).timeout.connect(func() -> void:
			if is_instance_valid(j_lead) and not j_lead.dead and is_instance_valid(j_chase):
				_reticles.append({"jet": j_lead, "t": 0.0, "life": 1.6})
				for b in range(6):
					get_tree().create_timer(float(b) * 0.05).timeout.connect(func() -> void:
						if is_instance_valid(j_chase):
							var t_ang := j_chase.angle + randf_range(-0.04, 0.04)
							_tracers.append({
								"pos": j_chase.pos,
								"vel": Vector2(cos(t_ang), sin(t_ang)) * 1400.0,
								"t": 0.0,
								"life": 0.45
							})
					)
		)

		# Missile launch + flare deployment
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			if is_instance_valid(j_lead) and not j_lead.dead and is_instance_valid(j_chase):
				_missiles.append({
					"pos": j_chase.pos,
					"ang": j_chase.angle,
					"speed": 550.0,
					"target": j_lead,
					"t": 0.0,
					"life": 2.2,
					"dead": false,
					"smoke": []
				})
				get_tree().create_timer(0.45).timeout.connect(func() -> void:
					if is_instance_valid(j_lead) and not j_lead.dead:
						_spawn_flares(j_lead.pos, 10)
				)
		)
		_next_scenario_at = _clock + 9.0
	else:
		# Supersonic low pass across bottom
		var dir := 1.0 if randf() < 0.5 else -1.0
		var x0 := -300.0 if dir > 0.0 else w + 300.0
		var x1 := w + 300.0 if dir > 0.0 else -300.0
		var y := randf_range(h * 0.78, h * 0.92)
		var pts: Array[Vector2] = [Vector2(x0, y + 40), Vector2(w * 0.5, y - 30), Vector2(x1, y - 120)]
		_spawn_jet(_last_team, pts, 180.0, 1400.0, 0.0)
		_next_scenario_at = _clock + 7.5

func _draw() -> void:
	# Draw afterburner trails
	for j_item in _jets:
		var j: JetInstance = j_item
		if j.trail.size() < 2:
			continue
		var team_col: Color = TEAM_BLUE.glow if j.team == "blue" else TEAM_RED.glow
		for i in range(1, j.trail.size()):
			var p0: Vector2 = j.trail[i - 1]["pos"]
			var p1: Vector2 = j.trail[i]["pos"]
			var pt_t: float = float(j.trail[i]["t"])
			var age: float = (j.t - pt_t) / j.trail_life
			var k: float = 1.0 - age
			var col := team_col
			col.a *= k * k * 0.6
			draw_line(p0, p1, col, j.trail_w * (1.0 + age * 2.0))
			var core_col := Color(1.0, 0.95, 0.85, k * 0.7)
			draw_line(p0, p1, core_col, maxf(1.5, j.trail_w * 0.25))

	# Draw missile smoke trails
	for m in _missiles:
		for sm in m.smoke:
			var age: float = (float(m.t) - float(sm["t"])) / 1.4
			var sc := Color(0.85, 0.88, 0.94, (1.0 - age) * 0.35)
			draw_circle(sm["pos"], 2.0 + age * 8.0, sc)
		if not m.dead:
			var m_dir := Vector2(cos(m.ang), sin(m.ang))
			draw_line(m.pos, m.pos - m_dir * 12.0, Color(1.0, 0.95, 0.9), 2.0)
			draw_circle(m.pos - m_dir * 12.0, 3.5, Color(1.0, 0.5, 0.1, 0.9))

	# Draw cannon tracers
	for tr in _tracers:
		var v_dir: Vector2 = tr.vel.normalized()
		draw_line(tr.pos, tr.pos - v_dir * 26.0, Color(1.0, 0.95, 0.4, 0.9), 2.0)

	# Draw flares
	for fl in _flares:
		var age := float(fl.t) / float(fl.life)
		var flare_col := Color(1.0, 0.85, 0.4, (1.0 - age) * 0.9)
		draw_circle(fl.pos, 3.0, flare_col)
		draw_circle(fl.pos, 1.2, Color.WHITE)

	# Draw jet silhouettes
	for j_item in _jets:
		var j: JetInstance = j_item
		if j.pos.x < -400.0 or j.pos.x > size.x + 400.0 or j.dead:
			continue
		var poly: PackedVector2Array = _poly_blue if j.team == "blue" else _poly_red
		var scale_val := j.size / 100.0
		var pitch_scale := maxf(0.45, cos(j.bank))

		var xform := Transform2D(j.angle, j.pos)
		var transformed := PackedVector2Array()
		transformed.resize(poly.size())
		for idx in range(poly.size()):
			var local := Vector2(poly[idx].x * scale_val, poly[idx].y * scale_val * pitch_scale)
			transformed[idx] = xform * local

		var body_col: Color = TEAM_BLUE.main if j.team == "blue" else TEAM_RED.main
		draw_colored_polygon(transformed, body_col)
		var wire_col := Color(0.9, 0.94, 1.0, 0.65)
		draw_polyline(transformed, wire_col, 1.0)

		# Afterburner nozzle glow
		var tail_offset := Vector2(-j.size * 0.46, 0.0)
		var nozzle_pos := xform * tail_offset
		var flame_col := Color(1.0, 0.65, 0.2, 0.9)
		draw_circle(nozzle_pos, j.size * 0.09, flame_col)
		draw_circle(nozzle_pos, j.size * 0.04, Color(1.0, 0.98, 0.9, 1.0))

	# Draw lock reticles
	for r in _reticles:
		var jet: JetInstance = r.jet
		if not is_instance_valid(jet) or jet.dead or jet.pos.x < -100.0:
			continue
		var s: float = jet.size * 0.6
		var col := Color(1.0, 0.3, 0.25, 0.85) if jet.team == "blue" else Color(0.3, 0.6, 1.0, 0.85)
		var p := jet.pos
		var c := s * 0.35
		# Corner box around target
		draw_line(Vector2(p.x - s, p.y - s), Vector2(p.x - s + c, p.y - s), col, 1.5)
		draw_line(Vector2(p.x - s, p.y - s), Vector2(p.x - s, p.y - s + c), col, 1.5)
		draw_line(Vector2(p.x + s, p.y - s), Vector2(p.x + s - c, p.y - s), col, 1.5)
		draw_line(Vector2(p.x + s, p.y - s), Vector2(p.x + s, p.y - s + c), col, 1.5)
		draw_line(Vector2(p.x - s, p.y + s), Vector2(p.x - s + c, p.y + s), col, 1.5)
		draw_line(Vector2(p.x - s, p.y + s), Vector2(p.x - s, p.y + s - c), col, 1.5)
		draw_line(Vector2(p.x + s, p.y + s), Vector2(p.x + s - c, p.y + s), col, 1.5)
		draw_line(Vector2(p.x + s, p.y + s), Vector2(p.x + s, p.y + s - c), col, 1.5)
		# Lock text
		draw_string(FONT_ACES, Vector2(p.x + s + 8, p.y - 4), "LOCK " + jet.team.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
		draw_string(FONT_ACES, Vector2(p.x + s + 8, p.y + 10), "1.8 NM", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)

	# Draw sonic booms
	for b in _booms:
		var prog := float(b.t) / float(b.life)
		var r := prog * float(b.r_max)
		var alpha := (1.0 - prog) * 0.8
		var boom_col := Color(1.0, 1.0, 1.0, alpha)
		draw_arc(b.pos, r, 0.0, TAU, 32, boom_col, 3.0)
		var halo_col := Color(0.6, 0.8, 1.0, alpha * 0.4)
		draw_arc(b.pos, r * 0.7, 0.0, TAU, 24, halo_col, 2.0)
