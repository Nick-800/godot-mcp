## Shared secret that gates the bridge sockets. It lives in the project's
## .godot folder (normally gitignored), so only local tools that can read the
## project directory can connect. Browsers can reach localhost ports but
## cannot read this file.
@tool
extends RefCounted

const TOKEN_PATH := "res://.godot/mcp_bridge_token"


static func read_current() -> String:
	if not FileAccess.file_exists(TOKEN_PATH):
		return ""
	return FileAccess.get_file_as_string(TOKEN_PATH).strip_edges()


static func get_or_create() -> String:
	var existing := read_current()
	if existing.length() >= 32:
		return existing
	var token := Crypto.new().generate_random_bytes(24).hex_encode()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot"))
	var file := FileAccess.open(TOKEN_PATH, FileAccess.WRITE)
	if file:
		file.store_string(token)
	return token
