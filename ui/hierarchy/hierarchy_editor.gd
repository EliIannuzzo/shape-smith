extends Node
## Structural hierarchy edits (add, reparent) as document commands. SceneSync
## turns the commands into scene changes; main.gd refreshes the panels.

const ORTHOGONALITY_TOLERANCE := 0.0001
# Smaller determinants make inverse transforms unstable.
const MIN_TRANSFORM_DETERMINANT := 0.000001

const Geometry = preload("res://core/model/shape_geometry.gd")
const Document = preload("res://core/document/shape_document.gd")
const AddElements = preload("res://core/commands/add_elements.gd")
const MoveElements = preload("res://core/commands/move_elements.gd")
const SetFields = preload("res://core/commands/set_element_fields.gd")
const Composite = preload("res://core/commands/composite_command.gd")
const DeleteElements = preload("res://core/commands/delete_elements.gd")
const RemoveTracks = preload("res://core/commands/remove_tracks.gd")
signal new_document_requested
signal element_selection_requested(element: Node3D)
signal status_message(text: String)
var viewport_view
var edit_history
var hierarchy_browser
var animation_workspace
var transform_controller
var document
var scene_sync
var selection
## The texture ID last assigned to a face; new cubes use it.
var last_texture := ""


func bind(view: Node, history: Node, browser: Control, playback: Control, transforms: Node) -> void:
	viewport_view = view
	edit_history = history
	hierarchy_browser = browser
	animation_workspace = playback
	transform_controller = transforms


## Called whenever a document opens or a new one starts.
func bind_document(target_document, sync, current_selection = null) -> void:
	document = target_document
	scene_sync = sync
	selection = current_selection


func root_node() -> Node3D:
	return viewport_view.models.get_child(0) if viewport_view.models.get_child_count() > 0 else null


## Adds a 4×4×4 cube under the selected element, or at the root.
func add_shape() -> bool:
	if root_node() == null:
		new_document_requested.emit()
	return add_element(cube_source(unique_name("Cube"), 4), "Add Shape")


## Adds an element under the selected element (or the given parent uid) and
## selects it. Starts a new document if none is open.
func add_element(source: Dictionary, label: String, parent := "<selected>", index := -1) -> bool:
	if root_node() == null:
		new_document_requested.emit()
	edit_history.flush_pending.emit()
	if parent == "<selected>":
		parent = Document.uid_of(viewport_view.selected_node)
	if not document.has(parent):
		parent = Document.ROOT
	var command = AddElements.new(document, [{"parent": parent, "index": index, "source": source}], label)
	if not edit_history.execute(command):
		return false
	element_selection_requested.emit(scene_sync.node_for(command.added()[0]))
	return true


## "Cube", or "Cube 2" and so on when the name is taken (case-insensitive).
func unique_name(base: String) -> String:
	var names: Array = document.ordered().map(func(uid: String): return document.element(uid).name().to_lower())
	var name_value := base
	var suffix := 2
	while name_value.to_lower() in names:
		name_value = "%s %d" % [base, suffix]
		suffix += 1
	return name_value


## A cube with the given edge length (in shape units) using the texture you
## last assigned to a face, or else the first texture ID, on every face.
func cube_source(name_value: String, edge := 16) -> Dictionary:
	var faces: Dictionary = {}
	var ids: Array = viewport_view.texture_library.ids()
	var texture := last_texture if ids.has(last_texture) else (str(ids[0]) if not ids.is_empty() else "")
	for face in Geometry.FACES:
		faces[face] = {"texture": "#" + texture, "uv": [0, 0, edge, edge]}
	var half := edge / 2.0
	return {"name": name_value, "from": [0, 0, 0], "to": [edge, edge, edge], "rotationOrigin": [half, half, half], "faces": faces}


