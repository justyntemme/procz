const std = @import("std");
const clay = @import("zclay");
const theme = @import("theme");
const column_ops = @import("column_ops");
const process = @import("process");

// ---------------------------------------------------------------------------
// Public types consumed by main.zig
// ---------------------------------------------------------------------------

pub const TopEntry = struct {
    name: []const u8 = "",
    value: u64 = 0,
    value_str: []const u8 = "",
};

pub const MAX_CORES: usize = 128;

pub const SystemSummary = struct {
    total_rss: u64 = 0,
    total_rss_str: []const u8 = "0K",
    proc_count: usize = 0,
    top_cpu: [5]TopEntry = [_]TopEntry{.{}} ** 5,
    top_cpu_count: u8 = 0,
    top_mem: [5]TopEntry = [_]TopEntry{.{}} ** 5,
    top_mem_count: u8 = 0,
    top_disk: [5]TopEntry = [_]TopEntry{.{}} ** 5,
    top_disk_count: u8 = 0,
    // Pre-formatted strings (allocated by frame arena, safe for Clay to reference)
    header_stats_str: []const u8 = "",
    mem_title_str: []const u8 = "Memory",
    // Per-core CPU utilization (0.0–1.0)
    core_utils: [MAX_CORES]f32 = [_]f32{0} ** MAX_CORES,
    core_count: u32 = 0,
};

pub const RowText = struct {
    pid_str: []const u8,
    name_prefix: []const u8,
    name: []const u8,
    cpu_str: []const u8,
    mem_str: []const u8,
    disk_str: []const u8,
    gpu_str: []const u8 = "",
    path_str: []const u8,
    full_path: []const u8,
    depth: u16,
    cpu_intensity: f32 = 0,
    mem_intensity: f32 = 0,
    disk_intensity: f32 = 0,
    gpu_intensity: f32 = 0,
    // Raw values for sorting
    raw_cpu: u64 = 0,
    raw_mem: u64 = 0,
    raw_disk: u64 = 0,
    raw_gpu: u64 = 0,
    pid: i32 = 0,
    // Tree disclosure triangle state
    is_parent: bool = false,
    is_expanded: bool = true,
    // Search: true if this row directly matches, false if it's an ancestor shown for context
    search_match: bool = true,
};

pub const SortColumn = enum {
    none,
    name,
    cpu,
    mem,
    disk,
    gpu,
};

pub const SortDirection = enum {
    ascending,
    descending,
};

pub const ActiveTab = enum { processes, network, performance, startup };

/// Logical column indices
pub const Col = enum(u3) {
    pid = 0,
    name = 1,
    cpu = 2,
    mem = 3,
    disk = 4,
    gpu = 5,
    path = 6,
};

pub const COL_COUNT = 7;
pub const default_col_order: [COL_COUNT]u8 = .{ 0, 1, 2, 3, 4, 5, 6 };
const proc_col_labels = [COL_COUNT][]const u8{ "PID", "NAME", "CPU", "MEM", "DISK", "GPU", "PATH" };
const proc_sort_map = [COL_COUNT]SortColumn{ .none, .name, .cpu, .mem, .disk, .none, .none };

/// Startup tab logical column indices
pub const SuCol = enum(u3) {
    label = 0,
    program = 1,
    status = 2,
    at_load = 3,
    keep_alive = 4,
    su_type = 5,
};

pub const SU_COL_COUNT = 6;
pub const default_su_col_order: [SU_COL_COUNT]u8 = .{ 0, 2, 3, 4, 5, 1 };
const su_col_labels = [SU_COL_COUNT][]const u8{ "LABEL", "PROGRAM", "STATUS", "AT LOAD", "KEEP ALIVE", "TYPE" };
const su_sort_map = [SU_COL_COUNT]SortColumn{ .none, .none, .none, .none, .none, .none };

/// Network tab logical column indices (main window)
pub const NetCol = enum(u3) { state_col = 0, local = 1, remote = 2, pid_col = 3, proto = 4, proc_name = 5 };
pub const NET_COL_COUNT: u8 = 6;
pub const NET_RESIZABLE: u8 = 5; // proc_name grows (not resizable)
pub const net_default_widths = [NET_RESIZABLE]f32{ 90, 220, 220, 60, 50 };
pub const default_net_col_order: [NET_COL_COUNT]u8 = .{ 0, 1, 2, 3, 4, 5 };
const net_col_labels = [NET_COL_COUNT][]const u8{ "STATE", "LOCAL", "REMOTE", "PID", "PROTO", "PROCESS" };

/// Generic column header bar configuration (used by both tabs).
const ColumnHeaderDef = struct {
    col_widths: []const f32,
    col_order: []const u8,
    col_count: u8,
    grow_col_idx: u8,
    col_labels: []const []const u8,
    sort_map: []const SortColumn,
    dragging_header: ?u8,
    drag_header_x: f32,
    viewport_width: f32,
};

pub const InteractionState = struct {
    is_selected: []const bool, // parallel to row_texts
    hovered_index: ?usize,
    sort_column: SortColumn = .none,
    sort_direction: SortDirection = .descending,
    col_widths: [6]f32 = .{ theme.col_pid, theme.col_name, theme.col_cpu, theme.col_mem, theme.col_disk, theme.col_gpu },
    col_order: [COL_COUNT]u8 = default_col_order, // display position → logical column index
    dragging_header: ?u8 = null, // logical column index being dragged for reorder
    drag_header_x: f32 = 0, // current mouse x during header drag
    search_text: []const u8 = "",
    search_focused: bool = false,
    cursor_visible: bool = true,
    cursor_pos: usize = 0,
    selection_start: ?usize = null, // anchor for text selection (null = no selection)
    active_tab: ActiveTab = .processes,
    tab_anim: f32 = 0.0, // tab indicator cross-fade (0=processes, 1=performance)
    search_width_anim: f32 = 200.0, // animated search bar width
    sort_anim: f32 = 0.0, // sort indicator opacity (0→1)
    hover_anim: f32 = 0.0, // hover row highlight blend (0→1)
    hover_anim_index: ?usize = null, // row with active hover animation
    row_flash: []const f32 = &.{}, // parallel to row_texts — new-process flash intensity
    viewport_height: f32 = 600,
    viewport_width: f32 = 1024,
    scroll_y: f32 = 0, // pre-fetched scroll offset for processes tab virtualization
    startup_scroll_y: f32 = 0, // pre-fetched scroll offset for startup tab virtualization
    startup_items: []const process.StartupItem = &.{},

    // Startup tab column state
    su_col_widths: [SU_COL_COUNT]f32 = .{ 240, 0, 80, 80, 80, 70 }, // indexed by logical col: label(0), program(1=grow/unused), status(2), at_load(3), keep_alive(4), type(5)
    su_col_order: [SU_COL_COUNT]u8 = default_su_col_order,
    su_dragging_header: ?u8 = null,
    su_drag_header_x: f32 = 0,

    // Network tab state
    net_col_widths: [NET_RESIZABLE]f32 = net_default_widths,
    net_col_order: [NET_COL_COUNT]u8 = default_net_col_order,
    net_dragging_header: ?u8 = null,
    net_drag_header_x: f32 = 0,
    net_scroll_y: f32 = 0,
    connections: []const process.TcpConnection = &.{},
    conn_names: ?*const std.AutoHashMapUnmanaged(process.pid_t, []const u8) = null,
    frame_alloc: ?std.mem.Allocator = null,

    // Network stats panel strings (formatted by main.zig each snapshot)
    net_packets_in_str: []const u8 = "0",
    net_packets_out_str: []const u8 = "0",
    net_packets_in_rate_str: []const u8 = "0/s",
    net_packets_out_rate_str: []const u8 = "0/s",
    net_bytes_in_str: []const u8 = "0 B",
    net_bytes_out_str: []const u8 = "0 B",
    net_bytes_in_rate_str: []const u8 = "0 B/s",
    net_bytes_out_rate_str: []const u8 = "0 B/s",
    net_chart_mode: u8 = 0, // 0 = packets, 1 = data
};

