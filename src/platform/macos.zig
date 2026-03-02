const std = @import("std");
const process = @import("process");

const _Proc = process.Proc;
const _pid_t = process.pid_t;
const _ProcessState = process.ProcessState;

const PlatformError = error{
    SyscallFailed,
    OutOfMemory,
};

/// Mach absolute time → nanoseconds conversion.
const MachTimebaseInfo = extern struct { numer: u32, denom: u32 };
extern "c" fn mach_timebase_info(info: *MachTimebaseInfo) c_int;

var timebase_numer: u64 = 0;
var timebase_denom: u64 = 0;

fn machToNs(ticks: u64) u64 {
    if (timebase_numer == 0) {
        var info: MachTimebaseInfo = .{ .numer = 0, .denom = 0 };
        _ = mach_timebase_info(&info);
        timebase_numer = if (info.numer > 0) info.numer else 1;
        timebase_denom = if (info.denom > 0) info.denom else 1;
    }
    return ticks *| timebase_numer / timebase_denom;
}

const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/proc_info.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/resource.h");
    @cInclude("mach/mach.h");
    @cInclude("macos_gpu.h");
    @cInclude("macos_startup.h");
    @cInclude("arpa/inet.h");
    @cInclude("ifaddrs.h");
    @cInclude("net/if.h");
    @cInclude("net/if_dl.h");
});

/// Collect data for a single process by PID. Returns null if the process
/// doesn't exist or isn't accessible.
pub fn collectProcess(arena: std.mem.Allocator, pid: _pid_t) ?_Proc {
    return collectProcEntry(arena, pid);
}

/// Collect command-line arguments and environment variables for a PID
/// via KERN_PROCARGS2 sysctl. Returns null on EPERM/ESRCH (other user's
/// process or process not found).
pub fn collectProcessArgs(arena: std.mem.Allocator, pid: _pid_t) ?process.ProcessArgs {
    // 1. Get max buffer size via KERN_ARGMAX
    var argmax: c_int = 0;
    var argmax_size: usize = @sizeOf(c_int);
    var mib_argmax = [_]c_int{ c.CTL_KERN, c.KERN_ARGMAX };
    if (c.sysctl(&mib_argmax, 2, @ptrCast(&argmax), &argmax_size, null, 0) != 0) {
        return null;
    }
    const buf_size: usize = @intCast(argmax);

    // 2. Allocate buffer and fill via KERN_PROCARGS2
    const buf = arena.alloc(u8, buf_size) catch return null;
    var actual_size: usize = buf_size;
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROCARGS2, @intCast(pid) };
    if (c.sysctl(&mib, 3, buf.ptr, &actual_size, null, 0) != 0) {
        return null;
    }
    if (actual_size < 4) return null;
    const data = buf[0..actual_size];

    // 3. Parse: argc (4 bytes), exec_path, null padding, argv strings, env strings
    const argc: u32 = @bitCast(data[0..4].*);

    // Skip exec_path (null-terminated)
    var pos: usize = 4;
    while (pos < data.len and data[pos] != 0) : (pos += 1) {}
    // Skip null padding after exec_path
    while (pos < data.len and data[pos] == 0) : (pos += 1) {}

    // 4. Read argc argv strings
    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var argv_count: u32 = 0;
    while (argv_count < argc and pos < data.len) {
        const start = pos;
        while (pos < data.len and data[pos] != 0) : (pos += 1) {}
        if (pos > start) {
            argv_list.append(arena, data[start..pos]) catch {};
        }
        argv_count += 1;
        pos += 1; // skip null terminator
    }

    // 5. Remaining strings are environment variables
    var env_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var env_count: usize = 0;
    const max_env: usize = 500;
    while (pos < data.len and env_count < max_env) {
        const start = pos;
        while (pos < data.len and data[pos] != 0) : (pos += 1) {}
        if (pos > start) {
            env_list.append(arena, data[start..pos]) catch {};
            env_count += 1;
        }
        pos += 1; // skip null terminator
        // Stop at first empty string (consecutive nulls)
        if (pos < data.len and data[pos] == 0) break;
    }

    return process.ProcessArgs{
        .argv = argv_list.toOwnedSlice(arena) catch &.{},
        .environ = env_list.toOwnedSlice(arena) catch &.{},
    };
}

