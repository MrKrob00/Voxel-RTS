class_name WorldReaders
extends RefCounted
## Worker threads that read the world as it is (the path searches) are counted here. The main thread edits the voxels in place, which
## is safe for them, except for one thing: the first block put into a chunk of open sky makes its array (see VoxelWorld.set_block).
## That waits until no thread is reading.

static var _mutex := Mutex.new()
static var _count := 0


static func enter() -> void:
	_mutex.lock()
	_count += 1
	_mutex.unlock()


static func leave() -> void:
	_mutex.lock()
	_count -= 1
	_mutex.unlock()


static func wait_none() -> void:
	while true:
		_mutex.lock()
		var n := _count
		_mutex.unlock()
		if n == 0:
			return
		OS.delay_msec(1)
