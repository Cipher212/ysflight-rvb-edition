extends "res://core/preflight_session.gd"

# Free Flight shares team restrictions and hangar selection, with a paused mission behind menus.
func setup(p_main: Node) -> void:
	name = "FreeFlightSession"
	setup_base(p_main, EventConfig.load_config())
	get_tree().paused = true
