extends Node
## IK chains (the IK tab in Animation mode): bones that follow a target
## controller instead of their own keys.
##
## Four kinds: "ik2" (two bones, such as a thigh and shin, bend so the tip
## reaches the target, the knee towards an optional pole), "ik3" (three bones
## for a hind leg, kept in the pole's plane), "chain" (any number of bones,
## such as a tail or neck, bending freely) and "aim" (one bone,
## such as a head, turns to point at the target).
##
## Controllers are editor-only empty elements (`shapesmithController`), so
## they are moved and keyed like any element; a chain works in clips where its
## target controller has keys. Its strength (0 to 1) is the chain's weight,
## optionally keyed per clip. Chains are kept in `shapesmith.rigs` as {kind,
## chain: [bones], target, pole, tip, weight, enabled, weights: {clip code:
## [{frame, value}]}}. The game knows nothing of them: saving and exporting
## bake each active chain into rotation keys and leave the controllers out of
## the game data (a working file keeps them under `shapesmith.controllers`).

const IK = preload("res://core/animation/two_bone_ik.gd")
const Baker = preload("res://core/animation/animation_baker.gd")
const Document = preload("res://core/document/shape_document.gd")
const AddElements = preload("res://core/commands/add_elements.gd")
const DeleteElements = preload("res://core/commands/delete_elements.gd")
const SetDataEntries = preload("res://core/commands/set_data_entries.gd")
const Composite = preload("res://core/commands/composite_command.gd")
const ReplaceClip = preload("res://core/commands/replace_clip.gd")
const CONTROLLER_KEY := "shapesmithController"
const KINDS := {"ik2": "Two bones (leg, arm)", "ik3": "Three bones (hind leg)", "chain": "Chain (tail, neck)", "aim": "Aim (head, eye, turret)"}
const KIND_LABELS := {"ik2": "two bones", "ik3": "three bones", "chain": "chain", "aim": "aim"}
const KIND_HELP := {
	"ik2": "The tip of the lower bone reaches the target, and the joint bends towards the pole.",
	"ik3": "For hind legs: thigh, shin and the long foot bone. The tip reaches the target, the bones stay in the pole's plane and the knee points at the pole, so the leg keeps its zig-zag.",
	"chain": "For tails and necks: every bone from the first to the last bends a little so the tip follows the target.",
	"aim": "One bone turns to point at the target.",
}
static var Palette = preload("res://ui/theme/editor_palette.tres")

signal changed

var app
var markers: Control
## Each chain bone's keyed (FK) local transform at the shown frame, before IK,
## so chains can be solved again while a controller is dragged.
var _fk: Dictionary = {}


func bind(target_app) -> void:
	app = target_app
	markers = Control.new()
	markers.name = "ControllerMarkers"
	markers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	markers.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	markers.draw.connect(_draw_markers)
	app.viewport.add_child(markers)
	app.viewport.click_handlers.append(pick_controller)


func _process(_delta: float) -> void:
	if markers != null:
		markers.queue_redraw()
	# Dragging anything in Animation mode (a controller, or a bone above a
	# chain) re-solves the chains live, before the frame is drawn.
	if app != null and app.workspace.animation_mode and app.viewport.gizmo.dragging:
		live_solve()
	# Keyed strength changes along the clip: keep the slider on the playhead.
	if list != null and list.is_visible_in_tree() and roundi(app.workspace.frame) != _shown_frame:
		_shown_frame = roundi(app.workspace.frame)
		_sync_settings()


# --- Data ------------------------------------------------------------------------------

func rigs() -> Array:
	var marker: Variant = app.viewport.shape_data.get("shapesmith")
	var value: Variant = marker.get("rigs", []) if marker is Dictionary else []
	# Copies: edits go through set_rigs(), so undo can restore the old chains.
	return value.filter(func(rig): return rig is Dictionary).map(func(rig): return rig.duplicate(true)) if value is Array else []


func set_rigs(value: Array, label := "Change IK") -> bool:
	return app.history.execute(_rigs_command(value, label))


func _rigs_command(value: Array, label: String):
	return SetDataEntries.new(app.viewport.shape_data, "shapesmith", {"rigs": value if not value.is_empty() else Document.ABSENT}, label, _on_rigs_changed)


func _on_rigs_changed() -> void:
	changed.emit()
	app.workspace.refresh_preview()


static func is_controller(source: Variant) -> bool:
	return source is Dictionary and source.get(CONTROLLER_KEY, false) == true


func _node(name_value: String) -> Node3D:
	if name_value.is_empty():
		return null
	var entries: Array = app.workspace.animation.elements.get(name_value, [])
	return entries[0].node if entries.size() == 1 and is_instance_valid(entries[0].node) else null


func controllers() -> Array:
	var result: Array = []
	for node in app.viewport.Geometry.elements(app.viewport.models):
		if is_controller(node.get_meta("shape_element")):
			result.append(node)
	return result


static func bones_of(rig: Dictionary) -> Array:
	return rig.get("chain", []) if rig.get("chain") is Array else []


## Chains active in a compiled clip: their target controller is keyed there.
func active_rigs(compiled: Dictionary) -> Array:
	if compiled.is_empty() or not compiled.get("error", "").is_empty():
		return []
	return rigs().filter(func(rig): return rig.get("enabled", true) != false and compiled.tracks.has(str(rig.get("target", ""))) \
		and _bone_count_fits(str(rig.get("kind", "ik2")), bones_of(rig).size()))


