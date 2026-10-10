package dungeon

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"

Config :: struct {
	seed:       u64, // 0 picks a fresh seed on every run
	size:       Size_Config,
	tile_size:  f32,
	generation: Generation_Config,
	hallways:   Hallway_Config,
	locks:      Lock_Config,
	assets:     Asset_Config,
	tiles:      Tile_Config,
	floors:     map[string][]string, // floor set name -> models, one picked per cell
	decor:      map[string][]string, // layout character -> models, one picked per cell
	props:      Prop_Config,
	items:      Item_Config,
	markers:    Marker_Config,
	rooms:      []Room_Config,
	play:       Play_Config,
	enemies:    Enemy_Config,
	sounds:     Sound_Config,
	ui:         Ui_Config,
	camera:     Camera_Config,
	window:     Window_Config,
}

Size_Config :: struct {
	width:  int, // grid cells
	height: int,
}

Generation_Config :: struct {
	max_rooms:            int,
	min_rooms:            int, // regenerate (up to max_attempts) when fewer rooms fit
	max_attempts:         int,
	attempts_per_node:    int, // template draws tried for every open node
	allow_rotation:       bool,
	allow_adjacent_walls: bool, // false rejects rooms that would leave two walls back to back
	depth_bias:           f32, // 0 grows the dungeon evenly, 1 always extends the newest room
	entrance_position:    [2]f32, // fraction of the grid, {0.5, 0.5} is the centre
}

Hallway_Config :: struct {
	count:            int, // hallway templates generated per dungeon
	min_length:       int, // floor tiles along the hallway
	max_length:       int,
	side_door_chance: f32, // per wall cell along the length
	weight:           f32, // shared between all generated hallways
	chain_weight:     f32, // weight multiplier for a hallway attached to another hallway
	prune_dead_ends:  bool, // remove hallways nothing else was attached to
	floor:            string,
}

Lock_Config :: struct {
	chance: f32,
	max:    int,
}

Asset_Config :: struct {
	manifest: string, // the model manifest: every model, character and animation file in use
	texture:  string, // used by models that do not name a texture themselves
}

Tile_Config :: struct {
	wall:     []string, // straight sections, one picked per cell
	corner:   string,
	tsplit:   string,
	crossing: string,
	doorway:    string, // the frame; stays put
	door:       string, // the leaf; swings open a quarter turn about its own origin
	door_hinge: [3]f32, // where the leaf's origin sits inside the doorway
}

// Knight mode: walk the dungeon on foot, pick up keys, open doors.
Play_Config :: struct {
	start:           bool, // begin in knight mode instead of the free camera
	speed:           f32, // world units per second
	radius:          f32, // collision radius, world units
	interact_radius: f32, // reach for picking up keys and opening doors
	turn_speed:      f32, // radians per second the knight turns towards its heading
	camera_distance: f32,
	camera_pitch:    f32, // degrees, negative looks down
	character:       string, // id of a character in the model manifest
	idle:            Clip_Config,
	move:            Clip_Config,
	swing:           Clip_Config,
	hurt:            Clip_Config,
	death:           Clip_Config,
	celebrate:       Clip_Config, // played on finding the amulet
	celebrate_time:  f32, // seconds of celebrating before the game is won; 0 wins at once
	celebrate_pan:   f32, // seconds the camera takes to pan from the knight to the amulet
	celebrate_distance: f32, // how close the camera comes to the amulet
	celebrate_pitch: f32, // degrees, negative looks down; shallower than the usual view
	sword_joint:     string, // joint the sword is held by
	health:          int, // pips
	sword_reach:     f32, // world units from the knight's centre
	sword_arc:       f32, // degrees either side of straight ahead
	sword_damage:    int,
	sword_hit_time:  f32, // fraction of the swing at which the blade connects
	invulnerable:    f32, // seconds of grace after being hurt
	hit_flash:       f32, // seconds the knight or a skeleton flashes white when hit
}

// Skeletons: one rises at every enemy spawn point and hunts the knight.
Enemy_Config :: struct {
	enabled:         bool,
	character:       string, // id of a character on the same rig as the knight
	weapon:          string, // model welded to weapon_joint, "" for bare hands
	weapon_joint:    string,
	health:          int,
	speed:           f32,
	radius:          f32,
	sight:           f32, // world units of walking distance at which the knight is noticed
	attack_range:    f32, // centre to centre distance a blow reaches
	attack_windup:   f32, // seconds from starting a blow to it landing
	attack_recovery: f32, // seconds after a blow before the next move
	damage:          int,
	stagger:         f32, // seconds a skeleton reels after being hit
	idle:            Clip_Config,
	move:            Clip_Config,
	attack:          Clip_Config,
	hurt:            Clip_Config,
	death:           Clip_Config,
}

