extends RefCounted
## Builds menu bar menus from action ids, so every menu item shows its
## action's current shortcut, is disabled when the action cannot run, and
## runs through the same path as the keyboard shortcut.
##
## Entries: "-" for a separator, [action_id, item_id] for an item,
## [action_id, item_id, checked: Callable] for a check item, or
## ["submenu", label, popup, item_id].

const Icons = preload("res://ui/shared/editor_icons.gd")
static var Palette = preload("res://ui/theme/editor_palette.tres")
var registry
## Called with an action id when a menu item is chosen.
var run: Callable
var _menus: Array[Dictionary] = []


func build(menu: PopupMenu, entries: Array) -> void:
	menu.clear()
	var items := {}
	var checks := {}
	for entry in entries:
		if entry is String:
			menu.add_separator()
		elif entry[0] == "submenu":
			menu.add_submenu_node_item(entry[1], entry[2], entry[3])
			set_icon(menu, menu.item_count - 1, entry[1])
		else:
			var found = registry.action(entry[0])
			if entry.size() > 2:
				menu.add_check_item(found.label, entry[1])
				checks[entry[1]] = entry[2]
			else:
				menu.add_item(found.label, entry[1])
			items[entry[1]] = entry[0]
			set_icon(menu, menu.item_count - 1, entry[0])
	var record := {"menu": menu, "items": items, "checks": checks}
	_menus.append(record)
	menu.id_pressed.connect(func(id: int):
		if items.has(id):
			run.call(items[id]))
	menu.about_to_popup.connect(refresh.bind(record))
	_sync_accelerators(record)
	refresh(record)


## Gives a menu item its icon (see EditorIcons.MENU_ICONS), sized to the text.
static func set_icon(menu: PopupMenu, index: int, key: String) -> void:
	if not Icons.MENU_ICONS.has(key):
		return
	menu.set_item_icon(index, Icons.icon(Icons.MENU_ICONS[key]))
	menu.set_item_icon_max_width(index, 16)
	menu.set_item_icon_modulate(index, Palette.text)


## Updates enabled and checked states (also done each time a menu opens),
## and tints the icons for the current theme.
func refresh(record: Dictionary) -> void:
	var menu: PopupMenu = record.menu
	for index in range(menu.item_count):
		if menu.get_item_icon(index) != null:
			menu.set_item_icon_modulate(index, Palette.text)
	for id in record.items:
		menu.set_item_disabled(menu.get_item_index(id), not registry.action(record.items[id]).can_run())
	for id in record.checks:
		menu.set_item_checked(menu.get_item_index(id), bool(record.checks[id].call()))


func refresh_all() -> void:
	for record in _menus:
		refresh(record)


## Shows each action's current shortcut (after the user rebinds one).
func sync_accelerators() -> void:
	for record in _menus:
		_sync_accelerators(record)


func _sync_accelerators(record: Dictionary) -> void:
	var menu: PopupMenu = record.menu
	for id in record.items:
		menu.set_item_accelerator(menu.get_item_index(id), registry.action(record.items[id]).keys())
