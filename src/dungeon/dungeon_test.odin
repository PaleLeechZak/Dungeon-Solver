package dungeon

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

CONFIG_PATH :: #directory + "/../../config/dungeon.json5"
SEEDS :: 60

// Everything the library allocates in a test comes out of one arena.
@(private = "file")
Fixture :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	cfg:       Config,
}

@(private = "file")
fixture_init :: proc(t: ^testing.T, f: ^Fixture) -> bool {
	if !testing.expect(t, virtual.arena_init_growing(&f.arena) == nil) {
		return false
	}
	f.allocator = virtual.arena_allocator(&f.arena)
	err: string
	ok: bool
	f.cfg, err, ok = config_load(CONFIG_PATH, f.allocator)
	return testing.expectf(t, ok, "config_load failed: %s", err)
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	virtual.arena_destroy(&f.arena)
}

@(private = "file")
must_generate :: proc(t: ^testing.T, f: ^Fixture, seed: u64) -> ^Dungeon {
	d, err, ok := generate(&f.cfg, seed, f.allocator)
	testing.expectf(t, ok, "generate(%d) failed: %s", seed, err)
	return d
}

MINIMAL_CONFIG :: `{
	"props": {"chest": "c", "chest_lid": "l"}, "items": {"key": {"model": "k"}, "swords": 0}, "assets": {"manifest": "m"}, 
	"tiles": {"wall": ["wall"], "corner": "wall_corner", "tsplit": "wall_Tsplit", "crossing": "wall_crossing", "doorway": "wall_doorway", "door": "door"},
	"floors": {"stone": ["floor_tile_large"]},
	"rooms": [
		{"name": "start", "kind": "entrance", "layout": ["#D#", "#P#", "###"]}
	]
}`

// ---------------------------------------------------------------- rng

@(test)
rng_is_deterministic :: proc(t: ^testing.T) {
	a, b := rng_make(42), rng_make(42)
	c := rng_make(43)
	differs := false
	for _ in 0 ..< 100 {
		va := rng_next(&a)
		testing.expect_value(t, va, rng_next(&b))
		differs ||= va != rng_next(&c)
	}
	testing.expect(t, differs)
}

@(test)
rng_stays_in_range :: proc(t: ^testing.T) {
	r := rng_make(7)
	seen: [5]bool
	for _ in 0 ..< 500 {
		v := rng_range(&r, 3, 7)
		testing.expect(t, v >= 3 && v <= 7)
		seen[v - 3] = true
		f := rng_float(&r)
		testing.expect(t, f >= 0 && f < 1)
	}
	testing.expect_value(t, seen, [5]bool{true, true, true, true, true})
	testing.expect_value(t, rng_int(&r, 0), 0)
	testing.expect(t, !rng_chance(&r, 0))
	testing.expect(t, rng_chance(&r, 1))
}

// ---------------------------------------------------------------- templates

@(test)
template_parses_perimeter_and_nodes :: proc(t: ^testing.T) {
	rows := []string{"##D###", "#.E..~", "D..I.~", "#.b..#", "######"}
	decor := make(map[string][]string, context.temp_allocator)
	decor["b"] = {"barrel_large"}
	tmpl, err, ok := template_parse(rows, decor, context.temp_allocator)
	if !testing.expectf(t, ok, "parse failed: %s", err) {
		return
	}

	testing.expect_value(t, tmpl.w, 6)
	testing.expect_value(t, tmpl.h, 5)
	testing.expect_value(t, len(tmpl.nodes), 3)
	testing.expect_value(t, tmpl.nodes[0], Template_Node{kind = .Door, pos = {2, 0}, dir = .N, width = 1})
	testing.expect_value(t, tmpl.nodes[1], Template_Node{kind = .Open, pos = {5, 1}, dir = .E, width = 2})
	testing.expect_value(t, tmpl.nodes[2], Template_Node{kind = .Door, pos = {0, 2}, dir = .W, width = 1})

	testing.expect_value(t, len(tmpl.enemy_spawns), 1)
	testing.expect_value(t, tmpl.enemy_spawns[0], [2]int{2, 1})
	testing.expect_value(t, len(tmpl.item_slots), 1)
	testing.expect_value(t, tmpl.item_slots[0], Template_Slot{pos = {3, 2}, chest = true})
	testing.expect_value(t, len(tmpl.decor), 1)
	testing.expect_value(t, tmpl.decor[0].key, "b")
	testing.expect(t, !tmpl.has_player_spawn)

	// Corners join the two straight sections that meet there.
	testing.expect_value(t, tmpl.arms[0], Dirs{.E, .S})
	testing.expect_value(t, tmpl.arms[5], Dirs{.W, .S})
	testing.expect_value(t, tmpl.arms[4 * 6], Dirs{.E, .N})
	testing.expect_value(t, tmpl.arms[4 * 6 + 5], Dirs{.W, .N})
	testing.expect_value(t, tmpl.arms[1], Dirs{.E, .W})
	testing.expect_value(t, tmpl.arms[3 * 6], Dirs{.N, .S})
	testing.expect_value(t, tmpl.cells[1 * 6 + 5], Template_Cell.Open)
	testing.expect_value(t, tmpl.arms[1 * 6 + 5], Dirs{})
	testing.expect_value(t, tmpl.cells[2 * 6 + 2], Template_Cell.Floor)
}

