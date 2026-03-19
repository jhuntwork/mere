const std = @import("std");
const mere = @import("mere.zig");
const Context = mere.Context;
const path = @import("path.zig");
const hash_mod = @import("hash.zig");
const errors = @import("errors.zig");
const ui = mere.ui;
const emit = mere.ui.emit;
const c = @cImport({
    @cInclude("curl/curl.h");
});

const default_timeout: u32 = 30;
const max_parallel_downloads: usize = 3;

fn monotonicMillis() i64 {
    const now = std.Io.Clock.awake.now(path.currentIo());
    return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
}

/// Download operations error set
///
/// Standard Errors:
/// - OutOfMemory: Memory allocation failed during download operations
/// - FileSystem: File operations failed (writing downloaded content, cache access, etc.)
/// - PermissionDenied: Insufficient permissions for file operations
/// - InvalidInput: Invalid URL or download configuration
///
/// Download-Specific Errors:
/// - ConnectionTimeout: Network connection timed out during download
/// - SignatureVerificationFailed: Downloaded content signature verification failed
const Std = errors.StandardErrors;
pub const DownloadError = Std.OutOfMemory || Std.FileSystem || Std.PermissionDenied || Std.InvalidInput || Std.Network || error{
    ConnectionTimeout,
    SignatureVerificationFailed,
};

pub const TransferClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        download_file: *const fn (
            ptr: *anyopaque,
            ctx: *Context,
            url: [:0]const u8,
            dest_path: []const u8,
            options: DownloadOptions,
            download_id: u64,
            subject: ui.Subject,
        ) anyerror!u64,
    };

    pub fn downloadFile(
        self: TransferClient,
        ctx: *Context,
        url: [:0]const u8,
        dest_path: []const u8,
        options: DownloadOptions,
        download_id: u64,
        subject: ui.Subject,
    ) !u64 {
        return try self.vtable.download_file(self.ptr, ctx, url, dest_path, options, download_id, subject);
    }
};

/// A real client that uses libcurl
/// Errors:
///   - ResourceLimitReached: When memory allocation fails
///   - SystemError: When curl initialization fails
pub const CurlTransferClient = struct {
    ctx: *Context,
    curl: ?*c.CURL,
    error_buffer: [c.CURL_ERROR_SIZE]u8,

    pub fn init(ctx: *Context) !*CurlTransferClient {
        const curl = c.curl_easy_init() orelse {
            return error.FileSystem;
        };

        const http_client = try ctx.allocator.create(CurlTransferClient);
        http_client.* = CurlTransferClient{
            .ctx = ctx,
            .curl = curl,
            .error_buffer = undefined,
        };

        // No pushCleanup in Context; cleanup must be handled manually by the caller.
        return http_client;
    }

    /// Free all resources associated with the client
    /// This is called by MereContext during cleanup
    pub fn cleanupFn(_: *Context, data: *anyopaque) void {
        const self = @as(*CurlTransferClient, @ptrCast(@alignCast(data)));

        if (self.curl) |curl| {
            c.curl_easy_cleanup(curl);
            self.curl = null;
        }
        self.ctx.allocator.destroy(self);
    }

    fn downloadFileFn(
        ptr: *anyopaque,
        ctx: *Context,
        url: [:0]const u8,
        dest_path: []const u8,
        options: DownloadOptions,
        download_id: u64,
        subject: ui.Subject,
    ) anyerror!u64 {
        const self: *CurlTransferClient = @ptrCast(@alignCast(ptr));

        ctx.setDiagnosticContext(url, null);

        var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dest_abs = path.resolveToAbsolutePath(dest_path, &dest_buf) catch |err| {
            return ctx.fail(err, dest_path, "failed to resolve destination path");
        };
        ctx.debug("downloading file from {s} to {s}", .{ url, dest_abs });

        const temp_path = try std.fmt.allocPrint(ctx.allocator, "{s}.part", .{dest_abs});
        defer ctx.allocator.free(temp_path);

        const dest_exists = blk: {
            std.Io.Dir.accessAbsolute(path.currentIo(), dest_abs, .{}) catch |err| {
                ctx.debug("destination file does not exist: {s}", .{@errorName(err)});
                break :blk false;
            };
            break :blk true;
        };

        const temp_exists = blk: {
            std.Io.Dir.accessAbsolute(path.currentIo(), temp_path, .{}) catch |err| {
                ctx.debug("temp file does not exist: {s}", .{@errorName(err)});
                break :blk false;
            };
            break :blk true;
        };

        var expected_bytes: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
        if (options.expected_hash) |expected| {
            _ = std.fmt.hexToBytes(&expected_bytes, expected) catch {
                return ctx.failFmt(
                    error.InvalidInput,
                    url,
                    "invalid expected hash: must be 64 lowercase hex chars (blake3), got length={d}",
                    .{expected.len},
                );
            };
        }

        if (temp_exists and options.expected_hash != null) {
            const actual_hex_alloc = hash_mod.calculateFileHash(ctx.allocator, temp_path) catch |err| {
                return ctx.fail(err, temp_path, "failed to hash partial download file");
            };
            defer ctx.allocator.free(actual_hex_alloc);

            var hash_result: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
            _ = std.fmt.hexToBytes(&hash_result, actual_hex_alloc) catch {
                return ctx.fail(error.SignatureVerificationFailed, temp_path, "failed to parse partial downloaded hash");
            };

            if (std.mem.eql(u8, &hash_result, &expected_bytes)) {
                const final_bytes_total = blk: {
                    const temp_file = std.Io.Dir.openFileAbsolute(path.currentIo(), temp_path, .{}) catch {
                        break :blk 0;
                    };
                    defer temp_file.close(path.currentIo());
                    break :blk (temp_file.stat(path.currentIo()) catch break :blk 0).size;
                };

                ctx.debug("partial download already matches expected hash; skipping network transfer", .{});
                try finalizeTempIntoDestination(ctx, temp_path, dest_abs, dest_exists, options.force);
                return final_bytes_total;
            }
        }

        var can_resume = false;
        var initial_size: u64 = 0;

        if (options.allow_resume and temp_exists) {
            ctx.debug("checking if download can be resumed", .{});
            const temp_file = std.Io.Dir.openFileAbsolute(path.currentIo(), temp_path, .{ .mode = .read_write }) catch {
                return ctx.fail(error.FileSystem, temp_path, "failed to open partial download file");
            };
            const temp_stat = temp_file.stat(path.currentIo()) catch {
                temp_file.close(path.currentIo());
                return ctx.fail(error.FileSystem, temp_path, "failed to get partial download size");
            };
            initial_size = temp_stat.size;
            temp_file.close(path.currentIo());
            can_resume = initial_size > 0;

            if (can_resume) {
                emit.logFmtSeverity(ctx, null, .info, "resuming download from byte position {d}", .{initial_size});
            }
        }

        const file = if (can_resume)
            std.Io.Dir.openFileAbsolute(path.currentIo(), temp_path, .{ .mode = .read_write }) catch {
                return ctx.fail(error.FileSystem, temp_path, "failed to open download file");
            }
        else
            std.Io.Dir.createFileAbsolute(path.currentIo(), temp_path, .{
                .read = true,
                .truncate = true,
            }) catch {
                return ctx.fail(error.FileSystem, temp_path, "failed to create download file");
            };
        defer file.close(path.currentIo());

        if (can_resume) {
            var file_writer = std.Io.File.Writer.initStreaming(file, path.currentIo(), &.{});
            file_writer.seekTo(initial_size) catch {
                return ctx.fail(error.FileSystem, temp_path, "failed to seek partial download file");
            };
        }

        _ = try downloadFileWithCurl(
            self,
            ctx,
            file,
            url,
            options.timeout,
            initial_size,
            download_id,
            subject,
        );
        const final_stat = file.stat(path.currentIo()) catch {
            return ctx.fail(error.FileSystem, temp_path, "failed to determine downloaded size");
        };
        const final_bytes_total = final_stat.size;

        if (options.expected_hash != null) {
            const actual_hex_alloc = hash_mod.calculateFileHash(ctx.allocator, temp_path) catch |err| {
                return ctx.fail(err, temp_path, "failed to hash downloaded file");
            };
            defer ctx.allocator.free(actual_hex_alloc);

            var hash_result: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
            _ = std.fmt.hexToBytes(&hash_result, actual_hex_alloc) catch {
                return ctx.fail(error.SignatureVerificationFailed, temp_path, "failed to parse downloaded hash");
            };
            if (!std.mem.eql(u8, &hash_result, &expected_bytes)) {
                const actual_hex = std.fmt.bytesToHex(hash_result, .lower);
                const expected_hex = options.expected_hash.?;

                ctx.setDiagnosticContextFmt(
                    url,
                    "blake3 mismatch; expected={s} actual={s}",
                    .{ expected_hex, actual_hex },
                );

                return error.SignatureVerificationFailed;
            }
        }

        ctx.debug("finalizing download", .{});
        try finalizeTempIntoDestination(ctx, temp_path, dest_abs, dest_exists, options.force);
        ctx.debug("download completed successfully", .{});
        return final_bytes_total;
    }

    pub fn client(self: *CurlTransferClient) TransferClient {
        return .{
            .ptr = self,
            .vtable = &.{
                .download_file = downloadFileFn,
            },
        };
    }
};

