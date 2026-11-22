extends Node
## The Poses tab (Animation mode): a library of
## named poses to save and apply (or blend in), Copy and Paste Pose between
## frames, Mirror Pose, Reset Pose, and a breakdown slider that places the
## current frame between the neighbouring keys.
##
## Every tool works on the selected elements, or on every element when none is
## selected, and keys them at the playhead as one undo step. Poses are kept in
## `shapesmith.poses` as {name, elements: {element: {offset, rotation,
## stretch}}} (offset in shape units, rotation in degrees).

const AnimationEditor = preload("res://ui/animation/animation_editor.gd")
const Document = preload("res://core/document/shape_document.gd")
const SetDataEntries = preload("res://core/commands/set_data_entries.gd")
const GROUPS := ["offset", "rotation", "stretch"]
## VSMC2 warns past this many animated elements (MaxAnimatedElements).
const MAX_ANIMATED_ELEMENTS := 230
const WARN_ANIMATED_ELEMENTS := 200
static var Palette = preload("res://ui/theme/editor_palette.tres")

signal changed

var app
## Copy Pose: {element: {group: Vector3}}.
var clipboard: Dictionary = {}


func bind(target_app) -> void:
	app = target_app


# --- Data ------------------------------------------------------------------------------

func poses() -> Array:
	var marker: Variant = app.viewport.shape_data.get("shapesmith")
	var value: Variant = marker.get("poses", []) if marker is Dictionary else []
	return value.filter(func(pose): return pose is Dictionary).map(func(pose): return pose.duplicate(true)) if value is Array else []


func _set_poses(value: Array, label: String) -> bool:
	return app.history.execute(SetDataEntries.new(app.viewport.shape_data, "shapesmith",
		{"poses": value if not value.is_empty() else Document.ABSENT}, label, func(): changed.emit()))


## The elements the tools act on: the selection, or every element (by name;
## names shared by several elements are left out, as keys cannot tell them apart).
func targets() -> Array:
	var nodes: Array = app._selected_nodes()
	if nodes.is_empty() and is_instance_valid(app.viewport.selected_node):
		nodes = [app.viewport.selected_node]
	if nodes.is_empty():
		nodes = app.viewport.Geometry.elements(app.viewport.models)
	var names: Array = []
	for node in nodes:
		var name_value := str(node.get_meta("shape_element").get("name", ""))
		if not name_value.is_empty() and not name_value in names and app.workspace.animation.elements.get(name_value, []).size() == 1:
			names.append(name_value)
	return names


func _ready_clip() -> bool:
	var workspace = app.workspace
	return workspace.selected >= 0 and workspace.selected < workspace.animation.clips.size() and workspace.animation.clips[workspace.selected].error.is_empty()


## Each element's values at `time`: what the preview shows (including an
## unkeyed edit held with Auto Key off).
func capture(names: Array, time: int) -> Dictionary:
	var result := {}
	if not _ready_clip():
		return result
	for name_value in names:
		result[name_value] = app.workspace._held_values(name_value, time)
	return result


## The parts the last _key() keyed, and why it keyed nothing ("" when it did).
var _keyed: Array = []
var _why_not := ""
## Values closer than this count as unchanged.
const SAME := 0.0005


## Keys the values at the playhead, leaving out every part (and every
## position, rotation or scale) already at that value there: the game allows
## few animated elements, so a tool must not key parts it does not move.
func _key(values: Dictionary, label: String) -> bool:
	_keyed = []
	_why_not = "Pick an animation first."
	if values.is_empty() or not _ready_clip():
		return false
	var time := roundi(app.workspace.frame)
	var current := capture(values.keys(), time)
	var changed := {}
	for element in values:
		var groups := {}
		for group in values[element]:
			var now: Variant = current.get(element, {}).get(group)
			var goal: Vector3 = values[element][group]
			if not now is Vector3:
				groups[group] = goal
				continue
			var difference: Vector3 = (goal - now).abs()
			if maxf(difference.x, maxf(difference.y, difference.z)) > SAME:
				groups[group] = goal
		if not groups.is_empty():
			changed[element] = groups
	if changed.is_empty():
		_why_not = "Nothing to key: %s already %s this pose at %s." % [_parts(values.keys()), "has" if values.size() == 1 else "have", _frame_text()]
		return false
	_keyed = changed.keys()
	_why_not = ""
	return app.workspace.editor.key_values(app.workspace.selected, time, changed, label)


## Says what a tool did (or why it did nothing) where the user is looking.
func _report(done: bool, success: String, failure: String) -> bool:
	if app == null:
		return done
	var text := success if done else failure
	if not text.is_empty():
		app.notify(text, "info" if done else "warning")
	return done


func _parts(names: Array) -> String:
	if names.size() == 1:
		return names[0]
	return "%d parts" % names.size()


