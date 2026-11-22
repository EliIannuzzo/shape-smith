extends Button
## A dropdown for long lists: the button shows the chosen item; pressing it
## opens a popup with a search box and the items, in titled groups (such as
## attachment points first, then elements). Typing narrows the list; Enter
## picks the first match. Mirrors the parts of OptionButton's API the editor
## uses (add_item, select, selected, item_count, item text and metadata,
## disabled items, item_selected), so it can stand in for one.

signal item_selected(index: int)

static var Palette = preload("res://ui/theme/editor_palette.tres")
const POPUP_SIZE := Vector2i(340, 380)

## [{text, group, disabled, metadata}].
var items: Array = []
var selected := -1
var item_count: int:
	get:
		return items.size()
var placeholder := "Search"
var popup: PopupPanel
var search: LineEdit
var tree: Tree


func _init() -> void:
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	clip_text = true
	icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	pressed.connect(open)


func _ready() -> void:
	icon = get_theme_icon("arrow", "OptionButton")
	popup = PopupPanel.new()
	add_child(popup)
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.chrome
	style.border_color = Palette.border_light
	style.set_border_width_all(1)
	style.set_content_margin_all(6)
	popup.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	popup.add_child(box)
	search = LineEdit.new()
	search.placeholder_text = placeholder
	search.clear_button_enabled = true
	search.text_changed.connect(func(_text: String): _fill())
	search.text_submitted.connect(func(_text: String): _pick_first())
	box.add_child(search)
	tree = Tree.new()
	tree.hide_root = true
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.item_selected.connect(_on_tree_selected)
	box.add_child(tree)


func clear() -> void:
	items.clear()
	selected = -1
	text = ""


## Adds an item; `group` puts it under that heading in the popup.
func add_item(item_text: String, group := "") -> void:
	items.append({"text": item_text, "group": group, "disabled": false, "metadata": null})


func set_item_disabled(index: int, value: bool) -> void:
	if index >= 0 and index < items.size():
		items[index].disabled = value


func is_item_disabled(index: int) -> bool:
	return index >= 0 and index < items.size() and items[index].disabled


func set_item_metadata(index: int, value: Variant) -> void:
	if index >= 0 and index < items.size():
		items[index].metadata = value


func get_item_metadata(index: int) -> Variant:
	return items[index].metadata if index >= 0 and index < items.size() else null


func get_item_text(index: int) -> String:
	return items[index].text if index >= 0 and index < items.size() else ""


func get_item_group(index: int) -> String:
	return items[index].group if index >= 0 and index < items.size() else ""


## Shows an item as chosen, without emitting item_selected (like OptionButton).
func select(index: int) -> void:
	selected = index if index >= 0 and index < items.size() else -1
	text = get_item_text(selected)
	tooltip_text = ("%s · %s" % [get_item_group(selected).trim_suffix("s"), text]) if not get_item_group(selected).is_empty() else text


func open() -> void:
	if popup == null:
		return
	search.text = ""
	_fill()
	var width := maxi(POPUP_SIZE.x, int(size.x))
	popup.popup(Rect2i(Vector2i(_below()), Vector2i(width, POPUP_SIZE.y)))
	search.grab_focus.call_deferred()


## Just under the button, in the coordinates the popup is placed in: each
## embedded window (a dialog) adds its position; a popup that is its own OS
## window is placed on the screen.
func _below() -> Vector2:
	var point := get_global_position() + Vector2(0, size.y)
	var window := get_window()
	while window != null and window.is_embedded():
		point += Vector2(window.position)
		window = window.get_parent().get_window() if window.get_parent() != null else null
	if window != null and not popup.is_embedded():
		point += Vector2(window.position)
	return point


## Fills the tree with the items matching the search, under their groups.
func _fill() -> void:
	tree.clear()
	var root := tree.create_item()
	var query := search.text.strip_edges().to_lower()
	var groups := {}
	for index in range(items.size()):
		var entry: Dictionary = items[index]
		if not query.is_empty() and not query in entry.text.to_lower():
			continue
		var parent := root
		if not entry.group.is_empty():
			if not groups.has(entry.group):
				var heading := tree.create_item(root)
				heading.set_text(0, entry.group.to_upper())
				heading.set_selectable(0, false)
				heading.set_custom_color(0, Palette.muted)
				heading.set_custom_font_size(0, 11)
				groups[entry.group] = heading
			parent = groups[entry.group]
		var row := tree.create_item(parent)
		row.set_text(0, entry.text)
		row.set_metadata(0, index)
		if entry.disabled:
			row.set_selectable(0, false)
			row.set_custom_color(0, Palette.disabled)
		if index == selected:
			row.set_custom_color(0, Palette.accent)


func _on_tree_selected() -> void:
	var row := tree.get_selected()
	if row == null or row.get_metadata(0) == null:
		return
	choose(int(row.get_metadata(0)))


## Picks an item as the user would: selects it, emits item_selected, closes.
func choose(index: int) -> void:
	if index < 0 or index >= items.size() or items[index].disabled:
		return
	select(index)
	popup.hide()
	item_selected.emit(index)


func _pick_first() -> void:
	var row := tree.get_root().get_first_child() if tree.get_root() != null else null
	while row != null:
		if row.get_metadata(0) != null and row.is_selectable(0):
			choose(int(row.get_metadata(0)))
			return
		var child := row.get_first_child()
		while child != null:
			if child.is_selectable(0):
				choose(int(child.get_metadata(0)))
				return
			child = child.get_next()
		row = row.get_next()
