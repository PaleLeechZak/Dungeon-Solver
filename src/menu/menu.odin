// The pause menu and its two sub-screens: options (mixer volumes) and
// controls (rebinding). Pure state and layout: it reads an input.State, edits
// a Settings and appends to a ui.Draw_List. Everything on screen is built
// from the UI kit pieces in hud.Kit.
package menu

import "core:fmt"
import "core:math"

import "../dungeon"
import "../hud"
import "../input"
import "../ui"

Screen :: enum u8 {
	Closed,
	Pause,
	Options,
	Controls,
	// The two ways a game ends. Unlike the pause menu these cannot be
	// dismissed: the only ways out are a new game or the desktop.
	Won,
	Lost,
	// What the game opens on. It cannot be dismissed either: the way out is
	// to start playing.
	Main,
}

Item_Id :: enum u8 {
	Resume,
	Options,
	Controls,
	Quit,
	Master,
	Sound,
	Music,
	Bind, // one row of the controls screen; see Item.slot
	Reset,
	Back,
	New_Dungeon,
	Retry, // the same dungeon again
	Start,
	Main_Menu,
}

Item :: struct {
	id:    Item_Id,
	label: string,
	slot:  int, // index into SLOTS for .Bind
}

// A row of the controls screen.
Slot_Row :: struct {
	label: string,
	slot:  input.Slot,
}

SLOTS := [?]Slot_Row {
	{"Forward", {.Move_Forward, 1}},
	{"Back", {.Move_Forward, -1}},
	{"Left", {.Move_Right, -1}},
	{"Right", {.Move_Right, 1}},
	{"Fly up", {.Fly_Up, 1}},
	{"Fly down", {.Fly_Up, -1}},
	{"Hold to look around", {.Look_Hold, 1}},
	{"Fly faster", {.Fast, 1}},
	{"Swing sword", {.Swing, 1}},
	{"Knight / free flight", {.Toggle_Mode, 1}},
	{"Back to entrance", {.Reset_Camera, 1}},
	{"New dungeon", {.Regenerate, 1}},
	{"Reload config", {.Reload_Config, 1}},
}

MAX_ITEMS :: len(SLOTS) + 2

Event :: enum u8 {
	Opened,
	Resumed,
	Quit,
	Volume_Changed,
	Bindings_Changed,
	New_Dungeon,
	Retry,
	Started, // "Start game" was chosen on the main menu
	Main_Menu, // back to the main menu, abandoning the game in progress
}
Events :: bit_set[Event]

Menu :: struct {
	screen:    Screen,
	cursor:    int, // highlighted row
	capturing: bool, // the highlighted controls row is waiting for a press
	hold:      f32, // seconds left/right has been held on a slider
	was_down:  bool, // pointer button last frame
	dragging:  bool, // the pointer went down on a slider and has not let go
	// What the last update should sound like: Menu_* kinds only. The game
	// plays them through the same hooks as everything else.
	sounds:    bit_set[dungeon.Sound_Kind],
	// What a game-over screen says under its title. The strings belong to
	// whoever opened the screen and have to outlive it.
	summary:       [MAX_SUMMARY]string,
	summary_count: int,
	// Where Options and Controls lead back to: the pause menu, or the main
	// menu when they were opened from there.
	root:          Screen,
	game_title:    string, // heading of the main menu; has to outlive it
}

MAX_SUMMARY :: 4
SUMMARY_LINE :: 32 // pixels per summary line

// Everything the menu needs to know about one frame.
Frame :: struct {
	state:         ^input.State,
	raw, previous: ^input.Raw,
	pointer:       [2]f32, // pixels
	pointer_moved: bool,
	pointer_down:  bool,
	screen:        [2]f32,
	dt:            f32,
}

Rect :: struct {
	pos, size: [2]f32,
}

rect_contains :: proc(r: Rect, p: [2]f32) -> bool {
	return p.x >= r.pos.x && p.y >= r.pos.y && p.x < r.pos.x + r.size.x && p.y < r.pos.y + r.size.y
}

is_open :: proc(m: ^Menu) -> bool {
	return m.screen != .Closed
}

