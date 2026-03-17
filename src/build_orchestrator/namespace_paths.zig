const std = @import("std");

fn isWithinWorkspace(host_path: []const u8, workspace_root: []const u8) bool {
    if (std.mem.eql(u8, host_path, workspace_root)) return true;
    if (!std.mem.startsWith(u8, host_path, workspace_root)) return false;
    if (host_path.len <= workspace_root.len) return false;
    return host_path[workspace_root.len] == '/';
}

fn isNamespaceWorkspacePathVar(key: []const u8) bool {
    return std.mem.eql(u8, key, "MERE_BUILD_DIR") or
        std.mem.eql(u8, key, "MERE_SOURCES_DIR") or
        std.mem.eql(u8, key, "MERE_DESTDIR") or
        std.mem.eql(u8, key, "DESTDIR") or
        std.mem.eql(u8, key, "HOME") or
        std.mem.eql(u8, key, "XDG_CACHE_HOME") or
        std.mem.eql(u8, key, "XDG_CONFIG_HOME") or
        std.mem.eql(u8, key, "XDG_STATE_HOME") or
        std.mem.eql(u8, key, "XDG_DATA_HOME");
}

pub fn translateWorkspacePathToNamespace(
    allocator: std.mem.Allocator,
    host_path: []const u8,
    workspace_root: []const u8,
) ![]const u8 {
    if (isWithinWorkspace(host_path, workspace_root)) {
        const suffix = host_path[workspace_root.len..];
        if (suffix.len == 0) {
            return allocator.dupe(u8, "/work");
        }
        if (suffix[0] == '/') {
            return std.fs.path.join(allocator, &.{ "/work", suffix[1..] });
        }
        return std.fs.path.join(allocator, &.{ "/work", suffix });
    }
    return allocator.dupe(u8, host_path);
}

pub fn createNamespaceEnvMap(
    allocator: std.mem.Allocator,
    host_env: ?*std.process.EnvMap,
    workspace_root: []const u8,
) !std.process.EnvMap {
    var ns_env = std.process.EnvMap.init(allocator);
    errdefer ns_env.deinit();

    if (host_env) |env| {
        var it = env.iterator();
        while (it.next()) |entry| {
            if (isNamespaceWorkspacePathVar(entry.key_ptr.*)) {
                const translated_value = try translateWorkspacePathToNamespace(allocator, entry.value_ptr.*, workspace_root);
                defer allocator.free(translated_value);
                try ns_env.put(entry.key_ptr.*, translated_value);
                continue;
            }

            try ns_env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return ns_env;
}

test "translateWorkspacePathToNamespace rewrites only boundary-contained paths" {
    const allocator = std.testing.allocator;
    const root = "/tmp/workspace";

    const in_root = try translateWorkspacePathToNamespace(allocator, "/tmp/workspace/src/main.zig", root);
    defer allocator.free(in_root);
    try std.testing.expectEqualStrings("/work/src/main.zig", in_root);

    const same_root = try translateWorkspacePathToNamespace(allocator, "/tmp/workspace", root);
    defer allocator.free(same_root);
    try std.testing.expectEqualStrings("/work", same_root);

    const sibling = try translateWorkspacePathToNamespace(allocator, "/tmp/workspace-sibling/src/main.zig", root);
    defer allocator.free(sibling);
    try std.testing.expectEqualStrings("/tmp/workspace-sibling/src/main.zig", sibling);
}

test "createNamespaceEnvMap rewrites only namespace workspace path vars" {
    const allocator = std.testing.allocator;
    var host = std.process.EnvMap.init(allocator);
    defer host.deinit();

    try host.put("MERE_BUILD_DIR", "/tmp/workspace/build-src");
    try host.put("DESTDIR", "/tmp/workspace/dest");
    try host.put("HOME", "/tmp/workspace/build-src");
    try host.put("XDG_CACHE_HOME", "/tmp/workspace/build-src/.cache");
    try host.put("SIBLING", "/tmp/workspace-sibling/project");
    try host.put("OTHER", "/tmp/workspace/project");
    try host.put("PREFIX", "/usr");

    var mapped = try createNamespaceEnvMap(allocator, &host, "/tmp/workspace");
    defer mapped.deinit();

    try std.testing.expectEqualStrings("/work/build-src", mapped.get("MERE_BUILD_DIR").?);
    try std.testing.expectEqualStrings("/work/dest", mapped.get("DESTDIR").?);
    try std.testing.expectEqualStrings("/work/build-src", mapped.get("HOME").?);
    try std.testing.expectEqualStrings("/work/build-src/.cache", mapped.get("XDG_CACHE_HOME").?);
    try std.testing.expectEqualStrings("/tmp/workspace-sibling/project", mapped.get("SIBLING").?);
    try std.testing.expectEqualStrings("/tmp/workspace/project", mapped.get("OTHER").?);
    try std.testing.expectEqualStrings("/usr", mapped.get("PREFIX").?);
}
