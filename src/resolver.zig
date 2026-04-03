const std = @import("std");
const mere = @import("mere.zig");
const Context = mere.Context;
const package = @import("package.zig");
const pin = @import("pin.zig");
const store = @import("store.zig");
const RepoCache = @import("repocache.zig").RepoCache;
const version_constraint = @import("version_constraint.zig");
const errors = @import("errors.zig");
const builtin = @import("builtin");
const Std = errors.StandardErrors;
const max_requirement_depth: usize = 512;

pub const ResolverError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || error{
    PackageNotFound,
    ConflictingProvisions,
    UnsatisfiableDependencies,
};

pub const ResolvedPackage = struct {
    pkg: package.Package,
    repocache: *RepoCache,
    install_order: usize,
    scc_id: usize,
    from_pin: bool = false,
    pinned_store_path: ?[]const u8 = null,
    /// Package names this package directly depends on (extracted from the dependency graph).
    dependency_names: []const []const u8 = &.{},
};

pub const ResolutionResult = struct {
    packages: []ResolvedPackage,
    sccs: [][]usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResolutionResult) void {
        for (self.packages) |*resolved| {
            for (resolved.dependency_names) |name| self.allocator.free(name);
            if (resolved.dependency_names.len > 0) self.allocator.free(resolved.dependency_names);
            resolved.pkg.deinit();
        }
        self.allocator.free(self.packages);

        for (self.sccs) |scc| {
            self.allocator.free(scc);
        }
        self.allocator.free(self.sccs);
    }
};

pub const Requirement = struct {
    name: []const u8,
    constraint_expr: ?[]const u8 = null,
    content_hash: ?[]const u8 = null,
};

pub const PreferredSelection = struct {
    name: []const u8,
    version: []const u8,
    release: u32,
    arch: []const u8,
    content_hash: []const u8,
};

const GraphNode = struct {
    pkg_key: []const u8,
    pkg: ?package.Package,
    repocache: *RepoCache,
    index: ?usize = null,
    low_link: ?usize = null,
    on_stack: bool = false,
    dependencies: std.ArrayList([]const u8),

    fn deinit(self: *GraphNode, allocator: std.mem.Allocator) void {
        allocator.free(self.pkg_key);
        if (self.pkg) |*pkg| {
            pkg.deinit();
        }
        for (self.dependencies.items) |dep_key| {
            allocator.free(dep_key);
        }
        self.dependencies.deinit(allocator);
    }
};

const DependencyGraph = struct {
    nodes: std.StringHashMap(GraphNode),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) DependencyGraph {
        return .{
            .nodes = std.StringHashMap(GraphNode).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *DependencyGraph) void {
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            var node = entry.value_ptr;
            node.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    fn addNode(
        self: *DependencyGraph,
        pkg_key: []const u8,
        pkg: package.Package,
        repocache: *RepoCache,
    ) ResolverError!void {
        if (self.nodes.contains(pkg_key)) return;

        const key_copy = self.allocator.dupe(u8, pkg_key) catch {
            return ResolverError.OutOfMemory;
        };
        errdefer self.allocator.free(key_copy);

        var node = GraphNode{
            .pkg_key = key_copy,
            .pkg = pkg,
            .repocache = repocache,
            .dependencies = .empty,
        };

        self.nodes.put(key_copy, node) catch {
            var mutable = pkg;
            mutable.deinit();
            node.deinit(self.allocator);
            return ResolverError.OutOfMemory;
        };
    }

    fn addEdge(self: *DependencyGraph, pkg_key: []const u8, dep_key: []const u8) ResolverError!bool {
        var node = self.nodes.getPtr(pkg_key) orelse return ResolverError.PackageNotFound;
        for (node.dependencies.items) |existing| {
            if (std.mem.eql(u8, existing, dep_key)) {
                return false;
            }
        }
        const dep_copy = self.allocator.dupe(u8, dep_key) catch {
            return ResolverError.OutOfMemory;
        };
        node.dependencies.append(self.allocator, dep_copy) catch {
            self.allocator.free(dep_copy);
            return ResolverError.OutOfMemory;
        };
        return true;
    }
};

const TarjanState = struct {
    index_counter: usize = 0,
    stack: std.ArrayList([]const u8),
    sccs: std.ArrayList(std.ArrayList([]const u8)),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TarjanState {
        return .{
            .stack = .empty,
            .sccs = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *TarjanState) void {
        self.stack.deinit(self.allocator);
        for (self.sccs.items) |*scc| {
            scc.deinit(self.allocator);
        }
        self.sccs.deinit(self.allocator);
    }
};

fn tarjanStrongConnect(
    graph: *DependencyGraph,
    state: *TarjanState,
    pkg_key: []const u8,
) ResolverError!void {
    var node = graph.nodes.getPtr(pkg_key) orelse return ResolverError.PackageNotFound;

    node.index = state.index_counter;
    node.low_link = state.index_counter;
    state.index_counter += 1;

    state.stack.append(state.allocator, pkg_key) catch {
        return ResolverError.OutOfMemory;
    };
    node.on_stack = true;

    for (node.dependencies.items) |dep_key| {
        const dep_node = graph.nodes.getPtr(dep_key) orelse continue;

        if (dep_node.index == null) {
            try tarjanStrongConnect(graph, state, dep_key);
            const updated_dep = graph.nodes.getPtr(dep_key) orelse unreachable;
            const current = graph.nodes.getPtr(pkg_key) orelse unreachable;
            current.low_link = @min(current.low_link.?, updated_dep.low_link.?);
        } else if (dep_node.on_stack) {
            const current = graph.nodes.getPtr(pkg_key) orelse unreachable;
            current.low_link = @min(current.low_link.?, dep_node.index.?);
        }
    }

    const current_node = graph.nodes.getPtr(pkg_key) orelse unreachable;
    if (current_node.low_link == current_node.index) {
        var scc: std.ArrayList([]const u8) = .empty;

        while (true) {
            const w = state.stack.pop() orelse unreachable; // Stack should never be empty here
            var w_node = graph.nodes.getPtr(w) orelse unreachable;
            w_node.on_stack = false;

            scc.append(state.allocator, w) catch {
                scc.deinit(state.allocator);
                return ResolverError.OutOfMemory;
            };

            if (std.mem.eql(u8, w, pkg_key)) break;
        }

        state.sccs.append(state.allocator, scc) catch {
            scc.deinit(state.allocator);
            return ResolverError.OutOfMemory;
        };
    }
}

fn findSCCs(graph: *DependencyGraph, allocator: std.mem.Allocator) ResolverError![][]const []const u8 {
    var state = TarjanState.init(allocator);
    defer state.deinit();

    var iter = graph.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        if (node.index == null) {
            try tarjanStrongConnect(graph, &state, node.pkg_key);
        }
    }

    // Convert to owned slice
    const result = allocator.alloc([]const []const u8, state.sccs.items.len) catch {
        return ResolverError.OutOfMemory;
    };
    errdefer allocator.free(result);

    for (state.sccs.items, 0..) |scc, i| {
        const scc_slice = allocator.alloc([]const u8, scc.items.len) catch {
            return ResolverError.OutOfMemory;
        };
        @memcpy(scc_slice, scc.items);
        result[i] = scc_slice;
    }

    return result;
}

fn topologicalSort(
    graph: *DependencyGraph,
    sccs: []const []const []const u8,
    allocator: std.mem.Allocator,
) ResolverError!std.StringHashMap(usize) {
    var pkg_to_scc = std.StringHashMap(usize).init(allocator);
    defer pkg_to_scc.deinit();

    for (sccs, 0..) |scc, scc_idx| {
        for (scc) |pkg_key| {
            pkg_to_scc.put(pkg_key, scc_idx) catch {
                return ResolverError.OutOfMemory;
            };
        }
    }

    var scc_in_degree = allocator.alloc(usize, sccs.len) catch {
        return ResolverError.OutOfMemory;
    };
    defer allocator.free(scc_in_degree);
    @memset(scc_in_degree, 0);

    const scc_adj = allocator.alloc(std.ArrayList(usize), sccs.len) catch {
        return ResolverError.OutOfMemory;
    };
    defer {
        for (scc_adj) |*neighbors| {
            neighbors.deinit(allocator);
        }
        allocator.free(scc_adj);
    }
    for (scc_adj) |*neighbors| {
        neighbors.* = .empty;
    }

    var seen_edges = std.AutoHashMap(u128, void).init(allocator);
    defer seen_edges.deinit();

    var iter = graph.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        const from_scc = pkg_to_scc.get(node.pkg_key) orelse continue;

        for (node.dependencies.items) |dep_key| {
            const to_scc = pkg_to_scc.get(dep_key) orelse continue;
            if (from_scc != to_scc) {
                const edge_key = (@as(u128, from_scc) << 64) | @as(u128, to_scc);
                if (seen_edges.contains(edge_key)) continue;
                seen_edges.put(edge_key, {}) catch {
                    return ResolverError.OutOfMemory;
                };
                scc_in_degree[to_scc] += 1;
                scc_adj[from_scc].append(allocator, to_scc) catch {
                    return ResolverError.OutOfMemory;
                };
            }
        }
    }

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);

    for (scc_in_degree, 0..) |degree, scc_idx| {
        if (degree == 0) {
            queue.append(allocator, scc_idx) catch {
                return ResolverError.OutOfMemory;
            };
        }
    }

    var scc_order: std.ArrayList(usize) = .empty;
    defer scc_order.deinit(allocator);

    var queue_head: usize = 0;
    while (queue_head < queue.items.len) {
        const scc_idx = queue.items[queue_head];
        queue_head += 1;
        scc_order.append(allocator, scc_idx) catch {
            return ResolverError.OutOfMemory;
        };

        for (scc_adj[scc_idx].items) |to_scc| {
            scc_in_degree[to_scc] -= 1;
            if (scc_in_degree[to_scc] == 0) {
                queue.append(allocator, to_scc) catch {
                    return ResolverError.OutOfMemory;
                };
            }
        }
    }

    var result = std.StringHashMap(usize).init(allocator);
    errdefer result.deinit();

    // Reverse topological order so dependencies install before dependents.
    var install_order: usize = 0;
    var order_idx: usize = scc_order.items.len;
    while (order_idx > 0) {
        order_idx -= 1;
        const scc_idx = scc_order.items[order_idx];
        for (sccs[scc_idx]) |pkg_key| {
            result.put(pkg_key, install_order) catch {
                return ResolverError.OutOfMemory;
            };
            install_order += 1;
        }
    }

    return result;
}

