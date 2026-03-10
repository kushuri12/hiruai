@tool
extends VBoxContainer
## Godot AI Agent Dock — Full project control.
## Reads, writes, deletes .gd/.tscn files. Animated file cards.
## Auto-read loop: AI reads files first, then edits intelligently.

# ──────────────────── Node References ────────────────────
var kimi: Node
var chat_container: VBoxContainer
var scroll: ScrollContainer
var input_field: LineEdit
var send_btn: Button
var status_label: Label

# ──────────────────── Theme Colors ────────────────────
const C_BG := Color("#1a1a2e")
const C_PANEL := Color("#16213e")
const C_ACCENT := Color("#00d2ff")
const C_BTN := Color("#0f3460")
const C_USER_BG := Color("#0f3460")
const C_AI_BG := Color("#1a1a2e")
const C_TEXT := Color.WHITE
const C_USER := Color("#7cffb2")
const C_AI := Color("#64b5f6")
const C_ERR := Color("#ff6b6b")
const C_SYS := Color("#ffd93d")

const C_SAVE := Color("#00e676")
const C_READ := Color("#42a5f5")
const C_DELETE := Color("#ff5252")
const C_CREATE := Color("#ab47bc")

# ──────────────────── State ────────────────────
var chat_history: Array = []
var _read_loop_count: int = 0
const MAX_READ_LOOPS := 12

# Pending changes — waiting for user approval
var _pending_saves: Array[Dictionary] = []
var _pending_deletes: Array[String] = []
var _approval_panel: PanelContainer = null
var _tree_sent := false # Only send project tree once per session
var _read_files: Array[String] = [] # Track which files AI has READ this session


func _ready():
	custom_minimum_size = Vector2(300, 400)
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	_build_ui()
	_setup_kimi()
	_add_welcome()


# ══════════════════ KIMI SETUP ══════════════════

func _setup_kimi():
	var KimiScript = load("res://addons/godot_ai_agent/kimi_client.gd")
	kimi = Node.new()
	kimi.set_script(KimiScript)
	kimi.name = "KimiClient"
	add_child(kimi)
	kimi.chat_completed.connect(_on_ai_response)
	kimi.chat_error.connect(_on_ai_error)


# ══════════════════ UI CONSTRUCTION ══════════════════

func _build_ui():
	add_theme_constant_override("separation", 4)
	_build_header()
	add_child(HSeparator.new())
	_build_chat_area()
	add_child(HSeparator.new())
	_build_input_area()
	add_child(HSeparator.new())
	_build_action_buttons()


func _build_header():
	var panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _sb(C_PANEL, 0))
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)

	var title = Label.new()
	title.text = "🤖 AI AGENT"
	title.add_theme_color_override("font_color", C_ACCENT)
	title.add_theme_font_size_override("font_size", 15)
	title.size_flags_horizontal = SIZE_EXPAND_FILL

	status_label = Label.new()
	status_label.text = "● Ready"
	status_label.add_theme_color_override("font_color", Color("#00ff88"))
	status_label.add_theme_font_size_override("font_size", 11)

	var settings_btn = Button.new()
	settings_btn.text = "⚙️"
	settings_btn.tooltip_text = "API Key Settings"
	settings_btn.pressed.connect(_show_settings)
	_style_btn(settings_btn)

	hbox.add_child(title)
	hbox.add_child(status_label)
	hbox.add_child(settings_btn)
	panel.add_child(hbox)
	add_child(panel)


func _build_chat_area():
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 200)
	chat_container = VBoxContainer.new()
	chat_container.size_flags_horizontal = SIZE_EXPAND_FILL
	chat_container.size_flags_vertical = SIZE_EXPAND_FILL
	chat_container.add_theme_constant_override("separation", 6)
	scroll.add_child(chat_container)
	add_child(scroll)


func _build_input_area():
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)

	input_field = LineEdit.new()
	input_field.placeholder_text = "Ask anything about your Godot project..."
	input_field.size_flags_horizontal = SIZE_EXPAND_FILL
	input_field.custom_minimum_size = Vector2(0, 30)
	input_field.text_submitted.connect(_on_text_submitted)
	var style := _sb(Color("#0d1b2a"), 6)
	style.border_color = C_ACCENT.darkened(0.4)
	style.set_border_width_all(1)
	input_field.add_theme_stylebox_override("normal", style)
	input_field.add_theme_color_override("font_color", C_TEXT)
	input_field.add_theme_color_override("font_placeholder_color", Color("#556677"))
	input_field.add_theme_font_size_override("font_size", 14)

	send_btn = Button.new()
	send_btn.text = "➤"
	send_btn.custom_minimum_size = Vector2(36, 30)
	send_btn.pressed.connect(_on_send_pressed)
	_style_btn(send_btn, C_ACCENT.darkened(0.5))

	var cancel_btn = Button.new()
	cancel_btn.name = "CancelBtn"
	cancel_btn.text = "✖"
	cancel_btn.visible = false
	cancel_btn.custom_minimum_size = Vector2(36, 30)
	cancel_btn.pressed.connect(_on_cancel_pressed)
	_style_btn(cancel_btn, Color("#4e0d0d"))

	hbox.add_child(input_field)
	hbox.add_child(send_btn)
	hbox.add_child(cancel_btn)
	add_child(hbox)


func _build_action_buttons():
	var row1 = HBoxContainer.new()
	row1.add_theme_constant_override("separation", 3)
	_add_action_btn(row1, "📝 Generate", "Generate GDScript", _on_generate)
	_add_action_btn(row1, "🔧 Fix", "Fix errors from log", _on_fix)
	_add_action_btn(row1, "💡 Explain", "Explain project code", _on_explain)
	add_child(row1)

	var row2 = HBoxContainer.new()
	row2.add_theme_constant_override("separation", 3)
	_add_action_btn(row2, "🧩 Node", "Create node", _on_create_node)
	_add_action_btn(row2, "📂 Scan", "Scan project", _on_scan)
	_add_action_btn(row2, "🗑️ Clear", "Clear chat", _on_clear)
	add_child(row2)


func _add_action_btn(parent: HBoxContainer, text: String, tip: String, callback: Callable):
	var btn = Button.new()
	btn.text = text
	btn.tooltip_text = tip
	btn.size_flags_horizontal = SIZE_EXPAND_FILL
	btn.pressed.connect(callback)
	_style_btn(btn)
	parent.add_child(btn)


