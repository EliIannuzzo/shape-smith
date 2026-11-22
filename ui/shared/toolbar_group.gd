extends PanelContainer
static var Palette = preload("res://ui/theme/editor_palette.tres")
@export var buttons_path := NodePath("Buttons")


func _ready() -> void:
	refresh_style()
	Palette.changed.connect(refresh_style)


func refresh_style() -> void:
	var background := StyleBoxFlat.new()
	background.bg_color = Palette.surface
	background.border_color = Palette.border_light
	background.set_border_width_all(1)
	background.set_corner_radius_all(4)
	background.set_content_margin_all(2)
	add_theme_stylebox_override("panel", background)
	for child in get_node(buttons_path).get_children():
		if child is Button:
			style_button(child)


func style_button(button: Button) -> void:
	button.add_theme_color_override("icon_pressed_color", Palette.accent)
	button.add_theme_color_override("icon_hover_pressed_color", Palette.accent)
	var idle := StyleBoxEmpty.new()
	idle.content_margin_left = 8
	idle.content_margin_right = 8
	idle.content_margin_top = 4
	idle.content_margin_bottom = 4
	button.add_theme_stylebox_override("normal", idle)
	for state in ["hover", "pressed", "disabled"]:
		var style := button.get_theme_stylebox(state).duplicate() as StyleBox
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			style.set_content_margin(side, idle.get_content_margin(side))
		button.add_theme_stylebox_override(state, style)
