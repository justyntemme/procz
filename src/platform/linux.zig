const std = @import("std");
const process = @import("process");

const PlatformError = error{
    SyscallFailed,
    OutOfMemory,
};

pub fn collectSnapshot(_: std.mem.Allocator) PlatformError!std.AutoHashMap(process.pid_t, process.Proc) {
    @compileError("Linux platform not yet implemented");
}

pub fn middleTruncatePath(_: []const u8, _: usize, _: std.mem.Allocator) []const u8 {
    @compileError("Linux platform not yet implemented");
}