static func _bone_count_fits(kind: String, count: int) -> bool:
	match kind:
		"aim": return count == 1
		"ik3": return count == 3
		"chain": return count >= 2
	return count == 2


## A chain's strength at a frame of a clip: its weight, times its keyed
## strength in that clip (straight lines between keys, held past the ends).
static func weight_at(rig: Dictionary, code: String, frame: float) -> float:
	var base := clampf(float(rig.get("weight", 1.0)), 0.0, 1.0)
	var keys: Variant = rig.get("weights", {}).get(code) if rig.get("weights") is Dictionary else null
	if not keys is Array or keys.is_empty():
		return base
	var sorted: Array = keys.duplicate()
	sorted.sort_custom(func(a, b): return a.frame < b.frame)
	if frame <= float(sorted[0].frame):
		return base * float(sorted[0].value)
	for i in range(sorted.size() - 1):
		if frame <= float(sorted[i + 1].frame):
			var span := maxf(float(sorted[i + 1].frame) - float(sorted[i].frame), 0.0001)
			return base * lerpf(float(sorted[i].value), float(sorted[i + 1].value), (frame - float(sorted[i].frame)) / span)
	return base * float(sorted[-1].value)


func _clip_code() -> String:
	var workspace = app.workspace
	if workspace.selected < 0 or workspace.selected >= workspace.animation.clips.size():
		return ""
	return str(workspace.animation.clips[workspace.selected].code)


# --- Creating and removing chains -------------------------------------------------------

## Makes a two-bone chain from `lower` (a shin or forearm) and its parent, with
## a target controller at the lower bone's tip and a pole in front of the bend.
## One undo step. Returns an error message, or "".
func add_chain(lower: Node3D) -> String:
	if not is_instance_valid(lower) or not lower.get_parent() is Node3D or not lower.get_parent().has_meta("shape_element"):
		return "Select the lower bone of the chain (a shin or forearm); it needs a parent to bend from."
	return create_chain({"kind": "ik2", "bones": [lower.get_parent(), lower], "pole": true})


## Creates a chain from a dialog's choices: {kind, bones: [Node3D], pole:
## bool, target_name, pole_name, weight}. One undo step.
func create_chain(config: Dictionary) -> String:
	var kind: String = config.get("kind", "ik2")
	var bones: Array = config.get("bones", [])
	if not _bone_count_fits(kind, bones.size()) or bones.any(func(node): return not is_instance_valid(node) or not node.has_meta("shape_element") or is_controller(node.get_meta("shape_element"))):
		return "Choose the bone to aim." if kind == "aim" else ("A chain needs at least two bones." if kind == "chain" else "Choose the bones of the chain.")
	var names: Array = bones.map(func(node): return str(node.get_meta("shape_element").get("name", "")))
	for name_value in names:
		if name_value.is_empty() or app.workspace.animation.elements.get(name_value, []).size() != 1:
			return "Give %s a unique name first: animation finds elements by name." % (name_value if not name_value.is_empty() else "each bone")
	for i in range(1, bones.size()):
		if not bones[i - 1].is_ancestor_of(bones[i]):
			return "%s must be inside %s." % [names[i], names[i - 1]]
	if rigs().any(func(rig): return bones_of(rig).any(func(bone): return bone in names)):
		return "%s is already in an IK chain." % ", ".join(names)
	var last: Node3D = bones[-1]
	var tip := _default_tip(last.get_meta("shape_element"))
	var root: Node3D = app.viewport.models.get_child(0)
	var tip_world: Vector3 = last.global_transform * (tip / 16.0)
	var target_name := _unique(str(config.get("target_name", names[-1] + " IK")).strip_edges())
	var spots := [[target_name, tip_world]]
	var pole_name := ""
	if kind in ["ik2", "ik3"] and config.get("pole", true):
		# In front of the knee: the first joint, away from the root-to-tip line.
		var a: Vector3 = IK.pivot_world(bones[0], bones[0].get_meta("shape_element"), 0)
		var b: Vector3 = IK.pivot_world(bones[1], bones[1].get_meta("shape_element"), 0)
		var bend := b - (a + tip_world) * 0.5
		if bend.length() < 0.01:
			bend = Vector3.BACK
		pole_name = _unique(str(config.get("pole_name", names[1] + " Pole")).strip_edges(), [target_name])
		spots.append([pole_name, b + bend.normalized() * maxf(a.distance_to(b), 0.25)])
	var items: Array = []
	for spot in spots:
		var local: Vector3 = root.global_transform.affine_inverse() * spot[1] * 16.0
		var at := [snappedf(local.x, 0.01), snappedf(local.y, 0.01), snappedf(local.z, 0.01)]
		# The rotation origin on the controller puts its gizmo on it.
		items.append({"source": {"name": spot[0], "from": at, "to": at.duplicate(), "rotationOrigin": at.duplicate(), CONTROLLER_KEY: true, "faces": {}}})
	var list := rigs()
	list.append({"kind": kind, "chain": names, "target": target_name, "pole": pole_name,
		"tip": [snappedf(tip.x, 0.001), snappedf(tip.y, 0.001), snappedf(tip.z, 0.001)],
		"weight": clampf(float(config.get("weight", 1.0)), 0.0, 1.0), "enabled": true})
	var ok: bool = app.history.execute(Composite.new(app.document, [AddElements.new(app.document, items, "Add IK Controllers"), _rigs_command(list, "Add IK Chain")], "Add IK Chain"))
	return "" if ok else "Could not add the chain."


