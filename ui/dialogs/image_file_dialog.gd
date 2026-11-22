extends FileDialog

const MAX_ENTRIES_PER_FRAME := 16

const THUMB_SIZE := 64
const CACHE_LIMIT := 128
var file_list: Control
var thumbnails: Dictionary = {}
var cursor := 0
var directory_seen := ""
var applied: Dictionary = {}


func _ready() -> void:
	file_list = _find_file_list(get_vbox())
	if file_list == null:
		return

	file_list.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _find_file_list(node: Node) -> Control:
	# Godot 4.5+ has ItemLists for favorites, recent folders, and files.
	# The files list is last; older releases use a single Tree instead.
	var lists: Array[ItemList] = []
	_collect_lists(node, lists)
	if not lists.is_empty():
		return lists.back()

	return _find_tree(node)


func _collect_lists(node: Node, lists: Array[ItemList]) -> void:
	if node is ItemList:
		lists.append(node)
	for child in node.get_children(true):
		_collect_lists(child, lists)


func _find_tree(node: Node) -> Tree:
	if node is Tree:
		return node

	for child in node.get_children(true):
		var found := _find_tree(child)
		if found != null:
			return found

	return null


func _process(_delta: float) -> void:
	if not visible or file_list == null:
		return

	var items := preview_entries()
	if items.is_empty():
		return

	if directory_seen != current_dir:
		directory_seen = current_dir
		cursor = 0
		applied.clear()
	# Decode at most one PNG per frame so opening a directory remains responsive.
	for attempt in range(mini(items.size(), MAX_ENTRIES_PER_FRAME)):
		cursor %= items.size()
		var index := cursor
		cursor += 1
		var entry: Dictionary = items[index]
		var name_value: String = entry.name
		if name_value.get_extension().to_lower() != "png":
			continue

		var path := current_dir.path_join(name_value)
		var key := "%s:%d" % [path, FileAccess.get_modified_time(path)]
		var icon := entry_icon(entry)
		var stamp := "%s:%d" % [key, icon.get_instance_id() if icon != null else 0]
		if applied.get(index, "") == stamp:
			continue

		var missing := not thumbnails.has(key)
		if missing:
			if thumbnails.size() >= CACHE_LIMIT:
				thumbnails.erase(thumbnails.keys()[0])
			thumbnails[key] = make_thumbnail(path)
		if thumbnails[key] != null:
			if file_list is ItemList:
				file_list.set_item_icon(entry.index, thumbnails[key])
			else:
				entry.item.set_icon(0, thumbnails[key])
				entry.item.set_icon_max_width(0, THUMB_SIZE)
				entry.item.set_custom_minimum_height(THUMB_SIZE + 8)
			icon = thumbnails[key]
		applied[index] = "%s:%d" % [key, icon.get_instance_id() if icon != null else 0]
		if missing:
			break


func preview_entries() -> Array:
	var result: Array = []
	if file_list is ItemList:
		for i in range(file_list.item_count):
			result.append({"name": file_list.get_item_text(i), "index": i})
	elif file_list is Tree and file_list.get_root() != null:
		for item in file_list.get_root().get_children():
			result.append({"name": item.get_text(0), "item": item})
	return result


func entry_icon(entry: Dictionary) -> Texture2D:
	return file_list.get_item_icon(entry.index) if file_list is ItemList else entry.item.get_icon(0)


func make_thumbnail(path: String) -> Texture2D:
	var image := Image.new()
	if image.load(path) != OK or image.is_empty():
		return null

	var scale_value := minf(float(THUMB_SIZE) / image.get_width(), float(THUMB_SIZE) / image.get_height())
	image.resize(maxi(roundi(image.get_width() * scale_value), 1), maxi(roundi(image.get_height() * scale_value), 1), Image.INTERPOLATE_NEAREST)
	image.convert(Image.FORMAT_RGBA8)
	var preview := Image.create(THUMB_SIZE, THUMB_SIZE, false, Image.FORMAT_RGBA8)
	preview.fill(Color.TRANSPARENT)
	preview.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), (Vector2i(THUMB_SIZE, THUMB_SIZE) - image.get_size()) / 2)
	return ImageTexture.create_from_image(preview)
