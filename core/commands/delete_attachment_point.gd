extends "res://core/commands/edit_command.gd"
## Deletes one attachment point. Undo puts the same point back at its index,
## with the same uid.

var uid := ""
var _removed: Dictionary = {}


func _init(target_document, point_uid: String, label := "Delete Attachment Point") -> void:
	document = target_document
	uid = point_uid
	name = label


func do() -> bool:
	if document.point(uid) == null:
		return false
	_removed = document.remove_point(uid)
	return true


func undo() -> bool:
	if _removed.is_empty() or not document.has(_removed.owner):
		return false
	document.insert_point(_removed.owner, _removed.index, _removed.source, uid)
	return true


func byte_size() -> int:
	return var_to_bytes(_removed.get("source", {})).size()
