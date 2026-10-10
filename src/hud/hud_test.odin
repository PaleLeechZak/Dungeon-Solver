package hud

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:testing"

import "../dungeon"
import "../input"
import "../ui"

ROOT :: #directory + "/../../"

@(private = "file")
Fixture :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	cfg:       dungeon.Config,
	fonts:     Fonts,
	list:      ui.Draw_List,
	input:     input.State,
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
	f.fonts, err, ok = fonts_load(&f.cfg.ui, ROOT, f.allocator)
	if !testing.expectf(t, ok, "fonts: %s", err) {
		return false
	}
	ui.draw_list_init(&f.list, &f.fonts.atlas, f.allocator)
	f.input = {bindings = input.default_bindings(), fixed = input.fixed_bindings()}
	return true
}

@(private = "file")
count_color :: proc(list: ^ui.Draw_List, color: ui.Color) -> (quads: int) {
	for v in list.vertices {
		quads += int(v.color == color)
	}
	return quads / 6
}

// Number of quads textured with exactly this glyph.
@(private = "file")
count_glyph :: proc(list: ^ui.Draw_List, g: ui.Glyph) -> (quads: int) {
	for i := 0; i + 5 < len(list.vertices); i += 6 {
		quads += int(list.vertices[i].uv == g.uv_min && list.vertices[i + 2].uv == g.uv_max)
	}
	return
}

@(test)
character_lists_name_the_icons :: proc(t: ^testing.T) {
	path :: ROOT + "assets/kenney_input-prompts_1.5/Xbox Series/Fonts/kenney_input_xbox_series_characters.txt"
	data, err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	names := ui.glyph_map_parse(string(data), context.temp_allocator)
	testing.expect(t, len(names) > 90)
	testing.expect_value(t, names["controller_xbox360"], rune(0xE000))
	testing.expect_value(t, names["xbox_button_a"], rune(0xE004))
	testing.expect_value(t, names["xbox_stick_l"], rune(0xE04F))
	_, bogus := names["xbox_button_q"]
	testing.expect(t, !bogus)

	// Malformed lines are skipped rather than guessed at.
	odd := ui.glyph_map_parse("no colon here\n: x\nempty:\n  spaced_name :   Z  \r\nlast: ", context.temp_allocator)
	testing.expect_value(t, len(odd), 2)
	testing.expect_value(t, odd["spaced_name"], 'Z')
	testing.expect_value(t, odd["last"], rune(0xE123))
}

// The link the whole prompt display hangs on: every control the input system
// can name has an icon in the right font, found through that font's
// *_characters.txt, and that icon was rasterised.
@(test)
every_control_has_a_rasterised_icon :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	check :: proc(t: ^testing.T, f: ^Fixture, control: input.Control, pad: input.Pad_Type) {
		glyph := input.control_glyph(control, pad)
		r, known := icon_rune(&f.fonts, glyph)
		if !testing.expectf(t, known, "%v on %v: '%s' is not in the %v character list", control, pad, glyph.name, glyph.font) {
			return
		}
		testing.expectf(t, r >= 0xE000 && r <= 0xF8FF, "'%s' maps to %x, outside the private use area", glyph.name, r)
		baked, found := f.fonts.icons[glyph.font].glyphs[r]
		testing.expectf(t, found && baked.size.x > 8 && baked.size.y > 8, "'%s' was not rasterised", glyph.name)
		// Icons are drawn to fit the row they sit in.
		testing.expect(t, baked.size.y <= f.fonts.icon_size + 1)
	}
	for pad in input.Pad_Type {
		for key in input.Key do check(t, &f, key, pad)
		for button in input.Mouse_Button do check(t, &f, button, pad)
		for axis in input.Mouse_Axis do check(t, &f, axis, pad)
		for button in input.Pad_Button do check(t, &f, button, pad)
		for axis in input.Pad_Axis do check(t, &f, axis, pad)
	}
	testing.expect(t, !f.fonts.atlas.full)

	// Different controls really are different pictures.
	a, _ := icon_rune(&f.fonts, input.control_glyph(input.Pad_Button.South, .Xbox_One))
	b, _ := icon_rune(&f.fonts, input.control_glyph(input.Pad_Button.East, .Xbox_One))
	testing.expect(t, a != b)
	testing.expect(t, f.fonts.icons[.Xbox].glyphs[a].uv_min != f.fonts.icons[.Xbox].glyphs[b].uv_min)
}