@(test)
template_rejects_bad_layouts :: proc(t: ^testing.T) {
	bad := [][]string {
		{"###", "#.#"}, // too few rows
		{"##", "##", "##"}, // too few columns
		{"###", "#.", "###"}, // ragged
		{"D##", "#.#", "###"}, // door on a corner
		{"#~#", "#.#", "##~"}, // missing wall on a corner
		{"#x#", "#.#", "###"}, // unknown perimeter character
		{"####", "#.D#", "####"}, // door inside the room
		{"###", "#?#", "###"}, // unknown decor
		{"####", "#PP#", "####"}, // two player spawns
	}
	for rows in bad {
		_, _, ok := template_parse(rows, nil, context.temp_allocator)
		testing.expectf(t, !ok, "layout %v should be rejected", rows)
	}
}

@(test)
rotation_turns_north_to_east :: proc(t: ^testing.T) {
	rows := []string{"#D##", "#..#", "#..~", "####"}
	rotated := rotate_rows(rows, context.temp_allocator)
	testing.expect_value(t, len(rotated), 4)
	testing.expect_value(t, rotated[0], "####")
	testing.expect_value(t, rotated[1], "#..D")
	testing.expect_value(t, rotated[2], "#..#")
	testing.expect_value(t, rotated[3], "#~##")

	tmpl, _, ok := template_parse(rotated, nil, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, tmpl.nodes[0], Template_Node{kind = .Door, pos = {3, 1}, dir = .E, width = 1})
	testing.expect_value(t, tmpl.nodes[1], Template_Node{kind = .Open, pos = {1, 3}, dir = .S, width = 1})

	// Four quarter turns are the identity, also for non-square layouts.
	wide := []string{"##D####", "#.....~", "#######"}
	back := wide
	for _ in 0 ..< 4 {
		back = rotate_rows(back, context.temp_allocator)
	}
	for row, i in wide {
		testing.expect_value(t, back[i], row)
	}
	testing.expect_value(t, len(rotate_rows(wide, context.temp_allocator)), 7)
}

@(test)
hallways_are_one_tile_wide_with_end_doors :: proc(t: ^testing.T) {
	rng := rng_make(99)
	side_doors := 0
	for length in 1 ..= 9 {
		rows := hallway_rows(length, 0.5, &rng, context.temp_allocator)
		testing.expect_value(t, len(rows), 3)
		testing.expect_value(t, len(rows[1]), length + 2)
		testing.expect_value(t, rows[1][0], u8('D'))
		testing.expect_value(t, rows[1][length + 1], u8('D'))
		for x in 1 ..= length {
			testing.expect_value(t, rows[1][x], u8('.'))
		}
		tmpl, err, ok := template_parse(rows, nil, context.temp_allocator)
		testing.expectf(t, ok, "hallway failed to parse: %s", err) or_continue
		ends := 0
		for node in tmpl.nodes {
			testing.expect_value(t, node.kind, Node_Kind.Door)
			if node.dir == .E || node.dir == .W {
				ends += 1
			} else {
				side_doors += 1
			}
		}
		testing.expect_value(t, ends, 2)
	}
	testing.expect(t, side_doors > 0, "a 50% side door chance should produce side doors")

	plain := hallway_rows(6, 0, &rng, context.temp_allocator)
	testing.expect_value(t, plain[0], "########")
	testing.expect_value(t, plain[2], "########")
}

