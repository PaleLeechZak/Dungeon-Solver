package game

import "core:fmt"
import "core:mem"
import "core:strings"
import sdl "vendor:sdl3"

import "../assets"
import "../camera"
import "../dungeon"
import "../ui"

// Built by shaders/compile.bat and baked into the executable.
Shader_Code :: struct {
	spirv, dxil, msl: []u8,
}

TILE_VERT := Shader_Code{#load("../../shaders/compiled/tile.vert.spv"), #load("../../shaders/compiled/tile.vert.dxil"), #load("../../shaders/compiled/tile.vert.msl")}
TILE_FRAG := Shader_Code{#load("../../shaders/compiled/tile.frag.spv"), #load("../../shaders/compiled/tile.frag.dxil"), #load("../../shaders/compiled/tile.frag.msl")}
UI_VERT := Shader_Code{#load("../../shaders/compiled/ui.vert.spv"), #load("../../shaders/compiled/ui.vert.dxil"), #load("../../shaders/compiled/ui.vert.msl")}
UI_FRAG := Shader_Code{#load("../../shaders/compiled/ui.frag.spv"), #load("../../shaders/compiled/ui.frag.dxil"), #load("../../shaders/compiled/ui.frag.msl")}

CLEAR_COLOR :: sdl.FColor{0.035, 0.03, 0.055, 1}

// A vertex buffer that is rewritten every frame, with the staging buffer the
// new contents travel through. Grows when it has to.
Stream :: struct {
	buffer:   ^sdl.GPUBuffer,
	transfer: ^sdl.GPUTransferBuffer,
	capacity: u32, // bytes
}

// One kind of skinned character. Every instance alive this frame is skinned
// on the CPU into world space and all of them are uploaded as one run of
// vertices; they share the index buffer and the texture. Each has its own
// entry in `instances`, which carries how strongly it is flashing.
Actor :: struct {
	vertices:     Stream,
	instances:    Stream,
	index_buffer: ^sdl.GPUBuffer,
	texture:      ^sdl.GPUTexture,
	vertex_count: int, // per instance
	index_count:  u32, // per instance
}

// What to draw of one actor this frame.
Actor_Draw :: struct {
	actor:     int,
	vertices:  []assets.Vertex, // instances * vertex_count, world space
	instances: int,
	indices:   int, // how many indices of each instance to draw; negative for all
	flash:     []f32, // per instance, 0..1 towards white; missing entries do not flash
}

Renderer :: struct {
	window:          ^sdl.Window,
	device:          ^sdl.GPUDevice,
	pipeline:        ^sdl.GPUGraphicsPipeline,
	ui_pipeline:     ^sdl.GPUGraphicsPipeline,
	sampler:         ^sdl.GPUSampler,
	texture:         ^sdl.GPUTexture, // for models that name no texture of their own
	textures:        map[string]^sdl.GPUTexture, // by assets.Model.texture
	library:         assets.Library,
	vertex_buffer:   ^sdl.GPUBuffer,
	index_buffer:    ^sdl.GPUBuffer,
	instance_buffer: ^sdl.GPUBuffer,

	batches:         [dynamic]Batch,
	actors:          [dynamic]Actor,
	ui_vertices:     Stream,
	ui_atlas:        ^sdl.GPUTexture,
	depth_format:    sdl.GPUTextureFormat,
	depth_texture:   ^sdl.GPUTexture,
	depth_size:      [2]u32,
}

renderer_init :: proc(r: ^Renderer, cfg: ^dungeon.Config, manifest: ^assets.Manifest) -> bool {
	if !sdl.Init({.VIDEO, .GAMEPAD}) {
		fmt.eprintfln("SDL_Init failed: %s", sdl.GetError())
		return false
	}
	title := strings.clone_to_cstring(cfg.window.title, context.temp_allocator)
	r.window = sdl.CreateWindow(title, i32(cfg.window.width), i32(cfg.window.height), {.RESIZABLE})
	if r.window == nil {
		fmt.eprintfln("SDL_CreateWindow failed: %s", sdl.GetError())
		return false
	}
	r.device = sdl.CreateGPUDevice({.SPIRV, .DXIL, .MSL}, ODIN_DEBUG, nil)
	if r.device == nil {
		fmt.eprintfln("SDL_CreateGPUDevice failed: %s", sdl.GetError())
		return false
	}
	if !sdl.ClaimWindowForGPUDevice(r.device, r.window) {
		fmt.eprintfln("SDL_ClaimWindowForGPUDevice failed: %s", sdl.GetError())
		return false
	}

	r.depth_format = .D16_UNORM
	for format in ([]sdl.GPUTextureFormat{.D32_FLOAT, .D24_UNORM}) {
		if sdl.GPUTextureSupportsFormat(r.device, format, .D2, {.DEPTH_STENCIL_TARGET}) {
			r.depth_format = format
			break
		}
	}

	assets.library_init(&r.library)
	r.batches = make([dynamic]Batch)
	r.actors = make([dynamic]Actor)
	r.textures = make(map[string]^sdl.GPUTexture)
	return create_pipelines(r) && create_texture(r, cfg) && renderer_sync_models(r, cfg, manifest)
}

renderer_destroy :: proc(r: ^Renderer) {
	if r.device != nil {
		for &actor in r.actors {
			stream_release(r.device, &actor.vertices)
			stream_release(r.device, &actor.instances)
			sdl.ReleaseGPUBuffer(r.device, actor.index_buffer)
			sdl.ReleaseGPUTexture(r.device, actor.texture)
		}
		stream_release(r.device, &r.ui_vertices)
		sdl.ReleaseGPUTexture(r.device, r.ui_atlas)
		sdl.ReleaseGPUTexture(r.device, r.depth_texture)
		sdl.ReleaseGPUTexture(r.device, r.texture)
		for _, texture in r.textures {
			sdl.ReleaseGPUTexture(r.device, texture)
		}
		sdl.ReleaseGPUSampler(r.device, r.sampler)

		sdl.ReleaseGPUBuffer(r.device, r.instance_buffer)
		sdl.ReleaseGPUBuffer(r.device, r.index_buffer)
		sdl.ReleaseGPUBuffer(r.device, r.vertex_buffer)
		sdl.ReleaseGPUGraphicsPipeline(r.device, r.ui_pipeline)
		sdl.ReleaseGPUGraphicsPipeline(r.device, r.pipeline)
		if r.window != nil {
			sdl.ReleaseWindowFromGPUDevice(r.device, r.window)
		}
		sdl.DestroyGPUDevice(r.device)
	}
	if r.window != nil {
		sdl.DestroyWindow(r.window)
	}
	sdl.Quit()
	assets.library_destroy(&r.library)
	delete(r.batches)
	delete(r.actors)
	delete(r.textures)
	r^ = {}
}

@(private = "file")
create_shader :: proc(
	device: ^sdl.GPUDevice,
	source: Shader_Code,
	stage: sdl.GPUShaderStage,
	samplers, uniform_buffers: u32,
) -> ^sdl.GPUShader {
	formats := sdl.GetGPUShaderFormats(device)
	info := sdl.GPUShaderCreateInfo {
		entrypoint          = "main",
		stage               = stage,
		num_samplers        = samplers,
		num_uniform_buffers = uniform_buffers,
	}
	code: []u8
	switch {
	case .SPIRV in formats:
		code = source.spirv
		info.format = {.SPIRV}
	case .DXIL in formats:
		code = source.dxil
		info.format = {.DXIL}
	case .MSL in formats:
		code = source.msl
		info.format = {.MSL}
		info.entrypoint = "main0"
	case:
		fmt.eprintln("the GPU backend accepts none of the compiled shader formats")
		return nil
	}
	info.code = raw_data(code)
	info.code_size = uint(len(code))
	shader := sdl.CreateGPUShader(device, info)
	if shader == nil {
		fmt.eprintfln("SDL_CreateGPUShader failed: %s", sdl.GetError())
	}
	return shader
}

@(private = "file")
create_pipelines :: proc(r: ^Renderer) -> bool {
	tile_vert := create_shader(r.device, TILE_VERT, .VERTEX, 0, 1)
	tile_frag := create_shader(r.device, TILE_FRAG, .FRAGMENT, 1, 0)
	ui_vert := create_shader(r.device, UI_VERT, .VERTEX, 0, 1)
	ui_frag := create_shader(r.device, UI_FRAG, .FRAGMENT, 1, 0)
	defer {
		// The pipelines keep what they need; nil is ignored.
		sdl.ReleaseGPUShader(r.device, tile_vert)
		sdl.ReleaseGPUShader(r.device, tile_frag)
		sdl.ReleaseGPUShader(r.device, ui_vert)
		sdl.ReleaseGPUShader(r.device, ui_frag)
	}
	if tile_vert == nil || tile_frag == nil || ui_vert == nil || ui_frag == nil {
		return false
	}
	swapchain_format := sdl.GetGPUSwapchainTextureFormat(r.device, r.window)

	// The world: instanced, depth tested, opaque.
	{
		buffers := [?]sdl.GPUVertexBufferDescription {
			{slot = 0, pitch = size_of(assets.Vertex), input_rate = .VERTEX},
			{slot = 1, pitch = size_of(Instance), input_rate = .INSTANCE},
		}
		attributes := [?]sdl.GPUVertexAttribute {
			{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(assets.Vertex, pos))},
			{location = 1, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(assets.Vertex, normal))},
			{location = 2, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(assets.Vertex, uv))},
			{location = 3, buffer_slot = 1, format = .FLOAT4, offset = 0},
			{location = 4, buffer_slot = 1, format = .FLOAT4, offset = 16},
			{location = 5, buffer_slot = 1, format = .FLOAT4, offset = 32},
			{location = 6, buffer_slot = 1, format = .FLOAT4, offset = 48},
			{location = 7, buffer_slot = 1, format = .FLOAT4, offset = u32(offset_of(Instance, tint))},
		}
		color_target := sdl.GPUColorTargetDescription {
			format = swapchain_format,
		}
		r.pipeline = sdl.CreateGPUGraphicsPipeline(
			r.device,
			{
				vertex_shader = tile_vert,
				fragment_shader = tile_frag,
				vertex_input_state = {
					vertex_buffer_descriptions = raw_data(buffers[:]),
					num_vertex_buffers = len(buffers),
					vertex_attributes = raw_data(attributes[:]),
					num_vertex_attributes = len(attributes),
				},
				primitive_type = .TRIANGLELIST,
				// The free camera can end up anywhere, including inside walls,
				// so nothing is culled.
				rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, front_face = .COUNTER_CLOCKWISE, enable_depth_clip = true},
				depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
				target_info = {
					color_target_descriptions = &color_target,
					num_color_targets = 1,
					depth_stencil_format = r.depth_format,
					has_depth_stencil_target = true,
				},
			},
		)
	}

	// The HUD: flat, drawn last over everything, blended by alpha.
	{
		buffers := [?]sdl.GPUVertexBufferDescription{{slot = 0, pitch = size_of(ui.Vertex), input_rate = .VERTEX}}
		attributes := [?]sdl.GPUVertexAttribute {
			{location = 0, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(ui.Vertex, pos))},
			{location = 1, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(ui.Vertex, uv))},
			{location = 2, buffer_slot = 0, format = .FLOAT4, offset = u32(offset_of(ui.Vertex, color))},
		}
		color_target := sdl.GPUColorTargetDescription {
			format = swapchain_format,
			blend_state = {
				enable_blend = true,
				src_color_blendfactor = .SRC_ALPHA,
				dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
				color_blend_op = .ADD,
				src_alpha_blendfactor = .ONE,
				dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
				alpha_blend_op = .ADD,
			},
		}
		r.ui_pipeline = sdl.CreateGPUGraphicsPipeline(
			r.device,
			{
				vertex_shader = ui_vert,
				fragment_shader = ui_frag,
				vertex_input_state = {
					vertex_buffer_descriptions = raw_data(buffers[:]),
					num_vertex_buffers = len(buffers),
					vertex_attributes = raw_data(attributes[:]),
					num_vertex_attributes = len(attributes),
				},
				primitive_type = .TRIANGLELIST,
				rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE, enable_depth_clip = true},
				depth_stencil_state = {compare_op = .ALWAYS, enable_depth_test = false, enable_depth_write = false},
				target_info = {
					color_target_descriptions = &color_target,
					num_color_targets = 1,
					depth_stencil_format = r.depth_format,
					has_depth_stencil_target = true,
				},
			},
		)
	}

	if r.pipeline == nil || r.ui_pipeline == nil {
		fmt.eprintfln("SDL_CreateGPUGraphicsPipeline failed: %s", sdl.GetError())
		return false
	}
	return true
}

