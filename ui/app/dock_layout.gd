extends RefCounted
## Remembers the dock layout per editor mode in user://layout.cfg: which tab
## each dock shows, and the width of any split the user has dragged. Splits the
## user never dragged keep the editor's own sizing.

var config_path := "user://layout.cfg"
var splits: Dictionary = {}
var tabs: Dictionary = {}
var _config := ConfigFile.new()
var _dragged: Dictionary = {}


func bind(split_map: Dictionary, tab_map: Dictionary) -> void:
	splits = split_map
	tabs = tab_map
	for name in splits:
		splits[name].dragged.connect(func(_offset: int): _dragged[name] = true)


func load_config() -> void:
	_config = ConfigFile.new()
	_config.load(config_path)


## Applies what was stored for this mode. Tabs that are hidden in the mode
## are skipped.
func restore(mode: String) -> void:
	for name in tabs:
		var container: TabContainer = tabs[name]
		var index := int(_config.get_value(mode, "tab_" + name, -1))
		if index >= 0 and index < container.get_tab_count() and not container.is_tab_hidden(index):
			container.current_tab = index
	for name in splits:
		if _config.has_section_key(mode, "split_" + name):
			splits[name].split_offset = int(_config.get_value(mode, "split_" + name))
			_dragged[name] = true


## Stores this mode's tabs, and the splits the user has dragged.
func remember(mode: String) -> void:
	if mode.is_empty():
		return
	for name in tabs:
		_config.set_value(mode, "tab_" + name, tabs[name].current_tab)
	for name in splits:
		if _dragged.get(name, false):
			_config.set_value(mode, "split_" + name, splits[name].split_offset)
	_config.save(config_path)


## Forgets every stored layout. The caller puts the default sizes back.
func reset() -> void:
	_config = ConfigFile.new()
	_dragged.clear()
	if FileAccess.file_exists(config_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(config_path))
