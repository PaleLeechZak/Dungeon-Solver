// CPU-side asset loading. Nothing in here talks to SDL or the GPU, so it can
// be exercised from tests.
package assets

import "base:runtime"
import "core:fmt"
import "core:strings"
import "vendor:cgltf"
import stbi "vendor:stb/image"

Vertex :: struct {
	pos:    [3]f32,
	normal: [3]f32,
	uv:     [2]f32,
}

// Where one model lives inside the library's shared vertex and index arrays.
// Indices are relative to `vertex_offset`.
Model :: struct {
	first_index:   u32,
	index_count:   u32,
	vertex_offset: i32,
	vertex_count:  u32,
	texture:       string, // path of the image the model's UVs refer to, "" if it names none
	bounds_min:   [3]f32,
	bounds_max:   [3]f32,
}

Library :: struct {
	vertices:  [dynamic]Vertex,
	indices:   [dynamic]u32,
	models:    map[string]Model, // keys are owned by the library
	allocator: runtime.Allocator,
}

library_init :: proc(lib: ^Library, allocator := context.allocator) {
	lib.vertices = make([dynamic]Vertex, allocator)
	lib.indices = make([dynamic]u32, allocator)
	lib.models = make(map[string]Model, allocator)
	lib.allocator = allocator
}

library_destroy :: proc(lib: ^Library) {
	for name, model in lib.models {
		delete(name, lib.allocator)
		delete(model.texture, lib.allocator)
	}
	delete(lib.vertices)
	delete(lib.indices)
	delete(lib.models)
}

// Loads a model by its id in the model manifest, with every mesh node
// flattened into model space.
// A name of the form "id:node" loads only that node's own mesh, in the
// node's local space, so a part such as a door leaf can be placed and turned
// on its own. Loading a model the library already holds does nothing.
library_load :: proc(lib: ^Library, manifest: ^Manifest, name: string) -> (err: string, ok: bool) {
	if name in lib.models {
		return "", true
	}
	only_node := ""
	if colon := strings.index_byte(name, ':'); colon >= 0 {
		only_node = name[colon + 1:]
	}
	file, listed := manifest.models[model_id(name)]
	if !listed {
		return fmt.tprintf("model '%s' is not in the model manifest", model_id(name)), false
	}
	dir := file[:max(strings.last_index_byte(file, '/'), 0)]
	path := strings.clone_to_cstring(file, context.temp_allocator)
	options: cgltf.options
	data, result := cgltf.parse_file(options, path)
	if result != .success {
		return fmt.tprintf("cannot parse %s: %v", path, result), false
	}
	defer cgltf.free(data)
	if result = cgltf.load_buffers(options, data, path); result != .success {
		return fmt.tprintf("cannot load buffers of %s: %v", path, result), false
	}

	model := Model {
		first_index   = u32(len(lib.indices)),
		vertex_offset = i32(len(lib.vertices)),
		bounds_min    = {max(f32), max(f32), max(f32)},
		bounds_max    = {min(f32), min(f32), min(f32)},
	}

	for &node in data.nodes {
		if node.mesh == nil {
			continue
		}
		m := [16]f32{0 = 1, 5 = 1, 10 = 1, 15 = 1} // column-major
		if only_node == "" {
			cgltf.node_transform_world(&node, raw_data(m[:]))
		} else if string(node.name) != only_node {
			continue
		}

		for &prim in node.mesh.primitives {
			if prim.type != .triangles {
				continue
			}
			positions, normals, uvs: ^cgltf.accessor
			for attr in prim.attributes {
				#partial switch attr.type {
				case .position:
					positions = attr.data
				case .normal:
					normals = attr.data
				case .texcoord:
					if attr.index == 0 {
						uvs = attr.data
					}
				}
			}
			if positions == nil {
				continue
			}

			base := u32(len(lib.vertices)) - u32(model.vertex_offset)
			for i in 0 ..< positions.count {
				p, n: [3]f32
				v: Vertex
				_ = cgltf.accessor_read_float(positions, i, raw_data(p[:]), 3)
				v.pos = {
					m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
					m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
					m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14],
				}
				if normals != nil {
					_ = cgltf.accessor_read_float(normals, i, raw_data(n[:]), 3)
					// The pack only translates its child nodes; the upper 3x3 is enough.
					v.normal = {
						m[0] * n.x + m[4] * n.y + m[8] * n.z,
						m[1] * n.x + m[5] * n.y + m[9] * n.z,
						m[2] * n.x + m[6] * n.y + m[10] * n.z,
					}
				} else {
					v.normal = {0, 1, 0}
				}
				if uvs != nil {
					_ = cgltf.accessor_read_float(uvs, i, raw_data(v.uv[:]), 2)
				}
				for axis in 0 ..< 3 {
					model.bounds_min[axis] = min(model.bounds_min[axis], v.pos[axis])
					model.bounds_max[axis] = max(model.bounds_max[axis], v.pos[axis])
				}
				append(&lib.vertices, v)
			}

			if prim.indices != nil {
				for i in 0 ..< prim.indices.count {
					append(&lib.indices, base + u32(cgltf.accessor_read_index(prim.indices, i)))
				}
			} else {
				for i in 0 ..< positions.count {
					append(&lib.indices, base + u32(i))
				}
			}
		}
	}

	model.index_count = u32(len(lib.indices)) - model.first_index
	model.vertex_count = u32(len(lib.vertices)) - u32(model.vertex_offset)
	if model.index_count == 0 {
		return fmt.tprintf("%s contains no triangles for model '%s'", path, name), false
	}
	if len(data.images) > 0 && data.images[0].uri != nil {
		model.texture = fmt.aprintf("%s/%s", dir, data.images[0].uri, allocator = lib.allocator)
	}
	lib.models[strings.clone(name, lib.allocator)] = model
	return "", true
}

Image :: struct {
	pixels: []u8, // RGBA8, top row first
	width:  int,
	height: int,
}

image_load :: proc(path: string) -> (img: Image, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	w, h, channels: i32
	data := stbi.load(cpath, &w, &h, &channels, 4)
	if data == nil {
		return {}, false
	}
	return {pixels = data[:int(w) * int(h) * 4], width = int(w), height = int(h)}, true
}

image_destroy :: proc(img: ^Image) {
	if img.pixels != nil {
		stbi.image_free(raw_data(img.pixels))
	}
	img^ = {}
}

// The vertices and (model-relative) indices of one loaded model.
library_mesh :: proc(lib: ^Library, name: string) -> (vertices: []Vertex, indices: []u32, ok: bool) {
	model := lib.models[name] or_return
	vertices = lib.vertices[model.vertex_offset:][:model.vertex_count]
	indices = lib.indices[model.first_index:][:model.index_count]
	return vertices, indices, true
}