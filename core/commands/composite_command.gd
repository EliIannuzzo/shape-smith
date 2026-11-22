extends "res://core/commands/edit_command.gd"
## Runs several commands as one undo step (an import, a mirror, an IK bake).
## If a step fails, the steps already done are undone and nothing changes.

var steps: Array = []


func _init(target_document, commands: Array, label := "") -> void:
	document = target_document
	steps = commands.duplicate()
	name = label if not label.is_empty() or steps.is_empty() else steps[0].name


func do() -> bool:
	for i in range(steps.size()):
		if not steps[i].do():
			for j in range(i - 1, -1, -1):
				steps[j].undo()
			return false
	return true


func undo() -> bool:
	for i in range(steps.size() - 1, -1, -1):
		if not steps[i].undo():
			for j in range(i + 1, steps.size()):
				steps[j].do()
			return false
	return true


func byte_size() -> int:
	var total := 0
	for step in steps:
		total += step.byte_size()
	return total
