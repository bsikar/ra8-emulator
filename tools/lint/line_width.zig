//! Source columns are checked separately from function size and complexity.
const std = @import("std");

const zlinter = @import("zlinter");

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    max_columns: usize = 120,
};

pub fn buildRule(_: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    return .{ .rule_id = "line_width", .run = &run };
}

fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const allocator = session.runtime.sessionArena();
    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;
    var lines = std.mem.splitScalar(u8, doc.source(session), '\n');
    var offset: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const columns = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (columns > config.max_columns) {
            try problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .{ .byte_offset = offset },
                .end = .{ .byte_offset = offset + line.len - 1 },
                .message = try std.fmt.allocPrint(allocator, "Line has {d} columns; limit is {d}.", .{
                    columns, config.max_columns,
                }),
            });
        }
        offset += raw.len + 1;
    }

    if (problems.items.len == 0) return null;
    return try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(allocator));
}
