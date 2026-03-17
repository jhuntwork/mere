//! Minimal test binary that verifies the namespace environment is set up correctly.
//! Used by namespace integration tests as a stand-in for a real interactive shell.
//!
//! Usage: namespace_test_shell [--build]
//!   --build: Also check build mode specific paths (/work)
//!
//! Exit codes: 0 = success, 1-11 = specific check failed

const std = @import("std");

pub fn main() u8 {
    var build_mode = false;

    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--build")) {
            build_mode = true;
        }
    }

    std.fs.accessAbsolute("/bin", .{}) catch return 1;

    if (!build_mode) {
        std.fs.accessAbsolute("/proc", .{}) catch return 2;
        std.fs.accessAbsolute("/tmp", .{}) catch return 3;
        std.fs.accessAbsolute("/etc", .{}) catch return 4;
        std.fs.accessAbsolute("/mere", .{}) catch return 5;
    }

    if (build_mode) {
        std.fs.accessAbsolute("/work", .{}) catch return 10;
        if (std.fs.accessAbsolute("/mere", .{})) |_| {
            return 6;
        } else |_| {}
        std.fs.accessAbsolute("/tmp", .{}) catch return 7;
        std.fs.accessAbsolute("/var/tmp", .{}) catch return 8;
        std.fs.accessAbsolute("/etc", .{}) catch return 9;
        std.fs.accessAbsolute("/dev/null", .{}) catch return 11;
    }

    return 0;
}
