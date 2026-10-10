package dungeon

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:testing"

STEP :: 1.0 / 30.0

@(private = "file")
World :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	cfg:       Config,
}

// Loads the project config with every door that can be locked, locked.
@(private = "file")
world_init :: proc(t: ^testing.T, w: ^World) -> bool {
	if !testing.expect(t, virtual.arena_init_growing(&w.arena) == nil) {
		return false
	}
	w.allocator = virtual.arena_allocator(&w.arena)
	err: string
	ok: bool
	w.cfg, err, ok = config_load(CONFIG_PATH, w.allocator)
	w.cfg.locks = {chance = 1, max = 1000}
	// These tests are about getting around; the skeletons have their own in
	// combat_test.odin.
	w.cfg.enemies.enabled = false
	// Nor about winning: with the amulet in play the game would end the
	// moment the bot found it. goal_test.odin covers that.
	w.cfg.items.amulet.model = ""
	return testing.expectf(t, ok, "config_load failed: %s", err)
}

@(private = "file")
world_make :: proc(t: ^testing.T, w: ^World, seed: u64) -> (^Dungeon, Play) {
	d, err, ok := generate(&w.cfg, seed, w.allocator)
	testing.expectf(t, ok, "generate(%d) failed: %s", seed, err)
	return d, play_start(d, &w.cfg, w.allocator)
}

// How far the player's circle reaches into the nearest solid box; <= 0 is clear.
@(private = "file")
penetration :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config) -> f32 {
	boxes := make([dynamic]Box, context.temp_allocator)
	centre := world_cell(cfg, p.pos)
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			cell_blockers(p, d, cfg, centre + {dx, dy}, &boxes)
		}
	}
	worst := f32(-1e9)
	for box in boxes {
		nearest := [2]f32{clamp(p.pos.x, box.min.x, box.max.x), clamp(p.pos.y, box.min.y, box.max.y)}
		diff := p.pos - nearest
		worst = max(worst, cfg.play.radius - math.sqrt(diff.x * diff.x + diff.y * diff.y))
	}
	return worst
}

@(private = "file")
cell_centre :: proc(cfg: ^Config, cell: [2]int) -> [2]f32 {
	c := cell_world(cfg, cell)
	return {c.x, c.z}
}

@(test)
player_starts_on_the_spawn_point :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	d, p := world_make(t, &w, 3)

	testing.expect_value(t, world_cell(&w.cfg, p.pos), d.player_spawn)
	testing.expect_value(t, p.pos, cell_centre(&w.cfg, d.player_spawn))
	testing.expect_value(t, p.keys_held, 0)
	testing.expect_value(t, p.rooms_seen, 1)
	testing.expect(t, p.room_seen[0])
	testing.expect_value(t, len(p.has_key), d.lock_count)
	testing.expect_value(t, len(p.conn_open), len(d.conns))
	testing.expect(t, penetration(&p, d, &w.cfg) <= 0, "the spawn point is free of obstacles")
	testing.expect(t, d.lock_count > 0 && !play_complete(&p, d))

	// Standing still changes nothing.
	play_update(&p, d, &w.cfg, {}, STEP)
	testing.expect(t, !p.moving)
	testing.expect_value(t, p.pos, cell_centre(&w.cfg, d.player_spawn))
	testing.expect_value(t, p.version, 0)
}

@(test)
world_cells_are_centred_on_the_grid :: proc(t: ^testing.T) {
	cfg := config_default()
	testing.expect_value(t, world_cell(&cfg, {0, 0}), [2]int{0, 0})
	testing.expect_value(t, world_cell(&cfg, {1.9, -1.9}), [2]int{0, 0})
	testing.expect_value(t, world_cell(&cfg, {2.1, -2.1}), [2]int{1, -1})
	testing.expect_value(t, world_cell(&cfg, {40, 12}), [2]int{10, 3})
}

