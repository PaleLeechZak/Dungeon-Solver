package assets

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "../dungeon"

ROOT :: #directory + "/../../"

// The project's model manifest, loaded so that it works from any directory.
@(private = "file")
manifest_for :: proc(t: ^testing.T, allocator: runtime.Allocator) -> ^Manifest {
	m := new(Manifest, allocator)
	err: string
	ok: bool
	m^, err, ok = manifest_load("config/models.json5", ROOT, allocator)
	testing.expectf(t, ok, "model manifest: %s", err)
	return m
}

@(private = "file")close :: proc(a, b: [3]f32) -> bool {
	return abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3 && abs(a.z - b.z) < 1e-3
}

// The generator assumes these exact footprints: a 4 unit grid, walls centred
// in their cell and corner pieces reaching west and south.
@(test)
structural_pieces_fit_the_grid :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	cfg, cerr, cok := dungeon.config_load(ROOT + "config/dungeon.json5", allocator)
	if !testing.expectf(t, cok, "config: %s", cerr) {
		return
	}
	dir := manifest_for(t, allocator)

	lib: Library
	library_init(&lib, allocator)
	Expect :: struct {
		name:     string,
		min, max: [3]f32,
	}
	expected := []Expect {
		{"wall", {-2, 0, -0.5}, {2, 4, 0.5}},
		{cfg.tiles.corner, {-2, 0, -0.5}, {0.5, 4, 2}},
		{cfg.tiles.tsplit, {-2, 0, -0.5}, {2, 4, 2}},
		{cfg.tiles.crossing, {-2, 0, -2}, {2, 4, 2}},
		{cfg.tiles.doorway, {-2, 0, -0.5}, {2, 4, 0.5}},
	}
	for e in expected {
		err, ok := library_load(&lib, dir, e.name)
		if !testing.expectf(t, ok, "%s", err) {
			continue
		}
		model := lib.models[e.name]
		testing.expectf(t, close(model.bounds_min, e.min), "%s min is %v, expected %v", e.name, model.bounds_min, e.min)
		testing.expectf(t, close(model.bounds_max, e.max), "%s max is %v, expected %v", e.name, model.bounds_max, e.max)
	}
	for _, models in cfg.floors {
		for name in models {
			err, ok := library_load(&lib, dir, name)
			if !testing.expectf(t, ok, "%s", err) {
				continue
			}
			model := lib.models[name]
			half := cfg.tile_size / 2
			testing.expectf(
				t,
				abs(model.bounds_min.x + half) < 1e-3 && abs(model.bounds_max.x - half) < 1e-3 &&
				abs(model.bounds_min.z + half) < 1e-3 && abs(model.bounds_max.z - half) < 1e-3,
				"floor %s does not cover one %v unit cell: %v..%v",
				name,
				cfg.tile_size,
				model.bounds_min,
				model.bounds_max,
			)
		}
	}
}

@(test)
every_configured_model_loads :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	cfg, cerr, cok := dungeon.config_load(ROOT + "config/dungeon.json5", allocator)
	if !testing.expectf(t, cok, "config: %s", cerr) {
		return
	}
	dir := manifest_for(t, allocator)

	lib: Library
	library_init(&lib, allocator)
	names := dungeon.config_model_names(&cfg, allocator)
	testing.expect(t, len(names) > 10)
	for name in names {
		err, ok := library_load(&lib, dir, name)
		testing.expectf(t, ok, "%s", err)
	}
	testing.expect_value(t, len(lib.models), len(names))

	// Ranges are contiguous, in bounds and made of whole triangles.
	next_index: u32
	for name in names {
		model := lib.models[name]
		testing.expect_value(t, model.first_index, next_index)
		testing.expect(t, model.index_count > 0 && model.index_count % 3 == 0)
		next_index += model.index_count
		for i in model.first_index ..< model.first_index + model.index_count {
			vertex := int(model.vertex_offset) + int(lib.indices[i])
			if !testing.expectf(t, vertex < len(lib.vertices), "%s indexes past the vertex buffer", name) {
				break
			}
		}
	}
	testing.expect_value(t, int(next_index), len(lib.indices))

	// Loading twice is a no-op.
	before := len(lib.vertices)
	_, ok := library_load(&lib, dir, names[0])
	testing.expect(t, ok)
	testing.expect_value(t, len(lib.vertices), before)

	_, missing_ok := library_load(&lib, dir, "no_such_model")
	testing.expect(t, !missing_ok)
}

