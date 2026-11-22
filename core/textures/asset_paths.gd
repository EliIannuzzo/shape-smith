extends RefCounted

signal changed
const VANILLA := ["game", "survival", "creative", "story", "tutorial"]
## The game loads assets/game, survival, creative and the others all as the
## "game" domain, the play-style folders overriding the base: survival's
## seraph-naked.png (64 × 152, matching seraph.json) replaces game's old
## 128 × 128 one. Folders are searched in this order; others after.
const VANILLA_ORDER := ["survival", "creative", "story", "tutorial", "game"]
var base_path := ""
var additional: PackedStringArray = []
var config_path := "user://asset_paths.cfg"
var history
var last_error := ""


func roots() -> PackedStringArray:
	var result := PackedStringArray()
	if not base_path.is_empty():
		result.append(base_path)
	result.append_array(additional)
	return result


func load_config() -> void:
	var config := ConfigFile.new()
	if config.load(config_path) == OK:
		base_path = str(config.get_value("assets", "base", ""))
		additional = PackedStringArray(config.get_value("assets", "additional", []))
	changed.emit()


func configure(base: String, paths: PackedStringArray, persist := true) -> String:
	var normalized := PackedStringArray()
	var seen := PackedStringArray()
	var normalized_base := normalize(base) if not base.strip_edges().is_empty() else ""
	for path in ([normalized_base] if not normalized_base.is_empty() else []) + Array(paths):
		var value := normalize(path)
		if value.is_empty() or not DirAccess.dir_exists_absolute(value):
			return "Directory does not exist: %s" % path

		if value.to_lower() in seen:
			return "Duplicate asset path: %s" % value

		seen.append(value.to_lower())
		if value != normalized_base:
			normalized.append(value)
	if normalized_base == base_path and normalized == additional:
		return ""

	if history != null and persist:
		history.perform("Configure Asset Paths", _apply_config.bind(normalized_base, normalized, true),
			_apply_config.bind(base_path, additional.duplicate(), true), "", false)
	else:
		_apply_config(normalized_base, normalized, persist)
	return last_error


func _apply_config(base: String, paths: PackedStringArray, persist: bool) -> bool:
	last_error = ""
	if persist:
		var config := ConfigFile.new()
		config.set_value("assets", "base", base)
		config.set_value("assets", "additional", paths)
		if config.save(config_path) != OK:
			last_error = "Could not save asset path settings."
			return false

	base_path = base
	additional = paths.duplicate()
	changed.emit()
	return true


func resolve(reference: String) -> String:
	var domain := ""
	var path := reference.replace("\\", "/")
	if ":" in path:
		domain = path.get_slice(":", 0)
		path = path.get_slice(":", 1)
	path = path.trim_prefix("textures/")
	if path.get_extension().is_empty():
		path += ".png"
	if path.is_absolute_path() or ".." in path.split("/"):
		return ""

	for root in roots():
		for folder in texture_folders(root):
			if not domain.is_empty() and folder.domain != domain:
				continue

			var candidate: String = folder.path.path_join(path)
			if FileAccess.file_exists(candidate):
				return candidate

	return ""


func resolve_shape(reference: String, source_path := "") -> String:
	var path := reference.replace("\\", "/")
	if path.get_extension().is_empty():
		path += ".json"
	if path.is_absolute_path() or path.begins_with("res://") or path.begins_with("user://"):
		return path if FileAccess.file_exists(path) else ""

	var domain := ""
	if ":" in path:
		domain = path.get_slice(":", 0)
		path = path.get_slice(":", 1)
	path = path.trim_prefix("shapes/")
	var search_roots: Array = Array(roots())
	var cursor := normalize(source_path).get_base_dir()
	while not cursor.is_empty():
		if cursor.get_file().to_lower() == "shapes":
			search_roots.append(cursor.get_base_dir())
			break
		var parent := cursor.get_base_dir()
		if parent == cursor:
			break
		cursor = parent
	for root_path in search_roots:
		for folder in shape_folders(root_path):
			if not domain.is_empty() and folder.domain != domain:
				continue

			var candidate: String = folder.path.path_join(path).simplify_path()
			if FileAccess.file_exists(candidate):
				return candidate

	if domain.is_empty() and not source_path.is_empty():
		var relative := normalize(source_path).get_base_dir().path_join(path).simplify_path()
		if FileAccess.file_exists(relative):
			return relative

	return ""


