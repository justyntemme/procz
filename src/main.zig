const std = @import("std");
const sokol = @import("sokol");
const clay = @import("zclay");
const platform = @import("platform");
const process = @import("process");
const tree = @import("tree");
const renderer = @import("renderer");
const layout = @import("layout");
const channel = @import("channel");
const producer = @import("producer");
const font = @import("font");
const theme = @import("theme");

const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const print = std.debug.print;

const state = struct {
    var pass_action: sg.PassAction = .{};
    var snapshot_arena: std.heap.ArenaAllocator = undefined;
    var frame_arena: std.heap.ArenaAllocator = undefined;
    var has_snapshot: bool = false;

    // Clay memory
    var clay_memory: []u8 = &.{};

    // Current process data (rebuilt on each snapshot)
    var current_rows: []tree.FlatRow = &.{};
    var proc_map: std.AutoHashMap(process.pid_t, process.Proc) = undefined;
    var tree_result: tree.TreeResult = undefined;
    var proc_count: usize = 0;

    // Producer thread + SPSC queue
    var queue: channel.EventQueue = undefined;
    var thread_handle: ?std.Thread = null;
    var thread_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var mutex: std.Thread.Mutex = .{};
    var condition: std.Thread.Condition = .{};
    var exited_pids: std.AutoHashMap(process.pid_t, void) = undefined;
    var queue_inited: bool = false;

    // Input state
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var mouse_down: bool = false;
    var mouse_clicked: bool = false; // true only on frame button went down

    // Selection state (PID-based, survives snapshot refreshes)
    var selected_pids: std.AutoHashMap(process.pid_t, void) = undefined;
    var anchor_pid: ?process.pid_t = null; // for future shift+click

    // Display-index-to-PID mapping (rebuilt each frame from formatRowTexts)
    var current_display_pids: []process.pid_t = &.{};

    // Hover (display index from previous frame)
    var hovered_index: ?usize = null;

    // Modifier snapshot from last click (for future cmd/shift+click)
    var click_modifiers: u32 = 0;

    // Scroll accumulator (drained each frame by clay)
    var scroll_dx: f32 = 0;
    var scroll_dy: f32 = 0;

    // Deferred scroll-to-row target (set by key nav, applied in frame)
    var pending_scroll_index: ?usize = null;
};

fn clayErrorHandler(err: clay.ErrorData) callconv(.c) void {
    print("clay error: {s}\n", .{err.error_text.chars[0..@intCast(err.error_text.length)]});
}

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    renderer.setup();

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.12, .a = 1.0 },
    };

    // Init arenas
    state.snapshot_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    state.frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    // Init Clay
    const min_mem: u32 = clay.minMemorySize();
    state.clay_memory = std.heap.page_allocator.alloc(u8, min_mem) catch {
        print("procz: failed to allocate clay memory\n", .{});
        return;
    };
    const arena = clay.createArenaWithCapacityAndMemory(state.clay_memory);
    const init_dpi = sapp.dpiScale();
    _ = clay.initialize(arena, .{
        .w = sapp.widthf() / init_dpi,
        .h = sapp.heightf() / init_dpi,
    }, .{ .error_handler_function = clayErrorHandler });
    clay.setMeasureTextFunction(void, {}, renderer.measureText);

    // Init exited_pids set
    state.exited_pids = std.AutoHashMap(process.pid_t, void).init(std.heap.page_allocator);

    // Init selection state
    state.selected_pids = std.AutoHashMap(process.pid_t, void).init(std.heap.page_allocator);

    // Init SPSC queue and spawn producer thread
    state.queue = channel.initQueue(std.heap.page_allocator) catch {
        print("procz: queue init failed, collecting once on UI thread\n", .{});
        collectSnapshotFallback();
        return;
    };
    state.queue_inited = true;

    state.thread_running.store(true, .release);
    state.thread_handle = std.Thread.spawn(.{}, producer.run, .{producer.ThreadArgs{
        .queue = &state.queue,
        .running = &state.thread_running,
        .condition = &state.condition,
        .mutex = &state.mutex,
    }}) catch {
        print("procz: thread spawn failed, collecting once on UI thread\n", .{});
        collectSnapshotFallback();
        return;
    };
}

