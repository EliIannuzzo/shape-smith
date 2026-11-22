extends Control

const SCREEN_RADIUS := 80.0
const AXIS_START_RATIO := 0.24
const AXIS_END_RATIO := 1.45
const RING_SEGMENTS := 48
const RING_FACING_TOLERANCE := 0.001
const HANDLE_HIT_RADIUS := 8.0
const UNIFORM_SCALE_HANDLE := 6
const UNIFORM_SCALE_PIXELS := 100.0
const MIN_SCALE_FACTOR := 0.01
const MIN_AXIS_LENGTH := 0.000001
const MIN_GIZMO_RADIUS := 0.0001
const MIN_DRAG_PLANE_NORMAL_SQUARED := 0.1
const HANDLE_OUTLINE := Color(0.04, 0.05, 0.06)

const Units = preload("res://core/model/shape_units.gd")
signal drag_started
signal drag_finished(cancelled: bool)
signal scale_preview(factors: Vector3)
signal size_preview(axis_index: int, side: int, amount: float, symmetric: bool)
signal pivot_preview(world_position: Vector3)
enum Mode { TRANSFORM, SIZE, SCALE, PIVOT }
var mode := Mode.TRANSFORM
var size_dimensions := Vector3.ONE
var size_axis_length := 1.0
var scale_step := 0.1
static var Palette = preload("res://ui/theme/editor_palette.tres")
var view
var enabled := false
var local_space := true
var snap_enabled := false
var translation_step := 1.0
var rotation_step := 15.0
var dragging := false
## Arrows only (IK targets and poles: the solver uses where they are, not how
## they turn, so rotating or scaling one would do nothing).
var translate_only := false
var hovered := -1
var paths: Array = []
var origin := Vector3.ZERO
var orientation := Basis.IDENTITY
var radius := 1.0
var active := -1
var start_transform := Transform3D.IDENTITY
var start_mouse := Vector2.ZERO
var start_origin := Vector3.ZERO
var axis := Vector3.ZERO
var plane_normal := Vector3.ZERO
var start_hit := Vector3.ZERO
var last_angle := 0.0
var total_angle := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	visible = enabled and is_instance_valid(view.selected_node) and view.selected_node.is_visible_in_tree()
	if not visible:
		if dragging:
			finish(true)
		return

	if not dragging:
		size_dimensions = view.Geometry.size_of(view.selected_node.get_meta("shape_element"))
		origin = view.gizmo_pivot()
		var camera: Camera3D = view.camera
		var depth := -camera.to_local(origin).z
		visible = depth > camera.near
		radius = (camera.size if camera.projection == Camera3D.PROJECTION_ORTHOGONAL else 2.0 * depth * tan(deg_to_rad(camera.fov * 0.5))) * SCREEN_RADIUS / maxf(size.y, 1)
	orientation = view.selected_node.global_basis.orthonormalized() if local_space else Basis.IDENTITY
	_build_paths()
	queue_redraw()


func project(point: Vector3) -> Vector2:
	return view.camera.unproject_position(point)


func _build_paths() -> void:
	paths.clear()
	if mode == Mode.SIZE:
		for i in range(6):
			var face_axis := i / 2
			var center := size_dimensions * 0.5
			center[face_axis] = 0.0 if i % 2 == 0 else size_dimensions[face_axis]
			var point := project(view.selected_node.global_transform * center)
			paths.append(PackedVector2Array([point - Vector2(4, 0), point + Vector2(4, 0)]))
		return

	for i in range(3):
		paths.append(PackedVector2Array([project(origin + orientation[i] * radius * AXIS_START_RATIO), project(origin + orientation[i] * radius * AXIS_END_RATIO)]))
	for i in range(3):
		var points := PackedVector2Array()
		var facing: Vector3 = view.camera.global_basis.z if view.camera.projection == Camera3D.PROJECTION_ORTHOGONAL else (view.camera.global_position - origin).normalized()
		var u: Vector3 = orientation[(i + 1) % 3]
		var v: Vector3 = orientation[(i + 2) % 3]
		var planar := Vector2(facing.dot(u), facing.dot(v))
		var full_circle := planar.length() < RING_FACING_TOLERANCE
		var center := atan2(planar.y, planar.x)
		var sweep := TAU if full_circle else PI
		for step in range(RING_SEGMENTS + 1):
			var angle := center - sweep * 0.5 + sweep * step / float(RING_SEGMENTS)
			points.append(project(origin + radius * (orientation[(i + 1) % 3] * cos(angle) + orientation[(i + 2) % 3] * sin(angle))))
		paths.append(points)
	if mode == Mode.SCALE:
		var center := project(origin)
		paths.append(PackedVector2Array([center - Vector2(4, 0), center + Vector2(4, 0)]))