// ---------------------------------------------------------------- config

@(test)
project_config_is_valid :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}

	testing.expect(t, len(f.cfg.rooms) > 0)
	entrances, encounters, with_open_walls := 0, 0, 0
	for room in f.cfg.rooms {
		kind, ok := room_kind_parse(room.kind)
		testing.expect(t, ok)
		entrances += int(kind == .Entrance)
		encounters += int(kind == .Encounter)
		for row in room.layout {
			if strings.contains_rune(row, '~') {
				with_open_walls += 1
				break
			}
		}
	}
	testing.expect(t, entrances >= 1)
	testing.expect(t, encounters >= 1)
	testing.expect(t, with_open_walls >= 2, "odd-shaped rooms need at least two rooms with missing walls")
	testing.expect(t, f.cfg.hallways.count > 0)
}

@(test)
config_keeps_defaults_for_missing_fields :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, virtual.arena_init_growing(&f.arena) == nil) {
		return
	}
	defer fixture_destroy(&f)
	allocator := virtual.arena_allocator(&f.arena)

	// Hallways default to on, so they are switched off rather than given a floor.
	text := `{"size": {"width": 20}, "hallways": {"count": 0}, ` + MINIMAL_CONFIG[1:]
	cfg, err, ok := config_parse(transmute([]byte)string(text), allocator)
	if !testing.expectf(t, ok, "minimal config rejected: %s", err) {
		return
	}

	defaults := config_default()
	testing.expect_value(t, cfg.size.width, 20)
	testing.expect_value(t, cfg.size.height, defaults.size.height)
	testing.expect_value(t, cfg.tile_size, defaults.tile_size)
	testing.expect_value(t, cfg.generation.max_rooms, defaults.generation.max_rooms)
	testing.expect_value(t, cfg.generation.allow_rotation, true)
	testing.expect_value(t, cfg.camera.speed, defaults.camera.speed)
	testing.expect_value(t, cfg.hallways.max_length, defaults.hallways.max_length)
	testing.expect_value(t, cfg.assets.texture, defaults.assets.texture)
}

@(test)
config_rejects_invalid_input :: proc(t: ^testing.T) {
	f: Fixture
	if !testing.expect(t, virtual.arena_init_growing(&f.arena) == nil) {
		return
	}
	defer fixture_destroy(&f)
	allocator := virtual.arena_allocator(&f.arena)

	HALLWAYS_OFF :: `"hallways": {"count": 0}, `
	TILES :: `"tiles": {"wall": ["wall"], "corner": "c", "tsplit": "t", "crossing": "x", "doorway": "d", "door": "l"}, "floors": {"stone": ["f"]}, "props": {"chest": "c", "chest_lid": "l"}, "items": {"key": {"model": "k"}, "swords": 0}, "assets": {"manifest": "m"}, `
	cases := []string {
		`{ not json`,
		`{` + HALLWAYS_OFF + TILES + `"rooms": []}`,
		// no entrance
		`{` + HALLWAYS_OFF + TILES + `"rooms": [{"name": "a", "layout": ["#D#", "#.#", "###"]}]}`,
		// player spawn outside an entrance
		`{` + HALLWAYS_OFF + TILES + `"rooms": [{"name": "a", "layout": ["#D#", "#P#", "###"]}]}`,
		// entrance without a way out
		`{` + HALLWAYS_OFF + TILES + `"rooms": [{"name": "a", "kind": "entrance", "layout": ["###", "#P#", "###"]}]}`,
		// encounter without enemies
		`{` + HALLWAYS_OFF + TILES + `"rooms": [{"name": "a", "kind": "entrance", "layout": ["#D#", "#P#", "###"]}, {"name": "b", "kind": "encounter", "layout": ["#D#", "#.#", "###"]}]}`,
		// unknown kind
		`{` + HALLWAYS_OFF + TILES + `"rooms": [{"name": "a", "kind": "boss", "layout": ["#D#", "#P#", "###"]}]}`,
		// unknown floor set
		`{` + HALLWAYS_OFF + TILES + `"rooms": [{"name": "a", "kind": "entrance", "floor": "lava", "layout": ["#D#", "#P#", "###"]}]}`,
		// grid too small
		`{"size": {"width": 2, "height": 2}, ` + HALLWAYS_OFF + TILES + `"rooms": [{"name": "a", "kind": "entrance", "layout": ["#D#", "#P#", "###"]}]}`,
		// reserved decor key
		`{"decor": {"E": ["barrel"]}, ` + HALLWAYS_OFF + TILES + `"rooms": [{"name": "a", "kind": "entrance", "layout": ["#D#", "#P#", "###"]}]}`,
		// hallway lengths the wrong way round
		`{"hallways": {"count": 2, "min_length": 5, "max_length": 2}, ` + TILES + `"rooms": [{"name": "a", "kind": "entrance", "layout": ["#D#", "#P#", "###"]}]}`,
		// no wall models
		`{` + HALLWAYS_OFF + `"tiles": {"wall": [], "corner": "c", "tsplit": "t", "crossing": "x", "doorway": "d", "door": "l"}, "floors": {"stone": ["f"]}, "props": {"chest": "c", "chest_lid": "l"}, "items": {"key": {"model": "k"}, "swords": 0}, "assets": {"manifest": "m"}, "rooms": [{"name": "a", "kind": "entrance", "layout": ["#D#", "#P#", "###"]}]}`,
	}
	for text in cases {
		_, err, ok := config_parse(transmute([]byte)text, allocator)
		testing.expectf(t, !ok, "config should be rejected: %s", text)
		testing.expectf(t, ok || err != "", "rejection needs a message: %s", text)
	}
}

