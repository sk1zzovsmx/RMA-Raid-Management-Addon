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
LOOT_DISTRIBUTION = ADDON / "Services" / "Loot" / "DistributionSession.lua"
RAID_STATE = ADDON / "Services" / "Raid" / "State.lua"
TOC = ADDON / "Raid Management Addon.toc"
ROLLS_SERVICE = ADDON / "Services" / "Rolls" / "Service.lua"
MASTER_TRADE = ADDON / "Services" / "Master" / "Trade.lua"
MASTER_TRADE_EXECUTION = ADDON / "Services" / "Master" / "TradeExecution.lua"
MASTER_FLOW_STATE = ADDON / "Services" / "Master" / "FlowState.lua"
MASTER_AWARD = ADDON / "Services" / "Master" / "Award.lua"
MASTER_CONTROLLER = ADDON / "Controllers" / "Master.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class LootRuntimeStateOwnershipTest(unittest.TestCase):
    def test_distribution_keeps_legacy_wire_receive_only(self):
        distribution = read(LOOT_DISTRIBUTION)

        self.assertNotIn("function DistributionSession.RequestSnapshot()", distribution)
        self.assertNotIn("function DistributionSession.PublishRollTick(", distribution)
        self.assertNotIn("function DistributionSession.PublishAwarded(", distribution)
        self.assertIn('local MSG_SNAPSHOT_REQ = "SNAP_REQ"', distribution)
        self.assertIn('local MSG_ROLL_TICK = "ROLL_TICK"', distribution)
        self.assertIn('local MSG_AWARDED = "AWARDED"', distribution)
        self.assertIn("if kind == MSG_SNAPSHOT_REQ then", distribution)
        self.assertIn("if kind == MSG_ROLL_TICK then", distribution)
        self.assertIn("if kind == MSG_AWARDED then", distribution)
        self.assertIn("return handleRollTickMessage(fields, sender)", distribution)
        self.assertIn("return handleAwardedMessage(fields, sender)", distribution)
        self.assertIn("return DistributionSession.PublishSnapshot(sender, fields[3])", distribution)
        self.assertIn("function DistributionSession.PublishSnapshot(target, requestId)", distribution)

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

    def test_bootstrap_exposes_explicit_runtime_state_without_feature_proxy(self):
        init = read(INIT)
        self.assertIn("addon.State = addon.State or {}", init)
        self.assertIn("addon.State.raid = addon.State.raid or {}", init)
        self.assertIn("addon.Diag = Diag", init)
        self.assertNotIn("GetFeatureShared", init)

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
        self.assertIn('assert(module.DistributionSession', loot_service)
        self.assertNotIn("Runtime guard for stale installs", loot_service)
        self.assertNotIn("buildEmptyDistributionModel", loot_service)
        self.assertNotIn("module.DistributionSession = distribution", loot_service)

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

    def test_loot_tracking_uses_loot_runtime_state_owner(self):
        tracking = read(LOOT_TRACKING)

        self.assertIn("Database.EnsureLootRuntimeState()", tracking)
        self.assertNotIn("local lootState = feature.lootState", tracking)
        self.assertNotIn("local raidState = feature.raidState", tracking)

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

        self.assertIn("local Item = addon.Item", loot_inventory)
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
        trade_execution = read(MASTER_TRADE_EXECUTION)

        self.assertIn('assert(Loot.Inventory', master_controller)
        self.assertIn('assert(Loot.AwardPlanner', master_controller)
        self.assertNotIn("LootInventory.ResolveInventoryAwardedCount", master_controller)
        self.assertNotIn("LootInventory.ResolveTradeAwardedCount()", master_controller)
        self.assertNotIn("LootAwardPlanner.BuildTradeNotificationPlan", master_controller)
        self.assertIn("self.inventory.ResolveInventoryAwardedCount", trade_execution)
        self.assertIn("self.inventory.ResolveTradeAwardedCount()", trade_execution)
        self.assertIn("self.awardPlanner.BuildTradeNotificationPlan({", trade_execution)
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
        loot_service = read(LOOT_SERVICE)
        trade_execution = read(MASTER_TRADE_EXECUTION)

        self.assertIn("local LootDistribution = assert(Loot.DistributionSession", master_controller)
        self.assertIn("LootDistribution.PublishRollStart(", master_controller)
        self.assertIn("LootDistribution.PublishRollEnd(", master_controller)
        self.assertIn("LootDistribution.PublishItemDone(", master_controller)
        self.assertIn("LootDistribution.Clear()", master_controller)
        self.assertIn("distribution = LootDistribution", master_controller)
        self.assertIn("self.distribution.PublishItemDone(", trade_execution)
        self.assertNotIn("SetDistributionState", master_controller)
        self.assertNotIn("SetDistributionState", trade_execution)
        self.assertNotIn("function module:SetDistributionState", loot_service)
        self.assertNotIn("function module:HandleDistributionMessage", loot_service)
        self.assertNotIn("module.WarmItemCache =", loot_service)

    def test_master_controller_reads_multi_award_count_from_loot_owner_without_private_bridge(self):
        master_controller = read(MASTER_CONTROLLER)
        multi_award = read(MASTER_AWARD)

        self.assertNotIn("local function getCurrentMultiAwardCount", master_controller)
        self.assertNotIn("getCurrentMultiAwardCount(", master_controller)
        self.assertNotIn("getLootWindowItemCountByKey = function(itemKey)", master_controller)
        self.assertIn('local Loot = assert(Services.Loot, "Master award loot service is not initialized")', multi_award)
        self.assertIn("local observed = Loot:GetLootWindowItemCountByKey(cur.itemKey)", multi_award)
        self.assertIn("local currentCount = Loot:GetLootWindowItemCountByKey(ma.itemKey)", multi_award)

    def test_master_controller_reads_multi_award_slot_candidates_from_inventory_owner_without_private_bridge(self):
        master_controller = read(MASTER_CONTROLLER)
        multi_award = read(MASTER_AWARD)

        self.assertNotIn("local function buildMultiAwardSlotCandidates", master_controller)
        self.assertNotIn("buildMultiAwardSlotCandidates(", master_controller)
        self.assertIn("inventory = LootInventory", master_controller)
        self.assertIn("self.inventory.BuildMultiAwardSlotCandidates(itemLink)", multi_award)
        self.assertIn("self.inventory.BuildMultiAwardSlotCandidates(ma.itemLink)", multi_award)

    def test_loot_passive_group_loot_uses_loot_runtime_state_owner(self):
        passive_group_loot = read(LOOT_PASSIVE_GROUP_LOOT)

        self.assertIn("Database.EnsureLootRuntimeState()", passive_group_loot)
        self.assertNotIn("local lootState = feature.lootState", passive_group_loot)
        self.assertNotIn("local raidState = feature.raidState", passive_group_loot)

    def test_raid_state_uses_concrete_loot_context_owners_without_aggregate_bridge(self):
        snapshots = read(LOOT_SNAPSHOTS)
        raid_state = read(RAID_STATE)

        self.assertNotIn("_ContextBridge", snapshots)
        self.assertNotIn("contextBridge", snapshots)
        self.assertNotIn("_ContextBridge", raid_state)
        self.assertIn("LootService._State", raid_state)
        self.assertIn("LootService._Sessions", raid_state)
        self.assertIn("LootService._Snapshots", raid_state)
        self.assertIn("LootService._Context", raid_state)

    def test_rolls_service_uses_database_item_index_owner_directly(self):
        rolls_service = read(ROLLS_SERVICE)

        self.assertIn("local GetItemIndex = Database.GetItemIndex", rolls_service)
        self.assertNotIn("feature.GetItemIndex", rolls_service)

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
        trade_execution = read(MASTER_TRADE_EXECUTION)

        self.assertNotIn("local function getResolvedRollWinnerName", master_controller)
        self.assertNotIn("getResolvedRollWinnerName()", master_controller)
        self.assertNotIn("local winnerModel = buildRollSelectionModel and buildRollSelectionModel() or nil", master_controller)
        self.assertNotIn("local winner = playerName or Rolls:GetResolvedWinner(winnerModel)", master_controller)
        self.assertIn("function controller:ResolveWinner(playerName, isAwardRoll)", trade_execution)
        self.assertIn(
            "local winnerModel = self.buildRollSelectionModel and self.buildRollSelectionModel() or nil",
            trade_execution,
        )
        self.assertIn("local winner = playerName or self.rolls:GetResolvedWinner(winnerModel)", trade_execution)

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

        self.assertIn("local rosterVersion = RaidApi.GetRosterVersion(Raid)", master_controller)
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

        self.assertIn('assert(Loot.Inventory', master_controller)
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
