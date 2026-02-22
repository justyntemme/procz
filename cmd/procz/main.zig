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
const graph = @import("graph");

const builtin = @import("builtin");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const print = std.debug.print;

const native_menu = if (builtin.os.tag == .macos) @cImport({
    @cInclude("macos_menu.h");
}) else struct {
    pub fn setup_native_menu() void {}
    pub fn check_settings_requested() c_int {
        return 0;
    }
};

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

    // Total physical memory (fetched once at init)
    var total_memory: u64 = 0;

    // Sort state
    var sort_column: layout.SortColumn = .none;
    var sort_direction: layout.SortDirection = .descending;

    // Column widths (mutable, initialized from theme defaults)
    var col_widths: [6]f32 = .{ theme.col_pid, theme.col_name, theme.col_cpu, theme.col_mem, theme.col_disk, theme.col_gpu };

    // Column resize drag state
    var dragging_col: ?u8 = null; // index into col_widths being dragged
    var drag_start_x: f32 = 0;
    var drag_start_width: f32 = 0;

    // Settings popup state
    var settings_open: bool = false;

    // Double-click detection (spawns procz-detail)
    var last_click_pid: ?process.pid_t = null;
    var last_click_time_ns: i128 = 0;
    const double_click_threshold_ns: i128 = 400 * std.time.ns_per_ms;

    // Tab state
    var active_tab: layout.ActiveTab = .processes;

    // Search state
    var search_buf: [128]u8 = [_]u8{0} ** 128;
    var search_len: usize = 0;
    var search_focused: bool = false;
    var cursor_blink_timer: f64 = 0;
    var consume_next_char: bool = false; // suppress CHAR after slash-to-focus

    // Snapshot interval tracking for GPU % computation
    var last_snapshot_time_ns: i128 = 0;
    var snapshot_interval_ns: u64 = 2 * std.time.ns_per_s; // default 2s

    // Previous snapshot values for graph delta computation
    const PrevEntry = struct { pid: i32 = 0, cpu: u64 = 0, disk: u64 = 0, gpu: u64 = 0 };
    const MAX_PREV = 4096;
    var prev_values: [MAX_PREV]PrevEntry = [_]PrevEntry{.{}} ** MAX_PREV;
    var prev_count: usize = 0;

    // Per-core CPU utilization
    var prev_core_ticks: [platform.MAX_CORES]platform.CoreTicks = [_]platform.CoreTicks{.{}} ** platform.MAX_CORES;
    var curr_core_ticks: [platform.MAX_CORES]platform.CoreTicks = [_]platform.CoreTicks{.{}} ** platform.MAX_CORES;
    var core_count: usize = 0;
    var core_utils: [platform.MAX_CORES]f32 = [_]f32{0} ** platform.MAX_CORES;
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

    // Fetch total physical memory once
    state.total_memory = platform.getTotalMemory();

    // Initialize per-core CPU baseline
    state.core_count = platform.getPerCoreCpuTicks(&state.curr_core_ticks);

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

    // Setup native macOS menu bar (replaces sokol's default menu)
    native_menu.setup_native_menu();
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
                // Track snapshot interval for GPU % computation
                const now_ns = std.time.nanoTimestamp();
                if (state.last_snapshot_time_ns > 0) {
                    const delta = now_ns - state.last_snapshot_time_ns;
                    if (delta > 0) state.snapshot_interval_ns = @intCast(delta);
                }
                state.last_snapshot_time_ns = now_ns;

                // Save previous proc values for graph delta computation
                const had_previous = state.has_snapshot;
                if (had_previous) {
                    savePreviousValues();
                    state.snapshot_arena.deinit();
                }

                // Take ownership of the batch's arena
                state.snapshot_arena = batch.arena;
                state.proc_map = batch.map;
                state.proc_count = batch.map.count();
                state.has_snapshot = true;

                // Clear exited_pids — fresh snapshot is authoritative
                state.exited_pids.clearRetainingCapacity();

                // Push graph data (needs deltas from prev values, skip first snapshot)
                if (had_previous) pushGraphData();

                // Update per-core CPU utilization
                updateCoreUtilization();

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

