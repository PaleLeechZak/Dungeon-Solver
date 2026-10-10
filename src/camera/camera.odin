// Free-fly inspection camera. Pure maths: input arrives as plain numbers, so
// the package has no dependency on SDL and can be tested headless.
package camera

import "core:math"
import "core:math/linalg"

Camera :: struct {
	pos:             [3]f32,
	yaw:             f32, // radians; 0 looks down -Z (north), positive turns towards +X (east)
	pitch:           f32, // radians; positive looks up
	fov_y:           f32, // radians
	near, far:       f32,
	speed:           f32, // world units per second
	fast_multiplier: f32,
	sensitivity:     f32, // radians per pixel
}

Input :: struct {
	move:  [3]f32, // x strafes right, y rises along world up, z flies forward; each in [-1, 1]
	look:  [2]f32, // mouse travel in pixels; +x is right, +y is down
	fast:  bool,
	wheel: f32, // scroll steps; each one changes the speed by 15%
}

PITCH_LIMIT :: 89.0 * math.RAD_PER_DEG
MIN_SPEED :: 0.5
MAX_SPEED :: 500.0

make_camera :: proc(speed, fast_multiplier, sensitivity, fov_degrees: f32) -> Camera {
	return {
		fov_y = math.to_radians(fov_degrees),
		near = 0.1,
		far = 2000,
		speed = speed,
		fast_multiplier = fast_multiplier,
		sensitivity = sensitivity,
	}
}

forward :: proc(c: Camera) -> [3]f32 {
	cp := math.cos(c.pitch)
	return {math.sin(c.yaw) * cp, math.sin(c.pitch), -math.cos(c.yaw) * cp}
}

right :: proc(c: Camera) -> [3]f32 {
	return {math.cos(c.yaw), 0, math.sin(c.yaw)}
}

update :: proc(c: ^Camera, input: Input, dt: f32) {
	c.yaw += input.look.x * c.sensitivity
	c.pitch = clamp(c.pitch - input.look.y * c.sensitivity, -PITCH_LIMIT, PITCH_LIMIT)
	c.yaw = math.mod(c.yaw, math.TAU)

	if input.wheel != 0 {
		c.speed = clamp(c.speed * math.pow(1.15, input.wheel), MIN_SPEED, MAX_SPEED)
	}

	move := right(c^) * input.move.x + [3]f32{0, 1, 0} * input.move.y + forward(c^) * input.move.z
	if length := linalg.length(move); length > 1 {
		move /= length
	}
	speed := c.speed * (input.fast ? c.fast_multiplier : 1)
	c.pos += move * speed * dt
}

// Points the camera at a target from wherever it currently is.
look_at :: proc(c: ^Camera, target: [3]f32) {
	d := target - c.pos
	flat := math.sqrt(d.x * d.x + d.z * d.z)
	if flat < 1e-6 && abs(d.y) < 1e-6 {
		return
	}
	c.yaw = math.atan2(d.x, -d.z)
	c.pitch = clamp(math.atan2(d.y, flat), -PITCH_LIMIT, PITCH_LIMIT)
}

// World to view space. Right-handed: the camera looks down its own -Z.
view_matrix :: proc(c: Camera) -> matrix[4, 4]f32 {
	f := forward(c)
	r := linalg.normalize(linalg.cross(f, [3]f32{0, 1, 0}))
	u := linalg.cross(r, f)
	return matrix[4, 4]f32{
		r.x, r.y, r.z, -linalg.dot(r, c.pos),
		u.x, u.y, u.z, -linalg.dot(u, c.pos),
		-f.x, -f.y, -f.z, linalg.dot(f, c.pos),
		0, 0, 0, 1,
	}
}