## Moves an element under another (null for the root), keeping its world
## placement (or its local values with keep_world false, Alt in the outliner).
## When the element is part of a multi-selection, moves every selected element
## whose ancestors are not also selected, as one undo step. index places the
## elements among the target's children (-1 appends). Refused when any result
## would need shear.
func reparent_shape(element: Node3D, target: Node3D, index := -1, keep_world := true) -> bool:
	edit_history.flush_pending.emit()
	if target == null:
		target = root_node()
	if not is_instance_valid(element) or not is_instance_valid(target):
		return false

	var elements := _moving_set(element)
	var steps: Array = []
	var offset := 0
	for node in elements:
		if node == target or node.is_ancestor_of(target):
			return false
		if node.get_parent() == target and index < 0:
			continue
		var at := index
		if index >= 0:
			at = index + offset
			# Moving down within the same parent: the element's old slot closes.
			if node.get_parent() == target and document.index_of(Document.uid_of(node)) < index:
				at -= 1
			offset += 1
		var moved := _reparent_steps(node, target, at, keep_world)
		if moved.is_empty():
			return false
		steps.append_array(moved)
	if steps.is_empty():
		return false
	var count := elements.size()
	if not edit_history.execute(Composite.new(document, steps, "Move Shapes" if count > 1 else ("Reorder Shape" if element.get_parent() == target else "Reparent Shape"))):
		return false
	element_selection_requested.emit(element)
	return true


## A drop in the outliner: zone -1 above the target row, 0 onto it, 1 below it.
func move_relative(element: Node3D, target: Node3D, zone: int, keep_world := true) -> bool:
	if zone == 0 or target == null:
		return reparent_shape(element, target, -1, keep_world)
	var parent: Node3D = target.get_parent()
	var index: int = document.index_of(Document.uid_of(target)) + (1 if zone > 0 else 0)
	return reparent_shape(element, parent if parent != root_node() else null, index, keep_world)


## The selected elements to act on with this one: every selected element
## without a selected ancestor, in file order; or just this one.
func _moving_set(element: Node3D) -> Array[Node3D]:
	var result: Array[Node3D] = [element]
	var uid := Document.uid_of(element)
	if selection != null and selection.items.size() > 1 and selection.has(uid):
		result.clear()
		for item in document.ordered():
			if selection.has(item) and not selection.items.any(func(other: String): return other != item and document.is_ancestor(other, item)):
				var node: Node3D = scene_sync.node_for(item)
				if node != null:
					result.append(node)
	return result


## Element fields that keep `element` where it is in the world when its parent
## becomes `frame` (or any element whose local frame equals `frame`'s). {} when
## the result would need shear or the transforms are degenerate.
func world_fields(element: Node3D, frame: Node3D) -> Dictionary:
	return fields_for(element.get_meta("shape_element"), element.global_transform, element.get_parent().global_transform, frame.global_transform)


## The same, from transforms: an element (source) now at world transform
## `world` under a parent at `old_parent`, re-expressed under a parent at
## `frame`. Works for elements that are not in the scene yet (imports).
func fields_for(source: Dictionary, world: Transform3D, old_parent: Transform3D, frame: Transform3D) -> Dictionary:
	if absf(frame.basis.determinant()) < MIN_TRANSFORM_DETERMINANT:
		return {}
	var desired := frame.affine_inverse() * world
	if absf(desired.basis.determinant()) < MIN_TRANSFORM_DETERMINANT:
		return {}

	var scale_value := desired.basis.get_scale()
	var rotation := desired.basis * Basis.from_scale(Vector3.ONE / scale_value)
	var has_shear := (
		absf(rotation.x.dot(rotation.y)) > ORTHOGONALITY_TOLERANCE
		or absf(rotation.x.dot(rotation.z)) > ORTHOGONALITY_TOLERANCE
		or absf(rotation.y.dot(rotation.z)) > ORTHOGONALITY_TOLERANCE
	)
	if has_shear:
		status_message.emit("Cannot preserve this shape under that scaled parent: the transform would require shear.")
		return {}

	var after: Dictionary = {}
	var pivot: Vector3 = frame.affine_inverse() * (old_parent * (transform_controller.vector_from_array(source.get("rotationOrigin", [0, 0, 0])) / 16))
	var start := pivot + desired.basis.inverse() * (desired.origin - pivot)
	var size := Geometry.size_of(source)
	after.from = transform_controller.vector_to_array(start * 16)
	after.to = transform_controller.vector_to_array((start + size) * 16)
	after.rotationOrigin = transform_controller.vector_to_array(pivot * 16)
	var angles := rotation.get_euler(EULER_ORDER_XYZ) * 180 / PI
	for axis in range(3):
		var suffix: String = ["X", "Y", "Z"][axis]
		for group in ["rotation", "scale"]:
			var value: float = angles[axis] if group == "rotation" else scale_value[axis]
			if source.has(group + suffix) or not is_equal_approx(value, 0 if group == "rotation" else 1):
				after[group + suffix] = value
	return after


