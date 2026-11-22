extends Node
static var Palette = preload("res://ui/theme/editor_palette.tres")
const ELEMENTS := {
	"shade": {"label": "Shaded", "type": "bool", "default": true},
	"gradientShade": {"label": "Gradient shading", "type": "bool", "default": false},
	"zOffset": {"label": "Depth offset", "type": "number", "default": 0, "min": -32768, "max": 32767},
	"disableRandomDrawOffset": {"label": "Disable random offset / rotation", "type": "bool", "default": false},
	"climateColorMap": {"label": "Climate color map", "type": "text", "default": ""},
	"seasonColorMap": {"label": "Season color map", "type": "text", "default": ""}}
const FACES := {
	"enabled": {"label": "Face enabled", "type": "bool", "default": true},
	"reflectiveMode": {"label": "Reflective mode", "type": "enum", "default": 0},
	"windMode": {"label": "Wind mode", "type": "wind_modes", "default": [0, 0, 0, 0]},
	"windData": {"label": "Wind data · per vertex", "type": "array", "default": [0, 0, 0, 0]}}
const REFLECTIVE := [
	"None",
	"Weak",
	"Medium",
	"Strong",
	"Sparkly",
	"Mild"
]
const REFLECTION_HELP := [
	"Matte: no reflective effect.",
	"Subtle textured sheen; weak reflectivity is described as sun-position independent.",
	"Textured sheen influenced by lighting.",
	"Brighter, stronger textured sheen.",
	"Many small glints that change as the camera moves.",
	"Shares the Strong reflection shader branch in the installed game version."
]
const WIND_MODES := [
	"No wind",
	"Weak wind",
	"Normal wind",
	"Leaves",
	"Bend",
	"Tall bend",
	"Water",
	"Extra weak wind",
	"Fruit",
	"Weak wind · no bend",
	"Weak wind · inverse bend",
	"Water plant"
]
const WIND_HELP := [
	"No wind deformation. Wind data is not a wind-strength control.",
	"Wind data adds to vertex height for bending (0–7).",
	"Wind data adds to vertex height for bending (0–7).",
	"Leaf wiggle and bending; data contributes to bending height (0–7).",
	"Stem bending without wiggle; data contributes to bending height (0–7).",
	"Tall-stem bending; data contributes to bending height (0–7).",
	"Water has specialized shader behavior; data is not a general strength percentage.",
	"Gentle sway; data contributes to bending height (0–7).",
	"Fruit sway; data coordinates fruit movement (0–7), not frost coverage.",
	"Weak wiggle without height bending; data does not control bend height.",
	"Inverse bending for vines; data contributes to bending height (0–7).",
	"Water-plant data controls sway strength and bending (0–7)."
]
var viewport_view
var face_panel
var details_panel
var edit_history
var document
const Document = preload("res://core/document/shape_document.gd")
const SetFields = preload("res://core/commands/set_element_fields.gd")
const SetFaceFields = preload("res://core/commands/set_face_fields.gd")

var element_fields: Dictionary = {}
var face_fields: Dictionary = {}
var updating := false
var pending: Dictionary = {}
var wind_help: Label
var reflection_help: Label
var shader_toggle: Button
var shader_content: VBoxContainer
var rendering_toggle: Button
var rendering_content: VBoxContainer
var glow_value: Label


## Called whenever a document opens or a new one starts.
func bind_document(target_document) -> void:
	document = target_document


func bind(view: Node, faces: Control, details: Control, history: Node) -> void:
	viewport_view = view
	face_panel = faces
	details_panel = details
	edit_history = history


func _ready() -> void:
	face_panel.extra_properties = self
	_build(details_panel.content, "Rendering", {"shade": ELEMENTS.shade, "zOffset": ELEMENTS.zOffset}, element_fields, false)
	_build(face_panel.get_node("Split/Scroll/Fields"), "Shader", FACES, face_fields, true)
	viewport_view.selection_changing.connect(finish_pending)
	viewport_view.selection_changed.connect(func(_node: Node3D): refresh())
	face_panel.face_selected.connect(func(_node: Node3D, _face: String): refresh())
	edit_history.changed.connect(refresh)
	edit_history.flush_pending.connect(finish_pending)
	refresh()


