extends PanelContainer
static var Palette = preload("res://ui/theme/editor_palette.tres")


func _ready() -> void:
	refresh_style()
	Palette.changed.connect(refresh_style)


func refresh_style() -> void:
	# A section: a hairline above, no box, so panels read as one sheet.
	var style := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	style.border_color = Palette.border_light
	style.border_width_top = 1
	style.content_margin_top = 6
	style.content_margin_bottom = 4
	add_theme_stylebox_override("panel", style)
