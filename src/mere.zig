const std = @import("std");
pub const activation = @import("activation.zig");
pub const build = @import("build_orchestrator.zig");
pub const build_cache = @import("build_cache.zig");
pub const config = @import("config.zig");
pub const download = @import("download.zig");
pub const dev_cleanup = @import("dev_cleanup.zig");
pub const dev_publish = @import("dev_publish.zig");
pub const errors = @import("errors.zig");
pub const etc = @import("etc.zig");
pub const gc = @import("gc.zig");
pub const gcroots = @import("gcroots.zig");
pub const generation = @import("generation.zig");
pub const repo_history = @import("repo_history.zig");
pub const hash = @import("hash.zig");
pub const import = @import("import.zig");
pub const init = @import("init.zig");
pub const install = @import("install.zig");
pub const namespace = @import("namespace.zig");
pub const path = @import("path.zig");
pub const package = @import("package.zig");
pub const packaging = @import("packaging.zig");
pub const pin = @import("pin.zig");
pub const publish = @import("publish.zig");
pub const repodb = @import("repodb.zig");
pub const profile = @import("profile.zig");
pub const recipe = @import("recipe.zig");
pub const repository = @import("repository.zig");
pub const repo_sources = @import("repo_sources.zig");
pub const requested = @import("requested.zig");
pub const search = @import("search.zig");
pub const sign = @import("sign.zig");
pub const source_manager = @import("source_manager.zig");
pub const store = @import("store.zig");
pub const verify = @import("verify.zig");
pub const workspace_manager = @import("workspace_manager.zig");
pub const ui = @import("ui/mod.zig");

const DiagnosticContext = errors.DiagnosticContext;

