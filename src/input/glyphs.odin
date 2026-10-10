package input

import "core:fmt"

// Which Kenney input font a prompt comes from.
Glyph_Font :: enum u8 {
	Keyboard_Mouse,
	Xbox,
	PlayStation,
	Switch,
}

// A prompt icon: a glyph name as listed in the font's *_characters.txt.
Glyph :: struct {
	font: Glyph_Font,
	name: string,
}

pad_font :: proc(type: Pad_Type) -> Glyph_Font {
	switch type {
	case .PS3, .PS4, .PS5:
		return .PlayStation
	case .Switch:
		return .Switch
	case .Generic, .Xbox_360, .Xbox_One:
		return .Xbox
	}
	return .Xbox
}

@(private, rodata)
KEY_NAMES := [Key]string {
	.A = "keyboard_a", .B = "keyboard_b", .C = "keyboard_c", .D = "keyboard_d", .E = "keyboard_e", .F = "keyboard_f",
	.G = "keyboard_g", .H = "keyboard_h", .I = "keyboard_i", .J = "keyboard_j", .K = "keyboard_k", .L = "keyboard_l",
	.M = "keyboard_m", .N = "keyboard_n", .O = "keyboard_o", .P = "keyboard_p", .Q = "keyboard_q", .R = "keyboard_r",
	.S = "keyboard_s", .T = "keyboard_t", .U = "keyboard_u", .V = "keyboard_v", .W = "keyboard_w", .X = "keyboard_x",
	.Y = "keyboard_y", .Z = "keyboard_z",
	.N0 = "keyboard_0", .N1 = "keyboard_1", .N2 = "keyboard_2", .N3 = "keyboard_3", .N4 = "keyboard_4",
	.N5 = "keyboard_5", .N6 = "keyboard_6", .N7 = "keyboard_7", .N8 = "keyboard_8", .N9 = "keyboard_9",
	.F1 = "keyboard_f1", .F2 = "keyboard_f2", .F3 = "keyboard_f3", .F4 = "keyboard_f4", .F5 = "keyboard_f5",
	.F6 = "keyboard_f6", .F7 = "keyboard_f7", .F8 = "keyboard_f8", .F9 = "keyboard_f9", .F10 = "keyboard_f10",
	.F11 = "keyboard_f11", .F12 = "keyboard_f12",
	.Space = "keyboard_space", .Tab = "keyboard_tab", .Escape = "keyboard_escape", .Enter = "keyboard_enter",
	.Backspace = "keyboard_backspace", .Shift = "keyboard_shift", .Ctrl = "keyboard_ctrl", .Alt = "keyboard_alt",
	.Home = "keyboard_home", .End = "keyboard_end",
	.Up = "keyboard_arrow_up", .Down = "keyboard_arrow_down", .Left = "keyboard_arrow_left", .Right = "keyboard_arrow_right",
}

// The icon for a control. Pad controls depend on the pad in the player's
// hands: the same button is A, Cross or B.
control_glyph :: proc(c: Control, pad: Pad_Type) -> Glyph {
	switch v in c {
	case Key:
		return {.Keyboard_Mouse, KEY_NAMES[v]}
	case Mouse_Button:
		switch v {
		case .Left:
			return {.Keyboard_Mouse, "mouse_left"}
		case .Right:
			return {.Keyboard_Mouse, "mouse_right"}
		case .Middle:
			return {.Keyboard_Mouse, "mouse_scroll"}
		}
	case Mouse_Axis:
		return {.Keyboard_Mouse, v == .Wheel ? "mouse_scroll_vertical" : "mouse_move"}
	case Pad_Button:
		return {pad_font(pad), pad_button_name(v, pad)}
	case Pad_Axis:
		return {pad_font(pad), pad_axis_name(v, pad)}
	}
	return {}
}

