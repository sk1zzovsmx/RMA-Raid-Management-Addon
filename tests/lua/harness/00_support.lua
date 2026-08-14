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

local function assertContains(text, expected, message)
	if not string.find(tostring(text), expected, 1, true) then
		fail((message or "text does not contain expected value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(text))
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
	local diagnosticsPath = "Raid Management Addon/Localization/DiagnoseLog.en.lua"
	if
		path ~= diagnosticsPath
		and not (
			addon.Diag
			and addon.Diag.A
			and addon.Diag.A.BootstrapTimeApiNotInitialized
		)
	then
		local diagnosticsChunk = assert(loadfile(diagnosticsPath))
		diagnosticsChunk("Raid Management Addon", addon)
	end
	local chunk = assert(loadfile(path))
	chunk("Raid Management Addon", addon)
end

local function installPayloadCodec(addon)
	_G.strmatch = string.match
	local hasLibraries = false
	if type(_G.LibStub) == "function" then
		local okSerialize, serializeLibrary = pcall(_G.LibStub, "LibSerialize", true)
		local okDeflate, deflateLibrary = pcall(_G.LibStub, "LibDeflate", true)
		hasLibraries = okSerialize and serializeLibrary ~= nil and okDeflate and deflateLibrary ~= nil
	end
	if not hasLibraries then
		_G.LibStub = nil
		assert(loadfile("Raid Management Addon/Libs/LibStub/LibStub.lua"))()
		assert(loadfile("Raid Management Addon/Libs/LibSerialize/LibSerialize.lua"))()
		assert(loadfile("Raid Management Addon/Libs/LibDeflate/LibDeflate.lua"))()
	end
	local libSerialize = assert(_G.LibStub("LibSerialize"))
	local libDeflate = assert(_G.LibStub("LibDeflate"))
	addon.Comms = addon.Comms or {}
	addon.Comms.Payload = addon.Comms.Payload or {}
	local payload = addon.Comms.Payload
	function payload.Serialize(value)
		local okSerialize, serialized = pcall(libSerialize.Serialize, libSerialize, value)
		if not okSerialize or type(serialized) ~= "string" or serialized == "" then
			return nil, "SERIALIZE_FAILED"
		end
		local okEncode, encoded = pcall(libDeflate.EncodeForWoWAddonChannel, libDeflate, serialized)
		if not okEncode or type(encoded) ~= "string" or encoded == "" then
			return nil, "CHANNEL_ENCODE_FAILED"
		end
		return encoded
	end
	function payload.Deserialize(text)
		if type(text) ~= "string" or text == "" then
			return nil, "MALFORMED_PAYLOAD"
		end
		local okDecode, serialized = pcall(libDeflate.DecodeForWoWAddonChannel, libDeflate, text)
		if not okDecode or type(serialized) ~= "string" or serialized == "" then
			return nil, "CHANNEL_DECODE_FAILED"
		end
		local okCall, success, value = pcall(libSerialize.Deserialize, libSerialize, serialized)
		if not okCall or success ~= true then
			return nil, "DESERIALIZE_FAILED"
		end
		return value
	end
	return payload
end

local function assertR5Envelope(addon, message, expectedKind)
	local raw = assert(addon.Comms.Payload.Deserialize(message))
	local count = 0
	for key in pairs(raw) do
		assertTrue(type(key) == "number" and key >= 1 and key <= 5 and key == math.floor(key), "R5 envelope is sparse")
		count = count + 1
	end
	assertEqual(5, count, "R5 envelope slot count differs")
	assertEqual(5, raw[1], "R5 wire version differs")
	assertEqual(expectedKind, raw[2], "R5 message kind differs")
	assertTrue(raw[3] ~= nil, "R5 request slot is absent")
	assertTrue(raw[4] ~= nil, "R5 target slot is absent")
	assertTrue(type(raw[5]) == "table", "R5 body is absent")
	return raw
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
	_G.UnitName = function()
		return "Tester", "Test Realm"
	end
	_G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
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

	_G.LibStub = function()
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
		if type(sender) ~= "string" then
			return nil
		end
		local short = string.match(sender, "^([^%-]+)") or sender
		short = string.match(short, "^%s*(.-)%s*$")
		if short == "" then
			return nil
		end
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
			if rosterRaw == raw then
				return self.roster[i]
			end
			if self:NormalizeSender(rosterRaw) == normalized then
				found = self.roster[i]
				matchCount = (matchCount or 0) + 1
			end
		end
		if matchCount and matchCount > 1 then
			return nil, "short_name_collision"
		end
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
		if type(value) ~= "table" then
			return tostring(value)
		end
		local keys = {}
		for key in pairs(value) do
			keys[#keys + 1] = key
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
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
			chunks[#chunks + 1] =
				self:BuildChunk(kind, request, encodeDeterministic(rows), #chunks + 1, total, rawSender, target)
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
	local semanticSequence = { [41] = 1, [73] = 1 }
	function fixture.store:GetRaidByNid(raidNid)
		for i = 1, #fixture.raids do
			if fixture.raids[i].raidNid == raidNid then
				return fixture.raids[i], i
			end
		end
		return nil, nil
	end
	function fixture.store:GetRaidUid(raid)
		return raid and ("fixture-" .. tostring(raid.raidNid)) or nil
	end
	function fixture.store:CommitAuthoritativeEvent(raidUid, eventType, payload)
		local raidNid = tonumber(string.match(tostring(raidUid), "(%d+)$"))
		local raid = self:GetRaidByNid(raidNid)
		if not raid then
			return nil, "RAID_NOT_ACTIVE"
		end
		local function upsert(collection, field, entity)
			for i = 1, #collection do
				if tonumber(collection[i][field]) == tonumber(entity[field]) then
					collection[i] = deepCopy(entity)
					return
				end
			end
			collection[#collection + 1] = deepCopy(entity)
		end
		if eventType == "PLAYER_UPDATED" then
			upsert(raid.players, "playerNid", payload.player)
		elseif eventType == "PLAYER_DEPARTED" then
			for i = 1, #raid.players do
				if raid.players[i].playerNid == payload.playerNid then
					raid.players[i].leave = payload.leave
				end
			end
		elseif eventType == "ATTENDANCE_UPDATED" then
			upsert(raid.attendance, "playerNid", payload.attendance)
		elseif eventType == "BOSS_UPDATED" then
			upsert(raid.bossKills, "bossNid", payload.boss)
		elseif eventType == "LOOT_ADDED" or eventType == "LOOT_UPDATED" then
			upsert(raid.loot, "lootNid", payload.loot)
		elseif eventType == "LOOT_DELETED" then
			for i = #raid.loot, 1, -1 do
				if raid.loot[i].lootNid == payload.lootNid then
					table.remove(raid.loot, i)
				end
			end
		else
			return nil, "UNSUPPORTED_EVENT_TYPE"
		end
		semanticSequence[raidNid] = (semanticSequence[raidNid] or 1) + 1
		revisions[raidNid] = (revisions[raidNid] or 0) + 1
		fullSyncRevisions[raidNid] = revisions[raidNid]
		local event = { eventType = eventType, sequence = semanticSequence[raidNid] }
		return event, raid
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
		if self:GetRaidSyncRevision(raid) ~= staged._fixtureBaseRevision then
			return false, "CONFLICT"
		end
		staged._fixtureBaseRevision = nil
		local before = deepCopy(raid)
		local revisionBefore = self:GetRaidSyncRevision(raid)
		for key in pairs(raid) do
			raid[key] = nil
		end
		for key, value in pairs(deepCopy(staged)) do
			raid[key] = value
		end
		local ok, revision = pcall(self.TouchRaidSyncRevision, self, raid, reason)
		if not ok or type(revision) ~= "number" then
			for key in pairs(raid) do
				raid[key] = nil
			end
			for key, value in pairs(before) do
				raid[key] = value
			end
			self:SetRaidSyncRevision(raid, revisionBefore)
			return false, "COMMIT_FAILED"
		end
		return true
	end
	function fixture.store:RequiresFullSyncSince(raid, sinceRevision)
		return (fullSyncRevisions[raid.raidNid] or 0) > (tonumber(sinceRevision) or 0)
	end
	function fixture.store:CommitRaidInspectSnapshot(raid, playerNid, snapshot)
		local player
		for i = 1, #(raid.players or {}) do
			if tonumber(raid.players[i].playerNid) == tonumber(playerNid) then
				player = raid.players[i]
				break
			end
		end
		if not player then
			return nil, "missing inspect player"
		end
		local previous = deepCopy(player.inspect)
		local comparable = deepCopy(snapshot)
		if previous then
			previous.inspectedAt = nil
		end
		comparable.inspectedAt = nil
		if previous and deepEqual(previous, comparable) then
			return false
		end
		local candidate = deepCopy(player)
		candidate.inspect = deepCopy(snapshot)
		local event = self:CommitAuthoritativeEvent(self:GetRaidUid(raid), "PLAYER_UPDATED", { player = candidate })
		if not event then
			return nil
		end
		raid.inspect = raid.inspect or { players = {} }
		raid.inspect.players = raid.inspect.players or {}
		raid.inspect.players[playerNid] = deepCopy(snapshot)
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
	_G.GetNumPartyMembers = function()
		return 0
	end
	_G.GetRaidRosterInfo = function(index)
		local member = fixture.roster[index]
		if not member then
			return nil
		end
		return member.name,
			member.rank,
			member.subgroup,
			member.level,
			member.class,
			string.upper(member.class),
			nil,
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

local function installCanonicalRaidStoreFixture(addon, fixture, activeRaidNid)
	local function adler32(text)
		local a, b = 1, 0
		for i = 1, #text do
			a = (a + string.byte(text, i)) % 65521
			b = (b + a) % 65521
		end
		return b * 65536 + a
	end

	_G.LibStub = function(name)
		assertEqual("LibDeflate", name)
		return {
			Adler32 = function(_, text)
				return adler32(text)
			end,
		}
	end
	_G.GetTime = _G.GetTime or function()
		return fixture.now
	end
	_G.UnitFullName = _G.UnitFullName or function()
		return "Tester", "Test Realm"
	end

	local sourceRaids = deepCopy(fixture.raids)
	local archive = { formatVersion = 1, activeRaidUid = nil, order = {}, raids = {} }
	local function syncOrderedRaids()
		for key in pairs(fixture.raids) do
			fixture.raids[key] = nil
		end
		for i = 1, #archive.order do
			local record = archive.raids[archive.order[i]]
			fixture.raids[i] = record and record.state or nil
		end
		return fixture.raids
	end

	addon.Database.SavedVariables = {
		GetRaids = function()
			return archive
		end,
		ReplaceRaids = function(value)
			archive = value
			fixture.archive = archive
			syncOrderedRaids()
			return archive
		end,
		GetRaidArchiveError = function()
			return nil
		end,
	}
	addon.IgnoredMobs = addon.IgnoredMobs or {
		IsTrashMobName = function()
			return false
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidEvents.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidValidator.lua")
	addon.Database.GetRaidValidator = function()
		return addon.DB.RaidValidator
	end
	local triggerEvent = addon.Bus.TriggerEvent
	addon.Bus.TriggerEvent = function() end
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidStore.lua")
	addon.Bus.TriggerEvent = triggerEvent
	local store = addon.DB.RaidStore
	assertTrue(
		store:SetAuthorityGuard(function()
			return true
		end),
		"canonical fixture authority guard failed"
	)

	local archiveKeyByRaidNid = {}
	local function createSeedRaid(state, active)
		local raid, _, archiveKey = assert(store:CreateActiveRaid({
			authorityKey = "Tester-TestRealm",
			serverTime = state.startTime,
			raidNid = state.raidNid,
			realm = state.realm,
			zone = state.zone,
			size = state.size,
			difficulty = state.difficulty,
			players = state.players,
			bossKills = state.bossKills,
			loot = state.loot,
			attendance = state.attendance,
			nextPlayerNid = state.nextPlayerNid,
			nextBossNid = state.nextBossNid,
			nextLootNid = state.nextLootNid,
		}))
		archiveKeyByRaidNid[raid.raidNid] = archiveKey
		if not active then
			assert(
				store:ConcludeActiveRaid(archiveKey, math.max(fixture.now, tonumber(state.startTime) or fixture.now))
			)
		end
	end

	for i = 1, #sourceRaids do
		if tonumber(sourceRaids[i].raidNid) ~= tonumber(activeRaidNid) then
			createSeedRaid(sourceRaids[i], false)
		end
	end
	for i = 1, #sourceRaids do
		if tonumber(sourceRaids[i].raidNid) == tonumber(activeRaidNid) then
			createSeedRaid(sourceRaids[i], true)
		end
	end
	for i = 1, #sourceRaids do
		archive.order[i] = archiveKeyByRaidNid[sourceRaids[i].raidNid]
	end

	fixture.archive = archive
	fixture.archiveKeyByRaidNid = archiveKeyByRaidNid
	fixture.GetRaids = syncOrderedRaids
	fixture.GetRaid = function(_, index)
		return syncOrderedRaids()[index]
	end
	fixture.RefreshRaidRecord = function(_, raid)
		local archiveKey = store:GetRaidUid(raid)
		local record = archiveKey and archive.raids[archiveKey] or nil
		assertTrue(record ~= nil, "canonical fixture raid record is missing")
		record.digest = assert(addon.DB.RaidEvents.DigestState(record.state))
		if record.status == "active" and #record.events == 1 and record.events[1].eventType == "RAID_CREATED" then
			record.events[1].payload.state = deepCopy(record.state)
			record.events[1].resultDigest = record.digest
		end
		assertTrue(addon.Database.GetRaidValidator():ValidateRecord(record), "canonical fixture record refresh failed")
		return record
	end
	fixture.store = store
	addon.Database.GetRaidStore = function()
		return store
	end
	addon.Database.EnsureRaidByIndex = function(index)
		return store:EnsureRaidByIndex(index)
	end
	addon.Database.EnsureRaidByNid = function(raidNid)
		return store:EnsureRaidByNid(raidNid)
	end
	syncOrderedRaids()
	for i = #fixture.events, 1, -1 do
		fixture.events[i] = nil
	end
	return store
end

local function installRealAttendanceFixture(addon, fixture)
	local callbacks = {}
	_G.strlower = string.lower
	fixture.raids[2].raidNid = 42
	fixture.raids[2].players = { { playerNid = 21, name = "Beta", join = 975 } }
	fixture.raids[2].attendance = {}
	fixture.store:SetRaidSyncRevision(fixture.raids[2], 0)
	fixture.roster = { { name = "Beta", rank = 0, subgroup = 1, level = 80, class = "Priest", online = true } }

	addon.Events = {
		Internal = {
			RaidAttendanceChanged = "RaidAttendanceChanged",
			RaidRosterDelta = "RaidRosterDelta",
			RaidCreate = "RaidCreate",
		},
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
		end,
	}
	addon.Time = {
		GetCurrentTime = function()
			return fixture.now
		end,
	}
	addon.Database.EnsureRaidByIndex = function(index)
		return fixture.raids[index]
	end
	addon.Database.EnsureRaidSchema = function(raid)
		return raid
	end
	addon.Bus.RegisterCallback = function(eventName, callback)
		callbacks[eventName] = callback
	end

	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Attendance.lua")
	fixture.attendanceCallbacks = callbacks
	return addon.Services.Raid
end

local function installRaidCreationFixture(addon, failureMode)
	local fixture = newRaidRecordingFixture(addon)
	local callbacks = {}
	fixture.currentRaid = 1
	fixture.raids[1].attendance = { { playerNid = 11, segments = { { startTime = 900 } } } }
	fixture.order = {}
	_G.table.wipe = _G.table.wipe
		or function(target)
			for key in pairs(target) do
				target[key] = nil
			end
			return target
		end
	_G.UnitRace = function()
		return "Human", "Human"
	end
	_G.UnitExists = function()
		return true
	end
	_G.UnitGUID = function()
		return nil
	end
	_G.UnitIsDead = function()
		return false
	end
	_G.GetInstanceInfo = function()
		return "Ulduar", "raid", 2
	end
	_G.UNKNOWNOBJECT = "Unknown"
	addon.L = { RaidZones = {} }
	addon.Diag = { I = { LogRaidCreated = "%d %s %d %d", LogRaidEnded = "%d %s %d %d %d %d" } }
	addon.C = {}
	addon.State = { currentRaid = 1, raid = { numRaid = 7, marker = "old" }, raidStore = {} }
	addon.DB = {}
	addon.Strings = {
		TrimText = function(value)
			return value
		end,
	}
	addon.Time = {
		GetCurrentTime = function()
			return fixture.now
		end,
	}
	addon.Base64, addon.LootSources, addon.LootSourceCandidates = {}, {}, {}
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Events = {
		Internal = {
			RaidCreate = "RaidCreate",
			RaidAttendanceChanged = "RaidAttendanceChanged",
			RaidAuthorityRecoveryFinished = "RaidAuthorityRecoveryFinished",
			RaidReentryRecoveryReady = "RaidReentryRecoveryReady",
			RaidReentryDecisionRequired = "RaidReentryDecisionRequired",
			RaidReentryDecisionResolved = "RaidReentryDecisionResolved",
		},
	}
	addon.Bus.RegisterCallback = function(eventName, callback)
		callbacks[eventName] = callbacks[eventName] or {}
		callbacks[eventName][#callbacks[eventName] + 1] = callback
	end
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
		end,
		Loot = {
			_State = {
				SetField = function() end,
				SetActive = function() end,
				SyncActive = function() end,
				Reset = function() end,
			},
			_Sessions = {},
			_Snapshots = {},
			_Context = {},
		},
	}
	addon.IsInRaid = function()
		return true
	end
	addon.Group = {
		GetTypeAndCount = function()
			return "raid", 1, #fixture.roster
		end,
		GetNumMembers = function()
			return #fixture.roster
		end,
	}
	addon.Database.GetRealmName = function()
		return "Test Realm"
	end
	addon.Database.GetPlayerName = function()
		return "Tester"
	end
	addon.Database.GetCurrentRaid = function()
		return addon.State.currentRaid
	end
	addon.Database.SetCurrentRaid = function(value)
		addon.State.currentRaid = value
		return value
	end
	addon.Database.GetLastBoss = function()
		return addon.State.lastBoss
	end
	addon.Database.SetLastBoss = function(value)
		addon.State.lastBoss = value
		return value
	end
	addon.info = function() end
	addon.Database.IsBossFightRecord = function()
		return true
	end
	addon.Database.GetRaidSchemaVersion = function()
		return 6
	end
	installCanonicalRaidStoreFixture(addon, fixture, 41)
	local syncSequenceByRaid = setmetatable({}, { __mode = "k" })
	function fixture.store:GetRaidSyncRevision(raid)
		return tonumber(raid and syncSequenceByRaid[raid]) or 0
	end
	function fixture.store:SetRaidSyncRevision(raid, sequence)
		syncSequenceByRaid[raid] = tonumber(sequence) or 0
		return syncSequenceByRaid[raid]
	end
	function fixture.store:TouchRaidSyncRevision(raid)
		return self:SetRaidSyncRevision(raid, self:GetRaidSyncRevision(raid) + 1)
	end
	function fixture.store:MarkLootSyncRevision(raid, loot)
		local sequence = self:TouchRaidSyncRevision(raid)
		loot.syncRevision = sequence
		return sequence
	end
	function fixture.store:GetLootSyncRevision(_, _, loot)
		return tonumber(loot and loot.syncRevision) or 0
	end
	function fixture.store:SetLootSyncRevision(_, _, loot, sequence)
		loot.syncRevision = tonumber(sequence) or 0
		return loot.syncRevision
	end
	function fixture.store:RequiresFullSyncSince(raid, sequence)
		return self:GetRaidSyncRevision(raid) > (tonumber(sequence) or 0)
	end
	local captureHistory = fixture.store.CaptureRaidHistoryState
	local restoreHistory = fixture.store.RestoreRaidHistoryState
	fixture.store.CaptureRaidHistoryState = function(self)
		fixture.historyCaptures = (fixture.historyCaptures or 0) + 1
		return captureHistory(self)
	end
	fixture.store.RestoreRaidHistoryState = function(self, snapshot)
		fixture.historyRestores = (fixture.historyRestores or 0) + 1
		local restored, reason = restoreHistory(self, snapshot)
		fixture:GetRaids()
		return restored, reason
	end
	fixture.store:EnsureRaidByIndex(1)
	fixture.store:EnsureRaidByIndex(2)
	local realCreateActive = fixture.store.CreateActiveRaid
	local realConcludeActive = fixture.store.ConcludeActiveRaid
	fixture.store.CreateActiveRaid = function(self, args)
		fixture.candidateRaidNid = args and args.raidNid
		local inserted, index, archiveKey = realCreateActive(self, args)
		fixture.candidateRaidNid = inserted and inserted.raidNid or fixture.candidateRaidNid
		fixture:GetRaids()
		if inserted then
			fixture.order[#fixture.order + 1] = "insert"
		end
		return inserted, index, archiveKey
	end
	fixture.store.ConcludeActiveRaid = function(self, ...)
		local event, state = realConcludeActive(self, ...)
		fixture:GetRaids()
		return event, state
	end
	if failureMode == "create_nil" then
		fixture.store.CreateActiveRaid = function(_, args)
			fixture.candidateRaidNid = args and args.raidNid
			return nil
		end
	elseif failureMode == "create_throw" then
		fixture.store.CreateActiveRaid = function(_, args)
			fixture.candidateRaidNid = args and args.raidNid
			error("create failure")
		end
	elseif failureMode == "conclude_nil" then
		fixture.store.ConcludeActiveRaid = function()
			return nil
		end
	elseif failureMode == "conclude_throw" then
		fixture.store.ConcludeActiveRaid = function()
			error("conclusion failure")
		end
	end
	if failureMode == "delete_false" then
		fixture.store.DeleteRaid = function()
			return false
		end
	end
	if failureMode == "delete_throw" then
		fixture.store.DeleteRaid = function()
			error("delete failure")
		end
	end
	fixture.realCreateActive, fixture.realConcludeActive = realCreateActive, realConcludeActive
	addon.Bus.TriggerEvent = function(eventName, ...)
		fixture.events[#fixture.events + 1] = { name = eventName, args = { ... } }
		fixture.order[#fixture.order + 1] = eventName
		if eventName == "RaidAttendanceChanged" then
			fixture.attendanceEventCurrentRaid = addon.Database.GetCurrentRaid()
		end
		local listeners = callbacks[eventName] or {}
		for i = 1, #listeners do
			listeners[i](eventName, ...)
		end
	end
	fixture.callbacks = callbacks
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
	loadAddonFile(addon, "Raid Management Addon/Modules/Group.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/State.lua")
	raid._ScheduleRosterRefreshInternal = function() end
	raid._CancelRosterRefreshInternal = function() end
	function raid:CloseAttendanceForRaid(record, currentTime, reason, deferPublication)
		record.attendance[1].segments[1].endTime = currentTime
		fixture.store:TouchRaidSyncRevision(record)
		if not deferPublication then
			addon.Bus.TriggerEvent("RaidAttendanceChanged", record.raidNid, reason)
		end
		return true, record.raidNid
	end
	return fixture, raid
end

local function installRaidReplicationEventFixture(addon)
	local function adler32(text)
		local a, b = 1, 0
		for i = 1, #text do
			a = (a + string.byte(text, i)) % 65521
			b = (b + a) % 65521
		end
		return b * 65536 + a
	end
	_G.LibStub = function(name)
		assertEqual("LibDeflate", name)
		return {
			Adler32 = function(_, text)
				return adler32(text)
			end,
		}
	end
	addon.DB = addon.DB or {}
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidEvents.lua")
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
	_G.table.wipe = _G.table.wipe
		or function(target)
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
	addon.Diag = { D = setmetatable({}, {
		__index = function()
			return "%s %s %s %s %s %s"
		end,
	}) }
	addon.Diag.W = setmetatable({}, {
		__index = function()
			return "%s %s %s %s %s %s"
		end,
	})
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
				IsActive = function()
					return false
				end,
				Get = function()
					return false
				end,
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
		addon = addon,
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
		publicationOrder = {},
		busCallbacks = {},
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
	fixture.lootState = lootState
	local noop = function() end
	local dummyController = setmetatable({}, {
		__index = function()
			return noop
		end,
	})
	dummyController.HasInFlightAward = function()
		return fixture.tradeInFlight == true
	end
	fixture.tradeController = dummyController
	local frameApi = {
		GetRef = function()
			return nil
		end,
		SetScriptSafely = noop,
		BindModuleFrame = function()
			return "RMAMaster"
		end,
		MakeModuleFrameGetter = function()
			return function()
				return nil
			end
		end,
		SetFrameTitle = noop,
	}

	_G.table.wipe = _G.table.wipe
		or function(target)
			for key in pairs(target) do
				target[key] = nil
			end
			return target
		end
	_G.CreateFrame = function()
		return setmetatable({}, {
			__index = function()
				return noop
			end,
		})
	end
	_G.UnitName = function()
		return "Tester"
	end
	_G.GetMasterLootCandidate = function()
		return "Winner"
	end
	_G.GetRaidRosterInfo = function()
		return "Winner", 0, 1, 80, "Warrior", "WARRIOR"
	end
	_G.GetLootSlotInfo = function()
		return nil, "Test Item", 1, 4
	end
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
	_G.UIDropDownMenu_CreateInfo = function()
		return {}
	end
	_G.UIDropDownMenu_Initialize = noop
	_G.UIDropDownMenu_JustifyText = noop
	_G.UIDropDownMenu_SetButtonWidth = noop
	_G.UIDropDownMenu_SetSelectedValue = noop
	_G.UIDropDownMenu_SetText = noop
	_G.UIDropDownMenu_SetWidth = noop
	_G.ClearCursor = noop
	_G.CursorHasItem = function()
		return false
	end
	_G.GetCursorInfo = noop
	_G.GetContainerItemInfo = noop
	_G.GetContainerItemLink = noop
	_G.InitiateTrade = noop
	_G.PickupContainerItem = noop
	_G.SetRaidTarget = noop
	_G.CheckInteractDistance = function()
		return true
	end

	addon.L = setmetatable({}, {
		__index = function(_, key)
			return key .. " %s %s %s %s %s %s"
		end,
	})
	addon.L.WarnMLAwardConfirmationUncertain = "uncertain %s %s %s"
	addon.L.WarnMLAwardConfirmationUnresolved = "unresolved %s %s"
	addon.L.WarnMLLootAttributionFailed = "attribution %s"
	addon.L.ErrMLWinnerLootBanned = "banned %s"
	addon.L.ErrMLWinnerLootBannedWithNote = "banned %s %s"
	addon.L.WarnMLWinnerNoCandidate = "no candidate %s"
	addon.L.ChatAward = "%s won %s"
	addon.L.ChatAwardMutiple = "%s won %s"
	addon.Diag = {
		D = setmetatable({}, {
			__index = function()
				return "%s %s %s %s %s %s"
			end,
		}),
		E = setmetatable({}, {
			__index = function()
				return "%s %s %s %s %s %s"
			end,
		}),
		I = setmetatable({}, {
			__index = function()
				return "%s %s %s %s %s %s"
			end,
		}),
		W = setmetatable({}, {
			__index = function()
				return "%s %s %s %s %s %s"
			end,
		}),
	}
	addon.EntryPoints = { Debug = { RegisterCommand = noop } }
	addon.UI = {
		Frames = frameApi,
		Tooltips = { Bind = noop, Hide = noop },
		Lists = {
			CreateController = function()
				return dummyController
			end,
			CreateRowRenderer = function()
				return noop
			end,
			MakeIndexedRowName = function()
				return "Row"
			end,
		},
		Primitives = setmetatable({}, {
			__index = function()
				return noop
			end,
		}),
		Rows = setmetatable({}, {
			__index = function()
				return noop
			end,
		}),
		Popups = {
			Define = function()
				return true
			end,
			IsDefined = function()
				return true
			end,
			Show = noop,
			ShowConfirm = noop,
		},
		ModuleState = {
			Ensure = function()
				return {}
			end,
		},
		Scaffold = { DefineModule = noop },
		EditBoxes = { SetValue = noop },
	}
	addon.Item = {
		GetItemStringFromLink = function()
			return "item:19019"
		end,
	}
	addon.Group = addon.Group or {}
	addon.Group.IterateUnits = function()
		return function()
			return nil
		end
	end
	addon.Colors = {}
	addon.Comms = {
		SendWhisper = function()
			fixture.whisperCalls = (fixture.whisperCalls or 0) + 1
			return true
		end,
	}
	addon.Events = {
		Internal = setmetatable({}, {
			__index = function(_, key)
				return key
			end,
		}),
		ResolveWowForwardedName = function(name)
			return name
		end,
	}
	addon.C = setmetatable({
		rollTypes = {
			MAINSPEC = 1,
			OFFSPEC = 2,
			RESERVED = 3,
			FREE = 4,
			MANUAL = 5,
			HOLD = 6,
			BANK = 7,
			DISENCHANT = 8,
		},
		ML_AWARD_CONFIRM_TIMEOUT_SECONDS = 4,
		ML_MULTI_AWARD_TIMEOUT_SECONDS = 4,
		ML_MULTI_AWARD_DELAY = 0,
	}, {
		__index = function()
			return 30
		end,
	})
	addon.Database = {
		EnsureLootRuntimeState = function()
			return {}, lootState, {}
		end,
		RequireServiceMethod = function(_, owner, method)
			return function(target, ...)
				return owner[method](target, ...)
			end
		end,
		GetCurrentRaid = function()
			return 1
		end,
		GetPlayerName = function()
			return "Tester"
		end,
		GetRaidStore = function()
			return {
				EnsureRaidByIndex = function()
					return {}
				end,
			}
		end,
	}
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
		RegisterNamespace = noop,
		GetValue = function(_, key)
			return key == "announceOnWin" and fixture.announceOnWin == true
		end,
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
		RegisterCallback = function(eventName, callback)
			fixture.busCallbacks[eventName] = fixture.busCallbacks[eventName] or {}
			fixture.busCallbacks[eventName][#fixture.busCallbacks[eventName] + 1] = callback
		end,
	}
	addon.Controllers = { Logger = {}, Config = {} }
	addon.Widgets = {
		RaidGrid = { Hide = noop },
		LootHints = { ApplyLootFrameReserveHints = noop, ClearLootFrameReserveHints = noop },
		TradeMenu = setmetatable({}, {
			__index = function()
				return noop
			end,
		}),
		ItemSelection = {
			CreateController = function()
				return dummyController
			end,
		},
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
		for _ in pairs(fixture.activeTimerHandles) do
			count = count + 1
		end
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
		if type(fixture.onWarn) == "function" then
			fixture.onWarn()
		end
	end
	addon.info = noop
	addon.debug = noop
	addon.error = noop
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
		Chat = {
			Announce = function()
				fixture.announcementCalls = (fixture.announcementCalls or 0) + 1
				if fixture.throwAnnouncement then
					error("announcement exploded")
				end
				if fixture.rejectAnnouncement then
					return nil, "send_failed"
				end
				return true
			end,
		},
		Logger = { Actions = {} },
		Loot = {
			DistributionSession = {
				PublishItem = function(item)
					fixture.itemPublications = (fixture.itemPublications or 0) + 1
					fixture.lastPublishedItem = deepCopy(item)
					fixture.publicationOrder[#fixture.publicationOrder + 1] = "ITEM"
					return fixture.rejectItemPublication ~= true
				end,
				PublishRollStart = function(_, rollType)
					fixture.rollStartCalls = (fixture.rollStartCalls or 0) + 1
					fixture.lastPublishedRollType = rollType
					fixture.publicationOrder[#fixture.publicationOrder + 1] = "ROLL_START"
					return fixture.rejectRollStart ~= true
				end,
				PublishItemDone = function()
					fixture.distributionCalls = fixture.distributionCalls + 1
					fixture.publicationOrder[#fixture.publicationOrder + 1] = "ITEM_DONE"
					return fixture.rejectDistribution ~= true
				end,
				PublishItemCancelled = function()
					fixture.cancelledPublications = (fixture.cancelledPublications or 0) + 1
					return true
				end,
				PublishRollEnd = function(_, _, _, reason)
					fixture.rollEndCalls = (fixture.rollEndCalls or 0) + 1
					fixture.lastPublishedReason = reason
					fixture.publicationOrder[#fixture.publicationOrder + 1] = "ROLL_END"
					return fixture.rejectRollEnd ~= true
				end,
			},
			Inventory = {
				FindLootSlotIndex = function()
					return 1
				end,
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
				BuildAwardTargetPlan = function()
					return { target = 1, available = 1 }
				end,
				BuildMultiAwardWinnersPlan = function(opts)
					return { winners = opts.pickedWinners }
				end,
				BuildMultiAwardState = function(opts)
					return {
						state = {
							active = true,
							itemLink = opts.itemLink,
							winners = opts.winners,
							total = #opts.winners,
							pos = 2,
							rollType = opts.rollType,
							itemKey = "item:19019",
							lastCount = opts.available,
							announceOnWin = opts.announceOnWin,
						},
					}
				end,
			},
			LootAttribution = {
				ConfirmProvisional = function()
					return true
				end,
				IsMasterLootAwardFailureMessage = function(message)
					return message == "Inventory is full"
				end,
			},
			GetItemLink = function()
				return "item:19019"
			end,
			GetCurrentItemCount = function()
				return 1
			end,
			FetchLoot = function()
				fixture.fetchCalls = (fixture.fetchCalls or 0) + 1
			end,
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
			LootBans = {
				Get = function()
					fixture.lootBanChecks = (fixture.lootBanChecks or 0) + 1
					return fixture.lootBanAtCheck == fixture.lootBanChecks, "changed ban"
				end,
			},
			Debug = {},
			AddPlayerCountForRollType = function()
				fixture.counterCalls = fixture.counterCalls + 1
				return fixture.rejectCounter ~= true
			end,
			GetRosterVersion = function()
				return 1
			end,
			RequestMasterLootCandidateRefresh = noop,
			FindMasterLootCandidateIndex = function()
				if fixture.candidateUnavailable then
					return nil
				end
				return 1
			end,
			CanResolveMasterLootCandidates = function()
				return true
			end,
			CanUseCapability = function()
				return true
			end,
			EnsureMasterOnlyAccess = function()
				return true
			end,
			IsMasterLooter = function()
				return fixture.permissionDenied ~= true
			end,
			IsRaidLeader = function()
				return options.canonicalAuthority ~= false
			end,
			CanCommitRaidHistory = function()
				return options.canonicalAuthority ~= false
			end,
		},
		Rolls = {
			GetRollSession = function()
				return { id = "RS:1" }
			end,
			GetDisplayModel = function()
				return {
					resolution = {},
					requiredWinnerCount = 1,
					winner = "Winner",
					rows = { { name = "Winner", roll = 90 } },
				}
			end,
			BeginTieReroll = function()
				return false
			end,
			IsCountdownRunning = function()
				return false
			end,
			StopCountdown = noop,
			ShouldUseTieReroll = function()
				return false
			end,
			FreezeRollIntake = function()
				return { resolution = {}, requiredWinnerCount = 1, winner = "Winner", rollWinner = "Winner" }, "award"
			end,
			GetHighestRoll = function()
				return 90
			end,
			ValidateWinner = function()
				return fixture.winnerIneligible and { ok = false, warnMessage = "ineligible" } or { ok = true }
			end,
			EnsureLootRollSession = function()
				return { id = "RS:1" }
			end,
			ClearRolls = function()
				fixture.rollClearCalls = (fixture.rollClearCalls or 0) + 1
			end,
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
		_G.GetLootThreshold = function()
			return 2
		end
		_G.GetNumLootItems = function()
			return 0
		end
		_G.GetTime = function()
			return 10
		end
		_G.GetItemInfo = function()
			return "Thunderfury", nil, 5, nil, nil, "Weapon", nil, nil, nil, "texture"
		end
		addon.Deformat = function()
			return nil
		end
		addon.Strings = {
			NormalizeName = function(value)
				return value
			end,
		}
		addon.Time = {
			GetCurrentTime = function()
				return 10
			end,
		}
		addon.Item.GetItemIdFromLink = function()
			return 19019
		end
		addon.Item.GetItemKey = function()
			return "item:19019"
		end
		addon.Options.NormalizeLoggerLootQualityThreshold = function(value)
			return tonumber(value) or 2
		end
		addon.Database.EnsureLootRuntimeState = function()
			return {}, lootState, {}, {}
		end
		addon.Database.GetRaidQueries = function()
			return {
				ResolveLootLooterName = function()
					return "Winner"
				end,
			}
		end
		fixture.lootStore = {
			EnsureRaidByIndex = function()
				return fixture.raid
			end,
			GetRaidUid = function()
				return "fixture-loot"
			end,
			CommitAuthoritativeEvent = function(_, _, eventType, payload)
				if eventType == "LOOT_ADDED" then
					fixture.raid.loot[#fixture.raid.loot + 1] = deepCopy(payload.loot)
				elseif eventType == "LOOT_UPDATED" then
					for i = 1, #fixture.raid.loot do
						if fixture.raid.loot[i].lootNid == payload.loot.lootNid then
							fixture.raid.loot[i] = deepCopy(payload.loot)
						end
					end
				end
				fixture.lootRevision = fixture.lootRevision + 1
				return { eventType = eventType, sequence = fixture.lootRevision }, fixture.raid
			end,
			GetRaidSyncRevision = function()
				return fixture.lootRevision
			end,
			MarkLootSyncRevision = function()
				fixture.lootRevision = fixture.lootRevision + 1
				return fixture.lootRevision
			end,
			UpsertLootIndex = function()
				return true
			end,
		}
		addon.Database.GetRaidStore = function()
			return fixture.lootStore
		end
		addon.Bus.TriggerEvent = function(eventName)
			if eventName == "RaidLootUpdate" then
				fixture.raidLootUpdateCount = (fixture.raidLootUpdateCount or 0) + 1
				fixture.lootEventRevisions[#fixture.lootEventRevisions + 1] = fixture.lootRevision
				if fixture.throwRaidLootUpdateAt == fixture.raidLootUpdateCount then
					error("injected authoritative reconciliation failure")
				end
			end
		end
		addon.Services.Raid.EnsureRaidPlayerNid = function(_, name)
			return 1, name
		end
		addon.Services.Raid.FindOrCreateBossNidForLoot = function()
			return 1
		end
		addon.Services.Raid.GetActiveLootSource = function()
			return nil
		end
		local noopLootOwner = setmetatable({}, {
			__index = function()
				return function() end
			end,
		})
		addon.Services.Loot._PassiveGroupLoot = setmetatable({
			IsPassiveGroupLootMethod = function()
				return false
			end,
			IsPassiveLootWinnerMessage = function()
				return false
			end,
			ParseGroupLootWinner = function()
				return nil
			end,
			GetPassiveLootRollItemKey = function(link)
				return link
			end,
		}, getmetatable(noopLootOwner))
		addon.Services.Loot._Tracking = noopLootOwner
		addon.Services.Loot._Workflow = setmetatable({
			QueueAward = function() end,
			RecordReceipt = function() end,
			BeginLootWindow = function() end,
			SelectItem = function() end,
		}, getmetatable(noopLootOwner))
		addon.Services.Loot._Rules = {
			_IsIgnoredItem = function()
				return false
			end,
			GetItemSuggestion = function()
				return nil
			end,
		}
		addon.Services.Loot._Context = {
			ResolveRaidRecord = function()
				return 1, fixture.raid
			end,
		}
		addon.Services.Loot.DistributionSession.BeginWindow = function()
			return 1
		end
		addon.Services.Loot.DistributionSession.PublishWindowItems = function()
			return true
		end
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
				BuildModel = function()
					return addon.Services.Rolls:GetDisplayModel()
				end,
				GetSelectedCount = function()
					return 0
				end,
				GetSelectedWinnersOrdered = function()
					return {}
				end,
				ResetSelection = noop,
				ClearAnchor = noop,
				CopyVisibleRows = function()
					return {}
				end,
				GetFocusedRowId = function()
					return nil
				end,
			}
		end,
	}
	addon.Services.Master.Assignment = {
		BuildCandidateRows = function()
			return {}
		end,
	}
	addon.Services.Master.Messages = {
		BuildAssignMessages = function()
			return "award output", "award whisper"
		end,
	}
	addon.Services.Master.Trade = {
		ApplyAccept = function()
			return nil
		end,
		CancelClose = function()
			return false
		end,
		HasClosePending = function()
			return false
		end,
		IsFailureMessage = function()
			return false
		end,
		Reset = noop,
		SettleClose = noop,
	}
	addon.Services.Master.TradeExecution = {
		CreateController = function()
			return dummyController
		end,
	}
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
		if fixture.throwRefresh then
			error("refresh exploded")
		end
		return true
	end
	fixture.lootState = lootState
	return fixture
end