/// Options for configuring a download operation
pub const DownloadOptions = struct {
    /// Stall timeout in seconds (used for connect timeout and low-speed timeout).
    /// This is NOT a wall-clock limit for the full transfer.
    timeout: u32 = default_timeout,
    expected_hash: ?[]const u8 = null,
    force: bool = false,
    allow_resume: bool = true,
};

pub const BatchDownloadRequest = struct {
    url: [:0]const u8,
    dest_path: []const u8,
    options: DownloadOptions = .{},
};

const CurlDownloadSession = struct {
    file: std.Io.File,
    ctx: *Context,
    download_id: u64,
    subject: ui.Subject,
    initial_size: u64,
    last_emit_ms: i64 = 0,
    last_emit_current: u64 = 0,
    saw_progress: bool = false,
};

fn curlWriteToFileCallback(ptr: [*]u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const real_size = size * nmemb;
    const session: *CurlDownloadSession = @ptrCast(@alignCast(userdata));
    session.file.writeStreamingAll(path.currentIo(), ptr[0..real_size]) catch return 0;
    return real_size;
}

fn curlXferInfoCallback(
    userdata: *anyopaque,
    dltotal: c.curl_off_t,
    dlnow: c.curl_off_t,
    _: c.curl_off_t,
    _: c.curl_off_t,
) callconv(.c) c_int {
    const session: *CurlDownloadSession = @ptrCast(@alignCast(userdata));
    const total_now: ?u64 = if (dltotal > 0) session.initial_size + @as(u64, @intCast(dltotal)) else null;
    const current_now: u64 = session.initial_size + (if (dlnow > 0) @as(u64, @intCast(dlnow)) else 0);
    const now_ms = monotonicMillis();

    // Emit at most ~20fps unless this is a meaningful byte advance.
    if (now_ms - session.last_emit_ms < 50 and current_now <= session.last_emit_current + 64 * 1024) {
        return 0;
    }

    session.last_emit_ms = now_ms;
    session.last_emit_current = current_now;
    session.saw_progress = true;

    emit.downloadProgress(session.ctx, session.download_id, session.subject, current_now, total_now);
    return 0;
}

