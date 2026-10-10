package assets

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "vendor:cgltf"
import stbi "vendor:stb/image"

// A skinned character, animated on the CPU: every frame the bind-pose
// vertices are blended through the joint matrices into plain `Vertex` data.

MAX_INFLUENCES :: 4

Skinned_Vertex :: struct {
	pos:     [3]f32, // bind pose
	normal:  [3]f32,
	uv:      [2]f32,
	joints:  [MAX_INFLUENCES]u16,
	weights: [MAX_INFLUENCES]f32,
}

Transform :: struct {
	translation: [3]f32,
	rotation:    [4]f32, // quaternion, xyzw
	scale:       [3]f32,
}

Joint :: struct {
	name:         string,
	parent:       int, // index into Character.joints, -1 for a root
	rest:         Transform,
	base:         matrix[4, 4]f32, // world matrix of a root joint's non-joint parent
	inverse_bind: matrix[4, 4]f32,
}

Character :: struct {
	vertices:   []Skinned_Vertex,
	indices:    []u32,
	body_indices: int, // indices before this belong to the character itself, the rest to attachments
	joints:     []Joint,
	texture:    Image, // owned by stb_image; release with character_destroy_texture
	bounds_min: [3]f32, // of the bind pose
	bounds_max: [3]f32,
}

Track :: struct {
	translation_times: []f32,
	translations:      [][3]f32,
	rotation_times:    []f32,
	rotations:         [][4]f32,
	scale_times:       []f32,
	scales:            [][3]f32,
}

// One animation, already matched to a character's joints by name.
Clip :: struct {
	name:     string,
	duration: f32,
	tracks:   []Track, // one per joint; empty tracks keep the rest pose
}

@(private = "file")
matrix_from_columns :: proc(m: [16]f32) -> matrix[4, 4]f32 {
	return transmute(matrix[4, 4]f32)m
}

transform_matrix :: proc(t: Transform) -> matrix[4, 4]f32 {
	x, y, z, w := t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w
	s := t.scale
	return matrix[4, 4]f32{
		(1 - 2 * (y * y + z * z)) * s.x, (2 * (x * y - z * w)) * s.y, (2 * (x * z + y * w)) * s.z, t.translation.x,
		(2 * (x * y + z * w)) * s.x, (1 - 2 * (x * x + z * z)) * s.y, (2 * (y * z - x * w)) * s.z, t.translation.y,
		(2 * (x * z - y * w)) * s.x, (2 * (y * z + x * w)) * s.y, (1 - 2 * (x * x + y * y)) * s.z, t.translation.z,
		0, 0, 0, 1,
	}
}

@(private = "file")
node_transform :: proc(node: ^cgltf.node) -> Transform {
	t := Transform {
		rotation = {0, 0, 0, 1},
		scale    = {1, 1, 1},
	}
	if node.has_translation do t.translation = node.translation
	if node.has_rotation do t.rotation = node.rotation
	if node.has_scale do t.scale = node.scale
	return t
}

