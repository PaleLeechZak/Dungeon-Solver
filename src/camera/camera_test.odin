package camera

import "core:math"
import "core:testing"

@(private = "file")
near3 :: proc(a, b: [3]f32, eps: f32 = 1e-4) -> bool {
	return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
}

@(private = "file")
project :: proc(c: Camera, aspect: f32, p: [3]f32) -> [3]f32 {
	clip := view_projection(c, aspect) * [4]f32{p.x, p.y, p.z, 1}
	return clip.xyz / clip.w
}

@(test)
axes_follow_yaw_and_pitch :: proc(t: ^testing.T) {
	c := make_camera(10, 4, 0.01, 60)
	testing.expect(t, near3(forward(c), {0, 0, -1}))
	testing.expect(t, near3(right(c), {1, 0, 0}))

	c.yaw = math.PI / 2
	testing.expect(t, near3(forward(c), {1, 0, 0}))
	testing.expect(t, near3(right(c), {0, 0, 1}))

	c.yaw = 0
	c.pitch = math.PI / 2
	testing.expect(t, near3(forward(c), {0, 1, 0}))
}

@(test)
movement_is_relative_to_the_view :: proc(t: ^testing.T) {
	c := make_camera(10, 4, 0.01, 60)
	update(&c, {move = {0, 0, 1}}, 0.5)
	testing.expect(t, near3(c.pos, {0, 0, -5}))

	update(&c, {move = {1, 0, 0}}, 0.5)
	testing.expect(t, near3(c.pos, {5, 0, -5}))

	update(&c, {move = {0, 1, 0}, fast = true}, 0.5)
	testing.expect(t, near3(c.pos, {5, 20, -5}))

	// Diagonal input does not move faster than straight input.
	c.pos = {}
	update(&c, {move = {1, 1, 1}}, 1)
	length := math.sqrt(c.pos.x * c.pos.x + c.pos.y * c.pos.y + c.pos.z * c.pos.z)
	testing.expect(t, abs(length - 10) < 1e-3)

	// Facing east, forward is +X.
	c.pos = {}
	c.yaw = math.PI / 2
	update(&c, {move = {0, 0, 1}}, 1)
	testing.expect(t, near3(c.pos, {10, 0, 0}))
}

@(test)
mouse_look_turns_and_clamps :: proc(t: ^testing.T) {
	c := make_camera(10, 4, 0.01, 60)
	update(&c, {look = {50, 0}}, 0)
	testing.expect(t, abs(c.yaw - 0.5) < 1e-5, "moving the mouse right turns right")
	testing.expect(t, forward(c).x > 0)

	update(&c, {look = {0, 20}}, 0)
	testing.expect(t, abs(c.pitch + 0.2) < 1e-5, "moving the mouse down looks down")

	update(&c, {look = {0, -100000}}, 0)
	testing.expect(t, abs(c.pitch - PITCH_LIMIT) < 1e-5)
	update(&c, {look = {0, 100000}}, 0)
	testing.expect(t, abs(c.pitch + PITCH_LIMIT) < 1e-5)
	testing.expect(t, near3(c.pos, {}), "looking around does not move the camera")
}

@(test)
wheel_changes_speed_within_limits :: proc(t: ^testing.T) {
	c := make_camera(10, 4, 0.01, 60)
	update(&c, {wheel = 1}, 0)
	testing.expect(t, abs(c.speed - 11.5) < 1e-4)
	update(&c, {wheel = -1}, 0)
	testing.expect(t, abs(c.speed - 10) < 1e-4)
	update(&c, {wheel = 1000}, 0)
	testing.expect_value(t, c.speed, f32(MAX_SPEED))
	update(&c, {wheel = -1000}, 0)
	testing.expect_value(t, c.speed, f32(MIN_SPEED))
}

