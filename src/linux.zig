//! Linux interface boundary wrapping syscalls and ioctls.

const std = @import("std");
const c = @import("c");
const g602 = @import("g602.zig");

const log = std.log.scoped(.@"g602/linux");

pub const InputEvent = g602.InputEvent;

pub const DeviceResolution = struct {
    hidraw_path: []const u8,
    evdev_path: []const u8,

    pub fn free(self: DeviceResolution, allocator: std.mem.Allocator) void {
        allocator.free(self.hidraw_path);
        allocator.free(self.evdev_path);
    }
};

pub const SyscallError = error{SyscallFailed};

/// Generic "rc < 0 means failed" check that also logs the syscall name and
/// errno, so a startup or runtime failure tells you which step blew up
/// without needing a full error return trace.
pub fn ok(rc: anytype, op: []const u8) SyscallError!void {
    if (rc < 0) {
        const e = std.posix.errno(rc);
        log.err("{s} failed: errno={s}({d})", .{ op, @tagName(e), @intFromEnum(e) });
        return error.SyscallFailed;
    }
}

/// Byte count for a keybit array covering `KEY_MAX`.
///
/// `KEY_MAX` is 0x2ff in current kernels; 96 bytes (768 bits) is more than
///  enough to cover all `BTN_*` codes we care about plus headroom.
pub const KEYBIT_BYTES: usize = 96;

// ----- uinput setup structs (define ourselves for layout clarity) -----

const InputId = extern struct {
    bustype: u16 = 0,
    vendor: u16 = 0,
    product: u16 = 0,
    version: u16 = 0,
};

const UinputSetup = extern struct {
    id: InputId = .{},
    name: [80]u8 = @splat(0),
    ff_effects_max: u32 = 0,
};

// ----- hidraw -----

pub fn open_hidraw(path: [*:0]const u8) !c_int {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    try ok(fd, "open(hidraw)");
    return fd;
}

pub fn read_hidraw(fd: c_int, buf: []u8) ![]u8 {
    const n = std.posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => return buf[0..0],
        else => return error.SyscallFailed,
    };
    return buf[0..n];
}

// ----- evdev -----

pub fn open_and_grab_evdev(path: [*:0]const u8) !c_int {
    const fd = c.open(path, c.O_RDWR | c.O_CLOEXEC);
    try ok(fd, "open(evdev)");
    errdefer _ = c.close(fd);
    try ok(c.ioctl(fd, c.EVIOCGRAB, @as(c_int, 1)), "ioctl(EVIOCGRAB)");
    return fd;
}

/// Best-effort ungrab, used on teardown. Returning an error here would be
/// meaningless: we're on the way out, the caller can't do anything with
/// the failure, and the fd is about to be closed which implicitly
/// releases the grab anyway.
pub fn ungrab_evdev(fd: c_int) void {
    _ = c.ioctl(fd, c.EVIOCGRAB, @as(c_int, 0));
}

pub fn read_input_events(fd: c_int, buf: []InputEvent) ![]InputEvent {
    const bytes = std.mem.sliceAsBytes(buf);
    const n_bytes = std.posix.read(fd, bytes) catch |err| switch (err) {
        error.WouldBlock => return buf[0..0],
        else => return error.SyscallFailed,
    };
    return buf[0 .. n_bytes / @sizeOf(InputEvent)];
}

/// Reads the current `BTN_*` state via `EVIOCGKEY` for resync after `SYN_DROPPED`.
/// Returns the raw keybit array.
pub fn get_key_state(fd: c_int, out: *[KEYBIT_BYTES]u8) !void {
    const rc = c.ioctl(fd, c.EVIOCGKEY(@as(c_int, KEYBIT_BYTES)), out);
    try ok(rc, "ioctl(EVIOCGKEY)");
}

