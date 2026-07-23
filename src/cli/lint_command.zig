const std = @import("std");
const util = @import("util");
const walk = @import("../walk/Walker.zig");
const glob = @import("../walk/glob.zig");
const _lint = @import("../lint.zig");
const reporters = @import("../reporter.zig");
const lint_config = @import("lint_config.zig");

const mem = std.mem;
const path = std.fs.path;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const WalkState = walk.WalkState;
const Error = @import("../Error.zig");

const LintService = _lint.LintService;
const Fix = _lint.Fix;
const Options = @import("../cli/Options.zig");

var buf: [4096]u8 = undefined;

pub fn lint(alloc: Allocator, io: Io, environ: std.process.Environ, options: Options) !u8 {
    // writer cannot live on the stack.
    // this gets moved into Reporter, which runs on a different thread.
    const writer = try alloc.create(Io.File.Writer);
    writer.* = Io.File.stdout().writer(io, &buf);
    defer alloc.destroy(writer);
    var stdout = &writer.interface;
    defer stdout.flush() catch @panic("failed to flush writer");

    // NOTE: everything config related is stored in the same arena. This
    // includes the config source string, the parsed Config object, and
    // (eventually) whatever each rule needs to store. This lets all configs
    // store slices to the config's source, avoiding allocations. Include
    // patterns built from positional arguments live here too.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var reporter = try reporters.Reporter.initKind(options.format, io, environ, &writer.interface, alloc);
    defer reporter.deinit();
    reporter.opts.quiet = options.quiet;
    reporter.opts.report_stats = reporter.opts.report_stats and options.summary;

    var config = resolve_config: {
        var diagnostic: ?Error = null;
        const c = lint_config.resolveLintConfig(&arena, io, Io.Dir.cwd(), "zlint.json", alloc, &diagnostic) catch {
            var reported: [1]Error = .{
                diagnostic orelse Error.newStatic("Failed to load zlint configuration."),
            };
            try reporter.reportErrorSlice(alloc, &reported);
            return 1;
        };
        break :resolve_config c;
    };
    try lint_config.readGitignore(&config, io, Io.Dir.cwd());

    const start = Io.Timestamp.now(io, .real);

    {
        const fix = if (options.fix or options.fix_dangerously) Fix.Meta{
            .kind = .fix,
            .dangerous = options.fix_dangerously,
        } else Fix.Meta.disabled;

        // TODO: use options to specify number of threads (if provided)
        var service = try LintService.init(
            alloc,
            io,
            &reporter,
            config,
            .{ .fix = fix },
        );
        defer service.deinit();

        if (!options.stdin) {
            var invalid_arg: []const u8 = "";
            const include = normalizeIncludes(arena.allocator(), io, options.args.items, &invalid_arg) catch |e| {
                var reported: [1]Error = .{
                    switch (e) {
                        error.PathNotFound => Error.fmt(
                            alloc,
                            "no such file or directory: '{s}'",
                            .{invalid_arg},
                        ),
                        error.PathOutsideCwd => Error.fmt(
                            alloc,
                            "'{s}' is outside of the current working directory",
                            .{invalid_arg},
                        ),
                        else => return e,
                    } catch return error.OutOfMemory,
                };
                try reporter.reportErrorSlice(alloc, &reported);
                return 1;
            };
            var visitor: LintVisitor = .{
                .service = &service,
                .allocator = alloc,
                .include = include,
                .exclude = config.config.ignore,
            };
            var src = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
            defer src.close(io);
            var walker = try LintWalker.init(alloc, io, src, &visitor);
            defer walker.deinit();
            try walker.walk();
        } else {
            // SAFETY: initialized by reader
            var msg_buf: [4096]u8 = undefined;
            var delim_buf: [1024]u8 = undefined;
            var stdin = Io.File.stdin();
            var reader = stdin.readerStreaming(io, &msg_buf);
            while (try readUntilDelimiterOrEof(&reader.interface, &delim_buf, '\n')) |filepath| {
                if (!std.mem.endsWith(u8, filepath, ".zig")) continue;
                const owned = try alloc.dupe(u8, filepath);
                service.lintFileParallel(owned);
            }
        }
    }

    const stop = Io.Timestamp.now(io, .real);
    const duration: i64 = @intCast(@divTrunc(start.durationTo(stop).nanoseconds, std.time.ns_per_ms));
    reporter.printStats(duration);
    if (reporter.stats.numErrorsSync() > 0) {
        return 1;
    } else if (options.deny_warnings and reporter.stats.numWarningsSync() > 0) {
        return 1;
    } else {
        return 0;
    }
}

const LintWalker = walk.Walker(LintVisitor);

