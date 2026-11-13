//! Source-built firmware for public debugger conformance, separate from execution.
const std = @import("std");

pub fn add(b: *std.Build) void {
    const step = b.step("debug-fixtures", "Build deterministic debugger conformance firmware");
    const images = .{
        .{ "debug_conformance.elf", "conformance.zig", "link.ld", &std.Target.arm.cpu.cortex_m85 },
        .{ "debug_fault.elf", "fault.zig", "link.ld", &std.Target.arm.cpu.cortex_m85 },
        .{ "debug_cpu1.elf", "cpu1.zig", "link_cpu1.ld", &std.Target.arm.cpu.cortex_m33 },
        .{ "debug_peripheral.elf", "peripheral.zig", "link.ld", &std.Target.arm.cpu.cortex_m85 },
    };
    inline for (images) |image| {
        const target = b.resolveTargetQuery(.{
            .cpu_arch = .thumb,
            .os_tag = .freestanding,
            .abi = .eabihf,
            .cpu_model = .{ .explicit = image[3] },
        });
        const guest = b.addExecutable(.{
            .name = image[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/fixtures/debug/" ++ image[1]),
                .target = target,
                .optimize = .Debug,
                .strip = false,
                .omit_frame_pointer = false,
                .sanitize_c = .off,
            }),
        });
        guest.setLinkerScript(b.path("tests/fixtures/debug/" ++ image[2]));
        guest.entry = .{ .symbol_name = "Reset_Handler" };
        guest.link_function_sections = true;
        guest.link_gc_sections = true;
        step.dependOn(&b.addInstallArtifact(guest, .{}).step);
    }
}
