extends VSplitContainer

const PLAY_RATES := [0.25, 0.5, 1.0, 2.0]
const DEFAULT_PLAYER_HEIGHT := 240
const DEFAULT_INSPECTOR_WIDTH := 280
const MIN_SCENE_SPAN := 100
const MIN_CODE_FIELD_WIDTH := 60.0


signal element_selected(node: Node3D)

const ShapeAnimation = preload("res://core/animation/shape_animation.gd")
const AnimationEditor = preload("res://ui/animation/animation_editor.gd")
const GraphEditor = preload("res://ui/animation/graph_editor.gd")
static var Palette = preload("res://ui/theme/editor_palette.tres")
const BASE_FPS := 30.0
var animation = ShapeAnimation.new()
var editor = AnimationEditor.new()
var history
var updating := false
var rename_index := -1
var duration_pending := false
var committing_code := false


var selected := -1
var frame := 0.0
var playing := false
var animation_mode := false
var context_models
var ik
var graph
var graph_toggle: CheckButton
## Auto Key: gizmo edits in Animation mode write keys. Off, an edit is held as
## an unkeyed pose until Insert Key (K) or a frame change.
var auto_key := true
var auto_key_button: Button
## Unkeyed edits at held_frame: element name -> {group: Vector3 (shape units / degrees)}.
var held: Dictionary = {}
var held_frame := -1
const SETTINGS_PATH := "user://animation.cfg"
var player_size_initialized := false
var inspector_size_initialized := false

@onready var viewport = $Content/RightSplit/Viewport
## The clip list. The editor docks it as the left dock's Animations tab.
@onready var animation_sidebar: Control = $Content/LeftDock/Sidebar
@onready var animation_list: ItemList = %Animations
@onready var clip_title: LineEdit = %ClipTitle
@onready var empty_note: Label = %EmptyNote
@onready var timeline: HSlider = %Timeline
@onready var frame_input: SpinBox = %FrameInput
@onready var frame_total: Label = %FrameTotal
@onready var play_button: Button = %Play
@onready var loop_button: CheckButton = %Loop
@onready var duration: SpinBox = %Duration
@onready var on_stopped: OptionButton = %OnStopped
@onready var on_ended: OptionButton = %OnEnded
@onready var speed: OptionButton = %Speed
@onready var tracks = %KeyframeTracks
@onready var key_details: Label = %KeyDetails
@onready var keyframe_inspector = %KeyframeInspector


func _ready() -> void:
	_build_graph_editor()
	_build_auto_key()
	_connect_keyframe_actions()
	_connect_keyframe_inspector()
	_connect_animation_actions()
	_connect_animation_properties()
	_connect_timeline_layout()
	_connect_playback_controls()

	_set_enabled(false)
	set_animation_mode(false)


func _connect_keyframe_actions() -> void:
	tracks.keyframe_selected.connect(_inspect_keyframe)
	tracks.keyframe_cleared.connect(_hide_keyframe_inspector)
	tracks.move_requested.connect(_move_keyframes)
	tracks.delete_requested.connect(_delete_keyframes)
	tracks.copy_requested.connect(_copy_keyframes)
	tracks.paste_requested.connect(_paste_keyframes)
	tracks.paste_mirrored_requested.connect(paste_mirrored)
	tracks.scale_requested.connect(func(selection: Array, pivot: float, factor: float):
		editor.scale_keyframes(selected, selection, pivot, factor, frame))
	tracks.frames_requested.connect(ripple)
	tracks.markers_changed.connect(func(list: Array): editor.set_markers(selected, list, frame))
	editor.keyframes_moved.connect(tracks.restore_document_selection)


func _connect_keyframe_inspector() -> void:
	keyframe_inspector.closed.connect(tracks.clear_keyframe_selection)
	keyframe_inspector.shape_selected.connect(func(node: Node3D): viewport.select_element(node))
	keyframe_inspector.property_edited.connect(_edit_keyframe_property)
	tracks.details_changed.connect(_show_keyframe_details)


func _connect_animation_actions() -> void:
	editor.changed.connect(_refresh_animations)
	editor.rejected.connect(_show_animation_error)
	animation_list.rename_requested.connect(open_rename)
	animation_list.item_selected.connect(select_animation)
	%RenameDialog.confirmed.connect(_rename_animation)
	%RenameName.text_submitted.connect(_submit_animation_name)
	%NewAnimation.pressed.connect(_create_animation)
	%DeleteAnimation.pressed.connect(_delete_animation)
	%DuplicateAnimation.pressed.connect(_duplicate_animation)


