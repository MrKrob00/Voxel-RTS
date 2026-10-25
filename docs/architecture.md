# Architecture

Godot 4.7 / GDScript, Compatibility renderer, one process, threads only for world generation and meshing.
Rule of thumb: **data and rules at the bottom, nodes on top; a module knows only the modules below it.**

```
main.gd (sandbox scene: wires everything, input -> actions)
 ├─ camera/rts_camera.gd      camera rig, mouse + touch, emits primary/secondary actions
 ├─ world/voxel_world.gd      VoxelWorld: chunk storage, generation + meshing pipeline, picking (raycast)
 │    ├─ world/terrain_edit.gd   TerrainEdit: the rules of digging and building the ground
 │    │    └─ world/ramps.gd       Ramps: slope-piece rules (shared with the generator) and pit filling
 │    ├─ world/world_gen.gd      WorldGen: islands, bridges, terrain heights, blocks (pure function of seed + position)
 │    │    └─ world/map_preset.gd  MapPreset: everything that differs between map types (plains, later winter, desert)
 │    ├─ world/chunk_mesher.gd   ChunkMesher: voxel snapshot -> mesh arrays (thread safe, no scene access)
 │    └─ world/blocks.gd         Blocks: the voxel format and the block palette
 ├─ world/prop_field.gd       PropField: trees, boulders, crystals, ferns (zones), MultiMesh
 │    └─ world/props.gd          Props: procedural low-poly models
 └─ building/brick_world.gd   BrickWorld: player bricks (1x1x1, 2x1x1), support rule, collapse into RigidBody3D
tests/                         headless checks (see below)
scripts/tools/screenshot.gd    debug helper for screenshots
docs/                          reference notes and this file
```

## Voxel format (`Blocks`)

One int per voxel (`PackedInt32Array` per 16x16x16 chunk; an empty array is a chunk of open sky).
- bits 0-7: material. bits 8-15: shape. bit 16: `DUG`.
- Shape 0 is a full cube. Any other shape is `1 + h0 + 3*h1 + 9*h2 + 27*h3`, the heights (0, 1 or 2 half-blocks) of the four
  top corners. That covers wedges, inner and outer corners and half-height slabs, whole or half height.
- Only **whole** cubes are opaque, set a column's height and let bricks stand on them.

## Ground: stages and slope pieces (`TerrainEdit`, `Ramps`)

A block of ground has three states: **whole -> half dug -> gone**. A half-dug block is a flat half-block with the `DUG` flag.

The generator also removes features one block wide (pits, trenches, pillars, ridges), which would only produce shard-like
rings of slopes; players may dig and build any such shape.

Slope pieces (wedges, corners) are ground as well and can be dug or filled, but they are *derived*: they fill the cell above
a column that is lower than its neighbours. The rules live in one place, `Ramps.skin_shape`, and are used by the
generator (from column levels) and by `TerrainEdit` (from the cells), so generated and edited ground follow the same law.

- A slope piece is decided by the 3x3x3 neighbourhood of its cell: a whole block below it, the 8 neighbours in its layer
  (a whole block that is a step top rises 1 block, a half-dug block half a block) and the same 8 columns one layer up
  (anything natural there makes the neighbour a wall, which raises nothing). Each corner takes the highest rise among
  the three cells that touch it (two sides and the diagonal). The corner is a vertex shared by up to four pieces, and all of
  them compute it the same way, so neighbouring pieces always meet at equal heights (`tests/world_smoke_test.gd` checks the
  seams after generation and after every kind of edit).
- The **level** of a column is measured in half-blocks: `2 * (y of its highest whole cube + 1)`, plus 1 if the block on top of
  it is half dug. Slope pieces depend on the levels of the eight neighbours only.
- Changing a natural block (whole or half dug) re-derives the slope pieces of the 3x3 columns around it **after** the block
  changed, in the same call. So neighbours follow the block's current state, never the other way round.
- Digging a slope piece changes no level, so nothing around it changes: a destroyed slope stays destroyed.
- After digging, existing slope pieces only change shape or vanish; a pit the player dug is not refilled. After building,
  new slope pieces may appear next to the new wall, like at generation.
- Building on a slope piece or a half-dug block fills that very cell up to a whole block of its own material.

## Pipeline and frames (`VoxelWorld`)

- Generation and meshing run on `WorkerThreadPool`; the main thread commits results.
- Every voxel write bumps a version on the chunks that can see it. All chunks touched during one frame form an **edit group**
  whose new meshes are committed together in a single frame: a changed block and the slopes around it never appear one
  after the other. Initial meshes use a per-frame budget (`meshes_per_frame`).
- No physics colliders for terrain. Picking is a voxel DDA ray; units will use voxel data for pathfinding. Falling bricks
  get short-lived static collision patches built under them.

## Bricks (`BrickWorld`)

Bricks are separate objects on the voxel grid, never part of the terrain and never changing it.
- They can only stand on **whole** terrain blocks or on standing bricks, never on a slope piece or a half-dug block.
- A brick stands while at least one cell under it is such ground or a standing brick (running bond survives losing a brick,
  a straight stack does not). Bricks that lose all support fall as `RigidBody3D` and are cleaned up after a while.
- If the ground under a brick is dug, the brick re-checks its support (`block_changed`).

## Map types (`MapPreset`)

A map type is a `MapPreset` (terrain shape, surface blocks, colours, prop densities). The generator and the mesher only read
it. Plains is the first one; winter and desert are new static constructors, not new code paths.

## Tests

Run from the project folder (Godot 4.7.2 headless):

```
godot --headless --path . --import                              # once, builds the class cache
godot --headless --path . -s res://tests/world_smoke_test.gd    # generation, islands, bridges, stages, slopes, atomic frames
godot --headless --path . -s res://tests/ramps_rule_test.gd     # the slope rule on all 6561 neighbourhoods + random height fields
godot --headless --path . -s res://tests/brick_test.gd          # support rules, collapse, flat-ground-only building
godot --headless --path . -s res://tests/island_seeds_test.gd   # 40 seeds x 3 island counts: layout and bridges
```

Screenshots (virtual display): `xvfb-run -a godot --path . --rendering-driver opengl3 -- --shot=out.png [--zoom=D --focus=X,Z
--pitch=DEG --yaw=DEG --extras=N --seed=S --dig=X,Z,STAGES --noprops]`.

## Conventions

- New game rules go into a rules module (like `TerrainEdit`), not into `VoxelWorld` or `main.gd`.
- Anything that runs on a worker thread must not touch the scene tree; it reads immutable snapshots.
- Parameters of a map type belong in `MapPreset`; magic numbers in generators should be moved there when they are tuned.
