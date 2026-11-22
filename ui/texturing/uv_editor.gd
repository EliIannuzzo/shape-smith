extends Control

const CORNER_HIT_RADIUS := 8.0
const CORNER_HALF_SIZE := 3.0
const CHECKER_SIZE := 16.0
const MIN_ZOOM := 0.05
const MAX_ZOOM := 128.0
const ZOOM_FACTOR := 1.15
const FIT_FRACTION := 0.75

static var Palette = preload("res://ui/theme/editor_palette.tres")
## UV coordinates stay in VS logical units; the canvas uses image pixels.

signal uv_changed(uv: Array)
## Another face's rectangle was clicked: select that element and face.
signal face_clicked(node: Node3D, face: String)
signal edit_started
signal edit_finished
## Ctrl- or Shift-click on another face: add it to the selection or remove it.
signal face_toggled(node: Node3D, face: String)
## A box was dragged on empty canvas (in UV units); additive with Ctrl or Shift.
signal box_selected(box: Rect2, additive: bool)
var texture: Texture2D
var dimensions := Vector2(16, 16)
var uv: Array = [0.0, 0.0, 16.0, 16.0]
var zoom := 1.0
var pan := Vector2.ZERO
var drag_button := 0
var snap_enabled := true
var snap_step := Vector2(0.5, 0.5)
var drag_uv: Array = []
var resize_corner := -1
var show_other_uvs := true
var other_uvs: Array = []
## Parallel to other_uvs: {node, face, warning, selected} for each other face.
## warning is "" or "outside" (beyond the texture); selected faces move with
## the current one.
var other_faces: Array = []
## The current face's warning, as above, and its rotation in degrees.
var warning := ""
var face_rotation := 0.0
const Renderer = preload("res://core/textures/uv_layout_renderer.gd")
## Pixel grid lines appear once a texture pixel is at least this many screen pixels.
const GRID_MIN_PIXELS := 6.0
## A box selection being dragged, in canvas pixels.
var boxing := false
var box_start := Vector2.ZERO
var box_end := Vector2.ZERO
var box_additive := false
var _last_size := Vector2.ZERO
## Whether the view has been fitted at a usable canvas size yet, and whether
## the user has zoomed or panned since (then resizing keeps their view).
var _fitted := false
var _user_view := false


func corner_points() -> Array[Vector2]:
	if texture == null:
		return []

	var scale_value := texture.get_size() * zoom / dimensions
	return [pan + Vector2(uv[0], uv[1]) * scale_value, pan + Vector2(uv[2], uv[1]) * scale_value,
		pan + Vector2(uv[2], uv[3]) * scale_value, pan + Vector2(uv[0], uv[3]) * scale_value]


func corner_at(point: Vector2) -> int:
	var points := corner_points()
	for i in range(points.size()):
		if points[i].distance_to(point) <= CORNER_HIT_RADIUS:
			return i

	return -1


func _ready() -> void:
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	gui_input.connect(_on_gui_input)
	resized.connect(_on_resized)


## Refits when the canvas is resized, until the user zooms or pans; after
## that the zoom is kept and the view's centre stays put.
func _on_resized() -> void:
	if not _fitted or not _user_view or texture == null:
		fit()
	else:
		pan += (size - _last_size) * 0.5
		queue_redraw()
	_last_size = size


func set_face(image: Texture2D, logical_size: Vector2, coordinates: Array) -> void:
	var changed_image := image != texture
	texture = image
	dimensions = logical_size
	uv = coordinates.duplicate()
	if changed_image:
		fit()
	queue_redraw()


func fit() -> void:
	if texture == null:
		return

	_last_size = size
	_fitted = size.x >= 32 and size.y >= 32
	_user_view = false
	zoom = clampf(minf(size.x / texture.get_width(), size.y / texture.get_height()) * FIT_FRACTION, MIN_ZOOM, MAX_ZOOM)
	pan = (size - texture.get_size() * zoom) * 0.5
	queue_redraw()