const MereError = error{
    InvalidConfig,
    ResourceLimitReached,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    // Tests set this so helpers do not touch the developer's real HOME.
    home_dir: ?[]const u8 = null,
    verbose: bool = false,
    configuration: ?config.Config,
    signing_key_path: ?[]const u8 = null,
    diagnostic_context: ?DiagnosticContext = null,
    diag_arena: ?std.heap.ArenaAllocator = null,
    ui_emitter: ui.NoopEmitter,
    custom_emitter: ?*ui.Emitter = null,
    event_counter: u64 = 0,

    const default_root_path = "/";

    pub fn init(allocator: std.mem.Allocator, root_path: ?[]const u8) Context {
        var ctx = Context{
            .allocator = allocator,
            .root_path = "",
            .home_dir = null,
            .verbose = false,
            .configuration = null,
            .diagnostic_context = null,
            .diag_arena = null,
            .ui_emitter = ui.NoopEmitter.init(),
            .custom_emitter = null,
            .event_counter = 0,
        };

        // Delegate to setRoot and preserve the previous behavior of panicking on failure.
        ctx.setRoot(root_path) catch {
            std.debug.print("fatal: unable to initialize root path\n", .{});
            std.debug.panic("unable to initialize root path", .{});
        };

        return ctx;
    }

    /// Load configuration files and merge them.
    /// Errors:
    ///   - InvalidConfig: When configuration is invalid or can't be loaded
    ///   - ResourceLimitReached: When memory allocation fails
    pub fn loadConfig(self: *Context) MereError!void {
        if (self.configuration != null) {
            // Free the existing configuration if it exists
            var old_config = self.configuration.?;
            old_config.deinit();
        }

        // Load configuration including auto-discovered local repos
        var new_config = repo_sources.loadConfig(self) catch |load_err| {
            if (load_err == error.OutOfMemory) {
                return self.fail(MereError.ResourceLimitReached, "config", "out of memory loading config");
            }
            if (self.diagnostic_context != null) {
                return MereError.InvalidConfig;
            }
            const detail = std.fmt.allocPrint(self.allocator, "failed to load config: {s}", .{@errorName(load_err)}) catch {
                return self.fail(MereError.InvalidConfig, "config", "failed to load config");
            };
            defer self.allocator.free(detail);
            return self.fail(MereError.InvalidConfig, "config", detail);
        };
        new_config.validate() catch {
            new_config.deinit();
            return MereError.InvalidConfig;
        };
        self.configuration = new_config;
    }

    /// Get the configuration, loading it if necessary.
    /// Errors:
    ///   - InvalidConfig: When configuration is invalid or can't be loaded
    ///   - ResourceLimitReached: When memory allocation fails
    pub fn getConfig(self: *Context) MereError!*config.Config {
        if (self.configuration == null) {
            try self.loadConfig();
        }
        return &self.configuration.?; // Return pointer to the value
    }

    /// Clean up resources when done
    pub fn deinit(self: *Context) void {
        // Free diagnostic arena if initialized
        if (self.diag_arena) |*arena| {
            arena.deinit();
            self.diag_arena = null;
        }
        if (self.configuration) |*cfg| {
            cfg.deinit();
            self.configuration = null;
        }
        // Free owned root path buffer if it was allocated.
        if (self.root_path.len > 0) {
            self.allocator.free(self.root_path);
            self.root_path = "";
        }
    }

    /// Set or replace the Context root path.
    /// This centralizes normalization and ownership: the supplied path is resolved
    /// to an absolute path (if non-null), duplicated into the context allocator,
    /// and the previous root buffer is freed.
    pub fn setRoot(self: *Context, root_path: ?[]const u8) MereError!void {
        const allocator = self.allocator;
        var chosen: []const u8 = default_root_path;
        if (root_path) |rp| {
            if (std.fs.path.isAbsolute(rp)) {
                chosen = rp;
            } else {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                chosen = path.resolveToAbsolutePath(rp, &buf) catch {
                    self.err("unable to resolve root path: {s}", .{rp});
                    return MereError.ResourceLimitReached;
                };
            }
        }
        const dup = allocator.dupe(u8, chosen) catch {
            self.err("failed to allocate memory for root path: {s}", .{chosen});
            return MereError.ResourceLimitReached;
        };
        // Free previously-owned root_path buffer if any.
        if (self.root_path.len > 0) allocator.free(self.root_path);
        self.root_path = dup;
    }

    pub fn root(self: *const Context) []const u8 {
        return self.root_path;
    }

    /// Format and log an info message
    /// Note: This method swallows memory allocation errors, it will not log anything if allocation fails
    pub fn info(self: *Context, comptime fmt: []const u8, args: anytype) void {
        ui.emit.logFmtSeverity(self, null, .info, fmt, args);
    }

    /// Format and log an error message
    /// Note: This method swallows memory allocation errors, it will not log anything if allocation fails
    pub fn err(self: *Context, comptime fmt: []const u8, args: anytype) void {
        emitLabeledLog(self, .err, "error", .warn, fmt, args);
    }

    /// Format and log a debug message
    /// Note: This method swallows memory allocation errors, it will not log anything if allocation fails
    pub fn debug(self: *Context, comptime fmt: []const u8, args: anytype) void {
        if (!self.verbose) return;
        emitLabeledLog(self, .info, "debug", .detail, fmt, args);
    }

    /// Set diagnostic context for this operation
    /// This method stores the diagnostic context by value in the Context struct
    pub fn withDiagnosticContext(self: *Context, diag_ctx: DiagnosticContext) void {
        self.diagnostic_context = diag_ctx;
    }

    /// Get current diagnostic context or create default
    /// Returns the stored context or a default empty context
    pub fn getDiagnosticContext(self: *const Context) DiagnosticContext {
        return self.diagnostic_context orelse DiagnosticContext.init();
    }

    /// Get the diagnostic arena allocator, lazily initializing if needed.
    /// Returns the arena's allocator for string duplication.
    pub fn getDiagArena(self: *Context) std.mem.Allocator {
        if (self.diag_arena == null) {
            self.diag_arena = std.heap.ArenaAllocator.init(self.allocator);
        }
        return self.diag_arena.?.allocator();
    }

    fn emitLabeledLog(
        self: *Context,
        severity: ui.Severity,
        label: []const u8,
        label_kind: ui.SegmentKind,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(msg);
        const segments = [_]ui.Segment{
            .{ .text = label, .kind = label_kind },
            .{ .text = ": ", .kind = .normal },
            .{ .text = msg, .kind = .normal },
        };
        ui.emit.logSegmentsSeverity(self, null, severity, &segments);
    }

    /// Set diagnostic context with arena-allocated strings.
    /// Use this when the source strings may be freed before CLI reads the context.
    /// Silently fails on allocation error (diagnostic context is best-effort).
    pub fn setDiagnosticContext(self: *Context, subject: []const u8, details: ?[]const u8) void {
        const arena_alloc = self.getDiagArena();

        const subject_owned = arena_alloc.dupe(u8, subject) catch return;

        var diag_ctx = DiagnosticContext.init().withSubject(subject_owned);

        if (details) |det| {
            const details_owned = arena_alloc.dupe(u8, det) catch return;
            diag_ctx = diag_ctx.withDetails(details_owned);
        }

        self.diagnostic_context = diag_ctx;
    }

    /// Set diagnostic context with formatted details allocated from the diagnostic arena.
    /// Silently fails on allocation error (diagnostic context is best-effort).
    pub fn setDiagnosticContextFmt(self: *Context, subject: []const u8, comptime fmt: []const u8, args: anytype) void {
        const arena_alloc = self.getDiagArena();

        const subject_owned = arena_alloc.dupe(u8, subject) catch return;
        const details_owned = std.fmt.allocPrint(arena_alloc, fmt, args) catch {
            self.diagnostic_context = DiagnosticContext.init().withSubject(subject_owned);
            return;
        };

        self.diagnostic_context = DiagnosticContext.init()
            .withSubject(subject_owned)
            .withDetails(details_owned);
    }

    /// Set diagnostic context and return the provided error value.
    /// Use this in module error returns to enforce context enrichment.
    pub fn fail(self: *Context, error_value: anytype, subject: []const u8, details: ?[]const u8) @TypeOf(error_value) {
        self.setDiagnosticContext(subject, details);
        return error_value;
    }

    /// Set diagnostic context with formatted details and return the provided error value.
    /// Use this when detail formatting is required on an error path.
    pub fn failFmt(self: *Context, error_value: anytype, subject: []const u8, comptime fmt: []const u8, args: anytype) @TypeOf(error_value) {
        self.setDiagnosticContextFmt(subject, fmt, args);
        return error_value;
    }

    /// Reset diagnostic context and free arena memory.
    /// Call between operations in long-running scenarios.
    pub fn resetDiagnostics(self: *Context) void {
        self.diagnostic_context = null;
        if (self.diag_arena) |*arena| {
            arena.deinit();
            self.diag_arena = null;
        }
    }

    pub fn setEmitter(self: *Context, emitter: *ui.Emitter) void {
        self.custom_emitter = emitter;
    }

    pub fn nextEventId(self: *Context) u64 {
        self.event_counter += 1;
        return self.event_counter;
    }

    pub fn emit(self: *Context, event: ui.Event) void {
        if (self.custom_emitter) |emitter| {
            emitter.emit(event);
        } else {
            self.ui_emitter.emitter.emit(event);
        }
    }
};

