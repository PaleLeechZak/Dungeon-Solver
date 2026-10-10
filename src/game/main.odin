// Dungeon viewer and game: generates a dungeon from the config, lets a knight
// walk it, fight its skeletons and collect its keys, or shows it with a free
// camera.
//
//   odin run src/game -- [config path]
package game

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

import "../assets"
import "../camera"
import "../dungeon"
import "../hud"
import "../input"
import "../menu"
import "../sound"
import "../ui"

DEFAULT_CONFIG :: "config/dungeon.json5"

// Radians per second the camera circles the knight behind the main menu.
MAIN_MENU_DRIFT :: 0.12

// Seconds between the knight's death and the defeat screen.
DEATH_PAUSE :: 1.8

Mode :: enum {
	Free,
	Knight,
}

// A skinned character with the scratch space to pose it.
Rig :: struct {
	character: assets.Character,
	pose:      []assets.Transform,
	matrices:  []matrix[4, 4]f32,
	actor:     int, // renderer handle
}

Knight :: struct {
	using rig: Rig,
	idle:      assets.Clip,
	move:      assets.Clip,
	swing:     assets.Clip,
	hurt:      assets.Clip,
	death:     assets.Clip,
	celebrate: assets.Clip,
	clip:      ^assets.Clip,
	time:      f32,
	vertices:  []assets.Vertex,
}

Skeletons :: struct {
	using rig: Rig,
	loaded:    bool,
	idle:      assets.Clip,
	move:      assets.Clip,
	attack:    assets.Clip,
	hurt:      assets.Clip,
	death:     assets.Clip,
	vertices:  [dynamic]assets.Vertex, // every skeleton of the dungeon, one after another
}

App :: struct {
	config_path:  string,
	config_arena: ^virtual.Arena,
	cfg:          dungeon.Config,
	models:       assets.Manifest, // which model files are in use; lives in the config arena
	level_arena:  virtual.Arena,
	level:        ^dungeon.Dungeon,
	summary:      string, // one line about the dungeon; lives in the level arena
	seed:         u64,
	renderer:     Renderer,
	mode:         Mode,
	cam:          camera.Camera,
	orbit:        camera.Orbit,
	looking:      bool,
	pad:          ^sdl.Gamepad,
	controls:     input.State,
	fonts:        hud.Fonts,
	pips:         hud.Pips,
	play:         dungeon.Play,
	knight:       Knight,
	skeletons:    Skeletons,
	clock:        f32, // seconds since start, for looping animations
	pause:        menu.Menu,
	settings:     menu.Settings, // volumes and bindings, saved between runs
	previous_raw: input.Raw,
	sounds:       sound.Bank,
	sounds_ready: bool,
	audio:        Audio,
	shown:        Shown,
}

// What the tiles and the status line currently reflect.
Shown :: struct {
	mode:    Mode,
	version: int,
	taken:   int,
	notice:  Notice,
}

// What the last change to the dungeon was, for the status line.
Notice :: enum {
	None,
	Found_Key,
	Found_Sword,
	Empty_Chest,
}