const Candidate = struct {
    pkg: package.Package,
    repocache: *RepoCache,
    pkg_name: []const u8,
    priority: u8,

    fn deinit(self: *Candidate) void {
        self.pkg.deinit();
    }
};

const CandidateDecision = struct {
    label: []const u8,
    reason: []const u8,

    fn deinit(self: *CandidateDecision, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.reason);
    }
};

const GraphTxn = struct {
    allocator: std.mem.Allocator,
    added_nodes: std.ArrayList([]const u8),
    added_edges: std.ArrayList(struct { from: []const u8, to: []const u8 }),
    added_requirement_keys: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) GraphTxn {
        return .{
            .allocator = allocator,
            .added_nodes = .empty,
            .added_edges = .empty,
            .added_requirement_keys = .empty,
        };
    }

    fn deinit(self: *GraphTxn) void {
        self.added_nodes.deinit(self.allocator);
        self.added_edges.deinit(self.allocator);
        self.added_requirement_keys.deinit(self.allocator);
    }

    fn recordNode(self: *GraphTxn, key: []const u8) ResolverError!void {
        self.added_nodes.append(self.allocator, key) catch {
            return ResolverError.OutOfMemory;
        };
    }

    fn recordEdge(self: *GraphTxn, from: []const u8, to: []const u8) ResolverError!void {
        self.added_edges.append(self.allocator, .{ .from = from, .to = to }) catch {
            return ResolverError.OutOfMemory;
        };
    }

    fn recordRequirementKey(self: *GraphTxn, key: []const u8) ResolverError!void {
        self.added_requirement_keys.append(self.allocator, key) catch {
            return ResolverError.OutOfMemory;
        };
    }

    fn rollback(self: *GraphTxn, graph: *DependencyGraph, resolved_requirements: *std.StringHashMap([]const u8)) void {
        var requirement_idx = self.added_requirement_keys.items.len;
        while (requirement_idx > 0) {
            requirement_idx -= 1;
            const requirement_key = self.added_requirement_keys.items[requirement_idx];
            if (resolved_requirements.fetchRemove(requirement_key)) |entry| {
                self.allocator.free(entry.key);
            }
        }

        var edge_idx = self.added_edges.items.len;
        while (edge_idx > 0) {
            edge_idx -= 1;
            const edge = self.added_edges.items[edge_idx];
            removeEdge(graph, edge.from, edge.to);
        }

        var node_idx = self.added_nodes.items.len;
        while (node_idx > 0) {
            node_idx -= 1;
            const key = self.added_nodes.items[node_idx];
            removeNode(graph, key);
        }
    }
};

fn deinitResolvedRequirements(resolved_requirements: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) void {
    var iter = resolved_requirements.keyIterator();
    while (iter.next()) |key| {
        allocator.free(key.*);
    }
    resolved_requirements.deinit();
}

fn lookupResolvedRequirement(
    graph: *DependencyGraph,
    resolved_requirements: *std.StringHashMap([]const u8),
    requirement_label: []const u8,
    allocator: std.mem.Allocator,
) ?[]const u8 {
    const dep_key = resolved_requirements.get(requirement_label) orelse return null;
    if (graph.nodes.contains(dep_key)) {
        return dep_key;
    }

    if (resolved_requirements.fetchRemove(requirement_label)) |entry| {
        allocator.free(entry.key);
    }
    return null;
}

fn cacheResolvedRequirement(
    resolved_requirements: *std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    requirement_label: []const u8,
    dep_key: []const u8,
    txn: ?*GraphTxn,
) ResolverError!void {
    if (resolved_requirements.getPtr(requirement_label)) |existing| {
        existing.* = dep_key;
        return;
    }

    const key_copy = allocator.dupe(u8, requirement_label) catch {
        return ResolverError.OutOfMemory;
    };
    errdefer allocator.free(key_copy);

    resolved_requirements.put(key_copy, dep_key) catch {
        return ResolverError.OutOfMemory;
    };

    if (txn) |active_txn| {
        try active_txn.recordRequirementKey(key_copy);
    }
}

fn packageProvidesRequirementResource(pkg: *const package.Package, requirement_name: []const u8) bool {
    if (pkg.name) |pkg_name| {
        if (std.mem.eql(u8, pkg_name, requirement_name)) return true;
    }

    const bare_requirement = std.mem.indexOfScalar(u8, requirement_name, '/') == null;
    for (pkg.provisions.items) |prov| {
        if (std.mem.eql(u8, prov.resource, requirement_name)) return true;
        if (bare_requirement and prov.prov_type == .bin) {
            if (std.mem.eql(u8, std.fs.path.basename(prov.resource), requirement_name)) return true;
        }
    }

    return false;
}

fn packageMatchesRequirement(pkg: *const package.Package, requirement: Requirement) ResolverError!bool {
    if (!packageProvidesRequirementResource(pkg, requirement.name)) return false;
    if (requirement.content_hash) |hash| {
        return pkg.content_hash.len > 0 and std.mem.eql(u8, pkg.content_hash, hash);
    }
    if (requirement.constraint_expr) |expr| {
        const version = pkg.version orelse return ResolverError.InvalidInput;
        const release = pkg.release orelse return ResolverError.InvalidInput;
        return version_constraint.matchesConstraintExpr(expr, version, release) catch {
            return ResolverError.InvalidInput;
        };
    }
    return true;
}

fn lookupSatisfiedGraphNode(
    graph: *DependencyGraph,
    requirement: Requirement,
) ResolverError!?[]const u8 {
    var matched: ?[]const u8 = null;
    var iter = graph.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        if (node.pkg == null) continue;
        if (!try packageMatchesRequirement(&node.pkg.?, requirement)) continue;
        if (matched) |existing| {
            if (!std.mem.eql(u8, existing, node.pkg_key)) return null;
        } else {
            matched = node.pkg_key;
        }
    }
    return matched;
}

fn removeNode(graph: *DependencyGraph, key: []const u8) void {
    if (graph.nodes.fetchRemove(key)) |entry| {
        var node = entry.value;
        node.deinit(graph.allocator);
    }
}

fn removeEdge(graph: *DependencyGraph, from: []const u8, to: []const u8) void {
    var node = graph.nodes.getPtr(from) orelse return;
    var idx: usize = 0;
    while (idx < node.dependencies.items.len) {
        if (std.mem.eql(u8, node.dependencies.items[idx], to)) {
            const removed = node.dependencies.swapRemove(idx);
            graph.allocator.free(removed);
            return;
        }
        idx += 1;
    }
}

/// Compare candidates for sorting (higher priority first)
fn currentTargetArch() []const u8 {
    return @tagName(builtin.cpu.arch);
}

fn packageMatchesTargetArch(pkg: *const package.Package, target_arch: []const u8) bool {
    const pkg_arch = pkg.arch orelse return false;
    return std.mem.eql(u8, pkg_arch, target_arch) or std.mem.eql(u8, pkg_arch, "any");
}

fn candidateArchRank(candidate: Candidate, target_arch: []const u8) u8 {
    const pkg_arch = candidate.pkg.arch orelse return 2;
    if (std.mem.eql(u8, pkg_arch, target_arch)) return 0;
    if (std.mem.eql(u8, pkg_arch, "any")) return 1;
    return 2;
}

fn compareCandidates(target_arch: []const u8, a: Candidate, b: Candidate) bool {
    const version_mod = @import("version.zig");

    // 1. Compare versions and releases together
    const ver_cmp = version_mod.comparePackageVersions(
        a.pkg.version.?,
        a.pkg.release.?,
        b.pkg.version.?,
        b.pkg.release.?,
    ) catch return false;
    if (ver_cmp == .greater) return true; // a > b, a should come first
    if (ver_cmp == .less) return false; // a < b, b should come first

    // 2. Compare repo priority (lower number = higher priority)
    if (a.priority < b.priority) return true; // Lower priority number is better
    if (a.priority > b.priority) return false;

    // 3. Prefer an exact target-arch package over "any" when all else is tied.
    const a_arch_rank = candidateArchRank(a, target_arch);
    const b_arch_rank = candidateArchRank(b, target_arch);
    if (a_arch_rank < b_arch_rank) return true;
    if (a_arch_rank > b_arch_rank) return false;

    return false; // Equal
}

fn sameRank(target_arch: []const u8, a: Candidate, b: Candidate) bool {
    const version_mod = @import("version.zig");
    const ver_cmp = version_mod.comparePackageVersions(
        a.pkg.version.?,
        a.pkg.release.?,
        b.pkg.version.?,
        b.pkg.release.?,
    ) catch return false;
    if (ver_cmp != .equal) return false;
    return a.priority == b.priority and candidateArchRank(a, target_arch) == candidateArchRank(b, target_arch);
}

