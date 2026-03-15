@tool
extends Node
## NVIDIA API client with STREAMING support.
## Delivers AI tokens in real-time via SSE (Server-Sent Events).
## No Python backend needed.

signal chat_completed(text: String, finish_reason: String)
signal chat_error(error_message: String)
signal token_received(token: String) # NEW: fires per-token for streaming UI
signal stream_started() # NEW: fires when first token arrives
signal stream_finished(full_text: String, finish_reason: String) # NEW: fires when stream is done

const PROVIDERS = {
	"NVIDIA": "https://integrate.api.nvidia.com/v1",
	"Puter": "https://api.puter.com/puterai/openai/v1",
	"Google": "https://generativelanguage.googleapis.com/v1beta/openai"
}
const CONFIG_PATH := "user://godot_ai_agent.cfg"

const PROVIDER_MODELS = {
	"NVIDIA": {
		"GPT-OSS 120B (High)": "openai/gpt-oss-120b",
		"Kimi K2 Instruct (Thinking)": "moonshotai/kimi-k2-instruct",
		"Llama 3.1 405B (High)": "meta/llama-3.1-405b-instruct",
		"Llama 3.1 70B": "meta/llama-3.1-70b-instruct",
		"GLM-4.7 (High)": "z-ai/glm4.7",
		"GLM-5 (High)": "z-ai/glm5",
		"MiniMax m2.5": "minimaxai/minimax-m2.5"
	},
	"Puter": {
		"Claude Opus 4.6 (High)": "claude-opus-4-6",
		"Claude Sonnet 4.6": "claude-sonnet-4-6",
		"Claude 3.5 Sonnet": "claude-3-5-sonnet-20241022",
		"Gemini 3 Pro Preview (Thinking)": "gemini-3-pro-preview",
		"GPT-4o (Thinking)": "gpt-4o",
		"GPT-4o Mini": "gpt-4o-mini",
	},
	"Google": {
		"Gemini 3.1 Flash Lite": "gemini-3.1-flash-lite-preview"
	}
}

var nvidia_key: String = ""
var puter_key: String = ""
var google_key: String = ""
var api_key: String = "" # Current active key
var current_model: String = "openai/gpt-oss-120b"
var current_provider: String = "NVIDIA"
var _http: HTTPRequest
var _stream_http: HTTPClient # For SSE streaming
var _is_busy := false
var _is_streaming := false
var _cancel_requested := false
var _accumulated_text := ""
var _stream_byte_buffer := PackedByteArray()
var _last_finish_reason := "stop"

# Retry config
const MAX_RETRIES := 2
const RETRY_DELAY := 2.0
var _retry_count := 0
var _last_messages: Array = []


func _ready():
	_http = HTTPRequest.new()
	_http.timeout = 120
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	load_config()


func load_config():
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		nvidia_key = cfg.get_value("api", "nvidia_key", "")
		puter_key = cfg.get_value("api", "puter_key", "")
		google_key = cfg.get_value("api", "google_key", "")
		current_model = cfg.get_value("api", "model", "openai/gpt-oss-120b")
		current_provider = cfg.get_value("api", "provider", "NVIDIA")
		_update_active_key()


func _update_active_key():
	if current_provider == "NVIDIA":
		api_key = nvidia_key
	elif current_provider == "Google":
		api_key = google_key
	else:
		api_key = puter_key


func save_settings(n_key: String, p_key: String, g_key: String, model: String, provider: String = "NVIDIA"):
	nvidia_key = n_key
	puter_key = p_key
	google_key = g_key
	current_model = model
	current_provider = provider
	_update_active_key()
	
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("api", "nvidia_key", nvidia_key)
	cfg.set_value("api", "puter_key", puter_key)
	cfg.set_value("api", "google_key", google_key)
	cfg.set_value("api", "model", model)
	cfg.set_value("api", "provider", provider)
	cfg.save(CONFIG_PATH)


func is_busy() -> bool:
	return _is_busy


func cancel_request():
	if _is_busy:
		_cancel_requested = true
		if _is_streaming and _stream_http:
			_stream_http.close()
		_http.cancel_request()
		_is_busy = false
		_is_streaming = false


