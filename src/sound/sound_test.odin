package sound

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import "../dungeon"

ROOT :: #directory + "/../../"

@(private = "file")
Fixture :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	cfg:       dungeon.Config,
	bank:      Bank,
}

@(private = "file")
fixture_init :: proc(t: ^testing.T, f: ^Fixture) -> bool {
	if !testing.expect(t, virtual.arena_init_growing(&f.arena) == nil) {
		return false
	}
	f.allocator = virtual.arena_allocator(&f.arena)
	err: string
	ok: bool
	f.cfg, err, ok = dungeon.config_load(ROOT + "config/dungeon.json5", f.allocator)
	if !testing.expectf(t, ok, "config: %s", err) {
		return false
	}
	f.bank, err, ok = bank_load(f.cfg.sounds.manifest, ROOT, f.allocator)
	return testing.expectf(t, ok, "manifest: %s", err)
}

// The manifest is the record of which sound files the game uses. Loading it
// already checks that every file exists, every action has a hook and no file
// is listed without being played; this pins down the rest.
@(test)
manifest_lists_exactly_the_files_in_use :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	bank := &f.bank
	testing.expect(t, len(bank.sounds) > 20)

	plays := make([]int, len(bank.sounds), f.allocator)
	silent := 0
	for kind in dungeon.Sound_Kind {
		hook := bank.hooks[kind]
		silent += int(len(hook.sounds) == 0)
		for index in hook.sounds {
			if testing.expect(t, index >= 0 && index < len(bank.sounds)) {
				plays[index] += 1
			}
		}
		if len(hook.sounds) > 0 {
			testing.expectf(t, hook.volume > 0 && hook.volume <= 1, "%v has volume %v", kind, hook.volume)
			testing.expect(t, hook.interval >= 0)
		}
	}
	for index in bank.music {
		plays[index] += 1
	}
	for sound, i in bank.sounds {
		testing.expectf(t, plays[i] > 0, "'%s' is in the manifest but nothing plays it", sound.id)
		if i > 0 {
			testing.expect(t, bank.sounds[i - 1].id < sound.id, "the bank is sorted by id")
		}
		// A real WAV file, small enough to keep in memory.
		data, err := os.read_entire_file(sound.path, f.allocator)
		if testing.expectf(t, err == nil && len(data) > 44, "cannot read %s", sound.path) {
			testing.expectf(t, string(data[0:4]) == "RIFF" && string(data[8:12]) == "WAVE", "%s is not a WAV file", sound.path)
			testing.expectf(t, len(data) < 4 * 1024 * 1024, "%s is %d bytes", sound.path, len(data))
		}
		testing.expect(t, strings.has_suffix(sound.path, ".wav"))
	}
	// Every action is audible now, with more than one take of each.
	for kind in dungeon.Sound_Kind {
		testing.expectf(t, len(bank.hooks[kind].sounds) > 1, "%v should have variations", kind)
	}
	testing.expect_value(t, silent, 0)

	// The playlist: real files, each a loop long enough to be worth looping.
	testing.expect(t, len(bank.music) >= 3 && bank.repeats >= 1)
	for index in bank.music {
		info, err := os.stat(bank.sounds[index].path, f.allocator)
		testing.expect(t, err == nil && info.size > 1_000_000, "a music track should be several seconds long")
	}
}