# ══════════════════ STYLING ══════════════════

func _sb(color: Color, radius: int = 8) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


func _style_btn(btn: Button, bg: Color = C_BTN):
	btn.add_theme_stylebox_override("normal", _sb(bg, 6))
	btn.add_theme_stylebox_override("hover", _sb(bg.lightened(0.2), 6))
	btn.add_theme_stylebox_override("pressed", _sb(bg.darkened(0.1), 6))
	btn.add_theme_color_override("font_color", C_TEXT)
	btn.add_theme_color_override("font_hover_color", C_ACCENT)
	btn.add_theme_font_size_override("font_size", 13)


# ══════════════════ CHAT MESSAGES ══════════════════

func _add_msg(role: String, text: String):
	var bubble = PanelContainer.new()
	bubble.size_flags_horizontal = SIZE_EXPAND_FILL

	var bg: Color
	var prefix: String
	var pcol: Color

	match role:
		"ai":
			bg = C_AI_BG; prefix = "🤖 AI"; pcol = C_AI
		"user":
			bg = C_USER_BG; prefix = "👤 You"; pcol = C_USER
		"system":
			bg = Color("#2d1b69"); prefix = "⚙️ System"; pcol = C_SYS
		"error":
			bg = Color("#3d1515"); prefix = "❌ Error"; pcol = C_ERR
		_:
			bg = C_PANEL; prefix = ""; pcol = C_TEXT

	var bstyle = _sb(bg, 8)
	if role == "ai":
		bstyle.border_color = C_ACCENT.darkened(0.5)
		bstyle.border_width_left = 3
	bubble.add_theme_stylebox_override("panel", bstyle)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)

	var sender = Label.new()
	sender.text = prefix
	sender.add_theme_color_override("font_color", pcol)
	sender.add_theme_font_size_override("font_size", 13)
	vbox.add_child(sender)

	var content = RichTextLabel.new()
	content.bbcode_enabled = true
	content.fit_content = true
	content.scroll_active = false
	content.size_flags_horizontal = SIZE_EXPAND_FILL
	content.text = _fmt(text)
	content.add_theme_color_override("default_color", C_TEXT)
	content.add_theme_font_size_override("normal_font_size", 15)
	vbox.add_child(content)

	bubble.add_child(vbox)
	chat_container.add_child(bubble)
	
	# Typewriter effect for AI
	if role == "ai":
		content.visible_ratio = 0.0
		var duration = minf(text.length() * 0.01, 3.0) # ~100 chars per sec, max 3 seconds
		var tween = create_tween()
		tween.tween_property(content, "visible_ratio", 1.0, duration).set_trans(Tween.TRANS_LINEAR)
		
		# Keep scrolling down while typing
		var timer = Timer.new()
		timer.wait_time = 0.05
		timer.autostart = true
		timer.timeout.connect(_scroll_bottom)
		content.add_child(timer)
		tween.finished.connect(func(): timer.queue_free())
	
	_scroll_bottom()


func _fmt(text: String) -> String:
	var r = text
	var rx = RegEx.new()
	
	# 1. Multiline Code Blocks (Tolerate typo '```gdscript extends Node')
	rx.compile("```(?:[a-zA-Z0-9_ \\t]*\\n)?([\\s\\S]*?)```")
	for m in rx.search_all(r):
		var content = m.get_string(1).strip_edges()
		r = r.replace(m.get_string(), "\n[color=#a8c7fa][code]\n" + content + "\n[/code][/color]\n")
		
	# 2. Headings (Markdown ###)
	rx.compile("#{1,4}\\s+(.*)")
	for m in rx.search_all(r):
		r = r.replace(m.get_string(), "[b][color=#ffffff]" + m.get_string(1) + "[/color][/b]")

	# 3. Bold
	rx.compile("\\*\\*([^*]+)\\*\\*")
	for m in rx.search_all(r):
		r = r.replace(m.get_string(), "[b]" + m.get_string(1) + "[/b]")
		
	# 4. Inline code
	rx.compile("`([^`]+)`")
	for m in rx.search_all(r):
		r = r.replace(m.get_string(), "[color=#ffb48a]" + m.get_string(1) + "[/color]")
		
	return r


func _scroll_bottom():
	if not is_inside_tree():
		return
	await get_tree().process_frame
	await get_tree().process_frame
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)


func _show_thinking(status: String = "AI is thinking...", phase: String = "scan"):
	# Remove existing if any
	_hide_thinking()

	var panel = PanelContainer.new()
	panel.name = "ThinkingPanel"
	panel.size_flags_horizontal = SIZE_EXPAND_FILL
	
	# Phase-specific border color
	var phase_color = {
		"scan": Color("#42a5f5"),
		"wait": Color("#ffd93d"),
		"read": Color("#64b5f6"),
		"edit": Color("#00e676"),
		"think": Color("#ab47bc")
	}.get(phase, C_ACCENT)
	
	var st = _sb(Color("#0a0e18"), 8)
	st.border_color = phase_color.darkened(0.3)
	st.border_width_left = 3
	st.border_width_bottom = 1
	panel.add_theme_stylebox_override("panel", st)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	
	var vbox = VBoxContainer.new()
	vbox.name = "ThinkingVBox"
	vbox.add_theme_constant_override("separation", 4)

	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	
	# Phase-specific icon
	var phase_icon = {
		"scan": "📂", "wait": "⏳", "read": "📖", "edit": "✏️", "think": "🧠"
	}.get(phase, "⏳")
	
	var spinner = Label.new()
	spinner.text = phase_icon
	spinner.name = "Spinner"
	spinner.add_theme_font_size_override("font_size", 16)
	hbox.add_child(spinner)

	var lbl = Label.new()
	lbl.name = "StatusLabel"
	lbl.text = status
	lbl.add_theme_color_override("font_color", phase_color)
	lbl.add_theme_font_size_override("font_size", 13)
	hbox.add_child(lbl)
	
	vbox.add_child(hbox)
	margin.add_child(vbox)
	panel.add_child(margin)
	chat_container.add_child(panel)
	
	# Pulse animation on icon
	var tween = create_tween().set_loops()
	tween.tween_property(spinner, "modulate:a", 0.3, 0.6)
	tween.tween_property(spinner, "modulate:a", 1.0, 0.6)
	
	_scroll_bottom()

