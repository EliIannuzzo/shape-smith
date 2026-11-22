extends PanelContainer
signal property_edited(element: Node3D, property: String, axis: int, value: float)
const TransformEditor = preload("res://ui/viewport/gizmos/transform_editor.gd")
const PASSES := ["Auto", "Opaque", "Opaque No Cull", "Blend No Cull", "Transparent", "Liquid", "Top Soil", "Meta", "Opaque Water Plant", "Decor"]
const GROUPS := {"position": "Position · shape units", "size": "Size · shape units", "pivot": "Pivot · shape units", "rotation": "Rotation · degrees", "scale": "Scale"}
var edit_controller: TransformEditor
var model_mode := false
var selected: Node3D
var fields: Dictionary = {}
var pending: Dictionary = {}
var updating := false
## Every selected element; the inspector edits all of them when there are several.
var selection_nodes: Array = []
const MIXED := "—"
@onready var title: Label = $Margin/Layout/Title
@onready var content: VBoxContainer = $Margin/Layout/Scroll/Content
@onready var render_pass_label: Label = $Margin/Layout/Scroll/Content/RenderPassLabel
@onready var render_pass: OptionButton = $Margin/Layout/Scroll/Content/RenderPass


func bind(controller: TransformEditor) -> void:
	edit_controller = controller
	property_edited.connect(controller.edit_property)


func _ready() -> void:
	for group in GROUPS:
		var row = content.get_node(NodePath(group))
		fields[group] = row.inputs
		row.axis_edited.connect(func(axis: int, value: float):
			if not updating and is_instance_valid(selected):
				pending.erase(group + str(axis))
				_edit(group, axis, value))
		row.pending_edited.connect(func(axis: int, input: SpinBox):
			if not updating:
				pending[group + str(axis)] = input)
	for index in range(PASSES.size()):
		render_pass.add_item(PASSES[index], index)
		render_pass.set_item_metadata(index, index - 1)
	render_pass.item_selected.connect(func(index: int):
		finish_pending()
		if is_instance_valid(selected):
			_edit("renderPass", 0, render_pass.get_item_metadata(index)))


## The elements to edit together. Values they share are shown; values that
## differ show as "—", and typing a value sets it on all of them.
func set_selection(nodes: Array) -> void:
	selection_nodes = nodes.filter(func(node): return is_instance_valid(node))
	if visible and is_instance_valid(selected):
		sync_fields(selected.get_meta("shape_element"))


func _editing_many() -> bool:
	return selection_nodes.size() > 1 and selection_nodes.has(selected)


func _edit(group: String, axis: int, value: float) -> void:
	if _editing_many():
		edit_controller.edit_property_many(selection_nodes, group, axis, value)
	else:
		property_edited.emit(selected, group, axis, value)


func set_model_mode(enabled: bool) -> void:
	model_mode = enabled
	inspect(selected)


func finish_pending() -> void:
	var inputs := pending.values()
	pending.clear()
	for input in inputs:
		input.apply()


func inspect(element: Node3D) -> void:
	if selected != element:
		finish_pending()
	selected = element
	visible = model_mode and is_instance_valid(selected)
	if visible:
		sync_fields(selected.get_meta("shape_element"))


func sync_fields(source: Dictionary) -> void:
	updating = true
	var many := _editing_many()
	title.text = ("%d elements" % selection_nodes.size()) if many else str(selected.get_meta("shape_element").get("name", selected.name))
	for group in fields:
		for axis in range(3):
			var value := _field_value(source, group, axis)
			fields[group][axis].set_value_no_signal(value)
			if many and selection_nodes.any(func(node): return not is_equal_approx(_field_value(node.get_meta("shape_element"), group, axis), value)):
				fields[group][axis].get_line_edit().text = MIXED
	var pass_value := int(source.get("renderPass", -1))
	while render_pass.item_count > PASSES.size():
		render_pass.remove_item(render_pass.item_count - 1)
	var index := pass_value + 1 if pass_value >= -1 and pass_value <= 8 else -1
	if index < 0:
		render_pass.add_item("Custom (%d)" % pass_value)
		index = render_pass.item_count - 1
		render_pass.set_item_metadata(index, pass_value)
	render_pass.select(index)
	if many and selection_nodes.any(func(node): return int(node.get_meta("shape_element").get("renderPass", -1)) != pass_value):
		render_pass.select(-1)
	updating = false


static func _field_value(source: Dictionary, group: String, axis: int) -> float:
	match group:
		"position": return float(source.from[axis])
		"size": return float(source.to[axis]) - float(source.from[axis])
		"pivot": return float(source.get("rotationOrigin", [0, 0, 0])[axis])
		_: return float(source.get(group + ["X", "Y", "Z"][axis], 1 if group == "scale" else 0))


func _process(_delta: float) -> void:
	if visible and is_instance_valid(selected) and edit_controller != null:
		var preview := edit_controller.model_preview(selected)
		if not preview.is_empty():
			sync_fields(preview)
