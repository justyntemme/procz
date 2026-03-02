const std = @import("std");
const sokol = @import("sokol");
const clay = @import("zclay");
const platform = @import("platform");
const process = @import("process");
const renderer = @import("renderer");
const font = @import("font");
const theme = @import("theme");
const graph = @import("graph");
const column_ops = @import("column_ops");
const text_select = @import("text_select");
const scrollbar = @import("scrollbar");

const builtin = @import("builtin");
const slog = sokol.log;
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const print = std.debug.print;

const native_menu = if (builtin.os.tag == .macos) @cImport({
    @cInclude("macos_menu.h");
}) else struct {
    pub fn setup_detail_menu() void {}
};

const native_ui = if (builtin.os.tag == .macos) @cImport({
    @cInclude("macos_window_style.h");
    @cInclude("macos_defaults.h");
    @cInclude("macos_clipboard.h");
}) else struct {
    pub fn setup_window_style() void {}
    pub fn register_theme_observer() void {}
    pub fn check_theme_notification() c_int { return -1; }
    pub fn clipboard_set_string(_: [*c]const u8, _: c_int) void {}
};

const DetailTab = enum { overview, network, environment, security };

// Network column definitions
const NetCol = enum(u3) { state_col = 0, local = 1, remote = 2, pid_col = 3, proto = 4, proc_name = 5 };
const NET_COL_COUNT: u8 = 6;
const NET_RESIZABLE: u8 = 5; // proc_name grows (not resizable)
const net_default_widths = [NET_RESIZABLE]f32{ 80, 200, 200, 50, 42 };
const net_default_order = [NET_COL_COUNT]u8{ 0, 1, 2, 3, 4, 5 };
const net_col_labels = [NET_COL_COUNT][]const u8{ "STATE", "LOCAL", "REMOTE", "PID", "PROTO", "PROCESS" };

const state = struct {
    var pass_action: sg.PassAction = .{};
    var snapshot_arena: std.heap.ArenaAllocator = undefined;
    var frame_arena: std.heap.ArenaAllocator = undefined;
    var clay_memory: []u8 = &.{};

    // Target PID (from command line)
    var target_pid: process.pid_t = 0;

    // Collected process data (owned by snapshot_arena)
    var proc_data: ?process.Proc = null;
    var has_data: bool = false;

    // Coalition ID for target process
    var coalition_id: u64 = 0;

    // TCP connections (current display slice — may point to snapshot_arena or preserved_conns)
    var connections: []const process.TcpConnection = &.{};

    // PID → process name map for connection display
    var conn_names: std.AutoHashMapUnmanaged(process.pid_t, []const u8) = .empty;

    // Input state
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var mouse_down: bool = false;
    var mouse_clicked: bool = false;
    var scroll_dx: f32 = 0;
    var scroll_dy: f32 = 0;

    // Tab state
    var active_tab: DetailTab = .overview;

    // Refresh timer
    var last_refresh_ns: i128 = 0;
    const refresh_interval_ns: i128 = 3 * std.time.ns_per_s;

    // Network column resize/reorder state
    var net_col_widths: [NET_RESIZABLE]f32 = net_default_widths;
    var net_col_order: [NET_COL_COUNT]u8 = net_default_order;
    var net_drag: column_ops.ColumnDragState = .{};

    // Tab animation
    var tab_anim: f32 = 0.0; // 0=overview, 1=network

    // Process args (environment tab)
    var proc_args: ?process.ProcessArgs = null;

    // Text selection state (drag-to-select within value cells)
    var value_select: text_select.TextSelectState = .{};
    var active_cell_idx: ?usize = null; // index into selectable_entries
    var active_cell_x: f32 = 0; // bounding box X of active cell (from render commands)
    var drag_start_y: f32 = 0; // mouse Y when drag started (to detect vertical scroll intent)

    // Security info (fetched once)
    var security_info: ?process.SecurityInfo = null;
    var security_fetched: bool = false;

    // Preserve connections toggle
    var preserve_connections: bool = false;
    var toggle_anim_t: f32 = 0.0; // 0.0 = off, 1.0 = on, lerped each frame
    var preserved_conns: std.ArrayListUnmanaged(process.TcpConnection) = .empty;
    var preserved_names: std.AutoHashMapUnmanaged(process.pid_t, []const u8) = .empty;
};

// Selectable entry tracking — populated during layout, queried during click
const SelectableEntry = struct {
    element_id: clay.ElementId,
    text: []const u8,
};
var selectable_entries: [256]SelectableEntry = undefined;
var selectable_count: usize = 0;

fn registerSelectable(id: clay.ElementId, text: []const u8) void {
    if (selectable_count < selectable_entries.len) {
        selectable_entries[selectable_count] = .{ .element_id = id, .text = text };
        selectable_count += 1;
    }
}

const NET_TOOLBAR_HEIGHT: f32 = 32;

fn netColumnConfig() column_ops.ColumnConfig {
    return .{
        .col_widths = &state.net_col_widths,
        .col_order = &state.net_col_order,
        .col_count = NET_COL_COUNT,
        .grow_col_idx = @intFromEnum(NetCol.proc_name),
        .header_top = theme.header_height + theme.tab_bar_height + NET_TOOLBAR_HEIGHT,
        .header_height = 28,
        .left_pad = 14.0,
    };
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

    state.snapshot_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    state.frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    // Init Clay — raise element limit for large entitlement lists
    clay.setMaxElementCount(16384);
    const min_mem: u32 = clay.minMemorySize();
    state.clay_memory = std.heap.page_allocator.alloc(u8, min_mem) catch {
        print("procz-detail: failed to allocate clay memory\n", .{});
        return;
    };
    const clay_arena = clay.createArenaWithCapacityAndMemory(state.clay_memory);
    const init_dpi = sapp.dpiScale();
    _ = clay.initialize(clay_arena, .{
        .w = sapp.widthf() / init_dpi,
        .h = sapp.heightf() / init_dpi,
    }, .{ .error_handler_function = clayErrorHandler });
    clay.setMeasureTextFunction(void, {}, renderer.measureText);

    // Collect initial data
    collectData();

    native_menu.setup_detail_menu();
    native_ui.setup_window_style();
    native_ui.register_theme_observer();
}

