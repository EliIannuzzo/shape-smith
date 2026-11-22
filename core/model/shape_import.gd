extends RefCounted
## Plans File → Import Shape: merging another shape file into the open one.
## Pure data in, data out; the editor turns the plan into one undoable command.
##
## - Element names that clash (ignoring case) are renamed (Head → Head2), and
##   the imported animations and step-parent links follow the new names.
## - A texture ID whose path matches the open shape's is reused; a different
##   path gets a new ID (#body → #body_2) and the imported faces are updated.
##   Relative texture paths are rebased onto the open shape's folder.
## - textureSizes entries come along. If the files' textureWidth/Height
##   differ, the imported UVs are rescaled ("rescale") or the imported textures
##   get a textureSizes override ("sizes").
## - Attachment point codes that clash are renamed and reported.
## - Animations are skipped, merged into clips with the same code ("merge"),
##   or added as new clips with unique codes ("new").

const TextureLibrary = preload("res://core/textures/texture_library.gd")
const FACES := ["north", "east", "south", "west", "up", "down"]


## options: {animations: "merge"|"new"|"skip", uv: "rescale"|"sizes",
## source_dir, target_dir}. Returns {elements, renames, textures,
## texture_renames, texture_sizes, point_renames, clips, poses, mismatch, report}.
static func plan(target: Dictionary, incoming: Dictionary, options: Dictionary = {}) -> Dictionary:
	var result := {"elements": [], "renames": {}, "textures": {}, "texture_renames": {}, "texture_sizes": {},
		"point_renames": [], "clips": [], "poses": [], "mismatch": false, "report": PackedStringArray()}
	var elements: Array = incoming.get("elements", []).duplicate(true) if incoming.get("elements") is Array else []

	# Element names.
	var used := {}
	_collect_names(target.get("elements", []), used)
	for element in elements:
		_rename_elements(element, used, result.renames)
	for element in elements:
		_remap_step_parents(element, result.renames)
	if not result.renames.is_empty():
		result.report.append("Renamed %d element(s) that clashed: %s" % [result.renames.size(), ", ".join(result.renames.keys().map(func(old): return "%s → %s" % [old, result.renames[old]]))])

	# Textures.
	var target_textures: Dictionary = target.get("textures", {}) if target.get("textures") is Dictionary else {}
	var incoming_textures: Dictionary = incoming.get("textures", {}) if incoming.get("textures") is Dictionary else {}
	for id in incoming_textures:
		var value: Variant = _rebase(incoming_textures[id], str(options.get("source_dir", "")), str(options.get("target_dir", "")))
		if target_textures.has(id) and _same(target_textures[id], value):
			continue
		var new_id: String = id
		var suffix := 2
		while target_textures.has(new_id) or result.textures.has(new_id):
			new_id = "%s_%d" % [id, suffix]
			suffix += 1
		result.textures[new_id] = value
		if new_id != id:
			result.texture_renames[id] = new_id
	if not result.texture_renames.is_empty():
		result.report.append("Renamed texture IDs: %s" % ", ".join(result.texture_renames.keys().map(func(old): return "#%s → #%s" % [old, result.texture_renames[old]])))
	for element in elements:
		_retexture(element, result.texture_renames)

	# Texture sizes.
	var target_sizes: Dictionary = target.get("textureSizes", {}) if target.get("textureSizes") is Dictionary else {}
	var incoming_sizes: Dictionary = incoming.get("textureSizes", {}) if incoming.get("textureSizes") is Dictionary else {}
	for id in incoming_sizes:
		var new_id: String = result.texture_renames.get(id, id)
		if not target_sizes.has(new_id):
			result.texture_sizes[new_id] = incoming_sizes[id]
	var target_size := Vector2(float(target.get("textureWidth", 16)), float(target.get("textureHeight", 16)))
	var incoming_size := Vector2(float(incoming.get("textureWidth", 16)), float(incoming.get("textureHeight", 16)))
	if not target_size.is_equal_approx(incoming_size):
		result.mismatch = true
		if options.get("uv", "rescale") == "sizes":
			for id in incoming_textures:
				var new_id: String = result.texture_renames.get(id, id)
				if not result.texture_sizes.has(new_id) and not target_sizes.has(new_id) and not incoming_sizes.has(id):
					result.texture_sizes[new_id] = [incoming_size.x, incoming_size.y]
			result.report.append("Imported textures keep their %d×%d size (textureSizes)." % [incoming_size.x, incoming_size.y])
		else:
			var factor := target_size / incoming_size
			var sized := {}
			for id in incoming_sizes:
				sized["#" + str(result.texture_renames.get(id, id))] = true
			for element in elements:
				_scale_uvs(element, factor, sized)
			result.report.append("Rescaled imported UVs from %d×%d to %d×%d." % [incoming_size.x, incoming_size.y, target_size.x, target_size.y])

	# Attachment point codes.
	var codes := {}
	_collect_codes(target.get("elements", []), codes)
	for element in elements:
		_rename_codes(element, codes, result.point_renames)
	if not result.point_renames.is_empty():
		result.report.append("Renamed attachment points: %s" % ", ".join(result.point_renames.map(func(pair): return "%s → %s" % pair)))

	# Animations.
	var mode := str(options.get("animations", "merge"))
	var incoming_clips: Array = incoming.get("animations", []) if incoming.get("animations") is Array else []
	var target_clips: Array = target.get("animations", []) if target.get("animations") is Array else []
	if mode != "skip":
		var codes_used := {}
		for clip in target_clips:
			if clip is Dictionary:
				codes_used[_code(clip).to_lower()] = true
		for clip in incoming_clips:
			if not clip is Dictionary:
				continue
			var renamed := _rename_tracks(clip, result.renames)
			var match_index := -1
			for i in range(target_clips.size()):
				if target_clips[i] is Dictionary and _code(target_clips[i]).to_lower() == _code(clip).to_lower():
					match_index = i
			if mode == "merge" and match_index >= 0:
				for key in renamed.get("keyframes", []):
					if key is Dictionary and key.get("elements") is Dictionary and float(key.get("frame", 0)) < float(target_clips[match_index].get("quantityframes", target_clips[match_index].get("quantityFrames", 1))):
						for element_name in key.elements:
							result.poses.append({"clip": match_index, "frame": key.frame, "element": element_name, "pose": key.elements[element_name]})
			else:
				var code := _code(renamed)
				var unique := code
				var suffix := 2
				while codes_used.has(unique.to_lower()):
					unique = "%s-%d" % [code, suffix]
					suffix += 1
				codes_used[unique.to_lower()] = true
				if unique != code:
					renamed.code = unique
					result.report.append("Added animation %s as %s." % [code, unique])
				result.clips.append(renamed)
	elif not incoming_clips.is_empty():
		result.report.append("Skipped %d animation(s)." % incoming_clips.size())
	result.elements = elements
	return result