open :: proc(m: ^Menu) {
	m^ = {
		screen = .Pause,
		root   = .Pause,
	}
}

// Opens the main menu, headed with the game's name.
open_main :: proc(m: ^Menu, game_title: string) {
	m^ = {
		screen     = .Main,
		root       = .Main,
		game_title = game_title,
	}
}

// Whether the menu on screen is the main menu or one of its sub-screens,
// i.e. no game is in progress behind it.
in_main :: proc(m: ^Menu) -> bool {
	return m.screen != .Closed && m.root == .Main
}

close :: proc(m: ^Menu) {
	m^ = {}
}

// Opens the screen that ends a game, with a few lines about how it went.
open_game_over :: proc(m: ^Menu, won: bool, summary: []string) {
	m^ = {
		screen = won ? .Won : .Lost,
	}
	m.summary_count = min(len(summary), MAX_SUMMARY)
	copy(m.summary[:], summary[:m.summary_count])
}

is_game_over :: proc(m: ^Menu) -> bool {
	return m.screen == .Won || m.screen == .Lost
}

// The rows of a screen, top to bottom.
items :: proc(screen: Screen, buffer: ^[MAX_ITEMS]Item) -> []Item {
	n := 0
	add :: proc(buffer: ^[MAX_ITEMS]Item, n: ^int, item: Item) {
		buffer[n^] = item
		n^ += 1
	}
	switch screen {
	case .Closed:
	case .Pause:
		add(buffer, &n, {id = .Resume, label = "Resume"})
		add(buffer, &n, {id = .Options, label = "Options"})
		add(buffer, &n, {id = .Controls, label = "Controls"})
		add(buffer, &n, {id = .Main_Menu, label = "Main menu"})
		add(buffer, &n, {id = .Quit, label = "Quit to desktop"})
	case .Main:
		add(buffer, &n, {id = .Start, label = "Start game"})
		add(buffer, &n, {id = .Options, label = "Options"})
		add(buffer, &n, {id = .Controls, label = "Controls"})
		add(buffer, &n, {id = .Quit, label = "Quit to desktop"})
	case .Options:
		add(buffer, &n, {id = .Master, label = "Master volume"})
		add(buffer, &n, {id = .Sound, label = "Sound volume"})
		add(buffer, &n, {id = .Music, label = "Music volume"})
		add(buffer, &n, {id = .Back, label = "Back"})
	case .Controls:
		for row, i in SLOTS {
			add(buffer, &n, {id = .Bind, label = row.label, slot = i})
		}
		add(buffer, &n, {id = .Reset, label = "Reset to defaults"})
		add(buffer, &n, {id = .Back, label = "Back"})
	case .Won:
		add(buffer, &n, {id = .New_Dungeon, label = "New dungeon"})
		add(buffer, &n, {id = .Retry, label = "Play this dungeon again"})
		add(buffer, &n, {id = .Main_Menu, label = "Main menu"})
		add(buffer, &n, {id = .Quit, label = "Quit to desktop"})
	case .Lost:
		add(buffer, &n, {id = .Retry, label = "Try again"})
		add(buffer, &n, {id = .New_Dungeon, label = "New dungeon"})
		add(buffer, &n, {id = .Main_Menu, label = "Main menu"})
		add(buffer, &n, {id = .Quit, label = "Quit to desktop"})
	}
	return buffer[:n]
}

title :: proc(screen: Screen, game_title := "") -> string {
	switch screen {
	case .Main:
		return game_title
	case .Closed:
	case .Pause:
		return "Paused"
	case .Options:
		return "Options"
	case .Controls:
		return "Controls"
	case .Won:
		return "Victory"
	case .Lost:
		return "Defeat"
	}
	return ""
}

HEADER :: 104 // window top to first row
FOOTER :: 76 // last row to window bottom, with room for the key hints
ROW_HEIGHT :: 46
ROW_INSET :: 36 // window edge to row edge
ROW_FRAME_SCALE :: 0.5 // rows and sliders are slimmer than a window, so their frames are drawn smaller
TRACK_FRAME_SCALE :: 0.2
VOLUME_STEP :: 0.05
REPEAT_DELAY :: 0.35 // seconds a direction is held before it repeats
REPEAT_RATE :: 14 // steps per second after that