func _draw() -> void:
	if not visible:
		return

	var colors := [Palette.axis_x, Palette.axis_y, Palette.axis_z]
	for i in range(paths.size()):
		if not _handle_visible(i):
			continue

		var color: Color = Palette.key_selection if i == (active if dragging else hovered) else colors[i % 3]
		var points: PackedVector2Array = paths[i]
		if mode == Mode.SIZE:
			var center := (points[0] + points[1]) * 0.5
			var face_color: Color = Palette.key_selection if i == (active if dragging else hovered) else colors[i / 2]
			draw_rect(Rect2(center - Vector2(5, 5), Vector2(10, 10)), HANDLE_OUTLINE, true)
			draw_rect(Rect2(center - Vector2(4, 4), Vector2(8, 8)), face_color, true)
			continue

		if i == UNIFORM_SCALE_HANDLE:
			draw_rect(Rect2(project(origin) - Vector2(5, 5), Vector2(10, 10)), Palette.key_selection if i == (active if dragging else hovered) else Palette.text)
			continue

		draw_polyline(points, Color(HANDLE_OUTLINE, 0.85), 5.0, true)
		draw_polyline(points, color, 2.5, true)
		if i < 3:
			var end := points[1]
			if mode == Mode.SCALE:
				draw_rect(Rect2(end - Vector2(5, 5), Vector2(10, 10)), color)
				continue

			var direction := (end - points[0]).normalized()
			var side := direction.orthogonal() * 5.0
			draw_colored_polygon(PackedVector2Array([end + direction * 3, end - direction * 11 + side, end - direction * 11 - side]), color)


func hit_test(point: Vector2) -> int:
	if not Rect2(Vector2.ZERO, size).has_point(point):
		return -1

	var best := HANDLE_HIT_RADIUS
	var result := -1
	for i in range(paths.size()):
		if not _handle_visible(i):
			continue

		for j in range(paths[i].size() - 1):
			var closest := Geometry2D.get_closest_point_to_segment(point, paths[i][j], paths[i][j + 1])
			var distance := point.distance_to(closest)
			if distance < best:
				best = distance
				result = i
	return result


func _handle_visible(index: int) -> bool:
	if translate_only:
		return mode == Mode.TRANSFORM and index < 3
	if mode == Mode.PIVOT:
		return index < 3

	return index < 6 if mode in [Mode.TRANSFORM, Mode.SIZE] else index < 3 or index == UNIFORM_SCALE_HANDLE


func set_mode(value: int) -> void:
	finish(true)
	mode = value
	hovered = -1
	if is_instance_valid(view.selected_node):
		_build_paths()
	queue_redraw()


