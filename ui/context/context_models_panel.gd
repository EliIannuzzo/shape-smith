extends Node
## File → Shapes…: the shapes shown alongside the edited one (VSMC2's shape
## manager). Lists every root, this shape's first; for an additional shape it
## sets visibility, opacity, colour and which clip it plays; for any root it
## sets the origin: what the root follows (nothing, an element or an
## attachment point) and its item transform.

const Origins = preload("res://core/model/shape_origins.gd")
const Vector3Field = preload("res://ui/shared/vector3_field.tscn")
## Searchable dropdowns for the long lists (elements, clips).
const SearchChoice = preload("res://ui/shared/search_choice.gd")

var editor_theme: Theme
var viewport_view
var details_panel
var edit_history
var document_path: Callable
var save_document: Callable
var load_document: Callable
var save_then_continue: Callable
## The main shape's selected clip code, for the clip mapping.
var main_clip: Callable

var system
var dialog: Window
var picker: FileDialog
var context_prompt: ConfirmationDialog
var list: ItemList
var keys: Array = []
var selected_key := ""
var title: Label
var display: HBoxContainer
var enabled_toggle: CheckBox
var opacity: SpinBox
var hide_textures: CheckBox
var color: OptionButton
var clips: HBoxContainer
var unique_clips: CheckBox
var clip_label: Label
var clip_choice: SearchChoice
var follows: SearchChoice
var mount_offset: CheckBox
var item_fields: Dictionary = {}
var remove_button: Button
var open_button: Button
var message: Label
var updating := false
var follow_choices: Array = []
var step_input: LineEdit
var step_choices: SearchChoice
var step_node: Node3D
var pending_index := -1
var committing_step := false


func bind_services(view: Node, details: Control, history: Node) -> void:
	viewport_view = view
	details_panel = details
	edit_history = history


func bind_document_actions(get_path: Callable, save: Callable, load_shape: Callable, save_then := Callable()) -> void:
	document_path = get_path
	save_document = save
	load_document = load_shape
	save_then_continue = save_then


func set_editor_theme(theme_resource: Theme) -> void:
	editor_theme = theme_resource
	for window in [dialog, picker, context_prompt]:
		if is_instance_valid(window):
			window.theme = theme_resource


func _ready() -> void:
	dialog = $Dialog
	picker = $Picker
	context_prompt = $ContextPrompt
	dialog.bind_window(get_window(), editor_theme)
	set_editor_theme(editor_theme)
	_build($Dialog/Panel/Margin/Layout)
	picker.file_selected.connect(func(path: String):
		var error: String = system.add_model(path)
		message.text = error)
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			system.highlight(""))
	system.refreshed.connect(refresh)
	context_prompt.add_button("Discard and Open", true, "discard")
	context_prompt.confirmed.connect(_save_before_open)
	context_prompt.custom_action.connect(func(action: String):
		if action == "discard":
			context_prompt.hide()
			_open_pending())
	_setup_step_parent_editor()


