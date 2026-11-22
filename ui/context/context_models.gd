extends Node
## Additional shapes (VSMC2's shape manager): other shape files shown with the
## one being edited, one entry per root element, kept in `editor.additionalShapes`.
##
## Every root, the edited shape's included, has an origin (see ShapeOrigins):
## a plain transform, an element to follow, or an attachment point. Placement
## is solved every frame in dependency order, so a rider on a seat follows the
## animated mount. An additional shape plays the clip with the main clip's code,
## or the clip its own mapping names.

const Loader = preload("res://core/model/shape_loader.gd")
const Library = preload("res://core/textures/texture_library.gd")
const Geometry = preload("res://core/model/shape_geometry.gd")
const Origins = preload("res://core/model/shape_origins.gd")
const ShapeAnimation = preload("res://core/animation/shape_animation.gd")
const AssetPaths = preload("res://core/textures/asset_paths.gd")
const Document = preload("res://core/document/shape_document.gd")
const SetFields = preload("res://core/commands/set_element_fields.gd")
const COLORS := [Color("96a6bf"), Color("df7373"), Color("76b88a"), Color("7ba5dc"), Color("d8bb76"), Color("ae8acb")]
const CURRENT := Origins.CURRENT_SHAPE

signal refreshed

var document
var viewport_view
var asset_settings
var edit_history
var document_path: Callable

var stage: Node3D
## One record per additional shape entry that loaded: {index, key, entry, path,
## holder, element, elements, library, animation, codes, playing}.
var loaded: Array = []
var issues: PackedStringArray = []
## Main roots moved by their origin: node -> {pose, output}.
var main_poses: Dictionary = {}
var selected_key := ""
var syncing := false
var source_path := ""
## The main shape's playing clip code and frame ("" at rest).
var main_clip := ""
var main_frame := 0.0
## Roots whose origins form a loop; they stay where their own file puts them.
var cyclic: Array = []
## Set by Open in Context; applied when that file loads.
var pending_context: Dictionary = {}


func bind(view: Node, assets: RefCounted, history: Node, get_path: Callable) -> void:
	viewport_view = view
	asset_settings = assets
	edit_history = history
	document_path = get_path


func _ready() -> void:
	process_priority = 50
	stage = Node3D.new()
	stage.name = "ContextModels"
	viewport_view.models.get_parent().add_child(stage)
	asset_settings.changed.connect(rebuild)
	viewport_view.shape_replaced.connect(clear_references)
	viewport_view.selection_changing.connect(func():
		if not viewport_view.gizmo.dragging:
			clear_main_corrections())


# --- Loading and saving ------------------------------------------------------------

## Called with a freshly loaded file, before the document is built: root
## origins move onto their elements, older reference lists become additional
## shapes, and a pending Open in Context is applied. Returns true when the
## data changed in a way the user should save.
func prepare(data: Dictionary, path: String) -> bool:
	Origins.distribute(data)
	var changed := false
	var converted: Dictionary = Origins.convert_legacy(data, func(reference: String) -> Variant: return _root_names(reference, path))
	for missing in converted.missing:
		issues.append("Cannot find shape: " + str(missing))
	if not pending_context.is_empty() and AssetPaths.normalize(pending_context.path).to_lower() == AssetPaths.normalize(path).to_lower():
		_apply_context(data, path)
		changed = true
	pending_context.clear()
	return changed


func _root_names(reference: String, from_path: String) -> Variant:
	var path: String = asset_settings.resolve_shape(reference, from_path)
	if path.is_empty():
		return null
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary or not data.get("elements") is Array:
		return null
	var names: Array = []
	for element in data.elements:
		if element is Dictionary:
			names.append(str(element.get("name", "")))
	return names


