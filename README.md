# Voxel RTS

A voxel real-time strategy prototype in Godot 4.7 (GDScript), inspired by Castle Story: floating islands joined by bridges,
destructible voxel ground, units that dig and build, and bricks that stack and collapse. Designed for tablet and PC.

Status: sandbox. The world, ground editing and bricks work; units, pathfinding, resources and combat are next.

- `docs/architecture.md`: modules, the voxel format, the rules of digging and building, tests.
- `docs/castle-story-reference.md`, `docs/reference-images.md`: notes on the game that inspired this one.
- `tests/`: headless checks. `scenes/main.tscn` is the sandbox.

Controls (sandbox): WASD pan, Q/E rotate, R/F tilt, wheel zoom, middle-drag rotate; on touch one finger drags, two pinch and
twist. Left click uses the current mode (dig, build ground, bricks); right click digs; T rotates a brick.
