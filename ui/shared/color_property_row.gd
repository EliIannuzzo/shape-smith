extends HBoxContainer
signal color_edited(key: String, color: Color)
@export var property_key := ""
@onready var picker: ColorPickerButton = $Picker


func _ready() -> void:
	$Label.text = property_key.capitalize()
	picker.color_changed.connect(func(color: Color): color_edited.emit(property_key, color))
