extends Node

# Smaller determinants make inverse transforms unstable.
const MIN_TRANSFORM_DETERMINANT := 0.000001

const Units = preload("res://core/model/shape_units.gd")
const Geometry = preload("res://core/model/shape_geometry.gd")
const Document = preload("res://core/document/shape_document.gd")
const AddElements = preload("res://core/commands/add_elements.gd")
const DeleteElements = preload("res://core/commands/delete_elements.gd")
const SetFields = preload("res://core/commands/set_element_fields.gd")
const RenameTrack = preload("res://core/commands/rename_track.gd")
const RemoveTracks = preload("res://core/commands/remove_tracks.gd")
const AddPoses = preload("res://core/commands/add_poses.gd")
const Composite = preload("res://core/commands/composite_command.gd")
var viewport_view
var document
var scene_sync
var selection
var hierarchy_browser
var structure_editor
var edit_history
var transform_controller
var animation_workspace
var editor_theme: Theme
var editor_mode := "View"

var menu: PopupMenu
var rename_dialog: ConfirmationDialog
var rename_input: LineEdit
var rename_error: Label
var mirror_dialog: ConfirmationDialog
var mirror_axis: OptionButton
var mirror_plane: SpinBox
var mirror_error: Label
var target: Node3D
var clipboard: Dictionary = {}
## Context menu item ids. 0-4 keep their original ids.
enum Item { DELETE, RENAME, COPY, PASTE, MIRROR, ADD_CHILD, ADD_SIBLING, DUPLICATE, DELETE_KEEP_CHILDREN,
	GROUP, UNGROUP, REPARENT_TO, UNPARENT, HIDE_OTHERS, SHOW_ALL, LOCK, COPY_PATH }
var reparent_picker: PopupPanel
var picker_filter: LineEdit
var picker_list: ItemList
## Set by main: the outliner selection, so group actions use every selected element.
var selection_nodes: Callable
## A notice for the user, such as a rejected rename. kind is "info" or "error".
signal message(text: String, kind: String)


func bind(view: Node, browser: Control, structure: Node, history: Node, transforms: Node, playback: Control, theme_resource: Theme) -> void:
	viewport_view = view
	hierarchy_browser = browser
	structure_editor = structure
	edit_history = history
	transform_controller = transforms
	animation_workspace = playback
	editor_theme = theme_resource


## Called whenever a document opens or a new one starts.
func bind_document(target_document, sync, current_selection = null) -> void:
	document = target_document
	scene_sync = sync
	selection = current_selection


func set_editor_theme(theme_resource: Theme) -> void:
	editor_theme = theme_resource
	for window in [menu, rename_dialog, mirror_dialog]:
		if is_instance_valid(window):
			window.theme = theme_resource


func _ready() -> void:
	menu = $Menu
	rename_dialog = $Rename
	rename_input = $Rename/Layout/Name
	rename_error = $Rename/Layout/Error
	mirror_dialog = $Mirror
	mirror_axis = $Mirror/Layout/Axis
	mirror_plane = $Mirror/Layout/Plane
	mirror_error = $Mirror/Layout/Error
	set_editor_theme(editor_theme)
	_build_menu()
	menu.id_pressed.connect(_command)
	_build_reparent_picker()
	rename_dialog.confirmed.connect(_confirm_rename)
	rename_input.text_submitted.connect(func(_text: String): _confirm_rename())
	mirror_dialog.confirmed.connect(func():
		mirror_plane.apply()
		if mirror_shapes(_selected_or(target), mirror_axis.selected, mirror_plane.value):
			mirror_dialog.hide()
		else:
			mirror_error.text = "Cannot mirror a shape with zero scale.")
	hierarchy_browser.context_requested.connect(open_context)
	hierarchy_browser.rename_requested.connect(open_rename)
	hierarchy_browser.rename_submitted.connect(_on_rename_submitted)
	hierarchy_browser.delete_requested.connect(func(element: Node3D):
		if editor_mode == "Model":
			delete_shape(element))


