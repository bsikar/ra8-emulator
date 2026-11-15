"""Bundle containment and runtime-input integration, without a target machine."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("test_bundle", ROOT / "tools/test_bundle.py")
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "source"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.write("tests/fixtures/image.elf", b"firmware")
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(["git", "-c", "user.name=Bundle Test", "-c", "user.email=bundle@example.invalid", "commit", "-qm", "fixture"], cwd=self.root, check=True)
        self.fields = {"emulator": "cache/emulator.exe", "host_move_peer": "cache/move.exe", "host_lifecycle_peer": "cache/lifecycle.exe", "ssh_fixture": "cache/ssh.exe", "guest": "cache/guest"}
        for name in self.fields.values():
            self.write(name, name.encode())
        self.write("bin/suite.exe", b"cross-built suite")
        self.options()
        self.output = Path(self.temp.name) / "bundle"

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def options(self):
        text = "\n".join(f"pub const {key}: []const u8 = {json.dumps(value)};" for key, value in self.fields.items())
        self.write("cache/options.zig", text.encode())

    def run_bundle(self):
        return BUNDLE.package(self.root, [Path("cache/options.zig")], [Path("bin/suite.exe")], self.output)

    def test_tracked_fixtures_and_all_generated_inputs_are_preserved(self):
        manifest = self.run_bundle()
        for name in ["tests/fixtures/image.elf", "bin/suite.exe", *self.fields.values()]:
            self.assertEqual((self.root / name).read_bytes(), (self.output / name).read_bytes())
        self.assertEqual(self.fields, manifest["test_paths"])
        self.assertEqual(40, len(manifest["source_revision"]))
        self.assertEqual(manifest, json.loads((self.output / "test-bundle.json").read_text()))
        self.assertTrue(all(len(item["sha256"]) == 64 for item in manifest["files"]))

    def test_missing_helper_or_options_cannot_create_partial_bundle(self):
        (self.root / "cache/move.exe").unlink()
        with self.assertRaises(ValueError):
            self.run_bundle()
        self.assertFalse(self.output.exists())

    def test_escaping_paths_symlinks_and_existing_output_are_refused(self):
        for name in ["../outside", str(self.root / "cache/guest")]:
            with self.assertRaises(ValueError):
                BUNDLE.relative(self.root, name)
        (self.root / "linked").symlink_to(self.root / "cache/guest")
        with self.assertRaises(ValueError):
            BUNDLE.relative(self.root, "linked")
        self.output.mkdir()
        (self.output / "sentinel").write_text("leave alone")
        with self.assertRaises(FileExistsError):
            self.run_bundle()
        self.assertEqual("leave alone", (self.output / "sentinel").read_text())

    def test_windows_options_require_native_ssh_helper(self):
        self.fields.pop("ssh_fixture")
        self.options()
        with self.assertRaises(ValueError):
            self.run_bundle()

    def test_conflicting_options_and_internal_output_are_refused(self):
        self.write("cache/other", b"other guest")
        text = (self.root / "cache/options.zig").read_text().replace('"cache/guest"', '"cache/other"')
        self.write("cache/other.zig", text.encode())
        with self.assertRaises(ValueError):
            BUNDLE.package(self.root, [Path("cache/options.zig"), Path("cache/other.zig")], [Path("bin/suite.exe")], self.output)
        with self.assertRaises(ValueError):
            BUNDLE.package(self.root, [Path("cache/options.zig")], [Path("bin/suite.exe")], self.root / "bundle")


if __name__ == "__main__":
    unittest.main()