pub const MenuState = struct {
    settings_open: bool = false,
    settings_anim: f32 = 0.0, // popup fade (0=hidden, 1=visible)
};


// ---------------------------------------------------------------------------
// Layout entry point
// ---------------------------------------------------------------------------

pub fn buildLayout(row_texts: []const RowText, summary: SystemSummary, interaction: InteractionState, menu: MenuState) []clay.RenderCommand {
    net_row_idx = 0;
    clay.beginLayout();

    // Root container
    clay.UI()(.{
        .id = clay.ElementId.ID("root"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
        },
        .background_color = theme.bg,
    })({
        buildHeader(summary, menu, interaction);
        buildTabBar(interaction);

        // Tab content area
        switch (interaction.active_tab) {
            .processes => buildProcessesTab(row_texts, summary, interaction),
            .network => buildNetworkTab(interaction),
            .performance => buildPerformanceTab(summary),
            .startup => buildStartupTab(interaction),
        }

        buildFooter();

        // Settings popup (floating, high z-index, animated)
        if (menu.settings_anim > 0.01) {
            buildSettingsPopup(menu.settings_anim);
        }
    });

    return clay.endLayout();
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

fn buildHeader(summary: SystemSummary, menu: MenuState, interaction: InteractionState) void {
    _ = menu;
    clay.UI()(.{
        .id = clay.ElementId.ID("header"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.header_height) },
            .padding = clay.Padding.axes(14, 16),
            .child_alignment = .{ .x = .left, .y = .center },
            .direction = .left_to_right,
            .child_gap = 12,
        },
        .background_color = theme.header_bg,
        .border = .{
            .color = theme.separator,
            .width = .{ .bottom = 1 },
        },
    })({
        clay.text("procz", .{ .color = theme.text_title, .font_size = 18 });

        if (interaction.active_tab != .performance and interaction.active_tab != .network) {
            buildSearchBar(interaction);
        }

        // Spacer pushes stats to the right
        clay.UI()(.{
            .id = clay.ElementId.ID("hdr-sp"),
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow } },
        })({});

        clay.text(summary.header_stats_str, .{ .color = theme.text_dim, .font_size = 14 });
    });
}

fn buildSearchBar(interaction: InteractionState) void {
    // Safari-inspired capsule search field:
    // - No border when unfocused, subtle fill contrast only
    // - Thin accent ring on focus
    // - Full pill radius (height/2)
    // - Widens on focus for more typing room
    const focused = interaction.search_focused;
    const has_text = interaction.search_text.len > 0;
    const field_w: f32 = interaction.search_width_anim;
    const field_h: f32 = 28;
    const pill_radius = field_h / 2.0;

    // Background: subtle tertiary fill when idle, brighter when focused
    const bg_color = if (focused) theme.row_even else blk: {
        // Approximate macOS tertiarySystemFill: slight contrast over header_bg
        break :blk clay.Color{
            @min(theme.header_bg[0] + 8, 255),
            @min(theme.header_bg[1] + 8, 255),
            @min(theme.header_bg[2] + 8, 255),
            255,
        };
    };

    // Border: none when unfocused (Apple minimal chrome), accent ring on focus
    const border_w: u16 = if (focused) 1 else 0;
    const border_color = if (focused) theme.accent else theme.transparent;

    clay.UI()(.{
        .id = clay.ElementId.ID("search-bar"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(field_w), .h = clay.SizingAxis.fixed(field_h) },
            .padding = clay.Padding.axes(12, 5),
            .child_alignment = .{ .x = .left, .y = .center },
            .direction = .left_to_right,
            .child_gap = 6,
        },
        .background_color = bg_color,
        .corner_radius = clay.CornerRadius.all(pill_radius),
        .border = .{
            .color = border_color,
            .width = .{ .left = border_w, .right = border_w, .top = border_w, .bottom = border_w },
        },
    })({
        // Magnifying glass icon (always visible, dim)
        // U+2315 TELEPHONE RECORDER is close; use simple text approach
        clay.text("\xe2\x8c\x98", .{
            .color = if (focused) theme.text_dim else theme.text_footer,
            .font_size = 12,
        });

        if (!has_text and !focused) {
            // Placeholder: "Filter" in placeholderText color
            clay.text("Filter", .{ .color = theme.text_footer, .font_size = 14 });
        } else if (!has_text and focused) {
            // Focused but empty: blinking cursor at left edge
            // Thin rectangle cursor — no font spacing gap like "|" text would have
            clay.UI()(.{
                .id = clay.ElementId.ID("search-inner"),
                .layout = .{ .direction = .left_to_right, .child_gap = 0 },
            })({
                const cursor_a: f32 = if (interaction.cursor_visible) theme.accent[3] else 0;
                clay.UI()(.{
                    .id = clay.ElementId.ID("cursor-bar"),
                    .layout = .{ .sizing = .{ .w = clay.SizingAxis.fixed(1.5), .h = clay.SizingAxis.fixed(16) } },
                    .background_color = .{ theme.accent[0], theme.accent[1], theme.accent[2], cursor_a },
                    .corner_radius = clay.CornerRadius.all(0.75),
                })({});
            });
        } else {
            // Has text: show typed content with cursor/selection
            const pos = @min(interaction.cursor_pos, interaction.search_text.len);
            const has_sel = if (interaction.selection_start) |ss| @min(ss, interaction.search_text.len) != pos else false;

            clay.UI()(.{
                .id = clay.ElementId.ID("search-txt"),
                .layout = .{ .direction = .left_to_right, .child_gap = 0 },
            })({
                if (has_sel) {
                    const ss = @min(interaction.selection_start.?, interaction.search_text.len);
                    const sel_lo = @min(ss, pos);
                    const sel_hi = @max(ss, pos);
                    if (sel_lo > 0) {
                        clay.text(interaction.search_text[0..sel_lo], .{ .color = theme.text_primary, .font_size = 14 });
                    }
                    // Selection highlight
                    clay.UI()(.{
                        .id = clay.ElementId.ID("search-sel"),
                        .layout = .{ .child_gap = 0 },
                        .background_color = .{ theme.accent[0], theme.accent[1], theme.accent[2], 100 },
                        .corner_radius = clay.CornerRadius.all(2),
                    })({
                        clay.text(interaction.search_text[sel_lo..sel_hi], .{ .color = theme.text_primary, .font_size = 14 });
                    });
                    if (sel_hi < interaction.search_text.len) {
                        clay.text(interaction.search_text[sel_hi..], .{ .color = theme.text_primary, .font_size = 14 });
                    }
                } else {
                    // No selection — show thin rectangle cursor at position
                    if (pos > 0) {
                        clay.text(interaction.search_text[0..pos], .{ .color = theme.text_primary, .font_size = 14 });
                    }
                    if (focused) {
                        const cursor_a: f32 = if (interaction.cursor_visible) theme.accent[3] else 0;
                        clay.UI()(.{
                            .id = clay.ElementId.ID("cursor-bar2"),
                            .layout = .{ .sizing = .{ .w = clay.SizingAxis.fixed(1.5), .h = clay.SizingAxis.fixed(16) } },
                            .background_color = .{ theme.accent[0], theme.accent[1], theme.accent[2], cursor_a },
                            .corner_radius = clay.CornerRadius.all(0.75),
                        })({});
                    }
                    if (pos < interaction.search_text.len) {
                        clay.text(interaction.search_text[pos..], .{ .color = theme.text_primary, .font_size = 14 });
                    }
                }
            });
        }
    });
}

