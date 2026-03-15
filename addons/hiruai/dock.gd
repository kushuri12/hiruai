@tool
extends VBoxContainer

# ──────────────────── Node References ────────────────────
var kimi: Node
var chat_container: VBoxContainer
var scroll: ScrollContainer
var input_field: TextEdit
var send_btn: Button
var status_label: Label
var toolbox_panel: VBoxContainer
var toolbox_btn: Button

# ──────────────────── UI State ────────────────────
var tabs: TabContainer
var chat_tab: VBoxContainer
var agent_tab: VBoxContainer
var project_tab: VBoxContainer
var history_tab: VBoxContainer
var model_status: Button
var _nav_buttons: Array[Button] = []
var _nav_indicator: ColorRect = null
var _nav_hbox: HBoxContainer = null
var _context_files: Array[String] = []
var _token_count_label: Label = null
var _total_tokens := 0
var _conversation_list: Array[Dictionary] = [] # {title, messages, timestamp}
var _current_conversation_title := ""
var _model_quick_btn: Button = null
var _attachments_bar: HBoxContainer = null
var _cmd_popup: PopupPanel = null
var _file_suggestion_popup: PopupPanel = null
var _undo_stack: Array[Dictionary] = [] # [{path, old_content, type}]

# ──────────────────── Agent State ────────────────────
var chat_history: Array = []
var _read_loop_count: int = 0
var _stall_retry_count: int = 0

var _pending_saves: Array[Dictionary] = []
var _pending_replaces: Array[Dictionary] = []
var _pending_deletes: Array[String] = []
var _approval_panel: PanelContainer = null
var _tree_sent := false
var _read_files: Array[String] = []
var _self_healing_enabled := false
var _is_game_running_monitored := false
var _last_auto_attach_time := 0
const AUTO_ATTACH_COOLDOWN := 5000  # 5 seconds
var _auto_attach_enabled := false
var _consecutive_error_count := 0
var _log_offset: int = 0

# ──────────────────── Streaming State ────────────────────
var _streaming_bubble: PanelContainer = null
var _streaming_content: RichTextLabel = null
var _streaming_raw_text := ""
var _thought_streaming_label: RichTextLabel = null
var _last_thought_chip: Button = null
var _activity_log: Array[Dictionary] = [] # {icon, text, color, timestamp}
var _activity_panel: PanelContainer = null
var _step_counter := 0
var _last_request_time := 0
var _thinking_duration_sec := 0
var _quick_actions_bar: HBoxContainer = null

# ──────────────────── State Machine ────────────────────
enum AgentState {
	IDLE,
	ANALYZING,      # Reading/Scanning
	PLANNING,       # THOUGHT/PLAN generation
	EXECUTING,      # SAVE/REPLACE operations
	VERIFYING,      # Syntax check
	ERROR_RECOVERY, # Fixing errors
	COMPLETED
}
var _current_state := AgentState.IDLE
var _state_timeout := 0


func _ready():
	custom_minimum_size = Vector2(120, 400)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Root Styling
	var bg = StyleBoxFlat.new()
	bg.bg_color = HiruConst.C_BG_DEEP
	add_theme_stylebox_override("panel", bg)
	
	_build_ui()
	_setup_kimi()
	
	# Sync editor script changed (Cursor Style)
	if Engine.is_editor_hint():
		var se = EditorInterface.get_script_editor()
		if se: se.editor_script_changed.connect(_on_editor_script_changed)
	_add_welcome()
	_load_context()


# ══════════════════ KIMI SETUP ══════════════════

func _setup_kimi():
	# Kill existing to prevent signal duplication or memory leaks
	var existing = get_node_or_null("KimiClient")
	if existing: existing.queue_free()
	
	var kimi_path = "res://addons/hiruai/kimi_client.gd"
	var KimiScript = load(kimi_path)
	if not KimiScript:
		printerr("[HiruAI] Failed to load kimi_client.gd script!")
		return
		
	kimi = Node.new()
	kimi.set_script(KimiScript)
	kimi.name = "KimiClient"
	add_child(kimi)
	
	# Force an update of the instance properties in tool mode
	if kimi.has_method("load_config"):
		kimi.call("load_config")
	
	# Dynamic signal connection for stability during tool script reloads
	var signals = ["chat_completed", "chat_error", "stream_started", "token_received"]
	var callbacks = [_on_ai_response, _on_ai_error, _on_stream_started, _on_token_received]
	
	for i in signals.size():
		var sig = signals[i]
		if kimi.has_signal(sig):
			if not kimi.is_connected(sig, callbacks[i]):
				kimi.connect(sig, callbacks[i])
	
	# Update model button now that kimi is ready
	if _model_quick_btn and is_instance_valid(kimi) and "current_model" in kimi:
		_model_quick_btn.text = " ⚡ " + str(kimi.get("current_model")).get_file().left(12)

func _ensure_kimi() -> bool:
	"""Ensures kimi is a real object, not a placeholder from a failed compile."""
	if not is_instance_valid(kimi) or not "PROVIDER_MODELS" in kimi:
		_setup_kimi()
	return is_instance_valid(kimi) and "PROVIDER_MODELS" in kimi


# ══════════════════ UI CONSTRUCTION ══════════════════

func _build_ui():
	add_theme_constant_override("separation", 0)
	
	_build_nav_bar() # Premium Tab Nav with indicator
	
	# Main Content Area
	var content_wrap = PanelContainer.new()
	content_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_wrap.add_theme_stylebox_override("panel", HiruUtils.sb(HiruConst.C_BG_DEEP, 0))
	
	tabs = TabContainer.new()
	tabs.tabs_visible = false # We use custom nav bar
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	
	# TAB 1: Chat
	chat_tab = VBoxContainer.new()
	chat_tab.name = "Chat"
	_build_chat_area()
	tabs.add_child(chat_tab)
	
	# TAB 2: Agent
	agent_tab = VBoxContainer.new()
	agent_tab.name = "Agent"
	_build_agent_area()
	tabs.add_child(agent_tab)
	
	# TAB 3: Project
	project_tab = VBoxContainer.new()
	project_tab.name = "Project"
	_build_project_area()
	tabs.add_child(project_tab)
	
	# TAB 4: History
	history_tab = VBoxContainer.new()
	history_tab.name = "History"
	_build_history_area()
	tabs.add_child(history_tab)
	
	content_wrap.add_child(tabs)
	add_child(content_wrap)
	
	# Thin accent border instead of HSeparator
	var border = ColorRect.new()
	border.color = HiruConst.C_BORDER
	border.custom_minimum_size.y = 1
	add_child(border)
	
	_build_context_bar()
	_build_input_area()
	_build_toolbox_toggle()
	_build_action_buttons()


func _build_nav_bar():
	var bar = PanelContainer.new()
	bar.name = "NavBar"
	var style = HiruUtils.sb(HiruConst.C_BG_SIDEBAR, 0)
	style.content_margin_top = 6
	style.content_margin_bottom = 2
	style.content_margin_left = 8
	style.content_margin_right = 8
	bar.add_theme_stylebox_override("panel", style)
	
	var outer_vbox = VBoxContainer.new()
	outer_vbox.add_theme_constant_override("separation", 0)
	
	# Top row: tabs + model + settings
	_nav_hbox = HBoxContainer.new()
	_nav_hbox.add_theme_constant_override("separation", 0)
	
	_nav_buttons.clear()
	_add_nav_btn(_nav_hbox, "💬", 0)
	_add_nav_btn(_nav_hbox, "🤖", 1)
	_add_nav_btn(_nav_hbox, "📂", 2)
	_add_nav_btn(_nav_hbox, "📜", 3)
	
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nav_hbox.add_child(spacer)
	
	# Quick model switcher button
	_model_quick_btn = Button.new()
	_model_quick_btn.name = "ModelQuickBtn"
	var model_name = "Model"
	if is_instance_valid(kimi) and "current_model" in kimi:
		model_name = str(kimi.get("current_model")).get_file().left(12)
	_model_quick_btn.text = "⚡"
	_model_quick_btn.flat = true
	_model_quick_btn.add_theme_font_size_override("font_size", 11)
	_model_quick_btn.add_theme_color_override("font_color", HiruConst.C_ACCENT_ALT)
	_model_quick_btn.tooltip_text = "Quick switch AI model"
	_model_quick_btn.pressed.connect(_show_quick_model_menu)
	_model_quick_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_nav_hbox.add_child(_model_quick_btn)
	
	# Token counter
	_token_count_label = Label.new()
	_token_count_label.name = "TokenCount"
	_token_count_label.text = ""
	_token_count_label.add_theme_font_size_override("font_size", 10)
	_token_count_label.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	_token_count_label.tooltip_text = "Tokens used"
	_nav_hbox.add_child(_token_count_label)
	
	var settings_btn = Button.new()
	settings_btn.text = "⚙"
	settings_btn.flat = true
	settings_btn.add_theme_font_size_override("font_size", 14)
	settings_btn.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	settings_btn.add_theme_color_override("font_hover_color", HiruConst.C_ACCENT)
	settings_btn.pressed.connect(_show_settings)
	settings_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_nav_hbox.add_child(settings_btn)
	
	outer_vbox.add_child(_nav_hbox)
	
	# Animated underline indicator
	var indicator_bar = Control.new()
	indicator_bar.custom_minimum_size.y = 2
	_nav_indicator = ColorRect.new()
	_nav_indicator.name = "NavIndicator"
	_nav_indicator.color = HiruConst.C_ACCENT
	_nav_indicator.custom_minimum_size = Vector2(40, 2)
	_nav_indicator.position = Vector2(0, 0)
	indicator_bar.add_child(_nav_indicator)
	outer_vbox.add_child(indicator_bar)
	
	bar.add_child(outer_vbox)
	add_child(bar)
	
	# Set initial active state
	_update_nav_active(0)

func _add_nav_btn(parent, label: String, idx: int):
	var btn = Button.new()
	btn.text = label
	btn.flat = true
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(_on_nav_btn_pressed.bind(idx))
	_nav_buttons.append(btn)
	parent.add_child(btn)

func _update_nav_active(idx: int):
	for i in _nav_buttons.size():
		var c = HiruConst.C_ACCENT if i == idx else HiruConst.C_TEXT_DIM
		_nav_buttons[i].add_theme_color_override("font_color", c)
	# Animate indicator
	if _nav_indicator and _nav_buttons.size() > idx:
		var target_btn = _nav_buttons[idx]
		var tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		tween.tween_property(_nav_indicator, "position:x", target_btn.position.x, 0.25)
		tween.parallel().tween_property(_nav_indicator, "custom_minimum_size:x", target_btn.size.x, 0.25)

func _build_chat_area():
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	
	var chat_panel = PanelContainer.new()
	chat_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_panel.add_theme_stylebox_override("panel", HiruUtils.sb(HiruConst.C_BG_DEEP, 0))
	
	chat_container = VBoxContainer.new()
	chat_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_container.add_theme_constant_override("separation", 2)
	
	scroll.add_child(chat_container)
	chat_panel.add_child(scroll)
	chat_tab.add_child(chat_panel) # NOW ATTACHED TO TAB

func _build_agent_area():
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var title = Label.new()
	title.text = "AGENT ACTIVITY"
	title.add_theme_color_override("font_color", HiruConst.C_ACCENT)
	title.add_theme_font_size_override("font_size", 11)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	
	var step_lbl = Label.new()
	step_lbl.name = "StepCount"
	step_lbl.text = "0 steps"
	step_lbl.add_theme_font_size_override("font_size", 9)
	step_lbl.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	header.add_child(step_lbl)
	vbox.add_child(header)
	
	_activity_panel = PanelContainer.new()
	_activity_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_activity_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	
	var activiy_scroll = ScrollContainer.new()
	activiy_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var activity_list = VBoxContainer.new()
	activity_list.name = "ActivityList"
	activity_list.add_theme_constant_override("separation", 3)
	activiy_scroll.add_child(activity_list)
	_activity_panel.add_child(activiy_scroll)
	
	vbox.add_child(_activity_panel)
	margin.add_child(vbox)
	agent_tab.add_child(margin)

func _build_project_area():
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var title = Label.new()
	title.text = "PROJECT CONTEXT"
	title.add_theme_color_override("font_color", HiruConst.C_ACCENT_ALT)
	title.add_theme_font_size_override("font_size", 11)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	
	var scan_btn = Button.new()
	scan_btn.text = "🔄 Scan"
	scan_btn.flat = true
	scan_btn.add_theme_font_size_override("font_size", 10)
	scan_btn.add_theme_color_override("font_color", HiruConst.C_ACCENT_ALT)
	scan_btn.pressed.connect(_on_scan)
	scan_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	header.add_child(scan_btn)
	vbox.add_child(header)
	
	var proj_scroll = ScrollContainer.new()
	proj_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var stats = Label.new()
	stats.name = "FileStats"
	stats.text = "Click 🔄 Scan to analyze your project."
	stats.add_theme_font_size_override("font_size", 13)
	stats.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	proj_scroll.add_child(stats)
	
	vbox.add_child(proj_scroll)
	margin.add_child(vbox)
	project_tab.add_child(margin)

func _build_history_area():
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	var title = Label.new()
	title.text = "CONVERSATION HISTORY"
	title.add_theme_color_override("font_color", HiruConst.C_ACCENT_ALT)
	title.add_theme_font_size_override("font_size", 11)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	
	var new_btn = Button.new()
	new_btn.text = "➕ New"
	new_btn.flat = true
	new_btn.add_theme_font_size_override("font_size", 10)
	new_btn.add_theme_color_override("font_color", HiruConst.C_ACCENT_ALT)
	new_btn.pressed.connect(_on_new_conversation)
	header.add_child(new_btn)
	vbox.add_child(header)
	
	var scroll_hist = ScrollContainer.new()
	scroll_hist.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var list = VBoxContainer.new()
	list.name = "ConversationList"
	list.add_theme_constant_override("separation", 6)
	scroll_hist.add_child(list)
	vbox.add_child(scroll_hist)
	
	margin.add_child(vbox)
	history_tab.add_child(margin)

func _build_input_area():
	var panel = PanelContainer.new()
	var p_style = HiruUtils.sb(HiruConst.C_PANEL, 0)
	p_style.content_margin_top = 6
	p_style.content_margin_bottom = 8
	p_style.content_margin_left = 8
	p_style.content_margin_right = 8
	panel.add_theme_stylebox_override("panel", p_style)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	
	# Attachments bar (hidden by default)
	_attachments_bar = HBoxContainer.new()
	_attachments_bar.name = "AttachmentsBar"
	_attachments_bar.visible = false
	_attachments_bar.add_theme_constant_override("separation", 4)
	vbox.add_child(_attachments_bar)
	
	# Quick Actions Bar (Accept/Reject sticky buttons)
	_quick_actions_bar = HBoxContainer.new()
	_quick_actions_bar.visible = false
	_quick_actions_bar.add_theme_constant_override("separation", 10)
	vbox.add_child(_quick_actions_bar)
	
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)

	input_field = TextEdit.new()
	input_field.placeholder_text = "Ask Hiru anything... (/ for commands, @ for files)"
	input_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_field.custom_minimum_size = Vector2(0, 50) # Starting height
	input_field.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	input_field.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	input_field.scroll_fit_content_height = true # Auto-expand
	input_field.gui_input.connect(_on_input_gui_input)
	input_field.text_changed.connect(_on_input_text_changed)
	
	var style := HiruUtils.sb(Color("#0d0d18"), 10, true, HiruConst.C_ACCENT.darkened(0.6))
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	input_field.add_theme_stylebox_override("normal", style)
	input_field.add_theme_stylebox_override("focus", HiruUtils.sb(Color("#0d0d18"), 10, true, HiruConst.C_ACCENT))
	input_field.add_theme_color_override("font_color", HiruConst.C_TEXT)
	input_field.add_theme_color_override("font_placeholder_color", HiruConst.C_TEXT_DIM)
	input_field.add_theme_font_size_override("font_size", 15)
	
	# Send button with glow
	send_btn = Button.new()
	send_btn.text = " ➤ "
	send_btn.custom_minimum_size = Vector2(36, 36)
	send_btn.pressed.connect(_on_send_pressed)
	HiruUtils.style_btn(send_btn, HiruConst.C_ACCENT)

	var cancel_btn = Button.new()
	cancel_btn.name = "CancelBtn"
	cancel_btn.text = " ✖ "
	cancel_btn.visible = false
	cancel_btn.custom_minimum_size = Vector2(36, 36)
	cancel_btn.pressed.connect(_on_cancel_pressed)
	HiruUtils.style_btn(cancel_btn, HiruConst.C_ERR)

	hbox.add_child(input_field)
	hbox.add_child(send_btn)
	hbox.add_child(cancel_btn)
	vbox.add_child(hbox)
	
	# Shortcuts hint
	var hint = Label.new()
	hint.text = "Enter ↵ send • Shift+Enter ↵ new line • Ctrl+L clear"
	hint.add_theme_font_size_override("font_size", 9)
	hint.add_theme_color_override("font_color", Color(HiruConst.C_TEXT_DIM, 0.4))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint)
	
	panel.add_child(vbox)
	add_child(panel)