/// Fallback: collect a single snapshot on the UI thread (used if threading fails).
fn collectSnapshotFallback() void {
    _ = state.snapshot_arena.reset(.retain_capacity);
    const arena = state.snapshot_arena.allocator();

    const map = platform.collectSnapshot(arena) catch |err| {
        print("procz: snapshot failed: {}\n", .{err});
        return;
    };
    state.has_snapshot = true;
    state.proc_map = map;
    state.proc_count = map.count();

    const result = tree.buildTree(&map, arena) catch |err| {
        print("procz: tree build failed: {}\n", .{err});
        return;
    };
    state.tree_result = result;

    const rows = tree.flattenDfs(&result.adj, 0, arena) catch |err| {
        print("procz: tree flatten failed: {}\n", .{err});
        return;
    };
    state.current_rows = rows;
    print("procz: collected {d} processes, {d} tree rows (fallback)\n", .{ state.proc_count, rows.len });
}

/// Drain all pending events from the SPSC queue.
fn drainEvents() void {
    if (!state.queue_inited) return;

    while (state.queue.front()) |event_ptr| {
        var event = event_ptr.*;
        state.queue.pop();

        switch (event) {
            .snapshot => |*batch| {
                // Free old snapshot arena if we had one
                if (state.has_snapshot) {
                    state.snapshot_arena.deinit();
                }

                // Take ownership of the batch's arena
                state.snapshot_arena = batch.arena;
                state.proc_map = batch.map;
                state.proc_count = batch.map.count();
                state.has_snapshot = true;

                // Clear exited_pids — fresh snapshot is authoritative
                state.exited_pids.clearRetainingCapacity();

                // Rebuild tree from new snapshot
                const snap_alloc = state.snapshot_arena.allocator();
                const result = tree.buildTree(&state.proc_map, snap_alloc) catch |err| {
                    print("procz: tree build failed: {}\n", .{err});
                    continue;
                };
                state.tree_result = result;

                const rows = tree.flattenDfs(&result.adj, 0, snap_alloc) catch |err| {
                    print("procz: tree flatten failed: {}\n", .{err});
                    continue;
                };
                state.current_rows = rows;
                print("procz: snapshot {d} procs, {d} rows\n", .{ state.proc_count, rows.len });
            },
            .exit => |pid| {
                state.exited_pids.put(pid, {}) catch {};
            },
        }
        // Don't call event.deinit() for snapshots — we took ownership of the arena
        // Exit events have nothing to free
    }
}

export fn frame() void {
    // Reset frame arena each frame
    _ = state.frame_arena.reset(.retain_capacity);
    const frame_alloc = state.frame_arena.allocator();

    // Drain events from producer thread
    drainEvents();

    // Pre-format RowText slices for the layout
    const row_texts = formatRowTexts(frame_alloc) catch &.{};

    // Set Clay viewport dimensions (logical pixels, not framebuffer pixels)
    const dpi = sapp.dpiScale();
    clay.setLayoutDimensions(.{
        .w = sapp.widthf() / dpi,
        .h = sapp.heightf() / dpi,
    });

    // Set Clay pointer state before updateScrollContainers so clay knows
    // which scroll container the pointer is over
    clay.setPointerState(.{ .x = state.mouse_x, .y = state.mouse_y }, state.mouse_down);

    // Pass accumulated scroll deltas to clay
    const delta_time = @as(f32, @floatCast(sapp.frameDuration()));
    clay.updateScrollContainers(false, .{ .x = state.scroll_dx, .y = state.scroll_dy }, delta_time);
    state.scroll_dx = 0;
    state.scroll_dy = 0;

    // Apply deferred scroll-to-row from arrow key navigation
    if (state.pending_scroll_index) |idx| {
        scrollToRow(idx);
        state.pending_scroll_index = null;
    }

    // Compute summary for right panel
    const summary = computeSummary(frame_alloc);

    // Build is_selected parallel array from selected_pids + current_display_pids
    const display_count = state.current_display_pids.len;
    const is_selected_buf = frame_alloc.alloc(bool, display_count) catch null;
    if (is_selected_buf) |buf| {
        for (state.current_display_pids, 0..) |pid, i| {
            buf[i] = state.selected_pids.contains(pid);
        }
    }
    const is_selected: []const bool = is_selected_buf orelse &.{};

    // Build layout and get render commands
    const commands = layout.buildLayout(row_texts, summary, .{
        .is_selected = is_selected,
        .hovered_index = state.hovered_index,
    });

    // Update hover for next frame (post-layout detection)
    state.hovered_index = null;
    for (0..display_count) |i| {
        if (clay.pointerOver(clay.ElementId.IDI("row", @intCast(i)))) {
            state.hovered_index = i;
            break;
        }
    }

    // Process click
    if (state.mouse_clicked) {
        processClick();
        state.mouse_clicked = false;
    }

    // Render
    sg.beginPass(.{
        .action = state.pass_action,
        .swapchain = sglue.swapchain(),
    });
    renderer.render(commands);
    sg.endPass();
    sg.commit();
}