@(test)
text_font_covers_ascii_and_measures_consistently :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	font := &f.fonts.text
	for r in rune(32) ..= rune(126) {
		_, found := font.glyphs[r]
		testing.expectf(t, found, "Crimson Pro is missing '%c'", r)
	}
	testing.expect(t, font.ascent > 10 && font.descent > 2)
	testing.expect(t, abs(font.ascent + font.descent - f.cfg.ui.font_size) < 1)

	width := ui.draw_text(&f.list, font, "Keys 2/5", {100, 200}, {1, 1, 1, 1})
	testing.expect(t, width > 40 && width < 200)
	testing.expect(t, abs(ui.measure_text(font, "Keys 2/5") - width) < 1e-3)
	// One quad per visible character; the space draws nothing.
	testing.expect_value(t, len(f.list.vertices), 7 * 6)
	for v in f.list.vertices {
		testing.expect(t, v.pos.x >= 99 && v.pos.x <= 100 + width + 2)
		testing.expect(t, v.pos.y >= 200 && v.pos.y <= 200 + ui.line_height(font) + 1)
		testing.expect(t, v.uv.x >= 0 && v.uv.x <= 1 && v.uv.y >= 0 && v.uv.y <= 1)
	}
	testing.expect(t, ui.measure_text(font, "WWWW") > ui.measure_text(font, "iiii"))
	testing.expect_value(t, ui.measure_text(font, ""), 0)

	// The atlas holds real coverage where a glyph was put, and the solid
	// block shapes are drawn from is fully opaque.
	g := font.glyphs['W']
	x := int((g.uv_min.x + g.uv_max.x) / 2 * f32(f.fonts.atlas.width))
	y0, y1 := int(g.uv_min.y * f32(f.fonts.atlas.height)), int(g.uv_max.y * f32(f.fonts.atlas.height))
	ink := 0
	for y in y0 ..< y1 {
		ink += int(f.fonts.atlas.pixels[(y * f.fonts.atlas.width + x) * 4 + 3] > 128)
	}
	testing.expect(t, ink > 0, "the glyph's cell in the atlas is empty")
	testing.expect_value(t, f.fonts.atlas.pixels[3], 255)
}

@(test)
atlas_reports_when_it_is_too_small :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	tiny := f.cfg.ui
	tiny.atlas_size = 64
	_, err, ok := fonts_load(&tiny, ROOT, f.allocator)
	testing.expect(t, !ok)
	testing.expect(t, err != "")

	missing := f.cfg.ui
	missing.font = "assets/fonts/nope.ttf"
	_, _, ok = fonts_load(&missing, ROOT, f.allocator)
	testing.expect(t, !ok)
}

@(test)
pips_fall_off_when_health_drops :: proc(t: ^testing.T) {
	p: Pips
	pips_update(&p, 5, 0.016)
	testing.expect_value(t, p.count, 0) // the first reading is not a loss

	pips_update(&p, 5, 0.016)
	testing.expect_value(t, p.count, 0)

	// Two points of damage in one frame: the two rightmost pips come loose.
	pips_update(&p, 3, 0.016)
	testing.expect_value(t, p.count, 2)
	testing.expect_value(t, p.falling[0].slot, 4)
	testing.expect_value(t, p.falling[1].slot, 3)
	testing.expect_value(t, p.falling[0].age, 0)

	// They age while more damage adds another.
	pips_update(&p, 2, 0.3)
	testing.expect_value(t, p.count, 3)
	testing.expect(t, abs(p.falling[0].age - 0.3) < 1e-5)
	testing.expect_value(t, p.falling[2].slot, 2)
	testing.expect_value(t, p.falling[2].age, 0)

	// Each one is gone once its fall is over.
	pips_update(&p, 2, PIP_FALL_TIME - 0.25)
	testing.expect_value(t, p.count, 1)
	testing.expect_value(t, p.falling[0].slot, 2)
	pips_update(&p, 2, PIP_FALL_TIME)
	testing.expect_value(t, p.count, 0)

	// Healing puts pips back without ceremony.
	pips_update(&p, 5, 0.016)
	testing.expect_value(t, p.count, 0)
	testing.expect_value(t, p.health, 5)

	// A new dungeon starts clean, whatever the knight had before.
	pips_update(&p, 1, 0.016)
	testing.expect_value(t, p.count, 4)
	pips_reset(&p)
	pips_update(&p, 5, 0.016)
	testing.expect_value(t, p.count, 0)

	// Death from full health does not overflow anything.
	pips_reset(&p)
	pips_update(&p, 40, 0)
	pips_update(&p, 0, 0)
	testing.expect_value(t, p.count, MAX_FALLING)
}

