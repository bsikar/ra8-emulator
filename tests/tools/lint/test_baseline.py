"""No new debt, no duplicate masking, and no suppression of analysis errors."""
import json
import tempfile
import unittest
from collections import Counter
from pathlib import Path

from baseline import compare, findings, load, save


class BaselineTests(unittest.TestCase):
    def test_counts_detect_a_second_copy(self):
        old = Counter({("a.zig", "rule", "hash"): 1})
        new = Counter({("a.zig", "rule", "hash"): 2})
        self.assertEqual(1, sum(compare(new, old)[0].values()))

    def test_removed_finding_cannot_be_reintroduced_after_pruning(self):
        old = Counter({("a.zig", "rule", "hash"): 1})
        self.assertEqual(old, compare(Counter(), old)[1])
        self.assertEqual(old, compare(old, Counter())[0])

    def test_roundtrip_and_invalid_counts(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "baseline.json"
            expected = Counter({("a.zig", "rule", "hash"): 2})
            save(path, expected)
            self.assertEqual(expected, load(path))
            document = json.loads(path.read_text())
            document["findings"][0]["count"] = 0
            path.write_text(json.dumps(document))
            with self.assertRaises(ValueError):
                load(path)

    def test_line_moves_keep_identity_but_changed_code_does_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "a.zig"
            message = dict(ruleId="rule", severity=1, message="problem", line=1, endLine=1, column=1)
            document = dict(results=[dict(filePath=str(path), messages=[message])])
            path.write_text("bad();\n")
            before, _ = findings(document, root)
            path.write_text("\n\nbad();\n")
            message.update(line=3, endLine=3)
            self.assertEqual(before, findings(document, root)[0])
            path.write_text("\n\nworse();\n")
            self.assertTrue(compare(findings(document, root)[0], before)[0])
            message["severity"] = 2
            with self.assertRaises(ValueError):
                findings(document, root)

    def test_complexity_increase_cannot_reuse_an_allowance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "a.zig"
            path.write_text("pub fn dispatch() void {\n}\n")
            message = dict(ruleId="complexity", severity=1,
                           message="Function dispatch: branch complexity 16/15, nesting 2/3.",
                           line=1, endLine=1, column=1)
            document = dict(results=[dict(filePath=str(path), messages=[message])])
            before, _ = findings(document, root)
            message["message"] = "Function dispatch: branch complexity 17/15, nesting 2/3."
            self.assertTrue(compare(findings(document, root)[0], before)[0])

    def test_invalid_ranges_and_paths_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "a.zig"
            path.write_text("x\n")
            message = dict(ruleId="rule", severity=1, message="problem", line=2, endLine=2, column=1)
            document = dict(results=[dict(filePath=str(path), messages=[message])])
            with self.assertRaises(ValueError):
                findings(document, root)
            with self.assertRaises(ValueError):
                findings(document, root / "other")
