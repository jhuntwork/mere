const std = @import("std");

/// Process-local serialization for activation, boot projection, and GC.
/// CLI store locks provide cross-process serialization; this mutex protects
/// direct library API callers in the same process as well.
pub var mutex: std.Io.Mutex = .init;
