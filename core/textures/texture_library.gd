extends RefCounted

const MAX_PREVIEW_DIMENSION := 2048


const DEFAULT_TEXEL_SIZE := 0.5
const MIN_TEXEL_SIZE := 0.001
const MAX_TEXEL_SIZE := 1024.0

## Texture ID bindings, asset lookup, and cached VS composite previews.

signal changed
signal edited
signal environment_changed
const AssetPaths = preload("res://core/textures/asset_paths.gd")
const MODES := ["Normal", "Darken", "Lighten", "Multiply", "Screen", "ColorDodge", "ColorBurn", "Overlay", "OverlayCutout"]
var data: Dictionary = {}
var directory := ""
var textures: Dictionary = {}
var materials: Dictionary = {}
var issues: Dictionary = {}
var overlays_enabled := true
var render_mode := 0
var asset_paths = AssetPaths.new()
var linked_paths = AssetPaths.new()
var history
## Editor preference: shape units covered by one image pixel (32 px per block).
var texel_size := DEFAULT_TEXEL_SIZE
var texturing_config_path := "user://texturing.cfg"


func _init() -> void:
	asset_paths.changed.connect(invalidate)
	load_texturing_settings()


func load_texturing_settings() -> void:
	var config := ConfigFile.new()
	if config.load(texturing_config_path) == OK:
		var value: Variant = config.get_value("uv", "texel_size", DEFAULT_TEXEL_SIZE)
		if (value is int or value is float) and is_finite(value) and value >= MIN_TEXEL_SIZE and value <= MAX_TEXEL_SIZE:
			texel_size = float(value)


func set_texel_size(value: float) -> void:
	if not is_finite(value) or value < MIN_TEXEL_SIZE or value > MAX_TEXEL_SIZE or is_equal_approx(value, texel_size):
		return

	texel_size = value
	var config := ConfigFile.new()
	config.set_value("uv", "texel_size", value)
	config.save(texturing_config_path)
	changed.emit()


func pixel_uv_size(id: String) -> Vector2:
	return uv_size(id) / texture(id).get_size()


func bind(shape: Dictionary, path: String) -> void:
	data = shape
	directory = path.get_base_dir()
	linked_paths.additional = []
	if not data.get("textures", {}) is Dictionary:
		data["textures"] = {}
	invalidate()


func ids() -> Array:
	var result: Array = data.get("textures", {}).keys()
	result.sort()
	return result


func data_for_save(path: String) -> Dictionary:
	# Keep the live document rooted at its original texture directory so undo/redo
	# still uses the same references after Save As. Only the output is rebased.
	var result := data.duplicate(true)
	var destination := ProjectSettings.globalize_path(path).get_base_dir()
	for id in result.get("textures", {}):
		var value: Variant = result.textures[id]
		if destination != ProjectSettings.globalize_path(directory):
			value = _definition_for_save(value, destination)
		# Shape.Textures contains AssetLocation strings, not CompositeTextures.
		# Texture Manager uses a composite internally even for a simple link.
		if value is Dictionary and value.get("base") is String:
			var simple := true
			for key in value:
				match key:
					"base": pass
					"blendedOverlays", "overlays": simple = simple and value[key] is Array and value[key].is_empty()
					"rotation": simple = simple and value[key] == 0
					"alpha": simple = simple and value[key] == 255
					_: simple = false
			if simple:
				value = value.base
		result.textures[id] = value
	return result


func _definition_for_save(value: Variant, destination: String) -> Variant:
	if value is String:
		return _reference_for_save(value, destination)

	if value is Dictionary:
		if value.get("base") is String:
			value.base = _reference_for_save(value.base, destination)
		if value.get("blendedOverlays") is Array:
			for i in range(value.blendedOverlays.size()):
				value.blendedOverlays[i] = _definition_for_save(value.blendedOverlays[i], destination)
		if value.get("overlays") is Array:
			for i in range(value.overlays.size()):
				value.overlays[i] = _definition_for_save(value.overlays[i], destination)
	return value


