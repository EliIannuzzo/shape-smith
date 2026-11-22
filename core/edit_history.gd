extends Node

signal changed
signal flush_pending
signal failed(action: String)
const LIMIT := 200
## Oldest steps are dropped once commands hold more than this many bytes.
## Legacy callable steps report no size, so only commands count toward it.
const BYTE_BUDGET := 64 * 1024 * 1024
const MERGE_WINDOW_MS := 650
var actions: Array[Dictionary] = []
var bytes := 0
var cursor := 0
var busy := false
var revision := 0
var saved_revision := 0
var next_revision := 0
var merge_barrier := 0


func perform(name: String, apply: Callable, revert: Callable, merge_key := "", document := true) -> bool:
	if busy:
		return false

	busy = true
	var result: Variant = apply.call() if apply.is_valid() else false
	busy = false
	if result is bool and not result:
		failed.emit(name)
		return false

	_append(name, apply, revert, merge_key, document)
	return true


func record_applied(name: String, apply: Callable, revert: Callable, document := true) -> void:
	if not busy:
		_append(name, apply, revert, "", document)


## Runs a command object (see core/commands/) and records it.
func execute(command, document := true) -> bool:
	if busy:
		return false

	busy = true
	var applied: bool = command.do()
	busy = false
	if not applied:
		failed.emit(command.name)
		return false

	_append(command.name, Callable(), Callable(), command.merge_key, document, command)
	return true


func _append(name: String, apply: Callable, revert: Callable, merge_key: String, document: bool, command = null) -> void:
	var now := Time.get_ticks_msec()
	var before := revision
	if document:
		next_revision += 1
		revision = next_revision
	if cursor == actions.size() and cursor > 0 and not merge_key.is_empty():
		var previous: Dictionary = actions.back()
		if previous.merge_key == merge_key and previous.barrier == merge_barrier and now - previous.time <= MERGE_WINDOW_MS and _merge(previous, apply, command):
			previous.after = revision
			previous.time = now
			changed.emit()
			return

	_truncate(cursor)
	var size: int = command.byte_size() if command != null else 0
	actions.append({"name": name, "apply": apply, "revert": revert, "command": command, "bytes": size,
		"before": before, "after": revision, "merge_key": merge_key, "time": now, "barrier": merge_barrier})
	bytes += size
	cursor += 1
	while actions.size() > LIMIT or (bytes > BYTE_BUDGET and actions.size() > 1):
		bytes -= actions.pop_front().bytes
		cursor -= 1
	changed.emit()


func _merge(previous: Dictionary, apply: Callable, command) -> bool:
	if command == null and previous.command == null:
		previous.apply = apply
		return true
	if command == null or previous.command == null or not previous.command.merge_with(command):
		return false
	bytes -= previous.bytes
	previous.bytes = previous.command.byte_size()
	bytes += previous.bytes
	return true


func _truncate(size: int) -> void:
	for i in range(size, actions.size()):
		bytes -= actions[i].bytes
	actions.resize(size)


func undo() -> bool:
	if busy:
		return false

	flush_pending.emit()
	if cursor == 0:
		return false

	var action: Dictionary = actions[cursor - 1]
	if not _replay(action, false):
		return false

	cursor -= 1
	revision = action.before
	break_merge()
	changed.emit()
	return true


func redo() -> bool:
	if busy:
		return false

	flush_pending.emit()
	if cursor >= actions.size():
		return false

	var action: Dictionary = actions[cursor]
	if not _replay(action, true):
		return false

	cursor += 1
	revision = action.after
	break_merge()
	changed.emit()
	return true


func _replay(action: Dictionary, forward: bool) -> bool:
	busy = true
	var result: Variant
	if action.command != null:
		result = action.command.do() if forward else action.command.undo()
	else:
		var operation: Callable = action.apply if forward else action.revert
		result = operation.call() if operation.is_valid() else false
	busy = false
	if result is bool and not result:
		failed.emit(action.name)
		return false

	return true


func break_merge() -> void:
	merge_barrier += 1


func clear() -> void:
	actions.clear()
	bytes = 0
	cursor = 0
	revision = 0
	saved_revision = 0
	next_revision = 0
	break_merge()
	changed.emit()


func mark_saved() -> void:
	saved_revision = revision
	break_merge()
	changed.emit()


## Marks the document as having unsaved changes with no undo step to show for
## them (after recovering an autosave, for example).
func mark_unsaved() -> void:
	saved_revision = -1
	changed.emit()


func is_dirty() -> bool:
	return revision != saved_revision


func undo_name() -> String:
	return actions[cursor - 1].name if cursor > 0 else ""


func redo_name() -> String:
	return actions[cursor].name if cursor < actions.size() else ""


func handle_shortcut(event: InputEvent, viewport: Viewport) -> bool:
	if not event is InputEventKey or not event.pressed or event.echo or event.alt_pressed:
		return false

	if not event.ctrl_pressed and not event.meta_pressed:
		return false

	if event.keycode == KEY_Z:
		redo() if event.shift_pressed else undo()
	elif event.keycode == KEY_Y:
		redo()
	else:
		return false

	viewport.set_input_as_handled()
	return true


func _exit_tree() -> void:
	# Release captured models/resources before the application is destroyed.
	actions.clear()
