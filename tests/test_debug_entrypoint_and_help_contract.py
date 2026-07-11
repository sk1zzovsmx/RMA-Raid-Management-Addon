from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
TOC = ADDON / "Raid Management Addon.toc"
SLASH = ADDON / "EntryPoints" / "SlashEvents.lua"
DEBUG = ADDON / "EntryPoints" / "Debug.lua"
TIMER = ADDON / "Modules" / "Timer.lua"
RAID_DEBUG = ADDON / "Services" / "Raid" / "Debug.lua"
MASTER = ADDON / "Controllers" / "Master.lua"
CONFIG = ADDON / "Controllers" / "Config.lua"
CONFIG_XML = ADDON / "UI" / "Config.xml"
LOCALIZATION = ADDON / "Localization" / "localization.en.lua"


class DebugEntrypointAndHelpContractTest(unittest.TestCase):
    def test_debug_routing_and_command_reference_have_dedicated_owners(self):
        self.assertTrue(DEBUG.exists())

        toc = TOC.read_text(encoding="utf-8")
        self.assertLess(toc.index("EntryPoints\\Debug.lua"), toc.index("Modules\\Timer.lua"))
        self.assertLess(toc.index("EntryPoints\\Debug.lua"), toc.index("EntryPoints\\SlashEvents.lua"))

        slash = SLASH.read_text(encoding="utf-8")
        self.assertIn('local DebugEntryPoint = assert(addon.EntryPoints.Debug, "Debug entrypoint is not initialized")', slash)
        self.assertIn("registerAliases(cmdDebug, DebugEntryPoint.Handle)", slash)
        self.assertNotIn("local function handleDebugCommand", slash)
        self.assertNotIn("local function handleDebugRaidCommand", slash)

        debug = DEBUG.read_text(encoding="utf-8")
        self.assertIn("function module.RegisterCommand(command, usage, description, handler)", debug)
        self.assertIn("function module.GetHelpText()", debug)
        self.assertIn("function module.Handle(rest)", debug)
        self.assertNotIn("RaidDebug:SeedRaidPlayers()", debug)
        self.assertNotIn("MasterController:ShowDebugRaidGrid", debug)

        self.assertIn('DebugEntryPoint.RegisterCommand("timers"', TIMER.read_text(encoding="utf-8"))
        self.assertIn('DebugEntryPoint.RegisterCommand("raid"', RAID_DEBUG.read_text(encoding="utf-8"))
        self.assertIn('DebugEntryPoint.RegisterCommand("raidgrid"', MASTER.read_text(encoding="utf-8"))

        config = CONFIG.read_text(encoding="utf-8")
        self.assertIn('setText(helpContentFrameName, "CommandsTitle", L.StrConfigHelpCommandsTitle)', config)
        self.assertIn("DebugEntryPoint.GetHelpText()", config)
        self.assertIn('Layout.TextRow("CommandsTitle", "CommandsBody"', config)

        config_xml = CONFIG_XML.read_text(encoding="utf-8")
        self.assertIn('name="$parentCommandsTitle"', config_xml)
        self.assertIn('name="$parentCommandsBody"', config_xml)

        localization = LOCALIZATION.read_text(encoding="utf-8")
        self.assertIn("L.StrConfigHelpCommandsTitle", localization)
        self.assertIn("L.StrConfigHelpCommandsBody", localization)
        self.assertIn("L.StrConfigHelpDebugCommandsTitle", localization)
        self.assertIn("/rma reserves alias <softres-name> <raid-name>", localization)


if __name__ == "__main__":
    unittest.main()
