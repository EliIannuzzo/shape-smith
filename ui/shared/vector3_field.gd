extends VBoxContainer
const Limits = preload("res://core/model/shape_limits.gd")
signal axis_edited(axis: int, value: float)
signal pending_edited(axis: int, input: SpinBox)
@export var label_text := "Vector"
@export var minimum := -Limits.MAX_COORDINATE
@export var maximum := Limits.MAX_COORDINATE
@export var increment := 0.01
## Below this width the label sits above the fields instead of beside them.
const INLINE_WIDTH := 290.0
const LABEL_WIDTH := 64.0
var inline := false
@onready var inputs: Array[SpinBox] = [$Values/X, $Values/Y, $Values/Z]
static var Palette = preload("res://ui/theme/editor_palette.tres")


func _ready() -> void:
	$Label.text = label_text
	$Label.tooltip_text = label_text
	$Label.mouse_filter = Control.MOUSE_FILTER_PASS
	resized.connect(_fit)
	for axis in range(inputs.size()):
		var input := inputs[axis]
		input.get_line_edit().add_theme_font_size_override("font_size", 12)
		input.min_value = minimum
		input.max_value = maximum
		input.step = increment
		input.tooltip_text = label_text + " · " + input.prefix
		input.value_changed.connect(func(value: float): axis_edited.emit(axis, value))
		input.get_line_edit().text_changed.connect(func(_text: String): pending_edited.emit(axis, input))
		input.get_line_edit().gui_input.connect(_relative_entry.bind(input))
		_color_axis(input, axis)


## Typing "*2", "/2", "+4" or "-=4" applies that to the current value when
## Enter is pressed ("-4" alone is still a negative number). Plain expressions
## such as "8+4" are handled by the SpinBox itself.
static func relative_value(text: String, current: float) -> Variant:
	var trimmed := text.strip_edges()
	for operator in ["*", "/", "+", "-="]:
		if trimmed.begins_with(operator) and trimmed.length() > operator.length():
			var operand := trimmed.substr(operator.length()).strip_edges()
			if not operand.is_valid_float():
				return null
			var amount := operand.to_float()
			match operator:
				"*": return current * amount
				"/": return current / amount if amount != 0.0 else null
				"+": return current + amount
				"-=": return current - amount
	return null


func _relative_entry(event: InputEvent, input: SpinBox) -> void:
	if event is InputEventKey and event.pressed and event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		var line := input.get_line_edit()
		var result: Variant = relative_value(line.text.trim_prefix(input.prefix).strip_edges(), input.value)
		if result != null:
			line.text = str(result)


## A thin left border in the gizmo's axis color (X red, Y green, Z blue).
func _color_axis(input: SpinBox, axis: int) -> void:
	edge(input, [Palette.axis_x, Palette.axis_y, Palette.axis_z][axis])


## A thin left edge in `color` instead of a full border (shared with other
## numeric rows, such as UV bounds).
static func edge(input: SpinBox, color: Color) -> void:
	var line := input.get_line_edit()
	var base: StyleBox = line.get_theme_stylebox("normal")
	if base is StyleBoxFlat:
		var style := base.duplicate() as StyleBoxFlat
		style.border_width_top = 0
		style.border_width_right = 0
		style.border_width_bottom = 0
		style.border_width_left = 2
		style.border_color = color
		line.add_theme_stylebox_override("normal", style)


## Puts the label beside the fields (its short name; the unit is in its
## tooltip) when the row is wide enough, above them otherwise.
func _fit() -> void:
	var wide := size.x >= INLINE_WIDTH
	if wide == inline:
		return
	inline = wide
	var label: Label = get_node_or_null("Label")
	if label == null:
		label = $Values/Label
	if wide:
		label.reparent($Values, false)
		$Values.move_child(label, 0)
		label.custom_minimum_size.x = LABEL_WIDTH
		label.text = label_text.get_slice(" · ", 0)
	else:
		label.reparent(self, false)
		move_child(label, 0)
		label.custom_minimum_size.x = 0
		label.text = label_text


func set_vector(value: Vector3) -> void:
	for axis in range(3):
		inputs[axis].set_value_no_signal(value[axis])


func get_vector() -> Vector3:
	return Vector3(inputs[0].value, inputs[1].value, inputs[2].value)
