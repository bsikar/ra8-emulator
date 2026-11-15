//! Named namespace imports and a visible boundary before other declarations.
const std = @import("std");

const zlinter = @import("zlinter");

const Ast = std.zig.Ast;
const Problem = zlinter.results.LintProblem;

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

pub fn buildRule(_: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    return .{ .rule_id = "import_style", .run = &run };
}

fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const severity = options.getConfig(Config).severity;
    if (severity == .off) return null;

    const allocator = session.runtime.sessionArena();
    const tree = doc.tree(session);
    const allowed = try allocator.alloc(bool, tree.tokens.len);
    const starts = try allocator.alloc(bool, tree.tokens.len);
    @memset(allowed, false);
    @memset(starts, false);

    var endings: std.ArrayList(Ast.TokenIndex) = .empty;
    var nodes = try doc.nodeLineageIterator(.root, session.runtime.ruleArena());
    defer nodes.deinit();

    while (try nodes.next()) |tuple| {
        const node, const connections = tuple;
        if (!zlinter.ast.isContainerMember(tree, connections)) continue;
        const declaration = tree.fullVarDecl(node) orelse continue;
        const imported = importToken(tree, declaration.ast.init_node.unwrap() orelse continue) orelse continue;
        allowed[imported] = true;
        starts[tree.firstToken(node)] = true;

        var end = tree.lastToken(node);
        if (tree.tokenTag(end + 1) == .semicolon) end += 1;
        try endings.append(allocator, end);
    }

    var problems: std.ArrayList(Problem) = .empty;
    try findInline(rule.rule_id, severity, allocator, tree, doc.absPath(session), allowed, &problems);
    try findMissingGap(rule.rule_id, severity, allocator, tree, starts, endings.items, &problems);

    if (problems.items.len == 0) return null;
    return try zlinter.results.LintResult.init(doc.file_id, try problems.toOwnedSlice(allocator));
}

fn importToken(tree: Ast, initial: Ast.Node.Index) ?Ast.TokenIndex {
    var node = initial;
    while (tree.nodeTag(node) == .field_access) {
        node = tree.nodeData(node).node_and_token[0];
    }

    const token = tree.nodeMainToken(node);
    if (tree.tokenTag(token) != .builtin) return null;
    return if (std.mem.eql(u8, tree.tokenSlice(token), "@import")) token else null;
}

fn registration(tree: Ast, token: Ast.TokenIndex, path: []const u8) bool {
    // Test roots deliberately force discovery with comptime discard imports.
    if (std.mem.indexOf(u8, path, "/tests/") == null and std.mem.indexOf(u8, path, "\\tests\\") == null) return false;
    if (token < 2 or token + 4 >= tree.tokens.len) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(token - 2), "_") or tree.tokenTag(token - 1) != .equal) return false;
    if (tree.tokenTag(token + 1) != .l_paren or tree.tokenTag(token + 2) != .string_literal) return false;
    if (tree.tokenTag(token + 3) != .r_paren or tree.tokenTag(token + 4) != .semicolon) return false;

    for (tree.rootDecls()) |node| {
        if (tree.nodeTag(node) == .@"comptime" and
            token > tree.firstToken(node) and
            token < tree.lastToken(node)) return true;
    }
    return false;
}

fn hasBlankLine(gap: []const u8) bool {
    var lines = std.mem.splitScalar(u8, gap, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        if (lines.peek() != null and std.mem.trim(u8, line, " \t\r").len == 0) return true;
    }
    return false;
}

fn problem(
    rule_id: []const u8,
    severity: zlinter.rules.LintProblemSeverity,
    tree: Ast,
    token: Ast.TokenIndex,
    message: []const u8,
) Problem {
    return .{
        .rule_id = rule_id,
        .severity = severity,
        .start = .startOfToken(tree, token),
        .end = .endOfToken(tree, token),
        .message = message,
    };
}

fn findInline(
    rule_id: []const u8,
    severity: zlinter.rules.LintProblemSeverity,
    allocator: std.mem.Allocator,
    tree: Ast,
    path: []const u8,
    allowed: []const bool,
    problems: *std.ArrayList(Problem),
) !void {
    var token: Ast.TokenIndex = 0;
    while (token < tree.tokens.len) : (token += 1) {
        if (tree.tokenTag(token) != .builtin or !std.mem.eql(u8, tree.tokenSlice(token), "@import")) continue;
        if (allowed[token] or registration(tree, token, path)) continue;
        try problems.append(
            allocator,
            problem(
                rule_id,
                severity,
                tree,
                token,
                "Move this import to a named namespace declaration.",
            ),
        );
    }
}

fn findMissingGap(
    rule_id: []const u8,
    severity: zlinter.rules.LintProblemSeverity,
    allocator: std.mem.Allocator,
    tree: Ast,
    starts: []const bool,
    endings: []const Ast.TokenIndex,
    problems: *std.ArrayList(Problem),
) !void {
    for (endings) |end| {
        const next = end + 1;
        if (starts[next] or tree.tokenTag(next) == .eof or tree.tokenTag(next) == .r_brace) continue;
        const begin = tree.tokenStart(end) + tree.tokenSlice(end).len;
        const gap = tree.source[begin..tree.tokenStart(next)];
        if (!hasBlankLine(gap)) {
            try problems.append(
                allocator,
                problem(rule_id, severity, tree, next, "Add a blank line after the import group."),
            );
        }
    }
}
