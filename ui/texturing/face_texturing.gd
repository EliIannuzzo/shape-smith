extends VBoxContainer
const Units = preload("res://core/model/shape_units.gd")

signal face_edited(node: Node3D, face: String)
signal face_selected(node: Node3D, face: String)
## A texture ID was assigned to a face (new cubes use the last one).
signal texture_assigned(id: String)
## A face was picked on the UV canvas; the editor selects it everywhere.
signal face_picked(node: Node3D, face: String)
## A notice for the user about texturing.
signal texture_message(text: String)
## Elements to box-unwrap: set by the editor (the selection).
var unwrap_targets: Callable
## Faces selected on the UV canvas besides the current one: [{node, face}].
## Moving, rotating, mirroring and texel sizing act on all of them.
var extra_faces: Array = []
var _keep_extras := false
## Once the handle above the UV editor is dragged, the split stays put.
var _split_moved := false
var texel_tools
const Geometry = preload("res://core/model/shape_geometry.gd")
const Document = preload("res://core/document/shape_document.gd")
const SetFaceFields = preload("res://core/commands/set_face_fields.gd")
var library
var document
var selected: Node3D
var current_face := ""
var updating := false
var history
var uv_edit: Dictionary = {}
var model_root: Node3D
var uv_tools
var extra_properties
@onready var faces: OptionButton = %Face
@onready var textures: OptionButton = %Texture
@onready var fields: Array = [%U1, %V1, %U2, %V2]
@onready var uv_editor = %UVEditor


func _ready() -> void:
	# The face fields take the height they need and the UV editor the rest,
	# until the handle between them is dragged.
	var split: SplitContainer = $Split
	split.dragged.connect(func(_offset: int): _split_moved = true)
	$Split/Scroll/Fields.minimum_size_changed.connect(_fit_fields)
	resized.connect(_fit_fields)
	_setup_uv_tools()
	_connect_uv_toolbar()
	_connect_face_fields()
	_connect_uv_canvas()
	refresh()


func _setup_uv_tools() -> void:
	uv_tools = preload("res://ui/texturing/uv_tools.gd").new()
	uv_tools.panel = self
	add_child(uv_tools)


func _connect_uv_toolbar() -> void:
	%OtherUVs.toggled.connect(func(enabled: bool):
		uv_editor.show_other_uvs = enabled
		refresh_other_uvs())
	%ExportUV.pressed.connect(uv_tools.open_export)
	%Fit.pressed.connect(uv_editor.fit)
	# Texel tools, grouped like snapping: the button sizes the selected faces,
	# the settings hold the texel size and Resize Every Face.
	texel_tools = %TexelTools
	var texel: Button = texel_tools.enabled_toggle
	texel.toggle_mode = false
	texel.icon = preload("res://ui/shared/editor_icons.gd").icon("grid_on")
	texel.pressed.connect(size_uv_to_texels)
	texel_tools.settings_button.pressed.connect(func():
		%TexelSize.set_value_no_signal(library.texel_size if library != null else 0.5))
	%TexelSize.value_changed.connect(func(value: float):
		if library != null:
			library.set_texel_size(value))
	%TexelAll.pressed.connect(func():
		texel_tools.popup.hide()
		uv_tools.confirm_texel_all())
	%SnapUV.enabled_changed.connect(func(enabled: bool): _set_property("snapUV", enabled))
	%SnapUV.translation_step.value_changed.connect(func(_value: float): refresh())


func _connect_face_fields() -> void:
	# UV bounds look like the shape panel's XYZ rows: U edges red, V green.
	var Vector3Field = preload("res://ui/shared/vector3_field.gd")
	for i in range(fields.size()):
		fields[i].get_line_edit().add_theme_font_size_override("font_size", 12)
		Vector3Field.edge(fields[i], Vector3Field.Palette.axis_x if i % 2 == 0 else Vector3Field.Palette.axis_y)
	faces.item_selected.connect(_face_selected)
	textures.item_selected.connect(_texture_selected)
	for field in fields:
		field.value_changed.connect(func(_value: float):
			if not updating:
				_apply_uv([fields[0].value, fields[1].value, fields[2].value, fields[3].value]))
	%Glow.value_changed.connect(func(value: float): _set_property("glow", int(value)))
	%Rotation.item_selected.connect(func(index: int): _set_property("rotation", index * 90))