// Loads the first skin of a .glb/.gltf together with every mesh bound to it
// and the first texture embedded in the file.
character_load :: proc(path: string, allocator := context.allocator) -> (ch: Character, err: string, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	options: cgltf.options
	data, result := cgltf.parse_file(options, cpath)
	if result != .success {
		return ch, fmt.tprintf("cannot parse %s: %v", path, result), false
	}
	defer cgltf.free(data)
	if result = cgltf.load_buffers(options, data, cpath); result != .success {
		return ch, fmt.tprintf("cannot load buffers of %s: %v", path, result), false
	}
	if len(data.skins) == 0 {
		return ch, fmt.tprintf("%s has no skin", path), false
	}
	skin := &data.skins[0]

	ch.joints = make([]Joint, len(skin.joints), allocator)
	for node, i in skin.joints {
		joint := &ch.joints[i]
		joint.name = strings.clone_from_cstring(node.name, allocator)
		joint.rest = node_transform(node)
		joint.parent = -1
		joint.base = 1
		joint.inverse_bind = 1
		for candidate, ci in skin.joints {
			if candidate == node.parent {
				joint.parent = ci
			}
		}
		if joint.parent < 0 && node.parent != nil {
			m: [16]f32
			cgltf.node_transform_world(node.parent, raw_data(m[:]))
			joint.base = matrix_from_columns(m)
		}
		if skin.inverse_bind_matrices != nil {
			m: [16]f32
			_ = cgltf.accessor_read_float(skin.inverse_bind_matrices, uint(i), raw_data(m[:]), 16)
			joint.inverse_bind = matrix_from_columns(m)
		}
	}

	vertices := make([dynamic]Skinned_Vertex, allocator)
	indices := make([dynamic]u32, allocator)
	ch.bounds_min = {max(f32), max(f32), max(f32)}
	ch.bounds_max = {min(f32), min(f32), min(f32)}
	for &node in data.nodes {
		if node.mesh == nil {
			continue
		}
		// A mesh without a skin that hangs off a joint (a helmet on the head)
		// is rigid: all of it follows that one joint.
		rigid_joint := -1
		rigid_world: matrix[4, 4]f32 = 1
		if node.skin == nil {
			for ancestor := node.parent; ancestor != nil && rigid_joint < 0; ancestor = ancestor.parent {
				for candidate, ci in skin.joints {
					if candidate == ancestor {
						rigid_joint = ci
					}
				}
			}
			if rigid_joint < 0 {
				continue
			}
			m: [16]f32
			cgltf.node_transform_world(&node, raw_data(m[:]))
			rigid_world = matrix_from_columns(m)
		} else if node.skin != skin {
			continue
		}
		for &prim in node.mesh.primitives {
			if prim.type != .triangles {
				continue
			}
			positions, normals, uvs, joints, weights: ^cgltf.accessor
			for attr in prim.attributes {
				if attr.index != 0 {
					continue
				}
				#partial switch attr.type {
				case .position:
					positions = attr.data
				case .normal:
					normals = attr.data
				case .texcoord:
					uvs = attr.data
				case .joints:
					joints = attr.data
				case .weights:
					weights = attr.data
				}
			}
			if positions == nil || (rigid_joint < 0 && (joints == nil || weights == nil)) {
				continue
			}
			base := u32(len(vertices))
			for i in 0 ..< positions.count {
				v := Skinned_Vertex {
					normal = {0, 1, 0},
				}
				_ = cgltf.accessor_read_float(positions, i, raw_data(v.pos[:]), 3)
				if normals != nil {
					_ = cgltf.accessor_read_float(normals, i, raw_data(v.normal[:]), 3)
				}
				if uvs != nil {
					_ = cgltf.accessor_read_float(uvs, i, raw_data(v.uv[:]), 2)
				}
				ids: [MAX_INFLUENCES]c.uint
				if rigid_joint >= 0 {
					// Into the pose the joints were bound in, tied to the one joint.
					p := rigid_world * [4]f32{v.pos.x, v.pos.y, v.pos.z, 1}
					n := rigid_world * [4]f32{v.normal.x, v.normal.y, v.normal.z, 0}
					v.pos, v.normal = p.xyz, n.xyz
					ids[0] = c.uint(rigid_joint)
					v.weights = {1, 0, 0, 0}
				} else {
					_ = cgltf.accessor_read_uint(joints, i, raw_data(ids[:]), MAX_INFLUENCES)
					_ = cgltf.accessor_read_float(weights, i, raw_data(v.weights[:]), MAX_INFLUENCES)
				}
				sum: f32
				for k in 0 ..< MAX_INFLUENCES {
					if int(ids[k]) >= len(ch.joints) {
						return ch, fmt.tprintf("%s: vertex refers to joint %d of %d", path, ids[k], len(ch.joints)), false
					}
					v.joints[k] = u16(ids[k])
					sum += v.weights[k]
				}
				if sum > 0 {
					v.weights /= sum
				} else {
					v.weights = {1, 0, 0, 0}
				}
				for axis in 0 ..< 3 {
					ch.bounds_min[axis] = min(ch.bounds_min[axis], v.pos[axis])
					ch.bounds_max[axis] = max(ch.bounds_max[axis], v.pos[axis])
				}
				append(&vertices, v)
			}
			if prim.indices != nil {
				for i in 0 ..< prim.indices.count {
					append(&indices, base + u32(cgltf.accessor_read_index(prim.indices, i)))
				}
			} else {
				for i in 0 ..< positions.count {
					append(&indices, base + u32(i))
				}
			}
		}
	}
	if len(indices) == 0 {
		return ch, fmt.tprintf("%s has no skinned triangles", path), false
	}
	ch.vertices = vertices[:]
	ch.indices = indices[:]
	ch.body_indices = len(indices)

	for &image in data.images {
		if image.buffer_view == nil {
			continue
		}
		bytes := cgltf.buffer_view_data(image.buffer_view)
		if bytes == nil {
			continue
		}
		w, h, channels: i32
		pixels := stbi.load_from_memory(bytes, i32(image.buffer_view.size), &w, &h, &channels, 4)
		if pixels != nil {
			ch.texture = {pixels = pixels[:int(w) * int(h) * 4], width = int(w), height = int(h)}
			break
		}
	}
	if ch.texture.pixels == nil {
		return ch, fmt.tprintf("%s has no embedded texture", path), false
	}
	return ch, "", true
}