func _update_thinking(status: String, phase: String = "wait"):
	var p = chat_container.get_node_or_null("ThinkingPanel")
	if not p:
		_show_thinking(status, phase)
		return
	
	# Update icon and label
	var phase_icon = {
		"scan": "📂", "wait": "⏳", "read": "📖", "edit": "✏️", "think": "🧠"
	}.get(phase, "⏳")
	var phase_color = {
		"scan": Color("#42a5f5"),
		"wait": Color("#ffd93d"),
		"read": Color("#64b5f6"),
		"edit": Color("#00e676"),
		"think": Color("#ab47bc")
	}.get(phase, C_ACCENT)
	
	var spinner_node = p.find_child("Spinner", true, false)
	if spinner_node: spinner_node.text = phase_icon
	
	var lbl = p.find_child("StatusLabel", true, false)
	if lbl:
		lbl.text = status
		lbl.add_theme_color_override("font_color", phase_color)
	
	# Add log line
	var vbox = p.find_child("ThinkingVBox", true, false)
	if vbox:
		var log_line = Label.new()
		log_line.text = "  " + phase_icon + " " + status
		log_line.add_theme_color_override("font_color", phase_color.darkened(0.4))
		log_line.add_theme_font_size_override("font_size", 11)
		vbox.add_child(log_line)
		_scroll_bottom()


func _hide_thinking():
	var p = chat_container.get_node_or_null("ThinkingPanel")
	if p:
		p.queue_free()


func _add_welcome():
	_add_msg("ai", "Hello! I'm your Godot AI Agent with full project control.\n\nI can:\n• 📖 READ your .gd and .tscn files\n• 💾 CREATE & EDIT scripts and scenes\n• 🗑️ DELETE files\n• 🔧 FIX errors from Godot log\n• 📂 Scan your entire project\n\nI always read your code before editing — I won't make random changes.\n\nFirst, click ⚙️ to set your NVIDIA API key!")


# ══════════════════ SEND LOGIC ══════════════════

func _on_send_pressed():
	_send(input_field.text)

func _on_text_submitted(text: String):
	_send(text)

func _send(text: String):
	if text.strip_edges().is_empty():
		return
	if kimi.is_busy():
		_add_msg("system", "Please wait for the current response.")
		return

	_add_msg("user", text)
	input_field.text = ""
	_read_loop_count = 0

	# Only send file tree on first message or after Clear
	if not _tree_sent:
		_show_thinking("📂 Scanning project structure...", "scan")
		await get_tree().create_timer(0.1).timeout
		var Scanner = load("res://addons/godot_ai_agent/project_scanner.gd")
		var context = Scanner.get_file_tree()
		chat_history.append({"role": "user", "content": text + "\n\n[Project]\n" + context})
		_tree_sent = true
	else:
		chat_history.append({"role": "user", "content": text})

	_send_to_ai()


func _send_to_ai():
	var messages: Array = [ {"role": "system", "content": _system_prompt()}]
	# Token saving: only send last 6 messages
	var recent = chat_history.slice(maxi(0, chat_history.size() - 6))
	messages.append_array(recent)

	_set_status("⏳ Thinking...", C_SYS)
	_update_thinking("Sending to NVIDIA AI...", "wait")
	
	# Show cancel button, hide send button
	send_btn.visible = false
	var cancel = get_node_or_null("CancelBtn")
	if not cancel: # Try finding in children if name-based null
		for c in get_children():
			var found = c.find_child("CancelBtn", true, false)
			if found: cancel = found
	if cancel: cancel.visible = true
	
	kimi.send_chat(messages)


# ══════════════════ AI RESPONSE HANDLER ══════════════════

