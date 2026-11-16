## Minimal localhost WebSocket JSON-RPC server shared by the editor plugin and
## the runtime autoload. The owner must call poll() every frame.
##
## Wire format (text frames, JSON):
##   request:  {"id": 1, "method": "editor.status", "params": {...}}
##   response: {"id": 1, "result": ...} or {"id": 1, "error": {"message": "..."}}
## The first request on a connection must be {"method": "auth", "params": {"token": ...}}.
@tool
extends RefCounted

const Token := preload("token.gd")
const ERROR_KEY := "__mcp_error"

var _tcp := TCPServer.new()
var _clients: Array[Dictionary] = []
var _commands := {}
## Callables don't keep RefCounted handlers alive, so hold them here.
var _handlers: Array[Object] = []
var _info: Dictionary
var _log: Object


func _init(info: Dictionary, log_capture: Object = null) -> void:
	_info = info
	_log = log_capture
	Token.get_or_create()


## Handlers take a params Dictionary and return any JSON-safe value, or
## fail("...") to report an error. They may be coroutines.
static func fail(message: String) -> Dictionary:
	return {ERROR_KEY: message}


## Registers a Logger-based output capture on Godot 4.5+, or returns null.
static func create_log_capture(core_dir: String) -> Object:
	if not ClassDB.class_exists("Logger"):
		return null
	var capture = load(core_dir.path_join("log_capture.gd")).new()
	OS.call("add_logger", capture)
	return capture


## handler must implement get_commands() -> Dictionary of method name -> Callable.
func register(handler: Object) -> void:
	_handlers.append(handler)
	_commands.merge(handler.get_commands(), true)


func start(port: int) -> Error:
	return _tcp.listen(port, "127.0.0.1")


func is_listening() -> bool:
	return _tcp.is_listening()


func stop() -> void:
	for client in _clients:
		client.ws.close()
	_clients.clear()
	_tcp.stop()


func poll() -> void:
	while _tcp.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 4 * 1024 * 1024
		ws.outbound_buffer_size = 16 * 1024 * 1024
		ws.max_queued_packets = 4096
		if ws.accept_stream(_tcp.take_connection()) == OK:
			_clients.append({"ws": ws, "authed": false})
	for client in _clients.duplicate():
		var ws: WebSocketPeer = client.ws
		ws.poll()
		match ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				while ws.get_available_packet_count() > 0:
					_on_text(client, ws.get_packet().get_string_from_utf8())
			WebSocketPeer.STATE_CLOSED:
				_clients.erase(client)


func _on_text(client: Dictionary, text: String) -> void:
	var msg = JSON.parse_string(text)
	if typeof(msg) != TYPE_DICTIONARY:
		_send(client, {"id": null, "error": {"message": "Invalid JSON request"}})
		return
	var id = msg.get("id")
	var method := str(msg.get("method", ""))
	var params = msg.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}

	if not client.authed:
		var expected := Token.read_current()
		if method == "auth" and not expected.is_empty() and str(params.get("token", "")) == expected:
			client.authed = true
			_send(client, {"id": id, "result": _info})
		else:
			_send(client, {"id": id, "error": {"message": "Unauthorized: token mismatch. Is this %s running a different project?" % _info.get("kind", "instance")}})
			client.ws.close(4001, "unauthorized")
		return

	_dispatch(client, id, method, params)


func _dispatch(client: Dictionary, id: Variant, method: String, params: Dictionary) -> void:
	if not _commands.has(method):
		_send(client, {"id": id, "error": {"message": "Unknown method: %s" % method}})
		return
	var mark: int = _log.last_id() if _log else 0
	var result = await (_commands[method] as Callable).call(params)
	if typeof(result) == TYPE_DICTIONARY and result.has(ERROR_KEY):
		_send(client, {"id": id, "error": {"message": result[ERROR_KEY]}})
	elif result == null:
		# GDScript aborts a function on a runtime error and returns null.
		var detail := ""
		if _log:
			detail = "\n".join(_log.errors_since(mark))
		_send(client, {"id": id, "error": {"message": "%s failed inside Godot.%s" % [method, ("\n" + detail) if detail else " Check the Godot output for errors."]}})
	else:
		_send(client, {"id": id, "result": result})


func _send(client: Dictionary, payload: Dictionary) -> void:
	var ws: WebSocketPeer = client.ws
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(payload))
