from __future__ import annotations

from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
XML = ROOT / "Raid Management Addon" / "UI" / "LootHistory.xml"
LOGGER = ROOT / "Raid Management Addon" / "Controllers" / "Logger.lua"
SLASH_EVENTS = ROOT / "Raid Management Addon" / "EntryPoints" / "SlashEvents.lua"
SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"
STORE = ROOT / "Raid Management Addon" / "Database" / "DBRaidStore.lua"
LOCALIZATION = ROOT / "Raid Management Addon" / "Localization" / "localization.en.lua"


class SingleRaidSharingContractTests(unittest.TestCase):
    def test_history_slash_surface_keeps_only_share_entrypoint(self) -> None:
        source = SLASH_EVENTS.read_text(encoding="utf-8")
        self.assertIn('local cmdWarnings, cmdLogger = { "warning", "warnings", "warn", "rw" }, { "logger" }', source)
        self.assertIn('sub == "share"', source)
        self.assertIn("LoggerController:ShowShareDialog()", source)

        localization = LOCALIZATION.read_text(encoding="utf-8")
        self.assertIn("/rma logger [share]", localization)
        self.assertNotIn("/rma history " + "req", localization)
        self.assertNotIn("/rma history " + "push", localization)
        self.assertNotIn("/rma history " + "sync", localization)

    def test_share_layout_is_static_and_has_no_manual_recovery_button(self) -> None:
        ET.parse(XML)
        source = XML.read_text(encoding="utf-8")
        self.assertNotRegex(source, r"<Scripts>|<On[A-Za-z]+>")
        for name in (
            "$parentShareBtn",
            "RMALootHistoryShareFrame",
            "$parentSummary",
            "$parentRecipientDropDown",
            "$parentSendBtn",
            "$parentStatus",
        ):
            self.assertIn(f'name="{name}"', source)
        self.assertNotIn('name="$parentRecoverBtn"', source)

    def test_logger_binds_only_completed_raid_offer_and_current_group_target(self) -> None:
        source = LOGGER.read_text(encoding="utf-8")
        self.assertIn('record.status ~= "complete"', source)
        self.assertIn("Raid:IsGroupMember(module._shareTarget)", source)
        self.assertIn("syncer:OfferHistoricalRaid(raidUid, module._shareTarget)", source)
        self.assertNotIn("OfferLoggerRaid", source)

    def test_offer_popup_callbacks_are_exact_consent_actions(self) -> None:
        source = LOGGER.read_text(encoding="utf-8")
        self.assertIn("syncer:AcceptHistoricalOffer(offer.sender, offer.offerId)", source)
        self.assertIn("syncer:DeclineHistoricalOffer(offer.sender, offer.offerId)", source)
        self.assertNotIn("AcceptLoggerOffer", source)
        self.assertNotIn("DeclineLoggerOffer", source)

    def test_syncer_keeps_offers_runtime_only_and_bounded(self) -> None:
        source = SYNCER.read_text(encoding="utf-8")
        self.assertIn("MAX_HISTORY_OFFERS", source)
        self.assertIn("HISTORY_OFFER_TTL_SECONDS", source)
        self.assertIn("HISTORY_OUTGOING_OFFER_RETENTION_SECONDS = 65", source)
        self.assertIn("HISTORY_ACCEPTED_TTL_SECONDS = 65", source)
        self.assertIn('offer.state == "offered"', source)
        self.assertIn('offer.state == "accepted"', source)
        self.assertIn("module._incomingOffers", source)
        self.assertIn("module._outgoingOffers", source)
        self.assertNotRegex(source, r"RMA_[A-Za-z]*Offer|SavedVariables.*Offer")

    def test_conflicts_are_persisted_with_source_provenance_and_visible_feedback(self) -> None:
        store = STORE.read_text(encoding="utf-8")
        localization = LOCALIZATION.read_text(encoding="utf-8")
        self.assertIn("candidate.sourceRaidUid = sourceRaidUid", store)
        self.assertIn("candidate.conflictOfRaidUid = sourceRaidUid", store)
        self.assertIn("record.sourceRaidUid or raidUid", store)
        for outcome in ("Imported", "AlreadyPresent", "Conflict", "Declined", "Failed"):
            self.assertIn(f"StrLoggerHistoryShare{outcome}", localization)


if __name__ == "__main__":
    unittest.main()
