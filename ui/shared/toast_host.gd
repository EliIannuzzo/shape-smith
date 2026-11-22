extends MarginContainer
## Non-blocking notices in the bottom-right corner of the 3D view: status,
## recoverable errors, and offers with action buttons (such as Recover). Click
## a notice to dismiss it. Modal dialogs are kept for destructive confirmations.

static var Palette = preload("res://ui/theme/editor_palette.tres")
const MAX_VISIBLE := 4
const WIDTH := 340
const INFO_SECONDS := 4.0
const ERROR_SECONDS := 9.0

var stack: VBoxContainer


func _init() -> void:
	name = "Toasts"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		add_theme_constant_override("margin_" + side, 12)
	stack = VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.alignment = BoxContainer.ALIGNMENT_END
	stack.size_flags_horizontal = Control.SIZE_SHRINK_END
	stack.size_flags_vertical = Control.SIZE_FILL
	add_child(stack)


## Shows a notice. kind is "info" or "error". actions is an array of
## [label, Callable] pairs shown as buttons; pressing one dismisses the notice.
## seconds <= 0 keeps the notice until it is dismissed.
func show_toast(text: String, kind := "info", seconds := -1.0, actions: Array = []) -> PanelContainer:
	if seconds < 0:
		seconds = ERROR_SECONDS if kind == "error" else INFO_SECONDS
	while stack.get_child_count() >= MAX_VISIBLE:
		var oldest := stack.get_child(0)
		stack.remove_child(oldest)
		oldest.queue_free()
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = WIDTH
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.set_meta("kind", kind)
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.surface
	style.border_color = Palette.axis_x if kind == "error" else Palette.accent
	style.border_width_left = 3
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	panel.add_child(layout)
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = WIDTH - 24
	layout.add_child(label)
	if not actions.is_empty():
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		layout.add_child(row)
		for entry in actions:
			var button := Button.new()
			button.text = entry[0]
			var callback: Callable = entry[1]
			button.pressed.connect(func():
				dismiss(panel)
				callback.call())
			row.add_child(button)
	panel.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and actions.is_empty():
			dismiss(panel))
	stack.add_child(panel)
	if seconds > 0:
		get_tree().create_timer(seconds).timeout.connect(dismiss.bind(panel))
	return panel


func dismiss(panel: Control) -> void:
	if is_instance_valid(panel) and panel.get_parent() == stack:
		stack.remove_child(panel)
		panel.queue_free()


func messages() -> PackedStringArray:
	var result: PackedStringArray = []
	for panel in stack.get_children():
		result.append(panel.get_child(0).get_child(0).text)
	return result


func clear() -> void:
	for panel in stack.get_children():
		dismiss(panel)
