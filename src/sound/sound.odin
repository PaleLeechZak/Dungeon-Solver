// Which sound an in-game action makes. This package reads the sound manifest
// and turns the simulation's Sound_Events into "play this file at this
// volume". It decides; it does not play. No SDL in here.
package sound

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"

import "../dungeon"

// The manifest file as written; see config/sounds.json5.
Manifest_File :: struct {
	root:  string,
	files: map[string]string, // id -> path under root
	hooks: map[string]Hook_File, // dungeon.Sound_Kind name -> what it plays
	music: Music_File,
}

// Background music: each track is a seamless loop, played `repeats` times
// over before the next one takes its place.
Music_File :: struct {
	tracks:  []string, // ids from `files`
	repeats: int,
}

// The three volumes of the options screen. Every sound effect is scaled by
// master * sound, music by master * music.
Mixer :: struct {
	master, sound, music: f32,
}

music_gain :: proc(mixer: Mixer) -> f32 {
	return clamp(mixer.master * mixer.music, 0, 1)
}

Hook_File :: struct {
	sounds:   []string, // ids from `files`
	volume:   f32,
	interval: f32,
	bus:      string, // "sound" (the default) or "music": which mixer volume applies
}

// One file of the manifest.
Sound :: struct {
	id:   string,
	path: string, // ready to open: base + root + the manifest's path
}

Hook :: struct {
	sounds:   []int, // indices into Bank.sounds
	volume:   f32,
	interval: f32, // seconds before the same action may sound again
	music:    bool, // on the music bus: a musical phrase rather than an effect
}

// The manifest, checked and indexed, plus the little state needed to vary
// and thin out what gets played.
Bank :: struct {
	sounds:      []Sound, // every file the game uses, sorted by id
	hooks:       [dungeon.Sound_Kind]Hook,
	music:       []int, // the playlist, as indices into sounds; empty for no music
	repeats:     int, // times a track loops before the next
	track:       int, // position in the playlist, -1 before the first
	repeats_left: int,
	clock:       f32,
	last_played: [dungeon.Sound_Kind]f32, // clock time
	last_choice: [dungeon.Sound_Kind]int, // index into the hook's sounds, -1 before the first
	rng:         dungeon.Rng,
}

// What to play for one event.
Request :: struct {
	sound: int, // index into Bank.sounds
	gain:  f32, // 0..1
}

// Parses and checks a manifest. `base` is put in front of the root, which
// lets tests run from any directory. With `check_files` every listed file
// has to exist. The manifest is refused if a hook names an action or a sound
// that does not exist, if an action has no hook, or if a listed file is not
// played by any hook: the list has to be exactly what is used.
bank_parse :: proc(
	data: []byte,
	base := "",
	check_files := true,
	allocator := context.allocator,
) -> (
	bank: Bank,
	err: string,
	ok: bool,
) {
	fail :: proc(allocator: runtime.Allocator, format: string, args: ..any) -> (Bank, string, bool) {
		return {}, fmt.aprintf(format, ..args, allocator = allocator), false
	}

	file: Manifest_File
	if uerr := json.unmarshal(data, &file, json.Specification.JSON5, context.temp_allocator); uerr != nil {
		return fail(allocator, "sound manifest parse error: %v", uerr)
	}

	ids := make([dynamic]string, context.temp_allocator)
	for id in file.files {
		append(&ids, id)
	}
	slice.sort(ids[:])
	bank.sounds = make([]Sound, len(ids), allocator)
	for id, i in ids {
		path := file.files[id]
		if path == "" {
			return fail(allocator, "sound '%s' has no path", id)
		}
		for other in ids[:i] {
			if file.files[other] == path {
				return fail(allocator, "sounds '%s' and '%s' are the same file", other, id)
			}
		}
		bank.sounds[i] = {
			id   = strings.clone(id, allocator),
			path = strings.concatenate({base, file.root, "/", path}, allocator),
		}
		if check_files && !os.exists(bank.sounds[i].path) {
			return fail(allocator, "sound '%s': %s does not exist", id, bank.sounds[i].path)
		}
	}

	used := make([]bool, len(ids), context.temp_allocator)
	hooked: bit_set[dungeon.Sound_Kind]
	for name, hook in file.hooks {
		kind, known := reflect.enum_from_name(dungeon.Sound_Kind, name)
		if !known {
			return fail(allocator, "hook '%s' is not an in-game action", name)
		}
		hooked += {kind}
		indices := make([]int, len(hook.sounds), allocator)
		for id, i in hook.sounds {
			index, found := slice.binary_search(ids[:], id)
			if !found {
				return fail(allocator, "hook '%s' plays '%s', which is not in the file list", name, id)
			}
			indices[i] = index
			used[index] = true
		}
		if hook.bus != "" && hook.bus != "sound" && hook.bus != "music" {
			return fail(allocator, "hook '%s' is on bus '%s'; the buses are \"sound\" and \"music\"", name, hook.bus)
		}
		bank.hooks[kind] = {
			sounds   = indices,
			volume   = hook.volume,
			interval = hook.interval,
			music    = hook.bus == "music",
		}
	}
	bank.repeats = max(file.music.repeats, 1)
	bank.track = -1
	bank.music = make([]int, len(file.music.tracks), allocator)
	for id, i in file.music.tracks {
		index, found := slice.binary_search(ids[:], id)
		if !found {
			return fail(allocator, "music track '%s' is not in the file list", id)
		}
		bank.music[i] = index
		used[index] = true
	}
	for kind in dungeon.Sound_Kind {
		if kind not_in hooked {
			return fail(allocator, "no hook for the action %v; list it with an empty \"sounds\" to keep it silent", kind)
		}
	}
	for id, i in ids {
		if !used[i] {
			return fail(allocator, "sound '%s' is listed but no hook or music entry plays it", id)
		}
	}

	for &choice in bank.last_choice {
		choice = -1
	}
	for &played in bank.last_played {
		played = -1e6
	}
	bank.rng = dungeon.rng_make(0x50_55_4E_44)
	return bank, "", true
}