func _build(parent: VBoxContainer, title: String, schema: Dictionary, fields: Dictionary, face: bool) -> void:
	var panel = preload("res://ui/shared/collapsible_section.tscn").instantiate()
	panel.name = "Shader" if face else "Rendering"
	panel.title = title
	parent.add_child(panel)
	if not face:
		parent.move_child(panel, details_panel.render_pass_label.get_index())
	var content: VBoxContainer = panel.content
	if face:
		shader_toggle = panel.toggle
		shader_content = content
	else:
		rendering_toggle = panel.toggle
		rendering_content = content
	if not face:
		details_panel.render_pass_label.reparent(content)
		details_panel.render_pass.reparent(content)
	for key in schema:
		fields[key] = _build_field(content, key, schema[key], face)
		if face and key == "enabled":
			_build_glow_slider(content)
		if face and key == "reflectiveMode":
			_build_reflection_help(content)

	if face:
		wind_help = Label.new()
		wind_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		wind_help.add_theme_font_size_override("font_size", 11)
		content.add_child(wind_help)
	if face:
		var note := Label.new()
		note.text = "Reflection uses an approximate studio preview in Normal rendering. Wind deformation is not previewed."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.add_theme_font_size_override("font_size", 11)
		note.add_theme_color_override("font_color", Palette.muted)
		content.add_child(note)


func _build_field(content: VBoxContainer, key: String, spec: Dictionary, face: bool) -> Dictionary:
	var row := HBoxContainer.new()
	content.add_child(row)
	var label := Label.new()
	label.text = spec.label
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 12)
	row.add_child(label)
	var reset := Button.new()
	reset.text = "↺"
	reset.tooltip_text = "Use the game default (remove this property)"
	row.add_child(reset)
	reset.pressed.connect(func(): edit(face, key, null, true))
	var field := {"reset": reset, "type": spec.type}
	match spec.type:
		"bool":
			_build_boolean_field(row, field, face, key)
		"enum":
			_build_reflection_field(content, field, face, key)
		"number":
			_build_number_field(row, field, spec, face, key)
		"text":
			_build_text_field(content, field, face, key)
		"array", "wind_modes":
			_build_vertex_fields(content, row, field, face, key)
	return field


func _build_boolean_field(row: HBoxContainer, field: Dictionary, face: bool, key: String) -> void:
	var check := CheckBox.new()
	_style_check(check)
	row.add_child(check)
	field.input = check
	check.toggled.connect(func(value: bool):
		if not updating:
			edit(face, key, value))


func _build_reflection_field(content: VBoxContainer, field: Dictionary, face: bool, key: String) -> void:
	var choices := OptionButton.new()
	choices.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(choices)
	for mode in REFLECTIVE:
		choices.add_item(mode)
	for i in range(REFLECTION_HELP.size()):
		choices.set_item_tooltip(i, REFLECTION_HELP[i])
	field.input = choices
	choices.item_selected.connect(func(value: int):
		if not updating and value < REFLECTIVE.size():
			edit(face, key, value))


func _build_number_field(row: HBoxContainer, field: Dictionary, spec: Dictionary, face: bool, key: String) -> void:
	var value := SpinBox.new()
	value.min_value = spec.min
	value.max_value = spec.max
	row.add_child(value)
	field.input = value
	_connect_number(value, face, key)


func _build_text_field(content: VBoxContainer, field: Dictionary, face: bool, key: String) -> void:
	var input := LineEdit.new()
	input.placeholder_text = "Default / none"
	input.tooltip_text = "Vintage Story color map asset name. Stored for the game; tint preview is unavailable."
	content.add_child(input)
	field.input = input
	input.text_changed.connect(func(_value: String):
		if not updating:
			pending["%s:%s" % [face, key]] = {"face": face, "key": key, "input": input, "text": true})
	input.text_submitted.connect(func(_value: String): finish_pending())
	input.focus_exited.connect(finish_pending)


func _build_vertex_fields(content: VBoxContainer, row: HBoxContainer, field: Dictionary, face: bool, key: String) -> void:
	var enabled := CheckBox.new()
	_style_check(enabled)
	enabled.tooltip_text = "Override the default vertex settings"
	row.add_child(enabled)
	field.input = enabled
	field.values = []

	if field.type == "wind_modes":
		_build_wind_modes(content, field)
	else:
		var values := HBoxContainer.new()
		content.add_child(values)
		for index in range(4):
			_build_vertex_number(values, field, face, key, index)

	enabled.toggled.connect(func(value: bool):
		if not updating:
			edit(face, key, [0, 0, 0, 0], not value))


func _build_wind_modes(content: VBoxContainer, field: Dictionary) -> void:
	var all_row := HBoxContainer.new()
	content.add_child(all_row)
	var all_label := Label.new()
	all_label.text = "All"
	all_label.custom_minimum_size.x = 22
	all_row.add_child(all_label)
	field.all = _wind_dropdown()
	field.all.tooltip_text = "Apply one wind mode to all four face vertices"
	all_row.add_child(field.all)
	field.all.item_selected.connect(func(mode: int):
		if not updating and mode < WIND_MODES.size():
			edit(true, "windMode", [mode, mode, mode, mode]))

	for i in range(4):
		_build_wind_vertex(content, field, i)


