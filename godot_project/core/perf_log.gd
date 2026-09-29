extends RefCounted

# Per-section frame timings (GDScript side), summarised into crashlog/latest_run.txt every 300 frames next to
# the C++ PERF lines. main.gd measures the sections; this only accumulates and writes.

const SECTIONS := ["camera", "fetch", "effects", "hud", "audio"]
const FRAMES_PER_LINE := 300

var _sim: YSFlightSimulation = null
var _sum := PackedInt64Array()
var _max := PackedInt64Array()
var _frames: int = 0
var _start_tick: int = 0
var _start_usec: int = 0

func _init(sim: YSFlightSimulation) -> void:
	_sim = sim
	_sum.resize(SECTIONS.size())
	_max.resize(SECTIONS.size())

# One value (microseconds) per entry of SECTIONS.
func add_frame(us: PackedInt64Array) -> void:
	if _frames == 0:
		_start_tick = Engine.get_physics_frames()
		_start_usec = Time.get_ticks_usec()
	for i in SECTIONS.size():
		_sum[i] += us[i]
		_max[i] = maxi(_max[i], us[i])
	_frames += 1
	if _frames >= FRAMES_PER_LINE:
		_write()

func _write() -> void:
	var secs: float = maxf((Time.get_ticks_usec() - _start_usec) / 1e6, 0.001)
	var parts := PackedStringArray()
	for i in SECTIONS.size():
		parts.append("%s %.2f/%.2f" % [SECTIONS[i], _sum[i] / float(_frames) / 1000.0, _max[i] / 1000.0])
	_sim.log_to_crashlog("PERF GD (avg/max ms per frame): " + " | ".join(parts))
	var fx: PackedInt32Array = _sim.get_effects_stats()
	_sim.log_to_crashlog("PERF FRAME: fps %.1f | physics ticks per frame %.2f | draw calls %d | objects %d | nodes %d | primitives %d | trail segments %d | tracers %d" % [
		_frames / secs, float(Engine.get_physics_frames() - _start_tick) / _frames,
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)), fx[0], fx[2]])
	_sum.fill(0)
	_max.fill(0)
	_frames = 0
