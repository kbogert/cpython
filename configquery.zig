pub fn resolveQueries(b: *std.Build, template_files: []const []const u8, config_header: *ConfigHeader, config: Config, log_error_comments: bool) !void {
    const arena = b.allocator;
    const io = b.graph.io;

    var queries: std.ArrayList(Query) = .empty;
    var name_set: std.StringHashMapUnmanaged(u32) = .empty;
    var error_count: u32 = 0;

    for (template_files) |template_path| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, template_path, arena, .unlimited) catch |err| fatal(
            "failed to read '{s}' with {t}",
            .{ template_path, err },
        );
        var line_it = std.mem.splitScalar(u8, content, '\n');
        var line_num: u32 = 0;
        while (line_it.next()) |line_untrimmed| {
            line_num += 1;
            switch (parseLine(line_untrimmed)) {
                .skip => continue,
                .err => |msg| {
                    reportError(io, template_path, line_num, "{s}", .{msg});
                    error_count += 1;
                },
                .literal => |lit| {
                    checkUnique(arena, &name_set, io, template_path, line_num, lit.config_name, &error_count);
                    if (parseValue(lit.value_str)) |entry| {
                        config_header.values.put(b.allocator, lit.config_name, entry) catch @panic("OOM");
                    } else {
                        error_count += 1;
                        reportError(io, template_path, line_num, "{s} '{s}'", .{ lit.config_name, line_untrimmed });
                    }
                },
                .query => |input| {
                    checkUnique(arena, &name_set, io, template_path, line_num, input.config_name, &error_count);
                    if (input.includes.len > 0 or input.compile_body.len > 0) {
                        queries.append(arena, .{
                            .input = input,
                            .file_path = template_path,
                            .line_num = line_num,
                        }) catch |e| oom(e);
                    } else {
                        config_header.values.put(b.allocator, input.config_name, .{ .string = input.pass_text }) catch @panic("OOM");
                    }
                },
            }
        }
    }

    if (error_count > 0) fatal("{} errors in config templates", .{error_count});

    if (queries.items.len > 0) {
        const zig_exe = config.zig_exe orelse fatal("compile query requires zig-exe", .{});
        const argv_template = buildArgvTemplate(arena, zig_exe, &config);

        var group: std.Io.Group = .init;
        for (queries.items, 0..) |*q, i| {
            group.async(io, runCompileCheck, .{ arena, io, q, argv_template, i });
        }
        group.await(io) catch |err| switch (err) {
            error.Canceled => fatal("canceled", .{}),
        };

        for (queries.items) |*q| {
            const result = q.result orelse fatal("compile query for '{s}' has no result", .{q.input.config_name});
            if (result.fatal_msg) |msg| {
                error_count += 1;
                reportError(io, q.file_path, q.line_num, "{s}", .{msg});
            } else {
                const value_text = if (result.success) q.input.pass_text else q.input.fail_text;

                if (parseValue(value_text)) |entry| {
                    config_header.values.put(b.allocator, q.input.config_name, entry) catch @panic("OOM");
                } else {
                    error_count += 1;
                    reportError(io, q.file_path, q.line_num, "{s} '{s}'", .{ q.input.config_name, value_text });
                }
                if (result.error_comments.len > 0 and log_error_comments) {
                    std.log.debug("{s}{s} {s} : {s}\n", .{ result.error_comments, q.input.config_name, q.input.pass_text, q.input.fail_text });
                }
            }
        }
    }

    if (error_count > 0) fatal("{} errors", .{error_count});
}

pub const Config = struct {
    zig_exe: ?[]const u8 = null,
    target_triple: ?[]const u8 = null,
    mcpu: ?[]const u8 = null,
    include_dirs: std.ArrayList([]const u8) = .empty,
};

const Line = union(enum) {
    skip,
    err: []const u8,
    literal: struct {
        config_name: []const u8,
        value_str: []const u8,
    },
    query: QueryInput,
};

const QueryInput = struct {
    config_name: []const u8,
    pass_text: []const u8,
    fail_text: []const u8,
    defines: []const u8,
    includes: []const u8,
    compile_body: []const u8,
};

const Query = struct {
    input: QueryInput,
    file_path: []const u8,
    line_num: u32,
    result: ?Result = null,
    pub const Result = struct {
        success: bool,
        error_comments: []const u8,
        fatal_msg: ?[]const u8,
    };
};