fn collectData() void {
    _ = state.snapshot_arena.reset(.retain_capacity);
    const alloc = state.snapshot_arena.allocator();
    state.proc_data = platform.collectProcess(alloc, state.target_pid);
    state.has_data = state.proc_data != null;

    // Process arguments and environment variables
    state.proc_args = platform.collectProcessArgs(alloc, state.target_pid);

    // Coalition ID
    state.coalition_id = platform.getCoalitionId(state.target_pid);

    // Security info (only fetch once — entitlements don't change at runtime)
    // Uses page_allocator since this data persists across snapshot_arena resets
    if (!state.security_fetched) {
        state.security_info = platform.collectSecurityInfo(std.heap.page_allocator, state.target_pid);
        state.security_fetched = true;
    }

    // TCP connections
    const all_conns = platform.collectTcpConnections(alloc) catch &.{};

    // Filter: connections belonging to this PID or its coalition
    var filtered: std.ArrayListUnmanaged(process.TcpConnection) = .empty;
    for (all_conns) |conn| {
        const pid_match = conn.pid == state.target_pid;
        const coalition_match = state.coalition_id > 0 and conn.coalition_id == state.coalition_id;
        if (pid_match or coalition_match) {
            filtered.append(alloc, conn) catch continue;
        }
    }
    const current_conns = filtered.toOwnedSlice(alloc) catch &.{};

    if (state.preserve_connections) {
        // Merge current connections into preserved list
        for (current_conns) |conn| {
            if (!isPreserved(conn)) {
                // Copy to long-lived storage
                state.preserved_conns.append(std.heap.page_allocator, conn) catch continue;
            } else {
                // Update TCP state of existing preserved connection
                updatePreservedState(conn);
            }
        }
        // Rebuild conn_names from preserved conns
        state.conn_names = .empty;
        for (state.preserved_conns.items) |conn| {
            if (state.conn_names.contains(conn.pid)) continue;
            if (platform.collectProcess(alloc, conn.pid)) |p| {
                state.conn_names.put(alloc, conn.pid, p.name) catch continue;
            }
        }
        // Also check preserved_names for processes that may have exited
        for (state.preserved_conns.items) |conn| {
            if (!state.conn_names.contains(conn.pid)) {
                if (state.preserved_names.get(conn.pid)) |name| {
                    state.conn_names.put(alloc, conn.pid, name) catch continue;
                }
            }
        }
        state.connections = state.preserved_conns.items;
    } else {
        state.connections = current_conns;

        // Build PID → name map for connections
        state.conn_names = .empty;
        for (state.connections) |conn| {
            if (state.conn_names.contains(conn.pid)) continue;
            if (platform.collectProcess(alloc, conn.pid)) |p| {
                state.conn_names.put(alloc, conn.pid, p.name) catch continue;
            }
        }
    }

    // Save process names for preserved mode (in case process exits later)
    if (state.preserve_connections) {
        for (state.connections) |conn| {
            if (!state.preserved_names.contains(conn.pid)) {
                if (state.conn_names.get(conn.pid)) |name| {
                    // Dupe to page_allocator for long-lived storage
                    const duped = std.heap.page_allocator.dupe(u8, name) catch continue;
                    state.preserved_names.put(std.heap.page_allocator, conn.pid, duped) catch continue;
                }
            }
        }
    }

    state.last_refresh_ns = std.time.nanoTimestamp();
}

fn isPreserved(conn: process.TcpConnection) bool {
    for (state.preserved_conns.items) |existing| {
        if (existing.local_port == conn.local_port and
            existing.remote_port == conn.remote_port and
            existing.pid == conn.pid and
            std.mem.eql(u8, existing.local_addr[0..existing.local_addr_len], conn.local_addr[0..conn.local_addr_len]) and
            std.mem.eql(u8, existing.remote_addr[0..existing.remote_addr_len], conn.remote_addr[0..conn.remote_addr_len]))
        {
            return true;
        }
    }
    return false;
}

fn updatePreservedState(conn: process.TcpConnection) void {
    for (state.preserved_conns.items) |*existing| {
        if (existing.local_port == conn.local_port and
            existing.remote_port == conn.remote_port and
            existing.pid == conn.pid and
            std.mem.eql(u8, existing.local_addr[0..existing.local_addr_len], conn.local_addr[0..conn.local_addr_len]) and
            std.mem.eql(u8, existing.remote_addr[0..existing.remote_addr_len], conn.remote_addr[0..conn.remote_addr_len]))
        {
            existing.state = conn.state;
            return;
        }
    }
}

fn clayErrorHandler(err: clay.ErrorData) callconv(.c) void {
    print("clay error: {s}\n", .{err.error_text.chars[0..@intCast(err.error_text.length)]});
}

export fn frame() void {
    _ = state.frame_arena.reset(.retain_capacity);
    const frame_alloc = state.frame_arena.allocator();

    // Check cross-process theme sync from main procz window
    {
        const notified = native_ui.check_theme_notification();
        if (notified >= 0 and @as(usize, @intCast(notified)) < theme.theme_count) {
            theme.applyTheme(@intCast(notified));
        }
    }

    // Periodic refresh
    const now_ns = std.time.nanoTimestamp();
    if (now_ns - state.last_refresh_ns >= state.refresh_interval_ns) {
        collectData();
    }

    const dpi = sapp.dpiScale();
    clay.setLayoutDimensions(.{
        .w = sapp.widthf() / dpi,
        .h = sapp.heightf() / dpi,
    });
    clay.setPointerState(.{ .x = state.mouse_x, .y = state.mouse_y }, state.mouse_down);

    const delta_time = @as(f32, @floatCast(sapp.frameDuration()));
    clay.updateScrollContainers(false, .{ .x = state.scroll_dx, .y = state.scroll_dy }, delta_time);
    state.scroll_dx = 0;
    state.scroll_dy = 0;

    // Update clear color to match theme
    state.pass_action.colors[0].clear_value = .{
        .r = @as(f32, theme.bg[0]) / 255.0,
        .g = @as(f32, theme.bg[1]) / 255.0,
        .b = @as(f32, theme.bg[2]) / 255.0,
        .a = 1.0,
    };

    // Cursor feedback for network tab column interactions
    if (state.active_tab == .network) {
        const cfg = netColumnConfig();
        if (state.net_drag.dragging_col != null) {
            sapp.setMouseCursor(.RESIZE_EW);
        } else if (state.net_drag.header_drag_started) {
            sapp.setMouseCursor(.RESIZE_ALL);
        } else if (column_ops.hitTestEdge(state.mouse_x, state.mouse_y, cfg) != null) {
            sapp.setMouseCursor(.RESIZE_EW);
        } else if (column_ops.hitTestHeader(state.mouse_x, state.mouse_y, cfg) != null) {
            sapp.setMouseCursor(.POINTING_HAND);
        } else {
            sapp.setMouseCursor(.DEFAULT);
        }
    } else {
        sapp.setMouseCursor(.DEFAULT);
    }

    // Handle click
    if (state.mouse_clicked) {
        processClick();
        state.mouse_clicked = false;
    }

    // Animate toggle: lerp toward target (ease-out)
    {
        const target: f32 = if (state.preserve_connections) 1.0 else 0.0;
        const diff = target - state.toggle_anim_t;
        if (@abs(diff) < 0.005) {
            state.toggle_anim_t = target;
        } else {
            state.toggle_anim_t += diff * 0.18;
        }
    }
    // Animate tab indicator cross-fade (4 tabs: 0=overview, 1=network, 2=environment, 3=security)
    {
        const target: f32 = switch (state.active_tab) {
            .overview => 0.0,
            .network => 1.0,
            .environment => 2.0,
            .security => 3.0,
        };
        const diff = target - state.tab_anim;
        if (@abs(diff) < 0.005) {
            state.tab_anim = target;
        } else {
            state.tab_anim += diff * 0.18;
        }
    }

    const commands = buildLayout(frame_alloc);

    // Extract bounding box X of active cell for hit-testing during drag
    if (state.active_cell_idx) |idx| {
        if (idx < selectable_count) {
            const target_id = selectable_entries[idx].element_id.id;
            for (commands) |cmd| {
                if (cmd.command_type == .rectangle and cmd.id == target_id) {
                    state.active_cell_x = cmd.bounding_box.x;
                    break;
                }
            }
        }
    }

    // Register scrollbars for overlay rendering
    scrollbar.reset();
    scrollbar.addFromClay("overview-scroll", .{});
    scrollbar.addFromClay("env-scroll", .{});
    scrollbar.addFromClay("sec-scroll", .{});
    scrollbar.addFromClay("net-scroll", .{ .vertical = true, .horizontal = true });

    sg.beginPass(.{
        .action = state.pass_action,
        .swapchain = sglue.swapchain(),
    });
    renderer.render(commands);
    sg.endPass();
    sg.commit();
}

