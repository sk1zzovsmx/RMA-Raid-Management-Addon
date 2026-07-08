from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class UiWidgetDispatchContractTests(unittest.TestCase):
    def test_facade_exposes_explicit_registration_apis(self):
        facade = read(ADDON / "Modules" / "UI" / "Facade.lua")

        self.assertIn("function Widgets.RegisterMethod(widgetId, methodName, fn)", facade)
        self.assertIn('return registerCallable(widgetId, methodName, fn, "method")', facade)
        self.assertIn("function Widgets.RegisterFunction(widgetId, methodName, fn)", facade)
        self.assertIn('return registerCallable(widgetId, methodName, fn, "function")', facade)
        self.assertNotIn("METHOD_STYLE_WHITELIST", facade)
        self.assertNotIn("methodStyleWhitelist", facade)

    def test_widget_modules_classify_registered_dispatch_callables(self):
        config = read(ADDON / "Widgets" / "Config.lua")
        loot_counter = read(ADDON / "Widgets" / "LootCounter.lua")
        loot_hints = read(ADDON / "Widgets" / "LootHints.lua")
        raid_grid = read(ADDON / "Widgets" / "RaidGrid.lua")
        reserves_ui = read(ADDON / "Widgets" / "ReservesUI.lua")
        trade_menu = read(ADDON / "Widgets" / "TradeMenu.lua")

        for line in (
            'UIWidgets.RegisterMethod("Config", "Toggle", module.Toggle)',
            'UIWidgets.RegisterMethod("Config", "Default", module.Default)',
        ):
            self.assertIn(line, config)

        for line in (
            'UIWidgets.RegisterMethod("LootCounter", "Toggle", module.Toggle)',
            'UIWidgets.RegisterMethod("LootCounter", "AttachToMaster", module.AttachToMaster)',
        ):
            self.assertIn(line, loot_counter)

        for line in (
            'UIWidgets.RegisterFunction("LootHints", "ApplyLootFrameReserveHints", module.ApplyLootFrameReserveHints)',
            'UIWidgets.RegisterFunction("LootHints", "ClearLootFrameReserveHints", module.ClearLootFrameReserveHints)',
            'UIWidgets.RegisterFunction("LootHints", "EnsureLootFrameHooks", module.EnsureLootFrameHooks)',
        ):
            self.assertIn(line, loot_hints)

        for line in (
            'UIWidgets.RegisterFunction("RaidGrid", "ShowPicker", module.ShowPicker)',
            'UIWidgets.RegisterFunction("RaidGrid", "Hide", module.Hide)',
            'UIWidgets.RegisterFunction("RaidGrid", "IsShown", module.IsShown)',
            'UIWidgets.RegisterFunction("RaidGrid", "GetMode", module.GetMode)',
        ):
            self.assertIn(line, raid_grid)

        for line in (
            'UIWidgets.RegisterMethod("Reserves", "Toggle", module.Toggle)',
            'UIWidgets.RegisterMethod("Reserves", "ToggleImport", module.ToggleImport)',
        ):
            self.assertIn(line, reserves_ui)

        for line in (
            'UIWidgets.RegisterFunction("TradeMenu", "HideDropdowns", module.HideDropdowns)',
            'UIWidgets.RegisterFunction("TradeMenu", "RefreshDropdowns", module.RefreshDropdowns)',
            'UIWidgets.RegisterFunction("TradeMenu", "RefreshCandidate", module.RefreshCandidate)',
        ):
            self.assertIn(line, trade_menu)


if __name__ == "__main__":
    unittest.main()
