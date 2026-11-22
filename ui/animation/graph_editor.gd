extends VBoxContainer
## Animation → Graph: the selected element's channels as curves, coloured by
## axis (X red, Y green, Z blue; position solid, rotation and scale lighter).
## The channel list on the left shows or hides them.
##
## Click a key to select it (Shift adds); drag it up or down to change its
## value, or sideways to move the element's key in time. Drag a handle to
## shape the curve: the key's tangents become Aligned (or stay Broken).
## Interpolation and tangent mode apply to the selected keys; Use Preset
## returns them to the clip's ease preset. Middle-drag pans, the wheel zooms
## time (Ctrl: values). Dim dots show the baked game keys an export writes.

const Curves = preload("res://core/animation/channel_curves.gd")
const Baker = preload("res://core/animation/animation_baker.gd")
static var Palette = preload("res://ui/theme/editor_palette.tres")
const CHANNELS := ["offsetX", "offsetY", "offsetZ", "rotationX", "rotationY", "rotationZ", "stretchX", "stretchY", "stretchZ"]
const MARGIN_LEFT := 52.0
const MARGIN_BOTTOM := 18.0
const PICK_RADIUS := 7.0

var workspace
var editor
## The element whose channels are shown ("" for none).
var element := ""
var shown := {"offsetX": true, "offsetY": true, "offsetZ": true, "rotationX": true, "rotationY": true, "rotationZ": true,
	"stretchX": false, "stretchY": false, "stretchZ": false}
var normalize := false
var show_baked := true
## Selected keys: [{channel, frame}].
var selection: Array = []
## Visible area: frames on x, values on y.
var view := Rect2(0, -10, 30, 20)
var plot: Control
var channel_buttons: Dictionary = {}
var interp_choice: OptionButton
var mode_choice: OptionButton
var frame_field: SpinBox
var value_field: SpinBox
var note: Label
var _drag: Dictionary = {}
## Curves sampled in graph units ({channel: PackedVector2Array}) and the baked
## game keys ([{frame, channel, value}]): rebuilt only when the clip, the
## element or the shown channels change, not on every redraw.
var _curve_cache: Dictionary = {}
var _baked_cache: Array = []
var _baked_ready := false
var playhead_layer: Control
var _pan_from := Vector2.ZERO
var _updating := false
var _data: Dictionary = {}


## Channel groups in the list on the left, named as in the keyframe panel.
const GROUPS := {"offset": "Position", "rotation": "Rotation", "stretch": "Scale"}
var group_buttons: Dictionary = {}