fn processClick() void {
    if (clay.pointerOver(clay.ElementId.ID("tab-overview"))) {
        state.active_tab = .overview;
        return;
    }
    if (clay.pointerOver(clay.ElementId.ID("tab-network"))) {
        state.active_tab = .network;
        return;
    }
    if (clay.pointerOver(clay.ElementId.ID("tab-environment"))) {
        state.active_tab = .environment;
        return;
    }
    if (clay.pointerOver(clay.ElementId.ID("tab-security"))) {
        state.active_tab = .security;
        return;
    }

    // Toggle switch click
    if (clay.pointerOver(clay.ElementId.ID("toggle-preserve"))) {
        state.preserve_connections = !state.preserve_connections;
        if (!state.preserve_connections) {
            state.preserved_conns.clearAndFree(std.heap.page_allocator);
            // Free preserved names
            var name_iter = state.preserved_names.iterator();
            while (name_iter.next()) |entry| {
                std.heap.page_allocator.free(entry.value_ptr.*);
            }
            state.preserved_names = .empty;
            // Force refresh to get current state
            collectData();
        }
        return;
    }

    // Check if a selectable value cell was clicked (overview + environment + security tabs)
    if (state.active_tab == .overview or state.active_tab == .environment or state.active_tab == .security) {
        if (checkValueClick()) return;
    }

    // Click on empty area — deselect
    state.value_select.clear();
    state.active_cell_idx = null;
}

fn checkValueClick() bool {
    for (selectable_entries[0..selectable_count], 0..) |entry, idx| {
        if (clay.pointerOver(entry.element_id)) {
            state.active_cell_idx = idx;
            state.drag_start_y = state.mouse_y;
            const char_pos = text_select.hitTestText(state.mouse_x, state.active_cell_x, entry.text, 13);
            state.value_select.beginDrag(char_pos);
            return true;
        }
    }
    return false;
}

fn buildLayout(alloc: std.mem.Allocator) []clay.RenderCommand {
    conn_idx = 0;
    selectable_count = 0;
    clay.beginLayout();

    const proc_opt = state.proc_data;
    const name = if (proc_opt) |p| p.name else "(process not accessible)";
    const pid_str = std.fmt.allocPrint(alloc, "PID {d}", .{state.target_pid}) catch "?";

    clay.UI()(.{
        .id = clay.ElementId.ID("root"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
        },
        .background_color = theme.bg,
    })({
        // Header
        clay.UI()(.{
            .id = clay.ElementId.ID("header"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.header_height) },
                .padding = clay.Padding.axes(14, 16),
                .child_alignment = .{ .x = .left, .y = .center },
                .direction = .left_to_right,
                .child_gap = 10,
            },
            .background_color = theme.header_bg,
            .border = .{
                .color = theme.separator,
                .width = .{ .bottom = 1 },
            },
        })({
            clay.text(name, .{ .color = theme.text_title, .font_size = 18 });

            // PID badge
            clay.UI()(.{
                .id = clay.ElementId.ID("pid-badge"),
                .layout = .{
                    .padding = clay.Padding.axes(8, 4),
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = .{
                    theme.separator[0],
                    theme.separator[1],
                    theme.separator[2],
                    80,
                },
                .corner_radius = clay.CornerRadius.all(theme.corner_radius_sm),
            })({
                clay.text(pid_str, .{ .color = theme.text_dim, .font_size = 12 });
            });
        });

        // Tab bar
        buildTabBar();

        // Tab content
        switch (state.active_tab) {
            .overview => buildOverviewTab(alloc, proc_opt),
            .network => buildNetworkContent(alloc),
            .environment => buildEnvironmentContent(alloc),
            .security => buildSecurityTab(alloc),
        }

        // Network toolbar — floating overlay anchored to root, completely
        // independent of column layout.  Rendered after tab content so it
        // always appears on top.
        if (state.active_tab == .network) {
            buildNetToolbar(alloc);
        }

        // Footer
        clay.UI()(.{
            .id = clay.ElementId.ID("footer"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.footer_height) },
                .padding = clay.Padding.axes(14, 16),
                .child_alignment = .{ .x = .left, .y = .center },
            },
            .background_color = theme.footer_bg,
            .border = .{
                .color = theme.separator,
                .width = .{ .top = 1 },
            },
        })({
            clay.text("procz-detail", .{ .color = theme.text_footer, .font_size = 12 });
        });
    });

    return clay.endLayout();
}

fn buildTabBar() void {
    clay.UI()(.{
        .id = clay.ElementId.ID("tab-bar"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.tab_bar_height) },
            .direction = .left_to_right,
            .padding = .{ .left = 4, .right = 4 },
            .child_alignment = .{ .y = .bottom },
        },
        .background_color = theme.tab_bg,
    })({
        buildTabItem("tab-overview", "Overview", state.active_tab == .overview, @max(0, 1.0 - @abs(state.tab_anim - 0.0)));
        buildTabItem("tab-network", "Network", state.active_tab == .network, @max(0, 1.0 - @abs(state.tab_anim - 1.0)));
        buildTabItem("tab-environment", "Environment", state.active_tab == .environment, @max(0, 1.0 - @abs(state.tab_anim - 2.0)));
        buildTabItem("tab-security", "Security", state.active_tab == .security, @max(0, 1.0 - @abs(state.tab_anim - 3.0)));
    });
}

fn buildTabItem(comptime id: []const u8, label: []const u8, is_active: bool, indicator_alpha: f32) void {
    const is_hovered = !is_active and clay.pointerOver(clay.ElementId.ID(id));
    const item_bg = if (is_active) theme.bg
        else if (is_hovered) theme.row_hover
        else theme.transparent;
    const text_color = if (is_active) theme.text_primary else theme.text_dim;

    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fit, .h = clay.SizingAxis.fixed(theme.tab_bar_height - 4) },
            .direction = .top_to_bottom,
            .padding = .{ .left = 16, .right = 16, .top = 0, .bottom = 0 },
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = item_bg,
        .corner_radius = .{ .top_left = theme.corner_radius_sm, .top_right = theme.corner_radius_sm, .bottom_left = 0, .bottom_right = 0 },
    })({
        clay.text(label, .{ .color = text_color, .font_size = 14 });

        // Spacer pushes indicator to bottom edge with breathing room from text
        clay.UI()(.{
            .id = clay.ElementId.ID(id ++ "-sp"),
            .layout = .{ .sizing = .{ .h = clay.SizingAxis.grow } },
        })({});

        if (indicator_alpha > 0.01) {
            clay.UI()(.{
                .id = clay.ElementId.ID(id ++ "-ind"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(2) },
                },
                .background_color = .{ theme.accent[0], theme.accent[1], theme.accent[2], theme.accent[3] * indicator_alpha },
                .corner_radius = clay.CornerRadius.all(1),
            })({});
        }
    });
}

// ---------------------------------------------------------------------------
// Overview tab
// ---------------------------------------------------------------------------

