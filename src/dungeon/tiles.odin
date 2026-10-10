package dungeon

import "core:math"

// One model instance for the renderer. Positions are world units with the
// grid on the XZ plane: cell (x, y) is centred on (x, 0, y) * tile_size.
Tile :: struct {
	model: string,
	pos:   [3]f32,
	turns: int, // quarter turns about +Y; one turn swings +X (east) round to -Z (north)
	tilt:  f32, // radians about the model's own X axis, applied before the turn
	scale: f32,
	tint:  [3]f32,
}

Wall_Piece :: enum {
	Straight, // runs east-west at 0 turns
	Corner, // arms west and south at 0 turns
	Tsplit, // arms west, east and south at 0 turns
	Crossing,
}

// Picks the model and rotation for a wall cell from the directions it has to
// continue in. A turn moves every arm one step anticlockwise: E -> N -> W -> S.
wall_piece :: proc(arms: Dirs) -> (piece: Wall_Piece, turns: int) {
	switch card(arms) {
	case 4:
		return .Crossing, 0
	case 3:
		for d in Dir {
			if d not_in arms {
				return .Tsplit, (4 - int(d)) % 4
			}
		}
	case 2:
		if arms == {.E, .W} do return .Straight, 0
		if arms == {.N, .S} do return .Straight, 1
		for k in 0 ..< 4 {
			if arms == {Dir((3 + 4 - k) % 4), Dir((2 + 4 - k) % 4)} {
				return .Corner, k
			}
		}
	}
	return .Straight, .N in arms || .S in arms ? 1 : 0
}

LOCK_COLORS := [?][3]f32 {
	{1.00, 0.25, 0.25},
	{0.30, 0.55, 1.00},
	{0.35, 0.95, 0.40},
	{1.00, 0.85, 0.20},
	{0.85, 0.35, 1.00},
	{0.25, 0.95, 0.95},
	{1.00, 0.55, 0.15},
	{1.00, 0.45, 0.75},
}

lock_color :: proc(lock_id: int) -> [3]f32 {
	return LOCK_COLORS[lock_id %% len(LOCK_COLORS)]
}

cell_world :: proc(cfg: ^Config, pos: [2]int, y: f32 = 0) -> [3]f32 {
	return {f32(pos.x) * cfg.tile_size, y, f32(pos.y) * cfg.tile_size}
}

