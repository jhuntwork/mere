const events = @import("events.zig");

pub const Token = enum {
    err,
    success,
    warn,
    detail,
    phase,
    step_primary,
    step_secondary,
    meta_label,
    hash_muted,
};

pub fn code(token: Token) []const u8 {
    return switch (token) {
        .err => "31",
        .success => "32",
        .warn => "33",
        .detail => "90",
        .phase => "38;5;208",
        .step_primary => "34",
        .step_secondary => "90",
        .meta_label => "38;5;110",
        .hash_muted => "90",
    };
}

pub fn segmentCode(kind: events.SegmentKind) ?[]const u8 {
    return switch (kind) {
        .normal => null,
        .success => code(.success),
        .warn => code(.warn),
        .label => code(.meta_label),
        .detail => code(.detail),
    };
}
