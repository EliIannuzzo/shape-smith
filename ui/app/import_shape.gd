extends Node
## File → Import Shape…: merges another shape file into the open one as one
## undo step. A short dialog picks where the elements go, how to place them,
## what to do with animations, and how to handle a different texture size.

const ShapeLoader = preload("res://core/model/shape_loader.gd")
const ShapeImport = preload("res://core/model/shape_import.gd")
const Document = preload("res://core/document/shape_document.gd")
const AddElements = preload("res://core/commands/add_elements.gd")
const AddPoses = preload("res://core/commands/add_poses.gd")
const InsertClip = preload("res://core/commands/insert_clip.gd")
const SetDataEntries = preload("res://core/commands/set_data_entries.gd")
const Composite = preload("res://core/commands/composite_command.gd")

var app
var picker: FileDialog
var dialog: ConfirmationDialog
var target: OptionButton
var placement: OptionButton
var animations: OptionButton
var uv_row: HBoxContainer
var uv: OptionButton
var summary: Label
var path := ""
var incoming: Dictionary = {}
var parent_node: Node3D


func bind(editor) -> void:
	app = editor
	picker = FileDialog.new()
	picker.title = "Import shape"
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.filters = PackedStringArray(["*.json ; Vintage Story shape"])
	# Styled like the app's other file dialogs: this node is not a Control, so
	# the editor theme does not reach the dialog on its own.
	app.style_file_dialog(picker)
	picker.file_selected.connect(begin)
	add_child(picker)
	dialog = ConfirmationDialog.new()
	dialog.title = "Import Shape"
	dialog.ok_button_text = "Import"
	var layout := VBoxContainer.new()
	dialog.add_child(layout)
	target = _choice(layout, "Put it", [])
	placement = _choice(layout, "Placement", ["Keep where it is in the world", "Relative to the parent"])
	animations = _choice(layout, "Animations", ["Merge into clips with the same code", "Add as new clips", "Skip"])
	uv = _choice(layout, "Texture size", ["Rescale its UVs to this shape's size", "Keep its size (textureSizes)"])
	uv_row = uv.get_parent()
	summary = Label.new()
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	summary.custom_minimum_size.x = 420
	layout.add_child(summary)
	target.item_selected.connect(func(_index: int): _refresh())
	animations.item_selected.connect(func(_index: int): _refresh())
	uv.item_selected.connect(func(_index: int): _refresh())
	dialog.confirmed.connect(func(): run(path, options()))
	add_child(dialog)


func _choice(layout: Control, title: String, items: Array) -> OptionButton:
	var row := HBoxContainer.new()
	layout.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 110
	row.add_child(label)
	var button := OptionButton.new()
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for item in items:
		button.add_item(item)
	row.add_child(button)
	return button


func open_picker() -> void:
	if app.viewport.models.get_child_count() == 0:
		app.notify("Open or create a shape to import into.", "error")
		return
	picker.popup_centered_ratio(0.75)


## Reads the file and shows the import dialog.
func begin(file: String) -> void:
	incoming = load_data(file)
	if incoming.is_empty():
		return
	path = file
	parent_node = app.viewport.selected_node if is_instance_valid(app.viewport.selected_node) else null
	target.clear()
	target.add_item("At the root")
	if parent_node != null:
		target.add_item("Under %s" % parent_node.get_meta("shape_element").get("name", "the selected element"))
		target.select(1)
	dialog.theme = app.theme
	_refresh()
	dialog.popup_centered()


func load_data(file: String) -> Dictionary:
	var result: Dictionary = ShapeLoader.new().load_file(file)
	if not result.error.is_empty():
		app.notify("Could not import %s. %s" % [file.get_file(), result.error], "error")
		return {}
	result.root.free()
	return result.data


