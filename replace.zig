const std = @import("std");
const Io = std.Io;

pub fn replace(b: *std.Build, in_path: []const u8, out_path: []const u8, replacements: []const []const u8) void {
    const arena = b.allocator;
    const io = b.graph.io;

    var map: std.StringHashMapUnmanaged(MapNode) = .{};
    for (replacements) |r| {
        const eq_index = std.mem.indexOfScalar(u8, r, '=') orelse errExit(
            "expected NAME=VALUE cmdline arg but got '{s}'",
            .{r},
        );
        map.put(arena, r[0..eq_index], .{ .count = 0, .value = r[eq_index + 1 ..] }) catch @panic("OOM");
    }

    const in = std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .unlimited) catch |e|
        std.debug.panic("open '{s}' failed with {t}", .{ in_path, e });

    var out_file = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch @panic("Cannot create outfile");
    defer out_file.close(io);

    var out_file_buf: [4096]u8 = undefined;
    var file_writer = out_file.writer(io, &out_file_buf);
    writeFile(in_path, in, &map, &file_writer.interface) catch |err| std.debug.panic("write to '{s}' failed with {t}", .{ out_path, err });

    var unused_count: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.count == 0) {
            std.log.err("unused variable '{s}'", .{entry.key_ptr.*});
            unused_count += 1;
        }
    }
    if (unused_count != 0) {
        std.log.err("{} unused variable(s), the did not appear in template '{s}'", .{ unused_count, in_path });
        std.process.exit(0xff);
    }
}

const MapNode = struct {
    count: usize,
    value: []const u8,
};

fn writeFile(
    in_path: []const u8,
    in: []const u8,
    map: *const std.StringHashMapUnmanaged(MapNode),
    writer: *std.Io.Writer,
) error{WriteFailed}!void {
    var missing_count: usize = 0;
    var offset: usize = 0;
    while (true) {
        const at_index = std.mem.indexOfScalarPos(u8, in, offset, '@') orelse break;
        try writer.writeAll(in[offset..at_index]);
        const end = std.mem.indexOfScalarPos(u8, in, at_index + 1, '@') orelse errExit(
            "{s}: unterminated '@' at offset {}",
            .{ in_path, at_index },
        );
        const name = in[at_index + 1 .. end];
        if (map.getEntry(name)) |entry| {
            entry.value_ptr.count += 1;
            try writer.writeAll(entry.value_ptr.value);
        } else {
            std.log.err("undefined variable '{s}'", .{name});
            try writer.print("MISSING_VAR_{s}", .{name});
            missing_count += 1;
        }
        offset = end + 1;
    }
    try writer.writeAll(in[offset..]);
    try writer.flush();
    if (missing_count > 0) errExit("{} missing variable(s) for template '{s}'", .{ missing_count, in_path });
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}
