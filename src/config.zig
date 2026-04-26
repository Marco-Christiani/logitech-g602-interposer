//! Config parsing.
//!
//! Minimal subset of TOML: `[section]` headers, `key = value`, `#` comments.
//! String values may be quoted or bare. No multi-line strings, arrays, or
//!  inline tables.

const std = @import("std");
const c = @import("c");
const g602 = @import("g602.zig");

const log = std.log.scoped(.@"g602/config");

const eql = std.mem.eql;
fn str_eq(a: []const u8, b: []const u8) bool {
    return eql(u8, a, b);
}

pub const MAX_MODIFIERS: usize = 4;

pub const Binding = struct {
    keycode: u16,
    modifier_count: u8 = 0,
    modifiers: [MAX_MODIFIERS]u16 = @splat(0),

    pub fn mods(self: *const Binding) []const u16 {
        return self.modifiers[0..self.modifier_count];
    }

    pub fn parse(spec: []const u8) ParseError!Binding {
        var out: Binding = .{ .keycode = 0 };
        var have_key = false;

        var it = std.mem.splitScalar(u8, spec, '+');
        while (it.next()) |part_raw| {
            const part = trim(part_raw);
            if (part.len == 0) return error.MalformedLine;
            const code = lookup_keycode(part) orelse return error.UnknownKeycode;
            if (is_modifier(code)) {
                if (out.modifier_count >= MAX_MODIFIERS) return error.TooManyModifiers;
                out.modifiers[out.modifier_count] = code;
                out.modifier_count += 1;
            } else {
                if (have_key) return error.MultipleNonModifierKeys;
                out.keycode = code;
                have_key = true;
            }
        }

        if (!have_key) return error.NoKeycode;
        return out;
    }
};

pub const LoadResult = struct {
    cfg: Config,

    /// The resolved path the config was loaded from.
    /// `null` when built-in defaults were used because no file was found.
    path: ?[]const u8 = null,
};

