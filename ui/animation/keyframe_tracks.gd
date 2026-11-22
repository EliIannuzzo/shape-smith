extends Control

const DEFAULT_HIERARCHY_WIDTH := 210.0
const MIN_HIERARCHY_WIDTH := 110.0
const MIN_TRACK_WIDTH := 140.0
const TRACK_LEFT_PADDING := 14.0
const TRACK_RIGHT_PADDING := 16.0
const MARKER_HIT_RADIUS := 10.0
const MIN_PIXELS_PER_FRAME := 0.001
const TICK_INTERVALS := [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 5000, 10000]
const MIN_TICK_SPACING := 45.0


signal element_selected(node: Node3D)
signal element_collapsed(node: Node3D, collapsed: bool)
signal frame_selected(frame: float)
signal details_changed(text: String)
signal hierarchy_width_changed(width: float)
signal keyframe_selected(entries: Array, time: int)
signal keyframe_cleared
signal move_requested(selection: Array, delta: int)
signal delete_requested(selection: Array)
signal copy_requested(selection: Array)
signal paste_requested(time: int)
## Paste Mirrored: the copied keys on the mirror elements, mirrored.
signal paste_mirrored_requested(time: int)
## The selected keys scaled in time around `pivot` by `factor`.
signal scale_requested(selection: Array, pivot: float, factor: float)
## Ripple: insert (count > 0) or delete (count < 0) frames at a frame.
signal frames_requested(at: int, count: int)
## The clip's timeline markers changed: [{frame, name}].
signal markers_changed(markers: Array)
var key_menu: PopupMenu
var clipboard_available := false
var show_generated := false
var generated_times: Dictionary = {}
static var Palette = preload("res://ui/theme/editor_palette.tres")
const Metrics = preload("res://ui/shared/editor_metrics.gd")
const ROW_HEIGHT := float(Metrics.ROW_HEIGHT)
const HEADER_HEIGHT := 25.0
const DRAG_START_DISTANCE := 4.0
const DIVIDER_HIT_RADIUS := 5.0
const PROPERTY_GROUPS := {"offset": "Position", "rotation": "Rotation", "stretch": "Scale", "origin": "Origin (stored)"}
var clip: Dictionary = {}
var roots: Array[Node3D] = []
var children: Dictionary = {}
var keys: Dictionary = {}
var subtree_keys: Dictionary = {}
var collapsed: Dictionary = {}
var rows: Array[Dictionary] = []
var selected_node: Node3D
var frame := 0.0
var hierarchy_width := DEFAULT_HIERARCHY_WIDTH
var resizing_hierarchy := false
var selected_key_node: Node3D
var selected_key_frame := -1
var selected_keys: Array = []
var gesture := ""
var press_position := Vector2.ZERO
var pointer_position := Vector2.ZERO
var drag_delta := 0
var gesture_started := false
var base_selection: Array = []
var clicked_keys: Array = []
var additive := false
var pixels_per_frame := 1.0
## Elements whose rows are expanded into Position/Rotation/Scale and axis rows.
var channels_open: Dictionary = {}
## The channel row picked in the list ({node, channel}), for Insert Key.
var selected_channel: Dictionary = {}
## Scale gesture: the frame kept fixed and the current factor.
var scale_pivot := 0.0
var scale_factor := 1.0
var _scale_span := Vector2.ZERO
## Marker being dragged (index), and its frame while dragging.
var dragged_marker := -1
var dragged_marker_frame := 0
var marker_menu: PopupMenu
var marker_menu_index := -1
var rename_popup: PopupPanel
var rename_field: LineEdit
const CHANNEL_GROUPS := ["offset", "rotation", "stretch"]
const EXPANDER_WIDTH := 16.0


func _ready() -> void:
	key_menu = PopupMenu.new()
	key_menu.theme = preload("res://ui/theme/editor_theme.tres")
	add_child(key_menu)
	key_menu.add_item("Delete Keyframes", 0)
	key_menu.add_item("Copy Keyframes", 1)
	key_menu.add_item("Paste Keyframes", 2)
	key_menu.set_item_accelerator(1, KEY_MASK_CTRL | KEY_C)
	key_menu.set_item_accelerator(2, KEY_MASK_CTRL | KEY_V)
	for i in range(3):
		key_menu.set_item_icon(i, preload("res://ui/shared/editor_icons.gd").icon(["delete", "content_copy", "content_paste"][i]))
	key_menu.add_item("Paste Mirrored", 3)
	key_menu.set_item_accelerator(3, KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_V)
	key_menu.add_separator()
	key_menu.add_item("Insert Frame at Playhead", 4)
	key_menu.add_item("Delete Frame at Playhead", 5)
	key_menu.add_item("Add Marker at Playhead", 6)
	key_menu.id_pressed.connect(_key_menu_action)
	marker_menu = PopupMenu.new()
	marker_menu.theme = key_menu.theme
	add_child(marker_menu)
	marker_menu.add_item("Rename Marker…", 0)
	marker_menu.add_item("Delete Marker", 1)
	marker_menu.id_pressed.connect(func(id: int):
		if id == 0:
			begin_rename_marker(marker_menu_index)
		else:
			delete_marker(marker_menu_index))
	rename_popup = PopupPanel.new()
	rename_popup.theme = key_menu.theme
	rename_field = LineEdit.new()
	rename_field.custom_minimum_size.x = 160
	rename_popup.add_child(rename_field)
	add_child(rename_popup)
	rename_field.text_submitted.connect(func(text: String):
		rename_popup.hide()
		rename_marker(marker_menu_index, text))
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	resized.connect(func():
		queue_redraw()
		hierarchy_width_changed.emit(get_hierarchy_width()))
	gui_input.connect(_on_gui_input)


