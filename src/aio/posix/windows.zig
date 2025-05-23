const std = @import("std");
const ops = @import("../ops.zig");
const Link = @import("minilib").Link;
const win32 = @import("win32");

const FILE_SKIP_COMPLETION_PORT_ON_SUCCESS = win32.system.windows_programming.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS;
const GetLastError = win32.foundation.GetLastError;
const CloseHandle = win32.foundation.CloseHandle;
const INVALID_HANDLE = win32.foundation.INVALID_HANDLE_VALUE;
const HANDLE = win32.foundation.HANDLE;
const console = win32.system.console;
const win_sock = win32.networking.win_sock;
const io = win32.system.io;

pub fn unexpectedError(err: win32.foundation.WIN32_ERROR) error{Unexpected} {
    return std.os.windows.unexpectedError(@enumFromInt(@intFromEnum(err)));
}

pub fn unexpectedWSAError(err: win32.networking.win_sock.WSA_ERROR) error{Unexpected} {
    return std.os.windows.unexpectedWSAError(@enumFromInt(@intFromEnum(err)));
}

pub fn wtry(ret: anytype) !@TypeOf(ret) {
    const wbool: win32.foundation.BOOL = switch (@TypeOf(ret)) {
        bool => @intFromBool(ret),
        else => ret,
    };
    if (wbool == 0) {
        switch (GetLastError()) {
            .ERROR_IO_PENDING => {}, // not error
            else => |r| return unexpectedError(r),
        }
    }
    return ret;
}

pub fn checked(ret: anytype) void {
    _ = wtry(ret) catch unreachable;
}

// Light wrapper, mainly to link EventSources to this
pub const Iocp = struct {
    pub const Key = packed struct(usize) {
        type: enum(u8) {
            nop,
            shutdown,
            event_source,
            child_exit,
            overlapped,
        },
        // The ID is only used for custom events, for CreateIoCompletionPort assocations its useless,
        // as it prevents from having multiple keys for a single handle:
        // > Use the CompletionKey parameter to help your application track which I/O operations have completed.
        // > This value is not used by CreateIoCompletionPort for functional control; rather, it is attached to
        // > the file handle specified in the FileHandle parameter at the time of association with an I/O completion port.
        // > This completion key should be unique for each file handle, and it accompanies the file handle throughout the
        // > internal completion queuing process.
        id: ops.Id,
        _: std.meta.Int(.unsigned, @bitSizeOf(usize) - @bitSizeOf(u8) - @bitSizeOf(ops.Id)) = undefined,
    };

    port: HANDLE,
    num_threads: u32,

    pub fn init(num_threads: u32) !@This() {
        const port = io.CreateIoCompletionPort(INVALID_HANDLE, null, 0, num_threads).?;
        _ = try wtry(port != INVALID_HANDLE);
        errdefer checked(CloseHandle(port));
        return .{ .port = port, .num_threads = num_threads };
    }

    pub fn notify(self: *@This(), key: Key, ptr: ?*anyopaque) void {
        // data for notification is put into the transferred bytes, overlapped can be anything
        checked(io.PostQueuedCompletionStatus(self.port, 0, @bitCast(key), @ptrCast(@alignCast(ptr))));
    }

    pub fn deinit(self: *@This()) void {
        // docs say that GetQueuedCompletionStatus should return if IOCP port is closed
        // this doesn't seem to happen under wine though (wine bug?)
        // anyhow, wakeup the drain thread by hand
        for (0..self.num_threads) |_| self.notify(.{ .type = .shutdown, .id = undefined }, null);
        checked(CloseHandle(self.port));
        self.* = undefined;
    }

    pub fn associateHandle(self: *@This(), _: ops.Id, handle: HANDLE) !void {
        const fs = win32.storage.file_system;
        const key: Key = .{ .type = .overlapped, .id = undefined };
        _ = try wtry(fs.SetFileCompletionNotificationModes(handle, FILE_SKIP_COMPLETION_PORT_ON_SUCCESS));
        const res = io.CreateIoCompletionPort(handle, self.port, @bitCast(key), 0);
        if (res == null or res.? == INVALID_HANDLE) {
            // ignore 87 as it may mean that we just re-registered the handle
            if (GetLastError() == .ERROR_INVALID_PARAMETER) return;
            _ = try wtry(@as(i32, 0));
        }
    }

    pub fn associateSocket(self: *@This(), id: ops.Id, sock: std.posix.socket_t) !void {
        return self.associateHandle(id, @ptrCast(sock));
    }
};