// Flattens the dungeon into the list of models to draw. With a play state,
// doors and chests the player opened stand open and collected items are gone.
// `reveal` adds what a player on foot must not see: the contents of closed
// chests, spawn points and empty item spots.
build_tiles :: proc(d: ^Dungeon, cfg: ^Config, allocator := context.allocator, play: ^Play = nil, reveal := true) -> []Tile {
	tiles := make([dynamic]Tile, allocator)
	WHITE :: [3]f32{1, 1, 1}

	pick :: proc(d: ^Dungeon, models: []string, pos: [2]int, salt: u64) -> string {
		return models[hash_cell(d.seed, pos.x, pos.y, salt) % u64(len(models))]
	}
	add_marker :: proc(tiles: ^[dynamic]Tile, cfg: ^Config, m: Marker, pos: [2]int, tint: [3]f32) {
		if m.model == "" {
			return
		}
		append(tiles, Tile{model = m.model, pos = cell_world(cfg, pos, m.y), scale = m.scale, tint = tint})
	}

	for y in 0 ..< d.h {
		for x in 0 ..< d.w {
			pos := [2]int{x, y}
			cell := cell_at(d, pos)
			if cell.kind == .Empty {
				continue
			}
			floor := cfg.floors[room_template(d, int(cell.room)).floor]
			append(&tiles, Tile{model = pick(d, floor, pos, 1), pos = cell_world(cfg, pos), scale = 1, tint = WHITE})

			#partial switch cell.kind {
			case .Wall:
				piece, turns := wall_piece(cell.arms)
				model: string
				switch piece {
				case .Straight:
					model = pick(d, cfg.tiles.wall, pos, 2)
				case .Corner:
					model = cfg.tiles.corner
				case .Tsplit:
					model = cfg.tiles.tsplit
				case .Crossing:
					model = cfg.tiles.crossing
				}
				append(&tiles, Tile{model = model, pos = cell_world(cfg, pos), turns = turns, scale = 1, tint = WHITE})
			case .Door:
				_, turns := wall_piece(cell.arms)
				tint := WHITE
				open := false
				if cell.conn >= 0 {
					conn := d.conns[cell.conn]
					open = play != nil && play.conn_open[cell.conn]
					if conn.locked && !open {
						tint = lock_color(conn.lock_id)
					}
				}
				frame := Tile{model = cfg.tiles.doorway, pos = cell_world(cfg, pos), turns = turns, scale = 1, tint = tint}
				append(&tiles, frame)
				// The leaf hangs on its hinge and swings a quarter turn when open.
				hinge := cfg.tiles.door_hinge
				at := tile_matrix(frame) * [4]f32{hinge.x, hinge.y, hinge.z, 1}
				append(&tiles, Tile{model = cfg.tiles.door, pos = at.xyz, turns = turns + int(open), scale = 1, tint = tint})
			}
		}
	}
	for room in d.rooms {
		for decor in d.templates[room.template].decor {
			pos := room.pos + decor.pos
			append(
				&tiles,
				Tile {
					model = pick(d, cfg.decor[decor.key], pos, 3),
					pos = cell_world(cfg, pos),
					turns = int(hash_cell(d.seed, pos.x, pos.y, 4) % 4),
					scale = 1,
					tint = WHITE,
				},
			)
		}
	}

	if reveal {
		if len(d.rooms) > 0 {
			add_marker(&tiles, cfg, cfg.markers.player_spawn, d.player_spawn, cfg.markers.player_spawn.tint)
		}
		for spawn in d.enemy_spawns {
			add_marker(&tiles, cfg, cfg.markers.enemy_spawn, spawn.pos, cfg.markers.enemy_spawn.tint)
		}
	}

	item_tile :: proc(cfg: ^Config, slot: Item_Slot) -> (tile: Tile, ok: bool) {
		visual: Item_Visual
		switch slot.item {
		case .None:
			return {}, false
		case .Key:
			visual = cfg.items.key
			visual.tint = lock_color(slot.key)
		case .Sword:
			visual = cfg.items.sword
		case .Amulet:
			visual = cfg.items.amulet
		}
		return {model = visual.model, pos = cell_world(cfg, slot.pos), scale = visual.scale, tint = visual.tint}, visual.model != ""
	}

	for slot, i in d.item_slots {
		taken := play != nil && play.slot_taken[i]
		item, has_item := item_tile(cfg, slot)
		visual := item_visual(cfg, slot.item)

		if !slot.chest {
			switch {
			case has_item && !taken:
				// Lying flat on the floor, at whatever angle it fell.
				item.pos.y = visual.ground_y
				item.tilt = math.to_radians(visual.ground_tilt)
				item.turns = int(hash_cell(d.seed, slot.pos.x, slot.pos.y, 5) % 4)
				append(&tiles, item)
			case slot.item == .None && reveal:
				add_marker(&tiles, cfg, cfg.markers.ground_slot, slot.pos, cfg.markers.ground_slot.tint)
			}
			continue
		}

		body := Tile {
			model = cfg.props.chest,
			pos   = cell_world(cfg, slot.pos),
			turns = chest_turns(d, slot),
			scale = 1,
			tint  = WHITE,
		}
		append(&tiles, body)
		hinge := cfg.props.chest_hinge
		at := tile_matrix(body) * [4]f32{hinge.x, hinge.y, hinge.z, 1}
		append(
			&tiles,
			Tile {
				model = cfg.props.chest_lid,
				pos = at.xyz,
				turns = body.turns,
				// The lid reaches forward (+Z) from its hinge; a negative tilt lifts it.
				tilt = taken ? -math.to_radians(cfg.props.chest_open_angle) : 0,
				scale = 1,
				tint = WHITE,
			},
		)
		if has_item && !taken && reveal {
			item.pos.y = visual.reveal_y
			append(&tiles, item)
		}
	}
	// Found, the amulet is lifted up over the knight's head and stays there.
	if play != nil && play.has_amulet && cfg.items.amulet.model != "" {
		visual := cfg.items.amulet
		append(
			&tiles,
			Tile {
				model = visual.model,
				pos = {play.pos.x, amulet_height(play.celebrated), play.pos.y},
				scale = visual.scale,
				tint = visual.tint,
			},
		)
	}
	return tiles[:]
}

AMULET_LIFT_TIME :: 0.9 // seconds the amulet takes to rise
AMULET_LIFT_FROM :: 1.0 // world units above the floor: about the knight's hands
AMULET_LIFT_TO :: 3.4 // clear of the helmet

// How high the found amulet floats `seconds` into the celebration: it rises
// quickly at first and settles above the knight's head.
amulet_height :: proc(seconds: f32) -> f32 {
	t := clamp(seconds / AMULET_LIFT_TIME, 0, 1)
	eased := 1 - (1 - t) * (1 - t)
	return AMULET_LIFT_FROM + (AMULET_LIFT_TO - AMULET_LIFT_FROM) * eased
}

// How an item of a kind is drawn. Keys are the default.
item_visual :: proc(cfg: ^Config, item: Item_Kind) -> Item_Visual {
	#partial switch item {
	case .Sword:
		return cfg.items.sword
	case .Amulet:
		return cfg.items.amulet
	}
	return cfg.items.key
}

// Quarter turns that point a chest's front (+Z at rest) at the middle of its
// room, so it never opens towards a wall.
chest_turns :: proc(d: ^Dungeon, slot: Item_Slot) -> int {
	room := d.rooms[slot.room]
	t := d.templates[room.template]
	// Doubled to stay in whole numbers.
	to_centre := room.pos * 2 + {t.w - 1, t.h - 1} - slot.pos * 2
	if abs(to_centre.x) > abs(to_centre.y) {
		return to_centre.x > 0 ? 1 : 3 // east : west
	}
	return to_centre.y >= 0 ? 0 : 2 // south : north
}
// Model matrix for a tile: scale, tilt about X, turn about +Y, then translate.
tile_matrix :: proc(t: Tile) -> matrix[4, 4]f32 {
	angle := f32(t.turns) * math.PI / 2
	c, s := math.cos(angle), math.sin(angle)
	ct, st := math.cos(t.tilt), math.sin(t.tilt)
	k := t.scale
	// turn * tilt, written out.
	return matrix[4, 4]f32{
		c * k, s * st * k, s * ct * k, t.pos.x,
		0, ct * k, -st * k, t.pos.y,
		-s * k, c * st * k, c * ct * k, t.pos.z,
		0, 0, 0, 1,
	}
}