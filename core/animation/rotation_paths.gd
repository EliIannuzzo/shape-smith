extends RefCounted

const GIMBAL_LOCK_TOLERANCE_DEGREES := 0.001
const PATH_SAMPLE_COUNT := 49
const SHORTEST_AXIS_COMBINATIONS := 8
# Prefer smooth angular speed when two paths have nearly equal travel.
const SPEED_VARIATION_WEIGHT := 0.02
const PATH_COST_TOLERANCE := 0.000001

const AXES := ["X", "Y", "Z"]
const AnimationMath = preload("res://core/animation/vs_animation_math.gd")


static func rotation(degrees: Vector3) -> Basis:
	return Basis(Vector3.RIGHT, deg_to_rad(degrees.x)) * Basis(Vector3.UP, deg_to_rad(degrees.y)) * Basis(Vector3.BACK, deg_to_rad(degrees.z))


static func nearest_euler(basis: Basis, reference: Vector3) -> Vector3:
	var target := basis.orthonormalized()
	var principal := target.get_euler(EULER_ORDER_XYZ) * 180.0 / PI
	var candidates: Array[Vector3] = [principal, Vector3(principal.x + 180, 180 - principal.y, principal.z + 180)]
	# At XYZ gimbal lock, X and Z are coupled. Keep either neighboring angle
	# instead of accepting the decomposition's arbitrary zero for the other.
	if absf(absf(principal.y) - 90.0) < GIMBAL_LOCK_TOLERANCE_DEGREES:
		var sign_y := signf(principal.y)
		var coupled := principal.x + sign_y * principal.z
		candidates.append(Vector3(reference.x, principal.y, sign_y * (coupled - reference.x)))
		candidates.append(Vector3(coupled - sign_y * reference.z, principal.y, reference.z))
	var best := principal
	var cost := INF
	for candidate in candidates:
		for i in range(3):
			candidate[i] = reference[i] + wrapf(candidate[i] - reference[i], -180, 180)
		if not rotation(candidate).is_equal_approx(target):
			continue

		var distance := candidate.distance_squared_to(reference)
		if distance < cost:
			best = candidate
			cost = distance
	return best


static func auto_enabled(pose: Dictionary) -> bool:
	return not pose.get("editor") is Dictionary or pose.editor.get("autoShortestRotation", true) != false


static func angles(pose: Dictionary) -> Vector3:
	return Vector3(pose.get("rotationX", 0), pose.get("rotationY", 0), pose.get("rotationZ", 0))


static func has_rotation(pose: Dictionary) -> bool:
	return AXES.any(func(axis: String): return pose.get("rotation" + axis) != null)


static func best_flags(start: Vector3, finish: Vector3) -> int:
	var clip := {"quantityframes": 2, "keyframes": [
		{"frame": 0, "elements": {"shape": {"rotationX": start.x, "rotationY": start.y, "rotationZ": start.z}}},
		{"frame": 1, "elements": {"shape": {"rotationX": finish.x, "rotationY": finish.y, "rotationZ": finish.z}}}]}
	return _best_resolved_flags(AnimationMath.build_track(clip, "shape").rotation, 0, 1, 2, Vector3.ZERO)


static func _best_resolved_flags(keys: Array, start_frame: int, end_frame: int, length: int, base: Vector3) -> int:
	var best := 0
	var best_cost := INF
	var duration := end_frame - start_frame if end_frame > start_frame else length - start_frame + end_frame
	var samples: Array[float] = [0.0, float(duration)]
	for i in range(1, PATH_SAMPLE_COUNT):
		samples.append(duration * float(i) / float(PATH_SAMPLE_COUNT))
	# Include shared-frame boundaries: empty frames can change the actual path.
	for key in keys:
		var distance := posmod(int(key.frame) - start_frame, length)
		if distance > 0 and distance < duration:
			samples.append(float(distance))
	samples.sort()
	for mask in range(SHORTEST_AXIS_COMBINATIONS):
		var previous := rotation(base + AnimationMath.sample(keys, start_frame, length, Vector3.ZERO, true, start_frame, mask)).get_rotation_quaternion()
		var travel := 0.0
		var last_step := 0.0
		var variation := 0.0
		var last_distance := 0.0
		for sample in samples:
			if sample <= last_distance:
				continue

			var time := fposmod(start_frame + sample, length)
			var value := AnimationMath.sample(keys, time, length, Vector3.ZERO, true, start_frame, mask)
			var current := rotation(base + value).get_rotation_quaternion()
			var step := previous.angle_to(current)
			travel += step
			var speed := step / (sample - last_distance)
			if last_distance > 0:
				variation += absf(speed - last_step)
			last_step = speed
			last_distance = sample
			previous = current
		var cost := travel + variation * SPEED_VARIATION_WEIGHT
		if cost < best_cost - PATH_COST_TOLERANCE:
			best_cost = cost
			best = mask
	return best


static func update_neighbors(clip: Dictionary, element: String, time: int, base := Vector3.ZERO) -> void:
	var keys: Array = []
	for key in clip.get("keyframes", []):
		var pose: Variant = key.get("elements", {}).get(element)
		if pose is Dictionary and has_rotation(pose):
			keys.append({"frame": key.frame, "pose": pose})
	keys.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
	if keys.is_empty():
		return

	var changed := -1
	for i in range(keys.size()):
		if keys[i].frame == time:
			changed = i
	# Removing the last rotation property joins the surrounding transition.
	var affected: Array = []
	if changed >= 0:
		affected = [changed, posmod(changed - 1, keys.size())]
	else:
		var preceding := keys.size() - 1
		for i in range(keys.size()):
			if keys[i].frame < time:
				preceding = i
		affected = [preceding]
	for i in affected:
		var pose: Dictionary = keys[i].pose
		if not auto_enabled(pose):
			continue

		var resolved := AnimationMath.build_track(clip, element)
		var length := int(clip.get("quantityframes", clip.get("quantityFrames", 1)))
		var mask := _best_resolved_flags(resolved.rotation, keys[i].frame, keys[(i + 1) % keys.size()].frame, length, base) if keys.size() > 1 else 0
		for axis in range(3):
			var field: String = "rotShortestDistance" + AXES[axis]
			if mask & (1 << axis):
				pose[field] = true
			else:
				pose.erase(field)
