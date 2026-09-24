# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Brighton Sikarskie
#
# RA8D2 board emulator -- companion dev tool.
#
# Loads an EK-RA8D2 firmware ELF into an emulated Cortex-M memory map (Unicorn)
# and boots it, with the RA8D2 peripheral space as logged MMIO and SysTick
# ticked cooperatively so delays advance. Standalone dev tool under tools/,
# outside the firmware CI gates.
#
# cmake -B build -S . && cmake --build build -j
# ./build/ra8_emulator path/to/app.elf
#
# Needs Unicorn + Capstone (Linux: libunicorn-dev + libcapstone-dev, or a source
# install, found via pkg-config; macOS: Homebrew Capstone plus a source build of
# the pinned Unicorn) and a C23 compiler: GCC 13 or Clang 16 and newer. The
# ambient `cc` on Debian 12 is GCC 12 and cannot parse this source, so the
# preflight below refuses it by name rather than letting the build fail deep.
#

cmake_minimum_required(VERSION 3.20)

# Objective-C (board_view.m) is the macOS live-window backend ONLY, and an OBJC
# compiler / AppKit may be absent on a Linux CI runner. Enable C unconditionally
# and add OBJC only on APPLE, where board_view.m is actually compiled.
project(ra8_emulator LANGUAGES C)
if(APPLE)
  if(NOT DEFINED CMAKE_OBJC_COMPILER OR CMAKE_OBJC_COMPILER MATCHES "gcc")
    set(CMAKE_OBJC_COMPILER
        "/usr/bin/clang"
        CACHE FILEPATH "Objective-C compiler for the Cocoa board view" FORCE
    )
  endif()
  enable_language(OBJC)
endif()

set(CMAKE_C_STANDARD 23)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# C23 preflight. `cmake -B build -S .` selects the ambient `cc`, which on Debian
# 12 is GCC 12: it cannot parse a typed enum or `nullptr`, both of which this
# source tree uses throughout (525 typed enums, 403 `nullptr`s at the time of
# writing). Without this check GCC 12 fails deep in the build with a scatter of
# unused-variable and return-type diagnostics that read like defects in the
# source and are not. Compile the two constructs here instead and refuse up
# front, naming a compiler on this machine that does work.
#
# The source is valid C23 and stays that way; nothing below is ever "fixed" to
# suit a compiler that cannot read the language. CI selects its own pinned,
# C23-capable compiler, so this check simply passes there. Set
# -DRA8_C23_PREFLIGHT=OFF to skip it.
option(RA8_C23_PREFLIGHT "Refuse to configure with a compiler that cannot parse C23" ON)
if(RA8_C23_PREFLIGHT)
  set(RA8_C23_PROBE "${CMAKE_CURRENT_BINARY_DIR}/ra8_c23_probe.c")
  file(
    WRITE ${RA8_C23_PROBE}
    "#include <stdint.h>\n"
    "typedef enum : uint32_t { k_probe = 1U } probe_t;\n"
    "[[nodiscard]] static void* probe(void) { return nullptr; }\n"
    "int main(void) { return (probe() == nullptr) ? (int)(k_probe - 1U) : 1; }\n"
  )
  try_compile(
    RA8_C23_OK ${CMAKE_CURRENT_BINARY_DIR}/ra8_c23_probe SOURCES ${RA8_C23_PROBE}
    C_STANDARD 23 C_STANDARD_REQUIRED ON
    OUTPUT_VARIABLE RA8_C23_PROBE_LOG
  )
  if(NOT RA8_C23_OK)
    # Name something on this machine that would work, rather than leaving the
    # reader to guess at a version.
    set(RA8_C23_CANDIDATES "")
    foreach(cand gcc-15 gcc-14 gcc-13 clang-20 clang-19 clang-18 clang-17 clang-16)
      find_program(RA8_CAND_${cand} ${cand})
      if(RA8_CAND_${cand})
        list(APPEND RA8_C23_CANDIDATES "${RA8_CAND_${cand}}")
      endif()
    endforeach()
    if(RA8_C23_CANDIDATES)
      list(JOIN RA8_C23_CANDIDATES "\n    " RA8_C23_FOUND)
      set(RA8_C23_HINT "Compilers on this machine that should work:\n    ${RA8_C23_FOUND}")
    else()
      set(RA8_C23_HINT "No C23-capable compiler was found on this machine; install one.")
    endif()
    message(
      FATAL_ERROR
        "${CMAKE_C_COMPILER_ID} ${CMAKE_C_COMPILER_VERSION} (${CMAKE_C_COMPILER}) cannot compile "
        "this project.\n"
        "It is written in C23 and uses typed enums and nullptr throughout. The oldest compilers "
        "that parse both are GCC 13 and Clang 16 (Apple clang 15).\n"
        "${RA8_C23_HINT}\n"
        "Select one with a fresh build directory, for example:\n"
        "    cmake -B build -S . -DCMAKE_C_COMPILER=gcc-13\n"
        "    CC=clang-16 cmake -B build -S .\n"
        "This is a compiler limitation, not a defect in the source: do not change the code to "
        "suit an older compiler. Set -DRA8_C23_PREFLIGHT=OFF to skip this check."
    )
  endif()
