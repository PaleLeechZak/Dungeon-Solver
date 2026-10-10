// 2D text and shapes for the heads-up display. Fonts are rasterised into one
// shared atlas with stb_truetype, and drawing appends plain triangles to a
// list. No SDL and no GPU in here: the renderer uploads the atlas once and
// the vertex list every frame.
package ui

import "base:runtime"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import stbtt "vendor:stb/truetype"

Vertex :: struct {
	pos:   [2]f32, // pixels, origin top left, +Y down
	uv:    [2]f32,
	color: [4]f32,
}

Color :: [4]f32

// One RGBA8 image holding every glyph of every font: white, with the glyph's
// coverage as alpha. The top left corner is a solid block, so flat shapes can
// be drawn with the same texture.
Atlas :: struct {
	width, height: int,
	pixels:        []u8,
	pen:           [2]int, // where the next glyph goes
	row_height:    int,
	white_uv:      [2]f32,
	full:          bool, // a glyph did not fit
}

WHITE_BLOCK :: 4
PADDING :: 1

atlas_init :: proc(a: ^Atlas, width, height: int, allocator := context.allocator) {
	a^ = {
		width  = width,
		height = height,
		pixels = make([]u8, width * height * 4, allocator),
	}
	for y in 0 ..< WHITE_BLOCK {
		for x in 0 ..< WHITE_BLOCK {
			i := (y * width + x) * 4
			a.pixels[i + 0] = 255
			a.pixels[i + 1] = 255
			a.pixels[i + 2] = 255
			a.pixels[i + 3] = 255
		}
	}
	a.white_uv = {f32(WHITE_BLOCK) / 2 / f32(width), f32(WHITE_BLOCK) / 2 / f32(height)}
	a.pen = {WHITE_BLOCK + PADDING, 0}
	a.row_height = WHITE_BLOCK
}

// Reserves a w x h rectangle, filling rows left to right, top to bottom.
@(private)
atlas_reserve :: proc(a: ^Atlas, w, h: int) -> (pos: [2]int, ok: bool) {
	if a.pen.x + w + PADDING > a.width {
		a.pen = {0, a.pen.y + a.row_height + PADDING}
		a.row_height = 0
	}
	if w + PADDING > a.width || a.pen.y + h + PADDING > a.height {
		a.full = true
		return {}, false
	}
	pos = a.pen
	a.pen.x += w + PADDING
	a.row_height = max(a.row_height, h)
	return pos, true
}

Glyph :: struct {
	uv_min, uv_max: [2]f32,
	size:           [2]f32, // of the bitmap, pixels
	offset:         [2]f32, // from the pen position on the baseline to the bitmap's top left
	advance:        f32,
}

Font :: struct {
	size:     f32, // pixel height it was rasterised at
	ascent:   f32, // baseline to top of line, positive
	descent:  f32, // baseline to bottom of line, positive
	line_gap: f32,
	glyphs:   map[rune]Glyph,
}

line_height :: proc(f: ^Font) -> f32 {
	return f.ascent + f.descent + f.line_gap
}

// Rasterises the given characters of a TrueType/OpenType font into the atlas.
// Characters the font does not have are left out.
font_bake :: proc(
	atlas: ^Atlas,
	data: []byte,
	pixel_height: f32,
	runes: []rune,
	allocator := context.allocator,
) -> (
	font: Font,
	ok: bool,
) {
	info: stbtt.fontinfo
	if len(data) == 0 || !stbtt.InitFont(&info, raw_data(data), stbtt.GetFontOffsetForIndex(raw_data(data), 0)) {
		return {}, false
	}
	scale := stbtt.ScaleForPixelHeight(&info, pixel_height)
	ascent, descent, gap: i32
	stbtt.GetFontVMetrics(&info, &ascent, &descent, &gap)
	font = {
		size     = pixel_height,
		ascent   = f32(ascent) * scale,
		descent  = -f32(descent) * scale,
		line_gap = f32(gap) * scale,
		glyphs   = make(map[rune]Glyph, allocator),
	}

	scratch := make([dynamic]u8, context.temp_allocator)
	for r in runes {
		if r in font.glyphs || stbtt.FindGlyphIndex(&info, r) == 0 {
			continue
		}
		advance, bearing: i32
		stbtt.GetCodepointHMetrics(&info, r, &advance, &bearing)
		x0, y0, x1, y1: i32
		stbtt.GetCodepointBitmapBox(&info, r, scale, scale, &x0, &y0, &x1, &y1)
		w, h := int(x1 - x0), int(y1 - y0)
		glyph := Glyph {
			advance = f32(advance) * scale,
			offset  = {f32(x0), f32(y0)},
			size    = {f32(w), f32(h)},
		}
		if w > 0 && h > 0 {
			pos, fits := atlas_reserve(atlas, w, h)
			if !fits {
				return font, false
			}
			resize(&scratch, w * h)
			stbtt.MakeCodepointBitmap(&info, raw_data(scratch), i32(w), i32(h), i32(w), scale, scale, r)
			for y in 0 ..< h {
				for x in 0 ..< w {
					i := ((pos.y + y) * atlas.width + pos.x + x) * 4
					atlas.pixels[i + 0] = 255
					atlas.pixels[i + 1] = 255
					atlas.pixels[i + 2] = 255
					atlas.pixels[i + 3] = scratch[y * w + x]
				}
			}
			glyph.uv_min = {f32(pos.x) / f32(atlas.width), f32(pos.y) / f32(atlas.height)}
			glyph.uv_max = {f32(pos.x + w) / f32(atlas.width), f32(pos.y + h) / f32(atlas.height)}
		}
		font.glyphs[r] = glyph
	}
	return font, true
}

