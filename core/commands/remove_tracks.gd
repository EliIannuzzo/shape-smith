extends "res://core/commands/edit_command.gd"
## Removes the poses of the named elements from every keyframe. Stores only
## the removed poses and where they were, so undo restores the exact JSON.

var names: Array[String] = []
## {clip, key, element, pose, position} for each removed pose, in removal order.
var removed: Array[Dictionary] = []


func _init(target_document, element_names: Array, label := "Remove Tracks") -> void:
	document = target_document
	name = label
	for element_name in element_names:
		names.append(str(element_name))


func do() -> bool:
	removed.clear()
	var animations: Array = Document.animations(document.data)
	for clip_index in range(animations.size()):
		var keys: Array = Document.clip_keyframes(animations[clip_index])
		for key_index in range(keys.size()):
			var key = keys[key_index]
			if not key is Dictionary or not key.get("elements") is Dictionary:
				continue
			for element_name in names:
				if key.elements.has(element_name):
					removed.append({"clip": clip_index, "key": key_index, "element": element_name,
						"pose": key.elements[element_name], "position": key.elements.keys().find(element_name)})
					key.elements.erase(element_name)
	if not removed.is_empty():
		document.animations_changed.emit()
	return true


func undo() -> bool:
	var animations: Array = Document.animations(document.data)
	for i in range(removed.size() - 1, -1, -1):
		var entry: Dictionary = removed[i]
		var key: Dictionary = Document.clip_keyframes(animations[entry.clip])[entry.key]
		Document.insert_key(key.elements, entry.element, entry.pose, entry.position)
	if not removed.is_empty():
		document.animations_changed.emit()
	return true


func byte_size() -> int:
	return var_to_bytes(removed).size()
