from __future__ import annotations

from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "tests" / "lua" / "runtime_harness.lua"


def run_lua_case(case_name: str) -> subprocess.CompletedProcess[str]:
    lua = shutil.which("lua")
    if lua is None:
        raise AssertionError("lua command is not available on PATH")
    result = subprocess.run(
        [lua, str(HARNESS), case_name],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"Lua case {case_name!r} failed with exit code {result.returncode}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    return result
