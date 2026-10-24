const std = @import("std");
const testing = std.testing;
const ra8 = @import("ra8");
const oracle_mod = ra8.session.history_shadow_oracle;
const ShadowOracle = oracle_mod.ShadowOracle;
const MemoryRange = oracle_mod.MemoryRange;
const page_size = oracle_mod.page_size;
const Store = ra8.chip.core.cpu.memory.store.Store;
const trail_mod = ra8.session.history_trail;

test "shadow oracle passes when no writes occur" {
    var oracle = ShadowOracle.init(testing.allocator);
    defer oracle.deinit();

    var mem: [page_size * 2]u8 = @splat(0xAA);
    try oracle.trackRegion(0x2000_0000, &mem);

    // No writes
    const records: []const MemoryRange = &.{};
    try oracle.verifySlot(records);
}

test "shadow oracle passes when write is covered by trail record" {
    var oracle = ShadowOracle.init(testing.allocator);
    defer oracle.deinit();

    var mem: [page_size * 2]u8 = @splat(0xAA);
    try oracle.trackRegion(0x2000_0000, &mem);

    // Modify byte in page 0 (offset 100)
    mem[100] = 0x55;

    // Trail record covers page 0
    const records = [_]MemoryRange{.{
        .base = 0x2000_0000,
        .offset = 100,
        .len = 1,
    }};
    try oracle.verifySlot(&records);

    // Modifying byte in page 1 (offset 4096 + 20) with matching record
    mem[page_size + 20] = 0x77;
    const records2 = [_]MemoryRange{.{
        .base = 0x2000_0000,
        .offset = page_size + 20,
        .len = 4,
    }};
    try oracle.verifySlot(&records2);
}

test "shadow oracle catches a deliberately unhooked write" {
    var oracle = ShadowOracle.init(testing.allocator);
    defer oracle.deinit();

    var mem: [page_size * 2]u8 = @splat(0xAA);
    try oracle.trackRegion(0x2000_0000, &mem);

    // Deliberately unhooked write into page 1 (bypasses write hook)
    mem[page_size + 50] = 0xEF;

    // Trail record only covers page 0, leaving page 1 unhooked
    const records = [_]MemoryRange{.{
        .base = 0x2000_0000,
        .offset = 10,
        .len = 2,
    }};

    // Oracle MUST detect unhooked modification in page 1
    const result = oracle.verifySlot(&records);
    try testing.expectError(error.UnhookedWrite, result);
}

test "shadow oracle with Store tracking" {
    var store = try Store.init(null);
    defer store.deinit();

    var oracle = ShadowOracle.init(testing.allocator);
    defer oracle.deinit();

    try oracle.trackStore(&store);

    // Pick first mapped RAM region in store
    const page0 = store.pages[0].?;
    const base: u32 = ra8.chip.core.memmap.ram[0].base;
    _ = base;

    // Deliberately unhooked write
    page0[0] ^= 0xFF;

    const empty_records: []const MemoryRange = &.{};
    try testing.expectError(error.UnhookedWrite, oracle.verifySlot(empty_records));
}

test "shadow oracle recording verification helper" {
    var store = try Store.init(null);
    defer store.deinit();

    var slots: [2]u64 = .{ 0, 0 };
    var rec = trail_mod.Recording.init(testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();
    rec.arm();

    var oracle = ShadowOracle.init(testing.allocator);
    defer oracle.deinit();

    try oracle.trackStore(&store);

    // Legitimate write hooked through recording
    try store.write(.cpu0, ra8.chip.core.memmap.ram[0].base + 10, &.{0x22});

    try oracle.verifyRecording(rec.slice());
}
