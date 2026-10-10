package dungeon

Cell_Kind :: enum u8 {
	Empty,
	Floor,
	Wall,
	Door,
	Open, // floor where two rooms dropped their walls and merged
}

// Walls, doors and openings live in their own cells on a room's perimeter.
// Neighbouring rooms overlap by that one-cell ring, so a wall cell can belong
// to several rooms and `arms` is the union of what each of them needs.
Cell :: struct {
	kind: Cell_Kind,
	arms: Dirs,
	room: i32, // first room that claimed the cell, -1 when empty
	conn: i32, // connection running through a Door/Open cell, -1 otherwise
}

Room :: struct {
	template:   int, // index into Dungeon.templates
	kind:       Room_Kind,
	pos:        [2]int, // grid cell of the template's top-left corner
	parent:     int, // -1 for the entrance
	entry_conn: int, // connection leading back towards the entrance, -1 for the entrance
	depth:      int, // rooms between this one and the entrance
	node_conn:  []int, // per template node: its connection, or -1 when it was sealed
}

// An edge of the room tree. Rooms are numbered in the order they were
// generated, so `to` is always greater than `from`.
Connection :: struct {
	kind:      Node_Kind,
	from, to:  int,
	from_node: int,
	to_node:   int,
	pos:       [2]int, // first shared cell
	dir:       Dir, // from `from` into `to`
	width:     int,
	locked:    bool,
	lock_id:   int, // -1 when unlocked
}

Item_Kind :: enum u8 {
	None,
	Key,
	Sword,
	Amulet, // the goal: picking it up wins the game
}

Item_Slot :: struct {
	room:  int,
	pos:   [2]int,
	chest: bool, // the item is shut in a chest rather than lying on the floor
	item:  Item_Kind,
	key:   int, // lock_id when item is .Key, otherwise -1
}

Enemy_Spawn :: struct {
	room: int,
	pos:  [2]int,
}

Dungeon :: struct {
	seed:         u64,
	attempt:      int, // which retry of `seed` produced this layout
	w, h:         int,
	cells:        []Cell,
	templates:    []Template,
	rooms:        [dynamic]Room, // rooms[0] is the entrance
	conns:        [dynamic]Connection,
	item_slots:   [dynamic]Item_Slot,
	enemy_spawns: [dynamic]Enemy_Spawn,
	player_spawn: [2]int,
	lock_count:   int,
	base_counts:  []int, // rooms placed per Template.base
}

cell_at :: proc(d: ^Dungeon, pos: [2]int) -> ^Cell {
	return &d.cells[pos.y * d.w + pos.x]
}

in_bounds :: proc(d: ^Dungeon, pos: [2]int) -> bool {
	return pos.x >= 0 && pos.y >= 0 && pos.x < d.w && pos.y < d.h
}

room_template :: proc(d: ^Dungeon, room: int) -> ^Template {
	return &d.templates[d.rooms[room].template]
}

// Generates a dungeon from the entrance outwards. Everything is allocated
// from `allocator` and nothing is freed individually; hand in an arena.
generate :: proc(cfg: ^Config, seed: u64, allocator := context.allocator) -> (d: ^Dungeon, err: string, ok: bool) {
	for attempt in 0 ..< max(cfg.generation.max_attempts, 1) {
		candidate, gerr, gok := generate_once(cfg, seed, attempt, allocator)
		if !gok {
			return nil, gerr, false
		}
		if d == nil || len(candidate.rooms) > len(d.rooms) {
			d = candidate
		}
		if len(d.rooms) >= min(cfg.generation.min_rooms, cfg.generation.max_rooms) {
			break
		}
	}
	return d, "", true
}

@(private)
Frontier :: struct {
	room: int,
	node: int,
}