## The tip of a bone: the centre of its face farthest from where it turns.
static func _default_tip(source: Dictionary) -> Vector3:
	var start := IK._vector(source.get("from", [0, 0, 0]))
	var size := IK._vector(source.get("to", [0, 0, 0])) - start
	var pivot := IK._vector(source.get("rotationOrigin", source.get("from", [0, 0, 0]))) - start
	var best := Vector3.ZERO
	var far := -1.0
	for axis in range(3):
		for side in [0.0, 1.0]:
			var point := size * 0.5
			point[axis] = size[axis] * side
			if point.distance_to(pivot) > far:
				far = point.distance_to(pivot)
				best = point
	return best


func _unique(base: String, taken: Array = []) -> String:
	if base.is_empty():
		base = "IK"
	var value := base
	var count := 2
	while app.workspace.animation.elements.has(value) or app.document.find_by_name(value) != "" or value in taken:
		value = "%s %d" % [base, count]
		count += 1
	return value


## Removes a chain and the controllers only it used, as one undo step.
func remove_chain(index: int) -> bool:
	var list := rigs()
	if index < 0 or index >= list.size():
		return false
	var removed: Dictionary = list[index]
	list.remove_at(index)
	var still_used := {}
	for rig in list:
		still_used[str(rig.get("target", ""))] = true
		still_used[str(rig.get("pole", ""))] = true
	var uids: Array = []
	for name_value in [str(removed.get("target", "")), str(removed.get("pole", ""))]:
		if name_value.is_empty() or still_used.has(name_value):
			continue
		var uid: String = app.document.find_by_name(name_value)
		if not uid.is_empty() and is_controller(app.document.source(uid)):
			uids.append(uid)
	var steps: Array = [_rigs_command(list, "Remove IK Chain")]
	if not uids.is_empty():
		steps.append(DeleteElements.new(app.document, uids, "Remove IK Controllers"))
	return app.history.execute(Composite.new(app.document, steps, "Remove IK Chain"))


func change(index: int, field: String, value: Variant) -> bool:
	var list := rigs()
	if index < 0 or index >= list.size():
		return false
	list[index][field] = value
	return set_rigs(list, "Change IK Chain")


## Keys a chain's strength at the playhead in the current clip.
func key_weight(index: int, value: float) -> bool:
	var list := rigs()
	var code := _clip_code()
	if index < 0 or index >= list.size() or code.is_empty():
		return false
	var frame := roundi(app.workspace.frame)
	var weights: Dictionary = list[index].get("weights", {}) if list[index].get("weights") is Dictionary else {}
	var keys: Array = (weights.get(code, []) as Array).filter(func(key): return int(key.frame) != frame)
	keys.append({"frame": frame, "value": clampf(value, 0.0, 1.0)})
	keys.sort_custom(func(a, b): return a.frame < b.frame)
	weights[code] = keys
	list[index].weights = weights
	# With keys, they alone set the strength.
	list[index].weight = 1.0
	return set_rigs(list, "Key IK Strength")


## Removes a chain's strength keys in the current clip.
func clear_weight_keys(index: int) -> bool:
	var list := rigs()
	var code := _clip_code()
	if index < 0 or index >= list.size() or not list[index].get("weights") is Dictionary or not list[index].weights.has(code):
		return false
	list[index].weights.erase(code)
	if list[index].weights.is_empty():
		list[index].erase("weights")
	return set_rigs(list, "Clear IK Strength Keys")


# --- Solving ---------------------------------------------------------------------------

## Poses the active chains on top of the clip's pose at `frame`.
func apply(compiled: Dictionary, frame: float) -> void:
	_fk.clear()
	for rig in active_rigs(compiled):
		for name_value in bones_of(rig):
			var node := _node(str(name_value))
			if node != null:
				_fk[node] = node.transform
		solve_rig(rig, compiled, frame)


## Solves again from the keyed pose (while something is being dragged).
func live_solve() -> void:
	var workspace = app.workspace
	if workspace.selected < 0 or workspace.selected >= workspace.animation.clips.size():
		return
	var compiled: Dictionary = workspace.animation.clips[workspace.selected]
	for rig in active_rigs(compiled):
		for name_value in bones_of(rig):
			var node := _node(str(name_value))
			if node != null and _fk.has(node) and node != app.viewport.selected_node:
				node.transform = _fk[node]
		solve_rig(rig, compiled, workspace.frame)


