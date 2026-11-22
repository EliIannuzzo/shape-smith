extends PopupPanel
## View → Lighting…: the environment the game shader previews faces in. Sun
## height and direction, time of day, weather, shadows and a wind preview.
## These are viewing settings: they never change the shape, and they are
## remembered in user://lighting.cfg.

const CONFIG_PATH := "user://lighting.cfg"
const Palette = preload("res://ui/theme/editor_palette.tres")
const TIMES := ["day", "dusk", "night"]
const WEATHER := ["clear", "overcast", "rain"]

var library
var config_path := CONFIG_PATH
var sun_height: HSlider
var sun_angle: HSlider
var time_of_day: OptionButton
var weather: OptionButton
var shadows: CheckBox
var wind: CheckBox
var wind_speed: HSlider
var _syncing := false


func _init() -> void:
	name = "LightingPanel"
	title = "Lighting"
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	margin.add_child(grid)
	time_of_day = _option(grid, "Time of day", ["Day", "Dusk", "Night"], "Night keeps only glowing faces bright, to judge glow in the dark.")
	weather = _option(grid, "Weather", ["Clear", "Overcast", "Rain"], "Cloud and rain dim the daylight.")
	sun_height = _slider(grid, "Sun height", -10, 90, 1, "How high the sun stands, in degrees. Faces turned towards it are brightest.")
	sun_angle = _slider(grid, "Sun direction", 0, 359, 1, "Which way the sun shines from, in degrees around the model.")
	shadows = _check(grid, "Shadows", "With the game's shadows on, faces turned away from the sun are a little darker.")
	wind = _check(grid, "Wind preview", "Animate faces that have a wind mode, as the game sways plants and leaves.")
	wind_speed = _slider(grid, "Wind speed", 0, 1, 0.05, "From still air to a storm.")
	grid.add_child(Control.new())
	var reset := Button.new()
	reset.text = "Reset"
	reset.pressed.connect(reset_environment)
	grid.add_child(reset)
	refresh_style()
	Palette.changed.connect(refresh_style)


## An opaque panel: the theme's chrome is translucent over the 3D view.
func refresh_style() -> void:
	var background := StyleBoxFlat.new()
	background.bg_color = Color(Palette.chrome, 1.0)
	background.border_color = Palette.border_light
	background.set_border_width_all(1)
	add_theme_stylebox_override("panel", background)


func bind(target) -> void:
	library = target
	var config := ConfigFile.new()
	if config.load(config_path) == OK:
		var values := {}
		for key in library.default_environment():
			if config.has_section_key("environment", key):
				values[key] = config.get_value("environment", key)
		library.set_environment(_valid(values))
	sync()


## Opens below the given screen point, right-aligned to it.
func open(top_right: Vector2i) -> void:
	sync()
	reset_size()
	position = top_right - Vector2i(size.x, 0)
	popup()


func sync() -> void:
	if library == null:
		return

	_syncing = true
	var environment: Dictionary = library.environment
	time_of_day.select(maxi(0, TIMES.find(environment.time)))
	weather.select(maxi(0, WEATHER.find(environment.weather)))
	sun_height.value = environment.sun_height
	sun_angle.value = environment.sun_angle
	shadows.button_pressed = environment.shadows
	wind.button_pressed = environment.wind
	wind_speed.value = environment.wind_speed
	wind_speed.editable = environment.wind
	_syncing = false


func change(key: String, value: Variant) -> void:
	if _syncing or library == null:
		return

	library.set_environment(_valid({key: value}))
	_save()
	sync()


func reset_environment() -> void:
	library.set_environment(library.default_environment())
	_save()
	sync()


func _save() -> void:
	var config := ConfigFile.new()
	for key in library.environment:
		config.set_value("environment", key, library.environment[key])
	config.save(config_path)


## Keeps only values of the right kind and range, so a hand-edited file cannot
## break the preview.
func _valid(values: Dictionary) -> Dictionary:
	var result := {}
	for key in values:
		var value: Variant = values[key]
		match key:
			"time":
				if str(value) in TIMES: result[key] = str(value)
			"weather":
				if str(value) in WEATHER: result[key] = str(value)
			"sun_height":
				if value is float or value is int: result[key] = clampf(value, -10.0, 90.0)
			"sun_angle":
				if value is float or value is int: result[key] = fposmod(value, 360.0)
			"wind_speed":
				if value is float or value is int: result[key] = clampf(value, 0.0, 1.0)
			"shadows", "wind":
				if value is bool: result[key] = value
	return result


func _label(grid: GridContainer, text: String, tip: String) -> void:
	var label := Label.new()
	label.text = text
	label.tooltip_text = tip
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	grid.add_child(label)


func _option(grid: GridContainer, text: String, items: Array, tip: String) -> OptionButton:
	_label(grid, text, tip)
	var option := OptionButton.new()
	option.tooltip_text = tip
	for item in items:
		option.add_item(item)
	var values: Array = TIMES if text == "Time of day" else WEATHER
	var key := "time" if text == "Time of day" else "weather"
	option.item_selected.connect(func(index: int): change(key, values[index]))
	grid.add_child(option)
	return option


func _slider(grid: GridContainer, text: String, low: float, high: float, step_value: float, tip: String) -> HSlider:
	_label(grid, text, tip)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = step_value
	slider.custom_minimum_size.x = 160
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.tooltip_text = tip
	var key := text.to_lower().replace(" ", "_").replace("sun_direction", "sun_angle")
	slider.value_changed.connect(func(value: float): change(key, value))
	grid.add_child(slider)
	return slider


func _check(grid: GridContainer, text: String, tip: String) -> CheckBox:
	_label(grid, text, tip)
	var box := CheckBox.new()
	box.tooltip_text = tip
	var key := "wind" if text == "Wind preview" else text.to_lower()
	box.toggled.connect(func(pressed: bool): change(key, pressed))
	grid.add_child(box)
	return box
