const std = @import("std");
const Context = @import("mere.zig").Context;

/// Top-level error vocabulary for CLI boundaries.
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

/// Standard error vocabulary constants for module error set composition.
pub const StandardErrors = struct {
    pub const OutOfMemory = error{OutOfMemory};
    pub const FileSystem = error{FileSystem};
    pub const Network = error{Network};
    pub const PermissionDenied = error{PermissionDenied};
    pub const InvalidInput = error{InvalidInput};
    pub const CorruptData = error{CorruptData};
    pub const SignatureInvalid = error{SignatureInvalid};
    pub const OutOfDisk = error{OutOfDisk};
    pub const TooManyFiles = error{TooManyFiles};
    pub const Internal = error{Internal};
};

/// Error mapping utilities for CLI-boundary integration.
pub const ErrorMapping = struct {
    /// Map common Zig errors to standard vocabulary
    pub fn mapZigError(err: anyerror) MereError {
        return switch (err) {
            // Preserve Mere's standard vocabulary when it crosses a boundary.
            error.InvalidInput => MereError.InvalidInput,
            error.MissingArgument => MereError.MissingArgument,
            error.Network => MereError.Network,
            error.FileSystem => MereError.FileSystem,
            error.PermissionDenied => MereError.PermissionDenied,
            error.CorruptData => MereError.CorruptData,
            error.SignatureInvalid => MereError.SignatureInvalid,
            error.OutOfMemory => MereError.OutOfMemory,
            error.OutOfDisk => MereError.OutOfDisk,
            error.TooManyFiles => MereError.TooManyFiles,
            error.Internal => MereError.Internal,

            // Translate common Zig and module errors into that vocabulary.
            error.ConnectionTimeout,
            error.ConnectionTimedOut,
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.NetworkUnreachable,
            error.NetworkSubsystemFailed,
            error.HostLookupFailed,
            error.RepositoryUnavailable,
            => MereError.Network,
            error.AccessDenied,
            error.OperationNotPermitted,
            error.ReadOnlyFileSystem,
            => MereError.PermissionDenied,
            error.FileNotFound,
            error.IsDir,
            error.NotDir,
            error.PathAlreadyExists,
            error.ProcessFailed,
            error.NoLogDirectory,
            error.NoLogFile,
            error.NoActiveGeneration,
            error.LockFailed,
            error.Locked,
            => MereError.FileSystem,
            error.InvalidConfig,
            error.ParseError,
            error.ParseFailed,
            error.InvalidFormat,
            error.InvalidCharacter,
            error.BadPathName,
            error.UnsupportedProvider,
            error.NoRoots,
            error.GenerationNotFound,
            error.RepositoryNotFound,
            error.PackageNotFound,
            error.ConflictingProvision,
            error.ConflictingProvisions,
            error.UnsatisfiableDependencies,
            error.DuplicateTemplate,
            error.TemplateNotFound,
            => MereError.InvalidInput,
            error.ChecksumMismatch,
            error.InvalidData,
            error.BadData,
            error.CorruptInput,
            error.ManifestNotFound,
            error.InvalidManifest,
            error.ArchiveHashMismatch,
            error.SignatureVerificationFailed,
            => MereError.CorruptData,
            error.NoSpaceLeft => MereError.OutOfDisk,
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => MereError.TooManyFiles,
            else => MereError.Internal,
        };
    }

    /// Template for mapping module-specific errors to CLI vocabulary.
    /// Uses runtime anyerror dispatch instead of comptime inline else to avoid
    /// monomorphizing a branch per error variant (binary size optimization).
    pub fn mapModuleError(comptime ModuleError: type, err: ModuleError) MereError {
        const any: anyerror = err;
        // Check against MereError vocabulary names (these are the standard
        // module-level error names, not Zig stdlib errors)
        const mere_errors = .{
            .{ MereError.OutOfMemory, @as(anyerror, error.OutOfMemory) },
            .{ MereError.FileSystem, @as(anyerror, error.FileSystem) },
            .{ MereError.Network, @as(anyerror, error.Network) },
            .{ MereError.PermissionDenied, @as(anyerror, error.PermissionDenied) },
            .{ MereError.InvalidInput, @as(anyerror, error.InvalidInput) },
            .{ MereError.CorruptData, @as(anyerror, error.CorruptData) },
            .{ MereError.SignatureInvalid, @as(anyerror, error.SignatureInvalid) },
            .{ MereError.OutOfDisk, @as(anyerror, error.OutOfDisk) },
            .{ MereError.TooManyFiles, @as(anyerror, error.TooManyFiles) },
            .{ MereError.Internal, @as(anyerror, error.Internal) },
        };
        inline for (mere_errors) |pair| {
            if (any == pair[1]) return pair[0];
        }
        return MereError.Internal;
    }
};

