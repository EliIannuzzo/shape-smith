extends Node
const Limits = preload("res://core/model/shape_limits.gd")

# Smaller determinants make inverse transforms unstable.
const MIN_TRANSFORM_DETERMINANT := 0.000001

const Units = preload("res://core/model/shape_units.gd")
const Geometry = preload("res://core/model/shape_geometry.gd")
const Document = preload("res://core/document/shape_document.gd")
const AddPoint = preload("res://core/commands/add_attachment_point.gd")
const DeletePoint = preload("res://core/commands/delete_attachment_point.gd")
const SetPointFields = preload("res://core/commands/set_point_fields.gd")
const Composite = preload("res://core/commands/composite_command.gd")
static var Palette = preload("res://ui/theme/editor_palette.tres")

## The selected point changed (-1 for none), for the outliner.
signal point_selected(index: int)

class GizmoView extends RefCounted:
	const Geometry = preload("res://core/model/shape_geometry.gd")
	var viewport
	var selected_node: Node3D
	var camera: Camera3D:
		get: return viewport.camera
	var mouse_default_cursor_shape: int:
		set(value): viewport.mouse_default_cursor_shape = value
		get: return viewport.mouse_default_cursor_shape


	func gizmo_pivot() -> Vector3:
		return selected_node.global_position

var viewport_view
var details_panel
var face_panel
var transform_controller
var edit_history
var editor_mode := "View"
var document

var owner_node: Node3D
var index := -1
var section: VBoxContainer
var list: ItemList
var code: LineEdit
var message: Label
## Moves the selected point to another element, keeping it in place.
var owner_choice: OptionButton
## View → Attachment Point Labels: label every element's points, not only the
## selected element's.
var show_all_labels := true
var owner_nodes: Array = []
var fields: Dictionary = {}
var controls: Array[Button] = []
var pending: Dictionary = {}
var updating := false
var gizmo
var proxy: Node3D
var adapter: GizmoView
var drag_before: Dictionary = {}
var drag_owner: Node3D
var drag_index := -1
var drag_uid := ""


## Where the panel goes (the Attachments tab); the shape inspector without one.
var panel_parent: Control
## The list's rows: every point in the model, [{node, index}].
var list_entries: Array = []
## Asks the app to select an element (a row for another element's point).
signal element_requested(node: Node3D)


func bind(view: Node, details: Control, faces: Control, transforms: Node, history: Node) -> void:
	viewport_view = view
	details_panel = details
	face_panel = faces
	transform_controller = transforms
	edit_history = history


## Called whenever a document opens or a new one starts. The list follows
## the document's point signals, so undo and redo update it too.
func bind_document(target_document) -> void:
	if document != null:
		for connection in [[document.point_added, _on_point_added], [document.point_removed, _on_point_removed], [document.point_changed, _on_point_changed]]:
			if connection[0].is_connected(connection[1]):
				connection[0].disconnect(connection[1])
	document = target_document
	document.point_added.connect(_on_point_added)
	document.point_removed.connect(_on_point_removed)
	document.point_changed.connect(_on_point_changed)


func _owner_uid() -> String:
	return Document.uid_of(owner_node) if is_instance_valid(owner_node) else ""


## A point appearing on the inspected element (added, or restored by undo)
## becomes the selected point.
func _on_point_added(uid: String) -> void:
	if document.point(uid).owner == _owner_uid():
		index = document.point_index(uid)
	refresh()


func _on_point_removed(_uid: String, owner: String) -> void:
	if owner == _owner_uid():
		index = mini(index, points().size() - 1)
	refresh()


func _on_point_changed(_uid: String, _fields: Array) -> void:
	if not gizmo.dragging:
		refresh()