// Creates a GPU buffer holding a copy of `data`.
@(private = "file")
upload_buffer :: proc(device: ^sdl.GPUDevice, usage: sdl.GPUBufferUsageFlags, data: rawptr, size: int) -> ^sdl.GPUBuffer {
	buffer := sdl.CreateGPUBuffer(device, {usage = usage, size = u32(size)})
	transfer := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = u32(size)})
	defer sdl.ReleaseGPUTransferBuffer(device, transfer)
	if buffer == nil || transfer == nil {
		fmt.eprintfln("GPU buffer allocation of %d bytes failed: %s", size, sdl.GetError())
		sdl.ReleaseGPUBuffer(device, buffer)
		return nil
	}

	mapped := sdl.MapGPUTransferBuffer(device, transfer, false)
	if mapped == nil {
		fmt.eprintfln("SDL_MapGPUTransferBuffer failed: %s", sdl.GetError())
		sdl.ReleaseGPUBuffer(device, buffer)
		return nil
	}
	mem.copy(mapped, data, size)
	sdl.UnmapGPUTransferBuffer(device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = transfer}, {buffer = buffer, size = u32(size)}, false)
	sdl.EndGPUCopyPass(pass)
	if !sdl.SubmitGPUCommandBuffer(cmd) {
		fmt.eprintfln("GPU buffer upload failed: %s", sdl.GetError())
		sdl.ReleaseGPUBuffer(device, buffer)
		return nil
	}
	return buffer
}

