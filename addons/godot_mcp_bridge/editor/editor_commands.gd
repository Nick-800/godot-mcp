## Live editor commands. Scene edits go through EditorUndoRedoManager, so
## they show up in the editor's history and can be undone with Ctrl+Z.
## Node paths are relative to the edited scene root ("." is the root).
@tool
extends RefCounted

const Codec := preload("../core/variant_codec.gd")
const Bridge := preload("../core/bridge_server.gd")

var _plugin: EditorPlugin
var _log: Object


func _init(plugin: EditorPlugin, log_capture: Object) -> void:
	_plugin = plugin
	_log = log_capture


func get_commands() -> Dictionary:
	return {
		"editor.status": _status,
		"editor.scene_tree": _scene_tree,
		"editor.open_scene": _open_scene,
		"editor.create_scene": _create_scene,
		"editor.save": _save,
		"editor.add_node": _add_node,
		"editor.delete_node": _delete_node,
		"editor.move_node": _move_node,
		"editor.get_properties": _get_properties,
		"editor.set_properties": _set_properties,
		"editor.select": _select,
		"editor.attach_script": _attach_script,
		"editor.signals": _signals,
		"editor.play": _play,
		"editor.stop": _stop,
		"editor.screenshot": _screenshot,
		"editor.reload_filesystem": _reload_filesystem,
		"editor.validate_scripts": _validate_scripts,
		"editor.get_log": _get_log,
	}


# --- helpers ----------------------------------------------------------------

func _root() -> Node:
	return EditorInterface.get_edited_scene_root()


func _find(path: Variant) -> Node:
	var root := _root()
	if root == null:
		return null
	var p := str(path) if path != null else "."
	if p in ["", ".", "/", root.name]:
		return root
	return root.get_node_or_null(NodePath(p))


## Returns [node, error]. error is a Bridge.fail() dictionary or null.
func _require(path: Variant, param_name := "node") -> Array:
	if _root() == null:
		return [null, Bridge.fail("No scene is open in the editor. Use editor_open_scene or editor_create_scene first.")]
	var node := _find(path)
	if node == null:
		return [null, Bridge.fail("No node at %s '%s' in %s" % [param_name, path, _root().scene_file_path])]
	return [node, null]


func _rel(node: Node) -> String:
	var root := _root()
	return "." if node == root else str(root.get_path_to(node))


func _undo() -> EditorUndoRedoManager:
	return _plugin.get_undo_redo()


func _owned_subtree(node: Node, owner: Node) -> Array[Node]:
	var out: Array[Node] = []
	if node.owner == owner:
		out.append(node)
	for child in node.get_children():
		out.append_array(_owned_subtree(child, owner))
	return out


func _apply_properties(node: Object, properties: Dictionary, undo: EditorUndoRedoManager = null) -> Array:
	var errors := []
	for prop in properties:
		if not Codec.has_property(node, prop):
			errors.append("%s has no property '%s'" % [node.get_class(), prop])
			continue
		var value = Codec.decode(properties[prop], Codec.property_type(node, prop))
		if not Codec.last_error.is_empty():
			errors.append("%s: %s" % [prop, Codec.last_error])
			continue
		if undo:
			undo.add_do_method(node, "set_indexed", prop, value)
			undo.add_undo_method(node, "set_indexed", prop, node.get_indexed(prop))
		else:
			node.set_indexed(prop, value)
	return errors


func _instantiate_type(type: String) -> Variant:
	if not type.is_valid_identifier():
		return Bridge.fail("Invalid node type '%s'" % type)
	if ClassDB.class_exists(type):
		if not ClassDB.is_parent_class(type, "Node") or not ClassDB.can_instantiate(type):
			return Bridge.fail("'%s' is not an instantiable Node type" % type)
		return ClassDB.instantiate(type)
	for info in ProjectSettings.get_global_class_list():
		if info["class"] == type:
			var script: Script = load(info.path)
			var base := script.get_instance_base_type()
			if not ClassDB.is_parent_class(base, "Node"):
				return Bridge.fail("'%s' does not extend Node" % type)
			var node: Node = ClassDB.instantiate(base)
			node.set_script(script)
			return node
	return Bridge.fail("Unknown node type '%s'" % type)


