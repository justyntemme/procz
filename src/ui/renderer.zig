const std = @import("std");
const sokol = @import("sokol");
const clay = @import("zclay");
const theme = @import("theme");
const font = @import("font");
const graph = @import("graph");
const scrollbar = @import("scrollbar");
const icon_cache = @import("icon_cache");

const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sgl = sokol.gl;

var frame_w: f32 = 0; // logical width
var frame_h: f32 = 0; // logical height
var dpi_scale: f32 = 1.0;

// Scissor stack — supports nested clip containers by intersecting rects.
const MAX_SCISSOR_DEPTH = 8;
var scissor_stack: [MAX_SCISSOR_DEPTH]ScissorRect = undefined;
var scissor_depth: usize = 0;
var scissor_active: bool = false;
var clip_x: f32 = 0;
var clip_y: f32 = 0;
var clip_w: f32 = 0;
var clip_h: f32 = 0;

const ScissorRect = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn setup() void {
    sgl.setup(.{
        .max_vertices = 1024 * 1024,
        .logger = .{ .func = slog.func },
    });

    font.init();
    icon_cache.init();
}

pub fn shutdown() void {
    icon_cache.shutdown();
    font.shutdown();
    sgl.shutdown();
}

/// Clay MeasureText callback.
pub fn measureText(text: []const u8, config: *clay.TextElementConfig, _: void) clay.Dimensions {
    const size: f32 = @floatFromInt(config.font_size);
    const m = font.measure(text, size);
    return .{ .w = m.w, .h = m.h };
}

/// Render Clay commands using sgl (rects, text via font atlas).
/// Call inside an sg render pass.
pub fn render(commands: []const clay.RenderCommand) void {
    dpi_scale = sapp.dpiScale();
    // Use logical coordinates — the GPU viewport is framebuffer-sized,
    // so each logical pixel maps to dpi_scale physical pixels automatically.
    frame_w = sapp.widthf() / dpi_scale;
    frame_h = sapp.heightf() / dpi_scale;

    // Reset scissor state
    scissor_active = false;
    scissor_depth = 0;

    // Set up sgl orthographic projection in logical coordinates (top-left origin)
    sgl.defaults();
    sgl.matrixModeProjection();
    sgl.ortho(0, frame_w, frame_h, 0, -1, 1);

    for (commands) |cmd| {
        switch (cmd.command_type) {
            .rectangle => {
                if (isVisible(cmd.bounding_box)) renderRect(cmd);
            },
            .text => {
                if (isVisible(cmd.bounding_box)) renderText(cmd);
            },
            .border => renderBorder(cmd),
            .scissor_start => {
                const bb = cmd.bounding_box;
                // Push current scissor onto stack before overwriting
                if (scissor_active and scissor_depth < MAX_SCISSOR_DEPTH) {
                    scissor_stack[scissor_depth] = .{ .x = clip_x, .y = clip_y, .w = clip_w, .h = clip_h };
                    scissor_depth += 1;
                }
                // Compute new scissor — intersect with parent if nested
                var new_x = bb.x;
                var new_y = bb.y;
                var new_r = bb.x + bb.width;
                var new_b = bb.y + bb.height;
                if (scissor_active) {
                    // Intersect with current active scissor
                    new_x = @max(new_x, clip_x);
                    new_y = @max(new_y, clip_y);
                    new_r = @min(new_r, clip_x + clip_w);
                    new_b = @min(new_b, clip_y + clip_h);
                }
                clip_x = new_x;
                clip_y = new_y;
                clip_w = @max(0, new_r - new_x);
                clip_h = @max(0, new_b - new_y);
                scissor_active = true;
                sgl.scissorRectf(
                    clip_x * dpi_scale,
                    clip_y * dpi_scale,
                    clip_w * dpi_scale,
                    clip_h * dpi_scale,
                    true,
                );
            },
            .scissor_end => {
                if (scissor_depth > 0) {
                    // Pop back to parent scissor
                    scissor_depth -= 1;
                    const prev = scissor_stack[scissor_depth];
                    clip_x = prev.x;
                    clip_y = prev.y;
                    clip_w = prev.w;
                    clip_h = prev.h;
                    sgl.scissorRectf(
                        clip_x * dpi_scale,
                        clip_y * dpi_scale,
                        clip_w * dpi_scale,
                        clip_h * dpi_scale,
                        true,
                    );
                } else {
                    scissor_active = false;
                    sgl.scissorRectf(0, 0, frame_w * dpi_scale, frame_h * dpi_scale, true);
                }
            },
            else => {},
        }
    }

    // Render app icons at "ico" element positions
    renderIcons(commands);

    // Render graph line overlays on top of Clay elements
    graph.renderAll();

    // Render scrollbar overlays
    scrollbar.renderAll();

    // Log sgl errors (rate-limited)
    const err = sgl.getError();
    if (err.any) {
        const err_state = struct {
            var logged: u32 = 0;
        };
        if (err_state.logged < 10) {
            std.debug.print("sgl ERROR: verts_full={} uniforms_full={} cmds_full={} stack_over={} stack_under={} no_ctx={}\n", .{
                err.vertices_full, err.uniforms_full, err.commands_full,
                err.stack_overflow, err.stack_underflow, err.no_context,
            });
            err_state.logged += 1;
        }
    }

    sgl.draw();
}

