package assets

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import "../dungeon"

// The model manifest is the record of which model files the game uses, and
// the packaging script ships by it. These tests keep it honest.

@(test)
model_manifest_matches_the_config :: proc(t: ^testing.T) {
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
	m, err, ok := manifest_load(cfg.assets.manifest, ROOT, allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}

	// Loading already proved every file exists; this proves the list is
	// exactly what the config uses, no more and no less.
	err, ok = manifest_check(&m, &cfg, allocator)
	testing.expectf(t, ok, "%s", err)
	testing.expect(t, len(m.models) > 20)
	testing.expect_value(t, len(m.characters), 2)
	testing.expect(t, len(m.animations) >= 2)
	for id, path in m.models {
		testing.expectf(t, strings.has_suffix(path, ".gltf") && os.exists(path), "model '%s': %s", id, path)
	}
	for id, path in m.characters {
		testing.expectf(t, strings.has_suffix(path, ".glb") && os.exists(path), "character '%s': %s", id, path)
	}
	// A sub-model is found under its file's id.
	testing.expect_value(t, model_id("wall_doorway:wall_doorway_door"), "wall_doorway")
	testing.expect_value(t, model_id("wall"), "wall")
	testing.expect(t, "wall_doorway" in m.models)

	// A feature switched off keeps its files without the manifest complaining.
	quiet := cfg
	quiet.enemies.enabled = false
	quiet.items.swords = 0
	err, ok = manifest_check(&m, &quiet, allocator)
	testing.expectf(t, ok, "%s", err)

	// The config asking for something that is not listed is an error...
	wanting := cfg
	wanting.tiles.corner = "wall_gated"
	_, ok = manifest_check(&m, &wanting, allocator)
	testing.expect(t, !ok)
	wanting = cfg
	wanting.play.character = "mage"
	_, ok = manifest_check(&m, &wanting, allocator)
	testing.expect(t, !ok)
	wanting = cfg
	wanting.play.swing.file = "ranged"
	_, ok = manifest_check(&m, &wanting, allocator)
	testing.expect(t, !ok)

	// ...and so is listing something the config does not use.
	m.models["banner_red"] = m.models["wall"]
	_, ok = manifest_check(&m, &cfg, allocator)
	testing.expect(t, !ok)
	delete_key(&m.models, "banner_red")
	m.characters["mage"] = m.characters["knight"]
	_, ok = manifest_check(&m, &cfg, allocator)
	testing.expect(t, !ok)
	delete_key(&m.characters, "mage")
	m.animations["ranged"] = m.animations["melee"]
	_, ok = manifest_check(&m, &cfg, allocator)
	testing.expect(t, !ok)
}

@(test)
bad_model_manifests_are_refused :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	good := `{"root": "r", "models": {"wall": "a/wall.gltf"}, "characters": {"knight": "k.glb"}, "animations": {"general": "g.glb"}}`
	m, err, ok := manifest_parse(transmute([]byte)string(good), "base/", false, allocator)
	testing.expectf(t, ok, "%s", err)
	testing.expect_value(t, m.models["wall"], "base/r/a/wall.gltf")
	testing.expect_value(t, m.characters["knight"], "base/r/k.glb")
	testing.expect_value(t, m.animations["general"], "base/r/g.glb")

	bad := []string {
		`{ nope`,
		`{"root": "r", "models": {"wall": ""}}`, // no path
		`{"root": "r", "models": {"wall:door": "a.gltf"}}`, // ':' is for picking a node
		`{"root": "r", "models": {"wall": "a.gltf", "fence": "a.gltf"}}`, // one file, two ids
		`{"root": "r", "characters": {"a": "k.glb", "b": "k.glb"}}`,
	}
	for text in bad {
		_, message, loaded := manifest_parse(transmute([]byte)text, "", false, allocator)
		testing.expectf(t, !loaded && message != "", "manifest should be refused: %s", text)
	}
	// With file checking on, a path that leads nowhere is refused too.
	_, _, ok = manifest_parse(transmute([]byte)string(good), "", true, allocator)
	testing.expect(t, !ok)

	// A model that is not listed cannot be loaded, whatever is on disk.
	lib: Library
	library_init(&lib, allocator)
	_, ok = library_load(&lib, &m, "chest")
	testing.expect(t, !ok)
}

