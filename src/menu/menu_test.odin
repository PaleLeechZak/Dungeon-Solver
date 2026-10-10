package menu

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import "../dungeon"
import "../hud"
import "../input"
import "../ui"

ROOT :: #directory + "/../../"
SCREEN :: [2]f32{1600, 900}

// A menu, the settings it edits and a pretend set of devices to drive it.
@(private = "file")
Rig :: struct {
	arena:     virtual.Arena,
	allocator: runtime.Allocator,
	menu:      Menu,
	settings:  Settings,
	state:     input.State,
	raw:       input.Raw,
	previous:  input.Raw,
	pointer:   [2]f32,
}

@(private = "file")
rig_init :: proc(t: ^testing.T, r: ^Rig) -> bool {
	if !testing.expect(t, virtual.arena_init_growing(&r.arena) == nil) {
		return false
	}
	r.allocator = virtual.arena_allocator(&r.arena)
	r.settings = settings_default(r.allocator)
	r.state = {
		fixed = input.fixed_bindings(),
	}
	r.pointer = {-100, -100}
	return true
}

// One frame with the devices as they currently are in r.raw.
@(private = "file")
frame :: proc(r: ^Rig, dt: f32 = 0.016, pointer_moved := false) -> Events {
	r.state.bindings = r.settings.bindings[:]
	input.update(&r.state, &r.raw, dt)
	events := update(
		&r.menu,
		&r.settings,
		{
			state = &r.state,
			raw = &r.raw,
			previous = &r.previous,
			pointer = r.pointer,
			pointer_moved = pointer_moved,
			pointer_down = r.raw.mouse_buttons[.Left],
			screen = SCREEN,
			dt = dt,
		},
	)
	r.previous = r.raw
	return events
}

// Presses a key for one frame and lets go for the next.
@(private = "file")
tap :: proc(r: ^Rig, key: input.Key) -> Events {
	r.raw.keys[key] = true
	events := frame(r)
	r.raw.keys[key] = false
	return events + frame(r)
}

@(private = "file")
tap_pad :: proc(r: ^Rig, button: input.Pad_Button) -> Events {
	r.raw.pad_connected = true
	r.raw.pad_buttons[button] = true
	events := frame(r)
	r.raw.pad_buttons[button] = false
	return events + frame(r)
}

@(private = "file")
click :: proc(r: ^Rig, at: [2]f32) -> Events {
	r.pointer = at
	events := frame(r, pointer_moved = true)
	r.raw.mouse_buttons[.Left] = true
	events += frame(r)
	r.raw.mouse_buttons[.Left] = false
	return events + frame(r)
}

@(private = "file")
row_of :: proc(r: ^Rig, id: Item_Id, slot := 0) -> (index: int, rect: Rect) {
	buffer: [MAX_ITEMS]Item
	l := layout(r.menu.screen, SCREEN)
	for item, i in items(r.menu.screen, &buffer) {
		if item.id == id && (id != .Bind || item.slot == slot) {
			return i, l.rows[i]
		}
	}
	return -1, {}
}

@(private = "file")
centre :: proc(rect: Rect) -> [2]f32 {
	return rect.pos + rect.size / 2
}

@(private = "file")
slot_index :: proc(action: input.Action, sign: f32) -> int {
	for row, i in SLOTS {
		if row.slot.action == action && row.slot.sign == sign {
			return i
		}
	}
	return -1
}

@(test)
pause_opens_and_closes_the_menu :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	testing.expect(t, !is_open(&r.menu))
	testing.expect_value(t, frame(&r), Events{})

	testing.expect_value(t, tap(&r, .Escape), Events{.Opened})
	testing.expect_value(t, r.menu.screen, Screen.Pause)
	testing.expect_value(t, r.menu.cursor, 0)

	// The same key closes it again; so does choosing Resume.
	testing.expect_value(t, tap(&r, .Escape), Events{.Resumed})
	testing.expect(t, !is_open(&r.menu))
	tap(&r, .Escape)
	testing.expect_value(t, tap(&r, .Enter), Events{.Resumed})
	testing.expect(t, !is_open(&r.menu))

	// A pad's Start button does the same job, and its B button backs out.
	testing.expect_value(t, tap_pad(&r, .Start), Events{.Opened})
	testing.expect_value(t, tap_pad(&r, .East), Events{.Resumed})
	// Other keys do not open it.
	testing.expect_value(t, tap(&r, .Enter), Events{})
	testing.expect(t, !is_open(&r.menu))
}

@(test)
rows_are_walked_and_chosen :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	tap(&r, .Escape)

	tap(&r, .Down)
	testing.expect_value(t, r.menu.cursor, 1)
	tap(&r, .Up)
	tap(&r, .Up)
	testing.expect_value(t, r.menu.cursor, 4) // wrapped to the last row
	tap(&r, .Down)
	testing.expect_value(t, r.menu.cursor, 0)

	// Into the options and back: the cursor returns to where it left from.
	tap(&r, .Down)
	testing.expect_value(t, tap(&r, .Enter), Events{})
	testing.expect_value(t, r.menu.screen, Screen.Options)
	testing.expect_value(t, r.menu.cursor, 0)
	testing.expect_value(t, tap(&r, .Backspace), Events{})
	testing.expect_value(t, r.menu.screen, Screen.Pause)
	testing.expect_value(t, r.menu.cursor, 1)

	// The Back row does what the back key does.
	tap(&r, .Down)
	tap(&r, .Enter)
	testing.expect_value(t, r.menu.screen, Screen.Controls)
	tap(&r, .Up) // wraps from the first row to Back, the last
	tap(&r, .Enter)
	testing.expect_value(t, r.menu.screen, Screen.Pause)
	testing.expect_value(t, r.menu.cursor, 2)

	// From a sub-screen, Pause closes the whole menu at once.
	tap(&r, .Enter)
	testing.expect_value(t, tap(&r, .Escape), Events{.Resumed})
	testing.expect(t, !is_open(&r.menu))

	// Quit is reported, not acted on: the game decides what quitting means.
	tap(&r, .Escape)
	tap(&r, .Up)
	testing.expect_value(t, tap(&r, .Enter), Events{.Quit})

	// A pad's stick and A button work the menu too.
	close(&r.menu)
	tap_pad(&r, .Start)
	r.raw.pad_axes[.Left_Y] = 1
	frame(&r)
	r.raw.pad_axes[.Left_Y] = 0
	frame(&r)
	testing.expect_value(t, r.menu.cursor, 1)
	tap_pad(&r, .South)
	testing.expect_value(t, r.menu.screen, Screen.Options)
}