@(test)
walls_stop_the_player :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	for seed in 1 ..= u64(8) {
		d, _ := world_make(t, &w, seed)
		for heading in 0 ..< 8 {
			p := play_start(d, &w.cfg, w.allocator)
			angle := f32(heading) * math.PI / 4
			move := [2]f32{math.cos(angle), math.sin(angle)}
			for _ in 0 ..< 240 {
				play_update(&p, d, &w.cfg, move, STEP)
				depth := penetration(&p, d, &w.cfg)
				if !testing.expectf(t, depth < 1e-3, "seed %d heading %d: %v deep inside an obstacle at %v", seed, heading, depth, p.pos) {
					break
				}
			}
			// Eight seconds of running ends against something, not out in the void.
			cell := world_cell(&w.cfg, p.pos)
			testing.expect(t, in_bounds(d, cell) && cell_at(d, cell).kind != .Empty)
			testing.expect(t, p.moving)
		}
	}
}

// Wanders with erratic input and uneven frame times; the player must never
// end up inside anything or outside the dungeon.
@(test)
erratic_movement_never_leaves_the_floor :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	for seed in 1 ..= u64(6) {
		d, p := world_make(t, &w, seed)
		rng := rng_make(seed * 77)
		move: [2]f32
		for step in 0 ..< 4000 {
			if step % 20 == 0 {
				move = {rng_float(&rng) * 2 - 1, rng_float(&rng) * 2 - 1}
			}
			dt := 0.004 + rng_float(&rng) * 0.1
			play_update(&p, d, &w.cfg, move, dt)

			cell := world_cell(&w.cfg, p.pos)
			if !testing.expectf(t, in_bounds(d, cell), "seed %d: left the grid at %v", seed, p.pos) {
				break
			}
			if !testing.expectf(t, cell_at(d, cell).kind != .Empty, "seed %d: walked out of the dungeon at %v", seed, p.pos) {
				break
			}
			if !testing.expectf(t, penetration(&p, d, &w.cfg) < 1e-3, "seed %d: inside an obstacle at %v", seed, p.pos) {
				break
			}

		}
	}
}

@(test)
turning_follows_the_heading :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	d, p := world_make(t, &w, 2)

	// East is +X: a quarter turn clockwise from north.
	play_update(&p, d, &w.cfg, {1, 0}, 0.01)
	testing.expect(t, p.facing > 0 && p.facing < 0.2, "the turn is gradual")
	for _ in 0 ..< 30 {
		play_update(&p, d, &w.cfg, {1, 0}, 0.01)
	}
	testing.expect(t, abs(p.facing - math.PI / 2) < 1e-3)

	// The model faces +Z at rest; the matrix has to carry that onto the heading.
	m := actor_matrix(&p)
	front := m * [4]f32{0, 0, 1, 0}
	testing.expect(t, abs(front.x - 1) < 1e-3 && abs(front.z) < 1e-3)
	feet := m * [4]f32{0, 0, 0, 1}
	testing.expect(t, abs(feet.x - p.pos.x) < 1e-4 && abs(feet.z - p.pos.y) < 1e-4 && abs(feet.y - ACTOR_FLOOR_Y) < 1e-4)

	p.facing = 0
	north := actor_matrix(&p) * [4]f32{0, 0, 1, 0}
	testing.expect(t, abs(north.x) < 1e-3 && abs(north.z + 1) < 1e-3)

	// Facing south-west, south-east is a quarter turn away through south;
	// the knight must not spin three quarters round through north.
	p.facing = -math.PI * 0.75
	play_update(&p, d, &w.cfg, {1, 1}, 0.01)
	testing.expect(t, p.facing < -math.PI * 0.75 && p.facing > -math.PI)
	for _ in 0 ..< 30 {
		play_update(&p, d, &w.cfg, {1, 1}, 0.01)
	}
	testing.expect(t, abs(p.facing - math.PI * 0.75) < 1e-3)
}

