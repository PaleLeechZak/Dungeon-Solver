package dungeon

import "core:math"

// Skeletons. One rises at every enemy spawn point when play starts. They
// stand idle until the knight comes within walking reach, then run it down
// and strike. Like the rest of play this is pure simulation.

Enemy_State :: enum u8 {
	Idle,
	Chase,
	Attack, // wind up, strike at attack_windup, recover
	Stagger, // reeling from a sword blow
	Dead,
}

Enemy :: struct {
	pos:        [2]f32,
	facing:     f32, // same convention as Play.facing
	state:      Enemy_State,
	state_time: f32, // seconds spent in the current state
	health:     int,
	spawn:      int, // index into Dungeon.enemy_spawns
	struck:     bool, // the current attack's blow has landed or missed
	hit_time:   f32, // seconds since the sword last struck it
	stride:     f32, // distance run since its last footfall
}

// How brightly something flashes `since` seconds after being hit: full at
// the moment of the blow, fading to nothing over `duration`.
hit_flash :: proc(since, duration: f32) -> f32 {
	if duration <= 0 || since < 0 {
		return 0
	}
	return clamp(1 - since / duration, 0, 1)
}

play_flash :: proc(p: ^Play, cfg: ^Config) -> f32 {
	return hit_flash(p.hurt_time, cfg.play.hit_flash)
}

enemy_flash :: proc(e: Enemy, cfg: ^Config) -> f32 {
	return hit_flash(e.hit_time, cfg.play.hit_flash)
}

ENEMY_TURN_SPEED :: 10 // radians per second
KNOCKBACK :: 0.9 // world units a struck skeleton is shoved
ATTACK_START :: 0.85 // fraction of attack_range at which a skeleton stops and swings
ATTACK_GRACE :: 0.35 // extra reach of a blow already under way, so stepping back an inch does not dodge it

@(private)
enemies_spawn :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, allocator := context.allocator) {
	if !cfg.enemies.enabled {
		return
	}
	p.enemies = make([]Enemy, len(d.enemy_spawns), allocator)
	for spawn, i in d.enemy_spawns {
		at := cell_world(cfg, spawn.pos)
		p.enemies[i] = {
			pos    = {at.x, at.z},
			// Each looks a different way until it has something to look at.
			facing = f32(hash_cell(d.seed, spawn.pos.x, spawn.pos.y, 6) % 8) * math.PI / 4,
			health   = cfg.enemies.health,
			spawn    = i,
			hit_time = 1e6,
		}
	}
}

enemies_alive :: proc(p: ^Play) -> (count: int) {
	for e in p.enemies {
		count += int(e.state != .Dead)
	}
	return
}

// Moves `pos` away from `other` until the two are `distance` apart.
@(private)
push_apart :: proc(pos: ^[2]f32, other: [2]f32, distance: f32) {
	diff := pos^ - other
	dist2 := diff.x * diff.x + diff.y * diff.y
	if dist2 >= distance * distance {
		return
	}
	if dist2 < 1e-8 {
		diff = {1, 0}
		dist2 = 1
	}
	pos^ = other + diff * (distance / math.sqrt(dist2))
}

@(private)
turn_towards :: proc(facing: ^f32, direction: [2]f32, max_step: f32) {
	if direction.x * direction.x + direction.y * direction.y < 1e-8 {
		return
	}
	diff := math.atan2(direction.x, -direction.y) - facing^
	diff -= math.TAU * math.round(diff / math.TAU)
	facing^ += clamp(diff, -max_step, max_step)
	facing^ -= math.TAU * math.round(facing^ / math.TAU)
}

// Whether something can walk through a cell right now. Shut doors and
// anything with a prop on it cannot be walked through.
cell_walkable :: proc(p: ^Play, d: ^Dungeon, cell: [2]int) -> bool {
	if !in_bounds(d, cell) {
		return false
	}
	info := cell_at(d, cell)
	#partial switch info.kind {
	case .Floor, .Open:
		return !p.solid[cell.y * d.w + cell.x]
	case .Door:
		return info.conn >= 0 && p.conn_open[info.conn]
	}
	return false
}

// Fills Play.path with the walking distance from every cell to the knight,
// out to `limit` cells. Skeletons walk downhill on it.
@(private)
path_update :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, limit: i32) {
	for &v in p.path {
		v = -1
	}
	start := world_cell(cfg, p.pos)
	if !in_bounds(d, start) {
		return
	}
	queue := make([dynamic][2]int, context.temp_allocator)
	append(&queue, start)
	p.path[start.y * d.w + start.x] = 0
	for head := 0; head < len(queue); head += 1 {
		cell := queue[head]
		steps := p.path[cell.y * d.w + cell.x]
		if steps >= limit {
			continue
		}
		for dir in Dir {
			next := cell + dir_vec(dir)
			if cell_walkable(p, d, next) && p.path[next.y * d.w + next.x] < 0 {
				p.path[next.y * d.w + next.x] = steps + 1
				append(&queue, next)
			}
		}
	}
}

// Takes health off the knight unless it is still in the grace period after
// the last blow. Returns whether the blow counted.
play_hurt :: proc(p: ^Play, cfg: ^Config, damage: int) -> bool {
	// Nothing touches the knight once the amulet is found.
	if p.dead || p.has_amulet || p.hurt_left > 0 || damage <= 0 {
		return false
	}
	p.health = max(0, p.health - damage)
	p.hurt_left = cfg.play.invulnerable
	p.hurt_time = 0
	sound_emit(p, .Knight_Hurt, p.pos)
	if p.health == 0 {
		p.dead = true
		p.dead_time = 0
		p.swing_left = 0
		sound_emit(p, .Knight_Death, p.pos)
		sound_emit(p, .Game_Lost, p.pos)
	}
	return true
}

