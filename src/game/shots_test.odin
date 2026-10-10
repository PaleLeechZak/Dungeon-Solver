package game

import "core:math"
import "core:testing"

import "../camera"
import "../dungeon"

// Pure camera placement; no window involved.

@(private = "file")
near3 :: proc(a, b: [3]f32, eps: f32 = 1e-4) -> bool {
	return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
}

@(test)
camera_follows_the_knight_until_the_amulet_is_found :: proc(t: ^testing.T) {
	cfg := dungeon.config_default()
	orbit := camera.make_orbit(16, -50)
	orbit.yaw = 0.7
	p := dungeon.Play {
		pos = {40, 24},
	}

	shot := knight_shot(&p, &cfg, orbit)
	testing.expect_value(t, shot, follow_shot(&p, orbit))
	testing.expect(t, near3(shot.target, {40, KNIGHT_FOCUS_HEIGHT, 24}))
	testing.expect_value(t, shot.orbit, orbit)

	// The knight moves, the shot moves with it.
	p.pos = {44, 20}
	testing.expect(t, near3(knight_shot(&p, &cfg, orbit).target, {44, KNIGHT_FOCUS_HEIGHT, 20}))
}

@(test)
camera_pans_to_the_amulet_and_holds :: proc(t: ^testing.T) {
	cfg := dungeon.config_default()
	orbit := camera.make_orbit(16, -50)
	orbit.yaw = 0.7
	p := dungeon.Play {
		pos        = {40, 24},
		has_amulet = true,
	}
	cam := camera.make_camera(10, 4, 0.003, 60)
	centred :: proc(cam: ^camera.Camera, shot: camera.Shot, point: [3]f32) -> bool {
		camera.shot_apply(cam, shot)
		clip := camera.view_projection(cam^, 16.0 / 9.0) * [4]f32{point.x, point.y, point.z, 1}
		return abs(clip.x / clip.w) < 1e-3 && abs(clip.y / clip.w) < 1e-3
	}

	// The instant it is found nothing jumps: the pan starts from the shot
	// the player was already looking at.
	testing.expect_value(t, knight_shot(&p, &cfg, orbit), follow_shot(&p, orbit))

	// During the pan the camera closes in and comes down, steadily.
	previous := follow_shot(&p, orbit)
	for step in 1 ..= 10 {
		p.celebrated = cfg.play.celebrate_pan * f32(step) / 10
		shot := knight_shot(&p, &cfg, orbit)
		testing.expect(t, shot.orbit.distance <= previous.orbit.distance + 1e-5)
		testing.expect(t, shot.orbit.pitch >= previous.orbit.pitch - 1e-5, "the view gets shallower, not steeper")
		testing.expect(t, shot.target.y >= previous.target.y - 1e-5, "the aim rises from the knight's chest")
		testing.expect_value(t, shot.orbit.yaw, orbit.yaw) // from the side the player chose
		previous = shot
	}

	// When the pan is done the amulet itself is dead centre, close up.
	amulet := [3]f32{p.pos.x, dungeon.amulet_height(p.celebrated), p.pos.y}
	shot := knight_shot(&p, &cfg, orbit)
	testing.expect_value(t, shot, amulet_shot(&p, &cfg, orbit))
	testing.expect(t, near3(shot.target, amulet))
	testing.expect(t, centred(&cam, shot, amulet))
	testing.expect_value(t, shot.orbit.distance, cfg.play.celebrate_distance)
	testing.expect(t, abs(shot.orbit.pitch - math.to_radians(cfg.play.celebrate_pitch)) < 1e-5)
	testing.expect(t, cam.pos.y > 0.5, "the camera stays above the floor")

	// And it holds there: through the rest of the celebration, and after the
	// win, when the celebration clock has stopped for good.
	p.celebrated = cfg.play.celebrate_time
	held := knight_shot(&p, &cfg, orbit)
	testing.expect(t, centred(&cam, held, {p.pos.x, f32(dungeon.AMULET_LIFT_TO), p.pos.y}))
	testing.expect_value(t, held.orbit, shot.orbit)
	p.won = true
	testing.expect_value(t, knight_shot(&p, &cfg, orbit), held)

	// The pan never pulls the camera back: a player already closer stays put.
	near := orbit
	near.distance = 4
	testing.expect_value(t, knight_shot(&p, &cfg, near).orbit.distance, 4)

	// The default timings leave the camera on the amulet well before the win.
	testing.expect(t, cfg.play.celebrate_pan < cfg.play.celebrate_time)
	testing.expect(t, cfg.play.celebrate_pan >= dungeon.AMULET_LIFT_TIME, "the amulet has finished rising by the time the camera arrives")

	// No pan time: straight to the close-up.
	cfg.play.celebrate_pan = 0
	p.celebrated = 0
	p.won = false
	testing.expect_value(t, knight_shot(&p, &cfg, orbit), amulet_shot(&p, &cfg, orbit))
}