@(private = "file")
stream_release :: proc(device: ^sdl.GPUDevice, s: ^Stream) {
	sdl.ReleaseGPUBuffer(device, s.buffer)
	sdl.ReleaseGPUTransferBuffer(device, s.transfer)
	s^ = {}
}

// Replaces a stream's contents as part of the frame being recorded in `cmd`.
// Has to happen before the render pass that draws from it begins.
@(private = "file")
stream_write :: proc(device: ^sdl.GPUDevice, cmd: ^sdl.GPUCommandBuffer, s: ^Stream, data: rawptr, size: int) -> bool {
	if size <= 0 {
		return false
	}
	if u32(size) > s.capacity {
		capacity := max(s.capacity, 64 * 1024)
		for capacity < u32(size) {
			capacity *= 2
		}
		stream_release(device, s)
		s.buffer = sdl.CreateGPUBuffer(device, {usage = {.VERTEX}, size = capacity})
		s.transfer = sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = capacity})
		if s.buffer == nil || s.transfer == nil {
			fmt.eprintfln("GPU stream allocation of %d bytes failed: %s", capacity, sdl.GetError())
			stream_release(device, s)
			return false
		}
		s.capacity = capacity
	}
	mapped := sdl.MapGPUTransferBuffer(device, s.transfer, true)
	if mapped == nil {
		return false
	}
	mem.copy(mapped, data, size)
	sdl.UnmapGPUTransferBuffer(device, s.transfer)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = s.transfer}, {buffer = s.buffer, size = u32(size)}, true)
	sdl.EndGPUCopyPass(pass)
	return true
}

