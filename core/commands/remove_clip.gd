extends "res://core/commands/edit_command.gd"
## Removes one animation clip; undo puts the same clip object back.

var data: Dictionary
var index := -1
var notify: Callable
var view_after: Dictionary
var view_before: Dictionary
var _removed: Variant = null


func _init(shape_data: Dictionary, at: int, label: String, on_change := Callable(), next_view := {}, previous_view := {}) -> void:
	data = shape_data
	index = at
	name = label
	notify = on_change
	view_after = next_view
	view_before = previous_view


func do() -> bool:
	var clips: Array = Document.animations(data)
	if index < 0 or index >= clips.size():
		return false
	_removed = clips[index]
	clips.remove_at(index)
	if notify.is_valid():
		notify.call(view_after)
	return true


func undo() -> bool:
	if not data.get("animations") is Array:
		return false
	data.animations.insert(index, _removed)
	if notify.is_valid():
		notify.call(view_before)
	return true


func byte_size() -> int:
	return var_to_bytes(_removed).size()
