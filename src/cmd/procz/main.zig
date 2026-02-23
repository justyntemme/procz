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
const theme = @import("theme");
const graph = @import("graph");
const display = @import("display");

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

    // Materialized display data (rebuilt once per snapshot or view param change)
    var display_arena: std.heap.ArenaAllocator = undefined;
    var materialized_rows: []layout.RowText = &.{};
    var materialized_pids: []process.pid_t = &.{};
    var materialized_summary: layout.SystemSummary = .{};
    var display_dirty: bool = true;

    // Cached view params for dirty detection
    var cached_sort_column: layout.SortColumn = .none;
    var cached_sort_direction: layout.SortDirection = .descending;
    var cached_search_len: usize = 0;
    var cached_search_buf: [128]u8 = [_]u8{0} ** 128;
    var cached_col_widths: [6]f32 = .{ theme.col_pid, theme.col_name, theme.col_cpu, theme.col_mem, theme.col_disk, theme.col_gpu };
    var cached_window_width: f32 = 0;

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

    // Column order (display position → logical column index)
    var col_order: [layout.COL_COUNT]u8 = layout.default_col_order;

    // Column header drag-to-reorder state
    var dragging_header: ?u8 = null; // logical column index being dragged
    var header_drag_start_x: f32 = 0;
    var header_drag_started: bool = false; // true once mouse moved enough to start drag
    const header_drag_threshold: f32 = 5.0; // pixels before drag activates

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

    // Previous snapshot values (HashMap for O(1) lookup)
    var prev_map: std.AutoHashMap(process.pid_t, display.PrevEntry) = undefined;
    var prev_map_inited: bool = false;

    // Pre-computed deltas (rebuilt once per snapshot)
    var delta_map: std.AutoHashMap(process.pid_t, display.DeltaEntry) = undefined;
    var delta_map_inited: bool = false;

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
    state.display_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

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

                // Compute deltas once per snapshot (O(N) with HashMap)
                if (had_previous) computeDeltas();

                // Push graph data using pre-computed deltas
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
                state.display_dirty = true;
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
    if (!state.prev_map_inited) {
        state.prev_map = std.AutoHashMap(process.pid_t, display.PrevEntry).init(std.heap.page_allocator);
        state.prev_map_inited = true;
    }
    state.prev_map.clearRetainingCapacity();
    var iter = state.proc_map.iterator();
    while (iter.next()) |entry| {
        const p = entry.value_ptr.*;
        state.prev_map.put(p.pid, .{
            .cpu = p.total_user + p.total_system,
            .disk = p.diskio_bytes_read + p.diskio_bytes_written,
            .gpu = p.gpu_time_ns,
        }) catch continue;
    }
}