endif()

# Homebrew supplies Capstone on macOS. The pinned Unicorn source build lives in
# a user-local prefix by default so cloning the repository never requires sudo.
if(APPLE)
  find_program(BREW_EXECUTABLE brew HINTS /opt/homebrew/bin /usr/local/bin)
  if(BREW_EXECUTABLE)
    execute_process(
      COMMAND ${BREW_EXECUTABLE} --prefix
      OUTPUT_VARIABLE BREW
      OUTPUT_STRIP_TRAILING_WHITESPACE
    )
  endif()
  set(RA8_UNICORN_PREFIX "$ENV{RA8_UNICORN_PREFIX}")
  if(NOT RA8_UNICORN_PREFIX)
    set(RA8_UNICORN_PREFIX "$ENV{HOME}/.local/ra8-firmware/unicorn")
  endif()
  # A prior configuration may have cached Homebrew Unicorn. Always rediscover
  # the source-built pinned prefix after `just apps::emulator::setup`.
  unset(UNICORN_INCLUDE_DIR CACHE)
  unset(UNICORN_LIBRARY CACHE)
endif()

# board_view is the optional live board window: the Cocoa backend (board_view.m)
# on macOS, the headless no-op shim (board_view_stub.c) everywhere else. Both
# satisfy the same plain-C ABI in board_view.h, so exactly one is compiled and
# the non-APPLE build links zero AppKit/CoreGraphics symbols; --view then
# cleanly falls back to headless (board_view_open returns nullptr and main.c
# continues without a window). board_periph.c is the peripheral-block registry
# CORE (block dispatch + ICU/NVIC routing); each board_periph_<blk>.c is one
# register-accurate peripheral block that self-registers with the core
# (GPIO/PORT, GPT+AGT timers, SCI_B UART, I3C/I2C+GT911, ...); board_usb.c is
# the USBFS controller model + virtual host (chapter-9 enumeration);
# board_overlay.c composes the panel + status-sidebar board view into one RGB565
# buffer for both --view and --ppm; rest is C.
#
# Adding a peripheral block: just drop a new src/board_periph_<blk>.c (it
# self-registers its descriptor with the core via [[gnu::constructor]] -- see
# board_periph_block.h). The glob below picks it up automatically; the core
# keeps no central block list, so blocks can be added in parallel with no edit
# to this file and no conflict.
file(GLOB BOARD_PERIPH_BLOCKS CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/src/periph/board_periph_*.c"
)

if(APPLE)
  set(BOARD_VIEW_SRC src/display/board_view.m src/display/board_view_provider.c)
