package dungeon

import "core:math"

// Knight mode: a player walking the dungeon on foot. Like the generator this
// is pure simulation; the game feeds it a direction and draws the result.

// Collision shapes, as fractions of a tile. They follow the Dungeon Pack
// models: walls are a quarter tile thick and a doorway is half a tile wide.
WALL_HALF_THICKNESS :: 0.125
DOOR_HALF_OPENING :: 0.25
PROP_HALF_SIZE :: 0.2 // decor and chests

// Before this fraction of a swing is over the knight is rooted to the spot.
SWING_ROOTED :: 1.0

ACTOR_FLOOR_Y :: 0.05 // top of a floor tile

Play :: struct {
	pos:            [2]f32, // world X and Z
	facing:         f32, // radians; 0 faces north (-Z), positive turns towards east (+X)
	moving:         bool,
	has_key:        []bool, // per lock id
	has_sword:      bool,
	has_amulet:     bool,
	celebrate_left: f32, // seconds of celebrating still to go before the win
	celebrated:     f32, // seconds spent celebrating so far
	won:            bool, // the amulet is found and celebrated; the simulation stops there
	time:           f32, // seconds played, until the game is won or lost
	swing_left:     f32, // seconds of the current sword swing still to play, 0 when idle
	swing_total:    f32,
	slot_taken:     []bool, // per item slot: its chest is open, or it was picked off the floor
	slots_taken:    int, // chests opened plus items picked off the floor
	items_found:    int,
	last_found:     Item_Kind, // what the most recent chest or pickup gave
	last_found_key: int,
	conn_open:      []bool, // per connection: its door stands open
	room_seen:      []bool,
	solid:          []bool, // per cell: a prop stands on this floor cell
	keys_held:      int,
	doors_unlocked: int,
	rooms_seen:     int,
	blocked_by:     int, // lock id of a locked door within reach this update, else -1
	version:        int, // bumped whenever doors or keys change, i.e. tiles are stale
	health:         int,
	max_health:     int,
	hurt_left:      f32, // seconds of grace left after the last blow taken
	hurt_time:      f32, // seconds since the last blow taken, for the flinch
	dead:           bool,
	dead_time:      f32, // seconds since death
	swing_landed:   bool, // this swing's blade has already passed through
	kills:          int,
	enemies:        []Enemy,
	path:           []i32, // per cell: walking distance to the knight in cells, -1 where unreachable
	sound_events:   [MAX_SOUND_EVENTS]Sound_Event, // see sounds.odin
	sound_count:    int,
	stride:         f32, // distance walked since the last footfall
	was_blocked_by: int, // blocked_by of the previous update, so a locked door rattles once
	explored:       bool, // Dungeon_Explored has been raised
}

Box :: struct {
	min, max: [2]f32,
}

// Puts the player on the entrance's spawn point with empty hands.
play_start :: proc(d: ^Dungeon, cfg: ^Config, allocator := context.allocator) -> Play {
	p := Play {
		has_key    = make([]bool, d.lock_count, allocator),
		slot_taken = make([]bool, len(d.item_slots), allocator),
		conn_open  = make([]bool, len(d.conns), allocator),
		room_seen  = make([]bool, len(d.rooms), allocator),
		solid      = make([]bool, d.w * d.h, allocator),
		path       = make([]i32, d.w * d.h, allocator),
		blocked_by = -1,
		was_blocked_by = -1,
		health     = cfg.play.health,
		max_health = cfg.play.health,
		hurt_time  = 1e6,
	}
	if len(d.rooms) == 0 {
		return p
	}
	spawn := cell_world(cfg, d.player_spawn)
	p.pos = {spawn.x, spawn.z}
	p.room_seen[0] = true
	p.rooms_seen = 1
	for room in d.rooms {
		for decor in d.templates[room.template].decor {
			pos := room.pos + decor.pos
			p.solid[pos.y * d.w + pos.x] = true
		}
	}
	for slot in d.item_slots {
		// A chest is in the way; an item on the floor is not.
		if slot.chest {
			p.solid[slot.pos.y * d.w + slot.pos.x] = true
		}
	}
	p.last_found_key = -1
	enemies_spawn(&p, d, cfg, allocator)
	return p
}

