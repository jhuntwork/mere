const std = @import("std");

pub const ArtifactKind = enum {
    source_fetch,
    source_unpack,
    profile_tree,
    prepare_tree,
    build_tree,
    check_tree,
    destdir_tree,
    split_tree,
    package_archive,
};

pub const NodeKind = enum {
    source_fetch,
    source_unpack,
    profile_realize,
    prepare_phase,
    build_phase,
    check_phase,
    install_phase,
    split_stage,
    package_archive,
};

pub const NodeExecutionKind = enum {
    executed,
    restored_from_cache,
};

pub const ArtifactRef = struct {
    allocator: std.mem.Allocator,
    kind: ArtifactKind,
    key_hex: []const u8,
    digest_hex: []const u8,
    actual_subpath: ?[]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        kind: ArtifactKind,
        key_hex: []const u8,
        digest_hex: []const u8,
        actual_subpath: ?[]const u8,
    ) !ArtifactRef {
        return .{
            .allocator = allocator,
            .kind = kind,
            .key_hex = try allocator.dupe(u8, key_hex),
            .digest_hex = try allocator.dupe(u8, digest_hex),
            .actual_subpath = if (actual_subpath) |subpath| try allocator.dupe(u8, subpath) else null,
        };
    }

    pub fn deinit(self: *ArtifactRef) void {
        self.allocator.free(self.key_hex);
        self.allocator.free(self.digest_hex);
        if (self.actual_subpath) |subpath| self.allocator.free(subpath);
        self.* = undefined;
    }
};

pub const BuildNode = struct {
    allocator: std.mem.Allocator,
    kind: NodeKind,
    execution: NodeExecutionKind,
    key_hex: []const u8,
    output: ArtifactRef,

    pub fn init(
        allocator: std.mem.Allocator,
        kind: NodeKind,
        execution: NodeExecutionKind,
        key_hex: []const u8,
        output_kind: ArtifactKind,
        digest_hex: []const u8,
        actual_subpath: ?[]const u8,
    ) !BuildNode {
        return .{
            .allocator = allocator,
            .kind = kind,
            .execution = execution,
            .key_hex = try allocator.dupe(u8, key_hex),
            .output = try ArtifactRef.init(allocator, output_kind, key_hex, digest_hex, actual_subpath),
        };
    }

    pub fn deinit(self: *BuildNode) void {
        self.allocator.free(self.key_hex);
        self.output.deinit();
        self.* = undefined;
    }
};

pub fn phaseOutputKind(phase_name: []const u8) ?ArtifactKind {
    if (std.mem.eql(u8, phase_name, "prepare")) return .prepare_tree;
    if (std.mem.eql(u8, phase_name, "build")) return .build_tree;
    if (std.mem.eql(u8, phase_name, "check")) return .check_tree;
    if (std.mem.eql(u8, phase_name, "install")) return .destdir_tree;
    return null;
}

pub fn phaseNodeKind(phase_name: []const u8) ?NodeKind {
    if (std.mem.eql(u8, phase_name, "prepare")) return .prepare_phase;
    if (std.mem.eql(u8, phase_name, "build")) return .build_phase;
    if (std.mem.eql(u8, phase_name, "check")) return .check_phase;
    if (std.mem.eql(u8, phase_name, "install")) return .install_phase;
    return null;
}

test "phase helpers map recipe phases to artifact and node kinds" {
    try std.testing.expectEqual(ArtifactKind.prepare_tree, phaseOutputKind("prepare").?);
    try std.testing.expectEqual(ArtifactKind.build_tree, phaseOutputKind("build").?);
    try std.testing.expectEqual(ArtifactKind.check_tree, phaseOutputKind("check").?);
    try std.testing.expectEqual(ArtifactKind.destdir_tree, phaseOutputKind("install").?);
    try std.testing.expect(phaseOutputKind("package") == null);

    try std.testing.expectEqual(NodeKind.prepare_phase, phaseNodeKind("prepare").?);
    try std.testing.expectEqual(NodeKind.build_phase, phaseNodeKind("build").?);
    try std.testing.expectEqual(NodeKind.check_phase, phaseNodeKind("check").?);
    try std.testing.expectEqual(NodeKind.install_phase, phaseNodeKind("install").?);
    try std.testing.expect(phaseNodeKind("package") == null);
}
