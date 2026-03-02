const std = @import("std");
const process = @import("process");
const tree = @import("tree");
const layout = @import("layout");
const platform = @import("platform");
const font = @import("font");
const theme = @import("theme");

// ---------------------------------------------------------------------------
// Data types shared with main.zig
// ---------------------------------------------------------------------------

pub const DeltaEntry = struct { cpu: u64 = 0, disk: u64 = 0, gpu: u64 = 0 };
pub const PrevEntry = struct { cpu: u64 = 0, disk: u64 = 0, gpu: u64 = 0 };

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

const TreeEntry = struct {
    pid: process.pid_t,
    proc_data: process.Proc,
    depth: u16,
    cpu_delta: u64 = 0,
    disk_delta: u64 = 0,
    gpu_delta: u64 = 0,
    is_parent: bool = false,
    is_expanded: bool = true,
    search_match: bool = true, // false = ancestor shown for tree context
};

const SortContext = struct {
    column: layout.SortColumn,
    direction: layout.SortDirection,
};

// ---------------------------------------------------------------------------
// Materialization parameters and result
// ---------------------------------------------------------------------------

pub const MaterializeParams = struct {
    rows: []const tree.FlatRow,
    tree_pids: []const process.pid_t,
    proc_map: *const std.AutoHashMap(process.pid_t, process.Proc),
    delta_map: *const std.AutoHashMap(process.pid_t, DeltaEntry),
    exited_pids: *const std.AutoHashMap(process.pid_t, void),
    sort_column: layout.SortColumn,
    sort_direction: layout.SortDirection,
    search_text: []const u8,
    col_widths: [6]f32,
    window_width: f32,
    snapshot_interval_ns: u64,
    core_count: usize,
    total_memory: u64,
    proc_count: usize,
    core_utils: []const f32,
    collapsed_pids: ?*const std.AutoHashMap(process.pid_t, void) = null,
    tree_adj: ?*const tree.Adjacency = null,
    tree_pid_to_index: ?*const std.AutoHashMap(process.pid_t, u32) = null,
};

pub const MaterializedResult = struct {
    rows: []layout.RowText,
    display_pids: []process.pid_t,
    summary: layout.SystemSummary,
};

// ---------------------------------------------------------------------------
// Entry point: materialize display data from snapshot
// ---------------------------------------------------------------------------

