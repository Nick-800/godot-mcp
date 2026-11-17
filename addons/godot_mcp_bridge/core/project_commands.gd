## Project settings, input map and autoload commands. Used live by the editor
## plugin and, when no editor is connected, by headless_runner.gd.
@tool
extends RefCounted

const Codec := preload("variant_codec.gd")
const Bridge := preload("bridge_server.gd")

const BRIDGE_AUTOLOAD := "MCPRuntimeBridge"

## The EditorPlugin when running inside the editor, otherwise null.
var _plugin: Object
var _addon_dir: String


func _init(plugin: Object, addon_dir: String) -> void:
	_plugin = plugin
	_addon_dir = addon_dir


func get_commands() -> Dictionary:
	return {
		"project.settings": _settings,
		"project.input_actions": _input_actions,
		"project.autoloads": _autoloads,
		"project.enable_bridge": _enable_bridge,
	}


func _save() -> String:
	var err := ProjectSettings.save()
	return "" if err == OK else "ProjectSettings.save() failed: %s" % error_string(err)


# --- settings ---------------------------------------------------------------

func _settings(params: Dictionary) -> Variant:
	var action := str(params.get("action", "get"))
	if action == "get":
		var prefix := str(params.get("prefix", ""))
		var keys: Array = params.get("keys", [])
		var out := {}
		if not keys.is_empty():
			for key in keys:
				out[key] = Codec.encode(ProjectSettings.get_setting(key)) if ProjectSettings.has_setting(key) else "<unset>"
			return {"settings": out}
		var count := 0
		for info in ProjectSettings.get_property_list():
			var name: String = info.name
			if not name.contains("/") or not name.begins_with(prefix):
				continue
			out[name] = Codec.encode(ProjectSettings.get_setting(name))
			count += 1
			if count >= 300:
				return {"settings": out, "truncated": true}
		return {"settings": out}
	if action == "set":
		var settings: Dictionary = params.get("settings", {})
		if settings.is_empty():
			return Bridge.fail("settings is empty")
		var applied := {}
		var errors := []
		for key in settings:
			var raw = settings[key]
			if raw == null:
				ProjectSettings.set_setting(key, null)
				applied[key] = null
				continue
			var target := typeof(ProjectSettings.get_setting(key)) if ProjectSettings.has_setting(key) else TYPE_NIL
			var value = Codec.decode(raw, target)
			if not Codec.last_error.is_empty():
				errors.append("%s: %s" % [key, Codec.last_error])
				continue
			ProjectSettings.set_setting(key, value)
			applied[key] = Codec.encode(value)
		var save_error := _save()
		if save_error:
			errors.append(save_error)
		return {"applied": applied, "errors": errors}
	return Bridge.fail("Unknown action '%s' (use get or set)" % action)


# --- input map --------------------------------------------------------------

func _input_actions(params: Dictionary) -> Variant:
	var action := str(params.get("action", "list"))
	var name := str(params.get("name", ""))
	match action:
		"list":
			var include_builtin := bool(params.get("include_builtin", false))
			var out := {}
			for info in ProjectSettings.get_property_list():
				var key: String = info.name
				if not key.begins_with("input/"):
					continue
				var action_name := key.trim_prefix("input/")
				if action_name.begins_with("ui_") and not include_builtin:
					continue
				var data = ProjectSettings.get_setting(key)
				if typeof(data) != TYPE_DICTIONARY:
					continue
				out[action_name] = {
					"deadzone": data.get("deadzone", 0.5),
					"events": data.get("events", []).map(_describe_event),
				}
			return {"actions": out}
		"add", "set":
			if not name.is_valid_identifier() and not name.replace(".", "_").is_valid_identifier():
				return Bridge.fail("Invalid action name '%s'" % name)
			var key := "input/" + name
			var existing: Dictionary = ProjectSettings.get_setting(key, {}) if ProjectSettings.has_setting(key) else {}
			var events: Array = [] if action == "set" else existing.get("events", []).duplicate()
			for spec in params.get("events", []):
				var event = _make_event(spec)
				if event is String:
					return Bridge.fail(event)
				events.append(event)
			ProjectSettings.set_setting(key, {
				"deadzone": float(params.get("deadzone", existing.get("deadzone", 0.5))),
				"events": events,
			})
			var save_error := _save()
			if save_error:
				return Bridge.fail(save_error)
			return {"action": name, "events": events.map(_describe_event)}
		"remove":
			var key := "input/" + name
			if not ProjectSettings.has_setting(key):
				return Bridge.fail("No input action '%s'" % name)
			ProjectSettings.set_setting(key, null)
			var save_error := _save()
			if save_error:
				return Bridge.fail(save_error)
			return {"removed": name}
	return Bridge.fail("Unknown action '%s' (use list, add, set or remove)" % action)


const MOUSE_BUTTONS := {"left": MOUSE_BUTTON_LEFT, "right": MOUSE_BUTTON_RIGHT, "middle": MOUSE_BUTTON_MIDDLE,
	"wheel_up": MOUSE_BUTTON_WHEEL_UP, "wheel_down": MOUSE_BUTTON_WHEEL_DOWN}


