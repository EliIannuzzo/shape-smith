extends "res://ui/shared/tool_window.gd"

signal settings_changed(settings: Dictionary)
signal export_requested(path: String)
const Baker = preload("res://core/animation/animation_baker.gd")
const REDUCTION_MODES := ["auto", "custom", "off"]
var updating := false
@onready var reduction: OptionButton = %Reduction
@onready var interval: SpinBox = %Interval
@onready var position_tolerance: SpinBox = %PositionTolerance
@onready var rotation_tolerance: SpinBox = %RotationTolerance
@onready var scale_tolerance: SpinBox = %ScaleTolerance
@onready var picker: FileDialog = $Picker


func _ready() -> void:
	super()
	for label in ["Auto", "Custom", "Off"]:
		reduction.add_item(label)
	reduction.item_selected.connect(func(_index: int): _settings_edited())
	for input in [interval, position_tolerance, rotation_tolerance, scale_tolerance]:
		input.value_changed.connect(func(_value: float): _settings_edited())
	%Cancel.pressed.connect(hide)
	%Export.pressed.connect(func(): picker.popup_centered_ratio(0.75))
	picker.file_selected.connect(func(path: String): export_requested.emit(path))


func open(path: String, options: Dictionary) -> void:
	updating = true
	var config := Baker.validated_settings(options)
	reduction.select(REDUCTION_MODES.find(config.reduction))
	interval.value = config.frameInterval
	position_tolerance.value = config.positionTolerance
	rotation_tolerance.value = config.rotationTolerance
	scale_tolerance.value = config.scaleTolerance
	updating = false
	_update_controls()
	var name_value := path.get_file().get_basename().trim_suffix(".shapesmith")
	if not path.is_empty():
		picker.current_dir = ProjectSettings.globalize_path(path).get_base_dir()
	picker.current_file = ("Untitled" if name_value.is_empty() else name_value) + ".json"
	open_window()


func settings() -> Dictionary:
	return {
		"reduction": REDUCTION_MODES[reduction.selected], "frameInterval": int(interval.value),
		"positionTolerance": position_tolerance.value,
		"rotationTolerance": rotation_tolerance.value, "scaleTolerance": scale_tolerance.value,
	}


func _settings_edited() -> void:
	if updating:
		return
	_update_controls()
	settings_changed.emit(settings())


func _update_controls() -> void:
	var custom := reduction.selected == 1
	for input in [position_tolerance, rotation_tolerance, scale_tolerance]:
		input.editable = custom
	%Explanation.text = "Maximum error per axis compared with the sampled bake." if custom else (
		"Auto uses 0.01 shape units, 0.1 degrees, and 0.001 scale tolerance." if reduction.selected == 0
		else "Off keeps every sampled in-between frame."
	)


func show_summary(added: int, removed: int, error := "", support := 0) -> void:
	%Summary.text = error if not error.is_empty() else "%d in-between keys · %d redundant keys removed" % [added, removed]
	if error.is_empty() and support > 0:
		%Summary.text += "\n%d shared-frame rotation support samples required by Vintage Story" % support
	%Export.disabled = not error.is_empty()