func solve_rig(rig: Dictionary, compiled: Dictionary, frame: float) -> void:
	var bones := bones_of(rig)
	var target := _node(str(rig.get("target", "")))
	if target == null:
		return
	var weight := weight_at(rig, str(compiled.get("code", "")), frame)
	var animation = app.workspace.animation
	animation.ensure_resolved(compiled)
	var tip := IK._vector(rig.get("tip", [0, 0, 0])) / 16.0
	if rig.get("kind", "ik2") == "aim":
		var bone := _node(str(bones[0]))
		if bone == null:
			return
		var pivot := IK.pivot_world(bone, bone.get_meta("shape_element"), compiled.version, _offset(compiled, str(bones[0]), frame))
		bone.global_transform = IK.aim(bone.global_transform, pivot, bone.global_transform * tip, target.global_transform.origin, weight)
		return
	var pole := _node(str(rig.get("pole", "")))
	if rig.get("kind", "ik2") in ["ik3", "chain"]:
		var nodes: Array = bones.map(func(name_value): return _node(str(name_value)))
		if nodes.has(null):
			return
		for i in range(1, nodes.size()):
			if not nodes[i - 1].is_ancestor_of(nodes[i]):
				return
		var globals: Array = nodes.map(func(node): return node.global_transform)
		var pivots: Array = []
		for i in range(nodes.size()):
			pivots.append(IK.pivot_world(nodes[i], nodes[i].get_meta("shape_element"), compiled.version, _offset(compiled, str(bones[i]), frame)))
		var solved := IK.solve_chain(globals, pivots, nodes[-1].global_transform * tip, target.global_transform.origin,
			pole.global_transform.origin if pole != null and rig.kind == "ik3" else null, weight, rig.kind == "ik3")
		for i in range(nodes.size()):
			nodes[i].global_transform = solved[i]
		return
	var upper := _node(str(bones[0]))
	var lower := _node(str(bones[1]))
	if upper == null or lower == null or not upper.is_ancestor_of(lower):
		return
	var a := IK.pivot_world(upper, upper.get_meta("shape_element"), compiled.version, _offset(compiled, str(bones[0]), frame))
	var b := IK.pivot_world(lower, lower.get_meta("shape_element"), compiled.version, _offset(compiled, str(bones[1]), frame))
	var result := IK.solve(upper.global_transform, lower.global_transform, a, b, lower.global_transform * tip, target.global_transform.origin,
		pole.global_transform.origin if pole != null else null, weight)
	upper.global_transform = result.upper
	lower.global_transform = result.lower


func _offset(compiled: Dictionary, name_value: String, frame: float) -> Vector3:
	var track: Dictionary = compiled.tracks.get(name_value, {"offset": []})
	if not track.get("offset") is Array or track.offset.is_empty() or not track.offset[0] is Dictionary:
		return Vector3.ZERO
	return app.workspace.animation.sample_track(track.offset, frame, compiled.frames, Vector3.ZERO) / 16.0


## Rotation keys reproducing the active chains of clip `index`, frame by
## frame, reduced within the export tolerances: {element: [{frame, value}]}.
## Each chain's bones are keyed only at the frames where something that moves
## the chain is keyed in `records` (a clip's keyframes): its target or pole,
## an element above the chain, or its strength. The game plays straight lines
## between keys and allows little animation data, so keys between them would
## add nothing. For smoother IK, give the target's keys an ease: saving and
## exporting bake eased spans into in-between keys first, and `records` are
## those game keys, so the chain is keyed at them too.
func bake(index: int, records: Array) -> Dictionary:
	var animation = app.workspace.animation
	if index < 0 or index >= animation.clips.size():
		return {}
	var compiled: Dictionary = animation.clips[index]
	var active := active_rigs(compiled)
	if active.is_empty():
		return {}
	animation.ensure_resolved(compiled)
	var names: Array = []
	for rig in active:
		for name_value in bones_of(rig):
			if not name_value in names:
				names.append(name_value)
	var keyed := _driving_frames(records, active, str(compiled.get("code", "")))
	var times: Array = []
	var values: Array = []
	var previous := {}
	# Every frame is still solved, in order, so rotations stay continuous.
	for time in range(compiled.frames):
		animation.apply(compiled, time)
		apply(compiled, time)
		var entry := {}
		for name_value in names:
			var node := _node(name_value)
			if node == null:
				continue
			var source: Dictionary = node.get_meta("shape_element")
			var track: Dictionary = compiled.tracks.get(name_value, {"rotation": [], "stretch": []})
			var stretch: Vector3 = animation.sample_track(track.get("stretch", []), time, compiled.frames, Vector3.ONE)
			var reference: Vector3 = previous.get(name_value, animation.sample_track(track.get("rotation", []), time, compiled.frames, Vector3.ZERO, true))
			var rotation := IK.anim_rotation(source, node.transform, stretch, reference, compiled.version)
			previous[name_value] = rotation
			entry[name_value] = {"rotation": rotation}
		times.append(time)
		values.append(entry)
	_restore_preview()
	var result := {}
	for name_value in names:
		result[name_value] = []
		for i in range(times.size()):
			if values[i].has(name_value) and keyed.get(name_value, {}).has(int(times[i])):
				result[name_value].append({"frame": int(times[i]), "value": values[i][name_value].rotation})
	return result


## For each bone of the active chains: the frames (a set) where its chain is
## driven by a key in `records`: the target, the pole, an element above the
## chain (a body moving over a planted foot), or a strength key in clip `code`.
func _driving_frames(records: Array, active: Array, code: String) -> Dictionary:
	var result := {}
	for rig in active:
		var drivers: Array = [str(rig.get("target", "")), str(rig.get("pole", ""))].filter(func(name_value): return not name_value.is_empty())
		var top := _node(str(bones_of(rig)[0])) if not bones_of(rig).is_empty() else null
		var above: Node = top.get_parent() if top != null else null
		while above is Node3D and above.has_meta("shape_element"):
			drivers.append(str(above.get_meta("shape_element").get("name", "")))
			above = above.get_parent()
		var frames := {}
		for record in records:
			if record is Dictionary and record.get("elements") is Dictionary and drivers.any(func(name_value): return record.elements.has(name_value)):
				frames[roundi(float(record.get("frame", 0)))] = true
		var strength: Variant = rig.get("weights", {}).get(code) if rig.get("weights") is Dictionary else null
		for key in strength if strength is Array else []:
			if key is Dictionary:
				frames[roundi(float(key.get("frame", 0)))] = true
		for name_value in bones_of(rig):
			var merged: Dictionary = result.get(name_value, {})
			merged.merge(frames)
			result[name_value] = merged
	return result


