package ui

import "core:testing"

@(test)
atlas_packs_rows_without_overlap :: proc(t: ^testing.T) {
	a: Atlas
	atlas_init(&a, 64, 64, context.temp_allocator)
	testing.expect_value(t, len(a.pixels), 64 * 64 * 4)
	// The solid block shapes are drawn from.
	testing.expect_value(t, a.pixels[3], 255)
	testing.expect(t, a.white_uv.x > 0 && a.white_uv.x < f32(WHITE_BLOCK) / 64)

	Rect :: struct {
		pos, size: [2]int,
	}
	placed := make([dynamic]Rect, context.temp_allocator)
	for i in 0 ..< 12 {
		size := [2]int{10 + i % 3 * 4, 8 + i % 4 * 3}
		pos, ok := atlas_reserve(&a, size.x, size.y)
		if !testing.expectf(t, ok, "rect %d did not fit", i) {
			break
		}
		testing.expect(t, pos.x >= 0 && pos.y >= 0 && pos.x + size.x <= 64 && pos.y + size.y <= 64)
		// Clear of the white block and of everything placed before it.
		testing.expect(t, pos.x >= WHITE_BLOCK || pos.y >= WHITE_BLOCK)
		for other in placed {
			apart := pos.x >= other.pos.x + other.size.x || other.pos.x >= pos.x + size.x || pos.y >= other.pos.y + other.size.y || other.pos.y >= pos.y + size.y
			testing.expect(t, apart, "two glyph cells overlap")
		}
		append(&placed, Rect{pos, size})
	}

	// Too big for what is left, or for the atlas at all.
	_, ok := atlas_reserve(&a, 60, 60)
	testing.expect(t, !ok)
	testing.expect(t, a.full)
	_, ok = atlas_reserve(&a, 100, 4)
	testing.expect(t, !ok)
}

@(test)
shapes_are_two_triangles :: proc(t: ^testing.T) {
	a: Atlas
	atlas_init(&a, 32, 32, context.temp_allocator)
	list: Draw_List
	draw_list_init(&list, &a, context.temp_allocator)

	draw_rect(&list, {10, 20}, {30, 40}, {1, 0, 0, 1})
	testing.expect_value(t, len(list.vertices), 6)
	lo, hi := [2]f32{1e9, 1e9}, [2]f32{-1e9, -1e9}
	for v in list.vertices {
		lo = {min(lo.x, v.pos.x), min(lo.y, v.pos.y)}
		hi = {max(hi.x, v.pos.x), max(hi.y, v.pos.y)}
		testing.expect_value(t, v.uv, a.white_uv)
		testing.expect_value(t, v.color, Color{1, 0, 0, 1})
	}
	testing.expect_value(t, lo, [2]f32{10, 20})
	testing.expect_value(t, hi, [2]f32{40, 60})

	// A diamond is a square on its corner: its points are `radius` from the
	// centre, straight up, right, down and left.
	clear(&list.vertices)
	draw_diamond(&list, {100, 100}, 10, 0, {1, 1, 1, 1})
	testing.expect_value(t, len(list.vertices), 6)
	top := list.vertices[0].pos
	testing.expect(t, abs(top.x - 100) < 1e-3 && abs(top.y - 90) < 1e-3)
	for v in list.vertices {
		d := v.pos - [2]f32{100, 100}
		testing.expect(t, abs(d.x * d.x + d.y * d.y - 100) < 1e-2)
	}
}

@(test)
bad_font_data_is_refused :: proc(t: ^testing.T) {
	a: Atlas
	atlas_init(&a, 32, 32, context.temp_allocator)
	_, ok := font_bake(&a, nil, 20, {'a'}, context.temp_allocator)
	testing.expect(t, !ok)
}
@(test)
images_go_into_the_atlas_as_they_are :: proc(t: ^testing.T) {
	a: Atlas
	atlas_init(&a, 64, 64, context.temp_allocator)
	pixels := make([]u8, 6 * 5 * 4, context.temp_allocator)
	for &p, i in pixels {
		p = u8(i % 251)
	}
	image, ok := atlas_add_image(&a, pixels, 6, 5)
	testing.expect(t, ok)
	testing.expect_value(t, image.size, [2]f32{6, 5})
	x, y := int(image.uv_min.x * 64 + 0.5), int(image.uv_min.y * 64 + 0.5)
	for row in 0 ..< 5 {
		for col in 0 ..< 6 * 4 {
			if !testing.expect_value(t, a.pixels[((y + row) * 64 + x) * 4 + col], pixels[row * 6 * 4 + col]) {
				return
			}
		}
	}
	_, ok = atlas_add_image(&a, pixels, 100, 100)
	testing.expect(t, !ok)
	_, ok = atlas_add_image(&a, pixels[:8], 6, 5)
	testing.expect(t, !ok)
}