// A chest is two nodes: the body and a lid that is moved into place by its
// node transform. Doorways hang their door the same way.
@(test)
child_nodes_are_transformed :: proc(t: ^testing.T) {
	lib: Library
	library_init(&lib, context.temp_allocator)
	err, ok := library_load(&lib, manifest_for(t, context.temp_allocator), "chest")
	if !testing.expectf(t, ok, "%s", err) {
		return
	}
	model := lib.models["chest"]
	// The lid sits 0.5 up and 0.56 back from the chest body.
	testing.expectf(t, model.bounds_max.y > 0.7, "lid was not lifted onto the chest: %v", model.bounds_max)
	testing.expectf(t, model.bounds_min.z < -0.55, "lid was not moved back: %v", model.bounds_min)
}

@(test)
texture_loads_as_rgba :: proc(t: ^testing.T) {
	img, ok := image_load(ROOT + "assets/KayKit_Dungeon_Pack_1.1_SOURCE/Assets/textures/dungeon_texture.png")
	if !testing.expect(t, ok) {
		return
	}
	defer image_destroy(&img)
	testing.expect(t, img.width > 0 && img.height > 0)
	testing.expect_value(t, len(img.pixels), img.width * img.height * 4)

	_, missing := image_load(ROOT + "assets/does_not_exist.png")
	testing.expect(t, !missing)
}

// The doorway is drawn as a frame plus a leaf that swings on its hinge. Put
// back together with the configured hinge offset they must be the original model.
@(test)
door_leaf_hangs_on_the_configured_hinge :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	cfg, cerr, cok := dungeon.config_load(ROOT + "config/dungeon.json5", allocator)
	if !testing.expectf(t, cok, "config: %s", cerr) {
		return
	}
	dir := manifest_for(t, allocator)

	lib: Library
	library_init(&lib, allocator)
	for name in ([]string{cfg.tiles.doorway, cfg.tiles.door, "wall_doorway"}) {
		err, ok := library_load(&lib, dir, name)
		if !testing.expectf(t, ok, "%s", err) {
			return
		}
	}
	frame, leaf, whole := lib.models[cfg.tiles.doorway], lib.models[cfg.tiles.door], lib.models["wall_doorway"]
	testing.expect_value(t, frame.index_count + leaf.index_count, whole.index_count)

	// The leaf is hinged on its own origin: it starts there and reaches one way only.
	testing.expect(t, abs(leaf.bounds_min.x) < 0.25 && leaf.bounds_max.x > 1.5, "the leaf turns about its edge")
	hinge := cfg.tiles.door_hinge
	width := leaf.bounds_max.x - leaf.bounds_min.x
	testing.expect(t, abs(width - 2) < 0.01, "the leaf is two units wide")
	// Hung on the hinge it fills the gap in the middle of the frame...
	testing.expect(t, abs((leaf.bounds_min.x + hinge.x) + width / 2) < 0.01)
	testing.expect(t, abs((leaf.bounds_max.x + hinge.x) - width / 2) < 0.01)
	// ...which is exactly the opening the collision code leaves when it is open.
	testing.expect(t, abs(width / 2 - cfg.tile_size * dungeon.DOOR_HALF_OPENING) < 0.01)
	testing.expect(t, close(frame.bounds_min, whole.bounds_min) && close(frame.bounds_max, whole.bounds_max))
	// Walls are as thick as the collision code believes.
	testing.expect(t, abs(whole.bounds_max.z - cfg.tile_size * dungeon.WALL_HALF_THICKNESS) < 0.01)

	_, missing := library_load(&lib, dir, "wall_doorway:no_such_node")
	testing.expect(t, !missing)
}

@(private = "file")
Knight :: struct {
	arena:     virtual.Arena,
	cfg:       dungeon.Config,
	character: Character,
	idle:      Clip,
	move:      Clip,
	swing:     Clip,
}