# --- status / tree ----------------------------------------------------------

func _status(_params: Dictionary) -> Variant:
	var root := _root()
	return {
		"godot_version": Engine.get_version_info().string,
		"project_name": ProjectSettings.get_setting("application/config/name", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
		"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
		"edited_scene": root.scene_file_path if root else null,
		"open_scenes": Array(EditorInterface.get_open_scenes()),
		"selected": EditorInterface.get_selection().get_selected_nodes().map(_rel) if root else [],
		"is_playing": EditorInterface.is_playing_scene(),
		"log_capture": _log != null,
	}


func _scene_tree(params: Dictionary) -> Variant:
	var found := _require(params.get("node", "."))
	if found[1]:
		return found[1]
	var props: Array = params.get("properties", [])
	return {
		"scene": _root().scene_file_path,
		"tree": _describe(found[0], int(params.get("max_depth", 20)), props, bool(params.get("expand_instances", false))),
	}


func _describe(node: Node, depth: int, props: Array, expand_instances: bool) -> Dictionary:
	var root := _root()
	var info := {"name": str(node.name), "type": node.get_class(), "path": _rel(node)}
	var script: Script = node.get_script()
	if script:
		info["script"] = script.resource_path
	var is_instance := node != root and not node.scene_file_path.is_empty()
	if is_instance:
		info["instance"] = node.scene_file_path
	for prop in props:
		if Codec.has_property(node, prop):
			info[prop] = Codec.encode(node.get_indexed(prop))
	if is_instance and not expand_instances:
		if node.get_child_count() > 0:
			info["children_hidden"] = node.get_child_count()
		return info
	var children := []
	for child in node.get_children():
		if child.owner == null or (child.owner != root and child.owner != node and not expand_instances):
			continue
		if depth <= 0:
			info["children_hidden"] = node.get_child_count()
			break
		children.append(_describe(child, depth - 1, props, expand_instances))
	if not children.is_empty():
		info["children"] = children
	return info


# --- scenes -----------------------------------------------------------------

func _open_scene(params: Dictionary) -> Variant:
	var path := str(params.get("path", ""))
	if not ResourceLoader.exists(path):
		return Bridge.fail("Scene not found: %s" % path)
	EditorInterface.open_scene_from_path(path)
	await _plugin.get_tree().process_frame
	return {"edited_scene": _root().scene_file_path if _root() else null}


func _create_scene(params: Dictionary) -> Variant:
	var path := str(params.get("path", ""))
	if not path.begins_with("res://") or not (path.ends_with(".tscn") or path.ends_with(".scn")):
		return Bridge.fail("path must be a res:// .tscn file")
	if FileAccess.file_exists(path) and not bool(params.get("overwrite", false)):
		return Bridge.fail("%s already exists (pass overwrite to replace it)" % path)
	var root = _instantiate_type(str(params.get("root_type", "Node2D")))
	if root is Dictionary:
		return root
	root.name = str(params.get("root_name", path.get_file().get_basename().to_pascal_case()))
	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var err := ResourceSaver.save(packed, path)
	if err != OK:
		return Bridge.fail("Saving %s failed: %s" % [path, error_string(err)])
	EditorInterface.get_resource_filesystem().update_file(path)
	EditorInterface.open_scene_from_path(path)
	await _plugin.get_tree().process_frame
	return {"created": path}


func _save(params: Dictionary) -> Variant:
	if bool(params.get("all", false)):
		EditorInterface.save_all_scenes()
		return {"saved": Array(EditorInterface.get_open_scenes())}
	if _root() == null:
		return Bridge.fail("No scene is open")
	var err := EditorInterface.save_scene()
	if err != OK:
		return Bridge.fail("Save failed: %s" % error_string(err))
	return {"saved": _root().scene_file_path}


# --- node editing -----------------------------------------------------------

func _add_node(params: Dictionary) -> Variant:
	var found := _require(params.get("parent", "."), "parent")
	if found[1]:
		return found[1]
	var parent: Node = found[0]
	var root := _root()
	var node: Node
	if params.has("scene"):
		var scene_path := str(params.scene)
		if not ResourceLoader.exists(scene_path):
			return Bridge.fail("Scene not found: %s" % scene_path)
		var packed := load(scene_path) as PackedScene
		if packed == null:
			return Bridge.fail("%s is not a PackedScene" % scene_path)
		node = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	else:
		var made = _instantiate_type(str(params.get("type", "")))
		if made is Dictionary:
			return made
		node = made
	if params.has("name"):
		node.name = str(params.name)
	var errors := _apply_properties(node, params.get("properties", {}))

	var undo := _undo()
	undo.create_action("MCP: Add %s" % node.name, UndoRedo.MERGE_DISABLE, root)
	undo.add_do_method(parent, "add_child", node, true)
	undo.add_do_method(node, "set_owner", root)
	if params.has("index"):
		undo.add_do_method(parent, "move_child", node, int(params.index))
	undo.add_do_reference(node)
	undo.add_undo_method(parent, "remove_child", node)
	undo.commit_action()
	return {"path": _rel(node), "type": node.get_class(), "errors": errors}


func _delete_node(params: Dictionary) -> Variant:
	var found := _require(params.get("node"))
	if found[1]:
		return found[1]
	var node: Node = found[0]
	var root := _root()
	if node == root:
		return Bridge.fail("Can't delete the scene root")
	var parent := node.get_parent()
	var path := _rel(node)
	EditorInterface.get_selection().remove_node(node)
	var undo := _undo()
	undo.create_action("MCP: Delete %s" % node.name, UndoRedo.MERGE_DISABLE, root)
	undo.add_do_method(parent, "remove_child", node)
	undo.add_undo_method(parent, "add_child", node, true)
	undo.add_undo_method(parent, "move_child", node, node.get_index())
	for owned in _owned_subtree(node, root):
		undo.add_undo_method(owned, "set_owner", root)
	undo.add_undo_reference(node)
	undo.commit_action()
	return {"deleted": path}


func _move_node(params: Dictionary) -> Variant:
	var found := _require(params.get("node"))
	if found[1]:
		return found[1]
	var node: Node = found[0]
	var root := _root()
	if node == root and (params.has("new_parent") or params.has("index")):
		return Bridge.fail("Can't move the scene root")
	var parent := node.get_parent()
	var undo := _undo()
	undo.create_action("MCP: Move %s" % node.name, UndoRedo.MERGE_DISABLE, root)
	var owned := _owned_subtree(node, root)
	var target_parent := parent
	if params.has("new_parent"):
		var dest := _require(params.new_parent, "new_parent")
		if dest[1]:
			return dest[1]
		target_parent = dest[0]
		if target_parent == node or node.is_ancestor_of(target_parent):
			return Bridge.fail("Can't move a node under itself")
		if target_parent != parent:
			var keep := bool(params.get("keep_global_transform", true))
			undo.add_do_method(node, "reparent", target_parent, keep)
			undo.add_undo_method(node, "reparent", parent, keep)
			undo.add_undo_method(parent, "move_child", node, node.get_index())
			for n in owned:
				undo.add_do_method(n, "set_owner", root)
				undo.add_undo_method(n, "set_owner", root)
	if params.has("index"):
		undo.add_do_method(target_parent, "move_child", node, int(params.index))
		if target_parent == parent:
			undo.add_undo_method(parent, "move_child", node, node.get_index())
	if params.has("new_name"):
		undo.add_do_property(node, "name", str(params.new_name))
		undo.add_undo_property(node, "name", node.name)
	undo.commit_action()
	return {"path": _rel(node)}


func _get_properties(params: Dictionary) -> Variant:
	var found := _require(params.get("node", "."))
	if found[1]:
		return found[1]
	var node: Node = found[0]
	return {
		"path": _rel(node),
		"type": node.get_class(),
		"properties": Codec.describe_properties(node, params.get("names", []), bool(params.get("changed_only", true))),
	}


func _set_properties(params: Dictionary) -> Variant:
	var found := _require(params.get("node", "."))
	if found[1]:
		return found[1]
	var node: Node = found[0]
	var properties: Dictionary = params.get("properties", {})
	if properties.is_empty():
		return Bridge.fail("properties is empty")
	var undo := _undo()
	undo.create_action("MCP: Set properties on %s" % node.name, UndoRedo.MERGE_DISABLE, _root())
	var errors := _apply_properties(node, properties, undo)
	undo.commit_action()
	var now := {}
	for prop in properties:
		if Codec.has_property(node, prop):
			now[prop] = Codec.encode(node.get_indexed(prop))
	return {"path": _rel(node), "values": now, "errors": errors}


func _select(params: Dictionary) -> Variant:
	var selection := EditorInterface.get_selection()
	selection.clear()
	var selected := []
	for path in params.get("nodes", []):
		var node := _find(path)
		if node:
			selection.add_node(node)
			selected.append(_rel(node))
	if not selected.is_empty():
		EditorInterface.edit_node(_find(selected[-1]))
	return {"selected": selected}


func _attach_script(params: Dictionary) -> Variant:
	var found := _require(params.get("node", "."))
	if found[1]:
		return found[1]
	var node: Node = found[0]
	var path := str(params.get("script", ""))
	if path.is_empty():
		var undo := _undo()
		undo.create_action("MCP: Detach script", UndoRedo.MERGE_DISABLE, _root())
		undo.add_do_property(node, "script", null)
		undo.add_undo_property(node, "script", node.get_script())
		undo.commit_action()
		return {"path": _rel(node), "script": null}
	if not path.begins_with("res://") or not path.ends_with(".gd"):
		return Bridge.fail("script must be a res:// .gd path (or empty to detach)")
	var created := false
	if not FileAccess.file_exists(path):
		if not bool(params.get("create", true)):
			return Bridge.fail("Script not found: %s" % path)
		var script := GDScript.new()
		script.source_code = "extends %s\n\n\nfunc _ready() -> void:\n\tpass\n" % node.get_class()
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
		var err := ResourceSaver.save(script, path)
		if err != OK:
			return Bridge.fail("Couldn't create %s: %s" % [path, error_string(err)])
		EditorInterface.get_resource_filesystem().update_file(path)
		created = true
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as Script
	if loaded == null:
		return Bridge.fail("Couldn't load %s (parse error?)" % path)
	var undo := _undo()
	undo.create_action("MCP: Attach script", UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_property(node, "script", loaded)
	undo.add_undo_property(node, "script", node.get_script())
	undo.commit_action()
	return {"path": _rel(node), "script": path, "created": created}


# --- signals ----------------------------------------------------------------

func _signals(params: Dictionary) -> Variant:
	var found := _require(params.get("node", "."))
	if found[1]:
		return found[1]
	var source: Node = found[0]
	match str(params.get("action", "list")):
		"list":
			return _list_signals(source, bool(params.get("include_builtin", false)))
		"connect":
			return _connect_signal(source, params)
		"disconnect":
			return _disconnect_signal(source, params)
	return Bridge.fail("Unknown action (use list, connect or disconnect)")


func _list_signals(source: Node, include_builtin: bool) -> Variant:
	var signals := []
	var script_signals := []
	if source.get_script():
		script_signals = source.get_script().get_script_signal_list().map(func(s): return s.name)
	for sig in source.get_signal_list():
		var connections := []
		for conn in source.get_signal_connection_list(sig.name):
			# Non-persistent connections are the editor's own wiring, not saved in the scene.
			if not (conn.flags & CONNECT_PERSIST):
				continue
			var target = conn.callable.get_object()
			connections.append({
				"target": _rel(target) if target is Node and _root().is_ancestor_of(target) or target == _root() else str(target),
				"method": conn.callable.get_method(),
				"binds": Codec.encode(conn.callable.get_bound_arguments()),
			})
		var is_script_signal: bool = sig.name in script_signals
		if not include_builtin and connections.is_empty() and not is_script_signal:
			continue
		signals.append({
			"name": sig.name,
			"args": sig.args.map(func(a): return "%s: %s" % [a.name, _type_name(a)]),
			"connections": connections,
		})
	return {"node": _rel(source), "signals": signals}


func _connect_signal(source: Node, params: Dictionary) -> Variant:
	var sig := str(params.get("signal", ""))
	if not source.has_signal(sig):
		return Bridge.fail("%s has no signal '%s'" % [_rel(source), sig])
	var found := _require(params.get("target", "."), "target")
	if found[1]:
		return found[1]
	var target: Node = found[0]
	var method := str(params.get("method", ""))
	if method.is_empty():
		method = "_on_%s_%s" % [str(source.name).to_snake_case(), sig]
	if not method.is_valid_identifier():
		return Bridge.fail("Invalid method name '%s'" % method)

	var binds: Array = params.get("binds", []).map(func(b): return Codec.decode(b))
	var stub_added := false
	if not _has_method(target, method):
		var script: Script = target.get_script()
		if script == null or not script is GDScript:
			return Bridge.fail("%s has no method '%s' and no GDScript to add it to. Attach a script first." % [_rel(target), method])
		if not bool(params.get("create_method", true)):
			return Bridge.fail("%s has no method '%s'" % [_rel(target), method])
		var stub_error := _add_stub(script, method, _signal_args(source, sig), binds.size())
		if stub_error:
			return Bridge.fail(stub_error)
		stub_added = true

	var callable := Callable(target, method)
	if not binds.is_empty():
		callable = callable.bindv(binds)
	if source.is_connected(sig, callable):
		return Bridge.fail("Already connected")
	var flags := CONNECT_PERSIST
	if bool(params.get("deferred", false)):
		flags |= CONNECT_DEFERRED
	if bool(params.get("one_shot", false)):
		flags |= CONNECT_ONE_SHOT
	var undo := _undo()
	undo.create_action("MCP: Connect %s.%s" % [source.name, sig], UndoRedo.MERGE_DISABLE, _root())
	undo.add_do_method(source, "connect", sig, callable, flags)
	undo.add_undo_method(source, "disconnect", sig, callable)
	undo.commit_action()
	return {"from": _rel(source), "signal": sig, "to": _rel(target), "method": method, "method_stub_added": stub_added}


func _disconnect_signal(source: Node, params: Dictionary) -> Variant:
	var sig := str(params.get("signal", ""))
	var found := _require(params.get("target", "."), "target")
	if found[1]:
		return found[1]
	var target: Node = found[0]
	var method := str(params.get("method", ""))
	for conn in source.get_signal_connection_list(sig):
		var callable: Callable = conn.callable
		if callable.get_object() == target and (method.is_empty() or callable.get_method() == method):
			var undo := _undo()
			undo.create_action("MCP: Disconnect %s.%s" % [source.name, sig], UndoRedo.MERGE_DISABLE, _root())
			undo.add_do_method(source, "disconnect", sig, callable)
			undo.add_undo_method(source, "connect", sig, callable, conn.flags)
			undo.commit_action()
			return {"disconnected": {"from": _rel(source), "signal": sig, "to": _rel(target), "method": callable.get_method()}}
	return Bridge.fail("No matching connection found")


func _has_method(target: Node, method: String) -> bool:
	if ClassDB.class_has_method(target.get_class(), method):
		return true
	var script: Script = target.get_script()
	while script:
		for m in script.get_script_method_list():
			if m.name == method:
				return true
		script = script.get_base_script()
	return false


func _signal_args(source: Node, sig: String) -> Array:
	for info in source.get_signal_list():
		if info.name == sig:
			return info.args
	return []


func _type_name(arg: Dictionary) -> String:
	if arg.type == TYPE_OBJECT:
		return arg.class_name if not str(arg.class_name).is_empty() else "Object"
	if arg.type == TYPE_NIL:
		return "Variant"
	return type_string(arg.type)


func _add_stub(script: GDScript, method: String, args: Array, bind_count: int) -> String:
	var params := args.map(func(a): return "%s: %s" % [a.name, _type_name(a)])
	for i in bind_count:
		params.append("extra_arg_%d" % i)
	var source := script.source_code.rstrip("\n")
	script.source_code = "%s\n\n\nfunc %s(%s) -> void:\n\tpass\n" % [source, method, ", ".join(params)]
	var err := ResourceSaver.save(script, script.resource_path)
	if err != OK:
		return "Couldn't save %s: %s" % [script.resource_path, error_string(err)]
	script.reload(true)
	return ""


# --- running ----------------------------------------------------------------

func _play(params: Dictionary) -> Variant:
	var scene := str(params.get("scene", "main"))
	match scene:
		"main":
			if str(ProjectSettings.get_setting("application/run/main_scene", "")).is_empty():
				return Bridge.fail("No main scene set. Pass scene: \"current\" or a res:// path, or set application/run/main_scene.")
			EditorInterface.play_main_scene()
		"current":
			if _root() == null:
				return Bridge.fail("No scene is open")
			EditorInterface.play_current_scene()
		_:
			if not ResourceLoader.exists(scene):
				return Bridge.fail("Scene not found: %s" % scene)
			EditorInterface.play_custom_scene(scene)
	return {"playing": scene}


func _stop(_params: Dictionary) -> Variant:
	var was_playing := EditorInterface.is_playing_scene()
	EditorInterface.stop_playing_scene()
	return {"stopped": was_playing}


func _screenshot(params: Dictionary) -> Variant:
	if DisplayServer.get_name() == "headless":
		return Bridge.fail("The editor is running headless, so there is nothing to capture")
	var viewport: Viewport
	match str(params.get("target", "editor")):
		"2d":
			viewport = EditorInterface.get_editor_viewport_2d()
		"3d":
			viewport = EditorInterface.get_editor_viewport_3d(0)
		_:
			viewport = EditorInterface.get_base_control().get_viewport()
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image() if viewport else null
	if image == null or image.is_empty():
		return Bridge.fail("Couldn't capture the editor (is it running headless?)")
	return Codec.image_payload(image, int(params.get("max_width", 1280)))


# --- files / scripts --------------------------------------------------------

func _gd_files(dir: String, include_addons: bool, out: Array[String]) -> void:
	for sub in DirAccess.get_directories_at(dir):
		if sub.begins_with("."):
			continue
		if sub == "addons" and dir == "res://" and not include_addons:
			continue
		_gd_files(dir.path_join(sub), include_addons, out)
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".gd"):
			out.append(dir.path_join(file))


## Picks up files written outside the editor: rescans the filesystem and
## refreshes any already-loaded script whose source changed on disk.
func _reload_filesystem(_params: Dictionary) -> Variant:
	var files: Array[String] = []
	_gd_files("res://", false, files)
	var reloaded := []
	for path in files:
		if not ResourceLoader.has_cached(path):
			continue
		var script := load(path) as GDScript
		var disk := FileAccess.get_file_as_string(path)
		if script and script.source_code != disk:
			script.source_code = disk
			script.reload(true)
			reloaded.append(path)
	EditorInterface.get_resource_filesystem().scan()
	return {"rescanned": true, "reloaded_scripts": reloaded}


func _validate_scripts(params: Dictionary) -> Variant:
	var paths: Array = params.get("paths", [])
	if paths.is_empty():
		var files: Array[String] = []
		_gd_files("res://", bool(params.get("include_addons", false)), files)
		paths = files
	var failures := []
	for path in paths:
		if not FileAccess.file_exists(path):
			failures.append({"path": path, "errors": ["File not found"]})
			continue
		# Compile a fresh copy that knows its path, so relative preloads
		# resolve without touching the cached script the editor uses.
		var mark: int = _log.last_id() if _log else 0
		var script := GDScript.new()
		script.source_code = FileAccess.get_file_as_string(path)
		script.set_path_cache(path)
		var err := script.reload()
		var errors := []
		if _log:
			for line in _log.errors_since(mark):
				if line not in errors:
					errors.append(line)
		if err != OK:
			if errors.is_empty():
				errors = ["%s (details need Godot 4.5+)" % error_string(err)]
			failures.append({"path": path, "errors": errors})
	return {"checked": paths.size(), "failures": failures}


func _get_log(params: Dictionary) -> Variant:
	if _log == null:
		return Bridge.fail("Log capture needs Godot 4.5 or newer")
	return _log.since(int(params.get("since_id", 0)), bool(params.get("errors_only", false)), int(params.get("limit", 200)))
