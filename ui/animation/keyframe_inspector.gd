extends PanelContainer
const Limits = preload("res://core/model/shape_limits.gd")

signal property_edited(property: String, enabled: bool, value: Variant)
signal closed
signal shape_selected(node: Node3D)
const GROUPS := {"offset": "Position · shape units", "rotation": "Rotation · degrees", "stretch": "Scale"}
static var Palette = preload("res://ui/theme/editor_palette.tres")
var entries: Array = []
var entry_index := 0
var key_frame := -1
var fields: Dictionary = {}
var curve_fields: Dictionary = {}
var pending: Dictionary = {}
var updating := false
var auto_shortest: CheckBox
@onready var shapes: OptionButton = %ShapeName


func _ready() -> void:
	%Close.pressed.connect(func():
		finish_pending()
		clear_selection()
		closed.emit())
	shapes.item_selected.connect(func(index: int):
		finish_pending()
		entry_index = index
		_sync_fields()
		shape_selected.emit(entries[index].node))
	_build_fields()


func _build_fields() -> void:
	for group in GROUPS:
		_build_transform_group(group)
	_build_shortest_path_fields()
	_build_stored_origin_label()


## A group: its name and curve on one line, then a row per axis.
func _build_transform_group(group: String) -> void:
	if %Fields.get_child_count() > 0:
		%Fields.add_child(_gap())
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = GROUPS[group].get_slice(" · ", 0)
	title.tooltip_text = GROUPS[group]
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	title.theme_type_variation = &"SectionHeading"
	title.uppercase = true
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(title)
	var interpolation = preload("res://ui/animation/interpolation_field.tscn").instantiate()
	interpolation.group = group
	header.add_child(interpolation)
	interpolation.get_node("Label").hide()
	var curve: OptionButton = interpolation.get_node("Curve")
	curve.custom_minimum_size.x = 104
	curve.add_theme_font_size_override("font_size", 12)
	curve.tooltip_text = "Curve to the next key. " + curve.tooltip_text
	%Fields.add_child(header)
	interpolation.curve_edited.connect(_edit_interpolation)
	curve_fields[group] = interpolation
	for axis in ["X", "Y", "Z"]:
		_build_transform_axis(group, axis)


func _gap() -> Control:
	var gap := Control.new()
	gap.custom_minimum_size.y = 6
	return gap


func _build_transform_axis(group: String, axis: String) -> void:
	var property: String = group + axis
	var row := HBoxContainer.new()
	var check := CheckBox.new()
	_style_checkbox(check)
	check.tooltip_text = "Key this axis on this frame"
	var label := Label.new()
	label.text = axis
	label.custom_minimum_size.x = 14
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", [Palette.axis_x, Palette.axis_y, Palette.axis_z]["XYZ".find(axis)])
	row.add_theme_constant_override("separation", 6)
	var value := SpinBox.new()
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.custom_minimum_size.x = 80
	value.get_line_edit().add_theme_font_size_override("font_size", 12)
	value.min_value = -Limits.MAX_COORDINATE
	value.max_value = Limits.MAX_COORDINATE
	value.step = 0.01
	value.allow_greater = false
	value.allow_lesser = false
	row.add_child(check)
	row.add_child(label)
	row.add_child(value)
	%Fields.add_child(row)
	fields[property] = {"check": check, "value": value}
	check.toggled.connect(func(enabled: bool):
		if not updating:
			property_edited.emit(property, enabled, value.value))
	value.value_changed.connect(func(number: float):
		if not updating and check.button_pressed:
			pending.erase(property)
			property_edited.emit(property, true, number))
	value.get_line_edit().text_changed.connect(func(_text: String):
		if not updating:
			pending[property] = value)


