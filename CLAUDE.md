# Dungeon Solver

Config-driven dungeon generator written in Odin. The dungeon is a 2D grid laid
out from pre-constructed rooms joined by a node graph, drawn with the 3D tiles
of the KayKit Dungeon Pack through SDL3's GPU API. It can be inspected with a
free camera or played: a knight walks the dungeon, fights its skeletons,
collects keys and opens doors, with keyboard and mouse or a gamepad.

## Never launch the game

**Do not run the game to check your work. Not once, not "just to see if it starts".**

- Do not run `build\dungeon.exe`.
- Do not run `odin run src/game` (it builds *and launches*). Use `odin build`, or `build.bat`.
- Do not start it through a debugger, a background task, a screenshot tool or any other route.

Looking at the running game is a job for the human. When a change can only be
judged by eye or ear (lighting, model orientation, animation, camera or
movement feel, how a sound fits, anything on screen or from the speakers),
finish the code, make sure it builds and the tests pass, then say plainly what
you could not verify and what the human should look at. Never claim something
"looks right" or "renders correctly".

Verify with Odin's test framework instead:

- Prove behaviour with `@(test)` procedures from `core:testing`. A change to
  logic comes with a test; a bug fix comes with a test that failed before it.
- If something is hard to test because it is tangled up with SDL or the GPU,
  move the logic into a pure procedure and test that. `src/game/batch.odin` is
  the pattern: instance batching is plain data in, plain data out, and the
  renderer only uploads the result.
- To see a generated layout, use the headless dump tool below. It prints text
  and opens no window.
- Gameplay is tested by playing it in code. `play_test.odin` has a bot that
  walks a dungeon through the real movement, collision and pickup code until
  every key is held and every room seen; extend it rather than trying the
  game by hand.

## Commands

Run everything from the repository root; asset and config paths are relative to it.

| Task | Command |
| --- | --- |
| All tests | `test.bat` |
| One package | `odin test src/dungeon -out:build/dungeon_test.exe -vet -strict-style` |
| One test | add `-define:ODIN_TEST_NAMES=dungeon.same_seed_gives_same_dungeon` |
| Build only | `build.bat` (or `build.bat debug`) |
| Print a dungeon as text | `odin run src/dump -- config/dungeon.json5 <seed>` |
| Recompile shaders | `shaders\compile.bat`, then rebuild |
| Package release zips | `package.bat` for both platforms, or `package.bat windows` / `package.bat linux` (builds, stages, verifies, zips; does not run the game) |
| Build for Linux (through WSL) | `build_linux.bat` (or `debug`) -> `build\linux\dungeon` |
| Run the tests on Linux | `build_linux.bat test` |

Call the scripts with a path (`.\build.bat`, or `call "%~dp0build.bat"` from
another script): on this machine a bare `build.bat` resolves to a different
`build.bat` further along PATH. The same trap applies to `tar`: Git's GNU tar
is on PATH and will happily write a tar file named `.zip`, so `package.bat`
calls `%SystemRoot%\System32\tar.exe` by full path.

Test packages are `dungeon`, `camera`, `assets`, `input`, `ui`, `hud`, `sound`,
`menu`, `bundle` and `game`. The `game` tests link SDL3 but never call `main`, create a window, open
a gamepad or touch the GPU; keep it that way. `test.bat` copies `SDL3.dll` next
to the test binary for them.

Batch files need CRLF line endings or `cmd` misparses them; `build_linux.sh`
needs LF.

## Linux

`build_linux.bat` runs `build_linux.sh` in the default WSL distribution (set
`WSL_DISTRO` for another). The script needs a Linux build of Odin, clang, an
archiver and SDL3's development files, and says which is missing. On first run
it compiles Odin's bundled cgltf and stb sources into `.a` files inside the
Odin installation, which Odin expects on Linux. The Linux binary links the
system's SDL3 rather than carrying its own. "Never launch the game" applies
to `build/linux/dungeon` exactly as it does to the Windows build.

- Keep the code portable: forward slashes in paths, no Windows-only APIs
  outside what SDL and `core:os` already abstract.