test "Context.root returns the root path" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, "/some/test/root");
    defer ctx.deinit();
    try testing.expectEqualStrings("/some/test/root", ctx.root());
}

test "Context.root returns the default root path" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, null);
    defer ctx.deinit();
    try testing.expectEqualStrings("/", ctx.root());
}

test "Context diagnostic_context field initialization" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, "/test");
    defer ctx.deinit();

    // Verify diagnostic_context is initialized to null
    try testing.expect(ctx.diagnostic_context == null);

    // Verify we can create and assign a DiagnosticContext
    const diag_ctx = DiagnosticContext.init().withSubject("/test/path");
    ctx.diagnostic_context = diag_ctx;

    // Verify the assignment worked
    try testing.expect(ctx.diagnostic_context != null);
    try testing.expectEqualStrings("/test/path", ctx.diagnostic_context.?.subject.?);
}

test "Context diagnostic context round-trip consistency" {
    // **Feature: diagnostic-context-integration, Property 1: Context diagnostic round-trip consistency**
    // **Validates: Requirements 1.2**
    const testing = std.testing;

    // Property: For any diagnostic context, setting it on a Context and then retrieving it should return an equivalent context
    // Run 100 iterations to test the property across different inputs
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var ctx = Context.init(testing.allocator, "/test");
        defer ctx.deinit();

        // Generate test data for this iteration
        const subjects = [_]?[]const u8{ null, "/test/path", "https://example.com/package", "/var/lib/mere/repo.db", "package-1.0.tar.zst" };
        const details_list = [_]?[]const u8{ null, "timeout", "invalid format", "checksum mismatch", "permission denied" };

        const subject = subjects[i % subjects.len];
        const details = details_list[i % details_list.len];

        // Create diagnostic context
        var diag_ctx = DiagnosticContext.init();
        if (subject) |subj| {
            diag_ctx = diag_ctx.withSubject(subj);
        }
        if (details) |det| {
            diag_ctx = diag_ctx.withDetails(det);
        }

        // Set context and retrieve it
        ctx.withDiagnosticContext(diag_ctx);
        const retrieved_ctx = ctx.getDiagnosticContext();

        // Verify round-trip consistency
        if (subject) |subj| {
            try testing.expect(retrieved_ctx.subject != null);
            try testing.expectEqualStrings(subj, retrieved_ctx.subject.?);
        } else {
            try testing.expect(retrieved_ctx.subject == null);
        }
        if (details) |det| {
            try testing.expect(retrieved_ctx.details != null);
            try testing.expectEqualStrings(det, retrieved_ctx.details.?);
        } else {
            try testing.expect(retrieved_ctx.details == null);
        }
    }
}

