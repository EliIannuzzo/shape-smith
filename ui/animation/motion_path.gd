extends "res://ui/shared/toggle_settings.gd"

enum Scope { SELECTED_SHAPE, ENTIRE_HIERARCHY, SELECTED_HIERARCHY }
enum RenderMode { SHAPES, PATH }
const COMPACT_TOOLBAR_WIDTH := 1100
const DISTANT_FRAME_OPACITY := 0.12

const Units = preload("res://core/model/shape_units.gd")
const Math = preload("res://core/animation/vs_animation_math.gd")
var workspace
@onready var scope: OptionButton = $Popup/Margin/Content/Scope
@onready var frame_count: HSlider = $Popup/Margin/Content/Frames
@onready var frame_label: Label = $Popup/Margin/Content/FrameLabel
@onready var render_mode: OptionButton = $Popup/Margin/Content/RenderMode
@onready var opacity: HSlider = $Popup/Margin/Content/Opacity
@onready var fade: CheckBox = $Popup/Margin/Content/Fade
var drawing: Node3D
var ghosts := {}
var ghost_material := StandardMaterial3D.new()
var path_mesh := ImmediateMesh.new()
var path_drawing: MeshInstance3D
var samples := {}
var signature: Array = []


func _ready() -> void:
	super()
	drawing = Node3D.new()
	path_drawing = MeshInstance3D.new()
	frame_count.value_changed.connect(func(value: float): frame_label.text = "Frames: %d" % int(value))
	ghost_material.albedo_color = Color.WHITE
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.vertex_color_use_as_albedo = true
	ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var path_material := ghost_material.duplicate() as StandardMaterial3D
	path_material.no_depth_test = true
	path_drawing.mesh = path_mesh
	path_drawing.material_override = path_material
	path_drawing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	drawing.add_child(path_drawing)
	if workspace.is_node_ready():
		_bind_preview()
	else:
		workspace.ready.connect(_bind_preview, CONNECT_ONE_SHOT)


func _bind_preview() -> void:
	workspace.viewport.get_node("Viewport/World").add_child(drawing)
	workspace.editor.changed.connect(func(_index: int, _frame: float): invalidate())
	workspace.viewport.shape_replaced.connect(invalidate)


## Free the 3D drawing when this control is deleted, not when it is merely
## moved (the tool bar is re-parented onto the viewport).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(drawing):
		drawing.queue_free()


func invalidate() -> void:
	samples.clear()
	signature.clear()
	for ghost in ghosts.values():
		ghost.queue_free()
	ghosts.clear()


func _process(_delta: float) -> void:
	enabled_toggle.text = "" if get_viewport_rect().size.x < COMPACT_TOOLBAR_WIDTH else "Motion Path"
	# Keep settings valid even while the preview toggle is off.
	if workspace.selected >= 0 and workspace.selected < workspace.animation.clips.size():
		var length: int = workspace.animation.clips[workspace.selected].frames
		frame_count.max_value = maxi(1, length)
		frame_count.value = minf(frame_count.value, frame_count.max_value)
		frame_count.editable = length > 1
	var active: bool = workspace.animation_mode and is_enabled() and workspace.selected >= 0
	drawing.visible = active
	if not active:
		return

	var clip: Dictionary = workspace.animation.clips[workspace.selected]
	if not clip.error.is_empty():
		drawing.visible = false
		return

	var next := [
		workspace.selected,
		workspace.viewport.selected_node,
		floori(workspace.frame),
		scope.selected,
		frame_count.value,
		opacity.value,
		fade.button_pressed,
		render_mode.selected,
	]
	if next == signature:
		return
	# Rebinding/loading can replace nodes even with identical clip data.
	if signature.is_empty() or next[0] != signature[0]:
		samples.clear()
	signature = next.duplicate()
	redraw(clip)


