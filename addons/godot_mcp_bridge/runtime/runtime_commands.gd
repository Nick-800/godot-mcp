## Commands served by the running game. Node paths are absolute
## ("/root/Main/Player") or relative to the current scene ("Player").
extends RefCounted

const Codec := preload("../core/variant_codec.gd")
const Bridge := preload("../core/bridge_server.gd")
const ProjectCommands := preload("../core/project_commands.gd")

var _host: Node
var _log: Object
## Size of the last screenshot sent, so mouse coordinates can be given in
## screenshot pixels.
var _last_shot_size := Vector2.ZERO


func _init(host: Node, log_capture: Object) -> void:
	_host = host
	_log = log_capture


func get_commands() -> Dictionary:
	return {
		"game.status": _status,
		"game.screenshot": _screenshot,
		"game.scene_tree": _scene_tree,
		"game.get_properties": _get_properties,
		"game.set_properties": _set_properties,
		"game.call": _call,
		"game.eval": _eval,
		"game.input": _input,
		"game.get_log": _get_log,
		"game.quit": _quit,
	}


func _tree() -> SceneTree:
	return _host.get_tree()


func _find(path: Variant) -> Node:
	var p := str(path) if path != null else ""
	var tree := _tree()
	if p.is_empty() or p == ".":
		return tree.current_scene if tree.current_scene else tree.root
	if p.begins_with("/"):
		return tree.root.get_node_or_null(NodePath(p))
	if tree.current_scene:
		var node := tree.current_scene.get_node_or_null(NodePath(p))
		if node:
			return node
	return tree.root.get_node_or_null(NodePath(p))


func _status(_params: Dictionary) -> Variant:
	var tree := _tree()
	return {
		"scene": tree.current_scene.scene_file_path if tree.current_scene else null,
		"current_scene_path": str(tree.current_scene.get_path()) if tree.current_scene else null,
		"paused": tree.paused,
		"fps": Engine.get_frames_per_second(),
		"frame": Engine.get_process_frames(),
		"time_scale": Engine.time_scale,
		"window_size": Codec.encode(_host.get_window().size),
		"log_capture": _log != null,
	}


func _screenshot(params: Dictionary) -> Variant:
	if DisplayServer.get_name() == "headless":
		return Bridge.fail("The game is running headless, so there is nothing to capture")
	await RenderingServer.frame_post_draw
	var image := _host.get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return Bridge.fail("Couldn't capture the game viewport (headless display?)")
	var payload := Codec.image_payload(image, int(params.get("max_width", 1280)))
	_last_shot_size = Vector2(payload.width, payload.height)
	return payload


func _scene_tree(params: Dictionary) -> Variant:
	var node := _find(params.get("node", "/root"))
	if node == null:
		return Bridge.fail("No node at '%s'" % params.get("node"))
	return {"tree": _describe(node, int(params.get("max_depth", 8)), params.get("properties", []))}


func _describe(node: Node, depth: int, props: Array) -> Dictionary:
	var info := {"name": str(node.name), "type": node.get_class(), "path": str(node.get_path())}
	var script: Script = node.get_script()
	if script:
		info["script"] = script.resource_path
	if not node.scene_file_path.is_empty():
		info["scene"] = node.scene_file_path
	for prop in props:
		if Codec.has_property(node, prop):
			info[prop] = Codec.encode(node.get_indexed(prop))
	var children := []
	for child in node.get_children():
		if child == _host:
			continue
		if depth <= 0:
			info["children_hidden"] = node.get_child_count()
			break
		children.append(_describe(child, depth - 1, props))
	if not children.is_empty():
		info["children"] = children
	return info


func _get_properties(params: Dictionary) -> Variant:
	var node := _find(params.get("node"))
	if node == null:
		return Bridge.fail("No node at '%s'" % params.get("node"))
	return {
		"path": str(node.get_path()),
		"type": node.get_class(),
		"properties": Codec.describe_properties(node, params.get("names", []), bool(params.get("changed_only", true))),
	}


func _set_properties(params: Dictionary) -> Variant:
	var node := _find(params.get("node"))
	if node == null:
		return Bridge.fail("No node at '%s'" % params.get("node"))
	var errors := []
	var now := {}
	var properties: Dictionary = params.get("properties", {})
	for prop in properties:
		if not Codec.has_property(node, prop):
			errors.append("%s has no property '%s'" % [node.get_class(), prop])
			continue
		var value = Codec.decode(properties[prop], Codec.property_type(node, prop))
		if not Codec.last_error.is_empty():
			errors.append("%s: %s" % [prop, Codec.last_error])
			continue
		node.set_indexed(prop, value)
		now[prop] = Codec.encode(node.get_indexed(prop))
	return {"path": str(node.get_path()), "values": now, "errors": errors}


func _call(params: Dictionary) -> Variant:
	var node := _find(params.get("node"))
	if node == null:
		return Bridge.fail("No node at '%s'" % params.get("node"))
	var method := str(params.get("method", ""))
	if not node.has_method(method):
		return Bridge.fail("%s has no method '%s'" % [node.get_path(), method])
	var args: Array = params.get("args", []).map(func(a): return Codec.decode(a))
	return {"value": Codec.encode(node.callv(method, args))}


func _eval(params: Dictionary) -> Variant:
	var base := _find(params.get("node", ""))
	var expression := Expression.new()
	var err := expression.parse(str(params.get("expression", "")), ["tree", "root", "scene"])
	if err != OK:
		return Bridge.fail("Parse error: %s" % expression.get_error_text())
	var tree := _tree()
	var value = expression.execute([tree, tree.root, tree.current_scene], base, false)
	if expression.has_execute_failed():
		return Bridge.fail("Execution failed: %s" % expression.get_error_text())
	return {"value": Codec.encode(value)}


