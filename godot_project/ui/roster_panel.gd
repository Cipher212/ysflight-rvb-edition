extends PanelContainer

# One team's AI roster in the event builder (ui/event_builder.gd): pilot rows (name, aircraft -> role derived
# from the aircraft), add / remove, quick-fill ("FILL 8 MULTIROLE"), mirror to the other side, clear.
# Edits the shared config Dictionary in place (core/event_config.gd helpers) and emits changed() afterwards.

signal changed

const Kit := preload("res://ui/ui_kit.gd")
const EventConfig := preload("res://core/event_config.gd")
const ROLES := ["ANY", "MULTIROLE", "ATTACKER", "HEAVY", "CAS", "STEALTH", "GUNNER", "UCAV"]

var team := "blue"
var cfg: Dictionary = {}
var catalog: Array = []
var rng: RandomNumberGenerator = null

var _team_aircraft: Array = []   # catalog entries of this team
var _list: VBoxContainer = null
var _count: Label = null
var _fill_n: SpinBox = null
var _fill_role: OptionButton = null

func setup(p_team: String, p_cfg: Dictionary, p_catalog: Array, p_rng: RandomNumberGenerator) -> void:
	team = p_team
	cfg = p_cfg
	catalog = p_catalog
	rng = p_rng
	_team_aircraft = EventConfig.aircraft_for(catalog, team)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	add_child(col)
	var head := HBoxContainer.new()
	col.add_child(head)
	var strip := Kit.header_strip(("BLUE" if team == "blue" else "RED") + " FORCE  AI PILOTS", team)
	strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(strip)
	_count = Kit.label("", "TagLabel")
	head.add_child(_count)

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 8)
	col.add_child(tools)
	tools.add_child(Kit.button("+ ADD", "", _add_one))
	_fill_n = SpinBox.new()
	_fill_n.min_value = 1
	_fill_n.max_value = int(cfg.get("team_size", 8))
	_fill_n.value = 8
	tools.add_child(_fill_n)
	_fill_role = Kit.options(ROLES, 1)
	tools.add_child(_fill_role)
	tools.add_child(Kit.button("FILL", "RedButton" if team == "red" else "BlueButton", _fill))
	var other := "RED" if team == "blue" else "BLUE"
	var tools2 := HBoxContainer.new()
	tools2.add_theme_constant_override("separation", 8)
	col.add_child(tools2)
	tools2.add_child(Kit.button("MIRROR TO " + other, "", func() -> void:
		EventConfig.mirror(cfg, catalog, team, rng)
		changed.emit()))
	tools2.add_child(Kit.button("CLEAR", "", func() -> void:
		cfg["pilots"] = cfg["pilots"].filter(func(p): return p["team"] != team)
		changed.emit()))

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	refresh()

func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	var n := 0
	for p in cfg["pilots"]:
		if p["team"] == team:
			_list.add_child(_row(p))
			n += 1
	_count.text = "%d / %d" % [n, int(cfg.get("team_size", 8))]
	_fill_n.max_value = int(cfg.get("team_size", 8))
	if n == 0:
		_list.add_child(Kit.label("NO AI PILOTS", "DimLabel"))

func _row(pilot: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var name_edit := LineEdit.new()
	name_edit.text = pilot["name"]
	name_edit.max_length = 12
	name_edit.custom_minimum_size = Vector2(120, 0)
	name_edit.text_changed.connect(func(t: String) -> void: pilot["name"] = t.to_upper())
	h.add_child(name_edit)
	var ids := []
	for a in _team_aircraft:
		ids.append(a["identifier"])
	var ac := Kit.options(ids, maxi(ids.find(pilot["aircraft"]), 0))
	ac.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(ac)
	var role := Kit.label(EventConfig.role_of(catalog, pilot["aircraft"]), "DimLabel")
	role.custom_minimum_size = Vector2(130, 0)
	h.add_child(role)
	ac.item_selected.connect(func(i: int) -> void:
		pilot["aircraft"] = ids[i]
		role.text = EventConfig.role_of(catalog, ids[i]))
	h.add_child(Kit.button("X", "", func() -> void:
		cfg["pilots"].erase(pilot)
		changed.emit()))
	return h

func _add_one() -> void:
	EventConfig.fill(cfg, catalog, team, mini(1, int(cfg.get("team_size", 8)) - EventConfig.count(cfg, team)), "MULTIROLE", rng)
	changed.emit()

func _fill() -> void:
	var role: String = ROLES[_fill_role.selected]
	EventConfig.fill(cfg, catalog, team, mini(int(_fill_n.value), int(cfg.get("team_size", 8)) - EventConfig.count(cfg, team)), "" if role == "ANY" else role, rng)
	changed.emit()
