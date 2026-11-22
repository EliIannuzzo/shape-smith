extends RefCounted
## ShapeSmith working files (.shapesmith.json), format version 2.
##
## The file stays a valid game shape: the top-level `animations` hold the baked
## game keys, regenerated on every save, so it plays correctly in the game.
## The authored keys live in `shapesmith.clips` as per-channel tracks aimed at
## stable element IDs (`shapesmith.ids`); see ClipTracks. On load the authored
## keys replace the baked ones. Version 1 files (authored keys at the top
## level) open as they are and are written as version 2 on the next save.

const Baker = preload("res://core/animation/animation_baker.gd")
const Serializer = preload("res://core/model/shape_serializer.gd")
const ClipTracks = preload("res://core/animation/clip_tracks.gd")
const FORMAT := "shapesmith-working"
const VERSION := 2
const SUPPORTED := [1, 2]
const SUFFIX := ".shapesmith.json"
## Per-pose editor settings that live in the tracks, not in the game keys.
const EDITOR_POSE_FIELDS := ["interpolation", "autoShortestRotation", "shapeSmithImplicitAxes", "curves"]


static func is_working(data: Dictionary) -> bool:
	return data.get("shapesmith") is Dictionary and data.shapesmith.get("format") == FORMAT


static func version_of(data: Dictionary) -> int:
	var value: Variant = data.shapesmith.get("version") if is_working(data) else 0
	return int(value) if value is float or value is int else 0


static func validation_error(data: Dictionary) -> String:
	if is_working(data) and not version_of(data) in SUPPORTED:
		return "This ShapeSmith working file uses an unsupported format version."
	return ""


static func build(data: Dictionary) -> Dictionary:
	var options := Baker.settings(data)
	var marker: Dictionary = data.get("shapesmith", {}).duplicate(true) if data.get("shapesmith") is Dictionary else {}
	marker.format = FORMAT
	marker.version = VERSION
	marker.exportSettings = options
	marker.erase("generatedAnimations")
	var elements: Array = data.get("elements", []) if data.get("elements") is Array else []
	var previous: Dictionary = marker.get("ids", {}) if marker.get("ids") is Dictionary else {}
	marker.ids = ClipTracks.ids_for(elements, previous)
	var names := {}
	for entry in ClipTracks.element_paths(elements):
		names[marker.ids[entry.path]] = entry.name
	# Bake the keys exactly as they will load again, so the same document
	# always saves to the same bytes.
	var authored := data.duplicate(true)
	var clips: Array = []
	var animations: Array = authored.get("animations", []) if authored.get("animations") is Array else []
	for clip in animations:
		if not clip is Dictionary:
			clips.append({})
			continue
		var entry: Dictionary = ClipTracks.to_clip_tracks(clip, elements, marker.ids)
		# Timeline markers are editor data: kept with the tracks, not the game keys.
		if clip.get("markers") is Array:
			entry.markers = clip.markers
		clips.append(entry)
		if clip.get("keyframes") is Array:
			clip.keyframes = ClipTracks.to_keyframes(entry, names)
	var baked := Baker.bake_shape(authored, options)
	if not baked.error.is_empty():
		return {"error": baked.error}
	var output: Dictionary = baked.data
	_strip_pose_editors(output)
	var game_clips: Array = output.get("animations", []) if output.get("animations") is Array else []
	for clip in game_clips:
		if clip is Dictionary:
			clip.erase("markers")
	# A clip whose game keys say all its tracks do (linear keys, no eases,
	# curves, markers or controller keys) is not stored twice: on load its game
	# keys are its keys. Most clips of an imported shape are like this.
	for i in range(clips.size()):
		if clips[i] is Dictionary and i < game_clips.size() and game_clips[i] is Dictionary and _same_as_game(clips[i], game_clips[i], elements, marker.ids):
			clips[i] = null
	marker.clips = clips
	output.shapesmith = marker
	return {"data": output, "added": baked.added, "removed": baked.removed, "error": ""}