func bind_shape(root: Node3D) -> void:
	clipboard_available = false
	roots.clear()
	children.clear()
	collapsed.clear()
	keys.clear()
	generated_times.clear()
	subtree_keys.clear()
	selected_node = null
	_collect(root, null)
	set_clip({})


## Re-collects rows after elements were added, removed or moved, keeping the
## fold state of every element that is still there.
func sync_structure(root: Node3D) -> void:
	roots.clear()
	children.clear()
	_collect(root, null)
	for node in collapsed.keys():
		if not children.has(node):
			collapsed.erase(node)
	if not children.has(selected_node):
		selected_node = null
	set_clip(clip)


func _collect(node: Node, parent: Node3D) -> void:
	if node.has_meta("shape_element"):
		children[node] = []
		if parent == null:
			roots.append(node)
		else:
			children[parent].append(node)
		parent = node
	for child in node.get_children():
		_collect(child, parent)


func set_clip(value: Dictionary) -> void:
	clip = value
	gesture = ""
	drag_delta = 0
	gesture_started = false
	clear_keyframe_selection()
	keys.clear()
	subtree_keys.clear()
	for node in children:
		keys[node] = {}
		generated_times[node] = {}
		var name := element_name(node)
		for record in clip.get("generated_keyframes", []):
			if record.get("elements", {}).has(name):
				generated_times[node][int(record.frame)] = true
		for key in clip.get("keyframes", []):
			var pose: Dictionary = key.get("elements", {}).get(name, {})
			if not pose.is_empty():
				keys[node][int(key.frame)] = [{"node": node, "pose": pose}]
	for node in roots:
		_cache_subtree(node)
	_rebuild_rows()
	set_playhead(0.0)


func _cache_subtree(node: Node3D) -> Dictionary:
	var result: Dictionary = keys.get(node, {}).duplicate(true)
	for child in children[node]:
		var nested := _cache_subtree(child)
		for time in nested:
			if not result.has(time):
				result[time] = []
			result[time].append_array(nested[time])
	subtree_keys[node] = result
	return result


func _rebuild_rows() -> void:
	rows.clear()
	for node in roots:
		_append_row(node, 0)
	custom_minimum_size.y = HEADER_HEIGHT + maxi(rows.size(), 2) * ROW_HEIGHT
	queue_redraw()
	_update_details()


func _append_row(node: Node3D, depth: int) -> void:
	rows.append({"node": node, "depth": depth})
	if channels_open.get(node, false):
		for group in CHANNEL_GROUPS:
			if keys.get(node, {}).values().any(func(entries): return entries.any(func(entry): return _has_channel(entry.pose, group))):
				rows.append({"node": node, "depth": depth + 1, "channel": group})
				for axis in ["X", "Y", "Z"]:
					rows.append({"node": node, "depth": depth + 2, "channel": group + axis})
	if not collapsed.get(node, false):
		for child in children[node]:
			_append_row(child, depth + 1)


static func _has_channel(pose: Dictionary, channel: String) -> bool:
	if channel in CHANNEL_GROUPS:
		return ["X", "Y", "Z"].any(func(axis: String): return pose.get(channel + axis) != null)
	return pose.get(channel) != null


## Shows or hides an element's Position, Rotation and Scale rows.
func set_channels_open(node: Node3D, enabled: bool) -> void:
	if children.has(node):
		channels_open[node] = enabled
		if not enabled and selected_channel.get("node") == node:
			selected_channel = {}
		_rebuild_rows()


## Keys shown on a row: an element row shows its own (or, folded, its
## subtree's) keys; a channel row shows the frames that key that channel.
func row_times(row: Dictionary) -> Dictionary:
	if not row.has("channel"):
		return row_keys(row.node)
	var result := {}
	for time in keys.get(row.node, {}):
		var entries: Array = keys[row.node][time].filter(func(entry): return _has_channel(entry.pose, row.channel))
		if not entries.is_empty():
			result[time] = entries
	return result