generate_once :: proc(
	cfg: ^Config,
	seed: u64,
	attempt: int,
	allocator := context.allocator,
) -> (
	d: ^Dungeon,
	err: string,
	ok: bool,
) {
	rng := rng_make(seed + u64(attempt) * 0x9E3779B97F4A7C15)

	d = new(Dungeon, allocator)
	d.seed = seed
	d.attempt = attempt
	d.w = cfg.size.width
	d.h = cfg.size.height
	d.cells = make([]Cell, d.w * d.h, allocator)
	for &c in d.cells {
		c.room = -1
		c.conn = -1
	}
	d.rooms = make([dynamic]Room, allocator)
	d.conns = make([dynamic]Connection, allocator)
	d.item_slots = make([dynamic]Item_Slot, allocator)
	d.enemy_spawns = make([dynamic]Enemy_Spawn, allocator)
	d.base_counts = make([]int, template_base_count(cfg), allocator)
	d.templates, err, ok = build_templates(cfg, &rng, allocator)
	if !ok {
		return nil, err, false
	}

	// The entrance is the seed point: everything else grows out of its nodes.
	entrances := make([dynamic]int, context.temp_allocator)
	for t, i in d.templates {
		if t.kind == .Entrance && t.w <= d.w && t.h <= d.h {
			append(&entrances, i)
		}
	}
	if len(entrances) == 0 {
		return nil, "no entrance room fits inside the dungeon", false
	}
	entrance := entrances[rng_int(&rng, len(entrances))]
	et := &d.templates[entrance]
	epos := [2]int {
		clamp(int(cfg.generation.entrance_position.x * f32(d.w)) - et.w / 2, 0, d.w - et.w),
		clamp(int(cfg.generation.entrance_position.y * f32(d.h)) - et.h / 2, 0, d.h - et.h),
	}
	frontier := make([dynamic]Frontier, context.temp_allocator)
	place_room(d, entrance, epos, -1, &frontier, allocator)

	for len(frontier) > 0 && len(d.rooms) < cfg.generation.max_rooms {
		pick := len(frontier) - 1
		if !rng_chance(&rng, cfg.generation.depth_bias) {
			pick = rng_int(&rng, len(frontier))
		}
		f := frontier[pick]
		ordered_remove(&frontier, pick)
		try_attach(d, cfg, &rng, f, &frontier, allocator)
	}

	if cfg.hallways.prune_dead_ends {
		d = prune_dead_ends(d, allocator)
	}
	seal_open_nodes(d)
	assign_amulet(d, cfg, &rng)
	assign_swords(d, cfg, &rng)
	assign_locks(d, cfg, &rng)
	return d, "", true
}

@(private)
count_compatible :: proc(t: ^Template, kind: Node_Kind, dir: Dir, width: int) -> (count: int) {
	for n in t.nodes {
		if n.kind == kind && n.dir == dir && n.width == width {
			count += 1
		}
	}
	return
}

// Tries to hang a new room off one open node. The new room is positioned so
// that its matching node lands on the very same cells as the parent's.
@(private)
try_attach :: proc(
	d: ^Dungeon,
	cfg: ^Config,
	rng: ^Rng,
	f: Frontier,
	frontier: ^[dynamic]Frontier,
	allocator := context.allocator,
) -> bool {
	parent_node := room_template(d, f.room).nodes[f.node]
	node_pos := d.rooms[f.room].pos + parent_node.pos
	want_dir := dir_opposite(parent_node.dir)

	// Hallways leading straight into more hallways are toned down by chain_weight.
	weight_of :: proc(t: ^Template, parent_kind: Room_Kind, cfg: ^Config) -> f32 {
		if t.kind == .Hallway && parent_kind == .Hallway {
			return t.weight * cfg.hallways.chain_weight
		}
		return t.weight
	}
	parent_kind := d.rooms[f.room].kind

	candidates := make([dynamic]int, context.temp_allocator)
	total: f32
	for &t, i in d.templates {
		if t.kind == .Entrance {
			continue
		}
		if t.max_count > 0 && d.base_counts[t.base] >= t.max_count {
			continue
		}
		if count_compatible(&t, parent_node.kind, want_dir, parent_node.width) == 0 {
			continue
		}
		weight := weight_of(&t, parent_kind, cfg)
		if weight <= 0 {
			continue
		}
		append(&candidates, i)
		total += weight
	}
	if len(candidates) == 0 {
		return false
	}

	for _ in 0 ..< cfg.generation.attempts_per_node {
		ti := candidates[len(candidates) - 1]
		roll := rng_float(rng) * total
		for c in candidates {
			roll -= weight_of(&d.templates[c], parent_kind, cfg)
			if roll < 0 {
				ti = c
				break
			}
		}
		t := &d.templates[ti]

		skip := rng_int(rng, count_compatible(t, parent_node.kind, want_dir, parent_node.width))
		ni := -1
		for n, i in t.nodes {
			if n.kind != parent_node.kind || n.dir != want_dir || n.width != parent_node.width {
				continue
			}
			if skip == 0 {
				ni = i
				break
			}
			skip -= 1
		}

		pos := node_pos - t.nodes[ni].pos
		if !can_place(d, t, pos, node_pos, parent_node, cfg.generation.allow_adjacent_walls) {
			continue
		}

		room := place_room(d, ti, pos, f.room, frontier, allocator, skip_node = ni)
		connect_rooms(d, f.room, f.node, room, ni)
		return true
	}
	return false
}

