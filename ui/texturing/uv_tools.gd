extends Node

const MAX_EXPORT_DIMENSION := 8192
## Output pixels per texture pixel. Whole numbers keep every border on whole pixels.
const EXPORT_SCALES := [1, 2, 4, 8, 16]
const DEFAULT_SCALE := 8
const Renderer = preload("res://core/textures/uv_layout_renderer.gd")
## Export dialog checkboxes: option key, label, default.
const EXPORT_OPTIONS := [["fills", "Fill faces with direction colours", true], ["names", "Element names", true],
	["directions", "Direction letters (N E S W U D)", true], ["arrows", "Orientation arrows", true],
	["texture", "Texture underneath", false], ["layers", "Separate files per layer", false]]

const Geometry = preload("res://core/model/shape_geometry.gd")
const Document = preload("res://core/document/shape_document.gd")
const SetFaceFields = preload("res://core/commands/set_face_fields.gd")
const Composite = preload("res://core/commands/composite_command.gd")
const EditorTheme = preload("res://ui/theme/editor_theme.tres")
var panel
var confirmation: ConfirmationDialog
var export_dialog: ConfirmationDialog
var texture_choice: OptionButton
var resolution: OptionButton
var checks: Dictionary = {}
var picker: FileDialog
var error_dialog: AcceptDialog


func _ready() -> void:
	confirmation = ConfirmationDialog.new()
	confirmation.title = "Texel all UVs?"
	confirmation.theme = EditorTheme
	add_child(confirmation)
	confirmation.confirmed.connect(apply_texel_all)
	export_dialog = ConfirmationDialog.new()
	export_dialog.title = "Export UV layout"
	export_dialog.ok_button_text = "Save PNG…"
	export_dialog.theme = EditorTheme
	add_child(export_dialog)
	var layout := VBoxContainer.new()
	export_dialog.add_child(layout)
	texture_choice = OptionButton.new()
	_add_field(layout, "Texture", texture_choice)
	resolution = OptionButton.new()
	_add_field(layout, "Scale", resolution)
	for factor in EXPORT_SCALES:
		resolution.add_item("%d×" % factor)
		resolution.set_item_metadata(resolution.item_count - 1, factor)
	resolution.select(EXPORT_SCALES.find(DEFAULT_SCALE))
	for option in EXPORT_OPTIONS:
		var check := CheckButton.new()
		check.text = option[1]
		check.button_pressed = option[2]
		checks[option[0]] = check
		layout.add_child(check)
	var note := Label.new()
	note.text = "Exports every face that uses the chosen texture, coloured by direction:\nnorth/south blue, east/west red, up/down green. Borders sit inside each face.\nSeparate layers are saved as -fills, -borders and -labels next to the file."
	layout.add_child(note)
	picker = FileDialog.new()
	picker.title = "Export UV layout as PNG"
	picker.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.filters = PackedStringArray(["*.png ; UV layout PNG"])
	picker.theme = EditorTheme
	add_child(picker)
	export_dialog.confirmed.connect(func():
		picker.current_file = str(texture_choice.get_item_metadata(texture_choice.selected)).validate_filename() + "-uv.png"
		picker.popup_centered_ratio(0.75))
	picker.file_selected.connect(func(path: String):
		var id := str(texture_choice.get_item_metadata(texture_choice.selected))
		var result := export_png(path, id, dialog_options())
		if result != OK:
			error_dialog.dialog_text = "Could not export UV layout: " + error_string(result)
			error_dialog.popup_centered())
	error_dialog = AcceptDialog.new()
	error_dialog.theme = EditorTheme
	error_dialog.title = "UV export"
	add_child(error_dialog)


func _add_field(layout: Control, title: String, control: Control) -> void:
	var row := HBoxContainer.new()
	layout.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 100
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)


