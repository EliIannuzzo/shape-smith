extends RefCounted
const Limits = preload("res://core/model/shape_limits.gd")
const Units = preload("res://core/model/shape_units.gd")

const GROUPS := ["offset", "rotation", "stretch"]
const AXES := ["X", "Y", "Z"]
const Math = preload("res://core/animation/vs_animation_math.gd")
const Baker = preload("res://core/animation/animation_baker.gd")
var elements: Dictionary = {}
var clips: Array[Dictionary] = []
var warning := ""


func bind(shape: Node3D, data: Dictionary) -> void:
	elements.clear()
	clips.clear()
	warning = ""
	_collect(shape)
	refresh_clips(data)


## Re-reads which nodes carry which element names, after elements were added,
## removed or moved, without recompiling clips.
func rebind_elements(shape: Node3D) -> void:
	elements.clear()
	_collect(shape)


func refresh_clips(data: Dictionary) -> void:
	# Keep original rest transforms when metadata is edited during playback.
	clips.clear()
	warning = ""
	var animations: Variant = data.get("animations", [])
	if not animations is Array:
		warning = "The shape's animations field must be an array."
		return

	for i in range(animations.size()):
		var clip := _compile(animations[i], i)
		clip.generated_keyframes = []
		if clip.error.is_empty() and Baker.has_curves(animations[i]):
			var baked := Baker.bake_clip(animations[i], Baker.settings(data))
			if baked.error.is_empty():
				clip = _compile(baked.clip, i)
				clip.keyframes = animations[i].keyframes
				clip.generated_keyframes = baked.generated
			else:
				clip.error = baked.error
		clips.append(clip)


func _collect(node: Node) -> void:
	if node.has_meta("shape_element"):
		var source: Dictionary = node.get_meta("shape_element")
		var name := str(source.get("name", ""))
		if not elements.has(name):
			elements[name] = []
		elements[name].append({"node": node, "rest": node.transform, "source": source})
	for child in node.get_children():
		_collect(child)


func _compile(value: Variant, index: int) -> Dictionary:
	var clip := {"name": "Animation %d" % (index + 1), "code": "", "frames": 1, "version": 0,
		"tracks": {}, "keyframes": [], "loop": true, "error": "", "warning": "", "resolved": false, "source": value}
	if not value is Dictionary:
		clip.error = "Animation must be an object."
		return clip

	clip.name = str(value.get("name", value.get("code", clip.name)))
	clip.code = str(value.get("code", clip.name))
	var frames: Variant = value.get("quantityframes", value.get("quantityFrames", 0))
	var version: Variant = value.get("version", 0)
	if not _number(frames) or frames < 1 or frames > Limits.MAX_ANIMATION_FRAMES or frames != floor(frames):
		clip.error = "quantityframes must be a whole number between 1 and 100,000."
		return clip

	if not _number(version) or (version != 0.0 and version != 1.0):
		clip.error = "Only animation versions 0 and 1 are supported."
		return clip

	clip.frames = int(frames)
	clip.version = int(version)
	var ending: Variant = value.get("onAnimationEnd", "Repeat")
	clip.loop = ending == 0 if ending is int or ending is float else str(ending).to_lower() in ["repeat", "0"]
	var keyframes: Variant = value.get("keyframes", [])
	if not keyframes is Array or keyframes.is_empty():
		clip.error = "Animation has no keyframes."
		return clip

	clip.keyframes = keyframes
	var seen: Dictionary = {}
	for key in keyframes:
		if not key is Dictionary or not _number(key.get("frame")):
			clip.error = "Each keyframe needs a numeric frame."
			return clip

		var frame: float = key.frame
		if frame < 0 or frame >= frames or frame != floor(frame) or seen.has(frame):
			clip.error = "Keyframe numbers must be unique and within the animation's frame range."
			return clip

		seen[frame] = true
		if not key.get("elements", {}) is Dictionary:
			clip.error = "Keyframe elements must be an object."
			return clip

		for name in key.get("elements", {}):
			var pose: Variant = key.elements[name]
			if not pose is Dictionary:
				clip.error = "Each animated element must contain an object."
				return clip

			if not elements.has(name):
				clip.warning = "Some tracks refer to elements outside this shape and are skipped."
				continue

			if not clip.tracks.has(name):
				clip.tracks[name] = {"offset": [], "rotation": [], "stretch": []}
			for group in GROUPS:
				var sample := Vector3.ONE if group == "stretch" else Vector3.ZERO
				var shortest := [false, false, false]
				var has_value := false
				for axis in range(3):
					var field: String = group + AXES[axis]
					if pose.get(field) != null:
						if not _number(pose[field]):
							clip.error = "Animation transforms must contain finite numbers."
							return clip

						sample[axis] = float(pose[field])
						has_value = true
					shortest[axis] = pose.get("rotShortestDistance" + AXES[axis], false) == true
				if has_value:
					clip.tracks[name][group].append({"frame": frame, "value": sample, "shortest": shortest})
	return clip


