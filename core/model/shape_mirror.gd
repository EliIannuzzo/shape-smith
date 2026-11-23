extends RefCounted
## Mirroring a shape element across a plane without a reflection in its own
## transform. The box, pivot and rotation are reflected, the two faces across
## the mirror axis swap, and every face's texture is flipped so it reads as a
## mirror image. Scale keeps its sign: tools that cannot show a mirrored
## (negative-scale) element, such as VSMC2, show the result as ShapeSmith and
## the game do.
##
## Derivation, for reflection M across `plane` along `axis` in the parent's
## space and an element L = T(o) R S T(from - o): M L = L' F, where L' has the
## pivot and from corner reflected and R' = F R F (the rotation about `axis`
## kept, the other two negated), and F reflects the element's own frame. F
## turns the box into the same box (with the from/to ends swapped along
## `axis`), and passes on to the children as a reflection across the middle of
## this element: each child mirrors across size/2 in its parent's frame.

const Geometry = preload("res://core/model/shape_geometry.gd")
const AXES := ["X", "Y", "Z"]


## The fields of `source` mirrored across `plane` (shape units, along `axis`,
## in its parent's frame). `uv_size` gives a texture's UV size by ID, for faces
## that have no UV rectangle of their own.
static func element_fields(source: Dictionary, axis: int, plane: float, uv_size: Callable) -> Dictionary:
	var after := {}
	var start: Array = _vector(source.get("from", [0, 0, 0]))
	var end: Array = _vector(source.get("to", [0, 0, 0]))
	var origin: Array = _vector(source.get("rotationOrigin", [0, 0, 0]))
	var low := 2.0 * plane - float(end[axis])
	var high := 2.0 * plane - float(start[axis])
	start[axis] = low
	end[axis] = high
	origin[axis] = 2.0 * plane - float(origin[axis])
	after.from = start
	after.to = end
	after.rotationOrigin = origin
	for i in range(3):
		var key: String = "rotation" + AXES[i]
		if i != axis and source.has(key) and (source[key] is float or source[key] is int):
			after[key] = 0.0 if float(source[key]) == 0.0 else -float(source[key])
	if source.get("faces") is Dictionary:
		after.faces = faces(source.faces, axis, uv_size)
	# Auto unwrapping would lay the flipped UVs out again.
	if source.get("autoUnwrap") == true:
		after.autoUnwrap = false
	return after


## The plane, in a child's frame (its parent's from corner), across which the
## children of an element mirrored along `axis` mirror: the middle of the box.
static func child_plane(source: Dictionary, axis: int) -> float:
	return (float(_vector(source.get("to", [0, 0, 0]))[axis]) - float(_vector(source.get("from", [0, 0, 0]))[axis])) * 0.5


## An animation pose of a mirrored element: its offset along `axis` and its
## rotations about the other two axes negated (curve handles too).
static func pose(source_pose: Dictionary, axis: int) -> Dictionary:
	var result := source_pose.duplicate(true)
	var negated: Array = ["offset" + AXES[axis]]
	for i in range(3):
		if i != axis:
			negated.append("rotation" + AXES[i])
	for channel in negated:
		if result.get(channel) is float or result.get(channel) is int:
			result[channel] = 0.0 if float(result[channel]) == 0.0 else -float(result[channel])
	var curves: Variant = result.get("editor", {}).get("curves") if result.get("editor") is Dictionary else null
	if curves is Dictionary:
		for channel in negated:
			if curves.get(channel) is Dictionary:
				for side in ["in", "out"]:
					var handle: Variant = curves[channel].get(side)
					if handle is Array and handle.size() == 2 and (handle[1] is float or handle[1] is int):
						handle[1] = -float(handle[1])
	return result


## An attachment point on a mirrored element: its position mirrored across
## the middle of the box, its rotations about the other two axes negated.
static func point_fields(point: Dictionary, source: Dictionary, axis: int) -> Dictionary:
	var size := float(_vector(source.get("to", [0, 0, 0]))[axis]) - float(_vector(source.get("from", [0, 0, 0]))[axis])
	var after := {}
	var key: String = "pos" + AXES[axis]
	after[key] = size - float(point.get(key, 0))
	for i in range(3):
		var rotation: String = "rotation" + AXES[i]
		if i != axis and (point.get(rotation) is float or point.get(rotation) is int) and float(point[rotation]) != 0.0:
			after[rotation] = -float(point[rotation])
	return after