func _reference_for_save(reference: String, destination: String) -> String:
	var layers := reference.split("++")
	for i in range(layers.size()):
		var parts := layers[i].split("~")
		var base := parts[0]
		# Named asset references and aliases stay portable game references.
		if base.is_empty() or base.begins_with("#") or ":" in base or base.is_absolute_path():
			continue

		if not asset_paths.resolve(base).is_empty() or not linked_paths.resolve(base).is_empty():
			continue

		var source := resolve(base)
		if not source.is_empty():
			parts[0] = relative_file(destination, ProjectSettings.globalize_path(source))
			layers[i] = "~".join(parts)
	return "++".join(layers)


static func relative_file(directory_path: String, file_path: String) -> String:
	var base := directory_path.replace("\\", "/").simplify_path().split("/", false)
	var target := file_path.replace("\\", "/").simplify_path().split("/", false)
	var common := 0
	while common < mini(base.size(), target.size()):
		if (base[common].to_lower() != target[common].to_lower()) if OS.has_feature("windows") else (base[common] != target[common]):
			break
		common += 1
	# A reference on another drive must remain absolute.
	if common == 0:
		return file_path

	var parts: PackedStringArray = []
	for i in range(base.size() - common):
		parts.append("..")
	for i in range(common, target.size()):
		parts.append(target[i])
	return "/".join(parts)


func definition(id: String) -> Dictionary:
	var raw: Variant = data.get("textures", {}).get(id, "")
	if raw is Dictionary:
		return raw.duplicate(true)

	var parts := str(raw).split("++")
	var result := {"base": parts[0], "blendedOverlays": []}
	for i in range(1, parts.size()):
		var layer := parts[i].split("~")
		result.blendedOverlays.append({"base": layer[0], "blendMode": layer[1] if layer.size() > 1 else "Normal"})
	return result


func set_definition(id: String, value: Dictionary, prior_linked_paths: Variant = null) -> void:
	var textures_existed := data.has("textures")
	var before: Dictionary = data.get("textures", {})
	var existed := before.has(id)
	var old: Variant = before.get(id)
	old = old.duplicate(true) if old is Dictionary or old is Array else old
	var new_roots: PackedStringArray = linked_paths.additional.duplicate()
	var old_roots: PackedStringArray = prior_linked_paths if prior_linked_paths != null else new_roots.duplicate()
	if existed and old is Dictionary and old == value and old_roots == new_roots:
		return

	var assignments: Array = []
	if not existed and before.is_empty():
		_collect_untextured_faces(data.get("elements", []), assignments)
	var apply := _apply_definition.bind(id, true, value.duplicate(true), true, new_roots, assignments, true)
	var revert := _apply_definition.bind(id, existed, old, textures_existed, old_roots, assignments, false)
	if history != null:
		history.perform(("Change " if existed else "Add ") + "texture #" + id, apply, revert)
	else:
		apply.call()


func _collect_untextured_faces(elements: Array, result: Array) -> void:
	for element in elements:
		for face in element.get("faces", {}).values():
			if face is Dictionary and (face.get("texture") == null or str(face.get("texture", "")).strip_edges() in ["", "#"]):
				result.append({"face": face, "had_texture": face.has("texture"), "texture": face.get("texture")})
		_collect_untextured_faces(element.get("children", []), result)


func _apply_definition(id: String, exists: bool, value: Variant, textures_existed: bool, roots: PackedStringArray, assignments: Array = [], assign := false) -> void:
	linked_paths.additional = roots.duplicate()
	if not data.has("textures"):
		data["textures"] = {}
	if exists:
		data.textures[id] = value.duplicate(true) if value is Dictionary or value is Array else value
	else:
		data.textures.erase(id)
	if not textures_existed and data.textures.is_empty():
		data.erase("textures")
	for entry in assignments:
		if assign:
			entry.face.texture = "#" + id
		elif entry.had_texture:
			entry.face.texture = entry.texture
		else:
			entry.face.erase("texture")
	invalidate()
	edited.emit()


