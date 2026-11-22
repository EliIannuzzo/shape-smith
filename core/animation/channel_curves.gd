extends RefCounted
## One animation channel (say Neck rotationX) as a curve through its keys.
##
## A key is {f, v, interp, mode, in, out, preset}:
## - interp: "constant", "linear" or "bezier", for the segment to the next key;
## - mode: how its handles are found. "preset" follows the editor's five
##   presets (handles a third along each segment, which reproduce them
##   exactly); "auto" and "auto_clamped" are smooth (clamped stays flat at a
##   peak or dip); "aligned" and "broken" use the stored handles, aligned
##   keeping both on one line.
## - in/out: handle offsets [frames, value] from the key.
##
## A pose stores a channel's own curve in `editor.curves[channel]` as
## {interp, mode, in, out}; without one the channel follows the group preset.
## The game plays straight lines between keys, so curved spans are baked into
## dense game keys (see AnimationBaker).

const GROUPS := ["offset", "rotation", "stretch"]
const AXES := ["X", "Y", "Z"]
const PRESETS := ["linear", "ease_in", "ease_out", "ease_in_out", "hold"]
const INTERPOLATIONS := ["constant", "linear", "bezier"]
const MODES := ["auto", "auto_clamped", "aligned", "broken"]
## Bezier values at the handles for each preset: [out, in] as fractions of
## the change across the segment.
const PRESET_SHAPES := {"ease_in": [0.0, 1.0 / 3.0], "ease_out": [2.0 / 3.0, 1.0], "ease_in_out": [0.0, 1.0], "linear": [1.0 / 3.0, 2.0 / 3.0]}


## The authored keys of one channel in a clip, with rotation unwrapped along
## the game's shortest-path flags. Returns {keys, cycle, length, loop}.
static func channel(clip: Dictionary, element: String, field: String) -> Dictionary:
	var group := field.substr(0, field.length() - 1)
	var axis := AXES.find(field.right(1))
	var length := maxi(1, int(clip.get("quantityframes", clip.get("quantityFrames", 1))))
	var result := {"keys": [], "cycle": 0.0, "length": length, "loop": loops(clip)}
	if not group in GROUPS or axis < 0:
		return result
	var ordered: Array = (clip.get("keyframes", []) if clip.get("keyframes") is Array else []).filter(
		func(key): return key is Dictionary and (key.get("frame") is float or key.get("frame") is int) and key.get("elements", {}) is Dictionary)
	ordered.sort_custom(func(a, b): return a.frame < b.frame)
	var flags: Array = []
	for key in ordered:
		var pose: Variant = key.elements.get(element)
		if not pose is Dictionary or not AXES.any(func(name): return pose.get(group + name) != null):
			continue
		var raw: Variant = pose.get(field)
		var value := float(raw) if raw is float or raw is int else (1.0 if group == "stretch" else 0.0)
		var entry := {"f": float(key.frame), "v": value, "interp": "linear", "mode": "preset", "preset": "linear", "in": Vector2.ZERO, "out": Vector2.ZERO}
		var editor: Dictionary = pose.get("editor") if pose.get("editor") is Dictionary else {}
		var preset: Variant = editor.get("interpolation", {}).get(group, "linear") if editor.get("interpolation") is Dictionary else "linear"
		entry.preset = preset if preset in PRESETS else "linear"
		entry.interp = "constant" if entry.preset == "hold" else ("linear" if entry.preset == "linear" else "bezier")
		var own: Variant = editor.get("curves", {}).get(field) if editor.get("curves") is Dictionary else null
		if own is Dictionary:
			entry.interp = own.get("interp") if own.get("interp") in INTERPOLATIONS else "bezier"
			entry.mode = own.get("mode") if own.get("mode") in MODES else "auto_clamped"
			entry["in"] = _vector(own.get("in"), Vector2(-1, 0))
			entry.out = _vector(own.get("out"), Vector2(1, 0))
		result.keys.append(entry)
		flags.append(pose.get("rotShortestDistance" + AXES[axis]) == true)
	if group == "rotation" and result.keys.size() > 0:
		var keys: Array = result.keys
		var raws: Array = keys.map(func(key): return key.v)
		for i in range(1, keys.size()):
			keys[i].v = keys[i - 1].v + _rotation_step(raws[i] - raws[i - 1], flags[i - 1])
		result.cycle = keys[-1].v + _rotation_step(raws[0] - raws[-1], flags[-1]) - keys[0].v
	return result


static func _rotation_step(delta: float, shortest: bool) -> float:
	return wrapf(delta, -180.0, 180.0) if shortest else delta


## True when any key has its own curve (not just a preset).
static func has_own_curves(keys: Array) -> bool:
	return keys.any(func(key): return key.mode != "preset")


