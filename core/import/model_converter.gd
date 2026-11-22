extends RefCounted
## Converts a glTF or FBX model (loaded by Godot's GLTFDocument / FBXDocument)
## into a Vintage Story shape.
##
## Nodes and skeleton bones become elements: a node holding a single box mesh
## becomes that box (turning about the node's origin, so its animation still
## fits), other nodes become empty groups. Every connected part of a mesh is
## fitted as a box (its corners and faces must lie on one oriented box);
## parts that are not boxes are voxelised into merged cubes, or skipped. A box
## face whose UVs form a rectangle gets that `uv` and face rotation. Images
## are saved as PNGs next to the model and bound as textures. Animations are
## sampled at 30 fps into offset, rotation and stretch keys, then reduced with
## the baker's tolerances. Everything inexact is listed in the report.

const Baker = preload("res://core/animation/animation_baker.gd")
const RotationPaths = preload("res://core/animation/rotation_paths.gd")
const Geometry = preload("res://core/model/shape_geometry.gd")
const FPS := 30.0
const FACE_NAMES := ["north", "east", "south", "west", "up", "down"]
## Outward normal of each face in an element's own axes.
const FACE_NORMALS := [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0)]
const EPSILON := 0.001
## Voxelising tests each cube against each triangle; above this many tests a
## part is skipped instead (choose a bigger voxel size).
const MAX_VOXEL_WORK := 4000000.0
const DEFAULTS := {
	"scale": 16.0,              # shape units per metre (Blockbench: 16 px = 1 m)
	"offset": [8.0, 0.0, 8.0],  # where the model's origin goes (centre of the block)
	"up": "y",                  # "y" or "z"
	"non_box": "voxelise",      # "voxelise" or "skip"
	"voxel_size": 1.0,          # shape units
	"snap": false,              # round coordinates to whole shape units
	"texture_dir": "",          # where extracted images are written
	"texture_prefix": "model",
	"animations": true,
}

var options: Dictionary = {}
var report := {"boxes": 0, "groups": 0, "voxels": 0, "approximated": [], "skipped": []}
var textures: Dictionary = {}       # id -> path
var texture_sizes: Dictionary = {}  # id -> Vector2i
var _image_ids: Dictionary = {}     # Image instance id -> texture id
var _names: Dictionary = {}
var _frames: Array = []             # every frame that became an element: {key, element, rest, kind, lmin}
var _root_correction := Transform3D.IDENTITY


## Reads a model file into a Godot scene. Returns {scene, error}.
static func load_scene(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"scene": null, "error": "Could not read %s: the file was not found." % path.get_file()}
	var document: GLTFDocument = FBXDocument.new() if path.get_extension().to_lower() == "fbx" else GLTFDocument.new()
	var state: GLTFState = FBXState.new() if document is FBXDocument else GLTFState.new()
	var error := document.append_from_file(path, state)
	if error != OK:
		return {"scene": null, "error": "Could not read %s (error %d)." % [path.get_file(), error]}
	var scene := document.generate_scene(state)
	if scene == null:
		return {"scene": null, "error": "%s has no scene to import." % path.get_file()}
	return {"scene": scene, "error": ""}


## Counts for the import dialog: meshes, triangles, bones, animations.
static func stats(scene: Node) -> Dictionary:
	var result := {"meshes": 0, "triangles": 0, "bones": 0, "animations": 0}
	var stack: Array = [scene]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and node.mesh != null:
			result.meshes += 1
			for surface in range(node.mesh.get_surface_count()):
				var arrays: Array = node.mesh.surface_get_arrays(surface)
				var indices: Variant = arrays[Mesh.ARRAY_INDEX]
				result.triangles += (indices.size() if indices != null else arrays[Mesh.ARRAY_VERTEX].size()) / 3
		elif node is Skeleton3D:
			result.bones += node.get_bone_count()
		elif node is AnimationPlayer:
			result.animations += node.get_animation_list().size()
		stack.append_array(node.get_children())
	return result