## The faces of a mirrored box: each new face takes the old face it reflects
## from (the two across `axis` swap), with its UV rectangle and rotation chosen
## so every corner shows the texel the reflected corner showed.
static func faces(old_faces: Dictionary, axis: int, uv_size: Callable) -> Dictionary:
	var result := {}
	# Corner correspondences only depend on which corners meet, so a unit box
	# stands in for the real one (which may be flat along an axis).
	var cube: Array = Geometry.corners(Vector3.ONE)
	for new_index in range(6):
		var flip := Vector3.ONE
		flip[axis] = -1
		var old_index: int = Geometry.NORMALS.find(Geometry.NORMALS[new_index] * flip)
		var old_name: String = Geometry.FACES[old_index]
		if not old_faces.get(old_name) is Dictionary:
			continue
		var face: Dictionary = old_faces[old_name].duplicate(true)
		# For each new corner, the old corner it reflects onto.
		var from_old: Array = []
		for k in range(4):
			var point: Vector3 = cube[new_index][k]
			point[axis] = 1.0 - point[axis]
			var found := -1
			for j in range(4):
				if (cube[old_index][j] as Vector3).is_equal_approx(point):
					found = j
			from_old.append(found)
		if from_old.has(-1):
			result[Geometry.FACES[new_index]] = face
			continue
		var uv: Array = face.get("uv") if face.get("uv") is Array and face.uv.size() == 4 else []
		if uv.is_empty():
			var dimensions: Vector2 = uv_size.call(str(face.get("texture", "")).trim_prefix("#")) if uv_size.is_valid() else Vector2(16, 16)
			uv = [0.0, 0.0, dimensions.x, dimensions.y]
		var turns := posmod(roundi(float(face.get("rotation", 0)) / 90.0), 4)
		var old_coords := _coords(old_index, uv)
		var wanted: Array = []
		for k in range(4):
			wanted.append(old_coords[(from_old[k] + turns) % 4])
		var solved := _solve(new_index, uv, wanted, turns)
		if not solved.is_empty():
			face.uv = solved.uv
			if solved.turns * 90 != roundi(float(face.get("rotation", 0))):
				face.rotation = solved.turns * 90
			for field in ["windMode", "windData"]:
				var values: Variant = face.get(field)
				if values is Array and values.size() == 4:
					face[field] = from_old.map(func(j: int): return values[j])
		result[Geometry.FACES[new_index]] = face
	return result


## The UV rectangle (the old one's ends, possibly swapped) and quarter turns
## that put `wanted[k]` on corner k of face `index`; the old turns first.
static func _solve(index: int, uv: Array, wanted: Array, turns: int) -> Dictionary:
	for t in [turns, (turns + 1) % 4, (turns + 2) % 4, (turns + 3) % 4]:
		for swap_u in [false, true]:
			for swap_v in [false, true]:
				var candidate := [uv[2] if swap_u else uv[0], uv[3] if swap_v else uv[1], uv[0] if swap_u else uv[2], uv[1] if swap_v else uv[3]]
				var coords := _coords(index, candidate)
				var fits := true
				for k in range(4):
					if not (coords[(k + t) % 4] as Vector2).is_equal_approx(wanted[k]):
						fits = false
						break
				if fits:
					return {"uv": candidate, "turns": t}
	return {}


## A face's corner UVs before rotation, as the mesh builder lays them out.
static func _coords(index: int, uv: Array) -> Array:
	var u1 := float(uv[0])
	var v1 := float(uv[1])
	var u2 := float(uv[2])
	var v2 := float(uv[3])
	if index == 5:
		return [Vector2(u2, v2), Vector2(u2, v1), Vector2(u1, v1), Vector2(u1, v2)]
	return [Vector2(u1, v1), Vector2(u1, v2), Vector2(u2, v2), Vector2(u2, v1)]


static func _vector(value: Variant) -> Array:
	if value is Array and value.size() == 3:
		return [float(value[0]), float(value[1]), float(value[2])]
	return [0.0, 0.0, 0.0]
