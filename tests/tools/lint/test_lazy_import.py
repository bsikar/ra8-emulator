"""The real lint build helper must not fetch an unused dependency."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


class LazyImportTests(unittest.TestCase):
    zig = None

    def test_unused_uncached_dependency_is_not_materialized(self):
        manifest = (ROOT / "build.zig.zon").read_text()
        dependency = re.search(r"        \.zlinter = \.\{.*?        \},", manifest, re.S).group()
        package_hash = re.search(r'\.hash = "([^"]+)"', dependency).group(1)
        # Give the probe an unknown content hash so a warm package cache cannot
        # make an accidentally eager dependency look lazy.
        unknown_hash = package_hash[:-2] + ("AA" if not package_hash.endswith("AA") else "BA")
        dependency = dependency.replace(package_hash, unknown_hash)
        with tempfile.TemporaryDirectory(prefix="ra8-lazy-lint-") as temporary:
            root = Path(temporary)
            (root / "tools/lint").mkdir(parents=True)
            shutil.copyfile(ROOT / "tools/lint/build.zig", root / "tools/lint/build.zig")
            (root / "build.zig").write_text('''const std = @import("std");
const lint = @import("tools/lint/build.zig");

pub fn build(b: *std.Build) void {
    lint.add(b, @This());
    _ = b.step("probe", "Configure without requesting the linter");
}
''')
            (root / "build.zig.zon").write_text('''.{
    .name = .ra8_emulator,
    .version = "0.0.0",
    .fingerprint = 0xd7a6ec1532845ea,
    .minimum_zig_version = "0.17.0",
    .paths = .{ "build.zig", "build.zig.zon", "tools" },
    .dependencies = .{
''' + dependency + '\n    },\n}\n')
            result = subprocess.run([self.zig, "build", "probe", "-j1"], cwd=root,
                                    capture_output=True, timeout=180)
            self.assertEqual(0, result.returncode, result.stderr.decode())
            self.assertFalse((root / "zig-pkg" / unknown_hash).exists())
