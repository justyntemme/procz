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
    right_pad: f32 = 14.0, // right-side padding inside header
    edge_tolerance: f32 = 5.0,
    viewport_width: f32 = 0, // total header width (for computing grow column width)
};

/// Compute grow column width = viewport - left_pad - right_pad - sum(fixed columns).
/// Falls back to 200 when viewport_width is not set.
fn growWidth(cfg: ColumnConfig) f32 {
    if (cfg.viewport_width <= 0) return 200;
    var fixed_sum: f32 = cfg.left_pad + cfg.right_pad;
    for (cfg.col_order) |col_idx| {
        if (col_idx == cfg.grow_col_idx) continue;
        if (col_idx < cfg.col_widths.len) fixed_sum += cfg.col_widths[col_idx];
    }
    return @max(cfg.viewport_width - fixed_sum, 60);
}

/// Test if (mx, my) is near a resizable column's right edge (resize handle).
/// Returns the logical column index if within the edge tolerance, null otherwise.
pub fn hitTestEdge(mx: f32, my: f32, cfg: ColumnConfig) ?u8 {
    const header_bottom = cfg.header_top + cfg.header_height;
    if (my < cfg.header_top or my > header_bottom) return null;

    var edge_x: f32 = cfg.left_pad;
    for (cfg.col_order) |col_idx| {
        if (col_idx == cfg.grow_col_idx) {
            edge_x += growWidth(cfg); // advance past grow column
            continue;
        }
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
        const w: f32 = if (col_idx == cfg.grow_col_idx) growWidth(cfg) else if (col_idx < cfg.col_widths.len) cfg.col_widths[col_idx] else 200;
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
        const w: f32 = if (col_idx == cfg.grow_col_idx) growWidth(cfg) else if (col_idx < cfg.col_widths.len) cfg.col_widths[col_idx] else 200;
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
        const w: f32 = if (col_idx == cfg.grow_col_idx) growWidth(cfg) else if (col_idx < cfg.col_widths.len) cfg.col_widths[col_idx] else 200;
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

    // After removal, positions above src_pos shift down by 1
    const effective_drop = if (src_pos < drop_pos and drop_pos > 0) drop_pos - 1 else drop_pos;
    const insert_at = @min(effective_drop, col_count - 1);
    var j: u8 = col_count - 1;
    while (j > insert_at) : (j -= 1) {
        col_order[j] = col_order[j - 1];
    }
    col_order[insert_at] = src_col;
}

// ---------------------------------------------------------------------------
// ColumnDragState — shared mutable drag state for one tab's columns.
// Eliminates per-tab copy-paste of MOUSE_DOWN/MOVE/UP handling.
// ---------------------------------------------------------------------------

pub const ColumnDragState = struct {
    dragging_col: ?u8 = null,
    drag_start_x: f32 = 0,
    drag_start_width: f32 = 0,
    dragging_header: ?u8 = null,
    header_drag_start_x: f32 = 0,
    header_drag_started: bool = false,

    pub const drag_threshold: f32 = 5.0;

    /// MOUSE_DOWN: test for edge resize or header drag start.
    /// Returns true if the click was consumed (caller should NOT set mouse_clicked).
    pub fn handleMouseDown(self: *ColumnDragState, mx: f32, my: f32, cfg: ColumnConfig, widths: []f32) bool {
        if (hitTestEdge(mx, my, cfg)) |col_idx| {
            self.dragging_col = col_idx;
            self.drag_start_x = mx;
            self.drag_start_width = if (col_idx < widths.len) widths[col_idx] else 80;
            return true;
        } else if (hitTestHeader(mx, my, cfg)) |col_idx| {
            self.dragging_header = col_idx;
            self.header_drag_start_x = mx;
            self.header_drag_started = false;
            return true;
        }
        return false;
    }

    /// MOUSE_MOVE: resize column or detect drag threshold.
    pub fn handleMouseMove(self: *ColumnDragState, mx: f32, widths: []f32) void {
        if (self.dragging_col) |col_idx| {
            const delta = mx - self.drag_start_x;
            if (col_idx < widths.len) {
                widths[col_idx] = @max(self.drag_start_width + delta, 30.0);
            }
        }
        if (self.dragging_header != null and !self.header_drag_started) {
            if (@abs(mx - self.header_drag_start_x) >= drag_threshold) {
                self.header_drag_started = true;
            }
        }
    }

    /// MOUSE_UP: finalize reorder or mark as simple click.
    /// Returns true if the event was just a click (threshold not met).
    pub fn handleMouseUp(self: *ColumnDragState, mx: f32, cfg: ColumnConfig, order: []u8, col_count: u8) bool {
        var was_click = false;
        if (self.header_drag_started) {
            if (self.dragging_header) |src_col| {
                const drop_pos = findDropPos(mx, cfg);
                reorder(order, src_col, drop_pos, col_count);
            }
        } else if (self.dragging_header != null) {
            was_click = true;
        }
        self.dragging_header = null;
        self.header_drag_started = false;
        self.dragging_col = null;
        return was_click;
    }
};