func data_for_save(data: Dictionary, destination: String) -> Dictionary:
	data = Origins.with_origins_saved(data)
	var editor: Variant = data.get("editor")
	if not editor is Dictionary:
		return data
	var renames := {}
	for container in [data, editor]:
		if container.get("backDropShape") is String:
			container.backDropShape = _portable(container.backDropShape, destination, renames)
	for kind_name in ["additionalShapes", "backdrops", "attachments"]:
		for entry in editor.get(kind_name) if editor.get(kind_name) is Array else []:
			if entry is Dictionary and entry.get("shapeFilepath") is String:
				entry.shapeFilepath = _portable(entry.shapeFilepath, destination, renames)
	# Origins name shapes by the same paths: keep them pointing at the same files.
	var origins: Array = []
	for entry in editor.get("additionalShapes") if editor.get("additionalShapes") is Array else []:
		if entry is Dictionary:
			origins.append(entry.get("origin"))
	origins.append_array(editor.get("rootElementOrigins") if editor.get("rootElementOrigins") is Array else [])
	for origin in origins:
		if origin is Dictionary and origin.get("rootElement") is Dictionary and renames.has(origin.rootElement.get("shapePath")):
			origin.rootElement.shapePath = renames[origin.rootElement.shapePath]
	return data


## A reference that still finds the same file from `destination`. References
## that already do are kept exactly, so a VSMC2 file saves back unchanged.
func _portable(reference: String, destination: String, renames: Dictionary) -> String:
	var current: String = asset_settings.resolve_shape(reference, source_path)
	if current.is_empty() or AssetPaths.normalize(asset_settings.resolve_shape(reference, destination)).to_lower() == AssetPaths.normalize(current).to_lower():
		return reference
	var result: String = asset_settings.shape_reference(current, destination)
	renames[reference] = result
	return result


# --- Settings ----------------------------------------------------------------------

func settings() -> Dictionary:
	var value: Variant = viewport_view.shape_data.get("editor", {})
	var result: Dictionary = value.duplicate(true) if value is Dictionary else {}
	if not result.get("additionalShapes") is Array:
		result.additionalShapes = []
	return result


func entries() -> Array:
	return settings().additionalShapes


func commit_settings(value: Dictionary, label: String) -> void:
	edit_history.flush_pending.emit()
	if value.get("additionalShapes") is Array and value.additionalShapes.is_empty() and not _editor().has("additionalShapes"):
		value.erase("additionalShapes")
	var data: Dictionary = viewport_view.shape_data
	var exists := data.has("editor")
	var before: Variant = data.get("editor")
	before = before.duplicate(true) if before is Dictionary else before
	edit_history.perform(label, _apply_settings.bind(value, true), _apply_settings.bind(before, exists))


func _editor() -> Dictionary:
	var value: Variant = viewport_view.shape_data.get("editor")
	return value if value is Dictionary else {}


func _apply_settings(value: Variant, exists: bool) -> void:
	if exists:
		viewport_view.shape_data.editor = value.duplicate(true) if value is Dictionary else value
	else:
		viewport_view.shape_data.erase("editor")
	if not _update_in_place():
		rebuild()


## When the same shapes are listed, only display, origin and clip settings
## changed: apply them without reloading files.
func _update_in_place() -> bool:
	var value := entries()
	if loaded.is_empty() or not issues.is_empty():
		return false
	var count := 0
	for i in range(value.size()):
		var record := record_for(i)
		var entry: Variant = value[i]
		if record.is_empty() or not entry is Dictionary or entry.get("shapeFilepath") != record.entry.get("shapeFilepath") \
				or entry.get("rootShapeElementCode") != record.entry.get("rootShapeElementCode"):
			return false
		count += 1
	if count != loaded.size():
		return false
	for record in loaded:
		record.entry = value[record.index]
		record.holder.visible = record.entry.get("enabled", false) == true
		record.playing = "?"
		_style(record)
	sync()
	refreshed.emit()
	return true


