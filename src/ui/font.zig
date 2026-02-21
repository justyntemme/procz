const std = @import("std");
const sokol = @import("sokol");
const theme = @import("theme");

const sg = sokol.gfx;
const sgl = sokol.gl;

const stbtt = @cImport(@cInclude("stb_truetype.h"));

const print = std.debug.print;

// Atlas dimensions — 1024x1024 at 48px gives sharp glyphs on Retina displays
const ATLAS_W: i32 = 1024;
const ATLAS_H: i32 = 1024;
const ATLAS_PIXELS: usize = @intCast(ATLAS_W * ATLAS_H);
const BAKE_SIZE: f32 = 48.0;
const FIRST_CHAR: i32 = 32;
const NUM_CHARS: usize = 95; // ASCII 32–126

var baked_chars: [NUM_CHARS]stbtt.stbtt_bakedchar = undefined;
var atlas_view: sg.View = .{};
var atlas_sampler: sg.Sampler = .{};
var alpha_pip: sgl.Pipeline = .{};
var atlas_image: sg.Image = .{};
var initialized: bool = false;

pub fn init() void {
    // Read TTF file
    const font_path = "/Users/justyntemme/Library/Fonts/FiraCodeNerdFontMono-Regular.ttf";
    const file = std.fs.openFileAbsolute(font_path, .{}) catch |err| {
        print("font: failed to open {s}: {}\n", .{ font_path, err });
        return;
    };
    defer file.close();

    const font_data = file.readToEndAlloc(std.heap.page_allocator, 16 * 1024 * 1024) catch |err| {
        print("font: failed to read font file: {}\n", .{err});
        return;
    };
    defer std.heap.page_allocator.free(font_data);

    // Heap-allocate bitmaps (too large for stack: 256KB + 1MB)
    const alpha_bitmap = std.heap.page_allocator.alloc(u8, ATLAS_PIXELS) catch |err| {
        print("font: failed to alloc alpha bitmap: {}\n", .{err});
        return;
    };
    defer std.heap.page_allocator.free(alpha_bitmap);

    // Bake font bitmap (single-channel alpha)
    const result = stbtt.stbtt_BakeFontBitmap(
        font_data.ptr,
        0, // font offset
        BAKE_SIZE,
        alpha_bitmap.ptr,
        ATLAS_W,
        ATLAS_H,
        FIRST_CHAR,
        @intCast(NUM_CHARS),
        &baked_chars,
    );
    if (result <= 0) {
        print("font: stbtt_BakeFontBitmap failed (result={d})\n", .{result});
        return;
    }
    // Convert alpha bitmap to RGBA8: white + alpha
    const rgba_bitmap = std.heap.page_allocator.alloc(u8, ATLAS_PIXELS * 4) catch |err| {
        print("font: failed to alloc RGBA bitmap: {}\n", .{err});
        return;
    };
    defer std.heap.page_allocator.free(rgba_bitmap);

    for (0..ATLAS_PIXELS) |i| {
        rgba_bitmap[i * 4 + 0] = 255; // R
        rgba_bitmap[i * 4 + 1] = 255; // G
        rgba_bitmap[i * 4 + 2] = 255; // B
        rgba_bitmap[i * 4 + 3] = alpha_bitmap[i]; // A
    }

    // Create sokol image
    var desc = sg.ImageDesc{};
    desc.width = ATLAS_W;
    desc.height = ATLAS_H;
    desc.pixel_format = .RGBA8;
    desc.data.mip_levels[0] = .{
        .ptr = rgba_bitmap.ptr,
        .size = ATLAS_PIXELS * 4,
    };
    atlas_image = sg.makeImage(desc);

    // Create view from image
    atlas_view = sg.makeView(.{
        .texture = .{ .image = atlas_image },
    });

    // Create sampler — linear filtering + mipmap for smooth scaling at any DPI
    atlas_sampler = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .mipmap_filter = .LINEAR,
    });

    // Create alpha-blend pipeline for sgl
    var pip_desc = sg.PipelineDesc{};
    pip_desc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
    };
    alpha_pip = sgl.makePipeline(pip_desc);

    initialized = true;
    print("font: atlas ready ({d} rows used)\n", .{result});
}

pub fn isReady() bool {
    return initialized;
}

pub fn shutdown() void {
    if (!initialized) return;
    sg.destroyImage(atlas_image);
}

/// Measure text width and height at given font size.
pub fn measure(text: []const u8, font_size: f32) struct { w: f32, h: f32 } {
    if (!initialized) {
        const len: f32 = @floatFromInt(text.len);
        return .{ .w = len * font_size * 0.6, .h = font_size };
    }

    const scale = font_size / BAKE_SIZE;
    var x: f32 = 0;

    for (text) |ch| {
        if (ch < FIRST_CHAR or ch >= FIRST_CHAR + NUM_CHARS) {
            x += font_size * 0.6;
            continue;
        }
        const idx: usize = @intCast(ch - FIRST_CHAR);
        const bc = baked_chars[idx];
        x += bc.xadvance * scale;
    }

    return .{ .w = x, .h = font_size };
}

/// Draw text as textured quads via sgl.
pub fn drawText(x: f32, y: f32, text: []const u8, font_size: f32, r: u8, g: u8, b: u8, a: u8) void {
    if (!initialized or text.len == 0) return;

    const scale = font_size / BAKE_SIZE;
    const inv_w: f32 = 1.0 / @as(f32, @floatFromInt(ATLAS_W));
    const inv_h: f32 = 1.0 / @as(f32, @floatFromInt(ATLAS_H));

    sgl.loadPipeline(alpha_pip);
    sgl.enableTexture();
    sgl.texture(atlas_view, atlas_sampler);

    sgl.beginQuads();
    sgl.c4b(r, g, b, a);

    var cx: f32 = x;

    for (text) |ch| {
        if (ch < FIRST_CHAR or ch >= FIRST_CHAR + NUM_CHARS) {
            cx += font_size * 0.6;
            continue;
        }
        const idx: usize = @intCast(ch - FIRST_CHAR);
        const bc = baked_chars[idx];

        // Glyph bitmap dimensions in atlas pixels
        const glyph_w_px = @as(f32, @floatFromInt(bc.x1 - bc.x0));
        const glyph_h_px = @as(f32, @floatFromInt(bc.y1 - bc.y0));

        // Screen quad corners
        const x0 = cx + bc.xoff * scale;
        const y0 = y + bc.yoff * scale + font_size; // baseline offset
        const x1 = x0 + glyph_w_px * scale;
        const y1 = y0 + glyph_h_px * scale;

        // UV coords (atlas pixel coords -> normalized)
        const s0 = @as(f32, @floatFromInt(bc.x0)) * inv_w;
        const t0 = @as(f32, @floatFromInt(bc.y0)) * inv_h;
        const s1 = @as(f32, @floatFromInt(bc.x1)) * inv_w;
        const t1 = @as(f32, @floatFromInt(bc.y1)) * inv_h;

        // Emit quad (4 vertices, sgl handles indices for quads)
        sgl.v2fT2f(x0, y0, s0, t0);
        sgl.v2fT2f(x1, y0, s1, t0);
        sgl.v2fT2f(x1, y1, s1, t1);
        sgl.v2fT2f(x0, y1, s0, t1);

        cx += bc.xadvance * scale;
    }

    sgl.end();
    sgl.disableTexture();
}