func send_chat(messages: Array):
	if _is_busy:
		chat_error.emit("Please wait for the current request to finish.")
		return
	if api_key.is_empty():
		chat_error.emit("API key not set. Click ⚙️ Settings to add your NVIDIA API key.")
		return

	_is_busy = true
	_cancel_requested = false
	_retry_count = 0
	_last_messages = messages.duplicate(true)
	_accumulated_text = ""

	# No extra warning suffix to avoid AI obsessive acknowledgment
	var msgs_copy = messages.duplicate(true)

	# Try streaming first, fallback to non-streaming
	_send_streaming(msgs_copy)


func _send_streaming(messages: Array):
	"""Use HTTPClient for SSE streaming."""
	_is_streaming = true
	_stream_byte_buffer.clear()
	_accumulated_text = ""

	# Run streaming in a coroutine so we don't block
	_do_stream_request(messages)


func _do_stream_request(messages: Array):
	"""Perform the actual streaming HTTP request."""
	_stream_http = HTTPClient.new()
	
	var base_url = PROVIDERS.get(current_provider, PROVIDERS["NVIDIA"])
	var url_parts = base_url.replace("https://", "").split("/", false, 1)
	var host = url_parts[0]
	var path_prefix = "/" + url_parts[1] if url_parts.size() > 1 else ""
	
	var err = _stream_http.connect_to_host(host, 443, TLSOptions.client())
	if err != OK:
		_fallback_non_streaming(messages)
		return

	# Wait for connection
	var timeout_counter := 0
	while _stream_http.get_status() == HTTPClient.STATUS_CONNECTING or _stream_http.get_status() == HTTPClient.STATUS_RESOLVING:
		_stream_http.poll()
		await get_tree().create_timer(0.1).timeout
		timeout_counter += 1
		if timeout_counter > 150 or _cancel_requested: # 15 second timeout
			_stream_http.close()
			if _cancel_requested:
				_is_busy = false
				_is_streaming = false
				return
			_fallback_non_streaming(messages)
			return

	if _stream_http.get_status() != HTTPClient.STATUS_CONNECTED:
		_fallback_non_streaming(messages)
		return

	var headers := PackedStringArray([
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json",
		"Accept: text/event-stream"
	])

	var body := JSON.stringify({
		"model": current_model,
		"messages": messages,
		"temperature": 0.4,
		"max_tokens": 8192,
		"stream": true
	})

	err = _stream_http.request(HTTPClient.METHOD_POST, path_prefix + "/chat/completions", headers, body)
	if err != OK:
		_fallback_non_streaming(messages)
		return

	# Wait for response headers
	timeout_counter = 0
	while _stream_http.get_status() == HTTPClient.STATUS_REQUESTING:
		_stream_http.poll()
		await get_tree().create_timer(0.05).timeout
		timeout_counter += 1
		if timeout_counter > 600 or _cancel_requested: # 30 second timeout
			_stream_http.close()
			if _cancel_requested:
				_is_busy = false
				_is_streaming = false
				return
			_fallback_non_streaming(messages)
			return

	if not _stream_http.has_response():
		_fallback_non_streaming(messages)
		return

	var response_code = _stream_http.get_response_code()
	if response_code != 200:
		# Read error body
		var error_body := PackedByteArray()
		while _stream_http.get_status() == HTTPClient.STATUS_BODY:
			_stream_http.poll()
			var chunk = _stream_http.read_response_body_chunk()
			if chunk.size() > 0:
				error_body.append_array(chunk)
			else:
				await get_tree().create_timer(0.05).timeout

		var error_text = error_body.get_string_from_utf8()
		_stream_http.close()

		# Try retry with exponential backoff
		if _retry_count < MAX_RETRIES:
			var backoff = pow(2, _retry_count)
			_retry_count += 1
			await get_tree().create_timer(backoff).timeout
			if not _cancel_requested:
				_do_stream_request(messages)
			return

		_is_busy = false
		_is_streaming = false
		_parse_error_response(response_code, error_text)
		if _stream_http: _stream_http.close()
		return

	# Stream is live! Emit start signal
	stream_started.emit()

	# Read SSE stream
	var last_chunk_time := Time.get_ticks_msec()
	while _stream_http.get_status() == HTTPClient.STATUS_BODY:
		if _cancel_requested:
			_stream_http.close()
			_is_busy = false
			_is_streaming = false
			return

		_stream_http.poll()
		var chunk = _stream_http.read_response_body_chunk()
		if chunk.size() > 0:
			_stream_byte_buffer.append_array(chunk)
			_process_sse_byte_buffer()
			last_chunk_time = Time.get_ticks_msec()
		else:
			# Idle check: if we are in BODY status but no data for 20 seconds, assume finished or stalled
			if Time.get_ticks_msec() - last_chunk_time > 20000:
				print("[HiruAI] Stream idle for 20s, concluding.")
				break
			await get_tree().create_timer(0.01).timeout

	# Done streaming
	_stream_http.close()
	_is_streaming = false
	_is_busy = false

	# CRITICAL FIX: Process any remaining data in the buffer that didn't end with a newline
	if _stream_byte_buffer.size() > 0:
		_process_sse_byte_buffer(true) # Pass true to force process last line

	if _accumulated_text.strip_edges().is_empty():
		if _retry_count < MAX_RETRIES:
			_retry_count += 1
			_is_busy = true
			await get_tree().create_timer(RETRY_DELAY).timeout
			if not _cancel_requested:
				_do_stream_request(messages)
			return
		chat_error.emit("Empty response from AI after streaming.")
		return

	# ─── Finalize and Cleanup ───
	if _accumulated_text.contains("[THOUGHT]") and not _accumulated_text.contains("[/THOUGHT]"):
		_accumulated_text += "\n[/THOUGHT]"
		token_received.emit("\n[/THOUGHT]")
		
	stream_finished.emit(_accumulated_text, _last_finish_reason)
	chat_completed.emit(_accumulated_text, _last_finish_reason)


