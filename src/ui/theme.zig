const clay = @import("zclay");

// ---------------------------------------------------------------------------
// Layout constants (unchanged across themes)
// ---------------------------------------------------------------------------

// -- font sizes --
pub const font_size: f32 = 16.0;
pub const font_size_header: f32 = 18.0;
pub const font_size_small: f32 = 14.0;

// -- layout metrics --
pub const row_height: f32 = 24.0;
pub const header_height: f32 = 48.0;
pub const col_header_height: f32 = 28.0;
pub const footer_height: f32 = 28.0;
pub const indent_px: u16 = 20;

// -- column widths (pixels) --
pub const col_pid: f32 = 70.0;
pub const col_name: f32 = 240.0;
pub const col_cpu: f32 = 70.0;
pub const col_mem: f32 = 80.0;
pub const col_disk: f32 = 80.0;
pub const col_gpu: f32 = 70.0;

// -- visual polish (macOS-inspired corner radius tiers) --
pub const corner_radius_sm: f32 = 4.0; // swatches, dots, small indicators
pub const corner_radius: f32 = 8.0; // buttons, menu items, graph areas, panels
pub const corner_radius_lg: f32 = 12.0; // modals, settings popup
pub const shadow_offset: f32 = 4.0;

// -- tab bar metrics --
pub const tab_bar_height: f32 = 36.0;

// -- graph panel metrics --
pub const graph_padding: u16 = 8;
pub const bar_height: f32 = 12.0;
pub const bar_label_ratio: f32 = 0.33;
pub const graph_bar_row_height: f32 = 20.0;

// -- theme-independent --
pub const transparent: clay.Color = .{ 0, 0, 0, 0 };

// -- line graph colors (fixed across all themes) --
pub const line_colors = [5]clay.Color{
    .{ 80, 150, 255, 255 }, // blue
    .{ 80, 210, 120, 255 }, // green
    .{ 250, 190, 70, 255 }, // amber
    .{ 175, 130, 250, 255 }, // purple
    .{ 70, 200, 220, 255 }, // cyan
};

// ---------------------------------------------------------------------------
// Color scheme definition
// ---------------------------------------------------------------------------

pub const ColorScheme = struct {
    name: []const u8,

    // backgrounds
    bg: clay.Color,
    header_bg: clay.Color,
    col_header_bg: clay.Color,
    row_even: clay.Color,
    row_odd: clay.Color,
    row_selected: clay.Color,
    row_hover: clay.Color,
    footer_bg: clay.Color,
    right_panel_bg: clay.Color,
    graph_section_bg: clay.Color,
    separator: clay.Color,
    shadow_color: clay.Color,

    // text
    text_primary: clay.Color,
    text_dim: clay.Color,
    text_title: clay.Color,
    text_header: clay.Color,
    text_footer: clay.Color,
    tooltip_bg: clay.Color,
    tooltip_text: clay.Color,

    // intensity tint — single accent-derived color for all metric cells (Task Manager style)
    intensity_tint: clay.Color,

    // graph bars
    bar_cpu: clay.Color,
    bar_mem: clay.Color,
    bar_state: clay.Color,
    bar_bg: clay.Color,

    // menu / settings UI
    menu_bg: clay.Color,
    menu_hover: clay.Color,
    menu_border: clay.Color,
    accent: clay.Color,

    // tab bar
    tab_bg: clay.Color,
    tab_active_bg: clay.Color,
};

// ---------------------------------------------------------------------------
// Active colors (mutable — updated by applyTheme)
// ---------------------------------------------------------------------------

pub var bg: clay.Color = .{ 25, 25, 30, 255 };
pub var header_bg: clay.Color = .{ 35, 35, 45, 255 };
pub var col_header_bg: clay.Color = .{ 30, 30, 38, 255 };
pub var row_even: clay.Color = .{ 25, 25, 30, 255 };
pub var row_odd: clay.Color = .{ 30, 30, 36, 255 };
pub var row_selected: clay.Color = .{ 45, 60, 100, 255 };
pub var row_hover: clay.Color = .{ 38, 38, 48, 255 };
pub var footer_bg: clay.Color = .{ 30, 30, 40, 255 };
pub var right_panel_bg: clay.Color = .{ 28, 28, 35, 255 };
pub var graph_section_bg: clay.Color = .{ 22, 22, 28, 255 };
pub var separator: clay.Color = .{ 50, 50, 65, 255 };
pub var shadow_color: clay.Color = .{ 0, 0, 0, 80 };

