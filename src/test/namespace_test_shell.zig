//! Minimal test binary that verifies the namespace environment is set up correctly.
//! Used by namespace integration tests as a stand-in for a real interactive shell.
//!
//! Usage: namespace_test_shell [--build]
//!   --build: Also check build mode specific paths (/work)
//!
//! Exit codes: 0 = success, 1-11 = specific check failed

const std = @import("std");

pub fn main(init: std.process.Init) u8 {
    var build_mode = false;

    var args = std.process.Args.iterate(init.minimal.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--build")) {
            build_mode = true;
        }
    }

    std.Io.Dir.accessAbsolute(init.io, "/bin", .{}) catch return 1;

    if (!build_mode) {
        std.Io.Dir.accessAbsolute(init.io, "/proc", .{}) catch return 2;
        std.Io.Dir.accessAbsolute(init.io, "/tmp", .{}) catch return 3;
        std.Io.Dir.accessAbsolute(init.io, "/etc", .{}) catch return 4;
        std.Io.Dir.accessAbsolute(init.io, "/mere", .{}) catch return 5;
    }

    if (build_mode) {
        std.Io.Dir.accessAbsolute(init.io, "/work", .{}) catch return 10;
        if (std.Io.Dir.accessAbsolute(init.io, "/mere", .{})) |_| {
            return 6;
        } else |_| {}
        std.Io.Dir.accessAbsolute(init.io, "/tmp", .{}) catch return 7;
        std.Io.Dir.accessAbsolute(init.io, "/var/tmp", .{}) catch return 8;
        std.Io.Dir.accessAbsolute(init.io, "/etc", .{}) catch return 9;
        std.Io.Dir.accessAbsolute(init.io, "/dev/null", .{}) catch return 11;
    }

    return 0;
}
