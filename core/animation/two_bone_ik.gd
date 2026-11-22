extends RefCounted
## Analytic two-bone IK (a leg's thigh and shin, an arm's upper arm and
## forearm), in world space.
##
## The upper bone turns about its pivot A, the lower about its pivot B, so the
## lower bone's tip C reaches the target T. The bones stay in the plane
## through A, T and the pole P (where the knee or elbow points). Out of reach,
## the chain straightens towards the target. Rotations only: lengths and the
## pivots' positions are kept, so the result converts exactly back into
## animation rotation keys (see anim_rotation()).

const RotationPaths = preload("res://core/animation/rotation_paths.gd")
const EPSILON := 0.0001


## Solves the chain. All points are world positions; `upper` and `lower` are
## the bones' global transforms. `pole` is null for none (the knee then keeps
## the side it bends to now). Returns {"upper", "lower"}: new global
## transforms, blended from the current ones by `weight` (0 to 1).
static func solve(upper: Transform3D, lower: Transform3D, a: Vector3, b: Vector3, c: Vector3, target: Vector3, pole: Variant = null, weight := 1.0) -> Dictionary:
	var unchanged := {"upper": upper, "lower": lower}
	var upper_length := a.distance_to(b)
	var lower_length := b.distance_to(c)
	var reach := target - a
	if upper_length < EPSILON or lower_length < EPSILON or reach.length() < EPSILON or weight <= 0.0:
		return unchanged
	var u := reach.normalized()
	var distance := clampf(reach.length(), absf(upper_length - lower_length) + EPSILON, upper_length + lower_length - EPSILON)
	# The bend plane: towards the pole, or the side the knee is on now.
	var hint: Vector3 = (pole - a) if pole is Vector3 else (b - a)
	var side := hint - u * hint.dot(u)
	if side.length() < EPSILON:
		side = (b - a) - u * (b - a).dot(u)
	if side.length() < EPSILON:
		side = u.cross(Vector3.UP if absf(u.y) < 0.9 else Vector3.RIGHT)
	side = side.normalized()
	var cos_a := clampf((upper_length * upper_length + distance * distance - lower_length * lower_length) / (2.0 * upper_length * distance), -1.0, 1.0)
	var knee := a + (u * cos_a + side * sqrt(maxf(0.0, 1.0 - cos_a * cos_a))) * upper_length
	var tip := a + u * distance

	# Upper bone: turn the triangle (A, B, C) onto (A, knee, tip).
	var turn_upper := _frame(knee - a, tip - a, side) * _frame(b - a, c - a, hint).inverse()
	turn_upper = Basis(Quaternion().slerp(Quaternion(turn_upper.orthonormalized()), clampf(weight, 0.0, 1.0)))
	var about_a := Transform3D(turn_upper, a - turn_upper * a)
	var new_upper := about_a * upper
	var moved_lower := about_a * lower
	var moved_b := about_a * b
	var moved_c := about_a * c
	# Lower bone: turn its tip onto the solved tip.
	var goal := moved_b + (tip - knee) if weight >= 1.0 else moved_b + (tip - knee).normalized() * lower_length
	var turn_lower := Basis(_arc(moved_c - moved_b, goal - moved_b))
	turn_lower = Basis(Quaternion().slerp(Quaternion(turn_lower), clampf(weight, 0.0, 1.0))) if weight < 1.0 else turn_lower
	var new_lower := Transform3D(turn_lower, moved_b - turn_lower * moved_b) * moved_lower
	return {"upper": new_upper, "lower": new_lower}


## Aim: turns one bone about its pivot `a` so its tip `c` points at the
## target (a head or an eye looking at something), blended by `weight`.
## Returns the bone's new global transform.
static func aim(bone: Transform3D, a: Vector3, c: Vector3, target: Vector3, weight := 1.0) -> Transform3D:
	if weight <= 0.0 or (c - a).length() < EPSILON or (target - a).length() < EPSILON:
		return bone
	var turn := Basis(Quaternion().slerp(_arc(c - a, target - a), clampf(weight, 0.0, 1.0)))
	return Transform3D(turn, a - turn * a) * bone