func _build_wind_vertex(content: VBoxContainer, field: Dictionary, index: int) -> void:
	var vertex := HBoxContainer.new()
	content.add_child(vertex)
	var vertex_label := Label.new()
	vertex_label.text = "V%d" % (index + 1)
	vertex_label.custom_minimum_size.x = 22
	vertex.add_child(vertex_label)
	var choice := _wind_dropdown()
	vertex.add_child(choice)
	field.values.append(choice)
	choice.item_selected.connect(func(mode: int):
		if not updating and mode < WIND_MODES.size():
			_set_wind_vertex(index, mode))


func _build_vertex_number(values: HBoxContainer, field: Dictionary, face: bool, key: String, index: int) -> void:
	var value := SpinBox.new()
	value.min_value = 0
	value.max_value = 7
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.custom_minimum_size.x = 48
	value.prefix = "V%d" % (index + 1)
	value.tooltip_text = "Vertex %d · shader data (0–7), in Vintage Story face vertex order" % (index + 1)
	values.add_child(value)
	field.values.append(value)
	_connect_number(value, face, key, index)


func _build_glow_slider(content: VBoxContainer) -> void:
	var glow_row := HBoxContainer.new()
	content.add_child(glow_row)
	var glow_label := Label.new()
	glow_label.text = "Glow"
	glow_label.custom_minimum_size.x = 42
	glow_label.add_theme_font_size_override("font_size", 12)
	glow_row.add_child(glow_label)
	var glow: HSlider = face_panel.get_node("%Glow")
	glow.reparent(glow_row)
	glow.custom_minimum_size.x = 90
	var track := StyleBoxFlat.new()
	track.bg_color = Palette.border_light
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	track.set_corner_radius_all(2)
	glow.add_theme_stylebox_override("slider", track)
	var filled := track.duplicate() as StyleBoxFlat
	filled.bg_color = Palette.accent
	glow.add_theme_stylebox_override("grabber_area", filled)
	glow.add_theme_stylebox_override("grabber_area_highlight", filled)
	glow.drag_started.connect(edit_history.break_merge)
	glow_value = Label.new()
	glow_value.custom_minimum_size.x = 28
	glow_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	glow_row.add_child(glow_value)


func _build_reflection_help(content: VBoxContainer) -> void:
	reflection_help = Label.new()
	reflection_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reflection_help.add_theme_font_size_override("font_size", 11)
	content.add_child(reflection_help)


func _style_check(check: CheckBox) -> void:
	check.custom_minimum_size = Vector2(24, 26)
	check.add_theme_icon_override("checked", preload("res://assets/icons/key_checked.svg"))
	check.add_theme_icon_override("unchecked", preload("res://assets/icons/key_unchecked.svg"))
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var style := StyleBoxEmpty.new()
		style.set_content_margin_all(2)
		check.add_theme_stylebox_override(state, style)


func _wind_dropdown() -> OptionButton:
	var choice := OptionButton.new()
	choice.fit_to_longest_item = false
	choice.clip_text = true
	choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in range(WIND_MODES.size()):
		choice.add_item(WIND_MODES[i], i)
		choice.set_item_tooltip(i, "%d · %s" % [i, WIND_HELP[i]])
	return choice


func _show_wind(choice: OptionButton, value: int, mixed := false) -> void:
	while choice.item_count > WIND_MODES.size():
		choice.remove_item(choice.item_count - 1)
	if mixed or value < 0 or value >= WIND_MODES.size():
		choice.add_item("Mixed · all vertices" if mixed else "Imported mode %d" % value)
		choice.set_item_disabled(WIND_MODES.size(), true)
		choice.select(WIND_MODES.size())
	else:
		choice.select(value)


func _set_wind_vertex(axis: int, mode: int) -> void:
	var raw: Variant = _source(true).get("windMode")
	var values: Array = raw.duplicate() if raw is Array and raw.size() == 4 else [8, 8, 8, 8] if _source(true).get("frostable", false) else [0, 0, 0, 0]
	values[axis] = mode
	edit(true, "windMode", values)