@(test)
look_at_faces_the_target :: proc(t: ^testing.T) {
	c := make_camera(10, 4, 0.01, 60)
	c.pos = {10, 20, 30}
	target := [3]f32{-4, 0, 12}
	look_at(&c, target)

	d := target - c.pos
	length := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
	testing.expect(t, near3(forward(c), d / length))

	// The target lands in the middle of the screen.
	ndc := project(c, 16.0 / 9.0, target)
	testing.expect(t, abs(ndc.x) < 1e-3 && abs(ndc.y) < 1e-3)

	before := c
	look_at(&c, c.pos)
	testing.expect_value(t, c.yaw, before.yaw)
	testing.expect_value(t, c.pitch, before.pitch)
}

@(test)
view_matrix_looks_down_negative_z :: proc(t: ^testing.T) {
	c := make_camera(10, 4, 0.01, 60)
	c.pos = {3, 2, 5}
	c.yaw = 0.7
	c.pitch = -0.4
	view := view_matrix(c)

	ahead := c.pos + forward(c) * 6
	v := view * [4]f32{ahead.x, ahead.y, ahead.z, 1}
	testing.expect(t, near3(v.xyz, {0, 0, -6}))

	side := c.pos + right(c) * 2
	v = view * [4]f32{side.x, side.y, side.z, 1}
	testing.expect(t, near3(v.xyz, {2, 0, 0}))

	eye := view * [4]f32{c.pos.x, c.pos.y, c.pos.z, 1}
	testing.expect(t, near3(eye.xyz, {}))
}

@(test)
projection_maps_depth_to_zero_one :: proc(t: ^testing.T) {
	c := make_camera(10, 4, 0.01, 90)
	aspect: f32 = 2

	near := project(c, aspect, {0, 0, -c.near})
	far := project(c, aspect, {0, 0, -c.far})
	testing.expect(t, abs(near.z) < 1e-4)
	testing.expect(t, abs(far.z - 1) < 1e-4)

	mid := project(c, aspect, {0, 0, -50})
	testing.expect(t, mid.z > near.z && mid.z < far.z, "depth grows with distance")

	// With a 90 degree vertical field of view the frustum is as tall as it is deep.
	top := project(c, aspect, {0, 10, -10})
	testing.expect(t, abs(top.y - 1) < 1e-4, "+Y is up in clip space")
	edge := project(c, aspect, {20, 0, -10})
	testing.expect(t, abs(edge.x - 1) < 1e-4, "+X is right in clip space")
}

@(test)
orbit_keeps_the_target_centred :: proc(t: ^testing.T) {
	c := make_camera(10, 4, 0.01, 60)
	o := make_orbit(16, -50)
	target := [3]f32{20, 1.5, -12}
	orbit_apply(&c, o, target)

	d := c.pos - target
	testing.expect(t, abs(math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z) - 16) < 1e-3)
	testing.expect(t, c.pos.y > target.y, "the camera looks down from above")
	testing.expect(t, c.pos.z > target.z, "at yaw 0 the camera sits south of the target, looking north")
	ndc := project(c, 16.0 / 9.0, target)
	testing.expect(t, abs(ndc.x) < 1e-3 && abs(ndc.y) < 1e-3)

	// Still centred after swinging round and zooming.
	orbit_update(&o, {300, -40}, 2, 0.01)
	orbit_apply(&c, o, target)
	ndc = project(c, 16.0 / 9.0, target)
	testing.expect(t, abs(ndc.x) < 1e-3 && abs(ndc.y) < 1e-3)
	testing.expect(t, o.distance < 16, "scrolling up zooms in")
}

@(test)
orbit_stays_within_limits :: proc(t: ^testing.T) {
	o := make_orbit(1000, 45)
	testing.expect_value(t, o.distance, f32(ORBIT_MAX_DISTANCE))
	testing.expect_value(t, o.pitch, f32(ORBIT_MAX_PITCH))

	orbit_update(&o, {0, 100000}, 0, 0.01)
	testing.expect_value(t, o.pitch, f32(ORBIT_MIN_PITCH))
	orbit_update(&o, {0, -100000}, 0, 0.01)
	testing.expect_value(t, o.pitch, f32(ORBIT_MAX_PITCH))
	orbit_update(&o, {}, 1000, 0.01)
	testing.expect_value(t, o.distance, f32(ORBIT_MIN_DISTANCE))
	orbit_update(&o, {}, -1000, 0.01)
	testing.expect_value(t, o.distance, f32(ORBIT_MAX_DISTANCE))
}