pub fn parseValue(str: []const u8) ?ConfigHeader.Value {
    if (std.mem.eql(u8, str, "undef")) return .undef;
    if (std.mem.eql(u8, str, "defined")) return .defined;
    if (std.mem.eql(u8, str, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, str, "true")) return .{ .boolean = true };
    if (std.fmt.parseInt(i64, str, 10)) |int| return .{ .int = int } else |_| {}
    if (std.mem.startsWith(u8, str, ":")) return .{ .ident = str[1..] };
    if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"') return .{ .string = str[1 .. str.len - 1] };
    return null;
}

fn parseLine(line_untrimmed: []const u8) Line {
    const line = std.mem.trim(u8, line_untrimmed, &std.ascii.whitespace);
    if (line.len == 0 or line[0] == '#') return .skip;

    const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ .err = "expected 'NAME VALUE'" };
    const config_name = line[0..first_space];
    const value_str = std.mem.trimStart(u8, line[first_space + 1 ..], " ");

    if (!std.mem.startsWith(u8, value_str, "?")) {
        _ = parseValue(value_str) orelse
            return .{ .err = "invalid config value" };
        return .{ .literal = .{ .config_name = config_name, .value_str = value_str } };
    }

    const pass_str, const after_pass = scanConfigValue(value_str, 1);
    _ = parseValue(pass_str) orelse return .{ .err = "expected PASS_VALUE after ?" };
    const pipe_index = skipWhitespace(value_str, after_pass);
    if (pipe_index >= value_str.len or value_str[pipe_index] != '|')
        return .{ .err = "expected '|' after PASS_VALUE" };
    const fail_str, const after_fail = scanConfigValue(value_str, pipe_index + 1);
    _ = parseValue(fail_str) orelse return .{ .err = "expected FAIL_VALUE after '|'" };
    var rest = std.mem.trimStart(u8, value_str[after_fail..], " ");
    const defines = parseExprClause(&rest, "define=");
    const includes = parseExprClause(&rest, "include=");
    if (includes.len == 0 and rest.len == 0) return .{ .err = "query has no include nor code to check" };
    return .{ .query = .{
        .config_name = config_name,
        .pass_text = pass_str,
        .fail_text = fail_str,
        .defines = defines,
        .includes = includes,
        .compile_body = rest,
    } };
}

fn skipWhitespace(str: []const u8, start: usize) usize {
    var i = start;
    while (true) : (i += 1) {
        if (i >= str.len) return i;
        if (!std.ascii.isWhitespace(str[i])) return i;
    }
}

fn scanConfigValue(str: []const u8, start: usize) struct { []const u8, usize } {
    const i = skipWhitespace(str, start);
    if (i >= str.len) return .{ "", str.len };
    switch (str[i]) {
        'a'...'z', 'A'...'Z', '_' => return scanAlphanum(str, i),
        '-', '0'...'9' => return scanInt(str, i),
        // TODO: handle :IDENTICAL and "QUOTED_STRING"
        else => |ch| std.debug.panic("todo '{c}'", .{ch}),
    }
}
fn scanAlphanum(str: []const u8, start: usize) struct { []const u8, usize } {
    switch (str[start]) {
        'a'...'z', 'A'...'Z', '_' => {},
        else => unreachable,
    }
    var i = start + 1;
    while (true) : (i += 1) {
        if (i >= str.len) return .{ str[start..], i };
        switch (str[i]) {
            'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
            else => return .{ str[start..i], i },
        }
    }
}
fn scanInt(str: []const u8, start: usize) struct { []const u8, usize } {
    switch (str[start]) {
        '-', '0'...'9' => {},
        else => unreachable,
    }
    var i = start + 1;
    while (true) : (i += 1) {
        if (i >= str.len) return .{ str[start..], i };
        switch (str[i]) {
            '0'...'9' => {},
            else => return .{ str[start..i], i },
        }
    }
}

fn parseExprClause(rest: *[]const u8, prefix: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, rest.*, prefix)) return "";
    const after_prefix = rest.*[prefix.len..];
    const end = std.mem.indexOfScalar(u8, after_prefix, ' ') orelse after_prefix.len;
    rest.* = std.mem.trimStart(u8, after_prefix[end..], " ");
    return after_prefix[0..end];
}

fn buildArgvTemplate(
    arena: std.mem.Allocator,
    zig_exe: []const u8,
    config: *const Config,
) []const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(arena, zig_exe) catch |e| oom(e);
    argv.append(arena, "build-obj") catch |e| oom(e);
    if (config.target_triple) |t| {
        argv.append(arena, "-target") catch |e| oom(e);
        argv.append(arena, t) catch |e| oom(e);
    }
    if (config.mcpu) |m| {
        argv.append(arena, "-mcpu") catch |e| oom(e);
        argv.append(arena, m) catch |e| oom(e);
    }
    argv.append(arena, "-lc") catch |e| oom(e);
    argv.append(arena, "-fno-emit-bin") catch |e| oom(e);
    for (config.include_dirs.items) |dir| argv.append(arena, dir) catch |e| oom(e);
    return argv.toOwnedSlice(arena) catch |e| oom(e);
}