func _frame_text() -> String:
	return "frame %d" % roundi(app.workspace.frame)


# --- Library -----------------------------------------------------------------------------

func save_pose(name_value: String) -> bool:
	var names := targets()
	var values := capture(names, roundi(app.workspace.frame))
	if values.is_empty():
		return _report(false, "", "Pick an animation first: a pose is taken from the clip at the playhead.")
	var stored := {}
	for element in values:
		stored[element] = {}
		for group in GROUPS:
			var vector: Vector3 = values[element][group]
			stored[element][group] = [vector.x, vector.y, vector.z]
	var list := poses()
	var label := name_value.strip_edges() if not name_value.strip_edges().is_empty() else "Pose %d" % (list.size() + 1)
	list.append({"name": label, "elements": stored})
	var hint := " Only one part was selected: select more, or none for the whole model." if values.size() == 1 else ""
	return _report(_set_poses(list, "Save Pose"), "Saved “%s”: the pose of %s at %s.%s" % [label, _parts(values.keys()), _frame_text(), hint], "")


func delete_pose(index: int) -> bool:
	var list := poses()
	if index < 0 or index >= list.size():
		return false
	list.remove_at(index)
	return _set_poses(list, "Delete Pose")


## Keys a saved pose at the playhead, `blend` of the way from the current pose
## (1 applies it fully). Only elements in the pose that exist here are keyed;
## with a selection, only selected ones.
func apply_pose(index: int, blend := 1.0) -> bool:
	var list := poses()
	if index < 0 or index >= list.size() or not list[index].get("elements") is Dictionary:
		return false
	if not _ready_clip():
		return _report(false, "", "Pick an animation first.")
	var allowed := targets()
	var stored: Dictionary = list[index].elements
	var current := capture(stored.keys().filter(func(name_value): return name_value in allowed), roundi(app.workspace.frame))
	if current.is_empty():
		return _report(false, "", "“%s” holds %s, and none of them is among the selected parts. Select them, or click empty space to act on the whole model." % [list[index].name, _parts(stored.keys())])
	var values := {}
	for element in current:
		values[element] = {}
		for group in GROUPS:
			var raw: Variant = stored[element].get(group)
			if not raw is Array or raw.size() != 3:
				continue
			var goal := Vector3(raw[0], raw[1], raw[2])
			var now: Vector3 = current[element][group]
			if group == "rotation":
				goal = _near(goal, now)
			values[element][group] = now.lerp(goal, clampf(blend, 0.0, 1.0))
	return _report(_key(values, "Apply Pose"), "Keyed “%s” on %s at %s%s." % [list[index].name, _parts(_keyed), _frame_text(), " (%d%%)" % roundi(blend * 100) if blend < 1.0 else ""],
		_why_not)


## The same angles, each moved by whole turns to be nearest `reference`.
static func _near(angles: Vector3, reference: Vector3) -> Vector3:
	var result := angles
	for axis in range(3):
		result[axis] = reference[axis] + wrapf(angles[axis] - reference[axis], -180.0, 180.0)
	return result


# --- Pose edits ----------------------------------------------------------------------------

func copy_pose() -> bool:
	clipboard = capture(targets(), roundi(app.workspace.frame))
	clipboard_frame = roundi(app.workspace.frame)
	_sync_labels()
	return _report(not clipboard.is_empty(), "Copied the pose of %s at %s. Move the playhead and Paste to key it there." % [_parts(clipboard.keys()), _frame_text()], "Pick an animation first.")


func paste_pose() -> bool:
	var values := {}
	for element in clipboard:
		if app.workspace.animation.elements.get(element, []).size() == 1:
			values[element] = clipboard[element].duplicate()
	if clipboard.is_empty():
		return _report(false, "", "Copy a pose first.")
	return _report(_key(values, "Paste Pose"), "Pasted the pose of %s at %s." % [_parts(_keyed), _frame_text()], _why_not)


## Swaps each element's pose with its mirror element's (Left and Right, L and
## R), mirrored across X; elements without a side are mirrored in place.
func mirror_pose() -> bool:
	var names := targets()
	var involved: Array = names.duplicate()
	for name_value in names:
		var other := AnimationEditor.mirror_name(name_value)
		if other != name_value and app.workspace.animation.elements.get(other, []).size() == 1 and not other in involved:
			involved.append(other)
	var current := capture(involved, roundi(app.workspace.frame))
	var values := {}
	for name_value in involved:
		var other := AnimationEditor.mirror_name(name_value)
		var source: Dictionary = current.get(other if current.has(other) else name_value, {})
		if source.is_empty():
			continue
		values[name_value] = {
			"offset": Vector3(-source.offset.x, source.offset.y, source.offset.z),
			"rotation": Vector3(source.rotation.x, -source.rotation.y, -source.rotation.z),
			"stretch": source.stretch}
	return _report(_key(values, "Mirror Pose"), "Mirrored %s at %s." % [_parts(_keyed), _frame_text()], _why_not)


