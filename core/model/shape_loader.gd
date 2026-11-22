extends RefCounted
const Limits = preload("res://core/model/shape_limits.gd")
## Builds a detached model tree so failed imports leave the open document intact.

const Units = preload("res://core/model/shape_units.gd")
const UNITS_PER_BLOCK := Units.PER_BLOCK
const MAX_ELEMENTS := 10000
const MAX_DEPTH := 64
const Geometry = preload("res://core/model/shape_geometry.gd")
const FACE_NAMES = Geometry.FACES

var error := ""
var element_count := 0
var face_count := 0
var bounds := AABB()
var has_bounds := false
var material := StandardMaterial3D.new()


func load_file(path: String) -> Dictionary:
	error = ""
	element_count = 0
	face_count = 0
	has_bounds = false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "Could not open the selected file."}

	if file.get_length() > Limits.MAX_FILE_BYTES:
		return {"error": "Shape files must be smaller than 32 MB."}

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return {"error": "Invalid JSON at line %d: %s" % [json.get_error_line(), json.get_error_message()]}

	if not json.data is Dictionary or not json.data.get("elements") is Array:
		return {"error": "Expected a shape object containing an elements array."}
	var working_error := preload("res://core/model/working_document.gd").validation_error(json.data)
	if not working_error.is_empty():
		return {"error": working_error}

	preload("res://core/model/shape_serializer.gd").restore_implicit_axes(json.data)
	# Working files: authored keys replace the baked game keys.
	var notes: PackedStringArray = preload("res://core/model/working_document.gd").restore(json.data)
	var root := Node3D.new()
	root.name = "Shape"
	material.albedo_color = Color("b8c9db")
	material.roughness = 0.85
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	for element in json.data.elements:
		_add_element(element, root, Transform3D.IDENTITY, 0)
		if not error.is_empty():
			root.free()
			return {"error": error}

	return {"root": root, "bounds": bounds if has_bounds else AABB(Vector3.ZERO, Vector3.ONE),
		"elements": element_count, "faces": face_count, "data": json.data, "path": path, "error": "", "notes": notes}


func _add_element(value: Variant, parent: Node3D, parent_transform: Transform3D, depth: int) -> void:
	if not error.is_empty():
		return

	if depth > MAX_DEPTH or element_count >= MAX_ELEMENTS:
		error = "Shape exceeds the limit of %d elements or %d nesting levels." % [MAX_ELEMENTS, MAX_DEPTH]
		return

	if not value is Dictionary:
		error = "Each element must be an object."
		return

	var element: Dictionary = value
	for field in ["shade", "gradientShade", "disableRandomDrawOffset"]:
		if element.has(field) and not element[field] is bool:
			error = "Element %s must be a boolean." % field
			return

	for field in ["climateColorMap", "seasonColorMap"]:
		if element.get(field) != null and not element[field] is String:
			error = "Element %s must be a color map name." % field
			return

	for field in ["renderPass", "zOffset"]:
		if element.has(field) and not _integer_range(element[field], -32768, 32767):
			error = "Element %s must be an integer between -32768 and 32767." % field
			return

	var start := _vector(element.get("from"), "from") / UNITS_PER_BLOCK
	var end := _vector(element.get("to"), "to") / UNITS_PER_BLOCK
	var pivot := _vector(element.get("rotationOrigin", [0, 0, 0]), "rotationOrigin") / UNITS_PER_BLOCK
	var rotation := Vector3.ZERO
	var scale_value := Vector3.ONE
	for axis in range(3):
		var suffix: String = ["X", "Y", "Z"][axis]
		rotation[axis] = deg_to_rad(_number(element.get("rotation" + suffix, 0), "rotation" + suffix))
		scale_value[axis] = _number(element.get("scale" + suffix, 1), "scale" + suffix)
	if not error.is_empty():
		return

	var points: Variant = element.get("attachmentPoints", element.get("attachmentpoints", []))
	if not points is Array:
		error = "Element attachmentpoints must be an array."
		return

	for point in points:
		if not point is Dictionary or (point.has("code") and not point.code is String):
			error = "Attachment points must be objects with string codes."
			return

		for field in ["posX", "posY", "posZ", "rotationX", "rotationY", "rotationZ"]:
			if point.has(field):
				point[field] = _attachment_number(point[field], field)
		if not error.is_empty():
			return
	# VS applies X, Y, then Z matrix multiplication around a pivot, then From.
	var basis := Basis(Vector3.RIGHT, rotation.x) * Basis(Vector3.UP, rotation.y) * Basis(Vector3.BACK, rotation.z)
	basis = basis * Basis.from_scale(scale_value)
	var local := Transform3D(basis, pivot + basis * (start - pivot))
	var node := Node3D.new()
	node.name = str(element.get("name", "Element")).validate_node_name()
	node.transform = local
	node.set_meta("shape_element", element)
	parent.add_child(node)
	element_count += 1
	var world := parent_transform * local
	var faces: Variant = element.get("faces", {})
	if not faces is Dictionary:
		error = "Element faces must be an object."
		return

	var mesh := _make_mesh(end - start, faces, world)
	if mesh != null:
		var instance := MeshInstance3D.new()
		instance.name = "Geometry"
		instance.mesh = mesh
		if world.basis.determinant() < 0:
			instance.basis = Geometry.REFLECTION
		instance.set_meta("render_reflected", world.basis.determinant() < 0)
		instance.material_override = material
		node.add_child(instance)
	var children: Variant = element.get("children", [])
	if not children is Array:
		error = "Element children must be an array."
		return

	for child in children:
		_add_element(child, node, world, depth + 1)