func set_overlay_preview(enabled: bool) -> void:
	if overlays_enabled == enabled:
		return

	if history != null:
		history.perform("Preview overlays", _apply_overlay_preview.bind(enabled), _apply_overlay_preview.bind(overlays_enabled), "", false)
	else:
		_apply_overlay_preview(enabled)


func _apply_overlay_preview(enabled: bool) -> void:
	overlays_enabled = enabled
	invalidate()


func set_asset_paths(settings) -> void:
	if asset_paths.changed.is_connected(invalidate):
		asset_paths.changed.disconnect(invalidate)
	asset_paths = settings
	asset_paths.changed.connect(invalidate)
	invalidate()


func portable_reference(path: String) -> String:
	var binding: Dictionary = asset_paths.reference_for_file(path)
	if not binding.root.is_empty() and not binding.root in asset_paths.roots() and not binding.root in linked_paths.additional:
		linked_paths.additional.append(binding.root)
	return binding.reference


func invalidate() -> void:
	textures.clear()
	materials.clear()
	issues.clear()
	changed.emit()


func uv_size(id: String) -> Vector2:
	var sizes: Variant = data.get("textureSizes", {})
	var value: Variant = sizes.get(id, []) if sizes is Dictionary else []
	if value is Array and value.size() == 2 and _positive(value[0]) and _positive(value[1]):
		return Vector2(value[0], value[1])

	var width: Variant = data.get("textureWidth", 16)
	var height: Variant = data.get("textureHeight", 16)
	return Vector2(float(width) if _positive(width) else 16.0, float(height) if _positive(height) else 16.0)


## A texture whose image has other proportions than the area the shape lays
## out for it (its texture size) cannot line up with the shape's UVs. Returns
## a message for that ID, or "".
func layout_warning(id: String) -> String:
	var image_size := Vector2(texture(id).get_size())
	var layout := uv_size(id)
	if image_size.x <= 0 or image_size.y <= 0 or layout.x <= 0 or layout.y <= 0:
		return ""
	if absf(image_size.x / image_size.y - layout.x / layout.y) <= 0.02 * layout.x / layout.y:
		return ""
	return ("The image for #%s is %d × %d, but the shape lays this texture out as %s × %s, so its UVs will not line up. "
		+ "Link a matching image in Texture Manager.") % [id, image_size.x, image_size.y, _short(layout.x), _short(layout.y)]


static func _short(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) else str(snappedf(value, 0.01))


func texture(id: String) -> Texture2D:
	if not textures.has(id):
		var image := _compose_id(id, [])
		textures[id] = ImageTexture.create_from_image(image)
	return textures[id]


## Game-accurate shading (vs_shape.gdshader) in the Normal render mode. Only the
## main viewport's library turns this on; reference models keep plain materials.
var game_shading := false
## The Lighting panel's settings, applied to every game-shaded material.
var environment := default_environment()
const SHADER_PATH := "res://assets/shaders/vs_shape.gdshader"
const REFLECTIVE_MODES := ["none", "weak", "medium", "strong", "sparkly", "mild"]
## Cull and blend for each renderPass (-1 Auto, then Opaque 0 to Decor 8).
## Auto keeps the editor's soft edges: blended with a depth pre-pass, two-sided.
const PASS_STATES := {
	-1: {"cull": BaseMaterial3D.CULL_DISABLED, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS},
	0: {"cull": BaseMaterial3D.CULL_BACK, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR},
	1: {"cull": BaseMaterial3D.CULL_DISABLED, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR},
	2: {"cull": BaseMaterial3D.CULL_DISABLED, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA},
	3: {"cull": BaseMaterial3D.CULL_BACK, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA},
	4: {"cull": BaseMaterial3D.CULL_DISABLED, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA},
	5: {"cull": BaseMaterial3D.CULL_BACK, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA},
	6: {"cull": BaseMaterial3D.CULL_BACK, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR},
	7: {"cull": BaseMaterial3D.CULL_DISABLED, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR},
	8: {"cull": BaseMaterial3D.CULL_BACK, "transparency": BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR},
}
## Alpha-tested passes cut out pixels below this opacity.
const ALPHA_CUTOFF := 0.25
static var _shader_variants := {}