fn runCompileCheck(
    arena: std.mem.Allocator,
    io: std.Io,
    query: *Query,
    argv_template: []const []const u8,
    index: usize,
) void {
    query.result = doCompileCheck(arena, io, query, argv_template, index);
}

fn doCompileCheck(
    arena: std.mem.Allocator,
    io: std.Io,
    query: *const Query,
    argv_template: []const []const u8,
    index: usize,
) Query.Result {
    const sep = std.fs.path.sep_str;

    const pid = switch (@import("builtin").os.tag) {
        .linux => std.os.linux.getpid(),
        .macos, .ios => std.c.getpid(),
        else => @compileError("unsupported OS"),
    };
    var task_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_dir = "."; // TODO: Need a reliable temporary directory instead of the build path to place the test programs

    const task_dir = std.fmt.bufPrint(&task_dir_buf, "{s}" ++ sep ++ "tmp" ++ sep ++ "cq-{}-{}", .{ base_dir, pid, index }) catch
        fatal("cache-dir path too long", .{});
    std.Io.Dir.cwd().createDirPath(io, task_dir) catch |err|
        fatal("failed to create '{s}': {t}", .{ task_dir, err });

    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = std.fmt.bufPrint(&source_buf, "{s}" ++ sep ++ "check.c", .{task_dir}) catch
        fatal("source path too long", .{});

    {
        var file = std.Io.Dir.cwd().createFile(io, source_path, .{}) catch |err|
            fatal("failed to create '{s}' with {t}", .{ source_path, err });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var w = file.writer(io, &buf);
        writeSource(&w.interface, &query.input) catch fatal("failed to write source: {t}", .{w.err.?});
        std.debug.assert(w.interface.end == 0);
    }

    const argv = blk: {
        var a = std.ArrayList([]const u8).initCapacity(arena, argv_template.len + 3) catch |e| oom(e);
        a.appendSliceAssumeCapacity(argv_template);
        a.appendAssumeCapacity(source_path);
        break :blk a.items;
    };

    const result = std.process.run(arena, io, .{
        .argv = argv,
    }) catch |err| fatal("zig build-obj failed with {t}", .{err});

    var delete_task_dir = true;
    defer if (delete_task_dir) std.Io.Dir.cwd().deleteTree(io, task_dir) catch {};

    switch (result.term) {
        .exited => |code| if (code == 0) return .{
            .success = true,
            .error_comments = "",
            .fatal_msg = null,
        },
        inline else => |sig, kind| {
            return .{
                .success = false,
                .error_comments = "",
                .fatal_msg = std.fmt.allocPrint(arena, "zig build-obj terminated ({t}) with {}", .{ kind, sig }) catch |e| oom(e),
            };
        },
    }

    var comments: std.ArrayList(u8) = .empty;
    comments.appendSlice(arena, std.fmt.allocPrint(arena, "# compilation for '{s}' failed with the following:\n", .{query.input.config_name}) catch |e| oom(e)) catch |e| oom(e);
    var stderr_it = std.mem.splitScalar(u8, result.stderr, '\n');
    while (stderr_it.next()) |stderr_line| {
        if (stderr_line.len > 0) comments.appendSlice(arena, std.fmt.allocPrint(arena, "# {s}\n", .{stderr_line}) catch |e| oom(e)) catch |e| oom(e);
    }

    var has_expected_error = false;
    var has_unexpected_error = false;
    var err_it = std.mem.splitScalar(u8, result.stderr, '\n');
    while (err_it.next()) |err_line_raw| {
        const err_line = std.mem.trimEnd(u8, err_line_raw, "\r");
        if (err_line.len == 0) continue;
        const error_prefix = "error: ";
        const error_start = std.mem.indexOf(u8, err_line, error_prefix) orelse continue;
        const err_msg = err_line[error_start + error_prefix.len ..];
        if (std.mem.endsWith(u8, err_msg, "file not found") or
            std.mem.startsWith(u8, err_msg, "call to undeclared function ") or
            std.mem.startsWith(u8, err_msg, "call to undeclared library function ") or
            std.mem.startsWith(u8, err_msg, "use of undeclared identifier") or
            std.mem.startsWith(u8, err_msg, "invalid instruction mnemonic") or
            std.mem.startsWith(u8, err_msg, "function definition is not allowed") or
            std.mem.startsWith(u8, err_msg, "unknown type name") or
            std.mem.startsWith(u8, err_msg, "no member named") or
            std.mem.startsWith(u8, err_msg, "incomplete definition of type") or
            std.mem.startsWith(u8, err_msg, "implicit declaration of function") or
            std.mem.startsWith(u8, err_msg, "redefinition of"))
        {
            has_expected_error = true;
        } else {
            has_unexpected_error = true;
        }
    }

    var fatal_msg: ?[]const u8 = null;
    if (has_unexpected_error and !has_expected_error) {
        delete_task_dir = false;
        fatal_msg = std.fmt.allocPrint(
            arena,
            "compile check failed with unexpected error(s):\n{s}",
            .{result.stderr},
        ) catch |e| oom(e);
    }

    return .{
        .success = false,
        .error_comments = comments.toOwnedSlice(arena) catch |e| oom(e),
        .fatal_msg = fatal_msg,
    };
}