func _init() -> void:
	name = "GraphEditor"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)
	# Key tools along the top: interpolation, tangents, the selected key's
	# frame and value; view options at the right.
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	add_child(bar)
	interp_choice = OptionButton.new()
	for label in ["Constant", "Linear", "Bezier"]:
		interp_choice.add_item(label)
	interp_choice.tooltip_text = "Interpolation: how the selected keys move on to the next key"
	interp_choice.item_selected.connect(func(index: int): if not _updating: set_interpolation(["constant", "linear", "bezier"][index]))
	bar.add_child(interp_choice)
	mode_choice = OptionButton.new()
	for label in ["Auto", "Auto Clamped", "Aligned", "Broken"]:
		mode_choice.add_item(label)
	mode_choice.tooltip_text = "Tangents: how the selected keys' handles are set"
	mode_choice.item_selected.connect(func(index: int): if not _updating: set_mode(Curves.MODES[index]))
	bar.add_child(mode_choice)
	var preset := Button.new()
	preset.text = "Use Preset"
	preset.tooltip_text = "Return the selected keys to the clip's ease preset"
	preset.pressed.connect(use_preset)
	bar.add_child(preset)
	bar.add_child(VSeparator.new())
	bar.add_child(_label("Frame"))
	frame_field = SpinBox.new()
	frame_field.step = 1
	frame_field.max_value = 100000
	frame_field.custom_minimum_size.x = 80
	frame_field.tooltip_text = "The selected key's frame"
	frame_field.value_changed.connect(func(value: float): if not _updating: move_selected_to(int(value)))
	bar.add_child(frame_field)
	bar.add_child(_label("Value"))
	value_field = SpinBox.new()
	value_field.step = 0.001
	value_field.min_value = -100000
	value_field.max_value = 100000
	value_field.custom_minimum_size.x = 90
	value_field.tooltip_text = "The selected key's value"
	value_field.value_changed.connect(func(value: float): if not _updating: set_selected_value(value))
	bar.add_child(value_field)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	var normal := CheckBox.new()
	normal.text = "Normalize"
	normal.tooltip_text = "Scale every curve to the same height"
	normal.toggled.connect(func(value: bool):
		normalize = value
		frame_all())
	bar.add_child(normal)
	var baked := CheckBox.new()
	baked.text = "Game keys"
	baked.button_pressed = true
	baked.tooltip_text = "Show the keys an export writes"
	baked.toggled.connect(func(value: bool):
		show_baked = value
		plot.queue_redraw())
	bar.add_child(baked)
	var frame := Button.new()
	frame.text = "Frame All"
	frame.tooltip_text = "Fit the shown curves in the view"
	frame.pressed.connect(frame_all)
	bar.add_child(frame)
	for control in bar.get_children():
		if control is Control:
			control.add_theme_font_size_override("font_size", 13)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	add_child(body)
	body.add_child(_build_channel_list())
	plot = Control.new()
	plot.name = "Plot"
	plot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	plot.custom_minimum_size.y = 140
	plot.clip_contents = true
	plot.focus_mode = Control.FOCUS_CLICK
	plot.draw.connect(_draw_plot)
	plot.gui_input.connect(_plot_input)
	body.add_child(plot)
	# The playhead moves every frame during playback: it has its own layer so
	# the curves are not redrawn for it.
	playhead_layer = Control.new()
	playhead_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	playhead_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	playhead_layer.draw.connect(_draw_playhead)
	plot.add_child(playhead_layer)
	note = Label.new()
	note.theme_type_variation = &"MutedLabel"
	note.add_theme_font_size_override("font_size", 12)
	add_child(note)


## The channels, grouped: a group's name shows or hides all three axes; X, Y
## and Z (in the axis colours) each show or hide one curve.
func _build_channel_list() -> Control:
	var panel := PanelContainer.new()
	panel.name = "Channels"
	panel.custom_minimum_size.x = 156
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.chrome
	style.border_color = Palette.border
	style.border_width_right = 1
	style.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", style)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	panel.add_child(list)
	var heading := Label.new()
	heading.text = "CHANNELS"
	heading.theme_type_variation = &"SectionHeading"
	list.add_child(heading)
	var colors := [Palette.axis_x, Palette.axis_y, Palette.axis_z]
	for group in GROUPS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 2)
		list.add_child(row)
		var title := Button.new()
		title.text = GROUPS[group]
		title.flat = true
		title.alignment = HORIZONTAL_ALIGNMENT_LEFT
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title.focus_mode = Control.FOCUS_NONE
		title.tooltip_text = "Show or hide every %s curve" % GROUPS[group].to_lower()
		title.add_theme_font_size_override("font_size", 13)
		title.pressed.connect(toggle_group.bind(group))
		row.add_child(title)
		group_buttons[group] = title
		for axis in range(3):
			var channel: String = group + ["X", "Y", "Z"][axis]
			var button := Button.new()
			button.toggle_mode = true
			button.button_pressed = shown[channel]
			button.text = ["X", "Y", "Z"][axis]
			button.custom_minimum_size = Vector2(26, 24)
			button.tooltip_text = "%s %s" % [GROUPS[group], button.text]
			button.focus_mode = Control.FOCUS_NONE
			button.add_theme_font_size_override("font_size", 12)
			for state in ["font_color", "font_hover_color"]:
				button.add_theme_color_override(state, Color(colors[axis], 0.55))
			for state in ["font_pressed_color", "font_hover_pressed_color"]:
				button.add_theme_color_override(state, colors[axis])
			button.toggled.connect(func(value: bool):
				shown[channel] = value
				_sync_group_titles()
				frame_all())
			row.add_child(button)
			channel_buttons[channel] = button
	_sync_group_titles()
	return panel