@(private)
pad_button_name :: proc(b: Pad_Button, pad: Pad_Type) -> string {
	switch pad_font(pad) {
	case .PlayStation:
		switch b {
		case .South: return "playstation_button_cross"
		case .East: return "playstation_button_circle"
		case .West: return "playstation_button_square"
		case .North: return "playstation_button_triangle"
		case .Back:
			#partial switch pad {
			case .PS3: return "playstation3_button_select"
			case .PS4: return "playstation4_button_share"
			}
			return "playstation5_button_create"
		case .Start:
			#partial switch pad {
			case .PS3: return "playstation3_button_start"
			case .PS4: return "playstation4_button_options"
			}
			return "playstation5_button_options"
		case .Guide: return "playstation_button_analog"
		case .Left_Stick: return "playstation_stick_l_press"
		case .Right_Stick: return "playstation_stick_r_press"
		case .Left_Shoulder: return "playstation_trigger_l1"
		case .Right_Shoulder: return "playstation_trigger_r1"
		case .Dpad_Up: return "playstation_dpad_up"
		case .Dpad_Down: return "playstation_dpad_down"
		case .Dpad_Left: return "playstation_dpad_left"
		case .Dpad_Right: return "playstation_dpad_right"
		}
	case .Switch:
		// Nintendo's letters sit the other way round: the bottom button is B.
		switch b {
		case .South: return "switch_button_b"
		case .East: return "switch_button_a"
		case .West: return "switch_button_y"
		case .North: return "switch_button_x"
		case .Back: return "switch_button_minus"
		case .Start: return "switch_button_plus"
		case .Guide: return "switch_button_home"
		case .Left_Stick: return "switch_stick_l_press"
		case .Right_Stick: return "switch_stick_r_press"
		case .Left_Shoulder: return "switch_button_l"
		case .Right_Shoulder: return "switch_button_r"
		case .Dpad_Up: return "switch_dpad_up"
		case .Dpad_Down: return "switch_dpad_down"
		case .Dpad_Left: return "switch_dpad_left"
		case .Dpad_Right: return "switch_dpad_right"
		}
	case .Xbox, .Keyboard_Mouse:
		switch b {
		case .South: return "xbox_button_a"
		case .East: return "xbox_button_b"
		case .West: return "xbox_button_x"
		case .North: return "xbox_button_y"
		case .Back: return pad == .Xbox_360 ? "xbox_button_back" : "xbox_button_view"
		case .Start: return pad == .Xbox_360 ? "xbox_button_start" : "xbox_button_menu"
		case .Guide: return "xbox_guide"
		case .Left_Stick: return "xbox_stick_l_press"
		case .Right_Stick: return "xbox_stick_r_press"
		case .Left_Shoulder: return "xbox_lb"
		case .Right_Shoulder: return "xbox_rb"
		case .Dpad_Up: return "xbox_dpad_up"
		case .Dpad_Down: return "xbox_dpad_down"
		case .Dpad_Left: return "xbox_dpad_left"
		case .Dpad_Right: return "xbox_dpad_right"
		}
	}
	return ""
}

// Both axes of a stick share the stick's icon, so "move" shows one stick
// rather than a horizontal and a vertical arrow.
@(private)
pad_axis_name :: proc(a: Pad_Axis, pad: Pad_Type) -> string {
	left := a == .Left_X || a == .Left_Y || a == .Left_Trigger
	trigger := a == .Left_Trigger || a == .Right_Trigger
	switch pad_font(pad) {
	case .PlayStation:
		if trigger do return left ? "playstation_trigger_l2" : "playstation_trigger_r2"
		return left ? "playstation_stick_l" : "playstation_stick_r"
	case .Switch:
		if trigger do return left ? "switch_button_zl" : "switch_button_zr"
		return left ? "switch_stick_l" : "switch_stick_r"
	case .Xbox, .Keyboard_Mouse:
		if trigger do return left ? "xbox_lt" : "xbox_rt"
		return left ? "xbox_stick_l" : "xbox_stick_r"
	}
	return ""
}

// The icons to show for a group of actions on the device in use, in binding
// order and without repeats. Returns how many were written to `out`.
action_glyphs :: proc(s: ^State, actions: []Action, out: []Glyph) -> (count: int) {
	total := len(s.bindings) + len(s.fixed)
	for i in 0 ..< total {
		b := i < len(s.bindings) ? s.bindings[i] : s.fixed[i - len(s.bindings)]
		if control_source(b.control) != s.source {
			continue
		}
		wanted := false
		for a in actions {
			wanted ||= a == b.action
		}
		if !wanted {
			continue
		}
		glyph := control_glyph(b.control, s.pad_type)
		repeat := glyph.name == ""
		for existing in out[:count] {
			repeat ||= existing == glyph
		}
		if !repeat && count < len(out) {
			out[count] = glyph
			count += 1
		}
	}
	return
}

// A readable name for the device in use, e.g. for a debug line.
source_name :: proc(s: ^State) -> string {
	if s.source == .Keyboard_Mouse {
		return "keyboard & mouse"
	}
	return fmt.tprintf("%v gamepad", s.pad_type)
}