@(test)
a_falling_pip_drops_spins_and_fades :: proc(t: ^testing.T) {
	start, angle0, alpha0 := falling_pip(0)
	testing.expect_value(t, start, [2]f32{0, 0})
	testing.expect_value(t, angle0, 0)
	testing.expect_value(t, alpha0, 1)

	previous_alpha := f32(1)
	for step in 1 ..= 9 {
		age := PIP_FALL_TIME * f32(step) / 9
		_, angle, alpha := falling_pip(age)
		testing.expect(t, angle > 0)
		testing.expect(t, alpha < previous_alpha)
		previous_alpha = alpha
	}
	// It hops up a touch first, then gravity wins and it ends well below.
	early, _, _ := falling_pip(0.05)
	late, _, end_alpha := falling_pip(PIP_FALL_TIME)
	testing.expect(t, early.y < 0)
	testing.expect(t, late.y > 150)
	testing.expect_value(t, end_alpha, 0)
}

@(test)
hud_shows_pips_lines_and_prompts :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	pips: Pips
	pips_update(&pips, 5, 0)
	pips_update(&pips, 3, 0.1)
	pips_update(&pips, 3, 0.1)

	view := View {
		screen = {1600, 900},
		health = 3,
		max_health = 5,
		show_pips = true,
		lines = {"Seed 42", "Keys 1/5"},
		hints = {{"Move", {.Move_Forward, .Move_Right}}, {"Swing sword", {.Swing}}, {"Reload config", {.Reload_Config}}},
	}
	build(&f.list, &f.fonts, &pips, &f.input, view)

	// Five sockets, three of them filled, two pips in the air and fading.
	testing.expect_value(t, count_color(&f.list, PIP_EMPTY), 5)
	testing.expect_value(t, count_color(&f.list, PIP_FULL), 3)
	fading := 0
	for v in f.list.vertices {
		fading += int(v.color.rgb == PIP_FULL.rgb && v.color.a < 1 && v.color.a > 0)
	}
	testing.expect_value(t, fading / 6, 2)

	// The row of pips sits in the upper left corner.
	for v in f.list.vertices {
		if v.color == PIP_FULL {
			testing.expect(t, v.pos.x < 200 && v.pos.y < 70 && v.pos.x >= 0 && v.pos.y >= 0)
		}
		// Nothing is laid out off screen.
		testing.expect(t, v.pos.x >= 0 && v.pos.x <= 1600 && v.pos.y >= 0 && v.pos.y <= 900)
	}

	// Keyboard prompts: W A S D, mouse button and space, escape.
	icons := &f.fonts.icons[.Keyboard_Mouse]
	for name in ([]string{"keyboard_w", "keyboard_a", "keyboard_s", "keyboard_d", "mouse_left", "keyboard_space", "keyboard_f5"}) {
		r := f.fonts.names[.Keyboard_Mouse][name]
		testing.expectf(t, count_glyph(&f.list, icons.glyphs[r]) == 1, "%s should be shown once", name)
	}
	// Text is drawn twice, once as its own shadow.
	testing.expect_value(t, count_glyph(&f.list, f.fonts.text.glyphs['K']), 2)

	// Controls are in the lower left; the status lines under the pips.
	w := f.fonts.names[.Keyboard_Mouse]["keyboard_w"]
	for i := 0; i + 5 < len(f.list.vertices); i += 6 {
		if f.list.vertices[i].uv == icons.glyphs[w].uv_min {
			testing.expect(t, f.list.vertices[i].pos.y > 700 && f.list.vertices[i].pos.x < 100)
		}
		if f.list.vertices[i].uv == f.fonts.text.glyphs['K'].uv_min {
			testing.expect(t, f.list.vertices[i].pos.y > 60 && f.list.vertices[i].pos.y < 200)
		}
	}
}

