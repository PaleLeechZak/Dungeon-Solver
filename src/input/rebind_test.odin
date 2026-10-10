package input

import "core:testing"

@(test)
slots_show_the_right_bindings :: proc(t: ^testing.T) {
	bindings := default_bindings()
	glyphs: [8]Glyph

	// "Walk forward" and "walk back" are the two ends of one axis.
	forward, back := Slot{.Move_Forward, 1}, Slot{.Move_Forward, -1}
	n := slot_glyphs(bindings, forward, .Keyboard_Mouse, .Generic, glyphs[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, glyphs[0].name, "keyboard_w")
	n = slot_glyphs(bindings, back, .Keyboard_Mouse, .Generic, glyphs[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, glyphs[0].name, "keyboard_s")

	// On a pad one stick serves both, so it shows in both rows.
	n = slot_glyphs(bindings, forward, .Gamepad, .Xbox_One, glyphs[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, glyphs[0].name, "xbox_stick_l")
	n = slot_glyphs(bindings, back, .Gamepad, .Xbox_One, glyphs[:])
	testing.expect_value(t, glyphs[0].name, "xbox_stick_l")

	// Triggers are one-way, so each belongs to one row only.
	n = slot_glyphs(bindings, {.Fly_Up, 1}, .Gamepad, .Xbox_One, glyphs[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, glyphs[0].name, "xbox_rt")
	n = slot_glyphs(bindings, {.Fly_Up, -1}, .Gamepad, .Xbox_One, glyphs[:])
	testing.expect_value(t, glyphs[0].name, "xbox_lt")

	n = slot_glyphs(bindings, {.Swing, 1}, .Keyboard_Mouse, .Generic, glyphs[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, slot_glyphs(bindings, {.Reload_Config, 1}, .Gamepad, .PS5, glyphs[:]), 0)
}

@(test)
capture_takes_the_first_new_press :: proc(t: ^testing.T) {
	raw, previous: Raw

	_, ok := capture(&raw, &previous, .Keyboard_Mouse)
	testing.expect(t, !ok)

	// A key that was already held when the row started waiting does not count.
	raw.keys[.Enter] = true
	previous.keys[.Enter] = true
	_, ok = capture(&raw, &previous, .Keyboard_Mouse)
	testing.expect(t, !ok)

	raw.keys[.F] = true
	c: Capture
	c, ok = capture(&raw, &previous, .Keyboard_Mouse)
	testing.expect(t, ok)
	testing.expect_value(t, c, Capture{Key.F, 1})

	// Escape cancels, so it is never captured; a mouse button is fine.
	raw, previous = {}, {}
	raw.keys[.Escape] = true
	_, ok = capture(&raw, &previous, .Keyboard_Mouse)
	testing.expect(t, !ok)
	raw.mouse_buttons[.Middle] = true
	c, ok = capture(&raw, &previous, .Keyboard_Mouse)
	testing.expect(t, ok)
	testing.expect_value(t, c.control, Control(Mouse_Button.Middle))

	// Mouse travel and the wheel are not bindable.
	raw, previous = {}, {}
	raw.mouse_axes[.Move_X] = 40
	raw.mouse_axes[.Wheel] = 1
	raw.mouse_moved = true
	_, ok = capture(&raw, &previous, .Keyboard_Mouse)
	testing.expect(t, !ok)

	// Keyboard presses are ignored while a pad row is waiting, and the other way round.
	raw.keys[.G] = true
	_, ok = capture(&raw, &previous, .Gamepad)
	testing.expect(t, !ok)

	raw, previous = {pad_connected = true}, {pad_connected = true}
	raw.pad_buttons[.Start] = true
	_, ok = capture(&raw, &previous, .Gamepad)
	testing.expect(t, !ok, "Start is reserved for the menu")
	raw.pad_buttons[.East] = true
	c, ok = capture(&raw, &previous, .Gamepad)
	testing.expect(t, ok)
	testing.expect_value(t, c.control, Control(Pad_Button.East))

	// A stick has to be pushed properly, and the direction is remembered.
	raw, previous = {pad_connected = true}, {pad_connected = true}
	raw.pad_axes[.Right_Y] = -0.3
	_, ok = capture(&raw, &previous, .Gamepad)
	testing.expect(t, !ok)
	raw.pad_axes[.Right_Y] = -0.95
	c, ok = capture(&raw, &previous, .Gamepad)
	testing.expect(t, ok)
	testing.expect_value(t, c, Capture{Pad_Axis.Right_Y, -1})
	// Still held next frame: not a new press.
	previous = raw
	_, ok = capture(&raw, &previous, .Gamepad)
	testing.expect(t, !ok)
}

@(test)
rebinding_replaces_one_row_on_one_device :: proc(t: ^testing.T) {
	bindings := bindings_clone(default_bindings(), context.temp_allocator)
	glyphs: [8]Glyph
	s := State {
		bindings = bindings[:],
		fixed    = fixed_bindings(),
	}
	press :: proc(s: ^State, bindings: ^[dynamic]Binding, key: Key) -> ^State {
		s.bindings = bindings[:]
		raw: Raw
		raw.keys[key] = true
		update(s, &raw, 0.016)
		return s
	}

	// Swing on F instead of the mouse button and space.
	rebind(&bindings, {.Swing, 1}, {Key.F, 1})
	n := slot_glyphs(bindings[:], {.Swing, 1}, .Keyboard_Mouse, .Generic, glyphs[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, glyphs[0].name, "keyboard_f")
	testing.expect(t, press(&s, &bindings, .F).down[.Swing])
	testing.expect(t, !press(&s, &bindings, .Space).down[.Swing])
	// The pad's swing buttons were not touched...
	testing.expect_value(t, slot_glyphs(bindings[:], {.Swing, 1}, .Gamepad, .Xbox_One, glyphs[:]), 2)
	// ...and space still flies up: that is a different row.
	testing.expect_value(t, press(&s, &bindings, .Space).value[.Fly_Up], 1)

	// One end of an axis moves without the other.
	rebind(&bindings, {.Move_Forward, 1}, {Key.Up, 1})
	testing.expect_value(t, press(&s, &bindings, .Up).value[.Move_Forward], 1)
	testing.expect_value(t, press(&s, &bindings, .W).value[.Move_Forward], 0)
	testing.expect_value(t, press(&s, &bindings, .S).value[.Move_Forward], -1)
	rebind(&bindings, {.Move_Forward, -1}, {Key.Down, 1})
	testing.expect_value(t, press(&s, &bindings, .Down).value[.Move_Forward], -1)
	testing.expect_value(t, press(&s, &bindings, .S).value[.Move_Forward], 0)

	// A stick pushed up for "forward" goes forward when pushed up, whatever
	// sign that axis happens to report, and back when pulled down.
	stick :: proc(s: ^State, bindings: ^[dynamic]Binding, axis: Pad_Axis, value: f32) -> ^State {
		s.bindings = bindings[:]
		raw := Raw {
			pad_connected = true,
		}
		raw.pad_axes[axis] = value
		update(s, &raw, 0.016)
		return s
	}
	rebind(&bindings, {.Move_Forward, 1}, {Pad_Axis.Right_Y, -1})
	testing.expect_value(t, stick(&s, &bindings, .Right_Y, -1).value[.Move_Forward], 1)
	testing.expect_value(t, stick(&s, &bindings, .Right_Y, 1).value[.Move_Forward], -1)
	testing.expect_value(t, stick(&s, &bindings, .Left_Y, -1).value[.Move_Forward], 0) // the old stick let go
	// Bound by pulling down for "back" gives the very same binding.
	rebind(&bindings, {.Move_Forward, -1}, {Pad_Axis.Left_Y, 1})
	testing.expect_value(t, stick(&s, &bindings, .Left_Y, -1).value[.Move_Forward], 1)
	testing.expect_value(t, stick(&s, &bindings, .Left_Y, 1).value[.Move_Forward], -1)

	// A button action can sit on a stick direction or a trigger.
	rebind(&bindings, {.Swing, 1}, {Pad_Axis.Right_Trigger, 1})
	testing.expect(t, stick(&s, &bindings, .Right_Trigger, 1).down[.Swing])
	rebind(&bindings, {.Toggle_Mode, 1}, {Pad_Axis.Right_X, -1})
	testing.expect(t, stick(&s, &bindings, .Right_X, -1).down[.Toggle_Mode])
	testing.expect(t, !stick(&s, &bindings, .Right_X, 1).down[.Toggle_Mode], "only the direction that was bound")

	// The defaults themselves were never touched.
	testing.expect_value(t, slot_glyphs(default_bindings(), {.Swing, 1}, .Keyboard_Mouse, .Generic, glyphs[:]), 2)
}

@(test)
menus_can_always_be_reached :: proc(t: ^testing.T) {
	// Whatever the player does to the gameplay bindings, the menu keys work.
	empty: [dynamic]Binding
	s := State {
		bindings = empty[:],
		fixed    = fixed_bindings(),
	}
	raw: Raw
	raw.keys[.Escape] = true
	update(&s, &raw, 0.016)
	testing.expect(t, s.pressed[.Pause] && s.pressed[.Menu_Back])

	raw = {}
	raw.keys[.Down] = true
	update(&s, &raw, 0.016)
	testing.expect(t, s.pressed[.Menu_Down] && !s.down[.Menu_Up])

	// The left stick steers the menu too, each way its own action.
	raw = {pad_connected = true}
	raw.pad_axes[.Left_Y] = -1
	update(&s, &raw, 0.016)
	testing.expect(t, s.down[.Menu_Up] && !s.down[.Menu_Down])
	raw.pad_axes[.Left_Y] = 1
	update(&s, &raw, 0.016)
	testing.expect(t, s.down[.Menu_Down] && !s.down[.Menu_Up])
	raw = {pad_connected = true}
	raw.pad_buttons[.Start] = true
	update(&s, &raw, 0.016)
	testing.expect(t, s.pressed[.Pause])

	// None of the fixed bindings is something a row can be rebound to steal.
	for b in fixed_bindings() {
		#partial switch b.action {
		case .Pause:
			testing.expect(t, control_reserved(b.control))
		}
	}
	// And nothing in the gameplay defaults sits on a reserved control.
	for b in default_bindings() {
		testing.expectf(t, !control_reserved(b.control), "%v is bound to a reserved control", b.action)
	}
}

@(test)
controls_survive_being_written_down :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, c: Control) {
		name := control_name(c, context.temp_allocator)
		back, ok := control_parse(name)
		testing.expectf(t, ok && back == c, "%s did not survive the round trip", name)
	}
	for v in Key do check(t, v)
	for v in Mouse_Button do check(t, v)
	for v in Mouse_Axis do check(t, v)
	for v in Pad_Button do check(t, v)
	for v in Pad_Axis do check(t, v)
	testing.expect_value(t, control_name(Key.W, context.temp_allocator), "Key.W")
	testing.expect_value(t, control_name(Pad_Axis.Left_X, context.temp_allocator), "Pad_Axis.Left_X")

	for text in ([]string{"", "W", "Key.", "Key.Nope", "Pedal.Left", "Pad_Button.W"}) {
		_, ok := control_parse(text)
		testing.expectf(t, !ok, "'%s' should not parse", text)
	}
	for a in Action {
		back, ok := action_parse(action_name(a, context.temp_allocator))
		testing.expect(t, ok && back == a)
	}
	_, ok := action_parse("Dance")
	testing.expect(t, !ok)
}