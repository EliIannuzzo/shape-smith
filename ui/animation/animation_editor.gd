extends RefCounted
const Limits = preload("res://core/model/shape_limits.gd")

signal changed(index: int, frame: float)
signal rejected(message: String)
signal keyframes_moved(selection: Array)
const STOPPED := ["PlayTillEnd", "Rewind", "Stop", "EaseOut"]
const ENDED := ["Repeat", "Hold", "Stop", "EaseOut"]
const RotationPaths = preload("res://core/animation/rotation_paths.gd")
const Baker = preload("res://core/animation/animation_baker.gd")
const ReplaceClip = preload("res://core/commands/replace_clip.gd")
const InsertClip = preload("res://core/commands/insert_clip.gd")
const RemoveClip = preload("res://core/commands/remove_clip.gd")
const POSE_METADATA_FIELDS := ["rotShortestDistanceX", "rotShortestDistanceY", "rotShortestDistanceZ", "editor"]
var data: Dictionary = {}
var history
var keyframe_clipboard: Array = []


func bind(value: Dictionary, edit_history) -> void:
	keyframe_clipboard.clear()
	data = value
	history = edit_history


func clips() -> Array:
	return data.get("animations", []) if data.get("animations", []) is Array else []


func effective_code(clip: Dictionary) -> String:
	return str(clip.get("name", "")) if clip.get("code") == null else str(clip.code)


func minimum_duration(clip: Dictionary) -> int:
	var minimum := 1
	if not clip.get("keyframes", []) is Array:
		return minimum

	for key in clip.get("keyframes", []):
		if _empty_keyframe(key):
			continue

		if key is Dictionary and (key.get("frame") is float or key.get("frame") is int):
			minimum = maxi(minimum, int(key.frame) + 1)
	return minimum


func _empty_keyframe(key: Variant) -> bool:
	if not key is Dictionary or not key.get("elements", {}) is Dictionary:
		return false

	return key.get("elements", {}).values().all(_empty_pose)


func _empty_pose(pose: Variant) -> bool:
	return pose is Dictionary and pose.keys().all(func(field: String): return field in POSE_METADATA_FIELDS)


func _prune_deleted_frames(clip: Dictionary, affected_frames: Array) -> void:
	var frames: Array = clip.get("keyframes", [])
	for index in range(frames.size() - 1, -1, -1):
		var key: Dictionary = frames[index]
		if not affected_frames.has(int(key.frame)):
			continue

		var poses: Dictionary = key.get("elements", {})
		for element in poses.keys():
			if _empty_pose(poses[element]):
				poses.erase(element)
		if poses.is_empty():
			frames.remove_at(index)

	# The playback evaluator needs one frame even when the clip has no poses.
	if frames.is_empty():
		frames.append({"frame": 0, "elements": {}})
	clip.keyframes = frames


func set_property(index: int, property: String, value: Variant, frame := 0.0) -> bool:
	if index < 0 or index >= clips().size() or not clips()[index] is Dictionary:
		return false

	var source: Dictionary = clips()[index]
	if property in ["name", "code"]:
		value = str(value).strip_edges()
		if value.is_empty():
			rejected.emit("Animation %s cannot be empty." % property)
			return false

		if property == "code" and _code_exists(value, index):
			rejected.emit("That animation code is already in use. Choose a unique code.")
			return false

		if property == "name" and _name_exists(value, index):
			rejected.emit("That animation name is already in use. Choose a unique name.")
			return false
	elif property == "quantityframes":
		if int(value) < minimum_duration(source) or int(value) > Limits.MAX_ANIMATION_FRAMES:
			rejected.emit("Duration must be between %d and 100,000 frames. Existing keyframes are kept." % minimum_duration(source))
			return false

		value = int(value)
	elif property == "onActivityStopped":
		if not value in STOPPED:
			return false
	elif property == "onAnimationEnd":
		if not value in ENDED:
			return false
	else:
		return false

	if source.get(property) == value:
		return true

	var clip := source.duplicate(true)
	# An omitted code defaults to Name in VS. Renaming the display name must not
	# silently change the animation's effective identifier or external references.
	if property == "name" and clip.get("code") == null:
		clip.code = effective_code(source)
	clip[property] = value
	if property == "quantityframes":
		clip.erase("quantityFrames")
		if clip.get("keyframes") is Array:
			clip.keyframes = clip.keyframes.filter(func(key: Variant):
				return not (_empty_keyframe(key) and (key.get("frame") is float or key.get("frame") is int) and key.frame >= value))

			if clip.keyframes.is_empty():
				clip.keyframes.append({"frame": 0, "elements": {}})
	var view := {"index": index, "frame": frame}
	return _replace("Change Animation " + {"name": "Name", "code": "Code", "quantityframes": "Duration", "onActivityStopped": "On Stopped", "onAnimationEnd": "On Ended"}[property], index, clip, view, view)


