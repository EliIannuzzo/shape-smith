extends RefCounted
## An ordered set of selected uids (elements, attachment points, faces or keys)
## plus the active item. The active item is what the inspector shows; the set
## is what group operations act on.

signal changed

var items: Array[String] = []
var active := ""


func is_empty() -> bool:
	return items.is_empty()


func has(uid: String) -> bool:
	return items.has(uid)


## Plain click: select only this item. An empty uid clears the selection.
func select(uid: String) -> void:
	set_items([] if uid.is_empty() else [uid], uid)


## Ctrl+click: add or remove one item.
func toggle(uid: String) -> void:
	var next := items.duplicate()
	if next.has(uid):
		next.erase(uid)
		set_items(next, active if active != uid else ("" if next.is_empty() else next.back()))
	else:
		next.append(uid)
		set_items(next, uid)


func add(uid: String) -> void:
	if not items.has(uid):
		var next := items.duplicate()
		next.append(uid)
		set_items(next, uid)


## Shift+click: select everything between the active item and uid in `order`
## (outliner order), adding to the current selection.
func select_range(order: Array, uid: String) -> void:
	var from := order.find(active)
	var to := order.find(uid)
	if from < 0 or to < 0:
		select(uid)
		return
	var next := items.duplicate()
	for i in range(mini(from, to), maxi(from, to) + 1):
		if not next.has(order[i]):
			next.append(order[i])
	set_items(next, uid)


## Ctrl+A: select every item in `order`, keeping the active item if possible.
func select_all(order: Array) -> void:
	set_items(order, active if order.has(active) else ("" if order.is_empty() else order[0]))


func clear() -> void:
	set_items([], "")


## Drops items that no longer exist, for example after an undo removed them.
func prune(exists: Callable) -> void:
	var kept := items.filter(exists)
	if kept.size() != items.size():
		set_items(kept, active if kept.has(active) else ("" if kept.is_empty() else kept.back()))


func set_items(uids: Array, active_uid := "") -> void:
	var next: Array[String] = []
	for uid in uids:
		if not str(uid).is_empty() and not next.has(str(uid)):
			next.append(str(uid))
	if not active_uid.is_empty() and not next.has(active_uid):
		next.append(active_uid)
	if next == items and active_uid == active:
		return
	items = next
	active = active_uid
	changed.emit()