func _channel_label(channel: String) -> String:
	if channel in CHANNEL_GROUPS:
		return PROPERTY_GROUPS[channel]
	return channel.right(1)


func set_collapsed(node: Node3D, enabled: bool) -> void:
	if children.has(node):
		collapsed[node] = enabled
		_rebuild_rows()
		_notify_selection()


func select_element(node: Node3D) -> void:
	if not selected_keys.is_empty() and selected_node != node:
		clear_keyframe_selection()
		keyframe_cleared.emit()
	selected_node = node if children.has(node) else null
	_rebuild_rows()
	for i in range(rows.size()):
		if rows[i].node == selected_node and get_parent() is ScrollContainer:
			var scroll := get_parent() as ScrollContainer
			var top := HEADER_HEIGHT + i * ROW_HEIGHT
			if top < scroll.scroll_vertical:
				scroll.scroll_vertical = int(top)
			elif top + ROW_HEIGHT > scroll.scroll_vertical + scroll.size.y:
				scroll.scroll_vertical = int(top + ROW_HEIGHT - scroll.size.y)


func set_playhead(value: float) -> void:
	frame = value
	queue_redraw()
	_update_details()


func row_keys(node: Node3D) -> Dictionary:
	return subtree_keys.get(node, {}) if collapsed.get(node, false) else keys.get(node, {})


func element_name(node: Node3D) -> String:
	return str(node.get_meta("shape_element").get("name", "Unnamed element"))


func get_hierarchy_width() -> float:
	return clampf(hierarchy_width, MIN_HIERARCHY_WIDTH, maxf(size.x - MIN_TRACK_WIDTH, MIN_HIERARCHY_WIDTH))


func set_hierarchy_width(value: float) -> void:
	hierarchy_width = clampf(value, MIN_HIERARCHY_WIDTH, maxf(size.x - MIN_TRACK_WIDTH, MIN_HIERARCHY_WIDTH))
	hierarchy_width_changed.emit(get_hierarchy_width())
	queue_redraw()


func frame_x(value: float) -> float:
	var start := get_hierarchy_width() + TRACK_LEFT_PADDING
	var duration := maxf(float(clip.get("frames", 1)) - 1.0, 1.0)
	var track_width := maxf(size.x - start - TRACK_RIGHT_PADDING, 1.0)
	return start + value / duration * track_width


func _frame_at(x: float) -> float:
	return clampf(roundf((x - frame_x(0)) / maxf(frame_x(clip.get("frames", 1) - 1) - frame_x(0), 1.0) * (clip.get("frames", 1) - 1)), 0, clip.get("frames", 1) - 1)


