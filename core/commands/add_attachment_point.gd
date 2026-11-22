extends "res://core/commands/edit_command.gd"
## Adds an attachment point to an element. Undo removes it, and removes the
## attachment point array too if this command created it.

var owner := ""
var source: Dictionary = {}
var index := -1
var uid := ""
var _created_array := false


func _init(target_document, owner_uid: String, point_source: Dictionary, label := "Add Attachment Point", at := -1) -> void:
	document = target_document
	owner = owner_uid
	source = point_source
	index = at
	name = label


func do() -> bool:
	if not document.has(owner):
		return false
	var owner_source: Dictionary = document.source(owner)
	_created_array = not owner_source.get(Document._point_key(owner_source)) is Array
	uid = document.insert_point(owner, index, source, uid)
	return true


func undo() -> bool:
	if document.point(uid) == null:
		return false
	document.remove_point(uid, _created_array)
	return true


func byte_size() -> int:
	return var_to_bytes(source).size()