// ---------------------------------------------------------------- generation

@(test)
same_seed_gives_same_dungeon :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}

	a := dungeon_to_ascii(must_generate(t, &f, 1234), f.allocator)
	b := dungeon_to_ascii(must_generate(t, &f, 1234), f.allocator)
	c := dungeon_to_ascii(must_generate(t, &f, 1235), f.allocator)
	testing.expect(t, a == b, "the same seed must reproduce the same dungeon")
	testing.expect(t, a != c, "different seeds should give different dungeons")
}

@(test)
dungeon_is_a_tree_rooted_at_the_entrance :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}

	for seed in 1 ..= u64(SEEDS) {
		d := must_generate(t, &f, seed)
		testing.expect(t, len(d.rooms) >= 1) or_continue
		testing.expectf(t, len(d.rooms) <= f.cfg.generation.max_rooms, "seed %d: %d rooms", seed, len(d.rooms))
		testing.expect_value(t, len(d.conns), len(d.rooms) - 1)

		entrances := 0
		for room, i in d.rooms {
			tmpl := d.templates[room.template]
			testing.expect_value(t, room.kind, tmpl.kind)
			entrances += int(room.kind == .Entrance)
			testing.expectf(
				t,
				room.pos.x >= 0 && room.pos.y >= 0 && room.pos.x + tmpl.w <= d.w && room.pos.y + tmpl.h <= d.h,
				"seed %d: room %d leaves the %dx%d grid",
				seed,
				i,
				d.w,
				d.h,
			)
			if i == 0 {
				testing.expect_value(t, room.kind, Room_Kind.Entrance)
				testing.expect_value(t, room.parent, -1)
				testing.expect_value(t, room.entry_conn, -1)
				testing.expect_value(t, room.depth, 0)
				continue
			}
			testing.expect(t, room.parent >= 0 && room.parent < i, "parents are generated before their children") or_continue
			testing.expect_value(t, room.depth, d.rooms[room.parent].depth + 1)
			conn := d.conns[room.entry_conn]
			testing.expect_value(t, conn.to, i)
			testing.expect_value(t, conn.from, room.parent)
		}
		testing.expect_value(t, entrances, 1)

		// The player starts on a floor tile of the entrance room.
		spawn := cell_at(d, d.player_spawn)
		testing.expect_value(t, spawn.kind, Cell_Kind.Floor)
		testing.expect_value(t, spawn.room, 0)
		entrance := d.templates[d.rooms[0].template]
		testing.expect_value(t, d.player_spawn, d.rooms[0].pos + entrance.player_spawn)
	}
}