// Records the tree edge between a room's node and the matching node of the
// room just placed on top of it.
@(private)
connect_rooms :: proc(d: ^Dungeon, from, from_node, to, to_node: int) {
	node := room_template(d, from).nodes[from_node]
	node_pos := d.rooms[from].pos + node.pos
	conn := len(d.conns)
	append(
		&d.conns,
		Connection {
			kind = node.kind,
			from = from,
			to = to,
			from_node = from_node,
			to_node = to_node,
			pos = node_pos,
			dir = node.dir,
			width = node.width,
			lock_id = -1,
		},
	)
	d.rooms[from].node_conn[from_node] = conn
	d.rooms[to].node_conn[to_node] = conn
	d.rooms[to].entry_conn = conn
	axis := node_axis(node.dir)
	for i in 0 ..< node.width {
		cell_at(d, node_pos + axis * i).conn = i32(conn)
	}
}

// Drops hallways that ended up leading nowhere. Children always have a higher
// index than their parent, so one pass from the back catches whole dead
// chains. The survivors are replayed into a fresh dungeon, which keeps room
// numbers dense and in generation order.
@(private)
prune_dead_ends :: proc(d: ^Dungeon, allocator := context.allocator) -> ^Dungeon {
	children := make([]int, len(d.rooms), context.temp_allocator)
	for conn in d.conns {
		children[conn.from] += 1
	}
	remap := make([]int, len(d.rooms), context.temp_allocator)
	removed := 0
	#reverse for room, i in d.rooms {
		if i > 0 && room.kind == .Hallway && children[i] == 0 {
			remap[i] = -1
			children[room.parent] -= 1
			removed += 1
		}
	}
	if removed == 0 {
		return d
	}

	out := new(Dungeon, allocator)
	out.seed = d.seed
	out.attempt = d.attempt
	out.w = d.w
	out.h = d.h
	out.templates = d.templates
	out.cells = make([]Cell, d.w * d.h, allocator)
	for &c in out.cells {
		c.room = -1
		c.conn = -1
	}
	out.rooms = make([dynamic]Room, allocator)
	out.conns = make([dynamic]Connection, allocator)
	out.item_slots = make([dynamic]Item_Slot, allocator)
	out.enemy_spawns = make([dynamic]Enemy_Spawn, allocator)
	out.base_counts = make([]int, len(d.base_counts), allocator)

	unused := make([dynamic]Frontier, context.temp_allocator)
	for room, i in d.rooms {
		if remap[i] < 0 {
			continue
		}
		parent := room.parent >= 0 ? remap[room.parent] : -1
		remap[i] = place_room(out, room.template, room.pos, parent, &unused, allocator)
		if room.entry_conn >= 0 {
			conn := d.conns[room.entry_conn]
			connect_rooms(out, parent, conn.from_node, remap[i], conn.to_node)
		}
	}
	return out
}

// A room fits when its floor lands on empty cells only and its perimeter
// either lands on empty cells or shares plain wall with rooms already there.
// The cells of the node being connected are the one exception.
@(private)
can_place :: proc(d: ^Dungeon, t: ^Template, pos: [2]int, node_pos: [2]int, node: Template_Node, allow_adjacent_walls: bool) -> bool {
	if pos.x < 0 || pos.y < 0 || pos.x + t.w > d.w || pos.y + t.h > d.h {
		return false
	}
	occupied :: proc(d: ^Dungeon, pos: [2]int) -> bool {
		return in_bounds(d, pos) && cell_at(d, pos).kind != .Empty
	}
	axis := node_axis(node.dir)
	for ty in 0 ..< t.h {
		for tx in 0 ..< t.w {
			g := pos + {tx, ty}
			existing := cell_at(d, g)
			tc := t.cells[ty * t.w + tx]
			if existing.kind == .Empty {
				if allow_adjacent_walls || tc == .Floor {
					continue
				}
				// A free perimeter cell must not back onto somebody else's cells.
				if tx == 0 && occupied(d, g + {-1, 0}) do return false
				if tx == t.w - 1 && occupied(d, g + {1, 0}) do return false
				if ty == 0 && occupied(d, g + {0, -1}) do return false
				if ty == t.h - 1 && occupied(d, g + {0, 1}) do return false
				continue
			}
			if tc == .Floor {
				return false
			}
			offset := g - node_pos
			along := offset.x * axis.x + offset.y * axis.y
			if offset == axis * along && along >= 0 && along < node.width {
				continue
			}
			if existing.kind != .Wall || tc != .Wall {
				return false
			}
		}
	}
	return true
}

