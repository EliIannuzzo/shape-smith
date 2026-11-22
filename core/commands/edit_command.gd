extends RefCounted
## One undoable edit to a ShapeDocument. Subclasses store only the values they
## change, never copies of the whole document.

const Document = preload("res://core/document/shape_document.gd")

## Shown in Edit → Undo/Redo.
var name := ""
## Commands with the same non-empty key inside EditHistory's merge window are
## offered to merge_with() (drags and number fields become one undo step).
var merge_key := ""
var document


## Applies the edit. Returns false, changing nothing, if it cannot apply.
func do() -> bool:
	return false


func undo() -> bool:
	return false


## Absorbs `next`, a later command with the same merge_key, so one undo
## reverts both. Returns false if the two cannot merge.
func merge_with(_next) -> bool:
	return false


## Approximate memory held by this command, for EditHistory's byte budget.
func byte_size() -> int:
	return 64
