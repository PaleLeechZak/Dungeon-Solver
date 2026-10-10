package input

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"

// Rebinding. The controls screen shows one row per `Slot`; choosing a row and
// pressing something replaces what that row is bound to on the device used.

// One thing the player can bind a control to: a button action, or one
// direction of an axis action ("walk forward" is Move_Forward, +1).
Slot :: struct {
	action: Action,
	sign:   f32, // +1 or -1; always +1 for button actions
}

@(private)
is_stick_axis :: proc(c: Control) -> bool {
	axis, ok := c.(Pad_Axis)
	return ok && axis != .Left_Trigger && axis != .Right_Trigger
}

// Whether a binding belongs in a slot's row for the given device. A stick
// bound to an axis action serves both of its directions, so it shows in both
// rows.
binding_in_slot :: proc(b: Binding, slot: Slot, source: Source) -> bool {
	if b.action != slot.action || control_source(b.control) != source {
		return false
	}
	if action_kind(b.action) != .Axis || is_stick_axis(b.control) {
		return true
	}
	return (b.scale < 0) == (slot.sign < 0)
}

// The icons for a slot's row, without repeats. Returns how many were written.
slot_glyphs :: proc(bindings: []Binding, slot: Slot, source: Source, pad: Pad_Type, out: []Glyph) -> (count: int) {
	for b in bindings {
		if !binding_in_slot(b, slot, source) {
			continue
		}
		glyph := control_glyph(b.control, pad)
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

// What the player pressed while a row was waiting for input.
Capture :: struct {
	control:   Control,
	direction: f32, // which way a stick was pushed, +1 or -1; +1 for everything else
}

// Controls that keep their meaning in the menus and so cannot be given away:
// they are how a rebinding is cancelled.
control_reserved :: proc(c: Control) -> bool {
	#partial switch v in c {
	case Key:
		return v == .Escape
	case Pad_Button:
		return v == .Start
	}
	return false
}

// The first control on `source` that went down between two frames. Mouse
// movement and the wheel are not offered, and reserved controls are skipped.
capture :: proc(raw, previous: ^Raw, source: Source) -> (c: Capture, ok: bool) {
	switch source {
	case .Keyboard_Mouse:
		for key in Key {
			if raw.keys[key] && !previous.keys[key] && !control_reserved(key) {
				return {key, 1}, true
			}
		}
		for button in Mouse_Button {
			if raw.mouse_buttons[button] && !previous.mouse_buttons[button] {
				return {button, 1}, true
			}
		}
	case .Gamepad:
		if !raw.pad_connected {
			return
		}
		for button in Pad_Button {
			if raw.pad_buttons[button] && !previous.pad_buttons[button] && !control_reserved(button) {
				return {button, 1}, true
			}
		}
		for axis in Pad_Axis {
			now, before := control_level(raw, axis), control_level(previous, axis)
			if abs(now) >= AXIS_AS_BUTTON && abs(before) < AXIS_AS_BUTTON {
				return {axis, now < 0 ? -1 : 1}, true
			}
		}
	}
	return
}

// Gives a slot's row to the captured control: whatever the row had on that
// device goes, and the new control takes its place. Other rows are left
// alone, so one control may still do two things (Space flies up in free
// flight and swings the sword on foot).
rebind :: proc(bindings: ^[dynamic]Binding, slot: Slot, c: Capture) {
	source := control_source(c.control)
	for i := len(bindings) - 1; i >= 0; i -= 1 {
		if binding_in_slot(bindings[i], slot, source) {
			ordered_remove(bindings, i)
		}
	}
	scale := slot.sign
	switch {
	case action_kind(slot.action) != .Axis:
		// For a button the sign only says which way a stick has to be pushed.
		scale = c.direction
	case is_stick_axis(c.control):
		// Pushed the way it was captured, the stick drives the slot's direction.
		scale = slot.sign * c.direction
	}
	append(bindings, Binding{slot.action, c.control, scale})
}

// A copy of a binding table that can be edited.
bindings_clone :: proc(source: []Binding, allocator := context.allocator) -> [dynamic]Binding {
	out := make([dynamic]Binding, 0, len(source), allocator)
	append(&out, ..source)
	return out
}

// "Key.W", "Mouse_Button.Left", "Pad_Axis.Left_X": how a control is written
// in the settings file.
control_name :: proc(c: Control, allocator := context.allocator) -> string {
	switch v in c {
	case Key:
		return fmt.aprintf("Key.%v", v, allocator = allocator)
	case Mouse_Button:
		return fmt.aprintf("Mouse_Button.%v", v, allocator = allocator)
	case Mouse_Axis:
		return fmt.aprintf("Mouse_Axis.%v", v, allocator = allocator)
	case Pad_Button:
		return fmt.aprintf("Pad_Button.%v", v, allocator = allocator)
	case Pad_Axis:
		return fmt.aprintf("Pad_Axis.%v", v, allocator = allocator)
	}
	return ""
}

control_parse :: proc(text: string) -> (c: Control, ok: bool) {
	dot := strings.index_byte(text, '.')
	if dot < 0 {
		return
	}
	family, name := text[:dot], text[dot + 1:]
	switch family {
	case "Key":
		v := reflect.enum_from_name(Key, name) or_return
		return v, true
	case "Mouse_Button":
		v := reflect.enum_from_name(Mouse_Button, name) or_return
		return v, true
	case "Mouse_Axis":
		v := reflect.enum_from_name(Mouse_Axis, name) or_return
		return v, true
	case "Pad_Button":
		v := reflect.enum_from_name(Pad_Button, name) or_return
		return v, true
	case "Pad_Axis":
		v := reflect.enum_from_name(Pad_Axis, name) or_return
		return v, true
	}
	return
}

action_name :: proc(a: Action, allocator: runtime.Allocator) -> string {
	return fmt.aprintf("%v", a, allocator = allocator)
}

action_parse :: proc(text: string) -> (Action, bool) {
	return reflect.enum_from_name(Action, text)
}