## A group's name: shows all three of its curves, or hides them when all show.
func toggle_group(group: String) -> void:
	var all_shown: bool = ["X", "Y", "Z"].all(func(axis: String): return shown[group + axis])
	for axis in ["X", "Y", "Z"]:
		channel_buttons[group + axis].set_pressed_no_signal(not all_shown)
		shown[group + axis] = not all_shown
	_sync_group_titles()
	frame_all()


func _sync_group_titles() -> void:
	for group in group_buttons:
		var any: bool = ["X", "Y", "Z"].any(func(axis: String): return shown[group + axis])
		group_buttons[group].add_theme_color_override("font_color", Palette.text if any else Palette.muted)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"FieldLabel"
	return label


func bind(target_workspace, target_editor) -> void:
	workspace = target_workspace
	editor = target_editor


func show_element(name_value: String) -> void:
	if name_value == element:
		refresh()
		return
	element = name_value
	selection.clear()
	frame_all()


# --- Data ----------------------------------------------------------------------------

func clip() -> Dictionary:
	if workspace == null or workspace.selected < 0 or workspace.selected >= editor.clips().size():
		return {}
	var value: Variant = editor.clips()[workspace.selected]
	return value if value is Dictionary else {}


## Every shown channel of the element: channel -> {keys, handles, cycle, length, loop, low, high}.
func channels() -> Dictionary:
	var result := {}
	var source := clip()
	if source.is_empty() or element.is_empty():
		return result
	for channel in CHANNELS:
		if not shown[channel]:
			continue
		var data := Curves.channel(source, element, channel)
		if data.keys.is_empty():
			continue
		data.handles = Curves.handles(data.keys, data.length, data.loop, data.cycle)
		var low := INF
		var high := -INF
		for key in data.keys:
			low = minf(low, key.v)
			high = maxf(high, key.v)
		data.low = low
		data.high = high
		result[channel] = data
	return result


## Redraws only the playhead (cheap; called while playing).
func show_playhead() -> void:
	playhead_layer.queue_redraw()


func _invalidate() -> void:
	_curve_cache.clear()
	_baked_cache.clear()
	_baked_ready = false


func refresh() -> void:
	_invalidate()
	_data = channels()
	_sync_fields()
	plot.queue_redraw()


func frame_all() -> void:
	_invalidate()
	_data = channels()
	var length := float(clip().get("quantityframes", 30)) if not clip().is_empty() else 30.0
	var low := INF
	var high := -INF
	for channel in _data:
		for step in range(0, int(length) * 2 + 1):
			var value := _value(channel, step * 0.5)
			low = minf(low, value)
			high = maxf(high, value)
	if low == INF:
		low = -1.0
		high = 1.0
	if is_equal_approx(low, high):
		low -= 1.0
		high += 1.0
	var pad := (high - low) * 0.1
	view = Rect2(-1, low - pad, length + 2, high - low + pad * 2)
	_sync_fields()
	plot.queue_redraw()


## A channel's curve value at `time`, in plot units (normalised if asked).
func _value(channel: String, time: float) -> float:
	var data: Dictionary = _data[channel]
	var value := Curves.sample(data.keys, data.handles, time, data.length, data.loop, data.cycle)
	return _plot_value(channel, value)


func _plot_value(channel: String, value: float) -> float:
	if not normalize:
		return value
	var data: Dictionary = _data[channel]
	var span: float = maxf(data.high - data.low, 0.0001)
	return (value - data.low) / span * 2.0 - 1.0


func _real_value(channel: String, plotted: float) -> float:
	if not normalize:
		return plotted
	var data: Dictionary = _data[channel]
	return (plotted + 1.0) * 0.5 * maxf(data.high - data.low, 0.0001) + data.low


func to_screen(frame: float, value: float) -> Vector2:
	var area := _area()
	return Vector2(area.position.x + (frame - view.position.x) / view.size.x * area.size.x,
		area.position.y + (view.end.y - value) / view.size.y * area.size.y)


