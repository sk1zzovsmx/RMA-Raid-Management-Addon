function cases.raid_replication_event_identity(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local uid = assert(events.CreateRaidUid("Leader-Realm", 1721120000, 7, "abcd1234"))
	assertTrue(#uid <= 40, "raid UID exceeds wire bound")
	assertEqual(uid, events.CreateRaidUid("Leader-Realm", 1721120000, 7, "abcd1234"))
	assertEqual(uid .. ":2:18", events.BuildEventUid(uid, 2, 18))
	print("PASS raid_replication_event_identity")
end

function cases.raid_replication_digest(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local left = { zone = "ICC", players = { ["p2"] = { name = "B" }, ["p1"] = { name = "A" } } }
	local right = { players = { ["p1"] = { name = "A" }, ["p2"] = { name = "B" } }, zone = "ICC" }
	local leftDigest = assert(events.DigestState(left))
	assertEqual(leftDigest, events.DigestState(right))
	assertTrue(string.match(leftDigest, "^[0-9a-f][0-9a-f]+:%d+$") ~= nil)
	print("PASS raid_replication_digest")
end

function cases.raid_replication_reducers(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local state = { loot = {}, players = {}, bossKills = {}, attendance = {}, nextLootNid = 1 }
	local event = {
		raidUid = "r1",
		authorityEpoch = 1,
		sequence = 1,
		eventUid = "r1:1:1",
		eventType = "LOOT_ADDED",
		payload = { loot = { lootNid = 1, itemLink = "item:19019" } },
	}
	local nextState = assert(events.Apply(state, event))
	assertEqual("item:19019", nextState.loot[1].itemLink)
	assertEqual(nil, events.Apply(nextState, event))
	assertEqual(0, #state.loot, "reducer mutated its input")
	print("PASS raid_replication_reducers")
end

function cases.raid_replication_distribution_award_is_atomic(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local state = {
		loot = {},
		players = { { playerNid = 1, name = "Winner", countMS = 0, countOs = 0, countFree = 0, countSR = 0 } },
		bossKills = {},
		attendance = {},
		nextLootNid = 1,
	}
	local function award(looterNid, sequence, rollType)
		return {
			raidUid = "r1",
			authorityEpoch = 1,
			sequence = sequence,
			eventUid = "r1:1:" .. sequence,
			eventType = "LOOT_ADDED",
			payload = {
				loot = {
					lootNid = sequence,
					itemLink = "item:19019",
					itemCount = 2,
					looterNid = looterNid,
					rollType = rollType or 1,
					source = "DISTRIBUTION_AWARD",
				},
			},
		}
	end

	local before = deepCopy(state)
	local rejected = events.Apply(state, award(99, 1))
	assertEqual(nil, rejected, "distribution award without a canonical player was accepted")
	assertTrue(deepEqual(before, state), "failed distribution award partially mutated loot or counters")

	local committed = assert(events.Apply(state, award(1, 1)))
	assertEqual(1, #committed.loot, "atomic distribution award did not append exactly one loot row")
	assertEqual(2, committed.players[1].countMS, "atomic distribution award did not apply its counter")
	assertEqual(0, #state.loot, "atomic distribution reducer mutated its input")
	assertEqual(0, state.players[1].countMS, "atomic distribution counter mutated its input")
	assertEqual(nil, events.Apply(committed, award(1, 1)), "duplicate distribution award was accepted")
	assertEqual(2, committed.players[1].countMS, "duplicate distribution award changed the counter")

	local directState = deepCopy(state)
	local nonCountableRollTypes = { 0, 5, 6, 7 }
	for i = 1, #nonCountableRollTypes do
		local rollType = nonCountableRollTypes[i]
		local event = award(1, i, rollType)
		event.payload.loot.itemLink = "item:" .. tostring(19019 + i)
		local nextState = assert(events.Apply(directState, event))
		assertEqual(i, #nextState.loot, "non-countable distribution award did not append exactly once")
		assertEqual(rollType, nextState.loot[i].rollType, "non-countable distribution roll type changed")
		assertEqual(0, nextState.players[1].countMS, "non-countable distribution award changed MS")
		assertEqual(0, nextState.players[1].countOs, "non-countable distribution award changed OS")
		assertEqual(0, nextState.players[1].countSR, "non-countable distribution award changed SR")
		assertEqual(0, nextState.players[1].countFree, "non-countable distribution award changed Free")
		local beforeReplay = deepCopy(nextState)
		assertEqual(nil, events.Apply(nextState, event), "non-countable distribution replay was accepted")
		assertTrue(deepEqual(beforeReplay, nextState), "non-countable replay mutated canonical state")
		directState = nextState
	end
	print("PASS raid_replication_distribution_award_is_atomic")
end

local function buildRaidReplicationEvent(eventType, payload, sequence, resultDigest)
	sequence = sequence or 1
	return {
		raidUid = "r1",
		authorityEpoch = 1,
		sequence = sequence,
		eventUid = "r1:1:" .. sequence,
		eventType = eventType,
		payload = payload,
		resultDigest = resultDigest,
	}
end

function cases.raid_replication_all_event_reducers(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local state = assert(events.Apply(
		{},
		buildRaidReplicationEvent("RAID_CREATED", {
			state = {
				zone = "ICC",
				players = {},
				bossKills = {},
				attendance = {},
				loot = {},
				nextPlayerNid = 1,
				nextBossNid = 1,
				nextLootNid = 1,
			},
		})
	))
	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("RAID_METADATA_UPDATED", {
			metadata = { zone = "Ulduar", difficulty = 4 },
		}, 2)
	))
	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("PLAYER_UPDATED", {
			player = { playerNid = 1, name = "Alpha" },
		}, 3)
	))
	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("PLAYER_UPDATED", {
			player = { playerNid = 1, name = "Alpha", class = "Priest" },
		}, 4)
	))
	assertEqual("Priest", state.players[1].class, "player update must upsert existing stable NID")
	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("PLAYER_DEPARTED", {
			playerNid = 1,
			leave = 1721120100,
		}, 5)
	))
	assertEqual(
		nil,
		events.Apply(
			state,
			buildRaidReplicationEvent("PLAYER_DEPARTED", {
				playerNid = 99,
				leave = 1721120100,
			}, 6)
		)
	)

	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("BOSS_UPDATED", {
			boss = { bossNid = 1, name = "The Lich King" },
		}, 7)
	))
	assertEqual("The Lich King", state.bossKills[1].name, "boss update must upsert a missing stable NID")
	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("BOSS_UPDATED", {
			boss = { bossNid = 1, name = "The Lich King", difficulty = 4 },
		}, 8)
	))
	assertEqual(4, state.bossKills[1].difficulty, "boss update must replace an existing stable NID")

	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("ATTENDANCE_UPDATED", {
			attendance = { playerNid = 1, segments = {} },
		}, 9)
	))
	assertEqual(1, state.attendance[1].playerNid, "attendance update must upsert a missing stable NID")
	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("ATTENDANCE_UPDATED", {
			attendance = { playerNid = 1, segments = { { startTime = 1721120000, subgroup = 1 } } },
		}, 10)
	))
	assertEqual(1, #state.attendance[1].segments, "attendance update must replace an existing stable NID")

	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("LOOT_ADDED", {
			loot = { lootNid = 1, itemLink = "item:19019" },
		}, 11)
	))
	assertEqual(
		nil,
		events.Apply(
			state,
			buildRaidReplicationEvent("LOOT_ADDED", {
				loot = { lootNid = 1, itemLink = "item:19019" },
			}, 12)
		)
	)
	state = assert(events.Apply(
		state,
		buildRaidReplicationEvent("LOOT_UPDATED", {
			loot = { lootNid = 1, itemLink = "item:19019", looterNid = 1 },
		}, 13)
	))
	assertEqual(
		nil,
		events.Apply(
			state,
			buildRaidReplicationEvent("LOOT_UPDATED", {
				loot = { lootNid = 99, itemLink = "item:1" },
			}, 14)
		)
	)
	state = assert(events.Apply(state, buildRaidReplicationEvent("LOOT_DELETED", { lootNid = 1 }, 15)))
	assertEqual(nil, events.Apply(state, buildRaidReplicationEvent("LOOT_DELETED", { lootNid = 1 }, 16)))
	state = assert(events.Apply(state, buildRaidReplicationEvent("RAID_CONCLUDED", { endTime = 1721120200 }, 17)))
	assertEqual(
		nil,
		events.Apply(
			state,
			buildRaidReplicationEvent("PLAYER_UPDATED", {
				player = { playerNid = 2, name = "Beta" },
			}, 18)
		),
		"concluded raid accepted a mutation"
	)
	print("PASS raid_replication_all_event_reducers")
end

