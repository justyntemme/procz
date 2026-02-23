const std = @import("std");
const sokol = @import("sokol");
const clay = @import("zclay");
const platform = @import("platform");
const process = @import("process");
const renderer = @import("renderer");
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

const DetailTab = enum { overview, network };

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

    // TCP connections (owned by snapshot_arena)
    var connections: []process.TcpConnection = &.{};

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
};

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
    state.connections = filtered.toOwnedSlice(alloc) catch &.{};

    // Build PID → name map for connections
    state.conn_names = .empty;
    for (state.connections) |conn| {
        if (state.conn_names.contains(conn.pid)) continue;
        // Look up process name via platform
        if (platform.collectProcess(alloc, conn.pid)) |p| {
            state.conn_names.put(alloc, conn.pid, p.name) catch continue;
        }
    }

    state.last_refresh_ns = std.time.nanoTimestamp();
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
}

fn buildLayout(alloc: std.mem.Allocator) []clay.RenderCommand {
    label_idx = 0;
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
        })({
            clay.text(name, .{ .color = theme.text_title, .font_size = 18 });

            // PID badge
            clay.UI()(.{
                .id = clay.ElementId.ID("pid-badge"),
                .layout = .{
                    .padding = clay.Padding.axes(8, 3),
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = .{
                    theme.separator[0],
                    theme.separator[1],
                    theme.separator[2],
                    100,
                },
                .corner_radius = clay.CornerRadius.all(10),
            })({
                clay.text(pid_str, .{ .color = theme.text_dim, .font_size = 12 });
            });
        });

        // Tab bar
        buildTabBar();

        // Tab content
        switch (state.active_tab) {
            .overview => buildOverviewTab(alloc, proc_opt),
            .network => buildNetworkTab(alloc),
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
        })({
            clay.text("procz-detail", .{ .color = theme.text_footer, .font_size = 13 });
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

        if (is_active) {
            clay.UI()(.{
                .id = clay.ElementId.ID(id ++ "-ind"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(2) },
                },
                .background_color = theme.accent,
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
            .padding = clay.Padding.all(24),
            .child_gap = 16,
        },
        .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
        .background_color = theme.bg,
    })({
        if (proc_opt) |p| {
            const path = if (p.path.len > 0) p.path else "(unknown path)";
            labelValue(alloc, "Path", path);

            const mem_mb = p.mem_rss / (1024 * 1024);
            const mem_str = if (mem_mb > 0)
                std.fmt.allocPrint(alloc, "{d} MB", .{mem_mb}) catch "?"
            else
                std.fmt.allocPrint(alloc, "{d} KB", .{p.mem_rss / 1024}) catch "?";
            labelValue(alloc, "Memory (RSS)", mem_str);

            const phys_mb = p.mem_phys / (1024 * 1024);
            const phys_str = if (phys_mb > 0)
                std.fmt.allocPrint(alloc, "{d} MB", .{phys_mb}) catch "?"
            else
                std.fmt.allocPrint(alloc, "{d} KB", .{p.mem_phys / 1024}) catch "?";
            labelValue(alloc, "Physical Footprint", phys_str);

            const total_ns = p.total_user + p.total_system;
            const total_secs = total_ns / std.time.ns_per_s;
            const cpu_str = if (total_secs >= 3600)
                std.fmt.allocPrint(alloc, "{d}h {d}m {d}s", .{ total_secs / 3600, (total_secs % 3600) / 60, total_secs % 60 }) catch "?"
            else if (total_secs >= 60)
                std.fmt.allocPrint(alloc, "{d}m {d}s", .{ total_secs / 60, total_secs % 60 }) catch "?"
            else
                std.fmt.allocPrint(alloc, "{d}s", .{total_secs}) catch "?";
            labelValue(alloc, "CPU Time", cpu_str);

            const disk_read_mb = p.diskio_bytes_read / (1024 * 1024);
            const disk_write_mb = p.diskio_bytes_written / (1024 * 1024);
            const disk_str = std.fmt.allocPrint(alloc, "Read: {d} MB  Write: {d} MB", .{ disk_read_mb, disk_write_mb }) catch "?";
            labelValue(alloc, "Disk I/O", disk_str);

            const state_str: []const u8 = switch (p.state) {
                .running => "Running",
                .sleeping => "Sleeping",
                .stopped => "Stopped",
                .zombie => "Zombie",
                .unknown => "Unknown",
            };
            labelValue(alloc, "State", state_str);

            const ppid_str = std.fmt.allocPrint(alloc, "{d}", .{p.ppid}) catch "?";
            labelValue(alloc, "Parent PID", ppid_str);

            if (state.coalition_id > 0) {
                const coal_str = std.fmt.allocPrint(alloc, "{d}", .{state.coalition_id}) catch "?";
                labelValue(alloc, "Coalition ID", coal_str);
            }
        } else {
            clay.text("Process not accessible. May require entitlements.", .{
                .color = theme.text_dim,
                .font_size = 14,
            });
            clay.text("Run with: zig build sign-run -Didentity=...", .{
                .color = theme.text_footer,
                .font_size = 12,
            });
        }
    });
}

