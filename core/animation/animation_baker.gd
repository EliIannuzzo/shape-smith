extends RefCounted

const Math = preload("res://core/animation/vs_animation_math.gd")
const Curves = preload("res://core/animation/channel_curves.gd")
const Limits = preload("res://core/model/shape_limits.gd")
const GROUPS := ["offset", "rotation", "stretch"]
const AXES := ["X", "Y", "Z"]
const CURVES := ["linear", "ease_in", "ease_out", "ease_in_out", "hold"]
const CURVE_LABELS := ["Linear", "Ease In", "Ease Out", "Ease In/Out", "Hold"]
const DEFAULT_SETTINGS := {
	"reduction": "auto", "frameInterval": 1,
	"positionTolerance": 0.01, "rotationTolerance": 0.1, "scaleTolerance": 0.001,
}
const MAX_SAMPLED_POSES := 500000
const EXACT_TOLERANCE := 0.000000001


static func settings(data: Dictionary) -> Dictionary:
	var result := DEFAULT_SETTINGS.duplicate()
	var marker: Variant = data.get("shapesmith", {})
	var stored: Variant = marker.get("exportSettings", {}) if marker is Dictionary else {}
	if stored is Dictionary:
		for key in result:
			if stored.has(key):
				result[key] = stored[key]
	return validated_settings(result)


static func validated_settings(value: Dictionary) -> Dictionary:
	var result := DEFAULT_SETTINGS.duplicate()
	if value.get("reduction") in ["auto", "custom", "off"]:
		result.reduction = value.reduction
	var interval: Variant = value.get("frameInterval", 1)
	if (interval is int or interval is float) and is_finite(interval):
		result.frameInterval = clampi(int(interval), 1, 120)
	for key in ["positionTolerance", "rotationTolerance", "scaleTolerance"]:
		var number: Variant = value.get(key)
		if (number is int or number is float) and is_finite(number) and number >= 0:
			result[key] = minf(number, Limits.MAX_COORDINATE)
	return result


static func curve(pose: Dictionary, group: String) -> String:
	var editor: Variant = pose.get("editor", {})
	var interpolation: Variant = editor.get("interpolation", {}) if editor is Dictionary else {}
	var value: Variant = interpolation.get(group, "linear") if interpolation is Dictionary else "linear"
	return value if value in CURVES else "linear"


static func has_curves(clip: Dictionary) -> bool:
	if not clip.get("keyframes", []) is Array:
		return false
	for key in clip.get("keyframes", []):
		if not key is Dictionary or not key.get("elements", {}) is Dictionary:
			continue
		for pose in key.get("elements", {}).values():
			if pose is Dictionary:
				for group in GROUPS:
					if (curve(pose, group) != "linear" or own_curve(pose, group)) and _has_group(pose, group):
						return true
	return false


## True when a pose gives any axis of `group` its own curve (graph editor).
static func own_curve(pose: Dictionary, group: String) -> bool:
	var editor: Variant = pose.get("editor")
	var curves: Variant = editor.get("curves") if editor is Dictionary else null
	return curves is Dictionary and AXES.any(func(axis: String): return curves.get(group + axis) is Dictionary)


static func curve_weight(kind: String, weight: float) -> float:
	match kind:
		"ease_in":
			return weight * weight
		"ease_out":
			return 1.0 - (1.0 - weight) * (1.0 - weight)
		"ease_in_out":
			return weight * weight * (3.0 - 2.0 * weight)
		"hold":
			return 0.0 if weight < 1.0 else 1.0
	return weight


static func bake_shape(data: Dictionary, options: Dictionary) -> Dictionary:
	var output := data.duplicate(true)
	var generated: Array = []
	var added := 0
	var removed := 0
	var support := 0
	var clips: Variant = output.get("animations", [])
	if not clips is Array:
		return {"data": output, "generated": [], "added": 0, "removed": 0, "error": ""}
	for index in range(clips.size()):
		if not clips[index] is Dictionary:
			continue
		var baked := bake_clip(clips[index], options)
		if not baked.error.is_empty():
			return {"error": baked.error}
		clips[index] = baked.clip
		generated.append({"animation": index, "keyframes": baked.generated})
		added += baked.added
		removed += baked.removed
		support += baked.support
	return {"data": output, "generated": generated, "added": added, "removed": removed, "support": support, "error": ""}


