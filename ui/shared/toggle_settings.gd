extends "res://ui/shared/toolbar_group.gd"
signal enabled_changed(enabled: bool)
@export var toggle_text := ""
@export var toggle_icon: Texture2D
@export var toggle_tooltip := ""
@export var settings_tooltip := "Settings"
@onready var enabled_toggle: Button = $Buttons/Toggle
@onready var settings_button: Button = $Buttons/Settings
@onready var popup: PopupPanel = $Popup
@onready var popup_content: VBoxContainer = $Popup/Margin/Content


func _ready() -> void:
	enabled_toggle.text = toggle_text
	enabled_toggle.icon = toggle_icon
	enabled_toggle.tooltip_text = toggle_tooltip
	settings_button.tooltip_text = settings_tooltip
	super()
	settings_button.pressed.connect(open_settings)
	enabled_toggle.toggled.connect(func(value: bool): enabled_changed.emit(value))


func set_enabled(value: bool) -> void:
	enabled_toggle.set_pressed_no_signal(value)


func refresh_style() -> void:
	super()
	var background := StyleBoxFlat.new()
	background.bg_color = Color(Palette.chrome, 1.0)
	background.border_color = Palette.border_light
	background.set_border_width_all(1)
	popup.add_theme_stylebox_override("panel", background)


func is_enabled() -> bool:
	return enabled_toggle.button_pressed


func set_editable(value: bool) -> void:
	enabled_toggle.disabled = not value
	settings_button.disabled = not value


func open_settings() -> void:
	popup.reset_size()
	popup.position = Vector2i(settings_button.get_screen_position() + Vector2(0, settings_button.size.y))
	popup.popup()