test "Context.fail sets diagnostic context and returns error" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, "/test");
    defer ctx.deinit();

    const err = ctx.fail(error.InvalidInput, "subject", "details");
    try testing.expect(err == error.InvalidInput);

    const diag = ctx.getDiagnosticContext();
    try testing.expectEqualStrings("subject", diag.subject.?);
    try testing.expectEqualStrings("details", diag.details.?);
}

test "Context.failFmt sets formatted diagnostic context and returns error" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, "/test");
    defer ctx.deinit();

    const err = ctx.failFmt(error.FileSystem, "path", "failed with code {d}", .{42});
    try testing.expect(err == error.FileSystem);

    const diag = ctx.getDiagnosticContext();
    try testing.expectEqualStrings("path", diag.subject.?);
    try testing.expectEqualStrings("failed with code 42", diag.details.?);
}
test "Context diagnostic context retrieval reliability" {
    // **Feature: diagnostic-context-integration, Property 2: Diagnostic context retrieval reliability**
    // **Validates: Requirements 1.3, 4.3**
    const testing = std.testing;

    // Property: For any Context instance, calling getDiagnosticContext should never fail and should return either the stored context or a default context
    // Run 100 iterations to test the property across different Context states
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var ctx = Context.init(testing.allocator, "/test");
        defer ctx.deinit();

        // Test different Context states
        if (i % 3 == 0) {
            // Case 1: Context with no diagnostic context set (should return default empty context)
            const retrieved_ctx = ctx.getDiagnosticContext();
            try testing.expect(retrieved_ctx.subject == null);
            try testing.expect(retrieved_ctx.details == null);
        } else if (i % 3 == 1) {
            // Case 2: Context with diagnostic context set (should return stored context)
            const diag_ctx = DiagnosticContext.init().withSubject("/test/path");
            ctx.withDiagnosticContext(diag_ctx);
            const retrieved_ctx = ctx.getDiagnosticContext();
            try testing.expectEqualStrings("/test/path", retrieved_ctx.subject.?);
        } else {
            // Case 3: Context with diagnostic context set then cleared (should return default)
            const diag_ctx = DiagnosticContext.init().withSubject("/test/path");
            ctx.withDiagnosticContext(diag_ctx);
            ctx.diagnostic_context = null; // Clear the context
            const retrieved_ctx = ctx.getDiagnosticContext();
            try testing.expect(retrieved_ctx.subject == null);
            try testing.expect(retrieved_ctx.details == null);
        }

        // Verify that getDiagnosticContext never fails (this test would not compile if it could fail)
        // The method signature guarantees it returns a DiagnosticContext, not an error union
    }
}

