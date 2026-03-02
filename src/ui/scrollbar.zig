const std = @import("std");
const sokol = @import("sokol");
const clay = @import("zclay");
const theme = @import("theme");

const sgl = sokol.gl;
const sapp = sokol.app;

// ---------------------------------------------------------------------------
// Constants (macOS-style overlay scrollbars)
// ---------------------------------------------------------------------------

const THUMB_WIDTH: f32 = 8.0;
const MIN_THUMB_LEN: f32 = 28.0;
const EDGE_MARGIN: f32 = 3.0;
const SEGMENTS: usize = 8; // per corner arc

// Expand the hit-test area so it's easier to grab the thin scrollbar
const HIT_PAD: f32 = 6.0;

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

const ScrollbarEntry = struct {
    x: f32 = 0,
    y: f32 = 0,
    container_h: f32 = 0,
    container_w: f32 = 0,
    content_h: f32 = 0,
    content_w: f32 = 0,
    scroll_y: f32 = 0,
    scroll_x: f32 = 0,
    vertical: bool = true,
    horizontal: bool = false,
    // Mutable pointer into Clay's scroll container — allows direct scroll manipulation
    scroll_ptr: ?*clay.Vector2 = null,
};

const ThumbRect = struct { x: f32, y: f32, w: f32, h: f32 };

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

const MAX_SCROLLBARS = 12;
var entries: [MAX_SCROLLBARS]ScrollbarEntry = [_]ScrollbarEntry{.{}} ** MAX_SCROLLBARS;
var entry_count: usize = 0;

// Drag state (persists across frames)
var drag_active: bool = false;
var drag_is_vertical: bool = true;
var drag_scroll_ptr: ?*clay.Vector2 = null;
var drag_start_mouse: f32 = 0;
var drag_start_scroll: f32 = 0;
var drag_track_len: f32 = 0;
var drag_thumb_len: f32 = 0;
var drag_max_scroll: f32 = 0;

// ---------------------------------------------------------------------------
// Public API — registration
// ---------------------------------------------------------------------------

/// Clear all scrollbar entries. Call at start of each frame.
pub fn reset() void {
    entry_count = 0;
}

/// Register a scrollbar by Clay element ID. Fetches scroll data and bounding
/// box from Clay internally — callers just pass the element ID string.
pub fn addFromClay(comptime id: [:0]const u8, opts: struct { vertical: bool = true, horizontal: bool = false }) void {
    const sd = clay.getScrollContainerData(clay.ElementId.ID(id));
    if (!sd.found) return;
    const el = clay.getElementData(clay.ElementId.ID(id));
    if (!el.found) return;

    if (entry_count >= MAX_SCROLLBARS) return;
    entries[entry_count] = .{
        .x = el.bounding_box.x,
        .y = el.bounding_box.y,
        .container_h = sd.scroll_container_dimensions.h,
        .container_w = sd.scroll_container_dimensions.w,
        .content_h = sd.content_dimensions.h,
        .content_w = sd.content_dimensions.w,
        .scroll_y = -sd.scroll_position.y,
        .scroll_x = -sd.scroll_position.x,
        .vertical = opts.vertical,
        .horizontal = opts.horizontal,
        .scroll_ptr = sd.scroll_position,
    };
    entry_count += 1;
}

// ---------------------------------------------------------------------------
// Public API — mouse interaction
// ---------------------------------------------------------------------------

/// Returns true if a scrollbar drag is in progress.
pub fn isDragging() bool {
    return drag_active;
}