pub var text_primary: clay.Color = .{ 220, 220, 220, 255 };
pub var text_dim: clay.Color = .{ 140, 140, 150, 255 };
pub var text_title: clay.Color = .{ 180, 200, 255, 255 };
pub var text_header: clay.Color = .{ 160, 170, 190, 255 };
pub var text_footer: clay.Color = .{ 120, 120, 140, 255 };
pub var tooltip_bg: clay.Color = .{ 50, 50, 60, 240 };
pub var tooltip_text: clay.Color = .{ 230, 230, 230, 255 };

pub var intensity_tint: clay.Color = .{ 100, 140, 255, 255 };

pub var bar_cpu: clay.Color = .{ 80, 140, 255, 255 };
pub var bar_mem: clay.Color = .{ 80, 200, 120, 255 };
pub var bar_state: clay.Color = .{ 160, 120, 255, 255 };
pub var bar_bg: clay.Color = .{ 40, 40, 50, 255 };

pub var menu_bg: clay.Color = .{ 38, 38, 50, 255 };
pub var menu_hover: clay.Color = .{ 50, 50, 65, 255 };
pub var menu_border: clay.Color = .{ 55, 55, 70, 255 };
pub var accent: clay.Color = .{ 100, 140, 255, 255 };

pub var tab_bg: clay.Color = .{ 30, 30, 38, 255 };
pub var tab_active_bg: clay.Color = .{ 45, 60, 100, 255 };

// ---------------------------------------------------------------------------
// Theme state
// ---------------------------------------------------------------------------

pub var current_theme_index: usize = 0;

// ---------------------------------------------------------------------------
// Theme presets
// ---------------------------------------------------------------------------

pub const procz_dark = ColorScheme{
    .name = "Procz Dark",
    .bg = .{ 25, 25, 30, 255 },
    .header_bg = .{ 35, 35, 45, 255 },
    .col_header_bg = .{ 30, 30, 38, 255 },
    .row_even = .{ 25, 25, 30, 255 },
    .row_odd = .{ 30, 30, 36, 255 },
    .row_selected = .{ 45, 60, 100, 255 },
    .row_hover = .{ 38, 38, 48, 255 },
    .footer_bg = .{ 30, 30, 40, 255 },
    .right_panel_bg = .{ 28, 28, 35, 255 },
    .graph_section_bg = .{ 22, 22, 28, 255 },
    .separator = .{ 50, 50, 65, 255 },
    .shadow_color = .{ 0, 0, 0, 80 },
    .text_primary = .{ 220, 220, 220, 255 },
    .text_dim = .{ 140, 140, 150, 255 },
    .text_title = .{ 180, 200, 255, 255 },
    .text_header = .{ 160, 170, 190, 255 },
    .text_footer = .{ 120, 120, 140, 255 },
    .tooltip_bg = .{ 50, 50, 60, 240 },
    .tooltip_text = .{ 230, 230, 230, 255 },
    .intensity_tint = .{ 100, 140, 255, 255 },
    .bar_cpu = .{ 80, 140, 255, 255 },
    .bar_mem = .{ 80, 200, 120, 255 },
    .bar_state = .{ 160, 120, 255, 255 },
    .bar_bg = .{ 40, 40, 50, 255 },
    .menu_bg = .{ 38, 38, 50, 255 },
    .menu_hover = .{ 50, 50, 65, 255 },
    .menu_border = .{ 55, 55, 70, 255 },
    .accent = .{ 100, 140, 255, 255 },
    .tab_bg = .{ 30, 30, 38, 255 },
    .tab_active_bg = .{ 45, 60, 100, 255 },
};

