//! Name literal-loaded model addresses/constants, reading only ordinary memory.
const chip = @import("ra8_chip");

const core_view = @import("core_view.zig");
const names = @import("annotation_names.zig");

const Instr = chip.core.cpu.instr.Instr;
const text = chip.core.cpu.text.text;

pub fn append(core: core_view.View, instruction: Instr, into: *text.Text) void {
    const pool = address(instruction) orelse return;
    if (!ordinary(pool)) return;
    const value = core.readWord(pool) catch return;
    if (names.find(value)) |name| into.put(" ; ={s}", .{name});
}

fn address(instruction: Instr) ?u32 {
    const pc = (instruction.address +% 4) & ~@as(u32, 3);
    if (instruction.size == 2 and instruction.hw1 & 0xF800 == 0x4800) {
        return pc +% (@as(u32, instruction.hw1 & 0xFF) * 4);
    }
    if (instruction.size == 4 and instruction.hw1 & 0xFF7F == 0xF85F) {
        const offset: u32 = instruction.hw2 & 0xFFF;
        return if (instruction.hw1 & 0x80 != 0) pc +% offset else pc -% offset;
    }
    return null;
}

fn ordinary(address_value: u32) bool {
    for (chip.core.memmap.ram) |region| {
        if (region.perms.exec and address_value >= region.base and
            @as(u64, address_value) + 4 <= region.end()) return true;
    }
    return false;
}