func _face_selected(index: int) -> void:
	finish_pending()
	if history != null:
		history.break_merge()

	current_face = Geometry.FACES[index]
	refresh()
	face_selected.emit(selected, current_face)


func _connect_uv_canvas() -> void:
	uv_editor.face_clicked.connect(func(node: Node3D, face: String): face_picked.emit(node, face))
	uv_editor.face_toggled.connect(toggle_face)
	uv_editor.box_selected.connect(select_box)
	_add_canvas_tools()
	uv_editor.uv_changed.connect(_apply_uv)
	uv_editor.edit_started.connect(_begin_uv_edit)
	uv_editor.edit_finished.connect(_finish_uv_edit)
	for field in fields:
		field.get_line_edit().focus_entered.connect(func():
			if history != null:
				history.break_merge())


func bind_library(value) -> void:
	library = value
	library.changed.connect(refresh)


## Called whenever a document opens or a new one starts.
func bind_document(target_document) -> void:
	document = target_document


func bind_history(value) -> void:
	history = value
	history.flush_pending.connect(finish_pending)


func select_element(node: Node3D, face := "") -> void:
	# Another face drops the extra faces; reselecting this one (after an undo) keeps them.
	if not _keep_extras and (node != selected or (not face.is_empty() and face != current_face)):
		extra_faces.clear()
	if node != selected or (not face.is_empty() and face != current_face):
		finish_pending()
		if history != null:
			history.break_merge()
	selected = node
	current_face = face
	if is_instance_valid(selected):
		var source: Dictionary = selected.get_meta("shape_element")
		if not current_face in Geometry.FACES:
			current_face = ""
			for name in Geometry.FACES:
				if source.get("faces", {}).has(name):
					current_face = name
					break
			if current_face.is_empty():
				current_face = "north"
	refresh()


func refresh() -> void:
	if not is_node_ready():
		return

	updating = true
	var valid: bool = is_instance_valid(selected) and not current_face.is_empty() and library != null and selected.get_meta("shape_element").get("faces", {}).has(current_face)
	%Selection.text = str(selected.get_meta("shape_element").get("name", "Unnamed")) if is_instance_valid(selected) else "Select an element"
	_refresh_face_choices()
	_refresh_texture_choices()
	_set_face_controls_enabled(valid)

	if valid:
		_show_face_values()
	else:
		_clear_face_values()

	updating = false
	refresh_other_uvs()
	%TexelAll.disabled = model_root == null or library == null or library.data.is_empty()
	%ExportUV.disabled = %TexelAll.disabled


func _refresh_face_choices() -> void:
	faces.clear()
	for name in Geometry.FACES:
		faces.add_item(name.capitalize())
	faces.disabled = not is_instance_valid(selected)
	if current_face in Geometry.FACES:
		faces.select(Geometry.FACES.find(current_face))


func _refresh_texture_choices() -> void:
	textures.clear()
	textures.add_item("Unassigned")
	textures.set_item_metadata(0, "")
	if library != null:
		for id in library.ids():
			textures.add_item("#" + id)
			textures.set_item_metadata(textures.item_count - 1, id)


func _set_face_controls_enabled(valid: bool) -> void:
	for field in fields + [%Glow]:
		field.editable = valid
	textures.disabled = not valid
	%Rotation.disabled = not valid
	texel_tools.settings_button.disabled = library == null or library.data.is_empty()
	texel_tools.enabled_toggle.disabled = not valid
	%SnapUV.set_editable(valid)
	%SnapUV.set_enabled(face_data().get("snapUV", true) if valid else false)
	uv_editor.snap_enabled = valid and %SnapUV.is_enabled()


