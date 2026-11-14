"""Owned valid ancestor recipe used to detect forbidden build-root discovery."""
import hashlib
import json
from pathlib import Path
import sys


class Fixture:
    def __init__(self, base, root, evidence):
        self.child = root / "build.zig"
        self.original = self.child.read_bytes()
        self.parent = base / "build.zig"
        self.probe = base / "parent-build-probe.py"
        self.marker = root / "parent-build-executed"
        if self.parent.exists() or self.probe.exists() or self.marker.exists():
            raise AssertionError("ancestor fixture paths must start absent")
        python = json.dumps(sys.executable.replace("\\", "/"))
        script = json.dumps(str(self.probe).replace("\\", "/"))
        parent = ('const std = @import("std");\npub fn build(b: *std.Build) void {\n'
                  '    const probe = b.addSystemCommand(&.{ ' + python + ', ' + script + ' });\n'
                  '    b.getInstallStep().dependOn(&probe.step);\n}\n').encode()
        probe = ("from pathlib import Path\nPath(" + repr(str(self.marker)) + ").write_text('FORBIDDEN parent build executed')\n").encode()
        (evidence / "root-build-file.snapshot.zig").write_bytes(self.original)
        (evidence / "ancestor-build.fixture.zig").write_bytes(parent)
        (evidence / "ancestor-probe.fixture.py").write_bytes(probe)
        self.parent.write_bytes(parent)
        self.probe.write_bytes(probe)
        self.child.unlink()

    def metadata(self):
        return dict(ancestor_build_sha256=hashlib.sha256(self.parent.read_bytes()).hexdigest(),
                    original_build_sha256=hashlib.sha256(self.original).hexdigest(), marker=str(self.marker))

    def restore(self):
        if self.child.is_dir():
            self.child.rmdir()
        self.child.write_bytes(self.original)
        self.parent.unlink()
        self.probe.unlink()
