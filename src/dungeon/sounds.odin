package dungeon

import "core:math"

// Sound hooks. The simulation does not play anything; it records what just
// happened and where, and whoever runs it decides what that sounds like.
// Every in-game action that should be audible raises one of these.
Sound_Kind :: enum u8 {
	Knight_Step,
	Knight_Hurt,
	Knight_Death,
	Sword_Swing,
	Sword_Hit, // the blade lands on a skeleton
	Sword_Pickup,
	Key_Pickup,
	Chest_Open,
	Door_Open,
	Door_Locked, // walked up to a door without its key
	Skeleton_Notice, // an idle skeleton takes up the chase
	Skeleton_Step,
	Skeleton_Attack, // it starts its swing
	Skeleton_Hurt,
	Skeleton_Death,
	Dungeon_Explored,
	Amulet_Pickup,
	Game_Won, // the amulet is in hand
	Game_Lost, // the knight is dead
	// Raised by the menus rather than the simulation; they share the hook
	// table so that every sound the game makes is set up in one place.
	Menu_Open,
	Menu_Close,
	Menu_Move, // the highlight moved to another row
	Menu_Select,
	Menu_Back,
	Menu_Adjust, // a slider changed
	Menu_Bind, // a control was rebound, or all were reset
}

Sound_Event :: struct {
	kind: Sound_Kind,
	pos:  [2]f32, // world X and Z of whatever made the noise
}

MAX_SOUND_EVENTS :: 64

// Records an event. They pile up until sounds_clear; a full buffer drops the
// newest, which only happens if nobody is listening.
@(private)
sound_emit :: proc(p: ^Play, kind: Sound_Kind, pos: [2]f32) {
	if p.sound_count < MAX_SOUND_EVENTS {
		p.sound_events[p.sound_count] = {kind, pos}
		p.sound_count += 1
	}
}

// The events raised since the last sounds_clear, oldest first.
sounds_pending :: proc(p: ^Play) -> []Sound_Event {
	return p.sound_events[:p.sound_count]
}

sounds_clear :: proc(p: ^Play) {
	p.sound_count = 0
}

// Turns distance covered into footfalls: one event every `stride` units.
// `carried` holds the part of a stride left over between updates.
@(private)
sound_steps :: proc(p: ^Play, kind: Sound_Kind, carried: ^f32, from, to: [2]f32, stride: f32) {
	if stride <= 0 {
		return
	}
	d := to - from
	carried^ += math.sqrt(d.x * d.x + d.y * d.y)
	for carried^ >= stride {
		carried^ -= stride
		sound_emit(p, kind, to)
	}
}