/// Returns false if the bounding box is fully outside the current scissor rect.
fn isVisible(bb: clay.BoundingBox) bool {
    if (!scissor_active) return true;
    if (bb.x + bb.width <= clip_x) return false;
    if (bb.x >= clip_x + clip_w) return false;
    if (bb.y + bb.height <= clip_y) return false;
    if (bb.y >= clip_y + clip_h) return false;
    return true;
}

fn renderRect(cmd: clay.RenderCommand) void {
    const bb = cmd.bounding_box;
    const rect_data = cmd.render_data.rectangle;
    const c = rect_data.background_color;
    const r: u8 = @intFromFloat(c[0]);
    const g: u8 = @intFromFloat(c[1]);
    const b: u8 = @intFromFloat(c[2]);
    const a: u8 = @intFromFloat(c[3]);

    const cr = rect_data.corner_radius;
    const has_radius = cr.top_left > 0 or cr.top_right > 0 or cr.bottom_left > 0 or cr.bottom_right > 0;

    if (has_radius) {
        renderRoundedRect(bb.x, bb.y, bb.width, bb.height, cr, r, g, b, a);
    } else {
        sgl.beginQuads();
        sgl.c4b(r, g, b, a);
        sgl.v2f(bb.x, bb.y);
        sgl.v2f(bb.x + bb.width, bb.y);
        sgl.v2f(bb.x + bb.width, bb.y + bb.height);
        sgl.v2f(bb.x, bb.y + bb.height);
        sgl.end();
    }
}

/// Approximate rounded rectangle using triangle fans at each corner.
fn renderRoundedRect(x: f32, y: f32, w: f32, h: f32, cr: clay.CornerRadius, r: u8, g: u8, b: u8, a: u8) void {
    const segments: usize = 6; // segments per corner arc

    sgl.beginTriangles();
    sgl.c4b(r, g, b, a);

    // Clamp radii to half the smallest dimension
    const max_r = @min(w, h) * 0.5;
    const tl = @min(cr.top_left, max_r);
    const tr = @min(cr.top_right, max_r);
    const bl = @min(cr.bottom_left, max_r);
    const br = @min(cr.bottom_right, max_r);

    // Center rectangle (full width, between top/bottom radii)
    const top_max = @max(tl, tr);
    const bot_max = @max(bl, br);
    emitQuadAsTriangles(x, y + top_max, w, h - top_max - bot_max);

    // Top strip (between corners)
    emitQuadAsTriangles(x + tl, y, w - tl - tr, top_max);

    // Bottom strip (between corners)
    emitQuadAsTriangles(x + bl, y + h - bot_max, w - bl - br, bot_max);

    // Corner fans
    cornerFan(x + tl, y + tl, tl, std.math.pi, std.math.pi * 1.5, segments); // top-left
    cornerFan(x + w - tr, y + tr, tr, std.math.pi * 1.5, std.math.pi * 2.0, segments); // top-right
    cornerFan(x + w - br, y + h - br, br, 0, std.math.pi * 0.5, segments); // bottom-right
    cornerFan(x + bl, y + h - bl, bl, std.math.pi * 0.5, std.math.pi, segments); // bottom-left

    sgl.end();
}

