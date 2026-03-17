const std = @import("std");
const mere = @import("mere.zig");
const repo_sources = @import("repo_sources.zig");
const repocache = @import("repocache.zig");
const package = @import("package.zig");
const errors = @import("errors.zig");

const Std = errors.StandardErrors;
pub const SearchError = Std.OutOfMemory || Std.FileSystem || Std.CorruptData || error{
    PackageNotFound,
};

pub const SearchResult = struct {
    repo_name: []const u8,
    is_local: bool,
    name: []const u8,
    version: []const u8,
    release: u32,
    arch: []const u8,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_name);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.arch);
    }
};

pub fn searchPackages(ctx: *mere.Context, term: []const u8) SearchError!std.ArrayList(SearchResult) {
    var results = std.ArrayList(SearchResult){};
    errdefer {
        for (results.items) |*r| r.deinit(ctx.allocator);
        results.deinit(ctx.allocator);
    }

    const cfg = ctx.getConfig() catch {
        return ctx.fail(SearchError.FileSystem, term, "failed to load configuration");
    };

    var repocaches = repo_sources.createCaches(ctx, cfg) catch {
        return ctx.fail(SearchError.FileSystem, term, "failed to initialize repositories");
    };
    defer {
        for (repocaches.items) |rc| {
            rc.deinit();
            ctx.allocator.destroy(rc);
        }
        repocaches.deinit(ctx.allocator);
    }

    for (repocaches.items) |rc| {
        rc.ensureRepository() catch {
            ctx.debug("skipping repo {s}: failed to open", .{rc.name});
            continue;
        };

        const repo = &(rc.repository.?);
        var matches = repo.db.searchByName(ctx.allocator, term) catch {
            ctx.debug("skipping repo {s}: search query failed", .{rc.name});
            continue;
        };
        defer {
            for (matches.items) |*pkg| pkg.deinit();
            matches.deinit(ctx.allocator);
        }

        for (matches.items) |*pkg| {
            const result = SearchResult{
                .repo_name = ctx.allocator.dupe(u8, rc.name) catch return SearchError.OutOfMemory,
                .is_local = rc.is_local,
                .name = ctx.allocator.dupe(u8, pkg.name orelse continue) catch return SearchError.OutOfMemory,
                .version = ctx.allocator.dupe(u8, pkg.version orelse "?") catch return SearchError.OutOfMemory,
                .release = pkg.release orelse 0,
                .arch = ctx.allocator.dupe(u8, pkg.arch orelse "?") catch return SearchError.OutOfMemory,
            };
            results.append(ctx.allocator, result) catch return SearchError.OutOfMemory;
        }
    }

    return results;
}
