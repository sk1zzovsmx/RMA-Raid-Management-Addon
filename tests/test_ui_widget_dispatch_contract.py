from pathlib import Path
import subprocess
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
FACADE = ROOT / "Raid Management Addon" / "Modules" / "UI" / "Facade.lua"


def run_lua(script: str) -> None:
    subprocess.run(["lua.cmd", "-e", script], check=True, cwd=ROOT)


class UiWidgetDispatchContractTests(unittest.TestCase):
    def test_method_and_function_dispatch_stay_separate(self):
        script = textwrap.dedent(
            f"""
            local featureShared = {{
                Features = {{}},
                UI = {{}},
                ModuleRegistry = nil,
            }}
            local addon = {{
                Database = {{
                    GetFeatureShared = function()
                        return featureShared
                    end,
                }},
            }}

            local chunk = assert(loadfile("{str(FACADE).replace("\\", "\\\\")}"))
            chunk("Raid Management Addon", addon)

            local Widgets = assert(addon.UI and addon.UI.Widgets, "widget facade missing")
            local widgetOwner = {{ owner = "widget-owner" }}
            local methodCalls = 0
            local functionCalls = 0

            assert(Widgets.Register("DispatchSpec", widgetOwner) == true, "owner registration failed")
            assert(
                Widgets.RegisterMethod("DispatchSpec", "Ping", function(self, value)
                    methodCalls = methodCalls + 1
                    if self ~= widgetOwner then
                        error("CallMethod did not pass the registered widget owner")
                    end
                    return self.owner .. ":" .. value
                end) == true,
                "method registration failed"
            )
            assert(
                Widgets.RegisterFunction("DispatchSpec", "Pong", function(value)
                    functionCalls = functionCalls + 1
                    if value ~= "beta" then
                        error("CallFunction unexpectedly passed method self")
                    end
                    return "function:" .. value
                end) == true,
                "function registration failed"
            )

            local methodResult = Widgets.CallMethod("DispatchSpec", "Ping", "alpha")
            if methodResult ~= "widget-owner:alpha" then
                error("unexpected method dispatch result: " .. tostring(methodResult))
            end

            local functionResult = Widgets.CallFunction("DispatchSpec", "Pong", "beta")
            if functionResult ~= "function:beta" then
                error("unexpected function dispatch result: " .. tostring(functionResult))
            end

            if Widgets.CallMethod("DispatchSpec", "Pong", "cross-method") ~= nil then
                error("CallMethod fell back to a function registration")
            end
            if Widgets.CallFunction("DispatchSpec", "Ping", "cross-function") ~= nil then
                error("CallFunction reached a method registration")
            end

            if methodCalls ~= 1 then
                error("method callable invoked " .. tostring(methodCalls) .. " times")
            end
            if functionCalls ~= 1 then
                error("function callable invoked " .. tostring(functionCalls) .. " times")
            end
            """
        )
        run_lua(script)


if __name__ == "__main__":
    unittest.main()