main :: proc() {
	app := new(App)
	defer free(app)
	app.config_path = len(os.args) > 1 ? os.args[1] : DEFAULT_CONFIG

	if !load_config(app) {
		os.exit(1)
	}
	if virtual.arena_init_growing(&app.level_arena) != nil {
		fmt.eprintln("out of memory")
		os.exit(1)
	}
	defer virtual.arena_destroy(&app.level_arena)

	defer renderer_destroy(&app.renderer)
	if !renderer_init(&app.renderer, &app.cfg, &app.models) || !load_fonts(app) || !load_knight(app) || !load_skeletons(app) {
		os.exit(1)
	}
	defer if app.pad != nil {
		sdl.CloseGamepad(app.pad)
	}
	load_sounds(app)
	defer audio_destroy(&app.audio)

	// A missing or damaged settings file just means the defaults.
	app.settings = menu.settings_load(app.cfg.ui.settings)
	app.controls.fixed = input.fixed_bindings()
	app.seed = app.cfg.seed != 0 ? app.cfg.seed : fresh_seed()
	app.mode = app.cfg.play.start ? .Knight : .Free
	apply_camera_config(app)
	if !regenerate(app) {
		os.exit(1)
	}
	reset_camera(app)
	if app.cfg.ui.main_menu {
		menu.open_main(&app.pause, app.cfg.window.title)
	}

	last := sdl.GetTicksNS()
	running := true
	for running {
		events: Device_Events
		event: sdl.Event
		for sdl.PollEvent(&event) {
			running &&= devices_event(&events, &app.pad, &event)
		}

		now := sdl.GetTicksNS()
		dt := min(f32(now - last) / 1e9, 0.1)
		last = now
		app.clock += dt

		raw := devices_read(&events, app.pad, app.looking)
		// The menu may have changed the bindings since last frame.
		app.controls.bindings = app.settings.bindings[:]
		input.update(&app.controls, &raw, dt)
		in_state := &app.controls

		// The pause menu comes first. While it is open, and on the frame it
		// closes, the game underneath gets no input and does not move on.
		was_open := menu.is_open(&app.pause)
		menu_events := menu.update(
			&app.pause,
			&app.settings,
			{
				state = in_state,
				raw = &raw,
				previous = &app.previous_raw,
				pointer = pointer_position(&app.renderer),
				pointer_moved = events.mouse_moved,
				pointer_down = raw.mouse_buttons[.Left],
				screen = renderer_screen_size(&app.renderer),
				dt = dt,
			},
		)
		app.previous_raw = raw
		if .Quit in menu_events {
			running = false
		}
		// The two ways on from a game-over screen.
		if .New_Dungeon in menu_events {
			app.seed = fresh_seed()
			regenerate(app)
		}
		if .Retry in menu_events {
			regenerate(app)
		}
		// Back to the main menu: the game in progress is dropped, and the
		// next one starts in a dungeon of its own.
		if .Main_Menu in menu_events {
			app.seed = app.cfg.seed != 0 ? app.cfg.seed : fresh_seed()
			regenerate(app)
			menu.open_main(&app.pause, app.cfg.window.title)
		}
		// Rebinding is saved at once; volumes when the menu is left, so that
		// dragging a slider does not write the file every frame.
		if menu_events & {.Bindings_Changed, .Resumed, .Quit, .New_Dungeon, .Retry, .Started, .Main_Menu} != {} {
			if !menu.settings_save(app.cfg.ui.settings, &app.settings) {
				fmt.eprintfln("cannot save settings to '%s'", app.cfg.ui.settings)
			}
		}
		mixer := sound.Mixer{app.settings.master, app.settings.sound, app.settings.music}
		if app.sounds_ready {
			sound.bank_tick(&app.sounds, dt)
			audio_update(&app.audio, &app.sounds, mixer)
			// The menu's own clicks and ticks, heard at full strength wherever
			// the knight happens to be standing.
			for kind in app.pause.sounds {
				event := dungeon.Sound_Event{kind, app.play.pos}
				if request, ok := sound.bank_trigger(&app.sounds, event, app.play.pos, &app.cfg.sounds, mixer); ok {
					audio_play(&app.audio, request)
				}
			}
		}

		if was_open || menu.is_open(&app.pause) {
			if app.looking {
				app.looking = false
				_ = sdl.SetWindowRelativeMouseMode(app.renderer.window, false)
			}
			app.play.moving = false
			hud.pips_update(&app.pips, app.play.health, 0)
			pose_dt := f32(0)
			if menu.in_main(&app.pause) {
				// Behind the main menu the dungeon is a backdrop: the camera
				// drifts round the waiting knight, who is allowed to breathe.
				pose_dt = dt
				app.orbit.yaw += dt * MAIN_MENU_DRIFT
				camera.shot_apply(&app.cam, follow_shot(&app.play, app.orbit))
			} else {
				// Paused: the world holds its pose, animations included.
				app.clock -= dt
			}
			actors := [2]Actor_Draw{animate_knight(app, pose_dt), animate_skeletons(app)}
			renderer_draw(&app.renderer, app.cam, actors[:], build_hud(app))
			free_all(context.temp_allocator)
			continue
		}

		// The pointer is captured for looking around while Look_Hold is down.
		if in_state.down[.Look_Hold] != app.looking {
			app.looking = in_state.down[.Look_Hold]
			_ = sdl.SetWindowRelativeMouseMode(app.renderer.window, app.looking)
		}
		if in_state.pressed[.Toggle_Mode] {
			app.mode = app.mode == .Knight ? .Free : .Knight
		}
		if in_state.pressed[.Regenerate] {
			app.seed = fresh_seed()
			regenerate(app)
		}
		if in_state.pressed[.Reload_Config] {
			reload_config(app)
		}
		if in_state.pressed[.Reset_Camera] {
			reset_camera(app)
		}

		look := [2]f32{in_state.value[.Look_X], in_state.value[.Look_Y]}
		switch app.mode {
		case .Knight:
			// Once the amulet is found the camera is not the player's to
			// steer: it pans to the amulet and holds there.
			if !app.play.has_amulet {
				camera.orbit_update(&app.orbit, look, in_state.value[.Zoom], app.cam.sensitivity)
			}
			if in_state.pressed[.Swing] {
				dungeon.play_swing(&app.play, app.knight.swing.duration)
			}
			walk := camera.ground_direction(app.orbit.yaw, in_state.value[.Move_Right], in_state.value[.Move_Forward])
			dungeon.play_update(&app.play, app.level, &app.cfg, walk, dt)
			camera.shot_apply(&app.cam, knight_shot(&app.play, &app.cfg, app.orbit))
			play_sounds(app, mixer)
			// The game ends with the amulet in hand, or a moment after the
			// knight has fallen, once the fall has been seen.
			if app.play.won || (app.play.dead && app.play.dead_time >= DEATH_PAUSE) {
				menu.open_game_over(&app.pause, app.play.won, game_summary(app))
			}
		case .Free:
			// Free flight is for looking, so the world holds still: nothing
			// moves and no skeleton takes a swing at an unattended knight.
			app.play.moving = false
			camera.update(
				&app.cam,
				{
					move = {in_state.value[.Move_Right], in_state.value[.Fly_Up], in_state.value[.Move_Forward]},
					look = look,
					fast = in_state.down[.Fast],
					wheel = in_state.value[.Zoom],
				},
				dt,
			)
		}
		sync_tiles(app)
		hud.pips_update(&app.pips, app.play.health, dt)

		actors := [2]Actor_Draw{animate_knight(app, dt), animate_skeletons(app)}
		renderer_draw(&app.renderer, app.cam, actors[:], build_hud(app))
		free_all(context.temp_allocator)
	}
}

