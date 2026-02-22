const std = @import("std");
const sokol = @import("sokol");
const clay = @import("zclay");
const platform = @import("platform");
const process = @import("process");
const renderer = @import("renderer");
const font = @import("font");
const theme = @import("theme");

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
    var clay_memory: []u8 = &.{};

    // Target PID (from command line)
    var target_pid: process.pid_t = 0;

    // Collected process data (owned by snapshot_arena)
    var proc_data: ?process.Proc = null;
    var has_data: bool = false;

    // Input state
    var mouse_x: f32 = 0;
    var mouse_y: f32 = 0;
    var mouse_down: bool = false;
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
}

fn clayErrorHandler(err: clay.ErrorData) callconv(.c) void {
    print("clay error: {s}\n", .{err.error_text.chars[0..@intCast(err.error_text.length)]});
}

export fn frame() void {
    _ = state.frame_arena.reset(.retain_capacity);
    const frame_alloc = state.frame_arena.allocator();

    const dpi = sapp.dpiScale();
    clay.setLayoutDimensions(.{
        .w = sapp.widthf() / dpi,
        .h = sapp.heightf() / dpi,
    });
    clay.setPointerState(.{ .x = state.mouse_x, .y = state.mouse_y }, state.mouse_down);

    // Update clear color to match theme
    state.pass_action.colors[0].clear_value = .{
        .r = @as(f32, theme.bg[0]) / 255.0,
        .g = @as(f32, theme.bg[1]) / 255.0,
        .b = @as(f32, theme.bg[2]) / 255.0,
        .a = 1.0,
    };

    const commands = buildLayout(frame_alloc);

    sg.beginPass(.{
        .action = state.pass_action,
        .swapchain = sglue.swapchain(),
    });
    renderer.render(commands);
    sg.endPass();
    sg.commit();
}

fn buildLayout(alloc: std.mem.Allocator) []clay.RenderCommand {
    label_idx = 0;
    clay.beginLayout();

    const proc = state.proc_data;
    const name = if (proc) |p| p.name else "(process not accessible)";
    const path = if (proc) |p| (if (p.path.len > 0) p.path else "(unknown path)") else "";
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

        // Content
        clay.UI()(.{
            .id = clay.ElementId.ID("content"),
            .layout = .{
                .sizing = clay.Sizing.grow,
                .direction = .top_to_bottom,
                .padding = clay.Padding.all(24),
                .child_gap = 16,
            },
            .background_color = theme.bg,
        })({
            if (proc) |p| {
                // Path section
                labelValue(alloc, "Path", path);

                // Memory
                const mem_mb = p.mem_rss / (1024 * 1024);
                const mem_str = if (mem_mb > 0)
                    std.fmt.allocPrint(alloc, "{d} MB", .{mem_mb}) catch "?"
                else
                    std.fmt.allocPrint(alloc, "{d} KB", .{p.mem_rss / 1024}) catch "?";
                labelValue(alloc, "Memory (RSS)", mem_str);

                // Physical footprint
                const phys_mb = p.mem_phys / (1024 * 1024);
                const phys_str = if (phys_mb > 0)
                    std.fmt.allocPrint(alloc, "{d} MB", .{phys_mb}) catch "?"
                else
                    std.fmt.allocPrint(alloc, "{d} KB", .{p.mem_phys / 1024}) catch "?";
                labelValue(alloc, "Physical Footprint", phys_str);

                // CPU time
                const total_ns = p.total_user + p.total_system;
                const total_secs = total_ns / std.time.ns_per_s;
                const cpu_str = if (total_secs >= 3600)
                    std.fmt.allocPrint(alloc, "{d}h {d}m {d}s", .{ total_secs / 3600, (total_secs % 3600) / 60, total_secs % 60 }) catch "?"
                else if (total_secs >= 60)
                    std.fmt.allocPrint(alloc, "{d}m {d}s", .{ total_secs / 60, total_secs % 60 }) catch "?"
                else
                    std.fmt.allocPrint(alloc, "{d}s", .{total_secs}) catch "?";
                labelValue(alloc, "CPU Time", cpu_str);

                // Disk I/O
                const disk_read_mb = p.diskio_bytes_read / (1024 * 1024);
                const disk_write_mb = p.diskio_bytes_written / (1024 * 1024);
                const disk_str = std.fmt.allocPrint(alloc, "Read: {d} MB  Write: {d} MB", .{ disk_read_mb, disk_write_mb }) catch "?";
                labelValue(alloc, "Disk I/O", disk_str);

                // State
                const state_str: []const u8 = switch (p.state) {
                    .running => "Running",
                    .sleeping => "Sleeping",
                    .stopped => "Stopped",
                    .zombie => "Zombie",
                    .unknown => "Unknown",
                };
                labelValue(alloc, "State", state_str);

                // PPID
                const ppid_str = std.fmt.allocPrint(alloc, "{d}", .{p.ppid}) catch "?";
                labelValue(alloc, "Parent PID", ppid_str);
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
            }
        },
        .MOUSE_UP => {
            if (e.mouse_button == .LEFT) {
                state.mouse_down = false;
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

    // Build window title with em dash
    var title_buf: [128]u8 = undefined;
    const title_slice = std.fmt.bufPrint(&title_buf, "procz \xe2\x80\x94 PID {d}\x00", .{state.target_pid}) catch {
        sapp.run(.{
            .init_cb = init,
            .frame_cb = frame,
            .cleanup_cb = cleanup,
            .event_cb = onEvent,
            .width = 480,
            .height = 420,
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
        .width = 480,
        .height = 420,
        .high_dpi = true,
        .window_title = title_slice.ptr,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