func _build_toolbox_toggle():
	var bar = PanelContainer.new()
	var b_style = HiruUtils.sb(HiruConst.C_PANEL, 0)
	b_style.content_margin_top = 4
	b_style.content_margin_bottom = 4
	bar.add_theme_stylebox_override("panel", b_style)
	
	var hbox = HBoxContainer.new()
	
	toolbox_btn = Button.new()
	toolbox_btn.text = " 🛠️ Actions & Tools "
	toolbox_btn.flat = true
	toolbox_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toolbox_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbox_btn.toggle_mode = true
	toolbox_btn.toggled.connect(_on_toolbox_toggled)
	HiruUtils.style_btn(toolbox_btn, Color(0, 0, 0, 0.0))
	
	status_label = Label.new()
	status_label.text = "● Ready"
	status_label.add_theme_color_override("font_color", Color("#00ff88"))
	status_label.add_theme_font_size_override("font_size", 12)
	
	hbox.add_child(toolbox_btn)
	hbox.add_child(status_label)
	bar.add_child(hbox)
	add_child(bar)

func _set_status(text: String, color: Color = Color.WHITE):
	if status_label:
		status_label.text = text
		status_label.add_theme_color_override("font_color", color)

func _build_action_buttons():
	toolbox_panel = VBoxContainer.new()
	toolbox_panel.visible = false
	toolbox_panel.add_theme_constant_override("separation", 4)
	var inner = PanelContainer.new()
	inner.add_theme_stylebox_override("panel", HiruUtils.sb(HiruConst.C_PANEL, 0))
	
	var rows = VBoxContainer.new()
	rows.add_theme_constant_override("separation", 2)
	
	var row1 = HBoxContainer.new()
	row1.add_theme_constant_override("separation", 2)
	_add_action_btn(row1, "📝 Gen", "Generate: Create new GDScript from your prompt", _on_generate)
	_add_action_btn(row1, "🔧 Fix", "Auto-Fix: AI reads logs and fixes errors automatically", _on_fix)
	_add_action_btn(row1, "💡 Exp", "Explain: Get a clear explanation of code or logic", _on_explain)
	rows.add_child(row1)

	var row2 = HBoxContainer.new()
	row2.add_theme_constant_override("separation", 2)
	_add_action_btn(row2, "🧩 Node", "Create Node: Setup a new Scene and script hierarchy", _on_create_node)
	_add_action_btn(row2, "📂 Scan", "Scan: Refresh project file structure for AI context", _on_scan)
	_add_action_btn(row2, "🗑️ Clr", "Clear: Reset chat history and start fresh", _on_clear)
	rows.add_child(row2)

	var row3 = HBoxContainer.new()
	row3.add_theme_constant_override("separation", 2)
	_add_action_btn(row3, "▶️ Play", "Run Main: Launch the project's main scene", _on_play_main)
	_add_action_btn(row3, "🎬 Scene", "Run Scene: Launch the currently open scene", _on_play_current)
	_add_action_btn(row3, "⏹️ Stop", "Stop: Force stop the running game", _on_stop_game)
	rows.add_child(row3)
	
	var row4 = HBoxContainer.new()
	row4.add_theme_constant_override("separation", 2)
	var heal_btn = Button.new()
	heal_btn.name = "HealBtn"
	heal_btn.text = "🔁 Self-Healing: OFF"
	heal_btn.tooltip_text = "Self-Healing: AI monitors logs and auto-fixes bugs while you test"
	heal_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heal_btn.toggle_mode = true
	heal_btn.toggled.connect(_on_self_healing_toggled)
	HiruUtils.style_btn(heal_btn, Color("#2d1b69"))
	row4.add_child(heal_btn)
	
	rows.add_child(row4)
	
	inner.add_child(rows)
	toolbox_panel.add_child(inner)
	add_child(toolbox_panel)

func _build_context_bar():
	var bar = PanelContainer.new()
	bar.visible = false
	var style = HiruUtils.sb(HiruConst.C_BG_SIDEBAR, 0)
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	bar.add_theme_stylebox_override("panel", style)
	bar.name = "ContextBar"
	
	var hbox = HBoxContainer.new()
	hbox.name = "ContextList"
	hbox.add_theme_constant_override("separation", 4)
	bar.add_child(hbox)
	add_child(bar)

func _update_context_bar():
	var bar = find_child("ContextBar", true, false)
	if not bar: return
	
	bar.visible = not _context_files.is_empty()
	var list = bar.find_child("ContextList", true, false)
	if not list: return
	
	for c in list.get_children(): c.queue_free()
	
	for path in _context_files:
		var btn = Button.new()
		btn.text = "📄 " + path.get_file() + " ✕"
		btn.flat = true
		btn.add_theme_font_size_override("font_size", 9)
		btn.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
		btn.pressed.connect(_on_context_bar_detach.bind(path))
		list.add_child(btn)

func _on_context_bar_detach(path: String):
	_context_files.erase(path)
	_update_context_bar()
	_save_context()


func _save_context():
	var file = FileAccess.open("user://hiruai_context.json", FileAccess.WRITE)
	if file:
		var data = {
			"context_files": _context_files
		}
		file.store_string(JSON.stringify(data))
		file.close()

func _load_context():
	if not FileAccess.file_exists("user://hiruai_context.json"):
		return
	var file = FileAccess.open("user://hiruai_context.json", FileAccess.READ)
	if file:
		var test_json_conv = JSON.new()
		var error = test_json_conv.parse(file.get_as_text())
		if error == OK:
			var data = test_json_conv.data
			if data.has("context_files"):
				# Filter out non-existent files
				var valid_files: Array[String] = []
				for f in data["context_files"]:
					if FileAccess.file_exists(f):
						valid_files.append(f)
				_context_files = valid_files
				_update_context_bar()
		file.close()

func _update_token_display(tokens: int):
	_total_tokens += tokens
	if _token_count_label:
		_token_count_label.text = " [ %d tokens ] " % _total_tokens

func _show_quick_model_menu():
	if not _ensure_kimi(): return
	var menu = PopupMenu.new()
	var provider = kimi.get("current_provider")
	var provider_models = kimi.get("PROVIDER_MODELS")
	var models_dict = provider_models.get(provider, {})
	var current = kimi.get("current_model")
	
	var i = 0
	for m_name in models_dict:
		menu.add_radio_check_item(m_name, i)
		if models_dict[m_name] == current:
			menu.set_item_checked(i, true)
		i += 1
		
	menu.add_separator()
	menu.add_item("⚙️ Full Settings...", 99)
	
	# Pass data via binds to avoid local variable capture in tool mode
	menu.id_pressed.connect(_on_quick_model_selected.bind(models_dict, provider))
	
	add_child(menu)
	menu.popup(Rect2(_model_quick_btn.global_position + Vector2(0, 30), Vector2.ZERO))

func _on_quick_model_selected(id: int, models_dict: Dictionary, provider: String):
	if id == 99:
		_show_settings()
		return
		
	var names = models_dict.keys()
	if id < 0 or id >= names.size(): return
	
	var selected_name = names[id]
	var selected_model = models_dict[selected_name]
	kimi.call("save_settings", kimi.get("nvidia_key"), kimi.get("puter_key"), kimi.get("google_key"), selected_model, provider)
	_add_msg("system", "⚡ Switched to: " + selected_name + " (" + provider + ")")
	_set_status("● Ready (" + selected_name + ")", Color("#00ff88"))

func _show_command_palette():
	var commands = {
		"/fix": "Analyzes logs and suggests surgical fixes",
		"/scan": "Refreshes project structure for AI context",
		"/clear": "Resets current chat history",
		"/undo": "Reverts last file operations",
		"/save": "Saves attached files as context",
		"/explain": "Explains current code base",
		"/node": "Generates a new node structure",
		"/ui": "Advice on premium UI design",
		"/opt": "Performance optimization tips"
	}
	_show_command_list(commands, "⚡ Quick Commands (Ctrl+K)")

func _show_slash_suggestions(filter: String):
	var all_commands = {
		"/fix": "Fix errors from logs",
		"/scan": "Refresh file tree",
		"/clear": "Reset chat",
		"/undo": "Undo file changes",
		"/save": "Contextual save",
		"/explain": "Code analysis",
		"/node": "Scene creation",
		"/ui": "UI architect",
		"/opt": "Optimization"
	}
	var filtered = {}
	for k in all_commands:
		if k.begins_with(filter):
			filtered[k] = all_commands[k]
	
	if not filtered.is_empty():
		_show_command_list(filtered, "💡 Suggestions")
	elif _cmd_popup:
		_cmd_popup.hide()

func _show_command_list(commands: Dictionary, title_text: String):
	if not _cmd_popup or not is_instance_valid(_cmd_popup):
		_cmd_popup = PopupPanel.new()
		_cmd_popup.name = "CommandPopup"
		var popup_style = HiruUtils.sb(HiruConst.C_PANEL, 8, true, HiruConst.C_BORDER)
		_cmd_popup.add_theme_stylebox_override("panel", popup_style)
		add_child(_cmd_popup)
	
	for c in _cmd_popup.get_children():
		c.queue_free()
		
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	
	var title = Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	vbox.add_child(title)
	
	for cmd in commands:
		var btn = Button.new()
		btn.text = "  %-12s  ▸  %s" % [cmd, commands[cmd]]
		btn.flat = true
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 11)
		btn.add_theme_color_override("font_color", HiruConst.C_ACCENT if cmd.begins_with("/") else HiruConst.C_TEXT)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.pressed.connect(_on_command_suggestion_pressed.bind(cmd))
		vbox.add_child(btn)
		
	_cmd_popup.add_child(vbox)
	
	# Position above input field
	var pos = input_field.get_global_rect().position
	pos.y -= commands.size() * 26 + 40
	_cmd_popup.popup(Rect2(pos, Vector2(320, 0)))

func _handle_slash_command(cmd: String) -> bool:
	var parts = cmd.split(" ", false)
	if parts.is_empty(): return false
	
	match parts[0]:
		"/fix": _on_fix(); return true
		"/scan": _on_scan(); return true
		"/clear": _on_clear(); return true
		"/undo": _on_undo(); return true
		"/explain": _on_explain(); return true
		"/node": _on_create_node(); return true
		"/ui": _send("Give me elite UI design advice based on your skills."); return true
		"/opt": _send("Analyze my code for performance bottlenecks using your optimization skills."); return true
	return false

func _on_toolbox_toggled(on: bool):
	toolbox_panel.visible = on
	toolbox_btn.text = " 👇 Actions & Tools " if on else " 🛠️ Actions & Tools "
	_scroll_bottom(true)


func _add_action_btn(parent: HBoxContainer, text: String, tip: String, callback: Callable):
	var btn = Button.new()
	btn.text = text
	btn.tooltip_text = tip
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(callback)
	HiruUtils.style_btn(btn)
	parent.add_child(btn)


# ══════════════════ CHAT MESSAGES ══════════════════

func _add_msg(role: String, text: String):
	var bubble = PanelContainer.new()
	bubble.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# Role-specific styling
	var border_color = HiruConst.C_BORDER
	var bg_color = HiruConst.C_BG_DEEP
	var pcol: Color = HiruConst.C_TEXT
	var prefix: String = "✦ HIRU"
	
	match role:
		"user":
			prefix = "YOU"
			pcol = HiruConst.C_ACCENT_ALT
			border_color = HiruConst.C_ACCENT_ALT.darkened(0.6)
			bg_color = Color("#0f1018")
		"ai":
			prefix = "✦ HIRU"
			pcol = HiruConst.C_ACCENT
			border_color = HiruConst.C_ACCENT.darkened(0.5)
		"system":
			prefix = "SYSTEM"
			pcol = HiruConst.C_SYS
			border_color = HiruConst.C_SYS.darkened(0.7)
		"error":
			prefix = "ERROR"
			pcol = Color("#ff5555")
			border_color = Color("#ff5555").darkened(0.6)
	
	var bstyle = HiruUtils.sb(bg_color, 6, true, border_color)
	bstyle.border_width_left = 3
	bstyle.border_width_right = 0
	bstyle.border_width_top = 0
	bstyle.border_width_bottom = 0
	bstyle.content_margin_bottom = 10
	bstyle.content_margin_top = 8
	bstyle.content_margin_left = 14
	bstyle.content_margin_right = 12
	bubble.add_theme_stylebox_override("panel", bstyle)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)

	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	var sender = Label.new()
	sender.text = prefix
	sender.add_theme_color_override("font_color", pcol)
	sender.add_theme_font_size_override("font_size", 9)
	header.add_child(sender)
	
	var timestamp = Label.new()
	timestamp.text = Time.get_time_string_from_system().left(5)
	timestamp.add_theme_color_override("font_color", Color(HiruConst.C_TEXT_DIM, 0.4))
	timestamp.add_theme_font_size_override("font_size", 8)
	header.add_child(timestamp)
	
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	
	var copy_btn = Button.new()
	copy_btn.text = "📋"
	copy_btn.flat = true
	copy_btn.add_theme_font_size_override("font_size", 9)
	copy_btn.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	copy_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	copy_btn.tooltip_text = "Copy message"
	copy_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	copy_btn.pressed.connect(_on_copy_pressed.bind(text, copy_btn))
	header.add_child(copy_btn)
	
	vbox.add_child(header)

	var content = RichTextLabel.new()
	content.bbcode_enabled = true
	content.fit_content = true
	content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.selection_enabled = true
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.text = HiruUtils.fmt(text)
	content.add_theme_color_override("default_color", HiruConst.C_TEXT if role != "user" else HiruConst.C_ACCENT_ALT)
	content.add_theme_font_size_override("normal_font_size", 15)
	vbox.add_child(content)

	bubble.add_child(vbox)
	chat_container.add_child(bubble)
	
	_prune_chat_messages()
	
	# Animate entrance
	bubble.modulate.a = 0
	var tween = create_tween()
	tween.tween_property(bubble, "modulate:a", 1.0, 0.15)
	_scroll_bottom(true)
	return bubble


func _on_copy_pressed(text: String, btn: Button):
	DisplayServer.clipboard_set(text)
	btn.text = "✅"
	await get_tree().create_timer(1.5).timeout
	if is_instance_valid(btn):
		btn.text = "📋"


func _scroll_bottom(force: bool = false):
	if not is_inside_tree() or not scroll:
		return
	
	# Wait for layout updates to ensure max_value is accurate
	await get_tree().process_frame
	
	var v_bar = scroll.get_v_scroll_bar()
	var max_scroll = v_bar.max_value - v_bar.page
	var current_scroll = scroll.scroll_vertical
	
	# "Smart Scroll": Only auto-scroll if near bottom (100px threshold)
	# This allows users to scroll UP and stay there during streaming.
	if force or current_scroll >= max_scroll - 100:
		scroll.scroll_vertical = int(v_bar.max_value)


func _show_thinking(status: String = "AI is thinking...", phase: String = "scan"):
	# Remove existing if any
	_hide_thinking()

	var panel = PanelContainer.new()
	panel.name = "ThinkingPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# Phase-specific border color
	var phase_color = {
		"scan": Color("#42a5f5"),
		"wait": Color("#ffd93d"),
		"read": Color("#64b5f6"),
		"edit": Color("#00e676"),
		"think": Color("#ab47bc")
	}.get(phase, HiruConst.C_ACCENT)
	
	var st = HiruUtils.sb(Color.TRANSPARENT, 0)
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
	lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", phase_color)
	lbl.add_theme_font_size_override("font_size", 12)
	hbox.add_child(lbl)
	
	vbox.add_child(hbox)
	margin.add_child(vbox)
	panel.add_child(margin)
	chat_container.add_child(panel)
	
	# Scroll to bottom after adding
	_scroll_bottom(true)

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
	}.get(phase, HiruConst.C_ACCENT)
	
	var spinner_node = p.find_child("Spinner", true, false)
	if spinner_node: spinner_node.text = phase_icon
	
	var lbl = p.find_child("StatusLabel", true, false)
	if lbl:
		# Keep ThinkingPanel compact — truncate long status text
		var short_status = status.strip_edges().replace("\n", " ")
		if short_status.length() > 100:
			short_status = short_status.substr(0, 100) + "..."
		lbl.text = short_status
		lbl.add_theme_color_override("font_color", phase_color)
	
	# Scroll to bottom only once
	_scroll_bottom(true)


