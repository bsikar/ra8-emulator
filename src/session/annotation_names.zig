//! Exact names from the same register/constant namespaces the chip models use.
const chip = @import("ra8_chip");

const map = chip.core.memmap;

pub fn find(value: u32) ?[]const u8 {
    if (namespace(map.scb, "SCB", value)) |name| return name;
    if (namespace(map.syst, "SysTick", value)) |name| return name;
    if (namespace(map.nvic, "NVIC", value)) |name| return name;
    if (model(chip.periph.rtc, "RTC", value)) |name| return name;
    if (model(chip.periph.iwdt, "IWDT", value)) |name| return name;
    if (value == chip.periph.scb.key.write) return "SCB.VECTKEY";
    if (value == chip.periph.scb.key.status) return "SCB.VECTKEYSTAT";
    return null;
}

fn namespace(comptime T: type, comptime prefix: []const u8, value: u32) ?[]const u8 {
    inline for (@typeInfo(T).@"struct".decl_names) |name| {
        if (@TypeOf(@field(T, name)) == u32 and @field(T, name) == value) return prefix ++ "." ++ name;
    }
    return null;
}

fn model(comptime T: type, comptime prefix: []const u8, value: u32) ?[]const u8 {
    inline for (@typeInfo(T.off).@"struct".decl_names) |name| {
        if (@TypeOf(@field(T.off, name)) == u32 and T.win_base + @field(T.off, name) == value) {
            return prefix ++ "." ++ name;
        }
    }
    return null;
}
