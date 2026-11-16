## Converts between Godot Variants and JSON-friendly values.
##
## Encoding: JSON primitives pass through, resources become their res:// path,
## and other built-in types use Godot's text form, e.g. "Vector2(1, 2)".
## Decoding is guided by the target property's type, so callers can send
## "Vector2(1, 2)", [1, 2] or {"x": 1, "y": 2} for a Vector2, "#ff0000" or
## "red" for a Color, and "res://icon.svg" for a Texture2D.
@tool
extends RefCounted

const VECTOR_FIELDS := {
	TYPE_VECTOR2: ["x", "y"], TYPE_VECTOR2I: ["x", "y"],
	TYPE_VECTOR3: ["x", "y", "z"], TYPE_VECTOR3I: ["x", "y", "z"],
	TYPE_VECTOR4: ["x", "y", "z", "w"], TYPE_VECTOR4I: ["x", "y", "z", "w"],
	TYPE_COLOR: ["r", "g", "b", "a"],
}

static var _constructor_regex := RegEx.create_from_string("^[A-Z][A-Za-z0-9]*\\(.*\\)$")

## Set by decode() when a value could not be converted; empty otherwise.
static var last_error := ""


static func encode(value: Variant, depth := 0) -> Variant:
	var type := typeof(value)
	match type:
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return value
		TYPE_FLOAT:
			return value if is_finite(value) else str(value)
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(value)
		TYPE_ARRAY:
			if depth > 8:
				return "[...]"
			var out := []
			for item in value:
				out.append(encode(item, depth + 1))
			return out
		TYPE_DICTIONARY:
			if depth > 8:
				return "{...}"
			var out := {}
			for key in value:
				out[str(key)] = encode(value[key], depth + 1)
			return out
		TYPE_OBJECT:
			if not is_instance_valid(value):
				return null
			if value is Resource and not value.resource_path.is_empty() and not value.resource_path.contains("::"):
				return value.resource_path
			if value is InputEvent:
				return value.as_text()
			if value is Node:
				return "<%s %s>" % [value.get_class(), value.get_path() if value.is_inside_tree() else value.name]
			return "<%s>" % value.get_class()
		TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
			return str(value)
	if type >= TYPE_PACKED_BYTE_ARRAY and type < TYPE_MAX:
		if value.size() > 64:
			return "%s(size=%d)" % [type_string(type), value.size()]
		return encode(Array(value), depth)
	return var_to_str(value)


static func decode(value: Variant, target_type: int = TYPE_NIL) -> Variant:
	last_error = ""
	if value is String:
		return _decode_string(value, target_type)
	if value is Array:
		if VECTOR_FIELDS.has(target_type):
			return _vector_from(value, target_type)
		if target_type >= TYPE_PACKED_BYTE_ARRAY and target_type < TYPE_MAX:
			return type_convert(value.map(func(v): return decode(v)), target_type)
		return value.map(func(v): return decode(v))
	if value is Dictionary:
		if VECTOR_FIELDS.has(target_type):
			var fields: Array = VECTOR_FIELDS[target_type]
			return _vector_from(fields.map(func(f): return value.get(f, 1.0 if f == "a" else 0.0)), target_type)
		var out := {}
		for key in value:
			out[key] = decode(value[key])
		return out
	if target_type == TYPE_NIL or target_type == TYPE_OBJECT:
		return value
	return type_convert(value, target_type)


static func _decode_string(s: String, target_type: int) -> Variant:
	match target_type:
		TYPE_STRING:
			return s
		TYPE_STRING_NAME:
			return StringName(s)
		TYPE_NODE_PATH:
			return NodePath(s)
		TYPE_OBJECT:
			if s.is_empty() or s == "null":
				return null
			if s.begins_with("res://") or s.begins_with("uid://"):
				if not ResourceLoader.exists(s):
					last_error = "Resource not found: %s" % s
					return null
				return load(s)
		TYPE_COLOR:
			if not s.begins_with("Color("):
				return Color.from_string(s, Color(0, 0, 0, 0))
		TYPE_INT:
			if s.is_valid_int():
				return s.to_int()
		TYPE_FLOAT:
			if s.is_valid_float():
				return s.to_float()
		TYPE_BOOL:
			return s.to_lower() in ["true", "1", "yes", "on"]
	if _constructor_regex.search(s) and not s.contains("Object("):
		var parsed = str_to_var(s)
		if parsed != null:
			return parsed if target_type == TYPE_NIL else type_convert(parsed, target_type)
		last_error = "Could not parse %s" % s
		return null
	if target_type == TYPE_NIL:
		return s
	return type_convert(s, target_type)


static func _vector_from(items: Array, target_type: int) -> Variant:
	var n: Array = items.map(func(v): return float(v))
	match target_type:
		TYPE_VECTOR2: return Vector2(n[0], n[1])
		TYPE_VECTOR2I: return Vector2i(n[0], n[1])
		TYPE_VECTOR3: return Vector3(n[0], n[1], n[2])
		TYPE_VECTOR3I: return Vector3i(n[0], n[1], n[2])
		TYPE_VECTOR4: return Vector4(n[0], n[1], n[2], n[3])
		TYPE_VECTOR4I: return Vector4i(n[0], n[1], n[2], n[3])
		TYPE_COLOR: return Color(n[0], n[1], n[2], n[3] if n.size() > 3 else 1.0)
	return null


## Type to decode into when assigning obj.set_indexed(property, value).
static func property_type(obj: Object, property: String) -> int:
	var current = obj.get_indexed(property)
	if current != null:
		return typeof(current)
	var base := property.get_slice(":", 0)
	for info in obj.get_property_list():
		if info.name == base:
			return info.type
	return TYPE_NIL


static func has_property(obj: Object, property: String) -> bool:
	var base := property.get_slice(":", 0)
	for info in obj.get_property_list():
		if info.name == base:
			return true
	return false


## Editor-visible properties, optionally only those changed from defaults.
static func describe_properties(obj: Object, names: Array, changed_only: bool) -> Dictionary:
	var out := {}
	if not names.is_empty():
		for name in names:
			out[name] = encode(obj.get_indexed(name)) if has_property(obj, name) else "<no such property>"
		return out
	var script: Script = obj.get_script()
	for info in obj.get_property_list():
		var usage: int = info.usage
		if usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
			continue
		var is_script_var := (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0
		if not (usage & PROPERTY_USAGE_EDITOR) and not is_script_var:
			continue
		var name: String = info.name
		var value = obj.get(name)
		# Script variables are always listed: they are few and usually what matters.
		if changed_only and not is_script_var:
			var default_value = ClassDB.class_get_property_default_value(obj.get_class(), name)
			if typeof(default_value) == typeof(value) and default_value == value:
				continue
		out[name] = encode(value)
	if script:
		out["script"] = script.resource_path
	return out


static func image_payload(image: Image, max_width: int) -> Dictionary:
	var source_size := image.get_size()
	if max_width > 0 and image.get_width() > max_width:
		var height := int(round(image.get_height() * float(max_width) / image.get_width()))
		image.resize(max_width, max(1, height), Image.INTERPOLATE_LANCZOS)
	return {
		"png_base64": Marshalls.raw_to_base64(image.save_png_to_buffer()),
		"width": image.get_width(),
		"height": image.get_height(),
		"source_width": source_size.x,
		"source_height": source_size.y,
	}