// Reads a Kenney `*_characters.txt`: one "name: <character>" per line, where
// the character is the private-use code point the icon sits on in the font.
glyph_map_parse :: proc(text: string, allocator := context.allocator) -> map[string]rune {
	out := make(map[string]rune, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		name := strings.trim_space(line[:colon])
		value := strings.trim_space(line[colon + 1:])
		if name == "" || value == "" {
			continue
		}
		r, _ := utf8.decode_rune_in_string(value)
		if r == utf8.RUNE_ERROR {
			continue
		}
		out[strings.clone(name, allocator)] = r
	}
	return out
}

Draw_List :: struct {
	vertices: [dynamic]Vertex,
	white_uv: [2]f32,
}

draw_list_init :: proc(list: ^Draw_List, atlas: ^Atlas, allocator: runtime.Allocator) {
	list.vertices = make([dynamic]Vertex, allocator)
	list.white_uv = atlas.white_uv
}

// Two triangles from four corners given in order round the quad.
push_quad :: proc(list: ^Draw_List, p: [4][2]f32, uv: [4][2]f32, color: Color) {
	for i in ([6]int{0, 1, 2, 0, 2, 3}) {
		append(&list.vertices, Vertex{pos = p[i], uv = uv[i], color = color})
	}
}

draw_rect :: proc(list: ^Draw_List, pos, size: [2]f32, color: Color) {
	w := list.white_uv
	push_quad(list, {pos, pos + {size.x, 0}, pos + size, pos + {0, size.y}}, {w, w, w, w}, color)
}

// A square standing on its corner, turned by `angle` radians.
draw_diamond :: proc(list: ^Draw_List, centre: [2]f32, radius: f32, angle: f32, color: Color) {
	w := list.white_uv
	corners: [4][2]f32
	for &corner, i in corners {
		a := angle + f32(i) * (math.PI / 2)
		corner = centre + [2]f32{math.sin(a), -math.cos(a)} * radius
	}
	push_quad(list, corners, {w, w, w, w}, color)
}

@(private)
push_glyph :: proc(list: ^Draw_List, g: Glyph, top_left: [2]f32, color: Color) {
	if g.size.x <= 0 || g.size.y <= 0 {
		return
	}
	a, b := top_left, top_left + g.size
	push_quad(
		list,
		{a, {b.x, a.y}, b, {a.x, b.y}},
		{g.uv_min, {g.uv_max.x, g.uv_min.y}, g.uv_max, {g.uv_min.x, g.uv_max.y}},
		color,
	)
}

// Draws one line of text with its top at pos.y and returns its width.
// Characters missing from the font are skipped.
draw_text :: proc(list: ^Draw_List, font: ^Font, text: string, pos: [2]f32, color: Color) -> f32 {
	pen := pos.x
	baseline := pos.y + font.ascent
	for r in text {
		g, found := font.glyphs[r]
		if !found {
			continue
		}
		// Whole pixels keep the glyph edges crisp.
		push_glyph(list, g, {math.round(pen + g.offset.x), math.round(baseline + g.offset.y)}, color)
		pen += g.advance
	}
	return pen - pos.x
}

measure_text :: proc(font: ^Font, text: string) -> (width: f32) {
	for r in text {
		if g, found := font.glyphs[r]; found {
			width += g.advance
		}
	}
	return
}

// Draws an icon centred in a box whose top left is `pos`, as wide as the icon
// and `height` tall. Returns the icon's width, 0 when the font lacks it.
draw_icon :: proc(list: ^Draw_List, font: ^Font, icon: rune, pos: [2]f32, height: f32, color: Color) -> f32 {
	g, found := font.glyphs[icon]
	if !found {
		return 0
	}
	push_glyph(list, g, {math.round(pos.x), math.round(pos.y + (height - g.size.y) / 2)}, color)
	return g.size.x
}

