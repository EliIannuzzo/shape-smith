extends Control

enum FileAction { LOAD, ASSET_PATHS, SAVE, SAVE_AS, NEW, EXPORT, EXPORT_UV, REFERENCES, PREFERENCES, IMPORT, IMPORT_MODEL, RECENT = 50 }
enum EditAction { GRID = 0, UNDO = 10, REDO = 11, SELECT_ALL = 12, DELETE = 13, CUT = 14, COPY = 15, PASTE = 16, DUPLICATE = 17, INVERT = 18, RENAME = 19, THEME = 20, GROUP_SELECTION = 21, UNGROUP = 22, LOCK = 23, PALETTE = 30 }
enum AddAction { CUBE, ATTACHMENT_POINT, GROUP, BOUNDS_CUBE, AT_POINTER, CHILD, SIBLING }
enum ViewAction { PERSPECTIVE = 0, ORTHOGRAPHIC = 1, FRAME_ALL = 2, RENDER_MODE = 3, FRAME_SELECTION = 4, ISOLATE = 5, HIDE_OTHERS = 6, SHOW_ALL = 7, LIGHTING = 8, POINT_LABELS = 9 }
enum AnimationAction { NEW, DUPLICATE, DELETE, PLAY, INSERT_KEY, DELETE_KEYS, GRAPH, AUTO_KEY, PASTE_MIRRORED, INSERT_FRAME, DELETE_FRAME, ADD_MARKER }
enum HelpAction { SHORTCUTS, GUIDE, PALETTE, ABOUT }
const CLEAR_RECENT := 999
## Viewport menu item id.
const RESET_LAYOUT := 10
enum ToolAction { SCREENSHOT }

const FILE_DIALOG_SCREEN_RATIO := 0.75
# Apply model edits before the viewport updates its handles.
const TRANSFORM_EDITOR_PRIORITY := -10

static var Palette = preload("res://ui/theme/editor_palette.tres")
const ShapeLoader = preload("res://core/model/shape_loader.gd")
const AssetPaths = preload("res://core/textures/asset_paths.gd")
const WorkingDocument = preload("res://core/model/working_document.gd")
const AnimationBaker = preload("res://core/animation/animation_baker.gd")
const ShapeLimits = preload("res://core/model/shape_limits.gd")
const ShapeDocument = preload("res://core/document/shape_document.gd")
const Selection = preload("res://core/selection.gd")
const ModeController = preload("res://core/modes/mode_controller.gd")
const SceneSync = preload("res://ui/viewport/scene_sync.gd")
const ActionRegistry = preload("res://ui/app/action_registry.gd")
const CommandPalette = preload("res://ui/app/command_palette.gd")
const ToastHost = preload("res://ui/shared/toast_host.gd")
const RecentFiles = preload("res://ui/app/recent_files.gd")
const Autosave = preload("res://ui/app/autosave.gd")
const DockLayout = preload("res://ui/app/dock_layout.gd")
const MenuBuilder = preload("res://ui/app/menu_builder.gd")
const EditorActions = preload("res://ui/app/editor_actions.gd")
const Preferences = preload("res://ui/app/preferences.gd")
const AddElements = preload("res://core/commands/add_elements.gd")
const ViewportOverlay = preload("res://ui/viewport/viewport_overlay.gd")
const WelcomePanel = preload("res://ui/app/welcome_panel.gd")
const ImportShape = preload("res://ui/app/import_shape.gd")
enum LeftTab { OUTLINER, ANIMATIONS, IK, POSES, ATTACHMENTS }
## The mode panel that shows each left tab.
const LEFT_TAB_PANELS := {LeftTab.OUTLINER: "hierarchy", LeftTab.ANIMATIONS: "animation_list", LeftTab.IK: "ik_panel", LeftTab.POSES: "pose_panel", LeftTab.ATTACHMENTS: "attachment_panel"}
enum RightTab { FACE, TEXTURES }
var asset_paths = AssetPaths.new()
## Every command, for the menus and the command palette (Ctrl+Shift+P).
var actions = ActionRegistry.new()
var command_palette
var toasts
var recent_files = RecentFiles.new()
var recent_menu: PopupMenu
var add_menu: PopupMenu
var animation_menu: PopupMenu
var help_menu: PopupMenu
var menu_builder = MenuBuilder.new()
var preferences
var importer
## File → Import Model… (glTF and FBX).
var model_importer
var overlay
var welcome
## Footer: what the pointer is over, and the main keys for this mode.
## View → Isolate Selection: other elements' meshes are hidden (preview only).
var isolated := false
var autosave
## Left dock: Outliner | Animations. Texture sidebar: Face | Textures.
var left_tabs: TabContainer
var ik_tab_box: VBoxContainer
var pose_tab_box: VBoxContainer
var attachments_tab_box: VBoxContainer
var right_tabs: TabContainer
var dock_layout = DockLayout.new()
var _default_left_width := 0
## The open shape as typed records with stable uids. Every element edit goes
## through a command, so the document is the source of truth.
var document = ShapeDocument.from_data({"elements": []})
var selection = Selection.new()
var modes = ModeController.new()
## Applies document signals (from commands) to the viewport's nodes.
var scene_sync = SceneSync.new()
var _timeline_dirty := false
var _timeline_recompile := false
@onready var asset_paths_dialog = $AssetPaths
@onready var history = $EditHistory
@onready var edit_menu: PopupMenu = $Layout/MenuPanel/Menus/Edit

var current_mode := "View"
var loading := false
var current_path := ""
var document_is_working := false
var animation_export
var transform_editor
var gizmo_space: OptionButton
var snap_settings
var motion_path
var model_inspector
var hierarchy_editor
var hierarchy_actions
var selecting_element := false
var gizmo_modes: HBoxContainer
var gizmo_bar: PanelContainer
var gizmo_toolbar
var context_models
var context_panel
var context_button: Button
var guide_window: Window
var unsaved_prompt: ConfirmationDialog
var pending_document_action: Callable
var attachment_points
## Two-bone IK chains and their controllers (Animation sidebar).
var ik
const IkRigs = preload("res://ui/animation/ik_rigs.gd")
## Pose library, mirror, reset, copy and breakdown (Animation sidebar).
var pose_tools
var extra_properties
var theme_editor
var screenshot_tool

@onready var mode_tabs: TabBar = $Layout/ModePanel/Margin/Row/ModeTabs
@onready var workspace = $Layout/Workspace
@onready var viewport = $Layout/Workspace/Content/RightSplit/Viewport
@onready var hierarchy = $Layout/Workspace/Content/LeftDock/Hierarchy
@onready var texturing = $Layout/Workspace/Content/RightSplit/TextureSidebar/Margin/Texturing
@onready var texture_manager = $TextureManager
@onready var grid_settings: ConfirmationDialog = $GridSettings
@onready var grid_width: SpinBox = $GridSettings/Fields/Dimensions/Width
@onready var grid_depth: SpinBox = $GridSettings/Fields/Dimensions/Depth
@onready var file_menu: PopupMenu = $Layout/MenuPanel/Menus/File
@onready var grid_menu: PopupMenu = $Layout/MenuPanel/Menus/Edit/Grid
@onready var camera_menu: PopupMenu = $Layout/MenuPanel/Menus/Viewport
@onready var rendering_menu: PopupMenu = $Layout/MenuPanel/Menus/Viewport/Rendering
@onready var file_picker: FileDialog = $FilePicker
@onready var save_picker: FileDialog = $SavePicker
@onready var error_dialog: AcceptDialog = $ErrorDialog
@onready var status: Label = $Layout/Footer/Margin/Row/Status
@onready var grid_status: Label = $Layout/Footer/Margin/Row/Stage


func _enter_tree() -> void:
	preload("res://ui/theme/theme_settings.gd").new().load_saved()
	Palette.apply_to(theme)
	$Background.color = Palette.workspace
	gizmo_toolbar = $Layout/ModePanel/Margin/Row/GizmoToolbar
	gizmo_toolbar.bind_workspace($Layout/Workspace)