func _connect_number(input: SpinBox, face: bool, key: String, axis := -1) -> void:
	input.value_changed.connect(func(value: float):
		if not updating:
			if axis < 0:
				edit(face, key, int(value))
			else:
				var source := _source(face)
				var raw: Variant = source.get(key)
				var values: Array = raw.duplicate() if raw is Array and raw.size() == 4 else [0, 0, 0, 0]
				values[axis] = int(value)
				edit(face, key, values))
	input.get_line_edit().text_changed.connect(func(_value: String):
		if not updating:
			pending["%s:%s:%s" % [face, key, axis]] = {"face": face, "key": key, "input": input, "text": false})


func _source(face: bool) -> Dictionary:
	var node: Node3D = face_panel.selected if face else viewport_view.selected_node
	if not is_instance_valid(node):
		return {}

	var source: Dictionary = node.get_meta("shape_element")
	return source.get("faces", {}).get(face_panel.current_face, {}) if face else source


func refresh() -> void:
	updating = true
	if glow_value != null:
		glow_value.text = str(int(_source(true).get("glow", 0)))
	_refresh_fields(false)
	_refresh_fields(true)
	if wind_help != null:
		_refresh_wind_help()
	if reflection_help != null:
		_refresh_reflection_help()
	updating = false


func _refresh_fields(face: bool) -> void:
	var valid: bool = is_instance_valid(face_panel.selected if face else viewport_view.selected_node)
	if face:
		valid = valid and not face_panel.current_face.is_empty()
	var source := _source(face)
	var schema: Dictionary = FACES if face else ELEMENTS
	var fields: Dictionary = face_fields if face else element_fields
	for key in fields:
		var field: Dictionary = fields[key]
		var value: Variant = source.get(key, schema[key].default)
		field.reset.disabled = not valid or not source.has(key)
		if key == "windMode":
			field.reset.disabled = not valid or not (source.has(key) or source.has("frostable"))
		_refresh_field(key, field, value, source, valid)


func _refresh_field(key: String, field: Dictionary, value: Variant, source: Dictionary, valid: bool) -> void:
	match field.type:
		"bool":
			field.input.disabled = not valid
			if key == "enabled" and source.is_empty():
				value = false
			field.input.set_pressed_no_signal(value == true)
		"text":
			field.input.editable = valid
			field.input.text = str(value) if value != null else ""
		"number":
			field.input.editable = valid
			field.input.set_value_no_signal(value)
		"enum":
			_refresh_reflection_choice(field, value, valid)
		"array":
			_refresh_vertex_data(field, value, source, key, valid)
		"wind_modes":
			_refresh_wind_modes(field, value, source, key, valid)


func _refresh_reflection_choice(field: Dictionary, value: Variant, valid: bool) -> void:
	field.input.disabled = not valid
	var selected: int = REFLECTIVE.find(value) if value is String else int(value)
	while field.input.item_count > REFLECTIVE.size():
		field.input.remove_item(field.input.item_count - 1)
	if selected < 0 or selected >= REFLECTIVE.size():
		field.input.add_item("Custom (%s)" % value)
		selected = REFLECTIVE.size()
	field.input.select(selected)


func _refresh_vertex_data(field: Dictionary, value: Variant, source: Dictionary, key: String, valid: bool) -> void:
	field.input.disabled = not valid
	field.input.set_pressed_no_signal(value is Array and source.has(key))
	for i in range(4):
		var raw: int = int(value[i]) if value is Array and i < value.size() else 0
		field.values[i].editable = valid and source.has(key) and value is Array and raw >= 0 and raw <= 7
		field.values[i].set_value_no_signal(raw & 7)
		field.values[i].tooltip_text = "Vertex %d · data 0–7" % (i + 1) if raw >= 0 and raw <= 7 else "Imported value %d (shader reads %d). Preserved; reset Wind data to edit within 0–7." % [raw, raw & 7]


func _refresh_wind_modes(field: Dictionary, value: Variant, source: Dictionary, key: String, valid: bool) -> void:
	var modes: Array = value if value is Array and value.size() == 4 else [0, 0, 0, 0]
	if source.get("frostable", false):
		modes = [8, 8, 8, 8]
	var enabled: bool = source.get(key) is Array or source.get("frostable", false) == true
	field.input.disabled = not valid
	field.input.set_pressed_no_signal(enabled)
	field.all.disabled = not valid or not enabled
	var mixed: bool = not modes.all(func(mode: Variant): return mode == modes[0])
	_show_wind(field.all, int(modes[0]), mixed)
	if not enabled:
		field.all.add_item("Default / inherited")
		field.all.select(field.all.item_count - 1)
	for i in range(4):
		field.values[i].disabled = not valid or not enabled
		_show_wind(field.values[i], int(modes[i]))


