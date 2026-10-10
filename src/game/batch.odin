package game

import "base:intrinsics"
import "base:runtime"
import "core:fmt"

import "../assets"
import "../dungeon"

// Per-instance vertex data; must match locations 3-7 of tile.vert.hlsl.
Instance :: struct {
	model: [16]f32, // column-major
	tint:  [4]f32, // rgb multiplies the colour; a pushes it towards white (0 = not at all)
}

// All instances of one model, drawn with a single call.
Batch :: struct {
	model:          assets.Model,
	first_instance: u32,
	count:          u32,
}

// Groups tiles by model. Every batch owns one contiguous run of the returned
// instances, so a batch is a single instanced draw. Tiles whose model is not
// in the library are reported and left out.
build_instances :: proc(
	library: ^assets.Library,
	tiles: []dungeon.Tile,
	batches: ^[dynamic]Batch,
	allocator: runtime.Allocator,
) -> []Instance {
	clear(batches)
	batch_of := make(map[string]int, context.temp_allocator)
	total: u32
	for tile in tiles {
		index, seen := batch_of[tile.model]
		if !seen {
			index = -1
			if model, known := library.models[tile.model]; known {
				index = len(batches)
				append(batches, Batch{model = model})
			} else {
				fmt.eprintfln("model '%s' is not loaded, skipping its tiles", tile.model)
			}
			batch_of[tile.model] = index
		}
		if index >= 0 {
			batches[index].count += 1
			total += 1
		}
	}

	next: u32
	for &batch in batches {
		batch.first_instance = next
		next += batch.count
		batch.count = 0 // reused as the write cursor below
	}
	instances := make([]Instance, total, allocator)
	for tile in tiles {
		index := batch_of[tile.model]
		if index < 0 {
			continue
		}
		batch := &batches[index]
		instances[batch.first_instance + batch.count] = {
			model = intrinsics.matrix_flatten(dungeon.tile_matrix(tile)),
			tint  = {tile.tint.r, tile.tint.g, tile.tint.b, 0},
		}
		batch.count += 1
	}
	return instances
}

// Instance data for skinned characters. Their vertices are already in world
// space, so every instance is untransformed; all that varies is how strongly
// each one is flashing white from a hit just taken.
flash_instances :: proc(flash: []f32, count: int, allocator: runtime.Allocator) -> []Instance {
	instances := make([]Instance, count, allocator)
	for &instance, i in instances {
		instance = {
			model = {0 = 1, 5 = 1, 10 = 1, 15 = 1},
			tint  = {1, 1, 1, i < len(flash) ? clamp(flash[i], 0, 1) : 0},
		}
	}
	return instances
}