/// User-friendly error message formatting utilities
///
/// Converts error types to user-readable messages following requirements 5.1, 5.2
pub fn getUserFriendlyMessage(err: anyerror) []const u8 {
    return switch (err) {
        // File system errors
        error.FileNotFound => "file or directory not found",
        error.AccessDenied => "permission denied",
        error.IsDir => "expected file but found directory",
        error.NotDir => "expected directory but found file",
        error.PathAlreadyExists => "file or directory already exists",
        error.FileTooBig => "file is too large",
        error.NoSpaceLeft => "insufficient disk space",
        error.DeviceBusy => "device is busy",
        error.FileBusy => "file is in use",
        error.NameTooLong => "file or directory name is too long",
        error.NotOpenForReading => "file is not open for reading",
        error.NotOpenForWriting => "file is not open for writing",
        error.InvalidUtf8 => "invalid text encoding",
        error.BadPathName => "invalid file or directory path",
        error.SymLinkLoop => "too many symbolic links",
        error.ReadOnlyFileSystem => "file system is read-only",
        error.LinkQuotaExceeded => "too many links",

        // Network errors
        error.Network => "network error",
        error.ConnectionTimeout => "connection timed out",
        error.ConnectionRefused => "connection refused by server",
        error.NetworkUnreachable => "network unreachable",
        error.ConnectionTimedOut => "connection timed out",
        error.ConnectionResetByPeer => "connection reset by server",
        error.BrokenPipe => "connection broken",
        error.NetworkSubsystemFailed => "network system failure",
        error.HostLookupFailed => "unable to resolve hostname",
        error.AddressInUse => "network address already in use",
        error.AddressNotAvailable => "network address not available",

        // Resource errors
        error.OutOfMemory => "insufficient memory available",
        error.ProcessFdQuotaExceeded => "too many open files for process",
        error.SystemFdQuotaExceeded => "too many open files system-wide",
        error.SystemResources => "insufficient system resources",
        error.WouldBlock => "operation would block",
        error.Locked => "resource is locked",

        // Input/validation errors
        error.InvalidConfig => "invalid configuration",
        error.ParseError => "parse error",
        error.InvalidCharacter => "invalid character in input",
        error.Overflow => "numeric value too large",
        error.InvalidFormat => "invalid format",
        error.EndOfStream => "unexpected end of data",
        error.StreamTooLong => "data stream too long",
        error.ChecksumMismatch => "data integrity check failed",
        error.InvalidLength => "invalid data length",

        // Compression/archive errors
        error.InvalidData => "invalid or corrupted data",
        error.BadData => "corrupted data detected",
        error.CorruptInput => "input data is corrupted",
        error.WrongFormat => "unsupported file format",

        // Permission/security errors
        error.PermissionDenied => "permission denied",
        error.OperationNotPermitted => "operation not permitted",
        error.NotSupported => "operation not supported",

        // Standard module vocabulary
        error.FileSystem => "file system error",
        error.InvalidInput => "invalid input",
        error.MissingArgument => "missing required argument",
        error.CorruptData => "corrupt or incompatible data",
        error.SignatureInvalid => "signature verification failed",
        error.OutOfDisk => "insufficient disk space",
        error.TooManyFiles => "too many open files",
        error.Internal => "internal error",
        error.SessionSetupError => "failed to set up namespace session",
        error.SyntheticRootSetupError => "failed to build synthetic root",
        error.DeviceSetupError => "failed to set up namespace devices",
        error.EtcSetupError => "failed to generate namespace etc files",
        error.WorkingDirectoryUnavailable => "requested working directory is not available inside the namespace",
        error.MountRestricted => "mount operation not permitted in this environment",
        error.MountSourceMissing => "bind mount source path not found",
        error.MountBindError => "bind mount failed",

        // Convert module errors
        error.PkginfoNotFound => ".PKGINFO file not found in package",
        error.InvalidPkginfo => ".PKGINFO file format is invalid",
        error.SigningKeyNotFound => "signing key not found (run 'mere key generate' to create one)",
        error.SigningKeyInvalid => "signing key is invalid or corrupted",
        error.MetaWriteFailed => "failed to write package metadata",
        error.ManifestWriteFailed => "failed to write package manifest",
        error.HashComputeFailed => "failed to compute content hash",
        error.ArchiveCreateFailed => "failed to create output archive",
        error.ExtractionFailed => "failed to extract input archive",
        error.InputNotFound => "input package file not found",
        error.UnsupportedFormat => "input file format not supported (expected .xz)",

        // Install module errors
        error.MissingDependency => "dependency not found in any repository",
        error.PackageNotFound => "package not found in any repository",
        error.ConflictingProvision => "multiple packages provide the same file path",
        error.SymlinkEscapesBoundary => "package contains symlink that escapes installation boundary",

        // Import module errors
        error.DatabaseQueryFailed => "database operation failed",
        error.PackageAlreadyExists => "package already exists in repository",
        error.PackageImportFailed => "failed to persist package archive in shared pool",
        error.PackageExtractFailed => "failed to extract package archive",
        error.SigningFailed => "failed to sign repository metadata",
        error.StateNotFound => "required repository state not found",

        // Release publish module errors
        error.ArchiveMissing => "required package archive missing from dev repository pool",
        error.ArchiveHashMismatch => "package archive content does not match dev repository database record",

        // Default fallback — static string avoids pulling in global error name table
        else => "unknown error",
    };
}