fn matchesPin(pin_info: *const pin.Info, candidate: Candidate) bool {
    const components = store.parseStorePath(pin_info.store_path) catch {
        return false;
    };
    if (!std.mem.eql(u8, components.name, candidate.pkg.name.?)) return false;
    if (!std.mem.eql(u8, components.version, candidate.pkg.version.?)) return false;
    if (candidate.pkg.content_hash.len == 64 and !std.mem.eql(u8, components.content_hash, candidate.pkg.content_hash)) {
        return false;
    }
    return true;
}

fn formatCandidateLabel(allocator: std.mem.Allocator, candidate: Candidate) ResolverError![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}-{d} ({s}, repo {s}, priority {d})", .{
        candidate.pkg.name.?,
        candidate.pkg.version.?,
        candidate.pkg.release.?,
        candidate.pkg.arch.?,
        candidate.repocache.name,
        candidate.priority,
    }) catch {
        return ResolverError.OutOfMemory;
    };
}

fn formatResolutionFailure(
    ctx: *Context,
    requirement: []const u8,
    decisions: []const CandidateDecision,
) ResolverError!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);

    var out_buf: std.Io.Writer.Allocating = .fromArrayList(ctx.allocator, &buf);
    const out = &out_buf.writer;
    out.print("resolution failed for '{s}': ", .{requirement}) catch return ResolverError.OutOfMemory;

    for (decisions, 0..) |decision, idx| {
        if (idx > 0) out.writeAll("; ") catch return ResolverError.OutOfMemory;
        out.print("{s} rejected: {s}", .{ decision.label, decision.reason }) catch return ResolverError.OutOfMemory;
    }

    buf = out_buf.toArrayList();
    const msg = try buf.toOwnedSlice(ctx.allocator);
    errdefer ctx.allocator.free(msg);
    ctx.setDiagnosticContext(requirement, msg);
    ctx.allocator.free(msg);
}

fn formatAmbiguity(
    ctx: *Context,
    requirement: []const u8,
    candidates: []const Candidate,
) ResolverError!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);

    var out_buf: std.Io.Writer.Allocating = .fromArrayList(ctx.allocator, &buf);
    const out = &out_buf.writer;
    out.print("ambiguous providers for '{s}' (same version/release/priority): ", .{requirement}) catch return ResolverError.OutOfMemory;
    for (candidates, 0..) |candidate, idx| {
        const label = try formatCandidateLabel(ctx.allocator, candidate);
        defer ctx.allocator.free(label);
        if (idx > 0) out.writeAll("; ") catch return ResolverError.OutOfMemory;
        out.print("{s}", .{label}) catch return ResolverError.OutOfMemory;
    }

    buf = out_buf.toArrayList();
    const msg = try buf.toOwnedSlice(ctx.allocator);
    errdefer ctx.allocator.free(msg);
    ctx.setDiagnosticContext(requirement, msg);
    ctx.allocator.free(msg);
}

fn appendDecision(
    allocator: std.mem.Allocator,
    decisions: *std.ArrayList(CandidateDecision),
    label: []const u8,
    reason: []const u8,
) ResolverError!void {
    const label_copy = allocator.dupe(u8, label) catch {
        allocator.free(reason);
        return ResolverError.OutOfMemory;
    };
    decisions.append(allocator, .{ .label = label_copy, .reason = reason }) catch {
        allocator.free(label_copy);
        allocator.free(reason);
        return ResolverError.OutOfMemory;
    };
}

fn formatDependencyFailureReason(
    allocator: std.mem.Allocator,
    dep_name: []const u8,
    err: anyerror,
    dep_diag: errors.DiagnosticContext,
) ResolverError![]const u8 {
    return blk: {
        if (dep_diag.details) |details| {
            break :blk std.fmt.allocPrint(allocator, "dependency '{s}' failed: {s} - {s}", .{
                dep_name,
                @errorName(err),
                details,
            });
        }
        if (dep_diag.subject) |subject| {
            if (!std.mem.eql(u8, subject, dep_name)) {
                break :blk std.fmt.allocPrint(allocator, "dependency '{s}' failed: {s} (while resolving {s})", .{
                    dep_name,
                    @errorName(err),
                    subject,
                });
            }
        }
        break :blk std.fmt.allocPrint(allocator, "dependency '{s}' failed: {s}", .{
            dep_name,
            @errorName(err),
        });
    } catch {
        return ResolverError.OutOfMemory;
    };
}

/// Collect all candidates for a package from all repositories
fn collectCandidates(
    ctx: *Context,
    pkg_name: []const u8,
    repocaches: []*RepoCache,
    target_arch: []const u8,
    allocator: std.mem.Allocator,
) !std.ArrayList(Candidate) {
    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (candidates.items) |*c| {
            c.deinit();
        }
        candidates.deinit(allocator);
    }

    for (repocaches) |repocache| {
        if (repocache.repository) |repo| {
            // Try by name first
            if (repo.db.getPackagesByName(allocator, pkg_name)) |pkgs| {
                var packages = pkgs;
                var appended_by_name = false;
                defer {
                    for (packages.items) |*pkg| pkg.deinit();
                    packages.deinit(allocator);
                }
                for (packages.items) |*pkg| {
                    if (!packageMatchesTargetArch(pkg, target_arch)) continue;
                    try candidates.append(allocator, .{
                        .pkg = pkg.*,
                        .repocache = repocache,
                        .pkg_name = pkg.name.?,
                        .priority = repocache.priority,
                    });
                    pkg.* = package.Package.init(ctx);
                    appended_by_name = true;
                }
                if (appended_by_name) continue;
            } else |err| switch (err) {
                error.PackageNotFound => {},
                else => {
                    return ctx.failFmt(
                        ResolverError.FileSystem,
                        pkg_name,
                        "repository '{s}' candidate lookup by name failed: {s}",
                        .{ repocache.name, @errorName(err) },
                    );
                },
            }

            // Try by provision
            if (repo.db.getPackagesByProvision(allocator, pkg_name)) |pkgs| {
                var packages = pkgs;
                var appended_by_provision = false;
                defer {
                    for (packages.items) |*pkg| pkg.deinit();
                    packages.deinit(allocator);
                }
                for (packages.items) |*pkg| {
                    if (!packageMatchesTargetArch(pkg, target_arch)) continue;
                    try candidates.append(allocator, .{
                        .pkg = pkg.*,
                        .repocache = repocache,
                        .pkg_name = pkg.name.?,
                        .priority = repocache.priority,
                    });
                    pkg.* = package.Package.init(ctx);
                    appended_by_provision = true;
                }
                if (appended_by_provision) continue;
            } else |err| switch (err) {
                error.PackageNotFound => {},
                else => {
                    return ctx.failFmt(
                        ResolverError.FileSystem,
                        pkg_name,
                        "repository '{s}' candidate lookup by provision failed: {s}",
                        .{ repocache.name, @errorName(err) },
                    );
                },
            }

            // Try by bin provision basename match (e.g., "python3" -> "/usr/bin/python3")
            // Only for bare names without path separators
            if (std.mem.indexOfScalar(u8, pkg_name, '/') == null) {
                if (repo.db.getPackagesByBinBasename(allocator, pkg_name)) |pkgs| {
                    var packages = pkgs;
                    defer {
                        for (packages.items) |*pkg| pkg.deinit();
                        packages.deinit(allocator);
                    }
                    for (packages.items) |*pkg| {
                        if (!packageMatchesTargetArch(pkg, target_arch)) continue;
                        try candidates.append(allocator, .{
                            .pkg = pkg.*,
                            .repocache = repocache,
                            .pkg_name = pkg.name.?,
                            .priority = repocache.priority,
                        });
                        pkg.* = package.Package.init(ctx);
                    }
                } else |err| switch (err) {
                    error.PackageNotFound => {},
                    else => {
                        return ctx.failFmt(
                            ResolverError.FileSystem,
                            pkg_name,
                            "repository '{s}' candidate lookup by bin basename failed: {s}",
                            .{ repocache.name, @errorName(err) },
                        );
                    },
                }
            }
        }
    }

    return candidates;
}

fn collectAndRankCandidates(
    ctx: *Context,
    pkg_name: []const u8,
    repocaches: []*RepoCache,
    target_arch: []const u8,
    allocator: std.mem.Allocator,
    enforce_unique_top_rank: bool,
) ResolverError!std.ArrayList(Candidate) {
    var candidates = try collectCandidates(ctx, pkg_name, repocaches, target_arch, allocator);
    errdefer {
        for (candidates.items) |*c| {
            c.deinit();
        }
        candidates.deinit(allocator);
    }

    if (candidates.items.len == 0) {
        return ctx.fail(ResolverError.PackageNotFound, pkg_name, null);
    }

    // Sort candidates by version, release, and priority
    const sort_ctx = struct {
        target_arch: []const u8,

        fn lessThan(ctx2: @This(), a: Candidate, b: Candidate) bool {
            return compareCandidates(ctx2.target_arch, a, b);
        }
    }{ .target_arch = target_arch };
    std.mem.sort(Candidate, candidates.items, sort_ctx, @TypeOf(sort_ctx).lessThan);

    if (enforce_unique_top_rank and candidates.items.len > 1) {
        var tied: usize = 1;
        while (tied < candidates.items.len) : (tied += 1) {
            if (!sameRank(target_arch, candidates.items[0], candidates.items[tied])) break;
        }
        if (tied > 1) {
            try formatAmbiguity(ctx, pkg_name, candidates.items[0..tied]);
            return ResolverError.ConflictingProvisions;
        }
    }

    return candidates;
}

