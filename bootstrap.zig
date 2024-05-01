// SPDX-FileCopyrightText: 2024 yanchan09 <yan@omg.lol>
//
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const log = std.log.scoped(.bootstrap);

const MountInfo = struct {
    dev: [:0]const u8,
    path: [:0]const u8,
    fstype: [:0]const u8,
};

const MOUNTS = [_]MountInfo{
    .{ .dev = "none", .path = "dev", .fstype = "devtmpfs" },
    .{ .dev = "none", .path = "sys", .fstype = "sysfs" },
    .{ .dev = "none", .path = "proc", .fstype = "proc" },
    .{ .dev = "none", .path = "tmp", .fstype = "tmpfs" },
    .{ .dev = "none", .path = "run", .fstype = "tmpfs" },
    .{ .dev = "none", .path = "var/lib/postgresql/data", .fstype = "tmpfs" },
};

const SyscallError = error{SyscallFailed};

fn checkResult(res: usize, what: [*:0]const u8) SyscallError!void {
    const errno = std.os.linux.getErrno(res);
    if (errno != .SUCCESS) {
        log.err("{s}: {s}", .{ what, @tagName(errno) });
        return SyscallError.SyscallFailed;
    }
}

const BootstrapInfo = struct {
    argv: [][:0]const u8,
    envp: [][:0]const u8,
};

var child_pid: usize = 0;

pub fn handle_sigchld() !void {
    var status: u32 = undefined;
    var result: usize = undefined;
    while (true) {
        result = std.os.linux.waitpid(-1, &status, std.os.linux.W.NOHANG);
        try checkResult(result, "waitpid");
        if (result == 0) break;
        std.log.info("Reaped child {}", .{result});
        if (result == child_pid) {
            std.log.info("Main process exited, shutting down", .{});
            result = std.os.linux.reboot(.MAGIC1, .MAGIC2, .RESTART, null);
            try checkResult(result, "reboot");
        }
    }
}

pub fn handle_signal(sig: i32) callconv(.C) void {
    if (sig == std.os.linux.SIG.CHLD) {
        handle_sigchld() catch {};
    }
}