func _ready() -> void:
	_setup_docks()
	_setup_tool_windows()
	_setup_document_prompts()

	_setup_gizmo_toolbar()
	_setup_model_inspector()
	_setup_context_models()
	_setup_attachment_editor()

	_setup_edit_menu()
	_setup_asset_paths()
	_setup_file_menu()
	_setup_viewport_controls()

	_setup_shape_editors()
	_setup_texture_manager()
	_connect_editor_events()
	_setup_extra_properties()
	_setup_scene_sync()
	_setup_shell()

	call_deferred("_apply_editor_icons")
	_on_mode_changed(mode_tabs.current_tab)
	_sync_history()
	_offer_recovery.call_deferred()


func _setup_tool_windows() -> void:
	screenshot_tool = $ScreenshotTool
	screenshot_tool.bind_window(get_window(), theme)
	screenshot_tool.bind_scene(viewport, workspace)
	$Layout/MenuPanel/Menus/Tools.id_pressed.connect(_on_tools_menu_selected)
	MenuBuilder.set_icon($Layout/MenuPanel/Menus/Tools, 0, "tools.screenshot")

	theme_editor = $ThemeEditor
	theme_editor.bind_window(get_window(), theme)
	theme_editor.palette_preview_requested.connect(apply_palette)

	animation_export = $AnimationExport
	animation_export.bind_window(get_window(), theme)
	animation_export.settings_changed.connect(_on_export_settings_changed)
	animation_export.export_requested.connect(export_for_game)


func _setup_document_prompts() -> void:
	get_tree().auto_accept_quit = false
	get_window().close_requested.connect(_request_close)

	unsaved_prompt = $UnsavedPrompt
	unsaved_prompt.add_button("Discard", false, "discard")
	unsaved_prompt.confirmed.connect(_save_before_continue)
	unsaved_prompt.custom_action.connect(_on_unsaved_action)
	unsaved_prompt.canceled.connect(_cancel_document_action)


func _setup_gizmo_toolbar() -> void:
	gizmo_modes = gizmo_toolbar.mode_buttons
	gizmo_bar = gizmo_toolbar.bar
	gizmo_space = gizmo_toolbar.space
	snap_settings = gizmo_toolbar.snap
	motion_path = gizmo_toolbar.motion

	gizmo_toolbar.tool_selected.connect(_set_gizmo_mode)
	viewport.gizmo_mode_requested.connect(_set_gizmo_mode)
	gizmo_toolbar.space_selected.connect(_on_gizmo_space_selected)
	gizmo_toolbar.snapping_changed.connect(_on_snapping_changed)


func _setup_model_inspector() -> void:
	transform_editor = preload("res://ui/viewport/gizmos/transform_editor.gd").new()
	transform_editor.bind_services(viewport, workspace, history, texturing)
	transform_editor.selected_nodes = _selected_nodes
	transform_editor.process_priority = TRANSFORM_EDITOR_PRIORITY
	add_child(transform_editor)

	model_inspector = $Layout/Workspace/Content/RightSplit/ModelInspector
	model_inspector.bind(transform_editor)
	viewport.selection_changed.connect(model_inspector.inspect)
	viewport.selection_changing.connect(model_inspector.finish_pending)
	viewport.gizmo.drag_finished.connect(_refresh_model_inspector)
	history.flush_pending.connect(model_inspector.finish_pending)


func _setup_context_models() -> void:
	context_models = preload("res://ui/context/context_models.gd").new()
	context_models.bind(viewport, asset_paths, history, _document_path)
	add_child(context_models)
	workspace.context_models = context_models
	ik = IkRigs.new()
	ik.name = "IkRigs"
	add_child(ik)
	ik.bind(self)
	workspace.ik = ik
	ik.build_panel(ik_tab_box)
	pose_tools = preload("res://ui/animation/pose_tools.gd").new()
	pose_tools.name = "PoseTools"
	add_child(pose_tools)
	pose_tools.bind(self)
	pose_tools.build_panel(pose_tab_box)

	context_panel = preload("res://ui/context/context_models_panel.tscn").instantiate()
	context_panel.bind_services(viewport, model_inspector, history)
	context_panel.bind_document_actions(_document_path, save_shape, _load_shape, _save_then_continue)
	context_panel.system = context_models
	context_panel.main_clip = func() -> String:
		var clips: Array = workspace.animation.clips
		return str(clips[workspace.selected].code) if workspace.selected >= 0 and workspace.selected < clips.size() else ""
	context_panel.set_editor_theme(theme)
	add_child(context_panel)

	context_button = $Layout/Workspace/Content/LeftDock/ContextBar/ContextButton
	context_button.icon = preload("res://ui/shared/editor_icons.gd").icon("layers")
	context_button.add_theme_constant_override("icon_max_width", 18)
	context_button.pressed.connect(context_panel.open)


func _setup_attachment_editor() -> void:
	attachment_points = preload("res://ui/model/attachment_points.gd").new()
	attachment_points.bind(viewport, model_inspector, texturing, transform_editor, history)
	attachment_points.panel_parent = attachments_tab_box
	add_child(attachment_points)
	attachment_points.element_requested.connect(func(node: Node3D): _select_element(node))
	transform_editor.bind_editors(model_inspector, context_models, attachment_points)
	history.flush_pending.connect(func(): viewport.gizmo.finish())


## The Edit menu is built from actions in _build_menus().
func _setup_edit_menu() -> void:
	pass


func _setup_asset_paths() -> void:
	asset_paths.load_config()
	asset_paths.history = history
	asset_paths_dialog.settings = asset_paths
	asset_paths.changed.connect(_sync_asset_paths_dialog)
	viewport.texture_library.set_asset_paths(asset_paths)


## File → Open Recent is filled from RecentFiles; the File menu itself is
## built from actions in _build_menus().
func _setup_file_menu() -> void:
	recent_menu = PopupMenu.new()
	recent_menu.name = "OpenRecent"
	file_menu.add_child(recent_menu)
	save_picker.file_selected.connect(_on_save_path_selected)
	save_picker.canceled.connect(_cancel_document_action)
	file_picker.file_selected.connect(request_load_shape)
	recent_menu.id_pressed.connect(_on_recent_selected)
	recent_files.changed.connect(_rebuild_recent_menu)
	recent_files.load_config()


func _setup_viewport_controls() -> void:
	grid_menu.id_pressed.connect(_on_grid_selected)
	rendering_menu.id_pressed.connect(_on_rendering_selected)
	mode_tabs.tab_changed.connect(_on_mode_changed)

	grid_settings.confirmed.connect(_apply_grid_dimensions)
	grid_settings.about_to_popup.connect(_sync_grid_dimensions)
	_update_grid_status()


func _setup_shape_editors() -> void:
	texturing.bind_library(viewport.texture_library)
	texturing.model_root = viewport.models
	texturing.bind_history(history)

	hierarchy.history = history
	hierarchy_editor = preload("res://ui/hierarchy/hierarchy_editor.gd").new()
	hierarchy_editor.bind(viewport, history, hierarchy, workspace, transform_editor)
	hierarchy_editor.new_document_requested.connect(_new_shape)
	hierarchy_editor.element_selection_requested.connect(_select_element)
	hierarchy_editor.status_message.connect(func(message: String):
		status.text = message
		notify(message))
	add_child(hierarchy_editor)

	hierarchy.add_requested.connect(hierarchy_editor.add_shape)
	hierarchy.reparent_requested.connect(func(node: Node3D, target: Node3D): hierarchy_editor.reparent_shape(node, target))
	hierarchy.move_requested.connect(hierarchy_editor.move_relative)
	texturing.texture_assigned.connect(func(id: String): hierarchy_editor.last_texture = id)
	texturing.face_picked.connect(func(node: Node3D, face: String): _select_element(node, face))
	texturing.texture_message.connect(func(text: String): notify(text, "error"))
	texturing.unwrap_targets = _selected_nodes

	hierarchy_actions = preload("res://ui/hierarchy/hierarchy_actions.tscn").instantiate()
	hierarchy_actions.bind(viewport, hierarchy, hierarchy_editor, history, transform_editor, workspace, theme)
	hierarchy_actions.message.connect(func(text: String, kind: String): notify(text, kind))
	hierarchy_actions.selection_nodes = _selected_nodes
	add_child(hierarchy_actions)

	workspace.history = history
	history.flush_pending.connect(workspace.finish_pending)


