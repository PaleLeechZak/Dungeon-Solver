package input

import "core:testing"

@(private = "file")
fresh :: proc() -> State {
	return {bindings = default_bindings(), fixed = fixed_bindings()}
}

@(test)
keys_drive_axes_and_cancel_out :: proc(t: ^testing.T) {
	s := fresh()
	raw: Raw

	raw.keys[.W] = true
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.value[.Move_Forward], 1)
	testing.expect_value(t, s.value[.Move_Right], 0)

	raw.keys[.A] = true
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.value[.Move_Right], -1)

	// Opposite keys cancel; two keys for the same way do not add up past 1.
	raw.keys[.S] = true
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.value[.Move_Forward], 0)
	raw = {}
	raw.keys[.E] = true
	raw.keys[.Space] = true
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.value[.Fly_Up], 1)
}

@(test)
buttons_report_press_and_release_once :: proc(t: ^testing.T) {
	s := fresh()
	raw: Raw

	update(&s, &raw, 0.016)
	testing.expect(t, !s.down[.Swing] && !s.pressed[.Swing])

	raw.mouse_buttons[.Left] = true
	update(&s, &raw, 0.016)
	testing.expect(t, s.down[.Swing] && s.pressed[.Swing] && !s.released[.Swing])
	update(&s, &raw, 0.016)
	testing.expect(t, s.down[.Swing] && !s.pressed[.Swing], "holding is not pressing again")

	// A second control for the same action keeps it down without a new press.
	raw.keys[.Space] = true
	raw.mouse_buttons[.Left] = false
	update(&s, &raw, 0.016)
	testing.expect(t, s.down[.Swing] && !s.pressed[.Swing] && !s.released[.Swing])

	raw.keys[.Space] = false
	update(&s, &raw, 0.016)
	testing.expect(t, !s.down[.Swing] && s.released[.Swing])
	update(&s, &raw, 0.016)
	testing.expect(t, !s.released[.Swing])
}

@(test)
mouse_deltas_pass_through_and_sticks_scale_with_time :: proc(t: ^testing.T) {
	s := fresh()
	raw: Raw
	raw.mouse_axes[.Move_X] = 12
	raw.mouse_axes[.Move_Y] = -5
	raw.mouse_axes[.Wheel] = 2

	// However long the frame was, the mouse moved what it moved.
	update(&s, &raw, 0.5)
	testing.expect_value(t, s.value[.Look_X], 12)
	testing.expect_value(t, s.value[.Look_Y], -5)
	testing.expect_value(t, s.value[.Zoom], 2)

	// A stick held over is a rate: twice the time, twice the turn.
	raw = {pad_connected = true}
	raw.pad_axes[.Right_X] = 1
	update(&s, &raw, 0.01)
	short := s.value[.Look_X]
	update(&s, &raw, 0.02)
	testing.expect(t, abs(short - STICK_LOOK_RATE * 0.01) < 1e-3)
	testing.expect(t, abs(s.value[.Look_X] - 2 * short) < 1e-3)

	raw = {pad_connected = true}
	raw.pad_buttons[.Dpad_Down] = true
	update(&s, &raw, 0.5)
	testing.expect(t, abs(s.value[.Zoom] + PAD_ZOOM_RATE * 0.5) < 1e-4)
}

@(test)
sticks_have_a_deadzone :: proc(t: ^testing.T) {
	testing.expect_value(t, apply_deadzone(0.1), 0)
	testing.expect_value(t, apply_deadzone(-STICK_DEADZONE), 0)
	testing.expect_value(t, apply_deadzone(1), 1)
	testing.expect_value(t, apply_deadzone(-1), -1)
	testing.expect(t, apply_deadzone(0.6) > 0.45 && apply_deadzone(0.6) < 0.55)
	testing.expect(t, apply_deadzone(-0.6) < 0)

	s := fresh()
	raw := Raw {
		pad_connected = true,
	}
	raw.pad_axes[.Left_X] = 0.15 // a worn stick resting off centre
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.value[.Move_Right], 0)

	raw.pad_axes[.Left_X] = 1
	raw.pad_axes[.Left_Y] = -1 // pushed up
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.value[.Move_Right], 1)
	testing.expect_value(t, s.value[.Move_Forward], 1)

	// Triggers act as the two halves of an axis.
	raw = {pad_connected = true}
	raw.pad_axes[.Left_Trigger] = 0.2
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.value[.Fly_Up], 0)
	raw.pad_axes[.Left_Trigger] = 1
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.value[.Fly_Up], -1)
}