// Perspective projection for SDL's GPU API: clip space has +Y up and depth
// running from 0 at the near plane to 1 at the far plane.
projection_matrix :: proc(c: Camera, aspect: f32) -> matrix[4, 4]f32 {
	f := 1 / math.tan(c.fov_y / 2)
	return matrix[4, 4]f32{
		f / aspect, 0, 0, 0,
		0, f, 0, 0,
		0, 0, c.far / (c.near - c.far), c.near * c.far / (c.near - c.far),
		0, 0, -1, 0,
	}
}

view_projection :: proc(c: Camera, aspect: f32) -> matrix[4, 4]f32 {
	return projection_matrix(c, aspect) * view_matrix(c)
}

// Third-person camera that circles a target, used while walking the knight.
Orbit :: struct {
	yaw:      f32, // direction the camera looks in, same convention as Camera.yaw
	pitch:    f32, // negative looks down on the target
	distance: f32,
}

ORBIT_MIN_PITCH :: -85.0 * math.RAD_PER_DEG
ORBIT_MAX_PITCH :: -8.0 * math.RAD_PER_DEG // stays above the floor
ORBIT_MIN_DISTANCE :: 3.0
ORBIT_MAX_DISTANCE :: 120.0

make_orbit :: proc(distance, pitch_degrees: f32) -> Orbit {
	return {
		pitch = clamp(math.to_radians(pitch_degrees), ORBIT_MIN_PITCH, ORBIT_MAX_PITCH),
		distance = clamp(distance, ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE),
	}
}

// Mouse travel swings the camera round the target, the wheel moves it in and out.
orbit_update :: proc(o: ^Orbit, look: [2]f32, wheel: f32, sensitivity: f32) {
	o.yaw = math.mod(o.yaw + look.x * sensitivity, math.TAU)
	o.pitch = clamp(o.pitch - look.y * sensitivity, ORBIT_MIN_PITCH, ORBIT_MAX_PITCH)
	if wheel != 0 {
		o.distance = clamp(o.distance * math.pow(0.87, wheel), ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE)
	}
}

// Places the camera so that `target` sits in the middle of the view.
orbit_apply :: proc(c: ^Camera, o: Orbit, target: [3]f32) {
	c.yaw = o.yaw
	c.pitch = o.pitch
	c.pos = target - forward(c^) * o.distance
}

// Turns "forward/right on the stick" into a direction on the ground (world X
// and Z) for a view with the given yaw.
ground_direction :: proc(yaw: f32, right_amount, forward_amount: f32) -> [2]f32 {
	s, c := math.sin(yaw), math.cos(yaw)
	return [2]f32{c, s} * right_amount + [2]f32{s, -c} * forward_amount
}
// A place for the orbit camera to be: what it looks at and from where.
Shot :: struct {
	orbit:  Orbit,
	target: [3]f32,
}

// Slow out of the start and into the end: 0 at 0, 1 at 1, level at both.
smooth :: proc(t: f32) -> f32 {
	x := clamp(t, 0, 1)
	return x * x * (3 - 2 * x)
}

// The shot part of the way from one to another, for panning the camera from
// following one thing to framing another. `t` runs 0..1 and is eased, so the
// move starts and stops gently. The yaw takes the short way round.
shot_between :: proc(from, to: Shot, t: f32) -> Shot {
	// Exactly the ends at the ends, so a finished pan sits still rather than
	// trembling by a rounding error.
	if t <= 0 {
		return from
	}
	if t >= 1 {
		return to
	}
	s := smooth(t)
	turn := to.orbit.yaw - from.orbit.yaw
	turn -= math.TAU * math.round(turn / math.TAU)
	return {
		orbit = {
			yaw = from.orbit.yaw + turn * s,
			pitch = from.orbit.pitch + (to.orbit.pitch - from.orbit.pitch) * s,
			distance = from.orbit.distance + (to.orbit.distance - from.orbit.distance) * s,
		},
		target = from.target + (to.target - from.target) * s,
	}
}

// Points the camera along a shot.
shot_apply :: proc(c: ^Camera, shot: Shot) {
	orbit_apply(c, shot.orbit, shot.target)
}