fn buildOverviewTab(alloc: std.mem.Allocator, proc_opt: ?process.Proc) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("overview-scroll"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
            .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
            .child_gap = 12,
        },
        .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
        .background_color = theme.bg,
    })({
        if (proc_opt) |p| {
            const path = if (p.path.len > 0) p.path else "(unknown path)";

            // --- Identity card ---
            buildCard("card-id", &.{
                .{ "Path", path },
                .{ "State", switch (p.state) {
                    .running => "Running",
                    .sleeping => "Sleeping",
                    .stopped => "Stopped",
                    .zombie => "Zombie",
                    .unknown => "Unknown",
                } },
            });

            // --- Resource card ---
            const mem_mb = p.mem_rss / (1024 * 1024);
            const mem_str = if (mem_mb > 0)
                std.fmt.allocPrint(alloc, "{d} MB", .{mem_mb}) catch "?"
            else
                std.fmt.allocPrint(alloc, "{d} KB", .{p.mem_rss / 1024}) catch "?";

            const phys_mb = p.mem_phys / (1024 * 1024);
            const phys_str = if (phys_mb > 0)
                std.fmt.allocPrint(alloc, "{d} MB", .{phys_mb}) catch "?"
            else
                std.fmt.allocPrint(alloc, "{d} KB", .{p.mem_phys / 1024}) catch "?";

            const total_ns = p.total_user + p.total_system;
            const total_secs = total_ns / std.time.ns_per_s;
            const cpu_str = if (total_secs >= 3600)
                std.fmt.allocPrint(alloc, "{d}h {d}m {d}s", .{ total_secs / 3600, (total_secs % 3600) / 60, total_secs % 60 }) catch "?"
            else if (total_secs >= 60)
                std.fmt.allocPrint(alloc, "{d}m {d}s", .{ total_secs / 60, total_secs % 60 }) catch "?"
            else
                std.fmt.allocPrint(alloc, "{d}s", .{total_secs}) catch "?";

            const disk_read_mb = p.diskio_bytes_read / (1024 * 1024);
            const disk_write_mb = p.diskio_bytes_written / (1024 * 1024);
            const disk_str = std.fmt.allocPrint(alloc, "Read: {d} MB  Write: {d} MB", .{ disk_read_mb, disk_write_mb }) catch "?";

            buildCard("card-res", &.{
                .{ "Memory (RSS)", mem_str },
                .{ "Physical Footprint", phys_str },
                .{ "CPU Time", cpu_str },
                .{ "Disk I/O", disk_str },
            });

            // --- System card ---
            const ppid_str = std.fmt.allocPrint(alloc, "{d}", .{p.ppid}) catch "?";

            if (state.coalition_id > 0) {
                const coal_str = std.fmt.allocPrint(alloc, "{d}", .{state.coalition_id}) catch "?";
                buildCard("card-sys", &.{
                    .{ "Parent PID", ppid_str },
                    .{ "Coalition ID", coal_str },
                });
            } else {
                buildCard("card-sys", &.{
                    .{ "Parent PID", ppid_str },
                });
            }
        } else {
            // Error card
            clay.UI()(.{
                .id = clay.ElementId.ID("card-err"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow },
                    .direction = .top_to_bottom,
                    .padding = clay.Padding.all(16),
                    .child_gap = 6,
                },
                .background_color = theme.graph_section_bg,
                .corner_radius = clay.CornerRadius.all(theme.corner_radius),
                .border = .{
                    .color = .{ theme.separator[0], theme.separator[1], theme.separator[2], 50 },
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                },
            })({
                clay.text("Process not accessible", .{
                    .color = theme.text_primary,
                    .font_size = 14,
                });
                clay.text("May require entitlements. Run with: zig build sign-run -Didentity=...", .{
                    .color = theme.text_dim,
                    .font_size = 12,
                });
            });
        }
    });
}

/// Insert newlines into long text at natural break points (/, :, =, ;) to enable wrapping.
/// Falls back to hard character-level breaks for text without natural delimiters (e.g. base64).
/// Uses the frame arena so results are valid for the current frame only.
fn wrapLongText(text: []const u8) []const u8 {
    // Dynamic max_line based on available value column width
    const dpi = sapp.dpiScale();
    const win_w = sapp.widthf() / dpi;
    // Available: window - scroll padding(32) - card padding(28) - key column(200)
    const avail_px = @max(win_w - 260, 100);
    const char_w: f32 = 7.5; // approximate char width at font_size=13
    const max_line: usize = @intFromFloat(@max(avail_px / char_w, 20));

    if (text.len <= max_line) return text;

    const alloc = state.frame_arena.allocator();

    // First pass: find positions where newlines should be inserted.
    var breaks: [256]usize = undefined;
    var break_count: usize = 0;
    var col: usize = 0;
    var last_brk: usize = 0;
    var has_brk: bool = false;

    for (text, 0..) |ch, idx| {
        col += 1;
        if (ch == '/' or ch == ':' or ch == '=' or ch == ';' or ch == ' ' or ch == '-' or ch == ',' or ch == '\\' or ch == '&' or ch == '+') {
            last_brk = idx;
            has_brk = true;
        }
        if (col >= max_line) {
            if (has_brk) {
                // Break at last natural delimiter
                if (break_count < breaks.len) {
                    breaks[break_count] = last_brk;
                    break_count += 1;
                }
                col = idx - last_brk;
                has_brk = false;
            } else {
                // No natural break point — hard break at current position
                if (break_count < breaks.len) {
                    breaks[break_count] = idx;
                    break_count += 1;
                }
                col = 0;
            }
        }
    }

    if (break_count == 0) return text;

    // Second pass: copy text, inserting '\n' after each break position.
    var buf = alloc.alloc(u8, text.len + break_count) catch return text;
    var out: usize = 0;
    var bi: usize = 0;

    for (text, 0..) |ch, idx| {
        buf[out] = ch;
        out += 1;
        if (bi < break_count and idx == breaks[bi]) {
            buf[out] = '\n';
            out += 1;
            bi += 1;
        }
    }

    return buf[0..out];
}

/// Check if a given selectable entry index is the active cell with a selection or cursor.
fn isActiveCell(sel_idx: usize) bool {
    const idx = state.active_cell_idx orelse return false;
    return idx == sel_idx;
}

/// Render value text with selection highlight (split into pre/sel/post segments).
fn renderValueWithSelection(text: []const u8) void {
    if (state.value_select.selectedRange(text.len)) |r| {
        // Three-segment rendering: pre-selection, selection highlight, post-selection
        if (r.lo > 0) {
            clay.text(text[0..r.lo], .{ .color = theme.text_primary, .font_size = 13, .line_height = 18 });
        }
        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.fit } },
            .background_color = .{ theme.accent[0], theme.accent[1], theme.accent[2], 80 },
            .corner_radius = clay.CornerRadius.all(2),
        })({
            clay.text(text[r.lo..r.hi], .{ .color = theme.text_primary, .font_size = 13, .line_height = 18 });
        });
        if (r.hi < text.len) {
            clay.text(text[r.hi..], .{ .color = theme.text_primary, .font_size = 13, .line_height = 18 });
        }
    } else {
        // Has cursor but no selection — render normally (cursor bar visual not needed for read-only cells)
        clay.text(text, .{ .color = theme.text_primary, .font_size = 13, .line_height = 18 });
    }
}

/// Like renderValueWithSelection but preserves the given text color for non-selected segments.
fn renderValueWithSelectionColor(text: []const u8, color: clay.Color) void {
    if (state.value_select.selectedRange(text.len)) |r| {
        if (r.lo > 0) {
            clay.text(text[0..r.lo], .{ .color = color, .font_size = 13, .line_height = 18 });
        }
        clay.UI()(.{
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.fit } },
            .background_color = .{ theme.accent[0], theme.accent[1], theme.accent[2], 80 },
            .corner_radius = clay.CornerRadius.all(2),
        })({
            clay.text(text[r.lo..r.hi], .{ .color = color, .font_size = 13, .line_height = 18 });
        });
        if (r.hi < text.len) {
            clay.text(text[r.hi..], .{ .color = color, .font_size = 13, .line_height = 18 });
        }
    } else {
        clay.text(text, .{ .color = color, .font_size = 13, .line_height = 18 });
    }
}

