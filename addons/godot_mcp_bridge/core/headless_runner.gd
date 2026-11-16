## Runs one project command without an editor:
##   godot --headless --path <project> --script res://addons/godot_mcp_bridge/core/headless_runner.gd -- <method> <json params>
## Prints a single line "MCP_RESULT:<json>" with {"result": ...} or {"error": {...}}.
extends SceneTree

const ProjectCommands := preload("project_commands.gd")
const Bridge := preload("bridge_server.gd")


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		_finish({"error": {"message": "Usage: -- <method> [json params]"}})
		return
	var params = JSON.parse_string(args[1]) if args.size() > 1 else {}
	if typeof(params) != TYPE_DICTIONARY:
		params = {}
	var addon_dir := (get_script() as Script).resource_path.get_base_dir().get_base_dir()
	var handler := ProjectCommands.new(null, addon_dir)
	var commands := handler.get_commands()
	if not commands.has(args[0]):
		_finish({"error": {"message": "Unknown headless method: %s" % args[0]}})
		return
	var result = commands[args[0]].call(params)
	if typeof(result) == TYPE_DICTIONARY and result.has(Bridge.ERROR_KEY):
		_finish({"error": {"message": result[Bridge.ERROR_KEY]}})
	else:
		_finish({"result": result})


func _finish(payload: Dictionary) -> void:
	print("MCP_RESULT:" + JSON.stringify(payload))
	quit()