func create(index := -1, frame := 0.0) -> bool:
	if data.is_empty():
		return false

	var clip := {"name": _unique_name("New Animation"), "code": _unique_code("new-animation"),
		"quantityframes": 30, "version": 0, "onActivityStopped": "Rewind", "onAnimationEnd": "Repeat",
		"keyframes": [{"frame": 0, "elements": {}}]}
	var at := clips().size()
	return _run(InsertClip.new(data, at, clip, "New Animation", _notify, {"index": at, "frame": 0.0}, {"index": index, "frame": frame}))


func delete(index: int, frame := 0.0) -> bool:
	if index < 0 or index >= clips().size():
		return false

	var next := mini(index, clips().size() - 2)
	return _run(RemoveClip.new(data, index, "Delete Animation", _notify, {"index": next, "frame": 0.0}, {"index": index, "frame": frame}))


func duplicate(index: int, frame := 0.0) -> bool:
	if index < 0 or index >= clips().size() or not clips()[index] is Dictionary:
		return false

	var copy: Dictionary = clips()[index].duplicate(true)
	var original_code := effective_code(copy)
	copy.name = _unique_name(str(copy.get("name", "Animation")) + " Copy")
	copy.code = _unique_code(original_code + "-copy")
	return _run(InsertClip.new(data, index + 1, copy, "Duplicate Animation", _notify, {"index": index + 1, "frame": 0.0}, {"index": index, "frame": frame}))


## Commits an edited copy of one clip. Views are {index, frame[, selection]}:
## what the panel shows after the edit and after its undo.
func _replace(label: String, index: int, clip: Dictionary, view_after: Dictionary, view_before: Dictionary) -> bool:
	return _run(ReplaceClip.new(data, index, clip, label, _notify, view_after, view_before))


func _run(command) -> bool:
	return history.execute(command) if history != null else command.do()


func _notify(view: Dictionary) -> void:
	changed.emit(int(view.index), float(view.frame))
	if view.has("selection"):
		keyframes_moved.emit(view.selection.duplicate(true))


func _code_exists(code: String, except := -1) -> bool:
	for i in range(clips().size()):
		if i != except and clips()[i] is Dictionary and effective_code(clips()[i]).to_lower() == code.to_lower():
			return true

	return false


func _unique_code(base: String) -> String:
	var code := base
	var suffix := 2
	while _code_exists(code):
		code = "%s-%d" % [base, suffix]
		suffix += 1
	return code


func _unique_name(base: String) -> String:
	var name := base
	var suffix := 2
	while _name_exists(name):
		name = "%s %d" % [base, suffix]
		suffix += 1
	return name


func _name_exists(name: String, except := -1) -> bool:
	for i in range(clips().size()):
		if i != except and clips()[i] is Dictionary and str(clips()[i].get("name", effective_code(clips()[i]))).strip_edges().to_lower() == name.to_lower():
			return true

	return false