func _draw() -> void:
	var font := get_theme_default_font()
	var width := get_hierarchy_width()
	draw_rect(Rect2(Vector2.ZERO, size), Palette.workspace)
	draw_rect(Rect2(0, 0, size.x, HEADER_HEIGHT), Palette.chrome)
	draw_string(font, Vector2(8, 17), "SHAPE / KEYFRAMES", HORIZONTAL_ALIGNMENT_LEFT, width - 12, 11, Palette.muted)
	for i in range(rows.size()):
		var row: Dictionary = rows[i]
		var y := HEADER_HEIGHT + i * ROW_HEIGHT
		var picked: bool = (row.node == selected_node and not row.has("channel") and selected_channel.is_empty()) \
			or (row.has("channel") and selected_channel.get("node") == row.node and selected_channel.get("channel") == row.channel)
		var background: Color = Palette.selection if picked else (Palette.chrome if i % 2 == 0 else Palette.workspace)
		if row.has("channel") and not picked:
			background = background.lerp(Palette.surface, 0.5)
		draw_rect(Rect2(0, y, size.x, ROW_HEIGHT), background)
		var indent: float = minf(8 + row.depth * 12, width - 40)
		if row.has("channel"):
			var axis_color: Color = Palette.muted
			if not row.channel in CHANNEL_GROUPS:
				axis_color = [Palette.axis_x, Palette.axis_y, Palette.axis_z][["X", "Y", "Z"].find(row.channel.right(1))]
			draw_string(font, Vector2(indent + 14, y + 17), _channel_label(row.channel), HORIZONTAL_ALIGNMENT_LEFT, width - indent - 22, 11, axis_color)
			for time in row_times(row):
				var chosen := _contains(selected_keys, {"node": row.node, "frame": int(time)})
				var shift := _gesture_shift(int(time), chosen)
				var dot := Vector2(frame_x(int(time) + shift), y + ROW_HEIGHT * 0.5)
				draw_circle(dot, 3.5, Palette.key_selection if chosen else (Palette.accent if row.channel in CHANNEL_GROUPS else Color(axis_color, 0.85)))
			continue
		if keys.get(row.node, {}).size() > 0:
			var open: bool = channels_open.get(row.node, false)
			var box := Rect2(width - EXPANDER_WIDTH - 4, y + 5, EXPANDER_WIDTH - 4, ROW_HEIGHT - 10)
			draw_rect(box, Palette.border_light, false, 1.0)
			draw_line(Vector2(box.position.x + 3, box.get_center().y), Vector2(box.end.x - 3, box.get_center().y), Palette.muted)
			if not open:
				draw_line(Vector2(box.get_center().x, box.position.y + 3), Vector2(box.get_center().x, box.end.y - 3), Palette.muted)
		if not children[row.node].is_empty():
			var center := Vector2(indent + 4, y + ROW_HEIGHT * 0.5)
			var points := PackedVector2Array([center + Vector2(-3, -4), center + Vector2(3, 0), center + Vector2(-3, 4)]) if collapsed.get(row.node, false) else PackedVector2Array([center + Vector2(-4, -2), center + Vector2(4, -2), center + Vector2(0, 4)])
			draw_colored_polygon(points, Palette.muted)
		var label := element_name(row.node)
		while label.length() > 1 and font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x > width - indent - 22 - EXPANDER_WIDTH:
			label = label.left(label.length() - 2) + "…"
		draw_string(font, Vector2(indent + 14, y + 17), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Palette.text)
		var markers := _visible_markers(row)
		if show_generated:
			_draw_generated_keys(row.node, y, markers)
		for time in markers:
			var center := Vector2(frame_x(time), y + ROW_HEIGHT * 0.5)
			var points := PackedVector2Array([center + Vector2(0, -5), center + Vector2(5, 0), center + Vector2(0, 5), center + Vector2(-5, 0)])
			var marker: Dictionary = markers[time]
			draw_colored_polygon(points, Palette.accent if marker.own else Palette.muted)
			if not marker.own:
				draw_circle(center, 2, background)
			if marker.selected:
				var outline := PackedVector2Array([center + Vector2(0, -7), center + Vector2(7, 0), center + Vector2(0, 7), center + Vector2(-7, 0), center + Vector2(0, -7)])
				draw_polyline(outline, Palette.key_selection, 2.0, true)
	if not clip.is_empty():
		var step := 1
		for candidate in TICK_INTERVALS:
			step = candidate
			if (frame_x(candidate) - frame_x(0)) >= MIN_TICK_SPACING:
				break
		for time in range(0, clip.frames, step):
			var x := frame_x(time)
			draw_line(Vector2(x, HEADER_HEIGHT), Vector2(x, size.y), Color(Palette.border_light, 0.3))
			draw_string(font, Vector2(x - 3, 17), str(time), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Palette.muted)
		var x := frame_x(frame)
		draw_line(Vector2(x, HEADER_HEIGHT - 5), Vector2(x, size.y), Palette.accent, 1.0)
		_draw_markers(font)
		_draw_scale_handles()
	else:
		draw_string(font, Vector2(width + 16, 50), "Select an animation to view its keyframes", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Palette.muted)
	draw_rect(Rect2(width - 3, 0, 6, size.y), Palette.border)
	draw_line(Vector2(width, 6), Vector2(width, HEADER_HEIGHT - 6), Palette.muted, 2.0)
	if gesture == "box" and gesture_started:
		var area := Rect2(press_position, pointer_position - press_position).abs()
		draw_rect(area, Color(Palette.key_selection, 0.12))
		draw_rect(area, Palette.key_selection, false, 1.0)


func _draw_generated_keys(node: Node3D, y: float, authored_markers: Dictionary) -> void:
	var times: Dictionary = generated_times.get(node, {}).duplicate()
	if collapsed.get(node, false):
		var pending: Array = children.get(node, []).duplicate()
		while not pending.is_empty():
			var child = pending.pop_back()
			times.merge(generated_times.get(child, {}))
			pending.append_array(children.get(child, []))
	for time in times:
		if authored_markers.has(time):
			continue
		var center := Vector2(frame_x(time), y + ROW_HEIGHT * 0.5)
		draw_colored_polygon(PackedVector2Array([
			center + Vector2(0, -3), center + Vector2(3, 0),
			center + Vector2(0, 3), center + Vector2(-3, 0),
		]), Color(Palette.muted, 0.4))


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_DELETE:
		_delete_selection()
		accept_event()
		return

	if event is InputEventMouseMotion:
		_update_pointer_gesture(event)
	elif event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			_open_keyframe_menu(event)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_begin_pointer_gesture(event)
			else:
				_finish_pointer_gesture()