## The conversion. Returns {data, report}.
func convert(scene: Node, settings := {}) -> Dictionary:
	options = DEFAULTS.duplicate(true)
	options.merge(settings, true)
	var scale := float(options.scale)
	var offset := Vector3(options.offset[0], options.offset[1], options.offset[2])
	_root_correction = Transform3D(Basis(Vector3.RIGHT, -PI / 2.0) if options.up == "z" else Basis(), Vector3.ZERO)
	# The model's frame in shape units: units per metre, then the offset.
	var root_frame := {"key": "", "name": "", "rest": Transform3D(Basis(), offset) * Transform3D(Basis.from_scale(Vector3.ONE * scale), Vector3.ZERO) * _root_correction, "children": [], "parts": []}
	for child in scene.get_children():
		_collect(child, root_frame, scene)
	for frame in root_frame.children:
		frame.top = true
	var elements: Array = []
	for frame in root_frame.children:
		var element := _element(frame, root_frame.rest, true)
		if not element.is_empty():
			elements.append(element)
	for part in root_frame.parts:
		elements.append_array(_part_elements(part, root_frame.rest))
	var data := {"textureWidth": 16, "textureHeight": 16, "elements": elements}
	if not textures.is_empty():
		data.textures = textures.duplicate()
		var first: Vector2i = texture_sizes[textures.keys()[0]]
		data.textureWidth = first.x
		data.textureHeight = first.y
		var sizes := {}
		for id in texture_sizes:
			if texture_sizes[id] != first:
				sizes[id] = [texture_sizes[id].x, texture_sizes[id].y]
		if not sizes.is_empty():
			data.textureSizes = sizes
	if options.animations:
		var clips := _animations(scene)
		if not clips.is_empty():
			data.animations = clips
	return {"data": data, "report": report}


# --- Scene to frames -------------------------------------------------------------------

## A frame is a node or bone that becomes an element: its rest transform in its
## parent frame (metres), its child frames and its mesh parts.
func _collect(node: Node, parent: Dictionary, scene: Node) -> void:
	if not node is Node3D or node is AnimationPlayer:
		return
	var frame := {"key": str(scene.get_path_to(node)), "name": _unique(node.name), "rest": node.transform, "children": [], "parts": [], "node": node}
	parent.children.append(frame)
	if node is MeshInstance3D and node.mesh != null:
		if node.skin != null and node.get_node_or_null(node.skeleton) is Skeleton3D:
			_skinned_parts(node, scene)
		else:
			frame.parts.append_array(_parts(node.mesh, Transform3D.IDENTITY, node))
	if node is Skeleton3D:
		_collect_bones(node, frame, scene)
	for child in node.get_children():
		_collect(child, frame, scene)


func _collect_bones(skeleton: Skeleton3D, frame: Dictionary, scene: Node) -> void:
	var made := {}
	for bone in range(skeleton.get_bone_count()):
		made[bone] = {"key": "%s:%s" % [scene.get_path_to(skeleton), skeleton.get_bone_name(bone)], "name": _unique(skeleton.get_bone_name(bone)),
			"rest": skeleton.get_bone_rest(bone), "children": [], "parts": [], "bone": bone, "skeleton": skeleton}
	for bone in made:
		var parent := skeleton.get_bone_parent(bone)
		(made[parent].children if parent >= 0 else frame.children).append(made[bone])
	skeleton.set_meta("shapesmith_bone_frames", made)


## Skinned meshes: each part goes under the bone that weights it most, in that
## bone's rest frame.
func _skinned_parts(mesh_node: MeshInstance3D, _scene: Node) -> void:
	var skeleton: Skeleton3D = mesh_node.get_node(mesh_node.skeleton)
	if not skeleton.has_meta("shapesmith_bone_frames"):
		report.approximated.append({"name": mesh_node.name, "reason": "Its skeleton could not be read; the mesh was skipped."})
		return
	var frames: Dictionary = skeleton.get_meta("shapesmith_bone_frames")
	var mesh_to_skeleton := _scene_transform(skeleton).affine_inverse() * _scene_transform(mesh_node)
	for part in _parts(mesh_node.mesh, Transform3D.IDENTITY, mesh_node):
		var bone := _heaviest_bone(part, mesh_node.skin)
		var frame: Dictionary = frames.get(bone, frames.get(0, {}))
		if frame.is_empty():
			continue
		part.transform = skeleton.get_bone_global_rest(frame.bone).affine_inverse() * mesh_to_skeleton
		frame.parts.append(part)


## A node's transform relative to the imported scene's root (the scene is not
## in the tree, so global transforms are not available).
static func _scene_transform(node: Node) -> Transform3D:
	var result := Transform3D.IDENTITY
	var cursor: Node = node
	while cursor is Node3D and cursor.get_parent() != null:
		result = cursor.transform * result
		cursor = cursor.get_parent()
	return result


func _heaviest_bone(part: Dictionary, skin: Skin) -> int:
	var totals := {}
	for i in range(part.bones.size()):
		var joint: int = part.bones[i]
		totals[joint] = totals.get(joint, 0.0) + part.weights[i]
	var best := 0
	var most := -1.0
	for joint in totals:
		if totals[joint] > most:
			most = totals[joint]
			best = joint
	if skin != null and best < skin.get_bind_count():
		var bone := skin.get_bind_bone(best)
		return bone if bone >= 0 else best
	return best


