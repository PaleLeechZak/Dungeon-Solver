package dungeon

import "base:runtime"
import "core:mem/virtual"
import "core:testing"

// The goal of the game: an amulet hidden deep in the dungeon. Picking it up
// wins; dying loses.

@(private = "file")
Quest :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	cfg:       Config,
}

@(private = "file")
quest_init :: proc(t: ^testing.T, q: ^Quest) -> bool {
	if !testing.expect(t, virtual.arena_init_growing(&q.arena) == nil) {
		return false
	}
	q.allocator = virtual.arena_allocator(&q.arena)
	err: string
	ok: bool
	q.cfg, err, ok = config_load(CONFIG_PATH, q.allocator)
	if !testing.expectf(t, ok, "config_load failed: %s", err) {
		return false
	}
	return testing.expect(t, q.cfg.items.amulet.model != "", "the project config should have an amulet")
}

@(private = "file")
quest_make :: proc(t: ^testing.T, q: ^Quest, seed: u64) -> (^Dungeon, Play) {
	d, err, ok := generate(&q.cfg, seed, q.allocator)
	testing.expectf(t, ok, "generate(%d) failed: %s", seed, err)
	return d, play_start(d, &q.cfg, q.allocator)
}

@(private = "file")
amulet_slot :: proc(d: ^Dungeon) -> (index: int, slot: Item_Slot) {
	for s, i in d.item_slots {
		if s.item == .Amulet {
			return i, s
		}
	}
	return -1, {}
}

// Stands the knight next to a slot and walks it in.
@(private = "file")
walk_to_slot :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, slot: Item_Slot) {
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			from := slot.pos + {dx, dy}
			if (dx == 0 && dy == 0) || cell_at(d, from).kind != .Floor || p.solid[from.y * d.w + from.x] {
				continue
			}
			at := cell_world(cfg, from)
			goal := cell_world(cfg, slot.pos)
			p.pos = {at.x, at.z}
			for _ in 0 ..< 60 {
				play_update(p, d, cfg, [2]f32{goal.x, goal.z} - p.pos, STEP)
			}
			return
		}
	}
}

@(test)
one_amulet_is_hidden_as_deep_as_the_dungeon_goes :: proc(t: ^testing.T) {
	q: Quest
	defer virtual.arena_destroy(&q.arena)
	if !quest_init(t, &q) {
		return
	}
	for seed in 1 ..= u64(SEEDS) {
		d, _ := quest_make(t, &q, seed)
		amulets := 0
		for slot in d.item_slots {
			amulets += int(slot.item == .Amulet)
		}
		testing.expect_value(t, amulets, 1) or_continue
		testing.expect_value(t, stats(d).amulets, 1)

		_, amulet := amulet_slot(d)
		testing.expect_value(t, amulet.key, -1)
		depth := d.rooms[amulet.room].depth
		testing.expectf(t, depth > 0, "seed %d: the amulet is in the entrance", seed)
		// No room further from the entrance has anywhere to put an item.
		for slot in d.item_slots {
			testing.expectf(t, d.rooms[slot.room].depth <= depth, "seed %d: a slot at depth %d is deeper than the amulet at %d", seed, d.rooms[slot.room].depth, depth)
		}
		// It took nothing away from the locks: every lock still has its key,
		// and the dungeon can still be solved.
		keys := 0
		for slot in d.item_slots {
			keys += int(slot.item == .Key)
		}
		testing.expect_value(t, keys, d.lock_count)
		testing.expect(t, solve(d, q.allocator).solvable)
	}

	// The same seed hides it in the same place.
	a, _ := quest_make(t, &q, 77)
	b, _ := quest_make(t, &q, 77)
	_, slot_a := amulet_slot(a)
	_, slot_b := amulet_slot(b)
	testing.expect_value(t, slot_a.pos, slot_b.pos)

	// No model in the config, no amulet in the dungeon.
	q.cfg.items.amulet.model = ""
	none, _ := quest_make(t, &q, 3)
	testing.expect_value(t, stats(none).amulets, 0)
}

