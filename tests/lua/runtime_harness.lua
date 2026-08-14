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
	addon.Bus.TriggerEvent = addon.Bus.TriggerEvent or function() end

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
	local captureHistory = fixture.store.CaptureRaidHistoryState
	local restoreHistory = fixture.store.RestoreRaidHistoryState
	fixture.store.CaptureRaidHistoryState = function(self)
		fixture.historyCaptures = (fixture.historyCaptures or 0) + 1
		return captureHistory(self)
	end
	fixture.store.RestoreRaidHistoryState = function(self, snapshot)
		fixture.historyRestores = (fixture.historyRestores or 0) + 1
		return restoreHistory(self, snapshot)
	end
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
	addon.Services.EnsureNamespace("Raid")
	local raid = addon.Services.Raid
	fixture.realmPlayers = { Existing = { name = "Existing", level = 80 } }
	raid.CaptureRosterSessionState = function()
		fixture.rosterCaptures = (fixture.rosterCaptures or 0) + 1
		return { numRaid = addon.State.raid.numRaid, realmPlayers = deepCopy(fixture.realmPlayers) }
	end
	raid.RestoreRosterSessionState = function(_, snapshot)
		fixture.rosterRestores = (fixture.rosterRestores or 0) + 1
		addon.State.raid.numRaid, fixture.realmPlayers = snapshot.numRaid, deepCopy(snapshot.realmPlayers)
		return true
	end
	raid.CommitRosterSession = function(_, _, pendingMeta, num)
		for i = 1, #pendingMeta do
			fixture.realmPlayers[pendingMeta[i][1]] = { name = pendingMeta[i][1] }
		end
		addon.State.raid.numRaid = num
		fixture.rosterCommits = (fixture.rosterCommits or 0) + 1
		return fixture.rosterCommits
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/State.lua")
	raid._ScheduleRosterRefreshInternal = function() end
	raid._CancelRosterRefreshInternal = function() end
	function raid:CloseAttendanceForRaid(record, currentTime, reason, deferPublication)
		record.attendance[1].segments[1].endTime = currentTime
		fixture.store:TouchRaidSyncRevision(record)
		if not deferPublication then addon.Bus.TriggerEvent("RaidAttendanceChanged", record.raidNid, reason) end
		return true, record.raidNid
	end
	return fixture, raid
end

local function installLootHardeningRollsFixture(addon)
	local lootState = {
		lootCount = 1,
		rollsCount = 0,
		selectedItemCount = 1,
		currentRollType = 4,
		currentRollItem = 1,
		fromInventory = false,
	}
	local scheduled = {}
	local now = 10

	_G.GetTime = function()
		return now
	end
	_G.table.wipe = _G.table.wipe or function(target)
		for key in pairs(target) do
			target[key] = nil
		end
		return target
	end

	addon.C = {
		rollTypes = { MAINSPEC = 1, OFFSPEC = 2, RESERVED = 3, FREE = 4, MANUAL = 5 },
	}
	addon.L = setmetatable({}, {
		__index = function(_, key)
			return key .. " %s %s %s %s %s %s"
		end,
	})
	addon.L.ChatCountdownTic = "%d"
	addon.L.ChatCountdownEnd = "end"
	addon.Diag = { D = setmetatable({}, { __index = function() return "%s %s %s %s %s %s" end }) }
	addon.Diag.W = setmetatable({}, { __index = function() return "%s %s %s %s %s %s" end })
	addon.Options = {
		RegisterNamespace = function() end,
		GetValue = function(_, key)
			if key == "countdownRollsBlock" then
				return false
			end
			return false
		end,
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Database = {
		EnsureLootRuntimeState = function()
			return {}, lootState
		end,
		GetItemIndex = function()
			return 1
		end,
		GetCurrentRaid = function()
			return 1
		end,
		GetPlayerName = function()
			return "Tester"
		end,
	}
	addon.Item = {
		GetItemIdFromLink = function()
			return 19019
		end,
		GetItemStringFromLink = function()
			return "item:19019"
		end,
	}
	addon.Strings = {
		NormalizeName = function(name)
			return name
		end,
		NormalizeLower = function(name)
			return name and string.lower(name) or nil
		end,
	}
	addon.Deformat = function(message)
		local player, roll = string.match(message or "", "^(%S+) (%d+)$")
		return player, tonumber(roll), 1, 100
	end
	addon.Comms = { SendWhisper = function() end }
	addon.Events = { Internal = { AddRoll = "AddRoll" } }
	addon.Bus = { TriggerEvent = function() end }
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
		Chat = { Announce = function() end },
		Loot = {
			GetItem = function()
				return { itemLink = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Test Item]|h|r" }
			end,
			GetCurrentItemCount = function()
				return 1
			end,
		},
		Raid = {
			LootBans = {
				IsActive = function() return false end,
				Get = function() return false end,
			},
			GetUnitID = function(_, name)
				return name and "raid1" or "none"
			end,
			GetPlayerClass = function()
				return "WARRIOR"
			end,
		},
	}
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleRepeatingTimer(callback)
				local handle = { callback = callback, repeating = true }
				scheduled[#scheduled + 1] = handle
				return handle
			end
			function target:ScheduleTimer(callback)
				local handle = { callback = callback }
				scheduled[#scheduled + 1] = handle
				return handle
			end
			function target:CancelTimer(handle)
				handle.cancelled = true
			end
		end,
	}
	addon.info = function() end
	addon.debug = function() end

	loadAddonFile(addon, "Raid Management Addon/Services/Rolls/Countdown.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Rolls/Sessions.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Rolls/History.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Rolls/Responses.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Rolls/Strategies.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Rolls/Resolution.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Rolls/Display.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Rolls/Service.lua")

	return addon.Services.Rolls, lootState, scheduled
end

local function installLootHardeningMasterFixture(addon, options)
	options = options or {}
	local fixture = {
		attempts = 0,
		assignments = 0,
		timers = 0,
		timerCallbacks = {},
		distributionCalls = 0,
		counterCalls = 0,
		refreshCalls = 0,
		cancelledTimerHandles = {},
		activeTimerHandles = {},
		warningCount = 0,
		candidateScans = 0,
		lootCountScans = 0,
	}
	local lootState = {
		lootCount = 1,
		opened = true,
		rollsCount = 1,
		selectedItemCount = 1,
		currentRollType = 4,
		fromInventory = false,
		holder = "Winner",
		banker = "Banker",
		disenchanter = "Disenchanter",
		winner = "Winner",
	}
	local noop = function() end
	local dummyController = setmetatable({}, { __index = function() return noop end })
	dummyController.HasInFlightAward = function()
		return fixture.tradeInFlight == true
	end
	fixture.tradeController = dummyController
	local frameApi = {
		GetRef = function() return nil end,
		SetScriptSafely = noop,
		BindModuleFrame = function() return "RMAMaster" end,
		MakeModuleFrameGetter = function() return function() return nil end end,
		SetFrameTitle = noop,
	}

	_G.table.wipe = _G.table.wipe or function(target) for key in pairs(target) do target[key] = nil end return target end
	_G.CreateFrame = function() return setmetatable({}, { __index = function() return noop end }) end
	_G.UnitName = function() return "Tester" end
	_G.GetMasterLootCandidate = function() return "Winner" end
	_G.GetRaidRosterInfo = function() return "Winner", 0, 1, 80, "Warrior", "WARRIOR" end
	_G.GetLootSlotInfo = function() return nil, "Test Item", 1, 4 end
	_G.GiveMasterLoot = function()
		fixture.assignments = fixture.assignments + 1
		if fixture.throwGiveMasterLoot then
			error("GiveMasterLoot exploded")
		end
		if fixture.rejectGiveMasterLoot then
			return false
		end
	end
	_G.UIDropDownMenu_AddButton = noop
	_G.UIDropDownMenu_CreateInfo = function() return {} end
	_G.UIDropDownMenu_Initialize = noop
	_G.UIDropDownMenu_JustifyText = noop
	_G.UIDropDownMenu_SetButtonWidth = noop
	_G.UIDropDownMenu_SetSelectedValue = noop
	_G.UIDropDownMenu_SetText = noop
	_G.UIDropDownMenu_SetWidth = noop
	_G.ClearCursor = noop
	_G.CursorHasItem = function() return false end
	_G.GetCursorInfo = noop
	_G.GetContainerItemInfo = noop
	_G.GetContainerItemLink = noop
	_G.InitiateTrade = noop
	_G.PickupContainerItem = noop
	_G.SetRaidTarget = noop
	_G.CheckInteractDistance = function() return true end

	addon.L = setmetatable({}, { __index = function(_, key) return key .. " %s %s %s %s %s %s" end })
	addon.L.WarnMLAwardConfirmationUncertain = "uncertain %s %s %s"
	addon.L.WarnMLAwardConfirmationUnresolved = "unresolved %s %s"
	addon.L.WarnMLLootAttributionFailed = "attribution %s"
	addon.L.ErrMLWinnerLootBanned = "banned %s"
	addon.L.ErrMLWinnerLootBannedWithNote = "banned %s %s"
	addon.L.WarnMLWinnerNoCandidate = "no candidate %s"
	addon.L.ChatAward = "%s won %s"
	addon.L.ChatAwardMutiple = "%s won %s"
	addon.Diag = {
		D = setmetatable({}, { __index = function() return "%s %s %s %s %s %s" end }),
		E = setmetatable({}, { __index = function() return "%s %s %s %s %s %s" end }),
		I = setmetatable({}, { __index = function() return "%s %s %s %s %s %s" end }),
		W = setmetatable({}, { __index = function() return "%s %s %s %s %s %s" end }),
	}
	addon.EntryPoints = { Debug = { RegisterCommand = noop } }
	addon.UI = {
		Frames = frameApi,
		Tooltips = { Bind = noop, Hide = noop },
		Lists = {
			CreateController = function() return dummyController end,
			CreateRowRenderer = function() return noop end,
			MakeIndexedRowName = function() return "Row" end,
		},
		Primitives = setmetatable({}, { __index = function() return noop end }),
		Rows = setmetatable({}, { __index = function() return noop end }),
		Popups = { Define = function() return true end, IsDefined = function() return true end, Show = noop, ShowConfirm = noop },
		ModuleState = { Ensure = function() return {} end },
		Scaffold = { DefineModule = noop },
		EditBoxes = { SetValue = noop },
	}
	addon.Item = { GetItemStringFromLink = function() return "item:19019" end }
	addon.UnitIterator = function() return function() return nil end end
	addon.Colors = {}
	addon.Comms = { SendWhisper = function()
		fixture.whisperCalls = (fixture.whisperCalls or 0) + 1
		return true
	end }
	addon.Events = {
		Internal = setmetatable({}, { __index = function(_, key) return key end }),
		ResolveWowForwardedName = function(name) return name end,
	}
	addon.C = setmetatable({
		rollTypes = { MAINSPEC = 1, OFFSPEC = 2, RESERVED = 3, FREE = 4, MANUAL = 5, HOLD = 6, BANK = 7, DISENCHANT = 8 },
		ML_AWARD_CONFIRM_TIMEOUT_SECONDS = 4,
		ML_MULTI_AWARD_TIMEOUT_SECONDS = 4,
		ML_MULTI_AWARD_DELAY = 0,
	}, { __index = function() return 30 end })
	addon.Database = {
		EnsureLootRuntimeState = function() return {}, lootState, {} end,
		RequireServiceMethod = function(_, owner, method)
			return function(target, ...)
				return owner[method](target, ...)
			end
		end,
		GetCurrentRaid = function() return 1 end,
		GetPlayerName = function() return "Tester" end,
		GetRaidStore = function() return { EnsureRaidByIndex = function() return {} end } end,
	}
	addon.Options = {
		IsDebugEnabled = function() return false end,
		RegisterNamespace = noop,
		GetValue = function(_, key) return key == "announceOnWin" and fixture.announceOnWin == true end,
	}
	addon.Bus = {
		TriggerEvent = function(eventName)
			if eventName == "RaidLootUpdate" then
				fixture.raidLootUpdateCount = (fixture.raidLootUpdateCount or 0) + 1
				if fixture.throwRaidLootUpdateAt == fixture.raidLootUpdateCount then
					error("injected authoritative reconciliation failure")
				end
			end
		end,
		RegisterCallback = noop,
	}
	addon.Controllers = { Logger = {}, Config = {} }
	addon.Widgets = {
		RaidGrid = { Hide = noop },
		LootHints = { ApplyLootFrameReserveHints = noop, ClearLootFrameReserveHints = noop },
		TradeMenu = setmetatable({}, { __index = function() return noop end }),
		ItemSelection = { CreateController = function() return dummyController end },
	}
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleTimer(callback)
				if fixture.throwNextSchedule then
					fixture.throwNextSchedule = false
					error("schedule exploded")
				end
				if fixture.nilNextSchedule then
					fixture.nilNextSchedule = false
					return nil
				end
				fixture.timers = fixture.timers + 1
				local handle
				handle = function(...)
					fixture.activeTimerHandles[handle] = nil
					return callback(...)
				end
				fixture.activeTimerHandles[handle] = true
				fixture.timerCallbacks[#fixture.timerCallbacks + 1] = handle
				return handle
			end
			function target:CancelTimer(handle)
				fixture.activeTimerHandles[handle] = nil
				fixture.cancelledTimerHandles[#fixture.cancelledTimerHandles + 1] = handle
			end
		end,
	}
	function fixture.activeTimerCount()
		local count = 0
		for _ in pairs(fixture.activeTimerHandles) do count = count + 1 end
		return count
	end
	function fixture.runScheduledTimers()
		local timerIndex = 1
		while timerIndex <= #fixture.timerCallbacks do
			local handle = fixture.timerCallbacks[timerIndex]
			timerIndex = timerIndex + 1
			if fixture.activeTimerHandles[handle] then
				handle()
			end
		end
	end
	addon.warn = function(_, message)
		fixture.warningCount = fixture.warningCount + 1
		fixture.lastWarning = message
		if type(fixture.onWarn) == "function" then fixture.onWarn() end
	end
	addon.info = noop
	addon.debug = noop
	addon.error = noop
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
		Chat = { Announce = function()
			fixture.announcementCalls = (fixture.announcementCalls or 0) + 1
			if fixture.throwAnnouncement then error("announcement exploded") end
			if fixture.rejectAnnouncement then return nil, "send_failed" end
			return true
		end },
		Logger = { Actions = {} },
		Loot = {
			DistributionSession = {
				PublishItemDone = function()
					fixture.distributionCalls = fixture.distributionCalls + 1
					return fixture.rejectDistribution ~= true
				end,
				PublishItemCancelled = function() fixture.cancelledPublications = (fixture.cancelledPublications or 0) + 1 return true end,
				PublishRollEnd = function()
					fixture.rollEndCalls = (fixture.rollEndCalls or 0) + 1
					return fixture.rejectRollEnd ~= true
				end,
			},
			Inventory = {
				FindLootSlotIndex = function() return 1 end,
				ValidateLootSlot = function()
					if fixture.slotValidationResult == nil and fixture.slotValidationReason then
						return nil, fixture.slotValidationReason
					end
					return true
				end,
				BuildMultiAwardSlotCandidates = function()
					fixture.candidateScans = fixture.candidateScans + 1
					return { 1 }, { [1] = true }
				end,
			},
			AwardPlanner = {
				BuildAwardTargetPlan = function() return { target = 1, available = 1 } end,
				BuildMultiAwardWinnersPlan = function(opts) return { winners = opts.pickedWinners } end,
				BuildMultiAwardState = function(opts)
					return { state = { active = true, itemLink = opts.itemLink, winners = opts.winners, total = #opts.winners, pos = 2, rollType = opts.rollType, itemKey = "item:19019", lastCount = opts.available, announceOnWin = opts.announceOnWin } }
				end,
			},
			LootAttribution = {
				ConfirmProvisional = function() return true end,
				IsMasterLootAwardFailureMessage = function(message)
					return message == "Inventory is full"
				end,
			},
			GetItemLink = function() return "item:19019" end,
			GetCurrentItemCount = function() return 1 end,
			FetchLoot = function() fixture.fetchCalls = (fixture.fetchCalls or 0) + 1 end,
			GetLootWindowItemCountByKey = function()
				fixture.lootCountScans = fixture.lootCountScans + 1
				return fixture.windowItemCount or 1
			end,
			AddPendingAward = function(_, _, _, _, _, _, _, options)
				fixture.pendingAttributions = fixture.pendingAttributions or {}
				fixture.pendingAttributions[tostring(options and options.transactionId)] = true
			end,
			CancelPendingAward = function(_, transactionId)
				local key = tostring(transactionId or "")
				if key == "" or not (fixture.pendingAttributions and fixture.pendingAttributions[key]) then
					return false
				end
				fixture.pendingAttributions[key] = nil
				fixture.cancelledTransactions = fixture.cancelledTransactions or {}
				fixture.cancelledTransactions[#fixture.cancelledTransactions + 1] = key
				return true
			end,
		},
		Raid = {
			LootBans = { Get = function()
				fixture.lootBanChecks = (fixture.lootBanChecks or 0) + 1
				return fixture.lootBanAtCheck == fixture.lootBanChecks, "changed ban"
			end },
			Debug = {},
			AddPlayerCountForRollType = function()
				fixture.counterCalls = fixture.counterCalls + 1
				return fixture.rejectCounter ~= true
			end,
			GetRosterVersion = function() return 1 end,
			RequestMasterLootCandidateRefresh = noop,
			FindMasterLootCandidateIndex = function()
				if fixture.candidateUnavailable then return nil end
				return 1
			end,
			CanResolveMasterLootCandidates = function() return true end,
			CanUseCapability = function() return true end,
			EnsureMasterOnlyAccess = function() return true end,
			IsMasterLooter = function() return fixture.permissionDenied ~= true end,
		},
		Rolls = {
			GetRollSession = function() return { id = "RS:1" } end,
			GetDisplayModel = function() return { resolution = {}, requiredWinnerCount = 1, winner = "Winner", rows = { { name = "Winner", roll = 90 } } } end,
			BeginTieReroll = function() return false end,
			IsCountdownRunning = function() return false end,
			StopCountdown = noop,
			ShouldUseTieReroll = function() return false end,
			FreezeRollIntake = function() return { resolution = {}, requiredWinnerCount = 1, winner = "Winner", rollWinner = "Winner" }, "award" end,
			GetHighestRoll = function() return 90 end,
			ValidateWinner = function()
				return fixture.winnerIneligible and { ok = false, warnMessage = "ineligible" } or { ok = true }
			end,
			EnsureLootRollSession = function() return { id = "RS:1" } end,
			ClearRolls = function() fixture.rollClearCalls = (fixture.rollClearCalls or 0) + 1 end,
			SetRollRecordingEnabled = noop,
			SetExpectedWinners = noop,
			FinalizeRollSession = noop,
		},
	}
	if options.realLootFlow then
		fixture.raid = { loot = {} }
		fixture.lootRevision = 0
		fixture.lootEventRevisions = {}
		lootState.pendingAwards = {}
		lootState.lootCount = 0
		lootState.currentItemIndex = 0
		addon.C.itemColors = { [5] = "ffff8000" }
		addon.C.RESERVES_ITEM_FALLBACK_ICON = "texture"
		_G.GetLootThreshold = function() return 2 end
		_G.GetNumLootItems = function() return 0 end
		_G.GetTime = function() return 10 end
		_G.GetItemInfo = function()
			return "Thunderfury", nil, 5, nil, nil, "Weapon", nil, nil, nil, "texture"
		end
		addon.Deformat = function() return nil end
		addon.Strings = { NormalizeName = function(value) return value end }
		addon.Time = { GetCurrentTime = function() return 10 end }
		addon.Item.GetItemIdFromLink = function() return 19019 end
		addon.Item.GetItemKey = function() return "item:19019" end
		addon.Options.NormalizeLoggerLootQualityThreshold = function(value) return tonumber(value) or 2 end
		addon.Database.EnsureLootRuntimeState = function() return {}, lootState, {}, {} end
		addon.Database.GetRaidQueries = function()
			return { ResolveLootLooterName = function() return "Winner" end }
		end
		fixture.lootStore = {
			EnsureRaidByIndex = function() return fixture.raid end,
			GetRaidSyncRevision = function() return fixture.lootRevision end,
			MarkLootSyncRevision = function()
				fixture.lootRevision = fixture.lootRevision + 1
				return fixture.lootRevision
			end,
			UpsertLootIndex = function() return true end,
		}
		addon.Database.GetRaidStore = function() return fixture.lootStore end
		addon.Bus.TriggerEvent = function(eventName)
			if eventName == "RaidLootUpdate" then
				fixture.raidLootUpdateCount = (fixture.raidLootUpdateCount or 0) + 1
				fixture.lootEventRevisions[#fixture.lootEventRevisions + 1] = fixture.lootRevision
				if fixture.throwRaidLootUpdateAt == fixture.raidLootUpdateCount then
					error("injected authoritative reconciliation failure")
				end
			end
		end
		addon.Services.Raid.EnsureRaidPlayerNid = function(_, name) return 1, name end
		addon.Services.Raid.FindOrCreateBossNidForLoot = function() return 1 end
		addon.Services.Raid.GetActiveLootSource = function() return nil end
		local noopLootOwner = setmetatable({}, { __index = function() return function() end end })
		addon.Services.Loot._PassiveGroupLoot = setmetatable({
			IsPassiveGroupLootMethod = function() return false end,
			IsPassiveLootWinnerMessage = function() return false end,
			ParseGroupLootWinner = function() return nil end,
			GetPassiveLootRollItemKey = function(link) return link end,
		}, getmetatable(noopLootOwner))
		addon.Services.Loot._Tracking = noopLootOwner
		addon.Services.Loot._Workflow = setmetatable({
			QueueAward = function() end,
			RecordReceipt = function() end,
			BeginLootWindow = function() end,
			SelectItem = function() end,
		}, getmetatable(noopLootOwner))
		addon.Services.Loot._Rules = {
			_IsIgnoredItem = function() return false end,
			GetItemSuggestion = function() return nil end,
		}
		addon.Services.Loot._Context = { ResolveRaidRecord = function() return 1, fixture.raid end }
		addon.Services.Loot.DistributionSession.BeginWindow = function() return 1 end
		addon.Services.Loot.DistributionSession.PublishWindowItems = function() return true end
		loadAddonFile(addon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
		loadAddonFile(addon, "Raid Management Addon/Services/Loot/Recording.lua")
		local addAttribution = addon.Services.Loot.LootAttribution.Add
		addon.Services.Loot.LootAttribution.Add = function(...)
			fixture.realAttributionAddCalls = (fixture.realAttributionAddCalls or 0) + 1
			return addAttribution(...)
		end
		local confirmProvisional = addon.Services.Loot.LootAttribution.ConfirmProvisional
		addon.Services.Loot.LootAttribution.ConfirmProvisional = function(...)
			fixture.realProvisionalConfirmCalls = (fixture.realProvisionalConfirmCalls or 0) + 1
			return confirmProvisional(...)
		end
		loadAddonFile(addon, "Raid Management Addon/Services/Loot/Service.lua")
		fixture.loot = addon.Services.Loot
		fixture.loot:AddItem("item:19019", 1, "Thunderfury", 5, "texture")
		fixture.loot:SelectItem(1)
		fixture.realLootSetupTimers = fixture.timers
		local addPendingAward = fixture.loot.AddPendingAward
		function fixture.loot:AddPendingAward(itemLink, looter, ...)
			fixture.realAddPendingCalls = (fixture.realAddPendingCalls or 0) + 1
			fixture.realAddPendingItem, fixture.realAddPendingWinner = itemLink, looter
			return addPendingAward(self, itemLink, looter, ...)
		end
	end
	addon.Services.Master = {}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardConfirmation.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardAttempt.lua")
	local createExecuting = addon.Services.Master.AwardAttempt.CreateExecuting
	addon.Services.Master.AwardAttempt.CreateExecuting = function(opts)
		fixture.attempts = fixture.attempts + 1
		local attempt = createExecuting(opts)
		fixture.lastAttempt = attempt
		return attempt
	end
	addon.Services.Master.RollSelection = {
		Mode = { AUTO = "AUTO" },
		CreateController = function()
			return {
				BuildModel = function() return addon.Services.Rolls:GetDisplayModel() end,
				GetSelectedCount = function() return 0 end,
				GetSelectedWinnersOrdered = function() return {} end,
				ResetSelection = noop,
				ClearAnchor = noop,
				CopyVisibleRows = function() return {} end,
				GetFocusedRowId = function() return nil end,
			}
		end,
	}
	addon.Services.Master.Assignment = { BuildCandidateRows = function() return {} end }
	addon.Services.Master.Messages = { BuildAssignMessages = function() return "award output", "award whisper" end }
	addon.Services.Master.Trade = {
		ApplyAccept = function() return nil end,
		CancelClose = function() return false end,
		HasClosePending = function() return false end,
		IsFailureMessage = function() return false end,
		Reset = noop,
		SettleClose = noop,
	}
	addon.Services.Master.TradeExecution = { CreateController = function() return dummyController end }
	loadAddonFile(addon, "Raid Management Addon/Services/Master/ButtonState.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardSequence.lua")
	local realCreate = addon.Services.Master.AwardSequence.CreateController
	addon.Services.Master.AwardSequence.CreateController = function(opts)
		fixture.awardSequence = realCreate(opts)
		return fixture.awardSequence
	end

	loadAddonFile(addon, "Raid Management Addon/Controllers/Master.lua")
	fixture.master = addon.Controllers.Master
	local resetItemCount = fixture.master._Private.ResetItemCount
	fixture.master._Private.ResetItemCount = function(...)
		fixture.itemResetCalls = (fixture.itemResetCalls or 0) + 1
		if fixture.mutateSelectedCountOnReset then
			fixture.lootState.selectedItemCount = fixture.resetSelectedItemCount or 1
		end
		if fixture.throwItemReset then
			fixture.throwItemReset = false
			error("item reset exploded")
		end
		return resetItemCount(...)
	end
	fixture.master.RequestRefresh = function()
		fixture.refreshCalls = fixture.refreshCalls + 1
		if fixture.throwRefresh then error("refresh exploded") end
		return true
	end
	fixture.lootState = lootState
	return fixture
end

local cases = {}

local function createDistributionSessionFixture(addon)
	local fixture = {
		now = 10,
		authority = "LeaderA",
		failKind = nil,
		failOccurrence = nil,
		kindAttempts = {},
		sent = {},
		events = {},
	}
	_G.GetTime = function() return fixture.now end
	addon.Database = { GetPlayerName = function() return "Tester" end }
	addon.Diag = {}
	addon.Events = { Internal = { LootDistributionSessionChanged = "LootDistributionSessionChanged" } }
	addon.Bus = {
		TriggerEvent = function(_, reason, row, sessionId)
			fixture.events[#fixture.events + 1] = {
				reason = reason,
				row = deepCopy(row),
				sessionId = sessionId,
			}
		end,
	}
	local function splitFields(text, sep, out)
		out = out or {}
		for key in pairs(out) do out[key] = nil end
		local start = 1
		while true do
			local index = string.find(text or "", sep, start, true)
			if not index then
				out[#out + 1] = string.sub(text or "", start)
				break
			end
			out[#out + 1] = string.sub(text, start, index - 1)
			start = index + string.len(sep)
		end
		return out, #out
	end
	addon.Comms = {
		Payload = {
			EncodeText = function(value) return tostring(value or "") end,
			DecodeText = function(value) return value end,
			PackFields = function(sep, ...)
				local values = { ... }
				for i = 1, #values do values[i] = tostring(values[i]) end
				return table.concat(values, sep)
			end,
			SplitFields = splitFields,
		},
		RegisterPrefixIfAvailable = function() return true end,
		Sync = function(prefix, message)
			local fields = splitFields(message, "|", {})
			local kind = fields[1]
			fixture.kindAttempts[kind] = (fixture.kindAttempts[kind] or 0) + 1
			if kind == fixture.failKind and fixture.kindAttempts[kind] == fixture.failOccurrence then
				return false
			end
			fixture.sent[#fixture.sent + 1] = { prefix = prefix, message = message, kind = kind, fields = deepCopy(fields) }
			return true
		end,
		QueueAddonMessage = function() return true end,
	}
	addon.Item = { GetItemKey = function(value) return value and tostring(value) or nil end }
	addon.Strings = { NormalizeText = function(value) return value and value ~= "" and tostring(value) or nil end }
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
		Raid = {
			IsGroupMember = function() return true end,
			IsLootAuthority = function(_, sender) return sender == fixture.authority end,
			CanUseCapability = function() return true end,
		},
		Loot = {},
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/DistributionSession.lua")
	fixture.owner = addon.Services.Loot.DistributionSession
	function fixture:Deliver(message, sender)
		return self.owner.HandleMessage("RMADist", message, "RAID", sender or self.authority)
	end
	function fixture:CountSent(kind)
		local count = 0
		for i = 1, #self.sent do if self.sent[i].kind == kind then count = count + 1 end end
		return count
	end
	return fixture
end

local function distributionItem(key, slot)
	return {
		itemKey = key,
		itemLink = key,
		itemName = key,
		itemTexture = "texture",
		count = 1,
		quality = 4,
		slot = slot,
	}
end

function cases.loot_distribution_window_sender_is_atomic(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	assertEqual(nil, owner.BeginWindow(-1), "negative expected rows must reject")
	assertEqual("invalid_expected_rows", select(2, owner.BeginWindow(1.5)), "fractional rows reason differs")
	assertEqual("invalid_expected_rows", select(2, owner.BeginWindow(129)), "oversized rows reason differs")

	fixture.failKind = "WINDOW_ITEM"
	fixture.failOccurrence = 2
	local revision, reason = owner.BeginWindow(3)
	assertTrue(revision ~= nil, reason or "window begin failed")
	assertEqual(false, owner.EndWindow(revision), "window end must reject before all rows enqueue")
	local ok
	ok, reason = owner.PublishWindowItems({
		distributionItem("item:1", 1),
		distributionItem("item:2", 2),
		distributionItem("item:3", 3),
	}, revision)
	assertEqual(nil, ok, "partial item enqueue must reject")
	assertEqual("window_item_send_failed", reason, "partial enqueue reason differs")
	assertEqual(0, fixture:CountSent("WINDOW_END"), "partial window must not commit")
	fixture.failKind = nil
	local retryRevision, retryReason = owner.BeginWindow(3)
	assertEqual(revision, retryRevision, retryReason or "retry consumed the failed revision")
	assertEqual(true, owner.PublishWindowItems({
		distributionItem("item:1", 1),
		distributionItem("item:2", 2),
		distributionItem("item:3", 3),
	}, retryRevision), "complete same-revision retry must commit")
	assertEqual(1, fixture:CountSent("WINDOW_END"), "same-revision retry must end once")

	revision, reason = owner.BeginWindow(0)
	assertEqual(retryRevision + 1, revision, "successful END must consume exactly one revision")
	assertTrue(revision ~= nil, reason or "zero-row begin failed")
	fixture.failKind = "WINDOW_END"
	fixture.failOccurrence = 2
	ok, reason = owner.PublishWindowItems({}, revision)
	assertEqual(nil, ok, "END enqueue failure must reject")
	assertEqual("window_end_send_failed", reason, "END failure reason differs")
	local endRetryRevision
	endRetryRevision, reason = owner.BeginWindow(0)
	assertEqual(revision, endRetryRevision, reason or "END failure consumed the revision")
	fixture.failKind = nil
	assertEqual(true, owner.PublishWindowItems({}, endRetryRevision), "zero-row END retry must commit")
	assertEqual(2, fixture:CountSent("WINDOW_END"), "complete zero-row window must end once")
	local begin = fixture.sent[#fixture.sent - 1]
	assertEqual("0", begin.fields[5], "WINDOW_BEGIN must append expected row count")
	local nextRevision = assert(owner.BeginWindow(0))
	assertEqual(endRetryRevision + 1, nextRevision, "successful END retry did not advance revision")
	assertEqual(true, owner.PublishWindowItems({}, nextRevision), "post-retry next revision must commit")
	print("PASS loot_distribution_window_sender_is_atomic")
end

function cases.loot_distribution_window_receiver_is_session_scoped(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:1:10|1|1")
	fixture:Deliver("WINDOW_ITEM|2|LeaderA:1:10|1|item:old|1|4|item:old|Old|texture|1")
	fixture:Deliver("WINDOW_END|2|LeaderA:1:10|1")
	local committed = owner.GetDisplayModel()
	assertEqual(1, committed.revision, "initial complete revision did not commit")
	assertEqual("item:old", committed.rows[1].itemKey, "initial row differs")

	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:1:10|2|2")
	fixture:Deliver("WINDOW_ITEM|2|LeaderA:1:10|2|item:new|1|4|item:new|New|texture|1")
	fixture:Deliver("WINDOW_END|2|LeaderA:1:10|2")
	assertTrue(deepEqual(committed, owner.GetDisplayModel()), "missing row replaced complete display")

	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:1:10|2|1")
	fixture:Deliver("WINDOW_ITEM|2|LeaderA:1:10|2|item:dup|1|4|item:dup|Dup|texture|1")
	fixture:Deliver("WINDOW_ITEM|2|LeaderA:1:10|2|item:dup|1|4|item:dup|Changed|texture|1")
	fixture:Deliver("WINDOW_END|2|LeaderA:1:10|2")
	assertTrue(deepEqual(committed, owner.GetDisplayModel()), "duplicate row replaced complete display")

	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:1:10|2|0")
	fixture:Deliver("WINDOW_END|2|LeaderA:1:10|2")
	local empty = owner.GetDisplayModel()
	assertEqual(2, empty.revision, "complete zero-row revision did not commit")
	assertEqual(0, #empty.rows, "zero-row window retained rows")

	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:1:10|3|129")
	fixture:Deliver("WINDOW_ITEM|2|LeaderA:1:10|3|item:oversized|1|4|item:oversized|Oversized|texture|1")
	fixture:Deliver("WINDOW_END|2|LeaderA:1:10|3")
	assertTrue(deepEqual(empty, owner.GetDisplayModel()), "oversized expected row count mutated display")

	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:1:10|2|1")
	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:1:10|4|1")
	fixture:Deliver("WINDOW_ITEM|2|LeaderA:1:10|4|item:gap|1|4|item:gap|Gap|texture|1")
	fixture:Deliver("WINDOW_END|2|LeaderA:1:10|4")
	assertTrue(deepEqual(empty, owner.GetDisplayModel()), "equal or gapped revision mutated display")
	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:2:20|1|0")
	fixture:Deliver("WINDOW_END|2|LeaderA:2:20|1")
	local nextSession = owner.GetDisplayModel()
	assertEqual("LeaderA:2:20", nextSession.sessionId, "same authority could not advance to a new session")
	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:1:10|3|0")
	fixture:Deliver("WINDOW_END|2|LeaderA:1:10|3")
	assertTrue(deepEqual(nextSession, owner.GetDisplayModel()), "superseded same-authority session resurrected")

	fixture.authority = "LeaderB"
	fixture:Deliver("WINDOW_BEGIN|2|LeaderB:1:30|1|1", "LeaderB")
	assertTrue(owner._streams["LeaderB|LeaderB:1:30"] and owner._streams["LeaderB|LeaderB:1:30"].window, "new authority begin was rejected")
	fixture:Deliver("WINDOW_ITEM|2|LeaderB:1:30|1|item:b|1|4|item:b|B|texture|1", "LeaderB")
	assertEqual(1, #owner._streams["LeaderB|LeaderB:1:30"].window.order, "new authority row was rejected")
	fixture:Deliver("WINDOW_END|2|LeaderB:1:30|1", "LeaderB")
	local authorityDisplay = owner.GetDisplayModel()
	assertEqual("LeaderB:1:30", authorityDisplay.sessionId, "new authority did not replace session")
	fixture:Deliver("WINDOW_BEGIN|2|LeaderA:3:30|4|0", "LeaderA")
	fixture:Deliver("WINDOW_END|2|LeaderA:3:30|4", "LeaderA")
	assertTrue(deepEqual(authorityDisplay, owner.GetDisplayModel()), "delayed old-authority window mutated display")
	print("PASS loot_distribution_window_receiver_is_session_scoped")
end

function cases.loot_distribution_snapshot_cannot_resurrect_ended_session(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	fixture:Deliver("WINDOW_BEGIN|2|ended|1|1")
	fixture:Deliver("WINDOW_ITEM|2|ended|1|item:old|1|4|item:old|Old|texture|1")
	fixture:Deliver("WINDOW_END|2|ended|1")
	fixture:Deliver("SESSION_END|2|ended|1")
	local ended = owner.GetDisplayModel()
	assertEqual(0, #ended.rows, "session end must clear owned display")
	local snapshot = "item:resurrect|1|4|item:resurrect|Resurrect|texture|1|active|||||||"
	fixture:Deliver("SNAP|2|request|ended|" .. snapshot)
	assertTrue(deepEqual(ended, owner.GetDisplayModel()), "snapshot resurrected ended session")
	fixture:Deliver("WINDOW_BEGIN|2|ended|2|0")
	fixture:Deliver("WINDOW_END|2|ended|2")
	assertTrue(deepEqual(ended, owner.GetDisplayModel()), "atomic traffic resurrected tombstoned session")
	fixture:Deliver("ROLL_END|2|ended|item:old|Winner|100|late")
	assertTrue(deepEqual(ended, owner.GetDisplayModel()), "legacy state traffic resurrected tombstoned session")
	print("PASS loot_distribution_snapshot_cannot_resurrect_ended_session")
end

function cases.loot_distribution_clear_requires_ordered_owner_transition(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	local function commit(sessionId, revision, itemKey)
		fixture:Deliver("WINDOW_BEGIN|2|" .. sessionId .. "|" .. revision .. "|1")
		fixture:Deliver("WINDOW_ITEM|2|" .. sessionId .. "|" .. revision .. "|" .. itemKey .. "|1|4|" .. itemKey .. "|Item|texture|1")
		fixture:Deliver("WINDOW_END|2|" .. sessionId .. "|" .. revision)
	end
	commit("LeaderA:3:30", 1, "item:c")
	local ownerC = owner.GetDisplayModel()
	fixture:Deliver("CLEAR|2|LeaderA:2:20")
	assertTrue(deepEqual(ownerC, owner.GetDisplayModel()), "delayed CLEAR replaced the newer owner")
	fixture:Deliver("SNAP|2|request|LeaderA:4:40|item:snap|1|4|item:snap|Snap|texture|1|active|||||||")
	assertTrue(deepEqual(ownerC, owner.GetDisplayModel()), "snapshot changed session without an explicit transition")
	fixture:Deliver("CLEAR|2|LeaderA:4:40")
	local cleared = owner.GetDisplayModel()
	assertEqual("LeaderA:4:40", cleared.sessionId, "newer ordered CLEAR did not transition session")
	fixture:Deliver("SNAP|2|request|LeaderA:4:40|item:snap|1|4|item:snap|Snap|texture|1|active|||||||")
	local snapshotOwner = owner.GetDisplayModel()
	assertEqual("item:snap", snapshotOwner.rows[1].itemKey, "snapshot after explicit CLEAR did not apply")
	fixture:Deliver("CLEAR|2|LeaderA:5:50")
	local afterSnapshotClear = owner.GetDisplayModel()
	fixture:Deliver("SNAP|2|late|LeaderA:4:40|item:late|1|4|item:late|Late|texture|1|active|||||||")
	assertTrue(deepEqual(afterSnapshotClear, owner.GetDisplayModel()), "superseded snapshot-only owner resurrected")
	print("PASS loot_distribution_clear_requires_ordered_owner_transition")
end

function cases.loot_distribution_generated_session_order_is_validated(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	fixture.authority = "Authority"
	local function commit(sessionId, revision, itemKey)
		fixture:Deliver("WINDOW_BEGIN|2|" .. sessionId .. "|" .. revision .. "|1")
		fixture:Deliver("WINDOW_ITEM|2|" .. sessionId .. "|" .. revision .. "|" .. itemKey .. "|1|4|" .. itemKey .. "|Item|texture|1")
		fixture:Deliver("WINDOW_END|2|" .. sessionId .. "|" .. revision)
	end
	commit("Authority:1:100", 1, "item:current")
	local current = owner.GetDisplayModel()
	assertEqual("Authority:1:100", current.sessionId, "initial generated session did not commit")

	local rejected = {
		"Other:2:100",
		"Authority:0:100",
		"Authority:1:nan",
		"Authority:2",
		"Authority:2:99",
		"Authority:9007199254740992:101",
	}
	for i = 1, #rejected do
		local sessionId = rejected[i]
		fixture:Deliver("WINDOW_BEGIN|2|" .. sessionId .. "|1|0")
		fixture:Deliver("WINDOW_END|2|" .. sessionId .. "|1")
		assertTrue(deepEqual(current, owner.GetDisplayModel()), "invalid generated window replaced current session: " .. sessionId)
		fixture:Deliver("CLEAR|2|" .. sessionId)
		assertTrue(deepEqual(current, owner.GetDisplayModel()), "invalid generated CLEAR replaced current session: " .. sessionId)
	end
	fixture.authority = "NextAuthority"
	fixture:Deliver("CLEAR|2|Other:1:101", "NextAuthority")
	assertTrue(deepEqual(current, owner.GetDisplayModel()), "new authority admitted a session ID owned by another sender")
	fixture.authority = "Authority"

	fixture:Deliver("CLEAR|2|Authority:2:101")
	local newer = owner.GetDisplayModel()
	assertEqual("Authority:2:101", newer.sessionId, "newer timestamp did not replace current session")
	fixture:Deliver("CLEAR|2|Authority:1:101")
	assertTrue(deepEqual(newer, owner.GetDisplayModel()), "lower ordinal replaced session at the same timestamp")
	fixture:Deliver("CLEAR|2|Authority:3:101")
	assertEqual("Authority:3:101", owner.GetDisplayModel().sessionId, "higher ordinal did not replace session at the same timestamp")
	print("PASS loot_distribution_generated_session_order_is_validated")
end

function cases.loot_distribution_authority_handoff_without_provenance_is_validated(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	assertTrue(owner.BeginWindow(0) ~= nil, "local owner did not create distribution state")
	assertEqual(true, owner.Clear(), "local owner clear failed")
	local localClear = owner.GetDisplayModel()
	assertEqual("Tester:2:10", localClear.sessionId, "local clear did not create the expected generated session")

	fixture.authority = "NewLeader"
	fixture:Deliver("CLEAR|2|NewLeader:1:20", "NewLeader")
	assertEqual("NewLeader:1:20", owner.GetDisplayModel().sessionId, "new authority CLEAR was rejected without owner provenance")
	fixture:Deliver("WINDOW_BEGIN|2|NewLeader:2:30|1|1", "NewLeader")
	fixture:Deliver("WINDOW_ITEM|2|NewLeader:2:30|1|item:new|1|4|item:new|New|texture|1", "NewLeader")
	fixture:Deliver("WINDOW_END|2|NewLeader:2:30|1", "NewLeader")
	local active = owner.GetDisplayModel()
	assertEqual("NewLeader:2:30", active.sessionId, "new authority window did not become active")
	assertEqual("item:new", active.rows[1].itemKey, "new authority window row differs")

	fixture:Deliver("CLEAR|2|NewLeader:1:29", "NewLeader")
	assertTrue(deepEqual(active, owner.GetDisplayModel()), "older same-authority candidate replaced active session")
	fixture:Deliver("CLEAR|2|NewLeader:invalid", "NewLeader")
	assertTrue(deepEqual(active, owner.GetDisplayModel()), "malformed same-authority candidate replaced active session")
	print("PASS loot_distribution_authority_handoff_without_provenance_is_validated")
end

function cases.loot_distribution_ownership_and_session_end_are_retry_safe(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	local revision = assert(owner.BeginWindow(0))
	assertEqual(true, owner.PublishWindowItems({}, revision), "local window must initialize session")
	local token = assert(owner.AcquireSessionOwnership("award"))
	assertEqual(true, owner.Clear(), "display clear must publish")
	assertEqual(true, owner.ReleaseSessionOwnership(token), "display clear erased ownership token")

	fixture.failKind = "SESSION_END"
	fixture.failOccurrence = 1
	local retryToken = assert(owner.AcquireSessionOwnership("retry"))
	assertEqual(false, owner.RequestSessionEnd(), "owned session end must defer")
	assertEqual(false, owner.ReleaseSessionOwnership(retryToken), "failed last-owner end send must propagate")
	assertEqual(true, owner._sessionOwners[retryToken], "failed last-owner end send consumed ownership")
	fixture.failKind = nil
	assertEqual(true, owner.ReleaseSessionOwnership(retryToken), "same-token end retry must succeed")
	assertEqual(nil, owner._sessionOwners[retryToken], "successful end retry retained ownership")
	assertEqual(2, fixture.kindAttempts.SESSION_END, "session end retry count differs")
	print("PASS loot_distribution_ownership_and_session_end_are_retry_safe")
end

function cases.loot_fetch_propagates_distribution_failure(addon)
	local lootState, itemInfo, raidState = {}, {}, {}
	local beginResult, beginReason = nil, "window_begin_send_failed"
	local publishResult, publishReason = nil, "window_item_send_failed"
	local publishCalls = 0
	_G.table.wipe = _G.table.wipe or function(target) for key in pairs(target) do target[key] = nil end return target end
	_G.GetLootThreshold = function() return 2 end
	_G.GetNumLootItems = function() return 0 end
	addon.C = { itemColors = {}, rollTypes = {}, RESERVES_ITEM_FALLBACK_ICON = "fallback" }
	addon.L = {}
	addon.Diag = { D = setmetatable({}, { __index = function() return "%s %s %s %s" end }) }
	addon.Events = { Internal = { RaidLootUpdate = "RaidLootUpdate", SetItem = "SetItem" } }
	addon.Bus = { TriggerEvent = function() end }
	addon.Deformat = function() end
	addon.Options = {
		GetValue = function() return false end,
		NormalizeLoggerLootQualityThreshold = function(value) return tonumber(value) or 2 end,
	}
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Time = { GetCurrentTime = function() return 10 end }
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleTimer() return {} end
			function target:CancelTimer() return true end
		end,
	}
	addon.Item = {
		GetItemStringFromLink = function(value) return value end,
		GetItemIdFromLink = function() return 1 end,
		GetItemKey = function(value) return value end,
	}
	addon.Database = {
		EnsureLootRuntimeState = function() return {}, lootState, itemInfo, raidState end,
		GetCurrentRaid = function() return 1 end,
		GetPlayerName = function() return "Tester" end,
		GetRaidQueries = function() return { ResolveLootLooterName = function() end } end,
	}
	local noopOwner = setmetatable({}, { __index = function() return function() end end })
	local distribution = {
		BeginWindow = function() return beginResult, beginReason end,
		PublishWindowItems = function()
			publishCalls = publishCalls + 1
			return publishResult, publishReason
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} return addon.Services[name] end,
		Loot = {
			LootAttribution = noopOwner,
			_PassiveGroupLoot = noopOwner,
			_Tracking = noopOwner,
			_Workflow = setmetatable({ BeginLootWindow = function() end }, getmetatable(noopOwner)),
			_Recording = noopOwner,
			_Rules = { _IsIgnoredItem = function() return false end },
			AwardPlanner = noopOwner,
			Inventory = noopOwner,
			DistributionSession = distribution,
			_Context = { ResolveRaidRecord = function() return nil end },
		},
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/Service.lua")
	local ok, reason = addon.Services.Loot:FetchLoot()
	assertEqual(nil, ok, "begin failure must reject FetchLoot")
	assertEqual("window_begin_send_failed", reason, "begin failure reason was hidden")
	assertEqual(0, publishCalls, "publish ran after begin failure")
	beginResult, beginReason = 1, nil
	ok, reason = addon.Services.Loot:FetchLoot()
	assertEqual(nil, ok, "item publication failure must reject FetchLoot")
	assertEqual("window_item_send_failed", reason, "item publication reason was hidden")
	assertEqual(1, publishCalls, "publication attempt count differs")
	publishResult, publishReason = true, nil
	assertEqual(true, addon.Services.Loot:FetchLoot(), "successful publication must confirm FetchLoot")
	print("PASS loot_fetch_propagates_distribution_failure")
end

function cases.loot_distribution_done_retries_wire_without_duplicate_state(addon)
	local events, sends = {}, 0
	_G.GetTime = function() return 10 end
	addon.Database = { GetPlayerName = function() return "Tester" end }
	addon.Diag = {}
	addon.Events = { Internal = { LootDistributionSessionChanged = "LootDistributionSessionChanged" } }
	addon.Bus = { TriggerEvent = function(_, reason, row) events[#events + 1] = { reason = reason, row = row } end }
	addon.Comms = {
		Payload = {
			EncodeText = function(value) return tostring(value or "") end,
			DecodeText = function(value) return value end,
			PackFields = function(sep, ...) local values = { ... } for i = 1, #values do values[i] = tostring(values[i]) end return table.concat(values, sep) end,
			SplitFields = function() return {} end,
		},
		RegisterPrefixIfAvailable = function() return true end,
		Sync = function() sends = sends + 1 return sends > 1 end,
		QueueAddonMessage = function() return true end,
	}
	addon.Item = { GetItemKey = function(value) return value end }
	addon.Strings = { NormalizeText = function(value) return value and tostring(value) or nil end }
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} return addon.Services[name] end,
		Raid = {
			IsGroupMember = function() return true end,
			IsLootAuthority = function() return true end,
			CanUseCapability = function() return true end,
		},
		Loot = {},
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/DistributionSession.lua")
	local owner = addon.Services.Loot.DistributionSession
	assertEqual(false, owner.PublishItemDone("item:19019", "Winner"), "first wire send must fail")
	assertEqual(true, owner.PublishItemDone("item:19019", "Winner"), "identical done retry must resend")
	assertEqual(1, #events, "identical done retry duplicated local state notification")
	assertEqual(2, sends, "wire retry count differs")
	assertEqual("item_done", events[1].reason, "local done reason differs")
	assertEqual("Winner", owner._state.itemsByKey["item:19019"].winnerName, "done winner changed")
	assertEqual(true, owner.PublishItemDone("item:19019", "Other"), "different winner must update normally")
	assertEqual(2, #events, "different winner did not publish a local state change")
	assertEqual("Other", owner._state.itemsByKey["item:19019"].winnerName, "different winner was ignored")
	print("PASS loot_distribution_done_retries_wire_without_duplicate_state")
end

function cases.loot_award_attempt_checkpoints_are_retry_safe(addon)
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardAttempt.lua")
	local AwardAttempt = addon.Services.Master.AwardAttempt
	local publishCalls, confirmCalls, reentrantConfirm, reentrantFail = 0, 0
	local attempt
	attempt = AwardAttempt.CreateExecuting({
		transactionId = "AT:test",
		executorContext = { rollType = 1, callback = function() end },
		onConfirm = function()
			confirmCalls = confirmCalls + 1
			if confirmCalls == 1 then
				assertEqual(true, attempt:RunCheckpoint("publish", function()
					publishCalls = publishCalls + 1
					return true
				end), "successful checkpoint must commit")
				reentrantConfirm = attempt:Confirm()
				reentrantFail = attempt:Fail("reentrant")
				return nil, "confirmation_rejected"
			end
			assertEqual(true, attempt:RunCheckpoint("publish", function()
				publishCalls = publishCalls + 1
				return true
			end), "retry must accept completed checkpoint")
			return true
		end,
	})

	local throwOk, throwReason = attempt:RunCheckpoint("throw", function() error("checkpoint exploded") end)
	assertEqual(nil, throwOk, "throwing checkpoint must reject")
	assertTrue(tostring(throwReason):find("checkpoint exploded", 1, true) ~= nil, "throw reason must be stable")
	local rejectCalls = 0
	local rejectOk, rejectReason = attempt:RunCheckpoint("reject", function()
		rejectCalls = rejectCalls + 1
		return nil, "checkpoint_rejected_by_owner"
	end)
	assertEqual(nil, rejectOk, "rejected checkpoint must reject")
	assertEqual("checkpoint_rejected_by_owner", rejectReason, "checkpoint rejection reason differs")
	assertEqual(nil, attempt:Confirm(), "first confirm must become uncertain")
	assertEqual("uncertain", attempt:GetState().state, "rejected confirm must be uncertain")
	assertEqual(nil, reentrantConfirm, "reentrant confirm must reject")
	assertEqual(nil, reentrantFail, "reentrant fail must reject")
	assertEqual(true, attempt:Confirm(), "uncertain attempt must retry")
	assertEqual(1, publishCalls, "successful checkpoint repeated")
	assertEqual(2, confirmCalls, "confirm retry count differs")
	local state = attempt:GetState()
	assertEqual("confirmed", state.state, "successful retry must confirm")
	assertEqual(true, state.checkpoints.publish, "state must expose completed checkpoint names")
	assertEqual(nil, state.onConfirm, "state must contain data only")
	assertEqual(nil, state.executorContext.callback, "nested callback must not escape through state")
	assertEqual(false, attempt:Confirm(), "terminal confirm must reject")
	assertEqual(false, attempt:Fail("late"), "terminal fail must reject")

	local failCalls, failReentry = 0, nil
	local failed
	failed = AwardAttempt.CreateExecuting({
		onFail = function()
			failCalls = failCalls + 1
			failReentry = failed:Fail("again")
			error("failure callback exploded")
		end,
	})
	local failedOk, failedReason = failed:Fail("execution_failed")
	assertEqual(nil, failedOk, "throwing failure callback must be contained")
	assertTrue(tostring(failedReason):find("failure callback exploded", 1, true) ~= nil, "failure callback reason missing")
	assertEqual("failed", failed:GetState().state, "failure must commit terminal state before callback")
	assertEqual(nil, failReentry, "failure callback must not reenter")
	assertEqual(false, failed:Fail("duplicate"), "failure must be terminal once")
	assertEqual(1, failCalls, "failure callback repeated")
	print("PASS loot_award_attempt_checkpoints_are_retry_safe")
end

function cases.loot_award_attempt_snapshots_supported_fields_only(addon)
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardAttempt.lua")
	local source = { kind = "loot", slot = 3 }
	local context = { bagId = 0, slotId = 4 }
	local callbackCount = 0
	local attempt = addon.Services.Master.AwardAttempt.CreateExecuting({
		transactionId = "tx-simple-copy",
		winnerName = "Alpha",
		source = source,
		executorContext = context,
		onConfirm = function(snapshot)
			callbackCount = callbackCount + 1
			assertEqual(3, snapshot.source.slot, "later callback source snapshot must be unchanged")
			assertEqual(4, snapshot.executorContext.slotId, "later callback context snapshot must be unchanged")
			assertEqual(true, snapshot.checkpoints.publish, "later callback checkpoint snapshot must be unchanged")
			if callbackCount == 1 then
				snapshot.source.slot = 21
				snapshot.executorContext.slotId = 22
				snapshot.checkpoints.publish = false
				return nil, "retry_snapshot"
			end
			return true
		end,
	})
	source.slot = 9
	context.slotId = 8
	assertEqual(true, attempt:RunCheckpoint("publish", function() return true end), "checkpoint must complete")
	local exposed = attempt:GetState()
	exposed.source.slot = 12
	exposed.executorContext.slotId = 13
	exposed.checkpoints.publish = false
	local fresh = attempt:GetState()
	assertEqual(3, fresh.source.slot, "returned source must not alias attempt state")
	assertEqual(4, fresh.executorContext.slotId, "returned context must not alias attempt state")
	assertEqual(true, fresh.checkpoints.publish, "returned checkpoints must not alias attempt state")
	assertEqual(nil, attempt:Confirm(), "first callback must request a retry")
	fresh = attempt:GetState()
	assertEqual(3, fresh.source.slot, "callback source must not alias attempt state")
	assertEqual(4, fresh.executorContext.slotId, "callback context must not alias attempt state")
	assertEqual(true, fresh.checkpoints.publish, "callback checkpoints must not alias attempt state")
	assertEqual(true, attempt:Confirm(), "later callback must receive an unchanged snapshot")
	assertEqual(2, callbackCount, "confirm retry must capture two callback snapshots")
	print("PASS loot_award_attempt_snapshots_supported_fields_only")
end

function cases.loot_award_confirmation_retains_uncertain_effect(addon)
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardAttempt.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardConfirmation.lua")
	local scheduled, cancelled, refreshes, warnings, provisionalCalls = {}, 0, 0, 0, 0
	local confirmCalls = 0
	local effect = addon.Services.Master.AwardAttempt.CreateExecuting({
		onConfirm = function()
			confirmCalls = confirmCalls + 1
			if confirmCalls == 1 then return nil, "effect_rejected" end
			return true
		end,
	})
	local confirmation = addon.Services.Master.AwardConfirmation.Create({
		timeoutSeconds = 4,
		scheduleTimer = function(callback)
			scheduled[#scheduled + 1] = callback
			return callback
		end,
		cancelTimer = function() cancelled = cancelled + 1 end,
		requestRefresh = function() refreshes = refreshes + 1 end,
		warnFailure = function() warnings = warnings + 1 end,
		warnUncertain = function() warnings = warnings + 1 end,
		warnTimeout = function() warnings = warnings + 1 end,
		warnUnresolved = function() warnings = warnings + 1 end,
		onUnresolved = function() end,
		confirmProvisional = function()
			provisionalCalls = provisionalCalls + 1
			return true
		end,
	})
	assertTrue(confirmation:Queue({ itemLink = "item:19019", itemIndex = 1, playerName = "Winner", effect = effect }), "confirmation must queue")
	assertEqual(1, #scheduled, "queue must schedule one timer")
	assertEqual(nil, confirmation:Confirm(1), "rejected effect must remain unresolved")
	assertEqual(true, confirmation:HasInFlight(), "rejected effect must retain ownership")
	assertEqual("uncertain", effect:GetState().state, "rejected effect must be uncertain")
	assertEqual(1, provisionalCalls, "provisional attribution must run once")
	assertEqual(1, warnings, "rejection must warn once")
	assertEqual(1, refreshes, "rejection must request one refresh")
	assertEqual(1, #scheduled, "retry must not schedule a second timer")
	assertEqual(true, confirmation:Confirm(1), "later slot clear must retry successfully")
	assertEqual(false, confirmation:HasInFlight(), "successful retry must release ownership")
	assertEqual(1, provisionalCalls, "successful provisional checkpoint must not repeat")
	assertEqual(1, cancelled, "successful retry must cancel the original timer")
	assertEqual(false, confirmation:Confirm(1), "duplicate slot clear must be ignored")
	assertEqual(2, confirmCalls, "duplicate slot clear repeated effect confirmation")
	assertEqual(1, warnings, "successful retry must not duplicate warning")
	assertEqual(1, refreshes, "successful retry must not duplicate recovery refresh")

	local timeoutEffect = addon.Services.Master.AwardAttempt.CreateExecuting({ onConfirm = function() return true end })
	assertTrue(confirmation:Queue({ itemLink = "item:2", itemIndex = 2, playerName = "Runner", effect = timeoutEffect }), "timeout confirmation must queue")
	assertEqual(2, #scheduled, "second entry must own one timer")
	scheduled[2]()
	assertEqual("uncertain", timeoutEffect:GetState().state, "timeout must become uncertain")
	assertEqual(true, confirmation:HasInFlight(), "timeout must retain reconciliation ownership")
	assertEqual(2, warnings, "timeout must warn once")
	assertEqual(2, refreshes, "timeout must refresh once")
	assertEqual(true, confirmation:Confirm(2), "timed-out effect must remain reconcilable")
	assertEqual(false, confirmation:HasInFlight(), "reconciled timeout must release ownership")
	assertEqual(2, cancelled, "reconciled timeout must cancel only the outstanding expiry handle")
	print("PASS loot_award_confirmation_retains_uncertain_effect")
end

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
	"BAG_UPDATE",
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
		assertEqual(1, fixture.historyCaptures, "Create must capture history once")
		assertEqual(1, fixture.rosterCaptures, "Create must capture roster once")
		assertEqual(1, fixture.historyRestores, "failed Create must restore history once")
		assertEqual(1, fixture.rosterRestores, "failed Create must restore roster once")
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
	assertEqual(1, fixture.historyCaptures, "replacement captures history once")
	assertEqual(nil, fixture.historyRestores, "successful replacement does not restore")
	assertEqual(1, fixture.rosterCommits, "replacement commits roster once")
	print("PASS raid_session_replacement_preserves_event_order")
end


function cases.raid_state_resolves_roster_timers_after_toc_order_load(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	local fixtureSchedule = raid._ScheduleRosterRefreshInternal
	local savedPlayers = { ["Test Realm"] = fixture.realmPlayers }
	addon.Events.Internal.RaidRosterDelta = "RaidRosterDelta"
	addon.Database.SavedVariables.GetPlayers = function() return savedPlayers end
	addon.Timer = { BindMixin = function(target) fixture:InstallTimers(target) end }
	addon.IsInGroup = function() return true end
	addon.Database.GetPlayerName = function() return "Alpha" end
	_G.UnitSex = function() return 2 end

	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Roster.lua")
	assertTrue(raid._ScheduleRosterRefreshInternal ~= fixtureSchedule, "Roster must install the real scheduler after State")
	raid.CheckPlayer = function() return true end
	raid:CheckInitialRaidState()
	local scheduled = raid.updateRosterHandle
	assertTrue(scheduled and scheduled.active, "State must resolve the roster scheduler after both files load")
	raid:End()
	assertEqual(false, scheduled.active, "State must resolve roster cancellation after both files load")
	assertEqual(nil, raid.updateRosterHandle, "roster cancellation must clear the scheduled handle")
	print("PASS raid_state_resolves_roster_timers_after_toc_order_load")
end

function cases.raid_create_rejects_malformed_roster_metadata(addon)
	local scenarios = {
		{ name = "realm root", realmPlayers = "corrupt" },
		{ name = "realm child", realmPlayers = { Existing = "corrupt" } },
	}
	for i = 1, #scenarios do
		local scenario = scenarios[i]
		local fixture, raid = installRaidCreationFixture(addon, nil)
		local savedPlayers = { ["Test Realm"] = scenario.realmPlayers }
		local beforePlayers = deepCopy(savedPlayers)
		local beforeRaid = deepCopy(fixture.raids[1])
		addon.Events.Internal.RaidRosterDelta = "RaidRosterDelta"
		addon.Database.SavedVariables.GetPlayers = function() return savedPlayers end
		addon.Timer = { BindMixin = function(target) fixture:InstallTimers(target) end }
		addon.IsInGroup = function() return true end
		addon.Database.GetPlayerName = function() return "Alpha" end
		_G.UnitSex = function() return 2 end
		loadAddonFile(addon, "Raid Management Addon/Services/Raid/Roster.lua")

		local ok, result = pcall(raid.Create, raid, "Ulduar", 25, 2)
		assertEqual(true, ok, scenario.name .. " must not escape a Lua error")
		assertEqual(false, result, scenario.name .. " must reject raid creation")
		assertEqual(1, addon.Database.GetCurrentRaid(), scenario.name .. " changed the active raid")
		assertTrue(deepEqual(beforeRaid, fixture.raids[1]), scenario.name .. " mutated the existing raid")
		assertTrue(deepEqual(beforePlayers, savedPlayers), scenario.name .. " mutated SavedVariables")
		assertEqual(2, #fixture.raids, scenario.name .. " persisted a candidate raid")
		assertEqual(0, #fixture.events, scenario.name .. " published an event")
	end
	print("PASS raid_create_rejects_malformed_roster_metadata")
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
			assertEqual(1, fixture.historyCaptures, "Create must capture history once")
			assertEqual(1, fixture.rosterCaptures, "Create must capture roster once")
			assertEqual(1, fixture.historyRestores, "failed Create must restore history once")
			assertEqual(1, fixture.rosterRestores, "failed Create must restore roster once")
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
	addon.IgnoredMobs = { IsTrashMobName = function() return false end }
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidValidator.lua")
	addon.Database.GetRaidValidator = function() return addon.DB.RaidValidator end
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
	local originalCommit = fixture.store.CommitRaidHistoryCleanup
	fixture.store.CommitRaidHistoryCleanup = function(store, plan, currentRaidNid)
		fixture.currentRaid = 1
		return originalCommit(store, plan, fixture.raids[fixture.currentRaid].raidNid)
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
	nowValue = 13.5
	for i = 1, #timers do if not timers[i].cancelled and timers[i].deadline <= nowValue then timers[i].callback() end end
	assertEqual("timeout", finishes[#finishes], "deadline completes once with timeout")
	assertEqual(4, clears, "timeout clears only current owner")

	local combatStarts, combatFinishes = 0, 0
	combat = true
	coordinator:Request("combat-deferral", "raid3", "guid-combat", function()
		combatStarts = combatStarts + 1
	end, function(reason)
		assertEqual("timeout", reason, "active combat-deferred request must retain the timeout reason")
		combatFinishes = combatFinishes + 1
	end)
	nowValue = 21
	for i = 1, #timers do
		if not timers[i].cancelled and timers[i].deadline <= nowValue then
			timers[i].cancelled = true
			timers[i].callback()
		end
	end
	assertEqual(0, combatStarts, "combat-deferred work must not start in combat")
	assertEqual(0, combatFinishes, "queued time must not consume the active timeout")
	combat = false
	callbacks.PLAYER_REGEN_ENABLED()
	assertEqual(1, combatStarts, "regen must start deferred work once")
	nowValue = 29.1
	for i = 1, #timers do
		if not timers[i].cancelled and timers[i].deadline <= nowValue then
			timers[i].cancelled = true
			timers[i].callback()
		end
	end
	assertEqual(1, combatFinishes, "timeout must begin at activation and finish once")
	combat = true
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

function cases.equip_inspect_initial_timer_failure_preserves_reentrant_replacement(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local coordinator = addon.Services.InspectCoordinator
	local scheduleTimer = coordinator.ScheduleTimer
	local injected = false
	coordinator.ScheduleTimer = function(self, callback, delay)
		if delay == 8 and not injected then
			injected = true
			return nil
		end
		return scheduleTimer(self, callback, delay)
	end

	local terminalUpdates = 0
	local replacementAccepted, replacementStatus
	fixture.onEvent = function(eventName, raidNid, playerNid, snapshot)
		if eventName == "EquipInspectUpdated"
			and raidNid == 73
			and playerNid == 21
			and snapshot
			and snapshot.status == "failed"
			and snapshot.reason == "inspect_timer_failed"
		then
			terminalUpdates = terminalUpdates + 1
			if terminalUpdates == 1 then
				replacementAccepted, replacementStatus = inspect:ForcePlayer(2, 21)
			end
		end
	end

	local accepted, reason = inspect:ForcePlayer(2, 21)
	assertEqual(false, accepted, "initial timer failure must reject the original request")
	assertEqual("inspect_timer_failed", reason, "initial timer failure reason must remain stable")
	assertEqual(1, terminalUpdates, "initial timer failure must emit one terminal update")
	assertEqual(true, replacementAccepted, "terminal subscriber must enqueue replacement work")
	assertEqual("queued", replacementStatus, "replacement must retain coordinator admission")
	assertEqual("pending", inspect:GetSnapshot(fixture.raids[2], 21).status, "stale rejection must preserve replacement status")
	assertEqual(0, #fixture.inspectRequests, "replacement must respect the global minimum interval")
	fixture:AdvanceTime(1.75)
	assertEqual(1, #fixture.inspectRequests, "replacement must reach NotifyInspect once")

	fixture.onEvent = nil
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual("ready", inspect:GetSnapshot(fixture.raids[2], 21).status, "replacement must complete normally")
	coordinator.ScheduleTimer = scheduleTimer
	print("PASS equip_inspect_initial_timer_failure_preserves_reentrant_replacement")
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
		local coordinator = addon.Services.InspectCoordinator
		local scheduleTimer = coordinator.ScheduleTimer
		local injected = false
		coordinator.ScheduleTimer = function(self, callback, delay)
			if delay == 1.75 and not injected then
				injected = true
				if failureMode == "throw" then error("injected InspectCoordinator handoff timer failure") end
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
		coordinator.ScheduleTimer = scheduleTimer
		fixture:AdvanceTime(2)
		assertEqual(2, #fixture.inspectRequests, failureMode .. " reentrant work receives coordinator ownership")
		fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
		fixture:AdvanceTime(20)
		assertEqual(1, countTerminalUpdates(fixture, 41, 11), failureMode .. " handoff leaves no stale callback")
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
	fixture:AdvanceTime(1.75)
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
	fixture:AdvanceTime(1.75)
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
	fixture:AdvanceTime(1.75)
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
	fixture:AdvanceTime(1.75)
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

function cases.equip_inspect_combat_deferral_is_coordinator_owned(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	fixture.inCombat = true
	assertEqual("queued", select(2, inspect:ForcePlayer(2, 21)), "combat request must enter the coordinator queue")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual(nil, fixture.raids[2].inspect, "queued work must not consume an inspect callback before NotifyInspect")
	fixture:AdvanceTime(20)
	assertEqual(0, #fixture.inspectRequests, "queued combat work must not notify before regen")
	local activeTimers = 0
	for i = 1, #fixture.timers do
		if fixture.timers[i].active then activeTimers = activeTimers + 1 end
	end
	assertEqual(0, activeTimers, "EquipInspect must not own a combat retry timer")

	fixture.inCombat = false
	fixture.inspectCallbacks.PLAYER_REGEN_ENABLED()
	assertEqual(1, #fixture.inspectRequests, "regen must let the coordinator notify once")
	fixture:AdvanceTime(8.1)
	local snapshot = inspect:GetSnapshot(fixture.raids[2], 21)
	assertEqual("timeout", snapshot.status, "active request must time out after coordinator activation")
	assertEqual("inspect_timeout", snapshot.reason, "active timeout reason must remain stable")
	print("PASS equip_inspect_combat_deferral_is_coordinator_owned")
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
	local function reject(mutator)
		local staged = fixture.store:StageRaidHistoryMutation(raid)
		mutator(staged)
		local report = addon.Database.GetRaidValidator():GetRaidRecordValidation(staged, 0, 6)
		local expected
		for i = 1, #report.details do
			if report.details[i].level == "E" then
				expected = report.details[i].code
				break
			end
		end
		assertTrue(type(expected) == "string", "fixture must produce a validator error")
		local before = deepCopy(raid)
		local ok, reason = fixture.store:CommitRaidHistoryMutation(raid, staged, { reason = "test" })
		assertEqual(false, ok, "invalid staged history must reject")
		assertEqual(expected, reason, "store and validator error differ")
		assertTrue(deepEqual(before, raid), "rejected history must not mutate canonical data")
	end
	reject(function(staged) staged.players[2] = { playerNid = 21, name = "Duplicate" } end)
	reject(function(staged) staged.loot[2] = { lootNid = 7, itemId = 1 } end)
	reject(function(staged) staged.loot[3] = { lootNid = 9, itemId = 1 } end)
	reject(function(staged) staged.players.hidden = { playerNid = 22, name = "Hidden" } end)
	reject(function(staged) staged.bossKills[1] = { bossNid = 4, players = { [2] = 21 } } end)
	local staged = fixture.store:StageRaidHistoryMutation(raid)
	local ok, reason = fixture.store:CommitRaidHistoryMutation(raid, staged, { lootNid = "7", reason = "test" })
	assertEqual(false, ok, "numeric string loot scope must reject")
	assertEqual("INVALID_LOOT_SCOPE", reason, "loot scope reason differs")
	print("PASS logger_history_validation_is_strict_and_complete")
end

function cases.raid_store_uses_validator_first_error(addon)
	local fixture, _, raid = installLoggerAtomicFixture(addon)
	local staged = fixture.store:StageRaidHistoryMutation(raid)
	staged.players[2] = { playerNid = staged.players[1].playerNid, name = "Duplicate" }
	local report = addon.Database.GetRaidValidator():GetRaidRecordValidation(staged, 0, 6)
	local expected
	for i = 1, #report.details do
		if report.details[i].level == "E" then
			expected = report.details[i].code
			break
		end
	end
	assertTrue(type(expected) == "string", "fixture must produce a validator error")
	local committed, reason = fixture.store:CommitRaidHistoryMutation(raid, staged, { reason = "test" })
	assertEqual(false, committed, "invalid history must not commit")
	assertEqual(expected, reason, "first error differs")
	print("PASS raid_store_uses_validator_first_error")
end

function cases.raid_store_rejects_malformed_validator_reports(addon)
	local malformedReports = {
		{ label = "nil report", value = nil },
		{ label = "missing details", value = {} },
		{ label = "non-table details", value = { details = "invalid" } },
		{ label = "non-table detail", value = { details = { false } } },
		{ label = "missing detail code", value = { details = { { level = "E" } } } },
		{ label = "sparse details", value = { details = { [2] = { level = "W", code = "SPARSE" } } } },
		{ label = "mapped details", value = { details = { hidden = { level = "W", code = "HIDDEN" } } } },
	}
	for i = 1, #malformedReports do
		local malformed = malformedReports[i]
		local fixture, _, raid = installLoggerAtomicFixture(addon)
		addon.Database.GetRaidValidator = function()
			return {
				GetRaidRecordValidation = function()
					return malformed.value
				end,
			}
		end
		local staged = fixture.store:StageRaidHistoryMutation(raid)
		local before = deepCopy(raid)
		local committed, reason = fixture.store:CommitRaidHistoryMutation(raid, staged, { reason = "test" })
		assertEqual(false, committed, malformed.label .. " must reject")
		assertEqual("INVALID_RAID", reason, malformed.label .. " reason differs")
		assertTrue(deepEqual(before, raid), malformed.label .. " must not mutate canonical raid")
	end

	local malformedImports = {
		{ label = "nil import report", value = nil },
		{ label = "sparse import details", value = { details = { [2] = { level = "W", code = "SPARSE" } } } },
		{ label = "mapped import details", value = { details = { hidden = { level = "W", code = "HIDDEN" } } } },
	}
	for i = 1, #malformedImports do
		local malformed = malformedImports[i]
		local fixture, _, raid = installLoggerAtomicFixture(addon)
		addon.Database.GetRaidValidator = function()
			return {
				GetRaidRecordValidation = function()
					return malformed.value
				end,
			}
		end
		local imported = deepCopy(raid)
		imported.raidNid = 999
		local before = deepCopy(fixture.raids)
		local first, second, reason = fixture.store:CommitNewRaidHistoryImport(imported, 1)
		assertEqual(nil, first, malformed.label .. " must not return a raid")
		assertEqual(nil, second, malformed.label .. " must preserve three-value arity")
		assertEqual("INVALID_RAID", reason, malformed.label .. " reason differs")
		assertTrue(deepEqual(before, fixture.raids), malformed.label .. " must not mutate raid history")
	end
	print("PASS raid_store_rejects_malformed_validator_reports")
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
	local root = fixture.store:GetRawRaids()
	root[4] = root[2]
	root[2] = nil
	fixture.currentRaid = nil
	local firstRaid, movedRaid = root[1], root[4]
	local firstRuntime, movedRuntime = firstRaid._runtime, movedRaid._runtime
	local firstRevision = firstRuntime and firstRuntime.syncRevision or nil
	local movedRevision = movedRuntime and movedRuntime.syncRevision or nil
	local before = deepCopy(root)
	local getAllCalls, commitCalls = 0, 0
	local originalGetAll = fixture.store.GetAllRaids
	fixture.store.GetAllRaids = function(store)
		getAllCalls = getAllCalls + 1
		return originalGetAll(store)
	end
	local originalCommit = fixture.store.CommitRaidHistoryCleanup
	fixture.store.CommitRaidHistoryCleanup = function(store, plan, currentRaidNid)
		commitCalls = commitCalls + 1
		return originalCommit(store, plan, currentRaidNid)
	end
	local callbackCount, callbackResult, callbackComplete = 0
	local handle = actions:StartRaidHistoryCleanup(function(result, complete)
		callbackCount = callbackCount + 1
		callbackResult, callbackComplete = result, complete
	end, { emptyRaids = true, nonEpicLoot = true, chunkSize = 1, delaySeconds = 0 })
	assertEqual(true, handle:Cancel(), "active cleanup should cancel")
	fixture.store.GetAllRaids = originalGetAll
	fixture.store.CommitRaidHistoryCleanup = originalCommit
	assertEqual(0, getAllCalls, "pre-commit cancellation must not rebuild the raid index")
	assertEqual(0, commitCalls, "pre-commit cancellation must not call the store commit")
	assertEqual(1, callbackCount, "pre-commit cancellation callback must run once")
	assertTrue(root == fixture.store:GetRawRaids(), "pre-commit cancellation must preserve root identity")
	assertTrue(root[1] == firstRaid and root[4] == movedRaid, "pre-commit cancellation must preserve raid identities")
	assertTrue(deepEqual(before, root), "cancelled staged cleanup must preserve sparse raw history exactly")
	assertTrue(firstRaid._runtime == firstRuntime, "pre-commit cancellation must not allocate first runtime")
	assertTrue(movedRaid._runtime == movedRuntime, "pre-commit cancellation must preserve moved runtime")
	assertEqual(firstRevision, firstRuntime and firstRuntime.syncRevision or nil, "pre-commit cancellation changed first revision")
	assertEqual(movedRevision, movedRuntime and movedRuntime.syncRevision or nil, "pre-commit cancellation changed moved revision")
	assertEqual(false, callbackComplete, "cancel callback should report incomplete work")
	assertEqual(true, callbackResult.cancelled, "cancel result should expose cancellation")
	assertEqual(false, callbackResult.changed, "rolled-back cleanup should report no canonical change")
	assertEqual(0, #fixture.events, "rollback cancellation should not publish a data-change event")
	assertEqual(false, handle:Cancel(), "cancelled cleanup must be terminal")
	assertEqual(1, callbackCount, "terminal cancellation must not call back again")
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
	local originalCommit = fixture.store.CommitRaidHistoryCleanup
	fixture.store.CommitRaidHistoryCleanup = function() return nil, "INJECTED_FAILURE" end
	local handle = actions:StartRaidHistoryCleanup(function(result, complete)
		callbackCount = callbackCount + 1
		callbackResult, callbackComplete = result, complete
	end, { emptyRaids = true, nonEpicLoot = true, chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	fixture.store.CommitRaidHistoryCleanup = originalCommit
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

function cases.logger_cleanup_detached_failure_is_atomic(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local root = fixture.store:GetRawRaids()
	local before = deepCopy(root)
	local originalCommit = fixture.store.CommitRaidHistoryCleanup
	fixture.store.CommitRaidHistoryCleanup = function() return nil, "INJECTED_FAILURE" end
	local result = actions:CleanupRaidHistory({ emptyRaids = true, nonEpicLoot = true })
	fixture.store.CommitRaidHistoryCleanup = originalCommit
	assertEqual(true, result.failed, "store rejection must fail cleanup")
	assertEqual("INJECTED_FAILURE", result.error)
	assertTrue(root == fixture.store:GetRawRaids(), "cleanup must preserve root identity")
	assertTrue(deepEqual(before, root), "failed detached commit must preserve history")
	assertEqual(nil, result.rollbackFailed, "rollback protocol must be absent")
	assertEqual(0, #fixture.events)
	print("PASS logger_cleanup_detached_failure_is_atomic")
end

function cases.logger_cleanup_planning_is_non_mutating(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local root = fixture.store:GetRawRaids()
	root[4] = root[2]
	root[2] = nil
	fixture.currentRaid = nil
	local firstRaid, movedRaid = root[1], root[4]
	local firstRuntime, movedRuntime = firstRaid._runtime, movedRaid._runtime
	local firstRevision = firstRuntime and firstRuntime.syncRevision or nil
	local movedRevision = movedRuntime and movedRuntime.syncRevision or nil
	local before = deepCopy(root)
	local getAllCalls = 0
	local originalGetAll = fixture.store.GetAllRaids
	fixture.store.GetAllRaids = function(store)
		getAllCalls = getAllCalls + 1
		return originalGetAll(store)
	end
	local originalCommit = fixture.store.CommitRaidHistoryCleanup
	fixture.store.CommitRaidHistoryCleanup = function() return nil, "INJECTED_FAILURE" end
	local result = actions:CleanupRaidHistory({ emptyRaids = true, nonEpicLoot = true })
	fixture.store.GetAllRaids = originalGetAll
	fixture.store.CommitRaidHistoryCleanup = originalCommit
	assertEqual(true, result.failed, "rejected cleanup must fail")
	assertEqual("INJECTED_FAILURE", result.error, "rejected cleanup reason differs")
	assertEqual(0, getAllCalls, "cleanup planning must not rebuild the raid index")
	assertTrue(root == fixture.store:GetRawRaids(), "cleanup planning must preserve root identity")
	assertTrue(root[1] == firstRaid and root[4] == movedRaid, "cleanup planning must preserve raid identities")
	assertTrue(deepEqual(before, root), "cleanup planning must preserve sparse raw history exactly")
	assertTrue(firstRaid._runtime == firstRuntime, "cleanup planning must not allocate first raid runtime")
	assertTrue(movedRaid._runtime == movedRuntime, "cleanup planning must preserve active runtime identity")
	assertEqual(firstRevision, firstRuntime and firstRuntime.syncRevision or nil, "first revision changed")
	assertEqual(movedRevision, movedRuntime and movedRuntime.syncRevision or nil, "moved revision changed")
	assertEqual(0, #fixture.events, "rejected planning must not publish")
	print("PASS logger_cleanup_planning_is_non_mutating")
end

function cases.logger_cleanup_noop_preserves_canonical_identities(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local root = fixture.store:GetRawRaids()
	local firstRaid, secondRaid = root[1], root[2]
	local firstRuntime = fixture.store:EnsureRaidRuntime(firstRaid)
	local secondRuntime = fixture.store:EnsureRaidRuntime(secondRaid)
	local firstRevision = fixture.store:GetRaidSyncRevision(firstRaid)
	local secondRevision = fixture.store:GetRaidSyncRevision(secondRaid)
	local before = deepCopy(root)
	local result = actions:CleanupRaidHistory({})
	assertEqual(true, result.complete, "synchronous no-op cleanup must complete")
	assertEqual(false, result.changed, "synchronous no-op cleanup must report no change")
	assertEqual(0, result.raidsRemoved, "synchronous no-op cleanup removed raids")
	assertEqual(0, result.lootRemoved, "synchronous no-op cleanup removed loot")
	assertEqual(0, #result.affectedRaidNids, "synchronous no-op cleanup affected raids")
	assertTrue(root == fixture.store:GetRawRaids(), "synchronous no-op must preserve root identity")
	assertTrue(root[1] == firstRaid and root[2] == secondRaid, "synchronous no-op must preserve raid identities")
	assertTrue(firstRaid._runtime == firstRuntime, "synchronous no-op must preserve first runtime index")
	assertTrue(secondRaid._runtime == secondRuntime, "synchronous no-op must preserve second runtime index")
	assertTrue(deepEqual(before, root), "synchronous no-op must preserve canonical history exactly")
	assertEqual(firstRevision, fixture.store:GetRaidSyncRevision(firstRaid), "synchronous no-op changed first revision")
	assertEqual(secondRevision, fixture.store:GetRaidSyncRevision(secondRaid), "synchronous no-op changed second revision")
	assertEqual(0, #fixture.events, "synchronous no-op must publish no event")
	print("PASS logger_cleanup_noop_preserves_canonical_identities")
end

function cases.logger_async_cleanup_noop_preserves_canonical_identities(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local root = fixture.store:GetRawRaids()
	root[4] = root[2]
	root[2] = nil
	fixture.currentRaid = nil
	local firstRaid, secondRaid = root[1], root[4]
	local firstRuntime = fixture.store:EnsureRaidRuntime(firstRaid)
	local secondRuntime = fixture.store:EnsureRaidRuntime(secondRaid)
	local firstRevision = fixture.store:GetRaidSyncRevision(firstRaid)
	local secondRevision = fixture.store:GetRaidSyncRevision(secondRaid)
	local before = deepCopy(root)
	local getAllCalls = 0
	local originalGetAll = fixture.store.GetAllRaids
	fixture.store.GetAllRaids = function(store)
		getAllCalls = getAllCalls + 1
		return originalGetAll(store)
	end
	local callbackCount, callbackResult, callbackComplete = 0
	local handle = actions:StartRaidHistoryCleanup(function(result, complete)
		callbackCount = callbackCount + 1
		callbackResult, callbackComplete = result, complete
	end, { chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	fixture.store.GetAllRaids = originalGetAll
	assertEqual(0, getAllCalls, "asynchronous no-op must not rebuild the raid index")
	assertEqual(1, callbackCount, "asynchronous no-op callback must run once")
	assertEqual(true, callbackComplete, "asynchronous no-op cleanup must complete")
	assertEqual(true, callbackResult.complete, "asynchronous no-op result must be complete")
	assertEqual(false, callbackResult.changed, "asynchronous no-op cleanup must report no change")
	assertEqual(0, callbackResult.raidsRemoved, "asynchronous no-op cleanup removed raids")
	assertEqual(0, callbackResult.lootRemoved, "asynchronous no-op cleanup removed loot")
	assertEqual(0, #callbackResult.affectedRaidNids, "asynchronous no-op cleanup affected raids")
	assertTrue(root == fixture.store:GetRawRaids(), "asynchronous no-op must preserve root identity")
	assertTrue(root[1] == firstRaid and root[4] == secondRaid, "asynchronous no-op must preserve raid identities")
	assertTrue(firstRaid._runtime == firstRuntime, "asynchronous no-op must preserve first runtime index")
	assertTrue(secondRaid._runtime == secondRuntime, "asynchronous no-op must preserve second runtime index")
	assertTrue(deepEqual(before, root), "asynchronous no-op must preserve canonical history exactly")
	assertEqual(firstRevision, fixture.store:GetRaidSyncRevision(firstRaid), "asynchronous no-op changed first revision")
	assertEqual(secondRevision, fixture.store:GetRaidSyncRevision(secondRaid), "asynchronous no-op changed second revision")
	assertEqual(0, #fixture.events, "asynchronous no-op must publish no event")
	assertEqual(false, handle:IsCancelled(), "completed asynchronous no-op is not cancelled")
	assertEqual(false, handle:Cancel(), "completed asynchronous no-op must be terminal")
	assertEqual(1, callbackCount, "terminal no-op handle must not call back again")
	print("PASS logger_async_cleanup_noop_preserves_canonical_identities")
end

function cases.raid_store_cleanup_conflict_is_atomic(addon)
	local fixture = installLoggerCleanupFixture(addon)
	local root = fixture.store:GetRawRaids()
	local firstRaid, secondRaid = root[1], root[2]
	local firstRuntime = fixture.store:EnsureRaidRuntime(firstRaid)
	local secondRuntime = fixture.store:EnsureRaidRuntime(secondRaid)
	local firstRevision = fixture.store:GetRaidSyncRevision(firstRaid)
	local secondRevision = fixture.store:GetRaidSyncRevision(secondRaid)
	local before = deepCopy(root)
	local committed, reason = fixture.store:CommitRaidHistoryCleanup({
		protectedRaidNid = secondRaid.raidNid,
		raidCandidates = { { raidNid = firstRaid.raidNid, baseRevision = firstRevision + 1 } },
		lootCandidates = {},
	}, secondRaid.raidNid)
	assertEqual(nil, committed, "revision conflict must reject cleanup")
	assertEqual("CONFLICT", reason, "revision conflict reason differs")
	assertTrue(root == fixture.store:GetRawRaids(), "conflict must preserve root identity")
	assertTrue(root[1] == firstRaid and root[2] == secondRaid, "conflict must preserve raid identities")
	assertTrue(firstRaid._runtime == firstRuntime, "conflict must preserve first runtime index")
	assertTrue(secondRaid._runtime == secondRuntime, "conflict must preserve second runtime index")
	assertTrue(deepEqual(before, root), "conflict must preserve canonical history exactly")
	assertEqual(firstRevision, fixture.store:GetRaidSyncRevision(firstRaid), "conflict changed first revision")
	assertEqual(secondRevision, fixture.store:GetRaidSyncRevision(secondRaid), "conflict changed second revision")
	assertEqual(0, #fixture.events, "conflict must publish no event")
	print("PASS raid_store_cleanup_conflict_is_atomic")
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
		CaptureActivationState = function() return { activeInstanceKey = activated.loot } end,
		RestoreActivationState = function(snapshot)
			activated.loot = snapshot.activeInstanceKey
			return true
		end,
	}
	addon.IgnoredMobs = {
		ActivateInstance = function(key) activated.ignored = key return true end,
		DeactivateInstance = function() activated.ignored = nil end,
		GetActiveInstanceKey = function() return activated.ignored end,
		CaptureActivationState = function() return { activeInstanceKey = activated.ignored } end,
		RestoreActivationState = function(snapshot)
			activated.ignored = snapshot.activeInstanceKey
			return true
		end,
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

function cases.dataset_activation_requires_snapshot_contract(addon)
	installInitStubs(addon)
	addon.L = { RaidZones = {} }
	addon.Diag = { D = { LogRaidInstanceRecognized = "%s %s" }, W = { LogRaidUnmappedZone = "%s %s" } }
	addon.warn = function() end
	local lootKey
	local ignoredKey
	addon.LootSourcesData = {
		ResolveInstanceKey = function() return "icecrown citadel" end,
		GetActiveInstanceKey = function() return lootKey end,
		ActivateInstance = function(key) lootKey = key return true end,
		DeactivateInstance = function() lootKey = nil return true end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function() return ignoredKey end,
		ActivateInstance = function(key) ignoredKey = key return true end,
		DeactivateInstance = function() ignoredKey = nil return true end,
	}
	_G.GetInstanceInfo = function() return "Localized", "raid", 1, nil, 10, 0, false, 631 end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	local ok, err = pcall(addon.ZONE_CHANGED_NEW_AREA, addon)
	assertEqual(false, ok, "missing mandatory dataset snapshot methods must fail fast")
	assertTrue(string.find(tostring(err), "CaptureActivationState", 1, true) ~= nil)
	print("PASS dataset_activation_requires_snapshot_contract")
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
		CaptureActivationState = function() return { activeInstanceKey = lootKey } end,
		RestoreActivationState = function(snapshot)
			lootKey = snapshot.activeInstanceKey
			return true
		end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function() return ignoredKey end,
		ActivateInstance = function(key)
			if key == "new raid" then error("injected ignored failure") end
			ignoredKey = key
			return true
		end,
		DeactivateInstance = function() ignoredKey = nil return true end,
		CaptureActivationState = function() return { activeInstanceKey = ignoredKey } end,
		RestoreActivationState = function(snapshot)
			ignoredKey = snapshot.activeInstanceKey
			return true
		end,
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
		CaptureActivationState = function() return { activeInstanceKey = lootKey } end,
		RestoreActivationState = function(snapshot)
			lootKey = snapshot.activeInstanceKey
			return true
		end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function() return ignoredKey end,
		ActivateInstance = function(key) ignoredCalls = ignoredCalls + 1 ignoredKey = key return true end,
		DeactivateInstance = function() ignoredKey = nil return true end,
		CaptureActivationState = function() return { activeInstanceKey = ignoredKey } end,
		RestoreActivationState = function(snapshot)
			ignoredKey = snapshot.activeInstanceKey
			return true
		end,
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
		CaptureActivationState = function() return { activeInstanceKey = lootKey } end,
		RestoreActivationState = function()
			return false
		end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function() return ignoredKey end,
		ActivateInstance = function(key)
			if key == "new raid" then ignoredKey = nil return false, "ignored-rejected" end
			ignoredKey = key return true
		end,
		DeactivateInstance = function() ignoredKey = nil return true end,
		CaptureActivationState = function() return { activeInstanceKey = ignoredKey } end,
		RestoreActivationState = function(snapshot)
			ignoredKey = snapshot.activeInstanceKey
			return true
		end,
	}
	_G.GetInstanceInfo = function() return "Localized", "raid", 1, nil, 10, 0, false, 999 end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	local ok, err = pcall(addon.ZONE_CHANGED_NEW_AREA, addon)
	assertEqual(false, ok)
	assertTrue(string.find(tostring(err), "dataset_rollback_failed", 1, true) ~= nil)
	assertTrue(string.find(tostring(err), "snapshot-restore-rejected", 1, true) ~= nil)
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

function cases.options_reset_all_defaults(addon)
	local options = installOptionsStubs(addon)
	local first = options.RegisterNamespace("First", { enabled = true, nested = { count = 1 } })
	local second = options.RegisterNamespace("Second", { mode = "safe" })
	assertEqual(true, first:Set("enabled", false))
	assertEqual(true, first:Set("nested", { count = 9 }))
	assertEqual(true, second:Set("mode", "custom"))

	assertEqual(true, options.ResetAllDefaults(), "all-default reset must report success")
	assertEqual(true, first:Get("enabled"), "first namespace scalar must reset")
	assertEqual(1, first:Get("nested").count, "first namespace nested value must reset")
	assertEqual("safe", second:Get("mode"), "second namespace must reset")
	assertEqual(nil, options["Get" .. "Namespaces"], "namespace enumeration facade must not remain public")
	print("PASS options_reset_all_defaults")
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
	addon.Database.GetRaidValidator = function()
		return addon.DB.RaidValidator
	end
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
	local fixture = { timers = {}, events = {}, diagnostics = {} }
	table.wipe = table.wipe or function(value)
		for key in pairs(value) do value[key] = nil end
		return value
	end
	_G.GetItemInfo = function(itemRef)
		return tostring(itemRef), "item:" .. tostring(itemRef), nil, nil, nil, nil, nil, nil, nil, "icon"
	end
	addon.L = setmetatable({ StrUnknown = "Unknown" }, { __index = function(_, key) return key end })
	addon.Diag = {
		D = setmetatable({}, { __index = function() return "%s" end }),
		E = setmetatable({}, { __index = function() return "%s" end }),
	}
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
			fixture.optionValues = values
			return {
				Get = function(_, key) return values[key] end,
				Set = function(_, key, value)
					if fixture.failStage == "alias_option" and key == "nameAliases" then
						fixture.failStage = nil
						error("injected alias option failure")
					end
					local old = values[key]
					if old == value then return true end
					values[key] = value
					if key == "srImportMode" and fixture.optionObserver then
						fixture.optionObserver(key, old, value)
					end
					return true
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
	addon.error = function(_, message, detail)
		fixture.diagnostics[#fixture.diagnostics + 1] = detail and string.format(message, detail) or tostring(message)
	end
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
			BuildAliasState = function(source)
				local state = { reserveKeyByRaidKey = {} }
				for reserveKey, raidName in pairs(source or {}) do
					state.reserveKeyByRaidKey[string.lower(raidName)] = string.lower(reserveKey)
				end
				return state
			end,
			ResolveReserveKey = function(state, data, playerName)
				local key = type(playerName) == "string" and string.lower(playerName) or nil
				if key and data[key] then return key end
				local reserveKey = key and state.reserveKeyByRaidKey[key] or nil
				return reserveKey and data[reserveKey] and reserveKey or nil
			end,
			GetAliasMatches = function() return {} end,
		},
		_Display = {
			RebuildIndex = function(ctx)
				if fixture.failStage == "index" then
					fixture.failStage = nil
					error("injected index failure")
				end
				table.wipe(ctx.reservesByItemID)
				table.wipe(ctx.reservesByItemPlayer)
				table.wipe(ctx.playerItemsByName)
				for playerKey, player in pairs(ctx.reservesData) do
					local playerName = ctx.resolvePlayerNameDisplay(playerKey, player)
					local normalized = string.lower(playerName or playerKey)
					ctx.playerItemsByName[normalized] = ctx.playerItemsByName[normalized] or {}
					for i = 1, #(player.reserves or {}) do
						local row = player.reserves[i]
						if type(row) == "table" and row.rawID then
							local itemId = row.rawID
							ctx.reservesByItemID[itemId] = ctx.reservesByItemID[itemId] or {}
							ctx.reservesByItemID[itemId][#ctx.reservesByItemID[itemId] + 1] = row
							if fixture.skipPlayerIndexItem ~= itemId then
								ctx.reservesByItemPlayer[itemId] = ctx.reservesByItemPlayer[itemId] or {}
								ctx.reservesByItemPlayer[itemId][normalized] = row
							end
							ctx.playerItemsByName[normalized][itemId] = true
						end
					end
				end
				if fixture.lookupProbe then
					local row = ctx.getReserveEntryForItem(fixture.lookupProbe.itemId, fixture.lookupProbe.playerName)
					fixture.detachedLookupQuantity = row and row.quantity or nil
				end
				ctx.setDirty(true)
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
	assertEqual(true, reserves:HasItemReserves(100), "synced baseline must build the item index")
	assertEqual(true, reserves:HasItemReserves(200), "synced baseline must index every reserve item")
	local serializationName = table.concat({ "Build", "Canonical", "Serialization" })
	assertEqual(nil, reserves[serializationName],
		"canonical serialization must remain a private reserve implementation detail")
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
	local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
	fixture.failStage = "index"
	ok, reason = reserves:ApplyBatch({
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
	})
	fixture.failStage = nil
	assertEqual(nil, ok, "detached index failure must reject the batch")
	assertEqual("publish_failed", reason, "detached index failure reason differs")
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "failed detached build must preserve SavedVariables values")
	assertTrue(deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
		"failed detached build must preserve runtime values")
	assertEqual(2, reserves:GetReserveCountForItem(100, "Alpha"),
		"derived reserve lookup must match the preserved state")
	assertEqual(true, reserves:HasItemReserves(100), "failed detached build must preserve the published item index")
	assertEqual(true, reserves:GetSyncMetadata().runtime, "detached index failure must retain synced cache ownership")
	assertEqual(savesBefore, fixture.saveCount or 0, "failed detached build must not save")
	assertEqual(eventsBefore, #fixture.events, "failed detached build must not publish")

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
	assertEqual(true, reserves:HasItemReserves(200), "successful batch must publish the detached item index")
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
			local savedBefore = deepCopy(_G.RMA_Reserves)
			local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
			local eventsBefore, savesBefore = #fixture.events, fixture.saveCount or 0
			if fault == "replace" then fixture.failReplace = true else fixture.failStage = "index" end
			local invoked, changed, reason = pcall(operation.call, reserves)
			fixture.failReplace, fixture.failStage = nil, nil
			assertEqual(true, invoked, operation.name .. " must contain " .. fault .. " fault")
			assertTrue(not changed, operation.name .. " must fail on " .. fault .. " fault")
			assertEqual("publish_failed", reason, operation.name .. " fault reason differs")
			assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), operation.name .. " must preserve SavedVariables values")
			assertTrue(deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
				operation.name .. " must preserve runtime values")
			assertEqual(1, reserves:GetReserveCountForItem(100, "Alpha"),
				operation.name .. " derived lookup must match the preserved state")
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
	local savedBefore = deepCopy(_G.RMA_Reserves)
	local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
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
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "malformed imports must preserve values")
	assertTrue(deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
		"malformed imports must preserve runtime values")
	assertEqual(1, reserves:GetReserveCountForItem(50, "Base"),
		"malformed imports must preserve derived reserve lookup")
	print("PASS reserves_async_import_rejects_noncanonical_and_sparse_sources")
end

function cases.reserves_async_import_scheduler_failures_are_terminal(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:ApplyImport({ reservesData = { base = reserveImportPlayer("Base", 50) } }, nil,
		{ silentInfo = true }), "baseline import must succeed")
	local savedBefore = deepCopy(_G.RMA_Reserves)
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
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "scheduler failures must preserve SavedVariables values")
	assertEqual(50, reserves:GetPlayerReserveEntries("Base")[1].rawID, "scheduler failures must preserve runtime")
	print("PASS reserves_async_import_scheduler_failures_are_terminal")
end

function cases.reserves_async_import_publish_faults_rollback_exact_state(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = { base = reserveImportPlayer("Base", 50) } }, nil,
		{ silentInfo = true }), "baseline import must succeed")
	for _, stage in ipairs({ "index" }) do
		local savedRoot = _G.RMA_Reserves
		local savedBefore = deepCopy(savedRoot)
		local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
		local eventsBefore = #fixture.events
		fixture.failStage = stage
		local results = {}
		reserves:RequestApplyImport({ mode = "plus", reservesData = { alpha = reserveImportPlayer("Alpha", 100) } }, nil,
			function(...) results[#results + 1] = { ... } end, { chunkSize = 1, silentInfo = true })
		fixture:RunTimer(#fixture.timers)
		assertEqual(1, #results, "publish fault callback must run once for " .. stage)
		assertEqual(false, results[1][1], "publish fault must fail for " .. stage)
		assertEqual("failed", results[1][2], "publish fault result differs for " .. stage)
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "publish fault must preserve SavedVariables values for " .. stage)
		assertTrue(deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
			"publish fault must preserve runtime values for " .. stage)
		assertEqual(1, reserves:GetReserveCountForItem(50, "Base"),
			"publish fault derived lookup must match preserved state for " .. stage)
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

function cases.reserves_lookup_preserves_identity_index_fallback_and_detached_state(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	local data = {
		alpha = { playerNameDisplay = "Alpha", reserves = {
			{ rawID = 100, itemName = "Indexed", quantity = 2, plus = 1 },
			{ rawID = 200, itemName = "Fallback", quantity = 3, plus = 0 },
		} },
		raider = { playerNameDisplay = "Raider", reserves = {
			{ rawID = 100, itemName = "Exact", quantity = 5, plus = 0 },
		} },
	}
	fixture.skipPlayerIndexItem = 200
	assertTrue(reserves:SetSyncedData(data, { source = "Leader", checksum = "lookup", mode = "multi" }),
		"lookup fixture import failed")
	assertTrue(reserves:SetNameAlias("Alpha", "Raider"), "lookup fixture alias failed")
	assertEqual(5, reserves:GetReserveCountForItem(100, "Raider"),
		"exact reserve identity must take precedence over an alias target")
	assertTrue(reserves:SetNameAlias("Alpha", "AliasRaid"), "lookup alias replacement failed")
	assertEqual(2, reserves:GetReserveCountForItem(100, "AliasRaid"),
		"raid-name alias must resolve to the reserve owner")
	assertEqual(2, reserves:GetReserveCountForItem(100, "Alpha"), "indexed lookup quantity differs")
	assertEqual(3, reserves:GetReserveCountForItem(200, "Alpha"), "fallback traversal quantity differs")

	fixture.lookupProbe = { itemId = 100, playerName = "Alpha" }
	assertTrue(reserves:ApplyBatch({
		{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
	}), "detached publication mutation failed")
	assertEqual(4, fixture.detachedLookupQuantity,
		"detached publication lookup did not observe candidate state")
	assertEqual(4, reserves:GetReserveCountForItem(100, "Alpha"),
		"published lookup did not observe committed candidate state")
	print("PASS reserves_lookup_preserves_identity_index_fallback_and_detached_state")
end

function cases.reserves_import_option_notification_is_post_commit(addon)
	do
		local reserves, fixture = installRealReservesMutationFixture(addon)
		assertTrue(reserves:SetSyncedData({ base = reserveImportPlayer("Base", 50) },
			{ source = "Leader", checksum = "fixture", mode = "multi" }))
		local savedBefore = deepCopy(_G.RMA_Reserves)
		local runtimeBefore = deepCopy(reserves:GetPlayerReserveEntries("Base"))
		local savesBefore, eventsBefore = fixture.saveCount or 0, #fixture.events
		fixture.failReplace = true
		local ok, reason = reserves:ApplyImport({ mode = "plus", reservesData = {
			alpha = reserveImportPlayer("Alpha", 100),
		} }, nil, { silentInfo = true })
		fixture.failReplace = nil
		assertEqual(false, ok, "reserve replacement failure must reject the import")
		assertEqual("PUBLISH_FAILED", reason, "reserve replacement failure reason differs")
		assertEqual(0, fixture.optionValues.srImportMode, "replacement failure must preserve the stored mode")
		assertEqual("multi", reserves:GetImportMode(), "replacement failure must preserve the local mode")
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "replacement failure must preserve SavedVariables")
		assertTrue(deepEqual(runtimeBefore, reserves:GetPlayerReserveEntries("Base")),
			"replacement failure must preserve runtime roots")
		assertEqual(true, reserves:HasItemReserves(50), "replacement failure must preserve the old item index")
		assertEqual(false, reserves:HasItemReserves(100), "replacement failure must not publish the candidate index")
		assertEqual(true, reserves:GetSyncMetadata().runtime, "replacement failure must preserve cache ownership")
		assertEqual(savesBefore, fixture.saveCount or 0, "replacement failure must not save")
		assertEqual(eventsBefore, #fixture.events, "replacement failure must not publish a data event")
		assertEqual(0, #fixture.diagnostics, "replacement failure must not report an option diagnostic")
	end

	do
		local reserves, fixture = installRealReservesMutationFixture(addon)
		local savesBefore, eventsBefore = fixture.saveCount or 0, #fixture.events
		fixture.optionObserver = function() error("injected OptionChanged observer failure") end
		local ok = reserves:ApplyImport({ mode = "plus", reservesData = {
			alpha = reserveImportPlayer("Alpha", 100),
		} }, nil, { silentInfo = true })
		assertEqual(true, ok, "OptionChanged failure must not invalidate the committed import")
		assertEqual(1, fixture.optionValues.srImportMode, "OptionChanged failure must retain the stored mode")
		assertEqual("plus", reserves:GetImportMode(), "OptionChanged failure must retain the local mode")
		assertEqual(100, reserves:GetPlayerReserveEntries("Alpha")[1].rawID,
			"OptionChanged failure must retain the published reserve roots")
		assertEqual(true, reserves:HasItemReserves(100), "OptionChanged failure must retain the published index")
		assertEqual(false, reserves:GetSyncMetadata().runtime, "OptionChanged failure must retain local cache ownership")
		assertEqual(savesBefore + 1, fixture.saveCount or 0, "OptionChanged failure must save exactly once")
		assertEqual(eventsBefore + 1, #fixture.events, "OptionChanged failure must publish one data event")
		assertEqual(1, #fixture.diagnostics, "OptionChanged failure must report one contained diagnostic")
	end

	do
		local reserves, fixture = installRealReservesMutationFixture(addon)
		assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = {
			base = reserveImportPlayer("Base", 50),
		} }, nil, { silentInfo = true }), "reentrant observer baseline import must succeed")
		local observed = {}
		fixture.optionObserver = function()
			observed.mode = reserves:GetImportMode()
			observed.hasNewItem = reserves:HasItemReserves(200)
			observed.hasOldItem = reserves:HasItemReserves(50)
			observed.rawID = reserves:GetPlayerReserveEntries("Bravo")[1].rawID
			observed.runtime = reserves:GetSyncMetadata().runtime
		end
		local ok = reserves:ApplyImport({ mode = "plus", reservesData = {
			bravo = reserveImportPlayer("Bravo", 200),
		} }, nil, { silentInfo = true })
		assertEqual(true, ok, "reentrant OptionChanged observation must not reject the import")
		assertEqual("plus", observed.mode, "OptionChanged observer must see the new local mode")
		assertEqual(true, observed.hasNewItem, "OptionChanged observer must see the new item index")
		assertEqual(false, observed.hasOldItem, "OptionChanged observer must not see stale item indexes")
		assertEqual(200, observed.rawID, "OptionChanged observer must see the new reserve roots")
		assertEqual(false, observed.runtime, "OptionChanged observer must see promoted cache ownership")
		assertEqual(0, #fixture.diagnostics, "successful OptionChanged observation must report no diagnostic")
	end
	print("PASS reserves_import_option_notification_is_post_commit")
end

function cases.reserves_direct_import_apis_revalidate_bounded_canonical_input(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:ApplyImport({ mode = "multi", reservesData = { base = reserveImportPlayer("Base", 50) } }, nil,
		{ silentInfo = true }), "baseline import must succeed")
	local savedBefore = deepCopy(_G.RMA_Reserves)
	local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
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
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "invalid import must preserve values at " .. i)
		assertTrue(deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
			"invalid import must preserve runtime values at " .. i)
		assertEqual(1, reserves:GetReserveCountForItem(50, "Base"),
			"invalid import derived lookup must match preserved state at " .. i)
		assertEqual(eventsBefore, #fixture.events, "invalid import must not publish at " .. i)
	end
	for _, stage in ipairs({ "replace", "index" }) do
		if stage == "replace" then fixture.failReplace = true else fixture.failStage = stage end
		local ok, reason = reserves:ApplyImport({ mode = "plus", reservesData = {
			alpha = reserveImportPlayer("Alpha", 100),
		} }, nil, { silentInfo = true })
		fixture.failReplace, fixture.failStage = nil, nil
		assertEqual(false, ok, "synchronous import must contain " .. stage .. " fault")
		assertEqual("PUBLISH_FAILED", reason, "synchronous publish reason differs for " .. stage)
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "sync fault must preserve values")
		assertTrue(deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
			"sync fault must preserve runtime values")
		assertEqual(1, reserves:GetReserveCountForItem(50, "Base"),
			"sync fault derived lookup must match preserved state")
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
		local savedBefore = deepCopy(_G.RMA_Reserves)
		local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
		local eventsBefore = #fixture.events
		if fault == "replace" then fixture.failReplace = true else fixture.failStage = "index" end
		local invoked, ok, reason = pcall(reserves.AddPlayerReserve, reserves, "Alpha", 200)
		fixture.failReplace, fixture.failStage = nil, nil
		assertEqual(true, invoked, "add must contain " .. fault .. " fault")
		assertEqual(false, ok, "add must fail on " .. fault .. " fault")
		assertEqual("publish_failed", reason, "add publish reason differs")
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "add fault must preserve SavedVariables values")
		assertTrue(deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
			"add fault must preserve runtime values")
		assertEqual(1, reserves:GetReserveCountForItem(100, "Alpha"),
			"add fault derived lookup must match preserved state")
		assertEqual(true, reserves:GetSyncMetadata().runtime, "add fault must preserve synced cache ownership")
		assertEqual(eventsBefore, #fixture.events, "add fault must publish no event")
	end
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(reserves:SetSyncedData({ alpha = reserveImportPlayer("Alpha", 100) },
		{ source = "Leader", checksum = "fixture", mode = "multi" }))
	local eventsBefore = #fixture.events
	local ok, row = reserves:AddPlayerReserve("Alpha", 200)
	assertEqual(true, ok, "valid add must commit")
	assertTrue(deepEqual(row, reserves:GetPlayerReserveEntries("Alpha")[2]),
		"successful add must return the committed reserve value")
	assertEqual(1, reserves:GetReserveCountForItem(200, "Alpha"),
		"successful add derived lookup must match the published candidate")
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

local encodedWirePayloadMarker = "ENCODED_WIRE_PAYLOAD_MARKER"
local parsedRowItemMarker = "PARSED_ROW_ITEM_MARKER"

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
		localRevision = 0,
		deltaParses = 0,
		deltaImports = 0,
		inRaid = true,
		groupUnits = {},
		unitRanks = {},
		callbacks = {},
		nextRequestId = 0,
		debugEnabled = false,
		debugMessages = {},
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
		MsgLoggerSyncApplied = "%s %s",
		MsgLoggerPushImported = "%s %s", MsgLoggerReqImported = "%s %s",
	}
	local passthrough = setmetatable({
		LogSyncTrace = "[SyncTrace] event=%s %s",
	}, { __index = function() return "%s" end })
	local warningDiagnostics = setmetatable({
		LogSyncRevisionUnauthorized = "[Sync] Ignored history revision from non-master sender=%s",
	}, { __index = function() return "%s" end })
	addon.Diag = { D = passthrough, W = warningDiagnostics, E = passthrough }
	addon.DB = { Syncer = {} }
	addon.Events = {
		Internal = {
			OptionsLoaded = "OPTIONS",
			LoggerSelectRaid = "SELECT",
			RaidCreate = "CREATE",
			RaidRosterDelta = "ROSTER_DELTA",
			RaidLootUpdate = "RAID_LOOT_UPDATE",
		},
		Wow = { ZoneChangedNewArea = "wow.ZONE_CHANGED_NEW_AREA" },
		BuildConfigOptionChangedName = function(name) return "OPTION_" .. name end,
	}
	addon.Bus = {
		TriggerEvent = function(eventName, ...)
			fixture.events[#fixture.events + 1] = { eventName = eventName, args = { ... } }
		end,
		RegisterCallback = function(eventName, callback)
			fixture.callbacks[eventName] = callback
		end,
	}
	addon.Strings = { NormalizeName = trim, NormalizeLower = lower, TrimText = trim }
	addon.Timer = { BindMixin = function(target)
		target.ScheduleTimer = function(_, callback, delay)
			local handle = { callback = callback, delay = delay, active = true }
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
		IsDebugEnabled = function() return fixture.debugEnabled end,
	}
	addon.Comms = {
		RegisterPrefixIfAvailable = function() end,
		NormalizeSender = function(value) return trim(value) end,
		NextRequestId = function()
			fixture.nextRequestId = fixture.nextRequestId + 1
			return "generated-" .. tostring(fixture.nextRequestId)
		end,
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
	addon.Database.GetUnitRank = function(unit, fallback)
		return fixture.unitRanks[unit] or fallback or 0
	end
	function fixture:FireTimer(handle)
		if not handle or handle.active ~= true then return false end
		handle.active = false
		handle.callback()
		return true
	end
	function fixture:TriggerRaidLootUpdate(raidNum, row)
		local callback = assert(self.callbacks.RAID_LOOT_UPDATE, "raid loot callback must be bound")
		return callback("RAID_LOOT_UPDATE", raidNum, row)
	end
	local syncStore = {
		GetRaidSyncRevision = function() return fixture.localRevision end,
		SetRaidSyncRevision = function(_, _, revision)
			fixture.localRevision = tonumber(revision) or 0
			return fixture.localRevision
		end,
	}
	addon.Database.GetRaidStore = function() return syncStore end
	addon.Services.Raid = {
		GetUnitID = function(_, rawSender)
			return fixture.groupUnits[lower(rawSender)] or "none"
		end,
		IsGroupMember = function(_, rawSender)
			return fixture.groupUnits[lower(rawSender)] ~= nil
		end,
		CanUseCapability = function()
			local playerName = lower(addon.Database.GetPlayerName())
			for i = 1, #fixture.roster do
				local member = fixture.roster[i]
				if lower(member.name) == playerName then
					return (tonumber(member.rank) or 0) > 0
				end
			end
			return false
		end,
		GetLootMethodName = function() return fixture.lootMethod or "group" end,
		GetMasterLooterName = function()
			if fixture.lootMethod ~= "master" then return nil end
			return fixture.lootAuthority
		end,
		IsLootAuthority = function(_, rawSender)
			if lower(rawSender) ~= lower(fixture.lootAuthority) then return false end
			return fixture.inRaid or fixture.groupUnits[lower(rawSender)] ~= nil
		end,
		IsMasterLooter = function() return fixture.localMasterLooter == true end,
	}
	addon.IsInRaid = function() return fixture.inRaid end
	addon.IsInGroup = function() return true end
	addon.warn = function(_, message) fixture.warnings[#fixture.warnings + 1] = message end
	addon.error = function(_, message) fixture.warnings[#fixture.warnings + 1] = message end
	addon.info = function(_, message) fixture.infos[#fixture.infos + 1] = message end
	addon.debug = function(_, message)
		fixture.debugMessages[#fixture.debugMessages + 1] = tostring(message)
		if fixture.debugHook then fixture.debugHook(tostring(message)) end
	end
	function fixture:HasDebug(fragment)
		for i = 1, #self.debugMessages do
			if string.find(self.debugMessages[i], fragment, 1, true) then return true end
		end
		return false
	end
	function fixture:CountDebug(fragment)
		local count = 0
		for i = 1, #self.debugMessages do
			if string.find(self.debugMessages[i], fragment, 1, true) then count = count + 1 end
		end
		return count
	end
	function fixture:GetSyncTraces(eventName, requestId)
		local traces = {}
		local prefix = "[SyncTrace] event=" .. tostring(eventName)
		for i = 1, #self.debugMessages do
			local message = self.debugMessages[i]
			if string.sub(message, 1, #prefix) == prefix and string.sub(message, #prefix + 1, #prefix + 1) == " " then
				local fields = {}
				local details = string.sub(message, #prefix + 2)
				local positions, searchStart = {}, 1
				while true do
					local fieldStart, fieldEnd, key = string.find(details, "([%w]+)=", searchStart)
					if not fieldStart then break end
					positions[#positions + 1] = { key = key, fieldStart = fieldStart, valueStart = fieldEnd + 1 }
					searchStart = fieldEnd + 1
				end
				for fieldIndex = 1, #positions do
					local position = positions[fieldIndex]
					local nextPosition = positions[fieldIndex + 1]
					local valueEnd = nextPosition and (nextPosition.fieldStart - 2) or #details
					fields[position.key] = string.sub(details, position.valueStart, valueEnd)
				end
				if requestId == nil or fields.req == tostring(requestId) then
					traces[#traces + 1] = { line = message, fields = fields }
				end
			end
		end
		return traces
	end

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
		Build = function() return fixture.snapshotPayload or "snapshot" end,
		BuildDelta = function() return nil end,
		ValidateSnapshot = function() return true end,
		ValidateDelta = function() return true end,
		Parse = function(value)
			if fixture.failNextParse then
				fixture.failNextParse = false
				return nil
			end
			if value ~= "snapshot" and value ~= "snapshot-v1" and value ~= encodedWirePayloadMarker then return nil end
			if fixture.snapshot then return deepCopy(fixture.snapshot) end
			return { header = { protocolVersion = value == "snapshot-v1" and 1 or 2, raidNid = 41 }, bossKills = {}, loot = {} }
		end,
		ParseDelta = function(value)
			if value ~= "delta-v1" and value ~= "delta-v2" then return nil end
			fixture.deltaParses = fixture.deltaParses + 1
			if fixture.delta then return deepCopy(fixture.delta) end
			return { header = { protocolVersion = value == "delta-v1" and 1 or 2, raidNid = 41 }, loot = {} }
		end,
	}
	local raid = { raidNid = 41, zone = "Naxxramas", size = 25, difficulty = 1 }
	fixture.currentRaid = raid
	addon.DB.Syncer._Import = {
		ResolveRaidByReference = function() return raid end,
		GetCurrentRaidRecord = function() return fixture.currentRaid, 41 end,
		RaidMatchesSignature = function(currentRaid, signature)
			return currentRaid.zone == signature.zone
				and currentRaid.size == signature.size
				and currentRaid.difficulty == signature.diff
		end,
		RaidMatchesSnapshotHeader = function(currentRaid, header)
			return currentRaid.zone == header.zone
				and currentRaid.size == header.size
				and currentRaid.difficulty == header.difficulty
		end,
		BuildSignatureFromRaid = function(currentRaid)
			return { zone = currentRaid.zone, size = currentRaid.size, diff = currentRaid.difficulty }
		end,
		ReplaceRaidFromAuthority = function(_, snapshot)
			fixture.importAttempts = fixture.importAttempts + 1
			if fixture.failNextImport then
				fixture.failNextImport = false
				error("fixture import failure")
			end
			fixture.imports = fixture.imports + 1
			fixture.importedSnapshot = deepCopy(snapshot)
			fixture.localRevision = tonumber(snapshot.header and snapshot.header.revision) or 0
			raid.loot = deepCopy(snapshot.loot or {})
			return raid
		end,
		ApplyDeltaToRaid = function(_, delta)
			fixture.deltaImports = fixture.deltaImports + 1
			fixture.localRevision = tonumber(delta.header and delta.header.revision) or fixture.localRevision
			return raid
		end,
		ApplyDeltaFromAuthority = function(_, delta)
			fixture.deltaImports = fixture.deltaImports + 1
			fixture.localRevision = tonumber(delta.header and delta.header.revision) or fixture.localRevision
			return raid
		end,
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

local function assertSingleSyncTrace(fixture, eventName, requestId, expectedFields)
	local traces = fixture:GetSyncTraces(eventName, requestId)
	assertEqual(1, #traces, eventName .. " trace cardinality differs for request " .. tostring(requestId))
	local trace = traces[1]
	for key, expected in pairs(expectedFields) do
		assertEqual(tostring(expected), trace.fields[key], eventName .. " trace field differs: " .. tostring(key))
	end
	return trace
end

local function assertSingleImportOutcome(fixture, eventName, requestId, expectedFields)
	local applyCount = #fixture:GetSyncTraces("IMPORT_APPLY", requestId)
	local rejectCount = #fixture:GetSyncTraces("IMPORT_REJECT", requestId)
	assertEqual(1, applyCount + rejectCount, "import outcome cardinality differs for request " .. tostring(requestId))
	return assertSingleSyncTrace(fixture, eventName, requestId, expectedFields)
end

local expectedLoot = {
	{ lootNid = 1, itemId = 19019, itemLink = "item:19019", looterNid = 1, rollType = 1, rollValue = 98, bossNid = 1, source = "CHAT_MSG_LOOT" },
	{ lootNid = 2, itemId = 17182, itemLink = "item:17182", looterNid = 2, rollType = 2, rollValue = 87, bossNid = 1, source = "CHAT_MSG_LOOT" },
	{ lootNid = 3, itemId = 18832, itemLink = "item:18832", looterNid = 3, rollType = 3, rollValue = 76, bossNid = 1, source = "TRADE_ONLY" },
}

function cases.sync_notice_snapshot_round_trip_preserves_history_fields(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.debugEnabled = true
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Peer-Test Realm", rank = 0 },
	}
	fixture.snapshot = {
		header = {
			protocolVersion = 2,
			raidNid = 88,
			revision = 3,
			zone = "Naxxramas",
			size = 25,
			difficulty = 1,
		},
		players = {
			{ playerNid = 1, name = "DirectWinner" },
			{ playerNid = 2, name = "HoldWinner" },
			{ playerNid = 3, name = "TradeWinner" },
		},
		attendance = {},
		bosses = { { bossNid = 1, name = "Patchwerk" } },
		loot = deepCopy(expectedLoot),
	}
	fixture.snapshot.loot[1].itemName = parsedRowItemMarker

	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RV", 2, 88, "Naxxramas", 25, 1, 3 }, "\t"),
		"RAID",
		"Master-Test Realm"
	)
	local noticeTimer = assert(syncer._noticePullHandle, "revision notice did not schedule a pull")
	assertTrue(fixture:FireTimer(noticeTimer), "revision pull timer did not fire")
	local request = fixture.sent[#fixture.sent]
	assertEqual("WHISPER", request.channel, "history request must be targeted")
	assertEqual("Master-Test Realm", request.target, "history request targeted the wrong authority")
	local requestId = string.match(request.message, "^[^\t]+\t[^\t]+\t([^\t]+)")
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, requestId, "SYNC", 88, 1, 1, encodedWirePayloadMarker }, "\t"),
		"WHISPER",
		"Master-Test Realm"
	)

	local imported = assert(fixture.importedSnapshot, "authoritative snapshot was not imported")
	assertEqual(3, #imported.loot, "imported workflow row count differs")
	for i = 1, #expectedLoot do
		local expected = expectedLoot[i]
		local actual = imported.loot[i]
		assertEqual(expected.itemLink, actual.itemLink, "imported item differs")
		assertEqual(expected.looterNid, actual.looterNid, "imported winner reference differs")
		assertEqual(expected.rollType, actual.rollType, "imported roll type differs")
		assertEqual(expected.rollValue, actual.rollValue, "imported roll value differs")
	end
	assertEqual(1, fixture.imports, "history must import once")
	assertSingleImportOutcome(fixture, "IMPORT_APPLY", "generated-1", {
		mode = "SYNC",
		req = "generated-1",
		from = "master-test realm",
		localRaid = 41,
		sourceRaidNid = 88,
		revision = 3,
		loot = 3,
	})
	assertSingleSyncTrace(fixture, "REQUEST_END", "generated-1", {
		mode = "SYNC",
		req = "generated-1",
		reason = "complete",
	})
	for i = 1, #fixture.debugMessages do
		assertTrue(
			not string.find(fixture.debugMessages[i], encodedWirePayloadMarker, 1, true),
			"sync diagnostics exposed encoded payload contents"
		)
		assertTrue(
			not string.find(fixture.debugMessages[i], parsedRowItemMarker, 1, true),
			"sync diagnostics exposed parsed row contents"
		)
	end

	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RV", 2, 88, "Naxxramas", 25, 1, 3 }, "\t"),
		"RAID",
		"Master-Test Realm"
	)
	assertEqual(nil, syncer._noticePullHandle, "equal revision scheduled a duplicate pull")
	assertEqual(1, fixture.imports, "equal revision duplicated history")
	print("PASS sync_notice_snapshot_round_trip_preserves_history_fields")
end

function cases.sync_lineage_gates_incremental_delta(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.debugEnabled = true
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	fixture.snapshot = {
		header = {
			protocolVersion = 2,
			raidNid = 88,
			revision = 4,
			zone = "Naxxramas",
			size = 25,
			difficulty = 1,
		},
		players = {}, attendance = {}, bosses = {}, loot = {},
	}
	local function sinceRevision(message)
		local fields = {}
		for field in string.gmatch(message .. "\t", "(.-)\t") do fields[#fields + 1] = field end
		return tonumber(fields[9])
	end
	assertTrue(syncer:RequestLoggerSync(), "initial full bootstrap request must queue")
	assertEqual(0, sinceRevision(fixture.sent[#fixture.sent].message), "unbootstrapped sync must request a full snapshot")
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "generated-1", "SYNC", 88, 1, 1, "snapshot" }, "\t"),
		"RAID",
		"Leader-Test Realm"
	)
	assertEqual(1, fixture.imports, "authorized source snapshot must bootstrap local history")
	local lineage = assert(syncer._syncLineage[41], "successful bootstrap must record runtime lineage")
	assertEqual("leader-test realm", lineage.authorityName, "lineage authority name differs")
	assertEqual(88, lineage.sourceRaidNid, "lineage source raid differs")
	assertEqual(4, lineage.sourceRevision, "lineage source revision differs")

	syncer._terminalRequests["generated-1"] = nil
	fixture.sent = {}
	assertTrue(syncer:RequestLoggerSync(), "lineaged incremental request must queue")
	assertEqual(4, sinceRevision(fixture.sent[#fixture.sent].message), "matching lineage must request from local revision")
	local pending = assert(syncer._pendingRequests["generated-2"])
	assertEqual(88, pending.sourceRaidNid, "incremental request did not correlate source raid")
	syncer._pendingRequests["generated-2"] = nil
	syncer._terminalRequests["generated-2"] = nil

	fixture.delta = {
		header = { protocolVersion = 2, raidNid = 88, sinceRevision = 4, revision = 5 },
		loot = {},
	}
	local function receiveDelta(requestId, sender, sourceRaidNid)
		syncer._pendingRequests[requestId] = {
			createdAt = fixture.now,
			mode = "SYNC",
			sourceRaidNid = 88,
			signature = { sinceRevision = 4 },
			failedSenders = {},
			completed = false,
		}
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "DL", 2, requestId, "SYNC", sourceRaidNid, 1, 1, "delta-v2" }, "\t"),
			"RAID",
			sender
		)
	end

	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 0 },
		{ name = "NewLeader-Test Realm", rank = 2 },
	}
	receiveDelta("authority-drift", "NewLeader-Test Realm", 88)
	assertEqual(0, fixture.deltaParses, "authority drift must reject delta before parsing")
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	receiveDelta("source-drift", "Leader-Test Realm", 99)
	assertEqual(0, fixture.deltaParses, "source-id drift must reject delta before parsing")
	fixture.localRevision = 6
	receiveDelta("revision-drift", "Leader-Test Realm", 88)
	assertEqual(0, fixture.deltaParses, "local revision drift must reject delta before parsing")
	fixture.localRevision = 4
	receiveDelta("matching-lineage", "Leader-Test Realm", 88)
	assertEqual(1, fixture.deltaParses, "matching lineage must parse delta exactly once")
	assertEqual(1, fixture.deltaImports, "matching lineage must apply delta exactly once")
	assertEqual(5, syncer._syncLineage[41].sourceRevision, "successful delta must advance lineage revision")
	assertSingleImportOutcome(fixture, "IMPORT_APPLY", "matching-lineage", {
		mode = "SYNC",
		req = "matching-lineage",
		from = "leader-test realm",
		localRaid = 41,
		sourceRaidNid = 88,
		revision = 5,
		loot = 0,
	})
	assertSingleSyncTrace(fixture, "REQUEST_END", "matching-lineage", {
		mode = "SYNC",
		req = "matching-lineage",
		reason = "complete",
	})

	syncer._syncLineage = {}
	fixture.sent = {}
	assertTrue(syncer:RequestLoggerSync(), "reload-shaped missing lineage request must queue")
	assertEqual(0, sinceRevision(fixture.sent[#fixture.sent].message), "missing runtime lineage must force full snapshot")
	print("PASS sync_lineage_gates_incremental_delta")
end

function cases.sync_committed_history_revision_emits_notice_once(addon)
	local fixture = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.localMasterLooter = true
	fixture.localRevision = 0

	assertEqual(0, #fixture.sent, "uncommitted history emitted a notice")
	fixture.localRevision = 7
	fixture:TriggerRaidLootUpdate(41, { lootNid = 12 })

	assertEqual(1, #fixture.sent, "committed history must emit one notice")
	assertEqual("RAID", fixture.sent[1].channel, "revision notice must use group transport")
	assertEqual(
		table.concat({ "RV", 2, 41, "Naxxramas", 25, 1, 7 }, "\t"),
		fixture.sent[1].message,
		"revision notice payload differs"
	)

	fixture:TriggerRaidLootUpdate(41, { lootNid = 12 })
	assertEqual(1, #fixture.sent, "equal revision must not emit twice")

	fixture.options.persistentSync = false
	fixture.localRevision = 8
	fixture:TriggerRaidLootUpdate(41, { lootNid = 13 })
	assertEqual(1, #fixture.sent, "disabled persistent sync emitted a notice")
	print("PASS sync_committed_history_revision_emits_notice_once")
end

function cases.sync_diagnostics_are_debug_gated(addon)
	local fixture = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.localMasterLooter = true
	fixture.localRevision = 1
	fixture:TriggerRaidLootUpdate(41, { lootNid = 1 })
	assertEqual(0, #fixture.debugMessages, "disabled debug emitted sync diagnostics")
	print("PASS sync_diagnostics_are_debug_gated")
end

function cases.sync_diagnostics_trace_revision_pull(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.debugEnabled = true
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RV", 2, 88, "Naxxramas", 25, 1, 3 }, "\t"),
		"RAID",
		"Master-Test Realm"
	)
	assertTrue(fixture:HasDebug("event=RV_RECV"), "missing revision receive trace")
	assertTrue(fixture:HasDebug("event=RV_ACCEPT"), "missing revision acceptance trace")
	assertTrue(fixture:HasDebug("event=PULL_SCHEDULE"), "missing pull schedule trace")
	assertEqual(nil, syncer._pendingNotice.revision, "diagnostic revision must not persist in pending pull state")
	local acceptIndex, scheduleIndex
	for i = 1, #fixture.debugMessages do
		if string.find(fixture.debugMessages[i], "event=RV_ACCEPT", 1, true) then acceptIndex = i end
		if string.find(fixture.debugMessages[i], "event=PULL_SCHEDULE", 1, true) then scheduleIndex = i end
	end
	assertTrue(acceptIndex < scheduleIndex, "revision acceptance must precede pull scheduling")
	assertTrue(fixture:FireTimer(syncer._noticePullHandle), "notice pull did not fire")
	assertTrue(fixture:HasDebug("event=PULL_FIRE"), "missing pull fire trace")
	assertTrue(fixture:HasDebug("event=RQ_SEND"), "missing targeted request trace")
	assertTrue(fixture:HasDebug("req=generated-1"), "request trace lacks correlation ID")
	print("PASS sync_diagnostics_trace_revision_pull")
end

function cases.sync_diagnostics_trace_request_response_boundaries(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.debugEnabled = true
	fixture.roster = {
		{ name = "Tester-Test Realm", rank = 2 },
		{ name = "Requester-Test Realm", rank = 0 },
	}

	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RQ", 2, "snapshot-response", "REQ", 41, "", 0, 0, 0, 0 }, "\t"),
		"WHISPER",
		"Requester-Test Realm"
	)
	assertSingleSyncTrace(fixture, "RQ_RECV", "snapshot-response", {
		mode = "REQ", from = "Requester-Test Realm", raidRef = 41, channel = "WHISPER",
	})
	assertSingleSyncTrace(fixture, "RQ_ACCEPT", "snapshot-response", { mode = "REQ" })
	assertSingleSyncTrace(fixture, "SN_SEND", "snapshot-response", {
		mode = "REQ", target = "Requester-Test Realm", raidNid = 41, queued = "true",
	})
	assertEqual(0, #fixture:GetSyncTraces("DL_SEND", "snapshot-response"), "snapshot response emitted a delta outcome")

	fixture.lootMethod = "master"
	fixture.localMasterLooter = true
	addon.DB.Syncer._Payload.BuildDelta = function() return "delta", 1 end
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RQ", 2, "delta-response", "SYNC", 41, "Naxxramas", 25, 1, 3, 0 }, "\t"),
		"RAID",
		"Requester-Test Realm"
	)
	assertSingleSyncTrace(fixture, "RQ_RECV", "delta-response", { mode = "SYNC", channel = "RAID" })
	assertSingleSyncTrace(fixture, "DL_SEND", "delta-response", {
		mode = "SYNC", target = "Requester-Test Realm", raidNid = 41, queued = "true",
	})
	assertEqual(0, #fixture:GetSyncTraces("SN_SEND", "delta-response"), "successful delta response fell back to snapshot")

	addon.DB.Syncer._Payload.BuildDelta = function() return nil end
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RQ", 2, "fallback-response", "SYNC", 41, "Naxxramas", 25, 1, 3, 0 }, "\t"),
		"RAID",
		"Requester-Test Realm"
	)
	assertSingleSyncTrace(fixture, "SN_SEND", "fallback-response", { queued = "true" })
	assertEqual(0, #fixture:GetSyncTraces("DL_SEND", "fallback-response"), "unavailable delta emitted a transport outcome")

	fixture.failSingle = true
	local pendingVisibleAtFailure = false
	fixture.debugHook = function(message)
		if string.find(message, "event=RQ_SEND", 1, true) and string.find(message, "queued=false", 1, true) then
			for _ in pairs(syncer._pendingRequests) do pendingVisibleAtFailure = true end
		end
	end
	local queued = syncer:RequestLoggerPersistentSync()
	assertEqual(false, queued, "backpressured automatic request must fail")
	assertTrue(pendingVisibleAtFailure, "automatic send failure must trace before pending rollback")
	assertSingleSyncTrace(fixture, "RQ_SEND", "generated-1", {
		mode = "SYNC", queued = "false", reason = "backpressure",
	})
	assertEqual(nil, syncer._pendingRequests["generated-1"], "automatic send failure must still roll back pending state")
	print("PASS sync_diagnostics_trace_request_response_boundaries")
end

function cases.sync_diagnostics_attribute_admission_reasons(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.debugEnabled = true
	fixture.roster = {
		{ name = "Tester-Test Realm", rank = 0 },
		{ name = "Requester-Test Realm", rank = 0 },
	}
	fixture.lootMethod = "master"
	fixture.localMasterLooter = true

	local function request(requestId, mode, channel)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "RQ", 2, requestId, mode, 41, "Naxxramas", 25, 1, 0, 0 }, "\t"),
			channel,
			"Requester-Test Realm"
		)
	end
	request("unsupported-channel", "SYNC", "GUILD")
	assertSingleSyncTrace(fixture, "RQ_REJECT", "unsupported-channel", { reason = "channel_not_supported" })
	fixture.roster[1].rank = 2
	request("preserved-manual-channel", "REQ", "GUILD")
	assertSingleSyncTrace(fixture, "RQ_ACCEPT", "preserved-manual-channel", { mode = "REQ" })
	assertSingleSyncTrace(fixture, "SN_SEND", "preserved-manual-channel", { queued = "true" })
	fixture.roster[1].rank = 0
	request("local-no-capability", "REQ", "RAID")
	assertSingleSyncTrace(fixture, "RQ_REJECT", "local-no-capability", { reason = "responder_not_authority" })
	print("PASS sync_diagnostics_attribute_admission_reasons")
end

function cases.sync_diagnostics_trace_manual_admission(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.debugEnabled = true
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 2 },
		{ name = "Requester-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}

	local sendsBefore = #fixture.sent
	assertTrue(syncer:RequestLoggerReq(41, "Leader-Test Realm"), "manual Require must queue")
	assertEqual(sendsBefore + 1, #fixture.sent, "Require trace changed the send count")
	assertTrue(fixture:HasDebug("event=RQ_SEND mode=REQ"), "Require send trace missing")
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "generated-1", "REQ", 41, 1, 1, "snapshot" }, "\t"),
		"WHISPER",
		"Leader-Test Realm"
	)
	assertSingleImportOutcome(fixture, "IMPORT_APPLY", "generated-1", {
		mode = "REQ",
		req = "generated-1",
		from = "leader-test realm",
		localRaid = 1,
		sourceRaidNid = 41,
		revision = 0,
		loot = 0,
	})
	assertSingleSyncTrace(fixture, "REQUEST_END", "generated-1", {
		mode = "REQ",
		req = "generated-1",
		reason = "complete",
	})

	sendsBefore = #fixture.sent
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RQ", 2, "incoming-valid", "REQ", 41, "", 0, 0, 0, 0 }, "\t"),
		"WHISPER",
		"Requester-Test Realm"
	)
	assertEqual(sendsBefore + 1, #fixture.sent, "accepted Require trace changed the response count")
	assertTrue(fixture:HasDebug("event=RQ_ACCEPT mode=REQ"), "Require acceptance trace missing")

	local resolveRaid = addon.DB.Syncer._Import.ResolveRaidByReference
	addon.DB.Syncer._Import.ResolveRaidByReference = function() return nil end
	sendsBefore = #fixture.sent
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RQ", 2, "incoming-missing", "REQ", 999, "", 0, 0, 0, 0 }, "\t"),
		"WHISPER",
		"Requester-Test Realm"
	)
	addon.DB.Syncer._Import.ResolveRaidByReference = resolveRaid
	assertEqual(sendsBefore, #fixture.sent, "rejected Require trace changed the send count")
	assertTrue(fixture:HasDebug("event=RQ_REJECT"), "Require rejection trace missing")
	assertTrue(fixture:HasDebug("reason=raid_not_found"), "Require lookup reason missing")

	local importsBefore = fixture.imports
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "push-rejected", "PUSH", 41, 1, 1, "snapshot" }, "\t"),
		"WHISPER",
		"Leader-Test Realm"
	)
	assertEqual(importsBefore, fixture.imports, "rejected Push trace changed the import count")
	assertTrue(fixture:HasDebug("event=PUSH_REJECT"), "Push rejection trace missing")
	assertTrue(fixture:HasDebug("reason=no_push_consent"), "Push consent reason missing")

	fixture.options.syncRequirePlayer = "Leader-Test Realm"
	importsBefore = fixture.imports
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "push-accepted", "PUSH", 41, 1, 1, "snapshot" }, "\t"),
		"WHISPER",
		"Leader-Test Realm"
	)
	assertEqual(importsBefore + 1, fixture.imports, "accepted Push trace changed the import count")
	assertTrue(fixture:HasDebug("event=PUSH_ACCEPT"), "Push acceptance trace missing")
	assertTrue(fixture:HasDebug("consent=configured"), "Push acceptance consent missing")
	assertSingleImportOutcome(fixture, "IMPORT_APPLY", "push-accepted", {
		mode = "PUSH",
		req = "push-accepted",
		from = "leader-test realm",
		localRaid = 2,
		sourceRaidNid = 41,
		revision = 0,
		loot = 0,
	})
	assertEqual(0, #fixture:GetSyncTraces("REQUEST_END", "push-accepted"), "configured Push emitted a request terminal trace")
	print("PASS sync_diagnostics_trace_manual_admission")
end

function cases.sync_diagnostics_trace_push_admission_cardinality(addon)
	local capacityFixture, capacitySyncer = installRealDbSyncerFixture(addon)
	capacityFixture.debugEnabled = true
	capacityFixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	capacityFixture.options.syncRequirePlayer = "Leader-Test Realm"
	for i = 1, 64 do
		capacitySyncer._incoming["capacity-" .. tostring(i)] = {
			createdAt = capacityFixture.now,
			sender = "Capacity" .. tostring(i) .. "-Test Realm",
		}
	end
	capacitySyncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "capacity-refused", "PUSH", 41, 1, 2, "snap" }, "\t"),
		"WHISPER",
		"Leader-Test Realm"
	)
	assertEqual(0, capacityFixture:CountDebug("event=PUSH_ACCEPT"), "capacity refusal must not trace Push acceptance")
	assertSingleSyncTrace(capacityFixture, "PUSH_REJECT", "capacity-refused", { reason = "incoming_capacity" })
	assertEqual(0, capacityFixture.imports, "capacity refusal must not import")

	local admittedFixture, admittedSyncer = installRealDbSyncerFixture(addon)
	admittedFixture.debugEnabled = true
	admittedFixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	admittedFixture.options.syncRequirePlayer = "Leader-Test Realm"
	local function admittedPart(partIndex, payload)
		admittedSyncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "SN", 2, "admitted-multipart", "PUSH", 41, partIndex, 2, payload }, "\t"),
			"WHISPER",
			"Leader-Test Realm"
		)
	end
	admittedPart(1, "snap")
	admittedPart(2, "shot")
	assertEqual(1, admittedFixture:CountDebug("event=PUSH_ACCEPT"), "admitted multipart Push must trace acceptance once")
	assertEqual(1, admittedFixture.imports, "admitted multipart Push must import once")

	local rejectedFixture, rejectedSyncer = installRealDbSyncerFixture(addon)
	rejectedFixture.debugEnabled = true
	rejectedFixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	local function rejectedPart(partIndex)
		rejectedSyncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "SN", 2, "rejected-multipart", "PUSH", 41, partIndex, 2, "part" }, "\t"),
			"WHISPER",
			"Leader-Test Realm"
		)
	end
	rejectedPart(1)
	rejectedPart(2)
	assertEqual(1, rejectedFixture:CountDebug("event=PUSH_REJECT"), "rejected multipart Push must trace rejection once")
	assertEqual(0, rejectedFixture.imports, "rejected multipart Push must not import")
	print("PASS sync_diagnostics_trace_push_admission_cardinality")
end

function cases.sync_revision_notice_targets_master_and_coalesces(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}
	fixture.localRevision = 4
	syncer._syncLineage[41] = {
		authorityName = "master-test realm",
		sourceRaidNid = 88,
		sourceRevision = 4,
	}

	local function revisionNotice(revision)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "RV", 2, 88, "Naxxramas", 25, 1, revision }, "\t"),
			"RAID",
			"Master-Test Realm"
		)
	end

	revisionNotice(5)
	revisionNotice(7)
	assertEqual(1, #fixture.timers, "coalesced notices must allocate one timer")
	assertEqual(0.25, fixture.timers[1].delay, "revision pull delay differs")
	assertEqual(0, #fixture.sent, "notice must not request before the coalescing timer fires")

	assertTrue(fixture:FireTimer(fixture.timers[1]), "revision pull timer must fire")
	assertEqual(nil, syncer._noticePullHandle, "fired notice must clear its timer handle")
	assertEqual(nil, syncer._pendingNotice, "fired notice must clear pending notice state")
	assertEqual(1, #fixture.sent, "coalesced notices must send one request")
	assertEqual("WHISPER", fixture.sent[1].channel, "revision pull must use private transport")
	assertEqual("Master-Test Realm", fixture.sent[1].target, "revision pull must target the master looter")
	local fields = {}
	for field in string.gmatch(fixture.sent[1].message .. "\t", "(.-)\t") do
		fields[#fields + 1] = field
	end
	assertEqual("RQ", fields[1], "revision pull message kind differs")
	assertEqual("SYNC", fields[4], "revision pull request mode differs")
	assertEqual(88, syncer._pendingRequests["generated-1"].sourceRaidNid, "advertised source raid must be correlated")
	assertEqual("Master-Test Realm", syncer._pendingRequests["generated-1"].target, "pending request target differs")
	print("PASS sync_revision_notice_targets_master_and_coalesces")
end

function cases.sync_revision_notice_different_lineage_preserves_pending_pull(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.lootAuthority = "FirstMaster-Test Realm"
	fixture.roster = {
		{ name = "FirstMaster-Test Realm", rank = 0 },
		{ name = "SecondMaster-Test Realm", rank = 0 },
	}

	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RV", 2, 88, "Naxxramas", 25, 1, 5 }, "\t"),
		"RAID",
		"FirstMaster-Test Realm"
	)
	local firstNotice = assert(syncer._pendingNotice, "first valid notice must become pending")

	fixture.lootAuthority = "SecondMaster-Test Realm"
	fixture.currentRaid = { raidNid = 42, zone = "Ulduar", size = 10, difficulty = 2 }
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RV", 2, 99, "Ulduar", 10, 2, 9 }, "\t"),
		"RAID",
		"SecondMaster-Test Realm"
	)

	assertTrue(rawequal(firstNotice, syncer._pendingNotice), "different lineage must preserve pending notice identity")
	assertEqual("FirstMaster-Test Realm", syncer._pendingNotice.sender, "different authority replaced pending sender")
	assertEqual(88, syncer._pendingNotice.sourceRaidNid, "different lineage replaced pending source raid")
	assertEqual("Naxxramas", syncer._pendingNotice.signature.zone, "different signature replaced pending signature")
	assertEqual(1, #fixture.timers, "different lineage must not allocate another timer")

	assertTrue(fixture:FireTimer(fixture.timers[1]), "original notice timer must fire")
	assertEqual(0, #fixture.sent, "stale preserved notice must not request the former authority")
	assertEqual(nil, syncer._noticePullHandle, "stale preserved notice must clear its timer")
	assertEqual(nil, syncer._pendingNotice, "stale preserved notice must clear pending state")
	print("PASS sync_revision_notice_different_lineage_preserves_pending_pull")
end

function cases.sync_revision_notice_rejects_stale_mismatch_and_non_master(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.debugEnabled = true
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Member-Test Realm", rank = 0 },
	}
	fixture.localRevision = 7
	syncer._syncLineage[41] = {
		authorityName = "master-test realm",
		sourceRaidNid = 88,
		sourceRevision = 7,
	}

	local function revisionNotice(sender, sourceRaidNid, zone, size, diff, revision)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "RV", 2, sourceRaidNid, zone, size, diff, revision }, "\t"),
			"RAID",
			sender
		)
	end

	revisionNotice("Member-Test Realm", 88, "Naxxramas", 25, 1, 8)
	assertEqual(1, #fixture.warnings, "non-master notice must warn once")
	assertEqual(
		"[Sync] Ignored history revision from non-master sender=Member-Test Realm",
		fixture.warnings[1],
		"non-master notice warning differs"
	)
	assertEqual(0, #fixture.timers, "non-master notice must schedule nothing")
	revisionNotice("Master-Test Realm", 88, "Ulduar", 25, 1, 8)
	assertEqual(0, #fixture.timers, "signature mismatch must schedule nothing")
	revisionNotice("Master-Test Realm", 88, "Naxxramas", 25, 1, 7)
	assertEqual(0, #fixture.timers, "stale notice must schedule nothing")
	assertEqual(7, fixture.localRevision, "notice handling must not mutate local revision")
	assertEqual(0, fixture.imports, "notice handling must not import a snapshot")
	assertEqual(0, fixture.deltaImports, "notice handling must not import a delta")
	assertEqual(0, #fixture.sent, "rejected notices must not send a request")
	local rejects = fixture:GetSyncTraces("RV_REJECT")
	assertEqual(3, #rejects, "revision rejection trace count differs")
	for i = 1, #rejects do
		assertEqual("88", rejects[i].fields.sourceRaidNid, "revision rejection lacks source raid NID")
		assertTrue(rejects[i].fields.revision == "8" or rejects[i].fields.revision == "7", "revision rejection lacks revision")
	end
	print("PASS sync_revision_notice_rejects_stale_mismatch_and_non_master")
end

function cases.sync_late_join_targets_current_master_after_roster_identity(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}
	fixture.currentRaid = {
		raidNid = 41, zone = "Naxxramas", size = 25, difficulty = 1, startTime = 100,
	}
	fixture.snapshot = {
		header = {
			protocolVersion = 2, raidNid = 88, revision = 4,
			zone = "Naxxramas", size = 25, difficulty = 1,
		},
		players = {}, attendance = {}, bosses = {}, loot = {},
	}

	local onRosterDelta = assert(fixture.callbacks.ROSTER_DELTA, "roster callback must be bound")
	local onRaidCreate = assert(fixture.callbacks.CREATE, "raid-create callback must be bound")
	local onOptionsLoaded = assert(fixture.callbacks.OPTIONS, "options callback must be bound")
	local onZoneChanged = assert(
		fixture.callbacks["wow.ZONE_CHANGED_NEW_AREA"],
		"forwarded zone callback must be bound"
	)

	onRosterDelta()
	onRaidCreate()
	onOptionsLoaded()
	onZoneChanged()
	local authorityPull = assert(syncer._noticePullHandle, "late join must schedule one authority pull")
	assertEqual(0.25, authorityPull.delay, "late-join pull must use the notice coalescing delay")
	assertEqual("Master-Test Realm", syncer._pendingNotice.sender, "late-join pull target differs")
	assertEqual(nil, syncer._pendingNotice.sourceRaidNid, "late-join pull must not invent source lineage")
	assertEqual(0, fixture.imports, "scheduling a recovery pull must not mutate history")

	fixture.currentRaid = {
		raidNid = 41, zone = "Naxxramas", size = 25, difficulty = 1, startTime = 900,
	}
	onRosterDelta()
	assertTrue(rawequal(authorityPull, syncer._noticePullHandle), "local login time split the recovery context")
	assertTrue(fixture:FireTimer(authorityPull), "late-join pull timer must fire")
	assertEqual(1, #fixture.sent, "coalesced recovery callbacks must send one request")
	assertEqual("WHISPER", fixture.sent[1].channel, "late-join pull must use private transport")
	assertEqual("Master-Test Realm", fixture.sent[1].target, "late-join pull must target the current master")
	assertEqual(0, syncer._pendingRequests["generated-1"].signature.sinceRevision, "missing lineage must request a full snapshot")

	onRosterDelta()
	assertEqual(nil, syncer._noticePullHandle, "same recovered raid/master/signature scheduled another pull")
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "generated-1", "SYNC", 88, 1, 1, "snapshot" }, "\t"),
		"WHISPER",
		"Master-Test Realm"
	)
	assertEqual(1, fixture.imports, "authoritative snapshot must be the only history mutation")
	assertEqual(0, fixture.deltaImports, "late-join recovery unexpectedly applied a delta")
	print("PASS sync_late_join_targets_current_master_after_roster_identity")
end

function cases.sync_targeted_timeout_retries_once(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}

	local onRosterDelta = assert(fixture.callbacks.ROSTER_DELTA, "roster callback must be bound")
	onRosterDelta()
	assertTrue(fixture:FireTimer(syncer._noticePullHandle), "targeted automatic pull must start")
	local first = assert(syncer._pendingRequests["generated-1"], "first targeted request must be pending")
	assertEqual(0, first.retryCount, "initial targeted request retry count differs")
	assertTrue(fixture:FireTimer(first.timeoutHandle), "first targeted timeout must fire")
	assertEqual(2, #fixture.sent, "first timeout must queue exactly one retry")
	local retry = assert(syncer._pendingRequests["generated-2"], "targeted retry must be pending")
	assertEqual(1, retry.retryCount, "targeted retry count differs")
	assertEqual("Master-Test Realm", retry.target, "targeted retry changed authority")
	assertTrue(fixture:FireTimer(retry.timeoutHandle), "second targeted timeout must fire")
	assertEqual(2, #fixture.sent, "second timeout must not queue a third request")
	assertEqual(nil, syncer._pendingRequests["generated-3"], "third targeted request unexpectedly exists")
	assertEqual(0, fixture:FireTimers(), "bounded retry must leave no active retry timer")
	print("PASS sync_targeted_timeout_retries_once")
end

function cases.sync_pending_authority_pull_stops_when_persistent_sync_disables(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}

	local onRosterDelta = assert(fixture.callbacks.ROSTER_DELTA, "roster callback must be bound")
	local onPersistentSync = assert(
		fixture.callbacks.OPTION_persistentSync,
		"persistent-sync option callback must be bound"
	)
	onRosterDelta()
	local cancelledHandle = assert(syncer._noticePullHandle, "recovery pull must be pending")
	fixture.options.persistentSync = false
	onPersistentSync()
	assertEqual(nil, syncer._noticePullHandle, "disable must clear the pending notice handle")
	assertEqual(nil, syncer._pendingNotice, "disable must clear pending notice state")
	assertEqual(false, cancelledHandle.active, "disable must cancel the pending notice timer")
	assertEqual(false, fixture:FireTimer(cancelledHandle), "cancelled notice timer must not fire")
	assertEqual(0, #fixture.sent, "disable must not send a pending authority request")

	local raceFixture, raceSyncer = installRealDbSyncerFixture(addon)
	raceFixture.lootMethod = "master"
	raceFixture.lootAuthority = "Master-Test Realm"
	raceFixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}
	assert(raceFixture.callbacks.ROSTER_DELTA)()
	local raceHandle = assert(raceSyncer._noticePullHandle, "race recovery pull must be pending")
	raceFixture.options.persistentSync = false
	assertTrue(raceFixture:FireTimer(raceHandle), "race notice callback must execute")
	assertEqual(0, #raceFixture.sent, "timer must revalidate disabled persistent sync")
	assertEqual(nil, raceSyncer._noticePullHandle, "race callback must clear notice handle")
	assertEqual(nil, raceSyncer._pendingNotice, "race callback must clear pending notice state")
	print("PASS sync_pending_authority_pull_stops_when_persistent_sync_disables")
end

local function installPersistentSyncDisableFixture(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}
	fixture.snapshot = {
		header = {
			protocolVersion = 2,
			raidNid = 88,
			revision = 3,
			zone = "Naxxramas",
			size = 25,
			difficulty = 1,
		},
		players = {},
		attendance = {},
		bosses = {},
		loot = {},
	}
	return fixture, syncer
end

local function startAutomaticSyncRequest(fixture, syncer)
	local onRosterDelta = assert(fixture.callbacks.ROSTER_DELTA, "roster callback must be bound")
	onRosterDelta()
	assertTrue(fixture:FireTimer(syncer._noticePullHandle), "automatic pull must start")
	local request = fixture.sent[#fixture.sent]
	return assert(string.match(request.message, "^[^\t]+\t[^\t]+\t([^\t]+)"), "request id missing")
end

local function disablePersistentSync(fixture)
	fixture.options.persistentSync = false
	local onPersistentSync = assert(
		fixture.callbacks.OPTION_persistentSync,
		"persistent-sync option callback must be bound"
	)
	onPersistentSync()
end

local function deliverSyncSnapshot(syncer, requestId)
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, requestId, "SYNC", 88, 1, 1, "snapshot" }, "\t"),
		"WHISPER",
		"Master-Test Realm"
	)
end

function cases.sync_disable_cancels_automatic_request_without_retry(addon)
	local fixture, syncer = installPersistentSyncDisableFixture(addon)
	local requestId = startAutomaticSyncRequest(fixture, syncer)
	local pending = assert(syncer._pendingRequests[requestId], "automatic request must be pending")
	local timeoutHandle = assert(pending.timeoutHandle, "automatic request timeout must exist")
	disablePersistentSync(fixture)

	assertEqual(nil, syncer._pendingRequests[requestId], "disable retained the automatic request")
	assertEqual(false, timeoutHandle.active, "disable retained the automatic timeout")
	assertEqual(false, fixture:FireTimer(timeoutHandle), "cancelled automatic timeout fired")
	assertEqual(1, #fixture.sent, "disable allowed an automatic retry")
	print("PASS sync_disable_cancels_automatic_request_without_retry")
end

function cases.sync_disable_rejects_late_automatic_response(addon)
	local fixture, syncer = installPersistentSyncDisableFixture(addon)
	local requestId = startAutomaticSyncRequest(fixture, syncer)
	disablePersistentSync(fixture)
	deliverSyncSnapshot(syncer, requestId)

	assertEqual(0, fixture.imports, "late automatic response imported after disable")
	assertEqual(nil, next(syncer._incoming), "late automatic response retained assembly state")
	print("PASS sync_disable_rejects_late_automatic_response")
end

function cases.sync_disable_preserves_manual_request_response(addon)
	local fixture, syncer = installPersistentSyncDisableFixture(addon)
	assertTrue(syncer:RequestLoggerSync(), "manual sync request must queue")
	local request = fixture.sent[#fixture.sent]
	local requestId = assert(
		string.match(request.message, "^[^\t]+\t[^\t]+\t([^\t]+)"),
		"manual request id missing"
	)
	disablePersistentSync(fixture)
	deliverSyncSnapshot(syncer, requestId)

	assertEqual(1, fixture.imports, "disable cancelled the manual request response")
	print("PASS sync_disable_preserves_manual_request_response")
end

function cases.sync_pending_authority_pull_retargets_changed_master(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.lootAuthority = "OldMaster-Test Realm"
	fixture.roster = {
		{ name = "OldMaster-Test Realm", rank = 0 },
		{ name = "NewMaster-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}
	local onRosterDelta = assert(fixture.callbacks.ROSTER_DELTA, "roster callback must be bound")
	onRosterDelta()
	local oldHandle = assert(syncer._noticePullHandle, "old-master pull must be pending")
	fixture.lootAuthority = "NewMaster-Test Realm"
	onRosterDelta()
	local newHandle = assert(syncer._noticePullHandle, "new-master pull must replace the old pull")
	assertTrue(not rawequal(oldHandle, newHandle), "master change retained the old notice timer")
	assertEqual(false, oldHandle.active, "master change must cancel the old notice timer")
	assertEqual("NewMaster-Test Realm", syncer._pendingNotice.sender, "replacement pull target differs")
	assertEqual(false, fixture:FireTimer(oldHandle), "cancelled old-master timer must not fire")
	assertTrue(fixture:FireTimer(newHandle), "new-master pull timer must fire")
	assertEqual(1, #fixture.sent, "master replacement must send one request")
	assertEqual("NewMaster-Test Realm", fixture.sent[1].target, "old master received the replacement request")

	local raceFixture, raceSyncer = installRealDbSyncerFixture(addon)
	raceFixture.lootMethod = "master"
	raceFixture.lootAuthority = "OldMaster-Test Realm"
	raceFixture.roster = fixture.roster
	local raceRosterDelta = assert(raceFixture.callbacks.ROSTER_DELTA, "race roster callback must be bound")
	raceRosterDelta()
	local raceHandle = assert(raceSyncer._noticePullHandle, "race old-master pull must be pending")
	raceFixture.lootAuthority = "NewMaster-Test Realm"
	assertTrue(raceFixture:FireTimer(raceHandle), "race old-master callback must execute")
	assertEqual(0, #raceFixture.sent, "timer must revalidate the current master")
	raceRosterDelta()
	assertTrue(raceFixture:FireTimer(raceSyncer._noticePullHandle), "current-master recovery must remain schedulable")
	assertEqual(1, #raceFixture.sent, "current-master recovery must send one request")
	assertEqual("NewMaster-Test Realm", raceFixture.sent[1].target, "race recovery targeted the old master")
	print("PASS sync_pending_authority_pull_retargets_changed_master")
end

function cases.sync_request_throw_preserves_persistent_schedule(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	local onOptionsLoaded = assert(fixture.callbacks.OPTIONS, "options callback must be bound")
	onOptionsLoaded()
	local initialHandle = assert(syncer._persistentSyncHandle, "initial persistent sync must be scheduled")
	syncer.RequestLoggerPersistentSync = function()
		error("simulated request failure")
	end
	local ok = pcall(fixture.FireTimer, fixture, initialHandle)
	assertEqual(false, ok, "fixture must surface the simulated request failure")
	local recurringHandle = assert(syncer._persistentSyncHandle, "request failure must preserve recurring sync")
	assertEqual(120, recurringHandle.delay, "request failure must restore the recurring interval")
	print("PASS sync_request_throw_preserves_persistent_schedule")
end

function cases.sync_multipart_authority_change_rejects_completed_payload(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = {
		{ name = "OldLeader-Test Realm", rank = 2 },
		{ name = "NewLeader-Test Realm", rank = 0 },
	}
	fixture.snapshot = {
		header = { protocolVersion = 2, raidNid = 88, revision = 5 },
		players = {}, attendance = {}, bosses = {}, loot = {},
	}
	syncer._pendingRequests["multipart-snapshot"] = {
		createdAt = fixture.now, mode = "SYNC", signature = { sinceRevision = 0 }, failedSenders = {}, completed = false,
	}
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "multipart-snapshot", "SYNC", 88, 1, 2, "snap" }, "\t"),
		"RAID",
		"OldLeader-Test Realm"
	)
	assertTrue(next(syncer._incoming) ~= nil, "first snapshot chunk must allocate under the old authority")
	fixture.roster[1].rank = 0
	fixture.roster[2].rank = 2
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "multipart-snapshot", "SYNC", 88, 2, 2, "shot" }, "\t"),
		"RAID",
		"OldLeader-Test Realm"
	)
	assertEqual(0, fixture.imports, "former authority must not import a completed multipart snapshot")
	assertEqual(nil, next(syncer._incoming), "rejected multipart snapshot must release assembly state")

	fixture.localRevision = 4
	fixture.delta = {
		header = { protocolVersion = 2, raidNid = 88, sinceRevision = 4, revision = 5 },
		loot = {},
	}
	syncer._syncLineage[41] = {
		authorityName = "oldleader-test realm", sourceRaidNid = 88, sourceRevision = 4,
	}
	fixture.roster[1].rank = 2
	fixture.roster[2].rank = 0
	syncer._pendingRequests["multipart-delta"] = {
		createdAt = fixture.now,
		mode = "SYNC",
		sourceRaidNid = 88,
		signature = { sinceRevision = 4 },
		failedSenders = {},
		completed = false,
	}
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "DL", 2, "multipart-delta", "SYNC", 88, 1, 2, "delta-" }, "\t"),
		"RAID",
		"OldLeader-Test Realm"
	)
	assertTrue(next(syncer._incoming) ~= nil, "first delta chunk must allocate under the old authority")
	fixture.roster[1].rank = 0
	fixture.roster[2].rank = 2
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "DL", 2, "multipart-delta", "SYNC", 88, 2, 2, "v2" }, "\t"),
		"RAID",
		"OldLeader-Test Realm"
	)
	assertEqual(0, fixture.deltaImports, "former authority must not import a completed multipart delta")
	assertEqual(nil, next(syncer._incoming), "rejected multipart delta must release assembly state")

	fixture.sent = {}
	assertTrue(syncer:RequestLoggerSync(), "authority change must allow a replacement bootstrap request")
	local requestFields = {}
	for field in string.gmatch(fixture.sent[#fixture.sent].message .. "\t", "(.-)\t") do
		requestFields[#requestFields + 1] = field
	end
	assertEqual(0, tonumber(requestFields[9]), "authority change must force the next full bootstrap")
	print("PASS sync_multipart_authority_change_rejects_completed_payload")
end

function cases.sync_multipart_bootstrap_rejects_replaced_local_raid(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	fixture.snapshot = {
		header = { protocolVersion = 2, raidNid = 88, revision = 5, zone = "Naxxramas", size = 25, difficulty = 1 },
		players = {}, attendance = {}, bosses = {}, loot = {},
	}
	assertTrue(syncer:RequestLoggerSync(), "bootstrap request must queue")
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "generated-1", "SYNC", 88, 1, 2, "snap" }, "\t"),
		"RAID",
		"Leader-Test Realm"
	)
	fixture.currentRaid = { raidNid = 42, zone = "Naxxramas", size = 25, difficulty = 1 }
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "generated-1", "SYNC", 88, 2, 2, "shot" }, "\t"),
		"RAID",
		"Leader-Test Realm"
	)
	assertEqual(0, fixture.imports, "snapshot for a replaced local raid must not import")
	assertTrue(syncer._pendingRequests["generated-1"].failedSenders["leader-test realm"],
		"replaced-raid completion must require a fresh responder/bootstrap")
	print("PASS sync_multipart_bootstrap_rejects_replaced_local_raid")
end

function cases.sync_multipart_bootstrap_rejects_signature_drift(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	fixture.snapshot = {
		header = { protocolVersion = 2, raidNid = 88, revision = 5, zone = "Naxxramas", size = 25, difficulty = 1 },
		players = {}, attendance = {}, bosses = {}, loot = {},
	}
	assertTrue(syncer:RequestLoggerSync(), "bootstrap request must queue")
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "generated-1", "SYNC", 88, 1, 2, "snap" }, "\t"),
		"RAID",
		"Leader-Test Realm"
	)
	fixture.currentRaid.zone = "Ulduar"
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "generated-1", "SYNC", 88, 2, 2, "shot" }, "\t"),
		"RAID",
		"Leader-Test Realm"
	)
	assertEqual(0, fixture.imports, "snapshot after live signature drift must not import")
	assertTrue(syncer._pendingRequests["generated-1"].failedSenders["leader-test realm"],
		"signature-drift completion must require a fresh responder/bootstrap")
	print("PASS sync_multipart_bootstrap_rejects_signature_drift")
end

function cases.sync_bootstrap_rejects_snapshot_header_signature_mismatch(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = { { name = "Leader-Test Realm", rank = 2 } }
	fixture.snapshot = {
		header = { protocolVersion = 2, raidNid = 88, revision = 5, zone = "Ulduar", size = 25, difficulty = 1 },
		players = {}, attendance = {}, bosses = {}, loot = {},
	}
	assertTrue(syncer:RequestLoggerSync(), "bootstrap request must queue")
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, "generated-1", "SYNC", 88, 1, 1, "snapshot" }, "\t"),
		"RAID",
		"Leader-Test Realm"
	)
	assertEqual(0, fixture.imports, "snapshot header for another instance must not import")
	assertTrue(syncer._pendingRequests["generated-1"].failedSenders["leader-test realm"],
		"header mismatch must require a fresh responder/bootstrap")
	print("PASS sync_bootstrap_rejects_snapshot_header_signature_mismatch")
end

function cases.sync_master_looter_is_authoritative_without_rank(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Assistant-Test Realm", rank = 1 },
		{ name = "Requester-Test Realm", rank = 0 },
	}
	local function pending(requestId)
		syncer._pendingRequests[requestId] = {
			createdAt = fixture.now, mode = "SYNC", failedSenders = {}, completed = false,
		}
	end
	local function partialSnapshot(requestId, sender)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "SN", 2, requestId, "SYNC", 41, 1, 2, "part" }, "\t"),
			"RAID",
			sender
		)
	end
	pending("master")
	partialSnapshot("master", "Master-Test Realm")
	assertTrue(next(syncer._incoming) ~= nil, "rank-zero master looter must be accepted as sync authority")
	syncer._incoming = {}
	pending("assistant")
	partialSnapshot("assistant", "Assistant-Test Realm")
	assertEqual(nil, next(syncer._incoming), "assistant must be rejected while master loot is active")

	fixture.sent = {}
	fixture.localMasterLooter = false
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RQ", 2, "not-local-master", "SYNC", 41, "Naxxramas", 25, 1, 0, 0 }, "\t"),
		"RAID",
		"Requester-Test Realm"
	)
	assertEqual(0, #fixture.sent, "non-master local client must not answer broadcast sync")
	fixture.localMasterLooter = true
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RQ", 2, "local-master", "SYNC", 41, "Naxxramas", 25, 1, 0, 0 }, "\t"),
		"RAID",
		"Requester-Test Realm"
	)
	assertTrue(#fixture.sent > 0, "local master looter must answer broadcast sync")
	print("PASS sync_master_looter_is_authoritative_without_rank")
end

function cases.sync_automatic_requests_allow_group_channels_only(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.inRaid = false
	fixture.lootMethod = "master"
	fixture.localMasterLooter = true
	fixture.groupUnits = { ["requester-test realm"] = "party1" }

	local function request(channel, requestId)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "RQ", 2, requestId, "SYNC", 41, "Naxxramas", 25, 1, 0, 0 }, "\t"),
			channel,
			"Requester-Test Realm"
		)
	end

	request("PARTY", "party-request")
	assertEqual(1, #fixture.sent, "party automatic request must receive history")
	fixture.sent = {}
	request("GUILD", "guild-request")
	assertEqual(0, #fixture.sent, "guild automatic request must receive no history")
	print("PASS sync_automatic_requests_allow_group_channels_only")
end

function cases.sync_party_authority_rejects_members_and_outsiders(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.inRaid = false
	fixture.groupUnits = {
		["master-test realm"] = "party1",
		["leader-test realm"] = "party2",
		["member-test realm"] = "party3",
	}
	fixture.unitRanks = { party1 = 0, party2 = 2, party3 = 0 }
	local function partialSnapshot(requestId, sender)
		syncer._pendingRequests[requestId] = {
			createdAt = fixture.now,
			mode = "SYNC",
			raidNid = 41,
			signature = { zone = "Naxxramas", size = 25, diff = 1, sinceRevision = 0 },
			failedSenders = {},
			completed = false,
		}
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "SN", 2, requestId, "SYNC", 88, 1, 2, "part" }, "\t"),
			"PARTY",
			sender
		)
		local accepted = next(syncer._incoming) ~= nil
		syncer._incoming = {}
		return accepted
	end

	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	assertTrue(partialSnapshot("party-master", "Master-Test Realm"), "party master looter must be authoritative")
	assertEqual(false, partialSnapshot("party-master-member", "Member-Test Realm"),
		"ordinary party member must not replace master-looter authority")
	assertEqual(false, partialSnapshot("party-master-outsider", "Outsider-Test Realm"),
		"party outsider must not replace master-looter authority")

	fixture.lootMethod = "group"
	assertTrue(partialSnapshot("party-leader", "Leader-Test Realm"), "party leader must be authoritative")
	assertEqual(false, partialSnapshot("party-member", "Member-Test Realm"),
		"ordinary party member must not be authoritative")
	assertEqual(false, partialSnapshot("party-outsider", "Outsider-Test Realm"),
		"party outsider must not be authoritative")

	local function requestSnapshot(requestId)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "RQ", 2, requestId, "SYNC", 41, "Naxxramas", 25, 1, 0, 0 }, "\t"),
			"PARTY",
			"Member-Test Realm"
		)
	end
	fixture.sent = {}
	fixture.lootMethod = "master"
	fixture.localMasterLooter = false
	requestSnapshot("party-local-member-master")
	assertEqual(0, #fixture.sent, "ordinary local party member must not answer under master loot")
	fixture.localMasterLooter = true
	requestSnapshot("party-local-master")
	assertTrue(#fixture.sent > 0, "local party master looter must answer sync requests")

	fixture.sent = {}
	fixture.lootMethod = "group"
	fixture.unitRanks.player = 0
	requestSnapshot("party-local-member")
	assertEqual(0, #fixture.sent, "ordinary local party member must not answer sync requests")
	fixture.unitRanks.player = 2
	requestSnapshot("party-local-leader")
	assertEqual(0, #fixture.sent, "local party leader must not answer automatic sync outside master loot")
	print("PASS sync_party_authority_rejects_members_and_outsiders")
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
	syncer._syncLineage[41] = {
		authorityName = "leader-test realm", sourceRaidNid = 41, sourceRevision = fixture.localRevision,
	}
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
		{ name = "Assistant-Other Realm", rank = 2 },
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
	local cancelRequestName = "Cancel" .. "Request"
	assertEqual(nil, syncer[cancelRequestName], "DBSyncer must not expose a test-only cancellation facade")
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

	pending("timeout", 42, "Assistant-Other Realm")
	snapshot("timeout", "REQ", 42, "Assistant-Other Realm")
	assertEqual(1, fixture.importAttempts, "terminal request ID must not be reused across context")
	assertEqual(3, callbackCount, "reused request ID must terminate replacement callback once")
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
	local callbackCount = 0
	assertEqual(true, syncer:RequestLoggerReq(41, "Leader-Test Realm"), "request must start")
	local pending = assert(syncer._pendingRequests["generated-1"], "generated request must be pending")
	pending.callback = function(reason)
		callbackCount = callbackCount + 1
		assertEqual("timeout", reason, "timer terminal reason differs")
		syncer:OnAddonMessage("RMALogSync", table.concat({
			"SN", 2, "generated-1", "REQ", 41, 1, 1, "snapshot",
		}, "\t"), "WHISPER", "Leader-Test Realm")
	end
	assertEqual(1, fixture:FireTimers(), "one request timeout must fire without inbound traffic")
	assertEqual(1, callbackCount, "timer timeout callback must run once")
	assertEqual(0, fixture:FireTimers(), "terminal timeout must leave no active timer")
	assertEqual(0, fixture.importAttempts, "reentrant completion attempt must observe terminal state")
	assertEqual(nil, syncer._pendingRequests["generated-1"], "timer timeout must release pending state")
	print("PASS sync_request_timeout_fires_without_inbound_traffic")
end

function cases.sync_request_cleanup_is_context_scoped(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 2 },
		{ name = "Assistant-Other Realm", rank = 1 },
	}
	fixture.options.syncRequirePlayer = "Leader-Test Realm"
	assertEqual(true, syncer:RequestLoggerReq(41, "Assistant-Other Realm"), "local colliding request must start")
	local pending = assert(syncer._pendingRequests["generated-1"], "local colliding request must be pending")
	syncer._incoming["local"] = {
		createdAt = fixture.now, requestId = "generated-1", mode = "REQ", raidNid = 41,
		sender = "assistant-other realm", requestContext = pending, total = 2, got = 1, parts = { "x" }, encodedBytes = 1,
	}
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"SN", 2, "generated-1", "PUSH", 41, 1, 2, "push",
	}, "\t"), "WHISPER", "Leader-Test Realm")
	local pushKey
	for key, state in pairs(syncer._incoming) do
		if state.mode == "PUSH" then pushKey = key end
	end
	assertTrue(pushKey ~= nil, "unrelated configured PUSH collision must allocate independently")
	fixture.now = fixture.now + 31
	fixture:FireTimers()
	assertEqual(nil, syncer._incoming["local"], "timeout must remove its local response assembly")
	assertTrue(syncer._incoming[pushKey] ~= nil, "timeout must preserve unrelated PUSH with the same wire ID")

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
			"SN", 2, "generated-1", "PUSH", 41, partIndex or 1, partCount or 1, payload or "snapshot",
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
		{ name = "Assistant-Other Realm", rank = 2 },
	}
	pending("leader")
	chunk("SN", "leader", "leader-test realm")
	assertEqual(1, countIncoming(), "case-insensitive exact leader must allocate chunk state")
	pending("assistant")
	chunk("SN", "assistant", "Assistant")
	assertEqual(2, countIncoming(), "unique short raid leader must allocate snapshot chunk state")

	pending("late-same")
	chunk("SN", "late-same", "Late-Other Realm")
	assertEqual(2, countIncoming(), "first roster-late chunk must remain allocation-free")
	fixture.roster[#fixture.roster + 1] = { name = "Late-Test Realm", rank = 2 }
	chunk("SN", "late-same", "Late-Other Realm")
	assertEqual(3, countIncoming(), "same request and chunk must re-evaluate after roster population")

	local sendsBefore = #fixture.sent
	request("outsider-rq", "Outsider-Test Realm")
	assertEqual(sendsBefore, #fixture.sent, "outsider whisper request must receive no history")
	fixture.roster[#fixture.roster + 1] = { name = "Requester-Test Realm", rank = 0 }
	fixture.lootMethod = "master"
	fixture.localMasterLooter = true
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
	fixture.lootMethod = "master"
	fixture.localMasterLooter = true
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

function cases.sync_snapshot_chunks_fit_wotlk_addon_message_limit(addon)
	local function assertResponseFits(requestId, label)
		local fixture, syncer = installRealDbSyncerFixture(addon)
		fixture.lootMethod = "master"
		fixture.localMasterLooter = true
		fixture.roster = { { name = "Requester-Test Realm", rank = 0 } }
		fixture.snapshotPayload = string.rep("x", 500)

		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "RQ", 2, requestId, "SYNC", 16, "Naxxramas", 25, 1, 0, 0 }, "\t"),
			"RAID",
			"Requester-Test Realm"
		)

		assertTrue(#fixture.sent > 1, label .. " must exercise a multi-chunk snapshot")
		for i = 1, #fixture.sent do
			local sent = fixture.sent[i]
			local wireBytes = #sent.prefix + 1 + #sent.message
			assertTrue(
				wireBytes <= 255,
				string.format("%s chunk %d exceeds 255-byte addon-message limit: %d", label, i, wireBytes)
			)
		end
	end

	assertResponseFits("225631087-17", "live request id")
	assertResponseFits(string.rep("r", 64), "maximum request id")
	print("PASS sync_snapshot_chunks_fit_wotlk_addon_message_limit")
end

local function installRealCommsQueueFixture(addon)
	local fixture = { sent = {}, timers = {}, nextTimer = 1 }
	_G.SendAddonMessage = function(prefix, message, channel, target)
		fixture.sent[#fixture.sent + 1] = {
			prefix = prefix,
			message = message,
			channel = channel,
			target = target,
		}
	end
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
		target.ScheduleTimer = function(_, callback, delay)
			local timer = { callback = callback, delay = delay }
			fixture.timers[#fixture.timers + 1] = timer
			return timer
		end
	end }
	loadAddonFile(addon, "Raid Management Addon/Modules/Comms.lua")

	function fixture:FireNextTimer()
		local timer = self.timers[self.nextTimer]
		assertTrue(timer ~= nil, "expected another queue timer")
		self.nextTimer = self.nextTimer + 1
		timer.callback()
		return timer.delay
	end

	function fixture:Drain(expectedMessages)
		local startSent = #self.sent
		local elapsed = 0
		while #self.sent - startSent < expectedMessages do
			local before = #self.sent
			elapsed = elapsed + self:FireNextTimer()
			assertEqual(before + 1, #self.sent, "queue timer must send exactly one message")
		end
		return elapsed
	end

	return fixture
end

function cases.comms_queue_uses_constant_single_message_pacing(addon)
	local fixture = installRealCommsQueueFixture(addon)
	assertTrue(addon.Comms.QueueAddonMessages("RMA", { "one", "two", "three" }, "RAID"), "batch enqueue failed")
	for expected = 1, 3 do
		local delay = fixture:FireNextTimer()
		assertEqual(0.10, delay, "queue delay differs")
		assertEqual(expected, #fixture.sent, "each timer must send exactly one message")
	end
	assertEqual(3, fixture.nextTimer - 1, "drain scheduled an extra timer")
	print("PASS comms_queue_uses_constant_single_message_pacing")
end

function cases.sync_representative_payloads_meet_latency_budget(addon)
	local syncFixture, syncer = installRealDbSyncerFixture(addon)
	addon.Base64 = {}
	loadAddonFile(addon, "Raid Management Addon/Modules/Base64.lua")
	local transport = installRealCommsQueueFixture(addon)
	addon.Strings.NormalizeLower = function(value) return string.lower(tostring(value or "")) end
	local revision = 2
	local store = {
		GetRaidSyncRevision = function() return revision end,
		GetLootSyncRevision = function(_, _, row) return row.syncRevision or 0 end,
		RequiresFullSyncSince = function() return false end,
	}
	addon.Database.GetRaidStore = function() return store end
	addon.Database.GetRaidQueries = function()
		return { ResolveLootLooterNameFromMap = function(_, loot) return loot.looterName end }
	end
	addon.Database.EnsureRaidSchema = function(raid) return raid end
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncPayload.lua")
	local payload = addon.DB.Syncer._Payload
	local function lootRow(i)
		return {
			lootNid = i,
			itemId = 50000 + i,
			itemName = "Representative Raid Award " .. i,
			itemString = "item:" .. (50000 + i) .. ":0:0:0:0:0:0:0",
			itemLink = "|cffa335ee|Hitem:" .. (50000 + i) .. ":0:0:0:0:0:0:0|h[Representative Raid Award " .. i .. "]|h|r",
			itemRarity = 4,
			itemTexture = "Interface\\Icons\\INV_Misc_QuestionMark",
			itemCount = 1,
			looterName = "Leader-Test Realm",
			rollType = 1,
			rollValue = 100,
			bossNid = 0,
			time = 1712345678 + i,
			syncRevision = i,
		}
	end
	local raid = {
		raidNid = 41,
		schemaVersion = 1,
		zone = "Icecrown Citadel",
		size = 25,
		difficulty = 2,
		realm = "Test Realm",
		startTime = 1712345678,
		endTime = 0,
		nextPlayerNid = 2,
		nextBossNid = 1,
		nextLootNid = 3,
		players = { { playerNid = 1, name = "Leader-Test Realm", rank = 2, subgroup = 1, class = "PALADIN", join = 1712345678, leave = 0, countMS = 0 } },
		attendance = {},
		bossKills = {},
		loot = { lootRow(1), lootRow(2) },
	}
	syncFixture.currentRaid = raid
	syncFixture.lootMethod = "master"
	syncFixture.localMasterLooter = true
	syncFixture.roster = {
		{ name = "Requester-One-Test Realm", rank = 0 },
		{ name = "Requester-Two-Test Realm", rank = 0 },
	}
	syncFixture.groupUnits = {
		["requester-one-test realm"] = "raid1",
		["requester-two-test realm"] = "raid2",
	}

	local function queuedEnvelopeMessages()
		local messages = {}
		local head = addon.Comms._addonQueueHead
		local tail = addon.Comms._addonQueueTail
		for i = head, tail do
			messages[#messages + 1] = addon.Comms._addonQueue[i].msg
		end
		return messages
	end

	local function requestAndDrain(requestId, sender, sinceRevision, expectedKind, label)
		local request = table.concat({
			"RQ", 2, requestId, "SYNC", raid.raidNid, payload.EncodeText(raid.zone), raid.size, raid.difficulty,
			sinceRevision, 0,
		}, "\t")
		syncer:OnAddonMessage("RMALogSync", request, "RAID", sender)
		local messages = queuedEnvelopeMessages()
		assertTrue(#messages > 0, label .. " must enqueue production envelopes")
		assertTrue(#messages <= 47, label .. " exceeds 47 chunks: " .. #messages)
		for i = 1, #messages do
			local fields = addon.Comms.Payload.SplitFields(messages[i], "\t")
			assertEqual(expectedKind, fields[1], label .. " envelope kind differs")
			assertEqual(requestId, fields[3], label .. " request ID differs")
			assertEqual(i, tonumber(fields[6]), label .. " chunk index differs")
			assertEqual(#messages, tonumber(fields[7]), label .. " production chunk count differs")
		end
		local elapsed = 0.25 + transport:Drain(#messages)
		assertTrue(elapsed < 5, label .. " exceeds five seconds: " .. elapsed)
		local firstSent = transport.sent[#transport.sent - #messages + 1]
		assertTrue(firstSent and firstSent.message == messages[1], label .. " must drain the queued envelope")
		return #messages, elapsed
	end

	local deltaChunks, deltaElapsed = requestAndDrain(
		"latency-delta", "Requester-One-Test Realm", 1, "DL", "one-row delta"
	)
	revision = 20
	raid.loot = {}
	for i = 1, 20 do raid.loot[i] = lootRow(i) end
	raid.nextLootNid = 21
	local snapshotChunks, snapshotElapsed = requestAndDrain(
		"latency-snapshot", "Requester-Two-Test Realm", 0, "SN", "20-row snapshot"
	)

	local maximumMessages = {}
	for i = 1, 256 do maximumMessages[i] = string.rep("x", 255) end
	assertTrue(addon.Comms.QueueAddonMessages("RMA", maximumMessages, "RAID"), "maximum queue enqueue failed")
	local maximumElapsed = transport:Drain(#maximumMessages)
	assertTrue(maximumElapsed < 30, "maximum queue drain exceeds request timeout: " .. maximumElapsed)
	print(string.format(
		"MEASURE sync_payload_latency delta_chunks=%d delta_seconds=%.2f snapshot_chunks=%d snapshot_seconds=%.2f max_messages=256 max_seconds=%.2f",
		deltaChunks, deltaElapsed, snapshotChunks, snapshotElapsed, maximumElapsed
	))
	print("PASS sync_representative_payloads_meet_latency_budget")
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

local function installAuthoritativeBootstrapImportFixture(addon)
	installRaidDatabaseStubs(addon)
	local store = addon.DB.RaidStore
	local destination = canonicalRaidFixture()
	destination.raidNid = 7
	destination.startTime = 950
	destination.players[1].name = "LocalCollision"
	destination.bossKills[1].name = "LocalCollision"
	destination.loot[1].itemName = "LocalCollision"
	_G.RMA_Raids = { destination }
	store:SetRaidSyncRevision(destination, 9, "fixture")
	store:EnsureRaidRuntime(destination)
	local snapshot = {
		header = {
			protocolVersion = 2,
			schemaVersion = 6,
			raidNid = 88,
			revision = 4,
			realm = "Source Realm",
			zone = "Ulduar",
			size = 25,
			difficulty = 2,
			startTime = 100,
			endTime = 800,
			nextPlayerNid = 3,
			nextBossNid = 2,
			nextLootNid = 3,
		},
		players = {
			{ playerNid = 1, name = "SourceLeader", rank = 2, subgroup = 1, class = "WARRIOR", join = 100, leave = 800, count = 1 },
			{ playerNid = 2, name = "SourceMember", rank = 0, subgroup = 1, class = "PRIEST", join = 120, leave = 0, count = 0 },
		},
		attendance = {
			{ playerNid = 1, startTime = 100, endTime = 800, subgroup = 1, online = true },
			{ playerNid = 2, startTime = 120, endTime = 0, subgroup = 1, online = true },
		},
		bosses = {
			{ bossNid = 1, name = "Flame Leviathan", mode = "h", difficulty = 2, time = 300, players = { 1, 2 } },
		},
		loot = {
			{ lootNid = 1, itemId = 200, itemName = "SourceCollision", itemString = "item:200", itemLink = "[SourceCollision]", itemRarity = 4, itemTexture = "texture", itemCount = 1, looterNid = 1, rollType = 1, rollValue = 99, bossNid = 1, time = 310 },
			{ lootNid = 2, itemId = 201, itemName = "SourceSecond", itemString = "item:201", itemLink = "[SourceSecond]", itemRarity = 4, itemTexture = "texture", itemCount = 1, looterNid = 2, rollType = 0, rollValue = 0, bossNid = 1, time = 320 },
		},
	}
	addon.DB.Syncer = { _Payload = {
		ValidateSnapshot = function(value, localRevision, expectedRaidNid)
			if value ~= snapshot or localRevision ~= 0 or expectedRaidNid ~= 88 then return false, "fixture_validation_failed" end
			return true
		end,
		BuildPlayerNameMaps = function(players)
			local byName, valid = {}, {}
			for i = 1, #(players or {}) do
				byName[string.lower(players[i].name)] = players[i].playerNid
				valid[players[i].playerNid] = true
			end
			return {}, byName, valid
		end,
	} }
	addon.Time = { GetCurrentTime = function() return 100 end }
	addon.State = {}
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncImport.lua")
	return store, addon.DB.Syncer._Import, destination, snapshot
end

function cases.sync_late_join_bootstrap_replaces_unrelated_local_history(addon)
	local store, importer, destination, snapshot = installAuthoritativeBootstrapImportFixture(addon)
	destination.inspect = { players = { [1] = { playerNid = 1, name = "LocalCollision" } } }
	local localRaidNid = destination.raidNid
	local sourceStartTime = snapshot.header.startTime
	local sourcePlayerName = snapshot.players[1].name
	local sourceRevision = snapshot.header.revision
	local applied, reason = importer.ReplaceRaidFromAuthority(destination, snapshot)
	assertEqual(destination, applied, "bootstrap did not preserve canonical root identity")
	assertEqual(nil, reason, "bootstrap returned an unexpected error")
	assertEqual(localRaidNid, destination.raidNid, "bootstrap replaced local raid identity")
	assertEqual(sourceStartTime, destination.startTime, "bootstrap kept late login time")
	assertEqual(sourcePlayerName, destination.players[1].name, "colliding player NID was merged")
	assertEqual("Flame Leviathan", destination.bossKills[1].name, "colliding boss NID was merged")
	assertEqual("SourceCollision", destination.loot[1].itemName, "colliding loot NID was merged")
	assertEqual(#snapshot.loot, #destination.loot, "authoritative loot was not replaced exactly")
	assertEqual(nil, destination.inspect, "bootstrap retained inspect data keyed by unrelated local player NIDs")
	assertEqual(sourceRevision, store:GetRaidSyncRevision(destination), "source revision not adopted")
	print("PASS sync_late_join_bootstrap_replaces_unrelated_local_history")
end

function cases.sync_authoritative_bootstrap_rolls_back_atomically(addon)
	local store, importer, destination, snapshot = installAuthoritativeBootstrapImportFixture(addon)
	local before = deepCopy(destination)
	local originalEnsureRuntime = store.EnsureRaidRuntime
	store.EnsureRaidRuntime = function() error("injected authoritative bootstrap failure") end
	local applied, reason = importer.ReplaceRaidFromAuthority(destination, snapshot)
	store.EnsureRaidRuntime = originalEnsureRuntime
	assertEqual(nil, applied, "failed authoritative bootstrap must reject")
	assertEqual("COMMIT_FAILED", reason, "failed authoritative bootstrap reason differs")
	assertTrue(deepEqual(before, destination), "failed authoritative bootstrap exposed partial history or revision")
	assertEqual(9, store:GetRaidSyncRevision(destination), "failed authoritative bootstrap changed local revision")
	print("PASS sync_authoritative_bootstrap_rolls_back_atomically")
end

function cases.sync_authoritative_delta_maps_source_to_local_raid(addon)
	installRaidDatabaseStubs(addon)
	addon.DB.Syncer = {}
	addon.Diag = { D = {} }
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Comms = { Payload = {
		EncodeText = function(value) return tostring(value or "") end,
		DecodeText = function(value) return value end,
		SplitFields = function(message, separator, out)
			local fields = out or {}
			for i = 1, #fields do fields[i] = nil end
			for field in string.gmatch(message .. separator, "(.-)" .. separator) do fields[#fields + 1] = field end
			return fields, #fields
		end,
		PackFields = function(separator, ...)
			local values = { ... }
			for i = 1, #values do values[i] = tostring(values[i] or "") end
			return table.concat(values, separator)
		end,
	} }
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncPayload.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncImport.lua")
	local store = addon.DB.RaidStore
	local importer = addon.DB.Syncer._Import
	local destination = canonicalRaidFixture()
	destination.raidNid = 7
	_G.RMA_Raids = { destination }
	store:SetRaidSyncRevision(destination, 4, "fixture")
	store:EnsureRaidRuntime(destination)
	local delta = {
		header = { protocolVersion = 2, raidNid = 88, sinceRevision = 4, revision = 5 },
		loot = {
			{
				lootNid = 2,
				itemId = 201,
				itemName = "Authority Delta",
				itemString = "item:201",
				itemLink = "[Authority Delta]",
				itemRarity = 4,
				itemTexture = "texture",
				itemCount = 1,
				looterName = "Alpha",
				rollType = 1,
				rollValue = 95,
				bossNid = 1,
				time = 60,
				syncRevision = 5,
			},
		},
	}
	local before = deepCopy(destination)
	local generic, genericReason = importer.ApplyDeltaToRaid(destination, delta)
	assertEqual(nil, generic, "generic delta importer must remain strict about local raid identity")
	assertEqual("raid_mismatch", genericReason, "generic delta mismatch reason differs")
	assertTrue(deepEqual(before, destination), "generic mismatch must preserve canonical local history")

	local applied, reason = importer.ApplyDeltaFromAuthority(destination, delta, 88)
	assertEqual(destination, applied, "authoritative delta did not preserve canonical local raid root")
	assertEqual(nil, reason, "authoritative delta returned an unexpected error")
	assertEqual(7, destination.raidNid, "authoritative delta replaced local raid identity")
	assertEqual(2, #destination.loot, "authoritative delta did not append the source loot row")
	assertEqual("Authority Delta", destination.loot[2].itemName, "authoritative delta loot differs")
	assertEqual(5, store:GetRaidSyncRevision(destination), "authoritative delta revision was not committed")
	print("PASS sync_authoritative_delta_maps_source_to_local_raid")
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

	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.debugEnabled = true
	fixture.lootMethod = "master"
	fixture.lootAuthority = "Master-Test Realm"
	fixture.roster = {
		{ name = "Master-Test Realm", rank = 0 },
		{ name = "Peer-Test Realm", rank = 0 },
	}
	fixture.snapshot = {
		header = {
			protocolVersion = 2,
			raidNid = 88,
			revision = 4,
			zone = "Naxxramas",
			size = 25,
			difficulty = 1,
		},
		players = {}, attendance = {}, bosses = {}, loot = {},
	}
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "RV", 2, 88, "Naxxramas", 25, 1, 4 }, "\t"),
		"RAID",
		"Master-Test Realm"
	)
	local noticeTimer = assert(syncer._noticePullHandle, "revision notice did not schedule a failed import pull")
	assertTrue(fixture:FireTimer(noticeTimer), "failed import pull timer did not fire")
	local request = fixture.sent[#fixture.sent]
	local requestId = string.match(request.message, "^[^\t]+\t[^\t]+\t([^\t]+)")
	fixture.failNextImport = true
	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "SN", 2, requestId, "SYNC", 88, 1, 1, "snapshot" }, "\t"),
		"WHISPER",
		"Master-Test Realm"
	)
	assertSingleImportOutcome(fixture, "IMPORT_REJECT", "generated-1", {
		mode = "SYNC",
		req = "generated-1",
		from = "master-test realm",
		localRaid = 41,
		sourceRaidNid = 88,
		revision = 4,
		loot = 0,
		reason = "merge_failed",
	})
	assertEqual(0, #fixture:GetSyncTraces("REQUEST_END", "generated-1"), "rejected sync sender terminalized the shared request")
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
	fixture.lootMethod = "master"
	fixture.localMasterLooter = true
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

function cases.strings_utf8_safe_prefix(addon)
	loadAddonFile(addon, "Raid Management Addon/Modules/Strings.lua")
	local prefix = addon.Strings.Utf8SafePrefix
	assertEqual("abc", prefix("abc", 3), "ASCII text at the boundary must remain intact")
	assertEqual("A", prefix("A" .. string.char(0xc3, 0xa9), 2), "a split multibyte character must be omitted")
	assertEqual(
		"A" .. string.char(0xc3, 0xa9),
		prefix("A" .. string.char(0xc3, 0xa9), 3),
		"a complete multibyte character must remain"
	)
	assertEqual(
		"Good",
		prefix("Good" .. string.char(0xc0, 0x80) .. "suffix", 255),
		"malformed UTF-8 and its suffix must be removed"
	)
	assertEqual("", prefix(nil, 10), "non-string input must normalize to an empty prefix")
	assertEqual("", prefix("text", 0), "non-positive limits must return an empty prefix")
	print("PASS strings_utf8_safe_prefix")
end

function cases.spammer_warnings_saved_variables_are_normalized(addon)
	local spammerStore = {
		Name = "  Citadel  ",
		Tank = "-4",
		Healer = "2.8",
		Melee = {},
		Ranged = "12",
		TankClass = 44,
		HealerClass = "  Priest  ",
		Message = string.rep("M", 254) .. string.char(0xc3, 0xa9),
		Duration = "-10",
		Channels = {
			[1] = 7,
			[3] = "Trade",
			[4] = 99,
			duplicate = "trade",
			bad = {},
			guild = "GUILD",
		},
		Unexpected = "remove me",
	}
	local warningsStore = {
		[1] = { name = "  Pull  ", content = "  Pull now  ", extra = true },
		[3] = { name = "", content = "missing name" },
		[5] = { name = string.rep("N", 63) .. string.char(0xc3, 0xa9), content = string.rep("C", 254) .. string.char(0xc3, 0xa9) },
		mapped = { name = "  Stack  ", content = "  Stack now  " },
		invalidUtf8 = { name = "Safe", content = "Good" .. string.char(0xff) .. "discard" },
		bad = "not a warning",
	}

	local warningEvents = {}
	local failWarningEvent = false
	addon.L = {
		StrTank = "tank", StrHealer = "healer", StrMelee = "melee", StrRanged = "ranged",
		StrSpammerNeedStr = "need", StrConfigRaidWarningPreviewEmpty = "empty",
		StrRaidWarningTemplatePullName = string.rep("T", 63) .. string.char(0xc3, 0xa9),
		StrRaidWarningTemplatePullContent = string.rep("P", 254) .. string.char(0xc3, 0xa9),
	}
	addon.Strings = {
		TrimText = function(value)
			if type(value) ~= "string" then return "" end
			return value:match("^%s*(.-)%s*$")
		end,
	}
	addon.Database.SavedVariables = {
		GetSpammer = function() return spammerStore end,
		GetWarnings = function() return warningsStore end,
	}
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then addon.Services[owner][child] = addon.Services[owner][child] or {} end
	end
	addon.Events.Internal = { WarningsDataChanged = "WarningsDataChanged" }
	addon.Bus.TriggerEvent = function(_, reason)
		if failWarningEvent then error("listener failure") end
		local snapshot = {}
		for i = 1, #warningsStore do
			snapshot[i] = { name = warningsStore[i].name, content = warningsStore[i].content }
		end
		warningEvents[#warningEvents + 1] = { reason = reason, warnings = snapshot }
	end
	_G.GetChannelName = function(id)
		if id == 7 then return 7, "LookingForGroup" end
		return 0, nil
	end

	loadAddonFile(addon, "Raid Management Addon/Modules/Strings.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Draft.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Warnings/Store.lua")
	local draft = addon.Services.Spammer.Draft
	local warningStore = addon.Services.Warnings.Store

	local state = draft.BuildState(draft.GetStore())
	assertEqual("Citadel", state.name, "spammer name must be trimmed")
	assertEqual(0, state.tank, "negative counts must normalize to zero")
	assertEqual(2, state.healer, "fractional counts must normalize to an integer")
	assertEqual(0, state.melee, "invalid count types must normalize to zero")
	assertEqual(9, state.ranged, "counts must respect the persisted one-digit UI limit")
	assertEqual("", state.tankClass, "invalid string types must not be stringified")
	assertEqual("Priest", state.healerClass, "class text must be trimmed")
	assertEqual(254, #state.message, "spammer message must not persist a partial UTF-8 sequence")
	assertEqual("60", state.duration, "negative duration must restore the independent default")
	assertEqual(nil, spammerStore.Unexpected, "unknown spammer fields must be removed")
	assertEqual(2, #spammerStore.Channels, "channels must be dense and deduplicated")
	assertEqual("Trade", spammerStore.Channels[1], "numeric channel IDs must be discarded instead of retargeted")
	assertEqual("GUILD", spammerStore.Channels[2], "stable built-in destinations must be preserved")
	for key in pairs(spammerStore.Channels) do
		assertTrue(type(key) == "number" and key >= 1 and key <= 2, "channel storage must be a dense sequence")
	end

	local ok, reason = draft.SetField(spammerStore, "Unexpected", "x")
	assertEqual(false, ok, "unknown spammer fields must be rejected")
	assertEqual("invalid_field", reason, "unknown field rejection reason differs")
	ok, reason = draft.SetField(spammerStore, "Duration", -1)
	assertEqual(false, ok, "negative duration must be rejected at the service boundary")
	assertEqual("invalid_duration", reason, "duration rejection reason differs")
	local exactDraftName = string.rep("D", 62) .. string.char(0xc3, 0xa9)
	assertEqual(true, draft.SetField(spammerStore, "Name", exactDraftName), "exact-boundary UTF-8 draft text must save")
	assertEqual(exactDraftName, spammerStore.Name, "exact-boundary UTF-8 draft text must remain intact")
	local clearedDraft = draft.ClearDraft(spammerStore)
	assertEqual("", clearedDraft.Name, "clear must return completed canonical text state")
	assertEqual("0", clearedDraft.Tank, "clear must return completed canonical count state")
	assertEqual("60", clearedDraft.Duration, "clear must return completed canonical duration state")
	assertEqual(2, #clearedDraft.Channels, "clear must preserve normalized channel selection")

	local warnings = warningStore.GetStore()
	assertEqual(4, #warnings, "valid sparse and map-backed warnings must become dense")
	assertEqual("Pull", warnings[1].name, "warning names must be trimmed")
	assertEqual("Pull now", warnings[1].content, "warning content must be trimmed")
	assertEqual(nil, warnings[1].extra, "warning records must contain canonical fields only")
	assertEqual(63, #warnings[2].name, "warning names must not persist a partial UTF-8 sequence")
	assertEqual(254, #warnings[2].content, "warning content must not persist a partial UTF-8 sequence")
	assertEqual("Safe", warnings[3].name, "warnings with malformed UTF-8 suffixes must retain only the valid prefix")
	assertEqual("Good", warnings[3].content, "invalid UTF-8 and its suffix must not be persisted")
	assertEqual("Stack", warnings[4].name, "map-backed warnings must be retained deterministically")
	for key, warning in pairs(warnings) do
		assertTrue(type(key) == "number" and key >= 1 and key <= 4, "warnings must be a dense sequence")
		assertEqual("string", type(warning.name), "warning names must be strings")
		assertEqual("string", type(warning.content), "warning content must be strings")
	end
	local normalizedRefs = { warnings[1], warnings[2], warnings[3], warnings[4] }

	local templateResult = warningStore.EnsureDefaultTemplates()
	assertEqual(5, templateResult.added, "valid stock templates not already represented by name must be added")
	assertEqual(63, #warnings[5].name, "localized template names must be normalized before insertion")
	assertEqual(254, #warnings[5].content, "localized template content must be normalized before insertion")
	assertEqual("templates", warningEvents[#warningEvents].reason, "template event reason differs")
	assertEqual(63, #warningEvents[#warningEvents].warnings[5].name, "template event must observe canonical data")
	for i = 1, 4 do
		assertTrue(rawequal(normalizedRefs[i], warnings[i]), "template insertion must preserve existing row identity " .. i)
	end
	local exactWarningName = string.rep("W", 62) .. string.char(0xc3, 0xa9)
	local exactWarningContent = string.rep("Q", 253) .. string.char(0xc3, 0xa9)
	local savedWarning = warningStore.SaveWarning(exactWarningContent, exactWarningName)
	assertEqual(10, savedWarning, "exact-boundary UTF-8 warning must save")
	assertEqual(exactWarningName, warnings[savedWarning].name, "exact-boundary warning name must remain intact")
	assertEqual(exactWarningContent, warnings[savedWarning].content, "exact-boundary warning content must remain intact")
	for i = 1, 4 do
		assertTrue(rawequal(normalizedRefs[i], warnings[i]), "append must preserve existing row identity " .. i)
	end
	local beforeEditRefs = {}
	for i = 1, #warnings do beforeEditRefs[i] = warnings[i] end
	local editedID = warningStore.SaveWarning("edited content", "Edited exact", savedWarning, true)
	assertEqual(savedWarning, editedID, "valid edit must preserve warning ID")
	for i = 1, savedWarning - 1 do
		assertTrue(rawequal(beforeEditRefs[i], warnings[i]), "edit must preserve unchanged row identity " .. i)
	end
	assertTrue(not rawequal(beforeEditRefs[savedWarning], warnings[savedWarning]), "edit must replace only the changed row")
	local beforeRejectedSave = deepCopy(warnings)
	local rejectedID, rejectedReason = warningStore.SaveWarning(string.rep("X", 256), "Oversized")
	assertEqual(nil, rejectedID, "oversized API warning content must be rejected")
	assertEqual("content_too_long", rejectedReason, "oversized content reason differs")
	assertTrue(deepEqual(beforeRejectedSave, warnings), "oversized save must preserve exact warning state")
	rejectedID, rejectedReason = warningStore.SaveWarning("duplicate", " pull ")
	assertEqual(nil, rejectedID, "duplicate warning names must be rejected case-insensitively")
	assertEqual("duplicate_name", rejectedReason, "duplicate name reason differs")
	assertTrue(deepEqual(beforeRejectedSave, warnings), "duplicate save must preserve exact warning state")

	local eventCountBefore = #warningEvents
	local stableRoot = warningsStore
	local beforeNotificationRefs = {}
	for i = 1, #warnings do beforeNotificationRefs[i] = warnings[i] end
	failWarningEvent = true
	local committedID, committedReason, commitDetail = warningStore.SaveWarning("committed", "Notification contained")
	assertEqual(#beforeNotificationRefs + 1, committedID, "notification failure must not turn a committed save into failure")
	assertEqual(nil, committedReason, "committed save has no mutation failure")
	assertEqual(true, commitDetail.notificationFailed, "save must expose contained notification failure")
	assertTrue(rawequal(stableRoot, warningsStore), "save must preserve SavedVariables root identity")
	for i = 1, #beforeNotificationRefs do
		assertTrue(rawequal(beforeNotificationRefs[i], warnings[i]), "contained notification failure must preserve row identity " .. i)
	end
	assertEqual(eventCountBefore, #warningEvents, "throwing notification must not append an event snapshot")
	local deletedRef = warnings[2]
	local shiftedRef = warnings[3]
	local deleteResult = warningStore.DeleteWarning(2)
	assertEqual(true, deleteResult.deleted, "delete must commit despite notification failure")
	assertEqual(true, deleteResult.notificationFailed, "delete must expose contained notification failure")
	assertTrue(not rawequal(deletedRef, warnings[2]), "delete must remove the selected row")
	assertTrue(rawequal(shiftedRef, warnings[2]), "delete must preserve shifted row identity")
	local stockRefs = {}
	for i = 1, #warnings do
		local warning = warnings[i]
		if warning.name == string.rep("T", 63) or warning.name == "Spread" or warning.name == "Stack" or warning.name == "Stop DPS"
			or warning.name == "Bloodlust" or warning.name == "Break" then stockRefs[warning.name] = warning end
	end
	local clearResult = warningStore.ClearSavedWarnings(false)
	assertEqual(true, clearResult.notificationFailed, "clear must expose contained notification failure")
	for i = 1, #warnings do
		assertTrue(rawequal(stockRefs[warnings[i].name], warnings[i]), "clear must preserve kept stock row identity")
	end
	failWarningEvent = false

	-- Reload-shaped service initialization must be idempotent and create no shared defaults.
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Draft.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Warnings/Store.lua")
	assertEqual(2, #draft.GetChannels(spammerStore), "reload must preserve canonical channels")
	assertEqual(5, #warningStore.GetStore(), "reload must preserve kept stock warnings")
	local first = {}
	local second = {}
	assertTrue(draft.GetChannels(first) ~= draft.GetChannels(second), "fresh channel defaults must be independent")
	print("PASS spammer_warnings_saved_variables_are_normalized")
end

function cases.spammer_runtime_is_bounded_and_atomic(addon)
	local scheduled = {}
	local warnings = {}
	addon.L = addon.L or {}
	addon.L.MsgSpammerAutoStopDuration = "duration %d"
	addon.L.MsgSpammerAutoStopMessages = "messages %d"
	addon.warn = function(_, message) warnings[#warnings + 1] = message end
	addon.Services = addon.Services or {}
	addon.Services.Spammer = addon.Services.Spammer or {}
	addon.Services.EnsureNamespace = function() return addon.Services.Spammer end
	addon.Timer = addon.Timer or {}
	addon.Timer.BindMixin = function(target)
		function target:ScheduleRepeatingTimer(callback)
			local handle = { callback = callback, cancelled = false }
			scheduled[#scheduled + 1] = handle
			return handle
		end
		function target:CancelTimer(handle) handle.cancelled = true return true end
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	local runtime = addon.Services.Spammer.Runtime
	local workingScheduler = runtime.ScheduleRepeatingTimer
	local attempts, terminal = {}, 0
	local ok = runtime:Start({ duration = 1, output = "saved draft", channels = { "GUILD", "YELL" },
		sendFn = function(text, channel) attempts[#attempts + 1] = text .. ":" .. channel return true end,
		onTerminal = function() terminal = terminal + 1 end })
	assertEqual(ok, true, "runtime starts")
	for _ = 1, 60 do scheduled[1].callback() end
	assertEqual(#attempts, 30, "global cap counts destination attempts")
	assertEqual(terminal, 1, "terminal callback fires once")
	assertEqual(runtime:GetState().ticking, false, "cap stops runtime")
	assertEqual(0, #warnings, "runtime owner must not duplicate controller terminal feedback")

	local stale = scheduled[1].callback
	assertEqual(runtime:Start({ duration = 1, output = "restart", channels = { "GUILD" }, sendFn = function() return true end }), true, "restart")
	stale()
	assertEqual(runtime:GetState().attempts, 0, "stale callback ignored")
	runtime:Stop(true, true)
	assertEqual(runtime:GetState().ticking, false, "explicit stop")

	local clock, sendTimes = 0, {}
	assertEqual(runtime:Start({ duration = 3, output = "timed", channels = { "GUILD", "YELL" }, sendFn = function()
		sendTimes[#sendTimes + 1] = clock
		return true
	end }), true, "timed run starts")
	local timedCallback = scheduled[#scheduled].callback
	for second = 1, 6 do clock = second timedCallback() end
	assertEqual(sendTimes[1], 3, "first destination uses exact interval")
	assertEqual(sendTimes[2], 4, "destinations are throttled")
	assertEqual(sendTimes[3], 6, "cycle interval is measured from first destination")
	assertEqual(runtime:GetState().countdownRemaining, 3, "remaining time advances immediately after send")
	runtime:Stop(true, true)

	local stopTerminal = 0
	assertEqual(runtime:Start({ duration = 1, output = "stop", channels = { "GUILD" },
		sendFn = function() runtime:Stop(true, true) return true end,
		onTerminal = function() stopTerminal = stopTerminal + 1 end }), true, "reentrant stop run")
	scheduled[#scheduled].callback()
	assertEqual(runtime:GetState().ticking, false, "send callback stop remains authoritative")
	assertEqual(runtime:GetState().attempts, 0, "stopped run cannot restore reserved attempt")
	assertEqual(stopTerminal, 0, "explicit reentrant stop does not emit terminal callback")

	local replacementTerminal = 0
	assertEqual(runtime:Start({ duration = 1, output = "old", channels = { "GUILD" }, sendFn = function()
		return runtime:Start({ duration = 5, output = "replacement", channels = { "YELL" }, sendFn = function() return true end,
			onTerminal = function() replacementTerminal = replacementTerminal + 1 end })
	end }), true, "reentrant replacement run")
	local oldCallback = scheduled[#scheduled].callback
	oldCallback()
	assertEqual(runtime:GetState().output, "replacement", "old tick cannot overwrite replacement run")
	assertEqual(runtime:GetState().attempts, 0, "replacement attempt count remains intact")
	assertEqual(runtime:GetState().ticking, true, "replacement remains active")
	oldCallback()
	assertEqual(runtime:GetState().attempts, 0, "old callback remains stale")
	runtime:Stop(true, true)
	assertEqual(replacementTerminal, 0, "replacement callback not fired by old run")

	local failureReasons = {}
	assertEqual(runtime:Start({ duration = 1, output = "false", channels = { "GUILD" }, sendFn = function() return false end,
		onTerminal = function(reason) failureReasons[#failureReasons + 1] = reason end }), true, "false transport run")
	scheduled[#scheduled].callback()
	assertEqual("send_failed", failureReasons[1], "false transport terminates run")
	assertEqual(1, runtime:GetState().attempts, "false transport counts the actual attempt")
	assertEqual(0, runtime:GetState().messagesSent, "failed transport must not count as delivered")
	assertEqual(runtime:Start({ duration = 1, output = "nil", channels = { "GUILD" }, sendFn = function() return nil end,
		onTerminal = function(reason) failureReasons[#failureReasons + 1] = reason end }), true, "nil transport run")
	scheduled[#scheduled].callback()
	assertEqual("send_failed", failureReasons[2], "nil transport result must not report success")
	assertEqual(runtime:Start({ duration = 1, output = "throw", channels = { "GUILD" }, sendFn = function() error("transport") end,
		onTerminal = function(reason) failureReasons[#failureReasons + 1] = reason end }), true, "throwing transport run")
	scheduled[#scheduled].callback()
	assertEqual("send_failed", failureReasons[3], "throwing transport terminates run")
	assertEqual(3, #failureReasons, "each failed run emits terminal callback once")
	assertEqual(0, #warnings, "send failures emit no runtime-owner user feedback")
	local destinationAvailable = true
	assertEqual(runtime:Start({ duration = 1, output = "transition", channels = { "GUILD", "YELL" }, sendFn = function(_, destination)
		if destination == "GUILD" then destinationAvailable = false return true end
		return destinationAvailable
	end, onTerminal = function(reason) failureReasons[#failureReasons + 1] = reason end }), true, "channel transition run")
	local transitionCallback = scheduled[#scheduled].callback
	transitionCallback()
	transitionCallback()
	assertEqual("send_failed", failureReasons[4], "destination transition terminates through injected transport result")
	assertEqual(2, runtime:GetState().attempts, "transition counts both destination attempts")
	assertEqual(1, runtime:GetState().messagesSent, "transition counts only confirmed deliveries")
	assertEqual(0, #warnings, "destination transition emits no runtime-owner user feedback")

	assertEqual(runtime:Start({ duration = 999, output = "duration", channels = { "GUILD" }, sendFn = function() return true end }), true, "duration cap run")
	local durationCallback = scheduled[#scheduled].callback
	for _ = 1, 1800 do durationCallback() end
	assertEqual(0, #warnings, "duration cap feedback belongs to controller")
	runtime:Stop(true, true)
	assertEqual(0, #warnings, "explicit stop emits no runtime-owner user feedback")

	runtime.ScheduleRepeatingTimer = function() return nil end
	local failed = runtime:Start({ duration = 1, output = "fail", channels = { "GUILD" } })
	assertEqual(failed, false, "nil scheduler fails atomically")
	assertEqual(runtime:GetState().ticking, false, "failed start does not tick")
	runtime.ScheduleRepeatingTimer = function() error("scheduler unavailable") end
	failed = runtime:Start({ duration = 0, output = "fail", channels = { "GUILD" }, sendFn = function() return true end })
	assertEqual(failed, false, "throwing scheduler fails atomically")
	assertEqual(runtime:GetState().ticking, false, "throwing start does not tick")
	runtime.ScheduleRepeatingTimer = workingScheduler
	print("PASS spammer_runtime_is_bounded_and_atomic")
end

function cases.spammer_runtime_contains_callback_exceptions_and_reasons(addon)
	local scheduled, diagnostics = {}, {}
	addon.L = { WarnSpammerCallbackFailed = "callback failed: %s" }
	addon.warn = function(_, message, reason)
		diagnostics[#diagnostics + 1] = reason and string.format(message, reason) or message
	end
	addon.Services.Spammer = {}
	addon.Services.EnsureNamespace = function() return addon.Services.Spammer end
	addon.Timer = { BindMixin = function(target)
		function target:ScheduleRepeatingTimer(callback)
			local handle = { callback = callback }
			scheduled[#scheduled + 1] = handle
			return handle
		end
		function target:CancelTimer() return true end
	end }
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	local runtime = addon.Services.Spammer.Runtime

	local callOk, started = pcall(runtime.Start, runtime, {
		duration = 1, output = "callback", channels = { "GUILD" }, sendFn = function() return true end,
		onTick = function() error("tick start") end,
	})
	assertEqual(true, callOk, "throwing initial onTick must not escape Start")
	assertEqual(true, started, "throwing initial onTick must not undo committed start")
	assertEqual(true, runtime:GetState().ticking, "throwing initial onTick must preserve ticking state")
	assertEqual(1, #diagnostics, "throwing initial onTick must emit one diagnostic")
	callOk = pcall(runtime.Pause, runtime)
	assertEqual(true, callOk, "throwing pause onTick must not escape Pause")
	assertEqual(true, runtime:GetState().paused, "throwing pause onTick must preserve paused state")
	assertEqual(2, #diagnostics, "throwing pause onTick must emit one diagnostic")
	runtime:Stop(true, true)

	local terminalReason
	assertEqual(true, runtime:Start({
		duration = 1, output = "failure", channels = { "GUILD" },
		sendFn = function() return nil, "not_in_guild" end,
		onTerminal = function(reason) terminalReason = reason; error("terminal callback") end,
	}), "terminal callback containment run must start")
	callOk = pcall(scheduled[#scheduled].callback)
	assertEqual(true, callOk, "throwing terminal callback must not escape timer dispatch")
	assertEqual("not_in_guild", terminalReason, "runtime must preserve concrete transport reason")
	assertEqual(false, runtime:GetState().ticking, "throwing terminal callback must not undo cleanup")
	assertEqual(3, #diagnostics, "throwing terminal callback must emit one diagnostic")
	print("PASS spammer_runtime_contains_callback_exceptions_and_reasons")
end

function cases.spammer_controller_reports_terminal_failures_once(addon)
	local store = { Name = "Ulduar", Message = "hard modes", Duration = "1", Channels = { "GUILD" } }
	local scheduled, errors, infos = {}, {}, {}
	addon.L = {
		StrTank = "tank", StrHealer = "healer", StrMelee = "melee", StrRanged = "ranged", StrSpammerNeedStr = "need",
		BtnResume = "Resume", BtnStop = "Stop", BtnStart = "Start",
		ErrSpammerRuntime = "spammer failed: %s", MsgSpammerAutoStopDuration = "duration %d",
		MsgSpammerAutoStopMessages = "messages %d", WarnSpammerCallbackFailed = "callback failed: %s",
	}
	addon.error = function(_, message, reason) errors[#errors + 1] = string.format(message, reason) end
	addon.info = function(_, message) infos[#infos + 1] = message end
	addon.warn = function() end
	addon.Strings = { TrimText = function(value) return type(value) == "string" and value:match("^%s*(.-)%s*$") or "" end }
	addon.Database.SavedVariables = { GetSpammer = function() return store end }
	addon.Database.RequireServiceMethod = function(_, owner, method) return assert(owner[method]) end
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then addon.Services[owner][child] = addon.Services[owner][child] or {} end
	end
	addon.Services.Chat = { SendSpamOutput = function() return nil, "not_in_guild" end }
	addon.Timer = { BindMixin = function(target)
		function target:ScheduleRepeatingTimer() return nil end
		function target:CancelTimer() return true end
	end }
	addon.Controllers = {}
	addon.UI = {
		Frames = { MakeModuleFrameGetter = function() return function() return nil end end },
		ModuleState = { Ensure = function() return {} end }, Scaffold = { DefineModule = function() end },
		Primitives = { SetEnabled = function() end }, EditBoxes = {}, Tooltips = {},
	}
	addon.WithinRange = function(value, minimum, maximum) return value >= minimum and value <= maximum end
	loadAddonFile(addon, "Raid Management Addon/Modules/Strings.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Draft.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	loadAddonFile(addon, "Raid Management Addon/Controllers/Spammer.lua")
	local runtime = addon.Services.Spammer.Runtime
	local controller = addon.Controllers.Spammer

	controller:RequestStart()
	assertEqual(1, #errors, "scheduler failure must report exactly one user-visible error")
	assertTrue(errors[1]:find("scheduler_failed", 1, true) ~= nil, "scheduler error must preserve reason")
	assertEqual(0, #infos, "scheduler failure must not report success")

	runtime.ScheduleRepeatingTimer = function(_, callback)
		local handle = { callback = callback }
		scheduled[#scheduled + 1] = handle
		return handle
	end
	controller:RequestStart()
	scheduled[1].callback()
	assertEqual(2, #errors, "delivery failure must report exactly one additional error")
	assertTrue(errors[2]:find("not_in_guild", 1, true) ~= nil, "delivery error must preserve concrete reason")
	assertEqual(0, #infos, "delivery failure must not report success")
	print("PASS spammer_controller_reports_terminal_failures_once")
end

function cases.headless_spammer_uses_saved_draft_through_runtime_owner(addon)
	local store = { Name = "Icecrown 25", Tank = 1, Message = "fast clear", Duration = "2", Channels = { "GUILD" } }
	local scheduled, sent, warnings = {}, {}, {}
	addon.L = { StrTank = "tank", StrHealer = "healer", StrMelee = "melee", StrRanged = "ranged", StrSpammerNeedStr = "need",
		MsgSpammerAutoStopDuration = "duration %d", MsgSpammerAutoStopMessages = "messages %d" }
	addon.warn = function(_, message) warnings[#warnings + 1] = message end
	addon.Strings = { TrimText = function(value) return type(value) == "string" and value:match("^%s*(.-)%s*$") or "" end }
	addon.Database.SavedVariables = { GetSpammer = function() return store end }
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then addon.Services[owner][child] = addon.Services[owner][child] or {} end
	end
	addon.Services.Chat = { SendSpamOutput = function(_, output, channels)
		sent[#sent + 1] = { output = output, channel = channels[1] }
		return true
	end }
	addon.Timer = { BindMixin = function(target)
		function target:ScheduleRepeatingTimer(callback)
			local handle = { callback = callback }
			scheduled[#scheduled + 1] = handle
			return handle
		end
		function target:CancelTimer() return true end
	end }
	loadAddonFile(addon, "Raid Management Addon/Modules/Strings.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Draft.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	local draft = addon.Services.Spammer.Draft
	local runtime = addon.Services.Spammer.Runtime
	local preview = draft.BuildPreview(draft.GetStore(), draft.GetDefaultOutput())
	assertTrue(preview.output ~= "LFM", "saved draft must produce non-default headless output")
	assertEqual(runtime:Start({ duration = preview.duration, output = preview.output,
		channels = draft.GetChannels(store), resetCountdown = true, resetRun = true }), true, "runtime owner starts headless run")
	scheduled[1].callback()
	assertEqual(0, #sent, "headless start respects saved duration")
	scheduled[1].callback()
	assertEqual(preview.output, sent[1].output, "headless send uses canonical saved preview")
	assertEqual("GUILD", sent[1].channel, "headless send uses stable saved destination")
	runtime:Stop(true, true)
	assertEqual(runtime:Start({ duration = 1, output = preview.output, channels = { "GUILD", "YELL" }, resetRun = true }), true, "runtime cap run")
	local capCallback = scheduled[#scheduled].callback
	for _ = 1, 60 do capCallback() end
	assertEqual(0, #warnings, "headless runtime cap must not bypass controller feedback ownership")
	assertEqual(runtime:Start({ duration = 999, output = preview.output, channels = { "GUILD" }, resetRun = true }), true, "runtime duration run")
	local durationCallback = scheduled[#scheduled].callback
	for _ = 1, 1800 do durationCallback() end
	assertEqual(0, #warnings, "headless runtime duration cap must not emit duplicate user feedback")
	print("PASS headless_spammer_uses_saved_draft_through_runtime_owner")
end

function cases.controller_request_start_uses_saved_draft_without_frame(addon)
	local store = { Name = "Ulduar 25", Healer = 2, Message = "hard modes", Duration = "1", Channels = { "GUILD" } }
	local scheduled, sent, enabledStates = {}, {}, {}
	addon.L = { StrTank = "tank", StrHealer = "healer", StrMelee = "melee", StrRanged = "ranged", StrSpammerNeedStr = "need" }
	addon.Strings = { TrimText = function(value) return type(value) == "string" and value:match("^%s*(.-)%s*$") or "" end }
	addon.Database.SavedVariables = { GetSpammer = function() return store end }
	addon.Database.RequireServiceMethod = function(_, owner, method) return assert(owner[method]) end
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then addon.Services[owner][child] = addon.Services[owner][child] or {} end
	end
	addon.Services.Chat = { SendSpamOutput = function(_, output, channels)
		sent[#sent + 1] = { output = output, channel = channels[1] }
		return true
	end }
	addon.Timer = { BindMixin = function(target)
		function target:ScheduleRepeatingTimer(callback)
			local handle = { callback = callback }
			scheduled[#scheduled + 1] = handle
			return handle
		end
		function target:CancelTimer() return true end
	end }
	addon.Controllers = {}
	addon.UI = {
		Frames = { MakeModuleFrameGetter = function() return function() return nil end end },
		ModuleState = { Ensure = function() return {} end },
		Scaffold = { DefineModule = function() end },
		Primitives = { SetEnabled = function(_, enabled) enabledStates[#enabledStates + 1] = enabled end }, EditBoxes = {}, Tooltips = {},
	}
	addon.WithinRange = function(value, minimum, maximum) return value >= minimum and value <= maximum end
	loadAddonFile(addon, "Raid Management Addon/Modules/Strings.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Draft.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	loadAddonFile(addon, "Raid Management Addon/Controllers/Spammer.lua")
	assertEqual(addon.Controllers.Spammer:RequestStart(), nil, "controller start keeps public return contract")
	assertEqual(addon.Services.Spammer.Runtime:GetState().ticking, true, "headless controller starts runtime")
	assertEqual(false, enabledStates[#enabledStates], "successful headless start locks inputs")
	scheduled[1].callback()
	assertEqual(1, #sent, "headless controller dispatches after saved duration")
	assertTrue(sent[1].output:find("Ulduar 25", 1, true) ~= nil, "controller builds output from saved draft")
	assertTrue(sent[1].output:find("hard modes", 1, true) ~= nil, "controller includes saved message")
	assertEqual("GUILD", sent[1].channel, "controller uses saved stable channel")
	addon.Controllers.Spammer:RequestStop()
	assertEqual(addon.Services.Spammer.Runtime:GetState().ticking, false, "headless controller stop unlocks runtime")
	assertEqual(true, enabledStates[#enabledStates], "headless stop unlocks inputs")
	print("PASS controller_request_start_uses_saved_draft_without_frame")
end

function cases.spammer_clear_invalidates_ui_without_mutating_active_snapshot(addon)
	local store = { Name = "stale draft", Message = "old message", Duration = "1", Channels = { "GUILD" } }
	local scheduled, sent, currentFrame, scaffoldSpec = {}, {}, nil, nil
	addon.L = {
		StrTank = "tank", StrHealer = "healer", StrMelee = "melee", StrRanged = "ranged",
		StrSpammerNeedStr = "need", BtnResume = "Resume", BtnStop = "Stop", BtnStart = "Start",
	}
	addon.Strings = { TrimText = function(value) return type(value) == "string" and value:match("^%s*(.-)%s*$") or "" end }
	addon.Database.SavedVariables = { GetSpammer = function() return store end }
	addon.Database.RequireServiceMethod = function(_, owner, method) return assert(owner[method]) end
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then addon.Services[owner][child] = addon.Services[owner][child] or {} end
	end
	addon.Services.Chat = { SendSpamOutput = function(_, output, channels)
		sent[#sent + 1] = { output = output, channel = channels[1] }
		return true
	end }
	addon.Timer = { BindMixin = function(target)
		function target:ScheduleRepeatingTimer(callback)
			local handle = { callback = callback }
			scheduled[#scheduled + 1] = handle
			return handle
		end
		function target:CancelTimer() return true end
	end }
	addon.Controllers = {}
	local function newControl(text)
		return {
			text = text or "", checked = false,
			GetText = function(self) return self.text end,
			SetText = function(self, value) self.text = tostring(value or "") end,
			SetTextColor = function() end, SetMaxLetters = function() end,
			SetAlpha = function() end, SetEnabled = function() end, ClearFocus = function() end,
			GetChecked = function(self) return self.checked end,
			SetChecked = function(self, value) self.checked = value == true end,
		}
	end
	local frame = { shown = true, IsShown = function(self) return self.shown end }
	local suffixes = {
		"Name", "Duration", "Tank", "TankClass", "Healer", "HealerClass", "Melee", "MeleeClass",
		"Ranged", "RangedClass", "Message", "Output", "Length", "Tick", "StartBtn", "ClearBtn",
		"ChatGuild", "ChatYell",
	}
	for i = 1, #suffixes do _G["RMASpammer" .. suffixes[i]] = newControl() end
	for i = 1, 8 do _G["RMASpammerChat" .. i] = newControl() end
	addon.UI = {
		Frames = {
			MakeModuleFrameGetter = function() return function() return currentFrame end end,
			BindModuleFrame = function() currentFrame = frame; return "RMASpammer" end,
			GetRef = function(_, suffix) return _G["RMASpammer" .. suffix] end,
			SetScriptSafely = function() end,
		},
		ModuleState = { Ensure = function() return { Localized = true } end },
		Scaffold = { DefineModule = function(spec)
			scaffoldSpec = spec
			spec.module.RequestRefresh = function() spec.refresh() end
		end },
		Primitives = { SetEnabled = function() end, SetText = function() end },
		EditBoxes = { Reset = function(box) if box then box:SetText("") end end },
		Tooltips = {},
	}
	addon.WithinRange = function(value, minimum, maximum) return value >= minimum and value <= maximum end
	_G.GetChannelName = function() return 0, nil end

	loadAddonFile(addon, "Raid Management Addon/Modules/Strings.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Draft.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	loadAddonFile(addon, "Raid Management Addon/Controllers/Spammer.lua")
	local controller = addon.Controllers.Spammer
	controller:RequestClearDraft()
	assertEqual("", store.Name, "clear before frame creation must clear canonical draft")
	assertEqual("60", store.Duration, "clear before frame creation must restore canonical duration")

	store.Name, store.Message, store.Duration = "active draft", "immutable", "1"
	scaffoldSpec.onLoad(frame)
	controller:RequestRefresh()
	assertEqual("active draft", _G.RMASpammerName:GetText(), "frame must load current canonical draft")
	controller:RequestStart()
	assertEqual(true, addon.Services.Spammer.Runtime:GetState().ticking, "run must be active before clear")
	local activeCallback = scheduled[#scheduled].callback

	controller:RequestClearDraft()
	assertEqual(true, addon.Services.Spammer.Runtime:GetState().ticking, "clearing draft must not stop active run")
	assertEqual("", store.Name, "clear after frame creation must clear canonical draft")
	assertEqual("", _G.RMASpammerName:GetText(), "clear after frame creation must invalidate loaded UI immediately")
	assertEqual("LFM", _G.RMASpammerOutput:GetText(), "cleared UI preview must be canonical default")
	activeCallback()
	assertEqual(1, #sent, "pending callback must remain valid for active run")
	assertTrue(sent[1].output:find("active draft", 1, true) ~= nil, "active run must retain immutable output snapshot")
	assertTrue(sent[1].output:find("immutable", 1, true) ~= nil, "pending callback must not read cleared draft")

	controller:RequestStop()
	frame.shown = false
	controller:RequestStart()
	assertEqual(false, addon.Services.Spammer.Runtime:GetState().ticking, "later headless start must use cleared canonical draft")
	assertEqual(1, #scheduled, "cleared canonical draft must not schedule a replacement run")
	print("PASS spammer_clear_invalidates_ui_without_mutating_active_snapshot")
end

function cases.spammer_frame_binding_applies_uncached_clear_state(addon)
	local function installFixture(target, store)
		local scheduled, sent, currentFrame, scaffoldSpec = {}, {}, nil, nil
		target.L = {
			StrTank = "tank", StrHealer = "healer", StrMelee = "melee", StrRanged = "ranged",
			StrSpammerNeedStr = "need", BtnResume = "Resume", BtnStop = "Stop", BtnStart = "Start",
		}
		target.Strings = { TrimText = function(value)
			return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
		end }
		target.Database.SavedVariables = { GetSpammer = function() return store end }
		target.Database.RequireServiceMethod = function(_, owner, method) return assert(owner[method]) end
		target.Services.EnsureNamespace = function(owner, child)
			target.Services[owner] = target.Services[owner] or {}
			if child then target.Services[owner][child] = target.Services[owner][child] or {} end
		end
		target.Services.Chat = { SendSpamOutput = function(_, output, channels)
			sent[#sent + 1] = { output = output, channel = channels[1] }
			return true
		end }
		target.Timer = { BindMixin = function(owner)
			function owner:ScheduleRepeatingTimer(callback)
				local handle = { callback = callback }
				scheduled[#scheduled + 1] = handle
				return handle
			end
			function owner:CancelTimer() return true end
		end }
		target.Controllers = {}

		local function newControl(text)
			return {
				text = text or "", checked = false, enabled = true,
				GetText = function(self) return self.text end,
				SetText = function(self, value) self.text = tostring(value or "") end,
				SetTextColor = function() end, SetMaxLetters = function() end,
				SetAlpha = function() end,
				SetEnabled = function(self, enabled) self.enabled = enabled == true end,
				ClearFocus = function() end,
				GetChecked = function(self) return self.checked end,
				SetChecked = function(self, value) self.checked = value == true end,
			}
		end
		local function bindFrame()
			local frame = { shown = true, IsShown = function(self) return self.shown end }
			local suffixes = {
				"Name", "Duration", "Tank", "TankClass", "Healer", "HealerClass", "Melee", "MeleeClass",
				"Ranged", "RangedClass", "Message", "Output", "Length", "Tick", "StartBtn", "ClearBtn",
				"ChatGuild", "ChatYell",
			}
			for i = 1, #suffixes do _G["RMASpammer" .. suffixes[i]] = newControl() end
			for i = 1, 8 do _G["RMASpammerChat" .. i] = newControl() end
			currentFrame = frame
			scaffoldSpec.onLoad(frame)
			target.Controllers.Spammer:RequestRefresh()
			return frame
		end

		target.UI = {
			Frames = {
				MakeModuleFrameGetter = function() return function() return currentFrame end end,
				BindModuleFrame = function(_, frame) currentFrame = frame; return "RMASpammer" end,
				GetRef = function(_, suffix) return _G["RMASpammer" .. suffix] end,
				SetScriptSafely = function() end,
			},
			ModuleState = { Ensure = function() return { Localized = true } end },
			Scaffold = { DefineModule = function(spec)
				scaffoldSpec = spec
				spec.module.RequestRefresh = function() spec.refresh() end
			end },
			Primitives = {
				SetEnabled = function(control, enabled) if control then control.enabled = enabled == true end end,
				SetText = function(control, activeText, defaultText, active)
					if control then control:SetText(active and activeText or defaultText) end
				end,
			},
			EditBoxes = { Reset = function(box) if box then box:SetText("") end end },
			Tooltips = {},
		}
		target.WithinRange = function(value, minimum, maximum) return value >= minimum and value <= maximum end
		_G.GetChannelName = function() return 0, nil end
		loadAddonFile(target, "Raid Management Addon/Modules/Strings.lua")
		loadAddonFile(target, "Raid Management Addon/Services/Spammer/Draft.lua")
		loadAddonFile(target, "Raid Management Addon/Services/Spammer/Runtime.lua")
		loadAddonFile(target, "Raid Management Addon/Controllers/Spammer.lua")
		return {
			bindFrame = bindFrame,
			scheduled = scheduled,
			sent = sent,
		}
	end

	local clearedStore = { Name = "stale", Message = "stale", Duration = "1", Channels = { "GUILD" } }
	local clearedFixture = installFixture(addon, clearedStore)
	addon.Controllers.Spammer:RequestClearDraft()
	clearedFixture.bindFrame()
	assertEqual("", _G.RMASpammerName:GetText(), "bound frame must load canonical clear without store repopulation")
	assertEqual("60", _G.RMASpammerDuration:GetText(), "bound frame must load canonical cleared duration")
	assertEqual("LFM", _G.RMASpammerOutput:GetText(), "bound frame must render canonical cleared preview")
	assertEqual(false, _G.RMASpammerStartBtn.enabled, "bound frame must apply cleared start-button state")

	local activeAddon = newAddon()
	local activeStore = { Name = "active headless", Message = "snapshot", Duration = "1", Channels = { "GUILD" } }
	local activeFixture = installFixture(activeAddon, activeStore)
	activeAddon.Controllers.Spammer:RequestStart()
	assertEqual(true, activeAddon.Services.Spammer.Runtime:GetState().ticking, "headless run must start")
	local pendingCallback = activeFixture.scheduled[1].callback
	activeAddon.Controllers.Spammer:RequestClearDraft()
	activeFixture.bindFrame()
	assertEqual("", _G.RMASpammerName:GetText(), "active headless clear must bind canonical fields")
	assertEqual(false, _G.RMASpammerName.enabled, "active headless bind must lock draft inputs")
	assertEqual(false, _G.RMASpammerClearBtn.enabled, "active headless bind must disable clear control")
	assertEqual(true, _G.RMASpammerStartBtn.enabled, "active headless bind must keep Stop enabled after clear")
	assertEqual("Stop", _G.RMASpammerStartBtn:GetText(), "active headless bind must render active stop action")
	pendingCallback()
	assertEqual(1, #activeFixture.sent, "pending active snapshot callback must still send")
	assertTrue(activeFixture.sent[1].output:find("active headless", 1, true) ~= nil, "active output snapshot must survive clear")
	assertTrue(activeFixture.sent[1].output:find("snapshot", 1, true) ~= nil, "active message snapshot must survive clear")
	activeAddon.Services.Spammer.Runtime:Pause()
	activeAddon.Controllers.Spammer:RequestRefresh()
	assertEqual(true, _G.RMASpammerStartBtn.enabled, "paused clear must keep Resume enabled")
	assertEqual("Resume", _G.RMASpammerStartBtn:GetText(), "paused clear must render Resume action")
	activeAddon.Controllers.Spammer:RequestStart()
	assertEqual(false, activeAddon.Services.Spammer.Runtime:GetState().paused, "Resume action must work with cleared draft")
	activeAddon.Controllers.Spammer:RequestStart()
	assertEqual(false, activeAddon.Services.Spammer.Runtime:GetState().ticking, "Stop action must work with cleared draft")
	print("PASS spammer_frame_binding_applies_uncached_clear_state")
end

function cases.spammer_channel_menu_normalizes_unavailable_saved_choices(addon)
	local store = {
		Name = "Ulduar 25",
		Message = "hard modes",
		Duration = "1",
		Channels = { "Trade", "OldChannel", "GUILD" },
	}
	local currentFrame, scaffoldSpec, setChannelCalls = nil, nil, {}
	local choices = {}

	local function assertSameChannels(expected, actual, message)
		assertEqual(#expected, #actual, message .. " count")
		for i = 1, #expected do
			assertEqual(expected[i], actual[i], message .. " at " .. i)
		end
	end

	local function assertChoice(value, checked, disabled)
		for i = 1, #choices do
			local choice = choices[i]
			if choice.value == value then
				assertEqual(checked, choice.checked, value .. " checked state differs")
				assertEqual(disabled, choice.disabled, value .. " disabled state differs")
				return choice
			end
		end
		error("missing channel choice: " .. value)
	end

	addon.L = {
		StrTank = "tank", StrHealer = "healer", StrMelee = "melee", StrRanged = "ranged",
		StrSpammerNeedStr = "need", StrSpammerChannelUnavailable = "%s (unavailable)",
		StrChannels = "Channels",
		BtnResume = "Resume", BtnStop = "Stop", BtnStart = "Start",
	}
	addon.Strings = { TrimText = function(value)
		return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
	end }
	addon.Database.SavedVariables = { GetSpammer = function() return store end }
	addon.Database.RequireServiceMethod = function(_, owner, method) return assert(owner[method]) end
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then addon.Services[owner][child] = addon.Services[owner][child] or {} end
	end
	addon.Services.Chat = { SendSpamOutput = function() return true end }
	addon.Timer = { BindMixin = function(target)
		function target:ScheduleRepeatingTimer() return {} end
		function target:CancelTimer() return true end
	end }
	addon.Controllers = {}

	local function newControl()
		return {
			text = "", enabled = true,
			GetText = function(self) return self.text end,
			SetText = function(self, value) self.text = tostring(value or "") end,
			SetTextColor = function() end, SetMaxLetters = function() end,
			SetAlpha = function() end, ClearFocus = function() end,
			SetEnabled = function(self, enabled) self.enabled = enabled == true end,
		}
	end
	local frame = { shown = true, IsShown = function(self) return self.shown end }
	local suffixes = {
		"Name", "Duration", "Tank", "TankClass", "Healer", "HealerClass", "Melee", "MeleeClass",
		"Ranged", "RangedClass", "Message", "Output", "Length", "Tick", "StartBtn", "ClearBtn", "ChannelMenu",
	}
	for i = 1, #suffixes do _G["RMASpammer" .. suffixes[i]] = newControl() end
	addon.UI = {
		Frames = {
			MakeModuleFrameGetter = function() return function() return currentFrame end end,
			BindModuleFrame = function() currentFrame = frame; return "RMASpammer" end,
			GetRef = function(_, suffix) return _G["RMASpammer" .. suffix] end,
			SetScriptSafely = function() end,
		},
		ModuleState = { Ensure = function() return { Localized = true } end },
		Scaffold = { DefineModule = function(spec)
			scaffoldSpec = spec
			spec.module.RequestRefresh = function() spec.refresh() end
		end },
		Primitives = { SetEnabled = function(control, enabled) if control then control.enabled = enabled == true end end, SetText = function() end },
		EditBoxes = { Reset = function(box) if box then box:SetText("") end end },
		Tooltips = {},
	}
	addon.WithinRange = function(value, minimum, maximum) return value >= minimum and value <= maximum end
	_G.GetChannelList = function() return 2, "Trade", 7, "LookingForGroup" end
	_G.IsInGuild = function() return false end
	_G.UIDropDownMenu_Initialize = function(menu, initialize) menu.initialize = initialize end
	_G.UIDropDownMenu_CreateInfo = function() return {} end
	_G.UIDropDownMenu_AddButton = function(info)
		local choice = {
			value = info.arg1,
			text = info.text,
			checked = info.checked == true,
			disabled = info.disabled == true,
		}
		choice.click = function(checked)
			if choice.disabled or _G.RMASpammerChannelMenu.enabled == false then
				return
			end
			choice.checked = checked == true
			info.func(choice, info.arg1, info.arg2, choice.checked)
		end
		choices[#choices + 1] = choice
	end
	_G.UIDropDownMenu_DisableDropDown = function(menu) menu.enabled = false end
	_G.UIDropDownMenu_EnableDropDown = function(menu) menu.enabled = true end
	_G.UIDropDownMenu_SetWidth = function(menu, width, padding)
		menu.dropdownWidth = width
		menu.dropdownPadding = padding
		menu.dropdownOuterWidth = width + (padding or 50)
	end
	_G.UIDropDownMenu_SetText = function(menu, text) menu.dropdownText = text end

	loadAddonFile(addon, "Raid Management Addon/Modules/Strings.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Draft.lua")
	local draft = addon.Services.Spammer.Draft
	local originalSetChannelChecked = draft.SetChannelChecked
	draft.SetChannelChecked = function(targetStore, channel, checked)
		setChannelCalls[#setChannelCalls + 1] = { channel = channel, checked = checked }
		return originalSetChannelChecked(targetStore, channel, checked)
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	loadAddonFile(addon, "Raid Management Addon/Controllers/Spammer.lua")

	scaffoldSpec.onLoad(frame)
	local refs = scaffoldSpec.acquireRefs(frame)
	scaffoldSpec.bind(nil, nil, refs)
	addon.Controllers.Spammer:RequestRefresh()
	assertTrue(type(_G.RMASpammerChannelMenu.initialize) == "function", "channel dropdown must be initialized")
	assertEqual(180, _G.RMASpammerChannelMenu.dropdownWidth, "channel dropdown content width differs")
	assertEqual(25, _G.RMASpammerChannelMenu.dropdownPadding, "channel dropdown padding differs")
	assertEqual(205, _G.RMASpammerChannelMenu.dropdownOuterWidth, "channel dropdown must fit its 205px layout region")
	assertEqual("Channels", _G.RMASpammerChannelMenu.dropdownText, "channel dropdown must show neutral visible text")
	_G.RMASpammerChannelMenu.initialize(1)

	assertChoice("Trade", true, false)
	local lookingForGroup = assertChoice("LookingForGroup", false, false)
	local oldChannel = assertChoice("OldChannel", false, true)
	local guild = assertChoice("GUILD", false, true)
	assertChoice("YELL", false, false)
	assertSameChannels({ "Trade" }, draft.GetChannels(store), "menu build did not remove unavailable saved preferences")
	local normalizationCallCount = #setChannelCalls

	oldChannel.click(true)
	guild.click(true)
	assertEqual(false, oldChannel.checked, "disabled custom row click must leave local state unchanged")
	assertEqual(false, guild.checked, "disabled guild row click must leave local state unchanged")
	assertEqual(normalizationCallCount, #setChannelCalls, "disabled rows must not update saved preferences")
	lookingForGroup.click(true)
	assertEqual(normalizationCallCount + 1, #setChannelCalls, "first live channel click must update saved preferences once")
	assertEqual("LookingForGroup", setChannelCalls[normalizationCallCount + 1].channel, "live channel click target differs")
	assertEqual(true, setChannelCalls[normalizationCallCount + 1].checked, "live channel click must add an unchecked choice")
	assertSameChannels({ "Trade", "LookingForGroup" }, draft.GetChannels(store), "live click did not add channel")
	lookingForGroup.click(false)
	assertEqual(normalizationCallCount + 2, #setChannelCalls, "second live channel click must update saved preferences once")
	assertEqual(false, setChannelCalls[normalizationCallCount + 2].checked, "second live channel click must remove the kept-open choice")
	assertSameChannels({ "Trade" }, draft.GetChannels(store), "second live click did not remove channel")

	addon.Controllers.Spammer:RequestStart()
	assertEqual(false, _G.RMASpammerChannelMenu.enabled, "active run must disable channel dropdown")
	lookingForGroup.click(true)
	assertEqual(false, lookingForGroup.checked, "locked live row click must leave local state unchanged")
	assertEqual(normalizationCallCount + 2, #setChannelCalls, "locked live row must not update saved preferences")
	addon.Controllers.Spammer:RequestStop()
	assertEqual(true, _G.RMASpammerChannelMenu.enabled, "stopped run must enable channel dropdown")

	local discoveryFailureCallCount = #setChannelCalls
	store.Channels = { "Trade" }
	choices = {}
	_G.GetChannelList = function() error("channel discovery failed") end
	_G.RMASpammerChannelMenu.initialize(1)
	assertSameChannels({ "Trade" }, draft.GetChannels(store), "failed channel discovery removed saved custom channel")
	assertEqual(discoveryFailureCallCount, #setChannelCalls, "failed discovery must not normalize custom channels")

	choices = {}
	_G.GetChannelList = nil
	_G.RMASpammerChannelMenu.initialize(1)
	assertSameChannels({ "Trade" }, draft.GetChannels(store), "missing channel API removed saved custom channel")
	assertEqual(discoveryFailureCallCount, #setChannelCalls, "missing discovery API must not normalize custom channels")
	print("PASS spammer_channel_menu_normalizes_unavailable_saved_choices")
end

function cases.chat_delivery_uses_live_destinations_and_reports_failures(addon)
	local sent, raidCount, partyCount, unitRank, inGuild, officerSpeak = {}, 0, 0, 0, false, false
	local channelRows = { 2, "Trade" }
	_G.SendAddonMessage = function() end
	_G.SendChatMessage = function(message, channel, language, target)
		if message == "throw" then error("chat unavailable") end
		if message == "false" then return false end
		sent[#sent + 1] = { message = message, channel = channel, target = target }
		return nil
	end
	_G.GetAddOnMetadata = function() return "test" end
	_G.UnitName = function() return "Tester" end
	_G.IsInInstance = function() return false, "none" end
	_G.GetNumRaidMembers = function() return raidCount end
	_G.GetNumPartyMembers = function() return partyCount end
	_G.GetChannelList = function() return unpack(channelRows) end
	_G.GetChannelName = function(name)
		for i = 1, #channelRows, 2 do
			if string.lower(tostring(channelRows[i + 1])) == string.lower(tostring(name)) then
				return channelRows[i], channelRows[i + 1]
			end
		end
		return 0, nil
	end
	_G.IsInGuild = function() return inGuild end
	_G.GetGuildInfo = function() return "Officer", "Officer", 1 end
	_G.GuildControlGetRankFlags = function() return true, true, true, officerSpeak end
	addon.L = {}
	addon.C = { CHAT_OUTPUT_FORMAT = "%s", CHAT_PREFIX_SHORT = "RMA", CHAT_PREFIX_HEX = "" }
	addon.Database.GetSyncer = function() return nil end
	addon.Database.GetRaidSchemaVersion = function() return 1 end
	addon.Database.GetUnitRank = function() return unitRank end
	addon.Strings = {
		NormalizeName = function(value) return value end,
		TrimText = function(value) return value end,
		FormatChatMessage = function(value) return value end,
	}
	addon.Timer = { BindMixin = function(target) target.ScheduleTimer = function() return {} end end }
	addon.Services.EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} end
	addon.Deformat = function() return nil end
	addon.Options = { GetValue = function() return false end }
	addon.GetGroupTypeAndCount = function()
		if raidCount > 0 then return "raid", raidCount end
		if partyCount > 0 then return "party", partyCount end
	end
	local localPrints = 0
	addon.info = function() localPrints = localPrints + 1 end
	loadAddonFile(addon, "Raid Management Addon/Modules/Comms.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Chat.lua")

	local ok, reason = addon.Comms.SendChat("lfm", "Trade")
	assertEqual(true, ok, "named channel must resolve at send time")
	assertEqual(2, sent[#sent].target, "initial live channel ID differs")
	channelRows = { 7, "Trade" }
	assertEqual(true, addon.Comms.SendChat("reload", "Trade"), "rejoined channel must send")
	assertEqual(7, sent[#sent].target, "send must not retain stale numeric channel ID")
	channelRows = { 7, "Trade", 9, "Trade" }
	ok, reason = addon.Comms.SendChat("ambiguous", "Trade")
	assertEqual(nil, ok, "ambiguous channel names must fail closed")
	assertEqual("ambiguous_channel", reason, "ambiguous channel reason differs")
	channelRows = {}
	ok, reason = addon.Comms.SendChat("missing", "Trade")
	assertEqual(nil, ok, "missing channel must fail closed")
	assertEqual("channel_unavailable", reason, "missing channel reason differs")

	ok, reason = addon.Comms.SendChat("party", "PARTY")
	assertEqual(nil, ok, "party transport outside a party must fail")
	partyCount = 1
	assertEqual(true, addon.Comms.SendChat("party", "PARTY"), "live party transport must send")
	partyCount, raidCount = 0, 1
	assertEqual(true, addon.Comms.SendChat("raid", "RAID"), "live raid transport must send")
	assertEqual(true, addon.Comms.SendChat("party", "PARTY"), "PARTY remains valid for a raid group on WotLK")
	ok, reason = addon.Comms.SendChat("warning", "RAID_WARNING")
	assertEqual(nil, ok, "raid warning must require current rank")
	unitRank = 1
	assertEqual(true, addon.Comms.SendChat("warning", "RAID_WARNING"), "promoted raid member may send raid warning")
	unitRank = 0
	local before = #sent
	raidCount = 0
	ok, reason = addon.Comms.SendChat("party", "PARTY")
	assertEqual(nil, ok, "party destination must be revalidated after leaving the group")
	assertEqual(before, #sent, "invalid transition must not call the API")
	raidCount = 1

	local detail
	ok, reason, detail = addon.Services.Chat:Announce("throw", "RAID")
	assertEqual(nil, ok, "failed RAID announcement must propagate transport failure")
	assertEqual("send_failed", reason, "failed RAID announcement reason differs")
	assertEqual(false, detail.sent, "failed announcement detail must not claim delivery")
	assertEqual("RAID", detail.channel, "failed announcement detail must preserve attempted channel")
	assertEqual(false, detail.fallback, "failed group delivery is not a local fallback")
	unitRank = 1
	ok, reason = addon.Services.Chat:Announce("false", "RAID_WARNING")
	assertEqual(nil, ok, "failed RAID_WARNING announcement must not report success")
	assertEqual("send_failed", reason, "failed raid-warning reason differs")
	unitRank, raidCount = 0, 0
	local printBefore = localPrints
	ok, reason, detail = addon.Services.Chat:Announce("local")
	assertEqual(true, ok, "outside-group announcement must preserve compatible success return")
	assertEqual(nil, reason, "outside-group fallback has no transport failure")
	assertEqual(false, detail.sent, "outside-group fallback must not claim a group delivery")
	assertEqual("LOCAL", detail.channel, "outside-group fallback channel differs")
	assertEqual(true, detail.fallback, "outside-group result must identify the fallback")
	assertEqual(printBefore + 1, localPrints, "outside-group fallback must print exactly once")
	ok, reason, detail = addon.Services.Chat:Announce(string.rep("x", 256), "RAID")
	assertEqual(nil, ok, "oversized slash/API announcement must fail before transport")
	assertEqual("too_long", reason, "oversized announcement reason differs")
	assertEqual(false, detail.sent, "oversized announcement must not claim delivery")
	raidCount = 1

	ok, reason = addon.Comms.SendChat("guild", "GUILD")
	assertEqual(nil, ok, "guild transport outside a guild must fail")
	inGuild = true
	assertEqual(true, addon.Comms.SendChat("guild", "GUILD"), "guild member may send guild chat")
	ok, reason = addon.Comms.SendChat("officer", "OFFICER")
	assertEqual(nil, ok, "officer chat needs current rank permission")
	officerSpeak = true
	assertEqual(true, addon.Comms.SendChat("officer", "OFFICER"), "officer permission must be evaluated live")
	ok, reason = addon.Comms.SendChat("throw", "GUILD")
	assertEqual(nil, ok, "throwing chat API must fail safely")
	assertEqual("send_failed", reason, "throwing API reason differs")
	ok, reason = addon.Comms.SendChat("false", "GUILD")
	assertEqual(nil, ok, "explicit false API result must fail")

	channelRows = { 4, "Trade" }
	local attemptsBefore = #sent
	ok, reason = addon.Services.Chat:SendSpamOutput("multi", { "GUILD", "Missing", "Trade" })
	assertEqual(nil, ok, "partial multi-destination delivery must report failure")
	assertEqual("channel_unavailable", reason, "aggregate delivery must preserve first concrete failure")
	assertEqual(attemptsBefore + 2, #sent, "aggregate delivery must attempt every valid destination exactly once")
	addon.Services.Chat.Announce = function() return nil, "send_failed" end
	ok, reason = addon.Services.Chat:AnnounceWarningMessage("warning")
	assertEqual(nil, ok, "warning facade must propagate announcement failure")
	assertEqual("send_failed", reason, "warning facade failure reason differs")
	print("PASS chat_delivery_uses_live_destinations_and_reports_failures")
end

function cases.loot_award_freezes_roll_intake(addon)
	local Rolls, lootState, scheduled = installLootHardeningRollsFixture(addon)
	local itemLink = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Test Item]|h|r"
	local session = Rolls:EnsureRollSession(itemLink, addon.C.rollTypes.FREE, "lootWindow")
	assertTrue(session and session.active == true, "roll session must start active")
	Rolls:SetExpectedWinners(2)

	Rolls:SetRollRecordingEnabled(true)
	assertTrue(Rolls:SubmitDebugRoll("Winner", 90), "initial roll must enter")
	assertTrue(Rolls:SubmitDebugRoll("Runner", 80), "second roll must enter")
	local beforeFreeze = Rolls:GetDisplayModel()
	assertEqual("Winner", Rolls:GetResolvedWinner(beforeFreeze), "initial winner differs")
	assertTrue(Rolls:StartCountdown(1, nil, function()
		Rolls:SetRollRecordingEnabled(true)
	end), "countdown must start")
	local staleCountdownEnd = scheduled[#scheduled].callback
	staleCountdownEnd()
	local _, expiredRecord, expiredCanRoll = Rolls:GetRollStatus()
	assertEqual(true, expiredRecord, "non-blocking countdown expiry must leave intake open")
	assertEqual(true, expiredCanRoll, "non-blocking countdown expiry must accept rolls")

	local frozen, reason = Rolls:FreezeRollIntake("award")
	assertTrue(frozen ~= nil, reason or "freeze failed")
	assertEqual("award", reason, "freeze reason differs")
	local _, record, canRoll = Rolls:GetRollStatus()
	assertEqual(false, record, "award freeze must stop recording")
	assertEqual(false, canRoll, "award freeze must close intake")
	assertEqual(false, session.active, "award freeze must close the session window")
	assertTrue(session.endsAt ~= nil, "award freeze must record the closed session time")
	assertEqual(session, Rolls:GetRollSession(), "frozen session context must remain available to award consumers")
	local rebuilt = Rolls:GetDisplayModel()
	assertEqual("Winner", Rolls:GetResolvedWinner(rebuilt), "forced rebuild lost frozen winner")
	local rebuiltAgain = Rolls:GetDisplayModel()
	assertEqual("Winner", Rolls:GetResolvedWinner(rebuiltAgain), "repeated rebuild lost frozen winner")
	local frozenAgain, retryReason = Rolls:FreezeRollIntake("award_retry")
	assertTrue(frozenAgain ~= nil, retryReason or "repeated freeze rejected the retained session")
	assertEqual("award_retry", retryReason, "repeated freeze reason differs")
	assertEqual("Winner", Rolls:GetResolvedWinner(frozenAgain), "repeated freeze lost the frozen winner")
	assertEqual(2, frozenAgain.requiredWinnerCount, "repeated freeze lost the winner selection count")
	assertEqual(2, #frozenAgain.rows, "repeated freeze lost the frozen roll selection")
	local _, retryRecord, retryCanRoll = Rolls:GetRollStatus()
	assertEqual(false, retryRecord, "repeated freeze reopened roll recording")
	assertEqual(false, retryCanRoll, "repeated freeze reopened roll intake")
	assertEqual(false, session.active, "repeated freeze reactivated the roll session")

	local selectionState = {}
	local selected = {}
	local selection = {
		EnsureState = function()
			for key in pairs(selected) do selected[key] = nil end
		end,
		SetAnchor = function(_, name) selectionState.anchor = name end,
		GetAnchor = function() return selectionState.anchor end,
		GetCount = function()
			local count = 0
			for _ in pairs(selected) do count = count + 1 end
			return count
		end,
		GetSelected = function()
			local names = {}
			for name in pairs(selected) do names[#names + 1] = name end
			table.sort(names)
			return names
		end,
		IsSelected = function(_, name) return selected[name] == true end,
		Toggle = function(_, name, preserve)
			if not preserve then
				for key in pairs(selected) do selected[key] = nil end
			end
			selected[name] = not selected[name]
		end,
	}
	local rollRows = {
		IsSelectableRow = function(row) return row and row.selectionAllowed ~= false end,
		BuildSelectionState = function(opts)
			local winners = opts.selectedWinners or {}
			return {
				pickMode = opts.selectionAllowed == true,
				msCount = #winners,
				winnerName = #winners == 1 and winners[1].name or nil,
				selectionAllowed = opts.selectionAllowed == true,
			}
		end,
		BuildModel = function(opts) return opts.rows, opts.rows end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/RollSelection.lua")
	local rollSelection = addon.Services.Master.RollSelection.CreateController({
		getDisplayModel = function() return Rolls:GetDisplayModel() end,
		getSessionKey = function()
			local current = Rolls:GetRollSession()
			return current and current.id or nil
		end,
		isFromInventory = function() return true end,
		rollRows = rollRows,
		selection = selection,
		state = {},
	})
	local selectionModel = rollSelection:BuildModel(true)
	assertEqual(2, rollSelection:GetSelectedCount(), "forced selection rebuild lost selected count")
	local selectedWinners = rollSelection:GetSelectedWinnersOrdered(selectionModel.rows)
	assertEqual("Winner", selectedWinners[1].name, "forced selection rebuild changed first selected winner")
	assertEqual(90, selectedWinners[1].roll, "forced selection rebuild lost winner roll")
	assertEqual("Runner", selectedWinners[2].name, "forced selection rebuild changed second selected winner")

	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardSequence.lua")
	local assignedRoll
	local awardSequence = addon.Services.Master.AwardSequence.CreateController({
		awardPlanner = {
			BuildMultiAwardWinnersPlan = function(opts)
				return { winners = opts.pickedWinners }
			end,
			BuildMultiAwardState = function() return { state = nil } end,
		},
		inventory = { BuildMultiAwardSlotCandidates = function() return {}, {} end },
		lootState = lootState,
		rollSelection = rollSelection,
		scheduleTimer = function() return {} end,
		cancelTimer = function() end,
		registerAwardedItem = function() end,
		awardExecutor = { Assign = function(_, _, _, _, roll) assignedRoll = roll return true end },
		itemCount = { Set = function() end, Reset = function() end },
		createAttempt = function()
			return { Confirm = function() return true end, Fail = function() return true end }
		end,
		getRollSessionId = function() return session.id end,
		getItemKey = function() return "item:19019" end,
		getRaidNid = function() return 1 end,
	})
	local planned = awardSequence:BuildWinners(2)
	assertEqual(2, #planned, "AwardSequence lost frozen multi-selection")
	assertEqual("Winner", planned[1].name, "AwardSequence changed first frozen winner")
	assertTrue(awardSequence:TrySingleCopy(itemLink, "Winner"), "single award lookup must execute")
	assertEqual(90, assignedRoll, "single award lookup lost frozen winner roll")

	Rolls:CHAT_MSG_SYSTEM("LatePlayer 100")
	staleCountdownEnd()
	local _, recordAfter, canRollAfter = Rolls:GetRollStatus()
	assertEqual(false, recordAfter, "stale countdown callback reopened recording")
	assertEqual(false, canRollAfter, "stale countdown callback reopened intake")
	assertEqual("Winner", Rolls:GetResolvedWinner(rebuiltAgain), "late roll changed frozen winner")
	assertEqual(2, #Rolls:GetRolls(), "late roll mutated frozen history")
	Rolls:SetRollRecordingEnabled(true)
	local replacement = Rolls:GetRollSession()
	assertTrue(replacement ~= session, "new intake must replace the frozen session")
	assertTrue(replacement.active == true, "replacement session must be active")
	Rolls:ClearRolls()
	assertEqual(nil, Rolls:GetRollSession(), "normal clear must detach the replacement session")
	local missing, missingReason = Rolls:FreezeRollIntake("award")
	assertEqual(nil, missing, "freeze without a retained session must fail")
	assertEqual("no_active_roll_session", missingReason, "missing-session freeze reason differs")
	print("PASS loot_award_freezes_roll_intake")
end

function cases.loot_duplicate_award_is_rejected_in_flight(addon)
	local admissions = {
		{ "button", function(fixture) return fixture.master._Private.BtnAward(nil, nil) end },
		{ "manual-grid", function(fixture)
			return fixture.master._Private.AcceptManualGridAward({
				itemLink = "item:19019",
				playerName = "Winner",
				rollType = 4,
				rollValue = 90,
			})
		end },
		{ "hold", function(fixture) return fixture.master._Private.BtnHold(nil, nil) end },
		{ "single", function(fixture) return fixture.awardSequence:TrySingleCopy("item:19019", "Winner") end },
		{ "multi", function(fixture)
			return fixture.awardSequence:Start("item:19019", 2, {
				{ name = "Winner", roll = 90 },
				{ name = "Runner", roll = 80 },
			})
		end },
	}
	for i = 1, #admissions do
		local name, enter = admissions[i][1], admissions[i][2]
		local admitted = installLootHardeningMasterFixture(newAddon())
		local ok, reason = enter(admitted)
		assertTrue(ok, name .. " admission failed: " .. tostring(reason))
		assertEqual(1, admitted.attempts, name .. " admission created the wrong attempt count")
		assertEqual(1, admitted.assignments, name .. " admission created the wrong physical effect count")
		assertEqual(1, admitted.timers, name .. " admission created the wrong confirmation timer count")
	end

	local fixture = installLootHardeningMasterFixture(addon)
	local master = fixture.master
	local confirmation = master._awardConfirmation
	local pendingEffect = {
		RunCheckpoint = function(_, _, callback, ...) return callback(...) end,
		Confirm = function() return true end,
		Fail = function() return true end,
	}
	assertTrue(confirmation:Queue({
		itemLink = "item:19019",
		itemIndex = 1,
		playerName = "Winner",
		effect = pendingEffect,
	}), "initial confirmation must enter")
	local baselineTimers = fixture.timers
	local baselineAttempts = fixture.attempts

	local ok, reason = master._Private.BtnAward(nil, nil)
	assertEqual(nil, ok, "button reentry must fail closed")
	assertEqual("award_in_flight", reason, "button reentry reason differs")
	ok, reason = master._Private.AcceptManualGridAward({ itemLink = "item:19019", playerName = "Winner" })
	assertEqual(nil, ok, "manual-grid reentry must fail closed")
	assertEqual("award_in_flight", reason, "manual-grid reentry reason differs")
	ok, reason = master._Private.BtnHold(nil, nil)
	assertEqual(nil, ok, "direct assignment reentry must fail closed")
	assertEqual("award_in_flight", reason, "direct assignment reentry reason differs")
	ok, reason = fixture.awardSequence:TrySingleCopy("item:19019", "Winner")
	assertEqual(nil, ok, "single sequence reentry must fail closed")
	assertEqual("award_in_flight", reason, "single sequence reentry reason differs")
	ok, reason = fixture.awardSequence:Start("item:19019", 2, { { name = "Winner", roll = 90 }, { name = "Runner", roll = 80 } })
	assertEqual(nil, ok, "multi sequence reentry must fail closed")
	assertEqual("award_in_flight", reason, "multi sequence reentry reason differs")
	assertEqual(0, fixture.assignments, "duplicate award reached physical assignment")
	assertEqual(baselineAttempts, fixture.attempts, "duplicate award created another attempt")
	assertEqual(baselineTimers, fixture.timers, "duplicate award created another timer")

	assertTrue(confirmation:Confirm(1), "first award must confirm")
	assertEqual(false, confirmation:HasInFlight(), "confirmation must release in-flight guard")
	assertTrue(fixture.awardSequence:Start(
		"item:19019",
		2,
		{ { name = "Winner", roll = 90 }, { name = "Runner", roll = 80 } }
	), "confirmed multi sequence must start")
	assertEqual(1, fixture.assignments, "first legitimate multi assignment did not execute")
	assertTrue(confirmation:Confirm(1), "first multi assignment must confirm")
	local checkpoints = fixture.lastAttempt:GetState().checkpoints
	assertEqual(true, checkpoints.provisional_attribution, "provisional attribution checkpoint differs")
	assertEqual(true, checkpoints.distribution_notification, "distribution notification checkpoint differs")
	assertEqual(true, checkpoints.player_counter, "player counter checkpoint differs")
	assertTrue(fixture.awardSequence:ContinueOnLootSlotCleared(1), "next multi assignment must schedule")
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(2, fixture.assignments, "legitimate next multi assignment did not execute")
	assertEqual(baselineAttempts + 2, fixture.attempts, "legitimate multi entries must create exactly two attempts")
	print("PASS loot_duplicate_award_is_rejected_in_flight")
end

function cases.loot_direct_assignment_admits_before_mutation(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local effect = { MarkUncertain = function() end, Fail = function() end }
	assertTrue(fixture.master._awardConfirmation:Queue({
		itemLink = "item:19019", itemIndex = 1, playerName = "Winner", effect = effect,
	}), "fixture must own one pending award")
	local assignmentsBefore = fixture.assignments
	local rollTypeBefore = fixture.lootState.currentRollType
	local timersBefore = fixture.timers
	local admitted, reason = fixture.master._Private.BtnHold(nil, "LeftButton")
	assertEqual(nil, admitted, "direct assignment must reject")
	assertEqual("award_in_flight", reason, "admission reason differs")
	assertEqual(assignmentsBefore, fixture.assignments, "rejected admission assigned loot")
	assertEqual(rollTypeBefore, fixture.lootState.currentRollType, "rejected admission changed roll type")
	assertEqual(timersBefore, fixture.timers, "rejected admission changed timer ownership")
	print("PASS loot_direct_assignment_admits_before_mutation")
end

function cases.loot_direct_assignment_rejects_in_flight_trade_before_mutation(addon)
	local entries = {
		{ "hold", function(fixture) return fixture.master._Private.BtnHold(nil, "LeftButton") end },
		{ "bank", function(fixture) return fixture.master._Private.BtnBank(nil, "LeftButton") end },
		{ "disenchant", function(fixture) return fixture.master._Private.BtnDisenchant(nil, "LeftButton") end },
	}
	for i = 1, #entries do
		local fixture = installLootHardeningMasterFixture(i == 1 and addon or newAddon())
		fixture.tradeInFlight = true
		local assignmentsBefore = fixture.assignments
		local rollTypeBefore = fixture.lootState.currentRollType
		local timersBefore = fixture.timers
		local refreshesBefore = fixture.refreshCalls
		local admitted, reason = entries[i][2](fixture)
		assertEqual(nil, admitted, entries[i][1] .. " direct assignment must reject")
		assertEqual("trade_in_flight", reason, entries[i][1] .. " admission reason differs")
		assertEqual(assignmentsBefore, fixture.assignments, entries[i][1] .. " rejection assigned loot")
		assertEqual(rollTypeBefore, fixture.lootState.currentRollType, entries[i][1] .. " rejection changed roll type")
		assertEqual(timersBefore, fixture.timers, entries[i][1] .. " rejection changed timer ownership")
		assertEqual(refreshesBefore, fixture.refreshCalls, entries[i][1] .. " rejection refreshed UI state")
	end
	print("PASS loot_direct_assignment_rejects_in_flight_trade_before_mutation")
end

function cases.loot_award_prerequisites_and_sequence_retry_are_ordered(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local sequence = fixture.awardSequence
	local confirmation = fixture.master._awardConfirmation
	fixture.lootState.selectedItemCount = 3
	assertTrue(sequence:Start("item:19019", 3, {
		{ name = "Winner", roll = 90 },
		{ name = "Runner", roll = 80 },
		{ name = "Third", roll = 70 },
	}), "multi award must start")

	fixture.rejectDistribution = true
	local confirmed = confirmation:Confirm(1)
	assertEqual(nil, confirmed, "distribution rejection must retain confirmation")
	assertEqual(0, fixture.counterCalls, "counter ran before distribution prerequisite")
	assertEqual(nil, fixture.lootState.itemTraded, "sequence advanced before distribution prerequisite")
	assertEqual(2, fixture.lootState.multiAward.pos, "sequence position changed before prerequisites")

	fixture.rejectDistribution = false
	fixture.rejectCounter = true
	confirmed = confirmation:Confirm(1)
	assertEqual(nil, confirmed, "counter rejection must retain confirmation")
	assertEqual(2, fixture.distributionCalls, "failed distribution should retry once")
	assertEqual(1, fixture.counterCalls, "counter attempt count differs")
	assertEqual(nil, fixture.lootState.itemTraded, "sequence advanced before counter prerequisite")

	fixture.rejectCounter = false
	assertEqual(true, confirmation:Confirm(1), "prerequisite retry must confirm")
	assertEqual(2, fixture.distributionCalls, "completed distribution checkpoint repeated")
	assertEqual(2, fixture.counterCalls, "counter retry count differs")
	assertEqual(1, fixture.lootState.itemTraded, "register checkpoint did not run once")

	assertTrue(sequence:ContinueOnLootSlotCleared(1), "next award must schedule")
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(2, fixture.assignments, "second award did not execute")
	fixture.throwRefresh = true
	assertEqual(nil, confirmation:Confirm(1), "refresh throw must remain retryable")
	assertEqual(2, fixture.lootState.itemTraded, "register checkpoint did not commit before refresh failure")
	assertEqual(3, fixture.lootState.multiAward.pos, "position checkpoint did not commit before refresh failure")
	fixture.throwRefresh = false
	assertEqual(true, confirmation:Confirm(1), "refresh retry must complete")
	assertEqual(3, fixture.distributionCalls, "completed distribution checkpoint repeated during sequence retries")
	assertEqual(3, fixture.counterCalls, "completed counter checkpoint repeated during sequence retries")
	local state = fixture.lastAttempt:GetState()
	assertEqual(true, state.checkpoints.sequence_register_awarded_item, "register checkpoint missing")
	assertEqual(true, state.checkpoints.sequence_position_advance, "position checkpoint missing")
	assertEqual(true, state.checkpoints.sequence_progress_timeout, "progress timeout checkpoint missing")
	assertEqual(true, state.checkpoints.sequence_refresh, "refresh checkpoint missing")
	print("PASS loot_award_prerequisites_and_sequence_retry_are_ordered")
end

function cases.loot_award_finalize_and_single_reset_are_retry_safe(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	fixture.announceOnWin = true
	local confirmation = fixture.master._awardConfirmation
	assertTrue(fixture.awardSequence:Start("item:19019", 1, { { name = "Winner", roll = 90 } }), "final multi award must start")
	fixture.throwAnnouncement = true
	assertEqual(nil, confirmation:Confirm(1), "announcement throw must remain retryable")
	assertTrue(fixture.lootState.multiAward ~= nil, "announcement failure cleared multi state")
	fixture.throwAnnouncement = false
	fixture.throwItemReset = true
	local resetConfirmed, resetReason = confirmation:Confirm(1)
	assertEqual(nil, resetConfirmed, "item reset throw must remain retryable")
	assertTrue(tostring(resetReason):find("item reset exploded", 1, true) ~= nil, "unexpected reset failure: " .. tostring(resetReason))
	assertEqual(nil, fixture.lootState.multiAward, "state clear did not commit before reset failure")
	assertEqual(1, fixture.itemResetCalls, "first item reset attempt count differs")
	assertEqual(true, confirmation:Confirm(1), "item reset retry must confirm")
	assertEqual(2, fixture.announcementCalls, "successful announcement repeated after reset retry")
	assertEqual(2, fixture.itemResetCalls, "item reset retry count differs")
	local checkpoints = fixture.lastAttempt:GetState().checkpoints
	assertEqual(true, checkpoints.sequence_cancel_progress_timeout, "timeout cancel checkpoint missing")
	assertEqual(true, checkpoints.sequence_cancel_delay, "delay cancel checkpoint missing")
	assertEqual(true, checkpoints.sequence_clear_state, "state clear checkpoint missing")
	assertEqual(true, checkpoints.sequence_item_count_reset, "item reset checkpoint missing")

	local single = installLootHardeningMasterFixture(addon)
	local singleConfirmation = single.master._awardConfirmation
	assertTrue(single.awardSequence:TrySingleCopy("item:19019", "Winner"), "single award must start")
	single.throwItemReset = true
	assertEqual(nil, singleConfirmation:Confirm(1), "single reset throw must remain retryable")
	assertEqual(true, singleConfirmation:Confirm(1), "single reset retry must confirm")
	assertEqual(2, single.itemResetCalls, "single reset retry count differs")
	assertEqual(true, single.lastAttempt:GetState().checkpoints.single_item_count_reset, "single reset checkpoint missing")
	print("PASS loot_award_finalize_and_single_reset_are_retry_safe")
end

function cases.loot_multi_award_cancellation_preserves_current_and_future_admission(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local sequence = fixture.awardSequence
	local confirmation = fixture.master._awardConfirmation
	fixture.mutateSelectedCountOnReset = true
	fixture.lootState.selectedItemCount = 3
	fixture.windowItemCount = 2
	assertTrue(sequence:Start("item:19019", 3, {
		{ name = "Winner", roll = 90 },
		{ name = "Runner", roll = 80 },
		{ name = "Third", roll = 70 },
	}), "multi award must start")
	assertEqual(true, confirmation:Confirm(1), "first award must confirm")
	assertEqual(1, fixture.lootState.itemTraded, "first confirmed award count differs")
	local cancelledBeforeContinuation = #fixture.cancelledTimerHandles
	fixture.windowItemCount = 1
	assertTrue(sequence:ContinueOnLootSlotCleared(1), "next award delay must schedule")
	local refreshBeforeCancel = fixture.refreshCalls
	local cancelled, reason = sequence:CancelRemaining("operator")
	assertEqual(true, cancelled, "future awards must be cancellable during delay")
	assertEqual(nil, reason, "completed current award must not report in-flight ownership")
	assertEqual(refreshBeforeCancel + 1, fixture.refreshCalls, "cancellation must refresh exactly once")
	assertEqual(1, fixture.lootState.itemTraded, "cancellation changed confirmed award count")
	assertEqual(1, fixture.lootState.selectedItemCount, "fixture did not model cancellation item-count reset")
	assertEqual(nil, fixture.lootState.multiAward, "cancellation retained future sequence state")
	assertEqual(cancelledBeforeContinuation + 2, #fixture.cancelledTimerHandles, "progress and delay handles were not both cancelled")
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(1, fixture.assignments, "cancelled delay started the next winner")

	fixture.windowItemCount = 2
	assertTrue(sequence:Start("item:19019", 2, {
		{ name = "Fresh", roll = 70 }, { name = "FreshTwo", roll = 60 },
	}), "fresh sequence must be admitted")
	assertEqual(2, fixture.assignments, "fresh sequence did not execute")
	assertEqual(nil, fixture.lootState.itemTraded, "fresh sequence inherited canceled sequence progress")
	assertEqual(true, confirmation:Confirm(1), "fresh first award must confirm")
	assertEqual(1, fixture.lootState.itemTraded, "fresh sequence reset before its own target")
	fixture.windowItemCount = 1
	assertTrue(sequence:ContinueOnLootSlotCleared(2), "fresh second award must schedule")
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(true, confirmation:Confirm(1), "fresh second award must confirm")
	assertEqual(0, fixture.lootState.itemTraded, "fresh sequence did not reset at its own terminal target")
	assertEqual(1, fixture.rollClearCalls or 0, "fresh sequence cleared rolls before or after its own terminal point")

	local waiting = installLootHardeningMasterFixture(newAddon())
	waiting.lootState.selectedItemCount = 2
	assertTrue(waiting.awardSequence:Start("item:19019", 2, {
		{ name = "Winner", roll = 90 }, { name = "Runner", roll = 80 },
	}), "progress-timeout sequence must start")
	assertEqual(true, waiting.master._awardConfirmation:Confirm(1), "progress-timeout current award must confirm")
	local cancelledBeforeTimeout = #waiting.cancelledTimerHandles
	local timeoutRefreshes = waiting.refreshCalls
	assertEqual(true, waiting.awardSequence:CancelRemaining("operator"), "progress timeout must be cancellable")
	assertEqual(cancelledBeforeTimeout + 1, #waiting.cancelledTimerHandles, "progress timeout handle was not cancelled")
	assertEqual(timeoutRefreshes + 1, waiting.refreshCalls, "timeout cancellation must refresh exactly once")
	waiting.timerCallbacks[#waiting.timerCallbacks]()
	assertEqual(1, waiting.assignments, "cancelled progress timeout started the next winner")

	local current = installLootHardeningMasterFixture(newAddon())
	current.lootState.selectedItemCount = 2
	current.mutateSelectedCountOnReset = true
	assertTrue(current.awardSequence:Start("item:19019", 2, {
		{ name = "Winner", roll = 90 }, { name = "Runner", roll = 80 },
	}), "current-attempt sequence must start")
	local currentCancelled, currentReason = current.awardSequence:CancelRemaining("operator")
	assertEqual(true, currentCancelled, "future entries must cancel while current award is irreversible")
	assertEqual("current_award_in_flight", currentReason, "cancellation must disclose current award ownership")
	assertEqual(1, current.assignments, "cancellation pretended to reverse current assignment")
	assertEqual(true, current.master._awardConfirmation:Confirm(1), "current award must retain confirmation ownership")
	assertEqual(1, current.lootState.itemTraded, "current confirmed award was not preserved")
	assertEqual(false, current.awardSequence:ContinueOnLootSlotCleared(1), "cancelled sequence continued")
	current.windowItemCount = 2
	assertTrue(current.awardSequence:Start("item:19019", 2, {
		{ name = "Fresh", roll = 70 }, { name = "FreshTwo", roll = 60 },
	}), "fresh sequence after current terminal must start")
	assertEqual(nil, current.lootState.itemTraded, "fresh sequence after current terminal inherited old progress")
	assertEqual(true, current.master._awardConfirmation:Confirm(1), "fresh current first award must confirm")
	assertEqual(1, current.lootState.itemTraded, "fresh current sequence reset too early")
	current.windowItemCount = 1
	assertTrue(current.awardSequence:ContinueOnLootSlotCleared(2), "fresh current second award must schedule")
	current.timerCallbacks[#current.timerCallbacks]()
	assertEqual(true, current.master._awardConfirmation:Confirm(1), "fresh current second award must confirm")
	assertEqual(0, current.lootState.itemTraded, "fresh current sequence did not reset at terminal target")
	assertEqual(1, current.rollClearCalls or 0, "fresh current sequence roll reset count differs")
	print("PASS loot_multi_award_cancellation_preserves_current_and_future_admission")
end

function cases.loot_multi_award_clear_button_is_truthful(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	addon.L.BtnCancelRemainingAwards = "Cancel Remaining Awards"
	addon.L.TipMasterCancelRemainingAwards = "Cancel future awards; the current transfer may still finish."
	local buttonState = addon.Services.Master.ButtonState
	fixture.lootState.multiAward = { active = true, cancelled = false }
	local state = buttonState.BuildState({
		lootState = fixture.lootState,
		tooltipState = { clear = "Clear recorded rolls." },
		hasLootAccess = false,
		workflowState = {},
	})
	assertEqual("Cancel Remaining Awards", state.clearText, "active multi-award clear label differs")
	assertEqual(addon.L.TipMasterCancelRemainingAwards, state.clearTooltip, "active multi-award tooltip differs")
	assertEqual(true, state.canClear, "active multi-award cancellation must remain available")

	local clearRollCalls = 0
	addon.Services.Rolls.ClearRolls = function() clearRollCalls = clearRollCalls + 1 end
	local cancelCalls = 0
	fixture.awardSequence.CancelRemaining = function(_, cancelReason)
		cancelCalls = cancelCalls + 1
		assertEqual("operator", cancelReason, "button cancellation reason differs")
		return true
	end
	assertEqual(true, fixture.master._Private.BtnClear(nil, nil), "active clear must return cancellation result")
	assertEqual(1, cancelCalls, "active clear did not delegate to AwardSequence")
	assertEqual(0, clearRollCalls, "active clear erased rolls")
	fixture.lootState.multiAward = nil
	fixture.master._Private.BtnClear(nil, nil)
	assertEqual(1, clearRollCalls, "normal clear-roll behavior changed")
	print("PASS loot_multi_award_clear_button_is_truthful")
end

function cases.loot_slot_clear_perf_spans_close_on_all_exits(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local finishes = {}
	local starts = 0
	addon.hasPerf = true
	addon._PerfStart = function()
		starts = starts + 1
		return starts
	end
	addon._PerfFinish = function(_, label)
		finishes[#finishes + 1] = label
	end
	fixture.windowItemCount = 1
	assertTrue(fixture.awardSequence:Start("item:19019", 2, {
		{ name = "Winner", roll = 90 }, { name = "Runner", roll = 80 },
	}), "perf sequence must start")
	assertEqual(true, fixture.master:LOOT_SLOT_CLEARED(1), "auto-managed continuation must return its result")
	local finishCounts = {}
	for i = 1, #finishes do finishCounts[finishes[i]] = (finishCounts[finishes[i]] or 0) + 1 end
	assertEqual(1, finishCounts["Master.LOOT_SLOT_CLEARED ContinueAward"], "continuation span did not close")
	assertEqual(1, finishCounts["Master.LOOT_SLOT_CLEARED Total"], "total span did not close")

	fixture.master._awardConfirmation.Confirm = function() return nil, "retry" end
	finishes = {}
	local ok, failureReason = fixture.master:LOOT_SLOT_CLEARED(1)
	assertEqual(nil, ok, "failed confirmation must preserve nil result")
	assertEqual("retry", failureReason, "failed confirmation reason differs")
	local closedTotal = false
	for i = 1, #finishes do
		if finishes[i] == "Master.LOOT_SLOT_CLEARED Total" then closedTotal = true end
	end
	assertEqual(true, closedTotal, "failed confirmation exit did not close total span")
	print("PASS loot_slot_clear_perf_spans_close_on_all_exits")
end

function cases.loot_multi_award_twenty_slot_work_is_bounded(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local winners = {}
	for i = 1, 20 do winners[i] = { name = "Winner" .. tostring(i), roll = 101 - i } end
	fixture.windowItemCount = 20
	assertTrue(fixture.awardSequence:Start("item:19019", 20, winners), "bounded sequence must start")
	for i = 1, 20 do
		assertEqual(true, fixture.master._awardConfirmation:Confirm(1), "bounded confirmation failed at " .. tostring(i))
		if i < 20 then
			fixture.windowItemCount = 20 - i
			assertTrue(fixture.awardSequence:ContinueOnLootSlotCleared(i), "bounded continuation failed at " .. tostring(i))
			fixture.timerCallbacks[#fixture.timerCallbacks]()
		end
	end
	assertEqual(19, fixture.lootCountScans, "loot count scans exceed one per continuation")
	assertEqual(20, fixture.candidateScans, "candidate scans exceed initial plus one per continuation")
	assertEqual(20, fixture.distributionCalls, "RMADist completion sends differ from confirmed awards")
	assertEqual(39, fixture.refreshCalls, "refresh requests differ from one transition plus one confirmation per later award")
	print("PASS loot_multi_award_twenty_slot_work_is_bounded scans=19 candidates=20 sends=20 refreshes=39")
end

function cases.loot_slot_clear_stops_after_matched_confirmation_failure(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local confirmation = fixture.master._awardConfirmation
	local continueCalls = 0
	local continue = fixture.awardSequence.ContinueOnLootSlotCleared
	fixture.awardSequence.ContinueOnLootSlotCleared = function(self, slot)
		continueCalls = continueCalls + 1
		return continue(self, slot)
	end
	fixture.rejectDistribution = true
	assertTrue(fixture.awardSequence:Start("item:19019", 2, {
		{ name = "Winner", roll = 90 }, { name = "Runner", roll = 80 },
	}), "multi award must start")
	local result = fixture.master:LOOT_SLOT_CLEARED(1)
	assertEqual(nil, result, "matched failed confirmation must stop slot processing")
	assertEqual(0, continueCalls, "failed confirmation continued the multi award")
	assertEqual(0, fixture.fetchCalls or 0, "failed confirmation reset loot-window state")
	assertEqual(true, confirmation:HasInFlight(), "failed confirmation lost ownership")
	fixture.timerCallbacks[1]()
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(false, confirmation:HasInFlight(), "unresolved controller confirmation retained ownership")
	assertEqual(nil, fixture.lootState.multiAward, "unresolved controller confirmation kept future multi entries")
	assertEqual("failed", fixture.lastAttempt:GetState().state, "present target timeout must become a known failure")
	print("PASS loot_slot_clear_stops_after_matched_confirmation_failure")
end

function cases.loot_award_confirmation_expiry_is_bounded(addon)
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardAttempt.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardConfirmation.lua")
	local scheduled, warnings, refreshes, unresolved, success, cancelled = {}, 0, 0, 0, 0, 0
	local effect = addon.Services.Master.AwardAttempt.CreateExecuting({
		onConfirm = function() success = success + 1 return true end,
		onFail = function() cancelled = cancelled + 1 return true end,
	})
	local owner = addon.Services.Master.AwardConfirmation.Create({
		timeoutSeconds = 4,
		reconciliationSeconds = 8,
		scheduleTimer = function(callback, delay) scheduled[#scheduled + 1] = { callback = callback, delay = delay } return callback end,
		cancelTimer = function() end,
		requestRefresh = function() refreshes = refreshes + 1 end,
		warnFailure = function() warnings = warnings + 1 end,
		warnUncertain = function() warnings = warnings + 1 end,
		warnTimeout = function() warnings = warnings + 1 end,
		warnUnresolved = function() warnings = warnings + 1 end,
		onUnresolved = function() unresolved = unresolved + 1 end,
		confirmProvisional = function() return true end,
	})
	assertTrue(owner:Queue({ itemLink = "item:19019", itemIndex = 1, playerName = "Winner", effect = effect }), "entry must queue")
	assertEqual(1, #scheduled, "queue must own one confirmation timer")
	scheduled[1].callback()
	assertEqual(2, #scheduled, "timeout must schedule one reconciliation expiry")
	assertEqual(8, scheduled[2].delay, "expiry must use pending-award TTL")
	scheduled[2].callback()
	assertEqual(false, owner:HasInFlight(), "expiry must release ownership")
	local state = effect:GetState()
	assertEqual("uncertain", state.state, "expiry must remain uncertain")
	assertEqual("confirmation_unresolved", state.failureReason, "expiry reason differs")
	assertEqual(1, unresolved, "unresolved owner callback count differs")
	assertEqual(2, warnings, "timeout and unresolved warnings must each emit once")
	assertEqual(2, refreshes, "timeout and unresolved refreshes must each emit once")
	assertEqual(0, success, "expiry published success")
	assertEqual(0, cancelled, "expiry published known-failure cancellation")
	print("PASS loot_award_confirmation_expiry_is_bounded")
end

function cases.loot_award_confirmation_expiry_survives_presentation_failures(addon)
	local function runScenario(mode)
		addon.Services = {
			EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} return addon.Services[name] end,
		}
		loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardAttempt.lua")
		loadAddonFile(addon, "Raid Management Addon/Services/Master/AwardConfirmation.lua")
		local timeoutCallback, scheduleCalls, cleanupCalls, warnCalls, refreshCalls = nil, 0, 0, 0, 0
		local effect = addon.Services.Master.AwardAttempt.CreateExecuting({ onConfirm = function() return true end })
		local owner = addon.Services.Master.AwardConfirmation.Create({
			timeoutSeconds = 4,
			reconciliationSeconds = 8,
			scheduleTimer = function(callback)
				scheduleCalls = scheduleCalls + 1
				if scheduleCalls == 1 then timeoutCallback = callback return callback end
				if mode == "throw" then error("expiry schedule exploded") end
				return nil
			end,
			cancelTimer = function() end,
			requestRefresh = function() refreshCalls = refreshCalls + 1 error("refresh exploded") end,
			warnFailure = function() end,
			warnUncertain = function() end,
			warnTimeout = function() warnCalls = warnCalls + 1 error("timeout warning exploded") end,
			warnUnresolved = function() warnCalls = warnCalls + 1 error("unresolved warning exploded") end,
			onUnresolved = function() cleanupCalls = cleanupCalls + 1 error("cleanup exploded") end,
			confirmProvisional = function() return true end,
		})
		assertTrue(owner:Queue({ itemLink = "item:19019", itemIndex = 1, playerName = "Winner", effect = effect }), "scenario must queue")
		local ok = pcall(timeoutCallback)
		assertEqual(true, ok, mode .. " timeout path leaked callback failure")
		assertEqual(false, owner:HasInFlight(), mode .. " expiry failure retained ownership")
		assertEqual("uncertain", effect:GetState().state, mode .. " expiry changed terminal state")
		assertEqual("confirmation_unresolved", effect:GetState().failureReason, mode .. " expiry reason differs")
		assertEqual(1, cleanupCalls, mode .. " cleanup callback attempt count differs")
		assertEqual(2, warnCalls, mode .. " presentation warnings did not both attempt")
		assertEqual(2, refreshCalls, mode .. " presentation refreshes did not both attempt")
	end
	runScenario("nil")
	runScenario("throw")
	print("PASS loot_award_confirmation_expiry_survives_presentation_failures")
end

function cases.loot_inventory_slot_validation_is_strict(addon)
	local currentLink
	_G.GetNumLootItems = function() return currentLink and 1 or 0 end
	_G.GetLootSlotLink = function() return currentLink end
	_G.GetContainerNumSlots = function() return 0 end
	_G.GetContainerItemLink = function() return nil end
	_G.GetContainerItemInfo = function() return nil end
	addon.Database = { EnsureLootRuntimeState = function() return {}, {}, {} end }
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} return addon.Services[name] end,
	}
	addon.Item = {
		GetItemStringFromLink = function(link) return link and link:match("|H(item:[^|]+)|h") or nil end,
		GetItemIdFromLink = function(link)
			return tonumber(link and (link:match("item:(%d+)") or link:match("^(%d+)$")))
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/Inventory.lua")
	local inventory = addon.Services.Loot.Inventory
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	currentLink = "|cffa335ee|Hitem:19019:1:0:0:0:0:0:0|h[Changed]|h|r"
	local ok, reason = inventory.ValidateLootSlot(1, target)
	assertEqual(nil, ok, "same item ID must not override canonical mismatch")
	assertEqual("loot_slot_changed", reason, "canonical mismatch reason differs")
	currentLink = target
	assertEqual(true, inventory.ValidateLootSlot(1, target), "identical canonical item must validate")
	currentLink = nil
	ok, reason = inventory.ValidateLootSlot(1, target)
	assertEqual(nil, ok, "missing slot must reject")
	assertEqual("loot_slot_missing", reason, "missing slot reason differs")
	currentLink = "item:19019"
	assertEqual(true, inventory.ValidateLootSlot(1, "19019"), "item ID fallback must work when canonical data is unavailable")
	print("PASS loot_inventory_slot_validation_is_strict")
end

local function installTradeEvidenceInventory(addon, bags)
	_G.GetNumLootItems = function() return 0 end
	_G.GetLootSlotLink = function() return nil end
	_G.GetContainerNumSlots = function(bag)
		local rows = bags[bag] or {}
		local highest = 0
		for slot in pairs(rows) do
			if slot > highest then highest = slot end
		end
		return highest
	end
	_G.GetContainerItemLink = function(bag, slot)
		local row = bags[bag] and bags[bag][slot]
		return row and row.link or nil
	end
	_G.GetContainerItemInfo = function(bag, slot)
		local row = bags[bag] and bags[bag][slot]
		return nil, row and row.count or nil
	end
	addon.Database = addon.Database or {}
	addon.Database.EnsureLootRuntimeState = function() return {}, {}, {} end
	addon.Services = addon.Services or {}
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
	end
	addon.Item = {
		GetItemStringFromLink = function(link) return link and link:match("|H(item:[^|]+)|h") or nil end,
		GetItemIdFromLink = function(link)
			return tonumber(link and (link:match("item:(%d+)") or link:match("^(%d+)$")))
		end,
		IsBagItemSoulbound = function() return false end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/Inventory.lua")
	return addon.Services.Loot.Inventory
end

function cases.loot_award_sequence_schedule_failure_is_terminal(addon)
	local schedulerFailures = {
		{ name = "progress throw", progress = true, flag = "throwNextSchedule" },
		{ name = "progress nil", progress = true, flag = "nilNextSchedule" },
		{ name = "delay throw", progress = false, flag = "throwNextSchedule" },
		{ name = "delay nil", progress = false, flag = "nilNextSchedule" },
	}
	for i = 1, #schedulerFailures do
		local scenario = schedulerFailures[i]
		local fixture = installLootHardeningMasterFixture(i == 1 and addon or newAddon())
		fixture.lootState.selectedItemCount = 2
		fixture.mutateSelectedCountOnReset = true
		fixture.windowItemCount = 2
		local reentrantResult
		fixture.onWarn = function()
			reentrantResult = fixture.awardSequence:ContinueOnLootSlotCleared(1)
		end
		assertTrue(fixture.awardSequence:Start("item:19019", 2, {
			{ name = "Winner", roll = 90 }, { name = "Runner", roll = 80 },
		}), scenario.name .. " sequence must start")
		local result, reason
		if scenario.progress then
			fixture[scenario.flag] = true
			result, reason = fixture.master._awardConfirmation:Confirm(1)
		else
			assertEqual(true, fixture.master._awardConfirmation:Confirm(1), scenario.name .. " first award must confirm")
			fixture.windowItemCount = 1
			fixture[scenario.flag] = true
			result, reason = fixture.awardSequence:ContinueOnLootSlotCleared(1)
		end

		assertEqual(nil, result, scenario.name .. " must reject the sequence")
		assertEqual("timer_schedule_failed", reason, scenario.name .. " reason differs")
		assertEqual(nil, fixture.lootState.multiAward, scenario.name .. " retained ownership")
		assertEqual(1, fixture.warningCount, scenario.name .. " must warn once")
		assertEqual(false, reentrantResult, scenario.name .. " warning observed live sequence ownership")
		assertEqual(0, fixture.activeTimerCount(), scenario.name .. " left an active timer")
		assertEqual(1, fixture.lootState.selectedItemCount, scenario.name .. " did not reset item count")
	end
	print("PASS loot_award_sequence_schedule_failure_is_terminal")
end

function cases.loot_inventory_canonical_match_and_required_count(addon)
	local bags = { [0] = { [1] = { link = "|Hitem:19019:0:0:0:0:0:0:1|h[A]|h", count = 2 } } }
	local inventory = installTradeEvidenceInventory(addon, bags)
	assertTrue(inventory.LootLinkMatchesTarget(
		"|Hitem:19019:0:0:0:0:0:0:1|h[A]|h",
		"|cffa335ee|Hitem:19019:0:0:0:0:0:0:1|h[B]|h|r",
		"item:19019:0:0:0:0:0:0:1",
		19019
	), "canonical item strings must match")
	local evidence = assert(inventory.CaptureTradeEvidence(bags[0][1].link, 0, 1))
	evidence.expectedPartner = "Winner"
	bags[0][1].count = 1
	local verified, reason = inventory.VerifyTradeEvidence(evidence, "Winner", 2)
	assertEqual(nil, verified, "one transferred copy must not satisfy a two-copy award")
	assertEqual("trade_transfer_unverified", reason, "partial transfer reason differs")
	bags[0][1] = nil
	local awarded
	verified, awarded = inventory.VerifyTradeEvidence(evidence, "Winner", 2)
	assertEqual(true, verified, "two transferred copies must satisfy the required count")
	assertEqual(2, awarded, "required-count evidence differs")
	print("PASS loot_inventory_canonical_match_and_required_count")
end

function cases.loot_trade_inventory_evidence_requires_a_positive_delta(addon)
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local changed = "|cffa335ee|Hitem:19019:1:0:0:0:0:0:0|h[Changed]|h|r"
	local bags = { [0] = {
		[1] = { link = target, count = 2 },
		[2] = { link = target, count = 3 },
	} }
	local inventory = installTradeEvidenceInventory(addon, bags)
	local evidence, reason = inventory.CaptureTradeEvidence(target, 0, 1)
	assertTrue(evidence ~= nil, reason or "trade evidence capture failed")
	evidence.expectedPartner = "Winner"
	assertEqual(5, evidence.totalCount, "captured total count differs")
	local ok
	ok, reason = inventory.VerifyTradeEvidence(evidence, nil)
	assertEqual(nil, ok, "missing observed partner must not confirm a transfer")
	assertEqual("trade_partner_unavailable", reason, "missing observed partner reason differs")
	ok, reason = inventory.VerifyTradeEvidence(evidence, "Winner")
	assertEqual(nil, ok, "unchanged inventory must not confirm a transfer")
	assertEqual("trade_transfer_unverified", reason, "unchanged inventory reason differs")
	ok, reason = inventory.VerifyTradeEvidence(evidence, "Other")
	assertEqual(nil, ok, "wrong partner must not confirm a transfer")
	assertEqual("trade_partner_changed", reason, "wrong partner reason differs")

	bags[0][1].count = 1
	local awarded
	ok, awarded = inventory.VerifyTradeEvidence(evidence, "Winner")
	assertEqual(true, ok, "source-stack decrease must confirm")
	assertEqual(1, awarded, "source-stack awarded count differs")

	bags[0][1] = { link = target, count = 2 }
	bags[0][2].count = 1
	ok, awarded = inventory.VerifyTradeEvidence(evidence, "Winner")
	assertEqual(true, ok, "total-count decrease must confirm")
	assertEqual(2, awarded, "total-count awarded count differs")

	bags[0][1] = { link = changed, count = 2 }
	bags[0][2].count = 3
	ok, awarded = inventory.VerifyTradeEvidence(evidence, "Winner")
	assertEqual(true, ok, "canonical source replacement must prove the tracked stack left")
	assertEqual(2, awarded, "replacement source awarded count differs")
	print("PASS loot_trade_inventory_evidence_requires_a_positive_delta")
end

local function installAwardTradeFixture(addon, opts)
	opts = opts or {}
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local bags = opts.bags or { [0] = { [1] = { link = target, count = 2 } } }
	local inventory = installTradeEvidenceInventory(addon, bags)
	local selectedWinners = opts.selectedWinners or { { name = "Winner", roll = 90 } }
	addon.C = {
		RAID_TARGET_MARKERS = {},
		rollTypes = { MAINSPEC = 1, OFFSPEC = 2, RESERVED = 3, FREE = 4, HOLD = 5 },
	}
	addon.L = setmetatable({
		ChatTrade = "%s %s",
		ErrMLInventoryItemMissing = "%s",
		ErrItemStack = "%s",
		ErrNoWinnerSelected = "no winner",
		ErrMLWinnerIneligible = "%s",
		ErrMLWinnerLootBanned = "%s",
		ErrMLWinnerLootBannedWithNote = "%s %s",
		ErrScreenReminder = "screen",
		WarnTradeTransferUnverified = "%s %s",
	}, { __index = function(_, key) return key .. " %s %s %s %s" end })
	addon.Diag = {
		D = setmetatable({ LogTradeCompleted = "%s %s %s %s" }, { __index = function(_, key) return key .. " %s %s %s %s %s" end }),
		W = setmetatable({ LogTradeDelayedOutOfRange = "%s %s" }, { __index = function(_, key) return key .. " %s %s %s %s %s" end }),
		E = setmetatable({ LogTradeLoggerLogFailed = "%s %s %s" }, { __index = function(_, key) return key .. " %s %s %s %s %s" end }),
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/TradeExecution.lua")
	local counters = {
		logger = 0, raid = 0, registered = 0, rollEnd = 0, itemDone = 0, announce = 0,
		whisper = 0, release = 0, warn = 0, clearLoot = 0, reset = 0, refresh = 0,
		initiateSawState = nil, initiateTrade = 0, terminalMessages = {},
	}
	local lootState = {
		fromInventory = true, selectedItemCount = opts.selectedItemCount or 1, currentRollItem = 10,
		currentItemIndex = 1, rollSession = { id = "RS:trade" },
	}
	local itemInfo = {}
	local controller
	local function createAttempt(attemptOpts)
		local state = { state = "executing", checkpoints = {}, executorContext = attemptOpts.executorContext }
		local wrapperEffects = {}
		local attempt
		attempt = {
			Confirm = function()
				state.state = "confirming"
				if not wrapperEffects.rollEnd then
					controller.distribution.PublishRollEnd()
					wrapperEffects.rollEnd = true
				end
				if not wrapperEffects.itemDone then
					controller.distribution.PublishItemDone()
					wrapperEffects.itemDone = true
				end
				local invoked, ok = pcall(attemptOpts.onConfirm, attempt, state, nil)
				state.state = invoked and ok == true and "confirmed" or "uncertain"
				return invoked and ok == true and true or nil
			end,
			Fail = function(_, reason) state.state = "failed" state.reason = reason return true end,
			GetState = function() return state end,
		}
		return attempt
	end
	controller = addon.Services.Master.TradeExecution.CreateController({
		lootBans = { Get = function() return false end },
		trade = { Reset = function() end },
		inventory = inventory,
		awardPlanner = { BuildTradeNotificationPlan = function()
			return { keep = false, output = "awarded", whisper = "winner whisper", markerPlan = {} }
		end },
		rollSelection = {
			GetSelectedCount = function() return #selectedWinners end,
			DeselectWinner = function(_, playerName)
				for i = 1, #selectedWinners do
					if selectedWinners[i].name == playerName then
						table.remove(selectedWinners, i)
						break
					end
				end
			end,
			GetSelectedWinnersOrdered = function() return selectedWinners end,
		},
		raid = {
			GetUnitID = function() return "raid1" end,
			ClearRaidIcons = function() end,
			AddPlayerCountForRollType = function() counters.raid = counters.raid + 1 end,
		},
		loot = {
			GetItemLink = function() return target end,
			ClearLoot = function() counters.clearLoot = counters.clearLoot + 1 end,
		},
		distribution = {
			PublishRollEnd = function()
				counters.rollEnd = counters.rollEnd + 1
				counters.terminalMessages[#counters.terminalMessages + 1] = "ROLL_END"
				return true
			end,
			PublishItemDone = function()
				counters.itemDone = counters.itemDone + 1
				counters.terminalMessages[#counters.terminalMessages + 1] = "ITEM_DONE"
				return true
			end,
			AcquireSessionOwnership = function() return "owner:1" end,
			ReleaseSessionOwnership = function()
				counters.release = counters.release + 1
				return opts.rejectRelease ~= true
			end,
		},
		rolls = {
			EnsureLootRollSession = function() end,
			ValidateWinner = function() return { ok = true } end,
			GetResolvedWinner = function() return "Winner" end,
			GetRolls = function() return {} end,
		},
		comms = { SendWhisper = function() counters.whisper = counters.whisper + 1 return true end },
		database = { GetCurrentRaid = function() return 1 end, GetPlayerName = function() return "Holder" end },
		item = addon.Item,
		lootState = lootState,
		itemInfo = itemInfo,
		wow = {
			ClearCursor = function() end,
			CursorHasItem = function() return true end,
			GetContainerItemInfo = _G.GetContainerItemInfo,
			GetContainerItemLink = _G.GetContainerItemLink,
			PickupContainerItem = function() end,
			InitiateTrade = function()
				counters.initiateTrade = counters.initiateTrade + 1
				local state = controller:GetPendingState()
				counters.initiateSawState = state and state.state
			end,
			SetRaidTarget = function() end,
			CheckInteractDistance = function()
				if opts.inRange == false then return nil end
				return 1
			end,
		},
		getOption = function(_, key) return key == "ignoreStacks" end,
		buildRollSelectionModel = function()
			return { winner = selectedWinners[1] and selectedWinners[1].name or nil, rows = selectedWinners }
		end,
		buildLootRollSessionOptions = function() return {} end,
		resetTradeState = function() counters.reset = counters.reset + 1 end,
		hideTradeDropdowns = function() end,
		clearLootAndResetRecordedRolls = function() end,
		ensureTradeLootContext = function() return 10, false end,
		requestLoggerLootLog = function()
			counters.logger = counters.logger + 1
			return opts.rejectLogger ~= true
		end,
		registerAwardedItem = function(count)
			counters.registered = counters.registered + count
			return counters.registered >= lootState.selectedItemCount
		end,
		requestRefresh = function() counters.refresh = counters.refresh + 1 return true end,
		announce = function() counters.announce = counters.announce + 1 return true end,
		isAnnounced = function() return false end,
		setAnnounced = function() end,
		isScreenshotWarn = function() return false end,
		setScreenshotWarn = function() end,
		warn = function() counters.warn = counters.warn + 1 end,
		error = function() end,
		createAttempt = createAttempt,
		getItemKey = addon.Item.GetItemStringFromLink,
	})
	return {
		controller = controller,
		bags = bags,
		counters = counters,
		itemInfo = itemInfo,
		lootState = lootState,
		selectedWinners = selectedWinners,
		target = target,
		opts = opts,
	}
end

function cases.loot_trade_rejects_second_in_flight(addon)
	local fixture = installAwardTradeFixture(addon)
	assertTrue(fixture.controller:TradeItem(fixture.target, "Winner", 1, 99))
	local admitted, reason = fixture.controller:TradeItem(fixture.target, "Winner", 1, 98)
	assertEqual(nil, admitted, "second trade must be rejected")
	assertEqual("trade_in_flight", reason, "second trade reason differs")
	print("PASS loot_trade_rejects_second_in_flight")
end

function cases.loot_trade_required_count_tracks_placed_stack(addon)
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local sequential = installAwardTradeFixture(addon, {
		bags = { [0] = {
			[1] = { link = target, count = 1 },
			[2] = { link = target, count = 1 },
		} },
		selectedItemCount = 2,
		selectedWinners = { { name = "Winner", roll = 90 }, { name = "Runner", roll = 80 } },
	})
	assertTrue(sequential.controller:TradeItem(sequential.target, "Winner", 1, 90))
	assertTrue(sequential.controller:HandleTradeShow("Winner"))
	assertTrue(sequential.controller:HandleAcceptedAwardTrade(1, 1))
	sequential.bags[0][1] = nil
	local settled, settleReason = sequential.controller:SettleAcceptedTrade("Winner")
	assertEqual(true, settled, settleReason or "one placed copy must settle independently")
	assertEqual(false, sequential.controller:HasInFlightAward(), "first sequential trade retained ownership")
	assertEqual("Runner", sequential.lootState.winner, "first trade did not advance to the second winner")
	assertEqual(1, sequential.counters.registered, "first sequential trade registered the wrong quantity")
	assertEqual(0, sequential.counters.clearLoot, "remaining duplicate copy cleared the loot frame")
	assertTrue(sequential.controller:TradeItem(sequential.target, "Runner", 1, 80), "second winner was not admitted")

	local stack = installAwardTradeFixture(newAddon(), {
		bags = { [0] = { [1] = { link = target, count = 2 } } },
		selectedItemCount = 1,
	})
	assertTrue(stack.controller:TradeItem(stack.target, "Winner", 1, 90))
	assertTrue(stack.controller:HandleTradeShow("Winner"))
	assertTrue(stack.controller:HandleAcceptedAwardTrade(1, 1))
	stack.bags[0][1].count = 1
	local verified, reason = stack.controller:SettleAcceptedTrade("Winner")
	assertEqual(nil, verified, "partial whole-stack transfer must remain uncertain")
	assertEqual("trade_transfer_unverified", reason, "partial whole-stack reason differs")
	stack.bags[0][1] = nil
	assertEqual(true, stack.controller:SettleAcceptedTrade("Winner"), "whole-stack delta must settle")
	assertEqual(false, stack.controller:HasInFlightAward(), "settled duplicate-copy evidence retained ownership")
	assertEqual(2, stack.counters.registered, "whole-stack trade registered the wrong quantity")
	assertEqual(1, stack.counters.clearLoot, "settled whole-stack trade did not clear the loot frame")
	print("PASS loot_trade_required_count_tracks_placed_stack")
end

function cases.loot_out_of_range_trade_can_retry(addon)
	local Rolls = installLootHardeningRollsFixture(addon)
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local session = Rolls:EnsureRollSession(target, addon.C.rollTypes.FREE, "lootWindow")
	Rolls:SetExpectedWinners(2)
	Rolls:SetRollRecordingEnabled(true)
	assertTrue(Rolls:SubmitDebugRoll("Winner", 90), "first winner roll must enter")
	assertTrue(Rolls:SubmitDebugRoll("Runner", 80), "second winner roll must enter")

	local fixture = installAwardTradeFixture(addon, {
		bags = { [0] = {
			[1] = { link = target, count = 1 },
			[2] = { link = target, count = 1 },
		} },
		selectedItemCount = 2,
		selectedWinners = { { name = "Winner", roll = 90 }, { name = "Runner", roll = 80 } },
		inRange = false,
	})
	local function requestTrade(playerName, roll)
		local frozen, reason = Rolls:FreezeRollIntake("award")
		if not frozen then
			return nil, reason
		end
		return fixture.controller:TradeItem(target, playerName, addon.C.rollTypes.FREE, roll)
	end

	assertTrue(requestTrade("Winner", 90), "out-of-range award request must retain its notification flow")
	assertEqual(0, fixture.counters.initiateTrade, "out-of-range request initiated a trade")
	assertEqual(false, fixture.controller:HasInFlightAward(), "out-of-range request retained pending trade state")
	assertEqual("failed", fixture.controller:GetPendingState().state, "out-of-range terminal attempt state differs")
	assertEqual(false, session.active, "out-of-range request reopened the frozen roll session")

	fixture.opts.inRange = true
	assertTrue(requestTrade("Winner", 90), "in-range retry must be admitted on the frozen roll session")
	assertEqual(1, fixture.counters.initiateTrade, "in-range retry did not initiate trade")
	assertEqual("requested", fixture.controller:GetPendingState().state, "in-range retry did not establish pending state")
	assertTrue(fixture.controller:HandleTradeShow("Winner"), "first winner trade did not open")
	assertTrue(fixture.controller:HandleAcceptedAwardTrade(1, 1), "first winner trade was not accepted")
	fixture.bags[0][1] = nil
	assertTrue(fixture.controller:SettleAcceptedTrade("Winner"), "first winner trade did not confirm")
	assertEqual("Runner", fixture.lootState.winner, "confirmed first trade did not advance to second winner")
	assertEqual(false, session.active, "first confirmation reactivated the frozen roll session")

	assertTrue(requestTrade("Runner", 80), "second winner was not admitted on the same frozen roll session")
	assertEqual(2, fixture.counters.initiateTrade, "second winner trade did not initiate")
	assertEqual("requested", fixture.controller:GetPendingState().state, "second winner did not establish pending state")
	print("PASS loot_out_of_range_trade_can_retry")
end

function cases.loot_trade_close_retries_once_after_bag_update(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local master = fixture.master
	local tradeController = fixture.tradeController
	local ownedCount = 1
	local confirmCalls = 0
	local pendingAcceptedTrade = true

	fixture.tradeInFlight = true
	tradeController.HasPendingAcceptedTrade = function()
		return pendingAcceptedTrade
	end
	tradeController.SettleAcceptedTrade = function()
		if ownedCount > 0 then
			return nil, "trade_transfer_unverified"
		end
		pendingAcceptedTrade = false
		fixture.tradeInFlight = false
		confirmCalls = confirmCalls + 1
		return true
	end

	master:TRADE_CLOSED()
	fixture.runScheduledTimers()
	assertEqual(true, tradeController:HasPendingAcceptedTrade(), "early close settle must remain pending")

	ownedCount = ownedCount - 1
	master:BAG_UPDATE()
	fixture.runScheduledTimers()
	assertEqual(false, tradeController:HasInFlightAward(), "bag update did not settle accepted trade")
	assertEqual(1, confirmCalls, "accepted trade confirmed more than once")

	master:BAG_UPDATE()
	fixture.runScheduledTimers()
	assertEqual(1, confirmCalls, "later bag update repeated settlement")
	print("PASS loot_trade_close_retries_once_after_bag_update")
end

function cases.loot_trade_menu_is_manual_only(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	local master = fixture.master
	local tradeMenu = addon.Widgets.TradeMenu
	local refreshCalls = 0
	local hideCalls = 0

	tradeMenu.RefreshCandidate = function()
		refreshCalls = refreshCalls + 1
	end
	tradeMenu.HideDropdowns = function()
		hideCalls = hideCalls + 1
	end
	fixture.tradeInFlight = true
	master:TRADE_SHOW()
	master:TRADE_PLAYER_ITEM_CHANGED()
	master:TRADE_TARGET_ITEM_CHANGED()
	assertEqual(0, refreshCalls, "addon-driven trade refreshed manual candidates")
	assertEqual(3, hideCalls, "addon-driven trade did not keep manual dropdowns hidden")

	fixture.tradeInFlight = false
	master:TRADE_PLAYER_ITEM_CHANGED()
	assertEqual(1, refreshCalls, "manual trade did not refresh its candidate")
	print("PASS loot_trade_menu_is_manual_only")
end

function cases.loot_award_trade_event_order_is_evidence_gated(addon)
	local fixture = installAwardTradeFixture(addon)
	local trade = fixture.controller
	assertEqual(true, trade:TradeItem(fixture.target, "Winner", 1, 90), "trade request must start")
	assertEqual("requested", fixture.counters.initiateSawState, "pending state must exist before InitiateTrade")
	assertEqual("requested", trade:GetPendingState().state, "initial trade state differs")
	assertEqual(0, fixture.counters.rollEnd, "trade request published ROLL_END before evidence")
	assertEqual(0, fixture.counters.announce, "trade request announced success before evidence")
	assertEqual(true, trade:HandleTradeShow("Winner"), "expected TRADE_SHOW must advance")
	assertEqual("shown", trade:GetPendingState().state, "TRADE_SHOW state differs")
	assertEqual(false, trade:HandleAcceptedAwardTrade(1, 0), "one accepted flag must not complete intent")
	assertEqual("shown", trade:GetPendingState().state, "partial accept changed state")
	assertEqual(true, trade:HandleAcceptedAwardTrade(1, 1), "both accepted flags must advance intent")
	assertEqual("accepted", trade:GetPendingState().state, "accepted state differs")
	assertEqual(nil, trade:SettleAcceptedTrade("Winner"), "close without delta must remain unconfirmed")
	assertEqual("uncertain", trade:GetPendingState().state, "unverified close must be uncertain")
	assertEqual(0, fixture.counters.logger, "unverified close logged success")
	assertEqual(0, fixture.counters.release, "uncertain close released session ownership")
	assertEqual(1, fixture.counters.warn, "uncertain close must warn once")

	fixture.bags[0][1] = nil
	assertEqual(true, trade:SettleAcceptedTrade("Winner"), "later inventory delta must confirm")
	assertEqual("confirmed", trade:GetPendingState().state, "confirmed state differs")
	assertEqual(1, fixture.counters.logger, "confirmed trade logger count differs")
	assertEqual(1, fixture.counters.raid, "confirmed trade counter count differs")
	assertEqual(1, fixture.counters.rollEnd, "confirmed trade ROLL_END count differs")
	assertEqual(1, fixture.counters.itemDone, "confirmed trade ITEM_DONE count differs")
	assertEqual("ITEM_DONE", fixture.counters.terminalMessages[#fixture.counters.terminalMessages], "ITEM_DONE must remain terminal")
	assertEqual(1, fixture.counters.announce, "confirmed trade announcement count differs")
	assertEqual(1, fixture.counters.whisper, "confirmed trade whisper count differs")
	assertEqual(1, fixture.counters.release, "confirmed trade did not release session ownership")
	assertEqual(false, trade:HasInFlightAward(), "confirmed trade retained award ownership")
	assertEqual(1, fixture.counters.clearLoot, "confirmed trade did not clear the master loot item")
	assertEqual(2, fixture.counters.reset, "confirmed trade did not reset the trade state")
	assertEqual(1, fixture.counters.refresh, "confirmed trade did not refresh the master loot frame")

	local wrong = installAwardTradeFixture(newAddon())
	assertTrue(wrong.controller:TradeItem(wrong.target, "Winner", 1, 90), "wrong-partner scenario did not start")
	assertEqual(true, wrong.controller:HandleTradeShow("Other"), "wrong-partner show must be handled")
	assertEqual("failed", wrong.controller:GetPendingState().state, "wrong partner must fail the request")
	assertEqual(1, wrong.counters.release, "wrong partner retained session ownership")

	local missingShowPartner = installAwardTradeFixture(newAddon())
	assertTrue(missingShowPartner.controller:TradeItem(missingShowPartner.target, "Winner", 1, 90))
	local shown, showReason = missingShowPartner.controller:HandleTradeShow(nil)
	assertEqual(nil, shown, "TRADE_SHOW without an observed partner must not advance")
	assertEqual("trade_partner_unavailable", showReason, "missing TRADE_SHOW partner reason differs")
	assertEqual("requested", missingShowPartner.controller:GetPendingState().state, "missing partner advanced show state")

	local beforeShowCancel = installAwardTradeFixture(newAddon())
	assertTrue(beforeShowCancel.controller:TradeItem(beforeShowCancel.target, "Winner", 1, 90))
	assertTrue(beforeShowCancel.controller:FailAcceptedTrade("TRADE_REQUEST_CANCEL"), "pre-show cancel must fail")
	assertEqual("failed", beforeShowCancel.controller:GetPendingState().state, "pre-show cancel state differs")
	local afterShowCancel = installAwardTradeFixture(newAddon())
	assertTrue(afterShowCancel.controller:TradeItem(afterShowCancel.target, "Winner", 1, 90))
	assertTrue(afterShowCancel.controller:HandleTradeShow("Winner"))
	assertTrue(afterShowCancel.controller:FailAcceptedTrade("TRADE_CLOSED"), "post-show cancel must fail")
	assertEqual("failed", afterShowCancel.controller:GetPendingState().state, "post-show cancel state differs")

	local missingSettlePartner = installAwardTradeFixture(newAddon())
	assertTrue(missingSettlePartner.controller:TradeItem(missingSettlePartner.target, "Winner", 1, 90))
	assertTrue(missingSettlePartner.controller:HandleTradeShow("Winner"))
	assertTrue(missingSettlePartner.controller:HandleAcceptedAwardTrade(1, 1))
	missingSettlePartner.bags[0][1] = nil
	local settled, settleReason = missingSettlePartner.controller:SettleAcceptedTrade(nil)
	assertEqual(true, settled, settleReason or "validated TRADE_SHOW partner must survive post-close nil lookup")
	assertEqual(1, missingSettlePartner.counters.logger, "validated shown partner did not reach logger")
	assertEqual(1, missingSettlePartner.counters.release, "validated shown partner did not release ownership")

	local retry = installAwardTradeFixture(newAddon(), { rejectLogger = true })
	assertTrue(retry.controller:TradeItem(retry.target, "Winner", 1, 90))
	assertTrue(retry.controller:HandleTradeShow("Winner"))
	assertTrue(retry.controller:HandleAcceptedAwardTrade(1, 1))
	retry.bags[0][1] = nil
	assertEqual(nil, retry.controller:SettleAcceptedTrade("Winner"), "logger rejection must remain retryable")
	assertEqual(1, retry.counters.logger, "logger first attempt count differs")
	assertEqual(0, retry.counters.raid, "counter ran before logger success")
	retry.opts.rejectLogger = false
	assertEqual(true, retry.controller:SettleAcceptedTrade("Winner"), "logger retry must confirm")
	assertEqual(2, retry.counters.logger, "logger retry count differs")
	assertEqual(1, retry.counters.raid, "logger retry duplicated counter")
	assertEqual(1, retry.counters.rollEnd, "logger retry duplicated distribution terminal state")
	assertEqual(1, retry.counters.announce, "logger retry duplicated announcement")

	local releaseRetry = installAwardTradeFixture(newAddon(), { rejectRelease = true })
	assertTrue(releaseRetry.controller:TradeItem(releaseRetry.target, "Winner", 1, 90))
	assertTrue(releaseRetry.controller:HandleTradeShow("Winner"))
	assertTrue(releaseRetry.controller:HandleAcceptedAwardTrade(1, 1))
	releaseRetry.bags[0][1] = nil
	local released, releaseReason = releaseRetry.controller:SettleAcceptedTrade("Winner")
	assertEqual(nil, released, "failed session release must retain terminal ownership")
	assertEqual("session_ownership_release_failed", releaseReason, "release failure reason differs")
	assertEqual(true, releaseRetry.controller:HasInFlightAward(), "release failure orphaned the in-flight owner")
	assertEqual(true, releaseRetry.controller:GetPendingState().releasePending, "release retry state not exposed")
	assertEqual(1, releaseRetry.counters.logger, "release failure repeated logger")
	releaseRetry.opts.rejectRelease = false
	assertEqual(true, releaseRetry.controller:SettleAcceptedTrade(nil), "terminal release retry must succeed without evidence rerun")
	assertEqual(false, releaseRetry.controller:HasInFlightAward(), "successful release retry retained ownership")
	assertEqual(2, releaseRetry.counters.release, "session release retry count differs")
	assertEqual(1, releaseRetry.counters.logger, "session release retry duplicated logger")
	assertEqual(1, releaseRetry.counters.rollEnd, "session release retry duplicated RMADist publication")
	assertEqual(1, releaseRetry.counters.announce, "session release retry duplicated announcement")
	print("PASS loot_award_trade_event_order_is_evidence_gated")
end

function cases.loot_trader_keep_uses_award_callback_contract(addon)
	local fixture = installAwardTradeFixture(addon)
	assertEqual(true, fixture.controller:TradeItem(fixture.target, "Holder", 1, 90), "trader-keep award must settle")
	assertEqual(1, fixture.counters.rollEnd, "trader-keep award published ROLL_END more than once")
	assertEqual(1, fixture.counters.itemDone, "trader-keep award did not publish ITEM_DONE")
	assertEqual("ITEM_DONE", fixture.counters.terminalMessages[#fixture.counters.terminalMessages], "trader-keep ITEM_DONE must remain terminal")
	assertEqual(1, fixture.counters.clearLoot, "trader-keep award did not clear the master loot item")
	assertEqual(2, fixture.counters.reset, "trader-keep award did not reset the trade state")
	assertEqual(1, fixture.counters.refresh, "trader-keep award did not refresh the master loot frame")
	print("PASS loot_trader_keep_uses_award_callback_contract")
end

function cases.loot_manual_hold_trade_requires_inventory_evidence(addon)
	local target = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Target]|h|r"
	local bags = { [0] = { [1] = { link = target, count = 1 } } }
	installTradeEvidenceInventory(addon, bags)
	local lootState = {}
	local raid = { loot = { {
		lootNid = 10, rollType = 5, looter = "Holder", holder = "Holder",
		itemString = "item:19019:0:0:0:0:0:0:0", itemId = 19019,
	} } }
	local loggerCalls, countCalls, warnings = 0, 0, 0
	addon.C = { rollTypes = { MAINSPEC = 1, OFFSPEC = 2, RESERVED = 3, FREE = 4, HOLD = 5 } }
	addon.L = setmetatable({ BtnMS = "MS", BtnOS = "OS", BtnSR = "SR", BtnFree = "Free",
		WarnTradeManualReasonMissing = "%s", WarnTradeTransferUnverified = "%s",
	}, { __index = function(_, key) return key .. " %s %s" end })
	addon.Diag = { D = setmetatable({}, { __index = function(_, key) return key .. " %s %s %s" end }),
		W = setmetatable({}, { __index = function(_, key) return key .. " %s %s %s" end }),
		E = setmetatable({}, { __index = function(_, key) return key .. " %s %s %s" end }) }
	addon.warn = function() warnings = warnings + 1 end
	addon.Database.EnsureLootRuntimeState = function() return {}, lootState, {} end
	addon.Database.EnsureRaidByIndex = function() return raid end
	addon.Database.GetCurrentRaid = function() return 1 end
	addon.Database.GetPlayerName = function() return "Holder" end
	addon.Services.Logger = { Actions = { RecordLoot = function() loggerCalls = loggerCalls + 1 return true end } }
	addon.Services.Raid = {
		GetPlayerID = function() return 1 end,
		AddPlayerCountForRollType = function() countCalls = countCalls + 1 end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Master/Trade.lua")
	local trade = addon.Services.Master.Trade
	local state = trade.RefreshCandidate({
		source = "TRADE_PLAYER_ITEM_CHANGED", partnerName = "Winner",
		tradeItems = { [1] = { itemLink = target, itemString = "item:19019:0:0:0:0:0:0:0", itemId = 19019 } },
	})
	assertEqual(true, state.active, "manual Hold candidate did not activate")
	assertTrue(state.candidates[1].tradeEvidence ~= nil, "manual Hold candidate did not capture evidence")
	assertTrue(trade.SetSelectedReason(10, 1), "manual Hold reason selection failed")
	assertTrue(trade.ApplyAccept(1, 1, false), "manual Hold accept intent failed")
	assertEqual(false, trade.CompletePending(), "manual Hold without delta must not log")
	assertEqual("uncertain", trade.EnsureState().state, "manual Hold without evidence must be uncertain")
	assertEqual(0, loggerCalls, "manual Hold without evidence logged success")
	bags[0][1] = nil
	assertEqual(true, trade.CompletePending(), "manual Hold with later delta must log")
	assertEqual(1, loggerCalls, "manual Hold logger count differs")
	assertEqual(1, countCalls, "manual Hold counter count differs")
	assertEqual("confirmed", trade.EnsureState().state, "manual Hold confirmed state differs")
	assertEqual(1, warnings, "manual Hold uncertainty warning count differs")

	local secondAddon = newAddon()
	local secondTarget = "|cffa335ee|Hitem:18832:0:0:0:0:0:0:0|h[Second]|h|r"
	local secondBags = { [0] = {
		[1] = { link = target, count = 1 },
		[2] = { link = secondTarget, count = 1 },
	} }
	installTradeEvidenceInventory(secondAddon, secondBags)
	local secondLootState = {}
	local secondRaid = { loot = {
		{ lootNid = 10, rollType = 5, looter = "Holder", holder = "Holder",
			itemString = "item:19019:0:0:0:0:0:0:0", itemId = 19019 },
		{ lootNid = 11, rollType = 5, looter = "Holder", holder = "Holder",
			itemString = "item:18832:0:0:0:0:0:0:0", itemId = 18832 },
	} }
	local loggerByNid, counterByName, rejectSecond = {}, {}, true
	secondAddon.C = addon.C
	secondAddon.L = addon.L
	secondAddon.Diag = addon.Diag
	secondAddon.warn = function() end
	secondAddon.Database.EnsureLootRuntimeState = function() return {}, secondLootState, {} end
	secondAddon.Database.EnsureRaidByIndex = function() return secondRaid end
	secondAddon.Database.GetCurrentRaid = function() return 1 end
	secondAddon.Database.GetPlayerName = function() return "Holder" end
	secondAddon.Services.Logger = { Actions = { RecordLoot = function(_, request)
		local nid = request.lootNid
		loggerByNid[nid] = (loggerByNid[nid] or 0) + 1
		if nid == 11 and rejectSecond then return false end
		return true
	end } }
	secondAddon.Services.Raid = {
		GetPlayerID = function() return 1 end,
		AddPlayerCountForRollType = function(_, name)
			counterByName[name] = (counterByName[name] or 0) + 1
		end,
	}
	loadAddonFile(secondAddon, "Raid Management Addon/Services/Master/Trade.lua")
	local secondTrade = secondAddon.Services.Master.Trade
	local secondState = secondTrade.RefreshCandidate({
		source = "TRADE_PLAYER_ITEM_CHANGED", partnerName = "Winner",
		tradeItems = {
			[1] = { itemLink = target, itemString = "item:19019:0:0:0:0:0:0:0", itemId = 19019 },
			[2] = { itemLink = secondTarget, itemString = "item:18832:0:0:0:0:0:0:0", itemId = 18832 },
		},
	})
	assertEqual(2, #secondState.candidates, "two-candidate manual fixture differs")
	assertTrue(secondTrade.SetSelectedReason(10, 1))
	assertTrue(secondTrade.SetSelectedReason(11, 1))
	assertTrue(secondTrade.ApplyAccept(1, 1, false))
	secondBags[0][1] = nil
	secondBags[0][2] = nil
	assertEqual(false, secondTrade.CompletePending(), "second logger rejection must retain manual ownership")
	assertEqual(1, loggerByNid[10], "first manual candidate logger count differs")
	assertEqual(1, loggerByNid[11], "second manual candidate first attempt differs")
	assertEqual(1, counterByName.Winner, "first manual candidate counter count differs")
	rejectSecond = false
	assertEqual(true, secondTrade.CompletePending(), "manual partial logger retry must complete remaining candidate")
	assertEqual(1, loggerByNid[10], "manual retry duplicated completed first logger")
	assertEqual(2, loggerByNid[11], "manual retry did not retry second logger exactly once")
	assertEqual(2, counterByName.Winner, "manual retry duplicated or lost a counter")
	print("PASS loot_manual_hold_trade_requires_inventory_evidence")
end

function cases.loot_attribution_cancellation_is_transaction_scoped(addon)
	local lootState = { pendingAwards = {} }
	_G.GetTime = function() return 10 end
	addon.C = { PENDING_AWARD_TTL_SECONDS = 8 }
	addon.Diag = { D = { LogLootPendingAwardConsumed = "%s %s %s %s" } }
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Item = { GetItemStringFromLink = function(link) return link end }
	addon.Database = { EnsureLootRuntimeState = function() return {}, lootState end }
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} return addon.Services[name] end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
	local attribution = addon.Services.Loot.LootAttribution
	attribution.Add("item:19019", "Winner", 1, 90, "RS:1", nil, { transactionId = "AT:1" })
	attribution.Add("item:19019", "Winner", 2, 80, "RS:2", nil, { transactionId = "AT:2" })
	attribution.Add("item:18832", "Other", 1, 70, "RS:3", nil, { transactionId = "AT:1" })
	assertEqual(true, attribution.Cancel("AT:1"), "matching transaction must cancel")
	assertEqual(false, attribution.Cancel("AT:1"), "repeated cancellation must be idempotent")
	local remaining = 0
	local remainingTransaction
	for _, list in pairs(lootState.pendingAwards) do
		for i = 1, #list do
			remaining = remaining + 1
			remainingTransaction = list[i].transactionId
		end
	end
	assertEqual(1, remaining, "cancellation removed unrelated pending awards")
	assertEqual("AT:2", remainingTransaction, "wrong transaction survived cancellation")
	print("PASS loot_attribution_cancellation_is_transaction_scoped")
end

function cases.loot_award_attribution_event_order_is_atomic(addon)
	local lootState = { pendingAwards = {} }
	_G.GetTime = function() return 10 end
	addon.C = { PENDING_AWARD_TTL_SECONDS = 8 }
	addon.Diag = { D = { LogLootPendingAwardConsumed = "%s %s %s %s" } }
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Item = { GetItemStringFromLink = function(link) return link end }
	addon.Database = { EnsureLootRuntimeState = function() return {}, lootState end }
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} return addon.Services[name] end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
	local attribution = addon.Services.Loot.LootAttribution
	local records, reconciles = 0, 0
	local function finalize(award)
		records = records + 1
		return records
	end
	local function reconcile(award, authoritative)
		reconciles = reconciles + 1
		assertEqual(2, authoritative.itemCount, "authoritative count was not retained")
	end

	-- CHAT_MSG_LOOT first: retain the transaction until slot confirmation, then
	-- finalize exactly once without waiting for another chat event.
	attribution.Add("item:19019", "Winner", 1, 90, "RS:chat", nil, { transactionId = "AT:chat" })
	assertTrue(attribution.StageAuthoritative("item:19019", "Winner", {
		itemCount = 2,
	}, reconcile), "chat-first award was not staged")
	assertEqual(0, records, "chat-first award finalized before slot evidence")
	local chatFirst = attribution.ConfirmProvisional(
		"item:19019", "Winner", "RS:chat", 1, "AT:chat", 1,
		function() error("chat-first confirmation must not schedule grace") end,
		function() end,
		finalize
	)
	assertTrue(chatFirst and chatFirst.finalized, "chat-first award did not confirm")
	assertEqual("CHAT_MSG_LOOT", chatFirst.finalizedSource, "chat-first source differs")
	assertEqual(1, records, "chat-first award record count differs")
	assertEqual(1, reconciles, "chat-first reconciliation count differs")
	assertEqual(nil, attribution.Remove("item:19019", "Winner", 8, "RS:chat", false, false),
		"chat-first confirmation retained a consumable pending award")
	assertEqual(nil, attribution.ConfirmProvisional(
		"item:19019", "Winner", "RS:chat", 1, "AT:chat", 1, nil, nil, finalize
	), "duplicate chat-first slot confirmation found a completed pending award")
	assertEqual(1, records, "duplicate chat-first confirmation repeated finalization")
	assertEqual(1, reconciles, "duplicate chat-first confirmation repeated reconciliation")

	-- LOOT_SLOT_CLEARED first: grace remains pending until authoritative chat,
	-- which cancels it and reconciles the same record exactly once.
	local scheduled, cancelled = {}, 0
	attribution.Add("item:19019", "Winner", 1, 80, "RS:slot", nil, { transactionId = "AT:slot" })
	local slotFirst = attribution.ConfirmProvisional(
		"item:19019", "Winner", "RS:slot", 1, "AT:slot", 1,
		function(callback) scheduled[#scheduled + 1] = callback return callback end,
		function() cancelled = cancelled + 1 end,
		finalize
	)
	assertTrue(slotFirst and not slotFirst.finalized, "slot-first award finalized before chat/grace")
	assertEqual(nil, attribution.StageAuthoritative("item:19019", "Winner", { itemCount = 2 }, reconcile),
		"slot-first chat bypassed existing provisional reconciliation")
	local consumed = attribution.Remove("item:19019", "Winner", 8, "RS:slot", false, false)
	assertTrue(consumed ~= nil, "slot-first authoritative resolution did not consume pending")
	assertTrue(attribution.ReconcileProvisional(
		"item:19019", "Winner", "RS:slot", "AT:slot",
		function() cancelled = cancelled + 1 end,
		function() reconciles = reconciles + 1 end
	), "slot-first chat did not reconcile")
	assertEqual(2, records, "slot-first award record count differs")
	assertEqual(2, reconciles, "slot-first reconciliation count differs")
	assertEqual(1, cancelled, "slot-first grace timer cancellation count differs")
	scheduled[1]()
	assertEqual(2, records, "stale grace callback duplicated the record")
	print("PASS loot_award_attribution_event_order_is_atomic")
end

function cases.loot_attribution_schedule_failure_finalizes_once(addon)
	local lootState = { pendingAwards = {} }
	_G.GetTime = function() return 10 end
	addon.C = { PENDING_AWARD_TTL_SECONDS = 8 }
	addon.Diag = { D = { LogLootPendingAwardConsumed = "%s %s %s %s" } }
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Item = { GetItemStringFromLink = function(link) return link end }
	addon.Database = { EnsureLootRuntimeState = function() return {}, lootState end }
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} return addon.Services[name] end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
	local attribution = addon.Services.Loot.LootAttribution
	local failures = {
		{ name = "scheduler throw", schedule = function() error("schedule exploded") end, expectedReason = "timer_schedule_failed" },
		{ name = "scheduler nil", schedule = function() return nil end, expectedReason = "timer_schedule_failed" },
		{ name = "finalizer throw", throwFinalize = true, expectedReason = "record_finalize_failed" },
	}
	for i = 1, #failures do
		local scenario = failures[i]
		local transactionId = "AT:failure:" .. tostring(i)
		local sessionId = "RS:failure:" .. tostring(i)
		local finalizeCount, failureCount, reconcileCount = 0, 0, 0
		attribution.Add("item:19019", "Winner", 1, 90, sessionId, nil, { transactionId = transactionId })
		local scheduledCallback
		local schedule = scenario.schedule or function(callback)
			scheduledCallback = callback
			return callback
		end
		local observedReason
		local provisional = attribution.ConfirmProvisional(
			"item:19019", "Winner", sessionId, 1, transactionId, 1,
			schedule,
			function() error("failed grace timer must not need cancellation") end,
			function()
				finalizeCount = finalizeCount + 1
				if scenario.throwFinalize then error("finalize exploded") end
				return finalizeCount
			end,
			function(reason)
				failureCount = failureCount + 1
				observedReason = reason
				if reason == "record_finalize_failed" then
					assertEqual(nil, attribution.Remove("item:19019", "Winner", 8, sessionId, false, false),
						scenario.name .. " reported failure before consuming pending ownership")
				end
			end
		)
		if scheduledCallback then scheduledCallback() end
		assertTrue(provisional and provisional.finalized, scenario.name .. " did not finalize immediately")
		assertEqual("LOOT_SLOT_CLEARED", provisional.finalizedSource, scenario.name .. " source differs")
		assertEqual(1, finalizeCount, scenario.name .. " finalization count differs")
		assertEqual(1, failureCount, scenario.name .. " must report one failure")
		assertEqual(scenario.expectedReason, observedReason, scenario.name .. " failure reason differs")
		assertEqual(nil, attribution.Remove("item:19019", "Winner", 8, sessionId, false, false),
			scenario.name .. " retained a consumable pending award")
		local reconciled, reconcileReason = attribution.ReconcileProvisional(
			"item:19019", "Winner", sessionId, transactionId, nil,
			function() reconcileCount = reconcileCount + 1 end
		)
		if scenario.throwFinalize then
			assertEqual(nil, reconciled, scenario.name .. " falsely reported handled reconciliation")
			assertEqual("provisional_record_unavailable", reconcileReason, scenario.name .. " fallback reason differs")
			assertEqual(0, reconcileCount, scenario.name .. " applied authoritative data without a record")
		else
			assertTrue(reconciled, scenario.name .. " did not remain authoritatively reconcilable")
			assertEqual(1, reconcileCount, scenario.name .. " reconciliation count differs")
		end
		assertEqual(1, finalizeCount, scenario.name .. " authoritative reconciliation repeated finalization")
		assertEqual(1, failureCount, scenario.name .. " authoritative reconciliation repeated failure reporting")
	end

	local controllerFixture = installLootHardeningMasterFixture(newAddon(), { realLootFlow = true })
	assertTrue(controllerFixture.master._Private.BtnAward(nil, nil), "controller failure fixture admission failed")
	controllerFixture.throwNextSchedule = true
	assertEqual(true, controllerFixture.master._awardConfirmation:Confirm(1),
		"controller scheduler fallback did not complete confirmation")
	assertEqual(1, controllerFixture.warningCount, "controller scheduler fallback did not warn exactly once")
	assertEqual(1, #controllerFixture.raid.loot, "controller scheduler fallback did not record once")
	assertEqual("LOOT_SLOT_CLEARED", controllerFixture.raid.loot[1].source,
		"controller scheduler fallback record source differs")

	local fallbackFailures = {
		{ name = "finalizer throw", throwFinalize = true },
		{ name = "finalizer zero", recordIndex = 0 },
	}
	local parsed = {
		msg = "loot-msg",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 2,
		playerName = "Winner",
	}
	for i = 1, #fallbackFailures do
		local scenario = fallbackFailures[i]
		local fixture = installLootHardeningMasterFixture(newAddon(), { realLootFlow = true })
		local finalizeCalls = 0
		function fixture.loot:LogTradeOnlyLoot()
			finalizeCalls = finalizeCalls + 1
			if scenario.throwFinalize then error("record finalize exploded") end
			return scenario.recordIndex
		end
		assertTrue(fixture.master._Private.BtnAward(nil, nil), scenario.name .. " admission failed")
		assertEqual(true, fixture.master._awardConfirmation:Confirm(1), scenario.name .. " confirmation failed")
		fixture.timerCallbacks[#fixture.timerCallbacks]()
		assertEqual(1, finalizeCalls, scenario.name .. " finalizer count differs after grace")
		assertEqual(1, fixture.warningCount, scenario.name .. " warning count differs after grace")
		assertEqual(0, #fixture.raid.loot, scenario.name .. " created an invalid provisional row")
		assertEqual(nil, fixture.loot.LootAttribution.Remove(
			"item:19019", "Winner", 8, "RS:1", false, false
		), scenario.name .. " retained pending attribution after grace")

		fixture.loot:AddLoot("loot-msg", nil, nil, parsed)
		assertEqual(1, #fixture.raid.loot, scenario.name .. " authoritative fallback row count differs")
		assertEqual("CHAT_MSG_LOOT", fixture.raid.loot[1].source, scenario.name .. " authoritative source differs")
		assertEqual(1, finalizeCalls, scenario.name .. " reconciliation repeated finalization")
		assertEqual(1, fixture.warningCount, scenario.name .. " reconciliation repeated warning")
		assertEqual(nil, fixture.loot.LootAttribution.Remove(
			"item:19019", "Winner", 8, "RS:1", false, false
		), scenario.name .. " reconciliation restored pending attribution")

		fixture.loot:AddLoot("loot-msg", nil, nil, parsed)
		assertEqual(1, #fixture.raid.loot, scenario.name .. " duplicate authoritative event created another row")
		assertEqual(1, finalizeCalls, scenario.name .. " duplicate event repeated finalization")
		assertEqual(1, fixture.warningCount, scenario.name .. " duplicate event repeated warning")
	end
	print("PASS loot_attribution_schedule_failure_finalizes_once")
end

function cases.loot_attribution_terminal_callbacks_are_contained(addon)
	local lootState = { pendingAwards = {} }
	_G.GetTime = function() return 10 end
	addon.C = { PENDING_AWARD_TTL_SECONDS = 8 }
	addon.Diag = { D = { LogLootPendingAwardConsumed = "%s %s %s %s" } }
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Item = { GetItemStringFromLink = function(link) return link end }
	addon.Database = { EnsureLootRuntimeState = function() return {}, lootState end }
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} return addon.Services[name] end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
	local attribution = addon.Services.Loot.LootAttribution

	local authoritativeFailures = {
		{ name = "finalizer throw", finalize = function() error("record callback exploded") end },
		{ name = "finalizer zero", finalize = function() return 0 end },
	}
	for i = 1, #authoritativeFailures do
		local scenario = authoritativeFailures[i]
		local sessionId = "RS:authoritative:" .. tostring(i)
		local transactionId = "AT:authoritative:" .. tostring(i)
		local finalizeCount, authoritativeCount, warningCount = 0, 0, 0
		attribution.Add("item:19019", "Winner", 1, 90, sessionId, nil, { transactionId = transactionId })
		attribution.StageAuthoritative("item:19019", "Winner", { itemCount = 1 }, function()
			authoritativeCount = authoritativeCount + 1
		end)
		local provisional = attribution.ConfirmProvisional(
			"item:19019", "Winner", sessionId, 1, transactionId, 1, nil, nil,
			function(...)
				finalizeCount = finalizeCount + 1
				return scenario.finalize(...)
			end,
			function() warningCount = warningCount + 1 end
		)
		assertTrue(provisional and provisional.finalized, scenario.name .. " did not become terminal")
		assertEqual(1, finalizeCount, scenario.name .. " finalizer count differs")
		assertEqual(0, authoritativeCount, scenario.name .. " reconciled without a positive record id")
		assertEqual(1, warningCount, scenario.name .. " warning count differs")
		assertEqual(nil, attribution.Remove("item:19019", "Winner", 8, sessionId, false, false),
			scenario.name .. " retained pending ownership")
		assertEqual(nil, attribution.ConfirmProvisional(
			"item:19019", "Winner", sessionId, 1, transactionId, 1, nil, nil, scenario.finalize
		), scenario.name .. " admitted duplicate finalization")
		local reconciled, reconcileReason = attribution.ReconcileProvisional(
			"item:19019", "Winner", sessionId, transactionId, nil, function()
				authoritativeCount = authoritativeCount + 1
			end
		)
		assertTrue(reconciled and reconciled.finalized and reconciled.reconciled,
			scenario.name .. " lost terminal duplicate ownership")
		assertEqual(nil, reconcileReason, scenario.name .. " repeated terminal reason differs")
		assertEqual(0, authoritativeCount, scenario.name .. " applied authoritative data without a positive record id")
		assertEqual(1, finalizeCount, scenario.name .. " repeated finalization")
		assertEqual(1, warningCount, scenario.name .. " repeated warning")
	end

	local finalizeCount, authoritativeCount, warningCount, reentrantResult = 0, 0, 0, true
	attribution.Add("item:18832", "Winner", 1, 80, "RS:post", nil, { transactionId = "AT:post" })
	attribution.StageAuthoritative("item:18832", "Winner", { itemCount = 1 }, function()
		authoritativeCount = authoritativeCount + 1
		reentrantResult = attribution.ConfirmProvisional(
			"item:18832", "Winner", "RS:post", 1, "AT:post", 1, nil, nil, function() return 99 end
		)
		error("authoritative callback exploded")
	end)
	local postRecord = attribution.ConfirmProvisional(
		"item:18832", "Winner", "RS:post", 1, "AT:post", 1, nil, nil,
		function() finalizeCount = finalizeCount + 1 return 7 end,
		function() warningCount = warningCount + 1 end
	)
	assertTrue(postRecord and postRecord.finalized and postRecord.reconciled, "post-record callback lost terminal state")
	assertEqual(7, postRecord.recordIndex, "post-record callback lost the valid record id")
	assertEqual(nil, reentrantResult, "post-record callback observed live pending ownership")
	assertEqual(1, finalizeCount, "post-record callback repeated record creation")
	assertEqual(1, authoritativeCount, "post-record callback count differs")
	assertEqual(1, warningCount, "post-record callback warning count differs")

	local reconcileCount, reconcileWarnings = 0, 0
	attribution.Add("item:17182", "Winner", 1, 70, "RS:reconcile", nil, { transactionId = "AT:reconcile" })
	local scheduled
	attribution.ConfirmProvisional(
		"item:17182", "Winner", "RS:reconcile", 1, "AT:reconcile", 1,
		function(callback) scheduled = callback return callback end, nil,
		function() return 8 end,
		function() reconcileWarnings = reconcileWarnings + 1 end
	)
	attribution.StageAuthoritative("item:17182", "Winner", { itemCount = 1 })
	local reconciled = attribution.ReconcileProvisional(
		"item:17182", "Winner", "RS:reconcile", "AT:reconcile", nil,
		function() reconcileCount = reconcileCount + 1 error("reconcile callback exploded") end
	)
	assertTrue(reconciled and reconciled.finalized and reconciled.reconciled, "reconcile callback escaped terminal state")
	assertEqual(1, reconcileCount, "reconcile callback count differs")
	assertEqual(1, reconcileWarnings, "reconcile callback warning count differs")
	assertTrue(attribution.ReconcileProvisional(
		"item:17182", "Winner", "RS:reconcile", "AT:reconcile", nil,
		function() reconcileCount = reconcileCount + 1 end
	), "repeat reconcile lost terminal result")
	assertEqual(1, reconcileCount, "repeat reconcile invoked callback")
	assertEqual(1, reconcileWarnings, "repeat reconcile repeated warning")
	if scheduled then scheduled() end
	assertEqual(1, reconcileCount, "stale timer changed reconciliation")
	print("PASS loot_attribution_terminal_callbacks_are_contained")
end

function cases.loot_service_stages_authoritative_before_consumption(addon)
	local lootState, itemInfo, raidState = {}, {}, {}
	local staged, removed = 0, 0
	_G.table.wipe = _G.table.wipe or function(target) for key in pairs(target) do target[key] = nil end return target end
	_G.GetLootThreshold = function() return 2 end
	_G.GetItemInfo = function() return "Thunderfury", nil, 5, nil, nil, "Weapon", nil, nil, nil, "texture" end
	addon.C = { itemColors = {}, rollTypes = {}, PENDING_AWARD_TTL_SECONDS = 8, GROUP_LOOT_PENDING_AWARD_TTL_SECONDS = 60 }
	addon.L = {}
	addon.Diag = { D = setmetatable({}, { __index = function() return "%s %s %s %s" end }) }
	addon.Events = { Internal = { RaidLootUpdate = "RaidLootUpdate", SetItem = "SetItem" } }
	addon.Bus = { TriggerEvent = function() end }
	addon.Deformat = function() return nil end
	addon.Options = {
		GetValue = function() return false end,
		NormalizeLoggerLootQualityThreshold = function(value) return tonumber(value) or 2 end,
	}
	addon.Strings = { NormalizeName = function(value) return value end }
	addon.Time = { GetCurrentTime = function() return 10 end }
	addon.Timer = { BindMixin = function(target)
		function target:ScheduleTimer() return {} end
		function target:CancelTimer() return true end
	end }
	addon.Item = {
		GetItemStringFromLink = function() return "item:19019" end,
		GetItemIdFromLink = function() return 19019 end,
		GetItemKey = function() return "item:19019" end,
	}
	addon.Database = {
		EnsureLootRuntimeState = function() return {}, lootState, itemInfo, raidState end,
		GetCurrentRaid = function() return 1 end,
		GetPlayerName = function() return "Tester" end,
		GetRaidQueries = function() return { ResolveLootLooterName = function() end } end,
	}
	local noopOwner = setmetatable({}, { __index = function() return function() end end })
	local attribution = setmetatable({
		StageAuthoritative = function(_, _, authoritative)
			staged = staged + 1
			assertEqual(2, authoritative.itemCount, "service did not stage authoritative count")
			return true
		end,
		Remove = function()
			removed = removed + 1
			return nil
		end,
	}, getmetatable(noopOwner))
	addon.Services = {
		EnsureNamespace = function(name) addon.Services[name] = addon.Services[name] or {} return addon.Services[name] end,
		Loot = {
			LootAttribution = attribution,
			_PassiveGroupLoot = setmetatable({
				IsPassiveGroupLootMethod = function() return false end,
				IsPassiveLootWinnerMessage = function() return false end,
			}, getmetatable(noopOwner)),
			_Tracking = noopOwner,
			_Workflow = noopOwner,
			_Recording = noopOwner,
			_Rules = { _IsIgnoredItem = function() return false end },
			AwardPlanner = noopOwner,
			Inventory = noopOwner,
			DistributionSession = noopOwner,
			_Context = { ResolveRaidRecord = function() return 1, { loot = {} } end },
		},
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/Service.lua")
	addon.Services.Loot:AddLoot("loot-msg", nil, nil, {
		msg = "loot-msg",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 2,
		playerName = "Winner",
	})
	assertEqual(1, staged, "authoritative chat was not staged exactly once")
	assertEqual(0, removed, "pending award was consumed before transaction confirmation")
	print("PASS loot_service_stages_authoritative_before_consumption")
end

function cases.loot_award_event_orders_share_full_production_chain(addon)
	local function pendingCount(fixture)
		local count = 0
		for _, list in pairs(fixture.lootState.pendingAwards or {}) do
			count = count + #list
		end
		return count
	end
	local function assertConfirmedOnce(fixture, label)
		assertEqual(1, #fixture.raid.loot, label .. " canonical record count differs")
		local row = fixture.raid.loot[1]
		assertEqual("item:19019", row.itemString, label .. " item key differs")
		assertEqual(2, row.itemCount, label .. " authoritative count differs")
		assertEqual(4, row.rollType, label .. " roll type differs")
		assertEqual(90, row.rollValue, label .. " roll value differs")
		assertEqual("CHAT_MSG_LOOT", row.source, label .. " record source differs")
		assertEqual(0, pendingCount(fixture), label .. " retained pending attribution")
		assertEqual(false, fixture.master._awardConfirmation:HasInFlight(), label .. " retained confirmation")
		assertEqual(1, fixture.assignments, label .. " physical effect count differs")
		assertEqual(1, fixture.attempts, label .. " attempt count differs")
		assertEqual(1, fixture.realProvisionalConfirmCalls, label .. " provisional confirmation count differs")
		assertEqual(1, fixture.distributionCalls, label .. " distribution checkpoint count differs")
		assertEqual(1, fixture.counterCalls, label .. " counter checkpoint count differs")
		local checkpoints = fixture.lastAttempt:GetState().checkpoints
		assertEqual(true, checkpoints.provisional_attribution, label .. " provisional checkpoint missing")
		assertEqual(true, checkpoints.distribution_notification, label .. " distribution checkpoint missing")
		assertEqual(true, checkpoints.player_counter, label .. " counter checkpoint missing")
	end
	local parsed = {
		msg = "loot-msg",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 2,
		playerName = "Winner",
	}

	local chatFirst = installLootHardeningMasterFixture(addon, { realLootFlow = true })
	assertTrue(chatFirst.master._Private.BtnAward(nil, nil), "chat-first controller admission failed")
	assertEqual(1, chatFirst.assignments, "chat-first controller admission did not reach effect")
	assertEqual(1, chatFirst.realAddPendingCalls, "chat-first admission did not call real loot service")
	assertEqual(1, chatFirst.realAttributionAddCalls, "chat-first admission did not call real attribution owner")
	assertEqual("item:19019", chatFirst.realAddPendingItem, "chat-first pending item differs")
	assertEqual("Winner", chatFirst.realAddPendingWinner, "chat-first pending winner differs")
	assertTrue(chatFirst.loot.LootAttribution.Refresh("item:19019", "Winner", 8, "RS:1") ~= nil,
		"chat-first real attribution owner cannot find admitted pending")
	assertEqual(1, pendingCount(chatFirst), "chat-first award did not create pending attribution")
	chatFirst.loot:AddLoot("loot-msg", nil, nil, parsed)
	assertEqual(0, #chatFirst.raid.loot, "chat-first event logged before slot confirmation")
	assertEqual(1, pendingCount(chatFirst), "chat-first event consumed pending before confirmation")
	local chatConfirmed, chatReason = chatFirst.master._awardConfirmation:Confirm(1)
	assertTrue(chatConfirmed, "chat-first confirmation failed: " .. tostring(chatReason))
	assertConfirmedOnce(chatFirst, "chat-first")
	local chatStale = chatFirst.timerCallbacks[chatFirst.realLootSetupTimers + 1]
	chatStale()
	assertEqual(1, #chatFirst.raid.loot, "chat-first stale timeout duplicated record")
	assertEqual(1, chatFirst.realProvisionalConfirmCalls, "chat-first stale timeout repeated confirmation")
	assertEqual(false, chatFirst.master._awardConfirmation:HasInFlight(), "chat-first stale timeout restored confirmation")
	assertTrue(chatFirst.master._Private.BtnAward(nil, nil), "chat-first next award was blocked")
	assertEqual(2, chatFirst.attempts, "chat-first next admission attempt count differs")

	local slotFirst = installLootHardeningMasterFixture(newAddon(), { realLootFlow = true })
	assertTrue(slotFirst.master._Private.BtnAward(nil, nil), "slot-first controller admission failed")
	assertTrue(slotFirst.master._awardConfirmation:Confirm(1), "slot-first confirmation failed")
	assertEqual(0, #slotFirst.raid.loot, "slot-first confirmation logged before chat/grace")
	assertEqual(false, slotFirst.master._awardConfirmation:HasInFlight(), "slot-first confirmation remained in flight")
	local slotGrace = slotFirst.timerCallbacks[slotFirst.realLootSetupTimers + 2]
	slotFirst.loot:AddLoot("loot-msg", nil, nil, parsed)
	assertConfirmedOnce(slotFirst, "slot-first")
	slotGrace()
	assertEqual(1, #slotFirst.raid.loot, "slot-first stale grace callback duplicated record")
	assertEqual(1, slotFirst.realProvisionalConfirmCalls, "slot-first stale grace repeated confirmation")
	assertEqual(false, slotFirst.master._awardConfirmation:HasInFlight(), "slot-first stale grace restored confirmation")
	assertTrue(slotFirst.master._Private.BtnAward(nil, nil), "slot-first next award was blocked")
	assertEqual(2, slotFirst.attempts, "slot-first next admission attempt count differs")
	print("PASS loot_award_event_orders_share_full_production_chain")
end

function cases.loot_master_warns_once_when_authoritative_reconciliation_fails(addon)
	local fixture = installLootHardeningMasterFixture(addon, { realLootFlow = true })
	local finalizeCalls = 0
	local logTradeOnlyLoot = fixture.loot.LogTradeOnlyLoot
	function fixture.loot:LogTradeOnlyLoot(...)
		finalizeCalls = finalizeCalls + 1
		return logTradeOnlyLoot(self, ...)
	end
	local parsed = {
		msg = "loot-msg",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 2,
		playerName = "Winner",
	}

	assertTrue(fixture.master._Private.BtnAward(nil, nil), "reconcile warning controller admission failed")
	assertTrue(fixture.master._awardConfirmation:Confirm(1), "reconcile warning slot confirmation failed")
	fixture.throwRaidLootUpdateAt = (fixture.raidLootUpdateCount or 0) + 2
	fixture.loot:AddLoot("loot-msg", nil, nil, parsed)
	assertEqual(1, finalizeCalls, "reconcile warning finalization count differs")
	assertEqual(1, #fixture.raid.loot, "reconcile warning canonical record count differs")
	assertEqual(1, fixture.warningCount, "reconcile failure must warn exactly once")
	assertEqual("attribution record_reconcile_failed", fixture.lastWarning,
		"reconcile failure warning text differs")
	assertEqual(nil, fixture.loot.LootAttribution.Remove(
		"item:19019", "Winner", 8, "RS:1", false, false
	), "reconcile failure retained pending ownership")

	fixture.loot:AddLoot("loot-msg", nil, nil, parsed)
	assertEqual(1, finalizeCalls, "duplicate authoritative event repeated finalization")
	assertEqual(1, #fixture.raid.loot, "duplicate authoritative event created another record")
	assertEqual(1, fixture.warningCount, "duplicate authoritative event repeated warning")
	print("PASS loot_master_warns_once_when_authoritative_reconciliation_fails")
end

function cases.loot_master_effect_boundary_is_failure_safe(addon)
	local function pendingCount(fixture)
		local count = 0
		for _ in pairs(fixture.pendingAttributions or {}) do count = count + 1 end
		return count
	end
	local function run(configure)
		local target = newAddon()
		local fixture = installLootHardeningMasterFixture(target)
		configure(fixture)
		local ok, reason = fixture.awardSequence:TrySingleCopy("item:19019", "Winner")
		return fixture, ok, reason
	end
	local fixture, ok, reason = run(function(value)
		value.slotValidationResult = nil
		value.slotValidationReason = "loot_slot_changed"
	end)
	assertEqual(nil, ok, "changed slot must fail closed")
	assertEqual("loot_slot_changed", reason, "changed slot reason differs")
	assertEqual(0, fixture.assignments, "changed slot reached GiveMasterLoot")
	assertEqual(0, pendingCount(fixture), "changed slot retained attribution")

	fixture, ok, reason = run(function(value) value.permissionDenied = true end)
	assertEqual(nil, ok, "permission change must fail closed")
	assertEqual("not_master_looter", reason, "permission reason differs")
	assertEqual(0, fixture.assignments, "permission change reached GiveMasterLoot")

	fixture, ok, reason = run(function(value) value.winnerIneligible = true end)
	assertEqual(nil, ok, "eligibility change must fail closed")
	assertEqual("winner_ineligible", reason, "eligibility reason differs")

	fixture, ok, reason = run(function(value) value.lootBanAtCheck = 2 value.candidateUnavailable = true end)
	assertEqual(nil, ok, "new Loot Ban must fail closed")
	assertEqual("loot_ban", reason, "Loot Ban must retain precedence over candidate failure")

	fixture, ok, reason = run(function(value) value.candidateUnavailable = true end)
	assertEqual(nil, ok, "candidate change must fail closed")
	assertEqual("candidate_unavailable", reason, "candidate reason differs")

	for _, mode in ipairs({ "nil", "throw" }) do
		fixture, ok, reason = run(function(value)
			value[mode == "nil" and "nilNextSchedule" or "throwNextSchedule"] = true
		end)
		assertEqual(nil, ok, mode .. " scheduler must fail closed")
		assertEqual("confirmation_schedule_failed", reason, mode .. " scheduler reason differs")
		assertEqual(false, fixture.master._awardConfirmation:HasPending(), mode .. " scheduler left confirmation")
		assertEqual(0, pendingCount(fixture), mode .. " scheduler left attribution")
		assertEqual(0, fixture.assignments, mode .. " scheduler reached GiveMasterLoot")
	end

	for _, mode in ipairs({ "throw", "false" }) do
		fixture, ok, reason = run(function(value)
			value[mode == "throw" and "throwGiveMasterLoot" or "rejectGiveMasterLoot"] = true
		end)
		assertEqual(nil, ok, mode .. " GiveMasterLoot must be contained")
		assertEqual("give_master_loot_failed", reason, mode .. " GiveMasterLoot reason differs")
		assertEqual(false, fixture.master._awardConfirmation:HasPending(), mode .. " GiveMasterLoot left confirmation")
		assertEqual(0, pendingCount(fixture), mode .. " GiveMasterLoot left attribution")
	end
	print("PASS loot_master_effect_boundary_is_failure_safe")
end

function cases.loot_master_success_and_timeout_follow_confirmation_evidence(addon)
	local function pendingCount(fixture)
		local count = 0
		for _ in pairs(fixture.pendingAttributions or {}) do count = count + 1 end
		return count
	end
	local fixture = installLootHardeningMasterFixture(addon)
	assertTrue(fixture.awardSequence:TrySingleCopy("item:19019", "Winner"), "award must reach pending confirmation")
	assertEqual(1, fixture.assignments, "physical award count differs")
	assertEqual(0, fixture.rollEndCalls or 0, "ROLL_END published before confirmation")
	assertEqual(0, fixture.distributionCalls, "ITEM_DONE published before confirmation")
	assertEqual(0, fixture.announcementCalls or 0, "announcement published before confirmation")
	assertEqual(0, fixture.whisperCalls or 0, "whisper published before confirmation")
	assertEqual(true, fixture.master._awardConfirmation:Confirm(1), "slot evidence must confirm award")
	assertEqual(1, fixture.rollEndCalls, "ROLL_END must publish exactly once")
	assertEqual(1, fixture.distributionCalls, "ITEM_DONE must publish exactly once")
	assertEqual(1, fixture.announcementCalls, "announcement must publish exactly once")
	assertEqual(1, fixture.whisperCalls, "whisper must publish exactly once")

	local failed = installLootHardeningMasterFixture(newAddon())
	assertTrue(failed.awardSequence:TrySingleCopy("item:19019", "Winner"), "UI failure fixture must queue")
	failed.pendingAttributions["AT:unrelated"] = true
	failed.master:UI_ERROR_MESSAGE("Inventory is full")
	assertEqual(false, failed.master._awardConfirmation:HasPending(), "known UI failure retained confirmation")
	assertEqual(1, pendingCount(failed), "known UI failure removed unrelated attribution")
	assertEqual(true, failed.pendingAttributions["AT:unrelated"], "known UI failure removed wrong transaction")
	assertEqual(0, failed.distributionCalls, "known UI failure published success")

	local present = installLootHardeningMasterFixture(newAddon())
	assertTrue(present.awardSequence:TrySingleCopy("item:19019", "Winner"), "present timeout fixture must queue")
	present.pendingAttributions["AT:unrelated"] = true
	present.timerCallbacks[1]()
	assertEqual(false, present.master._awardConfirmation:HasPending(), "present target timeout retained ownership")
	assertEqual(1, pendingCount(present), "present timeout removed unrelated attribution")
	assertEqual("failed", present.lastAttempt:GetState().state, "present timeout must become known failure")
	assertEqual(0, present.distributionCalls, "present timeout published success")

	local absent = installLootHardeningMasterFixture(newAddon())
	assertTrue(absent.awardSequence:TrySingleCopy("item:19019", "Winner"), "absent timeout fixture must queue")
	absent.slotValidationResult = nil
	absent.slotValidationReason = "loot_slot_missing"
	absent.timerCallbacks[1]()
	assertEqual(false, absent.master._awardConfirmation:HasPending(), "absent target did not retry confirmation")
	assertEqual("confirmed", absent.lastAttempt:GetState().state, "absent target confirmation retry failed")
	assertEqual(1, absent.distributionCalls, "absent target did not publish confirmed success")

	local unavailable = installLootHardeningMasterFixture(newAddon())
	assertTrue(unavailable.awardSequence:TrySingleCopy("item:19019", "Winner"), "unavailable timeout fixture must queue")
	unavailable.lootState.opened = false
	unavailable.timerCallbacks[1]()
	assertEqual(true, unavailable.master._awardConfirmation:HasPending(), "unavailable loot window resolved prematurely")
	assertEqual("uncertain", unavailable.lastAttempt:GetState().state, "unavailable loot window must remain uncertain")
	assertEqual(0, unavailable.distributionCalls, "unavailable loot window published success")
	unavailable.timerCallbacks[#unavailable.timerCallbacks]()
	assertEqual(false, unavailable.master._awardConfirmation:HasPending(), "uncertain expiry retained ownership")
	assertEqual(0, pendingCount(unavailable), "uncertain expiry retained stale attribution")
	print("PASS loot_master_success_and_timeout_follow_confirmation_evidence")
end

function cases.loot_master_announcement_failure_is_retry_safe(addon)
	local fixture = installLootHardeningMasterFixture(addon)
	assertTrue(fixture.awardSequence:TrySingleCopy("item:19019", "Winner"), "award must reach confirmation")
	fixture.rejectAnnouncement = true
	local confirmed, reason = fixture.master._awardConfirmation:Confirm(1)
	assertEqual(nil, confirmed, "failed announcement must retain confirmation ownership")
	assertEqual("send_failed", reason, "failed announcement reason differs")
	assertEqual("uncertain", fixture.lastAttempt:GetState().state, "failed announcement must remain retryable")
	assertEqual(true, fixture.master._awardConfirmation:HasPending(), "failed announcement released confirmation")
	assertEqual(1, fixture.rollEndCalls, "failed announcement duplicated ROLL_END")
	assertEqual(1, fixture.distributionCalls, "failed announcement duplicated ITEM_DONE")
	assertEqual(1, fixture.counterCalls, "failed announcement duplicated player counter")
	assertEqual(1, fixture.announcementCalls, "failed announcement attempt count differs")
	assertEqual(0, fixture.whisperCalls or 0, "whisper ran after failed announcement")

	fixture.rejectAnnouncement = false
	assertEqual(true, fixture.master._awardConfirmation:Confirm(1), "announcement retry must confirm")
	assertEqual(false, fixture.master._awardConfirmation:HasPending(), "successful retry retained confirmation")
	assertEqual(1, fixture.rollEndCalls, "announcement retry duplicated ROLL_END")
	assertEqual(1, fixture.distributionCalls, "announcement retry duplicated ITEM_DONE")
	assertEqual(1, fixture.counterCalls, "announcement retry duplicated player counter")
	assertEqual(2, fixture.announcementCalls, "announcement retry count differs")
	assertEqual(1, fixture.whisperCalls, "successful retry must whisper exactly once")
	print("PASS loot_master_announcement_failure_is_retry_safe")
end

function cases.warning_controller_reports_terminal_announcement_outcomes(addon)
	local infos, warnings, errors = {}, {}, {}
	local outcome = { true, nil, { sent = true, channel = "RAID", fallback = false } }
	addon.L = {
		MsgWarningAnnounced = "sent %s",
		MsgWarningLocalFallback = "local fallback",
		ErrWarningAnnouncement = "announcement failed: %s",
	}
	addon.info = function(_, message, value) infos[#infos + 1] = value and string.format(message, value) or message end
	addon.warn = function(_, message) warnings[#warnings + 1] = message end
	addon.error = function(_, message, value) errors[#errors + 1] = value and string.format(message, value) or message end
	addon.Controllers = {}
	addon.State.warningsSavedVariablesFresh = false
	addon.Database.RequireServiceMethod = function(_, owner, method) return assert(owner[method]) end
	addon.Services.Chat = { AnnounceWarningMessage = function() return unpack(outcome) end }
	addon.Services.Warnings = { Store = {
		GetStore = function() return { { name = "Pull", content = "Pull now" } } end,
		GetWarning = function(id) return id == 1 and { name = "Pull", content = "Pull now" } or nil end,
		EnsureDefaultTemplates = function() return { added = 0, total = 1 } end,
		DeleteWarning = function() return { deleted = true, total = 0 } end,
		SaveWarning = function() return 1 end,
	} }
	addon.Events.Internal = { WarningsDataChanged = "WarningsDataChanged" }
	addon.Bus.RegisterCallback = function() end
	local noopController = { Dirty = function() end }
	addon.UI = {
		Lists = {
			CreateController = function() return noopController end,
			MakeIndexedRowName = function() return "row" end,
			CreateRowRenderer = function(callback) return callback end,
		},
		Frames = { MakeModuleFrameGetter = function() return function() return nil end end },
		Scaffold = { DefineModule = function() end },
		Primitives = {}, EditBoxes = {},
		ModuleState = { Ensure = function() return {} end },
	}
	addon.Strings = { TrimText = function(value) return value or "" end }
	loadAddonFile(addon, "Raid Management Addon/Controllers/Warnings.lua")

	local ok, reason, detail = addon.Controllers.Warnings:RequestAnnounce(1)
	assertEqual(true, ok, "successful controller announce result differs")
	assertEqual(true, detail.sent, "controller must preserve delivery detail")
	assertEqual("sent RAID", infos[1], "controller must report confirmed channel delivery")
	outcome = { true, nil, { sent = false, channel = "LOCAL", fallback = true } }
	ok, reason, detail = addon.Controllers.Warnings:RequestAnnounce(1)
	assertEqual(true, ok, "local fallback keeps compatible success result")
	assertEqual("local fallback", warnings[1], "controller must identify local fallback")
	outcome = { nil, "send_failed", { sent = false, channel = "RAID", fallback = false, reason = "send_failed" } }
	ok, reason = addon.Controllers.Warnings:RequestAnnounce(1)
	assertEqual(nil, ok, "controller must preserve terminal failure")
	assertEqual("announcement failed: send_failed", errors[1], "controller must report terminal failure reason")
	print("PASS warning_controller_reports_terminal_announcement_outcomes")
end

function cases.loot_canonical_mutations_advance_revision_before_notification(addon)
	local fixture = installLootHardeningMasterFixture(addon, { realLootFlow = true })
	local loot = fixture.loot
	local recording = loot._Recording
	local function assertNextEventRevision(previousRevision, previousEvents, label)
		assertEqual(previousEvents + 1, #fixture.lootEventRevisions, label .. " event count differs")
		assertTrue(fixture.lootEventRevisions[#fixture.lootEventRevisions] > previousRevision,
			label .. " notified before revision advanced")
	end

	local previousRevision = fixture.lootRevision
	local previousEvents = #fixture.lootEventRevisions
	assertTrue(loot:LogTradeOnlyLoot(
		"item:19019", "Winner", addon.C.rollTypes.MANUAL, 90, 1,
		"MASTER_LOOT", 1, 1, "RS:direct"
	) > 0, "direct Master Loot record was not appended")
	assertNextEventRevision(previousRevision, previousEvents, "direct Master Loot append")

	loot:AddPendingAward(
		"item:19019", "Winner", addon.C.rollTypes.HOLD, 0, "RS:hold", nil,
		{ transactionId = "AT:hold" }
	)
	loot:AddLoot("loot-msg", nil, nil, {
		msg = "loot-msg", kind = "winner", itemLink = "item:19019", itemCount = 2, playerName = "Winner",
	})
	previousRevision = fixture.lootRevision
	previousEvents = #fixture.lootEventRevisions
	local provisional = loot.LootAttribution.ConfirmProvisional(
		"item:19019", "Winner", "RS:hold", 1, "AT:hold", 1, nil, nil,
		function()
			return loot:LogTradeOnlyLoot(
				"item:19019", "Winner", addon.C.rollTypes.HOLD, 0, 1,
				"LOOT_SLOT_CLEARED", 1, 1, "RS:hold"
			)
		end
	)
	assertTrue(provisional and provisional.finalized, "Hold award was not provisionally committed")
	assertEqual(previousEvents + 2, #fixture.lootEventRevisions, "authoritative Hold event count differs")
	assertTrue(fixture.lootEventRevisions[previousEvents + 1] > previousRevision,
		"provisional Hold append notified before revision advanced")
	assertTrue(fixture.lootEventRevisions[previousEvents + 2] > fixture.lootEventRevisions[previousEvents + 1],
		"authoritative Hold update notified before revision advanced")

	assertTrue(loot:LogTradeOnlyLoot(
		"item:19019", "Winner", addon.C.rollTypes.HOLD, 0, 1,
		"LOOT_SLOT_CLEARED", 1, 1, "RS:trade"
	) > 0, "trade fallback record was not appended")
	previousRevision = fixture.lootRevision
	previousEvents = #fixture.lootEventRevisions
	assertTrue(loot:LogTradeOnlyLoot(
		"item:19019", "Winner", addon.C.rollTypes.HOLD, 80, 2,
		"TRADE_ONLY", 1, 1, "RS:trade"
	) > 0, "later Hold trade completion was not merged")
	assertNextEventRevision(previousRevision, previousEvents, "Hold trade reconciliation")

	previousRevision = fixture.lootRevision
	previousEvents = #fixture.lootEventRevisions
	local invalid = recording.Append(fixture.raid, nil)
	assertEqual(nil, invalid, "invalid recording append was accepted")
	assertEqual(previousRevision, fixture.lootRevision, "failed commit advanced revision")
	assertEqual(previousEvents, #fixture.lootEventRevisions, "failed commit emitted a notification")
	print("PASS loot_canonical_mutations_advance_revision_before_notification")
end

function cases.raid_capabilities_accept_numeric_unit_identity(addon)
	local raidMaster = 2
	local unitOwners = {
		player = "Local",
		raid1 = "Local",
		raid2 = "Disonesta",
		raid3 = "Member",
	}
	local namedUnits = {
		Local = "raid1",
		Disonesta = "raid2",
		Member = "raid3",
	}

	_G.GetLootMethod = function()
		return "master", nil, raidMaster
	end
	_G.UnitIsUnit = function(left, right)
		if unitOwners[left] and unitOwners[left] == unitOwners[right] then
			return 1
		end
		return nil
	end
	_G.UnitName = function(unit)
		return unitOwners[unit]
	end

	addon.L = {}
	addon.warn = function() end
	addon.Database.GetUnitRank = function() return 0 end
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
	end
	addon.Services.Raid = {
		GetUnitID = function(_, name) return namedUnits[name] or "none" end,
		IsPlayerInRaid = function() return true end,
	}

	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Capabilities.lua")
	local Raid = addon.Services.Raid
	assertEqual("Disonesta", Raid:GetMasterLooterName(), "current raid master name differs")
	assertEqual(true, Raid:IsLootAuthority("Disonesta"), "numeric UnitIsUnit result must accept remote master looter")
	assertEqual(false, Raid:IsLootAuthority("Member"), "ordinary raid member must not be loot authority")
	assertEqual(false, Raid:IsLootAuthority("Outsider"), "outsider must not be loot authority")
	assertEqual(false, Raid:IsMasterLooter(), "local player must not own a remote master-loot role")

	raidMaster = 1
	assertEqual("Local", Raid:GetMasterLooterName(), "local raid master name differs")
	assertEqual(true, Raid:IsMasterLooter(), "numeric UnitIsUnit result must preserve local master-looter detection")
	print("PASS raid_capabilities_accept_numeric_unit_identity")
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