fn downloadFileWithCurl(
    client: *CurlTransferClient,
    ctx: *Context,
    file: std.Io.File,
    url: [:0]const u8,
    timeout: u32,
    initial_size: u64,
    download_id: u64,
    subject: ui.Subject,
) !?u64 {
    if (client.curl == null) {
        return ctx.fail(error.FileSystem, url, "curl client not initialized");
    }

    var session = CurlDownloadSession{
        .file = file,
        .ctx = ctx,
        .download_id = download_id,
        .subject = subject,
        .initial_size = initial_size,
    };

    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_WRITEFUNCTION, curlWriteToFileCallback);
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_WRITEDATA, &session);
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_ERRORBUFFER, &client.error_buffer);
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_MAXREDIRS, @as(c_long, 10));
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, @intCast(timeout)));
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, 1));
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_LOW_SPEED_TIME, @as(c_long, @intCast(timeout)));
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_XFERINFOFUNCTION, curlXferInfoCallback);
    _ = c.curl_easy_setopt(client.curl, c.CURLOPT_XFERINFODATA, &session);

    if (initial_size > 0) {
        _ = c.curl_easy_setopt(client.curl, c.CURLOPT_RESUME_FROM_LARGE, @as(c.curl_off_t, @intCast(initial_size)));
    } else {
        _ = c.curl_easy_setopt(client.curl, c.CURLOPT_RESUME_FROM_LARGE, @as(c.curl_off_t, 0));
    }

    const res = c.curl_easy_perform(client.curl);
    if (res != c.CURLE_OK) {
        if (res == c.CURLE_OPERATION_TIMEDOUT) {
            return ctx.fail(error.ConnectionTimeout, url, "connection timeout or stalled transfer");
        }
        const error_msg = blk: {
            const buf_msg = std.mem.sliceTo(&client.error_buffer, 0);
            if (buf_msg.len > 0) break :blk buf_msg;
            const c_str = c.curl_easy_strerror(res);
            break :blk std.mem.sliceTo(c_str, 0);
        };
        return ctx.fail(error.Network, url, error_msg);
    }

    var status_code: c_long = 0;
    _ = c.curl_easy_getinfo(client.curl, c.CURLINFO_RESPONSE_CODE, &status_code);
    if (!(status_code == 200 or (std.mem.startsWith(u8, url, "file://") and status_code == 0) or status_code == 206 or (status_code == 416 and initial_size > 0))) {
        return ctx.failFmt(error.Network, url, "HTTP {d}", .{status_code});
    }

    var cl_download: c.curl_off_t = -1;
    _ = c.curl_easy_getinfo(client.curl, c.CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &cl_download);
    const total: ?u64 = if (cl_download > 0) initial_size + @as(u64, @intCast(cl_download)) else null;
    return total;
}

const MultiDownloadSession = struct {
    ctx: *Context,
    download_id: u64,
    subject: ui.Subject,
    file: std.Io.File,
    temp_path: []u8,
    dest_abs: []u8,
    dest_exists: bool,
    initial_size: u64,
    expected_hash: ?[]const u8,
    expected_bytes: [std.crypto.hash.Blake3.digest_length]u8 = undefined,
    force: bool,
    error_buffer: [c.CURL_ERROR_SIZE]u8 = undefined,
    easy: ?*c.CURL = null,
    file_open: bool = true,
    last_emit_ms: i64 = 0,
    last_emit_current: u64 = 0,
    final_bytes_total: u64 = 0,
};

fn finalizeTempIntoDestination(ctx: *Context, temp_path: []const u8, dest_abs: []const u8, dest_exists: bool, force: bool) !void {
    if (!dest_exists) {
        std.Io.Dir.renameAbsolute(temp_path, dest_abs, path.currentIo()) catch {
            return ctx.fail(error.FileSystem, dest_abs, "failed to move download into destination");
        };
    } else if (force) {
        std.Io.Dir.deleteFileAbsolute(path.currentIo(), dest_abs) catch {
            return ctx.fail(error.FileSystem, dest_abs, "failed to remove existing destination file");
        };
        std.Io.Dir.renameAbsolute(temp_path, dest_abs, path.currentIo()) catch {
            return ctx.fail(error.FileSystem, dest_abs, "failed to replace destination file");
        };
    }
}

fn multiWriteToFileCallback(ptr: [*]u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.c) usize {
    const real_size = size * nmemb;
    const session: *MultiDownloadSession = @ptrCast(@alignCast(userdata));
    session.file.writeStreamingAll(path.currentIo(), ptr[0..real_size]) catch return 0;
    return real_size;
}

fn multiXferInfoCallback(
    userdata: *anyopaque,
    dltotal: c.curl_off_t,
    dlnow: c.curl_off_t,
    _: c.curl_off_t,
    _: c.curl_off_t,
) callconv(.c) c_int {
    const session: *MultiDownloadSession = @ptrCast(@alignCast(userdata));
    const total_now: ?u64 = if (dltotal > 0) session.initial_size + @as(u64, @intCast(dltotal)) else null;
    const current_now: u64 = session.initial_size + (if (dlnow > 0) @as(u64, @intCast(dlnow)) else 0);
    const now_ms = monotonicMillis();

    if (now_ms - session.last_emit_ms < 50 and current_now <= session.last_emit_current + 64 * 1024) {
        return 0;
    }

    session.last_emit_ms = now_ms;
    session.last_emit_current = current_now;
    emit.downloadProgress(session.ctx, session.download_id, session.subject, current_now, total_now);
    return 0;
}

fn findSessionByEasy(sessions: []MultiDownloadSession, easy: *c.CURL) ?*MultiDownloadSession {
    for (sessions) |*session| {
        if (session.easy == easy) return session;
    }
    return null;
}

