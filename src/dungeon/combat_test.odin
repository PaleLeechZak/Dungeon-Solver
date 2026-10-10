package dungeon

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:testing"

@(private = "file")
Arena :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	cfg:       Config,
}

@(private = "file")
arena_init :: proc(t: ^testing.T, a: ^Arena) -> bool {
	if !testing.expect(t, virtual.arena_init_growing(&a.arena) == nil) {
		return false
	}
	a.allocator = virtual.arena_allocator(&a.arena)
	err: string
	ok: bool
	a.cfg, err, ok = config_load(CONFIG_PATH, a.allocator)
	if !testing.expectf(t, ok, "config_load failed: %s", err) {
		return false
	}
	return testing.expect(t, a.cfg.enemies.enabled, "the project config should have skeletons switched on")
}

@(private = "file")
arena_make :: proc(t: ^testing.T, a: ^Arena, seed: u64) -> (^Dungeon, Play) {
	d, err, ok := generate(&a.cfg, seed, a.allocator)
	testing.expectf(t, ok, "generate(%d) failed: %s", seed, err)
	return d, play_start(d, &a.cfg, a.allocator)
}

@(private = "file")
centre_of :: proc(cfg: ^Config, cell: [2]int) -> [2]f32 {
	c := cell_world(cfg, cell)
	return {c.x, c.z}
}

@(private = "file")
distance :: proc(a, b: [2]f32) -> f32 {
	d := a - b
	return math.sqrt(d.x * d.x + d.y * d.y)
}

// How far a circle reaches into the nearest solid thing; <= 0 is clear.
@(private = "file")
depth_in_walls :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, pos: [2]f32, radius: f32) -> f32 {
	boxes := make([dynamic]Box, context.temp_allocator)
	centre := world_cell(cfg, pos)
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			cell_blockers(p, d, cfg, centre + {dx, dy}, &boxes)
		}
	}
	worst := f32(-1e9)
	for box in boxes {
		nearest := [2]f32{clamp(pos.x, box.min.x, box.max.x), clamp(pos.y, box.min.y, box.max.y)}
		worst = max(worst, radius - distance(pos, nearest))
	}
	return worst
}

// Puts the knight on a free cell of a skeleton's room, `cells` away from it
// in a straight line. Returns the skeleton chosen.
@(private = "file")
stand_near_a_skeleton :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, cells: int) -> (enemy: int, ok: bool) {
	for e, i in p.enemies {
		home := d.enemy_spawns[e.spawn]
		for dir in Dir {
			clear := true
			for step in 1 ..= cells {
				cell := home.pos + dir_vec(dir) * step
				clear &&= in_bounds(d, cell) && cell_at(d, cell).kind == .Floor && int(cell_at(d, cell).room) == home.room && !p.solid[cell.y * d.w + cell.x]
			}
			if clear {
				p.pos = centre_of(cfg, home.pos + dir_vec(dir) * cells)
				return i, true
			}
		}
	}
	return -1, false
}

@(test)
a_skeleton_rises_at_every_spawn_point :: proc(t: ^testing.T) {
	a: Arena
	defer virtual.arena_destroy(&a.arena)
	if !arena_init(t, &a) {
		return
	}
	total := 0
	for seed in 1 ..= u64(10) {
		d, p := arena_make(t, &a, seed)
		testing.expect_value(t, len(p.enemies), len(d.enemy_spawns))
		testing.expect_value(t, enemies_alive(&p), len(d.enemy_spawns))
		for e, i in p.enemies {
			testing.expect_value(t, e.pos, centre_of(&a.cfg, d.enemy_spawns[i].pos))
			testing.expect_value(t, e.state, Enemy_State.Idle)
			testing.expect_value(t, e.health, a.cfg.enemies.health)
			testing.expect(t, depth_in_walls(&p, d, &a.cfg, e.pos, a.cfg.enemies.radius) <= 0)
		}
		testing.expect_value(t, p.health, a.cfg.play.health)
		testing.expect_value(t, p.max_health, a.cfg.play.health)
		testing.expect(t, !p.dead)
		total += len(p.enemies)
	}
	testing.expect(t, total > 0)

	a.cfg.enemies.enabled = false
	_, quiet := arena_make(t, &a, 1)
	testing.expect_value(t, len(quiet.enemies), 0)
}

