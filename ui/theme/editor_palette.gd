extends Resource
## Semantic editor colors, edited live through Edit > Theme.
## These are UI colors, independent of model materials and texture pixels.
## Consumers use a variable reference: Godot constant-folds const-resource reads.

@export var workspace := Color("17191d")
@export var chrome := Color("1e2126")
@export var surface := Color("282c33")
@export var hover := Color("333842")
@export var border := Color("101216")
@export var border_light := Color("414753")
@export var text := Color("d5d8df")
@export var muted := Color("969da9")
@export var disabled := Color("626a78")
@export var accent := Color("3b8eff")
@export var key_selection := Color("ffd866")
@export var motion_previous := Color("ff7f88")
@export var motion_future := Color("9bd7ff")
@export var selection := Color("293f60")
@export var checker_dark := Color("111418")
@export var checker_light := Color("15181d")
@export var grid_major := Color("414955")
@export var grid_minor := Color("292f38")
@export var axis_x := Color("ed596b")
@export var axis_y := Color("69cb75")
@export var axis_z := Color("3b8eff")


func apply_to(theme: Theme) -> void:
	# Style resources retain their scene-authored spacing, borders and radii.
	var backgrounds := {
		"chrome": ["MenuPanel/panel", "FooterPanel/panel", "SidebarPanel/panel", "AcceptDialog/panel", "PopupPanel/panel", "PanelContainer/panel", "Window/embedded_border", "Window/embedded_unfocused_border"],
		"surface": ["PopupMenu/panel", "LineEdit/normal", "TextureIDs/panel", "TexturePreview/panel", "TabBar/tab_selected"],
		"workspace": ["TextureLayers/panel"],
		"hover": ["Button/normal", "Button/disabled", "Button/hover", "OptionButton/normal", "OptionButton/hover", "TabBar/tab_hovered", "MenuButton/hover", "MenuButton/pressed", "MenuBar/hover", "MenuBar/pressed", "PopupMenu/hover", "CheckButton/hover", "CheckButton/hover_pressed", "ItemList/hovered"],
		"selection": ["Button/pressed", "Tree/selected", "Tree/selected_focus", "ItemList/selected", "ItemList/selected_focus"],
	}
	for role in backgrounds:
		for entry in backgrounds[role]:
			var parts: PackedStringArray = entry.split("/")
			var style := theme.get_stylebox(parts[1], parts[0]).duplicate() as StyleBoxFlat
			if style != null:
				style.bg_color = get(role)
				theme.set_stylebox(parts[1], parts[0], style)
	for type in theme.get_type_list():
		for name in theme.get_color_list(type):
			if "color" in name:
				var role := "disabled" if "disabled" in name else ("muted" if "unselected" in name else "text")
				theme.set_color(name, type, get(role))
		for name in theme.get_stylebox_list(type):
			var style := theme.get_stylebox(name, type) as StyleBoxFlat
			if style != null:
				style.border_color = accent if name in ["focus", "tab_focus", "tab_selected", "selected", "selected_focus", "pressed"] else border_light if type in ["Window", "TextureLayers"] else border
	for type in ["LineEdit", "TextEdit", "SpinBox", "OptionButton", "CheckButton"]:
		theme.set_color("font_color", type, text)
	for type in ["Button", "OptionButton", "CheckButton", "CheckBox", "LineEdit", "TextEdit", "ItemList", "Tree", "PopupMenu"]:
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "font_selected_color"]:
			theme.set_color(state, type, text)
		theme.set_color("font_disabled_color", type, disabled)
	for type in ["Button", "OptionButton", "CheckButton", "CheckBox"]:
		for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
			theme.set_color(state, type, text)
		theme.set_color("icon_disabled_color", type, disabled)
	theme.set_color("selection_color", "LineEdit", selection)
	theme.set_type_variation("MutedLabel", "Label")
	theme.set_color("font_color", "MutedLabel", muted)
	# Inspector panels: small muted section headings and field labels.
	theme.set_type_variation("SectionHeading", "Label")
	theme.set_color("font_color", "SectionHeading", muted)
	theme.set_font_size("font_size", "SectionHeading", 11)
	theme.set_type_variation("FieldLabel", "Label")
	theme.set_color("font_color", "FieldLabel", muted)
	theme.set_font_size("font_size", "FieldLabel", 12)
	preload("res://ui/shared/editor_metrics.gd").apply_to(theme)
	# Context menus need a distinct, shared highlight, including text-field menus.
	var menu_hover := theme.get_stylebox("hover", "PopupMenu").duplicate() as StyleBoxFlat
	menu_hover.bg_color = selection
	menu_hover.border_width_left = 2
	menu_hover.border_color = accent
	theme.set_stylebox("hover", "PopupMenu", menu_hover)
	theme.set_color("font_hover_color", "PopupMenu", text)
	# Changing visual state must not change the control's text/icon padding.
	for type in ["Button", "OptionButton", "CheckButton", "CheckBox", "MenuButton"]:
		var normal := theme.get_stylebox("normal", type)
		# CheckBox inherits Button at runtime, but Theme.get_stylebox does not
		# resolve that inheritance. Use the same base for every checkbox state.
		if type == "CheckBox":
			normal = theme.get_stylebox("normal", "Button").duplicate()
			theme.set_stylebox("normal", type, normal)
		for state in ["hover", "pressed", "hover_pressed", "disabled"]:
			var style := theme.get_stylebox(state, "Button" if type == "CheckBox" else type).duplicate() as StyleBox
			for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
				style.set_content_margin(side, normal.get_content_margin(side))
			theme.set_stylebox(state, type, style)