## Adds every root element of a shape file as an additional shape.
func add_model(path: String) -> String:
	if document_path.call().is_empty():
		return "Load or save a main shape first."
	if AssetPaths.normalize(path).to_lower() == AssetPaths.normalize(document_path.call()).to_lower():
		return "The current shape cannot reference itself."

	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary or not data.get("elements") is Array or data.elements.is_empty():
		return "That file has no elements to show."

	var reference: String = asset_settings.shape_reference(path, source_path)
	if AssetPaths.normalize(asset_settings.resolve_shape(reference, source_path)).to_lower() != AssetPaths.normalize(path).to_lower():
		reference = Library.relative_file(AssetPaths.normalize(source_path).get_base_dir(), AssetPaths.normalize(path)).get_basename()
	var value := settings()
	for entry in value.additionalShapes:
		if entry is Dictionary and str(entry.get("shapeFilepath", "")).to_lower() == reference.to_lower():
			return "That shape is already shown."

	for element in data.elements:
		if element is Dictionary:
			value.additionalShapes.append({"shapeFilepath": reference, "rootShapeElementCode": str(element.get("name", "")), "enabled": true})
	commit_settings(value, "Add Shape")
	frame_all()
	return ""


## Changes one field of an additional shape ("remove" removes the entry).
func change(index: int, field: String, value: Variant) -> void:
	var data := settings()
	if index < 0 or index >= data.additionalShapes.size() or not data.additionalShapes[index] is Dictionary:
		return
	if field == "remove":
		data.additionalShapes.remove_at(index)
	elif value == null:
		data.additionalShapes[index].erase(field)
	else:
		data.additionalShapes[index][field] = value
	commit_settings(data, "Remove Shape" if field == "remove" else "Change Shape")


## Removes every entry from one file.
func remove_file(shape_path: String) -> void:
	var data := settings()
	data.additionalShapes = data.additionalShapes.filter(func(entry): return not (entry is Dictionary and str(entry.get("shapeFilepath", "")) == shape_path))
	commit_settings(data, "Remove Shape")


# --- Origins -----------------------------------------------------------------------

## The roots that can carry an origin: the edited shape's roots, then every
## additional shape. Each is {key, label, shape, name, node, origin, index}.
## Without `include_unloaded`, only shapes that loaded (cheap, for every frame).
func roots(include_unloaded := true) -> Array:
	var result: Array = []
	if viewport_view.models.get_child_count() > 0:
		for node in viewport_view.models.get_child(0).get_children():
			# IK controllers are editor-only helpers, not parts of the shape.
			if node.has_meta("shape_element") and node.get_meta("shape_element").get("shapesmithController", false) != true:
				var source: Dictionary = node.get_meta("shape_element")
				result.append({"key": "main:" + Document.uid_of(node), "shape": CURRENT, "name": str(source.get("name", "")),
					"label": str(source.get("name", "")), "node": node, "origin": source.get(Origins.ORIGIN_KEY), "index": -1})
	if not include_unloaded:
		for record in loaded:
			result.append(_item(record.index, record.entry, record))
		return result
	var value := entries()
	for i in range(value.size()):
		if value[i] is Dictionary:
			result.append(_item(i, value[i], record_for(i)))
	return result


func _item(i: int, entry: Dictionary, record: Dictionary) -> Dictionary:
	return {"key": "shape:%d" % i, "shape": str(entry.get("shapeFilepath", "")), "name": str(entry.get("rootShapeElementCode", "")),
			"label": "%s › %s" % [str(entry.get("shapeFilepath", "")), str(entry.get("rootShapeElementCode", ""))],
			"node": record.element if not record.is_empty() else null, "origin": entry.get("origin"), "index": i}


func root(key: String) -> Dictionary:
	for item in roots():
		if item.key == key:
			return item
	return {}


func record_for(index: int) -> Dictionary:
	for record in loaded:
		if record.index == index:
			return record
	return {}


## Sets a root's origin (packed as VSMC2 writes it) as one undo step.
func set_origin(key: String, values: Variant) -> void:
	var origin: Variant = Origins.packed(values) if values is Dictionary else null
	var item := root(key)
	if item.is_empty():
		return
	if item.index >= 0:
		change(item.index, "origin", origin)
		return
	edit_history.flush_pending.emit()
	var uid := key.trim_prefix("main:")
	if document != null and document.has(uid):
		edit_history.execute(SetFields.new(document, uid, {Origins.ORIGIN_KEY: origin if origin != null else Document.ABSENT}, "Set Origin"))