## Chains of any length (FABRIK): three bones for a hind leg, many for a tail.
##
## `bones` are the chain's global transforms from the root down (each a
## descendant of the one before), `pivots` where each turns, `tip` the end of
## the last bone. Joints are pulled to the target and back to the root until
## they settle, keeping every bone's length. With `planar` (hind legs) the
## joints stay in the plane through the root, the target and the pole, and the
## first joint (the knee) ends on the pole's side, so a zig-zag leg keeps its
## shape; without it (tails) they move freely. Each bone is then turned onto its
## solved direction (the shortest turn, keeping its twist), blended by
## `weight`. Returns the new global transforms, in the same order.
static func solve_chain(bones: Array, pivots: Array, tip: Vector3, target: Vector3, pole: Variant = null, weight := 1.0, planar := false, iterations := 24) -> Array:
	var count := bones.size()
	if count == 0 or count != pivots.size() or weight <= 0.0:
		return bones.duplicate()
	var joints: Array = pivots.duplicate()
	joints.append(tip)
	var lengths: Array = []
	var total := 0.0
	for i in range(count):
		lengths.append((joints[i + 1] as Vector3).distance_to(joints[i]))
		total += lengths[i]
	if total < EPSILON:
		return bones.duplicate()
	var root: Vector3 = joints[0]
	var solved: Array = joints.duplicate()
	var normal := Vector3.ZERO
	if planar:
		var side: Vector3 = (pole - root) if pole is Vector3 else (joints[1] - root)
		normal = (target - root).cross(side)
		if normal.length() < EPSILON:
			normal = (target - root).cross(joints[count] - root)
		normal = normal.normalized() if normal.length() > EPSILON else Vector3.ZERO
	if root.distance_to(target) >= total - EPSILON:
		# Out of reach: straighten towards the target.
		var direction := (target - root).normalized()
		for i in range(count):
			solved[i + 1] = solved[i] + direction * lengths[i]
	else:
		if normal != Vector3.ZERO:
			_onto_plane(solved, root, normal)
		for iteration in range(iterations):
			solved[count] = target
			for i in range(count - 1, -1, -1):
				solved[i] = solved[i + 1] + _towards(solved[i] - solved[i + 1], lengths[i])
			solved[0] = root
			for i in range(count):
				solved[i + 1] = solved[i] + _towards(solved[i + 1] - solved[i], lengths[i])
			if normal != Vector3.ZERO:
				_onto_plane(solved, root, normal)
				for i in range(count):
					solved[i + 1] = solved[i] + _towards(solved[i + 1] - solved[i], lengths[i])
			if (solved[count] as Vector3).distance_to(target) < 0.00001:
				break
		# The knee goes the way the pole says: mirror the bends otherwise.
		if planar and pole is Vector3 and count >= 2:
			var axis := (target - root).normalized()
			var knee: Vector3 = solved[1] - root
			var knee_side := knee - axis * knee.dot(axis)
			var pole_side: Vector3 = (pole - root) - axis * (pole - root).dot(axis)
			if knee_side.dot(pole_side) < 0.0:
				for i in range(1, count):
					var offset: Vector3 = solved[i] - root
					var along := axis * offset.dot(axis)
					solved[i] = root + along - (offset - along)
	# Turn each bone onto its solved direction; later bones move with it.
	var result: Array = bones.duplicate()
	var current: Array = joints.duplicate()
	for i in range(count):
		var turn := Quaternion().slerp(_arc(current[i + 1] - current[i], solved[i + 1] - current[i]), clampf(weight, 0.0, 1.0))
		var about := Transform3D(Basis(turn), current[i] - Basis(turn) * current[i])
		for j in range(i, count):
			result[j] = about * result[j]
		for j in range(i + 1, count + 1):
			current[j] = about * current[j]
	return result


