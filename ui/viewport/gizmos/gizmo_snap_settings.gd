extends "res://ui/shared/toggle_settings.gd"
signal settings_changed
@export var uv_mode := false
@onready var translation_step: SpinBox = $Popup/Margin/Content/Move/Value
@onready var rotation_step: SpinBox = $Popup/Margin/Content/Rotate/Value
@onready var scale_increment: SpinBox = $Popup/Margin/Content/Scale/Value


func _ready() -> void:
	super()
	if uv_mode:
		enabled_toggle.tooltip_text = "Toggle UV snapping for this face"
		settings_button.tooltip_text = "UV snap settings"
		$Popup/Margin/Content/Title.text = "UV snap increments"
		$Popup/Margin/Content/Move/Label.text = "Step (image pixels)"
		translation_step.min_value = 0.125
		translation_step.step = 0.125
		translation_step.value = 1.0
		translation_step.tooltip_text = "UV grid spacing in image pixels. 1 snaps to individual pixels."
		$Popup/Margin/Content/Rotate.hide()
		$Popup/Margin/Content/Scale.hide()
	enabled_changed.connect(func(_on: bool): settings_changed.emit())
	for input in [translation_step, rotation_step, scale_increment]:
		input.value_changed.connect(func(_value: float): settings_changed.emit())
	popup.popup_hide.connect(func():
		for input in [translation_step, rotation_step, scale_increment]:
			input.apply())


func values() -> Dictionary:
	return {"enabled": is_enabled(), "translation": translation_step.value, "rotation": rotation_step.value, "scale": scale_increment.value}