func _build(layout: VBoxContainer) -> void:
	layout.add_theme_constant_override("separation", 8)
	layout.add_child(_note("Show other shape files around the one you are editing: a body under armour, a rider on a mount, a backdrop. They are shown here and remembered in this file; their own files are not changed."))
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 16)
	layout.add_child(columns)

	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 260
	columns.add_child(left)
	list = ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.item_selected.connect(func(index: int):
		if keys[index] != "":
			select(keys[index]))
	left.add_child(list)
	var actions := HBoxContainer.new()
	left.add_child(actions)
	var add := Button.new()
	add.text = "Add Shape…"
	add.pressed.connect(func(): picker.popup_centered_ratio(0.8))
	actions.add_child(add)
	remove_button = Button.new()
	remove_button.text = "Remove"
	remove_button.tooltip_text = "Remove the selected shape (all of its roots)"
	remove_button.pressed.connect(remove_selected)
	actions.add_child(remove_button)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	columns.add_child(right)
	title = Label.new()
	title.add_theme_font_size_override("font_size", 15)
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	right.add_child(title)

	display_section = _section(right, "Display", "How this shape looks next to yours.")
	display = HBoxContainer.new()
	display_section.add_child(display)
	enabled_toggle = _check(display, "Shown", func(value: bool): _change("enabled", value if value else null))
	display.add_child(_label("Opacity"))
	opacity = SpinBox.new()
	opacity.min_value = 0.05
	opacity.max_value = 1
	opacity.step = 0.05
	opacity.value_changed.connect(func(value: float): _change("opacity", value if not is_equal_approx(value, 1.0) else null))
	display.add_child(opacity)
	hide_textures = _check(display, "Solid", func(value: bool): _change("hideTextures", value if value else null))
	color = OptionButton.new()
	for name_value in ["Grey", "Red", "Green", "Blue", "Yellow", "Purple"]:
		color.add_item(name_value)
	color.item_selected.connect(func(index: int): _change("flatColorIndex", index if index > 0 else null))
	display.add_child(color)

	clips_section = _section(right, "Animation", "While you preview a clip, this shape plays its clip with the same code. Tick Own clips to choose a different one.")
	clips = HBoxContainer.new()
	clips_section.add_child(clips)
	unique_clips = _check(clips, "Own clips", func(value: bool): _change("useUniqueAnimations", value if value else null))
	unique_clips.tooltip_text = "Off: plays the clip with the same code as the edited shape's clip. On: plays the clip you choose for it."
	clip_label = _label("")
	clips.add_child(clip_label)
	clip_choice = SearchChoice.new()
	clip_choice.placeholder = "Search clips"
	clip_choice.custom_minimum_size.x = 180
	clip_choice.item_selected.connect(_choose_clip)
	clips.add_child(clip_choice)

	var attach := _section(right, "Attach to", "Nothing: it stays where its file puts it. An element: it moves with that part, also while animated. A point: it sits on an attachment point, turned the way the point is.")
	var follow_row := HBoxContainer.new()
	attach.add_child(follow_row)
	# Attachment points (usually a few) are listed first, then every element,
	# in a popup with a search box.
	follows = SearchChoice.new()
	follows.placeholder = "Search points and elements"
	follows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	follows.item_selected.connect(func(_index: int): _commit_origin())
	follow_row.add_child(follows)
	mount_offset = _check(follow_row, "Mount offset", func(_value: bool): _commit_origin())
	mount_offset.tooltip_text = "Measure the attachment point from the block's centre (8, 0, 8), as mounts do"
	var adjust := _section(right, "Adjust", "Move, turn and scale it from where it is attached, like the game's item and seat transforms.")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	adjust.add_child(grid)
	for field in [["itemTranslation", "Translation (blocks)", Vector3.ZERO, 0.0625], ["itemRotation", "Rotation (°)", Vector3.ZERO, 1.0],
			["itemScaleXYZ", "Scale", Vector3.ONE, 0.05], ["itemOrigin", "Pivot (blocks)", Origins.DEFAULT_PIVOT, 0.0625]]:
		var input = Vector3Field.instantiate()
		input.label_text = field[1]
		# A fine step, so values from other tools are never rounded; the arrows
		# still move in useful amounts.
		input.increment = 0.0001
		input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(input)
		for spin in input.inputs:
			spin.custom_arrow_step = field[3]
		input.axis_edited.connect(func(_axis: int, _value: float): _commit_origin())
		item_fields[field[0]] = input

	var footer := HBoxContainer.new()
	layout.add_child(footer)
	open_button = Button.new()
	open_button.text = "Open in Context…"
	open_button.tooltip_text = "Edit the selected shape, with this one shown around it"
	open_button.pressed.connect(open_in_context)
	footer.add_child(open_button)
	var frame := Button.new()
	frame.text = "Frame All"
	frame.pressed.connect(func(): system.frame_all())
	footer.add_child(frame)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	var done := Button.new()
	done.text = "Done"
	done.pressed.connect(dialog.hide)
	footer.add_child(done)
	message = Label.new()
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(message)


var display_section: VBoxContainer
var clips_section: VBoxContainer
var own_note: Label