func _connect_animation_properties() -> void:
	clip_title.text_submitted.connect(func(_text: String): _commit_code())
	clip_title.focus_exited.connect(_commit_code)
	duration.value_changed.connect(_change_duration)
	duration.get_line_edit().text_changed.connect(_mark_duration_pending)

	for label in ["Play Till End", "Rewind", "Stop", "Ease Out"]:
		on_stopped.add_item(label)
	for label in ["Repeat", "Hold", "Stop", "Ease Out"]:
		on_ended.add_item(label)

	on_stopped.item_selected.connect(_change_stopped_behavior)
	on_ended.item_selected.connect(_change_ended_behavior)


func _connect_timeline_layout() -> void:
	tracks.hierarchy_width_changed.connect(func(_width: float): _align_timeline.call_deferred())
	tracks.get_parent().get_v_scroll_bar().visibility_changed.connect(_align_timeline.call_deferred)
	$Player/Margin/Layout/Header.resized.connect(_align_timeline.call_deferred)
	_align_timeline.call_deferred()


func _connect_playback_controls() -> void:
	tracks.element_selected.connect(element_selected.emit)
	tracks.frame_selected.connect(seek)
	play_button.pressed.connect(toggle_play)
	%First.pressed.connect(func(): seek(0.0))
	%Last.pressed.connect(func(): seek(timeline.max_value))
	%Previous.pressed.connect(func(): seek(floorf(frame) - 1.0))
	%Next.pressed.connect(func(): seek(floorf(frame) + 1.0))
	timeline.value_changed.connect(seek)
	frame_input.value_changed.connect(seek)
	%ShowInbetweens.toggled.connect(func(enabled: bool):
		tracks.show_generated = enabled
		tracks.queue_redraw())


func _build_auto_key() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		auto_key = config.get_value("timeline", "auto_key", true) == true
	auto_key_button = Button.new()
	auto_key_button.name = "AutoKey"
	auto_key_button.toggle_mode = true
	auto_key_button.text = "●"
	auto_key_button.focus_mode = Control.FOCUS_NONE
	auto_key_button.toggled.connect(set_auto_key)
	%Play.get_parent().add_child(auto_key_button)
	%Play.get_parent().move_child(auto_key_button, %Last.get_index() + 1)
	_sync_auto_key()


func set_auto_key(enabled: bool) -> void:
	auto_key = enabled
	if enabled:
		held.clear()
	_sync_auto_key()
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("timeline", "auto_key", enabled)
	config.save(SETTINGS_PATH)


func _sync_auto_key() -> void:
	auto_key_button.set_pressed_no_signal(auto_key)
	auto_key_button.tooltip_text = "Auto Key is on: moving, turning or scaling a shape writes a key." if auto_key \
		else "Auto Key is off: edits are previewed until you press K (Insert Key)."
	auto_key_button.add_theme_color_override("font_color", Color("e5484d") if auto_key else Palette.muted)
	auto_key_button.add_theme_color_override("font_pressed_color", Color("e5484d"))
	auto_key_button.add_theme_color_override("font_hover_pressed_color", Color("ff6369"))


## Auto Key off: keeps an edit as an unkeyed pose at the playhead.
func hold(name_value: String, group: String, value: Vector3) -> void:
	if held_frame != roundi(frame):
		held.clear()
		held_frame = roundi(frame)
	if not held.has(name_value):
		held[name_value] = {}
	held[name_value][group] = value
	_show_held()


func _held_values(name_value: String, time: int) -> Dictionary:
	var compiled: Dictionary = animation.clips[selected]
	animation.ensure_resolved(compiled)
	var track: Dictionary = compiled.tracks.get(name_value, {"offset": [], "rotation": [], "stretch": []})
	var result := {
		"offset": animation.sample_track(track.offset, time, compiled.frames, Vector3.ZERO),
		"rotation": animation.sample_track(track.rotation, time, compiled.frames, Vector3.ZERO, true),
		"stretch": animation.sample_track(track.stretch, time, compiled.frames, Vector3.ONE)}
	if time == held_frame:
		for group in held.get(name_value, {}):
			result[group] = held[name_value][group]
	return result