@(private = "file")
knight_load :: proc(t: ^testing.T, k: ^Knight) -> bool {
	if !testing.expect(t, virtual.arena_init_growing(&k.arena) == nil) {
		return false
	}
	allocator := virtual.arena_allocator(&k.arena)
	err: string
	ok: bool
	k.cfg, err, ok = dungeon.config_load(ROOT + "config/dungeon.json5", allocator)
	if !testing.expectf(t, ok, "config: %s", err) {
		return false
	}
	play := k.cfg.play
	k.character, err, ok = character_load(manifest_for(t, allocator).characters[play.character], allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return false
	}
	k.idle, err, ok = clip_load(manifest_for(t, allocator).animations[play.idle.file], play.idle.clip, &k.character, allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return false
	}
	k.move, err, ok = clip_load(manifest_for(t, allocator).animations[play.move.file], play.move.clip, &k.character, allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return false
	}
	k.swing, err, ok = clip_load(manifest_for(t, allocator).animations[play.swing.file], play.swing.clip, &k.character, allocator)
	return testing.expectf(t, ok, "%s", err)
}

@(private = "file")
knight_destroy :: proc(k: ^Knight) {
	character_destroy_texture(&k.character)
	virtual.arena_destroy(&k.arena)
}

@(private = "file")
pose_vertices :: proc(k: ^Knight, clip: ^Clip, time: f32, root: matrix[4, 4]f32) -> []Vertex {
	ch := &k.character
	pose := make([]Transform, len(ch.joints), context.temp_allocator)
	matrices := make([]matrix[4, 4]f32, len(ch.joints), context.temp_allocator)
	out := make([]Vertex, len(ch.vertices), context.temp_allocator)
	pose_sample(ch, clip, time, pose)
	pose_matrices(ch, pose, root, matrices)
	skin(ch, matrices, out)
	return out
}

@(test)
knight_loads_with_rig_and_texture :: proc(t: ^testing.T) {
	k: Knight
	defer knight_destroy(&k)
	if !knight_load(t, &k) {
		return
	}
	ch := &k.character
	testing.expect_value(t, len(ch.joints), 23)
	testing.expect(t, len(ch.vertices) > 500)
	testing.expect(t, len(ch.indices) % 3 == 0 && len(ch.indices) > 0)
	for index in ch.indices {
		if !testing.expect(t, int(index) < len(ch.vertices)) {
			break
		}
	}
	testing.expect(t, ch.texture.width > 0 && len(ch.texture.pixels) == ch.texture.width * ch.texture.height * 4)

	roots := 0
	for joint, i in ch.joints {
		roots += int(joint.parent < 0)
		testing.expect(t, joint.parent < len(ch.joints) && joint.parent != i)
		testing.expect(t, joint.name != "")
	}
	testing.expect_value(t, roots, 1)
	for v in ch.vertices {
		sum := v.weights[0] + v.weights[1] + v.weights[2] + v.weights[3]
		if !testing.expect(t, abs(sum - 1) < 1e-3) {
			break
		}
	}

	// Sized like a person next to the dungeon's 2.75 unit doors, standing on
	// the ground, facing +Z (the visor sticks out in front, the cape behind).
	testing.expect(t, abs(ch.bounds_min.y) < 0.05)
	testing.expect(t, ch.bounds_max.y > 2 && ch.bounds_max.y < 2.75)
	testing.expect(t, ch.bounds_max.z > -ch.bounds_min.z)
}

// With every joint at rest the skinning matrices cancel against the inverse
// bind matrices and the mesh comes out exactly as it went in. This is the
// check that hierarchy, matrix order and weights fit together.
@(test)
rest_pose_reproduces_the_bind_pose :: proc(t: ^testing.T) {
	k: Knight
	defer knight_destroy(&k)
	if !knight_load(t, &k) {
		return
	}
	out := pose_vertices(&k, nil, 0, 1)
	worst: f32
	for v, i in k.character.vertices {
		d := out[i].pos - v.pos
		worst = max(worst, abs(d.x), abs(d.y), abs(d.z))
		n := out[i].normal - v.normal
		worst = max(worst, abs(n.x), abs(n.y), abs(n.z))
	}
	testing.expectf(t, worst < 2e-3, "rest pose is off by %v", worst)

	// A root matrix carries the whole figure along.
	moved := pose_vertices(&k, nil, 0, matrix[4, 4]f32{1, 0, 0, 10, 0, 1, 0, 0, 0, 0, 1, -4, 0, 0, 0, 1})
	d := moved[0].pos - out[0].pos
	testing.expect(t, abs(d.x - 10) < 1e-3 && abs(d.y) < 1e-3 && abs(d.z + 4) < 1e-3)
}

