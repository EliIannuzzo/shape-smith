extends RefCounted
## Single-clip VS Animation.GenerateFrameForElement + weighted ElementPose.Add.
const GROUPS := ["offset", "rotation", "stretch"]
const AXES := ["X", "Y", "Z"]


static func build_track(clip: Dictionary, element: String) -> Dictionary:
	var channels := {"offset": [], "rotation": [], "stretch": []}
	var times: Array = []
	for key in clip.get("keyframes", []):
		times.append(int(key.frame))
		var pose: Variant = key.get("elements", {}).get(element)
		if not pose is Dictionary:
			continue

		var flags := [false, false, false]
		for axis in range(3):
			flags[axis] = pose.get("rotShortestDistance" + AXES[axis], false) == true
		for group in GROUPS:
			var value := Vector3.ONE if group == "stretch" else Vector3.ZERO
			var present := false
			for axis in range(3):
				if pose.get(group + AXES[axis]) != null:
					present = true
					value[axis] = float(pose[group + AXES[axis]])
			if present:
				channels[group].append({"frame": int(key.frame), "value": value, "shortest": flags})
	var result := {"offset": [], "rotation": [], "stretch": []}
	if channels.offset.is_empty() and channels.rotation.is_empty() and channels.stretch.is_empty():
		return result

	var length := int(clip.get("quantityframes", clip.get("quantityFrames", 1)))
	var ended: Variant = clip.get("onAnimationEnd", "Repeat")
	var hold := str(ended).to_lower() in ["hold", "1", "1.0"]
	for time in times:
		var values := {"offset": Vector3.ZERO, "rotation": Vector3.ZERO, "stretch": Vector3.ONE}
		var flags := [false, false, false]
		var flag_frame := -1
		# VS copies the shortest flags after EACH present group, in this order.
		# A separate position/stretch key can therefore replace rotation flags.
		for group in GROUPS:
			var resolved := resolve_channel(channels[group], time, length)
			if not resolved.is_empty():
				values[group] = resolved.value
				flags = resolved.shortest
				flag_frame = resolved.frame
		for group in GROUPS:
			result[group].append({"frame": time, "value": values[group], "shortest": flags, "flag_frame": flag_frame, "hold": hold})
	return result


static func resolve_channel(keys: Array, time: int, length: int) -> Dictionary:
	if keys.is_empty():
		return {}

	var right_index := 0
	for i in range(keys.size()):
		if keys[i].frame > time:
			right_index = i
			break
	var right: Dictionary = keys[right_index]
	var left: Dictionary = keys[posmod(right_index - 1, keys.size())]
	var weight := 0.0
	if keys.size() > 1:
		if right.frame < left.frame:
			weight = float(posmod(time - int(left.frame), length)) / (length - left.frame + right.frame)
		else:
			weight = float(time - left.frame) / (right.frame - left.frame)
	return {"value": left.value.lerp(right.value, weight), "shortest": left.shortest, "frame": left.frame}


static func sample(keys: Array, time: float, length: int, fallback: Vector3, angular := false, override_frame := -1, override_mask := -1, blend_weight := 1.0) -> Vector3:
	if keys.is_empty():
		return fallback
	# ClientAnimator chooses the shared segment using the integer frame, then
	# interpolates using the fractional frame. Preserve serialized frame order.
	var left_index := keys.size() - 1
	for i in range(keys.size() - 1, -1, -1):
		if keys[i].frame <= int(time):
			left_index = i
			break
	var left: Dictionary = keys[left_index]
	var right: Dictionary = keys[(left_index + 1) % keys.size()]
	if left.get("hold", false) and int(time) + 1 == length:
		right = left
	var span: float = right.frame - left.frame if right.frame > left.frame else length - left.frame + right.frame
	var distance: float = time - left.frame if time >= left.frame else length - left.frame + time
	var weight := distance / span if span > 0 else 0.0
	var destination: Vector3 = right.value
	if angular:
		for axis in range(3):
			var shortest: bool = left.shortest[axis]
			if override_mask >= 0 and left.get("flag_frame", -1) == override_frame:
				shortest = bool(override_mask & (1 << axis))
			if shortest:
				destination[axis] = left.value[axis] + wrapf(destination[axis] - left.value[axis], -180, 180)
	var result: Vector3 = left.value.lerp(destination, weight)
	if angular:
		# Match ElementPose.Add, including its unweighted shortest-axis branch.
		for axis in range(3):
			var shortest: bool = left.shortest[axis]
			if override_mask >= 0 and left.get("flag_frame", -1) == override_frame:
				shortest = bool(override_mask & (1 << axis))
			if not shortest:
				result[axis] *= blend_weight
		return result

	return fallback + (result - fallback) * blend_weight