pub fn materialize(alloc: std.mem.Allocator, params: MaterializeParams) !MaterializedResult {
    // Compute summary from full proc_map (not affected by search/sort)
    var summary = computeSummary(alloc, params);

    if (params.rows.len == 0) {
        finishHeaderStats(alloc, &summary, 0, params);
        return .{
            .rows = &.{},
            .display_pids = &.{},
            .summary = summary,
        };
    }

    const has_search = params.search_text.len > 0;

    // Filter out exited PIDs, collapsed subtrees, and attach deltas.
    // When searching: skip collapse filtering so collapsed children are searchable.
    var filtered: std.ArrayListUnmanaged(TreeEntry) = .empty;
    try filtered.ensureTotalCapacity(alloc, params.rows.len);

    var skip_depth: ?u16 = null; // skip children at depth > this
    for (params.rows) |row| {
        const pid = params.tree_pids[row.index];

        // Handle collapsed subtree skipping (only when NOT searching)
        if (!has_search) {
            if (skip_depth) |sd| {
                if (row.depth > sd) continue;
                skip_depth = null;
            }
        }

        if (params.exited_pids.contains(pid)) continue;
        const p = params.proc_map.get(pid) orelse continue;
        const d = params.delta_map.get(pid) orelse DeltaEntry{};

        // Check if this node has children (is_parent) using tree adjacency
        var has_children = false;
        if (params.tree_adj) |adj| {
            if (params.tree_pid_to_index) |pid_map| {
                if (pid_map.get(pid)) |idx| {
                    has_children = adj.childrenOf(idx).len > 0;
                }
            }
        }

        // Check if this node is collapsed (ignored during search)
        const is_collapsed = if (!has_search)
            (if (params.collapsed_pids) |cp| cp.contains(pid) else false)
        else
            false;
        const is_expanded = !is_collapsed;

        // If collapsed, skip all descendants
        if (!has_search and is_collapsed and has_children) {
            skip_depth = row.depth;
        }

        filtered.appendAssumeCapacity(.{
            .pid = pid,
            .proc_data = p,
            .depth = row.depth,
            .cpu_delta = d.cpu,
            .disk_delta = d.disk,
            .gpu_delta = d.gpu,
            .is_parent = has_children,
            .is_expanded = is_expanded,
        });
    }

    // Search filter — preserve tree hierarchy by keeping matches + their ancestors
    if (has_search) {
        // Pass 1: find PIDs that directly match the search
        var match_set: std.AutoHashMapUnmanaged(process.pid_t, void) = .empty;
        try match_set.ensureTotalCapacity(alloc, @intCast(@min(filtered.items.len, 512)));
        for (filtered.items) |entry| {
            if (caseInsensitiveContains(entry.proc_data.name, params.search_text) or
                caseInsensitiveContains(entry.proc_data.path, params.search_text))
            {
                match_set.put(alloc, entry.pid, {}) catch {};
            }
        }

        // Pass 2: walk ancestor chains from each match to build ancestor set
        var ancestor_set: std.AutoHashMapUnmanaged(process.pid_t, void) = .empty;
        var match_iter = match_set.keyIterator();
        while (match_iter.next()) |pid_ptr| {
            var current_pid = pid_ptr.*;
            while (true) {
                const proc = params.proc_map.get(current_pid) orelse break;
                current_pid = proc.ppid;
                if (current_pid <= 0) break;
                if (ancestor_set.contains(current_pid) or match_set.contains(current_pid)) break;
                ancestor_set.put(alloc, current_pid, {}) catch {};
            }
        }

        // Pass 3: keep only matches + ancestors, preserving DFS tree order
        var w: usize = 0;
        for (filtered.items) |*entry| {
            const is_match = match_set.contains(entry.pid);
            const is_ancestor = ancestor_set.contains(entry.pid);
            if (is_match or is_ancestor) {
                // Force-expand ancestors of matches so the tree path is visible
                if (is_ancestor) {
                    entry.is_expanded = true;
                }
                entry.search_match = is_match;
                filtered.items[w] = entry.*;
                w += 1;
            }
        }
        filtered.shrinkRetainingCapacity(w);
    }

    // Sort: explicit column sort takes priority; search preserves tree order (no relevance sort)
    const is_sorted = params.sort_column != .none;
    if (is_sorted) {
        const sort_ctx = SortContext{ .column = params.sort_column, .direction = params.sort_direction };
        std.mem.sortUnstable(TreeEntry, filtered.items, sort_ctx, sortCompare);
    }
    const items = filtered.items;

    // Build parallel PID list
    var pid_list: std.ArrayListUnmanaged(process.pid_t) = .empty;
    try pid_list.ensureTotalCapacity(alloc, items.len);
    for (items) |entry| {
        pid_list.appendAssumeCapacity(entry.pid);
    }
    const display_pids = try pid_list.toOwnedSlice(alloc);

    // Compute path pixel budget
    const path_budget = params.window_width - params.col_widths[0] - params.col_widths[1] - params.col_widths[2] - params.col_widths[3] - params.col_widths[4] - params.col_widths[5] - 24;

    // System-relative intensity normalization
    const total_mem_f: f64 = if (params.total_memory > 0) @floatFromInt(params.total_memory) else 1.0;
    const interval_f: f64 = @floatFromInt(@max(params.snapshot_interval_ns, 1));
    const cores_f: f64 = @floatFromInt(@max(params.core_count, 1));
    const cpu_capacity: f64 = interval_f * cores_f;
    const disk_ref: f64 = 200.0 * 1024.0 * 1024.0;

    // Build RowTexts
    var texts: std.ArrayListUnmanaged(layout.RowText) = .empty;
    try texts.ensureTotalCapacity(alloc, items.len);

    for (items) |entry| {
        const cpu_intensity: f32 = @floatCast(@min(@as(f64, @floatFromInt(entry.cpu_delta)) / cpu_capacity, 1.0));
        const mem_intensity: f32 = @floatCast(@min(@as(f64, @floatFromInt(entry.proc_data.mem_rss)) / total_mem_f, 1.0));
        const disk_intensity: f32 = @floatCast(@min(@as(f64, @floatFromInt(entry.disk_delta)) / disk_ref, 1.0));
        const gpu_intensity: f32 = @floatCast(@min(@as(f64, @floatFromInt(entry.gpu_delta)) / interval_f, 1.0));

        texts.appendAssumeCapacity(.{
            .pid_str = truncateToFit(
                std.fmt.allocPrint(alloc, "{d}", .{entry.pid}) catch "?",
                params.col_widths[0], theme.font_size, alloc,
            ),
            .name_prefix = "",
            .name = entry.proc_data.name,
            .cpu_str = truncateToFit(
                formatCpuPercent(alloc, entry.cpu_delta, params.snapshot_interval_ns) catch "0%",
                params.col_widths[2], theme.font_size, alloc,
            ),
            .mem_str = truncateToFit(
                formatRss(alloc, entry.proc_data.mem_rss) catch "?",
                params.col_widths[3], theme.font_size, alloc,
            ),
            .disk_str = truncateToFit(
                formatDiskRate(alloc, entry.disk_delta, params.snapshot_interval_ns) catch "0 B/s",
                params.col_widths[4], theme.font_size, alloc,
            ),
            .gpu_str = truncateToFit(
                formatGpuPercent(alloc, entry.gpu_delta, params.snapshot_interval_ns) catch "0%",
                params.col_widths[5], theme.font_size, alloc,
            ),
            .path_str = if (path_budget > 30)
                middleTruncatePathToFit(entry.proc_data.path, path_budget, theme.font_size, alloc)
            else
                "",
            .full_path = entry.proc_data.path,
            .depth = if (is_sorted) 0 else entry.depth,
            .cpu_intensity = cpu_intensity,
            .mem_intensity = mem_intensity,
            .disk_intensity = disk_intensity,
            .gpu_intensity = gpu_intensity,
            .raw_cpu = entry.cpu_delta,
            .raw_mem = entry.proc_data.mem_rss,
            .raw_disk = entry.disk_delta,
            .raw_gpu = entry.gpu_delta,
            .pid = entry.pid,
            .is_parent = if (is_sorted) false else entry.is_parent,
            .is_expanded = if (is_sorted) true else entry.is_expanded,
            .search_match = entry.search_match,
        });
    }

    const rows = try texts.toOwnedSlice(alloc);

    // Finalize header stats with display count
    finishHeaderStats(alloc, &summary, display_pids.len, params);

    return .{
        .rows = rows,
        .display_pids = display_pids,
        .summary = summary,
    };
}