func set_keyframe_property(index: int, time: int, element: String, property: String, enabled: bool, value: Variant) -> bool:
	if index < 0 or index >= clips().size() or not clips()[index] is Dictionary:
		return false

	var numeric := property in ["offsetX", "offsetY", "offsetZ", "rotationX", "rotationY", "rotationZ", "stretchX", "stretchY", "stretchZ"]
	var flag := property in ["rotShortestDistanceX", "rotShortestDistanceY", "rotShortestDistanceZ"]
	var auto := property == "autoShortestRotation"
	var interpolation := property.begins_with("interpolation:")
	var group := property.trim_prefix("interpolation:")
	if interpolation and (group not in Baker.GROUPS or value not in Baker.CURVES):
		return false
	if not numeric and not flag and not auto and not interpolation:
		return false

	if numeric and (not (value is int or value is float) or not is_finite(float(value)) or absf(float(value)) > Limits.MAX_COORDINATE):
		return false

	var clip: Dictionary = clips()[index].duplicate(true)
	for key in clip.get("keyframes", []):
		if key.frame != time or not key.get("elements", {}).get(element) is Dictionary:
			continue

		var pose: Dictionary = key.elements[element]
		if interpolation:
			if not Baker.AXES.any(func(axis: String): return pose.get(group + axis) != null):
				return false
			if Baker.curve(pose, group) == value:
				return true
			if not pose.get("editor") is Dictionary:
				pose.editor = {}
			if not pose.editor.get("interpolation") is Dictionary:
				pose.editor.interpolation = {}
			if value == "linear":
				pose.editor.interpolation.erase(group)
				if pose.editor.interpolation.is_empty():
					pose.editor.erase("interpolation")
				if pose.editor.is_empty():
					pose.erase("editor")
			else:
				pose.editor.interpolation[group] = value
		elif auto:
			if not pose.get("editor") is Dictionary:
				pose.editor = {}
			pose.editor.autoShortestRotation = bool(value)
		elif flag:
			if pose.get(property, false) == bool(value):
				return true

			pose[property] = bool(value)
			if not pose.get("editor") is Dictionary:
				pose.editor = {}
			pose.editor.autoShortestRotation = false
		elif enabled:
			if pose.get(property) == value:
				return true

			pose[property] = value
		else:
			if not pose.has(property):
				return true

			pose.erase(property)
		if (auto and bool(value) and RotationPaths.has_rotation(pose)) or property.begins_with("rotation"):
			_update_rotation_paths(clip, element, time)
		var view := {"index": index, "frame": time}
		if numeric and not enabled:
			_prune_deleted_frames(clip, [time])
			if _empty_pose(pose):
				# The pose is gone: deselect it, and reselect it on undo.
				return _replace("Change Keyframe " + property, index, clip, {"index": index, "frame": time, "selection": []},
					{"index": index, "frame": time, "selection": [{"element": element, "frame": time}]})
		return _replace("Change Keyframe " + property, index, clip, view, view)

	return false


## Graph editor: gives one channel of one key its own curve, or with null
## returns it to the group's preset. `curve` is {interp, mode, in, out} (see
## ChannelCurves). With `value`, also sets the key's value in the same step.
func set_channel_curve(index: int, time: int, element: String, channel: String, curve: Variant, value: Variant = null) -> bool:
	if index < 0 or index >= clips().size() or not clips()[index] is Dictionary:
		return false
	var group := channel.substr(0, channel.length() - 1)
	if not group in Baker.GROUPS or not channel.right(1) in Baker.AXES:
		return false
	if curve != null and not (curve is Dictionary and curve.get("interp") in ["constant", "linear", "bezier"] and curve.get("mode") in ["auto", "auto_clamped", "aligned", "broken"]):
		return false
	if value != null and (not (value is int or value is float) or not is_finite(float(value)) or absf(float(value)) > Limits.MAX_COORDINATE):
		return false
	var clip: Dictionary = clips()[index].duplicate(true)
	for key in clip.get("keyframes", []):
		if key.frame != time or not key.get("elements", {}).get(element) is Dictionary:
			continue
		var pose: Dictionary = key.elements[element]
		if not Baker.AXES.any(func(axis: String): return pose.get(group + axis) != null):
			return false
		var before := pose.duplicate(true)
		if value != null:
			pose[channel] = float(value)
		var editor: Dictionary = pose.get("editor") if pose.get("editor") is Dictionary else {}
		var curves: Dictionary = editor.get("curves") if editor.get("curves") is Dictionary else {}
		if curve == null:
			curves.erase(channel)
		else:
			var stored := {"interp": curve.interp, "mode": curve.mode}
			for side in ["in", "out"]:
				var handle: Variant = curve.get(side)
				if handle is Vector2:
					handle = [handle.x, handle.y]
				if handle is Array and handle.size() == 2 and (handle[0] is float or handle[0] is int) and (handle[1] is float or handle[1] is int) \
						and is_finite(float(handle[0])) and is_finite(float(handle[1])):
					stored[side] = [float(handle[0]), float(handle[1])]
			curves[channel] = stored
		if curves.is_empty():
			editor.erase("curves")
		else:
			editor.curves = curves
		if editor.is_empty():
			pose.erase("editor")
		else:
			pose.editor = editor
		if pose == before:
			return true
		if channel.begins_with("rotation") and value != null:
			_update_rotation_paths(clip, element, time)
		var view := {"index": index, "frame": time}
		return _replace("Change Curve", index, clip, view, view)
	return false


