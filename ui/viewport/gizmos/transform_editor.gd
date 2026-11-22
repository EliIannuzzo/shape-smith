extends Node

const MIN_ELEMENT_SIZE := 0.001


# Smaller determinants make inverse transforms unstable.
const MIN_TRANSFORM_DETERMINANT := 0.000001

const Units = preload("res://core/model/shape_units.gd")
const ShapeAnimation = preload("res://core/animation/shape_animation.gd")
const Document = preload("res://core/document/shape_document.gd")
const SetFields = preload("res://core/commands/set_element_fields.gd")
const Composite = preload("res://core/commands/composite_command.gd")
const MODEL_FIELDS := ["from", "to", "rotationOrigin", "rotationX", "rotationY", "rotationZ", "scaleX", "scaleY", "scaleZ", "renderPass"]
var viewport_view
var animation_workspace
var edit_history
var face_panel
var details_panel
var reference_models
var attachment_editor
var editor_mode := "View"
var document

var node: Node3D
var before := Transform3D.IDENTITY
var source_before: Dictionary
var animation_edit := false
var frame := 0
var clip := -1
var scale_factors := Vector3.ONE
var size_after: Dictionary = {}
var pivot_after: Dictionary = {}
var context_basis := Transform3D.IDENTITY
## Returns every selected element node (set by the app); the gizmo's shape is one of them.
var selected_nodes := Callable()
## The other selected shapes a Model mode move, turn or scale carries along:
## [{node, before (local), global (global before), source}].
var companions: Array = []


func bind_services(view: Node, playback: Control, history: Node, faces: Control) -> void:
	viewport_view = view
	animation_workspace = playback
	edit_history = history
	face_panel = faces


## Called whenever a document opens or a new one starts.
func bind_document(target_document) -> void:
	document = target_document


func bind_editors(details: Control, references: Node, attachments: Node) -> void:
	details_panel = details
	reference_models = references
	attachment_editor = attachments


func _ready() -> void:
	viewport_view.gizmo.drag_started.connect(_begin)
	viewport_view.gizmo.drag_finished.connect(_finish)
	viewport_view.gizmo.scale_preview.connect(_preview_scale)
	viewport_view.gizmo.size_preview.connect(_preview_size)
	viewport_view.gizmo.pivot_preview.connect(_preview_pivot)


func _process(_delta: float) -> void:
	var view = viewport_view
	var workspace = animation_workspace
	var animation_mode: bool = editor_mode == "Animation"
	var playable: bool = workspace.selected >= 0 and workspace.selected < workspace.animation.clips.size() and workspace.animation.clips[workspace.selected].error.is_empty()
	view.gizmo.enabled = editor_mode == "Model" or (animation_mode and playable)
	if attachment_editor != null and attachment_editor.editing():
		view.gizmo.enabled = false
	if animation_mode and view.gizmo.mode in [view.gizmo.Mode.SIZE, view.gizmo.Mode.PIVOT]:
		view.gizmo.enabled = false
	view.animation_pivot_at_origin = animation_mode and playable and workspace.animation.clips[workspace.selected].version == 1
	if is_instance_valid(view.selected_node) and absf(view.selected_node.global_basis.determinant()) < MIN_TRANSFORM_DETERMINANT:
		view.gizmo.enabled = false
	if is_instance_valid(view.selected_node) and view.selected_node.get_meta("shapesmith_locked", false):
		view.gizmo.enabled = false
	# IK targets and poles only move.
	view.gizmo.translate_only = is_instance_valid(view.selected_node) and view.selected_node.has_meta("shape_element") 		and view.selected_node.get_meta("shape_element").get("shapesmithController", false) == true
	if view.gizmo.dragging and not companions.is_empty() and is_instance_valid(node):
		_preview_companions()


func model_preview(element: Node3D) -> Dictionary:
	var gizmo = viewport_view.gizmo
	if not gizmo.dragging or node != element:
		return {}

	if gizmo.mode == gizmo.Mode.PIVOT:
		return pivot_after

	var correction := context_basis.affine_inverse()
	return model_fields(correction * element.transform, gizmo.active >= 3, source_before, correction * before)


func _begin() -> void:
	scale_factors = Vector3.ONE
	size_after = {}
	pivot_after = {}
	details_panel.finish_pending()
	face_panel.finish_pending()
	animation_workspace.finish_pending()
	animation_edit = editor_mode == "Animation"
	if animation_edit:
		animation_workspace.seek(roundf(animation_workspace.frame))
	node = viewport_view.selected_node
	before = node.transform
	context_basis = Transform3D.IDENTITY
	if reference_models.main_poses.has(node):
		context_basis = before * reference_models.main_poses[node].pose.affine_inverse()
	source_before = node.get_meta("shape_element").duplicate(true)
	frame = roundi(animation_workspace.frame)
	clip = animation_workspace.selected
	companions = _gather_companions()


