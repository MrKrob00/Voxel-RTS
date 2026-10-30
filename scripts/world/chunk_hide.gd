class_name ChunkHide
extends RefCounted
## Several systems hide chunks of ground (the ones behind a hill, the ones the far ground stands for). A chunk is drawn when none of
## them wants it hidden: each keeps its own flag on the node.

static func set_hidden(node: Node3D, reason: String, hidden: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	var reasons: Dictionary = node.get_meta("hidden_by", {})
	if hidden:
		reasons[reason] = true
	else:
		reasons.erase(reason)
	node.set_meta("hidden_by", reasons)
	node.visible = reasons.is_empty()
