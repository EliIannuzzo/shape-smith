extends RefCounted
## Additional shapes and root origins, in VSMC2's file format (`editor` keys
## `additionalShapes` and `rootElementOrigins`), as pure data and maths.
##
## Every root element has an origin: a plain transform, an element it follows
## (`rootElement`), or an attachment point on that element's shape (`apCode`).
## Each origin also carries an item transform: translation, rotation, scale and
## a pivot (`itemOrigin`), as the game's item and seat transforms do. The
## placement maths matches VSMC2's origin points.
##
## Inside ShapeSmith a main root's origin lives on the element itself under
## ORIGIN_KEY, so it follows the element when roots are added, removed or
## reordered. `with_origins_saved()` writes them back as `rootElementOrigins`.

const CURRENT_SHAPE := "Current Shape"
const ORIGIN_KEY := "$origin"
const MOUNT_OFFSET := Vector3(8, 0, 8)
const DEFAULT_PIVOT := Vector3(0.5, 0.5, 0.5)
const Units = preload("res://core/model/shape_units.gd")


static func vector(value: Variant, fallback: Vector3) -> Vector3:
	if not value is Dictionary:
		return fallback
	var result := fallback
	for axis in ["x", "y", "z"]:
		var number: Variant = value.get(axis)
		if (number is float or number is int) and is_finite(float(number)):
			result[["x", "y", "z"].find(axis)] = float(number)
	return result


static func vector_data(value: Vector3) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}


## "attachment", "element" or "transform".
static func kind(origin: Variant) -> String:
	if not origin is Dictionary:
		return "transform"
	if str(origin.get("apCode", "") if origin.get("apCode") != null else "") != "":
		return "attachment"
	var code := element_code(origin)
	return "element" if not code.element.is_empty() else "transform"


## The element an origin points at: {shapePath, element}. A missing shapePath
## means the shape being edited, as VSMC2 omits that default.
static func element_code(origin: Variant) -> Dictionary:
	var code: Variant = origin.get("rootElement") if origin is Dictionary else null
	if not code is Dictionary:
		return {"shapePath": CURRENT_SHAPE, "element": ""}
	var path: Variant = code.get("shapePath", CURRENT_SHAPE)
	var element: Variant = code.get("element", "")
	return {"shapePath": str(path) if path != null else CURRENT_SHAPE, "element": str(element) if element != null else ""}


## The item transform, in blocks: pivot, scale, translation, then rotation
## about X, Y and Z, back from the pivot. An attachment point adds its position
## (shape units, less the mount offset when asked) and its rotation.
static func item_transform(origin: Variant, point: Dictionary = {}) -> Transform3D:
	var data: Dictionary = origin if origin is Dictionary else {}
	var pivot := vector(data.get("itemOrigin"), DEFAULT_PIVOT)
	var scale := vector(data.get("itemScaleXYZ"), Vector3.ONE)
	var translation := vector(data.get("itemTranslation"), Vector3.ZERO)
	var rotation := vector(data.get("itemRotation"), Vector3.ZERO)
	if not point.is_empty():
		var position := Vector3(_number(point.get("posX")), _number(point.get("posY")), _number(point.get("posZ")))
		if data.get("useMountOffset", false) == true:
			position -= MOUNT_OFFSET
		translation += position / Units.PER_BLOCK
		rotation += Vector3(_number(point.get("rotationX")), _number(point.get("rotationY")), _number(point.get("rotationZ")))
	var basis := Basis(Vector3.RIGHT, deg_to_rad(rotation.x)) * Basis(Vector3.UP, deg_to_rad(rotation.y)) * Basis(Vector3.BACK, deg_to_rad(rotation.z))
	return Transform3D(Basis(), pivot) * Transform3D(Basis.from_scale(scale), Vector3.ZERO) \
		* Transform3D(Basis(), translation) * Transform3D(basis, Vector3.ZERO) * Transform3D(Basis(), -pivot)