## Selected shapes other than the gizmo's, skipping any inside another selected
## shape (they already move with it) and locked ones. Model mode only: moving,
## turning and scaling act on all of them; resizing and pivots on one.
func _gather_companions() -> Array:
	var result: Array = []
	var gizmo = viewport_view.gizmo
	if animation_edit or not selected_nodes.is_valid() or gizmo.mode in [gizmo.Mode.SIZE, gizmo.Mode.PIVOT] or context_basis != Transform3D.IDENTITY:
		return result
	var picked: Array = selected_nodes.call()
	if picked.size() < 2 or not node in picked:
		return result
	for other in picked:
		if other == node or not is_instance_valid(other) or other.get_meta("shapesmith_locked", false):
			continue
		if picked.any(func(owner): return owner != other and is_instance_valid(owner) and owner.is_ancestor_of(other)):
			continue
		if absf(other.global_basis.determinant()) < MIN_TRANSFORM_DETERMINANT:
			continue
		result.append({"node": other, "before": other.transform, "global": other.global_transform, "source": other.get_meta("shape_element").duplicate(true)})
	return result


## Moves the companions with the gizmo's shape while dragging: by the same
## distance, or turned by the same amount about each one's own pivot.
func _preview_companions() -> void:
	var gizmo = viewport_view.gizmo
	if gizmo.mode == gizmo.Mode.SCALE:
		for entry in companions:
			if is_instance_valid(entry.node):
				entry.node.transform = animation_workspace.animation.element_transform(_scaled(entry.source, scale_factors), Vector3.ZERO, Vector3.ZERO, Vector3.ONE, 0)
		return
	var parent_global: Transform3D = (node.get_parent() as Node3D).global_transform if node.get_parent() is Node3D else Transform3D.IDENTITY
	var moved: Transform3D = (parent_global * node.transform) * (parent_global * before).affine_inverse()
	var rotating: bool = gizmo.active in [3, 4, 5]
	for entry in companions:
		if not is_instance_valid(entry.node):
			continue
		var start: Transform3D = entry.global
		if rotating:
			var pivot := _pivot_global(entry.source, start)
			entry.node.global_transform = Transform3D(moved.basis, pivot - moved.basis * pivot) * start
		else:
			entry.node.global_transform = Transform3D(Basis(), moved.origin) * start


func _pivot_global(source: Dictionary, global: Transform3D) -> Vector3:
	var pivot := vector_from_array(source.get("rotationOrigin", [0, 0, 0])) - vector_from_array(source.get("from", [0, 0, 0]))
	return global * (pivot / Units.PER_BLOCK)


func _scaled(source: Dictionary, factors: Vector3) -> Dictionary:
	var result := source.duplicate(true)
	for i in range(3):
		var key: String = "scale" + ["X", "Y", "Z"][i]
		result[key] = float(source.get(key, 1)) * factors[i]
	return result


func _restore_companions() -> void:
	for entry in companions:
		if is_instance_valid(entry.node):
			entry.node.transform = entry.before