pub fn downloadBatch(
    client: TransferClient,
    ctx: *Context,
    requests: []const BatchDownloadRequest,
) !void {
    if (requests.len == 0) return;
    if (requests.len == 1 or client.vtable.download_file != CurlTransferClient.downloadFileFn) {
        for (requests) |req| {
            try downloadFile(client, ctx, req.url, req.dest_path, req.options);
        }
        return;
    }

    const curl_multi = c.curl_multi_init() orelse {
        return ctx.fail(error.FileSystem, "curl_multi_init", "failed to initialize curl multi handle");
    };
    defer _ = c.curl_multi_cleanup(curl_multi);

    var sessions = try ctx.allocator.alloc(MultiDownloadSession, requests.len);
    defer ctx.allocator.free(sessions);
    var session_count: usize = 0;

    defer {
        for (sessions[0..session_count]) |*session| {
            if (session.easy) |easy| {
                _ = c.curl_multi_remove_handle(curl_multi, easy);
                c.curl_easy_cleanup(easy);
                session.easy = null;
            }
            if (session.file_open) {
                session.file.close(path.currentIo());
                session.file_open = false;
            }
            ctx.allocator.free(session.temp_path);
            ctx.allocator.free(session.dest_abs);
        }
    }

    for (requests) |req| {
        if (!path.isValidInputPath(req.dest_path)) {
            return ctx.fail(error.InvalidInput, req.dest_path, "invalid destination path");
        }
        if (!isValidUrl(req.url)) {
            return ctx.fail(error.InvalidInput, req.url, "invalid url");
        }

        var dest_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dest_abs_resolved = path.resolveToAbsolutePath(req.dest_path, &dest_buf) catch |err| {
            return ctx.fail(err, req.dest_path, "failed to resolve destination path");
        };
        const dest_abs = try ctx.allocator.dupe(u8, dest_abs_resolved);
        errdefer ctx.allocator.free(dest_abs);

        const temp_path = try std.fmt.allocPrint(ctx.allocator, "{s}.part", .{dest_abs});
        errdefer ctx.allocator.free(temp_path);

        const subject = ui.Subject{ .url = std.mem.sliceTo(req.url, 0), .path = dest_abs };
        const download_id = ctx.nextEventId();
        emit.downloadQueued(ctx, download_id, subject);
        errdefer emit.downloadError(ctx, download_id, subject);

        const dest_exists = blk: {
            std.Io.Dir.accessAbsolute(path.currentIo(), dest_abs, .{}) catch break :blk false;
            break :blk true;
        };
        const temp_exists = blk: {
            std.Io.Dir.accessAbsolute(path.currentIo(), temp_path, .{}) catch break :blk false;
            break :blk true;
        };

        var expected_bytes: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
        if (req.options.expected_hash) |expected| {
            _ = std.fmt.hexToBytes(&expected_bytes, expected) catch {
                return ctx.failFmt(
                    error.InvalidInput,
                    req.url,
                    "invalid expected hash: must be 64 lowercase hex chars (blake3), got length={d}",
                    .{expected.len},
                );
            };
        }

        if (temp_exists and req.options.expected_hash != null) {
            const actual_hex_alloc = hash_mod.calculateFileHash(ctx.allocator, temp_path) catch |err| {
                return ctx.fail(err, temp_path, "failed to hash partial download file");
            };
            defer ctx.allocator.free(actual_hex_alloc);

            var hash_result: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
            _ = std.fmt.hexToBytes(&hash_result, actual_hex_alloc) catch {
                return ctx.fail(error.SignatureVerificationFailed, temp_path, "failed to parse partial downloaded hash");
            };

            if (std.mem.eql(u8, &hash_result, &expected_bytes)) {
                const final_bytes_total = blk: {
                    const temp_file = std.Io.Dir.openFileAbsolute(path.currentIo(), temp_path, .{}) catch break :blk 0;
                    defer temp_file.close(path.currentIo());
                    break :blk (temp_file.stat(path.currentIo()) catch break :blk 0).size;
                };
                try finalizeTempIntoDestination(ctx, temp_path, dest_abs, dest_exists, req.options.force);
                emit.downloadComplete(ctx, download_id, subject, final_bytes_total);
                ctx.allocator.free(temp_path);
                ctx.allocator.free(dest_abs);
                continue;
            }
        }

        var can_resume = false;
        var initial_size: u64 = 0;
        if (req.options.allow_resume and temp_exists) {
            const temp_file = std.Io.Dir.openFileAbsolute(path.currentIo(), temp_path, .{ .mode = .read_write }) catch {
                return ctx.fail(error.FileSystem, temp_path, "failed to open partial download file");
            };
            const temp_stat = temp_file.stat(path.currentIo()) catch {
                temp_file.close(path.currentIo());
                return ctx.fail(error.FileSystem, temp_path, "failed to get partial download size");
            };
            initial_size = temp_stat.size;
            temp_file.close(path.currentIo());
            can_resume = initial_size > 0;
        }

        const file = if (can_resume)
            std.Io.Dir.openFileAbsolute(path.currentIo(), temp_path, .{ .mode = .read_write }) catch {
                return ctx.fail(error.FileSystem, temp_path, "failed to open download file");
            }
        else
            std.Io.Dir.createFileAbsolute(path.currentIo(), temp_path, .{ .read = true, .truncate = true }) catch {
                return ctx.fail(error.FileSystem, temp_path, "failed to create download file");
            };
        errdefer file.close(path.currentIo());
        if (can_resume) {
            var file_writer = std.Io.File.Writer.initStreaming(file, path.currentIo(), &.{});
            file_writer.seekTo(initial_size) catch {
                return ctx.fail(error.FileSystem, temp_path, "failed to seek partial download file");
            };
        }

        const easy = c.curl_easy_init() orelse {
            return ctx.fail(error.FileSystem, req.url, "failed to initialize curl easy handle");
        };
        errdefer c.curl_easy_cleanup(easy);

        sessions[session_count] = .{
            .ctx = ctx,
            .download_id = download_id,
            .subject = subject,
            .file = file,
            .temp_path = temp_path,
            .dest_abs = dest_abs,
            .dest_exists = dest_exists,
            .initial_size = initial_size,
            .expected_hash = req.options.expected_hash,
            .force = req.options.force,
            .easy = easy,
        };
        if (req.options.expected_hash != null) {
            sessions[session_count].expected_bytes = expected_bytes;
        }

        const session = &sessions[session_count];
        _ = c.curl_easy_setopt(easy, c.CURLOPT_URL, req.url.ptr);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, multiWriteToFileCallback);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, session);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_ERRORBUFFER, &session.error_buffer);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, 10));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, @intCast(req.options.timeout)));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, 1));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_LOW_SPEED_TIME, @as(c_long, @intCast(req.options.timeout)));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFOFUNCTION, multiXferInfoCallback);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFODATA, session);
        if (initial_size > 0) {
            _ = c.curl_easy_setopt(easy, c.CURLOPT_RESUME_FROM_LARGE, @as(c.curl_off_t, @intCast(initial_size)));
        } else {
            _ = c.curl_easy_setopt(easy, c.CURLOPT_RESUME_FROM_LARGE, @as(c.curl_off_t, 0));
        }
        session_count += 1;
    }

    if (session_count == 0) return;

    var next_to_start: usize = 0;
    var active: usize = 0;
    while (active < max_parallel_downloads and next_to_start < session_count) {
        const session = &sessions[next_to_start];
        const easy = session.easy orelse {
            return ctx.fail(error.FileSystem, "curl", "missing easy handle for pending transfer");
        };
        if (c.curl_multi_add_handle(curl_multi, easy) != c.CURLM_OK) {
            return ctx.fail(error.FileSystem, session.subject.url orelse "download", "failed to add curl handle to multi session");
        }
        next_to_start += 1;
        active += 1;
    }

    var running: c_int = 0;
    _ = c.curl_multi_perform(curl_multi, &running);
    var finished: usize = 0;
    var first_error: ?anyerror = null;
    var failed_labels: std.ArrayList([]u8) = .empty;
    var failed_details: std.ArrayList([]u8) = .empty;
    defer {
        for (failed_labels.items) |label| ctx.allocator.free(label);
        failed_labels.deinit(ctx.allocator);
        for (failed_details.items) |detail| ctx.allocator.free(detail);
        failed_details.deinit(ctx.allocator);
    }
    while (finished < session_count) {
        _ = c.curl_multi_wait(curl_multi, null, 0, 1000, null);
        _ = c.curl_multi_perform(curl_multi, &running);

        while (true) {
            var msgs_left: c_int = 0;
            const msg = c.curl_multi_info_read(curl_multi, &msgs_left) orelse break;
            if (msg.*.msg != c.CURLMSG_DONE) continue;

            const easy = msg.*.easy_handle orelse {
                return ctx.fail(error.FileSystem, "curl", "completed transfer missing easy handle");
            };
            const session = findSessionByEasy(sessions[0..session_count], easy) orelse {
                return ctx.fail(error.FileSystem, "curl", "unknown completed curl handle");
            };
            const session_url = session.subject.url orelse "download";
            var session_failed = false;
            var fail_reason: []const u8 = "transfer error";
            var mismatch_expected: ?[]const u8 = null;
            var mismatch_actual: [std.crypto.hash.Blake3.digest_length * 2]u8 = undefined;
            var mismatch_actual_set = false;

            if (session.file_open) {
                session.file.close(path.currentIo());
                session.file_open = false;
            }

            if (msg.*.data.result != c.CURLE_OK) {
                if (msg.*.data.result == c.CURLE_OPERATION_TIMEDOUT) {
                    if (first_error == null) {
                        ctx.setDiagnosticContext(session_url, "connection timeout or stalled transfer");
                        first_error = error.ConnectionTimeout;
                    }
                    fail_reason = "timeout";
                    session_failed = true;
                } else {
                    const error_msg = blk: {
                        const buf_msg = std.mem.sliceTo(&session.error_buffer, 0);
                        if (buf_msg.len > 0) break :blk buf_msg;
                        break :blk std.mem.sliceTo(c.curl_easy_strerror(msg.*.data.result), 0);
                    };
                    if (first_error == null) {
                        ctx.setDiagnosticContext(session_url, error_msg);
                        first_error = error.Network;
                    }
                    fail_reason = "network error";
                    session_failed = true;
                }
            }

            if (!session_failed) {
                var status_code: c_long = 0;
                _ = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status_code);
                if (!(status_code == 200 or status_code == 206 or (std.mem.startsWith(u8, session_url, "file://") and status_code == 0) or (status_code == 416 and session.initial_size > 0))) {
                    if (first_error == null) {
                        ctx.setDiagnosticContextFmt(session_url, "HTTP {d}", .{status_code});
                        first_error = error.Network;
                    }
                    fail_reason = "http error";
                    session_failed = true;
                }
            }

            _ = c.curl_multi_remove_handle(curl_multi, easy);
            c.curl_easy_cleanup(easy);
            session.easy = null;
            if (active > 0) active -= 1;

            if (!session_failed) {
                session.final_bytes_total = blk: {
                    const temp_file = std.Io.Dir.openFileAbsolute(path.currentIo(), session.temp_path, .{}) catch break :blk 0;
                    defer temp_file.close(path.currentIo());
                    break :blk (temp_file.stat(path.currentIo()) catch break :blk 0).size;
                };

                if (session.expected_hash != null) {
                    var actual_hex_alloc_opt: ?[]const u8 = null;
                    actual_hex_alloc_opt = hash_mod.calculateFileHash(ctx.allocator, session.temp_path) catch blk: {
                        if (first_error == null) {
                            ctx.setDiagnosticContext(session.temp_path, "failed to hash downloaded file");
                            first_error = error.FileSystem;
                        }
                        session_failed = true;
                        break :blk null;
                    };
                    if (actual_hex_alloc_opt) |actual_hex_alloc| {
                        defer ctx.allocator.free(actual_hex_alloc);

                        var hash_result: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
                        if (std.fmt.hexToBytes(&hash_result, actual_hex_alloc)) |_| {
                            if (!std.mem.eql(u8, &hash_result, &session.expected_bytes)) {
                                const actual_hex = std.fmt.bytesToHex(hash_result, .lower);
                                const expected_hex = session.expected_hash.?;
                                if (first_error == null) {
                                    ctx.setDiagnosticContextFmt(
                                        session_url,
                                        "blake3 mismatch; expected={s} actual={s}",
                                        .{ expected_hex, actual_hex },
                                    );
                                    first_error = error.SignatureVerificationFailed;
                                }
                                fail_reason = "hash mismatch";
                                mismatch_expected = expected_hex;
                                mismatch_actual = actual_hex;
                                mismatch_actual_set = true;
                                session_failed = true;
                            }
                        } else |_| {
                            if (first_error == null) {
                                ctx.setDiagnosticContext(session.temp_path, "failed to parse downloaded hash");
                                first_error = error.SignatureVerificationFailed;
                            }
                            fail_reason = "hash parse error";
                            session_failed = true;
                        }
                    }
                }
            }

            if (!session_failed) {
                finalizeTempIntoDestination(ctx, session.temp_path, session.dest_abs, session.dest_exists, session.force) catch {
                    if (first_error == null) {
                        ctx.setDiagnosticContext(session.dest_abs, "failed to move download into destination");
                        first_error = error.FileSystem;
                    }
                    fail_reason = "finalize error";
                    session_failed = true;
                };
            }

            if (session_failed) {
                const base = std.fs.path.basename(session.dest_abs);
                const owned = std.fmt.allocPrint(ctx.allocator, "{s} ({s})", .{ base, fail_reason }) catch null;
                if (owned) |label| {
                    failed_labels.append(ctx.allocator, label) catch {
                        ctx.allocator.free(label);
                    };
                }
                const detail = if (std.mem.eql(u8, fail_reason, "hash mismatch") and mismatch_expected != null and mismatch_actual_set)
                    std.fmt.allocPrint(ctx.allocator, "{s}: blake3 mismatch; expected={s} actual={s}", .{ base, mismatch_expected.?, &mismatch_actual }) catch null
                else
                    std.fmt.allocPrint(ctx.allocator, "{s}: {s}", .{ base, fail_reason }) catch null;
                if (detail) |line| {
                    failed_details.append(ctx.allocator, line) catch {
                        ctx.allocator.free(line);
                    };
                }
                emit.downloadError(ctx, session.download_id, session.subject);
            } else {
                emit.downloadComplete(ctx, session.download_id, session.subject, session.final_bytes_total);
            }
            finished += 1;
        }

        while (active < max_parallel_downloads and next_to_start < session_count) {
            const session = &sessions[next_to_start];
            const easy = session.easy orelse {
                return ctx.fail(error.FileSystem, "curl", "missing easy handle for pending transfer");
            };
            if (c.curl_multi_add_handle(curl_multi, easy) != c.CURLM_OK) {
                return ctx.fail(error.FileSystem, session.subject.url orelse "download", "failed to add curl handle to multi session");
            }
            next_to_start += 1;
            active += 1;
        }
    }

    if (failed_details.items.len > 0) {
        var diag: std.ArrayList(u8) = .empty;
        defer diag.deinit(ctx.allocator);
        for (failed_details.items, 0..) |line, i| {
            if (i > 0) try diag.appendSlice(ctx.allocator, "; ");
            try diag.appendSlice(ctx.allocator, line);
        }
        const current_diag = ctx.getDiagnosticContext();
        const subject = current_diag.subject orelse "download batch";
        ctx.setDiagnosticContext(subject, diag.items);
    }

    if (failed_labels.items.len > 0) {
        var summary: std.ArrayList(u8) = .empty;
        defer summary.deinit(ctx.allocator);
        var out_buf: std.Io.Writer.Allocating = .fromArrayList(ctx.allocator, &summary);
        const out = &out_buf.writer;

        const shown = @min(failed_labels.items.len, 5);
        out.print("download failures ({d}): ", .{failed_labels.items.len}) catch return error.OutOfMemory;
        var i: usize = 0;
        while (i < shown) : (i += 1) {
            if (i > 0) out.writeAll(", ") catch return error.OutOfMemory;
            out.writeAll(failed_labels.items[i]) catch return error.OutOfMemory;
        }
        if (failed_labels.items.len > shown) {
            out.print(", +{d} more", .{failed_labels.items.len - shown}) catch return error.OutOfMemory;
        }
        summary = out_buf.toArrayList();
        ctx.debug("{s}", .{summary.items});
    }

    if (first_error) |err| return err;
}