// ---------------------------------------------------------------------------
// Tab bar — horizontal row above content (classic Task Manager style)
// ---------------------------------------------------------------------------

fn buildTabBar(interaction: InteractionState) void {
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
        buildTabItem("tab-processes", "Processes", interaction.active_tab == .processes, @max(0, 1.0 - @abs(interaction.tab_anim - 0.0)));
        buildTabItem("tab-network", "Network", interaction.active_tab == .network, @max(0, 1.0 - @abs(interaction.tab_anim - 1.0)));
        buildTabItem("tab-perf", "Performance", interaction.active_tab == .performance, @max(0, 1.0 - @abs(interaction.tab_anim - 2.0)));
        buildTabItem("tab-startup", "Startup", interaction.active_tab == .startup, @max(0, 1.0 - @abs(interaction.tab_anim - 3.0)));
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

        // Active indicator: 2px accent bar at bottom edge (cross-fade animated)
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
// Processes tab — full-width process table + CPU cores
// ---------------------------------------------------------------------------

fn buildProcessesTab(row_texts: []const RowText, summary: SystemSummary, interaction: InteractionState) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("processes-content"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
        },
    })({
        // Column headers (generic bar used by both tabs)
        buildColumnHeaderBar("ch", .{
            .col_widths = &interaction.col_widths,
            .col_order = &interaction.col_order,
            .col_count = COL_COUNT,
            .grow_col_idx = @intFromEnum(Col.path),
            .col_labels = &proc_col_labels,
            .sort_map = &proc_sort_map,
            .dragging_header = interaction.dragging_header,
            .drag_header_x = interaction.drag_header_x,
            .viewport_width = interaction.viewport_width,
        }, interaction);

        // Scrollable row area (virtualized — only visible rows are built)
        // scroll_y is pre-fetched via getScrollContainerData in frame()
        // (getScrollOffset must be called inline with clip config, after clay.UI() opens the element)
        const scroll_y: f32 = interaction.scroll_y;
        const viewport_h = interaction.viewport_height;
        const total_rows: usize = row_texts.len;
        const total_content_h = @as(f32, @floatFromInt(total_rows)) * theme.row_height;

        // Visible row range with buffer
        const first_visible: usize = if (scroll_y > 0)
            @min(@as(usize, @intFromFloat(scroll_y / theme.row_height)), total_rows)
        else
            0;
        const visible_count: usize = @as(usize, @intFromFloat(viewport_h / theme.row_height)) + 4; // 2 row buffer each side
        const first_row = if (first_visible >= 2) first_visible - 2 else 0;
        const last_row = @min(first_row + visible_count, total_rows);

        // Top spacer (height of all rows above the visible window)
        const top_spacer_h = @as(f32, @floatFromInt(first_row)) * theme.row_height;
        // Bottom spacer (height of all rows below the visible window)
        const bottom_spacer_h = @as(f32, @floatFromInt(total_rows - last_row)) * theme.row_height;

        clay.UI()(.{
            .id = clay.ElementId.ID("scroll"),
            .layout = .{
                .sizing = clay.Sizing.grow,
                .direction = .top_to_bottom,
            },
            .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
        })({
            // Top spacer — represents rows above the visible window
            if (top_spacer_h > 0) {
                clay.UI()(.{
                    .id = clay.ElementId.ID("v-top"),
                    .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(top_spacer_h) } },
                })({});
            }

            // Only build Clay elements for visible rows
            for (row_texts[first_row..last_row], first_row..last_row) |row, i| {
                const is_selected = if (i < interaction.is_selected.len) interaction.is_selected[i] else false;
                const is_hovered = if (interaction.hovered_index) |hi| hi == i else false;
                const base_bg = if (is_selected) theme.row_selected else if (i % 2 == 0) theme.row_even else theme.row_odd;
                const with_hover = if (!is_selected and is_hovered) blendColor(base_bg, theme.row_hover, interaction.hover_anim) else base_bg;
                const flash_t: f32 = if (i < interaction.row_flash.len) interaction.row_flash[i] else 0;
                const bg_color = if (flash_t > 0.01) blendColor(with_hover, .{ theme.accent[0], theme.accent[1], theme.accent[2], 255 }, flash_t * 0.25) else with_hover;

                // Dim ancestor-only rows during search (not direct matches)
                const is_ancestor_only = !row.search_match;
                const dim_text = if (is_ancestor_only) clay.Color{
                    theme.text_dim[0], theme.text_dim[1], theme.text_dim[2], 100,
                } else theme.text_dim;

                clay.UI()(.{
                    .id = clay.ElementId.IDI("row", @intCast(i)),
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.row_height) },
                        .padding = .{ .left = 14, .right = 14, .top = 3, .bottom = 3 },
                        .child_alignment = .{ .x = .left, .y = .center },
                        .direction = .left_to_right,
                    },
                    .background_color = bg_color,
                })({
                    const i_scale: f32 = if (is_selected) 0.3 else if (is_ancestor_only) 0.0 else 1.0;
                    for (interaction.col_order) |col_idx| {
                        const col: Col = @enumFromInt(col_idx);
                        switch (col) {
                            .pid => cell("pid", i, interaction.col_widths[0], row.pid_str, dim_text),
                            .name => nameCellDyn(i, row, interaction.col_widths[1]),
                            .cpu => intensityCell("cpu", i, interaction.col_widths[2], row.cpu_str, dim_text, theme.intensity_tint, row.cpu_intensity * i_scale, bg_color),
                            .mem => intensityCell("mem", i, interaction.col_widths[3], row.mem_str, dim_text, theme.intensity_tint, row.mem_intensity * i_scale, bg_color),
                            .disk => intensityCell("dsk", i, interaction.col_widths[4], row.disk_str, dim_text, theme.intensity_tint, row.disk_intensity * i_scale, bg_color),
                            .gpu => intensityCell("gpu", i, interaction.col_widths[5], row.gpu_str, dim_text, theme.intensity_tint, row.gpu_intensity * i_scale, bg_color),
                            .path => pathCell(i, row),
                        }
                    }
                });
            }

            // Bottom spacer — represents rows below the visible window
            if (bottom_spacer_h > 0) {
                clay.UI()(.{
                    .id = clay.ElementId.ID("v-bot"),
                    .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(bottom_spacer_h) } },
                })({});
            }
            _ = total_content_h;
        });

        // CPU cores at bottom of processes tab
        buildCpuCores(summary, false);
    });
}

// ---------------------------------------------------------------------------
// Performance tab — scrollable graph panels
// ---------------------------------------------------------------------------

