extends RefCounted
## Owns the editor modes and the active one. Replaces scattered checks such
## as `index in [1, 3]`: ask `controller.current.shows("hierarchy")` instead.

signal mode_changed(mode)

const EditorMode = preload("res://core/modes/editor_mode.gd")

## Panel names a mode can declare.
## "hierarchy" is the left dock's Outliner tab and "animation_list" its
## Animations tab.
const PANELS := ["left_dock", "hierarchy", "animation_list", "context_button",
	"texture_sidebar", "gizmo_toolbar", "motion_paths", "model_inspector", "animation_workspace", "ik_panel", "pose_panel", "attachment_panel"]

## TransformGizmo.Mode values.
const MOVE_ROTATE := 0
const SIZE := 1
const SCALE := 2
const PIVOT := 3

var modes: Array = []
var current


func _init() -> void:
	register(EditorMode.create("View", [], [], false))
	register(EditorMode.create("Model", ["left_dock", "hierarchy", "context_button", "gizmo_toolbar", "model_inspector", "attachment_panel"],
		[MOVE_ROTATE, SIZE, SCALE, PIVOT], true, false, "elements"))
	register(EditorMode.create("Texture", ["left_dock", "hierarchy", "texture_sidebar"],
		[], true, true))
	# The dope sheet lists the elements, so Animation has no Outliner tab.
	register(EditorMode.create("Animation", ["left_dock", "animation_list", "ik_panel", "pose_panel", "context_button", "gizmo_toolbar", "motion_paths", "animation_workspace"],
		[MOVE_ROTATE, SCALE], true, false, "keyframes"))
	current = modes[0]


func register(mode) -> void:
	modes.append(mode)


func find(mode_id: String):
	for mode in modes:
		if mode.id == mode_id:
			return mode
	return null


func index_of(mode_id: String) -> int:
	for i in range(modes.size()):
		if modes[i].id == mode_id:
			return i
	return -1


## Switches mode. Returns false for an unknown id or when already active.
func activate(mode_id: String) -> bool:
	var mode = find(mode_id)
	if mode == null or mode == current:
		return false
	current = mode
	mode_changed.emit(mode)
	return true


func is_mode(mode_id: String) -> bool:
	return current != null and current.id == mode_id
