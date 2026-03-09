@tool
extends RefCounted
## Project scanner with full file reading capability.
## Uses Godot's DirAccess/FileAccess — no Python needed.

const SCAN_EXTENSIONS := ["gd", "tscn", "tres", "cfg"]
const IGNORE_DIRS := [".godot", ".import", ".git", "addons"]
const MAX_FILE_CONTENT := 8000
const MAX_AUTO_READ_FILES := 10
const MAX_AUTO_READ_SIZE := 3000


static func scan_project() -> String:
	var files: Array[String] = []
	_scan_dir("res://", files, 0)
	var lines: Array[String] = ["Project Files (%d):" % files.size()]
	for f in files:
		lines.append("  • " + f)
	return "\n".join(lines)


static func get_full_context() -> String:
	"""Returns file tree + contents of small .gd/.tscn files for AI context."""
	var files: Array[String] = []
	_scan_dir("res://", files, 0)

	var parts: Array[String] = []
	parts.append("=== PROJECT STRUCTURE ===")
	parts.append(get_file_tree())
	parts.append("")
	parts.append("=== FILE CONTENTS (auto-included) ===")

	# Sort by size (smallest first) so AI reads small files
	var file_data: Array[Dictionary] = []
	for f in files:
		var ext = f.get_extension()
		if ext == "gd" or ext == "tscn":
			var content = read_file(f)
			if content.length() <= MAX_AUTO_READ_SIZE and not content.begins_with("Error:"):
				file_data.append({"path": f, "content": content, "size": content.length()})

	file_data.sort_custom(func(a, b): return a["size"] < b["size"])

	var included := 0
	for fd in file_data:
		if included >= MAX_AUTO_READ_FILES:
			break
		parts.append("--- %s ---" % fd["path"])
		parts.append(fd["content"])
		parts.append("")
		included += 1

	if included < file_data.size():
		parts.append("(%d more files not shown — use [READ:path] to read them)" % (file_data.size() - included))

	return "\n".join(parts)


static func _scan_dir(path: String, files: Array[String], depth: int):
	if depth > 6:
		return
	var dir = DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
		var full_path = path.path_join(file_name)
		if dir.current_is_dir():
			if file_name not in IGNORE_DIRS:
				_scan_dir(full_path, files, depth + 1)
		else:
			var ext = file_name.get_extension()
			if ext in SCAN_EXTENSIONS:
				files.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()


static func read_file(path: String) -> String:
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return "Error: Cannot read " + path
	var content = file.get_as_text()
	file.close()
	
	var lines = content.split("\n")
	var total_lines = lines.size()
	var max_lines = 150
	
	# Add line numbers for AI reference
	var numbered: Array[String] = []
	var limit = mini(total_lines, max_lines)
	for i in limit:
		numbered.append("%3d | %s" % [i + 1, lines[i]])
	
	var result = "\n".join(numbered)
	if total_lines > max_lines:
		result += "\n... (showing %d/%d lines. Use [READ_LINES:path:start-end] if you need more)" % [max_lines, total_lines]
	else:
		result += "\n(%d lines total)" % total_lines
	return result


static func read_file_lines(path: String, start_line: int, end_line: int) -> String:
	"""Read specific line range from a file (1-indexed, inclusive)."""
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return "Error: Cannot read " + path
	var content = file.get_as_text()
	file.close()
	
	var lines = content.split("\n")
	var total_lines = lines.size()
	start_line = clampi(start_line, 1, total_lines)
	end_line = clampi(end_line, start_line, total_lines)
	
	var numbered: Array[String] = []
	for i in range(start_line - 1, end_line):
		numbered.append("%3d | %s" % [i + 1, lines[i]])
	
	var result = "\n".join(numbered)
	result += "\n(showing lines %d-%d of %d)" % [start_line, end_line, total_lines]
	return result


static func get_file_tree() -> String:
	var lines: Array[String] = ["📂 Project/"]
	_tree_dir("res://", lines, "", 0)
	return "\n".join(lines)


static func _tree_dir(path: String, lines: Array[String], prefix: String, depth: int):
	if depth > 4:
		return
	var dir = DirAccess.open(path)
	if not dir:
		return
	var entries: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname = dir.get_next()
	while fname != "":
		if not fname.begins_with(".") and fname not in IGNORE_DIRS:
			entries.append({"name": fname, "is_dir": dir.current_is_dir()})
		fname = dir.get_next()
	dir.list_dir_end()
	entries.sort_custom(func(a, b): return a["name"] < b["name"])
	for i in entries.size():
		var entry = entries[i]
		var is_last = (i == entries.size() - 1)
		var connector = "└── " if is_last else "├── "
		var icon = "📁 " if entry["is_dir"] else _file_icon(entry["name"])
		lines.append(prefix + connector + icon + entry["name"])
		if entry["is_dir"]:
			var new_prefix = prefix + ("    " if is_last else "│   ")
			_tree_dir(path.path_join(entry["name"]), lines, new_prefix, depth + 1)


static func _file_icon(fname: String) -> String:
	if fname.ends_with(".gd"): return "📜 "
	if fname.ends_with(".tscn"): return "🎬 "
	if fname.ends_with(".tres"): return "🎨 "
	if fname.ends_with(".png") or fname.ends_with(".jpg"): return "🖼️ "
	if fname.ends_with(".wav") or fname.ends_with(".ogg"): return "🔊 "
	return "📄 "


static func search_text(query: String) -> String:
	"""Cari custom keyword/nama fungsi di sebuah file .gd"""
	var files: Array[String] = []
	_scan_dir("res://", files, 0)
	
	var results: Array[String] = []
	var rx = RegEx.new()
	rx.compile("(?i)" + query) # Case insensitive search
	
	for f in files:
		if not f.ends_with(".gd"):
			continue
			
		var file = FileAccess.open(f, FileAccess.READ)
		if not file: continue
		var content = file.get_as_text()
		file.close()
		
		var lines = content.split("\n")
		var found_in_file := false
		for i in lines.size():
			if rx.search(lines[i]):
				if not found_in_file:
					results.append("File: " + f)
					found_in_file = true
				results.append("  Line %d: %s" % [i + 1, lines[i].strip_edges()])
				
		if results.size() > 50:
			results.append("... (Too many results, refine your search keyword)")
			break
			
	if results.is_empty():
		return "No results found for '" + query + "'"
	return "\n".join(results)


static func read_godot_log() -> String:
	"""Read the latest Godot editor log for error information."""
	# Try multiple log locations
	var log_paths := [
		"user://logs/godot.log",
		"user://logs/editor.log"
	]
	for log_path in log_paths:
		var file = FileAccess.open(log_path, FileAccess.READ)
		if file:
			var content = file.get_as_text()
			file.close()
			# Get last 3000 chars (most recent logs)
			if content.length() > 3000:
				content = content.substr(content.length() - 3000)
			# Filter for errors and warnings
			var lines = content.split("\n")
			var error_lines: Array[String] = []
			for line in lines:
				var lower = line.to_lower()
				if "error" in lower or "warning" in lower or "script_error" in lower or "failed" in lower or "exception" in lower:
					error_lines.append(line)
			if error_lines.size() > 0:
				return "Recent errors/warnings:\n" + "\n".join(error_lines.slice(-20))
			return "No recent errors found in log."
	return "Could not read Godot log file."