func _make_mesh(size: Vector3, faces: Dictionary, world: Transform3D) -> ArrayMesh:
	var mirrored := world.basis.determinant() < 0
	var correction: Basis = Geometry.REFLECTION if mirrored else Basis.IDENTITY
	var corners := Geometry.corners(size)
	var normals: Array = Geometry.NORMALS
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 0
	for index in range(6):
		if not faces.has(FACE_NAMES[index]):
			continue

		var face: Variant = faces[FACE_NAMES[index]]
		if not face is Dictionary:
			error = "Each face must be an object."
			return null

		if face.has("uv"):
			if not face.uv is Array or face.uv.size() != 4:
				error = "Face UV bounds must contain four numbers."
				return null

			for value in face.uv:
				_number(value, "uv")
		if face.has("texture") and not face.texture is String:
			error = "Face texture must be a texture ID string."
		for field in ["enabled", "frostable"]:
			if face.has(field) and not face[field] is bool:
				error = "Face %s must be a boolean." % field
		for field in ["windMode", "windData"]:
			if face.get(field) == null:
				continue

			if not face[field] is Array or face[field].size() != 4:
				error = "Face %s must contain four signed bytes." % field
				return null

			for entry in face[field]:
				if not _integer_range(entry, -128, 127):
					error = "Face %s values must be integers between -128 and 127." % field
		if face.has("reflectiveMode") and not face.reflectiveMode is String and not _integer_range(face.reflectiveMode, -2147483648, 2147483647):
			error = "Face reflectiveMode must be an enum name or integer."
		for field in ["rotation", "glow"]:
			if face.has(field):
				_number(face[field], field)
		if not error.is_empty():
			return null

		if face.get("enabled", true) == false:
			continue

		for corner in Geometry.REFLECTED_TRIANGLES if mirrored else Geometry.TRIANGLES:
			var vertex: Vector3 = corners[index][corner]
			surface.set_normal(correction * normals[index])
			surface.add_vertex(correction * vertex)
			var point := world * vertex
			if not has_bounds:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(point)
		count += 1
	face_count += count
	return surface.commit() if count > 0 else null


func _vector(value: Variant, field: String) -> Vector3:
	if not value is Array or value.size() != 3:
		error = "%s must be an array of three numbers." % field
		return Vector3.ZERO

	return Vector3(_number(value[0], field), _number(value[1], field), _number(value[2], field))


func _attachment_number(value: Variant, field: String) -> float:
	# Some base-game shapes store attachment transforms as JSON strings.
	if value is String and value.strip_edges().is_valid_float():
		value = value.to_float()

	return _number(value, "Attachment point " + field)


func _number(value: Variant, field: String) -> float:
	if not (value is float or value is int) or not is_finite(float(value)) or abs(float(value)) > Limits.MAX_COORDINATE:
		error = "%s must contain finite numbers within ±1,000,000." % field
		return 0.0

	return float(value)


func _integer_range(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) == floor(float(value)) and value >= minimum and value <= maximum
