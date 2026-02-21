const std = @import("std");
const spsc = @import("spsc_queue");
const process = @import("process");

const _pid_t = process.pid_t;
const _Proc = process.Proc;

/// A complete process snapshot transferred from producer to consumer.
/// Owns its ArenaAllocator — the consumer must call `deinit()` when done.
pub const Batch = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMap(_pid_t, _Proc),
    timestamp_ns: i128,

    pub fn deinit(self: *Batch) void {
        // map internals allocated from arena — no separate map.deinit needed
        self.arena.deinit();
    }
};

/// Events pushed from producer thread to UI consumer.
pub const Event = union(enum) {
    snapshot: Batch,
    exit: _pid_t,

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .snapshot => |*b| b.deinit(),
            .exit => {},
        }
    }
};

pub const EventQueue = spsc.SpscQueue(Event, false);

pub fn initQueue(gpa: std.mem.Allocator) !EventQueue {
    return EventQueue.initCapacity(gpa, 4);
}
