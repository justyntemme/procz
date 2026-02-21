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

/// Middle-truncate a filesystem path, preserving root context and binary name.
/// - macOS: Pure Zig. NSLineBreakByTruncatingMiddle is a rendering enum, not a string API.
/// - Windows (future): TODO use PathCompactPathEx from shlwapi.h.
pub fn middleTruncatePath(path: []const u8, max_chars: usize, alloc: std.mem.Allocator) []const u8 {
    return impl.middleTruncatePath(path, max_chars, alloc);
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
