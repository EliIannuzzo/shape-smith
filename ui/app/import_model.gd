extends Node
## File → Import Model…: turns a glTF (.gltf, .glb) or FBX file into a shape
## (see ModelConverter). The dialog shows what the file holds and the
## conversion options; the result opens as a new, unsaved shape, or merges
## into the open one through Import Shape. A report lists everything that was
## not converted exactly.

const Converter = preload("res://core/import/model_converter.gd")

var app
var picker: FileDialog
var dialog: ConfirmationDialog
var stats_label: Label
var scale: SpinBox
var up: OptionButton
var centre: CheckBox
var non_box: OptionButton
var voxel_size: SpinBox
var snap: CheckBox
var animations: CheckBox
var report_dialog: AcceptDialog
var report_text: RichTextLabel
var path := ""
var scene: Node
var merge_requested := false


func bind(editor) -> void:
	app = editor
	picker = FileDialog.new()
	picker.title = "Import model"
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.filters = PackedStringArray(["*.gltf, *.glb ; glTF models", "*.fbx ; FBX models"])
	# Styled like the app's other file dialogs: this node is not a Control, so
	# the editor theme does not reach the dialog on its own.
	app.style_file_dialog(picker)
	picker.file_selected.connect(begin)
	add_child(picker)
	dialog = ConfirmationDialog.new()
	dialog.title = "Import Model"
	dialog.ok_button_text = "Open as New Shape"
	dialog.add_button("Merge into This Shape", true, "merge")
	var layout := VBoxContainer.new()
	dialog.add_child(layout)
	stats_label = Label.new()
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_label.custom_minimum_size.x = 440
	layout.add_child(stats_label)
	scale = _spin(layout, "Shape units per metre", 0.01, 1000.0, 0.01, 16.0, "16 matches Blockbench and Vintage Story: one metre is one block.")
	up = _choice(layout, "Up axis", ["Y (glTF, Blockbench, Godot)", "Z (some FBX files)"])
	centre = _check(layout, "Put the model's origin at the centre of the block", true)
	non_box = _choice(layout, "Parts that are not boxes", ["Voxelise into cubes", "Skip"])
	voxel_size = _spin(layout, "Voxel size (shape units)", 0.25, 16.0, 0.25, 1.0, "Smaller cubes follow the shape closer, but make more elements.")
	snap = _check(layout, "Snap coordinates to whole shape units", false)
	animations = _check(layout, "Import animations (sampled at 30 fps)", true)
	dialog.confirmed.connect(func(): run(false))
	dialog.custom_action.connect(func(action: String):
		if action == "merge":
			dialog.hide()
			run(true))
	dialog.canceled.connect(_release)
	add_child(dialog)
	report_dialog = AcceptDialog.new()
	report_dialog.title = "Import report"
	report_text = RichTextLabel.new()
	report_text.custom_minimum_size = Vector2(460, 220)
	report_text.fit_content = false
	report_dialog.add_child(report_text)
	add_child(report_dialog)


func _row(layout: Control, title: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	layout.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 200
	row.add_child(label)
	return row


func _spin(layout: Control, title: String, low: float, high: float, step_value: float, value: float, tip: String) -> SpinBox:
	var row := _row(layout, title)
	var box := SpinBox.new()
	box.min_value = low
	box.max_value = high
	box.step = step_value
	box.value = value
	box.tooltip_text = tip
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(box)
	return box


func _choice(layout: Control, title: String, items: Array) -> OptionButton:
	var row := _row(layout, title)
	var button := OptionButton.new()
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for item in items:
		button.add_item(item)
	row.add_child(button)
	return button


func _check(layout: Control, title: String, value: bool) -> CheckBox:
	var box := CheckBox.new()
	box.text = title
	box.button_pressed = value
	layout.add_child(box)
	return box


func open_picker() -> void:
	picker.popup_centered_ratio(0.75)


## Reads the model and shows what it holds with the options.
func begin(file: String) -> bool:
	_release()
	var loaded := Converter.load_scene(file)
	if not loaded.error.is_empty():
		app.notify(loaded.error, "error")
		return false
	path = file
	scene = loaded.scene
	var stats := Converter.stats(scene)
	stats_label.text = "%s: %d meshes, %d triangles, %d bones, %d animations." % [file.get_file(), stats.meshes, stats.triangles, stats.bones, stats.animations]
	dialog.get_ok_button().disabled = false
	for button in dialog.get_children(true):
		if button is Button and button.text == "Merge into This Shape":
			button.disabled = app.viewport.models.get_child_count() == 0
	dialog.theme = app.theme
	dialog.popup_centered()
	return true


func options() -> Dictionary:
	return {"scale": scale.value, "up": "z" if up.selected == 1 else "y", "offset": [8.0, 0.0, 8.0] if centre.button_pressed else [0.0, 0.0, 0.0],
		"non_box": "skip" if non_box.selected == 1 else "voxelise", "voxel_size": voxel_size.value, "snap": snap.button_pressed,
		"animations": animations.button_pressed, "texture_dir": path.get_base_dir(), "texture_prefix": path.get_file().get_basename()}


## Converts and opens (or merges) the result. Returns the report.
func run(merge: bool) -> Dictionary:
	if scene == null:
		return {}
	dialog.hide()
	var result: Dictionary = Converter.new().convert(scene, options())
	_release()
	var shape_path := "user://imports".path_join(path.get_file().get_basename() + ".json")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shape_path.get_base_dir()))
	var file := FileAccess.open(shape_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(result.data, "\t"))
	file.close()
	if merge and app.viewport.models.get_child_count() > 0:
		app.importer.begin(shape_path)
	else:
		app._load_shape(shape_path)
		# A new, unsaved shape: Save asks where to put it.
		app.current_path = ""
		app.document_is_working = false
		app.context_models.source_path = ""
		app.history.mark_unsaved()
		app._update_title()
		app.status.text = "Imported %s · not saved yet" % path.get_file()
	_show_report(result.report)
	return result.report


func _show_report(report: Dictionary) -> void:
	var summary := "Imported %d boxes and %d groups from %s." % [report.boxes, report.groups, path.get_file()]
	if report.approximated.is_empty() and report.skipped.is_empty():
		app.notify(summary + " Everything converted exactly.")
		return
	app.notify(summary + " %d parts were approximated and %d skipped." % [report.approximated.size(), report.skipped.size()], "warning")
	var lines: PackedStringArray = [summary, ""]
	for entry in report.approximated:
		lines.append("• %s: %s" % [entry.name, entry.reason])
	for entry in report.skipped:
		lines.append("• %s: %s" % [entry.name, entry.reason])
	report_text.text = "\n".join(lines)
	report_dialog.theme = app.theme
	report_dialog.popup_centered()


func _release() -> void:
	if scene != null:
		scene.free()
		scene = null