@(test)
clips_animate_without_tearing_the_knight_apart :: proc(t: ^testing.T) {
	k: Knight
	defer knight_destroy(&k)
	if !knight_load(t, &k) {
		return
	}
	testing.expect(t, k.idle.duration > 0.5 && k.move.duration > 0.5)
	testing.expect_value(t, len(k.move.tracks), len(k.character.joints))

	rest := pose_vertices(&k, nil, 0, 1)
	for clip in ([]^Clip{&k.idle, &k.move}) {
		animated := 0
		for track in clip.tracks {
			animated += int(len(track.rotations) > 0)
		}
		testing.expectf(t, animated >= 20, "%s drives only %d joints", clip.name, animated)

		moved_from_rest: f32
		for step in 0 ..< 8 {
			time := clip.duration * f32(step) / 8
			out := pose_vertices(&k, clip, time, 1)
			lo, hi := [3]f32{1e9, 1e9, 1e9}, [3]f32{-1e9, -1e9, -1e9}
			for v, i in out {
				for axis in 0 ..< 3 {
					lo[axis] = min(lo[axis], v.pos[axis])
					hi[axis] = max(hi[axis], v.pos[axis])
				}
				d := v.pos - rest[i].pos
				moved_from_rest = max(moved_from_rest, abs(d.x), abs(d.y), abs(d.z))
				length := v.normal.x * v.normal.x + v.normal.y * v.normal.y + v.normal.z * v.normal.z
				if !testing.expectf(t, length > 0.25 && length < 2.25, "%s: normal length^2 %v", clip.name, length) {
					break
				}
			}
			// Still a knight-sized figure standing on the floor.
			testing.expectf(t, lo.y > -0.3 && lo.y < 0.5, "%s at %v: feet at %v", clip.name, time, lo.y)
			testing.expectf(t, hi.y > 1.8 && hi.y < 3.2, "%s at %v: head at %v", clip.name, time, hi.y)
			testing.expectf(t, hi.x - lo.x < 3 && hi.z - lo.z < 3, "%s at %v: spread %v", clip.name, time, hi - lo)
		}
		testing.expectf(t, moved_from_rest > 0.2, "%s does not move the T-pose", clip.name)

		// Clips loop: one full duration later the pose is the same.
		a := pose_vertices(&k, clip, 0.3, 1)
		b := pose_vertices(&k, clip, 0.3 + clip.duration * 3, 1)
		worst: f32
		for v, i in a {
			d := v.pos - b[i].pos
			worst = max(worst, abs(d.x), abs(d.y), abs(d.z))
		}
		testing.expectf(t, worst < 1e-2, "%s does not loop cleanly: %v", clip.name, worst)
	}

	_, _, ok := clip_load(manifest_for(t, context.temp_allocator).animations[k.cfg.play.move.file], "No_Such_Clip", &k.character, context.temp_allocator)
	testing.expect(t, !ok)
}
// Models come from more than one pack now and each brings its own texture.
@(test)
models_know_their_texture :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	cfg, cerr, cok := dungeon.config_load(ROOT + "config/dungeon.json5", allocator)
	if !testing.expectf(t, cok, "config: %s", cerr) {
		return
	}
	dirs := manifest_for(t, allocator)
	lib: Library
	library_init(&lib, allocator)
	for name in dungeon.config_model_names(&cfg, allocator) {
		err, ok := library_load(&lib, dirs, name)
		if !testing.expectf(t, ok, "%s", err) {
			continue
		}
		model := lib.models[name]
		testing.expectf(t, model.texture != "", "%s names no texture", name)
		img, loaded := image_load(model.texture)
		testing.expectf(t, loaded, "%s: texture %s does not load", name, model.texture)
		image_destroy(&img)
	}
	testing.expect(t, strings.has_suffix(lib.models["wall"].texture, "dungeon_texture.png"))
	testing.expect(t, strings.contains(lib.models["wall"].texture, "KayKit_Dungeon_Pack"))

	sword := lib.models[cfg.items.sword.model]
	testing.expect(t, strings.contains(sword.texture, "KayKit_Adventurers"), "the sword comes from another pack")
	testing.expect(t, sword.texture != lib.models["wall"].texture)

	vertices, indices, ok := library_mesh(&lib, cfg.items.sword.model)
	testing.expect(t, ok)
	testing.expect_value(t, len(indices), int(sword.index_count))
	testing.expect(t, len(vertices) > 0)
	for index in indices {
		if !testing.expect(t, int(index) < len(vertices)) {
			break
		}
	}
	_, _, missing := library_mesh(&lib, "nope")
	testing.expect(t, !missing)
}