func _build_menu() -> void:
	var icons = preload("res://ui/shared/editor_icons.gd")
	menu.clear()
	for entry in [[Item.ADD_CHILD, "Add Child", 0, "add"], [Item.ADD_SIBLING, "Add Sibling", 0, ""], null,
			[Item.DUPLICATE, "Duplicate", KEY_MASK_CTRL | KEY_D, "content_copy"], [Item.COPY, "Copy", KEY_MASK_CTRL | KEY_C, ""],
			[Item.PASTE, "Paste", KEY_MASK_CTRL | KEY_V, "content_paste"], null,
			[Item.RENAME, "Rename", KEY_F2, "edit"], [Item.GROUP, "Group Selection", KEY_MASK_CTRL | KEY_G, "create_new_folder"],
			[Item.UNGROUP, "Ungroup", KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_G, ""], [Item.REPARENT_TO, "Reparent To…", 0, "open_with"],
			[Item.UNPARENT, "Unparent", 0, ""], [Item.MIRROR, "Mirror…", 0, "flip"], null,
			[Item.HIDE_OTHERS, "Hide Others", 0, "visibility_off"], [Item.SHOW_ALL, "Show All", 0, "visibility"],
			[Item.LOCK, "Lock", 0, ""], [Item.COPY_PATH, "Copy Path", 0, ""], null,
			[Item.DELETE, "Delete", KEY_DELETE, "delete"], [Item.DELETE_KEEP_CHILDREN, "Delete, Keep Children", 0, ""]]:
		if entry == null:
			menu.add_separator()
			continue
		menu.add_item(entry[1], entry[0], entry[2])
		if not entry[3].is_empty():
			menu.set_item_icon(menu.get_item_index(entry[0]), icons.icon(entry[3]))


func open_context(element: Node3D, position_value: Vector2) -> void:
	if editor_mode != "Model":
		return

	target = element
	var has_children: bool = document.has(Document.uid_of(element)) and not document.children_of(Document.uid_of(element)).is_empty()
	menu.set_item_disabled(menu.get_item_index(Item.PASTE), clipboard.is_empty())
	menu.set_item_disabled(menu.get_item_index(Item.UNGROUP), not has_children)
	menu.set_item_disabled(menu.get_item_index(Item.DELETE_KEEP_CHILDREN), not has_children)
	menu.set_item_disabled(menu.get_item_index(Item.UNPARENT), element.get_parent() == structure_editor.root_node())
	menu.set_item_text(menu.get_item_index(Item.LOCK), "Unlock" if hierarchy_browser.is_locked(element) else "Lock")
	menu.set_item_disabled(menu.get_item_index(Item.COPY_PATH), DisplayServer.get_name() == "headless")
	menu.position = Vector2i(position_value)
	menu.popup()


func _command(id: int) -> void:
	if editor_mode != "Model" or not is_instance_valid(target):
		return

	match id:
		Item.DELETE: delete_shape(target)
		Item.RENAME: open_rename(target)
		Item.COPY: copy_shape(target)
		Item.PASTE: paste_shape(target)
		Item.MIRROR: open_mirror(target)
		Item.ADD_CHILD: structure_editor.add_relative(target, true)
		Item.ADD_SIBLING: structure_editor.add_relative(target, false)
		Item.DUPLICATE: duplicate_shapes(target)
		Item.DELETE_KEEP_CHILDREN: structure_editor.lift_children(target, "Delete, Keep Children")
		Item.GROUP: structure_editor.group_elements(target)
		Item.UNGROUP: structure_editor.lift_children(target, "Ungroup")
		Item.REPARENT_TO: open_reparent_picker(target)
		Item.UNPARENT: structure_editor.reparent_shape(target, null)
		Item.HIDE_OTHERS: hierarchy_browser.hide_others(_selected_or(target))
		Item.SHOW_ALL: hierarchy_browser.show_all()
		Item.LOCK: hierarchy_browser.toggle_lock(target)
		Item.COPY_PATH: DisplayServer.clipboard_set(document.path_of(Document.uid_of(target)))


## Every selected element when `element` is one of them, else just `element`.
func _selected_or(element: Node3D) -> Array:
	var nodes: Array = selection_nodes.call() if selection_nodes.is_valid() else []
	return nodes if nodes.size() > 1 and nodes.has(element) else [element]