// Sound effects. Which files exist and which in-game action plays which of
// them is in the manifest file; see src/sound.
Sound_Config :: struct {
	enabled:         bool,
	manifest:        string, // path of the sound manifest
	hearing:         f32, // world units from the knight at which a sound has faded to nothing
	voices:          int, // sounds that can play at once
	knight_stride:   f32, // world units between the knight's footfalls
	skeleton_stride: f32,
}

// Heads-up display: text in `font`, control prompts from the Kenney input
// fonts, each with the *_characters.txt that names its icons.
Ui_Config :: struct {
	font:        string,
	font_size:   f32, // pixels
	icon_size:   f32,
	atlas_size:  int, // side of the square glyph texture, pixels
	prompts:     Prompt_Fonts,
	kit:         Kit_Config,
	settings:    string, // file the player's volumes and bindings are saved to
	main_menu:   bool, // open on the main menu rather than straight into the dungeon
}

// Pieces of the Kenney fantasy UI kit the menus are built from. Each is a
// white image that is tinted when drawn; panels and borders are stretched as
// nine-slices with `margin` pixels of frame.
Kit_Config :: struct {
	dir:           string,
	window:        string, // filled panel behind a menu
	window_border: string, // its frame, drawn on top in a lighter tint
	button:        string, // fill of the highlighted row
	button_border: string, // frame of the highlighted row
	track:         string, // slider track and fill
	divider:       string, // rule under a menu's title
	margin:        f32,
	divider_cap:   f32, // pixels of ornament at the divider's end that must not stretch
}

Prompt_Fonts :: struct {
	keyboard_mouse: Prompt_Font,
	xbox:           Prompt_Font,
	playstation:    Prompt_Font,
	switch_pad:     Prompt_Font `json:"switch"`,
}

Prompt_Font :: struct {
	font:       string,
	characters: string,
}

Clip_Config :: struct {
	file: string, // id of an animation file in the model manifest
	clip: string, // name of the clip inside it
}

Marker :: struct {
	model: string,
	y:     f32,
	scale: f32,
	tint:  [3]f32,
}

// Markers are only drawn in free flight: they show where later generation
// stages will put things.
Marker_Config :: struct {
	player_spawn: Marker,
	enemy_spawn:  Marker,
	ground_slot:  Marker, // an item slot on the floor with nothing on it
}

// A chest is a body plus a lid that tips back on its hinge when opened.
Prop_Config :: struct {
	chest:            string,
	chest_lid:        string,
	chest_hinge:      [3]f32, // where the lid's origin sits on the body
	chest_open_angle: f32, // degrees the lid tips back
}

// How an item looks lying on the floor, and floating above a closed chest
// when free flight reveals what is inside.
Item_Visual :: struct {
	model:       string,
	scale:       f32,
	tint:        [3]f32, // keys take the colour of their door instead
	ground_y:    f32,
	ground_tilt: f32, // degrees about the model's X axis, to lay it flat
	reveal_y:    f32,
}

Item_Config :: struct {
	key:    Item_Visual,
	sword:  Item_Visual,
	swords: int, // swords placed per dungeon
	amulet: Item_Visual, // the goal of the dungeon; no model means no amulet
}
Room_Config :: struct {
	name:      string,
	kind:      string, // "normal", "entrance" or "encounter"
	weight:    f32, // defaults to 1
	max_count: int, // 0 is unlimited
	floor:     string, // defaults to "stone"
	layout:    []string,
}

Camera_Config :: struct {
	speed:           f32, // world units per second
	fast_multiplier: f32,
	sensitivity:     f32, // radians per pixel of mouse travel
	fov:             f32, // vertical, degrees
}

Window_Config :: struct {
	width:  int,
	height: int,
	title:  string,
}

DEFAULT_FLOOR :: "stone"

@(private = "file")
PROMPT_DIR :: "assets/kenney_input-prompts_1.5/"

