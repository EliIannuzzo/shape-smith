extends SubViewportContainer

const AXIS_SEGMENT_COUNT := 21
# Separate coplanar overlays to avoid depth flicker.
const AXIS_HEIGHT := -0.001
const GRID_HEIGHT := -0.002
const SELECTION_SURFACE_OFFSET := 0.0005
const FRAME_PADDING := 1.2
const MIN_FRAME_DISTANCE := 0.05
const MIN_CAMERA_DISTANCE := 0.02
const MAX_CAMERA_DISTANCE := 5000.0
const MIN_ORTHOGRAPHIC_SIZE := 0.001
const MAX_GRID_DIMENSION := 255
const ZOOM_IN_FACTOR := 0.9
const ZOOM_OUT_FACTOR := 1.1
const PICK_DRAG_THRESHOLD := 4.0
const ORBIT_SENSITIVITY := 0.008
const MAX_PITCH := 1.5
const POLE_ALIGNMENT_THRESHOLD := 0.999
const GIZMO_SHORTCUTS := [KEY_W, KEY_E, KEY_R, KEY_T]

const Units = preload("res://core/model/shape_units.gd")

signal element_picked(node: Node3D, face: String)
## Ctrl/Shift+click on an element: add or remove it from the selection.
signal element_toggle_picked(node: Node3D)
signal selection_changed(node: Node3D)
signal selection_changing
signal gizmo_mode_requested(mode: int)
signal shape_replaced
## The camera moved (orbit, pan, zoom, framing or projection).
signal camera_changed
## The element and face under the pointer changed (null when none).
signal hover_changed(node: Node3D, face: String)
static var Palette = preload("res://ui/theme/editor_palette.tres")
const Geometry = preload("res://core/model/shape_geometry.gd")
const TextureLibrary = preload("res://core/textures/texture_library.gd")
var texture_library = TextureLibrary.new()
var selection_enabled := false
var selected_node: Node3D
var selection_outline: MeshInstance3D
## Dimmer outlines for selected elements other than the active one.
var secondary_outlines: Array[MeshInstance3D] = []
var drag_distance := 0.0

@onready var camera: Camera3D = $Viewport/World/Camera
@onready var models: Node3D = $Viewport/World/Models
@onready var grid: MeshInstance3D = $Viewport/World/Grid
@onready var axes: MeshInstance3D = $Viewport/World/Axes

var grid_dimensions := Vector2i(15, 15)

var target := Vector3(0, 0.5, 0)
var yaw := PI / 4.0
var pitch := 0.45
var distance := 4.0
var grid_spacing := 1.0
var model_bounds := AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE)
var drag_button := 0
var axis_snap := false
var shape_data: Dictionary = {}
var gizmo
var attachment_editor
## Callables taking a click position; the first that returns true takes the click.
var click_handlers: Array[Callable] = []
var animation_pivot_at_origin := false
var render_elements: Array[Node3D] = []
var hovered: Node3D
var hovered_face := ""
var _parity_requested := false


func _init() -> void:
	# The main view previews the game's own shading; references stay plain.
	texture_library.game_shading = true


func _ready() -> void:
	clip_contents = true
	gizmo = preload("res://ui/viewport/gizmos/transform_gizmo.gd").new()
	gizmo.view = self
	add_child(gizmo)
	var environment: Environment = $Viewport/World/Environment.environment
	environment.background_mode = Environment.BG_CLEAR_COLOR
	$Viewport.transparent_bg = true
	var checker := ColorRect.new()
	checker.name = "SceneChecker"
	checker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	checker.show_behind_parent = true
	checker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var material := ShaderMaterial.new()
	material.shader = preload("res://assets/shaders/scene_checker.gdshader")
	material.set_shader_parameter("checker_dark", Palette.checker_dark)
	material.set_shader_parameter("checker_light", Palette.checker_light)
	checker.material = material
	add_child(checker)
	gui_input.connect(_on_gui_input)
	resized.connect(_update_camera)
	_update_camera()
	_rebuild_grid()
	texture_library.changed.connect(refresh_textures)
	_rebuild_axes()


func refresh_palette() -> void:
	var checker := get_node_or_null("SceneChecker") as ColorRect
	if checker != null:
		checker.material.set_shader_parameter("checker_dark", Palette.checker_dark)
		checker.material.set_shader_parameter("checker_light", Palette.checker_light)
	_rebuild_grid()
	_rebuild_axes()
	if is_instance_valid(selection_outline):
		selection_outline.material_override.albedo_color = Palette.accent
	gizmo.queue_redraw()


