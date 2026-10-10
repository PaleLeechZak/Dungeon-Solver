package game

import "core:math"

import "../camera"
import "../dungeon"

// Where the knight camera should be this frame. Pure: the game loop applies
// the result, tests can ask for it without a window.

KNIGHT_FOCUS_HEIGHT :: 1.5 // world units above the floor: about the knight's chest

// The usual shot: circling the knight wherever the player has swung the camera.
follow_shot :: proc(p: ^dungeon.Play, orbit: camera.Orbit) -> camera.Shot {
	return {orbit = orbit, target = {p.pos.x, KNIGHT_FOCUS_HEIGHT, p.pos.y}}
}

// The close-up on the amulet over the knight's head: from the side the camera
// was already on, nearer and lower, looking up at it less steeply.
amulet_shot :: proc(p: ^dungeon.Play, cfg: ^dungeon.Config, orbit: camera.Orbit) -> camera.Shot {
	return {
		orbit = {
			yaw = orbit.yaw,
			pitch = clamp(math.to_radians(cfg.play.celebrate_pitch), camera.ORBIT_MIN_PITCH, camera.ORBIT_MAX_PITCH),
			// Pans in, never out: a player already zoomed right in stays there.
			distance = min(orbit.distance, max(cfg.play.celebrate_distance, camera.ORBIT_MIN_DISTANCE)),
		},
		target = {p.pos.x, dungeon.amulet_height(p.celebrated), p.pos.y},
	}
}

// The shot for the current state of play. From the moment the amulet is
// found the camera leaves the knight and pans to the amulet, following it up
// as it rises, and then holds on it: through the rest of the celebration and
// behind the victory screen.
knight_shot :: proc(p: ^dungeon.Play, cfg: ^dungeon.Config, orbit: camera.Orbit) -> camera.Shot {
	follow := follow_shot(p, orbit)
	if !p.has_amulet {
		return follow
	}
	close_up := amulet_shot(p, cfg, orbit)
	if cfg.play.celebrate_pan <= 0 {
		return close_up
	}
	return camera.shot_between(follow, close_up, p.celebrated / cfg.play.celebrate_pan)
}
