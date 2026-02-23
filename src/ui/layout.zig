const clay = @import("zclay");
const theme = @import("theme");

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

pub const ActiveTab = enum { processes, performance };

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
    active_tab: ActiveTab = .processes,
    viewport_height: f32 = 600,
    scroll_y: f32 = 0, // pre-fetched scroll offset for processes tab virtualization
};

pub const MenuState = struct {
    settings_open: bool = false,
};


// ---------------------------------------------------------------------------
// Layout entry point
// ---------------------------------------------------------------------------

pub fn buildLayout(row_texts: []const RowText, summary: SystemSummary, interaction: InteractionState, menu: MenuState) []clay.RenderCommand {
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
        buildTabBar(interaction.active_tab);

        // Tab content area
        switch (interaction.active_tab) {
            .processes => buildProcessesTab(row_texts, summary, interaction),
            .performance => buildPerformanceTab(summary),
        }

        buildFooter();

        // Settings popup (floating, high z-index)
        if (menu.settings_open) {
            buildSettingsPopup();
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
    })({
        clay.text("procz", .{ .color = theme.text_title, .font_size = 18 });

        buildSearchBar(interaction);

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
    const field_w: f32 = if (focused or has_text) 260 else 200;
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
            // Focused but empty: show subtle prompt + tight cursor
            clay.UI()(.{
                .id = clay.ElementId.ID("search-inner"),
                .layout = .{ .direction = .left_to_right, .child_gap = 0 },
            })({
                clay.text("Filter processes\xe2\x80\xa6", .{ .color = theme.text_footer, .font_size = 14 });
                if (interaction.cursor_visible) {
                    clay.text("|", .{ .color = theme.accent, .font_size = 14 });
                }
            });
        } else {
            // Has text: show typed content + tight cursor
            clay.UI()(.{
                .id = clay.ElementId.ID("search-txt"),
                .layout = .{ .direction = .left_to_right, .child_gap = 0 },
            })({
                clay.text(interaction.search_text, .{ .color = theme.text_primary, .font_size = 14 });
                if (focused and interaction.cursor_visible) {
                    clay.text("|", .{ .color = theme.accent, .font_size = 14 });
                }
            });
        }
    });
}

// ---------------------------------------------------------------------------
// Tab bar — horizontal row above content (classic Task Manager style)
// ---------------------------------------------------------------------------

fn buildTabBar(active: ActiveTab) void {
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
        buildTabItem("tab-processes", "Processes", active == .processes);
        buildTabItem("tab-perf", "Performance", active == .performance);
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

        // Active indicator: 2px accent bar at bottom edge
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
        // Column headers (order driven by col_order)
        clay.UI()(.{
            .id = clay.ElementId.ID("col-hdr"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.col_header_height) },
                .padding = clay.Padding.axes(6, 14),
                .child_alignment = .{ .x = .left, .y = .center },
                .direction = .left_to_right,
            },
            .background_color = theme.col_header_bg,
        })({
            for (interaction.col_order) |col_idx| {
                const col: Col = @enumFromInt(col_idx);
                const is_dragged = if (interaction.dragging_header) |dh| dh == col_idx else false;
                const alpha: f32 = if (is_dragged) 120 else 255;
                switch (col) {
                    .pid => colHeaderCellAlpha("ch-pid", interaction.col_widths[0], "PID", .none, interaction, alpha),
                    .name => colHeaderCellAlpha("ch-name", interaction.col_widths[1], "NAME", .name, interaction, alpha),
                    .cpu => colHeaderCellAlpha("ch-cpu", interaction.col_widths[2], "CPU", .cpu, interaction, alpha),
                    .mem => colHeaderCellAlpha("ch-mem", interaction.col_widths[3], "MEM", .mem, interaction, alpha),
                    .disk => colHeaderCellAlpha("ch-disk", interaction.col_widths[4], "DISK", .disk, interaction, alpha),
                    .gpu => colHeaderCellAlpha("ch-gpu", interaction.col_widths[5], "GPU", .gpu, interaction, alpha),
                    .path => colHeaderGrow("ch-path", "PATH"),
                }
            }

            // Drop indicator: floating accent line at the target drop position
            if (interaction.dragging_header != null) {
                // Compute drop X position from mouse X
                const drop_x = computeDropX(interaction);
                clay.UI()(.{
                    .id = clay.ElementId.ID("drop-ind"),
                    .floating = .{
                        .attach_to = .to_parent,
                        .attach_points = .{ .element = .left_top, .parent = .left_top },
                        .offset = .{ .x = drop_x, .y = 0 },
                        .z_index = 50,
                        .pointer_capture_mode = .passthrough,
                    },
                    .layout = .{
                        .sizing = .{ .w = clay.SizingAxis.fixed(2), .h = clay.SizingAxis.fixed(theme.col_header_height) },
                    },
                    .background_color = theme.accent,
                })({});
            }
        });

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
                const bg_color = if (is_selected) theme.row_selected
                    else if (is_hovered) theme.row_hover
                    else if (i % 2 == 0) theme.row_even
                    else theme.row_odd;

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
                    const i_scale: f32 = if (is_selected) 0.3 else 1.0;
                    for (interaction.col_order) |col_idx| {
                        const col: Col = @enumFromInt(col_idx);
                        switch (col) {
                            .pid => cell("pid", i, interaction.col_widths[0], row.pid_str, theme.text_dim),
                            .name => nameCellDyn(i, row, interaction.col_widths[1]),
                            .cpu => intensityCell("cpu", i, interaction.col_widths[2], row.cpu_str, theme.text_dim, theme.intensity_tint, row.cpu_intensity * i_scale, bg_color),
                            .mem => intensityCell("mem", i, interaction.col_widths[3], row.mem_str, theme.text_dim, theme.intensity_tint, row.mem_intensity * i_scale, bg_color),
                            .disk => intensityCell("dsk", i, interaction.col_widths[4], row.disk_str, theme.text_dim, theme.intensity_tint, row.disk_intensity * i_scale, bg_color),
                            .gpu => intensityCell("gpu", i, interaction.col_widths[5], row.gpu_str, theme.text_dim, theme.intensity_tint, row.gpu_intensity * i_scale, bg_color),
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
            .padding = clay.Padding.all(8),
            .child_gap = 4,
        },
        .background_color = theme.graph_section_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius),
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