// ---------------------------------------------------------------------------
// Network tab
// ---------------------------------------------------------------------------

fn buildNetworkTab(alloc: std.mem.Allocator) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("net-content"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
        },
        .background_color = theme.bg,
    })({
        // Column header
        clay.UI()(.{
            .id = clay.ElementId.ID("net-hdr"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(28) },
                .padding = clay.Padding.axes(6, 14),
                .child_alignment = .{ .x = .left, .y = .center },
                .direction = .left_to_right,
            },
            .background_color = theme.col_header_bg,
        })({
            netHeaderCell("nh-state", 80, "STATE");
            netHeaderCell("nh-local", 140, "LOCAL");
            netHeaderCell("nh-remote", 140, "REMOTE");
            netHeaderCell("nh-pid", 50, "PID");
            netHeaderCell("nh-proto", 42, "PROTO");

            clay.UI()(.{
                .id = clay.ElementId.ID("nh-proc"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
                    .child_alignment = .{ .x = .left, .y = .center },
                },
            })({
                clay.text("PROCESS", .{ .color = theme.text_header, .font_size = 14 });
            });
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
                const count_str = std.fmt.allocPrint(alloc, "{d} connection{s}", .{
                    state.connections.len,
                    if (state.connections.len == 1) "" else "s",
                }) catch "?";
                clay.UI()(.{
                    .id = clay.ElementId.ID("net-count"),
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(24) },
                        .padding = .{ .left = 14, .right = 14, .top = 4, .bottom = 4 },
                        .child_alignment = .{ .x = .left, .y = .center },
                    },
                })({
                    clay.text(count_str, .{ .color = theme.text_dim, .font_size = 12 });
                });

                for (state.connections, 0..) |conn, i| {
                    buildConnectionRow(alloc, conn, i);
                }
            }
        });
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
        connCell("cs", 80, conn.state.label(), state_color);
        connCell("cl", 140, local_str, theme.text_dim);
        connCell("cm", 140, remote_str, theme.text_dim);
        connCell("cp", 50, pid_str, theme.text_dim);
        connCell("cx", 42, proto, theme.text_dim);

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

fn netHeaderCell(comptime id: []const u8, width: f32, label: []const u8) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(label, .{ .color = theme.text_header, .font_size = 14 });
    });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

var label_idx: u16 = 0;

fn labelValue(alloc: std.mem.Allocator, label: []const u8, value: []const u8) void {
    _ = alloc;
    clay.UI()(.{
        .id = clay.ElementId.IDI("lv", label_idx),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow },
            .direction = .top_to_bottom,
            .child_gap = 2,
        },
    })({
        clay.text(label, .{ .color = theme.text_header, .font_size = 13 });
        clay.text(value, .{ .color = theme.text_primary, .font_size = 14 });
    });
    label_idx +%= 1;
}

export fn cleanup() void {
    renderer.shutdown();
    if (state.clay_memory.len > 0) {
        std.heap.page_allocator.free(state.clay_memory);
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
        },
        .MOUSE_DOWN => {
            if (e.mouse_button == .LEFT) {
                state.mouse_x = e.mouse_x / dpi;
                state.mouse_y = e.mouse_y / dpi;
                state.mouse_down = true;
                state.mouse_clicked = true;
            }
        },
        .MOUSE_UP => {
            if (e.mouse_button == .LEFT) {
                state.mouse_down = false;
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
