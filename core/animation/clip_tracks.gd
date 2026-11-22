extends RefCounted
## Working file v2: authored animation as one track per element channel
## (`shapesmith.clips`), aimed at stable element IDs (`shapesmith.ids`).
##
## Each key is {f, v, interp, in, out, preset}: "linear", "constant" (Hold) or
## "bezier" with in/out handles as [frames, value] offsets. The editor's five
## presets are bezier handles a third of the way along each segment, which
## reproduces the old preset curves exactly; `preset` names the one in use.
## Rotation keys also keep the game's shortest-path flag and the editor's
## per-key auto flag. An axis the user did not key, filled in because the game
## needs all three, is marked `implicit`.
##
## Inside the editor the clip is still a list of game keyframes with per-pose
## `editor` blocks; to_clip_tracks() and to_keyframes() convert losslessly.

const GROUPS := ["offset", "rotation", "stretch"]
const AXES := ["X", "Y", "Z"]
const PRESETS := ["linear", "ease_in", "ease_out", "ease_in_out", "hold"]
## Pose fields the tracks carry; anything else on a pose is kept under "extra".
const POSE_FIELDS := ["offsetX", "offsetY", "offsetZ", "rotationX", "rotationY", "rotationZ", "stretchX", "stretchY", "stretchZ",
	"rotShortestDistanceX", "rotShortestDistanceY", "rotShortestDistanceZ", "editor"]
const EDITOR_FIELDS := ["interpolation", "autoShortestRotation", "shapeSmithImplicitAxes", "curves"]


# --- Element IDs -------------------------------------------------------------------

## Path ("Body/Neck/Head") for every element dictionary, in file order. A
## repeated path gets "#2", "#3"... so every element has its own.
static func element_paths(elements: Array) -> Array:
	var result: Array = []
	var seen := {}
	_paths(elements, "", result, seen)
	return result


static func _paths(elements: Array, prefix: String, result: Array, seen: Dictionary) -> void:
	for element in elements:
		if not element is Dictionary:
			continue
		var path := prefix + str(element.get("name", ""))
		var unique := path
		var count := 2
		while seen.has(unique):
			unique = "%s#%d" % [path, count]
			count += 1
		seen[unique] = true
		result.append({"path": unique, "name": str(element.get("name", "")), "element": element})
		if element.get("children") is Array:
			_paths(element.children, path + "/", result, seen)


## The ID map for saving: paths that had an ID keep it; new paths get one.
static func ids_for(elements: Array, previous: Dictionary) -> Dictionary:
	var result := {}
	var used := {}
	for value in previous.values():
		used[str(value)] = true
	for entry in element_paths(elements):
		var id: Variant = previous.get(entry.path)
		if not id is String or id.is_empty():
			id = _new_id(used)
		result[entry.path] = id
		used[id] = true
	return result


static func _new_id(used: Dictionary) -> String:
	var id := ""
	while id.is_empty() or used.has(id):
		id = "e:%04x" % (randi() & 0xffff) if used.size() < 30000 else "e:%08x" % randi()
	return id


# --- Saving ------------------------------------------------------------------------