## A titled group of settings with a line saying what it is for.
func _section(parent: Control, heading: String, help: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)
	box.add_child(HSeparator.new())
	var label := Label.new()
	label.text = heading
	label.add_theme_font_size_override("font_size", 13)
	box.add_child(label)
	box.add_child(_note(help))
	return box


func _note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 11)
	label.modulate = Color(1, 1, 1, 0.7)
	return label


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _check(parent: Control, text: String, handler: Callable) -> CheckBox:
	var box := CheckBox.new()
	box.text = text
	box.toggled.connect(func(value: bool):
		if not updating:
			handler.call(value))
	parent.add_child(box)
	return box


func open() -> void:
	refresh()
	dialog.open_window()


func select(key: String) -> void:
	selected_key = key
	system.highlight(key)
	refresh()


func refresh() -> void:
	if not is_node_ready() or dialog == null:
		return
	updating = true
	list.clear()
	keys.clear()
	var roots: Array = system.roots()
	var others := roots.filter(func(each): return each.index >= 0)
	for group in [["THIS SHAPE", roots.filter(func(each): return each.index < 0)], ["OTHER SHAPES", others]]:
		var header := list.add_item(group[0] + ("  (%d)" % group[1].size() if group[0] == "OTHER SHAPES" else ""))
		list.set_item_selectable(header, false)
		list.set_item_disabled(header, true)
		keys.append("")
		for item in group[1]:
			var shown := true
			if item.index >= 0:
				shown = system.entries()[item.index].get("enabled", false) == true
			var label: String = ("  " + item.name) if item.index < 0 else ("  %s %s" % ["●" if shown else "○", item.label])
			if Origins.kind(item.origin) != "transform":
				label += "  ⇢ attached"
			var row := list.add_item(label)
			list.set_item_tooltip(row, "Hidden (tick Shown to show it)" if item.index >= 0 and not shown else "")
			if item.index >= 0 and item.node == null:
				list.set_item_custom_fg_color(row, Color(0.9, 0.5, 0.4))
				list.set_item_tooltip(row, "Its file could not be found")
			keys.append(item.key)
			if item.key == selected_key:
				list.select(row)
	if others.is_empty():
		var hint := list.add_item("  None yet: Add Shape… picks a .json file")
		list.set_item_selectable(hint, false)
		list.set_item_disabled(hint, true)
		keys.append("")
	var item: Dictionary = {}
	for each in roots:
		if each.key == selected_key:
			item = each
	var entry: Dictionary = system.entries()[item.index] if not item.is_empty() and item.index >= 0 else {}
	title.text = "Select a part in the list" if item.is_empty() else ("This shape › " + item.name if item.index < 0 else item.label)
	# Display and clips belong to other shapes; this shape's parts only attach.
	display_section.visible = item.is_empty() or item.index >= 0
	clips_section.visible = item.is_empty() or item.index >= 0
	for control in [enabled_toggle, hide_textures, unique_clips]:
		control.disabled = entry.is_empty()
	opacity.editable = not entry.is_empty()
	color.disabled = entry.is_empty()
	remove_button.disabled = entry.is_empty()
	open_button.disabled = entry.is_empty() or system.record_for(item.index).is_empty()
	enabled_toggle.button_pressed = entry.get("enabled", false) == true
	opacity.set_value_no_signal(float(entry.get("opacity", 1)))
	hide_textures.button_pressed = entry.get("hideTextures", false) == true
	color.select(clampi(int(entry.get("flatColorIndex", 0)), 0, 5))
	_refresh_clips(item, entry)
	_refresh_origin(item)
	message.text = "\n".join(system.warnings())
	updating = false
	_inspect_step(viewport_view.selected_node)


