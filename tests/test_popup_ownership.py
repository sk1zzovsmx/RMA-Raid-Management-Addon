import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
FRAMES = ADDON / "Modules" / "UI" / "Frames.lua"
LOOT_COUNTER = ADDON / "Widgets" / "LootCounter.lua"
MASTER = ADDON / "Controllers" / "Master.lua"
LOGGER = ADDON / "Controllers" / "Logger.lua"
RESERVES_UI = ADDON / "Widgets" / "ReservesUI.lua"
CONFIG = ADDON / "Controllers" / "Config.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class PopupOwnershipTest(unittest.TestCase):
    def test_confirm_popup_helper_preserves_preferred_index_option(self):
        frames = read(FRAMES)
        define_confirm = re.search(
            r"function\s+Popups\.DefineConfirm\s*\(.*?^end",
            frames,
            re.MULTILINE | re.DOTALL,
        )

        self.assertIsNotNone(define_confirm)
        self.assertIn("preferredIndex = options.preferredIndex", define_confirm.group(0))

    def test_loot_counter_reset_all_uses_popup_owner_api(self):
        loot_counter = read(LOOT_COUNTER)

        self.assertIn("local DefineConfirmPopup = assert(Popups.DefineConfirm", loot_counter)
        self.assertIn("local IsPopupDefined = assert(Popups.IsDefined", loot_counter)
        self.assertIn("local ShowPopup = assert(Popups.Show", loot_counter)
        self.assertIn("Popups.DefineConfirm", loot_counter)
        self.assertIn("preferredIndex = 3", loot_counter)
        self.assertIn("ShowPopup(RESET_ALL_POPUP_KEY)", loot_counter)
        self.assertNotIn("not (Popups and Popups.DefineConfirm and Popups.IsDefined)", loot_counter)
        self.assertNotIn("not (Popups and Popups.Show and Popups.Show(RESET_ALL_POPUP_KEY))", loot_counter)
        self.assertNotIn("StaticPopup_Show", loot_counter)
        self.assertNotIn("StaticPopupDialogs", loot_counter)

    def test_master_manual_grid_confirm_uses_popup_owner_api(self):
        master = read(MASTER)

        self.assertIn('local DefinePopup = assert(Popups.Define, "Master popup definer is not initialized")', master)
        self.assertIn(
            'local IsPopupDefined = assert(Popups.IsDefined, "Master popup defined-state checker is not initialized")',
            master,
        )
        self.assertIn('local ShowPopup = assert(Popups.Show, "Master popup shower is not initialized")', master)
        self.assertIn('DefinePopup("RMA_MASTER_LOOT_GRID_CONFIRM"', master)
        self.assertIn('return ShowPopup("RMA_MASTER_LOOT_GRID_CONFIRM"', master)
        self.assertNotIn("not (Popups and Popups.Define and Popups.IsDefined)", master)
        self.assertNotIn("not (Popups and Popups.Show)", master)
        self.assertNotIn("StaticPopupDialogs", master)

    def test_master_group_loot_restore_confirm_uses_popup_owner_api(self):
        master = read(MASTER)

        self.assertIn('local ShowConfirmPopup = assert(Popups.ShowConfirm, "Master confirm popup shower is not initialized")', master)
        self.assertIn("ShowConfirmPopup(", master)
        self.assertIn("GROUP_LOOT_RESTORE_POPUP_KEY,\n\t\t\t\tL.PopupGroupLootRestoreText", master)
        self.assertNotIn("if Popups and Popups.ShowConfirm then", master)
        self.assertNotIn("Popups.ShowConfirm(\n\t\t\t\t\tGROUP_LOOT_RESTORE_POPUP_KEY", master)

    def test_reserves_wrong_csv_popup_uses_popup_owner_api(self):
        reserves_ui = read(RESERVES_UI)

        self.assertIn('local DefinePopup = assert(Popups.Define, "Reserves UI popup definer is not initialized")', reserves_ui)
        self.assertIn(
            'local IsPopupDefined = assert(Popups.IsDefined, "Reserves UI popup defined-state checker is not initialized")',
            reserves_ui,
        )
        self.assertIn('local ShowPopup = assert(Popups.Show, "Reserves UI popup shower is not initialized")', reserves_ui)
        self.assertIn('DefinePopup("RMA_WRONG_CSV_FOR_PLUS"', reserves_ui)
        self.assertIn('ShowPopup("RMA_WRONG_CSV_FOR_PLUS", nil, nil, popupData)', reserves_ui)
        self.assertIn("preferredIndex = 3", reserves_ui)
        self.assertNotIn("not (Popups and Popups.Define and Popups.IsDefined)", reserves_ui)
        self.assertNotIn("ensureWrongCSVPopup() and Popups and Popups.Show", reserves_ui)
        self.assertNotIn("StaticPopup_Show", reserves_ui)
        self.assertNotIn("StaticPopupDialogs", reserves_ui)

    def test_reserves_confirm_popups_use_popup_owner_api(self):
        reserves_ui = read(RESERVES_UI)

        self.assertIn(
            'local DefineConfirmPopup = assert(Popups.DefineConfirm, "Reserves UI confirm popup definer is not initialized")',
            reserves_ui,
        )
        self.assertIn(
            'local ShowConfirmPopup = assert(Popups.ShowConfirm, "Reserves UI confirm popup shower is not initialized")',
            reserves_ui,
        )
        self.assertIn("DefineConfirmPopup(key, text, onAccept, cancels, options)", reserves_ui)
        self.assertIn("return ShowConfirmPopup(key, text, onAccept, cancels, options)", reserves_ui)
        self.assertIn(
            "ShowConfirmPopup(\n\t\t\tCLEAR_SAVED_RESERVES_POPUP_KEY,\n\t\t\tL.StrConfirmClearReserves",
            reserves_ui,
        )
        self.assertNotIn("if not Popups then", reserves_ui)
        self.assertNotIn("Popups.IsDefined and Popups.IsDefined(key) and Popups.DefineConfirm", reserves_ui)
        self.assertNotIn("Popups.ShowConfirm(key, text, onAccept, cancels, options)", reserves_ui)
        self.assertNotIn("Popups\n\t\t\tand Popups.ShowConfirm", reserves_ui)
        self.assertNotIn("return clearSavedReservesFromUI()", reserves_ui)

    def test_config_destructive_confirms_use_popup_owner_api(self):
        config = read(CONFIG)

        self.assertIn('local Popups = assert(UI.Popups, "Config popup namespace is not initialized")', config)
        self.assertIn('local ShowConfirmPopup = assert(Popups.ShowConfirm, "Config confirm popup shower is not initialized")', config)
        self.assertIn("ShowConfirmPopup(popupKey, L.StrConfirmPurgeLootHistory, function()", config)
        self.assertIn("ShowConfirmPopup(\n\t\t\tpopupKey,\n\t\t\tL.StrConfirmClearRaidWarnings", config)
        self.assertNotIn("Popups\n\t\t\tand Popups.ShowConfirm", config)
        self.assertNotIn("Popups.ShowConfirm(popupKey, L.StrConfirmPurgeLootHistory", config)
        self.assertNotIn("Popups.ShowConfirm(\n\t\t\t\tpopupKey,\n\t\t\t\tL.StrConfirmClearRaidWarnings", config)

    def test_logger_roll_type_popup_uses_popup_owner_api(self):
        logger = read(LOGGER)

        self.assertIn('local DefinePopup = assert(Popups.Define, "Logger popup definer is not initialized")', logger)
        self.assertIn(
            'local IsPopupDefined = assert(Popups.IsDefined, "Logger popup defined-state checker is not initialized")',
            logger,
        )
        self.assertIn('local ShowPopup = assert(Popups.Show, "Logger popup shower is not initialized")', logger)
        self.assertIn('local HidePopup = assert(Popups.Hide, "Logger popup hider is not initialized")', logger)
        self.assertIn('local ResizePopup = assert(Popups.Resize, "Logger popup resizer is not initialized")', logger)
        self.assertIn("HidePopup(ROLLTYPE_POPUP_KEY)", logger)
        self.assertIn("ResizePopup(self, self.which)", logger)
        self.assertIn("DefinePopup(ROLLTYPE_POPUP_KEY", logger)
        self.assertIn("ShowPopup(ROLLTYPE_POPUP_KEY, nil, nil, {", logger)
        self.assertNotIn("not (Popups and Popups.Define and Popups.IsDefined)", logger)

    def test_logger_edit_box_popups_use_popup_owner_api(self):
        logger = read(LOGGER)

        self.assertIn('local ShowEditBoxPopup = assert(Popups.ShowEditBox, "Logger edit-box popup shower is not initialized")', logger)
        self.assertIn('ShowEditBoxPopup("RMALOGGER_ITEM_EDIT_WINNER"', logger)
        self.assertIn('ShowEditBoxPopup("RMALOGGER_ITEM_EDIT_VALUE"', logger)
        self.assertNotIn("if not Popups then", logger)
        self.assertNotIn('\t\t\tPopups.ShowEditBox("RMALOGGER_ITEM_EDIT_WINNER"', logger)
        self.assertNotIn('\t\t\tPopups.ShowEditBox("RMALOGGER_ITEM_EDIT_VALUE"', logger)

    def test_logger_delete_confirms_use_popup_owner_api(self):
        logger = read(LOGGER)

        self.assertIn('local ShowConfirmPopup = assert(Popups.ShowConfirm, "Logger confirm popup shower is not initialized")', logger)
        self.assertIn('ShowConfirmPopup("RMALOGGER_DELETE_RAID", L.StrConfirmDeleteRaid, deleteRaids)', logger)
        self.assertIn('ShowConfirmPopup("RMALOGGER_DELETE_ITEM", L.StrConfirmDeleteItem, deleteItem)', logger)
        self.assertNotIn('Popups.ShowConfirm("RMALOGGER_DELETE_RAID"', logger)
        self.assertNotIn('Popups.ShowConfirm("RMALOGGER_DELETE_ITEM"', logger)
        self.assertNotIn("and Popups then", logger)


if __name__ == "__main__":
    unittest.main()