fn savePreviousValues() void {
    var count: usize = 0;
    var iter = state.proc_map.iterator();
    while (iter.next()) |entry| {
        if (count >= state.MAX_PREV) break;
        const p = entry.value_ptr.*;
        state.prev_values[count] = .{
            .pid = p.pid,
            .cpu = p.total_user + p.total_system,
            .disk = p.diskio_bytes_read + p.diskio_bytes_written,
            .gpu = p.gpu_time_ns,
        };
        count += 1;
    }
    state.prev_count = count;
}

const GraphTopInfo = struct { name: []const u8 = "", value: f32 = 0 };

fn pushGraphData() void {
    var top_cpu = [_]GraphTopInfo{.{}} ** 5;
    var top_mem = [_]GraphTopInfo{.{}} ** 5;
    var top_disk = [_]GraphTopInfo{.{}} ** 5;
    var cpu_count: u8 = 0;
    var mem_count: u8 = 0;
    var disk_count: u8 = 0;

    var iter = state.proc_map.iterator();
    while (iter.next()) |entry| {
        const p = entry.value_ptr.*;
        const cpu_total = p.total_user + p.total_system;
        var cpu_delta: u64 = 0; // No previous data = unknown rate, treat as 0
        const disk_total = p.diskio_bytes_read + p.diskio_bytes_written;
        var disk_delta: u64 = 0;

        for (state.prev_values[0..state.prev_count]) |prev| {
            if (prev.pid == p.pid) {
                cpu_delta = cpu_total -| prev.cpu;
                disk_delta = disk_total -| prev.disk;
                break;
            }
        }

        // DEBUG: print raw values for "yes" processes
        if (std.mem.eql(u8, p.name, "yes")) {
            std.debug.print("DBG yes pid={d} cpu_total={d} delta={d} interval={d} pct={d:.1}%\n", .{
                p.pid, cpu_total, cpu_delta, state.snapshot_interval_ns,
                if (state.snapshot_interval_ns > 0) @as(f64, @floatFromInt(cpu_delta)) / @as(f64, @floatFromInt(state.snapshot_interval_ns)) * 100.0 else 0.0,
            });
        }

        insertTopInfo(&top_cpu, &cpu_count, p.name, @floatFromInt(cpu_delta));
        insertTopInfo(&top_mem, &mem_count, p.name, @floatFromInt(p.mem_rss));
        insertTopInfo(&top_disk, &disk_count, p.name, @floatFromInt(disk_delta));
    }

    // Push to graph histories
    var cpu_vals: [5]f32 = undefined;
    var cpu_names: [5][]const u8 = undefined;
    for (0..cpu_count) |i| {
        cpu_vals[i] = top_cpu[i].value;
        cpu_names[i] = top_cpu[i].name;
    }
    graph.cpu_history.push(cpu_vals[0..cpu_count], cpu_names[0..cpu_count]);

    var mem_vals: [5]f32 = undefined;
    var mem_names: [5][]const u8 = undefined;
    for (0..mem_count) |i| {
        mem_vals[i] = top_mem[i].value;
        mem_names[i] = top_mem[i].name;
    }
    graph.mem_history.push(mem_vals[0..mem_count], mem_names[0..mem_count]);

    var disk_vals: [5]f32 = undefined;
    var disk_names: [5][]const u8 = undefined;
    for (0..disk_count) |i| {
        disk_vals[i] = top_disk[i].value;
        disk_names[i] = top_disk[i].name;
    }
    // Only push disk data if there was activity; skip to preserve last graph state
    // (avoids flickering to blank when no process has disk I/O between snapshots)
    if (disk_count > 0) {
        graph.disk_history.push(disk_vals[0..disk_count], disk_names[0..disk_count]);
    }
}

