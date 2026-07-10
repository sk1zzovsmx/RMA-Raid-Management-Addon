-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: centralized event-name registry helpers

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local type, tostring = type, tostring

local Events = feature.Events or {}
addon.Events = Events
local Database = feature.Database

-- ----- Internal state ----- --
Events.Internal = Events.Internal or {}
Events.Wow = Events.Wow or {}

local Internal = Events.Internal
local Wow = Events.Wow

Database.EnsureBootstrapEvents()

Wow.OpenMasterLootList = Wow.OpenMasterLootList or "wow.OPEN_MASTER_LOOT_LIST"
Wow.UpdateMasterLootList = Wow.UpdateMasterLootList or "wow.UPDATE_MASTER_LOOT_LIST"
Wow.ReadyCheck = Wow.ReadyCheck or "wow.READY_CHECK"
Wow.InspectTalentReady = Wow.InspectTalentReady or "wow.INSPECT_TALENT_READY"
Wow.PlayerRegenEnabled = Wow.PlayerRegenEnabled or "wow.PLAYER_REGEN_ENABLED"

Internal.AddRoll = "AddRoll"
Internal.SpecInspectUpdated = "SpecInspectUpdated"
Internal.LoggerLootChanged = "LoggerLootChanged"
Internal.LoggerDataChanged = "LoggerDataChanged"
Internal.LoggerSelectRaid = "LoggerSelectRaid"
Internal.LoggerSelectBoss = "LoggerSelectBoss"
Internal.LoggerSelectPlayer = "LoggerSelectPlayer"
Internal.LoggerSelectBossPlayer = "LoggerSelectBossPlayer"
Internal.LoggerSelectItem = "LoggerSelectItem"
Internal.LoggerClearPlayerSelections = "LoggerClearPlayerSelections"
Internal.PlayerCountChanged = "PlayerCountChanged"
Internal.RaidRosterDelta = "RaidRosterDelta"
Internal.RaidCreate = "RaidCreate"
Internal.RaidLootUpdate = "RaidLootUpdate"
Internal.ReservesDataChanged = "ReservesDataChanged"
Internal.WarningsDataChanged = "WarningsDataChanged"
Internal.GroupLootRestoreNeeded = "GroupLootRestoreNeeded"
Internal.ScreenNotice = "ScreenNotice"
Internal.SetItem = "SetItem"
Internal.RaidAttendanceChanged = "RaidAttendanceChanged"
Internal.EquipInspectStarted = "EquipInspectStarted"
Internal.EquipInspectUpdated = "EquipInspectUpdated"
Internal.EquipInspectCompleted = "EquipInspectCompleted"

Internal.ConfigSortAscending = "ConfigsortAscending"
Internal.ConfigShowLootCounterDuringMSRoll = "ConfigshowLootCounterDuringMSRoll"

-- ----- Private helpers ----- --

-- ----- Public methods ----- --
function Events.GetConfigOptionChanged(optionName)
	if type(optionName) ~= "string" or optionName == "" then
		return nil
	end
	return "Config" .. optionName
end

function Events.GetWowForwarded(eventName)
	if type(eventName) ~= "string" or eventName == "" then
		return nil
	end
	return Wow[eventName] or ("wow." .. tostring(eventName))
end

do
	local name = "Modules/Events"
	local deps = { "Init" }
	local registry = feature.ModuleRegistry
	if registry then
		registry.AddModule(name, { deps = deps })
		registry.SetLoaded(name)
	else
		addon.ModuleRegistryPendingRegistrations = addon.ModuleRegistryPendingRegistrations or {}
		local pending = addon.ModuleRegistryPendingRegistrations
		pending[#pending + 1] = { name = name, deps = deps, loaded = true }
	end
end