func _finish(cancelled: bool) -> void:
	if not is_instance_valid(node):
		return

	var desired := node.transform
	node.transform = before
	var carried: Array = []
	for entry in companions:
		if is_instance_valid(entry.node):
			carried.append({"node": entry.node, "desired": entry.node.transform, "before": entry.before, "source": entry.source})
	_restore_companions()
	companions = []
	viewport_view.request_parity_check()
	if viewport_view.gizmo.mode == viewport_view.gizmo.Mode.PIVOT:
		var previous := _model_fields_snapshot(source_before)
		if not cancelled and not pivot_after.is_empty() and pivot_after != previous:
			commit_model_fields(node, previous, pivot_after, "Move Shape Pivot")
		return

	if viewport_view.gizmo.mode == viewport_view.gizmo.Mode.SIZE:
		var previous := _model_fields_snapshot(source_before)
		if cancelled or size_after.is_empty() or size_after == previous:
			viewport_view.Geometry.refresh(node, viewport_view.texture_library)
			viewport_view.select_element(node)
		else:
			commit_model_fields(node, previous, size_after, "Resize Shape")
		return

	if cancelled or desired.is_equal_approx(before):
		return

	if viewport_view.gizmo.mode == viewport_view.gizmo.Mode.SCALE:
		if animation_edit:
			var name_value := str(source_before.get("name", ""))
			if name_value.is_empty() or animation_workspace.animation.elements.get(name_value, []).size() != 1:
				animation_workspace.editor.rejected.emit("Give this shape a unique name before animating it.")
				return

			var values := _animation_values()
			if animation_workspace.auto_key:
				animation_workspace.editor.set_transform(clip, frame, name_value, "stretch", values.stretch * scale_factors)
			else:
				animation_workspace.hold(name_value, "stretch", values.stretch * scale_factors)
		else:
			var previous: Dictionary = {}
			for field in MODEL_FIELDS:
				if source_before.has(field):
					previous[field] = source_before[field]
			var after := previous.duplicate(true)
			for i in range(3):
				var key: String = "scale" + ["X", "Y", "Z"][i]
				after[key] = float(source_before.get(key, 1)) * scale_factors[i]
			if carried.is_empty():
				commit_model_fields(node, previous, after, "Scale Shape")
			else:
				var changes: Array = [{"node": node, "previous": previous, "after": after}]
				for entry in carried:
					var other_previous := _model_fields_snapshot(entry.source)
					changes.append({"node": entry.node, "previous": other_previous, "after": _model_fields_snapshot(_scaled(entry.source, scale_factors))})
				commit_many(changes, "Scale %d Shapes" % changes.size())
		return

	var rotating: bool = viewport_view.gizmo.active in [3, 4, 5]
	if animation_edit:
		_commit_animation(context_basis.affine_inverse() * desired, rotating)
	elif carried.is_empty():
		_commit_model(context_basis.affine_inverse() * desired, rotating)
	else:
		var changes: Array = [{"node": node, "previous": _model_fields_snapshot(source_before), "after": model_fields(desired, rotating, source_before, before)}]
		for entry in carried:
			changes.append({"node": entry.node, "previous": _model_fields_snapshot(entry.source), "after": model_fields(entry.desired, rotating, entry.source, entry.before)})
		commit_many(changes, "%s %d Shapes" % ["Rotate" if rotating else "Move", changes.size()])


func _model_fields_snapshot(source: Dictionary) -> Dictionary:
	var fields: Dictionary = {}
	for field in MODEL_FIELDS:
		if source.has(field):
			fields[field] = source[field].duplicate() if source[field] is Array else source[field]
	return fields


func _preview_pivot(world_position: Vector3) -> void:
	var source := source_before.duplicate(true)
	var parent: Node3D = node.get_parent()
	var pivot := (parent.global_transform * context_basis).affine_inverse() * world_position
	if pivot.is_equal_approx(vector_from_array(source_before.get("rotationOrigin", [0, 0, 0])) / Units.PER_BLOCK):
		pivot_after = _model_fields_snapshot(source_before)
		return
	# Compensate the box origin for rotation/scale around its new pivot. This
	# preserves the node transform, its visible vertices, and all child transforms.
	var canonical := context_basis.affine_inverse() * before
	var start := pivot + canonical.basis.inverse() * (canonical.origin - pivot)
	var extent := vector_from_array(source_before.to) - vector_from_array(source_before.from)
	source.rotationOrigin = vector_to_array(pivot * Units.PER_BLOCK)
	source.from = vector_to_array(start * Units.PER_BLOCK)
	source.to = vector_to_array(start * Units.PER_BLOCK + extent)
	pivot_after = _model_fields_snapshot(source)


func _preview_size(axis_index: int, side: int, amount: float, symmetric: bool) -> void:
	var source := source_before.duplicate(true)
	var minimum := float(source.from[axis_index])
	var maximum := float(source.to[axis_index])
	var width := maximum - minimum
	# Keep faces from crossing; Shift changes both sides around the starting center.
	var change := maxf(side * amount, (MIN_ELEMENT_SIZE - width) / (2.0 if symmetric else 1.0))
	if side < 0:
		source.from[axis_index] = minimum - change
		if symmetric:
			source.to[axis_index] = maximum + change
	else:
		source.to[axis_index] = maximum + change
		if symmetric:
			source.from[axis_index] = minimum - change
	size_after = _model_fields_snapshot(source)
	var live: Dictionary = node.get_meta("shape_element")
	node.set_meta("shape_element", source)
	viewport_view.Geometry.refresh(node, viewport_view.texture_library)
	node.transform = context_basis * animation_workspace.animation.element_transform(source, Vector3.ZERO, Vector3.ZERO, Vector3.ONE, 0)
	viewport_view.gizmo.size_dimensions = viewport_view.Geometry.size_of(source)
	node.set_meta("shape_element", live)
	viewport_view.request_parity_check()
	if is_instance_valid(viewport_view.selection_outline):
		viewport_view.selection_outline.hide()