/// Hit-test all registered scrollbar thumbs. Call from MOUSE_DOWN handler.
/// Returns true if a scrollbar was hit (caller should consume the event).
pub fn handleMouseDown(mx: f32, my: f32) bool {
    for (entries[0..entry_count]) |info| {
        if (info.vertical) {
            if (computeVerticalThumb(info)) |thumb| {
                // Expanded hit area for easier grabbing
                if (mx >= thumb.x - HIT_PAD and mx <= thumb.x + thumb.w + HIT_PAD and
                    my >= thumb.y and my <= thumb.y + thumb.h)
                {
                    drag_active = true;
                    drag_is_vertical = true;
                    drag_scroll_ptr = info.scroll_ptr;
                    drag_start_mouse = my;
                    drag_start_scroll = info.scroll_y;
                    drag_max_scroll = info.content_h - info.container_h;
                    drag_track_len = info.container_h - EDGE_MARGIN * 2;
                    drag_thumb_len = thumb.h;
                    return true;
                }
                // Track click (click above/below thumb): jump to that position
                const track_x = thumb.x - HIT_PAD;
                const track_x2 = thumb.x + thumb.w + HIT_PAD;
                if (mx >= track_x and mx <= track_x2 and
                    my >= info.y + EDGE_MARGIN and my <= info.y + info.container_h - EDGE_MARGIN)
                {
                    // Jump scroll position so the thumb center lands at click point
                    const click_in_track = my - (info.y + EDGE_MARGIN);
                    const track_h = info.container_h - EDGE_MARGIN * 2;
                    const max_scroll = info.content_h - info.container_h;
                    const frac = @min(@max((click_in_track - thumb.h * 0.5) / (track_h - thumb.h), 0), 1.0);
                    if (info.scroll_ptr) |ptr| {
                        ptr.y = -frac * max_scroll;
                    }
                    // Start drag from new position
                    drag_active = true;
                    drag_is_vertical = true;
                    drag_scroll_ptr = info.scroll_ptr;
                    drag_start_mouse = my;
                    drag_start_scroll = frac * max_scroll;
                    drag_max_scroll = max_scroll;
                    drag_track_len = track_h;
                    drag_thumb_len = thumb.h;
                    return true;
                }
            }
        }
        if (info.horizontal) {
            if (computeHorizontalThumb(info)) |thumb| {
                if (mx >= thumb.x and mx <= thumb.x + thumb.w and
                    my >= thumb.y - HIT_PAD and my <= thumb.y + thumb.h + HIT_PAD)
                {
                    drag_active = true;
                    drag_is_vertical = false;
                    drag_scroll_ptr = info.scroll_ptr;
                    drag_start_mouse = mx;
                    drag_start_scroll = info.scroll_x;
                    drag_max_scroll = info.content_w - info.container_w;
                    drag_track_len = info.container_w - EDGE_MARGIN * 2;
                    drag_thumb_len = thumb.w;
                    return true;
                }
            }
        }
    }
    return false;
}

/// Update scroll position during drag. Call from MOUSE_MOVE handler.
pub fn handleMouseMove(mx: f32, my: f32) void {
    if (!drag_active) return;
    const ptr = drag_scroll_ptr orelse return;

    const current_mouse = if (drag_is_vertical) my else mx;
    const mouse_delta = current_mouse - drag_start_mouse;

    // Convert pixel delta in track space to scroll delta in content space
    const usable_track = drag_track_len - drag_thumb_len;
    if (usable_track <= 0) return;
    const scroll_delta = (mouse_delta / usable_track) * drag_max_scroll;
    const new_scroll = @min(@max(drag_start_scroll + scroll_delta, 0), drag_max_scroll);

    if (drag_is_vertical) {
        ptr.y = -new_scroll;
    } else {
        ptr.x = -new_scroll;
    }
}

/// End scrollbar drag. Call from MOUSE_UP handler.
pub fn handleMouseUp() void {
    drag_active = false;
    drag_scroll_ptr = null;
}

// ---------------------------------------------------------------------------
// Public API — rendering
// ---------------------------------------------------------------------------

/// Render all registered scrollbars as sgl overlays.
/// Called from renderer after Clay commands and graph overlays.
pub fn renderAll() void {
    if (entry_count == 0) return;

    // Reset scissor to full viewport so scrollbars aren't clipped
    sgl.scissorRectf(0, 0, sapp.widthf(), sapp.heightf(), true);

    for (entries[0..entry_count]) |info| {
        if (info.vertical) renderVertical(info);
        if (info.horizontal) renderHorizontal(info);
    }
}

// ---------------------------------------------------------------------------
// Thumb geometry computation (shared by rendering and hit-testing)
// ---------------------------------------------------------------------------

fn computeVerticalThumb(info: ScrollbarEntry) ?ThumbRect {
    if (info.container_h <= 0 or info.content_h <= 0) return null;
    const ratio = info.container_h / info.content_h;
    if (ratio >= 1.0) return null;

    const track_h = info.container_h - EDGE_MARGIN * 2;
    if (track_h <= 0) return null;

    const thumb_h = @max(ratio * track_h, MIN_THUMB_LEN);
    const max_scroll = info.content_h - info.container_h;
    const frac = if (max_scroll > 0) @min(@max(info.scroll_y / max_scroll, 0), 1.0) else 0;
    const thumb_y = frac * (track_h - thumb_h);

    // Pin to the right edge of the viewport. The container's bounding box may
    // be stale on the first frame (zeros from getElementData before any layout),
    // and full-width scroll containers should always have their scrollbar at
    // the window's right edge regardless.
    const dpi = sapp.dpiScale();
    const viewport_w = sapp.widthf() / dpi;
    const right_edge = if (info.container_w > 0) info.x + info.container_w else viewport_w;

    return .{
        .x = right_edge - THUMB_WIDTH - EDGE_MARGIN,
        .y = info.y + EDGE_MARGIN + thumb_y,
        .w = THUMB_WIDTH,
        .h = thumb_h,
    };
}