const TreeEntry = struct {
    pid: process.pid_t,
    proc_data: process.Proc,
    depth: u16,
};

fn formatRowTexts(alloc: std.mem.Allocator) ![]layout.RowText {
    if (!state.has_snapshot or state.current_rows.len == 0) {
        state.current_display_pids = &.{};
        return &.{};
    }

    const rows = state.current_rows;

    // First pass: filter out exited PIDs
    var filtered: std.ArrayListUnmanaged(TreeEntry) = .empty;
    try filtered.ensureTotalCapacity(alloc, rows.len);

    for (rows) |row| {
        const pid = state.tree_result.pids[row.index];
        if (state.exited_pids.contains(pid)) continue;
        const p = state.proc_map.get(pid) orelse continue;
        filtered.appendAssumeCapacity(.{ .pid = pid, .proc_data = p, .depth = row.depth });
    }

    const items = filtered.items;

    // Build parallel PID mapping for selection tracking
    var pid_list: std.ArrayListUnmanaged(process.pid_t) = .empty;
    try pid_list.ensureTotalCapacity(alloc, items.len);
    for (items) |entry| {
        pid_list.appendAssumeCapacity(entry.pid);
    }
    state.current_display_pids = try pid_list.toOwnedSlice(alloc);

    // Compute dynamic path pixel budget from the left panel width
    const dpi = sapp.dpiScale();
    const left_w = sapp.widthf() / dpi * 0.60;
    const path_budget = left_w - theme.col_pid - theme.col_name - theme.col_cpu - theme.col_mem - 24;

    // Second pass: build RowTexts with tree prefixes
    var texts: std.ArrayListUnmanaged(layout.RowText) = .empty;
    try texts.ensureTotalCapacity(alloc, items.len);

    var is_last: [64]bool = [_]bool{false} ** 64;

    for (items, 0..) |entry, i| {
        const last = isLastSibling(items, i);
        is_last[entry.depth] = last;

        const prefix = buildTreePrefix(entry.depth, &is_last, last, alloc);
        const cpu_total = entry.proc_data.total_user + entry.proc_data.total_system;

        texts.appendAssumeCapacity(.{
            .pid_str = truncateToFit(
                std.fmt.allocPrint(alloc, "{d}", .{entry.pid}) catch "?",
                theme.col_pid,
                theme.font_size,
                alloc,
            ),
            .name_prefix = prefix,
            .name = entry.proc_data.name,
            .cpu_str = truncateToFit(
                formatCpuTime(alloc, cpu_total) catch "?",
                theme.col_cpu,
                theme.font_size,
                alloc,
            ),
            .mem_str = truncateToFit(
                formatRss(alloc, entry.proc_data.mem_rss) catch "?",
                theme.col_mem,
                theme.font_size,
                alloc,
            ),
            .path_str = if (path_budget > 30)
                middleTruncatePathToFit(entry.proc_data.path, path_budget, theme.font_size, alloc)
            else
                "",
            .full_path = entry.proc_data.path,
            .depth = entry.depth,
        });
    }

    return texts.toOwnedSlice(alloc);
}