// Creates a sampled RGBA8 texture from decoded pixels.
@(private = "file")
upload_texture :: proc(device: ^sdl.GPUDevice, pixels: []u8, image_width, image_height: int) -> ^sdl.GPUTexture {
	width, height := u32(image_width), u32(image_height)
	texture := sdl.CreateGPUTexture(
		device,
		{type = .D2, format = .R8G8B8A8_UNORM, usage = {.SAMPLER}, width = width, height = height, layer_count_or_depth = 1, num_levels = 1},
	)
	transfer := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = u32(len(pixels))})
	defer sdl.ReleaseGPUTransferBuffer(device, transfer)
	mapped := transfer != nil ? sdl.MapGPUTransferBuffer(device, transfer, false) : nil
	if texture == nil || mapped == nil {
		fmt.eprintfln("texture setup failed: %s", sdl.GetError())
		sdl.ReleaseGPUTexture(device, texture)
		return nil
	}
	mem.copy(mapped, raw_data(pixels), len(pixels))
	sdl.UnmapGPUTransferBuffer(device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		pass,
		{transfer_buffer = transfer, pixels_per_row = width, rows_per_layer = height},
		{texture = texture, w = width, h = height, d = 1},
		false,
	)
	sdl.EndGPUCopyPass(pass)
	if !sdl.SubmitGPUCommandBuffer(cmd) {
		fmt.eprintfln("texture upload failed: %s", sdl.GetError())
		sdl.ReleaseGPUTexture(device, texture)
		return nil
	}
	return texture
}