pub const Config = struct {
    /// Default bindings, applied when the active mode's per-layer table has
    ///  no override for a given G-button.
    /// Indexed by `GButton.index()`.
    bindings: [g602.G_BUTTON_COUNT]?Binding = @splat(null),

    /// Layer A overrides (physical toggle position producing byte[3]==0x80).
    /// `null` entry falls back to `bindings`.
    bindings_a: [g602.G_BUTTON_COUNT]?Binding = @splat(null),

    /// Layer B overrides (toggle position producing byte[3]==0x00).
    /// `null` entry falls back to `bindings`.
    bindings_b: [g602.G_BUTTON_COUNT]?Binding = @splat(null),

    hidraw_path: ?[]const u8 = null,
    evdev_path: ?[]const u8 = null,
    log_level: std.log.Level = .info,

    _arena: ?std.heap.ArenaAllocator = null,

    pub fn binding_for(self: *const Config, mode: g602.Mode, idx: usize) ?Binding {
        const per_layer = switch (mode) {
            .a => self.bindings_a[idx],
            .b => self.bindings_b[idx],
        };
        return per_layer orelse self.bindings[idx];
    }

    pub fn deinit(self: *Config) void {
        if (self._arena) |*a| a.deinit();
    }

    pub fn keycode_set(self: *const Config, out: *std.ArrayList(u16)) !void {
        for (self.bindings) |maybe_b| {
            const b = maybe_b orelse continue;
            try append_unique(out, b.keycode);
            for (b.mods()) |m| try append_unique(out, m);
        }
    }

    /// Resolve the config source and load it.
    ///
    /// Precedence: `explicit` path > `$XDG_CONFIG_HOME/g602/config.toml` >
    ///  `$HOME/.config/g602/config.toml` > built-in defaults.
    ///
    /// The returned `path` is null only when defaults were used.
    /// Any error other than "file genuinely absent" propagates.
    pub fn load(
        allocator: std.mem.Allocator,
        environ: std.process.Environ,
        explicit: ?[]const u8,
    ) !LoadResult {
        if (explicit) |p| {
            const owned = try allocator.dupe(u8, p);
            return .{ .cfg = try Config.parse_file(allocator, p), .path = owned };
        }

        if (environ.getPosix("XDG_CONFIG_HOME")) |xdg| {
            const path = try std.fmt.allocPrint(allocator, "{s}/g602/config.toml", .{xdg});
            if (try Config.load_if_present(allocator, path)) |cfg| {
                return .{ .cfg = cfg, .path = path };
            }
        }
        if (environ.getPosix("HOME")) |home| {
            const path = try std.fmt.allocPrint(allocator, "{s}/.config/g602/config.toml", .{home});
            if (try Config.load_if_present(allocator, path)) |cfg| {
                return .{ .cfg = cfg, .path = path };
            }
        }

        log.info("no config file found, using built-in defaults (hot reload disabled)", .{});
        return .{ .cfg = try Config.default(allocator), .path = null };
    }

    /// Returns null only if the file is genuinely absent (ENOENT).
    /// Any other failure propagates.
    fn load_if_present(allocator: std.mem.Allocator, path: []const u8) !?Config {
        return Config.parse_file(allocator, path) catch |err| switch (err) {
            error.ConfigFileNotFound => null,
            else => err,
        };
    }

    /// Built-in defaults used when no config file is found.
    pub fn default(allocator: std.mem.Allocator) !Config {
        const text =
            \\[bindings]
            \\g4 = "f13"
            \\g5 = "f14"
            \\g6 = "f15"
            \\g7 = "f16"
            \\g8 = "f17"
            \\g9 = "f18"
            \\g10 = "alt+right"
            \\g11 = "alt+left"
            \\
        ;
        return try Config.parse(allocator, text);
    }

    pub fn parse_file(allocator: std.mem.Allocator, path: []const u8) !Config {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        // O_NONBLOCK so opening a FIFO or similar at the config path does not
        //  freeze the daemon waiting for a writer. For regular files O_NONBLOCK
        //  is a no-op on read.
        const fd = c.open(@ptrCast(&path_buf), c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return switch (std.posix.errno(fd)) {
            .NOENT => error.ConfigFileNotFound,
            else => error.ConfigOpenFailed,
        };
        defer _ = c.close(fd);

        // reject anything that is not a regular file so a FIFO, socket, or
        //  blocking device cannot wedge us in read()
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0) return error.ConfigReadFailed;
        if ((st.st_mode & c.S_IFMT) != c.S_IFREG) return error.ConfigNotRegularFile;

        const max_bytes: usize = 64 * 1024;
        // scratch allocation for file contents, using page_allocator so repeated
        //  reloads dont bloat the caller's long-lived arena.
        var bytes_buf = try std.heap.page_allocator.alloc(u8, max_bytes);
        defer std.heap.page_allocator.free(bytes_buf);
        var total: usize = 0;
        while (total < bytes_buf.len) {
            const rc = c.read(fd, bytes_buf[total..].ptr, bytes_buf.len - total);
            if (rc < 0) return error.ConfigReadFailed;
            if (rc == 0) break;
            total += @intCast(rc);
        }
        if (total >= max_bytes) return error.ConfigTooLarge;
        return try Config.parse(allocator, bytes_buf[0..total]);
    }

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Config {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var cfg: Config = .{};
        var section: enum { none, bindings, bindings_a, bindings_b, devices, daemon } = .none;

        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw_line| {
            const line = trim(strip_comment(raw_line));
            if (line.len == 0) continue;

            if (line[0] == '[') {
                if (line.len < 3 or line[line.len - 1] != ']') return error.MalformedLine;
                const name = trim(line[1 .. line.len - 1]);
                if (str_eq(name, "bindings")) {
                    section = .bindings;
                } else if (str_eq(name, "bindings.a")) {
                    section = .bindings_a;
                } else if (str_eq(name, "bindings.b")) {
                    section = .bindings_b;
                } else if (str_eq(name, "devices")) {
                    section = .devices;
                } else if (str_eq(name, "daemon")) {
                    section = .daemon;
                } else {
                    return error.UnknownSection;
                }
                continue;
            }

            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.MalformedLine;
            const key = trim(line[0..eq_idx]);
            const raw_val = trim(line[eq_idx + 1 ..]);
            const val = unquote(raw_val);

            switch (section) {
                .none => return error.MalformedLine,
                .bindings => try set_binding_in(&cfg.bindings, key, val),
                .bindings_a => try set_binding_in(&cfg.bindings_a, key, val),
                .bindings_b => try set_binding_in(&cfg.bindings_b, key, val),
                .devices => try set_device(&cfg, &arena, key, val),
                .daemon => try set_daemon(&cfg, key, val),
            }
        }

        cfg._arena = arena;
        return cfg;
    }
};

pub const ParseError = error{
    UnknownKeycode,
    NoKeycode,
    MultipleNonModifierKeys,
    TooManyModifiers,
    UnknownSection,
    UnknownKey,
    UnknownGButton,
    InvalidBool,
    InvalidLogLevel,
    MalformedLine,
    PathTooLong,
    ConfigOpenFailed,
    ConfigReadFailed,
    ConfigNotRegularFile,
    ConfigTooLarge,
    ConfigFileNotFound,
} || std.mem.Allocator.Error;

fn append_unique(list: *std.ArrayList(u16), v: u16) !void {
    for (list.items) |existing| {
        if (existing == v) return;
    }
    try list.append(v);
}

