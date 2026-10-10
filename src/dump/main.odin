// Headless inspection tool: generates a dungeon and prints it as text.
// It opens no window and needs no GPU, so it is safe to run anywhere.
//
//   odin run src/dump -- [config path] [seed]
package dump

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"

import "../dungeon"

main :: proc() {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.eprintln("out of memory")
		os.exit(1)
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	path := len(os.args) > 1 ? os.args[1] : "config/dungeon.json5"
	cfg, err, ok := dungeon.config_load(path, allocator)
	if !ok {
		fmt.eprintln(err)
		os.exit(1)
	}

	seed := cfg.seed
	if len(os.args) > 2 {
		parsed, parse_ok := strconv.parse_u64(os.args[2])
		if !parse_ok {
			fmt.eprintfln("'%s' is not a seed", os.args[2])
			os.exit(1)
		}
		seed = parsed
	}
	if seed == 0 {
		seed = 1
	}

	d, gerr, gok := dungeon.generate(&cfg, seed, allocator)
	if !gok {
		fmt.eprintln(gerr)
		os.exit(1)
	}

	fmt.print(dungeon.dungeon_to_ascii(d, allocator))
	s := dungeon.stats(d)
	result := dungeon.solve(d, allocator)
	fmt.printfln("seed %d (attempt %d), %dx%d cells", d.seed, d.attempt, d.w, d.h)
	fmt.printfln(
		"rooms %d: %d normal, %d encounter, %d hallway, 1 entrance; max depth %d",
		s.rooms,
		s.by_kind[.Normal],
		s.by_kind[.Encounter],
		s.by_kind[.Hallway],
		s.max_depth,
	)
	fmt.printfln(
		"doors %d (%d locked), merged walls %d, item slots %d (%d chests), enemy spawns %d",
		s.doors,
		s.locks,
		s.merges,
		s.item_slots,
		s.chests,
		s.enemy_spawns,
	)
	fmt.printfln(
		"solver: %d/%d rooms reached, %d keys found, solvable = %v",
		result.rooms_reached,
		s.rooms,
		result.keys_found,
		result.solvable,
	)
	place :: proc(slot: dungeon.Item_Slot) -> string {
		return slot.chest ? "in a chest" : "on the floor"
	}
	for slot in d.item_slots {
		if slot.item == .Amulet {
			fmt.printfln(
				"  amulet: %s in room %d (%s), %d rooms from the entrance",
				place(slot),
				slot.room,
				dungeon.room_template(d, slot.room).name,
				d.rooms[slot.room].depth,
			)
		}
		if slot.item == .Sword {
			fmt.printfln("  sword: %s in room %d (%s)", place(slot), slot.room, dungeon.room_template(d, slot.room).name)
		}
	}
	for conn in d.conns {
		if !conn.locked {
			continue
		}
		for slot in d.item_slots {
			if slot.key == conn.lock_id {
				fmt.printfln(
					"  lock %c: door into room %d (%s), key %s in room %d (%s)",
					'A' + rune(conn.lock_id % 26),
					conn.to,
					dungeon.room_template(d, conn.to).name,
					place(slot),
					slot.room,
					dungeon.room_template(d, slot.room).name,
				)
			}
		}
	}
}