@(test)
ground_direction_follows_the_view :: proc(t: ^testing.T) {
	near2 :: proc(a, b: [2]f32) -> bool {
		return abs(a.x - b.x) < 1e-4 && abs(a.y - b.y) < 1e-4
	}
	// Looking north: forward is -Z, right is +X.
	testing.expect(t, near2(ground_direction(0, 0, 1), {0, -1}))
	testing.expect(t, near2(ground_direction(0, 1, 0), {1, 0}))
	// Looking east: forward is +X, right is +Z (south).
	testing.expect(t, near2(ground_direction(math.PI / 2, 0, 1), {1, 0}))
	testing.expect(t, near2(ground_direction(math.PI / 2, 1, 0), {0, 1}))

	// It agrees with where the camera itself points.
	c := make_camera(10, 4, 0.01, 60)
	c.yaw = 1.1
	f := forward(c)
	testing.expect(t, near2(ground_direction(c.yaw, 0, 1), {f.x, f.z}))
}
@(test)
camera_pans_from_one_shot_to_another :: proc(t: ^testing.T) {
	follow := Shot{{yaw = 0.4, pitch = -0.9, distance = 16}, {10, 1.5, 20}}
	close_up := Shot{{yaw = 0.4, pitch = -0.3, distance = 6}, {10, 3.4, 20}}

	testing.expect_value(t, shot_between(follow, close_up, 0), follow)
	testing.expect_value(t, shot_between(follow, close_up, 1), close_up)
	// Past either end it holds, which is what keeps the camera on its subject
	// once the move is done.
	testing.expect_value(t, shot_between(follow, close_up, 5), close_up)
	testing.expect_value(t, shot_between(follow, close_up, -1), follow)

	// On the way, whatever it is aiming at is dead centre, and it closes in
	// without ever backing off or overshooting.
	c := make_camera(10, 4, 0.01, 60)
	previous := follow
	for step in 1 ..= 20 {
		shot := shot_between(follow, close_up, f32(step) / 20)
		shot_apply(&c, shot)
		ndc := project(c, 16.0 / 9.0, shot.target)
		testing.expect(t, abs(ndc.x) < 1e-3 && abs(ndc.y) < 1e-3)
		testing.expect(t, shot.orbit.distance <= previous.orbit.distance + 1e-5 && shot.orbit.distance >= close_up.orbit.distance - 1e-5)
		testing.expect(t, shot.target.y >= previous.target.y - 1e-5 && shot.target.y <= close_up.target.y + 1e-5)
		testing.expect(t, c.pos.y > shot.target.y, "the camera stays above what it looks at")
		previous = shot
	}

	// It eases: little happens at the very start and the very end.
	early := shot_between(follow, close_up, 0.1)
	middle := shot_between(follow, close_up, 0.5)
	late := shot_between(follow, close_up, 0.9)
	testing.expect(t, follow.orbit.distance - early.orbit.distance < 0.5)
	testing.expect(t, abs(middle.orbit.distance - 11) < 1e-3)
	testing.expect(t, late.orbit.distance - close_up.orbit.distance < 0.5)
	testing.expect_value(t, smooth(0), 0)
	testing.expect_value(t, smooth(1), 1)
	testing.expect_value(t, smooth(0.5), 0.5)

	// Turning takes the short way: from just short of a full turn to just past zero.
	a := Shot{{yaw = math.TAU - 0.1, pitch = -0.5, distance = 10}, {}}
	b := Shot{{yaw = 0.1, pitch = -0.5, distance = 10}, {}}
	half := shot_between(a, b, 0.5)
	testing.expect(t, abs(half.orbit.yaw - math.TAU) < 1e-4, "it should pass through zero, not swing back through half a turn")
}