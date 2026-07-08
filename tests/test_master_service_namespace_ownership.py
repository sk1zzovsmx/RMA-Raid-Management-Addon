import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MASTER_SERVICES = ROOT / "Raid Management Addon" / "Services" / "Master"
MASTER_SERVICE = MASTER_SERVICES / "Service.lua"
MASTER_ROLL_UI = MASTER_SERVICES / "RollUi.lua"
MASTER_MULTI_AWARD = MASTER_SERVICES / "MultiAward.lua"
MASTER_ASSIGNMENT = MASTER_SERVICES / "Assignment.lua"
MASTER_MESSAGES = MASTER_SERVICES / "Messages.lua"
DEBUG_SERVICE = ROOT / "Raid Management Addon" / "Services" / "Debug.lua"
MASTER_ITEM_SELECTION = MASTER_SERVICES / "ItemSelection.lua"
MASTER_TRADE_EXECUTION = MASTER_SERVICES / "TradeExecution.lua"
MASTER_CONTROLLER = ROOT / "Raid Management Addon" / "Controllers" / "Master.lua"
MASTER_TOC = ROOT / "Raid Management Addon" / "Raid Management Addon.toc"
TRADE_MENU = ROOT / "Raid Management Addon" / "Widgets" / "TradeMenu.lua"


def read(path):
    return path.read_text(encoding="utf-8")


def read_optional(path):
    if not path.exists():
        return ""
    return read(path)