@(test)
shut_doors_keep_skeletons_out :: proc(t: ^testing.T) {
	a: Arena
	defer virtual.arena_destroy(&a.arena)
	if !arena_init(t, &a) {
		return
	}
	for seed in 1 ..= u64(6) {
		d, p := arena_make(t, &a, seed)
		// The knight stands at the entrance and touches nothing for ten seconds.
		for _ in 0 ..< 300 {
			play_update(&p, d, &a.cfg, {}, STEP)
		}
		for e, i in p.enemies {
			testing.expectf(t, e.state == .Idle, "seed %d: skeleton %d is %v behind shut doors", seed, i, e.state)
			testing.expect_value(t, e.pos, centre_of(&a.cfg, d.enemy_spawns[i].pos))
		}
		testing.expect_value(t, p.health, p.max_health)

		// The walking-distance field stops at shut doors and starts at the knight.
		here := world_cell(&a.cfg, p.pos)
		testing.expect_value(t, p.path[here.y * d.w + here.x], 0)
		for conn in d.conns {
			if conn.kind == .Door {
				testing.expect(t, !cell_walkable(&p, d, conn.pos))
				testing.expect_value(t, p.path[conn.pos.y * d.w + conn.pos.x], -1)
			}
		}
	}
}

@(test)
skeletons_chase_and_strike :: proc(t: ^testing.T) {
	a: Arena
	defer virtual.arena_destroy(&a.arena)
	if !arena_init(t, &a) {
		return
	}
	cfg := &a.cfg
	tested := 0
	for seed in 1 ..= u64(8) {
		d, p := arena_make(t, &a, seed)
		enemy, ok := stand_near_a_skeleton(&p, d, cfg, 2)
		if !ok {
			continue
		}
		tested += 1
		start := distance(p.pos, p.enemies[enemy].pos)

		// It notices at once and closes in.
		play_update(&p, d, cfg, {}, STEP)
		testing.expect_value(t, p.enemies[enemy].state, Enemy_State.Chase)
		// However close another skeleton of the room happens to stand, no
		// blow can land before its wind-up is over.
		for _ in 0 ..< int(cfg.enemies.attack_windup / STEP) - 2 {
			play_update(&p, d, cfg, {}, STEP)
		}
		testing.expect(t, distance(p.pos, p.enemies[enemy].pos) < start - 1, "the skeleton did not come closer")
		testing.expect_value(t, p.health, p.max_health)

		// Standing still, the knight is cut down one pip at a time.
		elapsed := f32(int(cfg.enemies.attack_windup / STEP) - 1) * STEP
		last_hurt := f32(-100)
		health := p.health
		for step := 0; step < 3000 && !p.dead; step += 1 {
			play_update(&p, d, cfg, {}, STEP)
			elapsed += STEP
			if p.health < health {
				testing.expect_value(t, p.health, health - cfg.enemies.damage)
				testing.expectf(
					t,
					elapsed - last_hurt >= cfg.play.invulnerable - 2 * STEP,
					"seed %d: hurt again after only %v s",
					seed,
					elapsed - last_hurt,
				)
				testing.expect(t, p.hurt_time < STEP * 2)
				last_hurt = elapsed
				health = p.health
			}
			// Nobody ends up inside anybody else or inside a wall.
			for e in p.enemies {
				if e.state == .Dead {
					continue
				}
				testing.expect(t, distance(e.pos, p.pos) > cfg.enemies.radius + cfg.play.radius - 0.05) or_break
				testing.expect(t, depth_in_walls(&p, d, cfg, e.pos, cfg.enemies.radius) < 1e-3) or_break
			}
		}
		testing.expectf(t, p.dead, "seed %d: the knight survived a skeleton standing on it", seed)
		testing.expect_value(t, p.health, 0)
		testing.expect(t, elapsed > cfg.enemies.attack_windup)

		// With the knight down the skeletons lose interest.
		for _ in 0 ..< 90 {
			play_update(&p, d, cfg, {1, 0}, STEP)
		}
		for e in p.enemies {
			testing.expect(t, e.state == .Idle, "a skeleton is still after the dead knight")
		}
		testing.expect(t, p.dead_time > 2.5)
		testing.expect(t, !p.moving, "the dead do not walk")
	}
	testing.expect(t, tested >= 3)
}

@(test)
being_hurt_buys_a_moment_of_grace :: proc(t: ^testing.T) {
	a: Arena
	defer virtual.arena_destroy(&a.arena)
	if !arena_init(t, &a) {
		return
	}
	cfg := &a.cfg
	d, p := arena_make(t, &a, 2)

	testing.expect(t, !play_hurt(&p, cfg, 0))
	testing.expect(t, play_hurt(&p, cfg, 1))
	testing.expect_value(t, p.health, cfg.play.health - 1)
	testing.expect(t, !play_hurt(&p, cfg, 1), "a second blow straight away is shrugged off")
	testing.expect_value(t, p.health, cfg.play.health - 1)

	for _ in 0 ..< int(cfg.play.invulnerable / STEP) + 2 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect(t, play_hurt(&p, cfg, 1))
	testing.expect_value(t, p.health, cfg.play.health - 2)

	// A blow bigger than what is left takes it to nothing, not below.
	p.hurt_left = 0
	p.has_sword = true
	testing.expect(t, play_swing(&p, 1))
	testing.expect(t, play_hurt(&p, cfg, 100))
	testing.expect_value(t, p.health, 0)
	testing.expect(t, p.dead)
	testing.expect_value(t, p.swing_left, 0)
	testing.expect(t, !play_swing(&p, 1), "the dead swing no swords")
	testing.expect(t, !play_hurt(&p, cfg, 1))

	at := p.pos
	play_update(&p, d, cfg, {1, 0}, 0.5)
	testing.expect_value(t, p.pos, at)
}