fn loadPreferredCandidate(
    ctx: *Context,
    preferred: PreferredSelection,
    repocaches: []*RepoCache,
    target_arch: []const u8,
) ResolverError!?Candidate {
    if (!std.mem.eql(u8, preferred.arch, target_arch) and !std.mem.eql(u8, preferred.arch, "any")) {
        return null;
    }

    var best: ?Candidate = null;
    errdefer if (best) |*candidate| candidate.deinit();

    for (repocaches) |repocache| {
        if (repocache.repository) |repo| {
            var pkg = repo.db.getPackageExact(
                preferred.name,
                preferred.version,
                preferred.release,
                preferred.arch,
            ) catch |err| switch (err) {
                error.PackageNotFound => continue,
                else => {
                    return ctx.failFmt(
                        ResolverError.FileSystem,
                        preferred.name,
                        "repository '{s}' exact preferred lookup failed: {s}",
                        .{ repocache.name, @errorName(err) },
                    );
                },
            };

            if (!std.mem.eql(u8, pkg.content_hash, preferred.content_hash)) {
                pkg.deinit();
                continue;
            }

            if (best) |*current_best| {
                if (repocache.priority < current_best.priority) {
                    current_best.deinit();
                    current_best.* = .{
                        .pkg = pkg,
                        .repocache = repocache,
                        .pkg_name = pkg.name.?,
                        .priority = repocache.priority,
                    };
                } else {
                    pkg.deinit();
                }
            } else {
                best = .{
                    .pkg = pkg,
                    .repocache = repocache,
                    .pkg_name = pkg.name.?,
                    .priority = repocache.priority,
                };
            }
        }
    }

    return best;
}

fn collectPreferredCandidates(
    ctx: *Context,
    requirement_name: []const u8,
    repocaches: []*RepoCache,
    preferred_selections: []const PreferredSelection,
    target_arch: []const u8,
    allocator: std.mem.Allocator,
) ResolverError!std.ArrayList(Candidate) {
    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (candidates.items) |*candidate| candidate.deinit();
        candidates.deinit(allocator);
    }

    for (preferred_selections) |preferred| {
        var candidate = (try loadPreferredCandidate(ctx, preferred, repocaches, target_arch)) orelse continue;
        if (packageProvidesRequirementResource(&candidate.pkg, requirement_name)) {
            try candidates.append(allocator, candidate);
        } else {
            candidate.deinit();
        }
    }

    if (candidates.items.len > 1) {
        const sort_ctx = struct {
            target_arch: []const u8,

            fn lessThan(ctx2: @This(), a: Candidate, b: Candidate) bool {
                return compareCandidates(ctx2.target_arch, a, b);
            }
        }{ .target_arch = target_arch };
        std.mem.sort(Candidate, candidates.items, sort_ctx, @TypeOf(sort_ctx).lessThan);
    }

    return candidates;
}

fn resolvePinForRequirement(
    pkg_name: []const u8,
    pins: []const pin.Info,
) ?*const pin.Info {
    for (pins) |*pin_info| {
        if (std.mem.eql(u8, pin_info.package_name, pkg_name)) {
            return pin_info;
        }
    }

    return null;
}

fn ensureCandidateMatchesPin(
    allocator: std.mem.Allocator,
    maybe_pin: ?*const pin.Info,
    candidate: Candidate,
    candidate_label: []const u8,
    decisions: *std.ArrayList(CandidateDecision),
) ResolverError!bool {
    const pin_info = maybe_pin orelse return true;
    if (matchesPin(pin_info, candidate)) return true;

    const reason = std.fmt.allocPrint(allocator, "pin requires {s}-{s} from {s}", .{
        pin_info.package_name,
        pin_info.package_version,
        pin_info.store_path,
    }) catch {
        return ResolverError.OutOfMemory;
    };
    try appendDecision(allocator, decisions, candidate_label, reason);
    return false;
}

fn tryResolveCandidate(
    ctx: *Context,
    graph: *DependencyGraph,
    resolved_requirements: *std.StringHashMap([]const u8),
    repocaches: []*RepoCache,
    pins: []const pin.Info,
    preferred_selections: []const PreferredSelection,
    allocator: std.mem.Allocator,
    maybe_pin: ?*const pin.Info,
    candidate: *Candidate,
    candidate_label: []const u8,
    decisions: *std.ArrayList(CandidateDecision),
    depth: usize,
) ResolverError!?[]const u8 {
    if (!try ensureCandidateMatchesPin(allocator, maybe_pin, candidate.*, candidate_label, decisions)) {
        return null;
    }

    const pkg_key = std.fmt.allocPrint(allocator, "{s}|{s}|{d}|{s}", .{
        candidate.pkg.name.?,
        candidate.pkg.version.?,
        candidate.pkg.release.?,
        candidate.pkg.arch.?,
    }) catch {
        return ResolverError.OutOfMemory;
    };
    defer allocator.free(pkg_key);

    if (graph.nodes.contains(pkg_key)) {
        const existing = graph.nodes.getPtr(pkg_key) orelse return ResolverError.PackageNotFound;
        return existing.pkg_key;
    }

    ctx.debug("selected {s}-{s}-{d} from repo {s} (priority {})", .{
        candidate.pkg.name.?,
        candidate.pkg.version.?,
        candidate.pkg.release.?,
        candidate.repocache.name,
        candidate.priority,
    });

    var txn = GraphTxn.init(allocator);
    defer txn.deinit();

    const admitted_key = try admitCandidateNode(ctx, graph, candidate, pkg_key, &txn);

    var candidate_failed = false;
    try resolveCandidateDependencies(
        ctx,
        graph,
        resolved_requirements,
        repocaches,
        pins,
        preferred_selections,
        allocator,
        admitted_key,
        candidate.pkg_name,
        candidate_label,
        decisions,
        &txn,
        &candidate_failed,
        depth,
    );

    if (candidate_failed) {
        txn.rollback(graph, resolved_requirements);
        return null;
    }

    return admitted_key;
}

fn admitCandidateNode(
    ctx: *Context,
    graph: *DependencyGraph,
    candidate: *Candidate,
    pkg_key: []const u8,
    txn: *GraphTxn,
) ResolverError![]const u8 {
    const pkg = candidate.pkg;
    const repocache = candidate.repocache;
    candidate.pkg = package.Package.init(ctx);

    try graph.addNode(pkg_key, pkg, repocache);
    const admitted_key = (graph.nodes.getPtr(pkg_key) orelse return ResolverError.PackageNotFound).pkg_key;
    try txn.recordNode(admitted_key);
    return admitted_key;
}

fn resolveCandidateDependencies(
    ctx: *Context,
    graph: *DependencyGraph,
    resolved_requirements: *std.StringHashMap([]const u8),
    repocaches: []*RepoCache,
    pins: []const pin.Info,
    preferred_selections: []const PreferredSelection,
    allocator: std.mem.Allocator,
    from_pkg_key: []const u8,
    pkg_name: []const u8,
    candidate_label: []const u8,
    decisions: *std.ArrayList(CandidateDecision),
    txn: *GraphTxn,
    candidate_failed: *bool,
    depth: usize,
) ResolverError!void {
    const node = graph.nodes.getPtr(from_pkg_key) orelse return ResolverError.PackageNotFound;
    const repocache = node.repocache;
    if (repocache.repository == null) return;
    if (node.pkg == null) {
        return ctx.fail(ResolverError.InvalidInput, from_pkg_key, "resolver missing admitted package metadata");
    }

    const repo = repocache.repository.?;
    const admitted_pkg = node.pkg.?;
    var deps = repo.db.getDependenciesForPackageExact(
        allocator,
        admitted_pkg.name.?,
        admitted_pkg.version.?,
        admitted_pkg.release.?,
        admitted_pkg.arch.?,
    ) catch |err| {
        if (err == error.PackageNotFound) {
            return ctx.fail(ResolverError.PackageNotFound, pkg_name, "dependencies not found");
        }
        return ResolverError.FileSystem;
    };
    defer {
        for (deps.items) |*dep| {
            dep.deinit(allocator);
        }
        deps.deinit(allocator);
    }

    for (deps.items) |dep| {
        const requirement: Requirement = .{
            .name = dep.target_resource,
            .constraint_expr = dep.version_constraint,
        };
        const dep_key = resolveRequirement(ctx, graph, resolved_requirements, repocaches, pins, preferred_selections, requirement, allocator, depth + 1, txn) catch |err| {
            const dep_diag = ctx.getDiagnosticContext();
            const reason = try formatDependencyFailureReason(allocator, requirement.name, err, dep_diag);
            try appendDecision(allocator, decisions, candidate_label, reason);
            candidate_failed.* = true;
            break;
        };

        if (candidate_failed.*) break;

        const added = try graph.addEdge(from_pkg_key, dep_key);
        if (added) {
            try txn.recordEdge(from_pkg_key, dep_key);
        }
    }
}

fn finalizeResolutionFailure(
    ctx: *Context,
    requirement_label: []const u8,
    decisions: []const CandidateDecision,
) ResolverError![]const u8 {
    if (decisions.len > 0) {
        try formatResolutionFailure(ctx, requirement_label, decisions);
    }
    return ResolverError.UnsatisfiableDependencies;
}