fresh_seed :: proc() -> u64 {
	rng := dungeon.rng_make(u64(time.to_unix_nanoseconds(time.now())))
	// Kept short so a seed is easy to copy into the config.
	return dungeon.rng_next(&rng) % 1_000_000_000 + 1
}

// Reads the config into a fresh arena and only swaps it in when it is valid.
load_config :: proc(app: ^App) -> bool {
	arena := new(virtual.Arena)
	if virtual.arena_init_growing(arena) != nil {
		free(arena)
		fmt.eprintln("out of memory")
		return false
	}
	cfg, err, ok := dungeon.config_load(app.config_path, virtual.arena_allocator(arena))
	// The model manifest belongs to the config: it has to list exactly the
	// models the config uses, so the two are loaded and checked together.
	models: assets.Manifest
	if ok {
		models, err, ok = assets.manifest_load(cfg.assets.manifest, "", virtual.arena_allocator(arena))
	}
	if ok {
		err, ok = assets.manifest_check(&models, &cfg, virtual.arena_allocator(arena))
	}
	if !ok {
		fmt.eprintln(err)
		virtual.arena_destroy(arena)
		free(arena)
		return false
	}
	if app.config_arena != nil {
		virtual.arena_destroy(app.config_arena)
		free(app.config_arena)
	}
	app.config_arena = arena
	app.cfg = cfg
	app.models = models
	return true
}