func _show_held() -> void:
	if selected < 0 or selected >= animation.clips.size():
		return
	var compiled: Dictionary = animation.clips[selected]
	for name_value in held:
		var values := _held_values(name_value, held_frame)
		for entry in animation.elements.get(name_value, []):
			if is_instance_valid(entry.node):
				entry.node.transform = animation.element_transform(entry.source, values.offset / 16.0, values.rotation, values.stretch, compiled.version)
	viewport.request_parity_check()


## The graph editor shares the player with the dope sheet; Graph switches.
func _build_graph_editor() -> void:
	graph = GraphEditor.new()
	graph.bind(self, editor)
	graph.visible = false
	var layout := $Player/Margin/Layout
	layout.add_child(graph)
	layout.move_child(graph, tracks.get_parent().get_index() + 1)
	graph_toggle = CheckButton.new()
	graph_toggle.text = "Graph"
	graph_toggle.tooltip_text = "Show the selected element's curves instead of the dope sheet"
	graph_toggle.focus_mode = Control.FOCUS_NONE
	graph_toggle.toggled.connect(show_graph)
	%ShowInbetweens.get_parent().add_child(graph_toggle)
	editor.changed.connect(func(_index: int, _frame: float):
		if graph.visible:
			graph.refresh())
	viewport.selection_changed.connect(func(_node: Node3D):
		if graph.visible:
			graph.show_element(_graph_element()))


func show_graph(enabled: bool) -> void:
	graph_toggle.set_pressed_no_signal(enabled)
	tracks.get_parent().visible = not enabled
	graph.visible = enabled
	if enabled:
		graph.show_element(_graph_element())


func _graph_element() -> String:
	var node: Node3D = viewport.selected_node
	return str(node.get_meta("shape_element").get("name", "")) if is_instance_valid(node) and node.has_meta("shape_element") else ""


## Pastes the copied keys onto the mirror elements (Left and Right swap), mirrored.
func paste_mirrored(time: int = -1) -> void:
	if selected < 0:
		return
	editor.paste_mirrored(selected, roundi(frame) if time < 0 else time, tracks.selection_for_document(), frame)


## Ripple insert (count > 0) or delete (count < 0) frames at a frame.
func ripple(at: int, count: int) -> void:
	if selected < 0 or count == 0:
		return
	if count > 0:
		editor.insert_frames(selected, at, count, frame)
	else:
		editor.delete_frames(selected, at, -count, frame)


func refresh_preview() -> void:
	_refresh_animations(selected, frame)


func _move_keyframes(selection: Array, delta: int) -> void:
	finish_pending()
	editor.move_keyframes(selected, selection, delta, frame)


func _delete_keyframes(selection: Array) -> void:
	if not animation_mode:
		return

	finish_pending()
	editor.delete_keyframes(selected, selection, frame)


func _copy_keyframes(selection: Array) -> void:
	finish_pending()
	if editor.copy_keyframes(selected, selection):
		tracks.clipboard_available = true


func _paste_keyframes(time: int) -> void:
	if not animation_mode:
		return

	finish_pending()
	editor.paste_keyframes(selected, time, tracks.selection_for_document(), frame)


func _edit_keyframe_property(property: String, enabled: bool, value: Variant) -> void:
	var selection: Dictionary = keyframe_inspector.selection()
	if selection.is_empty():
		return

	var name: String = tracks.element_name(selection.node)
	editor.set_keyframe_property(selected, selection.frame, name, property, enabled, value)


func _show_keyframe_details(text: String) -> void:
	key_details.text = text.get_slice("\n", 0)
	if "\n" in text:
		key_details.text += " · More in tooltip"
	key_details.tooltip_text = text


func _show_animation_error(message: String) -> void:
	%AnimationError.dialog_text = message
	%AnimationError.popup_centered()


func _rename_animation() -> void:
	editor.set_property(rename_index, "name", %RenameName.text, frame)


func _submit_animation_name(_text: String) -> void:
	%RenameDialog.hide()
	_rename_animation()


func _create_animation() -> void:
	finish_pending()
	editor.create(selected, frame)


func _delete_animation() -> void:
	finish_pending()
	editor.delete(selected, frame)


func _duplicate_animation() -> void:
	finish_pending()
	editor.duplicate(selected, frame)


func _change_duration(value: float) -> void:
	if not updating:
		editor.set_property(selected, "quantityframes", int(value), frame)


func _mark_duration_pending(_text: String) -> void:
	if not updating:
		duration_pending = true


