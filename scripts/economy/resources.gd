class_name Resources
extends RefCounted
## The kinds of things that units dig up, carry, store and make.

## BRICK counts HALVES of a 2x1x1 stone brick: a brick is 2, a 1x1x1 cube is 1, a unit carries one brick (2) at a time.
enum Kind { NONE, STONE, COAL, IRON, AMBER, LOG, PLANK, PLANT, ROPE, BRICK }

const NAMES := {
	Kind.STONE: "Stone", Kind.COAL: "Coal", Kind.IRON: "Iron", Kind.AMBER: "Amber",
	Kind.LOG: "Log", Kind.PLANK: "Plank", Kind.PLANT: "Grass", Kind.ROPE: "Rope", Kind.BRICK: "Brick half",
}
const COLORS := {
	Kind.STONE: Color("8a8d91"), Kind.COAL: Color("3a3a3e"), Kind.IRON: Color("a9c9dd"), Kind.AMBER: Color("f08a1c"),
	Kind.LOG: Color("7b5630"), Kind.PLANK: Color("c9985a"), Kind.PLANT: Color("5fa83a"), Kind.ROPE: Color("d9c28a"), Kind.BRICK: Color("9a9da2"),
}
## How many a unit carries at once: everything is one bag or one log, but three planks go on the back together.
const CARRY := {Kind.PLANK: 3, Kind.BRICK: 2}

## The things a quarry brings by default; the player can switch kinds off per task (those are broken and thrown away).
const DIGGABLE := [Kind.STONE, Kind.COAL, Kind.IRON, Kind.AMBER]


static func carry_capacity(kind: int) -> int:
	return CARRY.get(kind, 1)


## What a unit gets from digging a block of this material: a bag of it. Earth (grass, dirt, sand, snow) gives nothing:
## workers just break it and it is gone. Kind.NONE means "nothing to carry".
static func from_block(material: int) -> int:
	match material:
		Blocks.STONE:
			return Kind.STONE
		Blocks.COAL:
			return Kind.COAL
		Blocks.IRON:
			return Kind.IRON
		Blocks.ORANGE_ORE:
			return Kind.AMBER
	return Kind.NONE


static func label(kind: int) -> String:
	return NAMES.get(kind, "?")