func _rebuild_axes() -> void:
	var axis_mesh: ImmediateMesh = axes.mesh
	axis_mesh.clear_surfaces()
	axis_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	# Short near segments avoid clipping precision loss on horizon-length lines.
	for direction in [-1.0, 1.0]:
		var start := 0.0
		for power in range(AXIS_SEGMENT_COUNT):
			var end: float = pow(2.0, power) * direction
			_line(axis_mesh, Vector3(start, AXIS_HEIGHT, 0), Vector3(end, AXIS_HEIGHT, 0), Palette.axis_x)
			_line(axis_mesh, Vector3(0, AXIS_HEIGHT, start), Vector3(0, AXIS_HEIGHT, end), Palette.axis_z)
			start = end
	axis_mesh.surface_end()


func show_shape(result: Dictionary) -> void:
	select_element(null)
	for child in models.get_children():
		models.remove_child(child)
		child.queue_free()
	models.add_child(result.root)
	shape_data = result.data
	shape_replaced.emit()
	model_bounds = result.bounds
	model_bounds.position += models.position
	frame_shape()
	texture_library.bind(shape_data, result.get("path", ""))


func refresh_textures() -> void:
	render_elements = Geometry.elements(models)
	for node in render_elements:
		Geometry.refresh(node, texture_library)


## Rebuilds meshes whose mirroring no longer matches their transform (a
## negative scale or stretch flips the winding). Call request_parity_check()
## after changing element transforms; it runs once, before the frame renders.
func sync_geometry_parity() -> void:
	_parity_requested = false
	for node in Geometry.elements(models):
		var geometry: MeshInstance3D = node.get_node_or_null("Geometry")
		if geometry != null and geometry.get_meta("render_reflected", false) != Geometry.reflected(node):
			Geometry.refresh(node, texture_library)


func request_parity_check() -> void:
	if not _parity_requested:
		_parity_requested = true
		sync_geometry_parity.call_deferred()


func set_render_mode(mode: int) -> void:
	texture_library.render_mode = clampi(mode, 0, 2)
	texture_library.materials.clear()
	refresh_textures()


func pick_at(position_value: Vector2) -> Dictionary:
	return Geometry.pick(models, camera.project_ray_origin(position_value), camera.project_ray_normal(position_value))


func select_element(node: Node3D, face := "") -> void:
	selection_changing.emit()
	if gizmo != null and gizmo.dragging:
		gizmo.finish(true)
	if is_instance_valid(selection_outline):
		var previous := selection_outline
		selection_outline = null
		if previous.get_parent() != null:
			previous.get_parent().remove_child(previous)
		previous.queue_free()
	selected_node = node
	selection_changed.emit(node)
	if not is_instance_valid(node):
		return

	selection_outline = _outline(node, face, Palette.accent)
	node.add_child(selection_outline)


func _outline(node: Node3D, face: String, color: Color) -> MeshInstance3D:
	var source: Dictionary = node.get_meta("shape_element")
	var vertices := Geometry.corners(Geometry.size_of(source))
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(6):
		if not face.is_empty() and Geometry.FACES[i] != face:
			continue

		for edge in range(4):
			mesh.surface_add_vertex(vertices[i][edge] + Geometry.NORMALS[i] * SELECTION_SURFACE_OFFSET)
			mesh.surface_add_vertex(vertices[i][(edge + 1) % 4] + Geometry.NORMALS[i] * SELECTION_SURFACE_OFFSET)
	mesh.surface_end()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	if color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var outline := MeshInstance3D.new()
	outline.mesh = mesh
	outline.material_override = material
	outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return outline


## Outlines the other selected elements more faintly than the active one.
func set_secondary_selection(nodes: Array) -> void:
	for outline in secondary_outlines:
		if is_instance_valid(outline):
			if outline.get_parent() != null:
				outline.get_parent().remove_child(outline)
			outline.queue_free()
	secondary_outlines.clear()
	for node in nodes:
		if is_instance_valid(node) and node != selected_node and node.is_inside_tree():
			var outline := _outline(node, "", Color(Palette.accent, 0.45))
			node.add_child(outline)
			secondary_outlines.append(outline)


func frame_shape() -> void:
	frame_bounds(model_bounds)


## Points the camera at a world-space box and backs off until it fits.
func frame_bounds(bounds: AABB) -> void:
	target = bounds.get_center()
	var radius := maxf(bounds.size.length() * 0.5, 0.05)
	var aspect := maxf(size.x / maxf(size.y, 1.0), 0.1)
	var half_fov := atan(tan(deg_to_rad(camera.fov * 0.5)) * minf(aspect, 1.0))
	distance = clampf(radius / sin(half_fov) * FRAME_PADDING, MIN_FRAME_DISTANCE, MAX_CAMERA_DISTANCE)
	_update_camera()


func set_projection(orthographic: bool) -> void:
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL if orthographic else Camera3D.PROJECTION_PERSPECTIVE
	_update_camera()


