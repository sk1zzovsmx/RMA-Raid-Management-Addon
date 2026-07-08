import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
INIT = ADDON / "Init.lua"
LOOT_STATE = ADDON / "Services" / "Loot" / "State.lua"
LOOT_SERVICE = ADDON / "Services" / "Loot" / "Service.lua"
LOOT_INVENTORY = ADDON / "Services" / "Loot" / "Inventory.lua"
LOOT_PENDING_AWARDS = ADDON / "Services" / "Loot" / "PendingAwards.lua"
LOOT_TRACKING = ADDON / "Services" / "Loot" / "Tracking.lua"
LOOT_PASSIVE_GROUP_LOOT = ADDON / "Services" / "Loot" / "PassiveGroupLoot.lua"
LOOT_SNAPSHOTS = ADDON / "Services" / "Loot" / "Snapshots.lua"
RAID_STATE = ADDON / "Services" / "Raid" / "State.lua"
TOC = ADDON / "Raid Management Addon.toc"
ROLLS_SERVICE = ADDON / "Services" / "Rolls" / "Service.lua"
MASTER_TRADE = ADDON / "Services" / "Master" / "Trade.lua"
MASTER_FLOW_STATE = ADDON / "Services" / "Master" / "FlowState.lua"
MASTER_CONTROLLER = ADDON / "Controllers" / "Master.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class LootRuntimeStateOwnershipTest(unittest.TestCase):
    def test_loot_runtime_accessors_are_owned_by_loot_state_service(self):
        init = read(INIT)
        loot_state = read(LOOT_STATE)
        for method in (
            "EnsureLootRuntimeState",
            "GetItemIndex",
        ):
            pattern = r"function\s+Database\." + method + r"\s*\("
            self.assertRegex(loot_state, pattern, method)
            self.assertNotRegex(init, pattern, method)

    def test_bootstrap_feature_shared_exposes_runtime_tables_not_item_index_alias(self):
        init = read(INIT)
        self.assertIn('if key == "lootState"', init)
        self.assertIn('if key == "itemInfo"', init)
        self.assertNotIn('if key == "GetItemIndex"', init)

    def test_loot_service_uses_loot_runtime_state_owner(self):
        loot_service = read(LOOT_SERVICE)

        self.assertIn("Database.EnsureLootRuntimeState()", loot_service)
        self.assertNotIn("local lootState = feature.lootState", loot_service)
        self.assertNotIn("local itemInfo = feature.itemInfo", loot_service)
        self.assertNotIn("local raidState = feature.raidState", loot_service)

    def test_loot_distribution_session_is_required_owner_not_stale_install_fallback(self):
        toc = read(TOC)
        loot_service = read(LOOT_SERVICE)

        self.assertLess(toc.index("Services\\Loot\\DistributionSession.lua"), toc.index("Services\\Loot\\Service.lua"))
        self.assertIn('assert(module._DistributionSession', loot_service)
        self.assertNotIn("Runtime guard for stale installs", loot_service)
        self.assertNotIn("buildEmptyDistributionModel", loot_service)
        self.assertNotIn("module._DistributionSession = distribution", loot_service)

    def test_loot_inventory_uses_loot_runtime_state_owner(self):
        loot_inventory = read(LOOT_INVENTORY)

        self.assertIn("Database.EnsureLootRuntimeState()", loot_inventory)
        self.assertNotIn("local lootState = feature.lootState", loot_inventory)
        self.assertNotIn("local itemInfo = feature.itemInfo", loot_inventory)
        self.assertNotIn("feature.lootState.currentItemIndex", loot_inventory)

    def test_loot_pending_awards_uses_loot_runtime_state_owner(self):
        pending_awards = read(LOOT_PENDING_AWARDS)

        self.assertIn("Database.EnsureLootRuntimeState()", pending_awards)
        self.assertNotIn("local lootState = feature.lootState", pending_awards)
        self.assertIn('"Services/Loot/State"', pending_awards)

    def test_loot_tracking_uses_loot_runtime_state_owner(self):
        tracking = read(LOOT_TRACKING)

        self.assertIn("Database.EnsureLootRuntimeState()", tracking)
        self.assertNotIn("local lootState = feature.lootState", tracking)
        self.assertNotIn("local raidState = feature.raidState", tracking)
        self.assertIn('"Services/Loot/State"', tracking)

    def test_loot_service_does_not_keep_tracking_snapshot_pass_throughs(self):
        loot_service = read(LOOT_SERVICE)

        self.assertNotIn("local function findLootSlotIndex", loot_service)
        self.assertNotIn("function module:GetTrackingSnapshot(raidNum)", loot_service)

    def test_loot_service_window_count_method_owns_scan_without_private_pass_through(self):
        loot_service = read(LOOT_SERVICE)

        self.assertIn("function module:GetLootWindowItemCountByKey(itemKey)", loot_service)
        self.assertIn("for i = 1, (tonumber(lootState.lootCount) or 0) do", loot_service)
        self.assertNotIn("local function getLootWindowItemCountByKey", loot_service)
        self.assertNotIn("return getLootWindowItemCountByKey(itemKey)", loot_service)

    def test_loot_inventory_checks_item_soulbound_owner_directly(self):
        loot_inventory = read(LOOT_INVENTORY)
        loot_service = read(LOOT_SERVICE)

        self.assertIn("local Item = feature.Item", loot_inventory)
        self.assertIn("Item.IsBagItemSoulbound(bag, slot)", loot_inventory)
        self.assertIn("Item.IsBagItemSoulbound(cachedBag, cachedSlot)", loot_inventory)
        self.assertNotIn("ModuleItemIsSoulbound", loot_inventory)
        self.assertNotIn("local function isBagItemSoulbound", loot_service)
        self.assertNotIn("function itemIsSoulbound", loot_service)
        self.assertNotIn("module.IsBagItemSoulbound", loot_service)
        self.assertNotIn("module.ItemIsSoulbound", loot_service)

    def test_loot_inventory_reads_current_item_link_without_private_facade(self):
        loot_inventory = read(LOOT_INVENTORY)

        self.assertNotIn("local function getItemLink()", loot_inventory)
        self.assertNotIn("or getItemLink()", loot_inventory)
        self.assertIn("Loot.GetItemLink(currentIndex)", loot_inventory)

    def test_loot_service_does_not_export_unused_distribution_model_facade(self):
        loot_service = read(LOOT_SERVICE)

        self.assertNotIn("function module:GetDistributionSessionModel()", loot_service)
        self.assertNotIn("return getDistributionSession().GetDisplayModel()", loot_service)

    def test_loot_service_does_not_export_unused_tracking_snapshot_facade(self):
        loot_service = read(LOOT_SERVICE)

        self.assertNotIn("function module:GetTrackingSnapshot(raidNum)", loot_service)
        self.assertNotIn("return Tracking.GetSnapshot(raidNum, lootTable, Inventory.FindLootSlotIndex)", loot_service)

    def test_master_controller_uses_award_owners_without_loot_service_bridges(self):
        master_controller = read(MASTER_CONTROLLER)
        loot_service = read(LOOT_SERVICE)

        self.assertIn('assert(Loot._Inventory', master_controller)
        self.assertIn('assert(Loot._AwardPlanner', master_controller)
        self.assertIn("LootInventory.ResolveInventoryAwardedCountFromArgs", master_controller)
        self.assertIn("LootInventory.ResolveTradeAwardedCount()", master_controller)
        self.assertIn("LootAwardPlanner.BuildTradeNotificationPlan", master_controller)
        for bridge_name in (
            "ResolveTradeAwardedCount",
            "ResolveInventoryAwardedCount",
            "BuildTradeNotificationPlan",
            "BuildAwardTargetPlan",
            "ValidateInventoryTradeSelection",
            "BuildMultiAwardWinnersPlan",
            "BuildMultiAwardState",
            "BuildMultiAwardSlotCandidates",
        ):
            with self.subTest(bridge_name=bridge_name):
                self.assertNotIn("Loot:" + bridge_name + "(", master_controller)
                self.assertNotIn("function module:" + bridge_name, loot_service)

    def test_master_controller_calls_loot_distribution_owner_without_private_bridge(self):
        master_controller = read(MASTER_CONTROLLER)

        self.assertNotIn("local function updateLootDistribution", master_controller)
        self.assertNotIn("updateLootDistribution(", master_controller)
        self.assertIn('Loot:SetDistributionState("roll_start"', master_controller)
        self.assertIn('Loot:SetDistributionState("roll_end"', master_controller)
        self.assertIn('Loot:SetDistributionState("item_done"', master_controller)
        self.assertIn('Loot:SetDistributionState("session")', master_controller)

    def test_master_controller_reads_multi_award_count_from_loot_owner_without_private_bridge(self):
        master_controller = read(MASTER_CONTROLLER)

        self.assertNotIn("local function getCurrentMultiAwardCount", master_controller)
        self.assertNotIn("getCurrentMultiAwardCount(", master_controller)
        self.assertIn("Loot:GetLootWindowItemCountByKey(cur.itemKey)", master_controller)
        self.assertIn("Loot:GetLootWindowItemCountByKey(ma.itemKey)", master_controller)

    def test_master_controller_reads_multi_award_slot_candidates_from_inventory_owner_without_private_bridge(self):
        master_controller = read(MASTER_CONTROLLER)

        self.assertNotIn("local function buildMultiAwardSlotCandidates", master_controller)
        self.assertNotIn("buildMultiAwardSlotCandidates(", master_controller)
        self.assertIn("LootInventory.BuildMultiAwardSlotCandidates(itemLink)", master_controller)
        self.assertIn("LootInventory.BuildMultiAwardSlotCandidates(ma.itemLink)", master_controller)

    def test_loot_passive_group_loot_uses_loot_runtime_state_owner(self):
        passive_group_loot = read(LOOT_PASSIVE_GROUP_LOOT)

        self.assertIn("Database.EnsureLootRuntimeState()", passive_group_loot)
        self.assertNotIn("local lootState = feature.lootState", passive_group_loot)
        self.assertNotIn("local raidState = feature.raidState", passive_group_loot)
        self.assertIn('"Services/Loot/State"', passive_group_loot)

    def test_raid_state_uses_loot_context_bridge_owner_without_getter_facade(self):
        snapshots = read(LOOT_SNAPSHOTS)
        raid_state = read(RAID_STATE)

        self.assertIn("module._ContextBridge = contextBridge", snapshots)
        self.assertNotIn("function module:GetContextBridge()", snapshots)
        self.assertNotIn("GetContextBridge", raid_state)
        self.assertIn("LootService._ContextBridge", raid_state)

    def test_rolls_service_uses_database_item_index_owner_directly(self):
        rolls_service = read(ROLLS_SERVICE)

        self.assertIn("local GetItemIndex = Database.GetItemIndex", rolls_service)
        self.assertNotIn("feature.GetItemIndex", rolls_service)
        self.assertIn('"Services/Loot/State"', rolls_service)

    def test_rolls_service_uses_loot_runtime_state_owner(self):
        rolls_service = read(ROLLS_SERVICE)

        self.assertIn("Database.EnsureLootRuntimeState()", rolls_service)
        self.assertNotIn("local lootState = feature.lootState or {}", rolls_service)
        self.assertNotIn("feature.lootState = lootState", rolls_service)

    def test_rolls_sessions_context_inlines_loot_item_lookup_without_private_pass_through(self):
        rolls_service = read(ROLLS_SERVICE)

        self.assertIsNone(re.search(r"^local GetItem$", rolls_service, re.MULTILINE))
        self.assertIsNone(re.search(r"^GetItem = function\\(i\\)", rolls_service, re.MULTILINE))
        self.assertNotIn("getItem = GetItem", rolls_service)
        self.assertIn("getItem = function(i)", rolls_service)
        self.assertIn("local loot = Services.Loot", rolls_service)
        self.assertIn("return loot and loot.GetItem and loot.GetItem(i) or nil", rolls_service)

    def test_master_controller_calls_rolls_service_without_local_api_facade(self):
        master_controller = read(MASTER_CONTROLLER)

        self.assertNotIn("local RollsApi", master_controller)
        self.assertNotIn("RollsApi.", master_controller)
        for method_name in (
            "GetResolvedWinner",
            "ShouldUseTieReroll",
            "SetExpectedWinners",
            "EnsureLootRollSession",
            "SyncSessionState",
            "IsCountdownRunning",
            "StopCountdown",
            "StartCountdown",
            "FinalizeRollSession",
            "ValidateWinner",
        ):
            with self.subTest(method_name=method_name):
                self.assertIn("Rolls:" + method_name + "(", master_controller)
        self.assertNotIn("local function validateAwardWinner", master_controller)

    def test_master_controller_inlines_tie_reroll_check_without_private_pass_through(self):
        master_controller = read(MASTER_CONTROLLER)

        self.assertNotIn("local function shouldUseTieReroll", master_controller)
        self.assertNotIn("shouldUseTieReroll(model)", master_controller)
        self.assertNotIn("shouldUseTieReroll(rollModel)", master_controller)
        self.assertIn("Rolls:ShouldUseTieReroll(model)", master_controller)
        self.assertIn("Rolls:ShouldUseTieReroll(rollModel)", master_controller)

    def test_master_controller_inlines_trade_resolved_winner_without_private_pass_through(self):
        master_controller = read(MASTER_CONTROLLER)

        self.assertNotIn("local function getResolvedRollWinnerName", master_controller)
        self.assertNotIn("getResolvedRollWinnerName()", master_controller)
        self.assertIn("local winnerModel = buildRollUiModel and buildRollUiModel() or nil", master_controller)
        self.assertIn("local winner = playerName or Rolls:GetResolvedWinner(winnerModel)", master_controller)

    def test_master_controller_inlines_displayed_winner_without_private_pass_through(self):
        master_controller = read(MASTER_CONTROLLER)

        self.assertNotIn("local function getDisplayedWinnerName", master_controller)
        self.assertNotIn("getDisplayedWinnerName(rollModel)", master_controller)
        self.assertIn("local displayedWinner = getCurrentTradeWinner() or getCurrentMultiAwardWinner()", master_controller)
        self.assertIn("displayedWinner = Rolls:GetResolvedWinner(rollModel)", master_controller)

    def test_master_controller_calls_raid_api_without_private_pass_throughs(self):
        master_controller = read(MASTER_CONTROLLER)

        for helper_name in (
            "getRaidRosterVersion",
            "invalidateCandidateCache",
            "resolveCandidateIndex",
            "hasMasterLootCandidates",
        ):
            with self.subTest(helper_name=helper_name):
                self.assertNotIn("local function " + helper_name, master_controller)

        self.assertIn("RaidApi.GetRosterVersion(Raid)", master_controller)
        self.assertIn("RaidApi.RequestMasterLootCandidateRefresh(Raid)", master_controller)
        self.assertIn("RaidApi.FindMasterLootCandidateIndex(Raid, itemLink, playerName)", master_controller)
        self.assertIn("RaidApi.CanResolveMasterLootCandidates(Raid, itemLink)", master_controller)

    def test_master_trade_uses_loot_runtime_state_owner_for_manual_trade(self):
        master_trade = read(MASTER_TRADE)

        self.assertIn("Database.EnsureLootRuntimeState()", master_trade)
        self.assertNotIn("feature.lootState = feature.lootState or {}", master_trade)
        self.assertNotIn("feature.lootState.manualTrade", master_trade)

    def test_master_controller_uses_loot_runtime_state_owner(self):
        master_controller = read(MASTER_CONTROLLER)

        self.assertIn("Database.EnsureLootRuntimeState()", master_controller)
        self.assertNotIn("local lootState = feature.lootState or {}", master_controller)
        self.assertNotIn("feature.lootState = lootState", master_controller)
        self.assertNotIn("local itemInfo = feature.itemInfo or {}", master_controller)
        self.assertNotIn("feature.itemInfo = itemInfo", master_controller)

    def test_master_controller_uses_loot_inventory_owner_without_service_bridges(self):
        master_controller = read(MASTER_CONTROLLER)
        loot_service = read(LOOT_SERVICE)

        self.assertIn('assert(Loot._Inventory', master_controller)
        for bridge_name in (
            "FindLootSlotIndex",
            "FindTradeableInventoryMatch",
            "FindTradeableInventoryItem",
        ):
            with self.subTest(bridge_name=bridge_name):
                self.assertNotIn("Loot:" + bridge_name + "(", master_controller)
                self.assertNotIn("function module." + bridge_name, loot_service)

    def test_master_flow_state_requires_caller_owned_loot_state(self):
        master_flow_state = read(MASTER_FLOW_STATE)
        master_controller = read(MASTER_CONTROLLER)

        self.assertIn("lootState = lootState", master_controller)
        self.assertIn("opts.lootState", master_flow_state)
        self.assertNotIn("feature.lootState", master_flow_state)


if __name__ == "__main__":
    unittest.main()
