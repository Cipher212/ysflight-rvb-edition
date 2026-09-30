extends RefCounted

# What the next main.tscn load should do, set by the menus before changing scene (static: survives the scene
# change, no autoload needed). "free" = the classic free flight (Play.bat / command-line modes); "event" =
# an offline RvB event from user://rvb_event.json (core/event_config.gd).

static var mode := "free"