func set_transform(index: int, time: int, element: String, group: String, value: Vector3) -> bool:
	if index < 0 or index >= clips().size() or not group in ["offset", "rotation", "stretch"] or not value.is_finite():
		return false

	var clip: Dictionary = clips()[index].duplicate(true)
	var frames: Array = clip.get("keyframes", [])
	var target: Dictionary = {}
	for key in frames:
		if key.frame == time:
			target = key
			break
	if target.is_empty():
		target = {"frame": time, "elements": {}}
		frames.append(target)
		frames.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
		clip.keyframes = frames
	if not target.has("elements"):
		target.elements = {}
	if not target.elements.has(element):
		target.elements[element] = {}
	for i in range(3):
		target.elements[element][group + ["X", "Y", "Z"][i]] = value[i]
	if group == "rotation":
		_update_rotation_paths(clip, element, time)
	var view := {"index": index, "frame": time}
	return _replace("Scale Animation Keyframe" if group == "stretch" else "Rotate Animation Keyframe" if group == "rotation" else "Move Animation Keyframe", index, clip, view, view)


## Keys an element's current offset and rotation at a frame (one undo step).
## values: {"offset": Vector3, "rotation": Vector3}.
func insert_key(index: int, time: int, element: String, values: Dictionary) -> bool:
	if index < 0 or index >= clips().size() or not clips()[index] is Dictionary:
		return false
	var clip: Dictionary = clips()[index].duplicate(true)
	if not clip.get("keyframes") is Array:
		clip.keyframes = []
	var target: Dictionary = {}
	for key in clip.keyframes:
		if key is Dictionary and key.get("frame") == time:
			target = key
	if target.is_empty():
		target = {"frame": time, "elements": {}}
		clip.keyframes.append(target)
		clip.keyframes.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
	if not target.get("elements") is Dictionary:
		target.elements = {}
	var pose: Dictionary = target.elements.get(element, {})
	for group in values:
		for axis in range(3):
			pose[group + ["X", "Y", "Z"][axis]] = values[group][axis]
	target.elements[element] = pose
	_update_rotation_paths(clip, element, time)
	var view := {"index": index, "frame": time}
	return _replace("Insert Keyframe", index, clip, view, view)


static func behavior_index(value: Variant, choices: Array) -> int:
	for i in range(choices.size()):
		if (value is int or value is float) and value == i:
			return i

		if str(value).to_lower() == str(choices[i]).to_lower() or str(value) == str(i):
			return i

	return -1


