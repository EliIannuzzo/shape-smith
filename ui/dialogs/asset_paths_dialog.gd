extends ConfirmationDialog

var settings
var browse_target := "base"
@onready var base: LineEdit = %BasePath
@onready var paths: ItemList = %AdditionalPaths


func _ready() -> void:
	dialog_hide_on_ok = false
	confirmed.connect(_apply)
	%BrowseBase.pressed.connect(func(): _browse("base"))
	%Add.pressed.connect(func(): _browse("additional"))
	%Remove.pressed.connect(func(): _move("remove"))
	%Up.pressed.connect(func(): _move("up"))
	%Down.pressed.connect(func(): _move("down"))
	%FolderPicker.dir_selected.connect(_chosen)


func open() -> void:
	sync_from_settings()
	popup_centered(Vector2i(mini(get_parent().get_window().size.x - 32, 850), mini(get_parent().get_window().size.y - 32, 520)))


func sync_from_settings() -> void:
	base.text = settings.base_path
	paths.clear()
	for path in settings.additional:
		_add(path)
	%Message.text = "Base assets are searched first, then additional paths from top to bottom. First match wins."


func _browse(target: String) -> void:
	browse_target = target
	%FolderPicker.popup_centered_ratio(0.85)


func _chosen(path: String) -> void:
	if browse_target == "base":
		base.text = path
	else:
		_add(path)


func _add(path: String) -> void:
	var index := paths.add_item(path)
	paths.set_item_tooltip(index, path)
	paths.select(index)


func _move(action: String) -> void:
	if paths.get_selected_items().is_empty():
		return

	var index: int = paths.get_selected_items()[0]
	if action == "remove":
		paths.remove_item(index)
		if paths.item_count > 0:
			paths.select(mini(index, paths.item_count - 1))
		return

	var next := clampi(index + (-1 if action == "up" else 1), 0, paths.item_count - 1)
	var value := paths.get_item_text(index)
	paths.set_item_text(index, paths.get_item_text(next))
	paths.set_item_tooltip(index, paths.get_item_text(next))
	paths.set_item_text(next, value)
	paths.set_item_tooltip(next, value)
	paths.select(next)


func _apply() -> void:
	var additional := PackedStringArray()
	for i in range(paths.item_count):
		additional.append(paths.get_item_text(i))
	var error: String = settings.configure(base.text, additional)
	if not error.is_empty():
		%Message.text = error
		return

	hide()


func _shortcut_input(event: InputEvent) -> void:
	if settings != null and settings.history != null:
		settings.history.handle_shortcut(event, get_viewport())