func _hide_thinking():
	var p = chat_container.get_node_or_null("ThinkingPanel")
	if p:
		p.queue_free()


func _add_welcome():
	# Clear any existing
	for c in chat_container.get_children(): c.queue_free()
	
	var spacer = Control.new()
	spacer.custom_minimum_size.y = 30
	chat_container.add_child(spacer)

	var center = CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	
	# Logo/Brand
	var brand_hbox = HBoxContainer.new()
	brand_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	brand_hbox.add_theme_constant_override("separation", 8)
	var logo = Label.new()
	logo.text = "✦"
	logo.add_theme_font_size_override("font_size", 28)
	logo.add_theme_color_override("font_color", HiruConst.C_ACCENT)
	brand_hbox.add_child(logo)
	var brand = Label.new()
	brand.text = "HiruAI"
	brand.add_theme_font_size_override("font_size", 22)
	brand.add_theme_color_override("font_color", Color.WHITE)
	brand_hbox.add_child(brand)
	vbox.add_child(brand_hbox)
	
	var lbl = Label.new()
	lbl.text = "Your AI coding assistant for Godot"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)
	
	# Quick action cards
	var cards_label = Label.new()
	cards_label.text = "Quick Start"
	cards_label.add_theme_font_size_override("font_size", 11)
	cards_label.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	cards_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(cards_label)
	
	var cards = VBoxContainer.new()
	cards.add_theme_constant_override("separation", 6)
	_add_quick_card(cards, "📝", "Generate Script", "Create a new GDScript from description", _on_quick_generate)
	_add_quick_card(cards, "🔧", "Fix Errors", "Auto-detect and fix project errors", _on_fix)
	_add_quick_card(cards, "💡", "Explain Code", "Get explanations of your code", _on_explain)
	_add_quick_card(cards, "🧩", "Create Node", "Build new scene & script hierarchy", _on_create_node)
	vbox.add_child(cards)
	
	# Version info
	var ver = Label.new()
	ver.text = "v3.0 Elite • Scope-Locked Architect Mode Active"

	ver.add_theme_font_size_override("font_size", 9)
	ver.add_theme_color_override("font_color", Color(HiruConst.C_TEXT_DIM, 0.5))
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(ver)
	
	center.add_child(vbox)
	chat_container.add_child(center)
	
	# Animate entrance
	center.modulate.a = 0
	var tween = create_tween().set_ease(Tween.EASE_OUT)
	tween.tween_property(center, "modulate:a", 1.0, 0.5)

func _on_quick_generate():
	_send("/generate")

func _on_quick_fix():
	_send("/fix")

func _on_quick_explain():
	_send("/explain")

func _on_quick_create_node():
	_send("/create_node")

func _add_quick_card(parent: VBoxContainer, icon: String, title: String, desc: String, callback: Callable):
	var card = PanelContainer.new()
	var st = HiruUtils.sb(HiruConst.C_PANEL, 8, true, HiruConst.C_BORDER)
	st.content_margin_top = 8
	st.content_margin_bottom = 8
	st.content_margin_left = 12
	st.content_margin_right = 12
	card.add_theme_stylebox_override("panel", st)
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	
	var ic = Label.new()
	ic.text = icon
	ic.add_theme_font_size_override("font_size", 16)
	hbox.add_child(ic)
	
	var text_vbox = VBoxContainer.new()
	text_vbox.add_theme_constant_override("separation", 1)
	text_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var t = Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 12)
	t.add_theme_color_override("font_color", Color.WHITE)
	text_vbox.add_child(t)
	var d = Label.new()
	d.text = desc
	d.add_theme_font_size_override("font_size", 10)
	d.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	text_vbox.add_child(d)
	hbox.add_child(text_vbox)
	
	var arrow = Label.new()
	arrow.text = "→"
	arrow.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	hbox.add_child(arrow)
	
	card.add_child(hbox)
	
	# Invisible click button
	var btn = Button.new()
	btn.flat = true
	btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.modulate.a = 0
	btn.pressed.connect(callback)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.add_child(btn)
	
	parent.add_child(card)


# ══════════════════ SEND LOGIC ══════════════════

func _on_send_pressed():
	_send(input_field.text)

func _on_text_submitted(_text: String):
	_send(input_field.text)

func _on_input_gui_input(event: InputEvent):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER and not event.shift_pressed:
			get_viewport().set_input_as_handled()
			_send(input_field.text)
		elif event.keycode == KEY_L and event.ctrl_pressed:
			get_viewport().set_input_as_handled()
			_on_clear()
		elif event.keycode == KEY_K and event.ctrl_pressed:
			get_viewport().set_input_as_handled()
			_show_command_palette()
		elif event.keycode == KEY_ESCAPE:
			if _cmd_popup and _cmd_popup.visible:
				_cmd_popup.hide()

func _on_input_text_changed():
	var text = input_field.text
	# Detect slash commands
	if text.begins_with("/") and text.length() < 20:
		_show_slash_suggestions(text)
		return
	else:
		if _cmd_popup and _cmd_popup.visible:
			_cmd_popup.hide()
			
	# Detect @ mentions mode
	var words = text.split(" ")
	for word in words:
		if word.begins_with("@") and word.length() > 1:
			var query = word.substr(1).to_lower()
			_show_file_suggestions(query)
			return
			
	# Hide if no match
	if _file_suggestion_popup and _file_suggestion_popup.visible:
		_file_suggestion_popup.hide()

func _show_file_suggestions(query: String):
	if not _file_suggestion_popup or not is_instance_valid(_file_suggestion_popup):
		_file_suggestion_popup = PopupPanel.new()
		_file_suggestion_popup.name = "FileMentionPopup"
		var popup_style = HiruUtils.sb(HiruConst.C_PANEL, 8, true, HiruConst.C_BORDER)
		_file_suggestion_popup.add_theme_stylebox_override("panel", popup_style)
		add_child(_file_suggestion_popup)
	
	for c in _file_suggestion_popup.get_children():
		c.queue_free()
		
	var Scanner = load("res://addons/hiruai/project_scanner.gd")
	if not Scanner: return
	
	# Try to quickly find files (limit to 5)
	var files: Array[String] = []
	Scanner._scan_dir("res://", files, 0)
	
	var matches = []
	for f in files:
		if query in f.to_lower():
			matches.append(f)
			if matches.size() > 5: break
			
	if matches.is_empty():
		_file_suggestion_popup.hide()
		return
		
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	
	var title = Label.new()
	title.text = "Attach File"
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
	vbox.add_child(title)
	
	for m in matches:
		var btn = Button.new()
		btn.text = "📄 " + m.get_file()
		btn.flat = true
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 11)
		btn.add_theme_color_override("font_color", HiruConst.C_TEXT)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var bind_m = m
		btn.pressed.connect(_on_file_mention_pressed.bind(bind_m, query))
		vbox.add_child(btn)
		
	_file_suggestion_popup.add_child(vbox)
	var pos = input_field.get_global_rect().position
	pos.y -= matches.size() * 24 + 40
	_file_suggestion_popup.popup(Rect2(pos, Vector2(280, 0)))

func _attach_file_to_context(path: String):
	if path not in _context_files:
		_context_files.append(path)
		_update_context_bar()
		_save_context()
		_add_msg("system", "📎 Attached " + path.get_file() + " to context.")
		
		# Show attachment bar
		if _attachments_bar:
			_attachments_bar.visible = true
			var btn = Button.new()
			btn.text = "📄 " + path.get_file() + " ✕"
			btn.flat = true
			btn.add_theme_font_size_override("font_size", 9)
			var sb = HiruUtils.sb(Color("#2c2c3a"), 4)
			sb.content_margin_top = 2
			sb.content_margin_bottom = 2
			btn.add_theme_stylebox_override("normal", sb)
			btn.pressed.connect(_on_detach_file.bind(path, btn))
			_attachments_bar.add_child(btn)

func _on_detach_file(path: String, btn: Button):
	if path in _context_files:
		_context_files.erase(path)
		_update_context_bar()
	if is_instance_valid(btn):
		btn.queue_free()
	if _context_files.is_empty() and _attachments_bar:
		_attachments_bar.visible = false

func _send(text: String, is_internal: bool = false):
	if text.strip_edges().is_empty():
		return
	if not _ensure_kimi():
		_add_msg("error", "AI Client (Kimi) is stuck. Please toggle HiruAI plugin or restart Godot.")
		return
			
	if kimi.call("is_busy"):
		_add_msg("system", "Please wait for the current response.")
		return
	
	# Hide command popup
	if _cmd_popup and _cmd_popup.visible:
		_cmd_popup.hide()
	
	# Handle slash commands
	var stripped = text.strip_edges()
	if stripped.begins_with("/"):
		var handled = _handle_slash_command(stripped)
		if handled:
			input_field.text = ""
			return

	_add_msg("user", text)
	input_field.text = ""
	
	if not is_internal:
		_read_loop_count = 0
		_stall_retry_count = 0
		_step_counter = 0
		_activity_log.clear()
		_read_files.clear() # Reset per-turn so AI always re-reads fresh file versions
	
	# --- Cursor-like Feature: Auto-attach Current Editor Script ---
	if _auto_attach_enabled and Engine.is_editor_hint():
		var current_time = Time.get_ticks_msec()
		if current_time - _last_auto_attach_time > AUTO_ATTACH_COOLDOWN:
			var script_editor = EditorInterface.get_script_editor()
			if script_editor:
				var current_script = script_editor.get_current_script()
				if current_script:
					var path = current_script.resource_path
					if path != "" and path not in _context_files:
						_attach_file_to_context(path)
						_add_activity("🖇️", "Auto-attached current script: " + path.get_file(), HiruConst.C_ACCENT_ALT)
						_last_auto_attach_time = current_time

	# Clear previous pending data when a NEW human turn starts
	_pending_saves.clear()
	_pending_replaces.clear()
	_pending_deletes.clear()
	if _approval_panel and is_instance_valid(_approval_panel):
		if _approval_panel.has_meta("wrapper"):
			_approval_panel.get_meta("wrapper").queue_free()
		else:
			_approval_panel.queue_free()
		_approval_panel = null

	# ─── New Smart Scanning Logic ───
	# Only send file tree if user asks for something technical OR it hasn't been sent yet and we suspect it's needed.
	var needs_tree = _should_include_tree(text)
	
	if not _tree_sent and needs_tree:
		_add_activity("📂", "Analyzing project context...", Color("#42a5f5"))
		await get_tree().create_timer(0.1).timeout
		var Scanner = load("res://addons/hiruai/project_scanner.gd")
		var context = ""
		if Scanner:
			context = Scanner.get_file_tree()
		chat_history.append({"role": "user", "content": text + "\n\n[Project Structure]\n" + context})
		_tree_sent = true
		_add_activity("✅", "Context analyzed", Color("#00e676"))
	else:
		chat_history.append({"role": "user", "content": text})

	_send_to_ai()


func _send_to_ai():
	var messages: Array = [ {"role": "system", "content": _system_prompt()}]
	
	# --- Dynamic Context Injection ---
	var context_text := ""
	if !_context_files.is_empty():
		var Scanner = load("res://addons/hiruai/project_scanner.gd")
		context_text = "\n\n=== ATTACHED CONTEXT ===\n"
		for path in _context_files:
			context_text += "\n--- %s ---\n%s\n" % [path, Scanner.read_file(path)]
		context_text += "=========================\n"

	# Token saving: only send last 12 messages (increased from 6 for better multi-step memory)
	var history_copy = chat_history.duplicate(true)
	if history_copy.size() > 0 and history_copy[-1]["role"] == "user":
		history_copy[-1]["content"] += context_text
		
	var recent = history_copy.slice(maxi(0, history_copy.size() - 12))
	messages.append_array(recent)

	_set_status("● Thinking...", HiruConst.C_THINK)
	_current_state = AgentState.PLANNING
	_thinking_duration_sec = 0
	_step_counter += 1
	_last_request_time = Time.get_ticks_msec()
	_add_activity("⏳", "Step %d — Sending to %s..." % [_step_counter, str(kimi.get("current_model")).get_file()], HiruConst.C_THINK)
	
	# Toggle buttons
	send_btn.visible = false
	var cancel = find_child("CancelBtn", true, false)
	if cancel: cancel.visible = true
	
	kimi.call("send_chat", messages)


# ══════════════════ STREAMING HANDLERS ══════════════════

func _on_stream_started():
	"""Called when first SSE token arrives — create live bubble."""
	_hide_thinking()
	_streaming_raw_text = ""
	_step_counter += 1
	
	_thinking_duration_sec = maxi(1, (Time.get_ticks_msec() - _last_request_time) / 1000)
	_set_status("● Generating...", HiruConst.C_ACCENT)
	_current_state = AgentState.PLANNING
	_add_activity("🧠", "AI is generating response...", HiruConst.C_ACCENT)
	
	# Create streaming bubble
	_streaming_bubble = PanelContainer.new()
	_streaming_bubble.name = "StreamingBubble"
	_streaming_bubble.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bstyle = StyleBoxEmpty.new()
	bstyle.content_margin_top = 8
	_streaming_bubble.add_theme_stylebox_override("panel", bstyle)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)


	# Streaming indicator
	var stream_hint = Label.new()
	stream_hint.name = "StreamHint"
	stream_hint.text = "● streaming..."
	stream_hint.add_theme_color_override("font_color", Color("#00e676"))
	stream_hint.add_theme_font_size_override("font_size", 10)
	vbox.add_child(stream_hint)

	_streaming_content = RichTextLabel.new()
	_streaming_content.bbcode_enabled = true
	_streaming_content.fit_content = true
	_streaming_content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_streaming_content.scroll_active = false
	_streaming_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_streaming_content.add_theme_color_override("default_color", HiruConst.C_TEXT)
	_streaming_content.add_theme_font_size_override("normal_font_size", 15)
	_streaming_content.text = ""
	vbox.add_child(_streaming_content)

	_streaming_bubble.add_child(vbox)
	chat_container.add_child(_streaming_bubble)
	
	_thought_streaming_label = null # Reset for new message
	_scroll_bottom(true)


func _on_token_received(token: String):
	"""Called per-token — append to live bubble with real-time cleaning."""
	_streaming_raw_text += token
	if _streaming_content and is_instance_valid(_streaming_content):
		# 2. Live Thinking Update: Update the THOUGHT card in real-time if it exists
		var thought = HiruProtocol.extract_thoughts(_streaming_raw_text, true) # Partial allowed
		if thought != "":
			if not _thought_streaming_label or not is_instance_valid(_thought_streaming_label):
				_add_thought_card_with_text("") # Initialize live card
			
			if _thought_streaming_label and is_instance_valid(_thought_streaming_label):
				_thought_streaming_label.text = "[i]" + thought + "[/i]"
				# Ensure regular display doesn't show the thought block
				var display = HiruUtils.clean_display_text(_streaming_raw_text)
				_streaming_content.text = HiruUtils.fmt(display)
		else:
			# If no thought block found yet (or cleared), show regular text
			var display = HiruUtils.clean_display_text(_streaming_raw_text)
			_streaming_content.text = HiruUtils.fmt(display)
		
		# 3. Auto-scroll
		_scroll_bottom(false)


func _on_stream_finished(_full_text: String, _finish_reason: String = "stop"):
	pass


func _phase_from_icon(icon: String) -> String:
	match icon:
		"📂", "🔍": return "scan"
		"📖": return "read"
		"✏️", "💾": return "edit"
		"🧠": return "think"
		"⏳": return "wait"
		_: return "wait"


# ══════════════════ AI RESPONSE HANDLER ══════════════════