## Keys the rest pose: no offset, no rotation, no stretch.
func reset_pose() -> bool:
	var values := {}
	for name_value in targets():
		values[name_value] = {"offset": Vector3.ZERO, "rotation": Vector3.ZERO, "stretch": Vector3.ONE}
	return _report(_key(values, "Reset Pose"), "Keyed %s in the rest pose at %s." % [_parts(_keyed), _frame_text()], _why_not)


## Breakdown: keys each element `amount` of the way from its previous key to
## its next one (0 = the previous key's pose, 1 = the next one's). Elements
## without keys on both sides are left alone.
func breakdown(amount: float) -> bool:
	if not _ready_clip():
		return false
	var time := roundi(app.workspace.frame)
	var clip: Dictionary = app.workspace.editor.clips()[app.workspace.selected]
	var values := {}
	for name_value in targets():
		var before := -1
		var after := -1
		for key in clip.get("keyframes", []):
			if not key is Dictionary or not key.get("elements", {}).has(name_value):
				continue
			var frame := int(key.frame)
			if frame < time and frame > before:
				before = frame
			if frame > time and (after < 0 or frame < after):
				after = frame
		if before < 0 or after < 0:
			continue
		var left: Dictionary = capture([name_value], before)[name_value]
		var right: Dictionary = capture([name_value], after)[name_value]
		values[name_value] = {}
		for group in GROUPS:
			values[name_value][group] = (left[group] as Vector3).lerp(right[group], clampf(amount, 0.0, 1.0))
	if values.is_empty():
		return _report(false, "", "An in-between needs keys before and after the playhead: %s %s none on one side of %s." % [_parts(targets()), "has" if targets().size() == 1 else "have", _frame_text()])
	return _report(_key(values, "Breakdown"), "Keyed an in-between for %s at %s." % [_parts(_keyed), _frame_text()], _why_not)


## How many elements the current clip animates.
func animated_count() -> int:
	if not _ready_clip():
		return 0
	return app.workspace.animation.clips[app.workspace.selected].tracks.size()


# --- Panel (the Poses tab) ------------------------------------------------------------------

var list: ItemList
var name_field: LineEdit
var blend: HSlider
var blend_label: Label
var breakdown_slider: HSlider
var breakdown_label: Label
var targets_label: Label
var clipboard_label: Label
var clipboard_frame := 0
var message: Label
var _shown_clip := ""
var _shown_targets := ""


func build_panel(parent: Control) -> void:
	var box := VBoxContainer.new()
	box.name = "Poses"
	box.add_theme_constant_override("separation", 6)
	parent.add_child(box)
	box.add_child(_note("Every tool here keys a pose at the playhead, in one undo step."))
	targets_label = Label.new()
	targets_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(targets_label)

	_heading(box, "Pose library", "Saved poses stay in the file. Apply keys a saved pose at the playhead, in this clip or any other.")
	var save_row := HBoxContainer.new()
	box.add_child(save_row)
	name_field = LineEdit.new()
	name_field.placeholder_text = "Name, such as Crouch"
	name_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_field.text_submitted.connect(func(_text: String): _save())
	save_row.add_child(name_field)
	save_row.add_child(_button("Save Pose", "Save the pose of the parts above, as they are at the playhead", _save))
	list = ItemList.new()
	list.custom_minimum_size.y = 80
	list.item_activated.connect(func(index: int): apply_pose(index, blend.value))
	list.item_selected.connect(func(_index: int): _sync_buttons())
	box.add_child(list)
	var amount_row := HBoxContainer.new()
	box.add_child(amount_row)
	blend_label = Label.new()
	blend_label.custom_minimum_size.x = 110
	amount_row.add_child(blend_label)
	blend = HSlider.new()
	blend.min_value = 0
	blend.max_value = 1
	blend.step = 0.05
	blend.value = 1.0
	blend.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blend.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	blend.tooltip_text = "How far towards the saved pose: 100% applies it fully"
	blend.value_changed.connect(func(_value: float): _sync_labels())
	amount_row.add_child(blend)
	var library_row := HFlowContainer.new()
	box.add_child(library_row)
	library_row.add_child(_button("Apply Pose", "Key the selected saved pose at the playhead (double-clicking it does the same)", func():
		if list.is_anything_selected():
			apply_pose(list.get_selected_items()[0], blend.value)))
	library_row.add_child(_button("Delete Pose", "Remove the selected saved pose from the library", func():
		if list.is_anything_selected():
			delete_pose(list.get_selected_items()[0])))

	_heading(box, "Copy and paste", "A quick copy that is not saved: Copy takes the pose at this frame, Paste keys it at another frame. To keep a pose for later, save it to the library instead.")
	var copy_row := HFlowContainer.new()
	box.add_child(copy_row)
	copy_row.add_child(_button("Copy Pose", "Remember the pose of the parts above at the playhead", func():
		copy_pose()))
	copy_row.add_child(_button("Paste Pose", "Key the copied pose at the playhead", paste_pose))
	clipboard_label = _note("")
	box.add_child(clipboard_label)

	_heading(box, "Quick poses", "")
	var quick := HFlowContainer.new()
	box.add_child(quick)
	quick.add_child(_button("Mirror Left ↔ Right", "Swap the poses of left and right parts (ArmL and ArmR, LeftLeg and RightLeg), mirrored. Parts without a side are mirrored in place.", mirror_pose))
	quick.add_child(_button("Reset to Rest", "Key the parts above in their rest pose: no offset, rotation or stretch", reset_pose))

	_heading(box, "In-between", "Key a pose part of the way from each part's previous key to its next one.")
	var between := HBoxContainer.new()
	box.add_child(between)
	var left := Label.new()
	left.text = "Previous"
	between.add_child(left)
	breakdown_slider = HSlider.new()
	breakdown_slider.min_value = 0
	breakdown_slider.max_value = 1
	breakdown_slider.step = 0.05
	breakdown_slider.value = 0.5
	breakdown_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	breakdown_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	breakdown_slider.value_changed.connect(func(_value: float): _sync_labels())
	between.add_child(breakdown_slider)
	var right := Label.new()
	right.text = "Next"
	between.add_child(right)
	var between_row := HBoxContainer.new()
	box.add_child(between_row)
	breakdown_label = Label.new()
	breakdown_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	between_row.add_child(breakdown_label)
	between_row.add_child(_button("Key In-between", "Key the pose this far between the previous and next keys", func():
		breakdown(breakdown_slider.value)))

	message = _note("")
	box.add_child(message)
	changed.connect(refresh_panel)
	app.workspace.editor.changed.connect(func(_index: int, _frame: float): refresh_panel())
	refresh_panel()