## Each key's handles as {in, out} Vector2 offsets, resolved for its mode.
static func handles(keys: Array, length: int, loop: bool, cycle := 0.0) -> Array:
	var result: Array = []
	var count := keys.size()
	for i in range(count):
		var key: Dictionary = keys[i]
		var previous := _neighbour(keys, i, -1, length, loop, cycle)
		var next := _neighbour(keys, i, 1, length, loop, cycle)
		var span_in: float = key.f - previous.f if not previous.is_empty() else 0.0
		var span_out: float = next.f - key.f if not next.is_empty() else 0.0
		var entry := {"in": Vector2(-span_in / 3.0, 0), "out": Vector2(span_out / 3.0, 0)}
		match key.mode:
			"preset":
				if not next.is_empty():
					var shape: Array = PRESET_SHAPES.get(key.preset, PRESET_SHAPES.linear)
					entry.out.y = shape[0] * (next.v - key.v)
				if not previous.is_empty():
					var before: Dictionary = keys[(i - 1 + count) % count]
					var shape: Array = PRESET_SHAPES.get(before.preset, PRESET_SHAPES.linear) if before.mode == "preset" else PRESET_SHAPES.linear
					entry["in"].y = (shape[1] - 1.0) * (key.v - previous.v)
			"auto", "auto_clamped":
				var slope := 0.0
				if not previous.is_empty() and not next.is_empty():
					slope = (next.v - previous.v) / maxf(next.f - previous.f, 0.0001)
					if key.mode == "auto_clamped" and ((key.v >= previous.v and key.v >= next.v) or (key.v <= previous.v and key.v <= next.v)):
						slope = 0.0
				elif not next.is_empty() and key.mode == "auto":
					slope = (next.v - key.v) / maxf(span_out, 0.0001)
				elif not previous.is_empty() and key.mode == "auto":
					slope = (key.v - previous.v) / maxf(span_in, 0.0001)
				entry.out.y = slope * span_out / 3.0
				entry["in"].y = -slope * span_in / 3.0
			_:
				entry["in"] = Vector2(clampf(key["in"].x, -span_in, 0.0), key["in"].y)
				entry.out = Vector2(clampf(key.out.x, 0.0, span_out), key.out.y)
		result.append(entry)
	return result


## The key before (-1) or after (1) key i, as {f, v}, shifted across the loop
## seam. Empty at the ends of a clip that does not loop.
static func _neighbour(keys: Array, i: int, step: int, length: int, loop: bool, cycle: float) -> Dictionary:
	var count := keys.size()
	if count < 2:
		return {}
	var j := i + step
	if j >= 0 and j < count:
		return {"f": keys[j].f, "v": keys[j].v}
	if not loop:
		return {}
	if j < 0:
		return {"f": keys[count - 1].f - length, "v": keys[count - 1].v - cycle}
	return {"f": keys[0].f + length, "v": keys[0].v + cycle}


## The channel's value at `time` (frames; may run past the clip when it loops).
static func sample(keys: Array, resolved: Array, time: float, length: int, loop: bool, cycle := 0.0) -> float:
	var count := keys.size()
	if count == 0:
		return 0.0
	if count == 1:
		return keys[0].v
	var turns := floorf(time / length) if loop else 0.0
	var local := fposmod(time, length) if loop else clampf(time, 0.0, float(length))
	var index := -1
	for i in range(count):
		if keys[i].f <= local:
			index = i
	var left: Dictionary
	var right: Dictionary
	var left_handle: Vector2
	var right_handle: Vector2
	var start: float
	var end: float
	var offset := 0.0
	if index == -1:
		if not loop:
			return keys[0].v
		left = keys[count - 1]
		right = keys[0]
		start = left.f - length
		end = right.f
		left_handle = resolved[count - 1].out
		right_handle = resolved[0]["in"]
		offset = -cycle
	elif index == count - 1:
		if not loop:
			return keys[index].v + turns * cycle
		left = keys[index]
		right = keys[0]
		start = left.f
		end = right.f + length
		left_handle = resolved[index].out
		right_handle = resolved[0]["in"]
	else:
		left = keys[index]
		right = keys[index + 1]
		start = left.f
		end = right.f
		left_handle = resolved[index].out
		right_handle = resolved[index + 1]["in"]
	var v0: float = left.v + offset
	var v1: float = right.v + (cycle if index == count - 1 else 0.0)
	if index == -1:
		v1 = right.v
	var span := maxf(end - start, 0.0001)
	var t := (local - start) / span
	var value: float
	match left.interp:
		"constant":
			value = v0
		"linear":
			value = lerpf(v0, v1, t)
		_:
			value = bezier_value(Vector2(0, v0), Vector2(0, v0) + left_handle, Vector2(span, v1) + right_handle, Vector2(span, v1), local - start)
	return value + turns * cycle


## Cubic bezier through four points, evaluated where its x equals `x`.
static func bezier_value(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, x: float) -> float:
	var low := 0.0
	var high := 1.0
	var u := 0.5
	for i in range(30):
		u = (low + high) * 0.5
		var px := _cubic(p0.x, p1.x, p2.x, p3.x, u)
		if px < x:
			low = u
		else:
			high = u
	return _cubic(p0.y, p1.y, p2.y, p3.y, (low + high) * 0.5)


static func _cubic(a: float, b: float, c: float, d: float, u: float) -> float:
	var v := 1.0 - u
	return v * v * v * a + 3.0 * v * v * u * b + 3.0 * v * u * u * c + u * u * u * d


static func loops(clip: Dictionary) -> bool:
	var ending: Variant = clip.get("onAnimationEnd", "Repeat")
	return ending == 0 if ending is int or ending is float else str(ending).to_lower() in ["repeat", "0"]


static func _vector(value: Variant, fallback: Vector2) -> Vector2:
	if value is Array and value.size() == 2 and (value[0] is float or value[0] is int) and (value[1] is float or value[1] is int):
		return Vector2(value[0], value[1])
	return fallback