func _on_ai_response(text: String, finish_reason: String = "stop"):
	_hide_thinking()
	
	# Handle SCAN_TREE request from AI
	if HiruProtocol.extract_scan_tree(text):
		_current_state = AgentState.ANALYZING
		_add_activity("📂", "AI requested project scan...", Color("#42a5f5"))
		var Scanner = load("res://addons/hiruai/project_scanner.gd")
		var tree = Scanner.get_file_tree()
		_tree_sent = true
		chat_history.append({"role": "user", "content": "Project structure provided:\n" + tree + "\nNow you know the context. Proceed."})
		_send_to_ai()
		return
	
	# DO NOT queue_free yet. We check it below to avoid double message.
	_streaming_content = null
	
	# Restore buttons
	send_btn.visible = true
	var cancel = find_child("CancelBtn", true, false)
	if cancel: cancel.visible = false

	# 1) Extract all commands
	var searches = HiruProtocol.extract_searches(text)
	var reads = HiruProtocol.extract_reads(text)
	var read_lines = HiruProtocol.extract_read_lines(text)
	var scene_scans = HiruProtocol.extract_scene_scans(text)
	var skill_sync = "[SKILL_SYNC]" in text
	var saves = HiruProtocol.extract_saves(text)
	var replaces = HiruProtocol.extract_replaces(text)
	var deletes = HiruProtocol.extract_deletes(text)
	var diffs = HiruProtocol.extract_diffs(text) # NEW
	var run_req = HiruProtocol.extract_run_game(text)
	var thoughts = HiruProtocol.extract_thoughts(text, true)
	
	var has_actions = (searches.size() > 0 or reads.size() > 0 or read_lines.size() > 0 or scene_scans.size() > 0 or skill_sync or diffs.size() > 0)
	var has_saves = (saves.size() > 0 or replaces.size() > 0 or deletes.size() > 0)
	
	if thoughts != "":
		_current_state = AgentState.PLANNING
	if has_saves:
		_current_state = AgentState.EXECUTING
	if searches.size() > 0 or reads.size() > 0 or read_lines.size() > 0:
		_current_state = AgentState.ANALYZING

	# 1) PRE-ACTION: Show Activity Chips for commands
	if thoughts != "":
		if _thought_streaming_label and is_instance_valid(_thought_streaming_label):
			# Finalize the existing streaming card
			_thought_streaming_label.text = "[i]" + thoughts + "[/i]"
			if _last_thought_chip and is_instance_valid(_last_thought_chip):
				var dur_str = HiruUtils.format_duration(_thinking_duration_sec)
				_last_thought_chip.text = "  🧠 Thought for %s  ▸" % dur_str
				# Also collapse it if it was left open, or keep it as user likes?
				# Let's keep it expanded if it was a deep plan
		else:
			_add_thought_card_with_text(thoughts)
			# Ensure thought card appears ABOVE the streaming bubble if we just created it
			if _streaming_bubble and is_instance_valid(_streaming_bubble):
				var idx = chat_container.get_child_count() - 1
				var card = chat_container.get_child(idx)
				chat_container.move_child(card, _streaming_bubble.get_index())

	var plan = HiruProtocol.extract_plan(text)
	if plan != "":
		_add_intelligence_card("🗺️ MISSION PLAN", plan, Color("#3b82f6"))
		
	var progress = HiruProtocol.extract_progress(text)
	if progress != "":
		_add_intelligence_card("📋 TASK PROGRESS", progress, Color("#10b981"))
		
	var has_run_check = HiruProtocol.extract_run_check(text)
	if has_run_check and has_saves:
		_add_activity_bubble("⚙️ ACTION REQUIRED: Run the project and check for errors.", Color("#f59e0b"))
		
	var proactive_flags = HiruProtocol.extract_proactive_flags(text)
	for flag in proactive_flags:
		_add_activity_bubble("⚠️ PROACTIVE FLAG: " + flag, Color("#f59e0b"))
	
	if searches.size() > 0:
		_add_activity_bubble("🔍 Searching for %d keyword(s)..." % searches.size(), Color("#9c27b0"))
	if reads.size() > 0:
		_add_activity_bubble("📖 Analyzing %d file(s)..." % reads.size(), Color("#42a5f5"))
	if saves.size() > 0:
		for s in saves:
			var lines = s["content"].split("\n").size()
			_add_activity_bubble("💾 Saving %s (%d lines)..." % [s["path"].get_file(), lines], HiruConst.C_SAVE)
	if replaces.size() > 0:
		for r in replaces:
			_add_activity_bubble("💉 Replacing lines %d-%d in %s..." % [r["start"], r["end"], r["path"].get_file()], Color("#22d3ee"))
	if deletes.size() > 0:
		_add_activity_bubble("🗑️ Deleting %d file(s)..." % deletes.size(), HiruConst.C_DELETE)

	# 1.1) Show CLEAN AI message (no raw code blocks)
	chat_history.append({"role": "assistant", "content": text})
	var clean_text = HiruUtils.clean_display_text(text)
	
	# ONLY add message if it wasn't already streamed
	if not _streaming_bubble:
		if clean_text != "":
			_add_msg("ai", clean_text)
		elif text.strip_edges() != "":
			# AI sent something but it was all filtered out?
			if thoughts != "":
				_add_msg("ai", "⚙️ *Intelligence analyzed. No file changes or explanation were provided in this turn. See thought card above for details.*")
			else:
				_add_msg("ai", "⚙️ *Technical protocol executed. (No textual message provided)*")
	elif _streaming_bubble and is_instance_valid(_streaming_bubble):
		# If it was streamed, just finalize the last bubble
		var hint = _streaming_bubble.find_child("StreamHint", true, false)
		if hint: hint.queue_free()
		
		# Ensure formatted properly and CLEANED
		var rtxt = _streaming_bubble.find_child("RichTextLabel", true, false)
		if rtxt:
			if clean_text.strip_edges() == "":
				if thoughts != "":
					rtxt.text = "[i](Logic only response. See thought card above.)[/i]"
				else:
					rtxt.text = "[i](No textual output provided)[/i]"
			else:
				rtxt.text = HiruUtils.fmt(clean_text)
			rtxt.visible_ratio = 1.0
			
		_streaming_bubble = null # Mark as finished
		_add_activity("✅", "Response complete", Color("#00e676"))
		_update_token_display(text.length() / 4)
	
	# Status check — only set Ready if NO pending cycles/actions
	
	# 1. Update pending storage
	if has_saves:
		_pending_saves = saves
		_pending_replaces = replaces
		_pending_deletes = deletes
	
	# 2. Decide visibility
	var truly_has_pending = (_pending_saves.size() > 0 or _pending_replaces.size() > 0 or _pending_deletes.size() > 0)
	
	# CRITICAL: If there are pending changes, we STOP auto-loops to show the buttons
	# unless it's a syntax auto-fix loop which happens after this check.
	var can_auto_loop = has_actions and not truly_has_pending and _read_loop_count < HiruConst.MAX_READ_LOOPS
	
	if can_auto_loop:
		_set_status("● Processing Action...", HiruConst.C_SYS)
	elif truly_has_pending:
		_set_status("● Waiting for Approval", Color("#facc15"))
		# Force clear actions to stop auto-looping while waiting for user
		has_actions = false
		searches.clear()
		reads.clear()
		read_lines.clear()
		scene_scans.clear()
		skill_sync = false
		diffs.clear()
	else:
		_set_status("● Ready", Color("#00ff88"))


	# 3) Handle SEARCH requests
	if searches.size() > 0 and _read_loop_count < HiruConst.MAX_READ_LOOPS:
		_read_loop_count += 1
		_add_activity("🔍", "Searching %d keyword(s)..." % searches.size(), Color("#9c27b0"))
		var Scanner = load("res://addons/hiruai/project_scanner.gd")
		var search_results := ""
		if Scanner:
			for q in searches:
				_add_activity("🔍", "Searching for '" + q + "'...", Color("#42a5f5"))
				var result = Scanner.search_text(q)
				_add_file_card("Keyword: " + q, "Searched", Color("#9c27b0"))
				search_results += "\n=== Search: %s ===\n%s\n" % [q, result]
			
		chat_history.append({
			"role": "user",
			"content": "Search results:\n" + search_results + "\nNow use [READ:] or [READ_LINES:] on the files you need, or proceed."
		})
		_send_to_ai()
		return

	# 3a) Handle READ requests first — auto-read loop
	if reads.size() > 0 and _read_loop_count < HiruConst.MAX_READ_LOOPS:
		_read_loop_count += 1
		_add_activity("📖", "Reading %d file(s)..." % reads.size(), Color("#42a5f5"))
		var Scanner = load("res://addons/hiruai/project_scanner.gd")
		var file_contents := ""
		var read_count := 0
		for read_path in reads:
			if read_count >= 3:
				break
			_add_activity("📖", "Reading " + read_path.get_file() + "...", Color("#64b5f6"))
			var content = Scanner.read_file(read_path)
			_add_file_card(read_path, "Analyzed", HiruConst.C_READ)
			file_contents += "\n--- %s ---\n%s\n" % [read_path, content]
			if read_path not in _read_files:
				_read_files.append(read_path)
			if read_path not in _context_files:
				_context_files.append(read_path)
				_update_context_bar()
			read_count += 1
		if reads.size() > 3:
			file_contents += "\n(Skipped %d files. Use [READ:] again for remaining.)" % (reads.size() - 3)
		_add_activity("🧠", "Analyzing " + str(read_count) + " file(s)...", Color("#ab47bc"))
		chat_history.append({
			"role": "user",
			"content": "File contents:\n" + file_contents + "\nProceed with the task."
		})
		_send_to_ai()
		return

	# 3b) Handle READ_LINES requests
	if read_lines.size() > 0 and _read_loop_count < HiruConst.MAX_READ_LOOPS:
		_read_loop_count += 1
		var Scanner = load("res://addons/hiruai/project_scanner.gd")
		var file_contents := ""
		for rl in read_lines:
			_add_activity("📖", "Reading lines %d-%d of %s..." % [rl["start"], rl["end"], rl["path"].get_file()], Color("#64b5f6"))
			var content = Scanner.read_file_lines(rl["path"], rl["start"], rl["end"])
			_add_file_card(rl["path"], "Analyzed", HiruConst.C_READ.darkened(0.2), "#L%d-%d" % [rl["start"], rl["end"]])
			file_contents += "\n--- %s (lines %d-%d) ---\n%s\n" % [rl["path"], rl["start"], rl["end"], content]
		chat_history.append({
			"role": "user",
			"content": "File contents:\n" + file_contents + "\nProceed with the task."
		})
		_send_to_ai()
		return

	# 3c) Handle SCENE_SCAN requests
	if scene_scans.size() > 0 and _read_loop_count < HiruConst.MAX_READ_LOOPS:
		_read_loop_count += 1
		var Scanner = load("res://addons/hiruai/project_scanner.gd")
		var scene_trees := ""
		for spath in scene_scans:
			_add_activity("👁️", "Scanning scene hierarchy: " + spath.get_file() + "...", Color("#a87ffb"))
			var tree = Scanner.scan_scene(spath)
			_add_file_card(spath, "SCANNED", Color("#a87ffb"))
			scene_trees += "\n" + tree + "\n"
		chat_history.append({
			"role": "user",
			"content": "Scene hierarchies:\n" + scene_trees + "\nNow you know the node structure. Proceed."
		})
		_send_to_ai()
		return

	# 3d) Handle SKILL_SYNC requests
	if skill_sync and _read_loop_count < HiruConst.MAX_READ_LOOPS:
		_read_loop_count += 1
		var all_skills_advice = _sync_skills()
		_add_activity("🔮", "Evolving... Skills Synchronized.", Color("#f472b6"))
		chat_history.append({
			"role": "user",
			"content": "Skill Synchronization Complete. Specialized knowledge injected:\n" + all_skills_advice + "\nApply these principles to your current task."
		})
		_send_to_ai()
		return

	# 3e) Handle DIFF requests
	if diffs.size() > 0:
		_read_loop_count += 1
		var diff_results := ""
		for dpath in diffs:
			_add_activity("📊", "Comparing versions for %s..." % dpath.get_file(), Color("#10b981"))
			var old_content = ""
			# Search undo stack for previous state
			for action in _undo_stack:
				if action["path"] == dpath:
					old_content = action["content"]
					break
			
			if old_content == "":
				diff_results += "\n--- %s (No previous version in current session undo stack) ---\n" % dpath
			else:
				var current = _read_project_file(dpath)
				var stats = HiruDiff.calculate_diff_stats(old_content, current)
				diff_results += "\n--- DIFF: %s (%s) ---\n" % [dpath, stats]
				
		chat_history.append({
			"role": "user",
			"content": "Diff summaries:\n" + diff_results + "\nProceed with your next step."
		})
		_send_to_ai()
		return

	# 4) If there are SAVE/REPLACE/DELETE ops, validate planning and READ-before-SAVE
	if saves.size() > 0 or replaces.size() > 0 or deletes.size() > 0:
		# ── FORCED PLANNING PHASE ──
		# If AI jumped straight to SAVE without reading/searching ANYTHING first,
		# force a planning cycle: auto-read target files + demand [THOUGHT:] plan.
		if _read_loop_count == 0 and _read_loop_count < HiruConst.MAX_READ_LOOPS:
			_read_loop_count += 1
			_add_msg("system", "🧠 **Planning phase** — Hiru is analyzing your project before making changes...")
			_add_activity("🧠", "Planning: reading files before acting", Color("#ab47bc"))
			
			var Scanner = load("res://addons/hiruai/project_scanner.gd")
			var auto_read_contents := ""
			
			# Auto-read existing files the AI wants to modify
			for s in saves:
				if FileAccess.file_exists(s["path"]) and s["path"] not in _read_files:
					var content = Scanner.read_file(s["path"])
					auto_read_contents += "\n--- %s ---\n%s\n" % [s["path"], content]
					_add_file_card(s["path"], "Auto-Read", HiruConst.C_READ)
					_read_files.append(s["path"])
			
			for r in replaces:
				if FileAccess.file_exists(r["path"]) and r["path"] not in _read_files:
					var content = Scanner.read_file(r["path"])
					auto_read_contents += "\n--- %s ---\n%s\n" % [r["path"], content]
					_add_file_card(r["path"], "Auto-Read", HiruConst.C_READ)
					_read_files.append(r["path"])
			
			# Also auto-read files referenced in delete targets
			for d_path in deletes:
				if FileAccess.file_exists(d_path) and d_path not in _read_files:
					var content = Scanner.read_file(d_path)
					auto_read_contents += "\n--- %s ---\n%s\n" % [d_path, content]
					_read_files.append(d_path)
			
			var plan_prompt := "SYSTEM: PLANNING PHASE REQUIRED.\n"
			plan_prompt += "You MUST plan before making changes. Follow this flow:\n"
			plan_prompt += "1. [THOUGHT:] — State EXACTLY which lines you will change and why. Nothing else.\n"
			plan_prompt += "2. [READ:] / [SEARCH:] — If you need to check more files or find references, do it now.\n"
			plan_prompt += "3. EDIT RULE — CRITICAL:\n"
			plan_prompt += "   • File ALREADY EXISTS → use [REPLACE:path:S-E] with ONLY the changed lines. NEVER rewrite the whole file.\n"
			plan_prompt += "   • File does NOT exist yet → use [SAVE:path] with full content.\n"
			plan_prompt += "   • SCOPE LOCK: Only touch lines directly related to the user's request. Untouched code must remain byte-for-byte identical.\n\n"
			
			if auto_read_contents != "":
				plan_prompt += "I've auto-loaded the files you want to modify. Study them carefully:\n" + auto_read_contents
				plan_prompt += "\nNow start with [THOUGHT:] identifying the EXACT lines to change, then use [REPLACE:] for each existing file."
			else:
				plan_prompt += "These appear to be new files. Use [THOUGHT:] to explain your design decisions, then provide [SAVE:] blocks."
			
			chat_history.append({"role": "user", "content": plan_prompt})
			_send_to_ai()
			return
		
		# ── SAVE BLOCKER: Block [SAVE:] on existing files ──
		# This is the #1 defense against code destruction.
		# If AI sent [SAVE:] for files that already exist, reject and demand [REPLACE:]
		var save_blocked_paths: Array[String] = []
		var clean_saves: Array[Dictionary] = []
		for s in saves:
			if FileAccess.file_exists(s["path"]):
				save_blocked_paths.append(s["path"])
				_add_activity("🛑", "BLOCKED: [SAVE:] on existing file %s" % s["path"].get_file(), Color("#ff5252"))
			else:
				clean_saves.append(s)
		
		if save_blocked_paths.size() > 0 and _read_loop_count < HiruConst.MAX_READ_LOOPS:
			_read_loop_count += 1
			var blocked_list := ""
			var blocked_contents := ""
			var Scanner_block = load("res://addons/hiruai/project_scanner.gd")
			for bp in save_blocked_paths:
				var line_count = Scanner_block.read_file(bp).split("\n").size()
				blocked_list += "\n• %s (%d lines)" % [bp, line_count]
				if bp not in _read_files:
					blocked_contents += "\n--- %s ---\n%s\n" % [bp, Scanner_block.read_file(bp)]
					_read_files.append(bp)
			
			_add_msg("system", "🛑 **SAVE Blocked** — AI tried to overwrite existing files. Forcing surgical [REPLACE:] instead...")
			
			var block_msg := "SYSTEM ERROR: [SAVE:] BLOCKED on existing files!\n"
			block_msg += "These files ALREADY EXIST and cannot be overwritten with [SAVE:]:" + blocked_list + "\n\n"
			block_msg += "MANDATORY: You MUST use [REPLACE:path:S-E] to edit existing files.\n"
			block_msg += "Only change the SPECIFIC lines that need modification.\n"
			block_msg += "Example: [REPLACE:res://path.gd:15-25] with ONLY the changed lines.\n\n"
			if blocked_contents != "":
				block_msg += "Here are the current file contents. Find the exact lines to change:\n" + blocked_contents
			
			chat_history.append({"role": "user", "content": block_msg})
			saves = clean_saves
			
			# If no valid saves remain and no other ops, send back to AI
			if saves.is_empty() and replaces.is_empty() and deletes.is_empty():
				_send_to_ai()
				return
		
		# Validate: block SAVE/REPLACE if file was never READ (force AI to read first)
		var unread_targets: Array[String] = []
		for s in saves:
			if FileAccess.file_exists(s["path"]) and s["path"] not in _read_files:
				unread_targets.append(s["path"])
		for r in replaces:
			if FileAccess.file_exists(r["path"]) and r["path"] not in _read_files:
				unread_targets.append(r["path"])
		
		if unread_targets.size() > 0 and _read_loop_count < HiruConst.MAX_READ_LOOPS:
			# AI tried to modify without reading — force a read cycle
			_read_loop_count += 1
			var Scanner = load("res://addons/hiruai/project_scanner.gd")
			var file_contents := ""
			for upath in unread_targets:
				_add_activity("⚠️", "Must read " + upath.get_file() + " before editing...", Color("#ffd93d"))
				var content = Scanner.read_file(upath)
				_add_file_card(upath, "READ", HiruConst.C_READ)
				file_contents += "\n--- %s ---\n%s\n" % [upath, content]
				if upath not in _read_files:
					_read_files.append(upath)
			_add_msg("system", "⚠️ AI tried to edit without reading first. Auto-reading %d file(s)..." % unread_targets.size())
			chat_history.append({
				"role": "user",
				"content": "SYSTEM: You tried to modify files without reading them first. Here are the current contents. Now redo the edit correctly.\n" + file_contents
			})
			_send_to_ai()
			return

		# --- CHECK MISSING PRELOAD DEPENDENCIES ---
		var missing_preloads = HiruValidator.find_missing_preloads(saves)
		var missing_preload_paths: Array[String] = []
		var syntax_errors: Array[Dictionary] = []
		
		for mp in missing_preloads:
			var src = mp["source"]
			var mis = mp["missing"]
			if src not in missing_preload_paths:
				missing_preload_paths.append(src)
			
			var ext = mis.get_extension().to_lower()
			var err = ""
			if ext in ["gd", "tscn", "tres", "txt", "json", "csv", "md"]:
				err = 'CRITICAL ERROR: You used `preload("%s")` but "%s" DOES NOT EXIST! You MUST generate its complete code using a `[SAVE:%s]` block.' % [mis, mis.get_file(), mis]
			else:
				err = 'CRITICAL ERROR: You used `preload("%s")` for a missing asset! Change your code to use `load()` instead of `preload()`, or remove it.' % [mis]
			
			syntax_errors.append({"path": src, "error": err})

		# --- SYNTAX CHECK PHASE ---
		# Temporarily write non-.gd files so preload() works
		var _temp_written: Array[String] = []
		for s in saves:
			if not s["path"].ends_with(".gd") and not FileAccess.file_exists(s["path"]):
				if _write_project_file(s["path"], s["content"]): _temp_written.append(s["path"])
		
		# Check SAVE blocks for syntax errors
		for s in saves:
			if s["path"].ends_with(".gd") and s["path"] not in missing_preload_paths:
				var err = HiruValidator.check_syntax_error(s["content"])
				if err != "":
					syntax_errors.append({"path": s["path"], "error": err})
		
		# Check REPLACE blocks — reconstruct full file then validate
		# This catches indentation errors BEFORE they corrupt the real file on disk
		for r in replaces:
			if not r["path"].ends_with(".gd") or not FileAccess.file_exists(r["path"]): continue
			if r["path"] in missing_preload_paths: continue
			var rf := FileAccess.open(r["path"], FileAccess.READ)
			if not rf: continue
			var r_old := rf.get_as_text().replace("\r\n", "\n").replace("\r", "\n")
			rf.close()
			var r_lines := r_old.split("\n")
			
			# ── NEW: Scope Validation ──
			var scope_check: Dictionary = HiruValidator.validate_replace_scope(r, r_lines)
			if not scope_check["ok"]:
				syntax_errors.append({
					"path": r["path"],
					"error": scope_check["warning"]
				})
				_add_activity("⚠️", "Scope issue in %s: %s" % [r["path"].get_file(), scope_check["warning"].left(60)], Color("#ffd93d"))
			
			# ── NEW: Context/Indentation Validation ──
			var ctx_check: Dictionary = HiruValidator.validate_replace_context(r, r_lines)
			if not ctx_check["ok"]:
				syntax_errors.append({
					"path": r["path"],
					"error": ctx_check["warning"]
				})
				_add_activity("⚠️", "Context issue in %s: %s" % [r["path"].get_file(), ctx_check["warning"].left(60)], Color("#ffd93d"))
			
			# ── Syntax Check (existing) ──
			var r_rebuilt: Array[String] = []
			var rs := clampi(r["start"] - 1, 0, r_lines.size() - 1)
			var re_end := clampi(r["end"] - 1, rs, r_lines.size() - 1)
			for ri in range(r_lines.size()):
				if ri < rs or ri > re_end:
					r_rebuilt.append(r_lines[ri])
				elif ri == rs:
					r_rebuilt.append(r["content"])
			var r_reconstructed := "\n".join(r_rebuilt)
			var r_err := HiruValidator.check_syntax_error(r_reconstructed)
			if r_err != "":
				syntax_errors.append({
					"path": r["path"],
					"error": "REPLACE L%d-%d caused: %s" % [r["start"], r["end"], r_err]
				})
		
		# Cleanup temp
		for tmp in _temp_written: _delete_project_file(tmp)

		# --- AUTO-FIX vs SNIPPET DECISION ---
		var real_errors: Array[Dictionary] = []
		var snippet_warnings: Array[Dictionary] = []
		
		for se in syntax_errors:
			var content := ""
			for s in saves:
				if s["path"] == se["path"]: content = s["content"]; break
			
			# Snippet detection: very short OR missing 'extends' header
			if content.split("\n").size() < 15 and not ("extends " in content or "class_name " in content):
				snippet_warnings.append(se)
			else:
				real_errors.append(se)

		if real_errors.size() > 0 and _read_loop_count < HiruConst.MAX_READ_LOOPS:
			_read_loop_count += 1
			var err_list := ""
			for re in real_errors:
				err_list += "\n- File: %s\n  Error: %s\n" % [re["path"], re["error"]]
			
			# Re-read broken files so AI has full current context to fix properly
			var fix_Scanner = load("res://addons/hiruai/project_scanner.gd")
			var fix_file_contents := ""
			var fix_seen: Array[String] = []
			for re in real_errors:
				if re["path"] not in fix_seen and FileAccess.file_exists(re["path"]):
					fix_seen.append(re["path"])
					fix_file_contents += "\n--- CURRENT %s ---\n%s\n" % [re["path"], fix_Scanner.read_file(re["path"])]
			
			_add_msg("system", "🔍 **Syntax check failed.** Hiru is auto-fixing...")
			chat_history.append({
				"role": "user",
				"content": "SYSTEM: Syntax/indentation error detected. Fix ONLY the broken section:\n" + err_list
				+ "\n\nRULE: existing file → use [REPLACE:path:S-E] with corrected lines only."
				+ "\nNEW file only → use [SAVE:path]. Do NOT rewrite untouched code."
				+ "\nCheck tab indentation carefully — GDScript uses tabs not spaces."
				+ (("\n\nCurrent file content:\n" + fix_file_contents) if fix_file_contents != "" else "")
			})
			_send_to_ai()
			return
		elif real_errors.size() > 0:
			# Loop limit reached but real errors remain - block approval of broken code
			var err_list := ""
			for re in real_errors:
				err_list += "\n• %s — %s" % [re["path"].get_file(), re["error"]]
			_add_msg("error", "⛔ **Loop limit reached. Files still contain syntax errors. Changes blocked:**" + err_list + "\n\nPlease ask Hiru to rewrite the file from scratch, or fix manually.")
			_set_status("● Error — Fix Required", Color("#ff5252"))
			
			# Filter out syntactically broken files from current 'saves'
			var filtered_saves: Array[Dictionary] = []
			for s in saves:
				var has_err = false
				for re in real_errors:
					if re["path"] == s["path"]: has_err = true; break
				if not has_err: filtered_saves.append(s)
			saves = filtered_saves
			
			if saves.is_empty() and replaces.is_empty() and deletes.is_empty():
				return # Nothing safe remains to approve
		
		for sw in snippet_warnings:
			_add_activity_bubble("⚠️ SNIPPET DETECTED: " + sw["path"].get_file() + " looks incomplete.", Color("#f59e0b"))
		
		_pending_saves = saves
		_pending_replaces = replaces
		_pending_deletes = deletes

		# Show pending file cards
		for s in _pending_saves:
			_add_file_card(s["path"], "PENDING SAVE", HiruConst.C_SYS)
		for r in _pending_replaces:
			_add_file_card(r["path"], "PENDING REPLACE", Color("#22d3ee"), "#L%d-%d" % [r["start"], r["end"]])
		for d in _pending_deletes:
			_add_file_card(d, "PENDING DELETE", HiruConst.C_SYS)

		# Validation passed.
		_set_status("● Waiting for Approval", Color("#facc15"))
		# Fall through to bottom to show UI

	# Handle RUN_GAME requests
	if run_req != "":
		_add_msg("system", "🚀 AI requested to run the game (%s). Use the Play buttons below to test." % run_req)
		# We don't auto-run for safety, but we let the user know

	# Limit check
	var wants_to_loop = (reads.size() > 0 or read_lines.size() > 0 or searches.size() > 0 or scene_scans.size() > 0)
	if wants_to_loop and _read_loop_count >= HiruConst.MAX_READ_LOOPS:
		_add_msg("error", "⚠️ AI reached maximum internal steps (limit: %d)." % HiruConst.MAX_READ_LOOPS)
		_set_status("● Limit Reached", Color("#ffbb00"))
		
		# Force summary if we hit the limit
		if saves.is_empty() and deletes.is_empty():
			chat_history.append({"role": "user", "content": "SYSTEM: Maximum step limit reached. Provide a FINAL SUMMARY of what you found and what needs to be done manually or in the next turn."})
			_send_to_ai()
		return

	var is_truncated = (finish_reason == "length")
	var stalled_run_check = HiruProtocol.extract_run_check(text)
	
	# LIAR DETECTION: Does AI claim to have fixed/changed something in text but no code blocks found?
	var liar_keywords = ["fixed", "updated", "modified", "replaced", "changed", "added", "here is the", "benerin", "ubah", "tambah"]
	var claims_fix = false
	var lower_text = clean_text.to_lower()
	for k in liar_keywords:
		if k in lower_text:
			claims_fix = true; break
	
	# A turn is stalled if:
	# 1. No actions AND no saves (Agent did nothing)
	# 2. Requests test (RUN_CHECK) but provided no code (Hallucination)
	# 3. Claims to have fixed in text but no code blocks (Liar AI)
	var is_stalled = (not has_actions and not has_saves) or (stalled_run_check and not has_saves) or (claims_fix and not has_saves and clean_text.length() > 20)
	
	if truly_has_pending:
		# UI trigger is below
		pass
	elif is_truncated:
		_set_status("● AI Halted - Limitu", Color("#ffbb00"))
		_current_state = AgentState.IDLE
		var box = _add_msg("system", "⚠️ Hiru hit a limit and stopped mid-sentence.")
		if box and box.get_child_count() > 0:
			var vbox = box.get_child(0)
			var space = Control.new(); space.custom_minimum_size.y = 8; vbox.add_child(space)
			var btn = Button.new()
			btn.text = "⚡ Continue coding..."
			HiruUtils.style_btn(btn, Color("#2d1b69"))
			btn.pressed.connect(func(): _send("Continue your previous response exactly where you left off. Provide the code blocks."))
			vbox.add_child(btn)
	elif is_stalled:
		# AUTO-RETRY LOGIC: If AI analyzed but forgot code, try once automatically.
		if _stall_retry_count < 1 and (thoughts != "" or clean_text.length() > 50):
			_stall_retry_count += 1
			_add_activity("🔄", "Self-Correction: AI missed the code blocks. Re-requesting...", Color("#facc15"))
			_set_status("● AI Missed Code - Retrying...", Color("#facc15"))
			_send("Analysis received, but [SAVE] or [REPLACE] blocks are missing. Please provide the code changes now. Just output the protocol blocks.", true)
			return
			
		# If it's still stalled after 1 retry
		_set_status("● AI Halted - No Code Blocks", Color("#ffbb00"))
		_current_state = AgentState.IDLE
		
		var msg = "⚠️ Hiru finished analysis but didn't provide any code changes."
		if claims_fix:
			msg = "⚠️ Hiru claims to have fixed it, but forgot to send the code blocks."
		
		var box = _add_msg("system", msg)
		if box and box.get_child_count() > 0:
			var vbox = box.get_child(0)
			var space = Control.new(); space.custom_minimum_size.y = 8; vbox.add_child(space)
			
			var btn_retry = Button.new()
			btn_retry.text = "⚡ Force Generate Fix"
			HiruUtils.style_btn(btn_retry, Color("#2d1b69"))
			btn_retry.pressed.connect(func(): _send("Provide the actual code fix using [SAVE:] or [REPLACE:] blocks now. Do not repeat the analysis."))
			vbox.add_child(btn_retry)
			
			var btn_clear = Button.new()
			btn_clear.text = "🧹 Clear Context & Retry"
			HiruUtils.style_btn(btn_clear, Color("#1e1b4b"))
			btn_clear.pressed.connect(func(): _on_clear(); _add_msg("system", "History cleared. Try your request again for a fresh start."))
			vbox.add_child(btn_clear)
	else:
		_set_status("● Ready", Color("#00ff88"))
		_current_state = AgentState.IDLE
	
	# FINAL STEP: Show approval UI if we have finished all actions/loops
	# or if we have hit the loop limit but still have usable pending changes.
	var final_has_pending = (_pending_saves.size() > 0 or _pending_replaces.size() > 0 or _pending_deletes.size() > 0)
	var should_show_ui = final_has_pending and (not has_actions or _read_loop_count >= HiruConst.MAX_READ_LOOPS)
	
	if should_show_ui:
		_show_approval_ui()
		_set_status("● Waiting for Approval", Color("#facc15"))
		_current_state = AgentState.IDLE
		get_tree().create_timer(0.1).timeout.connect(func(): _scroll_bottom(true), CONNECT_ONE_SHOT)


