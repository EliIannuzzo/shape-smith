extends RefCounted
## Draws a texture's UV layout into images: one filled rectangle per face in
## its direction's colour, a border inside each rectangle, and optional labels
## (element name, direction letter, orientation arrow). Used by the UV map
## export; the UV canvas can show the same images, so the PNG matches.
##
## Borders sit on each face's own outermost pixels, so two faces that share an
## edge never draw over each other.

## North/south blue, east/west red, up/down green (as VSMC2 colours them).
const COLORS := {
	"north": Color("4f8dff"), "south": Color("4f8dff"),
	"east": Color("ef5b6b"), "west": Color("ef5b6b"),
	"up": Color("62c973"), "down": Color("62c973"),
}
const LETTERS := {"north": "N", "east": "E", "south": "S", "west": "W", "up": "U", "down": "D"}
const FILL_ALPHA := 0.35
const DEFAULT_OPTIONS := {"fills": true, "borders": true, "names": true, "directions": true, "arrows": true, "texture": false}

## A 3×5 pixel font for labels (images have no text drawing). Rows top to bottom.
const GLYPHS := {
	"A": ["010", "101", "111", "101", "101"], "B": ["110", "101", "110", "101", "110"],
	"C": ["011", "100", "100", "100", "011"], "D": ["110", "101", "101", "101", "110"],
	"E": ["111", "100", "110", "100", "111"], "F": ["111", "100", "110", "100", "100"],
	"G": ["011", "100", "101", "101", "011"], "H": ["101", "101", "111", "101", "101"],
	"I": ["111", "010", "010", "010", "111"], "J": ["001", "001", "001", "101", "010"],
	"K": ["101", "101", "110", "101", "101"], "L": ["100", "100", "100", "100", "111"],
	"M": ["101", "111", "101", "101", "101"], "N": ["110", "101", "101", "101", "101"],
	"O": ["010", "101", "101", "101", "010"], "P": ["110", "101", "110", "100", "100"],
	"Q": ["010", "101", "101", "110", "011"], "R": ["110", "101", "110", "101", "101"],
	"S": ["011", "100", "010", "001", "110"], "T": ["111", "010", "010", "010", "010"],
	"U": ["101", "101", "101", "101", "111"], "V": ["101", "101", "101", "101", "010"],
	"W": ["101", "101", "101", "111", "101"], "X": ["101", "101", "010", "101", "101"],
	"Y": ["101", "101", "010", "010", "010"], "Z": ["111", "001", "010", "100", "111"],
	"0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
	"2": ["110", "001", "010", "100", "111"], "3": ["110", "001", "010", "001", "110"],
	"4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "110", "001", "110"],
	"6": ["011", "100", "110", "101", "010"], "7": ["111", "001", "010", "010", "010"],
	"8": ["010", "101", "010", "101", "010"], "9": ["010", "101", "011", "001", "110"],
	"-": ["000", "000", "111", "000", "000"], "_": ["000", "000", "000", "000", "111"],
	".": ["000", "000", "000", "000", "010"], " ": ["000", "000", "000", "000", "000"],
}


## The pixel rectangle a face's UV covers in an image of image_size. Both
## edges round to the nearest pixel boundary, so neighbouring faces that share
## a boundary round the same way and never claim the same pixels.
static func face_rect(uv: Array, uv_dimensions: Vector2, image_size: Vector2i) -> Rect2i:
	var scale_value := Vector2(image_size) / uv_dimensions
	var start := Vector2(float(uv[0]), float(uv[1])) * scale_value
	var end := Vector2(float(uv[2]), float(uv[3])) * scale_value
	var low := Vector2i(roundi(minf(start.x, end.x)), roundi(minf(start.y, end.y)))
	var high := Vector2i(roundi(maxf(start.x, end.x)), roundi(maxf(start.y, end.y)))
	# A face thinner than one output pixel still gets a visible one-pixel line.
	high = high.max(low + Vector2i.ONE)
	return Rect2i(low, high - low)


## Renders the layout. entries: [{uv, face, name, rotation}]. options: see
## DEFAULT_OPTIONS. background: the texture image, drawn under the combined
## image when options.texture is set. Returns {fills, borders, labels, combined}.
static func render(entries: Array, uv_dimensions: Vector2, image_size: Vector2i, options: Dictionary = {}, background: Image = null) -> Dictionary:
	var settings := DEFAULT_OPTIONS.duplicate()
	settings.merge(options, true)
	var layers := {}
	for name in ["fills", "borders", "labels"]:
		layers[name] = Image.create(image_size.x, image_size.y, false, Image.FORMAT_RGBA8)
		layers[name].fill(Color.TRANSPARENT)
	var pixels_per_texel: float = float(image_size.x) / uv_dimensions.x
	var bounds := Rect2i(Vector2i.ZERO, image_size)
	for entry in entries:
		var rect := face_rect(entry.uv, uv_dimensions, image_size)
		var area := rect.intersection(bounds)
		if not area.has_area():
			continue
		var color: Color = COLORS.get(entry.face, Color.WHITE)
		if settings.fills:
			layers.fills.fill_rect(area, Color(color, FILL_ALPHA))
		if settings.borders:
			_border(layers.borders, rect, area, color)
		_labels(layers.labels, rect, area, entry, settings, pixels_per_texel)
	var combined := Image.create(image_size.x, image_size.y, false, Image.FORMAT_RGBA8)
	combined.fill(Color.TRANSPARENT)
	if settings.texture and background != null:
		var under := background.duplicate() as Image
		under.convert(Image.FORMAT_RGBA8)
		under.resize(image_size.x, image_size.y, Image.INTERPOLATE_NEAREST)
		combined.blit_rect(under, bounds, Vector2i.ZERO)
	for name in ["fills", "borders", "labels"]:
		combined.blend_rect(layers[name], bounds, Vector2i.ZERO)
	layers.combined = combined
	return layers