@(test)
bad_manifests_are_refused :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	// A complete set of hooks, all playing the one sound "a".
	all_hooks :: proc(skip: dungeon.Sound_Kind, has_skip: bool, allocator: runtime.Allocator) -> string {
		sb := strings.builder_make(allocator)
		for kind in dungeon.Sound_Kind {
			if has_skip && kind == skip {
				continue
			}
			strings.write_string(&sb, `"`)
			fmt.sbprintf(&sb, "%v", kind)
			strings.write_string(&sb, `": {"sounds": ["a"], "volume": 1}, `)
		}
		return strings.to_string(sb)
	}
	hooks := all_hooks(.Knight_Step, false, allocator)
	good := strings.concatenate({`{"root": "r", "files": {"a": "a.wav"}, "hooks": {`, hooks, `}}`}, allocator)
	bank, err, ok := bank_parse(transmute([]byte)good, "", false, allocator)
	testing.expectf(t, ok, "a minimal manifest should load: %s", err)
	testing.expect_value(t, len(bank.sounds), 1)
	testing.expect_value(t, bank.sounds[0].path, "r/a.wav")

	bad := []string {
		`{ nope`,
		// a file nobody plays
		strings.concatenate({`{"root": "r", "files": {"a": "a.wav", "b": "b.wav"}, "hooks": {`, hooks, `}}`}, allocator),
		// a hook playing a sound that is not listed
		strings.concatenate({`{"root": "r", "files": {"a": "a.wav"}, "hooks": {`, hooks, `"Sword_Hit": {"sounds": ["zzz"]}}}`}, allocator),
		// a hook for an action the game does not have
		strings.concatenate({`{"root": "r", "files": {"a": "a.wav"}, "hooks": {`, hooks, `"Dragon_Roar": {"sounds": ["a"]}}}`}, allocator),
		// an action without a hook
		strings.concatenate({`{"root": "r", "files": {"a": "a.wav"}, "hooks": {`, all_hooks(.Door_Open, true, allocator), `}}`}, allocator),
		// music that is not in the file list
		strings.concatenate({`{"root": "r", "files": {"a": "a.wav"}, "music": {"tracks": ["tune"]}, "hooks": {`, hooks, `}}`}, allocator),
		// the same file under two names
		strings.concatenate({`{"root": "r", "files": {"a": "a.wav", "b": "a.wav"}, "hooks": {`, hooks, `"Sword_Hit": {"sounds": ["a", "b"]}}}`}, allocator),
	}
	for text in bad {
		_, message, loaded := bank_parse(transmute([]byte)text, "", false, allocator)
		testing.expectf(t, !loaded, "manifest should be refused: %s", text)
		testing.expect(t, loaded || message != "")
	}

	// A music track counts as a use of its file.
	with_music := strings.concatenate({`{"root": "r", "files": {"a": "a.wav", "tune": "tune.wav"}, "music": {"tracks": ["tune"]}, "hooks": {`, hooks, `}}`}, allocator)
	bank, err, ok = bank_parse(transmute([]byte)with_music, "", false, allocator)
	testing.expectf(t, ok, "a manifest with music should load: %s", err)
	testing.expect_value(t, len(bank.music), 1)
	testing.expect_value(t, bank.sounds[bank.music[0]].id, "tune")
	testing.expect_value(t, bank.repeats, 1) // left out, a track plays once through

	// A hook can be put on the music bus, but not on a bus that does not exist.
	on_bus := strings.concatenate({`{"root": "r", "files": {"a": "a.wav"}, "hooks": {`, hooks, `"Sword_Hit": {"sounds": ["a"], "bus": "music"}}}`}, allocator)
	bank, err, ok = bank_parse(transmute([]byte)on_bus, "", false, allocator)
	testing.expectf(t, ok, "%s", err)
	testing.expect(t, bank.hooks[.Sword_Hit].music && !bank.hooks[.Knight_Step].music)
	wrong_bus := strings.concatenate({`{"root": "r", "files": {"a": "a.wav"}, "hooks": {`, hooks, `"Sword_Hit": {"sounds": ["a"], "bus": "voice"}}}`}, allocator)
	_, _, ok = bank_parse(transmute([]byte)wrong_bus, "", false, allocator)
	testing.expect(t, !ok)

	// With file checking on, a path that leads nowhere is refused too.
	_, _, ok = bank_parse(transmute([]byte)good, "", true, allocator)
	testing.expect(t, !ok)
}