fn isLastSibling(entries: []const TreeEntry, i: usize) bool {
    const d = entries[i].depth;
    var j = i + 1;
    while (j < entries.len) : (j += 1) {
        if (entries[j].depth < d) return true; // hit parent boundary
        if (entries[j].depth == d) return false; // found sibling
    }
    return true; // end of list
}

fn buildTreePrefix(depth: u16, is_last_arr: *const [64]bool, self_is_last: bool, alloc: std.mem.Allocator) []const u8 {
    if (depth == 0) return "";

    const d: usize = @intCast(depth);
    const total_len = d * 4;
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    parts.ensureTotalCapacity(alloc, total_len) catch return "";

    // Ancestor segments: levels 1..d-1
    var level: usize = 1;
    while (level < d) : (level += 1) {
        if (is_last_arr[level]) {
            parts.appendSliceAssumeCapacity("    ");
        } else {
            parts.appendSliceAssumeCapacity("|   ");
        }
    }

    // Connector segment at depth d
    if (self_is_last) {
        parts.appendSliceAssumeCapacity("`-- ");
    } else {
        parts.appendSliceAssumeCapacity("|-- ");
    }

    return parts.items;
}

/// Middle-truncate a path to fit within a pixel budget, using font.measure() for accuracy.
fn middleTruncatePathToFit(path: []const u8, max_px: f32, size: f32, alloc: std.mem.Allocator) []const u8 {
    if (path.len == 0) return path;
    const m = font.measure(path, size);
    if (m.w <= max_px) return path;

    // Estimate max_chars from pixel budget using average char width
    const avg_char_w = m.w / @as(f32, @floatFromInt(path.len));
    if (avg_char_w <= 0) return path;
    var max_chars: usize = @intFromFloat(@max(max_px / avg_char_w, 6));

    // Iteratively shrink until it fits (up to 10 iterations)
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

/// Truncate text so its rendered width fits within max_px pixels at the given font size.
/// If truncated, appends ".." to indicate overflow. Returns the original slice if it fits.
fn truncateToFit(text: []const u8, max_px: f32, size: f32, alloc: std.mem.Allocator) []const u8 {
    if (text.len == 0) return text;
    const m = font.measure(text, size);
    if (m.w <= max_px) return text;

    // Find the last character that fits, reserving space for ".."
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

fn formatCpuTime(alloc: std.mem.Allocator, ns: u64) ![]const u8 {
    const total_secs = ns / std.time.ns_per_s;
    if (total_secs >= 3600) {
        return std.fmt.allocPrint(alloc, "{d}h{d}m", .{ total_secs / 3600, (total_secs % 3600) / 60 });
    } else if (total_secs >= 60) {
        return std.fmt.allocPrint(alloc, "{d}m{d}s", .{ total_secs / 60, total_secs % 60 });
    } else {
        return std.fmt.allocPrint(alloc, "{d}s", .{total_secs});
    }
}

fn formatRss(alloc: std.mem.Allocator, rss: u64) ![]const u8 {
    const mb = rss / (1024 * 1024);
    if (mb > 0) {
        return std.fmt.allocPrint(alloc, "{d}M", .{mb});
    }
    const kb = rss / 1024;
    return std.fmt.allocPrint(alloc, "{d}K", .{kb});
}

fn computeSummary(alloc: std.mem.Allocator) layout.SystemSummary {
    var summary = layout.SystemSummary{};
    if (!state.has_snapshot) return summary;

    summary.proc_count = state.proc_count;

    var iter = state.proc_map.iterator();
    while (iter.next()) |entry| {
        const p = entry.value_ptr.*;

        summary.total_rss += p.mem_rss;

        const si: usize = @intFromEnum(p.state);
        if (si < 5) summary.state_counts[si] += 1;

        const cpu_total = p.total_user + p.total_system;
        insertTop5(&summary.top_cpu, &summary.top_cpu_count, p.name, cpu_total);
        insertTop5(&summary.top_mem, &summary.top_mem_count, p.name, p.mem_rss);
    }

    // Pre-format value strings for the layout
    for (summary.top_cpu[0..@intCast(summary.top_cpu_count)]) |*e| {
        e.value_str = formatCpuTime(alloc, e.value) catch "?";
    }
    for (summary.top_mem[0..@intCast(summary.top_mem_count)]) |*e| {
        e.value_str = formatRss(alloc, e.value) catch "?";
    }
    summary.total_rss_str = formatRss(alloc, summary.total_rss) catch "?";

    // Pre-format strings that layout.zig will pass to clay.text()
    // These must be arena-allocated so they survive until render commands are consumed.
    summary.header_stats_str = std.fmt.allocPrint(alloc, "{d} procs | {s} RSS", .{
        summary.proc_count,
        summary.total_rss_str,
    }) catch "?";

    summary.mem_title_str = std.fmt.allocPrint(alloc, "Memory ({s} total)", .{
        summary.total_rss_str,
    }) catch "Memory";

    for (0..5) |i| {
        const count = summary.state_counts[i];
        if (count > 0) {
            summary.state_value_strs[i] = std.fmt.allocPrint(alloc, "{d}", .{count}) catch "?";
        }
    }

    return summary;
}

fn insertTop5(arr: *[5]layout.TopEntry, count: *u8, name: []const u8, value: u64) void {
    if (value == 0) return;

    const c: usize = @intCast(count.*);
    if (c < 5) {
        arr[c] = .{ .name = name, .value = value };
        count.* += 1;
        // Bubble into sorted position (descending)
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

export fn cleanup() void {
    // Signal producer thread to stop
    if (state.thread_handle) |handle| {
        state.thread_running.store(false, .release);
        // Wake condition in case producer is in timedWait (polling-only fallback)
        state.condition.signal();
        handle.join();
        state.thread_handle = null;
    }

    // Drain remaining events and free them
    if (state.queue_inited) {
        while (state.queue.front()) |event_ptr| {
            var event = event_ptr.*;
            state.queue.pop();
            event.deinit();
        }
        state.queue.deinit();
    }

    state.exited_pids.deinit();
    state.selected_pids.deinit();

    renderer.shutdown();
    if (state.clay_memory.len > 0) {
        std.heap.page_allocator.free(state.clay_memory);
    }
    state.frame_arena.deinit();
    if (state.has_snapshot) {
        state.snapshot_arena.deinit();
    }
    sg.shutdown();
}

export fn onEvent(ev: [*c]const sapp.Event) void {
    const e = ev.*;
    const dpi = sapp.dpiScale();
    switch (e.type) {
        .MOUSE_MOVE => {
            state.mouse_x = e.mouse_x / dpi;
            state.mouse_y = e.mouse_y / dpi;
        },
        .MOUSE_DOWN => {
            if (e.mouse_button == .LEFT) {
                state.mouse_x = e.mouse_x / dpi;
                state.mouse_y = e.mouse_y / dpi;
                state.mouse_down = true;
                state.mouse_clicked = true;
                state.click_modifiers = e.modifiers;
            }
        },
        .MOUSE_UP => {
            if (e.mouse_button == .LEFT) state.mouse_down = false;
        },
        .MOUSE_SCROLL => {
            state.scroll_dx += e.scroll_x;
            state.scroll_dy += e.scroll_y;
        },
        .KEY_DOWN => {
            switch (e.key_code) {
                .DOWN => processKeyNav(.down),
                .UP => processKeyNav(.up),
                else => {},
            }
        },
        else => {},
    }
}

const NavDirection = enum { up, down };

fn processKeyNav(dir: NavDirection) void {
    const pids = state.current_display_pids;
    if (pids.len == 0) return;

    // Find lowest and highest selected display indices
    var lo: ?usize = null;
    var hi: ?usize = null;
    for (pids, 0..) |pid, i| {
        if (state.selected_pids.contains(pid)) {
            if (lo == null) lo = i;
            hi = i;
        }
    }

    const target: usize = switch (dir) {
        .down => if (hi) |h| @min(h + 1, pids.len - 1) else 0,
        .up => if (lo) |l| if (l > 0) l - 1 else 0 else pids.len - 1,
    };

    // Single select the target
    state.selected_pids.clearRetainingCapacity();
    state.selected_pids.put(pids[target], {}) catch {};
    state.anchor_pid = pids[target];

    // Defer scroll into view to next frame (needs layout data)
    state.pending_scroll_index = target;
}

fn scrollToRow(display_index: usize) void {
    const scroll_data = clay.getScrollContainerData(clay.ElementId.ID("scroll"));
    if (!scroll_data.found) return;

    const row_y = @as(f32, @floatFromInt(display_index)) * theme.row_height;
    const row_bottom = row_y + theme.row_height;
    const visible_top = -scroll_data.scroll_position.y; // scroll_position.y is negative
    const visible_bottom = visible_top + scroll_data.scroll_container_dimensions.h;

    if (row_y < visible_top) {
        scroll_data.scroll_position.y = -row_y;
    } else if (row_bottom > visible_bottom) {
        scroll_data.scroll_position.y = -(row_bottom - scroll_data.scroll_container_dimensions.h);
    }
}

fn processClick() void {
    const pids = state.current_display_pids;

    // Find which row was clicked (and its display index)
    var clicked_pid: ?process.pid_t = null;
    var clicked_index: ?usize = null;
    for (pids, 0..) |pid, i| {
        if (clay.pointerOver(clay.ElementId.IDI("row", @intCast(i)))) {
            clicked_pid = pid;
            clicked_index = i;
            break;
        }
    }

    if (clicked_pid) |pid| {
        const cmd = (state.click_modifiers & sapp.modifier_super) != 0;
        const shift = (state.click_modifiers & sapp.modifier_shift) != 0;

        if (cmd) {
            // Cmd+click: toggle the clicked PID in selection
            if (state.selected_pids.contains(pid)) {
                _ = state.selected_pids.remove(pid);
            } else {
                state.selected_pids.put(pid, {}) catch {};
            }
            state.anchor_pid = pid;
        } else if (shift) {
            // Shift+click: range select from anchor to clicked row
            if (state.anchor_pid) |anchor| {
                // Find display index of anchor
                var anchor_index: ?usize = null;
                for (pids, 0..) |p, i| {
                    if (p == anchor) {
                        anchor_index = i;
                        break;
                    }
                }

                if (anchor_index) |ai| {
                    const ci = clicked_index.?;
                    const lo = @min(ai, ci);
                    const hi = @max(ai, ci);
                    state.selected_pids.clearRetainingCapacity();
                    for (pids[lo .. hi + 1]) |range_pid| {
                        state.selected_pids.put(range_pid, {}) catch {};
                    }
                    // Keep anchor_pid unchanged for further shift+clicks
                } else {
                    // Anchor not visible, fall back to single select
                    state.selected_pids.clearRetainingCapacity();
                    state.selected_pids.put(pid, {}) catch {};
                    state.anchor_pid = pid;
                }
            } else {
                // No anchor yet, treat as single select
                state.selected_pids.clearRetainingCapacity();
                state.selected_pids.put(pid, {}) catch {};
                state.anchor_pid = pid;
            }
        } else {
            // Plain click: clear selection, select one
            state.selected_pids.clearRetainingCapacity();
            state.selected_pids.put(pid, {}) catch {};
            state.anchor_pid = pid;
        }
    } else {
        // Clicked outside rows: deselect all
        state.selected_pids.clearRetainingCapacity();
        state.anchor_pid = null;
    }
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = onEvent,
        .width = 1280,
        .height = 800,
        .high_dpi = true,
        .window_title = "procz",
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
