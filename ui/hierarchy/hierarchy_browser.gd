extends PanelContainer
static var Palette = preload("res://ui/theme/editor_palette.tres")
const Metrics = preload("res://ui/shared/editor_metrics.gd")

signal element_selected(node: Node3D)
signal visibility_changed_by_user
signal element_collapsed(node: Node3D, collapsed: bool)
signal add_requested
signal reparent_requested(node: Node3D, parent: Node3D)
## A row was dropped above (-1), onto (0) or below (1) another row. keep_world
## is false while Alt is held.
signal move_requested(node: Node3D, target: Node3D, zone: int, keep_world: bool)
signal context_requested(node: Node3D, screen_position: Vector2)
signal rename_requested(node: Node3D)
signal delete_requested(node: Node3D)
## Ctrl+click on a row: add or remove it from the selection.
signal element_toggled(node: Node3D)
## Shift+click on a row: select the range from the active row.
signal element_range_requested(node: Node3D)
## An inline rename was confirmed with this text.
signal rename_submitted(node: Node3D, name: String)
## An attachment point row was clicked: its element and index.
signal point_selected(node: Node3D, index: int)
const VISIBLE_ICON = preload("res://assets/icons/visibility.svg")
const HIDDEN_ICON = preload("res://assets/icons/visibility_off.svg")
const LOCKED_ICON = preload("res://assets/icons/lock.svg")
const UNLOCKED_ICON = preload("res://assets/icons/lock_open.svg")
## Node metadata marking an element that cannot be picked or moved in the
## viewport. Editor state only; it is not written to the file.
const LOCK_META := "shapesmith_locked"
## Seconds a dragged row must hover over a folded row before it unfolds.
const AUTO_EXPAND_SECONDS := 0.6
var history
@onready var tree: Tree = $Margin/Layout/Tree
var items: Dictionary = {}
var updating := false
var shape_root: Node3D
var filter_collapsed: Dictionary = {}
var selected_node: Node3D
var fold_states: Dictionary = {}
var filter_matches: Dictionary = {}
## Every selected node (the active one is selected_node), highlighted together.
var multi_selected: Dictionary = {}
## The node whose row is being renamed in place, or null.
var renaming: Node3D
var rename_field: LineEdit
var _hover_target: Node3D
var _hover_since := 0.0
## While dragging: {rect, zone} of the row under the pointer, for the insertion line.
var drop_hint: Dictionary = {}
## The attachment point shown selected under selected_node, or -1.
var selected_point := -1
## TreeItem meta on attachment point rows (nested under their element's row;
## their metadata is the element, so element code paths stay typed).
const POINT_META := "point_index"
class FoldArrows extends Control:
	var Palette = preload("res://ui/theme/editor_palette.tres")
	var browser


	func _draw() -> void:
		var hint: Dictionary = browser.drop_hint
		if not hint.is_empty() and hint.zone != 0:
			var y: float = hint.rect.position.y if hint.zone < 0 else hint.rect.end.y
			draw_line(Vector2(hint.rect.position.x, y), Vector2(hint.rect.end.x, y), Palette.accent, 2.0)
		for node in browser.items:
			if not browser.items[node].visible or not browser.has_children(node):
				continue

			var area: Rect2 = browser.collapse_rect(node)
			if not Rect2(Vector2.ZERO, size).intersects(area):
				continue

			var center := Vector2(area.position.x + 6, area.get_center().y)
			var points := PackedVector2Array([center + Vector2(-3, -4), center + Vector2(3, 0), center + Vector2(-3, 4)]) if browser.fold_states.get(node, false) else PackedVector2Array([center + Vector2(-4, -2), center + Vector2(4, -2), center + Vector2(0, 4)])
			draw_colored_polygon(points, Palette.muted)
@onready var filter_input: LineEdit = $Margin/Layout/Tools/Filter