func _animation_values() -> Dictionary:
	var compiled: Dictionary = animation_workspace.animation.clips[clip]
	var name_value := str(source_before.get("name", ""))
	var track: Dictionary = compiled.tracks.get(name_value, {"offset": [], "rotation": [], "stretch": []})
	var animation = animation_workspace.animation
	return {"version": compiled.version,
		"offset": animation.sample_track(track.offset, frame, compiled.frames, Vector3.ZERO),
		"rotation": animation.sample_track(track.rotation, frame, compiled.frames, Vector3.ZERO, true),
		"stretch": animation.sample_track(track.stretch, frame, compiled.frames, Vector3.ONE)}


func _preview_scale(factors: Vector3) -> void:
	scale_factors = factors
	if animation_edit:
		var values := _animation_values()
		node.transform = context_basis * animation_workspace.animation.element_transform(source_before, values.offset, values.rotation, values.stretch * factors, values.version)
	else:
		var source := source_before.duplicate(true)
		for i in range(3):
			var key: String = "scale" + ["X", "Y", "Z"][i]
			source[key] = float(source.get(key, 1)) * factors[i]
		node.transform = context_basis * animation_workspace.animation.element_transform(source, Vector3.ZERO, Vector3.ZERO, Vector3.ONE, 0)
	viewport_view.request_parity_check()


func vector_from_array(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])


