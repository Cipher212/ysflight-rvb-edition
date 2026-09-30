extends Control

# Post-event debrief: result, team totals, per-pilot table for each team, kill log; CSV export and back to the
# home screen. Reads user://rvb_event_results.json (core/event_results.gd), written when the event ends.

const Kit := preload("res://ui/ui_kit.gd")
const Results := preload("res://core/event_results.gd")
const AppState := preload("res://core/app_state.gd")
const HOME_SCENE := "res://ui/home.tscn"
const MARGIN := 40
const COLUMNS := ["PILOT", "AIRCRAFT", "ROLE", "AIR", "GND", "DEATHS", "HITS"]

var results: Dictionary = {}
var _export_label: Label = null

func _ready() -> void:
	AppState.mode = "free"
	Kit.make_screen(self)
	results = Results.load_results()
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN)
	add_child(margin)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 16)
	margin.add_child(page)
	_build_header(page)
	page.add_child(HSeparator.new())
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 20)
	page.add_child(cols)
	var tables := VBoxContainer.new()
	tables.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tables.size_flags_stretch_ratio = 2.0
	tables.add_theme_constant_override("separation", 16)
	cols.add_child(tables)
	for team in ["blue", "red"]:
		_build_table(tables, team)
	_build_kill_log(cols)
	_build_buttons(page)

func _build_header(page: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	page.add_child(row)
	row.add_child(Kit.label("DEBRIEF", "TitleLabel"))
	var cfg: Dictionary = results.get("config", {})
	var tag := Kit.label("%s  /  %s" % [str(cfg.get("map", "")).replace("[RVB]", ""),
		Kit.clock(float(results.get("elapsed", 0.0)))], "TagLabel")
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(tag)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var blue := Results.team_totals(results, "blue")
	var red := Results.team_totals(results, "red")
	var bk: int = blue["air_kills"] + blue["ground_kills"]
	var rk: int = red["air_kills"] + red["ground_kills"]
	for s in [["BLUE KILLS", bk, Kit.BLUE], ["RED KILLS", rk, Kit.RED],
			["BLUE LOSSES", blue["deaths"], Kit.BLUE], ["RED LOSSES", red["deaths"], Kit.RED]]:
		var box := PanelContainer.new()
		box.theme_type_variation = "StatBox"
		var v := VBoxContainer.new()
		box.add_child(v)
		var num := Kit.label(str(s[1]), "BigNumber")
		num.add_theme_color_override("font_color", s[2])
		v.add_child(num)
		v.add_child(Kit.label(s[0], "TableHead"))
		row.add_child(box)
	var verdict := "DRAW" if bk == rk else ("BLUE WINS" if bk > rk else "RED WINS")
	var stamp := Kit.label(verdict, "TitleLabel")
	if bk != rk:
		stamp.add_theme_color_override("font_color", Kit.BLUE if bk > rk else Kit.RED)
	stamp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(stamp)

func _build_table(parent: Control, team: String) -> void:
	var body := Kit.panel(parent, ("BLUE" if team == "blue" else "RED") + " FORCE", team)
	body.get_parent().get_parent().size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = COLUMNS.size()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(grid)
	for c in COLUMNS:
		grid.add_child(Kit.label(c, "TableHead"))
	for p in Results.ranked(results, team):
		var cells := [p["name"], p["aircraft"], p["role"], str(int(p["air_kills"])), str(int(p["ground_kills"])),
			str(int(p["deaths"])), Results.hit_rate(p)]
		for i in cells.size():
			var l := Kit.label(str(cells[i]), "RedText" if team == "red" and i == 0 else ("BlueText" if i == 0 else ""))
			if bool(p["player"]):
				l.add_theme_color_override("font_color", Color.WHITE)
			if i == 1:
				l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				l.clip_text = true
			grid.add_child(l)

func _build_kill_log(parent: Control) -> void:
	var body := Kit.panel(parent, "KILL LOG")
	var pc: Control = body.get_parent().get_parent()
	pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var kills: Array = results.get("kills", [])
	if kills.is_empty():
		list.add_child(Kit.label("NO KILLS", "DimLabel"))
	for k in kills:
		var what: String = ("%s > %s" % [k["killer"], k["victim"]]) if k["killer"] != "" else str(k["victim"])
		var line := Kit.label("%s  %s  %s%s" % [Kit.clock(float(k["time"])), what, str(k["how"]).to_upper(),
			"  (TEAM KILL)" if bool(k["team_kill"]) else ""])
		line.add_theme_font_size_override("font_size", 15)
		if k["killer_team"] == "red":
			line.add_theme_color_override("font_color", Color("#ff4a42"))
		elif k["killer_team"] == "blue":
			line.add_theme_color_override("font_color", Color("#6f95ff"))
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(line)

func _build_buttons(page: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	page.add_child(row)
	row.add_child(Kit.button("EXPORT CSV", "BlueButton", func() -> void:
		var path := Results.export_csv(results)
		_export_label.text = ("SAVED: " + path) if path != "" else "EXPORT FAILED"))
	row.add_child(Kit.button("BACK TO MENU", "RedButton", func() -> void:
		get_tree().change_scene_to_file(HOME_SCENE)))
	_export_label = Kit.label("", "DimLabel")
	_export_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_export_label)