/// Compute deltas once per snapshot. Called from drainEvents after savePreviousValues + map swap.
fn computeDeltas() void {
    if (!state.delta_map_inited) {
        state.delta_map = std.AutoHashMap(process.pid_t, display.DeltaEntry).init(std.heap.page_allocator);
        state.delta_map_inited = true;
    }
    state.delta_map.clearRetainingCapacity();
    var iter = state.proc_map.iterator();
    while (iter.next()) |entry| {
        const p = entry.value_ptr.*;
        const cpu_total = p.total_user + p.total_system;
        const disk_total = p.diskio_bytes_read + p.diskio_bytes_written;
        var cd: u64 = 0;
        var dd: u64 = 0;
        var gd: u64 = 0;
        if (state.prev_map.get(p.pid)) |prev| {
            cd = cpu_total -| prev.cpu;
            dd = disk_total -| prev.disk;
            gd = p.gpu_time_ns -| prev.gpu;
        }
        state.delta_map.put(p.pid, .{ .cpu = cd, .disk = dd, .gpu = gd }) catch continue;
    }
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
        const d = state.delta_map.get(p.pid) orelse display.DeltaEntry{};
        insertTopInfo(&top_cpu, &cpu_count, p.name, @floatFromInt(d.cpu));
        insertTopInfo(&top_mem, &mem_count, p.name, @floatFromInt(p.mem_rss));
        insertTopInfo(&top_disk, &disk_count, p.name, @floatFromInt(d.disk));
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

/// Check if view params changed since last materialization.
fn viewParamsChanged() bool {
    const dpi = sapp.dpiScale();
    const win_w = sapp.widthf() / dpi;

    if (state.cached_sort_column != state.sort_column) return true;
    if (state.cached_sort_direction != state.sort_direction) return true;
    if (state.cached_search_len != state.search_len) return true;
    if (state.cached_search_len > 0 and
        !std.mem.eql(u8, state.cached_search_buf[0..state.cached_search_len], state.search_buf[0..state.search_len]))
        return true;
    if (@abs(win_w - state.cached_window_width) > 0.5) return true;
    for (0..6) |i| {
        if (@abs(state.col_widths[i] - state.cached_col_widths[i]) > 0.5) return true;
    }
    return false;
}

/// Snapshot cached view params after materialization.
fn snapshotViewParams() void {
    const dpi = sapp.dpiScale();
    state.cached_sort_column = state.sort_column;
    state.cached_sort_direction = state.sort_direction;
    state.cached_search_len = state.search_len;
    @memcpy(state.cached_search_buf[0..state.search_len], state.search_buf[0..state.search_len]);
    state.cached_col_widths = state.col_widths;
    state.cached_window_width = sapp.widthf() / dpi;
}

/// Materialize display data if dirty or view params changed.
fn materializeIfNeeded() void {
    if (!state.has_snapshot) return;
    if (!state.display_dirty and !viewParamsChanged()) return;

    _ = state.display_arena.reset(.retain_capacity);
    const alloc = state.display_arena.allocator();

    const dpi = sapp.dpiScale();
    const win_w = sapp.widthf() / dpi;

    // Ensure delta_map is initialized (may be empty before first delta)
    if (!state.delta_map_inited) {
        state.delta_map = std.AutoHashMap(process.pid_t, display.DeltaEntry).init(std.heap.page_allocator);
        state.delta_map_inited = true;
    }

    const result = display.materialize(alloc, .{
        .rows = state.current_rows,
        .tree_pids = state.tree_result.pids,
        .proc_map = &state.proc_map,
        .delta_map = &state.delta_map,
        .exited_pids = &state.exited_pids,
        .sort_column = state.sort_column,
        .sort_direction = state.sort_direction,
        .search_text = state.search_buf[0..state.search_len],
        .col_widths = state.col_widths,
        .window_width = win_w,
        .snapshot_interval_ns = state.snapshot_interval_ns,
        .core_count = state.core_count,
        .total_memory = state.total_memory,
        .proc_count = state.proc_count,
        .core_utils = state.core_utils[0..state.core_count],
    }) catch |err| {
        print("procz: materialize failed: {}\n", .{err});
        return;
    };

    state.materialized_rows = result.rows;
    state.materialized_pids = result.display_pids;
    state.materialized_summary = result.summary;
    state.display_dirty = false;
    snapshotViewParams();
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

    // Materialize display data if needed (once per snapshot or view param change)
    materializeIfNeeded();

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

    // Build is_selected parallel array from selected_pids + materialized_pids
    const display_count = state.materialized_pids.len;
    const is_selected_buf = frame_alloc.alloc(bool, display_count) catch null;
    if (is_selected_buf) |buf| {
        for (state.materialized_pids, 0..) |pid, i| {
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

    // Pre-fetch scroll position for processes tab virtualization.
    // getScrollContainerData returns data from previous frame's layout, which is fine.
    // We can't use getScrollOffset() for this because it must be called inline
    // with the clip config (after clay.UI() opens the element).
    const proc_scroll_data = clay.getScrollContainerData(clay.ElementId.ID("scroll"));
    const proc_scroll_y: f32 = if (proc_scroll_data.found) -proc_scroll_data.scroll_position.y else 0;

    // Build layout and get render commands
    const commands = layout.buildLayout(state.materialized_rows, state.materialized_summary, .{
        .is_selected = is_selected,
        .hovered_index = state.hovered_index,
        .sort_column = state.sort_column,
        .sort_direction = state.sort_direction,
        .col_widths = state.col_widths,
        .col_order = state.col_order,
        .dragging_header = if (state.header_drag_started) state.dragging_header else null,
        .drag_header_x = state.mouse_x,
        .search_text = state.search_buf[0..state.search_len],
        .search_focused = state.search_focused,
        .cursor_visible = state.cursor_blink_timer < 0.5,
        .active_tab = state.active_tab,
        .viewport_height = sapp.heightf() / dpi - theme.header_height - theme.tab_bar_height - 28 - 32,
        .scroll_y = proc_scroll_y,
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

    // Update cursor: resize / grab / default
    if (state.dragging_col != null) {
        sapp.setMouseCursor(.RESIZE_EW);
    } else if (state.header_drag_started) {
        sapp.setMouseCursor(.RESIZE_ALL);
    } else if (hitTestColumnEdge(state.mouse_x, state.mouse_y) != null) {
        sapp.setMouseCursor(.RESIZE_EW);
    } else if (hitTestColumnHeader(state.mouse_x, state.mouse_y) != null) {
        sapp.setMouseCursor(.POINTING_HAND);
    } else {
        sapp.setMouseCursor(.DEFAULT);
    }

    // Pass mouse to graph for sparkline tooltip hit-testing
    graph.mouse_x = state.mouse_x;
    graph.mouse_y = state.mouse_y;

    // Render
    sg.beginPass(.{
        .action = state.pass_action,
        .swapchain = sglue.swapchain(),
    });
    renderer.render(commands);
    sg.endPass();
    sg.commit();
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
    state.display_arena.deinit();
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
            // Handle column header reorder drag — activate after threshold
            if (state.dragging_header != null and !state.header_drag_started) {
                if (@abs(state.mouse_x - state.header_drag_start_x) >= state.header_drag_threshold) {
                    state.header_drag_started = true;
                }
            }
        },
        .MOUSE_DOWN => {
            if (e.mouse_button == .LEFT) {
                state.mouse_x = e.mouse_x / dpi;
                state.mouse_y = e.mouse_y / dpi;

                // Check if clicking a column resize edge (highest priority)
                if (hitTestColumnEdge(state.mouse_x, state.mouse_y)) |col_idx| {
                    state.dragging_col = col_idx;
                    state.drag_start_x = state.mouse_x;
                    state.drag_start_width = state.col_widths[col_idx];
                    // Don't set mouse_clicked — this is a resize, not a row click
                } else if (hitTestColumnHeader(state.mouse_x, state.mouse_y)) |col_idx| {
                    // Start potential column header drag (activates after threshold)
                    state.dragging_header = col_idx;
                    state.header_drag_start_x = state.mouse_x;
                    state.header_drag_started = false;
                    // Don't set mouse_clicked — sort is deferred to MOUSE_UP
                    state.mouse_down = true;
                } else {
                    state.mouse_down = true;
                    state.mouse_clicked = true;
                    state.click_modifiers = e.modifiers;
                }
            }
        },
        .MOUSE_UP => {
            if (e.mouse_button == .LEFT) {
                if (state.header_drag_started) {
                    // Finalize column reorder
                    if (state.dragging_header) |src_col| {
                        const drop_pos = findDropPosition(state.mouse_x);
                        // Find current position of the dragged column
                        var src_pos: u8 = 0;
                        for (state.col_order, 0..) |c, p| {
                            if (c == src_col) {
                                src_pos = @intCast(p);
                                break;
                            }
                        }
                        if (src_pos != drop_pos) {
                            // Remove from old position and insert at new position
                            var new_order: [layout.COL_COUNT]u8 = undefined;
                            var dst: u8 = 0;
                            // Copy all except src
                            for (state.col_order) |c| {
                                if (c != src_col) {
                                    new_order[dst] = c;
                                    dst += 1;
                                }
                            }
                            // Insert src_col at drop_pos (clamped to new length)
                            const insert_at = @min(drop_pos, layout.COL_COUNT - 1);
                            // Shift elements right to make room
                            var j: u8 = layout.COL_COUNT - 1;
                            while (j > insert_at) : (j -= 1) {
                                new_order[j] = new_order[j - 1];
                            }
                            new_order[insert_at] = src_col;
                            state.col_order = new_order;
                        }
                    }
                } else if (state.dragging_header != null) {
                    // Threshold not met — treat as a simple header click (sort)
                    state.mouse_clicked = true;
                    state.click_modifiers = e.modifiers;
                }
                state.dragging_header = null;
                state.header_drag_started = false;
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
/// Returns the logical column index if within the resize zone, null otherwise.
fn hitTestColumnEdge(mx: f32, my: f32) ?u8 {
    // Column header area: Y from header + tab bar to + col_header_height
    const header_top = theme.header_height + theme.tab_bar_height;
    const header_bottom = header_top + theme.col_header_height;
    if (my < header_top or my > header_bottom) return null;

    const edge_tolerance: f32 = 5.0;
    const left_pad: f32 = 14.0; // matches row padding.left in layout

    var edge_x: f32 = left_pad;
    for (state.col_order) |col_idx| {
        if (col_idx == @intFromEnum(layout.Col.path)) continue; // PATH is grow, no resize
        edge_x += state.col_widths[col_idx];
        if (@abs(mx - edge_x) <= edge_tolerance) {
            return col_idx;
        }
    }
    return null;
}

/// Test if mouse position is over a column header body (not the resize handle edge).
/// Returns the logical column index, null if not over any header.
fn hitTestColumnHeader(mx: f32, my: f32) ?u8 {
    const header_top = theme.header_height + theme.tab_bar_height;
    const header_bottom = header_top + theme.col_header_height;
    if (my < header_top or my > header_bottom) return null;

    // Don't start header drag if we're on a resize edge
    if (hitTestColumnEdge(mx, my) != null) return null;

    const left_pad: f32 = 14.0;
    var edge_x: f32 = left_pad;
    for (state.col_order) |col_idx| {
        const w: f32 = if (col_idx == @intFromEnum(layout.Col.path)) 9999 else state.col_widths[col_idx];
        if (mx >= edge_x and mx < edge_x + w) {
            return col_idx;
        }
        edge_x += w;
    }
    return null;
}

/// Find the display position index where a column should be dropped based on mouse X.
fn findDropPosition(mx: f32) u8 {
    const left_pad: f32 = 14.0;
    var edge_x: f32 = left_pad;
    for (state.col_order, 0..) |col_idx, pos| {
        const w: f32 = if (col_idx == @intFromEnum(layout.Col.path)) 9999 else state.col_widths[col_idx];
        const mid = edge_x + w / 2.0;
        if (mx < mid) return @intCast(pos);
        edge_x += w;
    }
    return layout.COL_COUNT - 1;
}

const NavDirection = enum { up, down };

fn processKeyNav(dir: NavDirection) void {
    const pids = state.materialized_pids;
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

    const pids = state.materialized_pids;

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

    var theme_buf: [16]u8 = undefined;
    const theme_str = std.fmt.bufPrint(&theme_buf, "{d}", .{theme.current_theme_index}) catch return;

    const argv = [_][]const u8{ detail_path, pid_str, "--theme", theme_str };
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