func _on_ai_response(text: String):
	_hide_thinking()
	
	# Restore buttons
	send_btn.visible = true
	var cancel = get_node_or_null("CancelBtn")
	if not cancel:
		for c in get_children():
			var found = c.find_child("CancelBtn", true, false)
			if found: cancel = found
	if cancel: cancel.visible = false

	# 1) Extract all commands
	var searches = _extract_searches(text)
	var reads = _extract_reads(text)
	var read_lines = _extract_read_lines(text)
	var saves = _extract_saves(text)
	var deletes = _extract_deletes(text)

	# 2) Show CLEAN AI message (no raw code blocks)
	chat_history.append({"role": "assistant", "content": text})
	var clean_text = _clean_display_text(text)
	_add_msg("ai", clean_text)

	# 3) Handle SEARCH requests
	if searches.size() > 0 and _read_loop_count < MAX_READ_LOOPS:
		_read_loop_count += 1
		var Scanner = load("res://addons/godot_ai_agent/project_scanner.gd")
		var search_results := ""
		for q in searches:
			_update_thinking("🔍 Searching for '" + q + "'...", "scan")
			var result = Scanner.search_text(q)
			_add_file_card("Keyword: " + q, "SEARCH", Color("#9c27b0"))
			search_results += "\n=== Search: %s ===\n%s\n" % [q, result]
			
		chat_history.append({
			"role": "user",
			"content": "Search results:\n" + search_results + "\nNow use [READ:] or [READ_LINES:] on the files you need, or proceed."
		})
		_send_to_ai()
		return

	# 3a) Handle READ requests first — auto-read loop
	if reads.size() > 0 and _read_loop_count < MAX_READ_LOOPS:
		_read_loop_count += 1
		var Scanner = load("res://addons/godot_ai_agent/project_scanner.gd")
		var file_contents := ""
		var read_count := 0
		for read_path in reads:
			if read_count >= 3: # Max 3 files per read cycle to save tokens
				break
			_update_thinking("📖 Reading " + read_path.get_file() + "...", "read")
			var content = Scanner.read_file(read_path)
			_add_file_card(read_path, "READ", C_READ)
			file_contents += "\n--- %s ---\n%s\n" % [read_path, content]
			if read_path not in _read_files:
				_read_files.append(read_path)
			read_count += 1
		if reads.size() > 3:
			file_contents += "\n(Skipped %d files. Use [READ:] again for remaining.)" % (reads.size() - 3)
		_update_thinking("🧠 Analyzing " + str(read_count) + " file(s)...", "think")
		chat_history.append({
			"role": "user",
			"content": "File contents:\n" + file_contents + "\nProceed with the task."
		})
		_send_to_ai()
		return

	# 3b) Handle READ_LINES requests
	if read_lines.size() > 0 and _read_loop_count < MAX_READ_LOOPS:
		_read_loop_count += 1
		var Scanner = load("res://addons/godot_ai_agent/project_scanner.gd")
		var file_contents := ""
		for rl in read_lines:
			_update_thinking("📖 Reading lines %d-%d of %s..." % [rl["start"], rl["end"], rl["path"].get_file()], "read")
			var content = Scanner.read_file_lines(rl["path"], rl["start"], rl["end"])
			_add_file_card(rl["path"].get_file() + " (%d-%d)" % [rl["start"], rl["end"]], "READ LINES", C_READ.darkened(0.2))
			file_contents += "\n--- %s (lines %d-%d) ---\n%s\n" % [rl["path"], rl["start"], rl["end"], content]
		chat_history.append({
			"role": "user",
			"content": "File contents:\n" + file_contents + "\nProceed with the task."
		})
		_send_to_ai()
		return

	# 4) If there are SAVE/DELETE ops, validate READ-before-SAVE then show approval
	if saves.size() > 0 or deletes.size() > 0:
		# Validate: block SAVE if file was never READ (force AI to read first)
		var unread_saves: Array[String] = []
		for s in saves:
			var spath: String = s["path"]
			# Allow new file creation (file doesn't exist yet)
			if FileAccess.file_exists(spath) and spath not in _read_files:
				unread_saves.append(spath)
		
		if unread_saves.size() > 0 and _read_loop_count < MAX_READ_LOOPS:
			# AI tried to SAVE without reading — force a read cycle
			_read_loop_count += 1
			var Scanner = load("res://addons/godot_ai_agent/project_scanner.gd")
			var file_contents := ""
			for upath in unread_saves:
				_update_thinking("⚠️ Must read " + upath.get_file() + " before editing...", "read")
				var content = Scanner.read_file(upath)
				_add_file_card(upath, "READ", C_READ)
				file_contents += "\n--- %s ---\n%s\n" % [upath, content]
				if upath not in _read_files:
					_read_files.append(upath)
			_add_msg("system", "⚠️ AI tried to edit without reading first. Auto-reading %d file(s)..." % unread_saves.size())
			chat_history.append({
				"role": "user",
				"content": "SYSTEM: You tried to SAVE files without reading them first. Here are the current contents. You MUST preserve all existing code and only change what was requested:\n" + file_contents + "\nNow redo the edit correctly. Include the COMPLETE file content."
			})
			_send_to_ai()
			return
		
		_pending_saves = []
		for s in saves:
			_pending_saves.append(s)
		_pending_deletes = []
		for d in deletes:
			_pending_deletes.append(d)

		# Show pending file cards
		for save_data in _pending_saves:
			_add_file_card(save_data["path"], "PENDING SAVE", C_SYS)
		for del_path in _pending_deletes:
			_add_file_card(del_path, "PENDING DELETE", C_SYS)

		# Show accept / reject buttons
		_show_approval_ui()
		_set_status("⏸ Waiting for approval...", C_SYS)
		return

	# LIMIT FALLBACK: Prevent silent hanging
	var wants_to_action = reads.size() > 0 or read_lines.size() > 0 or searches.size() > 0 or saves.size() > 0 or deletes.size() > 0
	if wants_to_action and _read_loop_count >= MAX_READ_LOOPS:
		_add_msg("error", "⚠️ AI reached maximum internal steps (%d). Stopped to prevent infinite loop." % MAX_READ_LOOPS)
		_set_status("● Limit Reached", Color("#ffbb00"))
		return

	_set_status("● Ready", Color("#00ff88"))


func _clean_display_text(text: String) -> String:
	"""Strip [SAVE:], [READ:], [DELETE:] tags and code blocks from display."""
	var result = text
	var rx = RegEx.new()

	# Remove [SAVE:path] + code blocks entirely (if AI used backticks)
	rx.compile("\\[SAVE:[^\\]]+\\][\\s\\S]*?```(?:[a-zA-Z]*\\n)?[\\s\\S]*?```")
	for m in rx.search_all(result):
		result = result.replace(m.get_string(), "")

	# FALLSAFE: If AI forgot backticks, we should hide the raw text dump but NOT 
	# truncate the entire message if there's text AFTER it.
	# We'll replace it with a placeholder instead of truncating.
	rx.compile("\\[SAVE:[^\\]]+\\](?:[\\s\\S]*?)(?=\\n\\n|\\n[a-zA-Z]|[\\!\\[]|$)")
	for m in rx.search_all(result):
		result = result.replace(m.get_string(), "[i](Code block hidden)[/i]")

	# Remove [READ:path] tags
	rx.compile("\\[READ:[^\\]]+\\]")
	for m in rx.search_all(result):
		result = result.replace(m.get_string(), "")
		
	# Remove [READ_LINES:path:x-y] tags
	rx.compile("\\[READ_LINES:[^\\]]+\\]")
	for m in rx.search_all(result):
		result = result.replace(m.get_string(), "")
		
	# Remove [SEARCH:keyword] tags
	rx.compile("\\[SEARCH:[^\\]]+\\]")
	for m in rx.search_all(result):
		result = result.replace(m.get_string(), "")

	# Remove [DELETE:path] tags
	rx.compile("\\[DELETE:[^\\]]+\\]")
	for m in rx.search_all(result):
		result = result.replace(m.get_string(), "")

	# Clean up extra blank lines
	while "\n\n\n" in result:
		result = result.replace("\n\n\n", "\n\n")

	return result.strip_edges()