- File names are case sensitive on Linux. `bundle.collect` rejects any path
  whose capitals differ from the name on disk, so `test.bat` catches this on
  Windows; WSL's view of a Windows drive would not.
- `package.bat linux` packages the Linux build; see Manifests and packaging.

## Layout

| Path | What lives there |
| --- | --- |
| `config/dungeon.json5` | Everything tunable: size, rooms, hallways, locks, tiles, camera |
| `config/sounds.json5` | The sound manifest: every sound file in use, and which action plays which |
| `config/models.json5` | The model manifest: every model, character and animation file in use |
| `src/dungeon/` | Generator, plus the knight simulation in `play.odin`. Pure Odin, no SDL. Most work and most tests happen here |
| `src/camera/` | Free camera and the knight's orbit camera. Pure Odin |
| `src/assets/` | glTF and texture loading to CPU memory (cgltf, stb_image), and CPU skinning in `character.odin`. No GPU |
| `src/input/` | Actions, bindings, last-used device and which prompt icon a control gets. Pure Odin |
| `src/ui/` | Font rasterising into an atlas (stb_truetype) and 2D draw lists. No GPU |
| `src/hud/` | HUD layout: health pips, status lines, control prompts. Pure Odin over `input` and `ui` |
| `src/menu/` | Pause menu, options and controls screens, and the saved settings. Pure Odin over `input`, `ui` and `hud` |
| `src/sound/` | Reads the sound manifest and turns sound events into "play this file this loud". Pure Odin |
| `src/game/` | SDL3 window, GPU renderer, device polling, audio playback, game loop. The only package that draws or plays |
| `src/dump/` | Headless text dump of a generated dungeon |
| `src/bundle/` | Works out the release file list from the config and manifests, and verifies a staged copy |
| `src/pack/` | Headless tool behind `package.bat`: stages the release folder |
| `shaders/` | HLSL sources; `compiled/` is embedded into the game with `#load` |
| `assets/` | KayKit packs (tiles, knight, skeletons, animations), Kenney input prompt fonts and fantasy UI kit, Crimson Pro, sound packs. Do not edit |
| `settings.json` | Written by the game: the player's volumes and bindings. Not in version control |

## How the generator works

Read `src/dungeon/generate.odin` before changing any of this.

- **Grid.** One cell is one 4x4 unit tile. Cell `(x, y)` is centred on world
  `(x * tile_size, 0, y * tile_size)`. North is `-y` / world `-Z`.
- **Walls are cells.** A room template is a rectangle whose outer ring holds its
  walls, doors and openings; the floor is the inside. Neighbouring rooms overlap
  by that ring and share it, so a wall cell can belong to several rooms.
- **Arms.** Each wall cell stores the directions it continues in, OR-ed
  together from every room using it. `wall_piece` turns arms into a model and a
  rotation: two opposite arms are a straight wall, two adjacent a corner, three
  a T-split, four a crossing.
- **Nodes.** A `D` on the ring is a door node. A run of `~` is an open node:
  walls left off. An open node only joins an open node of the same width, and
  the two rooms then read as one odd-shaped room.
- **Growth.** `rooms[0]` is the entrance, which holds the player spawn and is
  the seed point. Rooms attach to free nodes one at a time by landing their
  matching node on the same cells. Nodes nothing attached to are sealed back
  into wall. The result is a tree: `len(conns) == len(rooms) - 1`.
- **Hallways** are generated per dungeon from the `hallways` config, not
  authored: one floor tile wide, a door at each end, a chance of a side door on
  every wall cell. Dead-end hallways are pruned.
- **Locks.** Rooms are numbered in generation order and a parent always has a
  lower number than its children. The key for the door into room `n` goes into
  an item slot of a room numbered below `n`, which makes every dungeon solvable
  by induction. `solve` plays the dungeon and is the check for that.
- **Later stages.** Enemy spawn points and empty item slots are collected in
  `Dungeon.enemy_spawns` and `Dungeon.item_slots` for stages that do not exist
  yet. They are only drawn in free flight.
- **Determinism.** A seed fully determines a dungeon. Use `Rng` from
  `src/dungeon/rng.odin`; do not use `core:math/rand` in the generator.

