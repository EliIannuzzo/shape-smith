extends "res://ui/shared/tool_window.gd"
## The user guide (docs/user-guide.md), read in the app: a searchable list of
## sections on the left, the chosen section on the right.

const GuideMarkdown = preload("res://core/docs/guide_markdown.gd")
const GUIDE_PATH := "res://docs/user-guide.md"
static var Palette = preload("res://ui/theme/editor_palette.tres")

var guide: Dictionary = {}
var search: LineEdit
var contents: Tree
var page: RichTextLabel
var shown := -1


func _init() -> void:
	title = "User Guide"
	default_size = Vector2i(1040, 760)
	min_size = Vector2i(560, 360)
	wrap_controls = false


func _ready() -> void:
	super()
	var background := PanelContainer.new()
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Palette.chrome
	background.add_theme_stylebox_override("panel", style)
	add_child(background)
	var split := HSplitContainer.new()
	split.split_offset = 250
	background.add_child(split)

	var side := VBoxContainer.new()
	side.custom_minimum_size.x = 200
	var side_margin := _margin(side, 8)
	split.add_child(side_margin)
	search = LineEdit.new()
	search.placeholder_text = "Search the guide"
	search.clear_button_enabled = true
	search.text_changed.connect(func(_text: String): _fill_contents())
	search.text_submitted.connect(func(_text: String): _open_first())
	side.add_child(search)
	contents = Tree.new()
	contents.hide_root = true
	contents.size_flags_vertical = Control.SIZE_EXPAND_FILL
	contents.item_selected.connect(_on_item_selected)
	side.add_child(contents)

	page = RichTextLabel.new()
	page.bbcode_enabled = true
	page.selection_enabled = true
	page.context_menu_enabled = true
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("paragraph_separation", 8)
	page.add_theme_font_size_override("normal_font_size", 14)
	page.add_theme_font_size_override("bold_font_size", 14)
	page.meta_clicked.connect(func(meta: Variant): OS.shell_open(str(meta)))
	split.add_child(_margin(page, 16))
	load_guide()


func _margin(child: Control, amount: int) -> MarginContainer:
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, amount)
	margin.add_child(child)
	return margin


## Reads and parses the guide. False when the file is missing.
func load_guide() -> bool:
	if not FileAccess.file_exists(GUIDE_PATH):
		guide = {}
		page.text = "The user guide was not found (docs/user-guide.md)."
		return false
	guide = GuideMarkdown.parse(FileAccess.get_file_as_string(GUIDE_PATH), Palette.motion_future)
	_fill_contents()
	if not guide.sections.is_empty():
		show_section(0)
	return true


func open_guide() -> void:
	open_window()
	search.grab_focus.call_deferred()


## Fills the contents with sections (and their subsections) matching the search.
func _fill_contents() -> void:
	contents.clear()
	var root := contents.create_item()
	var query := search.text.strip_edges().to_lower()
	if guide.is_empty():
		return
	for index in range(guide.sections.size()):
		var section: Dictionary = guide.sections[index]
		if not query.is_empty() and not query in section.text:
			continue
		var item := contents.create_item(root)
		item.set_text(0, section.title)
		item.set_metadata(0, [index, -1])
		for sub in range(section.subsections.size()):
			var child := contents.create_item(item)
			child.set_text(0, section.subsections[sub].title)
			child.set_metadata(0, [index, sub])
			child.set_custom_color(0, Palette.muted)
		item.collapsed = query.is_empty() and index != shown


func _open_first() -> void:
	var first := contents.get_root().get_first_child() if contents.get_root() != null else null
	if first != null:
		first.select(0)


func _on_item_selected() -> void:
	var item := contents.get_selected()
	if item == null:
		return
	var target: Array = item.get_metadata(0)
	show_section(target[0], target[1])


## Shows a section, scrolled to one of its subsections (or the top).
func show_section(index: int, subsection := -1) -> void:
	if guide.is_empty() or index < 0 or index >= guide.sections.size():
		return
	var section: Dictionary = guide.sections[index]
	if index != shown:
		shown = index
		page.text = section.bbcode
	if subsection >= 0 and subsection < section.subsections.size():
		page.scroll_to_paragraph(section.subsections[subsection].paragraph)
	else:
		page.scroll_to_line(0)


## The index of the section with this title, or -1.
func find_section(title_value: String) -> int:
	for index in range(guide.get("sections", []).size()):
		if guide.sections[index].title == title_value:
			return index
	return -1