func _show_approval_ui():
	"""Show Accept / Reject buttons for pending file changes."""
	# Remove old approval panel if exists
	if _approval_panel and is_instance_valid(_approval_panel):
		_approval_panel.queue_free()

	_approval_panel = PanelContainer.new()
	_approval_panel.name = "ApprovalPanel"
	_approval_panel.size_flags_horizontal = SIZE_EXPAND_FILL
	var ap_style = _sb(Color("#1a1a3e"), 10)
	ap_style.border_width_top = 2
	ap_style.border_width_bottom = 2
	ap_style.border_color = C_SYS
	_approval_panel.add_theme_stylebox_override("panel", ap_style)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)

	# Files list with Preview button
	for s_data in _pending_saves:
		var row = HBoxContainer.new()
		var lbl = Label.new()
		lbl.text = "💾 " + s_data["path"].get_file()
		lbl.size_flags_horizontal = SIZE_EXPAND_FILL
		lbl.add_theme_color_override("font_color", C_SYS)
		
		var btn = Button.new()
		btn.text = "👀 Preview Diff"
		_style_btn(btn, Color("#2b59c3"))
		# Create local scope binding for lambda
		var path_bind = s_data["path"]
		var content_bind = s_data["content"]
		btn.pressed.connect(func(): _preview_diff(path_bind, content_bind))
		
		row.add_child(lbl)
		row.add_child(btn)
		vbox.add_child(row)
		
	for d_path in _pending_deletes:
		var row = HBoxContainer.new()
		var lbl = Label.new()
		lbl.text = "🗑️ " + d_path.get_file()
		lbl.size_flags_horizontal = SIZE_EXPAND_FILL
		lbl.add_theme_color_override("font_color", C_ERR)
		row.add_child(lbl)
		vbox.add_child(row)

	# Buttons row
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)

	var accept_btn = Button.new()
	accept_btn.text = "✅ Accept Changes"
	accept_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	accept_btn.custom_minimum_size = Vector2(0, 32)
	_style_btn(accept_btn, C_SAVE.darkened(0.5))
	accept_btn.pressed.connect(_on_accept_changes)
	btn_row.add_child(accept_btn)

	var reject_btn = Button.new()
	reject_btn.text = "❌ Reject"
	reject_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	reject_btn.custom_minimum_size = Vector2(0, 32)
	_style_btn(reject_btn, C_DELETE.darkened(0.5))
	reject_btn.pressed.connect(_on_reject_changes)
	btn_row.add_child(reject_btn)

	vbox.add_child(btn_row)
	_approval_panel.add_child(vbox)

	# Animate in
	_approval_panel.modulate.a = 0.0
	chat_container.add_child(_approval_panel)

	var tween = create_tween()
	tween.tween_property(_approval_panel, "modulate:a", 1.0, 0.3)
	_scroll_bottom()

func _preview_diff(path: String, new_content: String):
	var old_content = ""
	if FileAccess.file_exists(path):
		var file = FileAccess.open(path, FileAccess.READ)
		if file:
			old_content = file.get_as_text()
			file.close()

	var win = Window.new()
	win.title = "Unified Diff Preview: " + path.get_file()
	win.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_MAIN_WINDOW_SCREEN
	win.size = Vector2(900, 650)
	win.close_requested.connect(win.queue_free)

	var panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var pstyle = StyleBoxFlat.new()
	pstyle.bg_color = Color("#1e1e1e")
	panel.add_theme_stylebox_override("panel", pstyle)

	var ce = CodeEdit.new()
	ce.editable = false
	ce.draw_tabs = true
	ce.gutters_draw_line_numbers = true
	ce.minimap_draw = true
	ce.scroll_past_end_of_file = true
	ce.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ce.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# Try to use editor theme for fonts
	if Engine.is_editor_hint():
		var ed_theme = EditorInterface.get_editor_theme()
		if ed_theme:
			ce.theme = ed_theme
			var font = ed_theme.get_font("source", "EditorFonts")
			if font: ce.add_theme_font_override("font", font)
			var font_size = ed_theme.get_font_size("source_size", "EditorFonts")
			if font_size: ce.add_theme_font_size_override("font_size", font_size)

	# --- Unified Diff Calculation (LCS) ---
	var old_lines = old_content.split("\n")
	var new_lines = new_content.split("\n")
	
	var m = old_lines.size()
	var n = new_lines.size()
	var diff_ops = []
	
	# Max ~3162x3162 grid, prevents long freezing on massive files
	if m * n < 10000000:
		var L = []
		for i in range(m + 1):
			var row = []
			row.resize(n + 1)
			row.fill(0)
			L.append(row)
			
		for i in range(1, m + 1):
			for j in range(1, n + 1):
				if old_lines[i - 1] == new_lines[j - 1]:
					L[i][j] = L[i - 1][j - 1] + 1
				else:
					L[i][j] = maxi(L[i - 1][j], L[i][j - 1])
					
		var i = m
		var j = n
		
		while i > 0 and j > 0:
			if old_lines[i - 1] == new_lines[j - 1]:
				diff_ops.push_front({"type": "=", "text": old_lines[i - 1]})
				i -= 1
				j -= 1
			elif L[i - 1][j] > L[i][j - 1]:
				diff_ops.push_front({"type": "-", "text": old_lines[i - 1]})
				i -= 1
			else:
				diff_ops.push_front({"type": "+", "text": new_lines[j - 1]})
				j -= 1
				
		while i > 0:
			diff_ops.push_front({"type": "-", "text": old_lines[i - 1]})
			i -= 1
		while j > 0:
			diff_ops.push_front({"type": "+", "text": new_lines[j - 1]})
			j -= 1
			
	else:
		# Fallback for massive files: Just show old then new to prevent engine freeze
		for line in old_lines: diff_ops.append({"type": "-", "text": line})
		for line in new_lines: diff_ops.append({"type": "+", "text": line})
			
	var diff_lines = PackedStringArray()
	for op in diff_ops:
		if op.type == "+":
			diff_lines.append("+ " + op.text)
		elif op.type == "-":
			diff_lines.append("- " + op.text)
		else:
			diff_lines.append("  " + op.text)
			
	ce.text = "\n".join(diff_lines)
	
	# Apply background colors
	for i in range(diff_ops.size()):
		if diff_ops[i].type == "+":
			ce.set_line_background_color(i, Color(0.1, 0.8, 0.1, 0.2)) # Green
		elif diff_ops[i].type == "-":
			ce.set_line_background_color(i, Color(0.8, 0.1, 0.1, 0.2)) # Red

	panel.add_child(ce)
	win.add_child(panel)
	add_child(win)
	win.popup()