## Builds an InputEvent from {"type": "key", "key": "W"} style specs, or
## returns an error string.
static func _make_event(spec: Variant) -> Variant:
	if typeof(spec) != TYPE_DICTIONARY:
		return "Event spec must be an object like {\"type\": \"key\", \"key\": \"W\"}"
	match str(spec.get("type", "key")):
		"key":
			var keycode := OS.find_keycode_from_string(str(spec.get("key", "")))
			if keycode == KEY_NONE:
				return "Unknown key '%s'" % spec.get("key", "")
			var event := InputEventKey.new()
			event.device = -1  # all devices, like mappings made in the editor
			event.physical_keycode = keycode
			event.shift_pressed = bool(spec.get("shift", false))
			event.ctrl_pressed = bool(spec.get("ctrl", false))
			event.alt_pressed = bool(spec.get("alt", false))
			event.meta_pressed = bool(spec.get("meta", false))
			return event
		"mouse_button":
			var button = spec.get("button", "left")
			var event := InputEventMouseButton.new()
			event.device = -1
			event.button_index = MOUSE_BUTTONS.get(button, int(button) if str(button).is_valid_int() else MOUSE_BUTTON_LEFT)
			return event
		"joy_button":
			var event := InputEventJoypadButton.new()
			event.button_index = int(spec.get("button", 0))
			event.device = -1
			return event
		"joy_axis":
			var event := InputEventJoypadMotion.new()
			event.axis = int(spec.get("axis", 0))
			event.axis_value = float(spec.get("value", 1.0))
			event.device = -1
			return event
	return "Unknown event type '%s' (use key, mouse_button, joy_button or joy_axis)" % spec.get("type")


static func _describe_event(event: Variant) -> Variant:
	if event is InputEventKey:
		var code: int = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
		var parts := []
		for mod in [["Ctrl", event.ctrl_pressed], ["Shift", event.shift_pressed], ["Alt", event.alt_pressed], ["Meta", event.meta_pressed]]:
			if mod[1]:
				parts.append(mod[0])
		parts.append(OS.get_keycode_string(code))
		return {"type": "key", "key": "+".join(parts)}
	if event is InputEventMouseButton:
		return {"type": "mouse_button", "button": event.button_index}
	if event is InputEventJoypadButton:
		return {"type": "joy_button", "button": event.button_index}
	if event is InputEventJoypadMotion:
		return {"type": "joy_axis", "axis": event.axis, "value": event.axis_value}
	return str(event)


# --- autoloads --------------------------------------------------------------

func _autoloads(params: Dictionary) -> Variant:
	var action := str(params.get("action", "list"))
	var name := str(params.get("name", ""))
	match action:
		"list":
			var out := {}
			for info in ProjectSettings.get_property_list():
				var key: String = info.name
				if key.begins_with("autoload/"):
					var raw := str(ProjectSettings.get_setting(key))
					out[key.trim_prefix("autoload/")] = {"path": raw.trim_prefix("*"), "enabled": raw.begins_with("*")}
			return {"autoloads": out}
		"add":
			var path := str(params.get("path", ""))
			if not name.is_valid_identifier():
				return Bridge.fail("Autoload name must be a valid identifier")
			if not FileAccess.file_exists(path):
				return Bridge.fail("File not found: %s" % path)
			if _plugin:
				_plugin.add_autoload_singleton(name, path)
			else:
				ProjectSettings.set_setting("autoload/" + name, "*" + path)
				var save_error := _save()
				if save_error:
					return Bridge.fail(save_error)
			return {"added": name, "path": path}
		"remove":
			if not ProjectSettings.has_setting("autoload/" + name):
				return Bridge.fail("No autoload named '%s'" % name)
			if _plugin:
				_plugin.remove_autoload_singleton(name)
			else:
				ProjectSettings.set_setting("autoload/" + name, null)
				var save_error := _save()
				if save_error:
					return Bridge.fail(save_error)
			return {"removed": name}
	return Bridge.fail("Unknown action '%s' (use list, add or remove)" % action)


# --- bridge install ---------------------------------------------------------

## Turns on the editor plugin and the runtime autoload in project.godot.
## Used by the installer when no editor is running.
func _enable_bridge(_params: Dictionary) -> Variant:
	var plugin_cfg := _addon_dir.path_join("plugin.cfg")
	var enabled: PackedStringArray = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	if not enabled.has(plugin_cfg):
		enabled.append(plugin_cfg)
		ProjectSettings.set_setting("editor_plugins/enabled", enabled)
	ProjectSettings.set_setting("autoload/" + BRIDGE_AUTOLOAD, "*" + _addon_dir.path_join("runtime/runtime_bridge.gd"))
	var save_error := _save()
	if save_error:
		return Bridge.fail(save_error)
	return {"enabled": true, "plugin": plugin_cfg}