func _refresh_wind_help() -> void:
	var source := _source(true)
	var modes: Variant = source.get("windMode", [0, 0, 0, 0])
	if source.get("frostable", false):
		modes = [8, 8, 8, 8]
	var descriptions: PackedStringArray = []
	if not source.get("windMode") is Array and not source.get("frostable", false):
		descriptions.append("Wind mode uses the game default/inherited settings until overridden. Leave wind overrides off for ordinary rigid model parts.")
	if modes is Array:
		for raw in modes:
			var mode := int(raw)
			var description: String = WIND_HELP[mode] if mode >= 0 and mode < WIND_HELP.size() else "Imported wind mode %d is preserved; choose a named mode to replace it." % mode
			if not description in descriptions:
				descriptions.append(description)
	var data: Variant = source.get("windData")
	if data is Array and data.any(func(value: Variant): return value < 0 or value > 7):
		descriptions.append("Imported wind data: %s. Values are preserved; the fields show their effective three-bit values. Reset Wind data to replace them." % str(data))
	if source.has("frostable"):
		descriptions.append("Legacy 'frostable' is preserved. True maps to Fruit wind, not frost coverage; editing/resetting Wind mode removes this legacy flag.")
	wind_help.text = "\n".join(descriptions)


func _refresh_reflection_help() -> void:
	var source := _source(true)
	var raw: Variant = source.get("reflectiveMode", 0)
	var mode: int = REFLECTIVE.find(raw) if raw is String else int(raw)
	reflection_help.text = REFLECTION_HELP[mode] if mode >= 0 and mode < REFLECTION_HELP.size() else "Imported reflective mode is preserved."
	var wind: Variant = source.get("windMode")
	if mode > 0 and (source.get("frostable", false) or (wind is Array and wind.any(func(value: Variant): return value != 0))):
		reflection_help.text += "\nReflection and wind share shader data in Vintage Story and cannot be combined reliably on the same face."


func finish_pending() -> void:
	var edits: Array = []
	for item in pending.values():
		var entry: Dictionary = item.duplicate()
		entry.value = item.input.text if item.text else item.input.get_line_edit().text
		edits.append(entry)
	pending.clear()
	for item in edits:
		if item.text:
			var value: String = item.value.strip_edges()
			edit(item.face, item.key, value, value.is_empty())
		else:
			item.input.get_line_edit().text = item.value
			item.input.apply()


func edit(face: bool, key: String, value: Variant, remove := false) -> bool:
	if not (FACES if face else ELEMENTS).has(key):
		return false

	var spec: Dictionary = (FACES if face else ELEMENTS)[key]
	if not remove:
		match spec.type:
			"bool":
				if not value is bool:
					return false

			"text":
				if not value is String:
					return false

			"number":
				if not (value is int or value is float) or not is_finite(value) or value != floor(value) or value < spec.min or value > spec.max:
					return false

				value = int(value)
			"enum":
				if not value is int or value < 0 or value >= REFLECTIVE.size():
					return false

			"array", "wind_modes":
				if not value is Array or value.size() != 4:
					return false

				for i in range(value.size()):
					var entry: Variant = value[i]
					if not (entry is int or entry is float) or not is_finite(entry) or entry != floor(entry) or entry < -128 or entry > 127:
						return false

					if key == "windData" and (entry < 0 or entry > 7):
						var existing: Variant = _source(true).get(key)
						if not existing is Array or existing.size() != 4 or existing[i] != entry:
							return false

	var node: Node3D = face_panel.selected if face else viewport_view.selected_node
	if not is_instance_valid(node):
		return false

	var uid := Document.uid_of(node)
	if document == null or not document.has(uid):
		return false

	if face:
		var name: String = face_panel.current_face
		if name.is_empty():
			return false

		var source: Dictionary = node.get_meta("shape_element")
		var old: Dictionary = source.get("faces", {}).get(name, {})
		var fields := {key: Document.ABSENT if remove else value}
		if key == "windMode" and old.has("frostable"):
			fields.frostable = Document.ABSENT
		var unchanged: bool = old.has(key) != remove and (remove or old.get(key) == value) and not fields.has("frostable")
		if unchanged:
			return true

		return edit_history.execute(SetFaceFields.new(document, uid, name, fields, "Change Face " + key, "", {"texture": "#", "uv": [0, 0, 16, 16]}))

	var source: Dictionary = node.get_meta("shape_element")
	if source.has(key) != remove and (remove or source.get(key) == value):
		return true

	return edit_history.execute(SetFields.new(document, uid, {key: Document.ABSENT if remove else value}, "Change Element " + key))