func ensure_resolved(clip: Dictionary) -> void:
	if clip.resolved:
		return
	# Resolve on first use, so opening a large multi-animation model does not
	# allocate every clip's complete pose table at once.
	for name in clip.tracks:
		clip.tracks[name] = Math.build_track(clip.source, name)
	clip.resolved = true


func restore() -> void:
	for entries in elements.values():
		for entry in entries:
			if is_instance_valid(entry.node):
				entry.node.transform = entry.rest


func apply(clip: Dictionary, frame: float, blend_weight := 1.0) -> void:
	if not clip.error.is_empty():
		return

	ensure_resolved(clip)
	for name in elements:
		var track: Dictionary = clip.tracks.get(name, {"offset": [], "rotation": [], "stretch": []})
		var offset := Math.sample(track.offset, frame, clip.frames, Vector3.ZERO, false, -1, -1, blend_weight) / Units.PER_BLOCK
		var rotation := Math.sample(track.rotation, frame, clip.frames, Vector3.ZERO, true, -1, -1, blend_weight)
		var stretch := Math.sample(track.stretch, frame, clip.frames, Vector3.ONE, false, -1, -1, blend_weight)
		for entry in elements[name]:
			if is_instance_valid(entry.node):
				entry.node.transform = element_transform(entry.source, offset, rotation, stretch, clip.version)


func sample_track(keys: Array, frame: float, length: int, fallback: Vector3, angular := false) -> Vector3:
	return Math.sample(keys, frame, length, fallback, angular)


func element_transform(source: Dictionary, offset: Vector3, rotation: Vector3, stretch: Vector3, version: int) -> Transform3D:
	var start := vector_from_array(source.from) / Units.PER_BLOCK
	var pivot := vector_from_array(source.get("rotationOrigin", [0, 0, 0])) / Units.PER_BLOCK
	var base_rotation := Vector3(source.get("rotationX", 0), source.get("rotationY", 0), source.get("rotationZ", 0))
	var base_scale := Vector3(source.get("scaleX", 1), source.get("scaleY", 1), source.get("scaleZ", 1))
	if version == 1:
		var basis := Basis.from_scale(base_scale) * rotation_basis(base_rotation)
		var transform := Transform3D(basis, pivot + basis * (start - pivot + offset))
		return transform * Transform3D(Basis.from_scale(stretch) * rotation_basis(rotation), Vector3.ZERO)

	var basis := rotation_basis(base_rotation + rotation) * Basis.from_scale(base_scale * stretch)
	return Transform3D(basis, pivot + basis * (start + offset - pivot))


func rotation_basis(degrees: Vector3) -> Basis:
	return Basis(Vector3.RIGHT, deg_to_rad(degrees.x)) * Basis(Vector3.UP, deg_to_rad(degrees.y)) * Basis(Vector3.BACK, deg_to_rad(degrees.z))


func vector_from_array(value: Array) -> Vector3:
	return Vector3(value[0], value[1], value[2])


func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and absf(float(value)) <= Limits.MAX_COORDINATE