func _ready() -> void:
	process_priority = 55
	proxy = Node3D.new()
	proxy.name = "AttachmentPointPreview"
	proxy.set_meta("shape_element", {"from": [0, 0, 0], "to": [0, 0, 0]})
	viewport_view.models.get_parent().add_child(proxy)
	adapter = GizmoView.new()
	adapter.viewport = viewport_view
	adapter.selected_node = proxy
	var markers = preload("res://ui/viewport/attachment_point_markers.gd").new()
	markers.editor = self
	viewport_view.add_child(markers)
	gizmo = preload("res://ui/viewport/gizmos/transform_gizmo.gd").new()
	gizmo.view = adapter
	gizmo.process_priority = 60
	viewport_view.add_child(gizmo)
	gizmo.drag_started.connect(_begin_drag)
	gizmo.drag_finished.connect(_finish_drag)
	viewport_view.attachment_editor = self
	_build_ui()
	viewport_view.selection_changing.connect(func(): gizmo.finish(true))
	viewport_view.selection_changed.connect(inspect)
	viewport_view.shape_replaced.connect(func(): inspect(null))
	edit_history.flush_pending.connect(finish_pending)


func _build_ui() -> void:
	var panel = preload("res://ui/model/attachment_point_panel.tscn").instantiate()
	(panel_parent if panel_parent != null else details_panel.content).add_child(panel)
	section = panel.get_node("AttachmentPoints")
	# In its own tab the tab names it; the list shows every point in the model.
	section.get_node("Heading").visible = panel_parent == null
	list = section.get_node("List")
	list.custom_minimum_size.y = 160
	list.item_selected.connect(_on_row_selected)
	controls.assign(section.get_node("Actions").get_children())
	controls[0].pressed.connect(add_point)
	controls[1].pressed.connect(duplicate_point)
	controls[2].pressed.connect(delete_point)
	controls[3].pressed.connect(func(): select_point(-1))
	code = section.get_node("Code")
	code.text_submitted.connect(func(_text: String): rename_point(code.text))
	code.focus_exited.connect(_commit_code)
	for group in ["pos", "rotation"]:
		var row = section.get_node(NodePath(group))
		for axis in range(3):
			fields[group + ["X", "Y", "Z"][axis]] = row.inputs[axis]
		row.axis_edited.connect(func(axis: int, value: float):
			if not updating:
				var property: String = group + ["X", "Y", "Z"][axis]
				pending.erase(property)
				set_property(property, value))
		row.pending_edited.connect(func(axis: int, input: SpinBox):
			if not updating:
				pending[group + ["X", "Y", "Z"][axis]] = input)
	message = section.get_node("Message")
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "On element"
	label.theme_type_variation = &"FieldLabel"
	label.custom_minimum_size.x = 64
	row.add_child(label)
	owner_choice = OptionButton.new()
	owner_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	owner_choice.fit_to_longest_item = false
	owner_choice.tooltip_text = "Move the point to another element. It stays where it is in the model."
	owner_choice.item_selected.connect(func(choice: int):
		if not updating and choice >= 0 and choice < owner_nodes.size():
			move_point_to(owner_nodes[choice]))
	row.add_child(owner_choice)
	section.add_child(row)
	section.move_child(row, code.get_index() + 1)
	refresh()


func points(node: Node3D = null) -> Array:
	if node == null:
		node = owner_node
	if not is_instance_valid(node) or not node.has_meta("shape_element"):
		return []

	var source: Dictionary = node.get_meta("shape_element")
	var value: Variant = source.get(_points_key(source), [])
	return value if value is Array else []


func _points_key(source: Dictionary) -> String:
	return "attachmentpoints" if source.has("attachmentpoints") and not source.has("attachmentPoints") else "attachmentPoints"


func valid_selection() -> bool:
	return is_instance_valid(owner_node) and index >= 0 and index < points().size() and points()[index] is Dictionary


func editing() -> bool:
	return editor_mode == "Model" and valid_selection()


func inspect(node: Node3D) -> void:
	if node != owner_node:
		finish_pending()
		gizmo.finish(true)
		index = -1
	owner_node = node
	refresh()