// ---------------------------------------------------------------------------
// Summary computation
// ---------------------------------------------------------------------------

fn computeSummary(alloc: std.mem.Allocator, params: MaterializeParams) layout.SystemSummary {
    var summary = layout.SystemSummary{};
    summary.proc_count = params.proc_count;

    var iter = params.proc_map.iterator();
    while (iter.next()) |entry| {
        const p = entry.value_ptr.*;
        summary.total_rss += p.mem_rss;

        const cpu_total = p.total_user + p.total_system;
        const disk_total = p.diskio_bytes_read + p.diskio_bytes_written;
        insertTop5(&summary.top_cpu, &summary.top_cpu_count, p.name, cpu_total);
        insertTop5(&summary.top_mem, &summary.top_mem_count, p.name, p.mem_rss);
        insertTop5(&summary.top_disk, &summary.top_disk_count, p.name, disk_total);
    }

    for (summary.top_cpu[0..@intCast(summary.top_cpu_count)]) |*e| {
        e.value_str = formatCumulativeTime(alloc, e.value) catch "?";
    }
    for (summary.top_mem[0..@intCast(summary.top_mem_count)]) |*e| {
        e.value_str = formatRss(alloc, e.value) catch "?";
    }
    for (summary.top_disk[0..@intCast(summary.top_disk_count)]) |*e| {
        e.value_str = formatRss(alloc, e.value) catch "?";
    }
    summary.total_rss_str = formatRss(alloc, summary.total_rss) catch "?";

    summary.mem_title_str = std.fmt.allocPrint(alloc, "Memory ({s} total)", .{
        summary.total_rss_str,
    }) catch "Memory";

    // Copy per-core CPU utilization
    summary.core_count = @intCast(params.core_utils.len);
    for (params.core_utils, 0..) |util, i| {
        summary.core_utils[i] = util;
    }

    return summary;
}

