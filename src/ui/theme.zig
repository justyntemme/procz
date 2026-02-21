const clay = @import("zclay");

// -- font sizes --
pub const font_size: f32 = 16.0;
pub const font_size_header: f32 = 18.0;
pub const font_size_small: f32 = 14.0;

// -- layout metrics --
pub const row_height: f32 = 24.0;
pub const header_height: f32 = 44.0;
pub const col_header_height: f32 = 28.0;
pub const footer_height: f32 = 32.0;
pub const indent_px: u16 = 20;

// -- column widths (pixels) --
pub const col_pid: f32 = 70.0;
pub const col_name: f32 = 240.0;
pub const col_cpu: f32 = 70.0;
pub const col_mem: f32 = 80.0;

// -- visual polish --
pub const corner_radius: f32 = 6.0;
pub const shadow_color: clay.Color = .{ 0, 0, 0, 80 };
pub const shadow_offset: f32 = 2.0;

// -- graph panel metrics --
pub const graph_padding: u16 = 8;
pub const bar_height: f32 = 12.0;
pub const bar_label_ratio: f32 = 0.33;
pub const graph_bar_row_height: f32 = 20.0;

// -- color palette --
pub const bg: clay.Color = .{ 25, 25, 30, 255 };
pub const header_bg: clay.Color = .{ 35, 35, 45, 255 };
pub const col_header_bg: clay.Color = .{ 30, 30, 38, 255 };
pub const row_even: clay.Color = .{ 25, 25, 30, 255 };
pub const row_odd: clay.Color = .{ 30, 30, 36, 255 };
pub const row_selected: clay.Color = .{ 45, 60, 100, 255 }; // muted blue
pub const row_hover: clay.Color = .{ 38, 38, 48, 255 }; // subtle lift
pub const footer_bg: clay.Color = .{ 30, 30, 40, 255 };
pub const right_panel_bg: clay.Color = .{ 28, 28, 35, 255 };
pub const graph_section_bg: clay.Color = .{ 22, 22, 28, 255 };
pub const separator: clay.Color = .{ 50, 50, 65, 255 };

// -- text colors --
pub const text_primary: clay.Color = .{ 220, 220, 220, 255 };
pub const text_dim: clay.Color = .{ 140, 140, 150, 255 };
pub const text_title: clay.Color = .{ 180, 200, 255, 255 };
pub const text_header: clay.Color = .{ 160, 170, 190, 255 };
pub const text_footer: clay.Color = .{ 120, 120, 140, 255 };
pub const transparent: clay.Color = .{ 0, 0, 0, 0 };
pub const tooltip_bg: clay.Color = .{ 50, 50, 60, 240 };
pub const tooltip_text: clay.Color = .{ 230, 230, 230, 255 };

// -- graph bar colors --
pub const bar_cpu: clay.Color = .{ 80, 140, 255, 255 };
pub const bar_mem: clay.Color = .{ 80, 200, 120, 255 };
pub const bar_state: clay.Color = .{ 160, 120, 255, 255 };
pub const bar_bg: clay.Color = .{ 40, 40, 50, 255 };