func _setup_texture_manager() -> void:
	viewport.texture_library.history = history
	texture_manager.bind_library(viewport.texture_library)
	texture_manager.asset_paths_requested.connect(func(): configure_asset_paths(true))
	texture_manager.open_requested.connect(func():
		if not modes.is_mode("Texture"):
			mode_tabs.current_tab = modes.index_of("Texture"))
	viewport.texture_library.changed.connect(_sync_texture_manager_button)


func _connect_editor_events() -> void:
	hierarchy.element_selected.connect(_select_element)
	hierarchy.point_selected.connect(func(_node: Node3D, index: int): attachment_points.select_point(index))
	attachment_points.point_selected.connect(func(index: int):
		hierarchy.selected_point = index
		hierarchy.select_element(hierarchy.selected_node))
	hierarchy.element_toggled.connect(_toggle_element)
	hierarchy.element_range_requested.connect(_select_range)
	viewport.element_toggle_picked.connect(_toggle_element)
	selection.changed.connect(_sync_multi_selection)
	workspace.element_selected.connect(_select_element)
	hierarchy.element_collapsed.connect(workspace.tracks.set_collapsed)
	workspace.tracks.element_collapsed.connect(hierarchy.set_collapsed)
	viewport.element_picked.connect(_select_viewport_element)

	texturing.face_selected.connect(func(node: Node3D, face: String): viewport.select_element(node, face))
	texturing.face_edited.connect(_on_face_edited)
	viewport.texture_library.edited.connect(_on_texture_edited)

	history.changed.connect(_sync_history)
	history.changed.connect(_sync_document)
	history.failed.connect(_on_history_failed)


func _setup_scene_sync() -> void:
	scene_sync.transform_changed.connect(_on_scene_transform_changed)
	scene_sync.node_attached.connect(func(node: Node3D):
		hierarchy.add_rows(node)
		_queue_timeline(true))
	scene_sync.node_moved.connect(func(node: Node3D):
		hierarchy.move_rows(node)
		_queue_timeline(false))
	scene_sync.node_detached.connect(_on_scene_node_detached)
	scene_sync.element_updated.connect(_on_scene_element_updated)


func _exit_tree() -> void:
	dock_layout.remember(modes.current.id)
	scene_sync.unbind()
	# A clean exit leaves no autosave behind; one left at launch means a crash.
	if autosave != null:
		autosave.discard_session()


func _setup_extra_properties() -> void:
	extra_properties = preload("res://ui/model/extra_shape_properties.gd").new()
	extra_properties.bind(viewport, texturing, model_inspector, history)
	add_child(extra_properties)


func _on_tools_menu_selected(id: int) -> void:
	if id == ToolAction.SCREENSHOT:
		screenshot_tool.open(current_path)


func open_shape_picker() -> void:
	if not file_picker.visible:
		file_picker.popup_centered_ratio(FILE_DIALOG_SCREEN_RATIO)


func _on_save_path_selected(path: String) -> void:
	if save_shape(path):
		_continue_document_action()
	else:
		_cancel_document_action()


func _on_unsaved_action(action: StringName) -> void:
	if action == &"discard":
		unsaved_prompt.hide()
		_continue_document_action()


func _on_gizmo_space_selected(local_space: bool) -> void:
	viewport.gizmo.finish(true)
	viewport.gizmo.local_space = local_space


func _on_snapping_changed(settings: Dictionary) -> void:
	viewport.gizmo.snap_enabled = settings.enabled
	viewport.gizmo.translation_step = settings.translation
	viewport.gizmo.rotation_step = settings.rotation
	viewport.gizmo.scale_step = settings.scale


func _refresh_model_inspector(_cancelled: bool) -> void:
	model_inspector.call_deferred("inspect", viewport.selected_node)


func _document_path() -> String:
	return current_path


func _sync_asset_paths_dialog() -> void:
	if asset_paths_dialog.visible:
		asset_paths_dialog.sync_from_settings()


func _sync_grid_dimensions() -> void:
	grid_width.value = viewport.grid_dimensions.x
	grid_depth.value = viewport.grid_dimensions.y


func _sync_texture_manager_button() -> void:
	right_tabs.set_tab_disabled(RightTab.TEXTURES, viewport.texture_library.data.is_empty())


func _on_face_edited(node: Node3D, face: String) -> void:
	_select_element(node, face)
	_mark_edited()


func _on_texture_edited() -> void:
	if not loading and not viewport.shape_data.is_empty():
		_mark_edited()


func _on_history_failed(action: String) -> void:
	status.text = "Could not replay %s" % action
	notify("Could not apply %s." % action, "error")


func configure_asset_paths(_from_manager := false) -> void:
	asset_paths_dialog.open()


func _on_mode_changed(index: int) -> void:
	dock_layout.remember(modes.current.id)
	modes.activate(mode_tabs.get_tab_title(index))
	var mode = modes.current
	attachment_points.gizmo.finish(true)
	# The button sits in a bar with a gap around it, so it reads as a button.
	context_button.get_parent().visible = mode.shows("context_button")
	gizmo_toolbar.set_editor_mode(mode)
	if mode.shows("gizmo_toolbar") and not mode.allows_tool(viewport.gizmo.mode):
		viewport.gizmo.set_mode(ModeController.MOVE_ROTATE)
		gizmo_toolbar.select_tool(ModeController.MOVE_ROTATE)
	viewport.gizmo.finish(true)
	model_inspector.finish_pending()
	texturing.finish_pending()
	workspace.finish_pending()
	current_mode = mode.id
	transform_editor.editor_mode = current_mode
	hierarchy_actions.editor_mode = current_mode
	attachment_points.editor_mode = current_mode
	model_inspector.set_model_mode(mode.shows("model_inspector"))
	workspace.set_animation_mode(mode.shows("animation_workspace"))
	model_inspector.inspect(viewport.selected_node)
	$Layout/Workspace/Content/LeftDock.visible = mode.shows("left_dock")
	# View mode hides the whole dock; hiding every tab would leave none selected.
	if mode.shows("left_dock"):
		# A hidden tab cannot be selected: show all, pick, then hide.
		for tab in LEFT_TAB_PANELS:
			left_tabs.set_tab_hidden(tab, false)
		left_tabs.current_tab = LeftTab.ANIMATIONS if mode.shows("animation_list") else LeftTab.OUTLINER
		for tab in LEFT_TAB_PANELS:
			left_tabs.set_tab_hidden(tab, not mode.shows(LEFT_TAB_PANELS[tab]))
	$Layout/Workspace/Content/RightSplit/TextureSidebar.visible = mode.shows("texture_sidebar")
	dock_layout.restore(mode.id)
	viewport.selection_enabled = mode.selectable
	if is_instance_valid(viewport.selection_outline):
		viewport.selection_outline.visible = mode.selectable


func apply_palette(values: Dictionary) -> void:
	var settings = preload("res://ui/theme/theme_settings.gd")
	var before: Dictionary = settings.colors()
	for key in values:
		if before.has(key):
			Palette.set(key, Color(values[key]))
	settings.refresh_tree(self, before)
	# Build off-tree to avoid a notification cascade while changing each style.
	var next_theme := theme.duplicate(true) as Theme
	Palette.apply_to(next_theme)
	theme = next_theme
	theme_editor.theme = next_theme
	screenshot_tool.theme = next_theme
	animation_export.theme = next_theme
	hierarchy_actions.set_editor_theme(next_theme)
	context_panel.set_editor_theme(next_theme)
	hierarchy.refresh_palette()
	workspace.animation_list.show_rename(workspace.selected)
	$Background.color = Palette.workspace
	viewport.refresh_palette()
	motion_path.signature.clear()
	Palette.emit_changed()


