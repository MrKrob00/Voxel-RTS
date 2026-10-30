class_name GroundLayers
extends RefCounted
## The two pictures every chunk of ground carries (the light of the corners of its faces, and its grass: green and wear), kept as the
## layers of TWO texture arrays instead of two textures of the chunk's own. So all the ground is drawn with ONE material (the renderer
## does not change textures and uniforms between chunks), and the chunk says which layer is its own in the second UV of its vertices.
## The arrays are made for START layers and made again twice as big when they are full (the material is told by `changed`).

const START := 128
const MAX := 2048                 ## what a graphics card is sure to take as the layers of a texture

signal changed

var ao: Texture2DArray            ## layer = a chunk: 32 x 256, the 4 corners x 6 faces of every block (ChunkMesher.AO_TEX_SIZE)
var cover: Texture2DArray         ## layer = a chunk: the columns and the border round them: rgb the green, a the wear
var capacity := 0
var _ao_images: Array[Image] = []
var _cover_images: Array[Image] = []
var _free: Array[int] = []
var _layer_of := {}               # chunk position -> layer
var _blank_ao: Image
var _blank_cover: Image


func _init(cover_size: int) -> void:
	_blank_ao = Image.create(ChunkMesher.AO_TEX_SIZE.x, ChunkMesher.AO_TEX_SIZE.y * ChunkMesher.AO_TEX_SIZE.z, false, Image.FORMAT_RGBA8)
	_blank_cover = Image.create(cover_size, cover_size, false, Image.FORMAT_RGBA8)
	_make(START)


func layer_count() -> int:
	return _layer_of.size()


func _make(count: int) -> void:
	for i in range(capacity, count):
		_ao_images.append(_blank_ao)
		_cover_images.append(_blank_cover)
		_free.append(i)
	_free.reverse()   # the lowest layers first
	capacity = count
	ao = Texture2DArray.new()
	ao.create_from_images(_ao_images)
	cover = Texture2DArray.new()
	cover.create_from_images(_cover_images)


## The layer of the chunk at `cpos` (it keeps it while it stays): given when the chunk has none.
func acquire(cpos: Vector3i) -> int:
	if _layer_of.has(cpos):
		return _layer_of[cpos]
	if _free.is_empty():
		if capacity >= MAX:
			push_warning("GroundLayers: out of layers")
			return MAX - 1
		_make(mini(capacity * 2, MAX))
		changed.emit()
	var layer: int = _free.pop_back()
	_layer_of[cpos] = layer
	return layer


func fill(layer: int, ao_image: Image, cover_image: Image) -> void:
	_ao_images[layer] = ao_image
	ao.update_layer(ao_image, layer)
	if cover_image != null:
		_cover_images[layer] = cover_image
		cover.update_layer(cover_image, layer)


func release(cpos: Vector3i) -> void:
	if _layer_of.has(cpos):
		_free.append(_layer_of[cpos])
		_layer_of.erase(cpos)