fn insertTopInfo(arr: *[5]GraphTopInfo, count: *u8, name: []const u8, value: f32) void {
    if (value <= 0) return;
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

fn updateCoreUtilization() void {
    // Save previous ticks
    state.prev_core_ticks = state.curr_core_ticks;

    // Get current ticks
    state.core_count = platform.getPerCoreCpuTicks(&state.curr_core_ticks);

    // Compute utilization per core
    for (0..state.core_count) |i| {
        const prev = state.prev_core_ticks[i];
        const curr = state.curr_core_ticks[i];

        const user_d = curr.user -| prev.user;
        const sys_d = curr.system -| prev.system;
        const idle_d = curr.idle -| prev.idle;
        const nice_d = curr.nice -| prev.nice;

        const total = user_d + sys_d + idle_d + nice_d;
        if (total > 0) {
            const active = user_d + sys_d + nice_d;
            state.core_utils[i] = @as(f32, @floatFromInt(active)) / @as(f32, @floatFromInt(total));
        } else {
            state.core_utils[i] = 0;
        }
    }

    // Push to sparkline ring buffers
    graph.pushCoreData(state.core_utils[0..state.core_count]);
}

export fn frame() void {
    // Reset frame arena each frame
    _ = state.frame_arena.reset(.retain_capacity);
    const frame_alloc = state.frame_arena.allocator();

    // Check native menu actions
    if (native_menu.check_settings_requested() != 0) {
        state.settings_open = true;
    }

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

    // Update clear color to match theme background
    state.pass_action.colors[0].clear_value = .{
        .r = @as(f32, theme.bg[0]) / 255.0,
        .g = @as(f32, theme.bg[1]) / 255.0,
        .b = @as(f32, theme.bg[2]) / 255.0,
        .a = 1.0,
    };

    // Update cursor blink timer
    state.cursor_blink_timer += @as(f64, @floatCast(sapp.frameDuration()));
    if (state.cursor_blink_timer >= 1.0) state.cursor_blink_timer -= 1.0;

    // Build layout and get render commands
    const commands = layout.buildLayout(row_texts, summary, .{
        .is_selected = is_selected,
        .hovered_index = state.hovered_index,
        .sort_column = state.sort_column,
        .sort_direction = state.sort_direction,
        .col_widths = state.col_widths,
        .search_text = state.search_buf[0..state.search_len],
        .search_focused = state.search_focused,
        .cursor_visible = state.cursor_blink_timer < 0.5,
        .active_tab = state.active_tab,
    }, .{
        .settings_open = state.settings_open,
    });

    // Extract graph area bounding boxes from render commands
    {
        const cpu_id = clay.ElementId.ID("ga-cpu").id;
        const mem_id = clay.ElementId.ID("ga-mem").id;
        const disk_id = clay.ElementId.ID("ga-disk").id;
        const spark_id = clay.ElementId.ID("spark-area").id;
        graph.cpu_bounds = null;
        graph.mem_bounds = null;
        graph.disk_bounds = null;
        graph.spark_bounds = null;
        for (commands) |cmd| {
            if (cmd.command_type == .rectangle) {
                const bb = cmd.bounding_box;
                if (cmd.id == cpu_id) {
                    graph.cpu_bounds = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
                } else if (cmd.id == mem_id) {
                    graph.mem_bounds = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
                } else if (cmd.id == disk_id) {
                    graph.disk_bounds = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
                } else if (cmd.id == spark_id) {
                    graph.spark_bounds = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
                }
            }
        }
    }

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
    cpu_delta: u64 = 0,
    disk_delta: u64 = 0,
    gpu_delta: u64 = 0,
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

        // Compute deltas from previous snapshot for this process
        const cpu_total = p.total_user + p.total_system;
        const disk_total = p.diskio_bytes_read + p.diskio_bytes_written;
        var cd: u64 = 0;
        var dd: u64 = 0;
        var gd: u64 = 0;
        for (state.prev_values[0..state.prev_count]) |prev| {
            if (prev.pid == pid) {
                cd = cpu_total -| prev.cpu;
                dd = disk_total -| prev.disk;
                gd = p.gpu_time_ns -| prev.gpu;
                break;
            }
        }
        filtered.appendAssumeCapacity(.{ .pid = pid, .proc_data = p, .depth = row.depth, .cpu_delta = cd, .disk_delta = dd, .gpu_delta = gd });
    }

    // Search filter
    const query = state.search_buf[0..state.search_len];
    if (query.len > 0) {
        var w: usize = 0;
        for (filtered.items) |entry| {
            if (caseInsensitiveContains(entry.proc_data.name, query) or
                caseInsensitiveContains(entry.proc_data.path, query))
            {
                filtered.items[w] = entry;
                w += 1;
            }
        }
        filtered.shrinkRetainingCapacity(w);
    }

    // Sort if a sort column is active (replaces tree order with flat sort)
    const is_sorted = state.sort_column != .none;
    if (is_sorted) {
        const sort_ctx = SortContext{ .column = state.sort_column, .direction = state.sort_direction };
        std.mem.sortUnstable(TreeEntry, filtered.items, sort_ctx, sortCompare);
    }
    const items = filtered.items;

    // Build parallel PID mapping for selection tracking
    var pid_list: std.ArrayListUnmanaged(process.pid_t) = .empty;
    try pid_list.ensureTotalCapacity(alloc, items.len);
    for (items) |entry| {
        pid_list.appendAssumeCapacity(entry.pid);
    }
    state.current_display_pids = try pid_list.toOwnedSlice(alloc);

    // Compute dynamic path pixel budget from the full window width
    const dpi = sapp.dpiScale();
    const table_w = sapp.widthf() / dpi;
    const path_budget = table_w - state.col_widths[0] - state.col_widths[1] - state.col_widths[2] - state.col_widths[3] - state.col_widths[4] - state.col_widths[5] - 24;

    // System-relative intensity normalization (like Windows Task Manager):
    // CPU: fraction of total CPU capacity (all cores × snapshot interval)
    // MEM: fraction of total physical RAM
    // DISK: fraction of reference throughput (~100MB/s)
    // GPU: fraction of GPU time capacity
    const total_mem_f: f64 = if (state.total_memory > 0) @floatFromInt(state.total_memory) else 1.0;
    const interval_f: f64 = @floatFromInt(@max(state.snapshot_interval_ns, 1));
    const cores_f: f64 = @floatFromInt(@max(state.core_count, 1));
    const cpu_capacity: f64 = interval_f * cores_f;
    const disk_ref: f64 = 200.0 * 1024.0 * 1024.0; // ~100MB/s at 2s intervals

    // Second pass: build RowTexts (tree prefixes only when not sorted)
    var texts: std.ArrayListUnmanaged(layout.RowText) = .empty;
    try texts.ensureTotalCapacity(alloc, items.len);

    var is_last: [64]bool = [_]bool{false} ** 64;

    for (items, 0..) |entry, i| {
        var prefix: []const u8 = "";
        if (!is_sorted) {
            const last = isLastSibling(items, i);
            is_last[entry.depth] = last;
            prefix = buildTreePrefix(entry.depth, &is_last, last, alloc);
        }
        const cpu_delta = entry.cpu_delta;
        const disk_delta = entry.disk_delta;
        const gpu_delta = entry.gpu_delta;

        // System-relative intensity (like Windows Task Manager)
        const cpu_intensity: f32 = @floatCast(@min(@as(f64, @floatFromInt(cpu_delta)) / cpu_capacity, 1.0));
        const mem_intensity: f32 = @floatCast(@min(@as(f64, @floatFromInt(entry.proc_data.mem_rss)) / total_mem_f, 1.0));
        const disk_intensity: f32 = @floatCast(@min(@as(f64, @floatFromInt(disk_delta)) / disk_ref, 1.0));
        const gpu_intensity: f32 = @floatCast(@min(@as(f64, @floatFromInt(gpu_delta)) / interval_f, 1.0));

        texts.appendAssumeCapacity(.{
            .pid_str = truncateToFit(
                std.fmt.allocPrint(alloc, "{d}", .{entry.pid}) catch "?",
                state.col_widths[0],
                theme.font_size,
                alloc,
            ),
            .name_prefix = prefix,
            .name = entry.proc_data.name,
            .cpu_str = truncateToFit(
                formatCpuPercent(alloc, cpu_delta, state.snapshot_interval_ns) catch "0%",
                state.col_widths[2],
                theme.font_size,
                alloc,
            ),
            .mem_str = truncateToFit(
                formatRss(alloc, entry.proc_data.mem_rss) catch "?",
                state.col_widths[3],
                theme.font_size,
                alloc,
            ),
            .disk_str = truncateToFit(
                formatDiskRate(alloc, disk_delta, state.snapshot_interval_ns) catch "0 B/s",
                state.col_widths[4],
                theme.font_size,
                alloc,
            ),
            .gpu_str = truncateToFit(
                formatGpuPercent(alloc, gpu_delta, state.snapshot_interval_ns) catch "0%",
                state.col_widths[5],
                theme.font_size,
                alloc,
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
            .raw_cpu = cpu_delta,
            .raw_mem = entry.proc_data.mem_rss,
            .raw_disk = disk_delta,
            .raw_gpu = gpu_delta,
            .pid = entry.pid,
        });
    }

    return texts.toOwnedSlice(alloc);
}

const SortContext = struct {
    column: layout.SortColumn,
    direction: layout.SortDirection,
};

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

fn caseInsensitiveContains(haystack: []const u8, needle: []const u8) bool {
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
    // Each ancestor: "│ " (3+1=4 bytes) or "  " (2 bytes)
    // Connector: "├─" or "└─" (3+3=6 bytes) + trailing space (1 byte)
    const max_len = (d - 1) * 4 + 7;
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    parts.ensureTotalCapacity(alloc, max_len) catch return "";

    // Ancestor segments: levels 1..d-1
    // Each ancestor gets "│ " (continuing) or "  " (past-last)
    var level: usize = 1;
    while (level < d) : (level += 1) {
        if (is_last_arr[level]) {
            parts.appendSliceAssumeCapacity("  "); // ancestor was last child, no line
        } else {
            parts.appendSliceAssumeCapacity("\xe2\x94\x82 "); // │ + space
        }
    }

    // Connector segment at this depth
    if (self_is_last) {
        parts.appendSliceAssumeCapacity("\xe2\x94\x94\xe2\x94\x80"); // └─
    } else {
        parts.appendSliceAssumeCapacity("\xe2\x94\x9c\xe2\x94\x80"); // ├─
    }

    // Trailing space before name
    parts.appendAssumeCapacity(' ');

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
    // Per-core percentage (like Activity Monitor): 100% = one core fully utilized.
    // A multi-threaded process can exceed 100% (e.g. 400% = 4 cores maxed).
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

fn computeSummary(alloc: std.mem.Allocator) layout.SystemSummary {
    var summary = layout.SystemSummary{};
    if (!state.has_snapshot) return summary;

    summary.proc_count = state.proc_count;

    var iter = state.proc_map.iterator();
    while (iter.next()) |entry| {
        const p = entry.value_ptr.*;

        summary.total_rss += p.mem_rss;

        const cpu_total = p.total_user + p.total_system;
        const disk_total = p.diskio_bytes_read + p.diskio_bytes_written;
        insertTop5(&summary.top_cpu, &summary.top_cpu_count, p.name, cpu_total);
        insertTop5(&summary.top_mem, &summary.top_mem_count, p.name, p.mem_rss);
        insertTop5(&summary.top_disk, &summary.top_disk_count, p.name, disk_total);
    }

    // Pre-format value strings for the layout (graph legends use cumulative time)
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

    // Pre-format strings that layout.zig will pass to clay.text()
    // These must be arena-allocated so they survive until render commands are consumed.
    if (state.search_len > 0) {
        summary.header_stats_str = std.fmt.allocPrint(alloc, "{d}/{d} procs | {s} RSS", .{
            state.current_display_pids.len,
            summary.proc_count,
            summary.total_rss_str,
        }) catch "?";
    } else {
        summary.header_stats_str = std.fmt.allocPrint(alloc, "{d} procs | {s} RSS", .{
            summary.proc_count,
            summary.total_rss_str,
        }) catch "?";
    }

    summary.mem_title_str = std.fmt.allocPrint(alloc, "Memory ({s} total)", .{
        summary.total_rss_str,
    }) catch "Memory";

    // Per-core CPU utilization
    summary.core_count = @intCast(state.core_count);
    for (0..state.core_count) |i| {
        summary.core_utils[i] = state.core_utils[i];
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
            // Handle column resize drag
            if (state.dragging_col) |col_idx| {
                const delta = state.mouse_x - state.drag_start_x;
                const new_width = @max(state.drag_start_width + delta, 30.0); // min 30px
                state.col_widths[col_idx] = new_width;
            }
        },
        .MOUSE_DOWN => {
            if (e.mouse_button == .LEFT) {
                state.mouse_x = e.mouse_x / dpi;
                state.mouse_y = e.mouse_y / dpi;

                // Check if clicking a column resize edge
                if (hitTestColumnEdge(state.mouse_x, state.mouse_y)) |col_idx| {
                    state.dragging_col = col_idx;
                    state.drag_start_x = state.mouse_x;
                    state.drag_start_width = state.col_widths[col_idx];
                    // Don't set mouse_clicked — this is a resize, not a row click
                } else {
                    state.mouse_down = true;
                    state.mouse_clicked = true;
                    state.click_modifiers = e.modifiers;
                }
            }
        },
        .MOUSE_UP => {
            if (e.mouse_button == .LEFT) {
                state.mouse_down = false;
                state.dragging_col = null;
            }
        },
        .MOUSE_SCROLL => {
            state.scroll_dx += e.scroll_x;
            state.scroll_dy += e.scroll_y;
        },
        .CHAR => {
            if (state.consume_next_char) {
                state.consume_next_char = false;
            } else if (state.search_focused) {
                const cp = e.char_code;
                // Only accept printable ASCII (space through tilde)
                if (cp >= 32 and cp < 127 and state.search_len < state.search_buf.len - 1) {
                    state.search_buf[state.search_len] = @intCast(cp);
                    state.search_len += 1;
                    state.cursor_blink_timer = 0;
                }
            }
        },
        .KEY_DOWN => {
            switch (e.key_code) {
                .DOWN => {
                    if (!state.search_focused) processKeyNav(.down);
                },
                .UP => {
                    if (!state.search_focused) processKeyNav(.up);
                },
                .BACKSPACE, .DELETE => {
                    if (state.search_focused and state.search_len > 0) {
                        state.search_len -= 1;
                        state.search_buf[state.search_len] = 0;
                        state.cursor_blink_timer = 0;
                    }
                },
                .ESCAPE => {
                    if (state.search_focused) {
                        state.search_len = 0;
                        @memset(&state.search_buf, 0);
                        state.search_focused = false;
                    } else if (state.settings_open) {
                        state.settings_open = false;
                    }
                },
                .SLASH => {
                    if (!state.search_focused and !state.settings_open) {
                        state.search_focused = true;
                        state.cursor_blink_timer = 0;
                        state.consume_next_char = true; // suppress the '/' CHAR event
                    }
                },
                else => {},
            }
        },
        else => {},
    }
}

/// Test if mouse position is near a column header's right edge (resize handle).
/// Returns the column index (0-4) if within the resize zone, null otherwise.
fn hitTestColumnEdge(mx: f32, my: f32) ?u8 {
    // Column header area: Y from header + tab bar to + col_header_height
    const header_top = theme.header_height + theme.tab_bar_height;
    const header_bottom = header_top + theme.col_header_height;
    if (my < header_top or my > header_bottom) return null;

    const edge_tolerance: f32 = 5.0;
    const left_pad: f32 = 14.0; // matches row padding.left in layout

    var edge_x: f32 = left_pad;
    for (0..6) |i| {
        edge_x += state.col_widths[i];
        if (@abs(mx - edge_x) <= edge_tolerance) {
            return @intCast(i);
        }
    }
    return null;
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

fn processHeaderClick() bool {
    const headers = [_]struct { id: []const u8, col: layout.SortColumn }{
        .{ .id = "ch-name", .col = .name },
        .{ .id = "ch-cpu", .col = .cpu },
        .{ .id = "ch-mem", .col = .mem },
        .{ .id = "ch-disk", .col = .disk },
        .{ .id = "ch-gpu", .col = .gpu },
    };

    for (headers) |h| {
        if (clay.pointerOver(clay.ElementId.ID(h.id))) {
            if (state.sort_column == h.col) {
                // Toggle direction, or clear sort on third click
                if (state.sort_direction == .descending) {
                    state.sort_direction = .ascending;
                } else {
                    // Clear sort (return to tree view)
                    state.sort_column = .none;
                }
            } else {
                state.sort_column = h.col;
                state.sort_direction = .descending;
            }
            return true;
        }
    }
    return false;
}

fn processMenuClick() bool {
    // Handle settings popup interactions (highest priority)
    if (state.settings_open) {
        // Check theme item clicks
        for (0..theme.theme_count) |i| {
            if (clay.pointerOver(clay.ElementId.IDI("thm", @intCast(i)))) {
                theme.applyTheme(i);
                return true;
            }
        }
        // Check close button
        if (clay.pointerOver(clay.ElementId.ID("settings-x"))) {
            state.settings_open = false;
            return true;
        }
        // Click outside the settings panel closes it
        if (!clay.pointerOver(clay.ElementId.ID("settings-pnl"))) {
            state.settings_open = false;
        }
        return true; // consume click when settings is open
    }

    return false;
}

fn processClick() void {
    // Handle menu/settings interactions first
    if (processMenuClick()) return;

    // Tab clicks
    if (clay.pointerOver(clay.ElementId.ID("tab-processes"))) {
        state.active_tab = .processes;
        return;
    }
    if (clay.pointerOver(clay.ElementId.ID("tab-perf"))) {
        state.active_tab = .performance;
        return;
    }

    // Handle search bar click
    if (clay.pointerOver(clay.ElementId.ID("search-bar"))) {
        state.search_focused = true;
        state.cursor_blink_timer = 0;
        return;
    } else if (state.search_focused) {
        state.search_focused = false;
    }

    // Check column header clicks for sorting
    if (processHeaderClick()) return;

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

        // Double-click detection: open details panel
        const now_ns = std.time.nanoTimestamp();
        const is_double = if (state.last_click_pid) |prev_pid|
            prev_pid == pid and (now_ns - state.last_click_time_ns) < state.double_click_threshold_ns
        else
            false;
        state.last_click_pid = pid;
        state.last_click_time_ns = now_ns;

        if (is_double and !cmd and !shift) {
            spawnDetailWindow(pid);
            state.last_click_pid = null;
            return;
        }

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

/// Spawn a procz-detail window for the given PID.
/// Searches: (1) sibling of current exe, (2) zig-out/bin/ relative to CWD.
fn spawnDetailWindow(pid: process.pid_t) void {
    const detail_path = findDetailBinary() orelse {
        print("procz: procz-detail binary not found (run `zig build` first)\n", .{});
        return;
    };

    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return;

    const argv = [_][]const u8{ detail_path, pid_str };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    _ = child.spawn() catch |err| {
        print("procz: failed to spawn procz-detail: {}\n", .{err});
    };
}

fn findDetailBinary() ?[]const u8 {
    // 1. Try sibling of current executable (installed / .app bundle)
    const sibling = blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&path_buf) catch break :blk null;
        const dir = std.fs.path.dirname(exe_path) orelse break :blk null;
        var detail_buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrint(&detail_buf, "{s}/procz-detail", .{dir}) catch break :blk null;
        // Check if it exists
        std.fs.cwd().access(candidate, .{}) catch break :blk null;
        // Copy to stable memory (detail_buf is stack-local)
        break :blk std.heap.page_allocator.dupe(u8, candidate) catch null;
    };
    if (sibling) |s| return s;

    // 2. Try zig-out/bin/ relative to CWD (development: `zig build run`)
    const dev_path = "zig-out/bin/procz-detail";
    std.fs.cwd().access(dev_path, .{}) catch return null;
    return dev_path;
}

pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = onEvent,
        .width = 1024,
        .height = 800,
        .high_dpi = true,
        .window_title = "procz",
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
