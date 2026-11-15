"""Project wire extension over the independent bounded build RPC client."""
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "build_smoke"))
from protocol import Client as BuildClient, blob, take_blob, workspace_client
from backend import Backend

workspace_client.METHODS.update(project_open=0x170, project_close=0x171,
                                 project_build=0x172, project_prepare=0x173)


class Client(BuildClient):
    def open_project(self, config="project.json", error=None):
        result = self.call("project_open", blob(config), error)
        if error is None:
            assert result == b"\x01"

    def close_project(self, error=None):
        result = self.call("project_close", b"", error)
        if error is None:
            assert result == b"\x01"

    def build_project(self, recipe="debug", error=None):
        result = self.call("project_build", blob(recipe), error)
        if error is None:
            assert len(result) == 8
            return struct.unpack("<Q", result)[0]

    def prepare(self, job, error=None):
        result = self.call("project_prepare", struct.pack("<Q", job), error)
        if error is None:
            receipt, end = take_blob(result)
            assert end == len(result)
            return receipt.decode("utf8")