@(test)
gamepad_is_an_alternative_for_every_gameplay_action :: proc(t: ^testing.T) {
	// Reloading the config stays on the keyboard, and only the mouse needs a
	// button held to look around.
	keyboard_only := bit_set[Action]{.Reload_Config, .Look_Hold}
	has: [Source]bit_set[Action]
	for b in default_bindings() {
		has[control_source(b.control)] += {b.action}
	}
	for b in fixed_bindings() {
		has[control_source(b.control)] += {b.action}
	}
	for a in Action {
		testing.expectf(t, a in has[.Keyboard_Mouse], "%v has no keyboard or mouse binding", a)
		if a not_in keyboard_only {
			testing.expectf(t, a in has[.Gamepad], "%v has no gamepad binding", a)
		}
	}

	s := fresh()
	raw := Raw {
		pad_connected = true,
	}
	raw.pad_buttons[.West] = true
	update(&s, &raw, 0.016)
	testing.expect(t, s.pressed[.Swing])

	// An unplugged pad contributes nothing, whatever its last state was.
	raw.pad_connected = false
	update(&s, &raw, 0.016)
	testing.expect(t, !s.down[.Swing] && s.released[.Swing])
}

@(test)
last_touched_device_is_tracked :: proc(t: ^testing.T) {
	s := fresh()
	raw: Raw
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Keyboard_Mouse)

	raw = {pad_connected = true, pad_type = .PS5}
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Keyboard_Mouse) // plugged in but untouched

	raw.pad_buttons[.South] = true
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Gamepad)
	testing.expect_value(t, s.pad_type, Pad_Type.PS5)

	// Letting go changes nothing; the pad was still the last thing touched.
	raw.pad_buttons[.South] = false
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Gamepad)

	// Stick drift inside the deadzone is not a touch...
	raw.pad_axes[.Left_X] = 0.1
	s.source = .Keyboard_Mouse
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Keyboard_Mouse)
	// ...a real push is.
	raw.pad_axes[.Left_X] = 0.9
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Gamepad)

	// Moving the mouse takes the prompts back, even with no button held.
	raw.pad_axes[.Left_X] = 0
	raw.mouse_moved = true
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Keyboard_Mouse)

	// A different pad model is picked up when it is used.
	raw.mouse_moved = false
	raw.pad_type = .Switch
	raw.pad_axes[.Right_Trigger] = 1
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Gamepad)
	testing.expect_value(t, s.pad_type, Pad_Type.Switch)

	// Both at once: whoever had it keeps it.
	raw.keys[.W] = true
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Gamepad)

	// Pulling the plug falls back to the keyboard.
	raw = {}
	update(&s, &raw, 0.016)
	testing.expect_value(t, s.source, Source.Keyboard_Mouse)
}

