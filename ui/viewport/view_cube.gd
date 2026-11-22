extends Control
## A small axis gizmo in the viewport corner. Each dot is an axis direction as
## the camera sees it; click one to look along that axis (X red, Y green,
## Z blue; filled dots are the positive ends).

static var Palette = preload("res://ui/theme/editor_palette.tres")
const RADIUS := 26.0
const DOT := 7.0
const DIRECTIONS := [Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector3.LEFT, Vector3.DOWN, Vector3.FORWARD]
const LABELS := ["X", "Y", "Z", "", "", ""]

var viewport


func _init() -> void:
	custom_minimum_size = Vector2(RADIUS * 2 + DOT * 2 + 4, RADIUS * 2 + DOT * 2 + 4)
	tooltip_text = "Click an axis to view along it"


func bind(view) -> void:
	viewport = view
	viewport.camera_changed.connect(queue_redraw)


func _axis_color(index: int) -> Color:
	return [Palette.axis_x, Palette.axis_y, Palette.axis_z][index % 3]


## Screen positions of the six axis dots, back to front.
func dots() -> Array:
	var result: Array = []
	if viewport == null or not is_instance_valid(viewport.camera):
		return result
	var basis: Basis = viewport.camera.global_basis
	var center := size * 0.5
	for i in range(6):
		var direction: Vector3 = DIRECTIONS[i]
		var screen := Vector2(direction.dot(basis.x), -direction.dot(basis.y)) * RADIUS
		result.append({"index": i, "position": center + screen, "depth": direction.dot(basis.z)})
	result.sort_custom(func(a, b): return a.depth < b.depth)
	return result


func _draw() -> void:
	draw_circle(size * 0.5, RADIUS + DOT, Color(Palette.chrome, 0.55))
	for dot in dots():
		var color := _axis_color(dot.index)
		if dot.index < 3:
			draw_line(size * 0.5, dot.position, color, 2.0)
			draw_circle(dot.position, DOT, color)
			draw_string(get_theme_default_font(), dot.position + Vector2(-3.5, 4), LABELS[dot.index], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Palette.workspace)
		else:
			draw_circle(dot.position, DOT - 1.5, Color(color, 0.35))
			draw_arc(dot.position, DOT - 1.5, 0, TAU, 16, color, 1.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var dots_front := dots()
		dots_front.reverse()
		for dot in dots_front:
			if dot.position.distance_to(event.position) <= DOT + 2:
				viewport.view_from(DIRECTIONS[dot.index])
				accept_event()
				return
