package dungeon

import "base:runtime"
import "core:fmt"

// Grid directions. Grid y grows southwards and maps onto world +Z.
Dir :: enum u8 {
	N,
	E,
	S,
	W,
}
Dirs :: bit_set[Dir;u8]

dir_vec :: proc(d: Dir) -> [2]int {
	switch d {
	case .N:
		return {0, -1}
	case .E:
		return {1, 0}
	case .S:
		return {0, 1}
	case .W:
		return {-1, 0}
	}
	return {}
}

dir_opposite :: proc(d: Dir) -> Dir {
	return Dir((int(d) + 2) % 4)
}

// Axis a node's cells run along: west to east on N/S sides, north to south on E/W sides.
node_axis :: proc(side: Dir) -> [2]int {
	return side == .N || side == .S ? {1, 0} : {0, 1}
}

// Arms of a straight wall section sitting on the given side of a room.
straight_arms :: proc(side: Dir) -> Dirs {
	return side == .N || side == .S ? {.E, .W} : {.N, .S}
}

Room_Kind :: enum u8 {
	Normal,
	Entrance,
	Encounter,
	Hallway,
}

Template_Cell :: enum u8 {
	Floor,
	Wall,
	Door,
	Open, // perimeter cell with its wall left off
}

Node_Kind :: enum u8 {
	Door,
	Open,
}

// A place on the perimeter where another room attaches. A door is one cell
// wide; an open node covers a run of missing walls and only joins an open
// node of the same width, merging both rooms into one odd-shaped room.
Template_Node :: struct {
	kind:  Node_Kind,
	pos:   [2]int, // first cell of the run, see node_axis
	dir:   Dir, // points out of the room
	width: int,
}

// A place an item can be: inside a chest, or lying on the floor.
Template_Slot :: struct {
	pos:   [2]int,
	chest: bool,
}

Template_Decor :: struct {
	pos: [2]int,
	key: string,
}

// Layout characters:
//   #  wall (required on all four corners)      .  floor
//   D  door node, perimeter only                P  player spawn
//   ~  missing wall, perimeter only             E  enemy spawn
//                                               I  item slot: a chest
//                                               i  item slot: on the floor
// Any other interior character is looked up in the config's decor table.
Template :: struct {
	name:             string,
	kind:             Room_Kind,
	weight:           f32,
	max_count:        int,
	floor:            string,
	base:             int, // index shared by all rotations of one room
	rotation:         int, // clockwise quarter turns applied to the authored layout
	w, h:             int,
	cells:            []Template_Cell,
	arms:             []Dirs, // directions a wall cell continues in
	nodes:            []Template_Node,
	has_player_spawn: bool,
	player_spawn:     [2]int,
	enemy_spawns:     [][2]int,
	item_slots:       []Template_Slot,
	decor:            []Template_Decor,
}

template_parse :: proc(
	rows: []string,
	decor: map[string][]string,
	allocator := context.allocator,
) -> (
	t: Template,
	err: string,
	ok: bool,
) {
	h := len(rows)
	if h < 3 {
		return t, "layout needs at least 3 rows", false
	}
	w := len(rows[0])
	if w < 3 {
		return t, "layout needs at least 3 columns", false
	}
	for row, y in rows {
		if len(row) != w {
			return t, fmt.aprintf("row %d is %d wide, expected %d", y, len(row), w, allocator = allocator), false
		}
	}

	t.w, t.h = w, h
	t.cells = make([]Template_Cell, w * h, allocator)
	t.arms = make([]Dirs, w * h, allocator)
	enemy_spawns := make([dynamic][2]int, allocator)
	item_slots := make([dynamic]Template_Slot, allocator)
	decor_cells := make([dynamic]Template_Decor, allocator)

	for y in 0 ..< h {
		for x in 0 ..< w {
			c := rows[y][x]
			i := y * w + x
			on_x := x == 0 || x == w - 1
			on_y := y == 0 || y == h - 1
			switch {
			case on_x && on_y:
				if c != '#' {
					return t, fmt.aprintf("corner (%d,%d) must be '#', got '%c'", x, y, c, allocator = allocator), false
				}
				t.cells[i] = .Wall
				t.arms[i] = {x == 0 ? .E : .W, y == 0 ? .S : .N}
			case on_x || on_y:
				side: Dir = y == 0 ? .N : y == h - 1 ? .S : x == 0 ? .W : .E
				switch c {
				case '#':
					t.cells[i] = .Wall
					t.arms[i] = straight_arms(side)
				case 'D':
					t.cells[i] = .Door
					t.arms[i] = straight_arms(side)
				case '~':
					t.cells[i] = .Open
				case:
					return t,
						fmt.aprintf("perimeter (%d,%d) must be '#', 'D' or '~', got '%c'", x, y, c, allocator = allocator),
						false
				}
			case:
				t.cells[i] = .Floor
				switch c {
				case '.':
				case 'P':
					if t.has_player_spawn {
						return t, "layout has more than one player spawn", false
					}
					t.has_player_spawn = true
					t.player_spawn = {x, y}
				case 'E':
					append(&enemy_spawns, [2]int{x, y})
				case 'I':
					append(&item_slots, Template_Slot{pos = {x, y}, chest = true})
				case 'i':
					append(&item_slots, Template_Slot{pos = {x, y}})
				case '#', 'D', '~':
					return t,
						fmt.aprintf("'%c' at (%d,%d) is only allowed on the perimeter", c, x, y, allocator = allocator),
						false
				case:
					key := rows[y][x:x + 1]
					if key not_in decor {
						return t, fmt.aprintf("unknown layout character '%c' at (%d,%d)", c, x, y, allocator = allocator), false
					}
					append(&decor_cells, Template_Decor{pos = {x, y}, key = key})
				}
			}
		}
	}

	nodes := make([dynamic]Template_Node, allocator)
	scan_side :: proc(t: ^Template, nodes: ^[dynamic]Template_Node, side: Dir, start: [2]int, count: int) {
		axis := node_axis(side)
		run_start := -1
		for i in 0 ..= count {
			kind := Template_Cell.Wall
			pos := start + axis * i
			if i < count {
				kind = t.cells[pos.y * t.w + pos.x]
			}
			if kind == .Open {
				if run_start < 0 {
					run_start = i
				}
				continue
			}
			if run_start >= 0 {
				append(nodes, Template_Node{kind = .Open, pos = start + axis * run_start, dir = side, width = i - run_start})
				run_start = -1
			}
			if kind == .Door {
				append(nodes, Template_Node{kind = .Door, pos = pos, dir = side, width = 1})
			}
		}
	}
	scan_side(&t, &nodes, .N, {1, 0}, w - 2)
	scan_side(&t, &nodes, .E, {w - 1, 1}, h - 2)
	scan_side(&t, &nodes, .S, {1, h - 1}, w - 2)
	scan_side(&t, &nodes, .W, {0, 1}, h - 2)

	t.nodes = nodes[:]
	t.enemy_spawns = enemy_spawns[:]
	t.item_slots = item_slots[:]
	t.decor = decor_cells[:]
	return t, "", true
}