pub const catppuccin_mocha = ColorScheme{
    .name = "Catppuccin Mocha",
    .bg = .{ 30, 30, 46, 255 },
    .header_bg = .{ 49, 50, 68, 255 },
    .col_header_bg = .{ 24, 24, 37, 255 },
    .row_even = .{ 30, 30, 46, 255 },
    .row_odd = .{ 36, 36, 52, 255 },
    .row_selected = .{ 45, 55, 90, 255 },
    .row_hover = .{ 39, 39, 55, 255 },
    .footer_bg = .{ 24, 24, 37, 255 },
    .right_panel_bg = .{ 24, 24, 37, 255 },
    .graph_section_bg = .{ 17, 17, 27, 255 },
    .separator = .{ 69, 71, 90, 255 },
    .shadow_color = .{ 0, 0, 0, 80 },
    .text_primary = .{ 205, 214, 244, 255 },
    .text_dim = .{ 166, 173, 200, 255 },
    .text_title = .{ 180, 190, 254, 255 },
    .text_header = .{ 186, 194, 222, 255 },
    .text_footer = .{ 127, 132, 156, 255 },
    .tooltip_bg = .{ 49, 50, 68, 240 },
    .tooltip_text = .{ 205, 214, 244, 255 },
    .intensity_tint = .{ 137, 180, 250, 255 },
    .bar_cpu = .{ 137, 180, 250, 255 },
    .bar_mem = .{ 166, 227, 161, 255 },
    .bar_state = .{ 203, 166, 247, 255 },
    .bar_bg = .{ 17, 17, 27, 255 },
    .menu_bg = .{ 49, 50, 68, 255 },
    .menu_hover = .{ 69, 71, 90, 255 },
    .menu_border = .{ 69, 71, 90, 255 },
    .accent = .{ 137, 180, 250, 255 },
    .tab_bg = .{ 24, 24, 37, 255 },
    .tab_active_bg = .{ 45, 55, 90, 255 },
};

pub const catppuccin_frappe = ColorScheme{
    .name = "Catppuccin Frappe",
    .bg = .{ 48, 52, 70, 255 },
    .header_bg = .{ 65, 69, 89, 255 },
    .col_header_bg = .{ 41, 44, 60, 255 },
    .row_even = .{ 48, 52, 70, 255 },
    .row_odd = .{ 54, 58, 76, 255 },
    .row_selected = .{ 55, 65, 100, 255 },
    .row_hover = .{ 55, 59, 78, 255 },
    .footer_bg = .{ 41, 44, 60, 255 },
    .right_panel_bg = .{ 41, 44, 60, 255 },
    .graph_section_bg = .{ 35, 38, 52, 255 },
    .separator = .{ 81, 87, 109, 255 },
    .shadow_color = .{ 0, 0, 0, 80 },
    .text_primary = .{ 198, 208, 245, 255 },
    .text_dim = .{ 165, 173, 206, 255 },
    .text_title = .{ 186, 187, 241, 255 },
    .text_header = .{ 181, 191, 226, 255 },
    .text_footer = .{ 115, 121, 148, 255 },
    .tooltip_bg = .{ 65, 69, 89, 240 },
    .tooltip_text = .{ 198, 208, 245, 255 },
    .intensity_tint = .{ 140, 170, 238, 255 },
    .bar_cpu = .{ 140, 170, 238, 255 },
    .bar_mem = .{ 166, 209, 137, 255 },
    .bar_state = .{ 202, 158, 230, 255 },
    .bar_bg = .{ 35, 38, 52, 255 },
    .menu_bg = .{ 65, 69, 89, 255 },
    .menu_hover = .{ 81, 87, 109, 255 },
    .menu_border = .{ 81, 87, 109, 255 },
    .accent = .{ 140, 170, 238, 255 },
    .tab_bg = .{ 41, 44, 60, 255 },
    .tab_active_bg = .{ 55, 65, 100, 255 },
};

