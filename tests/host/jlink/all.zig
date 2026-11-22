test {
    _ = @import("emu_list_test.zig");
    _ = @import("identity_test.zig");
    _ = @import("run_test.zig");
    _ = @import("elf_image_test.zig");
    _ = @import("commander_test.zig");
    _ = @import("uart_test.zig");
    _ = @import("uart/linux_test.zig");
    _ = @import("uart/macos_test.zig");
    _ = @import("uart/windows_test.zig");
    _ = @import("serial_test.zig");
    _ = @import("serial/linux_test.zig");
    _ = @import("serial/macos_test.zig");
    _ = @import("serial/windows_test.zig");
}