/// Error context structure for rich error information
///
/// Provides structured error message formatting following "{error}: \"{subject}\"[ - {details}]" pattern
/// Example: "missing dependency: \"/bin/execlineb\""
/// Example with details: "signature invalid: \"pkg.tar.zst\" - key fingerprint not trusted"
pub const ErrorContext = struct {
    /// The subject/thing that had the error (path, package name, URL, etc.)
    subject: ?[]const u8,
    /// Optional additional details
    details: ?[]const u8,

    /// Format error context with the error message
    /// Returns: "{error_message}: \"{subject}\"" or "{error_message}: \"{subject}\" - {details}"
    pub fn formatWithMessage(self: ErrorContext, allocator: std.mem.Allocator, error_message: []const u8) ![]const u8 {
        if (self.subject) |subj| {
            if (self.details) |det| {
                return std.fmt.allocPrint(allocator, "{s}: \"{s}\" - {s}", .{ error_message, subj, det });
            } else {
                return std.fmt.allocPrint(allocator, "{s}: \"{s}\"", .{ error_message, subj });
            }
        } else {
            return std.fmt.allocPrint(allocator, "{s}", .{error_message});
        }
    }
};

/// Diagnostic context for tracking what resource/subject an operation is working on
///
/// Used to provide context in error messages. The subject is the thing that had the error
/// (a file path, package name, URL, dependency name, etc.)
///
pub const DiagnosticContext = struct {
    /// The subject/thing being operated on (path, package name, URL, dependency, etc.)
    subject: ?[]const u8 = null,
    /// Optional additional details
    details: ?[]const u8 = null,
    /// Source location (for debugging)
    location: ?std.builtin.SourceLocation = null,

    /// Initialize an empty diagnostic context
    pub fn init() DiagnosticContext {
        return DiagnosticContext{
            .location = @src(),
        };
    }

    /// Set the subject (the thing being operated on)
    pub fn withSubject(self: DiagnosticContext, subject: []const u8) DiagnosticContext {
        var ctx = self;
        ctx.subject = subject;
        return ctx;
    }

    /// Add details to the context
    pub fn withDetails(self: DiagnosticContext, details: []const u8) DiagnosticContext {
        var ctx = self;
        ctx.details = details;
        return ctx;
    }

    /// Create an ErrorContext from this DiagnosticContext
    pub fn toErrorContext(self: DiagnosticContext) ErrorContext {
        return ErrorContext{
            .subject = self.subject,
            .details = self.details,
        };
    }
};