@(private = "file")
create_texture :: proc(r: ^Renderer, cfg: ^dungeon.Config) -> bool {
	img, ok := assets.image_load(cfg.assets.texture)
	if !ok {
		fmt.eprintfln("cannot load texture '%s'", cfg.assets.texture)
		return false
	}
	defer assets.image_destroy(&img)

	r.texture = upload_texture(r.device, img.pixels, img.width, img.height)
	r.sampler = sdl.CreateGPUSampler(
		r.device,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			address_mode_w = .CLAMP_TO_EDGE,
		},
	)
	if r.sampler == nil {
		fmt.eprintfln("SDL_CreateGPUSampler failed: %s", sdl.GetError())
	}
	return r.texture != nil && r.sampler != nil
}

// Hands the renderer the glyph atlas the HUD's vertices refer to.
renderer_set_ui_atlas :: proc(r: ^Renderer, atlas: ^ui.Atlas) -> bool {
	sdl.ReleaseGPUTexture(r.device, r.ui_atlas)
	r.ui_atlas = upload_texture(r.device, atlas.pixels, atlas.width, atlas.height)
	return r.ui_atlas != nil
}

// Registers a kind of animated character and returns its handle for
// Actor_Draw. Its vertices arrive every frame through renderer_draw.
renderer_add_actor :: proc(r: ^Renderer, ch: ^assets.Character) -> (actor: int, ok: bool) {
	a := Actor {
		vertex_count = len(ch.vertices),
		index_count  = u32(len(ch.indices)),
		index_buffer = upload_buffer(r.device, {.INDEX}, raw_data(ch.indices), len(ch.indices) * size_of(u32)),
		texture      = upload_texture(r.device, ch.texture.pixels, ch.texture.width, ch.texture.height),
	}
	append(&r.actors, a)
	return len(r.actors) - 1, a.index_buffer != nil && a.texture != nil
}

