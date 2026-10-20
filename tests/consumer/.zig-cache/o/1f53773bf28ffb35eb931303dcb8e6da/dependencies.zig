pub const packages = struct {
    pub const @"../.." = struct {
        pub const build_root = "../..";
        pub const build_zig = @import("../..");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "ra8_firmware", "ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1" },
            .{ "sdl", "sdl-0.5.4+3.4.16-SDL--sQ4qAH3kwC19Zs1kxdHplaSDnWl2MUptZD4AItI" },
            .{ "translate_c", "translate_c-0.0.0-Q_BUWoFOBwAhz77Zd15HCVuhTKzdUKc94kezmCeJ7IC_" },
        };
    };
    pub const @"N-V-__8AABnHqwH0WNMqhd6EOZNeMNA60iRlcWUh_osHYQKZ" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AABzBxwBMl4El_S7LHuoUmX_djbnoBjd-bFivTVUO" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AACeHVAWQnalf6pLkI_X_OgjmjhX_AXiqy625pqeO" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAF8UUQDfw2gf77-gAA8_kdu0idv5S00VssPCWByg" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAGSoDQDB0db5wTeihbe1fdhAZxfHTxNomUA-QNfC" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAGXETQH82E7iW1WCWsDfDOuaNu545OeJ4Z_ffPs6" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAGXukwCsPZWLszqjHEq2BSv7gwvQcmCQ8FZ3C7BA" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAHM2GQD1bQLoOLlEhGDOEM8O1g0jjvII9F_PUyat" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAMeECgBRiKccCTAGJTRwB5LP6QVHDxHj_SQxBofe" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAONGfwDjjMjSEyow7xCaH-cj9BOe1iHzR_n4TxFQ" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAOXoRQGfmvONnuF6PJBJcnL5BhJXM69TKQ9f_w3A" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAPZtwAhYa3pneorsST1dPMt0UEWk2_bDy9Cdc3To" = struct {
        pub const available = false;
    };
    pub const @"N-V-__8AAPk7yQDK2oreQ5VXoxAgGf5nMpSFAB6_6Dialtw4" = struct {
        pub const available = false;
    };
    pub const @"aro-0.0.0-JSD1QtuBNwCASyBtNF3pqTl_W3oAJQGEVyFAtrBSE_Pa" = struct {
        pub const build_root = "zig-pkg/aro-0.0.0-JSD1QtuBNwCASyBtNF3pqTl_W3oAJQGEVyFAtrBSE_Pa";
        pub const build_zig = @import("aro-0.0.0-JSD1QtuBNwCASyBtNF3pqTl_W3oAJQGEVyFAtrBSE_Pa");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1";
        pub const build_zig = @import("ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "ra8_box", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_box" },
            .{ "ra8_power_profile", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_power_profile" },
            .{ "ra8_epd_cal", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_epd_cal" },
            .{ "ra8_imgdec", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_imgdec" },
            .{ "ra8_core", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_core" },
            .{ "ra8_board_ek_ra8d2", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_board_ek_ra8d2" },
            .{ "ra8_board_ra8p1", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_board_ra8p1" },
            .{ "ra8_mem", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_mem" },
            .{ "ra8_dfu", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_dfu" },
            .{ "ra8_rot", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_rot" },
            .{ "ra8_rot_launch", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_rot_launch" },
            .{ "ra8_dfu_device", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_dfu_device" },
            .{ "ra8_psa_crypto", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_psa_crypto" },
            .{ "ra8_sdmmc_spi", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_sdmmc_spi" },
            .{ "ra8_tz_secure_boot", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_tz_secure_boot" },
            .{ "ra8_usb_pal", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_usb_pal" },
            .{ "ra8_hal", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_hal" },
            .{ "ra8_io", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_io" },
            .{ "ra8_fs", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_fs" },
            .{ "if_ra8_cgc", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/if_ra8_cgc" },
            .{ "if", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/if" },
            .{ "ra8_abi_fixture", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tests/zig_abi_fixture" },
            .{ "translate_c", "translate_c-0.0.0-Q_BUWoFOBwAhz77Zd15HCVuhTKzdUKc94kezmCeJ7IC_" },
            .{ "flatbuffers", "N-V-__8AABzBxwBMl4El_S7LHuoUmX_djbnoBjd-bFivTVUO" },
            .{ "gemmlowp", "N-V-__8AAF8UUQDfw2gf77-gAA8_kdu0idv5S00VssPCWByg" },
            .{ "ruy", "N-V-__8AAHM2GQD1bQLoOLlEhGDOEM8O1g0jjvII9F_PUyat" },
            .{ "tflite_micro", "N-V-__8AABnHqwH0WNMqhd6EOZNeMNA60iRlcWUh_osHYQKZ" },
            .{ "esp_hosted", "N-V-__8AAPk7yQDK2oreQ5VXoxAgGf5nMpSFAB6_6Dialtw4" },
            .{ "protobuf_c", "N-V-__8AAMeECgBRiKccCTAGJTRwB5LP6QVHDxHj_SQxBofe" },
            .{ "nimble", "N-V-__8AAGXukwCsPZWLszqjHEq2BSv7gwvQcmCQ8FZ3C7BA" },
            .{ "netxduo", "N-V-__8AAPZtwAhYa3pneorsST1dPMt0UEWk2_bDy9Cdc3To" },
            .{ "threadx", "N-V-__8AACeHVAWQnalf6pLkI_X_OgjmjhX_AXiqy625pqeO" },
            .{ "mbedtls", "N-V-__8AAONGfwDjjMjSEyow7xCaH-cj9BOe1iHzR_n4TxFQ" },
            .{ "tf_psa_crypto", "N-V-__8AAGXETQH82E7iW1WCWsDfDOuaNu545OeJ4Z_ffPs6" },
            .{ "usbx", "N-V-__8AAOXoRQGfmvONnuF6PJBJcnL5BhJXM69TKQ9f_w3A" },
            .{ "levelx", "N-V-__8AAGSoDQDB0db5wTeihbe1fdhAZxfHTxNomUA-QNfC" },
        };
    };
    pub const @"sdl-0.5.4+3.4.16-SDL--sQ4qAH3kwC19Zs1kxdHplaSDnWl2MUptZD4AItI" = struct {
        pub const available = false;
    };
    pub const @"translate_c-0.0.0-Q_BUWoFOBwAhz77Zd15HCVuhTKzdUKc94kezmCeJ7IC_" = struct {
        pub const build_root = "zig-pkg/translate_c-0.0.0-Q_BUWoFOBwAhz77Zd15HCVuhTKzdUKc94kezmCeJ7IC_";
        pub const build_zig = @import("translate_c-0.0.0-Q_BUWoFOBwAhz77Zd15HCVuhTKzdUKc94kezmCeJ7IC_");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "aro", "aro-0.0.0-JSD1QtuBNwCASyBtNF3pqTl_W3oAJQGEVyFAtrBSE_Pa" },
        };
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/if" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/if";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/if");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "translate_c", "translate_c-0.0.0-Q_BUWoFOBwAhz77Zd15HCVuhTKzdUKc94kezmCeJ7IC_" },
        };
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/if_ra8_cgc" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/if_ra8_cgc";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/if_ra8_cgc");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_board_ek_ra8d2" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_board_ek_ra8d2";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_board_ek_ra8d2");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_board_ra8p1" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_board_ra8p1";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_board_ra8p1");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_box" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_box";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_box");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_core" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_core";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_core");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_dfu" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_dfu";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_dfu");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_dfu_device" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_dfu_device";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_dfu_device");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_epd_cal" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_epd_cal";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_epd_cal");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_fs" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_fs";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_fs");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "ra8_zig_build", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tools/zig_build" },
            .{ "translate_c", "translate_c-0.0.0-Q_BUWoFOBwAhz77Zd15HCVuhTKzdUKc94kezmCeJ7IC_" },
        };
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_hal" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_hal";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_hal");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "ra8_zig_build", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tools/zig_build" },
        };
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_imgdec" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_imgdec";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_imgdec");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_io" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_io";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_io");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "ra8_zig_build", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tools/zig_build" },
        };
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_mem" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_mem";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_mem");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_power_profile" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_power_profile";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_power_profile");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_psa_crypto" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_psa_crypto";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_psa_crypto");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "translate_c", "translate_c-0.0.0-Q_BUWoFOBwAhz77Zd15HCVuhTKzdUKc94kezmCeJ7IC_" },
            .{ "mbedtls", "N-V-__8AAONGfwDjjMjSEyow7xCaH-cj9BOe1iHzR_n4TxFQ" },
            .{ "tf_psa_crypto", "N-V-__8AAGXETQH82E7iW1WCWsDfDOuaNu545OeJ4Z_ffPs6" },
        };
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_rot" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_rot";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_rot");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_rot_launch" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_rot_launch";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_rot_launch");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_sdmmc_spi" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_sdmmc_spi";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_sdmmc_spi");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_tz_secure_boot" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_tz_secure_boot";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_tz_secure_boot");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_usb_pal" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_usb_pal";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/libs/ra8_usb_pal");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tests/zig_abi_fixture" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tests/zig_abi_fixture";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tests/zig_abi_fixture");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
            .{ "ra8_zig_build", "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tools/zig_build" },
        };
    };
    pub const @"zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tools/zig_build" = struct {
        pub const build_root = "zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tools/zig_build";
        pub const build_zig = @import("zig-pkg/ra8_firmware-0.1.0-HagwjdUPCwr40zx3eP1hnxDxA5eV-6kdq36QOJKZ2yN1/tools/zig_build");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "ra8_emulator", "../.." },
};