func _refresh_clips(item: Dictionary, entry: Dictionary) -> void:
	unique_clips.button_pressed = entry.get("useUniqueAnimations", false) == true
	var code: String = main_clip.call() if main_clip.is_valid() else ""
	var record: Dictionary = system.record_for(item.index) if not entry.is_empty() else {}
	clip_label.text = "While %s plays:" % (code if not code.is_empty() else "no clip")
	clip_choice.clear()
	clip_choice.add_item("Nothing")
	clip_choice.select(0)
	var current := Origins.mapped_clip(entry, code, _main_codes(), record.get("codes", [])) if not entry.is_empty() else ""
	for reference_code in record.get("codes", []):
		clip_choice.add_item(reference_code)
		if reference_code == current:
			clip_choice.select(clip_choice.item_count - 1)
	clip_choice.disabled = entry.is_empty() or code.is_empty() or entry.get("useUniqueAnimations", false) != true


func _main_codes() -> Array:
	var codes: Array = []
	var animations: Variant = viewport_view.shape_data.get("animations", [])
	for clip in animations if animations is Array else []:
		codes.append(str(clip.get("code", clip.get("name", ""))) if clip is Dictionary else "")
	return codes


func _choose_clip(index: int) -> void:
	var item: Dictionary = system.root(selected_key)
	if updating or item.is_empty() or item.index < 0:
		return
	var record: Dictionary = system.record_for(item.index)
	var reference_code: String = clip_choice.get_item_text(index) if index > 0 else ""
	var pairs := Origins.with_mapping(system.entries()[item.index], main_clip.call(), reference_code, _main_codes(), record.get("codes", []))
	_change("animationPlaybackMapping", pairs if not pairs.is_empty() else null)


func _refresh_origin(item: Dictionary) -> void:
	follows.clear()
	follow_choices = [{}]
	follows.add_item("Nothing")
	follows.disabled = item.is_empty()
	mount_offset.disabled = true
	for field in item_fields.values():
		for input in field.inputs:
			input.editable = not item.is_empty()
	if item.is_empty():
		return
	var origin: Dictionary = item.origin if item.origin is Dictionary else {}
	var kind := Origins.kind(origin)
	var code := Origins.element_code(origin)
	var selected := 0
	# A root's own elements, and anything that already follows it, show as
	# disabled: following them would make a loop.
	for choice in system.point_choices():
		follow_choices.append(choice)
		follows.add_item(choice.label, "Attachment points")
		if not system.can_follow(item.key, choice.shape, choice.element):
			follows.set_item_disabled(follows.item_count - 1, true)
		if kind == "attachment" and choice.code == str(origin.get("apCode", "")) and choice.shape.to_lower() == code.shapePath.to_lower():
			selected = follows.item_count - 1
	for choice in system.element_choices():
		follow_choices.append(choice)
		follows.add_item(choice.label, "Elements")
		if not system.can_follow(item.key, choice.shape, choice.element):
			follows.set_item_disabled(follows.item_count - 1, true)
		if kind == "element" and choice.shape.to_lower() == code.shapePath.to_lower() and choice.element.to_lower() == code.element.to_lower():
			selected = follows.item_count - 1
	if selected == 0 and kind != "transform":
		follows.add_item("Missing: " + (str(origin.get("apCode")) if kind == "attachment" else code.element))
		follow_choices.append({"missing": true})
		selected = follows.item_count - 1
	follows.select(selected)
	mount_offset.disabled = kind != "attachment"
	mount_offset.button_pressed = origin.get("useMountOffset", false) == true
	item_fields.itemTranslation.set_vector(Origins.vector(origin.get("itemTranslation"), Vector3.ZERO))
	item_fields.itemRotation.set_vector(Origins.vector(origin.get("itemRotation"), Vector3.ZERO))
	item_fields.itemScaleXYZ.set_vector(Origins.vector(origin.get("itemScaleXYZ"), Vector3.ONE))
	item_fields.itemOrigin.set_vector(Origins.vector(origin.get("itemOrigin"), Origins.DEFAULT_PIVOT))


