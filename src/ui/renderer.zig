const std = @import("std");
const sokol = @import("sokol");
const clay = @import("zclay");
const theme = @import("theme");
const font = @import("font");
const graph = @import("graph");

const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sgl = sokol.gl;

var frame_w: f32 = 0; // logical width
var frame_h: f32 = 0; // logical height
var dpi_scale: f32 = 1.0;

// Scissor state — textured quads respect sgl scissors, so we only need
// basic visibility culling (skip fully-invisible elements).
var scissor_active: bool = false;
var clip_x: f32 = 0;
var clip_y: f32 = 0;
var clip_w: f32 = 0;
var clip_h: f32 = 0;

pub fn setup() void {
    sgl.setup(.{
        .max_vertices = 1024 * 1024,
        .logger = .{ .func = slog.func },
    });

    font.init();
}

pub fn shutdown() void {
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
                scissor_active = true;
                clip_x = bb.x;
                clip_y = bb.y;
                clip_w = bb.width;
                clip_h = bb.height;
                // scissorRectf operates in framebuffer pixels, scale from logical
                sgl.scissorRectf(
                    bb.x * dpi_scale,
                    bb.y * dpi_scale,
                    bb.width * dpi_scale,
                    bb.height * dpi_scale,
                    true,
                );
            },
            .scissor_end => {
                scissor_active = false;
                sgl.scissorRectf(0, 0, frame_w * dpi_scale, frame_h * dpi_scale, true);
            },
            else => {},
        }
    }

    // Render graph line overlays on top of Clay elements
    graph.renderAll();

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
