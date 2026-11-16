## Autoload added by the Godot MCP Bridge plugin. While the game runs from the
## editor binary it serves screenshots, input and inspection on localhost.
## In exported games (no "editor" feature) it removes itself immediately.
extends Node

const BridgeServer := preload("../core/bridge_server.gd")
const RuntimeCommands := preload("runtime_commands.gd")
const PORT := 6511

var _server: RefCounted


func _ready() -> void:
	var args := OS.get_cmdline_args()
	if not OS.has_feature("editor") or args.has("--script") or args.has("-s"):
		queue_free()
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	var log_capture := BridgeServer.create_log_capture(get_script().resource_path.get_base_dir().get_base_dir().path_join("core"))
	_server = BridgeServer.new({
		"kind": "game",
		"project_path": ProjectSettings.globalize_path("res://"),
		"pid": OS.get_process_id(),
	}, log_capture)
	_server.register(RuntimeCommands.new(self, log_capture))
	var err: Error = _server.start(PORT)
	if err != OK:
		push_warning("Godot MCP Bridge: couldn't listen on 127.0.0.1:%d (another game instance running?)" % PORT)
		_server = null
		queue_free()


func _process(_delta: float) -> void:
	if _server:
		_server.poll()


func _exit_tree() -> void:
	if _server:
		_server.stop()