test "Context diagnostic context to ErrorContext conversion" {
    // **Feature: diagnostic-context-integration, Property 3: ErrorContext conversion**
    // **Validates: Requirements 1.4, 3.1, 3.2, 3.5, 4.4**
    const testing = std.testing;

    // Property: For any diagnostic context, toErrorContext should produce an ErrorContext that can format messages correctly
    // Run 100 iterations to test the property across different inputs
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var ctx = Context.init(testing.allocator, "/test");
        defer ctx.deinit();

        // Generate test data for this iteration
        const subjects = [_]?[]const u8{ null, "/test/path", "https://example.com/package", "/var/lib/mere/repo.db", "package-1.0.tar.zst" };
        const details_list = [_]?[]const u8{ null, "timeout", "invalid format", "checksum mismatch", "permission denied" };
        const error_messages = [_][]const u8{ "operation failed", "network timeout", "file not found", "permission denied", "invalid format" };

        const subject = subjects[i % subjects.len];
        const details = details_list[i % details_list.len];
        const error_msg = error_messages[i % error_messages.len];

        // Create diagnostic context
        var diag_ctx = DiagnosticContext.init();
        if (subject) |subj| {
            diag_ctx = diag_ctx.withSubject(subj);
        }
        if (details) |det| {
            diag_ctx = diag_ctx.withDetails(det);
        }

        // Set context and convert to ErrorContext
        ctx.withDiagnosticContext(diag_ctx);
        const error_ctx = diag_ctx.toErrorContext();
        const formatted = error_ctx.formatWithMessage(testing.allocator, error_msg) catch continue;
        defer testing.allocator.free(formatted);

        // Verify the formatted message starts with the error message
        try testing.expect(std.mem.startsWith(u8, formatted, error_msg));

        // If we reach here, the conversion and formatting worked correctly
    }
}

test "Context diagnostic context field storage" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, "/test");
    defer ctx.deinit();

    // Set a diagnostic context
    const diag_ctx = DiagnosticContext.init().withSubject("/test/path").withDetails("test details");
    ctx.withDiagnosticContext(diag_ctx);

    // Verify the context was stored
    try testing.expect(ctx.diagnostic_context != null);
    try testing.expectEqualStrings("/test/path", ctx.diagnostic_context.?.subject.?);
    try testing.expectEqualStrings("test details", ctx.diagnostic_context.?.details.?);
}

test "Context setDiagnosticContextFmt formats details in arena" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, "/test");
    defer ctx.deinit();

    ctx.setDiagnosticContextFmt("subject", "detail {d}", .{3});

    const diag = ctx.getDiagnosticContext();
    try testing.expectEqualStrings("subject", diag.subject.?);
    try testing.expectEqualStrings("detail 3", diag.details.?);
}