@(test)
rooms_only_overlap_on_their_walls :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}

	for seed in 1 ..= u64(SEEDS) {
		d := must_generate(t, &f, seed)
		floor_owners := make([]int, d.w * d.h, context.temp_allocator)
		covered := make([]bool, d.w * d.h, context.temp_allocator)
		for room in d.rooms {
			tmpl := d.templates[room.template]
			for ty in 0 ..< tmpl.h {
				for tx in 0 ..< tmpl.w {
					i := (room.pos.y + ty) * d.w + room.pos.x + tx
					covered[i] = true
					if tmpl.cells[ty * tmpl.w + tx] == .Floor {
						floor_owners[i] += 1
					}
				}
			}
		}
		for cell, i in d.cells {
			testing.expectf(t, covered[i] == (cell.kind != .Empty), "seed %d: cell %d coverage mismatch", seed, i)
			switch cell.kind {
			case .Floor:
				testing.expectf(t, floor_owners[i] == 1, "seed %d: floor cell %d has %d owners", seed, i, floor_owners[i])
			case .Wall, .Door, .Open:
				testing.expectf(t, floor_owners[i] == 0, "seed %d: a room's floor runs through wall cell %d", seed, i)
			case .Empty:
			}
			if cell.kind == .Wall {
				testing.expectf(t, card(cell.arms) >= 2, "seed %d: wall cell %d has arms %v", seed, i, cell.arms)
			}
		}
	}
}

@(test)
doors_and_openings_join_two_rooms :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}

	merges := 0
	for seed in 1 ..= u64(SEEDS) {
		d := must_generate(t, &f, seed)

		// No node is left dangling: every door cell belongs to a connection.
		for cell, i in d.cells {
			if cell.kind == .Door || cell.kind == .Open {
				testing.expectf(t, cell.conn >= 0, "seed %d: cell %d is an unconnected %v", seed, i, cell.kind)
			} else {
				testing.expect_value(t, cell.conn, -1)
			}
		}

		for conn, ci in d.conns {
			from_node := room_template(d, conn.from).nodes[conn.from_node]
			to_node := room_template(d, conn.to).nodes[conn.to_node]
			testing.expect_value(t, from_node.kind, conn.kind)
			testing.expect_value(t, to_node.kind, conn.kind)
			testing.expect_value(t, to_node.dir, dir_opposite(from_node.dir))
			// A room missing N walls is only ever filled by a room missing the same N walls.
			testing.expect_value(t, to_node.width, from_node.width)
			testing.expect_value(t, d.rooms[conn.from].pos + from_node.pos, conn.pos)
			testing.expect_value(t, d.rooms[conn.to].pos + to_node.pos, conn.pos)
			testing.expect_value(t, d.rooms[conn.from].node_conn[conn.from_node], ci)
			testing.expect_value(t, d.rooms[conn.to].node_conn[conn.to_node], ci)
			if conn.kind == .Door {
				testing.expect_value(t, conn.width, 1)
			} else {
				merges += 1
				testing.expect(t, !conn.locked, "there is no door to lock on a merged wall")
			}

			axis := node_axis(conn.dir)
			step := dir_vec(conn.dir)
			for i in 0 ..< conn.width {
				pos := conn.pos + axis * i
				cell := cell_at(d, pos)
				testing.expect_value(t, cell.kind, conn.kind == .Door ? Cell_Kind.Door : Cell_Kind.Open)
				testing.expect_value(t, int(cell.conn), ci)
				// Floor of the two joined rooms lies on either side.
				behind, ahead := cell_at(d, pos - step), cell_at(d, pos + step)
				testing.expect_value(t, behind.kind, Cell_Kind.Floor)
				testing.expect_value(t, ahead.kind, Cell_Kind.Floor)
				testing.expect_value(t, int(behind.room), conn.from)
				testing.expect_value(t, int(ahead.room), conn.to)
			}
		}
	}
	testing.expect(t, merges > 0, "no seed produced a merged, odd-shaped room")
}

