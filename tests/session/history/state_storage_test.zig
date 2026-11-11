//! Covers src/session/history/state_storage.zig: rebuilt XIP OSPI NOR
//! read-only bytes at 0x8000_0000 match when unmutated, while post-load NOR
//! flash programming or sector erasing diverges at the exact NOR address.
const std = @import("std");
const ra8 = @import("ra8");

const storage = ra8.session.history_state_storage;
const memory = ra8.session.history_state_memory;
const elf = ra8.board.image.elf;

const gpa = std.testing.allocator;

fn xipElf(out: *std.ArrayList(u8), fill: u8) !void {
    var head = std.mem.zeroes(elf.Header);
    head.magic = "\x7fELF".*;
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    head.e_phoff = @sizeOf(elf.Header);
    head.e_phentsize = @sizeOf(elf.ProgramHeader);
    head.e_phnum = 1;
    const body = @sizeOf(elf.Header) + @sizeOf(elf.ProgramHeader);
    const load = elf.ProgramHeader{
        .p_type = elf.pt_load,
        .p_offset = body,
        .p_vaddr = memory.ospi_base,
        .p_paddr = memory.ospi_base,
        .p_filesz = 8,
        .p_memsz = 8,
        .p_flags = 5,
        .p_align = 4,
    };
    try out.appendSlice(gpa, std.mem.asBytes(&head));
    try out.appendSlice(gpa, std.mem.asBytes(&load));
    try out.appendNTimes(gpa, fill, 8);
}

fn storagePayload(out: *std.ArrayList(u8), sector_data: ?[]const u8) !void {
    var board = ra8.board.board.Board.init(gpa);
    defer board.deinit();
    try board.nor.resize(64 * 1024);
    if (sector_data) |data| {
        board.nor.window().rawWrite(0, data);
    }
    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();
    try ra8.snapshot.file.writeHeader(&writer.writer);
    try ra8.board.snapshot.storage.save(&board, &writer.writer);
    const sec = (try ra8.snapshot.file.Reader.find(writer.written(), .storage)).?;
    try out.appendSlice(gpa, sec.payload);
}

const Compare = struct { diff: storage.Diff, same_hash: bool };

fn compare(a_payload: []const u8, b_payload: []const u8, mask: memory.Mask) !Compare {
    const parsed_a = try storage.parse(a_payload);
    const parsed_b = try storage.parse(b_payload);
    var ha = std.crypto.hash.Blake3.init(.{});
    var hb = std.crypto.hash.Blake3.init(.{});
    storage.hash(&ha, parsed_a, mask);
    storage.hash(&hb, parsed_b, mask.flipped());
    var da: [16]u8 = undefined;
    var db: [16]u8 = undefined;
    ha.final(&da);
    hb.final(&db);
    return .{
        .diff = storage.compare(parsed_a, parsed_b, mask),
        .same_hash = std.mem.eql(u8, &da, &db),
    };
}

test "rebuilt XIP OSPI NOR read-only segment matches while post-load NOR program or erase diverges" {
    var elf_a: std.ArrayList(u8) = .empty;
    defer elf_a.deinit(gpa);
    var elf_b: std.ArrayList(u8) = .empty;
    defer elf_b.deinit(gpa);
    try xipElf(&elf_a, 0xAA);
    try xipElf(&elf_b, 0xBB);
    const mask: memory.Mask = .{
        .a = try elf.Image.init(elf_a.items),
        .b = try elf.Image.init(elf_b.items),
    };

    var sec_a: std.ArrayList(u8) = .empty;
    defer sec_a.deinit(gpa);
    var sec_b: std.ArrayList(u8) = .empty;
    defer sec_b.deinit(gpa);
    try storagePayload(&sec_a, &@as([8]u8, @splat(0xAA)));
    try storagePayload(&sec_b, &@as([8]u8, @splat(0xBB)));

    const ok = try compare(sec_a.items, sec_b.items, mask);
    try std.testing.expectEqual(storage.Diff.none, ok.diff);
    try std.testing.expect(ok.same_hash);

    // Post-load NOR byte program at 0x8000_0003 (0xBB & 0x0F -> 0x0B).
    var programmed: [8]u8 = @splat(0xBB);
    programmed[3] = 0x0B;
    var sec_prog: std.ArrayList(u8) = .empty;
    defer sec_prog.deinit(gpa);
    try storagePayload(&sec_prog, &programmed);
    const prog = try compare(sec_a.items, sec_prog.items, mask);
    try std.testing.expectEqual(memory.Spot{ .address = memory.ospi_base + 3, .expected = 0xAA, .actual = 0x0B }, prog.diff.memory);
    try std.testing.expect(!prog.same_hash);

    // Post-load NOR sector erase back to 0xFF (sector omitted from sparse NOR save).
    var sec_erased: std.ArrayList(u8) = .empty;
    defer sec_erased.deinit(gpa);
    try storagePayload(&sec_erased, null);
    const erased = try compare(sec_a.items, sec_erased.items, mask);
    try std.testing.expectEqual(memory.Spot{ .address = memory.ospi_base, .expected = 0xAA, .actual = 0xFF }, erased.diff.memory);
    try std.testing.expect(!erased.same_hash);
}
