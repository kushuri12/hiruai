@tool
extends Node
class_name HiruProtocol

static func sanitize_path(path: String) -> String:
	path = path.strip_edges()
	# Only allow res://
	if not path.begins_with("res://"):
		if path.begins_with("/"): path = "res://" + path.substr(1)
		else: path = "res://" + path
	
	# Block path traversal
	if ".." in path or "//" in path.replace("res://", ""):
		return ""
		
	# Validate extension
	var valid_ext = ["gd", "tscn", "tres", "cfg", "json", "txt", "md"]
	var ext = path.get_extension().to_lower()
	if ext not in valid_ext and ext != "":
		return ""
		
	return path

static func extract_searches(text: String) -> Array[String]:
	var results: Array[String] = []
	var rx = RegEx.new()
	rx.compile("\\[SEARCH:([^\\]]+)\\]|<search:([^>]+)>|<search>\\s*(.*?)\\s*</search>")
	for m in rx.search_all(text):
		var k = ""
		for i in range(1, 4):
			if m.get_string(i) != "":
				k = m.get_string(i).strip_edges()
				break
		if k != "" and k not in results:
			results.append(k)
	return results

static func extract_reads(text: String) -> Array[String]:
	var paths: Array[String] = []
	var rx = RegEx.new()
	# Support [READ:path], <read:path>, <read>path</read>, and legacy parameter tags
	rx.compile("\\[READ:([^\\]]+)\\]|<read:([^>]+)>|<read>\\s*(.*?)\\s*</read>|<parameter=file>\\s*(.*?)\\s*</parameter>")
	for m in rx.search_all(text):
		var p = ""
		for i in range(1, 5):
			if m.get_string(i) != "":
				p = m.get_string(i)
				break
		
		p = p.replace(" ", "").replace("\n", "").replace("\r", "").strip_edges()
		p = sanitize_path(p)
		if p != "" and p not in paths: paths.append(p)
	return paths