func _heading(box: Control, title: String, text: String) -> void:
	box.add_child(HSeparator.new())
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 13)
	box.add_child(label)
	if not text.is_empty():
		box.add_child(_note(text))


func _note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Palette.muted)
	return label


## Refreshes when another clip or selection is shown, however that happened.
func _process(_delta: float) -> void:
	if list == null or app == null:
		return
	var workspace = app.workspace
	var key := "%d:%d" % [workspace.selected, workspace.animation.clips.size()]
	if key != _shown_clip:
		_shown_clip = key
		refresh_panel()
	var names := ", ".join(targets()) if app.viewport.models.get_child_count() > 0 else ""
	if names != _shown_targets:
		_shown_targets = names
		_sync_labels()


func _button(text: String, tip: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.pressed.connect(action)
	return button


func _save() -> void:
	if save_pose(name_field.text):
		name_field.text = ""


func _sync_buttons() -> void:
	_sync_labels()


func _sync_labels() -> void:
	if targets_label == null:
		return
	var selected: bool = not app._selected_nodes().is_empty() or is_instance_valid(app.viewport.selected_node)
	var names := targets()
	targets_label.text = ("Acts on: " + (", ".join(names.slice(0, 6)) + (" and %d more" % (names.size() - 6) if names.size() > 6 else ""))) if selected and not names.is_empty() \
		else "Acts on: the whole model (select parts to limit it)"
	blend_label.text = "Amount %d%%" % roundi(blend.value * 100)
	clipboard_label.text = "Copied: nothing yet" if clipboard.is_empty() else "Copied: %s, from frame %d" % [_parts(clipboard.keys()), clipboard_frame]
	breakdown_label.text = "%d%% of the way to the next key" % roundi(breakdown_slider.value * 100)


func refresh_panel() -> void:
	if list == null:
		return
	var selected := list.get_selected_items()[0] if list.is_anything_selected() else -1
	list.clear()
	for pose in poses():
		var size: int = pose.get("elements", {}).size()
		list.add_item("%s  (%d %s)" % [pose.get("name", "Pose"), size, "part" if size == 1 else "parts"])
	if selected >= 0 and selected < list.item_count:
		list.select(selected)
	_sync_labels()
	var count := animated_count()
	if count > WARN_ANIMATED_ELEMENTS:
		message.text = "This clip animates %d elements; the game handles up to %d." % [count, MAX_ANIMATED_ELEMENTS]
		message.add_theme_color_override("font_color", Color("e5a443") if count <= MAX_ANIMATED_ELEMENTS else Color("e5484d"))
	elif message.text.begins_with("This clip animates"):
		message.text = ""
		message.add_theme_color_override("font_color", Palette.muted)
