// What goes in a release. The list is worked out from the config and the two
// manifests, the same files the game itself reads, so the package holds what
// the game uses and nothing else from the gigabytes under assets/.
package bundle

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "../assets"
import "../dungeon"
import "../hud"
import "../sound"

@(private)
List :: struct {
	files:     [dynamic]string,
	base:      string,
	allocator: runtime.Allocator,
}

// Adds a path, given relative to the base, once.
@(private)
add :: proc(l: ^List, path: string) {
	if path == "" {
		return
	}
	clean, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	for existing in l.files {
		if existing == clean {
			return
		}
	}
	// The caller's string may not outlive this call; the list keeps its own.
	append(&l.files, strings.clone(clean, l.allocator))
}

// Adds a path that already has the base in front of it.
@(private)
add_full :: proc(l: ^List, path: string) {
	add(l, strings.trim_prefix(path, l.base))
}

// Every data file the game needs to run from the given config, as paths
// relative to `base` with forward slashes, sorted. The executable and SDL's
// library are not data and are not in the list. Licence files that sit in the
// folders the shipped assets come from are included.
collect :: proc(config_path: string, base := "", allocator := context.allocator) -> (files: []string, err: string, ok: bool) {
	l := List {
		files     = make([dynamic]string, allocator),
		base      = base,
		allocator = allocator,
	}
	cfg: dungeon.Config
	cfg, err, ok = dungeon.config_load(strings.concatenate({base, config_path}, context.temp_allocator), context.temp_allocator)
	if !ok {
		return nil, err, false
	}
	add(&l, config_path)

	// Models, with the buffers and textures each .gltf points at.
	add(&l, cfg.assets.manifest)
	add(&l, cfg.assets.texture)
	models: assets.Manifest
	models, err, ok = assets.manifest_load(cfg.assets.manifest, base, context.temp_allocator)
	if !ok {
		return nil, err, false
	}
	if err, ok = assets.manifest_check(&models, &cfg, allocator); !ok {
		return nil, err, false
	}
	for _, path in models.models {
		add_full(&l, path)
		needs, readable := assets.gltf_dependencies(path, context.temp_allocator)
		if !readable {
			return nil, fmt.aprintf("cannot read %s to find what it needs", path, allocator = allocator), false
		}
		for file in needs {
			add_full(&l, file)
		}
	}
	for _, path in models.characters do add_full(&l, path)
	for _, path in models.animations do add_full(&l, path)

	// Sounds and music.
	if cfg.sounds.enabled {
		add(&l, cfg.sounds.manifest)
		bank: sound.Bank
		bank, err, ok = sound.bank_load(cfg.sounds.manifest, base, context.temp_allocator)
		if !ok {
			return nil, err, false
		}
		for s in bank.sounds {
			add_full(&l, s.path)
		}
	}

	// Fonts, prompt icons and the UI kit.
	ui := cfg.ui
	add(&l, ui.font)
	for prompt in ([]dungeon.Prompt_Font{ui.prompts.keyboard_mouse, ui.prompts.xbox, ui.prompts.playstation, ui.prompts.switch_pad}) {
		add(&l, prompt.font)
		add(&l, prompt.characters)
	}
	for piece in ([]string{ui.kit.window, ui.kit.window_border, ui.kit.button, ui.kit.button_border, ui.kit.track, ui.kit.divider}) {
		add(&l, strings.concatenate({ui.kit.dir, "/", piece}, context.temp_allocator))
	}

	// Licences travel with the assets: any licence file in a folder a shipped
	// file comes from, or in one of that folder's parents.
	folders := make([dynamic]string, context.temp_allocator)
	for file in l.files {
		dir := file
		for {
			slash := strings.last_index_byte(dir, '/')
			if slash <= 0 {
				break
			}
			dir = dir[:slash]
			known := false
			for folder in folders {
				known ||= folder == dir
			}
			if !known {
				append(&folders, dir)
			}
		}
	}
	for folder in folders {
		entries, read_err := os.read_all_directory_by_path(strings.concatenate({base, folder}, context.temp_allocator), context.temp_allocator)
		if read_err != nil {
			continue
		}
		for entry in entries {
			lower := strings.to_lower(entry.name, context.temp_allocator)
			if entry.type == .Regular && (strings.contains(lower, "license") || strings.contains(lower, "licence") || lower == "ofl.txt") {
				add(&l, strings.concatenate({folder, "/", entry.name}, context.temp_allocator))
			}
		}
	}

	slice.sort(l.files[:])
	listings := make(map[string][]os.File_Info, context.temp_allocator)
	for file in l.files {
		if !os.exists(strings.concatenate({base, file}, context.temp_allocator)) {
			return nil, fmt.aprintf("%s is needed but does not exist", file, allocator = allocator), false
		}
		// Windows finds "Wall.gltf" when asked for "wall.gltf"; Linux does
		// not. A path has to be spelled the way the file is, or the Linux
		// build cannot load what the Windows build can.
		if wrong, spelled := exact_spelling(base, file, &listings); !spelled {
			return nil, fmt.aprintf("%s: '%s' is spelled with different capitals on disk; that only works on Windows", file, wrong, allocator = allocator), false
		}
		// Everything has to stay inside the project, or the package layout breaks.
		if strings.has_prefix(file, "/") || strings.contains(file, "..") || strings.contains(file, ":") {
			return nil, fmt.aprintf("%s is outside the project folder", file, allocator = allocator), false
		}
	}
	return l.files[:], "", true
}