## One clip as v2 tracks. `ids` maps element paths to IDs; keyframe poses name
## elements, so a name resolves to the first element with that name.
static func to_clip_tracks(clip: Dictionary, elements: Array, ids: Dictionary) -> Dictionary:
	var by_name := {}
	for entry in element_paths(elements):
		if not by_name.has(entry.name):
			by_name[entry.name] = ids.get(entry.path, "")
	var result := {"code": str(clip.get("code", clip.get("name", ""))), "tracks": []}
	var length := int(clip.get("quantityframes", clip.get("quantityFrames", 1)))
	var keyframes: Array = clip.get("keyframes", []) if clip.get("keyframes") is Array else []
	var ordered := keyframes.filter(func(key): return key is Dictionary and (key.get("frame") is float or key.get("frame") is int))
	ordered.sort_custom(func(a, b): return a.frame < b.frame)
	var names: Array = []
	for key in ordered:
		for name in key.get("elements", {}) if key.get("elements") is Dictionary else {}:
			if not name in names:
				names.append(name)
	# A fixed order, so saving the same animation always writes the same file.
	names.sort()
	var unmatched: Array = []
	for name in names:
		var target: String = by_name.get(name, "")
		if target.is_empty():
			# A track for an element that is not in this shape is kept by name.
			target = "name:" + str(name)
			unmatched.append(name)
		var poses: Array = []
		for key in ordered:
			var pose: Variant = key.get("elements", {}).get(name)
			if pose is Dictionary:
				poses.append({"f": int(key.frame), "pose": pose})
		for group in GROUPS:
			var keyed := poses.filter(func(entry): return AXES.any(func(axis): return entry.pose.get(group + axis) != null))
			if keyed.is_empty():
				continue
			for axis in range(3):
				result.tracks.append({"target": target, "channel": group + AXES[axis],
					"keys": _channel_keys(keyed, group, axis, length, _loops(clip))})
		var extras: Array = []
		for entry in poses:
			var extra := {}
			var keyed_groups: Array = GROUPS.filter(func(group): return AXES.any(func(axis): return entry.pose.get(group + axis) != null))
			for field in entry.pose:
				if not field in POSE_FIELDS:
					extra[field] = entry.pose[field]
				elif field.begins_with("rotShortestDistance") and not "rotation" in keyed_groups:
					extra[field] = entry.pose[field]
			var editor: Variant = entry.pose.get("editor")
			if editor is Dictionary:
				var kept := {}
				for field in editor:
					if not field in EDITOR_FIELDS:
						kept[field] = editor[field]
				# Settings for a group this pose does not key have no channel key.
				if editor.get("interpolation") is Dictionary:
					var stale := {}
					for group in editor.interpolation:
						if not group in keyed_groups:
							stale[group] = editor.interpolation[group]
					if not stale.is_empty() or editor.interpolation.is_empty():
						kept.interpolation = stale
				elif editor.has("interpolation"):
					kept.interpolation = editor.interpolation
				if editor.get("curves") is Dictionary:
					var loose := {}
					for channel_name in editor.curves:
						if not str(channel_name).substr(0, str(channel_name).length() - 1) in keyed_groups:
							loose[channel_name] = editor.curves[channel_name]
					if not loose.is_empty() or editor.curves.is_empty():
						kept.curves = loose
				elif editor.has("curves"):
					kept.curves = editor.curves
				if editor.has("autoShortestRotation") and not "rotation" in keyed_groups:
					kept.autoShortestRotation = editor.autoShortestRotation
				if not kept.is_empty() or editor.is_empty():
					extra.editor = kept
			elif entry.pose.has("editor"):
				extra.editor = editor
			if not extra.is_empty() or not AXES.any(func(axis): return GROUPS.any(func(group): return entry.pose.get(group + axis) != null)):
				extras.append({"f": entry.f, "data": extra})
		if not extras.is_empty():
			result.tracks.append({"target": target, "channel": "pose", "keys": extras})
	# Frames with no poses at all still exist in the game file.
	var empty: Array = []
	for key in ordered:
		if key.get("elements", {}) is Dictionary and key.get("elements", {}).is_empty():
			empty.append(int(key.frame))
	if not empty.is_empty():
		result.emptyFrames = empty
	if not unmatched.is_empty():
		result.unmatched = unmatched
	return result


static func _channel_keys(keyed: Array, group: String, axis: int, length: int, loop: bool) -> Array:
	var field: String = group + AXES[axis]
	var keys: Array = []
	var curves: Array = []
	for i in range(keyed.size()):
		var pose: Dictionary = keyed[i].pose
		var editor: Dictionary = pose.get("editor") if pose.get("editor") is Dictionary else {}
		var implicit: Array = editor.get("shapeSmithImplicitAxes", []) if editor.get("shapeSmithImplicitAxes") is Array else []
		var value: Variant = pose.get(field)
		var key := {"f": keyed[i].f, "v": float(value) if value != null else (1.0 if group == "stretch" else 0.0)}
		if value == null or field in implicit:
			key.implicit = true
		var preset := _preset(pose, group)
		key.interp = "linear" if preset == "linear" else ("constant" if preset == "hold" else "bezier")
		var chosen: Variant = editor.get("interpolation", {}).get(group) if editor.get("interpolation") is Dictionary else null
		if chosen != null:
			key.preset = chosen
		# A curve drawn in the graph editor overrides the preset for this channel.
		var own: Variant = editor.get("curves", {}).get(field) if editor.get("curves") is Dictionary else null
		if own != null:
			key.own = own
			if own is Dictionary:
				for setting in ["interp", "mode", "in", "out"]:
					if own.has(setting):
						key[setting] = own[setting]
		if group == "rotation":
			if pose.has("rotShortestDistance" + AXES[axis]):
				key.shortest = pose["rotShortestDistance" + AXES[axis]]
			if editor.has("autoShortestRotation"):
				key.autoShortest = editor.autoShortestRotation
		keys.append(key)
		curves.append(preset)
	# Handles a third of the way along each segment reproduce the presets.
	for i in range(keys.size()):
		if keys[i].has("own") or keys[i].interp != "bezier" or (i == keys.size() - 1 and not loop):
			continue
		var next: Dictionary = keys[(i + 1) % keys.size()]
		var span := float(next.f - keys[i].f) if next.f > keys[i].f else float(length - keys[i].f + next.f)
		var delta: float = next.v - keys[i].v
		if group == "rotation" and keys[i].get("shortest", false) == true:
			delta = wrapf(delta, -180.0, 180.0)
		var shape: Array = {"ease_in": [0.0, 1.0 / 3.0], "ease_out": [2.0 / 3.0, 1.0], "ease_in_out": [0.0, 1.0]}[curves[i]]
		keys[i].out = [span / 3.0, shape[0] * delta]
		if not next.has("own"):
			next["in"] = [-span / 3.0, (shape[1] - 1.0) * delta]
	return keys