func begin(point: Vector2) -> bool:
	if not visible or not enabled:
		return false

	active = hit_test(point)
	if active < 0:
		return false

	drag_started.emit()
	origin = view.gizmo_pivot()
	orientation = view.selected_node.global_basis.orthonormalized() if local_space else Basis.IDENTITY
	start_transform = view.selected_node.global_transform
	start_mouse = point
	start_origin = origin
	axis = orientation[active % 3].normalized()
	if mode == Mode.SIZE:
		var index := active / 2
		axis = view.selected_node.global_basis[index].normalized()
		size_axis_length = view.selected_node.global_basis[index].length()
		var center := size_dimensions * 0.5
		center[index] = 0.0 if active % 2 == 0 else size_dimensions[index]
		start_origin = view.selected_node.global_transform * center
	# The axis-containing plane facing the camera avoids unstable ray/axis intersections.
	plane_normal = axis if mode == Mode.TRANSFORM and active >= 3 else (view.camera.global_basis.z - axis * view.camera.global_basis.z.dot(axis)).normalized()
	if plane_normal.length_squared() < MIN_DRAG_PLANE_NORMAL_SQUARED:
		plane_normal = view.camera.global_basis.y
	start_hit = _hit_plane(point)
	last_angle = 0.0
	total_angle = 0.0
	dragging = true
	return true


func _hit_plane(point: Vector2) -> Vector3:
	var hit: Variant = Plane(plane_normal, start_origin).intersects_ray(view.camera.project_ray_origin(point), view.camera.project_ray_normal(point))
	return hit if hit != null else start_origin


func motion(point: Vector2, snap := false, symmetric := false) -> void:
	if not dragging:
		hovered = hit_test(point) if visible else -1
		view.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hovered >= 0 else Control.CURSOR_ARROW
		return

	var transform := start_transform
	var hit := _hit_plane(point)
	if mode == Mode.SIZE:
		var amount := (hit - start_hit).dot(axis) / maxf(size_axis_length, MIN_AXIS_LENGTH) * Units.PER_BLOCK
		if snap != snap_enabled:
			amount = snappedf(amount, translation_step)
		size_preview.emit(active / 2, -1 if active % 2 == 0 else 1, amount, symmetric)
		transform = view.selected_node.global_transform
	elif mode == Mode.SCALE:
		var amount := ((point.x - start_mouse.x) - (point.y - start_mouse.y)) / UNIFORM_SCALE_PIXELS if active == UNIFORM_SCALE_HANDLE else (hit - start_hit).dot(axis) / maxf(radius, MIN_GIZMO_RADIUS)
		var factor := maxf(MIN_SCALE_FACTOR, 1.0 + amount)
		if snap != snap_enabled:
			factor = maxf(MIN_SCALE_FACTOR, snappedf(factor, scale_step))
		var factors := Vector3.ONE
		if active == UNIFORM_SCALE_HANDLE:
			factors = Vector3.ONE * factor
		elif local_space:
			factors[active] = factor
		else:
			# VS stores rotation and axis scale separately, so avoid world-space shear.
			var local_axes := start_transform.basis.orthonormalized()
			for i in range(3):
				factors[i] = 1.0 + (factor - 1.0) * pow(local_axes[i].dot(axis), 2)
		scale_preview.emit(factors)
		transform = view.selected_node.global_transform
	elif active < 3:
		var amount := (hit - start_hit).dot(axis)
		if snap != snap_enabled:
			amount = snappedf(amount, translation_step / Units.PER_BLOCK)
		var delta := axis * amount
		origin = start_origin + delta
		if mode == Mode.PIVOT:
			pivot_preview.emit(origin)
		else:
			transform.origin += delta
	else:
		var a := (start_hit - start_origin).normalized()
		var b := (hit - start_origin).normalized()
		var angle := atan2(axis.dot(a.cross(b)), a.dot(b))
		total_angle += wrapf(angle - last_angle, -PI, PI)
		last_angle = angle
		angle = snappedf(total_angle, deg_to_rad(rotation_step)) if snap != snap_enabled else total_angle
		var rotation := Basis(axis, angle)
		transform = Transform3D(rotation * start_transform.basis, start_origin + rotation * (start_transform.origin - start_origin))
	view.selected_node.global_transform = transform
	orientation = transform.basis.orthonormalized() if local_space else Basis.IDENTITY
	_build_paths()
	queue_redraw()


func finish(cancelled := false) -> void:
	if not dragging:
		return

	dragging = false
	if cancelled and is_instance_valid(view.selected_node):
		view.selected_node.global_transform = start_transform
	drag_finished.emit(cancelled)
	active = -1
