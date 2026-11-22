extends AcceptDialog
## File → Preferences (Ctrl+,): autosave interval, theme and layout, and
## keyboard shortcuts. Select a command and press Change, then the new keys;
## Escape cancels, Backspace clears. Keys already used by another command move
## to the new one.

static var Palette = preload("res://ui/theme/editor_palette.tres")

var app
var tabs: TabContainer
var interval: SpinBox
var shortcuts: Tree
var change_button: Button
var note: Label
var capturing := ""


func _init() -> void:
	name = "Preferences"
	title = "Preferences"
	ok_button_text = "Close"
	min_size = Vector2i(560, 480)
	tabs = TabContainer.new()
	add_child(tabs)
	tabs.add_child(_general())
	tabs.add_child(_shortcuts())
	tabs.set_tab_title(0, "General")
	tabs.set_tab_title(1, "Shortcuts")


func open(editor, tab := "") -> void:
	app = editor
	interval.set_value_no_signal(app.autosave.interval)
	refresh_shortcuts()
	note.text = ""
	if not tab.is_empty():
		for i in range(tabs.get_tab_count()):
			if tabs.get_tab_title(i) == tab:
				tabs.current_tab = i
	popup_centered(Vector2i(600, 520))


func _general() -> Control:
	var layout := VBoxContainer.new()
	layout.name = "General"
	var row := HBoxContainer.new()
	layout.add_child(row)
	var label := Label.new()
	label.text = "Autosave unsaved edits every"
	row.add_child(label)
	interval = SpinBox.new()
	interval.min_value = 10
	interval.max_value = 3600
	interval.step = 10
	interval.suffix = "s"
	interval.value_changed.connect(func(value: float):
		if app != null:
			app.autosave.set_interval(value))
	row.add_child(interval)
	for entry in [["Theme…", func(): app.theme_editor.open()], ["Reset Layout", func(): app.reset_layout()]]:
		var button := Button.new()
		button.text = entry[0]
		button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		button.pressed.connect(entry[1])
		layout.add_child(button)
	return layout


func _shortcuts() -> Control:
	var layout := VBoxContainer.new()
	layout.name = "Shortcuts"
	shortcuts = Tree.new()
	shortcuts.columns = 2
	shortcuts.hide_root = true
	shortcuts.column_titles_visible = true
	shortcuts.set_column_title(0, "Command")
	shortcuts.set_column_title(1, "Shortcut")
	shortcuts.set_column_expand_ratio(0, 3)
	shortcuts.size_flags_vertical = Control.SIZE_EXPAND_FILL
	shortcuts.item_activated.connect(begin_capture)
	layout.add_child(shortcuts)
	var row := HBoxContainer.new()
	layout.add_child(row)
	change_button = Button.new()
	change_button.text = "Change…"
	change_button.pressed.connect(begin_capture)
	row.add_child(change_button)
	var reset := Button.new()
	reset.text = "Reset All"
	reset.pressed.connect(func():
		app.actions.reset_keys()
		refresh_shortcuts()
		note.text = "Every shortcut is back to its default.")
	row.add_child(reset)
	note = Label.new()
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(note)
	return layout


func refresh_shortcuts() -> void:
	shortcuts.clear()
	var root := shortcuts.create_item()
	for found in app.actions.all():
		var item := shortcuts.create_item(root)
		item.set_text(0, "%s: %s" % [found.category, found.label])
		item.set_text(1, found.shortcut_text())
		item.set_metadata(0, found.id)
		if found.id == capturing:
			item.set_text(1, "Press keys…")
			item.set_custom_color(1, Palette.accent)


func begin_capture() -> void:
	var selected := shortcuts.get_selected()
	if selected == null:
		note.text = "Select a command first."
		return
	capturing = selected.get_metadata(0)
	note.text = "Press the new shortcut. Escape cancels; Backspace clears it."
	refresh_shortcuts()


## Records the next key press for the command being changed.
func capture(event: InputEventKey) -> bool:
	if capturing.is_empty() or not event.pressed or event.echo:
		return false
	if event.keycode in [KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META]:
		return true
	var id := capturing
	capturing = ""
	if event.keycode == KEY_ESCAPE:
		note.text = ""
	else:
		var keys: int = 0 if event.keycode == KEY_BACKSPACE else app.actions.Keys.to_keys(event)
		var taken: String = app.actions.set_keys(id, keys)
		var label: String = app.actions.action(id).label
		note.text = ("%s is now %s." % [label, app.actions.action(id).shortcut_text()]) if keys != 0 else "%s has no shortcut." % label
		if not taken.is_empty():
			note.text += " It was used by %s, which now has none." % app.actions.action(taken).label
	refresh_shortcuts()
	return true


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and capture(event):
		set_input_as_handled()