func _open_keyframe_menu(event: InputEventMouseButton) -> void:
	if not gesture.is_empty() or resizing_hierarchy:
		return

	grab_focus()
	if event.position.y < HEADER_HEIGHT and _timeline_marker_at(event.position) >= 0:
		marker_menu_index = _timeline_marker_at(event.position)
		marker_menu.position = Vector2i(get_screen_transform() * event.position)
		marker_menu.popup()
		accept_event()
		return
	var hit: Dictionary = _hit_marker(event.position) if event.position.x > get_hierarchy_width() else {}
	if not hit.is_empty():
		var clicked := _marker_keys(hit.node, hit.frame)
		if not clicked.all(func(key: Dictionary): return _contains(selected_keys, key)):
			selected_keys = clicked
		selected_node = hit.node
		frame_selected.emit(hit.frame)
		_notify_selection()
	elif event.position.x > get_hierarchy_width() and not clip.is_empty():
		frame_selected.emit(_frame_at(event.position.x))
	key_menu.set_item_disabled(0, selected_keys.is_empty())
	key_menu.set_item_disabled(1, selected_keys.is_empty())
	key_menu.set_item_disabled(2, not clipboard_available or clip.is_empty())
	for id in [3]:
		key_menu.set_item_disabled(key_menu.get_item_index(id), not clipboard_available or clip.is_empty())
	for id in [4, 5, 6]:
		key_menu.set_item_disabled(key_menu.get_item_index(id), clip.is_empty())
	key_menu.position = Vector2i(get_screen_transform() * event.position)
	key_menu.popup()
	accept_event()


func _update_pointer_gesture(event: InputEventMouseMotion) -> void:
	if resizing_hierarchy:
		set_hierarchy_width(event.position.x)
	elif not gesture.is_empty():
		pointer_position = event.position
		if event.position.distance_to(press_position) >= DRAG_START_DISTANCE:
			gesture_started = true
		if gesture_started and gesture == "move":
			var desired := roundi((event.position.x - press_position.x) / pixels_per_frame)
			drag_delta = _bounded_delta(desired)
		elif gesture_started and gesture == "scale":
			var moved_end := float(_frame_at(event.position.x))
			var fixed_span := _scale_span.y - scale_pivot if _scale_span.y != scale_pivot else _scale_span.x - scale_pivot
			scale_factor = maxf((moved_end - scale_pivot) / fixed_span, 0.05) if absf(fixed_span) > 0.0 else 1.0
		elif gesture == "marker":
			dragged_marker_frame = int(_frame_at(event.position.x))
		elif gesture_started and gesture == "box":
			_box_select()
		queue_redraw()
	mouse_default_cursor_shape = Control.CURSOR_HSPLIT if resizing_hierarchy or absf(event.position.x - get_hierarchy_width()) <= DIVIDER_HIT_RADIUS else Control.CURSOR_POINTING_HAND


func _finish_pointer_gesture() -> void:
	resizing_hierarchy = false
	if gesture == "scale":
		var factor := scale_factor
		gesture = ""
		gesture_started = false
		queue_redraw()
		if not is_equal_approx(factor, 1.0):
			scale_requested.emit(selection_for_document(), scale_pivot, factor)
		accept_event()
		return
	if gesture == "marker":
		gesture = ""
		var list := markers()
		if dragged_marker >= 0 and dragged_marker < list.size() and int(list[dragged_marker].frame) != dragged_marker_frame:
			list[dragged_marker].frame = dragged_marker_frame
			markers_changed.emit(list)
		dragged_marker = -1
		queue_redraw()
		accept_event()
		return
	var move := gesture == "move" and gesture_started and drag_delta != 0
	var delta := drag_delta
	var moving := selection_for_document()
	if gesture == "move" and not gesture_started and not additive:
		selected_keys = clicked_keys.duplicate()
	gesture = ""
	drag_delta = 0
	gesture_started = false
	_notify_selection()
	if move:
		move_requested.emit(moving, delta)
	accept_event()


func _begin_pointer_gesture(event: InputEventMouseButton) -> void:
	grab_focus()
	if absf(event.position.x - get_hierarchy_width()) <= DIVIDER_HIT_RADIUS:
		resizing_hierarchy = true
		accept_event()
		return

	if event.position.x < get_hierarchy_width():
		_select_hierarchy_row(event.position)
		return

	_begin_timeline_selection(event)