## A row of the list: its point may be on another element, which is selected first.
func _on_row_selected(row: int) -> void:
	if row < 0 or row >= list_entries.size():
		return
	var entry: Dictionary = list_entries[row]
	if entry.node != owner_node:
		element_requested.emit(entry.node)
		if entry.node != owner_node:
			inspect(entry.node)
	select_point(entry.index)


func select_point(value: int) -> void:
	finish_pending()
	viewport_view.gizmo.finish(true)
	index = value if value >= 0 and value < points().size() else -1
	message.text = ""
	refresh()
	point_selected.emit(index)


func refresh() -> void:
	updating = true
	pending.clear()
	list.clear()
	list_entries.clear()
	var valid := valid_selection()
	if is_instance_valid(viewport_view.models):
		for node in Geometry.elements(viewport_view.models):
			var element_points := points(node)
			for i in range(element_points.size()):
				var point: Variant = element_points[i]
				var row := list.add_item("%s   ·   %s" % [str(point.get("code", "Unnamed")) if point is Dictionary else "Invalid point", str(node.get_meta("shape_element").get("name", "Unnamed"))])
				list.set_item_tooltip(row, "%s on %s" % [list.get_item_text(row).get_slice("   ·   ", 0), node.get_meta("shape_element").get("name", "Unnamed")])
				list.set_item_custom_bg_color(row, Palette.surface if row % 2 == 0 else Palette.chrome)
				list_entries.append({"node": node, "index": i})
				if valid and node == owner_node and i == index:
					list.select(row)
	const EMPTY_NOTE := "No attachment points yet. Select a shape and press + to add one."
	if list_entries.is_empty() and message.text.is_empty():
		message.text = EMPTY_NOTE
	elif not list_entries.is_empty() and message.text == EMPTY_NOTE:
		message.text = ""
	code.editable = valid
	code.text = str(points()[index].get("code", "")) if valid else ""
	for property in fields:
		fields[property].editable = valid
		fields[property].set_value_no_signal(float(points()[index].get(property, 0)) if valid else 0)
	owner_choice.clear()
	owner_nodes.clear()
	if valid:
		for node in Geometry.elements(viewport_view.models):
			owner_nodes.append(node)
			owner_choice.add_item(str(node.get_meta("shape_element").get("name", "Unnamed")))
			if node == owner_node:
				owner_choice.select(owner_choice.item_count - 1)
	owner_choice.disabled = not valid or not _can_edit()
	controls[0].disabled = not is_instance_valid(owner_node)
	for i in range(1, controls.size()):
		controls[i].disabled = not valid
	updating = false
	_sync_proxy()


func _selected_uid() -> String:
	return document.point_at(_owner_uid(), index) if document != null and valid_selection() else ""


func _can_edit() -> bool:
	return is_instance_valid(owner_node) and editor_mode == "Model" and document != null and document.has(_owner_uid())


func _code_exists(value: String, except_index := -1) -> bool:
	for node in Geometry.elements(viewport_view.models):
		for i in range(points(node).size()):
			if node == owner_node and i == except_index:
				continue

			var point: Variant = points(node)[i]
			if point is Dictionary and str(point.get("code", "")).to_lower() == value.to_lower():
				return true

	return false


func _unique_code(base: String) -> String:
	var value := base
	var suffix := 2
	while _code_exists(value):
		value = base + str(suffix)
		suffix += 1
	return value


func add_point() -> void:
	finish_pending()
	if not is_instance_valid(owner_node):
		return

	if not _can_edit():
		return
	var point := {"code": _unique_code("Attachment"), "posX": 0, "posY": 0, "posZ": 0, "rotationX": 0, "rotationY": 0, "rotationZ": 0}
	edit_history.execute(AddPoint.new(document, _owner_uid(), point))


func duplicate_point() -> void:
	finish_pending()
	if not valid_selection():
		return

	if not _can_edit():
		return
	var point: Dictionary = points()[index].duplicate(true)
	point.code = _unique_code(str(point.get("code", "Attachment")))
	edit_history.execute(AddPoint.new(document, _owner_uid(), point, "Duplicate Attachment Point"))