@(test)
locked_doors_need_their_key :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	tested := 0
	for seed in 1 ..= u64(12) {
		d, p := world_make(t, &w, seed)
		for conn, ci in d.conns {
			if !conn.locked {
				continue
			}
			step := dir_vec(conn.dir)
			front := conn.pos - step
			if p.solid[front.y * d.w + front.x] {
				continue
			}
			push := [2]f32{f32(step.x), f32(step.y)}
			door := cell_centre(&w.cfg, conn.pos)
			beyond :: proc(p: ^Play, door, push: [2]f32) -> f32 {
				return (p.pos.x - door.x) * push.x + (p.pos.y - door.y) * push.y
			}

			p = play_start(d, &w.cfg, w.allocator)
			p.pos = cell_centre(&w.cfg, front)
			for _ in 0 ..< 90 {
				play_update(&p, d, &w.cfg, push, STEP)
			}
			testing.expect(t, !p.conn_open[ci], "a locked door stays shut without its key")
			testing.expect_value(t, p.blocked_by, conn.lock_id)
			testing.expect(t, beyond(&p, door, push) < 0, "the player is still in front of the door")
			testing.expect_value(t, p.doors_unlocked, 0)

			p.has_key[conn.lock_id] = true
			version := p.version
			for _ in 0 ..< 90 {
				play_update(&p, d, &w.cfg, push, STEP)
			}
			testing.expect(t, p.conn_open[ci], "the key opens the door")
			testing.expect(t, p.version > version, "opening a door marks the tiles stale")
			testing.expect_value(t, p.doors_unlocked, 1)
			testing.expect(t, p.blocked_by != conn.lock_id)
			testing.expect(t, beyond(&p, door, push) > w.cfg.tile_size / 2, "the player walked through")
			testing.expect(t, p.room_seen[conn.to])
			tested += 1
			break
		}
	}
	testing.expect(t, tested >= 3, "too few locked doors were exercised")
}

// A bot that plays the way a person would: walk to the nearest thing worth
// reaching (a key, or a room not seen yet) through whatever is passable now.
@(private = "file")
bot_plan :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, path: ^[dynamic][2]int) {
	clear(path)
	passable :: proc(p: ^Play, d: ^Dungeon, cell: [2]int) -> bool {
		if !in_bounds(d, cell) {
			return false
		}
		info := cell_at(d, cell)
		#partial switch info.kind {
		case .Floor, .Open:
			return !p.solid[cell.y * d.w + cell.x]
		case .Door:
			conn := d.conns[info.conn]
			return p.conn_open[info.conn] || !conn.locked || p.has_key[conn.lock_id]
		}
		return false
	}

	start := world_cell(cfg, p.pos)
	parent := make([]int, d.w * d.h, context.temp_allocator)
	for &v in parent {
		v = -1
	}
	// Reaching for a chest can leave the player inside the chest's own cell;
	// from there the way back is whichever free cell is next to it.
	queue := make([dynamic][2]int, context.temp_allocator)
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			seed := start + {dx, dy}
			if (seed == start) == passable(p, d, start) && passable(p, d, seed) {
				append(&queue, seed)
				parent[seed.y * d.w + seed.x] = seed.y * d.w + seed.x
			}
		}
	}

	goal, extra := [2]int{-1, -1}, [2]int{-1, -1}
	search: for head := 0; head < len(queue); head += 1 {
		cell := queue[head]
		info := cell_at(d, cell)
		if info.kind == .Floor && !p.room_seen[info.room] {
			goal = cell
			break search
		}
		// A chest can be walked up to from any side, corners included.
		for slot, i in d.item_slots {
			away := slot.pos - cell
			if slot.item != .None && !p.slot_taken[i] && abs(away.x) <= 1 && abs(away.y) <= 1 {
				goal, extra = cell, slot.pos
				break search
			}
		}
		for dir in Dir {
			next := cell + dir_vec(dir)
			if passable(p, d, next) && parent[next.y * d.w + next.x] < 0 {
				parent[next.y * d.w + next.x] = cell.y * d.w + cell.x
				append(&queue, next)
			}
		}
	}
	if goal.x < 0 {
		return
	}
	if extra.x >= 0 {
		append(path, extra)
	}
	// Built goal first; the bot walks it from the back.
	at := goal
	for {
		append(path, at)
		i := parent[at.y * d.w + at.x]
		if i == at.y * d.w + at.x {
			break
		}
		at = {i % d.w, i / d.w}
	}
}