fn buildPerformanceTab(summary: SystemSummary) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("perf-content"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
        },
    })({
        clay.UI()(.{
            .id = clay.ElementId.ID("perf-scroll"),
            .layout = .{
                .sizing = clay.Sizing.grow,
                .direction = .top_to_bottom,
                .padding = clay.Padding.all(12),
                .child_gap = 12,
            },
            .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
            .background_color = theme.right_panel_bg,
        })({
            buildPerfGraphSection("g-cpu", "ga-cpu", "CPU", summary.top_cpu[0..@intCast(summary.top_cpu_count)]);
            buildPerfGraphSection("g-mem", "ga-mem", summary.mem_title_str, summary.top_mem[0..@intCast(summary.top_mem_count)]);
            buildPerfGraphSection("g-disk", "ga-disk", "Disk I/O", summary.top_disk[0..@intCast(summary.top_disk_count)]);

            // CPU Cores section in performance tab (taller)
            buildCpuCores(summary, true);
        });
    });
}

// ---------------------------------------------------------------------------
// Network tab — system-wide TCP connections
// ---------------------------------------------------------------------------

fn buildNetworkTab(interaction: InteractionState) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("network-content"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
        },
    })({
        // Column headers (normal flow — rendered first, opaque bg)
        buildColumnHeaderBar("nt", .{
            .col_widths = &interaction.net_col_widths,
            .col_order = &interaction.net_col_order,
            .col_count = NET_COL_COUNT,
            .grow_col_idx = @intFromEnum(NetCol.proc_name),
            .col_labels = &net_col_labels,
            .sort_map = &[NET_COL_COUNT]SortColumn{ .none, .none, .none, .none, .none, .none },
            .dragging_header = interaction.net_dragging_header,
            .drag_header_x = interaction.net_drag_header_x,
            .viewport_width = interaction.viewport_width,
        }, interaction);

        // Outer clip container — clips EVERYTHING below the column headers.
        // This prevents any scroll content from bleeding upward into the
        // header area. The nested scissor stack in the renderer ensures
        // the inner scroll clip intersects with this outer clip.
        clay.UI()(.{
            .id = clay.ElementId.ID("net-body"),
            .layout = .{
                .sizing = clay.Sizing.grow,
                .direction = .top_to_bottom,
            },
            .clip = .{ .vertical = true },
        })({
            // Connection count header
            clay.UI()(.{
                .id = clay.ElementId.ID("net-info"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(24) },
                    .padding = .{ .left = 14, .right = 14 },
                    .child_alignment = .{ .x = .left, .y = .center },
                },
                .background_color = theme.bg,
            })({
                clay.text("TCP Connections", .{ .color = theme.text_dim, .font_size = 12 });
            });

            // Scrollable connection rows (virtualized)
            const scroll_y = interaction.net_scroll_y;
            const viewport_h = interaction.viewport_height - 24 - 140; // subtract info bar + stats strip height
            const total_rows: usize = interaction.connections.len;
            const row_h: f32 = 24;

            const first_visible: usize = if (scroll_y > 0)
                @min(@as(usize, @intFromFloat(scroll_y / row_h)), total_rows)
            else
                0;
            const visible_count: usize = @min(@as(usize, @intFromFloat(@max(viewport_h, 0) / row_h)) + 4, 80);
            const first_row = if (first_visible >= 2) first_visible - 2 else 0;
            const last_row = @min(first_row + visible_count, total_rows);

            const top_spacer_h = @as(f32, @floatFromInt(first_row)) * row_h;
            const bottom_spacer_h = @as(f32, @floatFromInt(total_rows -| last_row)) * row_h;

            clay.UI()(.{
                .id = clay.ElementId.ID("net-scroll"),
                .layout = .{
                    .sizing = clay.Sizing.grow,
                    .direction = .top_to_bottom,
                },
                .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
            })({
                if (interaction.connections.len == 0) {
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
                    // Top spacer
                    if (top_spacer_h > 0) {
                        clay.UI()(.{
                            .id = clay.ElementId.ID("nt-vtop"),
                            .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(top_spacer_h) } },
                        })({});
                    }

                    for (interaction.connections[first_row..last_row], first_row..last_row) |conn, i| {
                        buildMainNetworkRow(conn, i, interaction);
                    }

                    // Bottom spacer
                    if (bottom_spacer_h > 0) {
                        clay.UI()(.{
                            .id = clay.ElementId.ID("nt-vbot"),
                            .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(bottom_spacer_h) } },
                        })({});
                    }
                }
            });

            // --- Network stats info strip (5-box layout) ---
            buildNetworkStatsStrip(interaction);
        });
    });
}

fn buildNetworkStatsStrip(interaction: InteractionState) void {
    const strip_h: f32 = 140;
    const border_color = clay.Color{ theme.separator[0], theme.separator[1], theme.separator[2], 50 };

    clay.UI()(.{
        .id = clay.ElementId.ID("net-stats-strip"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(strip_h) },
            .direction = .left_to_right,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
            .child_gap = 10,
        },
        .background_color = theme.bg,
    })({
        // Box 1: Empty spacer (equal grow)
        clay.UI()(.{
            .id = clay.ElementId.ID("net-spacer-l"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            },
        })({});

        // Box 2: Packets Info card (equal grow)
        clay.UI()(.{
            .id = clay.ElementId.ID("net-pkt-card"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
                .direction = .top_to_bottom,
                .padding = .{ .left = 14, .right = 14, .top = 12, .bottom = 12 },
                .child_gap = 3,
            },
            .background_color = theme.graph_section_bg,
            .corner_radius = clay.CornerRadius.all(theme.corner_radius),
            .border = .{
                .color = border_color,
                .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            },
        })({
            clay.text("Packets", .{ .color = theme.text_header, .font_size = 14 });
            netStatRow("Packets In", interaction.net_packets_in_str);
            netStatRow("Packets Out", interaction.net_packets_out_str);
            netStatRow("In/sec", interaction.net_packets_in_rate_str);
            netStatRow("Out/sec", interaction.net_packets_out_rate_str);
        });

        // Box 3: Bidirectional chart (equal grow)
        clay.UI()(.{
            .id = clay.ElementId.ID("net-chart-wrap"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
                .direction = .top_to_bottom,
                .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 },
                .child_gap = 4,
            },
            .background_color = theme.graph_section_bg,
            .corner_radius = clay.CornerRadius.all(theme.corner_radius),
            .border = .{
                .color = border_color,
                .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            },
        })({
            // Chart title / dropdown trigger
            clay.UI()(.{
                .id = clay.ElementId.ID("net-chart-hdr"),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(18) },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            })({
                const label: []const u8 = if (interaction.net_chart_mode == 0) "Packets \xE2\x96\xBE" else "Data \xE2\x96\xBE";
                clay.text(label, .{ .color = theme.accent, .font_size = 12 });
            });

            // Chart area placeholder (bounds extracted by main.zig for sgl overlay)
            clay.UI()(.{
                .id = clay.ElementId.ID("ga-net"),
                .layout = .{
                    .sizing = clay.Sizing.grow,
                },
                .background_color = theme.bar_bg,
                .corner_radius = clay.CornerRadius.all(theme.corner_radius_sm),
            })({});
        });

        // Box 4: Data Info card (equal grow)
        clay.UI()(.{
            .id = clay.ElementId.ID("net-data-card"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
                .direction = .top_to_bottom,
                .padding = .{ .left = 14, .right = 14, .top = 12, .bottom = 12 },
                .child_gap = 3,
            },
            .background_color = theme.graph_section_bg,
            .corner_radius = clay.CornerRadius.all(theme.corner_radius),
            .border = .{
                .color = border_color,
                .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
            },
        })({
            clay.text("Data", .{ .color = theme.text_header, .font_size = 14 });
            netStatRow("Received", interaction.net_bytes_in_str);
            netStatRow("Sent", interaction.net_bytes_out_str);
            netStatRow("In/sec", interaction.net_bytes_in_rate_str);
            netStatRow("Out/sec", interaction.net_bytes_out_rate_str);
        });

        // Box 5: Empty spacer (equal grow)
        clay.UI()(.{
            .id = clay.ElementId.ID("net-spacer-r"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            },
        })({});
    });
}