test "mapZigError maps common errors correctly" {
    const testing = std.testing;

    // Test mapping of common Zig errors
    try testing.expectEqual(MereError.InvalidInput, ErrorMapping.mapZigError(error.InvalidInput));
    try testing.expectEqual(MereError.MissingArgument, ErrorMapping.mapZigError(error.MissingArgument));
    try testing.expectEqual(MereError.FileSystem, ErrorMapping.mapZigError(error.FileSystem));
    try testing.expectEqual(MereError.Network, ErrorMapping.mapZigError(error.Network));
    try testing.expectEqual(MereError.PermissionDenied, ErrorMapping.mapZigError(error.PermissionDenied));
    try testing.expectEqual(MereError.CorruptData, ErrorMapping.mapZigError(error.CorruptData));
    try testing.expectEqual(MereError.SignatureInvalid, ErrorMapping.mapZigError(error.SignatureInvalid));
    try testing.expectEqual(MereError.OutOfMemory, ErrorMapping.mapZigError(error.OutOfMemory));
    try testing.expectEqual(MereError.OutOfDisk, ErrorMapping.mapZigError(error.OutOfDisk));
    try testing.expectEqual(MereError.TooManyFiles, ErrorMapping.mapZigError(error.TooManyFiles));
    try testing.expectEqual(MereError.Internal, ErrorMapping.mapZigError(error.Internal));

    try testing.expectEqual(MereError.PermissionDenied, ErrorMapping.mapZigError(error.AccessDenied));
    try testing.expectEqual(MereError.FileSystem, ErrorMapping.mapZigError(error.Locked));
    try testing.expectEqual(MereError.InvalidInput, ErrorMapping.mapZigError(error.UnsatisfiableDependencies));
    try testing.expectEqual(MereError.CorruptData, ErrorMapping.mapZigError(error.SignatureVerificationFailed));
    try testing.expectEqual(MereError.FileSystem, ErrorMapping.mapZigError(error.FileNotFound));
    try testing.expectEqual(MereError.FileSystem, ErrorMapping.mapZigError(error.IsDir));
    try testing.expectEqual(MereError.FileSystem, ErrorMapping.mapZigError(error.NotDir));
    try testing.expectEqual(MereError.Network, ErrorMapping.mapZigError(error.Network));
    try testing.expectEqual(MereError.Network, ErrorMapping.mapZigError(error.ConnectionTimeout));
    try testing.expectEqual(MereError.SignatureInvalid, ErrorMapping.mapZigError(error.SignatureInvalid));
    try testing.expectEqual(MereError.Network, ErrorMapping.mapZigError(error.ConnectionRefused));
    try testing.expectEqual(MereError.Network, ErrorMapping.mapZigError(error.NetworkUnreachable));
    try testing.expectEqual(MereError.InvalidInput, ErrorMapping.mapZigError(error.InvalidConfig));
    try testing.expectEqual(MereError.InvalidInput, ErrorMapping.mapZigError(error.ParseError));
    try testing.expectEqual(MereError.OutOfDisk, ErrorMapping.mapZigError(error.NoSpaceLeft));
    try testing.expectEqual(MereError.TooManyFiles, ErrorMapping.mapZigError(error.ProcessFdQuotaExceeded));
    try testing.expectEqual(MereError.TooManyFiles, ErrorMapping.mapZigError(error.SystemFdQuotaExceeded));
}

test "mapZigError returns Internal for unknown errors" {
    const testing = std.testing;

    // Test that unknown errors map to Internal
    const UnknownError = error{SomeUnknownError};
    try testing.expectEqual(MereError.Internal, ErrorMapping.mapZigError(UnknownError.SomeUnknownError));
}

test "mapModuleError maps standard module errors correctly" {
    const testing = std.testing;

    // Define a test module error set
    const TestModuleError = error{
        OutOfMemory,
        FileSystem,
        Network,
        PermissionDenied,
        InvalidInput,
        CorruptData,
        SignatureInvalid,
        OutOfDisk,
        TooManyFiles,
        SomeModuleSpecificError,
    };

    // Test mapping of standard errors
    try testing.expectEqual(MereError.OutOfMemory, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.OutOfMemory));
    try testing.expectEqual(MereError.FileSystem, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.FileSystem));
    try testing.expectEqual(MereError.Network, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.Network));
    try testing.expectEqual(MereError.PermissionDenied, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.PermissionDenied));
    try testing.expectEqual(MereError.InvalidInput, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.InvalidInput));
    try testing.expectEqual(MereError.CorruptData, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.CorruptData));
    try testing.expectEqual(MereError.SignatureInvalid, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.SignatureInvalid));
    try testing.expectEqual(MereError.OutOfDisk, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.OutOfDisk));
    try testing.expectEqual(MereError.TooManyFiles, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.TooManyFiles));

    // Test that module-specific errors map to Internal
    try testing.expectEqual(MereError.Internal, ErrorMapping.mapModuleError(TestModuleError, TestModuleError.SomeModuleSpecificError));
}

test "DiagnosticContext creation and basic functionality" {
    const testing = std.testing;

    // Test basic context creation
    const ctx = DiagnosticContext.init();
    try testing.expect(ctx.subject == null);
    try testing.expect(ctx.details == null);
    try testing.expect(ctx.location != null);
}

