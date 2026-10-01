extends Control

# Online (Home > ONLINE): placeholder until online play exists. A server list panel with nothing in it, and BACK.

const Kit := preload("res://ui/ui_kit.gd")
const HOME_SCENE := "res://ui/home.tscn"
const MARGIN := 40

func _ready() -> void:
	Kit.make_screen(self)
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
	title_row.add_child(Kit.label("ONLINE", "TitleLabel"))
	var tag := Kit.label("SERVERS", "TagLabel")
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(tag)
	page.add_child(HSeparator.new())
	var body := Kit.panel(page, "SERVER LIST")
	body.get_parent().get_parent().size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(Kit.label("ONLINE PLAY IS NOT AVAILABLE IN THIS VERSION", "DimLabel"))
	var buttons := HBoxContainer.new()
	page.add_child(buttons)
	var join := Kit.button("JOIN")
	join.disabled = true
	buttons.add_child(join)
	buttons.add_child(Kit.button("BACK", "", func() -> void: get_tree().change_scene_to_file(HOME_SCENE)))