@(test)
a_player_can_collect_every_item_and_see_every_room :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	total_keys := 0
	for seed in 1 ..= u64(10) {
		d, p := world_make(t, &w, seed)
		path := make([dynamic][2]int, context.temp_allocator)
		version := -1
		steps := 0
		for !play_complete(&p, d) && steps < 150_000 {
			steps += 1
			if len(path) == 0 || version != p.version {
				version = p.version
				bot_plan(&p, d, &w.cfg, &path)
				if len(path) == 0 {
					break
				}
			}
			target := cell_centre(&w.cfg, path[len(path) - 1])
			to := target - p.pos
			if to.x * to.x + to.y * to.y < 0.3 * 0.3 {
				pop(&path)
				continue
			}
			play_update(&p, d, &w.cfg, to * 100, STEP)
		}
		testing.expectf(
			t,
			play_complete(&p, d),
			"seed %d: stopped after %d steps with %d/%d keys and %d/%d rooms at %v",
			seed,
			steps,
			p.keys_held,
			d.lock_count,
			p.rooms_seen,
			len(d.rooms),
			p.pos,
		)
		testing.expect_value(t, p.doors_unlocked, d.lock_count)
		for slot, i in d.item_slots {
			if slot.item != .None {
				testing.expectf(t, p.slot_taken[i], "seed %d: %v in slot %d was left behind", seed, slot.item, i)
			}
		}
		testing.expect_value(t, p.keys_held, d.lock_count)
		testing.expect_value(t, p.has_sword, stats(d).swords > 0)
		total_keys += p.keys_held
	}
	testing.expect(t, total_keys > 0)
}

@(private = "file")
count :: proc(tiles: []Tile, model: string) -> (n: int) {
	for tile in tiles {
		n += int(tile.model == model)
	}
	return
}

@(private = "file")
tile_near :: proc(tiles: []Tile, cfg: ^Config, model: string, cell: [2]int) -> (found: Tile, ok: bool) {
	for tile in tiles {
		if tile.model == model && abs(tile.pos.x - f32(cell.x) * cfg.tile_size) < 1.5 && abs(tile.pos.z - f32(cell.y) * cfg.tile_size) < 1.5 {
			return tile, true
		}
	}
	return
}

@(test)
doors_swing_open_in_the_tiles :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	d, p := world_make(t, &w, 4)
	if !testing.expect(t, d.lock_count > 0) {
		return
	}
	tinted :: proc(tiles: []Tile, model: string) -> (n: int) {
		for tile in tiles {
			n += int(tile.model == model && tile.tint != {1, 1, 1})
		}
		return
	}

	// Untouched, a play state changes nothing about the picture.
	plain := build_tiles(d, &w.cfg, w.allocator)
	fresh := build_tiles(d, &w.cfg, w.allocator, &p)
	testing.expect_value(t, len(fresh), len(plain))
	for tile, i in plain {
		testing.expect(t, tile == fresh[i])
	}
	testing.expect_value(t, tinted(plain, w.cfg.tiles.door), d.lock_count)

	// The leaf hangs on the hinge, inside its frame's cell.
	locked: Connection
	locked_index := -1
	for conn, i in d.conns {
		if conn.lock_id == 0 {
			locked, locked_index = conn, i
		}
	}
	leaf, _ := tile_near(plain, &w.cfg, w.cfg.tiles.door, locked.pos)
	frame, _ := tile_near(plain, &w.cfg, w.cfg.tiles.doorway, locked.pos)
	testing.expect_value(t, leaf.turns, frame.turns)
	offset := leaf.pos - frame.pos
	reach := math.sqrt(offset.x * offset.x + offset.z * offset.z)
	testing.expect(t, abs(reach - abs(w.cfg.tiles.door_hinge.x)) < 1e-3)
	// It sits along the wall, not across it.
	across := dir_vec(locked.dir)
	testing.expect(t, abs(offset.x * f32(across.x) + offset.z * f32(across.y)) < 1e-3)

	p.conn_open[locked_index] = true
	after := build_tiles(d, &w.cfg, w.allocator, &p)
	testing.expect_value(t, tinted(after, w.cfg.tiles.door), d.lock_count - 1)
	testing.expect_value(t, tinted(after, w.cfg.tiles.doorway), d.lock_count - 1)
	open_leaf, _ := tile_near(after, &w.cfg, w.cfg.tiles.door, locked.pos)
	open_frame, _ := tile_near(after, &w.cfg, w.cfg.tiles.doorway, locked.pos)
	testing.expect_value(t, open_leaf.turns, leaf.turns + 1)
	testing.expect_value(t, open_leaf.pos, leaf.pos)
	testing.expect_value(t, open_frame.turns, frame.turns)
	testing.expect_value(t, open_leaf.tint, [3]f32{1, 1, 1})
}