@(test)
the_pointer_highlights_and_clicks :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	tap(&r, .Escape)

	index, rect := row_of(&r, .Controls)
	r.pointer = centre(rect)
	frame(&r, pointer_moved = true)
	testing.expect_value(t, r.menu.cursor, index)

	// Resting there, the keys still move the highlight away.
	tap(&r, .Up)
	testing.expect_value(t, r.menu.cursor, index - 1)

	testing.expect_value(t, click(&r, centre(rect)), Events{})
	testing.expect_value(t, r.menu.screen, Screen.Controls)

	// A click outside every row does nothing.
	before := r.menu
	click(&r, {5, 5})
	testing.expect_value(t, r.menu.screen, before.screen)
	testing.expect_value(t, r.menu.cursor, before.cursor)

	_, back := row_of(&r, .Back)
	click(&r, centre(back))
	testing.expect_value(t, r.menu.screen, Screen.Pause)
	_, resume := row_of(&r, .Resume)
	testing.expect_value(t, click(&r, centre(resume)), Events{.Resumed})
}

@(test)
volumes_are_set_by_keys_and_pointer :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	r.settings.master, r.settings.sound, r.settings.music = 0.5, 0.5, 0.5
	tap(&r, .Escape)
	tap(&r, .Down)
	tap(&r, .Enter)
	near :: proc(a, b: f32) -> bool {
		return abs(a - b) < 1e-4
	}

	// One tap, one step, on the highlighted volume only.
	testing.expect_value(t, tap(&r, .Right), Events{.Volume_Changed})
	testing.expect(t, near(r.settings.master, 0.55))
	testing.expect(t, near(r.settings.sound, 0.5) && near(r.settings.music, 0.5))
	tap(&r, .Left)
	tap(&r, .Left)
	testing.expect(t, near(r.settings.master, 0.45))

	// Held, it keeps going after a pause, and stops at the end of the scale.
	tap(&r, .Down)
	r.raw.keys[.Right] = true
	frame(&r)
	testing.expect(t, near(r.settings.sound, 0.55))
	for _ in 0 ..< 15 {
		frame(&r)
	}
	testing.expect(t, near(r.settings.sound, 0.55), "no repeat before the delay is up")
	for _ in 0 ..< 30 {
		frame(&r)
	}
	testing.expect(t, r.settings.sound > 0.7 && r.settings.sound < 1, "held, it repeats at a steady rate")
	for _ in 0 ..< 120 {
		frame(&r)
	}
	testing.expect_value(t, r.settings.sound, 1)
	testing.expect_value(t, frame(&r), Events{}) // nothing left to change
	r.raw.keys[.Right] = false
	frame(&r)
	// Letting go and tapping again is one step, not a burst.
	tap(&r, .Left)
	testing.expect(t, near(r.settings.sound, 0.95))

	// Clicking on the slider puts it there; dragging follows the pointer.
	index, rect := row_of(&r, .Music)
	track := slider_rect(rect)
	r.pointer = {track.pos.x + track.size.x * 0.2, track.pos.y + 8}
	frame(&r, pointer_moved = true)
	testing.expect_value(t, r.menu.cursor, index)
	r.raw.mouse_buttons[.Left] = true
	testing.expect_value(t, frame(&r), Events{.Volume_Changed})
	testing.expect(t, near(r.settings.music, 0.2))
	r.pointer.x = track.pos.x + track.size.x * 0.8
	frame(&r, pointer_moved = true)
	testing.expect(t, near(r.settings.music, 0.8))
	// Dragged far past the end it stops at the end, and keeps hold even when
	// the pointer strays off the row.
	r.pointer = {track.pos.x + track.size.x + 500, track.pos.y - 200}
	frame(&r, pointer_moved = true)
	testing.expect_value(t, r.settings.music, 1)
	r.raw.mouse_buttons[.Left] = false
	frame(&r)
	// Released, moving the pointer changes nothing.
	r.pointer = {track.pos.x, track.pos.y + 8}
	testing.expect_value(t, frame(&r, pointer_moved = true), Events{})
	testing.expect_value(t, r.settings.music, 1)

	// Clicking the label rather than the slider only highlights the row.
	_, master := row_of(&r, .Master)
	before := r.settings.master
	click(&r, master.pos + {30, master.size.y / 2})
	testing.expect_value(t, r.settings.master, before)

	// Volumes are whole steps and stay within 0..1.
	for _ in 0 ..< 40 {
		tap(&r, .Left)
	}
	testing.expect_value(t, r.settings.master, 0)
}

