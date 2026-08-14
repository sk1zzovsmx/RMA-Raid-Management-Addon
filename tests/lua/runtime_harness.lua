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
	_G.GetInventoryItemLink = function() return nil end
	_G.GetInventoryItemTexture = function() return nil end
	_G.GetInventoryItemQuality = function() return nil end
	_G.GetItemInfo = function() return nil end
	_G.NotifyInspect = function(unit)
		if fixture.notifyFails then error("notify failed") end
		fixture.inspectRequests[#fixture.inspectRequests + 1] = unit
	end
	loadAddonFile(addon, "Raid Management Addon/Services/EquipInspect.lua")
	fixture.inspectCallbacks = callbacks
	return fixture, addon.Services.EquipInspect
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

local caseName = arg[1]
local case = cases[caseName]
if not case then
	fail("unknown Lua behavior case: " .. tostring(caseName))
end

resetSavedVariables()
local addon = newAddon()
assertTrue(addon.State and addon.Database and addon.Services and addon.Events and addon.Bus)
case(addon)
