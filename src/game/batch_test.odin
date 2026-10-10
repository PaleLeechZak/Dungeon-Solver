package game

import "core:testing"

import "../assets"
import "../dungeon"

// These tests never call main, create a window or touch the GPU.

@(test)
instances_are_grouped_by_model :: proc(t: ^testing.T) {
	library: assets.Library
	assets.library_init(&library, context.temp_allocator)
	library.models["wall"] = {first_index = 0, index_count = 30, vertex_offset = 0}
	library.models["floor"] = {first_index = 30, index_count = 6, vertex_offset = 20}

	tiles := []dungeon.Tile {
		{model = "floor", pos = {0, 0, 0}, scale = 1, tint = {1, 1, 1}},
		{model = "wall", pos = {4, 0, 0}, scale = 1, tint = {1, 0, 0}},
		{model = "ghost", pos = {9, 9, 9}, scale = 1, tint = {1, 1, 1}},
		{model = "floor", pos = {8, 0, 0}, scale = 1, tint = {1, 1, 1}},
		{model = "wall", pos = {12, 0, 0}, turns = 1, scale = 1, tint = {0, 1, 0}},
		{model = "floor", pos = {16, 0, 0}, scale = 1, tint = {1, 1, 1}},
	}
	batches := make([dynamic]Batch, context.temp_allocator)
	instances := build_instances(&library, tiles, &batches, context.temp_allocator)

	// The unknown model is dropped, everything else is kept.
	testing.expect_value(t, len(instances), 5)
	testing.expect_value(t, len(batches), 2)
	testing.expect_value(t, batches[0].model.index_count, 6)
	testing.expect_value(t, batches[0].first_instance, 0)
	testing.expect_value(t, batches[0].count, 3)
	testing.expect_value(t, batches[1].model.index_count, 30)
	testing.expect_value(t, batches[1].model.vertex_offset, 0)
	testing.expect_value(t, batches[1].first_instance, 3)
	testing.expect_value(t, batches[1].count, 2)

	// Translation is the last column; order inside a batch follows the tiles.
	testing.expect_value(t, instances[0].model[12], 0)
	testing.expect_value(t, instances[1].model[12], 8)
	testing.expect_value(t, instances[2].model[12], 16)
	testing.expect_value(t, instances[3].model[12], 4)
	testing.expect_value(t, instances[4].model[12], 12)
	testing.expect_value(t, instances[3].tint, [4]f32{1, 0, 0, 0})
	testing.expect_value(t, instances[4].tint, [4]f32{0, 1, 0, 0})

	// Unrotated tiles keep the identity basis in columns 0-2.
	testing.expect_value(t, instances[3].model[0], 1)
	testing.expect_value(t, instances[3].model[5], 1)
	testing.expect_value(t, instances[3].model[10], 1)
	testing.expect_value(t, instances[3].model[15], 1)
	// One turn sends the model's +X axis (column 0) to -Z.
	testing.expect(t, abs(instances[4].model[0]) < 1e-5)
	testing.expect(t, abs(instances[4].model[2] + 1) < 1e-5)
}

@(test)
rebuilding_replaces_the_batches :: proc(t: ^testing.T) {
	library: assets.Library
	assets.library_init(&library, context.temp_allocator)
	library.models["wall"] = {index_count = 30}

	batches := make([dynamic]Batch, context.temp_allocator)
	first := build_instances(&library, {{model = "wall", scale = 1}, {model = "wall", scale = 1}}, &batches, context.temp_allocator)
	testing.expect_value(t, len(first), 2)
	second := build_instances(&library, {{model = "wall", scale = 1}}, &batches, context.temp_allocator)
	testing.expect_value(t, len(second), 1)
	testing.expect_value(t, len(batches), 1)
	testing.expect_value(t, batches[0].count, 1)

	none := build_instances(&library, nil, &batches, context.temp_allocator)
	testing.expect_value(t, len(none), 0)
	testing.expect_value(t, len(batches), 0)
}

// The vertex layout handed to the pipeline is written out by hand.
@(test)
instance_layout_matches_the_shader :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Instance), 80)
	testing.expect_value(t, offset_of(Instance, tint), 64)
	testing.expect_value(t, size_of(assets.Vertex), 32)
	testing.expect_value(t, offset_of(assets.Vertex, normal), 12)
	testing.expect_value(t, offset_of(assets.Vertex, uv), 24)
}

@(test)
characters_flash_one_by_one :: proc(t: ^testing.T) {
	// Tiles never flash: the fourth tint component is the flash, not opacity.
	library: assets.Library
	assets.library_init(&library, context.temp_allocator)
	library.models["wall"] = {index_count = 30}
	batches := make([dynamic]Batch, context.temp_allocator)
	tiles := build_instances(&library, {{model = "wall", scale = 1, tint = {1, 1, 1}}}, &batches, context.temp_allocator)
	testing.expect_value(t, tiles[0].tint.a, 0)

	instances := flash_instances({0, 0.5, 7, -2}, 5, context.temp_allocator)
	testing.expect_value(t, len(instances), 5)
	testing.expect_value(t, instances[0].tint, [4]f32{1, 1, 1, 0})
	testing.expect_value(t, instances[1].tint, [4]f32{1, 1, 1, 0.5})
	testing.expect_value(t, instances[2].tint.a, 1) // clamped
	testing.expect_value(t, instances[3].tint.a, 0)
	testing.expect_value(t, instances[4].tint.a, 0) // no value given: no flash
	for instance in instances {
		// Their vertices are already where they belong.
		testing.expect_value(t, instance.model, [16]f32{0 = 1, 5 = 1, 10 = 1, 15 = 1})
	}
	testing.expect_value(t, len(flash_instances(nil, 0, context.temp_allocator)), 0)
}