@(test)
controls_are_rebound_from_the_menu :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	tap(&r, .Escape)
	tap(&r, .Down)
	tap(&r, .Down)
	tap(&r, .Enter)
	testing.expect_value(t, r.menu.screen, Screen.Controls)
	glyphs: [8]input.Glyph
	swing := input.Slot{.Swing, 1}

	// Walk to "Swing sword" and choose it: the row waits for a press. The
	// Enter that chose it is not taken as that press.
	index, _ := row_of(&r, .Bind, slot_index(.Swing, 1))
	for r.menu.cursor != index {
		tap(&r, .Down)
	}
	testing.expect_value(t, tap(&r, .Enter), Events{})
	testing.expect(t, r.menu.capturing)
	testing.expect_value(t, input.slot_glyphs(r.settings.bindings[:], swing, .Keyboard_Mouse, .Generic, glyphs[:]), 2)

	// Escape backs out of the row without closing the menu or changing anything.
	testing.expect_value(t, tap(&r, .Escape), Events{})
	testing.expect(t, !r.menu.capturing)
	testing.expect_value(t, r.menu.screen, Screen.Controls)
	testing.expect_value(t, input.slot_glyphs(r.settings.bindings[:], swing, .Keyboard_Mouse, .Generic, glyphs[:]), 2)

	// Choose it again and press F.
	tap(&r, .Enter)
	testing.expect_value(t, tap(&r, .F), Events{.Bindings_Changed})
	testing.expect(t, !r.menu.capturing)
	testing.expect_value(t, input.slot_glyphs(r.settings.bindings[:], swing, .Keyboard_Mouse, .Generic, glyphs[:]), 1)
	testing.expect_value(t, glyphs[0].name, "keyboard_f")
	// The gamepad's bindings for the same row were left alone.
	testing.expect_value(t, input.slot_glyphs(r.settings.bindings[:], swing, .Gamepad, .Xbox_One, glyphs[:]), 2)

	// While a row waits, the menu keys are just keys: W becomes the binding
	// instead of moving the cursor.
	cursor := r.menu.cursor
	tap(&r, .Enter)
	testing.expect_value(t, tap(&r, .W), Events{.Bindings_Changed})
	testing.expect_value(t, r.menu.cursor, cursor)
	testing.expect_value(t, input.slot_glyphs(r.settings.bindings[:], swing, .Keyboard_Mouse, .Generic, glyphs[:]), 1)
	testing.expect_value(t, glyphs[0].name, "keyboard_w")

	// With a pad in hand the same row edits the pad's binding: choose it with
	// A, then push a button. Start cancels instead of being bound.
	tap_pad(&r, .South)
	testing.expect(t, r.menu.capturing)
	testing.expect_value(t, tap_pad(&r, .Start), Events{})
	testing.expect(t, !r.menu.capturing && is_open(&r.menu))
	tap_pad(&r, .South)
	testing.expect_value(t, tap_pad(&r, .North), Events{.Bindings_Changed})
	testing.expect_value(t, input.slot_glyphs(r.settings.bindings[:], swing, .Gamepad, .Xbox_One, glyphs[:]), 1)
	testing.expect_value(t, glyphs[0].name, "xbox_button_y")
	// The keyboard binding made a moment ago is still there.
	testing.expect_value(t, input.slot_glyphs(r.settings.bindings[:], swing, .Keyboard_Mouse, .Generic, glyphs[:]), 1)

	// A row can be chosen with the mouse and bound to a mouse button.
	_, row := row_of(&r, .Bind, slot_index(.Fast, 1))
	click(&r, centre(row))
	testing.expect(t, r.menu.capturing)
	r.raw.mouse_buttons[.Middle] = true
	testing.expect_value(t, frame(&r), Events{.Bindings_Changed})
	r.raw.mouse_buttons[.Middle] = false
	frame(&r)
	testing.expect_value(t, input.slot_glyphs(r.settings.bindings[:], {.Fast, 1}, .Keyboard_Mouse, .Generic, glyphs[:]), 1)
	testing.expect_value(t, glyphs[0].name, "mouse_scroll")

	// The game sees the new bindings straight away.
	close(&r.menu)
	r.raw = {}
	r.raw.keys[.W] = true
	frame(&r)
	testing.expect(t, r.state.down[.Swing])
	r.raw = {}
	frame(&r)

	// Reset puts everything back.
	tap(&r, .Escape)
	tap(&r, .Down)
	tap(&r, .Down)
	tap(&r, .Enter)
	reset, _ := row_of(&r, .Reset)
	for r.menu.cursor != reset {
		tap(&r, .Up)
	}
	testing.expect_value(t, tap(&r, .Enter), Events{.Bindings_Changed})
	testing.expect_value(t, len(r.settings.bindings), len(input.default_bindings()))
	for b, i in input.default_bindings() {
		testing.expect(t, r.settings.bindings[i] == b) or_break
	}
}

@(test)
every_gameplay_action_can_be_rebound :: proc(t: ^testing.T) {
	// Each default binding belongs to a row of the controls screen, so there
	// is nothing the player is stuck with...
	for b in input.default_bindings() {
		found := false
		for row in SLOTS {
			found ||= input.binding_in_slot(b, row.slot, input.control_source(b.control))
		}
		testing.expectf(t, found, "%v on %v has no row", b.action, b.control)
	}
	// ...and no row offers something the menus themselves depend on.
	for row in SLOTS {
		testing.expect(t, rebindable(row.slot.action))
		for b in input.fixed_bindings() {
			testing.expectf(t, b.action != row.slot.action, "%v is fixed but has a row", b.action)
		}
		testing.expect(t, row.slot.sign == 1 || input.action_kind(row.slot.action) == .Axis)
	}
	testing.expect(t, !rebindable(.Pause) && !rebindable(.Menu_Confirm) && !rebindable(.Look_X))
}

