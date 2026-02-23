const builtin = @import("builtin");
const std = @import("std");
const process = @import("process");

pub const pid_t = process.pid_t;
pub const Proc = process.Proc;
pub const ProcessState = process.ProcessState;

const impl = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("Unsupported OS"),
};

pub const ExitWatcher = impl.ExitWatcher;
pub const MAX_CORES = impl.MAX_CORES;
pub const CoreTicks = impl.CoreTicks;

/// Return per-core CPU tick counts (user, system, idle, nice).
/// Writes into `out` and returns the number of cores found.
pub fn getPerCoreCpuTicks(out: *[MAX_CORES]CoreTicks) usize {
    return impl.getPerCoreCpuTicks(out);
}

/// Middle-truncate a filesystem path, preserving root context and binary name.
/// - macOS: Pure Zig. NSLineBreakByTruncatingMiddle is a rendering enum, not a string API.
/// - Windows (future): TODO use PathCompactPathEx from shlwapi.h.
pub fn middleTruncatePath(path: []const u8, max_chars: usize, alloc: std.mem.Allocator) []const u8 {
    return impl.middleTruncatePath(path, max_chars, alloc);
}

/// Return total physical RAM in bytes.
pub fn getTotalMemory() u64 {
    return impl.getTotalMemory();
}

pub const PlatformError = error{
    SyscallFailed,
    OutOfMemory,
};

/// Collect a full process snapshot. All data owned by `arena`.
/// Returns a map of pid -> Proc.
pub fn collectSnapshot(arena: std.mem.Allocator) PlatformError!std.AutoHashMap(pid_t, Proc) {
    return impl.collectSnapshot(arena);
}

/// Collect data for a single process by PID. All strings owned by `arena`.
/// Returns null if the process doesn't exist or isn't accessible.
pub fn collectProcess(arena: std.mem.Allocator, pid: pid_t) ?Proc {
    return impl.collectProcess(arena, pid);
}

pub const TcpConnection = process.TcpConnection;
pub const TcpState = process.TcpState;

/// Get resource coalition ID for a process (groups app with its XPC services).
pub fn getCoalitionId(pid: pid_t) u64 {
    return impl.getCoalitionId(pid);
}

/// Collect all TCP connections system-wide. Filter by PID/coalition as needed.
pub fn collectTcpConnections(arena: std.mem.Allocator) PlatformError![]TcpConnection {
    return impl.collectTcpConnections(arena);
}
