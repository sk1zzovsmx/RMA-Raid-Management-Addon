from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
DB_SYNCER = ADDON / "Database" / "DBSyncer.lua"
MASTER = ADDON / "Controllers" / "Master.lua"
GREENFIELD_CONTRACT = ROOT / "docs" / "GREENFIELD_REWRITE_CONTRACT.md"


def read(path):
    return path.read_text(encoding="utf-8")


class AddonMessagePrefixContractTest(unittest.TestCase):
    def test_logger_sync_registers_public_rma_prefix_before_handling_messages(self):
        syncer = read(DB_SYNCER)

        self.assertIn('local COMM_PREFIX = "RMALogSync"', syncer)
        self.assertIn("Comms.RegisterPrefixIfAvailable(COMM_PREFIX)", syncer)
        self.assertNotIn("local RegisterAddonMessagePrefix = _G.RegisterAddonMessagePrefix", syncer)
        self.assertNotIn("registerAddonMessagePrefix(COMM_PREFIX)", syncer)
        self.assertIn("function module:OnAddonMessage(prefix, msg, channel, sender)", syncer)

    def test_roll_winner_broadcast_registers_public_rma_prefix_before_sync(self):
        master = read(MASTER)

        self.assertIn('local ROLL_WINNER_PREFIX = "RMA-RollWinner"', master)
        self.assertIn("Comms.RegisterPrefixIfAvailable(ROLL_WINNER_PREFIX)", master)
        self.assertNotIn("local Client = assert(feature.Client", master)
        self.assertNotIn('if type(_G.RegisterAddonMessagePrefix) == "function" then', master)
        self.assertNotIn("_G.RegisterAddonMessagePrefix(ROLL_WINNER_PREFIX)", master)
        self.assertNotIn("local RegisterAddonMessagePrefix = _G.RegisterAddonMessagePrefix", master)
        self.assertNotIn("registerAddonMessagePrefix(ROLL_WINNER_PREFIX)", master)
        self.assertIn("Comms.Sync(ROLL_WINNER_PREFIX, name)", master)

    def test_greenfield_contract_lists_runtime_addon_message_prefixes(self):
        contract = read(GREENFIELD_CONTRACT)

        for prefix in ("RMADist", "RMALogSync", "RMAResSync", "RMAVersion", "RMA-RollWinner"):
            self.assertIn(f"- `{prefix}`", contract)