/// Collect all loaded LaunchAgents/LaunchDaemons via ServiceManagement.
pub fn collectStartupItems(arena: std.mem.Allocator) []process.StartupItem {
    const result = c.get_startup_items();
    defer c.free_startup_items(result);

    if (result.count <= 0 or result.items == null) return &.{};

    const count: usize = @intCast(result.count);
    const items = arena.alloc(process.StartupItem, count) catch return &.{};
    var out_count: usize = 0;

    for (0..count) |i| {
        const ci = result.items[i];
        const label_slice = if (ci.label != null)
            std.mem.sliceTo(ci.label, 0)
        else
            "";
        const program_slice = if (ci.program != null)
            std.mem.sliceTo(ci.program, 0)
        else
            "";

        items[out_count] = .{
            .label = arena.dupe(u8, label_slice) catch continue,
            .program = arena.dupe(u8, program_slice) catch continue,
            .pid = if (ci.pid >= 0) @intCast(ci.pid) else null,
            .run_at_load = ci.run_at_load != 0,
            .keep_alive = ci.keep_alive != 0,
            .is_user_agent = ci.is_user_agent != 0,
        };
        out_count += 1;
    }

    return items[0..out_count];
}

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
        const proc_entry = collectProcEntry(arena, pid) orelse continue;
        map.putAssumeCapacity(pid, proc_entry);
    }

    // Merge GPU usage data from IOKit
    var gpu_buf: [1024]c.GpuProcEntry = undefined;
    const gpu_count = c.collect_gpu_usage(&gpu_buf, gpu_buf.len);
    for (gpu_buf[0..gpu_count]) |gpu_entry| {
        if (map.getPtr(gpu_entry.pid)) |proc_ptr| {
            proc_ptr.gpu_time_ns = gpu_entry.gpu_time_ns;
        }
    }

    return map;
}

