"""Build local Cortex-M85/M33 examples with Zig 0.17.0."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

RECIPES = {
    "audio/tone": dict(kind="direct", source="audio/tone.zig", script="audio/tone.ld", abi="eabi"),
    "console/echo": dict(source="console/echo.zig", script="console/echo.ld"),
    "gpio/blink": dict(source="gpio/blink.zig", script="gpio/gpio.ld"),
    "gpio/buttons": dict(source="gpio/buttons.zig", script="gpio/gpio.ld"),
    "plug/gauge_poll": dict(source="plug/gauge_poll.zig", script="plug/plug.ld"),
    "plug/gauge_uart": dict(source="plug/gauge_uart.zig", script="plug/plug.ld", abi="eabi", legacy_link=True),
    "touch/touch": dict(source="touch/touch.zig", script="touch/touch.ld"),
    "profile/call_tree": dict(source="profile/call_tree.zig", script="profile/call_tree.ld", profile=True),
    "sizing/ext_stream": dict(source="sizing/ext_stream.zig", script="fpu/fpu.ld",
                              startup="fpu/startup.S", symbols=True),
    "pacbti/pacbti_smoke": dict(kind="assembly", source="pacbti/pacbti_smoke.S",
                               script="pacbti/pacbti.ld", startup="pacbti/startup.S"),
    **{f"fpu/{name}": dict(source=f"fpu/{name}.zig", script="fpu/fpu.ld", startup="fpu/startup.S",
                           cpu="cortex_m85+fp_armv8d16+fullfp16")
       for name in ("fp_basic", "fp_cmp", "fp_cvt", "fp_modes")},
    **{f"fpu/{name}": dict(source=f"fpu/{name}.zig", script="fpu/fpu.ld", startup="fpu/startup.S",
                           cpu="cortex_m85+mve_fp+fp_armv8d16+fullfp16", optimize="ReleaseFast")
       for name in ("lob", "dsp", "nnf")},
    "profile/call_tree_unstripped": dict(kind="guest", source="profile/call_tree.zig",
                                         script="profile/call_tree.ld"),
    "profile/call_tree_cpu1": dict(kind="guest", source="profile/call_tree_cpu1.zig",
                                  script="profile/call_tree_cpu1.ld"),
    "profile/two_threads": dict(kind="guest", source="profile/two_threads.zig",
                                script="profile/two_threads.ld"),
    "threadx/threadx_dual": dict(kind="guest", source="threadx/threadx_dual.zig",
                                script="profile/two_threads.ld"),
    "threadx/threadx_dual_cpu1": dict(kind="guest", source="threadx/threadx_dual_cpu1.zig",
                                     script="threadx/threadx_dual_cpu1.ld"),
    **{f"debug/{name}": dict(kind="guest", source=f"debug/{name}.zig", debug=True,
                             script="debug/link_cpu1.ld" if name == "cpu1" else "debug/link.ld",
                             cpu="cortex_m33" if name == "cpu1" else "cortex_m85", optimize="Debug")
       for name in ("conformance", "fault", "peripheral", "cpu1")},
}


def _recipe_commands(recipe, base, work, destination, zig):
    source, script = base / recipe["source"], base / recipe["script"]
    target = ["-target", "thumb-freestanding-" + recipe.get("abi", "eabihf"),
              "-mcpu=" + recipe.get("cpu", "cortex_m85")]
    optimize = recipe.get("optimize", "ReleaseSmall")
    if recipe.get("kind") == "guest":
        flags = ["-fno-strip", "-fentry=Reset_Handler"]
        if recipe.get("debug"):
            flags += ["-fno-omit-frame-pointer", "-fno-sanitize-c", "-ffunction-sections", "--gc-sections"]
        return [[zig, "build-exe", *target, "-O", optimize, *flags, "--script", str(script),
                 str(source), "-femit-bin=" + str(destination)]]
    if recipe.get("kind") == "direct":
        return [[zig, "build-exe", *target, "-O", optimize, "-fno-stack-check", "-fstrip",
                 "-fno-compiler-rt", "-fno-entry", "-z", "max-page-size=4", "--script", str(script),
                 str(source), "-femit-bin=" + str(destination)]]
    objects, commands = [], []
    if "startup" in recipe:
        startup = work / "startup.o"
        commands.append([zig, "cc", *target, "-c", str(base / recipe["startup"]), "-o", str(startup)])
        objects.append(str(startup))
    obj = work / "body.o"
    if recipe.get("kind") == "assembly":
        commands.append([zig, "cc", *target, "-c", str(source), "-o", str(obj)])
    else:
        compiler = [zig, "build-obj", *target, "-O", optimize]
        if recipe.get("profile"):
            compiler += ["-fstrip"]
        else:
            compiler += ["-fno-stack-check", "-fno-compiler-rt"]
            if not recipe.get("legacy_link"):
                compiler += ["-ffunction-sections"]
            if not recipe.get("symbols"):
                compiler += ["-fstrip"]
        commands.append([*compiler, str(source), "-femit-bin=" + str(obj)])
    objects.append(str(obj))
    link = [zig, "cc", *target, "-nostdlib", "-Wl,-e,Reset_Handler"]
    if recipe.get("profile"):
        link += ["-Wl,-z,max-page-size=16"]
    elif not recipe.get("legacy_link"):
        link += ["-Wl,--build-id=none", "-Wl,-z,max-page-size=4"]
        if recipe.get("kind") != "assembly":
            link += ["-Wl,--gc-sections", "-Wl,--strip-debug" if recipe.get("symbols") else "-Wl,-s"]
    else:
        link += ["-Wl,-s"]
    commands.append([*link, "-Wl,-T," + str(script), *objects, "-o", str(destination)])
    return commands


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*", help="example names, such as gpio/blink, or all (default)")
    parser.add_argument("--output", type=Path, help="output directory; default: examples/build")
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    if args.list:
        print("\n".join(RECIPES))
        return
    names = list(RECIPES) if not args.names or args.names == ["all"] else args.names
    unknown = set(names) - RECIPES.keys()
    if unknown:
        parser.error("unknown examples: " + ", ".join(sorted(unknown)))
    zig = shutil.which(args.zig)
    if zig is None:
        parser.error("Zig executable not found: " + args.zig)
    zig = str(Path(zig).resolve())
    if subprocess.check_output([zig, "version"], text=True).strip() != "0.17.0":
        parser.error("use Zig 0.17.0")
    base = Path(__file__).resolve().parent
    output = args.output.resolve() if args.output else base / "build"
    for name in names:
        destination = output / (name + ".elf")
        if destination.resolve() == (base / (name + ".elf")).resolve():
            parser.error("choose an output directory separate from the checked-in ELFs")
    for name in names:
        destination = output / (name + ".elf")
        destination.parent.mkdir(parents=True, exist_ok=True)
        work = output / ".objects" / name
        work.mkdir(parents=True, exist_ok=True)
        print("Building " + name, flush=True)
        for command in _recipe_commands(RECIPES[name], base, work, destination, zig):
            subprocess.run(command, cwd=base, check=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