// Fonts, like the characters, are loaded once; changing them in the config
// needs a restart.
load_fonts :: proc(app: ^App) -> bool {
	err: string
	ok: bool
	if app.fonts, err, ok = hud.fonts_load(&app.cfg.ui); !ok {
		fmt.eprintln(err)
		return false
	}
	return renderer_set_ui_atlas(&app.renderer, &app.fonts.atlas)
}

// Sound is optional: a manifest that will not load is reported and the game
// runs silent. The manifest, like the fonts, is read once at start-up.
load_sounds :: proc(app: ^App) {
	if !app.cfg.sounds.enabled {
		return
	}
	err: string
	if app.sounds, err, app.sounds_ready = sound.bank_load(app.cfg.sounds.manifest); !app.sounds_ready {
		fmt.eprintfln("no sound: %s", err)
		return
	}
	audio_init(&app.audio, &app.sounds, app.cfg.sounds.voices)
}

// Turns what the simulation says just happened into sound, as heard from
// where the knight stands.
play_sounds :: proc(app: ^App, mixer: sound.Mixer) {
	defer dungeon.sounds_clear(&app.play)
	if !app.sounds_ready {
		return
	}
	for event in dungeon.sounds_pending(&app.play) {
		if request, ok := sound.bank_trigger(&app.sounds, event, app.play.pos, &app.cfg.sounds, mixer); ok {
			audio_play(&app.audio, request)
		}
	}
}

@(private = "file")
load_clip :: proc(app: ^App, clip: ^assets.Clip, cfg: dungeon.Clip_Config, ch: ^assets.Character) -> bool {
	err: string
	ok: bool
	if clip^, err, ok = assets.clip_load(app.models.animations[cfg.file], cfg.clip, ch); !ok {
		fmt.eprintln(err)
	}
	return ok
}

// Welds a model from the mesh library onto one of a character's joints.
@(private = "file")
attach_model :: proc(app: ^App, ch: ^assets.Character, model, joint: string) -> bool {
	vertices, indices, found := assets.library_mesh(&app.renderer.library, model)
	if !found {
		fmt.eprintfln("model '%s' is not loaded", model)
		return false
	}
	if err, ok := assets.character_attach(ch, vertices, indices, joint); !ok {
		fmt.eprintln(err)
		return false
	}
	return true
}

@(private = "file")
finish_rig :: proc(app: ^App, rig: ^Rig) -> bool {
	rig.pose = make([]assets.Transform, len(rig.character.joints))
	rig.matrices = make([]matrix[4, 4]f32, len(rig.character.joints))
	ok: bool
	rig.actor, ok = renderer_add_actor(&app.renderer, &rig.character)
	assets.character_destroy_texture(&rig.character) // it lives on the GPU now
	return ok
}

load_knight :: proc(app: ^App) -> bool {
	k := &app.knight
	play := app.cfg.play
	err: string
	ok: bool
	if k.character, err, ok = assets.character_load(app.models.characters[play.character]); !ok {
		fmt.eprintln(err)
		return false
	}
	if !load_clip(app, &k.idle, play.idle, &k.character) ||
	   !load_clip(app, &k.move, play.move, &k.character) ||
	   !load_clip(app, &k.swing, play.swing, &k.character) ||
	   !load_clip(app, &k.hurt, play.hurt, &k.character) ||
	   !load_clip(app, &k.death, play.death, &k.character) ||
	   !load_clip(app, &k.celebrate, play.celebrate, &k.character) {
		return false
	}
	// The sword becomes part of the knight's mesh, riding on the hand joint.
	if app.cfg.items.swords > 0 && !attach_model(app, &k.character, app.cfg.items.sword.model, play.sword_joint) {
		return false
	}
	k.clip = &k.idle
	k.vertices = make([]assets.Vertex, len(k.character.vertices))
	return finish_rig(app, k)
}

load_skeletons :: proc(app: ^App) -> bool {
	ec := app.cfg.enemies
	if !ec.enabled {
		return true
	}
	s := &app.skeletons
	err: string
	ok: bool
	if s.character, err, ok = assets.character_load(app.models.characters[ec.character]); !ok {
		fmt.eprintln(err)
		return false
	}
	if !load_clip(app, &s.idle, ec.idle, &s.character) ||
	   !load_clip(app, &s.move, ec.move, &s.character) ||
	   !load_clip(app, &s.attack, ec.attack, &s.character) ||
	   !load_clip(app, &s.hurt, ec.hurt, &s.character) ||
	   !load_clip(app, &s.death, ec.death, &s.character) {
		return false
	}
	if ec.weapon != "" && !attach_model(app, &s.character, ec.weapon, ec.weapon_joint) {
		return false
	}
	s.vertices = make([dynamic]assets.Vertex)
	s.loaded = true
	return finish_rig(app, s)
}