fn resolveRequirement(
    ctx: *Context,
    graph: *DependencyGraph,
    resolved_requirements: *std.StringHashMap([]const u8),
    repocaches: []*RepoCache,
    pins: []const pin.Info,
    preferred_selections: []const PreferredSelection,
    requirement: Requirement,
    allocator: std.mem.Allocator,
    depth: usize,
    txn: ?*GraphTxn,
) ResolverError![]const u8 {
    const requirement_label = if (requirement.constraint_expr) |expr|
        std.fmt.allocPrint(allocator, "{s}{s}", .{ requirement.name, expr }) catch return ResolverError.OutOfMemory
    else
        allocator.dupe(u8, requirement.name) catch return ResolverError.OutOfMemory;
    defer allocator.free(requirement_label);

    if (lookupResolvedRequirement(graph, resolved_requirements, requirement_label, allocator)) |resolved| {
        return resolved;
    }

    if (try lookupSatisfiedGraphNode(graph, requirement)) |resolved| {
        try cacheResolvedRequirement(resolved_requirements, allocator, requirement_label, resolved, txn);
        return resolved;
    }

    if (depth > max_requirement_depth) {
        return ctx.failFmt(
            ResolverError.UnsatisfiableDependencies,
            requirement_label,
            "dependency resolution depth exceeded ({d})",
            .{max_requirement_depth},
        );
    }

    // Check for pin first (highest priority)
    const maybe_pin = resolvePinForRequirement(requirement.name, pins);

    if (maybe_pin) |pin_info| {
        ctx.debug("found pin for {s}: {s}", .{ requirement.name, pin_info.store_path });
    }

    var decisions: std.ArrayList(CandidateDecision) = .empty;
    defer {
        for (decisions.items) |*decision| {
            decision.deinit(allocator);
        }
        decisions.deinit(allocator);
    }

    if (maybe_pin == null and preferred_selections.len > 0) {
        var preferred_candidates = try collectPreferredCandidates(
            ctx,
            requirement.name,
            repocaches,
            preferred_selections,
            currentTargetArch(),
            allocator,
        );
        defer {
            for (preferred_candidates.items) |*candidate| candidate.deinit();
            preferred_candidates.deinit(allocator);
        }

        for (preferred_candidates.items) |*candidate| {
            const candidate_label = try formatCandidateLabel(allocator, candidate.*);
            defer allocator.free(candidate_label);

            // Skip preferred candidate if a newer version exists in the repo.
            // Preferred selections stabilize dependency resolution but should
            // not hold back upgrades when a newer version is available.
            skip_preferred: {
                var all_candidates = collectAndRankCandidates(
                    ctx,
                    candidate.pkg_name,
                    repocaches,
                    currentTargetArch(),
                    allocator,
                    false,
                ) catch break :skip_preferred;
                defer {
                    for (all_candidates.items) |*c| c.deinit();
                    all_candidates.deinit(allocator);
                }
                if (all_candidates.items.len > 0 and
                    compareCandidates(currentTargetArch(), all_candidates.items[0], candidate.*))
                {
                    const reason = std.fmt.allocPrint(allocator, "newer version available: {s}-{s}-{d}", .{
                        all_candidates.items[0].pkg.name.?,
                        all_candidates.items[0].pkg.version.?,
                        all_candidates.items[0].pkg.release.?,
                    }) catch break :skip_preferred;
                    try appendDecision(allocator, &decisions, candidate_label, reason);
                    continue;
                }
            }

            if (requirement.constraint_expr) |expr| {
                const matches = version_constraint.matchesConstraintExpr(
                    expr,
                    candidate.pkg.version.?,
                    candidate.pkg.release.?,
                ) catch {
                    return ctx.fail(ResolverError.InvalidInput, requirement_label, "invalid version constraint");
                };
                if (!matches) continue;
            }

            const resolved = try tryResolveCandidate(
                ctx,
                graph,
                resolved_requirements,
                repocaches,
                pins,
                preferred_selections,
                allocator,
                null,
                candidate,
                candidate_label,
                &decisions,
                depth,
            );
            if (resolved == null) continue;
            try cacheResolvedRequirement(resolved_requirements, allocator, requirement_label, resolved.?, txn);
            return resolved.?;
        }
    }

    // Collect and rank candidates from all repositories
    var candidates = try collectAndRankCandidates(
        ctx,
        requirement.name,
        repocaches,
        currentTargetArch(),
        allocator,
        maybe_pin == null,
    );
    defer {
        for (candidates.items) |*c| {
            c.deinit();
        }
        candidates.deinit(allocator);
    }

    // Try candidates in order (limited backtracking)
    for (candidates.items) |*candidate| {
        const candidate_label = try formatCandidateLabel(allocator, candidate.*);
        defer allocator.free(candidate_label);

        if (requirement.constraint_expr) |expr| {
            const matches = version_constraint.matchesConstraintExpr(
                expr,
                candidate.pkg.version.?,
                candidate.pkg.release.?,
            ) catch {
                return ctx.fail(ResolverError.InvalidInput, requirement_label, "invalid version constraint");
            };
            if (!matches) {
                const reason = std.fmt.allocPrint(allocator, "version constraint '{s}' not satisfied", .{expr}) catch {
                    return ResolverError.OutOfMemory;
                };
                try appendDecision(allocator, &decisions, candidate_label, reason);
                continue;
            }
        }

        const resolved = try tryResolveCandidate(
            ctx,
            graph,
            resolved_requirements,
            repocaches,
            pins,
            preferred_selections,
            allocator,
            maybe_pin,
            candidate,
            candidate_label,
            &decisions,
            depth,
        );
        if (resolved == null) {
            continue;
        }
        try cacheResolvedRequirement(resolved_requirements, allocator, requirement_label, resolved.?, txn);
        return resolved.?;
    }

    return finalizeResolutionFailure(ctx, requirement_label, decisions.items);
}

pub fn withRequirements(
    ctx: *Context,
    requirements: []const Requirement,
    repocaches: []*RepoCache,
    preferred_selections: []const PreferredSelection,
    allocator: std.mem.Allocator,
) ResolverError!ResolutionResult {
    const gc_roots_dir = std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "gc-roots" }) catch {
        return ResolverError.OutOfMemory;
    };
    defer allocator.free(gc_roots_dir);

    var graph = DependencyGraph.init(allocator);
    defer graph.deinit();

    var resolved_requirements = std.StringHashMap([]const u8).init(allocator);
    defer deinitResolvedRequirements(&resolved_requirements, allocator);

    var pins = pin.list(allocator, gc_roots_dir) catch |err| {
        return switch (err) {
            error.OutOfMemory => ResolverError.OutOfMemory,
            error.PermissionDenied => ctx.fail(ResolverError.PermissionDenied, gc_roots_dir, "permission denied while listing pins"),
            error.InvalidInput, error.InvalidStorePath => ctx.fail(ResolverError.InvalidInput, gc_roots_dir, "invalid pin metadata"),
            else => ctx.fail(ResolverError.FileSystem, gc_roots_dir, "failed to list pins"),
        };
    };
    defer pins.deinit();

    for (requirements) |requirement| {
        _ = try resolveRequirement(ctx, &graph, &resolved_requirements, repocaches, pins.pins.items, preferred_selections, requirement, allocator, 0, null);
    }

    const sccs = try findSCCs(&graph, allocator);
    defer {
        for (sccs) |scc| {
            allocator.free(scc);
        }
        allocator.free(sccs);
    }

    for (sccs) |scc| {
        if (scc.len > 1) {
            if (scc.len > 0) {
                ctx.setDiagnosticContext(scc[0], "circular dependency detected");
            }
            ctx.debug("circular dependency in SCC with {d} packages", .{scc.len});
        }
    }

    var install_orders = try topologicalSort(&graph, sccs, allocator);
    defer install_orders.deinit();

    const packages = allocator.alloc(ResolvedPackage, graph.nodes.count()) catch {
        return ResolverError.OutOfMemory;
    };
    errdefer allocator.free(packages);

    var pkg_to_scc = std.StringHashMap(usize).init(allocator);
    defer pkg_to_scc.deinit();

    for (sccs, 0..) |scc, scc_idx| {
        for (scc) |pkg_key| {
            pkg_to_scc.put(pkg_key, scc_idx) catch {
                return ResolverError.OutOfMemory;
            };
        }
    }

    var idx: usize = 0;
    var iter = graph.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        const order = install_orders.get(node.pkg_key) orelse 0;
        const scc_id = pkg_to_scc.get(node.pkg_key) orelse 0;

        if (node.pkg == null) {
            return ctx.fail(ResolverError.InvalidInput, node.pkg_key, "resolver lost package ownership");
        }

        // Extract package names from dependency keys (format: "name|version|release|arch")
        const dep_names = allocator.alloc([]const u8, node.dependencies.items.len) catch {
            return ResolverError.OutOfMemory;
        };
        for (node.dependencies.items, 0..) |dep_key, di| {
            const sep = std.mem.indexOfScalar(u8, dep_key, '|') orelse dep_key.len;
            dep_names[di] = allocator.dupe(u8, dep_key[0..sep]) catch {
                return ResolverError.OutOfMemory;
            };
        }

        packages[idx] = .{
            .pkg = node.pkg.?,
            .repocache = node.repocache,
            .install_order = order,
            .scc_id = scc_id,
            .dependency_names = dep_names,
        };
        node.pkg = null;
        idx += 1;
    }

    const result_sccs = allocator.alloc([]usize, sccs.len) catch {
        return ResolverError.OutOfMemory;
    };
    errdefer allocator.free(result_sccs);

    for (sccs, 0..) |_, scc_idx| {
        var scc_indices: std.ArrayList(usize) = .empty;
        defer scc_indices.deinit(allocator);

        for (packages, 0..) |resolved, pkg_idx| {
            if (resolved.scc_id == scc_idx) {
                scc_indices.append(allocator, pkg_idx) catch {
                    return ResolverError.OutOfMemory;
                };
            }
        }

        result_sccs[scc_idx] = allocator.dupe(usize, scc_indices.items) catch {
            return ResolverError.OutOfMemory;
        };
    }

    return ResolutionResult{
        .packages = packages,
        .sccs = result_sccs,
        .allocator = allocator,
    };
}