pub fn main() !void {
    var result: usize = undefined;
    var socket: i32 = undefined;

    result = std.os.linux.socket(std.os.linux.AF.VSOCK, std.os.linux.SOCK.STREAM, 0);
    try checkResult(result, "socket");
    socket = @intCast(result);
    errdefer _ = std.os.linux.close(socket);

    result = std.os.linux.connect(socket, &std.os.linux.sockaddr.vm{
        .port = 1,
        .cid = 2,
        .flags = 0,
    }, @sizeOf(std.os.linux.sockaddr.vm));
    try checkResult(result, "connect");

    var out_header: [8]u8 = undefined;
    @memcpy(out_header[0..4], "HELO");
    std.mem.writeIntSliceLittle(u32, out_header[4..8], 0);
    // todo- partial writes :))
    result = std.os.linux.write(socket, &out_header, out_header.len);
    try checkResult(result, "write");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var alloc = arena.allocator();

    var bootstrap_info: BootstrapInfo = undefined;
    while (true) {
        var header: [8]u8 = undefined;
        var read_offs: u32 = 0;
        while (read_offs < header.len) {
            result = std.os.linux.read(socket, header[read_offs..].ptr, header.len - read_offs);
            try checkResult(result, "read");
            read_offs += @intCast(result);
        }

        const in_sz = std.mem.readIntSliceLittle(u32, header[4..8]);

        var payload_buf = try alloc.alloc(u8, in_sz);
        read_offs = 0;
        while (read_offs < payload_buf.len) {
            result = std.os.linux.read(socket, payload_buf[read_offs..].ptr, payload_buf.len - read_offs);
            try checkResult(result, "read");
            read_offs += @intCast(result);
        }

        if (std.mem.eql(u8, header[0..4], "HELO")) {
            bootstrap_info = try std.json.parseFromSliceLeaky(BootstrapInfo, alloc, payload_buf, .{});
            break;
        }

        _ = arena.reset(.retain_capacity);
    }

    result = std.os.linux.close(socket);
    try checkResult(result, "close");

    log.info("Mounting devtmpfs on /dev", .{});
    result = std.os.linux.mount("none", "/dev", "devtmpfs", 0, 0);
    checkResult(result, "mount") catch {};

    log.info("Mounting /dev/vda on /newroot", .{});
    result = std.os.linux.mount("/dev/vda", "/newroot", "erofs", std.os.linux.MS.RDONLY, 0);
    try checkResult(result, "mount");

    result = std.os.linux.chdir("/newroot");
    try checkResult(result, "chdir");

    log.info("Switching root", .{});
    result = std.os.linux.mount(".", "/", null, std.os.linux.MS.MOVE, 0);
    try checkResult(result, "mount");
    result = std.os.linux.chroot(".");
    try checkResult(result, "chroot");

    var old_sigset: std.os.linux.sigset_t = undefined;
    var new_sigset: std.os.linux.sigset_t = undefined;
    @memset(&new_sigset, std.math.maxInt(u32));

    // Block signals until we're ready to handle them
    result = std.os.linux.sigprocmask(std.os.linux.SIG.SETMASK, &new_sigset, &old_sigset);
    try checkResult(result, "sigprocmask");

    result = std.os.linux.unshare(std.os.linux.CLONE.NEWPID);
    try checkResult(result, "unshare");

    result = std.os.linux.fork();
    try checkResult(result, "fork");
    child_pid = result;

    if (child_pid == 0) {
        for (MOUNTS) |mnt| {
            log.info("mount: ({s}) {s} -> {s}", .{ mnt.fstype, mnt.dev, mnt.path });
            result = std.os.linux.mount(mnt.dev.ptr, mnt.path.ptr, mnt.fstype.ptr, 0, 0);
            checkResult(result, "mount") catch {};
        }

        log.info("Linking /dev/fd to /proc/self/fd", .{});
        result = std.os.linux.symlink("/proc/self/fd", "/dev/fd");
        checkResult(result, "symlink") catch {};

        const exe = bootstrap_info.argv[0];
        const argv = try alloc.allocSentinel(?[*:0]const u8, bootstrap_info.argv.len, null);
        for (0.., bootstrap_info.argv) |i, e| {
            argv[i] = e;
        }
        const envp = try alloc.allocSentinel(?[*:0]const u8, bootstrap_info.envp.len, null);
        for (0.., bootstrap_info.envp) |i, e| {
            envp[i] = e;
        }
        // Restore signals for the child
        result = std.os.linux.sigprocmask(std.os.linux.SIG.SETMASK, &old_sigset, null);
        try checkResult(result, "sigprocmask");
        result = std.os.linux.syscall0(.setsid);
        try checkResult(result, "setsid");
        result = std.os.linux.execve(exe, argv.ptr, envp.ptr);
        try checkResult(result, "execve");
        unreachable;
    }

    arena.deinit();

    std.log.info("Child started as PID {}", .{child_pid});

    // Set up a handler for SIGCHLD
    var sigmask: std.os.linux.sigset_t = undefined;
    @memset(&sigmask, std.math.maxInt(u32));
    result = std.os.linux.sigaction(std.os.linux.SIG.CHLD, &.{
        .handler = .{ .handler = handle_signal },
        .mask = sigmask,
        .flags = 0,
    }, null);
    try checkResult(result, "sigaction");

    // Unblock SIGCHLD
    var unblock_sigmask = std.os.linux.empty_sigset;
    std.os.linux.sigaddset(&unblock_sigmask, std.os.linux.SIG.CHLD);
    result = std.os.linux.sigprocmask(std.os.linux.SIG.UNBLOCK, &unblock_sigmask, null);
    try checkResult(result, "sigprocmask");

    // Wait for things to happen
    while (true) {
        std.time.sleep(std.time.ns_per_s);
    }
}
