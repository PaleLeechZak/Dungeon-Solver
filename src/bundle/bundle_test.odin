package bundle

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import "../assets"
import "../dungeon"
import "../sound"

ROOT :: #directory + "/../../"
CONFIG :: "config/dungeon.json5"

@(private = "file")
has :: proc(files: []string, path: string) -> bool {
	for file in files {
		if file == path {
			return true
		}
	}
	return false
}

@(test)
package_holds_what_the_game_uses_and_nothing_else :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	files, err, ok := collect(CONFIG, ROOT, allocator)
	if !testing.expectf(t, ok, "%s", err) {
		return
	}

	// A tidy list: relative, inside the project, sorted, no repeats, all real.
	total: i64
	for file, i in files {
		testing.expectf(t, strings.has_prefix(file, "assets/") || strings.has_prefix(file, "config/"), "%s is outside assets/ and config/", file)
		testing.expect(t, !strings.contains(file, "\\") && !strings.contains(file, ".."))
		if i > 0 {
			testing.expectf(t, files[i - 1] < file, "%s is out of order or repeated", file)
		}
		info, stat_err := os.stat(strings.concatenate({ROOT, file}, allocator), allocator)
		if testing.expectf(t, stat_err == nil, "%s does not exist", file) {
			total += info.size
		}
	}

	// The config and both manifests.
	testing.expect(t, has(files, CONFIG))
	testing.expect(t, has(files, "config/models.json5"))
	testing.expect(t, has(files, "config/sounds.json5"))

	// Every model in the model manifest, with the .bin and texture it needs.
	cfg, _, _ := dungeon.config_load(ROOT + CONFIG, allocator)
	models, _, models_ok := assets.manifest_load(cfg.assets.manifest, ROOT, allocator)
	testing.expect(t, models_ok)
	for id, path in models.models {
		relative := strings.trim_prefix(path, ROOT)
		testing.expectf(t, has(files, relative), "model '%s' is not packaged", id)
		bin, _ := strings.replace(relative, ".gltf", ".bin", 1, allocator)
		testing.expectf(t, has(files, bin), "%s is not packaged", bin)
	}
	for _, path in models.characters {
		testing.expect(t, has(files, strings.trim_prefix(path, ROOT)))
	}
	for _, path in models.animations {
		testing.expect(t, has(files, strings.trim_prefix(path, ROOT)))
	}
	dungeon_pack :: "assets/KayKit_Dungeon_Pack_1.1_SOURCE/Assets/gltf/"
	testing.expect(t, has(files, dungeon_pack + "wall.gltf") && has(files, dungeon_pack + "wall.bin"))
	testing.expect(t, has(files, dungeon_pack + "dungeon_texture.png"))
	// The sword and the skeleton's blade bring their own packs' textures.
	testing.expect(t, has(files, "assets/KayKit_Adventurers_2.0_SOURCE/Assets/gltf/knight_texture.png"))
	testing.expect(t, has(files, "assets/KayKit_Skeletons_1.1_SOURCE/assets/gltf/skeleton_texture_A.png"))

	// Every sound in the sound manifest.
	bank, _, bank_ok := sound.bank_load(cfg.sounds.manifest, ROOT, allocator)
	testing.expect(t, bank_ok)
	for s in bank.sounds {
		testing.expectf(t, has(files, strings.trim_prefix(s.path, ROOT)), "sound '%s' is not packaged", s.id)
	}

	// Fonts, the icon lists that go with them, and the UI kit pieces.
	testing.expect(t, has(files, cfg.ui.font))
	testing.expect(t, has(files, cfg.ui.prompts.xbox.font) && has(files, cfg.ui.prompts.xbox.characters))
	testing.expect(t, has(files, cfg.ui.prompts.keyboard_mouse.font) && has(files, cfg.ui.prompts.switch_pad.characters))
	testing.expect(t, has(files, "assets/kenney_fantasy-ui-borders/PNG/Double/Panel/panel-010.png"))
	testing.expect(t, has(files, cfg.assets.texture))

	// Licences come along with the assets they cover.
	testing.expect(t, has(files, "assets/KayKit_Dungeon_Pack_1.1_SOURCE/License.txt"))
	testing.expect(t, has(files, "assets/kenney_input-prompts_1.5/License.txt"))
	testing.expect(t, has(files, "assets/kenney_fantasy-ui-borders/License.txt"))
	testing.expect(t, has(files, "assets/fonts/Crimson_Pro/OFL.txt"))
	testing.expect(t, has(files, "assets/sounds/Gothic Fantasy Sound FX Pack Vol. 1/Royalty-Free License (Link).pdf"))

	// And the point of it all: what is not used stays behind.
	testing.expect(t, !has(files, dungeon_pack + "banner_red.gltf"), "an unused model was packaged")
	testing.expect(t, !has(files, "settings.json"))
	sounds, fonts := 0, 0
	for file in files {
		lower := strings.to_lower(file, allocator)
		testing.expectf(t, !strings.contains(lower, "__macosx") && !strings.contains(lower, ".ds_store"), "%s is clutter", file)
		for unwanted in ([]string{".fbx", ".obj", ".mtl", ".blend", ".svg", ".url", ".zip", ".otf"}) {
			testing.expectf(t, !strings.has_suffix(lower, unwanted), "%s should not be packaged", file)
		}
		sounds += int(strings.has_suffix(lower, ".wav"))
		fonts += int(strings.has_suffix(lower, ".ttf"))
	}
	testing.expect_value(t, sounds, len(bank.sounds))
	testing.expect_value(t, fonts, 5) // Crimson Pro and four prompt fonts
	testing.expectf(t, len(files) < 400, "%d files is far more than the game uses", len(files))
	testing.expectf(t, total < 150 * 1024 * 1024, "the package would be %d MB", total / (1024 * 1024))
}

@(test)
a_broken_config_is_not_packaged :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	_, err, ok := collect("config/no_such_config.json5", ROOT, allocator)
	testing.expect(t, !ok && err != "")

	// A folder with nothing in it is not a package.
	verr, verified := verify(ROOT + "src", CONFIG)
	testing.expect(t, !verified && verr != "")
}

// Windows does not care about capitals in file names and Linux does, so a
// path that is merely close to the real name must be caught on Windows too.
@(test)
paths_must_be_spelled_as_on_disk :: proc(t: ^testing.T) {
	listings := make(map[string][]os.File_Info, context.temp_allocator)
	_, ok := exact_spelling(ROOT, "config/dungeon.json5", &listings)
	testing.expect(t, ok)
	_, ok = exact_spelling(ROOT, "assets/KayKit_Dungeon_Pack_1.1_SOURCE/Assets/gltf/wall.gltf", &listings)
	testing.expect(t, ok)

	wrong: string
	wrong, ok = exact_spelling(ROOT, "config/Dungeon.json5", &listings)
	testing.expect(t, !ok)
	testing.expect_value(t, wrong, "Dungeon.json5")
	// A folder spelled wrong part-way down is found as well.
	wrong, ok = exact_spelling(ROOT, "assets/KayKit_Dungeon_Pack_1.1_SOURCE/assets/gltf/wall.gltf", &listings)
	testing.expect(t, !ok)
	testing.expect_value(t, wrong, "assets")
	_, ok = exact_spelling(ROOT, "config/no_such_file.json5", &listings)
	testing.expect(t, !ok)
}