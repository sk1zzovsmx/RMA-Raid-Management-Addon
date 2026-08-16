function cases.lua_51_smoke()
	assertEqual("Lua 5.1", _VERSION, "behavior harness requires Lua 5.1")
	print("PASS lua_51_smoke")
end

function cases.screen_notice_uses_internal_event_without_direct_export(addon)
	local registeredEvent
	local registeredCallback
	local titleValue
	local detailValue
	local detailHidden = false
	local frameWidth
	local frameHeight
	local frameAlpha
	local frameShown = false
	local frameLevel
	local fadeArgs
	local screenNoticeEvent = "RMA_SCREEN_NOTICE"
	local titleFontSet = false
	local detailFontSet = false

	local noticeFrame = {
		SetFrameLevel = function(_, value)
			frameLevel = value
		end,
		SetWidth = function(_, value)
			frameWidth = value
		end,
		SetHeight = function(_, value)
			frameHeight = value
		end,
		SetAlpha = function(_, value)
			frameAlpha = value
		end,
		Show = function()
			frameShown = true
		end,
		Hide = function()
			frameShown = false
		end,
	}
	local titleText = {
		SetFont = function(_, path, size, flags)
			titleFontSet = path == "Fonts\\FRIZQT__.TTF" and size == 24 and flags == "OUTLINE"
			return titleFontSet
		end,
		SetText = function(_, value)
			if not titleFontSet then
				error("RMAScreenNoticeFrameTitleText:SetText(): Font not set")
			end
			titleValue = value
		end,
		GetWidth = function()
			return 180
		end,
	}
	local detailText = {
		SetFont = function(_, path, size, flags)
			detailFontSet = path == "Fonts\\FRIZQT__.TTF" and size == 16 and flags == "OUTLINE"
			return detailFontSet
		end,
		SetText = function(_, value)
			if not detailFontSet then
				error("RMAScreenNoticeFrameDetailText:SetText(): Font not set")
			end
			detailValue = value
		end,
		Hide = function()
			detailHidden = true
		end,
	}

	_G.RMAScreenNoticeFrame = noticeFrame
	_G.RMAScreenNoticeFrameTitleText = titleText
	_G.RMAScreenNoticeFrameDetailText = detailText
	addon.UI = {
		Effects = {
			SetTimedFade = function(...)
				fadeArgs = { ... }
			end,
		},
	}
	addon.Events = { Internal = { ScreenNotice = screenNoticeEvent } }
	addon.Bus = {
		RegisterCallback = function(eventName, callback)
			registeredEvent = eventName
			registeredCallback = callback
		end,
	}

	loadAddonFile(addon, "Raid Management Addon/Modules/UI/ScreenNotice.lua")

	assertEqual(screenNoticeEvent, registeredEvent, "screen notice registered for the wrong event")
	assertTrue(type(registeredCallback) == "function", "screen notice callback was not registered")
	assertEqual(nil, addon.UI.ScreenNotice.Show, "screen notice retained its direct export")
	assertEqual(false, registeredCallback(screenNoticeEvent, "", 2.5), "empty screen notice was accepted")
	local noticeOk, noticeResult = pcall(registeredCallback, screenNoticeEvent, "Master Loot enabled", 2.5)
	assertTrue(noticeOk, "screen notice set text before assigning valid fonts: " .. tostring(noticeResult))
	assertEqual(true, noticeResult, "screen notice event failed")
	assertEqual(true, titleFontSet, "screen notice title font was not initialized")
	assertEqual(true, detailFontSet, "screen notice detail font was not initialized")
	assertEqual(1000, frameLevel, "screen notice frame level changed")
	assertEqual("|cffff2020Master Loot|r enabled", titleValue, "screen notice title colorization changed")
	assertEqual("", detailValue, "screen notice detail was not cleared")
	assertEqual(true, detailHidden, "screen notice detail remained visible")
	assertEqual(180, frameWidth, "screen notice width changed")
	assertEqual(24, frameHeight, "screen notice height changed")
	assertEqual(1, frameAlpha, "screen notice alpha changed")
	assertEqual(true, frameShown, "screen notice frame was not shown")
	assertEqual(noticeFrame, fadeArgs and fadeArgs[1], "screen notice fade used the wrong frame")
	assertEqual(2.5, fadeArgs and fadeArgs[2], "screen notice fade duration changed")
	assertEqual(0.35, fadeArgs and fadeArgs[3], "screen notice fade length changed")
	assertTrue(type(fadeArgs and fadeArgs[4]) == "function", "screen notice fade callback was not provided")
	print("PASS screen_notice_uses_internal_event_without_direct_export")
end