func to_graph(point: Vector2) -> Vector2:
	var area := _area()
	return Vector2(view.position.x + (point.x - area.position.x) / area.size.x * view.size.x,
		view.end.y - (point.y - area.position.y) / area.size.y * view.size.y)


func _area() -> Rect2:
	return Rect2(MARGIN_LEFT, 4, maxf(plot.size.x - MARGIN_LEFT - 4, 1), maxf(plot.size.y - MARGIN_BOTTOM - 4, 1))


static func _color(channel: String) -> Color:
	var base: Color = [Palette.axis_x, Palette.axis_y, Palette.axis_z][["X", "Y", "Z"].find(channel.right(1))]
	if channel.begins_with("rotation"):
		return base.lightened(0.35)
	if channel.begins_with("stretch"):
		return base.darkened(0.25)
	return base


# --- Drawing --------------------------------------------------------------------------

func _draw_plot() -> void:
	var area := _area()
	plot.draw_rect(Rect2(Vector2.ZERO, plot.size), Palette.surface)
	var font := ThemeDB.fallback_font
	var frame_step := _nice_step(view.size.x / maxf(area.size.x / 60.0, 1.0))
	var start := ceilf(view.position.x / frame_step) * frame_step
	var x := start
	while x <= view.end.x:
		var p := to_screen(x, 0)
		plot.draw_line(Vector2(p.x, area.position.y), Vector2(p.x, area.end.y), Color(Palette.border_light, 0.35))
		plot.draw_string(font, Vector2(p.x + 2, plot.size.y - 4), str(int(x)) if is_equal_approx(x, roundf(x)) else "%.1f" % x, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Palette.muted)
		x += frame_step
	var value_step := _nice_step(view.size.y / maxf(area.size.y / 36.0, 1.0))
	var y := ceilf(view.position.y / value_step) * value_step
	while y <= view.end.y:
		var p := to_screen(0, y)
		plot.draw_line(Vector2(area.position.x, p.y), Vector2(area.end.x, p.y), Color(Palette.border_light, 0.6 if is_zero_approx(y) else 0.25))
		plot.draw_string(font, Vector2(4, p.y + 4), _short(y), HORIZONTAL_ALIGNMENT_LEFT, MARGIN_LEFT - 6, 11, Palette.muted)
		y += value_step
	var source := clip()
	if source.is_empty() or element.is_empty():
		plot.draw_string(font, area.get_center() - Vector2(120, 0), "Select an element with keys to see its curves.", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Palette.muted)
		return
	var length := float(source.get("quantityframes", 1))
	var end_x := to_screen(length, 0).x
	plot.draw_line(Vector2(end_x, area.position.y), Vector2(end_x, area.end.y), Color(Palette.muted, 0.6), 1.0)
	if show_baked:
		_draw_baked(source)
	for channel in _data:
		var color := _color(channel)
		var points := PackedVector2Array()
		for sample in _curve(channel):
			points.append(to_screen(sample.x, sample.y))
		if points.size() > 1:
			plot.draw_polyline(points, color, 1.5, true)
		var data: Dictionary = _data[channel]
		for i in range(data.keys.size()):
			var key: Dictionary = data.keys[i]
			var position := to_screen(key.f, _plot_value(channel, key.v))
			var selected := _is_selected(channel, int(key.f))
			if selected and key.interp == "bezier" or selected and i > 0 and data.keys[i - 1].interp == "bezier":
				for side in ["in", "out"]:
					var handle: Vector2 = data.handles[i][side]
					var tip := to_screen(key.f + handle.x, _plot_value(channel, key.v + handle.y))
					plot.draw_line(position, tip, Color(color, 0.8), 1.0)
					plot.draw_circle(tip, 3.5, color)
			var diamond := PackedVector2Array([position + Vector2(0, -5), position + Vector2(5, 0), position + Vector2(0, 5), position + Vector2(-5, 0)])
			plot.draw_colored_polygon(diamond, Palette.text if selected else color)
			plot.draw_polyline(diamond + PackedVector2Array([diamond[0]]), Palette.surface, 1.0)
	if _drag.get("kind") == "box":
		var box := Rect2(_drag.start, _drag.current - _drag.start).abs()
		plot.draw_rect(box, Color(Palette.key_selection, 0.12))
		plot.draw_rect(box, Palette.key_selection, false, 1.0)


