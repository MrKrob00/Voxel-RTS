# Castle Story: reference notes

Source: 14 gameplay screenshots from `images/` (YouTube frames, 2026-10-24), plus public descriptions of the game.
Used as a **design reference only**: our code, meshes and art are our own. Do not copy assets from the game.

## Look and feel (what our map must get closer to)

- **Terrain is voxel, but it does not look like coloured cubes.** Tops are smooth, painted surfaces with soft blended
  patches (grass / dirt / snow / sand edges are organic, not square). Cliff walls are textured stone (cobble pattern with
  small orange and silver ore flecks) with a brown dirt band at the top.
- **Biomes**: green forest, desert (sand + cracked-dry-ground texture + palms/bushes), snow (white ground, blue-ice
  patches, snowy pines). The sandbox map is an island with water around and below the cliffs.
- **Ground cover is everywhere**: leafy plants / grass tufts in dense clusters, harvestable; pine forests in groups;
  bare dirt paths and a dirt ring around the spawn crystal; boulders; logs and stumps after felling.
- **Flat build zone near the start** (crystal in a dirt circle), wild terrain and cliffs further out.
- Lighting: strong directional sun, long soft shadows, saturated colours, light haze.
- Camera: tilted top-down, can look straight down; zoom from whole camp to single unit.

## Units

- **Bricktrons**: yellow blob workers, brown sack on the back when carrying, pickaxe/axe in hand, a yellow ring under
  the selected unit.
- **Soldiers**: blue-cap archers (crossbow), melee with helmets; named hero units (name tag with an icon).
- **Enemy**: dark rock-golem creatures. Units show speech bubbles about their state ("Can't reach my destination",
  "My destination storage became full").
- **Population cap** (5/15) and **"Next Bricktron" energy bar** (20/100): the blue spawn crystal turns gathered energy
  into new units. Enemy spawn crystals are purple.

## Resources and models seen

| Thing | Look | Notes |
|---|---|---|
| Wood | pines (green / snowy / dry olive), felled logs, stumps, plank stacks | harvest tree -> logs -> planks |
| Stone | grey / tan boulder clusters, loose rubble, grey cut blocks | quarried from cliffs or harvested on the surface |
| Orange ore | clusters of orange crystals on the ground and flecks in cliff walls | the furnace resource (per the user) |
| Iron | silver / blue-grey flecks in stone walls | |
| Blue crystal | large blue spawn crystal; small blue crystals carried as energy | spawns units |
| Plants | green leaf clusters, snowy variants, desert palms | harvestable |
| Stockpile | wooden plank platform, wooden crate filled with gravel, plank stacks, stone block stacks | warning when full: "You need more empty stockpiles" |

## Mechanics visible in the screenshots

- **Task bar** at the bottom: groups (Crystal, Harvest, Build, Quarry, Cleanup) with worker dots; counter "Tasks 4/15".
  Each task marker in the world shows an icon and workers/slots (`x 2/8`) with a yellow beam down to the target.
- **Creating a task**: tool opens a panel with Goals, Resource Types (stone, ore, orange ore, tree, plants),
  Priority (- / +) and Actions (confirm, confirm-and-continue, cancel, delete with Ctrl+Del). Harvest uses a round
  brush (yellow circle) over an area; Build/Quarry use area/box selection.
- **Quarry/dig**: rectangular pits are dug voxel by voxel with **stairs cut into the wall** (half-height steps),
  dust particles; the pit bottom shows darker stone with orange ore.
- **Build**: a block palette (Stone Blocks, Plugs, Round Bricks, Crenelations, Wood Blocks) with many shapes
  (cube, slab, stairs, wedge, pillar, battlement). Cyan translucent **blueprint** of the planned wall, **red** where it
  is not allowed. Walls are bonded (offset) brick rows with arrow slits and a gate.
- **Physics on placed blocks**: stacks and walls topple like dominoes, leaning walls, rubble pieces fall
  (screenshots with a "Debug Mode" label). Terrain voxels do not move.
- **Minimap** top-left with mode name (Conquest / Sandbox) and timer, island silhouette, fog of war (black = unexplored),
  droplet icons = resource spots, spawn crystals; resource counters under it.
- Modes seen: **Conquest** (vs other players / creatures) and **Sandbox**.
- Combat: squads split into Melee / Ranged buttons (bottom right), attack lines, red rings on targets, rally marker.
- Selection rotate gizmo (arc arrows) to set formation facing.

## What this means for us

Decisions already taken:
- Floating islands, finite map, voxel terrain, GDScript, Godot 4.7.2, Compatibility renderer (tablet + PC), multiplayer last.
- Placement check "not in mid-air" instead of load simulation.

Open questions to settle with the user:
- Do placed building blocks get physics (topple / fall) like the original, or stay static? (screenshots show they topple)
- Are building blocks separate smaller shapes (bricks, stairs, wedges) or just voxels? The original uses a palette of shapes.
- Biomes per island (forest / desert / snow)?

Next work, in order:
1. Terrain look: smooth blended top colours (per-vertex colour noise instead of one flat colour per block), textured cliff
   walls (stone with ore flecks), dirt band, soft biome borders, per-island biome.
2. Ground cover and models, all procedural low-poly (no external assets) and batched with `MultiMeshInstance3D`
   for tablets: pine tree, boulder, orange crystal cluster, iron fleck, grass tuft, log, stump, spawn crystal.
3. Flat dirt build zone with the spawn crystal on the start island.
4. Units: Bricktron model, selection, move orders, voxel pathfinding (bridges between islands).
5. Tasks: harvest / quarry / build with a task bar, stockpiles, hauling.
6. Combat and enemies, then multiplayer.

## From the second batch of screenshots (task panel)

- The "New Task" panel groups tools: **Maintenance**, **Harvest** (tree, plants, ...; several resource icons), **Mining** (dig, dig
  with a block, a shovel) and **Construction**. A harvest task is a circle on the map with a counter of workers `x 0/8`; idle
  Bricktrons show "Nothing to do" above their heads. The spawn crystal sits on a small ring of bare earth.
- The player assigns Bricktrons to tasks; a task with no free stockpile, no reachable target or no resource leaves them idle.
- Mining tunnels have a special piece (`cs_mining_tunnel_or_01`): one 2x1x1 block, half a normal block and half steps. Only units
  make it (the ground generator never does): it is the digging state for walking into a hillside. TODO with sideways digging.