/// Download a file from a URL to a local path
/// Errors:
///   - InvalidConfig: When destination path is invalid
///   - InvalidArgument: When URL is invalid
///   - FileNotFound: When file cannot be created or accessed
///   - FileAccessDenied: When destination cannot be written
///   - SystemError: When download operation fails
///   - ConnectionTimeout: When the connection times out
///   - SignatureVerificationFailed: When hash verification fails
pub fn downloadFile(
    client: TransferClient,
    ctx: *Context,
    url: [:0]const u8,
    dest_path: []const u8,
    options: DownloadOptions,
) anyerror!void {
    if (!path.isValidInputPath(dest_path)) {
        return ctx.fail(error.InvalidInput, dest_path, "invalid destination path");
    }

    if (!isValidUrl(url)) {
        return ctx.fail(error.InvalidInput, url, "invalid url");
    }

    ctx.setDiagnosticContext(url, null);
    const url_slice = std.mem.sliceTo(url, 0);
    const download_id = ctx.nextEventId();
    const subject = ui.Subject{ .url = url_slice, .path = dest_path };
    emit.downloadQueued(ctx, download_id, subject);
    errdefer emit.downloadError(ctx, download_id, subject);
    const final_bytes_total = try client.downloadFile(ctx, url, dest_path, options, download_id, subject);
    emit.downloadComplete(ctx, download_id, subject, final_bytes_total);
}
pub fn isValidUrl(url: []const u8) bool {
    // Empty URLs are invalid
    if (url.len == 0) return false;

    // Allocate a null-terminated copy of the URL for libcurl using the C allocator
    const url_z = std.mem.concatWithSentinel(std.heap.c_allocator, u8, &.{url}, 0) catch return false;
    defer std.heap.c_allocator.free(url_z);

    // Use libcurl's URL API for proper URL validation
    const curl_url = c.curl_url() orelse return false;
    defer c.curl_url_cleanup(curl_url);

    // Try to parse the URL - this will validate the URL format
    // CURLU_NON_SUPPORT_SCHEME allows URLs with schemes that curl doesn't support for transfers
    const result = c.curl_url_set(curl_url, c.CURLUPART_URL, url_z, c.CURLU_NON_SUPPORT_SCHEME);

    // CURLUE_OK (0) means the URL was successfully parsed
    return result == c.CURLUE_OK;
}