/// Render a card container with label-value rows separated by hairlines.
fn buildCard(comptime id: []const u8, items: []const struct { []const u8, []const u8 }) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow },
            .direction = .top_to_bottom,
            .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
            .child_gap = 0,
        },
        .background_color = theme.graph_section_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius),
        .border = .{
            .color = .{ theme.separator[0], theme.separator[1], theme.separator[2], 50 },
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        },
    })({
        for (items, 0..) |item, i| {
            // Row
            clay.UI()(.{
                .id = clay.ElementId.IDI(id ++ "r", @intCast(i)),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow },
                    .direction = .left_to_right,
                    .padding = .{ .top = 6, .bottom = 6 },
                    .child_alignment = .{ .y = .top },
                },
            })({
                // Label
                clay.UI()(.{
                    .id = clay.ElementId.IDI(id ++ "l", @intCast(i)),
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.fixed(140) },
                        .padding = .{ .top = 1 },
                        .child_alignment = .{ .x = .left },
                    },
                })({
                    clay.text(item[0], .{ .color = theme.text_dim, .font_size = 13 });
                });
                // Value (drag-to-select)
                const wrapped_val = wrapLongText(item[1]);
                const val_id = clay.ElementId.IDI(id ++ "v", @intCast(i));
                const sel_idx = selectable_count;
                registerSelectable(val_id, wrapped_val);
                const is_active = isActiveCell(sel_idx);
                clay.UI()(.{
                    .id = val_id,
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.grow },
                        .child_alignment = .{ .x = .left },
                        .direction = .left_to_right,
                    },
                    .background_color = theme.transparent,
                    .corner_radius = clay.CornerRadius.all(3),
                })({
                    if (is_active) {
                        renderValueWithSelection(wrapped_val);
                    } else {
                        clay.text(wrapped_val, .{ .color = theme.text_primary, .font_size = 13, .line_height = 18 });
                    }
                });
            });

            // Hairline separator between rows (not after last)
            if (i < items.len - 1) {
                clay.UI()(.{
                    .id = clay.ElementId.IDI(id ++ "s", @intCast(i)),
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(1) },
                    },
                    .background_color = .{ theme.separator[0], theme.separator[1], theme.separator[2], 40 },
                })({});
            }
        }
    });
}

// ---------------------------------------------------------------------------
// Environment tab
// ---------------------------------------------------------------------------

var env_row_idx: u16 = 0;

fn buildEnvironmentContent(alloc: std.mem.Allocator) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("env-scroll"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
            .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
            .child_gap = 12,
        },
        .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
        .background_color = theme.bg,
    })({
        env_row_idx = 0;

        if (state.proc_args) |args| {
            // Arguments card
            buildEnvCard("env-argv", "Arguments", args.argv, alloc, false);

            // Environment Variables card
            // Sort env vars alphabetically for display
            const sorted_env = sortEnvVars(alloc, args.environ);
            buildEnvCard("env-vars", "Environment Variables", sorted_env, alloc, true);
        } else {
            // Empty state
            clay.UI()(.{
                .id = clay.ElementId.ID("env-empty"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow },
                    .direction = .top_to_bottom,
                    .padding = clay.Padding.all(24),
                    .child_gap = 6,
                    .child_alignment = .{ .x = .center },
                },
                .background_color = theme.graph_section_bg,
                .corner_radius = clay.CornerRadius.all(theme.corner_radius),
                .border = .{
                    .color = .{ theme.separator[0], theme.separator[1], theme.separator[2], 50 },
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                },
            })({
                clay.text("Environment data not available", .{
                    .color = theme.text_primary,
                    .font_size = 14,
                });
                clay.text("May require same-user process or entitlements.", .{
                    .color = theme.text_dim,
                    .font_size = 12,
                });
            });
        }
    });
}

fn sortEnvVars(alloc: std.mem.Allocator, environ: []const []const u8) []const []const u8 {
    const sorted = alloc.dupe([]const u8, environ) catch return environ;
    std.mem.sort([]const u8, sorted, {}, struct {
        pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return sorted;
}

fn buildEnvCard(comptime id: []const u8, title: []const u8, items: []const []const u8, alloc: std.mem.Allocator, split_equals: bool) void {
    _ = alloc;
    const display_count = @min(items.len, 500);

    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow },
            .direction = .top_to_bottom,
            .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
            .child_gap = 0,
        },
        .background_color = theme.graph_section_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius),
        .border = .{
            .color = .{ theme.separator[0], theme.separator[1], theme.separator[2], 50 },
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        },
    })({
        // Title row
        clay.UI()(.{
            .id = clay.ElementId.ID(id ++ "-hdr"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow },
                .padding = .{ .top = 4, .bottom = 8 },
            },
        })({
            clay.text(title, .{ .color = theme.text_header, .font_size = 16 });
        });

        if (items.len == 0) {
            clay.UI()(.{
                .id = clay.ElementId.ID(id ++ "-none"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow },
                    .padding = .{ .top = 6, .bottom = 6 },
                },
            })({
                clay.text("(none)", .{ .color = theme.text_dim, .font_size = 13 });
            });
        } else {
            for (items[0..display_count], 0..) |item, i| {
                // Row
                clay.UI()(.{
                    .id = clay.ElementId.IDI(id ++ "r", @intCast(env_row_idx)),
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.grow },
                        .direction = .left_to_right,
                        .padding = .{ .top = 4, .bottom = 4 },
                        .child_alignment = .{ .y = .top },
                    },
                    .background_color = if (i % 2 == 0) theme.transparent else .{ theme.separator[0], theme.separator[1], theme.separator[2], 15 },
                })({
                    if (split_equals) {
                        // Split on '=' into KEY and VALUE
                        if (std.mem.indexOfScalar(u8, item, '=')) |eq_pos| {
                            // Key
                            clay.UI()(.{
                                .id = clay.ElementId.IDI(id ++ "k", @intCast(env_row_idx)),
                                .layout = .{
                                    .sizing = .{ .w = clay.SizingAxis.fixed(200) },
                                    .padding = .{ .top = 1 },
                                    .child_alignment = .{ .x = .left },
                                },
                            })({
                                clay.text(item[0..eq_pos], .{ .color = theme.text_dim, .font_size = 13 });
                            });
                            // Value (drag-to-select)
                            const val_start = eq_pos + 1;
                            const val = if (val_start < item.len) item[val_start..] else "";
                            const wrapped_env_val = wrapLongText(val);
                            const env_val_id = clay.ElementId.IDI(id ++ "v", @intCast(env_row_idx));
                            const env_sel_idx = selectable_count;
                            registerSelectable(env_val_id, wrapped_env_val);
                            const env_is_active = isActiveCell(env_sel_idx);
                            clay.UI()(.{
                                .id = env_val_id,
                                .layout = .{
                                    .sizing = .{ .w = clay.SizingAxis.grow },
                                    .child_alignment = .{ .x = .left },
                                    .direction = .left_to_right,
                                },
                                .background_color = theme.transparent,
                                .corner_radius = clay.CornerRadius.all(3),
                            })({
                                if (env_is_active) {
                                    renderValueWithSelection(wrapped_env_val);
                                } else {
                                    clay.text(wrapped_env_val, .{ .color = theme.text_primary, .font_size = 13, .line_height = 18 });
                                }
                            });
                        } else {
                            // No '=' found, show as-is
                            clay.text(wrapLongText(item), .{ .color = theme.text_primary, .font_size = 13, .line_height = 18 });
                        }
                    } else {
                        // Show index prefix for argv
                        clay.UI()(.{
                            .id = clay.ElementId.IDI(id ++ "ix", @intCast(env_row_idx)),
                            .layout = .{
                                .sizing = .{ .w = clay.SizingAxis.fixed(40) },
                                .padding = .{ .top = 1 },
                                .child_alignment = .{ .x = .left },
                            },
                        })({
                            const idx_str = std.fmt.allocPrint(state.frame_arena.allocator(), "[{d}]", .{i}) catch "?";
                            clay.text(idx_str, .{ .color = theme.text_dim, .font_size = 13 });
                        });
                        // Value (drag-to-select)
                        const wrapped_argv_val = wrapLongText(item);
                        const argv_val_id = clay.ElementId.IDI(id ++ "va", @intCast(env_row_idx));
                        const argv_sel_idx = selectable_count;
                        registerSelectable(argv_val_id, wrapped_argv_val);
                        const argv_is_active = isActiveCell(argv_sel_idx);
                        clay.UI()(.{
                            .id = argv_val_id,
                            .layout = .{
                                .sizing = .{ .w = clay.SizingAxis.grow },
                                .child_alignment = .{ .x = .left },
                                .direction = .left_to_right,
                            },
                            .background_color = theme.transparent,
                            .corner_radius = clay.CornerRadius.all(3),
                        })({
                            if (argv_is_active) {
                                renderValueWithSelection(wrapped_argv_val);
                            } else {
                                clay.text(wrapped_argv_val, .{ .color = theme.text_primary, .font_size = 13, .line_height = 18 });
                            }
                        });
                    }
                });
                env_row_idx +%= 1;
            }
        }
    });
}

