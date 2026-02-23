/// Shared column hit-test, reorder, and drop-indicator geometry.
/// Pure functions — no dependencies on Clay, theme, or application state.

pub const ColumnConfig = struct {
    col_widths: []const f32, // widths of resizable columns (indexed by logical col)
    col_order: []const u8, // display position -> logical column index
    col_count: u8, // total columns including grow column
    grow_col_idx: u8, // logical index of grow column (not resizable)
    header_top: f32, // Y of column header top edge
    header_height: f32, // column header height
    left_pad: f32, // horizontal padding inside header
    edge_tolerance: f32 = 5.0,
};

/// Test if (mx, my) is near a resizable column's right edge (resize handle).
/// Returns the logical column index if within the edge tolerance, null otherwise.
pub fn hitTestEdge(mx: f32, my: f32, cfg: ColumnConfig) ?u8 {
    const header_bottom = cfg.header_top + cfg.header_height;
    if (my < cfg.header_top or my > header_bottom) return null;

    var edge_x: f32 = cfg.left_pad;
    for (cfg.col_order) |col_idx| {
        if (col_idx == cfg.grow_col_idx) continue; // grow column has no resize handle
        if (col_idx >= cfg.col_widths.len) continue;
        edge_x += cfg.col_widths[col_idx];
        if (@abs(mx - edge_x) <= cfg.edge_tolerance) {
            return col_idx;
        }
    }
    return null;
}

/// Test if (mx, my) is over a column header body (not the resize edge).
/// Returns the logical column index, null if not over any header.
pub fn hitTestHeader(mx: f32, my: f32, cfg: ColumnConfig) ?u8 {
    const header_bottom = cfg.header_top + cfg.header_height;
    if (my < cfg.header_top or my > header_bottom) return null;

    // Don't report header hit if we're on a resize edge
    if (hitTestEdge(mx, my, cfg) != null) return null;

    var edge_x: f32 = cfg.left_pad;
    for (cfg.col_order) |col_idx| {
        const w: f32 = if (col_idx == cfg.grow_col_idx) 9999 else if (col_idx < cfg.col_widths.len) cfg.col_widths[col_idx] else 9999;
        if (mx >= edge_x and mx < edge_x + w) {
            return col_idx;
        }
        edge_x += w;
    }
    return null;
}

/// Find the display position index where a column should be dropped based on mouse X.
pub fn findDropPos(mx: f32, cfg: ColumnConfig) u8 {
    var edge_x: f32 = cfg.left_pad;
    for (cfg.col_order, 0..) |col_idx, pos| {
        const w: f32 = if (col_idx == cfg.grow_col_idx) 9999 else if (col_idx < cfg.col_widths.len) cfg.col_widths[col_idx] else 9999;
        const mid = edge_x + w / 2.0;
        if (mx < mid) return @intCast(pos);
        edge_x += w;
    }
    return cfg.col_count - 1;
}

/// Compute the X offset for the drop indicator line (relative to col-hdr bounding box).
pub fn computeDropX(mx: f32, cfg: ColumnConfig) f32 {
    var edge_x: f32 = cfg.left_pad;
    for (cfg.col_order) |col_idx| {
        const w: f32 = if (col_idx == cfg.grow_col_idx) 200 else if (col_idx < cfg.col_widths.len) cfg.col_widths[col_idx] else 200;
        const mid = edge_x + w / 2.0;
        if (mx < mid) return edge_x;
        edge_x += w;
    }
    return edge_x;
}

/// In-place reorder: move `src_col` to `drop_pos` within `col_order`.
pub fn reorder(col_order: []u8, src_col: u8, drop_pos: u8, col_count: u8) void {
    // Find current position of the dragged column
    var src_pos: u8 = 0;
    for (col_order, 0..) |c, p| {
        if (c == src_col) {
            src_pos = @intCast(p);
            break;
        }
    }
    if (src_pos == drop_pos) return;

    // Remove src_col by shifting left
    var i: u8 = src_pos;
    while (i + 1 < col_count) : (i += 1) {
        col_order[i] = col_order[i + 1];
    }

    // Insert src_col at drop_pos (clamped)
    const insert_at = @min(drop_pos, col_count - 1);
    var j: u8 = col_count - 1;
    while (j > insert_at) : (j -= 1) {
        col_order[j] = col_order[j - 1];
    }
    col_order[insert_at] = src_col;
}