// A layout has to stay walkable once its props are solid: nothing may stand
// right inside a door or opening, the free floor has to be one connected
// area, and every item slot needs free floor next to it to be reached from.
template_check_walkable :: proc(t: ^Template, allocator := context.allocator) -> (err: string, ok: bool) {
	blocked := make([]bool, t.w * t.h, context.temp_allocator)
	for decor in t.decor {
		blocked[decor.pos.y * t.w + decor.pos.x] = true
	}
	for slot in t.item_slots {
		// Only chests are in the way; things on the floor are walked over.
		if slot.chest {
			blocked[slot.pos.y * t.w + slot.pos.x] = true
		}
	}
	free :: proc(t: ^Template, blocked: []bool, pos: [2]int) -> bool {
		if pos.x < 0 || pos.y < 0 || pos.x >= t.w || pos.y >= t.h {
			return false
		}
		i := pos.y * t.w + pos.x
		return t.cells[i] == .Floor && !blocked[i]
	}

	for node in t.nodes {
		for i in 0 ..< node.width {
			inside := node.pos + node_axis(node.dir) * i - dir_vec(node.dir)
			if !free(t, blocked, inside) {
				return fmt.aprintf("the floor at (%d,%d), right inside a door or opening, must be clear", inside.x, inside.y, allocator = allocator),
					false
			}
		}
	}

	reached := make([]bool, t.w * t.h, context.temp_allocator)
	stack := make([dynamic][2]int, context.temp_allocator)
	total := 0
	for y in 0 ..< t.h {
		for x in 0 ..< t.w {
			if !free(t, blocked, {x, y}) {
				continue
			}
			total += 1
			if len(stack) == 0 {
				append(&stack, [2]int{x, y})
				reached[y * t.w + x] = true
			}
		}
	}
	count := 0
	for len(stack) > 0 {
		pos := pop(&stack)
		count += 1
		for dir in Dir {
			next := pos + dir_vec(dir)
			if free(t, blocked, next) && !reached[next.y * t.w + next.x] {
				reached[next.y * t.w + next.x] = true
				append(&stack, next)
			}
		}
	}
	if count != total {
		return "props cut the floor into separate areas", false
	}

	for slot in t.item_slots {
		reachable := false
		for dy in -1 ..= 1 {
			for dx in -1 ..= 1 {
				reachable ||= free(t, blocked, slot.pos + {dx, dy})
			}
		}
		if !reachable {
			return fmt.aprintf("item slot (%d,%d) is walled in by props", slot.pos.x, slot.pos.y, allocator = allocator), false
		}
	}
	return "", true
}

// Rotates a layout a quarter turn clockwise: its north side becomes its east side.
rotate_rows :: proc(rows: []string, allocator := context.allocator) -> []string {
	h := len(rows)
	w := h > 0 ? len(rows[0]) : 0
	out := make([]string, w, allocator)
	for ny in 0 ..< w {
		buf := make([]u8, h, allocator)
		for nx in 0 ..< h {
			buf[nx] = rows[h - 1 - nx][ny]
		}
		out[ny] = string(buf)
	}
	return out
}

