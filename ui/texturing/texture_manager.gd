extends MarginContainer
## The Texture Manager, docked as the "Textures" tab of the Texture-mode
## sidebar: texture IDs, their base image and overlay layers, and a preview.

signal asset_paths_requested
## open() asks the editor to show this tab (switching to Texture mode).
signal open_requested

var library
var selected_id := ""
var browse_target := "base"
var updating := false
@onready var ids: ItemList = %IDs
@onready var layers: ItemList = %Layers
@onready var base: LineEdit = %Base
@onready var blend_mode: OptionButton = %BlendMode


func _ready() -> void:
	%TexelSize.value_changed.connect(func(value: float):
		if not updating and library != null:
			library.set_texel_size(value))
	%AddID.pressed.connect(_add_id)
	%NewID.text_submitted.connect(func(_value: String): _add_id())
	ids.item_selected.connect(func(index: int):
		selected_id = ids.get_item_text(index)
		refresh())
	base.text_submitted.connect(func(_value: String): _save_base())
	base.focus_exited.connect(_save_base)
	%BrowseBase.pressed.connect(func(): _browse("base"))
	%AddOverlay.pressed.connect(func(): _browse("overlay"))
	%RemoveOverlay.pressed.connect(func(): _change_layer("remove"))
	%MoveUp.pressed.connect(func(): _change_layer("up"))
	%MoveDown.pressed.connect(func(): _change_layer("down"))
	layers.item_selected.connect(_layer_selected)
	blend_mode.item_selected.connect(func(_index: int): _change_layer("blend"))
	%ImagePicker.file_selected.connect(_image_chosen)
	%ChooseRoot.pressed.connect(func(): asset_paths_requested.emit())
	%PreviewOverlays.toggled.connect(func(enabled: bool):
		if library != null:
			library.set_overlay_preview(enabled))
	for mode in library_modes():
		blend_mode.add_item(mode)


func bind_library(value) -> void:
	library = value
	library.changed.connect(refresh)


func open() -> void:
	if library == null or library.data.is_empty():
		return

	refresh()
	open_requested.emit()
	var tabs := get_parent() as TabContainer
	if tabs != null:
		tabs.current_tab = get_index()
	show()


func open_texel_settings() -> void:
	open()
	if visible:
		%TexelSize.get_line_edit().grab_focus()
		%TexelSize.get_line_edit().select_all()


func refresh() -> void:
	if not is_node_ready() or library == null:
		return

	updating = true
	%TexelSize.set_value_no_signal(library.texel_size)
	ids.clear()
	for id in library.ids():
		var index := ids.add_item(id)
		if id == selected_id:
			ids.select(index)
	if not library.ids().has(selected_id):
		selected_id = str(library.ids()[0]) if not library.ids().is_empty() else ""
		if not selected_id.is_empty():
			ids.select(0)
	var enabled := not selected_id.is_empty()
	base.editable = enabled
	%BrowseBase.disabled = not enabled
	%AddOverlay.disabled = not enabled
	%PreviewOverlays.set_pressed_no_signal(library.overlays_enabled)
	var roots: PackedStringArray = library.asset_paths.roots()
	%AssetRoot.text = "%d configured asset paths" % roots.size() if not roots.is_empty() else "Assets: automatic discovery"
	%AssetRoot.tooltip_text = "\n".join(roots)
	layers.clear()
	if enabled:
		var value: Dictionary = library.definition(selected_id)
		base.text = str(value.get("base", ""))
		for layer in _layers(value):
			var index := layers.add_item("%s · %s" % [str(layer.get("blendMode", "Normal")), str(layer.get("base", "")).get_file()])
			layers.set_item_tooltip(index, str(layer.get("base", "")))
		%Preview.texture = library.texture(selected_id)
		var mismatch: String = library.layout_warning(selected_id)
		%Message.text = "\n".join(library.issues.values()) if not library.issues.is_empty() else (mismatch if not mismatch.is_empty() else "Preview updates all faces using #%s. Layers apply from top to bottom." % selected_id)
	else:
		base.text = ""
		%Preview.texture = null
		%Message.text = "Add a texture, then link its base image."
	%Message.tooltip_text = %Message.text
	_layer_selected(-1)
	updating = false


