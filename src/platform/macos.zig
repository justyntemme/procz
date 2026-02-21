const std = @import("std");
const process = @import("process");

const _Proc = process.Proc;
const _pid_t = process.pid_t;
const _ProcessState = process.ProcessState;

const PlatformError = error{
    SyscallFailed,
    OutOfMemory,
};

const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/resource.h");
});

pub fn collectSnapshot(arena: std.mem.Allocator) PlatformError!std.AutoHashMap(_pid_t, _Proc) {
    // --- discover all PIDs via libproc (system API, no external deps) ---
    const size_bytes = c.proc_listpids(c.PROC_ALL_PIDS, 0, null, 0);
    if (size_bytes <= 0) return error.SyscallFailed;

    const count: usize = @divExact(@as(usize, @intCast(size_bytes)), @sizeOf(_pid_t));
    const pids = arena.alloc(_pid_t, count) catch return error.OutOfMemory;

    const returned_bytes = c.proc_listpids(
        c.PROC_ALL_PIDS,
        0,
        @ptrCast(pids.ptr),
        @intCast(count * @sizeOf(_pid_t)),
    );
    if (returned_bytes <= 0) return error.SyscallFailed;

    const actual_count: usize = @divExact(@as(usize, @intCast(returned_bytes)), @sizeOf(_pid_t));

    // --- collect per-process info via system APIs ---
    var map = std.AutoHashMap(_pid_t, _Proc).init(arena);
    map.ensureTotalCapacity(@intCast(actual_count)) catch return error.OutOfMemory;

    for (pids[0..actual_count]) |pid| {
        if (pid <= 0) continue;

        // BSD info: name, ppid, state, start time
        var bsd_info: c.proc_bsdinfo = undefined;
        const bsd_size = c.proc_pidinfo(
            pid,
            c.PROC_PIDTBSDINFO,
            0,
            &bsd_info,
            @sizeOf(c.proc_bsdinfo),
        );
        if (bsd_size <= 0) continue;

        // Task info: CPU times, RSS
        var task_info: c.proc_taskinfo = undefined;
        const task_size = c.proc_pidinfo(
            pid,
            c.PROC_PIDTASKINFO,
            0,
            &task_info,
            @sizeOf(c.proc_taskinfo),
        );
        const has_task = task_size > 0;

        // Process path via libproc
        var path_buf: [4096]u8 = undefined;
        const path_len = c.proc_pidpath(pid, &path_buf, path_buf.len);
        const path: []const u8 = if (path_len > 0)
            arena.dupe(u8, path_buf[0..@intCast(path_len)]) catch ""
        else
            "";

        // Rusage for physical memory footprint
        var rusage: c.rusage_info_v4 = undefined;
        const rusage_ret = c.proc_pid_rusage(pid, c.RUSAGE_INFO_V4, @ptrCast(&rusage));
        const has_rusage = rusage_ret == 0;

        // Name from bsd_info (null-terminated C string in fixed buffer)
        const raw_name: [*]const u8 = @ptrCast(&bsd_info.pbi_name);
        const name_len = std.mem.indexOfScalar(u8, raw_name[0..c.MAXCOMLEN], 0) orelse c.MAXCOMLEN;
        const name = arena.dupe(u8, raw_name[0..name_len]) catch "";

        // Start time
        const start_sec: i128 = @intCast(bsd_info.pbi_start_tvsec);
        const start_usec: i128 = @intCast(bsd_info.pbi_start_tvusec);
        const start_time_ns = start_sec * std.time.ns_per_s + start_usec * std.time.ns_per_us;

        const proc_entry = _Proc{
            .pid = pid,
            .ppid = @intCast(bsd_info.pbi_ppid),
            .name = name,
            .path = path,
            .state = mapState(bsd_info.pbi_status),
            .mem_rss = if (has_task) task_info.pti_resident_size else 0,
            .mem_phys = if (has_rusage) rusage.ri_phys_footprint else 0,
            .total_user = if (has_task) task_info.pti_total_user else 0,
            .total_system = if (has_task) task_info.pti_total_system else 0,
            .start_time_ns = start_time_ns,
        };

        map.putAssumeCapacity(pid, proc_entry);
    }

    return map;
}

