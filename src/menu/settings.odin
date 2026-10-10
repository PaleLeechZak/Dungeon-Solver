package menu

import "core:encoding/json"
import "core:os"
import "core:strings"

import "../input"

// What the player can change in the menus, and what is kept between runs.
Settings :: struct {
	master:   f32, // mixer volumes, 0..1
	sound:    f32,
	music:    f32,
	bindings: [dynamic]input.Binding, // gameplay controls
}

settings_default :: proc(allocator := context.allocator) -> Settings {
	return {master = 0.8, sound = 1, music = 0.7, bindings = input.bindings_clone(input.default_bindings(), allocator)}
}

// The file's shape. Controls and actions are written by name so the file
// stays readable and survives the enums being reordered.
@(private)
Settings_File :: struct {
	volume:   struct {
		master, sound, music: f32,
	},
	bindings: []Binding_File,
}

@(private)
Binding_File :: struct {
	action:  string,
	control: string,
	scale:   f32,
}

settings_to_json :: proc(s: ^Settings, allocator := context.allocator) -> (text: string, ok: bool) {
	file := Settings_File {
		bindings = make([]Binding_File, len(s.bindings), context.temp_allocator),
	}
	file.volume = {s.master, s.sound, s.music}
	for b, i in s.bindings {
		file.bindings[i] = {
			action  = input.action_name(b.action, context.temp_allocator),
			control = input.control_name(b.control, context.temp_allocator),
			scale   = b.scale,
		}
	}
	data, err := json.marshal(file, {pretty = true, use_spaces = false}, allocator)
	return string(data), err == nil
}

// Reads settings, starting from the defaults. Anything that cannot be
// understood is left at its default rather than failing: a damaged settings
// file must never stop the game from starting.
settings_parse :: proc(data: []byte, allocator := context.allocator) -> (s: Settings, ok: bool) {
	s = settings_default(allocator)
	file: Settings_File
	file.volume = {s.master, s.sound, s.music}
	if json.unmarshal(data, &file, json.Specification.JSON5, context.temp_allocator) != nil {
		return s, false
	}
	s.master = clamp(file.volume.master, 0, 1)
	s.sound = clamp(file.volume.sound, 0, 1)
	s.music = clamp(file.volume.music, 0, 1)

	if file.bindings == nil {
		return s, true
	}
	parsed := make([dynamic]input.Binding, 0, len(file.bindings), allocator)
	for b in file.bindings {
		action, action_ok := input.action_parse(b.action)
		control, control_ok := input.control_parse(b.control)
		// Menu navigation is not the player's to change, and a zero scale
		// would be a binding that does nothing.
		if !action_ok || !control_ok || b.scale == 0 || !rebindable(action) || input.control_reserved(control) {
			ok = false
			continue
		}
		append(&parsed, input.Binding{action, control, b.scale})
	}
	// An empty list is taken as damage, not as "no controls at all".
	if len(parsed) > 0 {
		delete(s.bindings)
		s.bindings = parsed
	}
	return s, len(parsed) == len(file.bindings)
}

settings_load :: proc(path: string, allocator := context.allocator) -> Settings {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return settings_default(allocator)
	}
	s, _ := settings_parse(data, allocator)
	return s
}

settings_save :: proc(path: string, s: ^Settings) -> bool {
	text, ok := settings_to_json(s, context.temp_allocator)
	if !ok {
		return false
	}
	return os.write_entire_file(path, transmute([]byte)strings.concatenate({text, "\n"}, context.temp_allocator)) == nil
}

// Whether an action appears on the controls screen.
rebindable :: proc(action: input.Action) -> bool {
	for row in SLOTS {
		if row.slot.action == action {
			return true
		}
	}
	return false
}