func _select_hierarchy_row(position: Vector2) -> void:
	var index := floori((position.y - HEADER_HEIGHT) / ROW_HEIGHT)
	if index >= 0 and index < rows.size():
		var row: Dictionary = rows[index]
		var indent: float = minf(8 + row.depth * 12, get_hierarchy_width() - 40)
		if row.has("channel"):
			clear_keyframe_selection()
			keyframe_cleared.emit()
			selected_node = row.node
			selected_channel = {"node": row.node, "channel": row.channel}
			element_selected.emit(row.node)
			queue_redraw()
		elif position.x >= get_hierarchy_width() - EXPANDER_WIDTH - 6 and keys.get(row.node, {}).size() > 0:
			set_channels_open(row.node, not channels_open.get(row.node, false))
		elif position.x >= indent - 2 and position.x <= indent + 12 and not children[row.node].is_empty():
			set_collapsed(row.node, not collapsed.get(row.node, false))
			element_collapsed.emit(row.node, collapsed[row.node])
		else:
			clear_keyframe_selection()
			keyframe_cleared.emit()
			selected_node = row.node
			selected_channel = {}
			element_selected.emit(row.node)
	accept_event()


func _begin_timeline_selection(event: InputEventMouseButton) -> void:
	press_position = event.position
	pointer_position = event.position
	additive = event.ctrl_pressed or event.meta_pressed
	base_selection = selected_keys.duplicate()
	gesture_started = false
	drag_delta = 0
	pixels_per_frame = maxf(frame_x(1) - frame_x(0), MIN_PIXELS_PER_FRAME)
	var handle := _scale_handle_at(event.position)
	if not handle.is_empty():
		gesture = "scale"
		scale_pivot = handle.pivot
		scale_factor = 1.0
		_scale_span = handle.span
		accept_event()
		return
	if event.position.y < HEADER_HEIGHT:
		var mark := _timeline_marker_at(event.position)
		if mark >= 0:
			gesture = "marker"
			dragged_marker = mark
			dragged_marker_frame = int(markers()[mark].frame)
			frame_selected.emit(dragged_marker_frame)
			accept_event()
			return
	var hit := _hit_marker(event.position)
	if not hit.is_empty():
		selected_node = hit.node
		clicked_keys = _marker_keys(hit.node, hit.frame, hit.get("row", -1))
		var all_selected := clicked_keys.all(func(key: Dictionary): return _contains(selected_keys, key))
		if additive:
			for key in clicked_keys:
				if all_selected:
					_remove_selected(key)
				elif not _contains(selected_keys, key):
					selected_keys.append(key)
		elif not all_selected:
			selected_keys = clicked_keys.duplicate()
		gesture = "move" if clicked_keys.any(func(key: Dictionary): return _contains(selected_keys, key)) else "toggle"
		frame_selected.emit(hit.frame)
	else:
		gesture = "box"
		if not additive:
			selected_keys.clear()
		if not clip.is_empty():
			frame_selected.emit(_frame_at(event.position.x))
	_notify_selection()
	_update_details()
	accept_event()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and (not gesture.is_empty() or resizing_hierarchy):
		if not gesture.is_empty():
			selected_keys = base_selection.duplicate()
		gesture = ""
		resizing_hierarchy = false
		drag_delta = 0
		gesture_started = false
		_notify_selection()
		get_viewport().set_input_as_handled()


func _delete_selection() -> void:
	if not selected_keys.is_empty() and gesture.is_empty() and not resizing_hierarchy:
		delete_requested.emit(selection_for_document())


func _key_menu_action(id: int) -> void:
	match id:
		0: _delete_selection()
		1: copy_selection()
		2: paste_at_playhead()
		3: paste_mirrored_requested.emit(roundi(frame))
		4: frames_requested.emit(roundi(frame), 1)
		5: frames_requested.emit(roundi(frame), -1)
		6: add_marker(roundi(frame))


func copy_selection() -> void:
	copy_requested.emit(selection_for_document())


func paste_at_playhead() -> void:
	paste_requested.emit(roundi(frame))


func _hit_marker(point: Vector2) -> Dictionary:
	var index := floori((point.y - HEADER_HEIGHT) / ROW_HEIGHT)
	if index < 0 or index >= rows.size():
		return {}

	var node: Node3D = rows[index].node
	var nearest := MARKER_HIT_RADIUS
	var result: Dictionary = {}
	for time in row_times(rows[index]):
		var center := Vector2(frame_x(time), HEADER_HEIGHT + (index + 0.5) * ROW_HEIGHT)
		var distance := center.distance_to(point)
		if distance < nearest:
			nearest = distance
			result = {"node": node, "frame": int(time), "row": index}
	return result


func _marker_keys(node: Node3D, time: int, row_index := -1) -> Array:
	var result: Array = []
	var source: Dictionary = row_times(rows[row_index]) if row_index >= 0 and row_index < rows.size() else row_keys(node)
	for entry in source.get(time, []):
		var key := {"node": entry.node, "frame": time}
		if not _contains(result, key):
			result.append(key)
	return result


func _contains(selection: Array, key: Dictionary) -> bool:
	return selection.any(func(other: Dictionary): return other.frame == key.frame and element_name(other.node) == element_name(key.node))


