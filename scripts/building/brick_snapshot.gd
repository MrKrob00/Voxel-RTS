class_name BrickSnapshot
extends RefCounted
## What a worker thread may read of the bricks while the game goes on: the cells they fill and their flights of steps, copied at one
## moment. Answers the two questions of Navigation the way BrickWorld does.

var cells := {}      # Vector3i -> true
var flights := {}    # Vector3i -> {"rise": Vector2i, "steps": int}


func occupied(cell: Vector3i) -> bool:
	return cells.has(cell)


func steps_at(cell: Vector3i) -> Dictionary:
	return flights.get(cell, {})