character_destroy_texture :: proc(ch: ^Character) {
	image_destroy(&ch.texture)
}

// Loads the named animation from a file and matches its channels to the
// character's joints by name. Channels for unknown nodes are ignored.
clip_load :: proc(
	path: string,
	name: string,
	ch: ^Character,
	allocator := context.allocator,
) -> (
	clip: Clip,
	err: string,
	ok: bool,
) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	options: cgltf.options
	data, result := cgltf.parse_file(options, cpath)
	if result != .success {
		return clip, fmt.tprintf("cannot parse %s: %v", path, result), false
	}
	defer cgltf.free(data)
	if result = cgltf.load_buffers(options, data, cpath); result != .success {
		return clip, fmt.tprintf("cannot load buffers of %s: %v", path, result), false
	}

	read_times :: proc(acc: ^cgltf.accessor, allocator: runtime.Allocator) -> []f32 {
		out := make([]f32, acc.count, allocator)
		for i in 0 ..< acc.count {
			_ = cgltf.accessor_read_float(acc, i, raw_data(out[i:]), 1)
		}
		return out
	}

	for &animation in data.animations {
		if string(animation.name) != name {
			continue
		}
		clip.name = strings.clone(name, allocator)
		clip.tracks = make([]Track, len(ch.joints), allocator)
		for &channel in animation.channels {
			if channel.target_node == nil || channel.sampler == nil {
				continue
			}
			joint := -1
			for j, ji in ch.joints {
				if j.name == string(channel.target_node.name) {
					joint = ji
					break
				}
			}
			if joint < 0 {
				continue
			}
			sampler := channel.sampler
			if sampler.interpolation == .cubic_spline {
				return clip, fmt.tprintf("%s '%s': cubic spline animation is not supported", path, name), false
			}
			times := read_times(sampler.input, allocator)
			if len(times) > 0 {
				clip.duration = max(clip.duration, times[len(times) - 1])
			}
			track := &clip.tracks[joint]
			#partial switch channel.target_path {
			case .translation:
				track.translation_times = times
				track.translations = make([][3]f32, len(times), allocator)
				for &v, i in track.translations {
					_ = cgltf.accessor_read_float(sampler.output, uint(i), raw_data(v[:]), 3)
				}
			case .rotation:
				track.rotation_times = times
				track.rotations = make([][4]f32, len(times), allocator)
				for &v, i in track.rotations {
					_ = cgltf.accessor_read_float(sampler.output, uint(i), raw_data(v[:]), 4)
				}
			case .scale:
				track.scale_times = times
				track.scales = make([][3]f32, len(times), allocator)
				for &v, i in track.scales {
					_ = cgltf.accessor_read_float(sampler.output, uint(i), raw_data(v[:]), 3)
				}
			}
		}
		return clip, "", true
	}
	return clip, fmt.tprintf("%s has no animation named '%s'", path, name), false
}

// Finds the keyframe pair around `time` and how far between them it lies.
@(private = "file")
keyframe :: proc(times: []f32, time: f32) -> (a, b: int, t: f32) {
	last := len(times) - 1
	if time <= times[0] {
		return 0, 0, 0
	}
	if time >= times[last] {
		return last, last, 0
	}
	lo, hi := 0, last
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if times[mid] <= time {
			lo = mid
		} else {
			hi = mid
		}
	}
	span := times[hi] - times[lo]
	return lo, hi, span > 0 ? (time - times[lo]) / span : 0
}