func _load_shape(path: String) -> void:
	var result: Dictionary = ShapeLoader.new().load_file(path)
	if not result.error.is_empty():
		notify("Could not open %s. %s" % [path.get_file(), result.error], "error")
		return

	# Root origins and older reference lists, before the document is built.
	var context_changed: bool = context_models.prepare(result.data, path)
	loading = true
	document_is_working = WorkingDocument.is_working(result.data)
	model_inspector.inspect(null)
	texturing.finish_pending()
	workspace.finish_pending()
	history.clear()
	texturing.select_element(null)
	context_models.clear_main_corrections()
	viewport.show_shape(result)
	_open_document(result.data, result.root)
	workspace.bind_shape()
	hierarchy.bind_shape(result.root)
	loading = false
	current_path = path
	context_models.source_path = path
	context_models.rebuild()
	if not context_models.loaded.is_empty():
		context_models.frame_all()
	for id in [FileAction.SAVE, FileAction.SAVE_AS, FileAction.EXPORT]:
		file_menu.set_item_disabled(file_menu.get_item_index(id), false)
	status.text = "%s  ·  %d elements / %d faces" % [path.get_file(), result.elements, result.faces]
	autosave.discard_session()
	if not path.begins_with(autosave.directory):
		recent_files.add(path)
	if context_changed:
		history.mark_unsaved()
	for note in result.get("notes", []):
		notify(note, "warning")
	for id in viewport.texture_library.ids():
		var mismatch: String = viewport.texture_library.layout_warning(id)
		if not mismatch.is_empty():
			notify(mismatch, "warning")
	_update_title()


func request_load_shape(path: String) -> void:
	_request_document_action(_load_shape.bind(path))


func request_new_shape() -> void:
	_request_document_action(_new_shape)


func _request_close() -> void:
	_request_document_action(_quit_application)


func _quit_application() -> void:
	get_tree().quit()


func _request_document_action(action: Callable) -> void:
	if pending_document_action.is_valid():
		return

	history.flush_pending.emit()
	pending_document_action = action
	if history.is_dirty():
		unsaved_prompt.dialog_text = "Save changes to %s before continuing?" % ("Untitled" if current_path.is_empty() else current_path.get_file())
		unsaved_prompt.popup_centered()
	else:
		_continue_document_action()


func _cancel_document_action() -> void:
	pending_document_action = Callable()


func _continue_document_action() -> void:
	var action := pending_document_action
	pending_document_action = Callable()
	if action.is_valid():
		action.call()


func _save_before_continue() -> void:
	if current_path.is_empty() or not document_is_working:
		save_as()
	elif save_shape():
		_continue_document_action()
	else:
		_cancel_document_action()


func _save_then_continue(action: Callable) -> void:
	if pending_document_action.is_valid():
		return
	pending_document_action = action
	_save_before_continue()


func _new_shape() -> void:
	history.flush_pending.emit()
	loading = true
	document_is_working = false
	model_inspector.inspect(null)
	texturing.select_element(null)
	history.clear()
	context_models.clear_main_corrections()
	var shape := Node3D.new()
	shape.name = "Shape"
	var data := {"elements": [], "textures": {}, "textureWidth": 16, "textureHeight": 16}
	viewport.show_shape({"root": shape, "data": data, "bounds": AABB(Vector3.ZERO, Vector3.ONE), "path": ""})
	_open_document(data, shape)
	workspace.bind_shape()
	hierarchy.bind_shape(shape)
	current_path = ""
	context_models.source_path = ""
	context_models.rebuild()
	loading = false
	for id in [FileAction.SAVE, FileAction.SAVE_AS, FileAction.EXPORT]:
		file_menu.set_item_disabled(file_menu.get_item_index(id), false)
	status.text = "Untitled shape"
	autosave.discard_session()
	_update_title()
	mode_tabs.current_tab = 1


func _open_document(data: Dictionary, root: Node3D) -> void:
	document = ShapeDocument.from_data(data)
	document.animations_changed.connect(_queue_timeline.bind(true))
	scene_sync.bind(document, root, viewport.texture_library, _rest_transform)
	hierarchy_editor.bind_document(document, scene_sync, selection)
	hierarchy_actions.bind_document(document, scene_sync, selection)
	transform_editor.bind_document(document)
	extra_properties.bind_document(document)
	attachment_points.bind_document(document)
	for point_signal in [document.point_added, document.point_removed, document.point_changed]:
		point_signal.connect(func(_a = null, _b = null): hierarchy.refresh_points.call_deferred())
	texturing.bind_document(document)
	context_models.bind_document(document)
	selection.clear()


func _rest_transform(source: Dictionary) -> Transform3D:
	return workspace.animation.element_transform(source, Vector3.ZERO, Vector3.ZERO, Vector3.ONE, 0)


## After each history step: drop removed elements from the selection, and
## finish the timeline update that step queued.
func _sync_document() -> void:
	selection.prune(document.has)
	_flush_timeline()


## A command moved an element: refresh what depends on its rest pose.
func _on_scene_transform_changed(node: Node3D) -> void:
	context_models.clear_main_corrections()
	for entries in workspace.animation.elements.values():
		for entry in entries:
			if entry.node == node:
				entry.rest = node.transform


## Any command edit to an element: refresh bounds, the selection outline and
## the inspectors that show it.
func _on_scene_element_updated(node: Node3D, fields: Array) -> void:
	if fields.has("name"):
		hierarchy.rename_row(node)
		_queue_timeline(true)
	if fields.any(func(field): return field not in SceneSync.NON_GEOMETRY_FIELDS):
		viewport.update_model_bounds()
	if viewport.selected_node == node:
		viewport.select_element(node, texturing.current_face if modes.current.face_selection else "")
		if fields.has("faces"):
			texturing.refresh()
	# Reselecting clears step-parent corrections; place references last.
	context_models.sync()


func _on_scene_node_detached(node: Node3D) -> void:
	var selected: Node3D = viewport.selected_node
	if is_instance_valid(selected) and (selected == node or node.is_ancestor_of(selected)):
		_select_element(null)
	hierarchy.remove_rows(node)
	_queue_timeline(true)


## The timeline and animation playback re-read the element tree once per
## history step that added, removed, moved or renamed elements, or changed
## tracks. Recompiling clips is needed only when names or tracks changed.
func _queue_timeline(recompile: bool) -> void:
	_timeline_recompile = _timeline_recompile or recompile
	if not _timeline_dirty:
		_timeline_dirty = true
		_flush_timeline.call_deferred()


func _flush_timeline() -> void:
	if not _timeline_dirty:
		return
	var recompile := _timeline_recompile
	_timeline_dirty = false
	_timeline_recompile = false
	workspace.sync_structure(recompile)
	viewport.update_model_bounds()
	var selected: Node3D = viewport.selected_node
	_select_element(selected if is_instance_valid(selected) and selected.is_inside_tree() else null)


func _select_viewport_element(node: Node3D, face := "") -> void:
	_select_element(node, face)
	if node != null:
		hierarchy.reveal_element(node)
		workspace.tracks.select_element(node)


## Ctrl+click: add or remove an element; the last one added is active.
func _toggle_element(node: Node3D) -> void:
	var uid := ShapeDocument.uid_of(node)
	if not modes.current.selectable or not document.has(uid):
		return
	selection.toggle(uid)
	_select_element(scene_sync.node_for(selection.active), "", true)


## Shift+click in the outliner: select from the active element to this one.
func _select_range(node: Node3D) -> void:
	var uid := ShapeDocument.uid_of(node)
	if not modes.current.selectable or not document.has(uid):
		return
	selection.select_range(document.ordered(), uid)
	_select_element(node, "", true)


func select_all_elements() -> void:
	if not modes.current.selectable or document.elements.is_empty():
		return
	selection.select_all(document.ordered())
	_select_element(scene_sync.node_for(selection.active), "", true)


func _sync_multi_selection() -> void:
	var nodes: Array = []
	for uid in selection.items:
		var node: Node3D = scene_sync.node_for(uid)
		if node != null:
			nodes.append(node)
	hierarchy.set_multi_selection(nodes)
	viewport.set_secondary_selection(nodes if modes.current.selectable else [])
	model_inspector.set_selection(nodes)