func move_keyframes(index: int, selection: Array, delta: int, playhead: float) -> bool:
	if index < 0 or index >= clips().size() or delta == 0 or selection.is_empty():
		return false

	var source: Dictionary = clips()[index]
	var clip: Dictionary = source.duplicate(true)
	var frames: Array = clip.keyframes
	var moving: Dictionary = {}
	var vacated: Dictionary = {}
	var payloads: Array = []
	for key in selection:
		var id := "%s:%d" % [key.element, key.frame]
		if moving.has(id):
			continue

		if key.frame + delta < 0 or key.frame + delta >= source.get("quantityframes", source.get("quantityFrames", 1)):
			return false

		moving[id] = true
		for record in frames:
			if record.frame == key.frame and record.get("elements", {}).has(key.element):
				payloads.append({"element": key.element, "frame": int(key.frame), "pose": record.elements[key.element].duplicate(true)})
	if payloads.size() != moving.size():
		return false

	for payload in payloads:
		for record in frames:
			if record.frame == payload.frame + delta and record.get("elements", {}).has(payload.element) and not moving.has("%s:%d" % [payload.element, int(record.frame)]):
				rejected.emit("A keyframe for this shape already exists at frame %d. No keys were moved." % int(record.frame))
				return false
	# Vacate every source first so selected keys can move into each other's slots.
	for payload in payloads:
		vacated[payload.frame] = true
		for record in frames:
			if record.frame == payload.frame:
				record.elements.erase(payload.element)
	var shifted: Array = []
	for payload in payloads:
		var destination: Dictionary = {}
		for record in frames:
			if record.frame == payload.frame + delta:
				destination = record
				break
		if destination.is_empty():
			destination = {"frame": payload.frame + delta, "elements": {}}
			frames.append(destination)
		if not destination.has("elements"):
			destination.elements = {}
		destination.elements[payload.element] = payload.pose
		shifted.append({"element": payload.element, "frame": payload.frame + delta})
	_prune_deleted_frames(clip, vacated.keys())
	frames = clip.keyframes
	frames.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
	for payload in payloads:
		if RotationPaths.has_rotation(payload.pose):
			_update_rotation_paths(clip, payload.element, payload.frame)
			_update_rotation_paths(clip, payload.element, payload.frame + delta)
	return _replace("Move Keyframes", index, clip, {"index": index, "frame": playhead + delta, "selection": shifted},
		{"index": index, "frame": playhead, "selection": selection.duplicate(true)})


func delete_keyframes(index: int, selection: Array, playhead: float) -> bool:
	if index < 0 or index >= clips().size() or selection.is_empty():
		return false

	var clip: Dictionary = clips()[index].duplicate(true)
	var frames: Array = clip.get("keyframes", [])
	var removed := false
	var removed_rotations: Array = []
	var affected_frames: Array = []
	for key in selection:
		for record in frames:
			if record.get("frame") == key.frame and record.get("elements", {}).has(key.element):
				if RotationPaths.has_rotation(record.elements[key.element]):
					removed_rotations.append(key)
				record.elements.erase(key.element)
				affected_frames.append(int(key.frame))
				removed = true
	if not removed:
		return false

	_prune_deleted_frames(clip, affected_frames)
	for key in removed_rotations:
		_update_rotation_paths(clip, key.element, key.frame)
	return _replace("Delete Keyframes", index, clip, {"index": index, "frame": playhead, "selection": []},
		{"index": index, "frame": playhead, "selection": selection.duplicate(true)})


func _update_rotation_paths(clip: Dictionary, element: String, time: int) -> void:
	var base := Vector3.ZERO
	# Version 0 adds animation angles to the model's Euler angles; version 1
	# applies animation after the base transform. Score the same local path.
	if int(clip.get("version", 0)) == 0:
		var stack: Array = data.get("elements", []).duplicate()
		while not stack.is_empty():
			var node: Variant = stack.pop_back()
			if not node is Dictionary:
				continue

			if node.get("name", "") == element:
				base = RotationPaths.angles(node)
				break
			if node.get("children") is Array:
				stack.append_array(node.children)
	RotationPaths.update_neighbors(clip, element, time, base)


func copy_keyframes(index: int, selection: Array) -> bool:
	if index < 0 or index >= clips().size() or selection.is_empty():
		return false

	var copied: Array = []
	var first := int(selection[0].frame)
	for key in selection:
		first = mini(first, int(key.frame))
		for record in clips()[index].get("keyframes", []):
			if record.get("frame") == key.frame and record.get("elements", {}).has(key.element):
				copied.append({"element": key.element, "frame": int(key.frame), "pose": record.elements[key.element].duplicate(true)})
	if copied.is_empty():
		return false

	for key in copied:
		key.frame -= first
	keyframe_clipboard = copied
	return true