pub fn is_bit_set(bits: []const u8, code: u16) bool {
    const byte_idx = code / 8;
    const bit_idx: u3 = @intCast(code % 8);
    if (byte_idx >= bits.len) return false;
    return (bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

// ----- uinput -----

pub const VirtualMouseSpec = struct {
    name: []const u8 = "G602 Interposed Mouse",
    vendor: u16 = 0x046d,
    product: u16 = 0x4602,
    version: u16 = 1,
};

pub const VirtualKeyboardSpec = struct {
    name: []const u8 = "G602 Interposed Keyboard",
    vendor: u16 = 0x046d,
    product: u16 = 0x4603,
    version: u16 = 1,
    keycodes: []const u16,
};

pub fn create_virtual_mouse(spec: VirtualMouseSpec) !c_int {
    const fd = c.open("/dev/uinput", c.O_WRONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    try ok(fd, "open(/dev/uinput) [mouse]");
    errdefer _ = c.close(fd);

    try ok(c.ioctl(fd, c.UI_SET_EVBIT, @as(c_ulong, c.EV_SYN)), "UI_SET_EVBIT EV_SYN [mouse]");
    try ok(c.ioctl(fd, c.UI_SET_EVBIT, @as(c_ulong, c.EV_KEY)), "UI_SET_EVBIT EV_KEY [mouse]");
    try ok(c.ioctl(fd, c.UI_SET_EVBIT, @as(c_ulong, c.EV_REL)), "UI_SET_EVBIT EV_REL [mouse]");

    // standard mouse buttons
    const btns = [_]c_ulong{
        c.BTN_LEFT, c.BTN_RIGHT, c.BTN_MIDDLE,
        c.BTN_SIDE, c.BTN_EXTRA, c.BTN_FORWARD,
        c.BTN_BACK, c.BTN_TASK,
    };
    for (btns) |b| try ok(c.ioctl(fd, c.UI_SET_KEYBIT, b), "UI_SET_KEYBIT [mouse]");

    // relative axes including high-res wheel (kernel 5.0+)
    const rels = [_]c_ulong{
        c.REL_X,            c.REL_Y,             c.REL_WHEEL, c.REL_HWHEEL,
        c.REL_WHEEL_HI_RES, c.REL_HWHEEL_HI_RES,
    };
    for (rels) |r| try ok(c.ioctl(fd, c.UI_SET_RELBIT, r), "UI_SET_RELBIT [mouse]");

    var setup: UinputSetup = .{};
    setup.id = .{
        .bustype = c.BUS_VIRTUAL,
        .vendor = spec.vendor,
        .product = spec.product,
        .version = spec.version,
    };
    const n = @min(spec.name.len, setup.name.len - 1);
    @memcpy(setup.name[0..n], spec.name[0..n]);

    try ok(c.ioctl(fd, c.UI_DEV_SETUP, &setup), "UI_DEV_SETUP [mouse]");
    try ok(c.ioctl(fd, c.UI_DEV_CREATE), "UI_DEV_CREATE [mouse]");
    return fd;
}

pub fn create_virtual_keyboard(spec: VirtualKeyboardSpec) !c_int {
    const fd = c.open("/dev/uinput", c.O_WRONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    try ok(fd, "open(/dev/uinput) [kbd]");
    errdefer _ = c.close(fd);

    try ok(c.ioctl(fd, c.UI_SET_EVBIT, @as(c_ulong, c.EV_SYN)), "UI_SET_EVBIT EV_SYN [kbd]");
    try ok(c.ioctl(fd, c.UI_SET_EVBIT, @as(c_ulong, c.EV_KEY)), "UI_SET_EVBIT EV_KEY [kbd]");
    try ok(c.ioctl(fd, c.UI_SET_EVBIT, @as(c_ulong, c.EV_REP)), "UI_SET_EVBIT EV_REP [kbd]");

    for (spec.keycodes) |kc| {
        try ok(c.ioctl(fd, c.UI_SET_KEYBIT, @as(c_ulong, kc)), "UI_SET_KEYBIT [kbd]");
    }

    var setup: UinputSetup = .{};
    setup.id = .{
        .bustype = c.BUS_VIRTUAL,
        .vendor = spec.vendor,
        .product = spec.product,
        .version = spec.version,
    };
    const n = @min(spec.name.len, setup.name.len - 1);
    @memcpy(setup.name[0..n], spec.name[0..n]);

    try ok(c.ioctl(fd, c.UI_DEV_SETUP, &setup), "UI_DEV_SETUP [kbd]");
    try ok(c.ioctl(fd, c.UI_DEV_CREATE), "UI_DEV_CREATE [kbd]");
    return fd;
}

/// Best-effort destroy + close, used on teardown.
///
/// Both ioctl and close errors at this point are unrecoverable and closing the
///  fd is the fallback cleanup anyway (the kernel tears down the uinput
///  device when its last fd goes away).
pub fn destroy_uinput(fd: c_int) void {
    _ = c.ioctl(fd, c.UI_DEV_DESTROY);
    _ = c.close(fd);
}

pub fn write_event(fd: c_int, ev_type: u16, ev_code: u16, ev_value: i32) !void {
    const ev = InputEvent{ .type = ev_type, .code = ev_code, .value = ev_value };
    const bytes = std.mem.asBytes(&ev);
    // Loop on short writes and retry EINTR/EAGAIN. uinput accepts whole
    //  input_event structs per call in practice, but defend against any
    //  partial write or signal-interrupted write regardless.
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc < 0) switch (std.posix.errno(rc)) {
            .INTR => continue,
            // EAGAIN on uinput writes shouldnt happen (the kernel processes
            //  events synchronously), but if it ever did, retrying unbounded
            //  would spin a core. Treat as fatal, the caller will surface it
            //  and we exit cleanly rather than lock up.
            else => |e| {
                log.err("write(uinput) failed: errno={s}({d})", .{ @tagName(e), @intFromEnum(e) });
                return error.SyscallFailed;
            },
        };
        if (rc == 0) {
            log.err("write(uinput) returned 0", .{});
            return error.SyscallFailed;
        }
        written += @intCast(rc);
    }
}

pub fn syn_report(fd: c_int) !void {
    try write_event(fd, c.EV_SYN, c.SYN_REPORT, 0);
}

// ----- signal handling via signalfd -----

/// Convert SIGINT/SIGTERM/SIGHUP from async interrupts into a readable fd.
///
/// Without this, a signal arriving mid-syscall would run the kernel's default
///  action (terminate the process) and skip our `State.deinit` teardown,
///  leaving evdev grabbed and held synthetic keys stuck.
///
/// The pattern here:
///
///   1. Build a set containing the signals we want to catch.
///   2. `sigprocmask(SIG_BLOCK, ...)` so those signals are held pending instead
///      of delivered asynchronously. This must happen BEFORE any signal can
///      arrive, otherwise the default handler (terminate) could run before we
///      install the fd.
///   3. Create a signalfd for the same mask. Any pending signal in the mask now
///      makes the fd readable in `poll()`; the readiness loop handles it like
///      any other event source.
///
/// The returned fd is owned by the caller; close on teardown.
///
/// Flag notes:
///   - `SFD_CLOEXEC`: auto-close on exec() so the fd does not leak to any
///     hypothetical child process.
///   - `SFD_NONBLOCK`: read() returns EAGAIN if nothing is pending instead of
///     blocking. Defensive, we only read after poll() signals readiness anyway.
pub fn setup_signalfd() !c_int {
    var mask: c.sigset_t = .{};
    // These three cannot fail with the arguments passed here. Reasoning is
    //  call-site-specific (not a general claim about the API):
    //   - sigemptyset: always returns 0 on Linux.
    //   - sigaddset: only fails (-1 / EINVAL) on an invalid signal number;
    //     SIGINT/SIGTERM/SIGHUP are always valid.
    //   - sigprocmask: the only realistic failure modes are EINVAL for a bad
    //     `how` (we pass SIG_BLOCK) and EFAULT for a bad pointer (ours is
    //     a stack-local in scope, oldset is null).
    _ = c.sigemptyset(&mask);
    _ = c.sigaddset(&mask, c.SIGINT);
    _ = c.sigaddset(&mask, c.SIGTERM);
    _ = c.sigaddset(&mask, c.SIGHUP);
    _ = c.sigprocmask(c.SIG_BLOCK, &mask, null);
    const fd = c.signalfd(-1, &mask, c.SFD_CLOEXEC | c.SFD_NONBLOCK);
    try ok(fd, "signalfd");
    return fd;
}

// ----- poll -----

pub const PollFd = std.posix.pollfd;

pub fn poll_fds(fds: []PollFd, timeout_ms: i32) !usize {
    return std.posix.poll(fds, timeout_ms);
}

// ----- inotify (for config hot reload) -----

const linux_os = std.os.linux;

pub const IN_CLOSE_WRITE: u32 = linux_os.IN.CLOSE_WRITE;
pub const IN_MOVED_TO: u32 = linux_os.IN.MOVED_TO;
pub const IN_CREATE: u32 = linux_os.IN.CREATE;
pub const InotifyEvent = linux_os.inotify_event;

pub fn inotify_init() !i32 {
    const rc = linux_os.inotify_init1(linux_os.IN.CLOEXEC | linux_os.IN.NONBLOCK);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => error.SyscallFailed,
    };
}

pub fn inotify_add_watch(fd: i32, path: [*:0]const u8, mask: u32) !i32 {
    const rc = linux_os.inotify_add_watch(fd, path, mask);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        else => error.SyscallFailed,
    };
}