func _restore_preview() -> void:
	var workspace = app.workspace
	if workspace.animation_mode and workspace.selected >= 0 and workspace.selected < workspace.animation.clips.size():
		workspace._apply_pose(workspace.animation.clips[workspace.selected], workspace.frame)
	else:
		workspace.animation.restore()


## Replaces the chain elements' rotation keys in `clip` with baked ones.
## Returns how many keys were written.
static func merge(clip: Dictionary, baked: Dictionary) -> int:
	if baked.is_empty() or not clip.get("keyframes") is Array:
		return 0
	for record in clip.keyframes:
		if not record is Dictionary or not record.get("elements") is Dictionary:
			continue
		for name_value in baked:
			var pose: Variant = record.elements.get(name_value)
			if not pose is Dictionary:
				continue
			for axis in ["X", "Y", "Z"]:
				pose.erase("rotation" + axis)
				pose.erase("rotShortestDistance" + axis)
			if pose.get("editor") is Dictionary:
				if pose.editor.get("interpolation") is Dictionary:
					pose.editor.interpolation.erase("rotation")
				if pose.editor.get("curves") is Dictionary:
					for axis in ["X", "Y", "Z"]:
						pose.editor.curves.erase("rotation" + axis)
			if not ["offset", "stretch"].any(func(group): return ["X", "Y", "Z"].any(func(axis): return pose.get(group + axis) != null)):
				record.elements.erase(name_value)
	var count := 0
	for name_value in baked:
		for key in baked[name_value]:
			var target: Dictionary = {}
			for record in clip.keyframes:
				if record is Dictionary and int(record.get("frame", -1)) == key.frame:
					target = record
			if target.is_empty():
				target = {"frame": float(key.frame), "elements": {}}
				clip.keyframes.append(target)
			if not target.get("elements") is Dictionary:
				target.elements = {}
			var pose: Dictionary = target.elements.get(name_value, {})
			for axis in range(3):
				pose["rotation" + ["X", "Y", "Z"][axis]] = key.value[axis]
				pose["rotShortestDistance" + ["X", "Y", "Z"][axis]] = false
			target.elements[name_value] = pose
			count += 1
	clip.keyframes = clip.keyframes.filter(func(record): return not (record is Dictionary and record.get("elements", {}).is_empty()))
	if clip.keyframes.is_empty():
		clip.keyframes.append({"frame": 0.0, "elements": {}})
	clip.keyframes.sort_custom(func(x, y): return x.frame < y.frame)
	return count


## IK → Bake to Keys: writes the current clip's chains as ordinary rotation
## keys at the frames where their targets (or poles) are keyed, one undo step.
func bake_to_keys(index: int) -> int:
	var baked := bake(index, app.workspace.editor.clips()[index].get("keyframes", []))
	if baked.is_empty():
		return 0
	var editor = app.workspace.editor
	var clip: Dictionary = editor.clips()[index].duplicate(true)
	var count := merge(clip, baked)
	var view := {"index": index, "frame": app.workspace.frame}
	app.history.execute(ReplaceClip.new(editor.data, index, clip, "Bake IK to Keys", editor._notify, view, view))
	return count


# --- Saving and exporting ----------------------------------------------------------------

## Takes the controllers out of shape data for saving: returns their element
## dictionaries (root controllers; they are always created at the root).
static func split_controllers(data: Dictionary) -> Array:
	var result: Array = []
	if not data.get("elements") is Array:
		return result
	var kept: Array = []
	for element in data.elements:
		if is_controller(element):
			result.append(element)
		else:
			kept.append(element)
	data.elements = kept
	return result


## The game side of a save or export: bakes the active chains into the
## animations and removes the controllers' keys. Returns keys written.
func finish_game_animations(output: Dictionary, controller_list: Array, with_ik := true) -> int:
	var count := 0
	var names: Array = controller_list.map(func(element): return str(element.get("name", "")))
	var animations: Array = output.get("animations", []) if output.get("animations") is Array else []
	for i in range(animations.size()):
		if not animations[i] is Dictionary:
			continue
		if with_ik:
			# The game keys, with eased spans already baked into in-betweens.
			count += merge(animations[i], bake(i, animations[i].get("keyframes", []) if animations[i].get("keyframes") is Array else []))
		for record in animations[i].get("keyframes", []):
			if record is Dictionary and record.get("elements") is Dictionary:
				for name_value in names:
					record.elements.erase(name_value)
		if animations[i].get("keyframes") is Array:
			animations[i].keyframes = animations[i].keyframes.filter(func(record): return not (record is Dictionary and record.get("elements", {}).is_empty()))
			if animations[i].keyframes.is_empty():
				animations[i].keyframes.append({"frame": 0, "elements": {}})
	return count


# --- Viewport markers ---------------------------------------------------------------------