func _unique(raw: String) -> String:
	var base := raw.strip_edges() if not raw.strip_edges().is_empty() else "Element"
	var value := base
	var count := 2
	while _names.has(value.to_lower()):
		value = "%s%d" % [base, count]
		count += 1
	_names[value.to_lower()] = true
	return value


# --- Mesh parts ---------------------------------------------------------------------------

## Splits a mesh into connected parts: {triangles: [[{p, uv}] x3], material, transform}.
func _parts(mesh: Mesh, transform: Transform3D, owner: Node) -> Array:
	var result: Array = []
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
		var vertex_normals: Variant = arrays[Mesh.ARRAY_NORMAL]
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		var bones: Variant = arrays[Mesh.ARRAY_BONES]
		var weights: Variant = arrays[Mesh.ARRAY_WEIGHTS]
		var order: Array = Array(indices) if indices != null else range(vertices.size())
		var material: Material = owner.get_active_material(surface) if owner is MeshInstance3D else mesh.surface_get_material(surface)
		# Union-find over welded positions.
		var weld := {}
		var parent: Array = []
		for i in range(vertices.size()):
			var key := _weld_key(vertices[i])
			if not weld.has(key):
				weld[key] = parent.size()
				parent.append(parent.size())
		for t in range(0, order.size() - 2, 3):
			var a: int = weld[_weld_key(vertices[order[t]])]
			for k in [1, 2]:
				_union(parent, a, weld[_weld_key(vertices[order[t + k]])])
		var groups := {}
		for t in range(0, order.size() - 2, 3):
			var root := _find(parent, weld[_weld_key(vertices[order[t]])])
			if not groups.has(root):
				groups[root] = {"triangles": [], "material": material, "transform": transform, "bones": [], "weights": [], "owner": str(owner.name)}
			var triangle: Array = []
			for k in range(3):
				var index: int = order[t + k]
				triangle.append({"p": vertices[index], "uv": uvs[index] if uvs != null and index < uvs.size() else Vector2.ZERO,
					"n": vertex_normals[index] if vertex_normals != null and index < vertex_normals.size() else Vector3.ZERO})
				if bones != null and weights != null:
					for j in range(4):
						if index * 4 + j < bones.size():
							groups[root].bones.append(bones[index * 4 + j])
							groups[root].weights.append(weights[index * 4 + j])
			groups[root].triangles.append(triangle)
		result.append_array(groups.values())
	return result


static func _weld_key(point: Vector3) -> Vector3i:
	return Vector3i(roundi(point.x * 10000.0), roundi(point.y * 10000.0), roundi(point.z * 10000.0))