local function installRaidSessionCheckFixture(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	_G.SetRaidTarget = function() end
	addon.Diag.A = setmetatable({}, {
		__index = function(_, key)
			return key
		end,
	})
	addon.Diag.D = {
		LogRaidCheck = "%s %s %s",
		LogRaidSessionCreate = "%s %d %d",
		LogRaidSessionChange = "%s %d %d",
	}
	addon.L.RaidZones.Ulduar = true
	addon.L.StrNewRaidSessionChange = "Raid session changed"
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Session.lua")
	raid:CommitRecognizedInstanceContext("Ulduar", "ulduar", 2)
	return fixture, raid
end

function cases.raid_session_uses_transient_canonical_identity(addon)
	local fixture, raid = installRaidSessionCheckFixture(addon)
	fixture.raids[1].size = 25
	fixture.raids[1].difficulty = 2
	local createCalls = 0
	local createdZone
	fixture.store.GetActiveRecord = function()
		return nil
	end
	addon.Database.SetCurrentRaid(nil)
	raid.Create = function(_, zone)
		createCalls = createCalls + 1
		createdZone = zone
		return true
	end

	raid:CommitRecognizedInstanceContext("Coeur du Magma", "molten core", 2)
	assertEqual(true, raid:Check(), "recognized localized raid was not admitted")
	assertEqual("Coeur du Magma", createdZone, "localized display name was not preserved for creation")

	addon.Database.SetCurrentRaid(1)
	local historicalZone = fixture.raids[1].zone
	createCalls = 0
	raid:ClearRecognizedInstanceContext()
	raid:CommitRecognizedInstanceContext("Citadelle locale", "icecrown citadel", 2)
	raid:Check()
	assertEqual(0, createCalls, "first recognized context after reload replaced the historical raid")
	assertEqual(historicalZone, fixture.raids[1].zone, "historical localized zone was rewritten")

	raid:CommitRecognizedInstanceContext("Citadelle traduite autrement", "icecrown citadel", 2)
	raid:Check()
	assertEqual(0, createCalls, "localized display-only change replaced the current raid")

	raid:CommitRecognizedInstanceContext("Nom contradictoire", "molten core", 2)
	raid:Check()
	assertEqual(1, createCalls, "canonical instance change did not replace the current raid")
	print("PASS raid_session_uses_transient_canonical_identity")
end

function cases.unknown_raid_retry_recovers_without_warning_spam(addon)
	local fixture, raid = installRaidSessionCheckFixture(addon)
	local frame = installInitStubs(addon)
	fixture:InstallTimers(raid)
	fixture:InstallTimers(addon)
	local instance = {
		name = "Unsupported Raid",
		instanceType = "raid",
		difficulty = 2,
		mapId = 9999,
	}
	local warnings = {}
	local debugMessages = {}
	local requestRaidInfoCount = 0
	local checkCount = 0
	local activeLootKey
	local activeIgnoredKey

	_G.GetInstanceInfo = function()
		return instance.name, instance.instanceType, instance.difficulty, nil, nil, nil, nil, instance.mapId
	end
	_G.RequestRaidInfo = function()
		requestRaidInfoCount = requestRaidInfoCount + 1
	end
	addon.L.MsgRaidInstanceUnsupported = "unsupported raid"
	addon.Diag.D.LogRaidUnknownInstance = "%s %s %s"
	addon.State.debugEnabled = true
	addon.Database.SetNextReset = function(value)
		return value
	end
	addon.LootSourcesData = {
		ResolveInstanceKey = function(_, mapId)
			if tonumber(mapId) == 631 then
				return "icecrown citadel"
			end
		end,
		GetActiveInstanceKey = function()
			return activeLootKey
		end,
		CaptureActivationState = function()
			return activeLootKey
		end,
		ActivateInstance = function(key)
			activeLootKey = key
			return true
		end,
		RestoreActivationState = function(key)
			activeLootKey = key
			return true
		end,
		DeactivateInstance = function()
			activeLootKey = nil
		end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function()
			return activeIgnoredKey
		end,
		CaptureActivationState = function()
			return activeIgnoredKey
		end,
		ActivateInstance = function(key)
			activeIgnoredKey = key
			return true
		end,
		RestoreActivationState = function(key)
			activeIgnoredKey = key
			return true
		end,
		DeactivateInstance = function()
			activeIgnoredKey = nil
		end,
	}
	raid.Check = function()
		checkCount = checkCount + 1
		return true
	end
	raid.CheckInitialRaidState = function() end

	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	assertTrue(frame ~= nil, "Init frame fixture was not installed")
	addon.warn = function(_, message)
		warnings[#warnings + 1] = message
	end
	addon.debug = function(_, message)
		debugMessages[#debugMessages + 1] = message
	end

	instance.name = "Icecrown Citadel"
	instance.mapId = 631
	addon:ZONE_CHANGED_NEW_AREA()
	assertEqual("icecrown citadel", raid:GetRecognizedInstanceContext().instanceKey, "recognized setup failed")

	instance.name = "Unsupported Raid"
	instance.mapId = 9999
	addon:RAID_INSTANCE_WELCOME(nil, 120)
	addon:ZONE_CHANGED_NEW_AREA()
	addon:PLAYER_ENTERING_WORLD()
	assertEqual(nil, raid:GetRecognizedInstanceContext(), "unknown transition retained recognized context")
	assertEqual(nil, activeLootKey, "unknown transition retained loot dataset")
	assertEqual(nil, activeIgnoredKey, "unknown transition retained ignored-mob dataset")
	assertEqual(1, #warnings, "overlapping entry events repeated the warning")
	assertEqual("unsupported raid", warnings[1], "warning exposed technical details")
	assertEqual(1, #debugMessages, "unknown identity diagnostic cardinality differs")
	assertTrue(string.find(debugMessages[1], "Unsupported Raid", 1, true) ~= nil, "debug omitted name")
	assertTrue(string.find(debugMessages[1], "9999", 1, true) ~= nil, "debug omitted map ID")
	fixture:AdvanceTime(4)
	assertEqual(1, #warnings, "delayed callbacks repeated the warning")

	instance.name = "Outside"
	instance.instanceType = "none"
	instance.difficulty = 0
	instance.mapId = 0
	addon:ZONE_CHANGED_NEW_AREA()
	instance.name = "Unsupported Raid"
	instance.instanceType = "raid"
	instance.difficulty = 2
	instance.mapId = 9999
	addon:RAID_INSTANCE_WELCOME(nil, 120)
	assertEqual(2, #warnings, "leave and re-entry did not reset warning dedupe")

	instance.name = "Loading Raid"
	instance.mapId = 0
	addon:ZONE_CHANGED_NEW_AREA()
	assertEqual(3, #warnings, "changed unknown identity did not warn once")
	instance.name = "Citadelle de la Couronne de glace"
	instance.mapId = 631
	fixture:AdvanceTime(4)
	local recovered = raid:GetRecognizedInstanceContext()
	assertTrue(recovered ~= nil, "bounded retry did not recover recognized context")
	assertEqual("icecrown citadel", recovered.instanceKey, "bounded retry recovered wrong canonical key")
	assertTrue(checkCount > 0, "bounded retry did not run the raid check")
	assertEqual(2, requestRaidInfoCount, "only RAID_INSTANCE_WELCOME should request raid info")
	print("PASS unknown_raid_retry_recovers_without_warning_spam")
end

function cases.raid_session_check_defers_persisted_active_raid_to_reentry(addon)
	local fixture, raid = installRaidSessionCheckFixture(addon)
	fixture.store.GetActiveRecord = function()
		return { status = "active", state = fixture.raids[1] }
	end
	addon.Database.SetCurrentRaid(nil)
	local createCalls = 0
	raid.Create = function()
		createCalls = createCalls + 1
		return true
	end

	local checked, reason = raid:Check("Ulduar", 2)

	assertEqual(false, checked, "persisted active raid was reported as created")
	assertEqual("RAID_REENTRY_REQUIRED", reason, "persisted active raid did not defer to reentry")
	assertEqual(0, createCalls, "persisted active raid attempted duplicate creation")
	print("PASS raid_session_check_defers_persisted_active_raid_to_reentry")
end

function cases.raid_session_check_creates_when_archive_has_no_active_raid(addon)
	local fixture, raid = installRaidSessionCheckFixture(addon)
	fixture.store.GetActiveRecord = function()
		return nil
	end
	addon.Database.SetCurrentRaid(nil)
	local createCalls = 0
	raid.Create = function(_, zone, size, difficulty)
		createCalls = createCalls + 1
		assertEqual("Ulduar", zone)
		assertEqual(25, size)
		assertEqual(2, difficulty)
		return true
	end

	local checked, reason = raid:Check("Ulduar", 2)

	assertEqual(true, checked, "fresh raid creation was not reported")
	assertEqual(nil, reason, "fresh raid creation did not preserve the Create result")
	assertEqual(1, createCalls, "fresh raid was not created exactly once")
	print("PASS raid_session_check_creates_when_archive_has_no_active_raid")
end

function cases.raid_session_check_propagates_create_rejection(addon)
	local fixture, raid = installRaidSessionCheckFixture(addon)
	fixture.store.GetActiveRecord = function()
		return nil
	end
	addon.Database.SetCurrentRaid(nil)
	local createCalls = 0
	raid.Create = function()
		createCalls = createCalls + 1
		return false, "INJECTED_CREATE_REJECTION"
	end

	local checked, reason = raid:Check("Ulduar", 2)

	assertEqual(false, checked, "rejected creation was reported as successful")
	assertEqual("INJECTED_CREATE_REJECTION", reason, "creation rejection reason was hidden")
	assertEqual(1, createCalls, "rejected creation was attempted more than once")
	print("PASS raid_session_check_propagates_create_rejection")
end

function cases.raid_session_create_failure_is_atomic(addon)
	for _, failure in ipairs({ "create_nil", "create_throw", "conclude_nil", "conclude_throw" }) do
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
		assertEqual(
			oldRevision,
			fixture.store:GetRaidSyncRevision(fixture.raids[1]),
			"old revision must remain unchanged"
		)
		assertEqual(2, #fixture.raids, "failed creation must not persist a partial raid")
		assertTrue(deepEqual(oldPlayers, fixture.realmPlayers), "failed creation must preserve realm metadata")
		if fixture.candidateRaidNid then
			assertEqual(
				nil,
				fixture.store:GetRaidIndexByNid(fixture.candidateRaidNid),
				"candidate nid must leave no index"
			)
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

function cases.raid_create_preserves_store_rejection_reason(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	local oldRevision = fixture.store:GetRaidSyncRevision(fixture.raids[1])
	local oldRaid = deepCopy(fixture.raids[1])
	local oldRuntime = deepCopy(addon.State.raid)
	local oldPlayers = deepCopy(fixture.realmPlayers)
	addon.Database.GetPlayerName = function()
		return "Tester"
	end
	fixture.store.CreateActiveRaid = function()
		return nil, "INJECTED_CREATE_REJECTION"
	end
	local created, reason = raid:Create("Naxxramas", 10, 1)
	assertEqual(false, created, "rejected raid creation must fail")
	assertEqual("INJECTED_CREATE_REJECTION", reason, "creation rejection reason was hidden")
	assertEqual(1, addon.Database.GetCurrentRaid(), "old raid must remain current")
	assertTrue(deepEqual(oldRaid, fixture.raids[1]), "old raid must remain open and unchanged")
	assertTrue(deepEqual(oldRuntime, addon.State.raid), "runtime raid state must remain unchanged")
	assertEqual(oldRevision, fixture.store:GetRaidSyncRevision(fixture.raids[1]), "old revision must remain unchanged")
	assertEqual(2, #fixture.raids, "failed creation must not persist a partial raid")
	assertTrue(deepEqual(oldPlayers, fixture.realmPlayers), "failed creation must preserve realm metadata")
	assertEqual(1, fixture.store:GetRaidIndexByNid(41), "first existing nid mapping must survive rollback")
	assertEqual(2, fixture.store:GetRaidIndexByNid(73), "second existing nid mapping must survive rollback")
	assertEqual(0, #fixture.events, "failed creation must publish no event")
	assertEqual(1, fixture.historyCaptures, "Create must capture history once")
	assertEqual(1, fixture.rosterCaptures, "Create must capture roster once")
	assertEqual(1, fixture.historyRestores, "failed Create must restore history once")
	assertEqual(1, fixture.rosterRestores, "failed Create must restore roster once")
	print("PASS raid_create_preserves_store_rejection_reason")
end

function cases.raid_end_rejection_preserves_active_runtime(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	local currentRaid = addon.Database.GetCurrentRaid()
	local lastBoss = { bossNid = 9 }
	addon.Database.GetLastBoss = function()
		return lastBoss
	end
	addon.Database.SetLastBoss = function(value)
		lastBoss = value
	end
	local runtimeBefore = deepCopy(addon.State.raid)
	local recordBefore = deepCopy(fixture.raids[currentRaid])
	local eventsBefore = #fixture.events
	fixture.store.GetRaidUid = function()
		return "active-fixture"
	end
	fixture.store.ConcludeActiveRaid = function()
		return nil, "INJECTED_CONCLUSION_FAILURE"
	end
	local ended, reason = raid:End()
	assertEqual(false, ended, "rejected conclusion must be terminal")
	assertEqual("INJECTED_CONCLUSION_FAILURE", reason, "conclusion failure reason differs")
	assertEqual(currentRaid, addon.Database.GetCurrentRaid(), "rejected conclusion cleared current raid")
	assertTrue(deepEqual(lastBoss, { bossNid = 9 }), "rejected conclusion cleared last boss")
	assertTrue(deepEqual(runtimeBefore, addon.State.raid), "rejected conclusion changed runtime raid state")
	assertTrue(deepEqual(recordBefore, fixture.raids[currentRaid]), "rejected conclusion changed canonical raid")
	assertEqual(eventsBefore, #fixture.events, "rejected conclusion published an event")
	print("PASS raid_end_rejection_preserves_active_runtime")
end

function cases.raid_session_replacement_preserves_event_order(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	addon.Database.GetPlayerName = function()
		return "Leader-Test Realm"
	end
	fixture.store.GetRaidUid = function(_, record)
		return record == fixture.raids[1] and "active-fixture" or nil
	end
	fixture.store.ConcludeActiveRaid = function(_, raidUid, endTime)
		assertEqual("active-fixture", raidUid, "replacement concluded the wrong raid")
		local record = fixture.raids[1]
		record.endTime = endTime
		for i = 1, #(record.attendance or {}) do
			local segments = record.attendance[i].segments or {}
			if segments[#segments] and not segments[#segments].endTime then
				segments[#segments].endTime = endTime
			end
		end
		return { eventType = "RAID_CONCLUDED" }, record
	end
	fixture.store.CreateActiveRaid = function(_, args)
		local record = {
			schemaVersion = 6,
			raidNid = 74,
			realm = args.realm,
			zone = args.zone,
			size = args.size,
			difficulty = args.difficulty,
			startTime = args.serverTime,
			players = deepCopy(args.players),
			bossKills = {},
			loot = {},
			attendance = {},
			nextPlayerNid = args.nextPlayerNid,
			nextBossNid = 1,
			nextLootNid = 1,
		}
		fixture.raids[3] = record
		fixture.order[#fixture.order + 1] = "insert"
		return record, 3, "replacement-fixture"
	end
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

function cases.raid_reentry_state_applies_resume_and_replace(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	fixture.store.GetRecord = function(_, raidUid)
		return raidUid == "active-fixture" and { status = "active", state = fixture.raids[1] } or nil
	end
	fixture.store.GetIndexByUid = function(_, raidUid)
		return raidUid == "active-fixture" and 1 or nil
	end
	fixture.store.GetRaidUid = function(_, state)
		if state == fixture.raids[1] then
			return "active-fixture"
		end
		if state == fixture.raids[3] then
			return "replacement-fixture"
		end
		return nil
	end
	fixture.store.GetActiveRecord = function()
		local current = addon.Database.GetCurrentRaid()
		return current and fixture.raids[current] and { status = "active", state = fixture.raids[current] } or nil
	end
	fixture.store.ConcludeActiveRaid = function(_, raidUid, endTime)
		assertEqual("active-fixture", raidUid, "replacement concluded the wrong recovered raid")
		fixture.raids[1].endTime = endTime
		return { eventType = "RAID_CONCLUDED" }, fixture.raids[1]
	end
	fixture.store.CreateActiveRaid = function(_, args)
		fixture.raids[3] = {
			schemaVersion = 6,
			raidNid = 74,
			realm = args.realm,
			zone = args.zone,
			size = args.size,
			difficulty = args.difficulty,
			startTime = args.serverTime,
			players = deepCopy(args.players),
			bossKills = {},
			loot = {},
			attendance = {},
			nextPlayerNid = args.nextPlayerNid,
			nextBossNid = 1,
			nextLootNid = 1,
		}
		return fixture.raids[3], 3, "replacement-fixture"
	end
	addon.Database.GetPlayerName = function()
		return "Leader-Test Realm"
	end

	addon.Database.SetCurrentRaid(nil)
	local before = deepCopy(fixture.raids[1])
	local resumed, resumedUid = raid:ApplyReentryDecision("active-fixture", "resume", {
		zone = fixture.raids[1].zone,
		size = fixture.raids[1].size,
		difficulty = fixture.raids[1].difficulty,
	})
	assertEqual(true, resumed)
	assertEqual("active-fixture", resumedUid)
	assertEqual(1, addon.Database.GetCurrentRaid())
	assertTrue(deepEqual(before, fixture.raids[1]), "resume mutated the persisted raid")

	addon.Database.SetCurrentRaid(nil)
	local mismatched, mismatchReason = raid:ApplyReentryDecision("active-fixture", "resume", {
		zone = "Ulduar",
		size = 25,
		difficulty = 2,
	})
	assertEqual(false, mismatched, "mismatched resume was accepted")
	assertEqual("RAID_CONTEXT_MISMATCH", mismatchReason)
	assertEqual(nil, addon.Database.GetCurrentRaid(), "mismatched resume reopened the raid")

	assertEqual(
		true,
		select(
			1,
			raid:ApplyReentryDecision("active-fixture", "replace", {
				zone = "Ulduar",
				size = 25,
				difficulty = 2,
			})
		)
	)
	assertEqual(3, addon.Database.GetCurrentRaid(), "replacement did not become current")
	assertEqual(1, fixture.historyCaptures, "replacement was not one atomic Create transaction")
	print("PASS raid_reentry_state_applies_resume_and_replace")
end

function cases.raid_reentry_create_defers_attendance_until_transition_finishes(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	addon.Events.Internal.RaidRosterDelta = "RaidRosterDelta"
	fixture.store.GetRecord = function(_, raidUid)
		return raidUid == "active-fixture" and { status = "active", state = fixture.raids[1] } or nil
	end
	fixture.store.GetIndexByUid = function(_, raidUid)
		return raidUid == "active-fixture" and 1 or nil
	end
	fixture.store.GetRaidUid = function(_, state)
		if state == fixture.raids[1] then
			return "active-fixture"
		end
		if state == fixture.raids[3] then
			return "replacement-fixture"
		end
		return nil
	end
	fixture.store.GetActiveRecord = function()
		local current = addon.Database.GetCurrentRaid()
		return current and fixture.raids[current] and { status = "active", state = fixture.raids[current] } or nil
	end
	fixture.store.ConcludeActiveRaid = function(_, raidUid, endTime)
		fixture.raids[1].endTime = endTime
		return { eventType = "RAID_CONCLUDED" }, fixture.raids[1]
	end
	fixture.store.CreateActiveRaid = function(_, args)
		fixture.raids[3] = {
			schemaVersion = 6,
			raidNid = 74,
			realm = args.realm,
			zone = args.zone,
			size = args.size,
			difficulty = args.difficulty,
			startTime = args.serverTime,
			players = deepCopy(args.players),
			bossKills = {},
			loot = {},
			attendance = {},
			nextPlayerNid = args.nextPlayerNid,
			nextBossNid = 1,
			nextLootNid = 1,
		}
		return fixture.raids[3], 3, "replacement-fixture"
	end
	addon.Database.GetPlayerName = function()
		return "Leader-Test Realm"
	end
	fixture.store.CommitAuthoritativeEvent = function(_, raidUid, eventType, payload)
		if raidUid == "replacement-fixture" and eventType == "ATTENDANCE_UPDATED" then
			fixture.attendanceCommits = (fixture.attendanceCommits or 0) + 1
			return { eventType = eventType, payload = payload }, fixture.raids[3]
		end
		return nil, "UNEXPECTED_EVENT"
	end
	addon.Database.EnsureRaidByIndex = function(index)
		return fixture.raids[index], index
	end
	_G.strlower = string.lower
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Attendance.lua")

	local started, _, deferredRaidId = raid:ApplyReentryDecision("active-fixture", "replace", {
		zone = "Ulduar",
		size = 25,
		difficulty = 2,
	})
	assertEqual(true, started)
	assertEqual(0, fixture.attendanceCommits or 0, "attendance seeded before transition publication")
	assertEqual(3, deferredRaidId, "replacement did not return its deferred RaidCreate id")
	assertEqual(true, raid:NotifyDeferredRaidCreate(deferredRaidId))
	assertEqual(2, fixture.attendanceCommits, "attendance did not seed after the deferred RaidCreate")
	print("PASS raid_reentry_create_defers_attendance_until_transition_finishes")
end

function cases.raid_state_resolves_roster_timers_after_toc_order_load(addon)
	local fixture, raid = installRaidCreationFixture(addon, nil)
	local fixtureSchedule = raid._ScheduleRosterRefreshInternal
	local savedPlayers = { ["Test Realm"] = fixture.realmPlayers }
	addon.Events.Internal.RaidRosterDelta = "RaidRosterDelta"
	addon.Database.SavedVariables.GetPlayers = function()
		return savedPlayers
	end
	addon.Timer = {
		BindMixin = function(target)
			fixture:InstallTimers(target)
		end,
	}
	addon.IsInGroup = function()
		return true
	end
	addon.Database.GetPlayerName = function()
		return "Alpha"
	end
	_G.UnitSex = function()
		return 2
	end

	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Roster.lua")
	assertTrue(
		raid._ScheduleRosterRefreshInternal ~= fixtureSchedule,
		"Roster must install the real scheduler after State"
	)
	raid.CheckPlayer = function()
		return true
	end
	raid:CheckInitialRaidState()
	local scheduled = raid.updateRosterHandle
	assertTrue(scheduled and scheduled.active, "State must resolve the roster scheduler after both files load")
	fixture.store.GetRaidUid = function()
		return "active-fixture"
	end
	fixture.store.ConcludeActiveRaid = function()
		return { eventType = "RAID_CONCLUDED" }
	end
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
		addon.Database.SavedVariables.GetPlayers = function()
			return savedPlayers
		end
		addon.Timer = {
			BindMixin = function(target)
				fixture:InstallTimers(target)
			end,
		}
		addon.IsInGroup = function()
			return true
		end
		addon.Database.GetPlayerName = function()
			return "Alpha"
		end
		_G.UnitSex = function()
			return 2
		end
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
					if switchThrows then
						error("switch failure")
					end
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
			assertEqual(
				nil,
				fixture.store:GetRaidIndexByNid(fixture.candidateRaidNid),
				"candidate nid must leave no index"
			)
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

function cases.bootstrap_raid_archive_quarantine_is_degraded_and_recovers(addon)
	local categories = {
		{
			code = "INVALID_RAID_ARCHIVE_TYPE",
			label = "invalid type",
			formatVersion = nil,
		},
		{
			code = "UNSUPPORTED_RAID_ARCHIVE_FORMAT",
			label = "unsupported format",
			formatVersion = 2,
		},
		{
			code = "CORRUPT_RAID_ARCHIVE",
			label = "corrupt format",
			formatVersion = 1,
		},
	}

	for i = 1, #categories do
		local scenario = categories[i]
		local fixtureAddon = newAddon()
		local frame = installInitStubs(fixtureAddon)
		local reservesLoadCount = 0
		local warningMessages = {}
		local debugMessages = {}
		local detail = "PRIVATE_ARCHIVE_PLAYER_DATA_" .. scenario.code
		local quarantined = true
		local validArchive = { formatVersion = 1, activeRaidUid = nil, order = {}, raids = {} }

		fixtureAddon.L = {}
		fixtureAddon.L.MsgRaidHistoryQuarantined = "quarantine %s: %s"
		fixtureAddon.L.StrRaidArchiveInvalidType = "invalid type"
		fixtureAddon.L.StrRaidArchiveUnsupportedFormat = "unsupported format"
		fixtureAddon.L.StrRaidArchiveCorrupt = "corrupt format"
		fixtureAddon.Services.Reserves = {
			Load = function()
				reservesLoadCount = reservesLoadCount + 1
			end,
		}
		fixtureAddon.Database.SavedVariables = {
			EnsureAll = function() end,
			NormalizeAfterLoad = function()
				if quarantined then
					return nil, scenario.code, detail
				end
				return validArchive
			end,
			GetRaidArchiveError = function()
				return quarantined and scenario.code or nil
			end,
			GetRaidArchiveFormatVersion = function()
				return quarantined and scenario.formatVersion or nil
			end,
		}

		loadAddonFile(fixtureAddon, "Raid Management Addon/Init.lua")
		fixtureAddon.warn = function(_, message)
			warningMessages[#warningMessages + 1] = message
		end
		fixtureAddon.debug = function(_, message)
			debugMessages[#debugMessages + 1] = message
		end
		fixtureAddon.RAID_ROSTER_UPDATE = function() end

		fixtureAddon:ADDON_LOADED("Raid Management Addon")

		assertEqual(true, fixtureAddon.State.initialized, scenario.code .. " blocked addon initialization")
		assertEqual(1, reservesLoadCount, scenario.code .. " blocked unrelated initialization")
		assertEqual(scenario.code, fixtureAddon.State.raidArchiveQuarantine.category, "quarantine category differs")
		assertEqual(scenario.formatVersion, fixtureAddon.State.raidArchiveQuarantine.formatVersion, "format metadata differs")
		assertEqual(1, #warningMessages, scenario.code .. " warning cardinality differs")
		assertEqual("quarantine " .. scenario.code .. ": " .. scenario.label, warningMessages[1], "warning differs")
		assertTrue(not string.find(warningMessages[1], detail, 1, true), "warning exposed validator or player data")
		assertEqual(1, #debugMessages, scenario.code .. " validator detail was not logged once")
		assertTrue(string.find(debugMessages[1], detail, 1, true) ~= nil, "debug log omitted validator detail")

		fixtureAddon.Database.SavedVariables.GetRaidArchiveError()
		fixtureAddon.Database.SavedVariables.GetRaidArchiveError()
		fixtureAddon:ADDON_LOADED("Raid Management Addon")
		assertEqual(1, #warningMessages, scenario.code .. " repeated the global warning")

		quarantined = false
		fixtureAddon.State.initialized = nil
		fixtureAddon:RegisterEvent("ADDON_LOADED")
		fixtureAddon:ADDON_LOADED("Raid Management Addon")
		assertEqual(true, fixtureAddon.State.initialized, scenario.code .. " recovery did not initialize")
		assertEqual(nil, fixtureAddon.State.raidArchiveQuarantine, scenario.code .. " recovery kept quarantine state")
		assertEqual(1, #warningMessages, scenario.code .. " recovery emitted another quarantine warning")
		assertEqual(2, reservesLoadCount, scenario.code .. " recovery skipped unrelated initialization")
		assertEqual(nil, frame.registered.ADDON_LOADED, scenario.code .. " recovery kept bootstrap event registered")
	end

	print("PASS bootstrap_raid_archive_quarantine_is_degraded_and_recovers")
end

function cases.bootstrap_success_commits_before_roster_refresh(addon)
	local frame = installInitStubs(addon)
	local order = {}
	local forwardedEvent
	addon.Bus.TriggerEvent = function(eventName)
		forwardedEvent = eventName
	end
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
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	addon.debug = function()
		order[#order + 1] = "debug"
	end
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
	assertEqual(true, frame.registered.PARTY_LOOT_METHOD_CHANGED, "loot-method change event was not registered")
	addon:PARTY_LOOT_METHOD_CHANGED()
	assertEqual("wow.PARTY_LOOT_METHOD_CHANGED", forwardedEvent, "loot-method change event was not forwarded")
	print("PASS bootstrap_success_commits_before_roster_refresh")
end

local function installRealRosterFixture(addon, fixture)
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
		return member.name,
			member.rank,
			member.subgroup,
			member.level,
			member.class,
			string.upper(member.class),
			nil,
			member.online
	end

	addon.Events = { Internal = { RaidRosterDelta = "RaidRosterDelta" } }
	addon.Diag = { D = { LogRaidLeftGroupEndSession = "left", LogRaidRosterUpdate = "%s %s" } }
	addon.L = { RaidZones = {} }
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Strings = {
		NormalizeName = function(name)
			return name
		end,
	}
	addon.Time = {
		GetCurrentTime = function()
			return fixture.now
		end,
	}
	addon.State = {}
	addon.IsInRaid = function()
		return fixture.inRaid
	end
	addon.IsInGroup = function()
		return fixture.inRaid
	end
	addon.Group = addon.Group or {}
	addon.Group.IterateUnits = function()
		return function()
			return nil
		end
	end
	addon.Services = {
		Raid = {
			_IsUnknownNameInternal = function(name)
				return name == nil
			end,
		},
		EnsureNamespace = function(name, child)
			addon.Services[name] = addon.Services[name] or {}
			if child then
				addon.Services[name][child] = addon.Services[name][child] or {}
			end
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			fixture:InstallTimers(target)
		end,
	}
	addon.Database.SavedVariables = {
		GetPlayers = function()
			return {}
		end,
	}
	addon.Database.GetCurrentRaid = function()
		return fixture.currentRaid
	end
	addon.Database.GetRealmName = function()
		return "Test Realm"
	end
	addon.Database.EnsureRaidByIndex = function(index)
		return fixture.raids[index]
	end
	local rosterRuntimeByRaid = setmetatable({}, { __mode = "k" })
	addon.Database.GetRaidStore = function()
		return {
			EnsureRaidRuntime = function(_, raid)
				local runtime = rosterRuntimeByRaid[raid] or { playersByName = {} }
				rosterRuntimeByRaid[raid] = runtime
				for i = 1, #(raid.players or {}) do
					runtime.playersByName[raid.players[i].name] = raid.players[i]
				end
				return runtime
			end,
			GetRaidUid = function()
				return "fixture-roster"
			end,
			CommitAuthoritativeEvent = function()
				return { sequence = 1 }
			end,
		}
	end
	addon.Bus.TriggerEvent = function(eventName, ...)
		fixture.events[#fixture.events + 1] = { name = eventName, args = { ... } }
	end

	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Roster.lua")
	local raid = addon.Services.Raid
	function raid:GetRecognizedInstanceContext()
		if fixture.recognizedContext == false then
			return nil
		end
		return fixture.recognizedContext or {
			zone = "Test Raid",
			instanceKey = "ulduar",
			difficulty = 2,
			size = 25,
		}
	end
	function raid:Check() end
	function raid:AddPlayer(player)
		local players = fixture.raids[fixture.currentRaid].players
		if not player.playerNid then
			player.playerNid = 100 + #players
		end
		local found = false
		for i = 1, #players do
			if players[i] == player then
				found = true
				break
			end
		end
		if not found then
			players[#players + 1] = player
		end
		return player
	end
	function raid:End(isAutomatic)
		fixture.endWasAutomatic = isAutomatic
		local current = fixture.currentRaid
		local record = fixture.raids[current]
		for i = 1, #(record.players or {}) do
			if not record.players[i].leave then
				record.players[i].leave = fixture.now
			end
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
	assertEqual(true, fixture.endWasAutomatic, "roster session end did not mark the conclusion automatic")
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
		StrRaidAttendance = "Attendance",
		MsgAttendanceRemoved = "Removed %d attendance record(s).",
		StrInspectQueued = "Queued",
		StrInspectPending = "Pending",
		StrInspectNotInspected = "Not inspected",
		MsgForceInspectMissingUnit = "Unit missing",
		MsgForceInspectOffline = "Player offline",
		MsgForceInspectOutOfRange = "Player out of range",
		MsgForceInspectCannotInspect = "Cannot inspect player",
		MsgForceInspectNotifyFailed = "Inspect request failed",
	}
	addon.Diag =
		{ W = { ErrLoggerUpdateRosterNotInRaid = "not raid", ErrLoggerUpdateRosterNotCurrent = "not current" } }
	addon.Controllers = {}
	addon.Database.GetCurrentRaid = function()
		return 1
	end
	addon.Database.GetRaids = function()
		return {}
	end
	addon.Database.GetRaidIndexByNid = function(raidNid)
		return tonumber(raidNid) == 42 and 2 or nil
	end
	addon.IsInRaid = function()
		return true
	end
	local warnMessage
	addon.warn = function(_, message)
		warnMessage = message
	end
	local infoMessage
	addon.info = function(_, message)
		infoMessage = message
	end
	local deleteRaidNid
	addon.Services.Attendance = {
		Store = {
			GetRaid = function(_, raidIndex)
				return fixture.raids[raidIndex]
			end,
		},
		View = {},
		Actions = {
			DeleteRaidAttendance = function(_, raidNid)
				deleteRaidNid = raidNid
				return 1
			end,
		},
		Export = {},
	}
	local forceResult = { true, "queued" }
	addon.Services.EquipInspect = {
		ForcePlayer = function()
			return unpack(forceResult)
		end,
	}
	raid.Projections = {}
	raid.LootBans = {}
	addon.Events = {
		Internal = {
			RaidCreate = "RaidCreate",
			RaidAttendanceChanged = "RaidAttendanceChanged",
			EquipInspectUpdated = "EquipInspectUpdated",
			EquipInspectCompleted = "EquipInspectCompleted",
			LoggerClearPlayerSelections = "LoggerClearPlayerSelections",
			LootBansChanged = "LootBansChanged",
		},
	}
	local registeredCallbacks = {}
	addon.Bus = {
		TriggerEvent = function() end,
		RegisterCallback = function(eventName, callback)
			registeredCallbacks[eventName] = callback
		end,
	}
	addon.Timer = { BindMixin = function() end }
	addon.Sort = {
		CompareNumbers = function()
			return false
		end,
		CompareValues = function()
			return false
		end,
	}
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
		"Title",
		"HeaderName",
		"HeaderJoin",
		"HeaderLeave",
		"HeaderIlvl",
		"HeaderSpec",
		"HeaderInspect",
		"AddBtn",
		"DeleteBtn",
		"ForceInspectBtn",
	}) do
		_G[listName .. suffix] = newWidget()
	end
	addon.UI = {
		ExportDialog = {},
		Rows = { SetLoggerRowIndex = noop, ApplyLoggerSkin = noop },
		Frames = {
			GetRef = noop,
			SetScriptSafely = function(widget, scriptName, callback)
				if widget == _G[listName .. "AddBtn"] and scriptName == "OnClick" then
					boundOnClick = callback
				end
				if widget == _G[listName .. "DeleteBtn"] and scriptName == "OnClick" then
					boundDeleteOnClick = callback
				end
				if widget == _G[listName .. "ForceInspectBtn"] and scriptName == "OnClick" then
					boundForceOnClick = callback
				end
			end,
			SetFrameTitle = noop,
			BindModuleFrame = noop,
			MakeFrameGetter = function()
				return function()
					return nil
				end
			end,
		},
		Tooltips = { ShowItem = noop, ShowLines = noop, Hide = noop, BindModel = noop },
		Primitives = { SetShown = noop },
		Lists = {
			CalculateColumnWidths = function()
				return {}
			end,
			GetContentWidth = function()
				return 240
			end,
			CalculateColumnBudget = function()
				return 240
			end,
			ApplyHeaderLayout = noop,
			ApplyRowWidths = noop,
			BindSortHeaders = noop,
			FormatCountTitle = function(baseText, count, contextText)
				local title = ("%s (%d)"):format(tostring(baseText or ""), tonumber(count) or 0)
				if contextText and contextText ~= "" then
					return ("%s - %s"):format(title, contextText)
				end
				return title
			end,
			SetLabel = function(frameName, suffix, text)
				local label = _G[frameName .. suffix]
				if label and label.SetText then
					label:SetText(text or "")
				end
			end,
			CreateController = function(cfg)
				controllerConfigs[#controllerConfigs + 1] = cfg
				return {
					Dirty = function()
						dirtyCount = dirtyCount + 1
					end,
					OnLoad = noop,
				}
			end,
			MakeIndexedRowName = function()
				return "Row"
			end,
			CreateRowRenderer = function(fn)
				return fn
			end,
			BindController = noop,
		},
	}
	_G.CreateFrame = function()
		return {}
	end
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
		{ "missing_unit", "Unit missing" },
		{ "offline", "Player offline" },
		{ "out_of_range", "Player out of range" },
		{ "cannot_inspect", "Cannot inspect player" },
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

local function installAttendanceShareFixture(addon)
	local noop = function() end
	local primitiveCalls = {}
	local callbacks = {}
	local lootBanned = false
	local forceInspectCalls = {}
	local itemTooltipCalls = {}
	local raid = {
		raidNid = 42,
		zone = "Icecrown Citadel",
		difficulty = 4,
		players = {},
	}

	local function newControl(name)
		return {
			name = name,
			width = 640,
			height = 22,
			text = "",
			shown = false,
			enabled = true,
			points = {},
			scripts = {},
			scriptSetCounts = {},
			GetName = function(self)
				return self.name
			end,
			SetText = function(self, value)
				self.text = tostring(value or "")
			end,
			GetText = function(self)
				return self.text
			end,
			SetScript = function(self, scriptName, callback)
				self.scripts[scriptName] = callback
				self.scriptSetCounts[scriptName] = (self.scriptSetCounts[scriptName] or 0) + 1
			end,
			GetScript = function(self, scriptName)
				return self.scripts[scriptName]
			end,
			SetWidth = function(self, width)
				self.width = width
			end,
			GetWidth = function(self)
				return self.width
			end,
			SetHeight = function(self, height)
				self.height = height
			end,
			GetHeight = function(self)
				return self.height
			end,
			SetSize = function(self, width, height)
				self.width = width
				self.height = height
			end,
			ClearAllPoints = function(self)
				self.points = {}
			end,
			SetPoint = function(self, ...)
				self.points[#self.points + 1] = { ... }
			end,
			SetAllPoints = function(self, relativeTo)
				self.allPoints = relativeTo
			end,
			Show = function(self)
				self.shown = true
			end,
			Hide = function(self)
				self.shown = false
			end,
			IsShown = function(self)
				return self.shown
			end,
			SetEnabled = function(self, enabled)
				self.enabled = enabled == true
			end,
			Enable = function(self)
				self.enabled = true
			end,
			Disable = function(self)
				self.enabled = false
			end,
			EnableMouse = function(self, enabled)
				self.mouseEnabled = enabled == true
			end,
			RegisterForClicks = function(self, ...)
				self.registeredClicks = { ... }
			end,
			SetID = function(self, id)
				self.id = id
			end,
			GetID = function(self)
				return self.id
			end,
			SetNormalTexture = function(self, texture)
				self.normalTexture = texture
			end,
			SetTexture = function(self, texture)
				self.texturePath = texture
			end,
			SetTexCoord = function(self, ...)
				self.texCoord = { ... }
			end,
			SetDesaturated = function(self, desaturated)
				self.desaturated = desaturated == true
			end,
			SetVertexColor = function(self, ...)
				self.vertexColor = { ... }
			end,
		}
	end

	local raidName = "RMARaidAttendanceRaids"
	local playerName = "RMARaidAttendanceRaidAttendees"
	local raidSuffixes = {
		"Title",
		"HeaderNum",
		"HeaderDate",
		"HeaderZone",
		"HeaderSize",
		"CurrentBtn",
		"DeleteBtn",
		"EmptyState",
		"ScrollFrame",
	}
	local playerSuffixes = {
		"Title",
		"HeaderName",
		"HeaderJoin",
		"HeaderLeave",
		"HeaderIlvl",
		"HeaderSpec",
		"HeaderInspect",
		"AddBtn",
		"DeleteBtn",
		"ForceInspectBtn",
		"ExportBtn",
		"EmptyState",
		"ScrollFrame",
	}
	_G[raidName] = newControl(raidName)
	_G[playerName] = newControl(playerName)
	for i = 1, #raidSuffixes do
		_G[raidName .. raidSuffixes[i]] = newControl(raidName .. raidSuffixes[i])
	end
	for i = 1, #playerSuffixes do
		_G[playerName .. playerSuffixes[i]] = newControl(playerName .. playerSuffixes[i])
	end

	addon.L = setmetatable({
		StrRaidsList = "Raids",
		StrRaidAttendees = "Raid Attendees",
		StrLoggerEmptyRaids = "No raids",
		StrLoggerEmptyRaidAttendeesSelectRaid = "Select a raid",
		StrLoggerEmptyRaidAttendees = "No attendees",
		StrInspectNotInspected = "Not inspected",
		StrLootBanTooltipTitle = "Loot banned",
	}, {
		__index = function(_, key)
			return key
		end,
	})
	addon.Diag = {
		A = setmetatable({}, {
			__index = function(_, key)
				return key
			end,
		}),
		W = setmetatable({}, {
			__index = function(_, key)
				return key
			end,
		}),
	}
	addon.Controllers = {}
	addon.Options = { IsDebugEnabled = function() return false end }
	addon.Database.GetCurrentRaid = function()
		return 1
	end
	addon.Database.GetRaids = function()
		return { raid }
	end
	addon.Database.GetRaidIndexByNid = function(raidNid)
		return tonumber(raidNid) == 42 and 1 or nil
	end
	addon.IsInRaid = function()
		return true
	end
	addon.info = noop
	addon.warn = noop
	addon.error = noop
	addon.Services = {
		Attendance = {
			Store = {
				GetRaid = function(_, raidIndex)
					return tonumber(raidIndex) == 1 and raid or nil
				end,
			},
			View = { FillRaidAttendeesList = noop },
			Actions = { DeleteRaidAttendance = function() return 0 end },
			Export = {},
		},
		EquipInspect = {
			ForcePlayer = function(_, raidIndex, playerNid)
				forceInspectCalls[#forceInspectCalls + 1] = { raidIndex, playerNid }
				return true, "queued"
			end,
		},
		Raid = {
			Projections = {
				FillRaidList = noop,
				GetDifficultyLabel = function()
					return "25 Heroic"
				end,
			},
			LootBans = {
				Get = function()
					return lootBanned, lootBanned and "Bench" or nil
				end,
			},
			RefreshAndPublish = noop,
		},
	}
	addon.Events = {
		Internal = {
			RaidCreate = "RaidCreate",
			RaidAttendanceChanged = "RaidAttendanceChanged",
			EquipInspectUpdated = "EquipInspectUpdated",
			EquipInspectCompleted = "EquipInspectCompleted",
			LoggerClearPlayerSelections = "LoggerClearPlayerSelections",
			LootBansChanged = "LootBansChanged",
		},
	}
	addon.Bus = {
		TriggerEvent = noop,
		RegisterCallback = function(eventName, callback)
			callbacks[eventName] = callback
		end,
	}
	addon.Timer = {
		BindMixin = function(owner)
			function owner:ScheduleTimer(callback)
				callback()
				return {}
			end
			function owner:CancelTimer()
				return true
			end
		end,
	}
	addon.Sort = {
		CompareNumbers = function(a, b, asc)
			return asc and a < b or a > b
		end,
		CompareValues = function(a, b, asc)
			return asc and a < b or a > b
		end,
	}
	addon.Colors = {
		GetClassColor = function()
			return 0.78, 0.61, 0.43
		end,
	}

	local controllers = {}
	addon.UI = {
		Rows = { SetLoggerRowIndex = noop, ApplyLoggerSkin = noop },
		Frames = {
			GetRef = function()
				return nil
			end,
			SetScriptSafely = function(control, scriptName, callback)
				control:SetScript(scriptName, callback)
				return true
			end,
			SetFrameTitle = noop,
			BindModuleFrame = noop,
			MakeFrameGetter = function()
				return function()
					return nil
				end
			end,
		},
		Tooltips = {
			ShowItem = function(...)
				itemTooltipCalls[#itemTooltipCalls + 1] = { ... }
			end,
			ShowLines = noop,
			Hide = noop,
			BindModel = function(control, model, anchor)
				control.tooltipModel = model
				control.tooltipAnchor = anchor
			end,
		},
		Primitives = {
			SetShown = function(control, shown)
				if control then
					control.shown = shown == true
				end
			end,
			SetEnabled = function(control, enabled)
				if control then
					control.enabled = enabled == true
				end
			end,
		},
		ExportDialog = {},
		Lists = {
			CreateController = function(config)
				local controller = { config = config, data = {}, sortedKeys = {} }
				function controller:Dirty() end
				function controller:Touch() end
				function controller:OnLoad() end
				function controller:Sort(key)
					self.sortedKeys[#self.sortedKeys + 1] = key
				end
				controllers[#controllers + 1] = controller
				return controller
			end,
			MakeIndexedRowName = function(suffix)
				return function(frameName, _, index)
					return tostring(frameName) .. tostring(suffix) .. tostring(index)
				end
			end,
			CreateRowRenderer = function(callback)
				return callback
			end,
			BindController = function(listModule, controller)
				listModule._ctrl = controller
				listModule.Sort = function(_, key)
					controller:Sort(key)
				end
			end,
		},
	}

	_G.CreateFrame = function(_, name)
		return newControl(name or "AttendanceDynamicControl")
	end

	local createController = addon.UI.Lists.CreateController
	local makeIndexedRowName = addon.UI.Lists.MakeIndexedRowName
	local createRowRenderer = addon.UI.Lists.CreateRowRenderer
	local bindController = addon.UI.Lists.BindController
	loadAddonFile(addon, "Raid Management Addon/Modules/UI/ListController.lua")
	addon.UI.Lists.CreateController = createController
	addon.UI.Lists.MakeIndexedRowName = makeIndexedRowName
	addon.UI.Lists.CreateRowRenderer = createRowRenderer
	addon.UI.Lists.BindController = bindController
	local sharedOperationNames = {
		"GetContentWidth",
		"CalculateColumnBudget",
		"ApplyHeaderLayout",
		"ApplyRowWidths",
		"BindSortHeaders",
		"FormatCountTitle",
		"SetLabel",
	}
	for i = 1, #sharedOperationNames do
		local operationName = sharedOperationNames[i]
		local operation = assert(addon.UI.Lists[operationName], operationName .. " is missing")
		primitiveCalls[operationName] = {}
		addon.UI.Lists[operationName] = function(...)
			local calls = primitiveCalls[operationName]
			calls[#calls + 1] = { ... }
			return operation(...)
		end
	end

	loadAddonFile(addon, "Raid Management Addon/Controllers/Attendance.lua")
	local raidController = addon.Controllers.Attendance.AttendanceRaids._ctrl
	local playerController = addon.Controllers.Attendance.AttendancePlayers._ctrl
	assertTrue(raidController ~= nil, "Attendance raid controller fixture did not bind")
	assertTrue(playerController ~= nil, "Attendance player controller fixture did not bind")
	raidController.config.localize(raidName)
	playerController.config.localize(playerName)

	return {
		controller = addon.Controllers.Attendance,
		raidController = raidController,
		playerController = playerController,
		raidName = raidName,
		playerName = playerName,
		raidFrame = _G[raidName],
		playerFrame = _G[playerName],
		raidScroll = _G[raidName .. "ScrollFrame"],
		playerScroll = _G[playerName .. "ScrollFrame"],
		primitiveCalls = primitiveCalls,
		newControl = newControl,
		forceInspectCalls = forceInspectCalls,
		itemTooltipCalls = itemTooltipCalls,
		setLootBanned = function(value)
			lootBanned = value == true
		end,
	}
end

function cases.attendance_lists_use_shared_layout_primitives_without_behavior_drift(addon)
	local fixture = installAttendanceShareFixture(addon)
	local attendance = fixture.controller
	local raidController = fixture.raidController
	local playerController = fixture.playerController
	local raidName = fixture.raidName
	local playerName = fixture.playerName

	local function assertHeader(name, width, offset, message)
		local header = _G[name]
		assertEqual(width, header.width, message .. " width")
		assertEqual("TOPLEFT", header.points[1][1], message .. " anchor")
		assertEqual(offset, header.points[1][4], message .. " offset")
		assertEqual(-25, header.points[1][5], message .. " top offset")
	end

	local function assertContiguousHeaders(headers, expectedEnd, message)
		for i = 2, #headers do
			assertEqual(
				headers[i - 1].points[1][4] + headers[i - 1].width,
				headers[i].points[1][4],
				message .. " header gap at " .. tostring(i)
			)
		end
		assertEqual(
			expectedEnd,
			headers[#headers].points[1][4] + headers[#headers].width,
			message .. " boundary"
		)
	end

	-- Localization runs twice while sort bindings remain one-time and controller-owned.
	raidController.config.localize(raidName)
	playerController.config.localize(playerName)
	assertEqual(1, _G[raidName .. "HeaderZone"].scriptSetCounts.OnClick, "raid sort header rebound")
	assertEqual(1, _G[playerName .. "HeaderSpec"].scriptSetCounts.OnClick, "Spec sort header rebound")
	assertEqual(nil, _G[playerName .. "HeaderInspect"].scriptSetCounts.OnClick, "Inspect became sortable")
	_G[raidName .. "HeaderZone"].scripts.OnClick()
	_G[playerName .. "HeaderSpec"].scripts.OnClick()
	assertEqual("zone", raidController.sortedKeys[1], "raid header dispatched the wrong sort key")
	assertEqual("spec", playerController.sortedKeys[1], "Spec header dispatched the wrong sort key")

	local raidHeaders = {
		_G[raidName .. "HeaderNum"],
		_G[raidName .. "HeaderDate"],
		_G[raidName .. "HeaderZone"],
		_G[raidName .. "HeaderSize"],
	}
	local playerHeaders = {
		_G[playerName .. "HeaderName"],
		_G[playerName .. "HeaderJoin"],
		_G[playerName .. "HeaderLeave"],
		_G[playerName .. "HeaderIlvl"],
		_G[playerName .. "HeaderSpec"],
		_G[playerName .. "HeaderInspect"],
	}
	assertHeader(raidName .. "HeaderNum", 30, 6, "raid number header")
	assertContiguousHeaders(raidHeaders, 643, "raid 619px budget")
	assertHeader(playerName .. "HeaderName", 74, 6, "attendance name header")
	assertHeader(playerName .. "HeaderJoin", 45, 80, "attendance join header")
	assertHeader(playerName .. "HeaderLeave", 45, 125, "attendance leave header")
	assertHeader(playerName .. "HeaderIlvl", 36, 170, "attendance ilvl header")
	assertHeader(playerName .. "HeaderSpec", 43, 206, "attendance Spec header")
	assertHeader(playerName .. "HeaderInspect", 394, 249, "attendance Inspect header")
	assertContiguousHeaders(playerHeaders, 643, "attendance 607px budget")

	local raidRow = fixture.newControl("AttendanceRaidRow1")
	raidRow._p = {
		ID = fixture.newControl("AttendanceRaidRow1ID"),
		Date = fixture.newControl("AttendanceRaidRow1Date"),
		Zone = fixture.newControl("AttendanceRaidRow1Zone"),
		Size = fixture.newControl("AttendanceRaidRow1Size"),
	}
	raidController.config.drawRow(raidRow, {
		seq = 3,
		dateFmt = "2026-08-16",
		zone = "Icecrown Citadel",
		size = 25,
	}, 1)
	assertEqual(24, raidRow._p.ID.width, "raid row id width drifted")
	assertEqual(raidHeaders[2].width - 6, raidRow._p.Date.width, "raid date row/header parity drifted")
	assertEqual(raidHeaders[3].width - 6, raidRow._p.Zone.width, "raid zone row/header parity drifted")
	assertEqual(raidHeaders[4].width, raidRow._p.Size.width, "raid size row/header parity drifted")
	assertEqual(
		619,
		raidRow._p.ID.width + raidRow._p.Date.width + raidRow._p.Zone.width + raidRow._p.Size.width,
		"raid row budget drifted"
	)

	local playerRow = fixture.newControl("AttendancePlayerRow1")
	playerRow._p = {
		Name = fixture.newControl("AttendancePlayerRow1Name"),
		Join = fixture.newControl("AttendancePlayerRow1Join"),
		Leave = fixture.newControl("AttendancePlayerRow1Leave"),
		Ilvl = fixture.newControl("AttendancePlayerRow1Ilvl"),
		Spec = fixture.newControl("AttendancePlayerRow1Spec"),
		InspectStatus = fixture.newControl("AttendancePlayerRow1InspectStatus"),
	}
	for _, suffix in ipairs({
		"SpecIcon",
		"SpecIconTexture",
		"SecondarySpecIcon",
		"SecondarySpecIconTexture",
		"InspectItemIcon1",
		"InspectItemIcon1Texture",
	}) do
		_G["AttendancePlayerRow1" .. suffix] = fixture.newControl("AttendancePlayerRow1" .. suffix)
	end
	local playerItem = {
		id = 21,
		playerNid = 21,
		name = "Alpha",
		class = "WARRIOR",
		joinFmt = "20:00",
		leaveFmt = "21:00",
		avgIlvlFmt = "245",
		inspect = {
			status = "ready",
			specIcon = "primary-spec",
			secondarySpecIcon = "secondary-spec",
			specName = "Arms",
			secondarySpecName = "Fury",
			items = { [1] = { itemLink = "|Hitem:1|h[Test]|h", texture = "helm-texture" } },
		},
	}
	playerController.config.drawRow(playerRow, playerItem, 1)
	assertEqual(68, playerRow._p.Name.width, "attendance name width drifted")
	assertEqual(39, playerRow._p.Join.width, "attendance join width drifted")
	assertEqual(39, playerRow._p.Leave.width, "attendance leave width drifted")
	assertEqual(30, playerRow._p.Ilvl.width, "attendance ilvl width drifted")
	assertEqual(37, playerRow._p.Spec.width, "attendance Spec width drifted")
	assertEqual(394, playerRow._p.InspectStatus.width, "attendance Inspect width drifted")
	assertEqual("primary-spec", _G.AttendancePlayerRow1SpecIconTexture.texturePath, "primary Spec texture drifted")
	assertEqual("secondary-spec", _G.AttendancePlayerRow1SecondarySpecIconTexture.texturePath, "secondary Spec texture drifted")
	assertEqual(true, _G.AttendancePlayerRow1SecondarySpecIconTexture.desaturated, "secondary Spec state drifted")
	assertEqual("Arms", _G.AttendancePlayerRow1SpecIcon.tooltipModel(_G.AttendancePlayerRow1SpecIcon).title, "Spec tooltip drifted")
	assertEqual("helm-texture", _G.AttendancePlayerRow1InspectItemIcon1Texture.texturePath, "Inspect texture drifted")
	assertEqual(1, _G.AttendancePlayerRow1InspectItemIcon1.points[1][4], "Inspect icon placement drifted")
	assertEqual("|Hitem:1|h[Test]|h", _G.AttendancePlayerRow1InspectItemIcon1._RMAItemLink, "Inspect link drifted")
	_G.AttendancePlayerRow1InspectItemIcon1.scripts.OnEnter(_G.AttendancePlayerRow1InspectItemIcon1)
	assertEqual(1, #fixture.itemTooltipCalls, "Inspect tooltip interaction drifted")

	-- Titles and already-selected empty-state strings remain Attendance-owned.
	raidController.data = {}
	playerController.data = {}
	attendance.attendanceSelectedRaid = nil
	raidController.config.postUpdate(raidName)
	playerController.config.postUpdate(playerName)
	assertEqual("Raids (0)", _G[raidName .. "Title"].text, "empty raid title drifted")
	assertEqual("No raids", _G[raidName .. "EmptyState"].text, "empty raid selection drifted")
	assertEqual("Raid Attendees (0)", _G[playerName .. "Title"].text, "absent context gained a fallback")
	assertEqual("Select a raid", _G[playerName .. "EmptyState"].text, "select-raid empty state drifted")

	attendance.attendanceSelectedRaid = 1
	attendance.attendanceSelectedPlayer = 21
	raidController.data = { {} }
	playerController.data = { {} }
	raidController.config.postUpdate(raidName)
	playerController.config.postUpdate(playerName)
	assertEqual("Raids (1)", _G[raidName .. "Title"].text, "populated raid title drifted")
	assertEqual(
		"Raid Attendees (1) - Icecrown Citadel 25 Heroic",
		_G[playerName .. "Title"].text,
		"Attendance context title drifted"
	)
	_G[playerName .. "ForceInspectBtn"].scripts.OnClick()
	assertEqual(1, #fixture.forceInspectCalls, "Force Inspect action moved or disappeared")
	assertEqual(1, fixture.forceInspectCalls[1][1], "Force Inspect used the wrong raid")
	assertEqual(21, fixture.forceInspectCalls[1][2], "Force Inspect used the wrong player")

	-- Invalid ScrollFrames and undersized frames preserve the 240 clamp and minima.
	fixture.raidScroll.width = 0
	fixture.playerScroll.width = 0
	fixture.raidFrame.width = 200
	fixture.playerFrame.width = 200
	raidController.data = {}
	playerController.data = {}
	raidController.config.postUpdate(raidName)
	playerController.config.postUpdate(playerName)
	raidController.config.drawRow(raidRow, {
		seq = 3,
		dateFmt = "2026-08-16",
		zone = "Icecrown Citadel",
		size = 25,
	}, 1)
	fixture.setLootBanned(true)
	playerController.config.drawRow(playerRow, playerItem, 1)
	assertHeader(raidName .. "HeaderNum", 30, 6, "fallback raid number header")
	assertHeader(raidName .. "HeaderDate", 94, 36, "fallback raid date header")
	assertHeader(raidName .. "HeaderZone", 134, 130, "fallback raid zone header")
	assertHeader(raidName .. "HeaderSize", 36, 264, "fallback raid size header")
	assertContiguousHeaders(raidHeaders, 300, "fallback raid minimum budget")
	assertHeader(playerName .. "HeaderName", 74, 6, "fallback attendance name header")
	assertHeader(playerName .. "HeaderInspect", 324, 249, "fallback attendance Inspect header")
	assertContiguousHeaders(playerHeaders, 573, "fallback attendance minimum budget")
	assertEqual(51, playerRow._p.Name.width, "loot-ban name inset moved into shared row geometry")
	assertEqual(20, playerRow._p.Name.points[1][4], "loot-ban name anchor drifted")
	assertEqual(true, playerRow._RMALootBanIcon.shown, "loot-ban icon ownership drifted")
	assertEqual("No attendees", _G[playerName .. "EmptyState"].text, "selected-raid empty state drifted")

	-- RED reaches this point with all Attendance-owned behavior intact, then fails
	-- only while the controller still bypasses the seven shared operations.
	assertEqual(14, #fixture.primitiveCalls.GetContentWidth, "Attendance did not route content width through UI.Lists")
	assertEqual(14, #fixture.primitiveCalls.CalculateColumnBudget, "Attendance did not route budgets through UI.Lists")
	assertEqual(10, #fixture.primitiveCalls.ApplyHeaderLayout, "Attendance did not route header geometry through UI.Lists")
	assertEqual(4, #fixture.primitiveCalls.ApplyRowWidths, "Attendance did not route row widths through UI.Lists")
	assertEqual(4, #fixture.primitiveCalls.BindSortHeaders, "Attendance did not route initial sort binding through UI.Lists")
	assertEqual(6, #fixture.primitiveCalls.FormatCountTitle, "Attendance did not route titles through UI.Lists")
	assertEqual(16, #fixture.primitiveCalls.SetLabel, "Attendance did not route title and empty labels through UI.Lists")

	print("PASS attendance_lists_use_shared_layout_primitives_without_behavior_drift")
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
	callback(
		nil,
		{ timestamp = 1001, joined = { { playerNid = 21, subgroup = 1, online = true } }, reason = "join" },
		nil,
		2
	)
	callback(
		nil,
		{ timestamp = 1002, updated = { { playerNid = 21, subgroup = 1, online = true, rank = 1 } }, reason = "rank" },
		nil,
		2
	)
	assertEqual(1, #record.attendance[1].segments, "duplicate join and rank-only update must reuse the segment")
	fixture:AssertRevision(42, 1, "duplicate and rank-only deltas must preserve revision")
	assertEqual(0, #fixture.events, "duplicate and rank-only deltas must emit nothing")

	callback(
		nil,
		{ timestamp = 1003, updated = { { playerNid = 21, subgroup = 2, online = true } }, reason = "subgroup" },
		nil,
		2
	)
	assertEqual(2, #record.attendance[1].segments, "subgroup transition must close and open exactly once")
	assertEqual(1003, record.attendance[1].segments[1].endTime, "subgroup transition must close prior segment")
	fixture:AssertRevision(42, 2, "subgroup transition must touch revision once")
	fixture:AssertEvent(1, "RaidAttendanceChanged", 42, "subgroup")

	callback(
		nil,
		{ timestamp = 1004, updated = { { playerNid = 21, subgroup = 2, online = false } }, reason = "offline" },
		nil,
		2
	)
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

function cases.attendance_semantic_store_failure_is_atomic(addon)
	local fixture = newRaidRecordingFixture(addon)
	local raid = installRealAttendanceFixture(addon, fixture)
	local record = fixture.raids[2]
	local before = deepCopy(record)
	local commitCalls = 0
	fixture.store.CommitAuthoritativeEvent = function()
		commitCalls = commitCalls + 1
		return nil, "INJECTED_STORE_FAILURE"
	end
	assertEqual(false, raid:SeedAttendanceFromCurrentRoster(2, "seed"), "failed attendance commit must reject")
	assertEqual(1, commitCalls, "attendance owner must reach semantic store")
	assertTrue(deepEqual(before, record), "failed attendance commit mutated canonical raid")
	assertEqual(0, #fixture.events, "failed attendance commit published an event")
	print("PASS attendance_semantic_store_failure_is_atomic")
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
			if child then
				addon.Services[name][child] = addon.Services[name][child] or {}
			end
		end,
		Attendance = {
			Store = {
				GetRaid = function(_, raidIndex)
					return fixture.raids[raidIndex]
				end,
				InvalidateRaidIndexes = function() end,
			},
		},
	}
	addon.Database.EnsureRaidSchema = function(value)
		return value
	end
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
		ErrCannotSetCurrentNotInRaid = "not raid",
		ErrCannotSetCurrentNotInInstance = "not instance",
		ErrCannotSetCurrentZoneMismatch = "zone",
		ErrCannotSetCurrentRaidDifficulty = "difficulty",
		ErrCannotSetCurrentRaidSize = "size",
		ErrCannotSetCurrentRaidReset = "reset",
	}
	addon.Diag = {}
	addon.Strings = {}
	addon.Base64 = {}
	addon.LootSourceCandidates = {}
	addon.Time = {
		GetCurrentTime = function()
			return 1000
		end,
	}
	addon.Events = { Internal = { LoggerLootChanged = "LoggerLootChanged", LoggerDataChanged = "LoggerDataChanged" } }
	addon.Bus = { TriggerEvent = function() end }
	addon.Timer = { BindMixin = function() end }
	raid.GetRaidSize = function()
		return 10
	end
	raid.IsRaidLeader = function()
		return true
	end
	raid.IsRaidExpired = function()
		return false
	end
	addon.Database.EnsureRaidByIndex = function(index)
		if index == 1 then
			return fixture.raids[1]
		end
	end
	addon.Database.SetCurrentRaid = function(index)
		fixture.currentRaid = index
	end
	addon.Database.SetLastBoss = function() end
	addon.IsInRaid = function()
		return true
	end
	addon.error = function(_, message)
		fail(message)
	end
	addon.info = function() end
	_G.GetInstanceInfo = function()
		return "Ulduar", "raid", 2, nil, nil, 0, false
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Logger/Actions.lua")
	local result = addon.Services.Logger.Actions:SetCurrentRaid(1)
	assertEqual(true, result, "Logger should select a compatible raid")
	assertEqual(1, fixture.currentRaid, "Logger should set current raid before refresh")
	assertEqual(1, #fixture.events, "Logger mutation must publish exactly once through roster owner")
	assertEqual(1, raid:GetRosterVersion(), "Logger mutation must advance roster version once")
	print("PASS real_logger_set_current_raid_calls_roster_owner")
end

function cases.real_logger_set_current_raid_rejects_non_leader(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = nil
	fixture.inRaid = true
	fixture.raids[1].zone = "Ulduar"
	fixture.raids[1].difficulty = 2
	fixture.raids[1].size = 10
	fixture.raids[1].players = {}
	fixture.roster = { { name = "Alpha", rank = 2, subgroup = 1, level = 80, class = "Warrior", online = true } }
	local raid = installRealRosterFixture(addon, fixture)
	local errors = {}
	addon.L = {
		RaidZones = {},
		LogRaidSetCurrent = "%s %s %s",
		ErrCannotSetCurrentNotRaidLeader = "not raid leader",
		ErrCannotSetCurrentNotInRaid = "not raid",
		ErrCannotSetCurrentNotInInstance = "not instance",
		ErrCannotSetCurrentZoneMismatch = "zone",
		ErrCannotSetCurrentRaidDifficulty = "difficulty",
		ErrCannotSetCurrentRaidSize = "size",
		ErrCannotSetCurrentRaidReset = "reset",
	}
	addon.Diag = {}
	addon.Strings = {}
	addon.Base64 = {}
	addon.LootSourceCandidates = {}
	addon.Time = {
		GetCurrentTime = function()
			return 1000
		end,
	}
	addon.Events = { Internal = { LoggerLootChanged = "LoggerLootChanged", LoggerDataChanged = "LoggerDataChanged" } }
	addon.Bus = { TriggerEvent = function() end }
	addon.Timer = { BindMixin = function() end }
	raid.GetRaidSize = function()
		return 10
	end
	raid.IsRaidLeader = function()
		return false
	end
	raid.IsRaidExpired = function()
		return false
	end
	addon.Database.EnsureRaidByIndex = function(index)
		if index == 1 then
			return fixture.raids[1]
		end
	end
	addon.Database.SetCurrentRaid = function(index)
		fixture.currentRaid = index
	end
	addon.Database.SetLastBoss = function() end
	addon.IsInRaid = function()
		return true
	end
	addon.error = function(_, message)
		errors[#errors + 1] = message
	end
	addon.info = function() end
	_G.GetInstanceInfo = function()
		return "Ulduar", "raid", 2, nil, nil, 0, false
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Logger/Actions.lua")
	local result = addon.Services.Logger.Actions:SetCurrentRaid(1)
	assertEqual(false, result, "non-leader selected a compatible raid as current")
	assertEqual(nil, fixture.currentRaid, "non-leader action changed current raid")
	assertEqual(0, #fixture.events, "non-leader action refreshed roster")
	assertEqual(addon.L.ErrCannotSetCurrentNotRaidLeader, errors[1], "non-leader rejection feedback differs")
	print("PASS real_logger_set_current_raid_rejects_non_leader")
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
	assertEqual(2, #fixture.events, "debounced dispatcher must publish roster delta and forwarded update once")
	assertEqual(addon.Events.Internal.RaidRosterDelta, fixture.events[1].name, "dispatcher delta event differs")
	assertEqual(addon.Events.Wow.RaidRosterUpdate, fixture.events[2].name, "dispatcher forwarded event differs")
	assertEqual(1, raid:GetRosterVersion(), "dispatcher mutation must advance roster version once")

	fixture.roster[2] = { name = "Beta", rank = 0, subgroup = 1, level = 80, class = "Priest", online = true }
	raid._ScheduleRosterRefreshInternal()
	raid._ScheduleRosterRefreshInternal()
	fixture:AdvanceTime(2)
	assertEqual(3, #fixture.events, "superseded roster callback must be cancelled")
	assertEqual(addon.Events.Internal.RaidRosterDelta, fixture.events[3].name, "scheduled delta event differs")
	assertEqual(2, raid:GetRosterVersion(), "scheduled mutation must advance roster version once")

	raid:RefreshAndPublish()
	assertEqual(3, #fixture.events, "direct real roster no-op must not publish")
	addon:RAID_ROSTER_UPDATE(true)
	assertEqual(4, #fixture.events, "dispatcher no-op must forward raid roster update")
	fixture:AssertEvent(4, addon.Events.Wow.RaidRosterUpdate)
	print("PASS real_roster_dispatch_and_scheduled_paths_publish_once")
end

local function installLoggerCleanupFixture(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = 2
	fixture.raids[1].players = {}
	fixture.raids[1].loot = {
		{ lootNid = 1, itemId = 100, itemLink = "item:100", itemRarity = 3 },
		{ lootNid = 2, itemId = 200, itemLink = "item:200", itemRarity = 4 },
	}
	fixture.raids[1].nextLootNid = 3
	fixture.raids[2].bossKills = { { bossNid = 1, name = "Flame Leviathan" } }
	fixture.raids[2].loot = {
		{ lootNid = 1, itemRarity = 3 },
		{ lootNid = 2, itemRarity = 4 },
		{ lootNid = 3, itemRarity = 2 },
	}
	addon.DB = {}
	addon.State = { raidStore = {} }
	addon.Database = addon.Database or {}
	addon.Database.IsBossFightRecord = function()
		return true
	end
	addon.Database.GetRaidSchemaVersion = function()
		return 6
	end
	addon.Database.GetCurrentRaid = function()
		return fixture.currentRaid
	end
	addon.Database.SetCurrentRaid = function(value)
		fixture.currentRaid = value
	end
	addon.Database.SetLastBoss = function(value)
		fixture.lastBoss = value
	end
	addon.Time = {
		GetCurrentTime = function()
			return fixture.now
		end,
	}
	installCanonicalRaidStoreFixture(addon, fixture, 73)
	function fixture.store:GetRaidSyncRevision(raid)
		local runtime = raid and self:EnsureRaidRuntime(raid)
		return tonumber(runtime and runtime.syncRevision) or 0
	end
	function fixture.store:SetRaidSyncRevision(raid, sequence)
		local runtime = self:EnsureRaidRuntime(raid)
		runtime.syncRevision = tonumber(sequence) or 0
		return runtime.syncRevision
	end
	function fixture.store:TouchRaidSyncRevision(raid)
		return self:SetRaidSyncRevision(raid, self:GetRaidSyncRevision(raid) + 1)
	end
	function fixture.store:MarkLootSyncRevision(raid, loot)
		local sequence = self:TouchRaidSyncRevision(raid)
		loot.syncRevision = sequence
		return sequence
	end
	function fixture.store:GetLootSyncRevision(_, loot)
		return tonumber(loot and loot.syncRevision) or 0
	end
	function fixture.store:SetLootSyncRevision(_, loot, sequence)
		loot.syncRevision = tonumber(sequence) or 0
		return loot.syncRevision
	end
	function fixture.store:RequiresFullSyncSince(raid, sequence)
		return self:GetRaidSyncRevision(raid) > (tonumber(sequence) or 0)
	end
	fixture.store:GetAllRaids()
	fixture.store:SetRaidSyncRevision(fixture:GetRaid(2), 8)
	addon.L = {}
	addon.Diag = {}
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
		NormalizeLower = string.lower,
	}
	addon.Base64 = {}
	addon.LootSourceCandidates = {}
	addon.LootSources = {}
	addon.LootSourcesData = {}
	addon.Services = {
		EnsureNamespace = function(name, child)
			addon.Services[name] = addon.Services[name] or {}
			if child then
				addon.Services[name][child] = addon.Services[name][child] or {}
			end
		end,
		Logger = { Store = {}, Helpers = {} },
	}
	addon.Timer = {
		BindMixin = function(target)
			fixture:InstallTimers(target)
		end,
	}
	addon.Events = { Internal = { LoggerLootChanged = "LoggerLootChanged", LoggerDataChanged = "LoggerDataChanged" } }
	addon.Bus = {
		TriggerEvent = function(eventName, payload)
			fixture.events[#fixture.events + 1] = { name = eventName, args = { payload } }
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Logger/Actions.lua")
	return fixture, addon.Services.Logger.Actions
end

function cases.logger_cleanup_is_store_owned_and_revision_coherent(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local result = actions:CleanupRaidHistory({ emptyRaids = true, nonEpicLoot = true })
	assertEqual(true, result.changed, "cleanup should report canonical mutation: " .. tostring(result.error))
	assertEqual(true, result.complete, "synchronous cleanup should complete")
	assertEqual(0, result.raidsRemoved, "historical raid with loot must survive")
	assertEqual(1, result.lootRemoved, "historical non-epic loot should be removed")
	assertEqual(2, #fixture.raids, "both canonical raids should survive")
	assertEqual(41, fixture.raids[1].raidNid, "historical raid identity should remain stable")
	assertEqual(1, #fixture.raids[1].loot, "historical epic loot should remain")
	assertEqual(4, fixture.raids[1].loot[1].itemRarity, "historical epic loot differs")
	assertEqual(2, fixture.currentRaid, "active selection should remain stable")
	assertEqual(73, fixture.raids[2].raidNid, "active raid identity should remain stable")
	assertEqual(3, #fixture.raids[2].loot, "cleanup must preserve active-raid loot")
	assertEqual(1, #fixture.events, "cleanup should publish once")
	print("PASS logger_cleanup_is_store_owned_and_revision_coherent")
end

local function installLoggerAtomicFixture(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local raid = fixture.raids[2]
	raid.players = { { playerNid = 21, name = "Beta", countMS = 0 } }
	raid.bossKills = {}
	raid.loot = { { lootNid = 7, itemId = 45038, itemLink = "[Fragment]" } }
	raid.nextPlayerNid = 22
	raid.nextBossNid = 4
	raid.nextLootNid = 8
	fixture:RefreshRaidRecord(raid)
	fixture.store:EnsureRaidRuntime(raid)
	addon.Base64.Encode = function(value)
		return value
	end
	addon.LootSourceCandidates.Copy = function(value)
		return deepCopy(value)
	end
	addon.LootSources.FindSource = function(itemId)
		if itemId == 45038 then
			return { kind = "boss", npcId = 33113, npcName = "Flame Leviathan", sourceKey = "ulduar:33113" }
		end
		return nil
	end
	addon.LootSourcesData.ActivateInstance = function()
		return true
	end
	addon.LootSourcesData.GetActiveInstanceKey = function()
		return "ulduar"
	end
	local queries = {}
	function queries:FindBossByNid(target, nid)
		for i = 1, #(target.bossKills or {}) do
			if tonumber(target.bossKills[i].bossNid) == tonumber(nid) then
				return target.bossKills[i]
			end
		end
	end
	function queries:FindBossByName(target, name)
		for i = 1, #(target.bossKills or {}) do
			if target.bossKills[i].name == name then
				return target.bossKills[i]
			end
		end
	end
	function queries:FindBossBySourceNpcId(target, npcId)
		for i = 1, #(target.bossKills or {}) do
			if tonumber(target.bossKills[i].sourceNpcId) == tonumber(npcId) then
				return target.bossKills[i]
			end
		end
	end
	function queries:FindBossBySourceKey(target, sourceKey)
		for i = 1, #(target.bossKills or {}) do
			if target.bossKills[i].sourceKey == sourceKey then
				return target.bossKills[i]
			end
		end
	end
	addon.Database.GetRaidQueries = function()
		return queries
	end
	addon.Database.EnsureRaidSchema = function(target)
		return fixture.store:NormalizeRaidRecord(target)
	end
	addon.Database.GetLastBoss = function()
		return nil
	end
	addon.Services.Logger.Store.GetRaid = function(_, raidIndex)
		return fixture.raids[raidIndex]
	end
	addon.Services.Logger.Store.GetLoot = function(_, target, lootNid)
		for i = 1, #(target.loot or {}) do
			if tonumber(target.loot[i].lootNid) == tonumber(lootNid) then
				return target.loot[i]
			end
		end
	end
	addon.Services.Logger.Store._ResolveLootLooterNid = function(_, name)
		return name == "Beta" and 21 or nil
	end
	addon.Services.Logger.Store._ResolveLootLooterName = function(_, loot)
		return tonumber(loot.looterNid) == 21 and "Beta" or nil
	end
	addon.Services.Logger.Helpers.NormalizeRollType = function(value)
		return value
	end
	addon.Services.Logger.Helpers.NormalizeRollValue = function(value)
		return tonumber(value)
	end
	return fixture, actions, raid
end

local function prepareCompletedRebuildRaid(fixture)
	local raid = fixture.raids[1]
	raid.players = { { playerNid = 21, name = "Beta", countMS = 0 } }
	raid.bossKills = {}
	raid.loot = { { lootNid = 7, itemId = 45038, itemLink = "[Fragment]" } }
	raid.nextPlayerNid = 22
	raid.nextBossNid = 4
	raid.nextLootNid = 8
	fixture:RefreshRaidRecord(raid)
	fixture.store:EnsureRaidRuntime(raid)
	return raid
end

function cases.logger_source_rebuild_is_atomic_and_revisioned(addon)
	local fixture, actions = installLoggerAtomicFixture(addon)
	local raid = prepareCompletedRebuildRaid(fixture)
	local result = actions:RebuildLootSources()
	raid = fixture:GetRaid(1)
	assertEqual(1, result.repaired, "resolved source should be rebuilt")
	assertEqual(1, result.bossesCreated, "static source should create one boss")
	assertEqual(4, raid.bossKills[1].bossNid, "allocated boss nid must stay stable")
	assertEqual(4, raid.loot[1].bossNid, "loot patch must reference committed boss")
	local unchanged = deepCopy(raid)
	local second = actions:RebuildLootSources()
	raid = fixture:GetRaid(1)
	assertEqual(0, second.repaired, "already rebuilt source is a no-op")
	assertTrue(deepEqual(unchanged, raid), "no-op rebuild preserves canonical raid deeply")
	raid.loot[2] = { lootNid = 8, itemId = 99999 }
	fixture.store:EnsureRaidRuntime(raid)
	local beforeUnresolved = deepCopy(raid)
	local unresolved = actions:RebuildLootSources()
	assertEqual(1, unresolved.unresolved, "missing source should remain unresolved")
	assertTrue(deepEqual(beforeUnresolved, raid), "unresolved rebuild preserves canonical state")
	print("PASS logger_source_rebuild_is_atomic_and_revisioned")
end

function cases.logger_source_rebuild_skips_active_record(addon)
	local fixture, actions, activeRaid = installLoggerAtomicFixture(addon)
	local completedRaid = fixture.raids[1]
	completedRaid.players = { { playerNid = 11, name = "Alpha" } }
	completedRaid.bossKills = {}
	completedRaid.loot = { { lootNid = 3, itemId = 45038, itemLink = "[Fragment]" } }
	completedRaid.nextBossNid = 2
	fixture:RefreshRaidRecord(completedRaid)
	fixture.store:EnsureRaidRuntime(completedRaid)
	fixture.currentRaid = 1
	assertTrue(fixture.store:GetActiveRecord().state == activeRaid, "fixture canonical active record differs")
	local activeBefore = deepCopy(activeRaid)
	local result = actions:RebuildLootSources()
	completedRaid = fixture:GetRaid(1)
	assertEqual(1, result.repaired, "completed history must still rebuild")
	assertEqual(1, result.bossesCreated, "completed history must create its static source boss")
	assertTrue(deepEqual(activeBefore, activeRaid), "active record must be excluded from rebuild")
	assertEqual(2, completedRaid.loot[1].bossNid, "completed loot must reference rebuilt source")
	print("PASS logger_source_rebuild_skips_active_record")
end

function cases.logger_record_loot_verification_failure_is_atomic(addon)
	local fixture, actions = installLoggerAtomicFixture(addon)
	local raid = prepareCompletedRebuildRaid(fixture)
	local before = deepCopy(raid)
	local originalCommit = fixture.store.CommitRaidHistoryMutation
	fixture.store.CommitRaidHistoryMutation = function(self, target, staged, opts, verify)
		return originalCommit(self, target, staged, opts, function()
			return false, "INJECTED_VERIFY_FAILURE"
		end)
	end
	local ok, reason = actions:RecordLoot({ raidId = 1, lootNid = 7, looter = "Beta", rollType = "MS", rollValue = 97 })
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
	fixture:RefreshRaidRecord(fixture.raids[2])
	local result = actions:CleanupRaidHistory({ emptyRaids = true, noBossEncounter = true })
	assertEqual(true, result.complete, "cleanup must complete while protecting active raid")
	assertEqual(1, result.raidsRemoved, "historical empty raid must be removed")
	assertEqual(73, fixture.raids[1].raidNid, "active empty raid must survive")
	assertEqual(1, fixture.currentRaid, "active selection must follow surviving stable identity")

	fixture, actions = installLoggerCleanupFixture(addon)
	fixture.raids[2].bossKills = {}
	fixture.raids[2].players = { { playerNid = 21, name = "Beta" } }
	fixture:RefreshRaidRecord(fixture.raids[2])
	result = actions:CleanupRaidHistory({ noBossEncounter = true })
	assertEqual(73, fixture.raids[#fixture.raids].raidNid, "active no-boss raid with players must survive")
	print("PASS logger_cleanup_preserves_active_raid")
end

function cases.logger_async_cleanup_conflicts_when_candidate_becomes_current(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local originalCommit = fixture.store.CommitRaidHistoryCleanup
	fixture.store.CommitRaidHistoryCleanup = function(store, plan, currentRaidNid)
		fixture.currentRaid = 1
		return originalCommit(store, plan, fixture.archiveKeyByRaidNid[fixture.raids[fixture.currentRaid].raidNid])
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

local function importCollidingHistoryRows(store, events)
	local activeState, _, activeUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		raidNid = 41,
		zone = "Active",
		serverTime = 1721120000,
	}))
	local completedState = deepCopy(activeState)
	completedState.zone = "History A"
	completedState.startTime = 1721110000
	completedState.endTime = 1721111000
	local function snapshot(uid, zone)
		local state = deepCopy(completedState)
		state.zone = zone
		return {
			raidUid = uid,
			status = "complete",
			authorityEpoch = 1,
			sequence = 1,
			digest = assert(events.DigestState(state)),
			checkpointSequence = 1,
			state = state,
			events = {},
		}
	end
	assertEqual("IMPORTED", store:ImportHistoricalSnapshot(snapshot("history-source-a", "History A")))
	assertEqual("IMPORTED", store:ImportHistoricalSnapshot(snapshot("history-source-b", "History B")))
	assertEqual("CONFLICT", store:ImportHistoricalSnapshot(snapshot("history-source-a", "History A divergent")))
	return activeUid
end

function cases.raid_archive_row_identity_collision(addon)
	local store = installRaidArchiveFixture(addon)
	local activeUid = importCollidingHistoryRows(store, addon.DB.RaidEvents)
	local archive = store:EnsureArchive()
	assertEqual(4, #archive.order, "fixture must expose active, two sources, and one variant")
	assertEqual(activeUid, store:GetArchiveKeyByIndex(1), "active archive key differs")
	for i = 1, #archive.order do
		local key = assert(store:GetArchiveKeyByIndex(i))
		assertEqual(i, store:GetIndexByArchiveKey(key), "archive row identity did not round-trip")
	end
	local active, activeIndex = store:EnsureRaidByNid(41)
	assertEqual(1, activeIndex, "colliding history replaced active raidNid lookup")
	assertEqual("Active", active.zone, "colliding history replaced active state")
	addon.Services.EnsureNamespace = function(name, child)
		addon.Services[name] = addon.Services[name] or {}
		if child then
			addon.Services[name][child] = addon.Services[name][child] or {}
		end
	end
	table.wipe = table.wipe or function(target)
		for key in pairs(target) do
			target[key] = nil
		end
	end
	_G.date = _G.date or function()
		return "date"
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidQueries.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Projections.lua")
	local rows = {}
	addon.Services.Raid.Projections.FillRaidList(rows)
	for i = 1, #rows do
		assertEqual(i, rows[i].id, "history row button id must be archive index")
	end
	local secondHistoryKey = store:GetArchiveKeyByIndex(3)
	local secondSnapshot = assert(store:BuildSnapshot(secondHistoryKey))
	assertEqual("history-source-b", secondSnapshot.raidUid, "share resolved the wrong source row")
	assertEqual("History B", secondSnapshot.state.zone, "share resolved the wrong row state")
	local secondRaid = assert(store:EnsureRaidByIndex(3))
	local metadata = addon.Services.Raid.Projections.BuildExportMetadata(secondRaid)
	assertEqual(41, metadata.raidNid, "export did not use the clicked row")
	assertEqual(true, store:DeleteRaidByArchiveKey(secondHistoryKey), "exact history delete failed")
	assertEqual(nil, store:GetRecord(secondHistoryKey), "exact deleted row survived")
	assertEqual("Active", store:GetRecord(activeUid).state.zone, "exact history delete changed active row")
	assert(store:ConcludeActiveRaid(activeUid, 1721120200))
	assertEqual(nil, store:EnsureRaidByNid(41), "ambiguous non-active raidNid lookup must fail closed")
	print("PASS raid_archive_row_identity_collision")
end

function cases.raid_archive_legacy_nid_delete_is_fail_closed(addon)
	local store = installRaidArchiveFixture(addon)
	local activeState, _, activeUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		raidNid = 41,
		zone = "Active",
		serverTime = 1721120000,
	}))
	local completedTemplate = deepCopy(activeState)
	completedTemplate.startTime = 1721110000
	completedTemplate.endTime = 1721111000
	local function importHistory(sourceUid, raidNid, zone)
		local state = deepCopy(completedTemplate)
		state.raidNid = raidNid
		state.zone = zone
		local snapshot = {
			raidUid = sourceUid,
			status = "complete",
			authorityEpoch = 1,
			sequence = 1,
			digest = assert(addon.DB.RaidEvents.DigestState(state)),
			checkpointSequence = 1,
			state = state,
			events = {},
		}
		assertEqual("IMPORTED", store:ImportHistoricalSnapshot(snapshot))
		return store:GetArchiveKeyByIndex(#store:EnsureArchive().order)
	end
	local uniqueSingleKey = importHistory("history-unique-single", 42, "Unique Single")
	local ambiguousAKey = importHistory("history-ambiguous-a", 43, "Ambiguous A")
	local ambiguousBKey = importHistory("history-ambiguous-b", 43, "Ambiguous B")
	local uniqueBatchKey = importHistory("history-unique-batch", 44, "Unique Batch")

	local archiveBefore = deepCopy(store:EnsureArchive())
	local deleted, deletedIndex, deleteReason = store:DeleteRaid(41)
	assertEqual(false, deleted, "single legacy delete removed the active record")
	assertEqual(nil, deletedIndex, "single active rejection returned a deleted index")
	assertEqual("ACTIVE_RAID_PROTECTED", deleteReason, "single active rejection reason differs")
	assertTrue(deepEqual(archiveBefore, store:EnsureArchive()), "single active rejection mutated the archive")

	local removed, removedNids, batchReason = store:DeleteRaidsByNid({ 42, 41 }, { protectedRaidNid = 999 })
	assertEqual(0, removed, "batch legacy delete bypassed active protection")
	assertEqual(0, #removedNids, "batch active rejection reported removals")
	assertEqual("ACTIVE_RAID_PROTECTED", batchReason, "batch active rejection reason differs")
	assertTrue(deepEqual(archiveBefore, store:EnsureArchive()), "batch active rejection partially mutated the archive")

	deleted, deletedIndex, deleteReason = store:DeleteRaid(43)
	assertEqual(false, deleted, "single legacy delete chose an ambiguous historical record")
	assertEqual(nil, deletedIndex, "ambiguous single rejection returned a deleted index")
	assertEqual("AMBIGUOUS_RAID_NID", deleteReason, "ambiguous single rejection reason differs")
	assertTrue(deepEqual(archiveBefore, store:EnsureArchive()), "ambiguous single rejection mutated the archive")
	removed, removedNids, batchReason = store:DeleteRaidsByNid({ 42, 43 })
	assertEqual(0, removed, "ambiguous batch partially deleted a unique record")
	assertEqual(0, #removedNids, "ambiguous batch reported removals")
	assertEqual("AMBIGUOUS_RAID_NID", batchReason, "ambiguous batch rejection reason differs")
	assertTrue(deepEqual(archiveBefore, store:EnsureArchive()), "ambiguous batch mutated the archive")

	assertEqual(true, store:DeleteRaid(42), "unique historical single delete failed")
	assertEqual(nil, store:GetRecord(uniqueSingleKey), "unique historical single record survived")
	assertTrue(store:GetRecord(activeUid) ~= nil, "unique historical single delete removed active record")
	assertTrue(
		store:GetRecord(ambiguousAKey) ~= nil and store:GetRecord(ambiguousBKey) ~= nil,
		"unique historical single delete changed ambiguous records"
	)
	removed, removedNids, batchReason = store:DeleteRaidsByNid({ 44 })
	assertEqual(1, removed, "unique historical batch delete count differs")
	assertEqual(44, removedNids[1], "unique historical batch delete identity differs")
	assertEqual(nil, batchReason, "unique historical batch delete returned an error")
	assertEqual(nil, store:GetRecord(uniqueBatchKey), "unique historical batch record survived")
	assertTrue(store:GetRecord(activeUid) ~= nil, "unique historical batch delete removed active record")
	print("PASS raid_archive_legacy_nid_delete_is_fail_closed")
end

function cases.raid_roster_rejects_stale_instance_context(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = 1
	fixture.inRaid = true
	fixture.recognizedContext = false
	fixture.raids[1].players = {
		{ playerNid = 1, name = "Existing", rank = 0, subgroup = 1, class = "WARRIOR", join = fixture.now },
	}
	fixture.roster = {
		{ name = "Replacement", rank = 0, subgroup = 1, level = 80, class = "Mage", online = true },
	}
	local raid = installRealRosterFixture(addon, fixture)

	local changed = raid:UpdateRaidRoster()

	assertEqual(false, changed, "roster mutated without a recognized instance context")
	assertEqual(1, #fixture.raids[1].players, "stale instance admission changed the roster")
	assertEqual("Existing", fixture.raids[1].players[1].name, "stale instance admission replaced attendance")
	assertEqual(0, raid:GetRosterVersion(), "stale instance admission advanced roster version")
	print("PASS raid_roster_rejects_stale_instance_context")
end

local function installRaidArchiveLoadFixture(initialArchive)
	resetSavedVariables()
	local fixtureAddon = newAddon()
	_G.RMA_Raids = initialArchive
	installRaidReplicationEventFixture(fixtureAddon)
	_G.GetTime = function()
		return 123.456
	end
	_G.UnitFullName = function()
		return "Leader", "Realm"
	end
	fixtureAddon.Time = {
		GetCurrentTime = function()
			return 1721120000
		end,
	}
	fixtureAddon.Events.Internal = { RaidReplicationCommitted = "RaidReplicationCommitted" }
	fixtureAddon.Bus.TriggerEvent = function() end
	fixtureAddon.IgnoredMobs = {
		IsTrashMobName = function()
			return false
		end,
	}
	loadAddonFile(fixtureAddon, "Raid Management Addon/Database/DB.lua")
	fixtureAddon.Services.Reserves = { Save = function() end }
	loadAddonFile(fixtureAddon, "Raid Management Addon/Database/SavedVariables.lua")
	loadAddonFile(fixtureAddon, "Raid Management Addon/Database/DBRaidValidator.lua")
	loadAddonFile(fixtureAddon, "Raid Management Addon/Database/DBRaidStore.lua")
	return fixtureAddon
end

function cases.raid_archive_nil_and_valid_load(addon)
	local freshAddon = installRaidArchiveLoadFixture(nil)
	local freshArchive = _G.RMA_Raids
	assertTrue(type(freshArchive) == "table", "nil archive did not initialize a table")
	assertEqual(1, freshArchive.formatVersion, "nil archive format differs")
	assertTrue(type(freshArchive.order) == "table", "nil archive order was not initialized")
	assertTrue(type(freshArchive.raids) == "table", "nil archive records were not initialized")
	assertEqual(nil, freshArchive.activeRaidUid, "nil archive initialized an active raid")
	assertTrue(freshAddon.Database.SavedVariables.EnsureAll() ~= nil, "fresh EnsureAll failed")
	assertTrue(_G.RMA_Raids == freshArchive, "fresh EnsureAll replaced the canonical archive")
	assertTrue(freshAddon.Database.SavedVariables.GetRaids() == freshArchive, "fresh getter replaced the archive")
	assertTrue(freshAddon.Database.SavedVariables.NormalizeAfterLoad() == freshArchive, "fresh normalize failed")
	assertTrue(freshAddon.Database.SavedVariables.PrepareForSave("logout") ~= nil, "fresh save preparation failed")
	assertTrue(_G.RMA_Raids == freshArchive, "fresh save preparation replaced the archive")

	local validArchive = {
		formatVersion = 1,
		activeRaidUid = nil,
		order = {},
		raids = {},
	}
	local before = deepCopy(validArchive)
	local validAddon = installRaidArchiveLoadFixture(validArchive)
	assertTrue(_G.RMA_Raids == validArchive, "module load replaced a valid archive")
	validAddon.Database.SavedVariables.EnsureAll()
	assertTrue(_G.RMA_Raids == validArchive, "EnsureAll replaced a valid archive")
	assertTrue(validAddon.Database.SavedVariables.GetRaids() == validArchive, "getter replaced a valid archive")
	assertTrue(validAddon.Database.SavedVariables.NormalizeAfterLoad() == validArchive, "valid normalize failed")
	assertTrue(deepEqual(before, validArchive), "valid normalize changed the archive")
	assertTrue(validAddon.Database.SavedVariables.PrepareForSave("logout") ~= nil, "valid save preparation failed")
	assertTrue(_G.RMA_Raids == validArchive and deepEqual(before, validArchive), "valid save preparation changed the archive")
	print("PASS raid_archive_nil_and_valid_load")
end

function cases.raid_archive_unsupported_load_preservation(addon)
	local variants = {
		{ name = "invalid type", value = "not-an-archive", category = "INVALID_RAID_ARCHIVE_TYPE" },
		{
			name = "future format",
			value = { formatVersion = 2, futureData = { keep = true } },
			category = "UNSUPPORTED_RAID_ARCHIVE_FORMAT",
		},
		{
			name = "older format",
			value = { formatVersion = 0, legacyData = { keep = true } },
			category = "UNSUPPORTED_RAID_ARCHIVE_FORMAT",
		},
		{
			name = "corrupt current format",
			value = { formatVersion = 1, order = "invalid", raids = {} },
			category = "CORRUPT_RAID_ARCHIVE",
		},
	}
	for i = 1, #variants do
		local variant = variants[i]
		local before = deepCopy(variant.value)
		local fixtureAddon = installRaidArchiveLoadFixture(variant.value)
		local savedVariables = fixtureAddon.Database.SavedVariables
		assertTrue(_G.RMA_Raids == variant.value, variant.name .. " was replaced during module load")
		savedVariables.EnsureAll()
		assertTrue(_G.RMA_Raids == variant.value, variant.name .. " was replaced by EnsureAll")
		assertTrue(savedVariables.GetRaids() == variant.value, variant.name .. " was replaced by GetRaids")
		assertTrue(deepEqual(before, variant.value), variant.name .. " changed before validation")
		local loaded, category, detail = savedVariables.NormalizeAfterLoad()
		assertEqual(nil, loaded, variant.name .. " was accepted")
		assertEqual(variant.category, category, variant.name .. " category differs")
		assertTrue(type(detail) == "string", variant.name .. " validator detail is absent")
		assertEqual(category, savedVariables.GetRaidArchiveError(), variant.name .. " store guard category differs")
		assertEqual(category, savedVariables.GetRaidArchiveCategory(), variant.name .. " exposed category differs")
		assertEqual(detail, savedVariables.GetRaidArchiveErrorDetail(), variant.name .. " exposed detail differs")
		assertTrue(_G.RMA_Raids == variant.value and deepEqual(before, variant.value), variant.name .. " changed during normalization")
		local prepared, saveCategory, saveDetail = savedVariables.PrepareForSave("logout")
		assertEqual(nil, prepared, variant.name .. " was prepared for save")
		assertEqual(category, saveCategory, variant.name .. " save category differs")
		assertEqual(detail, saveDetail, variant.name .. " save detail differs")
		assertTrue(_G.RMA_Raids == variant.value and deepEqual(before, variant.value), variant.name .. " changed during save preparation")
	end
	print("PASS raid_archive_unsupported_load_preservation")
end

function cases.raid_archive_invalid_load_quarantine(addon)
	local store = installRaidArchiveFixture(addon)
	local _, _, uid = assert(store:CreateActiveRaid({ authorityKey = "Leader", serverTime = 1721120000 }))
	assert(store:ConcludeActiveRaid(uid, 1721120100))
	local snapshot = assert(store:BuildSnapshot(uid))
	local divergent = deepCopy(snapshot)
	divergent.state.zone = "Variant"
	divergent.digest = assert(addon.DB.RaidEvents.DigestState(divergent.state))
	assertEqual("CONFLICT", store:ImportHistoricalSnapshot(divergent))
	local validArchive = deepCopy(store:EnsureArchive())
	_G.RMA_Raids = validArchive
	assertEqual(validArchive, addon.Database.SavedVariables.NormalizeAfterLoad(), "valid variant archive failed reload")
	local invalidArchives = {}
	local invalidOrder = deepCopy(validArchive)
	invalidOrder.order[1] = "missing-record"
	invalidArchives[#invalidArchives + 1] = invalidOrder
	local invalidOrderShape = deepCopy(validArchive)
	invalidOrderShape.order = "invalid-order"
	invalidArchives[#invalidArchives + 1] = invalidOrderShape
	local invalidDigest = deepCopy(validArchive)
	invalidDigest.raids[invalidDigest.order[1]].digest = "deadbeef:1"
	invalidArchives[#invalidArchives + 1] = invalidDigest
	local invalidProvenance = deepCopy(validArchive)
	local variantKey = invalidProvenance.order[2]
	invalidProvenance.raids[variantKey].sourceRaidUid = nil
	invalidArchives[#invalidArchives + 1] = invalidProvenance
	local invalidPointer = deepCopy(validArchive)
	invalidPointer.activeRaidUid = invalidPointer.order[1]
	invalidArchives[#invalidArchives + 1] = invalidPointer
	for i = 1, #invalidArchives do
		local invalid = invalidArchives[i]
		_G.RMA_Raids = invalid
		local before = deepCopy(invalid)
		local loaded, reason = addon.Database.SavedVariables.NormalizeAfterLoad()
		assertEqual(nil, loaded, "invalid archive load was accepted")
		assertTrue(type(reason) == "string", "invalid archive did not expose a diagnostic reason")
		assertTrue(_G.RMA_Raids == invalid and deepEqual(before, invalid), "invalid archive was normalized or replaced")
		assertEqual(reason, addon.Database.SavedVariables.GetRaidArchiveError(), "quarantine reason differs")
		local saved, saveReason = addon.Database.SavedVariables.PrepareForSave("logout")
		assertEqual(nil, saved, "invalid archive was prepared for save")
		assertEqual(reason, saveReason, "save rejection reason differs")
		assertTrue(_G.RMA_Raids == invalid and deepEqual(before, invalid), "save rejection mutated invalid archive")
		local created, createReason = store:CreateActiveRaid({ authorityKey = "Leader", serverTime = 1721120000 })
		assertEqual(nil, created, "quarantined archive accepted mutation")
		assertEqual(reason, createReason, "mutation rejection reason differs")
		assertTrue(deepEqual(before, invalid), "rejected mutation changed invalid archive")
	end
	print("PASS raid_archive_invalid_load_quarantine")
end

function cases.raid_archive_quarantined_reads_fail_closed(addon)
	local store = installRaidArchiveFixture(addon)
	local activeRaid, _, raidUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader",
		serverTime = 1721120000,
		raidNid = 41,
		zone = "Icecrown Citadel",
	}))
	local validArchive = deepCopy(store:EnsureArchive())
	local invalidArchives = {}

	local badDigest = deepCopy(validArchive)
	badDigest.raids[raidUid].digest = "deadbeef:1"
	invalidArchives[#invalidArchives + 1] = { name = "bad digest", archive = badDigest }

	local futureSchema = deepCopy(validArchive)
	futureSchema.raids[raidUid].state.schemaVersion = addon.Database.GetRaidSchemaVersion() + 1
	futureSchema.raids[raidUid].digest = assert(addon.DB.RaidEvents.DigestState(futureSchema.raids[raidUid].state))
	invalidArchives[#invalidArchives + 1] = { name = "future schema", archive = futureSchema }

	local invalidActivePointer = deepCopy(validArchive)
	invalidActivePointer.activeRaidUid = "missing-active-record"
	invalidArchives[#invalidArchives + 1] = { name = "invalid active pointer", archive = invalidActivePointer }

	for i = 1, #invalidArchives do
		local variant = invalidArchives[i]
		local invalid = variant.archive
		local canonicalState = invalid.raids[raidUid].state
		_G.RMA_Raids = invalid
		local loaded, reason = addon.Database.SavedVariables.NormalizeAfterLoad()
		assertEqual(nil, loaded, variant.name .. " archive load was accepted")
		assertTrue(type(reason) == "string", variant.name .. " archive did not quarantine")

		local readsOk, raids = pcall(function()
			return store:GetAllRaids()
		end)
		assertTrue(readsOk, variant.name .. " quarantined reads must not throw")
		assertEqual(0, #raids, variant.name .. " quarantined feature reads must be empty")
		assertEqual(nil, store:GetRecord(raidUid), variant.name .. " record read must fail closed")
		assertEqual(nil, store:EnsureArchive(), variant.name .. " archive read must fail closed")
		assertEqual(nil, store:GetActiveRecord(), variant.name .. " active record read must fail closed")
		assertEqual(nil, store:GetStateByIndex(1), variant.name .. " state index read must fail closed")
		assertEqual(nil, store:GetArchiveKeyByIndex(1), variant.name .. " archive key read must fail closed")
		assertEqual(nil, store:GetIndexByArchiveKey(raidUid), variant.name .. " archive index read must fail closed")
		assertEqual(nil, store:GetIndexByUid(raidUid), variant.name .. " UID index read must fail closed")
		assertEqual(nil, store:GetRaidUid(canonicalState), variant.name .. " state identity read must fail closed")
		assertEqual(nil, store:EnsureRaidByIndex(1), variant.name .. " raid index lookup must fail closed")
		assertEqual(nil, store:EnsureRaidByNid(activeRaid.raidNid), variant.name .. " NID lookup must fail closed")
		assertEqual(nil, store:GetRaidNidByIndex(1), variant.name .. " index-to-NID read must fail closed")
		assertEqual(
			nil,
			store:GetRaidIndexByNid(activeRaid.raidNid),
			variant.name .. " NID-to-index read must fail closed"
		)

		local rawRaids = store:GetRawRaids()
		assertEqual(1, #rawRaids, variant.name .. " raw diagnostic projection must retain canonical rows")
		assertTrue(rawRaids[1] == canonicalState, variant.name .. " raw diagnostic row must remain canonical")
	end
	print("PASS raid_archive_quarantined_reads_fail_closed")
end

function cases.raid_archive_cleanup_exact_identity(addon)
	local store = installRaidArchiveFixture(addon)
	local activeUid = importCollidingHistoryRows(store, addon.DB.RaidEvents)
	local archive = store:EnsureArchive()
	local deleteKey = archive.order[3]
	local editKey = archive.order[4]
	local editRecord = archive.raids[editKey]
	editRecord.state.loot = {
		{ lootNid = 1, itemId = 100, itemLink = "item:100", itemRarity = 3 },
		{ lootNid = 2, itemId = 200, itemLink = "item:200", itemRarity = 4 },
	}
	editRecord.state.nextLootNid = 3
	editRecord.digest = assert(addon.DB.RaidEvents.DigestState(editRecord.state))
	assert(addon.Database.GetRaidValidator():ValidateRecord(editRecord))
	local plan = {
		protectedArchiveKey = activeUid,
		raidCandidates = { { archiveKey = deleteKey, baseDigest = archive.raids[deleteKey].digest } },
		lootCandidates = {
			{
				archiveKey = editKey,
				baseDigest = editRecord.digest,
				lootNid = 1,
				itemId = 100,
				itemLink = "item:100",
				bossNid = nil,
			},
		},
	}
	local result = assert(store:CommitRaidHistoryCleanup(plan, activeUid))
	archive = store:EnsureArchive()
	assertEqual(1, result.raidsRemoved, "exact archive row was not deleted")
	assertEqual(nil, archive.raids[deleteKey], "deleted archive key survived")
	assertEqual(1, #archive.raids[editKey].state.loot, "exact variant loot was not edited")
	assertEqual(200, archive.raids[editKey].state.loot[1].itemId, "wrong variant loot survived")
	assertEqual("Active", archive.raids[activeUid].state.zone, "active row was changed")
	local beforeConflict = deepCopy(archive)
	local stale = {
		protectedArchiveKey = activeUid,
		raidCandidates = { { archiveKey = editKey, baseDigest = "deadbeef:1" } },
		lootCandidates = {},
	}
	assertEqual(nil, store:CommitRaidHistoryCleanup(stale, activeUid), "stale cleanup was accepted")
	assertTrue(deepEqual(beforeConflict, archive), "conflicted cleanup partially mutated archive")
	print("PASS raid_archive_cleanup_exact_identity")
end

function cases.raid_runtime_indexes_are_store_owned(addon)
	local store = installRaidArchiveFixture(addon)
	local state, _, raidUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		raidNid = 41,
		zone = "ICC",
		serverTime = 1721120000,
	}))
	local record = assert(store:GetRecord(raidUid))
	local digestBefore = assert(addon.DB.RaidEvents.DigestState(state))
	local runtimeBefore = assert(store:EnsureRaidRuntime(state))
	assertEqual(nil, state._runtime, "runtime cache entered canonical state")
	assertEqual(digestBefore, addon.DB.RaidEvents.DigestState(state), "runtime query changed canonical digest")
	assertEqual(
		true,
		addon.Database.GetRaidValidator():ValidateRecord(record),
		"runtime query invalidated record digest"
	)
	local snapshot = assert(store:BuildSnapshot(raidUid))
	assertEqual(nil, snapshot.state._runtime, "snapshot carried runtime cache")
	assertEqual(nil, _G.RMA_Raids.raids[raidUid].state._runtime, "SavedVariables carried runtime cache")
	assert(addon.Database.SavedVariables.PrepareForSave("test"))
	assertEqual(nil, _G.RMA_Raids.raids[raidUid].state._runtime, "save preparation carried runtime cache")

	local event, updatedState = assert(store:CommitAuthoritativeEvent(raidUid, "PLAYER_UPDATED", {
		player = { playerNid = 1, name = "Member" },
	}))
	assertEqual(2, event.sequence, "event sequence differs")
	local runtimeAfter = assert(store:EnsureRaidRuntime(updatedState))
	assertTrue(runtimeAfter ~= runtimeBefore, "candidate reused stale runtime cache")
	assertEqual("Member", runtimeAfter.playerByNid[1].name, "new state runtime cache is stale")
	assertEqual(nil, updatedState._runtime, "mutation candidate carried runtime cache")

	local maliciousSnapshot = assert(store:BuildSnapshot(raidUid))
	maliciousSnapshot.status = "complete"
	maliciousSnapshot.state.endTime = 1721120100
	maliciousSnapshot.state._runtime = { lootByNid = {} }
	maliciousSnapshot.digest = assert(addon.DB.RaidEvents.DigestState(maliciousSnapshot.state))
	maliciousSnapshot.events = {}
	maliciousSnapshot.checkpointSequence = maliciousSnapshot.sequence
	_G.RMA_Raids = { formatVersion = 1, activeRaidUid = nil, order = {}, raids = {} }
	local imported, importReason = store:ImportHistoricalSnapshot(maliciousSnapshot)
	assertEqual(nil, imported, "malicious runtime field entered imported state")
	assertTrue(type(importReason) == "string", "malicious snapshot rejection omitted reason")

	local maliciousArchive = deepCopy(snapshot)
	maliciousArchive.status = "complete"
	maliciousArchive.state.endTime = 1721120100
	maliciousArchive.state._runtime = { playersByName = {} }
	maliciousArchive.digest = assert(addon.DB.RaidEvents.DigestState(maliciousArchive.state))
	maliciousArchive.events = {}
	maliciousArchive.checkpointSequence = maliciousArchive.sequence
	_G.RMA_Raids = {
		formatVersion = 1,
		activeRaidUid = nil,
		order = { raidUid },
		raids = { [raidUid] = maliciousArchive },
	}
	local rawBefore = deepCopy(_G.RMA_Raids)
	local loaded = addon.Database.SavedVariables.NormalizeAfterLoad()
	assertEqual(nil, loaded, "persisted runtime field was accepted")
	assertTrue(deepEqual(rawBefore, _G.RMA_Raids), "persisted runtime field was normalized away")
	print("PASS raid_runtime_indexes_are_store_owned")
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
				if tonumber(raidIndex) ~= tonumber(fixture.currentRaid) then
					return nil
				end
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
		ResolveWowForwardedName = function(name)
			return name
		end,
	}
	addon.Bus = {
		TriggerEvent = function(eventName, ...)
			fixture.events[#fixture.events + 1] = { name = eventName, args = { ... } }
			if fixture.onEvent then
				fixture.onEvent(eventName, ...)
			end
		end,
		RegisterCallback = function(eventName, callback)
			callbacks[eventName] = callback
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			fixture:InstallTimers(target)
		end,
	}
	addon.Time = {
		GetCurrentTime = function()
			return 1700000000 + fixture.now
		end,
	}
	addon.Strings = {}
	addon.Database.GetCurrentRaid = function()
		return fixture.currentRaid
	end
	addon.Database.GetRaidStore = function()
		return fixture.store
	end
	addon.Database.EnsureRaidByIndex = function(index)
		return fixture.raids[index]
	end
	addon.Database.EnsureRaidByNid = function(raidNid)
		for i = 1, #fixture.raids do
			if tonumber(fixture.raids[i].raidNid) == tonumber(raidNid) then
				return fixture.raids[i], i
			end
		end
	end
	addon.Database.GetRaidIndexByNid = function(raidNid)
		local _, index = addon.Database.EnsureRaidByNid(raidNid)
		return index
	end
	_G.UnitGUID = function(unit)
		return "guid-" .. tostring(unit)
	end
	_G.UnitExists = function()
		return fixture.unitExists
	end
	_G.UnitIsConnected = function()
		return fixture.unitConnected
	end
	_G.CanInspect = function()
		return fixture.canInspect
	end
	_G.CheckInteractDistance = function()
		return fixture.unitInRange
	end
	_G.ClearInspectPlayer = function()
		fixture.clearInspectCount = fixture.clearInspectCount + 1
	end
	_G.UnitAffectingCombat = function()
		return fixture.inCombat
	end
	_G.GetInventoryItemLink = function(_, slot)
		return fixture.itemLinks[slot]
	end
	_G.GetInventoryItemTexture = function(_, slot)
		return fixture.itemTextures[slot]
	end
	_G.GetInventoryItemQuality = function()
		return nil
	end
	_G.GetItemInfo = function(itemRef)
		local itemId = tonumber(itemRef)
		if not itemId and type(itemRef) == "string" then
			itemId = tonumber(string.match(itemRef, "item:(%d+)"))
		end
		local itemLevel = itemId and fixture.itemInfo[itemId] or nil
		if not itemLevel then
			return nil
		end
		return "Item " .. tostring(itemId), nil, nil, itemLevel
	end
	_G.NotifyInspect = function(unit)
		if fixture.notifyFails then
			error("notify failed")
		end
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