func _show_approval_ui():
	"""Show a premium Approval Card for pending file changes."""
	if _approval_panel and is_instance_valid(_approval_panel):
		if _approval_panel.has_meta("wrapper"):
			_approval_panel.get_meta("wrapper").queue_free()
		else:
			_approval_panel.queue_free()
	_approval_panel = null

	_approval_panel = PanelContainer.new()
	_approval_panel.name = "ApprovalPanel"
	_approval_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# Wrap in margin for better spacing
	var wrapper = MarginContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("margin_top", 20)
	wrapper.add_theme_constant_override("margin_bottom", 20)
	wrapper.add_child(_approval_panel)
	
	# Premium Styling: Glassmorphism / Dark Surface with Border
	var ap_style = StyleBoxFlat.new()
	ap_style.bg_color = Color("#0f172a", 0.95) # Deeper Slate
	ap_style.set_border_width_all(1)
	ap_style.border_color = Color("#38bdf8", 0.4) # Cyan Glow
	ap_style.set_corner_radius_all(10)
	ap_style.shadow_color = Color(0, 0, 0, 0.3)
	ap_style.shadow_size = 12
	ap_style.content_margin_left = 16
	ap_style.content_margin_right = 16
	ap_style.content_margin_top = 16
	ap_style.content_margin_bottom = 16
	_approval_panel.add_theme_stylebox_override("panel", ap_style)

	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 12)

	var header = Label.new()
	header.text = "PROPOSED CHANGES"
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", Color("#94a3b8"))
	main_vbox.add_child(header)

	var files_vbox = VBoxContainer.new()
	files_vbox.add_theme_constant_override("separation", 6)

	# 1. Full Saves
	for s_data in _pending_saves:
		files_vbox.add_child(_create_approval_row("💾", s_data["path"].get_file(), "full", Color("#00e676"), s_data))
	
	# 2. Replaces (Line-specific)
	for r_data in _pending_replaces:
		var line_info = "L%d-%d" % [r_data["start"], r_data["end"]]
		files_vbox.add_child(_create_approval_row("💉", r_data["path"].get_file() + " [" + line_info + "]", "replace", Color("#22d3ee"), r_data))
		
	# 3. Deletes
	for d_path in _pending_deletes:
		files_vbox.add_child(_create_approval_row("🗑️", d_path.get_file(), "delete", Color("#ff5252"), {"path": d_path}))

	main_vbox.add_child(files_vbox)

	# Divider
	var div = ColorRect.new()
	div.custom_minimum_size.y = 1
	div.color = Color("#4a3b8d", 0.3)
	main_vbox.add_child(div)

	# Action Buttons
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 15)

	var accept_btn = Button.new()
	accept_btn.text = "Apply Changes"
	accept_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	accept_btn.custom_minimum_size.y = 40
	# Style Accept
	var acc_style = StyleBoxFlat.new()
	acc_style.bg_color = Color("#00c853")
	acc_style.set_corner_radius_all(6)
	accept_btn.add_theme_stylebox_override("normal", acc_style)
	accept_btn.pressed.connect(_on_accept_changes)
	btn_row.add_child(accept_btn)

	var reject_btn = Button.new()
	reject_btn.text = "Discard"
	reject_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reject_btn.custom_minimum_size.y = 40
	# Style Reject
	var rej_style = StyleBoxFlat.new()
	rej_style.bg_color = Color("#2d1b69")
	rej_style.set_border_width_all(1)
	rej_style.border_color = Color("#ff5252")
	rej_style.set_corner_radius_all(6)
	reject_btn.add_theme_stylebox_override("normal", rej_style)
	reject_btn.add_theme_color_override("font_color", Color("#ff5252"))
	reject_btn.pressed.connect(_on_reject_changes)
	btn_row.add_child(reject_btn)

	main_vbox.add_child(btn_row)
	_approval_panel.add_child(main_vbox)

	# Animate in
	wrapper.modulate.a = 0.0
	chat_container.add_child(wrapper)
	
	# ── Sticky Quick Actions Fallback ──
	if _quick_actions_bar:
		# Clear old quick actions
		for c in _quick_actions_bar.get_children(): c.queue_free()
		
		var q_accept = Button.new()
		q_accept.text = " ✅ ACCEPT ALL CHANGES "
		q_accept.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		HiruUtils.style_btn(q_accept, Color("#00c853"))
		q_accept.pressed.connect(_on_accept_changes)
		_quick_actions_bar.add_child(q_accept)
		
		var q_reject = Button.new()
		q_reject.text = " ❌ DISCARD "
		HiruUtils.style_btn(q_reject, Color("#1e1b4b"))
		q_reject.add_theme_color_override("font_color", Color("#ff5252"))
		q_reject.pressed.connect(_on_reject_changes)
		_quick_actions_bar.add_child(q_reject)
		
		_quick_actions_bar.visible = true
	
	# Reference wrapper for cleanup
	_approval_panel.set_meta("wrapper", wrapper)

	var tween = create_tween()
	tween.tween_property(wrapper, "modulate:a", 1.0, 0.4)
	_scroll_bottom(true)