# --- Reparent To… -----------------------------------------------------------------

func _build_reparent_picker() -> void:
	reparent_picker = PopupPanel.new()
	reparent_picker.name = "ReparentPicker"
	var layout := VBoxContainer.new()
	reparent_picker.add_child(layout)
	picker_filter = LineEdit.new()
	picker_filter.placeholder_text = "Move under…"
	picker_filter.text_changed.connect(func(_text: String): _fill_picker())
	picker_filter.text_submitted.connect(func(_text: String): _pick_parent(0 if picker_list.item_count > 0 else -1))
	layout.add_child(picker_filter)
	picker_list = ItemList.new()
	picker_list.custom_minimum_size = Vector2(320, 260)
	picker_list.item_activated.connect(_pick_parent)
	layout.add_child(picker_list)
	add_child(reparent_picker)


## A searchable list of every element the selection can move under.
func open_reparent_picker(element: Node3D) -> void:
	target = element
	picker_filter.text = ""
	_fill_picker()
	reparent_picker.theme = editor_theme
	reparent_picker.popup_centered()
	picker_filter.grab_focus()


func _fill_picker() -> void:
	picker_list.clear()
	var moving: Array = _selected_or(target)
	var words := picker_filter.text.strip_edges().to_lower()
	if words.is_empty() or "(root)".contains(words):
		picker_list.add_item("(root)")
		picker_list.set_item_metadata(0, "")
	for uid in document.ordered():
		var node: Node3D = scene_sync.node_for(uid)
		if node == null or moving.any(func(other): return other == node or other.is_ancestor_of(node)):
			continue
		var path: String = document.path_of(uid)
		if words.is_empty() or path.to_lower().contains(words):
			var index := picker_list.add_item(path)
			picker_list.set_item_metadata(index, uid)


func _pick_parent(index: int) -> void:
	if index < 0 or index >= picker_list.item_count:
		return
	var uid: String = picker_list.get_item_metadata(index)
	reparent_picker.hide()
	structure_editor.reparent_shape(target, scene_sync.node_for(uid) if not uid.is_empty() else null)


func open_rename(element: Node3D) -> void:
	if not editor_mode in ["Model", "Texture"] or not is_instance_valid(element):
		return

	edit_history.flush_pending.emit()
	target = element
	hierarchy_browser.begin_rename(element)


func _on_rename_submitted(element: Node3D, value: String) -> void:
	if not is_instance_valid(element) or value == str(element.get_meta("shape_element").get("name", "")):
		return
	if not rename_shape(element, value):
		message.emit("“%s” cannot be used: names must be non-empty and unique." % value, "error")


func _confirm_rename() -> void:
	if rename_shape(target, rename_input.text):
		rename_dialog.hide()
	else:
		rename_error.text = "Choose a non-empty name that no other shape uses."


func _names(element: Node3D) -> Array:
	var result: Array = []
	for node in Geometry.elements(element):
		result.append(str(node.get_meta("shape_element").get("name", "")))
	return result


func _name_taken(value: String, except_uid := "") -> bool:
	for uid in document.ordered():
		if uid != except_uid and document.element(uid).name().to_lower() == value.to_lower():
			return true
	return false


## Renames an element, its animation tracks and step-parent references to it,
## as one undo step.
func rename_shape(element: Node3D, value: String) -> bool:
	var uid := Document.uid_of(element)
	if not is_instance_valid(element) or not document.has(uid):
		return false

	value = value.strip_edges()
	if value.is_empty() or _name_taken(value, uid):
		return false

	edit_history.flush_pending.emit()
	var old: String = document.element(uid).name()
	if old == value:
		return true

	var steps: Array = [SetFields.new(document, uid, {"name": value})]
	for other in document.ordered():
		if document.source(other).get("stepParentName") == old:
			steps.append(SetFields.new(document, other, {"stepParentName": value}))
	steps.append(RenameTrack.new(document, old, value))
	if not edit_history.execute(Composite.new(document, steps, "Rename Shape")):
		return false
	structure_editor.element_selection_requested.emit(element)
	return true


