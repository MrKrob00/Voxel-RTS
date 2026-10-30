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
	# the picture: the camera looks down at 35 degrees; far ahead the ground lies above the top edge of the picture
	var proj := Projection.create_perspective(60.0, 16.0 / 9.0, 0.1, 1400.0)
	var pitch := deg_to_rad(35.0)
	var eye := Transform3D(Basis.looking_at(Vector3(0, -sin(pitch), cos(pitch)), Vector3.UP), Vector3(100, 10, 100))
	var probe := eye * Vector3(0, 0, -50)
	var planes := PackedFloat32Array()
	for k in 6:
		var pl: Plane = eye * proj.get_projection_plane(k)
		if pl.distance_to(probe) > 0.0:
			pl = Plane(-pl.normal, -pl.d)   # outward, as Camera3D.get_frustum
		planes.append_array([pl.normal.x, pl.normal.y, pl.normal.z, pl.d])
	failed += _check(not HorizonCulling.outside_picture(planes, 0.0, 90.0, 120.0, 106.0, 136.0, 4.0, 5.0), "ground a little way ahead is in the picture")
	failed += _check(HorizonCulling.outside_picture(planes, 0.0, 90.0, 200.0, 106.0, 216.0, 4.0, 5.0), "ground far ahead lies above the top edge of the picture: out")
	failed += _check(not HorizonCulling.outside_picture(planes, 0.0, 90.0, 200.0, 106.0, 216.0, -11.0, 5.0), "the box of its whole mesh, reaching down into the cliffs, would still count as in it")
	failed += _check(HorizonCulling.outside_picture(planes, 0.0, 90.0, 20.0, 106.0, 36.0, 4.0, 5.0), "ground behind the camera is out")
	failed += _check(not HorizonCulling.outside_picture(planes, 60.0, 90.0, 200.0, 106.0, 216.0, 4.0, 5.0), "a big margin lets it in")
	print("HORIZON DONE: %d failed" % failed)
	quit(1 if failed > 0 else 0)


func _check(cond: bool, what: String) -> int:
	print(("ok   " if cond else "FAIL ") + what)
	return 0 if cond else 1
