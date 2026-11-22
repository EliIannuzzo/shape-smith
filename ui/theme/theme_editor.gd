extends "res://ui/shared/tool_window.gd"
signal confirmed
signal palette_preview_requested(colors: Dictionary)
const Settings = preload("res://ui/theme/theme_settings.gd")
static var Palette = preload("res://ui/theme/editor_palette.tres")
const GROUPS := {
	"Backgrounds": ["workspace", "chrome", "surface", "hover", "border", "border_light", "selection"],
	"Text and highlights": ["text", "muted", "disabled", "accent", "key_selection"],
	"Viewport": ["checker_dark", "checker_light", "grid_major", "grid_minor", "axis_x", "axis_y", "axis_z", "motion_previous", "motion_future"]}
var settings = Settings.new()
var pickers := {}
var baseline := {}
var committed := false
@onready var presets: OptionButton = $Panel/Margin/Layout/Header/Presets
@onready var message: Label = $Panel/Margin/Layout/Message
@onready var importer: FileDialog = $Importer
@onready var exporter: FileDialog = $Exporter
@onready var color_scroll: ScrollContainer = $Panel/Margin/Layout/Colors
@onready var apply_button: Button = $Panel/Margin/Layout/Footer/Apply
@onready var cancel_button: Button = $Panel/Margin/Layout/Footer/Cancel


func _ready() -> void:
	super()
	for label in Settings.PRESET_NAMES:
		presets.add_item(label)
	presets.add_item("Custom")
	presets.item_selected.connect(func(index: int):
		if index < Settings.PRESET_NAMES.size():
			preview(Settings.preset(index)))
	$Panel/Margin/Layout/Header/Reset.pressed.connect(func():
		presets.select(0)
		preview(Settings.defaults()))
	for group in GROUPS:
		var heading := Label.new()
		heading.text = group
		color_scroll.get_node("Fields").add_child(heading)
		for key in GROUPS[group]:
			var row = preload("res://ui/shared/color_property_row.tscn").instantiate()
			row.property_key = key
			color_scroll.get_node("Fields").add_child(row)
			pickers[key] = row.picker
			row.color_edited.connect(_color_edited)
	$Panel/Margin/Layout/Files/Import.pressed.connect(func(): importer.popup_centered_ratio(0.7))
	$Panel/Margin/Layout/Files/Export.pressed.connect(func(): exporter.popup_centered_ratio(0.7))
	apply_button.pressed.connect(func(): confirmed.emit())
	cancel_button.pressed.connect(hide)
	importer.file_selected.connect(import_file)
	exporter.file_selected.connect(export_file)
	confirmed.connect(apply_theme)
	visibility_changed.connect(func():
		if not visible and not committed and not baseline.is_empty():
			palette_preview_requested.emit(baseline))


func _color_edited(key: String, color: Color) -> void:
	var values := Settings.colors()
	values[key] = color.to_html(true)
	presets.select(Settings.PRESET_NAMES.size())
	preview(values)


func get_ok_button() -> Button:
	return apply_button


func get_cancel_button() -> Button:
	return cancel_button


func open() -> void:
	if visible:
		return

	baseline = Settings.colors()
	committed = false
	message.text = "Changes preview live. Apply saves your theme."
	_sync()
	for index in range(Settings.PRESET_NAMES.size() + 1):
		presets.select(index)
		if index == Settings.PRESET_NAMES.size() or Settings.preset(index) == baseline:
			break
	open_window()


func preview(values: Dictionary) -> void:
	palette_preview_requested.emit(values)
	_sync()


func _sync() -> void:
	for key in pickers:
		pickers[key].color = Palette.get(key)


func apply_theme() -> void:
	var result: Error = settings.write_file(settings.path, Settings.colors())
	if result != OK:
		message.text = "Could not save theme: " + error_string(result)
		# Keep the preview and dialog available if persistence failed.
		return

	committed = true
	baseline = Settings.colors()
	hide()


func import_file(path: String) -> void:
	var values := settings.read_file(path)
	if values.is_empty():
		message.text = "Could not import theme. Choose a version 1 Shapesmith theme JSON file with valid colors."
		return

	presets.select(Settings.PRESET_NAMES.size())
	preview(values)
	message.text = "Imported for preview. Apply to save."


func export_file(path: String) -> void:
	var result: Error = settings.write_file(path, Settings.colors())
	message.text = "Theme exported." if result == OK else "Could not export theme: " + error_string(result)