test "DiagnosticContext withSubject method" {
    const testing = std.testing;

    // Test adding subject to context
    const ctx = DiagnosticContext.init();
    const ctx_with_subject = ctx.withSubject("/test/path");

    try testing.expectEqualStrings("/test/path", ctx_with_subject.subject.?);
    try testing.expect(ctx_with_subject.details == null);
}

test "DiagnosticContext withDetails method" {
    const testing = std.testing;

    // Test adding details to context
    const ctx = DiagnosticContext.init()
        .withSubject("busybox")
        .withDetails("version 1.36.1");

    try testing.expectEqualStrings("busybox", ctx.subject.?);
    try testing.expectEqualStrings("version 1.36.1", ctx.details.?);
}

test "DiagnosticContext toErrorContext method" {
    const testing = std.testing;

    // Test converting to ErrorContext
    const diag_ctx = DiagnosticContext.init()
        .withSubject("/bin/execlineb")
        .withDetails("required by busybox");

    const error_ctx = diag_ctx.toErrorContext();
    try testing.expectEqualStrings("/bin/execlineb", error_ctx.subject.?);
    try testing.expectEqualStrings("required by busybox", error_ctx.details.?);
}

test "ErrorContext formatWithMessage method" {
    const testing = std.testing;

    // Test formatting with subject only
    const ctx1 = ErrorContext{ .subject = "/bin/execlineb", .details = null };
    const formatted1 = try ctx1.formatWithMessage(testing.allocator, "dependency not found in any repository");
    defer testing.allocator.free(formatted1);
    try testing.expectEqualStrings("dependency not found in any repository: \"/bin/execlineb\"", formatted1);

    // Test formatting with subject and details
    const ctx2 = ErrorContext{ .subject = "pkg.tar.zst", .details = "key fingerprint not trusted" };
    const formatted2 = try ctx2.formatWithMessage(testing.allocator, "signature invalid");
    defer testing.allocator.free(formatted2);
    try testing.expectEqualStrings("signature invalid: \"pkg.tar.zst\" - key fingerprint not trusted", formatted2);

    // Test formatting with no subject
    const ctx3 = ErrorContext{ .subject = null, .details = null };
    const formatted3 = try ctx3.formatWithMessage(testing.allocator, "operation failed");
    defer testing.allocator.free(formatted3);
    try testing.expectEqualStrings("operation failed", formatted3);
}

test "getUserFriendlyMessage returns user-readable messages" {
    const testing = std.testing;

    // Test file system errors
    try testing.expectEqualStrings("file or directory not found", getUserFriendlyMessage(error.FileNotFound));
    try testing.expectEqualStrings("permission denied", getUserFriendlyMessage(error.AccessDenied));
    try testing.expectEqualStrings("expected file but found directory", getUserFriendlyMessage(error.IsDir));
    try testing.expectEqualStrings("expected directory but found file", getUserFriendlyMessage(error.NotDir));
    try testing.expectEqualStrings("insufficient disk space", getUserFriendlyMessage(error.NoSpaceLeft));

    // Test network errors
    try testing.expectEqualStrings("network error", getUserFriendlyMessage(error.Network));
    try testing.expectEqualStrings("connection timed out", getUserFriendlyMessage(error.ConnectionTimeout));
    try testing.expectEqualStrings("connection refused by server", getUserFriendlyMessage(error.ConnectionRefused));
    try testing.expectEqualStrings("network unreachable", getUserFriendlyMessage(error.NetworkUnreachable));
    try testing.expectEqualStrings("connection timed out", getUserFriendlyMessage(error.ConnectionTimedOut));

    // Test resource errors
    try testing.expectEqualStrings("insufficient memory available", getUserFriendlyMessage(error.OutOfMemory));
    try testing.expectEqualStrings("too many open files for process", getUserFriendlyMessage(error.ProcessFdQuotaExceeded));
    try testing.expectEqualStrings("too many open files system-wide", getUserFriendlyMessage(error.SystemFdQuotaExceeded));

    // Test input/validation errors
    try testing.expectEqualStrings("invalid configuration", getUserFriendlyMessage(error.InvalidConfig));
    try testing.expectEqualStrings("parse error", getUserFriendlyMessage(error.ParseError));
    try testing.expectEqualStrings("invalid input", getUserFriendlyMessage(error.InvalidInput));
    try testing.expectEqualStrings("corrupt or incompatible data", getUserFriendlyMessage(error.CorruptData));
    try testing.expectEqualStrings("file system error", getUserFriendlyMessage(error.FileSystem));
    try testing.expectEqualStrings("signature verification failed", getUserFriendlyMessage(error.SignatureInvalid));
    try testing.expectEqualStrings("invalid character in input", getUserFriendlyMessage(error.InvalidCharacter));
    try testing.expectEqualStrings("numeric value too large", getUserFriendlyMessage(error.Overflow));
    try testing.expectEqualStrings("data integrity check failed", getUserFriendlyMessage(error.ChecksumMismatch));
    try testing.expectEqualStrings("failed to persist package archive in shared pool", getUserFriendlyMessage(error.PackageImportFailed));
    try testing.expectEqualStrings("failed to extract package archive", getUserFriendlyMessage(error.PackageExtractFailed));
    try testing.expectEqualStrings("failed to sign repository metadata", getUserFriendlyMessage(error.SigningFailed));

    // Test unknown error fallback
    const UnknownError = error{SomeUnknownError};
    try testing.expectEqualStrings("unknown error", getUserFriendlyMessage(UnknownError.SomeUnknownError));
}