func vector_to_array(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


func rotation_degrees(basis: Basis, reference: Vector3) -> Vector3:
	return preload("res://core/animation/rotation_paths.gd").nearest_euler(basis, reference)


func _commit_model(desired: Transform3D, rotating: bool) -> void:
	var previous: Dictionary = {}
	for field in MODEL_FIELDS:
		if source_before.has(field):
			previous[field] = source_before[field]
	var after := model_fields(desired, rotating, source_before, context_basis.affine_inverse() * before)
	commit_model_fields(node, previous, after, "Rotate Shape" if rotating else "Move Shape")


func model_fields(desired: Transform3D, rotating: bool, source: Dictionary, original: Transform3D) -> Dictionary:
	var previous: Dictionary = {}
	for field in MODEL_FIELDS:
		if source.has(field):
			previous[field] = source[field]
	var after := previous.duplicate(true)
	if rotating:
		var scale_value := Vector3(source.get("scaleX", 1), source.get("scaleY", 1), source.get("scaleZ", 1))
		var reference := Vector3(source.get("rotationX", 0), source.get("rotationY", 0), source.get("rotationZ", 0))
		var angles := rotation_degrees(desired.basis * Basis.from_scale(Vector3.ONE / scale_value), reference)
		for i in range(3):
			after["rotation" + ["X", "Y", "Z"][i]] = angles[i]
	else:
		var delta := (desired.origin - original.origin) * Units.PER_BLOCK
		for field in ["from", "to", "rotationOrigin"]:
			after[field] = vector_to_array(vector_from_array(source.get(field, [0, 0, 0])) + delta)
	return after


func edit_property(element: Node3D, group: String, axis: int, value: float) -> void:
	var change := property_change(element, group, axis, value)
	if change.is_empty() or change.after == change.previous:
		return

	commit_model_fields(element, change.previous, change.after, "Change Shape " + group.capitalize(), "model:%s:%s:%d" % [Document.uid_of(element), group, axis])


## Sets one inspector value on several elements as one undo step. Position
## and size set the same coordinate on each; rotation and scale the same angle
## or factor.
func edit_property_many(elements: Array, group: String, axis: int, value: float) -> void:
	var steps: Array = []
	for element in elements:
		var change := property_change(element, group, axis, value)
		var uid := Document.uid_of(element)
		if change.is_empty() or change.after == change.previous or not document.has(uid):
			continue
		var fields := {}
		for key in change.after:
			if not change.previous.has(key) or change.previous[key] != change.after[key]:
				fields[key] = change.after[key]
		for key in change.previous:
			if not change.after.has(key):
				fields[key] = Document.ABSENT
		steps.append(SetFields.new(document, uid, fields))
	if not steps.is_empty():
		edit_history.execute(Composite.new(document, steps, "Change %d Shapes' %s" % [steps.size(), group.capitalize()]))


## The MODEL_FIELDS before and after setting one inspector value, or {}.
func property_change(element: Node3D, group: String, axis: int, value: float) -> Dictionary:
	var source: Dictionary = element.get_meta("shape_element")
	var previous: Dictionary = {}
	for field in MODEL_FIELDS:
		if source.has(field):
			previous[field] = source[field]
	var after := previous.duplicate(true)
	if group == "position":
		var delta := value - float(source.from[axis])
		for field in ["from", "to", "rotationOrigin"]:
			after[field] = source.get(field, [0, 0, 0]).duplicate()
			after[field][axis] += delta
	elif group == "size":
		after.to = source.to.duplicate()
		after.to[axis] = float(source.from[axis]) + value
	elif group == "pivot":
		after.rotationOrigin = source.get("rotationOrigin", [0, 0, 0]).duplicate()
		after.rotationOrigin[axis] = value
	elif group in ["rotation", "scale"]:
		after[group + ["X", "Y", "Z"][axis]] = value
	elif group == "renderPass":
		if value == -1:
			after.erase("renderPass")
		else:
			after.renderPass = int(value)
	else:
		return {}
	return {"previous": previous, "after": after}


## Commits a change between two MODEL_FIELDS snapshots as one command that
## holds only the fields that differ. SceneSync moves the node and rebuilds
## its mesh.
func commit_model_fields(element: Node3D, previous: Dictionary, after: Dictionary, label: String, merge_key := "") -> bool:
	var uid := Document.uid_of(element)
	if document == null or not document.has(uid):
		return false
	var fields := {}
	for key in after:
		if not previous.has(key) or previous[key] != after[key]:
			fields[key] = after[key]
	for key in previous:
		if not after.has(key):
			fields[key] = Document.ABSENT
	if fields.is_empty():
		return true
	return edit_history.execute(SetFields.new(document, uid, fields, label, merge_key))


## Several MODEL_FIELDS changes as one undo step: [{node, previous, after}].
func commit_many(changes: Array, label: String) -> bool:
	var steps: Array = []
	for change in changes:
		var uid := Document.uid_of(change.node)
		if document == null or not document.has(uid):
			continue
		var fields := {}
		for key in change.after:
			if not change.previous.has(key) or change.previous[key] != change.after[key]:
				fields[key] = change.after[key]
		for key in change.previous:
			if not change.after.has(key):
				fields[key] = Document.ABSENT
		if not fields.is_empty():
			steps.append(SetFields.new(document, uid, fields))
	if steps.is_empty():
		return false
	return edit_history.execute(Composite.new(document, steps, label))


func _commit_animation(desired: Transform3D, rotating: bool) -> void:
	var workspace = animation_workspace
	var source: Dictionary = node.get_meta("shape_element")
	var name: String = source.get("name", "")
	# VS animation tracks identify elements by name. Ambiguous tracks cannot be edited safely.
	if name.is_empty() or workspace.animation.elements.get(name, []).size() != 1:
		workspace.editor.rejected.emit("Give this shape a unique name before animating it.")
		return

	var compiled: Dictionary = workspace.animation.clips[clip]
	var base_rotation := Vector3(source.get("rotationX", 0), source.get("rotationY", 0), source.get("rotationZ", 0))
	var base_scale := Vector3(source.get("scaleX", 1), source.get("scaleY", 1), source.get("scaleZ", 1))
	var track: Dictionary = compiled.tracks.get(name, {"offset": [], "rotation": [], "stretch": []})
	var stretch: Vector3 = workspace.animation.sample_track(track.stretch, frame, compiled.frames, Vector3.ONE)
	var reference: Vector3 = workspace.animation.sample_track(track.rotation, frame, compiled.frames, Vector3.ZERO, true)
	var pivot := vector_from_array(source.get("rotationOrigin", [0, 0, 0])) / Units.PER_BLOCK
	var start := vector_from_array(source.from) / Units.PER_BLOCK
	var value: Vector3
	if rotating:
		if compiled.version == 1:
			var base: Basis = Basis.from_scale(base_scale) * workspace.animation.rotation_basis(base_rotation)
			value = rotation_degrees(Basis.from_scale(Vector3.ONE / stretch) * base.inverse() * desired.basis, reference)
		else:
			value = rotation_degrees(desired.basis * Basis.from_scale(Vector3.ONE / (base_scale * stretch)), base_rotation + reference) - base_rotation
	elif compiled.version == 1:
		var base: Basis = Basis.from_scale(base_scale) * workspace.animation.rotation_basis(base_rotation)
		value = (base.inverse() * (desired.origin - pivot) - start + pivot) * Units.PER_BLOCK
	else:
		value = (desired.basis.inverse() * (desired.origin - pivot) - start + pivot) * Units.PER_BLOCK
	if workspace.auto_key:
		workspace.editor.set_transform(clip, frame, name, "rotation" if rotating else "offset", value)
	else:
		workspace.hold(name, "rotation" if rotating else "offset", value)