// Every item is in hand and every room has been walked into.
play_complete :: proc(p: ^Play, d: ^Dungeon) -> bool {
	for slot, i in d.item_slots {
		if slot.item != .None && !p.slot_taken[i] {
			return false
		}
	}
	return p.rooms_seen == len(d.rooms)
}

// Whether the knight has just found the amulet and is celebrating, the win
// still to come.
play_celebrating :: proc(p: ^Play) -> bool {
	return p.has_amulet && !p.won
}

// Starts a sword swing lasting `duration` seconds. Needs the sword, and the
// previous swing to be over.
play_swing :: proc(p: ^Play, duration: f32) -> bool {
	if !p.has_sword || p.dead || p.has_amulet || p.swing_left > 0 || duration <= 0 {
		return false
	}
	p.swing_left = duration
	p.swing_total = duration
	p.swing_landed = false
	sound_emit(p, .Sword_Swing, p.pos)
	return true
}

// Grid cell a world position falls into. Cells are centred on multiples of tile_size.
world_cell :: proc(cfg: ^Config, pos: [2]f32) -> [2]int {
	return {int(math.floor(pos.x / cfg.tile_size + 0.5)), int(math.floor(pos.y / cfg.tile_size + 0.5))}
}

// Appends the solid boxes of one cell.
cell_blockers :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, cell: [2]int, boxes: ^[dynamic]Box) {
	t := cfg.tile_size
	half := t / 2
	c := [2]f32{f32(cell.x), f32(cell.y)} * t
	if !in_bounds(d, cell) {
		append(boxes, Box{c - half, c + half})
		return
	}
	info := cell_at(d, cell)
	w := t * WALL_HALF_THICKNESS
	switch info.kind {
	case .Empty:
		append(boxes, Box{c - half, c + half})
	case .Floor, .Open:
		if p.solid[cell.y * d.w + cell.x] {
			size := t * PROP_HALF_SIZE
			append(boxes, Box{c - size, c + size})
		}
	case .Wall:
		// A post in the middle and one bar per arm out to the cell edge.
		append(boxes, Box{c - w, c + w})
		for dir in Dir {
			if dir not_in info.arms {
				continue
			}
			box := Box{c - w, c + w}
			switch dir {
			case .N:
				box.min.y = c.y - half
			case .E:
				box.max.x = c.x + half
			case .S:
				box.max.y = c.y + half
			case .W:
				box.min.x = c.x - half
			}
			append(boxes, box)
		}
	case .Door:
		axis := .E in info.arms || .W in info.arms ? 0 : 1
		slab :: proc(c: [2]f32, axis: int, from, to, w: f32) -> Box {
			box := Box{c - w, c + w}
			box.min[axis] = c[axis] + from
			box.max[axis] = c[axis] + to
			return box
		}
		if info.conn >= 0 && p.conn_open[info.conn] {
			gap := t * DOOR_HALF_OPENING
			append(boxes, slab(c, axis, -half, -gap, w))
			append(boxes, slab(c, axis, gap, half, w))
		} else {
			append(boxes, slab(c, axis, -half, half, w))
		}
	}
}

// Pushes the player's circle out of everything solid around it.
@(private)
play_resolve :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config) {
	resolve_circle(p, d, cfg, &p.pos, cfg.play.radius)
}