Layout :: struct {
	window: Rect,
	rows:   [MAX_ITEMS]Rect,
	count:  int,
}

// Where a screen's window and rows go. Shared by drawing and by the pointer,
// so what is clicked is always what is seen.
layout :: proc(screen: Screen, screen_size: [2]f32, summary_lines := 0) -> (l: Layout) {
	buffer: [MAX_ITEMS]Item
	l.count = len(items(screen, &buffer))
	width: f32
	subheader: f32
	switch screen {
	case .Closed:
		return
	case .Pause, .Main:
		width = 460
	case .Options:
		width = 700
	case .Controls:
		width = 780
		subheader = 40
	case .Won, .Lost:
		width = 640
		subheader = f32(summary_lines) * SUMMARY_LINE + 16
	}
	width = min(width, screen_size.x - 32)
	// A long screen on a small window squeezes its rows rather than run off it.
	row := min(f32(ROW_HEIGHT), (screen_size.y - 32 - HEADER - subheader - FOOTER) / f32(l.count))
	height := HEADER + subheader + row * f32(l.count) + FOOTER
	l.window = {{math.round((screen_size.x - width) / 2), math.round((screen_size.y - height) / 2)}, {width, height}}
	for i in 0 ..< l.count {
		l.rows[i] = {
			{l.window.pos.x + ROW_INSET, l.window.pos.y + HEADER + subheader + row * f32(i)},
			{width - 2 * ROW_INSET, row},
		}
	}
	return
}

// The part of a volume row that is the slider itself.
slider_rect :: proc(row: Rect) -> Rect {
	left := row.pos.x + row.size.x * 0.44
	right := row.pos.x + row.size.x - 96
	return {{left, row.pos.y + (row.size.y - 16) / 2}, {max(right - left, 1), 16}}
}

@(private)
volume_of :: proc(s: ^Settings, id: Item_Id) -> ^f32 {
	#partial switch id {
	case .Master:
		return &s.master
	case .Sound:
		return &s.sound
	case .Music:
		return &s.music
	}
	return nil
}

@(private)
go_to :: proc(m: ^Menu, screen: Screen, from: Item_Id) {
	// "Back to the pause menu" means back to wherever this menu started.
	screen := screen
	if screen == .Pause {
		screen = m.root
	}
	m.screen = screen
	m.cursor = 0
	m.capturing = false
	m.dragging = false
	// Coming back to the pause menu, the cursor returns to where it left from.
	buffer: [MAX_ITEMS]Item
	for item, i in items(screen, &buffer) {
		if item.id == from {
			m.cursor = i
			break
		}
	}
}

