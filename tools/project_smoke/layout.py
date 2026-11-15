"""Owned project data and independently checked build receipts."""
import ast
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/build_smoke"))
from fixture import revision


def create(h):
    h.base = h.root.rename(h.output / "project base with spaces")
    h.root = h.base / "firmware"
    h.root.mkdir()
    for name in ("conformance.zig", "machine.zig", "link.ld"):
        shutil.copyfile(ROOT / "tests/fixtures/debug" / name, h.root / name)
    tree = ast.parse((ROOT / "tools/toolchain_smoke/build_debug.py").read_text(encoding="utf8"))
    recipe = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                  and any(isinstance(target, ast.Name) and target.id == "BUILD" for target in node.targets))
    slow = '    const wait = b.addSystemCommand(&.{ ' + json.dumps(sys.executable.replace("\\", "/")) + ', "owned_wait.py" });\n    b.step("slow", "owned cancellation fixture").dependOn(&wait.step);\n'
    (h.root / "build.zig").write_text(recipe.rsplit("}", 1)[0] + slow + "}\n", encoding="utf8")
    (h.root / "owned_wait.py").write_text('''import pathlib,subprocess,sys,time
base=pathlib.Path('.ra8-builds')
if len(sys.argv)>1:
 time.sleep(5)
 (base/'project.delayed').write_text('descendant survived')
else:
 subprocess.Popen([sys.executable,__file__,'child'])
 (base/'project.ready').write_text('nested child started')
 time.sleep(30)
''', encoding="utf8")
    h.config = dict(version=1, root="firmware", target="ra8d2", source_mappings=[dict(host=".", client="C:/client-only/project")],
                    recipes=[dict(name="debug", options="[]", artifact="bin/fresh.elf", timeout_ms=240000),
                             dict(name="slow", step="slow", options="[]", artifact="bin/fresh.elf", timeout_ms=60000)])
    h.config_path = h.base / "project.json"
    h.config_bytes = json.dumps(h.config, indent=2).encode("utf8")
    h.config_path.write_bytes(h.config_bytes)
    h.machine = h.root / "machine.zig"
    h.machine_bytes = h.machine.read_bytes()
    h.conformance = h.root / "conformance.zig"
    h.conformance_bytes = h.conformance.read_bytes()


def receipt(h, path, job, result):
    value = json.loads((h.root / path).read_text())
    h.check("receipt schema", value["version"], 1)
    h.check("receipt exact build ID", value["build_id"], job)
    h.check("receipt config digest", value["config_sha256"], hashlib.sha256(h.config_path.read_bytes()).hexdigest())
    h.check("receipt target", value["target"], "ra8d2")
    h.check("receipt recipe", value["recipe"], "debug")
    h.check("receipt original successful result", json.loads((h.root / value["directory"] / "result.json").read_text()), result)
    recipe = next(item for item in h.config["recipes"] if item["name"] == value["recipe"])
    expected = [str(h.zig), "build", "-j1", "--color=off", "--prefix", value["directory"] + "/out", "--build-file", "build.zig"]
    if recipe.get("step", ""):
        expected.append(recipe["step"])
    expected.extend(json.loads(recipe["options"]))
    h.check("project successful argv pins exact root build file", result["argv"], expected)
    for field in ("directory", "artifact", "artifact_sha256", "source_sha256", "compiler", "compiler_version"):
        h.check("receipt binds original " + field, value[field], result[field])
    data = (h.root / value["artifact"]).read_bytes()
    h.check("actual ARM ELF", (data[:4], int.from_bytes(data[18:20], "little")), (b"\x7fELF", 40))
    h.check("independent ELF digest", hashlib.sha256(data).hexdigest(), value["artifact_sha256"])
    h.check("independent workspace revision", revision(h.root), value["source_sha256"])
    h.check("exact selected compiler", Path(value["compiler"]), h.zig)
    h.check("exact compiler version", value["compiler_version"], "0.17.0")
    h.trace(dict(type="verified_receipt", path=path, receipt=value))
    return value