func _process_sse_byte_buffer(force_last_line: bool = false):
	"""Parse SSE data lines from the byte buffer (UTF-8 safe)."""
	while true:
		var newline_idx := -1
		for i in range(_stream_byte_buffer.size()):
			if _stream_byte_buffer[i] == 10: # '\n' character
				newline_idx = i
				break
				
		if newline_idx == -1:
			if force_last_line and _stream_byte_buffer.size() > 0:
				newline_idx = _stream_byte_buffer.size()
			else:
				break
				
		# Extract line up to newline (excluding newline)
		var line_bytes := _stream_byte_buffer.slice(0, newline_idx)
		
		# Remove the processed bytes including newline from buffer
		var remove_count = newline_idx
		if _stream_byte_buffer.size() > newline_idx:
			remove_count += 1
			
		# Efficiently remove bytes
		if remove_count > 0:
			_stream_byte_buffer = _stream_byte_buffer.slice(remove_count, _stream_byte_buffer.size())
			
		var line := line_bytes.get_string_from_utf8().strip_edges()
		
		if line == "" or line == "data: [DONE]":
			continue
			
		if not line.begins_with("data: "):
			continue

		var json_str = line.substr(6)
		var json = JSON.new()
		if json.parse(json_str) != OK:
			continue

		var data = json.data
		if data is Dictionary and data.has("choices") and data["choices"].size() > 0:
			var choice = data["choices"][0]
			var delta = choice.get("delta", {})
			
			if choice.has("finish_reason") and choice["finish_reason"] != null:
				_last_finish_reason = choice["finish_reason"]
				
			if delta is Dictionary:
				var content = delta.get("content", "")
				var reasoning = delta.get("reasoning_content", "")
				if reasoning == "": reasoning = delta.get("thought", "")
				
				# 1. Handle explicit reasoning field (e.g. DeepSeek R1, Kimi K2)
				if reasoning != "" and reasoning is String:
					if not _accumulated_text.contains("[THOUGHT]"):
						_accumulated_text += "[THOUGHT]\n"
						token_received.emit("[THOUGHT]\n")
					_accumulated_text += reasoning
					token_received.emit(reasoning)
				
				# 2. Handle main content
				if content != "" and content is String:
					# If we started reasoning but haven't closed it, close it before content
					if _accumulated_text.contains("[THOUGHT]") and not _accumulated_text.contains("[/THOUGHT]"):
						_accumulated_text += "\n[/THOUGHT]\n"
						token_received.emit("\n[/THOUGHT]\n")
					_accumulated_text += content
					token_received.emit(content)


