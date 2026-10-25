class_name Resources
extends RefCounted
## The kinds of material that units dig up, carry and store.

enum Kind { NONE, DIRT, STONE, COAL, IRON, AMBER, SAND, WOOD, PLANT }

const NAMES := {
	Kind.DIRT: "Earth", Kind.STONE: "Stone", Kind.COAL: "Coal", Kind.IRON: "Iron",
	Kind.AMBER: "Amber", Kind.SAND: "Sand", Kind.WOOD: "Wood", Kind.PLANT: "Plants",
}
const COLORS := {
	Kind.DIRT: Color("7a5a3a"), Kind.STONE: Color("8a8d91"), Kind.COAL: Color("3a3a3e"), Kind.IRON: Color("a9c9dd"),
	Kind.AMBER: Color("f08a1c"), Kind.SAND: Color("dccf8f"), Kind.WOOD: Color("b98a4e"), Kind.PLANT: Color("5fa83a"),
}


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
		Blocks.PLANK:
			return Kind.WOOD
	return Kind.NONE


## The things a quarry brings by default; the player can switch kinds off per task (those are broken and thrown away).
const DIGGABLE := [Kind.STONE, Kind.COAL, Kind.IRON, Kind.AMBER]


static func label(kind: int) -> String:
	return NAMES.get(kind, "?")
