//! Basically `std.Thread.Pool` but supports timeout
//! That is, if threads have been inactive for specific timeout the pool will release the threads

const builtin = @import("builtin");
const std = @import("std");

const DefaultImpl = struct {
    const DynamicThread = struct {
        active: bool = false,
        thread: ?std.Thread = null,
    };

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    threads: []DynamicThread = &.{},
    run_queue: std.SinglyLinkedList = .{},
    idling_threads: u32 = 0,
    active_threads: u32 = 0,
    timeout: u64,
    // used to serialize the acquisition order
    serial: std.DynamicBitSetUnmanaged,
    name: ?[]const u8,
    stack_size: usize,

    const Runnable = struct {
        runFn: RunProto,
        node: std.SinglyLinkedList.Node = .{},
    };
    const RunProto = *const fn (*@This(), *Runnable) void;

    pub const Options = struct {
        // Use the cpu core count by default
        max_threads: ?u32 = null,
        // Inactivity timeout when the thread will be joined
        timeout: u64 = 5 * std.time.ns_per_s,
        // Name for the threads
        name: ?[]const u8 = null,
        // Stack size for the threads
        stack_size: usize = (std.Thread.SpawnConfig{}).stack_size,
    };

    fn getCpuCount() usize {
        const root = @import("root");
        return switch (builtin.target.os.tag) {
            .wasi => if (@hasDecl(root, "wasi_thread_count")) root.wasi_thread_count else 1,
            else => std.Thread.getCpuCount() catch 1,
        };
    }

    pub const InitError = error{ OutOfMemory, Unsupported };

    pub fn init(allocator: std.mem.Allocator, options: Options) InitError!@This() {
        _ = std.time.Timer.start() catch return error.Unsupported; // check that we have a timer

        const thread_count = @max(1, options.max_threads orelse getCpuCount());

        var serial = try std.DynamicBitSetUnmanaged.initEmpty(allocator, thread_count);
        errdefer serial.deinit(allocator);
        const threads = try allocator.alloc(DynamicThread, thread_count);
        errdefer allocator.free(threads);
        @memset(threads, .{});
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .timeout = options.timeout,
            .serial = serial,
            .threads = threads,
            .name = options.name,
            .stack_size = options.stack_size,
        };
    }

    pub fn deinit(self: *@This()) void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.threads) |*dthread| dthread.active = false;
        }
        self.cond.broadcast();
        for (self.threads) |*dthread| if (dthread.thread) |thrd| thrd.join();
        self.allocator.free(self.threads);
        self.serial.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub const SpawnError = error{
        OutOfMemory,
        SystemResources,
        LockedMemoryLimitExceeded,
        ThreadQuotaExceeded,
        Unexpected,
    };

    pub fn spawn(self: *@This(), comptime func: anytype, args: anytype) SpawnError!void {
        const Args = @TypeOf(args);
        const ThreadPool = @This();
        const Closure = struct {
            arguments: Args,
            runnable: Runnable = .{ .runFn = runFn },

            fn runFn(pool: *ThreadPool, runnable: *Runnable) void {
                const closure: *@This() = @alignCast(@fieldParentPtr("runnable", runnable));
                @call(.auto, func, closure.arguments);
                // The thread pool's allocator is protected by the mutex.
                pool.mutex.lock();
                defer pool.mutex.unlock();
                pool.arena.allocator().destroy(closure);
            }
        };

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Activate a new thread if the run queue is running hot
            if (self.idling_threads == 0 and self.active_threads < self.threads.len) {
                for (self.threads[self.active_threads..], 0..) |*dthread, off| {
                    if (!dthread.active and dthread.thread == null) {
                        const id = self.active_threads + off;
                        dthread.active = true;
                        self.serial.unset(id);
                        self.active_threads += 1;
                        dthread.thread = try std.Thread.spawn(
                            .{ .allocator = self.allocator },
                            worker,
                            .{ self, dthread, @as(u32, @intCast(id)), self.timeout },
                        );
                        break;
                    }
                }
            }

            // TODO: Optimize closure allocations
            //       Closures are often same size, so they can be bucketed and reused
            const closure = try self.arena.allocator().create(Closure);
            closure.* = .{ .arguments = args };
            self.run_queue.prepend(&closure.runnable.node);
        }

        // Notify waiting threads outside the lock to try and keep the critical section small.
        // Wake up all the threads so they can figure out their acquisition order
        // Threads that don't seem to get much work will die out by itself
        self.cond.broadcast();
    }

    fn yield() std.Thread.YieldError!void {
        return switch (builtin.target.os.tag) {
            .wasi => switch (std.os.wasi.sched_yield()) {
                .SUCCESS => return,
                .NOSYS => return error.SystemCannotYield,
                else => return error.SystemCannotYield,
            },
            else => std.Thread.yield(),
        };
    }

    fn worker(self: *@This(), thread: *DynamicThread, id: u32, timeout: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.name) |name| thread.thread.?.setName(name) catch {};

        var timer = std.time.Timer.start() catch unreachable;
        main: while (thread.active) {
            // Serialize the acquisition order here so that threads will always pop the run queue in order
            // this makes the busy threads always be at the beginning of the array,
            // while less busy or dead threads are at the end
            // If a thread keeps getting out done by the earlier threads, it will time out
            const can_work: bool = blk: {
                outer: while (id > 0 and thread.active) {
                    if (self.run_queue.first == null) {
                        // We were outraced, go back to sleep
                        break :blk false;
                    }
                    if (timer.read() >= timeout) break :main;
                    for (0..id) |idx| if (!self.serial.isSet(idx)) {
                        self.mutex.unlock();
                        defer self.mutex.lock();
                        yield() catch {};
                        continue :outer;
                    };
                    break :outer;
                }
                break :blk true;
            };

            if (can_work) {
                self.serial.set(id);
                defer self.serial.unset(id);
                while (thread.active) {
                    if (self.run_queue.popFirst()) |run_node| {
                        self.mutex.unlock();
                        defer self.mutex.lock();
                        const runnable: *Runnable = @fieldParentPtr("node", run_node);
                        runnable.runFn(self, runnable);
                        timer.reset();
                    } else break;
                }
            }

            if (thread.active) {
                const now = timer.read();
                if (now >= timeout) break :main;
                if (self.run_queue.first == null) {
                    self.idling_threads += 1;
                    defer self.idling_threads -= 1;
                    self.cond.timedWait(&self.mutex, timeout - now) catch break :main;
                }
            }
        }

        self.active_threads -= 1;

        // This thread won't partipicate in the acquisition order anymore
        // In case there are threads further in the queue don't block them if there's a burst of work
        self.serial.set(id);

        if (thread.active) {
            // timed out
            thread.active = false;
            // the thread cleans up itself from here on
            thread.thread.?.detach();
            thread.thread = null;
        }
    }
};

const SingleThreadedImpl = struct {
    pub const Options = DefaultImpl.Options;

    pub const InitError = DefaultImpl.InitError;

    pub fn init(_: std.mem.Allocator, _: Options) InitError!@This() {
        return .{};
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub const SpawnError = DefaultImpl.SpawnError;

    pub fn spawn(_: *@This(), comptime _: anytype, _: anytype) SpawnError!void {
        @panic("DynamicThreadPool is not available on single-threaded build");
    }
};

pub const DynamicThreadPool = switch (builtin.single_threaded) {
    true => SingleThreadedImpl,
    false => DefaultImpl,
};
