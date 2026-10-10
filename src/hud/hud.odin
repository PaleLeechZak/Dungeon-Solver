// The heads-up display: health pips, the status lines that used to live in
// the window title, and the list of controls for whatever device the player
// is holding. Pure layout over the ui package; nothing here draws to a GPU.
package hud

import "core:fmt"
import "core:os"
import "core:strings"

import "../assets"
import "../dungeon"
import "../input"
import "../ui"

Fonts :: struct {
	atlas:     ui.Atlas,
	text:      ui.Font,
	icons:     [input.Glyph_Font]ui.Font,
	names:     [input.Glyph_Font]map[string]rune, // from each font's *_characters.txt
	icon_size: f32,
	kit:       Kit,
}

// The UI kit pieces the menus are drawn with, sitting in the same atlas.
Kit :: struct {
	window:        ui.Image,
	window_border: ui.Image,
	button:        ui.Image,
	button_border: ui.Image,
	track:         ui.Image,
	divider:       ui.Image,
	margin:        f32,
	divider_cap:   f32,
}

// Every icon name the input system can ask for from one prompt font.
needed_icons :: proc(font: input.Glyph_Font, allocator := context.allocator) -> []string {
	names := make([dynamic]string, allocator)
	add :: proc(names: ^[dynamic]string, font: input.Glyph_Font, glyph: input.Glyph) {
		if glyph.font != font || glyph.name == "" {
			return
		}
		for existing in names {
			if existing == glyph.name {
				return
			}
		}
		append(names, glyph.name)
	}
	for pad in input.Pad_Type {
		for key in input.Key do add(&names, font, input.control_glyph(key, pad))
		for button in input.Mouse_Button do add(&names, font, input.control_glyph(button, pad))
		for axis in input.Mouse_Axis do add(&names, font, input.control_glyph(axis, pad))
		for button in input.Pad_Button do add(&names, font, input.control_glyph(button, pad))
		for axis in input.Pad_Axis do add(&names, font, input.control_glyph(axis, pad))
	}
	return names[:]
}

@(private)
prompt_config :: proc(cfg: ^dungeon.Ui_Config, font: input.Glyph_Font) -> dungeon.Prompt_Font {
	switch font {
	case .Keyboard_Mouse:
		return cfg.prompts.keyboard_mouse
	case .Xbox:
		return cfg.prompts.xbox
	case .PlayStation:
		return cfg.prompts.playstation
	case .Switch:
		return cfg.prompts.switch_pad
	}
	return {}
}