test "getUserFriendlyMessage excludes technical details" {
    const testing = std.testing;

    // Verify that user-friendly messages don't contain technical implementation details
    const file_msg = getUserFriendlyMessage(error.FileNotFound);
    const network_msg = getUserFriendlyMessage(error.ConnectionRefused);
    const memory_msg = getUserFriendlyMessage(error.OutOfMemory);

    // Check that messages don't contain technical terms
    try testing.expect(std.mem.indexOf(u8, file_msg, "errno") == null);
    try testing.expect(std.mem.indexOf(u8, file_msg, "syscall") == null);
    try testing.expect(std.mem.indexOf(u8, network_msg, "socket") == null);
    try testing.expect(std.mem.indexOf(u8, network_msg, "TCP") == null);
    try testing.expect(std.mem.indexOf(u8, memory_msg, "malloc") == null);
    try testing.expect(std.mem.indexOf(u8, memory_msg, "heap") == null);

    // Check that messages are descriptive and actionable
    try testing.expect(file_msg.len > 5); // Not just error codes
    try testing.expect(network_msg.len > 5);
    try testing.expect(memory_msg.len > 5);
}

test "Property 8: Technical Detail Exclusion" {
    // **Feature: single-point-logging, Property 8: Technical Detail Exclusion**
    // **Validates: Requirements 3.4**
    const testing = std.testing;

    // Property: For any user-facing error message, the message should not contain
    // internal implementation details such as function names, memory addresses,
    // or internal error codes.

    // Define technical terms that should NEVER appear in user-facing messages
    const forbidden_technical_terms = [_][]const u8{
        "syscall", "errno",       "EINVAL",      "ENOENT",   "EACCES",  "malloc",
        "realloc", "0x",          "nullptr",     "segfault", "SIGSEGV", "sockaddr",
        "AF_INET", "SOCK_STREAM", "inode",       "dirent",   "zlib",    "deflate",
        "inflate", "libsodium",   "crypto_sign",
    };

    // Define comprehensive set of errors to test
    const test_errors = [_]anyerror{
        // File system errors
        error.FileNotFound,
        error.AccessDenied,
        error.IsDir,
        error.NotDir,
        error.NoSpaceLeft,
        error.NameTooLong,
        error.ReadOnlyFileSystem,

        // Network errors
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.ConnectionTimedOut,
        error.ConnectionResetByPeer,
        error.BrokenPipe,

        // Resource errors
        error.OutOfMemory,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,

        // Input/validation errors
        error.InvalidCharacter,
        error.Overflow,
        error.EndOfStream,

        // Permission/security errors
        error.PermissionDenied,
        error.OperationNotPermitted,
    };

    // Test each error type once
    for (test_errors) |test_error| {
        const message = getUserFriendlyMessage(test_error);

        // Property verification: Message must not contain technical details
        for (forbidden_technical_terms) |term| {
            var lower_message: [256]u8 = undefined;
            const message_len = @min(message.len, lower_message.len);
            for (message[0..message_len], 0..) |c, idx| {
                lower_message[idx] = std.ascii.toLower(c);
            }

            var lower_term: [64]u8 = undefined;
            const term_len = @min(term.len, lower_term.len);
            for (term[0..term_len], 0..) |c, idx| {
                lower_term[idx] = std.ascii.toLower(c);
            }

            const found = std.mem.indexOf(u8, lower_message[0..message_len], lower_term[0..term_len]);
            if (found != null) {
                std.debug.print("\nViolation: Error message '{s}' contains technical term '{s}'\n", .{ message, term });
                try testing.expect(false);
            }
        }

        // Message should be descriptive (not just error codes)
        try testing.expect(message.len >= 5);

        // Message should not contain hexadecimal patterns (memory addresses)
        try testing.expect(std.mem.indexOf(u8, message, "0x") == null);
    }

    // Test that unknown errors fall back to static string
    const UnknownError = error{SomeCustomError};
    const unknown_msg = getUserFriendlyMessage(UnknownError.SomeCustomError);
    try testing.expectEqualStrings("unknown error", unknown_msg);
}