func paste_keyframes(index: int, time: int, previous_selection: Array, playhead: float) -> bool:
	if index < 0 or index >= clips().size() or keyframe_clipboard.is_empty():
		return false

	var clip: Dictionary = clips()[index].duplicate(true)
	var duration := int(clip.get("quantityframes", clip.get("quantityFrames", 1)))
	for key in keyframe_clipboard:
		if time + key.frame < 0 or time + key.frame >= duration:
			rejected.emit("Copied keyframes do not fit within the animation duration.")
			return false

	var frames: Array = clip.get("keyframes", [])
	var pasted: Array = []
	for key in keyframe_clipboard:
		var destination: Dictionary = {}
		var target := time + int(key.frame)
		for record in frames:
			if record.frame == target:
				destination = record
				break
		if destination.is_empty():
			destination = {"frame": target, "elements": {}}
			frames.append(destination)
		if not destination.has("elements"):
			destination.elements = {}
		destination.elements[key.element] = key.pose.duplicate(true)
		pasted.append({"element": key.element, "frame": target})
	frames.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
	clip.keyframes = frames
	for key in keyframe_clipboard:
		if RotationPaths.has_rotation(key.pose):
			_update_rotation_paths(clip, key.element, time + key.frame)
	return _replace("Paste Keyframes", index, clip, {"index": index, "frame": time, "selection": pasted},
		{"index": index, "frame": playhead, "selection": previous_selection.duplicate(true)})



# --- Time edits, markers and mirrored paste (Phase 5) -------------------------------

## Scales the selected keys in time around `pivot` (a frame). Keys land on
## whole frames; a scale that would put two keys of one element on the same
## frame, or outside the clip, is refused.
func scale_keyframes(index: int, selection: Array, pivot: float, factor: float, playhead: float) -> bool:
	if index < 0 or index >= clips().size() or selection.is_empty() or not is_finite(factor) or factor <= 0.0:
		return false
	var source: Dictionary = clips()[index]
	var duration := int(source.get("quantityframes", source.get("quantityFrames", 1)))
	var targets := {}
	var moved: Array = []
	for key in selection:
		var target := roundi(pivot + (float(key.frame) - pivot) * factor)
		if target < 0 or target >= duration:
			rejected.emit("Scaled keys would leave the animation. Lengthen it first.")
			return false
		var id := "%s:%d" % [key.element, target]
		if targets.has(id):
			rejected.emit("Two keys of %s would land on frame %d. No keys were scaled." % [key.element, target])
			return false
		targets[id] = true
		moved.append({"element": key.element, "frame": int(key.frame), "to": target})
	var clip: Dictionary = source.duplicate(true)
	var payloads: Array = []
	var moving := {}
	for entry in moved:
		moving["%s:%d" % [entry.element, entry.frame]] = true
	for entry in moved:
		for record in clip.keyframes:
			if record.frame == entry.frame and record.get("elements", {}).has(entry.element):
				payloads.append({"element": entry.element, "to": entry.to, "pose": record.elements[entry.element].duplicate(true)})
			if record.frame == entry.to and record.get("elements", {}).has(entry.element) and not moving.has("%s:%d" % [entry.element, entry.to]):
				rejected.emit("A key of %s already sits on frame %d. No keys were scaled." % [entry.element, entry.to])
				return false
	var vacated: Array = []
	for entry in moved:
		vacated.append(entry.frame)
		for record in clip.keyframes:
			if record.frame == entry.frame:
				record.elements.erase(entry.element)
	var result: Array = []
	for payload in payloads:
		_put_pose(clip, payload.to, payload.element, payload.pose)
		result.append({"element": payload.element, "frame": payload.to})
	_prune_deleted_frames(clip, vacated)
	clip.keyframes.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
	for payload in payloads:
		if RotationPaths.has_rotation(payload.pose):
			_update_rotation_paths(clip, payload.element, payload.to)
	return _replace("Scale Keyframes", index, clip, {"index": index, "frame": playhead, "selection": result},
		{"index": index, "frame": playhead, "selection": selection.duplicate(true)})


func _put_pose(clip: Dictionary, time: int, element: String, pose: Dictionary) -> void:
	for record in clip.keyframes:
		if record.frame == time:
			if not record.get("elements") is Dictionary:
				record.elements = {}
			record.elements[element] = pose
			return
	clip.keyframes.append({"frame": time, "elements": {element: pose}})