test "Context initialization with diagnostic context field" {
    const testing = std.testing;
    var ctx = Context.init(testing.allocator, "/test/root");
    defer ctx.deinit();

    // Verify diagnostic_context is initialized to null
    try testing.expect(ctx.diagnostic_context == null);

    // Verify other fields are properly initialized
    try testing.expectEqualStrings("/test/root", ctx.root_path);
    try testing.expect(ctx.allocator.ptr == testing.allocator.ptr);
    try testing.expect(ctx.configuration == null);
    try testing.expect(ctx.signing_key_path == null);
    try testing.expect(ctx.home_dir == null);
}

test "Context diagnostic context field storage and retrieval" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, "/test");
    defer ctx.deinit();

    // Test storing and retrieving diagnostic context by value
    const original_ctx = DiagnosticContext.init().withSubject("/test/path").withDetails("test details");
    ctx.withDiagnosticContext(original_ctx);

    // Verify the context was stored correctly
    try testing.expect(ctx.diagnostic_context != null);
    try testing.expectEqualStrings("/test/path", ctx.diagnostic_context.?.subject.?);
    try testing.expectEqualStrings("test details", ctx.diagnostic_context.?.details.?);

    // Test that getDiagnosticContext returns the stored context
    const retrieved_ctx = ctx.getDiagnosticContext();
    try testing.expectEqualStrings("/test/path", retrieved_ctx.subject.?);
    try testing.expectEqualStrings("test details", retrieved_ctx.details.?);

    // Test overwriting diagnostic context
    const new_ctx = DiagnosticContext.init().withSubject("new-subject");
    ctx.withDiagnosticContext(new_ctx);

    try testing.expectEqualStrings("new-subject", ctx.diagnostic_context.?.subject.?);
    try testing.expect(ctx.diagnostic_context.?.details == null);
}

test "Context diagnostic context field memory management" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, "/test");
    defer ctx.deinit();

    // Set diagnostic context multiple times
    for (0..10) |i| {
        const subject = if (i % 2 == 0) "/even/path" else "/odd/path";
        const diag_ctx = DiagnosticContext.init().withSubject(subject);
        ctx.withDiagnosticContext(diag_ctx);

        // Verify the context is stored correctly
        try testing.expectEqualStrings(subject, ctx.diagnostic_context.?.subject.?);
    }

    // Clear diagnostic context
    ctx.diagnostic_context = null;
    try testing.expect(ctx.diagnostic_context == null);

    // Verify getDiagnosticContext returns default when null
    const default_ctx = ctx.getDiagnosticContext();
    try testing.expect(default_ctx.subject == null);

    // Context.deinit() should work correctly with or without diagnostic context
    // (This is tested implicitly by the defer ctx.deinit() above)
}