@(test)
layout_fits_the_window :: proc(t: ^testing.T) {
	for size in ([][2]f32{{1600, 900}, {1280, 720}, {800, 500}, {640, 400}}) {
		for screen in ([]Screen{.Pause, .Options, .Controls}) {
			l := layout(screen, size)
			testing.expect(t, l.count > 0)
			w := l.window
			testing.expectf(t, w.pos.x >= 0 && w.pos.y >= 0 && w.pos.x + w.size.x <= size.x && w.pos.y + w.size.y <= size.y, "%v at %v: window %v", screen, size, w)
			// Centred.
			testing.expect(t, abs(w.pos.x + w.size.x / 2 - size.x / 2) <= 1)
			for row, i in l.rows[:l.count] {
				testing.expect(t, row.size.y > 8)
				testing.expect(t, row.pos.x > w.pos.x && row.pos.x + row.size.x < w.pos.x + w.size.x)
				testing.expect(t, row.pos.y >= w.pos.y && row.pos.y + row.size.y <= w.pos.y + w.size.y)
				if i > 0 {
					// Stacked without overlapping, so a click lands on one row.
					testing.expect(t, row.pos.y >= l.rows[i - 1].pos.y + l.rows[i - 1].size.y - 0.01)
				}
				track := slider_rect(row)
				testing.expect(t, track.pos.x > row.pos.x && track.pos.x + track.size.x < row.pos.x + row.size.x)
			}
		}
	}
	testing.expect_value(t, layout(.Closed, {1600, 900}).count, 0)
}

@(private = "file")
Stage :: struct {
	using rig: Rig,
	cfg:       dungeon.Config,
	fonts:     hud.Fonts,
	list:      ui.Draw_List,
}

@(private = "file")
stage_init :: proc(t: ^testing.T, s: ^Stage) -> bool {
	if !rig_init(t, s) {
		return false
	}
	err: string
	ok: bool
	s.cfg, err, ok = dungeon.config_load(ROOT + "config/dungeon.json5", s.allocator)
	if !testing.expectf(t, ok, "config: %s", err) {
		return false
	}
	s.fonts, err, ok = hud.fonts_load(&s.cfg.ui, ROOT, s.allocator)
	if !testing.expectf(t, ok, "fonts: %s", err) {
		return false
	}
	ui.draw_list_init(&s.list, &s.fonts.atlas, s.allocator)
	return true
}

// Quads textured from somewhere inside one atlas image.
@(private = "file")
quads_of :: proc(list: ^ui.Draw_List, image: ui.Image, color: ui.Color) -> (count: int) {
	for i := 0; i + 5 < len(list.vertices); i += 6 {
		inside := true
		for v in list.vertices[i:][:6] {
			inside &&= v.uv.x >= image.uv_min.x - 1e-6 && v.uv.x <= image.uv_max.x + 1e-6
			inside &&= v.uv.y >= image.uv_min.y - 1e-6 && v.uv.y <= image.uv_max.y + 1e-6
			inside &&= v.color == color
		}
		count += int(inside)
	}
	return
}

@(private = "file")
shows_glyph :: proc(s: ^Stage, font: input.Glyph_Font, name: string) -> (count: int) {
	g := s.fonts.icons[font].glyphs[s.fonts.names[font][name]]
	for i := 0; i + 5 < len(s.list.vertices); i += 6 {
		count += int(s.list.vertices[i].uv == g.uv_min && s.list.vertices[i + 2].uv == g.uv_max)
	}
	return
}

@(private = "file")
redraw :: proc(s: ^Stage) {
	clear(&s.list.vertices)
	draw(&s.list, &s.fonts, &s.menu, &s.settings, &s.state, SCREEN)
}