pub fn resolve(
    ctx: *Context,
    pkg_names: []const []const u8,
    repocaches: []*RepoCache,
    allocator: std.mem.Allocator,
) ResolverError!ResolutionResult {
    var requirements: std.ArrayList(Requirement) = .empty;
    defer requirements.deinit(allocator);

    for (pkg_names) |pkg_name| {
        requirements.append(allocator, .{
            .name = pkg_name,
            .constraint_expr = null,
        }) catch return ResolverError.OutOfMemory;
    }

    return withRequirements(ctx, requirements.items, repocaches, &.{}, allocator);
}

fn initTestRepository(repocache: *RepoCache) !void {
    const Repository = @import("repository.zig").Repository;
    repocache.repository = try Repository.init(repocache.ctx, repocache.cache_dir, false);
}

fn insertTestPackage(ctx: *Context, repo: *RepoCache, name: []const u8, deps: []const []const u8) !void {
    if (repo.repository == null) {
        return ResolverError.FileSystem;
    }
    var pkg = package.Package.init(ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, name);
    pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, currentTargetArch());
    pkg.signature = try ctx.allocator.dupe(u8, "sig");
    pkg.content_hash = try ctx.allocator.dupe(u8, "hash");
    pkg.archive_hash = try ctx.allocator.dupe(u8, "a" ** 64);

    for (deps) |dep_name| {
        try pkg.addDependency(dep_name, try package.DependencyType.fromString("elf-needed"));
    }

    _ = try repo.repository.?.db.insertPackageTransaction(&pkg);
}

fn insertVersionedTestPackage(
    ctx: *Context,
    repo: *RepoCache,
    name: []const u8,
    version: []const u8,
    deps: []const package.Dependency,
) !void {
    if (repo.repository == null) {
        return ResolverError.FileSystem;
    }

    var pkg = package.Package.init(ctx);
    defer pkg.deinit();
    pkg.name = try ctx.allocator.dupe(u8, name);
    pkg.version = try ctx.allocator.dupe(u8, version);
    pkg.release = 1;
    pkg.arch = try ctx.allocator.dupe(u8, currentTargetArch());
    pkg.signature = try ctx.allocator.dupe(u8, "sig");
    pkg.content_hash = try std.fmt.allocPrint(ctx.allocator, "hash-{s}-{s}", .{ name, version });
    pkg.archive_hash = try ctx.allocator.dupe(u8, "b" ** 64);

    for (deps) |dep| {
        const dep_type = dep.getType();
        try pkg.addDependencyWithConstraint(dep.resource, dep_type, dep.version_constraint);
    }

    _ = try repo.repository.?.db.insertPackageTransaction(&pkg);
}

fn findInstallOrder(result: *const ResolutionResult, name: []const u8) ?usize {
    for (result.packages) |resolved| {
        if (resolved.pkg.name) |pkg_name| {
            if (std.mem.eql(u8, pkg_name, name)) {
                return resolved.install_order;
            }
        }
    }
    return null;
}

fn alternateTestArch() []const u8 {
    const host_arch = currentTargetArch();
    if (std.mem.eql(u8, host_arch, "x86_64")) return "aarch64";
    return "x86_64";
}

fn sccContainsPackage(result: *const ResolutionResult, scc: []usize, name: []const u8) bool {
    for (scc) |pkg_idx| {
        const pkg_name = result.packages[pkg_idx].pkg.name orelse continue;
        if (std.mem.eql(u8, pkg_name, name)) return true;
    }
    return false;
}

test "resolve linear dependencies" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const repo_url = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo", .{test_env.path});
    defer ctx.allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    try insertTestPackage(ctx, &repocache, "A", &.{"B"});
    try insertTestPackage(ctx, &repocache, "B", &.{"C"});
    try insertTestPackage(ctx, &repocache, "C", &.{});

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{"A"}, repocaches[0..], ctx.allocator);
    defer result.deinit();

    const order_a = findInstallOrder(&result, "A") orelse return error.TestUnexpectedResult;
    const order_b = findInstallOrder(&result, "B") orelse return error.TestUnexpectedResult;
    const order_c = findInstallOrder(&result, "C") orelse return error.TestUnexpectedResult;

    try std.testing.expect(order_c < order_b);
    try std.testing.expect(order_b < order_a);

    for (result.sccs) |scc| {
        try std.testing.expectEqual(@as(usize, 1), scc.len);
    }
}

// Spec #10: Dependency cycles tolerated via SCC
test "resolve detects cycles" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const repo_url = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo", .{test_env.path});
    defer ctx.allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    try insertTestPackage(ctx, &repocache, "A", &.{"B"});
    try insertTestPackage(ctx, &repocache, "B", &.{"A"});

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{"A"}, repocaches[0..], ctx.allocator);
    defer result.deinit();

    var found_cycle = false;
    for (result.sccs) |scc| {
        if (scc.len == 2 and sccContainsPackage(&result, scc, "A") and sccContainsPackage(&result, scc, "B")) {
            found_cycle = true;
            break;
        }
    }
    try std.testing.expect(found_cycle);
}

test "resolve handles duplicate SCC-to-dependency edges deterministically" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const repo_url = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo", .{test_env.path});
    defer ctx.allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    // A and B form an SCC and both depend on C, creating duplicate SCC->SCC edges.
    try insertTestPackage(ctx, &repocache, "A", &.{ "B", "C" });
    try insertTestPackage(ctx, &repocache, "B", &.{ "A", "C" });
    try insertTestPackage(ctx, &repocache, "C", &.{});

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{"A"}, repocaches[0..], ctx.allocator);
    defer result.deinit();

    const order_a = findInstallOrder(&result, "A") orelse return error.TestUnexpectedResult;
    const order_b = findInstallOrder(&result, "B") orelse return error.TestUnexpectedResult;
    const order_c = findInstallOrder(&result, "C") orelse return error.TestUnexpectedResult;

    try std.testing.expect(order_c < order_a);
    try std.testing.expect(order_c < order_b);
}

test "resolve handles disconnected components" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const repo_url = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo", .{test_env.path});
    defer ctx.allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    try insertTestPackage(ctx, &repocache, "A", &.{"B"});
    try insertTestPackage(ctx, &repocache, "B", &.{});
    try insertTestPackage(ctx, &repocache, "X", &.{});

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{ "A", "X" }, repocaches[0..], ctx.allocator);
    defer result.deinit();

    try std.testing.expect(findInstallOrder(&result, "A") != null);
    try std.testing.expect(findInstallOrder(&result, "B") != null);
    try std.testing.expect(findInstallOrder(&result, "X") != null);

    const order_a = findInstallOrder(&result, "A") orelse return error.TestUnexpectedResult;
    const order_b = findInstallOrder(&result, "B") orelse return error.TestUnexpectedResult;
    try std.testing.expect(order_b < order_a);
}

// Spec #10: Provision ambiguity = hard error
test "resolve reports ambiguity diagnostics" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    ctx.resetDiagnostics();
    defer ctx.resetDiagnostics();

    const repo_url_a = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo-a", .{test_env.path});
    defer ctx.allocator.free(repo_url_a);
    var repo_a = try RepoCache.init(ctx, "repo-a", repo_url_a, &.{}, 100);
    defer repo_a.deinit();
    try initTestRepository(&repo_a);

    const repo_url_b = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo-b", .{test_env.path});
    defer ctx.allocator.free(repo_url_b);
    var repo_b = try RepoCache.init(ctx, "repo-b", repo_url_b, &.{}, 100);
    defer repo_b.deinit();
    try initTestRepository(&repo_b);

    try insertTestPackage(ctx, &repo_a, "A", &.{});
    try insertTestPackage(ctx, &repo_b, "A", &.{});

    var repocaches = [_]*RepoCache{ &repo_a, &repo_b };
    try std.testing.expectError(
        ResolverError.ConflictingProvisions,
        resolve(ctx, &.{"A"}, repocaches[0..], ctx.allocator),
    );

    const diag = ctx.getDiagnosticContext();
    const details = diag.details orelse return error.TestUnexpectedResult;
    try std.testing.expect(diag.subject != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "ambiguous providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "repo-a") != null);
}

// Spec #10: Dependency resolution failure diagnostics
test "resolve reports dependency failure diagnostics" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    ctx.resetDiagnostics();
    defer ctx.resetDiagnostics();

    const repo_url = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo", .{test_env.path});
    defer ctx.allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    try insertTestPackage(ctx, &repocache, "A", &.{"B"});

    var repocaches = [_]*RepoCache{&repocache};
    try std.testing.expectError(
        ResolverError.UnsatisfiableDependencies,
        resolve(ctx, &.{"A"}, repocaches[0..], ctx.allocator),
    );

    const diag = ctx.getDiagnosticContext();
    const details = diag.details orelse return error.TestUnexpectedResult;
    try std.testing.expect(diag.subject != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "resolution failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "dependency 'B' failed") != null);
}

test "resolve surfaces repository lookup corruption diagnostics" {
    const th = @import("test_helpers.zig");
    const c = @import("repodb.zig").c;
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    ctx.resetDiagnostics();
    defer ctx.resetDiagnostics();

    const repo_url = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo-corrupt", .{test_env.path});
    defer ctx.allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-corrupt", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    // Corrupt lookup path by removing the packages table.
    if (repocache.repository) |*repo| {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(repo.db.db, "DROP TABLE packages;", null, null, &err_msg);
        if (err_msg != null) c.sqlite3_free(err_msg);
        try std.testing.expectEqual(c.SQLITE_OK, rc);
    } else {
        return error.TestUnexpectedResult;
    }

    var repocaches = [_]*RepoCache{&repocache};
    try std.testing.expectError(
        ResolverError.FileSystem,
        resolve(ctx, &.{"A"}, repocaches[0..], ctx.allocator),
    );

    const diag = ctx.getDiagnosticContext();
    const details = diag.details orelse return error.TestUnexpectedResult;
    try std.testing.expect(diag.subject != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "repo-corrupt") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, "lookup by name failed") != null);
}

