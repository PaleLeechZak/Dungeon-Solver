// Action based input. The game asks "is Swing pressed" or "how far is
// Move_Forward pushed"; this package knows which keys, mouse buttons and
// gamepad controls answer that. It is pure: the game copies device state into
// a `Raw` every frame, so everything here can be tested without SDL.
package input

Action :: enum u8 {
	Move_Right, // axes: -1..1
	Move_Forward,
	Fly_Up,
	Look_X, // deltas: mouse pixels, or the stick's equivalent of them
	Look_Y,
	Zoom, // delta: wheel steps
	Look_Hold, // buttons from here on
	Fast,
	Swing,
	Toggle_Mode,
	Regenerate,
	Reload_Config,
	Reset_Camera,
	Pause,
	// Menu navigation. These are never rebound, so a player can always get
	// back to the controls screen to undo a mistake.
	Menu_Up,
	Menu_Down,
	Menu_Left,
	Menu_Right,
	Menu_Confirm,
	Menu_Back,
}

Action_Kind :: enum u8 {
	Button,
	Axis, // a level in -1..1 for as long as the control is held
	Delta, // an amount that happened this frame
}

action_kind :: proc(a: Action) -> Action_Kind {
	switch a {
	case .Move_Right, .Move_Forward, .Fly_Up:
		return .Axis
	case .Look_X, .Look_Y, .Zoom:
		return .Delta
	case .Look_Hold, .Fast, .Swing, .Toggle_Mode, .Regenerate, .Reload_Config, .Reset_Camera, .Pause:
		return .Button
	case .Menu_Up, .Menu_Down, .Menu_Left, .Menu_Right, .Menu_Confirm, .Menu_Back:
		return .Button
	}
	return .Button
}

Key :: enum u8 {
	A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	N0, N1, N2, N3, N4, N5, N6, N7, N8, N9,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	Space, Tab, Escape, Enter, Backspace, Shift, Ctrl, Alt, Home, End,
	Up, Down, Left, Right,
}

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
}

Mouse_Axis :: enum u8 {
	Move_X, // pixels this frame
	Move_Y,
	Wheel, // steps this frame
}

// Buttons by position, the way SDL reports them: South is A on an Xbox pad,
// Cross on a PlayStation pad and B on a Switch pad.
Pad_Button :: enum u8 {
	South,
	East,
	West,
	North,
	Back,
	Guide,
	Start,
	Left_Stick,
	Right_Stick,
	Left_Shoulder,
	Right_Shoulder,
	Dpad_Up,
	Dpad_Down,
	Dpad_Left,
	Dpad_Right,
}

Pad_Axis :: enum u8 {
	Left_X, // -1 left .. 1 right
	Left_Y, // -1 up .. 1 down
	Right_X,
	Right_Y,
	Left_Trigger, // 0 .. 1
	Right_Trigger,
}

Pad_Type :: enum u8 {
	Generic,
	Xbox_360,
	Xbox_One, // One and Series
	PS3,
	PS4,
	PS5,
	Switch,
}

Control :: union #no_nil {
	Key,
	Mouse_Button,
	Mouse_Axis,
	Pad_Button,
	Pad_Axis,
}

Source :: enum u8 {
	Keyboard_Mouse,
	Gamepad,
}

control_source :: proc(c: Control) -> Source {
	switch _ in c {
	case Key, Mouse_Button, Mouse_Axis:
		return .Keyboard_Mouse
	case Pad_Button, Pad_Axis:
		return .Gamepad
	}
	return .Keyboard_Mouse
}

// One control feeding one action. `scale` is what the control contributes
// when fully pressed or pushed: -1 turns a key into "the other way", and for
// a stick driving a Delta action it is the amount per second at full tilt.
Binding :: struct {
	action:  Action,
	control: Control,
	scale:   f32,
}

// Device state for one frame, filled in by the game.
Raw :: struct {
	keys:          [Key]bool,
	mouse_buttons: [Mouse_Button]bool,
	mouse_axes:    [Mouse_Axis]f32, // what the mouse did this frame, already gated by the game
	mouse_moved:   bool, // the pointer moved at all, even when that motion is not used
	pad_connected: bool,
	pad_type:      Pad_Type,
	pad_buttons:   [Pad_Button]bool,
	pad_axes:      [Pad_Axis]f32,
}

STICK_DEADZONE :: 0.2
TRIGGER_THRESHOLD :: 0.3
AXIS_AS_BUTTON :: 0.5