// Pushes a circle out of the walls, doors and props around it.
resolve_circle :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, pos: ^[2]f32, r: f32) {
	boxes := make([dynamic]Box, context.temp_allocator)
	at := pos^
	centre := world_cell(cfg, at)
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			cell_blockers(p, d, cfg, centre + {dx, dy}, &boxes)
		}
	}
	for _ in 0 ..< 4 {
		moved := false
		for box in boxes {
			nearest := [2]f32{clamp(at.x, box.min.x, box.max.x), clamp(at.y, box.min.y, box.max.y)}
			diff := at - nearest
			dist2 := diff.x * diff.x + diff.y * diff.y
			if dist2 >= r * r {
				continue
			}
			moved = true
			if dist2 > 1e-10 {
				at = nearest + diff * (r / math.sqrt(dist2))
				continue
			}
			// Centre inside the box: leave through the nearest face.
			exits := [4]f32{at.x - box.min.x, box.max.x - at.x, at.y - box.min.y, box.max.y - at.y}
			best := 0
			for e, i in exits {
				if e < exits[best] {
					best = i
				}
			}
			switch best {
			case 0:
				at.x = box.min.x - r
			case 1:
				at.x = box.max.x + r
			case 2:
				at.y = box.min.y - r
			case 3:
				at.y = box.max.y + r
			}
		}
		if !moved {
			break
		}
	}
	pos^ = at
}
// Opens chests, picks up items and opens doors within reach.
@(private)
play_interact :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config) {
	within :: proc(p: ^Play, cfg: ^Config, cell: [2]int) -> bool {
		c := cell_world(cfg, cell)
		dx, dz := p.pos.x - c.x, p.pos.y - c.z
		return dx * dx + dz * dz < cfg.play.interact_radius * cfg.play.interact_radius
	}
	// Reaching a chest opens it and hands over whatever is inside; an empty
	// chest opens too. Items on the floor are simply picked up.
	for slot, i in d.item_slots {
		if p.slot_taken[i] || (!slot.chest && slot.item == .None) || !within(p, cfg, slot.pos) {
			continue
		}
		p.slot_taken[i] = true
		p.slots_taken += 1
		p.version += 1
		p.last_found = slot.item
		p.last_found_key = slot.key
		at := cell_world(cfg, slot.pos)
		if slot.chest {
			sound_emit(p, .Chest_Open, {at.x, at.z})
		}
		switch slot.item {
		case .Key:
			p.has_key[slot.key] = true
			p.keys_held += 1
			p.items_found += 1
			sound_emit(p, .Key_Pickup, p.pos)
		case .Sword:
			p.has_sword = true
			p.items_found += 1
			sound_emit(p, .Sword_Pickup, p.pos)
		case .Amulet:
			// The knight celebrates first; the win follows when that is done.
			p.has_amulet = true
			p.items_found += 1
			sound_emit(p, .Amulet_Pickup, p.pos)
			p.celebrate_left = cfg.play.celebrate_time
			if p.celebrate_left <= 0 {
				p.won = true
				sound_emit(p, .Game_Won, p.pos)
			}
		case .None:
		}
	}
	for conn, i in d.conns {
		if conn.kind != .Door || p.conn_open[i] || !within(p, cfg, conn.pos) {
			continue
		}
		if conn.locked && !p.has_key[conn.lock_id] {
			p.blocked_by = conn.lock_id
			continue
		}
		p.conn_open[i] = true
		p.doors_unlocked += int(conn.locked)
		p.version += 1
		at := cell_world(cfg, conn.pos)
		sound_emit(p, .Door_Open, {at.x, at.z})
	}
}

