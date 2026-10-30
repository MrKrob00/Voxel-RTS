class_name Tools
extends RefCounted
## What the player can do with a tap or a drag: the tools, grouped like the task panel of the original game (Harvest, Mining,
## Construction). The HUD shows them as a palette; main.gd carries them out.

enum Mode {
	SELECT,
	MARK_TREES, MARK_GRASS,
	MARK_DIG,
	STOCKPILE, STUMP, ROPE_MACHINE, REMOVE_PLAN,
	DIG, VOXEL, STONE_BRICK, STONE_CUBE, WOOD_BRICK, WOOD_CUBE,
}

## The tabs of the build panel, as the original's strip at the left: stone blocks, wood blocks, structures; each with its title and
## the sections it shows.
const TABS := {
	"stone": {"title": "Stone Blocks", "icon": "brick", "sections": ["Stone Blocks", "Plugs", "Round Bricks", "Crenelations"]},
	"wood": {"title": "Wood Blocks", "icon": "log", "sections": ["Wood Blocks"]},
	"structures": {"title": "Structures", "icon": "platform", "sections": ["Storage", "Production", "Plans"]},
}
const TAB_ORDER := ["stone", "wood", "structures"]
## The tool of the block number i of the BlockCatalog is BLOCK_BASE + i.
const BLOCK_BASE := 1000
## The pseudo tool of the "Construction" tile of the task panel: it opens the panel of blocks.
const OPEN_BLOCKS := -2
## Emblem of "stop" in the round menu.
const STOP := -3
const CATEGORIES := ["Harvest", "Mining", "Construction", "Sandbox"]


## Every tool except Select: {mode, category, label, hint, level (does it use the level stepper), level_name}.
static func defs() -> Array[Dictionary]:
	var out: Array[Dictionary] = _fixed_defs()
	var blocks := BlockCatalog.all()
	for i in blocks.size():
		var b: Dictionary = blocks[i]
		var wood: bool = b.material == BlockCatalog.WOOD
		out.append({"mode": BLOCK_BASE + i, "category": "Construction", "section": b.section, "tab": "wood" if wood else "stone", "label": b.label, "short": b.label, "block": b.id,
			"enabled": not wood,
			"hint": ("Needs plugs to stand on: coming. Costs one plank." if wood else "Tap to plan one, or drag the way it should lie (the round arrow turns it, or the R key). Costs one block of stone, whatever its shape.")})
	return out


## The icon of a tool that has no model to photograph (felling, quarry...), from assets/icons (game-icons.net), or null.
static func icon_texture(mode: int) -> Texture2D:
	var name: String = {
		Mode.MARK_TREES: "fell_trees", Mode.MARK_GRASS: "cut_grass", Mode.MARK_DIG: "quarry", OPEN_BLOCKS: "build", STOP: "stop", Mode.REMOVE_PLAN: "stop",
		Mode.DIG: "dig_now", Mode.VOXEL: "fill_ground", Mode.STONE_BRICK: "free_stone", Mode.STONE_CUBE: "free_stone",
		Mode.WOOD_BRICK: "free_wood", Mode.WOOD_CUBE: "free_wood",
	}.get(mode, "")
	return load("res://assets/icons/%s.svg" % name) as Texture2D if name != "" else null


## The picture of a structure (stockpile, stump...) for the palette, or null.
static func structure_picture(mode: int) -> Texture2D:
	var id: String = {Mode.STOCKPILE: "platform", Mode.STUMP: "stump", Mode.ROPE_MACHINE: "rope_machine"}.get(mode, "")
	return load("res://assets/structures/icons/%s.png" % id) as Texture2D if id != "" else null


static func is_block(mode: int) -> bool:
	return mode >= BLOCK_BASE


static func block_of(mode: int) -> String:
	var blocks := BlockCatalog.all()
	var i := mode - BLOCK_BASE
	return blocks[i].id if i >= 0 and i < blocks.size() else ""


static func _fixed_defs() -> Array[Dictionary]:
	return [
		{"mode": Mode.MARK_TREES, "category": "Harvest", "label": "Fell trees", "short": "Trees", "hint": "Tap a tree or drag a box over trees. Logs are carried to a platform, or to a free stump first."},
		{"mode": Mode.MARK_GRASS, "category": "Harvest", "label": "Cut grass", "short": "Grass", "hint": "Tap or drag over grass. The sacks go to a crate."},
		{"mode": Mode.MARK_DIG, "category": "Mining", "label": "Dig / quarry", "short": "Quarry", "hint": "Drag a box over the ground. Level 1 clears the surface; more digs layer by layer and leaves a staircase.", "level": true, "level_name": "depth"},
		{"mode": Mode.STOCKPILE, "category": "Construction", "label": "Stockpile 2x2", "section": "Storage", "tab": "structures", "short": "Stockpile", "hint": "Where units put what they carry. It looks like a platform for logs and planks, a crate for stone and grass, a stack of bricks. Costs 3 planks, brought by units."},
		{"mode": Mode.STUMP, "category": "Construction", "label": "Stump with axe", "section": "Production", "tab": "structures", "short": "Stump", "hint": "Makes 3 planks of a log. Costs a log. Free units use it by themselves."},
		{"mode": Mode.ROPE_MACHINE, "category": "Construction", "label": "Rope machine", "section": "Production", "tab": "structures", "short": "Rope", "hint": "Makes a rope of 2 sacks of grass. Costs 2 planks."},
		{"mode": Mode.REMOVE_PLAN, "category": "Construction", "label": "Remove plans", "section": "Plans", "tab": "structures", "short": "Remove", "hint": "Tap a plan (a planned structure or wall), tap it again to remove it. What its units brought is lost."},
		{"mode": Mode.DIG, "category": "Sandbox", "label": "Dig now", "short": "Dig now", "hint": "Dig a block at once (no units)."},
		{"mode": Mode.VOXEL, "category": "Sandbox", "label": "Fill ground", "short": "Fill", "hint": "Fill a cell with ground at once."},
		{"mode": Mode.STONE_BRICK, "category": "Sandbox", "label": "Free stone brick", "short": "Brick S", "hint": "Put a brick down at once."},
		{"mode": Mode.STONE_CUBE, "category": "Sandbox", "label": "Free stone cube", "short": "Cube S", "hint": "Put a cube down at once."},
		{"mode": Mode.WOOD_BRICK, "category": "Sandbox", "label": "Free wood brick", "short": "Brick W", "hint": "Put a brick down at once."},
		{"mode": Mode.WOOD_CUBE, "category": "Sandbox", "label": "Free wood cube", "short": "Cube W", "hint": "Put a cube down at once."},
	]


static func def_of(mode: int) -> Dictionary:
	for d in defs():
		if d.mode == mode:
			return d
	return {"mode": Mode.SELECT, "category": "", "label": "Select / move", "hint": "Tap a unit to select it, tap the ground to send it there. Long press and drag draws a box."}
