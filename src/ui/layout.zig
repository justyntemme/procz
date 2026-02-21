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

pub const SystemSummary = struct {
    total_rss: u64 = 0,
    total_rss_str: []const u8 = "0K",
    proc_count: usize = 0,
    top_cpu: [5]TopEntry = [_]TopEntry{.{}} ** 5,
    top_cpu_count: u8 = 0,
    top_mem: [5]TopEntry = [_]TopEntry{.{}} ** 5,
    top_mem_count: u8 = 0,
    state_counts: [5]u32 = [_]u32{0} ** 5,
    // Pre-formatted strings (allocated by frame arena, safe for Clay to reference)
    header_stats_str: []const u8 = "",
    mem_title_str: []const u8 = "Memory",
    state_value_strs: [5][]const u8 = [_][]const u8{ "", "", "", "", "" },
};

pub const RowText = struct {
    pid_str: []const u8,
    name_prefix: []const u8,
    name: []const u8,
    cpu_str: []const u8,
    mem_str: []const u8,
    path_str: []const u8,
    full_path: []const u8,
    depth: u16,
};

pub const InteractionState = struct {
    is_selected: []const bool, // parallel to row_texts
    hovered_index: ?usize,
};

const state_names = [_][]const u8{ "Running", "Sleeping", "Stopped", "Zombie", "Unknown" };

// ---------------------------------------------------------------------------
// Layout entry point
// ---------------------------------------------------------------------------

pub fn buildLayout(row_texts: []const RowText, summary: SystemSummary, interaction: InteractionState) []clay.RenderCommand {
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
        buildHeader(summary);
        buildBody(row_texts, summary, interaction);
        buildFooter();
    });

    return clay.endLayout();
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

fn buildHeader(summary: SystemSummary) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("header"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.header_height) },
            .padding = clay.Padding.axes(8, 12),
            .child_alignment = .{ .x = .left, .y = .center },
            .direction = .left_to_right,
        },
        .background_color = theme.header_bg,
    })({
        clay.text("procz", .{ .color = theme.text_title, .font_size = 16 });

        // Spacer pushes stats to the right
        clay.UI()(.{
            .id = clay.ElementId.ID("hdr-sp"),
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.grow } },
        })({});

        clay.text(summary.header_stats_str, .{ .color = theme.text_dim, .font_size = 16 });
    });
}

// ---------------------------------------------------------------------------
// Body — horizontal 60/40 split
// ---------------------------------------------------------------------------

fn buildBody(row_texts: []const RowText, summary: SystemSummary, interaction: InteractionState) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("body"),
        .layout = .{
            .sizing = clay.Sizing.grow,
            .direction = .left_to_right,
        },
    })({
        buildLeftPanel(row_texts, interaction);
        buildRightPanel(summary);
    });
}

// ---------------------------------------------------------------------------
// Left panel — process tree table
// ---------------------------------------------------------------------------

fn buildLeftPanel(row_texts: []const RowText, interaction: InteractionState) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("left"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.percent(0.60), .h = clay.SizingAxis.grow },
            .direction = .top_to_bottom,
        },
    })({
        // Column headers
        clay.UI()(.{
            .id = clay.ElementId.ID("col-hdr"),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.col_header_height) },
                .padding = clay.Padding.axes(4, 12),
                .child_alignment = .{ .x = .left, .y = .center },
                .direction = .left_to_right,
            },
            .background_color = theme.col_header_bg,
        })({
            colHeaderCell("ch-pid", theme.col_pid, "PID");
            colHeaderCell("ch-name", theme.col_name, "NAME");
            colHeaderCell("ch-cpu", theme.col_cpu, "CPU");
            colHeaderCell("ch-mem", theme.col_mem, "MEM");
            colHeaderGrow("ch-path", "PATH");
        });

        // Scrollable row area
        clay.UI()(.{
            .id = clay.ElementId.ID("scroll"),
            .layout = .{
                .sizing = clay.Sizing.grow,
                .direction = .top_to_bottom,
            },
            .clip = .{ .vertical = true, .child_offset = clay.getScrollOffset() },
        })({
            for (row_texts, 0..) |row, i| {
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
                        .padding = .{ .left = 12, .right = 12, .top = 3, .bottom = 3 },
                        .child_alignment = .{ .x = .left, .y = .center },
                        .direction = .left_to_right,
                    },
                    .background_color = bg_color,
                })({
                    cell("pid", i, theme.col_pid, row.pid_str, theme.text_dim);
                    nameCell(i, row);
                    cell("cpu", i, theme.col_cpu, row.cpu_str, theme.text_dim);
                    cell("mem", i, theme.col_mem, row.mem_str, theme.text_dim);
                    pathCell(i, row);
                });
            }
        });
    });
}

// ---------------------------------------------------------------------------
// Right panel — graph summaries
// ---------------------------------------------------------------------------

fn buildRightPanel(summary: SystemSummary) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("right"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            .direction = .top_to_bottom,
            .padding = clay.Padding.all(theme.graph_padding),
            .child_gap = theme.graph_padding,
        },
        .background_color = theme.right_panel_bg,
    })({
        buildCpuSection(summary);
        buildMemSection(summary);
        buildStateSection(summary);
    });
}