// On foot the knight sees chests and what lies on the floor, nothing else.
// Free flight adds the contents of closed chests and the spawn points.
@(test)
hidden_things_only_show_in_free_flight :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	in_chests, on_floor := 0, 0
	for seed in 1 ..= u64(10) {
		d, p := world_make(t, &w, seed)
		on_foot := build_tiles(d, &w.cfg, w.allocator, &p, reveal = false)
		flying := build_tiles(d, &w.cfg, w.allocator, &p, reveal = true)

		keys_floor, keys_chest, swords_floor, swords_chest, chests, bare := 0, 0, 0, 0, 0, 0
		for slot in d.item_slots {
			chests += int(slot.chest)
			bare += int(!slot.chest && slot.item == .None)
			#partial switch slot.item {
			case .Key:
				keys_floor += int(!slot.chest)
				keys_chest += int(slot.chest)
			case .Sword:
				swords_floor += int(!slot.chest)
				swords_chest += int(slot.chest)
			}
		}
		in_chests += keys_chest + swords_chest
		on_floor += keys_floor + swords_floor

		cfg := &w.cfg
		testing.expect_value(t, count(on_foot, cfg.items.key.model), keys_floor)
		testing.expect_value(t, count(flying, cfg.items.key.model), keys_floor + keys_chest)
		testing.expect_value(t, count(on_foot, cfg.items.sword.model), swords_floor)
		testing.expect_value(t, count(flying, cfg.items.sword.model), swords_floor + swords_chest)

		testing.expect_value(t, count(on_foot, cfg.markers.enemy_spawn.model), 0)
		testing.expect_value(t, count(on_foot, cfg.markers.player_spawn.model), 0)
		testing.expect_value(t, count(on_foot, cfg.markers.ground_slot.model), 0)
		testing.expect_value(t, count(flying, cfg.markers.enemy_spawn.model), len(d.enemy_spawns))
		testing.expect_value(t, count(flying, cfg.markers.player_spawn.model), 1)
		testing.expect_value(t, count(flying, cfg.markers.ground_slot.model), bare)

		// Chests look the same either way, whatever is in them.
		testing.expect_value(t, count(on_foot, cfg.props.chest), chests)
		testing.expect_value(t, count(flying, cfg.props.chest), chests)
		testing.expect_value(t, count(on_foot, cfg.props.chest_lid), chests)

		// Hiding only ever removes tiles.
		testing.expect(t, len(on_foot) <= len(flying))

		for slot in d.item_slots {
			if slot.item == .None {
				continue
			}
			visual := slot.item == .Sword ? cfg.items.sword : cfg.items.key
			tile, shown := tile_near(flying, cfg, visual.model, slot.pos)
			testing.expect(t, shown) or_continue
			if slot.chest {
				testing.expect_value(t, tile.pos.y, visual.reveal_y)
				testing.expect_value(t, tile.tilt, 0)
			} else {
				testing.expect_value(t, tile.pos.y, visual.ground_y)
				testing.expect(t, abs(tile.tilt - math.PI / 2) < 1e-4, "items on the floor lie flat")
			}
			if slot.item == .Key {
				testing.expect_value(t, tile.tint, lock_color(slot.key))
			}
		}
	}
	testing.expect(t, in_chests > 0, "no seed put an item in a chest")
	testing.expect(t, on_floor > 0, "no seed put an item on the floor")
}

// Walks the knight from a free neighbouring cell straight at a slot.
@(private = "file")
approach_slot :: proc(t: ^testing.T, p: ^Play, d: ^Dungeon, cfg: ^Config, slot: Item_Slot) -> bool {
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			from := slot.pos + {dx, dy}
			if (dx == 0 && dy == 0) || cell_at(d, from).kind != .Floor || p.solid[from.y * d.w + from.x] {
				continue
			}
			p.pos = cell_centre(cfg, from)
			for _ in 0 ..< 60 {
				play_update(p, d, cfg, cell_centre(cfg, slot.pos) - p.pos, STEP)
			}
			return true
		}
	}
	testing.expect(t, false, "no free cell next to the slot")
	return false
}

