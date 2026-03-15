@tool
extends Node
class_name HiruValidator

static func check_syntax_error(code: String) -> String:
	var script = GDScript.new()
	script.source_code = code
	var err = script.reload()
	if err != OK:
		match err:
			ERR_PARSE_ERROR: return "Parse Error (Check for typos, missing colons, or invalid keywords)"
			ERR_COMPILATION_FAILED: return "Compilation Failed (Indentation or syntax error)"
			_: return "Syntax Error (Godot Error Code: %d)" % err
	return ""

static func find_missing_preloads(saves: Array[Dictionary]) -> Array[Dictionary]:
	var missing: Array[Dictionary] = []
	var all_save_paths: Array[String] = []
	for s in saves: all_save_paths.append(s["path"])
	var rx = RegEx.new()
	rx.compile('preload\\s*\\(\\s*"([^"]+)"\\s*\\)')
	for s in saves:
		var spath = s["path"]
		for m in rx.search_all(s["content"]):
			var dep_path: String = m.get_string(1)
			if not dep_path.begins_with("res://"): dep_path = "res://" + dep_path.trim_prefix("/")
			if FileAccess.file_exists(dep_path): continue
			if dep_path in all_save_paths: continue
			var already_added = false
			for mis in missing:
				if mis["source"] == spath and mis["missing"] == dep_path: already_added = true
			if not already_added: missing.append({"source": spath, "missing": dep_path})
	return missing


static func validate_replace_scope(r_data: Dictionary, original_lines: PackedStringArray) -> Dictionary:
	var s_line: int = int(r_data["start"])
	var e_line: int = int(r_data["end"])
	var start_i: int = clampi(s_line - 1, 0, original_lines.size() - 1)
	var end_i: int = clampi(e_line - 1, start_i, original_lines.size() - 1)
	var range_size: int = end_i - start_i + 1
	var content_str: String = str(r_data["content"])
	var replacement_lines: PackedStringArray = content_str.split("\n")
	var replacement_size: int = replacement_lines.size()
	var max_allowed: int = maxi(range_size * 2, range_size + 20)
	if replacement_size > max_allowed and range_size > 5:
		var msg: String = "SCOPE CREEP: Replacing %d lines (L%d-%d) but providing %d new lines. This suggests the AI is rewriting more code than necessary." % [range_size, s_line, e_line, replacement_size]
		return {"ok": false, "warning": msg}
	return {"ok": true, "warning": ""}


static func validate_replace_context(r_data: Dictionary, original_lines: PackedStringArray) -> Dictionary:
	var s_line: int = int(r_data["start"])
	var e_line: int = int(r_data["end"])
	var start_i: int = clampi(s_line - 1, 0, original_lines.size() - 1)
	var end_i: int = clampi(e_line - 1, start_i, original_lines.size() - 1)
	var content_str: String = str(r_data["content"])
	var replacement_lines: PackedStringArray = content_str.split("\n")
	if replacement_lines.is_empty():
		return {"ok": false, "warning": "Empty replacement content"}
	if start_i > 0:
		var line_before: String = original_lines[start_i - 1]
		var before_tabs: int = _count_leading_tabs(line_before)
		var first_replacement: String = replacement_lines[0]
		var first_tabs: int = _count_leading_tabs(first_replacement)
		var first_stripped: String = first_replacement.strip_edges()
		if absi(first_tabs - before_tabs) > 2 and not first_stripped.begins_with("func ") and not first_stripped.begins_with("class "):
			var msg: String = "INDENTATION MISMATCH: Line before replacement has %d tabs, but replacement starts with %d tabs." % [before_tabs, first_tabs]
			return {"ok": false, "warning": msg}
	if end_i + 1 < original_lines.size():
		var line_after: String = original_lines[end_i + 1]
		var after_tabs: int = _count_leading_tabs(line_after)
		var last_replacement: String = replacement_lines[replacement_lines.size() - 1]
		var last_tabs: int = _count_leading_tabs(last_replacement)
		var after_stripped: String = line_after.strip_edges()
		if absi(last_tabs - after_tabs) > 2 and not after_stripped.begins_with("func ") and not after_stripped.begins_with("class ") and after_stripped != "":
			var msg: String = "INDENTATION MISMATCH at end: Line after replacement has %d tabs, but replacement ends with %d tabs." % [after_tabs, last_tabs]
			return {"ok": false, "warning": msg}
	return {"ok": true, "warning": ""}


static func _count_leading_tabs(line: String) -> int:
	var count: int = 0
	for i in line.length():
		if line[i] == "\t":
			count += 1
		else:
			break
	return count