// A picture copied into the atlas, e.g. a panel from a UI kit.
Image :: struct {
	uv_min, uv_max: [2]f32,
	size:           [2]f32, // pixels
}

// Copies RGBA pixels into the atlas as they are, colour included.
atlas_add_image :: proc(a: ^Atlas, pixels: []u8, width, height: int) -> (image: Image, ok: bool) {
	if width <= 0 || height <= 0 || len(pixels) < width * height * 4 {
		return {}, false
	}
	pos := atlas_reserve(a, width, height) or_return
	for y in 0 ..< height {
		row := pixels[y * width * 4:][:width * 4]
		copy(a.pixels[((pos.y + y) * a.width + pos.x) * 4:], row)
	}
	return {
			uv_min = {f32(pos.x) / f32(a.width), f32(pos.y) / f32(a.height)},
			uv_max = {f32(pos.x + width) / f32(a.width), f32(pos.y + height) / f32(a.height)},
			size = {f32(width), f32(height)},
		},
		true
}

// One rectangle of the screen filled with one rectangle of the atlas.
@(private)
push_rect :: proc(list: ^Draw_List, a, b: [2]f32, uv_a, uv_b: [2]f32, color: Color) {
	if b.x <= a.x || b.y <= a.y {
		return
	}
	push_quad(list, {a, {b.x, a.y}, b, {a.x, b.y}}, {uv_a, {uv_b.x, uv_a.y}, uv_b, {uv_a.x, uv_b.y}}, color)
}

// Draws an image stretched over a rectangle, optionally mirrored left to right.
draw_image :: proc(list: ^Draw_List, image: Image, pos, size: [2]f32, color: Color, flip_x := false) {
	uv_a, uv_b := image.uv_min, image.uv_max
	if flip_x {
		uv_a.x, uv_b.x = uv_b.x, uv_a.x
	}
	push_rect(list, pos, pos + size, uv_a, uv_b, color)
}

// Draws a framed panel of any size from one small image: the four corners
// keep their size, the edges stretch one way and the middle both ways.
// `margin` is how wide the frame is in the image, in pixels; `scale` draws the frame smaller or larger than that, for rows too slim for full corners.
draw_nine_slice :: proc(list: ^Draw_List, image: Image, margin: f32, pos, size: [2]f32, color: Color, scale: f32 = 1) {
	if size.x <= 0 || size.y <= 0 {
		return
	}
	// A panel smaller than two corners squeezes the corners instead of overlapping them.
	m := [2]f32{min(margin * scale, size.x / 2), min(margin * scale, size.y / 2)}
	uv_margin := [2]f32{margin / image.size.x, margin / image.size.y} * (image.uv_max - image.uv_min)

	xs := [4]f32{pos.x, pos.x + m.x, pos.x + size.x - m.x, pos.x + size.x}
	ys := [4]f32{pos.y, pos.y + m.y, pos.y + size.y - m.y, pos.y + size.y}
	us := [4]f32{image.uv_min.x, image.uv_min.x + uv_margin.x, image.uv_max.x - uv_margin.x, image.uv_max.x}
	vs := [4]f32{image.uv_min.y, image.uv_min.y + uv_margin.y, image.uv_max.y - uv_margin.y, image.uv_max.y}
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			push_rect(list, {xs[col], ys[row]}, {xs[col + 1], ys[row + 1]}, {us[col], vs[row]}, {us[col + 1], vs[row + 1]}, color)
		}
	}
}

// Draws a rule of any length from a divider image: `cap` pixels at its right
// end (the ornament) keep their size and the rest stretches. Mirrored, the
// ornament sits at the left end instead.
draw_divider :: proc(list: ^Draw_List, image: Image, cap: f32, pos: [2]f32, length: f32, color: Color, flip_x := false) {
	c := min(cap, length)
	split := image.uv_max.x - c / image.size.x * (image.uv_max.x - image.uv_min.x)
	bottom := pos.y + image.size.y
	if !flip_x {
		push_rect(list, pos, {pos.x + length - c, bottom}, image.uv_min, {split, image.uv_max.y}, color)
		push_rect(list, {pos.x + length - c, pos.y}, {pos.x + length, bottom}, {split, image.uv_min.y}, image.uv_max, color)
	} else {
		push_rect(list, pos, {pos.x + c, bottom}, {image.uv_max.x, image.uv_min.y}, {split, image.uv_max.y}, color)
		push_rect(list, {pos.x + c, pos.y}, {pos.x + length, bottom}, {split, image.uv_min.y}, {image.uv_min.x, image.uv_max.y}, color)
	}
}