// ---------------------------------------------------------------------------
// Security tab
// ---------------------------------------------------------------------------

var sec_row_idx: u16 = 0;

fn buildSecurityTab(alloc: std.mem.Allocator) void {
    sec_row_idx = 0;
    clay.UI()(.{
        .id = clay.ElementId.ID("sec-scroll"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
            .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
            .child_gap = 12,
        },
        .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
        .background_color = theme.bg,
    })({
        if (state.security_info) |info| {
            // --- Code Signing card ---
            buildCard("card-sign", &.{
                .{ "Signing Identity", if (info.code_sign_id.len > 0) info.code_sign_id else "(unsigned)" },
                .{ "Team ID", if (info.team_id.len > 0) info.team_id else "(none)" },
                .{ "Authority", if (info.signing_authority.len > 0) info.signing_authority else "(none)" },
                .{ "Format", if (info.format.len > 0) info.format else "(unknown)" },
            });

            // --- Sandbox card ---
            buildCard("card-sandbox", &.{
                .{ "Sandboxed", if (info.is_sandboxed) "Yes" else "No" },
            });

            // --- Entitlements card ---
            if (info.entitlements.len > 0) {
                buildEntitlementsCard(alloc, info.entitlements);
            } else {
                buildCard("card-ent", &.{
                    .{ "Entitlements", "(none)" },
                });
            }
        } else {
            // Not available
            clay.UI()(.{
                .id = clay.ElementId.ID("sec-empty"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow },
                    .direction = .top_to_bottom,
                    .padding = clay.Padding.all(24),
                    .child_gap = 6,
                    .child_alignment = .{ .x = .center },
                },
                .background_color = theme.graph_section_bg,
                .corner_radius = clay.CornerRadius.all(theme.corner_radius),
                .border = .{
                    .color = .{ theme.separator[0], theme.separator[1], theme.separator[2], 50 },
                    .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                },
            })({
                clay.text("Security data not available", .{
                    .color = theme.text_primary,
                    .font_size = 14,
                });
                clay.text("Process may have exited or requires entitlements.", .{
                    .color = theme.text_dim,
                    .font_size = 12,
                });
            });
        }
    });
}

fn buildEntitlementsCard(alloc: std.mem.Allocator, entitlements: []const process.Entitlement) void {
    const display_count = @min(entitlements.len, 100);

    clay.UI()(.{
        .id = clay.ElementId.ID("card-ent"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow },
            .direction = .top_to_bottom,
            .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
            .child_gap = 0,
        },
        .background_color = theme.graph_section_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius),
        .border = .{
            .color = .{ theme.separator[0], theme.separator[1], theme.separator[2], 50 },
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        },
    })({
        // Title with count
        clay.UI()(.{
            .id = clay.ElementId.ID("ent-hdr"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow },
                .padding = .{ .top = 4, .bottom = 8 },
                .direction = .left_to_right,
                .child_gap = 8,
                .child_alignment = .{ .y = .center },
            },
        })({
            clay.text("Entitlements", .{ .color = theme.text_header, .font_size = 16 });
            const count_str = std.fmt.allocPrint(alloc, "({d})", .{entitlements.len}) catch "";
            clay.text(count_str, .{ .color = theme.text_dim, .font_size = 12 });
        });

        for (entitlements[0..display_count], 0..) |ent, i| {
            // Row — top-to-bottom layout so key and value each get full width
            clay.UI()(.{
                .id = clay.ElementId.IDI("entr", @intCast(sec_row_idx)),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow },
                    .direction = .top_to_bottom,
                    .padding = .{ .left = 4, .right = 4, .top = 6, .bottom = 6 },
                },
                .background_color = if (i % 2 == 0) theme.transparent else .{ theme.separator[0], theme.separator[1], theme.separator[2], 15 },
            })({
                // Key (full width)
                clay.UI()(.{
                    .id = clay.ElementId.IDI("entk", @intCast(sec_row_idx)),
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.grow },
                        .child_alignment = .{ .x = .left },
                    },
                })({
                    clay.text(ent.key, .{ .color = theme.text_dim, .font_size = 12, .wrap_mode = .none });
                });
                // Value — displayed below the key with wrapping
                const wrapped_val = wrapLongText(ent.value);
                const val_id = clay.ElementId.IDI("entv", @intCast(sec_row_idx));
                const sel_idx = selectable_count;
                registerSelectable(val_id, wrapped_val);
                const is_active = isActiveCell(sel_idx);
                clay.UI()(.{
                    .id = val_id,
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.grow },
                        .child_alignment = .{ .x = .left },
                        .direction = .left_to_right,
                        .padding = .{ .top = 2 },
                    },
                    .background_color = theme.transparent,
                    .corner_radius = clay.CornerRadius.all(3),
                })({
                    // Color-code booleans for quick scanning
                    const val_color = if (std.mem.eql(u8, ent.value, "true"))
                        theme.accent
                    else if (std.mem.eql(u8, ent.value, "false"))
                        clay.Color{ 255, 100, 100, 255 }
                    else
                        theme.text_primary;

                    if (is_active and state.value_select.hasSelection()) {
                        renderValueWithSelectionColor(wrapped_val, val_color);
                    } else {
                        clay.text(wrapped_val, .{ .color = val_color, .font_size = 13, .line_height = 18 });
                    }
                });
            });
            sec_row_idx +%= 1;
        }
    });
}

// ---------------------------------------------------------------------------
// Network tab
// ---------------------------------------------------------------------------

