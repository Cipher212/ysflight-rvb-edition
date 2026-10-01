extends RefCounted

# What the next main.tscn load should do, set by the menus before changing scene (static: survives the scene
# change, no autoload needed). "free" = the classic 16 v 16 free play (command-line modes); "event" = an
# offline RvB event from user://rvb_event.json (core/event_config.gd); "free_flight" = Home > FREE FLIGHT.

static var mode := "free"
