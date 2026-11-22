extends "res://ui/shared/property_panel.gd"
signal expanded_changed(expanded: bool)
@export var title := "Section"
@export var expanded := false
@onready var toggle: Button = $Layout/Toggle
@onready var content: VBoxContainer = $Layout/Body/Content
## Holds the content: indented, on a slightly darker ground with a line at its
## left, so an open section stands out from the fields around it.
@onready var body: PanelContainer = $Layout/Body


func _ready() -> void:
	super()
	toggle.text = title.to_upper()
	toggle.add_theme_font_size_override("font_size", 11)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		toggle.add_theme_color_override(state, Palette.muted if state == "font_color" else Palette.text)
	toggle.add_theme_constant_override("icon_max_width", 14)
	toggle.tooltip_text = "Show or hide " + title.to_lower() + " settings"
	toggle.set_pressed_no_signal(expanded)
	_set_expanded(expanded)
	toggle.toggled.connect(_set_expanded)


func refresh_style() -> void:
	super()
	if body == null:
		return
	var style := StyleBoxFlat.new()
	style.bg_color = Color(Palette.workspace, 0.55)
	style.border_color = Palette.border_light
	style.border_width_left = 2
	style.content_margin_left = 12
	style.content_margin_right = 6
	style.content_margin_top = 6
	style.content_margin_bottom = 8
	body.add_theme_stylebox_override("panel", style)


func _set_expanded(value: bool) -> void:
	expanded = value
	content.visible = value
	body.visible = value
	toggle.icon = preload("res://assets/icons/expanded.svg") if value else preload("res://assets/icons/collapsed.svg")
	expanded_changed.emit(value)