static func _collect_names(elements: Variant, used: Dictionary) -> void:
	if not elements is Array:
		return
	for element in elements:
		if element is Dictionary:
			used[str(element.get("name", "")).to_lower()] = true
			_collect_names(element.get("children", []), used)


static func _rename_elements(element: Dictionary, used: Dictionary, renames: Dictionary) -> void:
	var old := str(element.get("name", ""))
	if not old.is_empty():
		var name := old
		var suffix := 2
		while used.has(name.to_lower()):
			name = "%s%d" % [old, suffix]
			suffix += 1
		used[name.to_lower()] = true
		if name != old:
			element.name = name
			renames[old] = name
	for child in element.get("children", []) if element.get("children") is Array else []:
		if child is Dictionary:
			_rename_elements(child, used, renames)


static func _remap_step_parents(element: Dictionary, renames: Dictionary) -> void:
	if renames.has(element.get("stepParentName")):
		element.stepParentName = renames[element.stepParentName]
	for child in element.get("children", []) if element.get("children") is Array else []:
		if child is Dictionary:
			_remap_step_parents(child, renames)


static func _retexture(element: Dictionary, renames: Dictionary) -> void:
	if element.get("faces") is Dictionary:
		for face in element.faces.values():
			if face is Dictionary and face.get("texture") is String:
				var id: String = face.texture.trim_prefix("#")
				if renames.has(id):
					face.texture = "#" + renames[id]
	for child in element.get("children", []) if element.get("children") is Array else []:
		if child is Dictionary:
			_retexture(child, renames)


