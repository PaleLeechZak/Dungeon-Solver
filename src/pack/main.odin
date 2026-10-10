// Stages a release: copies the executable and exactly the data files the
// config and the manifests call for into one folder, then proves the copy is
// complete by loading everything from it. package.bat zips the result.
// Opens no window and needs no GPU.
//
//   odin run src/pack -- <output folder> <windows|linux> [config path] [folder with the binaries]
//
// The data files are the same for both platforms; only the binaries and the
// note on how to run them differ. The tool itself runs on Windows either way.
package pack

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

import "../bundle"

Platform :: struct {
	name:     string,
	binaries: []string, // copied from the binaries folder to the package root
	built_by: string, // script that produces them
	how:      string, // README: how to start the game
}

PLATFORMS := [?]Platform {
	{
		name = "windows",
		binaries = {"dungeon.exe", "SDL3.dll"},
		built_by = "build.bat",
		how = "Run dungeon.exe from this folder.",
	},
	{
		name = "linux",
		binaries = {"dungeon"},
		built_by = "build_linux.bat",
		how = "Install SDL3 (Fedora: sudo dnf install SDL3, Debian/Ubuntu: sudo apt install libsdl3-0),\nthen run ./dungeon from this folder.",
	},
}

README :: `Dungeon Solver

%s

Controls are shown on screen and can be changed from the pause menu
(Esc, or Start on a gamepad). Settings are saved to settings.json here.

config/dungeon.json5 holds everything tunable. The asset packs under assets/
are the work of their authors; their licence files are included beside them.
`

main :: proc() {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.eprintln("out of memory")
		os.exit(1)
	}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	context.temp_allocator = allocator

	platform: Platform
	if len(os.args) > 2 {
		for candidate in PLATFORMS {
			if candidate.name == os.args[2] {
				platform = candidate
			}
		}
	}
	if platform.name == "" {
		fmt.eprintln("usage: pack <output folder> <windows|linux> [config path] [folder with the binaries]")
		os.exit(2)
	}
	out := strings.trim_right(os.args[1], "/\\")
	config := len(os.args) > 3 ? os.args[3] : "config/dungeon.json5"
	binaries := len(os.args) > 4 ? strings.trim_right(os.args[4], "/\\") : (platform.name == "linux" ? "build/linux" : "build")

	files, err, ok := bundle.collect(config, "", allocator)
	if !ok {
		fmt.eprintfln("cannot work out what to package: %s", err)
		os.exit(1)
	}

	// Start from nothing, so a file dropped from a manifest is dropped from
	// the package too.
	if os.exists(out) && os.remove_all(out) != nil {
		fmt.eprintfln("cannot clear %s", out)
		os.exit(1)
	}
	copy_into :: proc(out, from, to: string) -> (size: i64, ok: bool) {
		target := strings.concatenate({out, "/", to})
		if slash := strings.last_index_byte(target, '/'); slash > 0 {
			if os.make_directory_all(target[:slash]) != nil && !os.is_directory(target[:slash]) {
				fmt.eprintfln("cannot create %s", target[:slash])
				return 0, false
			}
		}
		if os.copy_file(target, from) != nil {
			fmt.eprintfln("cannot copy %s to %s", from, target)
			return 0, false
		}
		info, stat_err := os.stat(target, context.temp_allocator)
		return info.size, stat_err == nil
	}

	total: i64
	for file in files {
		size, copied := copy_into(out, file, file)
		if !copied {
			os.exit(1)
		}
		total += size
	}
	for binary in platform.binaries {
		size, copied := copy_into(out, strings.concatenate({binaries, "/", binary}), binary)
		if !copied {
			fmt.eprintfln("build the game first: %s", platform.built_by)
			os.exit(1)
		}
		total += size
	}
	readme := fmt.aprintf(README, platform.how)
	if os.write_entire_file(strings.concatenate({out, "/README.txt"}), transmute([]byte)readme) != nil {
		fmt.eprintln("cannot write README.txt")
		os.exit(1)
	}

	if verr, verified := bundle.verify(out, config); !verified {
		fmt.eprintfln("the package is incomplete: %s", verr)
		os.exit(1)
	}
	fmt.printfln(
		"staged %d data files and %d %s binaries, %.1f MB, in %s",
		len(files),
		len(platform.binaries),
		platform.name,
		f64(total) / (1024 * 1024),
		out,
	)
	fmt.println("verified: everything the game loads at start-up loads from the package")
}
