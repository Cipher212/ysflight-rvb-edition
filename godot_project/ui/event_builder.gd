extends Control

# Offline RvB event builder (Home > LOCAL): event settings on the left, the two AI rosters (ui/roster_panel.gd)
# on the right. FLY saves user://rvb_event.json (core/event_config.gd) and starts main.tscn in event mode.
# The aircraft catalog comes from YS's templates via a sim node that loads no mission.

const Kit := preload("res://ui/ui_kit.gd")
const EventConfig := preload("res://core/event_config.gd")
const AppState := preload("res://core/app_state.gd")
const RosterPanel := preload("res://ui/roster_panel.gd")
const GAME_SCENE := "res://main.tscn"
const HOME_SCENE := "res://ui/home.tscn"
const MARGIN := 40

var cfg: Dictionary = {}
var catalog: Array = []
var _rng := RandomNumberGenerator.new()
var _rosters: Array = []
var _loading: Label = null

func _ready() -> void:
	Kit.make_screen(self)
	_rng.randomize()
	cfg = EventConfig.load_config() # last event, so testers can rerun it
	_loading = Kit.label("LOADING AIRCRAFT...", "SectionLabel")
	_loading.set_anchors_preset(Control.PRESET_CENTER)
	add_child(_loading)
	_load_catalog.call_deferred() # after the first frame, so the loading text shows

func _load_catalog() -> void:
	var sim := YSFlightSimulation.new()
	add_child(sim)
	sim.initialize_simulation()
	catalog = sim.get_aircraft_catalog()
	# Drop pilots whose aircraft this install doesn't have
	cfg["pilots"] = cfg["pilots"].filter(func(p): return EventConfig.role_of(catalog, p["aircraft"]) != "?")
	_loading.queue_free()
	_build()

func _build() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN)
	add_child(margin)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 18)
	margin.add_child(page)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 16)
	page.add_child(title_row)
	title_row.add_child(Kit.label("OFFLINE EVENT", "TitleLabel"))
	var tag := Kit.label("LOCAL  /  VS AI", "TagLabel")
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(tag)
	page.add_child(HSeparator.new())

	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 20)
	page.add_child(cols)
	_build_settings(cols)
	for team in ["blue", "red"]:
		var r: PanelContainer = RosterPanel.new()
		cols.add_child(r)
		r.setup(team, cfg, catalog, _rng)
		r.changed.connect(_refresh_rosters)
		_rosters.append(r)

func _build_settings(parent: Control) -> void:
	var box := Kit.panel(parent, "EVENT")
	box.get_parent().get_parent().custom_minimum_size = Vector2(560, 0)
	var maps := []
	for m in EventConfig.MAPS:
		maps.append(m["label"])
	var map_opt := Kit.options(maps)
	map_opt.item_selected.connect(func(i: int) -> void: cfg["map"] = EventConfig.MAPS[i]["id"])
	Kit.row(box, "MAP", map_opt)

	var team_opt := Kit.options(["BLUE", "RED"], 1 if cfg["player_team"] == "red" else 0)
	team_opt.item_selected.connect(func(i: int) -> void: cfg["player_team"] = "red" if i == 1 else "blue")
	Kit.row(box, "YOUR TEAM", team_opt)

	var callsign := LineEdit.new()
	callsign.text = cfg["player_name"]
	callsign.max_length = 12
	callsign.text_changed.connect(func(t: String) -> void: cfg["player_name"] = t.to_upper())
	Kit.row(box, "YOUR CALLSIGN", callsign)

	var diff := Kit.options(EventConfig.DIFFICULTIES)
	diff.tooltip_text = "Placeholder: every AI flies the same for now"
	Kit.row(box, "AI DIFFICULTY", diff)

	var tod := Kit.options(EventConfig.TIMES_OF_DAY, maxi(EventConfig.TIMES_OF_DAY.find(cfg["time_of_day"]), 0))
	tod.tooltip_text = "Placeholder: not applied yet"
	tod.item_selected.connect(func(i: int) -> void: cfg["time_of_day"] = EventConfig.TIMES_OF_DAY[i])
	Kit.row(box, "TIME OF DAY", tod)

	var dur := SpinBox.new()
	dur.min_value = EventConfig.MIN_MINUTES
	dur.max_value = EventConfig.MAX_MINUTES
	dur.step = 5
	dur.suffix = "MIN"
	dur.value = cfg["duration_min"]
	dur.value_changed.connect(func(v: float) -> void: cfg["duration_min"] = int(v))
	Kit.row(box, "DURATION", dur)

	box.add_child(Kit.label("RULES", "SectionLabel"))
	for rule in [["collisions", "MID-AIR COLLISIONS"], ["friendly_fire", "FRIENDLY FIRE"]]:
		var cb := CheckBox.new()
		cb.text = rule[1]
		cb.button_pressed = bool(cfg["rules"][rule[0]])
		cb.toggled.connect(func(on: bool) -> void: cfg["rules"][rule[0]] = on)
		box.add_child(cb)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)
	box.add_child(Kit.label("AIR STARTS ONLY: THE AI CANNOT TAKE OFF YET", "DimLabel"))
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	box.add_child(buttons)
	var fly := Kit.button("FLY", "RedButton", _fly)
	fly.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(fly)
	buttons.add_child(Kit.button("BACK", "", func() -> void: get_tree().change_scene_to_file(HOME_SCENE)))

func _refresh_rosters() -> void:
	for r in _rosters:
		r.refresh()

func _fly() -> void:
	EventConfig.save(cfg)
	AppState.mode = "event"
	get_tree().change_scene_to_file(GAME_SCENE)
