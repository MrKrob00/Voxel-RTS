class_name TestContext
extends RefCounted
## What the shared-world suites get: the scene tree, the one generated world (and its tree props), and a container to put their
## own nodes in.

var tree: SceneTree
var world: VoxelWorld
var props: PropField
var scene: Node3D