## Ripple insert: adds `count` empty frames at `at`, moving every later key
## and lengthening the clip.
func insert_frames(index: int, at: int, count: int, playhead: float) -> bool:
	if index < 0 or index >= clips().size() or count < 1:
		return false
	var source: Dictionary = clips()[index]
	var duration := int(source.get("quantityframes", source.get("quantityFrames", 1)))
	if at < 0 or at > duration or duration + count > Limits.MAX_ANIMATION_FRAMES:
		return false
	var clip: Dictionary = source.duplicate(true)
	for record in clip.get("keyframes", []):
		if record.frame >= at:
			record.frame = float(int(record.frame) + count)
	clip.erase("quantityFrames")
	clip.quantityframes = duration + count
	_shift_markers(clip, at, count)
	return _replace("Insert Frames", index, clip, {"index": index, "frame": playhead}, {"index": index, "frame": playhead})


## Ripple delete: removes frames `at` to `at + count - 1` with their keys,
## moving every later key back and shortening the clip.
func delete_frames(index: int, at: int, count: int, playhead: float) -> bool:
	if index < 0 or index >= clips().size() or count < 1:
		return false
	var source: Dictionary = clips()[index]
	var duration := int(source.get("quantityframes", source.get("quantityFrames", 1)))
	if at < 0 or at + count > duration or duration - count < 1:
		rejected.emit("An animation needs at least one frame.")
		return false
	var clip: Dictionary = source.duplicate(true)
	clip.keyframes = clip.get("keyframes", []).filter(func(record): return not (record.frame >= at and record.frame < at + count))
	for record in clip.keyframes:
		if record.frame >= at + count:
			record.frame = float(int(record.frame) - count)
	if clip.keyframes.is_empty():
		clip.keyframes.append({"frame": 0, "elements": {}})
	clip.erase("quantityFrames")
	clip.quantityframes = duration - count
	if clip.get("markers") is Array:
		clip.markers = clip.markers.filter(func(marker): return not (marker is Dictionary and marker.get("frame", -1) >= at and marker.get("frame", -1) < at + count))
	_shift_markers(clip, at + count, -count)
	return _replace("Delete Frames", index, clip, {"index": index, "frame": minf(playhead, duration - count - 1)}, {"index": index, "frame": playhead})


func _shift_markers(clip: Dictionary, from: int, delta: int) -> void:
	for marker in clip.get("markers", []) if clip.get("markers") is Array else []:
		if marker is Dictionary and int(marker.get("frame", -1)) >= from:
			marker.frame = int(marker.frame) + delta


## Named markers on the time ruler: [{frame, name}], editor-only (kept in the
## working file, not the game file).
func markers(index: int) -> Array:
	if index < 0 or index >= clips().size() or not clips()[index] is Dictionary:
		return []
	var value: Variant = clips()[index].get("markers", [])
	return value.filter(func(marker): return marker is Dictionary) if value is Array else []


func set_markers(index: int, value: Array, playhead := 0.0, label := "Change Markers") -> bool:
	if index < 0 or index >= clips().size() or not clips()[index] is Dictionary:
		return false
	var source: Dictionary = clips()[index]
	var duration := int(source.get("quantityframes", source.get("quantityFrames", 1)))
	var cleaned: Array = []
	for marker in value:
		if marker is Dictionary and (marker.get("frame") is int or marker.get("frame") is float):
			cleaned.append({"frame": clampi(int(marker.frame), 0, duration - 1), "name": str(marker.get("name", "Marker"))})
	cleaned.sort_custom(func(a, b): return a.frame < b.frame)
	if cleaned == markers(index) and (source.has("markers") or cleaned.is_empty()):
		return true
	var clip: Dictionary = source.duplicate(true)
	if cleaned.is_empty():
		clip.erase("markers")
	else:
		clip.markers = cleaned
	return _replace(label, index, clip, {"index": index, "frame": playhead}, {"index": index, "frame": playhead})


