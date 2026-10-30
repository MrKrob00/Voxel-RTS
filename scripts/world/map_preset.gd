class_name MapPreset
extends RefCounted
## Everything that makes one map type different from another: terrain shape, surface blocks, colours, props.
## New maps (winter, desert) are new static constructors here; the generator and the mesher only read these fields.

var id := "plains"
var display_name := "Plains"
var sky_color := Color("9cc7ee")
var ambient_color := Color(0.72, 0.76, 0.85)

# Terrain shape.
var hills_amp := 19.0             ## raw height spread before it is cut into plateaus, +- blocks
var mountain_amp := 11.0          ## max ridge height above the island base
var mountain_region := Vector2(0.20, 0.56)   ## smoothstep edges on the region noise: higher = fewer mountains
var pass_width := Vector2(0.05, 0.22)        ## smoothstep edges on |pass noise|: wider = bigger valleys between peaks
var flat_share := 0.24            ## share of the island radius kept flat around the island centre (build area)
var terrace_step := 6.0           ## plateaus are this many blocks apart; between them are cliffs...
var pass_ramp := Vector2(0.03, 0.16)   ## ...except where the pass noise is near zero: there the ground slopes (a pass)
var dirt_depth := 1               ## dirt layers under the surface block, stone below...
var dirt_extra_threshold := 0.18  ## ...plus a second dirt layer where this 2D noise is above the threshold (about a third of the ground)
var top_block := Blocks.GRASS
var sub_block := Blocks.DIRT

# Surface colours (blended per vertex, so patches have soft edges).
var surface_light := Color("6aa83c")
var surface_dark := Color("4f9a34")
var surface_deep := Color("3d8434")   ## a third, darker green in broad blobs
var bare_color := Color("8a6a43")    ## earth showing where the grass is gone (GroundCover: under props and buildings, along cliffs)

# Props per 100 free surface cells.
var tree_density := 5.0
var boulder_density := 0.5
var crystal_density := 0.6          ## orange crystals, only at cliff feet
var plant_density := 14.0


static func plains() -> MapPreset:
	return MapPreset.new()


## Smooth pseudo-noise in 0..1 from world x/z (cheap, thread safe, no allocation).
static func blob(x: float, z: float, scale: float) -> float:
	var a := sin(x * 0.13 * scale + sin(z * 0.07 * scale) * 2.0)
	var b := sin(z * 0.11 * scale + sin(x * 0.05 * scale) * 2.3)
	var c := sin((x + z) * 0.045 * scale)
	return clampf((a + b + c * 1.3) / 3.3 * 0.5 + 0.5, 0.0, 1.0)


## The green of the grass at a place (three blobs of colour). The ground shader does not work it out: it reads it from the ground image
## of the chunk (VoxelWorld._mesh_task), one texel per column.
func grass_colour(x: float, z: float) -> Color:
	var base := surface_dark.lerp(surface_light, blob(x, z, 1.0))
	return base.lerp(surface_deep, smoothstep(0.58, 0.72, blob(x - 90.0, z + 55.0, 0.55)) * 0.75)


## Colour of a vertex on a face. Top faces of the surface block blend light/dark ground cover and bare patches;
## `bare` (0..1, see GroundCover) is how much of the grass is gone there: under props and buildings, along cliff edges.
func vertex_color(block: int, face_kind: int, wx: float, wz: float, bare := 0.0) -> Color:
	if block == top_block and face_kind == Blocks.FACE_TOP:
		var t := blob(wx, wz, 1.0)
		var base := surface_dark.lerp(surface_light, t)
		base = base.lerp(surface_deep, smoothstep(0.58, 0.72, blob(wx - 90.0, wz + 55.0, 0.55)) * 0.75)
		return base.lerp(bare_color, bare)
	return Blocks.color_of(block, face_kind)
