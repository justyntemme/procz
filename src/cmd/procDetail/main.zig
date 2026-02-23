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

const DetailTab = enum { overview, network };

// Network column definitions
const NetCol = enum(u3) { state_col = 0, local = 1, remote = 2, pid_col = 3, proto = 4, proc_name = 5 };
const NET_COL_COUNT: u8 = 6;
const NET_RESIZABLE: u8 = 5; // proc_name grows (not resizable)
const net_default_widths = [NET_RESIZABLE]f32{ 80, 140, 140, 50, 42 };
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
    var net_dragging_col: ?u8 = null;
    var net_drag_start_x: f32 = 0;
    var net_drag_start_width: f32 = 0;
    var net_dragging_header: ?u8 = null;
    var net_header_drag_start_x: f32 = 0;
    var net_header_drag_started: bool = false;
    const header_drag_threshold: f32 = 5.0;

    // Preserve connections toggle
    var preserve_connections: bool = false;
    var preserved_conns: std.ArrayListUnmanaged(process.TcpConnection) = .empty;
    var preserved_names: std.AutoHashMapUnmanaged(process.pid_t, []const u8) = .empty;
};

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

    // Init Clay
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

    native_menu.setup_native_menu();
}

fn collectData() void {
    _ = state.snapshot_arena.reset(.retain_capacity);
    const alloc = state.snapshot_arena.allocator();
    state.proc_data = platform.collectProcess(alloc, state.target_pid);
    state.has_data = state.proc_data != null;

    // Coalition ID
    state.coalition_id = platform.getCoalitionId(state.target_pid);

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
        if (state.net_dragging_col != null) {
            sapp.setMouseCursor(.RESIZE_EW);
        } else if (state.net_header_drag_started) {
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

    const commands = buildLayout(frame_alloc);

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
}

fn buildLayout(alloc: std.mem.Allocator) []clay.RenderCommand {
    conn_idx = 0;
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
        buildTabItem("tab-overview", "Overview", state.active_tab == .overview);
        buildTabItem("tab-network", "Network", state.active_tab == .network);
    });
}

fn buildTabItem(comptime id: []const u8, label: []const u8, is_active: bool) void {
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

        if (is_active) {
            clay.UI()(.{
                .id = clay.ElementId.ID(id ++ "-ind"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(2) },
                },
                .background_color = theme.accent,
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
                    .child_alignment = .{ .y = .center },
                },
            })({
                // Label
                clay.UI()(.{
                    .id = clay.ElementId.IDI(id ++ "l", @intCast(i)),
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.fixed(140) },
                        .child_alignment = .{ .x = .left, .y = .center },
                    },
                })({
                    clay.text(item[0], .{ .color = theme.text_dim, .font_size = 13 });
                });
                // Value
                clay.UI()(.{
                    .id = clay.ElementId.IDI(id ++ "v", @intCast(i)),
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.grow },
                        .child_alignment = .{ .x = .left, .y = .center },
                    },
                })({
                    clay.text(item[1], .{ .color = theme.text_primary, .font_size = 13 });
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
                const is_dragged = if (state.net_header_drag_started) if (state.net_dragging_header) |dh| dh == col_idx else false else false;
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
            if (state.net_header_drag_started) {
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
            .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
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
        buildToggle("toggle-preserve", state.preserve_connections);
    });
}

