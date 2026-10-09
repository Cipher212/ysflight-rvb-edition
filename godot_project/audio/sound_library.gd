extends RefCounted

# The game's sounds: approved CC0 jet engine loops (jet_cockpit.wav by minian89,
# jet_external.wav by m_cel) and stock YSFlight .wav files from res://sound/
# (propeller loop, gun and warnings) plus two synthesized cockpit tones
# (missile lock beep, over-G warning). Loaded once by audio_manager.gd.

# Sound streams loaded at startup
var jet_cockpit: AudioStreamWAV = null
var jet_external: AudioStreamWAV = null
var prop0: AudioStreamWAV = null
var gun: AudioStreamWAV = null
var warning: AudioStreamWAV = null
var stallhorn: AudioStreamWAV = null
var gearhorn: AudioStreamWAV = null
var missile: AudioStreamWAV = null
var rocket: AudioStreamWAV = null
var bombsaway: AudioStreamWAV = null
var bang: AudioStreamWAV = null
var blast: AudioStreamWAV = null
var blast2: AudioStreamWAV = null
var touchdwn: AudioStreamWAV = null
var retractldg: AudioStreamWAV = null
var extendldg: AudioStreamWAV = null
var damage: AudioStreamWAV = null
var hit: AudioStreamWAV = null

# Backward-compatibility alias for test_runner.gd (shares jet_external without duplicate load)
var engine0: AudioStreamWAV:
	get: return jet_external

# Synthesized streams
var lock_beep: AudioStreamWAV = null
var over_g: AudioStreamWAV = null

func _init() -> void:
	_load_all_sounds()
	_synthesize_tones()

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
	jet_cockpit = _load_sound("jet_cockpit.wav", true)
	jet_external = _load_sound("jet_external.wav", true)
	prop0 = _load_sound("prop0.wav", true)
	gun = _load_sound("gun.wav", true)
	warning = _load_sound("warning.wav", true)
	stallhorn = _load_sound("stallhorn.wav", true)
	gearhorn = _load_sound("gearhorn.wav", true)

	missile = _load_sound("missile.wav", false)
	rocket = _load_sound("rocket.wav", false)
	bombsaway = _load_sound("bombsaway.wav", false)
	bang = _load_sound("bang.wav", false)
	blast = _load_sound("blast.wav", false)
	blast2 = _load_sound("blast2.wav", false)
	touchdwn = _load_sound("touchdwn.wav", false)
	retractldg = _load_sound("retractldg.wav", false)
	extendldg = _load_sound("extendldg.wav", false)
	damage = _load_sound("damage.wav", false)
	hit = _load_sound("hit.wav", false)

func _synthesize_tones() -> void:
	var rate := 44100
	var amp := 32767.0 * 0.35

	# 1. Lock-on beep: 1000 Hz sine, 90 ms on / 90 ms off, -10 dB, 5 ms fade
	var lock_on_samples := int(round(0.090 * rate))
	var lock_off_samples := int(round(0.090 * rate))
	var lock_total_samples := lock_on_samples + lock_off_samples
	var lock_fade_samples := int(round(0.005 * rate))
	var lock_bytes := PackedByteArray()
	lock_bytes.resize(lock_total_samples * 2)

	for i in range(lock_on_samples):
		var env := 1.0
		if i < lock_fade_samples:
			env = float(i) / float(lock_fade_samples)
		elif i >= lock_on_samples - lock_fade_samples:
			env = float(lock_on_samples - 1 - i) / float(lock_fade_samples)
		var t := float(i) / float(rate)
		var val := int(clamp(sin(TAU * 1000.0 * t) * env * amp, -32768.0, 32767.0))
		lock_bytes.encode_s16(i * 2, val)
	for i in range(lock_on_samples, lock_total_samples):
		lock_bytes.encode_s16(i * 2, 0)

	lock_beep = AudioStreamWAV.new()
	lock_beep.format = AudioStreamWAV.FORMAT_16_BITS
	lock_beep.stereo = false
	lock_beep.mix_rate = rate
	lock_beep.data = lock_bytes
	lock_beep.loop_mode = AudioStreamWAV.LOOP_FORWARD
	lock_beep.loop_begin = 0
	lock_beep.loop_end = lock_total_samples

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