pub fn read_inotify(fd: i32, buf: []u8) ![]u8 {
    const n = std.posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => return buf[0..0],
        else => return error.SyscallFailed,
    };
    return buf[0..n];
}

pub const InotifyIter = struct {
    buf: []const u8,
    pos: usize = 0,

    pub const Item = struct {
        ev: *align(1) const InotifyEvent,
        name: []const u8,
    };

    pub fn next(self: *InotifyIter) ?Item {
        if (self.pos + @sizeOf(InotifyEvent) > self.buf.len) return null;
        const ev: *align(1) const InotifyEvent = @ptrCast(self.buf[self.pos..].ptr);
        const name_start = self.pos + @sizeOf(InotifyEvent);
        const name_end = name_start + ev.len;
        if (name_end > self.buf.len) return null;
        const raw = self.buf[name_start..name_end];
        const name = if (ev.len > 0) std.mem.sliceTo(raw, 0) else raw;
        self.pos = name_end;
        return .{ .ev = ev, .name = name };
    }
};

// ----- device resolution via sysfs -----

const HID_ID_BUS_USB: u16 = 0x0003;

/// Resolve the target G602 hidraw and evdev nodes under /sys.
///
/// Strategy:
///   - Scan /sys/class/hidraw/hidrawN. For each, read device/uevent and match
///     HID_ID against the expected `0003:<vid>:<pid>`. The G602 receiver
///     exposes one hidraw per logical interface. We pick the one that reports
///     5-byte G-button snapshots. Picking the wrong one is handled by the
///     caller (they can override via config).
///   - Scan /sys/class/input/eventN. For each, read device/id/vendor and
///     device/id/product. Pick the one that advertises EV_REL, which on this
///     receiver is the merged mouse node we need to grab.
///
/// Returned paths are owned by the caller and must be freed.
pub fn resolve_g602(allocator: std.mem.Allocator) !DeviceResolution {
    const hidraw = try resolve_hidraw(allocator);
    errdefer allocator.free(hidraw);
    const evdev = try resolve_evdev(allocator);
    return .{ .hidraw_path = hidraw, .evdev_path = evdev };
}