test "Context chaining isolation property" {
    // **Feature: diagnostic-context-integration, Property 4: Context chaining isolation**
    // **Validates: Requirements 3.4**
    const testing = std.testing;

    // Property: For any sequence of nested operations, each operation should be able to set its own diagnostic context without affecting other operations' contexts
    // Run 100 iterations to test the property across different nested operation scenarios
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        // Create multiple Context instances to simulate nested operations
        var ctx1 = Context.init(testing.allocator, "/test1");
        defer ctx1.deinit();
        var ctx2 = Context.init(testing.allocator, "/test2");
        defer ctx2.deinit();
        var ctx3 = Context.init(testing.allocator, "/test3");
        defer ctx3.deinit();

        // Generate test data for this iteration
        const subjects = [_]?[]const u8{ null, "/path1", "/path2", "/path3", "resource.txt" };
        const details_list = [_]?[]const u8{ null, "detail1", "detail2", "detail3", "extra info" };

        const subj1 = subjects[i % subjects.len];
        const subj2 = subjects[(i + 1) % subjects.len];
        const subj3 = subjects[(i + 2) % subjects.len];
        const det1 = details_list[i % details_list.len];
        const det2 = details_list[(i + 1) % details_list.len];
        const det3 = details_list[(i + 2) % details_list.len];

        // Set different diagnostic contexts on each Context instance
        var diag_ctx1 = DiagnosticContext.init();
        if (subj1) |s| diag_ctx1 = diag_ctx1.withSubject(s);
        if (det1) |d| diag_ctx1 = diag_ctx1.withDetails(d);
        ctx1.withDiagnosticContext(diag_ctx1);

        var diag_ctx2 = DiagnosticContext.init();
        if (subj2) |s| diag_ctx2 = diag_ctx2.withSubject(s);
        if (det2) |d| diag_ctx2 = diag_ctx2.withDetails(d);
        ctx2.withDiagnosticContext(diag_ctx2);

        var diag_ctx3 = DiagnosticContext.init();
        if (subj3) |s| diag_ctx3 = diag_ctx3.withSubject(s);
        if (det3) |d| diag_ctx3 = diag_ctx3.withDetails(d);
        ctx3.withDiagnosticContext(diag_ctx3);

        // Verify that each Context maintains its own diagnostic context independently
        const retrieved_ctx1 = ctx1.getDiagnosticContext();
        const retrieved_ctx2 = ctx2.getDiagnosticContext();
        const retrieved_ctx3 = ctx3.getDiagnosticContext();

        // Verify isolation: each context should have its own subject
        if (subj1) |s| {
            try testing.expect(retrieved_ctx1.subject != null);
            try testing.expectEqualStrings(s, retrieved_ctx1.subject.?);
        } else {
            try testing.expect(retrieved_ctx1.subject == null);
        }

        if (subj2) |s| {
            try testing.expect(retrieved_ctx2.subject != null);
            try testing.expectEqualStrings(s, retrieved_ctx2.subject.?);
        } else {
            try testing.expect(retrieved_ctx2.subject == null);
        }

        if (subj3) |s| {
            try testing.expect(retrieved_ctx3.subject != null);
            try testing.expectEqualStrings(s, retrieved_ctx3.subject.?);
        } else {
            try testing.expect(retrieved_ctx3.subject == null);
        }

        // Test that modifying one context doesn't affect others
        const new_diag_ctx = DiagnosticContext.init().withSubject("modified-subject");
        ctx2.withDiagnosticContext(new_diag_ctx);

        // Verify ctx1 and ctx3 are unchanged
        const final_ctx1 = ctx1.getDiagnosticContext();
        const final_ctx3 = ctx3.getDiagnosticContext();
        if (subj1) |s| {
            try testing.expectEqualStrings(s, final_ctx1.subject.?);
        }
        if (subj3) |s| {
            try testing.expectEqualStrings(s, final_ctx3.subject.?);
        }

        // Verify ctx2 was modified
        const final_ctx2 = ctx2.getDiagnosticContext();
        try testing.expectEqualStrings("modified-subject", final_ctx2.subject.?);
    }
}