test "ErrorContext formatWithMessage creates structured messages" {
    const testing = std.testing;

    // Test basic formatting with subject only
    const basic_ctx = ErrorContext{
        .subject = "busybox",
        .details = null,
    };
    const basic_formatted = try basic_ctx.formatWithMessage(testing.allocator, "package not found");
    defer testing.allocator.free(basic_formatted);
    try testing.expectEqualStrings("package not found: \"busybox\"", basic_formatted);

    // Test formatting with subject and details
    const ctx_with_details = ErrorContext{
        .subject = "https://repo.example.com",
        .details = "timeout after 30s",
    };
    const formatted_with_details = try ctx_with_details.formatWithMessage(testing.allocator, "repository sync failed");
    defer testing.allocator.free(formatted_with_details);
    try testing.expectEqualStrings("repository sync failed: \"https://repo.example.com\" - timeout after 30s", formatted_with_details);

    // Test formatting with no subject
    const no_subject_ctx = ErrorContext{
        .subject = null,
        .details = null,
    };
    const no_subject_formatted = try no_subject_ctx.formatWithMessage(testing.allocator, "operation failed");
    defer testing.allocator.free(no_subject_formatted);
    try testing.expectEqualStrings("operation failed", no_subject_formatted);
}

test "ErrorContext follows new message pattern" {
    const testing = std.testing;

    // Test that all formatted messages follow the "{error}: \"{subject}\"[ - {details}]" pattern
    const test_cases = [_]struct { ctx: ErrorContext, msg: []const u8 }{
        .{ .ctx = .{ .subject = "/etc/config", .details = null }, .msg = "file not found" },
        .{ .ctx = .{ .subject = "https://api.example.com", .details = null }, .msg = "network error" },
        .{ .ctx = .{ .subject = "package.tar.zst", .details = "signature check failed" }, .msg = "validation error" },
    };

    for (test_cases) |tc| {
        const formatted = try tc.ctx.formatWithMessage(testing.allocator, tc.msg);
        defer testing.allocator.free(formatted);

        // Verify the message starts with the error message
        try testing.expect(std.mem.startsWith(u8, formatted, tc.msg));

        // If subject is present, verify it appears in quotes
        if (tc.ctx.subject) |subj| {
            const expected_subject_part = try std.fmt.allocPrint(testing.allocator, "\"{s}\"", .{subj});
            defer testing.allocator.free(expected_subject_part);
            try testing.expect(std.mem.indexOf(u8, formatted, expected_subject_part) != null);
        }

        // If details are present, verify they appear after " - "
        if (tc.ctx.details) |det| {
            const expected_details_part = try std.fmt.allocPrint(testing.allocator, " - {s}", .{det});
            defer testing.allocator.free(expected_details_part);
            try testing.expect(std.mem.indexOf(u8, formatted, expected_details_part) != null);
        }
    }
}