// Advances the player by dt seconds. `move` is the wanted direction on the
// ground in world X/Z; its length (capped at 1) scales the speed.
play_update :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, move: [2]f32, dt: f32) {
	if len(d.rooms) == 0 {
		return
	}
	// Won: the story is over and nothing moves any more.
	if p.won {
		p.moving = false
		p.swing_left = 0
		p.blocked_by = -1
		return
	}
	// The amulet is in hand: the knight stands and celebrates while the rest
	// of the dungeon holds still, and then the game is won.
	if p.has_amulet {
		p.moving = false
		p.swing_left = 0
		p.blocked_by = -1
		p.celebrated += dt
		p.celebrate_left -= dt
		if p.celebrate_left <= 0 {
			p.celebrate_left = 0
			p.won = true
			sound_emit(p, .Game_Won, p.pos)
		}
		return
	}
	move := move
	p.hurt_left = max(0, p.hurt_left - dt)
	p.hurt_time += dt
	if !p.dead {
		p.time += dt
	}
	if p.dead {
		// Nothing more to do but lie there; the skeletons lose interest.
		p.dead_time += dt
		p.moving = false
		p.swing_left = 0
		p.blocked_by = -1
		p.was_blocked_by = -1
		enemies_update(p, d, cfg, dt)
		return
	}
	before := p.pos
	if p.swing_left > 0 {
		// Feet planted for the swing.
		if p.swing_left > p.swing_total * (1 - SWING_ROOTED) {
			move = {}
		}
		p.swing_left = max(0, p.swing_left - dt)
	}
	length := math.sqrt(move.x * move.x + move.y * move.y)
	if length > 1 {
		move /= length
	}
	p.moving = length > 0.05
	p.blocked_by = -1

	if p.moving {
		// Turn towards the heading by the shorter way round.
		diff := math.atan2(move.x, -move.y) - p.facing
		diff -= math.TAU * math.round(diff / math.TAU)
		step := cfg.play.turn_speed * dt
		p.facing += clamp(diff, -step, step)
		p.facing -= math.TAU * math.round(p.facing / math.TAU)
	}

	// Doors swing open on approach, before the player runs into them.
	play_interact(p, d, cfg)

	if p.moving {
		delta := move * (cfg.play.speed * dt)
		travel := math.sqrt(delta.x * delta.x + delta.y * delta.y)
		// Short hops, so nothing thin can be skipped over on a slow frame.
		steps := max(1, int(math.ceil(travel / (cfg.play.radius * 0.5))))
		for _ in 0 ..< steps {
			p.pos += delta / f32(steps)
			// Skeletons are in the way too, but walls have the last word.
			for e in p.enemies {
				if e.state != .Dead {
					push_apart(&p.pos, e.pos, cfg.play.radius + cfg.enemies.radius)
				}
			}
			play_resolve(p, d, cfg)
		}
		play_interact(p, d, cfg)
	}

	// Footfalls follow the ground actually covered, so running into a wall is silent.
	sound_steps(p, .Knight_Step, &p.stride, before, p.pos, cfg.sounds.knight_stride)
	// A locked door rattles when first tried, not for as long as the knight leans on it.
	if p.blocked_by >= 0 && p.blocked_by != p.was_blocked_by {
		sound_emit(p, .Door_Locked, p.pos)
	}
	p.was_blocked_by = p.blocked_by
	if !p.explored && play_complete(p, d) {
		p.explored = true
		sound_emit(p, .Dungeon_Explored, p.pos)
	}

	sword_update(p, d, cfg)
	enemies_update(p, d, cfg, dt)

	cell := world_cell(cfg, p.pos)
	if in_bounds(d, cell) {
		info := cell_at(d, cell)
		if info.kind == .Floor && !p.room_seen[info.room] {
			p.room_seen[info.room] = true
			p.rooms_seen += 1
		}
	}
}

// World matrix for the player's model.
actor_matrix :: proc(p: ^Play) -> matrix[4, 4]f32 {
	return facing_matrix(p.pos, p.facing)
}

// World matrix for a character standing at `pos` and facing `facing`. The
// KayKit characters face +Z at rest.
facing_matrix :: proc(pos: [2]f32, facing: f32) -> matrix[4, 4]f32 {
	angle := math.PI - facing
	c, s := math.cos(angle), math.sin(angle)
	return matrix[4, 4]f32{
		c, 0, s, pos.x,
		0, 1, 0, ACTOR_FLOOR_Y,
		-s, 0, c, pos.y,
		0, 0, 0, 1,
	}
}
