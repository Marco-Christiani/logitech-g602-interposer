//! Entry point. Arg parsing, config resolution, wiring.

const std = @import("std");
const builtin = @import("builtin");

const linux = @import("linux.zig");
const config_mod = @import("config.zig");
const daemon = @import("daemon.zig");
const log_mod = @import("log.zig");
const print = std.debug.print;

const log = std.log.scoped(.@"g602/main");

pub const std_options: std.Options = .{
    // `log_mod.logFn` does the runtime filtering against level set from config.
    .log_level = .debug,
    .logFn = log_mod.logFn,
};

const usage =
    \\g602 - Logitech G602 input interposer
    \\
    \\Usage:
    \\  g602 [--config PATH] [--list-devices] [--check-config] [--help]
    \\
    \\Options:
    \\  --config, -c PATH     Load config from PATH.
    \\                        Default: $XDG_CONFIG_HOME/g602/config.toml,
    \\                        falling back to ~/.config/g602/config.toml.
    \\                        If no file is found, a built-in default is used.
    \\  --list-devices, -l    Print resolved hidraw and evdev paths, then exit.
    \\  --check-config, -C    Parse and validate the config, then exit.
    \\  --trace, -t           Print every hidraw report and evdev event to stderr
    \\                        along with classification decisions.
    \\  --help, -h            Show this message.
    \\
;

fn str_eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn str_eq_any(s: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| if (str_eq(s, c)) return true;
    return false;
}

const Cli = struct {
    config_path: ?[]const u8 = null,
    list_devices: bool = false,
    check_config: bool = false,
    trace: bool = false,
    help: bool = false,

    fn from_args(args: std.process.Args) !Cli {
        var out: Cli = .{};
        var iter = args.iterate();
        _ = iter.skip();
        while (iter.next()) |a| {
            if (str_eq_any(a, &.{ "--help", "-h" })) {
                out.help = true;
            } else if (str_eq_any(a, &.{ "--list-devices", "-l" })) {
                out.list_devices = true;
            } else if (str_eq_any(a, &.{ "--check-config", "-C" })) {
                out.check_config = true;
            } else if (str_eq_any(a, &.{ "--trace", "-t" })) {
                out.trace = true;
            } else if (str_eq_any(a, &.{ "--config", "-c" })) {
                out.config_path = iter.next() orelse return error.MissingArgument;
            } else {
                return error.UnknownArgument;
            }
        }
        return out;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena_alloc: std.mem.Allocator = init.arena.allocator();

    const cli = Cli.from_args(init.minimal.args) catch |err| {
        print("error: {s}\n\n{s}", .{ @errorName(err), usage });
        return 2;
    };

    if (cli.help) {
        print("{s}", .{usage});
        return 0;
    }

    var loaded = config_mod.Config.load(arena_alloc, init.minimal.environ, cli.config_path) catch |err| {
        print("error: failed to load config: {s}\n", .{@errorName(err)});
        return 1;
    };
    log_mod.setLevel(loaded.cfg.log_level);

    if (cli.check_config) {
        print("config OK\n", .{});
        loaded.cfg.deinit();
        return 0;
    }

    // Resolve devices
    const hidraw_path = if (loaded.cfg.hidraw_path) |p| try arena_alloc.dupe(u8, p) else null;
    const evdev_path = if (loaded.cfg.evdev_path) |p| try arena_alloc.dupe(u8, p) else null;

    // Always run the resolver, even when the user has explicit [devices] paths.
    //  The auto-resolved answer is used as a fallback when paths are missing,
    //  and as a sanity check that warns when the explicit path disagrees with
    //  what the resolver would have chosen (typically a stale [devices] block
    //  pointing at a /dev node that has since been renumbered).
    var auto_res: ?linux.DeviceResolution = null;
    defer if (auto_res) |r| r.free(arena_alloc);
    auto_res = linux.resolve_g602(arena_alloc) catch |err| blk: {
        if (hidraw_path == null or evdev_path == null) {
            print("error: failed to resolve G602 device: {s}\n", .{@errorName(err)});
            print("hint: set [devices] hidraw = ... and evdev = ... in config\n", .{});
            return 1;
        }
        log.debug("auto-resolution failed ({s}); using explicit [devices] paths", .{@errorName(err)});
        break :blk null;
    };

    if (hidraw_path != null or evdev_path != null) {
        log.warn("[devices] override in use; disables auto-resolution and may break across receiver replugs (paths shift) -- remove from config.toml unless debugging", .{});
    }
    if (auto_res) |a| {
        if (hidraw_path) |p| if (!std.mem.eql(u8, p, a.hidraw_path)) {
            log.warn("config hidraw '{s}' differs from auto-resolved '{s}' (config wins)", .{ p, a.hidraw_path });
        };
        if (evdev_path) |p| if (!std.mem.eql(u8, p, a.evdev_path)) {
            log.warn("config evdev '{s}' differs from auto-resolved '{s}' (config wins)", .{ p, a.evdev_path });
        };
    }

    const resolved_hidraw = hidraw_path orelse auto_res.?.hidraw_path;
    const resolved_evdev = evdev_path orelse auto_res.?.evdev_path;

    if (cli.list_devices) {
        print("Selected:\n  hidraw: {s}\n  evdev:  {s}\n\n", .{ resolved_hidraw, resolved_evdev });
        print("All matching G602 nodes:\n", .{});
        var nodes = linux.list_all_matching(arena_alloc) catch |err| {
            print("  (listing failed: {s})\n", .{@errorName(err)});
            loaded.cfg.deinit();
            return 0;
        };
        defer {
            for (nodes.items) |n| n.free(arena_alloc);
            nodes.deinit(arena_alloc);
        }
        for (nodes.items) |n| {
            switch (n.kind) {
                .hidraw => {
                    if (n.caps_key.len != 0) {
                        print("  hidraw  {s}  name=\"{s}\"  [{s}]\n", .{ n.path, n.name, n.caps_key });
                    } else {
                        print("  hidraw  {s}  name=\"{s}\"\n", .{ n.path, n.name });
                    }
                },
                .evdev => print("  evdev   {s}  name=\"{s}\"  rel=\"{s}\"  key=\"{s}\"\n", .{ n.path, n.name, n.caps_rel, n.caps_key }),
            }
        }
        loaded.cfg.deinit();
        return 0;
    }

    // Run the daemon (ownership of config transfers)
    daemon.run(arena_alloc, .{
        .config = loaded.cfg,
        .config_path = loaded.path,
        .hidraw_path = resolved_hidraw,
        .evdev_path = resolved_evdev,
        .trace = cli.trace,
    }) catch |err| {
        log.err("daemon exited with error: {s}", .{@errorName(err)});
        return err;
    };

    return 0;
}

test {
    _ = @import("g602.zig");
    _ = @import("config.zig");
    _ = @import("linux.zig");
}