static func default_environment() -> Dictionary:
	return {"sun_height": 60.0, "sun_angle": 225.0, "time": "day", "weather": "clear", "shadows": false,
		"wind": false, "wind_speed": 0.5}


static func reflective_index(face: Dictionary) -> int:
	var value: Variant = face.get("reflectiveMode", 0)
	var index := REFLECTIVE_MODES.find(str(value).to_lower()) if value is String else int(value) if value is int or value is float else 0
	return index if index >= 0 and index < REFLECTIVE_MODES.size() else 0


static func pass_state(render_pass: int) -> Dictionary:
	return PASS_STATES.get(render_pass, PASS_STATES[-1])


func material(face: Dictionary, shade := true, render_pass := -1) -> Material:
	var id := str(face.get("texture", "")).trim_prefix("#")
	var glow := clampf(float(face.get("glow", 0)), 0.0, 255.0)
	var reflective := reflective_index(face)
	var key := "%s:%s:%s:%s:%s" % [id, glow, shade, render_pass, reflective]
	if materials.has(key):
		return materials[key]

	var state := pass_state(render_pass)
	var textured := not id.is_empty()
	# Untextured faces stay solid unless their pass blends.
	var transparency: int = state.transparency if textured or render_pass >= 0 else BaseMaterial3D.TRANSPARENCY_DISABLED
	var result: Material
	if game_shading and render_mode == 0:
		var shaded := ShaderMaterial.new()
		shaded.shader = _shader_variant(state.cull, transparency)
		shaded.set_shader_parameter("textured", textured)
		shaded.set_shader_parameter("tint", Color.WHITE if textured else Color("b8c9db"))
		if textured:
			shaded.set_shader_parameter("face_texture", texture(id))
			shaded.set_shader_parameter("texture_pixels", Vector2(texture(id).get_size()))
		shaded.set_shader_parameter("glow_level", glow)
		shaded.set_shader_parameter("shade", shade)
		shaded.set_shader_parameter("reflective_mode", reflective)
		shaded.set_shader_parameter("alpha_cutoff", ALPHA_CUTOFF)
		_apply_environment(shaded)
		result = shaded
	else:
		var plain := StandardMaterial3D.new()
		plain.roughness = 1.0
		plain.metallic_specular = 0.0
		plain.cull_mode = state.cull
		plain.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		plain.texture_repeat = true
		plain.transparency = transparency
		if not shade or render_mode != 0:
			plain.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if textured:
			plain.albedo_texture = texture(id)
		else:
			plain.albedo_color = Color("b8c9db")
		if glow > 0:
			plain.emission_enabled = true
			plain.emission = plain.albedo_color
			plain.emission_texture = plain.albedo_texture
			plain.emission_energy_multiplier = glow / 255.0
		result = plain
	# What the face's pass does, readable whichever material type it is.
	result.set_meta("cull_mode", state.cull)
	result.set_meta("transparency", transparency)
	materials[key] = result
	return result


static func _shader_variant(cull: int, transparency: int) -> Shader:
	var key := "%d:%d" % [cull, transparency]
	if not _shader_variants.has(key):
		var defines := ""
		if cull == BaseMaterial3D.CULL_BACK:
			defines += "#define VS_CULL_BACK
"
		if transparency in [BaseMaterial3D.TRANSPARENCY_ALPHA, BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS]:
			defines += "#define VS_BLEND