else()
  set(BOARD_VIEW_SRC src/display/board_view_stub.c)
endif()

add_executable(
  ra8_emulator
  src/main.c
  src/host/emu_host_io.c
  src/engine/emu_console.c
  src/engine/emu_elf.c
  src/engine/emu_elf_reboot.c
  src/engine/emu_elf_source.c
  src/engine/emu_elf_symbols.c
  src/engine/emu_engine.c
  src/engine/emu_memmap.c
  src/engine/emu_memory_access.c
  src/engine/emu_mmio.c
  src/engine/emu_mpu.c
  src/engine/emu_prof.c
  src/engine/emu_presentation.c
  src/engine/emu_args.c
  src/engine/emu_run.c
  src/engine/emu_run_guards.c
  src/engine/emu_run_inner.c
  src/engine/emu_run_report.c
  src/engine/emu_trace.c
  src/engine/emu_tz.c
  src/engine/emu_view.c
  src/engine/emu_view_surface.c
  src/engine/emu_view_tile.c
  src/engine/emu_usbh_seam.c
  src/engine/emu_cpu1.c
  src/engine/emu_exc.c
  src/engine/emu_exc_scs.c
  src/engine/emu_idle.c
  src/engine/emu_insn_seams.c
  src/engine/emu_seam_div0.c
  src/engine/emu_seam_longshift.c
  src/engine/emu_seam_sd.c
  src/engine/emu_seam_mve.c
  src/periph/board_periph.c
  ${BOARD_PERIPH_BLOCKS}
  src/usb/board_usb.c
  src/usb/board_usb_bridge.c
  src/usb/board_usb_dev.c
  src/usb/board_usb_loop.c
  src/usb/board_usb_vhost.c
  src/usb/board_usb_host.c
  src/io/board_net.c
  src/display/board_overlay.c
  src/display/board_overlay_draw.c
  src/display/board_view_pixels.c
  src/io/board_console.c
  src/io/board_input.c
  ${BOARD_VIEW_SRC}
)

if(APPLE)
  set_source_files_properties(src/display/board_view.m PROPERTIES COMPILE_FLAGS "-fobjc-arc")
endif()

# The USB model includes the firmware's register/ELC headers for the exact
# offsets + ELC event numbers it must mirror (ra8_usb_regs.h, ra8_elc_regs.h);
# ra8_core/inc supplies ra8_attributes.h for the RA8_PRIV annotations on the
# emu_* module-private cross-TU helpers.
target_include_directories(
  ra8_emulator
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/inc
)

# Unicorn + Capstone discovery. macOS checks the source-built user prefix before
# Homebrew, while CMAKE_PREFIX_PATH remains available for custom setups.
find_path(
  UNICORN_INCLUDE_DIR unicorn/unicorn.h
  HINTS ${RA8_UNICORN_PREFIX} ${BREW}
  PATH_SUFFIXES include REQUIRED
)
find_path(
  CAPSTONE_INCLUDE_DIR capstone/capstone.h
  HINTS ${BREW}
  PATH_SUFFIXES include REQUIRED
)
find_library(
  UNICORN_LIBRARY unicorn
  HINTS ${RA8_UNICORN_PREFIX} ${BREW}
  PATH_SUFFIXES lib REQUIRED
)
find_library(
  CAPSTONE_LIBRARY capstone
  HINTS ${BREW}
  PATH_SUFFIXES lib REQUIRED
)
target_include_directories(ra8_emulator PRIVATE ${UNICORN_INCLUDE_DIR} ${CAPSTONE_INCLUDE_DIR})
target_link_libraries(ra8_emulator PRIVATE ${UNICORN_LIBRARY} ${CAPSTONE_LIBRARY})

if(APPLE)
  set_property(TARGET ra8_emulator PROPERTY BUILD_RPATH "${RA8_UNICORN_PREFIX}/lib")