static func _same_as_game(entry: Dictionary, game_clip: Dictionary, elements: Array, ids: Dictionary) -> bool:
	if entry.has("markers") or entry.has("unmatched"):
		return false
	return ClipTracks.to_clip_tracks(game_clip.duplicate(true), elements, ids) == entry


## On load: the authored keys of a version 2 file replace its baked keys
## (clips stored as null have none: their game keys are their keys).
## Returns notes about tracks whose elements could not be found.
static func restore(data: Dictionary) -> PackedStringArray:
	var notes: PackedStringArray = []
	if not is_working(data):
		return notes
	var marker: Dictionary = data.shapesmith
	# Cached in-betweens (version 1) are rebuilt from authored keys, never trusted.
	marker.erase("generatedAnimations")
	# IK controllers are editor-only elements, kept out of the game data.
	if marker.get("controllers") is Array and data.get("elements") is Array:
		for controller in marker.controllers:
			if controller is Dictionary:
				data.elements.append(controller)
		marker.erase("controllers")
	if version_of(data) < 2 or not marker.get("clips") is Array:
		return notes
	var elements: Array = data.get("elements", []) if data.get("elements") is Array else []
	var by_path := {}
	for entry in ClipTracks.element_paths(elements):
		by_path[entry.path] = entry.name
	var names := {}
	var ids: Dictionary = marker.get("ids", {}) if marker.get("ids") is Dictionary else {}
	var missing: Array = []
	for path in ids:
		if by_path.has(path):
			names[ids[path]] = by_path[path]
		else:
			# Edited by another tool: keep the track under the element's own name.
			names[ids[path]] = str(path).get_file().get_slice("#", 0)
			missing.append(path)
	var animations: Array = data.get("animations", []) if data.get("animations") is Array else []
	for i in range(marker.clips.size()):
		var entry: Variant = marker.clips[i]
		if not entry is Dictionary:
			continue
		var clip: Variant = animations[i] if i < animations.size() else null
		if not clip is Dictionary or str(clip.get("code", clip.get("name", ""))) != str(entry.get("code", "")):
			clip = null
			for candidate in animations:
				if candidate is Dictionary and str(candidate.get("code", candidate.get("name", ""))) == str(entry.get("code", "")):
					clip = candidate
					break
		if clip == null:
			notes.append("Animation %s has authored keys but no clip in the file; they were skipped." % entry.get("code", ""))
			continue
		clip.keyframes = ClipTracks.to_keyframes(entry, names)
		if entry.get("markers") is Array:
			clip.markers = entry.markers
	marker.erase("clips")
	if not missing.is_empty():
		notes.append("Some animated elements were renamed or moved outside ShapeSmith (%s); their keys were kept by name." % ", ".join(missing.slice(0, 5)))
	return notes


static func export_game(data: Dictionary, options: Dictionary) -> Dictionary:
	var animations: Variant = data.get("animations", [])
	if not animations is Array:
		return {"error": "Animations must be an array."}
	for clip in animations:
		if not clip is Dictionary:
			return {"error": "Each animation must be an object."}
		var error := Baker.validation_error(clip)
		if not error.is_empty():
			return {"error": error}
	var baked := Baker.bake_shape(data, options)
	if not baked.error.is_empty():
		return baked
	var output: Dictionary = Serializer.game_data(baked.data)
	output.erase("shapesmith")
	for clip in output.get("animations", []) if output.get("animations") is Array else []:
		if clip is Dictionary:
			clip.erase("markers")
	_strip_pose_editors(output)
	baked.data = output
	return baked


static func _strip_pose_editors(data: Dictionary) -> void:
	for clip in data.get("animations", []) if data.get("animations") is Array else []:
		if not clip is Dictionary or not clip.get("keyframes") is Array:
			continue
		for key in clip.keyframes:
			if not key is Dictionary or not key.get("elements") is Dictionary:
				continue
			for pose in key.elements.values():
				if pose is Dictionary and pose.get("editor") is Dictionary:
					for field in EDITOR_POSE_FIELDS:
						pose.editor.erase(field)
					if pose.editor.is_empty():
						pose.erase("editor")
