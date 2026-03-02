const std = @import("std");
const builtin = @import("builtin");
const sokol = @import("sokol");

const sg = sokol.gfx;
const sgl = sokol.gl;
const slog = sokol.log;

const print = std.debug.print;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const ATLAS_SIZE: i32 = 512; // 512×512 RGBA atlas
const ICON_SIZE: i32 = 16; // each icon slot is 16×16
const GRID_DIM: i32 = @divExact(ATLAS_SIZE, ICON_SIZE); // 32 slots per axis
const MAX_SLOTS: usize = @intCast(GRID_DIM * GRID_DIM); // 1024 max icons
const ATLAS_PIXELS: usize = @intCast(ATLAS_SIZE * ATLAS_SIZE);

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

pub const IconUV = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

var atlas_buf: ?[]u8 = null; // ATLAS_PIXELS * 4 bytes RGBA
var atlas_image: sg.Image = .{};
var atlas_view: sg.View = .{};
var atlas_sampler: sg.Sampler = .{};
var alpha_pip: sgl.Pipeline = .{};
var dirty: bool = false;
var initialized: bool = false;

var slot_count: u16 = 0;
var pid_map: std.AutoHashMap(i32, u16) = undefined;
var pid_map_inited: bool = false;

// Temporary buffer for loading a single icon (ICON_SIZE × ICON_SIZE × 4)
var icon_tmp: [ICON_SIZE * ICON_SIZE * 4]u8 = undefined;

/// Visible PIDs set by main.zig each frame before renderer.render().
/// The renderer uses the IDI index to look up the PID from this array.
pub var visible_pids: []const i32 = &.{};

/// Visible row range set by main.zig each frame. Limits icon ID matching
/// to only the ~30 rows that have Clay elements, instead of all 2048.
pub var visible_range: struct { first: usize, count: usize } = .{ .first = 0, .count = 0 };

// ---------------------------------------------------------------------------
// Native icon loader (from ObjC, linked via native_ui_lib on macOS)
// ---------------------------------------------------------------------------

const get_icon = if (builtin.os.tag == .macos)
    struct {
        extern fn get_app_icon_rgba(pid: c_int, out_rgba: [*c]u8, size: c_int) c_int;
        fn call(pid: c_int, out: [*c]u8, size: c_int) c_int {
            return get_app_icon_rgba(pid, out, size);
        }
    }.call
else
    struct {
        fn call(_: c_int, _: [*c]u8, _: c_int) c_int {
            return 0;
        }
    }.call;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn init() void {
    // Allocate CPU-side atlas buffer
    atlas_buf = std.heap.page_allocator.alloc(u8, ATLAS_PIXELS * 4) catch {
        print("icon_cache: failed to alloc atlas buffer\n", .{});
        return;
    };
    @memset(atlas_buf.?, 0);

    // Create sokol GPU image (mutable, updated each frame when dirty)
    var desc = sg.ImageDesc{};
    desc.width = ATLAS_SIZE;
    desc.height = ATLAS_SIZE;
    desc.pixel_format = .RGBA8;
    desc.usage = .{ .dynamic_update = true };
    atlas_image = sg.makeImage(desc);

    atlas_view = sg.makeView(.{
        .texture = .{ .image = atlas_image },
    });

    atlas_sampler = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
    });

    // Alpha-blend pipeline (same pattern as font.zig)
    var pip_desc = sg.PipelineDesc{};
    pip_desc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
    };
    alpha_pip = sgl.makePipeline(pip_desc);

    pid_map = std.AutoHashMap(i32, u16).init(std.heap.page_allocator);
    pid_map_inited = true;

    initialized = true;
    print("icon_cache: initialized ({d}×{d} atlas, {d} max slots)\n", .{ ATLAS_SIZE, ATLAS_SIZE, MAX_SLOTS });
}

pub fn shutdown() void {
    if (!initialized) return;
    sg.destroyImage(atlas_image);
    if (atlas_buf) |buf| std.heap.page_allocator.free(buf);
    atlas_buf = null;
    if (pid_map_inited) pid_map.deinit();
    initialized = false;
}

/// Get UV coordinates for a PID's icon, loading it if necessary.
/// Returns null if the icon is unavailable or atlas is full.
pub fn getOrLoad(pid: i32) ?IconUV {
    if (!initialized) return null;

    // Check cache
    if (pid_map.get(pid)) |slot| {
        return slotToUV(slot);
    }

    // Atlas full
    if (slot_count >= MAX_SLOTS) return null;

    // Try to load icon from macOS
    const ok = get_icon(@intCast(pid), &icon_tmp, ICON_SIZE);
    if (ok == 0) return null;

    // Allocate slot
    const slot = slot_count;
    slot_count += 1;

    // Copy icon pixels into atlas buffer at the correct position
    const col: usize = @intCast(slot % @as(u16, @intCast(GRID_DIM)));
    const row: usize = @intCast(slot / @as(u16, @intCast(GRID_DIM)));
    const buf = atlas_buf orelse return null;

    const icon_size: usize = @intCast(ICON_SIZE);
    for (0..icon_size) |iy| {
        const src_off = iy * icon_size * 4;
        const dst_x = col * icon_size;
        const dst_y = row * icon_size + iy;
        const dst_off = (dst_y * @as(usize, @intCast(ATLAS_SIZE)) + dst_x) * 4;
        @memcpy(buf[dst_off..][0 .. icon_size * 4], icon_tmp[src_off..][0 .. icon_size * 4]);
    }

    pid_map.put(pid, slot) catch return null;
    dirty = true;

    return slotToUV(slot);
}

/// Upload atlas to GPU if any new icons were loaded this frame.
pub fn flush() void {
    if (!initialized or !dirty) return;
    dirty = false;

    const buf = atlas_buf orelse return;
    var img_data = sg.ImageData{};
    img_data.mip_levels[0] = .{
        .ptr = buf.ptr,
        .size = ATLAS_PIXELS * 4,
    };
    sg.updateImage(atlas_image, img_data);
}

/// Render a single icon as a textured quad at the given screen position.
pub fn drawIcon(x: f32, y: f32, w: f32, h: f32, uv: IconUV) void {
    if (!initialized) return;

    sgl.loadPipeline(alpha_pip);
    sgl.enableTexture();
    sgl.texture(atlas_view, atlas_sampler);

    sgl.beginQuads();
    sgl.c4b(255, 255, 255, 255);
    sgl.v2fT2f(x, y, uv.u0, uv.v0);
    sgl.v2fT2f(x + w, y, uv.u1, uv.v0);
    sgl.v2fT2f(x + w, y + h, uv.u1, uv.v1);
    sgl.v2fT2f(x, y + h, uv.u0, uv.v1);
    sgl.end();

    sgl.disableTexture();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn slotToUV(slot: u16) IconUV {
    const col: f32 = @floatFromInt(slot % @as(u16, @intCast(GRID_DIM)));
    const row: f32 = @floatFromInt(slot / @as(u16, @intCast(GRID_DIM)));
    const atlas_f: f32 = @floatFromInt(ATLAS_SIZE);
    const icon_f: f32 = @floatFromInt(ICON_SIZE);
    return .{
        .u0 = col * icon_f / atlas_f,
        .v0 = row * icon_f / atlas_f,
        .u1 = (col + 1.0) * icon_f / atlas_f,
        .v1 = (row + 1.0) * icon_f / atlas_f,
    };
}
