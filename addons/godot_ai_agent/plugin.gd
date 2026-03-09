@tool
extends EditorPlugin

var dock: Control

func _enter_tree():
	var DockScript = load("res://addons/godot_ai_agent/dock.gd")
	dock = DockScript.new()
	dock.name = "AIAgent"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	
	# Start Ghost Autocomplete
	var GhostScript = load("res://addons/godot_ai_agent/ghost_autocomplete.gd")
	var ghost = GhostScript.new()
	ghost.name = "GhostAutocomplete"
	add_child(ghost)
	
	print("[AI Agent] ✅ Plugin loaded.")

func _exit_tree():
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
		
	var ghost = get_node_or_null("GhostAutocomplete")
	if ghost:
		ghost.queue_free()
		
	print("[AI Agent] Plugin unloaded.")