pub const NodeInfo = struct {
    kind: enum { hidraw, evdev },
    path: []const u8,
    name: []const u8,
    caps_rel: []const u8,
    caps_key: []const u8,

    pub fn free(self: NodeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.name);
        allocator.free(self.caps_rel);
        allocator.free(self.caps_key);
    }
};

/// Enumerate all hidraw and evdev nodes matching the G602 vid/pid.
///
/// Useful for debugging when a physical button does not appear on the auto-
///  selected node and we need to check whether it is on a sibling node.
pub fn list_all_matching(allocator: std.mem.Allocator) !std.ArrayList(NodeInfo) {
    var out: std.ArrayList(NodeInfo) = .empty;
    errdefer {
        for (out.items) |n| n.free(allocator);
        out.deinit(allocator);
    }

    // hidraw
    {
        const dirp = c.opendir("/sys/class/hidraw");
        if (dirp != null) {
            defer _ = c.closedir(dirp);
            while (true) {
                const ent = c.readdir(dirp);
                if (ent == null) break;
                const entname = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                if (!std.mem.startsWith(u8, entname, "hidraw")) continue;
                const uevent_path = try std.fmt.allocPrint(allocator, "/sys/class/hidraw/{s}/device/uevent", .{entname});
                defer allocator.free(uevent_path);
                const body = read_small_file(allocator, uevent_path) catch continue;
                defer allocator.free(body);
                if (!hid_id_vendor_matches(body, g602.VID_LOGITECH)) continue;

                const desc_path = try std.fmt.allocPrint(allocator, "/sys/class/hidraw/{s}/device/report_descriptor", .{entname});
                defer allocator.free(desc_path);
                const desc = read_small_file(allocator, desc_path) catch &[_]u8{};
                defer if (desc.len != 0) allocator.free(desc);
                const has_snap = descriptor_declares_report_id(desc, g602.HIDRAW_PREFIX_B0);

                const hid_name = extract_uevent_field(body, "HID_NAME") orelse "";
                // caps_key reused as a free-form tag for hidraws (caps don't
                //  apply). "snapshot" marks the node carrying our report ID
                //  0x80 stream.
                const tag = if (has_snap) "snapshot" else "";
                const info: NodeInfo = .{
                    .kind = .hidraw,
                    .path = try std.fmt.allocPrint(allocator, "/dev/{s}", .{entname}),
                    .name = try allocator.dupe(u8, hid_name),
                    .caps_rel = try allocator.dupe(u8, ""),
                    .caps_key = try allocator.dupe(u8, tag),
                };
                try out.append(allocator, info);
            }
        }
    }

    // evdev
    {
        const dirp = c.opendir("/sys/class/input");
        if (dirp != null) {
            defer _ = c.closedir(dirp);
            while (true) {
                const ent = c.readdir(dirp);
                if (ent == null) break;
                const entname = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
                if (!std.mem.startsWith(u8, entname, "event")) continue;
                const vendor = read_u16_hex(allocator, "/sys/class/input", entname, "device/id/vendor") catch continue;
                const product = read_u16_hex(allocator, "/sys/class/input", entname, "device/id/product") catch continue;
                if (vendor != g602.VID_LOGITECH or product != g602.PID_G602) continue;

                const name_path = try std.fmt.allocPrint(allocator, "/sys/class/input/{s}/device/name", .{entname});
                defer allocator.free(name_path);
                const rel_path = try std.fmt.allocPrint(allocator, "/sys/class/input/{s}/device/capabilities/rel", .{entname});
                defer allocator.free(rel_path);
                const key_path = try std.fmt.allocPrint(allocator, "/sys/class/input/{s}/device/capabilities/key", .{entname});
                defer allocator.free(key_path);

                const raw_name = read_small_file(allocator, name_path) catch try allocator.dupe(u8, "");
                defer allocator.free(raw_name);
                const raw_rel = read_small_file(allocator, rel_path) catch try allocator.dupe(u8, "");
                defer allocator.free(raw_rel);
                const raw_key = read_small_file(allocator, key_path) catch try allocator.dupe(u8, "");
                defer allocator.free(raw_key);

                const info: NodeInfo = .{
                    .kind = .evdev,
                    .path = try std.fmt.allocPrint(allocator, "/dev/input/{s}", .{entname}),
                    .name = try allocator.dupe(u8, std.mem.trim(u8, raw_name, " \t\r\n")),
                    .caps_rel = try allocator.dupe(u8, std.mem.trim(u8, raw_rel, " \t\r\n")),
                    .caps_key = try allocator.dupe(u8, std.mem.trim(u8, raw_key, " \t\r\n")),
                };
                try out.append(allocator, info);
            }
        }
    }

    return out;
}