const LintVisitor = struct {
    /// borrowed
    service: *LintService,
    allocator: Allocator,
    include: []const glob.Pattern,
    exclude: []const glob.Pattern,

    pub fn visit(self: *LintVisitor, entry: walk.Entry) ?walk.WalkState {
        switch (entry.kind) {
            .directory => {
                if (entry.basename.len == 0 or entry.basename[0] == '.') {
                    return WalkState.Skip;
                } else if (mem.eql(u8, entry.basename, "vendor") or mem.eql(u8, entry.basename, "zig-out")) {
                    return WalkState.Skip;
                }
                for (self.service.config.config.ignore) |ignore| {
                    if (mem.startsWith(u8, entry.path, ignore)) {
                        return WalkState.Skip;
                    }
                }
            },
            .file => {
                if (!mem.eql(u8, path.extension(entry.path), ".zig") or
                    !self.isIncluded(&entry))
                {
                    return WalkState.Continue;
                }

                const filepath = self.allocator.dupe(u8, entry.path) catch {
                    return WalkState.Stop;
                };
                self.service.lintFileParallel(filepath);
            },
            else => {
                // todo: warn
            },
        }
        return WalkState.Continue;
    }

    fn isIncluded(self: *const LintVisitor, entry: *const walk.Entry) bool {
        util.debugAssert(
            entry.kind != .directory,
            "isIncluded should only be passed file-like things, got a dir.",
            .{},
        );

        if (self.include.len > 0) matches_include: {
            for (self.include) |pattern| {
                if (glob.match(pattern, entry.path)) {
                    break :matches_include;
                }
            }
            return false;
        }

        if (self.exclude.len > 0) {
            for (self.exclude) |pattern| {
                if (glob.match(pattern, entry.path)) {
                    return false;
                }
            }
        }

        return true;
    }
};

/// Errors produced when a positional argument is a path that cannot be
/// linted. The offending argument is stored in `invalid_arg`.
pub const NormalizeIncludesError = error{
    /// The path does not exist.
    PathNotFound,
    /// The path is outside of the current working directory. The walker only
    /// covers the cwd, so it could never match anything.
    PathOutsideCwd,
};

/// Turn positional CLI arguments into glob patterns used to filter walked
/// files.
///
/// Arguments containing glob syntax pass through unchanged. Everything else
/// is treated as a filesystem path: directories become `<dir>/**` (so
/// `zlint src` lints everything under `src/`) and files are matched exactly.
/// Paths that do not exist or that leave the cwd are errors, since silently
/// linting 0 files hides mistakes, especially in CI.
///
/// Patterns are allocated in `alloc`, which must outlive the walk (an arena
/// is used in practice).
fn normalizeIncludes(
    alloc: Allocator,
    io: Io,
    args: []const []const u8,
    invalid_arg: ?*[]const u8,
) (NormalizeIncludesError || Io.Dir.StatFileError || Io.Dir.RealPathFileError || Allocator.Error)![]const glob.Pattern {
    if (args.len == 0) return &.{};

    const sep_str = if (comptime util.IS_WINDOWS) "\\" else "/";
    var includes: std.ArrayListUnmanaged(glob.Pattern) = try .initCapacity(alloc, args.len);

    const cwd = Io.Dir.cwd();
    // Canonical absolute path of the cwd, resolved lazily on the first
    // path-like argument.
    var cwd_abs: ?[]const u8 = null;

    for (args) |raw| {
        if (isGlobPattern(raw)) {
            includes.appendAssumeCapacity(raw);
            continue;
        }

        if (cwd_abs == null) cwd_abs = try cwd.realPathFileAlloc(io, ".", alloc);
        // Lexically resolve `./`, trailing separators, and `..` against the
        // cwd, then express the result relative to it. The walker only covers
        // the cwd and produces cwd-relative paths, so this handles `./src`,
        // absolute paths, and catches paths outside the cwd.
        const abs = try path.resolve(alloc, &.{ cwd_abs.?, raw });
        const rel = try path.relative(alloc, cwd_abs.?, null, cwd_abs.?, abs);
        // On Windows `rel` stays absolute when on a different drive.
        if (path.isAbsolute(rel) or mem.eql(u8, rel, "..") or
            mem.startsWith(u8, rel, ".." ++ sep_str))
        {
            if (invalid_arg) |ptr| ptr.* = raw;
            return error.PathOutsideCwd;
        }
        // `zlint .` lints the whole cwd, just like bare `zlint`.
        if (rel.len == 0) {
            includes.appendAssumeCapacity("**");
            continue;
        }

        const stat = cwd.statFile(io, rel, .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => {
                if (invalid_arg) |ptr| ptr.* = raw;
                return error.PathNotFound;
            },
            else => return e,
        };

        // Glob patterns use '/' separators, even on Windows.
        const normalized = if (comptime util.IS_WINDOWS) blk: {
            const owned = try alloc.dupe(u8, rel);
            mem.replaceScalar(u8, owned, std.fs.path.sep, '/');
            break :blk owned;
        } else rel;

        includes.appendAssumeCapacity(switch (stat.kind) {
            .directory => try std.fmt.allocPrint(alloc, "{s}/**", .{normalized}),
            else => normalized,
        });
    }

    return includes.items;
}

