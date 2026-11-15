"""Branch scoring follows syntax, treats else-if chains as flat, and isolates functions."""
import tempfile
import unittest
from pathlib import Path

from run import report

ROOT = Path(__file__).resolve().parents[3]


class ComplexityTests(unittest.TestCase):
    zig = None

    def test_real_ast_scores(self):
        guard = "if (a) return;\n"
        cases = {
            "at_limit": ("pub fn f(a: bool) void {\n" + guard * 15 + "}\n", None),
            "over_limit": ("pub fn f(a: bool) void {\n" + guard * 16 + "}\n", (16, 1)),
            "nesting": ("pub fn f(a: bool) void { if (a) { if (a) { if (a) { if (a) {} } } } }\n", (10, 4)),
            "else_if": ("pub fn f(a: bool) void { if (a) {} " + "else if (a) {} " * 15 + "}\n", (16, 1)),
            "flat_switch": ("pub fn f(a: u8) void { switch (a) { " + "".join(f"{i} => {{}}," for i in range(40)) + "else => {}, } }\n", None),
            "mixed_boolean": ("pub fn f(a: bool) void {\n" + guard * 13 + "if (a and a and a or a) return;\n}\n", (16, 1)),
            "comments": ('// if if if while for\npub fn f() void { const text = "if while for else"; _ = text; }\n', None),
            "nested_function": ("pub fn outer() void { const N = struct { pub fn inner(a: bool) void {\n" + guard * 16 + "} }; _ = N; }\n", (16, 1)),
        }
        with tempfile.TemporaryDirectory(prefix=".complexity-fixtures-", dir=ROOT / "tests") as temporary:
            directory = Path(temporary)
            for name, (source, _) in cases.items():
                (directory / (name + ".zig")).write_text(source)
            document = report(self.zig, [directory])
            actual = {Path(item["filePath"]).stem: item["messages"] for item in document["results"]}
            for name, (_, expected) in cases.items():
                with self.subTest(name=name):
                    messages = [m["message"] for m in actual.get(name, []) if m["ruleId"] == "complexity"]
                    if expected is None:
                        self.assertEqual([], messages)
                    else:
                        self.assertEqual(1, len(messages), messages)
                        score, depth = expected
                        self.assertIn(f"branch complexity {score}/15, nesting {depth}/3", messages[0])