Invariants the tests enforce, and that new code must keep: room floors never
overlap, every door or open cell has floor of its two rooms on either side,
every tile's model is listed by `config_model_names`, every lock has exactly
one key and `solve` reaches every room.

## Knight mode

Read `src/dungeon/play.odin` before changing any of this. Tab switches between
the knight and the free camera; `play.start` in the config picks the first one.

- **State.** `Play` holds the knight's position, the keys in hand and which
  doors stand open. It is created by `play_start` for every dungeon and never
  touches the `Dungeon` itself. `play_update` takes a direction on the ground
  and a time step; the game supplies both and draws the result.
- **Collision** is a circle against boxes built per cell by `cell_blockers`:
  a wall is a post plus one bar per arm, a shut door is a slab, an open door
  leaves a gap, decor and item slots are a box in the middle of their cell.
  The sizes are fractions of a tile (`WALL_HALF_THICKNESS`, `DOOR_HALF_OPENING`,
  `PROP_HALF_SIZE`) and `assets_test.odin` checks them against the models.
- **Winning and losing.** The goal is the amulet: `assign_amulet` hides one in
  a free item slot of the deepest room that has a slot. Picking it up starts a
  celebration (`play_celebrating`, `play.celebrate_time` seconds): the knight
  cheers on the spot and cannot be hurt, the skeletons hold still, and the
  amulet is drawn rising over its head (`amulet_height`). When that is over
  `Play.won` is set, after which `play_update` does nothing.
- **The camera** in knight mode is placed by `knight_shot` in
  `src/game/shots.odin`: the player's orbit round the knight, until the amulet
  is found, when it pans (`camera.shot_between`, `play.celebrate_pan` seconds)
  to a close-up of the amulet and holds there, ignoring look and zoom input,
  through the celebration and behind the victory screen. Dying sets `Play.dead`.
  `Play.time` counts the seconds played. The game shows `menu`'s `Won` or
  `Lost` screen (the latter `DEATH_PAUSE` seconds after the fall), which
  cannot be dismissed: it offers the same dungeon again, a new one, or the
  desktop. With no `items.amulet.model` there is no amulet and no way to win.
- **Items** are keys, swords and the amulet (`Item_Kind`). An item slot is either a chest
  (`I` in a layout) or a spot on the floor (`i`). Chests are solid and hide
  what they hold; things on the floor are visible and walked over.
- **Chests, pickups and doors** work by reach (`play.interact_radius`): coming
  near a chest opens it and awards its item (empty chests open too), coming
  near an item on the floor takes it, coming near a door opens it, a locked
  door only once its key is held. What was opened stays open. `Play.version`
  bumps on every such change and the game rebuilds the tiles only then.
- **Hidden versus revealed.** `build_tiles(..., reveal)` draws what a player on
  foot may see when `reveal` is false: chests, items on the floor, doors. With
  `reveal` (free flight) it adds the contents of closed chests floating above
  them, the spawn markers and empty floor slots. Anything that would spoil the
  game for the knight belongs behind `reveal`.