/// Mac-style toggle switch: 44x24 pill, 20x20 knob.
/// Uses left-to-right layout with spacers to position the knob (no nested floats).
fn buildToggle(comptime id: []const u8, on: bool) void {
    const track_w: f32 = 44;
    const track_h: f32 = 24;
    const knob_size: f32 = 20;
    const track_bg = if (on) theme.accent else theme.bar_bg;
    const border_w: u16 = if (on) 0 else 1;
    const border_color = if (on) theme.transparent else theme.separator;

    // Padding positions the knob: OFF = 2px from left, ON = 22px from left
    const pad_left: u16 = if (on) 22 else 2;
    const pad_right: u16 = if (on) 2 else 22;

    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(track_w), .h = clay.SizingAxis.fixed(track_h) },
            .padding = .{ .left = pad_left, .right = pad_right, .top = 2, .bottom = 2 },
        },
        .background_color = track_bg,
        .corner_radius = clay.CornerRadius.all(track_h / 2.0),
        .border = .{
            .color = border_color,
            .width = .{ .left = border_w, .right = border_w, .top = border_w, .bottom = border_w },
        },
    })({
        // Knob — normal child, positioned by parent padding
        clay.UI()(.{
            .id = clay.ElementId.ID(id ++ "-knob"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.fixed(knob_size), .h = clay.SizingAxis.fixed(knob_size) },
            },
            .background_color = .{ 255, 255, 255, 255 },
            .corner_radius = clay.CornerRadius.all(knob_size / 2.0),
        })({});
    });
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
        clay.text(text_content, .{ .color = color, .font_size = 13 });
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

export fn onEvent(ev: [*c]const sapp.Event) void {
    const e = ev.*;
    const dpi = sapp.dpiScale();
    switch (e.type) {
        .MOUSE_MOVE => {
            state.mouse_x = e.mouse_x / dpi;
            state.mouse_y = e.mouse_y / dpi;
            // Handle column resize drag (network tab)
            if (state.net_dragging_col) |col_idx| {
                const delta = state.mouse_x - state.net_drag_start_x;
                // Cap so total fixed columns never exceed window width
                const dpi2 = sapp.dpiScale();
                const win_w = sapp.widthf() / dpi2;
                var other_total: f32 = 0;
                for (0..NET_RESIZABLE) |j| {
                    if (j != col_idx) other_total += state.net_col_widths[j];
                }
                // Reserve 28px padding + 60px minimum for grow column
                const max_w = @max(win_w - other_total - 28.0 - 60.0, 30.0);
                const new_width = @min(@max(state.net_drag_start_width + delta, 30.0), max_w);
                state.net_col_widths[col_idx] = new_width;
            }
            // Handle column header reorder drag threshold
            if (state.net_dragging_header != null and !state.net_header_drag_started) {
                if (@abs(state.mouse_x - state.net_header_drag_start_x) >= state.header_drag_threshold) {
                    state.net_header_drag_started = true;
                }
            }
        },
        .MOUSE_DOWN => {
            if (e.mouse_button == .LEFT) {
                state.mouse_x = e.mouse_x / dpi;
                state.mouse_y = e.mouse_y / dpi;

                if (state.active_tab == .network) {
                    const cfg = netColumnConfig();
                    // Check column resize edge first (highest priority)
                    if (column_ops.hitTestEdge(state.mouse_x, state.mouse_y, cfg)) |col_idx| {
                        state.net_dragging_col = col_idx;
                        state.net_drag_start_x = state.mouse_x;
                        state.net_drag_start_width = state.net_col_widths[col_idx];
                        state.mouse_down = true;
                    } else if (column_ops.hitTestHeader(state.mouse_x, state.mouse_y, cfg)) |col_idx| {
                        // Start potential column header drag
                        state.net_dragging_header = col_idx;
                        state.net_header_drag_start_x = state.mouse_x;
                        state.net_header_drag_started = false;
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
                if (state.net_header_drag_started) {
                    // Finalize column reorder
                    if (state.net_dragging_header) |src_col| {
                        const drop_pos = column_ops.findDropPos(state.mouse_x, netColumnConfig());
                        column_ops.reorder(&state.net_col_order, src_col, drop_pos, NET_COL_COUNT);
                    }
                } else if (state.net_dragging_header != null) {
                    // Threshold not met — treat as simple click
                    state.mouse_clicked = true;
                }
                state.net_dragging_header = null;
                state.net_header_drag_started = false;
                state.mouse_down = false;
                state.net_dragging_col = null;
            }
        },
        .MOUSE_SCROLL => {
            state.scroll_dx += e.scroll_x;
            state.scroll_dy += e.scroll_y;
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
        .window_title = title_slice.ptr,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
