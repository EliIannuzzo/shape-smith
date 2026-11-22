extends "res://core/commands/edit_command.gd"
## Renames an element's poses in every keyframe of every animation, keeping
## each keyframe's key order so undo restores the JSON exactly.

var from := ""
var to := ""


func _init(target_document, old_name: String, new_name: String, label := "Rename Track") -> void:
	document = target_document
	from = old_name
	to = new_name
	name = label


func do() -> bool:
	return _rename(from, to)


func undo() -> bool:
	return _rename(to, from)


func _rename(old_name: String, new_name: String) -> bool:
	var keys := Document.keyframes(document.data)
	# A stray pose already using the new name would be overwritten.
	for key in keys:
		if key.elements.has(old_name) and key.elements.has(new_name):
			return false
	var changed := false
	for key in keys:
		if key.elements.has(old_name):
			Document.rename_key(key.elements, old_name, new_name)
			changed = true
	if changed:
		document.animations_changed.emit()
	return true