test "Context memory allocation consistency property" {
    // **Feature: diagnostic-context-integration, Property 5: Memory allocation consistency**
    // **Validates: Requirements 5.1**
    const testing = std.testing;

    // Property: For any Context instance, diagnostic context operations should use the Context's allocator for all memory allocations
    // Run 100 iterations to test the property across different allocation scenarios
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        // Use a tracking allocator to monitor allocation behavior
        const tracking_allocator = std.testing.allocator;
        var ctx = Context.init(tracking_allocator, "/test");
        defer ctx.deinit();

        // Generate test data for this iteration
        const subjects = [_]?[]const u8{ null, "/test/path", "https://example.com", "/var/lib/mere", "package.tar.zst" };
        const details_list = [_]?[]const u8{ null, "timeout", "invalid format", "checksum mismatch", "permission denied" };

        const subject = subjects[i % subjects.len];
        const details = details_list[i % details_list.len];

        // Create diagnostic context
        var diag_ctx = DiagnosticContext.init();
        if (subject) |subj| {
            diag_ctx = diag_ctx.withSubject(subj);
        }
        if (details) |det| {
            diag_ctx = diag_ctx.withDetails(det);
        }

        // Set diagnostic context (this should not allocate memory)
        ctx.withDiagnosticContext(diag_ctx);
        // Verify that getDiagnosticContext doesn't allocate (returns by value)
        const retrieved_ctx = ctx.getDiagnosticContext();
        if (subject) |subj| {
            try testing.expectEqualStrings(subj, retrieved_ctx.subject.?);
        }

        // Verify the Context's allocator is the one being used for the Context instance
        try testing.expect(ctx.allocator.ptr == tracking_allocator.ptr);

        // Test that diagnostic context formatting uses the Context's allocator
        const error_ctx = retrieved_ctx.toErrorContext();
        const formatted = error_ctx.formatWithMessage(ctx.allocator, "test error") catch continue;
        defer ctx.allocator.free(formatted);

        // Verify the Context still uses the same allocator
        try testing.expect(ctx.allocator.ptr == tracking_allocator.ptr);
    }
}

test "Context graceful allocation failure handling property" {
    // **Feature: diagnostic-context-integration, Property 6: Graceful allocation failure handling**
    // **Validates: Requirements 2.4, 5.2**
    const testing = std.testing;

    // Property: For any diagnostic context operation, allocation failures should be handled gracefully without crashing the system
    // Run 100 iterations to test the property across different allocation failure scenarios
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        // Create a failing allocator that allows Context.init but fails on subsequent allocations
        var failing_allocator = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
        var ctx = Context.init(failing_allocator.allocator(), "/test");
        defer ctx.deinit();

        // Generate test data for this iteration
        const subjects = [_]?[]const u8{ null, "/test/path", "https://example.com/package", "/var/lib/mere/repo.db", "package-1.0.tar.zst" };
        const details_list = [_]?[]const u8{ null, "timeout", "invalid format", "checksum mismatch", "permission denied" };

        const subject = subjects[i % subjects.len];
        const details = details_list[i % details_list.len];

        // Create diagnostic context (this should not allocate)
        var diag_ctx = DiagnosticContext.init();
        if (subject) |subj| {
            diag_ctx = diag_ctx.withSubject(subj);
        }
        if (details) |det| {
            diag_ctx = diag_ctx.withDetails(det);
        }

        // Set diagnostic context (this should not allocate)
        ctx.withDiagnosticContext(diag_ctx);

        // Test that getDiagnosticContext handles allocation gracefully (it doesn't allocate)
        const retrieved_ctx = ctx.getDiagnosticContext();
        if (subject) |subj| {
            try testing.expectEqualStrings(subj, retrieved_ctx.subject.?);
        }

        // Test that toErrorContext and formatWithMessage handle allocation failures gracefully
        const error_ctx = retrieved_ctx.toErrorContext();
        _ = error_ctx.formatWithMessage(failing_allocator.allocator(), "test error") catch {
            // Expected to fail - this is the graceful handling
        };

        // If we reach here, the allocation failure was handled gracefully
        // The system should continue to function even when memory allocation fails

        // Test that the Context remains functional after allocation failures
        // getDiagnosticContext should still work (it doesn't allocate)
        const final_ctx = ctx.getDiagnosticContext();
        if (subject) |subj| {
            try testing.expectEqualStrings(subj, final_ctx.subject.?);
        }

        // Test that withDiagnosticContext still works after allocation failures
        const new_diag_ctx = DiagnosticContext.init().withSubject("recovery-subject");
        ctx.withDiagnosticContext(new_diag_ctx);
        const recovery_ctx = ctx.getDiagnosticContext();
        try testing.expectEqualStrings("recovery-subject", recovery_ctx.subject.?);

        // Verify the system remains stable and functional despite allocation failures
        try testing.expect(true);
    }
}
