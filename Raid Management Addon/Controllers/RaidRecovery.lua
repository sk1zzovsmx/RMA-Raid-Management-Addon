-- ----- RMA Lua Contract -----
-- deps: addon.Events, addon.Bus, addon.L, addon.UI.Popups, addon.Services.Raid.Projections
-- shared: none
-- exports: focused recovery confirmation popup
-- events: listens RaidReentryDecisionRequired; emits RaidReentryDecisionResolved
local addon = select(2, ...)
local Events = addon.Events
local Bus = addon.Bus
local L = addon.L
local Popups = assert(addon.UI.Popups, "Raid recovery popup namespace is not initialized")
local Projections = assert(addon.Services.Raid.Projections, "Raid projections are not initialized")
local Required = assert(Events.Internal.RaidReentryDecisionRequired)
local Resolved = assert(Events.Internal.RaidReentryDecisionResolved)
local KEY = "RMA_RAID_REENTRY_CONFIRM"

if not Popups.IsDefined(KEY) then
	Popups.Define(KEY, {
		text = "%s",
		button1 = _G.YES or _G.OKAY,
		button2 = _G.NO or _G.CANCEL,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = false,
		OnAccept = function(_, data)
			Bus.TriggerEvent(Resolved, data.raidUid, "resume", data.context)
		end,
		OnCancel = function(_, data)
			Bus.TriggerEvent(Resolved, data.raidUid, "replace", data.context)
		end,
	})
end

Bus.RegisterCallback(Required, function(_, summary)
	if type(summary) ~= "table" or type(summary.raid) ~= "table" then
		return
	end
	local text = L.PopupRaidReentryConfirm:format(
		tostring(summary.raid.zone),
		tonumber(summary.raid.size) or 0,
		Projections.GetDifficultyLabel(summary.raid)
	)
	Popups.Show(KEY, text, nil, summary)
end)