/// Collect all available data for a single PID. Returns null if the
/// process doesn't exist or the BSD info syscall fails.
fn collectProcEntry(arena: std.mem.Allocator, pid: _pid_t) ?_Proc {
    // BSD info: name, ppid, state, start time
    var bsd_info: c.proc_bsdinfo = undefined;
    const bsd_size = c.proc_pidinfo(
        pid,
        c.PROC_PIDTBSDINFO,
        0,
        &bsd_info,
        @sizeOf(c.proc_bsdinfo),
    );
    if (bsd_size <= 0) return null;

    // Task info via proc_pidinfo: RSS (memory)
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

    return _Proc{
        .pid = pid,
        .ppid = @intCast(bsd_info.pbi_ppid),
        .name = name,
        .path = path,
        .state = mapState(bsd_info.pbi_status),
        .mem_rss = if (has_task) task_info.pti_resident_size else 0,
        .mem_phys = if (has_rusage) rusage.ri_phys_footprint else 0,
        .total_user = if (has_rusage) machToNs(rusage.ri_user_time) else 0,
        .total_system = if (has_rusage) machToNs(rusage.ri_system_time) else 0,
        .diskio_bytes_read = if (has_rusage) rusage.ri_diskio_bytesread else 0,
        .diskio_bytes_written = if (has_rusage) rusage.ri_diskio_byteswritten else 0,
        .start_time_ns = start_time_ns,
    };
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

/// Return total physical RAM in bytes via sysctl hw.memsize.
pub fn getTotalMemory() u64 {
    var mib = [_]c_int{ c.CTL_HW, c.HW_MEMSIZE };
    var mem: u64 = 0;
    var len: usize = @sizeOf(u64);
    _ = c.sysctl(&mib, 2, @ptrCast(&mem), &len, null, 0);
    return mem;
}

// ---------------------------------------------------------------------------
// Per-core CPU ticks via Mach host_processor_info
// ---------------------------------------------------------------------------

pub const MAX_CORES: usize = 128;

pub const CoreTicks = struct {
    user: u32 = 0,
    system: u32 = 0,
    idle: u32 = 0,
    nice: u32 = 0,
};

pub fn getPerCoreCpuTicks(out: *[MAX_CORES]CoreTicks) usize {
    var num_cpus: c.natural_t = 0;
    var cpu_info: c.processor_info_array_t = null;
    var info_count: c.mach_msg_type_number_t = 0;

    const kr = c.host_processor_info(
        c.mach_host_self(),
        c.PROCESSOR_CPU_LOAD_INFO,
        &num_cpus,
        &cpu_info,
        &info_count,
    );
    if (kr != c.KERN_SUCCESS) return 0;
    defer {
        const size = @as(c.vm_size_t, info_count) * @sizeOf(c.integer_t);
        _ = c.vm_deallocate(c.mach_task_self_, @intFromPtr(cpu_info), size);
    }

    const n: usize = @min(num_cpus, MAX_CORES);
    for (0..n) |i| {
        const base = i * c.CPU_STATE_MAX;
        out.*[i] = .{
            .user = @bitCast(cpu_info[base + c.CPU_STATE_USER]),
            .system = @bitCast(cpu_info[base + c.CPU_STATE_SYSTEM]),
            .idle = @bitCast(cpu_info[base + c.CPU_STATE_IDLE]),
            .nice = @bitCast(cpu_info[base + c.CPU_STATE_NICE]),
        };
    }

    return n;
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

// ---------------------------------------------------------------------------
// Coalition ID & TCP connections (for Network tab)
// ---------------------------------------------------------------------------

const PROC_PIDCOALITIONINFO: c_int = 20;
const COALITION_NUM_TYPES = 2;

const CoalitionInfo = extern struct {
    coalition_id: [COALITION_NUM_TYPES]u64,
    reserved1: u64,
    reserved2: u64,
    reserved3: u64,
};

/// Get resource coalition ID for a process (groups app with its XPC services).
pub fn getCoalitionId(pid: _pid_t) u64 {
    var info: CoalitionInfo = std.mem.zeroes(CoalitionInfo);
    const ret = c.proc_pidinfo(pid, PROC_PIDCOALITIONINFO, 0, &info, @sizeOf(CoalitionInfo));
    if (ret > 0) {
        return info.coalition_id[0];
    }
    return 0;
}

/// Collect all TCP connections system-wide via sysctl("net.inet.tcp.pcblist_n").
/// Caller should filter by PID / coalition_id as needed.
pub fn collectTcpConnections(arena: std.mem.Allocator) PlatformError![]process.TcpConnection {
    var len: usize = 0;
    const name = "net.inet.tcp.pcblist_n";

    if (c.sysctlbyname(name, null, &len, null, 0) != 0) {
        return arena.alloc(process.TcpConnection, 0) catch return error.OutOfMemory;
    }
    if (len == 0) {
        return arena.alloc(process.TcpConnection, 0) catch return error.OutOfMemory;
    }

    const buf = arena.alloc(u8, len) catch return error.OutOfMemory;
    if (c.sysctlbyname(name, buf.ptr, &len, null, 0) != 0) {
        return arena.alloc(process.TcpConnection, 0) catch return error.OutOfMemory;
    }

    var connections: std.ArrayListUnmanaged(process.TcpConnection) = .empty;

    if (len < 24) {
        return connections.toOwnedSlice(arena) catch return error.OutOfMemory;
    }

    const xig_len = std.mem.readInt(u32, buf[0..4], .little);
    var offset: usize = xig_len;

    const XSO_SOCKET: u32 = 0x001;
    const XSO_INPCB: u32 = 0x010;
    const XSO_TCPCB: u32 = 0x020;

    var have_inpcb = false;
    var local_port: u16 = 0;
    var foreign_port: u16 = 0;
    var local_addr: [16]u8 = undefined;
    var foreign_addr: [16]u8 = undefined;
    var is_ipv6: bool = false;
    var pid: i32 = 0;
    var coalition_id: u64 = 0;
    var tcp_state: i32 = 0;

    while (offset + 8 <= len) {
        var xt_len = std.mem.readInt(u32, buf[offset..][0..4], .little);
        var xt_kind = std.mem.readInt(u32, buf[offset + 4 ..][0..4], .little);

        // Footer check
        if (xt_len == xig_len) {
            if (have_inpcb and pid > 0) {
                const conn = makeConnection(pid, coalition_id, local_port, foreign_port, &local_addr, &foreign_addr, is_ipv6, tcp_state);
                connections.append(arena, conn) catch {};
            }
            break;
        }

        // Handle padding (xt_len=0) by scanning forward
        if (xt_len == 0) {
            var scan = offset;
            while (scan + 8 <= len) {
                scan += 4;
                const try_len = std.mem.readInt(u32, buf[scan..][0..4], .little);
                if (try_len >= 24 and try_len < 1024) {
                    const try_kind = std.mem.readInt(u32, buf[scan + 4 ..][0..4], .little);
                    if (try_kind >= 1 and try_kind <= 0x20) {
                        offset = scan;
                        xt_len = try_len;
                        xt_kind = try_kind;
                        break;
                    }
                }
            }
            if (xt_len == 0) break;
        }

        if (offset + xt_len > len) break;

        if (xt_kind == XSO_INPCB and xt_len >= 64) {
            // Save previous connection if any
            if (have_inpcb and pid > 0) {
                const conn = makeConnection(pid, coalition_id, local_port, foreign_port, &local_addr, &foreign_addr, is_ipv6, tcp_state);
                connections.append(arena, conn) catch {};
            }

            have_inpcb = true;
            pid = 0;
            tcp_state = 0;

            foreign_port = std.mem.readInt(u16, buf[offset + 16 ..][0..2], .big);
            local_port = std.mem.readInt(u16, buf[offset + 18 ..][0..2], .big);
            @memcpy(&foreign_addr, buf[offset + 48 ..][0..16]);
            @memcpy(&local_addr, buf[offset + 64 ..][0..16]);

            const vflag = buf[offset + 44];
            is_ipv6 = (vflag & 0x2) != 0;
        } else if (xt_kind == XSO_SOCKET and xt_len >= 72) {
            pid = std.mem.readInt(i32, buf[offset + 68 ..][0..4], .little);
            coalition_id = if (pid > 0) getCoalitionId(pid) else 0;
        } else if (xt_kind == XSO_TCPCB and xt_len >= 40) {
            tcp_state = std.mem.readInt(i32, buf[offset + 36 ..][0..4], .little);
        }

        offset += xt_len;
    }

    return connections.toOwnedSlice(arena) catch return error.OutOfMemory;
}

/// Collect code signing and entitlement information for a process.
/// Uses `codesign` CLI to extract signing details and entitlements.
pub fn collectSecurityInfo(arena: std.mem.Allocator, pid: _pid_t) ?process.SecurityInfo {
    // Get process path first
    var path_buf: [4096]u8 = undefined;
    const path_len = c.proc_pidpath(pid, &path_buf, path_buf.len);
    if (path_len <= 0) return null;
    const path = path_buf[0..@intCast(path_len)];

    var info = process.SecurityInfo{};

    // Run: codesign -dvv <path> — signing details on stderr
    {
        const null_terminated = arena.dupeZ(u8, path) catch return null;
        const argv = [_][]const u8{ "/usr/bin/codesign", "-dvv", null_terminated };
        var child = std.process.Child.init(&argv, arena);
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        _ = child.spawn() catch return null;

        // Read pipes BEFORE wait — wait() may close file descriptors
        var stderr_buf: [4096]u8 = undefined;
        const stderr_read = if (child.stderr) |f| f.readAll(&stderr_buf) catch 0 else 0;
        _ = child.wait() catch {};

        // Parse stderr for relevant fields
        const stderr = stderr_buf[0..stderr_read];
        info.code_sign_id = parseField(stderr, "Identifier=", arena);
        info.team_id = parseField(stderr, "TeamIdentifier=", arena);
        info.signing_authority = parseField(stderr, "Authority=", arena);
        info.format = parseField(stderr, "Format=", arena);
    }

    // Run: codesign -d --entitlements :- <path> — entitlements XML on stdout
    {
        const null_terminated = arena.dupeZ(u8, path) catch return info;
        const argv = [_][]const u8{ "/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", null_terminated };
        var child = std.process.Child.init(&argv, arena);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        _ = child.spawn() catch return info;

        // Read BOTH pipes before wait to avoid deadlock (child blocks if pipe fills)
        var stdout_buf: [32768]u8 = undefined;
        var stderr_discard: [4096]u8 = undefined;
        const stdout_read = if (child.stdout) |f| f.readAll(&stdout_buf) catch 0 else 0;
        _ = if (child.stderr) |f| f.readAll(&stderr_discard) catch 0 else 0;
        _ = child.wait() catch {};

        if (stdout_read > 0) {
            // codesign may prepend a binary DER header (0xFADE7171) before the XML.
            // Find the start of the XML plist.
            var xml_start: usize = 0;
            const raw = stdout_buf[0..stdout_read];
            if (std.mem.indexOf(u8, raw, "<?xml")) |pos| {
                xml_start = pos;
            } else if (std.mem.indexOf(u8, raw, "<plist")) |pos| {
                xml_start = pos;
            }
            info.entitlements = parseEntitlements(raw[xml_start..], arena);

            // Check for sandbox entitlement
            for (info.entitlements) |ent| {
                if (std.mem.eql(u8, ent.key, "com.apple.security.app-sandbox") and
                    std.mem.eql(u8, ent.value, "true"))
                {
                    info.is_sandboxed = true;
                    break;
                }
            }
        }
    }

    return info;
}

/// Parse a "Key=Value\n" field from codesign output.
fn parseField(data: []const u8, prefix: []const u8, arena: std.mem.Allocator) []const u8 {
    var offset: usize = 0;
    while (offset < data.len) {
        // Find start of this line
        const line_start = offset;
        // Find end of line
        while (offset < data.len and data[offset] != '\n') : (offset += 1) {}
        const line = data[line_start..offset];
        if (offset < data.len) offset += 1; // skip \n

        if (line.len > prefix.len and std.mem.startsWith(u8, line, prefix)) {
            return arena.dupe(u8, line[prefix.len..]) catch "";
        }
    }
    return "";
}

/// Simple entitlements parser for Apple plist XML.
/// Extracts key-value pairs from the flat structure.
fn parseEntitlements(xml: []const u8, arena: std.mem.Allocator) []const process.Entitlement {
    var entries: std.ArrayListUnmanaged(process.Entitlement) = .empty;

    var pos: usize = 0;
    while (pos < xml.len) {
        // Find <key>...</key>
        const key_start_tag = "<key>";
        const key_end_tag = "</key>";
        const ks = std.mem.indexOfPos(u8, xml, pos, key_start_tag) orelse break;
        const key_start = ks + key_start_tag.len;
        const ke = std.mem.indexOfPos(u8, xml, key_start, key_end_tag) orelse break;
        const key = xml[key_start..ke];
        pos = ke + key_end_tag.len;

        // Find the value tag (next <true/>, <false/>, <string>...</string>, <integer>...</integer>, <array>, etc.)
        // Skip whitespace
        while (pos < xml.len and (xml[pos] == ' ' or xml[pos] == '\t' or xml[pos] == '\n' or xml[pos] == '\r')) : (pos += 1) {}

        var value: []const u8 = "";
        if (pos < xml.len and xml[pos] == '<') {
            if (std.mem.startsWith(u8, xml[pos..], "<true/>")) {
                value = "true";
                pos += "<true/>".len;
            } else if (std.mem.startsWith(u8, xml[pos..], "<false/>")) {
                value = "false";
                pos += "<false/>".len;
            } else if (std.mem.startsWith(u8, xml[pos..], "<string>")) {
                const vs = pos + "<string>".len;
                if (std.mem.indexOfPos(u8, xml, vs, "</string>")) |ve| {
                    value = xml[vs..ve];
                    pos = ve + "</string>".len;
                }
            } else if (std.mem.startsWith(u8, xml[pos..], "<integer>")) {
                const vs = pos + "<integer>".len;
                if (std.mem.indexOfPos(u8, xml, vs, "</integer>")) |ve| {
                    value = xml[vs..ve];
                    pos = ve + "</integer>".len;
                }
            } else if (std.mem.startsWith(u8, xml[pos..], "<array")) {
                // Extract string items from array
                if (std.mem.indexOfPos(u8, xml, pos, "</array>")) |ae| {
                    const array_xml = xml[pos..ae];
                    value = extractArrayStrings(array_xml, arena);
                    pos = ae + "</array>".len;
                } else {
                    value = "(array)";
                    pos += 1;
                }
            } else if (std.mem.startsWith(u8, xml[pos..], "<dict")) {
                if (std.mem.indexOfPos(u8, xml, pos, "</dict>")) |de| {
                    const dict_xml = xml[pos..de];
                    value = extractDictEntries(dict_xml, arena);
                    pos = de + "</dict>".len;
                } else {
                    value = "(dict)";
                    pos += 1;
                }
            } else {
                pos += 1;
                continue;
            }
        }

        entries.append(arena, .{
            .key = arena.dupe(u8, key) catch continue,
            .value = arena.dupe(u8, value) catch continue,
        }) catch continue;
    }

    return entries.toOwnedSlice(arena) catch &.{};
}

/// Extract string values from an <array>...</array> XML fragment.
/// Returns a comma-separated string of items (strings, true/false, integers).
fn extractArrayStrings(array_xml: []const u8, arena: std.mem.Allocator) []const u8 {
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    var apos: usize = 0;
    var count: usize = 0;

    while (apos < array_xml.len) {
        if (std.mem.indexOfPos(u8, array_xml, apos, "<string>")) |ss| {
            const vs = ss + "<string>".len;
            if (std.mem.indexOfPos(u8, array_xml, vs, "</string>")) |se| {
                if (count > 0) parts.appendSlice(arena, ", ") catch break;
                parts.appendSlice(arena, array_xml[vs..se]) catch break;
                apos = se + "</string>".len;
                count += 1;
                continue;
            }
        }
        if (std.mem.indexOfPos(u8, array_xml, apos, "<true/>")) |ts| {
            if (count > 0) parts.appendSlice(arena, ", ") catch break;
            parts.appendSlice(arena, "true") catch break;
            apos = ts + "<true/>".len;
            count += 1;
            continue;
        }
        if (std.mem.indexOfPos(u8, array_xml, apos, "<false/>")) |fs| {
            if (count > 0) parts.appendSlice(arena, ", ") catch break;
            parts.appendSlice(arena, "false") catch break;
            apos = fs + "<false/>".len;
            count += 1;
            continue;
        }
        if (std.mem.indexOfPos(u8, array_xml, apos, "<integer>")) |is_| {
            const ivs = is_ + "<integer>".len;
            if (std.mem.indexOfPos(u8, array_xml, ivs, "</integer>")) |ie| {
                if (count > 0) parts.appendSlice(arena, ", ") catch break;
                parts.appendSlice(arena, array_xml[ivs..ie]) catch break;
                apos = ie + "</integer>".len;
                count += 1;
                continue;
            }
        }
        break;
    }

    if (parts.items.len == 0) return "(empty array)";
    return parts.toOwnedSlice(arena) catch "(array)";
}

/// Collect system-wide network statistics using getifaddrs() + AF_LINK.
/// Sums ifi_ipackets, ifi_opackets, ifi_ibytes, ifi_obytes across non-loopback interfaces.
pub fn collectNetworkStats() process.NetworkStats {
    var stats = process.NetworkStats{};

    var ifap: ?*c.ifaddrs = null;
    if (c.getifaddrs(&ifap) != 0) return stats;
    defer c.freeifaddrs(ifap);

    var ifa = ifap;
    while (ifa) |iface| : (ifa = iface.ifa_next) {
        // Only look at AF_LINK (data-link layer) entries
        if (iface.ifa_addr == null or iface.ifa_addr.*.sa_family != c.AF_LINK) continue;

        // Skip loopback interface
        if (iface.ifa_name != null) {
            const name = std.mem.sliceTo(iface.ifa_name, 0);
            if (std.mem.startsWith(u8, name, "lo")) continue;
        }

        // ifa_data points to struct if_data for AF_LINK entries
        if (iface.ifa_data) |data_ptr| {
            const if_data: *const c.if_data = @ptrCast(@alignCast(data_ptr));
            stats.packets_in += @intCast(if_data.ifi_ipackets);
            stats.packets_out += @intCast(if_data.ifi_opackets);
            stats.bytes_in += @intCast(if_data.ifi_ibytes);
            stats.bytes_out += @intCast(if_data.ifi_obytes);
        }
    }

    return stats;
}

/// Extract key=value pairs from a <dict>...</dict> XML fragment.
/// Returns a comma-separated string like "key1=value1, key2=value2".
fn extractDictEntries(dict_xml: []const u8, arena: std.mem.Allocator) []const u8 {
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    var dpos: usize = 0;
    var count: usize = 0;

    while (dpos < dict_xml.len) {
        // Find <key>...</key>
        const ks = std.mem.indexOfPos(u8, dict_xml, dpos, "<key>") orelse break;
        const key_start = ks + "<key>".len;
        const ke = std.mem.indexOfPos(u8, dict_xml, key_start, "</key>") orelse break;
        const key = dict_xml[key_start..ke];
        dpos = ke + "</key>".len;

        // Skip whitespace
        while (dpos < dict_xml.len and (dict_xml[dpos] == ' ' or dict_xml[dpos] == '\t' or dict_xml[dpos] == '\n' or dict_xml[dpos] == '\r')) : (dpos += 1) {}

        var val: []const u8 = "";
        if (dpos < dict_xml.len and dict_xml[dpos] == '<') {
            if (std.mem.startsWith(u8, dict_xml[dpos..], "<true/>")) {
                val = "true";
                dpos += "<true/>".len;
            } else if (std.mem.startsWith(u8, dict_xml[dpos..], "<false/>")) {
                val = "false";
                dpos += "<false/>".len;
            } else if (std.mem.startsWith(u8, dict_xml[dpos..], "<string>")) {
                const vs = dpos + "<string>".len;
                if (std.mem.indexOfPos(u8, dict_xml, vs, "</string>")) |ve| {
                    val = dict_xml[vs..ve];
                    dpos = ve + "</string>".len;
                }
            } else if (std.mem.startsWith(u8, dict_xml[dpos..], "<integer>")) {
                const vs = dpos + "<integer>".len;
                if (std.mem.indexOfPos(u8, dict_xml, vs, "</integer>")) |ve| {
                    val = dict_xml[vs..ve];
                    dpos = ve + "</integer>".len;
                }
            } else if (std.mem.startsWith(u8, dict_xml[dpos..], "<array")) {
                if (std.mem.indexOfPos(u8, dict_xml, dpos, "</array>")) |ae| {
                    val = extractArrayStrings(dict_xml[dpos..ae], arena);
                    dpos = ae + "</array>".len;
                } else {
                    val = "(array)";
                    dpos += 1;
                }
            } else if (std.mem.startsWith(u8, dict_xml[dpos..], "<dict")) {
                // Avoid infinite recursion — show as nested
                val = "(nested dict)";
                if (std.mem.indexOfPos(u8, dict_xml, dpos + 1, "</dict>")) |de| {
                    dpos = de + "</dict>".len;
                } else {
                    dpos += 1;
                }
            } else {
                dpos += 1;
                continue;
            }
        }

        if (count > 0) parts.appendSlice(arena, ", ") catch break;
        parts.appendSlice(arena, key) catch break;
        parts.append(arena, '=') catch break;
        parts.appendSlice(arena, val) catch break;
        count += 1;
    }

    if (parts.items.len == 0) return "(empty dict)";
    return parts.toOwnedSlice(arena) catch "(dict)";
}

fn makeConnection(pid: i32, coalition_id: u64, lport: u16, fport: u16, laddr: *const [16]u8, faddr: *const [16]u8, is_ipv6: bool, tcp_state: i32) process.TcpConnection {
    var conn: process.TcpConnection = .{
        .pid = pid,
        .coalition_id = coalition_id,
        .local_port = lport,
        .remote_port = fport,
        .local_addr = [_]u8{0} ** 46,
        .local_addr_len = 0,
        .remote_addr = [_]u8{0} ** 46,
        .remote_addr_len = 0,
        .state = process.TcpState.fromKernelState(tcp_state),
        .is_ipv6 = is_ipv6,
    };

    if (is_ipv6) {
        var local_buf: [c.INET6_ADDRSTRLEN]u8 = undefined;
        var remote_buf: [c.INET6_ADDRSTRLEN]u8 = undefined;

        const local_ptr = c.inet_ntop(c.AF_INET6, laddr, &local_buf, c.INET6_ADDRSTRLEN);
        const remote_ptr = c.inet_ntop(c.AF_INET6, faddr, &remote_buf, c.INET6_ADDRSTRLEN);

        if (local_ptr != null) {
            const local_str = std.mem.sliceTo(&local_buf, 0);
            const copy_len = @min(local_str.len, conn.local_addr.len);
            @memcpy(conn.local_addr[0..copy_len], local_str[0..copy_len]);
            conn.local_addr_len = @intCast(copy_len);
        }
        if (remote_ptr != null) {
            const remote_str = std.mem.sliceTo(&remote_buf, 0);
            const copy_len = @min(remote_str.len, conn.remote_addr.len);
            @memcpy(conn.remote_addr[0..copy_len], remote_str[0..copy_len]);
            conn.remote_addr_len = @intCast(copy_len);
        }
    } else {
        var local_buf: [c.INET_ADDRSTRLEN]u8 = undefined;
        var remote_buf: [c.INET_ADDRSTRLEN]u8 = undefined;

        const local_ptr = c.inet_ntop(c.AF_INET, laddr[12..16], &local_buf, c.INET_ADDRSTRLEN);
        const remote_ptr = c.inet_ntop(c.AF_INET, faddr[12..16], &remote_buf, c.INET_ADDRSTRLEN);

        if (local_ptr != null) {
            const local_str = std.mem.sliceTo(&local_buf, 0);
            const copy_len = @min(local_str.len, conn.local_addr.len);
            @memcpy(conn.local_addr[0..copy_len], local_str[0..copy_len]);
            conn.local_addr_len = @intCast(copy_len);
        }
        if (remote_ptr != null) {
            const remote_str = std.mem.sliceTo(&remote_buf, 0);
            const copy_len = @min(remote_str.len, conn.remote_addr.len);
            @memcpy(conn.remote_addr[0..copy_len], remote_str[0..copy_len]);
            conn.remote_addr_len = @intCast(copy_len);
        }
    }

    return conn;
}
