const std = @import("std");
const sokol = @import("sokol");
const theme = @import("theme");
const font = @import("font");

const sgl = sokol.gl;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const MAX_HISTORY: usize = 60; // ~2 minutes at ~2s per snapshot
pub const MAX_TRACKED: usize = 5;

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const DataPoint = struct {
    values: [MAX_TRACKED]f32 = [_]f32{0} ** MAX_TRACKED,
    count: u8 = 0,
    // Per-point process names (rankings change between snapshots)
    names: [MAX_TRACKED][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** MAX_TRACKED,
    name_lens: [MAX_TRACKED]u8 = [_]u8{0} ** MAX_TRACKED,
};

pub const Bounds = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const ValueKind = enum {
    cpu_ticks, // Mach absolute time delta → format as ms or µs
    mem_bytes, // RSS bytes → format as MB/GB
    disk_bytes, // I/O delta bytes → format as KB/MB/GB
};

pub const GraphHistory = struct {
    points: [MAX_HISTORY]DataPoint = [_]DataPoint{.{}} ** MAX_HISTORY,
    head: usize = 0,
    len: usize = 0,
    kind: ValueKind = .cpu_ticks,

    // Current legend names (copied into fixed buffers)
    names: [MAX_TRACKED][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** MAX_TRACKED,
    name_lens: [MAX_TRACKED]u8 = [_]u8{0} ** MAX_TRACKED,
    current_count: u8 = 0,

    // Lerped display values for smooth animation of the latest data point
    display_latest: [MAX_TRACKED]f32 = [_]f32{0} ** MAX_TRACKED,

    pub fn push(self: *GraphHistory, values: []const f32, names: []const []const u8) void {
        const count: u8 = @intCast(@min(values.len, MAX_TRACKED));

        var dp = DataPoint{ .count = count };
        for (0..count) |i| {
            dp.values[i] = values[i];
            // Copy name into the data point for tooltip lookup
            const name = names[i];
            const len: usize = @min(name.len, 31);
            @memcpy(dp.names[i][0..len], name[0..len]);
            if (len < 32) dp.names[i][len] = 0;
            dp.name_lens[i] = @intCast(len);
        }

        self.points[self.head] = dp;
        self.head = (self.head + 1) % MAX_HISTORY;
        if (self.len < MAX_HISTORY) self.len += 1;

        // Update legend names
        self.current_count = count;
        for (0..count) |i| {
            const name = names[i];
            const len: usize = @min(name.len, 31);
            @memcpy(self.names[i][0..len], name[0..len]);
            if (len < 32) self.names[i][len] = 0;
            self.name_lens[i] = @intCast(len);
        }
    }

    pub fn lerpDisplay(self: *GraphHistory) void {
        if (self.len == 0) return;
        const latest = (self.head + MAX_HISTORY - 1) % MAX_HISTORY;
        const dp = self.points[latest];
        const dp_count: usize = @intCast(dp.count);
        for (0..dp_count) |i| {
            self.display_latest[i] += (dp.values[i] - self.display_latest[i]) * 0.15;
        }
    }

    pub fn getName(self: *const GraphHistory, index: usize) []const u8 {
        if (index >= self.current_count) return "";
        return self.names[index][0..self.name_lens[index]];
    }
};

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

pub var cpu_history: GraphHistory = .{ .kind = .cpu_ticks };
pub var mem_history: GraphHistory = .{ .kind = .mem_bytes };
pub var disk_history: GraphHistory = .{ .kind = .disk_bytes };

pub var cpu_bounds: ?Bounds = null;
pub var mem_bounds: ?Bounds = null;
pub var disk_bounds: ?Bounds = null;

/// Clip region for graph overlays. When set, an sgl scissor is applied
/// so graphs don't bleed over the header/tab bar when scrolled.
pub var clip_bounds: ?Bounds = null;

// ---------------------------------------------------------------------------
// Per-core CPU sparkline data
// ---------------------------------------------------------------------------

pub const MAX_SPARK_CORES: usize = 128;
const SPARK_HISTORY: usize = MAX_HISTORY; // same time window as main graphs

var core_data: [MAX_SPARK_CORES][SPARK_HISTORY]f32 = [_][SPARK_HISTORY]f32{[_]f32{0} ** SPARK_HISTORY} ** MAX_SPARK_CORES;
var spark_head: usize = 0;
var spark_len: usize = 0;
pub var spark_core_count: usize = 0;
pub var spark_bounds: ?Bounds = null;

/// Lerped display values for smooth sparkline transitions
pub var display_utils: [MAX_SPARK_CORES]f32 = [_]f32{0} ** MAX_SPARK_CORES;

pub fn lerpCoreDisplay() void {
    if (spark_len == 0) return;
    const latest = (spark_head + SPARK_HISTORY - 1) % SPARK_HISTORY;
    for (0..spark_core_count) |c| {
        display_utils[c] += (core_data[c][latest] - display_utils[c]) * 0.15;
    }
}

pub fn pushCoreData(utils: []const f32) void {
    const count = @min(utils.len, MAX_SPARK_CORES);
    spark_core_count = count;
    for (0..count) |c| {
        core_data[c][spark_head] = utils[c];
    }
    spark_head = (spark_head + 1) % SPARK_HISTORY;
    if (spark_len < SPARK_HISTORY) spark_len += 1;
}

// ---------------------------------------------------------------------------
// Rendering entry point (called from renderer after Clay commands)
// ---------------------------------------------------------------------------

pub fn renderAll() void {
    // Apply scissor so graphs don't bleed over header/tabs when scrolled
    if (clip_bounds) |cb| {
        const dpi = sokol.app.dpiScale();
        sgl.scissorRectf(
            cb.x * dpi,
            cb.y * dpi,
            cb.w * dpi,
            cb.h * dpi,
            true,
        );
    }

    if (cpu_bounds) |b| renderGraph(&cpu_history, b);
    if (mem_bounds) |b| renderGraph(&mem_history, b);
    if (disk_bounds) |b| renderGraph(&disk_history, b);
    if (spark_bounds) |b| renderSparklines(b);

    // Reset scissor to full viewport
    if (clip_bounds != null) {
        sgl.scissorRectf(0, 0, sokol.app.widthf(), sokol.app.heightf(), true);
    }
}

// ---------------------------------------------------------------------------
// Graph rendering
// ---------------------------------------------------------------------------

fn renderGraph(history: *GraphHistory, bounds: Bounds) void {
    if (history.len < 2) return;

    const count: usize = history.current_count;
    if (count == 0) return;

    // Swap latest point with lerped display values for smooth animation
    const latest = (history.head + MAX_HISTORY - 1) % MAX_HISTORY;
    var saved: [MAX_TRACKED]f32 = undefined;
    for (0..count) |j| {
        saved[j] = history.points[latest].values[j];
        history.points[latest].values[j] = history.display_latest[j];
    }
    defer for (0..count) |j| {
        history.points[latest].values[j] = saved[j];
    };

    // Auto-scale: find max value across all visible points
    var max_val: f32 = 0.001; // avoid division by zero
    {
        var i: usize = 0;
        while (i < history.len) : (i += 1) {
            const idx = (history.head + MAX_HISTORY - history.len + i) % MAX_HISTORY;
            const dp = history.points[idx];
            const dp_count: usize = @intCast(dp.count);
            for (0..dp_count) |j| {
                if (dp.values[j] > max_val) max_val = dp.values[j];
            }
        }
    }

    // Grid lines (subtle horizontal guides at 25%, 50%, 75%)
    drawGrid(bounds);

    // Data lines (draw back-to-front so line 0 renders on top)
    var line_idx: usize = count;
    while (line_idx > 0) {
        line_idx -= 1;
        drawLine(history, line_idx, bounds, max_val);
    }

    // Hover tooltip
    renderGraphTooltip(history, bounds, max_val);
}

/// Format a raw graph value into a human-readable string with appropriate units.
fn formatValue(buf: []u8, val: f64, kind: ValueKind) []const u8 {
    return switch (kind) {
        .cpu_ticks => blk: {
            // CPU deltas are nanoseconds of CPU time consumed in ~2s interval
            const ns = val;
            if (ns >= 1_000_000_000.0) {
                break :blk std.fmt.bufPrint(buf, "{d:.1} s", .{ns / 1_000_000_000.0}) catch "";
            } else if (ns >= 1_000_000.0) {
                break :blk std.fmt.bufPrint(buf, "{d:.1} ms", .{ns / 1_000_000.0}) catch "";
            } else if (ns >= 1_000.0) {
                break :blk std.fmt.bufPrint(buf, "{d:.0} \xc2\xb5s", .{ns / 1_000.0}) catch ""; // µs
            } else {
                break :blk std.fmt.bufPrint(buf, "{d:.0} ns", .{ns}) catch "";
            }
        },
        .mem_bytes => blk: {
            const bytes = val;
            if (bytes >= 1_073_741_824.0) { // 1 GiB
                break :blk std.fmt.bufPrint(buf, "{d:.2} GB", .{bytes / 1_073_741_824.0}) catch "";
            } else if (bytes >= 1_048_576.0) { // 1 MiB
                break :blk std.fmt.bufPrint(buf, "{d:.1} MB", .{bytes / 1_048_576.0}) catch "";
            } else if (bytes >= 1_024.0) {
                break :blk std.fmt.bufPrint(buf, "{d:.0} KB", .{bytes / 1_024.0}) catch "";
            } else {
                break :blk std.fmt.bufPrint(buf, "{d:.0} B", .{bytes}) catch "";
            }
        },
        .disk_bytes => blk: {
            // Disk deltas are bytes read+written in ~2s interval
            const bytes = val;
            if (bytes >= 1_073_741_824.0) {
                break :blk std.fmt.bufPrint(buf, "{d:.2} GB", .{bytes / 1_073_741_824.0}) catch "";
            } else if (bytes >= 1_048_576.0) {
                break :blk std.fmt.bufPrint(buf, "{d:.1} MB", .{bytes / 1_048_576.0}) catch "";
            } else if (bytes >= 1_024.0) {
                break :blk std.fmt.bufPrint(buf, "{d:.1} KB", .{bytes / 1_024.0}) catch "";
            } else {
                break :blk std.fmt.bufPrint(buf, "{d:.0} B", .{bytes}) catch "";
            }
        },
    };
}

fn renderGraphTooltip(history: *const GraphHistory, bounds: Bounds, max_val: f32) void {
    // Hit-test: is the mouse within the graph area?
    if (mouse_x < bounds.x or mouse_x >= bounds.x + bounds.w) return;
    if (mouse_y < bounds.y or mouse_y >= bounds.y + bounds.h) return;
    if (history.len < 2) return;

    const n = history.len;
    const dx = bounds.w / @as(f32, @floatFromInt(MAX_HISTORY - 1));
    const x_offset = MAX_HISTORY - n;

    // Map mouse X to the nearest data point index in the ring buffer
    const rel_x = mouse_x - bounds.x;
    const float_idx = rel_x / dx - @as(f32, @floatFromInt(x_offset));
    const snapped: usize = @intFromFloat(@max(@min(@round(float_idx), @as(f32, @floatFromInt(n - 1))), 0));
    const ring_idx = (history.head + MAX_HISTORY - n + snapped) % MAX_HISTORY;
    const dp = history.points[ring_idx];
    const dp_count: usize = @intCast(dp.count);
    if (dp_count == 0) return;

    // Draw vertical crosshair at snapped X
    const snap_x = bounds.x + dx * @as(f32, @floatFromInt(x_offset + snapped));
    sgl.beginLines();
    sgl.c4b(200, 200, 200, 40);
    sgl.v2f(snap_x, bounds.y);
    sgl.v2f(snap_x, bounds.y + bounds.h);
    sgl.end();

    // Measure tooltip size: each line = color dot + name + formatted value
    const fs: f32 = 12.0;
    const pad: f32 = 6.0;
    const line_h: f32 = 16.0;
    const dot_w: f32 = 8.0 + 4.0; // dot + gap

    var tooltip_w: f32 = 0;
    var line_bufs: [MAX_TRACKED][64]u8 = undefined;
    var val_bufs: [MAX_TRACKED][32]u8 = undefined;
    var line_strs: [MAX_TRACKED][]const u8 = undefined;
    for (0..dp_count) |j| {
        const name = dp.names[j][0..dp.name_lens[j]];
        const val_str = formatValue(&val_bufs[j], @as(f64, dp.values[j]), history.kind);
        const label = std.fmt.bufPrint(&line_bufs[j], "{s}: {s}", .{ name, val_str }) catch continue;
        line_strs[j] = label;
        const m = font.measure(label, fs);
        if (dot_w + m.w > tooltip_w) tooltip_w = dot_w + m.w;
    }
    tooltip_w += pad * 2;
    const tooltip_h = pad * 2 + @as(f32, @floatFromInt(dp_count)) * line_h;

    // Position tooltip near mouse, clamped to graph bounds
    var tx = mouse_x + 12;
    var ty = mouse_y - tooltip_h - 4;
    if (tx + tooltip_w > bounds.x + bounds.w) tx = mouse_x - tooltip_w - 8;
    if (ty < bounds.y) ty = bounds.y + 4;

    // Tooltip background
    const tbg = theme.tooltip_bg;
    const ttx = theme.tooltip_text;
    sgl.beginTriangles();
    sgl.c4b(@intFromFloat(tbg[0]), @intFromFloat(tbg[1]), @intFromFloat(tbg[2]), @intFromFloat(tbg[3]));
    sgl.v2f(tx, ty);
    sgl.v2f(tx + tooltip_w, ty);
    sgl.v2f(tx + tooltip_w, ty + tooltip_h);
    sgl.v2f(tx, ty);
    sgl.v2f(tx + tooltip_w, ty + tooltip_h);
    sgl.v2f(tx, ty + tooltip_h);
    sgl.end();

    // Draw each line: color dot + text
    for (0..dp_count) |j| {
        const ly = ty + pad + @as(f32, @floatFromInt(j)) * line_h;
        const color = theme.line_colors[j];

        // Color dot
        sgl.beginTriangles();
        sgl.c4b(@intFromFloat(color[0]), @intFromFloat(color[1]), @intFromFloat(color[2]), 255);
        const dx2: f32 = tx + pad;
        const dy2: f32 = ly + 4.0;
        sgl.v2f(dx2, dy2);
        sgl.v2f(dx2 + 6, dy2);
        sgl.v2f(dx2 + 6, dy2 + 6);
        sgl.v2f(dx2, dy2);
        sgl.v2f(dx2 + 6, dy2 + 6);
        sgl.v2f(dx2, dy2 + 6);
        sgl.end();

        // Dot indicator on the graph line for this point
        const nv = @min(dp.values[j] / max_val, 1.0);
        const dot_gx = snap_x;
        const dot_gy = bounds.y + bounds.h * (1.0 - nv);
        sgl.beginTriangles();
        sgl.c4b(@intFromFloat(color[0]), @intFromFloat(color[1]), @intFromFloat(color[2]), 255);
        const dr: f32 = 3.0;
        sgl.v2f(dot_gx - dr, dot_gy - dr);
        sgl.v2f(dot_gx + dr, dot_gy - dr);
        sgl.v2f(dot_gx + dr, dot_gy + dr);
        sgl.v2f(dot_gx - dr, dot_gy - dr);
        sgl.v2f(dot_gx + dr, dot_gy + dr);
        sgl.v2f(dot_gx - dr, dot_gy + dr);
        sgl.end();

        font.drawText(tx + pad + dot_w, ly, line_strs[j], fs, @intFromFloat(ttx[0]), @intFromFloat(ttx[1]), @intFromFloat(ttx[2]), @intFromFloat(ttx[3]));
    }
}

fn drawGrid(bounds: Bounds) void {
    sgl.beginLines();
    sgl.c4b(128, 128, 128, 20);

    const levels = [_]f32{ 0.25, 0.5, 0.75 };
    for (levels) |level| {
        const gy = bounds.y + bounds.h * (1.0 - level);
        sgl.v2f(bounds.x, gy);
        sgl.v2f(bounds.x + bounds.w, gy);
    }
    sgl.end();
}

fn drawLine(history: *const GraphHistory, line_idx: usize, bounds: Bounds, max_val: f32) void {
    const n = history.len;
    if (n < 2) return;

    const dx = bounds.w / @as(f32, @floatFromInt(MAX_HISTORY - 1));
    const color = theme.line_colors[line_idx];
    const r: u8 = @intFromFloat(color[0]);
    const g: u8 = @intFromFloat(color[1]);
    const b: u8 = @intFromFloat(color[2]);
    const x_offset = MAX_HISTORY - n;

    // Filled area under the line (semi-transparent)
    sgl.beginTriangles();
    sgl.c4b(r, g, b, 25);

    for (0..n - 1) |i| {
        const idx0 = (history.head + MAX_HISTORY - n + i) % MAX_HISTORY;
        const idx1 = (history.head + MAX_HISTORY - n + i + 1) % MAX_HISTORY;

        const v0 = @min(history.points[idx0].values[line_idx] / max_val, 1.0);
        const v1 = @min(history.points[idx1].values[line_idx] / max_val, 1.0);

        const px0 = bounds.x + dx * @as(f32, @floatFromInt(x_offset + i));
        const px1 = bounds.x + dx * @as(f32, @floatFromInt(x_offset + i + 1));
        const py0 = bounds.y + bounds.h * (1.0 - v0);
        const py1 = bounds.y + bounds.h * (1.0 - v1);
        const base_y = bounds.y + bounds.h;

        // Two triangles to fill area from line to baseline
        sgl.v2f(px0, py0);
        sgl.v2f(px1, py1);
        sgl.v2f(px1, base_y);

        sgl.v2f(px0, py0);
        sgl.v2f(px1, base_y);
        sgl.v2f(px0, base_y);
    }
    sgl.end();

    // Line stroke
    sgl.beginLines();
    sgl.c4b(r, g, b, 230);

    for (0..n - 1) |i| {
        const idx0 = (history.head + MAX_HISTORY - n + i) % MAX_HISTORY;
        const idx1 = (history.head + MAX_HISTORY - n + i + 1) % MAX_HISTORY;

        const v0 = @min(history.points[idx0].values[line_idx] / max_val, 1.0);
        const v1 = @min(history.points[idx1].values[line_idx] / max_val, 1.0);

        const px0 = bounds.x + dx * @as(f32, @floatFromInt(x_offset + i));
        const px1 = bounds.x + dx * @as(f32, @floatFromInt(x_offset + i + 1));
        const py0 = bounds.y + bounds.h * (1.0 - v0);
        const py1 = bounds.y + bounds.h * (1.0 - v1);

        sgl.v2f(px0, py0);
        sgl.v2f(px1, py1);
    }
    sgl.end();
}

// ---------------------------------------------------------------------------
// Per-core CPU sparklines
// ---------------------------------------------------------------------------

/// Mouse position for spark tooltip hit-testing (set by main each frame).
pub var mouse_x: f32 = 0;
pub var mouse_y: f32 = 0;

fn renderSparklines(bounds: Bounds) void {
    const count = spark_core_count;
    if (count == 0 or spark_len < 2) return;

    const gap: f32 = 3.0;

    // Auto-calculate grid: aim for sparklines ~80px wide
    const target_w: f32 = 80.0;
    const cols_f = @max(@floor((bounds.w + gap) / (target_w + gap)), 1.0);
    const cols: usize = @intFromFloat(cols_f);
    const rows: usize = (count + cols - 1) / cols;

    const spark_w = (bounds.w - gap * (cols_f - 1.0)) / cols_f;
    const spark_h = if (rows > 0)
        @min((bounds.h - gap * @as(f32, @floatFromInt(if (rows > 1) rows - 1 else 0))) / @as(f32, @floatFromInt(rows)), 28.0)
    else
        28.0;

    const tint = theme.intensity_tint;
    const r: u8 = @intFromFloat(tint[0]);
    const g: u8 = @intFromFloat(tint[1]);
    const b: u8 = @intFromFloat(tint[2]);

    var hovered_core: ?usize = null;

    for (0..count) |ci| {
        const col: usize = ci % cols;
        const row: usize = ci / cols;

        const sx = bounds.x + @as(f32, @floatFromInt(col)) * (spark_w + gap);
        const sy = bounds.y + @as(f32, @floatFromInt(row)) * (spark_h + gap);

        // Hit-test for tooltip
        if (mouse_x >= sx and mouse_x < sx + spark_w and
            mouse_y >= sy and mouse_y < sy + spark_h)
        {
            hovered_core = ci;
        }

        // Background for each sparkline cell
        sgl.beginTriangles();
        sgl.c4b(255, 255, 255, 8);
        sgl.v2f(sx, sy);
        sgl.v2f(sx + spark_w, sy);
        sgl.v2f(sx + spark_w, sy + spark_h);
        sgl.v2f(sx, sy);
        sgl.v2f(sx + spark_w, sy + spark_h);
        sgl.v2f(sx, sy + spark_h);
        sgl.end();

        // Swap latest point with lerped display value for smooth animation
        const latest_idx = (spark_head + SPARK_HISTORY - 1) % SPARK_HISTORY;
        const saved_val = core_data[ci][latest_idx];
        core_data[ci][latest_idx] = display_utils[ci];
        renderOneSparkline(ci, sx, sy, spark_w, spark_h, r, g, b);
        core_data[ci][latest_idx] = saved_val;
    }

    // Draw tooltip for hovered core
    if (hovered_core) |ci| {
        const latest_idx = (spark_head + SPARK_HISTORY - 1) % SPARK_HISTORY;
        const util = @min(core_data[ci][latest_idx], 1.0) * 100.0;
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "Core {d}: {d:.0}%", .{ ci, util }) catch return;

        const fs: f32 = 13.0;
        const m = font.measure(label, fs);
        const pad: f32 = 6.0;
        const tx = mouse_x + 12;
        const ty = mouse_y - m.h - pad * 2;

        // Tooltip background
        const tbg = theme.tooltip_bg;
        const ttx = theme.tooltip_text;
        sgl.beginTriangles();
        sgl.c4b(@intFromFloat(tbg[0]), @intFromFloat(tbg[1]), @intFromFloat(tbg[2]), @intFromFloat(tbg[3]));
        sgl.v2f(tx, ty);
        sgl.v2f(tx + m.w + pad * 2, ty);
        sgl.v2f(tx + m.w + pad * 2, ty + m.h + pad * 2);
        sgl.v2f(tx, ty);
        sgl.v2f(tx + m.w + pad * 2, ty + m.h + pad * 2);
        sgl.v2f(tx, ty + m.h + pad * 2);
        sgl.end();

        font.drawText(tx + pad, ty + pad, label, fs, @intFromFloat(ttx[0]), @intFromFloat(ttx[1]), @intFromFloat(ttx[2]), @intFromFloat(ttx[3]));
    }
}

fn renderOneSparkline(core: usize, sx: f32, sy: f32, sw: f32, sh: f32, r: u8, g: u8, b: u8) void {
    const n = spark_len;
    if (n < 2) return;

    const dx = sw / @as(f32, @floatFromInt(SPARK_HISTORY - 1));
    const x_off = SPARK_HISTORY - n;

    // Filled area
    sgl.beginTriangles();
    sgl.c4b(r, g, b, 30);

    for (0..n - 1) |i| {
        const di0 = (spark_head + SPARK_HISTORY - n + i) % SPARK_HISTORY;
        const di1 = (spark_head + SPARK_HISTORY - n + i + 1) % SPARK_HISTORY;

        const v0 = @min(core_data[core][di0], 1.0);
        const v1 = @min(core_data[core][di1], 1.0);

        const px0 = sx + dx * @as(f32, @floatFromInt(x_off + i));
        const px1 = sx + dx * @as(f32, @floatFromInt(x_off + i + 1));
        const py0 = sy + sh * (1.0 - v0);
        const py1 = sy + sh * (1.0 - v1);
        const base_y = sy + sh;

        sgl.v2f(px0, py0);
        sgl.v2f(px1, py1);
        sgl.v2f(px1, base_y);

        sgl.v2f(px0, py0);
        sgl.v2f(px1, base_y);
        sgl.v2f(px0, base_y);
    }
    sgl.end();

    // Line stroke
    sgl.beginLines();
    sgl.c4b(r, g, b, 200);

    for (0..n - 1) |i| {
        const di0 = (spark_head + SPARK_HISTORY - n + i) % SPARK_HISTORY;
        const di1 = (spark_head + SPARK_HISTORY - n + i + 1) % SPARK_HISTORY;

        const v0 = @min(core_data[core][di0], 1.0);
        const v1 = @min(core_data[core][di1], 1.0);

        const px0 = sx + dx * @as(f32, @floatFromInt(x_off + i));
        const px1 = sx + dx * @as(f32, @floatFromInt(x_off + i + 1));
        const py0 = sy + sh * (1.0 - v0);
        const py1 = sy + sh * (1.0 - v1);

        sgl.v2f(px0, py0);
        sgl.v2f(px1, py1);
    }
    sgl.end();
}
