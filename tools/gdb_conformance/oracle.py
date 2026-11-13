"""Read fixture symbols independently of emulator parsers and emit its oracle."""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from line_rows import address_of


def symbols(path, sizes=None):
    data = path.read_bytes()
    if data[:6] != b"\x7fELF\x01\x01":
        raise ValueError("fixture must be ELF32 little-endian")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    offset, size, count = header[6], header[11], header[12]
    sections = [struct.unpack_from("<IIIIIIIIII", data, offset + i * size)
                for i in range(count)]
    result = {}
    for section in sections:
        if section[1] != 2:
            continue
        strings = sections[section[6]]
        names = data[strings[4]:strings[4] + strings[5]]
        for at in range(section[4], section[4] + section[5], section[9]):
            name, value, length, info, _, index = struct.unpack_from("<IIIBBH", data, at)
            if not name or not index or info >> 4 not in (1, 2):
                continue
            end = names.index(b"\0", name)
            text = names[name:end].decode("utf-8")
            result[text] = value & ~1 if info & 15 == 2 else value
            if sizes is not None:
                sizes[text] = length
    return result


def image(path):
    path = path.resolve()
    sizes = {}
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "symbols": symbols(path, sizes), "symbol_sizes": sizes}


def generate(fixture, source, fault=None, cpu1=None, peripheral=None):
    normal = image(fixture)
    found = normal["symbols"]
    if "register_checkpoint" not in found:
        if "controlled_fault" not in found:
            raise ValueError("unknown fixture kind")
        return {"schema": 1, "fixture_sha256": normal["sha256"],
                "fixture": normal["path"], "symbols": found,
                "symbol_sizes": normal["symbol_sizes"], "entry": found["Reset_Handler"]}
    required = ("Reset_Handler", "register_checkpoint", "call_small", "after_small",
                "call_long", "after_long", "small_callee", "long_callee",
                "nested_inner", "nested_outer", "breakpoint_loop", "known_word", "stage")
    for name in required:
        if name not in found:
            raise ValueError("missing fixture symbol: " + name)
    found["safe_step"] = found["register_checkpoint"]
    lines = source.read_text(encoding="utf-8").splitlines()
    marker = next(i for i, line in enumerate(lines, 1) if "SOURCE_BREAK:" in line)
    result = {
        "schema": 1, "fixture_sha256": normal["sha256"], "fixture": normal["path"],
        "symbols": found, "symbol_sizes": normal["symbol_sizes"], "entry": found["Reset_Handler"],
        "ready": found["register_checkpoint"],
        "ready_registers": {"r0": 0x11223344, "r1": 0x55667788},
        "values": {"r0": 0x11223344, "r1": 0x55667788, "known_word": 0x11223344,
                   "stage_after_nested": 42, "long_iterations": 30000, "small_step_bytes": 2},
        "source": {"path": str(source.resolve()), "line": marker,
                   "address": address_of(fixture, source, marker),
                   "markers": {"nested_inner": marker},
                   "sha256": hashlib.sha256(source.read_bytes()).hexdigest()},
        "next": {"small_call": found["call_small"], "small_return": found["after_small"],
                 "long_call": found["call_long"], "long_return": found["after_long"]},
    }
    if fault:
        result["fault"] = image(fault)
    if cpu1:
        result["cpu1"] = image(cpu1)
    if peripheral:
        result["peripheral"] = image(peripheral)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--source", type=Path,
                        default=Path(__file__).resolve().parents[2] / "tests/fixtures/debug/machine.zig")
    parser.add_argument("--fault-fixture", type=Path)
    parser.add_argument("--cpu1-fixture", type=Path)
    parser.add_argument("--peripheral-fixture", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = generate(args.fixture, args.source, args.fault_fixture, args.cpu1_fixture, args.peripheral_fixture)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": "PASS", "fixture_sha256": result["fixture_sha256"],
                      "symbols": len(result["symbols"])}))


if __name__ == "__main__":
    main()
