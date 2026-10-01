extends RefCounted

# Small builders for the RvB menu screens, so every screen looks the same (logs/UI_scheme.md). Styling comes
# only from res://ui/rvb_theme.tres type variations; nothing here sets colours by hand except the team accents.

const THEME := preload("res://ui/rvb_theme.tres")
const RED := Color("#ff2d2d")
const BLUE := Color("#2f62ff")
const INK := Color("#04060d")
const PALE := Color("#d9dfee")
const DESIGN_SIZE := Vector2(1920.0, 1080.0) # every screen is laid out at this size, then scaled to the window
const MIN_SCALE := 0.5
const LOADING_NODE := "RvbLoading"

# Full-screen root setup: theme, ink background, visible mouse, scaled to the window.
static func make_screen(root: Control) -> void:
	root.theme = THEME
	fit_to_window(root)
	var bg := ColorRect.new()
	bg.color = INK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

# Lays root out at DESIGN_SIZE (same aspect as the window) and scales it to fill the window, so a menu looks the
# same at any resolution. Call on a menu's root Control; re-fits when the window is resized.
static func fit_to_window(root: Control) -> void:
	root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var apply := func() -> void:
		var win: Vector2 = root.get_viewport().get_visible_rect().size
		var s: float = maxf(minf(win.x / DESIGN_SIZE.x, win.y / DESIGN_SIZE.y), MIN_SCALE)
		root.scale = Vector2(s, s)
		root.position = Vector2.ZERO
		root.size = win / s
	var hook := func() -> void:
		apply.call()
		root.get_viewport().size_changed.connect(apply)
	if root.is_inside_tree():
		hook.call()
	else:
		root.tree_entered.connect(hook, CONNECT_ONE_SHOT)

# Loading screen for the seconds main.tscn takes to load a map. Added to the tree root, so it survives the scene
# change; main.gd removes it (hide_loading) once the first frame of the flight is ready. Call it, wait two frames
# so it is drawn, then change scene.
static func show_loading(tree: SceneTree, title: String, detail: String) -> void:
	var layer := CanvasLayer.new()
	layer.name = LOADING_NODE
	layer.layer = 200
	tree.root.add_child(layer)
	var root := Control.new()
	layer.add_child(root)
	make_screen(root)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var body := panel(center, title)
	body.custom_minimum_size = Vector2(620, 0)
	body.add_child(label("LOADING", "BigNumber"))
	body.add_child(label(detail, "DimLabel"))

static func hide_loading(tree: SceneTree) -> void:
	var layer := tree.root.get_node_or_null(LOADING_NODE)
	if layer != null:
		layer.queue_free()

static func label(text: String, variation: String = "") -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	return l

static func button(text: String, variation: String = "", on_press: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	if variation != "":
		b.theme_type_variation = variation
	if on_press.is_valid():
		b.pressed.connect(on_press)
	return b

# PS2-style window: pale header strip (with a red or blue square) over a bordered body. Returns the body box.
static func panel(parent: Control, title: String, team: String = "") -> VBoxContainer:
	var pc := PanelContainer.new()
	parent.add_child(pc)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 14)
	pc.add_child(outer)
	outer.add_child(header_strip(title, team))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL # so a ScrollContainer inside gets the panel's height
	outer.add_child(body)
	return body

# Pale header strip with the site's small square (red / blue team, or red by default) before the title.
static func header_strip(title: String, team: String = "") -> PanelContainer:
	var strip := PanelContainer.new()
	strip.theme_type_variation = "HeaderStrip"
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	strip.add_child(h)
	var sq := ColorRect.new()
	sq.color = BLUE if team == "blue" else RED
	sq.custom_minimum_size = Vector2(10, 10)
	sq.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(sq)
	var l := label(title, "PanelHeader")
	l.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	h.add_child(l)
	return strip

# Form row: dim key on the left, the control on the right.
static func row(parent: Control, key: String, control: Control, key_width: float = 230.0) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	var k := label(key, "SectionLabel")
	k.custom_minimum_size = Vector2(key_width, 0)
	h.add_child(k)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(control)
	parent.add_child(h)
	return h

static func options(items: Array, selected: int = 0) -> OptionButton:
	var o := OptionButton.new()
	for it in items:
		o.add_item(str(it))
	if o.item_count > 0:
		o.select(clampi(selected, 0, o.item_count - 1))
	return o

# Minutes:seconds, for the event clock.
static func clock(seconds: float) -> String:
	var s := maxi(int(ceil(seconds)), 0)
	return "%02d:%02d" % [s / 60, s % 60]
