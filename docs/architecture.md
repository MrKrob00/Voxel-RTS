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
 │    ├─ world/ground_cover.gd   GroundCover: how much grass is gone per column (props, buildings, cliff edges)
 │    ├─ world/chunk_mesher.gd   ChunkMesher: voxel snapshot -> mesh arrays (thread safe, no scene access)
 │    └─ world/blocks.gd         Blocks: the voxel format and the block palette
 ├─ world/prop_field.gd       PropField: trees, boulders, crystals, ferns (zones), MultiMesh
 │    └─ world/props.gd          Props: procedural low-poly models
 ├─ physics/ground_colliders.gd  GroundColliders: short-lived collision patches under things that fall (bricks, logs)
 ├─ items/                    LooseItems / LooseLog: felled logs as physics bodies
 ├─ building/brick_world.gd   BrickWorld: player bricks (1x1x1, 2x1x1), support rule, collapse into RigidBody3D
 ├─ units/navigation.gd       Navigation: where units can stand, 8-way moves, A* (pure rules on voxel data)
 ├─ units/unit.gd             Unit: one worker (1.7 x 0.8 blocks): walking, hopping, falling, model, status label
 ├─ units/unit_manager.gd     UnitManager: spawning, selection (tap, box, double tap), formation move orders
 ├─ economy/                  Resources (kinds of bags), Stockpile (2x2 wooden platform, 24 bags), Economy (where bags go)
 └─ tasks/                    TaskBoard (jobs, assignment, marks), DigTask (marked blocks), Worker (the FSM of one worker)
