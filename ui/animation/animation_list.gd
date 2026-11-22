extends ItemList

signal rename_requested(index: int)
static var Palette = preload("res://ui/theme/editor_palette.tres")
const Metrics = preload("res://ui/shared/editor_metrics.gd")
var rename_button := Button.new()
var rename_index := -1


func _ready() -> void:
	clip_contents = true
	add_theme_color_override("guide_color", Color.TRANSPARENT)
	rename_button.name = "Rename"
	rename_button.icon = preload("res://assets/icons/rename.svg")
	rename_button.tooltip_text = "Rename animation"
	rename_button.flat = true
	rename_button.visible = false
	for state in ["normal", "hover", "pressed", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Palette.hover if state in ["hover", "pressed"] else Color.TRANSPARENT
		style.set_content_margin_all(2)
		rename_button.add_theme_stylebox_override(state, style)
	add_child(rename_button)
	rename_button.pressed.connect(func(): rename_requested.emit(rename_index))
	item_selected.connect(show_rename)
	resized.connect(_position_rename)
	get_v_scroll_bar().value_changed.connect(func(_value: float): _position_rename())
	get_v_scroll_bar().visibility_changed.connect(_position_rename)


func show_rename(index: int) -> void:
	rename_index = index
	for row in range(item_count):
		set_item_custom_bg_color(row, Palette.selection if is_selected(row) else (Palette.surface if row % 2 == 0 else Palette.chrome))
	rename_button.hide()
	call_deferred("_position_rename")


func _position_rename() -> void:
	if not is_node_ready():
		return

	var panel := get_theme_stylebox("panel")
	var scrollbar := get_v_scroll_bar()
	var right: float = size.x - panel.get_content_margin(SIDE_RIGHT) - (scrollbar.size.x if scrollbar.visible else 0.0)
	fixed_column_width = maxi(int(right - panel.get_content_margin(SIDE_LEFT) - Metrics.ROW_HEIGHT), 30)
	if rename_index < 0 or rename_index >= item_count or not is_selected(rename_index):
		rename_button.hide()
		return

	var rect := get_item_rect(rename_index)
	var y := rect.position.y - scrollbar.value
	var top := panel.get_content_margin(SIDE_TOP)
	var bottom := size.y - panel.get_content_margin(SIDE_BOTTOM)
	rename_button.position = Vector2(right - Metrics.ROW_HEIGHT, y)
	rename_button.size = Vector2(Metrics.ROW_HEIGHT, Metrics.ROW_HEIGHT)
	rename_button.visible = y >= top and y + Metrics.ROW_HEIGHT <= bottom


func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2 and rename_index >= 0:
		rename_requested.emit(rename_index)
		accept_event()
