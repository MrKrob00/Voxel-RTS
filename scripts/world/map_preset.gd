class_name MapPreset
extends RefCounted
## Everything that makes one map type different from another: terrain shape, surface blocks, colours, props.
## New maps (winter, desert) are new static constructors here; the generator and the mesher only read these fields.

var id := "plains"
var display_name := "Plains"
var sky_color := Color("9cc7ee")
var ambient_color := Color(0.72, 0.76, 0.85)

# Terrain shape.
var hills_amp := 15.0             ## raw height spread before it is cut into plateaus, +- blocks
var mountain_amp := 26.0          ## max ridge height above the island base
var mountain_region := Vector2(0.28, 0.62)   ## smoothstep edges on the region noise: higher = fewer mountains
var pass_width := Vector2(0.05, 0.22)        ## smoothstep edges on |pass noise|: wider = bigger valleys between peaks
var flat_share := 0.30            ## share of the island radius kept flat around the island centre (build area)
var terrace_step := 5.0           ## plateaus are this many blocks apart; between them are cliffs...
var pass_ramp := Vector2(0.03, 0.16)   ## ...except where the pass noise is near zero: there the ground slopes (a pass)
var dirt_depth := 2               ## dirt layers under the surface block, stone below
var top_block := Blocks.GRASS
var sub_block := Blocks.DIRT

# Surface colours (blended per vertex, so patches have soft edges).
var surface_light := Color("73b83f")
var surface_dark := Color("4f9a34")
var patch_color := Color("8a6a43")   ## bare ground showing through the ground cover
var patch_start := 0.84              ## 0..1 noise level where bare patches begin (higher = fewer)
var clear_center := Vector2(-1000, -1000)   ## bare dirt circle around the spawn crystal (set by the world)
var clear_radius := 5.0

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


## Colour of a vertex on a face. Top faces of the surface block blend light/dark ground cover and bare patches.
func vertex_color(block: int, face_kind: int, wx: float, wz: float) -> Color:
	if block == top_block and face_kind == Blocks.FACE_TOP:
		var t := blob(wx, wz, 1.0)
		var base := surface_dark.lerp(surface_light, t)
		var p := smoothstep(patch_start, patch_start + 0.10, blob(wx + 31.0, wz - 17.0, 1.7))
		var d := Vector2(wx, wz).distance_to(clear_center)
		p = maxf(p, 1.0 - smoothstep(clear_radius, clear_radius + 2.0, d))
		return base.lerp(patch_color, p)
	return Blocks.color_of(block, face_kind)
