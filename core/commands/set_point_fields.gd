extends "res://core/commands/edit_command.gd"
## Sets (or, with Document.ABSENT, removes) fields on one attachment point.

var uid := ""
var after: Dictionary = {}
var before: Dictionary = {}
var _captured := false


func _init(target_document, point_uid: String, fields: Dictionary, label := "Edit Attachment Point", key := "") -> void:
	document = target_document
	uid = point_uid
	after = fields.duplicate(true)
	name = label
	merge_key = key


func do() -> bool:
	if document.point(uid) == null:
		return false
	var previous: Dictionary = document.set_point_fields(uid, after)
	if not _captured:
		before = previous
		_captured = true
	return true


func undo() -> bool:
	if document.point(uid) == null:
		return false
	document.set_point_fields(uid, before)
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
