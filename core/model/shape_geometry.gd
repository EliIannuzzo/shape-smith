extends RefCounted

# Smaller determinants make inverse transforms unstable.
const MIN_TRANSFORM_DETERMINANT := 0.000001

const Units = preload("res://core/model/shape_units.gd")

const FACES := ["north", "east", "south", "west", "up", "down"]
const NORMALS := [Vector3.FORWARD, Vector3.RIGHT, Vector3.BACK, Vector3.LEFT, Vector3.UP, Vector3.DOWN]
# Godot front faces are clockwise; normals remain outward.
const TRIANGLES := [0, 2, 1, 0, 3, 2]
const REFLECTED_TRIANGLES := [0, 1, 2, 0, 2, 3]
const REFLECTION := Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3.BACK)
const WIRE_EDGES := [0, 1, 1, 2, 2, 3, 3, 0, 0, 2]


static func corners(size: Vector3) -> Array:
	var x := size.x
	var y := size.y
	var z := size.z
	return [
		[Vector3(x, y, 0), Vector3(x, 0, 0), Vector3.ZERO, Vector3(0, y, 0)],
		[Vector3(x, y, z), Vector3(x, 0, z), Vector3(x, 0, 0), Vector3(x, y, 0)],
		[Vector3(0, y, z), Vector3(0, 0, z), Vector3(x, 0, z), Vector3(x, y, z)],
		[Vector3(0, y, 0), Vector3.ZERO, Vector3(0, 0, z), Vector3(0, y, z)],
		[Vector3(0, y, 0), Vector3(0, y, z), Vector3(x, y, z), Vector3(x, y, 0)],
		[Vector3(0, 0, z), Vector3.ZERO, Vector3(x, 0, 0), Vector3(x, 0, z)]
	]


static func size_of(source: Dictionary) -> Vector3:
	return (Vector3(source.to[0], source.to[1], source.to[2]) - Vector3(source.from[0], source.from[1], source.from[2])) / Units.PER_BLOCK


static func face_uv(face: Dictionary, dimensions: Vector2) -> Array:
	var uv: Array = face.get("uv", [0.0, 0.0, dimensions.x, dimensions.y])
	return uv.duplicate()


static func reflected(node: Node3D) -> bool:
	if node.is_inside_tree():
		return node.global_basis.determinant() < 0
	# This also works while a newly copied subtree is detached from the scene.
	var determinant := 1.0
	var parent: Node = node
	while parent is Node3D:
		determinant *= parent.basis.determinant()
		parent = parent.get_parent()
	return determinant < 0


static func refresh(node: Node3D, library) -> void:
	var source: Dictionary = node.get_meta("shape_element")
	var geometry: MeshInstance3D = node.get_node_or_null("Geometry")
	if geometry == null:
		return

	var vertices := corners(size_of(source))
	var mirrored := reflected(node)
	var correction := REFLECTION if mirrored else Basis.IDENTITY
	# Keep the render instance right-handed. Bake the compensating reflection
	# into vertices/normals and reverse winding; source transforms stay intact.
	geometry.basis = correction
	geometry.set_meta("render_reflected", mirrored)
	var mesh := ArrayMesh.new()
	for index in range(6):
		var face: Dictionary = source.get("faces", {}).get(FACES[index], {})
		if not source.get("faces", {}).has(FACES[index]) or face.get("enabled", true) == false:
			continue

		var dimensions: Vector2 = library.uv_size(str(face.get("texture", "")).trim_prefix("#"))
		var uv := face_uv(face, dimensions)
		var coords := [Vector2(uv[0], uv[1]), Vector2(uv[0], uv[3]), Vector2(uv[2], uv[3]), Vector2(uv[2], uv[1])]
		# V grows down; preserve the VS compass orientation on the bottom face.
		if index == 5:
			coords = [Vector2(uv[2], uv[3]), Vector2(uv[2], uv[1]), Vector2(uv[0], uv[1]), Vector2(uv[0], uv[3])]
		var turns := posmod(roundi(float(face.get("rotation", 0)) / 90.0), 4)
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_LINES if library.render_mode == 2 else Mesh.PRIMITIVE_TRIANGLES)
		# The game shader's wind preview reads each corner's windMode and windData.
		var wind: bool = ("game_shading" in library) and library.game_shading
		if wind:
			surface.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
		for corner in WIRE_EDGES if library.render_mode == 2 else (REFLECTED_TRIANGLES if mirrored else TRIANGLES):
			if wind:
				surface.set_custom(0, Color(_corner_value(face.get("windMode"), corner), _corner_value(face.get("windData"), corner), 0, 0))
			surface.set_normal(correction * NORMALS[index])
			surface.set_uv(coords[posmod(corner + turns, 4)] / dimensions)
			surface.add_vertex(correction * vertices[index][corner])
		surface.set_material(library.material(face, source.get("shade", true), int(source.get("renderPass", -1))))
		surface.commit(mesh)
	geometry.material_override = null
	geometry.mesh = mesh


static func _corner_value(values: Variant, corner: int) -> float:
	if values is Array and corner < values.size() and (values[corner] is int or values[corner] is float):
		return float(values[corner])
	return 0.0


static func pick(root: Node3D, origin: Vector3, direction: Vector3) -> Dictionary:
	var best := {"distance": INF}
	for node in elements(root):
		if not node.is_visible_in_tree():
			continue

		# Locked elements cannot be picked.
		if node.get_meta("shapesmith_locked", false):
			continue

		# Isolate Selection hides other elements' meshes; skip those too.
		var mesh: Node3D = node.get_node_or_null("Geometry")
		if mesh != null and not mesh.visible:
			continue

		if absf(node.global_basis.determinant()) < MIN_TRANSFORM_DETERMINANT:
			continue

		var inverse := node.global_transform.affine_inverse()
		var source: Dictionary = node.get_meta("shape_element")
		var vertices := corners(size_of(source))
		for i in range(6):
			if not source.get("faces", {}).has(FACES[i]) or source.faces[FACES[i]].get("enabled", true) == false:
				continue

			for triangle in [[0, 1, 2], [0, 2, 3]]:
				var hit: Variant = Geometry3D.ray_intersects_triangle(inverse * origin, inverse.basis * direction,
					vertices[i][triangle[0]], vertices[i][triangle[1]], vertices[i][triangle[2]])
				if hit != null:
					var distance: float = (node.global_transform * hit - origin).dot(direction)
					if distance >= 0 and distance < best.distance:
						best = {"node": node, "face": FACES[i], "distance": distance}
	return best


static func elements(root: Node) -> Array[Node3D]:
	var result: Array[Node3D] = []
	if root.has_meta("shape_element"):
		result.append(root)
	for child in root.get_children():
		result.append_array(elements(child))
	return result
