extends RefCounted
## The editor's model of one shape file, independent of the scene tree.
##
## Each record wraps the raw JSON dictionary it was parsed from, so every field
## ShapeSmith does not understand is written back unchanged. Records are keyed by
## a stable uid that lives only in memory and is never written to game JSON.
## Edits go through the mutation methods below (normally from a command), which
## emit fine-grained signals so panels update only what changed.
##
## Migration adapter: while panels still edit Node3D metadata directly,
## call refresh() after such edits. It re-reads the data and keeps each
## element's uid for as long as the element's dictionary is the same object.

signal element_added(uid: String)
signal element_removed(uid: String)
signal element_changed(uid: String, fields: Array)
signal element_moved(uid: String, old_parent: String, new_parent: String)
signal structure_reset
## Keyframes changed (tracks renamed, removed or added by a command).
signal animations_changed
signal point_added(uid: String)
signal point_removed(uid: String, owner: String)
signal point_changed(uid: String, fields: Array)

## Parent uid of top-level elements.
const ROOT := ""
## Field value meaning "remove this key", distinct from a JSON null.
const ABSENT := &"<absent>"
const NODE_META := "shape_uid"
const POINT_KEYS := ["attachmentpoints", "attachmentPoints"]


class Element:
	var uid := ""
	var source: Dictionary
	var parent := ROOT
	var children: Array[String] = []
	var points: Array[String] = []

	func name() -> String:
		return str(source.get("name", ""))


class AttachmentPoint:
	var uid := ""
	var owner := ""
	var source: Dictionary

	func code() -> String:
		return str(source.get("code", ""))


var data: Dictionary = {}
var elements: Dictionary = {}
var points: Dictionary = {}
var roots: Array[String] = []
var _next_id := 0
## Records that refresh() could not match, kept so a redo can reclaim them.
const RETIRED_LIMIT := 2048
var _retired_elements: Array = []
var _retired_points: Array = []


static func from_data(value: Dictionary):
	var document = load("res://core/document/shape_document.gd").new()
	document.reset(value)
	return document


func reset(value: Dictionary) -> void:
	data = value
	elements.clear()
	points.clear()
	roots.clear()
	_retired_elements.clear()
	_retired_points.clear()
	if not data.get("elements") is Array:
		data.elements = []
	for source in data.elements:
		if source is Dictionary:
			roots.append(_register(source, ROOT, []))
	structure_reset.emit()


## Re-reads the data after legacy code edited it directly. Uids survive for
## every element and attachment point whose dictionary is still the same object,
## including one that a legacy undo removed and a redo puts back.
func refresh() -> void:
	var reuse := {"elements": elements.values() + _retired_elements, "points": points.values() + _retired_points}
	elements.clear()
	points.clear()
	roots.clear()
	for source in data.get("elements", []):
		if source is Dictionary:
			roots.append(_register(source, ROOT, [], reuse))
	# Whatever was not matched may come back on redo; keep the most recent.
	_retired_elements = reuse.elements.slice(-RETIRED_LIMIT)
	_retired_points = reuse.points.slice(-RETIRED_LIMIT)
	structure_reset.emit()


func _register(source: Dictionary, parent: String, uids: Array, reuse := {}, point_uids: Array = []) -> String:
	var record := Element.new()
	record.uid = _claim(source, uids, reuse.get("elements", []), "e")
	record.source = source
	record.parent = parent
	elements[record.uid] = record
	for point in point_array(source):
		if point is Dictionary:
			var marker := AttachmentPoint.new()
			marker.uid = _claim(point, point_uids, reuse.get("points", []), "p")
			marker.owner = record.uid
			marker.source = point
			points[marker.uid] = marker
			record.points.append(marker.uid)
	var children: Variant = source.get("children", [])
	if children is Array:
		for child in children:
			if child is Dictionary:
				record.children.append(_register(child, record.uid, uids, reuse, point_uids))
	return record.uid


func _claim(source: Dictionary, uids: Array, candidates: Array, prefix: String) -> String:
	if not uids.is_empty():
		var reused: String = uids.pop_front()
		if not elements.has(reused) and not points.has(reused):
			return reused
	for i in range(candidates.size()):
		if is_same(candidates[i].source, source):
			var uid: String = candidates[i].uid
			candidates.remove_at(i)
			return uid
	_next_id += 1
	return "%s:%x" % [prefix, _next_id]


## A fresh element uid, for commands that must name an element before it
## exists (a group created and filled in one step).
func new_uid() -> String:
	_next_id += 1
	return "e:%x" % _next_id


# --- Queries ---------------------------------------------------------------

func has(uid: String) -> bool:
	return elements.has(uid)


func element(uid: String) -> Element:
	return elements.get(uid)


func source(uid: String) -> Dictionary:
	return elements[uid].source if elements.has(uid) else {}


func parent_of(uid: String) -> String:
	return elements[uid].parent if elements.has(uid) else ROOT


