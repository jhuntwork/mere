const std = @import("std");
const mere = @import("mere");
const types = @import("../types.zig");
const command = @import("../command.zig");
const MereError = mere.errors.MereError;
const ui = mere.ui;
const emit = ui.emit;

const search_meta = command.CommandMeta{
    .group = "Package Management",
    .order = 20,
    .name = "search",
    .description = "Search for packages by name across all configured repositories",
    .args = &[_]types.Arg{
        .{
            .name = "term",
            .description = "Search term (substring match on package name)",
            .required = true,
        },
    },
};

fn handleSearch(ctx: *mere.Context, args: *const types.ParsedArgs) MereError!types.CommandResult {
    if (args.positional.len < 1) {
        return MereError.MissingArgument;
    }

    const term = args.positional[0];

    var curl_client = try mere.download.CurlTransferClient.init(ctx);
    defer mere.download.CurlTransferClient.cleanupFn(ctx, curl_client);
    const client = curl_client.client();

    var results = mere.search.searchPackages(ctx, term, client) catch |err| {
        const user_message = mere.errors.getUserFriendlyMessage(err);
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try std.fmt.allocPrint(ctx.allocator, "search failed: {s}", .{user_message}),
        };
    };
    defer {
        for (results.items) |*r| r.deinit(ctx.allocator);
        results.deinit(ctx.allocator);
    }

    if (results.items.len == 0) {
        return types.CommandResult{
            .success = false,
            .exit_code = 1,
            .message = try std.fmt.allocPrint(ctx.allocator, "no packages found matching '{s}'", .{term}),
        };
    }

    for (results.items) |r| {
        var release_buf: [32]u8 = undefined;
        const release_text = std.fmt.bufPrint(&release_buf, "{d}", .{r.release}) catch continue;
        if (r.is_local) {
            const segments = [_]ui.Segment{
                .{ .text = r.repo_name, .kind = .label },
                .{ .text = " ", .kind = .normal },
                .{ .text = "[local]", .kind = .label },
                .{ .text = " / ", .kind = .normal },
                .{ .text = r.name, .kind = .detail },
                .{ .text = " ", .kind = .normal },
                .{ .text = r.version, .kind = .detail },
                .{ .text = "-", .kind = .normal },
                .{ .text = release_text, .kind = .detail },
                .{ .text = " (", .kind = .normal },
                .{ .text = r.arch, .kind = .detail },
                .{ .text = ")", .kind = .normal },
            };
            emit.logSegmentsSeverity(ctx, .search, .info, &segments);
        } else {
            const segments = [_]ui.Segment{
                .{ .text = r.repo_name, .kind = .label },
                .{ .text = " / ", .kind = .normal },
                .{ .text = r.name, .kind = .detail },
                .{ .text = " ", .kind = .normal },
                .{ .text = r.version, .kind = .detail },
                .{ .text = "-", .kind = .normal },
                .{ .text = release_text, .kind = .detail },
                .{ .text = " (", .kind = .normal },
                .{ .text = r.arch, .kind = .detail },
                .{ .text = ")", .kind = .normal },
            };
            emit.logSegmentsSeverity(ctx, .search, .info, &segments);
        }
    }

    return types.CommandResult{ .success = true, .exit_code = 0 };
}

pub fn createCommand(allocator: std.mem.Allocator) !*command.Command {
    const cmd = try allocator.create(command.Command);
    cmd.* = command.Command.init(allocator, search_meta, handleSearch);
    return cmd;
}