config_default :: proc() -> Config {
	return Config {
		size = {width = 48, height = 48},
		tile_size = 4,
		generation = {
			max_rooms = 30,
			min_rooms = 8,
			max_attempts = 8,
			attempts_per_node = 12,
			allow_rotation = true,
			depth_bias = 0.35,
			entrance_position = {0.5, 0.5},
		},
		hallways = {count = 6, min_length = 2, max_length = 6, side_door_chance = 0.2, weight = 4, chain_weight = 0.4, prune_dead_ends = true, floor = DEFAULT_FLOOR},
		locks = {chance = 0.3, max = 4},
		assets = {manifest = "config/models.json5", texture = "assets/KayKit_Dungeon_Pack_1.1_SOURCE/Assets/textures/dungeon_texture.png"},
		markers = {
			player_spawn = {scale = 1, tint = {1, 1, 1}},
			enemy_spawn = {scale = 1, tint = {1, 1, 1}},
			ground_slot = {scale = 1, tint = {1, 1, 1}},
		},
		props = {chest_open_angle = 100},
		items = {
			key = {scale = 1, tint = {1, 1, 1}, ground_tilt = 90, reveal_y = 2.4},
			sword = {scale = 1, tint = {1, 1, 1}, ground_tilt = 90, reveal_y = 2.4},
			swords = 1,
			amulet = {scale = 1, tint = {1, 1, 1}, reveal_y = 2.2},
		},
		play = {
			speed = 9,
			radius = 0.5,
			interact_radius = 2.2,
			turn_speed = 12,
			camera_distance = 16,
			camera_pitch = -50,
			character = "knight",
			idle = {file = "general", clip = "Idle_A"},
			move = {
				file = "movement",
				clip = "Running_A",
			},
			swing = {
				file = "melee",
				clip = "Melee_1H_Attack_Slice_Diagonal",
			},
			hurt = {file = "general", clip = "Hit_A"},
			death = {file = "general", clip = "Death_A"},
			celebrate = {file = "simulation", clip = "Cheering"},
			celebrate_time = 3.3,
			celebrate_pan = 1.0,
			celebrate_distance = 7,
			celebrate_pitch = -14,
			sword_joint = "handslot.r",
			health = 5,
			sword_reach = 3.2,
			sword_arc = 75,
			sword_damage = 1,
			sword_hit_time = 0.4,
			invulnerable = 0.9,
			hit_flash = 0.18,
		},
		enemies = {
			enabled = true,
			character = "skeleton_warrior",
			weapon = "Skeleton_Blade",
			weapon_joint = "handslot.r",
			health = 2,
			speed = 5.5,
			radius = 0.5,
			sight = 28,
			attack_range = 2.2,
			attack_windup = 0.45,
			attack_recovery = 0.9,
			damage = 1,
			stagger = 0.5,
			idle = {file = "general", clip = "Idle_A"},
			move = {file = "movement", clip = "Running_A"},
			attack = {file = "melee", clip = "Melee_1H_Attack_Chop"},
			hurt = {file = "general", clip = "Hit_A"},
			death = {file = "general", clip = "Death_A"},
		},
		sounds = {
			enabled = true,
			manifest = "config/sounds.json5",
			hearing = 45,
			voices = 16,
			knight_stride = 2.6,
			skeleton_stride = 2.4,
		},
		ui = {
			font = "assets/fonts/Crimson_Pro/static/CrimsonPro-Medium.ttf",
			font_size = 26,
			icon_size = 40,
			atlas_size = 1024,
			settings = "settings.json",
			main_menu = true,
			kit = {
				dir = "assets/kenney_fantasy-ui-borders/PNG/Double",
				window = "Panel/panel-010.png",
				window_border = "Border/panel-border-010.png",
				button = "Panel/panel-009.png",
				button_border = "Border/panel-border-009.png",
				track = "Panel/panel-015.png",
				divider = "Divider/divider-003.png",
				margin = 32,
				divider_cap = 56,
			},
			prompts = {
				keyboard_mouse = {
					font = PROMPT_DIR + "Keyboard & Mouse/Fonts/kenney_input_keyboard_&_mouse.ttf",
					characters = PROMPT_DIR + "Keyboard & Mouse/Fonts/kenney_input_keyboard_&_mouse_characters.txt",
				},
				xbox = {
					font = PROMPT_DIR + "Xbox Series/Fonts/kenney_input_xbox_series.ttf",
					characters = PROMPT_DIR + "Xbox Series/Fonts/kenney_input_xbox_series_characters.txt",
				},
				playstation = {
					font = PROMPT_DIR + "PlayStation Series/Fonts/kenney_input_playstation_series.ttf",
					characters = PROMPT_DIR + "PlayStation Series/Fonts/kenney_input_playstation_series_characters.txt",
				},
				switch_pad = {
					font = PROMPT_DIR + "Nintendo Switch/Fonts/kenney_input_nintendo_switch.ttf",
					characters = PROMPT_DIR + "Nintendo Switch/Fonts/kenney_input_nintendo_switch_characters.txt",
				},
			},
		},
		camera = {speed = 16, fast_multiplier = 4, sensitivity = 0.003, fov = 60},
		window = {width = 1600, height = 900, title = "Dungeon Solver"},
	}
}

