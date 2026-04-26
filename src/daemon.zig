//! Coordination layer. Owns state, runs the readiness loop, cleans up.

const std = @import("std");
const c = @import("c");
const g602 = @import("g602.zig");
const linux = @import("linux.zig");
const config_mod = @import("config.zig");
const log_mod = @import("log.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.@"g602/daemon");

pub const RunOptions = struct {
    /// Ownership moves into the daemon. Do not deinit from the caller.
    config: config_mod.Config,

    /// Path the config was loaded from. null means "defaults used, nothing
    ///  to watch" and disables hot reload.
    config_path: ?[]const u8 = null,
    hidraw_path: []const u8,
    evdev_path: []const u8,
    trace: bool = false,
};

/// Upper bound on held entries.
///
/// Each G-button contributes at most `MAX_MODIFIERS + 1` entries,
///  with 8 buttons that's 40. Rounding up for safety, since entries
///  are cheap.
const HELD_KEY_CAP: usize = 64;

/// Per-G-button held-key tracking so we can emit matching releases on exit,
/// resync, or disconnect.
///
/// Each G-button held can contribute modifiers plus one non-modifier
///  key, store them all so teardown is unambiguous.
const HeldKey = struct {
    bit: u16,
    code: u16,
};

/// Module-level entry point kept as a thin wrapper so callers don't have
/// to think about the State lifecycle.
pub fn run(allocator: std.mem.Allocator, opts: RunOptions) !void {
    var state = try State.init(allocator, opts);
    defer state.deinit();
    try state.loop();
}

pub const State = struct {
    hidraw_fd: c_int,
    evdev_fd: c_int,
    vmouse_fd: c_int,
    vkbd_fd: c_int,
    sig_fd: c_int,

    /// -1 when hot reload is disabled (no config file path to watch).
    inotify_fd: c_int = -1,

    allocator: std.mem.Allocator,
    cfg: config_mod.Config,
    config_path: ?[]const u8 = null,
    config_basename: []const u8 = "",
    trace: bool = false,

    /// Last held-mask snapshot from hidraw.
    held_mask: u16 = 0,

    /// Firmware profile reported by the most recent snapshot.
    /// `null` until the first snapshot arrives.
    /// Used to pick between per-layer bindings.
    current_mode: ?g602.Mode = null,

    /// Keys currently held on the virtual keyboard. Parallel arrays.
    held_keys_buf: [HELD_KEY_CAP]HeldKey = @splat(.{ .bit = 0, .code = 0 }),
    held_keys_len: usize = 0,

    /// Tracked `BTN_*` state as forwarded to the virtual mouse.
    ///
    /// Used on teardown to release any mouse buttons we forwarded as held.
    held_btn: std.StaticBitSet(0x200) = std.StaticBitSet(0x200).initEmpty(),

    /// Set `true` when any mouse event was forwarded in the current evdev
    ///  frame, cleared on `SYN_REPORT`.
    frame_has_mouse_event: bool = false,

    /// After `SYN_DROPPED`, we drop every subsequent evdev event until the
    ///  next `SYN_REPORT`, then reconcile state via `EVIOCGKEY`.
    /// May span multiple `read()` calls if the kernel buffer needed to drain.
    discarding: bool = false,

    pub fn init(allocator: std.mem.Allocator, opts: RunOptions) !State {
        const hidraw_z = try to_sentinel(opts.hidraw_path);
        const evdev_z = try to_sentinel(opts.evdev_path);

        // If a later step errors, unwind by closing the fd.
        // NOTE: Close failures during error unwinding are unrecoverable, the
        //  process is about to propagate an error out anyway so we dont check
        //  the code.
        const hidraw_fd = try linux.open_hidraw(&hidraw_z);
        errdefer _ = c.close(hidraw_fd);

        // Create uinput devices before grabbing the real evdev so the window
        //  during which the user's mouse is non-functional is minimized.
        const vmouse_fd = try linux.create_virtual_mouse(.{});
        errdefer linux.destroy_uinput(vmouse_fd);

        // Advertise the entire KEY_* universe on the virtual keyboard so a
        //  hot-reloaded config can reference any keycode without needing to
        //  recreate the device.
        const vkbd_fd = try linux.create_virtual_keyboard(.{ .keycodes = config_mod.all_key_codes });
        errdefer linux.destroy_uinput(vkbd_fd);

        // Grab real evdev LAST
        const evdev_fd = try linux.open_and_grab_evdev(&evdev_z);
        errdefer {
            linux.ungrab_evdev(evdev_fd);
            _ = c.close(evdev_fd);
        }

        const sig_fd = try linux.setup_signalfd();
        errdefer _ = c.close(sig_fd);

        var inotify_fd: c_int = -1;
        var basename: []const u8 = "";
        if (opts.config_path) |path| {
            if (setup_inotify(path)) |watch| {
                inotify_fd = watch.fd;
                basename = watch.basename;
            } else |err| {
                log.warn("inotify setup failed for {s}: {s}; hot reload disabled", .{ path, @errorName(err) });
            }
        }

        return .{
            .hidraw_fd = hidraw_fd,
            .evdev_fd = evdev_fd,
            .vmouse_fd = vmouse_fd,
            .vkbd_fd = vkbd_fd,
            .sig_fd = sig_fd,
            .inotify_fd = inotify_fd,
            .allocator = allocator,
            .cfg = opts.config,
            .config_path = opts.config_path,
            .config_basename = basename,
            .trace = opts.trace,
        };
    }

    /// All syscall errors are deliberately swallowed or logged.
    ///
    /// We are on the way out, the caller cannot do anything with failure here,
    ///  and partial teardown is still better than partial teardown followed
    ///  by a panic.
    ///
    /// Keys/buttons are released first so the compositor sees a clean edge
    ///  before uinput devices disappear; ungrab precedes evdev close so the
    ///  real mouse is usable the moment our fd goes away.
    pub fn deinit(self: *State) void {
        // release held outputs first so downstream consumers see a clean edge
        //  before the virtual devices get destroyed
        self.release_all_synthetic_keys() catch |e| {
            log.warn("failed to release synthetic keys during teardown: {s}", .{@errorName(e)});
        };
        self.release_all_forwarded_buttons() catch |e| {
            log.warn("failed to release forwarded buttons during teardown: {s}", .{@errorName(e)});
        };

        // extra SYN_REPORT beyond what the release helpers already emit, cheap
        //  insurance against a failed syn mid-release
        linux.syn_report(self.vkbd_fd) catch {};
        linux.syn_report(self.vmouse_fd) catch {};

        // `ungrab_evdev` / `destroy_uinput` return void by design (see `linux`)
        // as usual, we regard raw `c.close` failures as unrecoverable and the
        //  process is about to exit either way
        linux.ungrab_evdev(self.evdev_fd);
        _ = c.close(self.evdev_fd);
        linux.destroy_uinput(self.vmouse_fd);
        linux.destroy_uinput(self.vkbd_fd);
        _ = c.close(self.hidraw_fd);
        _ = c.close(self.sig_fd);
        if (self.inotify_fd >= 0) _ = c.close(self.inotify_fd);
        self.cfg.deinit();
    }

    pub fn loop(self: *State) !void {
        log.info("running. hidraw_fd={d} evdev_fd={d}", .{ self.hidraw_fd, self.evdev_fd });
        if (self.inotify_fd >= 0) log.info("hot reload watching {s}", .{self.config_path.?});

        var fds_storage = [_]linux.PollFd{
            .{ .fd = self.hidraw_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = self.evdev_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = self.sig_fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = -1, .events = c.POLLIN, .revents = 0 },
        };
        const fds_len: usize = if (self.inotify_fd >= 0) 4 else 3;
        if (self.inotify_fd >= 0) fds_storage[3].fd = self.inotify_fd;
        const fds = fds_storage[0..fds_len];

        while (true) {
            for (fds) |*f| f.revents = 0;
            // Cap the poll wait while discarding so that if the kernel fails to
            //  send the closing SYN_REPORT we eventually force-reconcile rather
            //  than muting the mouse indefinitely.
            const timeout: i32 = if (self.discarding) 500 else -1;
            const ready = try linux.poll_fds(fds, timeout);
            if (ready == 0 and self.discarding) {
                log.warn("[evdev] SYN_REPORT timeout after SYN_DROPPED; force-reconciling", .{});
                self.discarding = false;
                try self.reconcile_from_kernel();
                continue;
            }

            if ((fds[2].revents & c.POLLIN) != 0) {
                if (try self.handle_signal()) {
                    log.info("shutting down on signal", .{});
                    return;
                }
            }

            if (fds_len > 3 and (fds[3].revents & c.POLLIN) != 0) {
                self.handle_inotify() catch |err| {
                    log.warn("inotify read failed: {s}", .{@errorName(err)});
                };
            }

            if ((fds[0].revents & c.POLLIN) != 0) {
                self.handle_hidraw() catch |err| {
                    log.warn("hidraw read failed: {s}; releasing synthetic keys", .{@errorName(err)});
                    try self.release_all_synthetic_keys();
                    return err;
                };
            }

            if ((fds[1].revents & c.POLLIN) != 0) {
                try self.handle_evdev();
            }

            // Hangups are fatal, the process exits and systemd restarts
            if ((fds[0].revents & (c.POLLHUP | c.POLLERR)) != 0) {
                log.warn("hidraw fd hung up", .{});
                return error.DeviceDisconnected;
            }
            if ((fds[1].revents & (c.POLLHUP | c.POLLERR)) != 0) {
                log.warn("evdev fd hung up", .{});
                return error.DeviceDisconnected;
            }
        }
    }

    // ----- signalfd -----

    /// Returns true if a terminating signal was received.
    ///
    /// signalfd guarantees reads return a multiple of `sizeof(siginfo)` or
    /// `-1` / `EAGAIN`; a partial read would be a kernel bug. We still
    /// require the full struct size defensively so `info` is never
    /// partially-initialized.
    fn handle_signal(self: *State) !bool {
        var info: SignalfdSiginfo = undefined;
        const bytes = std.mem.asBytes(&info);
        const rc = c.read(self.sig_fd, bytes.ptr, bytes.len);
        try linux.ok(rc, "[daemon] read(signalfd)");
        if (@as(usize, @intCast(rc)) != bytes.len) {
            log.err("Got short read expected={d} actual={d}", .{ bytes.len, rc });
            return error.ShortSignalfdRead;
        }
        return info.ssi_signo == c.SIGINT or info.ssi_signo == c.SIGTERM;
    }

    // ----- inotify / config reload -----

    fn handle_inotify(self: *State) !void {
        var buf: [4096]u8 = undefined;
        const bytes = try linux.read_inotify(self.inotify_fd, &buf);
        var it: linux.InotifyIter = .{ .buf = bytes };
        var should_reload = false;
        while (it.next()) |item| {
            if (std.mem.eql(u8, item.name, self.config_basename)) {
                should_reload = true;
            }
        }
        if (should_reload) self.reload_config();
    }

    fn reload_config(self: *State) void {
        const path = self.config_path orelse return;
        // use page_allocator so new config's inner arena is backed by freeable
        //  memory (daemon's main allocator may be a process arena)
        var new_cfg = config_mod.Config.parse_file(std.heap.page_allocator, path) catch |err| {
            log.warn("config reload failed for {s}: {s}; keeping current config", .{ path, @errorName(err) });
            return;
        };
        var old = self.cfg;
        self.cfg = new_cfg;
        old.deinit();
        log_mod.setLevel(self.cfg.log_level);
        var bound_count: usize = 0;
        for (self.cfg.bindings) |b| if (b != null) {
            bound_count += 1;
        };
        log.info("config reloaded from {s} ({d} bindings active)", .{ path, bound_count });
        _ = &new_cfg;
    }

    // ----- hidraw path -----

    fn handle_hidraw(self: *State) !void {
        var buf: [64]u8 = undefined;
        const bytes = try linux.read_hidraw(self.hidraw_fd, &buf);
        if (self.trace) trace_hidraw(bytes);
        switch (g602.parseHidrawReport(bytes)) {
            .ignore => {},
            .malformed => {
                log.warn("[hidraw] malformed snapshot, releasing synthetic keys to resync", .{});
                try self.release_all_synthetic_keys();
            },
            .snapshot => |snap| {
                if (self.current_mode) |prev| {
                    if (prev != snap.mode) {
                        log.info("[layer] {s} -> {s}", .{ @tagName(prev), @tagName(snap.mode) });
                    }
                }
                self.current_mode = snap.mode;
                if (self.trace) {
                    const diff = g602.diffMask(self.held_mask, snap.mask);
                    std.debug.print(
                        "hidraw: mask=0x{x:0>4} mode={s} prev=0x{x:0>4} pressed=0x{x:0>4} released=0x{x:0>4}\n",
                        .{ snap.mask, @tagName(snap.mode), self.held_mask, diff.pressed, diff.released },
                    );
                }
                try self.apply_mask_transition(snap.mask);
            },
        }
    }

    fn apply_mask_transition(self: *State, new_mask: u16) !void {
        const diff = g602.diffMask(self.held_mask, new_mask);

        // releases first so a swap (release+press on different bits in the same
        //  snapshot) doesn't briefly hold both replacement outputs
        for (0..16) |i| {
            const bit: u16 = @as(u16, 1) << @intCast(i);
            if ((diff.released & bit) != 0) try self.release_binding(bit);
        }
        for (0..16) |i| {
            const bit: u16 = @as(u16, 1) << @intCast(i);
            if ((diff.pressed & bit) != 0) try self.press_binding(bit);
        }

        self.held_mask = new_mask;
    }

    fn press_binding(self: *State, bit: u16) !void {
        const btn = g602.GButton.fromBit(bit) orelse return;
        // Mode defaults to .a before the first snapshot, apply_mask_transition
        //  is only reachable after a snapshot set self.current_mode anyway
        const mode = self.current_mode orelse .a;
        const binding = self.cfg.binding_for(mode, btn.index()) orelse return;

        // Modifiers down then key down
        //
        // Skip the actual EV_KEY write if the code is already held from another
        //  binding; still record in the held table so refcount tracking works
        //  on release.
        //
        // Order matters: push FIRST, emit SECOND.
        //  1. If push fails (capacity), no event leaks out.
        //  2. If emit fails after a successful push, the release path will still
        //     emit a matching key-up for the tracked code (which is harmless
        //     even if the key-down never reached the kernel).
        for (binding.mods()) |m| {
            const was_held = self.code_is_held(m);
            try self.push_held(bit, m);
            if (!was_held) {
                try linux.write_event(self.vkbd_fd, c.EV_KEY, m, 1);
            }
        }
        const key_was_held = self.code_is_held(binding.keycode);
        try self.push_held(bit, binding.keycode);
        if (!key_was_held) {
            try linux.write_event(self.vkbd_fd, c.EV_KEY, binding.keycode, 1);
        }
        try linux.syn_report(self.vkbd_fd);
    }

    fn release_binding(self: *State, bit: u16) !void {
        // collect and remove held entries for this bit in reverse order
        var codes: [HELD_KEY_CAP]u16 = undefined;
        var n: usize = 0;
        var i: usize = self.held_keys_len;
        while (i > 0) {
            i -= 1;
            if (self.held_keys_buf[i].bit != bit) continue;
            codes[n] = self.held_keys_buf[i].code;
            n += 1;
            self.remove_held_at(i);
        }
        // after removal, emit key-up only for codes no longer held by any other
        //  binding (refcount reached zero)
        for (codes[0..n]) |code| {
            if (!self.code_is_held(code)) {
                linux.write_event(self.vkbd_fd, c.EV_KEY, code, 0) catch |e| {
                    log.warn("vkbd release write failed: {s}", .{@errorName(e)});
                };
            }
        }
        linux.syn_report(self.vkbd_fd) catch {};
    }

    fn code_is_held(self: *const State, code: u16) bool {
        for (self.held_keys_buf[0..self.held_keys_len]) |hk| {
            if (hk.code == code) return true;
        }
        return false;
    }

    fn push_held(self: *State, bit: u16, code: u16) !void {
        if (self.held_keys_len >= HELD_KEY_CAP) return error.TooManyHeldKeys;
        self.held_keys_buf[self.held_keys_len] = .{ .bit = bit, .code = code };
        self.held_keys_len += 1;
    }

    fn remove_held_at(self: *State, i: usize) void {
        const last = self.held_keys_len - 1;
        if (i != last) self.held_keys_buf[i] = self.held_keys_buf[last];
        self.held_keys_len -= 1;
    }

    fn release_all_synthetic_keys(self: *State) !void {
        // emit key-up for each unique code exactly once, regardless of how many
        //  bindings referenced it
        var seen: [HELD_KEY_CAP]u16 = undefined;
        var seen_n: usize = 0;
        for (self.held_keys_buf[0..self.held_keys_len]) |hk| {
            var already = false;
            for (seen[0..seen_n]) |s| if (s == hk.code) {
                already = true;
                break;
            };
            if (already) continue;
            seen[seen_n] = hk.code;
            seen_n += 1;
            linux.write_event(self.vkbd_fd, c.EV_KEY, hk.code, 0) catch |e| {
                log.warn("vkbd release write failed: {s}", .{@errorName(e)});
            };
        }
        self.held_keys_len = 0;
        linux.syn_report(self.vkbd_fd) catch {};
        self.held_mask = 0;
    }

    // ----- evdev path -----

    fn handle_evdev(self: *State) !void {
        var buf: [64]g602.InputEvent = undefined;
        const events = try linux.read_input_events(self.evdev_fd, &buf);
        for (events) |ev| {
            if (self.discarding) {
                if (ev.type == c.EV_SYN and ev.code == c.SYN_REPORT) {
                    self.discarding = false;
                    try self.reconcile_from_kernel();
                }
                continue;
            }
            const action = g602.classifyEvdev(ev);
            if (self.trace) trace_evdev(ev, action);
            switch (action) {
                .forward_mouse => try self.forward_mouse_event(ev),
                .drop => {}, // leaked firmware key or MSC_SCAN
                .syn_report => try self.flush_frame(),
                .syn_dropped => {
                    log.warn("[evdev] SYN_DROPPED, discarding until next SYN_REPORT", .{});
                    self.discarding = true;
                },
                .unknown => log.debug("[evdev] ignoring type={d} code={d}", .{ ev.type, ev.code }),
            }
        }
    }

    fn forward_mouse_event(self: *State, ev: g602.InputEvent) !void {
        try linux.write_event(self.vmouse_fd, ev.type, ev.code, ev.value);
        self.frame_has_mouse_event = true;
        if (ev.type == c.EV_KEY) {
            if (ev.value != 0) {
                self.held_btn.set(ev.code);
            } else {
                self.held_btn.unset(ev.code);
            }
        }
    }

    fn flush_frame(self: *State) !void {
        if (self.frame_has_mouse_event) {
            try linux.syn_report(self.vmouse_fd);
            self.frame_has_mouse_event = false;
        }
    }

    /// Called at the `SYN_REPORT` that closes out a `SYN_DROPPED` window, once
    ///  we have fully drained the damaged frame(s).
    ///
    /// Queries current `BTN_*` state and reconciles tracked held buttons against
    ///  reality.
    fn reconcile_from_kernel(self: *State) !void {
        var bits: [linux.KEYBIT_BYTES]u8 = @splat(0);
        linux.get_key_state(self.evdev_fd, &bits) catch |e| {
            log.warn("EVIOCGKEY failed during resync: {s}", .{@errorName(e)});
            return;
        };

        // for each BTN_* we think is held, check reality and emit releases
        var code: u16 = c.BTN_MISC;
        while (code < 0x200) : (code += 1) {
            const we_think_held = self.held_btn.isSet(code);
            const really_held = linux.is_bit_set(&bits, code);
            if (we_think_held and !really_held) {
                linux.write_event(self.vmouse_fd, c.EV_KEY, code, 0) catch {};
                self.held_btn.unset(code);
            } else if (!we_think_held and really_held) {
                linux.write_event(self.vmouse_fd, c.EV_KEY, code, 1) catch {};
                self.held_btn.set(code);
            }
        }
        linux.syn_report(self.vmouse_fd) catch {};
    }

    fn release_all_forwarded_buttons(self: *State) !void {
        var it = self.held_btn.iterator(.{});
        while (it.next()) |code_usize| {
            const code: u16 = @intCast(code_usize);
            linux.write_event(self.vmouse_fd, c.EV_KEY, code, 0) catch {};
        }
        self.held_btn = std.StaticBitSet(0x200).initEmpty();
        linux.syn_report(self.vmouse_fd) catch {};
    }
};

// ----- free helpers -----

const SignalfdSiginfo = extern struct {
    ssi_signo: u32,
    _rest: [124]u8,
};

const Watch = struct { fd: c_int, basename: []const u8 };

fn setup_inotify(path: []const u8) !Watch {
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    var dir_z: [4096:0]u8 = @splat(0);
    if (dir.len >= dir_z.len) return error.PathTooLong;
    @memcpy(dir_z[0..dir.len], dir);

    const fd: c_int = @intCast(try linux.inotify_init());
    errdefer _ = c.close(fd);
    _ = try linux.inotify_add_watch(
        fd,
        &dir_z,
        linux.IN_CLOSE_WRITE | linux.IN_MOVED_TO | linux.IN_CREATE,
    );
    return .{ .fd = fd, .basename = base };
}

fn to_sentinel(path: []const u8) ![256:0]u8 {
    if (path.len >= 255) return error.PathTooLong;
    var buf: [256:0]u8 = @splat(0);
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf;
}

fn trace_hidraw(bytes: []const u8) void {
    std.debug.print("hidraw: raw[{d}]=", .{bytes.len});
    for (bytes) |b| std.debug.print(" {x:0>2}", .{b});
    std.debug.print("\n", .{});
}

fn trace_evdev(ev: g602.InputEvent, action: g602.EvdevAction) void {
    const type_s = switch (ev.type) {
        c.EV_SYN => "EV_SYN",
        c.EV_KEY => "EV_KEY",
        c.EV_REL => "EV_REL",
        c.EV_ABS => "EV_ABS",
        c.EV_MSC => "EV_MSC",
        else => "EV_?",
    };
    std.debug.print(
        "evdev:  type={s:<6} code=0x{x:0>3} value={d:<5} -> {s}\n",
        .{ type_s, ev.code, ev.value, @tagName(action) },
    );
}
