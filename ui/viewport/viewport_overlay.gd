extends MarginContainer
## Controls drawn over the 3D view: the gizmo tool bar at the top left, the
## render mode and view cube at the top right, and the welcome panel in the
## middle while no shape is open. Empty space passes clicks to the viewport.

const ViewCube = preload("res://ui/viewport/view_cube.gd")
const LightingPanel = preload("res://ui/viewport/lighting_panel.gd")
const EditorIcons = preload("res://ui/shared/editor_icons.gd")

signal render_mode_selected(mode: int)

var top: HBoxContainer
var left: HBoxContainer
var right: VBoxContainer
var render_mode: OptionButton
var lighting_button: Button
var lighting
var view_cube


func _init() -> void:
	name = "Overlay"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		add_theme_constant_override("margin_" + side, 8)
	top = HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	add_child(top)
	left = HBoxContainer.new()
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(left)
	right = VBoxContainer.new()
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right.alignment = BoxContainer.ALIGNMENT_BEGIN
	top.add_child(right)
	render_mode = OptionButton.new()
	render_mode.tooltip_text = "Render mode"
	render_mode.focus_mode = Control.FOCUS_NONE
	render_mode.item_selected.connect(func(index: int): render_mode_selected.emit(index))
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.alignment = BoxContainer.ALIGNMENT_END
	right.add_child(row)
	lighting_button = Button.new()
	lighting_button.text = "Lighting"
	# The same icons as the View menu.
	lighting_button.icon = EditorIcons.icon("light_mode")
	lighting_button.add_theme_constant_override("icon_max_width", 18)
	lighting_button.tooltip_text = "Sun, time of day, weather and wind for the Normal render mode"
	lighting_button.focus_mode = Control.FOCUS_NONE
	lighting_button.pressed.connect(open_lighting)
	row.add_child(lighting_button)
	row.add_child(render_mode)
	lighting = LightingPanel.new()
	add_child(lighting)
	view_cube = ViewCube.new()
	view_cube.size_flags_horizontal = Control.SIZE_SHRINK_END
	right.add_child(view_cube)


func bind(viewport, toolbar: Control, modes: PopupMenu) -> void:
	toolbar.reparent(left, false)
	toolbar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	for i in range(modes.item_count):
		render_mode.add_item(modes.get_item_text(i), modes.get_item_id(i))
		render_mode.set_item_icon(i, EditorIcons.icon("contrast"))
	render_mode.add_theme_constant_override("icon_max_width", 18)
	view_cube.bind(viewport)
	lighting.bind(viewport.texture_library)


func open_lighting() -> void:
	var corner := lighting_button.get_screen_position() + Vector2(lighting_button.size.x, lighting_button.size.y + 4)
	lighting.open(Vector2i(corner))


func set_render_mode(mode: int) -> void:
	render_mode.select(render_mode.get_item_index(mode))
