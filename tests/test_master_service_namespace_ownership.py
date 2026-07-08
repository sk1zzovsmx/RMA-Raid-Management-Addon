import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MASTER_SERVICES = ROOT / "Raid Management Addon" / "Services" / "Master"
MASTER_SERVICE = MASTER_SERVICES / "Service.lua"
MASTER_ROLL_UI = MASTER_SERVICES / "RollUi.lua"
MASTER_MULTI_AWARD = MASTER_SERVICES / "MultiAward.lua"
MASTER_CONTROLLER = ROOT / "Raid Management Addon" / "Controllers" / "Master.lua"
MASTER_TOC = ROOT / "Raid Management Addon" / "Raid Management Addon.toc"
TRADE_MENU = ROOT / "Raid Management Addon" / "Widgets" / "TradeMenu.lua"


def read(path):
    return path.read_text(encoding="utf-8")


def read_optional(path):
    if not path.exists():
        return ""
    return read(path)


class MasterServiceNamespaceOwnershipTest(unittest.TestCase):
    def test_master_services_publish_through_shared_namespace_owner(self):
        service_files = sorted(MASTER_SERVICES.glob("*.lua"))
        self.assertGreater(len(service_files), 0)

        for path in service_files:
            with self.subTest(file=path.name):
                text = read(path)
                self.assertIn('feature.EnsureServiceNamespace("Master")', text)
                self.assertNotIn("addon.Services.Master = Master", text)
                self.assertNotIn("Services.Master = Master", text)

    def test_master_controller_uses_flow_state_owner_without_service_passthrough(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)

        self.assertNotIn("function Master.BuildWorkflowState", service)
        self.assertNotIn('"Services/Master/FlowState"', service)
        self.assertNotIn("MasterService.BuildWorkflowState", controller)
        self.assertIn("MasterService.FlowState.BuildState({", controller)

    def test_master_controller_uses_button_state_owner_without_service_passthroughs(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)

        for method in (
            "BuildMasterTooltipState",
            "ResolveAwardSelectionState",
            "BuildMasterButtonState",
        ):
            self.assertNotIn("function Master." + method, service)
            self.assertNotIn("MasterService." + method, controller)

        self.assertIn("MasterService.ButtonState.BuildTooltipState({", controller)
        self.assertIn("MasterService.ButtonState.ResolveAwardSelectionState(rollModel, isTieReroll)", controller)
        self.assertIn("MasterService.ButtonState.BuildState({", controller)

    def test_master_controller_delegates_roll_ui_state_to_owner(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)
        roll_ui = read(MASTER_ROLL_UI)
        toc = read(MASTER_TOC)

        for method in (
            "BuildRollSelectionState",
            "BuildRollListRow",
            "BuildRollRowsModel",
            "IsSelectableRollRow",
        ):
            self.assertNotIn("function Master." + method, service)
            self.assertNotIn("MasterService." + method, controller)

        self.assertIn('local RollUiService = assert(MasterService.RollUi, "Master roll UI service is not initialized")', controller)
        self.assertIn("RollUiService.CreateController({", controller)
        self.assertIn("rollRows = MasterService.RollRows", controller)
        self.assertIn("selection = UI.Selection", controller)
        self.assertIn("rollUiController:BuildModel(forceRefresh)", controller)
        self.assertIn("rollUiController:SelectWinnerRow(name)", controller)
        self.assertIn("rollUiController:CopyVisibleRows(out)", controller)
        self.assertIn("rollUiController:GetFocusedRowId()", controller)
        self.assertIn("rollUiController:GetVisibleRows()", controller)
        self.assertNotIn("ROLL_WINNERS_CTX", controller)
        self.assertNotIn("ROLL_SELECTION_MODE", controller)
        self.assertNotIn("local function getSelectedRollWinnersOrdered", controller)
        self.assertNotIn("UI.Selection.GetCount", controller)

        self.assertIn("RollUi.ContextKey = ROLL_WINNERS_CTX", roll_ui)
        self.assertIn("RollUi.Mode = MODE", roll_ui)
        self.assertIn("function RollUi.CreateController(opts)", roll_ui)
        self.assertIn("selection.GetCount(ROLL_WINNERS_CTX)", roll_ui)
        self.assertIn("selection.Toggle(ROLL_WINNERS_CTX", roll_ui)
        self.assertIn("selection.SetAnchor(ROLL_WINNERS_CTX", roll_ui)
        self.assertIn("controller.rollRows.BuildSelectionState({", roll_ui)
        self.assertIn("self.rollRows.BuildModel({", roll_ui)
        self.assertIn("self.rollRows.BuildListRow(source, i)", roll_ui)

        self.assertLess(toc.index("Services\\Master\\RollRows.lua"), toc.index("Services\\Master\\RollUi.lua"))
        self.assertLess(toc.index("Services\\Master\\RollUi.lua"), toc.index("Controllers\\Master.lua"))

    def test_master_controller_delegates_multi_award_flow_to_owner(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)
        multi_award = read(MASTER_MULTI_AWARD)
        toc = read(MASTER_TOC)

        for method in (
            "CreateController",
            "BuildWinners",
            "Start",
            "FinalizeIfDone",
            "TryMultipleCopies",
            "TrySingleCopy",
            "ContinueOnLootSlotCleared",
        ):
            self.assertNotIn("function Master." + method, service)

        self.assertNotIn("local function collectMultiAwardNames", controller)
        self.assertNotIn("local function announceMultiAwardCompletion", controller)
        self.assertNotIn("local function armMultiAwardProgressTimeout", controller)
        self.assertNotIn("local function buildMultiAwardWinners", controller)
        self.assertNotIn("local function startMultiAwardSequence", controller)
        self.assertNotIn("local function continueMultiAwardOnLootSlotCleared", controller)
        self.assertNotIn("MasterService.MultiAward.", controller)
        self.assertIn(
            'local MultiAwardService = assert(MasterService.MultiAward, "Master multi-award service is not initialized")',
            controller,
        )
        self.assertIn("multiAwardController = MultiAwardService.CreateController({", controller)
        self.assertIn("return multiAwardController:TryMultipleCopies(itemLink, target, available)", controller)
        self.assertIn("return multiAwardController:TrySingleCopy(itemLink, winnerName)", controller)
        self.assertIn("return multiAwardController:ContinueOnLootSlotCleared(clearedSlot)", controller)

        self.assertIn("function MultiAward.CreateController(opts)", multi_award)
        self.assertIn("function controller:BuildWinners(target)", multi_award)
        self.assertIn("function controller:TryMultipleCopies(itemLink, target, available)", multi_award)
        self.assertIn("function controller:ContinueOnLootSlotCleared(clearedSlot)", multi_award)
        self.assertIn('awardExecutor = assert(opts.awardExecutor, "Master MultiAward award executor is not initialized")', multi_award)
        self.assertIn('itemCount = assert(opts.itemCount, "Master MultiAward item-count owner is not initialized")', multi_award)
        self.assertNotIn("assignItem = assert(opts.assignItem", multi_award)
        self.assertNotIn("setAnnounced = assert(opts.setAnnounced", multi_award)
        self.assertNotIn("setItemCountValue = assert(opts.setItemCountValue", multi_award)
        self.assertNotIn("resetItemCount = assert(opts.resetItemCount", multi_award)
        self.assertNotIn("getLootWindowItemCountByKey = assert(", multi_award)
        self.assertNotIn("L = assert(opts.L", multi_award)
        self.assertNotIn("Diag = assert(opts.Diag", multi_award)
        self.assertNotIn("resetTradeState = opts.resetTradeState", multi_award)

        self.assertLess(toc.index("Services\\Master\\RollUi.lua"), toc.index("Services\\Master\\MultiAward.lua"))
        self.assertLess(toc.index("Services\\Master\\MultiAward.lua"), toc.index("Services\\Master\\AssignmentHelpers.lua"))
        self.assertLess(toc.index("Services\\Master\\MultiAward.lua"), toc.index("Controllers\\Master.lua"))

    def test_master_controller_uses_message_plan_owners_without_service_passthroughs(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)

        for method in (
            "BuildAssignMessages",
            "BuildLootSpamPlan",
            "BuildRollAnnouncementPlan",
        ):
            self.assertNotIn("function Master." + method, service)
            self.assertNotIn("MasterService." + method, controller)

        self.assertNotIn('"Services/Master/AwardMessages"', service)
        self.assertNotIn('"Services/Master/LootSpam"', service)
        self.assertNotIn('"Services/Master/RollAnnouncements"', service)
        self.assertIn("MasterService.AwardMessages.BuildAssignMessages({", controller)
        self.assertIn("MasterService.LootSpam.BuildPlan({", controller)
        self.assertIn("MasterService.RollAnnouncements.BuildPlan({", controller)

    def test_master_controller_uses_assignment_grid_owners_without_service_passthroughs(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)

        for method in (
            "BuildAssignmentCandidateRows",
            "BuildDebugCandidateRows",
            "GetDebugRaidGridTargetCount",
            "IsDebugRaidGridFallbackEnabled",
            "BuildAssignmentTargetRows",
        ):
            self.assertNotIn("function Master." + method, service)
            self.assertNotIn("MasterService." + method, controller)

        self.assertNotIn('"Services/Master/AssignmentCandidates"', service)
        self.assertNotIn('"Services/Master/AssignmentTargets"', service)
        self.assertNotIn('"Services/Master/DebugRaidGrid"', service)
        self.assertIn("MasterService.AssignmentCandidates.BuildRows(collectMasterLootCandidates(), getRaidGridPlayerClass)", controller)
        self.assertIn("MasterService.DebugRaidGrid.IsFallbackEnabled(debugState, isDebugEnabled())", controller)
        self.assertIn("MasterService.DebugRaidGrid.GetTargetCount(debugState)", controller)
        self.assertIn("MasterService.DebugRaidGrid.BuildRows(count, collectRaidGridRosterRows())", controller)
        self.assertIn("MasterService.AssignmentTargets.BuildRows(module._dropDownData, getRaidGridPlayerClass)", controller)

    def test_master_controller_uses_award_counter_owner_without_service_passthroughs(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)

        for method in (
            "EnsureAwardCounterState",
            "QueueAwardCounterPending",
            "FindAwardCounterPendingBySlot",
            "RemoveAwardCounterPending",
            "ClearAwardCounterPending",
            "FailAwardCounterPending",
            "ConfirmAwardCounterPending",
            "HasAwardCounterPending",
        ):
            self.assertNotIn("function Master." + method, service)
            self.assertNotIn("MasterService." + method, controller)

        self.assertNotIn('"Services/Master/AwardCounter"', service)
        self.assertIn("MasterService.AwardCounter.EnsureState(module._PendingCounter)", controller)
        self.assertIn("MasterService.AwardCounter.Queue(self, {", controller)
        self.assertIn("MasterService.AwardCounter.FindBySlot(self, clearedSlot)", controller)
        self.assertIn("MasterService.AwardCounter.Remove(self, index, function(handle)", controller)
        self.assertIn("MasterService.AwardCounter.Clear(self, reason, function(handle)", controller)
        self.assertIn("MasterService.AwardCounter.Fail(self, reason, function(handle)", controller)
        self.assertIn("MasterService.AwardCounter.Confirm(self, clearedSlot, function(handle)", controller)
        self.assertIn("MasterService.AwardCounter.HasPending(self)", controller)

    def test_manual_trade_uses_trade_owner_without_service_facade(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)
        trade_menu = read(TRADE_MENU)
        toc = read(MASTER_TOC)

        for method in (
            "GetManualTradeReasonOrder",
            "ResetManualTrade",
            "RefreshManualTradeCandidate",
            "SetManualTradeReason",
            "ApplyManualTradeAccept",
            "HasManualTradeClosePending",
            "CancelManualTradeClose",
            "SettleManualTradeClose",
        ):
            self.assertNotIn("function Master." + method, service)
            self.assertNotIn("MasterService." + method, controller)
            self.assertNotIn("MasterService." + method, trade_menu)

        self.assertFalse(MASTER_SERVICE.exists())
        self.assertNotIn("Services\\Master\\Service.lua", toc)
        self.assertNotIn('"Services/Master/Service"', trade_menu)
        self.assertIn("Services\\Master\\Trade.lua", toc)
        self.assertIn('"Services/Master/Trade"', trade_menu)
        self.assertIn('local MasterService = assert(Services.Master, "Master service namespace is not initialized")', controller)
        self.assertIn('local MasterService = assert(Services.Master, "Master service namespace is not initialized")', trade_menu)
        self.assertNotIn("MasterService and MasterService.Trade", trade_menu)
        self.assertNotIn("MasterService.Trade and MasterService.Trade.", controller)
        self.assertNotIn("masterService and masterService.Trade", trade_menu)
        self.assertNotIn("masterService.Trade and masterService.Trade.", trade_menu)
        self.assertIn("MasterService.Trade.SettleClose()", controller)
        self.assertIn("MasterService.Trade.HasClosePending()", controller)
        self.assertIn("MasterService.Trade.Reset(true, true)", controller)
        self.assertIn("MasterService.Trade.CancelClose(message)", controller)
        self.assertIn("MasterService.Trade.ApplyAccept(playerAccepted, targetAccepted, isAddonDrivenTrade)", controller)
        self.assertIn("MasterService.Trade.GetReasonOrder()", trade_menu)
        self.assertIn("MasterService.Trade.RefreshCandidate({", trade_menu)

    def test_master_controller_registry_names_direct_master_service_owners(self):
        controller = read(MASTER_CONTROLLER)

        required_deps = (
            "Services/Master/FlowState",
            "Services/Master/ButtonState",
            "Services/Master/RollRows",
            "Services/Master/RollUi",
            "Services/Master/MultiAward",
            "Services/Master/AssignmentCandidates",
            "Services/Master/AssignmentTargets",
            "Services/Master/DebugRaidGrid",
            "Services/Master/AwardMessages",
            "Services/Master/LootSpam",
            "Services/Master/RollAnnouncements",
            "Services/Master/AwardCounter",
            "Services/Master/Trade",
        )

        for dep in required_deps:
            with self.subTest(dep=dep):
                self.assertIn('"' + dep + '"', controller)


if __name__ == "__main__":
    unittest.main()