@(private = "file")
pose_rig :: proc(rig: ^Rig, clip: ^assets.Clip, at: f32, loop: bool, root: matrix[4, 4]f32, out: []assets.Vertex) {
	assets.pose_sample(&rig.character, clip, at, rig.pose, loop)
	assets.pose_matrices(&rig.character, rig.pose, root, rig.matrices)
	assets.skin(&rig.character, rig.matrices, out)
}

// Poses the knight for this frame, in world space.
animate_knight :: proc(app: ^App, dt: f32) -> Actor_Draw {
	k := &app.knight
	p := &app.play

	clip, at, loop := &k.idle, f32(0), true
	switch {
	case p.dead:
		// Falls once and stays down.
		clip, at, loop = &k.death, p.dead_time, false
	case p.has_amulet:
		// Cheers for as long as the simulation celebrates, and is left
		// mid-cheer behind the victory screen.
		clip, at, loop = &k.celebrate, p.celebrated, true
	case p.swing_left > 0:
		// The simulation owns the swing's clock, so the two cannot drift.
		clip, at, loop = &k.swing, p.swing_total - p.swing_left, false
	case p.hurt_time < k.hurt.duration * 0.6:
		clip, at, loop = &k.hurt, p.hurt_time, false
	case:
		clip = p.moving ? &k.move : &k.idle
		if clip != k.clip {
			k.time = 0
		}
		k.time += dt
		at = k.time
	}
	k.clip = clip
	pose_rig(k, clip, at, loop, dungeon.actor_matrix(p), k.vertices)

	// The sword is welded on after the knight's own triangles; until it is
	// found only those are drawn.
	flash := make([]f32, 1, context.temp_allocator)
	flash[0] = dungeon.play_flash(p, &app.cfg)
	return {
		actor = k.actor,
		vertices = k.vertices,
		instances = 1,
		indices = p.has_sword ? -1 : k.character.body_indices,
		flash = flash,
	}
}

// Poses every skeleton of the dungeon, the fallen included.
animate_skeletons :: proc(app: ^App) -> Actor_Draw {
	s := &app.skeletons
	enemies := app.play.enemies
	if !s.loaded || len(enemies) == 0 {
		return {actor = -1}
	}
	per := len(s.character.vertices)
	resize(&s.vertices, per * len(enemies))
	flash := make([]f32, len(enemies), context.temp_allocator)
	for e, i in enemies {
		flash[i] = dungeon.enemy_flash(e, &app.cfg)
		clip, at, loop := &s.idle, f32(0), true
		switch e.state {
		case .Idle:
			// Out of step with each other, so a room of them does not sway as one.
			clip, at = &s.idle, app.clock + f32(i) * 0.37
		case .Chase:
			// Free flight freezes the chase; running on the spot would look odd.
			clip, at = app.mode == .Free ? &s.idle : &s.move, app.clock + f32(i) * 0.37
		case .Attack:
			clip, at, loop = &s.attack, e.state_time, false
		case .Stagger:
			clip, at, loop = &s.hurt, e.state_time, false
		case .Dead:
			clip, at, loop = &s.death, e.state_time, false
		}
		pose_rig(s, clip, at, loop, dungeon.facing_matrix(e.pos, e.facing), s.vertices[i * per:][:per])
	}
	return {actor = s.actor, vertices = s.vertices[:], instances = len(enemies), indices = -1, flash = flash}
}

reload_config :: proc(app: ^App) {
	if !load_config(app) {
		fmt.eprintln("keeping the previous config")
		return
	}
	if !renderer_sync_models(&app.renderer, &app.cfg, &app.models) {
		return
	}
	if app.cfg.seed != 0 {
		app.seed = app.cfg.seed
	}
	apply_camera_config(app)
	regenerate(app)
}

