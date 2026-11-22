extends "res://core/commands/edit_command.gd"
## Sets (or, with Document.ABSENT, removes) fields on one face of an element.
## Creates the face, and the "faces" object, when missing; undo removes what
## it created.

var uid := ""
var face := ""
var after: Dictionary = {}
## Fields a newly created face starts with, before `after` is applied.
var defaults: Dictionary = {}
var _before: Dictionary = {}
var _created_faces := false
var _created_face := false
var _captured := false


func _init(target_document, target: String, face_name: String, fields: Dictionary, label := "Change Face", key := "", new_face: Dictionary = {}) -> void:
	document = target_document
	uid = target
	face = face_name
	after = fields.duplicate(true)
	defaults = new_face.duplicate(true)
	name = label
	merge_key = key


func do() -> bool:
	if not document.has(uid):
		return false
	var source: Dictionary = document.source(uid)
	var created_faces := not source.get("faces") is Dictionary
	if created_faces:
		source.faces = {}
	var created_face := not source.faces.get(face) is Dictionary
	if created_face:
		source.faces[face] = defaults.duplicate(true)
	var target: Dictionary = source.faces[face]
	var previous := {}
	for key in after:
		previous[key] = Document._copy(target[key]) if target.has(key) else Document.ABSENT
		if is_same(after[key], Document.ABSENT):
			target.erase(key)
		else:
			target[key] = Document._copy(after[key])
	if not _captured:
		_before = previous
		_created_faces = created_faces
		_created_face = created_face
		_captured = true
	document.touch(uid, ["faces"])
	return true


func undo() -> bool:
	if not document.has(uid):
		return false
	var source: Dictionary = document.source(uid)
	if _created_face:
		source.faces.erase(face)
		if _created_faces and source.faces.is_empty():
			source.erase("faces")
	else:
		var target: Dictionary = source.faces[face]
		for key in _before:
			if is_same(_before[key], Document.ABSENT):
				target.erase(key)
			else:
				target[key] = Document._copy(_before[key])
	document.touch(uid, ["faces"])
	return true


func merge_with(next) -> bool:
	if next.get_script() != get_script() or next.uid != uid or next.face != face:
		return false
	for key in next.after:
		after[key] = next.after[key]
		if not _before.has(key):
			_before[key] = next._before[key]
	return true


func byte_size() -> int:
	return var_to_bytes(_before).size() + var_to_bytes(after).size()