fn set_binding_in(table: *[g602.G_BUTTON_COUNT]?Binding, key: []const u8, val: []const u8) ParseError!void {
    const btn_index = g_button_index(key) orelse return error.UnknownGButton;
    table[btn_index] = try Binding.parse(val);
}

fn set_device(cfg: *Config, arena: *std.heap.ArenaAllocator, key: []const u8, val: []const u8) ParseError!void {
    const a = arena.allocator();
    if (str_eq(key, "hidraw")) {
        cfg.hidraw_path = try a.dupe(u8, val);
    } else if (str_eq(key, "evdev")) {
        cfg.evdev_path = try a.dupe(u8, val);
    } else {
        return error.UnknownKey;
    }
}

fn set_daemon(cfg: *Config, key: []const u8, val: []const u8) ParseError!void {
    if (str_eq(key, "log_level")) {
        cfg.log_level = std.meta.stringToEnum(std.log.Level, val) orelse return error.InvalidLogLevel;
    } else {
        return error.UnknownKey;
    }
}

fn g_button_index(name: []const u8) ?usize {
    if (name.len < 2 or name.len > 3) return null;
    if (name[0] != 'g' and name[0] != 'G') return null;
    const n = std.fmt.parseInt(u8, name[1..], 10) catch return null;
    return switch (n) {
        // mathematically it's just n-4, but logically who knows, so listing explicitly
        4 => 0,
        5 => 1,
        6 => 2,
        7 => 3,
        8 => 4,
        9 => 5,
        10 => 6,
        11 => 7,
        else => null,
    };
}

fn is_modifier(code: u16) bool {
    return switch (code) {
        // zig fmt: off
        c.KEY_LEFTCTRL, c.KEY_RIGHTCTRL,
        c.KEY_LEFTSHIFT, c.KEY_RIGHTSHIFT,
        c.KEY_LEFTALT, c.KEY_RIGHTALT,
        c.KEY_LEFTMETA, c.KEY_RIGHTMETA => true,
        // zig fmt: on
        else => false,
    };
}

pub fn lookup_keycode(name: []const u8) ?u16 {
    // First, aliases (short forms that do not match any kernel symbol directly)
    for (aliases) |a| {
        if (std.ascii.eqlIgnoreCase(a.name, name)) return a.code;
    }
    // Next, exact match against the full KEY_*/BTN_* symbol name
    for (all_codes) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, name)) return e.code;
    }
    // Last, match with KEY_/BTN_ prefix stripped, so "macro1" matches KEY_MACRO1
    for (all_codes) |e| {
        if (std.ascii.eqlIgnoreCase(e.name[4..], name)) return e.code;
    }
    return null;
}

fn strip_comment(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, '#')) |i| return line[0..i];
    return line;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

const KeyEntry = struct { name: []const u8, code: u16 };

/// Short-form aliases that do not correspond directly to a kernel symbol name.
///
/// "ctrl" is really KEY_LEFTCTRL, "super" is KEY_LEFTMETA, etc.
///
/// Anything in this list takes precedence over the dynamic table lookup.
const aliases = [_]KeyEntry{
    .{ .name = "ctrl", .code = c.KEY_LEFTCTRL },
    .{ .name = "shift", .code = c.KEY_LEFTSHIFT },
    .{ .name = "alt", .code = c.KEY_LEFTALT },
    .{ .name = "meta", .code = c.KEY_LEFTMETA },
    .{ .name = "super", .code = c.KEY_LEFTMETA },
    .{ .name = "escape", .code = c.KEY_ESC },
    .{ .name = "return", .code = c.KEY_ENTER },
};

/// Every `KEY_*` code, filtered from `all_codes`.
///
/// Used to advertise the full keycode universe on the virtual keyboard so
///  hot-reloaded bindings can reference any keycode without needing to
///  recreate the uinput device.
pub const all_key_codes: []const u16 = blk: {
    @setEvalBranchQuota(100_000);
    var buf: [all_codes.len]u16 = undefined;
    var n: usize = 0;
    for (all_codes) |e| {
        if (std.mem.startsWith(u8, e.name, "KEY_")) {
            buf[n] = e.code;
            n += 1;
        }
    }
    const frozen = buf[0..n].*;
    break :blk &frozen;
};