## An origin as VSMC2 writes it: the item transform only where it differs from
## the defaults, then the element and attachment point. useMountOffset is kept
## when set (VSMC2 reads it).
static func packed(values: Dictionary) -> Variant:
	var result := {}
	var pivot := vector(values.get("itemOrigin"), DEFAULT_PIVOT)
	var rotation := vector(values.get("itemRotation"), Vector3.ZERO)
	var translation := vector(values.get("itemTranslation"), Vector3.ZERO)
	var scale := vector(values.get("itemScaleXYZ"), Vector3.ONE)
	if not pivot.is_equal_approx(DEFAULT_PIVOT):
		result.itemOrigin = vector_data(pivot)
	if not rotation.is_zero_approx():
		result.itemRotation = vector_data(rotation)
	if not translation.is_zero_approx():
		result.itemTranslation = vector_data(translation)
	if not scale.is_equal_approx(Vector3.ONE):
		result.itemScaleXYZ = vector_data(scale)
	var code := element_code(values)
	if not code.element.is_empty():
		result.rootElement = {"element": code.element} if code.shapePath == CURRENT_SHAPE else code
	var point: Variant = values.get("apCode")
	if point != null and str(point) != "":
		result.apCode = str(point)
		if values.get("useMountOffset", false) == true:
			result.useMountOffset = true
	return result if not result.is_empty() else null


## Orders roots so each comes after the root it depends on. `depends` maps a
## key to the key it follows ("" for none). Roots in a cycle are left out of
## the order and listed in `cycles`.
static func order(depends: Dictionary) -> Dictionary:
	var result: Array = []
	var cycles: Array = []
	var state := {}
	for key in depends:
		_visit(key, depends, state, result, cycles, [])
	return {"order": result, "cycles": cycles}


static func _visit(key: Variant, depends: Dictionary, state: Dictionary, result: Array, cycles: Array, path: Array) -> bool:
	if state.get(key, 0) == 2:
		return true
	if state.get(key, 0) == 1:
		for member in path.slice(path.find(key)):
			if not member in cycles:
				cycles.append(member)
		return false
	state[key] = 1
	path.append(key)
	var target: Variant = depends.get(key, "")
	var ok := true
	if target != "" and depends.has(target):
		ok = _visit(target, depends, state, result, cycles, path)
	path.pop_back()
	state[key] = 2
	if ok and not key in cycles:
		result.append(key)
	return ok and not key in cycles


## Moves `editor.rootElementOrigins[i]` onto root element i (ORIGIN_KEY).
static func distribute(data: Dictionary) -> void:
	var editor: Variant = data.get("editor")
	var elements: Variant = data.get("elements")
	if not editor is Dictionary or not editor.get("rootElementOrigins") is Array or not elements is Array:
		return
	var origins: Array = editor.rootElementOrigins
	for i in range(mini(origins.size(), elements.size())):
		if origins[i] is Dictionary and elements[i] is Dictionary:
			elements[i][ORIGIN_KEY] = origins[i].duplicate(true)


## A copy for saving: root origins written back as `rootElementOrigins` (one
## per root, null where a root has none) and ORIGIN_KEY removed everywhere.
## The list is written when any root has an origin or the file had one.
static func with_origins_saved(data: Dictionary) -> Dictionary:
	var result := data.duplicate(true)
	var elements: Variant = result.get("elements")
	if not elements is Array:
		return result
	var origins: Array = []
	var any := false
	for element in elements:
		var origin: Variant = element.get(ORIGIN_KEY) if element is Dictionary else null
		origins.append(origin)
		any = any or origin != null
	_strip(elements)
	var editor: Variant = result.get("editor")
	if any or (editor is Dictionary and editor.has("rootElementOrigins")):
		if not editor is Dictionary:
			editor = {}
			result.editor = editor
		editor.rootElementOrigins = origins
	return result


static func _strip(elements: Array) -> void:
	for element in elements:
		if element is Dictionary:
			element.erase(ORIGIN_KEY)
			if element.get("children") is Array:
				_strip(element.children)


## The older references a file may carry: VSMC1's `backDropShape` (in `editor`
## or at the top level) and ShapeSmith 1's `editor.backdrops` and
## `editor.attachments`.
static func legacy_references(data: Dictionary) -> Array:
	var result: Array = []
	var editor: Variant = data.get("editor")
	editor = editor if editor is Dictionary else {}
	for source in [editor.get("backDropShape"), data.get("backDropShape")]:
		if source is String and not source.is_empty():
			result.append({"shapeFilepath": source, "enabled": true, "opacity": 1.0})
			break
	for kind_name in ["backdrops", "attachments"]:
		if editor.get(kind_name) is Array:
			for entry in editor[kind_name]:
				if entry is Dictionary and entry.get("shapeFilepath") is String:
					result.append(entry)
	return result


