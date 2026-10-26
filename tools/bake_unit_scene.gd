extends SceneTree
## Builds scenes/units/unit.tscn from the model Unit used to make in code (godot --headless --path . -s res://tools/bake_unit_scene.gd).
## Kept for the record: the scene is the thing to edit from now on, in the editor.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var u := Unit.new()
	root.add_child(u)
	await process_frame
	u.name = "Unit"
	var names := {"_body": "Body", "_bar": "ProgressBar", "_ring": "SelectionRing", "_label": "StatusLabel", "_pack": "Pack"}
	for k in names:
		(u.get(k) as Node).name = names[k]
	_own(u, u)
	var scene := PackedScene.new()
	print("pack: ", scene.pack(u))
	print("save: ", ResourceSaver.save(scene, "res://scenes/units/unit.tscn"))
	quit()


func _own(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		_own(c, owner_node)