## Writes the origin the editor shows as one undo step.
func _commit_origin() -> void:
	var item: Dictionary = system.root(selected_key)
	if updating or item.is_empty():
		return
	var previous: Dictionary = item.origin if item.origin is Dictionary else {}
	var choice: Dictionary = follow_choices[maxi(follows.selected, 0)]
	var values := {}
	for key in item_fields:
		values[key] = Origins.vector_data(item_fields[key].get_vector())
	if choice.get("missing", false):
		for key in ["rootElement", "apCode", "useMountOffset"]:
			if previous.has(key):
				values[key] = previous[key]
	elif choice.has("code"):
		values.rootElement = {"shapePath": choice.shape, "element": choice.element}
		values.apCode = choice.code
		values.useMountOffset = mount_offset.button_pressed
	elif choice.has("element"):
		values.rootElement = {"shapePath": choice.shape, "element": choice.element}
	system.set_origin(selected_key, values)


func _change(field: String, value: Variant) -> void:
	var item: Dictionary = system.root(selected_key)
	if not updating and not item.is_empty() and item.index >= 0:
		system.change(item.index, field, value)


func remove_selected() -> void:
	var item: Dictionary = system.root(selected_key)
	if item.is_empty() or item.index < 0:
		return
	system.remove_file(item.shape)
	selected_key = ""
	system.highlight("")


func _save_before_open() -> void:
	if save_then_continue.is_valid():
		save_then_continue.call(_open_pending)
	elif save_document.call():
		_open_pending()


func open_in_context() -> void:
	var item: Dictionary = system.root(selected_key)
	if item.is_empty() or item.index < 0 or system.record_for(item.index).is_empty():
		message.text = "Select a shape that loaded."
		return
	pending_index = item.index
	edit_history.flush_pending.emit()
	if edit_history.is_dirty() or document_path.call().is_empty():
		context_prompt.popup_centered()
	else:
		_open_pending()


func _open_pending() -> void:
	if pending_index < 0:
		return
	var index := pending_index
	pending_index = -1
	var path: String = system.begin_context(index)
	if path.is_empty():
		return
	dialog.hide()
	load_document.call(path)
	selected_key = ""
	open()


# --- Step parent (game data, in the element inspector) ---------------------------------

func _setup_step_parent_editor() -> void:
	var step_section: VBoxContainer = $StepParent
	step_input = step_section.get_node("Name")
	# A searchable list in place of the scene's dropdown: shapes can have
	# hundreds of elements.
	var old: Control = step_section.get_node("Choices")
	step_choices = SearchChoice.new()
	step_choices.placeholder = "Search elements"
	old.add_sibling(step_choices)
	old.free()
	step_choices.name = "Choices"
	step_section.reparent(details_panel.content)
	step_input.text_submitted.connect(func(_value: String): _commit_step_input())
	step_input.focus_exited.connect(_commit_step_input)
	edit_history.flush_pending.connect(_commit_step_input)
	viewport_view.selection_changing.connect(_commit_step_input)
	step_choices.item_selected.connect(func(index: int):
		system.set_step_parent(step_node, str(step_choices.get_item_metadata(index))))
	viewport_view.selection_changed.connect(_inspect_step)


func _inspect_step(node: Node3D) -> void:
	step_node = node
	var valid: bool = is_instance_valid(node) and viewport_view.models.get_child_count() > 0 and node.get_parent() == viewport_view.models.get_child(0)
	step_input.editable = valid
	step_input.text = str(node.get_meta("shape_element").get("stepParentName", "")) if valid else ""
	step_choices.clear()
	step_choices.add_item("No step parent")
	step_choices.set_item_metadata(0, "")
	step_choices.select(0)
	for name_value in system.reference_names():
		step_choices.add_item(name_value)
		step_choices.set_item_metadata(step_choices.item_count - 1, name_value)
	step_choices.disabled = not valid
	if valid and not step_input.text.is_empty():
		var found := false
		for i in range(step_choices.item_count):
			if step_choices.get_item_metadata(i) == step_input.text:
				step_choices.select(i)
				found = true
		step_input.tooltip_text = "" if found else "No element with this name in the shown shapes; the name is kept."


func _commit_step_input() -> void:
	if committing_step or not step_input.editable or not is_instance_valid(step_node):
		return
	committing_step = true
	system.set_step_parent(step_node, step_input.text)
	committing_step = false
