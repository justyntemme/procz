const font = @import("font");

pub const SelectRange = struct { lo: usize, hi: usize };

pub const TextSelectState = struct {
    cursor_pos: usize = 0,
    selection_start: ?usize = null,
    dragging: bool = false,

    pub fn beginDrag(self: *TextSelectState, char_pos: usize) void {
        self.cursor_pos = char_pos;
        self.selection_start = char_pos;
        self.dragging = true;
    }

    pub fn updateDrag(self: *TextSelectState, char_pos: usize) void {
        if (self.dragging) {
            self.cursor_pos = char_pos;
        }
    }

    pub fn endDrag(self: *TextSelectState) void {
        self.dragging = false;
        // Collapse empty selection (click without drag)
        if (self.selection_start) |ss| {
            if (ss == self.cursor_pos) self.selection_start = null;
        }
    }

    pub fn selectedRange(self: TextSelectState, text_len: usize) ?SelectRange {
        const ss = self.selection_start orelse return null;
        const cp = @min(self.cursor_pos, text_len);
        const s = @min(ss, text_len);
        const lo = @min(s, cp);
        const hi = @max(s, cp);
        if (lo == hi) return null;
        return .{ .lo = lo, .hi = hi };
    }

    pub fn hasSelection(self: TextSelectState) bool {
        const ss = self.selection_start orelse return false;
        return ss != self.cursor_pos;
    }

    pub fn clear(self: *TextSelectState) void {
        self.cursor_pos = 0;
        self.selection_start = null;
        self.dragging = false;
    }
};

/// Map mouse X to character position within single-line text.
/// text_x = left edge of text in screen coordinates.
pub fn hitTestText(mouse_x: f32, text_x: f32, text: []const u8, font_size: f32) usize {
    const rel_x = mouse_x - text_x;
    if (rel_x <= 0) return 0;

    for (1..text.len + 1) |i| {
        const w = font.measure(text[0..i], font_size).w;
        if (rel_x < w) {
            const prev_w = if (i > 1) font.measure(text[0..i - 1], font_size).w else 0;
            const mid = (prev_w + w) / 2.0;
            return if (rel_x < mid) i - 1 else i;
        }
    }
    return text.len;
}