func _draw_playhead() -> void:
	if workspace == null or clip().is_empty():
		return
	var area := _area()
	var x := to_screen(workspace.frame, 0).x
	if x >= area.position.x and x <= area.end.x:
		playhead_layer.draw_line(Vector2(x, area.position.y), Vector2(x, area.end.y), Palette.accent, 1.5)


## A channel's curve in graph units, sampled four times a frame across the
## clip (and a little either side), plus every key.
func _curve(channel: String) -> PackedVector2Array:
	if _curve_cache.has(channel):
		return _curve_cache[channel]
	var data: Dictionary = _data[channel]
	var length := float(data.length)
	var times: Array = []
	var time := -2.0
	while time <= length + 2.0:
		times.append(time)
		time += 0.25
	for key in data.keys:
		times.append(float(key.f))
	times.sort()
	var result := PackedVector2Array()
	for t in times:
		result.append(Vector2(t, _value(channel, t)))
	_curve_cache[channel] = result
	return result


func _draw_baked(source: Dictionary) -> void:
	if not _baked_ready:
		_baked_ready = true
		var baked: Dictionary = Baker.bake_clip(source, Baker.settings(workspace.viewport.shape_data) if workspace != null else Baker.DEFAULT_SETTINGS)
		if baked.error.is_empty():
			for key in baked.clip.get("keyframes", []):
				var pose: Variant = key.get("elements", {}).get(element)
				if not pose is Dictionary:
					continue
				for channel in _data:
					if pose.get(channel) == null:
						continue
					var value := float(pose[channel])
					# Rotation keys are raw degrees; draw them on the unwrapped curve.
					if channel.begins_with("rotation"):
						var near := _value(channel, float(key.frame))
						value += roundf((near - _plot_value(channel, value)) / 360.0) * 360.0 if not normalize else 0.0
					_baked_cache.append({"frame": float(key.frame), "channel": channel, "value": _plot_value(channel, value)})
	for dot in _baked_cache:
		if _data.has(dot.channel):
			plot.draw_circle(to_screen(dot.frame, dot.value), 2.0, Color(_color(dot.channel), 0.45))


static func _nice_step(raw: float) -> float:
	var power := pow(10.0, floorf(log(maxf(raw, 0.0001)) / log(10.0)))
	for factor in [1.0, 2.0, 5.0, 10.0]:
		if raw <= power * factor:
			return power * factor
	return power * 10.0


static func _short(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) else ("%.2f" % value).trim_suffix("0")


# --- Selection and fields -------------------------------------------------------------

func _is_selected(channel: String, frame: int) -> bool:
	return selection.any(func(entry): return entry.channel == channel and entry.frame == frame)


func _key(channel: String, frame: int) -> Dictionary:
	for key in _data.get(channel, {}).get("keys", []):
		if int(key.f) == frame:
			return key
	return {}


func _sync_fields() -> void:
	_updating = true
	selection = selection.filter(func(entry): return not _key(entry.channel, entry.frame).is_empty())
	var editable := not selection.is_empty()
	for control in [interp_choice, mode_choice]:
		control.disabled = not editable
	frame_field.editable = selection.size() == 1
	value_field.editable = selection.size() == 1
	if editable:
		var key := _key(selection[0].channel, selection[0].frame)
		interp_choice.select(Curves.INTERPOLATIONS.find(key.interp))
		mode_choice.select(maxi(Curves.MODES.find(key.mode), 0) if key.mode != "preset" else -1)
		frame_field.set_value_no_signal(key.f)
		value_field.set_value_no_signal(key.v)
		note.text = "%s · frame %d%s" % [selection[0].channel, selection[0].frame, " · preset " + key.preset.capitalize() if key.mode == "preset" else ""]
	else:
		note.text = "Click a key to edit it. Drag up or down to change its value, sideways to move it in time." if not _data.is_empty() else ""
	_updating = false


# --- Edits --------------------------------------------------------------------------------

