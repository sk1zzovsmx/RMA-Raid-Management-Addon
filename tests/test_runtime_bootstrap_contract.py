from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import re
import unittest

from tests.lua_test_runner import run_lua_case


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
TOC = ADDON / "Raid Management Addon.toc"
LOOT_SOURCE_DIR = ADDON / "Modules" / "Dataset" / "LootSources"
LOOT_SOURCE_DATA = ADDON / "Modules" / "Dataset" / "LootSourcesData.lua"
DB_SYNCER = ADDON / "Database" / "DBSyncer.lua"
LOCALIZATION = ADDON / "Localization" / "localization.en.lua"
COMMS = ADDON / "Modules" / "Comms.lua"
SYNC_PROTOCOL = ADDON / "Database" / "DBSyncProtocol.lua"
SYNCER = ADDON / "Database" / "DBSyncer.lua"
RESERVES_IMPORT = ADDON / "Services" / "Reserves" / "Import.lua"
WIRE_CONTRACT_DOCS = (
    ROOT / "docs" / "ARCHITECTURE.md",
    ROOT / "docs" / "API_SURFACE.md",
    ROOT / "docs" / "VALIDATION.md",
)
APPROVED_AWARD_SERVICE_FILES = {
    r"Services\Loot\LootAttribution.lua",
    r"Services\Master\AwardAttempt.lua",
    r"Services\Master\AwardSequence.lua",
    r"Services\Master\AwardConfirmation.lua",
}
RETIRED_AWARD_SERVICE_FILES = {
    r"Services\Loot\PendingAwards.lua",
    r"Services\Master\Award.lua",
    r"Services\Master\AwardTransaction.lua",
    r"Services\Master\PendingAwardExecution.lua",
}
APPROVED_AWARD_OWNERS = {
    "Services.Loot.LootAttribution",
    "Services.Master.AwardAttempt",
    "Services.Master.AwardSequence",
    "Services.Master.AwardConfirmation",
}
RETIRED_AWARD_OWNERS = {
    "Services.Loot.PendingAwards",
    "Services.Master.Award",
    "Services.Master.AwardTransaction",
    "Services.Master.PendingAwardExecution",
}


