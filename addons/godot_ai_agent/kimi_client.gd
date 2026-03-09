@tool
extends Node
## Kimi K2.5 API client — calls NVIDIA API directly from GDScript.
## No Python backend needed.

signal chat_completed(response_text: String)
signal chat_error(error_message: String)

const API_URL := "https://integrate.api.nvidia.com/v1/chat/completions"
const MODEL := "moonshotai/kimi-k2-instruct"
const CONFIG_PATH := "user://godot_ai_agent.cfg"

var api_key: String = ""
var _http: HTTPRequest
var _is_busy := false


func _ready():
	_http = HTTPRequest.new()
	_http.timeout = 120 # 2 minutes
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	load_config()


func load_config():
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		api_key = cfg.get_value("api", "nvidia_key", "")


func save_api_key(key: String):
	api_key = key
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("api", "nvidia_key", key)
	cfg.save(CONFIG_PATH)


func is_busy() -> bool:
	return _is_busy


func cancel_request():
	if _is_busy:
		_http.cancel_request()
		_is_busy = false


func send_chat(messages: Array):
	if _is_busy:
		chat_error.emit("Please wait for the current request to finish.")
		return
	if api_key.is_empty():
		chat_error.emit("API key not set. Click ⚙️ Settings to add your NVIDIA API key.")
		return

	_is_busy = true

	var msgs_copy = messages.duplicate(true)
	if msgs_copy.size() > 0 and msgs_copy.back().get("role") == "user":
		var content = msgs_copy.back().get("content", "")
		msgs_copy.back()["content"] = content + "\n\n[SYSTEM WARNING TO AI: CRITICAL! DO NOT MINIFY CODE. You MUST use newlines (ENTER) after EVERY statement. Do NOT write multiple statements on the same line. If you ignore this, the GDScript will break!]"

	var headers := PackedStringArray([
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json"
	])

	var body := JSON.stringify({
		"model": MODEL,
		"messages": msgs_copy,
		"temperature": 0.4,
		"max_tokens": 4096,
		"stream": false
	})

	var err := _http.request(API_URL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_is_busy = false
		chat_error.emit("Failed to connect. Error code: %d" % err)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
	_is_busy = false

	if result != HTTPRequest.RESULT_SUCCESS:
		var error_msg := "Connection failed."
		match result:
			HTTPRequest.RESULT_CANT_CONNECT:
				error_msg = "Cannot connect to NVIDIA API. Check your internet."
			HTTPRequest.RESULT_TIMEOUT:
				error_msg = "Request timed out (300s). Server took too long to respond."
			HTTPRequest.RESULT_CANT_RESOLVE:
				error_msg = "Cannot resolve API hostname."
			_:
				error_msg = "Connection error (code: %d)" % result
		chat_error.emit(error_msg)
		return

	var response_text := body.get_string_from_utf8()

	if code != 200:
		var json := JSON.new()
		if json.parse(response_text) == OK and json.data is Dictionary:
			var data: Dictionary = json.data
			if data.has("error"):
				var err_data = data["error"]
				if err_data is Dictionary:
					chat_error.emit("API Error: " + err_data.get("message", "Unknown"))
				else:
					chat_error.emit("API Error: " + str(err_data))
				return
		chat_error.emit("API returned status %d" % code)
		return

	var json := JSON.new()
	if json.parse(response_text) != OK:
		chat_error.emit("Failed to parse API response.")
		return

	var data: Dictionary = json.data
	if data.has("choices") and data["choices"] is Array and data["choices"].size() > 0:
		var choice: Dictionary = data["choices"][0]
		var message: Dictionary = choice.get("message", {})
		var content: String = message.get("content", "")
		if content.is_empty():
			chat_error.emit("Empty response from AI.")
		else:
			chat_completed.emit(content)
	else:
		chat_error.emit("Unexpected response format from API.")
