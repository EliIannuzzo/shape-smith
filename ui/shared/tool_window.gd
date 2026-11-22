extends Window

const SCREEN_MARGIN := 16
const TITLE_BAR_HEIGHT := 24
const DEFAULT_SIZE_RESERVE := Vector2i(48, 64)
const MAX_SIZE_RESERVE := Vector2i(32, 48)

@export var default_size := Vector2i(480, 520)
var host_window: Window


func bind_window(host: Window, editor_theme: Theme) -> void:
	host_window = host
	theme = editor_theme


func _ready() -> void:
	hide()
	close_requested.connect(hide)


func open_window() -> void:
	var available := _usable_rect()
	var desired := Vector2i(mini(default_size.x, available.size.x - DEFAULT_SIZE_RESERVE.x), mini(default_size.y, available.size.y - DEFAULT_SIZE_RESERVE.y))
	max_size = Vector2i(available.size.x - MAX_SIZE_RESERVE.x, available.size.y - MAX_SIZE_RESERVE.y)
	size = desired
	popup_centered(desired)
	_fit_to_screen.call_deferred()


func _usable_rect() -> Rect2i:
	if is_embedded():
		return Rect2i(Vector2i.ZERO, get_tree().root.size)

	var host := host_window if host_window != null else get_tree().root
	return DisplayServer.screen_get_usable_rect(host.current_screen)


func _fit_to_screen() -> void:
	if not visible:
		return

	var available := _usable_rect().grow(-SCREEN_MARGIN)
	size = Vector2i(mini(size.x, available.size.x), mini(size.y, available.size.y - TITLE_BAR_HEIGHT))
	position = Vector2i(clampi(position.x, available.position.x, available.end.x - size.x), clampi(position.y, available.position.y + TITLE_BAR_HEIGHT, available.end.y - size.y))


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		hide()
		set_input_as_handled()