@(test)
opening_a_chest_awards_what_is_inside :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	cfg := &w.cfg
	opened_full, opened_empty := 0, 0
	for seed in 1 ..= u64(10) {
		d, _ := world_make(t, &w, seed)
		for slot, i in d.item_slots {
			if !slot.chest {
				continue
			}
			p := play_start(d, cfg, w.allocator)
			before := build_tiles(d, cfg, w.allocator, &p, reveal = false)
			shut, _ := tile_near(before, cfg, cfg.props.chest_lid, slot.pos)
			testing.expect_value(t, shut.tilt, 0)
			testing.expect(t, !p.slot_taken[i])

			if !approach_slot(t, &p, d, cfg, slot) {
				continue
			}
			testing.expectf(t, p.slot_taken[i], "seed %d: chest %d did not open", seed, i)
			testing.expect(t, p.version > 0, "an opened chest marks the tiles stale")
			testing.expect_value(t, p.last_found, slot.item)
			switch slot.item {
			case .Key:
				testing.expect(t, p.has_key[slot.key])
				testing.expect_value(t, p.last_found_key, slot.key)
				testing.expect_value(t, p.keys_held, 1)
				testing.expect_value(t, p.items_found, 1)
				opened_full += 1
			case .Sword:
				testing.expect(t, p.has_sword)
				testing.expect_value(t, p.items_found, 1)
				opened_full += 1
			case .Amulet:
				opened_full += 1
			case .None:
				testing.expect_value(t, p.items_found, 0)
				testing.expect(t, !p.has_sword)
				opened_empty += 1
			}
			// The chest itself is never walked through.
			testing.expect(t, penetration(&p, d, cfg) < 1e-3)

			// Its lid now stands tipped back, hinge unmoved, front edge in the air.
			after := build_tiles(d, cfg, w.allocator, &p, reveal = true)
			lid, _ := tile_near(after, cfg, cfg.props.chest_lid, slot.pos)
			testing.expect(t, lid.tilt < -1)
			testing.expect_value(t, lid.pos, shut.pos)
			front_edge := tile_matrix(lid) * [4]f32{0, 0, 1, 1}
			testing.expect(t, front_edge.y > lid.pos.y + 0.5, "the lid lifts rather than sinking into the chest")
			// What was inside is in the knight's hands, not floating over the chest.
			if slot.item != .None {
				visual := slot.item == .Sword ? cfg.items.sword : cfg.items.key
				_, still_shown := tile_near(after, cfg, visual.model, slot.pos)
				testing.expect(t, !still_shown)
			}

			// Opening happens once.
			version := p.version
			for _ in 0 ..< 10 {
				play_update(&p, d, cfg, {}, STEP)
			}
			testing.expect_value(t, p.version, version)
		}
	}
	testing.expect(t, opened_full >= 5)
	testing.expect(t, opened_empty >= 1, "empty chests should open too")
}

@(test)
items_on_the_floor_are_picked_up_by_walking_over_them :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	cfg := &w.cfg
	picked := 0
	for seed in 1 ..= u64(12) {
		d, _ := world_make(t, &w, seed)
		for slot, i in d.item_slots {
			if slot.chest {
				continue
			}
			p := play_start(d, cfg, w.allocator)
			testing.expect(t, !p.solid[slot.pos.y * d.w + slot.pos.x], "nothing on the floor is in the way")
			if !approach_slot(t, &p, d, cfg, slot) {
				continue
			}
			// The knight ends up standing on the very spot.
			testing.expect_value(t, world_cell(cfg, p.pos), slot.pos)
			if slot.item == .None {
				testing.expect(t, !p.slot_taken[i], "there is nothing to pick up from an empty spot")
				testing.expect_value(t, p.version, 0)
				continue
			}
			testing.expect(t, p.slot_taken[i])
			testing.expect_value(t, p.items_found, 1)
			picked += 1

			visual := slot.item == .Sword ? cfg.items.sword : cfg.items.key
			_, shown := tile_near(build_tiles(d, cfg, w.allocator, &p, reveal = true), cfg, visual.model, slot.pos)
			testing.expect(t, !shown, "a picked up item is gone from the floor")
		}
	}
	testing.expect(t, picked >= 3)
}