func _remove_selected(key: Dictionary) -> void:
	for i in range(selected_keys.size() - 1, -1, -1):
		if selected_keys[i].frame == key.frame and element_name(selected_keys[i].node) == element_name(key.node):
			selected_keys.remove_at(i)


func _bounded_delta(value: int) -> int:
	var maximum := int(clip.get("frames", 1)) - 1
	for key in selected_keys:
		maximum = mini(maximum, int(clip.get("frames", 1)) - 1 - int(key.frame))
	var first := int(clip.get("frames", 1)) - 1
	for key in selected_keys:
		first = mini(first, int(key.frame))
	return clampi(value, -first, maximum)


func _box_select() -> void:
	selected_keys = base_selection.duplicate() if additive else []
	var area := Rect2(press_position, pointer_position - press_position).abs()
	for i in range(rows.size()):
		var node: Node3D = rows[i].node
		for time in row_times(rows[i]):
			var center := Vector2(frame_x(time), HEADER_HEIGHT + (i + 0.5) * ROW_HEIGHT)
			if area.grow(3).has_point(center):
				for key in _marker_keys(node, time, i):
					if not _contains(selected_keys, key):
						selected_keys.append(key)
	_notify_selection()


func _visible_markers(row: Dictionary) -> Dictionary:
	var node: Node3D = row.node
	var result: Dictionary = {}
	var times := row_times(row)
	for time in times:
		for entry in times[time]:
			var chosen := _contains(selected_keys, {"node": entry.node, "frame": int(time)})
			var position := int(time) + _gesture_shift(int(time), chosen)
			if not result.has(position):
				result[position] = {"own": false, "selected": false}
			result[position].own = result[position].own or entry.node == node
			result[position].selected = result[position].selected or chosen
	return result


## How far a key is shown from its frame during a move or scale drag.
func _gesture_shift(time: int, chosen: bool) -> int:
	if not chosen:
		return 0
	if gesture == "move":
		return drag_delta
	if gesture == "scale" and gesture_started:
		return roundi(scale_pivot + (time - scale_pivot) * scale_factor) - time
	return 0


func selection_for_document() -> Array:
	return selected_keys.map(func(key: Dictionary): return {"element": element_name(key.node), "frame": int(key.frame)})


func restore_document_selection(selection: Array) -> void:
	var values: Array = []
	for key in selection:
		for node in children:
			if element_name(node) == key.element:
				values.append({"node": node, "frame": int(key.frame)})
				break
	restore_selection(values)


func restore_selection(selection: Array) -> void:
	selected_keys.clear()
	for key in selection:
		if is_instance_valid(key.node) and not _pose_for(key).is_empty():
			selected_keys.append(key)
	_notify_selection()


func _pose_for(key: Dictionary) -> Dictionary:
	for record in clip.get("keyframes", []):
		if record.frame == key.frame and record.get("elements", {}).has(element_name(key.node)):
			return {"node": key.node, "pose": record.elements[element_name(key.node)]}

	return {}


func _collapsed_selection(key: Dictionary) -> bool:
	var node: Node = key.node
	while node != null:
		if collapsed.get(node, false):
			return true

		node = node.get_parent()
	return false


func _notify_selection() -> void:
	selected_key_node = selected_keys[0].node if selected_keys.size() == 1 else null
	selected_key_frame = selected_keys[0].frame if selected_keys.size() == 1 else -1
	if selected_keys.size() == 1 and not _collapsed_selection(selected_keys[0]):
		var entry := _pose_for(selected_keys[0])
		if not entry.is_empty():
			keyframe_selected.emit([entry], selected_key_frame)
		else:
			keyframe_cleared.emit()
	else:
		keyframe_cleared.emit()
	queue_redraw()


func select_keyframe(node: Node3D, time: int) -> void:
	selected_keys = [{"node": node, "frame": time}]
	selected_key_node = node
	selected_key_frame = time
	queue_redraw()


func clear_keyframe_selection() -> void:
	selected_keys.clear()
	selected_key_node = null
	selected_key_frame = -1
	queue_redraw()


func _update_details() -> void:
	var text := "Select a shape or keyframe · Solid: own keys · Hollow: collapsed descendants"
	if is_instance_valid(selected_node) and children.has(selected_node):
		var entries: Array = row_keys(selected_node).get(roundi(frame), [])
		var summaries: PackedStringArray = []
		for entry in entries:
			var properties: PackedStringArray = []
			for group in PROPERTY_GROUPS:
				var axes: PackedStringArray = []
				for axis in ["X", "Y", "Z"]:
					if entry.pose.get(group + axis) != null:
						axes.append("%s %s" % [axis, str(entry.pose[group + axis])])
				if not axes.is_empty():
					properties.append("%s: %s" % [PROPERTY_GROUPS[group], ", ".join(axes)])
			var shortest: PackedStringArray = []
			for axis in ["X", "Y", "Z"]:
				if entry.pose.get("rotShortestDistance" + axis, false) == true:
					shortest.append(axis)
			if not shortest.is_empty():
				properties.append("Shortest rotation: " + ", ".join(shortest))
			summaries.append("%s — %s" % [element_name(entry.node), " · ".join(properties) if not properties.is_empty() else "No transform properties"])
		text = "Frame %d · %s" % [roundi(frame), "\n".join(summaries) if not summaries.is_empty() else element_name(selected_node) + " — No properties keyed on this frame"]
	details_changed.emit(text)