@(test)
gltf_files_name_what_they_need :: proc(t: ^testing.T) {
	dir :: ROOT + "assets/KayKit_Dungeon_Pack_1.1_SOURCE/Assets/gltf/"
	files, ok := gltf_dependencies(dir + "wall.gltf", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(files), 2)
	has_bin, has_texture := false, false
	for file in files {
		testing.expectf(t, os.exists(file), "%s does not exist", file)
		has_bin ||= strings.has_suffix(file, "/wall.bin")
		has_texture ||= strings.has_suffix(file, "/dungeon_texture.png")
	}
	testing.expect(t, has_bin && has_texture)

	// A .glb is self-contained.
	files, ok = gltf_dependencies(ROOT + "assets/KayKit_Adventurers_2.0_SOURCE/Characters/gltf/Knight.glb", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(files), 0)

	_, ok = gltf_dependencies(dir + "no_such.gltf", context.temp_allocator)
	testing.expect(t, !ok)
}
// The amulet is the project's own model rather than one from a pack. It has
// to load like any other, come out at a size that makes sense lying on a
// floor tile, and find its texture.
@(test)
amulet_model_loads :: proc(t: ^testing.T) {
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
	m, err, ok := manifest_load(cfg.assets.manifest, ROOT, allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}
	name := cfg.items.amulet.model
	testing.expect(t, name != "" && name in m.models)

	lib: Library
	library_init(&lib, allocator)
	err, ok = library_load(&lib, &m, name)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}
	model := lib.models[name]
	testing.expect(t, model.index_count > 0 && model.index_count % 3 == 0)

	// Scaled as configured it is a trinket, not a boulder: well inside one
	// tile, and flat enough to lie on the floor without a tilt.
	scale := cfg.items.amulet.scale
	size := (model.bounds_max - model.bounds_min) * scale
	testing.expectf(t, size.x > 0.3 && size.x < cfg.tile_size / 2 && size.z > 0.3 && size.z < cfg.tile_size / 2, "the amulet would be %v units across", size)
	testing.expectf(t, size.y < size.x, "the amulet stands %v tall but is only %v wide", size.y, size.x)
	testing.expect(t, model.bounds_min.y > -0.2, "it should sit on the floor, not under it")

	img, loaded := image_load(model.texture)
	testing.expectf(t, loaded, "the amulet's texture %s does not load", model.texture)
	image_destroy(&img)

	// Its buffer and texture are found for packaging.
	needs, readable := gltf_dependencies(m.models[name], allocator)
	testing.expect(t, readable)
	testing.expect_value(t, len(needs), 2)
	for file in needs {
		testing.expectf(t, os.exists(file), "%s is missing", file)
	}
}
// The cheer played on finding the amulet: it has to exist under the
// configured name, drive the knight's rig, and keep the knight on its feet.
@(test)
celebration_clip_animates_the_knight :: proc(t: ^testing.T) {
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
	m, err, ok := manifest_load(cfg.assets.manifest, ROOT, allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}
	ch: Character
	ch, err, ok = character_load(m.characters[cfg.play.character], allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}
	defer character_destroy_texture(&ch)
	clip: Clip
	clip, err, ok = clip_load(m.animations[cfg.play.celebrate.file], cfg.play.celebrate.clip, &ch, allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}
	testing.expect(t, clip.duration > 0.5)
	// The celebration is long enough to see the cheer through at least once.
	testing.expectf(t, cfg.play.celebrate_time >= clip.duration, "celebrating for %v s cuts a %v s cheer short", cfg.play.celebrate_time, clip.duration)

	pose := make([]Transform, len(ch.joints), allocator)
	matrices := make([]matrix[4, 4]f32, len(ch.joints), allocator)
	out := make([]Vertex, len(ch.vertices), allocator)
	first := make([]Vertex, len(ch.vertices), allocator)
	moved: f32
	highest: f32
	for step in 0 ..< 10 {
		pose_sample(&ch, &clip, clip.duration * f32(step) / 10, pose)
		pose_matrices(&ch, pose, 1, matrices)
		skin(&ch, matrices, out)
		lo, hi := f32(1e9), f32(-1e9)
		for v in out {
			lo = min(lo, v.pos.y)
			hi = max(hi, v.pos.y)
		}
		testing.expectf(t, lo > -0.4 && lo < 0.8, "feet at %v", lo)
		highest = max(highest, hi)
		if step == 0 {
			copy(first, out)
		}
		for v, i in out {
			d := v.pos - first[i].pos
			moved = max(moved, abs(d.x), abs(d.y), abs(d.z))
		}
	}
	// It is a cheer, not a pose: something travels a good way during it.
	testing.expectf(t, moved > 0.3, "nothing moves more than %v during the cheer", moved)
	// The amulet floats clear of even that.
	testing.expectf(t, dungeon.AMULET_LIFT_TO > highest, "the amulet at %v would sit inside the knight, which reaches %v", f32(dungeon.AMULET_LIFT_TO), highest)
}