extends RefCounted
## Every editor command in one place: its label, category, shortcut and
## whether it can run now. Menus, the command palette and keyboard shortcuts
## all read from here, so a command added once shows up everywhere with the
## same name and shortcut. Users can rebind shortcuts; the key map is saved in
## user://keymap.cfg and only stores shortcuts that differ from the defaults.

signal shortcuts_changed


## Key names shown as the character they type.
const SYMBOLS := {"Slash": "/", "Comma": ",", "Period": ".", "Minus": "-", "Equal": "="}


class Action:
	var id := ""
	var label := ""
	var category := ""
	var callback: Callable
	## Returns whether the action can run now. Invalid means always.
	var enabled: Callable
	## Key combination shown beside the action, as an InputEventKey.
	var shortcut: InputEventKey
	var default_keys := 0
	## Whether the shortcut may fire now, given the focused control. Invalid
	## means "unless a text field has focus".
	var when: Callable

	func can_run() -> bool:
		return not enabled.is_valid() or bool(enabled.call())

	func shortcut_text() -> String:
		if shortcut == null:
			return ""
		var text := shortcut.as_text_keycode()
		for name in SYMBOLS:
			if text.ends_with(name):
				text = text.trim_suffix(name) + SYMBOLS[name]
		return text

	func keys() -> int:
		return Keys.to_keys(shortcut)


class Keys:
	static func from_keys(keys: int) -> InputEventKey:
		if keys == 0:
			return null
		var event := InputEventKey.new()
		event.keycode = keys & KEY_CODE_MASK
		event.ctrl_pressed = keys & KEY_MASK_CTRL != 0
		event.shift_pressed = keys & KEY_MASK_SHIFT != 0
		event.alt_pressed = keys & KEY_MASK_ALT != 0
		return event

	static func to_keys(event: InputEventKey) -> int:
		if event == null:
			return 0
		var keys := int(event.keycode)
		if event.ctrl_pressed or event.meta_pressed:
			keys |= KEY_MASK_CTRL
		if event.shift_pressed:
			keys |= KEY_MASK_SHIFT
		if event.alt_pressed:
			keys |= KEY_MASK_ALT
		return keys


var actions: Dictionary = {}
var keymap_path := "user://keymap.cfg"
var _order: Array[String] = []


## Registers an action. `keys` is a keycode with modifier masks, such as
## KEY_MASK_CTRL | KEY_S, or 0 for none.
func register(id: String, label: String, category: String, callback: Callable, keys := 0, enabled := Callable(), when := Callable()) -> Action:
	var action := Action.new()
	action.id = id
	action.label = label
	action.category = category
	action.callback = callback
	action.enabled = enabled
	action.when = when
	action.default_keys = keys
	action.shortcut = Keys.from_keys(keys)
	if not actions.has(id):
		_order.append(id)
	actions[id] = action
	return action


func action(id: String) -> Action:
	return actions.get(id)


## Runs an action if it exists and can run now. Returns whether it ran.
func trigger(id: String) -> bool:
	var found: Action = actions.get(id)
	if found == null or not found.can_run():
		return false
	found.callback.call()
	return true


## All actions in registration order.
func all() -> Array[Action]:
	var result: Array[Action] = []
	for id in _order:
		result.append(actions[id])
	return result


## The action whose shortcut is this key press, or "".
func match_event(event: InputEvent) -> String:
	if not event is InputEventKey or not event.pressed or event.echo:
		return ""
	var keys := Keys.to_keys(event)
	for id in _order:
		if actions[id].shortcut != null and actions[id].keys() == keys:
			return id
	return ""


## Whether an action's shortcut may fire with this control focused.
func shortcut_allowed(id: String, focus: Control) -> bool:
	var found: Action = actions.get(id)
	if found == null:
		return false
	if found.when.is_valid():
		return bool(found.when.call(focus))
	return not (focus is LineEdit or focus is TextEdit)


## Rebinds an action (keys 0 clears it). An action already using the same keys
## loses them. Returns the id of that action, or "".
func set_keys(id: String, keys: int) -> String:
	var taken := ""
	if keys != 0:
		for other in _order:
			if other != id and actions[other].keys() == keys:
				actions[other].shortcut = null
				taken = other
	actions[id].shortcut = Keys.from_keys(keys)
	save_keymap()
	shortcuts_changed.emit()
	return taken


func reset_keys() -> void:
	for id in _order:
		actions[id].shortcut = Keys.from_keys(actions[id].default_keys)
	save_keymap()
	shortcuts_changed.emit()


func load_keymap() -> void:
	var config := ConfigFile.new()
	if config.load(keymap_path) != OK:
		return
	for id in config.get_section_keys("shortcuts") if config.has_section("shortcuts") else PackedStringArray():
		if actions.has(id):
			actions[id].shortcut = Keys.from_keys(int(config.get_value("shortcuts", id)))
	shortcuts_changed.emit()


func save_keymap() -> void:
	var config := ConfigFile.new()
	for id in _order:
		if actions[id].keys() != actions[id].default_keys:
			config.set_value("shortcuts", id, actions[id].keys())
	if config.has_section("shortcuts"):
		config.save(keymap_path)
	elif FileAccess.file_exists(keymap_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(keymap_path))


## Actions whose "Category: Label" contains every word of the query, best
## matches first: labels that start with the query, then by registration order.
func search(query: String) -> Array[Action]:
	var words := query.strip_edges().to_lower().split(" ", false)
	var scored: Array = []
	for i in range(_order.size()):
		var found: Action = actions[_order[i]]
		var haystack := (found.category + ": " + found.label).to_lower()
		if words.is_empty() or Array(words).all(func(word: String): return haystack.contains(word)):
			var prefix := not words.is_empty() and found.label.to_lower().begins_with(words[0])
			scored.append([0 if prefix else 1, i, found])
	scored.sort()
	var result: Array[Action] = []
	for entry in scored:
		result.append(entry[2])
	return result
