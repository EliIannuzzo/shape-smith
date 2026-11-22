extends HBoxContainer
signal tool_selected(mode: int)
signal space_selected(local_space: bool)
signal snapping_changed(settings: Dictionary)
@onready var bar: PanelContainer = $Tools
@onready var mode_buttons: HBoxContainer = $Tools/Buttons
@onready var space: OptionButton = $Space
@onready var snap = $Snap
@onready var motion = $MotionPath


func bind_workspace(workspace: Node) -> void:
	$MotionPath.workspace = workspace


func _ready() -> void:
	for index in range(mode_buttons.get_child_count()):
		mode_buttons.get_child(index).pressed.connect(func(): tool_selected.emit(index))
	space.item_selected.connect(func(index: int): space_selected.emit(index == 0))
	space.set_item_tooltip(1, "World-aligned handles. Scale is projected onto shape axes to preserve rotation without shear.")
	space.add_theme_stylebox_override("disabled", space.get_theme_stylebox("normal").duplicate())
	snap.settings_changed.connect(func(): snapping_changed.emit(snap.values()))


## Takes an EditorMode (core/modes/editor_mode.gd).
func set_editor_mode(editor_mode) -> void:
	visible = editor_mode.shows("gizmo_toolbar")
	bar.visible = visible
	mode_buttons.visible = visible
	space.visible = visible
	snap.visible = visible
	motion.visible = editor_mode.shows("motion_paths")
	for mode in range(mode_buttons.get_child_count()):
		var button: Button = mode_buttons.get_child(mode)
		button.disabled = not editor_mode.allows_tool(mode)
		button.visible = not button.disabled


func select_tool(mode: int) -> void:
	for index in range(mode_buttons.get_child_count()):
		mode_buttons.get_child(index).set_pressed_no_signal(index == mode)
	space.disabled = mode == 1
	space.tooltip_text = "Size handles follow the block faces" if mode == 1 else "Transform gizmo space · Ctrl: invert snapping · Escape: cancel"