## Whether `key` may follow an element of `shape_path` without a loop.
func can_follow(key: String, shape_path: String, element_name: String) -> bool:
	var target := _find_element(shape_path, element_name)
	if target == null:
		return false
	var owner_key := _root_key_of(target)
	var guard := 0
	while not owner_key.is_empty() and guard < 256:
		if owner_key == key:
			return false
		owner_key = _depends_on(owner_key)
		guard += 1
	return true


## Every element a root could follow, as {shape, element, label}.
func element_choices() -> Array:
	var result: Array = []
	for item in roots():
		if item.node == null:
			continue
		for node in Geometry.elements(item.node):
			result.append({"shape": item.shape, "element": str(node.get_meta("shape_element").get("name", "")),
				"label": "%s in %s" % [str(node.get_meta("shape_element").get("name", "")), "this shape" if item.shape == CURRENT else item.shape]})
	return result


## Every attachment point a root could sit on, as {shape, element, code, label}.
func point_choices() -> Array:
	var result: Array = []
	for item in roots():
		if item.node == null:
			continue
		for node in Geometry.elements(item.node):
			var source: Dictionary = node.get_meta("shape_element")
			for point in source.get("attachmentPoints", []) if source.get("attachmentPoints") is Array else []:
				if point is Dictionary and not str(point.get("code", "")).is_empty():
					result.append({"shape": item.shape, "element": str(source.get("name", "")), "code": str(point.code),
						"label": "%s on %s (%s)" % [point.code, source.get("name", ""), "this shape" if item.shape == CURRENT else item.shape]})
	return result


# --- Building ----------------------------------------------------------------------

func clear_main_corrections() -> void:
	for node in main_poses:
		if is_instance_valid(node) and node.transform.is_equal_approx(main_poses[node].output):
			node.transform = main_poses[node].pose
	if not main_poses.is_empty():
		viewport_view.request_parity_check()
	main_poses.clear()


func rebuild() -> void:
	if stage == null:
		return
	clear_references(false)
	if viewport_view.models.get_child_count() == 0:
		refreshed.emit()
		return
	_load_references()


func clear_references(notify := true) -> void:
	clear_main_corrections()
	for record in loaded:
		if record.library.asset_paths.changed.is_connected(record.library.invalidate):
			record.library.asset_paths.changed.disconnect(record.library.invalidate)
	for child in stage.get_children():
		stage.remove_child(child)
		child.queue_free()
	loaded.clear()
	issues.clear()
	cyclic.clear()
	if notify:
		refreshed.emit()


func _load_references() -> void:
	var value := entries()
	for reference in Origins.legacy_references(viewport_view.shape_data):
		issues.append("Cannot find shape: " + str(reference.shapeFilepath))
	for i in range(value.size()):
		var entry: Variant = value[i]
		if not entry is Dictionary:
			issues.append("Invalid shape entry %d" % (i + 1))
			continue
		var reference := str(entry.get("shapeFilepath", ""))
		var path: String = asset_settings.resolve_shape(reference, source_path)
		if path.is_empty():
			issues.append("Cannot find shape: " + reference)
			continue
		if AssetPaths.normalize(path).to_lower() == AssetPaths.normalize(document_path.call()).to_lower():
			issues.append("Ignored self reference: " + reference)
			continue
		var result: Dictionary = Loader.new().load_file(path)
		if not result.error.is_empty():
			issues.append(reference + ": " + result.error)
			continue
		var wanted := str(entry.get("rootShapeElementCode", ""))
		var element: Node3D = null
		for child in result.root.get_children():
			if child.has_meta("shape_element") and element == null and str(child.get_meta("shape_element").get("name", "")) == wanted:
				element = child
		if element == null:
			issues.append("%s has no root element %s" % [reference, wanted])
			result.root.free()
			continue
		var holder := Node3D.new()
		holder.name = "Shape%d" % i
		stage.add_child(holder)
		result.root.remove_child(element)
		holder.add_child(element)
		result.root.free()
		var library = Library.new()
		library.set_asset_paths(asset_settings)
		library.bind(result.data, path)
		var animation = ShapeAnimation.new()
		animation.bind(holder, result.data)
		var codes: Array = []
		for clip in animation.clips:
			codes.append(clip.code)
		var record := {"index": i, "key": "shape:%d" % i, "entry": entry, "path": path, "holder": holder, "element": element,
			"elements": Geometry.elements(element), "library": library, "animation": animation, "codes": codes, "playing": "", "frame": -1.0}
		for node in record.elements:
			Geometry.refresh(node, library)
		# VSMC2 saves an entry without "enabled" as hidden.
		holder.visible = entry.get("enabled", false) == true
		loaded.append(record)
		_style(record)
		for message in library.issues.values():
			issues.append(reference + ": " + str(message))
	sync()
	refreshed.emit()