// Loads every model the config mentions that the library does not hold yet
// and rebuilds the shared mesh buffers if anything was added.
renderer_sync_models :: proc(r: ^Renderer, cfg: ^dungeon.Config, manifest: ^assets.Manifest) -> bool {
	before := len(r.library.models)
	for name in dungeon.config_model_names(cfg, context.temp_allocator) {
		if err, ok := assets.library_load(&r.library, manifest, name); !ok {
			fmt.eprintln(err)
			return false
		}
	}
	// Models from different packs are painted from different atlases.
	for _, model in r.library.models {
		if model.texture == "" || model.texture in r.textures {
			continue
		}
		img, ok := assets.image_load(model.texture)
		if !ok {
			fmt.eprintfln("cannot load texture '%s'", model.texture)
			return false
		}
		texture := upload_texture(r.device, img.pixels, img.width, img.height)
		assets.image_destroy(&img)
		if texture == nil {
			return false
		}
		r.textures[model.texture] = texture
	}
	if len(r.library.models) == before && r.vertex_buffer != nil {
		return true
	}

	sdl.ReleaseGPUBuffer(r.device, r.vertex_buffer)
	sdl.ReleaseGPUBuffer(r.device, r.index_buffer)
	vertices, indices := r.library.vertices[:], r.library.indices[:]
	r.vertex_buffer = upload_buffer(r.device, {.VERTEX}, raw_data(vertices), len(vertices) * size_of(assets.Vertex))
	r.index_buffer = upload_buffer(r.device, {.INDEX}, raw_data(indices), len(indices) * size_of(u32))
	return r.vertex_buffer != nil && r.index_buffer != nil
}

// Replaces what is drawn with the given tiles.
renderer_set_tiles :: proc(r: ^Renderer, tiles: []dungeon.Tile) -> bool {
	sdl.ReleaseGPUBuffer(r.device, r.instance_buffer)
	r.instance_buffer = nil

	instances := build_instances(&r.library, tiles, &r.batches, context.temp_allocator)
	if len(instances) == 0 {
		return true
	}
	r.instance_buffer = upload_buffer(r.device, {.VERTEX}, raw_data(instances), len(instances) * size_of(Instance))
	return r.instance_buffer != nil
}