func _show_face_values() -> void:
	faces.select(Geometry.FACES.find(current_face))
	var face := face_data()
	var id := str(face.get("texture", "")).trim_prefix("#")
	var chosen := 0
	for i in range(textures.item_count):
		if textures.get_item_metadata(i) == id:
			chosen = i
	if not id.is_empty() and chosen == 0:
		textures.add_item("#%s (unresolved)" % id)
		chosen = textures.item_count - 1
		textures.set_item_metadata(chosen, id)
	textures.select(chosen)
	var dimensions: Vector2 = library.uv_size(id)
	uv_editor.snap_step = library.pixel_uv_size(id) if not id.is_empty() else Vector2(0.5, 0.5)
	uv_editor.snap_step *= %SnapUV.translation_step.value
	var uv := Geometry.face_uv(face, dimensions)
	for i in range(4):
		fields[i].set_value_no_signal(uv[i])
	%Glow.set_value_no_signal(face.get("glow", 0))
	%Rotation.select(posmod(roundi(float(face.get("rotation", 0)) / 90.0), 4))
	uv_editor.set_face(library.texture(id) if not id.is_empty() else null, dimensions, uv)
	%UVTitle.text = "UV EDITOR · %s" % ("#" + id if not id.is_empty() else "Unassigned")


func _clear_face_values() -> void:
	uv_editor.set_face(null, Vector2(16, 16), [0, 0, 16, 16])
	%UVTitle.text = "UV EDITOR"
	for i in range(4):
		fields[i].set_value_no_signal(0 if i < 2 else 16)
	%Glow.set_value_no_signal(0)
	%Rotation.select(0)


func refresh_other_uvs() -> void:
	uv_editor.other_uvs.clear()
	uv_editor.other_faces.clear()
	uv_editor.warning = ""
	uv_editor.face_rotation = float(face_data().get("rotation", 0)) if is_instance_valid(selected) and not current_face.is_empty() else 0.0
	var on_texture := {}
	if is_instance_valid(selected) and not current_face.is_empty():
		var id := str(face_data().get("texture", "")).trim_prefix("#")
		var faces: Array = uv_tools.entries().filter(func(entry): return entry.id == id)
		for entry in faces:
			on_texture[_face_key(entry.node, entry.face)] = true
		# Extra faces stay selected only while they are on this texture.
		extra_faces = extra_faces.filter(func(entry): return is_instance_valid(entry.node) and on_texture.has(_face_key(entry.node, entry.face)) \
			and not (entry.node == selected and entry.face == current_face))
		var chosen := {}
		for entry in extra_faces:
			chosen[_face_key(entry.node, entry.face)] = true
		for entry in faces:
			var kind := "" if Rect2(Vector2.ZERO, entry.dimensions).grow(0.001).encloses(_uv_rect(entry)) else "outside"
			if entry.node == selected and entry.face == current_face:
				uv_editor.warning = kind
			elif uv_editor.show_other_uvs or chosen.has(_face_key(entry.node, entry.face)):
				uv_editor.other_uvs.append(entry.uv)
				uv_editor.other_faces.append({"node": entry.node, "face": entry.face, "warning": kind, "selected": chosen.has(_face_key(entry.node, entry.face))})
	else:
		extra_faces.clear()
	uv_editor.queue_redraw()


static func _face_key(node: Node3D, face: String) -> String:
	return "%d:%s" % [node.get_instance_id(), face]


## The current face and the other selected ones: [{node, face}].
func selected_faces() -> Array:
	var result: Array = []
	if is_instance_valid(selected) and not current_face.is_empty() and selected.get_meta("shape_element").get("faces", {}).has(current_face):
		result.append({"node": selected, "face": current_face})
	return result + extra_faces