func _draw_markers() -> void:
	if app == null or app.current_mode not in ["Model", "Animation"]:
		return
	var camera: Camera3D = app.viewport.camera
	var font := ThemeDB.fallback_font
	var poles: Array = rigs().map(func(rig): return str(rig.get("pole", "")))
	for node in controllers():
		var world: Vector3 = node.global_transform.origin
		if camera.is_position_behind(world) or not node.is_visible_in_tree():
			continue
		var point: Vector2 = camera.unproject_position(world)
		var chosen: bool = app.viewport.selected_node == node
		var name_value := str(node.get_meta("shape_element").get("name", ""))
		var color: Color = Color("c58cff") if name_value in poles else Color("ff9f43")
		var size := 7.0 if chosen else 5.5
		var shape := PackedVector2Array([point + Vector2(0, -size), point + Vector2(size, 0), point + Vector2(0, size), point + Vector2(-size, 0), point + Vector2(0, -size)])
		markers.draw_polyline(shape, color, 2.0 if chosen else 1.5)
		markers.draw_string(font, point + Vector2(9, -6), name_value, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
	for rig in rigs():
		var bones := bones_of(rig)
		var lower := _node(str(bones[-1])) if not bones.is_empty() else null
		var pole := _node(str(rig.get("pole", "")))
		if lower != null and pole != null and not camera.is_position_behind(pole.global_transform.origin) and not camera.is_position_behind(lower.global_transform.origin):
			markers.draw_dashed_line(camera.unproject_position(lower.global_transform.origin), camera.unproject_position(pole.global_transform.origin), Color("c58cff", 0.5), 1.0, 4.0)


## Clicking a controller marker selects it.
func pick_controller(position: Vector2) -> bool:
	if app == null or app.current_mode not in ["Model", "Animation"]:
		return false
	var camera: Camera3D = app.viewport.camera
	for node in controllers():
		var world: Vector3 = node.global_transform.origin
		if not camera.is_position_behind(world) and node.is_visible_in_tree() and camera.unproject_position(world).distance_to(position) <= 9.0:
			app.viewport.element_picked.emit(node, "")
			return true
	return false


# --- IK tab ----------------------------------------------------------------------------------

var list: ItemList
var enabled_box: CheckBox
var weight: HSlider
var weight_label: Label
var pole_choice: OptionButton
var keys_label: Label
var message: Label
var dialog: ConfirmationDialog
var kind_choice: OptionButton
var upper_choice: OptionButton
var lower_choice: OptionButton
var bone_choice: OptionButton
var pole_box: CheckBox
var target_field: LineEdit
var pole_field: LineEdit
var dialog_rows: Dictionary = {}
var _bone_nodes: Array = []
var _updating := false
var _shown_frame := -1


func build_panel(parent: Control) -> void:
	var box := VBoxContainer.new()
	box.name = "IKChains"
	box.add_theme_constant_override("separation", 6)
	parent.add_child(box)
	box.add_child(_note("An IK chain moves bones by a target: drag the orange target and the bones follow. Key the target in a clip to use the chain there."))
	list = ItemList.new()
	list.custom_minimum_size.y = 90
	list.item_selected.connect(func(_index: int): _sync_settings())
	box.add_child(list)
	var buttons := HFlowContainer.new()
	box.add_child(buttons)
	buttons.add_child(_button("Add Chain…", "Choose the kind of chain and its bones", open_add_dialog))
	buttons.add_child(_button("Remove", "Remove the selected chain and its controllers", func(): remove_chain(_selected())))
	buttons.add_child(_button("Bake to Keys", "Write the current clip's chains as ordinary rotation keys, at the frames where their targets are keyed", func():
		var count := bake_to_keys(app.workspace.selected)
		message.text = "Baked %d keys." % count if count > 0 else "No chain is active in this clip: key its target first."))
	box.add_child(HSeparator.new())
	enabled_box = CheckBox.new()
	enabled_box.text = "On"
	enabled_box.tooltip_text = "Turn the chain off to see the bones' own keys"
	enabled_box.toggled.connect(func(value: bool): if not _updating and _selected() >= 0: change(_selected(), "enabled", value))
	box.add_child(enabled_box)
	var strength_row := HBoxContainer.new()
	box.add_child(strength_row)
	weight_label = Label.new()
	weight_label.text = "Strength"
	weight_label.tooltip_text = "How much IK wins over the bones' own keys: 0 is keys only, 1 is IK only"
	strength_row.add_child(weight_label)
	weight = HSlider.new()
	weight.min_value = 0
	weight.max_value = 1
	weight.step = 0.05
	weight.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	weight.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	weight.tooltip_text = weight_label.tooltip_text
	weight.drag_ended.connect(func(value_changed: bool):
		if value_changed and not _updating and _selected() >= 0 and not _has_weight_keys(_selected()):
			change(_selected(), "weight", weight.value))
	strength_row.add_child(weight)
	var key_row := HFlowContainer.new()
	box.add_child(key_row)
	key_row.add_child(_button("Key Strength", "Key the strength on the slider at the playhead in this clip, to blend IK in or out over time", func():
		if _selected() >= 0:
			key_weight(_selected(), weight.value)))
	key_row.add_child(_button("Clear Keys", "Remove this clip's strength keys", func(): clear_weight_keys(_selected())))
	keys_label = _note("")
	box.add_child(keys_label)
	pole_choice = OptionButton.new()
	pole_choice.tooltip_text = "The controller the knee or elbow points at"
	pole_choice.item_selected.connect(func(index: int):
		if not _updating and _selected() >= 0:
			change(_selected(), "pole", pole_choice.get_item_metadata(index)))
	box.add_child(pole_choice)
	message = _note("")
	box.add_child(message)
	_build_dialog()
	changed.connect(refresh_panel)
	app.workspace.editor.changed.connect(func(_index: int, _frame: float): refresh_panel())
	refresh_panel()


func _has_weight_keys(index: int) -> bool:
	var all := rigs()
	if index < 0 or index >= all.size() or not all[index].get("weights") is Dictionary:
		return false
	return all[index].weights.has(_clip_code())


func _note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Palette.muted)
	return label


