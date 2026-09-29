extends RefCounted

# Audio buses: PlayerEngine, Others, Effects (low-pass filtered in the cockpit; Others and Effects are
# also turned down there) and Cockpit (warnings, only audible in the cockpit). A hard limiter on Master
# stops many simultaneous explosions from clipping.

const INTERIOR_OTHERS_DB: float = -32.0
const INTERIOR_EFFECTS_DB: float = -12.0

# Bus indices and effect indices
var _player_bus_idx: int = -1
var _others_bus_idx: int = -1
var _effects_bus_idx: int = -1
var _cockpit_bus_idx: int = -1

var _player_lpf_idx: int = -1
var _others_lpf_idx: int = -1
var _effects_lpf_idx: int = -1

var _cur_others_bus_db: float = 0.0
var _cur_effects_bus_db: float = 0.0
var _was_interior: bool = false

func _init() -> void:
	_setup_buses()

func _setup_buses() -> void:
	_player_bus_idx = _get_or_create_bus("PlayerEngine")
	_others_bus_idx = _get_or_create_bus("Others")
	_effects_bus_idx = _get_or_create_bus("Effects")
	_cockpit_bus_idx = _get_or_create_bus("Cockpit")

	_player_lpf_idx = _ensure_low_pass_filter(_player_bus_idx)
	_others_lpf_idx = _ensure_low_pass_filter(_others_bus_idx)
	_effects_lpf_idx = _ensure_low_pass_filter(_effects_bus_idx)

	# Hard limiter on Master so many simultaneous explosions/launches never clip the output
	var master_idx := AudioServer.get_bus_index("Master")
	var has_limiter := false
	for i in AudioServer.get_bus_effect_count(master_idx):
		if AudioServer.get_bus_effect(master_idx, i) is AudioEffectHardLimiter:
			has_limiter = true
	if not has_limiter:
		var limiter := AudioEffectHardLimiter.new()
		limiter.ceiling_db = -1.0
		AudioServer.add_bus_effect(master_idx, limiter)

	# Initial exterior settings
	AudioServer.set_bus_volume_db(_player_bus_idx, 0.0)
	AudioServer.set_bus_volume_db(_others_bus_idx, 0.0)
	AudioServer.set_bus_volume_db(_effects_bus_idx, 0.0)
	AudioServer.set_bus_mute(_cockpit_bus_idx, true)

	AudioServer.set_bus_effect_enabled(_player_bus_idx, _player_lpf_idx, false)
	AudioServer.set_bus_effect_enabled(_others_bus_idx, _others_lpf_idx, false)
	AudioServer.set_bus_effect_enabled(_effects_bus_idx, _effects_lpf_idx, false)

	_cur_others_bus_db = 0.0
	_cur_effects_bus_db = 0.0
	_was_interior = false

func _get_or_create_bus(bus_name: StringName) -> int:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	return idx

func _ensure_low_pass_filter(bus_idx: int) -> int:
	for i in range(AudioServer.get_bus_effect_count(bus_idx)):
		if AudioServer.get_bus_effect(bus_idx, i) is AudioEffectLowPassFilter:
			return i
	var lpf := AudioEffectLowPassFilter.new()
	lpf.cutoff_hz = 900.0
	var effect_idx := AudioServer.get_bus_effect_count(bus_idx)
	AudioServer.add_bus_effect(bus_idx, lpf, effect_idx)
	AudioServer.set_bus_effect_enabled(bus_idx, effect_idx, false)
	return effect_idx

# Every frame: fade the cockpit ducking in/out, switch the muffling filters.
func update(delta: float, interior: bool) -> void:
	var target_others_db := INTERIOR_OTHERS_DB if interior else 0.0
	var target_effects_db := INTERIOR_EFFECTS_DB if interior else 0.0

	_cur_others_bus_db = move_toward(_cur_others_bus_db, target_others_db, delta * 70.0)
	AudioServer.set_bus_volume_db(_others_bus_idx, _cur_others_bus_db)

	_cur_effects_bus_db = move_toward(_cur_effects_bus_db, target_effects_db, delta * 20.0)
	AudioServer.set_bus_volume_db(_effects_bus_idx, _cur_effects_bus_db)

	AudioServer.set_bus_mute(_cockpit_bus_idx, not interior)

	if interior != _was_interior:
		_was_interior = interior
		AudioServer.set_bus_effect_enabled(_player_bus_idx, _player_lpf_idx, interior)
		AudioServer.set_bus_effect_enabled(_others_bus_idx, _others_lpf_idx, interior)
		AudioServer.set_bus_effect_enabled(_effects_bus_idx, _effects_lpf_idx, interior)
