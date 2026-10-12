extends RefCounted

# Owner-selected Sound Revamp files, shared by all bounded voices; other effects stay stock.
var engine_bands: Array[AudioStreamWAV] = []
var burner: AudioStreamWAV
var cockpit_drone: AudioStreamWAV
var lock_on: AudioStreamWAV
var enemy_locked: AudioStreamWAV
var incoming: AudioStreamWAV
var incoming_near: AudioStreamWAV
var missile_lost: AudioStreamWAV
var prop0: AudioStreamWAV
var gun: AudioStreamWAV
var stallhorn: AudioStreamWAV
var gearhorn: AudioStreamWAV
var missile: AudioStreamWAV
var rocket: AudioStreamWAV
var bombsaway: AudioStreamWAV
var bang: AudioStreamWAV
var blast: AudioStreamWAV
var bomb_blast: AudioStreamWAV
var bomb_water: AudioStreamWAV
var legacy_bang: AudioStreamWAV
var legacy_blast: AudioStreamWAV
var crash_blast: AudioStreamWAV
var touchdwn: AudioStreamWAV
var retractldg: AudioStreamWAV
var extendldg: AudioStreamWAV
var damage: AudioStreamWAV
var hit: AudioStreamWAV
var over_g: AudioStreamWAV

func _init() -> void:
	_load_all_sounds()
	_synthesize_over_g()

func _load_sound(filename: String, is_loop: bool = false) -> AudioStreamWAV:
	var global_path := ProjectSettings.globalize_path("res://sound/" + filename)
	var stream: AudioStreamWAV = null
	stream = AudioStreamWAV.load_from_file(global_path)
	if stream == null:
		var res_path := "res://sound/" + filename
		if ResourceLoader.exists(res_path):
			stream = load(res_path) as AudioStreamWAV
	if stream != null and is_loop:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		stream.loop_end = int(stream.get_length() * stream.mix_rate)
	return stream

func _load_all_sounds() -> void:
	for band in range(10):
		engine_bands.append(_load_sound("engine%d.wav" % band, true))
	burner = _load_sound("burner.wav", true)
	cockpit_drone = _load_sound("cockpit_drone.wav", true)
	_load_warning_sounds()
	prop0 = _load_sound("prop0.wav", true)
	gun = _load_sound("gun.wav", true)
	stallhorn = _load_sound("stallhorn.wav", true)
	gearhorn = _load_sound("gearhorn.wav", true)
	missile = _load_sound("missile.wav")
	rocket = _load_sound("rocket.wav")
	bombsaway = _load_sound("bombsaway.wav")
	bang = _load_sound("bang.wav")
	blast = _load_sound("blast.wav")
	bomb_blast = _load_sound("blast2.wav")
	bomb_water = _load_sound("blast2_water.wav")
	# Replays without event metadata and aircraft crashes use the installed bank too.
	legacy_bang = bang
	legacy_blast = blast
	crash_blast = bomb_blast
	touchdwn = _load_sound("touchdwn.wav")
	retractldg = _load_sound("retractldg.wav")
	extendldg = _load_sound("extendldg.wav")
	damage = _load_sound("damage.wav")
	hit = _load_sound("hit.wav")

func _load_warning_sounds() -> void:
	enemy_locked = _load_sound("locked.wav")
	incoming = _load_sound("incoming.wav", true)
	incoming_near = _load_sound("incoming_near.wav", true)
	missile_lost = _load_sound("missile_lost.wav")
	lock_on = _load_sound("lock_on.wav", true)
	# The prepared recording contains its acquisition intro followed by the looping tone.
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://sound/missile_warning_manifest.json"))
	for entry in manifest.files:
		if entry.output == "lock_on.wav" and lock_on != null:
			lock_on.loop_begin = int(entry.loop_begin)
			lock_on.loop_end = int(entry.loop_end)

func _synthesize_over_g() -> void:
	var rate := 44100
	var amp := 32767.0 * 0.35
	# 2. Over-G warning: two-tone 1600 Hz / 1250 Hz alternating, 50 ms on / 50 ms off each
	var g_seg_samples := int(round(0.050 * rate))
	var g_total_samples := g_seg_samples * 4
	var g_fade_samples := int(round(0.005 * rate))
	var g_bytes := PackedByteArray()
	g_bytes.resize(g_total_samples * 2)

	for phase in range(4):
		var freq := 0.0
		if phase == 0:
			freq = 1600.0
		elif phase == 2:
			freq = 1250.0

		var base_idx := phase * g_seg_samples
		if freq == 0.0:
			for k in range(g_seg_samples):
				g_bytes.encode_s16((base_idx + k) * 2, 0)
		else:
			for k in range(g_seg_samples):
				var env := 1.0
				if k < g_fade_samples:
					env = float(k) / float(g_fade_samples)
				elif k >= g_seg_samples - g_fade_samples:
					env = float(g_seg_samples - 1 - k) / float(g_fade_samples)
				var t := float(k) / float(rate)
				var wave := 0.85 * sin(TAU * freq * t) + 0.15 * sin(TAU * 3.0 * freq * t)
				var val := int(clamp(wave * env * amp, -32768.0, 32767.0))
				g_bytes.encode_s16((base_idx + k) * 2, val)

	over_g = AudioStreamWAV.new()
	over_g.format = AudioStreamWAV.FORMAT_16_BITS
	over_g.stereo = false
	over_g.mix_rate = rate
	over_g.data = g_bytes
	over_g.loop_mode = AudioStreamWAV.LOOP_FORWARD
	over_g.loop_begin = 0
	over_g.loop_end = g_total_samples
