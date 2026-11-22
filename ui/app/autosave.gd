extends Node
## Autosave, crash recovery and rolling backups.
##
## Every `interval` seconds, unsaved edits are written to user://autosave/ as a
## working file plus a small .meta.json naming the original file. A clean exit,
## a save, or opening another file removes them, so any autosave left at launch
## means the editor stopped unexpectedly and can be offered for recovery.
##
## Before a save replaces a file, the old version is copied to
## user://backups/<file>-<hash>/, keeping the newest BACKUPS copies.

signal autosaved(path: String)

const BACKUPS := 5
const DEFAULT_INTERVAL := 120.0
var directory := "user://autosave"
var backup_directory := "user://backups"
var settings_path := "user://autosave.cfg"
var interval := DEFAULT_INTERVAL
## Returns {"data": Dictionary, "source": String, "working": bool} for the
## current document, or {} when there is nothing to save.
var snapshot: Callable
## Returns whether the document has unsaved edits.
var dirty: Callable
var session := ""
var timer: Timer


func _ready() -> void:
	var config := ConfigFile.new()
	if config.load(settings_path) == OK:
		interval = maxf(float(config.get_value("autosave", "interval_seconds", DEFAULT_INTERVAL)), 10.0)
	session = "%d-%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	timer = Timer.new()
	timer.wait_time = interval
	timer.timeout.connect(autosave_now)
	add_child(timer)
	timer.start()


## Changes how often autosave runs and remembers it in autosave.cfg.
func set_interval(seconds: float) -> void:
	interval = maxf(seconds, 10.0)
	if timer != null:
		timer.wait_time = interval
		timer.start()
	var config := ConfigFile.new()
	config.load(settings_path)
	config.set_value("autosave", "interval_seconds", interval)
	config.save(settings_path)


## Writes the autosave if there are unsaved edits. Returns the file written,
## or "" when nothing was saved.
func autosave_now() -> String:
	if not dirty.is_valid() or not dirty.call() or not snapshot.is_valid():
		return ""
	var state: Dictionary = snapshot.call()
	if state.is_empty():
		return ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var base := (str(state.source).get_file().get_basename().trim_suffix(".shapesmith") if not str(state.source).is_empty() else "Untitled").validate_filename()
	var path := directory.path_join("%s-%s.shapesmith.json" % [base, session])
	var text := preload("res://core/model/shape_serializer.gd").stringify(state.data)
	if not _write(path, text):
		return ""
	_write(_meta_path(path), JSON.stringify({"source": state.source, "working": state.working, "time": Time.get_datetime_string_from_system()}))
	autosaved.emit(path)
	return path


## Removes this session's autosave (after a save, a new document, or a clean exit).
func discard_session() -> void:
	for entry in pending(true):
		if entry.path.contains(session):
			discard(entry.path)


func discard(path: String) -> void:
	for file in [path, _meta_path(path)]:
		if FileAccess.file_exists(file):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


## Autosaves left by earlier sessions, newest first:
## [{path, source, working, time}].
func pending(include_session := false) -> Array:
	var result: Array = []
	var dir := DirAccess.open(directory)
	if dir == null:
		return result
	for file in dir.get_files():
		if not file.ends_with(".shapesmith.json") or (not include_session and file.contains(session)):
			continue
		var path := directory.path_join(file)
		var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(_meta_path(path))) if FileAccess.file_exists(_meta_path(path)) else {}
		meta = meta if meta is Dictionary else {}
		result.append({"path": path, "source": str(meta.get("source", "")), "working": bool(meta.get("working", false)), "time": str(meta.get("time", ""))})
	result.sort_custom(func(a, b): return a.time > b.time)
	return result


## Copies the file about to be replaced into its backup folder and keeps
## the newest BACKUPS copies. Returns the backup path, or "" if none was made.
func back_up(destination: String) -> String:
	if not FileAccess.file_exists(destination):
		return ""
	var absolute := ProjectSettings.globalize_path(destination)
	var folder := backup_directory.path_join("%s-%s" % [absolute.get_file().validate_filename(), str(absolute.hash()).trim_prefix("-")])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := folder.path_join("%s-%d.json" % [stamp, Time.get_ticks_usec()])
	if DirAccess.copy_absolute(absolute, ProjectSettings.globalize_path(path)) != OK:
		return ""
	var files := Array(DirAccess.get_files_at(folder))
	files.sort()
	while files.size() > BACKUPS:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(files.pop_front())))
	return path


func backups_for(destination: String) -> PackedStringArray:
	var absolute := ProjectSettings.globalize_path(destination)
	var folder := backup_directory.path_join("%s-%s" % [absolute.get_file().validate_filename(), str(absolute.hash()).trim_prefix("-")])
	return DirAccess.get_files_at(folder) if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)) else PackedStringArray()


func _meta_path(path: String) -> String:
	return path.trim_suffix(".shapesmith.json") + ".meta.json"


func _write(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true