fn extract_uevent_field(body: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len or line[key.len] != '=') continue;
        return std.mem.trim(u8, line[key.len + 1 ..], " \t\r");
    }
    return null;
}

/// Walk a HID report descriptor looking for a Report ID declaration with the
/// given value.
///
/// The descriptor is a stream of TLV-style "items". Each item is one prefix
///  byte encoding (bSize, bType, bTag) plus 0/1/2/4 data bytes. Long items
///  (prefix 0xFE) are an explicit length-prefixed form. We must walk
///  item-by-item rather than scanning for the byte pattern, because a
///  unrelated item's data byte could happen to equal `0x85`.
///
/// Tag 0x85 = "Report ID" (bSize=1 byte data). Caller passes `id` (e.g. 0x80
///  for the G602 snapshot stream); we return true if any Report ID declaration
///  in the descriptor matches.
fn descriptor_declares_report_id(desc: []const u8, id: u8) bool {
    var i: usize = 0;
    while (i < desc.len) {
        const b = desc[i];
        if (b == 0xFE) {
            // long item: prefix(1) + dataSize(1) + tag(1) + data(dataSize)
            if (i + 2 >= desc.len) return false;
            const data_size = desc[i + 1];
            i += 3 + @as(usize, data_size);
            continue;
        }
        const size_code: u8 = b & 0x03;
        const data_size: usize = switch (size_code) {
            0 => 0,
            1 => 1,
            2 => 2,
            3 => 4,
            else => unreachable,
        };
        // 0x85 is the short-item form of "Report ID, 1 byte data".
        if (b == 0x85 and data_size == 1 and i + 1 < desc.len and desc[i + 1] == id) {
            return true;
        }
        i += 1 + data_size;
    }
    return false;
}

