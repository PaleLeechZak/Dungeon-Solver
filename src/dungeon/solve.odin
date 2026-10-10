package dungeon

import "core:strings"

Solve_Result :: struct {
	reached:      []bool, // per room
	rooms_reached: int,
	keys_found:   int,
	doors_opened: int,
	solvable:     bool, // every room can be reached from the entrance
}

// Plays the dungeon the way a player would: walk everywhere that is open,
// pick up every key in reach, unlock what those keys open, repeat.
solve :: proc(d: ^Dungeon, allocator := context.allocator) -> Solve_Result {
	result := Solve_Result {
		reached = make([]bool, len(d.rooms), allocator),
	}
	if len(d.rooms) == 0 {
		return result
	}
	keys := make([]bool, d.lock_count, context.temp_allocator)
	opened := make([]bool, len(d.conns), context.temp_allocator)
	result.reached[0] = true
	result.rooms_reached = 1

	for progressed := true; progressed; {
		progressed = false
		for slot in d.item_slots {
			if slot.key >= 0 && result.reached[slot.room] && !keys[slot.key] {
				keys[slot.key] = true
				result.keys_found += 1
				progressed = true
			}
		}
		for conn, i in d.conns {
			if result.reached[conn.from] == result.reached[conn.to] {
				continue
			}
			if conn.locked && !keys[conn.lock_id] {
				continue
			}
			if conn.locked && !opened[i] {
				opened[i] = true
				result.doors_opened += 1
			}
			result.reached[conn.from] = true
			result.reached[conn.to] = true
			result.rooms_reached += 1
			progressed = true
		}
	}
	result.solvable = result.rooms_reached == len(d.rooms)
	return result
}

Stats :: struct {
	rooms:        int,
	by_kind:      [Room_Kind]int,
	doors:        int,
	merges:       int, // open-wall connections
	locks:        int,
	item_slots:   int,
	chests:       int,
	swords:       int,
	amulets:      int,
	enemy_spawns: int,
	max_depth:    int,
}

stats :: proc(d: ^Dungeon) -> (s: Stats) {
	s.rooms = len(d.rooms)
	for room in d.rooms {
		s.by_kind[room.kind] += 1
		s.max_depth = max(s.max_depth, room.depth)
	}
	for conn in d.conns {
		if conn.kind == .Door {
			s.doors += 1
		} else {
			s.merges += 1
		}
	}
	s.locks = d.lock_count
	s.item_slots = len(d.item_slots)
	for slot in d.item_slots {
		s.chests += int(slot.chest)
		s.swords += int(slot.item == .Sword)
		s.amulets += int(slot.item == .Amulet)
	}
	s.enemy_spawns = len(d.enemy_spawns)
	return
}

// Top-down text rendering, north up:
//   #  wall     +  door     A-Z  locked door     a-z  key for the same letter
//   .  floor    @  player   !    enemy spawn     %    sword     *  amulet
//   $  empty chest          ,    empty spot on the floor
// Text cannot show whether a key or sword is in a chest or on the floor.
dungeon_to_ascii :: proc(d: ^Dungeon, allocator := context.allocator) -> string {
	grid := make([]u8, d.w * d.h, context.temp_allocator)
	for cell, i in d.cells {
		switch cell.kind {
		case .Empty:
			grid[i] = ' '
		case .Floor, .Open:
			grid[i] = '.'
		case .Wall:
			grid[i] = '#'
		case .Door:
			grid[i] = '+'
			if cell.conn >= 0 && d.conns[cell.conn].locked {
				grid[i] = 'A' + u8(d.conns[cell.conn].lock_id % 26)
			}
		}
	}
	for spawn in d.enemy_spawns {
		grid[spawn.pos.y * d.w + spawn.pos.x] = '!'
	}
	for slot in d.item_slots {
		glyph: u8
		switch slot.item {
		case .Key:
			glyph = 'a' + u8(slot.key % 26)
		case .Sword:
			glyph = '%'
		case .Amulet:
			glyph = '*'
		case .None:
			glyph = slot.chest ? '$' : ','
		}
		grid[slot.pos.y * d.w + slot.pos.x] = glyph
	}
	if len(d.rooms) > 0 {
		grid[d.player_spawn.y * d.w + d.player_spawn.x] = '@'
	}

	sb := strings.builder_make(allocator)
	for y in 0 ..< d.h {
		strings.write_bytes(&sb, grid[y * d.w:(y + 1) * d.w])
		strings.write_byte(&sb, '\n')
	}
	return strings.to_string(sb)
}