@(private = "file")
ensure_depth_texture :: proc(r: ^Renderer, width, height: u32) -> bool {
	if r.depth_texture != nil && r.depth_size == {width, height} {
		return true
	}
	sdl.ReleaseGPUTexture(r.device, r.depth_texture)
	r.depth_texture = sdl.CreateGPUTexture(
		r.device,
		{
			type = .D2,
			format = r.depth_format,
			usage = {.DEPTH_STENCIL_TARGET},
			width = width,
			height = height,
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)
	r.depth_size = {width, height}
	return r.depth_texture != nil
}

// Size of the window's drawable area in pixels, which is what HUD
// coordinates are measured in.
renderer_screen_size :: proc(r: ^Renderer) -> [2]f32 {
	w, h: i32
	if !sdl.GetWindowSizeInPixels(r.window, &w, &h) {
		return {}
	}
	return {f32(w), f32(h)}
}

// Where the mouse pointer is, in the same pixels as renderer_screen_size.
// The two differ from window coordinates on displays that scale the window.
pointer_position :: proc(r: ^Renderer) -> [2]f32 {
	x, y: f32
	_ = sdl.GetMouseState(&x, &y)
	w, h: i32
	if !sdl.GetWindowSize(r.window, &w, &h) || w <= 0 || h <= 0 {
		return {x, y}
	}
	pixels := renderer_screen_size(r)
	return {x * pixels.x / f32(w), y * pixels.y / f32(h)}
}

// Draws one frame: the dungeon, then the animated characters, then the HUD.
renderer_draw :: proc(r: ^Renderer, cam: camera.Camera, actors: []Actor_Draw, hud: []ui.Vertex) {
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil {
		return
	}

	// Everything rewritten per frame is uploaded before the render pass.
	drawable := make([]bool, len(actors), context.temp_allocator)
	for draw, i in actors {
		if draw.actor < 0 || draw.actor >= len(r.actors) || draw.instances <= 0 {
			continue
		}
		a := &r.actors[draw.actor]
		if len(draw.vertices) < draw.instances * a.vertex_count {
			continue
		}
		size := draw.instances * a.vertex_count * size_of(assets.Vertex)
		instances := flash_instances(draw.flash, draw.instances, context.temp_allocator)
		drawable[i] =
			stream_write(r.device, cmd, &a.vertices, raw_data(draw.vertices), size) &&
			stream_write(r.device, cmd, &a.instances, raw_data(instances), len(instances) * size_of(Instance))
	}
	hud_ready :=
		r.ui_atlas != nil &&
		len(hud) > 0 &&
		stream_write(r.device, cmd, &r.ui_vertices, raw_data(hud), len(hud) * size_of(ui.Vertex))

	swapchain: ^sdl.GPUTexture
	width, height: u32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, r.window, &swapchain, &width, &height) ||
	   swapchain == nil ||
	   !ensure_depth_texture(r, width, height) {
		// Minimised or mid-resize: nothing to draw into this frame.
		_ = sdl.SubmitGPUCommandBuffer(cmd)
		return
	}

	color_target := sdl.GPUColorTargetInfo {
		texture     = swapchain,
		clear_color = CLEAR_COLOR,
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	depth_target := sdl.GPUDepthStencilTargetInfo {
		texture          = r.depth_texture,
		clear_depth      = 1,
		load_op          = .CLEAR,
		store_op         = .DONT_CARE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
		cycle            = true,
	}
	pass := sdl.BeginGPURenderPass(cmd, &color_target, 1, &depth_target)

	view_proj := camera.view_projection(cam, f32(width) / f32(height))
	sdl.PushGPUVertexUniformData(cmd, 0, &view_proj, size_of(view_proj))
	sdl.BindGPUGraphicsPipeline(pass, r.pipeline)

	if r.instance_buffer != nil && len(r.batches) > 0 {
		vertex_buffers := [?]sdl.GPUBufferBinding{{buffer = r.vertex_buffer}, {buffer = r.instance_buffer}}
		sdl.BindGPUVertexBuffers(pass, 0, raw_data(vertex_buffers[:]), len(vertex_buffers))
		sdl.BindGPUIndexBuffer(pass, {buffer = r.index_buffer}, ._32BIT)

		bound: ^sdl.GPUTexture
		for batch in r.batches {
			texture := r.textures[batch.model.texture] or_else r.texture
			if texture != bound {
				bound = texture
				sampler := sdl.GPUTextureSamplerBinding{texture = texture, sampler = r.sampler}
				sdl.BindGPUFragmentSamplers(pass, 0, &sampler, 1)
			}
			sdl.DrawGPUIndexedPrimitives(
				pass,
				batch.model.index_count,
				batch.count,
				batch.model.first_index,
				batch.model.vertex_offset,
				batch.first_instance,
			)
		}
	}

	for draw, i in actors {
		if !drawable[i] {
			continue
		}
		a := &r.actors[draw.actor]
		vertex_buffers := [?]sdl.GPUBufferBinding{{buffer = a.vertices.buffer}, {buffer = a.instances.buffer}}
		sdl.BindGPUVertexBuffers(pass, 0, raw_data(vertex_buffers[:]), len(vertex_buffers))
		sdl.BindGPUIndexBuffer(pass, {buffer = a.index_buffer}, ._32BIT)
		sampler := sdl.GPUTextureSamplerBinding{texture = a.texture, sampler = r.sampler}
		sdl.BindGPUFragmentSamplers(pass, 0, &sampler, 1)
		count := draw.indices < 0 ? a.index_count : min(a.index_count, u32(draw.indices))
		// Each instance is the same indices over the next run of vertices,
		// with its own row of instance data.
		for instance in 0 ..< draw.instances {
			sdl.DrawGPUIndexedPrimitives(pass, count, 1, 0, i32(instance * a.vertex_count), u32(instance))
		}
	}

	if hud_ready {
		screen := [4]f32{f32(width), f32(height), 0, 0}
		sdl.BindGPUGraphicsPipeline(pass, r.ui_pipeline)
		sdl.PushGPUVertexUniformData(cmd, 0, &screen, size_of(screen))
		binding := sdl.GPUBufferBinding {
			buffer = r.ui_vertices.buffer,
		}
		sdl.BindGPUVertexBuffers(pass, 0, &binding, 1)
		sampler := sdl.GPUTextureSamplerBinding{texture = r.ui_atlas, sampler = r.sampler}
		sdl.BindGPUFragmentSamplers(pass, 0, &sampler, 1)
		sdl.DrawGPUPrimitives(pass, u32(len(hud)), 1, 0, 0)
	}

	sdl.EndGPURenderPass(pass)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
}