func children_of(uid: String) -> Array[String]:
	return roots if uid == ROOT else (elements[uid].children if elements.has(uid) else [] as Array[String])


func index_of(uid: String) -> int:
	return children_of(parent_of(uid)).find(uid)


func is_ancestor(ancestor: String, uid: String) -> bool:
	var current := parent_of(uid)
	while current != ROOT:
		if current == ancestor:
			return true
		current = parent_of(current)
	return false


## Depth-first order, the same order as the outliner and the JSON file.
func ordered(from := ROOT) -> Array[String]:
	var result: Array[String] = []
	for child in children_of(from):
		result.append(child)
		result.append_array(ordered(child))
	return result


func path_of(uid: String) -> String:
	var names: PackedStringArray = []
	var current := uid
	while current != ROOT and elements.has(current):
		names.insert(0, elements[current].name())
		current = elements[current].parent
	return "/".join(names)


func find_by_path(path: String) -> String:
	var current := ROOT
	for part in path.split("/"):
		var found := ""
		for child in children_of(current):
			if elements[child].name() == part:
				found = child
				break
		if found.is_empty():
			return ""
		current = found
	return current


func find_by_name(name: String) -> String:
	for uid in ordered():
		if elements[uid].name() == name:
			return uid
	return ""


# --- Animation data helpers (used by track commands) ------------------------

static func animations(value: Dictionary) -> Array:
	return value.animations if value.get("animations") is Array else []


static func clip_keyframes(clip: Variant) -> Array:
	return clip.keyframes if clip is Dictionary and clip.get("keyframes") is Array else []


