extends HBoxContainer

signal curve_edited(group: String, curve: String)
const Baker = preload("res://core/animation/animation_baker.gd")
@export var group := "offset"
@onready var choices: OptionButton = $Curve


func _ready() -> void:
	for label in Baker.CURVE_LABELS:
		choices.add_item(label)
	choices.select(0)
	choices.item_selected.connect(func(index: int): curve_edited.emit(group, Baker.CURVES[index]))


func sync(pose: Dictionary) -> void:
	choices.select(Baker.CURVES.find(Baker.curve(pose, group)))
	choices.disabled = not Baker.AXES.any(func(axis: String): return pose.get(group + axis) != null)