fn netStatRow(label: []const u8, value: []const u8) void {
    clay.UI()(.{
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(19) },
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.fixed(80), .h = clay.SizingAxis.grow },
                .child_alignment = .{ .x = .left, .y = .center },
            },
        })({
            clay.text(label, .{ .color = theme.text_dim, .font_size = 11 });
        });
        clay.text(value, .{ .color = theme.text_primary, .font_size = 12 });
    });
}

var net_row_idx: u16 = 0;

fn buildMainNetworkRow(conn: process.TcpConnection, i: usize, interaction: InteractionState) void {
    const bg = if (i % 2 == 0) theme.row_even else theme.row_odd;

    const state_color = switch (conn.state) {
        .established => theme.accent,
        .listen => clay.Color{ 100, 200, 255, 255 },
        .close_wait, .fin_wait_1, .fin_wait_2, .closing, .time_wait, .last_ack => clay.Color{ 255, 200, 80, 255 },
        else => theme.text_dim,
    };

    // Format address strings using frame arena (Clay stores pointers, not copies)
    const alloc = interaction.frame_alloc orelse return;
    const local_str = std.fmt.allocPrint(alloc, "{s}:{d}", .{ conn.localAddrStr(), conn.local_port }) catch "?";
    const remote_str = std.fmt.allocPrint(alloc, "{s}:{d}", .{ conn.remoteAddrStr(), conn.remote_port }) catch "?";
    const pid_str = std.fmt.allocPrint(alloc, "{d}", .{conn.pid}) catch "?";
    const proto: []const u8 = if (conn.is_ipv6) "TCP6" else "TCP4";
    const proc_name: []const u8 = if (interaction.conn_names) |names| names.get(conn.pid) orelse "?" else "?";

    clay.UI()(.{
        .id = clay.ElementId.IDI("nr", @intCast(net_row_idx)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(24) },
            .padding = .{ .left = 14, .right = 14, .top = 2, .bottom = 2 },
            .child_alignment = .{ .x = .left, .y = .center },
            .direction = .left_to_right,
        },
        .background_color = bg,
    })({
        for (interaction.net_col_order) |col_idx| {
            const col: NetCol = @enumFromInt(col_idx);
            switch (col) {
                .state_col => netCell("ns", interaction.net_col_widths[0], conn.state.label(), state_color),
                .local => netCell("nl", interaction.net_col_widths[1], local_str, theme.text_dim),
                .remote => netCell("nm", interaction.net_col_widths[2], remote_str, theme.text_dim),
                .pid_col => netCell("np", interaction.net_col_widths[3], pid_str, theme.text_dim),
                .proto => netCell("nx", interaction.net_col_widths[4], proto, theme.text_dim),
                .proc_name => {
                    clay.UI()(.{
                        .id = clay.ElementId.IDI("nn", @intCast(net_row_idx)),
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

    net_row_idx +%= 1;
}

fn netCell(comptime prefix: []const u8, width: f32, text_content: []const u8, color: clay.Color) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix, @intCast(net_row_idx)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(text_content, .{ .color = color, .font_size = 13, .wrap_mode = .none });
    });
}

// ---------------------------------------------------------------------------
// Startup tab — LaunchAgents/LaunchDaemons table
// ---------------------------------------------------------------------------

fn buildStartupTab(interaction: InteractionState) void {
    const label_max = 28; // chars for ~240px at font 16
    const prog_max = 48; // chars for grow column

    clay.UI()(.{
        .id = clay.ElementId.ID("startup-content"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .top_to_bottom,
        },
    })({
        // Column headers (same generic bar as processes tab)
        buildColumnHeaderBar("su", .{
            .col_widths = &interaction.su_col_widths,
            .col_order = &interaction.su_col_order,
            .col_count = SU_COL_COUNT,
            .grow_col_idx = @intFromEnum(SuCol.program),
            .col_labels = &su_col_labels,
            .sort_map = &su_sort_map,
            .dragging_header = interaction.su_dragging_header,
            .drag_header_x = interaction.su_drag_header_x,
            .viewport_width = interaction.viewport_width,
        }, interaction);

        // Virtualized scrollable rows
        const scroll_y = interaction.startup_scroll_y;
        const viewport_h = interaction.viewport_height;
        const total_rows: usize = interaction.startup_items.len;

        const first_visible: usize = if (scroll_y > 0)
            @min(@as(usize, @intFromFloat(scroll_y / theme.row_height)), total_rows)
        else
            0;
        const visible_count: usize = @as(usize, @intFromFloat(viewport_h / theme.row_height)) + 4;
        const first_row = if (first_visible >= 2) first_visible - 2 else 0;
        const last_row = @min(first_row + visible_count, total_rows);

        const top_spacer_h = @as(f32, @floatFromInt(first_row)) * theme.row_height;
        const bottom_spacer_h = @as(f32, @floatFromInt(total_rows -| last_row)) * theme.row_height;

        clay.UI()(.{
            .id = clay.ElementId.ID("su-scroll"),
            .layout = .{
                .sizing = clay.Sizing.grow,
                .direction = .top_to_bottom,
            },
            .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
        })({
            if (interaction.startup_items.len == 0) {
                clay.UI()(.{
                    .id = clay.ElementId.ID("su-empty"),
                    .layout = .{
                        .sizing = clay.Sizing.grow,
                        .padding = clay.Padding.all(24),
                        .child_alignment = .{ .x = .center, .y = .center },
                    },
                })({
                    clay.text("Loading startup items...", .{ .color = theme.text_dim, .font_size = 14 });
                });
            } else {
                // Top spacer
                if (top_spacer_h > 0) {
                    clay.UI()(.{
                        .id = clay.ElementId.ID("su-vtop"),
                        .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(top_spacer_h) } },
                    })({});
                }

                for (interaction.startup_items[first_row..last_row], first_row..last_row) |item, i| {
                    const bg = if (i % 2 == 0) theme.row_even else theme.row_odd;

                    // Truncated display strings
                    const label_trunc = truncStr(item.label, label_max);
                    const prog_trunc = truncStr(item.program, prog_max);

                    // Pre-compute status
                    const is_running = item.pid != null;
                    const status_text: []const u8 = if (is_running) "Running" else "Stopped";
                    const status_color = if (is_running) theme.accent else theme.text_dim;

                    clay.UI()(.{
                        .id = clay.ElementId.IDI("srow", @intCast(i)),
                        .layout = .{
                            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.row_height) },
                            .padding = .{ .left = 14, .right = 14, .top = 3, .bottom = 3 },
                            .child_alignment = .{ .x = .left, .y = .center },
                            .direction = .left_to_right,
                        },
                        .background_color = bg,
                    })({
                        for (interaction.su_col_order) |col_idx| {
                            const col: SuCol = @enumFromInt(col_idx);
                            switch (col) {
                                .label => startupCellWithTooltip("sul", i, interaction.su_col_widths[@intFromEnum(SuCol.label)], label_trunc, item.label, theme.text_primary),
                                .program => startupGrowCellWithTooltip("sup", i, prog_trunc, item.program, theme.text_dim),
                                .status => cell("ssta", i, interaction.su_col_widths[@intFromEnum(SuCol.status)], status_text, status_color),
                                .at_load => cell("sral", i, interaction.su_col_widths[@intFromEnum(SuCol.at_load)], if (item.run_at_load) "Yes" else "No", theme.text_dim),
                                .keep_alive => cell("suk", i, interaction.su_col_widths[@intFromEnum(SuCol.keep_alive)], if (item.keep_alive) "Yes" else "No", theme.text_dim),
                                .su_type => cell("sut", i, interaction.su_col_widths[@intFromEnum(SuCol.su_type)], if (item.is_user_agent) "Agent" else "Daemon", theme.text_dim),
                            }
                        }
                    });
                }

                // Bottom spacer
                if (bottom_spacer_h > 0) {
                    clay.UI()(.{
                        .id = clay.ElementId.ID("su-vbot"),
                        .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(bottom_spacer_h) } },
                    })({});
                }
            }
        });
    });
}