test "downloadFile returns error for empty destination path" {
    var ctx = Context.init(std.testing.allocator, null);
    defer ctx.deinit();
    const dummy_client = TransferClient{
        .ptr = undefined,
        .vtable = undefined,
    };
    const opts = DownloadOptions{};
    try std.testing.expectError(error.InvalidInput, downloadFile(dummy_client, &ctx, "http://example.com/file", "", opts));
}

test "downloadFile returns error for destination path with null byte" {
    var ctx = Context.init(std.testing.allocator, null);
    defer ctx.deinit();
    const dummy_client = TransferClient{
        .ptr = undefined,
        .vtable = undefined,
    };
    const opts = DownloadOptions{};
    const bad_path = "\x00";
    try std.testing.expectError(error.InvalidInput, downloadFile(dummy_client, &ctx, "http://example.com/file", bad_path, opts));
}

test "downloadFile emits download events" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    const TestCounts = struct {
        queued: usize = 0,
        progress: usize = 0,
        complete: usize = 0,
        err: usize = 0,
    };
    const TestEmitter = struct {
        emitter: ui.Emitter,
        counts: *TestCounts,

        fn init(counts: *TestCounts) @This() {
            var self = @This(){
                .emitter = undefined,
                .counts = counts,
            };
            self.emitter = .{ .emitFn = onEmit };
            return self;
        }

        fn onEmit(emitter: *ui.Emitter, event: ui.Event) void {
            const self: *@This() = @fieldParentPtr("emitter", emitter);
            switch (event.kind) {
                .download_queued => self.counts.queued += 1,
                .download_progress => self.counts.progress += 1,
                .download_complete => self.counts.complete += 1,
                .download_error => self.counts.err += 1,
                else => {},
            }
        }
    };

    var counts = TestCounts{};
    var test_emitter = TestEmitter.init(&counts);
    ctx.setEmitter(&test_emitter.emitter);

    var client = th.DummyClient.init(ctx.allocator);
    defer client.deinit();
    try client.set("http://example.com/file", "hello world");

    const transfer = TransferClient{
        .ptr = &client,
        .vtable = &.{ .download_file = th.dummy_download_file },
    };

    const dest_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "download.txt" });
    defer ctx.allocator.free(dest_path);

    try downloadFile(transfer, ctx, "http://example.com/file", dest_path, DownloadOptions{});

    try std.testing.expectEqual(@as(usize, 1), counts.queued);
    try std.testing.expectEqual(@as(usize, 0), counts.progress);
    try std.testing.expectEqual(@as(usize, 1), counts.complete);
    try std.testing.expectEqual(@as(usize, 0), counts.err);
}

