extends VBoxContainer

const Kit := preload("res://ui/ui_kit.gd")
var _session: Node
var _log: RichTextLabel
var _input: LineEdit

func setup(session: Node) -> void:
	_session = session
	_log = RichTextLabel.new()
	_log.bbcode_enabled = false
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_log)
	for message in session.messages:
		_log.add_text(message + "\n\n")
	session.message_added.connect(_append)
	add_child(Kit.label("LOCAL MESSAGES  /  THIS SESSION", "DimLabel"))
	_input = LineEdit.new()
	_input.placeholder_text = "TYPE A MESSAGE..."
	_input.max_length = 160
	_input.text_submitted.connect(_send)
	add_child(_input)
	add_child(Kit.button("SEND", "", func() -> void: _send(_input.text)))

func _send(value: String) -> void:
	_session.send_message(value)
	_input.clear()

func _append(_text: String) -> void:
	_log.clear()
	for message in _session.messages:
		_log.add_text(message + "\n\n")