@(test)
hallways_and_encounters_are_generated :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}

	total: Stats
	for seed in 1 ..= u64(SEEDS) {
		d := must_generate(t, &f, seed)
		s := stats(d)
		total.by_kind += s.by_kind
		total.enemy_spawns += s.enemy_spawns
		total.item_slots += s.item_slots

		spawns_per_room := make([]int, len(d.rooms), context.temp_allocator)
		for spawn in d.enemy_spawns {
			spawns_per_room[spawn.room] += 1
			cell := cell_at(d, spawn.pos)
			testing.expect_value(t, cell.kind, Cell_Kind.Floor)
			testing.expect_value(t, int(cell.room), spawn.room)
		}
		for slot in d.item_slots {
			cell := cell_at(d, slot.pos)
			testing.expect_value(t, cell.kind, Cell_Kind.Floor)
			testing.expect_value(t, int(cell.room), slot.room)
		}
		for room, i in d.rooms {
			tmpl := d.templates[room.template]
			testing.expect_value(t, spawns_per_room[i], len(tmpl.enemy_spawns))
			#partial switch room.kind {
			case .Encounter:
				testing.expectf(t, spawns_per_room[i] > 0, "seed %d: encounter room %d has no enemy spawns", seed, i)
			case .Hallway:
				// One tile across in one of the two ground plane dimensions.
				testing.expect(t, min(tmpl.w, tmpl.h) == 3, "a hallway is one floor tile wide")
				// With pruning on, no hallway is a dead end.
				children := 0
				for conn in d.conns {
					children += int(conn.from == i)
				}
				testing.expectf(t, children > 0, "seed %d: hallway %d leads nowhere", seed, i)
			}
		}
	}
	testing.expect(t, total.by_kind[.Hallway] > 0)
	testing.expect(t, total.by_kind[.Encounter] > 0)
	testing.expect(t, total.by_kind[.Normal] > 0)
	testing.expect(t, total.enemy_spawns > 0)
	testing.expect(t, total.item_slots > 0)
}

@(test)
size_is_configurable :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}

	f.cfg.size = {width = 20, height = 14}
	f.cfg.generation.min_rooms = 1
	small := must_generate(t, &f, 5)
	testing.expect_value(t, small.w, 20)
	testing.expect_value(t, small.h, 14)
	testing.expect_value(t, len(small.cells), 20 * 14)
	ascii := dungeon_to_ascii(small, f.allocator)
	testing.expect_value(t, len(ascii), (20 + 1) * 14)

	f.cfg.size = {width = 80, height = 80}
	f.cfg.generation.max_rooms = 6
	capped := must_generate(t, &f, 5)
	testing.expect(t, len(capped.rooms) <= 6)

	f.cfg.generation.max_rooms = 1
	alone := must_generate(t, &f, 5)
	testing.expect_value(t, len(alone.rooms), 1)
	testing.expect_value(t, len(alone.conns), 0)
	for cell in alone.cells {
		testing.expect(t, cell.kind != .Door && cell.kind != .Open, "a lone entrance has all its nodes sealed")
	}
}

@(test)
entrance_position_is_configurable :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}

	f.cfg.generation.entrance_position = {0, 0}
	corner := must_generate(t, &f, 3)
	testing.expect_value(t, corner.rooms[0].pos, [2]int{0, 0})

	f.cfg.generation.entrance_position = {1, 1}
	far := must_generate(t, &f, 3)
	tmpl := far.templates[far.rooms[0].template]
	testing.expect_value(t, far.rooms[0].pos, [2]int{far.w - tmpl.w, far.h - tmpl.h})
}

// ---------------------------------------------------------------- locks