/// Byte-truncate a string to fit a column. Returns a slice of the original.
fn truncStr(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    return s[0..max];
}

/// Fixed-width cell with tooltip showing full text on hover when truncated.
fn startupCellWithTooltip(comptime prefix: []const u8, index: usize, width: f32, display: []const u8, full: []const u8, color: clay.Color) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix, @intCast(index)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(display, .{ .color = color, .font_size = 16 });

        if (clay.hovered() and display.len < full.len) {
            startupTooltip(prefix, index, full);
        }
    });
}

/// Grow-width cell with tooltip showing full text on hover when truncated.
fn startupGrowCellWithTooltip(comptime prefix: []const u8, index: usize, display: []const u8, full: []const u8, color: clay.Color) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix, @intCast(index)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            .padding = .{ .right = 8 },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(display, .{ .color = color, .font_size = 16 });

        if (clay.hovered() and display.len < full.len) {
            startupTooltip(prefix, index, full);
        }
    });
}

fn startupTooltip(comptime prefix: []const u8, index: usize, full: []const u8) void {
    // Shadow
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix ++ "ts", @intCast(index)),
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .left_top, .parent = .left_bottom },
            .offset = .{ .x = 1, .y = 4 },
            .z_index = 99,
            .pointer_capture_mode = .passthrough,
        },
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fitMinMax(.{ .max = 600 }) },
            .padding = clay.Padding.axes(8, 5),
        },
        .background_color = .{ theme.shadow_color[0], theme.shadow_color[1], theme.shadow_color[2], 40 },
        .corner_radius = clay.CornerRadius.all(theme.corner_radius + 1),
    })({
        clay.text(full, .{ .color = .{ 0, 0, 0, 0 }, .font_size = 13 });
    });
    // Tooltip
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix ++ "tt", @intCast(index)),
        .floating = .{
            .attach_to = .to_parent,
            .attach_points = .{ .element = .left_top, .parent = .left_bottom },
            .offset = .{ .x = 0, .y = 2 },
            .z_index = 100,
            .pointer_capture_mode = .passthrough,
        },
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fitMinMax(.{ .max = 600 }) },
            .padding = clay.Padding.axes(8, 5),
        },
        .background_color = theme.tooltip_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius),
    })({
        clay.text(full, .{ .color = theme.tooltip_text, .font_size = 13 });
    });
}

fn buildPerfGraphSection(
    comptime section_id: []const u8,
    comptime area_id: []const u8,
    title: []const u8,
    legend_entries: []const TopEntry,
) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(section_id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(220) },
            .direction = .top_to_bottom,
            .padding = clay.Padding.all(12),
            .child_gap = 6,
        },
        .background_color = theme.graph_section_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius),
        .border = .{
            .color = .{ theme.separator[0], theme.separator[1], theme.separator[2], 50 },
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        },
    })({
        // Title
        clay.text(title, .{ .color = theme.text_header, .font_size = 16 });

        // Graph area — empty container where line chart is drawn by renderer
        clay.UI()(.{
            .id = clay.ElementId.ID(area_id),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            },
            .background_color = theme.bar_bg,
            .corner_radius = clay.CornerRadius.all(theme.corner_radius_sm),
        })({});

        // Legend row
        buildLegendRow(section_id, legend_entries);
    });
}

fn buildLegendRow(comptime prefix: []const u8, entries: []const TopEntry) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(prefix ++ "-leg"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(18) },
            .direction = .left_to_right,
            .child_gap = 8,
            .child_alignment = .{ .y = .center },
        },
    })({
        for (entries, 0..) |entry, i| {
            if (i >= 5) break;
            // Color dot
            clay.UI()(.{
                .id = clay.ElementId.IDI(prefix ++ "d", @intCast(i)),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.fixed(8), .h = clay.SizingAxis.fixed(8) },
                },
                .background_color = theme.line_colors[i],
                .corner_radius = clay.CornerRadius.all(4.0),
            })({});
            // Process name
            clay.text(entry.name, .{ .color = theme.text_dim, .font_size = 12 });
        }
    });
}

// ---------------------------------------------------------------------------
// Per-core CPU utilization bars
// ---------------------------------------------------------------------------

fn buildCpuCores(summary: SystemSummary, tall: bool) void {
    const count: usize = @intCast(summary.core_count);
    if (count == 0) return;

    // Fixed height: compact for processes tab, taller for performance tab
    const spark_section_h: f32 = if (tall)
        (if (count > 16) 160.0 else 120.0)
    else
        (if (count > 16) 90.0 else 60.0);

    clay.UI()(.{
        .id = clay.ElementId.ID("cores"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(spark_section_h) },
            .direction = .top_to_bottom,
            .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 6 },
            .child_gap = 4,
        },
        .background_color = theme.col_header_bg,
        .border = .{
            .color = theme.separator,
            .width = .{ .top = 1 },
        },
    })({
        clay.text("CPU Cores", .{ .color = theme.text_header, .font_size = 14 });

        // Sparkline area — empty container, rendered by graph.zig via sgl
        clay.UI()(.{
            .id = clay.ElementId.ID("spark-area"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            },
            .background_color = theme.bar_bg,
            .corner_radius = clay.CornerRadius.all(theme.corner_radius_sm),
        })({});
    });
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

fn buildFooter() void {
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
        clay.text("\xe2\x86\x91\xe2\x86\x93 navigate  \xc2\xb7  / search  \xc2\xb7  \xe2\x8c\x98, settings", .{
            .color = theme.text_footer,
            .font_size = 13,
        });
    });
}

// ---------------------------------------------------------------------------
// Settings popup (floating modal)
// ---------------------------------------------------------------------------