// ---------------------------------------------------------------------------
// ExitWatcher — kqueue EVFILT_PROC NOTE_EXIT
// ---------------------------------------------------------------------------
pub const ExitWatcher = struct {
    kq: std.posix.fd_t,

    const Self = @This();
    const CHUNK = 256;

    pub fn init() !Self {
        const kq = try std.posix.kqueue();
        return .{ .kq = kq };
    }

    pub fn deinit(self: *Self) void {
        std.posix.close(self.kq);
    }

    /// Bulk-register PIDs for NOTE_EXIT. Silently skips PIDs that already
    /// exited (ESRCH) or are otherwise unmonitorable.
    pub fn registerPids(self: *Self, pids: []const _pid_t) void {
        var i: usize = 0;
        while (i < pids.len) {
            const end = @min(i + CHUNK, pids.len);
            const chunk = pids[i..end];

            var changelist: [CHUNK]std.posix.Kevent = undefined;
            for (chunk, 0..) |pid, j| {
                changelist[j] = .{
                    .ident = @intCast(pid),
                    .filter = std.c.EVFILT.PROC,
                    .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
                    .fflags = std.c.NOTE.EXIT,
                    .data = 0,
                    .udata = 0,
                };
            }

            // Use raw kevent syscall; per-event errors reported in eventlist
            // but we don't need to read them — we just want to register.
            _ = std.c.kevent(
                self.kq,
                @ptrCast(&changelist),
                @intCast(chunk.len),
                @ptrCast(&changelist), // reuse as eventlist for error reporting
                @intCast(chunk.len),
                &.{ .sec = 0, .nsec = 0 }, // immediate return
            );

            i = end;
        }
    }

    /// Poll for exited PIDs. Returns the number of exit events written to `out_pids`.
    pub fn pollExits(self: *Self, out_pids: []_pid_t, timeout_ns: u64) usize {
        var events: [64]std.posix.Kevent = undefined;
        const max_events: usize = @min(events.len, out_pids.len);

        const ts: std.posix.timespec = .{
            .sec = @intCast(timeout_ns / std.time.ns_per_s),
            .nsec = @intCast(timeout_ns % std.time.ns_per_s),
        };

        const n = std.posix.kevent(self.kq, &.{}, &events, &ts) catch return 0;

        var count: usize = 0;
        for (events[0..n]) |ev| {
            if (count >= max_events) break;
            out_pids[count] = @intCast(ev.ident);
            count += 1;
        }
        return count;
    }
};

/// Middle-truncate a filesystem path, preserving root context and binary name.
/// Pure Zig implementation. NSLineBreakByTruncatingMiddle is a rendering enum, not a string API.
/// Result: "/System/Library/.../com.apple.WebKit.WebContent"
pub fn middleTruncatePath(path: []const u8, max_chars: usize, alloc: std.mem.Allocator) []const u8 {
    if (path.len == 0) return path;
    if (path.len <= max_chars) return path;

    const ellipsis = "...";
    const ellipsis_len = ellipsis.len;

    // Need at least room for "/.../x"
    if (max_chars < ellipsis_len + 3) {
        // Just return the tail truncated to max_chars
        const start = if (path.len > max_chars) path.len - max_chars else 0;
        return path[start..];
    }

    // Find last separator — the binary name
    const last_sep = std.mem.lastIndexOfScalar(u8, path, '/') orelse {
        // No separator, just truncate from the end
        return path[0..max_chars];
    };

    const tail = path[last_sep..]; // includes the '/'

    if (tail.len + ellipsis_len >= max_chars) {
        // Tail alone is too long, truncate tail from the left
        const start = path.len - max_chars;
        return path[start..];
    }

    // Head gets whatever space remains
    const head_budget = max_chars - tail.len - ellipsis_len;
    if (head_budget == 0) {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ ellipsis, tail }) catch path;
    }

    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
        path[0..head_budget],
        ellipsis,
        tail,
    }) catch path;
}

fn mapState(status: u32) _ProcessState {
    return switch (status) {
        c.SRUN => .running,
        c.SSLEEP => .sleeping,
        c.SSTOP => .stopped,
        c.SZOMB => .zombie,
        else => .unknown,
    };
}
