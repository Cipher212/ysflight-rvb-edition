extends VBoxContainer

const Kit := preload("res://ui/ui_kit.gd")
signal target_selected(key: int)
var _signature := ""

func refresh(pilots: Array, own_team: String) -> void:
	var signature := str(pilots) + own_team
	if signature == _signature:
		return
	_signature = signature
	for child in get_children():
		remove_child(child)
		child.queue_free()
	for team in ["blue", "red"]:
		var count := 0
		for pilot in pilots:
			if pilot.get("team", "") == team:
				count += 1
		add_child(Kit.header_strip("%s TEAM  /  %d PILOTS" % [team.to_upper(), count], team))
		for pilot in pilots:
			if pilot.get("team", "") != team:
				continue
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 14)
			add_child(row)
			var human := bool(pilot.get("player", false))
			var title := Kit.label(str(pilot.get("name", "AI")) + ("  [YOU]" if human else "  [AI]"))
			title.custom_minimum_size.x = 215
			row.add_child(title)
			var aircraft := Kit.label(str(pilot.get("aircraft", "")).replace("[RVB]", "").replace("_", " "), "DimLabel")
			aircraft.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			aircraft.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			row.add_child(aircraft)
			var live := bool(pilot.get("alive", false))
			var key := int(pilot.get("key", -1))
			if team == own_team and live and key >= 0 and not human:
				row.add_child(Kit.button("WATCH", "", func() -> void: target_selected.emit(key)))
			else:
				var status_text := "FLYING" if live else ("SELECTING" if human else ("RESPAWN" if int(pilot.get("deaths", 0)) > 0 else "READY"))
				var status := Kit.label(status_text, "DimLabel")
				status.custom_minimum_size.x = 100
				row.add_child(status)