@(test)
the_sword_strikes_what_is_in_front :: proc(t: ^testing.T) {
	a: Arena
	defer virtual.arena_destroy(&a.arena)
	if !arena_init(t, &a) {
		return
	}
	cfg := &a.cfg
	// Skeletons that neither hurt nor wander, so only the sword changes things.
	cfg.enemies.damage = 0
	cfg.enemies.speed = 0.001
	cfg.enemies.health = 2
	d, p := arena_make(t, &a, 5)
	if !testing.expect(t, len(p.enemies) >= 3) {
		return
	}
	p.has_sword = true
	p.facing = 0 // north
	front, behind, far := &p.enemies[0], &p.enemies[1], &p.enemies[2]
	front.pos = p.pos + {0, -2}
	behind.pos = p.pos + {0, 2}
	far.pos = p.pos + {0, -(cfg.play.sword_reach + 1.5)}

	testing.expect(t, play_swing(&p, 1))
	play_update(&p, d, cfg, {}, STEP)
	testing.expect_value(t, front.health, 2) // the blade has not come round yet
	testing.expect(t, !p.swing_landed)

	for _ in 0 ..< 14 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect(t, p.swing_landed)
	testing.expect_value(t, front.health, 1)
	testing.expect_value(t, front.state, Enemy_State.Stagger)
	testing.expect(t, front.pos.y < p.pos.y - 2.5, "a struck skeleton is knocked back")
	testing.expect_value(t, behind.health, 2)
	testing.expect_value(t, far.health, 2)
	testing.expect_value(t, p.kills, 0)

	// One swing, one blow: the rest of the animation does no more harm.
	for _ in 0 ..< 20 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, front.health, 1)
	testing.expect_value(t, p.swing_left, 0)
	// It has shaken the blow off by now.
	testing.expect(t, front.state != .Stagger)

	// The second blow finishes it.
	front.pos = p.pos + {0, -2}
	testing.expect(t, play_swing(&p, 1))
	for _ in 0 ..< 31 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, front.health, 0)
	testing.expect_value(t, front.state, Enemy_State.Dead)
	testing.expect_value(t, p.kills, 1)
	testing.expect_value(t, enemies_alive(&p), len(p.enemies) - 1)

	// The dead stay dead and stay put.
	corpse := front.pos
	for _ in 0 ..< 60 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, front.state, Enemy_State.Dead)
	testing.expect_value(t, front.pos, corpse)
	testing.expect(t, front.state_time > 2)

	// A corpse is not struck again, and does not get in the way.
	testing.expect(t, play_swing(&p, 1))
	for _ in 0 ..< 31 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, p.kills, 1)

	// Turning round brings the one behind into the arc.
	p.facing = math.PI
	behind.pos = p.pos + {0, 2}
	for _ in 0 ..< 2 {
		testing.expect(t, play_swing(&p, 1))
		for _ in 0 ..< 31 {
			play_update(&p, d, cfg, {}, STEP)
		}
		behind.pos = p.pos + {0, 2}
	}
	testing.expect_value(t, behind.state, Enemy_State.Dead)
	testing.expect_value(t, p.kills, 2)
	testing.expect_value(t, far.health, 2)

	// To the side, outside the arc, is safe from a swing straight ahead.
	p.facing = 0
	far.pos = p.pos + {2, 0.2}
	testing.expect(t, play_swing(&p, 1))
	for _ in 0 ..< 31 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, far.health, 2)
}