## Ctrl- or Shift-click on the canvas: adds a face to the selection, or
## removes it.
func toggle_face(node: Node3D, face: String) -> void:
	if not is_instance_valid(node) or (node == selected and face == current_face):
		return
	var key := _face_key(node, face)
	var kept: Array = extra_faces.filter(func(entry): return _face_key(entry.node, entry.face) != key)
	if kept.size() == extra_faces.size():
		kept.append({"node": node, "face": face})
	extra_faces = kept
	refresh_other_uvs()


## A box dragged on the canvas (in UV units) selects the faces it touches on
## this texture; with Ctrl or Shift it adds them. A click on empty canvas
## clears the extra faces.
func select_box(box: Rect2, additive: bool) -> void:
	if not is_instance_valid(selected) or current_face.is_empty():
		return
	var id := str(face_data().get("texture", "")).trim_prefix("#")
	var hits: Array = []
	if box.size.x > 0.0 and box.size.y > 0.0:
		for entry in uv_tools.entries():
			var current: bool = entry.node == selected and entry.face == current_face
			if entry.id == id and (current or uv_editor.show_other_uvs) and _uv_rect(entry).intersects(box):
				hits.append({"node": entry.node, "face": entry.face, "current": current})
	var others: Array = hits.filter(func(entry): return not entry.current).map(func(entry): return {"node": entry.node, "face": entry.face})
	if additive:
		for entry in others:
			if not extra_faces.any(func(chosen): return _face_key(chosen.node, chosen.face) == _face_key(entry.node, entry.face)):
				extra_faces.append(entry)
	elif hits.any(func(entry): return entry.current) or others.is_empty():
		extra_faces = others
	else:
		# The box missed the current face: the first face it touched becomes current.
		_keep_extras = true
		extra_faces = others.slice(1)
		if face_picked.get_connections().is_empty():
			select_element(others[0].node, others[0].face)
		else:
			face_picked.emit(others[0].node, others[0].face)
		_keep_extras = false
	refresh_other_uvs()


## Sets fields on every selected face as one undo step. `compute` returns a
## face's new fields, or {} to leave it.
func _set_on_selection(compute: Callable, label: String) -> bool:
	var steps: Array = []
	for entry in selected_faces():
		var uid := Document.uid_of(entry.node)
		if document == null or not document.has(uid):
			continue
		var changes: Dictionary = compute.call(entry.node, entry.face)
		if not changes.is_empty():
			steps.append(SetFaceFields.new(document, uid, entry.face, changes))
	if steps.is_empty() or history == null:
		return false
	finish_pending()
	history.break_merge()
	var result: bool = history.execute(preload("res://core/commands/composite_command.gd").new(document, steps, label))
	history.break_merge()
	return result


static func _face_of(node: Node3D, face: String) -> Dictionary:
	return node.get_meta("shape_element").get("faces", {}).get(face, {})


static func _uv_rect(entry: Dictionary) -> Rect2:
	return Rect2(Vector2(entry.uv[0], entry.uv[1]), Vector2(entry.uv[2] - entry.uv[0], entry.uv[3] - entry.uv[1])).abs()


## For each face entry: "overlap" when it partly covers another face (sharing
## exactly the same area is allowed: models often reuse a texture region),
## "outside" when it reaches beyond the texture, else "". Compares every pair,
## so use it on a handful of faces (checking a box unwrap), not a whole model.
static func uv_warnings(faces: Array) -> Array:
	var rects: Array = faces.map(func(entry): return Rect2(Vector2(entry.uv[0], entry.uv[1]), Vector2(entry.uv[2] - entry.uv[0], entry.uv[3] - entry.uv[1])).abs())
	var result: Array = []
	for i in range(faces.size()):
		var kind := ""
		var bounds := Rect2(Vector2.ZERO, faces[i].dimensions)
		if not bounds.grow(0.001).encloses(rects[i]):
			kind = "outside"
		for j in range(faces.size()):
			if i == j or rects[i].is_equal_approx(rects[j]):
				continue
			var shared: Rect2 = rects[i].intersection(rects[j])
			if shared.size.x > 0.001 and shared.size.y > 0.001:
				kind = "overlap"
				break
		result.append(kind)
	return result