func _style(record: Dictionary) -> void:
	var opacity := clampf(float(record.entry.get("opacity", 1)), 0, 1)
	for node in record.elements:
		var geometry: MeshInstance3D = node.get_node_or_null("Geometry")
		if geometry == null or geometry.mesh == null:
			continue
		for i in range(geometry.mesh.get_surface_count()):
			var material := geometry.mesh.surface_get_material(i).duplicate() as StandardMaterial3D
			if record.entry.get("hideTextures", false) == true:
				material.albedo_texture = null
				material.albedo_color = COLORS[posmod(int(record.entry.get("flatColorIndex", 0)), COLORS.size())]
			material.albedo_color.a = opacity
			if opacity < 1:
				material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			geometry.set_surface_override_material(i, material)
		geometry.material_overlay = null
		if selected_key == record.key:
			var highlight := StandardMaterial3D.new()
			highlight.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			highlight.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			highlight.albedo_color = Color(0.2, 0.55, 1, 0.25)
			geometry.material_overlay = highlight


func highlight(key: String) -> void:
	selected_key = key
	for record in loaded:
		_style(record)


# --- Placement ---------------------------------------------------------------------

## The main shape's clip: additional shapes play their matching clip.
func follow(code: String, frame: float) -> void:
	main_clip = code
	main_frame = frame


func sync() -> void:
	if syncing or stage == null or viewport_view.models.get_child_count() == 0:
		return
	var main_root: Node3D = viewport_view.models.get_child(0)
	var items := roots(false)
	# Nothing to place: idle frames cost nothing.
	if loaded.is_empty() and main_poses.is_empty() and not items.any(func(item): return item.origin != null or _auto_step_parent(item) != ""):
		return

	syncing = true
	_play_clips()
	var by_key := {}
	var depends := {}
	for item in items:
		by_key[item.key] = item
		depends[item.key] = _depends_on(item.key, item)
	var solved: Dictionary = Origins.order(depends)
	cyclic = solved.cycles
	for key in solved.order + solved.cycles:
		var item: Dictionary = by_key[key]
		if item.node == null:
			continue
		var frame: Transform3D = main_root.global_transform
		if not key in cyclic:
			frame = _origin_frame(item, main_root)
		if item.index >= 0:
			var record := record_for(item.index)
			record.holder.global_transform = frame
		else:
			_place_main_root(item.node, main_root, frame)
	for record in loaded:
		for node in record.elements:
			var geometry: MeshInstance3D = node.get_node_or_null("Geometry")
			if geometry != null and geometry.get_meta("render_reflected", false) != Geometry.reflected(node):
				Geometry.refresh(node, record.library)
				_style(record)
	syncing = false
	viewport_view.request_parity_check()