static func _scale_uvs(element: Dictionary, factor: Vector2, sized: Dictionary) -> void:
	if element.get("faces") is Dictionary:
		for face in element.faces.values():
			# Faces on textures with their own textureSizes keep their UVs.
			if face is Dictionary and face.get("uv") is Array and face.uv.size() == 4 and not sized.has(face.get("texture")):
				face.uv = [face.uv[0] * factor.x, face.uv[1] * factor.y, face.uv[2] * factor.x, face.uv[3] * factor.y]
	for child in element.get("children", []) if element.get("children") is Array else []:
		if child is Dictionary:
			_scale_uvs(child, factor, sized)


static func _collect_codes(elements: Variant, codes: Dictionary) -> void:
	if not elements is Array:
		return
	for element in elements:
		if not element is Dictionary:
			continue
		for key in ["attachmentpoints", "attachmentPoints"]:
			if element.get(key) is Array:
				for point in element[key]:
					if point is Dictionary:
						codes[str(point.get("code", "")).to_lower()] = true
		_collect_codes(element.get("children", []), codes)


static func _rename_codes(element: Dictionary, codes: Dictionary, renames: Array) -> void:
	for key in ["attachmentpoints", "attachmentPoints"]:
		if element.get(key) is Array:
			for point in element[key]:
				if not point is Dictionary:
					continue
				var old := str(point.get("code", ""))
				var code := old
				var suffix := 2
				while codes.has(code.to_lower()):
					code = "%s%d" % [old, suffix]
					suffix += 1
				codes[code.to_lower()] = true
				if code != old:
					point.code = code
					renames.append([old, code])
	for child in element.get("children", []) if element.get("children") is Array else []:
		if child is Dictionary:
			_rename_codes(child, codes, renames)


static func _code(clip: Dictionary) -> String:
	return str(clip.get("name", "")) if clip.get("code") == null else str(clip.code)


## A copy of the clip with keyframe element keys renamed.
static func _rename_tracks(clip: Dictionary, renames: Dictionary) -> Dictionary:
	var copy := clip.duplicate(true)
	for key in copy.get("keyframes", []) if copy.get("keyframes") is Array else []:
		if key is Dictionary and key.get("elements") is Dictionary:
			var poses := {}
			for element_name in key.elements:
				poses[renames.get(element_name, element_name)] = key.elements[element_name]
			key.elements = poses
	return copy


## Relative texture paths are rebased from the imported file's folder onto the
## open shape's folder; game references (domain:path) and IDs stay as they are.
static func _rebase(value: Variant, source_dir: String, target_dir: String) -> Variant:
	if source_dir.is_empty() or target_dir.is_empty() or source_dir == target_dir:
		return value
	if value is String:
		var layers: PackedStringArray = value.split("++")
		for i in range(layers.size()):
			var parts := layers[i].split("~")
			var base := parts[0]
			if base.is_empty() or base.begins_with("#") or ":" in base or base.is_absolute_path():
				continue
			parts[0] = TextureLibrary.relative_file(target_dir, source_dir.path_join(base).simplify_path())
			layers[i] = "~".join(parts)
		return "++".join(layers)
	if value is Dictionary and value.get("base") is String:
		var copy: Dictionary = value.duplicate(true)
		copy.base = _rebase(copy.base, source_dir, target_dir)
		return copy
	return value


static func _same(a: Variant, b: Variant) -> bool:
	return JSON.stringify(a) == JSON.stringify(b)