static func bake_clip(source: Dictionary, options: Dictionary) -> Dictionary:
	var result := {"clip": source.duplicate(true), "generated": [], "added": 0, "removed": 0, "support": 0, "error": ""}
	if not has_curves(source):
		return result
	result.error = validation_error(source)
	if not result.error.is_empty():
		return result
	var length := int(source.get("quantityframes", source.get("quantityFrames", 0)))
	if length < 1:
		result.error = "Cannot bake an animation without a positive duration."
		return result
	var config := validated_settings(options)
	var ordered := source.duplicate(true)
	ordered.keyframes.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
	var tracks := _collect_tracks(ordered)
	var authored := {}
	for key in source.get("keyframes", []):
		var time := int(key.get("frame", -1))
		if time < 0 or time >= length or authored.has(time):
			result.error = "Cannot bake duplicate or out-of-range authored frames."
			return result
		authored[time] = key
	var times := {}
	var curved := _curved_tracks(tracks, _loops(source))
	if curved.is_empty():
		return result
	for time in range(0, length, config.frameInterval):
		if _has_active_curve(curved, time, length, _loops(source)):
			times[time] = true
	for time in [0, length - 1]:
		if _has_active_curve(curved, time, length, _loops(source)):
			times[time] = true
	for time in authored:
		times[time] = true
	if times.size() * tracks.size() > MAX_SAMPLED_POSES:
		result.error = "Animation bake is too large. Increase the bake interval or split the animation."
		return result
	var samples: Array = times.keys()
	samples.sort()
	var values: Array = []
	for time in samples:
		values.append(_sample_pose_tracks(tracks, time, length, source))
	var kept := _reduce(samples, values, authored, config)
	var frames: Array = []
	for index in kept:
		var time: int = samples[index]
		var key: Dictionary = authored.get(time, {"frame": time, "elements": {}}).duplicate(true)
		if not key.has("elements"):
			key.elements = {}
		for name in tracks:
			var pose: Dictionary = key.elements.get(name, {}).duplicate(true)
			for group in values[index][name]:
				var vector: Vector3 = values[index][name][group]
				for axis in range(3):
					pose[group + AXES[axis]] = vector[axis]
			if values[index][name].has("rotation"):
				for axis in range(3):
					pose["rotShortestDistance" + AXES[axis]] = false
			key.elements[name] = pose
		frames.append(key)
	_set_loop_flags(frames, tracks, length, source)
	var reference := source.duplicate(true)
	reference.keyframes = frames
	var sparse := _sparse_frames(source, frames, curved, length)
	result.support = _preserve_shared_tracks(source, reference, sparse, tracks, curved, length)
	frames = sparse
	for key in frames:
		var authored_poses: Dictionary = authored.get(int(key.frame), {}).get("elements", {})
		var generated := {}
		for name in key.elements:
			if curved.has(name) and not authored_poses.has(name) and _has_active_curve({name: curved[name]}, int(key.frame), length, _loops(source)):
				generated[name] = key.elements[name].duplicate(true)
		if not generated.is_empty():
			result.generated.append({"frame": key.frame, "elements": generated})
	result.clip.keyframes = frames
	for key in result.generated:
		result.added += key.elements.size()
	var candidates := 0
	for time in samples:
		for name in curved:
			if not authored.get(time, {}).get("elements", {}).has(name) and _has_active_curve({name: curved[name]}, time, length, _loops(source)):
				candidates += 1
	result.removed = maxi(0, candidates - result.added)
	return result


static func _curved_tracks(tracks: Dictionary, loop: bool) -> Dictionary:
	var result := {}
	for name in tracks:
		for group in tracks[name]:
			var track: Dictionary = tracks[name][group]
			for index in range(track.authored.size()):
				if track.authored.size() > 1 and (track.authored[index].curve != "linear" or track.authored[index].custom) and (loop or index < track.authored.size() - 1):
					if not result.has(name):
						result[name] = {}
					result[name][group] = track
	return result


static func _active_curve(track: Dictionary, time: int, length: int, loop: bool) -> bool:
	var keys: Array = track.authored
	for index in range(keys.size()):
		if (keys[index].curve == "linear" and not keys[index].custom) or (not loop and index == keys.size() - 1):
			continue
		var next: int = keys[(index + 1) % keys.size()].frame
		var span := posmod(next - int(keys[index].frame), length)
		if posmod(time - int(keys[index].frame), length) <= span:
			return true
	return false


