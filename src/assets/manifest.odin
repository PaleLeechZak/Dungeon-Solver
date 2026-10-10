package assets

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import "../dungeon"

// The model manifest: the record of which model files, out of the thousands
// under assets/, the game actually uses. The config names models, characters
// and animation files by the ids listed here, nothing else is ever loaded,
// and the packaging script ships exactly these. See config/models.json5.
Manifest_File :: struct {
	root:       string,
	models:     map[string]string, // id -> .gltf under root: tiles, props, items, weapons
	characters: map[string]string, // id -> skinned .glb
	animations: map[string]string, // id -> .glb holding animation clips
}

Manifest :: struct {
	// id -> path ready to open (base + root + the manifest's path)
	models:     map[string]string,
	characters: map[string]string,
	animations: map[string]string,
}

@(private)
manifest_section :: proc(
	out: ^map[string]string,
	source: map[string]string,
	kind, base, root: string,
	check_files: bool,
	allocator: runtime.Allocator,
) -> (
	err: string,
	ok: bool,
) {
	out^ = make(map[string]string, allocator)
	for id, path in source {
		if id == "" || path == "" {
			return fmt.aprintf("%s '%s' needs both an id and a path", kind, id, allocator = allocator), false
		}
		// ':' picks a node out of a model, so it cannot be part of an id.
		if strings.contains_rune(id, ':') {
			return fmt.aprintf("%s id '%s' must not contain ':'", kind, id, allocator = allocator), false
		}
		for other, other_path in source {
			if other != id && other_path == path {
				return fmt.aprintf("%ss '%s' and '%s' are the same file", kind, other, id, allocator = allocator), false
			}
		}
		full := strings.concatenate({base, root, "/", path}, allocator)
		if check_files && !os.exists(full) {
			return fmt.aprintf("%s '%s': %s does not exist", kind, id, full, allocator = allocator), false
		}
		out[strings.clone(id, allocator)] = full
	}
	return "", true
}

// Parses a manifest. `base` is put in front of the root, which lets tests run
// from any directory. With `check_files` every listed file has to exist.
manifest_parse :: proc(
	data: []byte,
	base := "",
	check_files := true,
	allocator := context.allocator,
) -> (
	m: Manifest,
	err: string,
	ok: bool,
) {
	file: Manifest_File
	if uerr := json.unmarshal(data, &file, json.Specification.JSON5, context.temp_allocator); uerr != nil {
		return {}, fmt.aprintf("model manifest parse error: %v", uerr, allocator = allocator), false
	}
	if err, ok = manifest_section(&m.models, file.models, "model", base, file.root, check_files, allocator); !ok {
		return
	}
	if err, ok = manifest_section(&m.characters, file.characters, "character", base, file.root, check_files, allocator); !ok {
		return
	}
	if err, ok = manifest_section(&m.animations, file.animations, "animation", base, file.root, check_files, allocator); !ok {
		return
	}
	return m, "", true
}

manifest_load :: proc(path: string, base := "", allocator := context.allocator) -> (m: Manifest, err: string, ok: bool) {
	full := strings.concatenate({base, path}, context.temp_allocator)
	data, read_err := os.read_entire_file(full, context.temp_allocator)
	if read_err != nil {
		return {}, fmt.aprintf("cannot read model manifest '%s': %v", full, read_err, allocator = allocator), false
	}
	return manifest_parse(data, base, true, allocator)
}

// The manifest id a model name refers to: "wall_doorway:wall_doorway_door"
// is a node of the model "wall_doorway".
model_id :: proc(name: string) -> string {
	if colon := strings.index_byte(name, ':'); colon >= 0 {
		return name[:colon]
	}
	return name
}

