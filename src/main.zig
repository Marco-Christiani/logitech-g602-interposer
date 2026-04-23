//
// const c = @import("c");
//
// pub fn main(init: std.process.Init) !void {
//     std.debug.print("{any}\n", .{c.POLLIN});
//
//     const arena: std.mem.Allocator = init.arena.allocator();
//
//     const args = try init.minimal.args.toSlice(arena);
//     for (args) |arg| {
//         std.log.info("arg: {s}", .{arg});
//     }
//
//     const io = init.io;
//
//     var stdout_buffer: [1024]u8 = undefined;
//     var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
//     const stdout_writer = &stdout_file_writer.interface;
//     try stdout_writer.flush();
// }
const std = @import("std");
const c = @import("c");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const hidraw_path: [*:0]const u8 = "/dev/hidraw4";

    // keyboard-emulation event node for the target
    const evdev_path: [*:0]const u8 = "/dev/input/event4";

    const hidraw_fd = try openHidraw(hidraw_path);
    defer _ = c.close(hidraw_fd);

    const evdev_fd = try openAndGrabEvdev(evdev_path);
    defer ungrabAndCloseEvdev(evdev_fd);

    const uinput_fd = try setupUinput(io);
    defer {
        _ = c.ioctl(uinput_fd, c.UI_DEV_DESTROY);
        _ = c.close(uinput_fd);
    }

    var held_masks: u16 = 0;

    var fds = [_]c.pollfd{
        .{
            .fd = hidraw_fd,
            .events = c.POLLIN,
            .revents = 0,
        },
        .{
            .fd = evdev_fd,
            .events = c.POLLIN,
            .revents = 0,
        },
    };

    while (true) {
        fds[0].revents = 0;
        fds[1].revents = 0;

        const rc = c.poll(&fds, fds.len, -1);
        try syscallOk(rc);

        if ((fds[0].revents & c.POLLIN) != 0) {
            switch (try readOneHidrawReport(hidraw_fd)) {
                .button_press => |mask| try handleButtonPress(uinput_fd, &held_masks, mask),
                .button_release => try releaseAllHeld(uinput_fd, &held_masks),
                .other => {},
            }
        }

        if ((fds[1].revents & c.POLLIN) != 0) {
            try drainSuppressedEvdev(evdev_fd);
        }
    }
}

const HidrawReport = union(enum) {
    button_press: u16,
    button_release,
    other,
};

const timeval = extern struct {
    tv_sec: c.__kernel_long_t = 0,
    tv_usec: c.__kernel_long_t = 0,
};

const input_event = extern struct {
    time: timeval = .{},
    type: u16,
    code: u16,
    value: i32,
};

const input_id = extern struct {
    bustype: u16 = 0,
    vendor: u16 = 0,
    product: u16 = 0,
    version: u16 = 0,
};

const uinput_setup = extern struct {
    id: input_id = .{},
    name: [80]u8 = [_]u8{0} ** 80,
    ff_effects_max: u32 = 0,
};

fn syscallOk(rc: anytype) !void {
    if (rc < 0) return error.SyscallFailed;
}

fn parseHidrawReport(buf: []const u8) HidrawReport {
    // Physical button identity report:
    //   [0x80, mask_lo, mask_hi, 0x80, 0x00]
    if (buf.len == 5 and buf[0] == 0x80 and buf[3] == 0x80 and buf[4] == 0x00) {
        const mask = std.mem.readInt(u16, buf[1..3], .little);
        if (mask == 0) return .button_release;
        std.debug.print("+decoded press: mask=0x{x}\n", .{mask});
        return .{ .button_press = mask };
    }

    // Keyboard report from the mouse:
    //   [0x01, modifiers, key1, key2, key3, key4, key5, key6]
    // We intentionally ignore it here.
    return .other;
}

fn mapMaskToKey(mask: u16) ?u16 {
    return switch (mask) {
        // 0x0008 => c.KEY_F13, // G4
        0x0008 => c.KEY_A, // G4
        0x0010 => c.KEY_F14, // G5
        0x0020 => c.KEY_F15, // G6
        0x0040 => c.KEY_F16, // G7
        0x0080 => c.KEY_F17, // G8
        0x0100 => c.KEY_F18, // G9
        else => null,
    };
}