func options() -> Dictionary:
	var under := target.selected == 1 and is_instance_valid(parent_node)
	return {"parent": parent_node if under else null, "keep_world": placement.selected == 0,
		"animations": ["merge", "new", "skip"][animations.selected], "uv": ["rescale", "sizes"][uv.selected]}


func _plan(settings: Dictionary) -> Dictionary:
	var target_dir: String = ProjectSettings.globalize_path(app.current_path).get_base_dir() if not app.current_path.is_empty() else ProjectSettings.globalize_path(app.viewport.texture_library.directory)
	return ShapeImport.plan(app.viewport.shape_data, incoming, {"animations": settings.animations, "uv": settings.uv,
		"source_dir": ProjectSettings.globalize_path(path).get_base_dir(), "target_dir": target_dir})


func _refresh() -> void:
	var settings := options()
	placement.get_parent().visible = settings.parent != null
	var preview := _plan(settings)
	uv_row.visible = preview.mismatch
	var lines := PackedStringArray(["%s: %d element(s), %d texture(s), %d animation(s)." % [path.get_file(), _count(preview.elements),
		preview.textures.size(), (incoming.get("animations", []) as Array).size() if incoming.get("animations") is Array else 0]])
	lines.append_array(preview.report)
	summary.text = "\n".join(lines)


func _count(elements: Array) -> int:
	var total := 0
	for element in elements:
		if element is Dictionary:
			total += 1 + _count(element.get("children", []) if element.get("children") is Array else [])
	return total


## Imports `file` with these options (see options()). One undo step.
func run(file: String, settings: Dictionary) -> bool:
	if file != path or incoming.is_empty():
		incoming = load_data(file)
		path = file
	if incoming.is_empty():
		return false
	var plan := _plan(settings)
	var document = app.document
	var data: Dictionary = app.viewport.shape_data
	var library = app.viewport.texture_library
	var refresh_textures := func():
		library.invalidate()
		library.edited.emit()
	var steps: Array = []
	if not plan.textures.is_empty():
		steps.append(SetDataEntries.new(data, "textures", plan.textures, "", refresh_textures))
	if not plan.texture_sizes.is_empty():
		steps.append(SetDataEntries.new(data, "textureSizes", plan.texture_sizes, "", refresh_textures))
	var parent: Node3D = settings.get("parent")
	var parent_uid := Document.uid_of(parent) if parent != null else Document.ROOT
	var root: Node3D = app.viewport.models.get_child(0)
	var entries: Array = []
	for source in plan.elements:
		if parent != null and settings.get("keep_world", true):
			# Authored at the root of their own file: keep that world placement.
			var fields: Dictionary = app.hierarchy_editor.fields_for(source, root.global_transform * app._rest_transform(source), root.global_transform, parent.global_transform)
			if fields.is_empty():
				app.notify("Cannot keep %s's placement under that parent." % source.get("name", "an element"), "error")
				return false
			source.merge(fields, true)
		entries.append({"parent": parent_uid, "source": source})
	var add = AddElements.new(document, entries)
	steps.append(add)
	if not plan.poses.is_empty():
		steps.append(AddPoses.new(document, plan.poses))
	var clip_count: int = Document.animations(data).size()
	for clip in plan.clips:
		steps.append(InsertClip.new(data, clip_count, clip, "", app.workspace.editor._notify, {"index": clip_count, "frame": 0.0}, {"index": app.workspace.selected, "frame": app.workspace.frame}))
		clip_count += 1
	if not app.history.execute(Composite.new(document, steps, "Import %s" % file.get_file())):
		app.notify("Could not import %s." % file.get_file(), "error")
		return false
	if not plan.clips.is_empty() or not plan.poses.is_empty():
		app._queue_timeline(true)
	app._select_element(app.scene_sync.node_for(add.added()[0]) if not add.added().is_empty() else null)
	var message := "Imported %d element(s) from %s." % [_count(plan.elements), file.get_file()]
	if not plan.report.is_empty():
		message += " " + " ".join(plan.report)
	app.notify(message)
	return true