static func _towards(direction: Vector3, length: float) -> Vector3:
	return direction.normalized() * length if direction.length() > EPSILON else Vector3.UP * length


static func _onto_plane(joints: Array, origin: Vector3, normal: Vector3) -> void:
	for i in range(1, joints.size() - 1):
		var offset: Vector3 = joints[i] - origin
		joints[i] = joints[i] - normal * offset.dot(normal)


## An orthonormal frame whose x axis is `along` and whose xy plane holds `toward`.
static func _frame(along: Vector3, toward: Vector3, fallback: Vector3) -> Basis:
	var x := along.normalized()
	var z := x.cross(toward)
	if z.length() < EPSILON:
		z = x.cross(fallback)
	if z.length() < EPSILON:
		z = x.cross(Vector3.UP if absf(x.y) < 0.9 else Vector3.RIGHT)
	z = z.normalized()
	return Basis(x, z.cross(x), z)


## The shortest rotation taking direction `from` to direction `to`.
static func _arc(from: Vector3, to: Vector3) -> Quaternion:
	var f := from.normalized()
	var t := to.normalized()
	if f.length() < EPSILON or t.length() < EPSILON:
		return Quaternion()
	var d := f.dot(t)
	if d > 1.0 - EPSILON:
		return Quaternion()
	if d < -1.0 + EPSILON:
		var axis := f.cross(Vector3.RIGHT)
		if axis.length() < EPSILON:
			axis = f.cross(Vector3.UP)
		return Quaternion(axis.normalized(), PI)
	return Quaternion(f.cross(t).normalized(), acos(d))


## Where an element turns when animated, in world space: its rotation origin
## for animation version 0, its own origin (the from corner, moved by the
## animated offset) for version 1. `offset` is the animated offset in blocks.
static func pivot_world(node: Node3D, source: Dictionary, version: int, offset := Vector3.ZERO) -> Vector3:
	if version == 1:
		return node.global_transform.origin
	var pivot := _vector(source.get("rotationOrigin", [0, 0, 0])) / 16.0
	var start := _vector(source.get("from", [0, 0, 0])) / 16.0
	# The node's frame has the from corner, moved by the offset, at its origin.
	return node.global_transform * (pivot - start - offset)


## The animation rotation (degrees) that gives an element the local transform
## `local`, near `reference` so the curve does not jump a whole turn.
static func anim_rotation(source: Dictionary, local: Transform3D, stretch: Vector3, reference: Vector3, version: int) -> Vector3:
	var base_rotation := Vector3(_number(source.get("rotationX")), _number(source.get("rotationY")), _number(source.get("rotationZ")))
	var base_scale := Vector3(_number(source.get("scaleX"), 1.0), _number(source.get("scaleY"), 1.0), _number(source.get("scaleZ"), 1.0))
	if version == 1:
		var base := Basis.from_scale(base_scale) * _rotation_basis(base_rotation)
		return RotationPaths.nearest_euler(Basis.from_scale(Vector3.ONE / stretch) * base.inverse() * local.basis, reference)
	return RotationPaths.nearest_euler(local.basis * Basis.from_scale(Vector3.ONE / (base_scale * stretch)), base_rotation + reference) - base_rotation


static func _rotation_basis(degrees: Vector3) -> Basis:
	return Basis(Vector3.RIGHT, deg_to_rad(degrees.x)) * Basis(Vector3.UP, deg_to_rad(degrees.y)) * Basis(Vector3.BACK, deg_to_rad(degrees.z))


static func _vector(value: Variant) -> Vector3:
	return Vector3(_number(value[0]), _number(value[1]), _number(value[2])) if value is Array and value.size() == 3 else Vector3.ZERO


static func _number(value: Variant, fallback := 0.0) -> float:
	return float(value) if (value is float or value is int) and is_finite(float(value)) else fallback