func _ready() -> void:
	tree.clip_contents = true
	var arrows := FoldArrows.new()
	arrows.browser = self
	arrows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tree.add_child(arrows)
	arrows.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tree.draw.connect(arrows.queue_redraw)
	filter_input.text_changed.connect(_filter_changed)
	$Margin/Layout/Tools/Add.pressed.connect(func(): add_requested.emit())
	tree.set_drag_forwarding(_get_drag_data, _can_drop_data, _drop_data)
	tree.drop_mode_flags = 0
	tree.columns = 3
	# Visibility and lock toggles stay fixed on the left; the inline fold arrow
	# follows depth.
	tree.hide_folding = true
	tree.set_column_expand(0, false)
	tree.set_column_custom_minimum_width(0, 28)
	tree.set_column_clip_content(0, true)
	tree.set_column_expand(1, false)
	tree.set_column_custom_minimum_width(1, 24)
	tree.set_column_clip_content(1, true)
	tree.set_column_clip_content(2, true)
	tree.add_theme_constant_override("item_margin", 0)
	var panel := StyleBoxEmpty.new()
	panel.content_margin_left = 2
	panel.content_margin_right = 2
	tree.add_theme_stylebox_override("panel", panel)
	tree.gui_input.connect(_on_tree_gui_input)
	tree.item_collapsed.connect(func(item: TreeItem):
		if not updating and item.get_metadata(0) != null:
			# Native Tree state is presentation only. A native expansion must never
			# turn into a user fold command or overwrite our logical fold state.
			updating = true
			item.collapsed = fold_states.get(item.get_metadata(0), false)
			updating = false
		_sync_collapse_icon(item))
	tree.item_selected.connect(func():
		if not updating and tree.get_selected() != null:
			var picked := tree.get_selected()
			var node: Node3D = picked.get_metadata(0)
			if node != renaming and renaming != null:
				end_rename()
			var point: int = picked.get_meta(POINT_META, -1)
			selected_point = point
			select_element(node)
			element_selected.emit(node)
			if point >= 0:
				selected_point = point
				_sync_native_selection()
				_stripe_rows()
				point_selected.emit(node, point))


func bind_shape(root: Node3D) -> void:
	shape_root = root
	updating = true
	tree.clear()
	items.clear()
	tree.create_item()
	_add_children(root)
	for node in fold_states.keys():
		if items.has(node):
			items[node].collapsed = fold_states[node]
		else:
			fold_states.erase(node)
	if not items.has(selected_node):
		selected_node = null
	_stripe_rows()
	_sync_visibility()
	updating = false
	_filter_changed(filter_input.text, false)


func _add_children(node: Node, depth := 0) -> void:
	if node.has_meta("shape_element"):
		_make_item(node, depth)
		depth += 1
	for child in node.get_children():
		_add_children(child, depth)


func _make_item(node: Node3D, depth: int, index := -1) -> TreeItem:
	# Godot owns a flat list only. Native nested TreeItems can auto-expand
	# selected ancestors and interfere with our explicit hierarchy controls.
	var item := tree.create_item(tree.get_root(), index)
	item.set_meta("depth", depth)
	item.set_metadata(0, node)
	item.set_metadata(1, node)
	item.set_metadata(2, node)
	item.set_selectable(0, false)
	item.set_selectable(1, false)
	item.set_icon(0, VISIBLE_ICON)
	_sync_lock_icon(item, node)
	item.collapsed = fold_states.get(node, false)
	_sync_collapse_icon(item)
	item.set_tooltip_text(2, str(node.get_path()))
	items[node] = item
	_make_point_rows(node)
	return item


## Rows for an element's attachment points, nested under its row.
func _make_point_rows(node: Node3D) -> void:
	var item: TreeItem = items[node]
	for child in item.get_children():
		child.free()
	var points: Variant = node.get_meta("shape_element").get("attachmentPoints", node.get_meta("shape_element").get("attachmentpoints"))
	if not points is Array:
		return
	for i in range(points.size()):
		var row := tree.create_item(item)
		row.set_meta(POINT_META, i)
		row.set_meta("depth", int(item.get_meta("depth")) + 1)
		for column in range(3):
			row.set_metadata(column, node)
		row.set_selectable(0, false)
		row.set_selectable(1, false)
		var code: String = str(points[i].get("code", "Unnamed")) if points[i] is Dictionary else "Invalid point"
		row.set_text(2, " ".repeat(Metrics.INDENT_SPACES * int(row.get_meta("depth"))) + "    ⌖ " + code)
		row.set_custom_color(2, Palette.muted)
		row.set_tooltip_text(2, "Attachment point %s on %s" % [code, node.get_meta("shape_element").get("name", "")])