static func _preset(pose: Dictionary, group: String) -> String:
	var editor: Variant = pose.get("editor")
	var interpolation: Variant = editor.get("interpolation") if editor is Dictionary else null
	var value: Variant = interpolation.get(group, "linear") if interpolation is Dictionary else "linear"
	return value if value in PRESETS else "linear"


# --- Loading -----------------------------------------------------------------------

## The editor's keyframes for one v2 clip. `names` maps IDs to element names.
static func to_keyframes(entry: Dictionary, names: Dictionary) -> Array:
	var frames := {}
	for time in entry.get("emptyFrames", []) if entry.get("emptyFrames") is Array else []:
		frames[int(time)] = {}
	for track in entry.get("tracks", []) if entry.get("tracks") is Array else []:
		if not track is Dictionary or not track.get("keys") is Array:
			continue
		var target := str(track.get("target", ""))
		var name: String = names.get(target, target.trim_prefix("name:"))
		var channel := str(track.get("channel", ""))
		for key in track.keys:
			if not key is Dictionary or not (key.get("f") is float or key.get("f") is int):
				continue
			var time := int(key.f)
			if not frames.has(time):
				frames[time] = {}
			if not frames[time].has(name):
				frames[time][name] = {}
			var pose: Dictionary = frames[time][name]
			if channel == "pose":
				var data: Variant = key.get("data", {})
				if data is Dictionary:
					for field in data:
						if field == "editor" and data.editor is Dictionary:
							var editor := _editor(pose)
							for setting in data.editor:
								if setting in ["interpolation", "curves"] and data.editor[setting] is Dictionary and editor.get(setting) is Dictionary:
									editor[setting].merge(data.editor[setting], true)
								else:
									editor[setting] = data.editor[setting]
						else:
							pose[field] = data[field]
				continue
			if channel.length() < 2 or not channel.substr(0, channel.length() - 1) in GROUPS:
				continue
			var group := channel.substr(0, channel.length() - 1)
			var axis := channel.right(1)
			# An implicit axis is absent in the editor; the game file fills it in.
			if key.get("implicit", false) != true:
				pose[channel] = key.get("v", 1.0 if group == "stretch" else 0.0)
			var preset: Variant = key.get("preset", "hold" if key.get("interp") == "constant" else null)
			if preset != null:
				var editor := _editor(pose)
				if not editor.get("interpolation") is Dictionary:
					editor.interpolation = {}
				editor.interpolation[group] = preset
			if key.has("own"):
				var editor := _editor(pose)
				if not editor.get("curves") is Dictionary:
					editor.curves = {}
				editor.curves[channel] = key.own
			if group == "rotation":
				if key.has("shortest"):
					pose["rotShortestDistance" + axis] = key.shortest
				if key.has("autoShortest"):
					_editor(pose).autoShortestRotation = key.autoShortest
	var times: Array = frames.keys()
	times.sort()
	var result: Array = []
	for time in times:
		result.append({"frame": float(time), "elements": frames[time]})
	return result


static func _editor(pose: Dictionary) -> Dictionary:
	if not pose.get("editor") is Dictionary:
		pose.editor = {}
	return pose.editor


static func _loops(clip: Dictionary) -> bool:
	var ending: Variant = clip.get("onAnimationEnd", "Repeat")
	return ending == 0 if ending is int or ending is float else str(ending).to_lower() in ["repeat", "0"]
