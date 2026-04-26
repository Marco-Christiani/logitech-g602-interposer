//! Protocol and classification layer for the Logitech G602.

const std = @import("std");
const c = @import("c");

pub const VID_LOGITECH: u16 = 0x046d;
pub const PID_G602: u16 = 0x402c;

pub const HIDRAW_REPORT_LEN: usize = 5;

/// Report shape for G-button identity derived from dumps:
///   `[0x80, mask_lo, mask_hi, mode, 0x00]`
///
/// The mask at bytes [1..3] is a little-endian u16 snapshot of currently-held
///  G-buttons.
/// Byte [3] is a profile/mode indicator that flips between 0x00 and 0x80 when
///  the user toggles the DPI switch on the top side of the mouse.
pub const HIDRAW_PREFIX_B0: u8 = 0x80;
pub const HIDRAW_PREFIX_B4: u8 = 0x00;

pub const G_MASK_G4: u16 = 0x0008;
pub const G_MASK_G5: u16 = 0x0010;
pub const G_MASK_G6: u16 = 0x0020;
pub const G_MASK_G7: u16 = 0x0040;
pub const G_MASK_G8: u16 = 0x0080;
pub const G_MASK_G9: u16 = 0x0100;

// Top buttons next to the left click switch
pub const G_MASK_G10: u16 = 0x0200;
pub const G_MASK_G11: u16 = 0x0400;

pub const G_MASK_VALID: u16 =
    G_MASK_G4 | G_MASK_G5 | G_MASK_G6 | G_MASK_G7 | G_MASK_G8 | G_MASK_G9 |
    G_MASK_G10 | G_MASK_G11;

pub const G_BUTTON_COUNT: usize = 8;

pub const GButton = enum(u16) {
    g4 = G_MASK_G4,
    g5 = G_MASK_G5,
    g6 = G_MASK_G6,
    g7 = G_MASK_G7,
    g8 = G_MASK_G8,
    g9 = G_MASK_G9,
    g10 = G_MASK_G10,
    g11 = G_MASK_G11,

    pub fn fromBit(bit: u16) ?GButton {
        return switch (bit) {
            G_MASK_G4 => .g4,
            G_MASK_G5 => .g5,
            G_MASK_G6 => .g6,
            G_MASK_G7 => .g7,
            G_MASK_G8 => .g8,
            G_MASK_G9 => .g9,
            G_MASK_G10 => .g10,
            G_MASK_G11 => .g11,
            else => null,
        };
    }

    pub fn index(self: GButton) usize {
        return switch (self) {
            .g4 => 0,
            .g5 => 1,
            .g6 => 2,
            .g7 => 3,
            .g8 => 4,
            .g9 => 5,
            .g10 => 6,
            .g11 => 7,
        };
    }

    pub fn name(self: GButton) []const u8 {
        return @tagName(self);
    }
};

pub const Timeval = extern struct {
    tv_sec: isize = 0,
    tv_usec: isize = 0,
};

pub const InputEvent = extern struct {
    time: Timeval = .{},
    type: u16,
    code: u16,
    value: i32,
};

/// Which firmware profile the snapshot came from, as indicated by byte[3].
///
/// The physical toggle on the mouse flips between the two and we expose
///  this so bindings can be layered per mode.
pub const Mode = enum(u8) {
    a = 0x80,
    b = 0x00,
};

pub const Snapshot = struct {
    mask: u16,
    mode: Mode,
};

pub const HidrawParse = union(enum) {
    /// Full-state snapshot: held-mask (valid G-button bits only) plus the
    ///  profile the mouse is currently reporting from.
    snapshot: Snapshot,

    /// Report is a different, unrelated shape (e.g. the 8-byte keyboard
    ///  emulation report). These flow through our fd during normal operation
    ///  and must not cause a state reset.
    ignore,

    /// Report has length and prefix byte, but later bytes failed validation.
    ///
    /// Treat as potential sync loss: the caller should release held synthetic
    ///  keys so the next valid snapshot can re-establish truth.
    malformed,
};

pub fn parseHidrawReport(buf: []const u8) HidrawParse {
    if (buf.len != HIDRAW_REPORT_LEN) return .ignore;
    if (buf[0] != HIDRAW_PREFIX_B0) return .ignore;
    if (buf[3] != 0x00 and buf[3] != 0x80) return .malformed;
    if (buf[4] != HIDRAW_PREFIX_B4) return .malformed;
    const mask = std.mem.readInt(u16, buf[1..3], .little);
    const mode: Mode = @enumFromInt(buf[3]);
    return .{ .snapshot = .{ .mask = mask & G_MASK_VALID, .mode = mode } };
}

pub const MaskDiff = struct {
    pressed: u16,
    released: u16,
};

pub fn diffMask(prev: u16, next: u16) MaskDiff {
    const pv = prev & G_MASK_VALID;
    const nv = next & G_MASK_VALID;
    return .{
        .pressed = nv & ~pv,
        .released = pv & ~nv,
    };
}

pub const EvdevAction = enum {
    /// Relay to the virtual mouse.
    forward_mouse,

    /// Firmware leakage or MSC_SCAN. Drop.
    drop,

    /// SYN_REPORT. Caller handles frame boundary.
    syn_report,

    /// SYN_DROPPED. Caller runs resync.
    syn_dropped,

    /// Unknown code. Log once, drop.
    unknown,
};