// Every character and animation file id the config refers to. With
// `everything`, also those of features that are currently switched off.
@(private)
config_rig_ids :: proc(
	cfg: ^dungeon.Config,
	everything: bool,
	allocator: runtime.Allocator,
) -> (
	characters: [dynamic]string,
	animations: [dynamic]string,
) {
	characters = make([dynamic]string, allocator)
	animations = make([dynamic]string, allocator)
	append(&characters, cfg.play.character)
	for clip in ([]dungeon.Clip_Config{cfg.play.idle, cfg.play.move, cfg.play.swing, cfg.play.hurt, cfg.play.death, cfg.play.celebrate}) {
		append(&animations, clip.file)
	}
	if cfg.enemies.enabled || everything {
		e := cfg.enemies
		append(&characters, e.character)
		for clip in ([]dungeon.Clip_Config{e.idle, e.move, e.attack, e.hurt, e.death}) {
			append(&animations, clip.file)
		}
	}
	return
}

// Checks the manifest against the config, both ways round: everything the
// config asks for has to be listed, and everything listed has to be asked
// for. The list is only a record of what is used if neither can drift.
manifest_check :: proc(m: ^Manifest, cfg: ^dungeon.Config, allocator := context.allocator) -> (err: string, ok: bool) {
	has :: proc(list: []string, id: string) -> bool {
		for entry in list {
			if entry == id {
				return true
			}
		}
		return false
	}

	// Needed now, and allowed: a feature switched off in the config (no
	// swords, no skeletons) keeps its files without them counting as unused.
	needed := dungeon.config_model_names(cfg, context.temp_allocator)
	all := cfg^
	all.enemies.enabled = true
	all.items.swords = max(all.items.swords, 1)
	allowed := dungeon.config_model_names(&all, context.temp_allocator)
	for name in needed {
		if model_id(name) not_in m.models {
			return fmt.aprintf("the config uses model '%s', which is not in the model manifest", model_id(name), allocator = allocator), false
		}
	}
	for id in m.models {
		used := false
		for name in allowed {
			used ||= model_id(name) == id
		}
		if !used {
			return fmt.aprintf("model '%s' is in the manifest but the config does not use it", id, allocator = allocator), false
		}
	}

	characters, animations := config_rig_ids(cfg, false, context.temp_allocator)
	all_characters, all_animations := config_rig_ids(cfg, true, context.temp_allocator)
	for id in characters {
		if id not_in m.characters {
			return fmt.aprintf("the config uses character '%s', which is not in the model manifest", id, allocator = allocator), false
		}
	}
	for id in animations {
		if id not_in m.animations {
			return fmt.aprintf("the config uses animation file '%s', which is not in the model manifest", id, allocator = allocator), false
		}
	}
	for id in m.characters {
		if !has(all_characters[:], id) {
			return fmt.aprintf("character '%s' is in the manifest but the config does not use it", id, allocator = allocator), false
		}
	}
	for id in m.animations {
		if !has(all_animations[:], id) {
			return fmt.aprintf("animation file '%s' is in the manifest but the config does not use it", id, allocator = allocator), false
		}
	}
	return "", true
}

// The files a .gltf cannot be loaded without: its buffers and images, given
// as paths next to it. A .glb carries everything inside and has none.
gltf_dependencies :: proc(path: string, allocator := context.allocator) -> (files: []string, ok: bool) {
	if !strings.has_suffix(path, ".gltf") {
		return nil, true
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return nil, false
	}
	Uri :: struct {
		uri: string,
	}
	doc: struct {
		buffers: []Uri,
		images:  []Uri,
	}
	if json.unmarshal(data, &doc, json.Specification.JSON, context.temp_allocator) != nil {
		return nil, false
	}
	dir := path[:strings.last_index_byte(path, '/') + 1]
	out := make([dynamic]string, allocator)
	add :: proc(out: ^[dynamic]string, dir, uri: string, allocator: runtime.Allocator) {
		// Embedded data is not a file.
		if uri == "" || strings.has_prefix(uri, "data:") {
			return
		}
		full := strings.concatenate({dir, uri}, allocator)
		for existing in out {
			if existing == full {
				return
			}
		}
		append(out, full)
	}
	for buffer in doc.buffers do add(&out, dir, buffer.uri, allocator)
	for image in doc.images do add(&out, dir, image.uri, allocator)
	return out[:], true
}
