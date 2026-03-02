const std = @import("std");
const channel = @import("channel");
const platform = @import("platform");
const process = @import("process");

const _pid_t = process.pid_t;
const print = std.debug.print;

pub const ThreadArgs = struct {
    queue: *channel.EventQueue,
    running: *std.atomic.Value(bool),
    condition: *std.Thread.Condition,
    mutex: *std.Thread.Mutex,
};

var snapshot_count: usize = 0;
var has_startup_items: bool = false;

pub fn run(args: ThreadArgs) void {
    var watcher = platform.ExitWatcher.init() catch {
        print("procz: kqueue init failed, falling back to polling-only\n", .{});
        runPollingOnly(args);
        return;
    };
    defer watcher.deinit();

    while (args.running.load(.acquire)) {
        collectAndPush(args, &watcher);
        if (!args.running.load(.acquire)) break;
        drainExitsUntilTimeout(args, &watcher);
    }
}

fn collectAndPush(args: ThreadArgs, watcher: *platform.ExitWatcher) void {
    var batch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = batch_arena.allocator();

    const map = platform.collectSnapshot(arena) catch |err| {
        print("procz: producer snapshot failed: {}\n", .{err});
        batch_arena.deinit();
        return;
    };

    // Register all PIDs with kqueue for exit monitoring
    const count = map.count();
    const pid_slice = arena.alloc(_pid_t, count) catch {
        batch_arena.deinit();
        return;
    };
    var it = map.keyIterator();
    var i: usize = 0;
    while (it.next()) |key_ptr| {
        pid_slice[i] = key_ptr.*;
        i += 1;
    }
    watcher.registerPids(pid_slice);

    // Collect startup items: every snapshot for the first 20 (~60s),
    // then every 30th (~90s). Keeps retrying until found.
    const startup = if (!has_startup_items or snapshot_count < 20 or snapshot_count % 30 == 0)
        platform.collectStartupItems(arena)
    else
        &[_]process.StartupItem{};
    if (startup.len > 0) has_startup_items = true;
    snapshot_count +%= 1;

    var event = channel.Event{ .snapshot = .{
        .arena = batch_arena,
        .map = map,
        .timestamp_ns = std.time.nanoTimestamp(),
        .startup_items = startup,
    } };
    if (!pushEvent(args, &event)) {
        event.deinit();
    }
}

fn drainExitsUntilTimeout(args: ThreadArgs, watcher: *platform.ExitWatcher) void {
    // Poll kqueue in 500ms intervals for ~3s total
    const intervals: usize = 6;
    const interval_ns: u64 = 500 * std.time.ns_per_ms;

    for (0..intervals) |_| {
        if (!args.running.load(.acquire)) return;

        var exit_pids: [64]_pid_t = undefined;
        const n = watcher.pollExits(&exit_pids, interval_ns);

        for (exit_pids[0..n]) |pid| {
            var event = channel.Event{ .exit = pid };
            if (!pushEvent(args, &event)) {
                // exit events don't own memory, nothing to free
            }
        }
    }
}

/// Try to push an event with exponential backoff. Returns false if producer
/// was signalled to stop before the push succeeded.
fn pushEvent(args: ThreadArgs, event: *channel.Event) bool {
    const initial_backoff_ns: u64 = 100 * std.time.ns_per_us;
    const max_backoff_ns: u64 = 10 * std.time.ns_per_ms;
    var backoff_ns: u64 = initial_backoff_ns;

    while (!args.queue.tryPush(event.*)) {
        if (!args.running.load(.acquire)) return false;
        std.Thread.sleep(backoff_ns);
        backoff_ns = @min(backoff_ns * 2, max_backoff_ns);
    }
    return true;
}

fn runPollingOnly(args: ThreadArgs) void {
    while (args.running.load(.acquire)) {
        collectAndPushPollingOnly(args);
        if (!args.running.load(.acquire)) break;

        // Wait ~3s or until signalled to stop
        args.mutex.lock();
        defer args.mutex.unlock();
        args.condition.timedWait(args.mutex, 3 * std.time.ns_per_s) catch {};
    }
}

fn collectAndPushPollingOnly(args: ThreadArgs) void {
    var batch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = batch_arena.allocator();

    const map = platform.collectSnapshot(arena) catch |err| {
        print("procz: producer snapshot failed: {}\n", .{err});
        batch_arena.deinit();
        return;
    };

    const startup_items = if (!has_startup_items or snapshot_count < 20 or snapshot_count % 30 == 0)
        platform.collectStartupItems(arena)
    else
        &[_]process.StartupItem{};
    if (startup_items.len > 0) has_startup_items = true;
    snapshot_count +%= 1;

    var event = channel.Event{ .snapshot = .{
        .arena = batch_arena,
        .map = map,
        .timestamp_ns = std.time.nanoTimestamp(),
        .startup_items = startup_items,
    } };
    if (!pushEvent(args, &event)) {
        event.deinit();
    }
}