"
		if transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
			defines += "#define VS_PREPASS
"
		var shader := Shader.new()
		var code: String = (load(SHADER_PATH) as Shader).code
		shader.code = code.replace("shader_type spatial;", "shader_type spatial;
" + defines)
		_shader_variants[key] = shader
	return _shader_variants[key]


## Updates the Lighting panel's settings on every game-shaded material.
func set_environment(values: Dictionary) -> void:
	for key in values:
		environment[key] = values[key]
	for material_value in materials.values():
		if material_value is ShaderMaterial:
			_apply_environment(material_value)
	environment_changed.emit()


## The shader uniforms for the current environment.
func environment_uniforms() -> Dictionary:
	var height := deg_to_rad(clampf(float(environment.sun_height), -90.0, 90.0))
	var angle := deg_to_rad(float(environment.sun_angle))
	var sun := Vector3(sin(angle) * cos(height), sin(height), cos(angle) * cos(height)).normalized()
	var daylight: float = {"day": 1.0, "dusk": 0.6, "night": 0.12}.get(environment.time, 1.0)
	if environment.weather == "overcast":
		daylight *= 0.75
	elif environment.weather == "rain":
		daylight *= 0.6
	return {"sun_direction": sun, "daylight": daylight, "min_shade": 0.34 if environment.shadows else 0.45,
		"wind": bool(environment.wind), "wind_speed": clampf(float(environment.wind_speed), 0.0, 1.0)}


func _apply_environment(target: ShaderMaterial) -> void:
	var uniforms := environment_uniforms()
	for key in uniforms:
		target.set_shader_parameter(key, uniforms[key])


func _compose_id(id: String, stack: Array) -> Image:
	if id in stack or stack.size() > 32:
		issues[id] = "Circular texture reference."
		return missing_image()

	var next := stack.duplicate()
	next.append(id)
	var value := definition(id)
	var image := _asset(str(value.get("base", "")), next)
	var layers: Variant = value.get("blendedOverlays", value.get("overlays", []))
	if not layers is Array:
		issues[id] = "Overlays must be an array."
		layers = []
	for raw in layers if overlays_enabled else []:
		var layer: Dictionary = raw if raw is Dictionary else {"base": str(raw)}
		var mode: Variant = layer.get("blendMode", "Normal")
		var mode_index := blend_mode_index(mode)
		if mode_index < 0:
			issues[id] = "Unknown blend mode: %s" % mode
			continue

		var overlay := _asset(str(layer.get("base", "")), next)
		if overlay.get_size() != image.get_size():
			overlay.resize(image.get_width(), image.get_height(), Image.INTERPOLATE_NEAREST)
		for y in range(image.get_height()):
			for x in range(image.get_width()):
				image.set_pixel(x, y, blend(image.get_pixel(x, y), overlay.get_pixel(x, y), mode_index))
	var turns := posmod(roundi(_numeric(value.get("rotation", 0), 0.0) / 90.0), 4)
	for i in range(turns):
		image.rotate_90(CLOCKWISE)
	var alpha := clampf(_numeric(value.get("alpha", 255), 255.0) / 255.0, 0.0, 1.0)
	if alpha < 1.0:
		for y in range(image.get_height()):
			for x in range(image.get_width()):
				var color := image.get_pixel(x, y)
				color.a *= alpha
				image.set_pixel(x, y, color)
	return image


func _asset(reference: String, stack: Array) -> Image:
	if reference.begins_with("#"):
		return _compose_id(reference.trim_prefix("#"), stack)

	var resolved := resolve(reference)
	if resolved.is_empty():
		issues[reference] = "Asset not found: %s. Link it in Texture Manager or choose an assets folder." % reference
		return missing_image()

	var image: Image
	if resolved.begins_with("res://") and ResourceLoader.exists(resolved, "Texture2D"):
		var imported := load(resolved) as Texture2D
		image = imported.get_image() if imported != null else null
	else:
		image = Image.load_from_file(resolved)
	if image == null or image.is_empty():
		issues[reference] = "Could not read image: %s" % reference
		return missing_image()

	if image.get_width() > MAX_PREVIEW_DIMENSION or image.get_height() > MAX_PREVIEW_DIMENSION:
		issues[reference] = "Preview images must be at most 2048 × 2048 pixels."
		return missing_image()

	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	return image


func resolve(reference: String) -> String:
	if reference.is_empty():
		return ""

	var path := reference.replace("\\", "/")
	if path.is_absolute_path() and FileAccess.file_exists(path):
		return path
	# A moved editor project may still contain an old machine's absolute path.
	if path.is_absolute_path() and "/textures/" in path:
		path = path.split("/textures/", false, 1)[1]
	var configured: String = asset_paths.resolve(path)
	if not configured.is_empty():
		return configured

	var linked: String = linked_paths.resolve(path)
	if not linked.is_empty():
		return linked

	var nearby = AssetPaths.new()
	var cursor := directory
	while not cursor.is_empty():
		if cursor.get_file() == "shapes":
			nearby.additional.append(cursor.get_base_dir())
		var parent := cursor.get_base_dir()
		if parent == cursor:
			break
		cursor = parent
	var resolved: String = nearby.resolve(path)
	if not resolved.is_empty():
		return resolved
	# Relative files beside a standalone shape remain supported as a fallback.
	if not ":" in path:
		if path.get_extension().is_empty():
			path += ".png"
		var local_directory := ProjectSettings.globalize_path(directory)
		for candidate in [local_directory.path_join(path).simplify_path(), local_directory.path_join("textures").path_join(path).simplify_path()]:
			if FileAccess.file_exists(candidate):
				return candidate

	return ""


static func blend(base: Color, over: Color, mode: int) -> Color:
	if mode == 8:
		return Color(base.r, base.g, base.b, 0.0 if over.a > 0.0 else base.a)

	var alpha := over.a + base.a * (1.0 - over.a)
	if alpha <= 0:
		return Color.TRANSPARENT

	var result := Color(0, 0, 0, alpha)
	for channel in range(3):
		var a: float = base[channel]
		var b: float = over[channel]
		var mixed: float = b
		match mode:
			1: mixed = minf(a, b)
			2: mixed = maxf(a, b)
			3: mixed = a * b
			4: mixed = 1.0 - (1.0 - a) * (1.0 - b)
			5: mixed = 1.0 if b >= 1.0 else minf(1.0, a / (1.0 - b))
			6: mixed = 0.0 if b <= 0.0 else maxf(0.0, 1.0 - (1.0 - a) / b)
			7:
				# VS premultiplies the overlay color for its Overlay blend operation.
				b *= over.a
				mixed = 2.0 * a * b if a < 0.5 else 1.0 - 2.0 * (1.0 - a) * (1.0 - b)
		result[channel] = (a * base.a * (1.0 - over.a) + b * over.a * (1.0 - base.a) + mixed * base.a * over.a) / alpha
	return result


static func missing_image() -> Image:
	var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y in range(16):
		for x in range(16):
			image.set_pixel(x, y, Color("e879d1") if (x / 4 + y / 4) % 2 == 0 else Color("282e34"))
	return image


static func _positive(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and value > 0


static func blend_mode_index(value: Variant) -> int:
	if value is int or value is float:
		return int(value) if is_finite(float(value)) and value == floor(value) and value >= 0 and value < MODES.size() else -1

	var text := str(value)
	if text.is_valid_int():
		var index := int(text)
		return index if index >= 0 and index < MODES.size() else -1

	for i in range(MODES.size()):
		if text.to_lower() == MODES[i].to_lower():
			return i

	return -1


static func _numeric(value: Variant, fallback: float) -> float:
	return float(value) if (value is float or value is int) and is_finite(float(value)) else fallback