static func _find(parent: Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _union(parent: Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[rb] = ra


## Fits a part as an oriented box in `frame` (a transform from the part's mesh
## space to the target frame, in shape units). Returns {} when the part is
## not a box, else {axes: Basis, min, max, faces: {face_index: [triangles]}}.
static func fit_box(triangles: Array, frame: Transform3D) -> Dictionary:
	# A box has at most 8 corners: anything with more positions is not one.
	var distinct := {}
	for triangle in triangles:
		for vertex in triangle:
			distinct[_weld_key(vertex.p)] = true
			if distinct.size() > 8:
				return {}
	var points: Array = []
	var normals: Array = []
	for triangle in triangles:
		var a: Vector3 = frame * triangle[0].p
		var b: Vector3 = frame * triangle[1].p
		var c: Vector3 = frame * triangle[2].p
		var normal := _outward(triangle, a, b, c, frame)
		if normal == Vector3.ZERO:
			continue
		normals.append(normal)
		for p in [a, b, c]:
			if not points.any(func(q): return q.distance_to(p) < EPSILON):
				points.append(p)
	if normals.is_empty():
		return {}
	# Axis directions from the face normals (up to sign), completed with edges.
	var axes: Array = []
	for normal in normals:
		if not axes.any(func(axis): return absf(axis.dot(normal)) > 1.0 - EPSILON):
			axes.append(normal)
	if axes.size() > 3:
		return {}
	for i in range(axes.size()):
		for j in range(i + 1, axes.size()):
			if absf(axes[i].dot(axes[j])) > EPSILON:
				return {}
	if axes.size() < 3:
		# A flat part: its sides meet at right angles in each triangle, so
		# take the two sides at a triangle's square corner (not its diagonal).
		for triangle in triangles:
			if axes.size() >= 3:
				break
			var corners: Array = [frame * triangle[0].p, frame * triangle[1].p, frame * triangle[2].p]
			for k in range(3):
				var one: Vector3 = corners[(k + 1) % 3] - corners[k]
				var two: Vector3 = corners[(k + 2) % 3] - corners[k]
				if one.length() < EPSILON or two.length() < EPSILON or absf(one.normalized().dot(two.normalized())) > EPSILON:
					continue
				for edge in [one, two]:
					for axis in axes:
						edge -= axis * edge.dot(axis)
					if edge.length() > EPSILON and axes.size() < 3 and not axes.any(func(axis): return absf(axis.dot(edge.normalized())) > 1.0 - EPSILON):
						axes.append(edge.normalized())
				break
		if axes.size() == 2:
			axes.append(axes[0].cross(axes[1]).normalized())
		if axes.size() < 3:
			return {}
	# Name the axes after the frame axes they lie closest to, pointing forward.
	var basis_axes: Array = [null, null, null]
	for axis in axes:
		var best := 0
		for k in range(3):
			if absf(axis[k]) > absf(axis[best]):
				best = k
		if basis_axes[best] != null:
			best = [0, 1, 2].filter(func(k): return basis_axes[k] == null)[0]
		basis_axes[best] = axis if axis[best] >= 0.0 else -axis
	var basis := Basis(basis_axes[0], basis_axes[1], basis_axes[2])
	if basis.determinant() < 0.0:
		basis.z = -basis.z
	var low := Vector3(INF, INF, INF)
	var high := Vector3(-INF, -INF, -INF)
	for p in points:
		var local: Vector3 = basis.transposed() * p
		low = low.min(local)
		high = high.max(local)
	# Every point must be a box corner, every triangle on a box face.
	for p in points:
		var local: Vector3 = basis.transposed() * p
		for k in range(3):
			if absf(local[k] - low[k]) > EPSILON and absf(local[k] - high[k]) > EPSILON:
				return {}
	var faces := {}
	for triangle in triangles:
		var a: Vector3 = basis.transposed() * (frame * triangle[0].p)
		var b: Vector3 = basis.transposed() * (frame * triangle[1].p)
		var c: Vector3 = basis.transposed() * (frame * triangle[2].p)
		var normal := basis.transposed() * _outward(triangle, frame * triangle[0].p, frame * triangle[1].p, frame * triangle[2].p, frame)
		if normal == Vector3.ZERO:
			continue
		var face := -1
		for f in range(6):
			if normal.dot(FACE_NORMALS[f]) > 1.0 - EPSILON:
				face = f
		if face < 0:
			return {}
		var axis: int = [2, 0, 2, 0, 1, 1][face]
		var plane: float = high[axis] if FACE_NORMALS[face][axis] > 0.0 else low[axis]
		for q in [a, b, c]:
			if absf(q[axis] - plane) > EPSILON:
				return {}
		if not faces.has(face):
			faces[face] = []
		faces[face].append(triangle)
	return {"axes": basis, "min": low, "max": high, "faces": faces, "frame": frame}


## A triangle's outward normal: its plane's normal, turned to agree with the
## mesh's vertex normals (or Godot's clockwise front faces without them).
static func _outward(triangle: Array, a: Vector3, b: Vector3, c: Vector3, frame: Transform3D) -> Vector3:
	var normal := (b - a).cross(c - a)
	if normal.length() < 0.0000001:
		return Vector3.ZERO
	normal = normal.normalized()
	var hint: Vector3 = triangle[0].get("n", Vector3.ZERO) + triangle[1].get("n", Vector3.ZERO) + triangle[2].get("n", Vector3.ZERO)
	hint = frame.basis.inverse().transposed() * hint
	if hint.length() > 0.0001:
		return normal if normal.dot(hint) >= 0.0 else -normal
	return -normal


# --- Frames to elements ------------------------------------------------------------------

## The element for a frame whose rest transform is in `parent_frame` (the
## parent element's frame, in shape units, origin at its pivot).
func _element(frame: Dictionary, parent_frame: Transform3D, top := false) -> Dictionary:
	var scale := float(options.scale)
	# The frame in its parent's shape-unit space, without scale.
	var local: Transform3D = frame.rest
	var units := Transform3D(local.basis.orthonormalized(), local.origin * scale) if not top else _root_space(local, parent_frame)
	if not top and not local.basis.get_scale().is_equal_approx(Vector3.ONE):
		report.approximated.append({"name": frame.name, "reason": "It was scaled; the scale was left out."})
	var pivot := units.origin
	var rotation := _euler(units.basis)
	# Mesh frame: from the node's mesh space to its own frame in shape units.
	var to_own := Transform3D(Basis.from_scale(Vector3.ONE * scale), Vector3.ZERO)
	if top:
		to_own = Transform3D(Basis.from_scale(local.basis.get_scale() * scale), Vector3.ZERO)
	var children: Array = []
	# A node holding one box and nothing else becomes that box.
	if frame.children.is_empty() and frame.parts.size() == 1:
		var part: Dictionary = frame.parts[0]
		var box := fit_box(part.triangles, to_own * part.transform)
		if not box.is_empty() and box.axes.is_equal_approx(Basis()):
			# Turning about the node's origin keeps its animation exact.
			var element := _box_element(frame.name, box, part, pivot + box.min, pivot + box.max, pivot, rotation)
			_frames.append({"key": frame.key, "element": element, "rest": units, "lmin": box.min, "frame": frame})
			return element
	var element := {"name": frame.name, "from": _array(pivot), "to": _array(pivot), "rotationOrigin": _array(pivot)}
	_set_rotation(element, rotation)
	report.groups += 1
	_frames.append({"key": frame.key, "element": element, "rest": units, "lmin": Vector3.ZERO, "frame": frame})
	for child in frame.children:
		var made := _element(child, units)
		if not made.is_empty():
			children.append(made)
	for part in frame.parts:
		children.append_array(_part_elements(part, Transform3D.IDENTITY, to_own, frame.name))
	if not children.is_empty():
		element.children = children
	return element


## Top-level frames sit in the model frame: units per metre, the offset, and
## the up-axis correction, applied to their transform.
func _root_space(local: Transform3D, model: Transform3D) -> Transform3D:
	var placed := model * local
	return Transform3D(placed.basis.orthonormalized(), placed.origin)


## Elements for one mesh part in its frame (`to_own` maps mesh space to the
## frame's shape units). Boxes become one element each; other parts are
## voxelised or skipped.
func _part_elements(part: Dictionary, _parent: Transform3D, to_own := Transform3D.IDENTITY, owner_name := "") -> Array:
	if to_own == Transform3D.IDENTITY:
		to_own = Transform3D(Basis.from_scale(Vector3.ONE * float(options.scale)), Vector3.ZERO)
	var frame: Transform3D = to_own * part.transform
	var box := fit_box(part.triangles, frame)
	var base := str(part.get("owner", owner_name))
	var name_value := _unique((base if not base.is_empty() else "Part") + "_part")
	if not box.is_empty():
		# An oriented box turns about its centre.
		var middle: Vector3 = (box.min + box.max) * 0.5
		var center: Vector3 = box.axes * middle
		return [_box_element(name_value, box, part, center + box.min - middle, center + box.max - middle, center, _euler(box.axes))]
	if options.non_box == "skip":
		report.skipped.append({"name": name_value, "reason": "Not a box; skipped."})
		return []
	var cubes := voxelise(part.triangles, frame, float(options.voxel_size))
	if cubes.is_empty():
		report.skipped.append({"name": name_value, "reason": "Not a box, and too detailed to voxelise at %s units; skipped. Try a bigger voxel size." % options.voxel_size})
		return []
	report.approximated.append({"name": name_value, "reason": "Not a box; voxelised into %d cubes." % cubes.size()})
	report.voxels += cubes.size()
	var result: Array = []
	for i in range(cubes.size()):
		result.append({"name": _unique("%s_v%d" % [name_value, i + 1]), "from": _array(cubes[i].position), "to": _array(cubes[i].end),
			"faces": _plain_faces(part)})
	return result


func _plain_faces(part: Dictionary) -> Dictionary:
	var id := _texture_for(part.material)
	var faces := {}
	for face in FACE_NAMES:
		faces[face] = {"uv": [0, 0, 1, 1]} if id.is_empty() else {"texture": "#" + id, "uv": [0, 0, 1, 1]}
	return faces


## One box element: its corners in the parent frame are
## origin + R * (p - origin) for p between `from` and `to`, R its rotation.
func _box_element(name_value: String, box: Dictionary, part: Dictionary, from: Vector3, to: Vector3, origin: Vector3, rotation: Vector3) -> Dictionary:
	var element := {"name": name_value, "from": _array(from), "to": _array(to), "rotationOrigin": _array(origin)}
	_set_rotation(element, rotation)
	element.faces = _faces(box, part, to - from)
	report.boxes += 1
	return element


## Faces with UVs: each face's corners are matched to the mesh's vertices and
## their UVs read as a rectangle with a quarter-turn rotation.
func _faces(box: Dictionary, part: Dictionary, size: Vector3) -> Dictionary:
	var faces := {}
	var id := _texture_for(part.material)
	var texture_size: Vector2 = Vector2(texture_sizes.get(id, Vector2i(16, 16)))
	var corners := Geometry.corners(size / 16.0)
	var frame: Transform3D = box.frame
	for face in box.faces:
		var found: Array = []
		for c in range(4):
			var local: Vector3 = box.min + corners[face][c] * 16.0
			var uv: Variant = null
			for triangle in box.faces[face]:
				for vertex in triangle:
					if (box.axes.transposed() * (frame * vertex.p)).distance_to(local) < EPSILON:
						uv = vertex.uv
			found.append(uv)
		var entry := {}
		if not id.is_empty():
			entry.texture = "#" + id
		var solved := solve_uv(found, face, texture_size)
		entry.uv = solved.uv
		if solved.rotation != 0:
			entry.rotation = solved.rotation
		if not solved.exact:
			report.approximated.append({"name": "%s %s" % [part.get("owner", ""), FACE_NAMES[face]], "reason": "Its UVs are not a rectangle; their bounds were used."})
		faces[FACE_NAMES[face]] = entry
	return faces


## The face `uv` [u1, v1, u2, v2] and rotation that give each corner the UV
## it has in the model (UVs 0..1, top-left origin). Returns {uv, rotation, exact}.
static func solve_uv(corner_uvs: Array, face: int, texture_size: Vector2) -> Dictionary:
	var points: Array = []
	for uv in corner_uvs:
		if uv == null:
			return _bounds_uv(corner_uvs, texture_size)
		points.append(Vector2(uv.x * texture_size.x, uv.y * texture_size.y))
	var us: Array = []
	var vs: Array = []
	for p in points:
		if not us.any(func(u): return absf(u - p.x) < 0.01):
			us.append(p.x)
		if not vs.any(func(v): return absf(v - p.y) < 0.01):
			vs.append(p.y)
	if us.size() > 2 or vs.size() > 2:
		return _bounds_uv(corner_uvs, texture_size)
	if us.size() == 1:
		us.append(us[0])
	if vs.size() == 1:
		vs.append(vs[0])
	us.sort()
	vs.sort()
	# A plain rectangle with a turn first; a mirrored one only when needed.
	for flips in [[0, 0], [1, 0], [0, 1], [1, 1]]:
		for turns in range(4):
			var u_first: int = flips[0]
			var v_first: int = flips[1]
			var rect := [us[u_first], vs[v_first], us[1 - u_first], vs[1 - v_first]]
			var coords := [Vector2(rect[0], rect[1]), Vector2(rect[0], rect[3]), Vector2(rect[2], rect[3]), Vector2(rect[2], rect[1])]
			if face == 5:
				coords = [Vector2(rect[2], rect[3]), Vector2(rect[2], rect[1]), Vector2(rect[0], rect[1]), Vector2(rect[0], rect[3])]
			var matches := true
			for c in range(4):
				if coords[posmod(c + turns, 4)].distance_to(points[c]) > 0.01:
					matches = false
					break
			if matches:
				return {"uv": rect.map(func(value): return clean(value)), "rotation": turns * 90, "exact": true}
	return _bounds_uv(corner_uvs, texture_size)


static func _bounds_uv(corner_uvs: Array, texture_size: Vector2) -> Dictionary:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for uv in corner_uvs:
		if uv != null:
			low = low.min(Vector2(uv.x * texture_size.x, uv.y * texture_size.y))
			high = high.max(Vector2(uv.x * texture_size.x, uv.y * texture_size.y))
	if low.x == INF:
		low = Vector2.ZERO
		high = Vector2.ONE
	return {"uv": [clean(low.x), clean(low.y), clean(high.x), clean(high.y)], "rotation": 0, "exact": false}


# --- Textures -------------------------------------------------------------------------------

## The texture ID for a material's base image, saving the image the first
## time it is seen. "" when the material has no image.
func _texture_for(material: Material) -> String:
	var texture: Texture2D = material.albedo_texture if material is BaseMaterial3D else null
	if texture == null:
		return ""
	var image := texture.get_image()
	if image == null:
		return ""
	var key := texture.get_instance_id()
	if _image_ids.has(key):
		return _image_ids[key]
	var id := "texture%d" % (textures.size() + 1) if textures.size() > 0 else "texture"
	var directory := str(options.texture_dir)
	if directory.is_empty():
		directory = "user://imported-textures"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var file := directory.path_join("%s-%s.png" % [options.texture_prefix, id])
	if image.is_compressed():
		image.decompress()
	image.save_png(file)
	textures[id] = ProjectSettings.globalize_path(file)
	texture_sizes[id] = image.get_size()
	_image_ids[key] = id
	return id


# --- Voxelising ---------------------------------------------------------------------------------

## Fills a closed mesh with cubes of `size` shape units (inside by ray parity,
## plus every cube the surface passes through), merged greedily into boxes.
static func voxelise(triangles: Array, frame: Transform3D, size: float) -> Array:
	var world: Array = []
	var low := Vector3(INF, INF, INF)
	var high := Vector3(-INF, -INF, -INF)
	for triangle in triangles:
		var points: Array = [frame * triangle[0].p, frame * triangle[1].p, frame * triangle[2].p]
		world.append(points)
		for p in points:
			low = low.min(p)
			high = high.max(p)
	if world.is_empty():
		return []
	var origin := (low / size).floor() * size
	var counts := Vector3i(((high - origin) / size).ceil())
	counts = counts.max(Vector3i.ONE)
	# Every cube is tested against every triangle: give up on huge jobs.
	if float(counts.x) * counts.y * counts.z * world.size() > MAX_VOXEL_WORK:
		return []
	var filled := {}
	for x in range(counts.x):
		for y in range(counts.y):
			for z in range(counts.z):
				var center := origin + (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) * size
				var crossings := 0
				for t in world:
					var hit: Variant = Geometry3D.ray_intersects_triangle(center, Vector3(1, 0.000123, 0.000457), t[0], t[1], t[2])
					if hit != null:
						crossings += 1
				if crossings % 2 == 1:
					filled[Vector3i(x, y, z)] = true
	for t in world:
		var steps := maxi(2, int(ceilf(maxf(t[0].distance_to(t[1]), maxf(t[1].distance_to(t[2]), t[0].distance_to(t[2]))) / size * 2.0)))
		for i in range(steps + 1):
			for j in range(steps + 1 - i):
				var p: Vector3 = t[0] + (t[1] - t[0]) * (float(i) / steps) + (t[2] - t[0]) * (float(j) / steps)
				var cell := Vector3i(((p - origin) / size).floor())
				filled[cell.clamp(Vector3i.ZERO, counts - Vector3i.ONE)] = true
	# Greedy merge: runs along x, then rows along y, then slabs along z.
	var boxes: Array = []
	var used := {}
	var cells: Array = filled.keys()
	cells.sort_custom(func(a, b): return a.z < b.z or (a.z == b.z and (a.y < b.y or (a.y == b.y and a.x < b.x))))
	for cell in cells:
		if used.has(cell):
			continue
		var end: Vector3i = cell
		while filled.has(end + Vector3i(1, 0, 0)) and not used.has(end + Vector3i(1, 0, 0)):
			end.x += 1
		var grow_y := true
		while grow_y:
			for x in range(cell.x, end.x + 1):
				var next := Vector3i(x, end.y + 1, cell.z)
				if not filled.has(next) or used.has(next):
					grow_y = false
			if grow_y:
				end.y += 1
		var grow_z := true
		while grow_z:
			for x in range(cell.x, end.x + 1):
				for y in range(cell.y, end.y + 1):
					var next := Vector3i(x, y, end.z + 1)
					if not filled.has(next) or used.has(next):
						grow_z = false
			if grow_z:
				end.z += 1
		for x in range(cell.x, end.x + 1):
			for y in range(cell.y, end.y + 1):
				for z in range(cell.z, end.z + 1):
					used[Vector3i(x, y, z)] = true
		boxes.append(AABB(origin + Vector3(cell) * size, Vector3(end - cell + Vector3i.ONE) * size))
	return boxes


# --- Animations ---------------------------------------------------------------------------------

func _animations(scene: Node) -> Array:
	var clips: Array = []
	var players: Array = scene.find_children("*", "AnimationPlayer", true, false)
	for player in players:
		for animation_name in player.get_animation_list():
			var clip := _sample(player, animation_name, scene)
			if not clip.is_empty():
				clips.append(clip)
	return clips


## One animation sampled at 30 fps into keys for the elements it moves.
func _sample(player: AnimationPlayer, animation_name: String, scene: Node) -> Dictionary:
	var animation: Animation = player.get_animation(animation_name)
	if animation == null:
		return {}
	var root: Node = player.get_node_or_null(player.root_node)
	if root == null:
		root = scene
	var frames := maxi(1, roundi(animation.length * FPS))
	# Which element each track moves.
	var tracked := {}
	for track in range(animation.get_track_count()):
		var path := animation.track_get_path(track)
		var target: Node = root.get_node_or_null(NodePath(path.get_concatenated_names()))
		var key := str(scene.get_path_to(target)) if target != null else ""
		if path.get_subname_count() > 0 and target is Skeleton3D:
			key += ":" + str(path.get_concatenated_subnames())
		for entry in _frames:
			if entry.key == key:
				if not tracked.has(key):
					tracked[key] = {"entry": entry, "tracks": []}
				tracked[key].tracks.append(track)
	if tracked.is_empty():
		return {}
	var scale := float(options.scale)
	var times: Array = []
	var values: Array = []
	for f in range(frames):
		var time := minf(f / FPS, animation.length)
		var pose := {}
		for key in tracked:
			var entry: Dictionary = tracked[key].entry
			var local: Transform3D = entry.frame.rest
			var position := local.origin
			var rotation := local.basis.get_rotation_quaternion()
			var stretch := local.basis.get_scale()
			for track in tracked[key].tracks:
				match animation.track_get_type(track):
					Animation.TYPE_POSITION_3D:
						position = animation.position_track_interpolate(track, time)
					Animation.TYPE_ROTATION_3D:
						rotation = animation.rotation_track_interpolate(track, time)
					Animation.TYPE_SCALE_3D:
						stretch = animation.scale_track_interpolate(track, time)
			var rest: Transform3D = entry.rest
			var moved_origin: Vector3 = position * scale
			var moved_basis := Basis(rotation)
			if entry.frame.get("top", false):
				var placed := _top_transform(Transform3D(Basis(rotation).scaled(stretch), position))
				moved_origin = placed.origin
				moved_basis = placed.basis.orthonormalized()
			var base := _euler(rest.basis)
			var element_basis := _rotation_basis(base)
			var turned := RotationPaths.nearest_euler(moved_basis, base + (values[-1][entry.element.name].rotation if not values.is_empty() and values[-1].has(entry.element.name) else Vector3.ZERO)) - base
			var offset := _rotation_basis(base + turned).inverse() * (moved_origin - rest.origin)
			var rest_scale := local.basis.get_scale()
			pose[entry.element.name] = {"offset": offset, "rotation": turned, "stretch": stretch / rest_scale}
		times.append(f)
		values.append(pose)
	var settings := Baker.DEFAULT_SETTINGS.duplicate()
	var kept: Array = Baker._reduce(times, values, {}, settings)
	var keyframes: Array = []
	for i in kept:
		var elements := {}
		for name_value in values[i]:
			var sample: Dictionary = values[i][name_value]
			var keyed := {}
			if not _constant(values, name_value, "offset", Vector3.ZERO):
				keyed.merge(_fields("offset", sample.offset))
			if not _constant(values, name_value, "rotation", Vector3.ZERO):
				keyed.merge(_fields("rotation", sample.rotation))
			if not _constant(values, name_value, "stretch", Vector3.ONE):
				keyed.merge(_fields("stretch", sample.stretch))
			if not keyed.is_empty():
				elements[name_value] = keyed
		keyframes.append({"frame": times[i], "elements": elements})
	return {"name": animation_name, "code": animation_name.to_lower().replace(" ", ""), "quantityframes": frames,
		"onActivityStopped": "Rewind", "onAnimationEnd": "Repeat", "keyframes": keyframes}


## A top-level node's transform in the model frame, as in `convert()`.
func _top_transform(local: Transform3D) -> Transform3D:
	var offset := Vector3(options.offset[0], options.offset[1], options.offset[2])
	return Transform3D(Basis(), offset) * Transform3D(Basis.from_scale(Vector3.ONE * float(options.scale)), Vector3.ZERO) * _root_correction * local


static func _constant(values: Array, name_value: String, group: String, rest: Vector3) -> bool:
	for pose in values:
		if pose.has(name_value) and not (pose[name_value][group] as Vector3).is_equal_approx(rest):
			return false
	return true


static func _fields(group: String, value: Vector3) -> Dictionary:
	return {group + "X": snappedf(value.x, 0.0001), group + "Y": snappedf(value.y, 0.0001), group + "Z": snappedf(value.z, 0.0001)}


# --- Helpers ----------------------------------------------------------------------------------------

static func _euler(basis: Basis) -> Vector3:
	var result := RotationPaths.nearest_euler(basis.orthonormalized(), Vector3.ZERO)
	return Vector3(snappedf(result.x, 0.0001), snappedf(result.y, 0.0001), snappedf(result.z, 0.0001))


static func _rotation_basis(degrees: Vector3) -> Basis:
	return Basis(Vector3.RIGHT, deg_to_rad(degrees.x)) * Basis(Vector3.UP, deg_to_rad(degrees.y)) * Basis(Vector3.BACK, deg_to_rad(degrees.z))


static func _set_rotation(element: Dictionary, rotation: Vector3) -> void:
	for axis in range(3):
		if not is_zero_approx(rotation[axis]):
			element["rotation" + ["X", "Y", "Z"][axis]] = rotation[axis]


func _array(value: Vector3) -> Array:
	if options.get("snap", false):
		return [roundf(value.x), roundf(value.y), roundf(value.z)]
	return [clean(value.x), clean(value.y), clean(value.z)]


## Model files store numbers with limited precision (glTF writers often keep
## UVs as 16-bit values): a value this close to a 1/64 step is that step.
static func clean(value: float) -> float:
	var step := snappedf(value, 1.0 / 64.0)
	return step if absf(step - value) < 0.002 else snappedf(value, 0.0001)
