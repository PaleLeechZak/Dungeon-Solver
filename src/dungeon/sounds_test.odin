package dungeon

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:testing"

// Every in-game action that should be audible has to raise its event, once,
// where it happened. What the events sound like is tested in src/sound.

@(private = "file")
Stage :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	cfg:       Config,
}

@(private = "file")
stage_init :: proc(t: ^testing.T, s: ^Stage, enemies: bool) -> bool {
	if !testing.expect(t, virtual.arena_init_growing(&s.arena) == nil) {
		return false
	}
	s.allocator = virtual.arena_allocator(&s.arena)
	err: string
	ok: bool
	s.cfg, err, ok = config_load(CONFIG_PATH, s.allocator)
	s.cfg.locks = {chance = 1, max = 1000}
	s.cfg.enemies.enabled = enemies
	return testing.expectf(t, ok, "config_load failed: %s", err)
}

@(private = "file")
stage_make :: proc(t: ^testing.T, s: ^Stage, seed: u64) -> (^Dungeon, Play) {
	d, err, ok := generate(&s.cfg, seed, s.allocator)
	testing.expectf(t, ok, "generate(%d) failed: %s", seed, err)
	return d, play_start(d, &s.cfg, s.allocator)
}

@(private = "file")
heard :: proc(p: ^Play, kind: Sound_Kind) -> (count: int) {
	for event in sounds_pending(p) {
		count += int(event.kind == kind)
	}
	return
}

@(private = "file")
centre :: proc(cfg: ^Config, cell: [2]int) -> [2]f32 {
	c := cell_world(cfg, cell)
	return {c.x, c.z}
}

@(test)
footsteps_follow_the_ground_covered :: proc(t: ^testing.T) {
	s: Stage
	defer virtual.arena_destroy(&s.arena)
	if !stage_init(t, &s, false) {
		return
	}
	cfg := &s.cfg
	d, p := stage_make(t, &s, 3)

	// Standing about makes no noise.
	for _ in 0 ..< 30 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, len(sounds_pending(&p)), 0)

	// Walking does: one footfall per stride, each where the knight is.
	start := p.pos
	for _ in 0 ..< 20 {
		play_update(&p, d, cfg, {1, 0}, STEP)
	}
	walked := p.pos.x - start.x
	testing.expect(t, walked > cfg.sounds.knight_stride, "the entrance should leave room for a stride")
	testing.expect_value(t, heard(&p, .Knight_Step), int(walked / cfg.sounds.knight_stride))
	testing.expect_value(t, heard(&p, .Knight_Step), len(sounds_pending(&p)))
	for event in sounds_pending(&p) {
		testing.expect(t, event.pos.x > start.x && event.pos.x <= p.pos.x + 1e-3)
	}

	// Pushing against a wall covers no ground, so it is silent.
	for _ in 0 ..< 200 {
		play_update(&p, d, cfg, {1, 0}, STEP)
	}
	sounds_clear(&p)
	testing.expect_value(t, len(sounds_pending(&p)), 0)
	for _ in 0 ..< 90 {
		play_update(&p, d, cfg, {1, 0}, STEP)
	}
	testing.expect_value(t, heard(&p, .Knight_Step), 0)

	// The frame rate does not change how many steps a walk takes.
	a := play_start(d, cfg, s.allocator)
	b := play_start(d, cfg, s.allocator)
	for _ in 0 ..< 8 {
		play_update(&a, d, cfg, {0, 1}, 0.05)
	}
	for _ in 0 ..< 40 {
		play_update(&b, d, cfg, {0, 1}, 0.01)
	}
	testing.expect(t, abs(heard(&a, .Knight_Step) - heard(&b, .Knight_Step)) <= 1)

	// Switched off by a stride of zero.
	cfg.sounds.knight_stride = 0
	c := play_start(d, cfg, s.allocator)
	for _ in 0 ..< 20 {
		play_update(&c, d, cfg, {1, 0}, STEP)
	}
	testing.expect_value(t, heard(&c, .Knight_Step), 0)
}