func _place_main_root(node: Node3D, main_root: Node3D, frame: Transform3D) -> void:
	if viewport_view.gizmo.dragging and viewport_view.selected_node == node:
		return
	var pose: Transform3D = node.transform
	if main_poses.has(node) and pose.is_equal_approx(main_poses[node].output):
		pose = main_poses[node].pose
	var offset := main_root.global_transform.affine_inverse() * frame
	if offset.is_equal_approx(Transform3D.IDENTITY):
		node.transform = pose
		main_poses.erase(node)
	else:
		node.transform = offset * pose
		main_poses[node] = {"pose": pose, "output": node.transform}


## Where a root's own frame sits in the world: what it follows, then its item
## transform. A hidden or missing target counts as the shape's own frame.
func _origin_frame(item: Dictionary, main_root: Node3D) -> Transform3D:
	var origin: Variant = item.origin
	var kind := Origins.kind(origin)
	var base: Transform3D = main_root.global_transform
	var point := {}
	if kind == "attachment":
		var found := _find_point(Origins.element_code(origin).shapePath, str(origin.apCode))
		if not found.is_empty() and found.node.is_visible_in_tree():
			base = found.node.global_transform
			point = found.point
	else:
		var target: Node3D = null
		if kind == "element":
			var code := Origins.element_code(origin)
			target = _find_element(code.shapePath, code.element)
		else:
			var name_value := _auto_step_parent(item)
			if not name_value.is_empty():
				target = _find_element("", name_value, item.node)
		if target != null and target.is_visible_in_tree():
			base = target.global_transform
	return base * Origins.item_transform(origin, point)


## A root with no origin but a stepParentName follows that element, as
## VSMC2 and the game do.
func _auto_step_parent(item: Dictionary) -> String:
	if Origins.kind(item.origin) != "transform" or item.node == null:
		return ""
	return str(item.node.get_meta("shape_element").get("stepParentName", ""))


## The key of the root `key` follows, or "".
func _depends_on(key: String, item: Dictionary = {}) -> String:
	if item.is_empty():
		item = root(key)
	if item.is_empty() or item.node == null:
		return ""
	var origin: Variant = item.origin
	var target: Node3D = null
	match Origins.kind(origin):
		"attachment":
			var found := _find_point(Origins.element_code(origin).shapePath, str(origin.apCode))
			target = found.get("node")
		"element":
			var code := Origins.element_code(origin)
			target = _find_element(code.shapePath, code.element)
		_:
			var name_value := _auto_step_parent(item)
			if not name_value.is_empty():
				target = _find_element("", name_value, item.node)
	return _root_key_of(target) if target != null else ""


func _root_key_of(node: Node3D) -> String:
	if node == null:
		return ""
	var cursor: Node = node
	while cursor != null:
		var parent := cursor.get_parent()
		if viewport_view.models.get_child_count() > 0 and parent == viewport_view.models.get_child(0):
			return "main:" + Document.uid_of(cursor)
		for record in loaded:
			if cursor == record.element:
				return record.key
		cursor = parent
	return ""


## The shapes' root element nodes for a shape path ("" for any shape, edited
## shape first), in VSMC2's search order.
func _shape_roots(shape_path: String) -> Array:
	var result: Array = []
	if (shape_path.is_empty() or shape_path.to_lower() == CURRENT.to_lower()) and viewport_view.models.get_child_count() > 0:
		for node in viewport_view.models.get_child(0).get_children():
			if node.has_meta("shape_element"):
				result.append(node)
	for record in loaded:
		if shape_path.is_empty() or str(record.entry.get("shapeFilepath", "")).to_lower() == shape_path.to_lower():
			result.append(record.element)
	return result


## Breadth-first, case-insensitive, as VSMC2 finds step parents. With
## `exclude`, a root never finds an element of its own.
func _find_element(shape_path: String, element_name: String, exclude: Node3D = null) -> Node3D:
	if element_name.is_empty():
		return null
	var queue: Array = _shape_roots(shape_path)
	while not queue.is_empty():
		var node: Node3D = queue.pop_front()
		if node == exclude:
			continue
		if str(node.get_meta("shape_element").get("name", "")).to_lower() == element_name.to_lower():
			return node
		for child in node.get_children():
			if child.has_meta("shape_element"):
				queue.append(child)
	return null