@(test)
a_sword_is_placed_early_and_can_be_swung :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	cfg := &w.cfg
	for seed in 1 ..= u64(20) {
		d, _ := world_make(t, &w, seed)
		swords := 0
		for slot in d.item_slots {
			if slot.item == .Sword {
				swords += 1
				testing.expect_value(t, slot.key, -1)
				testing.expectf(t, slot.room < max(1, len(d.rooms) / 4), "seed %d: the sword is far away in room %d", seed, slot.room)
			}
		}
		testing.expect_value(t, swords, cfg.items.swords)
		testing.expect_value(t, stats(d).swords, swords)
	}

	cfg.items.swords = 0
	none, _ := world_make(t, &w, 3)
	testing.expect_value(t, stats(none).swords, 0)
	cfg.items.swords = 1

	d, p := world_make(t, &w, 3)
	testing.expect(t, !play_swing(&p, 1), "there is nothing to swing yet")
	testing.expect_value(t, p.swing_left, 0)

	for slot in d.item_slots {
		if slot.item == .Sword {
			approach_slot(t, &p, d, cfg, slot)
		}
	}
	if !testing.expect(t, p.has_sword) {
		return
	}
	testing.expect_value(t, p.last_found, Item_Kind.Sword)

	testing.expect(t, play_swing(&p, 1))
	testing.expect(t, !play_swing(&p, 1), "one swing at a time")
	testing.expect(t, !play_swing(&p, 0))
	// Feet stay planted for the swing.
	at := p.pos
	for _ in 0 ..< 15 {
		play_update(&p, d, cfg, {1, 0}, STEP)
	}
	testing.expect_value(t, p.pos, at)
	testing.expect(t, !p.moving)
	testing.expect(t, abs(p.swing_left - 0.5) < 1e-3)
	for _ in 0 ..< 20 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, p.swing_left, 0)
	testing.expect(t, play_swing(&p, 0.4), "and then the next one")
}

@(test)
chests_face_into_their_room :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	for seed in 1 ..= u64(10) {
		d, _ := world_make(t, &w, seed)
		for slot in d.item_slots {
			if !slot.chest {
				continue
			}
			// The cell in front of the chest is floor of the same room.
			front := tile_matrix(Tile{turns = chest_turns(d, slot), scale = 1}) * [4]f32{0, 0, 1, 0}
			ahead := slot.pos + {int(math.round(front.x)), int(math.round(front.z))}
			cell := cell_at(d, ahead)
			testing.expectf(t, cell.kind == .Floor && int(cell.room) == slot.room, "seed %d: chest at %v faces %v", seed, slot.pos, cell.kind)
		}
	}
}

@(test)
tilt_tips_a_tile_before_it_is_turned :: proc(t: ^testing.T) {
	near :: proc(v: [4]f32, x, y, z: f32) -> bool {
		return abs(v.x - x) < 1e-4 && abs(v.y - y) < 1e-4 && abs(v.z - z) < 1e-4
	}
	// A quarter tilt lays an upright model (+Y) down along +Z.
	flat := Tile{tilt = math.PI / 2, scale = 1}
	testing.expect(t, near(tile_matrix(flat) * [4]f32{0, 1, 0, 0}, 0, 0, 1))
	// Turning afterwards swings that round to +X (east).
	flat.turns = 1
	testing.expect(t, near(tile_matrix(flat) * [4]f32{0, 1, 0, 0}, 1, 0, 0))
	// A negative tilt lifts +Z, which is how a chest lid opens.
	open := Tile{tilt = -math.PI / 2, scale = 2, pos = {1, 2, 3}}
	testing.expect(t, near(tile_matrix(open) * [4]f32{0, 0, 1, 1}, 1, 4, 3))
	// No tilt leaves the old behaviour alone.
	testing.expect(t, near(tile_matrix(Tile{turns = 1, scale = 1}) * [4]f32{1, 0, 0, 0}, 0, 0, -1))
}
// Props are solid for the knight, so layouts that would trap or block it are
// turned away when the config loads.
@(test)
layouts_must_stay_walkable :: proc(t: ^testing.T) {
	decor := make(map[string][]string, context.temp_allocator)
	decor["b"] = {"barrel_large"}
	check :: proc(rows: []string, decor: map[string][]string) -> bool {
		tmpl, _, ok := template_parse(rows, decor, context.temp_allocator)
		if !ok {
			return false
		}
		_, walkable := template_check_walkable(&tmpl, context.temp_allocator)
		return walkable
	}

	testing.expect(t, check({"##D##", "#b.b#", "#...#", "#I.b#", "#####"}, decor), "props in the corners are fine")
	testing.expect(t, check({"#####", "~..I#", "~.b.#", "~...#", "#####"}, decor))
	testing.expect(t, check({"##D##", "#.i.#", "#...#", "#####"}, decor), "an item on the floor blocks nothing")

	testing.expect(t, !check({"##D##", "#.b.#", "#...#", "#####"}, decor), "a barrel right inside the door")
	testing.expect(t, !check({"##D##", "#.I.#", "#...#", "#####"}, decor), "a chest right inside the door")
	testing.expect(t, !check({"#####", "~b..#", "~...#", "#####"}, decor), "a barrel in an opening")
	testing.expect(t, !check({"##D##", "#...#", "#bbb#", "#...#", "#####"}, decor), "a row of barrels splits the room")
	testing.expect(t, !check({"##D###", "#..bI#", "#..bb#", "######"}, decor), "a chest nobody can get next to")
}

