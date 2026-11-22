extends "res://core/commands/edit_command.gd"
## Deletes elements with their subtrees. Selecting a parent and its child
## deletes the subtree once.

var uids: Array[String] = []
## Snapshots from Document.remove(), in removal order.
var removed: Array[Dictionary] = []


func _init(target_document, targets: Array, label := "Delete Element") -> void:
	document = target_document
	name = label
	for uid in targets:
		uids.append(str(uid))


func do() -> bool:
	var targets: Array[String] = []
	for uid in uids:
		if not document.has(uid):
			return false
		if not uids.any(func(other: String): return other != uid and document.is_ancestor(other, uid)) and uid not in targets:
			targets.append(uid)
	# Remove later elements first, so each snapshot's index stays valid when
	# undo re-inserts them in the reverse order.
	var order: Array[String] = document.ordered()
	targets.sort_custom(func(a: String, b: String): return order.find(a) > order.find(b))
	removed.clear()
	for uid in targets:
		removed.append(document.remove(uid))
	return true


func undo() -> bool:
	for i in range(removed.size() - 1, -1, -1):
		var snapshot: Dictionary = removed[i]
		if snapshot.parent != Document.ROOT and not document.has(snapshot.parent):
			return false
		document.insert(snapshot.parent, snapshot.index, snapshot.source, snapshot.uids, snapshot.point_uids)
	return true


func byte_size() -> int:
	var total := 0
	for snapshot in removed:
		total += var_to_bytes(snapshot.source).size()
	return total