## The element and attachment point with `code` in a shape: {node, point}.
func _find_point(shape_path: String, code: String) -> Dictionary:
	for top in _shape_roots(shape_path if not shape_path.is_empty() else CURRENT):
		for node in Geometry.elements(top):
			var points: Variant = node.get_meta("shape_element").get("attachmentPoints")
			for point in points if points is Array else []:
				if point is Dictionary and str(point.get("code", "")) == code:
					return {"node": node, "point": point}
	return {}


func _play_clips() -> void:
	var main_codes: Array = []
	var animations: Variant = viewport_view.shape_data.get("animations", [])
	for clip in animations if animations is Array else []:
		main_codes.append(str(clip.get("code", clip.get("name", ""))) if clip is Dictionary else "")
	for record in loaded:
		var code := Origins.mapped_clip(record.entry, main_clip, main_codes, record.codes)
		var index: int = record.codes.find(code)
		if index < 0:
			if record.playing != "":
				record.animation.restore()
				record.playing = ""
			continue
		var clip: Dictionary = record.animation.clips[index]
		var frame := fposmod(main_frame, float(maxi(clip.frames, 1)))
		if record.playing != code or not is_equal_approx(record.frame, frame):
			record.animation.apply(clip, frame)
			record.playing = code
			record.frame = frame


func _process(_delta: float) -> void:
	sync()


func frame_all() -> void:
	sync()
	var nodes: Array = Geometry.elements(viewport_view.models)
	for record in loaded:
		if record.holder.visible:
			nodes.append_array(record.elements)
	var bounds := AABB()
	var found := false
	for node in nodes:
		if not node.is_visible_in_tree():
			continue
		for face in Geometry.corners(Geometry.size_of(node.get_meta("shape_element"))):
			for point in face:
				var world: Vector3 = node.global_transform * point
				bounds = bounds.expand(world) if found else AABB(world, Vector3.ZERO)
				found = true
	if found:
		viewport_view.model_bounds = bounds
		viewport_view.frame_shape()


# --- Step parents (game data) --------------------------------------------------------

func set_step_parent(node: Node3D, name_value: String) -> void:
	if not is_instance_valid(node) or node.get_parent() != viewport_view.models.get_child(0):
		return
	var source: Dictionary = node.get_meta("shape_element")
	name_value = name_value.strip_edges()
	if str(source.get("stepParentName", "")) == name_value:
		return
	edit_history.flush_pending.emit()
	if str(source.get("stepParentName", "")) == name_value:
		return
	var uid := Document.uid_of(node)
	if document == null or not document.has(uid):
		return
	edit_history.execute(SetFields.new(document, uid, {"stepParentName": name_value if not name_value.is_empty() else Document.ABSENT}, "Set Step Parent"))


## Called whenever a document opens or a new one starts. Origin and
## step-parent edits (and their undo) re-place the shapes.
func bind_document(target_document) -> void:
	if document != null and document.element_changed.is_connected(_on_element_changed):
		document.element_changed.disconnect(_on_element_changed)
	document = target_document
	document.element_changed.connect(_on_element_changed)


func _on_element_changed(_uid: String, fields: Array) -> void:
	if fields.has("stepParentName") or fields.has(Origins.ORIGIN_KEY):
		clear_main_corrections()
		sync()
		refreshed.emit()


## Element names in the additional shapes, for the step parent picker.
func reference_names() -> Array:
	var names: Array = []
	for record in loaded:
		for node in record.elements:
			var name_value := str(node.get_meta("shape_element").get("name", ""))
			if not name_value in names:
				names.append(name_value)
	names.sort()
	return names


