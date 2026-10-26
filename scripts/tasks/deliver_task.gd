class_name DeliverTask
extends WorkTask
## A unit that was left holding something (its job was cancelled, a plan was deleted) takes it to a stockpile that has room, or throws
## it into the world when there is none. No target, no card in the ribbon: the worker only carries its load and the job ends.


func _init() -> void:
	title = "Deliver"
	max_workers = 1


func is_finished() -> bool:
	return true   # nothing more to do; the board removes the job once the load is down


func shown() -> bool:
	return false