static func _has_active_curve(curved: Dictionary, time: int, length: int, loop: bool) -> bool:
	for groups in curved.values():
		for track in groups.values():
			if _active_curve(track, time, length, loop):
				return true
	return false


static func _sparse_frames(source: Dictionary, baked: Array, curved: Dictionary, length: int) -> Array:
	var records := {}
	for key in source.keyframes:
		records[int(key.frame)] = key.duplicate(true)
	for key in baked:
		var time := int(key.frame)
		for name in curved:
			for group in curved[name]:
				if not _active_curve(curved[name][group], time, length, _loops(source)):
					continue
				if not records.has(time):
					records[time] = {"frame": time, "elements": {}}
				if not records[time].has("elements"):
					records[time].elements = {}
				if not records[time].elements.has(name):
					records[time].elements[name] = {}
				var pose: Dictionary = records[time].elements[name]
				for axis in AXES:
					pose[group + axis] = key.elements[name][group + axis]
					if group == "rotation":
						pose["rotShortestDistance" + axis] = key.elements[name].get("rotShortestDistance" + axis, false)
	var result: Array = records.values()
	result.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
	return result


static func _preserve_shared_tracks(source: Dictionary, reference: Dictionary, frames: Array, tracks: Dictionary, curved: Dictionary, length: int) -> int:
	var candidate := source.duplicate(true)
	candidate.keyframes = frames
	var support := {}
	var authored := {}
	for key in source.keyframes:
		authored[int(key.frame)] = key.get("elements", {})
	var probes: Array = []
	var times: Array = reference.keyframes.map(func(key: Dictionary): return int(key.frame))
	for index in range(times.size()):
		probes.append(float(times[index]))
		var next: int = times[index + 1] if index + 1 < times.size() else length + int(times[0])
		probes.append(fposmod((times[index] + next) * 0.5, length))
	for name in tracks:
		var original := Math.build_track(source, name)
		var baked := Math.build_track(reference, name)
		for group in ["offset", "stretch", "rotation"]:
			if not tracks[name].has(group):
				continue
			var expected: Array = baked[group] if curved.get(name, {}).has(group) else original[group]
			var actual: Array = Math.build_track(candidate, name)[group]
			if _channels_match(expected, actual, probes, length, group):
				continue
			# Shared frame boundaries can change a sparse rotation's shortest path.
			# These runtime compatibility samples are separate from curve in-betweens.
			for time in times:
				var record: Dictionary = {}
				for key in frames:
					if int(key.frame) == time:
						record = key
						break
				if record.is_empty():
					record = {"frame": time, "elements": {}}
					frames.append(record)
				if not record.has("elements"):
					record.elements = {}
				if not record.elements.has(name):
					record.elements[name] = {}
				var fallback := Vector3.ONE if group == "stretch" else Vector3.ZERO
				var value: Vector3 = Math.sample(expected, time, length, fallback, group == "rotation")
				for axis in range(3):
					record.elements[name][group + AXES[axis]] = value[axis]
					if group == "rotation":
						record.elements[name]["rotShortestDistance" + AXES[axis]] = _flags_at(expected, time)[axis]
				if not curved.has(name) and not _has_group(authored.get(time, {}).get(name, {}), group):
					support["%s:%d" % [name, time]] = true
	frames.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
	return support.size()


static func _flags_at(keys: Array, time: int) -> Array:
	var left: Dictionary = keys[-1]
	for key in keys:
		if key.frame <= time:
			left = key
	return left.shortest


static func _channels_match(expected: Array, actual: Array, probes: Array, length: int, group: String) -> bool:
	var fallback := Vector3.ONE if group == "stretch" else Vector3.ZERO
	for time in probes:
		for weight in [1.0, 0.35]:
			var a: Vector3 = Math.sample(expected, time, length, fallback, group == "rotation", -1, -1, weight)
			var b: Vector3 = Math.sample(actual, time, length, fallback, group == "rotation", -1, -1, weight)
			if not a.is_equal_approx(b):
				return false
	return true


