"""Hermetic checks for SSH qualification assertions and the incompatible peer."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import shlex

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ssh_host_e2e", ROOT / "tools/ssh_host_e2e.py")
E2E = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(E2E)


def result(rows, status=0, stderr=b""):
    data = b"\n".join(json.dumps(row).encode() for row in rows)
    return subprocess.CompletedProcess([], status, data, stderr)


class QualificationTests(unittest.TestCase):
    def test_successful_run_stream_and_registers_match(self):
        run = result([{"uart": {"text": "ready"}}, {"stopped": {"reason": "count", "pc": 42}}])
        self.assertEqual(2, len(E2E.compare(run, run, ["run", "--budget", "20000"])))
        registers = result([{"registers": {"pc": 42}}])
        self.assertEqual([{"registers": {"pc": 42}}], E2E.compare(registers, registers, ["regs", "pc"]))

    def test_equal_error_or_empty_answers_cannot_pass(self):
        for answer in [result([{"error": "Failed"}]), result([]), result([{"stopped": {"reason": "core_fault"}}])]:
            with self.assertRaises(ValueError):
                E2E.compare(answer, answer, ["run"])
        with self.assertRaises(ValueError):
            E2E.compare(result([{"registers": {"pc": 1}}]), result([{"registers": {"pc": 2}}]), ["regs"])
        with self.assertRaises(ValueError):
            E2E.answers(result([{"ok": True}], status=1))

    def test_mismatch_requires_exit_code_error_and_actionable_message(self):
        error = {"error": "VersionMismatch", "message": E2E.ADVICE}
        self.assertEqual(error, E2E.mismatch(result([error], status=1), True))
        text = b"ctl: VersionMismatch: " + E2E.ADVICE.encode()
        E2E.mismatch(result([], status=1, stderr=text), False)
        for answer in [result([error]), result([{"error": "Other", "message": E2E.ADVICE}], status=1), result([{"error": "VersionMismatch"}], status=1)]:
            with self.assertRaises(ValueError):
                E2E.mismatch(answer, True)
        with self.assertRaises(ValueError):
            E2E.mismatch(result([], status=1, stderr=b"VersionMismatch"), False)

    def test_cache_evidence_requires_one_store_then_reuse(self):
        with tempfile.TemporaryDirectory() as name:
            audit = Path(name) / "ssh.jsonl"
            store = "sh -c 'cache script' ra8-image-cache /cache hash.elf part store 32 60 100 67108864"
            hit = store.replace("part store", "part hit")
            audit.write_text("\n".join(json.dumps(["-T", "host", command]) for command in [store, hit]))
            self.assertEqual({"stores": 1, "hits": 1}, E2E.cache_counts(audit))
            for commands in [[store], [store, store, hit]]:
                audit.write_text("\n".join(json.dumps(["-T", "host", command]) for command in commands))
                with self.assertRaises(ValueError):
                    E2E.cache_counts(audit)

    def test_incompatible_peer_exchanges_real_hello_and_fault_frames(self):
        hello = struct.pack("<IHIHI", 10, 1, 0x52384152, 7, 0)
        fault = struct.pack("<IHHH", 4, 5, 4, 7)
        peer = subprocess.run([sys.executable, str(E2E.PEER)], input=hello + fault, capture_output=True, timeout=5)
        self.assertEqual(0, peer.returncode, peer.stderr)
        self.assertEqual(struct.pack("<IHIHI", 10, 1, 0x52384152, 8, 0), peer.stdout)
        bad = subprocess.run([sys.executable, str(E2E.PEER)], input=hello + struct.pack("<IHHH", 4, 5, 3, 7), capture_output=True, timeout=5)
        self.assertNotEqual(0, bad.returncode)

    def test_correct_diagnostic_without_peer_receipt_cannot_qualify(self):
        E2E.mismatch(result([{"error": "VersionMismatch", "message": E2E.ADVICE}], status=1), True)
        for receipt in [b"", b"version_mismatch fault verified\nwrong\n"]:
            with self.assertRaises(ValueError):
                E2E.receipt_count(subprocess.CompletedProcess([], 0, receipt, b""), 2)
        E2E.receipt_count(subprocess.CompletedProcess([], 0, b"version_mismatch fault verified\n", b""), 1)

    def test_peer_writes_receipt_only_after_valid_fault(self):
        hello = struct.pack("<IHIHI", 10, 1, 0x52384152, 7, 0)
        fault = struct.pack("<IHHH", 4, 5, 4, 7)
        with tempfile.TemporaryDirectory() as name:
            receipt = Path(name) / "receipt"
            argv = [sys.executable, str(E2E.PEER), "--receipt", str(receipt)]
            good = subprocess.run(argv, input=hello + fault, capture_output=True, timeout=5)
            self.assertEqual(0, good.returncode, good.stderr)
            bad = subprocess.run(argv, input=hello, capture_output=True, timeout=5)
            self.assertNotEqual(0, bad.returncode)
            self.assertEqual("version_mismatch fault verified\n", receipt.read_text())

    def test_receipt_check_waits_for_peer_completion(self):
        with tempfile.TemporaryDirectory() as name:
            qualification = E2E.Qualification.__new__(E2E.Qualification)
            qualification.remote_root = name
            qualification.remote = lambda command: subprocess.run(shlex.split(command), capture_output=True, check=True, timeout=6)
            writer = threading.Timer(0.05, lambda: (Path(name) / "receipts").write_text("version_mismatch fault verified\n"))
            writer.start()
            try:
                qualification.wait_receipts(1)
            finally:
                writer.join()


if __name__ == "__main__":
    unittest.main()
