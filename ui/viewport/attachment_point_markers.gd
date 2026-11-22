extends Control
var editor


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	process_priority = 65


func _process(_delta: float) -> void:
	queue_redraw()


## Each attachment point: a dot, its code, and a thin line to the centre of
## the element that owns it. Points on other elements are dimmer.
func _draw() -> void:
	for entry in editor.marker_entries():
		var color: Color = Color("ffd45c") if entry.active and entry.index == editor.index else Color("9ecbff")
		if not entry.active:
			color = Color(color, 0.55)
		draw_dashed_line(entry.owner, entry.position, Color(color, color.a * 0.6), 1.0, 4.0)
		draw_circle(entry.position, 5 if entry.active else 4, color)
		draw_circle(entry.position, 7 if entry.active else 6, Color("17202b"), false, 2)
		draw_string(ThemeDB.fallback_font, entry.position + Vector2(10, -8), entry.code, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, color)
