extends RefCounted
static var Palette = preload("res://ui/theme/editor_palette.tres")
const PaletteScript = preload("res://ui/theme/editor_palette.gd")
const PRESET_NAMES := ["Dark Blue", "Graphite", "Forest", "Light", "Vintage"]
const PRESET_RESOURCES := [
	preload("res://assets/themes/dark_blue.tres"),
	preload("res://assets/themes/graphite.tres"),
	preload("res://assets/themes/forest.tres"),
	preload("res://assets/themes/light.tres"),
	preload("res://assets/themes/vintage.tres"),
]
var path := "user://theme.json"


static func colors(resource: Resource = Palette) -> Dictionary:
	var result := {}
	for property in resource.get_property_list():
		if property.type == TYPE_COLOR:
			result[str(property.name)] = resource.get(property.name).to_html(true)
	return result


static func defaults() -> Dictionary:
	return colors(PaletteScript.new())


static func preset(index: int) -> Dictionary:
	if index < 0 or index >= PRESET_RESOURCES.size():
		return defaults()

	return colors(PRESET_RESOURCES[index])


static func validate(value: Variant) -> Dictionary:
	if not value is Dictionary or value.get("version") != 1 or not value.get("colors") is Dictionary:
		return {}

	var result := defaults()
	for key in value.colors:
		if not result.has(key):
			continue

		var color: Variant = value.colors[key]
		if not color is String or not color.is_valid_html_color():
			return {}

		result[key] = Color(color).to_html(true)
	return result


func read_file(filename: String) -> Dictionary:
	if not FileAccess.file_exists(filename):
		return {}

	return validate(JSON.parse_string(FileAccess.get_file_as_string(filename)))


func write_file(filename: String, values: Dictionary) -> Error:
	var file := FileAccess.open(filename, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()

	file.store_string(JSON.stringify({"version": 1, "colors": values}, "  ") + "\n")
	file.flush()
	return file.get_error()


func load_saved() -> void:
	var saved := read_file(path)
	if not saved.is_empty():
		for key in saved:
			Palette.set(key, Color(saved[key]))


static func _bound_color(owner: Object, slot: String, color: Color, before: Dictionary) -> Color:
	# Remember the semantic role, so equal custom colors can diverge again later.
	var bindings: Dictionary = owner.get_meta("theme_color_roles", {})
	if not bindings.has(slot):
		for key in before:
			var original := Color(before[key])
			if Vector3(color.r, color.g, color.b).is_equal_approx(Vector3(original.r, original.g, original.b)):
				bindings[slot] = key
				owner.set_meta("theme_color_roles", bindings)
				break
	if bindings.has(slot):
		var result: Color = Palette.get(bindings[slot])
		result.a = color.a
		return result

	return color


static func refresh_tree(node: Node, before: Dictionary) -> void:
	if node is Control:
		for property in node.get_property_list():
			var name: String = property.name
			if name.begins_with("theme_override_colors/") and node.get(name) is Color:
				node.set(name, _bound_color(node, name, node.get(name), before))
			elif name.begins_with("theme_override_styles/"):
				var style: Variant = node.get(name)
				if style is StyleBoxFlat:
					style.bg_color = _bound_color(style, "background", style.bg_color, before)
					style.border_color = _bound_color(style, "border", style.border_color, before)
		if node is ItemList:
			for index in range(node.item_count):
				node.set_item_custom_bg_color(index, _bound_color(node, "row_%d" % index, node.get_item_custom_bg_color(index), before))
		if node is Tree and node.get_root() != null:
			_refresh_item(node.get_root(), before)
		node.queue_redraw()
	for child in node.get_children():
		refresh_tree(child, before)


static func _refresh_item(item: TreeItem, before: Dictionary) -> void:
	for column in range(item.get_tree().columns):
		item.set_custom_bg_color(column, _bound_color(item, "column_%d" % column, item.get_custom_bg_color(column), before))
		var foreground := item.get_custom_color(column)
		var updated := _bound_color(item, "text_%d" % column, foreground, before)
		if updated != foreground:
			item.set_custom_color(column, updated)
		item.set_icon_modulate(column, _bound_color(item, "icon_%d" % column, item.get_icon_modulate(column), before))
	for child in item.get_children():
		_refresh_item(child, before)