func delete_point() -> void:
	finish_pending()
	if not valid_selection():
		return

	if not _can_edit() or _selected_uid().is_empty():
		return
	edit_history.execute(DeletePoint.new(document, _selected_uid()))


func _commit_code() -> void:
	if not updating and valid_selection() and code.text != str(points()[index].get("code", "")):
		rename_point(code.text)


func rename_point(value: String) -> bool:
	if not valid_selection():
		return false

	value = value.strip_edges()
	if value.is_empty() or _code_exists(value, index):
		message.text = "Attachment codes must be nonempty and unique across the model."
		return false

	if value == str(points()[index].get("code", "")):
		return true

	if not _can_edit() or _selected_uid().is_empty():
		return false
	message.text = ""
	return edit_history.execute(SetPointFields.new(document, _selected_uid(), {"code": value}, "Rename Attachment Point"))


## Moves the selected point onto `target`, keeping its place and direction in
## the model, as one undo step. The point keeps its code and identity.
func move_point_to(target: Node3D) -> bool:
	if not valid_selection() or not is_instance_valid(target) or target == owner_node or not _can_edit() or not document.has(Document.uid_of(target)):
		return false
	if absf(target.global_basis.determinant()) < MIN_TRANSFORM_DETERMINANT:
		message.text = "That element is scaled flat, so the point cannot keep its place on it."
		return false
	finish_pending()
	var point: Dictionary = points()[index].duplicate(true)
	var local := target.global_transform.affine_inverse() * point_transform(owner_node, point)
	var angles: Vector3 = transform_controller.rotation_degrees(local.basis.orthonormalized(), Vector3(point.get("rotationX", 0), point.get("rotationY", 0), point.get("rotationZ", 0)))
	for axis in range(3):
		point["pos" + ["X", "Y", "Z"][axis]] = snappedf(local.origin[axis] * Units.PER_BLOCK, 0.0001)
		point["rotation" + ["X", "Y", "Z"][axis]] = snappedf(angles[axis], 0.0001)
	var uid := _selected_uid()
	var add := AddPoint.new(document, Document.uid_of(target), point, "Move Attachment Point")
	add.uid = uid
	if not edit_history.execute(Composite.new(document, [DeletePoint.new(document, uid), add], "Move Attachment Point")):
		return false
	# Select the new owner the way a click does, then the moved point.
	viewport_view.element_picked.emit(target, "")
	select_point(points(target).size() - 1)
	return true


func set_property(property: String, value: float) -> bool:
	if not valid_selection() or not fields.has(property) or not is_finite(value) or absf(value) > Limits.MAX_COORDINATE:
		return false

	if float(points()[index].get(property, 0)) == value:
		return true

	if not _can_edit() or _selected_uid().is_empty():
		return false
	var uid := _selected_uid()
	return edit_history.execute(SetPointFields.new(document, uid, {property: value}, "Edit Attachment Point", "%s:%s" % [uid, property]))


func finish_pending() -> void:
	gizmo.finish()
	_commit_code()
	var inputs := pending.values()
	pending.clear()
	for input in inputs:
		input.apply()


func point_transform(node: Node3D, point: Dictionary) -> Transform3D:
	var position := Vector3(point.get("posX", 0), point.get("posY", 0), point.get("posZ", 0)) / Units.PER_BLOCK
	var angles := Vector3(point.get("rotationX", 0), point.get("rotationY", 0), point.get("rotationZ", 0))
	var rotation := Basis(Vector3.RIGHT, deg_to_rad(angles.x)) * Basis(Vector3.UP, deg_to_rad(angles.y)) * Basis(Vector3.BACK, deg_to_rad(angles.z))
	return node.global_transform * Transform3D(rotation, position)


func _sync_proxy() -> void:
	if valid_selection() and not gizmo.dragging:
		proxy.global_transform = point_transform(owner_node, points()[index])
	proxy.visible = valid_selection() and owner_node.is_visible_in_tree()