fn finishHeaderStats(alloc: std.mem.Allocator, summary: *layout.SystemSummary, display_count: usize, params: MaterializeParams) void {
    if (params.search_text.len > 0) {
        summary.header_stats_str = std.fmt.allocPrint(alloc, "{d}/{d} procs | {s} RSS", .{
            display_count,
            params.proc_count,
            summary.total_rss_str,
        }) catch "?";
    } else {
        summary.header_stats_str = std.fmt.allocPrint(alloc, "{d} procs | {s} RSS", .{
            params.proc_count,
            summary.total_rss_str,
        }) catch "?";
    }
}

fn insertTop5(arr: *[5]layout.TopEntry, count: *u8, name: []const u8, value: u64) void {
    if (value == 0) return;

    const c: usize = @intCast(count.*);
    if (c < 5) {
        arr[c] = .{ .name = name, .value = value };
        count.* += 1;
        var j: usize = c;
        while (j > 0 and arr[j].value > arr[j - 1].value) {
            const tmp = arr[j];
            arr[j] = arr[j - 1];
            arr[j - 1] = tmp;
            j -= 1;
        }
    } else if (value > arr[4].value) {
        arr[4] = .{ .name = name, .value = value };
        var j: usize = 4;
        while (j > 0 and arr[j].value > arr[j - 1].value) {
            const tmp = arr[j];
            arr[j] = arr[j - 1];
            arr[j - 1] = tmp;
            j -= 1;
        }
    }
}

// ---------------------------------------------------------------------------
// Sort
// ---------------------------------------------------------------------------

fn sortCompare(ctx: SortContext, a: TreeEntry, b: TreeEntry) bool {
    const order = switch (ctx.column) {
        .name => std.mem.order(u8, a.proc_data.name, b.proc_data.name),
        .cpu => std.math.order(a.cpu_delta, b.cpu_delta),
        .mem => std.math.order(a.proc_data.mem_rss, b.proc_data.mem_rss),
        .disk => std.math.order(a.disk_delta, b.disk_delta),
        .gpu => std.math.order(a.gpu_delta, b.gpu_delta),
        .none => .eq,
    };
    return switch (ctx.direction) {
        .ascending => order == .lt,
        .descending => order == .gt,
    };
}

// ---------------------------------------------------------------------------
// Search helpers
// ---------------------------------------------------------------------------

pub fn caseInsensitiveContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Text truncation
// ---------------------------------------------------------------------------

fn middleTruncatePathToFit(path: []const u8, max_px: f32, size: f32, alloc: std.mem.Allocator) []const u8 {
    if (path.len == 0) return path;
    const m = font.measure(path, size);
    if (m.w <= max_px) return path;

    const avg_char_w = m.w / @as(f32, @floatFromInt(path.len));
    if (avg_char_w <= 0) return path;
    var max_chars: usize = @intFromFloat(@max(max_px / avg_char_w, 6));

    var result = platform.middleTruncatePath(path, max_chars, alloc);
    var iterations: usize = 0;
    while (iterations < 10) : (iterations += 1) {
        const measured = font.measure(result, size);
        if (measured.w <= max_px) break;
        if (max_chars <= 6) break;
        max_chars -= 1;
        result = platform.middleTruncatePath(path, max_chars, alloc);
    }
    return result;
}