fn emitQuadAsTriangles(x: f32, y: f32, w: f32, h: f32) void {
    if (w <= 0 or h <= 0) return;
    // Triangle 1
    sgl.v2f(x, y);
    sgl.v2f(x + w, y);
    sgl.v2f(x + w, y + h);
    // Triangle 2
    sgl.v2f(x, y);
    sgl.v2f(x + w, y + h);
    sgl.v2f(x, y + h);
}

fn cornerFan(cx: f32, cy: f32, radius: f32, start_angle: f32, end_angle: f32, segments: usize) void {
    if (radius <= 0) return;
    const step = (end_angle - start_angle) / @as(f32, @floatFromInt(segments));

    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const a0 = start_angle + step * @as(f32, @floatFromInt(i));
        const a1 = start_angle + step * @as(f32, @floatFromInt(i + 1));
        sgl.v2f(cx, cy);
        sgl.v2f(cx + @cos(a0) * radius, cy + @sin(a0) * radius);
        sgl.v2f(cx + @cos(a1) * radius, cy + @sin(a1) * radius);
    }
}

fn renderText(cmd: clay.RenderCommand) void {
    const bb = cmd.bounding_box;
    const td = cmd.render_data.text;
    const c = td.text_color;
    const r: u8 = @intFromFloat(c[0]);
    const g: u8 = @intFromFloat(c[1]);
    const b: u8 = @intFromFloat(c[2]);
    const a: u8 = @intFromFloat(c[3]);

    const len: usize = @intCast(td.string_contents.length);
    const chars = td.string_contents.chars;
    const text = chars[0..len];
    const size: f32 = @floatFromInt(td.font_size);

    font.drawText(bb.x, bb.y, text, size, r, g, b, a);
}

fn renderBorder(cmd: clay.RenderCommand) void {
    const bb = cmd.bounding_box;
    const bd = cmd.render_data.border;
    const cr = bd.corner_radius;
    const has_radius = cr.top_left > 0 or cr.top_right > 0 or cr.bottom_left > 0 or cr.bottom_right > 0;

    if (has_radius) {
        renderRoundedBorder(bb, bd);
    } else {
        renderStraightBorder(bb, bd);
    }
}

fn renderStraightBorder(bb: clay.BoundingBox, bd: clay.BorderRenderData) void {
    const c = bd.color;
    const r: u8 = @intFromFloat(c[0]);
    const g: u8 = @intFromFloat(c[1]);
    const b: u8 = @intFromFloat(c[2]);
    const a: u8 = @intFromFloat(c[3]);

    sgl.beginQuads();
    sgl.c4b(r, g, b, a);

    const w = bd.width;

    if (w.top > 0) {
        const t: f32 = @floatFromInt(w.top);
        sgl.v2f(bb.x, bb.y);
        sgl.v2f(bb.x + bb.width, bb.y);
        sgl.v2f(bb.x + bb.width, bb.y + t);
        sgl.v2f(bb.x, bb.y + t);
    }
    if (w.bottom > 0) {
        const t: f32 = @floatFromInt(w.bottom);
        sgl.v2f(bb.x, bb.y + bb.height - t);
        sgl.v2f(bb.x + bb.width, bb.y + bb.height - t);
        sgl.v2f(bb.x + bb.width, bb.y + bb.height);
        sgl.v2f(bb.x, bb.y + bb.height);
    }
    if (w.left > 0) {
        const t: f32 = @floatFromInt(w.left);
        sgl.v2f(bb.x, bb.y);
        sgl.v2f(bb.x + t, bb.y);
        sgl.v2f(bb.x + t, bb.y + bb.height);
        sgl.v2f(bb.x, bb.y + bb.height);
    }
    if (w.right > 0) {
        const t: f32 = @floatFromInt(w.right);
        sgl.v2f(bb.x + bb.width - t, bb.y);
        sgl.v2f(bb.x + bb.width, bb.y);
        sgl.v2f(bb.x + bb.width, bb.y + bb.height);
        sgl.v2f(bb.x + bb.width - t, bb.y + bb.height);
    }

    sgl.end();
}

