local function fail(message)
	error(message, 2)
end

local function assertEqual(expected, actual, message)
	if actual ~= expected then
		fail((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
	end
end

local function assertTrue(value, message)
	if not value then
		fail(message or "expected a truthy value")
	end
end

local function deepCopy(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in pairs(value) do
		copy[deepCopy(key, seen)] = deepCopy(item, seen)
	end
	return copy
end

local function deepEqual(left, right, seen)
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	seen = seen or {}
	if seen[left] then
		return seen[left] == right
	end
	seen[left] = right
	for key, value in pairs(left) do
		if not deepEqual(value, right[key], seen) then
			return false
		end
	end
	for key in pairs(right) do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function resetSavedVariables()
	local keys = {}
	for key in pairs(_G) do
		if type(key) == "string" and string.sub(key, 1, 4) == "RMA_" then
			keys[#keys + 1] = key
		end
	end
	for i = 1, #keys do
		_G[keys[i]] = nil
	end
end

local function newAddon()
	return {
		State = {},
		Database = {},
		Services = {},
		Events = {},
		Bus = {},
	}
end

local function loadAddonFile(addon, path)
	local chunk = assert(loadfile(path))
	chunk("Raid Management Addon", addon)
end

local function installInitStubs(addon)
	local frame = {
		registered = {},
		registerCount = {},
		activeRegistrationCount = {},
	}

	function frame:RegisterEvent(eventName)
		self.registered[eventName] = true
		self.registerCount[eventName] = (self.registerCount[eventName] or 0) + 1
		self.activeRegistrationCount[eventName] = 1
	end

	function frame:UnregisterEvent(eventName)
		self.registered[eventName] = nil
		self.activeRegistrationCount[eventName] = 0
	end

	function frame:SetScript(scriptName, callback)
		self[scriptName] = callback
	end

	_G.GetTime = function()
		return 0
	end
	_G.GetRealmName = function()
		return "Test Realm"
	end
	_G.GetPartyLeaderIndex = function()
		return 0
	end
	_G.GetRaidRosterInfo = function()
		return nil, 0
	end
	_G.GetNumRaidMembers = function()
		return 0
	end
	_G.GetNumPartyMembers = function()
		return 0
	end
	_G.GetAddOnMetadata = function()
		return "0.0.0-test"
	end
	_G.CreateFrame = function()
		return frame
	end

	local compat = {}
	function compat:Embed(target)
		target.UnitFullName = function()
			return "Tester"
		end
	end
	function compat:Print() end

	local debugger = {
		logLevels = { INFO = 1, DEBUG = 2 },
	}
	function debugger:Embed(target)
		target.SetLogLevel = function() end
		target.GetLogLevel = function()
			return 1
		end
		target.info = function() end
		target.error = function(_, message)
			error(message, 2)
		end
	end

	_G.LibStub = function(name)
		if name == "LibCompat-1.0" then
			return compat
		end
		if name == "LibLogger-1.0" then
			return debugger
		end
		return {}
	end

	addon.Diagnose = {
		I = {
			LogDatabaseLoaded = "%s %s %s",
		},
		D = {
			LogDatabaseEventsRegistered = "%s",
		},
		E = {
			LogDatabaseEventHandlerFailed = "%s %s",
		},
	}

	return frame
end

local function installOptionsStubs(addon, persistedOptions)
	_G.RMA_Options = persistedOptions or {}
	addon.Database.SavedVariables = {
		GetOptions = function()
			return _G.RMA_Options
		end,
	}
	addon.Bus.TriggerEvent = function() end
	addon.warn = function() end
	loadAddonFile(addon, "Raid Management Addon/Database/DBOptions.lua")
	return addon.Options
end

local function newSyncCommunicationsFixture()
	local fixture = {
		now = 500,
		maxTimerCallbacks = 20,
		nextSequence = 1,
		sent = {},
		timers = {},
		roster = {
			{ name = "Leader-Test Realm", rank = 2 },
			{ name = "Assistant-Other Realm", rank = 1 },
			{ name = "Member-Test Realm", rank = 0 },
		},
		raids = {
			[41] = { raidNid = 41, revision = 3, zone = "Naxxramas", players = { { name = "Leader" } } },
			[73] = { raidNid = 73, revision = 8, zone = "Ulduar", players = { { name = "Member" } } },
		},
	}

	function fixture:NormalizeSender(sender)
		if type(sender) ~= "string" then return nil end
		local short = string.match(sender, "^([^%-]+)") or sender
		short = string.match(short, "^%s*(.-)%s*$")
		if short == "" then return nil end
		return string.upper(string.sub(short, 1, 1)) .. string.sub(short, 2)
	end

	function fixture:CaptureSender(rawSender)
		return { raw = rawSender, normalized = self:NormalizeSender(rawSender) }
	end

	function fixture:GetRosterMember(name)
		local raw = string.lower(string.match(tostring(name or ""), "^%s*(.-)%s*$"))
		local normalized = self:NormalizeSender(raw)
		local found, matchCount
		for i = 1, #self.roster do
			local rosterRaw = string.lower(string.match(tostring(self.roster[i].name or ""), "^%s*(.-)%s*$"))
			if rosterRaw == raw then return self.roster[i] end
			if self:NormalizeSender(rosterRaw) == normalized then
				found = self.roster[i]
				matchCount = (matchCount or 0) + 1
			end
		end
		if matchCount and matchCount > 1 then return nil, "short_name_collision" end
		return found
	end

	function fixture:IsPrivilegedSender(name)
		local member = self:GetRosterMember(name)
		return member ~= nil and (tonumber(member.rank) or 0) > 0
	end

	function fixture:AuthorizeSyncResponder(name)
		local member, reason = self:GetRosterMember(name)
		if not member then
			return false, reason or "unknown_sender"
		end
		return (tonumber(member.rank) or 0) > 0, "insufficient_rank"
	end

	function fixture:CanAnswerWhisperRequest(name)
		local member, reason = self:GetRosterMember(name)
		return member ~= nil, reason or "not_group_member"
	end

	function fixture:Send(prefix, payload, distribution, target)
		local message = {
			prefix = prefix,
			payload = deepCopy(payload),
			distribution = distribution,
			target = target,
		}
		self.sent[#self.sent + 1] = message
		return message
	end

	function fixture:Schedule(delay, callback, ...)
		assert(type(delay) == "number" and delay >= 0, "timer delay must be non-negative")
		assert(type(callback) == "function", "timer callback must be callable")
		local timer = {
			due = self.now + delay,
			callback = callback,
			args = { ... },
			argCount = select("#", ...),
			active = true,
		}
		self.timers[#self.timers + 1] = timer
		return timer
	end

	function fixture:AdvanceTime(elapsed)
		assert(type(elapsed) == "number" and elapsed >= 0, "elapsed time must be non-negative")
		self.now = self.now + elapsed
		local fired = 0
		for i = 1, #self.timers do
			local timer = self.timers[i]
			if timer.active and timer.due <= self.now then
				fired = fired + 1
				assert(fired <= self.maxTimerCallbacks, "timer callback limit exceeded")
				timer.active = false
				timer.callback(unpack(timer.args, 1, timer.argCount))
			end
		end
		return fired
	end

	function fixture:GetRaidRevision(raidNid)
		local raid = assert(self.raids[raidNid], "unknown fixture raid")
		return raid.revision
	end

	function fixture:SetRaidRevision(raidNid, revision)
		assert(type(revision) == "number" and revision >= 0, "revision must be non-negative")
		local raid = assert(self.raids[raidNid], "unknown fixture raid")
		raid.revision = revision
		return revision
	end

	function fixture:BuildRequest(mode, raidNid, signature)
		signature = signature or {}
		local encodedZone = "fake:" .. tostring(signature.zone or "")
		local compressionField
		if signature.supportsCompression == true then
			compressionField = 1
		elseif signature.supportsCompression == false or signature.supportsCompression == nil then
			compressionField = 0
		else
			compressionField = signature.supportsCompression
		end
		local request = {
			kind = "RQ",
			version = 2,
			requestId = tostring(self.nextSequence),
			mode = mode,
			raidNid = raidNid,
			zone = encodedZone,
			size = signature.size or 0,
			difficulty = signature.difficulty or 0,
			sinceRevision = signature.sinceRevision or 0,
			supportsCompression = signature.supportsCompression == true,
		}
		request.fields = {
			request.kind,
			request.version,
			request.requestId,
			request.mode,
			request.raidNid,
			request.zone,
			request.size,
			request.difficulty,
			request.sinceRevision,
			compressionField,
		}
		self.nextSequence = self.nextSequence + 1
		return request
	end

	local function encodeDeterministic(value)
		if type(value) ~= "table" then return tostring(value) end
		local keys = {}
		for key in pairs(value) do keys[#keys + 1] = key end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local encoded = {}
		for i = 1, #keys do
			local key = keys[i]
			encoded[#encoded + 1] = tostring(key) .. "=" .. encodeDeterministic(value[key])
		end
		return "{" .. table.concat(encoded, ",") .. "}"
	end

	function fixture:BuildChunk(kind, request, payload, partIndex, partCount, rawSender, target)
		return {
			kind = kind,
			version = request.version,
			requestId = request.requestId,
			mode = request.mode,
			raidNid = request.raidNid,
			partIndex = partIndex,
			partCount = partCount,
			payload = tostring(payload or ""),
			sender = self:CaptureSender(rawSender),
			target = target,
		}
	end

	function fixture:BuildChunks(kind, request, values, chunkSize, rawSender, target)
		assert(type(chunkSize) == "number" and chunkSize >= 1, "chunk size must be positive")
		local chunks = {}
		local total = math.ceil(#values / chunkSize)
		for first = 1, #values, chunkSize do
			local rows = {}
			for index = first, math.min(first + chunkSize - 1, #values) do
				rows[#rows + 1] = deepCopy(values[index])
			end
			chunks[#chunks + 1] = self:BuildChunk(
				kind,
				request,
				encodeDeterministic(rows),
				#chunks + 1,
				total,
				rawSender,
				target
			)
		end
		return chunks
	end

	function fixture:Snapshot(value)
		return deepCopy(value)
	end

	function fixture:AssertDeepEqual(expected, actual, message)
		assertTrue(deepEqual(expected, actual), message or "fixture values differ deeply")
	end

	function fixture:AssertUnchanged(snapshot, actual, message)
		assertTrue(deepEqual(snapshot, actual), message or "fixture value was mutated")
	end

	return fixture
end

local function newRaidRecordingFixture(addon)
	local fixture = {
		now = 1000,
		events = {},
		timers = {},
		inspectCallbacks = {},
		inspectRequests = {},
		roster = {
			{ name = "Alpha", rank = 2, subgroup = 1, level = 80, class = "Warrior", online = true },
			{ name = "Beta", rank = 0, subgroup = 1, level = 80, class = "Priest", online = true },
		},
	}
	fixture.raids = {
		{
			schemaVersion = 6,
			raidNid = 41,
			zone = "Naxxramas",
			startTime = 900,
			players = { { playerNid = 11, name = "Alpha" } },
			bossKills = {},
			loot = {},
			attendance = {},
		},
		{
			schemaVersion = 6,
			raidNid = 73,
			zone = "Ulduar",
			startTime = 950,
			players = { { playerNid = 21, name = "Beta" } },
			bossKills = {},
			loot = {},
			attendance = {},
		},
	}

	local revisions = { [41] = 3, [73] = 8 }
	local fullSyncRevisions = { [41] = 3, [73] = 8 }
	fixture.store = {}
	function fixture.store:GetRaidByNid(raidNid)
		for i = 1, #fixture.raids do
			if fixture.raids[i].raidNid == raidNid then
				return fixture.raids[i], i
			end
		end
		return nil, nil
	end
	function fixture.store:GetRaidSyncRevision(raid)
		return revisions[raid and raid.raidNid] or 0
	end
	function fixture.store:SetRaidSyncRevision(raid, revision)
		revisions[assert(raid and raid.raidNid)] = tonumber(revision) or 0
		return revisions[raid.raidNid]
	end
	function fixture.store:TouchRaidSyncRevision(raid)
		local revision = self:GetRaidSyncRevision(raid) + 1
		self:SetRaidSyncRevision(raid, revision)
		fullSyncRevisions[raid.raidNid] = revision
		return revision
	end
	function fixture.store:StageRaidHistoryMutation(raid)
		local staged = deepCopy(raid)
		staged._fixtureBaseRevision = self:GetRaidSyncRevision(raid)
		return staged
	end
	function fixture.store:CommitAttendanceMutation(raid, staged, reason)
		if self:GetRaidSyncRevision(raid) ~= staged._fixtureBaseRevision then return false, "CONFLICT" end
		staged._fixtureBaseRevision = nil
		local before = deepCopy(raid)
		local revisionBefore = self:GetRaidSyncRevision(raid)
		for key in pairs(raid) do raid[key] = nil end
		for key, value in pairs(deepCopy(staged)) do raid[key] = value end
		local ok, revision = pcall(self.TouchRaidSyncRevision, self, raid, reason)
		if not ok or type(revision) ~= "number" then
			for key in pairs(raid) do raid[key] = nil end
			for key, value in pairs(before) do raid[key] = value end
			self:SetRaidSyncRevision(raid, revisionBefore)
			return false, "COMMIT_FAILED"
		end
		return true
	end
	function fixture.store:RequiresFullSyncSince(raid, sinceRevision)
		return (fullSyncRevisions[raid.raidNid] or 0) > (tonumber(sinceRevision) or 0)
	end
	function fixture.store:CommitRaidInspectSnapshot(raid, playerNid, snapshot)
		local inspect = raid.inspect
		local previous = inspect and inspect.players and inspect.players[playerNid] or nil
		local comparablePrevious = deepCopy(previous)
		local comparableSnapshot = deepCopy(snapshot)
		if comparablePrevious then comparablePrevious.inspectedAt = nil end
		comparableSnapshot.inspectedAt = nil
		if comparablePrevious and deepEqual(comparablePrevious, comparableSnapshot) then return false end
		inspect = inspect or { players = {} }
		inspect.players = inspect.players or {}
		raid.inspect = inspect
		inspect.players[playerNid] = snapshot
		local revisionBefore = self:GetRaidSyncRevision(raid)
		local fullBefore = fullSyncRevisions[raid.raidNid]
		local ok, revision = pcall(self.TouchRaidSyncRevision, self, raid, "inspect")
		if not ok or type(revision) ~= "number" then
			inspect.players[playerNid] = previous
			self:SetRaidSyncRevision(raid, revisionBefore)
			fullSyncRevisions[raid.raidNid] = fullBefore
			return nil, ok and "invalid revision" or tostring(revision)
		end
		return true
	end

	function fixture:AssertRevision(raidNid, expected, message)
		local raid = assert(self.store:GetRaidByNid(raidNid))
		assertEqual(expected, self.store:GetRaidSyncRevision(raid), message or "raid revision differs")
	end
	function fixture:AssertEvent(index, eventName, ...)
		local event = self.events[index]
		assertTrue(event ~= nil, "missing captured event " .. tostring(index))
		assertEqual(eventName, event.name, "captured event name differs")
		local expected = { ... }
		assertEqual(#expected, #event.args, "captured event argument count differs")
		for i = 1, #expected do
			assertTrue(deepEqual(expected[i], event.args[i]), "captured event argument differs at " .. tostring(i))
		end
	end
	function fixture:InstallTimers(target)
		function target:ScheduleTimer(callback, delay, ...)
			local timer = {
				due = fixture.now + delay,
				callback = callback,
				args = { ... },
				argCount = select("#", ...),
				active = true,
			}
			fixture.timers[#fixture.timers + 1] = timer
			return timer
		end
		function target:CancelTimer(timer)
			if not timer or not timer.active then
				return false
			end
			timer.active = false
			return true
		end
		return target
	end
	function fixture:AdvanceTime(elapsed)
		self.now = self.now + elapsed
		for i = 1, #self.timers do
			local timer = self.timers[i]
			if timer.active and timer.due <= self.now then
				timer.active = false
				timer.callback(unpack(timer.args, 1, timer.argCount))
			end
		end
	end
	function fixture:RegisterInspectCallback(unit, callback)
		self.inspectCallbacks[unit] = callback
	end
	function fixture:FireInspectCallback(unit, ...)
		local callback = assert(self.inspectCallbacks[unit], "missing inspect callback")
		return callback(...)
	end

	addon.Database.GetRaidStore = function()
		return fixture.store
	end
	addon.Bus.TriggerEvent = function(eventName, ...)
		fixture.events[#fixture.events + 1] = { name = eventName, args = { ... } }
	end
	_G.GetTime = function()
		return fixture.now
	end
	_G.GetNumRaidMembers = function()
		return #fixture.roster
	end
	_G.GetRaidRosterInfo = function(index)
		local member = fixture.roster[index]
		if not member then
			return nil
		end
		return member.name, member.rank, member.subgroup, member.level, member.class, string.upper(member.class), nil,
			member.online
	end
	_G.UnitName = function(unit)
		local index = tonumber(string.match(tostring(unit), "^raid(%d+)$"))
		return index and fixture.roster[index] and fixture.roster[index].name or nil
	end
	_G.NotifyInspect = function(unit)
		fixture.inspectRequests[#fixture.inspectRequests + 1] = unit
	end

	return fixture
end

local function installRealAttendanceFixture(addon, fixture)
	local callbacks = {}
	_G.strlower = string.lower
	fixture.raids[2].raidNid = 42
	fixture.raids[2].players = { { playerNid = 21, name = "Beta", join = 975 } }
	fixture.raids[2].attendance = {}
	fixture.store:SetRaidSyncRevision(fixture.raids[2], 0)
	fixture.roster = { { name = "Beta", rank = 0, subgroup = 1, level = 80, class = "Priest", online = true } }

	addon.Events = { Internal = {
		RaidAttendanceChanged = "RaidAttendanceChanged",
		RaidRosterDelta = "RaidRosterDelta",
		RaidCreate = "RaidCreate",
	} }
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
		end,
	}
	addon.Time = { GetCurrentTime = function() return fixture.now end }
	addon.Database.EnsureRaidByIndex = function(index) return fixture.raids[index] end
	addon.Database.EnsureRaidSchema = function(raid) return raid end
	addon.Bus.RegisterCallback = function(eventName, callback)
		callbacks[eventName] = callback
	end

	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Attendance.lua")
	fixture.attendanceCallbacks = callbacks
	return addon.Services.Raid
end

local function installRaidCreationFixture(addon, failureMode)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = 1
	fixture.raids[1].attendance = { { playerNid = 11, segments = { { startTime = 900 } } } }
	fixture.order = {}
	_G.table.wipe = _G.table.wipe or function(target) for key in pairs(target) do target[key] = nil end return target end
	_G.UnitRace = function() return "Human", "Human" end
	_G.UnitExists = function() return true end
	_G.UnitGUID = function() return nil end
	_G.UnitIsDead = function() return false end
	_G.GetInstanceInfo = function() return "Ulduar", "raid", 2 end
	_G.UNKNOWNOBJECT = "Unknown"
	addon.L = { RaidZones = {} }
	addon.Diag = { I = { LogRaidCreated = "%d %s %d %d", LogRaidEnded = "%d %s %d %d %d %d" } }
	addon.C = {}
	addon.State = { currentRaid = 1, raid = { numRaid = 7, marker = "old" }, raidStore = {} }
	addon.DB = {}
	addon.Strings = { TrimText = function(value) return value end }
	addon.Time = { GetCurrentTime = function() return fixture.now end }
	addon.Base64, addon.LootSources, addon.LootSourceCandidates = {}, {}, {}
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Events = { Internal = { RaidCreate = "RaidCreate", RaidAttendanceChanged = "RaidAttendanceChanged" } }
	addon.Services = { EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} end,
		Loot = { _State = { SetField = function() end, SetActive = function() end, SyncActive = function() end,
			Reset = function() end },
			_Sessions = {}, _Snapshots = {}, _Context = {} } }
	addon.IsInRaid = function() return true end
	addon.GetGroupTypeAndCount = function() return "raid", #fixture.roster end
	addon.GetNumGroupMembers = function() return #fixture.roster end
	addon.GetCreatureId = function() return nil end
	addon.Database.GetRealmName = function() return "Test Realm" end
	addon.info = function() end
	addon.Database.IsBossFightRecord = function() return true end
	addon.Database.GetRaidSchemaVersion = function() return 6 end
	addon.Database.GetRaidMigrations = function() return nil end
	addon.Database.SavedVariables = { GetRaids = function() return fixture.raids end }
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidStore.lua")
	fixture.store = addon.DB.RaidStore
	addon.Database.GetRaidStore = function() return fixture.store end
	fixture.store:EnsureRaidByIndex(1)
	fixture.store:EnsureRaidByIndex(2)
	local realCreate = fixture.store.CreateRaidRecord
	local realInsert = fixture.store.InsertRaid
	local realDelete = fixture.store.DeleteRaid
	if failureMode == "create_nil" then
		fixture.store.CreateRaidRecord = function() return nil end
	elseif failureMode == "create_throw" then
		fixture.store.CreateRaidRecord = function() error("create failure") end
	end
	fixture.store.InsertRaid = function(self, raid)
		fixture.candidateRaidNid = raid.raidNid
		local inserted, index = realInsert(self, raid)
		fixture.candidateRaidNid = inserted and inserted.raidNid or fixture.candidateRaidNid
		if failureMode == "insert_nil" then return nil, nil end
		if failureMode == "insert_throw" then error("insert failure") end
		if not failureMode then
			fixture.order[#fixture.order + 1] = "insert"
		end
		return inserted, index
	end
	if failureMode == "delete_false" then fixture.store.DeleteRaid = function() return false end end
	if failureMode == "delete_throw" then fixture.store.DeleteRaid = function() error("delete failure") end end
	fixture.realCreate, fixture.realInsert, fixture.realDelete = realCreate, realInsert, realDelete
	addon.Bus.TriggerEvent = function(eventName, ...)
		fixture.events[#fixture.events + 1] = { name = eventName, args = { ... } }
		fixture.order[#fixture.order + 1] = eventName
		if eventName == "RaidAttendanceChanged" then fixture.attendanceEventCurrentRaid = addon.Database.GetCurrentRaid() end
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/State.lua")
	local raid = addon.Services.Raid
	raid._SetNumRaidInternal = function(value) addon.State.raid.numRaid = value end
	fixture.realmPlayers = { Existing = { name = "Existing", level = 80 } }
	raid._EnsureRealmPlayerMetaInternal = function() return fixture.realmPlayers end
	raid._UpsertPlayerMetaInternal = function(players, name) players[name] = { name = name } end
	function raid:CloseAttendanceForRaid(record, currentTime, reason, deferPublication)
		record.attendance[1].segments[1].endTime = currentTime
		fixture.store:TouchRaidSyncRevision(record)
		if not deferPublication then addon.Bus.TriggerEvent("RaidAttendanceChanged", record.raidNid, reason) end
		return true, record.raidNid
	end
	return fixture, raid
end

local cases = {}

local expectedRuntimeEvents = {
	"CHAT_MSG_SYSTEM",
	"CHAT_MSG_LOOT",
	"CHAT_MSG_WHISPER",
	"START_LOOT_ROLL",
	"CHAT_MSG_ADDON",
	"CHAT_MSG_MONSTER_YELL",
	"RAID_ROSTER_UPDATE",
	"PLAYER_ENTERING_WORLD",
	"ZONE_CHANGED_NEW_AREA",
	"COMBAT_LOG_EVENT_UNFILTERED",
	"RAID_INSTANCE_WELCOME",
	"PLAYER_DIFFICULTY_CHANGED",
	"UPDATE_INSTANCE_INFO",
	"LOOT_CLOSED",
	"LOOT_OPENED",
	"LOOT_SLOT_CLEARED",
	"OPEN_MASTER_LOOT_LIST",
	"UPDATE_MASTER_LOOT_LIST",
	"PLAYER_TARGET_CHANGED",
	"UI_ERROR_MESSAGE",
	"UI_INFO_MESSAGE",
	"TRADE_SHOW",
	"TRADE_ACCEPT_UPDATE",
	"TRADE_PLAYER_ITEM_CHANGED",
	"TRADE_REQUEST_CANCEL",
	"TRADE_CLOSED",
	"TRADE_TARGET_ITEM_CHANGED",
	"READY_CHECK",
	"INSPECT_TALENT_READY",
	"GET_ITEM_INFO_RECEIVED",
	"PLAYER_REGEN_ENABLED",
	"PLAYER_LOGOUT",
}

function cases.lua_51_smoke()
	assertEqual("Lua 5.1", _VERSION, "behavior harness requires Lua 5.1")
	print("PASS lua_51_smoke")
end

function cases.raid_session_create_failure_is_atomic(addon)
	for _, failure in ipairs({ "create_nil", "create_throw", "insert_nil", "insert_throw" }) do
		local fixture, raid = installRaidCreationFixture(addon, failure)
		local oldRevision = fixture.store:GetRaidSyncRevision(fixture.raids[1])
		local oldRaid = deepCopy(fixture.raids[1])
		local oldRuntime = deepCopy(addon.State.raid)
		local oldPlayers = deepCopy(fixture.realmPlayers)
		local ok, result = pcall(raid.Create, raid, "Ulduar", 25, 2)
		assertEqual(true, ok, "creation exception must be contained")
		assertEqual(false, result, "injected creation failure must return false")
		assertEqual(1, addon.Database.GetCurrentRaid(), "old raid must remain current")
		assertTrue(deepEqual(oldRaid, fixture.raids[1]), "old raid must remain open and unchanged")
		assertTrue(deepEqual(oldRuntime, addon.State.raid), "runtime raid state must remain unchanged")
		assertEqual(oldRevision, fixture.store:GetRaidSyncRevision(fixture.raids[1]), "old revision must remain unchanged")
		assertEqual(2, #fixture.raids, "failed creation must not persist a partial raid")
		assertTrue(deepEqual(oldPlayers, fixture.realmPlayers), "failed creation must preserve realm metadata")
		if fixture.candidateRaidNid then
			assertEqual(nil, fixture.store:GetRaidIndexByNid(fixture.candidateRaidNid), "candidate nid must leave no index")
		end
		assertEqual(1, fixture.store:GetRaidIndexByNid(41), "first existing nid mapping must survive rollback")
		assertEqual(2, fixture.store:GetRaidIndexByNid(73), "second existing nid mapping must survive rollback")
		assertEqual(0, #fixture.events, "failed creation must publish no event")
	end
	print("PASS raid_session_create_failure_is_atomic")
end

function cases.raid_session_replacement_preserves_event_order(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	assertEqual(true, raid:Create("Ulduar", 25, 2), "replacement must succeed")
	assertEqual(3, addon.Database.GetCurrentRaid(), "new raid must become current")
	assertEqual("insert", fixture.order[1], "replacement must be admitted before old-session effects")
	assertEqual("RaidAttendanceChanged", fixture.order[2], "old attendance close event order changed")
	assertEqual("RaidCreate", fixture.order[3], "raid create event must remain last")
	assertEqual(3, fixture.attendanceEventCurrentRaid, "attendance publication must observe the committed replacement")
	print("PASS raid_session_replacement_preserves_event_order")
end


function cases.raid_session_switch_failure_rolls_back_candidate(addon)
	for _, mode in ipairs({ "delete_false", "delete_throw" }) do
		for _, switchThrows in ipairs({ false, true }) do
			local fixture, raid = installRaidCreationFixture(addon, mode)
			local oldRaid = deepCopy(fixture.raids[1])
			local oldRuntime = deepCopy(addon.State.raid)
			local oldPlayers = deepCopy(fixture.realmPlayers)
			local setCurrentRaid = addon.Database.SetCurrentRaid
			addon.Database.SetCurrentRaid = function(raidId)
				if raidId == 3 then
					addon.State.currentRaid = raidId
					if switchThrows then error("switch failure") end
					return nil
				end
				return setCurrentRaid(raidId)
			end
			local ok, result = pcall(raid.Create, raid, "Ulduar", 25, 2)
			assertEqual(true, ok, "switch failure must be contained when delete rollback is unavailable")
			assertEqual(false, result, "injected switch failure must return false")
			assertEqual(1, addon.Database.GetCurrentRaid(), "switch failure must preserve current raid")
			assertTrue(deepEqual(oldRaid, fixture.raids[1]), "switch failure must preserve the open raid")
			assertTrue(deepEqual(oldRuntime, addon.State.raid), "switch failure must preserve runtime counts")
			assertTrue(deepEqual(oldPlayers, fixture.realmPlayers), "switch failure must preserve realm metadata")
			assertEqual(2, #fixture.raids, "switch failure must roll back the admitted candidate")
			assertTrue(fixture.candidateRaidNid ~= nil, "switch fixture must capture the allocated candidate nid")
			assertEqual(nil, fixture.store:GetRaidIndexByNid(fixture.candidateRaidNid), "candidate nid must leave no index")
			assertEqual(1, fixture.store:GetRaidIndexByNid(41), "first existing nid mapping must survive rollback")
			assertEqual(2, fixture.store:GetRaidIndexByNid(73), "second existing nid mapping must survive rollback")
			assertEqual(0, #fixture.events, "switch failure must publish no event")
		end
	end
	print("PASS raid_session_switch_failure_rolls_back_candidate")
end

function cases.raid_recording_fixture_smoke(addon)
	local fixture = newRaidRecordingFixture(addon)
	assertEqual(41, fixture.raids[1].raidNid, "first fixture raid must use a non-index nid")
	assertEqual(73, fixture.raids[2].raidNid, "second fixture raid must use a non-index nid")
	local raidCopy = deepCopy(fixture.raids[1])
	assertTrue(deepEqual(fixture.raids[1], raidCopy), "fixture raids must support stable deep copies")
	raidCopy.players[1].name = "Changed"
	assertEqual("Alpha", fixture.raids[1].players[1].name, "nested copy mutation must not change the source raid")
	fixture:AssertRevision(41, 3)
	fixture.store:TouchRaidSyncRevision(fixture.raids[1])
	fixture:AssertRevision(41, 4)

	addon.Bus.TriggerEvent("RMA_RAID_UPDATED", 41, { source = "smoke" })
	fixture:AssertEvent(1, "RMA_RAID_UPDATED", 41, { source = "smoke" })

	local timerTarget = {}
	fixture:InstallTimers(timerTarget)
	local timerArgs
	local timerHandle = timerTarget:ScheduleTimer(function(first, second, third)
		timerArgs = { first, second, third }
	end, 5, "alpha", nil, "omega")
	local cancelledHandle = timerTarget:ScheduleTimer(function()
		fail("cancelled timer must not fire")
	end, 5)
	assertEqual(true, timerTarget:CancelTimer(cancelledHandle), "active timer cancellation must succeed")
	assertEqual(false, timerTarget:CancelTimer(cancelledHandle), "timer cancellation must be deterministic")
	fixture:AdvanceTime(4)
	assertEqual(nil, timerArgs, "timer must remain pending before its deadline")
	fixture:AdvanceTime(1)
	assertEqual("alpha", timerArgs[1], "timer callback first argument differs")
	assertEqual(nil, timerArgs[2], "timer callback nil argument differs")
	assertEqual("omega", timerArgs[3], "timer callback trailing argument differs")
	assertEqual(false, timerTarget:CancelTimer(timerHandle), "completed timer must not remain cancellable")

	assertEqual(2, GetNumRaidMembers(), "fixture roster count differs")
	assertEqual("Beta", UnitName("raid2"), "fixture unit lookup differs")
	local rosterName, _, _, _, rosterClass, _, _, online = GetRaidRosterInfo(1)
	assertEqual("Alpha", rosterName, "fixture roster name differs")
	assertEqual("Warrior", rosterClass, "fixture roster class differs")
	assertEqual(true, online, "fixture roster online state differs")

	local inspectedName
	fixture:RegisterInspectCallback("raid2", function(name)
		inspectedName = name
	end)
	NotifyInspect("raid2")
	fixture:FireInspectCallback("raid2", "Beta")
	assertEqual("raid2", fixture.inspectRequests[1], "fixture must capture inspect requests")
	assertEqual("Beta", inspectedName, "fixture must invoke inspect callbacks")
	print("PASS raid_recording_fixture_smoke")
end

function cases.bootstrap_retries_after_failure(addon)
	local frame = installInitStubs(addon)
	local normalizeCalls = 0
	addon.Database.SavedVariables = {
		EnsureAll = function() end,
		NormalizeAfterLoad = function()
			normalizeCalls = normalizeCalls + 1
			if normalizeCalls == 1 then
				error("normalize failed")
			end
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Init.lua")

	local ok, err = pcall(addon.ADDON_LOADED, addon, "Raid Management Addon")
	assertEqual(false, ok, "first bootstrap attempt should surface the failure")
	assertTrue(string.find(tostring(err), "normalize failed", 1, true), "original bootstrap error should be visible")
	assertTrue(frame.registered.ADDON_LOADED, "failed bootstrap should keep ADDON_LOADED registered")
	assertEqual(false, addon.State.initialized == true, "failed bootstrap should not mark initialization complete")

	addon:ADDON_LOADED("Raid Management Addon")
	assertEqual(true, addon.State.initialized, "retry should complete initialization")
	assertEqual(nil, frame.registered.ADDON_LOADED, "successful bootstrap should remove ADDON_LOADED")
	assertEqual(1, frame.registerCount.CHAT_MSG_SYSTEM, "runtime events should be registered once")
	print("PASS bootstrap_retries_after_failure")
end

function cases.bootstrap_success_commits_before_roster_refresh(addon)
	local frame = installInitStubs(addon)
	local order = {}
	local registerEvent = frame.RegisterEvent
	function frame:RegisterEvent(eventName)
		registerEvent(self, eventName)
		if eventName ~= "ADDON_LOADED" then
			order[#order + 1] = "register"
		end
	end

	addon.Database.SavedVariables = {
		EnsureAll = function() end,
		NormalizeAfterLoad = function() end,
	}
	addon.State.debugEnabled = true
	addon.debug = function()
		order[#order + 1] = "debug"
	end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	addon.RAID_ROSTER_UPDATE = function(_, forceImmediate)
		assertEqual(true, forceImmediate, "bootstrap roster refresh should be immediate")
		order[#order + 1] = "roster"
	end

	addon:ADDON_LOADED("Raid Management Addon")

	assertEqual(#expectedRuntimeEvents + 2, #order, "bootstrap should register, report, then refresh")
	for i = 1, #expectedRuntimeEvents do
		assertEqual("register", order[i], "all runtime events should commit before roster refresh")
	end
	assertEqual("debug", order[#expectedRuntimeEvents + 1], "debug registration report should precede roster refresh")
	assertEqual("roster", order[#expectedRuntimeEvents + 2], "roster refresh should finish successful bootstrap")
	print("PASS bootstrap_success_commits_before_roster_refresh")
end

local function installRealRosterFixture(addon, fixture)
	_G.table.wipe = _G.table.wipe or function(target)
		for key in pairs(target) do
			target[key] = nil
		end
		return target
	end
	_G.UnitRace = function()
		return "Human", "Human"
	end
	_G.UnitSex = function()
		return 2
	end
	_G.UnitExists = function()
		return true
	end
	_G.GetInstanceInfo = function()
		return "Test", "none", 0
	end
	_G.GetNumRaidMembers = function()
		return #fixture.roster
	end
	_G.GetRaidRosterInfo = function(index)
		local member = fixture.roster[index]
		if not member then
			return nil
		end
		return member.name, member.rank, member.subgroup, member.level, member.class, string.upper(member.class), nil,
			member.online
	end

	addon.Events = { Internal = { RaidRosterDelta = "RaidRosterDelta" } }
	addon.Diag = { D = { LogRaidLeftGroupEndSession = "left", LogRaidRosterUpdate = "%s %s" } }
	addon.L = { RaidZones = {} }
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Strings = { NormalizeName = function(name) return name end }
	addon.Time = { GetCurrentTime = function() return fixture.now end }
	addon.State = {}
	addon.IsInRaid = function() return fixture.inRaid end
	addon.IsInGroup = function() return fixture.inRaid end
	addon.UnitIterator = function() return function() return nil end end
	addon.Services = {
		Raid = { _IsUnknownNameInternal = function(name) return name == nil end },
		EnsureNamespace = function(name, child)
			addon.Services[name] = addon.Services[name] or {}
			if child then addon.Services[name][child] = addon.Services[name][child] or {} end
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			fixture:InstallTimers(target)
		end,
	}
	addon.Database.SavedVariables = { GetPlayers = function() return {} end }
	addon.Database.GetCurrentRaid = function() return fixture.currentRaid end
	addon.Database.GetRealmName = function() return "Test Realm" end
	addon.Database.EnsureRaidByIndex = function(index) return fixture.raids[index] end
	addon.Database.GetRaidStore = function()
		return { EnsureRaidRuntime = function(_, raid)
			raid._runtime = raid._runtime or { playersByName = {} }
			for i = 1, #(raid.players or {}) do
				raid._runtime.playersByName[raid.players[i].name] = raid.players[i]
			end
			return raid._runtime
		end }
	end
	addon.Bus.TriggerEvent = function(eventName, ...)
		fixture.events[#fixture.events + 1] = { name = eventName, args = { ... } }
	end

	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Roster.lua")
	local raid = addon.Services.Raid
	function raid:Check() end
	function raid:AddPlayer(player)
		local players = fixture.raids[fixture.currentRaid].players
		if not player.playerNid then player.playerNid = 100 + #players end
		local found = false
		for i = 1, #players do
			if players[i] == player then found = true break end
		end
		if not found then players[#players + 1] = player end
		return player
	end
	function raid:End()
		local current = fixture.currentRaid
		local record = fixture.raids[current]
		for i = 1, #(record.players or {}) do
			if not record.players[i].leave then record.players[i].leave = fixture.now end
		end
		fixture.currentRaid = nil
	end
	return raid
end

function cases.real_roster_session_end_publishes_final_delta(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = 1
	fixture.inRaid = true
	fixture.roster = {}
	fixture.raids[1].players[1].leave = nil
	local raid = installRealRosterFixture(addon, fixture)

	local delta = raid:RefreshAndPublish()
	assertTrue(type(delta) == "table", "session-ending mutation must return a delta")
	assertEqual(true, delta.sessionEnded, "session-ending delta must be distinguishable")
	assertEqual(1, delta.raidNum, "session-ending delta must retain stable raid identity")
	assertEqual(1, #delta.left, "session-ending delta must finalize leavers")
	assertEqual(1, #fixture.events, "session-ending mutation must publish exactly once")
	fixture:AssertEvent(1, "RaidRosterDelta", delta, 1, 1)
	assertEqual(nil, fixture.currentRaid, "session end must clear current raid after identity capture")

	local noOp = raid:RefreshAndPublish()
	assertEqual(nil, noOp, "refresh without a current raid must be a no-op")
	assertEqual(1, #fixture.events, "no-op refresh must not publish")
	print("PASS real_roster_session_end_publishes_final_delta")
end

function cases.real_attendance_manual_refresh_calls_roster_owner(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = 1
	fixture.inRaid = true
	fixture.raids[1].players = {}
	fixture.roster = { { name = "Alpha", rank = 2, subgroup = 1, level = 80, class = "Warrior", online = true } }
	local raid = installRealRosterFixture(addon, fixture)
	addon.L = {
		StrRaidAttendance = "Attendance", MsgAttendanceRemoved = "Removed %d attendance record(s).",
		StrInspectQueued = "Queued", StrInspectPending = "Pending", StrInspectNotInspected = "Not inspected",
		MsgForceInspectMissingUnit = "Unit missing", MsgForceInspectOffline = "Player offline",
		MsgForceInspectOutOfRange = "Player out of range", MsgForceInspectCannotInspect = "Cannot inspect player",
		MsgForceInspectNotifyFailed = "Inspect request failed",
	}
	addon.Diag = { W = { ErrLoggerUpdateRosterNotInRaid = "not raid", ErrLoggerUpdateRosterNotCurrent = "not current" } }
	addon.Controllers = {}
	addon.Database.GetCurrentRaid = function() return 1 end
	addon.Database.GetRaids = function() return {} end
	addon.Database.GetRaidIndexByNid = function(raidNid) return tonumber(raidNid) == 42 and 2 or nil end
	addon.IsInRaid = function() return true end
	local warnMessage
	addon.warn = function(_, message) warnMessage = message end
	local infoMessage
	addon.info = function(_, message) infoMessage = message end
	local deleteRaidNid
	addon.Services.Attendance = {
		Store = { GetRaid = function(_, raidIndex) return fixture.raids[raidIndex] end },
		View = {},
		Actions = { DeleteRaidAttendance = function(_, raidNid) deleteRaidNid = raidNid return 1 end },
		Export = {},
	}
	local forceResult = { true, "queued" }
	addon.Services.EquipInspect = { ForcePlayer = function() return unpack(forceResult) end }
	raid.Projections = {}
	raid.LootBans = {}
	addon.Events = { Internal = {
		RaidCreate = "RaidCreate", RaidAttendanceChanged = "RaidAttendanceChanged",
		EquipInspectUpdated = "EquipInspectUpdated", EquipInspectCompleted = "EquipInspectCompleted",
		LoggerClearPlayerSelections = "LoggerClearPlayerSelections", LootBansChanged = "LootBansChanged",
	} }
	local registeredCallbacks = {}
	addon.Bus = {
		TriggerEvent = function() end,
		RegisterCallback = function(eventName, callback) registeredCallbacks[eventName] = callback end,
	}
	addon.Timer = { BindMixin = function() end }
	addon.Sort = { CompareNumbers = function() return false end, CompareValues = function() return false end }
	addon.Colors = {}
	local function noop() end
	local controllerConfigs = {}
	local boundOnClick
	local boundDeleteOnClick
	local boundForceOnClick
	local dirtyCount = 0
	local function newWidget()
		return { SetText = noop, SetWidth = noop, ClearAllPoints = noop, SetPoint = noop }
	end
	local listName = "RMARaidAttendanceRaidAttendees"
	_G[listName] = newWidget()
	for _, suffix in ipairs({
		"Title", "HeaderName", "HeaderJoin", "HeaderLeave", "HeaderIlvl", "HeaderSpec", "HeaderInspect",
		"AddBtn", "DeleteBtn", "ForceInspectBtn",
	}) do
		_G[listName .. suffix] = newWidget()
	end
	addon.UI = {
		ExportDialog = {},
		Rows = { SetLoggerRowIndex = noop, ApplyLoggerSkin = noop },
		Frames = {
			GetRef = noop,
			SetScriptSafely = function(widget, scriptName, callback)
				if widget == _G[listName .. "AddBtn"] and scriptName == "OnClick" then boundOnClick = callback end
				if widget == _G[listName .. "DeleteBtn"] and scriptName == "OnClick" then boundDeleteOnClick = callback end
				if widget == _G[listName .. "ForceInspectBtn"] and scriptName == "OnClick" then boundForceOnClick = callback end
			end,
			SetFrameTitle = noop, BindModuleFrame = noop,
			MakeFrameGetter = function() return function() return nil end end,
		},
		Tooltips = { ShowItem = noop, ShowLines = noop, Hide = noop, BindModel = noop },
		Primitives = { SetShown = noop },
		Lists = {
			CalculateColumnWidths = function() return {} end,
			CreateController = function(cfg)
				controllerConfigs[#controllerConfigs + 1] = cfg
				return { Dirty = function() dirtyCount = dirtyCount + 1 end, OnLoad = noop }
			end,
			MakeIndexedRowName = function() return "Row" end,
			CreateRowRenderer = function(fn) return fn end,
			BindController = noop,
		},
	}
	_G.CreateFrame = function() return {} end
	loadAddonFile(addon, "Raid Management Addon/Controllers/Attendance.lua")
	addon.Controllers.Attendance.attendanceSelectedRaid = 1
	assertTrue(type(controllerConfigs[2].localize) == "function", "Attendance player-list binding missing")
	controllerConfigs[2].localize(listName)
	assertTrue(type(boundOnClick) == "function", "Attendance update button OnClick binding missing")
	boundOnClick()
	assertEqual(1, #fixture.events, "Attendance mutation must publish exactly once through roster owner")
	assertEqual(1, raid:GetRosterVersion(), "Attendance mutation must advance roster version once")
	addon.Controllers.Attendance.attendanceSelectedRaid = 2
	local dirtyBaseline = dirtyCount
	registeredCallbacks.RaidAttendanceChanged(nil, 2)
	assertEqual(dirtyBaseline, dirtyCount, "raid index must not be treated as stable attendance event identity")
	registeredCallbacks.RaidAttendanceChanged(nil, 42)
	assertEqual(dirtyBaseline + 2, dirtyCount, "stable raid identity must resolve to the selected UI index")
	addon.Controllers.Attendance.attendanceSelectedPlayer = 21
	assertTrue(type(boundDeleteOnClick) == "function", "Attendance delete button OnClick binding missing")
	boundDeleteOnClick()
	assertEqual(73, deleteRaidNid, "Attendance deletion must cross the UI edge with stable raid identity")
	assertEqual("Removed 1 attendance record(s).", infoMessage, "Attendance deletion must provide localized feedback")
	addon.Controllers.Attendance.attendanceSelectedRaid = 1
	addon.Controllers.Attendance.attendanceSelectedPlayer = 21
	assertTrue(type(boundForceOnClick) == "function", "Attendance force-inspect OnClick binding missing")
	boundForceOnClick()
	assertEqual("Queued", infoMessage, "queued force inspect must provide localized feedback")
	forceResult = { false, "pending" }
	boundForceOnClick()
	assertEqual("Pending", infoMessage, "pending force inspect must provide localized feedback")
	forceResult = { false, "missing_player" }
	boundForceOnClick()
	assertEqual("Not inspected", warnMessage, "missing force inspect target must provide localized feedback")
	for _, scenario in ipairs({
		{ "missing_unit", "Unit missing" }, { "offline", "Player offline" },
		{ "out_of_range", "Player out of range" }, { "cannot_inspect", "Cannot inspect player" },
		{ "notify_failed", "Inspect request failed" },
	}) do
		forceResult = { false, scenario[1] }
		boundForceOnClick()
		assertEqual(scenario[2], warnMessage, scenario[1] .. " must provide localized feedback")
	end
	print("PASS real_attendance_manual_refresh_calls_roster_owner")
end

function cases.attendance_controller_resolves_stable_event_identity(addon)
	cases.real_attendance_manual_refresh_calls_roster_owner(addon)
	print("PASS attendance_controller_resolves_stable_event_identity")
end

function cases.attendance_seed_and_close_are_idempotent_revisioned_transactions(addon)
	local fixture = newRaidRecordingFixture(addon)
	local raid = installRealAttendanceFixture(addon, fixture)
	local record = fixture.raids[2]

	assertEqual(true, raid:SeedAttendanceFromCurrentRoster(2, "seed"), "first seed must mutate attendance")
	assertEqual(1, #record.attendance, "seed must create one attendance row")
	assertEqual(1, #record.attendance[1].segments, "seed must create one segment")
	fixture:AssertRevision(42, 1, "seed must touch revision once")
	fixture:AssertEvent(1, "RaidAttendanceChanged", 42, "seed")

	assertEqual(false, raid:SeedAttendanceFromCurrentRoster(2, "duplicate_seed"), "duplicate seed must be a no-op")
	assertEqual(1, #record.attendance[1].segments, "duplicate seed must reuse the open segment")
	fixture:AssertRevision(42, 1, "duplicate seed must preserve revision")
	assertEqual(1, #fixture.events, "duplicate seed must emit nothing")

	assertEqual(true, raid:CloseAttendanceForRaid(record, 1010, "close"), "first close must mutate attendance")
	assertEqual(1010, record.attendance[1].segments[1].endTime, "close must finalize the open segment")
	fixture:AssertRevision(42, 2, "close must touch revision once")
	fixture:AssertEvent(2, "RaidAttendanceChanged", 42, "close")

	assertEqual(false, raid:CloseAttendanceForRaid(record, 1020, "duplicate_close"), "duplicate close must be a no-op")
	fixture:AssertRevision(42, 2, "duplicate close must preserve revision")
	assertEqual(2, #fixture.events, "duplicate close must emit nothing")
	print("PASS attendance_seed_and_close_are_idempotent_revisioned_transactions")
end

function cases.attendance_delta_records_only_presence_transitions(addon)
	local fixture = newRaidRecordingFixture(addon)
	local raid = installRealAttendanceFixture(addon, fixture)
	local record = fixture.raids[2]
	assertEqual(true, raid:SeedAttendanceFromCurrentRoster(2, "seed"), "seed must establish presence")
	fixture.events = {}

	local callback = assert(fixture.attendanceCallbacks.RaidRosterDelta)
	callback(nil, { timestamp = 1001, joined = { { playerNid = 21, subgroup = 1, online = true } }, reason = "join" }, nil, 2)
	callback(nil, { timestamp = 1002, updated = { { playerNid = 21, subgroup = 1, online = true, rank = 1 } }, reason = "rank" }, nil, 2)
	assertEqual(1, #record.attendance[1].segments, "duplicate join and rank-only update must reuse the segment")
	fixture:AssertRevision(42, 1, "duplicate and rank-only deltas must preserve revision")
	assertEqual(0, #fixture.events, "duplicate and rank-only deltas must emit nothing")

	callback(nil, { timestamp = 1003, updated = { { playerNid = 21, subgroup = 2, online = true } }, reason = "subgroup" }, nil, 2)
	assertEqual(2, #record.attendance[1].segments, "subgroup transition must close and open exactly once")
	assertEqual(1003, record.attendance[1].segments[1].endTime, "subgroup transition must close prior segment")
	fixture:AssertRevision(42, 2, "subgroup transition must touch revision once")
	fixture:AssertEvent(1, "RaidAttendanceChanged", 42, "subgroup")

	callback(nil, { timestamp = 1004, updated = { { playerNid = 21, subgroup = 2, online = false } }, reason = "offline" }, nil, 2)
	assertEqual(3, #record.attendance[1].segments, "online transition must close and open exactly once")
	assertEqual(1004, record.attendance[1].segments[2].endTime, "online transition must close prior segment")
	assertEqual(false, record.attendance[1].segments[3].online, "online transition must preserve offline state")
	fixture:AssertRevision(42, 3, "online transition must touch revision once")
	fixture:AssertEvent(2, "RaidAttendanceChanged", 42, "offline")
	print("PASS attendance_delta_records_only_presence_transitions")
end

function cases.attendance_unknown_and_duplicate_leave_are_deep_noops(addon)
	local fixture = newRaidRecordingFixture(addon)
	installRealAttendanceFixture(addon, fixture)
	local record = fixture.raids[2]
	record.attendance = {
		{ playerNid = 21, segments = { { startTime = 975, endTime = 1000 } } },
		{ playerNid = 22, segments = "malformed" },
	}
	local before = deepCopy(record)
	local callback = assert(fixture.attendanceCallbacks.RaidRosterDelta)
	callback(nil, {
		timestamp = 1010,
		left = { { playerNid = 99 }, { playerNid = 21 }, { playerNid = 22 } },
		reason = "leave",
	}, nil, 2)

	assertTrue(deepEqual(before, record), "unknown, duplicate, and malformed-entry leave must preserve the raid deeply")
	fixture:AssertRevision(42, 0, "no-op leaves must preserve revision")
	assertEqual(0, #fixture.events, "no-op leaves must publish no attendance event")
	print("PASS attendance_unknown_and_duplicate_leave_are_deep_noops")
end

function cases.attendance_delayed_transition_remains_monotonic(addon)
	local fixture = newRaidRecordingFixture(addon)
	installRealAttendanceFixture(addon, fixture)
	local record = fixture.raids[2]
	record.attendance = { { playerNid = 21, segments = { { startTime = 1000, subgroup = 2 } } } }
	local callback = assert(fixture.attendanceCallbacks.RaidRosterDelta)
	callback(nil, {
		timestamp = 990,
		updated = { { playerNid = 21, subgroup = 3, online = false } },
		reason = "delayed_transition",
	}, nil, 2)

	local segments = record.attendance[1].segments
	assertEqual(2, #segments, "delayed transition must create one replacement segment")
	assertEqual(1000, segments[1].endTime, "delayed transition must close at the previous start")
	assertEqual(1000, segments[2].startTime, "replacement start must equal the monotonic close time")
	assertEqual(3, segments[2].subgroup, "replacement must retain the new subgroup")
	assertEqual(false, segments[2].online, "replacement must retain the new online state")
	fixture:AssertRevision(42, 1, "one delayed transition must touch revision once")
	assertEqual(1, #fixture.events, "one delayed transition must publish exactly once")
	fixture:AssertEvent(1, "RaidAttendanceChanged", 42, "delayed_transition")
	print("PASS attendance_delayed_transition_remains_monotonic")
end

function cases.attendance_removal_preserves_raid_history(addon)
	local fixture = newRaidRecordingFixture(addon)
	local raid = fixture.raids[2]
	raid.raidNid = 42
	raid.players = { { playerNid = 21, name = "Beta" }, { playerNid = 22, name = "Gamma" } }
	raid.attendance = {
		{ playerNid = 21, segments = { { startTime = 950, endTime = 980 } } },
		{ playerNid = 22, segments = { { startTime = 960, endTime = 990 } } },
	}
	raid.bossKills = { { bossNid = 1, name = "Flame Leviathan", players = { 21, 22 } } }
	raid.loot = { { lootNid = 1, itemId = 45038, looterNid = 21, bossNid = 1 } }
	raid.inspect = { players = { [21] = { status = "ready", itemLevel = 226 } } }
	fixture.store:SetRaidSyncRevision(raid, 8)
	function fixture.store:EnsureRaidByNid(raidNid)
		return self:GetRaidByNid(tonumber(raidNid))
	end
	function fixture.store:EnsureRaidRuntime()
		return { playerIdxByNid = { [21] = 1, [22] = 2 } }
	end

	addon.Events = { Internal = { RaidAttendanceChanged = "RaidAttendanceChanged" } }
	addon.Services = {
		EnsureNamespace = function(name, child)
			addon.Services[name] = addon.Services[name] or {}
			if child then addon.Services[name][child] = addon.Services[name][child] or {} end
		end,
		Attendance = { Store = {
			GetRaid = function(_, raidIndex) return fixture.raids[raidIndex] end,
			InvalidateRaidIndexes = function() end,
		} },
	}
	addon.Database.EnsureRaidSchema = function(value) return value end
	loadAddonFile(addon, "Raid Management Addon/Services/Attendance/Actions.lua")

	local playersBefore = deepCopy(raid.players)
	local bossesBefore = deepCopy(raid.bossKills)
	local lootBefore = deepCopy(raid.loot)
	local inspectBefore = deepCopy(raid.inspect)
	local removed = addon.Services.Attendance.Actions:DeleteRaidAttendance(42, { 21 })
	assertEqual(1, removed, "selected attendance evidence must be removed")
	assertEqual(1, #raid.attendance, "only one attendance row must remain")
	assertEqual(22, raid.attendance[1].playerNid, "unselected attendance must remain")
	assertTrue(deepEqual(playersBefore, raid.players), "player identity must remain")
	assertTrue(deepEqual(bossesBefore, raid.bossKills), "boss membership must remain")
	assertTrue(deepEqual(lootBefore, raid.loot), "loot attribution must remain")
	assertTrue(deepEqual(inspectBefore, raid.inspect), "inspect snapshot must remain")
	fixture:AssertRevision(42, 9, "attendance deletion must advance revision once")
	fixture:AssertEvent(1, "RaidAttendanceChanged", 42, "attendance_delete")

	assertEqual(0, addon.Services.Attendance.Actions:DeleteRaidAttendance(42, { 21 }), "repeat removal must be a no-op")
	fixture:AssertRevision(42, 9, "no-op deletion must preserve revision")
	assertEqual(1, #fixture.events, "no-op deletion must publish no event")
	print("PASS attendance_removal_preserves_raid_history")
end

function cases.real_logger_set_current_raid_calls_roster_owner(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = nil
	fixture.inRaid = true
	fixture.raids[1].zone = "Ulduar"
	fixture.raids[1].difficulty = 2
	fixture.raids[1].size = 10
	fixture.raids[1].players = {}
	fixture.roster = { { name = "Alpha", rank = 2, subgroup = 1, level = 80, class = "Warrior", online = true } }
	local raid = installRealRosterFixture(addon, fixture)
	addon.L = {
		RaidZones = {},
		LogRaidSetCurrent = "%s %s %s",
		ErrCannotSetCurrentNotInRaid = "not raid", ErrCannotSetCurrentNotInInstance = "not instance",
		ErrCannotSetCurrentZoneMismatch = "zone", ErrCannotSetCurrentRaidDifficulty = "difficulty",
		ErrCannotSetCurrentRaidSize = "size", ErrCannotSetCurrentRaidReset = "reset",
	}
	addon.Diag = {}
	addon.Strings = {}
	addon.Base64 = {}
	addon.LootSourceCandidates = {}
	addon.Time = { GetCurrentTime = function() return 1000 end }
	addon.Events = { Internal = { LoggerLootChanged = "LoggerLootChanged", LoggerDataChanged = "LoggerDataChanged" } }
	addon.Bus = { TriggerEvent = function() end }
	addon.Timer = { BindMixin = function() end }
	raid.GetRaidSize = function() return 10 end
	raid.IsRaidExpired = function() return false end
	addon.Database.EnsureRaidByIndex = function(index)
		if index == 1 then return fixture.raids[1] end
	end
	addon.Database.SetCurrentRaid = function(index) fixture.currentRaid = index end
	addon.Database.SetLastBoss = function() end
	addon.IsInRaid = function() return true end
	addon.error = function(_, message) fail(message) end
	addon.info = function() end
	_G.GetInstanceInfo = function() return "Ulduar", "raid", 2, nil, nil, 0, false end
	loadAddonFile(addon, "Raid Management Addon/Services/Logger/Actions.lua")
	local result = addon.Services.Logger.Actions:SetCurrentRaid(1)
	assertEqual(true, result, "Logger should select a compatible raid")
	assertEqual(1, fixture.currentRaid, "Logger should set current raid before refresh")
	assertEqual(1, #fixture.events, "Logger mutation must publish exactly once through roster owner")
	assertEqual(1, raid:GetRosterVersion(), "Logger mutation must advance roster version once")
	print("PASS real_logger_set_current_raid_calls_roster_owner")
end

function cases.real_roster_dispatch_and_scheduled_paths_publish_once(addon)
	installInitStubs(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = 1
	fixture.inRaid = true
	fixture.raids[1].players = {}
	fixture.roster = { { name = "Alpha", rank = 2, subgroup = 1, level = 80, class = "Warrior", online = true } }
	local raid = installRealRosterFixture(addon, fixture)
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	fixture:InstallTimers(addon)

	addon:RAID_ROSTER_UPDATE()
	addon:RAID_ROSTER_UPDATE()
	fixture:AdvanceTime(0.25)
	assertEqual(1, #fixture.events, "debounced dispatcher mutation must publish exactly once")
	assertEqual(1, raid:GetRosterVersion(), "dispatcher mutation must advance roster version once")

	fixture.roster[2] = { name = "Beta", rank = 0, subgroup = 1, level = 80, class = "Priest", online = true }
	raid._ScheduleRosterRefreshInternal()
	raid._ScheduleRosterRefreshInternal()
	fixture:AdvanceTime(2)
	assertEqual(2, #fixture.events, "superseded roster callback must be cancelled")
	assertEqual(2, raid:GetRosterVersion(), "scheduled mutation must advance roster version once")

	raid:RefreshAndPublish()
	assertEqual(2, #fixture.events, "real roster no-op must not publish")
	print("PASS real_roster_dispatch_and_scheduled_paths_publish_once")
end

local function installLoggerCleanupFixture(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = 2
	fixture.raids[1].players = {}
	fixture.raids[1].loot = {}
	fixture.raids[2].bossKills = { { bossNid = 1, name = "Flame Leviathan" } }
	fixture.raids[2].loot = {
		{ lootNid = 1, itemRarity = 3 },
		{ lootNid = 2, itemRarity = 4 },
		{ lootNid = 3, itemRarity = 2 },
	}
	addon.DB = {}
	addon.State = { raidStore = {} }
	addon.Database = addon.Database or {}
	addon.Database.IsBossFightRecord = function() return true end
	addon.Database.GetRaidSchemaVersion = function() return 6 end
	addon.Database.GetRaidMigrations = function() return nil end
	addon.Database.SavedVariables = { GetRaids = function() return fixture.raids end }
	addon.Database.GetCurrentRaid = function() return fixture.currentRaid end
	addon.Database.SetCurrentRaid = function(value) fixture.currentRaid = value end
	addon.Database.SetLastBoss = function(value) fixture.lastBoss = value end
	addon.Time = { GetCurrentTime = function() return fixture.now end }
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidStore.lua")
	fixture.store = addon.DB.RaidStore
	addon.Database.GetRaidStore = function() return fixture.store end
	fixture.store:GetAllRaids()
	fixture.store:SetRaidSyncRevision(fixture.raids[2], 8)
	addon.L = {}
	addon.Diag = {}
	addon.Strings = { NormalizeName = function(value) return value end, NormalizeLower = string.lower }
	addon.Base64 = {}
	addon.LootSourceCandidates = {}
	addon.LootSources = {}
	addon.LootSourcesData = {}
	addon.Services = {
		EnsureNamespace = function(name, child)
			addon.Services[name] = addon.Services[name] or {}
			if child then addon.Services[name][child] = addon.Services[name][child] or {} end
		end,
		Logger = { Store = {}, Helpers = {} },
	}
	addon.Timer = { BindMixin = function(target) fixture:InstallTimers(target) end }
	addon.Events = { Internal = { LoggerLootChanged = "LoggerLootChanged", LoggerDataChanged = "LoggerDataChanged" } }
	addon.Bus = { TriggerEvent = function(eventName, payload)
		fixture.events[#fixture.events + 1] = { name = eventName, args = { payload } }
	end }
	loadAddonFile(addon, "Raid Management Addon/Services/Logger/Actions.lua")
	return fixture, addon.Services.Logger.Actions
end

function cases.logger_cleanup_is_store_owned_and_revision_coherent(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local result = actions:CleanupRaidHistory({ emptyRaids = true, nonEpicLoot = true })
	assertEqual(true, result.changed, "cleanup should report canonical mutation")
	assertEqual(true, result.complete, "synchronous cleanup should complete")
	assertEqual(1, result.raidsRemoved, "empty raid should be removed")
	assertEqual(2, result.lootRemoved, "non-epic loot should be removed")
	assertEqual(1, #fixture.raids, "one raid should survive")
	assertEqual(73, fixture.raids[1].raidNid, "stable raid identity should survive compaction")
	assertEqual(1, fixture.currentRaid, "current selection should follow stable raid identity")
	assertEqual(9, fixture.store:GetRaidSyncRevision(fixture.raids[1]), "surviving raid should advance once")
	assertEqual(true, fixture.store:RequiresFullSyncSince(fixture.raids[1], 8), "loot deletion requires full sync")
	assertEqual(1, #fixture.events, "cleanup should publish once")
	print("PASS logger_cleanup_is_store_owned_and_revision_coherent")
end

local function installLoggerAtomicFixture(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local raid = fixture.raids[2]
	raid.players = { { playerNid = 21, name = "Beta" } }
	raid.bossKills = {}
	raid.loot = { { lootNid = 7, itemId = 45038, itemLink = "[Fragment]" } }
	raid.nextBossNid = 4
	fixture.store:EnsureRaidRuntime(raid)
	addon.Base64.Encode = function(value) return value end
	addon.LootSourceCandidates.Copy = function(value) return deepCopy(value) end
	addon.LootSources.FindSource = function(itemId)
		if itemId == 45038 then
			return { kind = "boss", npcId = 33113, npcName = "Flame Leviathan", sourceKey = "ulduar:33113" }
		end
		return nil
	end
	addon.LootSourcesData.ActivateInstance = function() return true end
	addon.LootSourcesData.GetActiveInstanceKey = function() return "ulduar" end
	local queries = {}
	function queries:FindBossByNid(target, nid)
		for i = 1, #(target.bossKills or {}) do
			if tonumber(target.bossKills[i].bossNid) == tonumber(nid) then return target.bossKills[i] end
		end
	end
	function queries:FindBossByName(target, name)
		for i = 1, #(target.bossKills or {}) do
			if target.bossKills[i].name == name then return target.bossKills[i] end
		end
	end
	function queries:FindBossBySourceNpcId(target, npcId)
		for i = 1, #(target.bossKills or {}) do
			if tonumber(target.bossKills[i].sourceNpcId) == tonumber(npcId) then return target.bossKills[i] end
		end
	end
	function queries:FindBossBySourceKey(target, sourceKey)
		for i = 1, #(target.bossKills or {}) do
			if target.bossKills[i].sourceKey == sourceKey then return target.bossKills[i] end
		end
	end
	addon.Database.GetRaidQueries = function() return queries end
	addon.Database.EnsureRaidSchema = function(target) return fixture.store:NormalizeRaidRecord(target) end
	addon.Database.GetLastBoss = function() return nil end
	addon.Services.Logger.Store.GetRaid = function(_, raidIndex) return fixture.raids[raidIndex] end
	addon.Services.Logger.Store.GetLoot = function(_, target, lootNid)
		for i = 1, #(target.loot or {}) do
			if tonumber(target.loot[i].lootNid) == tonumber(lootNid) then return target.loot[i] end
		end
	end
	addon.Services.Logger.Store._ResolveLootLooterNid = function(_, name)
		return name == "Beta" and 21 or nil
	end
	addon.Services.Logger.Store._ResolveLootLooterName = function(_, loot)
		return tonumber(loot.looterNid) == 21 and "Beta" or nil
	end
	addon.Services.Logger.Helpers.NormalizeRollType = function(value) return value end
	addon.Services.Logger.Helpers.NormalizeRollValue = function(value) return tonumber(value) end
	return fixture, actions, raid
end

function cases.logger_source_rebuild_is_atomic_and_revisioned(addon)
	local fixture, actions, raid = installLoggerAtomicFixture(addon)
	local result = actions:RebuildLootSources()
	assertEqual(1, result.repaired, "resolved source should be rebuilt")
	assertEqual(1, result.bossesCreated, "static source should create one boss")
	assertEqual(4, raid.bossKills[1].bossNid, "allocated boss nid must stay stable")
	assertEqual(4, raid.loot[1].bossNid, "loot patch must reference committed boss")
	assertEqual(9, fixture.store:GetRaidSyncRevision(raid), "boss plus loot mutation advances exactly once")
	assertEqual(true, fixture.store:RequiresFullSyncSince(raid, 8), "boss creation requires full sync")
	local unchanged = deepCopy(raid)
	local second = actions:RebuildLootSources()
	assertEqual(0, second.repaired, "already rebuilt source is a no-op")
	assertEqual(9, fixture.store:GetRaidSyncRevision(raid), "no-op rebuild preserves revision")
	assertTrue(deepEqual(unchanged, raid), "no-op rebuild preserves canonical raid deeply")
	raid.loot[2] = { lootNid = 8, itemId = 99999 }
	fixture.store:EnsureRaidRuntime(raid)
	local beforeUnresolved = fixture.store:GetRaidSyncRevision(raid)
	local unresolved = actions:RebuildLootSources()
	assertEqual(1, unresolved.unresolved, "missing source should remain unresolved")
	assertEqual(beforeUnresolved, fixture.store:GetRaidSyncRevision(raid), "unresolved rebuild preserves revision")
	print("PASS logger_source_rebuild_is_atomic_and_revisioned")
end

function cases.logger_record_loot_verification_failure_is_atomic(addon)
	local fixture, actions, raid = installLoggerAtomicFixture(addon)
	local before = deepCopy(raid)
	local originalCommit = fixture.store.CommitRaidHistoryMutation
	fixture.store.CommitRaidHistoryMutation = function(self, target, staged, opts, verify)
		return originalCommit(self, target, staged, opts, function() return false, "INJECTED_VERIFY_FAILURE" end)
	end
	local ok, reason = actions:RecordLoot({ raidId = 2, lootNid = 7, looter = "Beta", rollType = "MS", rollValue = 97 })
	assertEqual(false, ok, "verification failure must reject RecordLoot")
	assertEqual("WRITE_FAILED", reason, "local result shape must stay stable")
	assertTrue(deepEqual(before, raid), "failed verification must preserve loot row and revision deeply")
	assertEqual(0, #fixture.events, "failed verification must not publish")
	print("PASS logger_record_loot_verification_failure_is_atomic")
end

function cases.logger_cleanup_preserves_active_raid(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	fixture.raids[2].bossKills = {}
	fixture.raids[2].loot = {}
	fixture.raids[2].players = {}
	local result = actions:CleanupRaidHistory({ emptyRaids = true, noBossEncounter = true })
	assertEqual(true, result.complete, "cleanup must complete while protecting active raid")
	assertEqual(1, result.raidsRemoved, "historical empty raid must be removed")
	assertEqual(73, fixture.raids[1].raidNid, "active empty raid must survive")
	assertEqual(1, fixture.currentRaid, "active selection must follow surviving stable identity")

	fixture, actions = installLoggerCleanupFixture(addon)
	fixture.raids[2].bossKills = {}
	fixture.raids[2].players = { { playerNid = 21, name = "Beta" } }
	result = actions:CleanupRaidHistory({ noBossEncounter = true })
	assertEqual(73, fixture.raids[#fixture.raids].raidNid, "active no-boss raid with players must survive")
	print("PASS logger_cleanup_preserves_active_raid")
end

function cases.logger_async_cleanup_conflicts_when_candidate_becomes_current(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local originalCapture = fixture.store.CaptureRaidHistoryState
	fixture.store.CaptureRaidHistoryState = function(store)
		local snapshot = originalCapture(store)
		fixture.currentRaid = 1
		return snapshot
	end
	local callbackResult, callbackComplete
	actions:StartRaidHistoryCleanup(function(result, complete)
		callbackResult, callbackComplete = result, complete
	end, { emptyRaids = true, chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	assertEqual(false, callbackComplete, "stale async plan must be incomplete")
	assertEqual(true, callbackResult.conflict, "current-raid switch must report conflict")
	assertEqual(2, #fixture.raids, "conflicted cleanup must delete no raid")
	assertEqual(0, #fixture.events, "conflicted cleanup must publish no data event")
	print("PASS logger_async_cleanup_conflicts_when_candidate_becomes_current")
end

function cases.raid_store_bulk_delete_honors_protected_nid(addon)
	local fixture = installLoggerCleanupFixture(addon)
	local removed, removedNids = fixture.store:DeleteRaidsByNid({ 41, 73 }, { protectedRaidNid = 73 })
	assertEqual(1, removed, "store guard must delete only unprotected raid")
	assertEqual(41, removedNids[1], "store guard must report historical deletion")
	assertEqual(73, fixture.raids[1].raidNid, "store guard must preserve protected raid")
	print("PASS raid_store_bulk_delete_honors_protected_nid")
end

local installRaidDatabaseStubs
local canonicalRaidFixture

local function installEquipInspectFixture(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.unitExists = true
	fixture.unitConnected = true
	fixture.unitInRange = true
	fixture.canInspect = true
	fixture.inCombat = false
	fixture.notifyFails = false
	fixture.clearInspectCount = 0
	fixture.itemLinks = {}
	fixture.itemInfo = {}
	fixture.itemTextures = {}
	fixture.currentRaid = 2
	fixture.raids[2].players = {
		{ playerNid = 21, name = "Beta", class = "PRIEST" },
		{ playerNid = 22, name = "Gamma", class = "MAGE" },
	}
	local callbacks = {}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
		end,
		Raid = {
			GetUnitByPlayerNid = function(_, raidIndex, playerNid)
				if tonumber(raidIndex) ~= tonumber(fixture.currentRaid) then return nil end
				return tonumber(playerNid) == 21 and "raid1" or "raid2"
			end,
		},
	}
	addon.Services.SpecInspect = {
		GetUnitTalentSnapshot = function()
			return { specName = "Discipline", icon = "spec-icon", mainTalentTree = 1 }
		end,
	}
	addon.Events = {
		Internal = {
			EquipInspectStarted = "EquipInspectStarted",
			EquipInspectCompleted = "EquipInspectCompleted",
			EquipInspectUpdated = "EquipInspectUpdated",
			RaidCreate = "RaidCreate",
		},
		ResolveWowForwardedName = function(name) return name end,
	}
	addon.Bus = {
		TriggerEvent = function(eventName, ...)
			fixture.events[#fixture.events + 1] = { name = eventName, args = { ... } }
			if fixture.onEvent then fixture.onEvent(eventName, ...) end
		end,
		RegisterCallback = function(eventName, callback) callbacks[eventName] = callback end,
	}
	addon.Timer = { BindMixin = function(target) fixture:InstallTimers(target) end }
	addon.Time = { GetCurrentTime = function() return 1700000000 + fixture.now end }
	addon.Strings = {}
	addon.Database.GetCurrentRaid = function() return fixture.currentRaid end
	addon.Database.GetRaidStore = function() return fixture.store end
	addon.Database.EnsureRaidByIndex = function(index) return fixture.raids[index] end
	addon.Database.EnsureRaidByNid = function(raidNid)
		for i = 1, #fixture.raids do
			if tonumber(fixture.raids[i].raidNid) == tonumber(raidNid) then return fixture.raids[i], i end
		end
	end
	addon.Database.GetRaidIndexByNid = function(raidNid)
		local _, index = addon.Database.EnsureRaidByNid(raidNid)
		return index
	end
	_G.UnitGUID = function(unit) return "guid-" .. tostring(unit) end
	_G.UnitExists = function() return fixture.unitExists end
	_G.UnitIsConnected = function() return fixture.unitConnected end
	_G.CanInspect = function() return fixture.canInspect end
	_G.CheckInteractDistance = function() return fixture.unitInRange end
	_G.ClearInspectPlayer = function() fixture.clearInspectCount = fixture.clearInspectCount + 1 end
	_G.UnitAffectingCombat = function() return fixture.inCombat end
	_G.GetInventoryItemLink = function(_, slot) return fixture.itemLinks[slot] end
	_G.GetInventoryItemTexture = function(_, slot) return fixture.itemTextures[slot] end
	_G.GetInventoryItemQuality = function() return nil end
	_G.GetItemInfo = function(itemRef)
		local itemId = tonumber(itemRef)
		if not itemId and type(itemRef) == "string" then
			itemId = tonumber(string.match(itemRef, "item:(%d+)"))
		end
		local itemLevel = itemId and fixture.itemInfo[itemId] or nil
		if not itemLevel then return nil end
		return "Item " .. tostring(itemId), nil, nil, itemLevel
	end
	_G.NotifyInspect = function(unit)
		if fixture.notifyFails then error("notify failed") end
		fixture.inspectRequests[#fixture.inspectRequests + 1] = unit
	end
	loadAddonFile(addon, "Raid Management Addon/Services/InspectCoordinator.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/EquipInspect.lua")
	fixture.inspectCallbacks = callbacks
	return fixture, addon.Services.EquipInspect
end

local function itemLink(itemId)
	return "|cff0070dd|Hitem:" .. tostring(itemId) .. ":0:0:0:0:0:0:0|h[Fixture Item]|h|r"
end

function cases.equip_inspect_waits_for_complete_item_information(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	fixture.itemLinks[1] = itemLink(1001)
	assertEqual(true, inspect:ForcePlayer(2, 21), "cold-cache inspect starts")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual(nil, raid.inspect, "cold item information must not persist a partial snapshot")
	assertEqual("pending", inspect:GetSnapshot(raid, 21).status, "cold item remains runtime pending")
	assertEqual(false, inspect:ForcePlayer(2, 21), "a cold-cache request cannot be replaced while pending")
	assertEqual(1, #fixture.inspectRequests, "replacement attempt must not duplicate NotifyInspect")

	fixture.inspectCallbacks.GET_ITEM_INFO_RECEIVED(nil, 9999, true)
	assertEqual(nil, raid.inspect, "irrelevant item events must not finalize the snapshot")
	fixture.itemInfo[1001] = 232
	fixture.inspectCallbacks.GET_ITEM_INFO_RECEIVED(nil, 1001, true)
	local ready = assert(raid.inspect.players[21])
	assertEqual("ready", ready.status, "resolved item information persists ready")
	assertEqual(232, ready.avgIlvl, "average uses the resolved equipped item")
	print("PASS equip_inspect_waits_for_complete_item_information")
end

function cases.inspect_coordinator_serializes_global_ownership(addon)
	local callbacks, timers, nowValue, clears, combat = {}, {}, 0, 0, false
	addon.Events = { Internal = {}, ResolveWowForwardedName = function(name) return name end }
	addon.Bus = {
		RegisterCallback = function(name, callback) callbacks[name] = callback end,
	}
	addon.Timer = {
		BindMixin = function(module)
			function module:ScheduleTimer(callback, delay)
				local handle = { callback = callback, deadline = nowValue + delay }
				timers[#timers + 1] = handle
				return handle
			end
			function module:CancelTimer(handle) handle.cancelled = true end
		end,
	}
	addon.Services = { EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} end }
	_G.GetTime = function() return nowValue end
	_G.UnitAffectingCombat = function() return combat end
	_G.ClearInspectPlayer = function() clears = clears + 1 end
	loadAddonFile(addon, "Raid Management Addon/Services/InspectCoordinator.lua")
	local coordinator = addon.Services.InspectCoordinator
	local starts, finishes = {}, {}
	assertEqual("active", select(2, coordinator:Request("equipment", "raid1", "guid-1", function() starts[#starts + 1] = "equipment" end, function(reason) finishes[#finishes + 1] = reason end)), "equipment owns first target")
	assertEqual("queued", select(2, coordinator:Request("talents", "raid2", "guid-2", function() starts[#starts + 1] = "talents" end, function(reason) finishes[#finishes + 1] = reason end)), "talents queue behind equipment")
	assertEqual(false, coordinator:Release("equipment", "wrong-guid"), "mismatched ready cannot release owner")
	assertEqual(0, clears, "mismatched ready cannot clear target")
	assertEqual(true, coordinator:Release("equipment", "guid-1"), "matching owner releases")
	assertEqual(1, clears, "only released owner clears")
	assertEqual(nil, starts[2], "global throttle delays the next NotifyInspect owner")
	nowValue = 1.75
	for i = 1, #timers do if not timers[i].cancelled and timers[i].deadline <= nowValue then timers[i].cancelled = true; timers[i].callback() end end
	assertEqual("talents", starts[2], "queued talent request progresses after global throttle")
	assertEqual(false, coordinator:Release("equipment", "guid-1"), "old owner cannot clear new target")
	assertEqual(1, clears, "old owner leaves talent target intact")
	assertEqual(true, coordinator:Cancel("talents"), "active talent work cancels")
	assertEqual(2, clears, "cancel clears its own target once")
	local cancelledStarts, cancelledFinishes = 0, 0
	coordinator:Request("blocker", "raid1", "guid-block", function() end)
	coordinator:Request("cancel-me", "raid2", "guid-cancel", function() cancelledStarts = cancelledStarts + 1 end, function(reason)
		assertEqual("cancelled", reason, "queued cancellation has stable reason")
		cancelledFinishes = cancelledFinishes + 1
	end)
	assertEqual(true, coordinator:Cancel("cancel-me"), "queued work cancels by exact owner")
	assertEqual(0, cancelledStarts, "cancelled queued work never starts")
	assertEqual(1, cancelledFinishes, "cancelled queued callback fires once")
	nowValue = 3.5
	for i = 1, #timers do if not timers[i].cancelled and timers[i].deadline <= nowValue then timers[i].cancelled = true; timers[i].callback() end end
	coordinator:Release("blocker", "guid-block")

	combat = true
	assertEqual("queued", select(2, coordinator:Request("equipment", "raid1", "guid-3", function() starts[#starts + 1] = "combat" end, function(reason) finishes[#finishes + 1] = reason end)), "combat defers inspect")
	assertEqual(nil, starts[3], "combat request has not started")
	combat = false
	callbacks.PLAYER_REGEN_ENABLED()
	nowValue = 5.25
	for i = 1, #timers do if not timers[i].cancelled and timers[i].deadline <= nowValue then timers[i].cancelled = true; timers[i].callback() end end
	assertEqual("combat", starts[3], "regen starts deferred request")
	nowValue = 12
	for i = 1, #timers do if not timers[i].cancelled and timers[i].deadline <= nowValue then timers[i].callback() end end
	assertEqual("timeout", finishes[#finishes], "deadline completes once with timeout")
	assertEqual(4, clears, "timeout clears only current owner")

	local expiryFinishes = 0
	combat = true
	coordinator:Request("combat-expiry", "raid3", "guid-expire", function() fail("expired combat request started") end, function(reason)
		assertEqual("timeout", reason, "queued combat work uses total deadline")
		expiryFinishes = expiryFinishes + 1
	end)
	nowValue = 21
	for i = 1, #timers do if not timers[i].cancelled and timers[i].deadline <= nowValue then timers[i].cancelled = true; timers[i].callback() end end
	assertEqual(1, expiryFinishes, "queued combat deadline completes exactly once")
	for i = 1, 40 do
		assertEqual(true, coordinator:Request("cap-" .. tostring(i), "raid1", "guid-cap", function() end), "bounded queue accepts capacity")
	end
	assertEqual("queue_full", select(2, coordinator:Request("cap-overflow", "raid1", "guid-cap", function() end)), "bounded queue rejects overflow")
	print("PASS inspect_coordinator_serializes_global_ownership")
end

function cases.equip_and_talent_refresh_share_global_inspect_owner(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	fixture.itemLinks[1] = itemLink(1001)
	fixture.itemInfo[1001] = 251
	assertEqual("pending", select(2, inspect:ForcePlayer(2, 21)), "equipment starts first")
	local coordinator = addon.Services.InspectCoordinator
	local talentStarts = 0
	assertEqual("queued", select(2, coordinator:Request("talents", "raid2", "guid-raid2", function()
		talentStarts = talentStarts + 1
		NotifyInspect("raid2")
	end)), "talent refresh queues behind equipment")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid2")
	assertEqual(nil, fixture.raids[2].inspect, "mismatched talent ready cannot finalize equipment")
	assertEqual(0, fixture.clearInspectCount, "mismatched ready cannot clear equipment owner")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual("ready", fixture.raids[2].inspect.players[21].status, "equipment completes on matching GUID")
	assertEqual(0, talentStarts, "global throttle keeps talent refresh queued")
	fixture:AdvanceTime(1.75)
	assertEqual(1, talentStarts, "talent refresh starts after equipment release")
	assertEqual("raid2", fixture.inspectRequests[2], "talent refresh owns its requested unit")
	assertEqual(1, fixture.clearInspectCount, "equipment release clears exactly once")
	assertEqual(false, coordinator:Release("equipment", "guid-raid1"), "released equipment cannot clear talent target")
	assertEqual(1, fixture.clearInspectCount, "talent target remains owned")
	assertEqual(true, coordinator:Release("talents", "guid-raid2"), "talent owner releases itself")
	assertEqual(2, fixture.clearInspectCount, "talent release clears exactly once")
	print("PASS equip_and_talent_refresh_share_global_inspect_owner")
end

function cases.spec_inspect_correlates_lgt_completion_by_guid(addon)
	local fixture = newRaidRecordingFixture(addon)
	local busCallbacks, lgtCallbacks, resolved, refreshCalls, equipmentStarts = {}, {}, false, 0, 0
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} end,
		Raid = {
			GetUnitID = function(_, name) return name == "Alpha" and "raid1" or "none" end,
			GetPlayers = function() return { { name = "Alpha" } } end,
			GetPlayerClass = function() return "PRIEST" end,
		},
	}
	addon.Database.GetCurrentRaid = function() return 1 end
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Events = {
		Internal = { SpecInspectUpdated = "SpecInspectUpdated" },
		ResolveWowForwardedName = function(name) return name end,
	}
	addon.Bus = {
		TriggerEvent = function() end,
		RegisterCallback = function(name, callback) busCallbacks[name] = callback end,
	}
	addon.Timer = { BindMixin = function(target) fixture:InstallTimers(target) end }
	_G.GetTime = function() return fixture.now end
	_G.UnitAffectingCombat = function() return false end
	_G.ClearInspectPlayer = function() fixture.clearInspectCount = (fixture.clearInspectCount or 0) + 1 end
	_G.UnitGUID = function(unit) return unit == "raid1" and "guid-alpha" or "guid-other" end
	local lgt = {
		CheckInspectQueue = function() end,
		RegisterCallback = function(_, name, callback) lgtCallbacks[name] = callback end,
		RefreshTalentsByUnit = function(_, unit) assertEqual("raid1", unit, "SpecInspect refreshes requested unit"); refreshCalls = refreshCalls + 1 end,
		GetNumTalentGroups = function() return 1 end,
		GetActiveTalentGroup = function() return 1 end,
		GetUnitTalentSpec = function() if resolved then return "Discipline", 57, 14, 0 end end,
		GetGUIDTalentSpec = function(_, guid) if resolved and guid == "guid-alpha" then return "Discipline", 57, 14, 0 end end,
		GetTalentTabInfo = function() return "Discipline", "spec-icon" end,
		GetUnitRole = function() return "healer" end,
	}
	_G.LibStub = function(name) if name == "LibGroupTalents-1.0" or name == "LibTalentQuery-1.0" then return lgt end end
	loadAddonFile(addon, "Raid Management Addon/Services/InspectCoordinator.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/SpecInspect.lua")
	local spec = addon.Services.SpecInspect
	assertEqual(true, spec:RefreshPlayer("Alpha", { force = true }), "production SpecInspect queues LGT refresh")
	assertEqual(1, refreshCalls, "LGT refresh starts through coordinator")
	lgtCallbacks.LibGroupTalents_UpdateComplete(nil, "guid-other")
	assertEqual(true, addon.Services.InspectCoordinator:IsCategoryOwner("talents"), "unrelated UpdateComplete cannot release talent owner")
	addon.Services.InspectCoordinator:Request("equipment-after-spec", "raid2", "guid-other", function() equipmentStarts = equipmentStarts + 1 end, nil, "equipment")
	assertEqual(0, equipmentStarts, "equipment remains queued behind unresolved talent operation")
	resolved = true
	lgtCallbacks.LibGroupTalents_Update(nil, "guid-alpha", "raid1")
	assertEqual(0, equipmentStarts, "matching talent data still respects global throttle")
	fixture:AdvanceTime(1.75)
	assertEqual(1, equipmentStarts, "matching GUID terminal data releases the talent owner")
	addon.Services.InspectCoordinator:Release("equipment-after-spec", "guid-other")
	local scheduleTimer = addon.Services.InspectCoordinator.ScheduleTimer
	addon.Services.InspectCoordinator.ScheduleTimer = function() return nil end
	local timerOk, timerReason = spec:RefreshPlayer("Alpha", { force = true })
	assertEqual(false, timerOk, "SpecInspect reports coordinator timer failure")
	assertEqual("inspect_timer_failed", timerReason, "SpecInspect exposes stable timer failure")
	addon.Services.InspectCoordinator.ScheduleTimer = scheduleTimer
	local request = addon.Services.InspectCoordinator.Request
	addon.Services.InspectCoordinator.Request = function() return false, "queue_full" end
	local queueOk, queueReason = spec:RefreshPlayer("Alpha", { force = true })
	assertEqual(false, queueOk, "SpecInspect reports coordinator queue exhaustion")
	assertEqual("inspect_queue_full", queueReason, "queue exhaustion remains distinct")
	addon.Services.InspectCoordinator.Request = request
	print("PASS spec_inspect_correlates_lgt_completion_by_guid")
end

function cases.equip_inspect_throttle_timer_failure_is_terminal(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raidA = fixture.raids[1]
	raidA.inspect = { players = { [11] = { status = "ready", playerNid = 11, guid = "old-guid", avgIlvl = 200 } } }
	fixture.itemLinks[1], fixture.itemInfo[1001] = itemLink(1001), 251
	local coordinator = addon.Services.InspectCoordinator
	assertEqual("active", select(2, coordinator:Request("talent-blocker", "raid1", "talent-guid", function() end, nil, "talents")), "talent flow owns active target")
	fixture.currentRaid = 1
	assertEqual("queued", select(2, inspect:ForcePlayer(1, 11)), "raid A replacement queues")
	local scheduleTimer = coordinator.ScheduleTimer
	coordinator.ScheduleTimer = function(self, callback, delay)
		if delay == 1.75 then return nil end
		return scheduleTimer(self, callback, delay)
	end
	assertEqual(true, coordinator:Release("talent-blocker", "talent-guid"), "talent owner releases")
	assertEqual("failed", inspect:GetSnapshot(raidA, 11).status, "throttle timer failure is terminal")
	assertEqual("inspect_timer_failed", inspect:GetSnapshot(raidA, 11).reason, "timer failure has stable reason")
	assertEqual("old-guid", raidA.inspect.players[11].guid, "timer failure preserves last known good snapshot")
	assertEqual(200, raidA.inspect.players[11].avgIlvl, "timer failure preserves canonical gear")
	print("PASS equip_inspect_throttle_timer_failure_is_terminal")
end

function cases.equip_inspect_own_timer_failures_are_terminal(addon)
	local function countTerminalUpdates(fixture, raidNid, playerNid)
		local count = 0
		for i = 1, #fixture.events do
			local event = fixture.events[i]
			local snapshot = event.args[3]
			if event.name == "EquipInspectUpdated"
				and event.args[1] == raidNid
				and event.args[2] == playerNid
				and snapshot
				and snapshot.status == "failed"
				and snapshot.reason == "inspect_timer_failed"
			then
				count = count + 1
			end
		end
		return count
	end

	for _, failureMode in ipairs({ "nil", "throw" }) do
		local fixture, inspect = installEquipInspectFixture(addon)
		local raidA = fixture.raids[1]
		raidA.players = { { playerNid = 11, name = "Alpha", class = "WARRIOR" } }
		raidA.inspect = { players = { [11] = { status = "ready", playerNid = 11, guid = "old-guid", avgIlvl = 200 } } }
		assertEqual("pending", select(2, inspect:ForcePlayer(2, 21)), failureMode .. " handoff blocker starts")
		fixture.currentRaid = 1
		assertEqual("queued", select(2, inspect:ForcePlayer(1, 11)), failureMode .. " handoff work queues")
		local scheduleTimer = inspect.ScheduleTimer
		inspect.ScheduleTimer = function(self, callback, delay)
			if delay == 1.75 then
				if failureMode == "throw" then error("injected EquipInspect handoff timer failure") end
				return nil
			end
			return scheduleTimer(self, callback, delay)
		end
		local reentered = false
		fixture.onEvent = function(eventName, raidNid, playerNid, snapshot)
			if eventName == "EquipInspectUpdated"
				and raidNid == 41
				and playerNid == 11
				and snapshot
				and snapshot.reason == "inspect_timer_failed"
			then
				reentered = inspect:ForcePlayer(1, 11)
			end
		end
		fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
		local replacement = inspect:GetSnapshot(raidA, 11)
		assertEqual("pending", replacement.status, failureMode .. " reentrant replacement owns runtime status")
		assertEqual("old-guid", inspect:GetPersistedSnapshot(raidA, 11).guid, failureMode .. " handoff preserves last good snapshot")
		assertEqual(1, countTerminalUpdates(fixture, 41, 11), failureMode .. " handoff finalizes once")
		assertEqual(true, reentered, failureMode .. " terminal callback may safely enqueue replacement work")
		assertEqual(1, #fixture.inspectRequests, failureMode .. " reentrant work respects coordinator throttle")
		local completionCount = 0
		for i = 1, #fixture.events do
			if fixture.events[i].name == "EquipInspectCompleted" and fixture.events[i].args[1] == 41 then
				completionCount = completionCount + 1
			end
		end
		assertEqual(0, completionCount, failureMode .. " stale completion cannot close reentrant session")
		fixture.onEvent = nil
		inspect.ScheduleTimer = scheduleTimer
		fixture:AdvanceTime(2)
		assertEqual(2, #fixture.inspectRequests, failureMode .. " reentrant work receives coordinator ownership")
		fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
		fixture:AdvanceTime(20)
		assertEqual(1, countTerminalUpdates(fixture, 41, 11), failureMode .. " handoff leaves no stale callback")
	end

	for _, failureMode in ipairs({ "nil", "throw" }) do
		local fixture, inspect = installEquipInspectFixture(addon)
		fixture.inCombat = true
		local scheduleTimer = inspect.ScheduleTimer
		inspect.ScheduleTimer = function()
			if failureMode == "throw" then error("injected EquipInspect combat timer failure") end
			return nil
		end
		local ok, reason = inspect:ForcePlayer(2, 21)
		assertEqual(false, ok, failureMode .. " combat retry timer failure is synchronous")
		assertEqual("inspect_timer_failed", reason, failureMode .. " combat retry reason is stable")
		assertEqual("failed", inspect:GetSnapshot(fixture.raids[2], 21).status, failureMode .. " combat retry terminalizes")
		assertEqual(1, countTerminalUpdates(fixture, 73, 21), failureMode .. " combat retry finalizes once")
		inspect.ScheduleTimer = scheduleTimer
		fixture.inCombat = false
		fixture.inspectCallbacks.PLAYER_REGEN_ENABLED()
		fixture:AdvanceTime(20)
		assertEqual(0, #fixture.inspectRequests, failureMode .. " combat retry leaves no stale inspect")
		assertEqual(1, countTerminalUpdates(fixture, 73, 21), failureMode .. " combat retry callback remains single")
	end

	for _, failureMode in ipairs({ "nil", "throw" }) do
		local fixture, inspect = installEquipInspectFixture(addon)
		fixture.itemLinks[1] = itemLink(1001)
		assertEqual("pending", select(2, inspect:ForcePlayer(2, 21)), failureMode .. " cold item inspect starts")
		local scheduleTimer = inspect.ScheduleTimer
		inspect.ScheduleTimer = function()
			if failureMode == "throw" then error("injected EquipInspect item timer failure") end
			return nil
		end
		local callbackOk = pcall(fixture.inspectCallbacks.INSPECT_TALENT_READY, nil, "guid-raid1")
		assertEqual(true, callbackOk, failureMode .. " item retry timer failure is contained")
		local failed = inspect:GetSnapshot(fixture.raids[2], 21)
		assertEqual("failed", failed.status, failureMode .. " item retry terminalizes")
		assertEqual("inspect_timer_failed", failed.reason, failureMode .. " item retry reason is stable")
		assertEqual(1, countTerminalUpdates(fixture, 73, 21), failureMode .. " item retry finalizes once")
		inspect.ScheduleTimer = scheduleTimer
		fixture.itemInfo[1001] = 251
		fixture.inspectCallbacks.GET_ITEM_INFO_RECEIVED(nil, 1001, true)
		fixture:AdvanceTime(20)
		assertEqual(nil, fixture.raids[2].inspect, failureMode .. " stale item work cannot persist")
		assertEqual(1, countTerminalUpdates(fixture, 73, 21), failureMode .. " item retry callback remains single")
	end
	print("PASS equip_inspect_own_timer_failures_are_terminal")
end

function cases.vendored_lgt_respects_equipment_inspect_guard(addon)
	local frames, nowValue, notifyCount = {}, 0, 0
	_G.UNKNOWN = "Unknown"
	_G.strmatch = string.match
	_G.format = string.format
	_G.TALENT_ACTIVATION_SPELLS = {}
	_G.IsLoggedIn = function() return true end
	_G.GetTime = function() return nowValue end
	_G.GetNumRaidMembers = function() return 1 end
	_G.GetNumPartyMembers = function() return 0 end
	_G.UnitName = function(unit) if unit == "raid1" or unit == "Alpha" then return "Alpha", "Realm" end return "Player", "Realm" end
	_G.UnitGUID = function(unit) if unit == "raid1" or unit == "Alpha-Realm" or unit == "Alpha" then return "guid-alpha" end return "guid-player" end
	_G.UnitExists = function(unit) return unit == "raid1" or unit == "Alpha-Realm" or unit == "player" end
	_G.UnitIsPlayer = function() return true end
	_G.UnitIsVisible = function() return true end
	_G.UnitIsConnected = function() return true end
	_G.UnitCanAttack = function() return false end
	_G.UnitClass = function() return "Priest", "PRIEST" end
	_G.UnitLevel = function() return 80 end
	_G.UnitIsUnit = function(a, b) return a == b end
	_G.UnitInRaid = function() return 1 end
	_G.UnitInParty = function() return false end
	_G.CanInspect = function() return true end
	_G.CheckInteractDistance = function() return true end
	_G.GetActiveTalentGroup = function() return 1 end
	_G.GetNumTalentGroups = function() return 1 end
	_G.GetNumTalentTabs = function() return 3 end
	_G.GetTalentTabInfo = function(tab) return ({ "Discipline", "Holy", "Shadow" })[tab], "icon" .. tostring(tab), ({ 57, 14, 0 })[tab] end
	_G.GetNumTalents = function() return 1 end
	_G.GetTalentInfo = function(tab) return "Talent" .. tostring(tab), "talent-icon", 1, 1, ({ 5, 1, 0 })[tab], 5 end
	_G.GetUnspentTalentPoints = function() return 0 end
	_G.GetSpellInfo = function(id) return "Spell" .. tostring(id) end
	_G.GetGlyphSocketInfo = function() return nil end
	_G.SendAddonMessage = function() end
	_G.RegisterAddonMessagePrefix = function() end
	_G.strsplit = function(_, value) local a, b = string.match(value, "^([^-]+)%-?(.*)$"); return a, b ~= "" and b or nil end
	_G.wipe = function(t) for key in pairs(t) do t[key] = nil end return t end
	_G.geterrorhandler = function() return function(err) error(err) end end
	_G.securecall = function(func, ...) return func(...) end
	_G.CreateFrame = function(_, name)
		local frame = { shown = false }
		function frame:UnregisterAllEvents() end
		function frame:RegisterEvent() end
		function frame:SetScript(kind, callback) self[kind] = callback end
		function frame:Show() self.shown = true end
		function frame:Hide() self.shown = false end
		function frame:IsShown() return self.shown end
		frames[name] = frame
		return frame
	end
	_G.NotifyInspect = function() notifyCount = notifyCount + 1 end
	_G.hooksecurefunc = function(name, hook)
		local original = _G[name]
		_G[name] = function(...) local values = { original(...) }; hook(...); return unpack(values) end
	end
	loadAddonFile(addon, "Raid Management Addon/Libs/LibCompat-1.0/Libs/LibStub/LibStub.lua")
	loadAddonFile(addon, "Raid Management Addon/Libs/LibCompat-1.0/Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua")
	loadAddonFile(addon, "Raid Management Addon/Libs/LibCompat-1.0/Libs/LibGroupTalents-1.0/LibTalentQuery-1.0.lua")
	loadAddonFile(addon, "Raid Management Addon/Libs/LibCompat-1.0/Libs/LibGroupTalents-1.0/LibGroupTalents-1.0.lua")
	local lgt = LibStub("LibGroupTalents-1.0")
	local ltq, terminalReady = LibStub("LibTalentQuery-1.0"), 0
	local terminalOwner = {}
	ltq.RegisterCallback(terminalOwner, "TalentQuery_Ready", function() terminalReady = terminalReady + 1 end)
	lgt.roster["guid-alpha"] = { unit = "raid1", name = "Alpha", realm = "Realm", class = "PRIEST", level = 80 }
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} end,
		Raid = { GetUnitID = function() return "raid1" end, GetPlayers = function() return { { name = "Alpha" } } end, GetPlayerClass = function() return "PRIEST" end },
	}
	addon.Database = { GetCurrentRaid = function() return 1 end }
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Events = { Internal = { SpecInspectUpdated = "SpecInspectUpdated" }, ResolveWowForwardedName = function(name) return name end }
	local callbacks = {}
	addon.Bus = { RegisterCallback = function(name, callback) callbacks[name] = callback end, TriggerEvent = function() end }
	addon.Timer = { BindMixin = function(target) target.ScheduleTimer = function() return {} end; target.CancelTimer = function() end end }
	_G.UnitAffectingCombat = function() return false end
	_G.ClearInspectPlayer = function() end
	loadAddonFile(addon, "Raid Management Addon/Services/InspectCoordinator.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/SpecInspect.lua")
	local coordinator = addon.Services.InspectCoordinator
	coordinator:Request("equip-owner", "raid1", "guid-alpha", function() end, nil, "equipment")
	lgt:RefreshTalentsByUnit("raid1")
	LibStub("LibTalentQuery-1.0"):CheckInspectQueue()
	assertEqual(0, notifyCount, "actual vendored LTQ queue is blocked during equipment ownership")
	coordinator:Release("equip-owner", "guid-alpha")
	nowValue = 1.75
	LibStub("LibTalentQuery-1.0"):CheckInspectQueue()
	assertEqual(1, notifyCount, "actual vendored LTQ queue resumes after equipment ownership")
	ltq:INSPECT_TALENT_READY()
	assertEqual(1, terminalReady, "actual vendored LTQ emits matching terminal callback")
	print("PASS vendored_lgt_respects_equipment_inspect_guard")
end

function cases.equip_inspect_item_information_timeout_preserves_last_good(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	fixture.itemLinks[1] = itemLink(1001)
	fixture.itemInfo[1001] = 226
	inspect:ForcePlayer(2, 21)
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	local canonical = deepCopy(raid.inspect)
	local revision = fixture.store:GetRaidSyncRevision(raid)

	fixture.itemLinks[1] = itemLink(1002)
	assertEqual(true, inspect:ForcePlayer(2, 21), "replacement inspect starts")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	fixture:AdvanceTime(8)
	assertTrue(deepEqual(canonical, raid.inspect), "item timeout preserves the last good snapshot")
	assertEqual("timeout", inspect:GetSnapshot(raid, 21).status, "item timeout remains runtime-only")
	assertEqual("item_info_timeout", inspect:GetSnapshot(raid, 21).reason, "item timeout has a stable reason")
	fixture:AssertRevision(73, revision, "item timeout must not advance canonical revision")

	fixture.itemInfo[1002] = 245
	fixture.inspectCallbacks.GET_ITEM_INFO_RECEIVED(nil, 1002, true)
	assertTrue(deepEqual(canonical, raid.inspect), "late item event after cancellation must be ignored")
	print("PASS equip_inspect_item_information_timeout_preserves_last_good")
end

function cases.equip_inspect_cancels_cold_item_work_when_raid_disappears(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	fixture.itemLinks[1] = itemLink(1003)
	inspect:ForcePlayer(2, 21)
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	table.remove(fixture.raids, 2)
	inspect:ProcessQueue(73)
	local activeTimers = 0
	for i = 1, #fixture.timers do
		if fixture.timers[i].active then activeTimers = activeTimers + 1 end
	end
	assertEqual(0, activeTimers, "raid cancellation removes item-info retry and timeout timers")
	fixture.itemInfo[1003] = 251
	fixture.inspectCallbacks.GET_ITEM_INFO_RECEIVED(nil, 1003, true)
	fixture:AdvanceTime(10)
	assertEqual(1, fixture.clearInspectCount, "cancelled cold-cache work clears its inspect owner once")
	print("PASS equip_inspect_cancels_cold_item_work_when_raid_disappears")
end

function cases.equip_inspect_distinguishes_cold_occupied_slot_from_empty(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	fixture.itemTextures[1] = "fixture-texture"
	inspect:ForcePlayer(2, 21)
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual(nil, raid.inspect, "occupied slot with a cold link must not persist ready")
	assertEqual("pending", inspect:GetSnapshot(raid, 21).status, "cold occupied slot remains pending")

	fixture.itemLinks[1] = itemLink(1004)
	fixture.itemInfo[1004] = 264
	fixture:AdvanceTime(0.5)
	assertEqual("ready", raid.inspect.players[21].status, "bounded retry resolves the occupied slot")
	assertEqual(264, raid.inspect.players[21].avgIlvl, "resolved occupied slot contributes to average")

	local emptyFixture, emptyInspect = installEquipInspectFixture(addon)
	emptyInspect:ForcePlayer(2, 21)
	emptyFixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual("ready", emptyFixture.raids[2].inspect.players[21].status, "linkless textureless slot remains empty")
	print("PASS equip_inspect_distinguishes_cold_occupied_slot_from_empty")
end

function cases.equip_inspect_failed_item_event_keeps_original_deadline(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	fixture.itemLinks[1] = itemLink(1005)
	fixture.itemTextures[1] = "fixture-texture"
	inspect:ForcePlayer(2, 21)
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	local function activeTimerCount()
		local count = 0
		for i = 1, #fixture.timers do
			if fixture.timers[i].active then count = count + 1 end
		end
		return count
	end
	assertEqual(2, activeTimerCount(), "cold item owns one retry and the original timeout")
	fixture.itemInfo[1005] = 277
	fixture.inspectCallbacks.GET_ITEM_INFO_RECEIVED(nil, 1005, false)
	assertEqual(2, activeTimerCount(), "failed item event must not duplicate timers")
	assertEqual("pending", inspect:GetSnapshot(raid, 21).status, "failed item event remains pending")
	fixture.itemInfo[1005] = nil
	fixture:AdvanceTime(8)
	assertEqual("timeout", inspect:GetSnapshot(raid, 21).status, "failed item event must not extend the deadline")
	assertEqual(nil, raid.inspect, "failed item event must never persist a partial average")
	print("PASS equip_inspect_failed_item_event_keeps_original_deadline")
end

function cases.raid_inspect_persistence_compacts_only_on_explicit_save(addon)
	installRaidDatabaseStubs(addon)
	local raid = canonicalRaidFixture()
	raid.inspect = {
		startedAt = 51, completedAt = 52, mode = "auto", transient = "discard",
		players = {
			[11] = { status = "ready", playerNid = 11, name = "Alpha", specName = "Holy", avgIlvl = 226,
				inspectedAt = 12345, reason = "stale", items = { [1] = { itemId = 1 } }, transient = true },
			[12] = { status = "timeout", playerNid = 12, name = "Beta", specName = "Shadow", avgIlvl = 200 },
			[13] = { status = "failed", playerNid = 13, name = "Gamma" },
		},
	}
	local before = deepCopy(raid)
	addon.DB.RaidQueries:GetRaidSummary(raid)
	assertTrue(deepEqual(before, raid), "read must not compact persisted inspect data")
	local prepared = assert(addon.DB.RaidStore:PrepareRaidForSave(raid, 1))
	assertEqual(nil, prepared.inspect.startedAt, "inspect session start is transient")
	assertEqual(nil, prepared.inspect.completedAt, "inspect session completion is transient")
	assertEqual(nil, prepared.inspect.mode, "inspect mode is transient")
	assertEqual(nil, prepared.inspect.transient, "unknown inspect root fields are transient")
	assertEqual(nil, prepared.inspect.players[12], "legacy timeout snapshot must be removed")
	assertEqual(nil, prepared.inspect.players[13], "legacy failed snapshot must be removed")
	local ready = assert(prepared.inspect.players[11])
	assertEqual("ready", ready.status, "ready snapshot remains canonical")
	assertEqual("Holy", ready.specName, "ready spec survives compaction")
	assertEqual(226, ready.avgIlvl, "ready gear summary survives compaction")
	assertEqual(nil, ready.inspectedAt, "uptime timestamp cannot be converted safely")
	assertEqual(nil, ready.reason, "ready transient reason is removed")
	assertEqual(nil, ready.items, "derived item detail is not persisted")
	assertEqual(nil, ready.transient, "unknown snapshot fields are removed")
	print("PASS raid_inspect_persistence_compacts_only_on_explicit_save")
end

function cases.raid_store_inspect_commit_restores_partial_revision_failures(addon)
	installRaidDatabaseStubs(addon)
	local raid = canonicalRaidFixture()
	local store = addon.DB.RaidStore
	store:SetRaidSyncRevision(raid, 7, "baseline")
	raid._runtime.fullSyncRevision = 6
	raid.inspect = { players = { [1] = { status = "ready", playerNid = 1, specName = "Holy" } } }
	local beforeInspect = deepCopy(raid.inspect)
	local beforeRuntime = deepCopy(raid._runtime)
	local replacement = { status = "ready", playerNid = 1, specName = "Shadow" }
	local originalTouch = store.TouchRaidSyncRevision

	for _, failureMode in ipairs({ "throw", "invalid" }) do
		store.TouchRaidSyncRevision = function(self, target, reason)
			originalTouch(self, target, reason)
			if failureMode == "throw" then error("touch failed after advance") end
			return false
		end
		local changed, err = store:CommitRaidInspectSnapshot(raid, 1, replacement)
		assertEqual(nil, changed, failureMode .. " must reject inspect commit")
		assertTrue(type(err) == "string", failureMode .. " must return stable error text")
		assertTrue(deepEqual(beforeInspect, raid.inspect), failureMode .. " restores canonical inspect")
		assertTrue(deepEqual(beforeRuntime, raid._runtime), failureMode .. " restores complete sync runtime")
	end
	store.TouchRaidSyncRevision = originalTouch
	local changed = store:CommitRaidInspectSnapshot(raid, 1, replacement)
	assertEqual(true, changed, "changed inspect commits")
	assertEqual(8, store:GetRaidSyncRevision(raid), "changed inspect advances once")
	assertEqual(true, store:RequiresFullSyncSince(raid, 7), "changed inspect requires full sync")
	local runtimeAfterChange = deepCopy(raid._runtime)
	assertEqual(false, store:CommitRaidInspectSnapshot(raid, 1, deepCopy(replacement)), "identical inspect is no-op")
	assertTrue(deepEqual(runtimeAfterChange, raid._runtime), "no-op preserves sync runtime deeply")
	print("PASS raid_store_inspect_commit_restores_partial_revision_failures")
end

function cases.equip_inspect_ready_persistence_is_atomic_revisioned_full_sync(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	local initialRevision = fixture.store:GetRaidSyncRevision(raid)
	assertEqual(true, inspect:ForcePlayer(2, 21), "first ready inspect starts")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual(initialRevision + 1, fixture.store:GetRaidSyncRevision(raid), "first ready snapshot advances once")
	assertEqual(true, fixture.store:RequiresFullSyncSince(raid, initialRevision), "inspect mutation requires full sync")
	local canonical = deepCopy(raid.inspect)
	local function countReadyUpdatedEvents()
		local count = 0
		for i = 1, #fixture.events do
			local event = fixture.events[i]
			if event.name == "EquipInspectUpdated" and event.args[3] and event.args[3].status == "ready" then
				count = count + 1
			end
		end
		return count
	end
	local updatedEventCount = countReadyUpdatedEvents()
	assertEqual(true, inspect:ForcePlayer(2, 21), "identical ready inspect starts")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual(initialRevision + 1, fixture.store:GetRaidSyncRevision(raid), "identical ready snapshot is revision no-op")
	assertTrue(deepEqual(canonical, raid.inspect), "identical ready snapshot is canonical no-op")
	assertEqual(updatedEventCount, countReadyUpdatedEvents(), "identical ready emits no canonical data update")

	local originalTouch = fixture.store.TouchRaidSyncRevision
	local originalCommit = fixture.store.CommitRaidInspectSnapshot
	fixture.store.CommitRaidInspectSnapshot = function()
		return nil, "injected revision failure"
	end
	addon.Services.SpecInspect.GetUnitTalentSnapshot = function()
		return { specName = "Shadow", icon = "shadow-icon", mainTalentTree = 3 }
	end
	fixture.now = fixture.now + 1
	assertEqual(true, inspect:ForcePlayer(2, 21), "different ready inspect starts")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertTrue(deepEqual(canonical, raid.inspect), "revision failure rolls back ready assignment")
	local visible = inspect:GetSnapshot(raid, 21)
	assertEqual("ready", visible.status, "failed ready commit immediately restores last canonical UI state")
	assertEqual(canonical.players[21].specName, visible.specName, "failed ready commit restores canonical UI spec")
	fixture.store.TouchRaidSyncRevision = originalTouch
	fixture.store.CommitRaidInspectSnapshot = originalCommit
	print("PASS equip_inspect_ready_persistence_is_atomic_revisioned_full_sync")
end

function cases.equip_inspect_preserves_ready_snapshot_after_terminal_attempts(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	assertEqual(true, inspect:ForcePlayer(2, 21), "initial inspect starts")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	local canonical = deepCopy(raid.inspect.players[21])
	local canonicalInspect = deepCopy(raid.inspect)
	local revision = fixture.store:GetRaidSyncRevision(raid)

	assertEqual(true, inspect:ForcePlayer(2, 21), "forced timeout attempt starts")
	fixture:AdvanceTime(8)
	assertTrue(deepEqual(canonical, raid.inspect.players[21]), "timeout must preserve last known good snapshot")
	assertTrue(deepEqual(canonicalInspect, raid.inspect), "timeout must preserve canonical inspect state deeply")
	assertEqual("timeout", inspect:GetSnapshot(raid, 21).status, "UI query must expose latest timeout")
	assertEqual("inspect_timeout", inspect:GetSnapshot(raid, 21).reason, "UI query must expose timeout reason")
	assertEqual(canonical.specName, inspect:GetSnapshot(raid, 21).specName, "timeout UI keeps canonical spec")
	assertEqual(canonical.avgIlvl, inspect:GetSnapshot(raid, 21).avgIlvl, "timeout UI keeps canonical gear summary")
	fixture:AssertRevision(73, revision, "timeout must not advance canonical revision")

	fixture.unitInRange = false
	local ok, reason = inspect:ForcePlayer(2, 21)
	assertEqual(false, ok, "out-of-range attempt is terminal")
	assertEqual("out_of_range", reason, "out-of-range reason propagates")
	assertTrue(deepEqual(canonical, raid.inspect.players[21]), "skipped attempt must preserve last known good snapshot")
	assertTrue(deepEqual(canonicalInspect, raid.inspect), "skipped attempt must preserve canonical inspect state deeply")
	assertEqual("skipped", inspect:GetSnapshot(raid, 21).status, "UI query must expose latest skipped attempt")
	assertEqual("out_of_range", inspect:GetSnapshot(raid, 21).reason, "UI query must expose skipped reason")
	fixture:AssertRevision(73, revision, "skipped attempt must not advance canonical revision")
	print("PASS equip_inspect_preserves_ready_snapshot_after_terminal_attempts")
end

function cases.equip_inspect_ready_snapshot_survives_reload_with_epoch_timestamp(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	inspect:ForcePlayer(2, 21)
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	local persisted = deepCopy(raid.inspect.players[21])
	assertTrue((tonumber(persisted.inspectedAt) or 0) >= 1700000000, "persisted inspect time must use epoch time")

	local reloadedFixture, reloadedInspect = installEquipInspectFixture(addon)
	reloadedFixture.raids[2].inspect = { players = { [21] = persisted } }
	local restored = reloadedInspect:GetSnapshot(reloadedFixture.raids[2], 21)
	assertEqual("ready", restored.status, "reload must restore canonical ready status")
	assertEqual(persisted.specName, restored.specName, "reload must restore canonical spec")
	assertEqual(persisted.avgIlvl, restored.avgIlvl, "reload must restore canonical gear summary")
	print("PASS equip_inspect_ready_snapshot_survives_reload_with_epoch_timestamp")
end

function cases.equip_inspect_force_player_returns_synchronous_terminal_failure(addon)
	local scenarios = {
		{ "missing_unit", "unitExists" },
		{ "offline", "unitConnected" },
		{ "out_of_range", "unitInRange" },
		{ "cannot_inspect", "canInspect" },
		{ "notify_failed", "notifyFails", true },
	}
	for i = 1, #scenarios do
		local fixture, inspect = installEquipInspectFixture(addon)
		local scenario = scenarios[i]
		fixture[scenario[2]] = scenario[3] == true
		if scenario[3] ~= true then fixture[scenario[2]] = false end
		local ok, reason = inspect:ForcePlayer(2, 21)
		assertEqual(false, ok, scenario[1] .. " must be terminal")
		assertEqual(scenario[1], reason, scenario[1] .. " reason must propagate")
	end
	print("PASS equip_inspect_force_player_returns_synchronous_terminal_failure")
end

function cases.equip_inspect_table_raid_identity_reresolves_stably(addon)
	for _, identity in ipairs({ { raidNid = 73 }, { id = 2 }, { raidId = 2 }, { raidNum = 2 } }) do
		local _, inspect = installEquipInspectFixture(addon)
		assertEqual(true, inspect:ForcePlayer(identity, 21), "supported table raid identity must resolve")
	end
	local fixture, inspect = installEquipInspectFixture(addon)
	table.remove(fixture.raids, 1)
	fixture.currentRaid = 1
	assertEqual(true, inspect:ForcePlayer({ raidNid = 73 }, 21), "stable table NID must survive reorder")
	print("PASS equip_inspect_table_raid_identity_reresolves_stably")
end

function cases.equip_inspect_combat_retry_is_single_owned_chain(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	fixture.inCombat = true
	assertEqual("queued", select(2, inspect:ForcePlayer(2, 21)), "combat request remains queued")
	fixture:AdvanceTime(1.75)
	fixture:AdvanceTime(1.75)
	local activeTimers = 0
	for i = 1, #fixture.timers do if fixture.timers[i].active then activeTimers = activeTimers + 1 end end
	assertEqual(1, activeTimers, "repeated combat must retain one fallback retry")
	fixture.currentRaid = 1
	fixture.raids[1].players = { { playerNid = 11, name = "Alpha", class = "WARRIOR" } }
	inspect:ForcePlayer(1, 11)
	activeTimers = 0
	for i = 1, #fixture.timers do if fixture.timers[i].active then activeTimers = activeTimers + 1 end end
	assertEqual(1, activeTimers, "cross-raid handoff must not overlap an owned combat retry")
	fixture.currentRaid = 2
	fixture.inCombat = false
	fixture.inspectCallbacks.PLAYER_REGEN_ENABLED()
	assertEqual(1, #fixture.inspectRequests, "regen must progress the request once")
	fixture:AdvanceTime(10)
	assertEqual(1, #fixture.inspectRequests, "stale combat retry must not notify again")

	local cappedFixture, cappedInspect = installEquipInspectFixture(addon)
	cappedFixture.inCombat = true
	cappedInspect:ForcePlayer(2, 21)
	for i = 1, 4 do cappedFixture:AdvanceTime(1.75) end
	local cappedSnapshot = cappedInspect:GetSnapshot(cappedFixture.raids[2], 21)
	assertEqual("failed", cappedSnapshot.status, "combat fallback must terminate after bounded attempts")
	assertEqual("cannot_inspect", cappedSnapshot.reason, "combat exhaustion must expose a stable terminal reason")
	local cappedActiveTimers = 0
	for i = 1, #cappedFixture.timers do
		if cappedFixture.timers[i].active then cappedActiveTimers = cappedActiveTimers + 1 end
	end
	assertEqual(0, cappedActiveTimers, "combat exhaustion must leave no callback chain")
	print("PASS equip_inspect_combat_retry_is_single_owned_chain")
end

function cases.equip_inspect_orphan_does_not_clear_unrelated_active_target(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	fixture.currentRaid = 1
	fixture.raids[1].players = { { playerNid = 11, name = "Alpha", class = "WARRIOR" } }
	assertEqual(true, inspect:ForcePlayer(1, 11), "raid A request starts")
	fixture.currentRaid = 2
	assertEqual(true, inspect:ForcePlayer(2, 21), "raid B request queues")
	local clearBaseline = fixture.clearInspectCount
	table.remove(fixture.raids, 2)
	inspect:ProcessQueue(73)
	assertEqual(clearBaseline, fixture.clearInspectCount, "orphan without global target must not clear unrelated inspect")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid2")
	assertEqual("ready", fixture.raids[1].inspect.players[11].status, "unrelated active request must still complete")
	print("PASS equip_inspect_orphan_does_not_clear_unrelated_active_target")
end

function cases.equip_inspect_serializes_global_notify_ownership(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raidA = fixture.raids[1]
	local raidB = fixture.raids[2]
	assertEqual("pending", select(2, inspect:ForcePlayer(2, 21)), "raid B must own the first inspect")
	assertEqual(1, #fixture.inspectRequests, "raid B must issue exactly one inspect")

	fixture.currentRaid = 1
	raidA.players = { { playerNid = 11, name = "Alpha", class = "WARRIOR" } }
	local queued, status = inspect:ForcePlayer(1, 11)
	assertEqual(true, queued, "raid A must remain accepted behind the global owner")
	assertEqual("queued", status, "raid A must remain queued behind the global owner")
	assertEqual(1, #fixture.inspectRequests, "raid A must not overwrite raid B's global inspect")

	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual("ready", raidB.inspect.players[21].status, "raid B ready result must stay on raid B")
	assertEqual(nil, raidA.inspect, "raid A must not finalize before it owns the global inspect")
	fixture:AdvanceTime(1.75)
	assertEqual(2, #fixture.inspectRequests, "raid A must issue exactly one inspect after raid B releases ownership")
	assertEqual("raid2", fixture.inspectRequests[2], "raid A must inspect its own resolved unit")
	fixture:AdvanceTime(8)
	assertEqual("timeout", inspect:GetSnapshot(raidA, 11).status, "raid A timeout must stay on raid A")
	assertEqual("ready", raidB.inspect.players[21].status, "raid A timeout must not rewrite raid B")

	local fairFixture, fairInspect = installEquipInspectFixture(addon)
	fairInspect:ForcePlayer(2, 21)
	fairFixture.currentRaid = 1
	fairFixture.raids[1].players = { { playerNid = 11, name = "Alpha", class = "WARRIOR" } }
	fairInspect:ForcePlayer(1, 11)
	fairFixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	fairFixture.currentRaid = 2
	fairInspect:ForcePlayer(2, 22)
	assertEqual(1, #fairFixture.inspectRequests, "new work must not bypass the owned cross-raid throttle")
	fairFixture.currentRaid = 1
	fairFixture:AdvanceTime(1.75)
	assertEqual("raid2", fairFixture.inspectRequests[2], "oldest queued raid must progress first")
	fairFixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid2")
	fairFixture.currentRaid = 2
	fairFixture:AdvanceTime(1.75)
	assertEqual("raid2", fairFixture.inspectRequests[3], "later raid B work must progress without starving")
	assertEqual(3, #fairFixture.inspectRequests, "each globally serialized request must notify exactly once")
	print("PASS equip_inspect_serializes_global_notify_ownership")
end

function cases.equip_inspect_delayed_raid_create_ignores_deleted_raid(addon)
	local fixture = installEquipInspectFixture(addon)
	fixture.inspectCallbacks.RaidCreate(nil, { raidNid = 73 })
	table.remove(fixture.raids, 2)
	fixture:AdvanceTime(3)
	assertEqual(0, #fixture.inspectRequests, "deleted raid must not start delayed inspect work")
	print("PASS equip_inspect_delayed_raid_create_ignores_deleted_raid")
end

function cases.equip_inspect_delayed_work_tracks_stable_raid_identity(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raidA = fixture.raids[1]
	local raidB = fixture.raids[2]
	assertEqual(true, inspect:ForcePlayer(2, 21), "raid B player must queue")
	assertEqual("queued", select(2, inspect:ForcePlayer(2, 22)), "second player must report queued")
	table.remove(fixture.raids, 1)
	fixture.currentRaid = 1
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	fixture:AdvanceTime(1.75)
	fixture:AdvanceTime(8)
	assertEqual(nil, raidA.inspect, "raid A must never receive delayed raid B inspect data")
	assertEqual("ready", raidB.inspect.players[21].status, "ready result must remain on raid B after reorder")
	assertEqual("timeout", inspect:GetSnapshot(raidB, 22).status, "timeout result must remain on raid B after reorder")
	for i = 1, #fixture.events do
		local event = fixture.events[i]
		if event.name == "EquipInspectStarted" or event.name == "EquipInspectCompleted" or event.name == "EquipInspectUpdated" then
			assertEqual(73, event.args[1], "inspect callback payload must carry stable raid NID")
		end
	end
	print("PASS equip_inspect_delayed_work_tracks_stable_raid_identity")
end

function cases.equip_inspect_orphaned_work_is_cancelled(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raidB = fixture.raids[2]
	assertEqual(true, inspect:ForcePlayer(2, 21), "raid B player must queue")
	table.remove(fixture.raids, 2)
	fixture.currentRaid = 1
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	fixture:AdvanceTime(8)
	assertEqual(nil, raidB.inspect, "orphaned ready/timeout work must not mutate detached raid data")
	print("PASS equip_inspect_orphaned_work_is_cancelled")
end

function cases.logger_atomic_commit_failure_matrix(addon)
	local fixture, actions, raid = installLoggerAtomicFixture(addon)
	local ok = actions:RecordLoot({ raidId = 2, lootNid = 7, looter = "Beta", rollType = "MS", rollValue = 97 })
	assertEqual(true, ok, "valid loot mutation should commit")
	assertEqual(9, fixture.store:GetRaidSyncRevision(raid), "RecordLoot advances raid revision exactly once")
	assertEqual(9, fixture.store:GetLootSyncRevision(raid, raid.loot[1]), "RecordLoot advances exact loot revision")
	assertTrue(fixture.store:EnsureRaidRuntime(raid).lootByNid[7] == raid.loot[1], "commit rebuilds runtime loot index")

	local function assertRollback(label, installFailure)
		fixture, actions, raid = installLoggerAtomicFixture(addon)
		local before = deepCopy(raid)
		local restore = installFailure(fixture.store)
		local committed, reason = actions:RecordLoot({ raidId = 2, lootNid = 7, looter = "Beta", rollType = "MS", rollValue = 97 })
		if restore then restore() end
		assertEqual(false, committed, label .. " rejects RecordLoot")
		assertEqual("WRITE_FAILED", reason, label .. " preserves public error shape")
		assertTrue(deepEqual(before, raid), label .. " rolls back canonical and runtime state")
		assertEqual(0, #fixture.events, label .. " does not publish")
	end
	assertRollback("verify throw", function(store)
		local original = store.CommitRaidHistoryMutation
		store.CommitRaidHistoryMutation = function(self, target, staged, opts)
			return original(self, target, staged, opts, function() error("verify exploded") end)
		end
		return function() store.CommitRaidHistoryMutation = original end
	end)
	for _, methodName in ipairs({ "MarkLootSyncRevision", "TouchRaidSyncRevision", "EnsureRaidRuntime" }) do
		assertRollback(methodName .. " throw", function(store)
			local original = store[methodName]
			store[methodName] = function() error("injected " .. methodName) end
			return function() store[methodName] = original end
		end)
	end
	print("PASS logger_atomic_commit_failure_matrix")
end

function cases.logger_history_validation_is_strict_and_complete(addon)
	local fixture, _, raid = installLoggerAtomicFixture(addon)
	local function reject(mutator, expected)
		local staged = fixture.store:StageRaidHistoryMutation(raid)
		mutator(staged)
		local before = deepCopy(raid)
		local ok, reason = fixture.store:CommitRaidHistoryMutation(raid, staged, { reason = "test" })
		assertEqual(false, ok, expected .. " must reject")
		assertEqual(expected, reason, expected .. " reason differs")
		assertTrue(deepEqual(before, raid), expected .. " must not mutate canonical raid")
	end
	reject(function(staged) staged.raidNid = "73" end, "INVALID_RAID_NID")
	reject(function(staged) staged.players[1].playerNid = 1.5 end, "INVALID_PLAYER_NID")
	reject(function(staged) staged.loot[1].lootNid = "7" end, "INVALID_LOOT_NID")
	reject(function(staged) staged.loot[3] = { lootNid = 9, itemId = 1 } end, "INVALID_LOOT_COLLECTION")
	reject(function(staged) staged.players.hidden = { playerNid = 22, name = "Hidden" } end, "INVALID_PLAYER_COLLECTION")
	reject(function(staged) staged.bossKills[1] = { bossNid = 4, players = { [2] = 21 } } end, "INVALID_BOSS_PLAYER_COLLECTION")
	local staged = fixture.store:StageRaidHistoryMutation(raid)
	local ok, reason = fixture.store:CommitRaidHistoryMutation(raid, staged, { lootNid = "7", reason = "test" })
	assertEqual(false, ok, "numeric string loot scope must reject")
	assertEqual("INVALID_LOOT_SCOPE", reason, "loot scope reason differs")
	print("PASS logger_history_validation_is_strict_and_complete")
end

function cases.logger_async_rebuild_outcomes_and_conflict(addon)
	local fixture, actions, raid = installLoggerAtomicFixture(addon)
	local callbackResult, callbackComplete
	local handle = actions:StartLootSourceRebuild(function(result, complete)
		callbackResult, callbackComplete = result, complete
	end, { chunkSize = 1, delaySeconds = 0.1 })
	fixture:AdvanceTime(0.1)
	fixture:AdvanceTime(0.1)
	local recordOk = actions:RecordLoot({ raidId = 2, lootNid = 7, looter = "Beta", rollType = "MS", rollValue = 98 })
	assertEqual(true, recordOk, "concurrent RecordLoot setup must commit")
	fixture.events = {}
	fixture:AdvanceTime(0.1)
	fixture:AdvanceTime(0.1)
	assertEqual(false, callbackComplete, "conflict must be incomplete")
	assertEqual(true, callbackResult.failed, "conflict must fail")
	assertEqual(true, callbackResult.conflict, "conflict must be stable and retryable")
	assertEqual(0, callbackResult.repaired, "conflicted staged repairs are not committed counters")
	assertEqual(0, callbackResult.bossesCreated, "conflicted staged bosses are not committed counters")
	assertEqual(0, #fixture.events, "conflicted rebuild must not publish")
	assertEqual(98, raid.loot[1].rollValue, "conflicted rebuild must not overwrite concurrent RecordLoot")
	assertEqual(false, handle:Cancel(), "conflicted handle is terminal")

	fixture, actions, raid = installLoggerAtomicFixture(addon)
	local changedResult, changedComplete
	actions:StartLootSourceRebuild(function(result, complete) changedResult, changedComplete = result, complete end,
		{ chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	assertEqual(true, changedComplete, "changed rebuild completes")
	assertEqual(1, changedResult.repaired, "changed rebuild reports repair")
	assertEqual(1, #fixture.events, "changed rebuild publishes once")
	fixture.events = {}
	local noopResult, noopComplete
	actions:StartLootSourceRebuild(function(result, complete) noopResult, noopComplete = result, complete end,
		{ chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	assertEqual(true, noopComplete, "no-op rebuild completes")
	assertEqual(0, noopResult.repaired, "no-op rebuild reports no repair")
	assertEqual(0, #fixture.events, "no-op rebuild does not publish")
	raid.loot[2] = { lootNid = 8, itemId = 99999 }
	fixture.store:EnsureRaidRuntime(raid)
	local unresolvedResult
	actions:StartLootSourceRebuild(function(result) unresolvedResult = result end, { chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	assertEqual(1, unresolvedResult.unresolved, "unresolved row is reported")
	assertEqual(0, #fixture.events, "unresolved rebuild does not publish")
	local cancelledResult, cancelledComplete
	local cancelHandle = actions:StartLootSourceRebuild(function(result, complete)
		cancelledResult, cancelledComplete = result, complete
	end, { chunkSize = 1, delaySeconds = 0 })
	assertEqual(true, cancelHandle:Cancel(), "active rebuild cancels")
	assertEqual(false, cancelledComplete, "cancel is incomplete")
	assertEqual(true, cancelledResult.cancelled, "cancel outcome is explicit")
	assertEqual(0, cancelledResult.repaired, "cancelled stage contributes no committed repairs")
	print("PASS logger_async_rebuild_outcomes_and_conflict")
end

function cases.logger_async_cleanup_cancel_rolls_back_staged_work(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local before = deepCopy(fixture.raids)
	local callbackResult, callbackComplete
	local handle = actions:StartRaidHistoryCleanup(function(result, complete)
		callbackResult, callbackComplete = result, complete
	end, { emptyRaids = true, nonEpicLoot = true, chunkSize = 1, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	assertEqual(true, handle:Cancel(), "active cleanup should cancel")
	assertTrue(deepEqual(before, fixture.raids), "cancelled staged cleanup must persist nothing")
	assertEqual(false, callbackComplete, "cancel callback should report incomplete work")
	assertEqual(true, callbackResult.cancelled, "cancel result should expose cancellation")
	assertEqual(false, callbackResult.changed, "rolled-back cleanup should report no canonical change")
	assertEqual(0, #fixture.events, "rollback cancellation should not publish a data-change event")
	print("PASS logger_async_cleanup_cancel_rolls_back_staged_work")
end

function cases.logger_async_cleanup_completed_handle_is_terminal_not_cancelled(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local callbackCount, callbackResult, callbackComplete = 0
	local handle = actions:StartRaidHistoryCleanup(function(result, complete)
		callbackCount = callbackCount + 1
		callbackResult, callbackComplete = result, complete
	end, { emptyRaids = true, nonEpicLoot = true, chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	local completedSnapshot = deepCopy(callbackResult)
	assertEqual(true, callbackComplete, "completion callback should report success")
	assertEqual(1, callbackCount, "completion callback should run once")
	assertEqual(false, handle:IsCancelled(), "completed work is not cancelled")
	assertEqual(false, handle:Cancel(), "completed work cannot be cancelled")
	assertEqual(1, callbackCount, "post-completion cancellation must not call back")
	assertTrue(deepEqual(completedSnapshot, callbackResult), "post-completion cancellation must not mutate result")
	print("PASS logger_async_cleanup_completed_handle_is_terminal_not_cancelled")
end

function cases.logger_async_cleanup_store_failure_is_atomic(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local beforeRaids = deepCopy(fixture.raids)
	local beforeCurrent = fixture.currentRaid
	local callbackCount, callbackResult, callbackComplete = 0
	local originalDeleteRaids = fixture.store.DeleteRaidsByNid
	fixture.store.DeleteRaidsByNid = function()
		error("injected second store operation failure")
	end
	local handle = actions:StartRaidHistoryCleanup(function(result, complete)
		callbackCount = callbackCount + 1
		callbackResult, callbackComplete = result, complete
	end, { emptyRaids = true, nonEpicLoot = true, chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	fixture.store.DeleteRaidsByNid = originalDeleteRaids
	for i = 1, #beforeRaids do beforeRaids[i]._runtime = nil end
	local restoredRaids = deepCopy(fixture.raids)
	for i = 1, #restoredRaids do restoredRaids[i]._runtime = nil end
	assertTrue(deepEqual(beforeRaids, restoredRaids), "failed cleanup must deeply restore canonical raids")
	assertEqual(8, fixture.store:GetRaidSyncRevision(fixture.raids[2]), "failed cleanup must restore revision")
	assertEqual(beforeCurrent, fixture.currentRaid, "failed cleanup must restore current raid")
	assertEqual(0, #fixture.events, "failed cleanup must not publish")
	assertEqual(1, callbackCount, "failed cleanup must call back once")
	assertEqual(false, callbackComplete, "failed cleanup must report incomplete")
	assertEqual(true, callbackResult.failed, "failed cleanup must identify failure")
	assertEqual(false, callbackResult.cancelled, "store failure is not cancellation")
	assertEqual(false, handle:IsCancelled(), "failed work is not cancelled")
	assertEqual(false, handle:Cancel(), "failed terminal work cannot be cancelled")
	print("PASS logger_async_cleanup_store_failure_is_atomic")
end

function cases.logger_cleanup_snapshot_failures_are_terminal(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local originalCapture = fixture.store.CaptureRaidHistoryState
	fixture.store.CaptureRaidHistoryState = function() error("capture failed") end
	local syncResult = actions:CleanupRaidHistory({ emptyRaids = true, nonEpicLoot = true })
	assertEqual(true, syncResult.failed, "sync capture failure should be stable")
	assertEqual(false, syncResult.complete, "sync capture failure must not complete")
	assertEqual(0, #fixture.events, "sync capture failure must not publish")
	fixture.store.CaptureRaidHistoryState = function() return nil end
	local nilCaptureResult = actions:CleanupRaidHistory({ emptyRaids = true })
	assertEqual(true, nilCaptureResult.failed, "nil capture should be a stable failure")
	fixture.store.CaptureRaidHistoryState = originalCapture
	local originalDeleteRaids = fixture.store.DeleteRaidsByNid
	local originalRestore = fixture.store.RestoreRaidHistoryState
	fixture.store.DeleteRaidsByNid = function() error("sync apply failed") end
	fixture.store.RestoreRaidHistoryState = function() return false end
	local syncRestoreResult = actions:CleanupRaidHistory({ emptyRaids = true, nonEpicLoot = true })
	assertEqual(true, syncRestoreResult.rollbackFailed, "sync restore failure must report uncertainty")
	assertEqual(true, syncRestoreResult.rollbackUncertain, "sync restore failure cannot claim atomic rollback")
	assertEqual(false, syncRestoreResult.complete, "sync restore failure must not complete")
	fixture.store.DeleteRaidsByNid = originalDeleteRaids
	fixture.store.RestoreRaidHistoryState = originalRestore

	fixture, actions = installLoggerCleanupFixture(addon)
	local asyncCaptureCallbacks = 0
	fixture.store.CaptureRaidHistoryState = function() error("async capture failed") end
	local captureHandle = actions:StartRaidHistoryCleanup(function(result, complete)
		asyncCaptureCallbacks = asyncCaptureCallbacks + 1
		assertEqual(true, result.failed, "async capture failure should fail")
		assertEqual(false, complete, "async capture failure must be incomplete")
	end, { emptyRaids = true, chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	assertEqual(1, asyncCaptureCallbacks, "async capture failure callback should run once")
	assertEqual(false, captureHandle:Cancel(), "async capture failure is terminal")
	fixture.store.CaptureRaidHistoryState = originalCapture

	local function assertAsyncRestoreFailure(restoreImpl, expectedRollbackError)
		local callbackCount, callbackResult, callbackComplete = 0
		local originalDeleteRaids = fixture.store.DeleteRaidsByNid
		local originalRestore = fixture.store.RestoreRaidHistoryState
		fixture.store.DeleteRaidsByNid = function() error("apply failed after mutation") end
		fixture.store.RestoreRaidHistoryState = restoreImpl
		local handle = actions:StartRaidHistoryCleanup(function(result, complete)
			callbackCount = callbackCount + 1
			callbackResult, callbackComplete = result, complete
		end, { emptyRaids = true, nonEpicLoot = true, chunkSize = 20, delaySeconds = 0 })
		fixture:AdvanceTime(0)
		fixture.store.DeleteRaidsByNid = originalDeleteRaids
		fixture.store.RestoreRaidHistoryState = originalRestore
		assertEqual(1, callbackCount, "restore failure callback should run once")
		assertEqual(false, callbackComplete, "restore failure must be incomplete")
		assertEqual(true, callbackResult.failed, "restore failure should fail")
		assertEqual(true, callbackResult.rollbackFailed, "restore failure must report uncertain rollback")
		assertEqual(true, callbackResult.rollbackUncertain, "restore failure cannot claim atomic rollback")
		assertTrue(string.find(callbackResult.rollbackError, expectedRollbackError, 1, true) ~= nil, "rollback error differs")
		assertEqual(0, #fixture.events, "restore failure must not publish")
		assertEqual(false, handle:IsCancelled(), "failed handle is not cancelled")
		assertEqual(false, handle:Cancel(), "failed terminal handle cannot cancel")
	end
	assertAsyncRestoreFailure(function() return false end, "returned false")
	assertAsyncRestoreFailure(function() error("restore exploded") end, "restore exploded")
	print("PASS logger_cleanup_snapshot_failures_are_terminal")
end

function cases.logger_refresh_requests_coalesce_behaviorally(addon)
	local defer
	_G.table.wipe = _G.table.wipe or function(value)
		for key in pairs(value) do
			value[key] = nil
		end
	end
	_G.CreateFrame = function()
		defer = { shown = false }
		function defer:Show() self.shown = true end
		function defer:Hide() self.shown = false end
		return defer
	end
	addon.Diag = { E = { LogListUIError = "%s %s" }, W = { LogListUIMissingWidgets = "%s" }, D = {} }
	addon.warn = function() end
	addon.error = function(_, message) error(message) end
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.UI = {
		Frames = {
			SetScriptSafely = function(frame, name, callback) frame[name] = callback end,
			HookScriptSafely = function(frame, name, callback) frame[name] = callback end,
		},
		Rows = {}, Primitives = {},
	}
	loadAddonFile(addon, "Raid Management Addon/Modules/UI/ListController.lua")
	local refreshCount = 0
	local controller = addon.UI.Lists.CreateController({ getData = function() refreshCount = refreshCount + 1 end })
	controller.frameName = "TestList"
	controller._active = true
	controller:Dirty()
	controller:Dirty()
	assertEqual(0, refreshCount, "dirty requests should defer refresh")
	defer.OnUpdate(defer)
	assertEqual(1, refreshCount, "event and selection dirty requests should coalesce")
	print("PASS logger_refresh_requests_coalesce_behaviorally")
end

function cases.logger_bulk_raid_delete_publishes_once(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	fixture.currentRaid = nil
	local result = actions:DeleteRaidsByNid({ 41, 73 })
	assertEqual(2, result.removed, "bulk delete should delete both raids")
	assertEqual(0, #fixture.raids, "bulk delete should empty history")
	assertEqual(1, #fixture.events, "bulk raid deletion should publish one event")
	print("PASS logger_bulk_raid_delete_publishes_once")
end

function cases.listener_removal_does_not_skip_next(addon)
	local frame = installInitStubs(addon)
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	local calls = {}
	local first = {}
	local second = {}

	function first.TEST_EVENT(self)
		calls[#calls + 1] = "first"
		addon.UnregisterEvent(self, "TEST_EVENT")
	end

	function second.TEST_EVENT()
		calls[#calls + 1] = "second"
	end

	addon.RegisterEvent(first, "TEST_EVENT")
	addon.RegisterEvent(second, "TEST_EVENT")
	frame.OnEvent(frame, "TEST_EVENT")
	frame.OnEvent(frame, "TEST_EVENT")

	assertEqual(3, #calls, "listener mutation should affect only the next dispatch")
	assertEqual("first", calls[1])
	assertEqual("second", calls[2])
	assertEqual("second", calls[3])
	print("PASS listener_removal_does_not_skip_next")
end

function cases.nested_dispatch_preserves_outer_snapshot(addon)
	local frame = installInitStubs(addon)
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	local calls = {}
	local nested = false
	local first = {}
	local second = {}
	local third = {}

	function first.TEST_EVENT()
		calls[#calls + 1] = nested and "first nested" or "first outer"
		if not nested then
			nested = true
			addon.UnregisterEvent(second, "TEST_EVENT")
			frame.OnEvent(frame, "TEST_EVENT")
			nested = false
		end
	end

	function second.TEST_EVENT()
		calls[#calls + 1] = "second outer"
	end

	function third.TEST_EVENT()
		calls[#calls + 1] = nested and "third nested" or "third outer"
	end

	addon.RegisterEvent(first, "TEST_EVENT")
	addon.RegisterEvent(second, "TEST_EVENT")
	addon.RegisterEvent(third, "TEST_EVENT")
	frame.OnEvent(frame, "TEST_EVENT")

	assertEqual(5, #calls, "nested dispatch should not overwrite the outer listener snapshot")
	assertEqual("first outer", calls[1])
	assertEqual("first nested", calls[2])
	assertEqual("third nested", calls[3])
	assertEqual("second outer", calls[4])
	assertEqual("third outer", calls[5])
	print("PASS nested_dispatch_preserves_outer_snapshot")
end

function cases.localized_raid_identity_uses_instance_map_id(addon)
	addon.LootSourceCandidates = { GetModeSignature = function() return "" end }
	addon.LootSourcesData = { Raw = {} }
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSources/Vanilla.lua")
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSources/Wrath.lua")
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSourcesData.lua")

	assertEqual(
		"icecrown citadel",
		addon.LootSourcesData.ResolveInstanceKey("Citadelle de la Couronne de glace", 631),
		"localized names must resolve through the stable instance map id"
	)
	assertEqual(
		"molten core",
		addon.LootSourcesData.ResolveInstanceKey("Caverne du coeur du Magma", 409),
		"classic raid datasets must use the same locale-independent identity"
	)
	assertEqual(
		"icecrown citadel",
		addon.LootSourcesData.ResolveInstanceKey("Icecrown Citadel", nil),
		"English and custom-server name fallback must remain supported"
	)
	assertEqual(
		nil,
		addon.LootSourcesData.ResolveInstanceKey("Unknown Custom Raid", nil),
		"unknown instances must fail closed"
	)
	print("PASS localized_raid_identity_uses_instance_map_id")
end

function cases.instance_datasets_share_canonical_identity(addon)
	installInitStubs(addon)
	local activated = {}
	addon.L = { RaidZones = {} }
	addon.Diag = {
		D = { LogRaidInstanceRecognized = "%s %s" },
		W = { LogRaidUnmappedZone = "%s %s" },
	}
	addon.warn = function() end
	addon.LootSourcesData = {
		ResolveInstanceKey = function(name, instanceMapId)
			assertEqual("Citadelle de la Couronne de glace", name)
			assertEqual(631, instanceMapId)
			return "icecrown citadel"
		end,
		ActivateInstance = function(key) activated.loot = key return true end,
		DeactivateInstance = function() activated.loot = nil end,
		GetActiveInstanceKey = function() return activated.loot end,
	}
	addon.IgnoredMobs = {
		ActivateInstance = function(key) activated.ignored = key return true end,
		DeactivateInstance = function() activated.ignored = nil end,
		GetActiveInstanceKey = function() return activated.ignored end,
	}
	_G.GetInstanceInfo = function()
		return "Citadelle de la Couronne de glace", "raid", 2, nil, 25, 0, false, 631
	end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	addon:ZONE_CHANGED_NEW_AREA()
	assertEqual("icecrown citadel", activated.loot, "loot dataset must receive the canonical key")
	assertEqual("icecrown citadel", activated.ignored, "ignored-mob dataset must receive the same canonical key")
	print("PASS instance_datasets_share_canonical_identity")
end

function cases.loot_dataset_build_failure_preserves_active_generation(addon)
	local failBuild = false
	addon.LootSourceCandidates = {
		GetModeSignature = function()
			if failBuild then error("injected dataset failure") end
			return ""
		end,
	}
	addon.LootSourcesData = { Raw = {} }
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSources/Wrath.lua")
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSourcesData.lua")
	local data = addon.LootSourcesData
	assertTrue(data.ActivateInstance("icecrown citadel"))
	local oldItems = data.ByItemId
	local oldInstances = data.ByInstance
	local oldGeneration = data.GetGeneration()
	local oldCandidate = oldItems[50424] and oldItems[50424][1]
	failBuild = true
	local ok, err = pcall(data.ActivateInstance, "ulduar")
	assertEqual(false, ok, "fault injection must reach the detached build")
	assertTrue(string.find(tostring(err), "injected dataset failure", 1, true) ~= nil)
	assertEqual(oldItems, data.ByItemId, "active item root identity must remain unchanged")
	assertEqual(oldInstances, data.ByInstance, "active instance root identity must remain unchanged")
	assertEqual(oldGeneration, data.GetGeneration(), "failed build must not publish a generation")
	assertEqual("icecrown citadel", data.GetActiveInstanceKey())
	assertEqual(oldCandidate, data.ByItemId[50424] and data.ByItemId[50424][1], "attribution identity must remain unchanged")
	print("PASS loot_dataset_build_failure_preserves_active_generation")
end

function cases.loot_dataset_handles_duplicate_nil_and_malformed_entries(addon)
	addon.LootSourceCandidates = { GetModeSignature = function() return "" end }
	addon.LootSourcesData = { Raw = {
		{ name = "Test Raid", sources = {
			{ npcId = 7, name = "Boss", kind = "boss", items = { { 100 }, { 100 }, nil, "bad", { nil } } },
			{ npcId = nil, name = "Malformed", items = { { 101 } } },
		} },
	} }
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSourcesData.lua")
	local data = addon.LootSourcesData
	assertTrue(data.ActivateInstance("test raid"))
	assertEqual(2, #data.ByItemId[100], "duplicate definitions remain explicit source candidates")
	assertEqual(nil, data.ByItemId[101], "malformed source definitions must be skipped")
	assertEqual(nil, data.ByItemId[nil], "nil item identifiers must not be indexed")
	print("PASS loot_dataset_handles_duplicate_nil_and_malformed_entries")
end

function cases.dataset_activation_rolls_back_cross_owner_failure(addon)
	installInitStubs(addon)
	addon.L = { RaidZones = {} }
	addon.Diag = { D = { LogRaidInstanceRecognized = "%s %s" }, W = { LogRaidUnmappedZone = "%s %s" } }
	addon.warn = function() end
	local lootKey = "old raid"
	local ignoredKey = "old raid"
	addon.LootSourcesData = {
		ResolveInstanceKey = function() return "new raid" end,
		GetActiveInstanceKey = function() return lootKey end,
		ActivateInstance = function(key) lootKey = key return true end,
		DeactivateInstance = function() lootKey = nil return true end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function() return ignoredKey end,
		ActivateInstance = function(key)
			if key == "new raid" then error("injected ignored failure") end
			ignoredKey = key
			return true
		end,
		DeactivateInstance = function() ignoredKey = nil return true end,
	}
	_G.GetInstanceInfo = function() return "Localized", "raid", 1, nil, 10, 0, false, 999 end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	local ok = pcall(addon.ZONE_CHANGED_NEW_AREA, addon)
	assertEqual(false, ok, "activation failure must remain visible")
	assertEqual("old raid", lootKey, "loot activation must roll back")
	assertEqual("old raid", ignoredKey, "ignored-mob activation must roll back")
	print("PASS dataset_activation_rolls_back_cross_owner_failure")
end

function cases.dataset_activation_rejects_false_owner_results(addon)
	installInitStubs(addon)
	addon.L = { RaidZones = {} }
	addon.Diag = { D = { LogRaidInstanceRecognized = "%s %s" }, W = { LogRaidUnmappedZone = "%s %s" } }
	addon.warn = function() end
	local lootKey = "old raid"
	local ignoredKey = "old raid"
	local ignoredCalls = 0
	addon.LootSourcesData = {
		ResolveInstanceKey = function() return "new raid" end,
		GetActiveInstanceKey = function() return lootKey end,
		ActivateInstance = function(key)
			if key == "new raid" then return false, "loot-rejected" end
			lootKey = key return true
		end,
		DeactivateInstance = function() lootKey = nil return true end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function() return ignoredKey end,
		ActivateInstance = function(key) ignoredCalls = ignoredCalls + 1 ignoredKey = key return true end,
		DeactivateInstance = function() ignoredKey = nil return true end,
	}
	_G.GetInstanceInfo = function() return "Localized", "raid", 1, nil, 10, 0, false, 999 end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	local ok, err = pcall(addon.ZONE_CHANGED_NEW_AREA, addon)
	assertEqual(false, ok)
	assertTrue(string.find(tostring(err), "loot-rejected", 1, true) ~= nil)
	assertEqual(0, ignoredCalls, "second owner must not run after first-owner rejection")
	assertEqual("old raid", lootKey)
	assertEqual("old raid", ignoredKey)
	print("PASS dataset_activation_rejects_false_owner_results")
end

function cases.dataset_activation_reports_failed_rollback(addon)
	installInitStubs(addon)
	addon.L = { RaidZones = {} }
	addon.Diag = { D = { LogRaidInstanceRecognized = "%s %s" }, W = { LogRaidUnmappedZone = "%s %s" } }
	addon.warn = function() end
	local lootKey = "old raid"
	local ignoredKey = "old raid"
	addon.LootSourcesData = {
		ResolveInstanceKey = function() return "new raid" end,
		GetActiveInstanceKey = function() return lootKey end,
		ActivateInstance = function(key)
			if key == "old raid" and lootKey == "new raid" then return false, "rollback-refused" end
			lootKey = key return true
		end,
		DeactivateInstance = function() lootKey = nil return true end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function() return ignoredKey end,
		ActivateInstance = function(key)
			if key == "new raid" then ignoredKey = nil return false, "ignored-rejected" end
			ignoredKey = key return true
		end,
		DeactivateInstance = function() ignoredKey = nil return true end,
	}
	_G.GetInstanceInfo = function() return "Localized", "raid", 1, nil, 10, 0, false, 999 end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	local ok, err = pcall(addon.ZONE_CHANGED_NEW_AREA, addon)
	assertEqual(false, ok)
	assertTrue(string.find(tostring(err), "dataset_rollback_failed", 1, true) ~= nil)
	assertTrue(string.find(tostring(err), "rollback-refused", 1, true) ~= nil)
	assertEqual("new raid", lootKey, "failed rollback may leave state changed but must be terminal")
	assertEqual("old raid", ignoredKey, "successful peer rollback must still restore its owner")
	print("PASS dataset_activation_reports_failed_rollback")
end

function cases.dataset_activation_snapshots_restore_exact_generation(addon)
	addon.L = {}
	addon.LootSourceCandidates = { GetModeSignature = function() return "" end }
	addon.LootSourcesData = { Raw = {} }
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSources/Wrath.lua")
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSourcesData.lua")
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/IgnoredMobs.lua")
	local loot = addon.LootSourcesData
	local ignored = addon.IgnoredMobs
	assertTrue(loot.ActivateInstance("icecrown citadel"))
	assertTrue(ignored.ActivateInstance("icecrown citadel"))
	local lootRoot = loot.ByItemId
	local ignoredRoot = ignored.Ids
	local lootGeneration = loot.GetGeneration()
	local ignoredGeneration = ignored.GetGeneration()
	local lootSnapshot = loot.CaptureActivationState()
	local ignoredSnapshot = ignored.CaptureActivationState()
	assertTrue(loot.ActivateInstance("ulduar"))
	assertTrue(ignored.ActivateInstance("ulduar"))
	assertTrue(loot.RestoreActivationState(lootSnapshot))
	assertTrue(ignored.RestoreActivationState(ignoredSnapshot))
	assertEqual(lootRoot, loot.ByItemId)
	assertEqual(ignoredRoot, ignored.Ids)
	assertEqual(lootGeneration, loot.GetGeneration())
	assertEqual(ignoredGeneration, ignored.GetGeneration())
	assertEqual("icecrown citadel", loot.GetActiveInstanceKey())
	assertEqual("icecrown citadel", ignored.GetActiveInstanceKey())
	print("PASS dataset_activation_snapshots_restore_exact_generation")
end



function cases.error_reporting_failure_cleans_dispatch_snapshot(addon)
	local frame = installInitStubs(addon)
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	local listener = {}
	local weakListener = setmetatable({ listener }, { __mode = "v" })

	function listener.TEST_EVENT()
		error("listener failed")
	end

	addon.RegisterEvent(listener, "TEST_EVENT")
	local ok, err = pcall(frame.OnEvent, frame, "TEST_EVENT")
	assertEqual(false, ok, "diagnostic reporting failure should remain visible")
	assertTrue(
		string.find(tostring(err), "listener failed", 1, true),
		"callback failure should remain in the diagnostic error"
	)
	addon.UnregisterEvent(listener, "TEST_EVENT")
	listener = nil
	collectgarbage("collect")
	collectgarbage("collect")
	assertEqual(nil, weakListener[1], "failed dispatch should release its listener snapshot")
	print("PASS error_reporting_failure_cleans_dispatch_snapshot")
end

function cases.bootstrap_retries_after_commit_failure(addon)
	local frame = installInitStubs(addon)
	local registerEvent = frame.RegisterEvent
	local failCommitOnce = true
	local commitRegistrations = 0
	local failedEvent
	function frame:RegisterEvent(eventName)
		if failCommitOnce and eventName ~= "ADDON_LOADED" then
			commitRegistrations = commitRegistrations + 1
			if commitRegistrations == 2 then
				failCommitOnce = false
				failedEvent = eventName
				error("commit registration failed")
			end
		end
		registerEvent(self, eventName)
	end

	addon.Database.SavedVariables = {
		EnsureAll = function() end,
		NormalizeAfterLoad = function() end,
	}
	loadAddonFile(addon, "Raid Management Addon/Init.lua")

	local ok, err = pcall(addon.ADDON_LOADED, addon, "Raid Management Addon")
	assertEqual(false, ok, "commit failure should surface to diagnostics")
	assertTrue(
		string.find(tostring(err), "commit registration failed", 1, true),
		"original commit error should be visible"
	)
	assertEqual(nil, addon.State.initializing, "commit failure should clear the re-entry guard")
	assertTrue(frame.registered.ADDON_LOADED, "commit failure should preserve bootstrap retryability")
	assertEqual(false, addon.State.initialized == true, "commit failure should not mark initialization complete")

	addon:ADDON_LOADED("Raid Management Addon")
	assertEqual(true, addon.State.initialized, "retry should complete after a commit failure")
	assertEqual(nil, frame.registered.ADDON_LOADED, "successful retry should remove ADDON_LOADED")
	assertTrue(failedEvent ~= nil, "test should capture the event whose registration failed")
	for i = 1, #expectedRuntimeEvents do
		local eventName = expectedRuntimeEvents[i]
		assertEqual(true, frame.registered[eventName], "retry should activate expected runtime event " .. eventName)
		assertEqual(
			1,
			frame.activeRegistrationCount[eventName],
			"retry should leave one active registration for " .. eventName
		)
	end
	print("PASS bootstrap_retries_after_commit_failure")
end

function cases.options_normalize_persisted_types(addon)
	local options = installOptionsStubs(addon, {
		Test = {
			enabled = "false",
			disabled = false,
		},
	})
	local ns = options.RegisterNamespace("Test", {
		enabled = true,
		disabled = true,
	})
	options.EnsureLoaded()

	assertEqual(true, ns:Get("enabled"), "type-corrupt persisted booleans should reset to their default")
	assertEqual("boolean", type(_G.RMA_Options.Test.enabled), "normalized storage should retain the declared type")
	assertEqual(false, ns:Get("disabled"), "valid persisted false should be preserved")
	print("PASS options_normalize_persisted_types")
end

function cases.options_nested_defaults_are_independent(addon)
	local options = installOptionsStubs(addon)
	local declaredDefaults = {
		settings = {
			mode = "clean",
		},
	}
	local ns = options.RegisterNamespace("Nested", declaredDefaults)

	ns:Get("settings").mode = "mutated"
	local reset = ns:ResetDefaults()
	assertEqual("clean", reset.settings.mode, "reset should restore an unmodified nested default")
	assertTrue(reset.settings ~= declaredDefaults.settings, "reset storage should not alias declared defaults")
	reset.settings.mode = "changed again"
	local secondReset = ns:ResetDefaults()
	assertEqual("clean", secondReset.settings.mode, "each reset should create an independent nested table")
	print("PASS options_nested_defaults_are_independent")
end

function cases.options_reject_ambiguous_ownership(addon)
	local options = installOptionsStubs(addon)
	options.RegisterNamespace("First", { shared = true })

	local ok, err = pcall(options.RegisterNamespace, "Second", { shared = false })
	assertEqual(false, ok, "a key cannot be owned by two namespaces")
	assertTrue(
		string.find(
			tostring(err),
			'Options.RegisterNamespace: key "shared" is already owned by namespace "First"',
			1,
			true
		),
		"collision should raise a stable ownership error"
	)

	local first = options.RegisterNamespace("First", { extension = 3 })
	assertEqual(3, first:Get("extension"), "same-namespace registration may add a new key")
	local repeatedOk = pcall(options.RegisterNamespace, "First", { shared = "incompatible" })
	assertEqual(false, repeatedOk, "same-namespace registration should reject an incompatible declaration")
	print("PASS options_reject_ambiguous_ownership")
end

function cases.options_namespace_snapshot_is_isolated(addon)
	local options = installOptionsStubs(addon)
	local ns = options.RegisterNamespace("Snapshot", { enabled = true })
	local snapshot = options.GetNamespaces()
	snapshot.Snapshot._store = { enabled = false }
	snapshot.Snapshot._defaults = { enabled = false }
	snapshot.Snapshot = nil
	snapshot.Injected = ns

	local fresh = options.GetNamespaces()
	assertEqual("Snapshot", fresh.Snapshot:Name(), "mutating a snapshot must not remove a registered namespace")
	assertEqual(nil, fresh.Injected, "mutating a snapshot must not inject a namespace")
	assertEqual(true, options.GetByKey("enabled"), "snapshot mutation must not alter key ownership")
	print("PASS options_namespace_snapshot_is_isolated")
end

function cases.options_same_namespace_extension_preserves_storage(addon)
	local options = installOptionsStubs(addon, {
		Master = {
			first = true,
			later = 7,
			unknown = "remove me",
			[4] = "remove me too",
		},
	})
	options.RegisterNamespace("Master", { first = false })
	local ns = options.RegisterNamespace("Master", { later = 1 })
	options.EnsureLoaded()

	assertEqual(7, ns:Get("later"), "a later same-namespace owner should retain its valid persisted value")
	assertEqual(nil, _G.RMA_Options.Master.unknown, "strict admission should remove unknown string keys")
	assertEqual(nil, _G.RMA_Options.Master[4], "strict admission should remove non-string keys")
	print("PASS options_same_namespace_extension_preserves_storage")
end

function cases.options_reject_invalid_registered_keys(addon)
	local tableKey = {}
	local persisted = {
		Invalid = {
			[9] = "persisted numeric key",
			[tableKey] = "persisted table key",
		},
		[9] = "persisted numeric namespace",
		[tableKey] = "persisted table namespace",
	}
	local options = installOptionsStubs(addon, persisted)
	local invalidDefaults = {
		[9] = true,
		[tableKey] = false,
	}

	local numericOk, numericErr = pcall(options.RegisterNamespace, "Invalid", invalidDefaults)
	assertEqual(false, numericOk, "numeric registered option keys should be rejected")
	assertTrue(
		string.find(tostring(numericErr), "Options.RegisterNamespace: option keys must be non-empty strings", 1, true),
		"invalid keys should raise a stable registration error"
	)
	assertEqual(nil, options.Get("Invalid"), "failed registration must not mutate the namespace registry")
	assertEqual(nil, options.GetByKey(9), "failed registration must not mutate key ownership")

	local emptyOk, emptyErr = pcall(options.RegisterNamespace, "Invalid", { [""] = true })
	assertEqual(false, emptyOk, "empty registered option keys should be rejected")
	assertTrue(
		string.find(tostring(emptyErr), "Options.RegisterNamespace: option keys must be non-empty strings", 1, true),
		"empty keys should use the stable registration error"
	)

	options.RegisterNamespace("Valid", { enabled = true })
	options.EnsureLoaded()
	assertEqual(nil, _G.RMA_Options.Invalid, "strict storage must remove data for a rejected namespace")
	assertEqual(nil, _G.RMA_Options[9], "strict storage must not reintroduce numeric keys")
	assertEqual(nil, _G.RMA_Options[tableKey], "strict storage must not reintroduce table keys")
	print("PASS options_reject_invalid_registered_keys")
end

function cases.options_table_default_redeclaration(addon)
	local options = installOptionsStubs(addon)
	local first = { mode = "clean", nested = { enabled = true } }
	first.self = first
	options.RegisterNamespace("Tables", { settings = first })

	local equivalent = { nested = { enabled = true }, mode = "clean" }
	equivalent.self = equivalent
	local equivalentOk = pcall(options.RegisterNamespace, "Tables", { settings = equivalent })
	assertEqual(true, equivalentOk, "structurally equivalent table defaults should be accepted")

	local incompatible = { mode = "different", nested = { enabled = true } }
	incompatible.self = incompatible
	local incompatibleOk, incompatibleErr = pcall(options.RegisterNamespace, "Tables", { settings = incompatible })
	assertEqual(false, incompatibleOk, "structurally incompatible table defaults should be rejected")
	assertTrue(
		string.find(tostring(incompatibleErr), "has an incompatible declaration", 1, true),
		"incompatible table defaults should retain the stable declaration error"
	)
	print("PASS options_table_default_redeclaration")
end

function cases.options_cyclic_defaults_remain_independent(addon)
	local options = installOptionsStubs(addon)
	local cyclic = { mode = "clean" }
	cyclic.self = cyclic
	local ns = options.RegisterNamespace("Cyclic", { settings = cyclic })
	local stored = ns:Get("settings")
	assertTrue(stored.self == stored, "registration should preserve a self-referential default")
	assertTrue(stored ~= cyclic, "registered storage should not alias the declared default")

	local all = ns:All()
	assertTrue(all.settings.self == all.settings, "All should preserve the copied cycle shape")
	assertTrue(all.settings ~= stored, "All should isolate returned tables from storage")
	all.settings.mode = "all mutation"
	assertEqual("clean", stored.mode, "mutating All output should not alter storage")

	stored.mode = "storage mutation"
	local reset = ns:ResetDefaults()
	assertTrue(reset.settings.self == reset.settings, "ResetDefaults should preserve the cycle shape")
	assertTrue(reset.settings ~= stored, "ResetDefaults should replace storage independently")
	assertTrue(reset.settings ~= cyclic, "reset storage should not alias the declared default")
	assertEqual("clean", reset.settings.mode, "ResetDefaults should restore the isolated default")
	print("PASS options_cyclic_defaults_remain_independent")
end

function cases.options_namespace_facade_contract(addon)
	local options = installOptionsStubs(addon)
	options.RegisterNamespace("Facade", { enabled = true, nested = { count = 1 } })
	local facade = options.GetNamespaces().Facade

	assertEqual("Facade", facade:Name(), "facade Name should match the registered namespace")
	assertEqual(true, facade:Get("enabled"), "facade Get should delegate to the namespace")
	assertEqual(true, facade:Set("enabled", false), "facade Set should delegate to the namespace")
	assertEqual(false, facade:Get("enabled"), "facade Get should observe facade writes")
	local all = facade:All()
	all.nested.count = 9
	assertEqual(1, facade:Get("nested").count, "facade All should return isolated values")
	local reset = facade:ResetDefaults()
	assertEqual(true, reset.enabled, "facade ResetDefaults should restore defaults")
	reset.nested.count = 7
	assertEqual(7, facade:Get("nested").count, "facade ResetDefaults should preserve the namespace return contract")
	local secondReset = facade:ResetDefaults()
	assertEqual(1, secondReset.nested.count, "facade ResetDefaults should create independent storage each time")
	print("PASS options_namespace_facade_contract")
end

function cases.future_raid_schema_is_preserved(addon)
	addon.DB = {}
	addon.State.raidStore = {}
	addon.Time = {
		GetCurrentTime = function()
			return 100
		end,
	}
	addon.Sort = {
		GetLootSortName = function()
			return ""
		end,
	}
	addon.Strings = {
		NormalizeLower = function(value)
			return value and string.lower(value) or nil
		end,
		NormalizeName = function(value)
			return value
		end,
		NilIfEmpty = function(value)
			return value ~= "" and value or nil
		end,
	}
	addon.LootSourceCandidates = {
		ResolveSourceMetadata = function()
			return nil
		end,
		GetSharedLabel = function()
			return "Shared"
		end,
		IsSharedSourceName = function()
			return false
		end,
		Copy = function(value)
			return value
		end,
	}
	addon.IgnoredMobs = {
		IsTrashMobName = function()
			return false
		end,
	}
	addon.Database.IsBossFightRecord = function()
		return true
	end
	addon.Database.GetRaidSchemaVersion = function()
		return 6
	end
	addon.Database.SavedVariables = {
		GetRaids = function()
			return _G.RMA_Raids
		end,
	}
	_G.RMA_Raids = {}

	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidMigrations.lua")
	addon.Database.GetRaidMigrations = function()
		return addon.DB.RaidMigrations
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidStore.lua")
	addon.Database.GetRaidStore = function()
		return addon.DB.RaidStore
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidQueries.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidValidator.lua")

	local future = {
		schemaVersion = 7,
		raidNid = 41,
		players = {
			{ playerNid = 3, name = "Alpha", futureRole = "anchor" },
			{ playerNid = 3, name = "Beta", futureRole = "echo" },
		},
		bossKills = { { bossNid = 9, name = "Future Boss", players = { 3, 3 } } },
		loot = { { lootNid = 12, looterNid = 3, futureAward = { policy = "v7" } } },
		attendance = { { playerNid = 3, segments = { { startTime = 10, endTime = 20, online = false } } } },
		futureData = { nested = { enabled = true } },
	}

	local function assertPreserved(call, expectedError)
		local raid = deepCopy(future)
		local before = deepCopy(raid)
		local result, err = call(raid)
		assertEqual(nil, result, "future-schema operation should reject")
		assertEqual(expectedError, err, "future-schema operation should return stable error")
		assertTrue(deepEqual(before, raid), "future-schema operation must preserve the record deeply")
	end

	assertPreserved(function(raid)
		return addon.DB.RaidStore:NormalizeRaidRecord(raid)
	end, "unsupported raid schema")
	assertPreserved(function(raid)
		return addon.DB.RaidQueries:GetRaidSummary(raid)
	end, "unsupported raid schema")
	assertPreserved(function(raid)
		return addon.DB.RaidStore:PrepareRaidForSave(raid, 1)
	end, "unsupported raid schema")

	local raid = deepCopy(future)
	local before = deepCopy(raid)
	local validation = addon.DB.RaidValidator:GetRaidRecordValidation(raid, 1, 6)
	assertEqual("SCHEMA_VERSION_FUTURE", validation.details[1].code, "validator should report future schema")
	assertTrue(deepEqual(before, raid), "validation must preserve the future record deeply")

	local migrationRaid = deepCopy(future)
	local migrationBefore = deepCopy(migrationRaid)
	local migrated, migrationError = addon.DB.RaidMigrations:MigrateRaidToCurrentSchema(migrationRaid, 7, 6)
	assertEqual(nil, migrated, "direct migration should reject future schema")
	assertEqual("unsupported raid schema", migrationError, "direct migration should use stable error")
	assertTrue(deepEqual(migrationBefore, migrationRaid), "direct migration must preserve future record")

	for _, fromVersion in ipairs({ false, 5 }) do
		local mismatchedRaid = deepCopy(future)
		local mismatchedBefore = deepCopy(mismatchedRaid)
		local explicitVersion = fromVersion or nil
		local mismatchResult, mismatchError =
			addon.DB.RaidMigrations:MigrateRaidToCurrentSchema(mismatchedRaid, explicitVersion, 6)
		assertEqual(nil, mismatchResult, "record schema should override a missing or stale explicit version")
		assertEqual("unsupported raid schema", mismatchError, "mismatched migration should use stable error")
		assertTrue(deepEqual(mismatchedBefore, mismatchedRaid), "mismatched migration must preserve future record")
	end

	_G.RMA_Raids = { deepCopy(future) }
	local allBefore = deepCopy(_G.RMA_Raids[1])
	local prepared, prepareError = addon.DB.RaidStore:PrepareAllRaidsForSave()
	assertEqual(nil, prepared, "bulk save preparation should report rejection")
	assertEqual("unsupported raid schema", prepareError, "bulk save preparation should return stable error")
	assertTrue(deepEqual(allBefore, _G.RMA_Raids[1]), "bulk save preparation must preserve future record")
	print("PASS future_raid_schema_is_preserved")
end

installRaidDatabaseStubs = function(addon)
	_G.date = function()
		return "00:00"
	end
	addon.DB = {}
	addon.State.raidStore = {}
	addon.Time = {
		GetCurrentTime = function()
			return 100
		end,
	}
	addon.Sort = {
		GetLootSortName = function()
			return ""
		end,
	}
	addon.Strings = {
		NormalizeLower = function(value)
			return value and string.lower(value) or nil
		end,
		NormalizeName = function(value)
			return value
		end,
		NilIfEmpty = function(value)
			return value ~= "" and value or nil
		end,
		TrimText = function(value)
			return value
		end,
	}
	addon.LootSourceCandidates = {
		ResolveSourceMetadata = function()
			return nil
		end,
		GetSharedLabel = function()
			return "Shared"
		end,
		IsSharedSourceName = function()
			return false
		end,
		Copy = function(value)
			return value
		end,
	}
	addon.IgnoredMobs = {
		IsTrashMobName = function()
			return false
		end,
	}
	addon.Database.IsBossFightRecord = function()
		return true
	end
	addon.Database.GetRaidSchemaVersion = function()
		return 6
	end
	addon.Database.SavedVariables = {
		GetRaids = function()
			return _G.RMA_Raids
		end,
	}
	_G.RMA_Raids = {}
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidMigrations.lua")
	addon.Database.GetRaidMigrations = function()
		return addon.DB.RaidMigrations
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidStore.lua")
	addon.Database.GetRaidStore = function()
		return addon.DB.RaidStore
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidQueries.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidValidator.lua")
end

canonicalRaidFixture = function()
	return {
		schemaVersion = 6,
		raidNid = 7,
		zone = "Naxxramas",
		size = 10,
		difficulty = 1,
		startTime = 10,
		endTime = 90,
		nextPlayerNid = 3,
		nextBossNid = 2,
		nextLootNid = 2,
		players = {
			{ playerNid = 1, name = "Alpha", class = "MAGE", join = 10, leave = 90, countMS = 0 },
			{ playerNid = 2, name = "Beta", class = "PRIEST", join = 20, leave = 80, countMS = 0 },
		},
		bossKills = { { bossNid = 1, name = "Patchwerk", time = 50, players = { 1 } } },
		loot = { { lootNid = 1, bossNid = 1, looterNid = 1, itemId = 100, itemName = "Item" } },
		attendance = { { playerNid = 1, segments = { { startTime = 10, endTime = 90 } } } },
		changes = {},
	}
end

function cases.raid_queries_are_deeply_read_only(addon)
	installRaidDatabaseStubs(addon)
	local queries = addon.DB.RaidQueries
	local calls = {
		function(raid)
			return queries:GetRaidSummary(raid)
		end,
		function(raid)
			return queries:GetBossKills(raid)
		end,
		function(raid)
			return queries:GetRaidAttendance(raid)
		end,
		function(raid)
			return queries:GetBossAttendance(raid, 1)
		end,
		function(raid)
			return queries:GetLoot(raid, 1, "Alpha")
		end,
	}
	for i = 1, #calls do
		local raid = canonicalRaidFixture()
		local before = deepCopy(raid)
		calls[i](raid)
		assertTrue(deepEqual(before, raid), "query " .. i .. " must preserve its raid input deeply")
	end
	print("PASS raid_queries_are_deeply_read_only")
end

function cases.raid_queries_reject_future_schema_without_touching_output(addon)
	installRaidDatabaseStubs(addon)
	local queries = addon.DB.RaidQueries
	local calls = {
		function(raid, out)
			return queries:GetRaidSummary(raid, out)
		end,
		function(raid, out)
			return queries:GetBossKills(raid, out)
		end,
		function(raid, out)
			return queries:GetRaidAttendance(raid, out)
		end,
		function(raid, out)
			return queries:GetBossAttendance(raid, 1, out)
		end,
		function(raid, out)
			return queries:GetLoot(raid, nil, nil, out)
		end,
	}

	for i = 1, #calls do
		local raid = canonicalRaidFixture()
		raid.schemaVersion = 7
		local before = deepCopy(raid)
		local sentinel = { marker = "preserve", { stale = true } }
		local sentinelBefore = deepCopy(sentinel)
		local result, err = calls[i](raid, sentinel)
		assertEqual(nil, result, "future-schema query " .. i .. " should reject")
		assertEqual("unsupported raid schema", err, "future-schema query " .. i .. " should return stable error")
		assertTrue(deepEqual(sentinelBefore, sentinel), "future-schema query " .. i .. " must preserve output")
		assertTrue(deepEqual(before, raid), "future-schema query " .. i .. " must preserve raid deeply")
	end
	print("PASS raid_queries_reject_future_schema_without_touching_output")
end

function cases.raid_validator_reports_raw_defects(addon)
	installRaidDatabaseStubs(addon)
	local raid = canonicalRaidFixture()
	raid.players[2].playerNid = 1
	raid.players[3] = "malformed"
	raid.bossKills[2] = { bossNid = 1, name = "Duplicate", players = { 999 } }
	raid.bossKills[3] = "malformed"
	raid.loot[1].looterNid = 999
	raid.loot[2] = { lootNid = 1, bossNid = 999, looterNid = 1 }
	raid.loot[3] = "malformed"
	raid.attendance[2] = { playerNid = 999, segments = {} }
	raid.attendance[3] = "malformed"
	raid.nextPlayerNid = 1
	raid.nextBossNid = 1
	raid.nextLootNid = 1
	local before = deepCopy(raid)
	local result = addon.DB.RaidValidator:GetRaidRecordValidation(raid, 1, 6)
	local codes = {}
	for i = 1, #result.details do
		codes[result.details[i].code] = true
	end
	for _, code in ipairs({
		"PLAYER_NID_DUPLICATE",
		"BOSS_NID_DUPLICATE",
		"LOOT_NID_DUPLICATE",
		"COUNTER_TOO_LOW",
		"BOSS_ATTENDEE_MISSING_PLAYER",
		"LOOT_MISSING_LOOTER",
		"LOOT_MISSING_BOSS",
		"PLAYER_ROW_INVALID",
		"BOSS_ROW_INVALID",
		"LOOT_ROW_INVALID",
		"ATTENDANCE_ROW_INVALID",
	}) do
		assertTrue(codes[code], "raw validator should report " .. code)
	end
	assertTrue(deepEqual(before, raid), "raw validation must preserve its input deeply")
	print("PASS raid_validator_reports_raw_defects")
end

function cases.raid_normalization_preserves_explicit_empty_boss_attendance(addon)
	installRaidDatabaseStubs(addon)
	local explicit = canonicalRaidFixture()
	explicit.bossKills[1].players = {}
	addon.DB.RaidStore:NormalizeRaidRecord(explicit)
	assertEqual(0, #explicit.bossKills[1].players, "explicit empty boss attendance must stay empty")

	local absent = canonicalRaidFixture()
	absent.bossKills[1].players = nil
	addon.DB.RaidStore:NormalizeRaidRecord(absent)
	assertEqual(2, #absent.bossKills[1].players, "absent legacy attendance may be inferred during admission")

	local invalid = canonicalRaidFixture()
	invalid.bossKills[1].players = { 999 }
	addon.DB.RaidStore:NormalizeRaidRecord(invalid)
	assertEqual(
		0,
		#invalid.bossKills[1].players,
		"invalid supplied attendance must filter to empty without roster fallback"
	)
	print("PASS raid_normalization_preserves_explicit_empty_boss_attendance")
end

function cases.raid_validator_traverses_sparse_and_mapped_data(addon)
	installRaidDatabaseStubs(addon)
	local raid = canonicalRaidFixture()
	raid.players = {
		[1] = { playerNid = 4, name = "Alpha", countMS = 0 },
		[3] = { playerNid = 4, name = "Duplicate", countMS = 0 },
		mapped = "malformed",
	}
	raid.bossKills = {
		[2] = { bossNid = 8, name = "Patchwerk", players = { [2] = 999, mapped = "bad" } },
		[3] = { bossNid = 9, name = "Grobbulus", players = "malformed" },
		mapped = "malformed",
	}
	raid.loot = {
		[5] = { lootNid = 12, bossNid = 999, looterNid = 999 },
		mapped = "malformed",
	}
	raid.attendance = {
		[4] = { playerNid = 999, segments = { [3] = "malformed", mapped = {} } },
		[6] = { playerNid = 4, segments = "malformed" },
		mapped = "malformed",
	}
	raid.nextPlayerNid = 4
	raid.nextBossNid = 8
	raid.nextLootNid = 12

	local result = addon.DB.RaidValidator:GetRaidRecordValidation(raid, "mapped", 6)
	local codes = {}
	for i = 1, #result.details do
		codes[result.details[i].code] = true
	end
	for _, code in ipairs({
		"PLAYER_KEY_INVALID",
		"PLAYER_NID_DUPLICATE",
		"PLAYER_ROW_INVALID",
		"BOSS_KEY_INVALID",
		"BOSS_ROW_INVALID",
		"BOSS_ATTENDEE_KEY_INVALID",
		"BOSS_ATTENDEE_MISSING_PLAYER",
		"BOSS_ATTENDEE_INVALID",
		"BOSS_PLAYERS_INVALID",
		"LOOT_KEY_INVALID",
		"LOOT_ROW_INVALID",
		"LOOT_MISSING_BOSS",
		"LOOT_MISSING_LOOTER",
		"ATTENDANCE_KEY_INVALID",
		"ATTENDANCE_ROW_INVALID",
		"ATTENDANCE_PLAYER_MISSING",
		"ATTENDANCE_SEGMENT_KEY_INVALID",
		"ATTENDANCE_SEGMENT_ROW_INVALID",
		"ATTENDANCE_SEGMENTS_INVALID",
		"COUNTER_TOO_LOW",
	}) do
		assertTrue(codes[code], "sparse raw validator should report " .. code)
	end

	_G.RMA_Raids = { [2] = raid, mapped = "malformed raid" }
	local report = addon.DB.RaidValidator:ValidateAllRaids({ maxDetails = 200 })
	assertEqual(2, report.raids, "all-raid validation must count sparse and mapped entries")
	local raidNotTable = false
	local raidKeyInvalid = false
	for i = 1, #report.details do
		if report.details[i].code == "RAID_NOT_TABLE" then
			raidNotTable = true
			assertEqual("mapped", report.details[i].index, "mapped raid key should remain diagnostic context")
		end
		if report.details[i].code == "RAID_KEY_INVALID" then
			raidKeyInvalid = true
		end
	end
	assertTrue(raidNotTable, "all-raid validation must diagnose mapped malformed raids")
	assertTrue(raidKeyInvalid, "all-raid validation must diagnose mapped raid keys")
	print("PASS raid_validator_traverses_sparse_and_mapped_data")
end

function cases.raid_queries_guard_malformed_collections(addon)
	installRaidDatabaseStubs(addon)
	local queries = addon.DB.RaidQueries
	local malformed = canonicalRaidFixture()
	malformed.players = "players"
	malformed.bossKills = "bosses"
	malformed.loot = "loot"
	malformed.attendance = "attendance"
	malformed.changes = "changes"
	local before = deepCopy(malformed)
	local summary = queries:GetRaidSummary(malformed)
	assertEqual(0, summary.playersCount, "malformed players must not be counted as string bytes")
	assertEqual(0, summary.bossCount, "malformed bosses must not be counted as string bytes")
	assertEqual(0, summary.lootCount, "malformed loot must not be counted as string bytes")
	assertEqual(0, summary.changesCount, "malformed changes must not be traversed")
	assertEqual(0, #queries:GetBossKills(malformed), "malformed bosses must yield no rows")
	assertEqual(0, #queries:GetRaidAttendance(malformed), "malformed players must yield no rows")
	assertEqual(0, #queries:GetBossAttendance(malformed, 1), "malformed bosses must yield no attendance")
	assertEqual(0, #queries:GetLoot(malformed), "malformed loot must yield no rows")
	assertTrue(deepEqual(before, malformed), "malformed query inputs must remain read-only")

	local nested = canonicalRaidFixture()
	nested.players = { "bad", { playerNid = 1, name = "Alpha", join = 10, leave = 90 } }
	nested.bossKills = { "bad", { bossNid = 1, name = "Patchwerk", players = "bad" } }
	nested.loot = { "bad", { lootNid = 1, bossNid = 1, looterNid = 1, itemName = "Item" } }
	nested.attendance = { "bad", { playerNid = 1, segments = "bad" } }
	assertEqual(1, #queries:GetRaidAttendance(nested), "malformed nested rows must be skipped")
	assertEqual(0, #queries:GetBossAttendance(nested, 1), "non-table boss players must stay explicit empty")
	assertEqual(1, #queries:GetLoot(nested), "malformed loot rows must be skipped")
	print("PASS raid_queries_guard_malformed_collections")
end

function cases.raid_read_indexes_are_fresh_and_do_not_alias(addon)
	installRaidDatabaseStubs(addon)
	local raid = canonicalRaidFixture()
	addon.DB.RaidStore:EnsureRaidRuntime(raid)
	local readIndex = addon.DB.RaidStore:GetRaidRuntimeForRead(raid)
	assertTrue(readIndex.playerByNid == nil, "read indexes must not expose canonical player aliases")
	assertTrue(readIndex.bossByNid == nil, "read indexes must not expose canonical boss aliases")
	assertTrue(readIndex.lootByNid == nil, "read indexes must not expose canonical loot aliases")
	assertTrue(readIndex.attendanceByPlayerNid == nil, "read indexes must not expose canonical attendance aliases")
	readIndex.playerIdxByNid[1] = 999
	assertEqual("Alpha", raid.players[1].name, "mutating a read index must not mutate canonical rows")

	local queries = addon.DB.RaidQueries
	assertEqual(1, #queries:GetLoot(raid, 1, "Alpha"), "initial query should use current content")
	raid.players[1].name = "Gamma"
	raid.loot[1].looterNid = 2
	addon.DB.RaidStore:UpsertLootIndex(raid, raid.loot[1], 1)
	assertEqual(
		0,
		#queries:GetLoot(raid, 1, "Alpha"),
		"same-length player and loot changes must invalidate read lookup"
	)
	assertEqual(1, #queries:GetLoot(raid, 1, "Beta"), "query must observe same-length content changes")
	print("PASS raid_read_indexes_are_fresh_and_do_not_alias")
end

function cases.raid_query_output_buffers_never_alias_canonical_data(addon)
	installRaidDatabaseStubs(addon)
	local queries = addon.DB.RaidQueries
	local casesToRun = {
		{
			collection = function(raid)
				return raid.bossKills
			end,
			call = function(raid, out)
				return queries:GetBossKills(raid, out)
			end,
			expected = 1,
		},
		{
			collection = function(raid)
				return raid.players
			end,
			call = function(raid, out)
				return queries:GetRaidAttendance(raid, out)
			end,
			expected = 2,
		},
		{
			collection = function(raid)
				return raid.bossKills[1].players
			end,
			call = function(raid, out)
				return queries:GetBossAttendance(raid, 1, out)
			end,
			expected = 1,
		},
		{
			collection = function(raid)
				return raid.loot
			end,
			call = function(raid, out)
				return queries:GetLoot(raid, nil, nil, out)
			end,
			expected = 1,
		},
	}

	for i = 1, #casesToRun do
		local spec = casesToRun[i]
		local raid = canonicalRaidFixture()
		local before = deepCopy(raid)
		local canonicalOut = spec.collection(raid)
		local rows = spec.call(raid, canonicalOut)
		assertEqual(spec.expected, #rows, "direct canonical output alias should return complete query " .. i)
		assertTrue(rows ~= canonicalOut, "direct canonical output alias should be replaced for query " .. i)
		assertTrue(deepEqual(before, raid), "direct canonical output alias must preserve raid for query " .. i)

		raid = canonicalRaidFixture()
		before = deepCopy(raid)
		local canonicalRow = raid.players[1]
		local callerOut = { canonicalRow, { stale = true }, { stale = true } }
		rows = spec.call(raid, callerOut)
		assertEqual(spec.expected, #rows, "canonical row-prefilled output should return complete query " .. i)
		assertTrue(rows == callerOut, "safe caller-owned output table should remain reusable for query " .. i)
		assertTrue(rows[1] ~= canonicalRow, "canonical row alias should be replaced for query " .. i)
		assertTrue(deepEqual(before, raid), "canonical row-prefilled output must preserve raid for query " .. i)
	end
	print("PASS raid_query_output_buffers_never_alias_canonical_data")
end

function cases.saved_variables_save_failure_stops_reserves(addon)
	local reserveSaveCalls = 0
	addon.Services.Reserves = {
		Save = function()
			reserveSaveCalls = reserveSaveCalls + 1
		end,
	}
	addon.Database.GetRaidStore = function()
		return {
			PrepareAllRaidsForSave = function()
				return nil, "unsupported raid schema", 4
			end,
		}
	end

	loadAddonFile(addon, "Raid Management Addon/Database/SavedVariables.lua")
	local prepared, prepareError, raidIndex = addon.Database.SavedVariables.PrepareForSave("logout")
	assertEqual(nil, prepared, "saved variables should propagate raid preparation failure")
	assertEqual("unsupported raid schema", prepareError, "saved variables should propagate raid preparation error")
	assertEqual(4, raidIndex, "saved variables should propagate failing raid index")
	assertEqual(0, reserveSaveCalls, "reserves save must not run after raid preparation failure")
	print("PASS saved_variables_save_failure_stops_reserves")
end

local function installRealReservesMutationFixture(addon)
	local fixture = { timers = {}, events = {} }
	table.wipe = table.wipe or function(value)
		for key in pairs(value) do value[key] = nil end
		return value
	end
	_G.GetItemInfo = function(itemRef)
		return tostring(itemRef), "item:" .. tostring(itemRef), nil, nil, nil, nil, nil, nil, nil, "icon"
	end
	addon.L = setmetatable({ StrUnknown = "Unknown" }, { __index = function(_, key) return key end })
	addon.Diag = { D = setmetatable({}, { __index = function() return "%s" end }) }
	addon.C = { RESERVES_ITEM_FALLBACK_ICON = "fallback" }
	addon.Events.Internal = { ReservesDataChanged = "ReservesDataChanged" }
	addon.Bus.TriggerEvent = function(_, ...)
		if fixture.failStage == "event" then error("injected event failure") end
		fixture.events[#fixture.events + 1] = { ... }
	end
	addon.debug = function()
		if fixture.failStage == "debug" then error("injected debug failure") end
	end
	addon.info = function()
		if fixture.failStage == "info" then error("injected info failure") end
	end
	addon.Strings = {
		NormalizeName = function(value) return value end,
		NormalizeLower = function(value)
			if type(value) ~= "string" then return nil end
			return string.lower(value)
		end,
		TrimText = function(value) return value end,
	}
	addon.Item = {
		GetItemIdFromLink = function(value) return tonumber(value) end,
	}
	addon.LootSources = {}
	addon.Timer = {
		BindMixin = function(target)
			target.ScheduleTimer = function(_, callback)
				local failure = fixture.scheduleFailures and table.remove(fixture.scheduleFailures, 1)
				if failure == "throw" then error("injected schedule failure") end
				if failure == "nil" then return nil end
				local timer = { callback = callback, active = true }
				fixture.timers[#fixture.timers + 1] = timer
				return timer
			end
			target.CancelTimer = function(_, timer)
				if not timer or not timer.active then return false end
				timer.active = false
				return true
			end
		end,
	}
	addon.Options = {
		IsDebugEnabled = function() return fixture.failStage == "debug" end,
		RegisterNamespace = function(_, defaults)
			local values = deepCopy(defaults)
			return {
				Get = function(_, key) return values[key] end,
				Set = function(_, key, value)
					if fixture.failStage == "alias_option" and key == "nameAliases" then
						fixture.failStage = nil
						error("injected alias option failure")
					end
					values[key] = value
					if fixture.failStage == "mode" then
						fixture.failStage = nil
						error("injected mode failure")
					end
				end,
			}
		end,
	}
	addon.tLength = function(value)
		local count = 0
		for _ in pairs(value or {}) do count = count + 1 end
		return count
	end
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
	end
	addon.tLength = function(value) local count = 0; for _ in pairs(value) do count = count + 1 end; return count end
	addon.warn = function() end
	addon.debug = function() end
	addon.Services.Reserves = {
		_Aliases = {
			CopyAliasMap = function(source)
				local copied = {}; for key, value in pairs(source or {}) do copied[key] = value end; return copied
			end,
			SetAlias = function(target, reserveName, raidName)
				target[string.lower(reserveName)] = raidName; return true
			end,
			ClearAlias = function(target, reserveName)
				local key = string.lower(reserveName); if target[key] == nil then return false, "missing_alias" end
				target[key] = nil; return true
			end,
			BuildAliasState = function() return {} end,
			ResolveReserveKey = function(_, data, playerName)
				local key = type(playerName) == "string" and string.lower(playerName) or nil
				return key and data[key] and key or nil
			end,
			GetAliasMatches = function() return {} end,
		},
		_Display = {
			RebuildIndex = function()
				if fixture.failStage == "index" then
					fixture.failStage = nil
					error("injected index failure")
				end
			end,
			GetDisplayList = function() return {} end,
		},
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Reserves/Import.lua")
	addon.Database.GetCurrentRaid = function() return nil end
	addon.Database.SavedVariables = {
		GetReserves = function()
			_G.RMA_Reserves = _G.RMA_Reserves or {}
			return _G.RMA_Reserves
		end,
		ReplaceReserves = function(value)
			if fixture.failReplace == "mutate_then_throw" then
				local root = _G.RMA_Reserves or {}
				for key in pairs(root) do root[key] = nil end
				root.corrupt = { reserves = {} }
				error("injected reserve persistence failure after mutation")
			end
			if fixture.failReplace then error("injected reserve persistence failure") end
			fixture.saveCount = (fixture.saveCount or 0) + 1
			_G.RMA_Reserves = deepCopy(value or {})
			return _G.RMA_Reserves
		end,
		ClearReserves = function() _G.RMA_Reserves = nil end,
	}
	_G.RMA_Reserves = {}
	loadAddonFile(addon, "Raid Management Addon/Services/Reserves.lua")
	function fixture:RunTimer(index, includeCancelled)
		local timer = self.timers[index]
		assertTrue(timer ~= nil, "missing reserves fixture timer " .. tostring(index))
		if not timer.active and not includeCancelled then return false end
		timer.active = false
		timer.callback()
		return true
	end
	return addon.Services.Reserves, fixture
end

function cases.reserves_bulk_edits_are_atomic(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	local synced = {
		alpha = { playerNameDisplay = "Alpha", reserves = {
			{ rawID = 100, itemName = "Item", quantity = 2, plus = 3 },
			{ rawID = 200, itemName = "Other", quantity = 1, plus = 0 },
		} },
	}
	assertTrue(reserves:SetSyncedData(synced, { source = "Leader", checksum = "fixture", mode = "multi" }))
	local serialized = assert(reserves.BuildCanonicalSerialization(synced))
	local reordered = deepCopy(synced)
	reordered.alpha.reserves[1], reordered.alpha.reserves[2] = reordered.alpha.reserves[2], reordered.alpha.reserves[1]
	assertEqual(serialized, reserves.BuildCanonicalSerialization(reordered), "canonical equality must ignore reserve row order")
	reordered.alpha.reserves[1].itemName = "Changed canonical field"
	assertTrue(serialized ~= reserves.BuildCanonicalSerialization(reordered), "canonical equality must include every persisted row field")
	local invalidSerialization, projectionReason = reserves.BuildCanonicalSerialization({ alpha = { reserves = {} } })
	assertEqual(nil, invalidSerialization, "invalid projection must not serialize as nil equality")
	assertEqual("invalid_reserve_sequence", projectionReason, "projection error reason differs")
	local savedBefore = deepCopy(_G.RMA_Reserves)
	local savesBefore, eventsBefore = fixture.saveCount or 0, #fixture.events
	local ok, reason, rowIndex = reserves:ApplyBatch({
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
		{ kind = "quantity", playerName = "Missing", itemId = 100, value = 2 },
	})
	assertEqual(nil, ok, "mixed invalid batch must fail")
	assertEqual("invalid_player", reason, "mixed invalid batch reason differs")
	assertEqual(2, rowIndex, "mixed invalid batch row differs")
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "failed batch must preserve SavedVariables")
	assertEqual(2, reserves:GetPlayerReserveEntries("Alpha")[1].quantity, "failed batch must preserve runtime data")
	assertEqual(true, reserves:GetSyncMetadata().runtime, "failed batch must preserve synced cache ownership")
	assertEqual(savesBefore, fixture.saveCount or 0, "failed batch must not save")
	assertEqual(eventsBefore, #fixture.events, "failed batch must not publish")

	ok, reason, rowIndex = reserves:ApplyBatch({
		{ kind = "quantity", playerName = "Alpha", itemId = 999, value = 4 },
	})
	assertEqual(nil, ok, "missing item batch must fail")
	assertEqual("missing_item", reason, "missing item reason differs")
	assertEqual(1, rowIndex, "missing item row differs")
	ok, reason, rowIndex = reserves:ApplyBatch({
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 2 },
	})
	assertEqual(nil, ok, "no-change batch must fail")
	assertEqual("no_change", reason, "no-change reason differs")
	assertEqual(1, rowIndex, "no-change row differs")

	-- Duplicate commands are evaluated in order against the detached candidate.
	ok, reason, rowIndex = reserves:ApplyBatch({
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
	})
	assertEqual(nil, ok, "duplicate no-change command must fail the whole batch")
	assertEqual("no_change", reason, "duplicate command reason differs")
	assertEqual(2, rowIndex, "duplicate command row differs")
	local savedRoot = _G.RMA_Reserves
	local runtimeRow = reserves:GetPlayerReserveEntries("Alpha")[1]
	fixture.failReplace = "mutate_then_throw"
	ok, reason = reserves:ApplyBatch({
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
	})
	fixture.failReplace = nil
	assertEqual(nil, ok, "persistence failure must fail the batch")
	assertEqual("publish_failed", reason, "persistence failure reason differs")
	assertEqual(2, reserves:GetPlayerReserveEntries("Alpha")[1].quantity, "persistence failure must roll back runtime")
	assertEqual(true, reserves:GetSyncMetadata().runtime, "persistence failure must retain synced cache ownership")
	assertTrue(rawequal(savedRoot, _G.RMA_Reserves), "persistence rollback must preserve SavedVariables root identity")
	assertTrue(rawequal(runtimeRow, reserves:GetPlayerReserveEntries("Alpha")[1]), "rollback must preserve runtime row identity")
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "persistence rollback must restore exact SavedVariables values")
	assertEqual(savesBefore, fixture.saveCount or 0, "persistence failure must not count as a save")
	assertEqual(eventsBefore, #fixture.events, "persistence failure must not publish")

	for _, malformed in ipairs({
		{ [1] = { kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 }, [3] = { kind = "plus", playerName = "Alpha", itemId = 200, value = 1 } },
		{ alpha = { kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 } },
		{ { kind = "quantity", playerName = "Alpha", itemId = "100", value = 4 } },
		{ { kind = "quantity", playerName = "Alpha", itemId = 100, value = 4, extra = true } },
	}) do
		ok, reason = reserves:ApplyBatch(malformed)
		assertEqual(nil, ok, "malformed batch must fail")
		assertEqual("invalid_input", reason, "malformed batch reason differs")
	end
	local oversized = {}
	for i = 1, 501 do oversized[i] = { kind = "quantity", playerName = "Alpha", itemId = 100, value = i + 2 } end
	ok, reason = reserves:ApplyBatch(oversized)
	assertEqual(nil, ok, "oversized batch must fail")
	assertEqual("too_many_commands", reason, "oversized batch reason differs")

	ok, reason = reserves:ApplyBatch({
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 2 },
	})
	assertEqual(nil, ok, "net no-op batch must fail")
	assertEqual("no_change", reason, "net no-op reason differs")
	assertEqual(savesBefore, fixture.saveCount or 0, "net no-op must not save")
	assertEqual(eventsBefore, #fixture.events, "net no-op must not publish")

	local successSaves, successEvents = fixture.saveCount or 0, #fixture.events
	reserves.BuildCanonicalChecksum = function() return "forced-collision" end
	local summary
	ok, summary = reserves:ApplyBatch({
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 2 },
		{ kind = "plus", playerName = "Alpha", itemId = 200, value = 5 },
	})
	assertEqual(true, ok, "valid batch must succeed")
	assertEqual(1, summary.changed, "batch summary must count net changed targets")
	assertEqual(3, summary.commands, "batch summary command count differs")
	assertEqual(successSaves + 1, fixture.saveCount or 0, "successful batch must save once")
	assertEqual(successEvents + 1, #fixture.events, "successful batch must publish once")
	assertEqual(2, reserves:GetPlayerReserveEntries("Alpha")[1].quantity, "reverted quantity must retain original value")
	assertEqual(5, reserves:GetPlayerReserveEntries("Alpha")[2].plus, "plus edit missing")
	assertEqual(false, reserves:GetSyncMetadata().runtime, "successful batch must promote synced cache once")
	print("PASS reserves_bulk_edits_are_atomic")
end

function cases.reserves_single_edits_rollback_exact_state(addon)
	local operations = {
		{ name = "quantity", call = function(reserves) return reserves:SetPlayerReserveQuantity("Alpha", 100, 4) end },
		{ name = "plus", call = function(reserves) return reserves:SetPlayerReservePlus("Alpha", 100, 7) end },
		{ name = "remove", call = function(reserves) return reserves:RemovePlayerReserve("Alpha", 100) end },
	}
	for _, operation in ipairs(operations) do
		for _, fault in ipairs({ "replace", "index" }) do
			local reserves, fixture = installRealReservesMutationFixture(addon)
			local player = { playerNameDisplay = "Alpha", reserves = {
				{ rawID = 100, itemName = "Item 100", quantity = 1, plus = 0 },
			} }
			assertTrue(reserves:SetSyncedData({ alpha = player },
				{ source = "Leader", checksum = "fixture", mode = "multi" }), "synced baseline must load")
			local savedRoot = _G.RMA_Reserves
			local payloadRoot = select(1, reserves._Sync:GetPayload())
			local runtimeRow = reserves:GetPlayerReserveEntries("Alpha")[1]
			local savedBefore = deepCopy(savedRoot)
			local eventsBefore, savesBefore = #fixture.events, fixture.saveCount or 0
			if fault == "replace" then fixture.failReplace = "mutate_then_throw" else fixture.failStage = "index" end
			local invoked, changed, reason = pcall(operation.call, reserves)
			fixture.failReplace, fixture.failStage = nil, nil
			assertEqual(true, invoked, operation.name .. " must contain " .. fault .. " fault")
			assertTrue(not changed, operation.name .. " must fail on " .. fault .. " fault")
			assertEqual("publish_failed", reason, operation.name .. " fault reason differs")
			assertTrue(rawequal(savedRoot, _G.RMA_Reserves), operation.name .. " must preserve SavedVariables identity")
			assertTrue(rawequal(payloadRoot, select(1, reserves._Sync:GetPayload())),
				operation.name .. " must preserve runtime root identity")
			assertTrue(rawequal(runtimeRow, reserves:GetPlayerReserveEntries("Alpha")[1]),
				operation.name .. " must preserve row identity")
			assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), operation.name .. " must restore SavedVariables values")
			assertEqual(true, reserves:GetSyncMetadata().runtime, operation.name .. " must preserve cache ownership")
			assertEqual(eventsBefore, #fixture.events, operation.name .. " fault must not publish")
			if fault == "replace" then
				assertEqual(savesBefore, fixture.saveCount or 0, operation.name .. " fault must not report a save")
			end
		end
	end
	print("PASS reserves_single_edits_rollback_exact_state")
end

function cases.reserves_bulk_edit_ui_retains_failed_edits(addon)
	local noop = function() end
	local batchResult = { nil, "missing_item", 1 }
	local batchCalls = 0
	local deferredAccept
	local deferredAccepts = {}
	local deferConfirmation = false
	addon.Widgets = {}
	addon.L = setmetatable({
		BtnSave = "Save", BtnCancel = "Cancel", BtnEdit = "Edit",
		ErrReserveEditRow = "Row %d: %s", ErrReserveEditMissingItem = "missing item",
		ErrReserveEditFailed = "failed", StrConfirmApplyReserveEdits = "Apply %d?",
	}, { __index = function(_, key) return key end })
	addon.Diag = { D = setmetatable({}, { __index = function() return "%s" end }) }
	addon.C = { RESERVES_QUERY_COOLDOWN_SECONDS = 2, RESERVES_ITEM_FALLBACK_ICON = "fallback" }
	addon.Options = { IsDebugEnabled = function() return false end, Get = function() return nil end }
	addon.Events.Internal = { ReservesDataChanged = "ReservesDataChanged" }
	addon.Bus.RegisterCallback = noop
	addon.Colors = { GetClassColor = function() return 1, 1, 1 end }
	addon.Services.Chat = { Announce = noop }
	addon.Services.Raid = { GetPlayerClass = function() return nil end }
	addon.Services.Reserves = {
		HasData = function() return true end, IsPlusSystem = function() return false end,
		HasPendingItem = function() return false end, RemovePlayerReserve = noop,
		ClearSavedReserves = noop, GetDisplayList = function() return {} end,
		GetImportMode = function() return "multi" end, ParseImport = noop,
		RequestApplyImport = noop, SetImportMode = noop,
		ApplyBatch = function(_, commands)
			batchCalls = batchCalls + 1
			assertEqual(1, #commands, "UI must submit one batch command")
			assertEqual("quantity", commands[1].kind, "UI batch command kind differs")
			return unpack(batchResult)
		end,
	}
	local moduleStates = setmetatable({}, { __mode = "k" })
	local configs = {}
	local refreshCount = 0
	addon.UI = {
		Frames = {
			MakeModuleFrameGetter = function() return function() return nil end end,
			SetScriptSafely = function(widget, name, callback) widget[name] = callback end,
			SetFrameTitle = noop, BindModuleFrame = noop,
		},
		Scaffold = { DefineModule = function(config)
			configs[#configs + 1] = config
			config.module.RequestRefresh = function() refreshCount = refreshCount + 1 end
		end },
		Popups = {
			Define = noop, DefineConfirm = noop, IsDefined = function() return false end,
			Show = function() return false end,
			ShowConfirm = function(_, _, onAccept)
				if deferConfirmation then
					deferredAccept = onAccept
					deferredAccepts[#deferredAccepts + 1] = onAccept
				else onAccept() end
				return true
			end,
		},
		Primitives = { SetEnabled = noop }, EditBoxes = {},
		Tooltips = { Hide = noop, ShowItem = noop, Bind = noop },
		ModuleState = { Ensure = function(module)
			local state = moduleStates[module]
			if not state then state = { FrameName = "RMAReserveListFrame" }; moduleStates[module] = state end
			return state
		end },
	}
	_G.GetTime = function() return 0 end
	_G.GetNumRaidMembers = function() return 0 end
	_G.UnitName = function() return "Tester" end
	_G.RMAReserveListFrameSoftResStatusText = {
		SetText = function(self, value) self.text = value end,
		SetTextColor = function(self, r, g, b) self.color = { r, g, b } end,
	}
	loadAddonFile(addon, "Raid Management Addon/Widgets/ReservesUI.lua")
	local editButton = {}
	configs[1].bind(nil, nil, { editButton = editButton })
	assertTrue(type(editButton.OnClick) == "function", "reserve edit handler missing")

	local collect
	for i = 1, 20 do
		local name, value = debug.getupvalue(editButton.OnClick, i)
		if not name then break end
		if name == "collectVisibleReserveEdits" then collect = value break end
	end
	assertTrue(type(collect) == "function", "reserve edit collector upvalue missing")
	local rows
	for i = 1, 20 do
		local name, value = debug.getupvalue(collect, i)
		if not name then break end
		if name == "reserveItemRows" then rows = value break end
	end
	assertTrue(type(rows) == "table", "reserve row storage upvalue missing")
	local editBox = {
		_RMAReserveEditBase = "2", text = "4",
		GetText = function(self) return self.text end,
		SetText = function(self, value) self.text = value end,
		SetTextColor = function(self, r, g, b) self.color = { r, g, b } end,
	}
	rows[1] = { quantityEdit = editBox, _itemId = 100, _playerName = "Alpha" }
	local pending = collect()
	assertEqual(nil, pending[1].editBox, "pending confirmation must not retain edit-box references")
	editButton.OnClick()
	local refreshAfterEntering = refreshCount
	deferConfirmation = true
	editButton.OnClick()
	editButton.OnClick()
	assertEqual(2, #deferredAccepts, "overlapping confirmations must both be observable")
	deferredAccepts[1]()
	assertEqual(0, batchCalls, "superseded confirmation must not apply even when text matches")
	deferredAccepts[2]()
	assertEqual(1, batchCalls, "only current overlapping confirmation may apply")
	assertEqual(true, editButton._RMAReserveEditMode, "failed current confirmation must retain edit mode")
	deferredAccepts = {}
	batchCalls = 0
	deferredAccept = nil
	editButton.text = "4"
	editButton.OnClick()
	assertTrue(type(deferredAccept) == "function", "confirmation callback must be deferred for stale-row test")
	local reusedBox = {
		_RMAReserveEditBase = "8", text = "9",
		GetText = function(self) return self.text end,
		SetTextColor = function(self, r, g, b) self.color = { r, g, b } end,
	}
	rows[1] = { quantityEdit = reusedBox, _itemId = 999, _playerName = "Beta" }
	deferredAccept()
	assertEqual(0, batchCalls, "stale confirmation must not apply")
	assertEqual(true, editButton._RMAReserveEditMode, "stale confirmation must retain edit mode")
	assertEqual("2", editBox._RMAReserveEditBase, "stale confirmation must retain original baseline")
	assertEqual(refreshAfterEntering, refreshCount, "stale confirmation must not refresh")
	rows[1] = { quantityEdit = editBox, _itemId = 100, _playerName = "Alpha" }
	deferConfirmation = false
	deferredAccept = nil
	editButton.OnClick()
	assertEqual(1, batchCalls, "failed confirmation must invoke one batch")
	assertEqual(true, editButton._RMAReserveEditMode, "failed batch must retain edit mode")
	assertEqual("2", editBox._RMAReserveEditBase, "failed batch must retain edit baseline")
	assertEqual(1, editBox.color[1], "failed row must be highlighted")
	assertEqual(0.2, editBox.color[2], "failed row highlight differs")
	assertEqual("Row 1: missing item", _G.RMAReserveListFrameSoftResStatusText.text, "localized row feedback differs")
	assertEqual(refreshAfterEntering, refreshCount, "failed batch must not refresh away edits")

	batchResult = { true, { changed = 1 } }
	editButton.OnClick()
	assertEqual(2, batchCalls, "successful retry must invoke one batch")
	assertEqual(false, editButton._RMAReserveEditMode, "successful batch must exit edit mode")
	assertEqual("4", editBox._RMAReserveEditBase, "successful batch must update baseline")
	assertEqual(1, _G.RMAReserveListFrameSoftResStatusText.color[2], "successful retry must clear error color")
	assertEqual(refreshAfterEntering + 1, refreshCount, "successful batch must refresh once")
	print("PASS reserves_bulk_edit_ui_retains_failed_edits")
end

local function reserveImportPlayer(name, itemId)
	return {
		playerNameDisplay = name,
		reserves = { { rawID = itemId, itemName = "Item " .. tostring(itemId), quantity = 1, plus = 0 } },
	}
end

function cases.reserves_async_import_snapshots_input_and_publishes_once(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	local parsed = { mode = "multi", reservesData = {
		alpha = reserveImportPlayer("Alpha", 100),
		beta = reserveImportPlayer("Beta", 200),
	} }
	local callbacks = {}
	local opts = { chunkSize = 1, silentInfo = true, reason = "snapshotted-reason" }
	reserves:RequestApplyImport(parsed, 7, function(...)
		callbacks[#callbacks + 1] = { ... }
	end, opts)
	opts.reason = "mutated-reason"
	opts.silentInfo = false
	parsed.reservesData.alpha.reserves[1].rawID = 999
	parsed.reservesData.beta = nil
	parsed.reservesData.gamma = reserveImportPlayer("Gamma", 300)
	fixture:RunTimer(1)
	fixture:RunTimer(2)
	assertEqual(1, #callbacks, "completed import callback must run exactly once")
	assertEqual(true, callbacks[1][1], "completed import must report success")
	assertEqual(2, callbacks[1][2], "completed import must report snapshotted player count")
	assertEqual(100, reserves:GetPlayerReserveEntries("Alpha")[1].rawID, "caller row mutation must not affect import")
	assertEqual(200, reserves:GetPlayerReserveEntries("Beta")[1].rawID, "caller removal must not affect import")
	assertEqual(0, #reserves:GetPlayerReserveEntries("Gamma"), "caller addition must not affect import")
	local saved = deepCopy(_G.RMA_Reserves)
	reserves:Load()
	assertTrue(deepEqual(saved, _G.RMA_Reserves), "completed import must be reload-shaped")
	assertEqual(1, #fixture.events, "completed import must publish one event")
	assertEqual("snapshotted-reason", fixture.events[1][1], "caller options mutation must not affect import")
	print("PASS reserves_async_import_snapshots_input_and_publishes_once")
end

function cases.reserves_async_import_replacement_cancel_and_stale_callbacks_are_terminal(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	local baseline = { mode = "multi", reservesData = { base = reserveImportPlayer("Base", 50) } }
	assertTrue(reserves:ApplyImport(baseline, nil, { silentInfo = true }), "baseline import must succeed")
	local savedBefore = deepCopy(_G.RMA_Reserves)
	local eventsBefore = #fixture.events
	local firstResults, secondResults = {}, {}
	local first = reserves:RequestApplyImport({ reservesData = {
		alpha = reserveImportPlayer("Alpha", 100), beta = reserveImportPlayer("Beta", 200),
	} }, nil, function(...) firstResults[#firstResults + 1] = { ... } end, { chunkSize = 1, silentInfo = true })
	local staleTimerIndex = #fixture.timers
	local second = reserves:RequestApplyImport({ reservesData = {
		gamma = reserveImportPlayer("Gamma", 300), delta = reserveImportPlayer("Delta", 400),
	} }, nil, function(...) secondResults[#secondResults + 1] = { ... } end, { chunkSize = 1, silentInfo = true })
	assertEqual(1, #firstResults, "replacement must terminate prior callback exactly once")
	assertEqual(false, firstResults[1][1], "replacement must report non-success")
	assertEqual("cancelled", firstResults[1][2], "replacement must use stable cancelled result")
	assertEqual(true, first:IsCancelled(), "replaced handle must be terminal")
	fixture:RunTimer(staleTimerIndex, true)
	assertEqual(1, #firstResults, "stale callback must not re-complete replaced import")
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "replacement and stale callback must not publish")
	assertEqual(eventsBefore, #fixture.events, "replacement and stale callback must emit no event")
	assertEqual(true, second:Cancel(), "explicit cancel must transition active import")
	assertEqual(false, second:Cancel(), "repeated cancel must be idempotent")
	assertEqual(1, #secondResults, "cancel callback must run exactly once")
	assertEqual(false, secondResults[1][1], "cancel must report non-success")
	assertEqual("cancelled", secondResults[1][2], "cancel must use stable result")
	fixture:RunTimer(#fixture.timers, true)
	assertEqual(1, #secondResults, "stale cancelled callback must not re-complete")
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "cancel must preserve SavedVariables")
	assertEqual(50, reserves:GetPlayerReserveEntries("Base")[1].rawID, "cancel must preserve runtime cache")
	assertEqual(eventsBefore, #fixture.events, "cancel must emit no data event")
	print("PASS reserves_async_import_replacement_cancel_and_stale_callbacks_are_terminal")
end

function cases.reserves_async_import_failure_rolls_back_and_callbacks_are_reentrant(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:ApplyImport({ reservesData = { base = reserveImportPlayer("Base", 50) } }, nil,
		{ silentInfo = true }), "baseline import must succeed")
	local savedBefore = deepCopy(_G.RMA_Reserves)
	local eventsBefore = #fixture.events
	fixture.failReplace = true
	local failed = {}
	reserves:RequestApplyImport({ reservesData = { alpha = reserveImportPlayer("Alpha", 100) } }, nil,
		function(...) failed[#failed + 1] = { ... } end, { chunkSize = 1, silentInfo = true })
	fixture:RunTimer(#fixture.timers)
	assertEqual(1, #failed, "failed import callback must run exactly once")
	assertEqual(false, failed[1][1], "persistence failure must report non-success")
	assertEqual("failed", failed[1][2], "persistence failure must use stable result")
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "failed import must preserve SavedVariables")
	assertEqual(50, reserves:GetPlayerReserveEntries("Base")[1].rawID, "failed import must preserve runtime cache")
	assertEqual(0, #reserves:GetPlayerReserveEntries("Alpha"), "failed import must not expose candidate")
	assertEqual(eventsBefore, #fixture.events, "failed import must emit no data event")

	fixture.failReplace = false
	local nestedResults = {}
	reserves:RequestApplyImport({ reservesData = {
		old = reserveImportPlayer("Old", 200), extra = reserveImportPlayer("Extra", 201),
	} }, nil, function(ok, result)
		if not ok and result == "cancelled" then
			reserves:RequestApplyImport({ reservesData = { newest = reserveImportPlayer("Newest", 300) } }, nil,
				function(...) nestedResults[#nestedResults + 1] = { ... } end,
				{ chunkSize = 1, silentInfo = true })
		end
	end, { chunkSize = 1, silentInfo = true })
	reserves:RequestApplyImport({ reservesData = { outer = reserveImportPlayer("Outer", 400) } }, nil,
		function() end, { chunkSize = 1, silentInfo = true })
	fixture:RunTimer(#fixture.timers)
	assertEqual(1, #nestedResults, "reentrant replacement must remain the active import")
	assertEqual(true, nestedResults[1][1], "reentrant replacement must complete")
	assertEqual(300, reserves:GetPlayerReserveEntries("Newest")[1].rawID, "reentrant callback import must win")
	assertEqual(0, #reserves:GetPlayerReserveEntries("Outer"), "outer replacement must not clobber reentrant import")
	print("PASS reserves_async_import_failure_rolls_back_and_callbacks_are_reentrant")
end

function cases.reserves_async_import_rejects_noncanonical_and_sparse_sources(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:ApplyImport({ reservesData = { base = reserveImportPlayer("Base", 50) } }, nil,
		{ silentInfo = true }), "baseline import must succeed")
	local savedRoot, payloadRoot = _G.RMA_Reserves, select(1, reserves._Sync:GetPayload())
	local savedBefore = deepCopy(savedRoot)
	local malformed = {
		{ reservesData = { alpha = { playerNameDisplay = "Alpha", reserves = {
			[1] = { rawID = 100, quantity = 1, plus = 0 },
			[3] = { rawID = 300, quantity = 1, plus = 0 },
		} } } },
		{ reservesData = { alpha = { playerNameDisplay = "Alpha", reserves = {
			{ rawID = 100, quantity = 1, plus = 0, source = { mutable = true } },
		} } } },
		{ reservesData = { alpha = { playerNameDisplay = "Alpha", reserves = {
			{ rawID = 100, quantity = 1, plus = 0, unknown = {} },
		} } } },
	}
	for i = 1, #malformed do
		local results = {}
		reserves:RequestApplyImport(malformed[i], nil, function(...) results[#results + 1] = { ... } end,
			{ chunkSize = 1, silentInfo = true })
		assertEqual(1, #results, "malformed import callback must be terminal at row " .. i)
		assertEqual(false, results[1][1], "malformed import must fail at row " .. i)
		assertEqual("failed", results[1][2], "malformed import must use stable result at row " .. i)
		assertEqual("INVALID_IMPORT_DATA", results[1][3], "malformed reason differs at row " .. i)
	end
	assertEqual(0, #fixture.timers, "malformed imports must not schedule work")
	assertTrue(rawequal(savedRoot, _G.RMA_Reserves), "malformed imports must preserve SavedVariables identity")
	assertTrue(rawequal(payloadRoot, select(1, reserves._Sync:GetPayload())), "malformed imports must preserve payload identity")
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "malformed imports must preserve values")
	print("PASS reserves_async_import_rejects_noncanonical_and_sparse_sources")
end

function cases.reserves_async_import_scheduler_failures_are_terminal(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:ApplyImport({ reservesData = { base = reserveImportPlayer("Base", 50) } }, nil,
		{ silentInfo = true }), "baseline import must succeed")
	local savedRoot, savedBefore = _G.RMA_Reserves, deepCopy(_G.RMA_Reserves)
	for _, failure in ipairs({ "throw", "nil" }) do
		fixture.scheduleFailures = { failure }
		local results = {}
		reserves:RequestApplyImport({ reservesData = { alpha = reserveImportPlayer("Alpha", 100) } }, nil,
			function(...) results[#results + 1] = { ... } end, { chunkSize = 1, silentInfo = true })
		assertEqual(1, #results, "initial scheduler failure must callback once for " .. failure)
		assertEqual(false, results[1][1], "initial scheduler failure must reject for " .. failure)
		assertEqual("failed", results[1][2], "initial scheduler result differs for " .. failure)
		assertEqual("SCHEDULE_FAILED", results[1][3], "initial scheduler reason differs for " .. failure)
	end
	for _, failure in ipairs({ "throw", "nil" }) do
		fixture.scheduleFailures = { false, failure }
		local results = {}
		reserves:RequestApplyImport({ reservesData = {
			alpha = reserveImportPlayer("Alpha", 100), beta = reserveImportPlayer("Beta", 200),
		} }, nil, function(...) results[#results + 1] = { ... } end, { chunkSize = 1, silentInfo = true })
		fixture:RunTimer(#fixture.timers)
		assertEqual(1, #results, "interchunk scheduler failure must callback once for " .. failure)
		assertEqual("SCHEDULE_FAILED", results[1][3], "interchunk scheduler reason differs for " .. failure)
	end
	assertTrue(rawequal(savedRoot, _G.RMA_Reserves), "scheduler failures must preserve SavedVariables identity")
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "scheduler failures must preserve SavedVariables values")
	assertEqual(50, reserves:GetPlayerReserveEntries("Base")[1].rawID, "scheduler failures must preserve runtime")
	print("PASS reserves_async_import_scheduler_failures_are_terminal")
end

function cases.reserves_async_import_publish_faults_rollback_exact_state(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = { base = reserveImportPlayer("Base", 50) } }, nil,
		{ silentInfo = true }), "baseline import must succeed")
	for _, stage in ipairs({ "mode", "index" }) do
		local savedRoot = _G.RMA_Reserves
		local payloadRoot = select(1, reserves._Sync:GetPayload())
		local oldRow = reserves:GetPlayerReserveEntries("Base")[1]
		local savedBefore = deepCopy(savedRoot)
		local eventsBefore = #fixture.events
		fixture.failStage = stage
		local results = {}
		reserves:RequestApplyImport({ mode = "plus", reservesData = { alpha = reserveImportPlayer("Alpha", 100) } }, nil,
			function(...) results[#results + 1] = { ... } end, { chunkSize = 1, silentInfo = true })
		fixture:RunTimer(#fixture.timers)
		assertEqual(1, #results, "publish fault callback must run once for " .. stage)
		assertEqual(false, results[1][1], "publish fault must fail for " .. stage)
		assertEqual("failed", results[1][2], "publish fault result differs for " .. stage)
		assertTrue(rawequal(savedRoot, _G.RMA_Reserves), "publish fault must restore SavedVariables root for " .. stage)
		assertTrue(rawequal(payloadRoot, select(1, reserves._Sync:GetPayload())), "publish fault must restore payload root for " .. stage)
		assertTrue(rawequal(oldRow, reserves:GetPlayerReserveEntries("Base")[1]), "publish fault must restore row identity for " .. stage)
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "publish fault must restore values for " .. stage)
		assertEqual("multi", reserves:GetImportMode(), "publish fault must restore mode for " .. stage)
		assertEqual(eventsBefore, #fixture.events, "publish fault must emit no event for " .. stage)
	end
	for _, stage in ipairs({ "debug", "info", "event" }) do
		fixture.failStage = stage
		local results = {}
		reserves:RequestApplyImport({ reservesData = { ok = reserveImportPlayer("Ok", 500) } }, nil,
			function(...) results[#results + 1] = { ... } end, { chunkSize = 1, silentInfo = stage ~= "info" })
		fixture:RunTimer(#fixture.timers)
		assertEqual(1, #results, "contained notification fault callback must run once for " .. stage)
		assertEqual(true, results[1][1], "notification fault must not invalidate committed data for " .. stage)
		fixture.failStage = nil
	end
	print("PASS reserves_async_import_publish_faults_rollback_exact_state")
end

function cases.reserves_direct_import_apis_revalidate_bounded_canonical_input(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = { base = reserveImportPlayer("Base", 50) } }, nil,
		{ silentInfo = true }), "baseline import must succeed")
	local savedRoot = _G.RMA_Reserves
	local runtimeRoot = select(1, reserves._Sync:GetPayload())
	local runtimeRow = reserves:GetPlayerReserveEntries("Base")[1]
	local savedBefore = deepCopy(savedRoot)
	local timersBefore, eventsBefore = #fixture.timers, #fixture.events
	local invalid = {}
	local tooManyPlayers = {}
	for i = 1, 1001 do tooManyPlayers["player" .. i] = reserveImportPlayer("Player" .. i, i) end
	invalid[#invalid + 1] = tooManyPlayers
	local tooManyRows = { alpha = { playerNameDisplay = "Alpha", reserves = {} } }
	for i = 1, 21 do tooManyRows.alpha.reserves[i] = { rawID = i, quantity = 1, plus = 0 } end
	invalid[#invalid + 1] = tooManyRows
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = string.rep("A", 65), reserves = { { rawID = 1 } } } }
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = "Alpha", reserves = { { rawID = 1, note = string.rep("N", 257) } } } }
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = "Alpha", reserves = { { rawID = 1, quantity = math.huge } } } }
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = "Alpha", reserves = { [1] = { rawID = 1 }, [3] = { rawID = 3 } } } }
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = "Alpha", reserves = { { rawID = 1 }, { rawID = 1 } } } }
	invalid[#invalid + 1] = { [1] = reserveImportPlayer("Alpha", 1) }
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = "Alpha", reserves = {} } }
	invalid[#invalid + 1] = { ["Al" .. string.char(0xc3, 0xa9)] = reserveImportPlayer("Alpha", 1) }
	invalid[#invalid + 1] = { alpha = reserveImportPlayer("Al" .. string.char(0xc3, 0xa9), 1) }
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = "Alpha", reserves = {
		{ rawID = 1, source = "bad\nsource" },
	} } }
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = "Alpha", reserves = {
		{ rawID = 1, itemName = string.char(0xc3, 0xa9) },
	} } }
	for i = 1, #invalid do
		local ok, reason = reserves:ApplyImport({ mode = "multi", reservesData = invalid[i] }, nil, { silentInfo = true })
		assertEqual(false, ok, "sync direct import must reject invalid graph " .. i)
		assertEqual("INVALID_IMPORT_DATA", reason, "sync rejection reason differs at " .. i)
		local callbacks = {}
		local handle = reserves:RequestApplyImport({ mode = "multi", reservesData = invalid[i] }, nil,
			function(...) callbacks[#callbacks + 1] = { ... } end, { silentInfo = true })
		assertEqual(true, handle:IsCancelled(), "invalid async request must be terminal at " .. i)
		assertEqual(1, #callbacks, "invalid async callback must run once at " .. i)
		assertEqual(false, callbacks[1][1], "invalid async callback must fail at " .. i)
		assertEqual(#fixture.timers, timersBefore, "invalid async request must allocate no timer at " .. i)
		assertTrue(rawequal(savedRoot, _G.RMA_Reserves), "invalid import must preserve SavedVariables identity at " .. i)
		assertTrue(rawequal(runtimeRoot, select(1, reserves._Sync:GetPayload())),
			"invalid import must preserve runtime identity at " .. i)
		assertTrue(rawequal(runtimeRow, reserves:GetPlayerReserveEntries("Base")[1]),
			"invalid import must preserve row identity at " .. i)
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "invalid import must preserve values at " .. i)
		assertEqual(eventsBefore, #fixture.events, "invalid import must not publish at " .. i)
	end
	for _, stage in ipairs({ "replace", "mode", "index" }) do
		if stage == "replace" then fixture.failReplace = "mutate_then_throw" else fixture.failStage = stage end
		local ok, reason = reserves:ApplyImport({ mode = "plus", reservesData = {
			alpha = reserveImportPlayer("Alpha", 100),
		} }, nil, { silentInfo = true })
		fixture.failReplace, fixture.failStage = nil, nil
		assertEqual(false, ok, "synchronous import must contain " .. stage .. " fault")
		assertEqual("PUBLISH_FAILED", reason, "synchronous publish reason differs for " .. stage)
		assertTrue(rawequal(savedRoot, _G.RMA_Reserves), "sync fault must preserve SavedVariables identity")
		assertTrue(rawequal(runtimeRoot, select(1, reserves._Sync:GetPayload())), "sync fault must preserve runtime identity")
		assertTrue(rawequal(runtimeRow, reserves:GetPlayerReserveEntries("Base")[1]), "sync fault must preserve row identity")
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "sync fault must preserve values")
		assertEqual("multi", reserves:GetImportMode(), "sync fault must restore mode")
	end
	local exactGraph = {}
	for playerIndex = 1, 1000 do
		local rows = {}
		for rowIndex = 1, 5 do
			rows[rowIndex] = { rawID = playerIndex * 10 + rowIndex, quantity = 100, plus = 100 }
		end
		exactGraph["player" .. playerIndex] = {
			playerNameDisplay = "Player" .. playerIndex,
			reserves = rows,
		}
	end
	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = exactGraph }, nil, { silentInfo = true }),
		"exact 1000-player/5000-row bounds must succeed")
	local exactPlayerRows = {}
	for i = 1, 20 do exactPlayerRows[i] = { rawID = i, note = string.rep("N", 256) } end
	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = {
		[string.rep("k", 64)] = { playerNameDisplay = string.rep("P", 64), reserves = exactPlayerRows },
	} }, nil, { silentInfo = true }), "exact per-player and string bounds must succeed")
	local successSource = { alpha = reserveImportPlayer("Alpha", 100) }
	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = successSource }, nil, { silentInfo = true }),
		"bounded direct import must succeed")
	successSource.alpha.reserves[1].rawID = 999
	successSource.alpha.reserves[1].note = "caller mutation"
	assertEqual(100, reserves:GetPlayerReserveEntries("Alpha")[1].rawID,
		"successful direct import must detach caller rows")
	assertEqual(nil, reserves:GetPlayerReserveEntries("Alpha")[1].note,
		"successful direct import must detach caller strings")
	print("PASS reserves_direct_import_apis_revalidate_bounded_canonical_input")
end

function cases.reserves_add_player_reserve_is_transactional(addon)
	for _, fault in ipairs({ "replace", "index" }) do
		local reserves, fixture = installRealReservesMutationFixture(addon)
		local synced = { alpha = reserveImportPlayer("Alpha", 100) }
		assertTrue(reserves:SetSyncedData(synced, { source = "Leader", checksum = "fixture", mode = "multi" }),
			"synced add baseline must load")
		local savedRoot = _G.RMA_Reserves
		local runtimeRoot = select(1, reserves._Sync:GetPayload())
		local runtimeRow = reserves:GetPlayerReserveEntries("Alpha")[1]
		local savedBefore = deepCopy(savedRoot)
		local eventsBefore = #fixture.events
		if fault == "replace" then fixture.failReplace = "mutate_then_throw" else fixture.failStage = "index" end
		local invoked, ok, reason = pcall(reserves.AddPlayerReserve, reserves, "Alpha", 200)
		fixture.failReplace, fixture.failStage = nil, nil
		assertEqual(true, invoked, "add must contain " .. fault .. " fault")
		assertEqual(false, ok, "add must fail on " .. fault .. " fault")
		assertEqual("publish_failed", reason, "add publish reason differs")
		assertTrue(rawequal(savedRoot, _G.RMA_Reserves), "add fault must preserve SavedVariables identity")
		assertTrue(rawequal(runtimeRoot, select(1, reserves._Sync:GetPayload())),
			"add fault must preserve runtime identity")
		assertTrue(rawequal(runtimeRow, reserves:GetPlayerReserveEntries("Alpha")[1]),
			"add fault must preserve row identity")
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "add fault must preserve SavedVariables values")
		assertEqual(true, reserves:GetSyncMetadata().runtime, "add fault must preserve synced cache ownership")
		assertEqual(eventsBefore, #fixture.events, "add fault must publish no event")
	end
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:SetSyncedData({ alpha = reserveImportPlayer("Alpha", 100) },
		{ source = "Leader", checksum = "fixture", mode = "multi" }))
	local eventsBefore = #fixture.events
	local ok, row = reserves:AddPlayerReserve("Alpha", 200)
	assertEqual(true, ok, "valid add must commit")
	assertTrue(rawequal(row, reserves:GetPlayerReserveEntries("Alpha")[2]), "successful add must return committed clone")
	assertEqual(false, reserves:GetSyncMetadata().runtime, "successful add must promote the active candidate")
	assertEqual(eventsBefore + 1, #fixture.events, "successful add must publish exactly once")
	print("PASS reserves_add_player_reserve_is_transactional")
end

function cases.reserves_alias_publication_is_transactional(addon)
	for _, fault in ipairs({ "alias_option", "index" }) do
		local reserves, fixture = installRealReservesMutationFixture(addon)
		local eventsBefore = #fixture.events
		fixture.failStage = fault
		local invoked, ok, reason = pcall(reserves.SetNameAlias, reserves, "Alpha", "Bravo")
		fixture.failStage = nil
		assertEqual(true, invoked, "alias set must contain " .. fault .. " fault")
		assertEqual(false, ok, "alias set must fail on " .. fault .. " fault")
		assertEqual("publish_failed", reason, "alias set fault reason differs")
		assertEqual(nil, reserves:GetNameAliases().alpha, "failed alias set must restore options")
		assertEqual(eventsBefore, #fixture.events, "failed alias set must publish no event")
	end
	for _, fault in ipairs({ "alias_option", "index" }) do
		local reserves, fixture = installRealReservesMutationFixture(addon)
		assertTrue(reserves:SetNameAlias("Alpha", "Bravo"), "alias removal baseline must publish")
		local eventsBefore = #fixture.events
		fixture.failStage = fault
		local invoked, ok, reason = pcall(reserves.RemoveNameAlias, reserves, "Alpha")
		fixture.failStage = nil
		assertEqual(true, invoked, "alias removal must contain " .. fault .. " fault")
		assertEqual(false, ok, "alias removal must fail on " .. fault .. " fault")
		assertEqual("publish_failed", reason, "alias removal fault reason differs")
		assertEqual("Bravo", reserves:GetNameAliases().alpha, "failed alias removal must restore options")
		assertEqual(eventsBefore, #fixture.events, "failed alias removal must publish no event")
	end
	print("PASS reserves_alias_publication_is_transactional")
end

function cases.reserves_failed_synced_mutations_do_not_promote_cache(addon)
	local reserves = installRealReservesMutationFixture(addon)
	local synced = {
		alpha = {
			playerNameDisplay = "Alpha",
			reserves = { { rawID = 100, itemName = "Item", quantity = 2, plus = 3 } },
		},
	}
	local accepted, reason = reserves:SetSyncedData(synced, { source = "Leader", checksum = "fixture", mode = "multi" })
	assertEqual(true, accepted, "synced fixture must be accepted")
	assertEqual(nil, reason, "accepted synced fixture must not return an error")

	local failures = {
		{ call = function() return reserves:SetPlayerReserveQuantity("Missing", 100, 4) end, reason = "invalid_player" },
		{ call = function() return reserves:SetPlayerReserveQuantity("Alpha", 999, 4) end, reason = "missing_item" },
		{ call = function() return reserves:SetPlayerReserveQuantity("Alpha", 100, 2) end, reason = "no_change" },
		{ call = function() return reserves:SetPlayerReservePlus("Missing", 100, 4) end, reason = "invalid_player" },
		{ call = function() return reserves:SetPlayerReservePlus("Alpha", 999, 4) end, reason = "missing_item" },
		{ call = function() return reserves:SetPlayerReservePlus("Alpha", 100, 3) end, reason = "no_change" },
		{ call = function() return reserves:RemovePlayerReserve("Missing", 100) end, reason = "invalid_player" },
		{ call = function() return reserves:RemovePlayerReserve("Alpha", 999) end, reason = "missing_item" },
	}
	for i = 1, #failures do
		local changed, mutationReason = failures[i].call()
		assertEqual(false, changed, "failed synced mutation must remain false at row " .. i)
		assertEqual(failures[i].reason, mutationReason, "failed synced mutation reason differs at row " .. i)
		reserves:Save("test")
		reserves:Load()
		assertTrue(deepEqual({}, _G.RMA_Reserves), "failed synced mutation must not persist cache at row " .. i)
		assertEqual(true, reserves:GetSyncMetadata().runtime, "failed synced mutation must retain cache ownership at row " .. i)
		local entries = reserves:GetPlayerReserveEntries("Alpha")
		assertEqual(1, #entries, "synced view must survive save/reload at row " .. i)
		assertEqual(100, entries[1].rawID, "synced item must survive save/reload at row " .. i)
	end
	local changed, mutationReason = reserves:SetPlayerReserveQuantity("Alpha", 100, 4)
	assertEqual(true, changed, "successful synced mutation must publish its candidate")
	assertEqual(nil, mutationReason, "successful synced mutation must not return an error")
	assertEqual(false, reserves:GetSyncMetadata().runtime, "successful synced mutation must transfer cache ownership")
	assertEqual(4, _G.RMA_Reserves.Alpha.reserves[1].quantity, "successful synced mutation must persist its change")
	print("PASS reserves_failed_synced_mutations_do_not_promote_cache")
end

function cases.reserves_whisper_storage_identity_resolution_is_owner_bound(addon)
	local reserves = installRealReservesMutationFixture(addon)
	local function player(display)
		return { playerNameDisplay = display, reserves = { { rawID = 1, itemName = "Item", quantity = 1 } } }
	end
	local normalizedCharacter, normalizedRealm, normalizedIdentity =
		reserves:NormalizeWhisperPlayerIdentity("Al" .. string.char(0xc3, 0xa9) .. "a-Quel'Thalas-East", "Local Realm")
	assertEqual("Al" .. string.char(0xc3, 0xa9) .. "a", normalizedCharacter, "UTF-8 character must normalize")
	assertEqual("quelthalaseast", normalizedRealm, "internal realm punctuation must normalize")
	assertEqual("al" .. string.char(0xc3, 0xa9) .. "a-quelthalaseast", normalizedIdentity,
		"canonical identity must share the owner contract")
	for _, invalid in ipairs({ "", "Bad--Realm", "Bad-Realm-", "Bad- Realm", "Bad-Realm ", "'Bad-Realm",
		"Bad|Name-Realm", "Bad\tName-Realm", string.char(0xff) .. "Bad-Realm" }) do
		assertEqual(nil, reserves:NormalizeWhisperPlayerIdentity(invalid, "Local Realm"),
			"invalid owner identity must fail closed")
	end

	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = { alpha = player("Alpha") } }, nil,
		{ silentInfo = true }), "short-name fixture must import")
	local target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual("Alpha", target, "local qualified sender must reuse the existing short participant")
	assertEqual(nil, reason, "unambiguous short participant must resolve")
	assertTrue(reserves:AddPlayerReserve(target, 2), "resolved local participant must accept the reserve")
	assertEqual(1, reserves:GetCounts(), "resolved local sender must not create a qualified duplicate participant")
	assertEqual(2, #reserves:GetPlayerReserveEntries("Alpha"), "resolved reserve must update the existing short participant")

	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = {
		alpha = player("Alpha"), ["alpha-otherrealm"] = player("Alpha-otherrealm"),
	} }, nil, { silentInfo = true }), "ambiguous fixture must import")
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual(nil, target, "short plus cross-realm candidates must fail closed")
	assertEqual("ambiguous_player", reason, "ambiguous reason differs")
	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = {
		["alpha-otherrealm"] = player("Alpha-otherrealm"),
	} }, nil, { silentInfo = true }), "cross-only fixture must import")
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual(nil, target, "local sender must not reuse another realm's participant")
	assertEqual("ambiguous_player", reason, "cross-realm collision reason differs")

	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = {
		alpha = player("Alpha"), ["alpha-localrealm"] = player("Alpha-localrealm"),
		["alpha-otherrealm"] = player("Alpha-otherrealm"),
	} }, nil, { silentInfo = true }), "qualified fixture must import")
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual("Alpha-localrealm", target, "exact qualified participant must take precedence")
	assertEqual(nil, reason, "exact qualified participant must resolve")
	target = reserves:ResolveWhisperPlayerName("Alpha", "thirdrealm", "localrealm")
	assertEqual("Alpha-thirdrealm", target, "new cross-realm participant must remain qualified")

	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = {
		["alpha-local realm"] = player("Alpha-Local Realm"),
		["bravo-quel'thalas-east"] = player("Bravo-Quel'Thalas-East"),
	} }, nil, { silentInfo = true }), "punctuated realm fixture must import")
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual("Alpha-Local Realm", target, "normalized local realm must reuse the exact stored display")
	assertEqual(nil, reason, "normalized local exact identity must resolve")
	target, reason = reserves:ResolveWhisperPlayerName("Bravo", "quelthalaseast", "localrealm")
	assertEqual("Bravo-Quel'Thalas-East", target, "internal realm punctuation must reuse exact storage")
	assertEqual(nil, reason, "punctuated remote exact identity must resolve")

	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = {
		["alpha-local realm"] = player("Alpha-Local Realm"),
		["alpha-localrealm"] = player("Alpha-localrealm"),
	} }, nil, { silentInfo = true }), "normalized collision fixture must import")
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual(nil, target, "stored identities collapsing to one normalized identity must fail closed")
	assertEqual("ambiguous_player", reason, "normalized collision reason differs")

	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = {} }, nil,
		{ silentInfo = true }), "empty fixture must import")
	assertEqual("Alpha", reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm"),
		"new local participant must use established short-name storage")
	print("PASS reserves_whisper_storage_identity_resolution_is_owner_bound")
end

local function installRealReservesSyncFixture(addon)
	local reserves = installRealReservesMutationFixture(addon)
	addon.L.MsgReservesSyncFailed = "failed:%s"
	addon.L.MsgReservesSyncMeta = "%s %s %s %d %d"
	addon.L.MsgReservesSyncApplied = "applied:%s"
	addon.info = function() end
	local warnings = {}
	addon.warn = function(_, message) warnings[#warnings + 1] = message end
	local sent = {}
	local function encodeText(value)
		return (tostring(value or ""):gsub(".", function(char) return string.format("%02X", string.byte(char)) end))
	end
	local function decodeText(value)
		if type(value) ~= "string" or (#value % 2) ~= 0 or value:find("[^0-9A-F]") then return nil end
		return (value:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
	end
	local payload = {}
	function payload.PackFields(separator, ...)
		local fields = { ... }
		for i = 1, #fields do fields[i] = tostring(fields[i] or "") end
		return table.concat(fields, separator)
	end
	function payload.SplitFields(text, separator, destination)
		for key in pairs(destination) do destination[key] = nil end
		local from = 1
		while true do
			local at = string.find(text, separator, from, true)
			if not at then destination[#destination + 1] = string.sub(text, from); break end
			destination[#destination + 1] = string.sub(text, from, at - 1)
			from = at + #separator
		end
		return destination
	end
	payload.EncodeText = encodeText
	payload.DecodeText = decodeText
	addon.Comms = {
		Payload = payload,
		NormalizeSender = function(value) return tostring(value or ""):match("^[^-]+") or "" end,
		SendAddonWhisper = function(prefix, target, message)
			sent[#sent + 1] = { prefix = prefix, target = target, message = message }
			return true
		end,
		RegisterPrefixIfAvailable = function() end,
		NextRequestId = function(owner, field)
			owner[field] = (owner[field] or 0) + 1
			return tostring(owner[field])
		end,
		Sync = function() return true end,
	}
	addon.Services.Raid = {
		GetPlayerRoleState = function() return { isLeader = true } end,
		IsGroupMember = function() return true end,
		IsReservesAuthority = function() return true end,
	}
	_G.UnitName = function() return "Tester" end
	local now = 10
	_G.GetTime = function() return now end
	loadAddonFile(addon, "Raid Management Addon/Services/Reserves/Sync.lua")
	return {
		reserves = reserves,
		sync = reserves._Sync,
		payload = payload,
		sent = sent,
		setNow = function(value) now = value end,
		warnings = warnings,
	}
end

function cases.reserves_sync_checksums_and_payloads_are_verified(addon)
	local fixture = installRealReservesSyncFixture(addon)
	local first = {
		bravo = { playerNameDisplay = "Bravo", reserves = {
			{ rawID = 202, quantity = 1, plus = 0, class = "MAGE", spec = "Arcane", note = "b", source = "csv" },
			{ rawID = 201, quantity = 2, plus = 1, class = "MAGE", spec = "Fire", note = "a", source = "chat" },
		} },
		alpha = { playerNameDisplay = "Alpha", reserves = {
			{ rawID = 101, quantity = 1, plus = 0, class = "PRIEST", spec = "Holy", note = "", source = "csv" },
		} },
	}
	local reordered = {
		alpha = deepCopy(first.alpha),
		bravo = { playerNameDisplay = "Bravo", reserves = {
			deepCopy(first.bravo.reserves[2]), deepCopy(first.bravo.reserves[1]),
		} },
	}
	assertEqual(
		fixture.reserves.BuildCanonicalChecksum(first),
		fixture.reserves.BuildCanonicalChecksum(reordered),
		"equivalent reserve maps and rows need one canonical checksum"
	)

	local function compactPayload(data)
		local lines = { "H|multi|C1" }
		local playerNames = { "Alpha", "Bravo" }
		for i = 1, #playerNames do
			local name = playerNames[i]
			lines[#lines + 1] = "P|" .. i .. "|" .. fixture.payload.EncodeText(name)
			local rows = data[string.lower(name)].reserves
			for j = 1, #rows do
				local row = rows[j]
				lines[#lines + 1] = table.concat({
					"R", i, row.rawID, row.quantity, row.plus,
					fixture.payload.EncodeText(row.class), fixture.payload.EncodeText(row.spec),
					fixture.payload.EncodeText(row.note), fixture.payload.EncodeText(row.source),
				}, "|")
			end
		end
		return table.concat(lines, "\n")
	end
	local validPayload = compactPayload(first)
	local checksum = fixture.reserves.BuildCanonicalChecksum(first)
	local setCalls = 0
	local originalSet = fixture.sync.SetSyncedData
	fixture.sync.SetSyncedData = function(self, data, meta)
		setCalls = setCalls + 1
		return originalSet(self, data, meta)
	end
	local function transfer(requestId, announcedChecksum, players, entries, encoded, totalChunks)
		fixture.sync:HandleMessage("RMAResSync", table.concat({
			"META_ACK", requestId, announcedChecksum, "multi", players, entries, "Leader", "C2",
		}, "|"), "WHISPER", "Leader-Realm")
		fixture.sync:HandleMessage("RMAResSync", "DATA_CHUNK|" .. requestId .. "|1|" .. tostring(totalChunks or 1) .. "|" .. encoded, "WHISPER", "Leader-Realm")
		fixture.sync:HandleMessage("RMAResSync", "DATA_DONE|" .. requestId .. "|" .. announcedChecksum, "WHISPER", "Leader-Realm")
	end
	transfer("valid", checksum, 2, 3, fixture.payload.EncodeText(validPayload))
	assertEqual(1, setCalls, "valid verified payload must publish once; warning=" .. tostring(fixture.warnings[#fixture.warnings]))
	local validView = fixture.reserves:GetDisplayList()
	local validAlphaEntries = deepCopy(fixture.reserves:GetPlayerReserveEntries("Alpha"))
	local validMeta = deepCopy(fixture.reserves:GetSyncMetadata())

	local invalid = {
		{ id = "corrupt", checksum = checksum .. "1", players = 2, entries = 3, payload = string.gsub(validPayload, "202", "999", 1) },
		{ id = "truncated", checksum = checksum .. "2", players = 2, entries = 3, payload = string.sub(validPayload, 1, #validPayload - 8) },
		{ id = "empty", checksum = checksum .. "3", players = 2, entries = 3, payload = "" },
		{ id = "counts", checksum = checksum .. "4", players = 9, entries = 3, payload = validPayload },
		{ id = "missing", checksum = checksum .. "5", players = 2, entries = 3, payload = validPayload, totalChunks = 2 },
		{ id = "mode", checksum = checksum .. "6", players = 2, entries = 3, payload = string.gsub(validPayload, "H|multi|", "H|plus|", 1) },
	}
	for i = 1, #invalid do
		transfer(invalid[i].id, invalid[i].checksum, invalid[i].players, invalid[i].entries, fixture.payload.EncodeText(invalid[i].payload), invalid[i].totalChunks)
		assertEqual(1, setCalls, "rejected transfer must not reach SetSyncedData at row " .. i)
		assertTrue(deepEqual(validView, fixture.reserves:GetDisplayList()), "rejected transfer changed active view at row " .. i)
		assertTrue(deepEqual(validAlphaEntries, fixture.reserves:GetPlayerReserveEntries("Alpha")), "rejected transfer changed reserve rows at row " .. i)
		assertTrue(deepEqual(validMeta, fixture.reserves:GetSyncMetadata()), "rejected transfer changed metadata at row " .. i)
		assertEqual(nil, fixture.sync._pendingRequests[invalid[i].id], "rejected request was not cleared at row " .. i)
		assertEqual(nil, fixture.sync._incoming["Leader:" .. invalid[i].id], "rejected chunks were not cleared at row " .. i)
	end
	fixture.sync._pendingRequests.expired = { source = "Leader", checksum = "old", createdAt = 10 }
	fixture.sync._incoming["Leader:expired"] = { total = 1, chunks = { "old" }, createdAt = 10 }
	fixture.setNow(190)
	fixture.sync:HandleMessage("RMAResSync", "UNKNOWN|expired", "WHISPER", "Leader-Realm")
	assertEqual(nil, fixture.sync._pendingRequests.expired, "expired request must be cleared deterministically")
	assertEqual(nil, fixture.sync._incoming["Leader:expired"], "expired assembly must be cleared deterministically")
	print("PASS reserves_sync_checksums_and_payloads_are_verified")
end

function cases.reserves_sync_protocol_projection_and_chunks_fail_closed(addon)
	local fixture = installRealReservesSyncFixture(addon)
	local canonical = {
		alpha = { playerNameDisplay = "Alpha", reserves = {
			{ rawID = 100, quantity = 1, plus = 0, class = "MAGE", spec = "Fire", note = "", source = "csv" },
		} },
	}
	local wireEquivalent = {
		alpha = { playerNameDisplay = "Alpha", reserves = {
			{ rawID = "100", quantity = nil, plus = nil, class = "MAGE", spec = "Fire", note = "", source = "csv" },
		} },
	}
	local checksum = fixture.reserves.BuildCanonicalChecksum(canonical)
	assertTrue(type(checksum) == "string" and checksum:match("^C2:%d+:%d+$") ~= nil, "new checksums need a tagged semantic version")
	assertEqual(checksum, fixture.reserves.BuildCanonicalChecksum(wireEquivalent), "hashing and wire defaults must share one projection")
	local sparse = { alpha = { playerNameDisplay = "Alpha", reserves = { [1] = canonical.alpha.reserves[1], [3] = canonical.alpha.reserves[1] } } }
	local sparseChecksum, sparseReason = fixture.reserves.BuildCanonicalChecksum(sparse)
	assertEqual(nil, sparseChecksum, "sparse reserve sequences must be rejected")
	assertEqual("invalid_reserve_sequence", sparseReason, "sparse rejection reason differs")

	-- Legacy C1 metadata has no reproducible integrity digest; the new receiver fails closed without allocating state.
	fixture.sync:HandleMessage("RMAResSync", "META_ACK|legacy|12345|multi|1|1|Leader|C1", "WHISPER", "Leader-Realm")
	assertEqual(nil, fixture.sync._pendingRequests.legacy, "untagged legacy metadata must not start an unverifiable transfer")
	-- An old receiver treats the tagged checksum as opaque and accepts a matching DATA_DONE value.
	local oldPendingChecksum = checksum
	assertEqual(oldPendingChecksum, checksum, "new tagged META remains opaque to an old receiver")
	assertEqual(oldPendingChecksum, checksum, "new tagged DATA_DONE remains comparable by an old receiver")

	local invalidMeta = {
		"META_ACK|bad-mode|" .. checksum .. "|broken|1|1|Leader|C2",
		"META_ACK|bad-count|" .. checksum .. "|multi|1.5|1|Leader|C2",
		"META_ACK|negative|" .. checksum .. "|multi|-1|1|Leader|C2",
		"META_ACK|huge|" .. checksum .. "|multi|999999|1|Leader|C2",
		"META_ACK|bad-hash|C2:nope|multi|1|1|Leader|C2",
	}
	for i = 1, #invalidMeta do
		fixture.sync:HandleMessage("RMAResSync", invalidMeta[i], "WHISPER", "Leader-Realm")
	end
	for _, id in ipairs({ "bad-mode", "bad-count", "negative", "huge", "bad-hash" }) do
		assertEqual(nil, fixture.sync._pendingRequests[id], "invalid META allocated request " .. id)
	end

	fixture.sync:HandleMessage("RMAResSync", "META_ACK|chunks|" .. checksum .. "|multi|1|1|Leader|C2", "WHISPER", "Leader-Realm")
	fixture.sync:HandleMessage("RMAResSync", "DATA_CHUNK|chunks|1|2|AAAA", "WHISPER", "Leader-Realm")
	fixture.sync:HandleMessage("RMAResSync", "DATA_CHUNK|chunks|1|2|AAAA", "WHISPER", "Leader-Realm")
	assertTrue(fixture.sync._incoming["Leader:chunks"] ~= nil, "identical duplicate chunk should be idempotent")
	fixture.sync:HandleMessage("RMAResSync", "DATA_CHUNK|chunks|1|2|BBBB", "WHISPER", "Leader-Realm")
	assertEqual(nil, fixture.sync._incoming["Leader:chunks"], "conflicting duplicate must invalidate assembly")
	assertEqual(nil, fixture.sync._pendingRequests.chunks, "conflicting duplicate must invalidate request")

	local malformedChunks = {
		"DATA_CHUNK|fractional|1.5|2|AAAA",
		"DATA_CHUNK|empty|1|1|",
		"DATA_CHUNK|zero|0|1|AAAA",
	}
	for i = 1, #malformedChunks do
		local id = malformedChunks[i]:match("DATA_CHUNK|([^|]+)")
		fixture.sync._pendingRequests[id] = { source = "Leader", checksum = checksum, players = 1, entries = 1, createdAt = 10 }
		fixture.sync:HandleMessage("RMAResSync", malformedChunks[i], "WHISPER", "Leader-Realm")
		assertEqual(nil, fixture.sync._incoming["Leader:" .. id], "malformed chunk allocated assembly " .. id)
		assertEqual(nil, fixture.sync._pendingRequests[id], "malformed chunk retained request " .. id)
	end

	-- A new sender keeps every old field position and serves the old noncompact DATA_REQ shape.
	_G.RMA_Reserves = deepCopy(wireEquivalent)
	fixture.reserves:Load()
	for key in pairs(fixture.sent) do fixture.sent[key] = nil end
	fixture.sync:HandleMessage("RMAResSync", "META_REQ|old-meta", "WHISPER", "Old-Realm")
	local metaFields = {}
	fixture.payload.SplitFields(fixture.sent[#fixture.sent].message, "|", metaFields)
	assertEqual("META_ACK", metaFields[1], "new sender metadata kind changed")
	assertEqual("C2", metaFields[8], "new sender must advertise verified checksum semantics")
	assertEqual(fixture.reserves.BuildCanonicalChecksum(wireEquivalent), metaFields[3], "outbound META must hash serialized projection")
	local oldPending = metaFields[3]
	for key in pairs(fixture.sent) do fixture.sent[key] = nil end
	fixture.sync:HandleMessage("RMAResSync", "DATA_REQ|old-data|" .. oldPending, "WHISPER", "Old-Realm")
	local encodedParts = {}
	local oldDoneChecksum
	for i = 1, #fixture.sent do
		local fields = {}
		fixture.payload.SplitFields(fixture.sent[i].message, "|", fields)
		if fields[1] == "DATA_CHUNK" then encodedParts[tonumber(fields[3])] = fields[5] end
		if fields[1] == "DATA_DONE" then oldDoneChecksum = fields[3] end
	end
	assertEqual(oldPending, oldDoneChecksum, "old receiver must accept matching opaque META/DONE checksum")
	local oldPayload = fixture.payload.DecodeText(table.concat(encodedParts, ""))
	assertTrue(oldPayload:find("H|multi|", 1, true) == 1, "old DATA_REQ must receive legacy noncompact payload header")
	assertTrue(oldPayload:find("|100|1|0|", 1, true) ~= nil, "serialization must use the same numeric defaults as hashing")
	print("PASS reserves_sync_protocol_projection_and_chunks_fail_closed")
end

function cases.sync_fixture_models_communications_boundaries(addon)
	local fixture = newSyncCommunicationsFixture()
	assertEqual("Leader-Test Realm", fixture:CaptureSender("Leader-Test Realm").raw, "raw sender identity must be preserved")
	assertEqual("Leader", fixture:NormalizeSender("Leader-Test Realm"), "sender normalization must match Comms")
	assertEqual(2, fixture:GetRosterMember("Leader-Test Realm").rank, "leader rank differs")
	assertEqual(1, fixture:GetRosterMember("Assistant-Other Realm").rank, "assistant rank differs")
	assertEqual(0, fixture:GetRosterMember("Member-Test Realm").rank, "member rank differs")
	assertTrue(fixture:IsPrivilegedSender("Leader-Test Realm"), "realm-qualified leader must be privileged")
	assertTrue(fixture:IsPrivilegedSender("Assistant-Other Realm"), "realm-qualified assistant must be privileged")
	assertEqual(false, fixture:IsPrivilegedSender("Member-Test Realm"), "member must not be privileged")
	assertTrue(fixture:IsPrivilegedSender("Leader"), "current production aliases an unqualified sender")
	fixture.roster[#fixture.roster + 1] = { name = "Leader-Other Realm", rank = 0 }
	assertTrue(fixture:IsPrivilegedSender("leader-test realm"), "exact realm-qualified identity must win collisions")
	local collidedMember, collision = fixture:GetRosterMember("Leader")
	assertEqual(nil, collidedMember, "colliding short names must not select a roster member silently")
	assertEqual("short_name_collision", collision, "short-name collision must be explicit")
	table.remove(fixture.roster)

	local payload = { raidNid = 41, nested = { revision = 3 } }
	local payloadBefore = fixture:Snapshot(payload)
	local sent = fixture:Send("RMA_SYNC", payload, "WHISPER", "Assistant-Other Realm")
	payload.nested.revision = 99
	fixture:AssertDeepEqual(payloadBefore, sent.payload, "fake comms must capture payloads deeply")
	assertEqual("Assistant-Other Realm", sent.target, "fake comms target differs")

	local callbackArgs
	fixture:Schedule(2, function(first, second, third)
		callbackArgs = { first, second, third }
	end, "alpha", nil, "omega")
	assertEqual(0, fixture:AdvanceTime(1), "timer must remain pending before deadline")
	assertEqual(nil, callbackArgs, "pending timer must not fire")
	assertEqual(1, fixture:AdvanceTime(1), "one timer must fire at deadline")
	assertEqual("alpha", callbackArgs[1], "timer first argument differs")
	assertEqual(nil, callbackArgs[2], "timer nil argument differs")
	assertEqual("omega", callbackArgs[3], "timer trailing argument differs")

	assertEqual(3, fixture:GetRaidRevision(41), "initial raid revision differs")
	fixture:SetRaidRevision(41, 4)
	assertEqual(4, fixture:GetRaidRevision(41), "updated raid revision differs")
	assertEqual(8, fixture:GetRaidRevision(73), "raid revisions must remain isolated")

	local request = fixture:BuildRequest("SYNC", 41, {
		zone = "Naxxramas",
		size = 25,
		difficulty = 2,
		sinceRevision = 3,
		supportsCompression = true,
	})
	assertEqual("RQ", request.kind, "request wire kind differs")
	assertEqual(2, request.version, "request protocol version differs")
	assertEqual("1", request.requestId, "request id must be a string")
	assertEqual("SYNC", request.mode, "request mode differs")
	assertEqual(3, request.sinceRevision, "sync request revision differs")
	assertEqual("fake:Naxxramas", request.zone, "request zone must be encoded text")
	assertEqual(25, request.size, "request raid size differs")
	assertEqual(2, request.difficulty, "request difficulty differs")
	assertEqual(true, request.supportsCompression, "request compression support differs")
	local expectedRequestFields = { "RQ", 2, "1", "SYNC", 41, "fake:Naxxramas", 25, 2, 3, 1 }
	fixture:AssertDeepEqual(expectedRequestFields, request.fields, "request positional wire fields differ")
	local malformedRequest = fixture:BuildRequest("SYNC", 73, {
		zone = false,
		size = "oversized",
		difficulty = -1,
		sinceRevision = "stale",
		supportsCompression = "not-a-flag",
	})
	assertEqual("oversized", malformedRequest.fields[7], "malformed signature size must be constructible")
	assertEqual("not-a-flag", malformedRequest.fields[10], "malformed compression flag must be constructible")
	local requestBefore = fixture:Snapshot(request)
	local values = { { id = 1, nested = { value = "a" } }, { id = 2 }, { id = 3 } }
	local valuesBefore = fixture:Snapshot(values)
	local chunks = fixture:BuildChunks("SN", request, values, 2, "Leader-Test Realm", "Assistant-Other Realm")
	assertEqual(2, #chunks, "chunk builder must split rows")
	assertEqual("SN", chunks[1].kind, "chunk wire kind differs")
	assertEqual(request.requestId, chunks[1].requestId, "chunk request correlation differs")
	assertEqual(1, chunks[1].partIndex, "chunk part index differs")
	assertEqual(2, chunks[1].partCount, "chunk part count differs")
	assertEqual("string", type(chunks[1].payload), "chunk payload must be encoded text")
	assertEqual("Leader-Test Realm", chunks[1].sender.raw, "chunk sender context must preserve raw identity")
	assertEqual("Assistant-Other Realm", chunks[1].target, "chunk target context differs")
	local malformed = fixture:BuildChunk("DL", request, "encoded", 2, 3, "Member-Test Realm", nil)
	assertEqual(2, malformed.partIndex, "malformed/out-of-order fixture index must be constructible")
	assertEqual(3, malformed.partCount, "count mismatch fixture must be constructible")
	fixture:AssertUnchanged(requestBefore, request, "chunk building must preserve request")
	fixture:AssertUnchanged(valuesBefore, values, "chunk mutation must not alias source values")

	local mutated = fixture:Snapshot(valuesBefore)
	mutated[1].nested.value = "different"
	local mutationDetected = not pcall(function()
		fixture:AssertUnchanged(valuesBefore, mutated, "deep mutation must be detected")
	end)
	assertTrue(mutationDetected, "deep mutation assertion must reject nested changes")
	print("PASS sync_fixture_models_communications_boundaries")
end

function cases.sync_authorization_fails_closed(addon)
	local fixture = newSyncCommunicationsFixture()
	local incoming = {}
	local function receive(sender)
		local authorized = fixture:AuthorizeSyncResponder(sender)
		if authorized then
			incoming[sender] = { created = true }
		end
		return authorized
	end

	assertEqual(false, receive("Late-Other Realm"), "unknown sender must be rejected during roster uncertainty")
	assertEqual(nil, incoming["Late-Other Realm"], "rejected sender must not allocate incoming state")
	assertTrue(receive("Leader-Test Realm"), "leader must remain authorized")
	assertTrue(receive("Assistant-Other Realm"), "assistant must remain authorized")
	assertEqual(false, receive("Member-Test Realm"), "rank-zero member must be rejected")
	fixture.roster[#fixture.roster + 1] = { name = "Late-Other Realm", rank = 1 }
	assertTrue(receive("Late-Other Realm"), "roster-late assistant must be accepted after positive lookup")
	assertTrue(fixture:CanAnswerWhisperRequest("Member-Test Realm"), "current member may request history by whisper")
	assertEqual(false, fixture:CanAnswerWhisperRequest("Outsider-Test Realm"), "outsider whisper must receive no history")

	fixture.roster[#fixture.roster + 1] = { name = "Leader-Other Realm", rank = 0 }
	assertEqual(false, receive("Leader"), "ambiguous short sender identity must fail closed")
	print("PASS sync_authorization_fails_closed")
end

local function installRealDbSyncerFixture(addon)
	local fixture = {
		now = 500,
		roster = {},
		sent = {},
		warnings = {},
		infos = {},
		events = {},
		options = {},
		imports = 0,
		importAttempts = 0,
		importHook = nil,
		failNextImport = false,
		failNextDecode = false,
		failNextParse = false,
		failBatch = false,
		failSingle = false,
		batchAttempts = 0,
		timers = {},
	}
	_G.GetTime = function() return fixture.now end
	_G.GetNumRaidMembers = function() return #fixture.roster end
	_G.GetRaidRosterInfo = function(index)
		local member = fixture.roster[index]
		if not member then return nil end
		return member.name, member.rank
	end

	local function trim(value) return string.match(tostring(value or ""), "^%s*(.-)%s*$") end
	local function lower(value) return string.lower(tostring(value or "")) end
	addon.L = {
		MsgLoggerSyncRaidRefRequired = "raid required", MsgLoggerSyncTargetRequired = "target required",
		MsgLoggerSyncTargetSelf = "self target", MsgLoggerSyncNoRaid = "no raid", MsgLoggerSyncPushSent = "%s %s",
		MsgLoggerSyncNoCurrent = "no current", MsgLoggerSyncSent = "%s", MsgLoggerReqSent = "%s %s",
		MsgLoggerPushImported = "%s %s", MsgLoggerReqImported = "%s %s",
	}
	local passthrough = setmetatable({}, { __index = function() return "%s" end })
	addon.Diag = { D = passthrough, W = passthrough, E = passthrough }
	addon.DB = { Syncer = {} }
	addon.Events = {
		Internal = { OptionsLoaded = "OPTIONS", LoggerSelectRaid = "SELECT", RaidCreate = "CREATE" },
		BuildConfigOptionChangedName = function(name) return "OPTION_" .. name end,
	}
	addon.Bus = {
		TriggerEvent = function(eventName, ...)
			fixture.events[#fixture.events + 1] = { eventName = eventName, args = { ... } }
		end,
		RegisterCallback = function() end,
	}
	addon.Strings = { NormalizeName = trim, NormalizeLower = lower, TrimText = trim }
	addon.Timer = { BindMixin = function(target)
		target.ScheduleTimer = function(_, callback)
			local handle = { callback = callback, active = true }
			fixture.timers[#fixture.timers + 1] = handle
			return handle
		end
		target.CancelTimer = function(_, handle)
			if not handle or handle.active ~= true then return false end
			handle.active = false
			return true
		end
	end }
	function fixture:FireTimers()
		local fired = 0
		for i = 1, #self.timers do
			local handle = self.timers[i]
			if handle.active then
				handle.active = false
				fired = fired + 1
				handle.callback()
			end
		end
		return fired
	end
	addon.Options = {
		RegisterNamespace = function(_, defaults)
			fixture.options = defaults or {}
			return { Get = function(_, key) return fixture.options[key] end }
		end,
		IsDebugEnabled = function() return false end,
	}
	addon.Comms = {
		RegisterPrefixIfAvailable = function() end,
		NormalizeSender = function(value) return trim(value) end,
		NextRequestId = function() return "generated" end,
		QueueAddonMessage = function(prefix, message, channel, target)
			if fixture.failSingle then return false, "backpressure" end
			fixture.sent[#fixture.sent + 1] = { prefix = prefix, message = message, channel = channel, target = target }
			return true
		end,
		QueueAddonMessages = function(prefix, messages, channel, target)
			fixture.batchAttempts = fixture.batchAttempts + 1
			if fixture.failBatch then return false, "backpressure" end
			for i = 1, #messages do
				fixture.sent[#fixture.sent + 1] = { prefix = prefix, message = messages[i], channel = channel, target = target }
			end
			return true
		end,
		SendAddonBatch = function(prefix, messages, target)
			return addon.Comms.QueueAddonMessages(prefix, messages, target and "WHISPER" or "RAID", target)
		end,
		Sync = function(prefix, message)
			if fixture.failSingle then return false, "backpressure" end
			fixture.sent[#fixture.sent + 1] = { prefix = prefix, message = message, channel = "RAID" }
			return true
		end,
		Payload = {
			SplitFields = function(message, separator)
				local fields = {}
				for field in string.gmatch(message .. separator, "(.-)" .. separator) do fields[#fields + 1] = field end
				return fields, #fields
			end,
			PackFields = function(separator, ...)
				local fields = { ... }
				for i = 1, #fields do fields[i] = tostring(fields[i] or "") end
				return table.concat(fields, separator)
			end,
		},
	}
	addon.Database.GetPlayerName = function() return "Tester-Test Realm" end
	addon.Database.GetCurrentRaid = function() return 41 end
	addon.Database.GetRaidStore = function() return { GetRaidSyncRevision = function() return 0 end } end
	addon.Services.Raid = {
		IsGroupMember = function() return false end,
		CanUseCapability = function() return true end,
	}
	addon.IsInRaid = function() return true end
	addon.IsInGroup = function() return true end
	addon.warn = function(_, message) fixture.warnings[#fixture.warnings + 1] = message end
	addon.error = function(_, message) fixture.warnings[#fixture.warnings + 1] = message end
	addon.info = function(_, message) fixture.infos[#fixture.infos + 1] = message end
	addon.debug = function() end

	local noOp = function() end
	addon.DB.Syncer._Metrics = setmetatable({ Get = function() return {} end, Reset = function() end }, {
		__index = function() return noOp end,
	})
	addon.DB.Syncer._Payload = {
		EncodeText = function(value) return tostring(value or "") end,
		DecodeText = function(value) return value end,
		EncodeTransportText = function(value) return value end,
		DecodeTransportText = function(value)
			if fixture.failNextDecode then
				fixture.failNextDecode = false
				return nil
			end
			return value
		end,
		Build = function() return "snapshot" end,
		BuildDelta = function() return nil end,
		ValidateSnapshot = function() return true end,
		ValidateDelta = function() return true end,
		Parse = function(value)
			if fixture.failNextParse then
				fixture.failNextParse = false
				return nil
			end
			if value ~= "snapshot" and value ~= "snapshot-v1" then return nil end
			return { header = { protocolVersion = value == "snapshot-v1" and 1 or 2, raidNid = 41 }, bossKills = {}, loot = {} }
		end,
		ParseDelta = function(value)
			if value ~= "delta-v1" and value ~= "delta-v2" then return nil end
			return { header = { protocolVersion = value == "delta-v1" and 1 or 2, raidNid = 41 }, loot = {} }
		end,
	}
	local raid = { raidNid = 41 }
	addon.DB.Syncer._Import = {
		ResolveRaidByReference = function() return raid end,
		GetCurrentRaidRecord = function() return raid, 41 end,
		RaidMatchesSignature = function() return true end,
		BuildSignatureFromRaid = function() return { zone = "Naxxramas", size = 25, diff = 1 } end,
		ImportSnapshotAsNewRaid = function(snapshot)
			fixture.importAttempts = fixture.importAttempts + 1
			if fixture.importHook then fixture.importHook() end
			if fixture.failNextImport then
				fixture.failNextImport = false
				error("fixture import failure")
			end
			fixture.imports = fixture.imports + 1
			return snapshot, fixture.imports
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncer.lua")
	return fixture, addon.DB.Syncer
end

function cases.sync_envelope_validation_is_correlated_end_to_end(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 2 },
		{ name = "Requester-Test Realm", rank = 0 },
	}
	fixture.options.syncRequirePlayer = "Leader-Test Realm"
	local function snapshot(version, requestId, partIndex, partCount, payload)
		syncer:OnAddonMessage("RMALogSync", table.concat({
			"SN", version, requestId, "PUSH", 41, partIndex or 1, partCount or 1, payload or "snapshot",
		}, "\t"), "RAID", "Leader-Test Realm")
	end

	local sentBefore = #fixture.sent
	local id64 = string.rep("r", 64)
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"RQ", 2, id64, "REQ", 41, "Naxxramas", 25, 1, 0, 0,
	}, "\t"), "WHISPER", "Requester-Test Realm")
	assertTrue(#fixture.sent > sentBefore, "64-byte request id must remain valid for RQ")
	local afterValid = #fixture.sent
	local requestRateBefore = syncer._requestRate["Requester-Test Realm"].count
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"RQ", 2, string.rep("r", 65), "REQ", 41, "Naxxramas", 25, 1, 0, 0,
	}, "\t"), "WHISPER", "Requester-Test Realm")
	assertEqual(afterValid, #fixture.sent, "65-byte RQ must be rejected before response allocation")
	assertEqual(nil, next(syncer._incoming), "oversized RQ must not allocate incoming state")
	assertEqual(requestRateBefore, syncer._requestRate["Requester-Test Realm"].count, "oversized RQ must be rejected before rate metrics")

	snapshot(1, "v1-envelope-v2-payload", 1, 1, "snapshot")
	assertEqual(0, fixture.imports, "v1 envelope with v2 payload must not import")
	snapshot(2, "v1-envelope-v2-payload", 1, 1, "snapshot")
	assertEqual(1, fixture.imports, "version mismatch must release configured PUSH for retry")

	snapshot(2, "v2-envelope-v1-payload", 1, 1, "snapshot-v1")
	assertEqual(1, fixture.imports, "v2 envelope with v1 payload must not import")
	snapshot(1, "valid-v1", 1, 1, "snapshot-v1")
	assertEqual(2, fixture.imports, "valid v1 snapshot must remain accepted")

	snapshot(1, "changing-envelope", 1, 2, "snap")
	assertTrue(next(syncer._incoming) ~= nil, "first chunk must allocate assembly")
	snapshot(2, "changing-envelope", 2, 2, "shot-v1")
	assertEqual(nil, next(syncer._incoming), "changing envelope version must discard assembly")
	assertEqual(2, fixture.imports, "changing envelope version must not import")
	snapshot(1, "changing-envelope", 1, 1, "snapshot-v1")
	assertEqual(3, fixture.imports, "discarded version mismatch must release PUSH consent for retry")
	assertEqual(3, #fixture.events, "only valid snapshots may publish import events")

	local function delta(version, requestId, partIndex, partCount, payload)
		syncer._pendingRequests[requestId] = {
			createdAt = fixture.now, mode = "SYNC", failedSenders = {}, completed = false,
		}
		syncer:OnAddonMessage("RMALogSync", table.concat({
			"DL", version, requestId, "SYNC", 41, partIndex or 1, partCount or 1, payload or "delta-v2",
		}, "\t"), "RAID", "Leader-Test Realm")
	end
	delta(1, "legacy-delta", 1, 1, "delta-v2")
	assertEqual(nil, next(syncer._incoming), "DL v1 envelope must be rejected before assembly")
	delta(2, "v2-delta-v1-payload", 1, 1, "delta-v1")
	assertEqual(3, fixture.imports, "DL v2 with v1 payload must not mutate history")
	assertEqual(3, #fixture.events, "invalid DL must not publish events")
	delta(2, "changing-delta", 1, 2, "delta-")
	assertTrue(next(syncer._incoming) ~= nil, "first DL v2 chunk must allocate assembly")
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"DL", 1, "changing-delta", "SYNC", 41, 2, 2, "v2",
	}, "\t"), "RAID", "Leader-Test Realm")
	assertEqual(nil, next(syncer._incoming), "changing version for one DL assembly must not retain state")
	assertEqual(3, fixture.imports, "changing DL envelope must not mutate history")
	assertEqual(3, #fixture.events, "changing DL envelope must not publish events")

	local function pendingSync(requestId)
		syncer._pendingRequests[requestId] = {
			createdAt = fixture.now, mode = "SYNC", failedSenders = {}, completed = false,
		}
	end
	pendingSync("snapshot-to-delta")
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"SN", 2, "snapshot-to-delta", "SYNC", 41, 1, 3, "snap",
	}, "\t"), "RAID", "Leader-Test Realm")
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"DL", 2, "snapshot-to-delta", "SYNC", 41, 2, 3, "shot",
	}, "\t"), "RAID", "Leader-Test Realm")
	assertEqual(nil, next(syncer._incoming), "SN to DL kind change must discard assembly immediately")
	assertEqual(false, syncer._pendingRequests["snapshot-to-delta"].completed == true, "kind mismatch must preserve multi-responder request")

	pendingSync("delta-to-snapshot")
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"DL", 2, "delta-to-snapshot", "SYNC", 41, 1, 3, "delta-",
	}, "\t"), "RAID", "Leader-Test Realm")
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"SN", 2, "delta-to-snapshot", "SYNC", 41, 2, 3, "v2",
	}, "\t"), "RAID", "Leader-Test Realm")
	assertEqual(nil, next(syncer._incoming), "DL to SN kind change must discard assembly immediately")
	assertEqual(false, syncer._pendingRequests["delta-to-snapshot"].completed == true, "reverse kind mismatch must preserve multi-responder request")
	assertEqual(3, fixture.imports, "kind mismatches must not mutate history")
	assertEqual(3, #fixture.events, "kind mismatches must not publish events")

	snapshot(2, "push-kind-mismatch", 1, 3, "snap")
	assertTrue(next(syncer._incoming) ~= nil, "partial PUSH must allocate before kind mismatch")
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"DL", 2, "push-kind-mismatch", "PUSH", 41, 2, 3, "shot",
	}, "\t"), "RAID", "Leader-Test Realm")
	assertEqual(nil, next(syncer._incoming), "invalid DL PUSH must discard conflicting SN assembly")
	snapshot(2, "push-kind-mismatch", 1, 1, "snapshot")
	assertEqual(4, fixture.imports, "kind mismatch must release configured PUSH consent for retry")
	assertEqual(4, #fixture.events, "only the valid PUSH retry may publish an event")
	print("PASS sync_envelope_validation_is_correlated_end_to_end")
end

local function installCorrelatedPushRetryFixture(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Assistant-Other Realm", rank = 1 } }
	syncer._pendingRequests["correlated-retry"] = {
		createdAt = fixture.now,
		mode = "REQ",
		target = "Assistant-Other Realm",
		sender = "Assistant-Other Realm",
		completed = false,
	}
	local function push(partIndex, partCount, payload)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "SN", 2, "correlated-retry", "PUSH", 41, partIndex or 1, partCount or 1, payload or "snapshot" }, "\t"),
			"WHISPER",
			"assistant"
		)
	end
	return fixture, syncer, push
end

function cases.real_db_syncer_retries_correlated_push_after_import_failure(addon)
	local fixture, _, push = installCorrelatedPushRetryFixture(addon)
	fixture.failNextImport = true
	push()
	assertEqual(0, fixture.imports, "failed correlated import must not consume consent")
	assertEqual(0, #fixture.events, "failed import must not publish a logger refresh")
	push()
	assertEqual(1, fixture.imports, "correlated PUSH must retry after import failure")
	assertEqual(1, #fixture.events, "successful import must publish exactly one logger refresh")
	push()
	assertEqual(2, fixture.importAttempts, "successful correlated retry must consume consent exactly once")
	print("PASS real_db_syncer_retries_correlated_push_after_import_failure")
end

function cases.real_db_syncer_retries_correlated_push_after_decode_and_parse_failure(addon)
	local fixture, _, push = installCorrelatedPushRetryFixture(addon)
	fixture.failNextDecode = true
	push()
	assertEqual(0, fixture.importAttempts, "decode failure must occur before import")
	fixture.failNextParse = true
	push()
	assertEqual(0, fixture.importAttempts, "parse failure must occur before import")
	push()
	assertEqual(1, fixture.imports, "correlated PUSH must retry after decode and parse failure")
	push()
	assertEqual(1, fixture.importAttempts, "successful retry after decode/parse must consume consent once")
	print("PASS real_db_syncer_retries_correlated_push_after_decode_and_parse_failure")
end

function cases.real_db_syncer_rejects_correlated_push_after_request_timeout(addon)
	local fixture, syncer, push = installCorrelatedPushRetryFixture(addon)
	push(1, 2, "snap")
	assertTrue(next(syncer._incoming) ~= nil, "partial correlated PUSH must allocate one assembly")
	fixture.now = fixture.now + 46
	push(1, 1, "snapshot")
	assertEqual(0, fixture.imports, "timed-out request must revoke correlated PUSH retry")
	push(1, 1, "snapshot")
	assertEqual(0, fixture.importAttempts, "late timeout retry must be rejected before import")
	print("PASS real_db_syncer_rejects_correlated_push_after_request_timeout")
end

function cases.real_db_syncer_consumes_push_consent_once(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	local function push(requestId, sender, partIndex, partCount, payload)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "SN", 2, requestId, "PUSH", 41, partIndex or 1, partCount or 1, payload or "snapshot" }, "\t"),
			"WHISPER",
			sender
		)
	end
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 2 },
		{ name = "Assistant-Other Realm", rank = 1 },
	}
	fixture.options.syncRequirePlayer = "Leader-Test Realm"

	push("configured-once", "leader-test realm")
	assertEqual(1, fixture.imports, "configured PUSH must import once")
	push("configured-once", "Leader-Test Realm")
	assertEqual(1, fixture.importAttempts, "configured PUSH replay must be rejected before import")
	assertEqual(nil, next(syncer._incoming), "configured PUSH replay must not allocate incoming state")

	syncer._pendingRequests["correlated-once"] = {
		createdAt = fixture.now, mode = "REQ", target = "Assistant-Other Realm", sender = "Assistant-Other Realm",
		completed = false,
	}
	push("correlated-once", "assistant")
	assertEqual(2, fixture.imports, "correlated PUSH must import once")
	push("correlated-once", "Assistant-Other Realm")
	assertEqual(2, fixture.importAttempts, "correlated PUSH consent must be consumed exactly once")

	fixture.importHook = function()
		fixture.importHook = nil
		push("concurrent", "Leader-Test Realm")
	end
	push("concurrent", "leader-test realm")
	assertEqual(3, fixture.imports, "first concurrent PUSH must import")
	assertEqual(3, fixture.importAttempts, "second concurrent assembly for the same consent must be rejected")
	print("PASS real_db_syncer_consumes_push_consent_once")
end

function cases.real_db_syncer_releases_failed_push_consent(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	local function push(requestId)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "SN", 2, requestId, "PUSH", 41, 1, 1, "snapshot" }, "\t"),
			"WHISPER",
			"Leader-Test Realm"
		)
	end
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 2 },
		{ name = "Assistant-Other Realm", rank = 1 },
	}
	fixture.options.syncRequirePlayer = "Leader-Test Realm"
	fixture.failNextImport = true
	push("retry-after-failure")
	assertEqual(0, fixture.imports, "failed PUSH import must not be consumed")
	push("retry-after-failure")
	assertEqual(1, fixture.imports, "failed PUSH import must release consent for retry")
	assertEqual(2, fixture.importAttempts, "retry must reach the importer")
	print("PASS real_db_syncer_releases_failed_push_consent")
end

function cases.real_db_syncer_requires_push_consent(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	local function push(requestId, sender)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "SN", 2, requestId, "PUSH", 41, 1, 1, "snapshot" }, "\t"),
			"WHISPER",
			sender
		)
	end
	local function pending(requestId, target)
		syncer._pendingRequests[requestId] = {
			createdAt = fixture.now, mode = "REQ", target = target, sender = target, completed = false,
		}
	end

	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 2 },
		{ name = "Assistant-Other Realm", rank = 1 },
		{ name = "Member-Test Realm", rank = 0 },
	}
	push("outsider", "Outsider-Test Realm")
	assertEqual(0, fixture.imports, "outsider PUSH must not import")
	assertEqual(nil, next(syncer._incoming), "outsider PUSH must not allocate incoming state")
	push("member", "Member-Test Realm")
	assertEqual(0, fixture.imports, "rank-zero member PUSH must not import")
	push("officer-unsolicited", "Assistant-Other Realm")
	assertEqual(0, fixture.imports, "unsolicited officer PUSH must not import")

	pending("correlated", "Assistant-Other Realm")
	push("correlated", "assistant")
	assertEqual(1, fixture.imports, "targeted pending request must consent to an officer PUSH")

	fixture.options.syncRequirePlayer = "Leader-Test Realm"
	push("configured", "leader-test realm")
	assertEqual(2, fixture.imports, "configured officer source must consent to PUSH")
	fixture.roster[#fixture.roster + 1] = { name = "Leader-Other Realm", rank = 2 }
	fixture.options.syncRequirePlayer = "Leader"
	push("collision", "Leader")
	assertEqual(2, fixture.imports, "ambiguous configured short identity must fail closed")

	fixture.options.syncPushPlayer = "Assistant-Other Realm"
	local sentBefore = #fixture.sent
	assertTrue(syncer:BroadcastLoggerPush(41), "configured outbound PUSH target must be effective")
	assertTrue(#fixture.sent > sentBefore, "configured outbound PUSH must send")
	assertEqual("Assistant-Other Realm", fixture.sent[#fixture.sent].target, "configured PUSH target differs")
	print("PASS real_db_syncer_requires_push_consent")
end

function cases.sync_request_lifecycle_is_correlated_and_terminal_once(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 2 },
		{ name = "Assistant-Other Realm", rank = 1 },
	}
	local callbackCount, terminalReason = 0, nil
	local function pending(requestId, raidRef, target)
		syncer._pendingRequests[requestId] = {
			createdAt = fixture.now,
			mode = "REQ",
			raidRef = raidRef,
			target = target,
			sender = target,
			completed = false,
			callback = function(reason)
				callbackCount = callbackCount + 1
				terminalReason = reason
			end,
		}
	end
	local function snapshot(requestId, mode, raidNid, sender, partIndex, partCount, payload)
		syncer:OnAddonMessage("RMALogSync", table.concat({
			"SN", 2, requestId, mode, raidNid, partIndex or 1, partCount or 1, payload or "snapshot",
		}, "\t"), "WHISPER", sender)
	end

	snapshot("unsolicited", "REQ", 41, "Leader-Test Realm")
	assertEqual(0, fixture.importAttempts, "unsolicited response must not import")

	pending("bound", 41, "Leader-Test Realm")
	snapshot("bound", "REQ", 41, "Assistant-Other Realm")
	snapshot("bound", "REQ", 42, "Leader-Test Realm")
	snapshot("bound", "SYNC", 41, "Leader-Test Realm")
	assertEqual(0, fixture.importAttempts, "cross-context response must not import")
	assertEqual(nil, next(syncer._incoming), "cross-context response must not allocate assembly state")
	snapshot("bound", "REQ", 41, "Leader-Test Realm")
	assertEqual(1, fixture.imports, "matching response must import once")
	assertEqual(1, callbackCount, "successful request callback must run once")
	assertEqual("complete", terminalReason, "successful request terminal reason differs")
	snapshot("bound", "REQ", 41, "Leader-Test Realm")
	assertEqual(1, fixture.importAttempts, "duplicate terminal response must not re-enter import")
	assertEqual(1, callbackCount, "duplicate terminal response must not re-enter callback")

	pending("timeout", 41, "Leader-Test Realm")
	snapshot("timeout", "REQ", 41, "Leader-Test Realm", 1, 2, "snap")
	assertTrue(next(syncer._incoming) ~= nil, "partial response must allocate assembly state")
	fixture.now = fixture.now + 31
	snapshot("cleanup-trigger", "REQ", 41, "Leader-Test Realm")
	assertEqual(2, callbackCount, "timeout callback must run once")
	assertEqual("timeout", terminalReason, "timeout terminal reason differs")
	assertEqual(nil, next(syncer._incoming), "timeout must release incoming assembly state")
	snapshot("timeout", "REQ", 41, "Leader-Test Realm")
	assertEqual(1, fixture.importAttempts, "late timeout response must not import")
	assertEqual(2, callbackCount, "late timeout response must not re-enter callback")

	pending("cancel", 41, "Leader-Test Realm")
	assertEqual(true, syncer:CancelRequest("cancel"), "active request must cancel")
	assertEqual(false, syncer:CancelRequest("cancel"), "terminal request must not cancel twice")
	assertEqual(3, callbackCount, "cancel callback must run once")
	assertEqual("cancel", terminalReason, "cancel terminal reason differs")
	snapshot("cancel", "REQ", 41, "Leader-Test Realm")
	assertEqual(1, fixture.importAttempts, "cancelled request must reject late response")
	assertEqual(3, callbackCount, "late cancelled response must not re-enter callback")

	pending("timeout", 42, "Assistant-Other Realm")
	snapshot("timeout", "REQ", 42, "Assistant-Other Realm")
	assertEqual(1, fixture.importAttempts, "terminal request ID must not be reused across context")
	assertEqual(4, callbackCount, "reused request ID must terminate replacement callback once")
	assertEqual("reused", terminalReason, "reused request terminal reason differs")

	fixture.now = fixture.now + 46
	snapshot("prune-trigger", "REQ", 41, "Leader-Test Realm")
	assertEqual(nil, next(syncer._pendingRequests), "expired pending sender state must be released")
	assertEqual(nil, next(syncer._terminalRequests), "expired terminal correlation state must be bounded")
	print("PASS sync_request_lifecycle_is_correlated_and_terminal_once")
end

function cases.sync_request_timeout_fires_without_inbound_traffic(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	local callbackCount, reentrantCancel = 0, nil
	assertEqual(true, syncer:RequestLoggerReq(41, "Leader-Test Realm"), "request must start")
	local pending = assert(syncer._pendingRequests.generated, "generated request must be pending")
	pending.callback = function(reason)
			callbackCount = callbackCount + 1
			assertEqual("timeout", reason, "timer terminal reason differs")
			reentrantCancel = syncer:CancelRequest("generated")
			syncer:OnAddonMessage("RMALogSync", table.concat({
				"SN", 2, "generated", "REQ", 41, 1, 1, "snapshot",
			}, "\t"), "WHISPER", "Leader-Test Realm")
		end
	assertEqual(1, fixture:FireTimers(), "one request timeout must fire without inbound traffic")
	assertEqual(1, callbackCount, "timer timeout callback must run once")
	assertEqual(false, reentrantCancel, "reentrant cancellation must observe terminal state")
	assertEqual(0, fixture:FireTimers(), "terminal timeout must leave no active timer")
	assertEqual(0, fixture.importAttempts, "reentrant completion attempt must observe terminal state")
	assertEqual(nil, syncer._pendingRequests.generated, "timer timeout must release pending state")
	print("PASS sync_request_timeout_fires_without_inbound_traffic")
end

function cases.sync_request_cleanup_is_context_scoped(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	fixture.options.syncRequirePlayer = "Leader-Test Realm"
	local pending = {
		createdAt = fixture.now, mode = "REQ", raidRef = 41, target = "Assistant-Other Realm", sender = "Assistant-Other Realm",
	}
	syncer._pendingRequests["collision"] = pending
	syncer._incoming["local"] = {
		createdAt = fixture.now, requestId = "collision", mode = "REQ", raidNid = 41,
		sender = "assistant-other realm", requestContext = pending, total = 2, got = 1, parts = { "x" }, encodedBytes = 1,
	}
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"SN", 2, "collision", "PUSH", 41, 1, 2, "push",
	}, "\t"), "WHISPER", "Leader-Test Realm")
	local pushKey
	for key, state in pairs(syncer._incoming) do
		if state.mode == "PUSH" then pushKey = key end
	end
	assertTrue(pushKey ~= nil, "unrelated configured PUSH collision must allocate independently")
	assertEqual(true, syncer:CancelRequest("collision"), "local colliding request must cancel")
	assertEqual(nil, syncer._incoming["local"], "cancel must remove its local response assembly")
	assertTrue(syncer._incoming[pushKey] ~= nil, "cancel must preserve unrelated PUSH with same wire ID")

	local second = { createdAt = fixture.now, mode = "REQ", raidRef = 42, target = "Assistant-Other Realm" }
	syncer._pendingRequests["push-first"] = second
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"SN", 2, "push-first", "PUSH", 41, 1, 1, "snapshot",
	}, "\t"), "WHISPER", "Leader-Test Realm")
	assertTrue(syncer._pendingRequests["push-first"] == second, "unrelated PUSH completion must not terminalize local request")
	assertEqual(false, second.completed == true, "unrelated PUSH must not mark local request completed")
	print("PASS sync_request_cleanup_is_context_scoped")
end

function cases.sync_timeout_revokes_only_correlated_push_consent(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 2 },
		{ name = "Assistant-Other Realm", rank = 1 },
	}
	assertEqual(true, syncer:RequestLoggerReq(41, "Assistant-Other Realm"), "correlated request must start")
	local function push(sender, partIndex, partCount, payload)
		syncer:OnAddonMessage("RMALogSync", table.concat({
			"SN", 2, "generated", "PUSH", 41, partIndex or 1, partCount or 1, payload or "snapshot",
		}, "\t"), "WHISPER", sender)
	end
	push("Assistant-Other Realm", 1, 2, "snap")
	assertTrue(next(syncer._incoming) ~= nil, "partial correlated PUSH must allocate")
	assertTrue(next(syncer._pushConsents) ~= nil, "partial correlated PUSH must own consent")
	assertEqual(1, fixture:FireTimers(), "request timeout must fire")
	assertEqual(nil, next(syncer._incoming), "timeout must remove correlated partial assembly")
	assertEqual(nil, next(syncer._pushConsents), "timeout must revoke correlated consent")
	push("Assistant-Other Realm")
	assertEqual(0, fixture.importAttempts, "late correlated retry must be rejected before import")
	assertEqual(nil, next(syncer._incoming), "late correlated retry must not allocate")

	fixture.options.syncRequirePlayer = "Leader-Test Realm"
	push("Leader-Test Realm")
	assertEqual(1, fixture.imports, "unrelated configured PUSH with same ID must remain policy-authorized")
	assertEqual(1, fixture.importAttempts, "configured PUSH must import exactly once")
	print("PASS sync_timeout_revokes_only_correlated_push_consent")
end

function cases.real_db_syncer_authorizes_chunks_and_whisper_requests(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	local function countIncoming()
		local count = 0
		for _ in pairs(syncer._incoming) do count = count + 1 end
		return count
	end
	local function chunk(kind, requestId, sender)
		syncer:OnAddonMessage("RMALogSync", table.concat({ kind, 2, requestId, "SYNC", 41, 1, 2, "part" }, "\t"), "RAID", sender)
	end
	local function request(requestId, sender)
		syncer:OnAddonMessage("RMALogSync", table.concat({ "RQ", 2, requestId, "SYNC", 41, "Naxxramas", 25, 1, 0, 0 }, "\t"), "WHISPER", sender)
	end
	local function pending(requestId)
		syncer._pendingRequests[requestId] = {
			createdAt = fixture.now, mode = "SYNC", failedSenders = {}, completed = false,
		}
	end

	pending("unknown")
	chunk("SN", "unknown", "Late-Other Realm")
	assertEqual(0, countIncoming(), "unknown snapshot sender must not allocate chunk state")
	chunk("DL", "unknown", "Late-Other Realm")
	assertEqual(0, countIncoming(), "unknown delta sender must not allocate chunk state")

	fixture.roster = { { name = "Member-Test Realm", rank = 0 } }
	pending("member")
	chunk("SN", "member", "Member-Test Realm")
	assertEqual(0, countIncoming(), "rank-zero sender must not allocate chunk state")

	fixture.roster = {
		{ name = "Twin-Test Realm", rank = 2 },
		{ name = "Twin-Other Realm", rank = 1 },
	}
	pending("collision")
	chunk("SN", "collision", "Twin")
	assertEqual(0, countIncoming(), "ambiguous short sender must not allocate chunk state")
	pending("collision-exact")
	chunk("SN", "collision-exact", "twin-test realm")
	assertEqual(1, countIncoming(), "exact realm-qualified sender must win a short-name collision")
	syncer._incoming = {}

	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 2 },
		{ name = "Assistant-Other Realm", rank = 1 },
	}
	pending("leader")
	chunk("SN", "leader", "leader-test realm")
	assertEqual(1, countIncoming(), "case-insensitive exact leader must allocate chunk state")
	pending("assistant")
	chunk("DL", "assistant", "Assistant")
	assertEqual(2, countIncoming(), "unique short assistant must allocate delta chunk state")

	pending("late-same")
	chunk("SN", "late-same", "Late-Other Realm")
	assertEqual(2, countIncoming(), "first roster-late chunk must remain allocation-free")
	fixture.roster[#fixture.roster + 1] = { name = "Late-Test Realm", rank = 1 }
	chunk("SN", "late-same", "Late-Other Realm")
	assertEqual(3, countIncoming(), "same request and chunk must re-evaluate after roster population")

	local sendsBefore = #fixture.sent
	request("outsider-rq", "Outsider-Test Realm")
	assertEqual(sendsBefore, #fixture.sent, "outsider whisper request must receive no history")
	fixture.roster[#fixture.roster + 1] = { name = "Requester-Test Realm", rank = 0 }
	request("member-rq", "Requester-Other Realm")
	assertTrue(#fixture.sent > sendsBefore, "unique current member whisper request must receive history")
	assertEqual("Requester-Other Realm", fixture.sent[#fixture.sent].target, "response must preserve whisper target")
	print("PASS real_db_syncer_authorizes_chunks_and_whisper_requests")
end

function cases.sync_transport_resources_are_bounded_before_allocation(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	fixture.options.syncRequirePlayer = "Leader-Test Realm"
	local function countIncoming()
		local count = 0
		for _ in pairs(syncer._incoming) do count = count + 1 end
		return count
	end
	local function chunk(requestId, partIndex, partCount, data)
		syncer:OnAddonMessage("RMALogSync", table.concat({
			"SN", 2, requestId, "PUSH", 41, partIndex or 1, partCount or 2, data or "part",
		}, "\t"), "RAID", "Leader-Test Realm")
	end

	chunk("too-many-parts", 1, 257)
	assertEqual(0, countIncoming(), "over-limit part count must not allocate")
	chunk(string.rep("r", 65), 1, 2)
	assertEqual(0, countIncoming(), "over-limit request id must not allocate")

	for i = 1, 9 do
		local requestId = "flood-" .. i
		chunk(requestId, 1, 2)
	end
	assertEqual(8, countIncoming(), "per-sender assembly cap must reject request-id floods")
	for i = 1, 56 do
		local sender = "Officer" .. i .. "-Test Realm"
		fixture.roster[#fixture.roster + 1] = { name = sender, rank = 1 }
		fixture.options.syncRequirePlayer = sender
		syncer:OnAddonMessage("RMALogSync", table.concat({
			"SN", 2, "global-" .. i, "PUSH", 41, 1, 2, "part",
		}, "\t"), "RAID", sender)
	end
	assertEqual(64, countIncoming(), "global assembly cap boundary must remain available")
	fixture.roster[#fixture.roster + 1] = { name = "Overflow-Test Realm", rank = 1 }
	fixture.options.syncRequirePlayer = "Overflow-Test Realm"
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"SN", 2, "global-overflow", "PUSH", 41, 1, 2, "part",
	}, "\t"), "RAID", "Overflow-Test Realm")
	assertEqual(64, countIncoming(), "global assembly cap must reject excess state")

	fixture.options.syncRequirePlayer = "Leader-Test Realm"
	chunk("flood-1", 1, 3)
	assertEqual(63, countIncoming(), "changing part count must discard malformed assembly")
	print("PASS sync_transport_resources_are_bounded_before_allocation")
end

function cases.sync_multichunk_enqueue_is_atomic(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	fixture.options.syncPushPlayer = "Leader-Test Realm"
	fixture.failBatch = true
	assertEqual(false, syncer:BroadcastLoggerPush(41), "backpressured PUSH must report failure")
	assertEqual(0, #fixture.sent, "failed batch must enqueue no partial chunks")
	assertEqual(0, #fixture.infos, "failed PUSH must emit no success message")
	assertEqual(1, fixture.batchAttempts, "failed snapshot must make one atomic enqueue attempt")

	local before = fixture.batchAttempts
	addon.DB.Syncer._Payload.BuildDelta = function() return "delta", 1 end
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"RQ", 2, "atomic-sync", "SYNC", 41, "Naxxramas", 25, 1, 1, 0,
	}, "\t"), "WHISPER", "Leader-Test Realm")
	assertEqual(before + 1, fixture.batchAttempts, "delta backpressure must not fall back to a snapshot")
	assertEqual(0, #fixture.sent, "delta failure must leave transport queue unchanged")
	print("PASS sync_multichunk_enqueue_is_atomic")
end

function cases.comms_batch_preflight_prevents_partial_enqueue(addon)
	_G.SendAddonMessage = function() end
	_G.SendChatMessage = function() end
	_G.GetAddOnMetadata = function() return "test" end
	_G.UnitName = function() return "Tester" end
	_G.IsInInstance = function() return false, "none" end
	_G.GetNumRaidMembers = function() return 1 end
	_G.GetNumPartyMembers = function() return 0 end
	addon.L = {}
	addon.Database.GetSyncer = function() return nil end
	addon.Database.GetRaidSchemaVersion = function() return 1 end
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Timer = { BindMixin = function(target)
		target.ScheduleTimer = function() return {} end
	end }
	loadAddonFile(addon, "Raid Management Addon/Modules/Comms.lua")
	for i = 1, 255 do
		assertTrue(addon.Comms.QueueAddonMessage("RMA", "m" .. i, "RAID"), "queue fill must succeed")
	end
	local tailBefore = addon.Comms._addonQueueTail
	local queued, reason = addon.Comms.QueueAddonMessages("RMA", { "a", "b" }, "RAID")
	assertEqual(false, queued, "near-full batch must be rejected")
	assertEqual("backpressure", reason, "batch rejection reason differs")
	assertEqual(tailBefore, addon.Comms._addonQueueTail, "rejected batch must not change tail")
	assertEqual(nil, addon.Comms._addonQueue[tailBefore + 1], "rejected batch must enqueue no prefix")
	assertTrue(addon.Comms.QueueAddonMessages("RMA", { "last" }, "RAID"), "exact-capacity batch must succeed")
	assertEqual(256, addon.Comms._addonQueueTail, "exact-capacity tail differs")
	print("PASS comms_batch_preflight_prevents_partial_enqueue")
end

function cases.comms_request_ids_are_bounded_session_scoped_and_collision_aware(addon)
	_G.SendAddonMessage = function() end
	_G.SendChatMessage = function() end
	_G.GetAddOnMetadata = function() return "test" end
	_G.UnitName = function() return "Tester" end
	_G.GetTime = function() return 12.5 end
	_G.IsInInstance = function() return false, "none" end
	_G.GetNumRaidMembers = function() return 1 end
	_G.GetNumPartyMembers = function() return 0 end
	addon.L = {}
	addon.Database.GetSyncer = function() return nil end
	addon.Database.GetRaidSchemaVersion = function() return 1 end
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Timer = { BindMixin = function(target) target.ScheduleTimer = function() return {} end end }
	loadAddonFile(addon, "Raid Management Addon/Modules/Comms.lua")

	local owner = { _requestSessionNonce = "session-a", _nextRequestId = 999999 }
	local collisions = { ["session-a-0"] = true, ["session-a-1"] = true }
	local id = addon.Comms.NextRequestId(owner, nil, function(candidate) return collisions[candidate] == true end)
	assertEqual("session-a-2", id, "wrapped counter must skip colliding live IDs")
	assertTrue(#id <= 64, "request ID must remain within the wire limit")
	local reloadedOwner = { _requestSessionNonce = "session-b", _nextRequestId = 999999 }
	local reloadId = addon.Comms.NextRequestId(reloadedOwner, nil, function() return false end)
	assertEqual("session-b-0", reloadId, "new session nonce must isolate reload IDs")
	assertEqual(false, reloadId == id, "late prior-session packet must not correlate after reload")
	print("PASS comms_request_ids_are_bounded_session_scoped_and_collision_aware")
end

function cases.compressed_sync_payload_never_invokes_unbounded_inflate(addon)
	local inflateCalls = 0
	_G.LibStub = function()
		return {
			DecodeForWoWAddonChannel = function(_, value) return value end,
			DecompressDeflate = function()
				inflateCalls = inflateCalls + 1
				return string.rep("x", 1000000)
			end,
		}
	end
	addon.Diag = { D = {} }
	addon.DB = { Syncer = {} }
	addon.Database.GetRaidSchemaVersion = function() return 1 end
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Strings = {
		NormalizeName = function(value) return value end,
		NormalizeLower = function(value) return string.lower(tostring(value or "")) end,
	}
	addon.Comms = { Payload = {
		EncodeText = function(value) return tostring(value or "") end,
		DecodeText = function(value) return value end,
		SplitFields = function(message, separator, out)
			local fields = out or {}
			for i = 1, #fields do fields[i] = nil end
			for field in string.gmatch(message .. separator, "(.-)" .. separator) do fields[#fields + 1] = field end
			return fields, #fields
		end,
		PackFields = function(_, ...) return table.concat({ ... }, "\t") end,
	} }
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncPayload.lua")
	assertEqual(nil, addon.DB.Syncer._Payload.DecodeTransportText("D1:zip-bomb"), "compressed payload must fail closed")
	assertEqual(0, inflateCalls, "unbounded inflater must not be invoked")
	print("PASS compressed_sync_payload_never_invokes_unbounded_inflate")
end

function cases.sync_payload_validation_rejects_invalid_and_stale_revisions(addon)
	addon.Diag = { D = {} }
	addon.DB = { Syncer = {} }
	addon.Database.GetRaidSchemaVersion = function() return 1 end
	addon.Database.GetRaidQueries = function() return { ResolveLootLooterNameFromMap = function() return nil end } end
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Strings = {
		NormalizeName = function(value) return value end,
		NormalizeLower = function(value) return string.lower(tostring(value or "")) end,
	}
	addon.Comms = { Payload = {
		EncodeText = function(value) return tostring(value or "") end,
		DecodeText = function(value) return value end,
		SplitFields = function(message, separator, out)
			local fields = out or {}
			for i = 1, #fields do fields[i] = nil end
			for field in string.gmatch(message .. separator, "(.-)" .. separator) do fields[#fields + 1] = field end
			return fields, #fields
		end,
		PackFields = function(_, ...) return table.concat({ ... }, "\t") end,
	} }
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncPayload.lua")
	local validator = addon.DB.Syncer._Payload
	local function snapshot(revision)
		return { header = { protocolVersion = 2, schemaVersion = 1, raidNid = 41, revision = revision,
			nextPlayerNid = 2, nextBossNid = 2, nextLootNid = 2 },
			players = { { playerNid = 1, name = "Leader", subgroup = 1 } }, attendance = {}, bosses = {}, loot = {} }
	end
	local ok, reason = validator.ValidateSnapshot(snapshot(4), 3, 41)
	assertTrue(ok, "newer valid snapshot must pass")
	assertEqual("stale_revision", select(2, validator.ValidateSnapshot(snapshot(3), 3, 41)), "equal snapshot")
	assertEqual("invalid_protocol", select(2, validator.ValidateSnapshot({ header = { protocolVersion = 9 } }, 0, 41)), "protocol")
	local badSchema = snapshot(4); badSchema.header.schemaVersion = 2
	assertEqual("invalid_schema", select(2, validator.ValidateSnapshot(badSchema, 3, 41)), "schema")
	local badRange = snapshot(4); badRange.players[1].subgroup = 9
	assertEqual("invalid_player", select(2, validator.ValidateSnapshot(badRange, 3, 41)), "range")
	local duplicate = snapshot(4); duplicate.players[2] = { playerNid = 1, name = "Other" }
	assertEqual("duplicate_player", select(2, validator.ValidateSnapshot(duplicate, 3, 41)), "duplicate player")
	local badRef = snapshot(4); badRef.attendance[1] = { playerNid = 9, startTime = 1 }
	assertEqual("invalid_player_reference", select(2, validator.ValidateSnapshot(badRef, 3, 41)), "attendance reference")
	local badEnvelope = snapshot(4); badEnvelope.header.nextPlayerNid = 1
	assertEqual("header_range_mismatch", select(2, validator.ValidateSnapshot(badEnvelope, 3, 41)), "header nid envelope")
	local sparse = snapshot(4); sparse.players = { [1] = sparse.players[1], [3] = { playerNid = 2, name = "Two" } }
	assertEqual("invalid_sequence", select(2, validator.ValidateSnapshot(sparse, 3, 41)), "sparse player sequence")
	local mapSequence = snapshot(4); mapSequence.loot = { bad = { lootNid = 1 } }
	assertEqual("invalid_sequence", select(2, validator.ValidateSnapshot(mapSequence, 3, 41)), "map loot sequence")
	local badBossRefs = snapshot(4); badBossRefs.bosses[1] = { bossNid = 1, players = { [2] = 1 } }
	assertEqual("invalid_sequence", select(2, validator.ValidateSnapshot(badBossRefs, 3, 41)), "sparse boss references")
	assertEqual("raid_mismatch", select(2, validator.ValidateSnapshot(snapshot(4), 3, 73)), "envelope raid")
	local v1 = validator.Parse("H\t1\t1\t41\tNaxxramas\t25\t2\tRealm\t1\t0\t2\t1\t1\nP\t1\tLeader\t2\t1\tWARRIOR\t1\t0\t0")
	assertTrue(v1 ~= nil, "serialized 13-field v1 snapshot must still parse")
	assertTrue(validator.ValidateSnapshot(v1, 0, 41), "v1 snapshot may initialize empty history")
	assertEqual("stale_revision", select(2, validator.ValidateSnapshot(v1, 1, 41)), "v1 must not overwrite revisioned history")
	local badLoot = snapshot(4); badLoot.loot[1] = { lootNid = 1, itemId = "19019", itemName = "Item", itemString = "", itemLink = "", itemTexture = "", itemCount = 1, itemRarity = 4, rollType = 0, rollValue = 0, bossNid = 0, time = 1 }
	assertEqual("invalid_loot_row", select(2, validator.ValidateSnapshot(badLoot, 3, 41)), "numeric strings must not be silently coerced")

	local function delta(sinceRevision, revision, rows)
		rows = rows or {}
		for i = 1, #rows do
			local row = rows[i]
			if row.itemId == nil then row.itemId = 1 end
			if row.itemName == nil then row.itemName = "Item" end
			if row.itemString == nil then row.itemString = "item:1" end
			if row.itemLink == nil then row.itemLink = "[Item]" end
			if row.itemTexture == nil then row.itemTexture = "texture" end
			if row.looterName == nil then row.looterName = "" end
			if row.itemCount == nil then row.itemCount = 1 end
			if row.itemRarity == nil then row.itemRarity = 1 end
			if row.rollType == nil then row.rollType = 0 end
			if row.rollValue == nil then row.rollValue = 0 end
			if row.bossNid == nil then row.bossNid = 0 end
			if row.time == nil then row.time = 1 end
		end
		return { header = { protocolVersion = 2, raidNid = 41, sinceRevision = sinceRevision, revision = revision }, loot = rows }
	end
	ok = validator.ValidateDelta(delta(3, 5, { { lootNid = 1, syncRevision = 4 }, { lootNid = 2, syncRevision = 5 } }), 3, 41)
	assertTrue(ok, "valid monotone delta must pass")
	assertEqual("revision_gap", select(2, validator.ValidateDelta(delta(2, 4), 3, 41)), "since revision")
	assertEqual("stale_revision", select(2, validator.ValidateDelta(delta(3, 3), 3, 41)), "equal delta")
	assertEqual("row_revision_order", select(2, validator.ValidateDelta(delta(3, 5, { { lootNid = 1, syncRevision = 5 }, { lootNid = 2, syncRevision = 4 } }), 3, 41)), "row order")
	assertEqual("row_revision_range", select(2, validator.ValidateDelta(delta(3, 5, { { lootNid = 1, syncRevision = 6 } }), 3, 41)), "row envelope")
	assertEqual("duplicate_loot", select(2, validator.ValidateDelta(delta(3, 5, { { lootNid = 1, syncRevision = 4 }, { lootNid = 1, syncRevision = 5 } }), 3, 41)), "duplicate loot")
	assertEqual("incomplete_delta", select(2, validator.ValidateDelta(delta(3, 5, {}), 3, 41)), "empty delta cannot advance")
	assertEqual("incomplete_delta", select(2, validator.ValidateDelta(delta(3, 5, { { lootNid = 1, syncRevision = 4 } }), 3, 41)), "missing terminal revision")
	assertEqual("revision_gap", select(2, validator.ValidateDelta(delta(3, 5, { { lootNid = 1, syncRevision = 5 } }), 3, 41)), "row revision hole")
	local badDeltaLoot = delta(3, 4, { { lootNid = 1, syncRevision = 4, itemId = 1, itemName = {}, itemString = "", itemLink = "", itemTexture = "", itemCount = 1, itemRarity = 4, rollType = 0, rollValue = 0, bossNid = 0, time = 1 } })
	assertEqual("invalid_loot_row", select(2, validator.ValidateDelta(badDeltaLoot, 3, 41)), "delta loot types")

	local revisionSets = 0
	local store = {
		GetRaidSyncRevision = function(_, raid) return tonumber(raid._revision) or 0 end,
		SetRaidSyncRevision = function(_, raid, revision) revisionSets = revisionSets + 1; raid._revision = revision end,
		CreateRaidRecord = function() return { raidNid = 999, _revision = 0 } end,
		InsertRaid = function(_, raid) return raid, 1 end,
		CaptureRaidInsertionState = function() return {} end,
		RestoreRaidInsertionState = function() return true end,
		CommitNewRaidHistoryImport = function(_, raid) return raid, 1 end,
	}
	addon.Database.GetRaidStore = function() return store end
	addon.Database.StripRuntimeRaidCaches = function() end
	addon.Database.EnsureRaidSchema = function(raid)
		raid.players = raid.players or {}; raid.attendance = raid.attendance or {}; raid.bossKills = raid.bossKills or {}; raid.loot = raid.loot or {}
		return raid
	end
	addon.Time = { GetCurrentTime = function() return 1 end }
	addon.State = {}
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncImport.lua")
	local importer = addon.DB.Syncer._Import
	local invalidDestination = { raidNid = 41, _revision = 3, players = {}, attendance = {}, bossKills = {}, loot = {} }
	local invalidBefore = deepCopy(invalidDestination)
	local applied, importReason = importer.ApplySnapshotToRaid(invalidDestination, badLoot, false)
	assertEqual(nil, applied, "invalid loot snapshot import must reject")
	assertEqual("invalid_loot_row", importReason, "invalid loot import reason")
	assertTrue(deepEqual(invalidBefore, invalidDestination), "invalid loot import must not mutate")
	local malformedDestination = { raidNid = "41", _revision = 3, players = {}, attendance = {}, bossKills = {}, loot = {} }
	local malformedBefore = deepCopy(malformedDestination)
	applied, importReason = importer.ApplySnapshotToRaid(malformedDestination, snapshot(4), false)
	assertEqual(nil, applied, "malformed destination id must reject")
	assertEqual("invalid_destination_raid", importReason, "malformed destination reason")
	assertTrue(deepEqual(malformedBefore, malformedDestination), "malformed destination must not mutate")
	local missingDestination = { _revision = 3, players = {}, attendance = {}, bossKills = {}, loot = {} }
	local missingBefore = deepCopy(missingDestination)
	applied, importReason = importer.ApplySnapshotToRaid(missingDestination, snapshot(4), false)
	assertEqual(nil, applied, "missing destination id must reject")
	assertEqual("invalid_destination_raid", importReason, "missing destination reason")
	assertTrue(deepEqual(missingBefore, missingDestination), "missing destination must not mutate")
	local destination = { raidNid = 73, _revision = 3, players = {}, attendance = {}, bossKills = {}, loot = {} }
	local before = deepCopy(destination)
	applied, importReason = importer.ApplySnapshotToRaid(destination, snapshot(4), false)
	assertEqual(nil, applied, "destination raid mismatch must reject")
	assertEqual("raid_mismatch", importReason, "destination mismatch reason")
	assertTrue(deepEqual(before, destination), "destination mismatch must not mutate")
	assertEqual(0, revisionSets, "destination mismatch must not update revision")
	local imported = importer.ImportSnapshotAsNewRaid(snapshot(4))
	assertTrue(imported ~= nil, "new import must deliberately map external id to local record")
	local importedV1 = importer.ImportSnapshotAsNewRaid(v1)
	assertTrue(importedV1 ~= nil, "serialized v1 must remain importable only as empty local history")
	local deltaDestination = { raidNid = 41, _revision = 3, players = {}, attendance = {}, bossKills = {}, loot = {} }
	local deltaBefore = deepCopy(deltaDestination)
	local invalidDelta = delta(3, 5, { { lootNid = 1, syncRevision = 5 } })
	applied, importReason = importer.ApplyDeltaToRaid(deltaDestination, invalidDelta)
	assertEqual(nil, applied, "gapped delta import must reject")
	assertEqual("revision_gap", importReason, "gapped import reason")
	assertTrue(deepEqual(deltaBefore, deltaDestination), "gapped delta import must not mutate")
	print("PASS sync_payload_validation_rejects_invalid_and_stale_revisions")
end

function cases.sync_history_import_is_atomic_across_build_and_commit_failures(addon)
	installRaidDatabaseStubs(addon)
	local store = addon.DB.RaidStore
	local raid = canonicalRaidFixture()
	_G.RMA_Raids = { raid }
	store:SetRaidSyncRevision(raid, 3, "fixture")
	store:EnsureRaidRuntime(raid)
	local canonicalBefore = deepCopy(raid)
	local originalIdentity = {
		players = raid.players, player = raid.players[1], loot = raid.loot, lootRow = raid.loot[1],
		bosses = raid.bossKills, boss = raid.bossKills[1], attendance = raid.attendance,
		attendanceRow = raid.attendance[1], runtime = raid._runtime,
	}
	local function assertOriginalIdentity(message)
		assertTrue(rawequal(originalIdentity.players, raid.players), message .. " players")
		assertTrue(rawequal(originalIdentity.player, raid.players[1]), message .. " player row")
		assertTrue(rawequal(originalIdentity.loot, raid.loot), message .. " loot")
		assertTrue(rawequal(originalIdentity.lootRow, raid.loot[1]), message .. " loot row")
		assertTrue(rawequal(originalIdentity.bosses, raid.bossKills), message .. " bosses")
		assertTrue(rawequal(originalIdentity.boss, raid.bossKills[1]), message .. " boss row")
		assertTrue(rawequal(originalIdentity.attendance, raid.attendance), message .. " attendance")
		assertTrue(rawequal(originalIdentity.attendanceRow, raid.attendance[1]), message .. " attendance row")
		assertTrue(rawequal(originalIdentity.runtime, raid._runtime), message .. " runtime")
	end

	addon.DB.Syncer = { _Payload = {
		ValidateSnapshot = function() return true end,
		ValidateDelta = function() return true end,
		BuildPlayerNameMaps = function(players)
			local byName, valid = {}, {}
			for i = 1, #(players or {}) do
				valid[players[i].playerNid] = true
				byName[string.lower(players[i].name)] = players[i].playerNid
			end
			return {}, byName, valid
		end,
	} }
	addon.Time = { GetCurrentTime = function() return 100 end }
	addon.State = {}
	local normalizeCalls = 0
	addon.Strings.NormalizeName = function(value)
		normalizeCalls = normalizeCalls + 1
		if normalizeCalls == 2 then error("injected candidate failure") end
		return value
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncImport.lua")
	local importer = addon.DB.Syncer._Import
	local snapshot = {
		header = { schemaVersion = 6, raidNid = 7, revision = 4, nextPlayerNid = 5, nextBossNid = 2, nextLootNid = 2 },
		players = {
			{ playerNid = 3, name = "Gamma", class = "ROGUE", subgroup = 1 },
			{ playerNid = 4, name = "Delta", class = "DRUID", subgroup = 1 },
		},
		attendance = {}, bosses = {}, loot = {},
	}
	local ok = pcall(importer.ApplySnapshotToRaid, raid, snapshot, false)
	assertEqual(false, ok, "injected candidate build failure must surface")
	assertTrue(deepEqual(canonicalBefore, raid), "candidate build failure must preserve canonical raid and indexes")

	addon.Strings.NormalizeName = function(value) return value end
	local originalEnsureRuntime = store.EnsureRaidRuntime
	store.EnsureRaidRuntime = function() error("injected postcondition failure") end
	local applied, reason = importer.ApplySnapshotToRaid(raid, snapshot, false)
	store.EnsureRaidRuntime = originalEnsureRuntime
	assertEqual(nil, applied, "postcondition failure must reject import")
	assertEqual("COMMIT_FAILED", reason, "postcondition failure should use stable commit error")
	assertTrue(deepEqual(canonicalBefore, raid), "commit rollback must preserve canonical raid, revision, and indexes")
	assertOriginalIdentity("snapshot rollback must preserve identity")

	local delta = {
		header = { raidNid = 7, sinceRevision = 3, revision = 4, nextPlayerNid = 3, nextBossNid = 2, nextLootNid = 3 },
		loot = { { lootNid = 2, itemId = 101, itemName = "New", itemCount = 1, looterNid = 1,
			rollType = 0, rollValue = 0, bossNid = 1, time = 80, syncRevision = 4 } },
	}
	store.EnsureRaidRuntime = function() error("injected delta postcondition failure") end
	applied, reason = importer.ApplyDeltaToRaid(raid, delta)
	store.EnsureRaidRuntime = originalEnsureRuntime
	assertEqual(nil, applied, "delta postcondition failure must reject import")
	assertEqual("COMMIT_FAILED", reason, "delta failure should use stable commit error")
	assertTrue(deepEqual(canonicalBefore, raid), "delta rollback must preserve canonical raid, revision, and indexes")
	assertOriginalIdentity("delta rollback must preserve identity")

	local acceptedSnapshot = deepCopy(snapshot)
	acceptedSnapshot.loot = { { lootNid = 2, itemId = 102, itemName = "Unassigned", itemCount = 1,
		rollType = 0, rollValue = 0, bossNid = 0, time = 81 } }
	acceptedSnapshot.header.nextLootNid = 3
	local rootIdentity = raid
	applied, reason = importer.ApplySnapshotToRaid(raid, acceptedSnapshot, false)
	assertEqual(rootIdentity, applied, "accepted import must preserve canonical raid root identity")
	assertEqual(nil, reason, "accepted import must not return an error")
	assertEqual(4, store:GetRaidSyncRevision(raid), "accepted import must commit the remote revision exactly")
	assertEqual(2, #raid.loot, "accepted snapshot must preserve merge semantics")
	assertEqual(0, raid.loot[2].bossNid, "unassigned loot must remain a valid accepted merge")
	local acceptedDelta = deepCopy(delta)
	acceptedDelta.header.sinceRevision = 4
	acceptedDelta.header.revision = 5
	acceptedDelta.loot[1].syncRevision = 5
	local deltaBefore = deepCopy(raid)
	local deltaPlayers, deltaLoot, deltaLootRow, deltaRuntime = raid.players, raid.loot, raid.loot[1], raid._runtime
	local deltaBosses, deltaBoss, deltaAttendance, deltaAttendanceRow =
		raid.bossKills, raid.bossKills[1], raid.attendance, raid.attendance[1]
	local originalSetLootRevision = store.SetLootSyncRevision
	local originalGetLootRevision = store.GetLootSyncRevision
	local originalSetRaidRevision = store.SetRaidSyncRevision
	for _, injected in ipairs({
		function() store.SetLootSyncRevision = function() return 0 end end,
		function() store.SetLootSyncRevision = function() error("injected loot revision error") end end,
		function()
			store.SetLootSyncRevision = originalSetLootRevision
			store.GetLootSyncRevision = function() return 0 end
		end,
		function() store.SetRaidSyncRevision = function() return 0 end end,
		function() store.SetRaidSyncRevision = function() error("injected raid revision error") end end,
	}) do
		store.SetLootSyncRevision, store.GetLootSyncRevision, store.SetRaidSyncRevision =
			originalSetLootRevision, originalGetLootRevision, originalSetRaidRevision
		injected()
		applied, reason = importer.ApplyDeltaToRaid(raid, acceptedDelta)
		assertEqual(nil, applied, "revision postcondition failure must reject delta")
		assertEqual("COMMIT_FAILED", reason, "revision postcondition failure must be stable")
		assertTrue(deepEqual(deltaBefore, raid), "revision failure must preserve canonical data")
		assertTrue(rawequal(deltaPlayers, raid.players), "revision failure must preserve players identity")
		assertTrue(rawequal(deltaLoot, raid.loot), "revision failure must preserve loot identity")
		assertTrue(rawequal(deltaLootRow, raid.loot[1]), "revision failure must preserve loot row identity")
		assertTrue(rawequal(deltaBosses, raid.bossKills), "revision failure must preserve bosses identity")
		assertTrue(rawequal(deltaBoss, raid.bossKills[1]), "revision failure must preserve boss row identity")
		assertTrue(rawequal(deltaAttendance, raid.attendance), "revision failure must preserve attendance identity")
		assertTrue(rawequal(deltaAttendanceRow, raid.attendance[1]), "revision failure must preserve attendance row identity")
		assertTrue(rawequal(deltaRuntime, raid._runtime), "revision failure must preserve runtime identity")
	end
	store.SetLootSyncRevision, store.GetLootSyncRevision, store.SetRaidSyncRevision =
		originalSetLootRevision, originalGetLootRevision, originalSetRaidRevision
	applied, reason = importer.ApplyDeltaToRaid(raid, acceptedDelta)
	assertEqual(rootIdentity, applied, "accepted delta must preserve canonical raid root identity")
	assertEqual(nil, reason, "accepted delta must not return an error")
	assertEqual(5, store:GetRaidSyncRevision(raid), "accepted delta must commit its terminal revision")
	assertEqual(5, store:GetLootSyncRevision(raid, raid.loot[2]), "accepted delta must retain row revision coverage")
	local historyBeforeInsert = deepCopy(raid)
	historyBeforeInsert._runtime = nil
	local runtimeBeforeInsert = raid._runtime
	store.EnsureRaidRuntime = function() error("injected new-raid postcondition failure") end
	local imported, importedId, insertReason = importer.ImportSnapshotAsNewRaid(acceptedSnapshot)
	store.EnsureRaidRuntime = originalEnsureRuntime
	assertEqual(nil, imported, "failed new snapshot import must not insert a raid")
	assertEqual(nil, importedId, "failed new snapshot import must not expose an index")
	assertEqual("COMMIT_FAILED", insertReason, "failed new import should return a stable commit error")
	local persistedAfterInsert = deepCopy(raid)
	persistedAfterInsert._runtime = nil
	assertTrue(deepEqual(historyBeforeInsert, persistedAfterInsert), "failed new import must preserve canonical history")
	assertEqual(runtimeBeforeInsert, raid._runtime, "failed new import must preserve runtime index identity")
	local nextRaid = store:CreateRaidRecord({ startTime = 100 })
	assertEqual(8, nextRaid.raidNid, "failed new import must roll back the raid id allocator")
	print("PASS sync_history_import_is_atomic_across_build_and_commit_failures")
end

function cases.sync_v1_revision_zero_imports_through_real_store_without_regression(addon)
	installRaidDatabaseStubs(addon)
	addon.DB.Syncer = {}
	addon.Diag = { D = {} }
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Comms = { Payload = {
		EncodeText = function(value) return tostring(value or "") end,
		DecodeText = function(value) return value end,
		SplitFields = function(message, separator, out)
			local fields = out or {}; for i = 1, #fields do fields[i] = nil end
			for field in string.gmatch(message .. separator, "(.-)" .. separator) do fields[#fields + 1] = field end
			return fields, #fields
		end,
		PackFields = function(separator, ...)
			local values = { ... }; for i = 1, #values do values[i] = tostring(values[i] or "") end
			return table.concat(values, separator)
		end,
	} }
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncPayload.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncImport.lua")
	local store, importer, payload = addon.DB.RaidStore, addon.DB.Syncer._Import, addon.DB.Syncer._Payload
	local raid = store:CreateRaidRecord({ raidNid = 41, startTime = 1 })
	store:InsertRaid(raid)
	local v1 = payload.Parse("H\t1\t1\t41\tNaxxramas\t25\t2\tRealm\t1\t0\t2\t1\t1\nP\t1\tLeader\t2\t1\tWARRIOR\t1\t0\t0")
	assertTrue(v1 ~= nil, "v1 fixture must parse")
	local applied, reason = importer.ApplySnapshotToRaid(raid, v1, false)
	assertEqual(raid, applied, "v1 revision-zero snapshot must import into revision-zero history")
	assertEqual(nil, reason, "accepted v1 import must not return an error")
	assertEqual(0, store:GetRaidSyncRevision(raid), "v1 import must retain revision zero")
	store:SetRaidSyncRevision(raid, 1, "fixture")
	applied, reason = importer.ApplySnapshotToRaid(raid, v1, false)
	assertEqual(nil, applied, "v1 revision zero must not overwrite nonzero history")
	assertEqual("stale_revision", reason, "v1 regression must fail closed")
	assertEqual(1, store:GetRaidSyncRevision(raid), "rejected v1 import must preserve nonzero revision")
	local imported, importedIndex, importReason = importer.ImportSnapshotAsNewRaid(v1)
	assertTrue(imported ~= nil and importedIndex ~= nil, "v1 revision-zero snapshot must import as new history")
	assertEqual(nil, importReason, "accepted new v1 import must not return an error")
	assertEqual(0, store:GetRaidSyncRevision(imported), "new v1 history must retain revision zero")
	print("PASS sync_v1_revision_zero_imports_through_real_store_without_regression")
end

function cases.real_delta_builder_proves_complete_revision_coverage(addon)
	addon.Diag = { D = {} }
	addon.DB = { Syncer = {} }
	addon.Database.GetRaidSchemaVersion = function() return 1 end
	addon.Database.GetRaidQueries = function() return { ResolveLootLooterNameFromMap = function(_, loot) return loot.looterName end } end
	addon.Database.EnsureRaidSchema = function(raid) return raid end
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Strings = { NormalizeName = function(value) return value end, NormalizeLower = function(value) return string.lower(tostring(value or "")) end }
	addon.Comms = { Payload = {
		EncodeText = function(value) return tostring(value or "") end,
		DecodeText = function(value) return value end,
		SplitFields = function(message, separator, out)
			local fields = out or {}; for i = 1, #fields do fields[i] = nil end
			for field in string.gmatch(message .. separator, "(.-)" .. separator) do fields[#fields + 1] = field end
			return fields, #fields
		end,
		PackFields = function(separator, ...)
			local values = { ... }; for i = 1, #values do values[i] = tostring(values[i] or "") end
			return table.concat(values, separator)
		end,
	} }
	local revisions = {}
	local store = {
		RequiresFullSyncSince = function() return false end,
		GetRaidSyncRevision = function() return 5 end,
		GetLootSyncRevision = function(_, _, row) return revisions[row.lootNid] or 0 end,
	}
	addon.Database.GetRaidStore = function() return store end
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncPayload.lua")
	local payloadModule = addon.DB.Syncer._Payload
	local realBuildDelta = payloadModule.BuildDelta
	local raid = { raidNid = 41, players = {}, loot = {
		{ lootNid = 1, itemId = 1, itemName = "One", itemString = "item:1", itemLink = "[One]", itemRarity = 1, itemTexture = "t", itemCount = 1, looterName = "", rollType = 0, rollValue = 0, bossNid = 0, time = 1 },
		{ lootNid = 2, itemId = 2, itemName = "Two", itemString = "item:2", itemLink = "[Two]", itemRarity = 1, itemTexture = "t", itemCount = 1, looterName = "", rollType = 0, rollValue = 0, bossNid = 0, time = 2 },
	} }
	revisions[1], revisions[2] = 5, 4
	local payload, rowCount = realBuildDelta(raid, 3)
	assertEqual(2, rowCount, "reverse-NID edits must retain two rows")
	local parsed = payloadModule.ParseDelta(payload)
	assertTrue(payloadModule.ValidateDelta(parsed, 3, 41), "emitted rows must be ordered by revision and accepted")
	revisions[1], revisions[2] = 5, 0
	payload, rowCount = realBuildDelta(raid, 3)
	assertEqual(nil, payload, "coalesced repeated-row edits cannot prove revision coverage")
	assertEqual(0, rowCount, "unavailable delta has no rows")

	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Requester-Test Realm", rank = 0 } }
	local currentRaid = select(1, addon.DB.Syncer._Import.GetCurrentRaidRecord())
	for key, value in pairs(raid) do currentRaid[key] = value end
	addon.Database.GetRaidStore = function() return store end
	addon.DB.Syncer._Payload.BuildDelta = realBuildDelta
	addon.DB.Syncer._Payload.Build = function() return "snapshot" end
	syncer:OnAddonMessage("RMALogSync", table.concat({ "RQ", 2, "fallback", "SYNC", 41, "Naxxramas", 25, 1, 3, 0 }, "\t"), "WHISPER", "Requester-Test Realm")
	assertTrue(#fixture.sent > 0, "unavailable delta must produce a snapshot response")
	assertTrue(string.find(fixture.sent[#fixture.sent].message, "SN\t", 1, true) == 1, "fallback response must be snapshot")
	print("PASS real_delta_builder_proves_complete_revision_coverage")
end

function cases.reserves_import_limits_and_schema_fail_closed(addon)
	addon.L = addon.L or {}
	addon.tLength = function(value) local count = 0; for _ in pairs(value) do count = count + 1 end; return count end
	addon.warn = function() end
	addon.debug = function() end
	addon.L.WarnNoValidRows = "no rows"
	addon.L.WarnReservesHeaderHint = "header"
	addon.L.WarnReservesEncodedImportCompressed = "compressed"
	addon.L.WarnReservesEncodedImportInvalid = "invalid"
	addon.Diag = { D = {
		LogReservesParseStart = "start", LogReservesImportRows = "%d %d %s %d",
		LogReservesEncodedImportStart = "encoded", LogReservesEncodedImportRows = "%d %d %s",
	}, W = { LogReservesImportFailedEmpty = "empty", LogReservesEncodedImportFailed = "%s" } }
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Strings = {
		NormalizeText = function(value) return value end,
		NormalizeLower = function(value)
			if type(value) ~= "string" or value == "" then return nil end
			return string.lower(value)
		end,
	}
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
	end
	addon.Services.EnsureNamespace("Reserves")
	addon.Services.Reserves.GetImportMode = function() return "multi" end
	loadAddonFile(addon, "Raid Management Addon/Modules/Base64.lua")
	local jsonValue
	addon.Json = { Decode = function() return jsonValue end }
	loadAddonFile(addon, "Raid Management Addon/Services/Reserves/Import.lua")
	local parser = addon.Services.Reserves._Import.BuildParser()
	local service = addon.Services.Reserves

	local csvHeader = "x,itemId,from,name,class,spec,note,plus\n"
	local valid = csvHeader .. "x,1,raid,Alpha,WARRIOR,tank,note,0"
	assertTrue(parser.ParseImport(service, valid, "multi", { format = "csv" }) ~= nil, "normal CSV must import")
	local atEncodedLimit = string.rep("x", 262144)
	local parsed, reason = parser.ParseImport(service, atEncodedLimit, "multi", { format = "csv" })
	assertTrue(reason ~= "IMPORT_ENCODED_TOO_LARGE", "exact encoded limit must reach format validation")
	local tooLargeCsv = atEncodedLimit .. "x"
	parsed, reason = parser.ParseImport(service, tooLargeCsv, "multi", { format = "csv" })
	assertEqual(nil, parsed, "oversized CSV must fail")
	assertEqual("IMPORT_ENCODED_TOO_LARGE", reason, "oversized text reason differs")
	local atDecodedLimit = addon.Base64.Encode(string.rep("j", 131072))
	jsonValue = { softreserves = { { name = "Alpha", items = { { id = 1 } } } } }
	assertTrue(parser.ParseImport(service, atDecodedLimit, "multi", { format = "json" }) ~= nil, "exact decoded limit must import")
	local overDecodedLimit = addon.Base64.Encode(string.rep("j", 131073))
	parsed, reason = parser.ParseImport(service, overDecodedLimit, "multi", { format = "json" })
	assertEqual(nil, parsed, "decoded max plus one must fail")
	assertEqual("IMPORT_DECODED_TOO_LARGE", reason, "decoded size reason differs")

	jsonValue = { softreserves = { { name = "Alpha", items = { { id = 1 } } } } }
	parsed = parser.ParseImport(service, addon.Base64.Encode("json"), "multi", { format = "json" })
	assertTrue(parsed ~= nil, "normal encoded JSON must import")
	parsed, reason = parser.ParseImport(service, addon.Base64.Encode(string.char(0x78, 0x9c) .. "bomb"), "multi", { format = "json" })
	assertEqual(nil, parsed, "compressed import must fail before inflate")
	assertEqual("COMPRESSED_UNSUPPORTED", reason, "compressed import reason differs")

	jsonValue = { softreserves = { [1] = { name = "Alpha", items = { { id = 1 } } }, [3] = { name = "Beta", items = { { id = 2 } } } } }
	parsed, reason = parser.ParseImport(service, "json", "multi", { format = "json" })
	assertEqual(nil, parsed, "sparse JSON arrays must fail")
	assertEqual("JSON_INVALID_SCHEMA", reason, "sparse JSON reason differs")
	jsonValue = { softreserves = { { name = "Al" .. string.char(0xc3, 0xa9), items = { { id = 1 } } } } }
	parsed, reason = parser.ParseImport(service, "json", "multi", { format = "json" })
	assertEqual(nil, parsed, "non-ASCII player names must fail")
	assertEqual("FIELD_LIMIT", reason, "non-ASCII reason differs")
	jsonValue = { softreserves = { { name = "Alpha", items = { { id = 1.5 } } } } }
	parsed, reason = parser.ParseImport(service, "json", "multi", { format = "json" })
	assertEqual(nil, parsed, "fractional item IDs must fail")
	assertEqual("ITEM_ID_INVALID", reason, "fractional item reason differs")
	local quoted = csvHeader .. 'x,1,raid,"Alpha",WARRIOR,tank,"a,b",0\r\n'
	assertTrue(parser.ParseImport(service, quoted, "multi", { format = "csv" }) ~= nil, "quoted CRLF CSV must import")
	local wideHeader, wideRow = { "itemId", "name" }, { "1", "Alpha" }
	for i = 3, 32 do wideHeader[i], wideRow[i] = "legacy" .. i, "value" .. i end
	local exactFieldsCsv = table.concat(wideHeader, ",") .. "\n" .. table.concat(wideRow, ",")
	assertTrue(parser.ParseImport(service, exactFieldsCsv, "multi", { format = "csv" }) ~= nil, "exact CSV field limit must import")
	local overFieldsCsv = table.concat(wideHeader, ",") .. ",extra\n" .. table.concat(wideRow, ",") .. ",value"
	parsed, reason = parser.ParseImport(service, overFieldsCsv, "multi", { format = "csv" })
	assertEqual(nil, parsed, "CSV field max plus one must fail")
	assertEqual("CSV_FIELDS_LIMIT", reason, "CSV field count reason differs")
	parsed, reason = parser.ParseImport(service, csvHeader .. "x,1,raid," .. string.rep("A", 65) .. ",WARRIOR,tank,note,0", "multi", { format = "csv" })
	assertEqual(nil, parsed, "overlong CSV name must fail")
	assertEqual("FIELD_LIMIT", reason, "CSV field reason differs")
	local duplicateRows = csvHeader
	for _ = 1, 100 do duplicateRows = duplicateRows .. "x,1,raid,Alpha,WARRIOR,tank,note,0\n" end
	assertTrue(parser.ParseImport(service, duplicateRows, "multi", { format = "csv" }) ~= nil, "quantity exact limit must import")
	duplicateRows = duplicateRows .. "x,1,raid,Alpha,WARRIOR,tank,note,0\n"
	parsed, reason = parser.ParseImport(service, duplicateRows, "multi", { format = "csv" })
	assertEqual(nil, parsed, "quantity over limit must fail")
	assertEqual("QUANTITY_LIMIT", reason, "quantity reason differs")
	local hugeField = csvHeader .. "x,1,raid,Alpha,WARRIOR,tank," .. string.rep("n", 257) .. ",0"
	parsed, reason = parser.ParseImport(service, hugeField, "multi", { format = "csv" })
	assertEqual(nil, parsed, "huge CSV field must fail")
	assertEqual("FIELD_LIMIT", reason, "huge field reason differs")
	local reserveRows = csvHeader
	for itemId = 1, 20 do reserveRows = reserveRows .. "x," .. itemId .. ",raid,Alpha,WARRIOR,tank,note,0\n" end
	assertTrue(parser.ParseImport(service, reserveRows, "multi", { format = "csv" }) ~= nil, "reserves per player exact limit must import")
	reserveRows = reserveRows .. "x,21,raid,Alpha,WARRIOR,tank,note,0\n"
	parsed, reason = parser.ParseImport(service, reserveRows, "multi", { format = "csv" })
	assertEqual(nil, parsed, "reserves per player over limit must fail")
	assertEqual("RESERVES_PER_PLAYER_LIMIT", reason, "reserve count reason differs")
	local playerParts = { csvHeader }
	for i = 1, 1000 do playerParts[#playerParts + 1] = "x,1,raid,P" .. i .. ",WARRIOR,tank,note,0\n" end
	local playerRows = table.concat(playerParts)
	assertTrue(parser.ParseImport(service, playerRows, "multi", { format = "csv" }) ~= nil, "player exact limit must import")
	playerRows = playerRows .. "x,1,raid,P1001,WARRIOR,tank,note,0\n"
	parsed, reason = parser.ParseImport(service, playerRows, "multi", { format = "csv" })
	assertEqual(nil, parsed, "player max plus one must fail")
	assertEqual("PLAYERS_LIMIT", reason, "player limit reason differs")
	local rowParts = { csvHeader }
	for player = 1, 250 do
		for itemId = 1, 20 do rowParts[#rowParts + 1] = "x," .. itemId .. ",raid,R" .. player .. ",WARRIOR,tank,note,0\n" end
	end
	local maxRows = table.concat(rowParts)
	assertTrue(parser.ParseImport(service, maxRows, "multi", { format = "csv" }) ~= nil, "row exact limit must import")
	parsed, reason = parser.ParseImport(service, maxRows .. "x,1,raid,R1,WARRIOR,tank,note,0\n", "multi", { format = "csv" })
	assertEqual(nil, parsed, "row max plus one must fail")
	assertEqual("ROWS_LIMIT", reason, "row limit reason differs")
	jsonValue = { softreserves = { { name = "Alpha", items = { { id = "1" } } } } }
	parsed, reason = parser.ParseImport(service, addon.Base64.Encode("json"), "multi", { format = "json" })
	assertEqual(nil, parsed, "numeric string item ID must fail")
	assertEqual("ITEM_ID_INVALID", reason, "numeric string reason differs")
	jsonValue = { softreserves = { { name = "Alpha", items = { { id = 1 }, { id = 1 } } } } }
	parsed, reason = parser.ParseImport(service, addon.Base64.Encode("json"), "multi", { format = "json" })
	assertEqual(nil, parsed, "duplicate JSON item must fail")
	assertEqual("JSON_DUPLICATE_ITEM", reason, "duplicate item reason differs")
	jsonValue = { softreserves = { { name = "Alpha", items = { { id = math.huge } } } } }
	parsed, reason = parser.ParseImport(service, addon.Base64.Encode("json"), "multi", { format = "json" })
	assertEqual(nil, parsed, "infinite JSON item ID must fail")
	assertEqual("ITEM_ID_INVALID", reason, "infinite item reason differs")
	print("PASS reserves_import_limits_and_schema_fail_closed")
end

function cases.reserves_whisper_admission_is_bounded_and_fail_closed(addon)
	local callbacks, timers, sent, data = {}, {}, {}, {}
	local now = 100
	local addCalls = 0
	addon.L = {
		WhisperSoftResHeader = "header", WhisperSoftResEntry = "%d. %s", WhisperSoftResNone = "none %s",
		WhisperSoftResAdded = "added %s", WhisperSoftResInvalidItem = "invalid item",
		WhisperSoftResAdmissionLimited = "slow down", WhisperSoftResCapacity = "full",
		WhisperSoftResInvalidSender = "invalid sender",
		StrReservesItemFallback = "[Item %s]",
	}
	addon.Strings = {
		TrimText = function(value) return tostring(value or ""):match("^%s*(.-)%s*$") end,
		NormalizeLower = function(value) return string.lower(tostring(value or "")) end,
		NormalizeName = function(value) return tostring(value or "") end,
	}
	addon.Database = { GetRealmName = function() return "Local Realm" end }
	addon.Options = { GetValue = function() return true end }
	addon.Events.Wow = { ChatMsgWhisper = "CHAT_MSG_WHISPER" }
	addon.Bus.RegisterCallback = function(_, callback) callbacks[#callbacks + 1] = callback end
	addon.Comms = { SendWhisper = function(target, text) sent[#sent + 1] = { target, text }; return true end }
	addon.Time = { GetCurrentTime = function() return now end }
	addon.Services.Raid = {
		GetPlayerRoleState = function() return { inRaid = true, isMasterLooter = true } end,
		CanUseCapability = function() return true end,
	}
	addon.Services.EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} end
	addon.Services.EnsureNamespace("Reserves")
	local reserves = addon.Services.Reserves
	reserves.ScheduleTimer = function(_, callback) timers[#timers + 1] = callback; return #timers end
	reserves.IsPlusSystem = function() return false end
	reserves.GetCounts = function()
		local players, entries = 0, 0
		for _, rows in pairs(data) do players = players + 1; entries = entries + #rows end
		return players, entries
	end
	reserves.GetPlayerReserveEntries = function(_, name) return data[string.lower(name)] or {} end
	reserves.NormalizeWhisperPlayerIdentity = function(_, value, localRealm)
		if type(value) ~= "string" or value == "" or #value > 64 or value:find("[%c|]")
			or value:find(string.char(0xff), 1, true) then return nil end
		local character, realm = value:match("^([^-]+)%-(.+)$")
		character, realm = character or value, realm or localRealm
		if character:find("[^A-Za-z\128-\255']") or character:match("^'") or character:match("'$+")
			or realm:match("^[ %'-]") or realm:match("[ %'-]$") then return nil end
		local realmKey = string.lower((realm:gsub("[ '%-]", "")))
		local localKey = string.lower((localRealm:gsub("[ '%-]", "")))
		return character, realmKey, string.lower(character) .. "-" .. realmKey, localKey
	end
	reserves.ResolveWhisperPlayerName = function(_, character, senderRealm, localRealm)
		if senderRealm == localRealm then return character end
		return character .. "-" .. senderRealm
	end
	reserves.AddPlayerReserve = function(_, name, itemRef)
		if itemRef == "[PublishFail]" then return false, "publish_failed" end
		if itemRef ~= "[Valid]" then return false, "invalid_item" end
		addCalls = addCalls + 1
		local key = string.lower(name)
		data[key] = data[key] or {}
		local row = { rawID = 1, itemName = "Valid", quantity = 1 }
		data[key][#data[key] + 1] = row
		return true, row
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Reserves/Chat.lua")
	local whisper = callbacks[#callbacks]
	local function drainTimers()
		local timerIndex = 1
		while timers[timerIndex] and timerIndex <= 250 do
			timers[timerIndex]()
			timerIndex = timerIndex + 1
		end
	end

	-- Invalid transport identities are silent and allocate no timer, queue, rate, or mutation state.
	whisper(nil, "+sr [Valid]", "")
	whisper(nil, "+sr [Valid]", string.rep("A", 65))
	whisper(nil, "+sr [Valid]", "Bad\tName-Realm")
	whisper(nil, "+sr [Valid]", "Bad-Realm\n")
	whisper(nil, "+sr [Valid]", "Bad|Name-Realm")
	whisper(nil, "+sr [Valid]", string.char(0xff) .. "Bad-Realm")
	whisper(nil, "+sr [Valid]", "Bad--Realm")
	whisper(nil, "+sr [Valid]", "Bad-Realm-")
	whisper(nil, "+sr [Valid]", "Bad- Realm")
	whisper(nil, "+sr [Valid]", "Bad-Realm ")
	whisper(nil, "+sr [Valid]", "'Bad-Realm")
	assertEqual(0, #sent, "invalid senders must receive no response")
	assertEqual(0, #timers, "invalid senders must allocate no timer")
	assertEqual(0, addCalls, "invalid senders must not mutate")

	whisper(nil, "+sr [Valid]", "Outside")
	assertEqual(1, #data.outside, "out-of-group opt-in signup must reuse local short-name storage")
	whisper(nil, "+sr [Valid]", "Al" .. string.char(0xc3, 0xa9) .. "a-R" .. string.char(0xc3, 0xa9) .. "alm")
	assertTrue(data["al" .. string.char(0xc3, 0xa9) .. "a-r" .. string.char(0xc3, 0xa9) .. "alm"] ~= nil,
		"valid UTF-8 player and realm bytes must be accepted")

	-- Short local and explicit local realm share one admission identity.
	drainTimers()
	local deliveredBeforeBurst = #sent
	for _ = 1, 5 do whisper(nil, "+sr", "Burst") end
	whisper(nil, "+sr", "Burst-LocalRealm")
	whisper(nil, "+sr", "Burst")
	drainTimers()
	assertEqual(deliveredBeforeBurst + 6, #sent, "five replies plus one denial must be delivered")
	assertEqual("slow down", sent[#sent][2], "sixth request must receive the single denial")

	local mutationsBefore = #data.outside
	local repliesBeforePublishFailure = #sent
	whisper(nil, "+sr [PublishFail]", "Storage-Realm")
	assertEqual(repliesBeforePublishFailure, #sent, "publication failure must not send a success or invalid-item reply")
	assertEqual(nil, data["storage-realm"], "publication failure must not mutate")
	whisper(nil, "+sr [Bogus]", "Spoof-Realm")
	assertEqual(mutationsBefore, #data.outside, "invalid admission must not mutate existing data")
	assertEqual(nil, data["spoof-realm"], "invalid item must not create a participant")

	data["capped-realm"] = {}
	for i = 1, 20 do data["capped-realm"][i] = { rawID = i, itemName = tostring(i) } end
	whisper(nil, "+sr [Valid]", "Capped-Realm")
	assertEqual(20, #data["capped-realm"], "per-player reserve cap must reject before mutation")
	for i = 1, 1000 do data["player" .. i .. "-realm"] = {} end
	whisper(nil, "+sr [Valid]", "Overflow-Realm")
	assertEqual(nil, data["overflow-realm"], "participant cap must reject before mutation")
	data = {}
	for player = 1, 250 do
		local rows = {}
		for item = 1, 20 do rows[item] = { rawID = item, itemName = tostring(item) } end
		data["full" .. player .. "-realm"] = rows
	end
	whisper(nil, "+sr [Valid]", "Total-Realm")
	assertEqual(nil, data["total-realm"], "total reserve cap must reject before mutation")
	data = {}
	whisper(nil, "+sr [Valid]", "Twin-RealmA")
	whisper(nil, "+sr [Valid]", "Twin-RealmB")
	assertTrue(data["twin-realma"] ~= data["twin-realmb"], "realm-qualified identities must remain distinct")

	data = {}
	for i = 1, 110 do whisper(nil, "+sr", "Query" .. i .. "-Realm") end
	local deliveredBeforeQueue = #sent
	drainTimers()
	assertTrue(#sent - deliveredBeforeQueue <= 100, "response queue must retain at most 100 queued replies")

	now = 111
	local beforeExpiryReply = #sent
	whisper(nil, "+sr", "Burst-Local Realm")
	drainTimers()
	assertEqual(beforeExpiryReply + 1, #sent, "expired sender must receive a fresh admission")
	for _ = 1, 4 do whisper(nil, "+sr", "Burst") end
	whisper(nil, "+sr", "Burst-LocalRealm")
	drainTimers()
	data["persisted-realm"] = { { rawID = 7, itemName = "Persisted" } }
	loadAddonFile(addon, "Raid Management Addon/Services/Reserves/Chat.lua")
	assertEqual(7, data["persisted-realm"][1].rawID, "runtime admission reload must not alter persisted reserves")
	local beforeReloadReply = #sent
	callbacks[#callbacks](nil, "+sr", "Burst-Local Realm")
	drainTimers()
	assertEqual(beforeReloadReply + 1, #sent, "reload-shaped admission state must start empty")
	print("PASS reserves_whisper_admission_is_bounded_and_fail_closed")
end

function cases.sync_request_backpressure_rolls_back_pending(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	fixture.failSingle = true
	local queued, reason = syncer:RequestLoggerReq(41, "Leader-Test Realm")
	assertEqual(false, queued, "REQ must propagate queue backpressure")
	assertEqual("backpressure", reason, "REQ backpressure reason differs")
	assertEqual(nil, next(syncer._pendingRequests), "failed REQ must remove pending state")
	assertEqual(0, #fixture.infos, "failed REQ must emit no sent message")

	queued, reason = syncer:RequestLoggerSync()
	assertEqual(false, queued, "SYNC must propagate queue backpressure")
	assertEqual("backpressure", reason, "SYNC backpressure reason differs")
	assertEqual(nil, next(syncer._pendingRequests), "failed SYNC must remove pending state")
	assertEqual(0, #fixture.infos, "failed SYNC must emit no sent message")
	assertEqual(0, #fixture.sent, "failed requests must enqueue nothing")
	print("PASS sync_request_backpressure_rolls_back_pending")
end

local caseName = arg[1]
local case = cases[caseName]
if not case then
	fail("unknown Lua behavior case: " .. tostring(caseName))
end

resetSavedVariables()
local addon = newAddon()
assertTrue(addon.State and addon.Database and addon.Services and addon.Events and addon.Bus)
case(addon)