func _change_stopped_behavior(index: int) -> void:
	editor.set_property(selected, "onActivityStopped", AnimationEditor.STOPPED[index], frame)


func _change_ended_behavior(index: int) -> void:
	editor.set_property(selected, "onAnimationEnd", AnimationEditor.ENDED[index], frame)


func bind_shape() -> void:
	_clear_keyframe()
	playing = false
	selected = -1
	frame = 0.0
	_restore_pose()
	animation.bind(viewport.models.get_child(0), viewport.shape_data)
	editor.bind(viewport.shape_data, history)
	tracks.bind_shape(viewport.models.get_child(0))
	_refresh_animations(-1, 0.0)


## Updates the timeline after elements were added, removed, moved or renamed,
## keeping the selected clip, frame and fold states. Clips are recompiled only
## when element names or tracks changed.
func sync_structure(recompile: bool) -> void:
	if viewport.models.get_child_count() == 0:
		return
	var index := selected
	var at := frame
	var root: Node3D = viewport.models.get_child(0)
	_restore_pose()
	animation.rebind_elements(root)
	tracks.sync_structure(root)
	if recompile or index < 0 or index >= animation.clips.size():
		_refresh_animations(index, at)
	else:
		select_animation(index)
		if animation.clips[index].error.is_empty():
			seek(at)


func _refresh_animations(index: int, value: float) -> void:
	var key_selection: Array = tracks.selected_keys.duplicate()
	held.clear()
	var previous_code: String = animation.clips[selected].code if selected >= 0 and selected < animation.clips.size() else ""
	updating = true
	playing = false
	_restore_pose()
	animation.refresh_clips(viewport.shape_data)
	selected = -1
	frame = 0.0
	animation_list.clear()
	animation_list.show_rename(-1)
	var first_playable := _rebuild_animation_list()

	_set_enabled(false)
	clip_title.text = ""
	tracks.set_clip({})
	timeline.set_value_no_signal(0.0)
	frame_input.set_value_no_signal(0.0)
	frame_total.text = "/ —"
	updating = false
	var next := index if index >= 0 and index < animation.clips.size() else first_playable
	if next >= 0:
		select_animation(next)
		if animation.clips[next].error.is_empty():
			seek(value)
	else:
		_clear_keyframe()
	if selected >= 0 and animation.clips[selected].code == previous_code:
		tracks.restore_selection(key_selection)
	%NewAnimation.disabled = viewport.shape_data.is_empty()


func _rebuild_animation_list() -> int:
	var first_playable := -1
	for clip in animation.clips:
		var row := animation_list.add_item(clip.name)
		animation_list.set_item_custom_bg_color(row, Palette.surface if row % 2 == 0 else Palette.chrome)
		# Invalid clips stay selectable for repairing metadata or deleting them.
		animation_list.set_item_tooltip(row, clip.error if not clip.error.is_empty() else "%d frames\n%s" % [clip.frames, clip.warning])
		if first_playable < 0 and clip.error.is_empty():
			first_playable = row
	%AnimationCount.text = str(animation.clips.size())
	empty_note.visible = first_playable < 0
	empty_note.text = "No animations yet.\nCreate one with New."
	if not animation.warning.is_empty():
		empty_note.text = animation.warning
	elif not animation.clips.is_empty() and first_playable < 0:
		empty_note.text = "No playable animations.\nHover an entry for its validation error."
	return first_playable


func set_animation_mode(enabled: bool) -> void:
	animation_mode = enabled
	# A docked tab's visibility belongs to its TabContainer.
	if not animation_sidebar.get_parent() is TabContainer:
		animation_sidebar.visible = enabled
	$Player.visible = enabled
	if enabled and not player_size_initialized:
		player_size_initialized = true
		call_deferred("_initialize_player_size")
	if not enabled:
		_clear_keyframe()
		playing = false
		_restore_pose()
	elif selected >= 0:
		_apply_pose(animation.clips[selected], frame)
	_sync_play_button()


func _initialize_player_size() -> void:
	split_offset = maxi(roundi(size.y) - DEFAULT_PLAYER_HEIGHT, MIN_SCENE_SPAN)