fn buildSettingsPopup() void {
    // Scrim — full-screen dimming overlay behind the modal
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
        .background_color = .{ 0, 0, 0, 120 },
    })({});

    // Multi-layer soft shadow behind the modal (4 layers: outermost → innermost)
    const shadow_layers = [_]struct { ox: f32, oy: f32, expand: f32, alpha: u8 }{
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
                .offset = .{ .x = sl.ox, .y = sl.oy },
                .z_index = 191 + i,
            },
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.fixed(360 + sl.expand), .h = clay.SizingAxis.fixed(440 + sl.expand) },
            },
            .background_color = .{ theme.shadow_color[0], theme.shadow_color[1], theme.shadow_color[2], sl.alpha },
            .corner_radius = clay.CornerRadius.all(theme.corner_radius_lg + 2 + sl.expand / 2),
        })({});
    }

    // Centered floating panel
    clay.UI()(.{
        .id = clay.ElementId.ID("settings-pnl"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .center_center, .parent = .center_center },
            .z_index = 200,
        },
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(360), .h = clay.SizingAxis.fit },
            .direction = .top_to_bottom,
            .padding = clay.Padding.all(24),
            .child_gap = 14,
        },
        .background_color = theme.menu_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius_lg),
        .border = .{
            .color = .{ theme.menu_border[0], theme.menu_border[1], theme.menu_border[2], 80 },
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

/// Compute the X offset for the drop indicator (relative to col-hdr bounding box).
fn computeDropX(interaction: InteractionState) f32 {
    const mx = interaction.drag_header_x;
    const left_pad: f32 = 14.0; // matches col-hdr horizontal padding
    var edge_x: f32 = left_pad;
    for (interaction.col_order) |col_idx| {
        const w: f32 = if (col_idx == @intFromEnum(Col.path)) 200 else interaction.col_widths[col_idx];
        const mid = edge_x + w / 2.0;
        if (mx < mid) return edge_x;
        edge_x += w;
    }
    return edge_x;
}

fn colHeaderGrow(comptime id: []const u8, label: []const u8) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(label, .{ .color = theme.text_header, .font_size = 16 });
    });
}

fn colHeaderCell(comptime id: []const u8, width: f32, label: []const u8, column: SortColumn, interaction: InteractionState) void {
    colHeaderCellAlpha(id, width, label, column, interaction, 255);
}

fn colHeaderCellAlpha(comptime id: []const u8, width: f32, label: []const u8, column: SortColumn, interaction: InteractionState, alpha: f32) void {
    const is_sorted = column != .none and interaction.sort_column == column;
    const text_color = clay.Color{ theme.text_header[0], theme.text_header[1], theme.text_header[2], alpha };
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
            .direction = .left_to_right,
            .child_gap = 2,
        },
    })({
        clay.text(label, .{ .color = text_color, .font_size = 16 });
        if (is_sorted) {
            // ▲ U+25B2 = \xe2\x96\xb2, ▼ U+25BC = \xe2\x96\xbc
            const indicator: []const u8 = if (interaction.sort_direction == .ascending) "\xe2\x96\xb2" else "\xe2\x96\xbc";
            clay.text(indicator, .{ .color = text_color, .font_size = 14 });
        }
        // Spacer pushes resize handle to right edge
        clay.UI()(.{
            .id = clay.ElementId.ID(id ++ "-sp"),
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow } },
        })({});
        // Resize handle — visible bar at right edge, brightens on hover
        const rh_hovered = clay.pointerOver(clay.ElementId.ID(id ++ "-rh"));
        const rh_alpha: f32 = if (rh_hovered) 200 else 80;
        clay.UI()(.{
            .id = clay.ElementId.ID(id ++ "-rh"),
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
        },
    })({
        if (row.name_prefix.len > 0) {
            clay.text(row.name_prefix, .{ .color = theme.text_dim, .font_size = 16 });
        }
        clay.text(row.name, .{ .color = theme.text_primary, .font_size = 16 });
    });
}

fn pathCell(index: usize, row: RowText) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI("path", @intCast(index)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
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
                        .attach_points = .{ .element = .left_top, .parent = .left_bottom },
                        .offset = .{ .x = sl.ox, .y = 2 + sl.oy },
                        .z_index = sl.z,
                        .pointer_capture_mode = .passthrough,
                    },
                    .layout = .{
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
                    .attach_points = .{ .element = .left_top, .parent = .left_bottom },
                    .offset = .{ .x = 0, .y = 2 },
                    .z_index = 100,
                    .pointer_capture_mode = .passthrough,
                },
                .layout = .{
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