## The element on the other side: Left and Right swap, left and right, and a
## whole L or R word (ArmL, Arm_L, L_Arm, "Arm L"). Names without a side map
## to themselves.
static func mirror_name(name: String) -> String:
	for pair in [["Left", "Right"], ["left", "right"], ["LEFT", "RIGHT"]]:
		if pair[0] in name:
			return name.replace(pair[0], pair[1])
		if pair[1] in name:
			return name.replace(pair[1], pair[0])
	# A standalone L or R (Arm_L, "Ear L", l_hand), a capital L or R ending a
	# camel-case word (ArmL, ArmLUpper), or starting one (LHand).
	for pattern in ["(?:^|[^A-Za-z])([LRlr])(?=$|[^A-Za-z])", "(?<=[a-z])([LR])(?=$|[^A-Za-z]|[A-Z])", "^([LR])(?=[A-Z])"]:
		var found := RegEx.create_from_string(pattern).search(name)
		if found != null:
			var swapped: String = {"L": "R", "R": "L", "l": "r", "r": "l"}[found.get_string(1)]
			return name.substr(0, found.get_start(1)) + swapped + name.substr(found.get_end(1))
	return name


## A pose mirrored across the model's X axis: offset X and rotation Y and Z
## change sign, with their curve handles.
static func mirror_pose(pose: Dictionary) -> Dictionary:
	var result := pose.duplicate(true)
	for field in ["offsetX", "rotationY", "rotationZ"]:
		if result.get(field) is float or result.get(field) is int:
			result[field] = -float(result[field])
	var editor: Variant = result.get("editor")
	if editor is Dictionary and editor.get("curves") is Dictionary:
		for field in ["offsetX", "rotationY", "rotationZ"]:
			var curve: Variant = editor.curves.get(field)
			if curve is Dictionary:
				for side in ["in", "out"]:
					if curve.get(side) is Array and curve[side].size() == 2:
						curve[side] = [curve[side][0], -float(curve[side][1])]
	return result


## Pastes the copied keys mirrored: each element's keys go to its mirror
## element (when the shape has one), with mirrored values.
func paste_mirrored(index: int, time: int, previous_selection: Array, playhead: float) -> bool:
	if keyframe_clipboard.is_empty():
		return false
	var names := {}
	var stack: Array = data.get("elements", []).duplicate() if data.get("elements") is Array else []
	while not stack.is_empty():
		var element: Variant = stack.pop_back()
		if element is Dictionary:
			names[str(element.get("name", ""))] = true
			if element.get("children") is Array:
				stack.append_array(element.children)
	var original := keyframe_clipboard
	var mirrored: Array = []
	for key in original:
		var other := mirror_name(key.element)
		mirrored.append({"element": other if names.has(other) else key.element, "frame": key.frame, "pose": mirror_pose(key.pose)})
	keyframe_clipboard = mirrored
	var ok := paste_keyframes(index, time, previous_selection, playhead)
	keyframe_clipboard = original
	return ok



# --- Poses (Phase 5) ---------------------------------------------------------------------

## Keys several elements at one frame as one step. `values` maps element
## names to {group: Vector3} (offset in shape units, rotation in degrees,
## stretch as factors); each group is written whole, as the game stores it.
func key_values(index: int, time: int, values: Dictionary, label := "Key Pose") -> bool:
	if index < 0 or index >= clips().size() or not clips()[index] is Dictionary or values.is_empty():
		return false
	var source: Dictionary = clips()[index]
	if time < 0 or time >= int(source.get("quantityframes", source.get("quantityFrames", 1))):
		return false
	var clip: Dictionary = source.duplicate(true)
	if not clip.get("keyframes") is Array:
		clip.keyframes = []
	var target: Dictionary = {}
	for key in clip.keyframes:
		if key is Dictionary and int(key.get("frame", -1)) == time:
			target = key
	if target.is_empty():
		target = {"frame": float(time), "elements": {}}
		clip.keyframes.append(target)
		clip.keyframes.sort_custom(func(a: Dictionary, b: Dictionary): return a.frame < b.frame)
	if not target.get("elements") is Dictionary:
		target.elements = {}
	for element in values:
		var pose: Dictionary = target.elements.get(element, {})
		for group in values[element]:
			if not group in ["offset", "rotation", "stretch"]:
				continue
			var vector: Vector3 = values[element][group]
			if not vector.is_finite():
				return false
			for axis in range(3):
				pose[group + ["X", "Y", "Z"][axis]] = vector[axis]
		target.elements[element] = pose
	for element in values:
		if values[element].has("rotation"):
			_update_rotation_paths(clip, element, time)
	var view := {"index": index, "frame": time}
	return _replace(label, index, clip, view, view)