// Loads everything the game loads at start-up, but from a packaged copy in
// `dir`: the proof that the package is complete. Nothing here opens a window.
verify :: proc(dir, config_path: string) -> (err: string, ok: bool) {
	base := strings.concatenate({dir, "/"}, context.temp_allocator)
	cfg: dungeon.Config
	cfg, err, ok = dungeon.config_load(strings.concatenate({base, config_path}, context.temp_allocator), context.temp_allocator)
	if !ok {
		return
	}
	models: assets.Manifest
	if models, err, ok = assets.manifest_load(cfg.assets.manifest, base, context.temp_allocator); !ok {
		return
	}
	if err, ok = assets.manifest_check(&models, &cfg, context.temp_allocator); !ok {
		return
	}

	lib: assets.Library
	assets.library_init(&lib, context.temp_allocator)
	for name in dungeon.config_model_names(&cfg, context.temp_allocator) {
		if err, ok = assets.library_load(&lib, &models, name); !ok {
			return
		}
		if texture := lib.models[name].texture; texture != "" {
			img, loaded := assets.image_load(texture)
			if !loaded {
				return fmt.tprintf("texture %s is missing from the package", texture), false
			}
			assets.image_destroy(&img)
		}
	}
	fallback, fallback_ok := assets.image_load(strings.concatenate({base, cfg.assets.texture}, context.temp_allocator))
	if !fallback_ok {
		return fmt.tprintf("texture %s is missing from the package", cfg.assets.texture), false
	}
	assets.image_destroy(&fallback)

	rig :: proc(models: ^assets.Manifest, character: string, clips: []dungeon.Clip_Config) -> (err: string, ok: bool) {
		ch: assets.Character
		if ch, err, ok = assets.character_load(models.characters[character], context.temp_allocator); !ok {
			return
		}
		defer assets.character_destroy_texture(&ch)
		for clip in clips {
			if _, err, ok = assets.clip_load(models.animations[clip.file], clip.clip, &ch, context.temp_allocator); !ok {
				return
			}
		}
		return "", true
	}
	play := cfg.play
	if err, ok = rig(&models, play.character, {play.idle, play.move, play.swing, play.hurt, play.death, play.celebrate}); !ok {
		return
	}
	if e := cfg.enemies; e.enabled {
		if err, ok = rig(&models, e.character, {e.idle, e.move, e.attack, e.hurt, e.death}); !ok {
			return
		}
	}

	if cfg.sounds.enabled {
		// Loading the bank checks that every sound file is there.
		if _, err, ok = sound.bank_load(cfg.sounds.manifest, base, context.temp_allocator); !ok {
			return
		}
	}
	if _, err, ok = hud.fonts_load(&cfg.ui, base, context.temp_allocator); !ok {
		return
	}
	return "", true
}

// Whether every folder and file name in a path matches what is on disk
// letter for letter. Returns the first part that does not.
@(private)
exact_spelling :: proc(base, path: string, listings: ^map[string][]os.File_Info) -> (wrong: string, ok: bool) {
	dir := strings.trim_right(base, "/")
	rest := path
	for part in strings.split_iterator(&rest, "/") {
		entries, cached := listings[dir]
		if !cached {
			entries, _ = os.read_all_directory_by_path(dir == "" ? "." : dir, context.temp_allocator)
			listings[strings.clone(dir, context.temp_allocator)] = entries
		}
		found := false
		for entry in entries {
			found ||= entry.name == part
		}
		if !found {
			return part, false
		}
		dir = strings.concatenate({dir, dir == "" ? "" : "/", part}, context.temp_allocator)
	}
	return "", true
}