func uv_rect() -> Rect2:
	if texture == null:
		return Rect2()

	var scale_value := texture.get_size() * zoom / dimensions
	return Rect2(pan + Vector2(uv[0], uv[1]) * scale_value, Vector2(uv[2] - uv[0], uv[3] - uv[1]) * scale_value).abs()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Palette.checker_dark)
	for y in range(ceili(size.y / CHECKER_SIZE)):
		for x in range(ceili(size.x / CHECKER_SIZE)):
			if (x + y) % 2 == 0:
				draw_rect(Rect2(Vector2(x, y) * CHECKER_SIZE, Vector2.ONE * CHECKER_SIZE), Palette.checker_light)
	if texture == null:
		draw_string(get_theme_default_font(), Vector2(16, 32), "Select a textured face", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Palette.muted)
		return

	draw_texture_rect(texture, Rect2(pan, texture.get_size() * zoom), false)
	if zoom >= GRID_MIN_PIXELS:
		var grid := Color(Palette.workspace, 0.35)
		for x in range(texture.get_width() + 1):
			draw_line(pan + Vector2(x, 0) * zoom, pan + Vector2(x, texture.get_height()) * zoom, grid)
		for y in range(texture.get_height() + 1):
			draw_line(pan + Vector2(0, y) * zoom, pan + Vector2(texture.get_width(), y) * zoom, grid)
	if show_other_uvs:
		for i in range(other_uvs.size()):
			var rect := _rect_of(other_uvs[i])
			var info: Dictionary = other_faces[i] if i < other_faces.size() else {}
			if info.get("selected", false):
				draw_rect(rect, Color(Palette.accent, 0.22))
				draw_rect(rect, Color(Palette.accent, 0.9), false, 1.5)
				continue
			var color: Color = Renderer.COLORS.get(info.get("face", ""), Color(0.8, 0.82, 0.85))
			draw_rect(rect, Color(color, 0.18))
			draw_rect(rect, Color(color, 0.8), false, 1.0)
			_draw_warning(rect, info.get("warning", ""))
	var outline := uv_rect()
	draw_rect(outline, Color(Palette.accent, 0.13))
	draw_rect(outline, Palette.accent, false, 2.0)
	_draw_warning(outline.grow(2), warning)
	_draw_up_arrow(outline)
	for point in [outline.position, Vector2(outline.end.x, outline.position.y), outline.end, Vector2(outline.position.x, outline.end.y)]:
		draw_rect(Rect2(point - Vector2.ONE * CORNER_HALF_SIZE, Vector2.ONE * CORNER_HALF_SIZE * 2), Palette.text)
	if boxing:
		var box := Rect2(box_start, box_end - box_start).abs()
		draw_rect(box, Color(Palette.accent, 0.12))
		draw_rect(box, Color(Palette.accent, 0.8), false, 1.0)


## A canvas point in UV units.
func to_uv(point: Vector2) -> Vector2:
	return (point - pan) / (texture.get_size() * zoom) * dimensions


func _rect_of(coordinates: Array) -> Rect2:
	var scale_value := texture.get_size() * zoom / dimensions
	var start := pan + Vector2(coordinates[0], coordinates[1]) * scale_value
	var end := pan + Vector2(coordinates[2], coordinates[3]) * scale_value
	return Rect2(start, end - start).abs()


func _draw_warning(rect: Rect2, kind: String) -> void:
	if kind == "outside":
		draw_rect(rect, Color("f0a640"), false, 2.0)


## A small arrow inside the current face pointing to its edge that faces up on
## the model (the face's rotation turns it).
func _draw_up_arrow(rect: Rect2) -> void:
	if rect.size.x < 18 or rect.size.y < 18:
		return
	var direction := Vector2.UP.rotated(deg_to_rad(face_rotation)).round()
	var tip := rect.get_center() + direction * 7.0
	var side := Vector2(-direction.y, direction.x) * 5.0
	var base := tip - direction * 7.0
	draw_colored_polygon(PackedVector2Array([tip, base + side, base - side]), Color(Palette.text, 0.9))


## The index into other_uvs of the face under a point, or -1.
func other_face_at(point: Vector2) -> int:
	if not show_other_uvs or texture == null:
		return -1
	for i in range(other_uvs.size() - 1, -1, -1):
		if _rect_of(other_uvs[i]).has_point(point):
			return i
	return -1


