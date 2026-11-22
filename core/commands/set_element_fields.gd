extends "res://core/commands/edit_command.gd"
## Sets (or, with Document.ABSENT, removes) fields on one element.

var uid := ""
var after: Dictionary = {}
var before: Dictionary = {}
var _captured := false


func _init(target_document, target: String, fields: Dictionary, label := "Change Element", key := "") -> void:
	document = target_document
	uid = target
	after = fields.duplicate(true)
	name = label
	merge_key = key


func do() -> bool:
	if not document.has(uid):
		return false
	var previous: Dictionary = document.set_fields(uid, after)
	# Keep the values from the first run; a redo must restore those, not the
	# values the undo just wrote back.
	if not _captured:
		before = previous
		_captured = true
	return true


func undo() -> bool:
	if not document.has(uid):
		return false
	document.set_fields(uid, before)
	return true


func merge_with(next) -> bool:
	if next.get_script() != get_script() or next.uid != uid:
		return false
	for key in next.after:
		after[key] = next.after[key]
		if not before.has(key):
			before[key] = next.before[key]
	return true


func byte_size() -> int:
	return var_to_bytes(before).size() + var_to_bytes(after).size()