pub const EventSource = struct {
    pub const OperationContext = struct {
        id: ops.Id,
        iocp: *Iocp,
        link: WaitList.Node = .{},
    };

    pub const WaitList = std.SinglyLinkedList;

    waiters: WaitList = .{},
    semaphore: std.Thread.Semaphore = .{},

    pub fn init() !@This() {
        return .{};
    }

    pub fn deinit(self: *@This()) void {
        std.debug.assert(self.waiters.first == null); // having dangling waiters is bad
        self.* = undefined;
    }

    pub fn notify(self: *@This()) void {
        const notified_one = blk: {
            self.semaphore.mutex.lock();
            defer self.semaphore.mutex.unlock();
            if (self.waiters.popFirst()) |w| {
                const ctx: *OperationContext = @fieldParentPtr("link", w);
                ctx.iocp.notify(.{ .type = .event_source, .id = ctx.id }, self);
                break :blk true;
            }
            break :blk false;
        };
        if (!notified_one) self.semaphore.post();
    }

    pub fn waitNonBlocking(self: *@This()) error{WouldBlock}!void {
        self.semaphore.timedWait(0) catch return error.WouldBlock;
    }

    pub fn wait(self: *@This()) void {
        self.semaphore.wait();
    }

    pub fn addWaiter(self: *@This(), node: *WaitList.Node) void {
        self.semaphore.mutex.lock();
        defer self.semaphore.mutex.unlock();
        self.waiters.prepend(node);
    }

    pub fn removeWaiter(self: *@This(), node: *WaitList.Node) error{NotFound}!void {
        {
            self.semaphore.mutex.lock();
            defer self.semaphore.mutex.unlock();
            // safer list.remove ...
            if (self.waiters.first == node) {
                self.waiters.first = node.next;
            } else if (self.waiters.first) |first| {
                var current_elm = first;
                while (current_elm.next != node) {
                    if (current_elm.next == null) return error.NotFound;
                    current_elm = current_elm.next.?;
                }
                current_elm.next = node.next;
            }
        }
        node.* = .{};
    }
};

pub fn translateTty(_: std.posix.fd_t, _: []u8, _: *ops.ReadTty.TranslationState) ops.ReadTty.Error!usize {
    if (true) @panic("TODO");
    return 0;
}

pub fn readTty(fd: std.posix.fd_t, buf: []u8, mode: ops.ReadTty.Mode) ops.ReadTty.Error!usize {
    return switch (mode) {
        .direct => {
            if (buf.len < @sizeOf(console.INPUT_RECORD)) {
                return error.NoSpaceLeft;
            }
            var read: u32 = 0;
            const n_fits: u32 = @intCast(buf.len / @sizeOf(console.INPUT_RECORD));
            if (console.ReadConsoleInputW(fd, @ptrCast(@alignCast(buf.ptr)), n_fits, &read) == 0) {
                return unexpectedError(GetLastError());
            }
            return read * @sizeOf(console.INPUT_RECORD);
        },
        .translation => |state| translateTty(fd, buf, state),
    };
}

pub const PendingOrTransmitted = union(enum) {
    transmitted: usize,
    pending: void,
};