func set_grid_spacing(spacing: float) -> void:
	grid_spacing = spacing
	_rebuild_grid()


func set_grid_dimensions(dimensions: Vector2i) -> void:
	# Keep whole center cells at every supported subdivision.
	grid_dimensions = Vector2i(clampi(dimensions.x, 1, MAX_GRID_DIMENSION) | 1, clampi(dimensions.y, 1, MAX_GRID_DIMENSION) | 1)
	_rebuild_grid()


func _rebuild_grid() -> void:
	var mesh: ImmediateMesh = grid.mesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	# Odd block count puts a whole block at the origin, under the model footprint.
	var half_extent := Vector2(grid_dimensions) * 0.5
	for axis in range(2):
		var count := roundi(grid_dimensions[axis] / grid_spacing)
		for i in range(count + 1):
			var position_value := -half_extent[axis] + i * grid_spacing
			var whole_block := is_equal_approx(position_value + 0.5, roundf(position_value + 0.5))
			var color: Color = Palette.grid_major if whole_block else Palette.grid_minor
			if axis == 0:
				_line(mesh, Vector3(position_value, GRID_HEIGHT, -half_extent.y), Vector3(position_value, GRID_HEIGHT, half_extent.y), color)
			else:
				_line(mesh, Vector3(-half_extent.x, GRID_HEIGHT, position_value), Vector3(half_extent.x, GRID_HEIGHT, position_value), color)
	mesh.surface_end()


func _line(mesh: ImmediateMesh, start: Vector3, end: Vector3, color: Color) -> void:
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(start)
	mesh.surface_set_color(color)
	mesh.surface_add_vertex(end)


func _on_gui_input(event: InputEvent) -> void:
	if (
		event is InputEventKey and event.pressed and not event.echo
		and not event.ctrl_pressed and not event.alt_pressed
		and not event.meta_pressed and not event.shift_pressed
		and event.keycode in GIZMO_SHORTCUTS
	):
		gizmo_mode_requested.emit(GIZMO_SHORTCUTS.find(event.keycode))
		accept_event()
		return

	if event is InputEventMouseMotion and drag_button == 0 and not gizmo.dragging:
		var picked := pick_at(event.position)
		var node: Node3D = picked.get("node")
		var face: String = picked.get("face", "")
		if node != hovered or face != hovered_face:
			hovered = node
			hovered_face = face
			hover_changed.emit(node, face)

	if event is InputEventMouseButton and event.pressed:
		grab_focus()
		if event.button_index == MOUSE_BUTTON_LEFT and attachment_editor != null and attachment_editor.begin_at(event.position):
			accept_event()
			return

		if event.button_index == MOUSE_BUTTON_LEFT and gizmo.begin(event.position):
			accept_event()
			return

		# Overlays with their own clickable markers (IK controllers).
		if event.button_index == MOUSE_BUTTON_LEFT:
			for handler in click_handlers:
				if handler.call(event.position):
					accept_event()
					return

		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			drag_button = event.button_index
			drag_distance = 0.0
			_set_axis_snap(event.shift_pressed and drag_button != MOUSE_BUTTON_MIDDLE)
			accept_event()
		elif event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			distance = clampf(distance * (ZOOM_IN_FACTOR if event.button_index == MOUSE_BUTTON_WHEEL_UP else ZOOM_OUT_FACTOR), MIN_CAMERA_DISTANCE, MAX_CAMERA_DISTANCE)
			_update_camera()
			accept_event()


func _input(event: InputEvent) -> void:
	if attachment_editor != null and attachment_editor.gizmo.dragging:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			attachment_editor.gizmo.finish(true)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			attachment_editor.gizmo.finish()
		elif event is InputEventMouseMotion:
			attachment_editor.gizmo.motion(get_global_transform_with_canvas().affine_inverse() * event.position, event.ctrl_pressed)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion and attachment_editor != null:
		attachment_editor.gizmo.motion(get_global_transform_with_canvas().affine_inverse() * event.position)
	if gizmo.dragging:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			gizmo.finish(true)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			gizmo.finish()
		elif event is InputEventMouseMotion:
			gizmo.motion(get_global_transform_with_canvas().affine_inverse() * event.position, event.ctrl_pressed, event.shift_pressed)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion:
		gizmo.motion(get_global_transform_with_canvas().affine_inverse() * event.position)
	if event is InputEventMouseButton and not event.pressed and event.button_index == drag_button:
		if selection_enabled and drag_button == MOUSE_BUTTON_LEFT and drag_distance < PICK_DRAG_THRESHOLD:
			var position_value: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
			if Rect2(Vector2.ZERO, size).has_point(position_value):
				var picked := pick_at(position_value)
				if picked.has("node") and (event.ctrl_pressed or event.meta_pressed or event.shift_pressed):
					element_toggle_picked.emit(picked.node)
				elif picked.has("node"):
					element_picked.emit(picked.node, picked.face)
				elif not (event.ctrl_pressed or event.meta_pressed or event.shift_pressed):
					element_picked.emit(null, "")
		drag_button = 0
		_set_axis_snap(false)
	if event is InputEventKey and event.keycode == KEY_SHIFT and drag_button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		_set_axis_snap(event.pressed)
		get_viewport().set_input_as_handled()
	if event is InputEventMouseMotion and drag_button != 0:
		drag_distance += event.relative.length()
		if drag_button == MOUSE_BUTTON_MIDDLE:
			var height := 2.0 * distance * tan(deg_to_rad(camera.fov * 0.5))
			target += (-camera.basis.x * event.relative.x + camera.basis.y * event.relative.y) * height / maxf(size.y, 1.0)
		else:
			_set_axis_snap(event.shift_pressed)
			yaw -= event.relative.x * ORBIT_SENSITIVITY
			pitch = clampf(pitch + event.relative.y * ORBIT_SENSITIVITY, -MAX_PITCH, MAX_PITCH)
		_update_camera()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		if attachment_editor != null:
			attachment_editor.gizmo.finish(true)
		if gizmo != null:
			gizmo.finish(true)
		drag_button = 0
		_set_axis_snap(false)


