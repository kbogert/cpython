/// Add config values to a ConfigHeader from a lazy path.
/// The lazy path should contain lines in the format: NAME VALUE
pub fn addFile(config_header: *ConfigHeader, config_results: std.Build.LazyPath) void {
    const b = config_header.step.owner;
    // This ApplyConfigStep is just a HACK which *should work* but the proper solution is to
    // add LazyPath support in ConfigHeader itself.
    const apply = b.allocator.create(ApplyConfigStep) catch @panic("OOM");
    apply.* = .{
        .step = std.Build.Step.init(.{
            .tag = .config_header,
            .name = "add configuration from lazy path",
            .owner = b,
        }),
        .config_header = config_header,
        .config_results = config_results,
    };
    config_results.addStepDependencies(&apply.step);
    config_header.step.dependOn(&apply.step);
}

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

pub const FileEntry = struct {
    name: []const u8,
    value: ConfigHeader.Value,

    pub fn parse(line: []const u8) error{ MissingValue, InvalidValue }!FileEntry {
        const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.MissingValue;
        return .{
            .name = line[0..first_space],
            .value = parseValue(line[first_space + 1 ..]) orelse return error.InvalidValue,
        };
    }
};

const ApplyConfigStep = struct {
    step: std.Build.Step,
    config_header: *ConfigHeader,
    config_results: std.Build.LazyPath,

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const self: *ApplyConfigStep = @fieldParentPtr("step", step);

        const file_path = try self.config_results.getPath4(b, step);
        const content = file_path.root_dir.handle.readFileAlloc(
            b.graph.io,
            file_path.subPathOrDot(),
            b.allocator,
            .unlimited,
        ) catch |err| return step.fail(
            "unable to read config values from '{f}': {t}",
            .{ file_path, err },
        );
        var line_it = std.mem.splitScalar(u8, content, '\n');
        var line_num: u32 = 0;
        while (line_it.next()) |line| {
            line_num += 1;
            if (line.len == 0 or line[0] == '#') continue;
            if (FileEntry.parse(line)) |entry| {
                self.config_header.values.put(b.allocator, entry.name, entry.value) catch @panic("OOM");
            } else |err| {
                step.addError("{f}:{d}: {t} '{s}'", .{ file_path, line_num, err, line }) catch @panic("OOM");
            }
        }
        if (step.result_error_msgs.items.len != 0) return error.MakeFailed;
    }
};

const std = @import("std");
const ConfigHeader = std.Build.Step.ConfigHeader;