// A knight running about an encounter room with skeletons after it: whatever
// happens, nothing ends up inside a wall or outside the dungeon.
@(test)
a_running_fight_stays_inside_the_room :: proc(t: ^testing.T) {
	a: Arena
	defer virtual.arena_destroy(&a.arena)
	if !arena_init(t, &a) {
		return
	}
	cfg := &a.cfg
	cfg.enemies.damage = 0 // the knight has to live through the whole test
	chased := 0
	for seed in 1 ..= u64(6) {
		d, p := arena_make(t, &a, seed)
		if _, ok := stand_near_a_skeleton(&p, d, cfg, 1); !ok {
			continue
		}
		p.has_sword = true
		rng := rng_make(seed * 131)
		move: [2]f32
		for step in 0 ..< 2500 {
			if step % 25 == 0 {
				move = {rng_float(&rng) * 2 - 1, rng_float(&rng) * 2 - 1}
			}
			if step % 40 == 0 {
				play_swing(&p, 0.6)
			}
			play_update(&p, d, cfg, move, 0.004 + rng_float(&rng) * 0.08)

			testing.expectf(t, depth_in_walls(&p, d, cfg, p.pos, cfg.play.radius) < 1e-3, "seed %d: the knight is inside a wall at %v", seed, p.pos) or_break
			bad := false
			for e, i in p.enemies {
				cell := world_cell(cfg, e.pos)
				bad ||= !testing.expectf(t, in_bounds(d, cell) && cell_at(d, cell).kind != .Empty, "seed %d: skeleton %d left the dungeon at %v", seed, i, e.pos)
				bad ||= !testing.expectf(t, depth_in_walls(&p, d, cfg, e.pos, cfg.enemies.radius) < 1e-3, "seed %d: skeleton %d is inside a wall at %v", seed, i, e.pos)
				testing.expect(t, e.health >= 0)
				chased += int(e.state == .Chase)
			}
			if bad {
				break
			}
		}
		testing.expect_value(t, p.health, p.max_health)
		testing.expect_value(t, p.kills, len(p.enemies) - enemies_alive(&p))
	}
	testing.expect(t, chased > 0, "no skeleton ever gave chase")
}

@(test)
a_hit_flashes_and_fades :: proc(t: ^testing.T) {
	testing.expect_value(t, hit_flash(0, 0.2), 1)
	testing.expect(t, abs(hit_flash(0.1, 0.2) - 0.5) < 1e-5)
	testing.expect_value(t, hit_flash(0.2, 0.2), 0)
	testing.expect_value(t, hit_flash(5, 0.2), 0)
	testing.expect_value(t, hit_flash(0, 0), 0) // switched off in the config
	testing.expect_value(t, hit_flash(-1, 0.2), 0)

	a: Arena
	defer virtual.arena_destroy(&a.arena)
	if !arena_init(t, &a) {
		return
	}
	cfg := &a.cfg
	cfg.enemies.damage = 0
	cfg.enemies.speed = 0.001
	d, p := arena_make(t, &a, 5)
	if !testing.expect(t, len(p.enemies) >= 2) {
		return
	}

	// Nobody flashes before anything has happened.
	testing.expect_value(t, play_flash(&p, cfg), 0)
	for e in p.enemies {
		testing.expect_value(t, enemy_flash(e, cfg), 0)
	}

	// The knight: full flash on the blow, gone a moment later, and a blow
	// shrugged off during the grace period does not flash again.
	testing.expect(t, play_hurt(&p, cfg, 1))
	testing.expect_value(t, play_flash(&p, cfg), 1)
	play_update(&p, d, cfg, {}, cfg.play.hit_flash / 2)
	mid := play_flash(&p, cfg)
	testing.expect(t, mid > 0.3 && mid < 0.7)
	testing.expect(t, !play_hurt(&p, cfg, 1))
	testing.expect(t, play_flash(&p, cfg) <= mid)
	play_update(&p, d, cfg, {}, cfg.play.hit_flash)
	testing.expect_value(t, play_flash(&p, cfg), 0)

	// A skeleton: only the one the sword reaches lights up.
	p.has_sword = true
	p.facing = 0
	struck, spared := &p.enemies[0], &p.enemies[1]
	struck.pos = p.pos + {0, -2}
	spared.pos = p.pos + {0, 2}
	testing.expect(t, play_swing(&p, 1))
	flashed := false
	for _ in 0 ..< 30 {
		play_update(&p, d, cfg, {}, STEP)
		if p.swing_landed && !flashed {
			flashed = true
			// The frame the blade lands is the brightest.
			testing.expect(t, enemy_flash(struck^, cfg) > 0.8)
		}
		testing.expect_value(t, enemy_flash(spared^, cfg), 0)
	}
	testing.expect(t, flashed)
	testing.expect_value(t, enemy_flash(struck^, cfg), 0) // long faded by the end of the swing

	// The killing blow flashes too, on the way down.
	struck.pos = p.pos + {0, -2}
	testing.expect(t, play_swing(&p, 1))
	for _ in 0 ..< 13 {
		play_update(&p, d, cfg, {}, STEP)
	}
	testing.expect_value(t, struck.state, Enemy_State.Dead)
	testing.expect(t, enemy_flash(struck^, cfg) > 0.5)
}