/// Rounded border: traces the outline of a rounded rectangle as a strip
/// of triangles, respecting per-corner radii and per-side border widths.
fn renderRoundedBorder(bb: clay.BoundingBox, bd: clay.BorderRenderData) void {
    const c = bd.color;
    const r: u8 = @intFromFloat(c[0]);
    const g: u8 = @intFromFloat(c[1]);
    const b: u8 = @intFromFloat(c[2]);
    const a: u8 = @intFromFloat(c[3]);
    const w = bd.width;

    // Use the max border width as a uniform thickness for the rounded outline.
    // Most rounded borders (like the search pill) use the same width on all sides.
    const t_top: f32 = @floatFromInt(w.top);
    const t_bot: f32 = @floatFromInt(w.bottom);
    const t_left: f32 = @floatFromInt(w.left);
    const t_right: f32 = @floatFromInt(w.right);

    // If no sides have width, nothing to draw
    if (t_top == 0 and t_bot == 0 and t_left == 0 and t_right == 0) return;

    const max_r = @min(bb.width, bb.height) * 0.5;
    const tl = @min(bd.corner_radius.top_left, max_r);
    const tr = @min(bd.corner_radius.top_right, max_r);
    const bl_r = @min(bd.corner_radius.bottom_left, max_r);
    const br_r = @min(bd.corner_radius.bottom_right, max_r);

    sgl.beginTriangles();
    sgl.c4b(r, g, b, a);

    // Top edge (straight segment between top-left and top-right corners)
    if (t_top > 0) {
        emitQuadAsTriangles(bb.x + tl, bb.y, bb.width - tl - tr, t_top);
    }

    // Bottom edge
    if (t_bot > 0) {
        emitQuadAsTriangles(bb.x + bl_r, bb.y + bb.height - t_bot, bb.width - bl_r - br_r, t_bot);
    }

    // Left edge (straight segment between top-left and bottom-left corners)
    if (t_left > 0) {
        emitQuadAsTriangles(bb.x, bb.y + tl, t_left, bb.height - tl - bl_r);
    }

    // Right edge
    if (t_right > 0) {
        emitQuadAsTriangles(bb.x + bb.width - t_right, bb.y + tr, t_right, bb.height - tr - br_r);
    }

    // Corner arcs — drawn as ring segments (outer arc to inner arc)
    const segments: usize = 8;

    // Top-left corner
    if (tl > 0) {
        const inner_tl = @max(0, tl - @max(t_top, t_left));
        cornerRing(bb.x + tl, bb.y + tl, tl, inner_tl, std.math.pi, std.math.pi * 1.5, segments);
    }

    // Top-right corner
    if (tr > 0) {
        const inner_tr = @max(0, tr - @max(t_top, t_right));
        cornerRing(bb.x + bb.width - tr, bb.y + tr, tr, inner_tr, std.math.pi * 1.5, std.math.pi * 2.0, segments);
    }

    // Bottom-right corner
    if (br_r > 0) {
        const inner_br = @max(0, br_r - @max(t_bot, t_right));
        cornerRing(bb.x + bb.width - br_r, bb.y + bb.height - br_r, br_r, inner_br, 0, std.math.pi * 0.5, segments);
    }

    // Bottom-left corner
    if (bl_r > 0) {
        const inner_bl = @max(0, bl_r - @max(t_bot, t_left));
        cornerRing(bb.x + bl_r, bb.y + bb.height - bl_r, bl_r, inner_bl, std.math.pi * 0.5, std.math.pi, segments);
    }

    sgl.end();
}

