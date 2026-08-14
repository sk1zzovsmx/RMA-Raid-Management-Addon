-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Raid loot-method automation APIs
-- events: listens forwarded PLAYER_TARGET_CHANGED through Master; emits GroupLootRestoreNeeded
local addon = select(2, ...)
local Diag = addon.Diag
local L = addon.L
local Bus = addon.Bus
local Database = addon.Database
local Events = addon.Events
local Options = addon.Options
local Services = addon.Services
local Raid = assert(Services.Raid, Diag.A.RaidLootMethodServiceOwnerNotInitialized)

local tostring, tonumber, type = tostring, tonumber, type

local _G = _G
local GetTime = assert(_G.GetTime, Diag.A.RaidLootMethodTimeApiNotInitialized)
local SetLootMethod = assert(_G.SetLootMethod, Diag.A.RaidLootMethodSetterApiNotInitialized)
local UnitExists = assert(_G.UnitExists, Diag.A.RaidLootMethodUnitExistenceApiNotInitialized)
local UnitGUID = assert(_G.UnitGUID, Diag.A.RaidLootMethodUnitGuidApiNotInitialized)
local UnitInRaid = assert(_G.UnitInRaid, Diag.A.RaidLootMethodUnitRaidMembershipApiNotInitialized)
local UnitIsDead = assert(_G.UnitIsDead, Diag.A.RaidLootMethodUnitDeathStateApiNotInitialized)
local UnitName = assert(_G.UnitName, Diag.A.RaidLootMethodUnitNameApiNotInitialized)
local GetCreatureId = assert(Raid.GetCreatureId, Diag.A.RaidLootMethodCreatureIdHelperNotInitialized)
local InternalEvents = assert(Events.Internal, Diag.A.RaidLootMethodEventRegistryNotInitialized)
local ScreenNoticeEvent = assert(InternalEvents.ScreenNotice, Diag.A.RaidLootMethodScreenNoticeEventNotInitialized)
local GroupLootRestoreNeededEvent =
	assert(InternalEvents.GroupLootRestoreNeeded, Diag.A.RaidLootMethodRestoreNotificationNotInitialized)
local TriggerEvent = assert(Bus.TriggerEvent, Diag.A.RaidLootMethodEventBusSenderNotInitialized)

local AUTO_MASTER_LOOT_COOLDOWN_SECONDS = 3
local DEFAULT_AUTO_MASTER_LOOT_NOTICE_SECONDS = 1.25
local MIN_AUTO_MASTER_LOOT_NOTICE_SECONDS = 0.1
local MAX_AUTO_MASTER_LOOT_NOTICE_SECONDS = 5

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Raid")
local module = Raid

Options.RegisterNamespace("Master", {
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
	local bossIds = addon.BossIDs and addon.BossIDs.BossIDs
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
function module:RequestLootMethod(method)
	if method ~= "master" and method ~= "group" then
		addon:warn(L.MsgQuickBarLootMethodUnsupported)
		return false, "unsupported_method"
	end
	if not UnitInRaid("player") then
		addon:warn(L.MsgQuickBarRaidRequired)
		return false, "not_in_raid"
	end
	if not hasRaidLeaderAuthority() then
		addon:warn(L.MsgQuickBarLeaderRequired)
		return false, "not_leader"
	end
	if self:GetLootMethodName() == method then
		return true
	end
	if method == "master" then
		local playerName = getPlayerName()
		if not playerName or playerName == "" then
			addon:warn(L.MsgQuickBarPlayerNameUnavailable)
			return false, "player_name_unavailable"
		end
		SetLootMethod("master", playerName)
		addon:info(L.MsgQuickBarMasterLootSet)
	else
		SetLootMethod("group")
		addon:info(L.MsgQuickBarGroupLootSet)
	end
	return true
end

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

	showCenterNotice(L.MsgAutoMasterLootScreen)
	SetLootMethod("master", playerName)
	state.lastAutoMasterAt = now
	state.lastAutoMasterBoss = boss.name
	addon:info(
		L.MsgAutoMasterLootSet:format(
			tostring(boss.name or L.StrUnknown)
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
	addon:info(L.MsgGroupLootRestored)
	return true, source
end