func _curve_of(key: Dictionary, interp := "", mode := "", handles := {}) -> Dictionary:
	var result := {"interp": interp if not interp.is_empty() else (key.interp if key.mode != "preset" or key.interp != "linear" else "bezier"),
		"mode": mode if not mode.is_empty() else (key.mode if key.mode != "preset" else "auto_clamped")}
	result["in"] = handles.get("in", key["in"])
	result.out = handles.get("out", key.out)
	return result


func set_interpolation(interp: String) -> void:
	for entry in selection.duplicate():
		var key := _key(entry.channel, entry.frame)
		if not key.is_empty():
			editor.set_channel_curve(workspace.selected, entry.frame, element, entry.channel, _curve_of(key, interp))
	refresh()


func set_mode(mode: String) -> void:
	for entry in selection.duplicate():
		var key := _key(entry.channel, entry.frame)
		if key.is_empty():
			continue
		# Switching to a stored mode keeps the handles the key shows now.
		var index: int = _data[entry.channel].keys.find(key)
		var current: Dictionary = _data[entry.channel].handles[index]
		editor.set_channel_curve(workspace.selected, entry.frame, element, entry.channel,
			_curve_of(key, "bezier" if key.interp == "linear" and key.mode == "preset" else "", mode, {"in": current["in"], "out": current.out}))
	refresh()


func use_preset() -> void:
	for entry in selection.duplicate():
		editor.set_channel_curve(workspace.selected, entry.frame, element, entry.channel, null)
	refresh()


func set_selected_value(value: float) -> void:
	if selection.size() != 1:
		return
	editor.set_keyframe_property(workspace.selected, selection[0].frame, element, selection[0].channel, true, _raw_value(selection[0].channel, selection[0].frame, value))
	refresh()


func move_selected_to(frame: int) -> void:
	if selection.size() != 1 or frame == selection[0].frame:
		return
	var from: int = selection[0].frame
	# The edit refreshes the graph, so the selection must already name the new frame.
	var entry: Dictionary = selection[0]
	entry.frame = frame
	if not editor.move_keyframes(workspace.selected, [{"element": element, "frame": from}], frame - from, workspace.frame):
		entry.frame = from
		selection = [entry]
	refresh()


# --- Mouse ----------------------------------------------------------------------------------

func _plot_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var factor := 0.85 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.85
		var anchor := to_graph(event.position)
		if event.ctrl_pressed:
			view = Rect2(view.position.x, anchor.y - (anchor.y - view.position.y) * factor, view.size.x, view.size.y * factor)
		else:
			view = Rect2(anchor.x - (anchor.x - view.position.x) * factor, view.position.y, view.size.x * factor, view.size.y)
		plot.queue_redraw()
		plot.accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		_pan_from = event.position if event.pressed else Vector2.ZERO
		plot.accept_event()
	elif event is InputEventMouseMotion and _pan_from != Vector2.ZERO:
		var delta := to_graph(_pan_from) - to_graph(event.position)
		view.position += delta
		_pan_from = event.position
		plot.queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			press(event.position, event.shift_pressed)
		else:
			release(event.position)
		plot.accept_event()
	elif event is InputEventMouseMotion and not _drag.is_empty():
		_drag.current = event.position
		plot.queue_redraw()


## Selects every key inside a screen rectangle (adding to the selection when asked).
func box_select(area: Rect2, add := false) -> void:
	if not add:
		selection.clear()
	for channel in _data:
		for key in _data[channel].keys:
			if area.grow(2).has_point(to_screen(key.f, _plot_value(channel, key.v))) and not _is_selected(channel, int(key.f)):
				selection.append({"channel": channel, "frame": int(key.f)})
	_sync_fields()
	plot.queue_redraw()