/// Every KEY_*/BTN_* integer constant exposed by the translated c module,
///  resolved at compile time.
///
/// Lookup matches either the full symbol name (case-insensitive) or the
///  name with the KEY_/BTN_ prefix stripped ("macro1", "left", "pageup").
const all_codes: []const KeyEntry = blk: {
    @setEvalBranchQuota(100_000);
    const decls = @typeInfo(c).@"struct".decls;
    var buf: [decls.len]KeyEntry = undefined;
    var n: usize = 0;
    for (decls) |d| {
        const has_key = std.mem.startsWith(u8, d.name, "KEY_");
        const has_btn = std.mem.startsWith(u8, d.name, "BTN_");
        if (!has_key and !has_btn) continue;
        const val = @field(c, d.name);
        const T = @TypeOf(val);
        if (T != c_int and T != comptime_int) continue;
        if (val <= 0 or val >= 0x300) continue; // skip KEY_RESERVED, KEY_MAX, KEY_CNT, ranges
        buf[n] = .{ .name = d.name, .code = @intCast(val) };
        n += 1;
    }
    const frozen = buf[0..n].*;
    break :blk &frozen;
};

test "Binding.parse: single key" {
    const b = try Binding.parse("a");
    try std.testing.expectEqual(@as(u16, c.KEY_A), b.keycode);
    try std.testing.expectEqual(@as(u8, 0), b.modifier_count);
}

test "Binding.parse: ctrl+alt+a" {
    const b = try Binding.parse("ctrl+alt+a");
    try std.testing.expectEqual(@as(u16, c.KEY_A), b.keycode);
    try std.testing.expectEqual(@as(u8, 2), b.modifier_count);
}

test "Binding.parse: super alias for leftmeta" {
    const b = try Binding.parse("super+left");
    try std.testing.expectEqual(@as(u16, c.KEY_LEFT), b.keycode);
    try std.testing.expectEqual(@as(u16, c.KEY_LEFTMETA), b.modifiers[0]);
}

test "Binding.parse: unknown keycode rejected" {
    try std.testing.expectError(error.UnknownKeycode, Binding.parse("nonsense"));
}

test "Binding.parse: two non-modifier keys rejected" {
    try std.testing.expectError(error.MultipleNonModifierKeys, Binding.parse("a+b"));
}

test "Binding.parse: no non-modifier key rejected" {
    try std.testing.expectError(error.NoKeycode, Binding.parse("ctrl+alt"));
}

test "Config.parse: full config" {
    const text =
        \\# comment
        \\[bindings]
        \\g4 = "super+left"
        \\g5 = "super+right"
        \\g6 = ctrl+c
        \\g7 = "pageup"
        \\
        \\[daemon]
        \\log_level = "debug"
    ;
    var cfg = try Config.parse(std.testing.allocator, text);
    defer cfg.deinit();
    try std.testing.expect(cfg.bindings[0] != null);
    try std.testing.expectEqual(@as(u16, c.KEY_LEFT), cfg.bindings[0].?.keycode);
    try std.testing.expectEqual(std.log.Level.debug, cfg.log_level);
}

test "Config.parse: unknown G-button rejected" {
    const text = "[bindings]\ng3 = a\n";
    try std.testing.expectError(error.UnknownGButton, Config.parse(std.testing.allocator, text));
}

test "Config.default: loads" {
    var cfg = try Config.default(std.testing.allocator);
    defer cfg.deinit();
    try std.testing.expect(cfg.bindings[0] != null);
    try std.testing.expect(cfg.bindings[5] != null);
}

test "Config.parse: per-layer overrides" {
    const text =
        \\[bindings]
        \\g4 = "f13"
        \\g5 = "f14"
        \\
        \\[bindings.a]
        \\g4 = "super+left"
        \\
        \\[bindings.b]
        \\g4 = "super+right"
    ;
    var cfg = try Config.parse(std.testing.allocator, text);
    defer cfg.deinit();
    try std.testing.expect(cfg.bindings[0] != null);
    try std.testing.expect(cfg.bindings_a[0] != null);
    try std.testing.expect(cfg.bindings_b[0] != null);
    try std.testing.expect(cfg.bindings[1] != null);
    try std.testing.expect(cfg.bindings_a[1] == null);
    try std.testing.expect(cfg.bindings_b[1] == null);
}

test "Config.binding_for: mode-specific override wins, missing falls back" {
    const text =
        \\[bindings]
        \\g4 = "f13"
        \\g5 = "f14"
        \\
        \\[bindings.a]
        \\g4 = "super+left"
    ;
    var cfg = try Config.parse(std.testing.allocator, text);
    defer cfg.deinit();
    const a_g4 = cfg.binding_for(.a, 0).?;
    try std.testing.expectEqual(@as(u16, c.KEY_LEFT), a_g4.keycode);
    const b_g4 = cfg.binding_for(.b, 0).?;
    try std.testing.expectEqual(@as(u16, c.KEY_F13), b_g4.keycode);
    const a_g5 = cfg.binding_for(.a, 1).?;
    try std.testing.expectEqual(@as(u16, c.KEY_F14), a_g5.keycode);
    const b_g5 = cfg.binding_for(.b, 1).?;
    try std.testing.expectEqual(@as(u16, c.KEY_F14), b_g5.keycode);
}