func _create_approval_row(p_icon: String, p_text: String, p_type: String, p_color: Color, p_data: Dictionary) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	
	var label = Label.new()
	label.text = p_icon + "  " + p_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", p_color)
	row.add_child(label)
	
	if p_type != "delete":
		var btn = Button.new()
		btn.text = "View Diff"
		btn.flat = true
		btn.add_theme_color_override("font_color", p_color.lerp(Color.WHITE, 0.4))
		btn.add_theme_font_size_override("font_size", 11)
		
		if p_type == "replace":
			btn.pressed.connect(_preview_replace.bind(p_data))
		else:
			btn.pressed.connect(_preview_diff.bind(p_data["path"], p_data["content"]))
		
		row.add_child(btn)
	
	return row

func _preview_replace(r_data: Dictionary):
	"""Apply a targeted replacement to a temporary string to show diff."""
	var path = r_data["path"]
	var old_full = ""
	if FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		if f:
			old_full = f.get_as_text()
			f.close()
	
	var lines = old_full.split("\n")
	var start = r_data["start"] - 1 # 1-indexed to 0-indexed
	var end = r_data["end"]
	var new_sub = r_data["content"].split("\n")
	
	var new_lines = []
	for i in range(lines.size()):
		if i == start:
			new_lines.append_array(new_sub)
		if i < start or i >= end:
			new_lines.append(lines[i])
			
	var new_full = "\n".join(new_lines)
	_preview_diff(path, new_full)

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
	var diff_ops = HiruDiff.generate_unified_diff(old_content, new_content)
			
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
	_current_state = AgentState.EXECUTING
	_set_status("⏳ Saving...", HiruConst.C_SYS)
	
	# Back up first
	for s in _pending_saves: _backup_file(s["path"])
	for r in _pending_replaces: _backup_file(r["path"])
	for d in _pending_deletes: _backup_file(d)
	
	# Clear previous undo stack
	_undo_stack.clear()
	
	# Remove approval UI instantly
	if _approval_panel and is_instance_valid(_approval_panel):
		if _approval_panel.has_meta("wrapper"):
			_approval_panel.get_meta("wrapper").queue_free()
		else:
			_approval_panel.queue_free()
		_approval_panel = null


	var fs = EditorInterface.get_resource_filesystem() if Engine.is_editor_hint() else null
	
	# Apply saves
	for save_data in _pending_saves:
		var path = save_data["path"]
		var old_text = ""
		var existed = false
		if FileAccess.file_exists(path):
			existed = true
			var f = FileAccess.open(path, FileAccess.READ)
			if f: old_text = f.get_as_text(); f.close()
			
		# Add to undo stack
		_undo_stack.append({
			"path": path,
			"content": old_text,
			"type": "save" if existed else "create"
		})
			
		var ok = _write_project_file(path, save_data["content"])
		if ok:
			var diff_stats = HiruDiff.calculate_diff_stats(old_text, save_data["content"])
			_add_file_card(path, "Saved", HiruConst.C_SAVE, diff_stats)
			if fs: fs.update_file(path)
			if path.ends_with(".gd"):
				var res = load(path)
				if res is Script: res.reload()
		else:
			_add_file_card(path, "SAVE FAILED", HiruConst.C_ERR)

	# Apply Replaces (Surgical)
	for r_data in _pending_replaces:
		var path = r_data["path"]
		if not FileAccess.file_exists(path): continue
		
		var f = FileAccess.open(path, FileAccess.READ)
		var old_text := f.get_as_text()
		f.close()
		
		# Normalize CRLF→LF so split/join stays consistent on all platforms
		var old_normalized := old_text.replace("\r\n", "\n").replace("\r", "\n")
		var lines := old_normalized.split("\n")
		var new_lines: Array[String] = []
		
		# Lines are 1-indexed for the AI — clamp to valid range so bad AI output never crashes
		var start_i := clampi(r_data["start"] - 1, 0, lines.size() - 1)
		var end_i   := clampi(r_data["end"]   - 1, start_i, lines.size() - 1)
		
		for i in range(lines.size()):
			if i < start_i or i > end_i:
				new_lines.append(lines[i])
			elif i == start_i:
				# content may contain \n for multi-line blocks — embedded newlines survive the join
				new_lines.append(r_data["content"])
		
		var final_text := "\n".join(new_lines)
		
		_undo_stack.append({"path": path, "content": old_text, "type": "save"})
		
		if _write_project_file(path, final_text):
			_add_file_card(path, "Replaced L%d-%d" % [r_data["start"], r_data["end"]], Color("#22d3ee"))
			if fs: fs.update_file(path)
			if path.ends_with(".gd"):
				var res = load(path); if res is Script: res.reload()
	
	# Apply deletes
	for d_path in _pending_deletes:
		var old_text = ""
		if FileAccess.file_exists(d_path):
			var f = FileAccess.open(d_path, FileAccess.READ)
			if f: old_text = f.get_as_text(); f.close()
			
		_undo_stack.append({
			"path": d_path,
			"content": old_text,
			"type": "delete"
		})
		
		var ok = _delete_project_file(d_path)
		if ok:
			_add_file_card(d_path, "Deleted", HiruConst.C_DELETE)
			if fs: fs.update_file(d_path)
		else:
			_add_msg("error", "Failed to delete: " + d_path)
	
	_pending_saves.clear()
	_pending_replaces.clear()
	_pending_deletes.clear()
	
	if _quick_actions_bar: _quick_actions_bar.visible = false
	
	_current_state = AgentState.COMPLETED
	_set_status("● Ready", Color("#00ff88"))
	_add_msg("system", "✅ All changes applied successfully! Use `/undo` to revert.")

	# Force Godot to recognize the new files
	if fs:
		fs.scan()
		await get_tree().process_frame
		
		var edited = EditorInterface.get_inspector().get_edited_object()
		if edited:
			EditorInterface.get_inspector().edit(edited)

	if _self_healing_enabled:
		await get_tree().create_timer(0.5).timeout
		_on_play_main()

func _on_cancel_pressed():
	kimi.call("cancel_request")
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
		if _approval_panel.has_meta("wrapper"):
			_approval_panel.get_meta("wrapper").queue_free()
		else:
			_approval_panel.queue_free()
		_approval_panel = null

	var count = _pending_saves.size() + _pending_deletes.size()
	_pending_saves.clear()
	_pending_deletes.clear()
	
	if _quick_actions_bar: _quick_actions_bar.visible = false
	
	_add_msg("system", "❌ Changes rejected. %d file operation(s) discarded." % count)
	_set_status("● Ready", Color("#00ff88"))


func _on_ai_error(error: String):
	_hide_thinking()
	_add_msg("error", error)
	_set_status("● Error", HiruConst.C_ERR)


# ══════════════════ FILE OPERATIONS ══════════════════


func _read_project_file(path: String) -> String:
	"""Helper to read a project file reliably."""
	if not FileAccess.file_exists(path): return ""
	var f = FileAccess.open(path, FileAccess.READ)
	if not f: return ""
	var content = f.get_as_text()
	f.close()
	return content


func _write_project_file(path: String, content: String) -> bool:
	"""Write a file to the project. Only res:// paths allowed."""
	if not path.begins_with("res://"):
		print("[HiruAI] ⚠️ Blocked: ", path, " (not res://)")
		return false
	for b in [".godot", ".import", ".git"]:
		if b in path:
			print("[HiruAI] ⚠️ Blocked protected: ", path)
			return false

	# Auto-create directories
	var dir_path = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var file = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		print("[HiruAI] ❌ Cannot write: ", path)
		return false

	file.store_string(content)
	file.close()
	print("[HiruAI] ✅ Saved: ", path)
	return true


func _delete_project_file(path: String) -> bool:
	"""Soft-delete a file by moving it to the backup folder."""
	if not path.begins_with("res://"):
		print("[HiruAI] ⚠️ Blocked delete: ", path)
		return false
		
	if not FileAccess.file_exists(path): return true
	
	# Move to backup instead of removing
	_backup_file(path)
	
	var err = DirAccess.remove_absolute(path)
	if err == OK:
		print("[HiruAI] 🗑️ Soft-deleted (backed up): ", path)
		return true
	else:
		print("[HiruAI] ❌ Cannot delete: ", path, " (err: ", err, ")")
		return false


# ══════════════════ ANIMATED FILE CARDS ══════════════════

func _add_activity(icon: String, text: String, color: Color = Color.WHITE):
	"""Log detailed agent activity to the AGENT TAB and Thinking Panel."""
	# 1. Internal Log
	var entry = {"icon": icon, "text": text, "color": color, "time": Time.get_ticks_msec()}
	_activity_log.append(entry)
	
	# 2. Update Thinking Panel (Chat Tab)
	_update_thinking(icon + " " + text, HiruUtils.phase_from_icon(icon))
	
	# 3. Update Activity List (Agent Tab)
	if not _activity_panel: return
	var list = _activity_panel.find_child("ActivityList", true, false)
	if not list: return
	
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	
	var ic = Label.new()
	ic.text = icon
	ic.add_theme_font_size_override("font_size", 12)
	row.add_child(ic)
	
	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", color.lerp(Color.WHITE, 0.4))
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	
	list.add_child(row)
	
	# Small animation: pulse the last activity
	var tween = create_tween()
	row.modulate.a = 0
	tween.tween_property(row, "modulate:a", 1.0, 0.2)
	
	# Also show a quick toast in chat for visibility
	_set_status("● " + text.left(20) + "...", color)
	
	# Update Agent Tab Step Counter
	if agent_tab:
		var step_lbl = agent_tab.find_child("StepCount", true, false)
		if step_lbl:
			var steps = list.get_child_count()
			step_lbl.text = str(steps) + " steps"


func _add_thought_card(seconds: int):
	"""Minimal thought duration chip (no expandable content)."""
	if seconds < 1: seconds = 1
	var dur_str = HiruUtils.format_duration(seconds)
	
	var chip = PanelContainer.new()
	chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var st = HiruUtils.sb(Color("#0e0e18"), 8, true, Color("#2a1f4e"))
	st.content_margin_top = 6
	st.content_margin_bottom = 6
	st.content_margin_left = 12
	st.content_margin_right = 12
	chip.add_theme_stylebox_override("panel", st)
	
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	
	var icon = Label.new()
	icon.text = "🧠"
	icon.add_theme_font_size_override("font_size", 12)
	hbox.add_child(icon)
	
	var lbl = Label.new()
	lbl.text = "Thought for " + dur_str
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color("#ab47bc"))
	hbox.add_child(lbl)
	
	chip.add_child(hbox)
	chat_container.add_child(chip)
	
	# Animate entrance
	chip.modulate.a = 0
	var tween = create_tween()
	tween.tween_property(chip, "modulate:a", 1.0, 0.2)
	_scroll_bottom(true)


