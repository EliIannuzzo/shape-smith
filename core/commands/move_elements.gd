extends "res://core/commands/edit_command.gd"
## Reparents and reorders elements. Transform compensation (keep world
## placement) is a separate SetElementFields step in the same CompositeCommand.

## Each entry: {uid, parent, index}. index counts the new siblings after the
## element has left its old place; -1 appends.
var entries: Array[Dictionary] = []
var _previous: Array[Dictionary] = []


func _init(target_document, moves: Array, label := "Move Element") -> void:
	document = target_document
	name = label
	for move in moves:
		entries.append({"uid": str(move.uid), "parent": str(move.get("parent", Document.ROOT)), "index": int(move.get("index", -1))})


func do() -> bool:
	for entry in entries:
		if not document.has(entry.uid) or (entry.parent != Document.ROOT and not document.has(entry.parent)):
			return false
		if entry.parent == entry.uid or document.is_ancestor(entry.uid, entry.parent):
			return false
	_previous.clear()
	for entry in entries:
		var created: bool = entry.parent != Document.ROOT and not document.source(entry.parent).get("children") is Array
		var siblings: int = document.children_of(entry.parent).size()
		if document.parent_of(entry.uid) == entry.parent:
			siblings -= 1
		var index: int = siblings if entry.index < 0 else mini(entry.index, siblings)
		var old: Dictionary = document.move(entry.uid, entry.parent, index)
		old.uid = entry.uid
		old.created_children = created
		old.target = entry.parent
		_previous.append(old)
	return true


func undo() -> bool:
	for i in range(_previous.size() - 1, -1, -1):
		var old: Dictionary = _previous[i]
		if not document.has(old.uid):
			return false
		document.move(old.uid, old.parent, old.index)
		if old.created_children:
			document.drop_empty_children(old.target)
	return true