## Selects one element as the active one. Unless keep_selection, the
## multi-selection is replaced by just this element.
func _select_element(node: Node3D, face := "", keep_selection := false) -> void:
	if selecting_element:
		return

	selecting_element = true
	# Finish the previous element's edits before changing any selection. Their
	# notifications must not restore an old element halfway through this update.
	if viewport.selected_node != node:
		texturing.finish_pending()
		model_inspector.finish_pending()
		workspace.finish_pending()
	if not keep_selection:
		selection.select(ShapeDocument.uid_of(node))
	hierarchy.select_element(node)
	workspace.tracks.select_element(node)
	texturing.select_element(node, face)
	viewport.select_element(node, texturing.current_face if modes.current.face_selection else "")
	if is_instance_valid(viewport.selection_outline):
		viewport.selection_outline.visible = modes.current.selectable
	selecting_element = false
	_sync_multi_selection()


func _set_gizmo_mode(value: int) -> void:
	if not modes.current.allows_tool(value):
		return

	if value != 0:
		attachment_points.select_point(-1)
	viewport.gizmo.set_mode(value)
	gizmo_toolbar.select_tool(value)


func _apply_editor_icons() -> void:
	preload("res://ui/shared/editor_icons.gd").apply_buttons(self)


func _mark_edited() -> void:
	_sync_history()


func _sync_history() -> void:
	var undo_name: String = history.undo_name()
	var redo_name: String = history.redo_name()
	var undo_index := edit_menu.get_item_index(EditAction.UNDO)
	var redo_index := edit_menu.get_item_index(EditAction.REDO)
	edit_menu.set_item_text(undo_index, "Undo " + undo_name if not undo_name.is_empty() else "Undo")
	edit_menu.set_item_text(redo_index, "Redo " + redo_name if not redo_name.is_empty() else "Redo")
	edit_menu.set_item_disabled(undo_index, undo_name.is_empty())
	edit_menu.set_item_disabled(redo_index, redo_name.is_empty())
	status.text = status.text.trim_suffix(" · Edits in memory")
	if history.is_dirty():
		status.text += " · Edits in memory"
	_update_title()


## Keyboard shortcuts come from the action registry (rebindable in
## Preferences). Menu items with shortcuts are activated by the menu bar first;
## this handles every other action. Ctrl+Y stays an extra Redo.
func _shortcut_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var id: String = actions.match_event(event)
	if id.is_empty():
		history.handle_shortcut(event, get_viewport())
		return
	if actions.shortcut_allowed(id, get_viewport().gui_get_focus_owner()) and actions.trigger(id):
		get_viewport().set_input_as_handled()


func save_as() -> void:
	if viewport.models.get_child_count() == 0:
		return

	texturing.finish_pending()
	var base := current_path.get_file().get_basename().trim_suffix(".shapesmith")
	if not current_path.is_empty():
		save_picker.current_dir = ProjectSettings.globalize_path(current_path).get_base_dir()
	save_picker.current_file = ("Untitled" if base.is_empty() else base) + WorkingDocument.SUFFIX
	save_picker.popup_centered_ratio(FILE_DIALOG_SCREEN_RATIO)


func save_shape(path := "") -> bool:
	if viewport.models.get_child_count() == 0:
		return false

	if path.is_empty() and (current_path.is_empty() or not document_is_working):
		save_as()
		return false

	texturing.finish_pending()
	history.flush_pending.emit()
	var destination: String = current_path if path.is_empty() else path
	if destination.get_extension().is_empty():
		destination += WorkingDocument.SUFFIX
	var base: Dictionary = viewport.texture_library.data_for_save(destination)
	var controller_list: Array = IkRigs.split_controllers(base)
	var output: Dictionary = context_models.data_for_save(base, destination)
	if not _validate_texture_output(output):
		return false
	var working := WorkingDocument.build(output)
	if not working.error.is_empty():
		_show_file_error("Could not save working file", working.error)
		return false
	# The game side: IK chains become rotation keys; controllers stay editor-only.
	ik.finish_game_animations(working.data, controller_list)
	if not controller_list.is_empty():
		working.data.shapesmith.controllers = controller_list
	if not _write_document(destination, working.data):
		return false

	current_path = destination
	document_is_working = true
	history.mark_saved()
	status.text = "%s · Saved working file" % current_path.get_file()
	autosave.discard_session()
	recent_files.add(current_path)
	_update_title()
	return true


func _validate_texture_output(output: Dictionary) -> bool:
	for id in output.get("textures", {}):
		if not output.textures[id] is String:
			notify("Could not save: texture '%s' uses a composite definition. Vintage Story shape files require texture-path strings. Export the composite to a PNG and link that image, or put the composite in the block or item textures. Your edits have been kept." % id, "error")
			return false
	return true


func _show_file_error(title: String, message: String) -> void:
	notify("%s. %s" % [title, message], "error")


func _write_document(destination: String, output: Dictionary) -> bool:
	var json := preload("res://core/model/shape_serializer.gd").stringify(output)
	if json.to_utf8_buffer().size() > ShapeLimits.MAX_FILE_BYTES:
		_show_file_error("Could not save document", "The generated JSON exceeds the 32 MB import limit. Increase the bake interval or reduce the number of in-between frames.")
		return false
	# Replace the destination only after the complete JSON has reached disk.
	# Preview transforms, visibility, and playback settings never enter the JSON.
	autosave.back_up(destination)
	var temporary := destination + ".%d.tmp" % Time.get_ticks_usec()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	var error := FileAccess.get_open_error()
	if file != null:
		file.store_string(json)
		file.flush()
		error = file.get_error()
		file.close()
		if error == OK:
			error = DirAccess.rename_absolute(temporary, destination)
	if error != OK:
		if FileAccess.file_exists(temporary):
			DirAccess.remove_absolute(temporary)
		notify("Could not save %s. %s" % [destination, error_string(error)], "error")
		return false

	return true


func open_animation_export() -> void:
	if viewport.models.get_child_count() == 0:
		return
	history.flush_pending.emit()
	animation_export.open(current_path, AnimationBaker.settings(viewport.shape_data))
	_update_export_summary()


func _on_export_settings_changed(options: Dictionary) -> void:
	var before: Variant = viewport.shape_data.get("shapesmith")
	before = before.duplicate(true) if before is Dictionary else before
	var after: Dictionary = before.duplicate(true) if before is Dictionary else {}
	after.format = WorkingDocument.FORMAT
	after.version = WorkingDocument.VERSION
	after.exportSettings = AnimationBaker.validated_settings(options)
	if before == after:
		return
	history.perform("Change Animation Export Settings", _apply_export_settings.bind(after), _apply_export_settings.bind(before), "animation-export-settings")


func _apply_export_settings(marker: Variant) -> void:
	if marker is Dictionary:
		viewport.shape_data.shapesmith = marker.duplicate(true)
	else:
		viewport.shape_data.erase("shapesmith")
	workspace.refresh_preview()
	motion_path.invalidate()
	_update_export_summary()


func _update_export_summary() -> void:
	if not animation_export.visible:
		return
	var result := AnimationBaker.bake_shape(viewport.shape_data, AnimationBaker.settings(viewport.shape_data))
	animation_export.show_summary(result.get("added", 0), result.get("removed", 0), result.error, result.get("support", 0))


func export_for_game(path: String) -> bool:
	if viewport.models.get_child_count() == 0:
		return false
	history.flush_pending.emit()
	var destination := path if path.get_extension() != "" else path + ".json"
	if destination.ends_with(WorkingDocument.SUFFIX):
		_show_file_error("Choose a game export filename", "Use a separate .json file for game exports. Working files use .shapesmith.json.")
		return false
	if document_is_working and ProjectSettings.globalize_path(destination) == ProjectSettings.globalize_path(current_path):
		_show_file_error("Choose a separate export file", "The game export must not replace your working file.")
		return false
	var base: Dictionary = viewport.texture_library.data_for_save(destination)
	var controller_list: Array = IkRigs.split_controllers(base)
	var source: Dictionary = context_models.data_for_save(base, destination)
	if not _validate_texture_output(source):
		return false
	var exported := WorkingDocument.export_game(source, AnimationBaker.settings(viewport.shape_data))
	if not exported.error.is_empty():
		_show_file_error("Could not export animation", exported.error)
		return false
	var ik_keys: int = ik.finish_game_animations(exported.data, controller_list)
	if ik_keys > 0:
		notify("IK chains were baked into %d rotation keys." % ik_keys)
	if not _write_document(destination, exported.data):
		return false
	status.text = "%s · Exported for Vintage Story" % destination.get_file()
	animation_export.hide()
	return true


