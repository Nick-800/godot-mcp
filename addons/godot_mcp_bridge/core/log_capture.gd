## Ring buffer of engine output (prints, warnings, errors). Only loaded on
## Godot 4.5+, where the Logger class exists. Logger callbacks can arrive from
## any thread, so all access goes through a mutex.
@tool
extends Logger

const MAX_ENTRIES := 2000
const ERROR_KINDS := ["error", "warning", "script_error", "shader_error"]

var _mutex := Mutex.new()
var _entries: Array[Dictionary] = []
var _next_id := 1


func _log_message(message: String, error: bool) -> void:
	_push("stderr" if error else "stdout", message.strip_edges(false, true), "", 0)


func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	var kind: String = ERROR_KINDS[error_type] if error_type < ERROR_KINDS.size() else "error"
	var text := rationale if not rationale.is_empty() else code
	if not rationale.is_empty() and not code.is_empty() and code != rationale:
		text = "%s (%s)" % [rationale, code]
	_push(kind, text, file, line)


func _push(kind: String, text: String, file: String, line: int) -> void:
	_mutex.lock()
	_entries.append({"id": _next_id, "type": kind, "text": text, "file": file, "line": line})
	_next_id += 1
	if _entries.size() > MAX_ENTRIES:
		_entries.pop_front()
	_mutex.unlock()


func last_id() -> int:
	_mutex.lock()
	var id := _next_id - 1
	_mutex.unlock()
	return id


func since(since_id: int, errors_only := false, limit := 200) -> Dictionary:
	_mutex.lock()
	var out: Array[Dictionary] = []
	for entry in _entries:
		if entry.id <= since_id:
			continue
		if errors_only and entry.type in ["stdout", "stderr"]:
			continue
		out.append(entry)
	var last := _next_id - 1
	_mutex.unlock()
	var truncated := out.size() > limit
	if truncated:
		out = out.slice(out.size() - limit)
	return {"entries": out, "last_id": last, "truncated": truncated}


func errors_since(since_id: int) -> Array:
	return since(since_id, true, 50).entries.map(func(e): return "%s:%d %s" % [e.file, e.line, e.text] if e.file else e.text)
