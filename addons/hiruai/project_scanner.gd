@tool
extends RefCounted
class_name HiruProjectScanner
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

	file_data.sort_custom(_sort_by_size)

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
	
	var length = file.get_length()
	const MAX_SIZE = 51200 # 50KB
	
	var content = ""
	var is_truncated = false
	
	if length > MAX_SIZE:
		content = file.get_buffer(MAX_SIZE).get_string_from_utf8()
		is_truncated = true
	else:
		content = file.get_as_text()
	file.close()
	
	var lines = content.split("\n")
	var total_lines = lines.size()
	var max_lines = 300
	
	# Add line numbers for AI reference
	var numbered: Array[String] = []
	var limit = mini(total_lines, max_lines)
	for i in limit:
		numbered.append("%3d | %s" % [i + 1, lines[i]])
	
	var result = "\n".join(numbered)
	if is_truncated:
		result += "\n⚠️ [FILE TRUNCATED: File exceeds 50KB limit]"
	elif total_lines > max_lines:
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
	entries.sort_custom(_sort_by_name)
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
	"""Cari custom keyword/nama fungsi atau NAMA FILE."""
	var files: Array[String] = []
	_scan_dir("res://", files, 0)
	
	var results: Array[String] = []
	var q_lower = query.to_lower()
	
	for f in files:
		var f_lower = f.to_lower()
		var content := ""
		var matches_path = q_lower in f_lower
		
		# Always try to search path first (Smart Search)
		if matches_path:
			results.append("File Match (Path): " + f)
		
		# Then search content if it's a script
		if f.ends_with(".gd"):
			var file = FileAccess.open(f, FileAccess.READ)
			if file:
				content = file.get_as_text()
				file.close()
				
				var lines = content.split("\n")
				var found_in_content := false
				for i in lines.size():
					if q_lower in lines[i].to_lower():
						if not found_in_content and not matches_path:
							results.append("File Match (Content): " + f)
							found_in_content = true
						results.append("  Line %d: %s" % [i + 1, lines[i].strip_edges()])
		
		if results.size() > 60:
			results.append("... (Too many results, refine your keyword)")
			break
			
	if results.is_empty():
		return "No results found for '" + query + "'. Try different keywords."
	return "\n".join(results)


static func get_log_size() -> int:
	"""Returns the current size of the Godot log file."""
	var log_paths := ["user://logs/godot.log", "user://logs/editor.log"]
	for lp in log_paths:
		if FileAccess.file_exists(lp):
			var f = FileAccess.open(lp, FileAccess.READ)
			if f:
				var s = f.get_length()
				f.close()
				return s
	return 0


static func read_godot_log(since_offset: int = 0) -> String:
	"""Read and parse the Godot log. If since_offset > 0, only reads NEW entries."""
	var log_paths := ["user://logs/godot.log", "user://logs/editor.log"]
	
	var rx_stack := RegEx.new()
	rx_stack.compile("((?:res://)?[a-zA-Z0-9_\\-\\./\\\\]+\\.(?:gd|tscn|tres)):(\\d+)")

	for log_path in log_paths:
		if not FileAccess.file_exists(log_path): continue
		
		var file = FileAccess.open(log_path, FileAccess.READ)
		if file:
			var total_size = file.get_length()
			
			if since_offset > 0 and since_offset < total_size:
				file.seek(since_offset)
			elif total_size > 8000:
				file.seek(total_size - 8000)
				
			var content = file.get_as_text()
			file.close()
			
			if content.strip_edges() == "":
				return "No new entries found in log."
			
			var lines = content.split("\n")
			var error_context: Array[String] = []
			var detected_targets: Array[String] = []
			
			# Scan for errors
			for i in range(lines.size()):
				var line = lines[i]
				var lower = line.to_lower()
				
				if "error" in lower or "warning" in lower or "failed" in lower:
					error_context.append("LOG: " + line)
					
					# Look for stack trace in nearby lines
					for j in range(maxi(0, i-5), mini(lines.size(), i+5)):
						var m = rx_stack.search(lines[j])
						if m:
							var target = m.get_string(1) + ":" + m.get_string(2)
							if target not in detected_targets:
								detected_targets.append(target)
								error_context.append("📍 TARGET DETECTED: " + target)
					
					if error_context.size() > 40: break # Increased limit for better context
					
			if not error_context.is_empty():
				var result = "=== LOG ANALYSIS (OFFSET: %d) ===\n" % since_offset + "\n".join(error_context)
				if not detected_targets.is_empty():
					result += "\n\n💡 I found specific code locations in the stack trace."
				return result
				
			return "No critical errors found in the most recent log entries."
	return "Could not access Godot log files."