## Every keyframe, in every clip, that has an elements object.
static func keyframes(value: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for clip in animations(value):
		for key in clip_keyframes(clip):
			if key is Dictionary and key.get("elements") is Dictionary:
				result.append(key)
	return result


## Renames a key in place, keeping its position among the other keys.
static func rename_key(target: Dictionary, old_key: String, new_key: String) -> void:
	var entries := target.duplicate()
	target.clear()
	for key in entries:
		target[new_key if key == old_key else key] = entries[key]


## Inserts a key in place at a position among the existing keys.
static func insert_key(target: Dictionary, new_key: String, value: Variant, position: int) -> void:
	var entries := target.duplicate()
	target.clear()
	var index := 0
	for key in entries:
		if index == position:
			target[new_key] = value
		target[key] = entries[key]
		index += 1
	if not target.has(new_key):
		target[new_key] = value


static func point_array(element_source: Dictionary) -> Array:
	for key in POINT_KEYS:
		if element_source.get(key) is Array:
			return element_source[key]
	return []


# --- Mutations (called by commands) ----------------------------------------

## Writes fields onto an element. ABSENT erases a key. Returns the previous
## values in the same form, so passing the result back undoes the change.
func set_fields(uid: String, fields: Dictionary) -> Dictionary:
	var target: Dictionary = elements[uid].source
	var previous := {}
	for key in fields:
		previous[key] = _copy(target[key]) if target.has(key) else ABSENT
		if is_same(fields[key], ABSENT):
			target.erase(key)
		else:
			target[key] = _copy(fields[key])
	element_changed.emit(uid, fields.keys())
	return previous


## Reports an edit a command made inside an element's nested data (a face,
## for example) so listeners update as for set_fields().
func touch(uid: String, fields: Array) -> void:
	if elements.has(uid):
		element_changed.emit(uid, fields)


# --- Attachment points -------------------------------------------------------

func point(uid: String) -> AttachmentPoint:
	return points.get(uid)


## The point uid at an index of an element's attachment point array, or "".
func point_at(owner: String, index: int) -> String:
	if not elements.has(owner):
		return ""
	var array := point_array(elements[owner].source)
	if index < 0 or index >= array.size():
		return ""
	for uid in elements[owner].points:
		if is_same(points[uid].source, array[index]):
			return uid
	return ""


func point_index(uid: String) -> int:
	if not points.has(uid):
		return -1
	var array := point_array(elements[points[uid].owner].source)
	for i in range(array.size()):
		if is_same(array[i], points[uid].source):
			return i
	return -1


## Inserts a point into an element's array, creating "attachmentPoints" if the
## element has neither spelling. Returns the point's uid.
func insert_point(owner: String, index: int, point_source: Dictionary, uid := "") -> String:
	var owner_source: Dictionary = elements[owner].source
	var key := _point_key(owner_source)
	if not owner_source.get(key) is Array:
		owner_source[key] = []
	var array: Array = owner_source[key]
	index = array.size() if index < 0 else clampi(index, 0, array.size())
	array.insert(index, point_source)
	var marker := AttachmentPoint.new()
	if uid.is_empty() or points.has(uid) or elements.has(uid):
		_next_id += 1
		uid = "p:%x" % _next_id
	marker.uid = uid
	marker.owner = owner
	marker.source = point_source
	points[uid] = marker
	elements[owner].points.append(uid)
	point_added.emit(uid)
	return uid


## Removes a point. Returns {owner, index, source, uid} for insert_point().
## With erase_empty_key, an array left empty loses its key (undo of a first add).
func remove_point(uid: String, erase_empty_key := false) -> Dictionary:
	var marker: AttachmentPoint = points[uid]
	var owner_source: Dictionary = elements[marker.owner].source
	var index := point_index(uid)
	var key := _point_key(owner_source)
	owner_source[key].remove_at(index)
	if erase_empty_key and owner_source[key].is_empty():
		owner_source.erase(key)
	elements[marker.owner].points.erase(uid)
	points.erase(uid)
	point_removed.emit(uid, marker.owner)
	return {"owner": marker.owner, "index": index, "source": marker.source, "uid": uid}


## Like set_fields(), for one attachment point.
func set_point_fields(uid: String, fields: Dictionary) -> Dictionary:
	var target: Dictionary = points[uid].source
	var previous := {}
	for key in fields:
		previous[key] = _copy(target[key]) if target.has(key) else ABSENT
		if is_same(fields[key], ABSENT):
			target.erase(key)
		else:
			target[key] = _copy(fields[key])
	point_changed.emit(uid, fields.keys())
	return previous


## The spelling an element uses for its attachment points; new arrays use
## the game's camel case.
static func _point_key(element_source: Dictionary) -> String:
	return "attachmentpoints" if element_source.has("attachmentpoints") and not element_source.has("attachmentPoints") else "attachmentPoints"


## Inserts an element subtree. Pass the uids and point_uids returned by
## remove() to restore the same ids on undo. Returns the inserted element's uid.
func insert(parent: String, index: int, element_source: Dictionary, uids: Array = [], point_uids: Array = []) -> String:
	var siblings := _children_array(parent, true)
	index = clampi(index, 0, siblings.size())
	siblings.insert(index, element_source)
	var uid := _register(element_source, parent, uids.duplicate(), {}, point_uids.duplicate())
	children_of(parent).insert(index, uid)
	element_added.emit(uid)
	return uid


## Removes an element subtree and returns what insert() needs to restore it:
## {source, parent, index, uids, point_uids}. With erase_empty_children, a parent left with
## no children loses its "children" key (undo of an insert that created it).
func remove(uid: String, erase_empty_children := false) -> Dictionary:
	var record: Element = elements[uid]
	var parent := record.parent
	var index := index_of(uid)
	var subtree: Array[String] = [uid]
	subtree.append_array(ordered(uid))
	var siblings := _children_array(parent, false)
	siblings.remove_at(index)
	children_of(parent).remove_at(index)
	if erase_empty_children:
		drop_empty_children(parent)
	var point_uids: Array[String] = []
	for removed in subtree:
		for point in elements[removed].points:
			point_uids.append(point)
			points.erase(point)
		elements.erase(removed)
	element_removed.emit(uid)
	return {"source": record.source, "parent": parent, "index": index, "uids": subtree, "point_uids": point_uids}


## Reparents and/or reorders. index counts siblings after the element left its
## old place. Returns the old {parent, index} for undo.
func move(uid: String, parent: String, index: int) -> Dictionary:
	var record: Element = elements[uid]
	var old_parent := record.parent
	var old_index := index_of(uid)
	_children_array(old_parent, false).remove_at(old_index)
	children_of(old_parent).remove_at(old_index)
	var siblings := _children_array(parent, true)
	index = clampi(index, 0, siblings.size())
	siblings.insert(index, record.source)
	children_of(parent).insert(index, uid)
	record.parent = parent
	element_moved.emit(uid, old_parent, parent)
	return {"parent": old_parent, "index": old_index}


## Removes an empty "children" key that an undone edit had created.
func drop_empty_children(uid: String) -> void:
	if elements.has(uid) and elements[uid].source.get("children") is Array and elements[uid].source.children.is_empty():
		elements[uid].source.erase("children")


func _children_array(parent: String, create: bool) -> Array:
	if parent == ROOT:
		return data.elements
	var parent_source: Dictionary = elements[parent].source
	if not parent_source.get("children") is Array:
		if not create:
			return []
		parent_source.children = []
	return parent_source.children


static func _copy(value: Variant) -> Variant:
	return value.duplicate(true) if value is Array or value is Dictionary else value


# --- Scene adapter ---------------------------------------------------------

## Tags each legacy Node3D with its element's uid, matching nodes to records
## by their shared metadata dictionary.
func bind_nodes(root: Node) -> void:
	# Depth-first, like record registration, so matches are usually found first.
	var stack: Array[Node] = [root]
	var pending := elements.values()
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.has_meta("shape_element"):
			var element_source: Dictionary = node.get_meta("shape_element")
			for i in range(pending.size()):
				if is_same(pending[i].source, element_source):
					node.set_meta(NODE_META, pending[i].uid)
					pending.remove_at(i)
					break
		var children := node.get_children()
		children.reverse()
		stack.append_array(children)


static func uid_of(node: Node) -> String:
	return str(node.get_meta(NODE_META, "")) if is_instance_valid(node) else ""
