#!/usr/bin/env bash
# Builds the game for Linux. Meant to be run inside WSL (build_linux.bat does
# that from Windows), but works on any Linux with the tools below.
#
#   ./build_linux.sh            optimised build  -> build/linux/dungeon
#   ./build_linux.sh debug      debug build with GPU validation
#   ./build_linux.sh test       run every test package on Linux
#   ./build_linux.sh archive <folder> <zip>
#                               zip a staged release, keeping the game executable
#
# Needs: a Linux build of Odin (ODIN=/path/to/odin to pick one), clang, ar,
# and SDL3 with its development files. Nothing here runs the game.
set -euo pipefail
cd "$(dirname "$0")"

mode="${1:-release}"
case "$mode" in
release | debug | test | archive) ;;
*)
	echo "usage: $0 [release|debug|test|archive <folder> <zip>]" >&2
	exit 2
	;;
esac

fail() {
	echo "build_linux: $*" >&2
	exit 1
}

# --- archive -----------------------------------------------------------------
# Zips a staged Linux release (see package.bat). Done on the Linux side
# because a zip written by Windows tools cannot mark the game as executable,
# and one that carried a Windows drive's permissions would mark everything so.
if [ "$mode" = archive ]; then
	folder="${2:-}"
	target="${3:-}"
	[ -d "$folder" ] && [ -n "$target" ] || fail "usage: $0 archive <folder> <zip>"
	[ -f "$folder/dungeon" ] || fail "$folder holds no Linux build of the game."
	command -v python3 >/dev/null || fail "python3 is missing (Fedora: sudo dnf install python3, Debian/Ubuntu: sudo apt install python3)."
	rm -f "$target"
	python3 - "$folder" "$target" <<'PY'
import os, sys, zipfile

folder, target = os.path.abspath(sys.argv[1]), sys.argv[2]
parent = os.path.dirname(folder)
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, dirs, files in os.walk(folder):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            info = zipfile.ZipInfo.from_file(path, os.path.relpath(path, parent))
            # Only the game itself is a program; everything else is data.
            executable = os.path.relpath(path, folder) == "dungeon"
            info.external_attr = (0o100755 if executable else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(path, "rb") as source:
                archive.writestr(info, source.read())
PY
	echo "Wrote $target"
	exit 0
fi

# --- tools -------------------------------------------------------------------

ODIN="${ODIN:-$(command -v odin || true)}"
[ -n "$ODIN" ] && [ -x "$ODIN" ] || fail "no Linux build of Odin found. Put one on PATH or set ODIN=/path/to/odin."
# Under WSL the Windows odin.exe is on PATH too; that one builds Windows programs.
if ! head -c 4 "$ODIN" | grep -q ELF; then
	fail "$ODIN is not a Linux executable. Set ODIN to a Linux build of Odin."
fi

command -v clang >/dev/null || fail "clang is missing (Fedora: sudo dnf install clang, Debian/Ubuntu: sudo apt install clang)."
AR="$(command -v llvm-ar || command -v ar || true)"
[ -n "$AR" ] || fail "no archiver found (Fedora: sudo dnf install binutils, Debian/Ubuntu: sudo apt install binutils)."
if ! pkg-config --exists sdl3 2>/dev/null; then
	fail "SDL3 development files are missing (Fedora: sudo dnf install SDL3-devel, Debian/Ubuntu: sudo apt install libsdl3-dev)."
fi

ODIN_ROOT="$("$ODIN" root)"
ODIN_ROOT="${ODIN_ROOT%/}"

# --- Odin's bundled C libraries ----------------------------------------------
# Odin ships cgltf and stb as C sources; their Linux static libraries have to
# be built once, next to the bindings, before anything that imports them links.
# This adds six .a files to the Odin installation and touches nothing else.
ensure_vendor_lib() {
	local lib="$1" source="$2"
	[ -f "$lib" ] && return
	echo "Building $(basename "$lib") from $source (one-off, part of setting Odin up on Linux)"
	local object="$out/$(basename "$lib" .a).o"
	clang -c -O2 -fPIC -w "$source" -o "$object" || fail "could not compile $source."
	"$AR" rcs "$lib" "$object" || fail "could not write $lib. Is $ODIN_ROOT writable?"
}

out="build/linux"
mkdir -p "$out"

ensure_vendor_lib "$ODIN_ROOT/vendor/cgltf/lib/cgltf.a" "$ODIN_ROOT/vendor/cgltf/src/cgltf.c"
# The stb image and truetype bindings pull in their neighbours, used or not.
for name in stb_image stb_image_write stb_image_resize stb_rect_pack stb_truetype; do
	ensure_vendor_lib "$ODIN_ROOT/vendor/stb/lib/$name.a" "$ODIN_ROOT/vendor/stb/src/$name.c"
done

# --- build or test -----------------------------------------------------------

if [ "$mode" = test ]; then
	# The same headless tests as test.bat. Worth running here in their own
	# right: Linux file names are case sensitive, Windows ones are not, so a
	# path in a config or manifest that only works on Windows fails here.
	for package in dungeon camera assets input ui hud sound menu bundle game; do
		echo "=== $package ==="
		"$ODIN" test "src/$package" -out:"$out/${package}_test" -vet -strict-style
	done
	echo "All test packages passed on Linux."
	exit 0
fi

flags="-o:speed"
[ "$mode" = debug ] && flags="-debug"

"$ODIN" build src/game -out:"$out/dungeon" -vet -strict-style $flags

echo "Built $out/dungeon (links SDL $(pkg-config --modversion sdl3))."
echo "Run it from this folder on a Linux desktop with SDL3 installed: $out/dungeon [config path]"