## What lies under a point: {kind: "handle"|"key", channel, frame, side} or {}.
func hit(point: Vector2) -> Dictionary:
	for entry in selection:
		var data: Dictionary = _data.get(entry.channel, {})
		var key := _key(entry.channel, entry.frame)
		if key.is_empty():
			continue
		var index: int = data.keys.find(key)
		for side in ["in", "out"]:
			var handle: Vector2 = data.handles[index][side]
			if to_screen(key.f + handle.x, _plot_value(entry.channel, key.v + handle.y)).distance_to(point) <= PICK_RADIUS:
				return {"kind": "handle", "channel": entry.channel, "frame": entry.frame, "side": side}
	for channel in _data:
		for key in _data[channel].keys:
			if to_screen(key.f, _plot_value(channel, key.v)).distance_to(point) <= PICK_RADIUS:
				return {"kind": "key", "channel": channel, "frame": int(key.f)}
	return {}


func press(point: Vector2, add := false) -> void:
	var found := hit(point)
	if found.is_empty():
		# Empty space: a drag draws a selection box; a click moves the playhead.
		_drag = {"kind": "box", "start": point, "current": point, "add": add}
		return
	if found.kind == "key" and not _is_selected(found.channel, found.frame):
		if not add:
			selection.clear()
		selection.append({"channel": found.channel, "frame": found.frame})
	found.start = point
	found.current = point
	_drag = found
	_sync_fields()
	plot.queue_redraw()


func release(point: Vector2) -> void:
	var drag := _drag
	_drag = {}
	if drag.get("kind") == "box":
		if point.distance_to(drag.start) < 3.0:
			if not drag.add:
				selection.clear()
			if workspace != null:
				workspace.seek(clampf(roundf(to_graph(point).x), 0.0, float(clip().get("quantityframes", 1)) - 1.0))
		else:
			box_select(Rect2(drag.start, point - drag.start).abs(), drag.add)
		_sync_fields()
		plot.queue_redraw()
		return
	if drag.is_empty() or point.distance_to(drag.start) < 3.0:
		plot.queue_redraw()
		return
	var key := _key(drag.channel, drag.frame)
	if key.is_empty():
		return
	var at: Vector2 = to_graph(point)
	if drag.kind == "handle":
		drag_handle(drag.channel, drag.frame, drag.side, Vector2(at.x - key.f, _real_value(drag.channel, at.y) - key.v))
		return
	var moved: Vector2 = point - drag.start
	if absf(moved.x) > absf(moved.y):
		var delta := int(roundf(at.x - to_graph(drag.start).x))
		if delta != 0 and selection.size() == 1:
			move_selected_to(drag.frame + delta)
	else:
		var change: float = _real_value(drag.channel, at.y) - _real_value(drag.channel, to_graph(drag.start).y)
		for entry in selection:
			var target := _key(entry.channel, entry.frame)
			if not target.is_empty():
				editor.set_keyframe_property(workspace.selected, entry.frame, element, entry.channel, true, _raw_value(entry.channel, entry.frame, target.v + change))
	refresh()


## Rotation keys show unwrapped values; store the change on the raw value.
func _raw_value(channel: String, frame: int, lifted: float) -> float:
	if not channel.begins_with("rotation"):
		return lifted
	var raw: Variant = null
	for key in clip().get("keyframes", []):
		if int(key.frame) == frame and key.get("elements", {}).get(element) is Dictionary:
			raw = key.elements[element].get(channel)
	var current: float = _key(channel, frame).v
	return (float(raw) if raw != null else current) + (lifted - current)


## Sets one handle of a key (offset in frames and value), keeping the other
## handle on the same line unless the key's tangents are Broken.
func drag_handle(channel: String, frame: int, side: String, offset: Vector2) -> bool:
	var data: Dictionary = _data.get(channel, {})
	var key := _key(channel, frame)
	if key.is_empty():
		return false
	var index: int = data.keys.find(key)
	var current: Dictionary = data.handles[index]
	var mode: String = "broken" if key.mode == "broken" else "aligned"
	var other := "out" if side == "in" else "in"
	if side == "in":
		offset.x = minf(offset.x, -0.001)
	else:
		offset.x = maxf(offset.x, 0.001)
	var handles := {side: offset, other: current[other]}
	if mode == "aligned":
		var length: float = (current[other] as Vector2).length()
		handles[other] = -offset.normalized() * length
	var ok: bool = editor.set_channel_curve(workspace.selected, frame, element, channel, _curve_of(key, "bezier", mode, handles))
	refresh()
	return ok