## Rebuilds every element's attachment point rows (after point edits).
func refresh_points() -> void:
	var was_updating := updating
	updating = true
	for node in items:
		if is_instance_valid(node):
			_make_point_rows(node)
	updating = was_updating
	_refresh_rows()


static func _is_point_row(item: TreeItem) -> bool:
	return item != null and item.has_meta(POINT_META)


# --- Incremental updates (driven by document signals through main.gd) -------

## Adds rows for a node and its descendants at their place in the list.
func add_rows(node: Node3D) -> void:
	if not is_instance_valid(shape_root) or not shape_root.is_ancestor_of(node) or items.has(node):
		return
	var start := _element_order(shape_root).find(node)
	var depth := 0
	var ancestor := node.get_parent()
	while ancestor != null and ancestor != shape_root:
		if ancestor.has_meta("shape_element"):
			depth += 1
		ancestor = ancestor.get_parent()
	updating = true
	var index := start
	for element in _element_order(node):
		var level := depth
		var parent: Node = element.get_parent()
		while parent != node.get_parent() and parent != null:
			if parent.has_meta("shape_element"):
				level += 1
			parent = parent.get_parent()
		_make_item(element, level, index)
		index += 1
	updating = false
	_after_rows_changed()


## Removes the rows of a node and its descendants. Fold states are kept, so
## an undo that brings the node back restores them.
func remove_rows(node: Node3D) -> void:
	updating = true
	for element in _element_order(node):
		if items.has(element):
			items[element].free()
			items.erase(element)
			if selected_node == element:
				selected_node = null
	updating = false
	_after_rows_changed()


## A node moved to another parent or position: rebuild only its rows.
func move_rows(node: Node3D) -> void:
	remove_rows(node)
	add_rows(node)


func rename_row(node: Node3D) -> void:
	if items.has(node):
		_sync_collapse_icon(items[node])
		for element in _element_order(node):
			if items.has(element):
				items[element].set_tooltip_text(2, str(element.get_path()))
		_filter_changed(filter_input.text, false)