func _on_accept_changes():
	"""User approved — apply all pending saves and deletes."""
	_set_status("⏳ Saving...", C_SYS)
	
	# Remove approval UI instantly
	if _approval_panel and is_instance_valid(_approval_panel):
		_approval_panel.queue_free()
		_approval_panel = null

	var fs = EditorInterface.get_resource_filesystem() if Engine.is_editor_hint() else null
	
	# Apply saves
	for save_data in _pending_saves:
		var path = save_data["path"]
		var ok = _write_project_file(path, save_data["content"])
		if ok:
			_add_file_card(path, "SAVED", C_SAVE)
			if fs:
				fs.update_file(path)
				# Force reload if it's an open script
				# This can be slow, so we only do it for GDScript
				if path.ends_with(".gd"):
					var res = load(path)
					if res is Script:
						res.reload()
		else:
			_add_file_card(path, "SAVE FAILED", C_ERR)

	# Apply deletes
	for del_path in _pending_deletes:
		var ok = _delete_project_file(del_path)
		if ok:
			_add_file_card(del_path, "DELETED", C_DELETE)
			if fs: fs.update_file(del_path)
		else:
			_add_file_card(del_path, "DELETE FAILED", C_ERR)

	_add_msg("system", "✅ All changes applied!")

	# Force Godot to recognize the new files
	if fs:
		# Use scan() instead of re_scan_resources() for better performance
		fs.scan()
		
		# Wait just one frame for the OS to flush if needed
		await get_tree().process_frame
		
		# Refresh inspector if needed
		var edited = EditorInterface.get_inspector().get_edited_object()
		if edited:
			EditorInterface.get_inspector().edit(edited)

	_pending_saves.clear()
	_pending_deletes.clear()
	_set_status("● Ready", Color("#00ff88"))

func _on_cancel_pressed():
	kimi.cancel_request()
	_hide_thinking()
	
	# Restore buttons
	send_btn.visible = true
	var cancel = get_node_or_null("CancelBtn")
	if not cancel:
		for c in get_children():
			var found = c.find_child("CancelBtn", true, false)
			if found: cancel = found
	if cancel: cancel.visible = false
	
	_set_status("● Cancelled", Color("#ffbb00"))
	_add_msg("system", "⏹ Request cancelled by user.")


func _on_reject_changes():
	"""User rejected — discard all pending changes."""
	if _approval_panel and is_instance_valid(_approval_panel):
		_approval_panel.queue_free()
		_approval_panel = null

	var count = _pending_saves.size() + _pending_deletes.size()
	_pending_saves.clear()
	_pending_deletes.clear()

	_add_msg("system", "❌ Changes rejected. %d file operation(s) discarded." % count)
	_set_status("● Ready", Color("#00ff88"))


func _on_ai_error(error: String):
	_hide_thinking()
	_add_msg("error", error)
	_set_status("● Error", C_ERR)


func _set_status(text: String, color: Color):
	if status_label:
		status_label.text = text
		status_label.add_theme_color_override("font_color", color)


# ══════════════════ FILE OPERATIONS ══════════════════

func _extract_searches(text: String) -> Array[String]:
	"""Extract [SEARCH:keyword] tags."""
	var results: Array[String] = []
	var rx = RegEx.new()
	rx.compile("\\[SEARCH:([^\\]]+)\\]")
	for m in rx.search_all(text):
		var k = m.get_string(1).strip_edges()
		if k != "" and k not in results:
			results.append(k)
	return results


func _extract_reads(text: String) -> Array[String]:
	"""Extract [READ:path] tags from AI response."""
	var paths: Array[String] = []
	var rx = RegEx.new()
	# Match either [READ:path] or <parameter=file>path</parameter> (fallback for weird models)
	rx.compile("\\[READ:([^\\]]+)\\]|<parameter=file>\\s*(.*?)\\s*<\\/parameter>")
	for m in rx.search_all(text):
		var p = m.get_string(1)
		if p == "":
			p = m.get_string(2)
		
		# Bersihkan spasi dan newline jika AI typo
		p = p.replace(" ", "").replace("\n", "").replace("\r", "")
			
		# AI often forgets res:// when hallucinating tool calls
		if p != "" and not p.begins_with("res://"):
			p = "res://" + p.trim_prefix("/")
			
		if p != "" and p not in paths:
			paths.append(p)
	return paths


func _extract_read_lines(text: String) -> Array[Dictionary]:
	"""Extract [READ_LINES:path:start-end] tags."""
	var results: Array[Dictionary] = []
	var rx = RegEx.new()
	# Allow any characters for path until the last colon before digits
	rx.compile("\\[READ_LINES:\\s*(.+?)\\s*:\\s*(\\d+)\\s*-\\s*(\\d+)\\s*\\]")
	for m in rx.search_all(text):
		var p = m.get_string(1).replace(" ", "").replace("\n", "").replace("\r", "")
		if not p.begins_with("res://"):
			p = "res://" + p.trim_prefix("/")
		results.append({
			"path": p,
			"start": int(m.get_string(2)),
			"end": int(m.get_string(3))
		})
	return results


func _extract_saves(text: String) -> Array[Dictionary]:
	"""Extract [SAVE:path] + code block pairs, even if AI hallucinated format!"""
	var saves: Array[Dictionary] = []
	var rx = RegEx.new()
	rx.compile("\\[SAVE:([^\\]]+)\\]")
	
	var matches = rx.search_all(text)
	if matches.is_empty():
		return saves
		
	var has_backticks = text.find("```") != -1
	if has_backticks:
		var rx_full = RegEx.new()
		# Matches "```gdscript extends Node" by ignoring [a-zA-Z0-9_ \t] before \n
		rx_full.compile("\\[SAVE:([^\\]]+)\\][\\s\\S]*?```(?:[a-zA-Z0-9_ \\t]*\\n)?([\\s\\S]*?)```")
		for m in rx_full.search_all(text):
			saves.append({
				"path": m.get_string(1).strip_edges(),
				"content": _clean_extraneous_gdscript(m.get_string(2))
			})
		if saves.size() == matches.size() or saves.size() > 0:
			return saves
			
	# FALLBACK: AI completely forgot backticks ``` !
	# We manually slice the text up to the next [SAVE:...] or EOF.
	for i in matches.size():
		var path = matches[i].get_string(1).strip_edges()
		var start_pos = matches[i].get_end()
		var end_pos = text.length()
		if i + 1 < matches.size():
			end_pos = matches[i + 1].get_start()
			
		var block = text.substr(start_pos, end_pos - start_pos)
		
		# If this specific block has backticks, use it
		var rx_block = RegEx.new()
		rx_block.compile("```(?:[a-zA-Z0-9_ \\t]*\\n)?([\\s\\S]*?)```")
		var code_match = rx_block.search(block)
		if code_match:
			saves.append({"path": path, "content": _clean_extraneous_gdscript(code_match.get_string(1))})
			continue
			
		# Else, raw unstructured text dump. Strip conversational boilerplate.
		saves.append({"path": path, "content": _clean_extraneous_gdscript(_strip_code_boilerplate(block))})
		
	return saves

