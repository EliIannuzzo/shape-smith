extends RefCounted
## Keeps the viewport's Node3D tree in step with a ShapeDocument. It listens to
## the document's signals and updates only the elements a signal names: one
## Node3D (with a "Geometry" MeshInstance3D) per element.
##
## Nodes removed by a command are kept detached, so undo re-attaches the same
## node and panels that hold a reference to it keep working.

const Document = preload("res://core/document/shape_document.gd")
const Geometry = preload("res://core/model/shape_geometry.gd")

## Fields that change an element's local transform.
const TRANSFORM_FIELDS := ["from", "rotationOrigin", "rotationX", "rotationY", "rotationZ", "scaleX", "scaleY", "scaleZ"]
## Fields that do not affect the element's own mesh.
const NON_GEOMETRY_FIELDS := ["name", "children", "attachmentpoints", "attachmentPoints", "stepParentName"]

## An element's transform changed, so its rest pose and any dependent preview
## (animation rest poses, bounds, reference models) are stale.
signal transform_changed(node: Node3D)
## A node left the scene because its element was removed.
signal node_detached(node: Node3D)
## A node (with its subtree) entered the scene because its element was added.
signal node_attached(node: Node3D)
## A node changed parent or sibling position.
signal node_moved(node: Node3D)
## Emitted last for every field edit, after the node and mesh are updated.
signal element_updated(node: Node3D, fields: Array)

var document
var root: Node3D
var library
## Callable(source: Dictionary) -> Transform3D for an element at rest.
var rest_transform: Callable
var nodes: Dictionary = {}
var _detached: Dictionary = {}


func bind(target_document, scene_root: Node3D, texture_library, rest: Callable) -> void:
	unbind()
	document = target_document
	root = scene_root
	library = texture_library
	rest_transform = rest
	document.element_changed.connect(_on_changed)
	document.element_added.connect(_on_added)
	document.element_removed.connect(_on_removed)
	document.element_moved.connect(_on_moved)
	document.structure_reset.connect(_rescan)
	_rescan()


func unbind() -> void:
	if document != null:
		for connection in [[document.element_changed, _on_changed], [document.element_added, _on_added],
				[document.element_removed, _on_removed], [document.element_moved, _on_moved], [document.structure_reset, _rescan]]:
			if connection[0].is_connected(connection[1]):
				connection[0].disconnect(connection[1])
	for node in _detached.values():
		if is_instance_valid(node) and node.get_parent() == null:
			node.free()
	_detached.clear()
	nodes.clear()
	document = null
	root = null


func node_for(uid: String) -> Node3D:
	var node: Node3D = nodes.get(uid)
	return node if is_instance_valid(node) else null


## Legacy code changed the scene and data directly: re-tag and re-map nodes.
func _rescan() -> void:
	nodes.clear()
	if not is_instance_valid(root):
		return
	document.bind_nodes(root)
	for node in Geometry.elements(root):
		var uid := Document.uid_of(node)
		if document.has(uid):
			nodes[uid] = node
	for uid in _detached.keys():
		if document.has(uid):
			_detached.erase(uid)


func _on_changed(uid: String, fields: Array) -> void:
	var node := node_for(uid)
	if node == null:
		return
	var source: Dictionary = document.source(uid)
	if fields.has("name"):
		node.name = str(source.get("name", "Element")).validate_node_name()
	var moved := fields.any(func(field): return field in TRANSFORM_FIELDS)
	if moved:
		node.transform = rest_transform.call(source)
	if fields.any(func(field): return field not in NON_GEOMETRY_FIELDS):
		_ensure_geometry(node)
		Geometry.refresh(node, library)
	if moved:
		sync_parity(node)
		transform_changed.emit(node)
	element_updated.emit(node, fields)


func _on_added(uid: String) -> void:
	var node: Node3D = _detached.get(uid)
	_detached.erase(uid)
	if not is_instance_valid(node) or not is_same(node.get_meta("shape_element", null), document.source(uid)):
		node = _build(uid)
	_place(node, uid)
	_register(node)
	sync_parity(node)
	node_attached.emit(node)


func _on_removed(uid: String) -> void:
	var node := node_for(uid)
	if node == null:
		return
	for element in Geometry.elements(node):
		nodes.erase(Document.uid_of(element))
	node.get_parent().remove_child(node)
	_detached[uid] = node
	node_detached.emit(node)


func _on_moved(uid: String, _old_parent: String, _new_parent: String) -> void:
	var node := node_for(uid)
	if node == null:
		return
	_place(node, uid)
	sync_parity(node)
	node_moved.emit(node)


func _build(uid: String) -> Node3D:
	var source: Dictionary = document.source(uid)
	var node := Node3D.new()
	node.name = str(source.get("name", "Element")).validate_node_name()
	node.set_meta("shape_element", source)
	node.set_meta(Document.NODE_META, uid)
	node.transform = rest_transform.call(source)
	if source.get("faces") is Dictionary and not source.faces.is_empty():
		_ensure_geometry(node)
	for child in document.children_of(uid):
		node.add_child(_build(child))
	return node


## Puts a node under its document parent, at its document index among the
## parent's element nodes (helper nodes such as Geometry are skipped).
func _place(node: Node3D, uid: String) -> void:
	var parent_uid: String = document.parent_of(uid)
	var parent: Node3D = root if parent_uid == Document.ROOT else node_for(parent_uid)
	if node.get_parent() != parent:
		if node.get_parent() == null:
			parent.add_child(node)
		else:
			node.reparent(parent, false)
	# From the end, moving to a sibling's index lands just before that sibling.
	parent.move_child(node, -1)
	var siblings: Array[Node] = parent.get_children().filter(func(child): return child != node and child.has_meta("shape_element"))
	var index: int = document.index_of(uid)
	if index < siblings.size():
		parent.move_child(node, siblings[index].get_index())


func _register(node: Node3D) -> void:
	for element in Geometry.elements(node):
		var uid := Document.uid_of(element)
		if document.has(uid):
			nodes[uid] = element


func _ensure_geometry(node: Node3D) -> void:
	if node.get_node_or_null("Geometry") == null:
		var geometry := MeshInstance3D.new()
		geometry.name = "Geometry"
		node.add_child(geometry)
		node.move_child(geometry, 0)


## Rebuilds the meshes of a subtree whose mirroring (negative determinant)
## no longer matches how they were built. Replaces per-frame polling.
func sync_parity(subtree: Node3D) -> void:
	if library == null:
		return
	for element in Geometry.elements(subtree):
		var geometry: MeshInstance3D = element.get_node_or_null("Geometry")
		if geometry == null:
			continue
		if geometry.mesh == null or geometry.get_meta("render_reflected", false) != Geometry.reflected(element):
			Geometry.refresh(element, library)