/// Does an argument contain glob syntax? Arguments with glob characters are
/// matched as patterns; anything else is treated as a filesystem path.
fn isGlobPattern(arg: []const u8) bool {
    if (arg.len == 0) return false;
    if (arg[0] == '!') return true; // negated pattern
    const glob_chars = if (comptime util.IS_WINDOWS) "*?[]{}" else "*?[]{}\\";
    return mem.indexOfAny(u8, arg, glob_chars) != null;
}

/// Modified version of `streamUntilDelimiterOrEof` from zig v0.14.1's stdlib.
///
/// Reads from the stream until specified byte is found. If the buffer is not
/// large enough to hold the entire contents, `error.StreamTooLong` is returned.
/// If end-of-stream is found, returns the rest of the stream. If this
/// function is called again after that, returns null.
/// Returns a slice of the stream data, with ptr equal to `buf.ptr`. The
/// delimiter byte is written to the output buffer but is not included
/// in the returned slice.
pub fn readUntilDelimiterOrEof(self: *std.Io.Reader, buffer: []u8, delimiter: u8) anyerror!?[]u8 {
    var fbw = std.Io.Writer.fixed(buffer);
    const bytes_read = self.streamDelimiter(&fbw, delimiter) catch |err| switch (err) {
        error.EndOfStream => if (fbw.end == 0) {
            return null;
        } else {
            // Partial data at EOF (e.g. last line without trailing newline)
            return buffer[0..fbw.end];
        },

        else => |e| return e,
    };
    if (bytes_read == 0) return null;
    self.toss(1); // throw out the delimiter
    return buffer[0..bytes_read];
}

const t = std.testing;

// These tests assume the cwd is the repository root, like the lint_config
// tests.
test normalizeIncludes {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cwd = Io.Dir.cwd();
    const cwd_abs = try cwd.realPathFileAlloc(t.io, ".", alloc);
    const src_abs = try path.join(alloc, &.{ cwd_abs, "src" });
    const build_abs = try path.join(alloc, &.{ cwd_abs, "build.zig" });

    const Case = struct {
        args: []const []const u8,
        expected: []const []const u8,
    };
    const cases = [_]Case{
        .{ .args = &.{}, .expected = &.{} },
        // directories lint everything under them
        .{ .args = &.{"src"}, .expected = &.{"src/**"} },
        .{ .args = &.{"src/"}, .expected = &.{"src/**"} },
        .{ .args = &.{"./src"}, .expected = &.{"src/**"} },
        .{ .args = &.{ ".", "./" }, .expected = &.{ "**", "**" } },
        // files match exactly
        .{ .args = &.{"build.zig"}, .expected = &.{"build.zig"} },
        .{ .args = &.{"./build.zig"}, .expected = &.{"build.zig"} },
        // glob patterns pass through untouched
        .{ .args = &.{"src/**"}, .expected = &.{"src/**"} },
        .{ .args = &.{"!src/**"}, .expected = &.{"!src/**"} },
        .{ .args = &.{"**/*.zig"}, .expected = &.{"**/*.zig"} },
        // absolute paths within the cwd are relativized
        .{ .args = &.{src_abs}, .expected = &.{"src/**"} },
        .{ .args = &.{build_abs}, .expected = &.{"build.zig"} },
        // mixed arguments
        .{
            .args = &.{ "src", "build.zig", "test/**" },
            .expected = &.{ "src/**", "build.zig", "test/**" },
        },
    };

    for (cases) |case| {
        const actual = try normalizeIncludes(alloc, t.io, case.args, null);
        try t.expectEqual(case.expected.len, actual.len);
        for (case.expected, actual) |expected_pattern, actual_pattern| {
            try t.expectEqualStrings(expected_pattern, actual_pattern);
        }
    }
}

test "normalizeIncludes rejects paths that do not exist" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var invalid_arg: []const u8 = "";
    try t.expectError(
        error.PathNotFound,
        normalizeIncludes(alloc, t.io, &.{"definitely-not-a-real-zlint-path"}, &invalid_arg),
    );
    try t.expectEqualStrings("definitely-not-a-real-zlint-path", invalid_arg);
}

test "normalizeIncludes rejects paths outside of the cwd" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var invalid_arg: []const u8 = "";
    try t.expectError(
        error.PathOutsideCwd,
        normalizeIncludes(alloc, t.io, &.{ "..", "../outside" }, &invalid_arg),
    );
    try t.expectEqualStrings("..", invalid_arg);
}
