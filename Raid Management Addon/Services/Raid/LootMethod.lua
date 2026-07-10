-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Raid loot-method automation APIs
-- events: listens forwarded PLAYER_TARGET_CHANGED through Master; emits GroupLootRestoreNeeded
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Bus = feature.Bus
local Database = feature.Database
local Events = feature.Events
local Options = feature.Options
local Services = feature.Services

local tostring, tonumber, type = tostring, tonumber, type

local _G = _G
local GetTime = assert(_G.GetTime, "Raid loot method time API is not initialized")
local SetLootMethod = assert(_G.SetLootMethod, "Raid loot method setter API is not initialized")
local UnitExists = assert(_G.UnitExists, "Raid loot method unit existence API is not initialized")
local UnitGUID = assert(_G.UnitGUID, "Raid loot method unit GUID API is not initialized")
local UnitInRaid = assert(_G.UnitInRaid, "Raid loot method unit raid-membership API is not initialized")
local UnitIsDead = assert(_G.UnitIsDead, "Raid loot method unit death-state API is not initialized")
local UnitName = assert(_G.UnitName, "Raid loot method unit name API is not initialized")
local GetCreatureId = assert(feature.GetCreatureId, "Raid loot method creature-id helper is not initialized")
local InternalEvents = assert(Events.Internal, "Raid loot method event registry is not initialized")
local ScreenNoticeEvent = assert(InternalEvents.ScreenNotice, "Raid loot method screen notice event is not initialized")
local GroupLootRestoreNeededEvent =
	assert(InternalEvents.GroupLootRestoreNeeded, "Raid loot method restore notification is not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Raid loot method event bus sender is not initialized")

local AUTO_MASTER_LOOT_COOLDOWN_SECONDS = 3
local DEFAULT_AUTO_MASTER_LOOT_NOTICE_SECONDS = 1.25
local MIN_AUTO_MASTER_LOOT_NOTICE_SECONDS = 0.1
local MAX_AUTO_MASTER_LOOT_NOTICE_SECONDS = 5

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Raid")
local Raid = Services.Raid
local module = Raid

Options.AddNamespace("Master", {
	autoMasterLootOnBossTarget = false,
	autoMasterLootNoticeSeconds = 1.25,
	askGroupLootAfterBossLoot = false,
})

local state = {
	lastAutoMasterAt = 0,
	lastAutoMasterBoss = nil,
	lootWindowWasBoss = false,
	lootWindowWasMasterLoot = false,
	lootWindowPromptShown = false,
}

-- ----- Private helpers ----- --
local GetOption = Options.GetValue

local function getAutoMasterLootNoticeSeconds()
	local seconds = tonumber(GetOption("Master", "autoMasterLootNoticeSeconds"))
		or DEFAULT_AUTO_MASTER_LOOT_NOTICE_SECONDS
	if seconds < MIN_AUTO_MASTER_LOOT_NOTICE_SECONDS then
		return MIN_AUTO_MASTER_LOOT_NOTICE_SECONDS
	end
	if seconds > MAX_AUTO_MASTER_LOOT_NOTICE_SECONDS then
		return MAX_AUTO_MASTER_LOOT_NOTICE_SECONDS
	end
	return seconds
end

local function hasRaidLeaderAuthority()
	if not UnitInRaid("player") then
		return false
	end
	if not (module and module.GetPlayerRoleState) then
		return false
	end
	local role = module:GetPlayerRoleState()
	return role and role.isLeader == true
end

local function getPlayerName()
	local dbName = Database.GetPlayerName()
	if dbName and dbName ~= "" then
		return dbName
	end
	return UnitName("player")
end

local function getTargetBossInfo(allowDead)
	if not UnitExists("target") then
		return nil
	end
	if not allowDead and UnitIsDead("target") then
		return nil
	end

	local guid = UnitGUID("target")
	local npcId = guid and GetCreatureId(guid) or nil
	local bossIds = feature.BossIDs and feature.BossIDs.BossIDs
	if not (npcId and bossIds and bossIds[tonumber(npcId)] == true) then
		return nil
	end

	return {
		name = UnitName("target"),
		npcId = tonumber(npcId),
	}
end

local function showCenterNotice(message)
	if not message or message == "" then
		return false
	end
	TriggerEvent(ScreenNoticeEvent, message, getAutoMasterLootNoticeSeconds())
	return true
end

local function notifyGroupLootRestoreNeeded()
	TriggerEvent(GroupLootRestoreNeededEvent)
	return true
end

local function clearLootWindowPromptState()
	state.lootWindowWasBoss = false
	state.lootWindowWasMasterLoot = false
	state.lootWindowPromptShown = false
end

-- ----- Public methods ----- --
function module:HandleAutoMasterLootTargetChanged()
	-- PLAYER_TARGET_CHANGED
	if GetOption("Master", "autoMasterLootOnBossTarget") ~= true then
		return false
	end
	if not hasRaidLeaderAuthority() then
		return false
	end
	if module:GetLootMethodName() == "master" then
		return false
	end

	local boss = getTargetBossInfo(false)
	if not boss then
		return false
	end

	local now = GetTime()
	if
		state.lastAutoMasterBoss == boss.name
		and (now - (tonumber(state.lastAutoMasterAt) or 0)) < AUTO_MASTER_LOOT_COOLDOWN_SECONDS
	then
		return false
	end

	local playerName = getPlayerName()
	if not playerName or playerName == "" then
		return false
	end

	showCenterNotice(L.MsgAutoMasterLootScreen or "Boss targeted, auto switch to Master Loot.")
	SetLootMethod("master", playerName)
	state.lastAutoMasterAt = now
	state.lastAutoMasterBoss = boss.name
	addon:info(
		(L.MsgAutoMasterLootSet or "RMA: Loot method set to Master Loot for %s."):format(
			tostring(boss.name or "Unknown")
		)
	)
	return true
end

function module:NotifyLootWindowOpened()
	clearLootWindowPromptState()
	if GetOption("Master", "askGroupLootAfterBossLoot") ~= true then
		return false
	end
	if not hasRaidLeaderAuthority() then
		return false
	end
	state.lootWindowWasMasterLoot = module:GetLootMethodName() == "master"
	state.lootWindowWasBoss = getTargetBossInfo(true) ~= nil
	return state.lootWindowWasMasterLoot and state.lootWindowWasBoss
end

function module:NotifyLootWindowCleared()
	if GetOption("Master", "askGroupLootAfterBossLoot") ~= true then
		return false
	end
	if state.lootWindowPromptShown or not state.lootWindowWasMasterLoot or not state.lootWindowWasBoss then
		return false
	end
	if not hasRaidLeaderAuthority() or module:GetLootMethodName() ~= "master" then
		clearLootWindowPromptState()
		return false
	end
	if not notifyGroupLootRestoreNeeded() then
		return false
	end

	state.lootWindowPromptShown = true
	return true
end

function module:RestoreGroupLoot(source)
	if not hasRaidLeaderAuthority() then
		return false
	end
	if module:GetLootMethodName() ~= "master" then
		clearLootWindowPromptState()
		return false
	end

	SetLootMethod("group")
	clearLootWindowPromptState()
	addon:info(L.MsgGroupLootRestored or "RMA: Loot method set to Group Loot.")
	return true, source
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Raid/LootMethod", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Modules/Events",
			"Modules/Bus",
			"Database/DB",
			"Database/DBOptions",
			"Services/Raid/Capabilities",
		},
	})
	registry.SetLoaded("Services/Raid/LootMethod")
end