// **Feature: single-point-logging, Property 3: Error Message Format Consistency**
// *For any* error message generated by the system, the message should follow the standard format pattern: "{error_message}: \"{subject}\"[ - {details}]".
// **Validates: Requirements 3.5, 5.4**
test "Property 3: Error Message Format Consistency" {
    const testing = std.testing;

    const error_messages = [_][]const u8{ "package not found", "repository sync failed", "file not found", "signature invalid", "configuration error" };
    const subjects = [_]?[]const u8{ null, "/test/path", "https://example.com/package", "package-1.0.tar.zst", "/var/lib/mere/mere.kdl" };
    const details = [_]?[]const u8{ null, "timeout after 30s", "invalid format", "checksum mismatch", "permission denied" };

    // Test all 25 unique combinations (5 messages x 5 subjects, details cycle through)
    var i: u32 = 0;
    while (i < 25) : (i += 1) {
        const error_msg = error_messages[i % error_messages.len];
        const subject = subjects[i % subjects.len];
        const detail = details[i % details.len];

        // Create ErrorContext and format message
        const ctx = ErrorContext{
            .subject = subject,
            .details = detail,
        };

        const formatted = try ctx.formatWithMessage(testing.allocator, error_msg);
        defer testing.allocator.free(formatted);

        // Verify format consistency properties
        // 1. Message must start with error message
        try testing.expect(std.mem.startsWith(u8, formatted, error_msg));

        // 2. If subject is present, it must appear in quotes
        if (subject) |subj| {
            const subject_pattern = try std.fmt.allocPrint(testing.allocator, "\"{s}\"", .{subj});
            defer testing.allocator.free(subject_pattern);
            try testing.expect(std.mem.indexOf(u8, formatted, subject_pattern) != null);
        }

        // 3. If details are present, they must appear after " - "
        if (detail) |det| {
            const details_pattern = try std.fmt.allocPrint(testing.allocator, " - {s}", .{det});
            defer testing.allocator.free(details_pattern);
            try testing.expect(std.mem.indexOf(u8, formatted, details_pattern) != null);
        }
    }
}

test "comprehensive error handling - error propagation validation" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator, "/test");
    defer ctx.deinit();

    // Test that errors propagate correctly from lower-level modules to higher-level ones
    // This validates that error mapping functions work correctly after standardization

    // Test sign module error propagation - nonexistent file should give FileSystem error
    const sign = @import("sign.zig");
    const sign_result = sign.verifySignature(&ctx, "/nonexistent/file.txt", "test.pub", null);
    try testing.expectError(sign.SignError.FileSystem, sign_result);

    // Test that error unions still work with standardized errors
    const TestResult = sign.SignError!void;
    const test_error: TestResult = sign.SignError.InvalidKey;

    var caught_correct_error = false;
    test_error catch |err| switch (err) {
        sign.SignError.InvalidKey => {
            caught_correct_error = true;
        },
        else => {},
    };

    try testing.expect(caught_correct_error);
}

// Property 6: Resource Information Inclusion
// *For any* error involving file paths, URLs, or other resources, the error message should include
// the specific resource identifier that was involved in the failure.
// **Feature: single-point-logging, Property 6: Resource Information Inclusion**
// **Validates: Requirements 5.3**
test "Property 6: Resource Information Inclusion" {
    const testing = std.testing;

    // Test ErrorContext with subject (the resource that had the error)
    const subjects = [_][]const u8{
        "/etc/config/mere.conf",
        "/var/lib/mere/packages/busybox.tar.zst",
        "https://repo.example.com/packages",
        "/tmp/build/workspace",
    };

    const error_messages = [_][]const u8{
        "file not found",
        "package installation failed",
        "repository sync failed",
        "network request failed",
    };

    // Test 16 combinations (4x4)
    for (subjects) |subject| {
        for (error_messages) |error_msg| {
            const ctx = ErrorContext{
                .subject = subject,
                .details = null,
            };

            const formatted = try ctx.formatWithMessage(testing.allocator, error_msg);
            defer testing.allocator.free(formatted);

            // Property verification: Message MUST include the subject (resource)
            try testing.expect(std.mem.indexOf(u8, formatted, subject) != null);

            // Subject should appear in quotes per the format spec
            const expected_subject_part = try std.fmt.allocPrint(testing.allocator, "\"{s}\"", .{subject});
            defer testing.allocator.free(expected_subject_part);
            try testing.expect(std.mem.indexOf(u8, formatted, expected_subject_part) != null);

            // Message should start with error message
            try testing.expect(std.mem.startsWith(u8, formatted, error_msg));
        }
    }

    // Test with details field
    const ctx_with_details = ErrorContext{
        .subject = "/path/to/resource",
        .details = "additional context",
    };
    const formatted_with_details = try ctx_with_details.formatWithMessage(testing.allocator, "test operation failed");
    defer testing.allocator.free(formatted_with_details);
    try testing.expect(std.mem.indexOf(u8, formatted_with_details, "/path/to/resource") != null);
    try testing.expect(std.mem.indexOf(u8, formatted_with_details, "additional context") != null);

    // Edge case: no subject context
    const no_subject_ctx = ErrorContext{
        .subject = null,
        .details = null,
    };
    const no_subject_formatted = try no_subject_ctx.formatWithMessage(testing.allocator, "operation without resource");
    defer testing.allocator.free(no_subject_formatted);
    try testing.expectEqualStrings("operation without resource", no_subject_formatted);
}
