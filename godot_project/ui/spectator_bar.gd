extends Control

const Kit := preload("res://ui/ui_kit.gd")

func setup(session: Node) -> void:
	theme = Kit.THEME
	Kit.fit_to_window(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.position.y = 1020
	add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	bar.add_child(row)
	row.add_child(Kit.label("SPECTATOR  /  OWN TEAM", "SectionLabel"))
	row.add_child(Kit.label("TAB: NEXT ALLY  /  F1: COCKPIT  /  F11: FREE CAMERA", "DimLabel"))
	row.add_child(Kit.button("LOBBY  [ESC]", "", session.show_lobby))
