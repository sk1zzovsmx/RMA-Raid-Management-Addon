import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"
PAYLOAD = ROOT / "Raid Management Addon" / "Database" / "DBSyncPayload.lua"
IMPORT = ROOT / "Raid Management Addon" / "Database" / "DBSyncImport.lua"
STORE = ROOT / "Raid Management Addon" / "Database" / "DBRaidStore.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class IncrementalLoggerSyncContractTest(unittest.TestCase):
    def test_syncer_defines_v2_delta_protocol_and_full_fallback(self):
        source = read(SYNCER)
        self.assertIn("local LEGACY_PROTOCOL_VERSION = 1", source)
        self.assertIn("local PROTOCOL_VERSION = 2", source)
        self.assertIn('local MSG_DELTA = "DL"', source)
        self.assertIn("MAX_DELTA_ROWS = 50", source)
        self.assertIn("sendSnapshot(target, requestId, mode, raid)", source)
        self.assertRegex(source, r"sendDelta\s*\(")
        self.assertIn("sinceRevision", source)

    def test_payload_exports_delta_build_parse_api(self):
        source = read(PAYLOAD)
        self.assertIn("function SnapshotPayload.BuildDelta(raid, sinceRevision)", source)
        self.assertIn("function SnapshotPayload.ParseDelta(payload)", source)
        self.assertIn('"D"', source)
        self.assertIn('"LD"', source)

    def test_import_applies_delta_without_replacing_full_raid(self):
        source = read(IMPORT)
        self.assertIn("function SnapshotImport.ApplyDeltaToRaid(raid, delta)", source)
        self.assertIn("ApplySnapshotToRaid", source)
        self.assertIn("ApplyDeltaToRaid", source)

    def test_store_exposes_runtime_revision_helpers_without_savedvariable_schema_change(self):
        source = read(STORE)
        self.assertIn("function module:GetRaidSyncRevision(raid)", source)
        self.assertIn("function module:TouchRaidSyncRevision(raid, reason)", source)
        self.assertIn("syncRevision", source)
        allowed = r"RMA_Raids|RMA_Players|RMA_Reserves|RMA_Warnings|RMA_Spammer|RMA_Options"
        self.assertNotIn("RMA_", re.sub(allowed, "", source))


if __name__ == "__main__":
    unittest.main()