func redraw(clip: Dictionary) -> void:
	for ghost in ghosts.values():
		ghost.visible = false
	path_mesh.clear_surfaces()
	path_drawing.visible = render_mode.selected == RenderMode.PATH
	var evaluator = workspace.animation
	evaluator.ensure_resolved(clip)
	var nodes: Array = []
	for entries in evaluator.elements.values():
		for entry in entries:
			if not is_instance_valid(entry.node):
				continue

			var selected_node: Node3D = workspace.viewport.selected_node
			var include_descendants := (
				scope.selected == Scope.SELECTED_HIERARCHY
				and is_instance_valid(selected_node)
				and selected_node.is_ancestor_of(entry.node)
			)
			if scope.selected == Scope.ENTIRE_HIERARCHY or entry.node == selected_node or include_descendants:
				nodes.append(entry.node)
	if nodes.is_empty():
		return

	var count := mini(int(frame_count.value), clip.frames)
	if count < 2:
		return

	var start := clampi(floori(workspace.frame) - count / 2, 0, clip.frames - count)
	var finish := start + count
	for time in samples.keys():
		if time < start or time >= finish:
			samples.erase(time)
	for time in range(start, finish):
		if samples.has(time):
			continue

		var local := {}
		for name in evaluator.elements:
			var track: Dictionary = clip.tracks.get(name, {"offset": [], "rotation": [], "stretch": []})
			var offset: Vector3 = Math.sample(track.offset, time, clip.frames, Vector3.ZERO) / Units.PER_BLOCK
			var rotation: Vector3 = Math.sample(track.rotation, time, clip.frames, Vector3.ZERO, true)
			var stretch: Vector3 = Math.sample(track.stretch, time, clip.frames, Vector3.ONE)
			for entry in evaluator.elements[name]:
				local[entry.node] = evaluator.element_transform(entry.source, offset, rotation, stretch, clip.version)
		var world := {}
		for node in local:
			_world(node, local, world)
		samples[time] = world
	if render_mode.selected == RenderMode.PATH:
		_draw_paths(nodes, start, finish, count)
		return

	for node in nodes:
		var geometry := node.get_node_or_null("Geometry") as MeshInstance3D
		if geometry == null or geometry.mesh == null or not geometry.is_visible_in_tree():
			continue

		var ghost := _ghost(node, geometry)
		ghost.visible = true
		var instances := ghost.multimesh
		instances.instance_count = count - 1
		var index := 0
		for time in range(start, finish):
			# Leave the current frame to the solid, selectable model.
			if time == floori(workspace.frame):
				continue

			instances.set_instance_transform(index, samples[time][node] * geometry.transform)
			instances.set_instance_color(index, _frame_color(time, count))
			index += 1


func _draw_paths(nodes: Array, start: int, finish: int, count: int) -> void:
	path_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for node in nodes:
		var source: Dictionary = node.get_meta("shape_element")
		var box_from := Vector3(source.from[0], source.from[1], source.from[2])
		var box_to := Vector3(source.to[0], source.to[1], source.to[2])
		var center := (box_to - box_from) / (Units.PER_BLOCK * 2.0)
		for time in range(start, finish - 1):
			for endpoint in [time, time + 1]:
				path_mesh.surface_set_color(_frame_color(endpoint, count))
				path_mesh.surface_add_vertex(samples[endpoint][node] * center)
	path_mesh.surface_end()


func _frame_color(time: float, count: int) -> Color:
	var color: Color = Palette.motion_previous if time < workspace.frame else Palette.motion_future
	color.a = opacity.value
	if fade.button_pressed:
		var distance_from_playhead := absf(time - workspace.frame) / maxf(1, count / 2.0)
		color.a *= lerpf(1.0, DISTANT_FRAME_OPACITY, clampf(distance_from_playhead, 0, 1))
	return color


func _ghost(node: Node3D, geometry: MeshInstance3D) -> MultiMeshInstance3D:
	if ghosts.has(node) and ghosts[node].get_meta("source_mesh") == geometry.mesh:
		return ghosts[node]

	if ghosts.has(node):
		ghosts[node].queue_free()
	var ghost := MultiMeshInstance3D.new()
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.use_colors = true
	# Reuse geometry while overriding every face with the texture-free preview.
	instances.mesh = geometry.mesh
	ghost.multimesh = instances
	ghost.material_override = ghost_material
	ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ghost.set_meta("source_mesh", geometry.mesh)
	drawing.add_child(ghost)
	ghosts[node] = ghost
	return ghost


func _world(node: Node3D, local: Dictionary, cache: Dictionary) -> Transform3D:
	if cache.has(node):
		return cache[node]

	var parent := node.get_parent() as Node3D
	var result: Transform3D = local[node]
	if local.has(parent):
		result = _world(parent, local, cache) * result
	elif parent != null:
		result = parent.global_transform * result
	cache[node] = result
	return result