fn truncateToFit(text: []const u8, max_px: f32, size: f32, alloc: std.mem.Allocator) []const u8 {
    if (text.len == 0) return text;
    const m = font.measure(text, size);
    if (m.w <= max_px) return text;

    const ellipsis_w = font.measure("..", size).w;
    const budget = max_px - ellipsis_w;
    if (budget <= 0) return "..";

    var w: f32 = 0;
    var end: usize = 0;
    while (end < text.len) {
        const cw = font.measure(text[end .. end + 1], size).w;
        if (w + cw > budget) break;
        w += cw;
        end += 1;
    }
    if (end == 0) return "..";

    const truncated = std.fmt.allocPrint(alloc, "{s}..", .{text[0..end]}) catch return text[0..end];
    return truncated;
}

// ---------------------------------------------------------------------------
// Format helpers
// ---------------------------------------------------------------------------

fn formatCumulativeTime(alloc: std.mem.Allocator, ns: u64) ![]const u8 {
    const total_secs = ns / std.time.ns_per_s;
    if (total_secs >= 3600) {
        return std.fmt.allocPrint(alloc, "{d}h{d}m", .{ total_secs / 3600, (total_secs % 3600) / 60 });
    } else if (total_secs >= 60) {
        return std.fmt.allocPrint(alloc, "{d}m{d}s", .{ total_secs / 60, total_secs % 60 });
    } else {
        return std.fmt.allocPrint(alloc, "{d}s", .{total_secs});
    }
}

fn formatCpuPercent(alloc: std.mem.Allocator, delta_ns: u64, interval_ns: u64) ![]const u8 {
    if (delta_ns == 0 or interval_ns == 0) return "0%";
    const pct = @as(f64, @floatFromInt(delta_ns)) / @as(f64, @floatFromInt(interval_ns)) * 100.0;
    if (pct < 0.05) return "0%";
    if (pct >= 1000.0) {
        return std.fmt.allocPrint(alloc, "{d:.0}%", .{pct});
    }
    if (pct >= 10.0) {
        return std.fmt.allocPrint(alloc, "{d:.0}%", .{pct});
    }
    if (pct >= 1.0) {
        return std.fmt.allocPrint(alloc, "{d:.1}%", .{pct});
    }
    return std.fmt.allocPrint(alloc, "{d:.2}%", .{pct});
}

fn formatGpuPercent(alloc: std.mem.Allocator, delta_ns: u64, interval_ns: u64) ![]const u8 {
    if (delta_ns == 0 or interval_ns == 0) return "0%";
    const pct = @as(f64, @floatFromInt(delta_ns)) / @as(f64, @floatFromInt(interval_ns)) * 100.0;
    if (pct < 0.1) return "0%";
    if (pct >= 100.0) return "100%";
    if (pct >= 10.0) {
        return std.fmt.allocPrint(alloc, "{d:.0}%", .{pct});
    }
    return std.fmt.allocPrint(alloc, "{d:.1}%", .{pct});
}

fn formatDiskRate(alloc: std.mem.Allocator, delta_bytes: u64, interval_ns: u64) ![]const u8 {
    if (delta_bytes == 0 or interval_ns == 0) return "0 B/s";
    const secs = @as(f64, @floatFromInt(interval_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
    const bytes_per_sec = @as(f64, @floatFromInt(delta_bytes)) / secs;
    if (bytes_per_sec >= 1024.0 * 1024.0 * 1024.0) {
        return std.fmt.allocPrint(alloc, "{d:.1}G/s", .{bytes_per_sec / (1024.0 * 1024.0 * 1024.0)});
    } else if (bytes_per_sec >= 1024.0 * 1024.0) {
        return std.fmt.allocPrint(alloc, "{d:.1}M/s", .{bytes_per_sec / (1024.0 * 1024.0)});
    } else if (bytes_per_sec >= 1024.0) {
        return std.fmt.allocPrint(alloc, "{d:.0}K/s", .{bytes_per_sec / 1024.0});
    }
    return "0 B/s";
}

fn formatRss(alloc: std.mem.Allocator, rss: u64) ![]const u8 {
    const mb = rss / (1024 * 1024);
    if (mb > 0) {
        return std.fmt.allocPrint(alloc, "{d}M", .{mb});
    }
    const kb = rss / 1024;
    return std.fmt.allocPrint(alloc, "{d}K", .{kb});
}
