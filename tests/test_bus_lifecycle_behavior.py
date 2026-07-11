import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
BUS = ADDON / "Modules" / "Bus.lua"
LOOT_SOURCE_CANDIDATES = ADDON / "Modules" / "LootSourceCandidates.lua"


def run_lua(script):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", encoding="utf-8", delete=False) as handle:
        handle.write(script)
        script_path = Path(handle.name)
    try:
        subprocess.run(["lua.cmd", str(script_path)], check=True, cwd=ROOT)
    finally:
        script_path.unlink(missing_ok=True)


class BusLifecycleBehaviorTest(unittest.TestCase):
    def test_bus_owns_addon_lifetime_listeners_without_unregister_api(self):
        run_lua(textwrap.dedent(f"""
            local errors = 0
            local addon = {{
                Bus = {{}},
                Diag = {{ E = {{ LogUtilsCallbackExec = "%s %s %s" }} }},
                L = {{ StrCbErrUsage = "invalid callback" }},
                error = function() errors = errors + 1 end,
            }}
            assert(loadfile([[{BUS.as_posix()}]]))("RMA", addon)
            local bus = addon.Bus
            assert(bus.UnregisterCallback == nil)

            local calls = {{}}
            bus.RegisterCallback("Changed", function(_, value)
                calls[#calls + 1] = "first:" .. value
            end)
            bus.RegisterCallback("Changed", function()
                error("listener failure")
            end)
            bus.RegisterCallback("Changed", function(_, value)
                calls[#calls + 1] = "third:" .. value
            end)
            bus.TriggerEvent("Changed", "one")
            bus.TriggerEvent("Changed", "two")
            assert(table.concat(calls, ",") == "first:one,third:one,first:two,third:two")
            assert(errors == 2)
        """))

    def test_loot_source_candidates_is_published_once(self):
        source = LOOT_SOURCE_CANDIDATES.read_text(encoding="utf-8")
        self.assertEqual(1, source.count("addon.LootSourceCandidates = LootSourceCandidates"))


if __name__ == "__main__":
    unittest.main()
