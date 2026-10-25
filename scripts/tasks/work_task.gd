class_name WorkTask
extends RefCounted
## What a job looks like to the worker who does it. A task knows its targets (blocks to dig, trees to fell, a station to work at)
## and what doing one of them means; the Worker (one per assigned unit) does the walking, waiting and carrying the same way for
## every kind of job. Subclasses: DigTask, HarvestTask, CraftTask.

var id := 0
var title := "Task"
var max_workers := 8
var workers: Array[Unit] = []
var persistent := false          ## a station's task never finishes; workers join it when there is something to do, and leave when not
var overlay: MeshInstance3D      ## the marks drawn over the world, if any
var board: TaskBoard             ## set when the task is put on the board


func is_finished() -> bool:
	return true


## Whether the task has a card in the HUD's ribbon.
func shown() -> bool:
	return true


func summary() -> String:
	return title


## One short line for the task card (what is left to do).
func detail() -> String:
	return summary()


## Takes the nearest free target for `unit` and returns it, or null when nothing is free right now.
func claim(_unit: Unit, _from: Vector3i, _now: float) -> Variant:
	return null


## Gives a target back (it stays in the task; `retry_after` is the time before anybody tries it again).
func release(_target: Variant, _retry_after := 0.0) -> void:
	pass


## The target is done for good: out of the task.
func complete(_target: Variant) -> void:
	pass


## Is the target still there to work on?
func holds(_target: Variant) -> bool:
	return false


func valid(_target: Variant, _board: TaskBoard) -> bool:
	return false


## Cells a unit can stand in to work on the target.
func stand_cells(_target: Variant, _board: TaskBoard) -> Array[Vector3i]:
	return []


func face_point(_target: Variant) -> Vector3:
	return Vector3.ZERO


func work_time(_target: Variant) -> float:
	return 1.0


## What must be fetched from a stockpile before working: {} or {"kind": Kind, "amount": n}.
func input_needed() -> Dictionary:
	return {}


## Does a persistent task have something to do right now (so that an idle unit should come)?
func wants_workers(_board: TaskBoard) -> bool:
	return false


## Does the work. Returns {"kind": Kind (what the worker now carries, NONE for nothing), "amount": n, "done": the target is
## finished, "consumed": what it carried was used up}.
func perform(_target: Variant, _board: TaskBoard, _unit: Unit = null) -> Dictionary:
	return {}


## A standing job that has nothing to do just now: should a unit keep the load in its hands and wait (a brick for a wall that is not yet
## open at that height), rather than carry it back to a stockpile?
func keeps_load(_unit: Unit) -> bool:
	return false


## Whether a kind of thing is brought home (the rest is broken and thrown away). Only quarries filter.
func collects(_kind: int) -> bool:
	return true


## Called every frame by the board: lets a task prepare its next batch of targets (a quarry opens its next layer).
func update(_board: TaskBoard) -> void:
	pass


## Redraws the marks.
func redraw(_board: TaskBoard) -> void:
	pass


func mark_dirty() -> void:
	pass