fn emitKey(uinput_fd: c_int, key: u16, value: i32) !void {
    std.debug.print("[emit] key=0x{x} value=0x{x}\n", .{ key, value });
    var events = [_]input_event{
        .{
            .type = c.EV_KEY,
            .code = key,
            .value = value,
        },
        .{
            .type = c.EV_SYN,
            .code = c.SYN_REPORT,
            .value = 0,
        },
    };

    const bytes = std.mem.sliceAsBytes(events[0..]);
    const rc = c.write(uinput_fd, bytes.ptr, bytes.len);
    try syscallOk(rc);
}

fn releaseAllHeld(uinput_fd: c_int, held_masks: *u16) !void {
    var bit: u16 = 1;
    while (bit != 0) : (bit = bit << 1) {
        if ((held_masks.* & bit) != 0) {
            if (mapMaskToKey(bit)) |key| {
                try emitKey(uinput_fd, key, 0);
            }
        }
    }
    held_masks.* = 0;
}

fn handleButtonPress(uinput_fd: c_int, held_masks: *u16, mask: u16) !void {
    if ((held_masks.* & mask) != 0) return;

    if (mapMaskToKey(mask)) |key| {
        try emitKey(uinput_fd, key, 1);
        held_masks.* |= mask;
    }
}

fn setupUinput(io: Io) !c_int {
    const path: [*:0]const u8 = "/dev/uinput";
    const fd = c.open(path, c.O_WRONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    try syscallOk(fd);
    errdefer _ = c.close(fd);

    try syscallOk(c.ioctl(fd, c.UI_SET_EVBIT, c.EV_KEY));
    try syscallOk(c.ioctl(fd, c.UI_SET_EVBIT, c.EV_SYN));

    const keys = [_]u16{
        // c.KEY_F13,
        c.KEY_A,
        c.KEY_F14,
        c.KEY_F15,
        c.KEY_F16,
        c.KEY_F17,
        c.KEY_F18,
    };
    for (keys) |key| {
        try syscallOk(c.ioctl(fd, c.UI_SET_KEYBIT, key));
    }

    var setup = uinput_setup{};
    setup.id = .{
        .bustype = c.BUS_USB,
        .vendor = 0x046d,
        .product = 0x402c,
        .version = 1,
    };

    const name = "G602 Virtual Keyboard";
    @memcpy(setup.name[0..name.len], name);

    try syscallOk(c.ioctl(fd, c.UI_DEV_SETUP, &setup));
    try syscallOk(c.ioctl(fd, c.UI_DEV_CREATE));

    // give kernel a sec to materialize the virtual device
    try io.sleep(.fromMilliseconds(100), .awake);

    return fd;
}

fn openHidraw(path: [*:0]const u8) !c_int {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    try syscallOk(fd);
    return fd;
}

fn openAndGrabEvdev(path: [*:0]const u8) !c_int {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    try syscallOk(fd);
    errdefer _ = c.close(fd);

    // Exclusive grab so the original combo does not escape to the rest of the system.
    try syscallOk(c.ioctl(fd, c.EVIOCGRAB, @as(c_int, 1)));

    return fd;
}

fn ungrabAndCloseEvdev(fd: c_int) void {
    _ = c.ioctl(fd, c.EVIOCGRAB, @as(c_int, 0));
    _ = c.close(fd);
}

fn drainSuppressedEvdev(fd: c_int) !void {
    // We do a single blocking read after poll() says the fd is readable.
    // If more events remain queued, the next poll() will wake immediately.
    var buf: [32]input_event = undefined;
    const bytes = std.mem.sliceAsBytes(buf[0..]);

    var read: usize = 0;
    while (read < @sizeOf(input_event)) {
        const rc = c.read(fd, bytes.ptr, bytes.len);
        try syscallOk(rc);
        read += @intCast(rc);
    }

    std.debug.print("[DRAIN] rc={d}\n", .{read});
    if (read < @sizeOf(input_event)) return;
    const n = @divTrunc(@as(usize, @intCast(read)), @sizeOf(input_event));
    std.debug.print("n={d}\n", .{n});
    // const ev = std.mem.bytesAsSlice(input_event, bytes[0..@intCast(rc)]);
    for (buf[0..n]) |e| {
        std.debug.print("[DRAIN] {any}\n", .{e});
    }

    // Intentionally discard contents.
}

fn readOneHidrawReport(fd: c_int) !HidrawReport {
    var buf: [64]u8 = undefined;
    const rc = c.read(fd, &buf, buf.len);
    try syscallOk(rc);

    const n: usize = @intCast(rc);
    return parseHidrawReport(buf[0..n]);
}