// The lid is drawn separately so it can tip open. Shut, on the configured
// hinge, body and lid together must be the chest as modelled.
@(test)
chest_lid_sits_on_the_configured_hinge :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	cfg, cerr, cok := dungeon.config_load(ROOT + "config/dungeon.json5", allocator)
	if !testing.expectf(t, cok, "config: %s", cerr) {
		return
	}
	dirs := manifest_for(t, allocator)
	lib: Library
	library_init(&lib, allocator)
	for name in ([]string{cfg.props.chest, cfg.props.chest_lid, "chest"}) {
		err, ok := library_load(&lib, dirs, name)
		if !testing.expectf(t, ok, "%s", err) {
			return
		}
	}
	body, lid, whole := lib.models[cfg.props.chest], lib.models[cfg.props.chest_lid], lib.models["chest"]
	testing.expect_value(t, body.index_count + lid.index_count, whole.index_count)

	hinge := cfg.props.chest_hinge
	lo, hi := body.bounds_min, body.bounds_max
	for axis in 0 ..< 3 {
		lo[axis] = min(lo[axis], lid.bounds_min[axis] + hinge[axis])
		hi[axis] = max(hi[axis], lid.bounds_max[axis] + hinge[axis])
	}
	testing.expectf(t, close(lo, whole.bounds_min) && close(hi, whole.bounds_max), "reassembled %v..%v, modelled %v..%v", lo, hi, whole.bounds_min, whole.bounds_max)

	// The lid pivots about its back edge and reaches forward from there, so
	// tipping it about its own origin opens it like a real lid.
	testing.expect(t, lid.bounds_min.z > -0.2 && lid.bounds_max.z > 1, "the lid reaches forward from its hinge")
	// The hinge is at the back of the body, near its top.
	testing.expect(t, abs(hinge.z - body.bounds_min.z) < 0.1)
	testing.expect(t, abs(hinge.y - body.bounds_max.y) < 0.15)
	// A chest fits inside the box the collision code gives it.
	half := cfg.tile_size * dungeon.PROP_HALF_SIZE
	testing.expect(t, body.bounds_max.x <= half && -body.bounds_min.x <= half && body.bounds_max.z <= half && -body.bounds_min.z <= half)
}