fn checkUnique(
    arena: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(u32),
    io: std.Io,
    file: []const u8,
    line: u32,
    name: []const u8,
    error_count: *u32,
) void {
    const result = seen.getOrPut(arena, name) catch |e| oom(e);
    if (result.found_existing) {
        reportError(io, file, line, "duplicate config name '{s}' (first seen on line {})", .{ name, result.value_ptr.* });
        error_count.* += 1;
    } else {
        result.value_ptr.* = line;
    }
}

fn writeSource(w: *std.Io.Writer, q: *const QueryInput) error{WriteFailed}!void {
    if (q.defines.len > 0) {
        var it = std.mem.splitScalar(u8, q.defines, ',');
        while (it.next()) |d| try w.print("#define {s}\n", .{d});
    }
    if (q.includes.len > 0) {
        var it = std.mem.splitScalar(u8, q.includes, ',');
        while (it.next()) |h| try w.print("#include <{s}>\n", .{h});
    }
    if (q.compile_body.len != 0) {
        try w.writeAll(q.compile_body);
        try w.writeByte('\n');
    }
    try w.flush();
}

test parseLine {
    {
        const q = parseLine("HAVE_ALLOCA_H ? 1|undef include=alloca.h").query;
        try std.testing.expectEqualStrings("HAVE_ALLOCA_H", q.config_name);
        try std.testing.expectEqualStrings("1", q.pass_text);
        try std.testing.expectEqualStrings("undef", q.fail_text);
        try std.testing.expectEqualStrings("", q.defines);
        try std.testing.expectEqualStrings("alloca.h", q.includes);
        try std.testing.expectEqualStrings("", q.compile_body);
    }
    {
        const q = parseLine("HAVE_CLOSE_RANGE ? 1|undef define=_GNU_SOURCE include=unistd.h int main(){close_range(0,0,0);}").query;
        try std.testing.expectEqualStrings("_GNU_SOURCE", q.defines);
        try std.testing.expectEqualStrings("unistd.h", q.includes);
        try std.testing.expectEqualStrings("int main(){close_range(0,0,0);}", q.compile_body);
    }
    {
        const q = parseLine("HAVE_PRLIMIT ? 1|undef include=sys/time.h,sys/resource.h int main(){prlimit(0,0,0,0);}").query;
        try std.testing.expectEqualStrings("sys/time.h,sys/resource.h", q.includes);
        try std.testing.expectEqualStrings("int main(){prlimit(0,0,0,0);}", q.compile_body);
    }
    {
        const q = parseLine("HAVE_BUILTIN_ATOMIC ? 1|undef int main(){return 0;}").query;
        try std.testing.expectEqualStrings("", q.defines);
        try std.testing.expectEqualStrings("", q.includes);
        try std.testing.expectEqualStrings("int main(){return 0;}", q.compile_body);
    }
    {
        const lit = parseLine("SIZEOF_INT 4").literal;
        try std.testing.expectEqualStrings("SIZEOF_INT", lit.config_name);
        try std.testing.expectEqualStrings("4", lit.value_str);
    }
    try std.testing.expect(parseLine("") == .skip);
    try std.testing.expect(parseLine("# comment") == .skip);
    try std.testing.expect(parseLine("NOVALUE") == .err);
}

fn reportError(io: std.Io, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) void {
    var stderr = std.Io.File.stderr().writer(io, &.{});
    stderr.interface.print("{s}:{}: " ++ fmt ++ "\n", .{ file, line } ++ args) catch
        fatal("failed to write to stderr: {t}", .{stderr.err.?});
}

fn oom(err: error{OutOfMemory}) noreturn {
    fatal("{s}", .{@errorName(err)});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

const std = @import("std");
const ConfigHeaderExt = @import("ConfigHeaderExt.zig");
const ConfigHeader = std.Build.Step.ConfigHeader;
const LazyPath = std.Build.LazyPath;
