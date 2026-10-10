package game

import "core:testing"
import sdl "vendor:sdl3"

import "../input"

// These tests look at lookup tables and pure helpers only. They open no
// window, no device and no gamepad.

@(test)
every_key_has_its_own_scancode :: proc(t: ^testing.T) {
	for code, key in KEY_SCANCODES {
		testing.expectf(t, code != .UNKNOWN, "%v has no scancode", key)
		for other_code, other in KEY_SCANCODES {
			if other != key {
				testing.expectf(t, code != other_code, "%v and %v share a scancode", key, other)
			}
		}
	}
	testing.expect_value(t, KEY_SCANCODES[.W], sdl.Scancode.W)
	testing.expect_value(t, KEY_SCANCODES[.N0], sdl.Scancode._0)
	testing.expect_value(t, KEY_SCANCODES[.Enter], sdl.Scancode.RETURN)
}

@(test)
pad_tables_cover_every_control :: proc(t: ^testing.T) {
	for code, button in PAD_BUTTONS {
		for other_code, other in PAD_BUTTONS {
			if other != button {
				testing.expectf(t, code != other_code, "%v and %v share a button", button, other)
			}
		}
	}
	// South stays South: positions, not letters, are what gets mapped.
	testing.expect_value(t, PAD_BUTTONS[.South], sdl.GamepadButton.SOUTH)
	testing.expect_value(t, PAD_BUTTONS[.West], sdl.GamepadButton.WEST)
	testing.expect_value(t, PAD_AXES[.Left_Y], sdl.GamepadAxis.LEFTY)
	testing.expect_value(t, PAD_AXES[.Right_Trigger], sdl.GamepadAxis.RIGHT_TRIGGER)
}

@(test)
controller_models_are_recognised :: proc(t: ^testing.T) {
	testing.expect_value(t, pad_type(.XBOX360), input.Pad_Type.Xbox_360)
	testing.expect_value(t, pad_type(.XBOXONE), input.Pad_Type.Xbox_One)
	testing.expect_value(t, pad_type(.PS3), input.Pad_Type.PS3)
	testing.expect_value(t, pad_type(.PS4), input.Pad_Type.PS4)
	testing.expect_value(t, pad_type(.PS5), input.Pad_Type.PS5)
	testing.expect_value(t, pad_type(.NINTENDO_SWITCH_PRO), input.Pad_Type.Switch)
	testing.expect_value(t, pad_type(.NINTENDO_SWITCH_JOYCON_PAIR), input.Pad_Type.Switch)
	// Anything SDL cannot name gets the generic prompts.
	testing.expect_value(t, pad_type(.STANDARD), input.Pad_Type.Generic)
	testing.expect_value(t, pad_type(.UNKNOWN), input.Pad_Type.Generic)
}

@(test)
stick_values_span_minus_one_to_one :: proc(t: ^testing.T) {
	testing.expect_value(t, pad_axis_value(0), 0)
	testing.expect_value(t, pad_axis_value(32767), 1)
	testing.expect_value(t, pad_axis_value(-32768), -1)
	testing.expect_value(t, pad_axis_value(-32767), -1)
	testing.expect(t, abs(pad_axis_value(16384) - 0.5) < 0.001)
}

// Events latch what polling could miss: a key tapped and released between
// two frames still counts as pressed for the frame that follows.
@(test)
events_are_recorded :: proc(t: ^testing.T) {
	events: Device_Events
	pad: ^sdl.Gamepad

	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = .TAB
	testing.expect(t, devices_event(&events, &pad, &event))
	testing.expect(t, events.keys_tapped[.Tab])
	testing.expect(t, !events.keys_tapped[.W])

	event = {}
	event.type = .MOUSE_MOTION
	event.motion.xrel = 3
	event.motion.yrel = -2
	devices_event(&events, &pad, &event)
	devices_event(&events, &pad, &event)
	testing.expect_value(t, events.mouse_motion, [2]f32{6, -4})
	testing.expect(t, events.mouse_moved)

	event = {}
	event.type = .MOUSE_WHEEL
	event.wheel.y = 1
	devices_event(&events, &pad, &event)
	testing.expect_value(t, events.wheel, 1)

	event = {}
	event.type = .MOUSE_BUTTON_DOWN
	event.button.button = sdl.BUTTON_LEFT
	devices_event(&events, &pad, &event)
	testing.expect(t, events.buttons_tapped[.Left] && !events.buttons_tapped[.Right])

	event = {}
	event.type = .GAMEPAD_BUTTON_DOWN
	event.gbutton.button = u8(sdl.GamepadButton.WEST)
	devices_event(&events, &pad, &event)
	testing.expect(t, events.pad_tapped[.West] && !events.pad_tapped[.South])

	event = {}
	event.type = .QUIT
	testing.expect(t, !devices_event(&events, &pad, &event))
	testing.expect(t, pad == nil)
}