def toc_entries() -> list[str]:
    return [
        line.strip()
        for line in TOC.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def duplicate_raid_names() -> set[str]:
    occurrences: dict[str, list[str]] = defaultdict(list)
    for path in sorted(LOOT_SOURCE_DIR.glob("*.lua")):
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.match(r'^\t\tname = "([^"]+)",$', line)
            if match:
                key = " ".join(match.group(1).strip().lower().split())
                occurrences[key].append(path.name)
    return {name for name, files in occurrences.items() if len(files) > 1}


class RuntimeBootstrapContractTest(unittest.TestCase):
    def test_runtime_has_no_libcompat_dependency_or_accidental_mixin_api(self) -> None:
        entries = toc_entries()
        self.assertNotIn(r"Libs\LibCompat-1.0\lib.xml", entries)
        self.assertFalse((ADDON / "Libs" / "LibCompat-1.0").exists())

        runtime = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(ADDON.rglob("*.lua"))
            if "Libs" not in path.parts
        )
        self.assertNotIn("LibCompat-1.0", runtime)
        for retired_api in (
            "addon.tLength",
            "addon.TablePool",
            "addon.WithinRange",
            "addon.WrapTextInColorCode",
            "addon.UnitIterator",
            "addon.GetNumGroupMembers",
            "addon.GetGroupTypeAndCount",
            "addon.GetCreatureId",
            "addon.UnitFullName",
        ):
            self.assertNotIn(retired_api, runtime)

    def test_runtime_has_no_liblogger_dependency(self) -> None:
        entries = toc_entries()
        self.assertNotIn(r"Libs\LibLogger-1.0\lib.xml", entries)
        self.assertFalse((ADDON / "Libs" / "LibLogger-1.0").exists())

        runtime = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(ADDON.rglob("*.lua"))
            if "Libs" not in path.parts
        )
        self.assertNotIn("LibLogger-1.0", runtime)
        self.assertNotIn("addon.Debugger", runtime)

    def test_user_facing_help_has_no_beta_database_commands(self) -> None:
        source = LOCALIZATION.read_text(encoding="utf-8")
        self.assertNotIn("/rma history ", source)
        self.assertNotIn("/rma perf " + "sync", source)

    def test_beta_database_sync_architecture_is_absent(self) -> None:
        combined_runtime_source = TOC.read_text(encoding="utf-8") + "\n" + "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(ADDON.rglob("*.lua"))
            if "Libs" not in path.parts
        )
        retired = (
            "DBRaid" + "Migrations.lua",
            "DBSync" + "Metrics.lua",
            "DBSync" + "Payload.lua",
            "DBSync" + "Import.lua",
            "MODE_" + "PUSH",
            "MODE_" + "REQ",
            "MODE_" + "SYNC",
            "persistent" + "Sync",
            "RequestLogger" + "Req",
            "BroadcastLogger" + "Push",
            "RequestLogger" + "Sync",
        )
        for symbol in retired:
            self.assertNotIn(symbol, combined_runtime_source)

    def test_award_services_use_approved_domain_names(self) -> None:
        entries = set(toc_entries())
        self.assertTrue(APPROVED_AWARD_SERVICE_FILES <= entries)
        self.assertTrue(RETIRED_AWARD_SERVICE_FILES.isdisjoint(entries))

        runtime = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(ADDON.rglob("*.lua"))
            if "Libs" not in path.parts
        )
        for owner in APPROVED_AWARD_OWNERS:
            self.assertIsNotNone(re.search(rf"{re.escape(owner)}(?![A-Za-z])", runtime))
        for owner in RETIRED_AWARD_OWNERS:
            self.assertIsNone(re.search(rf"{re.escape(owner)}(?![A-Za-z])", runtime))

    def test_roster_loads_before_capabilities(self) -> None:
        entries = toc_entries()
        self.assertLess(
            entries.index(r"Services\Raid\Roster.lua"),
            entries.index(r"Services\Raid\Capabilities.lua"),
        )

    def test_raid_event_reducer_loads_before_atomic_store(self) -> None:
        entries = toc_entries()
        self.assertLess(
            entries.index(r"Database\DBRaidEvents.lua"),
            entries.index(r"Database\DBRaidStore.lua"),
        )

    def test_raid_store_has_one_canonical_archive_root(self) -> None:
        store = (ADDON / "Database" / "DBRaidStore.lua").read_text(encoding="utf-8")
        db = (ADDON / "Database" / "DB.lua").read_text(encoding="utf-8")
        for retired in (
            "isRaid" + "Archive",
            "buildRaidNid" + "IndexSignature",
            "hasRawRaid" + "Nid",
            "legacy" + "Raids",
            "CaptureRaid" + "InsertionState",
            "RestoreRaid" + "InsertionState",
        ):
            self.assertNotIn(retired, store)
        self.assertNotIn("function Database." + "Ensure" + "Archive", db)

    def test_cross_expansion_duplicates_use_later_dataset_precedence(self) -> None:
        self.assertEqual({"naxxramas", "onyxia's lair"}, duplicate_raid_names())
        source = LOOT_SOURCE_DATA.read_text(encoding="utf-8")
        self.assertNotIn("duplicate normalized loot-source raid name", source)
        self.assertIn("rawByInstance[raidKey] = raid", source)

    def test_master_loot_entrypoints_share_transaction_admission(self) -> None:
        result = run_lua_case("loot_duplicate_award_is_rejected_in_flight")
        self.assertIn(
            "PASS loot_duplicate_award_is_rejected_in_flight",
            result.stdout,
        )

    def test_shared_r5_wire_codec_replaces_obsolete_protocol_infrastructure(self) -> None:
        comms = COMMS.read_text(encoding="utf-8")
        protocol = SYNC_PROTOCOL.read_text(encoding="utf-8")
        toc = TOC.read_text(encoding="utf-8")
        runtime_sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in ADDON.rglob("*.lua")
            if "Libs" not in path.parts
        )

        for obsolete in (
            "_addonQueue",
            "PackFields",
            "SplitFields",
            "EncodeText",
            "DecodeText",
            "function Comms.Sync",
            'WIRE_MARKER = "R4"',
        ):
            self.assertNotIn(obsolete, comms + protocol)
        self.assertIn('LibStub("LibSerialize")', comms)
        self.assertIn('LibStub("LibDeflate")', comms)
        self.assertIn("ChatThrottleLib.SendAddonMessage", comms)
        self.assertNotIn("pcall(SendAddonMessage", runtime_sources)
        self.assertNotIn("pcall(SendChatMessage", runtime_sources)
        self.assertIn(r"Modules\Base64.lua", toc)
        self.assertIn(r"Modules\Json.lua", toc)
        self.assertNotIn("addon.Json", protocol)
        self.assertIn("addon.Json", RESERVES_IMPORT.read_text(encoding="utf-8"))

    def test_wire_contract_docs_declare_shared_r5_ownership(self) -> None:
        docs = "\n".join(path.read_text(encoding="utf-8") for path in WIRE_CONTRACT_DOCS)
        for statement in (
            "`addon.Comms.Payload` owns LibSerialize plus LibDeflate addon-channel encoding.",
            "`addon.Comms` owns destination validation and delegates all outbound scheduling to ChatThrottleLib.",
            "RMA addon-message protocols use version 5 envelopes and reject earlier versions.",
            "JSON and Base64 remain import/hash utilities, not addon-message wire codecs.",
        ):
            self.assertIn(statement, docs)

    def test_external_api_surface_lists_the_active_raid_sync_prefix(self) -> None:
        surface = (ROOT / "docs" / "API_SURFACE.md").read_text(encoding="utf-8")
        self.assertIn("`RMARaidSync`", surface)
        self.assertNotIn("`RMALogSync`", surface)

    def test_all_rma_protocol_owners_are_r5_only_and_reject_earlier_envelopes(self) -> None:
        syncer = SYNCER.read_text(encoding="utf-8")

        self.assertNotIn("version-4", syncer)
        self.assertNotRegex(syncer, r"\bProtocol\.VERSION\s+or\s+4\b")
        self.assertRegex(syncer, r"assert\s*\(\s*Protocol\.VERSION\s*==\s*5\b")
        for case_name in (
            "raid_replication_protocol_rejects_invalid",
            "reserves_sync_r5_envelopes_chunks_and_rejections",
            "loot_distribution_r5_snapshot_chunks_and_rejections",
            "comms_version_r5_envelope_and_alert_ack",
        ):
            result = run_lua_case(case_name)
            self.assertIn(f"PASS {case_name}", result.stdout)


if __name__ == "__main__":
    unittest.main()