fn buildNetworkContent(alloc: std.mem.Allocator) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("net-content"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
        },
        .background_color = theme.bg,
    })({
        // Spacer for floating toolbar above
        clay.UI()(.{
            .id = clay.ElementId.ID("tb-gap"),
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(NET_TOOLBAR_HEIGHT) } },
        })({});

        // Column headers (data-driven from net_col_order)
        clay.UI()(.{
            .id = clay.ElementId.ID("net-hdr"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(28) },
                .padding = clay.Padding.axes(6, 14),
                .child_alignment = .{ .x = .left, .y = .center },
                .direction = .left_to_right,
            },
            .background_color = theme.col_header_bg,
            .border = .{
                .color = theme.separator,
                .width = .{ .bottom = 1 },
            },
        })({
            for (state.net_col_order) |col_idx| {
                const col: NetCol = @enumFromInt(col_idx);
                const is_dragged = if (state.net_drag.header_drag_started) if (state.net_drag.dragging_header) |dh| dh == col_idx else false else false;
                const alpha: f32 = if (is_dragged) 120 else 255;
                if (col == .proc_name) {
                    // Grow column
                    clay.UI()(.{
                        .id = clay.ElementId.IDI("nh", @intCast(col_idx)),
                        .layout = .{
                            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
                            .child_alignment = .{ .x = .left, .y = .center },
                        },
                    })({
                        clay.text(net_col_labels[col_idx], .{
                            .color = .{ theme.text_header[0], theme.text_header[1], theme.text_header[2], alpha },
                            .font_size = 14,
                        });
                    });
                } else {
                    // Resizable column with resize handle
                    const w = state.net_col_widths[col_idx];
                    clay.UI()(.{
                        .id = clay.ElementId.IDI("nh", @intCast(col_idx)),
                        .layout = .{
                            .sizing = .{ .w = clay.SizingAxis.fixed(w), .h = clay.SizingAxis.grow },
                            .child_alignment = .{ .x = .left, .y = .center },
                            .direction = .left_to_right,
                            .child_gap = 2,
                        },
                    })({
                        clay.text(net_col_labels[col_idx], .{
                            .color = .{ theme.text_header[0], theme.text_header[1], theme.text_header[2], alpha },
                            .font_size = 14,
                        });
                        // Spacer pushes resize handle to right edge
                        clay.UI()(.{
                            .id = clay.ElementId.IDI("nhs", @intCast(col_idx)),
                            .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow } },
                        })({});
                        // Resize handle — 3px separator bar
                        const rh_hovered = clay.pointerOver(clay.ElementId.IDI("nhr", @intCast(col_idx)));
                        const rh_alpha: f32 = if (rh_hovered) 200 else 80;
                        clay.UI()(.{
                            .id = clay.ElementId.IDI("nhr", @intCast(col_idx)),
                            .layout = .{
                                .sizing = .{ .w = clay.SizingAxis.fixed(3), .h = clay.SizingAxis.fixed(16) },
                            },
                            .background_color = .{ theme.separator[0], theme.separator[1], theme.separator[2], rh_alpha },
                            .corner_radius = clay.CornerRadius.all(1.5),
                        })({});
                    });
                }
            }

            // Drop indicator: floating accent line at the target drop position
            if (state.net_drag.header_drag_started) {
                const drop_x = column_ops.computeDropX(state.mouse_x, netColumnConfig());
                clay.UI()(.{
                    .id = clay.ElementId.ID("net-drop"),
                    .floating = .{
                        .attach_to = .to_parent,
                        .attach_points = .{ .element = .left_top, .parent = .left_top },
                        .offset = .{ .x = drop_x, .y = 0 },
                        .z_index = 50,
                        .pointer_capture_mode = .passthrough,
                    },
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.fixed(2), .h = clay.SizingAxis.fixed(28) },
                    },
                    .background_color = theme.accent,
                })({});
            }
        });

        // Scrollable connection rows
        clay.UI()(.{
            .id = clay.ElementId.ID("net-scroll"),
            .layout = .{
                .sizing = clay.Sizing.grow,
                .direction = .top_to_bottom,
            },
            .clip = .{ .vertical = true, .horizontal = true, .child_offset = clay.getScrollOffset() },
        })({
            if (state.connections.len == 0) {
                clay.UI()(.{
                    .id = clay.ElementId.ID("net-empty"),
                    .layout = .{
                        .sizing = clay.Sizing.grow,
                        .padding = clay.Padding.all(24),
                        .child_alignment = .{ .x = .center, .y = .center },
                    },
                })({
                    clay.text("No TCP connections", .{ .color = theme.text_dim, .font_size = 14 });
                });
            } else {
                for (state.connections, 0..) |conn, i| {
                    buildConnectionRow(alloc, conn, i);
                }
            }
        });
    });
}

fn buildNetToolbar(alloc: std.mem.Allocator) void {
    const dpi = sapp.dpiScale();
    const win_w = sapp.widthf() / dpi;

    clay.UI()(.{
        .id = clay.ElementId.ID("net-toolbar"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .offset = .{ .x = 0, .y = theme.header_height + theme.tab_bar_height },
            .z_index = 30,
        },
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(win_w), .h = clay.SizingAxis.fixed(NET_TOOLBAR_HEIGHT) },
            .padding = .{ .left = 14, .right = 14, .top = 4, .bottom = 4 },
            .child_alignment = .{ .x = .left, .y = .center },
            .direction = .left_to_right,
            .child_gap = 8,
        },
        .background_color = theme.bg,
    })({
        // Connection count
        const count_str = std.fmt.allocPrint(alloc, "{d} connection{s}", .{
            state.connections.len,
            if (state.connections.len == 1) "" else "s",
        }) catch "?";
        clay.text(count_str, .{ .color = theme.text_dim, .font_size = 12 });

        // Spacer pushes toggle to the right
        clay.UI()(.{
            .id = clay.ElementId.ID("tb-spacer"),
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow } },
        })({});

        // "Preserve" label
        clay.text("Preserve", .{ .color = theme.text_dim, .font_size = 12 });

        // Mac-style toggle switch
        buildToggle("toggle-preserve", state.toggle_anim_t);
    });
}

/// Mac-style toggle switch: 44x24 pill, 20x20 knob with smooth animation.
/// `t` is the animation progress (0.0 = off, 1.0 = on).
fn buildToggle(comptime id: []const u8, t: f32) void {
    const track_w: f32 = 44;
    const track_h: f32 = 24;
    const knob_size: f32 = 20;

    // Interpolate knob position: 2px (off) → 22px (on)
    const pad_left: u16 = @intFromFloat(2.0 + t * 20.0);
    const pad_right: u16 = 44 - 20 - pad_left; // track - knob - left = remaining right

    // Interpolate track color: bar_bg → accent
    const track_bg = clay.Color{
        lerpF(theme.bar_bg[0], theme.accent[0], t),
        lerpF(theme.bar_bg[1], theme.accent[1], t),
        lerpF(theme.bar_bg[2], theme.accent[2], t),
        255,
    };

    // Outer ring fades out as toggle turns on (simulates rounded border)
    const ring_alpha: f32 = (1.0 - t) * 255.0;
    const ring_color = clay.Color{ theme.separator[0], theme.separator[1], theme.separator[2], ring_alpha };

    // Outer pill (acts as rounded border ring)
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(track_w), .h = clay.SizingAxis.fixed(track_h) },
            .padding = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = ring_color,
        .corner_radius = clay.CornerRadius.all(track_h / 2.0),
    })({
        // Inner track
        clay.UI()(.{
            .id = clay.ElementId.ID(id ++ "-trk"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.fixed(track_w - 2), .h = clay.SizingAxis.fixed(track_h - 2) },
                .padding = .{ .left = pad_left, .right = pad_right, .top = 1, .bottom = 1 },
            },
            .background_color = track_bg,
            .corner_radius = clay.CornerRadius.all((track_h - 2) / 2.0),
        })({
            // Knob
            clay.UI()(.{
                .id = clay.ElementId.ID(id ++ "-knob"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.fixed(knob_size), .h = clay.SizingAxis.fixed(knob_size) },
                },
                .background_color = .{ 255, 255, 255, 255 },
                .corner_radius = clay.CornerRadius.all(knob_size / 2.0),
            })({});
        });
    });
}