test "downloadFile does not append duplicate bytes when partial file exists for remote URL" {
    const th = @import("test_helpers.zig");
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }

    const ctx = &test_env.ctx;

    var client = th.DummyClient.init(ctx.allocator);
    defer client.deinit();
    try client.set("http://example.com/file", "abcdef");

    const transfer = TransferClient{
        .ptr = &client,
        .vtable = &.{ .download_file = th.dummy_download_file },
    };

    const dest_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, "resume-remote.txt" });
    defer ctx.allocator.free(dest_path);
    const part_path = try std.fmt.allocPrint(ctx.allocator, "{s}.part", .{dest_path});
    defer ctx.allocator.free(part_path);

    {
        const f = try path.makePathAndOpenFile(part_path);
        defer f.close(path.currentIo());
        try f.writeStreamingAll(path.currentIo(), "abc");
    }

    try downloadFile(transfer, ctx, "http://example.com/file", dest_path, DownloadOptions{ .allow_resume = true });

    const content = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), path.currentIo(), dest_path, ctx.allocator, .limited(1024));
    defer ctx.allocator.free(content);
    try std.testing.expectEqualStrings("abcdef", content);
}

test "downloadFile hash verification success and failure" {
    const testing = std.testing;
    const helpers = @import("test_helpers.zig");

    // Use the test_helpers createTestEnv for consistency
    var test_env = try helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    var dummy = helpers.DummyClient.init(ctx.allocator);
    defer dummy.deinit();
    try dummy.set("http://example.com/file", "hello world");
    var vtable = TransferClient.VTable{ .download_file = helpers.dummy_download_file };
    const client = TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    // Compute the correct hash for "hello world"
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("hello world");
    var hash_result: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    hasher.final(hash_result[0..]);
    var hash_hex: [std.crypto.hash.Blake3.digest_length * 2]u8 = undefined;
    hash_hex = std.fmt.bytesToHex(hash_result[0..], .lower);

    // Create a temp file path using the test env's temp dir and path
    const rel_name = "test_download_hash.txt";
    // Touch the file in the temp dir to ensure the parent directory exists and permissions are correct
    // Touch the file and close it immediately to avoid unused value error
    {
        const file = try test_env.tmp.dir.createFile(path.currentIo(), rel_name, .{});
        file.close(path.currentIo());
    }
    const dest_path = try std.fs.path.join(std.testing.allocator, &.{ test_env.path, rel_name });
    defer std.testing.allocator.free(dest_path);

    // Ensure parent directory exists using makePathAndOpenDir
    const pathmod = @import("path.zig");
    const parent_dir = std.fs.path.dirname(dest_path) orelse ".";
    var dir = try pathmod.makePathAndOpenDir(parent_dir);
    defer dir.close(path.currentIo());

    // Success case: correct hash
    const opts = DownloadOptions{
        .expected_hash = hash_hex[0..],
        .force = true,
    };
    try downloadFile(client, ctx, "http://example.com/file", dest_path, opts);

    // Failure case: wrong hash
    var bad_hash = hash_hex;
    bad_hash[0] = if (bad_hash[0] == '0') '1' else '0';
    const opts_bad = DownloadOptions{
        .expected_hash = bad_hash[0..],
        .force = true,
    };
    try testing.expectError(error.SignatureVerificationFailed, downloadFile(client, ctx, "http://example.com/file", dest_path, opts_bad));

    // Clean up the file if it exists
    std.Io.Dir.deleteFileAbsolute(path.currentIo(), dest_path) catch {};
}