func _on_grid_selected(id: int) -> void:
	if id == 4:
		grid_settings.popup_centered()
		return

	var before := _grid_state()
	var after := before.duplicate()
	if id == 5:
		after.axes = not before.axes
	elif id == 0:
		after.visible = not before.visible
	else:
		after.spacing = {1: 1.0, 2: 0.5, 3: 0.0625}[id]
	if before != after:
		history.perform("Change Grid", _apply_grid_state.bind(after), _apply_grid_state.bind(before), "", false)


func _update_grid_status() -> void:
	if not viewport.grid.visible:
		grid_status.text = "Grid hidden"
	else:
		grid_status.text = "Grid: %d × %d · %s block" % [viewport.grid_dimensions.x, viewport.grid_dimensions.y, str(viewport.grid_spacing)]


func _apply_grid_dimensions() -> void:
	grid_width.apply()
	grid_depth.apply()
	var before := _grid_state()
	var after := before.duplicate()
	after.dimensions = Vector2i(clampi(int(grid_width.value), 1, 255) | 1, clampi(int(grid_depth.value), 1, 255) | 1)
	if after != before:
		history.perform("Change Grid Dimensions", _apply_grid_state.bind(after), _apply_grid_state.bind(before), "", false)


func _on_camera_selected(id: int) -> void:
	if id == 2:
		viewport.frame_shape()
		return

	if id == RESET_LAYOUT:
		reset_layout()
		return

	var before: bool = viewport.camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	if before != (id == 1):
		history.perform("Change Camera Projection", _apply_projection.bind(id == 1), _apply_projection.bind(before), "", false)


func _apply_projection(orthographic: bool) -> void:
	viewport.set_projection(orthographic)
	camera_menu.set_item_checked(0, not orthographic)
	camera_menu.set_item_checked(1, orthographic)


func _on_rendering_selected(mode: int) -> void:
	var before: int = viewport.texture_library.render_mode
	if before != mode:
		history.perform("Change Viewport Rendering", _apply_rendering.bind(mode), _apply_rendering.bind(before), "", false)


func _apply_rendering(mode: int) -> void:
	viewport.set_render_mode(mode)
	if overlay != null:
		overlay.set_render_mode(mode)
	for index in range(3):
		rendering_menu.set_item_checked(index, index == mode)


func _grid_state() -> Dictionary:
	return {"visible": viewport.grid.visible, "axes": viewport.axes.visible,
		"spacing": viewport.grid_spacing, "dimensions": viewport.grid_dimensions}


func _apply_grid_state(state: Dictionary) -> void:
	viewport.grid.visible = state.visible
	viewport.axes.visible = state.axes
	if viewport.grid_spacing != state.spacing:
		viewport.set_grid_spacing(state.spacing)
	if viewport.grid_dimensions != state.dimensions:
		viewport.set_grid_dimensions(state.dimensions)
	grid_menu.set_item_checked(grid_menu.get_item_index(0), state.visible)
	grid_menu.set_item_checked(grid_menu.get_item_index(5), state.axes)
	for id in [1, 2, 3]:
		grid_menu.set_item_checked(grid_menu.get_item_index(id), {1: 1.0, 2: 0.5, 3: 0.0625}[id] == state.spacing)
	_update_grid_status()


# --- Shell: actions, palette, toasts, recent files, autosave, drag and drop ---

func _setup_shell() -> void:
	_setup_overlays()
	toasts = ToastHost.new()
	# Over the 3D view, where a notice never covers a control in any mode.
	viewport.add_child(toasts)
	command_palette = CommandPalette.new()
	command_palette.theme = theme
	add_child(command_palette)
	autosave = Autosave.new()
	autosave.name = "Autosave"
	autosave.dirty = func() -> bool: return history.is_dirty() and viewport.models.get_child_count() > 0
	autosave.snapshot = _autosave_snapshot
	add_child(autosave)
	get_window().files_dropped.connect(_on_files_dropped)
	preferences = Preferences.new()
	add_child(preferences)
	importer = ImportShape.new()
	importer.name = "ImportShape"
	add_child(importer)
	importer.bind(self)
	model_importer = preload("res://ui/app/import_model.gd").new()
	model_importer.name = "ImportModel"
	add_child(model_importer)
	model_importer.bind(self)
	EditorActions.register_all(self, actions)
	actions.load_keymap()
	_build_menus()
	actions.shortcuts_changed.connect(menu_builder.sync_accelerators)


func open_command_palette() -> void:
	command_palette.theme = theme
	command_palette.open(actions)


## Shows a non-blocking notice. kind is "info" or "error".
func notify(message: String, kind := "info", actions_list: Array = []) -> void:
	if toasts != null:
		toasts.show_toast(message, kind, -1.0, actions_list)


func delete_selection() -> void:
	if modes.current.clipboard == "elements" and is_instance_valid(viewport.selected_node):
		hierarchy_actions.delete_shape(viewport.selected_node)


## "• wyvern.shapesmith.json — ShapeSmith" while there are unsaved edits.
func _update_title() -> void:
	if is_instance_valid(welcome):
		welcome.visible = viewport.models.get_child_count() == 0
	if viewport.models.get_child_count() == 0:
		get_window().title = "ShapeSmith"
		return
	var name_value := "Untitled" if current_path.is_empty() else current_path.get_file()
	get_window().title = "%s%s — ShapeSmith" % ["• " if history.is_dirty() else "", name_value]


func _rebuild_recent_menu() -> void:
	recent_menu.clear()
	for i in range(recent_files.paths.size()):
		var path: String = recent_files.paths[i]
		recent_menu.add_item("%s   %s" % [path.get_file(), path.get_base_dir()], i)
		recent_menu.set_item_tooltip(i, path)
	if recent_files.paths.is_empty():
		recent_menu.add_item("No recent files", CLEAR_RECENT - 1)
		recent_menu.set_item_disabled(0, true)
	recent_menu.add_separator()
	recent_menu.add_item("Clear Recent Files", CLEAR_RECENT)
	recent_menu.set_item_disabled(recent_menu.get_item_index(CLEAR_RECENT), recent_files.paths.is_empty())


func _on_recent_selected(id: int) -> void:
	if id == CLEAR_RECENT:
		recent_files.clear()
		return
	if id < 0 or id >= recent_files.paths.size():
		return
	var path: String = recent_files.paths[id]
	if not FileAccess.file_exists(path):
		recent_files.remove(path)
		notify("%s no longer exists, so it was removed from Open Recent." % path.get_file(), "error")
		return
	request_load_shape(path)


func _autosave_snapshot() -> Dictionary:
	if viewport.models.get_child_count() == 0:
		return {}
	var destination: String = current_path if not current_path.is_empty() else autosave.directory.path_join("Untitled.shapesmith.json")
	var base: Dictionary = viewport.texture_library.data_for_save(destination)
	var controller_list: Array = IkRigs.split_controllers(base)
	var output: Dictionary = context_models.data_for_save(base, destination)
	var working := WorkingDocument.build(output)
	if working.error.is_empty():
		ik.finish_game_animations(working.data, controller_list, false)
		if not controller_list.is_empty():
			working.data.shapesmith.controllers = controller_list
	return {"data": working.data if working.error.is_empty() else output, "source": current_path, "working": document_is_working}


## Offers to recover an autosave that an earlier session left behind.
func _offer_recovery() -> void:
	var found: Array = autosave.pending()
	if found.is_empty():
		return
	var entry: Dictionary = found[0]
	var name_value: String = entry.source.get_file() if not entry.source.is_empty() else "an untitled shape"
	notify("ShapeSmith closed with unsaved changes to %s%s." % [name_value, (" (" + entry.time.replace("T", " ") + ")") if not entry.time.is_empty() else ""], "info",
		[["Recover", recover_autosave.bind(entry)], ["Discard", func():
			for each in found:
				autosave.discard(each.path)]])