State :: struct {
	bindings: []Binding, // gameplay controls; the player can change these
	fixed:    []Binding, // menu navigation, pause and analogue look; never rebound
	value:    [Action]f32,
	down:     [Action]bool,
	pressed:  [Action]bool, // went down this frame
	released: [Action]bool, // went up this frame
	// The device the player touched last, and what kind of pad that was.
	// Controls shown on screen follow these.
	source:   Source,
	pad_type: Pad_Type,
}

// Removes the dead centre of a stick and stretches the rest back to 0..1.
apply_deadzone :: proc(v: f32) -> f32 {
	magnitude := abs(v)
	if magnitude <= STICK_DEADZONE {
		return 0
	}
	scaled := min((magnitude - STICK_DEADZONE) / (1 - STICK_DEADZONE), 1)
	return v < 0 ? -scaled : scaled
}

// How far a control is engaged: 0/1 for buttons, signed for axes.
@(private)
control_level :: proc(raw: ^Raw, c: Control) -> f32 {
	switch v in c {
	case Key:
		return raw.keys[v] ? 1 : 0
	case Mouse_Button:
		return raw.mouse_buttons[v] ? 1 : 0
	case Mouse_Axis:
		return raw.mouse_axes[v]
	case Pad_Button:
		return raw.pad_connected && raw.pad_buttons[v] ? 1 : 0
	case Pad_Axis:
		if !raw.pad_connected {
			return 0
		}
		if v == .Left_Trigger || v == .Right_Trigger {
			return raw.pad_axes[v] > TRIGGER_THRESHOLD ? raw.pad_axes[v] : 0
		}
		return apply_deadzone(raw.pad_axes[v])
	}
	return 0
}

update :: proc(s: ^State, raw: ^Raw, dt: f32) {
	previous := s.down
	s.value = {}
	s.down = {}

	apply :: proc(s: ^State, raw: ^Raw, b: Binding, dt: f32) {
		level := control_level(raw, b.control)
		if level == 0 {
			return
		}
		_, is_mouse_axis := b.control.(Mouse_Axis)
		switch action_kind(b.action) {
		case .Button:
			// A stick or trigger presses a button when pushed the way the
			// binding's sign says; keys and buttons always have level 1.
			if level * (b.scale < 0 ? -1 : 1) >= AXIS_AS_BUTTON {
				s.down[b.action] = true
				s.value[b.action] = 1
			}
		case .Axis:
			s.value[b.action] += level * b.scale
		case .Delta:
			// The mouse reports what happened this frame; anything held
			// contributes for as long as the frame lasted.
			s.value[b.action] += is_mouse_axis ? level * b.scale : level * b.scale * dt
		}
	}
	for b in s.bindings {
		apply(s, raw, b, dt)
	}
	for b in s.fixed {
		apply(s, raw, b, dt)
	}	for a in Action {
		#partial switch action_kind(a) {
		case .Axis:
			s.value[a] = clamp(s.value[a], -1, 1)
			s.down[a] = abs(s.value[a]) >= AXIS_AS_BUTTON
		case .Delta:
			s.down[a] = s.value[a] != 0
		}
		s.pressed[a] = s.down[a] && !previous[a]
		s.released[a] = !s.down[a] && previous[a]
	}

	// Whoever was touched last owns the on-screen prompts. When both are
	// touched in the same frame the current owner keeps them.
	keyboard_mouse := raw.mouse_moved
	for down in raw.keys do keyboard_mouse ||= down
	for down in raw.mouse_buttons do keyboard_mouse ||= down
	keyboard_mouse ||= raw.mouse_axes[.Wheel] != 0

	gamepad := false
	if raw.pad_connected {
		for down in raw.pad_buttons do gamepad ||= down
		for axis in Pad_Axis {
			gamepad ||= control_level(raw, axis) != 0
		}
	}
	if gamepad != keyboard_mouse {
		s.source = gamepad ? .Gamepad : .Keyboard_Mouse
	}
	if s.source == .Gamepad {
		if raw.pad_connected {
			s.pad_type = raw.pad_type
		} else {
			s.source = .Keyboard_Mouse // it was unplugged
		}
	}
}

// Look speed of a fully tilted stick, in the pixels per second of mouse
// travel it stands in for.
STICK_LOOK_RATE :: 700
PAD_ZOOM_RATE :: 6 // wheel steps per second

// The tables are filled on first use: this compiler build fails to emit a
// constant table of unions.
@(private)
Binding_Table :: struct {
	rows:  [64]Binding,
	count: int,
}
@(private)
default_table, fixed_table: Binding_Table