// Local transform of every joint at `time` seconds into the clip. The clip
// loops, or with `loop` off holds its last frame. A nil clip gives the rest pose.
pose_sample :: proc(ch: ^Character, clip: ^Clip, time: f32, out: []Transform, loop := true) {
	time := time
	if clip != nil && clip.duration > 0 {
		if loop {
			time = time - clip.duration * f32(int(time / clip.duration))
			if time < 0 {
				time += clip.duration
			}
		} else {
			time = clamp(time, 0, clip.duration)
		}
	} else {
		time = 0
	}
	for joint, i in ch.joints {
		local := joint.rest
		if clip != nil {
			track := &clip.tracks[i]
			if len(track.translations) > 0 {
				a, b, t := keyframe(track.translation_times, time)
				local.translation = track.translations[a] + (track.translations[b] - track.translations[a]) * t
			}
			if len(track.scales) > 0 {
				a, b, t := keyframe(track.scale_times, time)
				local.scale = track.scales[a] + (track.scales[b] - track.scales[a]) * t
			}
			if len(track.rotations) > 0 {
				a, b, t := keyframe(track.rotation_times, time)
				qa, qb := track.rotations[a], track.rotations[b]
				// Take the short way round, then renormalise the straight blend.
				if qa.x * qb.x + qa.y * qb.y + qa.z * qb.z + qa.w * qb.w < 0 {
					qb = -qb
				}
				q := qa + (qb - qa) * t
				length := math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
				local.rotation = length > 0 ? q / length : qa
			}
		}
		out[i] = local
	}
}

// Turns local joint transforms into skinning matrices: bind space to model
// space, with `root` applied on top (pass the character's world matrix to get
// world-space vertices straight out of `skin`).
pose_matrices :: proc(ch: ^Character, pose: []Transform, root: matrix[4, 4]f32, out: []matrix[4, 4]f32) {
	done := make([]bool, len(ch.joints), context.temp_allocator)
	world :: proc(ch: ^Character, pose: []Transform, out: []matrix[4, 4]f32, done: []bool, i: int) -> matrix[4, 4]f32 {
		if !done[i] {
			joint := ch.joints[i]
			parent := joint.parent >= 0 ? world(ch, pose, out, done, joint.parent) : joint.base
			out[i] = parent * transform_matrix(pose[i])
			done[i] = true
		}
		return out[i]
	}
	for i in 0 ..< len(ch.joints) {
		world(ch, pose, out, done, i)
	}
	for &m, i in out {
		m = root * m * ch.joints[i].inverse_bind
	}
}

// Linear blend skinning into renderer vertices. `out` must hold len(ch.vertices).
skin :: proc(ch: ^Character, matrices: []matrix[4, 4]f32, out: []Vertex) {
	for v, i in ch.vertices {
		pos, normal: [4]f32
		p := [4]f32{v.pos.x, v.pos.y, v.pos.z, 1}
		n := [4]f32{v.normal.x, v.normal.y, v.normal.z, 0}
		for k in 0 ..< MAX_INFLUENCES {
			w := v.weights[k]
			if w == 0 {
				continue
			}
			m := matrices[v.joints[k]]
			pos += (m * p) * w
			normal += (m * n) * w
		}
		out[i] = {pos = pos.xyz, normal = normal.xyz, uv = v.uv}
	}
}

// Welds a rigid model onto one joint, so it follows that joint like a sword
// follows a hand. The model's origin lands on the joint and it must use the
// character's texture. Its triangles go after the character's own, which lets
// a caller draw the first `body_indices` indices to leave attachments out.
character_attach :: proc(
	ch: ^Character,
	vertices: []Vertex,
	indices: []u32,
	joint_name: string,
	allocator := context.allocator,
) -> (
	err: string,
	ok: bool,
) {
	joint := -1
	for j, i in ch.joints {
		if j.name == joint_name {
			joint = i
		}
	}
	if joint < 0 {
		return fmt.tprintf("the character has no joint named '%s'", joint_name), false
	}
	// Skinning multiplies by the inverse bind matrix first; going through its
	// inverse here leaves the model sitting in the joint's own space.
	bind := linalg.inverse(ch.joints[joint].inverse_bind)

	base := u32(len(ch.vertices))
	all_vertices := make([]Skinned_Vertex, len(ch.vertices) + len(vertices), allocator)
	copy(all_vertices, ch.vertices)
	for v, i in vertices {
		p := bind * [4]f32{v.pos.x, v.pos.y, v.pos.z, 1}
		n := bind * [4]f32{v.normal.x, v.normal.y, v.normal.z, 0}
		all_vertices[int(base) + i] = {
			pos     = p.xyz,
			normal  = n.xyz,
			uv      = v.uv,
			joints  = {0 = u16(joint)},
			weights = {0 = 1},
		}
	}
	all_indices := make([]u32, len(ch.indices) + len(indices), allocator)
	copy(all_indices, ch.indices)
	for index, i in indices {
		all_indices[len(ch.indices) + i] = base + index
	}
	ch.vertices = all_vertices
	ch.indices = all_indices
	return "", true
}