func _set_axis_snap(enabled: bool) -> void:
	if axis_snap == enabled:
		return

	if axis_snap and is_instance_valid(camera):
		# Keep the snapped view on release; subsequent motion starts from that axis.
		var direction := (camera.position - target).normalized()
		yaw = atan2(direction.x, direction.z) if absf(direction.y) < POLE_ALIGNMENT_THRESHOLD else yaw
		pitch = asin(clampf(direction.y, -1.0, 1.0))
	axis_snap = enabled
	_update_camera()


func _update_camera() -> void:
	if not is_instance_valid(camera):
		return

	var direction := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	if axis_snap:
		var axis := direction.abs().max_axis_index()
		var snapped := Vector3.ZERO
		snapped[axis] = signf(direction[axis])
		direction = snapped
	camera.position = target + direction * distance
	# Top/bottom views need an up vector perpendicular to the viewing direction.
	camera.look_at(target, Vector3.BACK if absf(direction.y) > POLE_ALIGNMENT_THRESHOLD else Vector3.UP)
	# KEEP_HEIGHT makes size the vertical span. Match perspective at the target.
	camera.size = maxf(2.0 * distance * tan(deg_to_rad(camera.fov * 0.5)), MIN_ORTHOGRAPHIC_SIZE)
	camera_changed.emit()


## Looks along an axis: direction points from the target to the camera.
func view_from(direction: Vector3) -> void:
	direction = direction.normalized()
	pitch = clampf(asin(clampf(direction.y, -1.0, 1.0)), -MAX_PITCH, MAX_PITCH)
	if absf(direction.y) < POLE_ALIGNMENT_THRESHOLD:
		yaw = atan2(direction.x, direction.z)
	_update_camera()


func gizmo_pivot() -> Vector3:
	if animation_pivot_at_origin:
		return selected_node.global_position

	var source: Dictionary = selected_node.get_meta("shape_element")
	# IK controllers are points: their gizmo sits on them.
	if source.get("shapesmithController", false) == true:
		return selected_node.global_position
	var start: Array = source.from
	var pivot: Array = source.get("rotationOrigin", [0, 0, 0])
	return selected_node.global_transform * ((Vector3(pivot[0], pivot[1], pivot[2]) - Vector3(start[0], start[1], start[2])) / Units.PER_BLOCK)


## The world-space box around the enabled faces of these elements.
func bounds_of(nodes: Array) -> AABB:
	var result := AABB()
	var found := false
	for element in nodes:
		var source: Dictionary = element.get_meta("shape_element")
		var corners := Geometry.corners(Geometry.size_of(source))
		for i in range(6):
			for corner in corners[i]:
				var point: Vector3 = element.global_transform * corner
				result = result.expand(point) if found else AABB(point, Vector3.ZERO)
				found = true
	return result


func update_model_bounds() -> void:
	var found := false
	for element in Geometry.elements(models):
		var source: Dictionary = element.get_meta("shape_element")
		var corners := Geometry.corners(Geometry.size_of(source))
		for i in range(6):
			if not source.get("faces", {}).has(Geometry.FACES[i]) or not source.faces[Geometry.FACES[i]].get("enabled", true):
				continue

			for corner in corners[i]:
				var point: Vector3 = element.global_transform * corner
				model_bounds = model_bounds.expand(point) if found else AABB(point, Vector3.ZERO)
				found = true
	if not found:
		model_bounds = AABB(Vector3.ZERO, Vector3.ONE)