func select_animation(index: int) -> void:
	if index < 0 or index >= animation.clips.size():
		return

	finish_pending()
	_clear_keyframe()
	updating = true
	_restore_pose()
	selected = index
	animation_list.select(index)
	animation_list.ensure_current_is_visible()
	
	var clip: Dictionary = animation.clips[index]
	var source: Variant = editor.clips()[index]
	var editable: bool = source is Dictionary
	
	tracks.set_clip(clip if clip.error.is_empty() else {})
	clip_title.text = editor.effective_code(source) if editable else ""
	clip_title.tooltip_text = clip.warning
	loop_button.set_pressed_no_signal(clip.loop)
	timeline.max_value = maxi(clip.frames - 1, 1)
	frame_input.max_value = clip.frames - 1
	frame_total.text = "/ %d" % (clip.frames - 1)
	
	_set_enabled(clip.error.is_empty())
	
	clip_title.editable = editable
	duration.editable = editable
	on_stopped.disabled = not editable
	on_ended.disabled = not editable
	%DeleteAnimation.disabled = false
	%DuplicateAnimation.disabled = not editable
	
	if editable:
		duration_pending = false
		duration.min_value = editor.minimum_duration(source)
		duration.set_value_no_signal(int(source.get("quantityframes", source.get("quantityFrames", 1))))
		duration.tooltip_text = "Duration in frames at 30 FPS. Minimum %d keeps existing keyframes." % int(duration.min_value)
		on_stopped.select(AnimationEditor.behavior_index(source.get("onActivityStopped", "Rewind"), AnimationEditor.STOPPED))
		on_ended.select(AnimationEditor.behavior_index(source.get("onAnimationEnd", "Repeat"), AnimationEditor.ENDED))
		
	animation_list.show_rename(index if editable else -1)
	timeline.editable = clip.frames > 1 and clip.error.is_empty()
	updating = false
	if clip.error.is_empty():
		seek(0.0)


func seek(value: float) -> void:
	if selected < 0 or not animation.clips[selected].error.is_empty():
		return

	playing = false
	_show_frame(clampf(value, 0.0, animation.clips[selected].frames - 1.0))
	_sync_play_button()


func toggle_play() -> void:
	if selected < 0 or not animation_mode or not animation.clips[selected].error.is_empty():
		return

	if not playing and not loop_button.button_pressed and frame >= animation.clips[selected].frames - 1:
		_show_frame(0.0)
	playing = not playing
	_sync_play_button()


func stop() -> void:
	seek(0.0)


func _process(delta: float) -> void:
	if not playing or selected < 0 or not animation_mode:
		return

	var clip: Dictionary = animation.clips[selected]
	var next: float = frame + delta * BASE_FPS * PLAY_RATES[speed.selected]
	if loop_button.button_pressed:
		next = fposmod(next, clip.frames)
	elif next >= clip.frames - 1:
		next = clip.frames - 1
		playing = false
	_show_frame(next)
	_sync_play_button()


func _show_frame(value: float) -> void:
	frame = value
	tracks.set_playhead(value)
	if graph != null and graph.visible:
		graph.show_playhead()
	timeline.set_value_no_signal(minf(frame, timeline.max_value))
	frame_input.set_value_no_signal(floorf(frame))
	if animation_mode:
		_apply_pose(animation.clips[selected], frame)


func _sync_play_button() -> void:
	if is_instance_valid(play_button):
		play_button.text = ""
		play_button.icon = preload("res://ui/shared/editor_icons.gd").icon("pause" if playing else "play_arrow")
		play_button.tooltip_text = "Pause animation" if playing else "Play animation"


func _set_enabled(enabled: bool) -> void:
	for button in [%First, %Previous, %Play, %Next, %Last, %Loop, %Speed]:
		button.disabled = not enabled
	timeline.editable = enabled
	frame_input.editable = enabled
	duration.editable = enabled
	clip_title.editable = enabled
	on_stopped.disabled = not enabled
	on_ended.disabled = not enabled
	%DeleteAnimation.disabled = not enabled
	%DuplicateAnimation.disabled = not enabled
	_sync_play_button()


func open_rename(index: int) -> void:
	finish_pending()
	if index < 0 or index >= editor.clips().size() or not editor.clips()[index] is Dictionary:
		return

	rename_index = index
	%RenameName.text = str(editor.clips()[index].get("name", editor.effective_code(editor.clips()[index])))
	%RenameDialog.popup_centered(Vector2i(360, 110))
	%RenameName.grab_focus()
	%RenameName.select_all()


func finish_pending() -> void:
	if updating or selected < 0:
		return

	keyframe_inspector.finish_pending()
	var pending_code := clip_title.text
	if duration_pending:
		duration_pending = false
		duration.apply()
		# A duration commit refreshes the controls; retain any unsubmitted code.
		clip_title.text = pending_code
	_commit_code()


