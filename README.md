# Voxel RTS

A voxel real-time strategy prototype in Godot 4.7 (GDScript), inspired by Castle Story: floating islands joined by bridges,
destructible voxel ground, units that dig and build, and bricks that stack and collapse. Designed for tablet and PC.

Status: sandbox. The world, ground editing, bricks, units with pathfinding, dig tasks and stockpiles work; wood and plants, building
tasks, enemies and multiplayer are next.

- `docs/architecture.md`: modules, the voxel format, the rules of digging and building, tests.
- `docs/castle-story-reference.md`, `docs/reference-images.md`: notes on the game that inspired this one.
- `tests/`: headless checks, `tests/run_all.sh` runs them all (a few minutes). `scenes/main.tscn` is the sandbox.

Controls (sandbox): WASD pan, Q/E rotate, R/F tilt, wheel zoom, middle-drag rotate; on touch one finger drags, two pinch and
twist. Tap / left click selects a unit or uses the current mode (select and move, mark dig area, place stockpile, dig, build
ground, bricks); long press or right click is the command (move there); mouse drag, or long press and then drag, draws a
selection box; double tap a unit selects all; T rotates a brick. The "Mode" button cycles the tools.