func _clean_extraneous_gdscript(code: String) -> String:
	"""Removes accidental 'gdscript' word glued to 'extends Node'."""
	var result = code.strip_edges()
	if result.begins_with("gdscript"):
		var after = result.substr(8).strip_edges()
		if after.begins_with("extends ") or after.begins_with("class_name ") or after.begins_with("@") or after.begins_with("func ") or after.begins_with("var ") or after.begins_with("const ") or after.begins_with("signal ") or after.begins_with("#"):
			# It was hallucinated, strip the 'gdscript' out.
			return after
	return result


func _strip_code_boilerplate(block: String) -> String:
	"""Finds where the actual GDScript begins when backticks are absent."""
	var lines = block.split("\n")
	var result = []
	var in_code = false
	for line in lines:
		var ln = line.strip_edges()
		if not in_code:
			var test_ln = ln
			if test_ln.begins_with("gdscript"):
				test_ln = test_ln.substr(8).strip_edges()
				
			if test_ln.begins_with("extends ") or test_ln.begins_with("class_name ") or test_ln.begins_with("@") or test_ln.begins_with("func ") or test_ln.begins_with("var ") or test_ln.begins_with("const ") or test_ln.begins_with("signal ") or test_ln.begins_with("#"):
				in_code = true
				if test_ln != ln:
					line = line.replace("gdscript", "").strip_edges()
			elif test_ln.begins_with("[gd_scene ") or test_ln.begins_with("[gd_resource "):
				in_code = true
				if test_ln != ln:
					line = line.replace("gdscript", "").strip_edges()
		if in_code:
			result.append(line)
			
	if result.is_empty():
		return block.strip_edges()
	return "\n".join(result).strip_edges()


func _extract_deletes(text: String) -> Array[String]:
	"""Extract [DELETE:path] tags."""
	var paths: Array[String] = []
	var rx = RegEx.new()
	rx.compile("\\[DELETE:([^\\]]+)\\]")
	for m in rx.search_all(text):
		paths.append(m.get_string(1).strip_edges())
	return paths


func _write_project_file(path: String, content: String) -> bool:
	"""Write a file to the project. Only res:// paths allowed."""
	if not path.begins_with("res://"):
		print("[AI Agent] ⚠️ Blocked: ", path, " (not res://)")
		return false
	for b in [".godot", ".import", ".git"]:
		if b in path:
			print("[AI Agent] ⚠️ Blocked protected: ", path)
			return false

	# Auto-create directories
	var dir_path = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		print("[AI Agent] ❌ Cannot write: ", path)
		return false

	file.store_string(content)
	file.close()
	print("[AI Agent] ✅ Saved: ", path)
	return true


func _delete_project_file(path: String) -> bool:
	"""Delete a file from the project. Only res:// paths allowed."""
	if not path.begins_with("res://"):
		print("[AI Agent] ⚠️ Blocked delete: ", path)
		return false
	for b in [".godot", ".import", ".git", "addons/godot_ai_agent"]:
		if b in path:
			print("[AI Agent] ⚠️ Blocked delete protected: ", path)
			return false

	var err = DirAccess.remove_absolute(path)
	if err == OK:
		print("[AI Agent] 🗑️ Deleted: ", path)
		return true
	else:
		print("[AI Agent] ❌ Cannot delete: ", path, " (err: ", err, ")")
		return false


# ══════════════════ ANIMATED FILE CARDS ══════════════════

func _add_file_card(path: String, operation: String, color: Color):
	"""Show an animated card for a file operation."""
	var card = PanelContainer.new()
	card.size_flags_horizontal = SIZE_EXPAND_FILL

	var cstyle = _sb(Color("#0d1117"), 10)
	cstyle.border_width_left = 4
	cstyle.border_color = color
	card.add_theme_stylebox_override("panel", cstyle)

	# Clickable overlay for navigation
	var btn_overlay = Button.new()
	btn_overlay.flat = true
	btn_overlay.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn_overlay.size_flags_horizontal = SIZE_EXPAND_FILL
	btn_overlay.size_flags_vertical = SIZE_EXPAND_FILL
	btn_overlay.pressed.connect(func(): _open_file_in_editor(path))
	
	# Add hover visual
	btn_overlay.mouse_entered.connect(func():
		cstyle.bg_color = Color("#1c222d")
		card.add_theme_stylebox_override("panel", cstyle)
	)
	btn_overlay.mouse_exited.connect(func():
		cstyle.bg_color = Color("#0d1117")
		card.add_theme_stylebox_override("panel", cstyle)
	)

	var hbox = HBoxContainer.new()
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE # Let click pass to button underground
	hbox.add_theme_constant_override("separation", 10)

	# Operation icon
	var icon_map := {
		"SAVED": "💾", "READ": "📖", "READ LINES": "📖", "SEARCH": "🔍", "DELETED": "🗑️",
		"SAVE FAILED": "❌", "DELETE FAILED": "❌",
		"PENDING SAVE": "⏳", "PENDING DELETE": "⚠️"
	}
	var icon = Label.new()
	icon.text = icon_map.get(operation, "📄")
	icon.add_theme_font_size_override("font_size", 20)
	hbox.add_child(icon)

	# File info
	var info = VBoxContainer.new()
	info.size_flags_horizontal = SIZE_EXPAND_FILL

	var fname = Label.new()
	var file_icon = "📜 " if path.ends_with(".gd") else "🎬 " if path.ends_with(".tscn") else "📄 "
	fname.text = file_icon + path.get_file()
	fname.add_theme_color_override("font_color", C_TEXT)
	fname.add_theme_font_size_override("font_size", 13)
	info.add_child(fname)

	var detail = Label.new()
	detail.text = operation + " — " + path
	detail.add_theme_color_override("font_color", color.lightened(0.3))
	detail.add_theme_font_size_override("font_size", 10)
	info.add_child(detail)

	hbox.add_child(info)

	# Status badge
	var badge = Label.new()
	badge.text = "✓" if "FAILED" not in operation else "✗"
	badge.add_theme_color_override("font_color", color)
	badge.add_theme_font_size_override("font_size", 18)
	hbox.add_child(badge)

	card.add_child(hbox)
	card.add_child(btn_overlay) # Floating over the card contents

	# Start invisible for animation
	card.modulate.a = 0.0
	chat_container.add_child(card)

	# Animate: fade in + slide from left
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "modulate:a", 1.0, 0.35).set_ease(Tween.EASE_OUT)

	# Color pulse on the border
	var tween2 = create_tween()
	tween2.tween_property(cstyle, "border_color", color.lightened(0.5), 0.2)
	tween2.tween_property(cstyle, "border_color", color, 0.3)

	_scroll_bottom()