## Converts legacy references into additional shapes, one per root element.
## `root_names` takes a shapeFilepath and returns its root element names, or
## null when the file cannot be found; such references are kept as they were.
## Returns {"converted": int, "missing": Array of paths}.
static func convert_legacy(data: Dictionary, root_names: Callable) -> Dictionary:
	var references := legacy_references(data)
	if references.is_empty():
		return {"converted": 0, "missing": []}
	if not data.get("editor") is Dictionary:
		data.editor = {}
	var editor: Dictionary = data.editor
	var shapes: Array = editor.get("additionalShapes") if editor.get("additionalShapes") is Array else []
	var missing: Array = []
	var kept := {"backdrops": [], "attachments": []}
	var converted := 0
	for reference in references:
		var names: Variant = root_names.call(reference.shapeFilepath)
		if not names is Array:
			missing.append(reference.shapeFilepath)
			continue
		for root_name in names:
			var entry := {"shapeFilepath": reference.shapeFilepath, "rootShapeElementCode": root_name,
				"enabled": reference.get("enabled", true) != false}
			var opacity: Variant = reference.get("opacity", 1.0)
			if (opacity is float or opacity is int) and not is_equal_approx(float(opacity), 1.0):
				entry.opacity = float(opacity)
			if reference.get("hideTextures", false) == true:
				entry.hideTextures = true
			if int(reference.get("flatColorIndex", 0)) != 0:
				entry.flatColorIndex = int(reference.flatColorIndex)
			shapes.append(entry)
			converted += 1
	# Unresolved references stay in the old keys so nothing is lost.
	for kind_name in ["backdrops", "attachments"]:
		if editor.get(kind_name) is Array:
			for entry in editor[kind_name]:
				if entry is Dictionary and entry.get("shapeFilepath") in missing:
					kept[kind_name].append(entry)
			if kept[kind_name].is_empty():
				editor.erase(kind_name)
			else:
				editor[kind_name] = kept[kind_name]
	for container in [editor, data]:
		if container.get("backDropShape") is String and not container.backDropShape in missing:
			container.erase("backDropShape")
	if not shapes.is_empty():
		editor.additionalShapes = shapes
	return {"converted": converted, "missing": missing}


## The reference clip to play while the main shape plays `main_code`. Without
## unique animations a clip with the same code plays; with them, the entry's
## `animationPlaybackMapping` (pairs of clip indices) decides. "" for none.
static func mapped_clip(entry: Dictionary, main_code: String, main_codes: Array, reference_codes: Array) -> String:
	if main_code.is_empty():
		return ""
	if entry.get("useUniqueAnimations", false) != true:
		for code in reference_codes:
			if str(code).to_lower() == main_code.to_lower():
				return str(code)
		return ""
	var pairs: Variant = entry.get("animationPlaybackMapping", [])
	if not pairs is Array:
		return ""
	for i in range(0, pairs.size() - 1, 2):
		var main_index := int(pairs[i]) if pairs[i] is float or pairs[i] is int else -1
		var reference_index := int(pairs[i + 1]) if pairs[i + 1] is float or pairs[i + 1] is int else -1
		if main_index >= 0 and main_index < main_codes.size() and str(main_codes[main_index]).to_lower() == main_code.to_lower() \
				and reference_index >= 0 and reference_index < reference_codes.size():
			return str(reference_codes[reference_index])
	return ""


## The mapping with `main_code` set to play `reference_code` ("" removes it).
static func with_mapping(entry: Dictionary, main_code: String, reference_code: String, main_codes: Array, reference_codes: Array) -> Array:
	var result: Array = []
	var pairs: Variant = entry.get("animationPlaybackMapping", [])
	var main_index := _index_of(main_codes, main_code)
	if pairs is Array:
		for i in range(0, pairs.size() - 1, 2):
			if int(pairs[i]) != main_index:
				result.append_array([int(pairs[i]), int(pairs[i + 1])])
	var reference_index := _index_of(reference_codes, reference_code)
	if main_index >= 0 and reference_index >= 0:
		result.append_array([main_index, reference_index])
	return result


static func _index_of(codes: Array, code: String) -> int:
	for i in range(codes.size()):
		if str(codes[i]).to_lower() == code.to_lower():
			return i
	return -1


static func _number(value: Variant) -> float:
	return float(value) if (value is float or value is int) and is_finite(float(value)) else 0.0