endif()

if(APPLE)
  target_link_libraries(
    ra8_emulator PRIVATE "-framework Cocoa" "-framework QuartzCore" "-framework CoreGraphics"
  )
endif()

target_compile_options(ra8_emulator PRIVATE -Wall -Wextra -Werror)

include(CTest)
if(BUILD_TESTING)
  add_executable(test_emu_host_io tests/src/test_emu_host_io.c src/host/emu_host_io.c)
  target_include_directories(
    test_emu_host_io PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/inc
  )
  target_compile_options(test_emu_host_io PRIVATE -Wall -Wextra -Werror)
  add_test(NAME test_emu_host_io COMMAND test_emu_host_io)

  add_executable(
    test_emu_presentation
    tests/src/test_emu_presentation.c
    src/host/emu_host_io.c
    src/engine/emu_presentation.c
    src/engine/emu_view_tile.c
    src/display/board_overlay.c
    src/display/board_overlay_draw.c
    src/display/board_view_pixels.c
  )
  target_include_directories(
    test_emu_presentation
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/inc
            ${UNICORN_INCLUDE_DIR}
  )
  target_link_libraries(test_emu_presentation PRIVATE ${UNICORN_LIBRARY})
  target_compile_options(test_emu_presentation PRIVATE -Wall -Wextra -Werror)
  add_test(NAME test_emu_presentation COMMAND test_emu_presentation)

  add_executable(
    test_emu_elf_source
    tests/src/test_emu_elf_source.c
    src/engine/emu_memory_access.c
    src/host/emu_host_io.c
    src/engine/emu_elf.c
    src/engine/emu_elf_source.c
    src/engine/emu_elf_symbols.c
  )
  target_include_directories(
    test_emu_elf_source
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/inc
            ${UNICORN_INCLUDE_DIR}
  )
  target_link_libraries(test_emu_elf_source PRIVATE ${UNICORN_LIBRARY})
  target_compile_options(test_emu_elf_source PRIVATE -Wall -Wextra -Werror)
  add_test(NAME test_emu_elf_source COMMAND test_emu_elf_source)

  add_executable(
    test_emu_memmap tests/src/test_emu_memmap.c src/host/emu_host_io.c src/engine/emu_memmap.c
                    src/engine/emu_memory_access.c
  )
  target_include_directories(
    test_emu_memmap
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/inc
            ${UNICORN_INCLUDE_DIR}
  )
  target_link_libraries(test_emu_memmap PRIVATE ${UNICORN_LIBRARY})
  target_compile_options(test_emu_memmap PRIVATE -Wall -Wextra -Werror)
  add_test(NAME test_emu_memmap COMMAND test_emu_memmap)

  add_executable(
    test_emu_mve_vmov tests/src/test_emu_mve_vmov.c src/engine/emu_engine.c
                      src/engine/emu_memory_access.c src/host/emu_host_io.c
  )
  target_include_directories(
    test_emu_mve_vmov
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/inc
            ${CMAKE_CURRENT_SOURCE_DIR}/src/engine
            ${UNICORN_INCLUDE_DIR}
  )
  target_link_libraries(test_emu_mve_vmov PRIVATE ${UNICORN_LIBRARY})
  target_compile_options(test_emu_mve_vmov PRIVATE -Wall -Wextra -Werror)
  add_test(NAME test_emu_mve_vmov COMMAND test_emu_mve_vmov)

  add_executable(
    test_board_sd_storage tests/src/test_board_sd_storage.c src/host/emu_host_io.c
                          src/periph/board_periph_sd_image.c src/periph/board_periph_sd_format.c
  )
  target_include_directories(
    test_board_sd_storage PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/inc
  )
  target_compile_options(test_board_sd_storage PRIVATE -Wall -Wextra -Werror)
  add_test(NAME test_board_sd_storage COMMAND test_board_sd_storage)
endif()
