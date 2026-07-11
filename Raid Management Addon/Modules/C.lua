-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local C = addon.C or {}
addon.C = C
local L = addon.L

-- ----- Internal state ----- --

-- ----- Private helpers ----- --

-- ----- Public methods ----- --

C.ITEM_LINK_PATTERN = "|?c?(%x*)|?H?([^:]*):?(%d+):?(%d*):?(%d*):?(%d*):?(%d*):?(%d*):?"
	.. "(%-?%d*):?(%-?%d*):?(%d*)|?h?%[?([^%[%]]*)%]?|?h?|?r?"

-- Roll Types Enum
C.rollTypes = {
	MANUAL = 0,
	MAINSPEC = 1,
	OFFSPEC = 2,
	RESERVED = 3,
	FREE = 4,
	BANK = 5,
	DISENCHANT = 6,
	HOLD = 7,
	NEED = 8,
	GREED = 9,
}

-- Roll Type Colored Display Text
C.lootTypesColored = {
	[0] = "|cffc0c0c0" .. L.BtnManual .. "|r",
	[1] = "|cff20ff20" .. L.BtnMS .. "|r",
	[2] = "|cffffff9f" .. L.BtnOS .. "|r",
	[3] = "|cffa335ee" .. L.BtnSR .. "|r",
	[4] = "|cffffd200" .. L.BtnFree .. "|r",
	[5] = "|cffff7f00" .. L.BtnBank .. "|r",
	[6] = "|cffff2020" .. L.BtnDisenchant .. "|r",
	[7] = "|cffffffff" .. L.BtnHold .. "|r",
	[8] = "|cff33ddff" .. L.BtnNeed .. "|r",
	[9] = "|cffffd966" .. L.BtnGreed .. "|r",
}

-- Item Quality Colors
C.itemColors = {
	[1] = "ff9d9d9d", -- Poor
	[2] = "ffffffff", -- Common
	[3] = "ff1eff00", -- Uncommon
	[4] = "ff0070dd", -- Rare
	[5] = "ffa335ee", -- Epic
	[6] = "ffff8000", -- Legendary
	[7] = "ffe6cc80", -- Artifact / Heirloom
}

-- Class Colors
C.CLASS_COLORS = {
	["UNKNOWN"] = "ffffffff",
	["DEATHKNIGHT"] = "ffc41f3b",
	["DRUID"] = "ffff7d0a",
	["HUNTER"] = "ffabd473",
	["MAGE"] = "ff40c7eb",
	["PALADIN"] = "fff58cba",
	["PRIEST"] = "ffffffff",
	["ROGUE"] = "fffff569",
	["SHAMAN"] = "ff0070de",
	["WARLOCK"] = "ff8787ed",
	["WARRIOR"] = "ffc79c6e",
}

-- Raid Target Markers
C.RAID_TARGET_MARKERS = {
	"{circle}",
	"{diamond}",
	"{triangle}",
	"{moon}",
	"{square}",
	"{cross}",
	"{skull}",
}

C.K_COLOR = "fff58cba"
C.RT_COLOR = "aaf49141"
C.titleString = "|c" .. C.K_COLOR .. "K|r|c" .. C.RT_COLOR .. "RT|r : %s"

C.CHAT_OUTPUT_FORMAT = "%s: %s"
C.CHAT_PREFIX_SHORT = "RMA"
C.CHAT_PREFIX_HEX = C.K_COLOR

-- Multi-award pacing (seconds) to avoid spamming GiveMasterLoot on laggy servers.
C.ML_MULTI_AWARD_DELAY = 0.2
-- Safety timeout: abort multi-award if the loot window does not reflect expected decrements.
C.ML_MULTI_AWARD_TIMEOUT_SECONDS = 4
-- Safety timeout: abandon unconfirmed Master Loot counter credits if no slot clear/error arrives.
C.ML_AWARD_CONFIRM_TIMEOUT_SECONDS = 4
C.PENDING_AWARD_TTL_SECONDS = 8
-- Passive Group Loot / Need Before Greed falls back to a short fixed window
-- only when START_LOOT_ROLL metadata is unavailable.
C.GROUP_LOOT_PENDING_AWARD_TTL_SECONDS = 60
C.GROUP_LOOT_ROLL_GRACE_SECONDS = 10
C.BOSS_KILL_DEDUPE_WINDOW_SECONDS = 30
C.BOSS_EVENT_CONTEXT_TTL_SECONDS = 30
C.RECENT_LOOT_DEATH_CONTEXT_TTL_SECONDS = 8
C.RECENT_TRASH_DEATH_CONTEXT_THROTTLE_SECONDS = 1

C.LOOT_COUNTER_ROW_HEIGHT = 25
C.RESERVES_ITEM_FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
C.RESERVES_QUERY_COOLDOWN_SECONDS = 2