func recover_autosave(entry: Dictionary) -> void:
	_request_document_action(_recover.bind(entry))


func _recover(entry: Dictionary) -> void:
	_load_shape(entry.path)
	if current_path != entry.path:
		return
	current_path = entry.source
	document_is_working = entry.working and not entry.source.is_empty()
	context_models.source_path = current_path
	viewport.texture_library.bind(viewport.shape_data, current_path)
	context_models.rebuild()
	autosave.discard(entry.path)
	history.mark_unsaved()
	status.text = "Recovered unsaved changes"
	notify("Recovered unsaved changes. Save to keep them.")


func _on_files_dropped(files: PackedStringArray) -> void:
	for file in files:
		match file.get_extension().to_lower():
			"json":
				if viewport.models.get_child_count() == 0:
					request_load_shape(file)
				else:
					notify("Open %s, or import it into this shape?" % file.get_file(), "info",
						[["Open", request_load_shape.bind(file)], ["Import…", importer.begin.bind(file)]])
				return
			"png":
				_link_dropped_texture(file)
			"fbx", "glb", "gltf":
				model_importer.begin(file)
				return
			_:
				notify("ShapeSmith cannot open %s files." % file.get_extension(), "error")


## Dropping a PNG adds it as a texture ID named after the file.
func _link_dropped_texture(path: String) -> void:
	if viewport.models.get_child_count() == 0:
		notify("Open or create a shape before adding textures.", "error")
		return
	var library = viewport.texture_library
	var base := path.get_file().get_basename().to_lower().replace(" ", "_")
	var id := base
	var suffix := 2
	while id in library.ids():
		id = "%s_%d" % [base, suffix]
		suffix += 1
	var roots_before: PackedStringArray = library.linked_paths.additional.duplicate()
	library.set_definition(id, {"base": library.portable_reference(path)}, roots_before)
	notify("Added texture #%s from %s." % [id, path.get_file()])


# --- Docks --------------------------------------------------------------------

## Builds the tabbed docks from the workspace's panels: the left dock gets
## Outliner and Animations tabs, the Texture-mode sidebar gets Face and
## Textures (the Texture Manager, no longer a separate window).
func _setup_docks() -> void:
	var left_dock: Control = $Layout/Workspace/Content/LeftDock
	left_tabs = TabContainer.new()
	left_tabs.name = "Tabs"
	left_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_dock.add_child(left_tabs)
	left_dock.move_child(left_tabs, hierarchy.get_index())
	for panel in [hierarchy, workspace.animation_sidebar]:
		panel.reparent(left_tabs, false)
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_tabs.set_tab_title(LeftTab.OUTLINER, "Outliner")
	left_tabs.set_tab_title(LeftTab.ANIMATIONS, "Animations")
	# IK and Poses get their own tabs in Animation mode.
	ik_tab_box = _scrolling_tab("IK")
	pose_tab_box = _scrolling_tab("Poses")
	# Attachment points get their own tab in Model mode.
	attachments_tab_box = _scrolling_tab("Attachments")
	left_dock.get_node("TextureManagerButton").free()

	var sidebar_margin: Control = texturing.get_parent()
	right_tabs = TabContainer.new()
	right_tabs.name = "Tabs"
	sidebar_margin.add_child(right_tabs)
	# The face panel sits in a margin inside its tab, like the docks' other pages.
	var face_page := MarginContainer.new()
	face_page.name = "FacePage"
	for side in ["left", "right", "bottom"]:
		face_page.add_theme_constant_override("margin_" + side, 8)
	face_page.add_theme_constant_override("margin_top", 6)
	right_tabs.add_child(face_page)
	texturing.reparent(face_page, false)
	texture_manager.reparent(right_tabs, false)
	right_tabs.set_tab_title(RightTab.FACE, "Face")
	right_tabs.set_tab_title(RightTab.TEXTURES, "Textures")

	var content: SplitContainer = $Layout/Workspace/Content
	_default_left_width = content.split_offset
	dock_layout.bind({"left": content, "right": $Layout/Workspace/Content/RightSplit}, {"left": left_tabs, "right": right_tabs})
	dock_layout.load_config()


func _scrolling_tab(title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.name = title
	panel.theme_type_variation = &"SidebarPanel"
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_tabs.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)
	left_tabs.set_tab_title(left_tabs.get_tab_count() - 1, title)
	return box


func _show_left_tab(tab: int) -> void:
	if not left_tabs.is_tab_hidden(tab):
		left_tabs.current_tab = tab


## Forgets remembered dock sizes and tabs and returns to the defaults.
func reset_layout() -> void:
	dock_layout.reset()
	$Layout/Workspace/Content.split_offset = _default_left_width
	workspace.reset_inspector_width()
	right_tabs.current_tab = RightTab.FACE
	_on_mode_changed(mode_tabs.current_tab)
	notify("Layout reset.")


# --- Menus and commands -------------------------------------------------------

## File, Edit, Add, View, Animation, Tools, Help. Items come from actions, so
## they show the current shortcut and are disabled when they cannot run.
func _build_menus() -> void:
	var menus: MenuBar = edit_menu.get_parent()
	add_menu = PopupMenu.new()
	add_menu.name = "Add"
	menus.add_child(add_menu)
	menus.move_child(add_menu, edit_menu.get_index() + 1)
	animation_menu = PopupMenu.new()
	animation_menu.name = "Animation"
	menus.add_child(animation_menu)
	menus.move_child(animation_menu, camera_menu.get_index() + 1)
	help_menu = PopupMenu.new()
	help_menu.name = "Help"
	menus.add_child(help_menu)
	menus.set_menu_title(camera_menu.get_index(), "View")
	menu_builder.registry = actions
	menu_builder.run = run_action
	menu_builder.build(file_menu, [["file.new", FileAction.NEW], ["file.open", FileAction.LOAD],
		["submenu", "Open Recent", recent_menu, FileAction.RECENT], ["file.import", FileAction.IMPORT],
		["file.import_model", FileAction.IMPORT_MODEL], "-",
		["file.save", FileAction.SAVE], ["file.save_as", FileAction.SAVE_AS], "-",
		["file.export", FileAction.EXPORT], ["file.export_uv", FileAction.EXPORT_UV], "-",
		["file.references", FileAction.REFERENCES], ["file.asset_paths", FileAction.ASSET_PATHS],
		["file.preferences", FileAction.PREFERENCES]])
	menu_builder.build(edit_menu, [["edit.undo", EditAction.UNDO], ["edit.redo", EditAction.REDO], "-",
		["edit.cut", EditAction.CUT], ["edit.copy", EditAction.COPY], ["edit.paste", EditAction.PASTE],
		["edit.duplicate", EditAction.DUPLICATE], ["edit.delete", EditAction.DELETE], "-",
		["edit.select_all", EditAction.SELECT_ALL], ["edit.invert_selection", EditAction.INVERT],
		["edit.rename", EditAction.RENAME], "-", ["edit.group", EditAction.GROUP_SELECTION],
		["edit.ungroup", EditAction.UNGROUP], ["edit.lock", EditAction.LOCK], "-",
		["submenu", "Grid", grid_menu, EditAction.GRID], ["edit.theme", EditAction.THEME], "-",
		["edit.palette", EditAction.PALETTE]])
	menu_builder.build(add_menu, [["add.cube", AddAction.CUBE], ["add.at_pointer", AddAction.AT_POINTER],
		["add.child", AddAction.CHILD], ["add.sibling", AddAction.SIBLING], "-", ["add.group", AddAction.GROUP],
		["add.attachment_point", AddAction.ATTACHMENT_POINT], ["add.bounds_cube", AddAction.BOUNDS_CUBE]])
	menu_builder.build(camera_menu, [
		["view.perspective", ViewAction.PERSPECTIVE, func() -> bool: return viewport.camera.projection == Camera3D.PROJECTION_PERSPECTIVE],
		["view.orthographic", ViewAction.ORTHOGRAPHIC, func() -> bool: return viewport.camera.projection == Camera3D.PROJECTION_ORTHOGONAL], "-",
		["view.frame", ViewAction.FRAME_ALL], ["view.frame_selection", ViewAction.FRAME_SELECTION],
		["view.isolate", ViewAction.ISOLATE, func() -> bool: return isolated], ["view.hide_others", ViewAction.HIDE_OTHERS],
		["view.show_all", ViewAction.SHOW_ALL], "-",
		["submenu", "Render Mode", rendering_menu, ViewAction.RENDER_MODE], ["view.lighting", ViewAction.LIGHTING],
		["view.point_labels", ViewAction.POINT_LABELS, func() -> bool: return attachment_points.show_all_labels],
		["view.reset_layout", RESET_LAYOUT]])
	menu_builder.build(animation_menu, [["animation.new", AnimationAction.NEW], ["animation.duplicate", AnimationAction.DUPLICATE],
		["animation.delete", AnimationAction.DELETE], "-", ["animation.play", AnimationAction.PLAY],
		["animation.insert_key", AnimationAction.INSERT_KEY], ["animation.delete_keys", AnimationAction.DELETE_KEYS],
		["animation.auto_key", AnimationAction.AUTO_KEY, func() -> bool: return workspace.auto_key],
		["animation.paste_mirrored", AnimationAction.PASTE_MIRRORED], "-",
		["animation.insert_frame", AnimationAction.INSERT_FRAME], ["animation.delete_frame", AnimationAction.DELETE_FRAME],
		["animation.add_marker", AnimationAction.ADD_MARKER], "-",
		["animation.graph", AnimationAction.GRAPH, func() -> bool: return workspace.graph.visible]])
	menu_builder.build(help_menu, [["help.shortcuts", HelpAction.SHORTCUTS], ["help.guide", HelpAction.GUIDE],
		["edit.palette", HelpAction.PALETTE], "-", ["help.about", HelpAction.ABOUT]])