// Lands the knight's sword once per swing, at the moment the blade comes
// round: every skeleton within reach and inside the arc ahead is struck.
@(private)
sword_update :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config) {
	if p.swing_left <= 0 || p.swing_landed {
		return
	}
	if p.swing_total - p.swing_left < p.swing_total * cfg.play.sword_hit_time {
		return
	}
	p.swing_landed = true
	ahead := [2]f32{math.sin(p.facing), -math.cos(p.facing)}
	min_cos := math.cos(math.to_radians(cfg.play.sword_arc))
	for &e in p.enemies {
		if e.state == .Dead {
			continue
		}
		to := e.pos - p.pos
		dist := math.sqrt(to.x * to.x + to.y * to.y)
		if dist > cfg.play.sword_reach {
			continue
		}
		// Right on top of the knight counts as in front.
		if dist > 1e-4 && (to.x * ahead.x + to.y * ahead.y) / dist < min_cos {
			continue
		}
		e.health -= cfg.play.sword_damage
		e.state_time = 0
		e.hit_time = 0
		sound_emit(p, .Sword_Hit, e.pos)
		if e.health <= 0 {
			e.health = 0
			e.state = .Dead
			p.kills += 1
			sound_emit(p, .Skeleton_Death, e.pos)
		} else {
			e.state = .Stagger
			sound_emit(p, .Skeleton_Hurt, e.pos)
		}
		if dist > 1e-4 {
			e.pos += to / dist * KNOCKBACK
			resolve_circle(p, d, cfg, &e.pos, cfg.enemies.radius)
		}
	}
}

@(private)
enemies_update :: proc(p: ^Play, d: ^Dungeon, cfg: ^Config, dt: f32) {
	if len(p.enemies) == 0 {
		return
	}
	ec := cfg.enemies
	sight_cells := i32(math.ceil(ec.sight / cfg.tile_size))
	path_update(p, d, cfg, sight_cells)

	for &e, index in p.enemies {
		e.state_time += dt
		e.hit_time += dt
		if e.state == .Dead {
			continue
		}
		to_knight := p.pos - e.pos
		dist := math.sqrt(to_knight.x * to_knight.x + to_knight.y * to_knight.y)
		cell := world_cell(cfg, e.pos)
		steps := in_bounds(d, cell) ? p.path[cell.y * d.w + cell.x] : -1
		noticed := !p.dead && steps >= 0

		switch e.state {
		case .Idle:
			if noticed {
				e.state = .Chase
				e.state_time = 0
				sound_emit(p, .Skeleton_Notice, e.pos)
			}
		case .Chase:
			if !noticed {
				e.state = .Idle
				e.state_time = 0
				break
			}
			if dist <= ec.attack_range * ATTACK_START {
				e.state = .Attack
				e.state_time = 0
				e.struck = false
				sound_emit(p, .Skeleton_Attack, e.pos)
				break
			}
			// In the knight's cell or the one next to it, run straight at it;
			// further off, head for the neighbouring cell that is nearer.
			heading := to_knight
			if steps > 1 {
				best := steps
				for dir in Dir {
					next := cell + dir_vec(dir)
					if !in_bounds(d, next) {
						continue
					}
					value := p.path[next.y * d.w + next.x]
					if value >= 0 && value < best {
						best = value
						centre := cell_world(cfg, next)
						heading = [2]f32{centre.x, centre.z} - e.pos
					}
				}
			}
			length := math.sqrt(heading.x * heading.x + heading.y * heading.y)
			if length > 1e-4 {
				heading /= length
				turn_towards(&e.facing, heading, ENEMY_TURN_SPEED * dt)
				travel := ec.speed * dt
				hops := max(1, int(math.ceil(travel / (ec.radius * 0.5))))
				from := e.pos
				for _ in 0 ..< hops {
					e.pos += heading * (travel / f32(hops))
					resolve_circle(p, d, cfg, &e.pos, ec.radius)
				}
				sound_steps(p, .Skeleton_Step, &e.stride, from, e.pos, cfg.sounds.skeleton_stride)
			}
		case .Attack:
			if e.state_time < ec.attack_windup {
				turn_towards(&e.facing, to_knight, ENEMY_TURN_SPEED * dt)
			} else if !e.struck {
				e.struck = true
				if dist <= ec.attack_range + ATTACK_GRACE {
					play_hurt(p, cfg, ec.damage)
				}
			}
			if e.state_time >= ec.attack_windup + ec.attack_recovery {
				e.state = .Chase
				e.state_time = 0
			}
		case .Stagger:
			if e.state_time >= ec.stagger {
				e.state = .Chase
				e.state_time = 0
			}
		case .Dead:
		}

		// Bodies do not overlap: keep clear of the knight and of each other,
		// then let the walls have the last word.
		push_apart(&e.pos, p.pos, ec.radius + cfg.play.radius)
		for other, j in p.enemies {
			if j != index && other.state != .Dead {
				push_apart(&e.pos, other.pos, ec.radius * 2)
			}
		}
		resolve_circle(p, d, cfg, &e.pos, ec.radius)
	}
}