func _fit_fields() -> void:
	if _split_moved:
		return
	var split: SplitContainer = $Split
	var scroll: ScrollContainer = $Split/Scroll
	var wanted: float = $Split/Scroll/Fields.get_combined_minimum_size().y
	# At most half the height, so the UV canvas stays usable with Shader open.
	var room: float = minf(split.size.y * 0.5, split.size.y - $Split/UVPanel.custom_minimum_size.y - split.get_theme_constant("separation"))
	split.split_offset = roundi(clampf(wanted, scroll.custom_minimum_size.y, maxf(scroll.custom_minimum_size.y, room)))


func _add_canvas_tools() -> void:
	var tools: Container = %OtherUVs.get_parent()
	var icons = preload("res://ui/shared/editor_icons.gd")
	# Face edits first, then whole-model tools, then the overlay toggle.
	var order := 0
	for entry in [["RotateUV", "rotate_right", "Rotate the face's texture 90°", rotate_face],
			["MirrorU", "flip", "Mirror the UV left to right", mirror_uv.bind(0)],
			["MirrorV", "flip_vertical", "Mirror the UV top to bottom", mirror_uv.bind(1)],
			["BoxUnwrap", "deployed_code", "Box unwrap the selected elements", box_unwrap_selection]]:
		var button := Button.new()
		button.name = entry[0]
		button.icon = icons.icon(entry[1])
		button.tooltip_text = entry[2]
		button.custom_minimum_size.x = 32
		button.add_theme_constant_override("icon_max_width", 20)
		button.pressed.connect(entry[3])
		tools.add_child(button)
		tools.move_child(button, order)
		order += 1
		if entry[0] == "MirrorV":
			tools.add_child(_tool_gap())
			tools.move_child(tools.get_child(tools.get_child_count() - 1), order)
			order += 1
	# Texel density sits beside Box Unwrap, then export.
	%TexelTools.reparent(tools, false)
	tools.move_child(%TexelTools, order)
	tools.move_child(%ExportUV, order + 1)
	%OtherUVs.text = "All faces"
	%OtherUVs.button_pressed = true
	_build_canvas_overlay()


## The view's own controls float in the canvas's top-right corner: all
## faces, snapping and Fit.
func _build_canvas_overlay() -> void:
	var palette = preload("res://ui/theme/editor_palette.tres")
	var overlay := PanelContainer.new()
	overlay.name = "CanvasTools"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(palette.chrome, 0.92)
	style.border_color = palette.border_light
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(3)
	style.content_margin_left = 8
	overlay.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	overlay.add_child(row)
	uv_editor.add_child(overlay)
	for control in [%OtherUVs, %SnapUV, %Fit]:
		control.reparent(row, false)
		control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	overlay.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	overlay.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 6)


func _tool_gap() -> Control:
	var gap := VSeparator.new()
	gap.custom_minimum_size.x = 6
	return gap


## Turns the current face's texture a quarter turn clockwise.
func rotate_face() -> void:
	if not extra_faces.is_empty():
		_set_on_selection(func(node: Node3D, face: String): return {"rotation": posmod(roundi(float(_face_of(node, face).get("rotation", 0))) + 90, 360)},
			"Rotate %d Faces" % selected_faces().size())
		return
	if is_instance_valid(selected) and not current_face.is_empty():
		_set_property("rotation", posmod(roundi(float(face_data().get("rotation", 0))) + 90, 360))