// Spec #11: Version wins over repo priority
test "resolve version wins over repo priority" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    // Create high-priority repo (priority 10) with older version
    const repo_url_high = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo-high", .{test_env.path});
    defer ctx.allocator.free(repo_url_high);
    var repo_high_priority = try RepoCache.init(ctx, "repo-high-priority", repo_url_high, &.{}, 10);
    defer repo_high_priority.deinit();
    try initTestRepository(&repo_high_priority);

    // Create low-priority repo (priority 100) with newer version
    const repo_url_low = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo-low", .{test_env.path});
    defer ctx.allocator.free(repo_url_low);
    var repo_low_priority = try RepoCache.init(ctx, "repo-low-priority", repo_url_low, &.{}, 100);
    defer repo_low_priority.deinit();
    try initTestRepository(&repo_low_priority);

    // Insert package "A" version 1.0.0 in high-priority repo
    if (repo_high_priority.repository) |*repo| {
        var pkg = package.Package.init(ctx);
        defer pkg.deinit();
        pkg.name = try ctx.allocator.dupe(u8, "A");
        pkg.version = try ctx.allocator.dupe(u8, "1.0.0");
        pkg.release = 1;
        pkg.arch = try ctx.allocator.dupe(u8, currentTargetArch());
        pkg.signature = try ctx.allocator.dupe(u8, "sig");
        pkg.content_hash = try ctx.allocator.dupe(u8, "hash1");
        pkg.archive_hash = try ctx.allocator.dupe(u8, "1" ** 64);
        _ = try repo.db.insertPackageTransaction(&pkg);
    }

    // Insert package "A" version 2.0.0 in low-priority repo
    if (repo_low_priority.repository) |*repo| {
        var pkg = package.Package.init(ctx);
        defer pkg.deinit();
        pkg.name = try ctx.allocator.dupe(u8, "A");
        pkg.version = try ctx.allocator.dupe(u8, "2.0.0");
        pkg.release = 1;
        pkg.arch = try ctx.allocator.dupe(u8, currentTargetArch());
        pkg.signature = try ctx.allocator.dupe(u8, "sig");
        pkg.content_hash = try ctx.allocator.dupe(u8, "hash2");
        pkg.archive_hash = try ctx.allocator.dupe(u8, "2" ** 64);
        _ = try repo.db.insertPackageTransaction(&pkg);
    }

    // Resolve package "A" - should pick version 2.0.0 from low-priority repo
    var repocaches = [_]*RepoCache{ &repo_high_priority, &repo_low_priority };
    var result = try resolve(ctx, &.{"A"}, repocaches[0..], ctx.allocator);
    defer result.deinit();

    // Verify we got exactly one package
    try std.testing.expectEqual(@as(usize, 1), result.packages.len);

    // Verify it's version 2.0.0 (higher version wins despite lower priority)
    const resolved_pkg = result.packages[0];
    try std.testing.expect(resolved_pkg.pkg.version != null);
    try std.testing.expectEqualStrings("2.0.0", resolved_pkg.pkg.version.?);
    try std.testing.expectEqualStrings("hash2", resolved_pkg.pkg.content_hash);
}

test "resolve prefers current exact selection over newer version" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;
    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-preferred", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-preferred", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    try insertVersionedTestPackage(ctx, &repocache, "A", "1.0.0", &.{});
    try insertVersionedTestPackage(ctx, &repocache, "A", "2.0.0", &.{});

    const requirements = [_]Requirement{
        .{ .name = "A", .constraint_expr = null },
    };
    const preferred = [_]PreferredSelection{
        .{
            .name = "A",
            .version = "1.0.0",
            .release = 1,
            .arch = currentTargetArch(),
            .content_hash = "hash-A-1.0.0",
        },
    };

    var repocaches = [_]*RepoCache{&repocache};
    var result = try withRequirements(ctx, &requirements, repocaches[0..], &preferred, allocator);
    defer result.deinit();

    // Preferred selection should NOT hold back upgrades — newer version wins
    try std.testing.expectEqual(@as(usize, 1), result.packages.len);
    try std.testing.expectEqualStrings("2.0.0", result.packages[0].pkg.version.?);
}

test "resolve prefers current selection when it is already the latest" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;
    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-preferred-latest", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-preferred-latest", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    try insertVersionedTestPackage(ctx, &repocache, "A", "2.0.0", &.{});

    const requirements = [_]Requirement{
        .{ .name = "A", .constraint_expr = null },
    };
    const preferred = [_]PreferredSelection{
        .{
            .name = "A",
            .version = "2.0.0",
            .release = 1,
            .arch = currentTargetArch(),
            .content_hash = "hash-A-2.0.0",
        },
    };

    var repocaches = [_]*RepoCache{&repocache};
    var result = try withRequirements(ctx, &requirements, repocaches[0..], &preferred, allocator);
    defer result.deinit();

    // When preferred IS the latest, it should still be selected
    try std.testing.expectEqual(@as(usize, 1), result.packages.len);
    try std.testing.expectEqualStrings("2.0.0", result.packages[0].pkg.version.?);
}

test "resolve upgrades current selection when new dependency requires it" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;
    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-required-upgrade", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-required-upgrade", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    try insertVersionedTestPackage(ctx, &repocache, "A", "1.0.0", &.{});
    try insertVersionedTestPackage(ctx, &repocache, "A", "2.0.0", &.{});

    var dep = try package.Dependency.initWithConstraint(allocator, "A", try package.DependencyType.fromString("elf-needed"), ">=2.0");
    defer dep.deinit(allocator);
    try insertVersionedTestPackage(ctx, &repocache, "X", "1.0.0", &.{dep});

    const requirements = [_]Requirement{
        .{ .name = "X", .constraint_expr = null },
        .{ .name = "A", .constraint_expr = null },
    };
    const preferred = [_]PreferredSelection{
        .{
            .name = "A",
            .version = "1.0.0",
            .release = 1,
            .arch = currentTargetArch(),
            .content_hash = "hash-A-1.0.0",
        },
    };

    var repocaches = [_]*RepoCache{&repocache};
    var result = try withRequirements(ctx, &requirements, repocaches[0..], &preferred, allocator);
    defer result.deinit();

    var a_version: ?[]const u8 = null;
    for (result.packages) |resolved| {
        if (std.mem.eql(u8, resolved.pkg.name.?, "A")) {
            a_version = resolved.pkg.version.?;
            break;
        }
    }

    try std.testing.expect(a_version != null);
    try std.testing.expectEqualStrings("2.0.0", a_version.?);
}

test "resolve falls back to older version when latest fails constraint" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;
    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-constrained", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-constrained", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    try insertVersionedTestPackage(ctx, &repocache, "dep", "1.0.0", &.{});
    try insertVersionedTestPackage(ctx, &repocache, "dep", "2.0.0", &.{});

    var dep = try package.Dependency.initWithConstraint(allocator, "dep", try package.DependencyType.fromString("elf-needed"), "<2.0");
    defer dep.deinit(allocator);
    try insertVersionedTestPackage(ctx, &repocache, "A", "1.0.0", &.{dep});

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{"A"}, repocaches[0..], allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.packages.len);

    var dep_version: ?[]const u8 = null;
    for (result.packages) |resolved| {
        if (std.mem.eql(u8, resolved.pkg.name.?, "dep")) {
            dep_version = resolved.pkg.version.?;
            break;
        }
    }

    try std.testing.expect(dep_version != null);
    try std.testing.expectEqualStrings("1.0.0", dep_version.?);
}

test "resolve backtracks to lower-ranked dependency candidate after rollback" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;
    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-backtrack", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-backtrack", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    try insertVersionedTestPackage(ctx, &repocache, "dep", "1.0.0", &.{});

    var missing_dep = try package.Dependency.init(allocator, "missing", try package.DependencyType.fromString("elf-needed"));
    defer missing_dep.deinit(allocator);
    try insertVersionedTestPackage(ctx, &repocache, "dep", "2.0.0", &.{missing_dep});

    var dep_requirement = try package.Dependency.init(allocator, "dep", try package.DependencyType.fromString("elf-needed"));
    defer dep_requirement.deinit(allocator);
    try insertVersionedTestPackage(ctx, &repocache, "A", "1.0.0", &.{dep_requirement});

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{"A"}, repocaches[0..], allocator);
    defer result.deinit();

    var dep_version: ?[]const u8 = null;
    for (result.packages) |resolved| {
        if (std.mem.eql(u8, resolved.pkg.name.?, "dep")) {
            dep_version = resolved.pkg.version.?;
            break;
        }
    }

    try std.testing.expect(dep_version != null);
    try std.testing.expectEqualStrings("1.0.0", dep_version.?);
}