pub const catppuccin_macchiato = ColorScheme{
    .name = "Catppuccin Macchiato",
    .bg = .{ 36, 39, 58, 255 },
    .header_bg = .{ 54, 58, 79, 255 },
    .col_header_bg = .{ 30, 32, 48, 255 },
    .row_even = .{ 36, 39, 58, 255 },
    .row_odd = .{ 42, 45, 64, 255 },
    .row_selected = .{ 48, 58, 95, 255 },
    .row_hover = .{ 44, 47, 66, 255 },
    .footer_bg = .{ 30, 32, 48, 255 },
    .right_panel_bg = .{ 30, 32, 48, 255 },
    .graph_section_bg = .{ 24, 25, 38, 255 },
    .separator = .{ 73, 77, 100, 255 },
    .shadow_color = .{ 0, 0, 0, 80 },
    .text_primary = .{ 202, 211, 245, 255 },
    .text_dim = .{ 165, 173, 206, 255 },
    .text_title = .{ 183, 189, 248, 255 },
    .text_header = .{ 184, 192, 224, 255 },
    .text_footer = .{ 110, 115, 141, 255 },
    .tooltip_bg = .{ 54, 58, 79, 240 },
    .tooltip_text = .{ 202, 211, 245, 255 },
    .intensity_tint = .{ 138, 173, 244, 255 },
    .bar_cpu = .{ 138, 173, 244, 255 },
    .bar_mem = .{ 166, 218, 149, 255 },
    .bar_state = .{ 198, 160, 246, 255 },
    .bar_bg = .{ 24, 25, 38, 255 },
    .menu_bg = .{ 54, 58, 79, 255 },
    .menu_hover = .{ 73, 77, 100, 255 },
    .menu_border = .{ 73, 77, 100, 255 },
    .accent = .{ 138, 173, 244, 255 },
    .tab_bg = .{ 30, 32, 48, 255 },
    .tab_active_bg = .{ 48, 58, 95, 255 },
};

pub const catppuccin_latte = ColorScheme{
    .name = "Catppuccin Latte",
    .bg = .{ 239, 241, 245, 255 },
    .header_bg = .{ 230, 233, 239, 255 },
    .col_header_bg = .{ 220, 224, 232, 255 },
    .row_even = .{ 239, 241, 245, 255 },
    .row_odd = .{ 230, 233, 239, 255 },
    .row_selected = .{ 170, 195, 240, 255 },
    .row_hover = .{ 220, 224, 232, 255 },
    .footer_bg = .{ 220, 224, 232, 255 },
    .right_panel_bg = .{ 230, 233, 239, 255 },
    .graph_section_bg = .{ 220, 224, 232, 255 },
    .separator = .{ 188, 192, 204, 255 },
    .shadow_color = .{ 0, 0, 0, 40 },
    .text_primary = .{ 76, 79, 105, 255 },
    .text_dim = .{ 92, 95, 119, 255 },
    .text_title = .{ 30, 102, 245, 255 },
    .text_header = .{ 76, 79, 105, 255 },
    .text_footer = .{ 108, 111, 133, 255 },
    .tooltip_bg = .{ 188, 192, 204, 240 },
    .tooltip_text = .{ 76, 79, 105, 255 },
    .intensity_tint = .{ 30, 102, 245, 255 },
    .bar_cpu = .{ 30, 102, 245, 255 },
    .bar_mem = .{ 64, 160, 43, 255 },
    .bar_state = .{ 136, 57, 239, 255 },
    .bar_bg = .{ 204, 208, 218, 255 },
    .menu_bg = .{ 230, 233, 239, 255 },
    .menu_hover = .{ 204, 208, 218, 255 },
    .menu_border = .{ 188, 192, 204, 255 },
    .accent = .{ 30, 102, 245, 255 },
    .tab_bg = .{ 220, 224, 232, 255 },
    .tab_active_bg = .{ 170, 195, 240, 255 },
};

pub const dracula = ColorScheme{
    .name = "Dracula",
    .bg = .{ 40, 42, 54, 255 },
    .header_bg = .{ 68, 71, 90, 255 },
    .col_header_bg = .{ 50, 52, 66, 255 },
    .row_even = .{ 40, 42, 54, 255 },
    .row_odd = .{ 46, 48, 60, 255 },
    .row_selected = .{ 60, 70, 110, 255 },
    .row_hover = .{ 50, 52, 66, 255 },
    .footer_bg = .{ 50, 52, 66, 255 },
    .right_panel_bg = .{ 44, 46, 58, 255 },
    .graph_section_bg = .{ 34, 36, 46, 255 },
    .separator = .{ 68, 71, 90, 255 },
    .shadow_color = .{ 0, 0, 0, 80 },
    .text_primary = .{ 248, 248, 242, 255 },
    .text_dim = .{ 98, 114, 164, 255 },
    .text_title = .{ 189, 147, 249, 255 },
    .text_header = .{ 200, 200, 200, 255 },
    .text_footer = .{ 98, 114, 164, 255 },
    .tooltip_bg = .{ 68, 71, 90, 240 },
    .tooltip_text = .{ 248, 248, 242, 255 },
    .intensity_tint = .{ 189, 147, 249, 255 },
    .bar_cpu = .{ 139, 233, 253, 255 },
    .bar_mem = .{ 80, 250, 123, 255 },
    .bar_state = .{ 189, 147, 249, 255 },
    .bar_bg = .{ 34, 36, 46, 255 },
    .menu_bg = .{ 68, 71, 90, 255 },
    .menu_hover = .{ 78, 81, 100, 255 },
    .menu_border = .{ 98, 114, 164, 255 },
    .accent = .{ 189, 147, 249, 255 },
    .tab_bg = .{ 50, 52, 66, 255 },
    .tab_active_bg = .{ 60, 70, 110, 255 },
};

