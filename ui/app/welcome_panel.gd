extends PanelContainer
## Shown over the empty viewport until a shape is open: start a new shape (empty
## or from a template), open a file, open an example, or reopen a recent file.

static var Palette = preload("res://ui/theme/editor_palette.tres")
const RECENT_SHOWN := 6

var app
var recent: VBoxContainer


func _init() -> void:
	name = "Welcome"
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	custom_minimum_size = Vector2(380, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(Palette.chrome, 0.94)
	style.border_color = Palette.border_light
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(20)
	add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 8)
	add_child(layout)
	var title := Label.new()
	title.text = "Start a shape"
	title.add_theme_font_size_override("font_size", 18)
	layout.add_child(title)
	for entry in [["New Empty Shape", "Ctrl+N", _new_empty], ["New Block (one 16×16×16 cube)", "", _new_block],
			["Open…", "Ctrl+O", func(): app.open_shape_picker()]]:
		var button := Button.new()
		button.text = entry[0] + ("    " + entry[1] if not entry[1].is_empty() else "")
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(entry[2])
		layout.add_child(button)
	var heading := Label.new()
	heading.text = "Recent files"
	heading.add_theme_color_override("font_color", Palette.muted)
	layout.add_child(heading)
	recent = VBoxContainer.new()
	layout.add_child(recent)
	var hint := Label.new()
	hint.text = "Or drop a .json shape onto the window. Ctrl+Shift+P finds any command."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Palette.muted)
	layout.add_child(hint)


func bind(editor) -> void:
	app = editor
	app.recent_files.changed.connect(refresh)
	refresh()


func refresh() -> void:
	for child in recent.get_children():
		child.queue_free()
	var paths: PackedStringArray = app.recent_files.paths
	if paths.is_empty():
		var none := Label.new()
		none.text = "None yet."
		none.add_theme_color_override("font_color", Palette.disabled)
		recent.add_child(none)
	for i in range(mini(paths.size(), RECENT_SHOWN)):
		var button := Button.new()
		button.text = paths[i].get_file()
		button.tooltip_text = paths[i]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.flat = true
		button.pressed.connect(app._on_recent_selected.bind(i))
		recent.add_child(button)


func _new_empty() -> void:
	app.request_new_shape()


func _new_block() -> void:
	app._request_document_action(func():
		app._new_shape()
		app.hierarchy_editor.add_shape()
		app.history.mark_saved())