@(test)
every_lock_has_a_key_earlier_in_the_tree :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}
	f.cfg.locks = {chance = 1, max = 1000}

	locks_seen := 0
	for seed in 1 ..= u64(SEEDS) {
		d := must_generate(t, &f, seed)
		locks_seen += d.lock_count

		keys := make([]int, d.lock_count, context.temp_allocator)
		key_room := make([]int, d.lock_count, context.temp_allocator)
		for slot in d.item_slots {
			if slot.key >= 0 {
				testing.expect(t, slot.key < d.lock_count) or_continue
				keys[slot.key] += 1
				key_room[slot.key] = slot.room
			}
		}
		locked := 0
		for conn in d.conns {
			if !conn.locked {
				testing.expect_value(t, conn.lock_id, -1)
				continue
			}
			locked += 1
			testing.expect_value(t, conn.kind, Node_Kind.Door)
			testing.expect(t, conn.lock_id >= 0 && conn.lock_id < d.lock_count) or_continue
			testing.expect_value(t, keys[conn.lock_id], 1)

			// The key lies in a room generated before the room behind the door...
			room := key_room[conn.lock_id]
			testing.expectf(t, room < conn.to, "seed %d: key %d is in room %d, door leads to %d", seed, conn.lock_id, room, conn.to)
			// ...which rules out the locked subtree itself.
			for r := room; r >= 0; r = d.rooms[r].parent {
				testing.expectf(t, r != conn.to, "seed %d: key %d is behind its own door", seed, conn.lock_id)
			}
		}
		testing.expect_value(t, locked, d.lock_count)

		result := solve(d, f.allocator)
		testing.expectf(t, result.solvable, "seed %d: only %d of %d rooms reachable", seed, result.rooms_reached, len(d.rooms))
		testing.expect_value(t, result.keys_found, d.lock_count)
		testing.expect_value(t, result.doors_opened, d.lock_count)
	}
	testing.expect(t, locks_seen > 0)
}

@(test)
lock_limits_are_respected :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}

	f.cfg.locks = {chance = 1, max = 2}
	for seed in 1 ..= u64(20) {
		testing.expect(t, must_generate(t, &f, seed).lock_count <= 2)
	}
	f.cfg.locks = {chance = 0, max = 10}
	for seed in 1 ..= u64(20) {
		d := must_generate(t, &f, seed)
		testing.expect_value(t, d.lock_count, 0)
		testing.expect(t, solve(d, f.allocator).solvable)
	}
}

@(test)
solver_needs_the_key :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}
	f.cfg.locks = {chance = 1, max = 1000}

	for seed in 1 ..= u64(SEEDS) {
		d := must_generate(t, &f, seed)
		if d.lock_count == 0 {
			continue
		}
		// Take the first key away: its door and everything behind it is lost.
		for &slot in d.item_slots {
			if slot.key == 0 {
				slot.item = .None
				slot.key = -1
			}
		}
		result := solve(d, f.allocator)
		testing.expect(t, !result.solvable)
		for conn in d.conns {
			if conn.lock_id == 0 {
				testing.expect(t, result.reached[conn.from])
				testing.expect(t, !result.reached[conn.to])
			}
		}
		testing.expect(t, result.reached[0])
		return
	}
	testing.expect(t, false, "no seed produced a locked door")
}

// ---------------------------------------------------------------- tiles

@(test)
wall_pieces_follow_their_arms :: proc(t: ^testing.T) {
	Case :: struct {
		arms:  Dirs,
		piece: Wall_Piece,
		turns: int,
	}
	cases := []Case {
		{{.E, .W}, .Straight, 0},
		{{.N, .S}, .Straight, 1},
		{{.W, .S}, .Corner, 0},
		{{.S, .E}, .Corner, 1},
		{{.E, .N}, .Corner, 2},
		{{.N, .W}, .Corner, 3},
		{{.W, .E, .S}, .Tsplit, 0},
		{{.S, .N, .E}, .Tsplit, 1},
		{{.E, .W, .N}, .Tsplit, 2},
		{{.N, .S, .W}, .Tsplit, 3},
		{{.N, .E, .S, .W}, .Crossing, 0},
	}
	for c in cases {
		piece, turns := wall_piece(c.arms)
		testing.expectf(t, piece == c.piece && turns == c.turns, "%v: got %v at %d turns", c.arms, piece, turns)
	}

	// Cross-check against the geometry: turning the model must carry the arms
	// it has at rest onto exactly the arms that were asked for.
	rest := [Wall_Piece]Dirs {
		.Straight = {.E, .W},
		.Corner   = {.W, .S},
		.Tsplit   = {.W, .E, .S},
		.Crossing = {.N, .E, .S, .W},
	}
	for c in cases {
		m := tile_matrix(Tile{turns = c.turns, scale = 1})
		turned: Dirs
		for dir in rest[c.piece] {
			v := dir_vec(dir)
			p := m * [4]f32{f32(v.x), 0, f32(v.y), 0}
			for candidate in Dir {
				cv := dir_vec(candidate)
				if abs(p.x - f32(cv.x)) < 1e-4 && abs(p.z - f32(cv.y)) < 1e-4 {
					turned += {candidate}
				}
			}
		}
		testing.expectf(t, turned == c.arms, "%v at %d turns covers %v, wanted %v", c.piece, c.turns, turned, c.arms)
	}
}