pub const nord = ColorScheme{
    .name = "Nord",
    .bg = .{ 46, 52, 64, 255 },
    .header_bg = .{ 59, 66, 82, 255 },
    .col_header_bg = .{ 46, 52, 64, 255 },
    .row_even = .{ 46, 52, 64, 255 },
    .row_odd = .{ 52, 58, 70, 255 },
    .row_selected = .{ 55, 75, 120, 255 },
    .row_hover = .{ 55, 62, 76, 255 },
    .footer_bg = .{ 59, 66, 82, 255 },
    .right_panel_bg = .{ 52, 58, 70, 255 },
    .graph_section_bg = .{ 40, 46, 56, 255 },
    .separator = .{ 76, 86, 106, 255 },
    .shadow_color = .{ 0, 0, 0, 80 },
    .text_primary = .{ 216, 222, 233, 255 },
    .text_dim = .{ 148, 156, 173, 255 },
    .text_title = .{ 136, 192, 208, 255 },
    .text_header = .{ 229, 233, 240, 255 },
    .text_footer = .{ 115, 125, 145, 255 },
    .tooltip_bg = .{ 59, 66, 82, 240 },
    .tooltip_text = .{ 216, 222, 233, 255 },
    .intensity_tint = .{ 136, 192, 208, 255 },
    .bar_cpu = .{ 94, 129, 172, 255 },
    .bar_mem = .{ 163, 190, 140, 255 },
    .bar_state = .{ 180, 142, 173, 255 },
    .bar_bg = .{ 40, 46, 56, 255 },
    .menu_bg = .{ 59, 66, 82, 255 },
    .menu_hover = .{ 67, 76, 94, 255 },
    .menu_border = .{ 76, 86, 106, 255 },
    .accent = .{ 136, 192, 208, 255 },
    .tab_bg = .{ 46, 52, 64, 255 },
    .tab_active_bg = .{ 55, 75, 120, 255 },
};

pub const tokyo_night = ColorScheme{
    .name = "Tokyo Night",
    .bg = .{ 26, 27, 38, 255 },
    .header_bg = .{ 41, 46, 66, 255 },
    .col_header_bg = .{ 22, 22, 30, 255 },
    .row_even = .{ 26, 27, 38, 255 },
    .row_odd = .{ 30, 31, 44, 255 },
    .row_selected = .{ 45, 55, 95, 255 },
    .row_hover = .{ 35, 37, 52, 255 },
    .footer_bg = .{ 22, 22, 30, 255 },
    .right_panel_bg = .{ 22, 22, 30, 255 },
    .graph_section_bg = .{ 18, 18, 26, 255 },
    .separator = .{ 59, 66, 97, 255 },
    .shadow_color = .{ 0, 0, 0, 80 },
    .text_primary = .{ 192, 202, 245, 255 },
    .text_dim = .{ 86, 95, 137, 255 },
    .text_title = .{ 122, 162, 247, 255 },
    .text_header = .{ 169, 177, 214, 255 },
    .text_footer = .{ 86, 95, 137, 255 },
    .tooltip_bg = .{ 41, 46, 66, 240 },
    .tooltip_text = .{ 192, 202, 245, 255 },
    .intensity_tint = .{ 122, 162, 247, 255 },
    .bar_cpu = .{ 122, 162, 247, 255 },
    .bar_mem = .{ 158, 206, 106, 255 },
    .bar_state = .{ 187, 154, 247, 255 },
    .bar_bg = .{ 18, 18, 26, 255 },
    .menu_bg = .{ 41, 46, 66, 255 },
    .menu_hover = .{ 52, 57, 80, 255 },
    .menu_border = .{ 59, 66, 97, 255 },
    .accent = .{ 122, 162, 247, 255 },
    .tab_bg = .{ 22, 22, 30, 255 },
    .tab_active_bg = .{ 45, 55, 95, 255 },
};

