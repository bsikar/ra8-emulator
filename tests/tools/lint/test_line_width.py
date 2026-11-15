"""The width limit counts Unicode columns, including the exact 120-column boundary."""
import tempfile
import unittest
from pathlib import Path

from run import report

ROOT = Path(__file__).resolve().parents[3]


class LineWidthTests(unittest.TestCase):
    zig = None

    def test_boundaries_unicode_and_crlf(self):
        cases = {
            "boundary": ("//" + "x" * 118 + "\n", False),
            "over": ("//" + "x" * 119 + "\n", True),
            "unicode": ("//" + "é" * 118 + "\n", False),
            "unicode_over": ("//" + "é" * 119 + "\n", True),
            "crlf": ("//" + "x" * 118 + "\r\n", False),
            "unterminated": ("//" + "x" * 119, True),
        }
        with tempfile.TemporaryDirectory(prefix=".width-fixtures-", dir=ROOT / "tests") as temporary:
            directory = Path(temporary)
            for name, (source, _) in cases.items():
                (directory / (name + ".zig")).write_bytes(source.encode("utf-8"))
            document = report(self.zig, [directory])
            actual = {Path(item["filePath"]).stem: item["messages"] for item in document["results"]}
            for name, (_, expected) in cases.items():
                with self.subTest(name=name):
                    messages = [m for m in actual.get(name, []) if m["ruleId"] == "line_width"]
                    self.assertEqual(int(expected), len(messages))
                    if messages:
                        self.assertEqual(1, messages[0]["line"])
                        self.assertIn("121 columns", messages[0]["message"])