## Mirrors the current face's UV along U (axis 0) or V (axis 1).
func mirror_uv(axis: int) -> void:
	if not extra_faces.is_empty():
		_set_on_selection(func(node: Node3D, face: String):
			var data := _face_of(node, face)
			var flipped := Geometry.face_uv(data, library.uv_size(str(data.get("texture", "")).trim_prefix("#")))
			return {"uv": [flipped[2], flipped[1], flipped[0], flipped[3]] if axis == 0 else [flipped[0], flipped[3], flipped[2], flipped[1]]},
			"Mirror %d UVs" % selected_faces().size())
		return
	if not is_instance_valid(selected) or current_face.is_empty():
		return
	var uv := Geometry.face_uv(face_data(), library.uv_size(str(face_data().get("texture", "")).trim_prefix("#")))
	if axis == 0:
		uv = [uv[2], uv[1], uv[0], uv[3]]
	else:
		uv = [uv[0], uv[3], uv[2], uv[1]]
	if history != null:
		history.break_merge()
	_set_property("uv", uv)


func box_unwrap_selection() -> void:
	var nodes: Array = unwrap_targets.call() if unwrap_targets.is_valid() else []
	if nodes.is_empty() and is_instance_valid(selected):
		nodes = [selected]
	box_unwrap(nodes)


## Lays every face of these elements out as a box unwrap on the current face's
## texture (up and down on top; west, north, east, south below), sized by the
## texel density and packed below the faces already on the texture. One step.
func box_unwrap(nodes: Array) -> bool:
	if nodes.is_empty() or document == null or library == null:
		return false
	var id := str(face_data().get("texture", "")).trim_prefix("#") if is_instance_valid(selected) and not current_face.is_empty() else ""
	if id.is_empty() and not library.ids().is_empty():
		id = str(library.ids()[0])
	var dimensions: Vector2 = library.uv_size(id)
	var step_value: Vector2 = library.pixel_uv_size(id) if not id.is_empty() else Vector2(1, 1)
	var targets := {}
	for node in nodes:
		targets[node] = true
	# Start below everything else already on this texture.
	var top := 0.0
	for entry in uv_tools.entries():
		if entry.id == id and not targets.has(entry.node):
			top = maxf(top, maxf(entry.uv[1], entry.uv[3]))
	var cursor := Vector2(0, ceilf(top / step_value.y) * step_value.y)
	var row_height := 0.0
	var steps: Array = []
	var SetFaceFields = preload("res://core/commands/set_face_fields.gd")
	for node in nodes:
		var size_value: Vector3 = Geometry.size_of(node.get_meta("shape_element")).abs() * Units.PER_BLOCK
		# Whole texture pixels, at least one each.
		var pixels: Vector3 = (size_value / library.texel_size).round().max(Vector3.ONE)
		var w := pixels.x * step_value.x
		var h := pixels.y * step_value.y
		var d := pixels.z * step_value.x
		var dv := pixels.z * step_value.y
		var cross := Vector2(2 * (w + d), dv + h)
		if cursor.x > 0 and cursor.x + cross.x > dimensions.x:
			cursor = Vector2(0, cursor.y + row_height)
			row_height = 0.0
		var u := cursor.x
		var v := cursor.y
		var layout := {"up": [u + d, v, u + d + w, v + dv], "down": [u + d + w, v, u + d + 2 * w, v + dv],
			"west": [u, v + dv, u + d, v + dv + h], "north": [u + d, v + dv, u + d + w, v + dv + h],
			"east": [u + d + w, v + dv, u + 2 * d + w, v + dv + h], "south": [u + 2 * d + w, v + dv, u + 2 * d + 2 * w, v + dv + h]}
		var uid := Document.uid_of(node)
		for face in layout:
			steps.append(SetFaceFields.new(document, uid, face, {"uv": layout[face], "texture": "#" + id, "rotation": 0}, "", "", {"texture": "#" + id}))
		cursor.x += cross.x
		row_height = maxf(row_height, cross.y)
	if cursor.y + row_height > dimensions.y + 0.001:
		texture_message.emit("The unwrap runs past the bottom of the texture; make the texture taller or select fewer elements.")
	if history == null:
		return false
	var Composite = preload("res://core/commands/composite_command.gd")
	return history.execute(Composite.new(document, steps, "Box Unwrap"))


func face_data() -> Dictionary:
	return selected.get_meta("shape_element").get("faces", {}).get(current_face, {})


