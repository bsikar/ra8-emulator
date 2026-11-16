"""Build an example using a local ra8-firmware checkout and its libraries."""
import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

APPS = {'uart': 'uart_irq_echo', 'sections': 'fault_crashlog_hil',
        'dfu': 'dfu_bootloader', 'signed_boot': 'dfu_bootloader',
        'threadx': 'threadx_stkof', 'trustzone/cpu1_pingpong_ipc': 'cpu1_pingpong_ipc',
        'trustzone/tz_nsc_cgc_usb': 'tz_nsc_cgc_usb', 'display': 'ra8_ui'}


def run(args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def host_compatibility(firmware, work, zig, env):
    if sys.platform != 'darwin' or subprocess.check_output([zig, 'version'], text=True).strip() != '0.14.1':
        return
    path = firmware / 'tools/zig_build/build.zig'
    old = '''return switch (builtin.os.version_range) {
        .semver => |range| range.min,
        else => null,
    };'''
    if path.exists():
        path.write_text(path.read_text().replace(old, 'return builtin.os.version_range.semver.min;'))
    sdk = Path(subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
    private = work / 'host-sdk'
    (private / 'usr/lib').mkdir(parents=True)
    shutil.copyfile(Path(zig).parent / 'lib/libc/darwin/libSystem.tbd', private / 'usr/lib/libSystem.tbd')
    (private / 'usr/include').symlink_to(sdk / 'usr/include')
    (private / 'System').symlink_to(sdk / 'System')
    tools = work / 'host-tools'
    tools.mkdir()
    xcrun = tools / 'xcrun'
    xcrun.write_text('#!/bin/sh\ncase "$*" in\n'
                     " '--sdk macosx --show-sdk-path'|'--show-sdk-path') echo " + shlex.quote(str(private)) +
                     ' ;;\n *) exec /usr/bin/xcrun "$@" ;;\nesac\n')
    xcrun.chmod(0o700)
    env['PATH'] = str(tools) + os.pathsep + env['PATH']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', choices=APPS)
    parser.add_argument('--firmware', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent / 'build')
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--arm-bin', type=Path, required=True)
    args = parser.parse_args()
    base = Path(__file__).resolve().parent
    if not (args.firmware / 'cmake/ra8_add_app.cmake').is_file():
        parser.error('--firmware must point to a ra8-firmware checkout')
    if not (args.arm_bin / 'arm-none-eabi-gcc').is_file():
        parser.error('--arm-bin must contain arm-none-eabi-gcc')
    work = args.output.resolve() / args.app
    if work == base or base in work.parents and 'build' not in work.relative_to(base).parts:
        parser.error('use the build directory or an external output directory')
    work.mkdir(parents=True, exist_ok=False)
    zig = shutil.which(args.zig)
    if zig is None:
        parser.error('Zig executable not found')
    zig = str(Path(zig).resolve())
    arm = args.arm_bin.resolve()
    env = os.environ.copy()
    env['PATH'] = str(arm) + os.pathsep + str(Path(zig).parent) + os.pathsep + env.get('PATH', '')
    env['GIT_LFS_SKIP_SMUDGE'] = '1'
    firmware = work / 'ra8-firmware'
    revision = subprocess.check_output(['git', '-C', str(args.firmware.resolve()), 'rev-parse', 'HEAD'], text=True).strip()
    run(['git', 'clone', '--no-hardlinks', '--no-checkout', args.firmware.resolve(), firmware], env=env)
    run(['git', '-C', firmware, 'checkout', '--detach', revision], env=env)
    host_compatibility(firmware, work, zig, env)
    local = base / args.app
    if args.app == 'display':
        for name in ('app', 'board'):
            shutil.copytree(local / name, work / name)
        for name in ('build.zig', 'build.zig.zon', 'image_build.zig'):
            shutil.copyfile(local / name, work / name)
        for path in (work / 'app').glob('*.zig'):
            text = path.read_text().replace('@backingInt(', '@intFromEnum(')
            text = text.replace('@fromBackingInt(@intCast(@as(u8, @intCast(action_id & id_mask))))',
                                '@enumFromInt(@as(u8, @intCast(action_id & id_mask)))')
            path.write_text(text)
        run([zig, 'build', 'image', '-j1', '-Darm-gnu-toolchain=' + str(arm)], cwd=work, env=env)
        run([arm / 'arm-none-eabi-strip', '--strip-debug', '-o', work / 'ra8_ui.elf',
             work / 'zig-out/image/ra8_ui.elf'])
        return
    candidates = [path for path in (firmware / 'examples').rglob(APPS[args.app]) if (path / 'src').is_dir()]
    if len(candidates) != 1:
        raise ValueError('firmware checkout must contain the matching example application')
    app = candidates[0]
    if (local / 'CMakeLists.txt').exists():
        shutil.copyfile(local / 'CMakeLists.txt', app / 'CMakeLists.txt')
    for name in ('src', 'inc', 'scripts'):
        if (local / name).exists():
            shutil.copytree(local / name, app / name, dirs_exist_ok=True)
    if (local / 'libs').exists():
        shutil.copytree(local / 'libs', firmware / 'libs', dirs_exist_ok=True)
    if args.app == 'threadx':
        graph = firmware / 'tests/zig_build_graph/cross_image.zig'
        old = 'for (cross_sources.cross_apps) |app| addCrossApp(b, arm_step, tools, app, globals);'
        text = graph.read_text()
        if text.count(old) != 1:
            raise ValueError('firmware build graph does not match the ThreadX example')
        graph.write_text(text.replace(old, 'for (cross_sources.cross_apps) |app| {\n'
                                      'if (std.mem.eql(u8, app.name, "threadx_stkof")) '
                                      'addCrossApp(b, arm_step, tools, app, globals);\n}'))
        run([zig, 'build', 'arm', '-j1'], cwd=firmware, env=env)
        run([arm / 'arm-none-eabi-strip', '--strip-debug', '-o', work / 'threadx_stkof.elf',
             firmware / 'zig-out/arm/threadx_stkof.elf'])
    else:
        build = work / 'cmake'
        run(['cmake', '-S', app, '-B', build, '-G', 'Ninja',
             '-DCMAKE_TOOLCHAIN_FILE=' + str(firmware / 'cmake/toolchain-ra8d2.cmake'),
             '-DRA8_ARM_TOOLCHAIN_BIN=' + str(arm), '-DCMAKE_BUILD_TYPE=MinSizeRel'], env=env)
        run(['cmake', '--build', build, '-j2'], env=env)
        for elf in build.glob('*.elf'):
            shutil.copyfile(elf, work / elf.name)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
