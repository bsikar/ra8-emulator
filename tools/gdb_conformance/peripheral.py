"""Real-GDB proof that a seeded SCI1 RX FIFO survives debugger reads."""
import argparse
import hashlib
import json
import re
import subprocess
import time
from pathlib import Path

from cases import check
from oracle import symbols

RDR = 0x40358100
CSR = 0x40358148
RDRF = 0x80000000


def commands(fixture):
    found = symbols(fixture)
    ready, drained = found["fifo_ready"], found["fifo_drained"]
    at = lambda name: f"*(unsigned int*)0x{found[name]:x}"
    script = ["set debug remote on", f"break *0x{ready:x}", "continue"]
    script += check(f"$pc == 0x{ready:x}", "fifo_ready_pc")
    script += check(f"({at('pending_status_before')} & {RDRF}) != 0", "guest_seeded_nonempty_fifo")
    script += ["set $held_pc = $pc", f"set $status_before = *(unsigned int*)0x{CSR:x}",
               "maintenance flush dcache", f"set $rdr_first = *(unsigned int*)0x{RDR:x}",
               "maintenance flush dcache", f"set $rdr_second = *(unsigned int*)0x{RDR:x}",
               f"set $status_after = *(unsigned int*)0x{CSR:x}"]
    script += check("$rdr_first == 255 && $rdr_second == 255", "two_gdb_reads_see_pending_byte")
    script += check(f"($status_before & {RDRF}) != 0 && ($status_after & {RDRF}) != 0",
                    "gdb_reads_keep_fifo_pending")
    script += check("$pc == $held_pc", "gdb_reads_do_not_advance_machine")
    script += ["delete breakpoints", f"break *0x{drained:x}", "continue"]
    script += check(f"$pc == 0x{drained:x}", "guest_finished_fifo_drain")
    base = found["drained"]
    script += [f"x/3wx 0x{base:x}"]
    script += [f"x/wx 0x{found[name]:x}" for name in
               ("status_after_first", "status_after_second", "status_after_third", "empty_read")]
    script += check(" && ".join(f"*(unsigned int*)0x{base + 4 * i:x} == 255" for i in range(3)),
                    "guest_receives_all_three_seeded_bytes")
    script += check(f"({at('status_after_first')} & {RDRF}) != 0", "fifo_pending_after_first_guest_read")
    script += check(f"({at('status_after_second')} & {RDRF}) != 0", "fifo_pending_after_second_guest_read")
    script += check(f"({at('status_after_third')} & {RDRF}) == 0", "fifo_empty_after_third_guest_read")
    script += check(f"{at('empty_read')} == 0", "guest_empty_read_is_zero")
    script += ["detach"]
    return script, []


def verify_remote_reads(transcript):
    # Remote debug logging proves both reads reached the endpoint, not a GDB cache.
    packets = re.findall(r"Sending packet: \$m40358100,4(?:#|\b)", transcript, re.IGNORECASE)
    if len(packets) < 2:
        raise AssertionError("fewer than two actual RSP reads of the populated RDR: " + str(len(packets)))
    return len(packets)


def run(args, run_batch):
    script, expected = commands(args.peripheral_fixture)
    result = run_batch(args, "peripheral-read-stability", script, expected, fixture=args.peripheral_fixture)
    transcript = (args.output / "peripheral-read-stability.client.log").read_text(encoding="utf8")
    try:
        result["actual_rdr_read_packets"] = verify_remote_reads(transcript)
    except AssertionError as error:
        result.update(status="FAIL", error=str(error))
    result["fixture_sha256"] = hashlib.sha256(args.peripheral_fixture.read_bytes()).hexdigest()
    result["seed"] = {"model": "SCI1 Simple-SPI idle receive", "bytes": [255, 255, 255],
                      "rdr": RDR, "csr": CSR, "pending_mask": RDRF}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("emulator", "peripheral-fixture", "gdb", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--expected-gdb-version", required=True)
    args = parser.parse_args()
    args.repo = Path(__file__).resolve().parents[2]
    args.output.mkdir(parents=True, exist_ok=False)
    args.deadline = time.monotonic() + 90
    args.fixture = args.peripheral_fixture
    version = subprocess.check_output([str(args.gdb), "--version"], text=True, timeout=10).splitlines()[0]
    if args.expected_gdb_version not in version:
        raise ValueError("actual GDB version differs from requested pin: " + version)
    from run import run_batch
    result = run(args, run_batch)
    result["gdb_version"] = version
    result["emulator_sha256"] = hashlib.sha256(args.emulator.read_bytes()).hexdigest()
    (args.output / "result.json").write_text(json.dumps(result, indent=2), encoding="utf8")
    print(json.dumps(result))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