func _element_order(node: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if node.has_meta("shape_element"):
		result.append(node)
	for child in node.get_children():
		result.append_array(_element_order(child))
	return result


func _after_rows_changed() -> void:
	_sync_visibility()
	_filter_changed(filter_input.text, false)
	tree.queue_redraw()


func select_element(node: Node3D) -> void:
	var changed := selected_node != node
	if changed:
		selected_point = -1
	selected_node = node
	_sync_native_selection()
	if changed and _row_visible(node):
		tree.scroll_to_item(items[node])
	_stripe_rows()


## Edits the row's name in place (F2): a text field over the row. Enter
## renames, Escape or clicking elsewhere cancels.
func begin_rename(node: Node3D) -> void:
	if not items.has(node):
		return
	end_rename()
	if not items[node].visible:
		reveal_element(node)
	select_element(node)
	tree.scroll_to_item(items[node])
	var area := tree.get_item_area_rect(items[node], 2)
	var indent := tree.get_theme_font("font").get_string_size(" ".repeat(Metrics.INDENT_SPACES * int(items[node].get_meta("depth")) + 4), HORIZONTAL_ALIGNMENT_LEFT, -1, tree.get_theme_font_size("font_size")).x
	rename_field = LineEdit.new()
	rename_field.name = "RenameField"
	rename_field.text = str(node.get_meta("shape_element").get("name", ""))
	rename_field.position = area.position + Vector2(indent, 0)
	rename_field.size = Vector2(maxf(area.size.x - indent, 80), area.size.y)
	rename_field.text_submitted.connect(func(_text: String): commit_rename())
	rename_field.gui_input.connect(func(event: InputEvent):
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			rename_field.accept_event()
			end_rename.call_deferred())
	rename_field.focus_exited.connect(end_rename, CONNECT_DEFERRED)
	tree.add_child(rename_field)
	renaming = node
	rename_field.grab_focus()
	rename_field.select_all()


## Renames with the field's text and closes it.
func commit_rename() -> void:
	if not is_instance_valid(renaming) or rename_field == null:
		return
	var node := renaming
	var value := rename_field.text.strip_edges()
	end_rename()
	rename_submitted.emit(node, value)


## Closes the rename field without renaming.
func end_rename() -> void:
	renaming = null
	if not is_instance_valid(rename_field):
		return
	var field := rename_field
	rename_field = null
	# Return focus to the outliner only if the field still had it (Enter or
	# Escape), not when the user had already clicked somewhere else.
	var had_focus := field.has_focus()
	if field.get_parent() != null:
		field.get_parent().remove_child(field)
	field.queue_free()
	if had_focus and tree.is_visible_in_tree():
		tree.grab_focus()


## Highlights every selected node; the active one keeps the full selection color.
func set_multi_selection(nodes: Array) -> void:
	multi_selected.clear()
	for node in nodes:
		if is_instance_valid(node):
			multi_selected[node] = true
	_stripe_rows()


func _row_visible(node: Node3D) -> bool:
	if not items.has(node):
		return false

	var item: TreeItem = items[node]
	return item.visible


func reveal_element(node: Node3D) -> void:
	if not items.has(node):
		return
	# Only explicit viewport picks reveal ancestors. Ordinary selection sync and
	# playback updates must respect the user's manually collapsed branches.
	if not filter_matches.get(node, true):
		filter_input.text = ""
		_filter_changed("")
	var ancestor := node.get_parent()
	while ancestor != null and ancestor != shape_root:
		if items.has(ancestor) and fold_states.get(ancestor, false):
			_set_fold(ancestor, false, true)
		ancestor = ancestor.get_parent()
	select_element(node)
	tree.scroll_to_item(items[node])


func _sync_native_selection() -> void:
	var was_updating := updating
	updating = true
	# TreeItem.select() does not clear other programmatically selected items.
	# Never allow old native selection flags to coexist with the current one.
	tree.deselect_all()
	if _row_visible(selected_node):
		var row: TreeItem = items[selected_node]
		if selected_point >= 0 and selected_point < row.get_child_count() and not row.collapsed:
			row = row.get_child(selected_point)
		row.select(2)
	updating = was_updating


func toggle_visibility(node: Node3D) -> void:
	if not is_instance_valid(node):
		return

	var visible_before := node.visible
	var name := str(node.get_meta("shape_element").get("name", "element"))
	if history != null:
		history.perform(("Hide " if visible_before else "Show ") + name,
			_apply_visibility.bind(node, not visible_before), _apply_visibility.bind(node, visible_before), "", false)
	else:
		_apply_visibility(node, not visible_before)


func _apply_visibility(node: Node3D, enabled: bool) -> bool:
	if not is_instance_valid(node):
		return false

	node.visible = enabled
	_sync_visibility()
	visibility_changed_by_user.emit()
	return true


func _sync_visibility() -> void:
	for node in items:
		if not is_instance_valid(node):
			continue

		var item: TreeItem = items[node]
		item.set_icon(0, VISIBLE_ICON if node.visible else HIDDEN_ICON)
		var inherited: bool = node.visible and not node.is_visible_in_tree()
		var color: Color = Palette.muted if node.is_visible_in_tree() else Palette.disabled
		item.set_icon_modulate(0, color)
		item.set_custom_color(2, Palette.text if node.is_visible_in_tree() else Palette.disabled)
		item.set_tooltip_text(0, "Hidden by parent; toggle own visibility" if inherited else ("Hide element and children" if node.visible else "Show element"))


func refresh_palette() -> void:
	_stripe_rows()
	_sync_visibility()


func _stripe_rows() -> void:
	var row := [0]
	_stripe_children(tree.get_root(), row)


func _stripe_children(parent: TreeItem, row: Array) -> void:
	if parent == null:
		return

	var item := parent.get_first_child()
	while item != null:
		if not item.visible:
			item = item.get_next()
			continue

		var node: Node3D = item.get_metadata(0)
		var base: Color = Palette.surface if row[0] % 2 == 0 else Palette.chrome
		var active: bool = node == selected_node and (item.get_meta(POINT_META, -1) == selected_point or (selected_point >= 0 and item.get_meta(POINT_META, -1) == -1 and item.collapsed))
		var color: Color = Palette.selection if active else (base.lerp(Palette.selection, 0.6) if multi_selected.has(node) and not _is_point_row(item) else base)
		for column in range(3):
			item.set_custom_bg_color(column, color)
		row[0] += 1
		if not item.collapsed:
			_stripe_children(item, row)
		item = item.get_next()


func set_collapsed(node: Node3D, collapsed: bool) -> void:
	_set_fold(node, collapsed, false)


func _set_fold(node: Node3D, collapsed: bool, notify: bool) -> void:
	if items.has(node):
		fold_states[node] = collapsed
		updating = true
		items[node].collapsed = collapsed
		updating = false
		if notify and not filter_input.text.is_empty():
			filter_collapsed[node] = collapsed
		_refresh_rows()
		if notify:
			element_collapsed.emit(node, collapsed)


func _refresh_rows() -> void:
	var was_updating := updating
	updating = true
	for node in items:
		var visible_row: bool = filter_matches.get(node, true)
		var ancestor: Node = node.get_parent()
		while visible_row and ancestor != null and ancestor != shape_root:
			if items.has(ancestor) and fold_states.get(ancestor, false):
				visible_row = false
			ancestor = ancestor.get_parent()
		items[node].visible = visible_row
		_sync_collapse_icon(items[node])
	updating = was_updating
	_sync_native_selection()
	_stripe_rows()


func _sync_collapse_icon(item: TreeItem) -> void:
	var node: Node3D = item.get_metadata(0)
	if node == null:
		return

	var prefix := "    "
	item.set_text(2, " ".repeat(Metrics.INDENT_SPACES * int(item.get_meta("depth"))) + prefix + str(node.get_meta("shape_element").get("name", "Unnamed element")))


func has_children(node: Node3D) -> bool:
	return node.get_children().any(func(child: Node): return child.has_meta("shape_element")) 		or (items.has(node) and items[node].get_child_count() > 0)


func collapse_rect(node: Node3D) -> Rect2:
	if not items.has(node) or not has_children(node):
		return Rect2()

	var item: TreeItem = items[node]
	var area := tree.get_item_area_rect(item, 2)
	var font := tree.get_theme_font("font")
	var font_size := tree.get_theme_font_size("font_size")
	area.position.x += font.get_string_size(" ".repeat(Metrics.INDENT_SPACES * int(item.get_meta("depth"))), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	area.size.x = font.get_string_size("    ", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	return area


func _on_tree_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode in [KEY_LEFT, KEY_RIGHT] and is_instance_valid(selected_node):
		_set_fold(selected_node, event.keycode == KEY_LEFT, true)
		tree.accept_event()
		return

	if event is InputEventKey and event.pressed and _is_point_row(tree.get_selected()) and event.keycode in [KEY_F2, KEY_DELETE]:
		# Rename and delete attachment points in the inspector, not the element.
		tree.accept_event()
		return

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2 and tree.get_selected() != null:
		rename_requested.emit(tree.get_selected().get_metadata(0))
		tree.accept_event()
		return

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_DELETE and tree.get_selected() != null:
		delete_requested.emit(tree.get_selected().get_metadata(0))
		tree.accept_event()
		return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		var clicked := tree.get_item_at_position(event.position)
		if clicked != null and not _is_point_row(clicked):
			var node: Node3D = clicked.get_metadata(0)
			element_selected.emit(node)
			context_requested.emit(node, tree.get_screen_position() + event.position)
			tree.accept_event()
		return

	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return

	if event.pressed and (event.ctrl_pressed or event.meta_pressed or event.shift_pressed) and tree.get_column_at_position(event.position) == 2:
		var picked := tree.get_item_at_position(event.position)
		if picked != null and not _is_point_row(picked):
			if event.shift_pressed:
				element_range_requested.emit(picked.get_metadata(0))
			else:
				element_toggled.emit(picked.get_metadata(0))
			tree.accept_event()
			return

	var item := tree.get_item_at_position(event.position)
	var column := tree.get_column_at_position(event.position)
	if item == null and event.pressed:
		element_selected.emit(null)
		return

	if item == null or _is_point_row(item) or (column > 1 and not collapse_rect(item.get_metadata(0)).has_point(event.position)):
		return
	# Handle the entire icon cell using the event's coordinates. This keeps the
	# hit target consistent with the displayed row, including after scrolling.
	if event.pressed:
		if column == 0:
			toggle_visibility(item.get_metadata(0))
		elif column == 1:
			toggle_lock(item.get_metadata(0))
		else:
			_set_fold(item.get_metadata(0), not fold_states.get(item.get_metadata(0), false), true)
	tree.accept_event()


func _filter_changed(text: String, reveal := true) -> void:
	updating = true
	if not text.is_empty() and filter_collapsed.is_empty():
		for node in items:
			filter_collapsed[node] = items[node].collapsed
	filter_matches.clear()
	if is_instance_valid(shape_root):
		_filter_branch(shape_root, text.strip_edges().to_lower(), reveal)
	if text.is_empty():
		for node in filter_collapsed:
			if items.has(node):
				items[node].collapsed = filter_collapsed[node]
				fold_states[node] = filter_collapsed[node]
		filter_collapsed.clear()
	updating = false
	_refresh_rows()


func _filter_branch(node: Node, text: String, reveal: bool) -> bool:
	var match_found := text.is_empty() or (items.has(node) and text in str(node.get_meta("shape_element").get("name", "")).to_lower())
	for child in node.get_children():
		if child.has_meta("shape_element") and _filter_branch(child, text, reveal):
			match_found = true
	if items.has(node):
		filter_matches[node] = match_found
		if reveal and not text.is_empty() and match_found:
			items[node].collapsed = false
			fold_states[node] = false
	return match_found


func _get_drag_data(position_value: Vector2) -> Variant:
	var item := tree.get_item_at_position(position_value)
	# Drag from the name, or anywhere on the row except the toggles.
	if item == null or _is_point_row(item) or tree.get_column_at_position(position_value) < 1:
		return null

	var node: Node3D = item.get_metadata(0)
	var preview := Label.new()
	preview.text = str(node.get_meta("shape_element").get("name", node.name))
	tree.set_drag_preview(preview)
	return {"shape_smith_element": node, "browser": self}


func _can_drop_data(position_value: Vector2, data: Variant) -> bool:
	tree.drop_mode_flags = 0
	if not Rect2(Vector2.ZERO, tree.size).has_point(position_value):
		return false

	if not data is Dictionary or data.get("browser") != self or not is_instance_valid(data.get("shape_smith_element")):
		return false

	var item := _row_at(position_value)
	var target: Node3D = item.get_metadata(0) if item != null else shape_root
	var node: Node3D = data.shape_smith_element
	var zone := drop_zone(position_value)
	var allowed := target != node and not node.is_ancestor_of(target)
	if zone == 0:
		allowed = allowed and node.get_parent() != target
	if allowed and get_viewport().gui_is_dragging():
		# The tree frames the row for "onto"; above and below get our own line
		# (the tree's in-between mode breaks its hit test on this flat list).
		tree.drop_mode_flags = Tree.DROP_MODE_ON_ITEM if zone == 0 else 0
		drop_hint = {"rect": tree.get_item_area_rect(item, 2), "zone": zone} if item != null else {}
		tree.queue_redraw()
		_auto_expand(target if zone == 0 else null)
	else:
		_clear_drop_hint()
	return allowed


## The row at a position in the tree, independent of the drop mode.
func _row_at(position_value: Vector2) -> TreeItem:
	var flags := tree.drop_mode_flags
	tree.drop_mode_flags = 0
	var item := tree.get_item_at_position(position_value)
	tree.drop_mode_flags = flags
	return item


func _clear_drop_hint() -> void:
	if not drop_hint.is_empty():
		drop_hint = {}
		tree.queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_clear_drop_hint()
		tree.drop_mode_flags = 0


## -1 for the top quarter of a row (insert above), 1 for the bottom quarter
## (insert below), 0 for the middle (make a child).
func drop_zone(position_value: Vector2) -> int:
	var item := _row_at(position_value)
	if item == null:
		return 0
	var area := tree.get_item_area_rect(item, 2)
	var t := (position_value.y - area.position.y) / maxf(area.size.y, 1.0)
	return -1 if t < 0.25 else (1 if t > 0.75 else 0)


func _auto_expand(target: Node3D) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if target != _hover_target:
		_hover_target = target
		_hover_since = now
	elif is_instance_valid(target) and items.has(target) and fold_states.get(target, false) and now - _hover_since >= AUTO_EXPAND_SECONDS:
		_set_fold(target, false, true)


func _drop_data(position_value: Vector2, data: Variant) -> void:
	if _can_drop_data(position_value, data):
		var item := _row_at(position_value)
		var zone := drop_zone(position_value)
		_clear_drop_hint()
		var keep_world := not Input.is_key_pressed(KEY_ALT)
		if zone == 0 and keep_world:
			reparent_requested.emit(data.shape_smith_element, item.get_metadata(0) if item != null else null)
		else:
			move_requested.emit(data.shape_smith_element, item.get_metadata(0) if item != null else null, zone, keep_world)


# --- Lock and visibility helpers -----------------------------------------------

func is_locked(node: Node3D) -> bool:
	return is_instance_valid(node) and node.get_meta(LOCK_META, false)


## Locks or unlocks an element: a locked element cannot be picked in the
## viewport or moved with the gizmo. Undoable; not saved in the file.
func toggle_lock(node: Node3D) -> void:
	if not is_instance_valid(node):
		return
	var locked := is_locked(node)
	var name := str(node.get_meta("shape_element").get("name", "element"))
	if history != null:
		history.perform(("Unlock " if locked else "Lock ") + name, _apply_lock.bind(node, not locked), _apply_lock.bind(node, locked), "", false)
	else:
		_apply_lock(node, not locked)


func _apply_lock(node: Node3D, locked: bool) -> bool:
	if not is_instance_valid(node):
		return false
	if locked:
		node.set_meta(LOCK_META, true)
	else:
		node.remove_meta(LOCK_META)
	if items.has(node):
		_sync_lock_icon(items[node], node)
	return true


func _sync_lock_icon(item: TreeItem, node: Node3D) -> void:
	var locked := is_locked(node)
	item.set_icon(1, LOCKED_ICON if locked else UNLOCKED_ICON)
	item.set_icon_modulate(1, Palette.text if locked else Color(Palette.muted, 0.35))
	item.set_tooltip_text(1, "Locked: cannot be picked or moved in the viewport" if locked else "Lock")


## Hides every element except these, their ancestors and their descendants,
## as one undoable step.
func hide_others(keep: Array) -> void:
	var kept := {}
	for node in keep:
		if not is_instance_valid(node):
			continue
		kept[node] = true
		var ancestor: Node = node.get_parent()
		while ancestor != null and ancestor != shape_root:
			kept[ancestor] = true
			ancestor = ancestor.get_parent()
		for element in _element_order(node):
			kept[element] = true
	var changes: Array = []
	for node in items:
		var parent: Node = node.get_parent()
		# Hide only the top of each hidden branch; children follow.
		if not kept.has(node) and (parent == shape_root or kept.has(parent)) and node.visible:
			changes.append(node)
	_set_visible_many(changes, false, "Hide Others")


func show_all() -> void:
	var changes: Array = items.keys().filter(func(node): return not node.visible)
	_set_visible_many(changes, true, "Show All")


func _set_visible_many(nodes: Array, value: bool, label: String) -> void:
	if nodes.is_empty():
		return
	var apply := func() -> bool:
		for node in nodes:
			if is_instance_valid(node):
				node.visible = value
		_sync_visibility()
		visibility_changed_by_user.emit()
		return true
	var revert := func() -> bool:
		for node in nodes:
			if is_instance_valid(node):
				node.visible = not value
		_sync_visibility()
		visibility_changed_by_user.emit()
		return true
	if history != null:
		history.perform(label, apply, revert, "", false)
	else:
		apply.call()