func _fallback_non_streaming(messages: Array):
	"""Fallback to standard non-streaming request."""
	_is_streaming = false
	print("[HiruAI] Streaming unavailable, falling back to standard request...")

	var headers := PackedStringArray([
		"Authorization: Bearer " + api_key,
		"Content-Type: application/json"
	])

	var body := JSON.stringify({
		"model": current_model,
		"messages": messages,
		"temperature": 0.4,
		"max_tokens": 8192,
		"stream": false
	})

	var base_url = PROVIDERS.get(current_provider, PROVIDERS["NVIDIA"])
	var api_endpoint = base_url + "/chat/completions"

	var request_err := _http.request(api_endpoint, headers, HTTPClient.METHOD_POST, body)
	if request_err != OK:
		_is_busy = false
		chat_error.emit("Failed to connect. Error code: %d" % request_err)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
	_is_busy = false

	if result != HTTPRequest.RESULT_SUCCESS:
		# Retry logic for non-streaming with exponential backoff
		if _retry_count < MAX_RETRIES:
			var backoff = pow(2, _retry_count)
			_retry_count += 1
			_is_busy = true
			await get_tree().create_timer(backoff).timeout
			if not _cancel_requested:
				_fallback_non_streaming(_last_messages)
			return

		var error_msg := "Connection failed."
		match result:
			HTTPRequest.RESULT_CANT_CONNECT:
				error_msg = "Cannot connect to NVIDIA API. Check your internet."
			HTTPRequest.RESULT_TIMEOUT:
				error_msg = "Request timed out (120s). Server took too long."
			HTTPRequest.RESULT_CANT_RESOLVE:
				error_msg = "Cannot resolve API hostname."
			_:
				error_msg = "Connection error (code: %d)" % result
		chat_error.emit(error_msg)
		return

	var response_text := body.get_string_from_utf8()

	if code != 200:
		_parse_error_response(code, response_text)
		return

	var json := JSON.new()
	if json.parse(response_text) != OK:
		chat_error.emit("Failed to parse API response.")
		return

	var data = json.data
	if data.has("choices") and data["choices"] is Array and data["choices"].size() > 0:
		var choice = data["choices"][0]
		if not choice is Dictionary:
			chat_error.emit("Unexpected response format: choice is not a dictionary.")
			return
			
		var message = choice.get("message")
		if not message is Dictionary:
			chat_error.emit("Unexpected response format: message is missing or invalid.")
			return
			
		var content_raw = message.get("content")
		var content: String = content_raw if content_raw is String else ""
		
		var reasoning_raw = message.get("reasoning_content")
		if reasoning_raw == null: reasoning_raw = message.get("thought")
		var reasoning: String = reasoning_raw if reasoning_raw is String else ""
		
		var full_res = ""
		if reasoning != "":
			full_res += "[THOUGHT]\n" + reasoning + "\n[/THOUGHT]\n"
		full_res += content
		
		if full_res.is_empty():
			chat_error.emit("Empty response from AI.")
		else:
			chat_completed.emit(full_res, "stop")
	else:
		chat_error.emit("Unexpected response format from API.")


func _parse_error_response(code: int, response_text: String):
	"""Parse and emit a user-friendly error from API error responses."""
	var json := JSON.new()
	if json.parse(response_text) == OK and json.data is Dictionary:
		var data = json.data
		if data.has("error"):
			var err_data = data["error"]
			if err_data is Dictionary:
				chat_error.emit("API Error (%d): %s" % [code, err_data.get("message", "Unknown")])
			else:
				chat_error.emit("API Error (%d): %s" % [code, str(err_data)])
			return
	chat_error.emit("API returned status %d" % code)
