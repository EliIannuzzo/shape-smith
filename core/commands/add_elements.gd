extends "res://core/commands/edit_command.gd"
## Inserts one or more element subtrees. Parents must exist before the command.

## Each entry: {parent, index, source[, uid]}. do() adds uid, uids and
## point_uids so a redo restores the same ids. Pass uid (Document.new_uid())
## when later steps of the same command must refer to the new element.
var entries: Array[Dictionary] = []


func _init(target_document, items: Array, label := "Add Element") -> void:
	document = target_document
	name = label
	for item in items:
		entries.append({"parent": item.get("parent", Document.ROOT), "index": int(item.get("index", -1)),
			"source": item.source, "uids": [item.uid] if item.has("uid") else [], "point_uids": []})


## The uids of the inserted elements, valid after do().
func added() -> Array[String]:
	var result: Array[String] = []
	for entry in entries:
		result.append(entry.get("uid", ""))
	return result


func do() -> bool:
	for entry in entries:
		if entry.parent != Document.ROOT and not document.has(entry.parent):
			return false
	for entry in entries:
		var siblings: int = document.children_of(entry.parent).size()
		var index: int = siblings if entry.index < 0 else entry.index
		entry.created_children = entry.parent != Document.ROOT and not document.source(entry.parent).get("children") is Array
		entry.uid = document.insert(entry.parent, index, entry.source, entry.uids, entry.point_uids)
		entry.uids = [entry.uid] + Array(document.ordered(entry.uid))
		entry.point_uids = []
		for uid in entry.uids:
			entry.point_uids.append_array(document.element(uid).points)
	return true


func undo() -> bool:
	for i in range(entries.size() - 1, -1, -1):
		var entry: Dictionary = entries[i]
		if not document.has(entry.get("uid", "")):
			return false
		document.remove(entry.uid, entry.created_children)
	return true


func byte_size() -> int:
	var total := 0
	for entry in entries:
		total += var_to_bytes(entry.source).size()
	return total