// Advances the menu by one frame. Does nothing but watch for Pause while
// closed. Returns what happened that the game has to act on.
update :: proc(m: ^Menu, s: ^Settings, f: Frame) -> (events: Events) {
	in_state := f.state
	clicked := f.pointer_down && !m.was_down
	defer m.was_down = f.pointer_down
	m.sounds = {}

	if m.screen == .Closed {
		if in_state.pressed[.Pause] {
			open(m)
			m.sounds = {.Menu_Open}
			events += {.Opened}
		}
		return
	}

	buffer: [MAX_ITEMS]Item
	rows := items(m.screen, &buffer)
	l := layout(m.screen, f.screen, m.summary_count)
	m.cursor = clamp(m.cursor, 0, len(rows) - 1)

	// However the highlight ends up on another row of this screen, by key,
	// stick or pointer, it ticks.
	screen_before, cursor_before := m.screen, m.cursor
	defer if m.screen == screen_before && m.cursor != cursor_before {
		m.sounds += {.Menu_Move}
	}

	if m.capturing {
		// A reserved control (Escape, Start) backs out; anything else on the
		// device in hand becomes the row's new binding.
		cancel := f.raw.keys[.Escape] && !f.previous.keys[.Escape]
		cancel ||= f.raw.pad_connected && f.raw.pad_buttons[.Start] && !f.previous.pad_buttons[.Start]
		if cancel {
			m.capturing = false
			m.sounds += {.Menu_Back}
		} else if captured, ok := input.capture(f.raw, f.previous, in_state.source); ok {
			input.rebind(&s.bindings, SLOTS[rows[m.cursor].slot].slot, captured)
			m.capturing = false
			m.sounds += {.Menu_Bind}
			events += {.Bindings_Changed}
		}
		return
	}

	// The pointer highlights what it is over.
	hovered := -1
	for row, i in l.rows[:l.count] {
		if rect_contains(row, f.pointer) {
			hovered = i
		}
	}
	if hovered >= 0 && (f.pointer_moved || clicked) {
		m.cursor = hovered
	}
	if in_state.pressed[.Menu_Down] {
		m.cursor = (m.cursor + 1) % len(rows)
	}
	if in_state.pressed[.Menu_Up] {
		m.cursor = (m.cursor + len(rows) - 1) % len(rows)
	}

	// Pause toggles the whole menu; Back climbs one level. A finished game
	// has nothing to go back to, so neither does anything there.
	// The main menu has no game behind it either, and from its sub-screens
	// Pause simply goes back, like Back does.
	if is_game_over(m) || m.screen == .Main {
		// fall through to the rows
	} else if m.root == .Main && (in_state.pressed[.Pause] || in_state.pressed[.Menu_Back]) {
		go_to(m, .Main, m.screen == .Options ? .Options : .Controls)
		m.sounds += {.Menu_Back}
		return
	} else if in_state.pressed[.Pause] || (in_state.pressed[.Menu_Back] && m.screen == .Pause) {
		close(m)
		m.sounds = {.Menu_Close}
		return {.Resumed}
	} else if in_state.pressed[.Menu_Back] {
		go_to(m, .Pause, m.screen == .Options ? .Options : .Controls)
		m.sounds += {.Menu_Back}
		return
	}

	item := rows[m.cursor]
	activated := in_state.pressed[.Menu_Confirm] || (clicked && hovered == m.cursor)

	if volume := volume_of(s, item.id); volume != nil {
		before := volume^
		// Left and right nudge; held, they keep going.
		direction := f32(int(in_state.down[.Menu_Right])) - f32(int(in_state.down[.Menu_Left]))
		if direction != 0 {
			first := in_state.pressed[.Menu_Right] || in_state.pressed[.Menu_Left]
			previous := m.hold
			m.hold += f.dt
			steps := 0
			if first {
				steps = 1
				m.hold = 0
			} else if m.hold >= REPEAT_DELAY {
				steps = int((m.hold - REPEAT_DELAY) * REPEAT_RATE) - int(max(previous - REPEAT_DELAY, 0) * REPEAT_RATE)
				steps += int(previous < REPEAT_DELAY)
			}
			volume^ += direction * VOLUME_STEP * f32(steps)
		} else {
			m.hold = 0
		}
		// Clicking or dragging on the slider sets it outright.
		track := slider_rect(l.rows[m.cursor])
		grab := Rect{track.pos - {8, 12}, track.size + {16, 24}}
		if clicked && rect_contains(grab, f.pointer) {
			m.dragging = true
		}
		if !f.pointer_down {
			m.dragging = false
		}
		if m.dragging {
			volume^ = (f.pointer.x - track.pos.x) / track.size.x
		}
		// Whole steps only, so the number shown is the number stored.
		volume^ = clamp(math.round(volume^ / VOLUME_STEP) * VOLUME_STEP, 0, 1)
		if volume^ != before {
			m.sounds += {.Menu_Adjust}
			events += {.Volume_Changed}
		}
		return
	}
	m.dragging = false
	m.hold = 0

	if !activated {
		return
	}
	switch item.id {
	case .Resume:
		close(m)
		m.sounds = {.Menu_Close}
		events += {.Resumed}
	case .Start:
		close(m)
		m.sounds = {.Menu_Select}
		events += {.Started}
	case .Main_Menu:
		m.sounds += {.Menu_Select}
		events += {.Main_Menu}
	case .Options:
		go_to(m, .Options, .Master)
		m.sounds += {.Menu_Select}
	case .Controls:
		go_to(m, .Controls, .Bind)
		m.sounds += {.Menu_Select}
	case .Quit:
		m.sounds += {.Menu_Select}
		events += {.Quit}
	case .Back:
		go_to(m, .Pause, m.screen == .Options ? .Options : .Controls)
		m.sounds += {.Menu_Back}
	case .Bind:
		m.capturing = true
		m.sounds += {.Menu_Select}
	case .Reset:
		clear(&s.bindings)
		append(&s.bindings, ..input.default_bindings())
		m.sounds += {.Menu_Bind}
		events += {.Bindings_Changed}
	case .New_Dungeon:
		close(m)
		m.sounds = {.Menu_Select}
		events += {.New_Dungeon}
	case .Retry:
		close(m)
		m.sounds = {.Menu_Select}
		events += {.Retry}
	case .Master, .Sound, .Music:
	}
	return
}