func _texture_selected(index: int) -> void:
	if updating:
		return

	var id: String = textures.get_item_metadata(index)
	_set_property("texture", "#" + id)
	if not id.is_empty():
		texture_assigned.emit(id)
	refresh()


func _set_property(key: String, value: Variant) -> void:
	if updating or not is_instance_valid(selected) or current_face.is_empty():
		return

	if not selected.get_meta("shape_element").get("faces", {}).has(current_face):
		return

	var before := _property_state(face_data(), key)
	var after := {"exists": true, "value": _copy(value)}
	if before == after:
		return

	var uid := Document.uid_of(selected)
	if history == null or document == null or not document.has(uid) or (key == "uv" and not uv_edit.is_empty()):
		# A UV drag previews live; _finish_uv_edit() commits it as one command.
		_apply_property(selected, current_face, key, after)
	else:
		var merge_key := "%s:%s:%s" % [uid, current_face, key] if key in ["uv", "glow"] else ""
		history.execute(SetFaceFields.new(document, uid, current_face, {key: _copy(value)}, "Set %s %s" % [current_face.capitalize(), key.to_upper() if key == "uv" else key], merge_key))


func _apply_uv(uv: Array) -> void:
	if updating or not is_instance_valid(selected) or current_face.is_empty():
		return

	if face_data().get("snapUV", true) and uv_editor.drag_button != MOUSE_BUTTON_LEFT:
		for i in range(4):
			uv[i] = snappedf(float(uv[i]), uv_editor.snap_step[i % 2])
	if not uv_edit.is_empty() and not uv_edit.get("resize", false):
		var shift: Vector2 = Vector2(uv[0], uv[1]) - uv_edit.start
		for entry in uv_edit.get("extras", []):
			var start: Array = entry.uv
			# A quiet preview: face_edited would make the app select this face.
			_face_of(entry.node, entry.face).uv = [start[0] + shift.x, start[1] + shift.y, start[2] + shift.x, start[3] + shift.y]
			Geometry.refresh(entry.node, library)
	_set_property("uv", uv.duplicate())
	updating = true
	for i in range(4):
		fields[i].set_value_no_signal(uv[i])
	uv_editor.uv = uv.duplicate()
	uv_editor.queue_redraw()
	updating = false


func size_uv_to_texels() -> void:
	if not is_instance_valid(selected) or current_face.is_empty() or library == null:
		return
	if not extra_faces.is_empty():
		_set_on_selection(func(node: Node3D, face: String): return {"uv": texel_uv(node.get_meta("shape_element"), face)},
			"Size %d UVs to Texels" % selected_faces().size())
		return

	finish_pending()
	if history != null:
		history.break_merge()
	_apply_uv(texel_uv(selected.get_meta("shape_element"), current_face))
	if history != null:
		history.break_merge()


func texel_uv(source: Dictionary, face_name: String) -> Array:
	var face: Dictionary = source.faces[face_name]
	var size_value := Geometry.size_of(source).abs() * Units.PER_BLOCK
	var extent: Vector2
	match face_name:
		"north", "south": extent = Vector2(size_value.x, size_value.y)
		"east", "west": extent = Vector2(size_value.z, size_value.y)
		_: extent = Vector2(size_value.x, size_value.z)
	if posmod(roundi(float(face.get("rotation", 0)) / 90.0), 2) == 1:
		extent = Vector2(extent.y, extent.x)
	var id := str(face.get("texture", "")).trim_prefix("#")
	var step_value: Vector2 = library.pixel_uv_size(id) if not id.is_empty() else Vector2(0.5, 0.5)
	var pixels: Vector2 = extent / library.texel_size
	if face.get("snapUV", true):
		pixels = pixels.floor().max(Vector2.ONE)
	extent = pixels * step_value
	var uv := Geometry.face_uv(face, library.uv_size(id))
	var origin := Vector2(uv[0], uv[1])
	if face.get("snapUV", true):
		origin = origin.snapped(step_value)
	var signs := Vector2(-1 if uv[2] < uv[0] else 1, -1 if uv[3] < uv[1] else 1)
	return [origin.x, origin.y, origin.x + extent.x * signs.x, origin.y + extent.y * signs.y]


