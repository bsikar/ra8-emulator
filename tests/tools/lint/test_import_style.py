"""Exercise the real custom AST rule and baseline checker."""
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/lint"))
from run import report
from test_baseline import BaselineTests
from test_lazy_import import LazyImportTests
from test_complexity import ComplexityTests
from test_line_width import LineWidthTests


class ImportStyleTests(unittest.TestCase):
    def test_new_debt_fails_and_prune_cannot_accept_it(self):
        baseline = ROOT / "tools/lint/baseline.json"
        before = baseline.read_bytes()
        with tempfile.TemporaryDirectory(prefix="lint-regression-", dir=ROOT / "tools") as temporary:
            path = Path(temporary) / "new_debt.zig"
            path.write_text('pub fn f() void { _ = @import("std").mem; }\n')
            for extra in ([], ["--prune-baseline"]):
                result = subprocess.run([sys.executable, "-B", str(ROOT / "tools/lint/run.py"),
                                         "--zig", ZIG, *extra], cwd=ROOT, capture_output=True, timeout=600)
                self.assertEqual(1, result.returncode, result.stderr.decode())
                self.assertIn(b"Move this import", result.stdout)
                self.assertEqual(before, baseline.read_bytes())

    def test_syntax_errors_cannot_be_baselined(self):
        with tempfile.TemporaryDirectory(prefix=".lint-invalid-", dir=ROOT / "tests") as temporary:
            directory = Path(temporary)
            (directory / "broken.zig").write_text("pub fn {\n")
            with self.assertRaises((ValueError, RuntimeError)):
                report(ZIG, [directory])

    def test_actual_ast_diagnostics(self):
        cases = {
            "named": ('const std = @import("std");\n\npub fn f() void {}\n', []),
            "missing_gap": ('const std = @import("std");\npub fn f() void {}\n', ["blank line"]),
            "comment_is_not_gap": ('const std = @import("std");\n// comment\npub fn f() void {}\n', ["blank line"]),
            "crlf": ('const std = @import("std");\r\n\r\npub fn f() void {}\r\n', []),
            "two_imports": ('const std = @import("std");\nconst builtin = @import("builtin");\n\npub fn f() void {}\n', []),
            "type_alias": ('const Allocator = @import("std").mem.Allocator;\n\npub fn f() void {}\n', []),
            "namespace": ('pub const ns = struct {\n pub const mem = @import("std").mem;\n};\n', []),
            "inline_call": ('pub fn f() void { _ = @import("std").mem; }\n', ["named namespace"]),
            "local_alias": ('pub fn f() void { const std = @import("std"); _ = std; }\n', ["named namespace"]),
            "inline_type": ('pub fn f(a: @import("std").mem.Allocator) void { _ = a; }\n', ["named namespace"]),
            "string": ('const text = "@import(\\\"std\\\")";\n', []),
            "comment": ('// @import("std")\npub fn f() void {}\n', []),
            "registration": ('comptime { _ = @import("std"); }\n', []),
            "test_body": ('test "x" { _ = @import("std"); }\n', ["named namespace"]),
            "registration_call": ('comptime { @import("std").debug.assert(true); }\n', ["named namespace"]),
        }
        with tempfile.TemporaryDirectory(prefix=".lint-fixtures-", dir=ROOT / "tests") as temporary:
            directory = Path(temporary)
            for name, (source, _) in cases.items():
                (directory / (name + ".zig")).write_bytes(source.encode())
            document = report(ZIG, [directory])
            actual = {Path(item["filePath"]).stem: item["messages"] for item in document["results"]}
            for name, (_, expected) in cases.items():
                with self.subTest(name=name):
                    messages = [m["message"] for m in actual.get(name, []) if m["ruleId"] == "import_style"]
                    self.assertEqual(len(expected), len(messages), messages)
                    for fragment, message in zip(expected, messages):
                        self.assertIn(fragment, message)


if __name__ == "__main__":
    at = sys.argv.index("--zig")
    ZIG = sys.argv[at + 1]
    LazyImportTests.zig = ZIG
    ComplexityTests.zig = ZIG
    LineWidthTests.zig = ZIG
    del sys.argv[at:at + 2]
    unittest.main()