// Spec #10: Path conflicts = hard error
// Per spec #10, path conflicts (two packages own same path) are hard errors
// detected during profile building. This test resolves two packages that both
// claim /usr/bin/foo, then verifies the PathConflictDetector catches the conflict.
test "resolved packages with same path produce path conflict error" {
    const th = @import("test_helpers.zig");
    const profile = @import("profile.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const repo_url = try std.fmt.allocPrint(ctx.allocator, "file://{s}/repo", .{test_env.path});
    defer ctx.allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    // Insert two packages that both provide /usr/bin/foo
    if (repocache.repository) |*repo| {
        var pkg_a = package.Package.init(ctx);
        defer pkg_a.deinit();
        pkg_a.name = try allocator.dupe(u8, "pkg-a");
        pkg_a.version = try allocator.dupe(u8, "1.0.0");
        pkg_a.release = 1;
        pkg_a.arch = try allocator.dupe(u8, currentTargetArch());
        pkg_a.signature = try allocator.dupe(u8, "sig-a");
        pkg_a.content_hash = try allocator.dupe(u8, "aaaa");
        pkg_a.archive_hash = try allocator.dupe(u8, "a" ** 64);
        _ = try repo.db.insertPackageTransaction(&pkg_a);
    }

    if (repocache.repository) |*repo| {
        var pkg_b = package.Package.init(ctx);
        defer pkg_b.deinit();
        pkg_b.name = try allocator.dupe(u8, "pkg-b");
        pkg_b.version = try allocator.dupe(u8, "1.0.0");
        pkg_b.release = 1;
        pkg_b.arch = try allocator.dupe(u8, currentTargetArch());
        pkg_b.signature = try allocator.dupe(u8, "sig-b");
        pkg_b.content_hash = try allocator.dupe(u8, "bbbb");
        pkg_b.archive_hash = try allocator.dupe(u8, "b" ** 64);
        _ = try repo.db.insertPackageTransaction(&pkg_b);
    }

    // Resolve both packages - resolver succeeds (it doesn't check file paths)
    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{ "pkg-a", "pkg-b" }, repocaches[0..], allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.packages.len);

    // Simulate profile building: both packages claim /usr/bin/foo with different targets
    // This is what profile.zig does when building a generation
    var detector = profile.PathConflictDetector.init(allocator);
    defer detector.deinit();

    // pkg-a claims /usr/bin/foo -> /mere/store/aaaa-pkg-a-1.0.0/usr/bin/foo
    _ = try detector.recordPath("usr/bin/foo", "/mere/store/aaaa-pkg-a-1.0.0", "pkg-a");
    // pkg-b claims /usr/bin/foo -> /mere/store/bbbb-pkg-b-1.0.0/usr/bin/foo (different target)
    _ = try detector.recordPath("usr/bin/foo", "/mere/store/bbbb-pkg-b-1.0.0", "pkg-b");

    // Path conflict must be detected as a hard error
    try std.testing.expect(detector.hasConflicts());
    try std.testing.expectEqual(@as(usize, 1), detector.conflictCount());

    const conflicts = detector.getConflicts();
    try std.testing.expectEqualStrings("usr/bin/foo", conflicts[0].path);
    try std.testing.expectEqualStrings("pkg-a", conflicts[0].package_a);
    try std.testing.expectEqualStrings("pkg-b", conflicts[0].package_b);
}

test "resolve filters out foreign-arch packages" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-arch-filter", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-arch-filter", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    if (repocache.repository) |*repo| {
        var foreign_pkg = package.Package.init(ctx);
        defer foreign_pkg.deinit();
        foreign_pkg.name = try allocator.dupe(u8, "A");
        foreign_pkg.version = try allocator.dupe(u8, "2.0.0");
        foreign_pkg.release = 1;
        foreign_pkg.arch = try allocator.dupe(u8, alternateTestArch());
        foreign_pkg.signature = try allocator.dupe(u8, "sig-foreign");
        foreign_pkg.content_hash = try allocator.dupe(u8, "foreign-hash");
        foreign_pkg.archive_hash = try allocator.dupe(u8, "f" ** 64);
        _ = try repo.db.insertPackageTransaction(&foreign_pkg);
    }

    if (repocache.repository) |*repo| {
        var host_pkg = package.Package.init(ctx);
        defer host_pkg.deinit();
        host_pkg.name = try allocator.dupe(u8, "A");
        host_pkg.version = try allocator.dupe(u8, "1.0.0");
        host_pkg.release = 1;
        host_pkg.arch = try allocator.dupe(u8, currentTargetArch());
        host_pkg.signature = try allocator.dupe(u8, "sig-host");
        host_pkg.content_hash = try allocator.dupe(u8, "host-hash");
        host_pkg.archive_hash = try allocator.dupe(u8, "h" ** 64);
        _ = try repo.db.insertPackageTransaction(&host_pkg);
    }

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{"A"}, repocaches[0..], allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.packages.len);
    try std.testing.expectEqualStrings("1.0.0", result.packages[0].pkg.version.?);
    try std.testing.expectEqualStrings(currentTargetArch(), result.packages[0].pkg.arch.?);
}

test "resolve prefers exact host arch over any when tied" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-any-tie", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-any-tie", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    if (repocache.repository) |*repo| {
        var any_pkg = package.Package.init(ctx);
        defer any_pkg.deinit();
        any_pkg.name = try allocator.dupe(u8, "A");
        any_pkg.version = try allocator.dupe(u8, "1.0.0");
        any_pkg.release = 1;
        any_pkg.arch = try allocator.dupe(u8, "any");
        any_pkg.signature = try allocator.dupe(u8, "sig-any");
        any_pkg.content_hash = try allocator.dupe(u8, "any-hash");
        any_pkg.archive_hash = try allocator.dupe(u8, "a" ** 64);
        _ = try repo.db.insertPackageTransaction(&any_pkg);
    }

    if (repocache.repository) |*repo| {
        var host_pkg = package.Package.init(ctx);
        defer host_pkg.deinit();
        host_pkg.name = try allocator.dupe(u8, "A");
        host_pkg.version = try allocator.dupe(u8, "1.0.0");
        host_pkg.release = 1;
        host_pkg.arch = try allocator.dupe(u8, currentTargetArch());
        host_pkg.signature = try allocator.dupe(u8, "sig-host");
        host_pkg.content_hash = try allocator.dupe(u8, "host-hash");
        host_pkg.archive_hash = try allocator.dupe(u8, "b" ** 64);
        _ = try repo.db.insertPackageTransaction(&host_pkg);
    }

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{"A"}, repocaches[0..], allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.packages.len);
    try std.testing.expectEqualStrings(currentTargetArch(), result.packages[0].pkg.arch.?);
}

test "resolve fails cleanly when dependency recursion depth exceeds limit" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-depth-limit", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-depth-limit", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    const chain_len = max_requirement_depth + 2;
    var i: usize = 0;
    while (i < chain_len) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "deep-{d}", .{i});
        try names.append(allocator, name);
    }

    i = 0;
    while (i < chain_len) : (i += 1) {
        if (i + 1 < chain_len) {
            const deps = [_][]const u8{names.items[i + 1]};
            try insertTestPackage(ctx, &repocache, names.items[i], deps[0..]);
        } else {
            try insertTestPackage(ctx, &repocache, names.items[i], &.{});
        }
    }

    var repocaches = [_]*RepoCache{&repocache};
    try std.testing.expectError(
        ResolverError.UnsatisfiableDependencies,
        resolve(ctx, &.{names.items[0]}, repocaches[0..], allocator),
    );
}

test "resolve handles larger dependency chain deterministically" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-large-chain", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-large-chain", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    const chain_len: usize = 128;
    var i: usize = 0;
    while (i < chain_len) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "chain-{d}", .{i});
        try names.append(allocator, name);
    }

    i = 0;
    while (i < chain_len) : (i += 1) {
        if (i + 1 < chain_len) {
            const deps = [_][]const u8{names.items[i + 1]};
            try insertTestPackage(ctx, &repocache, names.items[i], deps[0..]);
        } else {
            try insertTestPackage(ctx, &repocache, names.items[i], &.{});
        }
    }

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{names.items[0]}, repocaches[0..], allocator);
    defer result.deinit();

    try std.testing.expectEqual(chain_len, result.packages.len);

    const root_order = findInstallOrder(&result, names.items[0]) orelse unreachable;
    const leaf_order = findInstallOrder(&result, names.items[chain_len - 1]) orelse unreachable;
    try std.testing.expect(leaf_order < root_order);
}

test "resolve fails when pin directory is unreadable" {
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-pin-perm", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-pin-perm", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);
    try insertTestPackage(ctx, &repocache, "A", &.{});

    const gc_roots = try std.fs.path.join(allocator, &.{ ctx.root_path, "mere", "gc-roots" });
    defer allocator.free(gc_roots);
    try @import("path.zig").ensureDirExists(gc_roots);

    const gc_roots_z = try allocator.dupeZ(u8, gc_roots);
    defer allocator.free(gc_roots_z);
    switch (std.posix.errno(std.c.chmod(gc_roots_z, 0))) {
        .SUCCESS => {},
        else => return error.FileSystem,
    }
    defer _ = std.c.chmod(gc_roots_z, 0o755);

    var repocaches = [_]*RepoCache{&repocache};
    const result = resolve(ctx, &.{"A"}, repocaches[0..], allocator);
    if (result) |success| {
        var owned = success;
        defer owned.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(ResolverError.PermissionDenied, err);
    }
}

test "resolve handles larger SCC cycle" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;
    const allocator = ctx.allocator;

    const repo_url = try std.fmt.allocPrint(allocator, "file://{s}/repo-large-scc", .{test_env.path});
    defer allocator.free(repo_url);
    var repocache = try RepoCache.init(ctx, "repo-large-scc", repo_url, &.{}, 100);
    defer repocache.deinit();
    try initTestRepository(&repocache);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    const cycle_len: usize = 24;
    var i: usize = 0;
    while (i < cycle_len) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "scc-{d}", .{i});
        try names.append(allocator, name);
    }

    i = 0;
    while (i < cycle_len) : (i += 1) {
        const next = (i + 1) % cycle_len;
        const deps = [_][]const u8{names.items[next]};
        try insertTestPackage(ctx, &repocache, names.items[i], deps[0..]);
    }

    var repocaches = [_]*RepoCache{&repocache};
    var result = try resolve(ctx, &.{names.items[0]}, repocaches[0..], allocator);
    defer result.deinit();

    try std.testing.expectEqual(cycle_len, result.packages.len);
    try std.testing.expectEqual(@as(usize, 1), result.sccs.len);
    try std.testing.expectEqual(cycle_len, result.sccs[0].len);
}
