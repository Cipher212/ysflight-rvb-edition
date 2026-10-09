extends RefCounted

# Sequential volume fade-out / fade-in camera-view transition (cockpit <-> exterior)
# for the local player jet. Fades out over ~60 ms, switches streams at zero gain
# while muted, then fades in over ~60 ms. Reuses existing AudioStreamPlayer3D
# nodes without simultaneous crossfading; never starts players directly.

const FADE_HALF_TIME: float = 0.06
const SILENCE_DB: float = -100.0

enum State {
	IDLE,
	FADING_OUT,
	FADING_IN,
}

var state: int = State.IDLE
var current_interior: bool = false
var target_interior: bool = false
var fade_gain: float = 1.0
var fade_timer: float = 0.0

func _set_player_stream(player: AudioStreamPlayer3D, stream: AudioStreamWAV) -> void:
	if player == null or player.stream == stream:
		return
	player.volume_db = SILENCE_DB
	player.stream = stream

func _apply_stream_selection(sounds: RefCounted, v: Object, interior: bool) -> void:
	if v == null or sounds == null:
		return
	var target_stream: AudioStreamWAV = sounds.jet_cockpit if interior else sounds.jet_external
	_set_player_stream(v.engine_player, target_stream)
	_set_player_stream(v.burner_player, target_stream)

func reset_to_view(sounds: RefCounted, v: Object, interior: bool) -> void:
	current_interior = interior
	target_interior = interior
	state = State.IDLE
	fade_gain = 1.0
	fade_timer = 0.0
	_apply_stream_selection(sounds, v, interior)

func setup(sounds: RefCounted, v: Object, initial_interior: bool) -> void:
	reset_to_view(sounds, v, initial_interior)

func select_immediate(sounds: RefCounted, v: Object, interior: bool) -> void:
	reset_to_view(sounds, v, interior)

func reset_stopped(sounds: RefCounted, v: Object, interior: bool) -> void:
	reset_to_view(sounds, v, interior)

func reset_for_prop(interior: bool) -> void:
	current_interior = interior
	target_interior = interior
	state = State.IDLE
	fade_gain = 1.0
	fade_timer = 0.0

func update(
	delta: float,
	sounds: RefCounted,
	v: Object,
	interior: bool
) -> void:
	# If switching from prop, snap immediately to desired jet stream
	if v.engine_player != null and v.engine_player.stream == sounds.prop0:
		reset_to_view(sounds, v, interior)
		return

	# If both actual players are stopped, select requested view immediately without starting either
	var eng_playing: bool = v.engine_player != null and v.engine_player.playing
	var brn_playing: bool = v.burner_player != null and v.burner_player.playing
	if not eng_playing and not brn_playing:
		reset_to_view(sounds, v, interior)
		return

	match state:
		State.IDLE:
			if interior != current_interior:
				target_interior = interior
				state = State.FADING_OUT
				fade_timer = FADE_HALF_TIME
				fade_gain = 1.0
			else:
				fade_gain = 1.0
				_apply_stream_selection(sounds, v, current_interior)

		State.FADING_OUT:
			if interior == current_interior:
				target_interior = interior
				state = State.FADING_IN
				fade_timer = (1.0 - fade_gain) * FADE_HALF_TIME
			else:
				target_interior = interior
				fade_timer -= delta
				if fade_timer > 0.0:
					fade_gain = clampf(fade_timer / FADE_HALF_TIME, 0.0, 1.0)
				else:
					fade_gain = 0.0
					current_interior = target_interior
					_apply_stream_selection(sounds, v, current_interior)
					state = State.FADING_IN
					fade_timer = FADE_HALF_TIME

		State.FADING_IN:
			if interior != current_interior:
				target_interior = interior
				state = State.FADING_OUT
				fade_timer = fade_gain * FADE_HALF_TIME
			else:
				target_interior = interior
				fade_timer -= delta
				if fade_timer > 0.0:
					fade_gain = clampf(1.0 - (fade_timer / FADE_HALF_TIME), 0.0, 1.0)
				else:
					fade_gain = 1.0
					state = State.IDLE