func _get_log(params: Dictionary) -> Variant:
	if _log == null:
		return Bridge.fail("Log capture needs Godot 4.5 or newer")
	return _log.since(int(params.get("since_id", 0)), bool(params.get("errors_only", false)), int(params.get("limit", 200)))


func _quit(_params: Dictionary) -> Variant:
	_tree().quit.call_deferred()
	return {"quitting": true}


# --- input ------------------------------------------------------------------

## Runs input steps in order, e.g.
## [{"type": "action", "action": "jump"}, {"type": "wait", "ms": 500},
##  {"type": "key", "key": "D", "hold_ms": 800}, {"type": "click", "x": 320, "y": 200}]
func _input(params: Dictionary) -> Variant:
	var steps: Array = params.get("steps", [])
	var done := 0
	for step in steps:
		if typeof(step) != TYPE_DICTIONARY:
			return Bridge.fail("Step %d is not an object" % done)
		var error = await _run_step(step)
		if error:
			return Bridge.fail("Step %d (%s): %s" % [done, step.get("type"), error])
		done += 1
	return {"steps_done": done, "frame": Engine.get_process_frames()}


func _run_step(step: Dictionary) -> String:
	var hold := float(step.get("hold_ms", 80)) / 1000.0
	match str(step.get("type", "")):
		"wait":
			await _wait(float(step.get("ms", 100)) / 1000.0)
		"wait_frames":
			for i in int(step.get("frames", 1)):
				await _tree().process_frame
		"action":
			var action := StringName(str(step.get("action", "")))
			if not InputMap.has_action(action):
				return "Unknown input action '%s'" % action
			var mode := str(step.get("mode", "tap"))
			if mode != "release":
				_send_action(action, true, float(step.get("strength", 1.0)))
			if mode == "tap":
				await _wait(hold)
			if mode != "press":
				_send_action(action, false, 0.0)
		"key":
			var keycode := OS.find_keycode_from_string(str(step.get("key", "")))
			if keycode == KEY_NONE:
				return "Unknown key '%s'" % step.get("key")
			var mode := str(step.get("mode", "tap"))
			if mode != "release":
				_send_key(keycode, true, step)
			if mode == "tap":
				await _wait(hold)
			if mode != "press":
				_send_key(keycode, false, step)
		"text":
			for ch in str(step.get("text", "")):
				var event := InputEventKey.new()
				event.unicode = ch.unicode_at(0)
				event.keycode = OS.find_keycode_from_string(ch.to_upper())
				event.pressed = true
				Input.parse_input_event(event)
				var release := event.duplicate()
				release.pressed = false
				Input.parse_input_event(release)
				await _tree().process_frame
		"mouse_move":
			_send_motion(_to_window(step))
		"click":
			var pos := _to_window(step)
			var button: int = ProjectCommands.MOUSE_BUTTONS.get(step.get("button", "left"), MOUSE_BUTTON_LEFT)
			_send_motion(pos)
			await _tree().process_frame
			for i in (2 if bool(step.get("double", false)) else 1):
				_send_button(pos, button, true, i == 1)
				await _wait(hold)
				_send_button(pos, button, false, false)
		"drag":
			var from := _to_window({"x": step.get("from", [0, 0])[0], "y": step.get("from", [0, 0])[1]})
			var to := _to_window({"x": step.get("to", [0, 0])[0], "y": step.get("to", [0, 0])[1]})
			var button: int = ProjectCommands.MOUSE_BUTTONS.get(step.get("button", "left"), MOUSE_BUTTON_LEFT)
			var frames: int = max(1, int(float(step.get("ms", 300)) / 1000.0 * 60.0))
			_send_motion(from)
			_send_button(from, button, true, false)
			for i in frames:
				await _tree().process_frame
				_send_motion(from.lerp(to, float(i + 1) / frames), button)
			_send_button(to, button, false, false)
		"scroll":
			var pos := _to_window(step)
			var button := MOUSE_BUTTON_WHEEL_UP if str(step.get("direction", "down")) == "up" else MOUSE_BUTTON_WHEEL_DOWN
			for i in int(step.get("amount", 1)):
				_send_button(pos, button, true, false)
				_send_button(pos, button, false, false)
		_:
			return "Unknown step type (use wait, wait_frames, action, key, text, mouse_move, click, drag, scroll)"
	return ""


func _wait(seconds: float) -> void:
	await _tree().create_timer(seconds, true, false, true).timeout


## Maps screenshot pixel coordinates to window coordinates. Before any
## screenshot, coordinates are taken as window coordinates.
func _to_window(step: Dictionary) -> Vector2:
	var pos := Vector2(float(step.get("x", 0)), float(step.get("y", 0)))
	if _last_shot_size != Vector2.ZERO:
		pos *= Vector2(_host.get_window().size) / _last_shot_size
	return pos


func _send_action(action: StringName, pressed: bool, strength: float) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	event.strength = strength
	Input.parse_input_event(event)


func _send_key(keycode: Key, pressed: bool, step: Dictionary) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = pressed
	event.shift_pressed = bool(step.get("shift", false))
	event.ctrl_pressed = bool(step.get("ctrl", false))
	event.alt_pressed = bool(step.get("alt", false))
	Input.parse_input_event(event)


func _send_motion(pos: Vector2, held_button := 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.global_position = pos
	if held_button:
		event.button_mask = 1 << (held_button - 1)
	Input.parse_input_event(event)


func _send_button(pos: Vector2, button: int, pressed: bool, double_click: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = button
	event.pressed = pressed
	event.double_click = double_click
	if pressed:
		event.button_mask = 1 << (button - 1)
	Input.parse_input_event(event)
