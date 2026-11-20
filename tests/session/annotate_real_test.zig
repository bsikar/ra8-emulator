//! The real firmware image, not a fixture: a function start must name the
//! function, never an ARM mapping symbol (RA8EMU-1328).
//!
//! Rebuilds move the addresses, so the test picks its site from the image's
//! own table: a real function whose exact start a `$t`/`$a`/`$d` mapping
//! symbol also claims. Before the mapping-symbol skip such a line annotated
//! as " ; $d"; now it names the function. The image is the txm_manager ELF
//! the firmware tree's `zig build arm` step produces; the test skips when
//! it is not on disk.
const std = @import("std");

const ra8 = @import("ra8");
const annotate = ra8.session.annotate;
const symbols = ra8.session.symbols;

const default_path = "../ra8-firmware/zig-out/arm/txm_manager_cpu1_cpu1.elf";
const max_mappings = 8192;

fn isMappingSymbol(name: []const u8) bool {
    if (name.len < 2 or name[0] != '$') return false;
    if (name[1] != 't' and name[1] != 'd' and name[1] != 'a') return false;
    return name.len == 2 or name[2] == '.';
}

fn claimedByMapping(mappings: []const u32, address: u32) bool {
    for (mappings) |at| {
        if (at == address) return true;
    }
    return false;
}

fn realImage(allocator: std.mem.Allocator) !?[]u8 {
    // The sibling firmware checkout carries the image; a tree without it
    // skips the test rather than failing the suite.
    const path = default_path;
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// The function site to probe: a real, sized function whose start a
/// mapping symbol shares, preferring the threadx handler the spike
/// examined first.
fn probeSite(image: ra8.board.image.elf.Image, mappings: []const u32) ?symbols.Named {
    var site: ?symbols.Named = null;
    var walk = symbols.Walk.init(image);
    while (walk.next()) |named| {
        if (named.kind != symbols.symbol_type.func or named.size == 0) continue;
        const start = named.value & ~@as(u32, 1);
        if (!claimedByMapping(mappings, start)) continue;
        if (std.mem.eql(u8, named.name, "_tx_thread_application_stack_error_handler")) return named;
        if (site == null) site = named;
    }
    return site;
}

test "annotate_real function start names the function, never a mapping symbol" {
    const allocator = std.testing.allocator;
    const bytes = (try realImage(allocator)) orelse return error.SkipZigTest;
    defer allocator.free(bytes);
    const image = try ra8.board.image.elf.Image.init(bytes);

    const mappings = try allocator.alloc(u32, max_mappings);
    defer allocator.free(mappings);
    var count: usize = 0;
    var walk = symbols.Walk.init(image);
    while (walk.next()) |named| {
        if (!isMappingSymbol(named.name) or named.value == 0) continue;
        if (count == mappings.len) break;
        mappings[count] = named.value;
        count += 1;
    }

    const site = probeSite(image, mappings[0..count]) orelse return error.SkipZigTest;
    var text: ra8.chip.core.cpu.text.text.Text = .{};
    text.put("b.w #0x{x}", .{site.value & ~@as(u32, 1)});
    annotate.line(image, &text);
    try std.testing.expect(std.mem.indexOf(u8, text.slice(), site.name) != null);
    try std.testing.expect(std.mem.indexOf(u8, text.slice(), " ; $") == null);
}