// Parses JSON5 on top of config_default, so a config only has to list what it changes.
config_parse :: proc(data: []byte, allocator := context.allocator) -> (cfg: Config, err: string, ok: bool) {
	cfg = config_default()
	if uerr := json.unmarshal(data, &cfg, json.Specification.JSON5, allocator); uerr != nil {
		return cfg, fmt.aprintf("config parse error: %v", uerr, allocator = allocator), false
	}
	if verr, valid := config_validate(&cfg, allocator); !valid {
		return cfg, verr, false
	}
	return cfg, "", true
}

config_load :: proc(path: string, allocator := context.allocator) -> (cfg: Config, err: string, ok: bool) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return cfg, fmt.aprintf("cannot read config '%s': %v", path, read_err, allocator = allocator), false
	}
	return config_parse(data, allocator)
}

config_validate :: proc(cfg: ^Config, allocator := context.allocator) -> (err: string, ok: bool) {
	fail :: proc(allocator: runtime.Allocator, format: string, args: ..any) -> (string, bool) {
		return fmt.aprintf(format, ..args, allocator = allocator), false
	}

	if cfg.size.width < 8 || cfg.size.height < 8 {
		return fail(allocator, "size must be at least 8x8 cells, got %dx%d", cfg.size.width, cfg.size.height)
	}
	if cfg.tile_size <= 0 {
		return fail(allocator, "tile_size must be positive")
	}
	if cfg.generation.max_rooms < 1 {
		return fail(allocator, "generation.max_rooms must be at least 1")
	}
	if cfg.generation.attempts_per_node < 1 {
		return fail(allocator, "generation.attempts_per_node must be at least 1")
	}
	if cfg.hallways.count < 0 {
		return fail(allocator, "hallways.count cannot be negative")
	}
	if cfg.hallways.count > 0 {
		if cfg.hallways.min_length < 1 || cfg.hallways.max_length < cfg.hallways.min_length {
			return fail(
				allocator,
				"hallways need 1 <= min_length <= max_length, got %d..%d",
				cfg.hallways.min_length,
				cfg.hallways.max_length,
			)
		}
		if cfg.hallways.floor not_in cfg.floors {
			return fail(allocator, "hallways.floor '%s' is not defined in floors", cfg.hallways.floor)
		}
	}
	if len(cfg.tiles.wall) == 0 {
		return fail(allocator, "tiles.wall needs at least one model")
	}
	if cfg.tiles.corner == "" || cfg.tiles.tsplit == "" || cfg.tiles.crossing == "" || cfg.tiles.doorway == "" || cfg.tiles.door == "" {
		return fail(allocator, "tiles.corner, tiles.tsplit, tiles.crossing, tiles.doorway and tiles.door are all required")
	}
	if cfg.assets.manifest == "" {
		return fail(allocator, "assets.manifest, the path of the model manifest, is required")
	}
	if cfg.props.chest == "" || cfg.props.chest_lid == "" {
		return fail(allocator, "props.chest and props.chest_lid are required")
	}
	if cfg.items.key.model == "" {
		return fail(allocator, "items.key.model is required")
	}
	if cfg.items.swords > 0 && cfg.items.sword.model == "" {
		return fail(allocator, "items.sword.model is required when items.swords is above 0")
	}
	if cfg.play.speed <= 0 || cfg.play.radius <= 0 {
		return fail(allocator, "play.speed and play.radius must be positive")
	}
	if cfg.play.celebrate_time > 0 && cfg.play.celebrate_pan > cfg.play.celebrate_time {
		return fail(
			allocator,
			"play.celebrate_pan %v is longer than play.celebrate_time %v: the camera would not reach the amulet before the game ends",
			cfg.play.celebrate_pan,
			cfg.play.celebrate_time,
		)
	}
	if cfg.play.health < 1 {
		return fail(allocator, "play.health must be at least 1")
	}
	if cfg.enemies.enabled {
		e := cfg.enemies
		if e.health < 1 || e.speed <= 0 || e.radius <= 0 || e.radius >= cfg.tile_size * DOOR_HALF_OPENING {
			return fail(allocator, "enemies need health >= 1, a positive speed and a radius that fits a doorway")
		}
		if e.attack_range <= e.radius + cfg.play.radius {
			return fail(allocator, "enemies.attack_range %v cannot reach past the two bodies", e.attack_range)
		}
	}
	if cfg.sounds.enabled && (cfg.sounds.manifest == "" || cfg.sounds.hearing <= 0 || cfg.sounds.voices < 1) {
		return fail(allocator, "sounds need a manifest path, a positive hearing distance and at least one voice")
	}
	if cfg.ui.font_size <= 0 || cfg.ui.icon_size <= 0 || cfg.ui.atlas_size < 256 {
		return fail(allocator, "ui needs positive font_size and icon_size and an atlas_size of at least 256")
	}
	// The knight has to fit through a doorway, which is a quarter of a tile either side.
	if cfg.play.radius >= cfg.tile_size * DOOR_HALF_OPENING {
		return fail(allocator, "play.radius %v is too wide for a doorway", cfg.play.radius)
	}
	if cfg.play.interact_radius <= cfg.play.radius + cfg.tile_size * PROP_HALF_SIZE {
		return fail(allocator, "play.interact_radius %v cannot reach a key past its chest", cfg.play.interact_radius)
	}
	for name, models in cfg.floors {
		if len(models) == 0 {
			return fail(allocator, "floor set '%s' has no models", name)
		}
	}
	for key, models in cfg.decor {
		if len(key) != 1 {
			return fail(allocator, "decor key '%s' must be a single character", key)
		}
		switch key[0] {
		case '#', 'D', '~', '.', 'P', 'E', 'I', 'i':
			return fail(allocator, "decor key '%s' is a reserved layout character", key)
		}
		if len(models) == 0 {
			return fail(allocator, "decor '%s' has no models", key)
		}
	}
	if len(cfg.rooms) == 0 {
		return fail(allocator, "at least one room is required")
	}

	// Parsing every template is the real layout validation.
	rng := rng_make(1)
	templates, terr, tok := build_templates(cfg, &rng, context.temp_allocator)
	if !tok {
		return fmt.aprintf("%s", terr, allocator = allocator), false
	}
	has_entrance := false
	for t in templates {
		has_entrance ||= t.kind == .Entrance
	}
	if !has_entrance {
		return fail(allocator, "no room has kind \"entrance\"")
	}
	return "", true
}