@(test)
chests_pickups_and_doors_are_heard_once :: proc(t: ^testing.T) {
	s: Stage
	defer virtual.arena_destroy(&s.arena)
	if !stage_init(t, &s, false) {
		return
	}
	cfg := &s.cfg
	cfg.sounds.knight_stride = 0 // keep footsteps out of the counts

	walk_at :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, target: [2]f32, steps: int) {
		for _ in 0 ..< steps {
			play_update(p, d, cfg, target - p.pos, STEP)
		}
	}
	free_neighbour :: proc(p: ^Play, d: ^Dungeon, pos: [2]int) -> (cell: [2]int, ok: bool) {
		for dir in Dir {
			next := pos + dir_vec(dir)
			if cell_at(d, next).kind == .Floor && !p.solid[next.y * d.w + next.x] {
				return next, true
			}
		}
		return {}, false
	}

	chests, floor_items, swords, keys := 0, 0, 0, 0
	for seed in 1 ..= u64(8) {
		d, _ := stage_make(t, &s, seed)
		for slot in d.item_slots {
			p := play_start(d, cfg, s.allocator)
			from, ok := free_neighbour(&p, d, slot.pos)
			if !ok || (!slot.chest && slot.item == .None) {
				continue
			}
			p.pos = centre(cfg, from)
			walk_at(&p, d, cfg, centre(cfg, slot.pos), 60)

			testing.expect_value(t, heard(&p, .Chest_Open), int(slot.chest))
			testing.expect_value(t, heard(&p, .Key_Pickup), int(slot.item == .Key))
			testing.expect_value(t, heard(&p, .Sword_Pickup), int(slot.item == .Sword))
			if slot.chest {
				// The lid creaks at the chest, not at the knight's feet.
				for event in sounds_pending(&p) {
					if event.kind == .Chest_Open {
						testing.expect_value(t, event.pos, centre(cfg, slot.pos))
					}
				}
			}
			chests += int(slot.chest)
			floor_items += int(!slot.chest)
			swords += int(slot.item == .Sword)
			keys += int(slot.item == .Key)
		}
	}
	testing.expect(t, chests > 0 && floor_items > 0 && swords > 0 && keys > 0)

	// Doors: an unlocked one opens with one sound; a locked one rattles once
	// however long the knight leans on it, and opens once the key is held.
	opened, rattled := 0, 0
	for seed in 1 ..= u64(6) {
		d, _ := stage_make(t, &s, seed)
		for conn, ci in d.conns {
			if conn.kind != .Door {
				continue
			}
			// Two doors close together would both be in reach; keep to doors
			// that stand alone so the counts below are about this one.
			alone := true
			for other, oi in d.conns {
				gap := other.pos - conn.pos
				alone &&= oi == ci || other.kind != .Door || abs(gap.x) + abs(gap.y) > 2
			}
			if !alone {
				continue
			}
			front := conn.pos - dir_vec(conn.dir)
			p := play_start(d, cfg, s.allocator)
			if p.solid[front.y * d.w + front.x] {
				continue
			}
			p.pos = centre(cfg, front)
			push := [2]f32{f32(dir_vec(conn.dir).x), f32(dir_vec(conn.dir).y)}
			for _ in 0 ..< 90 {
				play_update(&p, d, cfg, push, STEP)
			}
			if conn.locked {

				testing.expect_value(t, heard(&p, .Door_Locked), 1)
				testing.expect(t, !p.conn_open[ci])
				rattled += 1

				// Stepping back out of reach and coming forward rattles it again.
				sounds_clear(&p)
				p.pos = centre(cfg, front)
				play_update(&p, d, cfg, {}, STEP)
				testing.expect_value(t, p.blocked_by, -1)
				for _ in 0 ..< 30 {
					play_update(&p, d, cfg, push, STEP)
				}

				testing.expect_value(t, heard(&p, .Door_Locked), 1)

				sounds_clear(&p)
				p.has_key[conn.lock_id] = true
				for _ in 0 ..< 10 {
					play_update(&p, d, cfg, push, STEP)
				}
				testing.expect_value(t, heard(&p, .Door_Locked), 0)
			}
			// Other doors may be within reach further on; this one opens once.
			here := 0
			for event in sounds_pending(&p) {
				here += int(event.kind == .Door_Open && event.pos == centre(cfg, conn.pos))
			}
			testing.expect_value(t, here, 1)
			opened += 1
		}
	}
	testing.expect(t, opened > 10 && rattled > 3)
}