func _reparent_steps(element: Node3D, target: Node3D, index := -1, keep_world := true) -> Array:
	var uid := Document.uid_of(element)
	var target_uid := Document.ROOT if target == root_node() else Document.uid_of(target)
	if not document.has(uid) or (target_uid != Document.ROOT and not document.has(target_uid)):
		return []
	var move = MoveElements.new(document, [{"uid": uid, "parent": target_uid, "index": index}])
	if not keep_world or element.get_parent() == target:
		return [move]
	var after := world_fields(element, target)
	if after.is_empty():
		return []
	return [move, SetFields.new(document, uid, after)]


## Ctrl+G: puts the selected elements into a new empty "Group" element, in
## place of the first of them, keeping their world placement. One undo step.
func group_elements(element: Node3D) -> bool:
	edit_history.flush_pending.emit()
	var nodes := _moving_set(element)
	if nodes.is_empty():
		return false
	var parent_node: Node3D = nodes[0].get_parent()
	var parent_uid := Document.ROOT if parent_node == root_node() else Document.uid_of(parent_node)
	var group_uid: String = document.new_uid()
	var steps: Array = [AddElements.new(document, [{"parent": parent_uid, "index": document.index_of(Document.uid_of(nodes[0])),
		"source": {"name": unique_name("Group"), "from": [0, 0, 0], "to": [0, 0, 0]}, "uid": group_uid}])]
	for i in range(nodes.size()):
		var uid := Document.uid_of(nodes[i])
		steps.append(MoveElements.new(document, [{"uid": uid, "parent": group_uid, "index": i}]))
		# The group sits at its parent's origin, so only elements from other
		# parents need new fields to stay in place.
		if nodes[i].get_parent() != parent_node:
			var after := world_fields(nodes[i], parent_node)
			if after.is_empty():
				return false
			steps.append(SetFields.new(document, uid, after))
	if not edit_history.execute(Composite.new(document, steps, "Group Shapes")):
		return false
	element_selection_requested.emit(scene_sync.node_for(group_uid))
	return true


## Ungroup, or Delete Keeping Children: moves the element's children up to
## its parent, after it and keeping their world placement, then deletes the
## element and its own animation track. One undo step.
func lift_children(element: Node3D, label := "Ungroup") -> bool:
	edit_history.flush_pending.emit()
	var uid := Document.uid_of(element)
	if not document.has(uid):
		return false
	var parent_node: Node3D = element.get_parent()
	var parent_uid := Document.ROOT if parent_node == root_node() else Document.uid_of(parent_node)
	var index: int = document.index_of(uid) + 1
	var steps: Array = []
	var children: Array[String] = document.children_of(uid).duplicate()
	for i in range(children.size()):
		var child: Node3D = scene_sync.node_for(children[i])
		steps.append(MoveElements.new(document, [{"uid": children[i], "parent": parent_uid, "index": index + i}]))
		var after := world_fields(child, parent_node)
		if after.is_empty():
			return false
		steps.append(SetFields.new(document, children[i], after))
	steps.append(RemoveTracks.new(document, [document.element(uid).name()]))
	steps.append(DeleteElements.new(document, [uid]))
	var first: Node3D = scene_sync.node_for(children[0]) if not children.is_empty() else null
	if not edit_history.execute(Composite.new(document, steps, label)):
		return false
	element_selection_requested.emit(first)
	return true