## Deletes an element's branch and its animation tracks as one undo step.
## When the element is part of a multi-selection, deletes every selected one.
func delete_shape(element: Node3D) -> bool:
	var uid := Document.uid_of(element)
	if not is_instance_valid(element) or not document.has(uid):
		return false

	var uids: Array = [uid]
	if selection != null and selection.items.size() > 1 and selection.has(uid):
		uids = selection.items.filter(func(item: String): return document.has(item))
	var names: Array = []
	for item in uids:
		var node: Node3D = scene_sync.node_for(item)
		if node != null:
			names.append_array(_names(node))
	edit_history.flush_pending.emit()
	return edit_history.execute(Composite.new(document, [
		RemoveTracks.new(document, names),
		DeleteElements.new(document, uids),
	], "Delete Shapes" if uids.size() > 1 else "Delete Shape"))


func copy_shape(element: Node3D) -> void:
	edit_history.flush_pending.emit()
	clipboard = _clip(element)


## An element's subtree and its animation poses, keyed by clip code.
func _clip(element: Node3D) -> Dictionary:
	var result := {"shape": element.get_meta("shape_element").duplicate(true), "tracks": []}
	var names := _names(element)
	for clip in Document.animations(viewport_view.shape_data):
		if not clip is Dictionary:
			continue

		var track := {"code": animation_workspace.editor.effective_code(clip), "frames": []}
		for frame in Document.clip_keyframes(clip):
			if not frame is Dictionary or not frame.get("elements") is Dictionary:
				continue

			var poses: Dictionary = {}
			for name in names:
				if frame.elements.has(name):
					poses[name] = frame.elements[name].duplicate(true)
			if not poses.is_empty():
				track.frames.append({"frame": frame.frame, "poses": poses})
		result.tracks.append(track)
	return result


## Pastes the copied branch (renamed "… Copy") under parent, or at the root,
## with its animation tracks, as one undo step.
func paste_shape(parent: Node3D) -> bool:
	if clipboard.is_empty():
		return false

	edit_history.flush_pending.emit()
	var parent_uid := Document.uid_of(parent)
	if not document.has(parent_uid):
		parent_uid = Document.ROOT
	var used: Array = document.ordered().map(func(uid: String): return document.element(uid).name().to_lower())
	var part := _paste_part(clipboard, parent_uid, used)
	var add = AddElements.new(document, [part.entry])
	if not edit_history.execute(Composite.new(document, [add, AddPoses.new(document, part.poses)], "Paste Shape")):
		return false
	structure_editor.element_selection_requested.emit(scene_sync.node_for(add.added()[0]))
	return true


## Ctrl+D: copies the element (or every selected element) next to itself,
## with animation tracks, as one undo step. The clipboard is left alone.
func duplicate_shapes(element: Node3D) -> bool:
	edit_history.flush_pending.emit()
	var nodes: Array = structure_editor._moving_set(element)
	var used: Array = document.ordered().map(func(uid: String): return document.element(uid).name().to_lower())
	var entries: Array = []
	var poses: Array = []
	for node in nodes:
		var parent_uid: String = document.parent_of(Document.uid_of(node))
		var part := _paste_part(_clip(node), parent_uid, used)
		entries.append(part.entry)
		poses.append_array(part.poses)
	var add = AddElements.new(document, entries)
	if not edit_history.execute(Composite.new(document, [add, AddPoses.new(document, poses)], "Duplicate Shapes" if nodes.size() > 1 else "Duplicate Shape")):
		return false
	structure_editor.element_selection_requested.emit(scene_sync.node_for(add.added()[0]))
	return true