@(test)
fights_are_heard :: proc(t: ^testing.T) {
	s: Stage
	defer virtual.arena_destroy(&s.arena)
	if !stage_init(t, &s, true) {
		return
	}
	cfg := &s.cfg
	cfg.enemies.speed = 0.001
	cfg.enemies.health = 2
	cfg.sounds.knight_stride = 0
	d, p := stage_make(t, &s, 5)
	if !testing.expect(t, len(p.enemies) >= 2) {
		return
	}

	// No sword, no swing, no sound.
	testing.expect(t, !play_swing(&p, 1))
	testing.expect_value(t, len(sounds_pending(&p)), 0)

	p.has_sword = true
	p.facing = 0
	target := &p.enemies[0]
	target.pos = p.pos + {0, -2}

	testing.expect(t, play_swing(&p, 1))
	testing.expect_value(t, heard(&p, .Sword_Swing), 1)
	testing.expect(t, !play_swing(&p, 1))
	testing.expect_value(t, heard(&p, .Sword_Swing), 1) // a refused swing is silent

	for _ in 0 ..< 31 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, heard(&p, .Sword_Hit), 1)
	testing.expect_value(t, heard(&p, .Skeleton_Hurt), 1)
	testing.expect_value(t, heard(&p, .Skeleton_Death), 0)
	// It woke up on the way.
	testing.expect_value(t, heard(&p, .Skeleton_Notice), 1)
	for event in sounds_pending(&p) {
		if event.kind == .Sword_Hit {
			// Heard where the blade met bone.
			testing.expect(t, math.abs(event.pos.x - p.pos.x) < 0.1 && event.pos.y < p.pos.y - 1)
		}
	}

	sounds_clear(&p)
	target.pos = p.pos + {0, -2}
	testing.expect(t, play_swing(&p, 1))
	for _ in 0 ..< 31 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, heard(&p, .Sword_Hit), 1)
	testing.expect_value(t, heard(&p, .Skeleton_Death), 1)
	testing.expect_value(t, heard(&p, .Skeleton_Hurt), 0)

	// A swing at thin air whooshes and nothing else. The other skeleton is
	// parked out of the way first.
	sounds_clear(&p)
	p.enemies[1].pos = p.pos + {0, 30}
	p.enemies[1].state = .Dead
	testing.expect(t, play_swing(&p, 1))
	for _ in 0 ..< 31 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, heard(&p, .Sword_Swing), 1)
	testing.expect_value(t, heard(&p, .Sword_Hit), 0)

	// Taking a blow, and the last one.
	sounds_clear(&p)
	p.hurt_left = 0
	testing.expect(t, play_hurt(&p, cfg, 1))
	testing.expect(t, !play_hurt(&p, cfg, 1)) // shrugged off: no second sound
	testing.expect_value(t, heard(&p, .Knight_Hurt), 1)
	testing.expect_value(t, heard(&p, .Knight_Death), 0)
	p.hurt_left = 0
	testing.expect(t, play_hurt(&p, cfg, 100))
	testing.expect_value(t, heard(&p, .Knight_Hurt), 2)
	testing.expect_value(t, heard(&p, .Knight_Death), 1)
}

@(test)
skeletons_are_heard_coming :: proc(t: ^testing.T) {
	s: Stage
	defer virtual.arena_destroy(&s.arena)
	if !stage_init(t, &s, true) {
		return
	}
	cfg := &s.cfg
	cfg.enemies.damage = 0
	cfg.sounds.knight_stride = 0
	tested := 0
	for seed in 1 ..= u64(8) {
		d, p := stage_make(t, &s, seed)
		// Stand three clear cells from a skeleton, in its room.
		placed := false
		for e in p.enemies {
			home := d.enemy_spawns[e.spawn]
			for dir in Dir {
				clear := true
				for step in 1 ..= 3 {
					cell := home.pos + dir_vec(dir) * step
					clear &&= in_bounds(d, cell) && cell_at(d, cell).kind == .Floor && int(cell_at(d, cell).room) == home.room && !p.solid[cell.y * d.w + cell.x]
				}
				if clear && !placed {
					p.pos = centre(cfg, home.pos + dir_vec(dir) * 3)
					placed = true
				}
			}
		}
		if !placed {
			continue
		}
		tested += 1
		for _ in 0 ..< 60 {
			play_update(&p, d, cfg, {}, STEP)
		}
		chasing := 0
		for e in p.enemies {
			chasing += int(e.state != .Idle)
		}
		testing.expect(t, chasing > 0)
		// Each one that woke said so exactly once.
		testing.expect_value(t, heard(&p, .Skeleton_Notice), chasing)
		testing.expect(t, heard(&p, .Skeleton_Step) >= 2, "a skeleton crossing three cells takes steps")
		testing.expect(t, heard(&p, .Skeleton_Attack) >= 1)
		for event in sounds_pending(&p) {
			// Skeleton noises come from the skeletons, not from the knight.
			if event.kind == .Skeleton_Step {
				testing.expect(t, event.pos != p.pos)
			}
		}

		// Unattended, the buffer fills up and stops; it never overruns.
		for _ in 0 ..< 3000 {
			play_update(&p, d, cfg, {}, STEP)
		}
		testing.expect(t, len(sounds_pending(&p)) <= MAX_SOUND_EVENTS)
		sounds_clear(&p)
		testing.expect_value(t, len(sounds_pending(&p)), 0)
	}
	testing.expect(t, tested >= 3)
}

@(test)
finishing_the_dungeon_is_announced_once :: proc(t: ^testing.T) {
	s: Stage
	defer virtual.arena_destroy(&s.arena)
	if !stage_init(t, &s, false) {
		return
	}
	cfg := &s.cfg
	d, p := stage_make(t, &s, 2)
	play_update(&p, d, cfg, {}, STEP)
	testing.expect_value(t, heard(&p, .Dungeon_Explored), 0)

	// Hand the knight everything and show it every room.
	for slot, i in d.item_slots {
		p.slot_taken[i] = true
		_ = slot
	}
	for &seen in p.room_seen {
		seen = true
	}
	p.rooms_seen = len(d.rooms)
	testing.expect(t, play_complete(&p, d))
	for _ in 0 ..< 10 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, heard(&p, .Dungeon_Explored), 1)
}