func _button(text: String, tip: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.pressed.connect(action)
	return button


func _selected() -> int:
	return list.get_selected_items()[0] if list != null and list.is_anything_selected() else -1


func refresh_panel() -> void:
	if list == null:
		return
	var selected := _selected()
	list.clear()
	for rig in rigs():
		var bones := bones_of(rig)
		var label := " › ".join(bones) if not bones.is_empty() else "?"
		var kind := str(rig.get("kind", "ik2"))
		var described: String = KIND_LABELS.get(kind, kind) + (" of %d" % bones.size() if kind == "chain" else "")
		list.add_item("%s  (%s)%s" % [label if kind != "chain" else "%s … %s" % [bones[0], bones[-1]], described, "" if rig.get("enabled", true) != false else " · off"])
	if selected >= 0 and selected < list.item_count:
		list.select(selected)
	elif list.item_count > 0:
		list.select(0)
	_sync_settings()


func _sync_settings() -> void:
	_updating = true
	var index := _selected()
	var all := rigs()
	var rig: Dictionary = all[index] if index >= 0 and index < all.size() else {}
	enabled_box.disabled = rig.is_empty()
	weight.editable = not rig.is_empty()
	pole_choice.disabled = rig.is_empty() or not rig.get("kind", "ik2") in ["ik2", "ik3"]
	enabled_box.button_pressed = rig.get("enabled", true) != false
	var code := _clip_code()
	var keys: Array = rig.get("weights", {}).get(code, []) if rig.get("weights") is Dictionary else []
	weight.value = weight_at(rig, code, app.workspace.frame) if not rig.is_empty() else 1.0
	if rig.is_empty():
		keys_label.text = ""
	elif keys.is_empty():
		keys_label.text = "The slider sets the strength for every frame. Key it to blend IK in or out over time."
	else:
		keys_label.text = "Strength keys in this clip: " + ", ".join(keys.map(func(key): return "frame %d: %d%%" % [key.frame, roundi(key.value * 100)]))
	pole_choice.clear()
	pole_choice.add_item("No pole")
	pole_choice.set_item_metadata(0, "")
	for node in controllers():
		var name_value := str(node.get_meta("shape_element").get("name", ""))
		pole_choice.add_item("Pole: " + name_value)
		pole_choice.set_item_metadata(pole_choice.item_count - 1, name_value)
		if name_value == str(rig.get("pole", "")):
			pole_choice.select(pole_choice.item_count - 1)
	_updating = false


# --- Add Chain dialog ---------------------------------------------------------------------------

func _build_dialog() -> void:
	dialog = ConfirmationDialog.new()
	dialog.title = "Add IK Chain"
	dialog.ok_button_text = "Add Chain"
	var layout := VBoxContainer.new()
	layout.custom_minimum_size.x = 440
	dialog.add_child(layout)
	kind_choice = _dialog_choice(layout, "kind", "Kind")
	for kind in KINDS:
		kind_choice.add_item(KINDS[kind])
		kind_choice.set_item_metadata(kind_choice.item_count - 1, kind)
	kind_choice.item_selected.connect(func(_index: int):
		_default_bones()
		_sync_dialog())
	# Wrapped notes get the dialog's width up front: measured narrow, they
	# would make the window grow tall before its first layout.
	kind_help = _note("")
	kind_help.custom_minimum_size.x = layout.custom_minimum_size.x
	layout.add_child(kind_help)
	upper_choice = _dialog_choice(layout, "upper", "Upper bone")
	middle_choice = _dialog_choice(layout, "middle", "Middle bone")
	lower_choice = _dialog_choice(layout, "lower", "Lower bone")
	bone_choice = _dialog_choice(layout, "bone", "Bone")
	chain_note = _note("")
	chain_note.custom_minimum_size.x = layout.custom_minimum_size.x
	layout.add_child(chain_note)
	target_field = _dialog_field(layout, "target", "Target name")
	pole_box = CheckBox.new()
	pole_box.text = "Add a pole controller to steer the bend"
	pole_box.button_pressed = true
	pole_box.toggled.connect(func(_value: bool): _sync_dialog())
	layout.add_child(pole_box)
	dialog_rows.pole_box = pole_box
	pole_field = _dialog_field(layout, "pole", "Pole name")
	lower_choice.item_selected.connect(func(_index: int):
		_parents_from(_bone_nodes[lower_choice.selected])
		_sync_dialog())
	for choice in [upper_choice, middle_choice, bone_choice]:
		choice.item_selected.connect(func(_index: int): _sync_dialog())
	dialog.confirmed.connect(_confirm_dialog)
	add_child(dialog)


var middle_choice: OptionButton
var kind_help: Label
var chain_note: Label


func _dialog_choice(layout: Control, key: String, title: String) -> OptionButton:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.name = "Title"
	label.text = title
	label.custom_minimum_size.x = 110
	row.add_child(label)
	var choice := OptionButton.new()
	choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	choice.fit_to_longest_item = false
	row.add_child(choice)
	layout.add_child(row)
	dialog_rows[key] = row
	return choice


func _dialog_field(layout: Control, key: String, title: String) -> LineEdit:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 110
	row.add_child(label)
	var field := LineEdit.new()
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	layout.add_child(row)
	dialog_rows[key] = row
	return field


## Opens Add IK Chain. The selected element is taken as the lowest bone (or
## the aimed one), with its parents above it.
func open_add_dialog() -> void:
	_bone_nodes.clear()
	for choice in [upper_choice, middle_choice, lower_choice, bone_choice]:
		choice.clear()
	for node in app.viewport.Geometry.elements(app.viewport.models):
		var source: Dictionary = node.get_meta("shape_element")
		if is_controller(source):
			continue
		_bone_nodes.append(node)
		var depth := 0
		var cursor: Node = node.get_parent()
		while cursor is Node3D and cursor.has_meta("shape_element"):
			depth += 1
			cursor = cursor.get_parent()
		for choice in [upper_choice, middle_choice, lower_choice, bone_choice]:
			choice.add_item("  ".repeat(depth) + str(source.get("name", "")))
	if _bone_nodes.is_empty():
		message.text = "The shape has no elements to make a chain from."
		return
	_default_bones()
	_sync_dialog()
	dialog.theme = app.theme
	# Start from the smallest size so the window fits its content.
	dialog.size = Vector2i.ZERO
	dialog.popup_centered(Vector2i(480, 0))


## Picks bones from the selection for the current kind.
func _default_bones() -> void:
	if _bone_nodes.is_empty():
		return
	var selected: Node3D = app.viewport.selected_node
	var lowest := _bone_nodes.find(selected) if selected in _bone_nodes else _bone_nodes.size() - 1
	bone_choice.select(lowest)
	# A bone without a parent bone is taken as the top: go down to its deepest first child.
	var needed: int = {"ik2": 1, "ik3": 2, "chain": 2}.get(_dialog_kind(), 1)
	var depth := 0
	var cursor: Node3D = _bone_nodes[lowest]
	while cursor.get_parent() in _bone_nodes:
		depth += 1
		cursor = cursor.get_parent()
	while depth < needed:
		var child := _bone_nodes.find_custom(func(node): return node.get_parent() == _bone_nodes[lowest])
		if child < 0:
			break
		lowest = child
		depth += 1
	lower_choice.select(lowest)
	_parents_from(_bone_nodes[lowest])


## Sets the upper (and middle) bones to the parents of `lower`; a chain starts
## up to four bones higher.
func _parents_from(lower: Node3D) -> void:
	var parents: Array = []
	var cursor: Node = lower.get_parent()
	while cursor in _bone_nodes:
		parents.append(cursor)
		cursor = cursor.get_parent()
	var kind := _dialog_kind()
	if kind == "ik3":
		if parents.size() >= 1:
			middle_choice.select(_bone_nodes.find(parents[0]))
		upper_choice.select(_bone_nodes.find(parents[1]) if parents.size() >= 2 else (_bone_nodes.find(parents[0]) if parents.size() >= 1 else 0))
	elif kind == "chain":
		upper_choice.select(_bone_nodes.find(parents[mini(3, parents.size() - 1)]) if not parents.is_empty() else 0)
	else:
		upper_choice.select(_bone_nodes.find(parents[0]) if not parents.is_empty() else 0)


## The bones the dialog describes, from the root down.
func dialog_bones() -> Array:
	match _dialog_kind():
		"aim":
			return [_bone_nodes[bone_choice.selected]]
		"ik3":
			return [_bone_nodes[upper_choice.selected], _bone_nodes[middle_choice.selected], _bone_nodes[lower_choice.selected]]
		"chain":
			var first: Node3D = _bone_nodes[upper_choice.selected]
			var path: Array = []
			var cursor: Node = _bone_nodes[lower_choice.selected]
			while cursor != null and cursor in _bone_nodes:
				path.push_front(cursor)
				if cursor == first:
					return path
				cursor = cursor.get_parent()
			return []
	return [_bone_nodes[upper_choice.selected], _bone_nodes[lower_choice.selected]]


func _suggest_names() -> void:
	var aim := _dialog_kind() == "aim"
	var choice: OptionButton = bone_choice if aim else lower_choice
	if choice.selected < 0 or choice.selected >= _bone_nodes.size():
		return
	var name_value := str(_bone_nodes[choice.selected].get_meta("shape_element").get("name", ""))
	target_field.text = name_value + (" Aim" if aim else " IK")
	pole_field.text = name_value + " Pole"


func _dialog_kind() -> String:
	return str(kind_choice.get_item_metadata(maxi(kind_choice.selected, 0)))


func _sync_dialog() -> void:
	var kind := _dialog_kind()
	var aim := kind == "aim"
	kind_help.text = KIND_HELP.get(kind, "")
	dialog_rows.upper.visible = not aim
	dialog_rows.middle.visible = kind == "ik3"
	dialog_rows.lower.visible = not aim
	dialog_rows.bone.visible = aim
	dialog_rows.upper.get_node("Title").text = "First bone" if kind == "chain" else "Upper bone"
	dialog_rows.lower.get_node("Title").text = "Last bone" if kind == "chain" else "Lower bone"
	var posed := kind in ["ik2", "ik3"]
	dialog_rows.pole_box.visible = posed
	dialog_rows.pole.visible = posed and pole_box.button_pressed
	chain_note.visible = kind == "chain"
	if kind == "chain":
		var bones := dialog_bones()
		chain_note.text = ("%d bones: %s" % [bones.size(), " › ".join(bones.map(func(node): return node.get_meta("shape_element").get("name", "")))]) if bones.size() >= 2 \
			else "The last bone must be inside the first one."
	_suggest_names()


func _confirm_dialog() -> void:
	var kind := _dialog_kind()
	var error := create_chain({"kind": kind, "bones": dialog_bones(), "pole": pole_box.button_pressed and kind in ["ik2", "ik3"],
		"target_name": target_field.text, "pole_name": pole_field.text})
	message.text = error if not error.is_empty() else "Key the target (orange) in a clip to use the chain there."
	if error.is_empty():
		list.select(list.item_count - 1)
		_sync_settings()