func warnings() -> PackedStringArray:
	var result := issues.duplicate()
	for item in roots():
		if item.node == null:
			continue
		var kind := Origins.kind(item.origin)
		if item.key in cyclic:
			result.append("%s: its origin loops back to itself, so it stays in place." % item.label)
		elif kind == "attachment" and _find_point(Origins.element_code(item.origin).shapePath, str(item.origin.apCode)).is_empty():
			result.append("%s: attachment point %s not found." % [item.label, item.origin.apCode])
		elif kind == "element":
			var code := Origins.element_code(item.origin)
			if _find_element(code.shapePath, code.element) == null:
				result.append("%s: element %s not found." % [item.label, code.element])
		elif not _auto_step_parent(item).is_empty() and _find_element("", _auto_step_parent(item), item.node) == null and item.index < 0:
			result.append("%s: step parent %s is not in any shown shape." % [item.label, _auto_step_parent(item)])
	return result


# --- Open in Context ----------------------------------------------------------------

## Prepares opening the file of an additional shape as the edited shape. The
## shape being edited becomes an additional shape of it, keeping every origin.
## Call before loading `path`; prepare() applies it.
func begin_context(index: int) -> String:
	var record := record_for(index)
	if record.is_empty():
		return ""
	pending_context = {"path": record.path, "from": document_path.call(), "from_source": source_path,
		"shape_path": str(record.entry.get("shapeFilepath", "")), "editor": settings(), "roots": []}
	for node in viewport_view.models.get_child(0).get_children():
		if node.has_meta("shape_element"):
			var source: Dictionary = node.get_meta("shape_element")
			pending_context.roots.append({"name": str(source.get("name", "")), "origin": source.get(Origins.ORIGIN_KEY), "enabled": node.visible})
	return record.path


func _apply_context(data: Dictionary, path: String) -> void:
	var context := pending_context
	var old_reference: String = asset_settings.shape_reference(context.from, path)
	var opened := str(context.shape_path)
	# Paths written for the old file must still find the same files from here.
	var rebased := {}
	var shapes: Array = []
	for entry in context.editor.additionalShapes:
		if not entry is Dictionary:
			continue
		var reference := str(entry.get("shapeFilepath", ""))
		if not rebased.has(reference):
			var file: String = asset_settings.resolve_shape(reference, context.from_source)
			rebased[reference] = asset_settings.shape_reference(file, path) if not file.is_empty() and AssetPaths.normalize(asset_settings.resolve_shape(reference, path)).to_lower() != AssetPaths.normalize(file).to_lower() else reference
		var copy: Dictionary = entry.duplicate(true)
		copy.shapeFilepath = rebased[reference]
		shapes.append(copy)
	for item in context.roots:
		var entry := {"shapeFilepath": old_reference, "rootShapeElementCode": item.name, "enabled": item.enabled}
		if item.origin is Dictionary:
			entry.origin = item.origin.duplicate(true)
		shapes.append(entry)
	var opened_origins := {}
	var kept: Array = []
	for entry in shapes:
		var origin: Variant = entry.get("origin")
		if origin is Dictionary and origin.get("rootElement") is Dictionary:
			var shape_path: String = Origins.element_code(origin).shapePath
			if shape_path == CURRENT:
				origin.rootElement.shapePath = old_reference
			elif shape_path == opened:
				origin.rootElement.erase("shapePath")
			elif rebased.has(shape_path):
				origin.rootElement.shapePath = rebased[shape_path]
		if entry.shapeFilepath == rebased.get(opened, opened):
			opened_origins[str(entry.get("rootShapeElementCode", ""))] = origin
		else:
			kept.append(entry)
	if not data.get("editor") is Dictionary:
		data.editor = {}
	data.editor.additionalShapes = kept
	for element in data.get("elements", []):
		if element is Dictionary:
			var origin: Variant = opened_origins.get(str(element.get("name", "")))
			if origin is Dictionary:
				element[Origins.ORIGIN_KEY] = origin
			else:
				element.erase(Origins.ORIGIN_KEY)


func _exit_tree() -> void:
	for record in loaded:
		if record.library.asset_paths.changed.is_connected(record.library.invalidate):
			record.library.asset_paths.changed.disconnect(record.library.invalidate)
