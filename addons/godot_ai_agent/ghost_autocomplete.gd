@tool
extends Node

var active_code_edit: CodeEdit
var debounce_timer: Timer
var http: HTTPRequest
var ghost_label: Label
var ghost_text := ""
var original_caret_line := -1
var original_caret_col := -1

func _ready():
	print("[AI Agent] Ghost Autocomplete initialized.")
	debounce_timer = Timer.new()
	debounce_timer.one_shot = true
	debounce_timer.wait_time = 0.8
	debounce_timer.timeout.connect(_request_autocomplete)
	add_child(debounce_timer)

	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_http_response)

	ghost_label = Label.new()
	ghost_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 0.8))
	ghost_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost_label.hide()
	
	if Engine.is_editor_hint():
		# Use Godot's built in font size setting or just a default
		var ed_theme = EditorInterface.get_editor_theme()
		if ed_theme:
			var font = ed_theme.get_font("source", "EditorFonts")
			if font:
				ghost_label.add_theme_font_override("font", font)
			var font_size = ed_theme.get_font_size("source_size", "EditorFonts")
			if font_size:
				ghost_label.add_theme_font_size_override("font_size", font_size)
	
	start_monitoring()

func start_monitoring():
	if not Engine.is_editor_hint(): return
	var script_editor = EditorInterface.get_script_editor()
	if not script_editor: return
	script_editor.editor_script_changed.connect(_on_script_changed)
	var current = script_editor.get_current_script()
	if current:
		_on_script_changed(current)

func find_code_edit(node: Node) -> CodeEdit:
	if node is CodeEdit: return node
	for child in node.get_children():
		var found = find_code_edit(child)
		if found: return found
	return null

func _on_script_changed(_script: Script):
	var script_editor = EditorInterface.get_script_editor()
	if not script_editor: return
	var current_editor = script_editor.get_current_editor()
	if not current_editor: return
	
	var ce = find_code_edit(current_editor)
	if ce:
		_hook_code_edit(ce)

func _hook_code_edit(ce: CodeEdit):
	if active_code_edit == ce: return
	
	if active_code_edit and is_instance_valid(active_code_edit):
		if active_code_edit.text_changed.is_connected(_on_text_changed):
			active_code_edit.text_changed.disconnect(_on_text_changed)
		if active_code_edit.gui_input.is_connected(_on_gui_input):
			active_code_edit.gui_input.disconnect(_on_gui_input)

	active_code_edit = ce
	if not active_code_edit.text_changed.is_connected(_on_text_changed):
		active_code_edit.text_changed.connect(_on_text_changed)
	if not active_code_edit.gui_input.is_connected(_on_gui_input):
		active_code_edit.gui_input.connect(_on_gui_input)
		
	if is_instance_valid(ghost_label) and is_instance_valid(active_code_edit):
		var font = active_code_edit.get_theme_font("font")
		var fsize = active_code_edit.get_theme_font_size("font_size")
		if font: ghost_label.add_theme_font_override("font", font)
		if fsize: ghost_label.add_theme_font_size_override("font_size", fsize)

func _process(delta):
	if ghost_text != "" and active_code_edit and is_instance_valid(active_code_edit):
		var caret_line = active_code_edit.get_caret_line()
		var caret_col = active_code_edit.get_caret_column()
		if caret_line != original_caret_line or caret_col != original_caret_col:
			_clear_ghost()
			return

		var pos = active_code_edit.get_rect_at_line_column(caret_line, caret_col).position
		# Adjust slightly for font baseline/spacing
		pos.x += 2 # Offset slightly from cursor
		ghost_label.position = pos
		if ghost_label.get_parent() != active_code_edit:
			if ghost_label.get_parent():
				ghost_label.get_parent().remove_child(ghost_label)
			active_code_edit.add_child(ghost_label)
		ghost_label.show()

func _on_text_changed():
	_clear_ghost()
	debounce_timer.start()