def extract_method_body(text, signature):
    start = text.index(signature)
    body = text[start:]
    next_method = body.find("\n\tfunction ", 1)
    next_registry = body.find("\nlocal registry =", 1)
    end = len(body)
    if next_method != -1:
        end = min(end, next_method)
    if next_registry != -1:
        end = min(end, next_registry)
    return body[:end]


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
        self.assertLess(toc.index("Services\\Master\\MultiAward.lua"), toc.index("Services\\Master\\Assignment.lua"))
        self.assertLess(toc.index("Services\\Master\\MultiAward.lua"), toc.index("Controllers\\Master.lua"))

    def test_master_controller_delegates_inventory_trade_execution_to_owner(self):
        controller = read(MASTER_CONTROLLER)
        trade_execution = read_optional(MASTER_TRADE_EXECUTION)
        toc = read(MASTER_TOC)
        trade_accept_update = extract_method_body(controller, "function module:TRADE_ACCEPT_UPDATE(playerAccepted, targetAccepted)")

        self.assertNotIn("Private.ResolveTradeExecutionWinner = function", controller)
        self.assertNotIn("Private.PrepareTradeableItem = function", controller)
        self.assertNotIn("Private.TryInitiateTrade = function", controller)
        self.assertNotIn("Private.BuildTradeUiNotificationPlan = function", controller)
        self.assertNotIn("function tradeItem(itemLink, playerName, rollType, rollValue)", controller)
        self.assertNotIn("tradeItem = function(itemLink, playerName, rollType, rollValue)", controller)
        self.assertNotIn("Private.CompleteTraderKeepAward = function", controller)
        self.assertNotIn("Private.BeginTradeItemState = function", controller)

        self.assertIn(
            'local TradeExecutionService = assert(MasterService.TradeExecution, "Master trade execution service is not initialized")',
            controller,
        )
        self.assertIn("tradeExecutionController = TradeExecutionService.CreateController({", controller)
        self.assertIn(
            "local result = tradeExecutionController:TradeItem(",
            controller,
        )
        self.assertIn("ok = tradeExecutionController:TradeItem(itemLink, target, rollType, 0)", controller)
        self.assertIn("RMATradeHandled = tradeExecutionController:HandleAcceptedAwardTrade(playerAccepted, targetAccepted)", controller)
        self.assertNotIn("LootInventory.ResolveTradeAwardedCount()", trade_accept_update)
        self.assertNotIn("ensureTradeLootContext(", trade_accept_update)
        self.assertNotIn("requestLoggerLootLog(", trade_accept_update)
        self.assertNotIn('Loot:SetDistributionState("item_done"', trade_accept_update)

        self.assertIn("function TradeExecution.CreateController(opts)", trade_execution)
        self.assertIn("function controller:ResolveWinner(playerName, isAwardRoll)", trade_execution)
        self.assertIn("function controller:PrepareTradeableItem(itemLink)", trade_execution)
        self.assertIn(
            "function controller:BeginTradeItemState(itemLink, playerName, rollType, rollValue, isAwardRoll)",
            trade_execution,
        )
        self.assertIn(
            "function controller:BuildNotificationPlan(itemLink, playerName, winnerName, rollType, isAwardRoll)",
            trade_execution,
        )
        self.assertIn(
            "function controller:CompleteTraderKeepAward(itemLink, winnerName, rollType, rollValue, output, whisper)",
            trade_execution,
        )
        self.assertIn(
            "function controller:HandleAcceptedAwardTrade(playerAccepted, targetAccepted)",
            trade_execution,
        )
        self.assertIn("function controller:TradeItem(itemLink, playerName, rollType, rollValue)", trade_execution)
        self.assertNotIn("function controller:CompleteInventoryAwardProgress(completedWinner, rollType, awardedCount)", trade_execution)
        self.assertIn("local awardedCount = self.inventory.ResolveTradeAwardedCount()", trade_execution)
        self.assertIn("local lootNid, createdTradeOnly = self.ensureTradeLootContext(", trade_execution)
        self.assertIn("local ok = self.requestLoggerLootLog(", trade_execution)
        self.assertIn('self.loot:SetDistributionState("item_done", {', trade_execution)

        self.assertLess(toc.index("Services\\Master\\Trade.lua"), toc.index("Services\\Master\\TradeExecution.lua"))
        self.assertLess(toc.index("Services\\Master\\TradeExecution.lua"), toc.index("Controllers\\Master.lua"))

    def test_master_controller_delegates_item_selection_owner(self):
        controller = read(MASTER_CONTROLLER)
        item_selection = read_optional(MASTER_ITEM_SELECTION)
        toc = read(MASTER_TOC)

        self.assertNotIn("local function getSelectionButtonRefs", controller)
        self.assertNotIn("local function anchorSelectionFrame", controller)
        self.assertNotIn("local function ensureSelectionButton", controller)
        self.assertNotIn("local function createSelectionFrame", controller)
        self.assertNotIn("function updateSelectionFrame()", controller)
        self.assertNotIn("Private.TryAcceptInventoryItemFromCursor = function", controller)

        self.assertIn(
            'local ItemSelectionService = assert(MasterService.ItemSelection, "Master item selection service is not initialized")',
            controller,
        )
        self.assertIn("itemSelectionController = ItemSelectionService.CreateController({", controller)
        self.assertIn("itemSelectionController:TryAcceptFromCursor()", controller)
        self.assertIn("itemSelectionController:UpdateFrame()", controller)
        self.assertIn("itemSelectionController:HideFrame()", controller)
        self.assertIn("itemSelectionController:Reset()", controller)

        self.assertIn("function ItemSelection.CreateController(opts)", item_selection)
        self.assertIn("function controller:ApplyInventoryItem(itemLink, totalCount, bag, slot, slotCount)", item_selection)
        self.assertIn("function controller:TryAcceptFromCursor()", item_selection)
        self.assertIn("function controller:UpdateFrame()", item_selection)
        self.assertIn("function controller:HideFrame()", item_selection)
        self.assertIn("function controller:Reset()", item_selection)
        self.assertIn('"RMAItemSelectionFrame"', item_selection)
        self.assertIn('"RMAItemSelectionButton"', item_selection)

        self.assertLess(toc.index("Services\\Master\\TradeExecution.lua"), toc.index("Services\\Master\\ItemSelection.lua"))
        self.assertLess(toc.index("Services\\Master\\ItemSelection.lua"), toc.index("Widgets\\RaidGrid.lua"))
        self.assertLess(toc.index("Services\\Master\\ItemSelection.lua"), toc.index("Controllers\\Master.lua"))

    def test_master_controller_uses_single_message_plan_owner_without_micro_services(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)
        messages = read(MASTER_MESSAGES)
        toc = read(MASTER_TOC)

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
        self.assertFalse((MASTER_SERVICES / "AwardMessages.lua").exists())
        self.assertFalse((MASTER_SERVICES / "LootSpam.lua").exists())
        self.assertFalse((MASTER_SERVICES / "RollAnnouncements.lua").exists())
        self.assertIn("MasterService.Messages.BuildAssignMessages({", controller)
        self.assertIn("MasterService.Messages.BuildLootSpamPlan({", controller)
        self.assertIn("MasterService.Messages.BuildRollAnnouncementPlan({", controller)
        self.assertIn("function Messages.BuildAssignMessages(opts)", messages)
        self.assertIn("function Messages.BuildLootSpamPlan(opts)", messages)
        self.assertIn("function Messages.BuildRollAnnouncementPlan(opts)", messages)
        self.assertIn("Services\\Master\\Messages.lua", toc)
        self.assertNotIn("Services\\Master\\AwardMessages.lua", toc)
        self.assertNotIn("Services\\Master\\LootSpam.lua", toc)
        self.assertNotIn("Services\\Master\\RollAnnouncements.lua", toc)
        self.assertLess(toc.index("Services\\Master\\Messages.lua"), toc.index("Controllers\\Master.lua"))

    def test_master_assignment_service_is_pure_model_policy(self):
        service = read_optional(MASTER_SERVICE)
        controller = read(MASTER_CONTROLLER)
        assignment = read(MASTER_ASSIGNMENT)
        debug_service = read(DEBUG_SERVICE)
        toc = read(MASTER_TOC)

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
        self.assertFalse((MASTER_SERVICES / "AssignmentUi.lua").exists())
        self.assertFalse((MASTER_SERVICES / "AssignmentCandidates.lua").exists())
        self.assertFalse((MASTER_SERVICES / "AssignmentTargets.lua").exists())
        self.assertFalse((MASTER_SERVICES / "AssignmentHelpers.lua").exists())
        self.assertFalse((MASTER_SERVICES / "DebugRaidGrid.lua").exists())
        self.assertNotIn("MasterService.AssignmentCandidates.BuildRows(", controller)
        self.assertNotIn("MasterService.DebugRaidGrid.IsFallbackEnabled(", controller)
        self.assertNotIn("MasterService.DebugRaidGrid.GetTargetCount(", controller)
        self.assertNotIn("MasterService.DebugRaidGrid.BuildRows(", controller)
        self.assertNotIn("MasterService.AssignmentTargets.BuildRows(", controller)
        self.assertIn('local AssignmentService = assert(MasterService.Assignment, "Master assignment service is not initialized")', controller)
        self.assertIn('local DebugService = assert(Services.Debug, "Debug service is not initialized")', controller)
        self.assertIn("AssignmentService.BuildCandidateRows(collectMasterLootCandidates(), getRaidGridPlayerClass)", controller)
        self.assertIn("AssignmentService.BuildTargetRows(module._dropDownData, getRaidGridPlayerClass)", controller)
        self.assertIn("DebugService.IsRaidGridDebugFallbackEnabled(", controller)
        self.assertIn("DebugService.GetRaidGridDebugTargetCount(debugState)", controller)
        self.assertIn("DebugService.BuildRaidGridDebugRows(count, collectRaidGridRosterRows())", controller)

        self.assertIn("function Assignment.ResolveClass(classProvider, name)", assignment)
        self.assertIn("function Assignment.BuildCandidateRows(candidates, classProvider)", assignment)
        self.assertIn("function Assignment.BuildTargetRows(groupedNames, classProvider)", assignment)
        self.assertIn("function module.BuildRaidGridDebugRows(count, rosterRows)", debug_service)
        self.assertIn("function module.GetRaidGridDebugTargetCount(debugState)", debug_service)
        self.assertIn("function module.IsRaidGridDebugFallbackEnabled(debugState, debugEnabled)", debug_service)

        forbidden_service_ui = (
            "UIDropDownMenu_",
            "CloseDropDownMenus",
            "DropDownList",
            "ShowPopup",
            "DefinePopup",
            "UI.Widgets",
            "CreateFrame",
            "GetFrameRef",
            "SetScript",
            "HookScript",
            "RaidGrid",
        )
        for token in forbidden_service_ui:
            with self.subTest(token=token):
                self.assertNotIn(token, assignment)

        self.assertIn("Services\\Master\\Assignment.lua", toc)
        self.assertNotIn("Services\\Master\\AssignmentUi.lua", toc)
        self.assertNotIn("Services\\Master\\AssignmentCandidates.lua", toc)
        self.assertNotIn("Services\\Master\\AssignmentTargets.lua", toc)
        self.assertNotIn("Services\\Master\\AssignmentHelpers.lua", toc)
        self.assertNotIn("Services\\Master\\DebugRaidGrid.lua", toc)
        self.assertLess(toc.index("Services\\Master\\Assignment.lua"), toc.index("Controllers\\Master.lua"))

    def test_master_controller_owns_assignment_ui_orchestration(self):
        controller = read(MASTER_CONTROLLER)
        toc = read(MASTER_TOC)

        self.assertNotIn("AssignmentUiService", controller)
        self.assertNotIn("assignmentUiController", controller)
        self.assertIn("Private.PrepareDropDowns = function()", controller)
        self.assertIn("Private.InitializeDropDowns = function()", controller)
        self.assertIn("local function updateAssignmentDropDown(frame)", controller)
        self.assertIn("Private.OpenManualAwardGrid = function()", controller)
        self.assertIn("Private.RefreshManualAwardGrid = function()", controller)
        self.assertIn("Private.AcceptManualGridAward = function(data)", controller)
        self.assertIn("Private.OnClickDropDown = function(_button, owner, value)", controller)
        self.assertIn("UIDropDownMenu_Initialize(frame, Private.InitializeDropDownMenu)", controller)
        self.assertIn("UI.Widgets.CallFunction(\"RaidGrid\", \"ShowPicker\"", controller)
        self.assertIn("Private.OpenManualAwardGrid()", controller)
        self.assertIn("Private.RefreshManualAwardGrid()", controller)

        self.assertLess(toc.index("Services\\Master\\Assignment.lua"), toc.index("Controllers\\Master.lua"))

    def test_master_controller_restores_raid_grid_unit_class_fallback(self):
        controller = read(MASTER_CONTROLLER)

        collect_roster_rows = extract_method_body(controller, "local function collectRaidGridRosterRows()")
        self.assertIn("local className = getRaidGridPlayerClass(name)", collect_roster_rows)
        self.assertIn("if not className then", collect_roster_rows)
        self.assertIn("local _, classFileName = UnitClass(unit)", collect_roster_rows)
        self.assertIn("className = classFileName", collect_roster_rows)
        self.assertIn("class = className", collect_roster_rows)

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
            "Services/Master/Assignment",
            "Services/Debug",
            "Services/Master/Messages",
            "Services/Master/AwardCounter",
            "Services/Master/Trade",
            "Services/Master/TradeExecution",
            "Services/Master/ItemSelection",
        )

        for dep in required_deps:
            with self.subTest(dep=dep):
                self.assertIn('"' + dep + '"', controller)

    def test_master_extracted_owners_receive_warning_callback_without_missing_flag_gate(self):
        controller = read(MASTER_CONTROLLER)

        self.assertNotIn("addon.hasWarn", controller)
        self.assertGreaterEqual(controller.count("warn = function(message)"), 3)
        self.assertGreaterEqual(controller.count("return addon:warn(message)"), 3)


if __name__ == "__main__":
    unittest.main()