func _process(_delta: float) -> void:
	if gizmo.dragging and not editing():
		gizmo.finish(true)
	_sync_proxy()
	gizmo.enabled = editing() and absf(owner_node.global_basis.determinant()) > MIN_TRANSFORM_DETERMINANT
	gizmo.local_space = viewport_view.gizmo.local_space
	gizmo.snap_enabled = viewport_view.gizmo.snap_enabled
	gizmo.translation_step = viewport_view.gizmo.translation_step
	gizmo.rotation_step = viewport_view.gizmo.rotation_step
	if gizmo.dragging:
		var values := _drag_values()
		for property in fields:
			fields[property].set_value_no_signal(values.get(property, 0))


## Screen markers: {node, index, code, position, owner (the element's centre
## on screen), active (on the selected element)}.
func marker_entries() -> Array:
	var entries: Array = []
	if editor_mode not in ["Model", "Animation"]:
		return entries
	var nodes: Array = Geometry.elements(viewport_view.models) if show_all_labels else ([owner_node] if is_instance_valid(owner_node) else [])
	var camera: Camera3D = viewport_view.camera
	for node in nodes:
		if not node.is_visible_in_tree() or points(node).is_empty():
			continue
		var centre: Vector3 = node.global_transform * (Geometry.size_of(node.get_meta("shape_element")) / 2.0)
		for i in range(points(node).size()):
			if not points(node)[i] is Dictionary:
				continue
			var world := point_transform(node, points(node)[i]).origin
			if node == owner_node and i == index and gizmo.dragging:
				world = proxy.global_position
			if camera.is_position_behind(world):
				continue
			entries.append({"node": node, "index": i, "code": str(points(node)[i].get("code", "")), "position": camera.unproject_position(world),
				"owner": camera.unproject_position(centre) if not camera.is_position_behind(centre) else camera.unproject_position(world), "active": node == owner_node})
	return entries


func begin_at(position: Vector2) -> bool:
	if editor_mode != "Model":
		return false

	if gizmo.begin(position):
		return true

	# Points on the selected element first, so overlapping markers pick those.
	var entries := marker_entries()
	entries.sort_custom(func(a, b): return a.active and not b.active)
	for entry in entries:
		if entry.position.distance_to(position) <= 9:
			if entry.node != owner_node:
				viewport_view.element_picked.emit(entry.node, "")
			select_point(entry.index)
			return true

	return false


func _begin_drag() -> void:
	_commit_code()
	details_panel.finish_pending()
	face_panel.finish_pending()
	drag_before = {"value": points().duplicate(true)}
	drag_owner = owner_node
	drag_index = index
	drag_uid = _selected_uid()
	edit_history.break_merge()


func _drag_values() -> Dictionary:
	var local := drag_owner.global_transform.affine_inverse() * proxy.global_transform
	var value: Dictionary = drag_before.value[drag_index].duplicate(true)
	var reference := Vector3(value.get("rotationX", 0), value.get("rotationY", 0), value.get("rotationZ", 0))
	var angles: Vector3 = transform_controller.rotation_degrees(local.basis, reference)
	for axis in range(3):
		if gizmo.active < 3:
			value["pos" + ["X", "Y", "Z"][axis]] = local.origin[axis] * Units.PER_BLOCK
		else:
			value["rotation" + ["X", "Y", "Z"][axis]] = angles[axis]
	return value


func _finish_drag(cancelled: bool) -> void:
	if not cancelled and is_instance_valid(drag_owner) and document != null and document.point(drag_uid) != null:
		var before: Dictionary = drag_before.value[drag_index]
		var after := _drag_values()
		var fields := {}
		for key in after:
			if not before.has(key) or before[key] != after[key]:
				fields[key] = after[key]
		if not fields.is_empty():
			edit_history.execute(SetPointFields.new(document, drag_uid, fields, "Transform Attachment Point"))
	drag_owner = null
	drag_uid = ""
	refresh()