fn hid_id_vendor_matches(uevent: []const u8, vid: u16) bool {
    var lines = std.mem.splitScalar(u8, uevent, '\n');
    while (lines.next()) |line| {
        const prefix = "HID_ID=";
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var parts = std.mem.splitScalar(u8, line[prefix.len..], ':');
        const bus_s = parts.next() orelse return false;
        const vid_s = parts.next() orelse return false;
        const bus = std.fmt.parseInt(u16, bus_s, 16) catch return false;
        const vid_parsed = std.fmt.parseInt(u32, vid_s, 16) catch return false;
        return bus == HID_ID_BUS_USB and (vid_parsed & 0xffff) == vid;
    }
    return false;
}

/// Resolve the hidraw delivering the G602 G-button snapshot stream.
///
/// Strategy: walk all Logitech-VID hidraws (both the G602's own PID and the
///  receiver's PID), read the report descriptor for each, and pick the one
///  that declares Report ID 0x80 (our snapshot stream).
///
/// Why not match by G602 PID alone: on a Unifying receiver the snapshot stream
///  is usually emitted on a *receiver-level* hidraw (HID_ID = receiver PID),
///  not the hidraw that demuxes per-device standard HID reports (HID_ID = G602
///  PID). A PID-only match picks the latter, which only carries firmware
///  combos and mouse motion, not snapshots.
fn resolve_hidraw(allocator: std.mem.Allocator) ![]const u8 {
    var candidates: std.ArrayList([]u8) = .empty;
    defer {
        for (candidates.items) |p| allocator.free(p);
        candidates.deinit(allocator);
    }

    const dirp = c.opendir("/sys/class/hidraw");
    if (dirp == null) return error.SysfsUnavailable;
    // closedir errors on teardown of a sysfs iteration are unactionable.
    defer _ = c.closedir(dirp);

    // readdir returns null on both end-of-directory and error.
    // For a sysfs walk we treat null as end-of-directory; a mid-walk readdir
    //  error would at worst leave us with partial candidates, which the caller
    //  recovers from via the explicit-path config override.
    while (true) {
        const ent = c.readdir(dirp);
        if (ent == null) break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.startsWith(u8, name, "hidraw")) continue;

        const uevent_path = try std.fmt.allocPrint(allocator, "/sys/class/hidraw/{s}/device/uevent", .{name});
        defer allocator.free(uevent_path);
        const body = read_small_file(allocator, uevent_path) catch continue;
        defer allocator.free(body);
        if (!hid_id_vendor_matches(body, g602.VID_LOGITECH)) continue;

        const desc_path = try std.fmt.allocPrint(allocator, "/sys/class/hidraw/{s}/device/report_descriptor", .{name});
        defer allocator.free(desc_path);
        const desc = read_small_file(allocator, desc_path) catch continue;
        defer allocator.free(desc);
        if (!descriptor_declares_report_id(desc, g602.HIDRAW_PREFIX_B0)) continue;

        const path = try std.fmt.allocPrint(allocator, "/dev/{s}", .{name});
        try candidates.append(allocator, path);
    }

    if (candidates.items.len == 0) return error.DeviceNotFound;

    // Tie-break: highest-numbered node. Survives renumbering on replug because
    //  the descriptor filter already picked uniquely-qualified nodes; this
    //  only matters in edge cases where multiple Logitech receivers each have
    //  a snapshot-capable hidraw, which is exotic enough to leave to [devices].
    std.mem.sort([]u8, candidates.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return hidrawNum(a) < hidrawNum(b);
        }
        fn hidrawNum(path: []const u8) u32 {
            const prefix = "/dev/hidraw";
            if (!std.mem.startsWith(u8, path, prefix)) return 0;
            return std.fmt.parseInt(u32, path[prefix.len..], 10) catch 0;
        }
    }.lessThan);
    const chosen = candidates.items[candidates.items.len - 1];
    return try allocator.dupe(u8, chosen);
}

