extends "res://core/commands/edit_command.gd"
## Inserts an animation clip, creating the "animations" array if the shape has
## none; undo removes the clip, and the array if this command created it.

var data: Dictionary
var index := -1
var clip: Dictionary
var notify: Callable
var view_after: Dictionary
var view_before: Dictionary
var _created := false


func _init(shape_data: Dictionary, at: int, value: Dictionary, label: String, on_change := Callable(), next_view := {}, previous_view := {}) -> void:
	data = shape_data
	index = at
	clip = value
	name = label
	notify = on_change
	view_after = next_view
	view_before = previous_view


func do() -> bool:
	_created = not data.get("animations") is Array
	if _created:
		data.animations = []
	var clips: Array = data.animations
	index = clampi(index, 0, clips.size())
	clips.insert(index, clip.duplicate(true))
	if notify.is_valid():
		notify.call(view_after)
	return true


func undo() -> bool:
	var clips: Array = Document.animations(data)
	if index < 0 or index >= clips.size():
		return false
	clips.remove_at(index)
	if _created and clips.is_empty():
		data.erase("animations")
	if notify.is_valid():
		notify.call(view_before)
	return true


func byte_size() -> int:
	return var_to_bytes(clip).size()