@(private)
place_room :: proc(
	d: ^Dungeon,
	template: int,
	pos: [2]int,
	parent: int,
	frontier: ^[dynamic]Frontier,
	allocator := context.allocator,
	skip_node := -1,
) -> int {
	t := &d.templates[template]
	index := len(d.rooms)
	room := Room {
		template   = template,
		kind       = t.kind,
		pos        = pos,
		parent     = parent,
		entry_conn = -1,
		depth      = parent >= 0 ? d.rooms[parent].depth + 1 : 0,
		node_conn  = make([]int, len(t.nodes), allocator),
	}
	for &c in room.node_conn {
		c = -1
	}
	append(&d.rooms, room)
	d.base_counts[t.base] += 1

	for ty in 0 ..< t.h {
		for tx in 0 ..< t.w {
			i := ty * t.w + tx
			cell := cell_at(d, pos + {tx, ty})
			if cell.kind == .Empty {
				switch t.cells[i] {
				case .Floor:
					cell.kind = .Floor
				case .Wall:
					cell.kind = .Wall
				case .Door:
					cell.kind = .Door
				case .Open:
					cell.kind = .Open
				}
				cell.room = i32(index)
			}
			cell.arms += t.arms[i]
		}
	}

	if t.has_player_spawn {
		d.player_spawn = pos + t.player_spawn
	}
	for slot in t.item_slots {
		append(&d.item_slots, Item_Slot{room = index, pos = pos + slot.pos, chest = slot.chest, key = -1})
	}
	for p in t.enemy_spawns {
		append(&d.enemy_spawns, Enemy_Spawn{room = index, pos = pos + p})
	}
	for _, ni in t.nodes {
		if ni != skip_node {
			append(frontier, Frontier{room = index, node = ni})
		}
	}
	return index
}

// Nodes nothing attached to become ordinary wall again.
@(private)
seal_open_nodes :: proc(d: ^Dungeon) {
	for room, ri in d.rooms {
		t := &d.templates[room.template]
		for node, ni in t.nodes {
			if d.rooms[ri].node_conn[ni] >= 0 {
				continue
			}
			axis := node_axis(node.dir)
			for i in 0 ..< node.width {
				cell := cell_at(d, room.pos + node.pos + axis * i)
				cell.kind = .Wall
				cell.arms += straight_arms(node.dir)
			}
		}
	}
}

// Hides the amulet as far from the entrance as the dungeon goes: in a free
// item slot of the deepest room that has one. Being an item in a room, it is
// reachable whenever the dungeon is solvable, and the keys placed afterwards
// never share its slot.
assign_amulet :: proc(d: ^Dungeon, cfg: ^Config, rng: ^Rng) {
	if cfg.items.amulet.model == "" {
		return
	}
	deepest := -1
	candidates := 0
	for slot in d.item_slots {
		if slot.item != .None {
			continue
		}
		depth := d.rooms[slot.room].depth
		if depth > deepest {
			deepest = depth
			candidates = 0
		}
		candidates += int(depth == deepest)
	}
	if candidates == 0 {
		return
	}
	pick := rng_int(rng, candidates)
	for &slot in d.item_slots {
		if slot.item != .None || d.rooms[slot.room].depth != deepest {
			continue
		}
		if pick == 0 {
			slot.item = .Amulet
			return
		}
		pick -= 1
	}
}

// Puts the configured number of swords into free item slots, early in the
// dungeon: among the first quarter of the rooms when those have room for one.
assign_swords :: proc(d: ^Dungeon, cfg: ^Config, rng: ^Rng) {
	for _ in 0 ..< cfg.items.swords {
		limit := max(1, len(d.rooms) / 4)
		early, free := 0, 0
		for slot in d.item_slots {
			if slot.item == .None {
				free += 1
				early += int(slot.room < limit)
			}
		}
		if free == 0 {
			return
		}
		if early == 0 {
			limit = len(d.rooms)
			early = free
		}
		pick := rng_int(rng, early)
		for &slot in d.item_slots {
			if slot.item != .None || slot.room >= limit {
				continue
			}
			if pick == 0 {
				slot.item = .Sword
				break
			}
			pick -= 1
		}
	}
}

// Locks doors and drops the matching key into an item slot of a room that was
// generated before the room behind the door. Rooms are numbered in generation
// order and a room's ancestors always have lower numbers, so by induction
// every key can be reached before the door that needs it.
assign_locks :: proc(d: ^Dungeon, cfg: ^Config, rng: ^Rng) {
	for &conn in d.conns {
		if d.lock_count >= cfg.locks.max {
			break
		}
		if conn.kind != .Door || !rng_chance(rng, cfg.locks.chance) {
			continue
		}
		free_slots := 0
		for slot in d.item_slots {
			if slot.item == .None && slot.room < conn.to {
				free_slots += 1
			}
		}
		if free_slots == 0 {
			continue
		}
		pick := rng_int(rng, free_slots)
		for &slot in d.item_slots {
			if slot.item != .None || slot.room >= conn.to {
				continue
			}
			if pick == 0 {
				slot.item = .Key
				slot.key = d.lock_count
				break
			}
			pick -= 1
		}
		conn.locked = true
		conn.lock_id = d.lock_count
		d.lock_count += 1
	}
}