fn resolve_evdev(allocator: std.mem.Allocator) ![]const u8 {
    var best: ?[]u8 = null;
    errdefer if (best) |b| allocator.free(b);

    const dirp = c.opendir("/sys/class/input");
    if (dirp == null) return error.SysfsUnavailable;
    defer _ = c.closedir(dirp);

    while (true) {
        const ent = c.readdir(dirp);
        if (ent == null) break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.startsWith(u8, name, "event")) continue;
        const vendor = read_u16_hex(allocator, "/sys/class/input", name, "device/id/vendor") catch continue;
        const product = read_u16_hex(allocator, "/sys/class/input", name, "device/id/product") catch continue;
        if (vendor != g602.VID_LOGITECH or product != g602.PID_G602) continue;

        const caps_path = try std.fmt.allocPrint(allocator, "/sys/class/input/{s}/device/capabilities/rel", .{name});
        defer allocator.free(caps_path);
        const caps = read_small_file(allocator, caps_path) catch continue;
        defer allocator.free(caps);
        if (!has_any_rel_bit(caps)) continue;

        const path = try std.fmt.allocPrint(allocator, "/dev/input/{s}", .{name});
        if (best) |b| allocator.free(b);
        best = path;
    }

    return best orelse error.DeviceNotFound;
}

fn has_any_rel_bit(caps_text: []const u8) bool {
    // capabilities/rel is a space-separated hex bitmask (e.g. "1943" or
    //  "0 1943") and any non-zero word means at least one REL axis
    //  is advertised.
    var it = std.mem.tokenizeAny(u8, caps_text, " \t\n\r");
    while (it.next()) |word| {
        const v = std.fmt.parseInt(u64, word, 16) catch continue;
        if (v != 0) return true;
    }
    return false;
}

