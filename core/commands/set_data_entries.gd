extends "res://core/commands/edit_command.gd"
## Sets (or, with Document.ABSENT, removes) entries of a top-level map in the
## shape data, such as "textures" or "textureSizes". Creates the map when
## missing; undo removes it again if it ends up empty.

var data: Dictionary
var key := ""
var after: Dictionary = {}
var notify: Callable
var _before: Dictionary = {}
var _created := false


func _init(shape_data: Dictionary, map_key: String, entries: Dictionary, label := "Change Data", on_change := Callable()) -> void:
	data = shape_data
	key = map_key
	after = entries.duplicate(true)
	name = label
	notify = on_change


func do() -> bool:
	_created = not data.get(key) is Dictionary
	if _created:
		data[key] = {}
	var target: Dictionary = data[key]
	_before.clear()
	for entry in after:
		_before[entry] = Document._copy(target[entry]) if target.has(entry) else Document.ABSENT
		if is_same(after[entry], Document.ABSENT):
			target.erase(entry)
		else:
			target[entry] = Document._copy(after[entry])
	if notify.is_valid():
		notify.call()
	return true


func undo() -> bool:
	if not data.get(key) is Dictionary:
		return false
	var target: Dictionary = data[key]
	for entry in _before:
		if is_same(_before[entry], Document.ABSENT):
			target.erase(entry)
		else:
			target[entry] = _before[entry]
	if _created and target.is_empty():
		data.erase(key)
	if notify.is_valid():
		notify.call()
	return true


func byte_size() -> int:
	return var_to_bytes(after).size() + var_to_bytes(_before).size()
