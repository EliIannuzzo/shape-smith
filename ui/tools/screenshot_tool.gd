extends "res://ui/shared/tool_window.gd"
static var Palette = preload("res://ui/theme/editor_palette.tres")
const RESOLUTIONS := [Vector2i.ZERO, Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160), Vector2i(1024, 1024), Vector2i(2048, 2048)]
const ModelViewport = preload("res://ui/viewport/model_viewport.gd")
const Playback = preload("res://ui/animation/animation_workspace.gd")
var source_view: ModelViewport
var playback: Playback
var image: Image
var capturing := false
@onready var preview: TextureRect = %Preview
@onready var message: Label = %Message
@onready var save_dialog: FileDialog = %SaveDialog
@onready var resolution: OptionButton = %Resolution


func bind_scene(view: ModelViewport, player: Playback) -> void:
	source_view = view
	playback = player


func _ready() -> void:
	super()
	%Close.pressed.connect(hide)
	%Capture.pressed.connect(capture)
	for output_size in RESOLUTIONS:
		resolution.add_item("Current viewport" if output_size == Vector2i.ZERO else "%d × %d" % [output_size.x, output_size.y])
	resolution.item_selected.connect(func(_index: int): capture())
	%Transparent.toggled.connect(func(_on: bool): capture())
	%IncludeGrid.toggled.connect(func(_on: bool): capture())
	%Save.pressed.connect(func(): save_dialog.popup_centered_ratio(0.7))
	save_dialog.file_selected.connect(save_png)


func open(document_path := "") -> void:
	if visible:
		grab_focus()
		return

	open_window()
	var filename: String = document_path.get_file().get_basename() if not document_path.is_empty() else "shapesmith"
	save_dialog.current_file = filename + ".png"
	capture()


func capture() -> void:
	if capturing:
		return

	if DisplayServer.get_name() == "headless":
		message.text = "Screenshot capture requires a graphics renderer."
		return

	capturing = true
	%Capture.disabled = true
	%Save.disabled = true
	for control in [resolution, %Transparent, %IncludeGrid]:
		control.disabled = true
	var view = source_view
	var source: SubViewport = view.get_node("Viewport")
	var output_size: Vector2i = RESOLUTIONS[resolution.selected]
	if output_size == Vector2i.ZERO:
		output_size = source.size
	# Render at the export resolution without resizing the editor viewport.
	var render_viewport := SubViewport.new()
	render_viewport.size = output_size
	render_viewport.world_3d = source.find_world_3d()
	render_viewport.transparent_bg = true
	render_viewport.msaa_3d = source.msaa_3d
	add_child(render_viewport)
	var camera := view.camera.duplicate() as Camera3D
	render_viewport.add_child(camera)
	camera.global_transform = view.camera.global_transform
	camera.make_current()
	var was_playing: bool = playback.playing
	var grid_visible: bool = view.grid.visible
	var axes_visible: bool = view.axes.visible
	var outline: MeshInstance3D = view.selection_outline
	var outline_visible := is_instance_valid(outline) and outline.visible
	playback.playing = false
	if not %IncludeGrid.button_pressed:
		view.grid.hide()
		view.axes.hide()
	if is_instance_valid(outline):
		outline.hide()
	render_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	image = render_viewport.get_texture().get_image()
	render_viewport.queue_free()
	view.grid.visible = grid_visible
	view.axes.visible = axes_visible
	if is_instance_valid(outline):
		outline.visible = outline_visible
	playback.playing = was_playing
	if image != null and not image.is_empty():
		if not %Transparent.button_pressed:
			var background := Image.create(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8)
			var color: Color = Palette.checker_dark
			color.a = 1.0
			background.fill(color)
			background.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
			image = background
		preview.texture = ImageTexture.create_from_image(image)
		message.text = "%d × %d pixels" % [image.get_width(), image.get_height()]
		%Save.disabled = false
	else:
		message.text = "Could not capture the viewport. Try Capture again."
	%Capture.disabled = false
	for control in [resolution, %Transparent, %IncludeGrid]:
		control.disabled = false
	capturing = false


func save_png(path: String) -> void:
	if image == null or image.is_empty():
		return

	if path.get_extension().to_lower() != "png":
		path += ".png"
	var file := FileAccess.open(path, FileAccess.WRITE)
	var result: Error = FileAccess.get_open_error()
	if file != null:
		file.store_buffer(image.save_png_to_buffer())
		file.flush()
		result = file.get_error()
	message.text = "Saved " + path.get_file() if result == OK else "Could not save screenshot: " + error_string(result)
