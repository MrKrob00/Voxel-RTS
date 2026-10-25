extends Node
## Debug helper: godot --path . --rendering-driver opengl3 res://scenes/main.tscn -- --shot=/path.png
## Waits for the world, saves one frame and quits. Only active when --shot= is given.

func _ready() -> void:
	var path := ""
	var zoom := 0.0
	var focus := Vector2(-1, -1)
	var digs: Array[Vector3i] = []   # (x, z, stages): dig the top block of that column before the shot
	var pitch := -1.0
	var yaw := -1000.0
	var select_all := false
	var stockpiles: Array[Vector3i] = []  # --stockpile=x,z[,bags]: put a stockpile there (--frame: a frame, filled with `bags` of stone)
	var task_rect: Array[int] = []        # --task=x0,z0,x1,z1[,depth]: mark an area to dig and put every unit on it (--nocollect: bring nothing home)
	var tool_mode := -1                   # --tool=N: choose that Tools.Mode, --palette: open the tool palette
	var palette := false
	var tab := "stone"                    # --tab=wood|structures: which tab of the build panel
	var demo := false                     # --demo-blocks: one of every block of the catalog on the ground near the spawn
	var clock := -1.0                     # --time=0.75: freeze the day at that time (0 midnight, 0.5 noon)
	var radial := false                   # --radial: the round menu of the first station
	var blocks := false                   # --blocks: and the page of blocks
	var wait_frames := 400                # --wait=N: frames to wait before the shot (let units work)
	var move_to := Vector2(-1, -1)   # --move=x,z: select every unit and send it there, then wait for it to walk a bit
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			path = a.substr(7)
		elif a.begins_with("--focus="):
			var parts := a.substr(8).split(",")
			focus = Vector2(float(parts[0]), float(parts[1]))
		elif a.begins_with("--dig="):
			var d := a.substr(6).split(",")
			digs.append(Vector3i(int(d[0]), int(d[1]), int(d[2]) if d.size() > 2 else 1))
		elif a.begins_with("--pitch="):
			pitch = float(a.substr(8))
		elif a.begins_with("--yaw="):
			yaw = float(a.substr(6))
		elif a.begins_with("--stockpile="):
			var sp := a.substr(12).split(",")
			stockpiles.append(Vector3i(int(sp[0]), int(sp[1]), int(sp[2]) if sp.size() > 2 else 0))
		elif a.begins_with("--task="):
			for part in a.substr(7).split(","):
				task_rect.append(int(part))
		elif a.begins_with("--tool="):
			tool_mode = int(a.substr(7))
		elif a == "--palette":
			palette = true
		elif a.begins_with("--time="):
			clock = float(a.get_slice("=", 1))
		elif a == "--demo-blocks":
			demo = true
		elif a == "--radial":
			radial = true
		elif a.begins_with("--tab="):
			tab = a.get_slice("=", 1)
			palette = true
			blocks = true
		elif a == "--blocks":
			palette = true
			blocks = true
		elif a.begins_with("--wait="):
			wait_frames = int(a.substr(7))
		elif a == "--select-all":
			select_all = true
		elif a.begins_with("--move="):
			var m := a.substr(7).split(",")
			move_to = Vector2(float(m[0]), float(m[1]))
			select_all = true
		elif a.begins_with("--zoom="):
			zoom = float(a.substr(7))
	if path == "":
		queue_free()
		return
	var world: VoxelWorld = get_parent().get("world")
	while not world.is_ready():
		await get_tree().process_frame
	for _i in 10:
		await get_tree().process_frame
	var units: UnitManager = get_parent().get("units")
	if select_all and units != null:
		units.select_all()
	if move_to.x >= 0.0 and units != null:
		var gc := units.nav.nearest_standable(Vector3i(int(move_to.x), world.surface_y(int(move_to.x), int(move_to.y)) + 1, int(move_to.y)), 5)
		if gc.x >= 0:
			units.command_move(gc)
	var economy: Economy = get_parent().get("economy")
	for sp in stockpiles:
		if economy == null:
			break
		var top := world.surface_y(sp.x, sp.y)
		var framed := OS.get_cmdline_user_args().has("--frame")
		var made := economy.place_stockpile(Vector3i(sp.x, top + 1, sp.y), Stockpile.Style.CRATE if framed else Stockpile.Style.PLATFORM)
		print("stockpile: ", "placed" if made != null else economy.last_error)
		if made != null and sp.z > 0:
			made.add(Resources.Kind.STONE if framed else Resources.Kind.IRON, sp.z)
	var board: TaskBoard = get_parent().get("board")
	if task_rect.size() >= 4 and board != null:
		var t := board.create_dig(task_rect[0], task_rect[1], task_rect[2], task_rect[3], task_rect[4] if task_rect.size() > 4 else 1)
		if t != null and OS.get_cmdline_user_args().has("--nocollect"):
			t.collect = {}
		if t != null and units != null:
			for u in units.units:
				board.assign(u, t)
	var hud_node = get_parent().get("hud")
	if hud_node != null and tool_mode >= 0:
		get_parent()._choose_tool(tool_mode)
	if clock >= 0.0:
		get_parent().day.day_seconds = 0.0
		get_parent().day.time_of_day = clock
		get_parent().day._apply()
	if demo:
		var main := get_parent()
		var sp: Vector3i = main.world.spawn_point()
		var n := 0
		for d in BlockCatalog.all():
			var at := Vector3i(sp.x - 6 + (n % 8) * 3, sp.y + 1, sp.z + 3 + (n / 8) * 3)
			for dz in 2:
				for dx in 3:
					main.world.set_block(Vector3i(at.x + dx, at.y - 1, at.z + dz), Blocks.make(Blocks.GRASS))
			main.bricks.place(at, 0, BrickWorld.Kind.WOOD if d.material == BlockCatalog.WOOD else BrickWorld.Kind.STONE, d.length, d.id, 0)
			n += 1
		main.rig.focus = Vector3(sp.x + 6, sp.y, sp.z + 6)
		main.rig.distance = 22.0
	if radial and not get_parent().economy.stations.is_empty():
		get_parent()._station_menu(get_parent().economy.stations[0])
	if hud_node != null and palette:
		hud_node._set_palette(true)
		if blocks:
			hud_node._page = "blocks"
			hud_node._tab = tab
			hud_node._fill_palette()
	for d in digs:
		var terrain: TerrainEdit = world.terrain
		var lv0 := terrain.level(d.x, d.y)
		var cell := Vector3i(d.x, lv0 / Blocks.UNIT - 1, d.y)   # the top whole block; it stays the same cell through its stages
		for _s in d.z:
			terrain.dig_step(cell)
	if focus.x >= 0.0:
		get_parent().get("rig").focus = Vector3(focus.x, 50, focus.y)
	if pitch >= 0.0:
		get_parent().get("rig").pitch = deg_to_rad(pitch)
	if yaw > -999.0:
		get_parent().get("rig").yaw = deg_to_rad(yaw)
	if zoom > 0.0:
		get_parent().get("rig").distance = zoom
	for i in wait_frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