fn lerpF(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

var conn_idx: u16 = 0;

fn buildConnectionRow(alloc: std.mem.Allocator, conn: process.TcpConnection, i: usize) void {
    const bg = if (i % 2 == 0) theme.row_even else theme.row_odd;

    const state_color = switch (conn.state) {
        .established => theme.accent,
        .listen => clay.Color{ 100, 200, 255, 255 },
        .close_wait, .fin_wait_1, .fin_wait_2, .closing, .time_wait, .last_ack => clay.Color{ 255, 200, 80, 255 },
        else => theme.text_dim,
    };

    const local_str = std.fmt.allocPrint(alloc, "{s}:{d}", .{ conn.localAddrStr(), conn.local_port }) catch "?";
    const remote_str = std.fmt.allocPrint(alloc, "{s}:{d}", .{ conn.remoteAddrStr(), conn.remote_port }) catch "?";
    const pid_str = std.fmt.allocPrint(alloc, "{d}", .{conn.pid}) catch "?";
    const proto: []const u8 = if (conn.is_ipv6) "TCP6" else "TCP4";
    const proc_name: []const u8 = state.conn_names.get(conn.pid) orelse "?";

    clay.UI()(.{
        .id = clay.ElementId.IDI("cr", @intCast(conn_idx)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(24) },
            .padding = .{ .left = 14, .right = 14, .top = 2, .bottom = 2 },
            .child_alignment = .{ .x = .left, .y = .center },
            .direction = .left_to_right,
        },
        .background_color = bg,
    })({
        // Data-driven column rendering via net_col_order
        for (state.net_col_order) |col_idx| {
            const col: NetCol = @enumFromInt(col_idx);
            switch (col) {
                .state_col => connCell("cs", state.net_col_widths[0], conn.state.label(), state_color),
                .local => connCell("cl", state.net_col_widths[1], local_str, theme.text_dim),
                .remote => connCell("cm", state.net_col_widths[2], remote_str, theme.text_dim),
                .pid_col => connCell("cp", state.net_col_widths[3], pid_str, theme.text_dim),
                .proto => connCell("cx", state.net_col_widths[4], proto, theme.text_dim),
                .proc_name => {
                    // Process name (grow to fill remaining space)
                    clay.UI()(.{
                        .id = clay.ElementId.IDI("cn", @intCast(conn_idx)),
                        .layout = .{
                            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
                            .child_alignment = .{ .x = .left, .y = .center },
                        },
                    })({
                        clay.text(proc_name, .{ .color = theme.text_primary, .font_size = 13 });
                    });
                },
            }
        }
    });

    conn_idx +%= 1;
}

fn connCell(comptime prefix: []const u8, width: f32, text_content: []const u8, color: clay.Color) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix, @intCast(conn_idx)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(text_content, .{ .color = color, .font_size = 13, .wrap_mode = .none });
    });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------


export fn cleanup() void {
    renderer.shutdown();
    if (state.clay_memory.len > 0) {
        std.heap.page_allocator.free(state.clay_memory);
    }
    // Free preserved connections if any
    if (state.preserved_conns.items.len > 0) {
        state.preserved_conns.clearAndFree(std.heap.page_allocator);
    }
    state.frame_arena.deinit();
    state.snapshot_arena.deinit();
    sg.shutdown();
}

/// Get the text of the currently active selectable cell (if any).
fn activeSelText() ?[]const u8 {
    const idx = state.active_cell_idx orelse return null;
    if (idx < selectable_count) return selectable_entries[idx].text;
    return null;
}

/// Copy the selected sub-range (or full value as fallback) to clipboard.
fn copySelection() void {
    const full_text = activeSelText() orelse return;
    if (state.value_select.selectedRange(full_text.len)) |r| {
        native_ui.clipboard_set_string(full_text[r.lo..r.hi].ptr, @intCast(r.hi - r.lo));
    } else {
        // No sub-range selected — copy entire value
        native_ui.clipboard_set_string(full_text.ptr, @intCast(full_text.len));
    }
}

export fn onEvent(ev: [*c]const sapp.Event) void {
    const e = ev.*;
    const dpi = sapp.dpiScale();
    switch (e.type) {
        .MOUSE_MOVE => {
            state.mouse_x = e.mouse_x / dpi;
            state.mouse_y = e.mouse_y / dpi;
            // Scrollbar drag takes priority
            if (scrollbar.isDragging()) {
                scrollbar.handleMouseMove(state.mouse_x, state.mouse_y);
            } else {
                // Handle value cell text selection drag
                if (state.value_select.dragging) {
                    // If mouse moved >8px vertically from drag start, cancel text selection
                    // and let Clay's scroll container handle it instead
                    const dy = @abs(state.mouse_y - state.drag_start_y);
                    if (dy > 8) {
                        state.value_select.clear();
                        state.active_cell_idx = null;
                    } else if (activeSelText()) |text| {
                        const char_pos = text_select.hitTestText(state.mouse_x, state.active_cell_x, text, 13);
                        state.value_select.updateDrag(char_pos);
                    }
                }
                // Handle column resize/reorder drag (network tab)
                state.net_drag.handleMouseMove(state.mouse_x, &state.net_col_widths);
            }
        },
        .MOUSE_DOWN => {
            if (e.mouse_button == .RIGHT) {
                // Right-click: copy selected text to clipboard
                copySelection();
            } else if (e.mouse_button == .LEFT) {
                state.mouse_x = e.mouse_x / dpi;
                state.mouse_y = e.mouse_y / dpi;

                // Scrollbar hit-test first
                if (scrollbar.handleMouseDown(state.mouse_x, state.mouse_y)) {
                    state.mouse_down = true;
                } else if (state.active_tab == .network) {
                    if (state.net_drag.handleMouseDown(state.mouse_x, state.mouse_y, netColumnConfig(), &state.net_col_widths)) {
                        state.mouse_down = true;
                    } else {
                        state.mouse_down = true;
                        state.mouse_clicked = true;
                    }
                } else {
                    state.mouse_down = true;
                    state.mouse_clicked = true;
                }
            }
        },
        .MOUSE_UP => {
            if (e.mouse_button == .LEFT) {
                // End scrollbar drag
                scrollbar.handleMouseUp();

                // End value cell text selection drag
                if (state.value_select.dragging) {
                    state.value_select.endDrag();
                }
                if (state.net_drag.handleMouseUp(state.mouse_x, netColumnConfig(), &state.net_col_order, NET_COL_COUNT)) {
                    state.mouse_clicked = true;
                }
                state.mouse_down = false;
            }
        },
        .MOUSE_SCROLL => {
            state.scroll_dx += e.scroll_x;
            state.scroll_dy += e.scroll_y;
        },
        .KEY_DOWN => {
            // Cmd+C: copy selected text to clipboard
            if (e.key_code == .C and (e.modifiers & sapp.modifier_super) != 0) {
                copySelection();
            }
        },
        else => {},
    }
}

pub fn main() void {
    const args = std.process.argsAlloc(std.heap.page_allocator) catch {
        print("procz-detail: failed to read args\n", .{});
        return;
    };
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 2) {
        print("Usage: procz-detail <pid>\n", .{});
        return;
    }

    state.target_pid = std.fmt.parseInt(process.pid_t, args[1], 10) catch {
        print("procz-detail: invalid PID: {s}\n", .{args[1]});
        return;
    };

    // Parse optional --theme <index>
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--theme") and i + 1 < args.len) {
            i += 1;
            const idx = std.fmt.parseInt(usize, args[i], 10) catch continue;
            theme.applyTheme(idx);
        }
    }

    // Build window title with em dash
    var title_buf: [128]u8 = undefined;
    const title_slice = std.fmt.bufPrint(&title_buf, "procz \xe2\x80\x94 PID {d}\x00", .{state.target_pid}) catch {
        sapp.run(.{
            .init_cb = init,
            .frame_cb = frame,
            .cleanup_cb = cleanup,
            .event_cb = onEvent,
            .width = 600,
            .height = 500,
            .high_dpi = true,
            .swap_interval = 4, // 30fps on 120Hz ProMotion, 15fps on 60Hz — detail window is mostly static
            .window_title = "procz-detail",
            .icon = .{ .sokol_default = true },
            .logger = .{ .func = slog.func },
        });
        return;
    };

    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = onEvent,
        .width = 600,
        .height = 500,
        .high_dpi = true,
        .swap_interval = 4, // 30fps on 120Hz ProMotion, 15fps on 60Hz — detail window is mostly static
        .window_title = title_slice.ptr,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