@(test)
glyphs_match_the_controller_in_hand :: proc(t: ^testing.T) {
	testing.expect_value(t, control_glyph(Key.W, .Generic), Glyph{.Keyboard_Mouse, "keyboard_w"})
	testing.expect_value(t, control_glyph(Key.F5, .PS5), Glyph{.Keyboard_Mouse, "keyboard_f5"})
	testing.expect_value(t, control_glyph(Mouse_Button.Left, .Generic), Glyph{.Keyboard_Mouse, "mouse_left"})
	testing.expect_value(t, control_glyph(Mouse_Axis.Wheel, .Generic), Glyph{.Keyboard_Mouse, "mouse_scroll_vertical"})

	// The bottom face button wears a different name on every pad.
	testing.expect_value(t, control_glyph(Pad_Button.South, .Xbox_One), Glyph{.Xbox, "xbox_button_a"})
	testing.expect_value(t, control_glyph(Pad_Button.South, .Generic), Glyph{.Xbox, "xbox_button_a"})
	testing.expect_value(t, control_glyph(Pad_Button.South, .PS4), Glyph{.PlayStation, "playstation_button_cross"})
	testing.expect_value(t, control_glyph(Pad_Button.South, .Switch), Glyph{.Switch, "switch_button_b"})
	testing.expect_value(t, control_glyph(Pad_Button.West, .Switch), Glyph{.Switch, "switch_button_y"})

	// And so does the model within a family.
	testing.expect_value(t, control_glyph(Pad_Button.Back, .Xbox_360).name, "xbox_button_back")
	testing.expect_value(t, control_glyph(Pad_Button.Back, .Xbox_One).name, "xbox_button_view")
	testing.expect_value(t, control_glyph(Pad_Button.Back, .PS3).name, "playstation3_button_select")
	testing.expect_value(t, control_glyph(Pad_Button.Back, .PS4).name, "playstation4_button_share")
	testing.expect_value(t, control_glyph(Pad_Button.Back, .PS5).name, "playstation5_button_create")

	testing.expect_value(t, control_glyph(Pad_Axis.Left_X, .Xbox_One).name, "xbox_stick_l")
	testing.expect_value(t, control_glyph(Pad_Axis.Left_Y, .Xbox_One).name, "xbox_stick_l")
	testing.expect_value(t, control_glyph(Pad_Axis.Right_Trigger, .PS5).name, "playstation_trigger_r2")

	// Every control has an icon on every pad.
	for pad in Pad_Type {
		for b in Pad_Button {
			testing.expectf(t, control_glyph(b, pad).name != "", "%v has no icon on %v", b, pad)
		}
		for a in Pad_Axis {
			testing.expectf(t, control_glyph(a, pad).name != "", "%v has no icon on %v", a, pad)
		}
	}
	for k in Key {
		testing.expectf(t, control_glyph(k, .Generic).name != "", "%v has no icon", k)
	}
}

@(test)
action_glyphs_follow_the_active_device :: proc(t: ^testing.T) {
	s := fresh()
	buffer: [8]Glyph

	n := action_glyphs(&s, {.Move_Forward, .Move_Right}, buffer[:])
	testing.expect_value(t, n, 4)
	testing.expect_value(t, buffer[0].name, "keyboard_w")
	testing.expect_value(t, buffer[1].name, "keyboard_a")
	testing.expect_value(t, buffer[2].name, "keyboard_s")
	testing.expect_value(t, buffer[3].name, "keyboard_d")

	n = action_glyphs(&s, {.Look_X, .Look_Y}, buffer[:])
	testing.expect_value(t, n, 1) // both axes of the mouse are one icon
	testing.expect_value(t, buffer[0].name, "mouse_move")

	s.source = .Gamepad
	s.pad_type = .PS5
	n = action_glyphs(&s, {.Move_Forward, .Move_Right}, buffer[:])
	testing.expect_value(t, n, 1) // one stick, not two arrows
	testing.expect_value(t, buffer[0], Glyph{.PlayStation, "playstation_stick_l"})

	n = action_glyphs(&s, {.Swing}, buffer[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, buffer[0].name, "playstation_button_square")
	testing.expect_value(t, buffer[1].name, "playstation_trigger_r1")

	s.pad_type = .Xbox_One
	n = action_glyphs(&s, {.Swing}, buffer[:])
	testing.expect_value(t, buffer[0].name, "xbox_button_x")

	// Nothing on the pad reloads the config, so no prompt is offered for it.
	testing.expect_value(t, action_glyphs(&s, {.Reload_Config}, buffer[:]), 0)
	// A short buffer is filled, not overrun.
	s.source = .Keyboard_Mouse
	testing.expect_value(t, action_glyphs(&s, {.Move_Forward, .Move_Right}, buffer[:2]), 2)
}