@(test)
nine_slice_keeps_its_corners :: proc(t: ^testing.T) {
	a: Atlas
	atlas_init(&a, 256, 256, context.temp_allocator)
	pixels := make([]u8, 96 * 96 * 4, context.temp_allocator)
	image, _ := atlas_add_image(&a, pixels, 96, 96)
	list: Draw_List
	draw_list_init(&list, &a, context.temp_allocator)

	draw_nine_slice(&list, image, 32, {100, 50}, {400, 200}, {1, 1, 1, 1})
	testing.expect_value(t, len(list.vertices), 9 * 6)

	// The top left corner is drawn at its own size from the image's own corner.
	corner := list.vertices[0:6]
	testing.expect_value(t, corner[0].pos, [2]f32{100, 50})
	testing.expect_value(t, corner[2].pos, [2]f32{132, 82})
	testing.expect_value(t, corner[0].uv, image.uv_min)
	third := (image.uv_max - image.uv_min) / 3
	testing.expect(t, abs(corner[2].uv.x - (image.uv_min.x + third.x)) < 1e-6)

	// Everything stays inside the rectangle asked for and inside the image.
	lo, hi := [2]f32{1e9, 1e9}, [2]f32{-1e9, -1e9}
	for v in list.vertices {
		lo = {min(lo.x, v.pos.x), min(lo.y, v.pos.y)}
		hi = {max(hi.x, v.pos.x), max(hi.y, v.pos.y)}
		testing.expect(t, v.uv.x >= image.uv_min.x - 1e-6 && v.uv.x <= image.uv_max.x + 1e-6)
		testing.expect(t, v.uv.y >= image.uv_min.y - 1e-6 && v.uv.y <= image.uv_max.y + 1e-6)
	}
	testing.expect_value(t, lo, [2]f32{100, 50})
	testing.expect_value(t, hi, [2]f32{500, 250})

	// The middle stretches: its quad spans everything between the corners.
	middle := list.vertices[4 * 6:][:6]
	testing.expect_value(t, middle[0].pos, [2]f32{132, 82})
	testing.expect_value(t, middle[2].pos, [2]f32{468, 218})

	// Too small for two corners: they shrink to meet, nothing is drawn inside out.
	clear(&list.vertices)
	draw_nine_slice(&list, image, 32, {0, 0}, {40, 300}, {1, 1, 1, 1})
	for v in list.vertices {
		testing.expect(t, v.pos.x >= 0 && v.pos.x <= 40)
	}
	clear(&list.vertices)
	draw_nine_slice(&list, image, 32, {0, 0}, {0, 100}, {1, 1, 1, 1})
	testing.expect_value(t, len(list.vertices), 0)
}

@(test)
dividers_stretch_but_keep_their_ornament :: proc(t: ^testing.T) {
	a: Atlas
	atlas_init(&a, 256, 256, context.temp_allocator)
	pixels := make([]u8, 192 * 44 * 4, context.temp_allocator)
	image, _ := atlas_add_image(&a, pixels, 192, 44)
	list: Draw_List
	draw_list_init(&list, &a, context.temp_allocator)

	draw_divider(&list, image, 48, {10, 20}, 300, {1, 1, 1, 1})
	testing.expect_value(t, len(list.vertices), 12)
	// The ornament is the last 48 pixels on the right, unstretched.
	cap := list.vertices[6:12]
	testing.expect_value(t, cap[0].pos.x, 262)
	testing.expect_value(t, cap[2].pos.x, 310)
	testing.expect_value(t, cap[2].uv.x, image.uv_max.x)

	// Mirrored, it leads from the left and the picture runs backwards.
	clear(&list.vertices)
	draw_divider(&list, image, 48, {10, 20}, 300, {1, 1, 1, 1}, flip_x = true)
	cap = list.vertices[0:6]
	testing.expect_value(t, cap[0].pos.x, 10)
	testing.expect_value(t, cap[2].pos.x, 58)
	testing.expect_value(t, cap[0].uv.x, image.uv_max.x)

	clear(&list.vertices)
	draw_image(&list, image, {0, 0}, {192, 44}, {1, 1, 1, 1}, flip_x = true)
	testing.expect_value(t, list.vertices[0].uv.x, image.uv_max.x)
}