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

// Character ranges
const FIRST_ASCII: i32 = 32;
const NUM_ASCII: usize = 95; // ASCII 32–126
const FIRST_BOX: i32 = 0x2500;
const NUM_BOX: usize = 128; // Box Drawing U+2500–U+257F
const FIRST_GEO: i32 = 0x25A0;
const NUM_GEO: usize = 96; // Geometric Shapes U+25A0–U+25FF (▲ ▼ etc.)

var ascii_chars: [NUM_ASCII]stbtt.stbtt_packedchar = undefined;
var box_chars: [NUM_BOX]stbtt.stbtt_packedchar = undefined;
var geo_chars: [NUM_GEO]stbtt.stbtt_packedchar = undefined;
var atlas_view: sg.View = .{};
var atlas_sampler: sg.Sampler = .{};
var alpha_pip: sgl.Pipeline = .{};
var atlas_image: sg.Image = .{};
var initialized: bool = false;

pub fn init() void {
    // Read TTF file from user's font directory
    const home = std.posix.getenv("HOME") orelse "/tmp";
    var path_buf: [512]u8 = undefined;
    const font_path = std.fmt.bufPrint(&path_buf, "{s}/Library/Fonts/FiraCodeNerdFontMono-Regular.ttf", .{home}) catch {
        print("font: HOME path too long\n", .{});
        return;
    };
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

    // Pack font using stbtt_PackFontRanges (supports multiple Unicode ranges)
    var spc: stbtt.stbtt_pack_context = undefined;
    if (stbtt.stbtt_PackBegin(&spc, alpha_bitmap.ptr, ATLAS_W, ATLAS_H, 0, 1, null) == 0) {
        print("font: stbtt_PackBegin failed\n", .{});
        return;
    }

    var ranges = [3]stbtt.stbtt_pack_range{
        .{
            .font_size = BAKE_SIZE,
            .first_unicode_codepoint_in_range = FIRST_ASCII,
            .array_of_unicode_codepoints = null,
            .num_chars = @intCast(NUM_ASCII),
            .chardata_for_range = &ascii_chars,
            .h_oversample = 0,
            .v_oversample = 0,
        },
        .{
            .font_size = BAKE_SIZE,
            .first_unicode_codepoint_in_range = FIRST_BOX,
            .array_of_unicode_codepoints = null,
            .num_chars = @intCast(NUM_BOX),
            .chardata_for_range = &box_chars,
            .h_oversample = 0,
            .v_oversample = 0,
        },
        .{
            .font_size = BAKE_SIZE,
            .first_unicode_codepoint_in_range = FIRST_GEO,
            .array_of_unicode_codepoints = null,
            .num_chars = @intCast(NUM_GEO),
            .chardata_for_range = &geo_chars,
            .h_oversample = 0,
            .v_oversample = 0,
        },
    };

    const pack_result = stbtt.stbtt_PackFontRanges(&spc, font_data.ptr, 0, &ranges, 3);
    stbtt.stbtt_PackEnd(&spc);

    if (pack_result == 0) {
        print("font: stbtt_PackFontRanges warning — some glyphs may be missing\n", .{});
        // Continue anyway — ASCII should be fine, box-drawing may be missing
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
    print("font: atlas ready (pack_result={d})\n", .{pack_result});
}

pub fn isReady() bool {
    return initialized;
}

pub fn shutdown() void {
    if (!initialized) return;
    sg.destroyImage(atlas_image);
}

// -------------------------------------------------------------------------
// UTF-8 decoding + character lookup
// -------------------------------------------------------------------------

fn decodeUtf8(bytes: []const u8) struct { cp: u32, len: u8 } {
    if (bytes.len == 0) return .{ .cp = 0xFFFD, .len = 0 };
    const b0 = bytes[0];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 < 0xC0) return .{ .cp = 0xFFFD, .len = 1 };
    if (b0 < 0xE0) {
        if (bytes.len < 2) return .{ .cp = 0xFFFD, .len = 1 };
        const cp = (@as(u32, b0 & 0x1F) << 6) | @as(u32, bytes[1] & 0x3F);
        return .{ .cp = cp, .len = 2 };
    }
    if (b0 < 0xF0) {
        if (bytes.len < 3) return .{ .cp = 0xFFFD, .len = 1 };
        const cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, bytes[1] & 0x3F) << 6) | @as(u32, bytes[2] & 0x3F);
        return .{ .cp = cp, .len = 3 };
    }
    if (bytes.len < 4) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, bytes[1] & 0x3F) << 12) | (@as(u32, bytes[2] & 0x3F) << 6) | @as(u32, bytes[3] & 0x3F);
    return .{ .cp = cp, .len = 4 };
}

