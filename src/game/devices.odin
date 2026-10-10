package game

import sdl "vendor:sdl3"

import "../input"

// The bridge between SDL's devices and the input package's `Raw`: this file
// is the only place that knows SDL's names for keys, buttons and pads.

@(rodata)
KEY_SCANCODES := [input.Key]sdl.Scancode {
	.A = .A, .B = .B, .C = .C, .D = .D, .E = .E, .F = .F, .G = .G, .H = .H, .I = .I, .J = .J, .K = .K, .L = .L, .M = .M,
	.N = .N, .O = .O, .P = .P, .Q = .Q, .R = .R, .S = .S, .T = .T, .U = .U, .V = .V, .W = .W, .X = .X, .Y = .Y, .Z = .Z,
	.N0 = ._0, .N1 = ._1, .N2 = ._2, .N3 = ._3, .N4 = ._4, .N5 = ._5, .N6 = ._6, .N7 = ._7, .N8 = ._8, .N9 = ._9,
	.F1 = .F1, .F2 = .F2, .F3 = .F3, .F4 = .F4, .F5 = .F5, .F6 = .F6, .F7 = .F7, .F8 = .F8, .F9 = .F9, .F10 = .F10,
	.F11 = .F11, .F12 = .F12,
	.Space = .SPACE, .Tab = .TAB, .Escape = .ESCAPE, .Enter = .RETURN, .Backspace = .BACKSPACE,
	.Shift = .LSHIFT, .Ctrl = .LCTRL, .Alt = .LALT, .Home = .HOME, .End = .END,
	.Up = .UP, .Down = .DOWN, .Left = .LEFT, .Right = .RIGHT,
}

@(rodata)
PAD_BUTTONS := [input.Pad_Button]sdl.GamepadButton {
	.South          = .SOUTH,
	.East           = .EAST,
	.West           = .WEST,
	.North          = .NORTH,
	.Back           = .BACK,
	.Guide          = .GUIDE,
	.Start          = .START,
	.Left_Stick     = .LEFT_STICK,
	.Right_Stick    = .RIGHT_STICK,
	.Left_Shoulder  = .LEFT_SHOULDER,
	.Right_Shoulder = .RIGHT_SHOULDER,
	.Dpad_Up        = .DPAD_UP,
	.Dpad_Down      = .DPAD_DOWN,
	.Dpad_Left      = .DPAD_LEFT,
	.Dpad_Right     = .DPAD_RIGHT,
}

@(rodata)
PAD_AXES := [input.Pad_Axis]sdl.GamepadAxis {
	.Left_X        = .LEFTX,
	.Left_Y        = .LEFTY,
	.Right_X       = .RIGHTX,
	.Right_Y       = .RIGHTY,
	.Left_Trigger  = .LEFT_TRIGGER,
	.Right_Trigger = .RIGHT_TRIGGER,
}

// Which family and model of pad SDL says is plugged in.
pad_type :: proc(type: sdl.GamepadType) -> input.Pad_Type {
	#partial switch type {
	case .XBOX360:
		return .Xbox_360
	case .XBOXONE:
		return .Xbox_One
	case .PS3:
		return .PS3
	case .PS4:
		return .PS4
	case .PS5:
		return .PS5
	case .NINTENDO_SWITCH_PRO, .NINTENDO_SWITCH_JOYCON_LEFT, .NINTENDO_SWITCH_JOYCON_RIGHT, .NINTENDO_SWITCH_JOYCON_PAIR:
		return .Switch
	}
	return .Generic
}

// Raw axis values run -32768..32767; this evens the two ends out to -1..1.
pad_axis_value :: proc(raw: i16) -> f32 {
	return max(f32(raw) / 32767, -1)
}

// What happened between two frames that polling alone could miss or cannot
// see: quick taps, mouse travel and the wheel.
Device_Events :: struct {
	keys_tapped:    [input.Key]bool,
	buttons_tapped: [input.Mouse_Button]bool,
	pad_tapped:     [input.Pad_Button]bool,
	mouse_motion:   [2]f32,
	mouse_moved:    bool,
	wheel:          f32,
}

// Records one SDL event. Returns false for the event that asks to quit.
devices_event :: proc(events: ^Device_Events, pad: ^^sdl.Gamepad, event: ^sdl.Event) -> (keep_running: bool) {
	#partial switch event.type {
	case .QUIT:
		return false
	case .KEY_DOWN:
		for code, key in KEY_SCANCODES {
			if code == event.key.scancode {
				events.keys_tapped[key] = true
			}
		}
	case .MOUSE_BUTTON_DOWN:
		switch event.button.button {
		case sdl.BUTTON_LEFT:
			events.buttons_tapped[.Left] = true
		case sdl.BUTTON_RIGHT:
			events.buttons_tapped[.Right] = true
		case sdl.BUTTON_MIDDLE:
			events.buttons_tapped[.Middle] = true
		}
	case .MOUSE_MOTION:
		events.mouse_motion += {event.motion.xrel, event.motion.yrel}
		events.mouse_moved = true
	case .MOUSE_WHEEL:
		events.wheel += event.wheel.y
	case .GAMEPAD_BUTTON_DOWN:
		for code, button in PAD_BUTTONS {
			if u8(code) == event.gbutton.button {
				events.pad_tapped[button] = true
			}
		}
	case .GAMEPAD_ADDED:
		// The first pad plugged in is the one that is used.
		if pad^ == nil {
			pad^ = sdl.OpenGamepad(event.gdevice.which)
		}
	case .GAMEPAD_REMOVED:
		if pad^ != nil && sdl.GetGamepadID(pad^) == event.gdevice.which {
			sdl.CloseGamepad(pad^)
			pad^ = nil
		}
	}
	return true
}

// Snapshot of every device for the input package. Mouse travel only counts
// while `looking`, i.e. while the pointer is captured for looking around.
devices_read :: proc(events: ^Device_Events, pad: ^sdl.Gamepad, looking: bool) -> (raw: input.Raw) {
	keys := sdl.GetKeyboardState(nil)
	for code, key in KEY_SCANCODES {
		raw.keys[key] = keys[int(code)] || events.keys_tapped[key]
	}
	// Either shift, control or alt will do.
	raw.keys[.Shift] ||= keys[int(sdl.Scancode.RSHIFT)]
	raw.keys[.Ctrl] ||= keys[int(sdl.Scancode.RCTRL)]
	raw.keys[.Alt] ||= keys[int(sdl.Scancode.RALT)]

	buttons := sdl.GetMouseState(nil, nil)
	raw.mouse_buttons[.Left] = .LEFT in buttons || events.buttons_tapped[.Left]
	raw.mouse_buttons[.Right] = .RIGHT in buttons || events.buttons_tapped[.Right]
	raw.mouse_buttons[.Middle] = .MIDDLE in buttons || events.buttons_tapped[.Middle]
	raw.mouse_moved = events.mouse_moved
	raw.mouse_axes[.Wheel] = events.wheel
	if looking {
		raw.mouse_axes[.Move_X] = events.mouse_motion.x
		raw.mouse_axes[.Move_Y] = events.mouse_motion.y
	}

	if pad != nil {
		raw.pad_connected = true
		raw.pad_type = pad_type(sdl.GetGamepadType(pad))
		for code, button in PAD_BUTTONS {
			raw.pad_buttons[button] = sdl.GetGamepadButton(pad, code) || events.pad_tapped[button]
		}
		for code, axis in PAD_AXES {
			raw.pad_axes[axis] = pad_axis_value(sdl.GetGamepadAxis(pad, code))
		}
	}
	return
}