apply_camera_config :: proc(app: ^App) {
	configured := camera.make_camera(
		app.cfg.camera.speed,
		app.cfg.camera.fast_multiplier,
		app.cfg.camera.sensitivity,
		app.cfg.camera.fov,
	)
	configured.pos = app.cam.pos
	configured.yaw = app.cam.yaw
	configured.pitch = app.cam.pitch
	app.cam = configured

	yaw := app.orbit.yaw
	app.orbit = camera.make_orbit(app.cfg.play.camera_distance, app.cfg.play.camera_pitch)
	app.orbit.yaw = yaw
}

// Free camera: hovers south of the entrance, looking down at the player spawn.
reset_camera :: proc(app: ^App) {
	if app.level == nil {
		return
	}
	target := dungeon.cell_world(&app.cfg, app.level.player_spawn)
	reach := app.cfg.tile_size * 9
	app.cam.pos = target + {0, reach, reach * 0.8}
	camera.look_at(&app.cam, target)
}

regenerate :: proc(app: ^App) -> bool {
	virtual.arena_free_all(&app.level_arena)
	app.level = nil
	allocator := virtual.arena_allocator(&app.level_arena)

	d, err, ok := dungeon.generate(&app.cfg, app.seed, allocator)
	if !ok {
		fmt.eprintln(err)
		return false
	}
	app.level = d
	app.play = dungeon.play_start(d, &app.cfg, allocator)
	hud.pips_reset(&app.pips)

	s := dungeon.stats(d)
	result := dungeon.solve(d, allocator)
	app.summary = fmt.aprintf(
		"Seed %d | %d rooms, %d hallways, %d encounters | %d locked doors%s",
		d.seed,
		s.rooms,
		s.by_kind[.Hallway],
		s.by_kind[.Encounter],
		s.locks,
		result.solvable ? "" : " | NOT SOLVABLE",
		allocator = allocator,
	)
	fmt.println(app.summary)
	app.shown = {version = -1} // force the tiles to refresh
	return sync_tiles(app)
}

// A few lines on how a finished game went, for the game-over screen. They
// live in the level arena, which lasts until the next dungeon is generated.
game_summary :: proc(app: ^App) -> []string {
	allocator := virtual.arena_allocator(&app.level_arena)
	p, d := &app.play, app.level
	lines := make([dynamic]string, allocator)
	if p.won {
		append(&lines, "The amulet is yours.")
	} else {
		append(&lines, "The knight has fallen and the amulet stays in the dark.")
	}
	seconds := int(p.time)
	append(&lines, fmt.aprintf("Time %d:%02d  |  Rooms %d/%d  |  Keys %d/%d", seconds / 60, seconds % 60, p.rooms_seen, len(d.rooms), p.keys_held, d.lock_count, allocator = allocator))
	if len(p.enemies) > 0 {
		append(&lines, fmt.aprintf("Skeletons slain %d/%d  |  Health left %d/%d", p.kills, len(p.enemies), p.health, p.max_health, allocator = allocator))
	}
	append(&lines, fmt.aprintf("Seed %d", d.seed, allocator = allocator))
	return lines[:]
}

// Rebuilds the tiles when a door or chest opened, an item was taken or the
// mode changed, and works out what the status line should say about it.
sync_tiles :: proc(app: ^App) -> bool {
	if app.level == nil {
		return false
	}
	now := Shown {
		mode    = app.mode,
		version = app.play.version,
		taken   = app.play.slots_taken,
		notice  = app.shown.notice,
	}
	// While the knight celebrates, the amulet rises over its head, so the
	// tiles change every frame.
	if now == app.shown && !dungeon.play_celebrating(&app.play) {
		return true
	}
	if now.version != app.shown.version {
		// Say what a chest or pickup gave, or clear the previous message once
		// the knight has moved on to opening doors.
		now.notice = .None
		if now.taken > app.shown.taken && now.taken > 0 {
			switch app.play.last_found {
			case .Key:
				now.notice = .Found_Key
			case .Sword:
				now.notice = .Found_Sword
			case .Amulet:
			// Winning speaks for itself, on the game-over screen.
			case .None:
				now.notice = .Empty_Chest
			}
		}
	}
	app.shown = now
	// Switching modes changes what is hidden, so the tiles change with it.
	tiles := dungeon.build_tiles(app.level, &app.cfg, context.temp_allocator, &app.play, reveal = app.mode == .Free)
	return renderer_set_tiles(&app.renderer, tiles)
}