DIM :: ui.Color{0, 0, 0, 0.6}
WINDOW_FILL :: ui.Color{0.07, 0.07, 0.11, 0.97}
WINDOW_FRAME :: ui.Color{0.80, 0.74, 0.58, 1}
HIGHLIGHT_FILL :: ui.Color{1, 1, 1, 0.09}
HIGHLIGHT_FRAME :: ui.Color{1.0, 0.86, 0.45, 1}
TRACK :: ui.Color{0.22, 0.22, 0.28, 1}
TRACK_FILL :: ui.Color{0.95, 0.78, 0.35, 1}
TEXT :: ui.Color{0.96, 0.93, 0.86, 1}
TEXT_DIM :: ui.Color{0.66, 0.64, 0.60, 1}

// Draws the open screen over whatever is already in the list.
draw :: proc(list: ^ui.Draw_List, fonts: ^hud.Fonts, m: ^Menu, s: ^Settings, in_state: ^input.State, screen_size: [2]f32) {
	if m.screen == .Closed {
		return
	}
	kit := &fonts.kit
	font := &fonts.text
	line := ui.line_height(font)
	buffer: [MAX_ITEMS]Item
	rows := items(m.screen, &buffer)
	l := layout(m.screen, screen_size, m.summary_count)
	w := l.window

	ui.draw_rect(list, {0, 0}, screen_size, DIM)
	ui.draw_nine_slice(list, kit.window, kit.margin, w.pos, w.size, WINDOW_FILL)
	ui.draw_nine_slice(list, kit.window_border, kit.margin, w.pos, w.size, WINDOW_FRAME)

	// Title, with a rule running out to an ornament on either side below it.
	heading := title(m.screen, m.game_title)
	ui.draw_text(list, font, heading, {w.pos.x + (w.size.x - ui.measure_text(font, heading)) / 2, w.pos.y + 30}, TEXT)
	half := (w.size.x - 2 * ROW_INSET) / 2
	rule_y := w.pos.y + 30 + line + 4
	ui.draw_divider(list, kit.divider, kit.divider_cap, {w.pos.x + ROW_INSET, rule_y}, half, WINDOW_FRAME, flip_x = true)
	ui.draw_divider(list, kit.divider, kit.divider_cap, {w.pos.x + ROW_INSET + half, rule_y}, half, WINDOW_FRAME)

	if m.screen == .Controls {
		note := fmt.tprintf("Bindings for %s. Touch another device to edit its bindings.", input.source_name(in_state))
		ui.draw_text(list, font, note, {w.pos.x + (w.size.x - ui.measure_text(font, note)) / 2, w.pos.y + HEADER}, TEXT_DIM)
	}

	// How the game went, under the title of a game-over screen.
	for text, i in m.summary[:m.summary_count] {
		pos := [2]f32{w.pos.x + (w.size.x - ui.measure_text(font, text)) / 2, w.pos.y + HEADER + f32(i) * SUMMARY_LINE}
		ui.draw_text(list, font, text, pos, TEXT)
	}

	glyphs: [8]input.Glyph
	for item, i in rows {
		row := l.rows[i]
		focused := i == m.cursor
		if focused {
			ui.draw_nine_slice(list, kit.button, kit.margin, row.pos, row.size, HIGHLIGHT_FILL, ROW_FRAME_SCALE)
			ui.draw_nine_slice(list, kit.button_border, kit.margin, row.pos, row.size, HIGHLIGHT_FRAME, ROW_FRAME_SCALE)
		}
		color := focused ? TEXT : TEXT_DIM
		text_y := row.pos.y + (row.size.y - line) / 2
		icon := min(fonts.icon_size, row.size.y - 4)
		icon_y := row.pos.y + (row.size.y - icon) / 2

		if volume := volume_of(s, item.id); volume != nil {
			ui.draw_text(list, font, item.label, {row.pos.x + 24, text_y}, color)
			track := slider_rect(row)
			ui.draw_nine_slice(list, kit.track, kit.margin, track.pos, track.size, TRACK, TRACK_FRAME_SCALE)
			ui.draw_nine_slice(list, kit.track, kit.margin, track.pos, {track.size.x * volume^, track.size.y}, TRACK_FILL, TRACK_FRAME_SCALE)
			percent := fmt.tprintf("%d%%", int(math.round(volume^ * 100)))
			ui.draw_text(list, font, percent, {row.pos.x + row.size.x - 24 - ui.measure_text(font, percent), text_y}, color)
			continue
		}
		if item.id != .Bind {
			// Plain buttons are centred.
			ui.draw_text(list, font, item.label, {row.pos.x + (row.size.x - ui.measure_text(font, item.label)) / 2, text_y}, color)
			continue
		}

		// A binding row: what it does on the left, what it is bound to on the right.
		ui.draw_text(list, font, item.label, {row.pos.x + 24, text_y}, color)
		right := row.pos.x + row.size.x - 24
		if focused && m.capturing {
			prompt := in_state.source == .Gamepad ? "Press a button..." : "Press a key..."
			ui.draw_text(list, font, prompt, {right - ui.measure_text(font, prompt), text_y}, HIGHLIGHT_FRAME)
			continue
		}
		count := input.slot_glyphs(s.bindings[:], SLOTS[item.slot].slot, in_state.source, in_state.pad_type, glyphs[:])
		if count == 0 {
			unbound := "unbound"
			ui.draw_text(list, font, unbound, {right - ui.measure_text(font, unbound), text_y}, TEXT_DIM)
			continue
		}
		// Laid out right to left so the icons end flush with the row.
		#reverse for glyph in glyphs[:count] {
			r, known := hud.icon_rune(fonts, glyph)
			if !known {
				continue
			}
			width := fonts.icons[glyph.font].glyphs[r].size.x
			right -= width
			ui.draw_icon(list, &fonts.icons[glyph.font], r, {right, icon_y}, icon, color)
			right -= 4
		}
	}

	// How to work the menu, with the icons of the device in hand.
	hints := [?]struct {
		action: input.Action,
		label:  string,
	}{{.Menu_Confirm, m.capturing ? "" : "Select"}, {.Menu_Back, m.capturing || is_game_over(m) || m.screen == .Main ? "" : "Back"}, {.Pause, m.capturing ? "Cancel" : is_game_over(m) || m.root == .Main ? "" : "Resume"}}
	x := w.pos.x + ROW_INSET
	y := w.pos.y + w.size.y - 30 - fonts.icon_size
	for hint in hints {
		if hint.label == "" {
			continue
		}
		// One icon each is enough here.
		if input.action_glyphs(in_state, {hint.action}, glyphs[:1]) == 0 {
			continue
		}
		if r, known := hud.icon_rune(fonts, glyphs[0]); known {
			x += ui.draw_icon(list, &fonts.icons[glyphs[0].font], r, {x, y}, fonts.icon_size, TEXT_DIM) + 6
		}
		x += ui.draw_text(list, font, hint.label, {x, y + (fonts.icon_size - line) / 2}, TEXT_DIM) + 28
	}
}