@(test)
picking_up_the_amulet_wins_after_a_celebration :: proc(t: ^testing.T) {
	q: Quest
	defer virtual.arena_destroy(&q.arena)
	if !quest_init(t, &q) {
		return
	}
	cfg := &q.cfg
	cfg.sounds.knight_stride = 0
	cfg.play.celebrate_time = 3
	heard :: proc(p: ^Play, kind: Sound_Kind) -> (n: int) {
		for event in sounds_pending(p) {
			n += int(event.kind == kind)
		}
		return
	}
	amulet_tiles :: proc(d: ^Dungeon, cfg: ^Config, p: ^Play, allocator: runtime.Allocator) -> (tiles: [dynamic]Tile) {
		tiles = make([dynamic]Tile, allocator)
		for tile in build_tiles(d, cfg, allocator, p, reveal = true) {
			if tile.model == cfg.items.amulet.model {
				append(&tiles, tile)
			}
		}
		return
	}

	for seed in 1 ..= u64(8) {
		d, p := quest_make(t, &q, seed)
		index, slot := amulet_slot(d)
		if !testing.expect(t, index >= 0) {
			continue
		}
		testing.expect(t, !p.won && !p.has_amulet && !play_celebrating(&p))

		// Skeletons in the amulet's room may get a blow in on the way; the
		// knight is given the health to shrug that off.
		p.health = 1000
		at := cell_world(cfg, slot.pos)
		goal := [2]f32{at.x, at.z}
		walk_to_slot(&p, d, cfg, Item_Slot{pos = slot.pos, room = slot.room, chest = slot.chest})
		// walk_to_slot keeps walking for two seconds; the amulet was picked
		// up on the way, and the knight has been celebrating since.
		testing.expectf(t, p.has_amulet && p.slot_taken[index], "seed %d: the amulet was not picked up", seed)
		testing.expect(t, play_celebrating(&p) && !p.won, "finding it is not yet winning")
		testing.expect_value(t, p.last_found, Item_Kind.Amulet)
		testing.expect_value(t, heard(&p, .Amulet_Pickup), 1)
		testing.expect_value(t, heard(&p, .Game_Won), 0)
		testing.expect(t, p.celebrated > 0 && p.celebrated < cfg.play.celebrate_time)
		testing.expect(t, abs(p.celebrated + p.celebrate_left - cfg.play.celebrate_time) < 1e-3)

		// It is no longer where it lay: it is over the knight's head.
		shown := amulet_tiles(d, cfg, &p, q.allocator)
		if testing.expect_value(t, len(shown), 1) {
			testing.expect(t, abs(shown[0].pos.x - p.pos.x) < 1e-4 && abs(shown[0].pos.z - p.pos.y) < 1e-4)
			testing.expect(t, shown[0].pos.y > AMULET_LIFT_FROM)
			moved := [2]f32{shown[0].pos.x, shown[0].pos.z} - goal
			testing.expect(t, moved.x * moved.x + moved.y * moved.y > 0.01 || !slot.chest)
		}

		// While celebrating the knight stands still, cannot be hurt, cannot
		// swing, and the skeletons hold still too.
		spot, health, clock := p.pos, p.health, p.time
		enemies := make([]Enemy, len(p.enemies), q.allocator)
		copy(enemies, p.enemies)
		p.has_sword = true
		testing.expect(t, !play_swing(&p, 1))
		testing.expect(t, !play_hurt(&p, cfg, 5))
		play_update(&p, d, cfg, {1, 0}, STEP)
		testing.expect_value(t, p.pos, spot)
		testing.expect_value(t, p.health, health)
		testing.expect_value(t, p.time, clock) // the clock stopped when the amulet was found
		testing.expect(t, !p.moving && !p.won)
		for e, i in p.enemies {
			testing.expect(t, e.pos == enemies[i].pos && e.state == enemies[i].state, "a skeleton moved during the celebration") or_break
		}

		// When the celebration is over the game is won, announced once.
		sounds_clear(&p)
		for _ in 0 ..< int(cfg.play.celebrate_time / STEP) + 2 {
			play_update(&p, d, cfg, {1, 0}, STEP)
		}
		testing.expectf(t, p.won, "seed %d: the celebration never ended", seed)
		testing.expect(t, !play_celebrating(&p) && !p.dead)
		testing.expect_value(t, heard(&p, .Game_Won), 1)
		testing.expect_value(t, p.celebrate_left, 0)

		// After that nothing changes any more, the celebration clock included.
		celebrated := p.celebrated
		sounds_clear(&p)
		for _ in 0 ..< 60 {
			play_update(&p, d, cfg, {1, 0}, STEP)
		}
		testing.expect_value(t, p.pos, spot)
		testing.expect_value(t, p.celebrated, celebrated)
		testing.expect_value(t, len(sounds_pending(&p)), 0)
		// The amulet stays held up for the victory screen.
		testing.expect_value(t, len(amulet_tiles(d, cfg, &p, q.allocator)), 1)
	}

	// With no celebration configured, finding it wins on the spot.
	cfg.play.celebrate_time = 0
	d, p := quest_make(t, &q, 3)
	_, slot := amulet_slot(d)
	p.health = 1000
	walk_to_slot(&p, d, cfg, slot)
	testing.expect(t, p.won && p.has_amulet)
	testing.expect_value(t, heard(&p, .Game_Won), 1)
}