function cases.raid_replication_lifecycle_guards(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local protectedKeys = {
		"realm",
		"startTime",
		"endTime",
		"raidUid",
		"raidNid",
		"status",
		"authorityEpoch",
		"sequence",
		"digest",
		"checkpointSequence",
		"events",
		"players",
		"bossKills",
		"attendance",
		"loot",
		"nextPlayerNid",
		"nextBossNid",
		"nextLootNid",
		"unknownField",
	}
	for i = 1, #protectedKeys do
		local state = {
			zone = "ICC",
			players = {},
			bossKills = {},
			attendance = {},
			loot = {},
			nextPlayerNid = 3,
			nextBossNid = 4,
			nextLootNid = 5,
		}
		local key = protectedKeys[i]
		local metadata = { zone = "Ulduar" }
		metadata[key] = key == "players" and {} or "forbidden"
		local before = deepCopy(state)
		assertEqual(
			nil,
			events.Apply(
				state,
				buildRaidReplicationEvent("RAID_METADATA_UPDATED", {
					metadata = metadata,
				}, i)
			),
			"metadata accepted protected key " .. key
		)
		assertTrue(deepEqual(before, state), "metadata failure mutated input for " .. key)
	end
	local state = { zone = "ICC", players = {}, bossKills = {}, attendance = {}, loot = {} }
	local updated = assert(events.Apply(
		state,
		buildRaidReplicationEvent("RAID_METADATA_UPDATED", {
			metadata = { zone = "Ulduar", size = 25, difficulty = 4 },
		}, 30)
	))
	assertEqual("Ulduar", updated.zone)
	print("PASS raid_replication_lifecycle_guards")
end

function cases.raid_replication_malformed_conclusion(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local malformedStates = {
		{ players = "bad", attendance = {}, bossKills = {}, loot = {} },
		{ players = {}, attendance = "bad", bossKills = {}, loot = {} },
		{ players = {}, attendance = { { playerNid = 1, segments = "bad" } }, bossKills = {}, loot = {} },
	}
	for i = 1, #malformedStates do
		local state = malformedStates[i]
		local before = deepCopy(state)
		local ok, result, reason =
			pcall(events.Apply, state, buildRaidReplicationEvent("RAID_CONCLUDED", { endTime = 1721120200 }, i))
		assertEqual(true, ok, "malformed conclusion threw")
		assertEqual(nil, result, "malformed conclusion was accepted")
		assertTrue(
			type(reason) == "string" and string.match(reason, "^[A-Z][A-Z_]+$") ~= nil,
			"malformed conclusion did not return an upper-snake reason"
		)
		assertTrue(deepEqual(before, state), "malformed conclusion mutated input")
	end
	print("PASS raid_replication_malformed_conclusion")
end

function cases.raid_replication_event_digest_validation(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local valid = buildRaidReplicationEvent("LOOT_ADDED", {
		loot = { lootNid = 1, itemLink = "item:19019" },
	}, 1, "deadbeef:1")
	assertEqual(true, events.ValidateEvent(valid))
	local invalidDigests = {
		"deadbee:1",
		"deadbeef0:1",
		"DEADBEEF:1",
		"deadbeef",
		"deadbeef:0",
		"deadbeef:-1",
		"deadbeef:01",
		"deadbeef:1000000000",
		"deadbeef:99999999999999999999",
	}
	for i = 1, #invalidDigests do
		local event = deepCopy(valid)
		event.resultDigest = invalidDigests[i]
		assertEqual(nil, events.ValidateEvent(event), "accepted invalid digest " .. invalidDigests[i])
	end
	print("PASS raid_replication_event_digest_validation")
end

function cases.raid_replication_canonical_failures(addon)
	installRaidReplicationEventFixture(addon)
	local events = addon.DB.RaidEvents
	local cycle = {}
	cycle.self = cycle
	assertEqual(nil, events.DigestState(cycle))
	assertEqual(nil, events.DigestState({ callback = function() end }))
	assertEqual(nil, events.DigestState({ value = 0 / 0 }))
	assertEqual(nil, events.DigestState({ value = math.huge }))
	local tableKey = {}
	assertEqual(nil, events.DigestState({ [tableKey] = true }))
	local event = buildRaidReplicationEvent("RAID_CREATED", { state = cycle })
	assertEqual(nil, events.ValidateEvent(event))
	print("PASS raid_replication_canonical_failures")
end

local function installRaidArchiveFixture(addon)
	installRaidReplicationEventFixture(addon)
	local now = 1721120000
	local committedTypes = {}
	_G.GetTime = function()
		return 123.456
	end
	_G.UnitFullName = function()
		return "Leader", "Realm"
	end
	addon.Time = {
		GetCurrentTime = function()
			return now
		end,
	}
	addon.Events.Internal = { RaidReplicationCommitted = "RaidReplicationCommitted" }
	addon.Bus.TriggerEvent = function(_, event)
		if type(event) == "table" and type(event.eventType) == "string" then
			committedTypes[#committedTypes + 1] = event.eventType
		end
	end
	addon.IgnoredMobs = {
		IsTrashMobName = function()
			return false
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Database/DB.lua")
	addon.Services.Reserves = { Save = function() end }
	loadAddonFile(addon, "Raid Management Addon/Database/SavedVariables.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidValidator.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidStore.lua")
	local store = addon.Database.GetRaidStore()
	assert(store:SetAuthorityGuard(function()
		return true
	end))
	local createActiveRaid = store.CreateActiveRaid
	store.CreateActiveRaid = function(self, first, initialState, serverTime, authorityEpoch)
		if type(first) == "table" then
			return createActiveRaid(self, first)
		end
		local source = initialState or {}
		local state, _, raidUid = createActiveRaid(self, {
			authorityKey = first,
			serverTime = serverTime,
			authorityEpoch = authorityEpoch,
			raidNid = source.raidNid,
			realm = source.realm,
			zone = source.zone,
			size = source.size,
			difficulty = source.difficulty,
			players = source.players,
			bossKills = source.bossKills,
			attendance = source.attendance,
			loot = source.loot,
			nextPlayerNid = source.nextPlayerNid,
			nextBossNid = source.nextBossNid,
			nextLootNid = source.nextLootNid,
		})
		local record = raidUid and self:GetRecord(raidUid) or nil
		return record and record.events[1] or nil, state
	end
	return store, function(value)
		now = value
	end, committedTypes
end

local function newReplicationState()
	return {
		zone = "ICC",
		players = {},
		bossKills = {},
		attendance = {},
		loot = {},
		nextPlayerNid = 1,
		nextBossNid = 1,
		nextLootNid = 1,
	}
end

local function installRaidAuthorityRecoveryStateFixture(addon)
	local store, setNow = installRaidArchiveFixture(addon)
	local _, raidIndex, raidUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		serverTime = 1721120000,
		realm = "Realm",
		zone = "Icecrown Citadel",
		size = 25,
		difficulty = 4,
		players = {},
		nextPlayerNid = 2,
	}))
	local staleArchive = store:CaptureRaidHistoryState()
	assert(store:CommitAuthoritativeEvent(raidUid, "PLAYER_UPDATED", {
		player = { playerNid = 2, name = "Luca", join = 1721120001 },
	}))
	local recoveredSnapshot = assert(store:BuildSnapshot(raidUid))
	assert(store:RestoreRaidHistoryState(staleArchive))

	local fixture = {
		now = 1721120010,
		recovering = true,
		callbacks = {},
		replayOrder = {},
		roster = {
			{ name = "Luca", rank = 0, subgroup = 1, class = "MAGE" },
			{ name = "Marco", rank = 0, subgroup = 1, class = "PRIEST" },
		},
		store = store,
		raidIndex = raidIndex,
		raidUid = raidUid,
		recoveredSnapshot = recoveredSnapshot,
	}
	setNow(fixture.now)
	assert(store:SetAuthorityGuard(function(operation)
		if operation == "promote" then
			return true
		end
		if fixture.recovering then
			return false, "AUTHORITY_RECOVERING"
		end
		return true
	end))

	_G.table.wipe = _G.table.wipe
		or function(target)
			for key in pairs(target) do
				target[key] = nil
			end
			return target
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
	_G.UnitIsConnected = function()
		return true
	end
	_G.UnitName = function(unit)
		local index = tonumber(string.match(tostring(unit), "^raid(%d+)$"))
		return index and fixture.roster[index] and fixture.roster[index].name or nil
	end
	_G.UnitRace = function()
		return "Human", "Human"
	end
	_G.GetInstanceInfo = function()
		return "Icecrown Citadel", "raid", 4
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
		return member.name, member.rank, member.subgroup, 80, member.class, member.class, nil, true
	end
	_G.UNKNOWNOBJECT = "Unknown"
	_G.UNKNOWNBEING = "Unknown Being"

	addon.State.currentRaid = raidIndex
	addon.State.raid = {}
	addon.C = { BOSS_KILL_DEDUPE_WINDOW_SECONDS = 30 }
	addon.L = { RaidZones = {} }
	addon.Diag = {
		I = {
			LogBossLogged = "%s %d %d %d",
			LogRaidEnded = "%d %s %d %d %d %d",
		},
		D = {},
	}
	addon.Strings = {
		TrimText = function(value)
			return value
		end,
		NormalizeName = function(value)
			return value
		end,
		NormalizeLower = function(value)
			return value and string.lower(value) or nil
		end,
	}
	addon.Base64 = {
		Encode = function(value)
			return tostring(value)
		end,
	}
	addon.IgnoredMobs = {
		IsTrashMobName = function()
			return false
		end,
		GetTrashMobName = function()
			return "Trash"
		end,
		Contains = function()
			return false
		end,
	}
	addon.LootSources = {}
	addon.LootSourceCandidates = {}
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.info = function() end
	addon.debug = function() end
	addon.IsInRaid = function()
		return true
	end
	addon.IsInGroup = function()
		return true
	end
	addon.GetGroupTypeAndCount = function()
		return "raid", #fixture.roster
	end
	addon.GetNumGroupMembers = function()
		return #fixture.roster
	end
	addon.GetCreatureId = function()
		return nil
	end
	addon.UnitIterator = function()
		local index = 0
		return function()
			index = index + 1
			if fixture.roster[index] then
				return "raid" .. tostring(index)
			end
		end
	end
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
	end
	addon.Services.Loot = {
		_State = {
			SetField = function(_, _, value)
				return value
			end,
			SetActive = function(_, value)
				return value
			end,
			SyncActive = function() end,
			Reset = function() end,
		},
		_Sessions = {},
		_Snapshots = {},
		_Context = {},
	}
	function addon.Services.Loot:ReplayAuthorityRecoveryFacts(replayRaidUid)
		assertEqual(raidUid, replayRaidUid, "loot replay raid UID differs")
		fixture.replayOrder[#fixture.replayOrder + 1] = "loot"
		return true
	end

	addon.Events.Internal.RaidCreate = "RaidCreate"
	addon.Events.Internal.RaidAttendanceChanged = "RaidAttendanceChanged"
	addon.Events.Internal.RaidAuthorityRecoveryFinished = "RaidAuthorityRecoveryFinished"
	addon.Events.Internal.RaidReentryRecoveryReady = "RaidReentryRecoveryReady"
	addon.Events.Internal.RaidReentryDecisionRequired = "RaidReentryDecisionRequired"
	addon.Events.Internal.RaidReentryDecisionResolved = "RaidReentryDecisionResolved"
	addon.Bus.RegisterCallback = function(eventName, callback)
		fixture.callbacks[eventName] = fixture.callbacks[eventName] or {}
		fixture.callbacks[eventName][#fixture.callbacks[eventName] + 1] = callback
	end
	addon.Bus.TriggerEvent = function(eventName, ...)
		local callbacks = fixture.callbacks[eventName] or {}
		for i = 1, #callbacks do
			callbacks[i](eventName, ...)
		end
	end
	addon.DB.Syncer = {
		IsAuthorityRecovering = function(_, candidateRaidUid)
			return fixture.recovering and candidateRaidUid == raidUid
		end,
	}

	loadAddonFile(addon, "Raid Management Addon/Modules/Group.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/State.lua")
	local raid = addon.Services.Raid
	raid._ScheduleRosterRefreshInternal = function() end
	raid._CancelRosterRefreshInternal = function() end
	function raid:GetPlayers(candidateRaidIndex)
		local candidate = addon.Database.EnsureRaidByIndex(candidateRaidIndex or addon.Database.GetCurrentRaid())
		return candidate and candidate.players or {}
	end
	function raid:GetPlayerID(name, candidateRaidIndex)
		local players = self:GetPlayers(candidateRaidIndex)
		for i = #players, 1, -1 do
			if players[i].name == name then
				return tonumber(players[i].playerNid) or 0
			end
		end
		return 0
	end
	function raid:RefreshAndPublish()
		fixture.replayOrder[#fixture.replayOrder + 1] = "roster"
		if fixture.refreshMarco ~= false then
			return self:AddPlayer({ name = "Marco", join = fixture.now, rank = 0, subgroup = 1, class = "PRIEST" })
		end
	end

	local commitAuthoritativeEvent = store.CommitAuthoritativeEvent
	store.CommitAuthoritativeEvent = function(self, candidateRaidUid, eventType, payload)
		local event, result = commitAuthoritativeEvent(self, candidateRaidUid, eventType, payload)
		if event and eventType == "BOSS_UPDATED" then
			fixture.replayOrder[#fixture.replayOrder + 1] = "boss"
		end
		return event, result
	end
	local concludeActiveRaid = store.ConcludeActiveRaid
	store.ConcludeActiveRaid = function(self, candidateRaidUid, endTime)
		local event, result = concludeActiveRaid(self, candidateRaidUid, endTime)
		if event then
			fixture.replayOrder[#fixture.replayOrder + 1] = "conclusion"
		end
		return event, result
	end

	function fixture:FinishRecovery(succeeded, reason)
		if succeeded then
			assert(self.store:RepairActiveFromSnapshot(self.recoveredSnapshot))
			self.recovering = false
		end
		addon.Bus.TriggerEvent("RaidAuthorityRecoveryFinished", self.raidUid, succeeded, reason)
		if not succeeded then
			self.recovering = false
		end
	end

	function fixture:SetNow(value)
		self.now = value
		setNow(value)
	end

	function fixture:InstrumentSchemaMutation()
		local ensureRaidSchema = addon.Database.EnsureRaidSchema
		self.schemaCalls = 0
		addon.Database.EnsureRaidSchema = function(candidate)
			self.schemaCalls = self.schemaCalls + 1
			candidate.nextBossNid = (tonumber(candidate.nextBossNid) or 1) + 100
			return ensureRaidSchema(candidate)
		end
	end

	return fixture, raid
end

function cases.raid_handover_replays_raid_facts_after_snapshot(addon)
	local fixture, raid = installRaidAuthorityRecoveryStateFixture(addon)
	local sequenceBefore = fixture.store:GetRecord(fixture.raidUid).sequence
	local bossNid, bossReason = raid:AddBoss("Lord Marrowgar", nil, nil, 36612)
	assertEqual(0, bossNid, "recovering boss observation returned a canonical NID")
	assertEqual("AUTHORITY_RECOVERING", bossReason, "recovering boss observation reason differs")
	local ended, endReason = raid:End(true)
	assertEqual(false, ended, "automatic conclusion committed during recovery")
	assertEqual("AUTHORITY_RECOVERING", endReason, "automatic conclusion recovery reason differs")
	assertEqual(
		sequenceBefore,
		fixture.store:GetRecord(fixture.raidUid).sequence,
		"recovery observation changed canonical sequence"
	)

	fixture:FinishRecovery(true)
	local recovered = fixture.store:GetRecord(fixture.raidUid)
	assertEqual(2, recovered.state.players[1].playerNid, "recovered Luca NID differs")
	assertEqual("Luca", recovered.state.players[1].name, "recovered player was overwritten")
	local marcoNid = raid:GetPlayerID("Marco", fixture.raidIndex)
	assertTrue(marcoNid > 2, "pending player reused recovered NID")
	local boss = recovered.state.bossKills[1]
	assertTrue(boss ~= nil, "pending boss was not replayed")
	local attendeeNids = {}
	for i = 1, #(boss.players or {}) do
		attendeeNids[boss.players[i]] = true
	end
	assertTrue(attendeeNids[2] == true, "boss attendance omitted recovered Luca NID")
	assertTrue(attendeeNids[marcoNid] == true, "boss attendance omitted final Marco NID")
	assertEqual("roster", fixture.replayOrder[1], "roster did not replay first")
	assertEqual("boss", fixture.replayOrder[2], "boss did not replay second")
	assertEqual("loot", fixture.replayOrder[3], "loot did not replay third")
	assertEqual("conclusion", fixture.replayOrder[4], "conclusion did not replay last")
	assertEqual("complete", recovered.status, "automatic conclusion retry did not complete the raid")
	print("PASS raid_handover_replays_raid_facts_after_snapshot")
end

function cases.raid_handover_discards_raid_facts_on_failure(addon)
	local fixture, raid = installRaidAuthorityRecoveryStateFixture(addon)
	fixture.refreshMarco = false
	local sequenceBefore = fixture.store:GetRecord(fixture.raidUid).sequence
	local bossNid, reason = raid:AddBoss("Lord Marrowgar", nil, nil, 36612)
	assertEqual(0, bossNid, "recovering boss observation returned a canonical NID")
	assertEqual("AUTHORITY_RECOVERING", reason, "recovering boss observation reason differs")
	fixture:FinishRecovery(false, "DIGEST_CONFLICT")
	assertEqual(
		sequenceBefore,
		fixture.store:GetRecord(fixture.raidUid).sequence,
		"failed recovery mutated canonical sequence"
	)
	raid:_ReplayAuthorityRecovery(fixture.raidUid, true)
	assertEqual(
		sequenceBefore,
		fixture.store:GetRecord(fixture.raidUid).sequence,
		"discarded boss fact replayed after failed recovery"
	)
	assertEqual(
		0,
		#fixture.store:GetRecord(fixture.raidUid).state.bossKills,
		"failed recovery retained a pending boss mutation"
	)
	print("PASS raid_handover_discards_raid_facts_on_failure")
end

function cases.raid_handover_recovery_dedupe_is_temporal(addon)
	local fixture, raid = installRaidAuthorityRecoveryStateFixture(addon)
	assertEqual(0, raid:AddBoss("Lord Marrowgar", nil, nil, 36612))
	fixture:SetNow(fixture.now + 31)
	assertEqual(0, raid:AddBoss("Lord Marrowgar", nil, nil, 36612))
	fixture:FinishRecovery(true)
	local recovered = fixture.store:GetRecord(fixture.raidUid)
	assertEqual(1, #recovered.state.bossKills, "recent same-key observation was lost after the older fact expired")
	assertEqual(
		fixture.now,
		recovered.state.bossKills[1].time,
		"replayed boss did not retain the recent observation time"
	)
	print("PASS raid_handover_recovery_dedupe_is_temporal")
end

function cases.raid_handover_recovery_gate_precedes_schema_mutation(addon)
	local fixture, raid = installRaidAuthorityRecoveryStateFixture(addon)
	fixture:InstrumentSchemaMutation()
	local recordBefore = deepCopy(fixture.store:GetRecord(fixture.raidUid))
	local bossNid, reason = raid:AddBoss("Lord Marrowgar", nil, nil, 36612)
	assertEqual(0, bossNid, "recovering boss observation returned a canonical NID")
	assertEqual("AUTHORITY_RECOVERING", reason, "recovering boss observation reason differs")
	assertEqual(0, fixture.schemaCalls, "recovery gate ran after schema normalization")
	assertTrue(
		deepEqual(recordBefore, fixture.store:GetRecord(fixture.raidUid)),
		"recovery observation mutated schema, NIDs, digest, or sequence"
	)
	print("PASS raid_handover_recovery_gate_precedes_schema_mutation")
end

function cases.raid_handover_manual_conclusion_is_not_retried(addon)
	local fixture, raid = installRaidAuthorityRecoveryStateFixture(addon)
	local ended, reason = raid:End()
	assertEqual(false, ended, "manual conclusion committed during recovery")
	assertEqual("AUTHORITY_RECOVERING", reason, "manual conclusion recovery reason differs")
	fixture:FinishRecovery(true)
	local recovered = fixture.store:GetRecord(fixture.raidUid)
	assertEqual("active", recovered.status, "manual conclusion was retried after recovery")
	assertEqual(nil, recovered.state.endTime, "manual conclusion assigned an end time after recovery")
	print("PASS raid_handover_manual_conclusion_is_not_retried")
end

function cases.raid_handover_recovery_fact_bounds_and_invalid_success(addon)
	local fixture, raid = installRaidAuthorityRecoveryStateFixture(addon)
	fixture.refreshMarco = false
	local initialSequence = fixture.store:GetRecord(fixture.raidUid).sequence
	assertEqual(0, raid:AddBoss("Mismatched Raid Boss", nil, nil, 40001))
	assertEqual(false, raid:_ReplayAuthorityRecovery("wrong-raid", true), "mismatched success replay was accepted")
	assertEqual(
		initialSequence,
		fixture.store:GetRecord(fixture.raidUid).sequence,
		"mismatched success mutated canonical sequence"
	)
	fixture.recovering = false
	function raid:IsRaidLeader()
		return true
	end
	assertEqual(true, raid:_ReplayAuthorityRecovery(fixture.raidUid, true), "post-mismatch empty replay failed")
	assertEqual(
		0,
		#fixture.store:GetRecord(fixture.raidUid).state.bossKills,
		"mismatched success retained pending boss facts"
	)

	fixture.recovering = true
	assertEqual(0, raid:AddBoss("Lost Authority Boss", nil, nil, 50001))
	fixture.recovering = false
	function raid:IsRaidLeader()
		return false
	end
	assertEqual(
		false,
		raid:_ReplayAuthorityRecovery(fixture.raidUid, true),
		"authority-loss success replay was accepted"
	)
	function raid:IsRaidLeader()
		return true
	end
	assertEqual(true, raid:_ReplayAuthorityRecovery(fixture.raidUid, true), "post-authority-loss empty replay failed")
	assertEqual(
		0,
		#fixture.store:GetRecord(fixture.raidUid).state.bossKills,
		"authority-loss success retained pending boss facts"
	)

	fixture.recovering = true
	fixture.refreshMarco = true
	for i = 1, 65 do
		local bossNid, reason = raid:AddBoss("Final Bounded Boss " .. tostring(i), nil, nil, 60000 + i)
		assertEqual(0, bossNid)
		assertEqual("AUTHORITY_RECOVERING", reason, "final bounded fact was not queued at " .. tostring(i))
	end
	assert(fixture.store:RepairActiveFromSnapshot(fixture.recoveredSnapshot))
	fixture.recovering = false
	assertEqual(true, raid:_ReplayAuthorityRecovery(fixture.raidUid, true), "valid success replay failed")
	local record = fixture.store:GetRecord(fixture.raidUid)
	assertEqual(64, #record.state.bossKills, "pending boss fact cap differs")
	assertEqual(true, raid:_ReplayAuthorityRecovery(fixture.raidUid, true), "duplicate success callback failed")
	assertEqual(
		64,
		#fixture.store:GetRecord(fixture.raidUid).state.bossKills,
		"duplicate success callback duplicated boss facts"
	)
	print("PASS raid_handover_recovery_fact_bounds_and_invalid_success")
end

function cases.raid_replication_archive_reload(addon)
	_G.RMA_Raids = nil
	local store = installRaidArchiveFixture(addon)
	local archive = store:EnsureArchive()
	assertEqual(1, archive.formatVersion, "archive format differs")
	assertEqual(0, #archive.order, "fresh canonical archive was not empty")
	local event, state = assert(store:CreateActiveRaid("Leader-Realm", newReplicationState(), 1721120000))
	assertEqual(1, event.sequence)
	assertTrue(state == store:GetActiveRecord().state, "create did not return canonical state")
	local uid = event.raidUid
	assertEqual(uid, archive.activeRaidUid, "active UID differs")
	assertEqual(uid, archive.order[1], "archive order differs")
	assertEqual("active", archive.raids[uid].status, "active status differs")
	assertEqual(1, archive.raids[uid].authorityEpoch, "authority epoch differs")
	assertEqual(0, archive.raids[uid].checkpointSequence, "initial checkpoint differs")
	assertEqual(uid .. ":1:1", archive.raids[uid].events[1].eventUid, "initial event UID differs")
	assertEqual("RAID_CREATED", archive.raids[uid].events[1].eventType, "initial event type differs")
	assertEqual(uid, archive.raids[uid].events[1].raidUid, "initial event raid UID differs")
	assertEqual(archive.raids[uid].digest, archive.raids[uid].events[1].resultDigest, "initial digest differs")
	assertTrue(deepEqual(state, archive.raids[uid].events[1].payload.state), "initial event state differs")
	local committed = assert(store:CommitAuthoritativeEvent(uid, "RAID_METADATA_UPDATED", {
		metadata = { zone = "Ulduar" },
	}))
	local beforeReload = deepCopy(store:GetRecord(uid))
	addon.Database.SavedVariables.NormalizeAfterLoad()
	local afterReload = store:GetRecord(uid)
	assertEqual(committed.sequence, afterReload.sequence, "reload lost sequence")
	assertEqual(beforeReload.digest, afterReload.digest, "reload lost digest")
	assertEqual(beforeReload.checkpointSequence, afterReload.checkpointSequence, "reload lost checkpoint")
	assertEqual(afterReload.state, addon.Database.EnsureRaidByIndex(1), "ordered feature read differs")
	print("PASS raid_replication_archive_reload")
end

function cases.raid_replication_atomic_store(addon)
	local store = installRaidArchiveFixture(addon)
	local created = assert(store:CreateActiveRaid("Leader-Realm", newReplicationState(), 1721120000))
	local uid = created.raidUid
	local original = deepCopy(store:GetRecord(uid))
	local rejected = store:CommitAuthoritativeEvent(uid, "LOOT_UPDATED", {
		loot = { lootNid = 99, itemLink = "item:1" },
	})
	assertEqual(nil, rejected, "failing reducer was committed")
	assertTrue(deepEqual(original, store:GetRecord(uid)), "failing reducer mutated record")

	local nextEvent = {
		raidUid = uid,
		authorityEpoch = 1,
		sequence = 2,
		eventUid = uid .. ":1:2",
		eventType = "RAID_METADATA_UPDATED",
		payload = { metadata = { zone = "Ulduar" } },
		resultDigest = "deadbeef:1",
	}
	rejected = store:ApplyReplicaEvent(nextEvent)
	assertEqual(nil, rejected, "digest mismatch was committed")
	assertTrue(deepEqual(original, store:GetRecord(uid)), "digest mismatch mutated record")

	local candidateState = assert(addon.DB.RaidEvents.Apply(original.state, nextEvent))
	nextEvent.resultDigest = assert(addon.DB.RaidEvents.DigestState(candidateState))
	local applied, appliedState = assert(store:ApplyReplicaEvent(nextEvent))
	assertEqual(2, applied.sequence, "replica sequence differs")
	assertEqual("Ulduar", appliedState.zone, "replica state was not applied")
	local snapshot = assert(store:BuildSnapshot(uid))
	local snapshotBefore = deepCopy(snapshot)
	snapshot.digest = "deadbeef:1"
	assertEqual(nil, store:ReplaceActiveFromSnapshot(snapshot), "invalid snapshot replaced active raid")
	assertTrue(deepEqual(snapshotBefore.state, store:GetRecord(uid).state), "invalid snapshot mutated active raid")

	local concluded = assert(store:ConcludeActiveRaid(uid, 1721120200))
	assertEqual("RAID_CONCLUDED", concluded.eventType)
	assertEqual(nil, store:GetActiveRecord(), "conclusion retained active pointer")
	assertEqual(0, #store:GetRecord(uid).events, "conclusion retained active ledger")
	local historical = assert(store:BuildSnapshot(uid))
	_G.RMA_Raids = { formatVersion = 1, activeRaidUid = nil, order = {}, raids = {} }
	assertEqual("IMPORTED", store:ImportHistoricalSnapshot(historical))
	local imported = assert(addon.Database.EnsureRaidByIndex(1))
	assertEqual(1721120200, imported.endTime, "historical snapshot state differs")
	print("PASS raid_replication_atomic_store")
end

function cases.raid_replication_rejects_exposed_state_tampering(addon)
	local store = installRaidArchiveFixture(addon)
	local _, _, raidUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		serverTime = 1721120000,
		zone = "Icecrown Citadel",
		players = { { playerNid = 1, name = "Alpha", join = 1721120000 } },
	}))
	local canonical = deepCopy(store:GetRecord(raidUid))
	local replicaEvent = {
		raidUid = raidUid,
		authorityEpoch = canonical.authorityEpoch,
		sequence = canonical.sequence + 1,
		eventUid = assert(addon.DB.RaidEvents.BuildEventUid(raidUid, canonical.authorityEpoch, canonical.sequence + 1)),
		eventType = "RAID_METADATA_UPDATED",
		payload = { metadata = { zone = "Ulduar" } },
	}
	local replicaState = assert(addon.DB.RaidEvents.Apply(canonical.state, replicaEvent))
	replicaEvent.resultDigest = assert(addon.DB.RaidEvents.DigestState(replicaState))

	local exposed = assert(store:GetStateByIndex(1))
	exposed.players[1].rank = 2
	assertEqual(2, store:GetAllRaids()[1].players[1].rank, "read APIs did not expose the same nested canonical state")
	local corruptedArchive = deepCopy(store:EnsureArchive())
	local function assertRejected(label, callback)
		local result, reason = callback()
		assertEqual(nil, result, label .. " accepted tampered current state")
		assertEqual("CURRENT_STATE_DIGEST_MISMATCH", reason, label .. " rejection reason differs")
		assertTrue(deepEqual(corruptedArchive, store:EnsureArchive()), label .. " mutated the archive on rejection")
	end

	assertRejected("authoritative commit", function()
		return store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
			metadata = { zone = "Trial of the Crusader" },
		})
	end)
	assertRejected("replica apply", function()
		return store:ApplyReplicaEvent(replicaEvent)
	end)
	assertRejected("authority promotion", function()
		return store:PromoteAuthority(raidUid, canonical.sequence)
	end)
	assertRejected("conclusion", function()
		return store:ConcludeActiveRaid(raidUid, 1721120200)
	end)
	print("PASS raid_replication_rejects_exposed_state_tampering")
end

function cases.raid_replication_checkpoint(addon)
	local store = installRaidArchiveFixture(addon)
	local created = assert(store:CreateActiveRaid("Leader-Realm", newReplicationState(), 1721120000))
	local uid = created.raidUid
	for i = 1, 513 do
		assert(store:CommitAuthoritativeEvent(uid, "RAID_METADATA_UPDATED", {
			metadata = { zone = "Zone" .. tostring(i) },
		}))
	end
	local record = store:GetRecord(uid)
	assertEqual(512, #record.events, "ledger was not bounded")
	assertEqual(2, record.checkpointSequence, "checkpoint position differs")
	local missing, reason = store:GetEventRange(uid, 1)
	assertEqual(nil, missing)
	assertEqual("SNAPSHOT_REQUIRED", reason)
	local range = assert(store:GetEventRange(uid, record.checkpointSequence))
	assertEqual(512, #range)
	assertEqual(record.checkpointSequence + 1, range[1].sequence)
	local snapshot = assert(store:BuildSnapshot(uid))
	assertEqual(record.sequence, snapshot.sequence)
	assertEqual(record.sequence, snapshot.checkpointSequence)
	assertEqual(0, #snapshot.events)
	local future, futureReason = store:GetEventRange(uid, record.sequence + 1)
	assertEqual(nil, future)
	assertEqual("SNAPSHOT_REQUIRED", futureReason)
	print("PASS raid_replication_checkpoint")
end

function cases.raid_replication_snapshot_validation(addon)
	local store = installRaidArchiveFixture(addon)
	local initialState = newReplicationState()
	initialState.raidNid = 73
	local created = assert(store:CreateActiveRaid("Leader-Realm", initialState, 1721120000))
	local uid = created.raidUid
	local activeSnapshot = assert(store:BuildSnapshot(uid))
	assertEqual(
		store:GetRecord(uid).state,
		assert(store:ReplaceActiveFromSnapshot(activeSnapshot)),
		"same active UID and digest was not idempotent"
	)
	local activeBefore = deepCopy(store:EnsureArchive())
	local conflictingActive = deepCopy(activeSnapshot)
	conflictingActive.state.zone = "Ulduar"
	conflictingActive.digest = assert(addon.DB.RaidEvents.DigestState(conflictingActive.state))
	local replaced, replaceReason = store:ReplaceActiveFromSnapshot(conflictingActive)
	assertEqual(nil, replaced)
	assertEqual("RAID_CONFLICT", replaceReason)
	assertTrue(deepEqual(activeBefore, store:EnsureArchive()), "active conflict mutated archive")
	local invalidActive = deepCopy(activeSnapshot)
	invalidActive.state.endTime = 1721120100
	invalidActive.digest = assert(addon.DB.RaidEvents.DigestState(invalidActive.state))
	assertEqual(nil, store:ReplaceActiveFromSnapshot(invalidActive), "ended active snapshot was accepted")
	assertTrue(deepEqual(activeBefore, store:EnsureArchive()), "invalid active snapshot mutated archive")

	assert(store:ConcludeActiveRaid(uid, 1721120200))
	assertEqual("complete", store:GetRecord(uid).status, "completed status differs")
	local historical = assert(store:BuildSnapshot(uid))
	_G.RMA_Raids = { formatVersion = 1, activeRaidUid = nil, order = {}, raids = {} }
	assertEqual("IMPORTED", store:ImportHistoricalSnapshot(historical))
	assertEqual(
		"ALREADY_PRESENT",
		store:ImportHistoricalSnapshot(historical),
		"same historical UID and digest was not idempotent"
	)
	local firstImport = assert(addon.Database.EnsureRaidByIndex(1))
	local importedBefore = deepCopy(store:EnsureArchive())
	local conflictingHistorical = deepCopy(historical)
	conflictingHistorical.state.zone = "Naxxramas"
	conflictingHistorical.digest = assert(addon.DB.RaidEvents.DigestState(conflictingHistorical.state))
	local imported, importReason = store:ImportHistoricalSnapshot(conflictingHistorical)
	assertEqual("CONFLICT", imported)
	assertEqual("RAID_CONFLICT", importReason)
	assertEqual(2, #store:EnsureArchive().order, "historical conflict was not preserved")
	assertTrue(
		deepEqual(importedBefore.raids[historical.raidUid], store:GetRecord(historical.raidUid)),
		"historical conflict changed the original row"
	)
	local preservedBefore = deepCopy(store:EnsureArchive())
	local invalidComplete = deepCopy(historical)
	invalidComplete.events = { deepCopy(activeSnapshot) }
	assertEqual(nil, store:ImportHistoricalSnapshot(invalidComplete), "completed ledger was accepted")
	assertTrue(deepEqual(preservedBefore, store:EnsureArchive()), "invalid completed snapshot mutated archive")
	local invalidStatus = deepCopy(historical)
	invalidStatus.status = "concluded"
	assertEqual(nil, store:ImportHistoricalSnapshot(invalidStatus), "unknown completed status was accepted")
	assertTrue(deepEqual(preservedBefore, store:EnsureArchive()), "unknown status mutated archive")
	local missingEndTime = deepCopy(historical)
	missingEndTime.raidUid = "r:1721120002:2:23456789"
	missingEndTime.state.endTime = nil
	missingEndTime.digest = assert(addon.DB.RaidEvents.DigestState(missingEndTime.state))
	local missingResult, missingReason = store:ImportHistoricalSnapshot(missingEndTime)
	assertEqual(nil, missingResult, "completed snapshot without endTime was accepted")
	assertEqual("INVALID_COMPLETE_RAID_STATE", missingReason)
	assertTrue(deepEqual(preservedBefore, store:EnsureArchive()), "missing conclusion state mutated archive")
	local reversedLifecycle = deepCopy(historical)
	reversedLifecycle.raidUid = "r:1721120003:3:3456789a"
	reversedLifecycle.state.startTime = 1721120300
	reversedLifecycle.digest = assert(addon.DB.RaidEvents.DigestState(reversedLifecycle.state))
	local reversedResult, reversedReason = store:ImportHistoricalSnapshot(reversedLifecycle)
	assertEqual(nil, reversedResult, "endTime before startTime was accepted")
	assertEqual("INVALID_COMPLETE_RAID_STATE", reversedReason)
	assertTrue(deepEqual(preservedBefore, store:EnsureArchive()), "reversed lifecycle mutated archive")
	assertEqual(firstImport, addon.Database.EnsureRaidByNid(firstImport.raidNid), "imported raidNid index differs")
	assertEqual(true, store:DeleteRaidByArchiveKey(historical.raidUid))
	assertEqual(nil, addon.Database.EnsureRaidByNid(firstImport.raidNid), "deleted raid remained indexed")
	print("PASS raid_replication_snapshot_validation")
end

function cases.raid_replication_archive_rollback(addon)
	local store = installRaidArchiveFixture(addon)
	local emptyArchive = deepCopy(store:EnsureArchive())
	local insertionCaptureName = "CaptureRaid" .. "InsertionState"
	local insertionRestoreName = "RestoreRaid" .. "InsertionState"
	assertEqual(nil, store[insertionCaptureName], "obsolete insertion capture API must be absent")
	assertEqual(nil, store[insertionRestoreName], "obsolete insertion restore API must be absent")

	local historyCapture = store:CaptureRaidHistoryState()
	assert(
		store:CreateActiveRaid({ authorityKey = "Leader-Realm", raidNid = 73, zone = "Ulduar", serverTime = 1721120100 })
	)
	local insertedArchive = store:EnsureArchive()
	assertTrue(
		insertedArchive.activeRaidUid ~= nil and #insertedArchive.order == 1,
		"simulated post-insert failure setup did not persist canonical raid"
	)
	assertTrue(store:RestoreRaidHistoryState(historyCapture), "history restore failed")
	assertTrue(deepEqual(emptyArchive, store:EnsureArchive()), "history restore did not restore full archive")
	assertEqual(nil, addon.Database.EnsureRaidByNid(73), "history restore left stale raidNid index")
	assertEqual(0, #store:GetAllRaids(), "history restore left an ordered feature row")
	print("PASS raid_replication_archive_rollback")
end

function cases.raid_replication_single_active(addon)
	local store = installRaidArchiveFixture(addon)
	local initialState = newReplicationState()
	initialState.raidNid = 41
	local created = assert(store:CreateActiveRaid("Leader-Realm", initialState, 1721120000))
	local activeUid = created.raidUid
	local otherSnapshot = assert(store:BuildSnapshot(activeUid))
	otherSnapshot.raidUid = "r:1721120001:2:12345678"
	local archiveBefore = deepCopy(store:EnsureArchive())
	local replaced, replaceReason = store:ReplaceActiveFromSnapshot(otherSnapshot)
	assertEqual(nil, replaced)
	assertEqual("ACTIVE_RAID_EXISTS", replaceReason)
	assertTrue(deepEqual(archiveBefore, store:EnsureArchive()), "different active UID mutated archive")

	local archive = store:EnsureArchive()
	local orphanUid = otherSnapshot.raidUid
	archive.raids[orphanUid] = deepCopy(archive.raids[activeUid])
	archive.order[#archive.order + 1] = orphanUid
	local invalidArchiveBefore = deepCopy(archive)
	local concluded, concludeReason = store:ConcludeActiveRaid(orphanUid, 1721120200)
	assertEqual(nil, concluded)
	assertEqual("RAID_NOT_ACTIVE", concludeReason)
	assertTrue(deepEqual(invalidArchiveBefore, archive), "non-current conclusion mutated archive")
	assertEqual(
		nil,
		addon.Database.GetRaidValidator():ValidateArchive(archive),
		"multiple active records passed archive validation"
	)
	archive.raids[orphanUid] = nil
	archive.order[#archive.order] = nil
	assertEqual(true, addon.Database.GetRaidValidator():ValidateArchive(archive))
	assert(store:ConcludeActiveRaid(activeUid, 1721120200))
	assertEqual(
		true,
		addon.Database.GetRaidValidator():ValidateArchive(archive),
		"zero-active completed archive failed validation"
	)
	archive.raids[activeUid].status = "active"
	assertEqual(
		nil,
		addon.Database.GetRaidValidator():ValidateArchive(archive),
		"nil active pointer accepted active-status record"
	)
	print("PASS raid_replication_single_active")
end

function cases.raid_replication_local_mutations(addon)
	local store, _, committedTypes = installRaidArchiveFixture(addon)
	local state, raidIndex, raidUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		serverTime = 1721120000,
		realm = "Realm",
		zone = "Icecrown Citadel",
		size = 25,
		difficulty = 4,
		players = { { playerNid = 1, name = "Alpha", join = 1721120000 } },
	}))
	assertEqual(1, raidIndex)
	assertTrue(type(raidUid) == "string" and raidUid ~= "")
	assert(store:CommitAuthoritativeEvent(raidUid, "PLAYER_UPDATED", {
		player = { playerNid = 1, name = "Alpha", join = 1721120000, rank = 2 },
	}))
	assert(store:CommitAuthoritativeEvent(raidUid, "ATTENDANCE_UPDATED", {
		attendance = { playerNid = 1, segments = { { startTime = 1721120000 } } },
	}))
	assert(store:CommitAuthoritativeEvent(raidUid, "BOSS_UPDATED", {
		boss = { bossNid = 1, name = "Marrowgar", players = { 1 }, time = 1721120050 },
	}))
	assert(store:CommitAuthoritativeEvent(raidUid, "LOOT_ADDED", {
		loot = { lootNid = 1, itemId = 49908, looterNid = 1, bossNid = 1 },
	}))
	assert(store:CommitAuthoritativeEvent(raidUid, "LOOT_UPDATED", {
		loot = { lootNid = 1, itemId = 49908, looterNid = 1, bossNid = 1, rollType = 1 },
	}))
	assert(store:CommitAuthoritativeEvent(raidUid, "LOOT_DELETED", { lootNid = 1 }))
	assert(store:ConcludeActiveRaid(raidUid, 1721120200))
	local expected = {
		"RAID_CREATED",
		"PLAYER_UPDATED",
		"ATTENDANCE_UPDATED",
		"BOSS_UPDATED",
		"LOOT_ADDED",
		"LOOT_UPDATED",
		"LOOT_DELETED",
		"RAID_CONCLUDED",
	}
	assertTrue(deepEqual(expected, committedTypes), "committed semantic event order differs")
	assertEqual("complete", store:GetRecord(raidUid).status)
	assertEqual(0, #store:GetRecord(raidUid).events)
	print("PASS raid_replication_local_mutations")
end

function cases.raid_replication_conclusion(addon)
	local store, _, committedTypes = installRaidArchiveFixture(addon)
	local state, _, raidUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		serverTime = 1721120000,
		zone = "Icecrown Citadel",
		players = { { playerNid = 1, name = "Alpha", join = 1721120000 } },
	}))
	local record = store:GetRecord(raidUid)
	local sequence, digest, eventCount = record.sequence, record.digest, #committedTypes
	local concluded, reason = store:ConcludeActiveRaid(raidUid, "invalid")
	assertEqual(nil, concluded)
	assertEqual("INVALID_END_TIME", reason)
	assertEqual(sequence, record.sequence)
	assertEqual(digest, record.digest)
	assertEqual(eventCount, #committedTypes)
	assertEqual(nil, state.endTime)
	local beforeConclusion = store:CaptureRaidHistoryState()
	local conclusionEvent = assert(store:ConcludeActiveRaid(raidUid, 1721120200))
	assert(store:RestoreRaidHistoryState(beforeConclusion))
	assert(store:ApplyReplicaEvent(conclusionEvent))
	assertEqual("complete", store:GetRecord(raidUid).status, "replica conclusion did not complete raid")
	assertEqual(nil, store:EnsureArchive().activeRaidUid, "replica conclusion retained active raid pointer")
	assertEqual(0, #store:GetRecord(raidUid).events, "replica conclusion retained active event ledger")
	print("PASS raid_replication_conclusion")
end

function cases.raid_replication_live_snapshot_repair(addon)
	local store = installRaidArchiveFixture(addon)
	local _, _, raidUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		serverTime = 1721120000,
		zone = "Icecrown Citadel",
		players = { { playerNid = 1, name = "Alpha", join = 1721120000 } },
	}))
	local sequenceOne = store:CaptureRaidHistoryState()
	local function snapshotFromArchive(captured, uid)
		local record = assert(captured.raids.raids[uid], "captured record missing")
		local snapshot = deepCopy(record)
		snapshot.raidUid = uid
		snapshot.checkpointSequence = snapshot.sequence
		snapshot.events = {}
		return snapshot
	end
	assert(store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
		metadata = { zone = "Ulduar" },
	}))
	local branchA = assert(store:BuildSnapshot(raidUid))

	assert(store:RestoreRaidHistoryState(sequenceOne))
	assert(store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
		metadata = { zone = "Naxxramas" },
	}))
	local branchB = assert(store:BuildSnapshot(raidUid))
	assertEqual(branchA.sequence, branchB.sequence)
	assertTrue(branchA.digest ~= branchB.digest, "fixture branches did not diverge")

	assert(store:RestoreRaidHistoryState(sequenceOne))
	assert(store:RepairActiveFromSnapshot(branchA))
	local corrupted = assert(store:GetRecord(raidUid))
	corrupted.state.zone = "Corrupted Local Alias"
	assertTrue(
		store:GetStateDigest(corrupted.state) ~= corrupted.digest,
		"fixture did not corrupt the exposed local state"
	)
	assert(store:RepairActiveFromSnapshot(branchA))
	assertEqual(
		"Ulduar",
		store:GetRecord(raidUid).state.zone,
		"same-position valid snapshot did not repair corrupted local state"
	)
	local beforeRejectedRepair = store:CaptureRaidHistoryState()
	local staleSnapshot = snapshotFromArchive(sequenceOne, raidUid)
	local repaired, repairReason = store:RepairActiveFromSnapshot(staleSnapshot)
	assertEqual(nil, repaired)
	assertEqual("STALE_SNAPSHOT", repairReason)
	assertEqual("DIGEST_CONFLICT", select(2, store:RepairActiveFromSnapshot(branchB)))
	assertTrue(deepEqual(beforeRejectedRepair, store:CaptureRaidHistoryState()), "rejected repair mutated archive")

	local wrongEpoch = deepCopy(branchA)
	wrongEpoch.authorityEpoch = wrongEpoch.authorityEpoch + 1
	assertEqual("AUTHORITY_EPOCH_MISMATCH", select(2, store:RepairActiveFromSnapshot(wrongEpoch)))

	local oldSequence = store:GetRecord(raidUid).sequence
	local beforeConclusion = store:CaptureRaidHistoryState()
	assert(store:ConcludeActiveRaid(raidUid, 1721120200))
	local finalSnapshot = assert(store:BuildSnapshot(raidUid))
	assert(store:RestoreRaidHistoryState(beforeConclusion))
	assert(store:RepairActiveFromSnapshot(finalSnapshot))
	assertEqual(oldSequence + 1, store:GetRecord(raidUid).sequence, "live repair did not advance sequence")
	assertEqual(finalSnapshot.digest, store:GetRecord(raidUid).digest, "live repair digest differs")
	assertEqual("complete", store:GetRecord(raidUid).status, "final live repair did not conclude raid")
	assertEqual(nil, store:EnsureArchive().activeRaidUid, "final live repair retained active pointer")
	assertEqual(0, #store:GetRecord(raidUid).events, "final live repair retained event ledger")

	local historical = deepCopy(branchA)
	historical.raidUid = "unrelated-history"
	local archiveBefore = store:CaptureRaidHistoryState()
	assertEqual(nil, store:RepairActiveFromSnapshot(historical), "live repair accepted unrelated raid")
	assertTrue(deepEqual(archiveBefore, store:CaptureRaidHistoryState()), "rejected repair mutated archive")
	print("PASS raid_replication_live_snapshot_repair")
end

function cases.raid_replication_authority_guard(addon)
	local store = installRaidArchiveFixture(addon)
	local _, _, raidUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		serverTime = 1721120000,
		zone = "Icecrown Citadel",
	}))
	local record = store:GetRecord(raidUid)
	local sequence, digest = record.sequence, record.digest
	store:SetAuthorityGuard(function()
		return false
	end)
	local event, reason = store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
		metadata = { zone = "Ulduar" },
	})
	assertEqual(nil, event, "non-authority commit succeeded")
	assertEqual("NOT_RAID_LEADER", reason, "authority rejection reason differs")
	assertEqual(sequence, record.sequence, "rejected authority commit advanced sequence")
	assertEqual(digest, record.digest, "rejected authority commit changed digest")
	store:SetAuthorityGuard(function()
		return true
	end)
	assert(store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
		metadata = { zone = "Ulduar" },
	}))
	print("PASS raid_replication_authority_guard")