fn buildSettingsPopup(anim: f32) void {
    // Scrim — full-screen dimming overlay behind the modal (fade-in animated)
    clay.UI()(.{
        .id = clay.ElementId.ID("scrim"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .z_index = 190,
        },
        .layout = .{
            .sizing = clay.Sizing.grow,
        },
        .background_color = .{ 0, 0, 0, 120.0 * anim },
    })({});

    // Multi-layer soft shadow behind the modal (4 layers: outermost → innermost, fade-in animated)
    const shadow_layers = [_]struct { ox: f32, oy: f32, expand: f32, alpha: f32 }{
        .{ .ox = 6, .oy = 8, .expand = 12, .alpha = 15 },
        .{ .ox = 4, .oy = 6, .expand = 8, .alpha = 30 },
        .{ .ox = 2, .oy = 4, .expand = 4, .alpha = 50 },
        .{ .ox = 1, .oy = 2, .expand = 2, .alpha = 70 },
    };
    inline for (shadow_layers, 0..) |sl, i| {
        clay.UI()(.{
            .id = clay.ElementId.IDI("s-shd", i),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .center_center, .parent = .center_center },
                .offset = .{ .x = sl.ox, .y = sl.oy + (1.0 - anim) * 10.0 },
                .z_index = 191 + i,
            },
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.fixed(360 + sl.expand), .h = clay.SizingAxis.fixed(440 + sl.expand) },
            },
            .background_color = .{ theme.shadow_color[0], theme.shadow_color[1], theme.shadow_color[2], sl.alpha * anim },
            .corner_radius = clay.CornerRadius.all(theme.corner_radius_lg + 2 + sl.expand / 2),
        })({});
    }

    // Centered floating panel (slides up as it fades in)
    clay.UI()(.{
        .id = clay.ElementId.ID("settings-pnl"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .center_center, .parent = .center_center },
            .offset = .{ .x = 0, .y = (1.0 - anim) * 10.0 },
            .z_index = 200,
        },
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(360), .h = clay.SizingAxis.fit },
            .direction = .top_to_bottom,
            .padding = clay.Padding.all(24),
            .child_gap = 14,
        },
        .background_color = .{ theme.menu_bg[0], theme.menu_bg[1], theme.menu_bg[2], theme.menu_bg[3] * anim },
        .corner_radius = clay.CornerRadius.all(theme.corner_radius_lg),
        .border = .{
            .color = .{ theme.menu_border[0], theme.menu_border[1], theme.menu_border[2], 80.0 * anim },
            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
        },
    })({
        // Title
        clay.text("Settings", .{ .color = theme.text_primary, .font_size = 18 });

        // Separator
        clay.UI()(.{
            .id = clay.ElementId.ID("set-sep"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(1) },
            },
            .background_color = theme.separator,
        })({});

        // Theme section label
        clay.text("Theme", .{ .color = theme.text_header, .font_size = 16 });

        // Theme list
        clay.UI()(.{
            .id = clay.ElementId.ID("theme-list"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow },
                .direction = .top_to_bottom,
                .child_gap = 2,
            },
        })({
            for (0..theme.theme_count) |i| {
                const is_active = i == theme.current_theme_index;
                const is_hovered = clay.pointerOver(clay.ElementId.IDI("thm", @intCast(i)));
                const item_bg = if (is_active) theme.accent
                    else if (is_hovered) theme.menu_hover
                    else theme.transparent;
                const item_text_color = if (is_active) theme.menu_bg else theme.text_primary;

                clay.UI()(.{
                    .id = clay.ElementId.IDI("thm", @intCast(i)),
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(36) },
                        .padding = clay.Padding.axes(12, 8),
                        .child_alignment = .{ .x = .left, .y = .center },
                        .direction = .left_to_right,
                        .child_gap = 10,
                    },
                    .background_color = item_bg,
                    .corner_radius = clay.CornerRadius.all(theme.corner_radius),
                })({
                    // Color swatch preview
                    clay.UI()(.{
                        .id = clay.ElementId.IDI("tsw", @intCast(i)),
                        .layout = .{
                            .sizing = .{ .w = clay.SizingAxis.fixed(18), .h = clay.SizingAxis.fixed(18) },
                        },
                        .background_color = theme.presets[i].accent,
                        .corner_radius = clay.CornerRadius.all(theme.corner_radius_sm),
                        .border = .{
                            .color = theme.separator,
                            .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
                        },
                    })({});

                    clay.text(theme.presets[i].name, .{
                        .color = item_text_color,
                        .font_size = 16,
                    });
                });
            }
        });

        // Bottom row with close button
        clay.UI()(.{
            .id = clay.ElementId.ID("set-btm"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow },
                .child_alignment = .{ .x = .right, .y = .center },
            },
        })({
            clay.UI()(.{
                .id = clay.ElementId.ID("settings-x"),
                .layout = .{
                    .sizing = .{ .h = clay.SizingAxis.fixed(30) },
                    .padding = clay.Padding.axes(20, 6),
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = if (clay.pointerOver(clay.ElementId.ID("settings-x"))) theme.menu_hover else theme.transparent,
                .corner_radius = clay.CornerRadius.all(15), // pill radius (30/2)
            })({
                clay.text("Done", .{ .color = theme.accent, .font_size = 14 });
            });
        });
    });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Generic column header bar — used by both processes and startup tabs.
/// `prefix` is a comptime string for unique Clay element IDs (e.g. "ch" or "su").
fn buildColumnHeaderBar(comptime prefix: []const u8, def: ColumnHeaderDef, interaction: InteractionState) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(prefix ++ "-hdr"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.col_header_height) },
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
        for (def.col_order) |col_idx| {
            const is_dragged = if (def.dragging_header) |dh| dh == col_idx else false;
            const alpha: f32 = if (is_dragged) 120 else 255;
            const label = if (col_idx < def.col_labels.len) def.col_labels[col_idx] else "?";
            const sort_col = if (col_idx < def.sort_map.len) def.sort_map[col_idx] else .none;

            if (col_idx == def.grow_col_idx) {
                colHeaderGrowCell(prefix, col_idx, label, alpha);
            } else {
                const width = if (col_idx < def.col_widths.len) def.col_widths[col_idx] else 80;
                colHeaderFixedCell(prefix, col_idx, width, label, sort_col, interaction, alpha);
            }
        }

        // Drop indicator: floating accent line at the target drop position
        if (def.dragging_header != null) {
            const drop_x = column_ops.computeDropX(def.drag_header_x, .{
                .col_widths = def.col_widths,
                .col_order = def.col_order,
                .col_count = def.col_count,
                .grow_col_idx = def.grow_col_idx,
                .header_top = theme.header_height + theme.tab_bar_height,
                .header_height = theme.col_header_height,
                .left_pad = 14.0,
                .viewport_width = def.viewport_width,
            });
            clay.UI()(.{
                .id = clay.ElementId.ID(prefix ++ "-drop"),
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_top, .parent = .left_top },
                    .offset = .{ .x = drop_x, .y = 6 },
                    .z_index = 50,
                    .pointer_capture_mode = .passthrough,
                },
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.fixed(2), .h = clay.SizingAxis.fixed(theme.col_header_height - 12) },
                },
                .background_color = theme.accent,
                .corner_radius = clay.CornerRadius.all(1),
            })({});
        }
    });
}

/// Grow column header cell (no resize handle, right padding so text doesn't touch neighbor).
fn colHeaderGrowCell(comptime prefix: []const u8, col_idx: u8, label: []const u8, alpha: f32) void {
    const text_color = clay.Color{ theme.text_header[0], theme.text_header[1], theme.text_header[2], alpha };
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix ++ "h", @intCast(col_idx)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            .padding = .{ .right = 8 },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(label, .{ .color = text_color, .font_size = 16 });
    });
}

