extends RefCounted

const ROW_HEIGHT := 26
const LIST_FONT_SIZE := 13
const INDENT_SPACES := 4


static func apply_to(theme: Theme) -> void:
	var font := theme.get_default_font()
	if font == null:
		font = ThemeDB.fallback_font
	var font_height := ceili(font.get_height(LIST_FONT_SIZE))
	theme.set_font_size("font_size", "Tree", LIST_FONT_SIZE)
	theme.set_font_size("font_size", "ItemList", LIST_FONT_SIZE)
	# Tree adds spacing above and below; ItemList adds it once per row.
	theme.set_constant("v_separation", "Tree", maxi((ROW_HEIGHT - font_height) / 2, 0))
	theme.set_constant("v_separation", "ItemList", maxi(ROW_HEIGHT - font_height, 0))
	# The mode bar's tabs are shorter than the docks' tabs.
	theme.set_type_variation("ModeTabs", "TabBar")
	for state in ["tab_selected", "tab_unselected", "tab_hovered", "tab_focus", "tab_disabled"]:
		if theme.has_stylebox(state, "TabBar"):
			var tab := theme.get_stylebox(state, "TabBar").duplicate() as StyleBox
			tab.content_margin_top = 6
			tab.content_margin_bottom = 6
			theme.set_stylebox(state, "ModeTabs", tab)
	theme.set_type_variation("TransportButton", "Button")
	theme.set_font_size("font_size", "TransportButton", LIST_FONT_SIZE)
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var style := theme.get_stylebox(state, "Button").duplicate() as StyleBox
		style.content_margin_left = 8
		style.content_margin_right = 8
		theme.set_stylebox(state, "TransportButton", style)
