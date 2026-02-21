const std = @import("std");
const process = @import("process");

const _pid_t = process.pid_t;
const _Proc = process.Proc;

/// CSR-style adjacency structure for the process tree.
/// `offsets[i]..offsets[i+1]` indexes into `flat` to give children of node `i`.
pub const Adjacency = struct {
    offsets: []u32,
    flat: []u32,

    pub fn childrenOf(self: *const Adjacency, idx: usize) []const u32 {
        return self.flat[self.offsets[idx]..self.offsets[idx + 1]];
    }
};

/// A row in the flattened tree for rendering.
pub const FlatRow = struct {
    index: u32,
    depth: u16,
};

/// Build a CSR adjacency graph from a process map.
/// Index 0 is a virtual root that parents all orphaned processes.
pub const TreeResult = struct {
    adj: Adjacency,
    pids: []_pid_t,
    pid_to_index: std.AutoHashMap(_pid_t, u32),
    count: usize,
};

pub fn buildTree(map: *const std.AutoHashMap(_pid_t, _Proc), arena: std.mem.Allocator) !TreeResult {
    const n = map.count();
    const total: usize = n + 1; // +1 for virtual root at index 0

    // --- build pid list and index map ---
    const pids = try arena.alloc(_pid_t, total);
    pids[0] = 0; // virtual root

    var pid_to_index = std.AutoHashMap(_pid_t, u32).init(arena);
    try pid_to_index.ensureTotalCapacity(@intCast(total));
    pid_to_index.putAssumeCapacity(0, 0);

    var idx: u32 = 1;
    var map_iter = map.iterator();
    while (map_iter.next()) |entry| {
        pids[idx] = entry.key_ptr.*;
        pid_to_index.putAssumeCapacity(entry.key_ptr.*, idx);
        idx += 1;
    }

    // --- count children per parent ---
    const child_counts = try arena.alloc(u32, total);
    @memset(child_counts, 0);

    map_iter = map.iterator();
    while (map_iter.next()) |entry| {
        const proc = entry.value_ptr;
        const parent_idx = pid_to_index.get(proc.ppid) orelse 0; // orphans -> virtual root
        child_counts[parent_idx] += 1;
    }

    // --- build offsets (prefix sum) ---
    const offsets = try arena.alloc(u32, total + 1);
    offsets[0] = 0;
    for (0..total) |i| {
        offsets[i + 1] = offsets[i] + child_counts[i];
    }

    const flat_len: usize = offsets[total];
    const flat = try arena.alloc(u32, flat_len);

    // --- populate flat array (reuse child_counts as write cursors) ---
    @memset(child_counts, 0);

    map_iter = map.iterator();
    while (map_iter.next()) |entry| {
        const proc = entry.value_ptr;
        const self_idx = pid_to_index.get(proc.pid) orelse continue;
        const parent_idx = pid_to_index.get(proc.ppid) orelse 0;
        const write_pos = offsets[parent_idx] + child_counts[parent_idx];
        flat[write_pos] = self_idx;
        child_counts[parent_idx] += 1;
    }

    return .{
        .adj = .{ .offsets = offsets, .flat = flat },
        .pids = pids,
        .pid_to_index = pid_to_index,
        .count = total,
    };
}

/// Depth-first flatten of the tree for rendering.
/// Returns rows in display order with indentation depth.
pub fn flattenDfs(adj: *const Adjacency, root: u32, scratch: std.mem.Allocator) ![]FlatRow {
    var result: std.ArrayListUnmanaged(FlatRow) = .empty;
    var stack: std.ArrayListUnmanaged(StackEntry) = .empty;
    try stack.append(scratch, .{ .idx = root, .depth = 0 });

    while (stack.pop()) |entry| {
        // Skip virtual root (index 0) from output, but process its children
        if (entry.idx != 0) {
            try result.append(scratch, .{ .index = entry.idx, .depth = entry.depth });
        }

        const children = adj.childrenOf(entry.idx);
        // Push in reverse so first child is processed first (appears first in output)
        var i: usize = children.len;
        while (i > 0) {
            i -= 1;
            const child_depth: u16 = if (entry.idx == 0) 0 else entry.depth + 1;
            try stack.append(scratch, .{ .idx = children[i], .depth = child_depth });
        }
    }

    return result.toOwnedSlice(scratch);
}

const StackEntry = struct {
    idx: u32,
    depth: u16,
};