fn computeHorizontalThumb(info: ScrollbarEntry) ?ThumbRect {
    if (info.container_w <= 0 or info.content_w <= 0) return null;
    const ratio = info.container_w / info.content_w;
    if (ratio >= 1.0) return null;

    const track_w = info.container_w - EDGE_MARGIN * 2;
    if (track_w <= 0) return null;

    const thumb_w = @max(ratio * track_w, MIN_THUMB_LEN);
    const max_scroll = info.content_w - info.container_w;
    const frac = if (max_scroll > 0) @min(@max(info.scroll_x / max_scroll, 0), 1.0) else 0;
    const thumb_x = frac * (track_w - thumb_w);

    return .{
        .x = info.x + EDGE_MARGIN + thumb_x,
        .y = info.y + info.container_h - THUMB_WIDTH - EDGE_MARGIN,
        .w = thumb_w,
        .h = THUMB_WIDTH,
    };
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn renderVertical(info: ScrollbarEntry) void {
    const thumb = computeVerticalThumb(info) orelse return;
    const is_active = drag_active and drag_is_vertical and drag_scroll_ptr == info.scroll_ptr;
    drawThumb(thumb.x, thumb.y, thumb.w, thumb.h, is_active);
}

fn renderHorizontal(info: ScrollbarEntry) void {
    const thumb = computeHorizontalThumb(info) orelse return;
    const is_active = drag_active and !drag_is_vertical and drag_scroll_ptr == info.scroll_ptr;
    drawThumb(thumb.x, thumb.y, thumb.w, thumb.h, is_active);
}

fn drawThumb(x: f32, y: f32, w: f32, h: f32, active: bool) void {
    // Fully-rounded corner radius (half the narrow dimension = pill shape)
    const cr = @min(w, h) * 0.5;

    // Shadow / outer glow (slightly larger, darker, behind the thumb)
    {
        const expand: f32 = 1.0;
        drawRoundedRect(
            x - expand,
            y - expand,
            w + expand * 2,
            h + expand * 2,
            cr + expand,
            0,
            0,
            0,
            if (active) @as(u8, 30) else @as(u8, 15),
        );
    }

    // Main thumb
    {
        const td = theme.text_dim;
        const r: u8 = @intFromFloat(td[0]);
        const g: u8 = @intFromFloat(td[1]);
        const b: u8 = @intFromFloat(td[2]);
        const a: u8 = if (active) 160 else 100;
        drawRoundedRect(x, y, w, h, cr, r, g, b, a);
    }
}

// ---------------------------------------------------------------------------
// Rounded rect primitive (filled, single color)
// ---------------------------------------------------------------------------

fn drawRoundedRect(x: f32, y: f32, w: f32, h: f32, radius: f32, r: u8, g: u8, b: u8, a: u8) void {
    if (w <= 0 or h <= 0) return;
    const cr = @min(radius, @min(w, h) * 0.5);

    sgl.beginTriangles();
    sgl.c4b(r, g, b, a);

    // Center body (full width, between top/bottom arcs)
    emitQuad(x, y + cr, w, h - cr * 2);
    // Top strip between corners
    emitQuad(x + cr, y, w - cr * 2, cr);
    // Bottom strip between corners
    emitQuad(x + cr, y + h - cr, w - cr * 2, cr);

    // Corner fans
    cornerFan(x + cr, y + cr, cr, std.math.pi, std.math.pi * 1.5); // TL
    cornerFan(x + w - cr, y + cr, cr, std.math.pi * 1.5, std.math.pi * 2.0); // TR
    cornerFan(x + w - cr, y + h - cr, cr, 0, std.math.pi * 0.5); // BR
    cornerFan(x + cr, y + h - cr, cr, std.math.pi * 0.5, std.math.pi); // BL

    sgl.end();
}

fn emitQuad(x: f32, y: f32, w: f32, h: f32) void {
    if (w <= 0 or h <= 0) return;
    sgl.v2f(x, y);
    sgl.v2f(x + w, y);
    sgl.v2f(x + w, y + h);
    sgl.v2f(x, y);
    sgl.v2f(x + w, y + h);
    sgl.v2f(x, y + h);
}

fn cornerFan(cx: f32, cy: f32, radius: f32, start_angle: f32, end_angle: f32) void {
    if (radius <= 0) return;
    const step = (end_angle - start_angle) / @as(f32, @floatFromInt(SEGMENTS));
    var i: usize = 0;
    while (i < SEGMENTS) : (i += 1) {
        const a0 = start_angle + step * @as(f32, @floatFromInt(i));
        const a1 = start_angle + step * @as(f32, @floatFromInt(i + 1));
        sgl.v2f(cx, cy);
        sgl.v2f(cx + @cos(a0) * radius, cy + @sin(a0) * radius);
        sgl.v2f(cx + @cos(a1) * radius, cy + @sin(a1) * radius);
    }
}