func _on_gui_input(event: InputEvent) -> void:
	if texture == null:
		return

	if event is InputEventMouseButton:
		var additive: bool = event.shift_pressed or event.ctrl_pressed
		var other := other_face_at(event.position) if event.button_index == MOUSE_BUTTON_LEFT else -1
		var on_current: bool = uv_rect().grow(6).has_point(event.position)
		if not event.pressed:
			_release(event.button_index)
		elif event.button_index == MOUSE_BUTTON_LEFT and additive and other >= 0 and not on_current:
			face_toggled.emit(other_faces[other].node, other_faces[other].face)
		elif event.button_index == MOUSE_BUTTON_LEFT and not on_current and other >= 0 and not other_faces[other].get("selected", false):
			var info: Dictionary = other_faces[other]
			face_clicked.emit(info.node, info.face)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			drag_button = MOUSE_BUTTON_RIGHT
		elif event.button_index == MOUSE_BUTTON_LEFT and (on_current or other >= 0):
			# The current face, or another selected one: they move together.
			drag_button = MOUSE_BUTTON_LEFT
			drag_uv = uv.duplicate()
			resize_corner = corner_at(event.position)
			edit_started.emit()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			drag_button = MOUSE_BUTTON_LEFT
			boxing = true
			box_additive = additive
			box_start = event.position
			box_end = event.position
		elif event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_user_view = true
			var previous := zoom
			zoom = clampf(zoom * (ZOOM_FACTOR if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_FACTOR), MIN_ZOOM, MAX_ZOOM)
			pan = event.position - (event.position - pan) * zoom / previous
		accept_event()
	if event is InputEventMouseMotion:
		if drag_button == 0:
			var corner := corner_at(event.position)
			mouse_default_cursor_shape = corner_cursor(corner)
		if drag_button == MOUSE_BUTTON_RIGHT:
			_user_view = true
			pan += event.relative
		elif boxing:
			box_end = event.position
		elif drag_button == MOUSE_BUTTON_LEFT:
			var delta: Vector2 = event.relative / (texture.get_size() * zoom) * dimensions
			if resize_corner >= 0:
				var u := 0 if resize_corner in [0, 3] else 2
				var v := 1 if resize_corner in [0, 1] else 3
				drag_uv[u] += delta.x
				drag_uv[v] += delta.y
				uv = drag_uv.duplicate()
				if snap_enabled:
					uv[u] = snappedf(uv[u], snap_step.x)
					uv[v] = snappedf(uv[v], snap_step.y)
			else:
				drag_uv = [drag_uv[0] + delta.x, drag_uv[1] + delta.y, drag_uv[2] + delta.x, drag_uv[3] + delta.y]
				var start := Vector2(drag_uv[0], drag_uv[1])
				var offset := start.snapped(snap_step) - start if snap_enabled else Vector2.ZERO
				uv = [drag_uv[0] + offset.x, drag_uv[1] + offset.y, drag_uv[2] + offset.x, drag_uv[3] + offset.y]
			uv_changed.emit(uv.duplicate())
		if drag_button != 0:
			accept_event()
	queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and not event.pressed and event.button_index == drag_button:
		_release(event.button_index)


## A mouse button came up: ends a box selection (reporting it) or a drag.
func _release(button: int) -> void:
	if boxing and button == MOUSE_BUTTON_LEFT and texture != null:
		var start := to_uv(box_start)
		var end := to_uv(box_end)
		var box := Rect2(start, end - start).abs() if box_start.distance_to(box_end) > 3.0 else Rect2()
		var additive := box_additive
		boxing = false
		box_selected.emit(box, additive)
	finish_drag()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		finish_drag()


func finish_drag() -> void:
	var previous := drag_button
	var was_boxing := boxing
	drag_button = 0
	resize_corner = -1
	boxing = false
	if was_boxing:
		queue_redraw()
		return
	if previous == MOUSE_BUTTON_LEFT:
		edit_finished.emit()


func corner_cursor(corner: int) -> CursorShape:
	if corner < 0:
		return Control.CURSOR_ARROW

	var offset := corner_points()[corner] - uv_rect().get_center()
	return Control.CURSOR_FDIAGSIZE if offset.x * offset.y >= 0 else Control.CURSOR_BDIAGSIZE