static func extract_read_lines(text: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var rx = RegEx.new()
	# Support [READ_LINES:path:start-end], <read_lines:path:start-end>, and <read_lines path="..." start="..." end="..."/>
	rx.compile("(?:\\[READ_LINES:| <read_lines\\s*path=\")\\s*(.+?)\\s*(?::| \"\\s*start=\")\\s*(\\d+)\\s*(?:-| \"\\s*end=\")\\s*(\\d+)\\s*(?:\\]|\"\\/>)")
	
	var rx2 = RegEx.new()
	rx2.compile("<read_lines:([^:]+):(\\d+)-(\\d+)>")
	
	for m in rx.search_all(text):
		var p = sanitize_path(m.get_string(1).replace(" ", ""))
		if p == "": continue
		results.append({
			"path": p,
			"start": int(m.get_string(2)),
			"end": int(m.get_string(3))
		})
	for m in rx2.search_all(text):
		var p = sanitize_path(m.get_string(1).replace(" ", ""))
		if p == "": continue
		results.append({
			"path": p,
			"start": int(m.get_string(2)),
			"end": int(m.get_string(3))
		})
	return results

static func extract_replaces(text: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var patterns = [
		"\\[REPLACE:\\s*(.+?)\\s*:\\s*(\\d+)\\s*-\\s*(\\d+)\\s*\\][\\s\\S]*?```(?:[a-zA-Z0-9_ \\t]*\\n)?([\\s\\S]*?)```",
		"<replace\\s*path=\"([^\"]+)\"\\s*start=\"(\\d+)\"\\s*end=\"(\\d+)\">\\s*(?:```[\\s\\S]*?```|([\\s\\S]*?))\\s*<\\/replace>",
		"<replace:([^:]+):(\\d+)-(\\d+)>[\\s\\S]*?```(?:[a-zA-Z0-9_ \\t]*\\n)?([\\s\\S]*?)```"
	]
	
	for p_str in patterns:
		var rx = RegEx.new()
		rx.compile(p_str)
		for m in rx.search_all(text):
			var p = sanitize_path(m.get_string(1).strip_edges())
			if p == "": continue
			
			var content = ""
			if m.get_group_count() >= 4:
				content = m.get_string(4)
			
			if content.strip_edges() == "": continue
			
			results.append({
				"path": p,
				"start": int(m.get_string(2)),
				"end": int(m.get_string(3)),
				"content": clean_code_block(content)
			})
			
	# Priority 2: Loose [REPLACE:] without backticks
	var rx_loose = RegEx.new()
	rx_loose.compile("\\[REPLACE:\\s*(.+?)\\s*:\\s*(\\d+)\\s*-\\s*(\\d+)\\s*\\]")
	var loose_matches = rx_loose.search_all(text)
	for i in loose_matches.size():
		var p = sanitize_path(loose_matches[i].get_string(1).strip_edges())
		if p == "": continue
		
		# Avoid double counting if already captured by backtick pattern
		var already = false
		for r in results:
			if r["path"] == p and r["start"] == int(loose_matches[i].get_string(2)):
				already = true; break
		if already: continue
		
		var start_pos = loose_matches[i].get_end()
		var end_pos = text.length()
		
		# Look for next protocol tag or end of string
		var terminator_tags = ["[THOUGHT", "[SAVE:", "[REPLACE:", "[/REPLACE]", "[READ:", "[SEARCH:", "```"]
		for tag in terminator_tags:
			var found = text.find(tag, start_pos)
			if found != -1 and found < end_pos:
				end_pos = found
				
		var block_content = text.substr(start_pos, end_pos - start_pos).strip_edges()
		if block_content != "" and block_content.length() > 5:
			results.append({
				"path": p,
				"start": int(loose_matches[i].get_string(2)),
				"end": int(loose_matches[i].get_string(3)),
				"content": clean_code_block(block_content)
			})
			
	return results

static func clean_code_block(text: String) -> String:
	"""Removes line number prefixes like '  49 | ' WITHOUT touching code indentation.
	
	CRITICAL: strip_edges() removes ALL leading whitespace including TABS.
	GDScript uses tabs for indentation — strip_edges() on the full block = instant crash.
	Rule: ONLY strip leading blank newlines (never spaces/tabs) and trailing whitespace."""
	var result := text
	# Strip only leading blank newlines — tabs at line start belong to code
	while result.length() > 0 and (result.left(1) == "\n" or result.left(1) == "\r"):
		result = result.substr(1)
	# Strip trailing whitespace only (right side)
	result = result.strip_edges(false, true)
	# Remove line-number prefix format: '  49 | ' — spaces+digits+pipe+ONE space
	# Stopping at exactly one literal space means the next char (a tab) is preserved
	var rx := RegEx.new()
	rx.compile("(?m)^ *\\d+ *[|:] ")
	result = rx.sub(result, "", true)
	return result

static func extract_scene_scans(text: String) -> Array[String]:
	var results: Array[String] = []
	var rx = RegEx.new()
	rx.compile("\\[SCENE_SCAN:([^\\]]+)\\]|<scene_scan:([^>]+)>|<scene_scan>\\s*(.*?)\\s*</scene_scan>")
	for m in rx.search_all(text):
		var p = ""
		for i in range(1, 4):
			if m.get_string(i) != "":
				p = sanitize_path(m.get_string(i).strip_edges())
				break
		if p != "" and p not in results: results.append(p)
	return results

static func extract_thoughts(text: String, allow_partial: bool = false) -> String:
	var patterns = [
		"(?is)\\[THOUGHT:?\\s*.*?\\]+([\\s\\S]*?)\\[/THOUGHT\\]",
		"(?is)<thought>([\\s\\S]*?)</thought>",
		"(?is)<think>([\\s\\S]*?)</think>"
	]
	if allow_partial:
		patterns.append("(?is)\\[THOUGHT:?\\s*.*?\\]+([\\s\\S]*)$")
		patterns.append("(?is)<thought>([\\s\\S]*)$")
		patterns.append("(?is)<think>([\\s\\S]*)$")
	for p in patterns:
		var rx = RegEx.new()
		rx.compile(p)
		var m = rx.search(text)
		if m and m.get_string(1).strip_edges() != "":
			return m.get_string(1).strip_edges()
	if allow_partial and "[THOUGHT]" in text:
		var start = text.find("[THOUGHT]") + 9
		var slice = text.substr(start).strip_edges()
		# Clean up stray bracket that might stay from streaming or double tags
		if slice.begins_with("]"): slice = slice.substr(1).strip_edges()
		return slice
	if allow_partial and "<thought>" in text:
		var start = text.find("<thought>") + 9
		return text.substr(start).strip_edges()
	return ""

static func extract_saves(text: String) -> Array[Dictionary]:
	var saves: Array[Dictionary] = []
	var claimed_blocks: Array[String] = []
	
	# Priority 1: Strict Tags (Bracket or XML)
	var save_patterns = [
		"\\[SAVE:([^\\]]+)\\][\\s\\S]*?```(?:[a-zA-Z0-9_ \\t]*\\n)?([\\s\\S]*?)```",
		"<save\\s*path=\"([^\"]+)\">\\s*```(?:[a-zA-Z0-9_ \\t]*\\n)?([\\s\\S]*?)```\\s*<\\/save>",
		"<save\\s*path=\"([^\"]+)\">([\\s\\S]*?)<\\/save>",
		"\\[SAVE:([^\\]]+)\\]([\\s\\S]*?)\\[(?:/SAVE|END_SAVE)\\]",
		"<save:([^>]+)>\\s*```(?:[a-zA-Z0-9_ \\t]*\\n)?([\\s\\S]*?)```"
	]
	
	for pattern in save_patterns:
		var rx = RegEx.new()
		rx.compile(pattern)
		for m in rx.search_all(text):
			var path = sanitize_path(m.get_string(1).strip_edges())
			if path == "": continue
			var content = clean_code_block(m.get_string(2))
			if content == "" and m.get_group_count() >= 3:
				content = clean_code_block(m.get_string(3))
			
			if content != "" and not _is_path_already_saved(saves, path):
				saves.append({
					"path": path,
					"content": clean_extraneous_gdscript(content) if path.ends_with(".gd") else content
				})
				claimed_blocks.append(content)

	# Priority 2: Annotated Code Blocks (e.g. res://path.gd followed by ```)
	var rx_code = RegEx.new()
	rx_code.compile("```(?:[a-zA-Z0-9_ \\t]*\\n)?([\\s\\S]*?)```")
	var code_matches = rx_code.search_all(text)
	for m_code in code_matches:
		var raw_content = m_code.get_string(1)
		var is_claimed = false
		for cb in claimed_blocks:
			if raw_content.strip_edges() == cb.strip_edges():
				is_claimed = true; break
		if is_claimed: continue
		
		var start_pos = m_code.get_start()
		var check_start = maxi(0, start_pos - 150)
		var pre_text = text.substr(check_start, start_pos - check_start)
		
		var rx_path = RegEx.new()
		rx_path.compile("(res://[a-zA-Z0-9_\\-\\./\\\\]+\\.[a-zA-Z0-9_]+)")
		var path_matches = rx_path.search_all(pre_text)
		
		var found_path = ""
		if path_matches.size() > 0:
			found_path = path_matches[path_matches.size() - 1].get_string(1).strip_edges()
		else:
			var first_line = raw_content.split("\n")[0].strip_edges()
			if first_line.begins_with("#") and "res://" in first_line:
				var c_rx = RegEx.new()
				c_rx.compile("(res://[a-zA-Z0-9_\\-\\./\\\\]+\\.[a-zA-?A-Z0-9_]+)")
				var cm = c_rx.search(first_line)
				if cm: found_path = cm.get_string(1).strip_edges()
		
		if found_path != "" and not _is_path_already_saved(saves, found_path):
			found_path = sanitize_path(found_path)
			if found_path != "":
				var cleaned := clean_code_block(raw_content)
				saves.append({
					"path": found_path,
					"content": clean_extraneous_gdscript(cleaned) if found_path.ends_with(".gd") else cleaned
				})
				claimed_blocks.append(raw_content)

	# Priority 3: Loose [SAVE:] without backticks (stops at next protocol tag)
	var rx_loose = RegEx.new()
	rx_loose.compile("\\[SAVE:([^\\]]+)\\]")
	var loose_matches = rx_loose.search_all(text)
	for i in loose_matches.size():
		var path = sanitize_path(loose_matches[i].get_string(1).strip_edges())
		if path == "" or _is_path_already_saved(saves, path): continue
		
		var start_pos = loose_matches[i].get_end()
		var end_pos = text.length()
		
		var terminator_tags = [
			"[THOUGHT", "[PLAN", "[PROGRESS", "[SAVE:", "[READ:", "[READ_LINES:", 
			"[SEARCH:", "[SCENE_SCAN:", "[DELETE:", "[RUN_GAME:", "[RUN_CHECK]", "[REPLACE:",
			"[/SAVE]", "[END_SAVE]", "<thought", "<save", "<read", "<search", "<delete"
		]
		
		if i + 1 < loose_matches.size(): 
			end_pos = loose_matches[i + 1].get_start()
		
		var next_tag_pos = -1
		for tag in terminator_tags:
			var found = text.find(tag, start_pos)
			if found != -1 and found < end_pos:
				if next_tag_pos == -1 or found < next_tag_pos:
					next_tag_pos = found
		
		if next_tag_pos != -1:
			end_pos = next_tag_pos
			
		var block_content = text.substr(start_pos, end_pos - start_pos).strip_edges()
		if block_content != "":
			var cleaned := strip_code_boilerplate(clean_code_block(block_content))
			saves.append({
				"path": path,
				"content": clean_extraneous_gdscript(cleaned) if path.ends_with(".gd") else cleaned
			})
			
	return saves

static func _is_path_already_saved(saves: Array[Dictionary], path: String) -> bool:
	for s in saves:
		if s["path"] == path: return true
	return false

static func clean_extraneous_gdscript(code: String) -> String:
	var result = code.strip_edges()
	if result.begins_with("gdscript"):
		var after = result.substr(8).strip_edges()
		if after.begins_with("extends ") or after.begins_with("class_name ") or after.begins_with("@") or after.begins_with("func ") or after.begins_with("var ") or after.begins_with("const ") or after.begins_with("signal ") or after.begins_with("#"):
			return after
	return result

static func strip_code_boilerplate(block: String) -> String:
	"""Strips markdown/language label boilerplate before actual code begins.
	Only skips lines BEFORE the first real GDScript/TSCN keyword is found.
	Once we're in code, ALL lines (including indented ones) are kept as-is."""
	var lines = block.split("\n")
	var result = []
	var in_code = false
	for line in lines:
		if not in_code:
			# Check the stripped version to detect keywords, but keep original line intact
			var ln = line.strip_edges()
			var test_ln = ln
			if test_ln.begins_with("gdscript"): test_ln = test_ln.substr(8).strip_edges()
			if test_ln.begins_with("extends ") or test_ln.begins_with("class_name ") \
				or test_ln.begins_with("@") or test_ln.begins_with("func ") \
				or test_ln.begins_with("var ") or test_ln.begins_with("const ") \
				or test_ln.begins_with("signal ") or test_ln.begins_with("#") \
				or test_ln.begins_with("[gd_scene ") or test_ln.begins_with("[gd_resource "):
					in_code = true
					# Strip 'gdscript' label if it was fused onto the first keyword
					if test_ln != ln:
						line = line.replace("gdscript", "").strip_edges()
		# Once in code: append the original line unchanged (tabs intact)
		if in_code:
			result.append(line)
	if result.is_empty(): return block.strip_edges()
	return "\n".join(result).strip_edges()

static func extract_deletes(text: String) -> Array[String]:
	var paths: Array[String] = []
	var rx = RegEx.new()
	rx.compile("\\[DELETE:([^\\]]+)\\]|<delete:([^>]+)>|<delete>\\s*(.*?)\\s*</delete>")
	for m in rx.search_all(text):
		var p = ""
		for i in range(1, 4):
			if m.get_string(i) != "":
				p = sanitize_path(m.get_string(i).strip_edges())
				break
		if p != "" and p not in paths: paths.append(p)
	return paths

static func extract_run_game(text: String) -> String:
	var rx = RegEx.new()
	rx.compile("\\[RUN_GAME:(main|current)\\]")
	var m = rx.search(text)
	if m: return m.get_string(1)
	return ""

static func extract_run_check(text: String) -> bool:
	return "[RUN_CHECK]" in text or "<run_check/>" in text or "<run_check>" in text

static func extract_plan(text: String) -> String:
	var rx = RegEx.new()
	rx.compile("(?is)\\[PLAN\\]([\\s\\S]*?)\\[/PLAN\\]")
	var m = rx.search(text)
	if m: return m.get_string(1).strip_edges()
	return ""

static func extract_progress(text: String) -> String:
	var rx = RegEx.new()
	rx.compile("(?is)\\[PROGRESS\\]([\\s\\S]*?)\\[/PROGRESS\\]")
	var m = rx.search(text)
	if m: return m.get_string(1).strip_edges()
	return ""

static func extract_proactive_flags(text: String) -> Array[String]:
	var results: Array[String] = []
	var rx = RegEx.new()
	rx.compile("(?i)(?:⚠️\\s*)?PROACTIVE FLAG:?\\s*(.*)")
	for m in rx.search_all(text):
		results.append(m.get_string(1).strip_edges())
	return results
static func extract_scan_tree(text: String) -> bool:
	return "[SCAN_TREE]" in text or "<scan_tree/>" in text or "<scan_tree>" in text

static func extract_diffs(text: String) -> Array[String]:
	var paths: Array[String] = []
	var rx = RegEx.new()
	rx.compile("\\[DIFF:([^\\]]+)\\]|<diff:([^>]+)>")
	for m in rx.search_all(text):
		var p = m.get_string(1) if m.get_string(1) != "" else m.get_string(2)
		p = sanitize_path(p)
		if p != "" and p not in paths: paths.append(p)
	return paths