// Loads the text font and the prompt fonts and rasterises what the HUD needs
// into one atlas. `root` is put in front of the config's paths. An icon name
// the input system uses but a font's character list lacks is an error.
fonts_load :: proc(
	cfg: ^dungeon.Ui_Config,
	root := "",
	allocator := context.allocator,
) -> (
	fonts: Fonts,
	err: string,
	ok: bool,
) {
	read :: proc(root, path: string) -> (data: []byte, ok: bool) {
		full := strings.concatenate({root, path}, context.temp_allocator)
		bytes, read_err := os.read_entire_file(full, context.temp_allocator)
		return bytes, read_err == nil
	}

	fonts.icon_size = cfg.icon_size
	ui.atlas_init(&fonts.atlas, cfg.atlas_size, cfg.atlas_size, allocator)

	// The UI kit goes in first: its pieces are the biggest things in the atlas.
	fonts.kit.margin = cfg.kit.margin
	fonts.kit.divider_cap = cfg.kit.divider_cap
	pieces := [?]struct {
		into: ^ui.Image,
		file: string,
	} {
		{&fonts.kit.window, cfg.kit.window},
		{&fonts.kit.window_border, cfg.kit.window_border},
		{&fonts.kit.button, cfg.kit.button},
		{&fonts.kit.button_border, cfg.kit.button_border},
		{&fonts.kit.track, cfg.kit.track},
		{&fonts.kit.divider, cfg.kit.divider},
	}
	for piece in pieces {
		path := strings.concatenate({root, cfg.kit.dir, "/", piece.file}, context.temp_allocator)
		img, loaded := assets.image_load(path)
		if !loaded {
			return fonts, fmt.aprintf("cannot load UI kit piece '%s'", path, allocator = allocator), false
		}
		piece.into^, ok = ui.atlas_add_image(&fonts.atlas, img.pixels, img.width, img.height)
		assets.image_destroy(&img)
		if !ok {
			return fonts, fmt.aprintf("UI kit piece '%s' does not fit the atlas", path, allocator = allocator), false
		}
	}

	text_data, text_ok := read(root, cfg.font)
	if !text_ok {
		return fonts, fmt.aprintf("cannot read font '%s'", cfg.font, allocator = allocator), false
	}
	ascii: [95]rune
	for &r, i in ascii {
		r = rune(32 + i)
	}
	if fonts.text, ok = ui.font_bake(&fonts.atlas, text_data, cfg.font_size, ascii[:], allocator); !ok {
		return fonts, fmt.aprintf("cannot rasterise font '%s'", cfg.font, allocator = allocator), false
	}

	for font in input.Glyph_Font {
		prompt := prompt_config(cfg, font)
		characters, chars_ok := read(root, prompt.characters)
		if !chars_ok {
			return fonts, fmt.aprintf("cannot read '%s'", prompt.characters, allocator = allocator), false
		}
		fonts.names[font] = ui.glyph_map_parse(string(characters), allocator)

		wanted := needed_icons(font, context.temp_allocator)
		runes := make([]rune, len(wanted), context.temp_allocator)
		for name, i in wanted {
			r, known := fonts.names[font][name]
			if !known {
				return fonts, fmt.aprintf("'%s' does not list the icon '%s'", prompt.characters, name, allocator = allocator), false
			}
			runes[i] = r
		}

		data, data_ok := read(root, prompt.font)
		if !data_ok {
			return fonts, fmt.aprintf("cannot read font '%s'", prompt.font, allocator = allocator), false
		}
		if fonts.icons[font], ok = ui.font_bake(&fonts.atlas, data, cfg.icon_size, runes, allocator); !ok {
			return fonts,
				fmt.aprintf("cannot rasterise '%s' (atlas_size %d too small?)", prompt.font, cfg.atlas_size, allocator = allocator),
				false
		}
		for name, i in wanted {
			if runes[i] not_in fonts.icons[font].glyphs {
				return fonts, fmt.aprintf("font '%s' has no glyph for '%s'", prompt.font, name, allocator = allocator), false
			}
		}
	}
	return fonts, "", true
}

// The character a prompt icon sits on, looked up by name in the font's list.
icon_rune :: proc(fonts: ^Fonts, glyph: input.Glyph) -> (r: rune, ok: bool) {
	return fonts.names[glyph.font][glyph.name]
}

// ---------------------------------------------------------------- pips

MAX_FALLING :: 16
PIP_FALL_TIME :: 0.9 // seconds a lost pip takes to drop away
PIP_GRAVITY :: 1500 // pixels per second squared
PIP_RADIUS :: 13
PIP_SPACING :: 36
MARGIN :: 24

PIP_FULL :: ui.Color{0.86, 0.16, 0.20, 1}
PIP_EMPTY :: ui.Color{0.05, 0.04, 0.06, 0.55}
TEXT_COLOR :: ui.Color{0.96, 0.93, 0.86, 1}
SHADOW_COLOR :: ui.Color{0, 0, 0, 0.8}

Falling_Pip :: struct {
	slot: int,
	age:  f32,
}

// Remembers the health last shown, so that a drop can be turned into pips
// tumbling off the row.
Pips :: struct {
	health:  int,
	known:   bool,
	falling: [MAX_FALLING]Falling_Pip,
	count:   int,
}

// Forgets everything, e.g. for a new dungeon: the next update shows the
// health as it is without any pip falling.
pips_reset :: proc(p: ^Pips) {
	p^ = {}
}

pips_update :: proc(p: ^Pips, health: int, dt: f32) {
	kept := 0
	for i in 0 ..< p.count {
		p.falling[i].age += dt
		if p.falling[i].age < PIP_FALL_TIME {
			p.falling[kept] = p.falling[i]
			kept += 1
		}
	}
	p.count = kept

	if p.known {
		// Each pip lost since last frame drops from its own place in the row.
		for slot := p.health - 1; slot >= max(health, 0); slot -= 1 {
			if p.count < MAX_FALLING {
				p.falling[p.count] = {slot = slot}
				p.count += 1
			}
		}
	}
	p.health = health
	p.known = true
}