test "downloadFile works with file:// scheme using CurlTransferClient" {
    const helpers = @import("test_helpers.zig");
    var test_env = try helpers.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    // Create a source file
    const src_name = "curl_file_src.txt";
    const src_content = "curl file test content";
    const src_file_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, src_name });
    defer ctx.allocator.free(src_file_path);
    {
        const f = try path.makePathAndOpenFile(src_file_path);
        try f.writeStreamingAll(path.currentIo(), src_content);
        f.close(path.currentIo());
    }

    // Prepare destination path
    const dest_name = "curl_file_dest.txt";
    const dest_file_path = try std.fs.path.join(ctx.allocator, &.{ test_env.path, dest_name });
    defer ctx.allocator.free(dest_file_path);

    // Build file:// URL
    const url_buf = try std.fmt.allocPrintSentinel(ctx.allocator, "file://{s}", .{src_file_path}, 0);
    defer ctx.allocator.free(url_buf);

    // Use CurlTransferClient to download
    var curl_client = try CurlTransferClient.init(ctx);
    const client = curl_client.client();
    try downloadFile(client, ctx, url_buf[0.. :0], dest_file_path, DownloadOptions{});

    // Verify destination file contents
    const downloaded = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), path.currentIo(), dest_file_path, ctx.allocator, .limited(1024));
    defer ctx.allocator.free(downloaded);
    try std.testing.expectEqualStrings(src_content, downloaded);

    // Cleanup CurlTransferClient to avoid memory leak
    CurlTransferClient.cleanupFn(ctx, curl_client);
}

test "ensurePackageArchiveCached downloads and caches, then hits cache" {
    const th = @import("test_helpers.zig");
    const RepoCache = @import("repocache.zig").RepoCache;
    const Package = @import("package.zig").Package;
    var test_env = try th.createTestEnv();
    defer {
        test_env.cleanup();
        std.testing.allocator.destroy(test_env);
    }
    const ctx = &test_env.ctx;

    // Dummy HTTP client that returns fixed body
    var dummy = th.DummyClient.init(ctx.allocator);
    defer dummy.deinit();
    const content_hash = "a" ** 64;
    try dummy.set("https://repo.example.com/packages/mypkg-1.2.3-1-x86_64-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pkg.tar.zst", "archive-cached");
    var vtable = TransferClient.VTable{ .download_file = th.dummy_download_file };
    const client = TransferClient{ .ptr = @ptrCast(&dummy), .vtable = &vtable };

    // Prepare a dummy RepoCache for both calls
    var test_repocache = try RepoCache.init(
        ctx,
        "testrepo",
        "https://repo.example.com",
        &.{},
        100,
    );
    defer test_repocache.deinit();

    // First call: should download and cache
    var test_pkg = Package{
        .ctx = ctx,
        .name = "mypkg",
        .version = "1.2.3",
        .release = 1,
        .arch = "x86_64",
        .signature = null,
        .dependencies = undefined,
        .provisions = undefined,
        .content_hash = content_hash,
        .archive_hash = content_hash,
    };
    const cache_path = try th.ensurePackageArchiveCached(
        &test_repocache,
        &test_pkg,
        client,
    );
    defer ctx.allocator.free(cache_path);

    // File should exist and contain the expected bytes
    const cached = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), path.currentIo(), cache_path, ctx.allocator, .limited(1024));
    defer ctx.allocator.free(cached);
    try std.testing.expectEqualStrings("archive-cached", cached);
    // Second call: should hit cache and keep the original cached bytes.
    try dummy.set("https://repo.example.com/packages/mypkg-1.2.3-1-x86_64-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pkg.tar.zst", "should-not-be-used");
    const cache_path2 = try th.ensurePackageArchiveCached(
        &test_repocache,
        &test_pkg,
        client,
    );
    defer ctx.allocator.free(cache_path2);

    // File should still contain the original cached bytes
    const cached2 = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), path.currentIo(), cache_path2, ctx.allocator, .limited(1024));
    defer ctx.allocator.free(cached2);
    try std.testing.expectEqualStrings("archive-cached", cached2);
    // test_repocache cleanup handled by defer test_repocache.deinit() above
}

test "isValidUrl is stable for file:// URLs" {
    const url = "file:///tmp/testfile";
    try std.testing.expect(isValidUrl(url));
    try std.testing.expect(isValidUrl(url));
}