## Adds a new 4×4×4 cube inside the element (Add Child) or next to it (Add
## Sibling), using the last texture you assigned.
func add_relative(element: Node3D, as_child: bool) -> bool:
	var uid := Document.uid_of(element)
	if not document.has(uid):
		return add_element(cube_source(unique_name("Cube"), 4), "Add Shape", Document.ROOT)
	if as_child:
		return add_element(cube_source(unique_name("Cube"), 4), "Add Child", uid)
	var parent: String = document.parent_of(uid)
	return add_element(cube_source(unique_name("Cube"), 4), "Add Sibling", parent, document.index_of(uid) + 1)


## Shift+A in the viewport: a 4×4×4 cube on the face under the pointer (as a
## child of that element, sitting on the face), or at the view's centre.
func add_at(picked: Dictionary, view_target: Vector3) -> bool:
	var node: Node3D = picked.get("node")
	if node != null and document.has(Document.uid_of(node)):
		var source: Dictionary = node.get_meta("shape_element")
		var index := Geometry.FACES.find(picked.face)
		var corners: Array = Geometry.corners(Geometry.size_of(source))[index]
		var centre := Vector3.ZERO
		for corner in corners:
			centre += corner / 4.0
		centre *= 16.0
		var normal: Vector3 = Geometry.NORMALS[index]
		var start := centre - Vector3(2, 2, 2) + normal * 2.0
		var cube := cube_source(unique_name("Cube"), 4)
		cube.from = [start.x, start.y, start.z]
		cube.to = [start.x + 4, start.y + 4, start.z + 4]
		cube.rotationOrigin = [start.x + 2, start.y + 2, start.z + 2]
		return add_element(cube, "Add Shape", Document.uid_of(node))
	var root := root_node()
	if root == null:
		new_document_requested.emit()
		root = root_node()
	var local := root.global_transform.affine_inverse() * view_target * 16.0
	var placed := cube_source(unique_name("Cube"), 4)
	var corner := (local - Vector3(2, 2, 2)).round()
	placed.from = [corner.x, corner.y, corner.z]
	placed.to = [corner.x + 4, corner.y + 4, corner.z + 4]
	placed.rotationOrigin = [corner.x + 2, corner.y + 2, corner.z + 2]
	return add_element(placed, "Add Shape", Document.ROOT)


## Rebuilds the panels that list elements (hierarchy and timeline), keeping
## the selected clip, frame and fold states. Pass rebuild_meshes only when
## meshes may be stale; SceneSync keeps them current for command edits.
func refresh_structure(selection: Node3D, rebuild_meshes := true) -> void:
	var workspace = animation_workspace
	var clip: int = workspace.selected
	var frame: float = workspace.frame
	var collapsed: Dictionary = hierarchy_browser.fold_states.duplicate()
	workspace.bind_shape()
	if clip >= 0 and clip < workspace.animation.clips.size():
		workspace.select_animation(clip)
		workspace.seek(frame)
	hierarchy_browser.bind_shape(root_node())
	if rebuild_meshes:
		viewport_view.refresh_textures()
	viewport_view.update_model_bounds()
	element_selection_requested.emit(selection)
	for element in collapsed:
		if is_instance_valid(element) and element.is_inside_tree():
			var folded: bool = collapsed[element]
			workspace.tracks.set_collapsed(element, folded)
			hierarchy_browser.set_collapsed(element, folded)
