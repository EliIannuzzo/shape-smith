extends RefCounted
## Registers every editor command with the action registry: its label,
## category, default shortcut, when it can run, and when its shortcut may fire.
## Menus, the command palette and keyboard shortcuts all use these.

const Document = preload("res://core/document/shape_document.gd")


static func register_all(app, registry) -> void:
	var has_document := func() -> bool: return app.viewport.models.get_child_count() > 0
	var model_mode := func() -> bool: return app.modes.current.clipboard == "elements"
	var animation_mode := func() -> bool: return app.modes.is_mode("Animation")
	var has_selection := func() -> bool: return model_mode.call() and is_instance_valid(app.viewport.selected_node)
	var has_clip := func() -> bool: return animation_mode.call() and app.workspace.selected >= 0 and app.workspace.selected < app.workspace.animation.clips.size()
	# File commands work even while a text field has focus.
	var anywhere := func(_focus: Control) -> bool: return true
	var not_typing := func(focus: Control) -> bool: return not (focus is LineEdit or focus is TextEdit)
	# Single-key shortcuts must not fire while a button or list has focus either.
	var free_keys := func(focus: Control) -> bool: return not (focus is LineEdit or focus is TextEdit or focus is BaseButton or focus is ItemList)

	registry.register("file.new", "New", "File", app.request_new_shape, KEY_MASK_CTRL | KEY_N, Callable(), anywhere)
	registry.register("file.open", "Open…", "File", app.open_shape_picker, KEY_MASK_CTRL | KEY_O, Callable(), anywhere)
	registry.register("file.import_model", "Import Model (glTF, FBX)…", "File", func(): app.model_importer.open_picker(), 0, func() -> bool: return true, anywhere)
	registry.register("file.import", "Import Shape…", "File", func(): app.importer.open_picker(), KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_I, has_document, anywhere)
	registry.register("file.save", "Save", "File", func(): app.save_shape(), KEY_MASK_CTRL | KEY_S, has_document, anywhere)
	registry.register("file.save_as", "Save As…", "File", app.save_as, KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_S, has_document, anywhere)
	registry.register("file.export", "Export for Vintage Story…", "File", app.open_animation_export, KEY_MASK_CTRL | KEY_E, has_document, anywhere)
	registry.register("file.export_uv", "Export UV Map…", "File", func(): app.texturing.uv_tools.open_export(), 0, func() -> bool: return has_document.call() and not app.viewport.texture_library.data.is_empty())
	registry.register("file.references", "Shapes…", "File", func(): app.context_panel.open(), 0, has_document)
	registry.register("file.asset_paths", "Asset Paths…", "File", func(): app.configure_asset_paths())
	registry.register("file.preferences", "Preferences…", "File", func(): app.open_preferences(), KEY_MASK_CTRL | KEY_COMMA, Callable(), anywhere)

	registry.register("edit.undo", "Undo", "Edit", func(): app.history.undo(), KEY_MASK_CTRL | KEY_Z, func() -> bool: return not app.history.undo_name().is_empty(), anywhere)
	registry.register("edit.redo", "Redo", "Edit", func(): app.history.redo(), KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_Z, func() -> bool: return not app.history.redo_name().is_empty(), anywhere)
	registry.register("edit.cut", "Cut", "Edit", app.cut_selection, KEY_MASK_CTRL | KEY_X, func() -> bool: return has_selection.call() or app.workspace.tracks.selected_keys.size() > 0 and animation_mode.call())
	registry.register("edit.copy", "Copy", "Edit", app.copy_selection, KEY_MASK_CTRL | KEY_C, func() -> bool: return has_selection.call() or animation_mode.call())
	registry.register("edit.paste", "Paste", "Edit", app.paste_clipboard, KEY_MASK_CTRL | KEY_V, func() -> bool: return model_mode.call() or animation_mode.call())
	registry.register("edit.duplicate", "Duplicate", "Edit", app.duplicate_selection, KEY_MASK_CTRL | KEY_D, has_selection)
	registry.register("edit.delete", "Delete", "Edit", app.delete_selection, KEY_DELETE, has_selection)
	registry.register("edit.select_all", "Select All", "Edit", app.select_all_elements, KEY_MASK_CTRL | KEY_A, func() -> bool: return model_mode.call() and not app.document.elements.is_empty())
	registry.register("edit.invert_selection", "Invert Selection", "Edit", app.invert_selection, KEY_MASK_CTRL | KEY_I, func() -> bool: return model_mode.call() and not app.document.elements.is_empty())
	registry.register("edit.rename", "Rename", "Edit", app.rename_selected, KEY_F2, has_selection, free_keys)
	registry.register("edit.group", "Group Selection", "Edit", func(): app.hierarchy_editor.group_elements(app.viewport.selected_node), KEY_MASK_CTRL | KEY_G, has_selection)
	registry.register("edit.ungroup", "Ungroup", "Edit", func(): app.hierarchy_editor.lift_children(app.viewport.selected_node, "Ungroup"), KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_G,
		func() -> bool: return has_selection.call() and not app.document.children_of(Document.uid_of(app.viewport.selected_node)).is_empty())
	registry.register("edit.lock", "Lock / Unlock", "Edit", func(): app.hierarchy.toggle_lock(app.viewport.selected_node), KEY_MASK_CTRL | KEY_L, has_selection)
	registry.register("edit.theme", "Theme…", "Edit", func(): app.theme_editor.open())
	registry.register("edit.palette", "Command Palette…", "Edit", app.open_command_palette, KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_P, Callable(), anywhere)

	registry.register("add.cube", "Cube", "Add", func(): app.hierarchy_editor.add_shape(), 0, model_mode)
	registry.register("add.at_pointer", "Cube at Pointer", "Add", app.add_at_pointer, KEY_MASK_SHIFT | KEY_A, model_mode, free_keys)
	registry.register("add.child", "Child Cube", "Add", func(): app.hierarchy_editor.add_relative(app.viewport.selected_node, true), 0, has_selection)
	registry.register("add.sibling", "Sibling Cube", "Add", func(): app.hierarchy_editor.add_relative(app.viewport.selected_node, false), 0, has_selection)
	registry.register("add.group", "Empty Group", "Add", app.add_empty_group, 0, model_mode)
	registry.register("add.attachment_point", "Attachment Point", "Add", func():
		app.attachment_points.add_point()
		app._show_left_tab(app.LeftTab.ATTACHMENTS), 0, has_selection)
	registry.register("add.bounds_cube", "Cube from Selection Bounds", "Add", app.add_bounds_cube, 0, has_selection)

	registry.register("view.perspective", "Perspective", "View", func(): app._on_camera_selected(0))
	registry.register("view.orthographic", "Orthographic", "View", func(): app._on_camera_selected(1))
	registry.register("view.frame", "Frame All", "View", app.frame_all, KEY_HOME, has_document, free_keys)
	registry.register("view.frame_selection", "Frame Selection", "View", app.frame_selection, KEY_F, func() -> bool: return is_instance_valid(app.viewport.selected_node), free_keys)
	registry.register("view.isolate", "Isolate Selection", "View", app.toggle_isolation, KEY_SLASH, func() -> bool: return app.isolated or is_instance_valid(app.viewport.selected_node), free_keys)
	registry.register("view.hide_others", "Hide Others", "View", func(): app.hierarchy.hide_others(app._selected_nodes()), KEY_MASK_ALT | KEY_H, has_selection, free_keys)
	registry.register("view.show_all", "Show All", "View", func(): app.hierarchy.show_all(), KEY_MASK_SHIFT | KEY_MASK_ALT | KEY_H, has_document, free_keys)
	registry.register("view.grid", "Toggle Grid", "View", func(): app._on_grid_selected(0))
	registry.register("view.axes", "Toggle Axes", "View", func(): app._on_grid_selected(5))
	for index in range(app.rendering_menu.item_count):
		registry.register("view.render_%d" % index, "Render: " + app.rendering_menu.get_item_text(index), "View", func(): app._on_rendering_selected(index))
	registry.register("view.lighting", "Lighting…", "View", func(): app.overlay.open_lighting())
	registry.register("view.point_labels", "Attachment Point Labels", "View", func(): app.attachment_points.show_all_labels = not app.attachment_points.show_all_labels)
	registry.register("view.reset_layout", "Reset Layout", "View", app.reset_layout)
	for index in range(app.mode_tabs.tab_count):
		var title: String = app.mode_tabs.get_tab_title(index)
		registry.register("mode." + title.to_lower(), title + " Mode", "Mode", func(): app.mode_tabs.current_tab = index, KEY_1 + index, Callable(), free_keys)

	registry.register("animation.new", "New Clip", "Animation", func(): app.workspace._create_animation(), 0, animation_mode)
	registry.register("animation.duplicate", "Duplicate Clip", "Animation", func(): app.workspace._duplicate_animation(), 0, has_clip)
	registry.register("animation.delete", "Delete Clip", "Animation", func(): app.workspace._delete_animation(), 0, has_clip)
	registry.register("animation.play", "Play / Pause", "Animation", func(): app.workspace.toggle_play(), KEY_SPACE, has_clip, free_keys)
	registry.register("animation.insert_key", "Insert Key", "Animation", app.insert_key, KEY_K, func() -> bool: return has_clip.call() and is_instance_valid(app.viewport.selected_node), free_keys)
	registry.register("animation.auto_key", "Auto Key", "Animation", func(): app.workspace.set_auto_key(not app.workspace.auto_key), 0, has_clip)
	registry.register("animation.paste_mirrored", "Paste Mirrored", "Animation", func(): app.workspace.paste_mirrored(), KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_V,
		func() -> bool: return has_clip.call() and not app.workspace.editor.keyframe_clipboard.is_empty())
	registry.register("animation.insert_frame", "Insert Frame", "Animation", func(): app.workspace.ripple(roundi(app.workspace.frame), 1), 0, has_clip)
	registry.register("animation.delete_frame", "Delete Frame", "Animation", func(): app.workspace.ripple(roundi(app.workspace.frame), -1), 0, has_clip)
	registry.register("animation.add_marker", "Add Marker", "Animation", func(): app.workspace.tracks.add_marker(roundi(app.workspace.frame)), 0, has_clip)
	registry.register("animation.copy_pose", "Copy Pose", "Animation", func(): app.pose_tools.copy_pose(), 0, has_clip)
	registry.register("animation.paste_pose", "Paste Pose", "Animation", func(): app.pose_tools.paste_pose(), 0, func() -> bool: return has_clip.call() and not app.pose_tools.clipboard.is_empty())
	registry.register("animation.mirror_pose", "Mirror Pose", "Animation", func(): app.pose_tools.mirror_pose(), 0, has_clip)
	registry.register("animation.reset_pose", "Reset Pose", "Animation", func(): app.pose_tools.reset_pose(), 0, has_clip)
	registry.register("animation.graph", "Graph Editor", "Animation", func(): app.workspace.show_graph(not app.workspace.graph.visible), 0, has_clip)
	registry.register("animation.delete_keys", "Delete Keys", "Animation", func(): app.workspace._delete_keyframes(app.workspace.tracks.selected_keys.duplicate()), 0, func() -> bool: return has_clip.call() and not app.workspace.tracks.selected_keys.is_empty())

	registry.register("panel.textures", "Textures", "Panels", func(): app.texture_manager.open(), 0, func() -> bool: return not app.viewport.texture_library.data.is_empty())
	registry.register("panel.outliner", "Outliner", "Panels", func(): app._show_left_tab(app.LeftTab.OUTLINER), 0, func() -> bool: return app.modes.current.shows("hierarchy"))
	registry.register("panel.animations", "Animations", "Panels", func(): app._show_left_tab(app.LeftTab.ANIMATIONS), 0, func() -> bool: return app.modes.current.shows("animation_list"))
	registry.register("tools.screenshot", "Screenshot…", "Tools", func(): app.screenshot_tool.open(app.current_path))

	registry.register("help.shortcuts", "Keyboard Shortcuts", "Help", func(): app.open_preferences("Shortcuts"))
	registry.register("help.guide", "User Guide", "Help", app.open_user_guide)
	registry.register("help.about", "About ShapeSmith", "Help", app.show_about)
