extends Resource
## Declares what one editor mode shows and allows. Panels and tools ask the
## active mode instead of checking tab indices.

## Matches the mode tab title ("View", "Model", "Texture", "Animation").
@export var id := ""
## Panels visible in this mode. See ModeController.PANELS for the names.
@export var panels: PackedStringArray = []
## Gizmo tools (TransformGizmo.Mode values) available in this mode.
@export var gizmo_tools: PackedInt32Array = []
## Whether clicking the viewport or outliner selects elements.
@export var selectable := false
## Whether a face (rather than a whole element) is the unit of selection.
@export var face_selection := false
## What Ctrl+C / Ctrl+V copy and paste: "", "elements" or "keyframes".
@export var clipboard := ""


static func create(mode_id: String, mode_panels: Array, tools: Array, can_select: bool, faces := false, clipboard_kind := ""):
	var mode = load("res://core/modes/editor_mode.gd").new()
	mode.id = mode_id
	mode.panels = PackedStringArray(mode_panels)
	mode.gizmo_tools = PackedInt32Array(tools)
	mode.selectable = can_select
	mode.face_selection = faces
	mode.clipboard = clipboard_kind
	return mode


func shows(panel: String) -> bool:
	return panels.has(panel)


func allows_tool(tool: int) -> bool:
	return gizmo_tools.has(tool)