pub fn sendEx(sockfd: std.posix.socket_t, buf: [*]win_sock.WSABUF, flags: u32, overlapped: ?*io.OVERLAPPED) !PendingOrTransmitted {
    var written: u32 = 0;
    while (true) {
        const rc = win_sock.WSASend(sockfd, buf, 1, &written, flags, overlapped, null);
        if (rc == win_sock.SOCKET_ERROR) {
            switch (win_sock.WSAGetLastError()) {
                .EWOULDBLOCK, .EINTR, .EINPROGRESS => continue,
                ._IO_PENDING => if (overlapped != null) return .pending else unreachable,
                .EACCES => return error.AccessDenied,
                .EADDRNOTAVAIL => return error.AddressNotAvailable,
                .ECONNRESET => return error.ConnectionResetByPeer,
                .EMSGSIZE => return error.MessageTooBig,
                .ENOBUFS => return error.SystemResources,
                .ENOTSOCK => return error.FileDescriptorNotASocket,
                .EAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .EDESTADDRREQ => unreachable, // A destination address is required.
                .EFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                .EHOSTUNREACH => return error.NetworkUnreachable,
                .EINVAL => unreachable,
                .ENETDOWN => return error.NetworkSubsystemFailed,
                .ENETRESET => return error.ConnectionResetByPeer,
                .ENETUNREACH => return error.NetworkUnreachable,
                .ENOTCONN => return error.SocketNotConnected,
                .ESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                .NOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                else => |err| return unexpectedWSAError(err),
            }
        }
        break;
    }
    return .{ .transmitted = @intCast(written) };
}

pub fn recvEx(sockfd: std.posix.socket_t, buf: [*]win_sock.WSABUF, flags: u32, overlapped: ?*io.OVERLAPPED) !PendingOrTransmitted {
    var read: u32 = 0;
    var inout_flags: u32 = flags;
    while (true) {
        const rc = win_sock.WSARecv(sockfd, buf, 1, &read, &inout_flags, overlapped, null);
        if (rc == win_sock.SOCKET_ERROR) {
            switch (win_sock.WSAGetLastError()) {
                .EWOULDBLOCK, .EINTR, .EINPROGRESS => continue,
                ._IO_PENDING => if (overlapped != null) return .pending else unreachable,
                .EACCES => return error.AccessDenied,
                .EADDRNOTAVAIL => return error.AddressNotAvailable,
                .ECONNRESET => return error.ConnectionResetByPeer,
                .EMSGSIZE => return error.MessageTooBig,
                .ENOBUFS => return error.SystemResources,
                .ENOTSOCK => return error.FileDescriptorNotASocket,
                .EAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .EDESTADDRREQ => unreachable, // A destination address is required.
                .EFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                .EHOSTUNREACH => return error.NetworkUnreachable,
                .EINVAL => unreachable,
                .ENETDOWN => return error.NetworkSubsystemFailed,
                .ENETRESET => return error.ConnectionResetByPeer,
                .ENETUNREACH => return error.NetworkUnreachable,
                .ENOTCONN => return error.SocketNotConnected,
                .ESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                .NOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                else => |err| return unexpectedWSAError(err),
            }
        }
        break;
    }
    return .{ .transmitted = @intCast(read) };
}

pub const MSG = struct {
    pub const DONTWAIT = 0x0;
    pub const NOSIGNAL = 0x0;
    pub const PEEK: u32 = @bitCast(win_sock.MSG_PEEK);
    pub const PARTIAL: u32 = @bitCast(win_sock.MSG_PARTIAL);
    pub const DONTROUTE: u32 = @bitCast(win_sock.MSG_DONTROUTE);
    pub const OOB: u32 = @bitCast(win_sock.MSG_OOB);
    pub const PUSH_IMMEDIATE: u32 = @bitCast(win_sock.MSG_PUSH_IMMEDIATE);
    pub const WAITALL: u32 = @bitCast(win_sock.WAITALL);
};

pub const iovec = extern struct {
    len: u32,
    base: [*]u8,
};