tests/                         headless checks (see below)
scripts/tools/screenshot.gd    debug helper for screenshots
docs/                          reference notes and this file
```

## Voxel format (`Blocks`)

One int per voxel (`PackedInt32Array` per 16x16x16 chunk; an empty array is a chunk of open sky).
- bits 0-7: material. bits 8-17: shape. bit 18: `DUG`.
- Shape 0 is a full cube. Any other shape of a slope piece is `1 + h0 + 5*h1 + 25*h2 + 125*h3`: the heights, in
  quarter-blocks (0 to 4), of the four top corners.
- A dug block (flag `DUG`) has shape `DUG_SHAPE_BASE + 16 * corner_mask + dip_mask`: which corners are raised to a full block
  (they touch whole neighbours) and which sides sink to the dug height because another dug block is next to them. Its
  centre is at `DUG_HEIGHT` (3 of 4), so its top is a shallow bowl (`SHAPE_BOWL`: all four corners raised) and neighbouring
  pits run into one another instead of leaving a ridge between them.
- Only **whole** cubes are opaque, set a column's height and let bricks stand on them.

## Ground: stages and slope pieces (`TerrainEdit`, `Ramps`)

A block of ground has three states: **whole -> half dug -> gone**. A half-dug block stands 3/4 high and
has the `DUG` flag. It keeps its material: the mesher paints the turf only where the ground rises to a whole block (the rim)
and earth towards the middle, and building the block up again brings the grass back. Its corners that touch whole neighbours rise to their height, so the first stage is a shallow bowl with
sloping sides, not a square hole. A block covered by other ground has no half-way state and just goes.

The generator also removes features one block wide (pits, trenches, pillars, ridges), which would only produce shard-like
rings of slopes; players may dig and build any such shape.

Slope pieces (wedges, corners) are ground as well and can be dug or filled, but they are *derived*: they fill the cell above
a column that is lower than its neighbours. The rules live in one place, `Ramps.skin_shape`, and are used by the
generator (from column levels) and by `TerrainEdit` (from the cells), so generated and edited ground follow the same law.

- A slope piece is decided by the 3x3x3 neighbourhood of its cell: a whole block below it, the 8 neighbours in its layer
  (a whole block that is a step top rises 1 block, a half-dug block 3/4 of a block) and the same 8 columns one layer up
  (anything natural there makes the neighbour a wall, which raises nothing). Each corner takes the highest rise among
  the three cells that touch it (two sides and the diagonal). The corner is a vertex shared by up to four pieces, and all of
  them compute it the same way, so neighbouring pieces always meet at equal heights (`tests/world_smoke_test.gd` checks the
  seams after generation and after every kind of edit).
- The **level** of a column is measured in quarter-blocks: `4 * (y of its highest whole cube + 1)`, plus 3 if the block on top
  of it is half dug.
- Slope pieces and half-dug blocks are shaped by the same rule (a half-dug block just never goes below `DUG_HEIGHT`).
- Changing a natural block (whole or half dug) re-derives the pieces of the 3x3 columns around it **after** the block
  changed, in the same call. So neighbours follow the block's current state, never the other way round.
- Digging a slope piece changes no level, so nothing around it changes: a destroyed slope stays destroyed.
- After digging, existing slope pieces only change shape or vanish; a pit the player dug is not refilled. After building,
  new slope pieces may appear next to the new wall, like at generation.
- Building on a slope piece or a half-dug block fills that very cell up to a whole block of its own material.

## Grass and bare earth (`GroundCover`)

Grass is a surface cover, not a block material. `GroundCover` stores, per column, how much of it is gone (0 turf .. 255 earth).
It is painted from three sources: a cliff pass at world start (the lip of a drop of 2+ blocks, the island edge, the foot of a
wall), `PropField` (a soft disc of earth around every tree, boulder and ore vein) and `BrickWorld.place` (a footprint plus a
margin around every building). Grass never grows back. The mesher gets a one-column-border slice of the cover with each chunk
and blends it per vertex (bilinear), so the turf fades into the earth with no tile edges: the soft brush is the "tileset" of
transitions. `VoxelWorld.hold_meshing()` keeps meshing back until the cliff pass and the prop scatter are done, so the first
picture is final; later stamps rebuild only the chunks they touch (`stamp_cover_disc`, `stamp_cover_rect`).

## Units (`Navigation`, `Unit`, `UnitManager`)

- A unit is **1.7 blocks tall and 0.8 wide**: it needs the cell it stands in and the one above free, and fits a one-block corridor.
- A navigation NODE is the cell the feet are in: open air over a whole block or a brick, or *inside* a slope piece / half-dug
  block (a unit stands in a pit or on a slope, at `Blocks.surface_height` of that piece). Moves go to the 8 neighbouring
  columns, up 1 block (a hop) or down at most 3; a diagonal needs both cells beside it free. A* returns the way to the
  closest reachable cell when the goal is walled in. Everything is read from voxel data (and bricks), nothing from the scene.
- If the floor under a unit is dug away it falls to the next one; if its path is cut during a walk it looks for another.
- **Gestures** (`RTSCamera` turns raw input into the same signals on every device): tap / click = select (or use the tool),
  tap on the ground with a selection = move there, long press = command (like a right click), long press then drag = selection
  box, mouse drag = box, double tap on a unit = select all, two fingers = zoom and rotate, one finger drag = pan.
  Buttons "All units" and "Idle units" select groups.

## Work (`TaskBoard`, `Worker`, `Economy`, `Stockpile`)

- **Dig task**: the player marks columns (tap one, or drag/long-press-drag a box in "mark dig area" mode); the surface block of
  every column is marked. Units are assigned from the task list (the selection, or all idle units if none is selected).
- A **Worker** is a small state machine (SEEK -> GO_DIG -> DIG -> GO_STOCK -> PUT, WAIT when there is no room). One dig stage
  (1.3 s) gives **one bag** (half a block) of what the block is made of (`Resources.from_block`: stone, coal, iron, amber). **Earth
  (grass, dirt, sand, snow) gives nothing**: workers just break it. The worker carries the bag to the nearest stockpile that takes
  it and has room (reserved while it is on its way), puts it down and comes back to the same block for its next stage. A block
  takes two stages (whole -> half dug -> gone), a slope piece one.
- **Task filter**: a dig task brings home only the kinds that are switched on (stone, coal, iron, amber, buttons on the task row);
  the rest is broken and thrown away, so a quarry can be set to carry iron only.
- Two **stockpile** styles, both 2x2 on four whole ground blocks at one height with two free cells above (`Stockpile.can_place`: not
  on slopes or half-dug blocks, not over bricks or another stockpile):
  - the **plank platform** (24 bags; wood and ores);
  - the **frame**, four low walls round the pile (16 bags; stone and plants). Stone shows as a heap of gravel that grows with every
    bag. When the frame is filled with stone to the brim it disappears and **4 stone bricks of 2x1x1** (two layers of two, the 2x2x2
    volume) stand in its place as ordinary `BrickWorld` bricks.
  A stockpile holds one kind at a time and takes another once it is empty. With no stockpile that takes the kind, the worker
  keeps its bag and says "No free stockpile for stone".
- **Quarry** (a dig task with depth > 1, the `+/-` buttons next to "mark dig area"): it digs **layer by layer** (`DigTask.update`
  opens the next layer when the one before is dug). Each column has a limit of layers. Along the edge of the area, from its low corner and
  first along the longer side, the limits climb 0, 1, 2, 3, ...: what is left standing is a **staircase of earth or stone** down into the pit,
  **one column per step**, back to back, as short as it can be. Every step column ends in a **stair piece** (four small steps, rising towards
  the column before it); where the edge ends and there is still depth to go, the stairs turn the corner and the corner column is a **flat
  landing**, the only flat stretch. The depth is cut back when the whole edge is too short for stairs that deep. Units walk down and climb
  out one block at a time.
- **Stair piece** (`Blocks.STAIRS_FLAG`): a wedge-shaped partial piece drawn as 4 steps (`ChunkMesher._emit_stairs`), height under the feet
  stepped (`Blocks.surface_height(..., stairs)`). Only workers make it (`TerrainEdit.make_stairs`); the neighbour rules never derive, change
  or replace it, it is removed when the ground under it goes, and digging it takes one stage.
- **Where a log goes.** A worker only picks a log up when there is somewhere to take it: a free stump (with room for its planks) or a
  stockpile that takes logs; otherwise the log stays where it lies. With a free stump the log goes **there first**: the worker makes 3
  planks, carries them to a stockpile, then goes back to felling (`TaskBoard.detour_to_stump` / `resume_or_free`). Free units do the same
  by themselves for logs already on a stockpile.
- **How things are built**: the player puts down a **blueprint** (`Blueprint`, a translucent shape that covers its ground and shows what
  it still needs); its standing job (`BuildTask`) lets idle units, whenever a stockpile holds something the blueprint still needs, fetch a
  load (one log, three planks), carry it over and put it in; when everything is in, the real building stands (a station also gets its
  job). Cancelling a plan removes its job. The game starts with a plank platform and a stump near the spawn crystal.
- **Bricks and walls.** A frame filled with stone to the brim becomes a **stack of 4 stone bricks** (a `Stockpile.Style.STACK` holding 8
  halves; a brick is 2 halves, a 1x1x1 cube 1). A wall is planned as a line (`WallPlan`: bricks along it, cubes where a half is needed,
  every course offset by a cell, a running bond; up to 3 courses, because a unit lays at arm's length, 2 blocks above its feet, and
  scaffolding does not exist yet). Its job (`WallTask`) lets idle units fetch a brick from a stack (carried on the back), stand next to
  the place and lay it; **only slots with something to rest on are open**, so the wall grows from the bottom up, stage by stage. A unit
  keeps its brick while the next course is not open; a lone half goes back to the stack when no cube is left to lay.
- **Jumping**: a unit hops up one block, drops up to three, and **jumps over a gap of one cell** (a ditch, a missing block) at the same
  height or one block higher or lower (`Navigation.jump`, more expensive than walking so it is used only when it saves a detour).
- **Prices** (`Stockpile.COST`, `Station.DEFS`): a stockpile 3 planks (a guess; the original's price was not found), a stump 1 log, a rope
  machine 2 planks (a guess).
- Not done yet: wood and plant harvesting, building tasks, a task bar like the original (Harvest / Mining / Construction groups),
  and the *mining stair* state of the ground (one 2x1x1 piece, half whole block and half steps, which only units make).

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

Run from the project folder (Godot 4.7.2 headless). One command runs everything, several groups at once:

```
tests/run_all.sh              # smoke, shared, islands, cover, ramps
tests/run_all.sh shared       # only the groups whose name contains the word
```

The pass/fail verdict comes from the output (a "TEST DONE" / "SUITES DONE" line and no FAIL or SCRIPT ERROR line), not from the
exit code: Godot headless can abort while shutting down after a world was generated, even with every check passed.

- **shared** (`tests/run_suites.gd`, suites in `tests/suites/`): navigation, work (stockpiles, dig/haul loop), quarry (layers,
  staircase, stair pieces), craft (felling, logs as rigid bodies, stump, grass, rope machine) and bricks. They share **one world**, generated
  once (256 x 256, one extra island, trees and grass, no meshes) in about 2 s. Each suite gets it back in its original state
  (`VoxelWorld.snapshot()` / `restore()`, `PropField.reset()`) and its own scene container (`TestSuite`, `TestContext`). Run a few with
  `-s res://tests/run_suites.gd -- quarry work`. Suites step the units and the task board by hand with a fixed time step, so they are fast.
- `tests/world_smoke_test.gd`: generation on the full map, islands, bridges, ground stages and slopes, atomic frames, 569 random edits.
  It needs real meshes and the full-size world, so it has its own.
- `tests/island_seeds_test.gd`: 40 seeds x 3 island counts: layout and bridges. `tests/ground_cover_test.gd`, `tests/ramps_rule_test.gd`:
  no world at all (bare earth brushes; the slope rule on all 6561 neighbourhoods).

Screenshots (virtual display): `xvfb-run -a godot --path . --rendering-driver opengl3 -- --shot=out.png [--zoom=D --focus=X,Z
--pitch=DEG --yaw=DEG --extras=N --seed=S --dig=X,Z,STAGES --noprops]`.

## Conventions

- New game rules go into a rules module (like `TerrainEdit`), not into `VoxelWorld` or `main.gd`.
- Anything that runs on a worker thread must not touch the scene tree; it reads immutable snapshots.
- Parameters of a map type belong in `MapPreset`; magic numbers in generators should be moved there when they are tuned.