@(test)
events_become_requests :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	bank, cfg := &f.bank, &f.cfg.sounds
	mixer := Mixer{1, 1, 1}

	// Right at the listener: the hook's own volume, one of the hook's sounds.
	request, ok := bank_trigger(bank, {.Sword_Hit, {10, 10}}, {10, 10}, cfg, mixer)
	testing.expect(t, ok)
	testing.expect(t, abs(request.gain - bank.hooks[.Sword_Hit].volume) < 1e-4)
	found := false
	for index in bank.hooks[.Sword_Hit].sounds {
		found ||= index == request.sound
	}
	testing.expect(t, found)
	testing.expect(t, strings.contains(bank.sounds[request.sound].path, "Strike Blade"))

	// Further away is quieter, and past earshot is not played at all.
	bank_tick(bank, 1)
	near, _ := bank_trigger(bank, {.Sword_Hit, {10 + cfg.hearing * 0.25, 10}}, {10, 10}, cfg, mixer)
	bank_tick(bank, 1)
	far, far_ok := bank_trigger(bank, {.Sword_Hit, {10 + cfg.hearing * 0.75, 10}}, {10, 10}, cfg, mixer)
	testing.expect(t, far_ok)
	testing.expect(t, near.gain < request.gain && far.gain < near.gain && far.gain > 0)
	bank_tick(bank, 1)
	_, heard := bank_trigger(bank, {.Sword_Hit, {10 + cfg.hearing * 1.5, 10}}, {10, 10}, cfg, mixer)
	testing.expect(t, !heard)

	// The mixer: master and sound volume both scale an effect, the music
	// volume does not touch it, and either at zero silences it.
	bank_tick(bank, 1)
	half, _ := bank_trigger(bank, {.Sword_Hit, {10, 10}}, {10, 10}, cfg, Mixer{0.5, 1, 1})
	testing.expect(t, abs(half.gain - request.gain / 2) < 1e-4)
	bank_tick(bank, 1)
	quarter, _ := bank_trigger(bank, {.Sword_Hit, {10, 10}}, {10, 10}, cfg, Mixer{0.5, 0.5, 0})
	testing.expect(t, abs(quarter.gain - request.gain / 4) < 1e-4)
	bank_tick(bank, 1)
	_, heard = bank_trigger(bank, {.Sword_Hit, {10, 10}}, {10, 10}, cfg, Mixer{1, 0, 1})
	testing.expect(t, !heard)
	bank_tick(bank, 1)
	_, heard = bank_trigger(bank, {.Sword_Hit, {10, 10}}, {10, 10}, cfg, Mixer{0, 1, 1})
	testing.expect(t, !heard)
	// Music has its own gain, also under the master.
	testing.expect_value(t, music_gain({0.5, 1, 0.5}), 0.25)
	testing.expect_value(t, music_gain({1, 0, 1}), 1)
	testing.expect_value(t, music_gain({0, 1, 1}), 0)

	bank_tick(bank, 1)
	cfg.enabled = false
	_, heard = bank_trigger(bank, {.Sword_Hit, {10, 10}}, {10, 10}, cfg, mixer)
	testing.expect(t, !heard)
	cfg.enabled = true

	// A hook with nothing to play stays silent without complaint.
	bank.hooks[.Door_Open].sounds = nil
	_, heard = bank_trigger(bank, {.Door_Open, {10, 10}}, {10, 10}, cfg, mixer)
	testing.expect(t, !heard)

	// A hook on the music bus follows the music volume, not the sound volume.
	testing.expect(t, bank.hooks[.Game_Won].music)
	testing.expect(t, bank.hooks[.Game_Lost].music, "defeat has its own musical phrase")
	testing.expect(t, !bank.hooks[.Amulet_Pickup].music)
	fanfare, _ := bank_trigger(bank, {.Game_Won, {10, 10}}, {10, 10}, cfg, Mixer{1, 0, 0.5})
	testing.expect(t, abs(fanfare.gain - bank.hooks[.Game_Won].volume * 0.5) < 1e-4)
	bank_tick(bank, 1)
	_, heard = bank_trigger(bank, {.Game_Won, {10, 10}}, {10, 10}, cfg, Mixer{1, 1, 0})
	testing.expect(t, !heard)
}

@(test)
repeats_are_varied_and_spaced_out :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	bank, cfg := &f.bank, &f.cfg.sounds
	hook := bank.hooks[.Knight_Step]
	if !testing.expect(t, len(hook.sounds) > 1 && hook.interval > 0) {
		return
	}

	// A crowd of skeletons taking a step in the same frame is one footfall.
	first, ok := bank_trigger(bank, {.Knight_Step, {}}, {}, cfg, Mixer{1, 1, 1})
	testing.expect(t, ok)
	_, again := bank_trigger(bank, {.Knight_Step, {}}, {}, cfg, Mixer{1, 1, 1})
	testing.expect(t, !again, "the same action inside its interval is dropped")
	// Other actions are not held up by it.
	_, other := bank_trigger(bank, {.Sword_Swing, {}}, {}, cfg, Mixer{1, 1, 1})
	testing.expect(t, other)

	// Once the interval has passed it sounds again, never the same file twice
	// running, and over time every variation gets its turn.
	seen := make(map[int]int, f.allocator)
	seen[first.sound] = 1
	previous := first.sound
	for _ in 0 ..< 200 {
		bank_tick(bank, hook.interval + 0.01)
		request, played := bank_trigger(bank, {.Knight_Step, {}}, {}, cfg, Mixer{1, 1, 1})
		if !testing.expect(t, played) {
			break
		}
		testing.expect(t, request.sound != previous, "the same footstep twice in a row")
		previous = request.sound
		seen[request.sound] += 1
	}
	testing.expect_value(t, len(seen), len(hook.sounds))
}
@(test)
music_rotates_through_the_playlist :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	bank := &f.bank
	tracks, repeats := len(bank.music), bank.repeats
	if !testing.expect(t, tracks > 1) {
		return
	}

	// Each track is queued `repeats` times, then the next, and after the last
	// the first comes round again.
	for lap in 0 ..< 2 {
		for track in 0 ..< tracks {
			for _ in 0 ..< repeats {
				next, ok := music_next(bank)
				testing.expect(t, ok)
				testing.expectf(t, next == bank.music[track], "lap %d: expected track %d", lap, track)
			}
		}
	}

	// A track is never followed by itself once its repeats are up.
	previous, _ := music_next(bank)
	for _ in 1 ..< repeats {
		music_next(bank)
	}
	following, _ := music_next(bank)
	testing.expect(t, following != previous)

	// No playlist, no music.
	bank.music = nil
	_, ok := music_next(bank)
	testing.expect(t, !ok)
}