// Layout of a hallway running west to east: one floor tile wide, a door at
// each end and a chance of a door on every wall cell along its length.
hallway_rows :: proc(length: int, side_door_chance: f32, rng: ^Rng, allocator := context.allocator) -> []string {
	w := length + 2
	rows := make([]string, 3, allocator)
	for y in 0 ..< 3 {
		buf := make([]u8, w, allocator)
		for x in 0 ..< w {
			end := x == 0 || x == w - 1
			switch {
			case y == 1:
				buf[x] = end ? 'D' : '.'
			case end:
				buf[x] = '#'
			case:
				buf[x] = rng_chance(rng, side_door_chance) ? 'D' : '#'
			}
		}
		rows[y] = string(buf)
	}
	return rows
}

room_kind_parse :: proc(s: string) -> (kind: Room_Kind, ok: bool) {
	switch s {
	case "", "normal":
		return .Normal, true
	case "entrance":
		return .Entrance, true
	case "encounter":
		return .Encounter, true
	}
	return .Normal, false
}

// Expands the config into the concrete templates generation draws from: every
// authored room in each allowed rotation, plus freshly rolled hallways.
build_templates :: proc(
	cfg: ^Config,
	rng: ^Rng,
	allocator := context.allocator,
) -> (
	templates: []Template,
	err: string,
	ok: bool,
) {
	out := make([dynamic]Template, allocator)
	rotations := cfg.generation.allow_rotation ? 4 : 1

	add_rotations :: proc(
		out: ^[dynamic]Template,
		proto: Template,
		rows: []string,
		rotations: int,
		decor: map[string][]string,
		allocator: runtime.Allocator,
	) -> (
		first: ^Template,
		err: string,
		ok: bool,
	) {
		rows := rows
		start := len(out)
		for r in 0 ..< rotations {
			t, perr, pok := template_parse(rows, decor, allocator)
			if !pok {
				return nil, fmt.aprintf("room '%s': %s", proto.name, perr, allocator = allocator), false
			}
			t.name = proto.name
			t.kind = proto.kind
			t.weight = proto.weight / f32(rotations)
			t.max_count = proto.max_count
			t.floor = proto.floor
			t.base = proto.base
			t.rotation = r
			append(out, t)
			rows = rotate_rows(rows, allocator)
		}
		return &out[start], "", true
	}

	for room, i in cfg.rooms {
		kind, kind_ok := room_kind_parse(room.kind)
		if !kind_ok {
			return nil, fmt.aprintf("room '%s': unknown kind '%s'", room.name, room.kind, allocator = allocator), false
		}
		floor := room.floor == "" ? DEFAULT_FLOOR : room.floor
		if floor not_in cfg.floors {
			return nil, fmt.aprintf("room '%s': floor '%s' is not defined in floors", room.name, floor, allocator = allocator), false
		}
		proto := Template {
			name      = room.name,
			kind      = kind,
			weight    = room.weight > 0 ? room.weight : 1,
			max_count = room.max_count,
			floor     = floor,
			base      = i,
		}
		first, aerr, aok := add_rotations(&out, proto, room.layout, rotations, cfg.decor, allocator)
		if !aok {
			return nil, aerr, false
		}
		if werr, wok := template_check_walkable(first, allocator); !wok {
			return nil, fmt.aprintf("room '%s': %s", room.name, werr, allocator = allocator), false
		}
		if len(first.nodes) == 0 {
			return nil, fmt.aprintf("room '%s' has no door or open wall", room.name, allocator = allocator), false
		}
		if (kind == .Entrance) != first.has_player_spawn {
			return nil,
				fmt.aprintf("room '%s': exactly the entrance rooms need one player spawn 'P'", room.name, allocator = allocator),
				false
		}
		if kind == .Encounter && len(first.enemy_spawns) == 0 {
			return nil, fmt.aprintf("encounter room '%s' has no enemy spawn 'E'", room.name, allocator = allocator), false
		}
	}

	for i in 0 ..< cfg.hallways.count {
		length := rng_range(rng, cfg.hallways.min_length, cfg.hallways.max_length)
		rows := hallway_rows(length, cfg.hallways.side_door_chance, rng, allocator)
		proto := Template {
			name   = fmt.aprintf("hallway_%d", i, allocator = allocator),
			kind   = .Hallway,
			weight = max(cfg.hallways.weight, 0.001) / f32(cfg.hallways.count),
			floor  = cfg.hallways.floor,
			base   = len(cfg.rooms) + i,
		}
		if _, aerr, aok := add_rotations(&out, proto, rows, rotations, cfg.decor, allocator); !aok {
			return nil, aerr, false
		}
	}
	return out[:], "", true
}

// Number of distinct `Template.base` values build_templates produces.
template_base_count :: proc(cfg: ^Config) -> int {
	return len(cfg.rooms) + cfg.hallways.count
}