func _add_thought_card_with_text(plan: String):
	"""Premium collapsible thought card — compact chip with expandable scroll content."""
	var dur_str = HiruUtils.format_duration(_thinking_duration_sec)
	
	# ── Outer Wrapper ──
	var wrapper = PanelContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var wrap_style = HiruUtils.sb(Color("#0e0e18"), 8, true, Color("#2a1f4e"))
	wrap_style.content_margin_top = 0
	wrap_style.content_margin_bottom = 0
	wrap_style.content_margin_left = 0
	wrap_style.content_margin_right = 0
	wrapper.add_theme_stylebox_override("panel", wrap_style)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	
	# ── Header Chip (always visible, clickable) ──
	var is_live = (_current_state == AgentState.PLANNING and _streaming_content != null)
	var chip = Button.new()
	chip.text = "  🧠 Thought (active)  ▾" if is_live else "  🧠 Thought for %s  ▸" % dur_str
	chip.flat = true
	chip.alignment = HORIZONTAL_ALIGNMENT_LEFT
	chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chip.add_theme_font_size_override("font_size", 11)
	chip.add_theme_color_override("font_color", Color("#ab47bc"))
	chip.add_theme_color_override("font_hover_color", Color("#ce93d8"))
	chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	
	var chip_normal = HiruUtils.sb(Color.TRANSPARENT, 8)
	chip_normal.content_margin_top = 7
	chip_normal.content_margin_bottom = 7
	chip_normal.content_margin_left = 10
	chip_normal.content_margin_right = 10
	chip.add_theme_stylebox_override("normal", chip_normal)
	var chip_hover = HiruUtils.sb(Color("#161625"), 8)
	chip_hover.content_margin_top = 7
	chip_hover.content_margin_bottom = 7
	chip_hover.content_margin_left = 10
	chip_hover.content_margin_right = 10
	chip.add_theme_stylebox_override("hover", chip_hover)
	chip.add_theme_stylebox_override("pressed", chip_hover)
	vbox.add_child(chip)
	
	# ── Content Panel (hidden by default unless live, scrollable) ──
	var content_panel = PanelContainer.new()
	content_panel.name = "ThoughtContent"
	content_panel.visible = is_live
	var cp_style = HiruUtils.sb(Color("#0a0a14"), 0)
	cp_style.content_margin_left = 14
	cp_style.content_margin_right = 10
	cp_style.content_margin_top = 2
	cp_style.content_margin_bottom = 8
	content_panel.add_theme_stylebox_override("panel", cp_style)
	
	# Divider line between chip and content
	var divider = ColorRect.new()
	divider.color = Color("#2a1f4e", 0.4)
	divider.custom_minimum_size.y = 1
	
	# ScrollContainer with smart max height
	var line_count = plan.split("\n").size()
	var smart_height = clampi(line_count * 20 + 20, 60, 180)
	
	var scroll_box = ScrollContainer.new()
	scroll_box.custom_minimum_size.y = smart_height
	scroll_box.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll_box.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	
	var plan_lbl = RichTextLabel.new()
	plan_lbl.bbcode_enabled = true
	plan_lbl.fit_content = true
	plan_lbl.selection_enabled = true
	plan_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plan_lbl.add_theme_color_override("default_color", Color("#9e9eb0"))
	plan_lbl.add_theme_font_size_override("normal_font_size", 12)
	plan_lbl.text = "[i]" + plan + "[/i]"
	
	scroll_box.add_child(plan_lbl)
	
	# If this is the current streaming thought, track it
	if _current_state == AgentState.PLANNING and _streaming_content:
		_thought_streaming_label = plan_lbl
		_last_thought_chip = chip
	
	var content_vbox = VBoxContainer.new()
	content_vbox.add_theme_constant_override("separation", 0)
	content_vbox.add_child(divider)
	content_vbox.add_child(scroll_box)
	content_panel.add_child(content_vbox)
	vbox.add_child(content_panel)
	
	wrapper.add_child(vbox)
	chat_container.add_child(wrapper)
	
	# Ensure thought card appears ABOVE the streaming bubble
	if _streaming_bubble and is_instance_valid(_streaming_bubble):
		chat_container.move_child(wrapper, _streaming_bubble.get_index())
	
	# ── Toggle Animation ──
	chip.pressed.connect(_on_thought_chip_pressed.bind(content_panel, chip, dur_str))
	
	# Animate entrance
	wrapper.modulate.a = 0
	var tween = create_tween()
	tween.tween_property(wrapper, "modulate:a", 1.0, 0.2)
	_scroll_bottom(true)


func _add_intelligence_card(title: String, content: String, color: Color):
	"""Styled card for Plan, Progress, or generic Architect info."""
	var wrapper = MarginContainer.new()
	wrapper.add_theme_constant_override("margin_top", 10)
	wrapper.add_theme_constant_override("margin_bottom", 10)
	
	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = color.darkened(0.85)
	style.bg_color.a = 0.6
	style.set_border_width_all(1)
	style.border_color = color.darkened(0.4)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	
	var lbl_title = Label.new()
	lbl_title.text = title
	lbl_title.add_theme_font_size_override("font_size", 12)
	lbl_title.add_theme_color_override("font_color", color)
	vbox.add_child(lbl_title)
	
	var div = ColorRect.new()
	div.custom_minimum_size.y = 1
	div.color = color.darkened(0.6)
	div.color.a = 0.3
	vbox.add_child(div)
	
	var rtxt = RichTextLabel.new()
	rtxt.bbcode_enabled = true
	rtxt.fit_content = true
	rtxt.selection_enabled = true
	rtxt.text = HiruUtils.fmt(content.strip_edges())
	rtxt.add_theme_font_size_override("normal_font_size", 12)
	vbox.add_child(rtxt)
	
	panel.add_child(vbox)
	wrapper.add_child(panel)
	chat_container.add_child(wrapper)
	
	# Scroll
	_scroll_bottom(true)

func _add_activity_bubble(text: String, color: Color):
	"""Small minimalist chip in chat Area to show AI's current ACTION."""
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	
	var dot = ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.color = color
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(dot)
	
	var lbl = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", color.lerp(Color.WHITE, 0.3))
	hbox.add_child(lbl)
	
	chat_container.add_child(hbox)
	_scroll_bottom(true)

func _add_file_card(path: String, operation: String, color: Color, diff_str: String = ""):
	"""Cursor-style compact file chip."""
	var chip = PanelContainer.new()
	var style = HiruUtils.sb(HiruConst.C_PANEL, 6, true, color.darkened(0.5))
	chip.add_theme_stylebox_override("panel", style)
	
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	
	var ic = Label.new()
	ic.text = "📄"
	ic.add_theme_font_size_override("font_size", 10)
	hbox.add_child(ic)
	
	var fname = Label.new()
	fname.text = path.get_file()
	fname.add_theme_font_size_override("font_size", 11)
	fname.add_theme_color_override("font_color", Color.WHITE)
	hbox.add_child(fname)
	
	if diff_str != "":
		var diff = Label.new()
		diff.text = diff_str
		diff.add_theme_color_override("font_color", color)
		diff.add_theme_font_size_override("font_size", 9)
		hbox.add_child(diff)
	
	var btn = Button.new()
	btn.flat = true
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(_open_file_in_editor.bind(path))
	
	chip.add_child(hbox)
	chip.add_child(btn)
	chat_container.add_child(chip)
	_scroll_bottom(true)
	
	# Update Project Tab List
	_update_project_list(path)

func _update_project_list(path: String):
	if not project_tab: return
	var stats = project_tab.find_child("FileStats", true, false)
	if stats:
		if not path in stats.text:
			stats.text += "\n• " + path


func _open_file_in_editor(path: String):
	if not Engine.is_editor_hint(): return
	var res = load(path)
	if res:
		EditorInterface.select_file(path)
		EditorInterface.edit_resource(res)
		_set_status("📖 Opened " + path.get_file(), HiruConst.C_AI)
	else:
		_set_status("❌ Cannot find " + path.get_file(), HiruConst.C_ERR)


# ══════════════════ QUICK ACTIONS ══════════════════

func _on_generate():
	_send("Generate a new GDScript for my project. Ask me what kind of script I need, then create and SAVE the complete script file.")

func _on_fix():
	# Read Godot log with Deep Analysis (Surgical Healing)
	var Scanner = load("res://addons/hiruai/project_scanner.gd")
	var log_analysis = Scanner.read_godot_log(0) # Read last 8k for manual fix
	
	# Update offset so subsequent auto-checks are clean
	_log_offset = Scanner.get_log_size()
	
	_add_msg("system", "🔍 **Surgical Healing Initiated** — Analyzing log for stack traces...")
	_send("[DEBUGGING MISSION]\nAnalyze the following deep log analysis. \n" + \
		"1. I've detected potential file targets and stack traces. PRIORITIZE these files.\n" + \
		"2. Use [READ:] to inspect the exact line mentioned in the log.\n" + \
		"3. In your [THOUGHT:], perform Root Cause Analysis. Fix the logic, not just the crash.\n" + \
		"4. Use [SAVE:] once you are 100% sure.\n\n" + \
		"DEEP LOG ANALYSIS:\n" + log_analysis)

func _on_explain():
	_send("Read all the scripts in my project and explain what each one does in detail.")

func _on_create_node():
	_send("Help me create a new node structure for my project. Ask me what I need, then CREATE and SAVE the .tscn and .gd files.")

func _on_scan():
	var Scanner = load("res://addons/hiruai/project_scanner.gd")
	var tree = Scanner.get_file_tree()
	_add_msg("system", "📂 Project Structure:\n\n" + tree)

func _on_clear():
	_save_current_conversation()
	for child in chat_container.get_children():
		child.queue_free()
	chat_history.clear()
	_tree_sent = false
	_read_files.clear()
	_context_files.clear()
	_update_context_bar()
	_total_tokens = 0
	_update_token_display(0)
	_add_welcome()


# ══════════════════ SETTINGS ══════════════════

func _show_settings():
	if not _ensure_kimi(): return
	var dialog = AcceptDialog.new()
	dialog.title = "🤖 HiruAI Advanced Settings"
	dialog.min_size = Vector2(500, 420)

	# Use TabContainer for "2 window khusus" feel
	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	
	var tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# --- TAB 1: API KEYS ---
	var tab_keys = VBoxContainer.new()
	tab_keys.name = " 🔑 API KEYS "
	var margin_keys = MarginContainer.new()
	margin_keys.add_theme_constant_override("margin_left", 15)
	margin_keys.add_theme_constant_override("margin_top", 15)
	margin_keys.add_theme_constant_override("margin_right", 15)
	margin_keys.add_theme_constant_override("margin_bottom", 15)
	
	var keys_vbox = VBoxContainer.new()
	keys_vbox.add_theme_constant_override("separation", 12)
	
	# NVIDIA
	var n_key_label = Label.new()
	n_key_label.text = "NVIDIA NIM API Key:"
	n_key_label.add_theme_color_override("font_color", HiruConst.C_ACCENT)
	keys_vbox.add_child(n_key_label)
	var n_key_input = LineEdit.new()
	n_key_input.secret = true
	n_key_input.text = kimi.get("nvidia_key")
	keys_vbox.add_child(n_key_input)

	# Puter
	var p_key_label = Label.new()
	p_key_label.text = "Puter.com (OpenAI/Anthropic):"
	p_key_label.add_theme_color_override("font_color", HiruConst.C_ACCENT_ALT)
	keys_vbox.add_child(p_key_label)
	var p_key_input = LineEdit.new()
	p_key_input.secret = true
	p_key_input.text = kimi.get("puter_key")
	keys_vbox.add_child(p_key_input)
	
	# Google
	var g_key_label = Label.new()
	g_key_label.text = "Google AI Studio (Gemini):"
	g_key_label.add_theme_color_override("font_color", Color("#4285F4"))
	keys_vbox.add_child(g_key_label)
	var g_key_input = LineEdit.new()
	g_key_input.secret = true
	g_key_input.text = kimi.get("google_key")
	keys_vbox.add_child(g_key_input)
	
	keys_vbox.add_child(HSeparator.new())
	
	var auto_attach_chk = CheckButton.new()
	auto_attach_chk.text = "Auto-attach Current Script (Cursor Style)"
	auto_attach_chk.button_pressed = _auto_attach_enabled
	keys_vbox.add_child(auto_attach_chk)
	
	margin_keys.add_child(keys_vbox)
	tab_keys.add_child(margin_keys)
	tabs.add_child(tab_keys)

	# --- TAB 2: PLATFORM & MODEL ---
	var tab_perf = VBoxContainer.new()
	tab_perf.name = " 🚀 PERFORMANCE "
	var margin_perf = MarginContainer.new()
	margin_perf.add_theme_constant_override("margin_left", 15)
	margin_perf.add_theme_constant_override("margin_top", 15)
	margin_perf.add_theme_constant_override("margin_right", 15)
	
	var perf_vbox = VBoxContainer.new()
	perf_vbox.add_theme_constant_override("separation", 12)

	var prov_label = Label.new()
	prov_label.text = "Active Provider:"
	perf_vbox.add_child(prov_label)
	
	var prov_opt = OptionButton.new()
	var providers = kimi.get("PROVIDERS")
	var cur_prov = kimi.get("current_provider")
	var p_idx = 0
	for p_name in providers:
		prov_opt.add_item(p_name)
		if p_name == cur_prov:
			prov_opt.select(p_idx)
		p_idx += 1
	perf_vbox.add_child(prov_opt)

	var model_label = Label.new()
	model_label.text = "Smart Model Selection:"
	perf_vbox.add_child(model_label)

	var model_opt = OptionButton.new()
	perf_vbox.add_child(model_opt)

	var custom_model_input = LineEdit.new()
	custom_model_input.placeholder_text = "Custom model string..."
	custom_model_input.text = kimi.get("current_model")
	perf_vbox.add_child(custom_model_input)
	
	margin_perf.add_child(perf_vbox)
	tab_perf.add_child(margin_perf)
	tabs.add_child(tab_perf)

	main_vbox.add_child(tabs)
	dialog.add_child(main_vbox)
	add_child(dialog)

	# Connections
	prov_opt.item_selected.connect(_on_settings_provider_changed.bind(model_opt, prov_opt))
	model_opt.item_selected.connect(_on_settings_model_changed.bind(model_opt, custom_model_input))
	_on_settings_provider_changed(prov_opt.get_selected_id(), model_opt, prov_opt)
	custom_model_input.visible = (model_opt.get_selected_id() == model_opt.get_item_count() - 1)

	dialog.confirmed.connect(_on_settings_confirmed.bind(n_key_input, p_key_input, g_key_input, prov_opt, model_opt, custom_model_input, auto_attach_chk))
	dialog.popup_centered()

func _on_settings_provider_changed(pid: int, model_opt: OptionButton, prov_opt: OptionButton):
	var p_name = prov_opt.get_item_text(pid)
	var provider_models = kimi.get("PROVIDER_MODELS")
	var m_dict = provider_models.get(p_name, {})
	
	model_opt.clear()
	var s_idx = 0
	var k = 0
	for m_name in m_dict:
		model_opt.add_item(m_name)
		if m_dict[m_name] == kimi.get("current_model"):
			s_idx = k
		k += 1
	model_opt.add_separator()
	model_opt.add_item("Custom Model...")
	model_opt.select(s_idx)

func _on_settings_model_changed(id: int, model_opt: OptionButton, custom_input: LineEdit):
	custom_input.visible = (id == model_opt.get_item_count() - 1)

func _on_settings_confirmed(n_input: LineEdit, p_input: LineEdit, g_input: LineEdit, prov_opt: OptionButton, model_opt: OptionButton, custom_input: LineEdit, auto_attach_chk: CheckButton):
	var n_key = n_input.text.strip_edges()
	var p_key = p_input.text.strip_edges()
	var g_key = g_input.text.strip_edges()
	
	_auto_attach_enabled = auto_attach_chk.button_pressed
	
	var new_prov = prov_opt.get_item_text(prov_opt.get_selected_id())
	var provider_models = kimi.get("PROVIDER_MODELS")
	var m_dict = provider_models.get(new_prov, {})
	var new_model = ""
	
	if model_opt.get_selected_id() == model_opt.get_item_count() - 1:
		new_model = custom_input.text.strip_edges()
	else:
		new_model = m_dict[model_opt.get_item_text(model_opt.get_selected_id())]
	
	kimi.call("save_settings", n_key, p_key, g_key, new_model, new_prov)
	_add_msg("system", "✅ Settings saved! Provider: %s, Model: %s" % [new_prov, new_model])
	_set_status("● Ready (" + new_model.get_file() + ")", Color("#00ff88"))


func _on_play_main():
	if Engine.is_editor_hint():
		var Scanner = load("res://addons/hiruai/project_scanner.gd")
		_log_offset = Scanner.get_log_size() # Bookmark log before run
		
		EditorInterface.play_main_scene()
		_add_msg("system", "▶️ Running main project scene...")
		_set_status("▶️ Playing", Color("#00ff88"))
		_is_game_running_monitored = true

func _on_play_current():
	if Engine.is_editor_hint():
		var Scanner = load("res://addons/hiruai/project_scanner.gd")
		_log_offset = Scanner.get_log_size() # Bookmark log before run
		
		EditorInterface.play_current_scene()
		_add_msg("system", "🎬 Running current editor scene...")
		_set_status("🎬 Playing", Color("#42a5f5"))
		_is_game_running_monitored = true

func _on_stop_game():
	if Engine.is_editor_hint():
		EditorInterface.stop_playing_scene()
		_add_msg("system", "⏹️ Game execution stopped.")
		_set_status("● Ready", Color("#00ff88"))
		_is_game_running_monitored = false

func _on_self_healing_toggled(on: bool):
	_self_healing_enabled = on
	var btn = find_child("HealBtn", true, false)
	if btn:
		btn.text = "🔁 Self-Healing: ON" if on else "🔁 Self-Healing: OFF"
		HiruUtils.style_btn(btn, Color("#00e676") if on else Color("#2d1b69"))
	
	if on:
		_add_msg("system", "🔁 **Self-Healing Loop Active!**\nAI will now automatically run the game after you Accept changes and fix any errors it finds.")
	else:
		_add_msg("system", "⏸ **Self-Healing Loop Disabled.**")