/// Device-specific classification for the G602.
///
/// Real mouse behavior on this device lives in `EV_REL` and the `BTN_*` range
///  (codes >= `BTN_MISC` == 0x100).
///
/// Firmware-generated G-button keyboard combos appear as `EV_KEY` codes in the
///  keyboard range (< 0x100).
///
/// `MSC_SCAN` always belongs to a keyboard event and is dropped unconditionally.
pub fn classifyEvdev(ev: InputEvent) EvdevAction {
    return switch (ev.type) {
        c.EV_REL => .forward_mouse,
        c.EV_KEY => if (ev.code >= c.BTN_MISC) .forward_mouse else .drop,
        c.EV_MSC => .drop,
        c.EV_SYN => switch (ev.code) {
            c.SYN_REPORT => .syn_report,
            c.SYN_DROPPED => .syn_dropped,
            else => .unknown,
        },
        else => .unknown,
    };
}

test "parseHidrawReport: valid press in mode a" {
    const buf = [_]u8{ 0x80, 0x08, 0x00, 0x80, 0x00 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(
        HidrawParse{ .snapshot = .{ .mask = G_MASK_G4, .mode = .a } },
        r,
    );
}

test "parseHidrawReport: release in mode a" {
    const buf = [_]u8{ 0x80, 0x00, 0x00, 0x80, 0x00 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(
        HidrawParse{ .snapshot = .{ .mask = 0, .mode = .a } },
        r,
    );
}

test "parseHidrawReport: g9 in high byte" {
    const buf = [_]u8{ 0x80, 0x00, 0x01, 0x80, 0x00 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(
        HidrawParse{ .snapshot = .{ .mask = G_MASK_G9, .mode = .a } },
        r,
    );
}

test "parseHidrawReport: concurrent g4+g9" {
    const buf = [_]u8{ 0x80, 0x08, 0x01, 0x80, 0x00 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(
        HidrawParse{ .snapshot = .{ .mask = G_MASK_G4 | G_MASK_G9, .mode = .a } },
        r,
    );
}

test "parseHidrawReport: wrong length ignored" {
    const buf = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(HidrawParse.ignore, r);
}

test "parseHidrawReport: wrong prefix ignored" {
    const buf = [_]u8{ 0x02, 0x08, 0x00, 0x80, 0x00 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(HidrawParse.ignore, r);
}

test "parseHidrawReport: garbage bits outside valid mask are masked off" {
    const buf = [_]u8{ 0x80, 0xff, 0xff, 0x80, 0x00 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(
        HidrawParse{ .snapshot = .{ .mask = G_MASK_VALID, .mode = .a } },
        r,
    );
}

test "parseHidrawReport: mode b snapshot" {
    const buf = [_]u8{ 0x80, 0x00, 0x02, 0x00, 0x00 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(
        HidrawParse{ .snapshot = .{ .mask = G_MASK_G10, .mode = .b } },
        r,
    );
}

test "parseHidrawReport: invalid byte[3] marked malformed" {
    const buf = [_]u8{ 0x80, 0x00, 0x00, 0x42, 0x00 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(HidrawParse.malformed, r);
}

test "parseHidrawReport: invalid byte[4] marked malformed" {
    const buf = [_]u8{ 0x80, 0x00, 0x00, 0x80, 0x42 };
    const r = parseHidrawReport(&buf);
    try std.testing.expectEqual(HidrawParse.malformed, r);
}

test "diffMask: single press" {
    const d = diffMask(0, G_MASK_G4);
    try std.testing.expectEqual(@as(u16, G_MASK_G4), d.pressed);
    try std.testing.expectEqual(@as(u16, 0), d.released);
}

test "diffMask: single release" {
    const d = diffMask(G_MASK_G4, 0);
    try std.testing.expectEqual(@as(u16, 0), d.pressed);
    try std.testing.expectEqual(@as(u16, G_MASK_G4), d.released);
}

test "diffMask: concurrent transition swap" {
    const d = diffMask(G_MASK_G4 | G_MASK_G5, G_MASK_G5 | G_MASK_G6);
    try std.testing.expectEqual(@as(u16, G_MASK_G6), d.pressed);
    try std.testing.expectEqual(@as(u16, G_MASK_G4), d.released);
}

test "diffMask: no change" {
    const d = diffMask(G_MASK_G7, G_MASK_G7);
    try std.testing.expectEqual(@as(u16, 0), d.pressed);
    try std.testing.expectEqual(@as(u16, 0), d.released);
}

test "classifyEvdev: relative motion forwarded" {
    const ev = InputEvent{ .type = c.EV_REL, .code = c.REL_X, .value = 5 };
    try std.testing.expectEqual(EvdevAction.forward_mouse, classifyEvdev(ev));
}

test "classifyEvdev: BTN_LEFT forwarded" {
    const ev = InputEvent{ .type = c.EV_KEY, .code = c.BTN_LEFT, .value = 1 };
    try std.testing.expectEqual(EvdevAction.forward_mouse, classifyEvdev(ev));
}

test "classifyEvdev: KEY_LEFTCTRL dropped as leakage" {
    const ev = InputEvent{ .type = c.EV_KEY, .code = c.KEY_LEFTCTRL, .value = 1 };
    try std.testing.expectEqual(EvdevAction.drop, classifyEvdev(ev));
}

test "classifyEvdev: MSC_SCAN dropped" {
    const ev = InputEvent{ .type = c.EV_MSC, .code = c.MSC_SCAN, .value = 0x70029 };
    try std.testing.expectEqual(EvdevAction.drop, classifyEvdev(ev));
}

test "classifyEvdev: SYN_REPORT recognized" {
    const ev = InputEvent{ .type = c.EV_SYN, .code = c.SYN_REPORT, .value = 0 };
    try std.testing.expectEqual(EvdevAction.syn_report, classifyEvdev(ev));
}

test "classifyEvdev: SYN_DROPPED recognized" {
    const ev = InputEvent{ .type = c.EV_SYN, .code = c.SYN_DROPPED, .value = 0 };
    try std.testing.expectEqual(EvdevAction.syn_dropped, classifyEvdev(ev));
}