bank_load :: proc(path: string, base := "", allocator := context.allocator) -> (bank: Bank, err: string, ok: bool) {
	full := strings.concatenate({base, path}, context.temp_allocator)
	data, read_err := os.read_entire_file(full, context.temp_allocator)
	if read_err != nil {
		return {}, fmt.aprintf("cannot read sound manifest '%s': %v", full, read_err, allocator = allocator), false
	}
	return bank_parse(data, base, true, allocator)
}

// The piece of music to queue next: the current track until it has had its
// repeats, then the following one, round and round the playlist.
music_next :: proc(bank: ^Bank) -> (sound: int, ok: bool) {
	if len(bank.music) == 0 {
		return -1, false
	}
	if bank.repeats_left <= 0 {
		bank.track = (bank.track + 1) % len(bank.music)
		bank.repeats_left = bank.repeats
	}
	bank.repeats_left -= 1
	return bank.music[bank.track], true
}

// Moves the bank's clock on; intervals are measured against it.
bank_tick :: proc(bank: ^Bank, dt: f32) {
	bank.clock += dt
}

// Decides what, if anything, an event sounds like to a listener standing at
// `listener`. Nothing is played when the hook is silent, the event is out of
// earshot, or the same action sounded less than its interval ago.
bank_trigger :: proc(
	bank: ^Bank,
	event: dungeon.Sound_Event,
	listener: [2]f32,
	cfg: ^dungeon.Sound_Config,
	mixer: Mixer,
) -> (
	request: Request,
	ok: bool,
) {
	hook := &bank.hooks[event.kind]
	if !cfg.enabled || len(hook.sounds) == 0 {
		return
	}
	d := event.pos - listener
	// Linear fade with distance; squared so that it drops off quickly at first.
	nearness := 1 - min(math.sqrt(d.x * d.x + d.y * d.y) / cfg.hearing, 1)
	gain := mixer.master * (hook.music ? mixer.music : mixer.sound) * hook.volume * nearness * nearness
	if gain <= 0.001 {
		return
	}
	if bank.clock - bank.last_played[event.kind] < hook.interval {
		return
	}

	// Any of the hook's sounds but the one it played last.
	choice := 0
	if len(hook.sounds) > 1 {
		choice = dungeon.rng_int(&bank.rng, len(hook.sounds) - 1)
		if choice >= bank.last_choice[event.kind] && bank.last_choice[event.kind] >= 0 {
			choice += 1
		}
	}
	bank.last_choice[event.kind] = choice
	bank.last_played[event.kind] = bank.clock
	return {sound = hook.sounds[choice], gain = min(gain, 1)}, true
}
