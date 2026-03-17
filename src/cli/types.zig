const std = @import("std");
const mere = @import("mere");
const ui = mere.ui;

/// Standard error vocabulary for CLI operations
/// This mirrors the MereError from src/errors.zig to avoid module conflicts
pub const MereError = error{
    /// User-supplied data that fails validation
    InvalidInput,
    /// Required CLI argument not provided
    MissingArgument,

    /// Network connectivity or protocol issues
    Network,
    /// File/directory operations that fail
    FileSystem,
    /// Access control violations
    PermissionDenied,

    /// Data integrity check failures
    CorruptData,
    /// Cryptographic verification failures
    SignatureInvalid,

    /// Memory allocation failures
    OutOfMemory,
    /// Insufficient disk space
    OutOfDisk,
    /// File handle exhaustion
    TooManyFiles,

    /// Unexpected errors indicating bugs
    Internal,
};

/// Flag types supported by the CLI system
pub const FlagType = enum {
    bool,
    string,
    int,
};

/// Flag definition
pub const Flag = struct {
    name: []const u8,
    short: ?u8 = null,
    description: []const u8,
    flag_type: FlagType,
    value_name: ?[]const u8 = null,
    value_optional: bool = false,
    required: bool = false,
    default_value: ?[]const u8 = null,
};

/// Argument definition
pub const Arg = struct {
    name: []const u8,
    description: []const u8,
    required: bool = true,
};

/// Parsed flag value
pub const FlagValue = union(FlagType) {
    bool: bool,
    string: []const u8,
    int: i64,
};

/// Parsed command arguments and flags
pub const ParsedArgs = struct {
    command_path: [][]const u8, // Full path like ["dev", "import"]
    positional: [][]const u8,
    flags: std.StringHashMap(FlagValue),
    global_flags: std.StringHashMap(FlagValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ParsedArgs {
        return ParsedArgs{
            .command_path = &[_][]const u8{},
            .positional = &[_][]const u8{},
            .flags = std.StringHashMap(FlagValue).init(allocator),
            .global_flags = std.StringHashMap(FlagValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParsedArgs) void {
        self.flags.deinit();
        self.global_flags.deinit();
        if (self.command_path.len > 0) {
            self.allocator.free(self.command_path);
        }
        if (self.positional.len > 0) {
            self.allocator.free(self.positional);
        }
    }

    /// Get a flag value, checking both command and global flags
    pub fn getFlag(self: *const ParsedArgs, name: []const u8) ?FlagValue {
        return self.flags.get(name) orelse self.global_flags.get(name);
    }

    /// Get a boolean flag value
    pub fn getBool(self: *const ParsedArgs, name: []const u8) bool {
        if (self.getFlag(name)) |value| {
            return switch (value) {
                .bool => |b| b,
                else => false,
            };
        }
        return false;
    }

    /// Get a string flag value
    pub fn getString(self: *const ParsedArgs, name: []const u8) ?[]const u8 {
        if (self.getFlag(name)) |value| {
            return switch (value) {
                .string => |s| s,
                else => null,
            };
        }
        return null;
    }

    /// Get an integer flag value
    pub fn getInt(self: *const ParsedArgs, name: []const u8) ?i64 {
        if (self.getFlag(name)) |value| {
            return switch (value) {
                .int => |i| i,
                else => null,
            };
        }
        return null;
    }
};

/// Command execution result
pub const CommandResult = struct {
    success: bool = true,
    exit_code: u8 = 0,
    message: ?[]const u8 = null,
    segments: ?[]const ui.Segment = null,

    /// Create error result with formatted message
    pub fn createError(allocator: std.mem.Allocator, exit_code: u8, comptime fmt: []const u8, args: anytype) !CommandResult {
        return CommandResult{
            .success = false,
            .exit_code = exit_code,
            .message = try std.fmt.allocPrint(allocator, fmt, args),
        };
    }

    /// Create success result with optional message
    pub fn createSuccess(message: ?[]const u8) CommandResult {
        return CommandResult{
            .success = true,
            .message = message,
        };
    }

    pub fn createSuccessSegments(allocator: std.mem.Allocator, segments: []const ui.Segment) !CommandResult {
        var owned = try allocator.alloc(ui.Segment, segments.len);
        errdefer allocator.free(owned);

        var i: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                allocator.free(owned[j].text);
            }
        }

        while (i < segments.len) : (i += 1) {
            owned[i] = .{
                .text = try allocator.dupe(u8, segments[i].text),
                .kind = segments[i].kind,
            };
        }

        return CommandResult{
            .success = true,
            .segments = owned,
        };
    }
};