func _build_shortest_path_fields() -> void:
	%Fields.add_child(_gap())
	var shortest_title := Label.new()
	shortest_title.text = "Shortest rotation path"
	shortest_title.theme_type_variation = &"SectionHeading"
	shortest_title.uppercase = true
	%Fields.add_child(shortest_title)
	auto_shortest = CheckBox.new()
	_style_checkbox(auto_shortest)
	auto_shortest.text = "Auto"
	auto_shortest.add_theme_font_size_override("font_size", 12)
	auto_shortest.tooltip_text = "Choose per-axis flags by comparing eight Euler paths. Updates this and the preceding auto-managed rotation key, including the loop boundary. Disable for intentional spins or manual flags."
	%Fields.add_child(auto_shortest)
	auto_shortest.toggled.connect(func(value: bool):
		if not updating:
			property_edited.emit("autoShortestRotation", true, value))
	var axes := HBoxContainer.new()
	axes.add_theme_constant_override("separation", 12)
	%Fields.add_child(axes)
	for axis in ["X", "Y", "Z"]:
		var property: String = "rotShortestDistance" + axis
		var check := CheckBox.new()
		_style_checkbox(check)
		check.text = axis
		check.tooltip_text = "Take the shortest way round on %s" % axis
		check.add_theme_font_size_override("font_size", 12)
		axes.add_child(check)
		fields[property] = {"check": check}
		check.toggled.connect(func(value: bool):
			if not updating:
				property_edited.emit(property, true, value))


func _build_stored_origin_label() -> void:
	var stored := Label.new()
	stored.name = "StoredOrigin"
	stored.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stored.theme_type_variation = &"MutedLabel"
	stored.add_theme_font_size_override("font_size", 11)
	%Fields.add_child(stored)


func _style_checkbox(check: CheckBox) -> void:
	check.custom_minimum_size = Vector2(24, 26)
	check.add_theme_icon_override("checked", preload("res://assets/icons/key_checked.svg"))
	check.add_theme_icon_override("unchecked", preload("res://assets/icons/key_unchecked.svg"))
	var empty := StyleBoxEmpty.new()
	empty.set_content_margin_all(2)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		check.add_theme_stylebox_override(state, empty)
	var focus := StyleBoxFlat.new()
	focus.bg_color = Color.TRANSPARENT
	focus.border_color = Palette.accent
	focus.set_border_width_all(1)
	focus.set_content_margin_all(2)
	check.add_theme_stylebox_override("focus", focus)


func inspect(values: Array, time: int, preferred: Node3D = null) -> void:
	entries = values
	key_frame = time
	entry_index = 0
	shapes.clear()
	for i in range(entries.size()):
		var node: Node3D = entries[i].node
		shapes.add_item(str(node.get_meta("shape_element").get("name", "Unnamed element")))
		if node == preferred:
			entry_index = i
	if entries.is_empty():
		clear_selection()
		return

	shapes.select(entry_index)
	shapes.tooltip_text = shapes.get_item_text(entry_index)
	%FrameLabel.text = "Frame %d" % time
	_sync_fields()
	show()


func _sync_fields() -> void:
	updating = true
	pending.clear()
	var pose: Dictionary = entries[entry_index].pose
	for field in curve_fields.values():
		field.sync(pose)
	var auto: bool = preload("res://core/animation/rotation_paths.gd").auto_enabled(pose)
	auto_shortest.set_pressed_no_signal(auto)
	for property in fields:
		var controls: Dictionary = fields[property]
		if controls.has("value"):
			var enabled: bool = pose.get(property) != null
			controls.check.set_pressed_no_signal(enabled)
			controls.value.editable = enabled
			controls.value.set_value_no_signal(float(pose.get(property, 1 if property.begins_with("stretch") else 0)) if enabled else (1 if property.begins_with("stretch") else 0))
		else:
			controls.check.set_pressed_no_signal(pose.get(property, false) == true)
			controls.check.disabled = auto
	var origin: PackedStringArray = []
	for axis in ["X", "Y", "Z"]:
		if pose.get("origin" + axis) != null:
			origin.append("%s %s" % [axis, str(pose["origin" + axis])])
	var stored: Label = %Fields.get_node("StoredOrigin")
	stored.visible = not origin.is_empty()
	stored.text = "Stored origin: %s\nOrigin fields are preserved; playback uses position, rotation, and scale." % ", ".join(origin)
	updating = false


func selection() -> Dictionary:
	return {"node": entries[entry_index].node, "nodes": entries.map(func(entry: Dictionary): return entry.node), "frame": key_frame} if visible and not entries.is_empty() else {}


func _edit_interpolation(group: String, curve: String) -> void:
	if not updating:
		property_edited.emit("interpolation:" + group, true, curve)


func clear_selection() -> void:
	hide()
	entries.clear()
	key_frame = -1
	pending.clear()


func finish_pending() -> void:
	var controls := pending.values().duplicate()
	pending.clear()
	for control in controls:
		if is_instance_valid(control):
			control.apply()