fn read_small_file(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const fd = c.open(@ptrCast(&path_buf), c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);

    const buf = try allocator.alloc(u8, 4096);
    errdefer allocator.free(buf);
    var total: usize = 0;
    while (total < buf.len) {
        const rc = c.read(fd, buf[total..].ptr, buf.len - total);
        if (rc < 0) {
            allocator.free(buf);
            return error.ReadFailed;
        }
        if (rc == 0) break;
        total += @intCast(rc);
    }
    return try allocator.realloc(buf, total);
}

fn read_u16_hex(allocator: std.mem.Allocator, base: []const u8, sub: []const u8, leaf: []const u8) !u16 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ base, sub, leaf });
    defer allocator.free(path);
    const body = try read_small_file(allocator, path);
    defer allocator.free(body);
    const trimmed = std.mem.trim(u8, body, " \t\n\r");
    return std.fmt.parseInt(u16, trimmed, 16);
}

test "hid_id_vendor_matches: logitech" {
    const uevent = "DRIVER=logitech-hidpp-device\nHID_ID=0003:0000046D:0000402C\nHID_NAME=Logitech G602\n";
    try std.testing.expect(hid_id_vendor_matches(uevent, 0x046d));
}

test "hid_id_vendor_matches: non-logitech rejected" {
    const uevent = "HID_ID=0003:00001532:00004041\n";
    try std.testing.expect(!hid_id_vendor_matches(uevent, 0x046d));
}

test "hid_id_vendor_matches: receiver pid still matches on vid" {
    // Receiver-level hidraw advertises the receiver PID (c537), not the G602
    //  PID; the new resolver matches by VID alone so this must accept.
    const uevent = "HID_ID=0003:0000046D:0000C537\n";
    try std.testing.expect(hid_id_vendor_matches(uevent, 0x046d));
}

test "hasAnyRelBit: present" {
    try std.testing.expect(has_any_rel_bit("1943\n"));
    try std.testing.expect(has_any_rel_bit("0 1943\n"));
    try std.testing.expect(!has_any_rel_bit("0\n"));
    try std.testing.expect(!has_any_rel_bit("0 0\n"));
}

test "descriptor_declares_report_id: simple match" {
    // 0x06 0x00 0xff = Usage Page (Vendor 0xFF00) -- 3 bytes
    // 0x09 0x01      = Usage 0x01                 -- 2 bytes
    // 0x85 0x80      = Report ID 0x80             -- 2 bytes
    // 0x95 0x04      = Report Count 4             -- 2 bytes
    // 0x75 0x08      = Report Size 8              -- 2 bytes
    // 0x81 0x02      = Input(Data,Var,Abs)        -- 2 bytes
    const desc = [_]u8{ 0x06, 0x00, 0xff, 0x09, 0x01, 0x85, 0x80, 0x95, 0x04, 0x75, 0x08, 0x81, 0x02 };
    try std.testing.expect(descriptor_declares_report_id(&desc, 0x80));
    try std.testing.expect(!descriptor_declares_report_id(&desc, 0x01));
}

test "descriptor_declares_report_id: 0x85 in another item's data is not a match" {
    // 0x16 0x85 0x00 = Logical Minimum, 2-byte data 0x0085. The 0x85 byte sits
    //  in an item's data section, so it must not be misread as a Report ID
    //  declaration. This is the false-positive a naive byte-pattern scan hits.
    const desc = [_]u8{ 0x16, 0x85, 0x00 };
    try std.testing.expect(!descriptor_declares_report_id(&desc, 0x85));
}

test "isBitSet" {
    var bits: [32]u8 = @splat(0);
    bits[0x10] = 0b0000_0001; // sets bit 0x80 (byte 0x10, bit 0)
    try std.testing.expect(is_bit_set(&bits, 0x80));
    try std.testing.expect(!is_bit_set(&bits, 0x81));
}