static func shape_folders(path: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var root := normalize(path)
	if root.get_file().to_lower() in ["textures", "shapes"]:
		root = root.get_base_dir()
	if DirAccess.dir_exists_absolute(root.path_join("assets")):
		root = root.path_join("assets")
	if DirAccess.dir_exists_absolute(root.path_join("shapes")):
		result.append({"path": root.path_join("shapes"), "domain": domain_name(root.get_file())})
	for name in by_precedence(DirAccess.get_directories_at(root)):
		var folder := root.path_join(name).path_join("shapes")
		if DirAccess.dir_exists_absolute(folder):
			result.append({"path": folder, "domain": domain_name(name)})
	return result


func shape_reference(path: String, source_path: String) -> String:
	var full := normalize(path)
	var cursor := full.get_base_dir()
	while not cursor.is_empty():
		if cursor.get_file().to_lower() == "shapes":
			return domain_name(cursor.get_base_dir().get_file()) + ":" + full.substr(cursor.length() + 1).get_basename()

		var parent := cursor.get_base_dir()
		if parent == cursor:
			break
		cursor = parent
	return preload("res://core/textures/texture_library.gd").relative_file(normalize(source_path).get_base_dir(), full).get_basename()


func reference_for_file(path: String) -> Dictionary:
	var full := normalize(path)
	for root in roots():
		for folder in texture_folders(root):
			var reference := _relative_texture(full, folder.path, folder.domain)
			if not reference.is_empty():
				return {"reference": reference, "root": root}
	# Also recognize an unconfigured asset pack when linking a file directly.
	var cursor := full.get_base_dir()
	while not cursor.is_empty():
		if cursor.get_file().to_lower() == "textures":
			var domain := domain_name(cursor.get_base_dir().get_file())
			var reference := _relative_texture(full, cursor, domain)
			return {"reference": reference, "root": cursor.get_base_dir()}

		var parent := cursor.get_base_dir()
		if parent == cursor:
			break
		cursor = parent
	return {"reference": path, "root": ""}


static func normalize(path: String) -> String:
	if path.strip_edges().is_empty():
		return ""

	var result := ProjectSettings.globalize_path(path.strip_edges().replace("\\", "/")).simplify_path()
	return result.trim_suffix("/") if result.length() > 3 else result


## Asset folder names in the order the game lets them override each other
## (see VANILLA_ORDER); mod folders keep their order, after the vanilla ones.
static func by_precedence(names: PackedStringArray) -> Array:
	var ranked: Array = []
	for i in range(names.size()):
		var rank := VANILLA_ORDER.find(names[i].to_lower())
		ranked.append([rank if rank >= 0 else VANILLA_ORDER.size(), i, names[i]])
	ranked.sort()
	return ranked.map(func(entry: Array): return entry[2])


static func domain_name(name: String) -> String:
	return "game" if name.to_lower() in VANILLA or name.to_lower() == "assets" else name.to_lower()


static func texture_folders(path: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var root := normalize(path)
	if not DirAccess.dir_exists_absolute(root):
		return result

	if root.get_file().to_lower() == "textures":
		result.append({"path": root, "domain": domain_name(root.get_base_dir().get_file())})
		return result

	if DirAccess.dir_exists_absolute(root.path_join("assets")):
		root = root.path_join("assets")
	# A vanilla folder (assets/game) also brings its vanilla siblings, in the
	# game's order: a shape opened from assets/game uses survival's textures.
	if root.get_file().to_lower() in VANILLA and DirAccess.dir_exists_absolute(root.get_base_dir()):
		for name in by_precedence(DirAccess.get_directories_at(root.get_base_dir())):
			var sibling := root.get_base_dir().path_join(name).path_join("textures")
			if name.to_lower() in VANILLA and DirAccess.dir_exists_absolute(sibling):
				result.append({"path": sibling, "domain": "game"})
		if not result.is_empty():
			return result
	if DirAccess.dir_exists_absolute(root.path_join("textures")):
		result.append({"path": root.path_join("textures"), "domain": domain_name(root.get_file())})
	for name in by_precedence(DirAccess.get_directories_at(root)):
		var folder := root.path_join(name).path_join("textures")
		if DirAccess.dir_exists_absolute(folder):
			result.append({"path": folder, "domain": domain_name(name)})
	return result


static func _relative_texture(path: String, root: String, domain: String) -> String:
	var prefix := normalize(root) + "/"
	if not path.to_lower().begins_with(prefix.to_lower()):
		return ""

	var relative := path.substr(prefix.length())
	if relative.get_extension().to_lower() == "png":
		relative = relative.get_basename()
	return domain + ":" + relative