// Every model the config can ask the renderer to draw.
config_model_names :: proc(cfg: ^Config, allocator := context.allocator) -> []string {
	names := make([dynamic]string, allocator)
	add :: proc(names: ^[dynamic]string, name: string) {
		if name == "" {
			return
		}
		for existing in names {
			if existing == name {
				return
			}
		}
		append(names, name)
	}
	for name in cfg.tiles.wall {
		add(&names, name)
	}
	add(&names, cfg.tiles.corner)
	add(&names, cfg.tiles.tsplit)
	add(&names, cfg.tiles.crossing)
	add(&names, cfg.tiles.doorway)
	add(&names, cfg.tiles.door)
	for _, models in cfg.floors {
		for name in models {
			add(&names, name)
		}
	}
	for _, models in cfg.decor {
		for name in models {
			add(&names, name)
		}
	}
	add(&names, cfg.markers.player_spawn.model)
	add(&names, cfg.markers.enemy_spawn.model)
	add(&names, cfg.markers.ground_slot.model)
	add(&names, cfg.props.chest)
	add(&names, cfg.props.chest_lid)
	add(&names, cfg.items.key.model)
	if cfg.items.swords > 0 {
		add(&names, cfg.items.sword.model)
	}
	add(&names, cfg.items.amulet.model)
	if cfg.enemies.enabled {
		add(&names, cfg.enemies.weapon)
	}
	return names[:]
}