func _open_file_in_editor(path: String):
	if not Engine.is_editor_hint(): return
	var res = load(path)
	if res:
		EditorInterface.select_file(path)
		EditorInterface.edit_resource(res)
		_set_status("📖 Opened " + path.get_file(), C_AI)
	else:
		_set_status("❌ Cannot find " + path.get_file(), C_ERR)


# ══════════════════ QUICK ACTIONS ══════════════════

func _on_generate():
	_send("Generate a new GDScript for my project. Ask me what kind of script I need, then create and SAVE the complete script file.")

func _on_fix():
	# Read Godot log and send errors
	var Scanner = load("res://addons/godot_ai_agent/project_scanner.gd")
	var log_text = Scanner.read_godot_log()
	_send("Read my project files, check the error log below, and fix any errors you find. SAVE the corrected files.\n\nGodot Log:\n" + log_text)

func _on_explain():
	_send("Read all the scripts in my project and explain what each one does in detail.")

func _on_create_node():
	_send("Help me create a new node structure for my project. Ask me what I need, then CREATE and SAVE the .tscn and .gd files.")

func _on_scan():
	var Scanner = load("res://addons/godot_ai_agent/project_scanner.gd")
	var tree = Scanner.get_file_tree()
	_add_msg("system", "📂 Project Structure:\n\n" + tree)

func _on_clear():
	for child in chat_container.get_children():
		child.queue_free()
	chat_history.clear()
	_tree_sent = false # Re-send tree on next message
	_read_files.clear() # Reset read tracking
	_add_welcome()


# ══════════════════ SETTINGS ══════════════════

func _show_settings():
	var dialog = AcceptDialog.new()
	dialog.title = "🤖 AI Agent Settings"
	dialog.min_size = Vector2(420, 180)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)

	var lbl = Label.new()
	lbl.text = "NVIDIA API Key:"
	lbl.add_theme_font_size_override("font_size", 14)
	vbox.add_child(lbl)

	var info = Label.new()
	info.text = "Get your free key at: build.nvidia.com"
	info.add_theme_color_override("font_color", Color("#888888"))
	info.add_theme_font_size_override("font_size", 11)
	vbox.add_child(info)

	var key_input = LineEdit.new()
	key_input.placeholder_text = "nvapi-..."
	key_input.secret = true
	key_input.text = kimi.api_key
	key_input.custom_minimum_size = Vector2(380, 28)
	vbox.add_child(key_input)

	dialog.add_child(vbox)
	add_child(dialog)

	dialog.confirmed.connect(func():
		var new_key = key_input.text.strip_edges()
		if not new_key.is_empty():
			kimi.save_api_key(new_key)
			_add_msg("system", "✅ API key saved! You're ready to chat.")
			_set_status("● Ready", Color("#00ff88"))
	)
	dialog.popup_centered()


# ══════════════════ SYSTEM PROMPT ══════════════════

func _system_prompt() -> String:
	return """You are a helpful and expert AI Assistant for Godot 4.x (GDScript).
You have direct control over the user's project files.
Be conversational, friendly, and act as a professional assistant (asisten).
You can discuss ideas, explain logic, and help with project structure.

═══ AVAILABLE COMMANDS ═══
[SEARCH:keyword] — Search for a class, func, or var definition across all files
[READ:res://path/file.gd] — Read a file (max 150 lines shown)
[READ_LINES:res://path/file.gd:50-120] — Read specific line range

To SAVE/OVERWRITE a file, you MUST use this EXACT format WITH the markdown backticks:
[SAVE:res://path/file.gd]
```gdscript
# ALL complete code here
```

[DELETE:res://path/file.gd] — Delete a file

═══ BEHAVIOR & RULES ═══

1. BE A TRUE ASSISTANT:
   - Don't just dump code. Explain WHY you chose an approach if it's complex.
   - If the user asks for advice, give it before or after the code tags.
   - You can discuss game design, performance, and best practices.

2. READ BEFORE EDIT (MANDATORY):
   - You MUST [READ:] or [SEARCH:] a file BEFORE editing it. NEVER guess.
   - If you can't find a function, use [SEARCH:function_name] first.
   - If the user says "edit X", your FIRST response must be [READ:res://path/to/X].
   - DO NOT ask for permission to read. Just use the [READ:]/[READ_LINES:] tag IMMEDIATELY.

3. COMPLETE FILE ONLY:
   - When using [SAVE:], you MUST include the ENTIRE file content.
   - NEVER use comments like "# ... rest of code ...".

4. FORMATTING STRICTNESS:
   - GDScript is indentation-based! Put a line break (ENTER) after EVERY statement.
   - NEVER write multiple statements on the same line. 

5. GODOT 4.x SYNTAX ONLY:
   - Use @export, @onready, @tool, snake_case, signal connections, etc.

6. RESPONSE FORMAT:
   - You can write paragraphs for explanation.
   - Use brief lists for change logs.
   - If unsure about something, ASK the user. Don't guess."""