## Writes a face value directly, without history. Used for live previews.
func _apply_property(node: Node3D, face_name: String, key: String, state: Dictionary) -> bool:
	if not is_instance_valid(node):
		return false

	var source: Dictionary = node.get_meta("shape_element")
	if not source.get("faces", {}).has(face_name):
		return false

	if state.exists:
		source.faces[face_name][key] = _copy(state.value)
	else:
		source.faces[face_name].erase(key)
	Geometry.refresh(node, library)
	if node == selected and face_name == current_face:
		refresh()
	face_edited.emit(node, face_name)
	return true


func _begin_uv_edit() -> void:
	if is_instance_valid(selected) and not current_face.is_empty():
		var start: Array = Geometry.face_uv(face_data(), library.uv_size(str(face_data().get("texture", "")).trim_prefix("#"))) if library != null else uv_editor.uv
		var extras: Array = []
		for entry in extra_faces:
			var data := _face_of(entry.node, entry.face)
			extras.append({"node": entry.node, "face": entry.face, "before": _property_state(data, "uv"),
				"uv": Geometry.face_uv(data, library.uv_size(str(data.get("texture", "")).trim_prefix("#")))})
		uv_edit = {"node": selected, "face": current_face, "before": _property_state(face_data(), "uv"), "resize": uv_editor.resize_corner >= 0,
			"start": Vector2(start[0], start[1]), "extras": extras}


func _finish_uv_edit() -> void:
	if uv_edit.is_empty():
		return

	var edit := uv_edit
	uv_edit = {}
	if history == null or not is_instance_valid(edit.node):
		return

	var source: Dictionary = edit.node.get_meta("shape_element")
	var after := _property_state(source.faces[edit.face], "uv")
	var uid := Document.uid_of(edit.node)
	if not edit.get("extras", []).is_empty() and after != edit.before and document != null:
		_finish_group_move(edit)
		return
	if after == edit.before or document == null or not document.has(uid):
		return

	# Put the starting value back, then commit the whole gesture as one command
	# so its undo restores exactly where the drag began.
	var face: Dictionary = source.faces[edit.face]
	if edit.before.exists:
		face.uv = _copy(edit.before.value)
	else:
		face.erase("uv")
	var label := ("Resize %s UV" if edit.get("resize", false) else "Move %s UV") % str(edit.face).capitalize()
	history.execute(SetFaceFields.new(document, uid, edit.face, {"uv": _copy(after.value)}, label))


## Commits a move of several faces as one step, from where the drag began.
func _finish_group_move(edit: Dictionary) -> void:
	var steps: Array = []
	for entry in [{"node": edit.node, "face": edit.face, "before": edit.before}] + edit.extras:
		if not is_instance_valid(entry.node):
			continue
		var face: Dictionary = _face_of(entry.node, entry.face)
		var after := _property_state(face, "uv")
		var uid := Document.uid_of(entry.node)
		if after == entry.before or not document.has(uid):
			continue
		if entry.before.exists:
			face.uv = _copy(entry.before.value)
		else:
			face.erase("uv")
		steps.append(SetFaceFields.new(document, uid, entry.face, {"uv": _copy(after.value)}))
	if not steps.is_empty():
		history.execute(preload("res://core/commands/composite_command.gd").new(document, steps, "Move %d UVs" % steps.size()))


func finish_pending() -> void:
	if extra_properties != null:
		extra_properties.finish_pending()
	if is_instance_valid(uv_editor):
		uv_editor.finish_drag()
	_finish_uv_edit()


func _property_state(face: Dictionary, key: String) -> Dictionary:
	return {"exists": face.has(key), "value": _copy(face.get(key))}


func _copy(value: Variant) -> Variant:
	return value.duplicate(true) if value is Array or value is Dictionary else value