## Runs an action chosen from a menu or by its menu shortcut, unless a text
## field has focus and the action should leave typing alone.
func run_action(id: String) -> void:
	if actions.shortcut_allowed(id, get_viewport().gui_get_focus_owner()):
		actions.trigger(id)


func open_preferences(tab := "") -> void:
	preferences.theme = theme
	preferences.open(self, tab)


func copy_selection() -> void:
	if modes.current.clipboard == "keyframes":
		workspace.tracks.copy_selection()
	elif is_instance_valid(viewport.selected_node):
		hierarchy_actions.copy_shape(viewport.selected_node)


func paste_clipboard() -> void:
	if modes.current.clipboard == "keyframes":
		workspace.tracks.paste_at_playhead()
	elif modes.current.clipboard == "elements":
		hierarchy_actions.paste_shape(viewport.selected_node)


func cut_selection() -> void:
	copy_selection()
	if modes.current.clipboard == "keyframes":
		workspace._delete_keyframes(workspace.tracks.selected_keys.duplicate())
	else:
		delete_selection()


## Copies the selected element (or every selected element) next to itself,
## leaving the clipboard alone.
func duplicate_selection() -> void:
	if is_instance_valid(viewport.selected_node):
		hierarchy_actions.duplicate_shapes(viewport.selected_node)


## Every selected element's node, in selection order.
func _selected_nodes() -> Array:
	var nodes: Array = []
	for uid in selection.items:
		var node: Node3D = scene_sync.node_for(uid)
		if node != null:
			nodes.append(node)
	return nodes


## Shift+A: a 4×4×4 cube on the face under the pointer, or at the view centre.
func add_at_pointer() -> void:
	hierarchy_editor.add_at(viewport.pick_at(viewport.get_local_mouse_position()), viewport.target)


func invert_selection() -> void:
	var others: Array = Array(document.ordered()).filter(func(uid: String): return not selection.has(uid))
	if others.is_empty():
		_select_element(null)
		return
	selection.set_items(others, others[0])
	_select_element(scene_sync.node_for(others[0]), "", true)


## F2 outside the outliner: rename the selected element in its outliner row.
func rename_selected() -> void:
	var node: Node3D = viewport.selected_node
	if is_instance_valid(node):
		if modes.current.shows("hierarchy"):
			_show_left_tab(LeftTab.OUTLINER)
		hierarchy.begin_rename(node)


func add_empty_group() -> void:
	hierarchy_editor.add_element({"name": hierarchy_editor.unique_name("Group"), "from": [0, 0, 0], "to": [0, 0, 0]}, "Add Group")


## A cube enclosing every selected element, added at the root.
func add_bounds_cube() -> void:
	var bounds := _selection_bounds()
	if not bounds.has_volume() or viewport.models.get_child_count() == 0:
		notify("The selection has no volume to enclose.", "error")
		return
	var shape: Node3D = viewport.models.get_child(0)
	var local := AABB()
	var first := true
	for i in range(8):
		var point: Vector3 = shape.global_transform.affine_inverse() * bounds.get_endpoint(i) * 16.0
		local = AABB(point, Vector3.ZERO) if first else local.expand(point)
		first = false
	var start := local.position.snapped(Vector3.ONE * 0.001)
	var end := local.end.snapped(Vector3.ONE * 0.001)
	var source: Dictionary = hierarchy_editor.cube_source(hierarchy_editor.unique_name("Bounds"))
	source.from = [start.x, start.y, start.z]
	source.to = [end.x, end.y, end.z]
	source.rotationOrigin = [start.x, start.y, start.z]
	hierarchy_editor.add_element(source, "Add Cube from Selection Bounds", ShapeDocument.ROOT)


func _selection_bounds() -> AABB:
	var nodes: Array = []
	for uid in selection.items:
		var node: Node3D = scene_sync.node_for(uid)
		if node != null:
			nodes.append(node)
	if nodes.is_empty() and is_instance_valid(viewport.selected_node):
		nodes.append(viewport.selected_node)
	return viewport.bounds_of(nodes)


func frame_all() -> void:
	viewport.update_model_bounds()
	viewport.frame_shape()


func frame_selection() -> void:
	var bounds := _selection_bounds()
	if bounds.size != Vector3.ZERO or bounds.position != Vector3.ZERO:
		viewport.frame_bounds(bounds)


## Hides every element mesh except the selection's (a preview; nothing in the
## file changes). Toggling again shows them all.
func toggle_isolation() -> void:
	isolated = not isolated
	var keep := {}
	if isolated:
		for uid in selection.items:
			keep[uid] = true
		if keep.is_empty():
			keep[ShapeDocument.uid_of(viewport.selected_node)] = true
	for uid in document.ordered():
		var node: Node3D = scene_sync.node_for(uid)
		var geometry: Node = node.get_node_or_null("Geometry") if node != null else null
		if geometry != null:
			geometry.visible = not isolated or keep.has(uid)
	notify("Showing the selection only. Press / again to show everything." if isolated else "Showing every element.")


func insert_key() -> void:
	if workspace.insert_key(viewport.selected_node):
		notify("Inserted a key at frame %d." % roundi(workspace.frame))


## Help → User Guide: the guide, read in the app.
## Gives a file dialog made in code the look and size of the app's own.
func style_file_dialog(picker: FileDialog) -> void:
	picker.theme = theme
	picker.size = file_picker.size
	picker.min_size = file_picker.min_size


func open_user_guide() -> void:
	if guide_window == null:
		guide_window = preload("res://ui/help/user_guide_window.gd").new()
		guide_window.name = "UserGuide"
		add_child(guide_window)
		guide_window.bind_window(get_window(), theme)
	guide_window.open_guide()


func show_about() -> void:
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	notify("ShapeSmith %s, a shape and animation editor for Vintage Story, built with Godot %s." % [version, Engine.get_version_info().string])


# --- Viewport overlays, welcome panel and footer hints -------------------------

func _setup_overlays() -> void:
	overlay = ViewportOverlay.new()
	viewport.add_child(overlay)
	overlay.bind(viewport, gizmo_toolbar, rendering_menu)
	overlay.set_render_mode(viewport.texture_library.render_mode)
	overlay.render_mode_selected.connect(_on_rendering_selected)
	welcome = WelcomePanel.new()
	overlay.add_child(welcome)
	welcome.bind(self)
	welcome.visible = viewport.models.get_child_count() == 0



