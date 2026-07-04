from pathlib import Path
import re
import subprocess
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUS = ROOT / "Raid Management Addon" / "Modules" / "Bus.lua"


def read_bus():
    return BUS.read_text(encoding="utf-8")


class BusDispatchArrayContractTest(unittest.TestCase):
    def test_bus_public_api_is_preserved(self):
        src = read_bus()
        self.assertRegex(src, r"function\s+Bus\.RegisterCallback\s*\(")
        self.assertRegex(src, r"function\s+Bus\.UnregisterCallback\s*\(")
        self.assertRegex(src, r"function\s+Bus\.TriggerEvent\s*\(")

    def test_bus_does_not_depend_on_callbackhandler_or_xml_scripts(self):
        src = read_bus()
        self.assertNotIn("CallbackHandler", src)
        self.assertNotIn("C_Timer", src)
        self.assertNotIn("OnUpdate", src)

    def test_bus_uses_array_listener_storage_with_token_index(self):
        src = read_bus()
        self.assertTrue("listenerList" in src or "listeners.items" in src)
        self.assertIn("indexByToken", src)
        self.assertRegex(src, r"for\s+i\s*=\s*1\s*,\s*#.*items\s+do")

    def test_bus_defers_compaction_during_dispatch(self):
        src = read_bus()
        self.assertIn("dispatchDepth", src)
        self.assertTrue("pendingCompact" in src or "dirty" in src)

    def test_unregister_during_dispatch_does_not_skip_unrelated_listeners(self):
        script = textwrap.dedent(
            f"""
            local calls = {{}}
            local errors = {{}}
            local addon = {{
                Database = {{
                    GetFeatureShared = function()
                        return {{
                            L = {{ StrCbErrUsage = "bad callback registration" }},
                            Diag = {{ E = {{ LogUtilsCallbackExec = "callback %s for %s failed: %s" }} }},
                            Bus = {{}},
                            ModuleRegistry = nil,
                        }}
                    end,
                }},
                error = function(_, msg)
                    errors[#errors + 1] = msg
                end,
            }}

            local chunk = assert(loadfile("{str(BUS).replace("\\", "\\\\")}"))
            chunk("Raid Management Addon", addon)

            local tokenB
            addon.Bus.RegisterCallback("event", function(eventName, value)
                calls[#calls + 1] = "a:" .. eventName .. ":" .. value
                addon.Bus.UnregisterCallback(tokenB)
            end)
            tokenB = addon.Bus.RegisterCallback("event", function()
                calls[#calls + 1] = "b"
            end)
            addon.Bus.RegisterCallback("event", function()
                calls[#calls + 1] = "c"
            end)

            addon.Bus.TriggerEvent("event", "one")
            addon.Bus.TriggerEvent("event", "two")

            local expected = {{ "a:event:one", "c", "a:event:two", "c" }}
            for i = 1, #expected do
                if calls[i] ~= expected[i] then
                    error("call mismatch " .. i .. ": " .. tostring(calls[i]) .. " ~= " .. expected[i])
                end
            end
            if calls[#expected + 1] then
                error("unexpected extra call " .. tostring(calls[#expected + 1]))
            end
            if errors[1] then
                error("unexpected callback error " .. tostring(errors[1]))
            end
            """
        )
        subprocess.run(["lua.cmd", "-e", script], check=True, cwd=ROOT)


if __name__ == "__main__":
    unittest.main()