static func validation_error(source: Dictionary) -> String:
	var duration: Variant = source.get("quantityframes", source.get("quantityFrames"))
	if not (duration is int or duration is float) or not is_finite(duration) or duration < 1 or duration > Limits.MAX_ANIMATION_FRAMES or duration != floor(duration):
		return "Cannot bake an animation with an invalid duration."
	if not source.get("keyframes") is Array or source.keyframes.is_empty():
		return "An exported animation needs at least one keyframe."
	var seen := {}
	for key in source.get("keyframes", []):
		if not key is Dictionary or not (key.get("frame") is int or key.get("frame") is float):
			return "Cannot bake an animation with a malformed keyframe."
		var time: float = key.frame
		if not is_finite(time) or time != floor(time) or time < 0 or time >= duration or seen.has(int(time)):
			return "Cannot bake duplicate or out-of-range authored frames."
		seen[int(time)] = true
		if not key.get("elements", {}) is Dictionary:
			return "Cannot bake malformed keyframe elements."
		for pose in key.get("elements", {}).values():
			if not pose is Dictionary:
				return "Cannot bake a malformed element pose."
			for group in GROUPS:
				for axis in AXES:
					var value: Variant = pose.get(group + axis)
					if value != null and (not (value is int or value is float) or not is_finite(value) or absf(value) > Limits.MAX_COORDINATE):
						return "Cannot bake nonnumeric or out-of-range transforms."
	return ""


static func _has_group(pose: Dictionary, group: String) -> bool:
	return AXES.any(func(axis: String): return pose.get(group + axis) != null)


static func _collect_tracks(source: Dictionary) -> Dictionary:
	var result := {}
	for key in source.get("keyframes", []):
		for name in key.get("elements", {}):
			if not result.has(name):
				result[name] = {}
	for name in result:
		var resolved := Math.build_track(source, name)
		for group in GROUPS:
			if resolved[group].is_empty():
				continue
			var authored: Array = []
			for key in source.keyframes:
				var pose: Dictionary = key.get("elements", {}).get(name, {})
				if _has_group(pose, group):
					authored.append({"frame": int(key.frame), "curve": curve(pose, group), "custom": own_curve(pose, group)})
			authored.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
			var track := {"keys": resolved[group], "authored": authored}
			# Axes with their own curves are evaluated as beziers, each on its own.
			if authored.any(func(entry: Dictionary): return entry.custom):
				track.axes = {}
				for axis in range(3):
					var channel := Curves.channel(source, name, group + AXES[axis])
					if Curves.has_own_curves(channel.keys):
						channel.handles = Curves.handles(channel.keys, channel.length, channel.loop, channel.cycle)
						track.axes[axis] = channel
			if group == "rotation":
				_build_rotation_lift(track)
			result[name][group] = track
	for name in result.keys():
		if result[name].is_empty():
			result.erase(name)
	return result


static func _rotation_delta(left: Dictionary, right: Dictionary) -> Vector3:
	var delta: Vector3 = right.value - left.value
	for axis in range(3):
		if left.shortest[axis]:
			delta[axis] = wrapf(delta[axis], -180.0, 180.0)
	return delta


static func _build_rotation_lift(track: Dictionary) -> void:
	var keys: Array = track.keys
	var lifted: Array[Vector3] = [keys[0].value]
	for index in range(1, keys.size()):
		lifted.append(lifted[-1] + _rotation_delta(keys[index - 1], keys[index]))
	track.lifted = lifted
	track.cycle = lifted[-1] + _rotation_delta(keys[-1], keys[0]) - lifted[0]


static func _curve_time(track: Dictionary, time: float, length: int, loop: bool) -> float:
	var keys: Array = track.authored
	if keys.size() < 2:
		return time
	var local_time := fposmod(time, length)
	var index := keys.size() - 1
	for candidate in range(keys.size()):
		if keys[candidate].frame <= local_time:
			index = candidate
	var left: Dictionary = keys[index]
	var right: Dictionary = keys[(index + 1) % keys.size()]
	if left.curve == "linear" or (index == keys.size() - 1 and not loop):
		return time
	var start: float = left.frame
	if local_time < start:
		start -= length
	var span: float = right.frame - left.frame if right.frame > left.frame else length - left.frame + right.frame
	var weight := (local_time - start) / span
	return floorf(time / length) * length + start + curve_weight(left.curve, weight) * span