fn buildCpuSection(summary: SystemSummary) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("g-cpu"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.percent(0.40) },
            .direction = .top_to_bottom,
            .padding = clay.Padding.all(6),
        },
        .background_color = theme.graph_section_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius),
        .clip = .{ .vertical = true },
    })({
        clay.text("Top CPU", .{ .color = theme.text_header, .font_size = 16 });

        const max_val = if (summary.top_cpu_count > 0) summary.top_cpu[0].value else 1;
        const count: usize = @intCast(summary.top_cpu_count);
        for (summary.top_cpu[0..count], 0..) |entry, i| {
            graphBarRow("cb", i, entry.name, calcBarRatio(entry.value, max_val), entry.value_str, theme.bar_cpu);
        }
    });
}

fn buildMemSection(summary: SystemSummary) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("g-mem"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.percent(0.30) },
            .direction = .top_to_bottom,
            .padding = clay.Padding.all(6),
        },
        .background_color = theme.graph_section_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius),
        .clip = .{ .vertical = true },
    })({
        clay.text(summary.mem_title_str, .{ .color = theme.text_header, .font_size = 16 });

        const max_val = if (summary.top_mem_count > 0) summary.top_mem[0].value else 1;
        const count: usize = @intCast(summary.top_mem_count);
        for (summary.top_mem[0..count], 0..) |entry, i| {
            graphBarRow("mb", i, entry.name, calcBarRatio(entry.value, max_val), entry.value_str, theme.bar_mem);
        }
    });
}

fn buildStateSection(summary: SystemSummary) void {
    clay.UI()(.{
        .id = clay.ElementId.ID("g-st"),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            .direction = .top_to_bottom,
            .padding = clay.Padding.all(6),
        },
        .background_color = theme.graph_section_bg,
        .corner_radius = clay.CornerRadius.all(theme.corner_radius),
        .clip = .{ .vertical = true },
    })({
        clay.text("Process States", .{ .color = theme.text_header, .font_size = 16 });

        var max_count: u32 = 1;
        for (summary.state_counts) |sc| {
            if (sc > max_count) max_count = sc;
        }

        for (state_names, 0..) |name, i| {
            const count = summary.state_counts[i];
            if (count == 0) continue;
            graphBarRow("sb", i, name, calcBarRatio(count, max_count), summary.state_value_strs[i], theme.bar_state);
        }
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
            .padding = clay.Padding.axes(6, 12),
            .child_alignment = .{ .x = .left, .y = .center },
        },
        .background_color = theme.footer_bg,
    })({
        clay.text("q: quit | arrows: scroll | enter: detail", .{
            .color = theme.text_footer,
            .font_size = 16,
        });
    });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

fn colHeaderCell(comptime id: []const u8, width: f32, label: []const u8) void {
    clay.UI()(.{
        .id = clay.ElementId.ID(id),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(width), .h = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .left, .y = .center },
        },
    })({
        clay.text(label, .{ .color = theme.text_header, .font_size = 16 });
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

fn nameCell(index: usize, row: RowText) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI("name", @intCast(index)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.fixed(theme.col_name), .h = clay.SizingAxis.grow },
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
                .corner_radius = clay.CornerRadius.all(4.0),
            })({
                clay.text(row.full_path, .{ .color = theme.tooltip_text, .font_size = 14 });
            });
        }
    });
}

fn graphBarRow(comptime prefix: []const u8, index: usize, name: []const u8, fill_ratio: f32, value_str: []const u8, bar_color: clay.Color) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI(prefix ++ "r", @intCast(index)),
        .layout = .{
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(theme.graph_bar_row_height) },
            .direction = .left_to_right,
            .padding = clay.Padding.axes(2, 0),
            .child_alignment = .{ .y = .center },
            .child_gap = 4,
        },
    })({
        // Label — 1/3 of the row
        clay.UI()(.{
            .id = clay.ElementId.IDI(prefix ++ "l", @intCast(index)),
            .layout = .{ .sizing = .{ .w = clay.SizingAxis.percent(theme.bar_label_ratio) } },
        })({
            clay.text(name, .{ .color = theme.text_primary, .font_size = 16 });
        });

        // Bar background + fill — takes remaining space minus value label
        clay.UI()(.{
            .id = clay.ElementId.IDI(prefix ++ "b", @intCast(index)),
            .layout = .{ .sizing = .{
                .w = clay.SizingAxis.grow,
                .h = clay.SizingAxis.fixed(theme.bar_height),
            } },
            .background_color = theme.bar_bg,
            .corner_radius = clay.CornerRadius.all(3.0),
        })({
            if (fill_ratio > 0) {
                clay.UI()(.{
                    .id = clay.ElementId.IDI(prefix ++ "f", @intCast(index)),
                    .layout = .{ .sizing = .{
                        .w = clay.SizingAxis.percent(fill_ratio),
                        .h = clay.SizingAxis.grow,
                    } },
                    .background_color = bar_color,
                    .corner_radius = clay.CornerRadius.all(3.0),
                })({});
            }
        });

        // Value label
        clay.UI()(.{
            .id = clay.ElementId.IDI(prefix ++ "v", @intCast(index)),
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.fit },
            },
        })({
            clay.text(value_str, .{ .color = theme.text_dim, .font_size = 16 });
        });
    });
}

fn calcBarRatio(value: anytype, max_val: anytype) f32 {
    const v: f32 = @floatFromInt(value);
    const m: f32 = @floatFromInt(max_val);
    if (m <= 0) return 0;
    return @min(v / m, 1.0);
}