func _add_id() -> void:
	var id: String = %NewID.text.strip_edges().trim_prefix("#")
	var pattern := RegEx.create_from_string("^[A-Za-z0-9_.-]+$")
	if pattern.search(id) == null or library.ids().has(id):
		%Message.text = "Use a unique ID containing letters, numbers, _, - or a dot."
		return

	selected_id = id
	library.set_definition(id, {"base": "", "blendedOverlays": []})
	%NewID.clear()


func _save_base() -> void:
	if updating or selected_id.is_empty() or library == null:
		return

	var value: Dictionary = library.definition(selected_id)
	if str(value.get("base", "")) != base.text.strip_edges():
		value["base"] = base.text.strip_edges()
		library.set_definition(selected_id, value)


func _browse(target: String) -> void:
	browse_target = target
	%ImagePicker.popup_centered_ratio(0.8)


func _image_chosen(path: String) -> void:
	if selected_id.is_empty():
		return

	var roots_before: PackedStringArray = library.linked_paths.additional.duplicate()
	var value: Dictionary = library.definition(selected_id)
	if browse_target == "base":
		value["base"] = library.portable_reference(path)
	else:
		var values := _layers(value)
		values.append({"base": library.portable_reference(path), "blendMode": "Normal"})
		value["blendedOverlays"] = values
		value.erase("overlays")
	library.set_definition(selected_id, value, roots_before)
	var reference: String = library.portable_reference(path)
	var resolved: String = library.resolve(reference)
	if not resolved.is_empty() and library.AssetPaths.normalize(resolved).to_lower() != library.AssetPaths.normalize(path).to_lower():
		%Message.text = "This texture is shadowed by an earlier asset path. Reorder Configure Asset Paths to use the selected file."
		%Message.tooltip_text = %Message.text


func _layers(value: Dictionary) -> Array:
	var result: Array = []
	var raw: Variant = value.get("blendedOverlays", value.get("overlays", []))
	if raw is Array:
		for layer in raw:
			result.append(layer.duplicate(true) if layer is Dictionary else {"base": str(layer), "blendMode": "Normal"})
	return result


func _layer_selected(index: int) -> void:
	var valid := index >= 0 and not selected_id.is_empty()
	for button in [%RemoveOverlay, %MoveUp, %MoveDown, %BlendMode]:
		button.disabled = not valid
	if valid:
		var layer: Dictionary = _layers(library.definition(selected_id))[index]
		var mode: Variant = layer.get("blendMode", "Normal")
		blend_mode.select(maxi(library.blend_mode_index(mode), 0))


func _change_layer(action: String) -> void:
	if updating or layers.get_selected_items().is_empty():
		return

	var index: int = layers.get_selected_items()[0]
	var value: Dictionary = library.definition(selected_id)
	var values := _layers(value)
	var next := index
	match action:
		"remove": values.remove_at(index)
		"blend": values[index]["blendMode"] = library_modes()[blend_mode.selected]
		"up", "down":
			next = clampi(index + (-1 if action == "up" else 1), 0, values.size() - 1)
			var temporary: Dictionary = values[index]
			values[index] = values[next]
			values[next] = temporary
	value["blendedOverlays"] = values
	value.erase("overlays")
	library.set_definition(selected_id, value)
	if not values.is_empty():
		next = mini(next, values.size() - 1)
		layers.select(next)
		_layer_selected(next)


func library_modes() -> Array:
	return preload("res://core/textures/texture_library.gd").MODES


## hide() on the open tab returns the sidebar to its first tab.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and not visible:
		var tabs := get_parent() as TabContainer
		if tabs != null and tabs.current_tab == get_index():
			tabs.current_tab = 0