pub const gruvbox_dark = ColorScheme{
    .name = "Gruvbox Dark",
    .bg = .{ 40, 40, 40, 255 },
    .header_bg = .{ 60, 56, 54, 255 },
    .col_header_bg = .{ 50, 48, 47, 255 },
    .row_even = .{ 40, 40, 40, 255 },
    .row_odd = .{ 46, 46, 46, 255 },
    .row_selected = .{ 70, 60, 50, 255 },
    .row_hover = .{ 50, 48, 47, 255 },
    .footer_bg = .{ 60, 56, 54, 255 },
    .right_panel_bg = .{ 50, 48, 47, 255 },
    .graph_section_bg = .{ 32, 32, 32, 255 },
    .separator = .{ 80, 73, 69, 255 },
    .shadow_color = .{ 0, 0, 0, 80 },
    .text_primary = .{ 235, 219, 178, 255 },
    .text_dim = .{ 168, 153, 132, 255 },
    .text_title = .{ 250, 189, 47, 255 },
    .text_header = .{ 213, 196, 161, 255 },
    .text_footer = .{ 146, 131, 116, 255 },
    .tooltip_bg = .{ 60, 56, 54, 240 },
    .tooltip_text = .{ 235, 219, 178, 255 },
    .intensity_tint = .{ 250, 189, 47, 255 },
    .bar_cpu = .{ 131, 165, 152, 255 },
    .bar_mem = .{ 184, 187, 38, 255 },
    .bar_state = .{ 211, 134, 155, 255 },
    .bar_bg = .{ 32, 32, 32, 255 },
    .menu_bg = .{ 60, 56, 54, 255 },
    .menu_hover = .{ 80, 73, 69, 255 },
    .menu_border = .{ 80, 73, 69, 255 },
    .accent = .{ 250, 189, 47, 255 },
    .tab_bg = .{ 50, 48, 47, 255 },
    .tab_active_bg = .{ 70, 60, 50, 255 },
};

// ---------------------------------------------------------------------------
// Preset array — order determines display in settings UI
// ---------------------------------------------------------------------------

pub const presets = [_]ColorScheme{
    procz_dark,
    catppuccin_mocha,
    catppuccin_frappe,
    catppuccin_macchiato,
    catppuccin_latte,
    dracula,
    nord,
    tokyo_night,
    gruvbox_dark,
};

pub const theme_count: usize = presets.len;

// ---------------------------------------------------------------------------
// Apply theme — copies all colors from a preset into the active vars
// ---------------------------------------------------------------------------

pub fn applyTheme(index: usize) void {
    if (index >= presets.len) return;
    current_theme_index = index;
    const s = presets[index];

    bg = s.bg;
    header_bg = s.header_bg;
    col_header_bg = s.col_header_bg;
    row_even = s.row_even;
    row_odd = s.row_odd;
    row_selected = s.row_selected;
    row_hover = s.row_hover;
    footer_bg = s.footer_bg;
    right_panel_bg = s.right_panel_bg;
    graph_section_bg = s.graph_section_bg;
    separator = s.separator;
    shadow_color = s.shadow_color;

    text_primary = s.text_primary;
    text_dim = s.text_dim;
    text_title = s.text_title;
    text_header = s.text_header;
    text_footer = s.text_footer;
    tooltip_bg = s.tooltip_bg;
    tooltip_text = s.tooltip_text;

    intensity_tint = s.intensity_tint;

    bar_cpu = s.bar_cpu;
    bar_mem = s.bar_mem;
    bar_state = s.bar_state;
    bar_bg = s.bar_bg;

    menu_bg = s.menu_bg;
    menu_hover = s.menu_hover;
    menu_border = s.menu_border;
    accent = s.accent;

    tab_bg = s.tab_bg;
    tab_active_bg = s.tab_active_bg;
}
