const std = @import("std");
const framing = @import("ra8").dap.framing;

test "fragmented and coalesced Content-Length frames count UTF-8 bytes" {
    var decoder: framing.Decoder = .{};
    var count: usize = 0;
    for ("Content-Length: 4\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n\"é\"Content-Length: 2\r\n\r\n{}") |byte| {
        if (try decoder.push(byte)) |json| {
            try std.testing.expectEqualStrings(if (count == 0) "\"é\"" else "{}", json);
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "missing duplicate zero oversized and malformed lengths are rejected" {
    const cases = .{
        .{ "X: y\r\n\r\n", error.MissingLength },
        .{ "Content-Length: 2\r\nContent-Length: 2\r\n\r\n", error.DuplicateLength },
        .{ "Content-Length: 0\r\n\r\n", error.BadLength },
        .{ "Content-Length: 65537\r\n\r\n", error.BadLength },
        .{ "Content-Length: -1\r\n\r\n", error.BadLength },
    };
    inline for (cases) |case| {
        var decoder: framing.Decoder = .{};
        for (case[0][0 .. case[0].len - 1]) |byte| _ = try decoder.push(byte);
        try std.testing.expectError(case[1], decoder.push('\n'));
    }
}