KNIGHT_HINTS := [?]hud.Hint {
	{"Walk", {.Move_Forward, .Move_Right}},
	{"Look around", {.Look_Hold, .Look_X, .Look_Y}},
	{"Swing sword", {.Swing}},
	{"Zoom", {.Zoom}},
	{"Free flight", {.Toggle_Mode}},
	{"New dungeon", {.Regenerate}},
	{"Reload config", {.Reload_Config}},
	{"Menu", {.Pause}},
}

FREE_HINTS := [?]hud.Hint {
	{"Fly", {.Move_Forward, .Move_Right}},
	{"Up and down", {.Fly_Up}},
	{"Look around", {.Look_Hold, .Look_X, .Look_Y}},
	{"Fly faster", {.Fast}},
	{"Fly speed", {.Zoom}},
	{"Back to entrance", {.Reset_Camera}},
	{"Knight", {.Toggle_Mode}},
	{"New dungeon", {.Regenerate}},
	{"Reload config", {.Reload_Config}},
	{"Menu", {.Pause}},
}

// Lays out this frame's HUD: health, what the window title used to say, and
// the controls for the device in hand.
build_hud :: proc(app: ^App) -> []ui.Vertex {
	list: ui.Draw_List
	ui.draw_list_init(&list, &app.fonts.atlas, context.temp_allocator)
	p, d := &app.play, app.level

	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, app.summary)
	view := hud.View {
		screen     = renderer_screen_size(&app.renderer),
		health     = p.health,
		max_health = p.max_health,
	}
	switch app.mode {
	case .Knight:
		view.show_pips = true
		progress := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&progress, "Keys %d/%d | %s | Rooms %d/%d", p.keys_held, d.lock_count, p.has_sword ? "Sword in hand" : "Unarmed", p.rooms_seen, len(d.rooms))
		if dungeon.stats(d).amulets > 0 {
			fmt.sbprintf(&progress, " | Find the amulet")
		}
		if len(p.enemies) > 0 {
			fmt.sbprintf(&progress, " | Skeletons slain %d/%d", p.kills, len(p.enemies))
		}
		append(&lines, strings.to_string(progress))
		switch {
		case p.dead || p.won:
		// The game-over screen has the last word.
		case p.blocked_by >= 0:
			append(&lines, fmt.tprintf("This door needs key %c", 'A' + rune(p.blocked_by % 26)))
		case app.shown.notice == .Found_Key:
			append(&lines, fmt.tprintf("Found key %c", 'A' + rune(p.last_found_key % 26)))
		case app.shown.notice == .Found_Sword:
			append(&lines, "Found a sword")
		case app.shown.notice == .Empty_Chest:
			append(&lines, "The chest is empty")
		case p.explored:
			append(&lines, "Every room explored")
		}
		// No point advertising a sword the knight does not have.
		view.hints = KNIGHT_HINTS[:]
		if !p.has_sword {
			hints := make([dynamic]hud.Hint, context.temp_allocator)
			for hint in KNIGHT_HINTS {
				if hint.label != "Swing sword" {
					append(&hints, hint)
				}
			}
			view.hints = hints[:]
		}
	case .Free:
		append(&lines, "Free flight: the dungeon stands still, chest contents and spawn points are shown")
		view.hints = FREE_HINTS[:]
	}
	view.lines = lines[:]
	// No game is in progress behind the main menu, so there is no HUD for it.
	if !menu.in_main(&app.pause) {
		hud.build(&list, &app.fonts, &app.pips, &app.controls, view)
	}
	// The pause menu, when open, goes over the top of everything.
	menu.draw(&list, &app.fonts, &app.pause, &app.settings, &app.controls, view.screen)
	return list.vertices[:]
}
