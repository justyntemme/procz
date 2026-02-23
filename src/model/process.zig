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
    diskio_bytes_read: u64 = 0,
    diskio_bytes_written: u64 = 0,
    gpu_time_ns: u64 = 0,
    start_time_ns: i128 = 0,
};

// ---------------------------------------------------------------------------
// TCP connection types (for procz-detail network tab)
// ---------------------------------------------------------------------------

pub const TcpState = enum {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    close_wait,
    fin_wait_1,
    closing,
    last_ack,
    fin_wait_2,
    time_wait,
    unknown,

    pub fn label(self: TcpState) []const u8 {
        return switch (self) {
            .closed => "CLOSED",
            .listen => "LISTEN",
            .syn_sent => "SYN_SENT",
            .syn_received => "SYN_RECV",
            .established => "ESTABLISHED",
            .close_wait => "CLOSE_WAIT",
            .fin_wait_1 => "FIN_WAIT_1",
            .closing => "CLOSING",
            .last_ack => "LAST_ACK",
            .fin_wait_2 => "FIN_WAIT_2",
            .time_wait => "TIME_WAIT",
            .unknown => "UNKNOWN",
        };
    }

    pub fn fromKernelState(state_val: i32) TcpState {
        return switch (state_val) {
            0 => .closed,
            1 => .listen,
            2 => .syn_sent,
            3 => .syn_received,
            4 => .established,
            5 => .close_wait,
            6 => .fin_wait_1,
            7 => .closing,
            8 => .last_ack,
            9 => .fin_wait_2,
            10 => .time_wait,
            else => .unknown,
        };
    }
};

pub const TcpConnection = struct {
    pid: pid_t,
    coalition_id: u64,
    local_port: u16,
    remote_port: u16,
    local_addr: [46]u8,
    local_addr_len: u8,
    remote_addr: [46]u8,
    remote_addr_len: u8,
    state: TcpState,
    is_ipv6: bool,

    pub fn localAddrStr(self: *const TcpConnection) []const u8 {
        return self.local_addr[0..self.local_addr_len];
    }

    pub fn remoteAddrStr(self: *const TcpConnection) []const u8 {
        return self.remote_addr[0..self.remote_addr_len];
    }
};
