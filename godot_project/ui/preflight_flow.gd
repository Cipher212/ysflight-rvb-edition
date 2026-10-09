extends CanvasLayer

const Kit := preload("res://ui/ui_kit.gd")
const Lobby := preload("res://ui/preflight_lobby.gd")
const Hangar := preload("res://ui/hangar_selection.gd")
const SpectatorBar := preload("res://ui/spectator_bar.gd")
var lobby: Control
var hangar: Control
var _root: Control
var _spectator_bar: Control
var _session: Node

func setup(session: Node) -> void:
	_session = session
	_root = Control.new()
	add_child(_root)
	Kit.make_screen(_root)
	lobby = Lobby.new()
	_root.add_child(lobby)
	lobby.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lobby.setup(session)
	hangar = Hangar.new()
	_root.add_child(hangar)
	hangar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hangar.setup(session)
	_spectator_bar = SpectatorBar.new()
	add_child(_spectator_bar)
	_spectator_bar.setup(session)
	session.menu_requested.connect(_open)
	session.menu_closed.connect(_close)
	session.finished.connect(_close)
	_open(session.menu_screen)

func _open(screen: String) -> void:
	_spectator_bar.hide()
	_root.show()
	lobby.visible = screen == "lobby"
	hangar.visible = screen == "hangar"
	if hangar.visible:
		hangar.refresh_aircraft()
	else:
		lobby.refresh()
	hangar.preview.set_active(hangar.visible)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _close() -> void:
	hangar.preview.set_active(false)
	_root.hide()
	_spectator_bar.visible = _session.spectating