# --- Markers and scaling ---------------------------------------------------------------

func markers() -> Array:
	var source: Variant = clip.get("source", {})
	var value: Variant = source.get("markers", []) if source is Dictionary else []
	var result: Array = []
	for marker in value if value is Array else []:
		if marker is Dictionary:
			result.append(marker.duplicate())
	return result


func _timeline_marker_at(point: Vector2) -> int:
	var list := markers()
	for i in range(list.size()):
		if absf(frame_x(int(list[i].frame)) - point.x) <= 6.0:
			return i
	return -1


func add_marker(time: int, name_value := "") -> void:
	var list := markers()
	if name_value.is_empty():
		name_value = "Marker %d" % (list.size() + 1)
	list.append({"frame": time, "name": name_value})
	markers_changed.emit(list)


func rename_marker(index: int, name_value: String) -> void:
	var list := markers()
	if index >= 0 and index < list.size() and not name_value.strip_edges().is_empty():
		list[index].name = name_value.strip_edges()
		markers_changed.emit(list)


func delete_marker(index: int) -> void:
	var list := markers()
	if index >= 0 and index < list.size():
		list.remove_at(index)
		markers_changed.emit(list)


func begin_rename_marker(index: int) -> void:
	var list := markers()
	if index < 0 or index >= list.size():
		return
	marker_menu_index = index
	rename_field.text = str(list[index].name)
	rename_popup.position = Vector2i(get_screen_transform() * Vector2(frame_x(int(list[index].frame)), HEADER_HEIGHT))
	rename_popup.popup()
	rename_field.grab_focus()
	rename_field.select_all()


func _draw_markers(font: Font) -> void:
	var list := markers()
	for i in range(list.size()):
		var time: int = dragged_marker_frame if i == dragged_marker and gesture == "marker" else int(list[i].frame)
		var x := frame_x(time)
		draw_colored_polygon(PackedVector2Array([Vector2(x - 4, HEADER_HEIGHT - 7), Vector2(x + 4, HEADER_HEIGHT - 7), Vector2(x, HEADER_HEIGHT - 1)]), Palette.key_selection)
		draw_line(Vector2(x, HEADER_HEIGHT), Vector2(x, size.y), Color(Palette.key_selection, 0.35), 1.0)
		var text := str(list[i].name)
		var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10)
		draw_rect(Rect2(x + 3, 1, text_size.x + 4, 12), Color(Palette.chrome, 0.9))
		draw_string(font, Vector2(x + 5, 11), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Palette.key_selection)


## The selected keys' first and last frame, when they span more than one.
func _selection_span() -> Vector2:
	if selected_keys.size() < 2:
		return Vector2.ZERO
	var first := INF
	var last := -INF
	for key in selected_keys:
		first = minf(first, key.frame)
		last = maxf(last, key.frame)
	return Vector2(first, last) if last > first else Vector2.ZERO


## Scale handles sit at both ends of the selection, under the ruler. Drag one
## to stretch or squeeze the selected keys in time around the other end.
func _scale_handle_at(point: Vector2) -> Dictionary:
	var span := _selection_span()
	if span == Vector2.ZERO or point.y < HEADER_HEIGHT - 9 or point.y > HEADER_HEIGHT + 2:
		return {}
	if absf(point.x - (frame_x(span.y) + 6)) <= 5:
		return {"pivot": span.x, "span": span}
	if absf(point.x - (frame_x(span.x) - 6)) <= 5:
		return {"pivot": span.y, "span": span}
	return {}


func _draw_scale_handles() -> void:
	var span := _selection_span()
	if span == Vector2.ZERO:
		return
	var left := frame_x(span.x)
	var right := frame_x(span.y)
	if gesture == "scale" and gesture_started:
		left = frame_x(scale_pivot + (span.x - scale_pivot) * scale_factor)
		right = frame_x(scale_pivot + (span.y - scale_pivot) * scale_factor)
	draw_line(Vector2(left, HEADER_HEIGHT - 3), Vector2(right, HEADER_HEIGHT - 3), Color(Palette.key_selection, 0.6), 2.0)
	for x in [left - 6, right + 6]:
		draw_rect(Rect2(x - 3, HEADER_HEIGHT - 9, 6, 10), Palette.key_selection)