@(test)
the_found_amulet_rises_over_the_knight :: proc(t: ^testing.T) {
	testing.expect_value(t, amulet_height(0), f32(AMULET_LIFT_FROM))
	testing.expect_value(t, amulet_height(AMULET_LIFT_TIME), f32(AMULET_LIFT_TO))
	testing.expect_value(t, amulet_height(100), f32(AMULET_LIFT_TO)) // and stays there
	testing.expect_value(t, amulet_height(-1), f32(AMULET_LIFT_FROM))
	previous := amulet_height(0)
	half := amulet_height(AMULET_LIFT_TIME / 2)
	for step in 1 ..= 10 {
		h := amulet_height(AMULET_LIFT_TIME * f32(step) / 10)
		testing.expect(t, h > previous, "it only ever goes up")
		previous = h
	}
	// Quick off the mark, gentle at the top.
	testing.expect(t, half > (AMULET_LIFT_FROM + AMULET_LIFT_TO) / 2)
}
@(test)
the_amulet_is_shown_like_any_other_item :: proc(t: ^testing.T) {
	q: Quest
	defer virtual.arena_destroy(&q.arena)
	if !quest_init(t, &q) {
		return
	}
	cfg := &q.cfg
	on_floor, in_chest := 0, 0
	for seed in 1 ..= u64(20) {
		d, p := quest_make(t, &q, seed)
		_, slot := amulet_slot(d)
		count :: proc(tiles: []Tile, model: string) -> (n: int) {
			for tile in tiles {
				n += int(tile.model == model)
			}
			return
		}
		// Free flight always shows where it is; on foot it is only visible
		// when it lies on the floor rather than in a chest.
		testing.expect_value(t, count(build_tiles(d, cfg, q.allocator, &p, reveal = true), cfg.items.amulet.model), 1)
		testing.expect_value(t, count(build_tiles(d, cfg, q.allocator, &p, reveal = false), cfg.items.amulet.model), int(!slot.chest))
		on_floor += int(!slot.chest)
		in_chest += int(slot.chest)
	}
	testing.expect(t, on_floor + in_chest == 20)
	testing.expect_value(t, item_visual(cfg, .Amulet).model, cfg.items.amulet.model)
	testing.expect_value(t, item_visual(cfg, .Sword).model, cfg.items.sword.model)
	testing.expect_value(t, item_visual(cfg, .Key).model, cfg.items.key.model)
}

@(test)
dying_loses_and_stops_the_clock :: proc(t: ^testing.T) {
	q: Quest
	defer virtual.arena_destroy(&q.arena)
	if !quest_init(t, &q) {
		return
	}
	cfg := &q.cfg
	d, p := quest_make(t, &q, 4)

	for _ in 0 ..< 30 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect(t, abs(p.time - 1) < 1e-3, "the clock counts the seconds played")

	testing.expect(t, play_hurt(&p, cfg, 1000))
	testing.expect(t, p.dead && !p.won)
	lost := 0
	for event in sounds_pending(&p) {
		lost += int(event.kind == .Game_Lost)
	}
	testing.expect_value(t, lost, 1)

	clock := p.time
	for _ in 0 ..< 60 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, p.time, clock)
	testing.expect(t, p.dead_time > 1.9, "time since death keeps running, for the fall")

	// The dead do not win: lying on the amulet picks nothing up.
	_, slot := amulet_slot(d)
	at := cell_world(cfg, slot.pos)
	p.pos = {at.x, at.z}
	for _ in 0 ..< 10 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect(t, !p.won && !p.has_amulet)
}