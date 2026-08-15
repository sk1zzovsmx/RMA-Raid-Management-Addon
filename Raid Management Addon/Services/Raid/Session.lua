-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag

local Database = addon.Database
local Services = addon.Services

local pairs = pairs
local tonumber = tonumber
local type = type
local SetRaidTarget = assert(_G.SetRaidTarget, Diag.A.RaidSessionTargetIconApiNotInitialized)

do
	addon.Services.EnsureNamespace("Raid")
	local Raid = Services.Raid
	local module = Raid

	-- ----- Internal state ----- --
	local raidInstanceCheckHandles = {}
	local RAID_INSTANCE_CHECK_DELAYS = { 0.3, 0.8, 1.5, 2.5, 3.5 }
	local recognizedInstanceContext
	local boundRaidId
	local boundInstanceKey

	-- ----- Private helpers ----- --
	local isDebugEnabled = addon.Options.IsDebugEnabled

	local function cancelRaidInstanceChecks()
		for idx, handle in pairs(raidInstanceCheckHandles) do
			module:CancelTimer(handle)
			raidInstanceCheckHandles[idx] = nil
		end
	end

	local function runLiveRaidInstanceCheck(refreshInstance)
		if type(refreshInstance) == "function" then
			return refreshInstance()
		end
		return module:Check()
	end

	local function bindCurrentRaid(instanceKey)
		local currentRaid = Database.GetCurrentRaid()
		if currentRaid == nil then
			return false
		end
		boundRaidId = currentRaid
		boundInstanceKey = instanceKey
		return true
	end

	local function createRaidSessionWithReason(instanceName, newSize, instanceDiff, isCreate)
		local created = module:Create(instanceName, newSize, instanceDiff)
		if not created then
			return false
		end
		addon:info(L.StrNewRaidSessionChange)
		local template = isCreate and Diag.D.LogRaidSessionCreate or Diag.D.LogRaidSessionChange
		if isDebugEnabled() then
			addon:debug(template:format(tostring(instanceName), newSize, tonumber(instanceDiff) or -1))
		end
		return true
	end

	-- ----- Public methods ----- --

	function module:InvalidateRaidRuntime(raidNum)
		local raid = Database.EnsureRaidByIndex(raidNum)
		if raid then
			if type(module._InvalidateRaidRuntimeInternal) == "function" then
				module._InvalidateRaidRuntimeInternal(raid)
			end
		end
	end

	function module:CancelInstanceChecks()
		cancelRaidInstanceChecks()
	end

	function module:CommitRecognizedInstanceContext(instanceName, instanceKey, instanceDiff)
		local difficulty = module._ResolveRaidDifficultyInternal(instanceDiff)
		local size = module._GetRaidSizeFromDifficultyInternal(difficulty)
		if type(instanceName) ~= "string" or instanceName == ""
			or type(instanceKey) ~= "string" or instanceKey == ""
			or not size
		then
			recognizedInstanceContext = nil
			return false, "INVALID_RAID_CONTEXT"
		end
		recognizedInstanceContext = {
			zone = instanceName,
			instanceKey = instanceKey,
			size = size,
			difficulty = difficulty,
		}
		return true
	end

	function module:ClearRecognizedInstanceContext()
		recognizedInstanceContext = nil
	end

	function module:GetRecognizedInstanceContext()
		local context = recognizedInstanceContext
		if not context then
			return nil
		end
		return {
			zone = context.zone,
			instanceKey = context.instanceKey,
			size = context.size,
			difficulty = context.difficulty,
		}
	end

	function module:ResolveRaidInstanceContext()
		local context = module:GetRecognizedInstanceContext()
		if not context then
			return nil, "UNRECOGNIZED_RAID_INSTANCE"
		end
		return context
	end

	function module:ScheduleInstanceChecks(refreshInstance)
		cancelRaidInstanceChecks()

		-- Immediate live check, then short retries to catch delayed server fallback updates.
		runLiveRaidInstanceCheck()

		for i = 1, #RAID_INSTANCE_CHECK_DELAYS do
			local idx = i
			local delaySeconds = RAID_INSTANCE_CHECK_DELAYS[idx]
			raidInstanceCheckHandles[idx] = module:ScheduleTimer(function()
				raidInstanceCheckHandles[idx] = nil
				runLiveRaidInstanceCheck(refreshInstance)
			end, delaySeconds)
		end
	end

	-- Checks the current raid status and creates a new session if needed.
	function module:Check()
		local syncer = addon.DB and addon.DB.Syncer
		if syncer and type(syncer.IsAuthorityRecovering) == "function" and syncer:IsAuthorityRecovering() then
			return false, "AUTHORITY_RECOVERING"
		end
		local context, contextReason = module:ResolveRaidInstanceContext()
		if not context then
			return nil, contextReason
		end
		local instanceName = context.zone
		local instanceDiff = context.difficulty
		local newSize = context.size
		if isDebugEnabled() then
			addon:debug(
				Diag.D.LogRaidCheck:format(
					tostring(instanceName),
					tostring(instanceDiff),
					tostring(Database.GetCurrentRaid())
				)
			)
		end
		local currentRaid = Database.GetCurrentRaid()
		if not currentRaid then
			local raidStore = Database.GetRaidStore()
			if raidStore:GetActiveRecord() then
				return false, "RAID_REENTRY_REQUIRED"
			end
			local created, reason = module:Create(context.zone, newSize, instanceDiff)
			if created then
				bindCurrentRaid(context.instanceKey)
			end
			return created, reason
		end

		local current = Database.EnsureRaidByIndex(currentRaid)
		if not current then
			if createRaidSessionWithReason(context.zone, newSize, instanceDiff, true) then
				bindCurrentRaid(context.instanceKey)
			end
			return
		end

		if boundRaidId ~= currentRaid then
			boundRaidId = currentRaid
			boundInstanceKey = context.instanceKey
		end

		local shouldCreate = boundInstanceKey ~= context.instanceKey
			or tonumber(current.size) ~= newSize
			or tonumber(current.difficulty) ~= instanceDiff

		if shouldCreate then
			if createRaidSessionWithReason(context.zone, newSize, instanceDiff, false) then
				bindCurrentRaid(context.instanceKey)
			end
		end
	end

	-- ----- Boss helpers (merged from Raid/Boss.lua) ----- --

	function module:GetBossByNid(bossNid, raidNum)
		raidNum = raidNum or Database.GetCurrentRaid()
		local raid = raidNum and Database.EnsureRaidByIndex(raidNum)
		if not raid or bossNid == nil then
			return nil
		end

		Database.EnsureRaidSchema(raid)

		bossNid = tonumber(bossNid) or 0
		if bossNid <= 0 then
			return nil
		end

		local bosses = raid.bossKills
		for i = 1, #bosses do
			local b = bosses[i]
			if b and tonumber(b.bossNid) == bossNid then
				return b, i
			end
		end
		return nil
	end

	function module:ClearRaidIcons()
		local players = module:GetPlayers()
		for i = 1, #players do
			SetRaidTarget("raid" .. tostring(i), 0)
		end
	end
end