- **The sword.** `assign_swords` puts `items.swords` swords into early item
  slots. Once found, `play_swing` starts a swing that roots the knight for its
  length; it has no target yet because there are no enemies. The sword model is
  welded into the knight's mesh on the `play.sword_joint` joint by
  `assets.character_attach` (it shares the knight's texture), placed after the
  knight's own triangles so that it is simply not drawn until it is found.
- **A chest is two tiles** like a door: the body, and the lid on
  `props.chest_hinge`, which tips back by `Tile.tilt` when open.
- **Doors are two tiles**: the frame, and the leaf hung at `tiles.door_hinge`,
  which turns one extra quarter turn when open. Model names of the form
  `file:node` load a single node of a glTF in its local space; that is how the
  leaf is split from the frame.
- **Models and textures.** A model name is an id in the model manifest, and is
  drawn with the texture its own glTF names, so tiles from different packs can
  be mixed.
- **Layouts stay walkable.** Because props and chests are solid,
  `template_check_walkable` rejects a room where they stand right inside a
  door or opening, split the floor, or wall in an item slot.
- **The knight is skinned on the CPU.** `assets.pose_sample` reads the clip,
  `pose_matrices` builds joint matrices with the knight's world matrix folded
  in, `skin` writes plain world-space vertices and the renderer re-uploads
  them every frame. The rest pose reproducing the bind pose is the test that
  holds this together. The model and clips are loaded once at start-up.
- **Facing** uses the camera's yaw convention: 0 is north (`-Z`), positive
  turns east. The KayKit characters face `+Z` at rest; `facing_matrix` bridges
  the two.

## Skeletons and combat

Read `src/dungeon/enemies.odin`. It is part of the same pure simulation.

- **Spawning.** `play_start` raises one skeleton at every `Dungeon.enemy_spawns`
  entry when `enemies.enabled`. This is the population stage the spawn points
  were collected for.
- **Finding the knight.** Every update `path_update` floods `Play.path` with
  the walking distance to the knight, out to `enemies.sight`, through
  `cell_walkable` cells only. Shut doors are not walkable, so skeletons behind
  them stay idle until the knight opens the way. Skeletons walk downhill on
  that field and run straight at the knight once in its cell or the next.
- **States.** `Idle -> Chase -> Attack -> Chase`, with `Stagger` after a sword
  blow and `Dead` at zero health. An attack lands once, `attack_windup`
  seconds in, if the knight is still in reach.
- **The knight's health** is `Play.health`. `play_hurt` takes a pip and grants
  `play.invulnerable` seconds of grace; at zero the knight is `dead`, input
  stops and the skeletons go idle.
- **The sword** lands once per swing, `sword_hit_time` of the way through, on
  every skeleton within `sword_reach` and `sword_arc` of straight ahead.
- **Hit flash.** `play_flash` and `enemy_flash` give 1 at the moment of a blow
  fading to 0 over `play.hit_flash` seconds. The game passes them per
  character to the renderer, which puts them in the instance tint's alpha;
  the tile shader reads that alpha as "how far towards white", not opacity,
  so ordinary tiles carry 0 there.
- **Bodies** push each other apart, and walls always get the last word
  (`resolve_circle`), so nothing is ever shoved into geometry.
- **Free flight pauses the simulation.** The game only calls `play_update` in
  knight mode.
- Skeletons are the same rig as the knight, so `assets/character.odin` and the
  same animation files serve both. A mesh that is not skinned but parented to
  a joint (the warrior's helmet) is loaded as rigid on that joint.

## Manifests and packaging

`assets/` holds gigabytes; the game uses a sliver of it. Two manifests record
exactly which files, and both are enforced rather than trusted.

- **Model manifest** (`config/models.json5`, `src/assets/manifest.odin`). Maps
  ids to files in three sections: `models` (.gltf), `characters` (.glb) and
  `animations` (.glb). The config never holds a model path: tile names,
  `play.character` and every clip's `file` are ids from here. A name like
  `wall_doorway:wall_doorway_door` is a node of the model `wall_doorway`.
- **Kept honest both ways.** `assets.manifest_check` fails if the config uses
  an id that is not listed, or if something is listed that the config does not
  use. The game runs it at start-up and on config reload. To use a new model,
  add it to the manifest; when one stops being used, remove it. Files of a
  feature that is merely switched off (no skeletons, no swords) may stay.
- **Sound manifest**: see Sound below; it works the same way.
- **Packaging.** `bundle.collect` builds the release file list from the config
  and both manifests: listed files, the `.bin` and texture each `.gltf` names
  (`assets.gltf_dependencies`), fonts and their icon lists, UI kit pieces, and
  any licence file in the folders those come from. `src/pack` copies that into
  `build\package\<platform>\dungeon-solver` with that platform's binaries, then
  `bundle.verify` loads everything the game loads at start-up from the staged
  copy, so a file missing from the list fails the packaging, not the player.
- **One zip per platform.** `package.bat` makes
  `build\dungeon-solver-windows.zip` and `build\dungeon-solver-linux.zip`.
  The data is identical; `src/pack` takes the platform and adds its binaries
  (`PLATFORMS` in `src/pack/main.odin`): `dungeon.exe` and `SDL3.dll`, or the
  Linux `dungeon` from `build_linux.bat`. The Linux zip is written inside WSL
  (`build_linux.sh archive`) so the game keeps its executable bit; it does not
  carry SDL3, which the README tells the player to install.
- A new kind of file the game reads at run time must be added to
  `bundle.collect` and to `bundle.verify`.

## Sound

- **Hooks.** The simulation never plays anything. Each audible action raises a
  `dungeon.Sound_Event` (kind and position) through `sound_emit` in
  `src/dungeon/sounds.odin`; they queue in `Play` until `sounds_clear`. To make
  a new action audible: add a `Sound_Kind`, emit it where the action happens,
  add a hook for it to the manifest, and test that it fires once.
- **The manifest** is `config/sounds.json5`. Its `files` map is the record of
  which of the hundreds of files under `assets/sounds` the game actually uses;
  only those are loaded. `hooks` maps every `Sound_Kind` to the files it may
  play. `sound.bank_parse` refuses a manifest with a missing file, a file no
  hook plays, a hook for an unknown action or sound, or an action without a
  hook. An action that should stay silent is listed with an empty `sounds`.
  When a sound stops being used, remove it from `files`; the load fails until
  you do.
- **Choosing.** `sound.bank_trigger` picks one of the hook's files (never the
  same twice running), fades it with distance from the knight out to
  `sounds.hearing`, and drops repeats of the same action inside the hook's
  `interval`, which is what keeps a room of skeletons from clattering as one.
- **Mixer.** `sound.Mixer` holds the three volumes of the options screen.
  Effects are scaled by master times sound, music by master times music. A
  hook with `"bus": "music"` (a musical phrase, like the one for finishing
  the dungeon) follows the music volume instead.
- **Music.** The sound packs hold no songs, so the manifest's `music.tracks`
  are seamless ambient loops. `sound.music_next` walks the playlist, giving
  each track `music.repeats` plays before the next, and `audio_update` queues
  whatever it returns whenever the music stream runs low.
- **Menu sounds.** `menu.update` leaves the `Menu_*` kinds it should sound
  like in `Menu.sounds` for one frame, and the game plays them through the
  same hooks. A new menu interaction that should be heard adds to that set.
- **Playing** is `src/game/audio.odin`: SDL audio streams as a pool of voices.
  Sound is optional; without a device or with a bad manifest the game runs
  silent and says so on stderr.

## Input

Read `src/input/input.odin`. Nothing outside `src/game/devices.odin` may query
SDL for keys, buttons or sticks.

- **Actions, not keys.** Game code reads `State.value`, `down`, `pressed` and
  `released` per `Action`. Which controls drive an action is a `Binding`
  table; gamepad controls are simply more rows in it.
- **Two tables.** `State.bindings` are the gameplay controls, which the player
  can change and which live in the saved settings. `State.fixed`
  (`fixed_bindings`) are pause, menu navigation and analogue look and zoom;
  they are never rebound, so the menus always work. A new gameplay action
  goes in `default_bindings` and gets a row in `menu.SLOTS`.
- **Rebinding** is `src/input/rebind.odin`: a `Slot` is a button action or one
  direction of an axis action, `capture` finds the control just pressed, and
  `rebind` replaces that slot's bindings on that device only. Escape and
  Start are reserved for cancelling and are never captured.
- **Three kinds of action.** `Button`; `Axis`, a level in -1..1 while held;
  `Delta`, an amount this frame. For a Delta the mouse contributes what it
  moved, while anything held contributes `scale * dt`.
- **`Raw` is the seam.** `devices.odin` copies SDL state into a `Raw` each
  frame, latching taps from events so a quick press is never missed. Tests
  build a `Raw` by hand.
- **Last device.** `State.source` is whichever of keyboard/mouse or gamepad
  was touched last, and `State.pad_type` the model of that pad. Stick drift
  inside the deadzone does not count as a touch.
- **Prompts.** `control_glyph` names the icon for a control on a given pad
  (South is A, Cross or B). To add a key or pad button, add it to the enum, to
  `KEY_NAMES` or the `pad_*_name` procedures, and to the tables in
  `devices.odin`; the hud tests then check the icon exists in the font.

## Menus

Read `src/menu/menu.odin`. The menu is state plus layout, tested by feeding it
fake input frames; nothing in it touches SDL.

- **Main menu.** With `ui.main_menu` the game opens on `Main` (`open_main`):
  Start game, Options, Controls, Quit. It cannot be dismissed; `Started` is the
  way out. A menu remembers its `root`, so Options and Controls lead back to
  the main menu when opened from it and to the pause menu otherwise. The pause
  menu and both game-over screens have a "Main menu" row, which returns
  `Main_Menu`; the game then drops the dungeon in progress, generates a new
  one and reopens the main menu. Behind it the dungeon is a backdrop: no HUD,
  no simulation, the camera drifting round the knight.
- **Game over.** `open_game_over` shows `Won` or `Lost` with a few summary
  lines from the game; those return `New_Dungeon` or `Retry` and ignore Pause
  and Back.
- **Screens.** `Pause` leads to `Options` (master, sound and music volume) and
  `Controls` (one row per `SLOTS` entry, then reset and back). `update` returns
  events; the game acts on `Quit`, saves on `Bindings_Changed` and when the
  menu closes, and reads the volumes every frame.
- **While open** the game calls neither `play_update` nor its own input
  handling, and skips them for the frame the menu closes on, so the key that
  closed the menu does not also swing the sword.
- **One layout for eyes and pointer.** `layout` places the window and rows;
  drawing and hit-testing both use it. Keys, gamepad and mouse all work.
- **Built from the UI kit.** Windows, the highlighted row, slider tracks and
  title rules are pieces of the Kenney fantasy UI kit named in `ui.kit`,
  loaded into the atlas as `hud.Kit` and drawn with `ui.draw_nine_slice` and
  `ui.draw_divider`. The pieces are white and are tinted when drawn. New menu
  furniture should come from the kit too, not from flat rectangles.
- **Controls screen** edits the bindings of the device last touched; picking
  up the other device switches what it shows.
- **Settings** (`settings.odin`) are written by name to `ui.settings`. Loading
  never fails: anything unreadable falls back to its default.

## HUD and text

- **Fonts.** `hud.fonts_load` rasterises Crimson Pro (ASCII) and, from each
  Kenney input font, exactly the icons `input` can ask for, into one RGBA
  atlas. Icon characters are looked up by name in the font's
  `*_characters.txt` (`ui.glyph_map_parse`); a missing name fails the load.
  Fonts are loaded once at start-up.
- **Drawing.** `ui.Draw_List` is a flat list of coloured, textured triangles
  in pixels, origin top left. The atlas has a solid white block, so shapes and
  text share one texture and one draw call. The renderer uploads the list each
  frame and draws it last with the `ui` shaders.
- **Layout** is `hud.build`: pips top left, status lines under them (the text
  that used to be the window title), control prompts bottom left for
  `State.source`, and a centred banner. Only ASCII is rasterised, so status
  text must stay ASCII.
- **Pips.** `hud.Pips` remembers the health last shown; when it drops, the
  lost pips fall away for `PIP_FALL_TIME` seconds (`falling_pip`).
- **Characters on screen.** The renderer keeps one `Actor` per kind of
  character; all instances of a kind are skinned on the CPU and uploaded as
  one run of vertices each frame.

## Conventions

- The library allocates from the allocator it is handed and never frees
  piecemeal. Pass an arena (`core:mem/virtual`) and throw the arena away. Tests
  do the same, which keeps the test runner's leak tracking quiet.
- Fallible procedures return `(value, err: string, ok: bool)`.
- Rotations are quarter turns about `+Y`; one turn carries east (`+X`) to north
  (`-Z`). Matrices are column-major and the shader multiplies `view_proj * world`.
- Clip space follows SDL's GPU API: `+Y` up, depth 0 at the near plane to 1 at the far plane.
- New layout characters go in the `decor` table of the config, not in code.
- Build with `-vet -strict-style`; both scripts already do.
