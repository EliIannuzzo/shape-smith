extends "res://core/commands/edit_command.gd"
## Writes element poses into keyframes, creating keyframes (in frame order)
## where a clip has none at that frame. Undo removes exactly what was added.

## Each entry: {clip, frame, element, pose}. clip is an index into animations.
var poses: Array[Dictionary] = []
var _applied: Array[Dictionary] = []


func _init(target_document, entries: Array, label := "Add Poses") -> void:
	document = target_document
	name = label
	for entry in entries:
		poses.append({"clip": int(entry.clip), "frame": entry.frame, "element": str(entry.element), "pose": entry.pose.duplicate(true)})


func do() -> bool:
	var animations: Array = Document.animations(document.data)
	for entry in poses:
		if entry.clip < 0 or entry.clip >= animations.size() or not animations[entry.clip] is Dictionary or not animations[entry.clip].get("keyframes") is Array:
			return false
	_applied.clear()
	for entry in poses:
		var keys: Array = animations[entry.clip].keyframes
		var record := {"clip": entry.clip, "element": entry.element, "created_key": false, "created_elements": false, "previous": Document.ABSENT}
		var key: Dictionary = {}
		var insert_at := keys.size()
		for i in range(keys.size()):
			if keys[i] is Dictionary and keys[i].get("frame") == entry.frame:
				key = keys[i]
				break
			if keys[i] is Dictionary and float(keys[i].get("frame", 0)) > float(entry.frame) and insert_at == keys.size():
				insert_at = i
		if key.is_empty():
			key = {"frame": entry.frame, "elements": {}}
			keys.insert(insert_at, key)
			record.created_key = true
		elif not key.get("elements") is Dictionary:
			key.elements = {}
			record.created_elements = true
		if key.elements.has(entry.element):
			record.previous = key.elements[entry.element]
		key.elements[entry.element] = entry.pose.duplicate(true)
		record.key = key
		_applied.append(record)
	if not _applied.is_empty():
		document.animations_changed.emit()
	return true


func undo() -> bool:
	var animations: Array = Document.animations(document.data)
	for i in range(_applied.size() - 1, -1, -1):
		var record: Dictionary = _applied[i]
		var key: Dictionary = record.key
		if record.created_key:
			var keys: Array = animations[record.clip].keyframes
			for index in range(keys.size()):
				if is_same(keys[index], key):
					keys.remove_at(index)
					break
			continue
		if is_same(record.previous, Document.ABSENT):
			key.elements.erase(record.element)
		else:
			key.elements[record.element] = record.previous
		if record.created_elements and key.elements.is_empty():
			key.erase("elements")
	if not _applied.is_empty():
		document.animations_changed.emit()
	return true


func byte_size() -> int:
	return var_to_bytes(poses).size()