func _clear_ghost():
	ghost_text = ""
	ghost_label.hide()
	# Optional: Instead of cancelling request, we could just ignore it.
	# But cancelling saves bandwidth. However HTTPRequest cancel might drop connection.
	# We just let it finish and ignore it if text changed.
	# http.cancel_request()

func _on_gui_input(event: InputEvent):
	if ghost_text != "" and event is InputEventKey and event.pressed:
		if event.keycode == KEY_TAB:
			# Accept completion
			active_code_edit.insert_text_at_caret(ghost_text)
			_clear_ghost()
			active_code_edit.accept_event()
		elif event.keycode == KEY_ESCAPE:
			_clear_ghost()
			active_code_edit.accept_event()

func _request_autocomplete():
	if not is_instance_valid(active_code_edit): return
	
	var cfg := ConfigFile.new()
	var api_key = ""
	if cfg.load("user://godot_ai_agent.cfg") == OK:
		api_key = cfg.get_value("api", "nvidia_key", "")
	if api_key.is_empty(): return
	
	var line = active_code_edit.get_caret_line()
	var col = active_code_edit.get_caret_column()
	original_caret_line = line
	original_caret_col = col
	
	var text = active_code_edit.text
	var lines = text.split("\n")
	var before_lines = lines.slice(0, line)
	var current_line_before = lines[line].substr(0, col)
	var current_line_after = lines[line].substr(col)
	var after_lines = lines.slice(line + 1, lines.size())
	
	var before = "\n".join(before_lines) + ("\n" if before_lines.size() > 0 else "") + current_line_before
	var after = current_line_after + ("\n" if after_lines.size() > 0 else "") + "\n".join(after_lines)
	
	# Limit context to save tokens
	var context_before = before.substr(maxi(0, before.length() - 1500))
	var context_after = after.substr(0, 500)

	var prompt = "You are a GDScript autocomplete engine. Complete the code exactly at [CURSOR].\n" + \
	"Return ONLY the exact characters that should be inserted at [CURSOR].\n" + \
	"Do NOT output markdown blocks or backticks. Do NOT repeat the before/after code.\n\n" + \
	"Code:\n" + context_before + "[CURSOR]" + context_after
	
	var messages = [ {"role": "user", "content": prompt}]
	var headers := PackedStringArray([
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json"
	])
	
	var body := JSON.stringify({
		"model": "moonshotai/kimi-k2-instruct",
		"messages": messages,
		"temperature": 0.2,
		"max_tokens": 128,
		"stream": false
	})
	
	http.request("https://integrate.api.nvidia.com/v1/chat/completions", headers, HTTPClient.METHOD_POST, body)

func _on_http_response(result: int, code: int, headers: PackedStringArray, body: PackedByteArray):
	if code != 200: return
	var json = JSON.new()
	if json.parse(body.get_string_from_utf8()) == OK:
		var data = json.data
		if data is Dictionary and data.has("choices") and data["choices"].size() > 0:
			var completion_text: String = data["choices"][0].get("message", {}).get("content", "")
			
			# Clean up any bad AI formatting
			completion_text = completion_text.replace("```gdscript", "").replace("```", "")
			# Sometimes it prepends spaces we already typed. We can strip starting spaces only if needed, 
			# but actually we told it to output exact chars to insert. 
			# Let's just use it directly, maybe strip leading newlines if it hallucinated them unnecessarily.
			
			if completion_text != "":
				if active_code_edit and active_code_edit.get_caret_line() == original_caret_line and active_code_edit.get_caret_column() == original_caret_col:
					# Only keep the first line of completion to avoid multiline ghost overlapping real text
					var completion_lines = completion_text.split("\n")
					ghost_text = completion_text
					
					# But for display, we might just want to show the first line to keep it clean floating
					# Or show all lines. For simplicity, just show the whole text. 
					# Godot Label handles newlines.
					ghost_label.text = ghost_text