@(private)
table_fill :: proc(table: ^Binding_Table, rows: []Binding) -> []Binding {
	if table.count == 0 {
		copy(table.rows[:], rows)
		table.count = len(rows)
	}
	return table.rows[:table.count]
}

// The gameplay bindings a fresh install starts with. Copy them (see
// bindings_clone) before letting the player change any.
default_bindings :: proc() -> []Binding {
	if default_table.count > 0 {
		return default_table.rows[:default_table.count]
	}
	rows := [?]Binding {
		// Keyboard and mouse.
		{.Move_Forward, Key.W, 1},
		{.Move_Right, Key.A, -1},
		{.Move_Forward, Key.S, -1},
		{.Move_Right, Key.D, 1},
		{.Fly_Up, Key.E, 1},
		{.Fly_Up, Key.Q, -1},
		{.Fly_Up, Key.Space, 1},
		{.Fly_Up, Key.Ctrl, -1},
		{.Look_Hold, Mouse_Button.Right, 1},
		{.Fast, Key.Shift, 1},
		{.Swing, Mouse_Button.Left, 1},
		{.Swing, Key.Space, 1},
		{.Toggle_Mode, Key.Tab, 1},
		{.Regenerate, Key.R, 1},
		{.Reload_Config, Key.F5, 1},
		{.Reset_Camera, Key.Home, 1},
		// Gamepad alternatives.
		{.Move_Right, Pad_Axis.Left_X, 1},
		{.Move_Forward, Pad_Axis.Left_Y, -1},
		{.Fly_Up, Pad_Axis.Right_Trigger, 1},
		{.Fly_Up, Pad_Axis.Left_Trigger, -1},
		{.Fast, Pad_Button.Left_Stick, 1},
		{.Swing, Pad_Button.West, 1},
		{.Swing, Pad_Button.Right_Shoulder, 1},
		{.Toggle_Mode, Pad_Button.North, 1},
		{.Regenerate, Pad_Button.Back, 1},
		{.Reset_Camera, Pad_Button.Right_Stick, 1},
	}
	return table_fill(&default_table, rows[:])
}

// Bindings that are not offered for rebinding: looking and zooming with the
// mouse or right stick, pausing, and finding one's way round the menus.
fixed_bindings :: proc() -> []Binding {
	if fixed_table.count > 0 {
		return fixed_table.rows[:fixed_table.count]
	}
	rows := [?]Binding {
		{.Look_X, Mouse_Axis.Move_X, 1},
		{.Look_Y, Mouse_Axis.Move_Y, 1},
		{.Zoom, Mouse_Axis.Wheel, 1},
		{.Look_X, Pad_Axis.Right_X, STICK_LOOK_RATE},
		{.Look_Y, Pad_Axis.Right_Y, STICK_LOOK_RATE},
		{.Zoom, Pad_Button.Dpad_Up, PAD_ZOOM_RATE},
		{.Zoom, Pad_Button.Dpad_Down, -PAD_ZOOM_RATE},
		{.Pause, Key.Escape, 1},
		{.Pause, Pad_Button.Start, 1},
		{.Menu_Up, Key.Up, 1},
		{.Menu_Up, Key.W, 1},
		{.Menu_Up, Pad_Button.Dpad_Up, 1},
		{.Menu_Up, Pad_Axis.Left_Y, -1},
		{.Menu_Down, Key.Down, 1},
		{.Menu_Down, Key.S, 1},
		{.Menu_Down, Pad_Button.Dpad_Down, 1},
		{.Menu_Down, Pad_Axis.Left_Y, 1},
		{.Menu_Left, Key.Left, 1},
		{.Menu_Left, Key.A, 1},
		{.Menu_Left, Pad_Button.Dpad_Left, 1},
		{.Menu_Left, Pad_Axis.Left_X, -1},
		{.Menu_Right, Key.Right, 1},
		{.Menu_Right, Key.D, 1},
		{.Menu_Right, Pad_Button.Dpad_Right, 1},
		{.Menu_Right, Pad_Axis.Left_X, 1},
		{.Menu_Confirm, Key.Enter, 1},
		{.Menu_Confirm, Key.Space, 1},
		{.Menu_Confirm, Pad_Button.South, 1},
		{.Menu_Back, Key.Escape, 1},
		{.Menu_Back, Key.Backspace, 1},
		{.Menu_Back, Pad_Button.East, 1},
	}
	return table_fill(&fixed_table, rows[:])
}