@(test)
screens_are_built_from_the_ui_kit :: proc(t: ^testing.T) {
	s: Stage
	defer virtual.arena_destroy(&s.arena)
	if !stage_init(t, &s) {
		return
	}
	kit := &s.fonts.kit

	// Closed, the menu draws nothing at all.
	redraw(&s)
	testing.expect_value(t, len(s.list.vertices), 0)

	tap(&s, .Escape)
	redraw(&s)
	// A window: the kit's panel tinted dark with its border drawn over it,
	// each a nine-slice.
	testing.expect_value(t, quads_of(&s.list, kit.window, WINDOW_FILL), 9)
	testing.expect_value(t, quads_of(&s.list, kit.window_border, WINDOW_FRAME), 9)
	// One highlighted row, framed with the kit's button pieces.
	testing.expect_value(t, quads_of(&s.list, kit.button_border, HIGHLIGHT_FRAME), 9)
	testing.expect_value(t, quads_of(&s.list, kit.button, HIGHLIGHT_FILL), 9)
	// The rule under the title, an ornament at each end.
	testing.expect_value(t, quads_of(&s.list, kit.divider, WINDOW_FRAME), 4)
	// Everything is on screen, and the game behind is dimmed first.
	testing.expect_value(t, s.list.vertices[0].color, DIM)
	for v in s.list.vertices {
		testing.expect(t, v.pos.x >= 0 && v.pos.x <= SCREEN.x && v.pos.y >= 0 && v.pos.y <= SCREEN.y) or_break
	}
	// The highlight is on the row the cursor is on.
	l := layout(.Pause, SCREEN)
	for i := 0; i + 5 < len(s.list.vertices); i += 6 {
		if s.list.vertices[i].color == HIGHLIGHT_FRAME {
			testing.expect(t, s.list.vertices[i].pos.y >= l.rows[0].pos.y - 0.01 && s.list.vertices[i].pos.y <= l.rows[0].pos.y + l.rows[0].size.y)
		}
	}
	// Key hints at the bottom use the device's own icons.
	testing.expect_value(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_enter"), 1)
	testing.expect(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_escape") >= 1)

	// Options: three sliders drawn with the kit's track piece, filled as far
	// as their volume.
	tap(&s, .Down)
	tap(&s, .Enter)
	s.settings.master, s.settings.sound, s.settings.music = 0.25, 1, 0
	redraw(&s)
	testing.expect_value(t, quads_of(&s.list, kit.track, TRACK), 3 * 9)
	// The empty one has no fill; the others do.
	testing.expect_value(t, quads_of(&s.list, kit.track, TRACK_FILL), 2 * 9)
	_, master := row_of(&s, .Master)
	track := slider_rect(master)
	fill_right := f32(0)
	for v in s.list.vertices {
		if v.color == TRACK_FILL && v.pos.y >= master.pos.y && v.pos.y <= master.pos.y + master.size.y {
			fill_right = max(fill_right, v.pos.x)
		}
	}
	testing.expect(t, abs(fill_right - (track.pos.x + track.size.x * 0.25)) < 0.5)
}

@(test)
controls_screen_shows_the_bindings_in_hand :: proc(t: ^testing.T) {
	s: Stage
	defer virtual.arena_destroy(&s.arena)
	if !stage_init(t, &s) {
		return
	}
	tap(&s, .Escape)
	tap(&s, .Down)
	tap(&s, .Down)
	tap(&s, .Enter)
	redraw(&s)
	// W A S D for the four directions, plus W and S and A and D never
	// doubling up: each key shows once in its own row.
	for name in ([]string{"keyboard_w", "keyboard_a", "keyboard_s", "keyboard_d", "keyboard_tab", "keyboard_f5", "mouse_left", "mouse_right"}) {
		testing.expectf(t, shows_glyph(&s, .Keyboard_Mouse, name) == 1, "%s should show once", name)
	}
	// Space both flies up and swings, so it shows in two rows.
	testing.expect_value(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_space"), 2)
	testing.expect_value(t, shows_glyph(&s, .Xbox, "xbox_stick_l"), 0)

	// A row waiting for a press shows a prompt instead of its icons.
	index, _ := row_of(&s, .Bind, slot_index(.Toggle_Mode, 1))
	for s.menu.cursor != index {
		tap(&s, .Down)
	}
	tap(&s, .Enter)
	redraw(&s)
	testing.expect_value(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_tab"), 0)
	tap(&s, .Escape)

	// Pick up a pad: the same screen now lists the pad's bindings. The stick
	// that moves the cursor shows in all four direction rows.
	tap_pad(&s, .Dpad_Up)
	redraw(&s)
	testing.expect_value(t, shows_glyph(&s, .Xbox, "xbox_stick_l"), 4)
	testing.expect_value(t, shows_glyph(&s, .Xbox, "xbox_button_x"), 1)
	testing.expect_value(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_w"), 0)
	// Its menu hints follow too.
	testing.expect_value(t, shows_glyph(&s, .Xbox, "xbox_button_a"), 1)
	testing.expect_value(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_enter"), 0)
}

@(test)
settings_survive_a_round_trip :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	s := &r.settings
	s.master, s.sound, s.music = 0.35, 0.6, 0.05
	input.rebind(&s.bindings, {.Swing, 1}, {input.Key.F, 1})
	input.rebind(&s.bindings, {.Move_Forward, 1}, {input.Pad_Axis.Right_Y, -1})

	text, ok := settings_to_json(s, r.allocator)
	testing.expect(t, ok)
	// Written by name, so a person can read and edit it.
	testing.expect(t, strings.contains(text, `"Key.F"`) && strings.contains(text, `"Swing"`) && strings.contains(text, `"master"`))

	back, clean := settings_parse(transmute([]byte)text, r.allocator)
	testing.expect(t, clean)
	testing.expect_value(t, back.master, s.master)
	testing.expect_value(t, back.sound, s.sound)
	testing.expect_value(t, back.music, s.music)
	testing.expect_value(t, len(back.bindings), len(s.bindings))
	for b, i in s.bindings {
		testing.expect(t, back.bindings[i] == b) or_break
	}

	// Through a file as well.
	path := ROOT + "build/menu_test_settings.json"
	testing.expect(t, settings_save(path, s))
	loaded := settings_load(path, r.allocator)
	testing.expect_value(t, loaded.master, s.master)
	testing.expect_value(t, len(loaded.bindings), len(s.bindings))
	_ = os.remove(path)

	// No file yet: the defaults.
	fresh := settings_load(ROOT + "build/no_such_settings.json", r.allocator)
	defaults := settings_default(r.allocator)
	testing.expect_value(t, fresh.master, defaults.master)
	testing.expect_value(t, len(fresh.bindings), len(defaults.bindings))
}

@(test)
damaged_settings_fall_back_to_defaults :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	defaults := settings_default(r.allocator)

	// Not JSON at all.
	s, clean := settings_parse(transmute([]byte)string("{ volume: oops"), r.allocator)
	testing.expect(t, !clean)
	testing.expect_value(t, s.master, defaults.master)
	testing.expect_value(t, len(s.bindings), len(defaults.bindings))

	// Volumes out of range are pulled back in; a missing one keeps its default.
	s, clean = settings_parse(transmute([]byte)string(`{"volume": {"master": 7, "sound": -2}}`), r.allocator)
	testing.expect(t, clean)
	testing.expect_value(t, s.master, 1)
	testing.expect_value(t, s.sound, 0)
	testing.expect_value(t, s.music, defaults.music)
	testing.expect_value(t, len(s.bindings), len(defaults.bindings))

	// Bad entries are dropped and the rest kept: an unknown action, an
	// unknown control, a menu action, a reserved key and a zero scale.
	text := `{"bindings": [
		{"action": "Swing", "control": "Key.F", "scale": 1},
		{"action": "Dance", "control": "Key.G", "scale": 1},
		{"action": "Swing", "control": "Key.Banana", "scale": 1},
		{"action": "Menu_Confirm", "control": "Key.H", "scale": 1},
		{"action": "Swing", "control": "Key.Escape", "scale": 1},
		{"action": "Swing", "control": "Key.J", "scale": 0}
	]}`
	s, clean = settings_parse(transmute([]byte)text, r.allocator)
	testing.expect(t, !clean)
	testing.expect_value(t, len(s.bindings), 1)
	testing.expect(t, s.bindings[0] == input.Binding{.Swing, input.Key.F, 1})

	// A list with nothing usable in it is treated as damage: defaults again,
	// so the game is never left without controls.
	s, _ = settings_parse(transmute([]byte)string(`{"bindings": [{"action": "Dance", "control": "Key.G", "scale": 1}]}`), r.allocator)
	testing.expect_value(t, len(s.bindings), len(defaults.bindings))
	s, _ = settings_parse(transmute([]byte)string(`{"bindings": []}`), r.allocator)
	testing.expect_value(t, len(s.bindings), len(defaults.bindings))
}

// Every frame the menu says what it sounded like; the game plays that
// through the sound hooks.
@(test)
the_menu_is_heard :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	Sounds :: bit_set[dungeon.Sound_Kind]
	// What one press sounds like: the frame the key goes down. Letting go is silent.
	press :: proc(r: ^Rig, key: input.Key) -> Sounds {
		r.raw.keys[key] = true
		frame(r)
		heard := r.menu.sounds
		r.raw.keys[key] = false
		frame(r)
		return heard
	}

	// Silent while closed and untouched.
	frame(&r)
	testing.expect_value(t, r.menu.sounds, Sounds{})

	testing.expect_value(t, press(&r, .Escape), Sounds{.Menu_Open})
	frame(&r)
	testing.expect_value(t, r.menu.sounds, Sounds{}) // a sound lasts one frame

	testing.expect_value(t, press(&r, .Down), Sounds{.Menu_Move})
	testing.expect_value(t, press(&r, .Enter), Sounds{.Menu_Select}) // into Options
	testing.expect_value(t, r.menu.screen, Screen.Options)

	// A slider ticks when it moves and is silent at the end of its travel.
	r.settings.master = 0.9
	testing.expect_value(t, press(&r, .Right), Sounds{.Menu_Adjust})
	testing.expect_value(t, press(&r, .Right), Sounds{.Menu_Adjust})
	testing.expect_value(t, r.settings.master, 1)
	testing.expect_value(t, press(&r, .Right), Sounds{})

	testing.expect_value(t, press(&r, .Backspace), Sounds{.Menu_Back})
	testing.expect_value(t, r.menu.screen, Screen.Pause)

	// Rebinding: choosing a row, backing out of it, and binding it.
	press(&r, .Down)
	testing.expect_value(t, press(&r, .Enter), Sounds{.Menu_Select})
	testing.expect_value(t, r.menu.screen, Screen.Controls)
	testing.expect_value(t, press(&r, .Enter), Sounds{.Menu_Select})
	testing.expect(t, r.menu.capturing)
	testing.expect_value(t, press(&r, .Escape), Sounds{.Menu_Back})
	press(&r, .Enter)
	testing.expect_value(t, press(&r, .G), Sounds{.Menu_Bind})

	// The pointer coming to rest on another row ticks once, not every frame
	// it stays there.
	_, row := row_of(&r, .Bind, 5)
	r.pointer = centre(row)
	frame(&r, pointer_moved = true)
	testing.expect_value(t, r.menu.sounds, Sounds{.Menu_Move})
	frame(&r, pointer_moved = true)
	testing.expect_value(t, r.menu.sounds, Sounds{})

	// Resetting counts as a rebind; closing has its own sound.
	reset, _ := row_of(&r, .Reset)
	for r.menu.cursor != reset {
		press(&r, .Down)
	}
	testing.expect_value(t, press(&r, .Enter), Sounds{.Menu_Bind})
	testing.expect_value(t, press(&r, .Escape), Sounds{.Menu_Close})
	testing.expect(t, !is_open(&r.menu))

	// Resume closes too, and Quit is a selection.
	press(&r, .Escape)
	testing.expect_value(t, press(&r, .Enter), Sounds{.Menu_Close})
	press(&r, .Escape)
	press(&r, .Up)
	testing.expect_value(t, press(&r, .Enter), Sounds{.Menu_Select})

	// Only menu sounds ever come out of the menu.
	for kind in dungeon.Sound_Kind {
		#partial switch kind {
		case .Menu_Open, .Menu_Close, .Menu_Move, .Menu_Select, .Menu_Back, .Menu_Adjust, .Menu_Bind:
		case:
			testing.expect(t, kind not_in r.menu.sounds)
		}
	}
}
@(test)
game_over_screens_offer_a_way_on_but_not_back :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	labels :: proc(screen: Screen) -> [3]string {
		buffer: [MAX_ITEMS]Item
		rows := items(screen, &buffer)
		return {rows[0].label, rows[1].label, rows[2].label}
	}
	// After a defeat the first thing offered is another go at the same
	// dungeon; after a win, a new one.
	testing.expect_value(t, labels(.Lost), [3]string{"Try again", "New dungeon", "Main menu"})
	testing.expect_value(t, labels(.Won), [3]string{"New dungeon", "Play this dungeon again", "Main menu"})
	testing.expect_value(t, title(.Won), "Victory")
	testing.expect_value(t, title(.Lost), "Defeat")

	open_game_over(&r.menu, false, {"The knight has fallen.", "Rooms 3/30"})
	testing.expect(t, is_open(&r.menu) && is_game_over(&r.menu))
	testing.expect_value(t, r.menu.screen, Screen.Lost)
	testing.expect_value(t, r.menu.summary_count, 2)
	testing.expect_value(t, r.menu.cursor, 0)

	// There is no game to resume: Escape, Backspace and Start do nothing.
	testing.expect_value(t, tap(&r, .Escape), Events{})
	testing.expect_value(t, tap(&r, .Backspace), Events{})
	testing.expect_value(t, tap_pad(&r, .Start), Events{})
	testing.expect_value(t, tap_pad(&r, .East), Events{})
	testing.expect_value(t, r.menu.screen, Screen.Lost)

	// The rows can still be walked and chosen.
	tap(&r, .Down)
	testing.expect_value(t, r.menu.cursor, 1)
	testing.expect_value(t, tap(&r, .Enter), Events{.New_Dungeon})
	testing.expect(t, !is_open(&r.menu), "choosing a way on closes the screen")

	open_game_over(&r.menu, false, nil)
	testing.expect_value(t, tap(&r, .Enter), Events{.Retry})
	testing.expect(t, !is_open(&r.menu))

	open_game_over(&r.menu, true, {"The amulet is yours."})
	testing.expect_value(t, r.menu.screen, Screen.Won)
	testing.expect_value(t, tap(&r, .Enter), Events{.New_Dungeon})
	open_game_over(&r.menu, true, nil)
	tap(&r, .Down)
	testing.expect_value(t, tap(&r, .Enter), Events{.Retry})
	open_game_over(&r.menu, true, nil)
	tap(&r, .Up)
	testing.expect_value(t, tap(&r, .Enter), Events{.Quit})
	testing.expect(t, is_open(&r.menu), "quitting is the game's to act on")

	// With the pointer, too; the rows sit below however many summary lines there are.
	open_game_over(&r.menu, false, {"one", "two", "three"})
	l := layout(.Lost, SCREEN, 3)
	plain := layout(.Lost, SCREEN, 0)
	testing.expect(t, l.rows[0].pos.y - l.window.pos.y > plain.rows[0].pos.y - plain.window.pos.y + 2 * SUMMARY_LINE)
	testing.expect_value(t, click(&r, centre(l.rows[1])), Events{.New_Dungeon})

	// More lines than fit are cut off rather than overrun.
	open_game_over(&r.menu, true, {"1", "2", "3", "4", "5", "6"})
	testing.expect_value(t, r.menu.summary_count, MAX_SUMMARY)
}

@(test)
game_over_screens_show_how_it_went :: proc(t: ^testing.T) {
	s: Stage
	defer virtual.arena_destroy(&s.arena)
	if !stage_init(t, &s) {
		return
	}
	kit := &s.fonts.kit
	open_game_over(&s.menu, true, {"Zzz qqq", "Xxx"})
	frame(&s)
	redraw(&s)

	// The same kit-built window as every other screen.
	testing.expect_value(t, quads_of(&s.list, kit.window, WINDOW_FILL), 9)
	testing.expect_value(t, quads_of(&s.list, kit.window_border, WINDOW_FRAME), 9)
	testing.expect_value(t, quads_of(&s.list, kit.button_border, HIGHLIGHT_FRAME), 9)

	// Both summary lines are drawn, centred, between the title and the rows.
	l := layout(.Won, SCREEN, 2)
	z := s.fonts.text.glyphs['Z']
	x := s.fonts.text.glyphs['X']
	found_z, found_x := false, false
	for i := 0; i + 5 < len(s.list.vertices); i += 6 {
		v := s.list.vertices[i]
		if v.uv == z.uv_min || v.uv == x.uv_min {
			found_z ||= v.uv == z.uv_min
			found_x ||= v.uv == x.uv_min
			testing.expect(t, v.pos.y > l.window.pos.y + 60 && v.pos.y < l.rows[0].pos.y)
			testing.expect(t, v.pos.x > l.window.pos.x && v.pos.x < l.window.pos.x + l.window.size.x)
		}
	}
	testing.expect(t, found_z && found_x)
	for v in s.list.vertices {
		testing.expect(t, v.pos.x >= 0 && v.pos.x <= SCREEN.x && v.pos.y >= 0 && v.pos.y <= SCREEN.y) or_break
	}

	// Only "select" is offered at the bottom: there is nothing to go back to.
	testing.expect_value(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_enter"), 1)
	testing.expect_value(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_escape"), 0)

	// The window fits on small screens with a full summary.
	for size in ([][2]f32{{1600, 900}, {800, 500}, {640, 400}}) {
		small := layout(.Lost, size, MAX_SUMMARY)
		w := small.window
		testing.expect(t, w.pos.x >= 0 && w.pos.y >= 0 && w.pos.x + w.size.x <= size.x && w.pos.y + w.size.y <= size.y)
		testing.expect(t, small.rows[0].size.y > 8)
	}
}
@(test)
the_main_menu_starts_the_game :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	open_main(&r.menu, "Dungeon Solver")
	testing.expect(t, is_open(&r.menu) && in_main(&r.menu) && !is_game_over(&r.menu))
	testing.expect_value(t, r.menu.screen, Screen.Main)
	testing.expect_value(t, title(r.menu.screen, r.menu.game_title), "Dungeon Solver")

	buffer: [MAX_ITEMS]Item
	rows := items(.Main, &buffer)
	testing.expect_value(t, rows[0].label, "Start game")
	testing.expect_value(t, rows[len(rows) - 1].label, "Quit to desktop")
	testing.expect_value(t, r.menu.cursor, 0) // Start game is what Enter does first

	// There is no game to go back to yet: Escape, Backspace and Start stay put.
	testing.expect_value(t, tap(&r, .Escape), Events{})
	testing.expect_value(t, tap(&r, .Backspace), Events{})
	testing.expect_value(t, tap_pad(&r, .Start), Events{})
	testing.expect_value(t, r.menu.screen, Screen.Main)

	// Options and Controls are reachable from here, and lead back here, not
	// to the pause menu, whichever way one leaves them.
	tap(&r, .Down)
	tap(&r, .Enter)
	testing.expect_value(t, r.menu.screen, Screen.Options)
	testing.expect(t, in_main(&r.menu))
	testing.expect_value(t, tap(&r, .Right), Events{.Volume_Changed})
	testing.expect_value(t, tap(&r, .Backspace), Events{})
	testing.expect_value(t, r.menu.screen, Screen.Main)
	testing.expect_value(t, r.menu.cursor, 1)

	tap(&r, .Down)
	tap(&r, .Enter)
	testing.expect_value(t, r.menu.screen, Screen.Controls)
	// Escape, which would close a pause menu outright, only steps back.
	testing.expect_value(t, tap(&r, .Escape), Events{})
	testing.expect_value(t, r.menu.screen, Screen.Main)
	testing.expect_value(t, r.menu.cursor, 2)
	tap(&r, .Enter)
	_, back := row_of(&r, .Back)
	testing.expect_value(t, click(&r, centre(back)), Events{})
	testing.expect_value(t, r.menu.screen, Screen.Main)

	// Rebinding works from here as it does from the pause menu.
	tap(&r, .Enter)
	tap(&r, .Enter)
	testing.expect(t, r.menu.capturing)
	testing.expect_value(t, tap(&r, .K), Events{.Bindings_Changed})
	tap(&r, .Escape)
	testing.expect_value(t, r.menu.screen, Screen.Main)

	// Quit is reported; Start game closes the menu and says so.
	tap(&r, .Up)
	tap(&r, .Up)
	tap(&r, .Up)
	testing.expect_value(t, r.menu.cursor, 3)
	testing.expect_value(t, tap(&r, .Enter), Events{.Quit})
	_, start := row_of(&r, .Start)
	testing.expect_value(t, click(&r, centre(start)), Events{.Started})
	testing.expect(t, !is_open(&r.menu) && !in_main(&r.menu))
	testing.expect(t, .Menu_Select in r.menu.sounds || r.menu.sounds == {}) // heard on the frame it was chosen

	// Once playing, Escape opens the pause menu, not the main menu.
	testing.expect_value(t, tap(&r, .Escape), Events{.Opened})
	testing.expect_value(t, r.menu.screen, Screen.Pause)
	testing.expect(t, !in_main(&r.menu))
}

@(test)
the_way_back_to_the_main_menu :: proc(t: ^testing.T) {
	r: Rig
	defer virtual.arena_destroy(&r.arena)
	if !rig_init(t, &r) {
		return
	}
	// From the pause menu: reported, for the game to drop what is in progress.
	tap(&r, .Escape)
	index, _ := row_of(&r, .Main_Menu)
	testing.expect(t, index >= 0)
	for r.menu.cursor != index {
		tap(&r, .Down)
	}
	testing.expect_value(t, tap(&r, .Enter), Events{.Main_Menu})

	// From either game-over screen as well.
	for won in ([]bool{true, false}) {
		open_game_over(&r.menu, won, nil)
		index, _ = row_of(&r, .Main_Menu)
		for r.menu.cursor != index {
			tap(&r, .Down)
		}
		testing.expect_value(t, tap(&r, .Enter), Events{.Main_Menu})
	}
	// The main menu itself has no such row.
	open_main(&r.menu, "Game")
	index, _ = row_of(&r, .Main_Menu)
	testing.expect_value(t, index, -1)

	// Sub-screens of the pause menu still lead back to the pause menu.
	open(&r.menu)
	tap(&r, .Down)
	tap(&r, .Enter)
	testing.expect_value(t, r.menu.screen, Screen.Options)
	tap(&r, .Backspace)
	testing.expect_value(t, r.menu.screen, Screen.Pause)
}

@(test)
main_menu_is_drawn_under_the_games_name :: proc(t: ^testing.T) {
	s: Stage
	defer virtual.arena_destroy(&s.arena)
	if !stage_init(t, &s) {
		return
	}
	kit := &s.fonts.kit
	open_main(&s.menu, "Zzz")
	frame(&s)
	redraw(&s)

	testing.expect_value(t, quads_of(&s.list, kit.window, WINDOW_FILL), 9)
	testing.expect_value(t, quads_of(&s.list, kit.window_border, WINDOW_FRAME), 9)
	testing.expect_value(t, quads_of(&s.list, kit.button_border, HIGHLIGHT_FRAME), 9)
	testing.expect_value(t, quads_of(&s.list, kit.divider, WINDOW_FRAME), 4)

	// The game's name is the heading, above the rows.
	l := layout(.Main, SCREEN)
	q := s.fonts.text.glyphs['Z']
	found := false
	for i := 0; i + 5 < len(s.list.vertices); i += 6 {
		if s.list.vertices[i].uv == q.uv_min {
			found = true
			testing.expect(t, s.list.vertices[i].pos.y < l.rows[0].pos.y && s.list.vertices[i].pos.y > l.window.pos.y)
		}
	}
	testing.expect(t, found)
	// Select is offered; Back and Resume are not, there being nowhere to go.
	testing.expect_value(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_enter"), 1)
	testing.expect_value(t, shows_glyph(&s, .Keyboard_Mouse, "keyboard_escape"), 0)

	for size in ([][2]f32{{1600, 900}, {640, 400}}) {
		w := layout(.Main, size).window
		testing.expect(t, w.pos.x >= 0 && w.pos.y >= 0 && w.pos.x + w.size.x <= size.x && w.pos.y + w.size.y <= size.y)
	}
}