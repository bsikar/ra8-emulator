//! Per-function branch complexity and nesting, measured from the Zig AST.
const std = @import("std");

const zlinter = @import("zlinter");

const Ast = std.zig.Ast;
const Stats = struct { score: usize = 0, depth: usize = 0 };

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    max_score: usize = 15,
    max_depth: usize = 3,
};

pub fn buildRule(_: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    return .{ .rule_id = "complexity", .run = &run };
}

fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const tree = doc.tree(session);
    const allocator = session.runtime.sessionArena();
    const stats = try session.runtime.ruleArena().alloc(Stats, tree.nodes.len);
    @memset(stats, .{});

    try measure(tree, doc, session, stats);

    var problems: std.ArrayList(zlinter.results.LintProblem) = .empty;
    for (stats, 0..) |value, index| {
        if (value.score <= config.max_score and value.depth <= config.max_depth) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node) orelse continue;
        const token = proto.name_token orelse proto.ast.fn_token;
        try problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, token),
            .end = .endOfToken(tree, token),
            .message = try std.fmt.allocPrint(allocator, "Function {s}: branch complexity {d}/{d}, nesting {d}/{d}.", .{
                tree.tokenSlice(token), value.score, config.max_score, value.depth, config.max_depth,
            }),
        });
    }

    if (problems.items.len == 0) return null;
    return try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(allocator));
}

fn measure(
    tree: Ast,
    doc: *const zlinter.session.LintDocument,
    session: *zlinter.session.LintSession,
    stats: []Stats,
) zlinter.rules.RunError!void {
    var nodes = try doc.nodeLineageIterator(.root, session.runtime.ruleArena());
    defer nodes.deinit();
    while (try nodes.next()) |tuple| {
        const node = tuple[0];
        const tag = tree.nodeTag(node);
        if (!branch(tag) and tag != .bool_and and tag != .bool_or) continue;
        const owner = functionOf(tree, doc, node) orelse continue;
        const measured = depthOf(tree, doc, node);
        const value = &stats[@backingInt(owner)];
        if (branch(tag)) {
            value.score += 1 + measured;
            value.depth = @max(value.depth, measured + 1);
        } else if (tuple[1].parent) |parent| {
            if (tree.nodeTag(parent) != tag) value.score += 1;
        }
    }
}

fn branch(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .if_simple,
        .@"if",
        .for_simple,
        .@"for",
        .while_simple,
        .while_cont,
        .@"while",
        .@"switch",
        .switch_comma,
        .@"catch",
        => true,
        else => false,
    };
}

fn functionOf(tree: Ast, doc: *const zlinter.session.LintDocument, node: Ast.Node.Index) ?Ast.Node.Index {
    var ancestors = doc.nodeAncestorIterator(node);
    while (ancestors.next()) |parent| {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

fn depthOf(tree: Ast, doc: *const zlinter.session.LintDocument, node: Ast.Node.Index) usize {
    var ancestors = doc.nodeAncestorIterator(node);
    var child = node;
    var depth: usize = 0;
    while (ancestors.next()) |parent| {
        if (tree.nodeTag(parent) == .fn_decl) break;
        if (branch(tree.nodeTag(parent))) {
            const is_else_if = if (tree.fullIf(parent)) |info|
                info.ast.else_expr.unwrap() == child and tree.fullIf(child) != null
            else
                false;
            if (!is_else_if) depth += 1;
        }
        child = parent;
    }
    return depth;
}
