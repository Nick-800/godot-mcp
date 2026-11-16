## Editor side of the Godot MCP Bridge: serves live editor commands on
## 127.0.0.1:6510 and registers the runtime autoload for games run from here.
@tool
extends EditorPlugin

const BridgeServer := preload("core/bridge_server.gd")
const EditorCommands := preload("editor/editor_commands.gd")
const ProjectCommands := preload("core/project_commands.gd")
const PORT := 6510

var _server: RefCounted
var _log: Object


func _addon_dir() -> String:
	return get_script().resource_path.get_base_dir()


func _enable_plugin() -> void:
	add_autoload_singleton(ProjectCommands.BRIDGE_AUTOLOAD, _addon_dir().path_join("runtime/runtime_bridge.gd"))


func _disable_plugin() -> void:
	remove_autoload_singleton(ProjectCommands.BRIDGE_AUTOLOAD)


func _enter_tree() -> void:
	var config := ConfigFile.new()
	config.load(_addon_dir().path_join("plugin.cfg"))
	_log = BridgeServer.create_log_capture(_addon_dir().path_join("core"))
	_server = BridgeServer.new({
		"kind": "editor",
		"project_path": ProjectSettings.globalize_path("res://"),
		"bridge_version": config.get_value("plugin", "version", "?"),
		"godot_version": Engine.get_version_info().string,
		"pid": OS.get_process_id(),
	}, _log)
	_server.register(EditorCommands.new(self, _log))
	_server.register(ProjectCommands.new(self, _addon_dir()))
	var err: Error = _server.start(PORT)
	if err != OK:
		push_warning("Godot MCP Bridge: couldn't listen on 127.0.0.1:%d (is another editor using it?)" % PORT)
		_server = null
	else:
		print("Godot MCP Bridge listening on 127.0.0.1:%d" % PORT)


func _exit_tree() -> void:
	if _server:
		_server.stop()
		_server = null
	if _log:
		OS.call("remove_logger", _log)
		_log = null


func _process(_delta: float) -> void:
	if _server:
		_server.poll()