func _commit_code() -> void:
	if updating or committing_code or selected < 0 or selected >= editor.clips().size() or not editor.clips()[selected] is Dictionary:
		return

	var current: String = editor.effective_code(editor.clips()[selected])
	if clip_title.text.strip_edges() != current:
		committing_code = true
		if not editor.set_property(selected, "code", clip_title.text, frame):
			clip_title.text = current
		committing_code = false


func _clear_keyframe() -> void:
	keyframe_inspector.finish_pending()
	keyframe_inspector.clear_selection()
	tracks.clear_keyframe_selection()


func _hide_keyframe_inspector() -> void:
	keyframe_inspector.finish_pending()
	keyframe_inspector.clear_selection()


func _inspect_keyframe(entries: Array, time: int) -> void:
	finish_pending()
	if not animation_mode or entries.is_empty():
		return

	keyframe_inspector.inspect(entries, time)
	if not inspector_size_initialized:
		inspector_size_initialized = true
		call_deferred("_initialize_inspector_width")
	viewport.select_element(entries[0].node)


## Animation → Insert Key (K): keys the element's current offset and
## rotation at the playhead. Returns whether a key was added.
func insert_key(node: Node3D) -> bool:
	if not is_instance_valid(node) or selected < 0 or selected >= animation.clips.size():
		return false
	var compiled: Dictionary = animation.clips[selected]
	var name_value := str(node.get_meta("shape_element").get("name", ""))
	if not compiled.error.is_empty() or name_value.is_empty() or animation.elements.get(name_value, []).size() != 1:
		editor.rejected.emit("Give this shape a unique name before animating it.")
		return false
	var time := roundi(frame)
	if held_frame != time:
		held.clear()
	var values := _held_values(name_value, time)
	# A selected channel row keys just its group; otherwise position and
	# rotation, plus scale when an unkeyed scale edit is held.
	var groups: Array = ["offset", "rotation"]
	if held_frame == time and held.get(name_value, {}).has("stretch"):
		groups.append("stretch")
	var channel: Dictionary = tracks.selected_channel
	if not channel.is_empty() and channel.node == node:
		groups = [str(channel.channel).rstrip("XYZ")]
	var keyed := {}
	for group in groups:
		keyed[group] = values[group]
	var ok: bool = editor.insert_key(selected, time, name_value, keyed)
	if ok:
		held.erase(name_value)
	return ok


## Puts the right sidebar back to its default width (Reset Layout).
func reset_inspector_width() -> void:
	_initialize_inspector_width()


func _initialize_inspector_width() -> void:
	var split: HSplitContainer = $Content/RightSplit
	split.split_offset = maxi(roundi(split.size.x) - DEFAULT_INSPECTOR_WIDTH, MIN_SCENE_SPAN)


func _align_timeline() -> void:
	var grabber := timeline.get_theme_icon("grabber")
	var half_grabber := grabber.get_width() * 0.5
	var label: Label = $Player/Margin/Layout/Header/CodeLabel
	var header: HBoxContainer = $Player/Margin/Layout/Header
	var code_field_width: float = (
		tracks.get_hierarchy_width() + tracks.TRACK_LEFT_PADDING
		- label.size.x - header.get_theme_constant("separation") * 2 - half_grabber
	)
	clip_title.custom_minimum_size.x = maxf(code_field_width, MIN_CODE_FIELD_WIDTH)
	var right_inset: float = (
		tracks.get_parent().size.x - tracks.size.x
		+ tracks.TRACK_RIGHT_PADDING - half_grabber
	)
	timeline.get_parent().add_theme_constant_override("margin_right", maxi(roundi(right_inset), 0))


func _restore_pose() -> void:
	if context_models != null:
		context_models.clear_main_corrections()
		context_models.follow("", 0)
	animation.restore()
	viewport.request_parity_check()


func _apply_pose(clip: Dictionary, time: float) -> void:
	if context_models != null:
		context_models.clear_main_corrections()
		context_models.follow(str(clip.get("code", "")), time)
	animation.apply(clip, time)
	if not held.is_empty():
		if roundi(time) == held_frame and not playing:
			_show_held()
		else:
			held.clear()
	if ik != null:
		ik.apply(clip, time)
	viewport.request_parity_check()
	if context_models != null:
		context_models.sync()