/// Fixed-width column header cell with sort indicator + resize handle.
fn colHeaderFixedCell(comptime prefix: []const u8, col_idx: u8, width: f32, label: []const u8, column: SortColumn, interaction: InteractionState, alpha: f32) void {
    const is_sorted = column != .none and interaction.sort_column == column;
    const text_color = clay.Color{ theme.text_header[0], theme.text_header[1], theme.text_header[2], alpha };
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix ++ "h", @intCast(col_idx)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
            .direction = .left_to_right,
            .child_gap = 2,
        },
    })({
        clay.text(label, .{ .color = text_color, .font_size = 16 });
        if (is_sorted) {
            const sort_alpha = alpha * interaction.sort_anim;
            const indicator: []const u8 = if (interaction.sort_direction == .ascending) "\xe2\x96\xb2" else "\xe2\x96\xbc";
            clay.text(indicator, .{ .color = .{ theme.text_header[0], theme.text_header[1], theme.text_header[2], sort_alpha }, .font_size = 14 });
        }
        // Spacer pushes resize handle to right edge
        clay.UI()(.{
            .id = clay.ElementId.IDI(prefix ++ "s", @intCast(col_idx)),
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow } },
        })({});
        // Resize handle — visible bar at right edge, brightens on hover
        const rh_hovered = clay.pointerOver(clay.ElementId.IDI(prefix ++ "r", @intCast(col_idx)));
        const rh_alpha: f32 = if (rh_hovered) 200 else 80;
        clay.UI()(.{
            .id = clay.ElementId.IDI(prefix ++ "r", @intCast(col_idx)),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.fixed(3), .h = clay.SizingAxis.fixed(16) },
            },
            .background_color = .{ theme.separator[0], theme.separator[1], theme.separator[2], rh_alpha },
            .corner_radius = clay.CornerRadius.all(1.5),
        })({});
    });
}

fn cell(comptime prefix: []const u8, index: usize, width: f32, text_content: []const u8, color: clay.Color) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix, @intCast(index)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(text_content, .{ .color = color, .font_size = 16 });
    });
}

fn intensityCell(comptime prefix: []const u8, index: usize, width: f32, text_content: []const u8, color: clay.Color, tint: clay.Color, intensity: f32, row_bg: clay.Color) void {
    // Square-root curve so low-but-nonzero values (1-5%) get visible color,
    // matching Task Manager's heat-map behavior where even light usage is tinted.
    // Linear scaling makes anything below ~15% invisible (alpha < 20).
    const t = @max(0.0, @min(intensity, 1.0));
    const bg = if (t > 0.001) blk: {
        const boosted = @sqrt(t); // sqrt curve: 1%→10%, 5%→22%, 25%→50%, 100%→100%
        const max_alpha: f32 = 160.0;
        break :blk clay.Color{ tint[0], tint[1], tint[2], boosted * max_alpha };
    } else row_bg;
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix, @intCast(index)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
        },
        .background_color = bg,
    })({
        clay.text(text_content, .{ .color = color, .font_size = 16 });
    });
}

fn nameCellDyn(index: usize, row: RowText, width: f32) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI("name", @intCast(index)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
            .direction = .left_to_right,
            .child_gap = 0,
        },
    })({
        // Tree indentation spacer (depth × 16px)
        if (row.depth > 0) {
            const indent_w: f32 = @as(f32, @floatFromInt(row.depth)) * 16.0;
            clay.UI()(.{
                .id = clay.ElementId.IDI("ind", @intCast(index)),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.fixed(indent_w), .h = clay.SizingAxis.fixed(16) },
                },
            })({});
        }

        // Disclosure triangle (clickable) or spacer for leaves
        if (row.is_parent) {
            const triangle: []const u8 = if (row.is_expanded) "\xe2\x96\xbc" else "\xe2\x96\xb6"; // ▼ or ▶
            clay.UI()(.{
                .id = clay.ElementId.IDI("tree", @intCast(index)),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.fixed(16), .h = clay.SizingAxis.fixed(16) },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            })({
                clay.text(triangle, .{ .color = theme.text_dim, .font_size = 10 });
            });
        } else if (row.depth > 0) {
            // Leaf spacer (same width as triangle)
            clay.UI()(.{
                .id = clay.ElementId.IDI("tsp", @intCast(index)),
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.fixed(16), .h = clay.SizingAxis.fixed(16) },
                },
            })({});
        }

        // Icon placeholder — 16×16, nearly transparent so Clay emits a
        // rectangle command that the renderer can match by element ID.
        clay.UI()(.{
            .id = clay.ElementId.IDI("ico", @intCast(index)),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.fixed(16), .h = clay.SizingAxis.fixed(16) },
            },
            .background_color = .{ 0, 0, 0, 1 },
        })({});

        // Gap between icon and name
        clay.UI()(.{
            .id = clay.ElementId.IDI("ng", @intCast(index)),
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.fixed(6) } },
        })({});

        const name_color = if (!row.search_match) clay.Color{
            theme.text_dim[0], theme.text_dim[1], theme.text_dim[2], 100,
        } else theme.text_primary;
        clay.text(row.name, .{ .color = name_color, .font_size = 16 });
    });
}

fn blendColor(a: clay.Color, b: clay.Color, t: f32) clay.Color {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    };
}

fn pathCell(index: usize, row: RowText) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI("path", @intCast(index)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            .padding = .{ .right = 8 },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(row.path_str, .{ .color = theme.text_dim, .font_size = 16 });

        // Tooltip on hover (only if path was truncated)
        if (clay.hovered() and row.full_path.len > 0 and row.path_str.len < row.full_path.len) {
            // Tooltip shadow layers (2 layers for subtle depth)
            const tt_shadows = [_]struct { ox: f32, oy: f32, expand: f32, alpha: u8, z: u16 }{
                .{ .ox = 3, .oy = 4, .expand = 6, .alpha = 20, .z = 98 },
                .{ .ox = 1, .oy = 2, .expand = 2, .alpha = 45, .z = 99 },
            };
            inline for (tt_shadows, 0..) |sl, si| {
                clay.UI()(.{
                    .id = clay.ElementId.IDI("pts" ++ [_]u8{'0' + si}, @intCast(index)),
                    .floating = .{
                        .attach_to = .to_parent,
                        .attach_points = .{ .element = .right_top, .parent = .right_bottom },
                        .offset = .{ .x = sl.ox, .y = 2 + sl.oy },
                        .z_index = sl.z,
                        .pointer_capture_mode = .passthrough,
                    },
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.fitMinMax(.{ .max = 500 }) },
                        .padding = clay.Padding.axes(6 + @as(u16, @intFromFloat(sl.expand / 2)), 4 + @as(u16, @intFromFloat(sl.expand / 2))),
                    },
                    .background_color = .{ theme.shadow_color[0], theme.shadow_color[1], theme.shadow_color[2], sl.alpha },
                    .corner_radius = clay.CornerRadius.all(theme.corner_radius + sl.expand / 2),
                })({
                    // Invisible text to size the shadow to match tooltip
                    clay.text(row.full_path, .{ .color = .{ 0, 0, 0, 0 }, .font_size = 14 });
                });
            }

            clay.UI()(.{
                .id = clay.ElementId.IDI("ptt", @intCast(index)),
                .floating = .{
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .right_top, .parent = .right_bottom },
                    .offset = .{ .x = 0, .y = 2 },
                    .z_index = 100,
                    .pointer_capture_mode = .passthrough,
                },
                .layout = .{
                    .sizing = .{ .w = clay.SizingAxis.fitMinMax(.{ .max = 500 }) },
                    .padding = clay.Padding.axes(6, 4),
                },
                .background_color = theme.tooltip_bg,
                .corner_radius = clay.CornerRadius.all(theme.corner_radius),
            })({
                clay.text(row.full_path, .{ .color = theme.tooltip_text, .font_size = 14 });
            });
        }
    });
}

