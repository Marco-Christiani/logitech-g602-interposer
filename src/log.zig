//! Runtime-configurable log level.

const std = @import("std");

var runtime_level: std.atomic.Value(u8) = .init(@intFromEnum(std.log.Level.info));

pub fn setLevel(level: std.log.Level) void {
    runtime_level.store(@intFromEnum(level), .monotonic);
}

pub fn getLevel() std.log.Level {
    return @enumFromInt(runtime_level.load(.monotonic));
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const threshold = runtime_level.load(.monotonic);
    if (@intFromEnum(level) > threshold) return;
    std.log.defaultLog(level, scope, format, args);
}