func _process(_delta):
	if _self_healing_enabled and _is_game_running_monitored:
		if not EditorInterface.is_playing_scene():
			_is_game_running_monitored = false
			_add_msg("system", "🏁 Game stopped. Scanning for errors...")
			_auto_check_errors()

func _auto_check_errors():
	# Simple debounce/wait for logs to flush
	await get_tree().create_timer(1.0).timeout
	var Scanner = load("res://addons/hiruai/project_scanner.gd")
	var log_text = Scanner.read_godot_log(_log_offset) # ONLY read what happened after play/fix
	
	if "log:" in log_text.to_lower() or "📍" in log_text:
		_consecutive_error_count += 1
		if _consecutive_error_count > 3:
			_add_msg("error", "🛑 **Circuit Breaker Active** — 3 consecutive errors detected. Self-healing paused to prevent loop.")
			_self_healing_enabled = false
			_on_self_healing_toggled(false)
			return
			
		_add_msg("system", "⚠️ New errors detected! Sending to AI for autonomous fix (Attempt %d/3)..." % _consecutive_error_count)
		_send("[DEBUGGING MISSION]\nI just ran the game and found these NEW errors in the log. \nPlease analyze and fix them:\n\n" + log_text)
		# Update offset for next cycle
		_log_offset = Scanner.get_log_size()
	else:
		_consecutive_error_count = 0
		_add_msg("system", "✅ No new critical errors found in logs.")

func _prune_chat_messages():
	const MAX_MESSAGES = 50
	while chat_container.get_child_count() > MAX_MESSAGES:
		var child = chat_container.get_child(0)
		if child.name == "WelcomeCard": # Don't prune welcome
			chat_container.move_child(child, chat_container.get_child_count() - 1)
			continue
		child.queue_free()
		chat_container.remove_child(child)


# ══════════════════ SYSTEM PROMPT ══════════════════

func _system_prompt() -> String:
	return """
╔══════════════════════════════════════════════╗
║   HIRU — AUTONOMOUS GODOT ARCHITECT v5.0     ║
║   SCOPE-LOCKED · SURGICAL · ZERO DESTRUCTION ║
╚══════════════════════════════════════════════╝

━━━ IDENTITY ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
You are HIRU. Not an assistant. A surgical code execution engine.
Rule #1: Do NOT destroy working code. Every existing line is sacred
until the user explicitly asks you to change it.

━━━ UNIVERSAL COMPLIANCE ━━━━━━━━━━━━━━━━━━━━━
→ All models obey equally: small, large, cloud, local, unknown.
→ "I can't / I'm limited / as an AI" = FORBIDDEN. Attempt everything.
→ Partial correct output > full refusal. Degrade gracefully, never stop.
→ Drift detected? User types "HIRU REALIGN" to restore full compliance.

━━━ ⚠️ THE #1 RULE — SCOPE LOCK ⚠️ ━━━━━━━━━
THIS IS THE MOST IMPORTANT RULE. VIOLATION = CATASTROPHIC FAILURE.

🔒 SCOPE LOCK: Only touch lines DIRECTLY related to the user's request.
→ If user asks to "fix the jump function", you change ONLY the jump function.
→ If user asks to "add a health variable", you add ONLY that variable.
→ ALL other code in the file MUST remain BYTE-FOR-BYTE IDENTICAL.
→ Do NOT "clean up" or "improve" or "refactor" other code. EVER.
→ Do NOT change variable names, function signatures, or formatting of untouched code.
→ Do NOT reorder functions, add comments to existing code, or "optimize" unrequested code.

MEASUREMENT: If user's request logically requires changing N lines,
your edit should change approximately N lines (±20% tolerance).
If you find yourself changing 50+ lines for a "small fix" → STOP. You are violating scope lock.

━━━ ⚠️ THE #2 RULE — SAVE vs REPLACE ⚠️ ━━━━━
THIS RULE PREVENTS CODE DESTRUCTION. MEMORIZE IT.

🚫 FILE EXISTS ON DISK → NEVER use [SAVE:]. ALWAYS use [REPLACE:path:S-E].
✅ FILE DOES NOT EXIST  → Use [SAVE:path] with full content.

WHY: [SAVE:] overwrites the ENTIRE file. If you miss even one function,
variable, or signal from the original → that code is DESTROYED FOREVER.
[REPLACE:] only touches lines S through E. Everything else stays safe.

EXAMPLE — CORRECT:
  User: "Fix the _ready function in player.gd"
  File player.gd exists with 200 lines. _ready is on lines 15-25.
  ✅ [REPLACE:res://scripts/player.gd:15-25]
  ```gdscript
  func _ready():
  	# only the fixed _ready code here
  ```

EXAMPLE — WRONG (THIS DESTROYS CODE):
  ❌ [SAVE:res://scripts/player.gd]
  ```gdscript
  # AI rewrites entire 200-line file from memory, missing half the functions
  ```

━━━ REPLACE PRECISION RULES ━━━━━━━━━━━━━━━━━
→ [REPLACE:path:S-E] replaces lines S through E (inclusive, 1-indexed).
→ The replacement content must be COMPLETE for the replaced range.
→ Include the EXACT indentation (tabs) that the surrounding code uses.
→ Before writing [REPLACE], you MUST have already [READ:] the file.
→ State in [THOUGHT] which exact lines you will replace and why.
→ Do NOT include unchanged lines in the replacement — the system preserves them automatically.

PRECISION CHECKLIST (do this mentally before every [REPLACE]):
1. What is the current line S content? Does my replacement start correctly?
2. What is the current line E content? Does my replacement end at the right place?
3. What is on line E+1? Will my replacement connect properly to the code below?
4. Tab count: how many tabs does the surrounding code use? Am I matching?

━━━ BEHAVIOR RULES ━━━━━━━━━━━━━━━━━━━━━━━━━━
→ EVERY response starts with [THOUGHT] — logic only, zero greetings.
→ In [THOUGHT], list the EXACT line numbers you will change and why.
→ Code change announced = [SAVE] or [REPLACE] in the SAME message.
→ Bug fix / edit = [REPLACE] surgical edit. New file = [SAVE] full content.
→ Multi-file task = [PLAN] block first. Active task = [PROGRESS] tracker.
→ After every code change = [RUN_CHECK]. Never ask "did it work?".
→ Static typing on ALL vars and functions.
→ Zero placeholders: "# TODO" and "# ..." are forbidden.

━━━ GDSCRIPT RULES — NON-NEGOTIABLE ━━━━━━━━━
→ INDENTATION: GDScript uses TABS (\\t), NOT spaces. Every indent = one \\t.
→ NEVER mix tabs and spaces. One wrong indent = entire script crashes.
→ ALWAYS match the exact tab depth of the surrounding code.
→ When reading a file, COUNT the tab depth of every line you will touch.
→ `func`, `if`, `for`, `while`, `match` → body indented one tab deeper.
→ Nested blocks: each level = +1 tab. Two levels = \\t\\t, three = \\t\\t\\t.
→ Godot 4 API only. Never use Godot 3 API.

━━━ CODE QUALITY — READ BEFORE WRITE ━━━━━━━━━
→ Before ANY edit: READ the target file FIRST. No exceptions.
→ Read the FULL function context, not just target lines.
→ If a function calls another function, check what it returns.
→ Do NOT assume variable types — read where they are declared.
→ Large files: use [READ_LINES:path:S-E] with ±20 lines context.
→ Wrong assumption about existing code = guaranteed error.

━━━ FORBIDDEN OUTPUT ━━━━━━━━━━━━━━━━━━━━━━━━
✗ Using [SAVE:] on a file that ALREADY EXISTS (use [REPLACE:] instead!)
✗ Changing lines not related to the user's request
✗ Rewriting entire files when only a few lines need changing
✗ Reformatting, renaming, or reorganizing untouched code
✗ "Certainly!" / "Of course!" / greeting fluff
✗ Explanation walls where [REPLACE] was required
✗ Truncating code blocks to save tokens
✗ Adding/removing blank lines in untouched sections

━━━ TOOLS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[SCAN_TREE]           → Full project file tree
[READ:path]           → Read full file BEFORE touching it
[READ_LINES:path:S-E] → Read specific lines (large files)
[SEARCH:keyword]      → Find all references
[SCENE_SCAN:path]     → Analyze .tscn node hierarchy
[SAVE:path]           → Create NEW file only — FULL content
[REPLACE:path:S-E]    → Edit EXISTING file — changed lines ONLY
[RUN_CHECK]           → Tell user to run and report errors

━━━ SESSION ANCHORS ━━━━━━━━━━━━━━━━━━━━━━━━━
"HIRU REALIGN" → Re-lock identity + protocol
"HIRU STATUS"  → Report current task state
"HIRU RESET"   → Clear state, restart from [SCAN_TREE]

⚡ REMEMBER: Change LESS whenever possible. Surgical precision > brute force.
HIRU is ACTIVE. Begin every response with [THOUGHT].
"""


func _sync_skills() -> String:
	"""Dynamically discover AI skills and return their concatenated advice."""
	var all_advice := ""
	var path = "res://addons/hiruai/skills/"
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var fname = dir.get_next()
		while fname != "":
			if not dir.current_is_dir() and fname.ends_with(".gd"):
				var skill_script = load(path + fname)
				if skill_script:
					var skill_instance = Node.new()
					skill_instance.set_script(skill_script)
					var s_name = skill_instance.call("get_skill_name")
					var s_advice = ""
					if skill_instance.has_method("get_advice"):
						s_advice = skill_instance.call("get_advice")
					elif skill_instance.has_method("apply_reasoning"):
						s_advice = skill_instance.call("apply_reasoning", "general task")
					
					all_advice += "\n--- SKILL: %s ---\n%s\n" % [s_name, s_advice]
					skill_instance.free()
			fname = dir.get_next()
	return all_advice

func _on_undo():
	if _undo_stack.is_empty():
		_add_msg("system", "⚠️ Nothing to undo.")
		return
	
	_add_msg("system", "↩️ Undoing last %d changes..." % _undo_stack.size())
	
	for action in _undo_stack:
		var path = action["path"]
		var type = action["type"]
		var old_content = action["content"]
		
		match type:
			"save":
				_write_project_file(path, old_content)
				_add_activity("↩️", "Restored: " + path.get_file(), HiruConst.C_SAVE)
			"create":
				_delete_project_file(path)
				_add_activity("↩️", "Deleted created file: " + path.get_file(), HiruConst.C_DELETE)
			"delete":
				_write_project_file(path, old_content)
				_add_activity("↩️", "Restored deleted file: " + path.get_file(), HiruConst.C_SAVE)
	
	var fs = EditorInterface.get_resource_filesystem() if Engine.is_editor_hint() else null
	if fs: fs.scan()
	
	_undo_stack.clear()
	_add_msg("system", "✅ Undo complete.")

func _on_new_conversation():
	_save_current_conversation()
	_on_clear()

func _save_current_conversation():
	if chat_history.size() == 0:
		return
	
	# Generate title from first user message
	var title = _current_conversation_title
	if title == "":
		for msg in chat_history:
			if msg["role"] == "user":
				title = msg["content"].left(40).strip_edges()
				if title.length() >= 38:
					title += "..."
				break
		if title == "":
			title = "Conversation %d" % (_conversation_list.size() + 1)
	
	_conversation_list.append({
		"title": title,
		"messages": chat_history.duplicate(true),
		"timestamp": Time.get_datetime_string_from_system()
	})
	_current_conversation_title = ""
	_refresh_history_list()

func _refresh_history_list():
	if not history_tab: return
	var list = history_tab.find_child("ConversationList", true, false)
	if not list: return
	for c in list.get_children(): c.queue_free()
	
	for i in range(_conversation_list.size() - 1, -1, -1):
		var conv = _conversation_list[i]
		var card = PanelContainer.new()
		var st = HiruUtils.sb(HiruConst.C_PANEL, 6, true, HiruConst.C_BORDER)
		st.content_margin_top = 6
		st.content_margin_bottom = 6
		card.add_theme_stylebox_override("panel", st)
		
		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 8)
		
		var ic = Label.new()
		ic.text = "💬"
		ic.add_theme_font_size_override("font_size", 12)
		hbox.add_child(ic)
		
		var text_vbox = VBoxContainer.new()
		text_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var t = Label.new()
		t.text = conv["title"]
		t.add_theme_font_size_override("font_size", 11)
		t.add_theme_color_override("font_color", Color.WHITE)
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		text_vbox.add_child(t)
		var ts = Label.new()
		ts.text = conv.get("timestamp", "")
		ts.add_theme_font_size_override("font_size", 9)
		ts.add_theme_color_override("font_color", HiruConst.C_TEXT_DIM)
		text_vbox.add_child(ts)
		hbox.add_child(text_vbox)
		
		var load_btn = Button.new()
		load_btn.text = "↩"
		load_btn.flat = true
		load_btn.add_theme_color_override("font_color", HiruConst.C_ACCENT_ALT)
		load_btn.tooltip_text = "Load this conversation"
		load_btn.pressed.connect(_load_conversation.bind(i))
		load_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		hbox.add_child(load_btn)
		
		card.add_child(hbox)
		list.add_child(card)

func _load_conversation(idx: int):
	if idx < 0 or idx >= _conversation_list.size(): return
	var conv = _conversation_list[idx]
	
	# Clear current
	for child in chat_container.get_children():
		child.queue_free()
	
	chat_history = conv["messages"].duplicate(true)
	_current_conversation_title = conv["title"]
	_tree_sent = true
	
	# Replay messages visually
	for msg in chat_history:
		if msg["role"] == "user":
			_add_msg("user", msg["content"].left(200))
		elif msg["role"] == "assistant":
			_add_msg("ai", HiruUtils.clean_display_text(msg["content"]))
	
	tabs.current_tab = 0
	_update_nav_active(0)
	_add_msg("system", "📜 Loaded conversation: " + conv["title"])

func _on_nav_btn_pressed(idx: int):
	tabs.current_tab = idx
	_update_nav_active(idx)

func _on_command_suggestion_pressed(cmd: String):
	if cmd.begins_with("/"):
		input_field.text = cmd + " "
		input_field.set_caret_column(input_field.text.length())
		_cmd_popup.hide()
	else:
		_send(cmd)
		_cmd_popup.hide()

func _on_file_mention_pressed(path: String, query: String):
	_attach_file_to_context(path)
	var cur_text = input_field.text
	var words = cur_text.split(" ")
	for i in words.size():
		if words[i].begins_with("@") and query in words[i].to_lower():
			words.remove_at(i)
			break
	input_field.text = " ".join(words)
	input_field.set_caret_column(input_field.text.length())
	_file_suggestion_popup.hide()

func _on_thought_chip_pressed(content_panel: Control, chip: Button, dur_str: String):
	content_panel.visible = !content_panel.visible
	if content_panel.visible:
		chip.text = "  🧠 Thought for %s  ▾" % dur_str
	else:
		chip.text = "  🧠 Thought for %s  ▸" % dur_str
	_scroll_bottom(true)


func _on_editor_script_changed(_script: Script):
	if not _auto_attach_enabled or not _script: return
	
	var current_time = Time.get_ticks_msec()
	if current_time - _last_auto_attach_time < AUTO_ATTACH_COOLDOWN:
		return
		
	var path = _script.resource_path
	if path == "" or not path.begins_with("res://"): return
	if path in _context_files: return
	
	# Auto-attach current file to context bar (Cursor style)
	_attach_file_to_context(path)
	_last_auto_attach_time = current_time

func _should_include_tree(text: String) -> bool:
	var t = text.to_lower()
	var keywords = [
		"fix", "benerin", "script", "file", "folder", "projek", "project",
		"buat", "create", "scene", ".gd", ".tscn", "/", "error", "bug",
		"refactor", "tambah", "add", "struktur", "structure", "scan",
		"edit", "ubah", "ganti", "player", "pemain", "logic", "coding", "code"
	]
	for k in keywords:
		if k in t: return true
	return false

func _backup_file(path: String):
	if not FileAccess.file_exists(path): return
	
	var backup_dir := "res://.hiruai_backup/"
	if not DirAccess.dir_exists_absolute(backup_dir):
		DirAccess.make_dir_absolute(backup_dir)
		
	var content = FileAccess.get_file_as_string(path)
	var timestamp = Time.get_datetime_string_from_system().replace(":", "-")
	var backup_path = backup_dir + path.get_file() + "." + timestamp + ".bak"
	
	var file = FileAccess.open(backup_path, FileAccess.WRITE)
	if file:
		file.store_string(content)
		file.close()
		_add_activity("🛡️", "Backup created: " + backup_path.get_file(), Color("#94a3b8"))