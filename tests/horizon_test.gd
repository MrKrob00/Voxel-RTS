extends SceneTree
## Headless: godot --headless --path . -s res://tests/horizon_test.gd
## HorizonCulling on a small height map: a ridge hides the low ground behind it and not the ground in front of it, nor what rises above it.

func _init() -> void:
	var failed := 0
	var cw := 60
	var cd := 60   # squares of 4 blocks: 240 x 240 blocks
	var heights := PackedFloat32Array()
	heights.resize(cw * cd)
	heights.fill(10.0)
	for cz in range(40, 42):      # a ridge 30 high across x = 80..120, z = 160..168
		for cx in range(20, 30):
			heights[cx + cz * cw] = 30.0
	var cam := Vector3(100.0, 12.0, 100.0)
	var horizon := HorizonCulling.make_horizon(cam, heights, cw, cd)
	failed += _check(HorizonCulling.chunk_hidden(cam, horizon, 90.0, 180.0, 106.0, 196.0, 20.0), "low ground behind the ridge is hidden")
	failed += _check(not HorizonCulling.chunk_hidden(cam, horizon, 90.0, 120.0, 106.0, 136.0, 20.0), "ground in front of it is not")
	failed += _check(not HorizonCulling.chunk_hidden(cam, horizon, 90.0, 180.0, 106.0, 196.0, 60.0), "a chunk that rises above the line over the ridge is not")
	failed += _check(not HorizonCulling.chunk_hidden(cam, horizon, 140.0, 180.0, 156.0, 196.0, 20.0), "ground behind where the ridge ends is not")
	failed += _check(not HorizonCulling.chunk_hidden(cam, horizon, 96.0, 96.0, 112.0, 112.0, 14.0), "the chunk under the camera is not")
	failed += _check(HorizonCulling.chunk_hidden(cam, horizon, 90.0, 172.0, 106.0, 188.0, 12.0), "ground right behind the ridge is hidden")
	# the camera high over the ridge sees over it
	var high := Vector3(100.0, 80.0, 100.0)
	var horizon_high := HorizonCulling.make_horizon(high, heights, cw, cd)
	failed += _check(not HorizonCulling.chunk_hidden(high, horizon_high, 90.0, 180.0, 106.0, 196.0, 20.0), "from high above nothing is hidden by the ridge")
	print("HORIZON DONE: %d failed" % failed)
	quit(1 if failed > 0 else 0)


func _check(cond: bool, what: String) -> int:
	print(("ok   " if cond else "FAIL ") + what)
	return 0 if cond else 1
