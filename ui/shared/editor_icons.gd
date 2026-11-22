extends RefCounted
## Google Material Symbols Outlined, bundled under Apache-2.0.


## The icon for each menu item, by action id (submenus by their label).
const MENU_ICONS := {
	"file.new": "note_add", "file.open": "folder_open", "Open Recent": "history", "file.import": "input",
	"file.import_model": "deployed_code", "file.save": "save", "file.save_as": "save_as", "file.export": "ios_share",
	"file.export_uv": "download", "file.references": "layers", "file.asset_paths": "folder_managed", "file.preferences": "settings",
	"edit.undo": "undo", "edit.redo": "redo", "edit.cut": "content_cut", "edit.copy": "content_copy", "edit.paste": "content_paste",
	"edit.duplicate": "library_add", "edit.delete": "delete", "edit.select_all": "select_all", "edit.invert_selection": "flip_to_front",
	"edit.rename": "edit", "edit.group": "create_new_folder", "edit.ungroup": "folder_off", "edit.lock": "lock", "Grid": "grid_on",
	"edit.theme": "palette", "edit.palette": "search",
	"add.cube": "deployed_code", "add.at_pointer": "ads_click", "add.child": "subdirectory_arrow_right", "add.sibling": "add",
	"add.group": "create_new_folder", "add.attachment_point": "my_location", "add.bounds_cube": "select",
	"view.perspective": "3d_rotation", "view.orthographic": "grid_view", "view.frame": "zoom_out_map",
	"view.frame_selection": "center_focus_strong", "view.isolate": "filter_center_focus", "view.hide_others": "visibility_off",
	"view.show_all": "visibility", "Render Mode": "contrast", "view.lighting": "light_mode", "view.point_labels": "label",
	"view.reset_layout": "restart_alt",
	"animation.new": "movie", "animation.duplicate": "content_copy", "animation.delete": "delete", "animation.play": "play_arrow",
	"animation.insert_key": "key", "animation.delete_keys": "key_off", "animation.auto_key": "radio_button_checked",
	"animation.paste_mirrored": "flip", "animation.insert_frame": "playlist_add", "animation.delete_frame": "playlist_remove",
	"animation.add_marker": "bookmark", "animation.graph": "show_chart",
	"tools.screenshot": "photo_camera", "help.shortcuts": "keyboard", "help.guide": "menu_book", "help.about": "info",
}


static func icon(name_value: String) -> Texture2D:
	return load("res://assets/icons/material/%s.svg" % name_value)


static func apply_buttons(root: Node) -> void:
	var actions := {
		"Fit": ["zoom_out_map", "Fit UV texture in view"],
		"ExportUV": ["download", "Export UV layout"],
		"NewAnimation": ["add", "New animation"],
		"DeleteAnimation": ["delete", "Delete animation"],
		"DuplicateAnimation": ["content_copy", "Duplicate animation"],
		"First": ["skip_previous", "First frame"], "Last": ["skip_next", "Last frame"],
		"Previous": ["arrow_back", "Previous frame"], "Next": ["arrow_forward", "Next frame"],
		"Stop": ["stop", "Stop animation"], "Play": ["play_arrow", "Play animation"],
		"BrowseBase": ["folder_open", "Link texture file"],
		"AddOverlay": ["add_photo_alternate", "Add overlay image"],
		"RemoveOverlay": ["delete", "Remove overlay"],
		"MoveUp": ["arrow_upward", "Move overlay up"], "MoveDown": ["arrow_downward", "Move overlay down"],
		"Add": ["add", "Add shape"], "Rename": ["edit", "Rename"]}
	if root is Button and actions.has(str(root.name)):
		var action: Array = actions[str(root.name)]
		root.icon = icon(action[0])
		root.text = ""
		if root.tooltip_text.is_empty():
			root.tooltip_text = action[1]
		root.custom_minimum_size.x = 32
		root.add_theme_constant_override("icon_max_width", 20)
	for child in root.get_children():
		apply_buttons(child)
