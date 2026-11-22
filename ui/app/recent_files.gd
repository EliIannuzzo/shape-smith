extends RefCounted
## The most recently opened or saved shape files, newest first, kept in
## user:// so they survive restarts. Settings never go into the shape file.

signal changed

const LIMIT := 10
var config_path := "user://recent_files.cfg"
var paths: PackedStringArray = []


func load_config() -> void:
	var config := ConfigFile.new()
	paths = PackedStringArray(config.get_value("recent", "paths", [])) if config.load(config_path) == OK else PackedStringArray()
	changed.emit()


func add(path: String) -> void:
	if path.is_empty():
		return
	var absolute := ProjectSettings.globalize_path(path)
	var next := PackedStringArray([absolute])
	for existing in paths:
		if existing != absolute and next.size() < LIMIT:
			next.append(existing)
	_store(next)


func remove(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	var next := PackedStringArray()
	for existing in paths:
		if existing != absolute:
			next.append(existing)
	_store(next)


func clear() -> void:
	_store(PackedStringArray())


func _store(next: PackedStringArray) -> void:
	if next == paths:
		return
	paths = next
	var config := ConfigFile.new()
	config.set_value("recent", "paths", Array(paths))
	config.save(config_path)
	changed.emit()