@(test)
tile_matrix_places_and_scales :: proc(t: ^testing.T) {
	m := tile_matrix(Tile{pos = {8, 1, -4}, turns = 1, scale = 2})
	p := m * [4]f32{1, 1, 0, 1}
	// East swings round to north, doubled, then moved.
	testing.expect(t, abs(p.x - 8) < 1e-4 && abs(p.y - 3) < 1e-4 && abs(p.z - (-6)) < 1e-4)
}

@(test)
tiles_cover_the_dungeon :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}
	f.cfg.locks = {chance = 1, max = 1000}

	known := config_model_names(&f.cfg, f.allocator)
	for seed in 1 ..= u64(20) {
		d := must_generate(t, &f, seed)
		tiles := build_tiles(d, &f.cfg, f.allocator)

		counts := make(map[string]int, context.temp_allocator)
		tinted_doors := 0
		for tile in tiles {
			counts[tile.model] += 1
			found := false
			for name in known {
				found ||= name == tile.model
			}
			testing.expectf(t, found, "tile uses model '%s' that config_model_names does not list", tile.model)
			testing.expect(t, tile.scale > 0)
			if tile.model == f.cfg.tiles.doorway && tile.tint != {1, 1, 1} {
				tinted_doors += 1
			}
		}

		occupied, door_cells, corner_cells := 0, 0, 0
		for cell in d.cells {
			occupied += int(cell.kind != .Empty)
			door_cells += int(cell.kind == .Door)
			if cell.kind == .Wall {
				piece, _ := wall_piece(cell.arms)
				corner_cells += int(piece == .Corner)
			}
		}
		floors := 0
		for _, models in f.cfg.floors {
			seen := make(map[string]bool, context.temp_allocator)
			for name in models {
				if name not_in seen {
					seen[name] = true
					floors += counts[name]
				}
			}
		}
		testing.expect_value(t, floors, occupied)
		testing.expect_value(t, counts[f.cfg.tiles.doorway], door_cells)
		testing.expect_value(t, counts[f.cfg.tiles.door], door_cells)
		testing.expect_value(t, counts[f.cfg.tiles.corner], corner_cells)
		testing.expect(t, corner_cells >= 4)
		testing.expect_value(t, tinted_doors, d.lock_count)

		// Free flight shows everything: every item, chest and empty spot.
		keys, swords, chests, bare := 0, 0, 0, 0
		for slot in d.item_slots {
			keys += int(slot.item == .Key)
			swords += int(slot.item == .Sword)
			chests += int(slot.chest)
			bare += int(!slot.chest && slot.item == .None)
		}
		testing.expect_value(t, counts[f.cfg.items.key.model], keys)
		testing.expect_value(t, counts[f.cfg.items.sword.model], swords)
		testing.expect_value(t, counts[f.cfg.props.chest], chests)
		testing.expect_value(t, counts[f.cfg.props.chest_lid], chests)
		testing.expect_value(t, counts[f.cfg.markers.ground_slot.model], bare)
		testing.expect_value(t, keys, d.lock_count)
		testing.expect_value(t, counts[f.cfg.markers.enemy_spawn.model], len(d.enemy_spawns))
		testing.expect_value(t, counts[f.cfg.markers.player_spawn.model], 1)
	}
}

@(test)
ascii_shows_locks_and_keys :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f) {
		return
	}
	f.cfg.locks = {chance = 1, max = 3}

	for seed in 1 ..= u64(SEEDS) {
		d := must_generate(t, &f, seed)
		if d.lock_count < 3 {
			continue
		}
		ascii := dungeon_to_ascii(d, f.allocator)
		testing.expect_value(t, strings.count(ascii, "@"), 1)
		testing.expect_value(t, strings.count(ascii, "A"), 1)
		testing.expect_value(t, strings.count(ascii, "a"), 1)
		testing.expect_value(t, strings.count(ascii, "C"), 1)
		testing.expect_value(t, strings.count(ascii, "c"), 1)
		testing.expect_value(t, strings.count(ascii, "\n"), d.h)
		return
	}
	testing.expect(t, false, "no seed produced three locks")
}
