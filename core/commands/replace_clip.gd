extends "res://core/commands/edit_command.gd"
## Replaces one animation clip with an edited copy. Stores the old clip object
## and the new one, never the other clips.
##
## `notify` (optional) is called with view_after on do and view_before on undo,
## so the animation panel can restore the clip, frame and key selection.

var data: Dictionary
var index := -1
var after: Dictionary
var before: Dictionary = {}
var notify: Callable
var view_after: Dictionary
var view_before: Dictionary
var _captured := false


func _init(shape_data: Dictionary, clip_index: int, clip: Dictionary, label: String, on_change := Callable(), next_view := {}, previous_view := {}) -> void:
	data = shape_data
	index = clip_index
	after = clip
	name = label
	notify = on_change
	view_after = next_view
	view_before = previous_view


func do() -> bool:
	var clips: Array = Document.animations(data)
	if index < 0 or index >= clips.size():
		return false
	if not _captured:
		before = clips[index]
		_captured = true
	clips[index] = after.duplicate(true)
	if notify.is_valid():
		notify.call(view_after)
	return true


func undo() -> bool:
	var clips: Array = Document.animations(data)
	if index < 0 or index >= clips.size():
		return false
	clips[index] = before
	if notify.is_valid():
		notify.call(view_before)
	return true


func byte_size() -> int:
	return var_to_bytes(before).size() + var_to_bytes(after).size()