/// Draw a ring segment (arc strip) between an outer and inner radius.
fn cornerRing(cx: f32, cy: f32, outer_r: f32, inner_r: f32, start: f32, end: f32, segments: usize) void {
    if (outer_r <= 0) return;
    const step = (end - start) / @as(f32, @floatFromInt(segments));

    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const a0 = start + step * @as(f32, @floatFromInt(i));
        const a1 = start + step * @as(f32, @floatFromInt(i + 1));
        const cos0 = @cos(a0);
        const sin0 = @sin(a0);
        const cos1 = @cos(a1);
        const sin1 = @sin(a1);

        // Outer edge
        const ox0 = cx + cos0 * outer_r;
        const oy0 = cy + sin0 * outer_r;
        const ox1 = cx + cos1 * outer_r;
        const oy1 = cy + sin1 * outer_r;

        // Inner edge
        const ix0 = cx + cos0 * inner_r;
        const iy0 = cy + sin0 * inner_r;
        const ix1 = cx + cos1 * inner_r;
        const iy1 = cy + sin1 * inner_r;

        // Two triangles forming a quad strip segment
        sgl.v2f(ox0, oy0);
        sgl.v2f(ox1, oy1);
        sgl.v2f(ix0, iy0);

        sgl.v2f(ix0, iy0);
        sgl.v2f(ox1, oy1);
        sgl.v2f(ix1, iy1);
    }
}

// ---------------------------------------------------------------------------
// App icon rendering pass
// ---------------------------------------------------------------------------

fn renderIcons(commands: []const clay.RenderCommand) void {
    const pids = icon_cache.visible_pids;
    if (pids.len == 0) return;

    // Find the scroll container's scissor region from the command stream.
    // The "scroll" element (process list) emits a scissor_start that defines
    // the visible area. We capture it so icons are clipped to the scroll area.
    var scroll_clip: ?struct { x: f32, y: f32, w: f32, h: f32 } = null;
    const scroll_id = clay.ElementId.ID("scroll").id;
    for (commands) |cmd| {
        if (cmd.command_type == .scissor_start and cmd.id == scroll_id) {
            scroll_clip = .{
                .x = cmd.bounding_box.x,
                .y = cmd.bounding_box.y,
                .w = cmd.bounding_box.width,
                .h = cmd.bounding_box.height,
            };
            break;
        }
    }

    // No scroll container found — likely on performance tab, skip icons
    const sc = scroll_clip orelse return;

    // Apply scissor to clip icons to the scroll area
    sgl.scissorRectf(
        sc.x * dpi_scale,
        sc.y * dpi_scale,
        sc.w * dpi_scale,
        sc.h * dpi_scale,
        true,
    );

    // Build a lookup map: element ID → PID index.
    // Only pre-compute IDs for the visible row range (~30 rows) instead of
    // all 2048. This reduces the inner matching loop from O(2048) to O(~30).
    const range = icon_cache.visible_range;
    const max_rows: usize = pids.len;
    const start = @min(range.first, max_rows);
    const end = @min(start + range.count, max_rows);
    const id_count = end - start;
    if (id_count == 0) return;

    var id_map: [128]u32 = undefined; // 128 is more than enough for visible rows
    var id_indices: [128]usize = undefined;
    const count = @min(id_count, 128);
    for (0..count) |i| {
        id_map[i] = clay.ElementId.IDI("ico", @intCast(start + i)).id;
        id_indices[i] = start + i;
    }

    // Scan commands for icon elements (16×16 rects)
    for (commands) |cmd| {
        if (cmd.command_type != .rectangle) continue;
        const bb = cmd.bounding_box;
        // Quick size filter: icon elements are exactly 16×16
        if (bb.width < 15.5 or bb.width > 16.5 or bb.height < 15.5 or bb.height > 16.5) continue;

        // Clip test against scroll area
        if (bb.y + bb.height <= sc.y or bb.y >= sc.y + sc.h) continue;

        // Match against pre-computed IDs (only visible rows)
        for (id_map[0..count], id_indices[0..count]) |expected_id, idx| {
            if (cmd.id == expected_id) {
                const pid = pids[idx];
                if (icon_cache.getOrLoad(pid)) |uv| {
                    icon_cache.drawIcon(bb.x, bb.y, bb.width, bb.height, uv);
                }
                break;
            }
        }
    }

    // Upload any newly loaded icons to GPU
    icon_cache.flush();

    // Reset scissor to full viewport
    sgl.scissorRectf(0, 0, frame_w * dpi_scale, frame_h * dpi_scale, true);
}
