const std = @import("std");

pub const pid_t = std.posix.pid_t;

pub const ProcessState = enum {
    running,
    sleeping,
    stopped,
    zombie,
    unknown,
};

/// Canonical process data collected per snapshot.
/// All string slices are owned by the batch arena.
pub const Proc = struct {
    pid: pid_t = 0,
    ppid: pid_t = 0,
    name: []const u8 = "",
    path: []const u8 = "",
    state: ProcessState = .unknown,
    mem_rss: u64 = 0,
    mem_phys: u64 = 0,
    total_user: u64 = 0,
    total_system: u64 = 0,
    start_time_ns: i128 = 0,
};