func entries() -> Array:
	var result: Array = []
	if not is_instance_valid(panel.model_root) or panel.library == null:
		return result

	for node in Geometry.elements(panel.model_root):
		var source: Dictionary = node.get_meta("shape_element")
		for face_name in Geometry.FACES:
			if not source.get("faces", {}).has(face_name):
				continue

			var face: Dictionary = source.faces[face_name]
			var id := str(face.get("texture", "")).trim_prefix("#")
			result.append({"node": node, "face": face_name, "id": id, "name": str(source.get("name", "")),
				"rotation": float(face.get("rotation", 0)),
				"uv": Geometry.face_uv(face, panel.library.uv_size(id)), "dimensions": panel.library.uv_size(id)})
	return result


func confirm_texel_all() -> void:
	panel.finish_pending()
	var count := entries().size()
	if count == 0:
		return

	confirmation.dialog_text = "Resize all %d face UVs across the entire model?\nTexel size: %s shape units per pixel.\nUV origins, flips and rotations are preserved. Snapped faces align to pixels.\nThis can be undone in one step." % [count, str(panel.library.texel_size)]
	confirmation.popup_centered()


func apply_texel_all() -> void:
	panel.finish_pending()
	var document = panel.document
	if document == null or panel.history == null:
		return

	var steps: Array = []
	for entry in entries():
		var source: Dictionary = entry.node.get_meta("shape_element")
		var uv: Array = panel.texel_uv(source, entry.face)
		var uid := Document.uid_of(entry.node)
		if source.faces[entry.face].get("uv") != uv and document.has(uid):
			steps.append(SetFaceFields.new(document, uid, entry.face, {"uv": uv}))
	if not steps.is_empty():
		panel.history.execute(Composite.new(document, steps, "Texel All UVs"))


func open_export() -> void:
	panel.finish_pending()
	texture_choice.clear()
	var ids: Array = []
	for entry in entries():
		if not entry.id.is_empty() and not entry.id in ids:
			ids.append(entry.id)
	ids.sort()
	for id in ids:
		texture_choice.add_item("#" + id)
		texture_choice.set_item_metadata(texture_choice.item_count - 1, id)
		if is_instance_valid(panel.selected) and not panel.current_face.is_empty() and id == str(panel.face_data().get("texture", "")).trim_prefix("#"):
			texture_choice.select(texture_choice.item_count - 1)
	if ids.is_empty():
		error_dialog.dialog_text = "Assign a texture to a face before exporting its UV layout."
		error_dialog.popup_centered()
		return

	export_dialog.popup_centered(Vector2i(480, 380))


## The options chosen in the export dialog.
func dialog_options() -> Dictionary:
	var options := {"scale": int(resolution.get_item_metadata(resolution.selected))}
	for key in checks:
		options[key] = checks[key].button_pressed
	return options


## Writes the UV layout of every face using texture `id`. options: scale
## (output pixels per texture pixel, default 8), fills, borders, names,
## directions, arrows, texture (draw the image underneath) and layers (also
## write <name>-fills.png, -borders.png and -labels.png).
func export_png(path: String, id: String, options: Dictionary = {}) -> Error:
	var factor := int(options.get("scale", DEFAULT_SCALE))
	var texture: Texture2D = panel.library.texture(id)
	var uv_dimensions: Vector2 = panel.library.uv_size(id)
	var base: Vector2i = Vector2i(texture.get_size()) if texture != null else Vector2i(uv_dimensions)
	var size_value := base * factor
	if factor < 1 or size_value.x < 1 or size_value.y < 1 or size_value.x > MAX_EXPORT_DIMENSION or size_value.y > MAX_EXPORT_DIMENSION:
		return ERR_INVALID_PARAMETER

	var faces: Array = entries().filter(func(entry): return entry.id == id)
	var images: Dictionary = Renderer.render(faces, uv_dimensions, size_value, options, texture.get_image() if texture != null else null)
	var file := path if path.to_lower().ends_with(".png") else path + ".png"
	var result: Error = images.combined.save_png(file)
	if result == OK and options.get("layers", false):
		for layer in ["fills", "borders", "labels"]:
			result = images[layer].save_png(file.trim_suffix(".png") + "-%s.png" % layer)
			if result != OK:
				break
	return result


func face_pixel_rect(uv: Array, uv_dimensions: Vector2, image_size: Vector2i) -> Rect2i:
	return Renderer.face_rect(uv, uv_dimensions, image_size)
