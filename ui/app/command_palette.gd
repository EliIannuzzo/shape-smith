extends PopupPanel
## Ctrl+Shift+P: type to find any editor action, then press Enter. Lists every
## action with its shortcut; actions that cannot run now are greyed out.

static var Palette = preload("res://ui/theme/editor_palette.tres")
const WIDTH := 520
const ROWS := 12

var registry
var query: LineEdit
var results: ItemList
var _shown: Array = []


func _init() -> void:
	name = "CommandPalette"
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.chrome
	style.border_color = Palette.border_light
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(8)
	add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	add_child(layout)
	query = LineEdit.new()
	query.placeholder_text = "Type a command…"
	query.clear_button_enabled = true
	layout.add_child(query)
	results = ItemList.new()
	results.custom_minimum_size = Vector2(WIDTH, ROWS * 26)
	results.select_mode = ItemList.SELECT_SINGLE
	results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var list_style := StyleBoxFlat.new()
	list_style.bg_color = Palette.surface
	list_style.set_content_margin_all(4)
	results.add_theme_stylebox_override("panel", list_style)
	layout.add_child(results)
	query.text_changed.connect(func(_text: String): refresh())
	query.text_submitted.connect(func(_text: String): run_selected())
	query.gui_input.connect(_on_query_input)
	results.item_activated.connect(func(_index: int): run_selected())


func open(action_registry) -> void:
	registry = action_registry
	query.text = ""
	refresh()
	popup_centered(Vector2i(WIDTH + 16, 0))
	query.grab_focus()


func refresh() -> void:
	results.clear()
	_shown = registry.search(query.text) if registry != null else []
	for found in _shown:
		var shortcut: String = found.shortcut_text()
		var index := results.add_item("%s: %s%s" % [found.category, found.label, ("    " + shortcut) if not shortcut.is_empty() else ""])
		results.set_item_metadata(index, found.id)
		if not found.can_run():
			results.set_item_custom_fg_color(index, Palette.disabled)
	if results.item_count > 0:
		results.select(_first_enabled())


func _first_enabled() -> int:
	for i in range(_shown.size()):
		if _shown[i].can_run():
			return i
	return 0


## Runs the highlighted action and closes the palette. Returns whether it ran.
func run_selected() -> bool:
	var selected := results.get_selected_items()
	if selected.is_empty():
		return false
	var id: String = results.get_item_metadata(selected[0])
	hide()
	return registry.trigger(id)


func _on_query_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or results.item_count == 0:
		return
	var step := 0
	if event.keycode == KEY_DOWN:
		step = 1
	elif event.keycode == KEY_UP:
		step = -1
	if step != 0:
		var current := results.get_selected_items()
		var index := posmod((current[0] if not current.is_empty() else -step) + step, results.item_count)
		results.select(index)
		results.ensure_current_is_visible()
		query.accept_event()