pub const iovec_const = extern struct {
    len: u32,
    base: [*]const u8,
};

pub fn readv(fd: std.posix.fd_t, iov: []const iovec) std.posix.ReadError!usize {
    return std.posix.readv(fd, @ptrCast(iov));
}

pub fn preadv(fd: std.posix.fd_t, iov: []const iovec, off: usize) std.posix.PReadError!usize {
    return std.posix.preadv(fd, @ptrCast(iov), off);
}

pub fn writev(fd: std.posix.fd_t, iov: []const iovec_const) std.posix.WriteError!usize {
    return std.posix.writev(fd, @ptrCast(iov));
}

pub fn pwritev(fd: std.posix.fd_t, iov: []const iovec_const, off: usize) std.posix.PWriteError!usize {
    return std.posix.pwritev(fd, @ptrCast(iov), off);
}

pub const msghdr = extern struct {
    name: ?*std.posix.sockaddr,
    namelen: std.posix.socklen_t,
    iov: [*]iovec,
    iovlen: i32,
    controllen: std.posix.socklen_t,
    control: ?*anyopaque,
    _: std.meta.Int(.unsigned, @bitSizeOf(usize) + 32 - 32) = 0, // padding
    flags: i32,
};

pub const msghdr_const = extern struct {
    name: ?*const std.posix.sockaddr,
    namelen: std.posix.socklen_t,
    iov: [*]const iovec_const,
    iovlen: i32,
    controllen: std.posix.socklen_t,
    control: ?*anyopaque,
    _: std.meta.Int(.unsigned, @bitSizeOf(usize) + 32 - 32) = 0, // padding
    flags: i32,
};

comptime {
    std.debug.assert(@sizeOf(iovec) == @sizeOf(win_sock.WSABUF));
    std.debug.assert(@sizeOf(msghdr) == @sizeOf(win_sock.WSAMSG));
    std.debug.assert(@sizeOf(msghdr_const) == @sizeOf(win_sock.WSAMSG));
}

pub fn sendmsgEx(sockfd: std.posix.socket_t, msg: *const msghdr_const, flags: u32, overlapped: ?*io.OVERLAPPED) !PendingOrTransmitted {
    var written: u32 = 0;
    while (true) {
        const rc = win_sock.WSASendMsg(sockfd, @constCast(@ptrCast(msg)), flags, &written, overlapped, null);
        if (rc == win_sock.SOCKET_ERROR) {
            switch (win_sock.WSAGetLastError()) {
                .EWOULDBLOCK, .EINTR, .EINPROGRESS => continue,
                ._IO_PENDING => if (overlapped != null) return .pending else unreachable,
                .EACCES => return error.AccessDenied,
                .EADDRNOTAVAIL => return error.AddressNotAvailable,
                .ECONNRESET => return error.ConnectionResetByPeer,
                .EMSGSIZE => return error.MessageTooBig,
                .ENOBUFS => return error.SystemResources,
                .ENOTSOCK => return error.FileDescriptorNotASocket,
                .EAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .EDESTADDRREQ => unreachable, // A destination address is required.
                .EFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                .EHOSTUNREACH => return error.NetworkUnreachable,
                .EINVAL => unreachable,
                .ENETDOWN => return error.NetworkSubsystemFailed,
                .ENETRESET => return error.ConnectionResetByPeer,
                .ENETUNREACH => return error.NetworkUnreachable,
                .ENOTCONN => return error.SocketNotConnected,
                .ESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                .NOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                else => |err| return unexpectedWSAError(err),
            }
        }
        break;
    }
    return .{ .transmitted = @intCast(written) };
}

pub fn sendmsg(sockfd: std.posix.socket_t, msg: *const msghdr_const, flags: u32) !usize {
    return sendmsgEx(sockfd, msg, flags, null);
}

