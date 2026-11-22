extends RefCounted

# IEEE 754 doubles represent every integer exactly up to this limit.
const MAX_EXACT_JSON_INTEGER := 9007199254740991.0
## Files are written like the game's own: tab-indented, with any object or
## array that fits in this many characters on one line (a keyframe's pose, a
## face, a from/to pair), so a shape's size is its data, not its indentation.
const INLINE_WIDTH := 140
## Animation values are written to this step: a ten-thousandth of a degree or
## shape unit, far below what shows in game, without float noise such as
## 72.8647689819336 from baked IK and curves.
const POSE_STEP := 0.0001
const POSE_FIELDS := ["offsetX", "offsetY", "offsetZ", "rotationX", "rotationY", "rotationZ", "stretchX", "stretchY", "stretchZ"]

## Godot parses every JSON number as a float. VS's Newtonsoft reader rejects
## decimal tokens for integer fields, even when their fractional part is zero.


static func stringify(data: Dictionary) -> String:
	return _format(_json_numbers(game_data(data)), 0) + "\n"


static func game_data(data: Dictionary) -> Dictionary:
	var result := data.duplicate(true)
	if not result.get("elements") is Array or not result.get("animations") is Array:
		return result

	var marker: Variant = result.get("shapesmith")
	var tracks: Variant = marker.get("clips") if marker is Dictionary else null
	for clip_index in range(result.animations.size()):
		var clip: Variant = result.animations[clip_index]
		if not clip is Dictionary or not clip.get("keyframes") is Array:
			continue
		# A working file's tracks keep unchecked axes, but only for the clips it
		# stores tracks for (clips that match their game keys are not stored).
		var tracks_keep_axes: bool = tracks is Array and clip_index < tracks.size() and tracks[clip_index] is Dictionary

		for key in clip.keyframes:
			if not key is Dictionary or not key.get("elements") is Dictionary:
				continue

			for pose in key.elements.values():
				if not pose is Dictionary:
					continue

				for field in POSE_FIELDS:
					var number: Variant = pose.get(field)
					if number is float and is_finite(number):
						pose[field] = snappedf(number, POSE_STEP)
				# False is the game's default for these flags: leave them out.
				for axis in ["X", "Y", "Z"]:
					if pose.get("rotShortestDistance" + axis) == false:
						pose.erase("rotShortestDistance" + axis)
				var implicit: Array = []
				for group in ["offset", "rotation", "stretch"]:
					if not ["X", "Y", "Z"].any(func(axis: String): return pose.get(group + axis) != null):
						continue

					for axis in ["X", "Y", "Z"]:
						var field: String = group + axis
						if pose.get(field) == null:
							pose[field] = 1 if group == "stretch" else 0
							implicit.append(field)
				# The game's nullable fields require all three axes in an authored
				# group. Keep the editor's unchecked axes when opening the file again
				# (working files from version 2 keep them in their tracks instead).
				if not implicit.is_empty() and not tracks_keep_axes and (not pose.has("editor") or pose.editor is Dictionary):
					if not pose.has("editor"):
						pose.editor = {}
					pose.editor.shapeSmithImplicitAxes = implicit
	return result


static func restore_implicit_axes(data: Dictionary) -> void:
	if not data.get("animations") is Array:
		return

	for clip in data.animations:
		if not clip is Dictionary or not clip.get("keyframes") is Array:
			continue

		for key in clip.keyframes:
			if not key is Dictionary or not key.get("elements") is Dictionary:
				continue

			for pose in key.elements.values():
				if not pose is Dictionary or not pose.get("editor") is Dictionary:
					continue

				var implicit: Variant = pose.editor.get("shapeSmithImplicitAxes")
				if not implicit is Array:
					continue

				for field in implicit:
					if field in ["offsetX", "offsetY", "offsetZ", "rotationX", "rotationY", "rotationZ", "stretchX", "stretchY", "stretchZ"]:
						if pose.get(field) == (1 if field.begins_with("stretch") else 0):
							pose.erase(field)
				pose.editor.erase("shapeSmithImplicitAxes")
				if pose.editor.is_empty():
					pose.erase("editor")


static func _format(value: Variant, depth: int) -> String:
	var indent := "\t".repeat(depth)
	var child_indent := indent + "\t"
	var lines: PackedStringArray = []
	if (value is Dictionary or value is Array) and depth > 0:
		var single := _inline(value)
		if single.length() <= INLINE_WIDTH:
			return single
	if value is Dictionary:
		if value.is_empty():
			return "{}"

		for key in value:
			lines.append(child_indent + JSON.stringify(str(key)) + ": " + _format(value[key], depth + 1))
		return "{\n" + ",\n".join(lines) + "\n" + indent + "}"

	if value is Array:
		var inline_array := true
		for item in value:
			if item is Dictionary or item is Array:
				inline_array = false
		for item in value:
			lines.append(("" if inline_array else child_indent) + _format(item, depth + 1))
		if inline_array:
			return "[" + ", ".join(lines) + "]"

		return "[\n" + ",\n".join(lines) + "\n" + indent + "]"

	return JSON.stringify(value, "", false, true)


## One line, spaced like the game's files: { "a": 1, "b": [ 1, 2 ] }.
static func _inline(value: Variant) -> String:
	if value is Dictionary:
		if value.is_empty():
			return "{}"
		var parts: PackedStringArray = []
		for key in value:
			parts.append(JSON.stringify(str(key)) + ": " + _inline(value[key]))
		return "{ " + ", ".join(parts) + " }"
	if value is Array:
		if value.is_empty():
			return "[]"
		var items: PackedStringArray = []
		for item in value:
			items.append(_inline(item))
		return "[ " + ", ".join(items) + " ]"
	return JSON.stringify(value, "", false, true)


static func _json_numbers(value: Variant) -> Variant:
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = _json_numbers(value[key])
		return result

	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_json_numbers(item))
		return result
	# Stay within the exact integer range of a JSON double. Leave fractional
	# transforms untouched and avoid mutating the live document or undo history.
	if value is float and is_finite(value) and absf(value) <= MAX_EXACT_JSON_INTEGER and value == floor(value):
		return int(value)

	return value