## The AddElements entry and AddPoses entries that paste one copied branch.
func _paste_part(clip_data: Dictionary, parent_uid: String, used: Array) -> Dictionary:
	var copy: Dictionary = clip_data.shape.duplicate(true)
	var mapping: Dictionary = {}
	_unique_names(copy, used, mapping)
	_remap_parents(copy, mapping)
	var poses: Array = []
	var animations: Array = Document.animations(viewport_view.shape_data)
	for clip_index in range(animations.size()):
		var clip: Variant = animations[clip_index]
		if not clip is Dictionary or not clip.get("keyframes") is Array:
			continue

		for track in clip_data.tracks:
			if track.code != animation_workspace.editor.effective_code(clip):
				continue

			for frame in track.frames:
				if frame.frame >= clip.get("quantityframes", clip.get("quantityFrames", 1)):
					continue

				for name in frame.poses:
					poses.append({"clip": clip_index, "frame": frame.frame, "element": mapping[name], "pose": frame.poses[name]})
	return {"entry": {"parent": parent_uid, "source": copy}, "poses": poses}


func _unique_names(source: Dictionary, used: Array, mapping: Dictionary) -> void:
	var old: String = source.get("name", "Element")
	var base := old + " Copy"
	var name_value := base
	var suffix := 2
	while name_value.to_lower() in used:
		name_value = base + " " + str(suffix)
		suffix += 1
	used.append(name_value.to_lower())
	source.name = name_value
	mapping[old] = name_value
	for child in source.get("children", []):
		_unique_names(child, used, mapping)


func _remap_parents(source: Dictionary, mapping: Dictionary) -> void:
	if mapping.has(source.get("stepParentName")):
		source.stepParentName = mapping[source.stepParentName]
	for child in source.get("children", []):
		_remap_parents(child, mapping)


func open_mirror(element: Node3D) -> void:
	if editor_mode != "Model":
		return

	edit_history.flush_pending.emit()
	target = element
	mirror_error.text = ""
	mirror_dialog.popup_centered(Vector2i(340, 190))


func mirror_shape(element: Node3D, axis: int, plane: float) -> bool:
	var after := mirror_fields(element, axis, plane)
	if after.is_empty():
		return false
	var uid := Document.uid_of(element)
	edit_history.flush_pending.emit()
	return edit_history.execute(SetFields.new(document, uid, after, "Mirror Shape"))


## The fields that reflect an element across a plane in its parent's space,
## or {} if it cannot be mirrored (zero scale).
func mirror_fields(element: Node3D, axis: int, plane: float) -> Dictionary:
	if not is_instance_valid(element) or axis < 0 or axis > 2 or absf(element.basis.determinant()) < MIN_TRANSFORM_DETERMINANT:
		return {}
	if not document.has(Document.uid_of(element)):
		return {}
	var source: Dictionary = element.get_meta("shape_element")
	var after: Dictionary = {}
	var signs := Vector3.ONE
	signs[axis] = -1
	var reflection := Basis.from_scale(signs)
	var shift := Vector3.ZERO
	shift[axis] = 2 * plane / Units.PER_BLOCK
	var desired := Transform3D(reflection * element.basis, reflection * element.position + shift)
	var pivot: Vector3 = reflection * (transform_controller.vector_from_array(source.get("rotationOrigin", [0, 0, 0])) / Units.PER_BLOCK) + shift
	var start := pivot + desired.basis.inverse() * (desired.origin - pivot)
	var size := Geometry.size_of(source)
	var scale_value := desired.basis.get_scale()
	var rotation := desired.basis * Basis.from_scale(Vector3.ONE / scale_value)
	var angles := rotation.get_euler(EULER_ORDER_XYZ) * 180 / PI
	after.from = transform_controller.vector_to_array(start * 16)
	after.to = transform_controller.vector_to_array((start + size) * 16)
	after.rotationOrigin = transform_controller.vector_to_array(pivot * 16)
	for i in range(3):
		after["rotation" + ["X", "Y", "Z"][i]] = angles[i]
		after["scale" + ["X", "Y", "Z"][i]] = scale_value[i]
	return after


## Mirrors several elements, each in its own parent's space, as one step.
func mirror_shapes(elements: Array, axis: int, plane: float) -> bool:
	if elements.size() == 1:
		return mirror_shape(elements[0], axis, plane)
	var steps: Array = []
	for element in elements:
		var fields := mirror_fields(element, axis, plane)
		if fields.is_empty():
			return false
		steps.append(SetFields.new(document, Document.uid_of(element), fields))
	return edit_history.execute(Composite.new(document, steps, "Mirror Shapes"))
