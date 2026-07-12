from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
FRAMES_LUA = ROOT / "Raid Management Addon" / "Modules" / "UI" / "Frames.lua"


def get_ref_body() -> str:
    source = FRAMES_LUA.read_text(encoding="utf-8")
    match = re.search(
        r"function Frames\.GetRef\(frameOrName, childName\)([\s\S]*?)\nend",
        source,
    )
    if match is None:
        raise AssertionError("Frames.GetRef definition is missing")
    return match.group(1)


class UiFramesReferenceContractTest(unittest.TestCase):
    def test_owned_child_precedes_exact_global_fallback(self) -> None:
        body = get_ref_body()
        owned_lookup = "local owned = _G[frameName .. childName]"
        exact_fallback = "return _G[childName]"
        self.assertIn(owned_lookup, body)
        self.assertIn("if owned then", body)
        self.assertLess(body.index(owned_lookup), body.rindex(exact_fallback))

    def test_absolute_owned_name_remains_supported(self) -> None:
        body = get_ref_body()
        self.assertIn("if strsub(childName, 1, #frameName) == frameName then", body)
        self.assertIn("return _G[childName]", body)

    def test_invalid_inputs_remain_guarded(self) -> None:
        body = get_ref_body()
        self.assertIn('if type(frameName) ~= "string" or frameName == "" then', body)
        self.assertIn('if type(childName) ~= "string" or childName == "" then', body)


if __name__ == "__main__":
    unittest.main()