pip_centre :: proc(slot: int) -> [2]f32 {
	return {MARGIN + PIP_RADIUS + f32(slot) * PIP_SPACING, MARGIN + PIP_RADIUS}
}

// Where a pip that came loose `age` seconds ago is, relative to its slot:
// it tips sideways, spins and fades as gravity takes it.
falling_pip :: proc(age: f32) -> (offset: [2]f32, angle: f32, alpha: f32) {
	offset = {34 * age, 0.5 * PIP_GRAVITY * age * age - 120 * age}
	angle = 7 * age
	alpha = clamp(1 - age / PIP_FALL_TIME, 0, 1)
	return
}

// ---------------------------------------------------------------- layout

// One row of the controls list: a label and the actions whose bindings are
// shown as icons in front of it.
Hint :: struct {
	label:   string,
	actions: []input.Action,
}

View :: struct {
	screen:     [2]f32, // pixels
	health:     int,
	max_health: int,
	show_pips:  bool,
	lines:      []string, // status text, top left under the pips
	hints:      []Hint, // controls, bottom left
	banner:     string, // large notice across the middle, "" for none
}

ICON_GAP :: 4
LABEL_GAP :: 12
ROW_GAP :: 6

@(private)
shadowed_text :: proc(list: ^ui.Draw_List, font: ^ui.Font, text: string, pos: [2]f32, color: ui.Color) -> f32 {
	ui.draw_text(list, font, text, pos + {1.5, 1.5}, SHADOW_COLOR)
	return ui.draw_text(list, font, text, pos, color)
}

// Appends the whole HUD to the draw list.
build :: proc(list: ^ui.Draw_List, fonts: ^Fonts, pips: ^Pips, in_state: ^input.State, view: View) {
	top := f32(MARGIN)

	if view.show_pips {
		for slot in 0 ..< view.max_health {
			ui.draw_diamond(list, pip_centre(slot), PIP_RADIUS + 3, 0, PIP_EMPTY)
			if slot < view.health {
				ui.draw_diamond(list, pip_centre(slot), PIP_RADIUS, 0, PIP_FULL)
			}
		}
		for falling in pips.falling[:pips.count] {
			offset, angle, alpha := falling_pip(falling.age)
			color := PIP_FULL
			color.a = alpha
			ui.draw_diamond(list, pip_centre(falling.slot) + offset, PIP_RADIUS, angle, color)
		}
		top += 2 * PIP_RADIUS + 14
	}

	for line in view.lines {
		shadowed_text(list, &fonts.text, line, {MARGIN, top}, TEXT_COLOR)
		top += ui.line_height(&fonts.text)
	}

	// Controls, stacked upwards from the bottom left corner.
	// An action with nothing bound on the device in hand gets no row.
	row_height := fonts.icon_size + ROW_GAP
	glyphs: [8]input.Glyph
	rows := 0
	for hint in view.hints {
		rows += int(input.action_glyphs(in_state, hint.actions, glyphs[:]) > 0)
	}
	y := view.screen.y - MARGIN - f32(rows) * row_height
	for hint in view.hints {
		count := input.action_glyphs(in_state, hint.actions, glyphs[:])
		if count == 0 {
			continue
		}
		x := f32(MARGIN)
		for glyph in glyphs[:count] {
			if r, known := icon_rune(fonts, glyph); known {
				width := ui.draw_icon(list, &fonts.icons[glyph.font], r, {x, y}, fonts.icon_size, TEXT_COLOR)
				x += width + ICON_GAP
			}
		}
		text_y := y + (fonts.icon_size - ui.line_height(&fonts.text)) / 2
		shadowed_text(list, &fonts.text, hint.label, {x + LABEL_GAP - ICON_GAP, text_y}, TEXT_COLOR)
		y += row_height
	}

	if view.banner != "" {
		width := ui.measure_text(&fonts.text, view.banner)
		pos := [2]f32{(view.screen.x - width) / 2, view.screen.y * 0.3}
		pad := [2]f32{18, 10}
		ui.draw_rect(list, pos - pad, {width, ui.line_height(&fonts.text)} + pad * 2, {0, 0, 0, 0.6})
		ui.draw_text(list, &fonts.text, view.banner, pos, TEXT_COLOR)
	}
}