static func _sample_rotation(track: Dictionary, time: float, length: int) -> Vector3:
	var local_time := fposmod(time, length)
	var keys: Array = track.keys
	var index := keys.size() - 1
	for candidate in range(keys.size()):
		if keys[candidate].frame <= int(local_time):
			index = candidate
	var left: Dictionary = keys[index]
	var right: Dictionary = keys[(index + 1) % keys.size()]
	var cycle: Vector3 = track.cycle
	var value: Vector3 = track.lifted[index]
	if local_time < keys[0].frame:
		value -= cycle
	if not (left.get("hold", false) and int(local_time) + 1 == length):
		var span: float = right.frame - left.frame if right.frame > left.frame else length - left.frame + right.frame
		var distance: float = local_time - left.frame if local_time >= left.frame else length - left.frame + local_time
		value += _rotation_delta(left, right) * (distance / span if span > 0 else 0.0)
	return value + cycle * floorf(time / length)


static func _loops(source: Dictionary) -> bool:
	var ending: Variant = source.get("onAnimationEnd", "Repeat")
	return ending == 0 if ending is int or ending is float else str(ending).to_lower() in ["repeat", "0"]


static func _sample_pose_tracks(tracks: Dictionary, time: float, length: int, source: Dictionary) -> Dictionary:
	var result := {}
	for name in tracks:
		result[name] = {}
		for group in tracks[name]:
			var track: Dictionary = tracks[name][group]
			var sample_time := _curve_time(track, time, length, _loops(source))
			if group == "rotation":
				result[name][group] = _sample_rotation(track, sample_time, length)
			else:
				var fallback := Vector3.ONE if group == "stretch" else Vector3.ZERO
				result[name][group] = Math.sample(track.keys, fposmod(sample_time, length), length, fallback)
			for axis in track.get("axes", {}):
				var channel: Dictionary = track.axes[axis]
				var value: Vector3 = result[name][group]
				value[axis] = Curves.sample(channel.keys, channel.handles, time, length, channel.loop, channel.cycle)
				result[name][group] = value
	return result


static func _reduce(times: Array, values: Array, authored: Dictionary, options: Dictionary) -> Array:
	if options.reduction == "off":
		return range(times.size())
	var tolerances: Dictionary = options if options.reduction == "custom" else DEFAULT_SETTINGS
	var tolerance := {
		"offset": maxf(tolerances.positionTolerance, EXACT_TOLERANCE),
		"rotation": maxf(tolerances.rotationTolerance, EXACT_TOLERANCE),
		"stretch": maxf(tolerances.scaleTolerance, EXACT_TOLERANCE),
	}
	var keep := {0: true, times.size() - 1: true}
	for index in range(times.size()):
		if authored.has(times[index]):
			keep[index] = true
	var anchors: Array = keep.keys()
	anchors.sort()
	var pending: Array = []
	for index in range(anchors.size() - 1):
		pending.append(Vector2i(anchors[index], anchors[index + 1]))
	while not pending.is_empty():
		var segment: Vector2i = pending.pop_back()
		var worst := -1
		var error := 1.0
		for index in range(segment.x + 1, segment.y):
			var weight := float(times[index] - times[segment.x]) / float(times[segment.y] - times[segment.x])
			var score := _segment_error(values[segment.x], values[segment.y], values[index], weight, tolerance)
			if score > error:
				error = score
				worst = index
		if worst >= 0:
			keep[worst] = true
			pending.append(Vector2i(segment.x, worst))
			pending.append(Vector2i(worst, segment.y))
	var result: Array = keep.keys()
	result.sort()
	return result


static func _segment_error(left: Dictionary, right: Dictionary, actual: Dictionary, weight: float, tolerance: Dictionary) -> float:
	var error := 0.0
	for name in actual:
		for group in actual[name]:
			var start: Vector3 = left[name][group]
			var end: Vector3 = right[name][group]
			var difference: Vector3 = (start.lerp(end, weight) - actual[name][group]).abs()
			error = maxf(error, maxf(difference.x, maxf(difference.y, difference.z)) / tolerance[group])
	return error


static func _set_loop_flags(frames: Array, tracks: Dictionary, length: int, source: Dictionary) -> void:
	if frames.size() < 2:
		return
	var last: Dictionary = frames[-1].elements
	var desired := _sample_pose_tracks(tracks, length, length, source)
	for name in tracks:
		if not tracks[name].has("rotation"):
			continue
		for axis in range(3):
			var field: String = "rotation" + AXES[axis]
			var raw: float = frames[0].elements[name][field] - last[name][field]
			var expected: float = desired[name].rotation[axis] - last[name][field]
			last[name]["rotShortestDistance" + AXES[axis]] = absf(wrapf(raw, -180, 180) - expected) < absf(raw - expected)