end

local function installRaidReplicationProtocolFixture(addon)
	installPayloadCodec(addon)
	installRaidReplicationEventFixture(addon)
	loadAddonFile(addon, "Raid Management Addon/Modules/Json.lua")
	local payload = addon.Comms.Payload
	function payload.PackFields(separator, ...)
		local values = { ... }
		for i = 1, #values do
			values[i] = tostring(values[i])
		end
		return table.concat(values, separator)
	end
	function payload.SplitFields(text, separator)
		local fields = {}
		local from = 1
		while true do
			local startAt, endAt = string.find(text, separator, from, true)
			if not startAt then
				fields[#fields + 1] = string.sub(text, from)
				break
			end
			fields[#fields + 1] = string.sub(text, from, startAt - 1)
			from = endAt + 1
		end
		return fields, #fields
	end
	addon.Item = addon.Item or {}
	addon.Item.GetItemIdFromLink = function(itemLink)
		return type(itemLink) == "string" and tonumber(string.match(itemLink, "item:(%d+)")) or nil
	end
	addon.Item.GetItemStringFromLink = function(itemLink)
		return type(itemLink) == "string" and string.match(itemLink, "|H(item:[%-%d:]+)|h") or nil
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncProtocol.lua")
	return addon.DB.SyncProtocol
end

local function protocolBodies()
	return {
		HEAD_REQ = {},
		HEAD = {
			raidUid = "r:1721120000:1:12345678",
			authorityEpoch = 2,
			sequence = 7,
			checkpointSequence = 3,
			digest = "12345678:42",
			status = "active",
			zone = "Icecrown Citadel",
			size = 25,
			difficulty = 4,
		},
		EVENT = { event = buildRaidReplicationEvent("LOOT_DELETED", { lootNid = 4 }, 7, "12345678:42") },
		LIVE_LOOT = {
			event = {
				raidUid = "r:1721120000:1:12345678",
				authorityEpoch = 1,
				sequence = 42,
				eventUid = "r:1721120000:1:12345678:1:42",
				eventType = "LOOT_ADDED",
				payload = {
					loot = {
						lootNid = 31,
						itemId = 47242,
						itemName = "Pride of the Eredar",
						itemString = "item:47242:0:0:0:0:0:0:0",
						itemLink = "|cffa335ee|Hitem:47242:0:0:0:0:0:0:0|h[Pride of the Eredar]|h|r",
						itemRarity = 4,
						itemTexture = "Interface\\Icons\\INV_Jewelry_Ring_66",
						itemCount = 1,
						looterNid = 7,
						rollType = 1,
						rollValue = 94,
						rollSessionId = "RS:42",
						bossNid = 4,
						time = 1721120200,
						source = "DISTRIBUTION_AWARD",
					},
				},
				resultDigest = "12345678:2048",
			},
		},
		RANGE_REQ = { raidUid = "r1", authorityEpoch = 2, fromSequence = 4, toSequence = 7 },
		RANGE_DATA = {
			raidUid = "r1",
			authorityEpoch = 2,
			fromSequence = 4,
			toSequence = 7,
			partIndex = 1,
			partCount = 2,
			chunk = "abc123+/=",
		},
		SNAP_REQ = { raidUid = "r1" },
		SNAP_DATA = {
			raidUid = "r1",
			authorityEpoch = 2,
			sequence = 7,
			partIndex = 2,
			partCount = 2,
			chunk = "snapshot-part",
		},
		OFFER = {
			raidUid = "r1",
			authorityEpoch = 2,
			sequence = 7,
			digest = "12345678:42",
			zone = "Icecrown Citadel",
			startTime = 1721120000,
			size = 25,
			difficulty = 4,
			lootCount = 12,
		},
		RESULT = { outcome = "FAILED", reason = "TRANSFER_TIMEOUT" },
	}
end

function cases.raid_replication_protocol_round_trip(addon)
	local protocol = installRaidReplicationProtocolFixture(addon)
	assertEqual(5, protocol.VERSION, "protocol version differs")
	local headRequestWire = assert(protocol.Encode("HEAD_REQ", nil, nil, {}))
	local headRequestRaw = assert(addon.Comms.Payload.Deserialize(headRequestWire))
	assertEqual(5, headRequestRaw[1], "raid wire version differs")
	assertEqual("HEAD_REQ", headRequestRaw[2], "raid message kind differs")
	assertEqual(false, headRequestRaw[3], "missing request id is not dense")
	assertEqual(false, headRequestRaw[4], "missing target is not dense")
	assertEqual(nil, protocol.Decode("R4\tHEAD_REQ\t-\t-\t{}"), "R4 wire was accepted")
	local bodies = protocolBodies()
	local kinds = {
		"HEAD_REQ",
		"HEAD",
		"EVENT",
		"LIVE_LOOT",
		"RANGE_REQ",
		"RANGE_DATA",
		"SNAP_REQ",
		"SNAP_DATA",
		"OFFER",
		"RESULT",
	}
	for i = 1, #kinds do
		local kind = kinds[i]
		local fireAndForget = kind == "HEAD_REQ" or kind == "HEAD" or kind == "EVENT" or kind == "LIVE_LOOT"
		local requestId, target
		if not fireAndForget then
			requestId = "request-" .. i
			target = "Recipient"
		end
		local message, messageReason = protocol.Encode(kind, requestId, target, bodies[kind])
		assertTrue(message ~= nil, kind .. " did not encode: " .. tostring(messageReason))
		assertTrue(#message <= 243, kind .. " envelope exceeds the safe wire limit")
		local decoded, decodeReason = protocol.Decode(message)
		assertTrue(decoded ~= nil, kind .. " did not decode: " .. tostring(decodeReason))
		assertEqual(kind, decoded.kind, kind .. " decoded kind differs")
		assertEqual(requestId or "-", decoded.requestId, kind .. " decoded request ID differs")
		assertEqual(target or "-", decoded.target, kind .. " decoded target differs")
		assertTrue(deepEqual(bodies[kind], decoded.body), kind .. " decoded body differs")
		local oldWire = assert(addon.Comms.Payload.Serialize({ 4, kind, requestId or false, target or false, rawget(assert(addon.Comms.Payload.Deserialize(message)), 5) }))
		assertEqual(nil, protocol.Decode(oldWire), "R4 wire was accepted")
	end
	local legacyHead = deepCopy(bodies.HEAD)
	legacyHead.zone = nil
	legacyHead.size = nil
	legacyHead.difficulty = nil
	local legacyWire = assert(protocol.Encode("HEAD", nil, nil, legacyHead))
	assertTrue(deepEqual(legacyHead, assert(protocol.Decode(legacyWire)).body), "legacy HEAD did not round-trip")

	local boundaryBody = deepCopy(bodies.OFFER)
	boundaryBody.zone = string.rep("x", 69)
	local boundaryMessage = assert(protocol.Encode("OFFER", "request-fixed", "Target", boundaryBody))
	assertTrue(#boundaryMessage <= 243, "accepted R5 envelope exceeded the wire limit")
	assertTrue(protocol.Decode(boundaryMessage) ~= nil, "bounded R5 envelope did not decode")
	local internationalZones = { "Citadelle française", "Eiskronenzitadelle ä", "Ледяная Корона" }
	for i = 1, #internationalZones do
		local internationalOffer = deepCopy(bodies.OFFER)
		internationalOffer.zone = internationalZones[i]
		local internationalWire = assert(protocol.Encode("OFFER", "utf8-" .. tostring(i), "Target", internationalOffer))
		assertEqual(
			internationalZones[i],
			assert(protocol.Decode(internationalWire)).body.zone,
			"international offer zone did not round-trip"
		)
	end
	local function wireNoise(seed, count, excludePipe)
		local value = {}
		for i = 1, count do
			local valueByte = 33 + ((seed * 41 + i * 53) % 94)
			if excludePipe and valueByte == 124 then
				valueByte = 123
			end
			value[i] = string.char(valueByte)
		end
		return table.concat(value)
	end
	local oversizedBody = deepCopy(boundaryBody)
	oversizedBody.raidUid = wireNoise(1, 40)
	oversizedBody.zone = wireNoise(2, 128, true)
	local oversizedMessage, oversizedReason =
		protocol.Encode("OFFER", wireNoise(3, 64), wireNoise(4, 64), oversizedBody)
	assertEqual(nil, oversizedMessage, "oversize envelope was accepted")
	assertEqual("MESSAGE_TOO_LARGE", oversizedReason, "oversize envelope failed for the wrong reason")
	print("PASS raid_replication_protocol_round_trip")
end

function cases.raid_replication_protocol_compact_live_loot(addon)
	local protocol = installRaidReplicationProtocolFixture(addon)
	local event = protocolBodies().LIVE_LOOT.event
	local verbose, verboseReason = protocol.Encode("EVENT", "-", "-", { event = event })
	assertEqual(nil, verbose, "representative verbose loot unexpectedly fit")
	assertEqual("MESSAGE_TOO_LARGE", verboseReason)
	local wire, reason = protocol.Encode("LIVE_LOOT", "-", "-", { event = event })
	assertTrue(wire ~= nil, "compact live loot did not encode: " .. tostring(reason))
	assertTrue(#wire <= 243, "compact live loot exceeded 243 bytes")
	local decoded, decodeReason = protocol.Decode(wire)
	assertTrue(decoded ~= nil, "compact live loot did not decode: " .. tostring(decodeReason))
	assertEqual("LIVE_LOOT", decoded.kind)
	assertTrue(deepEqual(event, decoded.body.event), "compact live loot did not reconstruct exactly")
	print("PASS raid_replication_protocol_compact_live_loot")
end

function cases.raid_replication_protocol_accepts_group_loot_roll_types(addon)
	local protocol = installRaidReplicationProtocolFixture(addon)
	for _, rollType in ipairs({ 8, 9 }) do
		local event = deepCopy(protocolBodies().LIVE_LOOT.event)
		event.payload.loot.rollType = rollType
		local wire, reason = protocol.Encode("LIVE_LOOT", "-", "-", { event = event })
		assertTrue(wire ~= nil, "group-loot roll type " .. rollType .. " did not encode: " .. tostring(reason))
		assertTrue(#wire <= 243, "group-loot roll type " .. rollType .. " exceeded 243 bytes")
		local decoded, decodeReason = protocol.Decode(wire)
		assertTrue(decoded ~= nil, "group-loot roll type " .. rollType .. " did not decode: " .. tostring(decodeReason))
		assertTrue(
			deepEqual(event, decoded.body.event),
			"group-loot roll type " .. rollType .. " did not round-trip exactly"
		)
	end
	print("PASS raid_replication_protocol_accepts_group_loot_roll_types")
end

function cases.raid_replication_protocol_rejects_invalid(addon)
	local protocol = installRaidReplicationProtocolFixture(addon)
	local bodies = protocolBodies()
	local previousLibStub = _G.LibStub
	_G.LibStub = nil
	local libDeflate = assert(loadfile("Raid Management Addon/Libs/LibDeflate/LibDeflate.lua"))()
	_G.LibStub = previousLibStub
	local addonChunk = libDeflate:EncodeForWoWAddonChannel("snapshot" .. string.char(128))
	assertTrue(
		string.find(addonChunk, "[\128-\255]") ~= nil,
		"LibDeflate addon-channel chunk did not retain an extended byte"
	)
	assertEqual(
		"snapshot" .. string.char(128),
		libDeflate:DecodeForWoWAddonChannel(addonChunk),
		"LibDeflate addon-channel chunk did not round-trip"
	)
	local encodedSnapshot = deepCopy(bodies.SNAP_DATA)
	encodedSnapshot.chunk = addonChunk
	assertTrue(
		protocol.Encode("SNAP_DATA", "request", "Target", encodedSnapshot) ~= nil,
		"LibDeflate addon-channel snapshot chunk was rejected"
	)
	local nulSnapshot = deepCopy(encodedSnapshot)
	nulSnapshot.chunk = addonChunk .. string.char(0)
	assertEqual(
		nil,
		protocol.Encode("SNAP_DATA", "request", "Target", nulSnapshot),
		"NUL-containing snapshot chunk was accepted"
	)
	local unsafeZones = {
		"Icecrown\nCitadel",
		"Icecrown\tCitadel",
		"|cffff0000ICC",
		"|Ticon:16|t",
		"|Hitem:1|hICC|h",
		"Icecrown" .. string.char(1) .. "Citadel",
		"Icecrown" .. string.char(127) .. "Citadel",
	}
	for i = 1, #unsafeZones do
		local unsafeOffer = deepCopy(bodies.OFFER)
		unsafeOffer.zone = unsafeZones[i]
		assertEqual(
			nil,
			protocol.Encode("OFFER", "unsafe-zone-" .. tostring(i), "Target", unsafeOffer),
			"unsafe offer zone was accepted"
		)
	end
	assertEqual(nil, protocol.Encode("EXEC", "request", "Target", {}), "unknown message kind was accepted")
	local unknownWire = assert(addon.Comms.Payload.Serialize({ 5, "EXEC", "request", "Target", {} }))
	assertEqual(nil, protocol.Decode(unknownWire), "unknown decoded kind was accepted")
	local unsupportedBodyCalls = 0
	local decodeBody = protocol.DecodeBody
	protocol.DecodeBody = function(...)
		unsupportedBodyCalls = unsupportedBodyCalls + 1
		return decodeBody(...)
	end
	local oldWire = assert(addon.Comms.Payload.Serialize({ 4, "HEAD", false, false, bodies.HEAD }))
	local decoded, reason = protocol.Decode(oldWire)
	assertEqual(nil, decoded, "version 2 envelope was accepted")
	assertEqual("UNSUPPORTED_PROTOCOL", reason, "version 2 rejection reason differs")
	assertEqual(0, unsupportedBodyCalls, "unsupported version decoded its body")
	protocol.DecodeBody = decodeBody

	local validHead = assert(protocol.Encode("HEAD", nil, nil, bodies.HEAD))
	local validHeadRaw = assert(addon.Comms.Payload.Deserialize(validHead))
	local extraWire = assert(addon.Comms.Payload.Serialize({
		validHeadRaw[1], validHeadRaw[2], validHeadRaw[3], validHeadRaw[4], validHeadRaw[5], "extra",
	}))
	assertEqual(nil, protocol.Decode(extraWire), "extra envelope field was accepted")

	local invalidCases = {}
	local function reject(label, kind, requestId, target, body)
		invalidCases[#invalidCases + 1] = {
			label = label,
			kind = kind,
			requestId = requestId,
			target = target,
			body = body,
		}
	end
	local candidate = deepCopy(bodies.HEAD)
	candidate.extra = true
	reject("unknown body key", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.HEAD)
	candidate.status = "paused"
	reject("HEAD status enum", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.HEAD)
	candidate.digest = "ABCDEF12:42"
	reject("lowercase digest", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.HEAD)
	candidate.digest = "12345678:0"
	reject("positive digest byte count", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.HEAD)
	candidate.size = nil
	reject("partial HEAD context", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.HEAD)
	candidate.size = 40
	reject("HEAD raid size", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.HEAD)
	candidate.difficulty = 5
	reject("HEAD difficulty", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.HEAD)
	candidate.zone = string.rep("x", 81)
	reject("HEAD zone bound", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.RESULT)
	candidate.outcome = "OK"
	reject("RESULT outcome enum", "RESULT", "request", "Target", candidate)
	candidate = deepCopy(bodies.OFFER)
	candidate.authorityEpoch = 0
	reject("OFFER authority epoch", "OFFER", "request", "Target", candidate)
	for _, epoch in ipairs({ 0, 1000000 }) do
		candidate = deepCopy(bodies.HEAD)
		candidate.authorityEpoch = epoch
		reject("authority epoch " .. epoch, "HEAD", nil, nil, candidate)
	end
	for _, sequence in ipairs({ -1, 1000000000 }) do
		candidate = deepCopy(bodies.HEAD)
		candidate.sequence = sequence
		reject("HEAD sequence " .. sequence, "HEAD", nil, nil, candidate)
	end
	candidate = deepCopy(bodies.HEAD)
	candidate.sequence = 0
	candidate.checkpointSequence = 0
	reject("active HEAD sequence zero", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.HEAD)
	candidate.checkpointSequence = -1
	reject("negative checkpoint", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.HEAD)
	candidate.checkpointSequence = candidate.sequence + 1
	reject("checkpoint beyond sequence", "HEAD", nil, nil, candidate)
	candidate = deepCopy(bodies.RANGE_REQ)
	candidate.toSequence = candidate.fromSequence - 1
	reject("ordered range", "RANGE_REQ", "request", "Target", candidate)
	candidate = deepCopy(bodies.RANGE_REQ)
	candidate.toSequence = candidate.fromSequence + 512
	reject("512-event range bound", "RANGE_REQ", "request", "Target", candidate)
	candidate = deepCopy(bodies.RANGE_DATA)
	candidate.partIndex = 0
	reject("positive part index", "RANGE_DATA", "request", "Target", candidate)
	candidate = deepCopy(bodies.RANGE_DATA)
	candidate.partCount = 257
	reject("part count maximum", "RANGE_DATA", "request", "Target", candidate)
	candidate = deepCopy(bodies.RANGE_DATA)
	candidate.partIndex = candidate.partCount + 1
	reject("part index not beyond count", "RANGE_DATA", "request", "Target", candidate)
	candidate = deepCopy(bodies.RANGE_DATA)
	candidate.chunk = string.rep("x", 221)
	reject("chunk maximum", "RANGE_DATA", "request", "Target", candidate)
	candidate = deepCopy(bodies.RESULT)
	candidate.reason = string.rep("x", 97)
	reject("RESULT reason maximum", "RESULT", "request", "Target", candidate)
	candidate = deepCopy(bodies.SNAP_REQ)
	candidate.raidUid = "r:\195\169"
	reject("ASCII raid UID", "SNAP_REQ", "request", "Target", candidate)
	reject("HEAD_REQ nonempty body", "HEAD_REQ", nil, nil, { raidUid = "r1" })
	reject("HEAD_REQ targeted addressing", "HEAD_REQ", "request", "Leader", {})
	reject("HEAD broadcast addressing", "HEAD", "request", "Target", bodies.HEAD)
	reject("EVENT broadcast addressing", "EVENT", "request", "Target", bodies.EVENT)
	reject("targeted request ID required", "SNAP_REQ", nil, "Target", bodies.SNAP_REQ)
	reject("targeted target required", "SNAP_REQ", "request", nil, bodies.SNAP_REQ)
	reject("targeted request broadcast sentinel", "SNAP_REQ", "-", "Target", bodies.SNAP_REQ)
	reject("targeted target broadcast sentinel", "SNAP_REQ", "request", "-", bodies.SNAP_REQ)
	for i = 1, #invalidCases do
		local row = invalidCases[i]
		assertEqual(nil, protocol.Encode(row.kind, row.requestId, row.target, row.body), row.label .. " was accepted")
	end

	local oneByteChunk = deepCopy(bodies.RANGE_DATA)
	oneByteChunk.chunk = "x"
	assertTrue(protocol.Encode("RANGE_DATA", "request", "Target", oneByteChunk) ~= nil, "one-byte chunk was rejected")
	local sequenceZeroSnapshot = deepCopy(bodies.SNAP_DATA)
	sequenceZeroSnapshot.sequence = 0
	assertTrue(
		protocol.Encode("SNAP_DATA", "request", "Target", sequenceZeroSnapshot) ~= nil,
		"sequence-zero snapshot chunk was rejected"
	)
	local sequenceZeroCompleteHead = deepCopy(bodies.HEAD)
	sequenceZeroCompleteHead.sequence = 0
	sequenceZeroCompleteHead.checkpointSequence = 0
	sequenceZeroCompleteHead.status = "complete"
	assertTrue(
		protocol.Encode("HEAD", nil, nil, sequenceZeroCompleteHead) ~= nil,
		"sequence-zero completed HEAD was rejected"
	)
	local maximumChunk = deepCopy(bodies.RANGE_DATA)
	maximumChunk.chunk = string.rep("x", 220)
	local maximumChunkWire, maximumChunkReason = protocol.Encode("RANGE_DATA", "request", "Target", maximumChunk)
	assertEqual(nil, maximumChunkWire, "R5 envelope accepted an oversized on-wire chunk")
	assertEqual("MESSAGE_TOO_LARGE", maximumChunkReason, "R5 oversized chunk rejection reason differs")
	local maximumReason = deepCopy(bodies.RESULT)
	maximumReason.reason = string.rep("x", 96)
	assertTrue(
		protocol.Encode("RESULT", "request", "Target", maximumReason) ~= nil,
		"96-byte RESULT reason was rejected"
	)

	assertEqual(nil, protocol.Decode("\001malformed"), "malformed encoded envelope was accepted")
	local sparseWire = assert(addon.Comms.Payload.Serialize({
		[1] = 5, [2] = "SNAP_REQ", [3] = "request", [5] = bodies.SNAP_REQ,
	}))
	assertEqual(nil, protocol.Decode(sparseWire), "sparse R5 envelope was accepted")
	local wrongBodyWire = assert(addon.Comms.Payload.Serialize({ 5, "SNAP_REQ", "request", "Target", "body" }))
	assertEqual(nil, protocol.Decode(wrongBodyWire), "non-table R5 body was accepted")

	local compactEvent = protocolBodies().LIVE_LOOT.event
	local compactSlots = {
		compactEvent.raidUid,
		compactEvent.authorityEpoch,
		compactEvent.sequence,
		compactEvent.resultDigest,
		31,
		compactEvent.payload.loot.itemLink,
		1,
		7,
		1,
		94,
		"RS:42",
		4,
		1721120200,
		"DISTRIBUTION_AWARD",
		compactEvent.payload.loot.itemTexture,
		false,
	}
	local function rejectCompact(label, slots)
		local encoded = assert(addon.Comms.Payload.Serialize({ 5, "LIVE_LOOT", false, false, slots }))
		local body, compactReason = protocol.Decode(encoded)
		assertEqual(nil, body, label .. " was accepted")
		assertTrue(
			compactReason == "INVALID_MESSAGE_BODY"
				or compactReason == "NON_RECONSTRUCTIBLE_LIVE_LOOT"
				or compactReason == "MESSAGE_TOO_LARGE",
			label .. " rejected with unexpected reason " .. tostring(compactReason)
		)
	end
	local arity = deepCopy(compactSlots)
	arity[16] = nil
	rejectCompact("compact dense-array arity", arity)
	local nullSlot = deepCopy(compactSlots)
	nullSlot[5] = false
	rejectCompact("compact required null slot", nullSlot)
	local malformedLink = deepCopy(compactSlots)
	malformedLink[6] = "item:47242"
	rejectCompact("compact malformed hyperlink", malformedLink)
	local mismatched = deepCopy(compactEvent)
	mismatched.payload.loot.itemId = 1
	assertEqual(
		nil,
		protocol.Encode("LIVE_LOOT", "-", "-", { event = mismatched }),
		"mismatched derived item ID was accepted"
	)
	local unexpectedKey = deepCopy(compactEvent)
	unexpectedKey.payload.loot.extra = true
	assertEqual(
		nil,
		protocol.Encode("LIVE_LOOT", "-", "-", { event = unexpectedKey }),
		"unexpected loot key was accepted"
	)
	local malformedSource = deepCopy(compactSlots)
	malformedSource[16] = {
		"BOSS",
		4,
		false,
		false,
		false,
		false,
		false,
		{ { "Name", "KIND", "key", 7, "extra" } },
	}
	rejectCompact("compact malformed nested source tuple", malformedSource)
	local oversized = deepCopy(compactEvent)
	oversized.payload.loot.itemTexture = string.rep("x", 300)
	local oversizedWire, oversizedReason = protocol.Encode("LIVE_LOOT", "-", "-", { event = oversized })
	assertEqual(nil, oversizedWire, "oversized compact live loot was accepted")
	assertEqual("MESSAGE_TOO_LARGE", oversizedReason, "oversized compact live loot failed for the wrong reason")
	print("PASS raid_replication_protocol_rejects_invalid")
end

function cases.raid_replication_protocol_rejects_malformed_compact_live_loot_scalars(addon)
	local protocol = installRaidReplicationProtocolFixture(addon)
	local compactEvent = protocolBodies().LIVE_LOOT.event
	local compactSlots = {
		compactEvent.raidUid,
		compactEvent.authorityEpoch,
		compactEvent.sequence,
		compactEvent.resultDigest,
		31,
		compactEvent.payload.loot.itemLink,
		1,
		7,
		1,
		94,
		"RS:42",
		4,
		1721120200,
		"DISTRIBUTION_AWARD",
		compactEvent.payload.loot.itemTexture,
		false,
	}
	local function copyCompactSlots()
		local copy = {}
		for i = 1, #compactSlots do
			copy[i] = compactSlots[i]
		end
		return copy
	end
	local function rejectCompact(label, slot, value)
		local slots = copyCompactSlots()
		slots[slot] = value
		local encoded = assert(addon.Comms.Payload.Serialize({ 5, "LIVE_LOOT", false, false, slots }))
		local body = protocol.Decode(encoded)
		assertEqual(nil, body, label .. " was accepted")
	end

	local malformedScalars = {
		{ "raid UID table", 1, {} },
		{ "authority epoch string", 2, "1" },
		{ "sequence boolean", 3, true },
		{ "digest table", 4, {} },
		{ "loot NID string", 5, "31" },
		{ "item link table", 6, {} },
		{ "item count boolean", 7, true },
		{ "looter NID table", 8, {} },
		{ "roll type string", 9, "1" },
		{ "roll value boolean", 10, false },
		{ "roll session table", 11, {} },
		{ "boss NID string", 12, "4" },
		{ "time table", 13, {} },
		{ "source table", 14, {} },
		{ "item texture table", 15, {} },
		{ "loot source string", 16, "source" },
	}
	for i = 1, #malformedScalars do
		local case = malformedScalars[i]
		rejectCompact(case[1], case[2], case[3])
	end

	local boundedScalars = {
		{ "authority epoch lower bound", 2, 0 },
		{ "authority epoch upper bound", 2, 1000000 },
		{ "sequence lower bound", 3, 0 },
		{ "sequence upper bound", 3, 1000000000 },
		{ "loot NID lower bound", 5, 0 },
		{ "loot NID upper bound", 5, 1000000000 },
		{ "item count lower bound", 7, 0 },
		{ "item count upper bound", 7, 1000000000 },
		{ "looter NID lower bound", 8, 0 },
		{ "looter NID upper bound", 8, 1000000000 },
		{ "roll type lower bound", 9, -1 },
		{ "roll type upper bound", 9, 10 },
		{ "roll value lower bound", 10, -1 },
		{ "roll value upper bound", 10, 1000000000 },
		{ "boss NID lower bound", 12, -1 },
		{ "boss NID upper bound", 12, 1000000000 },
		{ "time lower bound", 13, 0 },
		{ "time upper bound", 13, 10000000000 },
	}
	for i = 1, #boundedScalars do
		local case = boundedScalars[i]
		rejectCompact(case[1], case[2], case[3])
	end

	local optionalNulls = copyCompactSlots()
	optionalNulls[11] = false
	optionalNulls[14] = false
	optionalNulls[15] = false
	optionalNulls[16] = false
	local optionalWire = assert(addon.Comms.Payload.Serialize({ 5, "LIVE_LOOT", false, false, optionalNulls }))
	local optionalBody, optionalReason = protocol.Decode(optionalWire)
	assertTrue(optionalBody ~= nil, "false optional compact slots were rejected: " .. tostring(optionalReason))
	print("PASS raid_replication_protocol_rejects_malformed_compact_live_loot_scalars")
end