pub fn recvmsgEx(sockfd: std.posix.socket_t, msg: *msghdr, _: u32, overlapped: ?*io.OVERLAPPED) !PendingOrTransmitted {
    const DumbStuff = struct {
        var once = std.once(do_once);
        var fun: win_sock.LPFN_WSARECVMSG = undefined;
        var have_fun = false;
        fn do_once() void {
            const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch unreachable;
            defer std.posix.close(sock);
            var trash: u32 = 0;
            const res = win_sock.WSAIoctl(
                sock,
                win_sock.SIO_GET_EXTENSION_FUNCTION_POINTER,
                // not in zigwin32
                @constCast(@ptrCast(&std.os.windows.ws2_32.WSAID_WSARECVMSG)),
                @sizeOf(std.os.windows.GUID),
                @ptrCast(&fun),
                @sizeOf(@TypeOf(fun)),
                &trash,
                null,
                null,
            );
            have_fun = res != win_sock.SOCKET_ERROR;
        }
    };
    DumbStuff.once.call();
    if (!DumbStuff.have_fun) return error.Unexpected;
    var read: u32 = 0;
    while (true) {
        const rc = DumbStuff.fun(sockfd, @ptrCast(msg), &read, overlapped, null);
        if (rc == win_sock.SOCKET_ERROR) {
            switch (win_sock.WSAGetLastError()) {
                .EWOULDBLOCK, .EINTR, .EINPROGRESS => continue,
                ._IO_PENDING => if (overlapped != null) return .pending else unreachable,
                .EACCES => return error.AccessDenied,
                .EADDRNOTAVAIL => return error.AddressNotAvailable,
                .ECONNRESET => return error.ConnectionResetByPeer,
                .EMSGSIZE => return error.MessageTooBig,
                .ENOBUFS => return error.SystemResources,
                .ENOTSOCK => return error.FileDescriptorNotASocket,
                .EAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .EDESTADDRREQ => unreachable, // A destination address is required.
                .EFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                .EHOSTUNREACH => return error.NetworkUnreachable,
                .EINVAL => unreachable,
                .ENETDOWN => return error.NetworkSubsystemFailed,
                .ENETRESET => return error.ConnectionResetByPeer,
                .ENETUNREACH => return error.NetworkUnreachable,
                .ENOTCONN => return error.SocketNotConnected,
                .ESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                .NOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                else => |err| return unexpectedWSAError(err),
            }
        }
        break;
    }
    return .{ .transmitted = @intCast(read) };
}

pub fn recvmsg(sockfd: std.posix.socket_t, msg: *msghdr, flags: u32) !usize {
    return recvmsgEx(sockfd, msg, flags, null);
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) std.posix.SocketError!std.posix.socket_t {
    // NOTE: windows translates the SOCK.NONBLOCK/SOCK.CLOEXEC flags into
    // windows-analagous operations
    const filtered_sock_type = socket_type & ~@as(u32, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC);
    const flags: u32 = if ((socket_type & std.posix.SOCK.CLOEXEC) != 0)
        std.os.windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT
    else
        0;
    const rc = try std.os.windows.WSASocketW(
        @bitCast(domain),
        @bitCast(filtered_sock_type),
        @bitCast(protocol),
        null,
        0,
        flags | std.os.windows.ws2_32.WSA_FLAG_OVERLAPPED,
    );
    errdefer std.os.windows.closesocket(rc) catch unreachable;
    if ((socket_type & std.posix.SOCK.NONBLOCK) != 0) {
        var mode: c_ulong = 1; // nonblocking
        if (std.os.windows.ws2_32.SOCKET_ERROR == std.os.windows.ws2_32.ioctlsocket(rc, std.os.windows.ws2_32.FIONBIO, &mode)) {
            switch (std.os.windows.ws2_32.WSAGetLastError()) {
                // have not identified any error codes that should be handled yet
                else => unreachable,
            }
        }
    }
    return rc;
}