@(test)
sword_follows_the_hand :: proc(t: ^testing.T) {
	k: Knight
	defer knight_destroy(&k)
	if !knight_load(t, &k) {
		return
	}
	allocator := virtual.arena_allocator(&k.arena)
	ch := &k.character
	lib: Library
	library_init(&lib, allocator)
	err, ok := library_load(&lib, manifest_for(t, allocator), k.cfg.items.sword.model)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}

	// The sword is painted from the same atlas as the knight, which is what
	// lets it be welded into the knight's mesh.
	atlas, atlas_ok := image_load(lib.models[k.cfg.items.sword.model].texture)
	if testing.expect(t, atlas_ok) {
		same := len(atlas.pixels) == len(ch.texture.pixels)
		for i := 0; same && i < len(atlas.pixels); i += 1 {
			same = atlas.pixels[i] == ch.texture.pixels[i]
		}
		testing.expect(t, same, "the sword's texture differs from the knight's")
		image_destroy(&atlas)
	}

	sword_vertices, sword_indices, _ := library_mesh(&lib, k.cfg.items.sword.model)
	body_vertices, body_indices := len(ch.vertices), len(ch.indices)
	_, bad := character_attach(ch, sword_vertices, sword_indices, "no_such_joint", allocator)
	testing.expect(t, !bad)
	err, ok = character_attach(ch, sword_vertices, sword_indices, k.cfg.play.sword_joint, allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}
	testing.expect_value(t, ch.body_indices, body_indices)
	testing.expect_value(t, len(ch.vertices), body_vertices + len(sword_vertices))
	testing.expect_value(t, len(ch.indices), body_indices + len(sword_indices))
	for index in ch.indices[body_indices:] {
		if !testing.expect(t, int(index) >= body_vertices && int(index) < len(ch.vertices)) {
			break
		}
	}

	// Find the grip (nearest the model's origin) and the tip (furthest from it).
	grip, tip := 0, 0
	for v, i in sword_vertices {
		d := v.pos.x * v.pos.x + v.pos.y * v.pos.y + v.pos.z * v.pos.z
		g, p := sword_vertices[grip].pos, sword_vertices[tip].pos
		if d < g.x * g.x + g.y * g.y + g.z * g.z do grip = i
		if d > p.x * p.x + p.y * p.y + p.z * p.z do tip = i
	}
	length :: proc(v: [3]f32) -> f32 {
		return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	}
	blade := length(sword_vertices[tip].pos - sword_vertices[grip].pos)

	// At rest the grip is in the knight's right hand, out at the end of the arm.
	rest := pose_vertices(&k, nil, 0, 1)
	hand := rest[body_vertices + grip].pos
	testing.expectf(t, hand.x < -0.6 && hand.y > 0.8 && hand.y < 1.5, "the grip is at %v, not in the right hand", hand)

	// Through the swing the sword stays rigid, stays in the hand, and its tip
	// really travels.
	hand_joint := -1
	for joint, i in ch.joints {
		if joint.name == k.cfg.play.sword_joint do hand_joint = i
	}
	pose := make([]Transform, len(ch.joints), context.temp_allocator)
	matrices := make([]matrix[4, 4]f32, len(ch.joints), context.temp_allocator)
	tip_lo, tip_hi := [3]f32{1e9, 1e9, 1e9}, [3]f32{-1e9, -1e9, -1e9}
	for step in 0 ..< 12 {
		time := k.swing.duration * f32(step) / 12
		out := pose_vertices(&k, &k.swing, time, 1)
		g, p := out[body_vertices + grip].pos, out[body_vertices + tip].pos
		testing.expectf(t, abs(length(p - g) - blade) < 0.02, "the blade stretched to %v at %v", length(p - g), time)

		pose_sample(ch, &k.swing, time, pose)
		pose_matrices(ch, pose, 1, matrices)
		// Undo the inverse bind to get the joint's own position.
		joint_world := matrices[hand_joint] * linalg.inverse(ch.joints[hand_joint].inverse_bind)
		joint_pos := [3]f32{joint_world[0, 3], joint_world[1, 3], joint_world[2, 3]}
		testing.expectf(t, length(g - joint_pos) < 0.45, "the grip left the hand by %v at %v", length(g - joint_pos), time)
		for axis in 0 ..< 3 {
			tip_lo[axis] = min(tip_lo[axis], p[axis])
			tip_hi[axis] = max(tip_hi[axis], p[axis])
		}
	}
	testing.expectf(t, length(tip_hi - tip_lo) > 1, "the tip only moves %v during a swing", length(tip_hi - tip_lo))
	testing.expect(t, k.swing.duration > 0.4 && k.swing.duration < 3)
}
// The skeletons share the knight's rig, so the same loader and the same
// animation files have to work for them. The warrior also wears a helmet that
// is not skinned at all but simply parented to the head joint.
@(test)
skeleton_loads_with_helmet_weapon_and_clips :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	cfg, cerr, cok := dungeon.config_load(ROOT + "config/dungeon.json5", allocator)
	if !testing.expectf(t, cok, "config: %s", cerr) {
		return
	}
	ec := cfg.enemies
	ch, err, ok := character_load(manifest_for(t, allocator).characters[ec.character], allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}
	defer character_destroy_texture(&ch)
	testing.expect_value(t, len(ch.joints), 23)

	// Find the vertices riding on the head alone: that is the helmet.
	head := -1
	for joint, i in ch.joints {
		if joint.name == "head" do head = i
	}
	helmet_top := f32(0)
	helmet := 0
	for v in ch.vertices {
		if int(v.joints[0]) == head && v.weights[0] == 1 && v.pos.y > 2.0 {
			helmet += 1
			helmet_top = max(helmet_top, v.pos.y)
		}
	}
	testing.expect(t, helmet > 20, "the helmet did not come along")
	testing.expectf(t, helmet_top > 2.2 && helmet_top < 3, "the helmet sits at %v, not on the head", helmet_top)
	testing.expect(t, abs(ch.bounds_min.y) < 0.1, "the skeleton stands on the ground")

	// Rest pose in, bind pose out, helmet included.
	pose := make([]Transform, len(ch.joints), allocator)
	matrices := make([]matrix[4, 4]f32, len(ch.joints), allocator)
	out := make([]Vertex, len(ch.vertices), allocator)
	pose_sample(&ch, nil, 0, pose)
	pose_matrices(&ch, pose, 1, matrices)
	skin(&ch, matrices, out)
	worst: f32
	for v, i in ch.vertices {
		d := out[i].pos - v.pos
		worst = max(worst, abs(d.x), abs(d.y), abs(d.z))
	}
	testing.expectf(t, worst < 2e-3, "rest pose is off by %v", worst)

	// Its blade is painted from the skeleton's own atlas and welds to the hand.
	lib: Library
	library_init(&lib, allocator)
	lerr, lok := library_load(&lib, manifest_for(t, allocator), ec.weapon)
	if !testing.expectf(t, lok, "%s", lerr) {
		return
	}
	atlas, atlas_ok := image_load(lib.models[ec.weapon].texture)
	if testing.expect(t, atlas_ok) {
		same := len(atlas.pixels) == len(ch.texture.pixels)
		for i := 0; same && i < len(atlas.pixels); i += 1 {
			same = atlas.pixels[i] == ch.texture.pixels[i]
		}
		testing.expect(t, same, "the blade's texture differs from the skeleton's")
		image_destroy(&atlas)
	}
	vertices, indices, _ := library_mesh(&lib, ec.weapon)
	aerr, aok := character_attach(&ch, vertices, indices, ec.weapon_joint, allocator)
	testing.expectf(t, aok, "%s", aerr)

	// Every clip a skeleton plays exists and drives its joints.
	for clip_cfg in ([]dungeon.Clip_Config{ec.idle, ec.move, ec.attack, ec.hurt, ec.death}) {
		clip, clip_err, clip_ok := clip_load(manifest_for(t, allocator).animations[clip_cfg.file], clip_cfg.clip, &ch, allocator)
		if !testing.expectf(t, clip_ok, "%s", clip_err) {
			continue
		}
		testing.expect(t, clip.duration > 0.3)
		driven := 0
		for track in clip.tracks {
			driven += int(len(track.rotations) > 0)
		}
		testing.expectf(t, driven >= 20, "%s drives only %d joints", clip.name, driven)
	}
	// So does the knight's flinch and fall.
	for clip_cfg in ([]dungeon.Clip_Config{cfg.play.hurt, cfg.play.death}) {
		_, clip_err, clip_ok := clip_load(manifest_for(t, allocator).animations[clip_cfg.file], clip_cfg.clip, &ch, allocator)
		testing.expectf(t, clip_ok, "%s", clip_err)
	}
}

// Death is played once and then held; sampling must be able to stop at the
// end instead of wrapping round to the first frame.
@(test)
clips_can_be_held_on_their_last_frame :: proc(t: ^testing.T) {
	k: Knight
	defer knight_destroy(&k)
	if !knight_load(t, &k) {
		return
	}
	ch := &k.character
	a := make([]Transform, len(ch.joints), context.temp_allocator)
	b := make([]Transform, len(ch.joints), context.temp_allocator)

	pose_sample(ch, &k.swing, k.swing.duration, a, loop = false)
	pose_sample(ch, &k.swing, k.swing.duration + 5, b, loop = false)
	for joint, i in a {
		testing.expect(t, joint == b[i], "held past the end, the pose should not change") or_break
	}
	// Looping, the same time lands back near the start instead.
	pose_sample(ch, &k.swing, 0, b)
	pose_sample(ch, &k.swing, k.swing.duration * 2, a)
	for joint, i in a {
		testing.expect(t, joint == b[i]) or_break
	}
}