@(test)
play_settings_are_validated :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	_, ok := config_validate(&w.cfg, w.allocator)
	testing.expect(t, ok)

	wide := w.cfg
	wide.play.radius = wide.tile_size * DOOR_HALF_OPENING
	_, ok = config_validate(&wide, w.allocator)
	testing.expect(t, !ok, "a knight as wide as a doorway cannot get through it")

	short := w.cfg
	short.play.interact_radius = short.play.radius + short.tile_size * PROP_HALF_SIZE
	_, ok = config_validate(&short, w.allocator)
	testing.expect(t, !ok, "a reach that stops at the chest's edge never collects its key")

	still := w.cfg
	still.play.speed = 0
	_, ok = config_validate(&still, w.allocator)
	testing.expect(t, !ok)

	slow := w.cfg
	slow.play.celebrate_pan = slow.play.celebrate_time + 1
	_, ok = config_validate(&slow, w.allocator)
	testing.expect(t, !ok, "a pan that outlasts the celebration never reaches the amulet")
	slow.play.celebrate_time = 0 // no celebration at all: the pan length is moot
	_, ok = config_validate(&slow, w.allocator)
	testing.expect(t, ok)
}
// The whole game in one test: a player who explores, collects keys and opens
// doors gets to the amulet, however deep it is hidden, and wins.
@(test)
the_amulet_can_be_reached_and_wins_the_game :: proc(t: ^testing.T) {
	w: World
	defer virtual.arena_destroy(&w.arena)
	if !world_init(t, &w) {
		return
	}
	w.cfg.items.amulet.model = "amulet"
	for seed in 1 ..= u64(10) {
		d, p := world_make(t, &w, seed)
		if !testing.expect_value(t, stats(d).amulets, 1) {
			continue
		}
		path := make([dynamic][2]int, context.temp_allocator)
		version := -1
		steps, updates := 0, 0
		for !p.has_amulet && steps < 150_000 {
			steps += 1
			if len(path) == 0 || version != p.version {
				version = p.version
				bot_plan(&p, d, &w.cfg, &path)
				if len(path) == 0 {
					break
				}
			}
			target := cell_centre(&w.cfg, path[len(path) - 1])
			to := target - p.pos
			if to.x * to.x + to.y * to.y < 0.3 * 0.3 {
				pop(&path)
				continue
			}
			play_update(&p, d, &w.cfg, to * 100, STEP)
			updates += 1
		}
		testing.expectf(t, p.has_amulet, "seed %d: no amulet after %d steps, %d/%d rooms seen", seed, steps, p.rooms_seen, len(d.rooms))
		testing.expect(t, abs(p.time - f32(updates) * STEP) < 0.5, "the clock ran until the amulet was found")
		// The celebration plays out, and then the game is won.
		for _ in 0 ..< int(w.cfg.play.celebrate_time / STEP) + 2 {
			play_update(&p, d, &w.cfg, {}, STEP)
		}
		testing.expectf(t, p.won, "seed %d: finding the amulet did not win the game", seed)
		testing.expect(t, !p.dead)
	}
}