## One pixel wide, on the face's own outermost pixels.
static func _border(image: Image, rect: Rect2i, area: Rect2i, color: Color) -> void:
	var last := area.end - Vector2i.ONE
	for x in range(area.position.x, area.end.x):
		if rect.position.y >= area.position.y:
			image.set_pixel(x, rect.position.y, color)
		if rect.end.y - 1 <= last.y:
			image.set_pixel(x, rect.end.y - 1, color)
	for y in range(area.position.y, area.end.y):
		if rect.position.x >= area.position.x:
			image.set_pixel(rect.position.x, y, color)
		if rect.end.x - 1 <= last.x:
			image.set_pixel(rect.end.x - 1, y, color)


static func _labels(image: Image, rect: Rect2i, area: Rect2i, entry: Dictionary, settings: Dictionary, pixels_per_texel: float) -> void:
	# Letters are 3×5 cells; grow them with the export scale but keep them
	# inside the face.
	var cell := clampi(floori(pixels_per_texel / 4.0), 1, 4)
	var inner := area.grow(-2)
	if not inner.has_area():
		return
	var cursor := inner.position + Vector2i(1, 1)
	if settings.directions:
		var letter: String = LETTERS.get(entry.face, "")
		if _fits(letter, cell, inner, cursor):
			_text(image, letter, cursor, cell, Color.WHITE)
			cursor.x += (letter.length() * 4) * cell + cell
	if settings.names:
		var label := _fit_text(str(entry.get("name", "")).to_upper(), cell, inner.end.x - cursor.x)
		if not label.is_empty() and cursor.y + 5 * cell <= inner.end.y:
			_text(image, label, cursor, cell, Color(1, 1, 1, 0.9))
	if settings.arrows:
		_arrow(image, inner, float(entry.get("rotation", 0)), cell)


static func _fits(text: String, cell: int, inner: Rect2i, at: Vector2i) -> bool:
	return not text.is_empty() and at.x + (text.length() * 4 - 1) * cell <= inner.end.x and at.y + 5 * cell <= inner.end.y


## As many characters of text as fit in width pixels.
static func _fit_text(text: String, cell: int, width: int) -> String:
	var count := clampi((width + cell) / (4 * cell), 0, text.length())
	return text.substr(0, count)


static func _text(image: Image, text: String, at: Vector2i, cell: int, color: Color) -> void:
	var x := at.x
	for character in text:
		var glyph: Array = GLYPHS.get(character, GLYPHS[" "])
		for row in range(5):
			for column in range(3):
				if glyph[row][column] == "1":
					_cell(image, Vector2i(x + column * cell, at.y + row * cell), cell, color)
		x += 4 * cell


static func _cell(image: Image, at: Vector2i, cell: int, color: Color) -> void:
	image.fill_rect(Rect2i(at, Vector2i(cell, cell)).intersection(Rect2i(Vector2i.ZERO, image.get_size())), color)


## A small triangle in the middle of the face pointing to the edge that faces
## "up" on the model, turned by the face's rotation (0, 90, 180 or 270
## degrees, clockwise). It sits in the centre so it never covers the labels.
static func _arrow(image: Image, inner: Rect2i, rotation: float, cell: int) -> void:
	var size := 3 * cell
	if inner.size.x < size * 3 or inner.size.y < size * 3:
		return
	var direction := Vector2.UP.rotated(deg_to_rad(rotation)).round()
	var centre := Vector2(inner.get_center())
	var tip := centre + direction * size * 0.5
	var side := Vector2(-direction.y, direction.x)
	var base := tip - direction * size
	var points := PackedVector2Array([tip, base + side * size, base - side * size])
	var box := Rect2(points[0], Vector2.ZERO).expand(points[1]).expand(points[2])
	for y in range(floori(box.position.y), ceili(box.end.y) + 1):
		for x in range(floori(box.position.x), ceili(box.end.x) + 1):
			if Geometry2D.is_point_in_polygon(Vector2(x, y) + Vector2(0.5, 0.5), points) and Rect2i(Vector2i.ZERO, image.get_size()).has_point(Vector2i(x, y)):
				image.set_pixel(x, y, Color(1, 1, 1, 0.85))
