-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: emits RaidRosterDelta
local addon = select(2, ...)
local Diag = addon.Diag

local Database = addon.Database
local SavedVariables = Database.SavedVariables
local Events = addon.Events
local Bus = addon.Bus
local Services = addon.Services
local Strings = addon.Strings
local Time = addon.Time
local Timer = addon.Timer
local coreState = addon.State

local InternalEvents = assert(Events.Internal, "Raid roster internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Raid roster event publisher is not initialized")
local RaidRosterDeltaEvent = assert(InternalEvents.RaidRosterDelta, "Raid roster delta event is not initialized")

local tinsert, twipe = table.insert, table.wipe
local pairs, ipairs, type = pairs, ipairs, type
local strlen = string.len
local strsub = string.sub
local strmatch = string.match
local _G = _G
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, "Raid roster count API is not initialized")
local tostring, tonumber = tostring, tonumber
local getRaidRosterInfo = GetRaidRosterInfo
local UnitRace, UnitSex = UnitRace, UnitSex

do
	addon.Services.EnsureNamespace("Raid")
	local Raid = Services.Raid
	local module = Raid

	-- Timer ownership: roster refresh debounce plus retry for pending units.
	-- Raid/State.lua and Raid/Session.lua share the same `addon.Services.Raid`
	-- table and reuse the mixin embedded here.
	Timer.BindMixin(module, "Raid")

	-- ----- Internal state ----- --
	local numRaid = 0
	local rosterVersion = 0
	local liveUnitsByName = {}
	local liveNamesByUnit = {}
	local liveOnlineByName = {}
	local pendingUnits = {}

	local RETRY_DELAY_SECONDS = 1
	local RETRY_MAX_ATTEMPTS = 5
	local ROSTER_REFRESH_DELAY_SECONDS = 2
	local isUnknownName = assert(module._IsUnknownNameInternal, "Raid unknown-name helper is not initialized")

	-- ----- Private helpers ----- --
	local isDebugEnabled = addon.Options.IsDebugEnabled

	local function resetLiveUnitCaches()
		twipe(liveUnitsByName)
		twipe(liveNamesByUnit)
		twipe(liveOnlineByName)
	end

	local function cancelPendingUnitRetryTimer()
		if module.pendingUnitRetryHandle then
			module:CancelTimer(module.pendingUnitRetryHandle)
			module.pendingUnitRetryHandle = nil
		end
	end

	local function cancelScheduledRosterRefresh()
		if module.updateRosterHandle then
			module:CancelTimer(module.updateRosterHandle)
			module.updateRosterHandle = nil
		end
	end

	local function scheduleRosterRefresh()
		cancelScheduledRosterRefresh()
		module.updateRosterHandle = module:ScheduleTimer(function()
			module.updateRosterHandle = nil
			module:RefreshAndPublish()
		end, ROSTER_REFRESH_DELAY_SECONDS)
	end

	local function resetPendingUnitRetry()
		cancelPendingUnitRetryTimer()
		twipe(pendingUnits)
	end

	local function markPendingUnit(unitID)
		local tries = tonumber(pendingUnits[unitID]) or 0
		if tries < RETRY_MAX_ATTEMPTS then
			pendingUnits[unitID] = tries + 1
		end
	end

	local function trimPendingUnits(maxRaidSize)
		for unitID in pairs(pendingUnits) do
			local idx = tonumber(strmatch(unitID, "^raid(%d+)$")) or 0
			if idx <= 0 or idx > maxRaidSize then
				pendingUnits[unitID] = nil
			end
		end
	end

	local function hasRetryablePendingUnits()
		for _, tries in pairs(pendingUnits) do
			if (tonumber(tries) or 0) < RETRY_MAX_ATTEMPTS then
				return true
			end
		end
		return false
	end

	local function schedulePendingUnitRetry()
		if not hasRetryablePendingUnits() then
			return
		end

		cancelPendingUnitRetryTimer()
		module.pendingUnitRetryHandle = module:ScheduleTimer(function()
			module.pendingUnitRetryHandle = nil
			if not addon.IsInRaid() then
				return
			end
			addon:RAID_ROSTER_UPDATE(true)
		end, RETRY_DELAY_SECONDS)
	end

	local function finalizeRosterDelta(delta)
		if #delta.joined == 0 then
			delta.joined = nil
		end
		if #delta.updated == 0 then
			delta.updated = nil
		end
		if #delta.left == 0 then
			delta.left = nil
		end
		if #delta.unresolved == 0 then
			delta.unresolved = nil
		end
		if delta.joined or delta.updated or delta.left or delta.unresolved then
			return delta
		end
		return nil
	end

	local function buildRosterDelta()
		return {
			joined = {},
			updated = {},
			left = {},
			unresolved = {},
		}
	end

	local function ensureRealmPlayerMeta(realm)
		local players = SavedVariables.GetPlayers()
		players[realm] = players[realm] or {}
		return players[realm]
	end

	local function getSyntheticRosterState(raidNum)
		local debugState = coreState and coreState.debug or nil
		local syntheticByRaid = debugState and debugState.syntheticByRaid or nil
		if type(syntheticByRaid) ~= "table" then
			return nil
		end
		return syntheticByRaid[tonumber(raidNum) or -1]
	end

	local function isSyntheticRosterPlayer(name, raidNum)
		local syntheticState = getSyntheticRosterState(raidNum)
		if type(syntheticState) ~= "table" or not name then
			return false
		end
		return syntheticState[name] == true
	end

	local function upsertPlayerMeta(realmPlayers, name, unitID, level, race, raceL, class, classL)
		if not (realmPlayers and name and unitID) then
			return
		end

		local known = realmPlayers[name]
		if not known then
			known = {}
			realmPlayers[name] = known
		end

		known.name = name
		known.level = level or 0
		known.race = race
		known.raceL = raceL
		known.class = class or "UNKNOWN"
		known.classL = classL
		known.sex = UnitSex(unitID) or 0
	end

	-- ----- Public methods ----- --
	local function copyRosterMeta(source)
		if type(source) ~= "table" then
			return nil
		end
		local copy = {}
		for name, value in pairs(source) do
			if type(value) ~= "table" then
				return nil
			end
			copy[name] = {}
			for key, item in pairs(value) do
				copy[name][key] = item
			end
		end
		return copy
	end

	local function publishRosterDeltaInternal(delta, raidNum)
		local payload

		raidNum = raidNum or Database.GetCurrentRaid()
		if not raidNum then
			return nil, nil
		end

		if type(delta) ~= "table" then
			delta = {}
		end

		payload = {
			joined = type(delta.joined) == "table" and delta.joined or {},
			updated = type(delta.updated) == "table" and delta.updated or {},
			left = type(delta.left) == "table" and delta.left or {},
			unresolved = type(delta.unresolved) == "table" and delta.unresolved or {},
			raidNum = tonumber(delta.raidNum) or tonumber(raidNum),
			timestamp = tonumber(delta.timestamp) or Time.GetCurrentTime(),
		}

		rosterVersion = rosterVersion + 1
		payload = finalizeRosterDelta(payload) or payload
		TriggerEvent(RaidRosterDeltaEvent, payload, rosterVersion, raidNum)
		return rosterVersion, payload
	end

	module._CancelRosterRefreshInternal = cancelScheduledRosterRefresh
	module._ScheduleRosterRefreshInternal = scheduleRosterRefresh
	module._PublishRosterDelta = publishRosterDeltaInternal

	function module:CaptureRosterSessionState(realm)
		local players = SavedVariables.GetPlayers()
		if type(players) ~= "table" then
			return nil
		end
		local realmPlayers = players[realm]
		if realmPlayers == nil then
			realmPlayers = {}
			players[realm] = realmPlayers
		elseif type(realmPlayers) ~= "table" then
			return nil
		end
		local playerMeta = copyRosterMeta(realmPlayers)
		if not playerMeta then
			return nil
		end
		return {
			numRaid = numRaid,
			rosterVersion = rosterVersion,
			realmPlayers = realmPlayers,
			playerMeta = playerMeta,
		}
	end

	function module:RestoreRosterSessionState(snapshot)
		if type(snapshot) ~= "table" or type(snapshot.realmPlayers) ~= "table" then
			return false
		end
		numRaid = tonumber(snapshot.numRaid) or 0
		rosterVersion = tonumber(snapshot.rosterVersion) or 0
		for name in pairs(snapshot.realmPlayers) do
			snapshot.realmPlayers[name] = nil
		end
		for name, value in pairs(copyRosterMeta(snapshot.playerMeta)) do
			snapshot.realmPlayers[name] = value
		end
		resetPendingUnitRetry()
		resetLiveUnitCaches()
		return true
	end

	function module:CommitRosterSession(realm, pendingMeta, raidSize)
		local realmPlayers = ensureRealmPlayerMeta(realm)
		for i = 1, #(pendingMeta or {}) do
			upsertPlayerMeta(realmPlayers, unpack(pendingMeta[i]))
		end
		numRaid = tonumber(raidSize) or 0
		rosterVersion = rosterVersion + 1
		resetPendingUnitRetry()
		resetLiveUnitCaches()
		return rosterVersion
	end

	function module:IsSyntheticPlayerActive(name, raidNum)
		local currentRaidId = raidNum or Database.GetCurrentRaid()
		local raid = Database.EnsureRaidByIndex(currentRaidId)
		local resolvedName

		if not raid or not name then
			return false
		end

		resolvedName = Strings.NormalizeName(name, true)
		if not resolvedName or resolvedName == "" then
			return false
		end

		if not isSyntheticRosterPlayer(resolvedName, currentRaidId) then
			return false
		end

		return module:GetPlayerID(resolvedName, currentRaidId) > 0
	end

	local function checkCurrentRaidInstance()
		if not addon.IsInRaid() then
			return
		end

		local instanceName, instanceType, instanceDiff = GetInstanceInfo()
		if instanceType == "raid" and addon.L.RaidZones[instanceName] ~= nil then
			module:Check(instanceName, instanceDiff)
		end
	end

	local function endRosterSession(resetRaidSize, debugMessage)
		local raidNum = Database.GetCurrentRaid()
		local raid = raidNum and Database.EnsureRaidByIndex(raidNum) or nil
		local timestamp = Time.GetCurrentTime()
		local delta = buildRosterDelta()
		delta.raidNum = raidNum
		delta.timestamp = timestamp
		delta.sessionEnded = true
		if raid and type(raid.players) == "table" then
			for _, player in ipairs(raid.players) do
				if player and not player.leave then
					tinsert(delta.left, {
						name = player.name,
						playerNid = tonumber(player.playerNid) or nil,
						rank = player.rank or 0,
						subgroup = player.subgroup or 1,
						class = player.class or "UNKNOWN",
						online = false,
					})
				end
			end
		end
		if resetRaidSize then
			numRaid = 0
		end
		if debugMessage and isDebugEnabled() then
			addon:debug(debugMessage)
		end
		resetPendingUnitRetry()
		resetLiveUnitCaches()
		module:End(true)
		rosterVersion = rosterVersion + 1
		return true, finalizeRosterDelta(delta) or delta, raidNum
	end

	local function applyUnknownRosterUnit(ctx, unitID)
		markPendingUnit(unitID)
		local prevName = ctx.prevNamesByUnit[unitID]
		if prevName and not ctx.nextUnitsByName[prevName] then
			ctx.seen[prevName] = true
			ctx.nextUnitsByName[prevName] = unitID
			ctx.nextNamesByUnit[unitID] = prevName
			ctx.nextOnlineByName[prevName] = ctx.prevOnlineByName[prevName]
		end
		tinsert(ctx.delta.unresolved, { unitID = unitID, name = prevName })
		return true
	end

	local function buildJoinedRosterPlayer(ctx, name, rank, subgroup, class, online)
		local prevPlayer = ctx.playersByName[name]
		local newRank = rank or (prevPlayer and prevPlayer.rank) or 0
		local newSubgroup = subgroup or (prevPlayer and prevPlayer.subgroup) or 1
		local newClass = class or (prevPlayer and prevPlayer.class) or "UNKNOWN"
		local isOnline = online ~= false

		local deltaEntry = {
			name = name,
			unitID = ctx.unitID,
			rank = newRank,
			subgroup = newSubgroup,
			class = newClass,
			online = isOnline,
		}
		tinsert(ctx.delta.joined, deltaEntry)

		return {
			playerNid = prevPlayer and prevPlayer.playerNid or nil,
			name = name,
			rank = newRank,
			subgroup = newSubgroup,
			class = newClass,
			join = ctx.now,
			leave = nil,
			countMS = (prevPlayer and prevPlayer.countMS) or 0,
		},
			deltaEntry
	end

	local function refreshActiveRosterPlayer(ctx, name, rank, subgroup, class, online)
		local currentPlayer = ctx.playersByName[name]
		local player = {}
		for key, value in pairs(currentPlayer) do
			player[key] = value
		end
		local oldUnitID = ctx.prevUnitsByName[name]
		local oldRank = player.rank or 0
		local oldSubgroup = player.subgroup or 1
		local oldClass = player.class or "UNKNOWN"
		local oldOnline = ctx.prevOnlineByName[name]
		local newRank = rank or oldRank
		local newSubgroup = subgroup or oldSubgroup
		local newClass = class or oldClass
		local newOnline = online ~= false
		local onlineChanged = oldOnline ~= nil and oldOnline ~= newOnline
		local fieldChanged = (oldRank ~= newRank) or (oldSubgroup ~= newSubgroup) or (oldClass ~= newClass)
		local unitChanged = oldUnitID and (oldUnitID ~= ctx.unitID)
		local changed = fieldChanged or unitChanged or onlineChanged
		local deltaEntry

		if changed then
			deltaEntry = {
				name = name,
				oldUnitID = oldUnitID,
				unitID = ctx.unitID,
				oldRank = oldRank,
				rank = newRank,
				oldSubgroup = oldSubgroup,
				subgroup = newSubgroup,
				oldClass = oldClass,
				class = newClass,
				oldOnline = oldOnline,
				online = newOnline,
			}
			tinsert(ctx.delta.updated, deltaEntry)
		end

		player.rank = newRank
		player.subgroup = newSubgroup
		player.class = newClass
		return player, changed, deltaEntry
	end

	local function applyKnownRosterUnit(ctx, unitID, name, rank, subgroup, level, classL, class, online)
		pendingUnits[unitID] = nil
		ctx.unitID = unitID
		ctx.nextUnitsByName[name] = unitID
		ctx.nextNamesByUnit[unitID] = name
		ctx.nextOnlineByName[name] = online ~= false

		local raceL, race = UnitRace(unitID)
		local prevPlayer = ctx.playersByName[name]
		local active = prevPlayer and prevPlayer.leave == nil
		local player
		local deltaEntry
		local changed = false

		if active then
			player, changed, deltaEntry = refreshActiveRosterPlayer(ctx, name, rank, subgroup, class, online)
		else
			player, deltaEntry = buildJoinedRosterPlayer(ctx, name, rank, subgroup, class, online)
			changed = true
		end

		-- Keep raid.players consistent even if rows were manually edited.
		module:AddPlayer(player)
		if deltaEntry then
			deltaEntry.playerNid = tonumber(player and player.playerNid) or nil
		end

		ctx.seen[name] = true
		upsertPlayerMeta(ctx.realmPlayers, name, unitID, level, race, raceL, class, classL)
		return changed
	end

	local function markRosterLeavers(ctx)
		local changed = false
		for pname, p in pairs(ctx.playersByName) do
			if p.leave == nil and not ctx.seen[pname] then
				if isSyntheticRosterPlayer(pname, ctx.currentRaidId) then
					ctx.seen[pname] = true
				else
					local committed = Database.GetRaidStore():CommitAuthoritativeEvent(ctx.raidUid, "PLAYER_DEPARTED", {
						playerNid = tonumber(p.playerNid),
						leave = ctx.now,
					})
					changed = committed ~= nil or changed
					tinsert(ctx.delta.left, {
						name = pname,
						unitID = ctx.prevUnitsByName[pname],
						playerNid = tonumber(p.playerNid) or nil,
						rank = p.rank or 0,
						subgroup = p.subgroup or 1,
						class = p.class or "UNKNOWN",
						oldOnline = ctx.prevOnlineByName[pname],
						online = false,
					})
				end
			end
		end
		return changed
	end

	function module:GetRosterVersion()
		return rosterVersion
	end

	-- Updates the current raid roster, adding new players and marking those who left.
	-- Returns rosterChanged, delta where delta contains joined/updated/left/unresolved lists.
	function module:UpdateRaidRoster()
		checkCurrentRaidInstance()

		if not Database.GetCurrentRaid() then
			resetPendingUnitRetry()
			resetLiveUnitCaches()
			return false
		end
		-- Cancel any pending roster update timer.
		cancelScheduledRosterRefresh()

		local rosterChanged = false
		local delta = buildRosterDelta()

		if not addon.IsInRaid() then
			return endRosterSession(true, Diag.D.LogRaidLeftGroupEndSession)
		end

		local currentRaidId = Database.GetCurrentRaid()
		local raid = Database.EnsureRaidByIndex(currentRaidId)
		if not raid then
			return false
		end

		local realm = Database.GetRealmName()
		local realmPlayers = ensureRealmPlayerMeta(realm)
		local runtime = Database.GetRaidStore():EnsureRaidRuntime(raid)
		local playersByName = runtime and runtime.playersByName or {}

		local prevNumRaid = numRaid
		local n = tonumber(GetNumRaidMembers()) or 0

		-- Keep local raid-size cache in sync.
		numRaid = n
		if n ~= prevNumRaid then
			rosterChanged = true
		end

		if n == 0 then
			return endRosterSession(false)
		end

		local prevUnitsByName = liveUnitsByName
		local prevNamesByUnit = liveNamesByUnit
		local prevOnlineByName = liveOnlineByName
		local ctx = {
			currentRaidId = currentRaidId,
			realmPlayers = realmPlayers,
			playersByName = playersByName,
			prevUnitsByName = prevUnitsByName,
			prevNamesByUnit = prevNamesByUnit,
			prevOnlineByName = prevOnlineByName,
			nextUnitsByName = {},
			nextNamesByUnit = {},
			nextOnlineByName = {},
			seen = {},
			delta = delta,
			now = Time.GetCurrentTime(),
			raidUid = Database.GetRaidStore():GetRaidUid(raid),
		}
		delta.timestamp = ctx.now
		delta.raidNum = currentRaidId
		local hasUnknownUnits = false

		-- Localize heavy-used locals for the loop to reduce lookups.
		local applyUnknown = applyUnknownRosterUnit
		local applyKnown = applyKnownRosterUnit
		local getInfo = getRaidRosterInfo
		local tstr = tostring
		local isUnknownFn = isUnknownName

		for i = 1, n do
			local unitID = "raid" .. tstr(i)
			local name, rank, subgroup, level, classL, class, _, online = getInfo(i)
			if isUnknownFn(name) then
				hasUnknownUnits = applyUnknown(ctx, unitID) or hasUnknownUnits
			else
				rosterChanged = applyKnown(ctx, unitID, name, rank, subgroup, level, classL, class, online)
					or rosterChanged
			end
		end

		trimPendingUnits(n)
		liveUnitsByName = ctx.nextUnitsByName
		liveNamesByUnit = ctx.nextNamesByUnit
		liveOnlineByName = ctx.nextOnlineByName

		rosterChanged = markRosterLeavers(ctx) or rosterChanged

		if hasUnknownUnits then
			schedulePendingUnitRetry()
		else
			resetPendingUnitRetry()
		end

		delta = finalizeRosterDelta(delta)

		if rosterChanged then
			rosterVersion = rosterVersion + 1
			if isDebugEnabled() then
				addon:debug(Diag.D.LogRaidRosterUpdate:format(rosterVersion, n))
			end
		end
		return rosterChanged, delta
	end

	-- Refreshes the canonical roster and publishes its mutation exactly once.
	-- Returns the published delta, or nil when the refresh did not mutate roster state.
	function module:RefreshAndPublish()
		local changed, delta, raidNum = module:UpdateRaidRoster()
		if not changed or type(delta) ~= "table" then
			return nil
		end

		TriggerEvent(RaidRosterDeltaEvent, delta, rosterVersion, raidNum or Database.GetCurrentRaid())
		return delta
	end

	function module:CheckPlayer(name, raidNum)
		local found = false
		local players = module:GetPlayers(raidNum)
		if players ~= nil then
			name = Strings.NormalizeName(name)
			for _, p in ipairs(players) do
				if name == p.name then
					found = true
					break
				elseif strlen(name) >= 5 and type(p.name) == "string" and strsub(p.name, 1, strlen(name)) == name then
					name = p.name
					found = true
					break
				end
			end
		end
		return found, name
	end

	function module:GetPlayerID(name, raidNum)
		local playerNid = 0
		raidNum = raidNum or Database.GetCurrentRaid()
		local raid = raidNum and Database.EnsureRaidByIndex(raidNum)
		if raid then
			name = Strings.NormalizeName(name or Database.GetPlayerName(), true)
			local players = raid.players or {}
			for i = #players, 1, -1 do
				local p = players[i]
				if p and p.name == name then
					playerNid = tonumber(p.playerNid) or 0
					break
				end
			end
		end
		return playerNid
	end

	function module:GetPlayerName(id, raidNum)
		local name
		raidNum = raidNum or (coreState and coreState.selectedRaid) or Database.GetCurrentRaid()
		local raid = raidNum and Database.EnsureRaidByIndex(raidNum)
		if raid then
			local qid = tonumber(id) or id
			local players = raid.players or {}
			for i = 1, #players do
				local p = players[i]
				local pid = p and (tonumber(p.playerNid) or p.playerNid)
				if pid == qid then
					name = p.name
					break
				end
			end
		end
		return name
	end

	function module:GetPlayerClass(name)
		local class = "UNKNOWN"
		local realm = Database.GetRealmName()
		local resolvedName = name or Database.GetPlayerName()
		local players = SavedVariables.GetPlayers()
		if players[realm] and players[realm][resolvedName] then
			class = players[realm][resolvedName].class or "UNKNOWN"
		end
		return class
	end

	-- Returns players from the raid log. Can be filtered by boss kill.
	function module:GetPlayers(raidNum, bossNid, out)
		raidNum = raidNum or Database.GetCurrentRaid()
		local raid = Database.EnsureRaidByIndex(raidNum)
		if not raid then
			return {}
		end

		Database.EnsureRaidSchema(raid)

		local raidPlayers = raid.players or {}

		bossNid = tonumber(bossNid) or 0
		if bossNid > 0 then
			local bossKill = module:GetBossByNid(bossNid, raidNum)
			if bossKill and bossKill.players then
				local players = out or {}
				if out then
					twipe(players)
				end
				local bossPlayers = {}
				for i = 1, #bossKill.players do
					local playerNid = tonumber(bossKill.players[i])
					if playerNid and playerNid > 0 then
						bossPlayers[playerNid] = true
					end
				end
				for _, p in ipairs(raidPlayers) do
					local playerNid = tonumber(p and p.playerNid)
					if playerNid and bossPlayers[playerNid] then
						tinsert(players, p)
					end
				end
				-- Caller releases when using a pooled table.
				return players
			end
		end

		return raidPlayers
	end

	-- Gets a player's unit ID (e.g., "raid1").
	function module:GetUnitID(name)
		if not addon.IsInGroup() or not name then
			return "none"
		end

		name = Strings.NormalizeName(name)
		local cachedUnit = liveUnitsByName[name]
		if cachedUnit then
			if UnitExists(cachedUnit) and UnitName(cachedUnit) == name then
				return cachedUnit
			end
			liveUnitsByName[name] = nil
			if liveNamesByUnit[cachedUnit] == name then
				liveNamesByUnit[cachedUnit] = nil
			end
		end

		for unit in addon.Group.IterateUnits(true) do
			local unitName = UnitName(unit)
			if unitName then
				unitName = Strings.NormalizeName(unitName)
				liveUnitsByName[unitName] = unit
				liveNamesByUnit[unit] = unitName
				if unitName == name then
					return unit
				end
			end
		end
		return "none"
	end
end