static func scan_scene(path: String) -> String:
	"""Parses a .tscn file and returns a human-readable node tree."""
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return "Error: Cannot read scene " + path
		
	var content = file.get_as_text()
	file.close()
	
	var lines = content.split("\n")
	var node_list: Array[Dictionary] = []
	
	# Regex to match [node name="..." type="..." parent="..."]
	var rx_node = RegEx.new()
	rx_node.compile('\\[node name="([^"]+)"(?: type="([^"]+)")?(?: parent="([^"]+)")?(?: instance=ExtResource\\("([^"]+)"\\))?')
	
	# Regex to match [ext_resource path="..." type="..." id="..."]
	var rx_ext = RegEx.new()
	rx_ext.compile('\\[ext_resource path="([^"]+)" type="([^"]+)" id="([^"]+)"\\]')
	
	var ext_resources = {}
	
	for line in lines:
		var m_ext = rx_ext.search(line)
		if m_ext:
			ext_resources[m_ext.get_string(3)] = {
				"path": m_ext.get_string(1),
				"type": m_ext.get_string(2)
			}
			continue
			
		var m = rx_node.search(line)
		if m:
			var node_name = m.get_string(1)
			var node_type = m.get_string(2)
			var node_parent = m.get_string(3)
			var instance_id = m.get_string(4)
			
			if node_type == "" and instance_id != "":
				if ext_resources.has(instance_id):
					node_type = "Instance:" + ext_resources[instance_id]["path"].get_file()
				else:
					node_type = "Inherited/Instanced"
			
			node_list.append({
				"name": node_name,
				"type": node_type if node_type != "" else "Node",
				"parent": node_parent
			})
			
	if node_list.is_empty():
		return "No nodes found in scene (or format not recognized)."

	# Build a hierarchy string
	var result_lines: Array[String] = ["🎬 Scene Hierarchy: " + path]
	
	# Group by parent to help visualization
	# The first node usually has no parent line in tscn or parent="."
	for i in node_list.size():
		var n = node_list[i]
		var depth = 0
		if n["parent"] != "":
			if n["parent"] == ".":
				depth = 1
			else:
				var parent_parts = n["parent"].split("/")
				depth = parent_parts.size() + 1
		
		var indent = "  ".repeat(depth)
		var prefix = "└── " if i == node_list.size() -1 else "├── "
		result_lines.append(indent + prefix + n["name"] + " (" + n["type"] + ")")
		
	# --- Signals & Connections ---
	var rx_conn = RegEx.new()
	rx_conn.compile('\\[connection signal="([^"]+)" from="([^"]+)" to="([^"]+)" method="([^"]+)"\\]')
	
	var connections: Array[String] = []
	for line in lines:
		var m = rx_conn.search(line)
		if m:
			connections.append("  🔗 %s.%s -> %s.%s()" % [m.get_string(2), m.get_string(1), m.get_string(3), m.get_string(4)])
	
	if connections.size() > 0:
		result_lines.append("\n📡 Signal Connections:")
		result_lines.append_array(connections)
		
	return "\n".join(result_lines)


static func _sort_by_size(a: Dictionary, b: Dictionary) -> bool:
	return a["size"] < b["size"]


static func _sort_by_name(a: Dictionary, b: Dictionary) -> bool:
	return a["name"] < b["name"]