@(test)
prompts_follow_the_device_in_hand :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	pips: Pips
	view := View {
		screen = {1280, 720},
		hints  = {{"Move", {.Move_Forward, .Move_Right}}, {"Swing sword", {.Swing}}, {"Reload config", {.Reload_Config}}},
	}
	shown :: proc(f: ^Fixture, font: input.Glyph_Font, name: string) -> int {
		return count_glyph(&f.list, f.fonts.icons[font].glyphs[f.fonts.names[font][name]])
	}

	// Pick up a PlayStation pad: the same HUD now shows its stick and Square.
	raw := input.Raw {
		pad_connected = true,
		pad_type      = .PS5,
	}
	raw.pad_buttons[.South] = true
	input.update(&f.input, &raw, 0.016)
	build(&f.list, &f.fonts, &pips, &f.input, view)
	testing.expect_value(t, shown(&f, .PlayStation, "playstation_stick_l"), 1)
	testing.expect_value(t, shown(&f, .PlayStation, "playstation_button_square"), 1)
	testing.expect_value(t, shown(&f, .Keyboard_Mouse, "keyboard_w"), 0)
	testing.expect_value(t, shown(&f, .Xbox, "xbox_button_x"), 0)
	// Reloading has no pad binding, so its row is dropped rather than left bare.
	testing.expect_value(t, count_glyph(&f.list, f.fonts.text.glyphs['R']), 0)
	testing.expect_value(t, count_glyph(&f.list, f.fonts.text.glyphs['M']), 2)
	// No pips were asked for.
	testing.expect_value(t, count_color(&f.list, PIP_EMPTY), 0)

	// An Xbox pad shows X where the PlayStation pad showed Square...
	clear(&f.list.vertices)
	raw.pad_type = .Xbox_One
	input.update(&f.input, &raw, 0.016)
	build(&f.list, &f.fonts, &pips, &f.input, view)
	testing.expect_value(t, shown(&f, .Xbox, "xbox_button_x"), 1)
	testing.expect_value(t, shown(&f, .PlayStation, "playstation_button_square"), 0)

	// ...a Switch pad shows Y for that same button...
	clear(&f.list.vertices)
	raw.pad_type = .Switch
	input.update(&f.input, &raw, 0.016)
	build(&f.list, &f.fonts, &pips, &f.input, view)
	testing.expect_value(t, shown(&f, .Switch, "switch_button_y"), 1)

	// ...and touching the keyboard brings the keys back.
	clear(&f.list.vertices)
	raw = {}
	raw.keys[.W] = true
	input.update(&f.input, &raw, 0.016)
	build(&f.list, &f.fonts, &pips, &f.input, view)
	testing.expect_value(t, shown(&f, .Keyboard_Mouse, "keyboard_w"), 1)
	testing.expect_value(t, shown(&f, .Switch, "switch_button_y"), 0)
	testing.expect_value(t, count_glyph(&f.list, f.fonts.text.glyphs['R']), 2)
}

@(test)
banner_is_centred :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	pips: Pips
	build(&f.list, &f.fonts, &pips, &f.input, View{screen = {1000, 600}, banner = "The knight has fallen"})
	lo, hi := f32(1e9), f32(-1e9)
	for v in f.list.vertices {
		lo = min(lo, v.pos.x)
		hi = max(hi, v.pos.x)
	}
	testing.expect(t, abs((lo + hi) / 2 - 500) < 4)
	testing.expect(t, len(f.list.vertices) > 6 * 10)
}

@(test)
ui_kit_pieces_are_in_the_atlas :: proc(t: ^testing.T) {
	f: Fixture
	defer virtual.arena_destroy(&f.arena)
	if !fixture_init(t, &f) {
		return
	}
	kit := &f.fonts.kit
	for piece in ([]ui.Image{kit.window, kit.window_border, kit.button, kit.button_border, kit.track}) {
		// Square panels with room for a frame on every side and a middle to stretch.
		testing.expect(t, piece.size.x == piece.size.y && piece.size.x > 2 * kit.margin)
		testing.expect(t, piece.uv_max.x > piece.uv_min.x && piece.uv_max.x <= 1)
	}
	testing.expect(t, kit.divider.size.x > kit.divider.size.y * 3, "the divider is a long thin rule")
	testing.expect(t, kit.divider_cap < kit.divider.size.x)

	// The pieces carry real pixels: a filled panel is opaque in the middle,
	// a border is see-through there.
	alpha_at_centre :: proc(a: ^ui.Atlas, image: ui.Image) -> u8 {
		x := int((image.uv_min.x + image.uv_max.x) / 2 * f32(a.width))
		y := int((image.uv_min.y + image.uv_max.y) / 2 * f32(a.height))
		return a.pixels[(y * a.width + x) * 4 + 3]
	}
	testing.expect_value(t, alpha_at_centre(&f.fonts.atlas, kit.window), 255)
	testing.expect_value(t, alpha_at_centre(&f.fonts.atlas, kit.window_border), 0)
	testing.expect_value(t, alpha_at_centre(&f.fonts.atlas, kit.track), 255)
	testing.expect(t, !f.fonts.atlas.full)

	missing := f.cfg.ui
	missing.kit.window = "Panel/nope.png"
	_, _, ok := fonts_load(&missing, ROOT, f.allocator)
	testing.expect(t, !ok)
}