fn lookupChar(cp: u32) ?*const stbtt.stbtt_packedchar {
    if (cp >= @as(u32, @intCast(FIRST_ASCII)) and cp < @as(u32, @intCast(FIRST_ASCII)) + NUM_ASCII) {
        return &ascii_chars[cp - @as(u32, @intCast(FIRST_ASCII))];
    }
    if (cp >= @as(u32, @intCast(FIRST_BOX)) and cp < @as(u32, @intCast(FIRST_BOX)) + NUM_BOX) {
        return &box_chars[cp - @as(u32, @intCast(FIRST_BOX))];
    }
    if (cp >= @as(u32, @intCast(FIRST_GEO)) and cp < @as(u32, @intCast(FIRST_GEO)) + NUM_GEO) {
        return &geo_chars[cp - @as(u32, @intCast(FIRST_GEO))];
    }
    return null;
}

// -------------------------------------------------------------------------
// Public API: measure + drawText
// -------------------------------------------------------------------------

/// Measure text width and height at given font size.
pub fn measure(text: []const u8, font_size: f32) struct { w: f32, h: f32 } {
    if (!initialized) {
        const len: f32 = @floatFromInt(text.len);
        return .{ .w = len * font_size * 0.6, .h = font_size };
    }

    const scale = font_size / BAKE_SIZE;
    var x: f32 = 0;
    var i: usize = 0;

    while (i < text.len) {
        const decoded = decodeUtf8(text[i..]);
        if (decoded.len == 0) break;

        if (lookupChar(decoded.cp)) |pc| {
            x += pc.xadvance * scale;
        } else {
            x += font_size * 0.6;
        }
        i += decoded.len;
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
    var i: usize = 0;

    while (i < text.len) {
        const decoded = decodeUtf8(text[i..]);
        if (decoded.len == 0) break;

        if (lookupChar(decoded.cp)) |pc| {
            // Screen quad corners using packedchar xoff/yoff/xoff2/yoff2
            const x0 = cx + pc.xoff * scale;
            const y0 = y + pc.yoff * scale + font_size;
            const x1 = cx + pc.xoff2 * scale;
            const y1 = y + pc.yoff2 * scale + font_size;

            // UV coords (atlas pixel coords -> normalized)
            const s0 = @as(f32, @floatFromInt(pc.x0)) * inv_w;
            const t0 = @as(f32, @floatFromInt(pc.y0)) * inv_h;
            const s1 = @as(f32, @floatFromInt(pc.x1)) * inv_w;
            const t1 = @as(f32, @floatFromInt(pc.y1)) * inv_h;

            // Emit quad (4 vertices, sgl handles indices for quads)
            sgl.v2fT2f(x0, y0, s0, t0);
            sgl.v2fT2f(x1, y0, s1, t0);
            sgl.v2fT2f(x1, y1, s1, t1);
            sgl.v2fT2f(x0, y1, s0, t1);

            cx += pc.xadvance * scale;
        } else {
            cx += font_size * 0.6;
        }
        i += decoded.len;
    }

    sgl.end();
    sgl.disableTexture();
}
