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
	addon.Events = {
		Internal = {},
		ResolveWowForwardedName = function(name)
			return name
		end,
	}
	addon.Bus = {
		RegisterCallback = function(name, callback)
			callbacks[name] = callback
		end,
	}
	addon.Timer = {
		BindMixin = function(module)
			function module:ScheduleTimer(callback, delay)
				local handle = { callback = callback, deadline = nowValue + delay }
				timers[#timers + 1] = handle
				return handle
			end
			function module:CancelTimer(handle)
				handle.cancelled = true
			end
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
		end,
	}
	_G.GetTime = function()
		return nowValue
	end
	_G.UnitAffectingCombat = function()
		return combat
	end
	_G.ClearInspectPlayer = function()
		clears = clears + 1
	end
	loadAddonFile(addon, "Raid Management Addon/Services/InspectCoordinator.lua")
	local coordinator = addon.Services.InspectCoordinator
	local starts, finishes = {}, {}
	assertEqual(
		"active",
		select(
			2,
			coordinator:Request("equipment", "raid1", "guid-1", function()
				starts[#starts + 1] = "equipment"
			end, function(reason)
				finishes[#finishes + 1] = reason
			end)
		),
		"equipment owns first target"
	)
	assertEqual(
		"queued",
		select(
			2,
			coordinator:Request("talents", "raid2", "guid-2", function()
				starts[#starts + 1] = "talents"
			end, function(reason)
				finishes[#finishes + 1] = reason
			end)
		),
		"talents queue behind equipment"
	)
	assertEqual(false, coordinator:Release("equipment", "wrong-guid"), "mismatched ready cannot release owner")
	assertEqual(0, clears, "mismatched ready cannot clear target")
	assertEqual(true, coordinator:Release("equipment", "guid-1"), "matching owner releases")
	assertEqual(1, clears, "only released owner clears")
	assertEqual(nil, starts[2], "global throttle delays the next NotifyInspect owner")
	nowValue = 1.75
	for i = 1, #timers do
		if not timers[i].cancelled and timers[i].deadline <= nowValue then
			timers[i].cancelled = true
			timers[i].callback()
		end
	end
	assertEqual("talents", starts[2], "queued talent request progresses after global throttle")
	assertEqual(false, coordinator:Release("equipment", "guid-1"), "old owner cannot clear new target")
	assertEqual(1, clears, "old owner leaves talent target intact")
	assertEqual(true, coordinator:Cancel("talents"), "active talent work cancels")
	assertEqual(2, clears, "cancel clears its own target once")
	local cancelledStarts, cancelledFinishes = 0, 0
	coordinator:Request("blocker", "raid1", "guid-block", function() end)
	coordinator:Request("cancel-me", "raid2", "guid-cancel", function()
		cancelledStarts = cancelledStarts + 1
	end, function(reason)
		assertEqual("cancelled", reason, "queued cancellation has stable reason")
		cancelledFinishes = cancelledFinishes + 1
	end)
	assertEqual(true, coordinator:Cancel("cancel-me"), "queued work cancels by exact owner")
	assertEqual(0, cancelledStarts, "cancelled queued work never starts")
	assertEqual(1, cancelledFinishes, "cancelled queued callback fires once")
	nowValue = 3.5
	for i = 1, #timers do
		if not timers[i].cancelled and timers[i].deadline <= nowValue then
			timers[i].cancelled = true
			timers[i].callback()
		end
	end
	coordinator:Release("blocker", "guid-block")

	combat = true
	assertEqual(
		"queued",
		select(
			2,
			coordinator:Request("equipment", "raid1", "guid-3", function()
				starts[#starts + 1] = "combat"
			end, function(reason)
				finishes[#finishes + 1] = reason
			end)
		),
		"combat defers inspect"
	)
	assertEqual(nil, starts[3], "combat request has not started")
	combat = false
	callbacks.PLAYER_REGEN_ENABLED()
	nowValue = 5.25
	for i = 1, #timers do
		if not timers[i].cancelled and timers[i].deadline <= nowValue then
			timers[i].cancelled = true
			timers[i].callback()
		end
	end
	assertEqual("combat", starts[3], "regen starts deferred request")
	nowValue = 13.5
	for i = 1, #timers do
		if not timers[i].cancelled and timers[i].deadline <= nowValue then
			timers[i].callback()
		end
	end
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
		assertEqual(
			true,
			coordinator:Request("cap-" .. tostring(i), "raid1", "guid-cap", function() end),
			"bounded queue accepts capacity"
		)
	end
	assertEqual(
		"queue_full",
		select(2, coordinator:Request("cap-overflow", "raid1", "guid-cap", function() end)),
		"bounded queue rejects overflow"
	)
	print("PASS inspect_coordinator_serializes_global_ownership")
end

function cases.equip_and_talent_refresh_share_global_inspect_owner(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	fixture.itemLinks[1] = itemLink(1001)
	fixture.itemInfo[1001] = 251
	assertEqual("pending", select(2, inspect:ForcePlayer(2, 21)), "equipment starts first")
	local coordinator = addon.Services.InspectCoordinator
	local talentStarts = 0
	assertEqual(
		"queued",
		select(
			2,
			coordinator:Request("talents", "raid2", "guid-raid2", function()
				talentStarts = talentStarts + 1
				NotifyInspect("raid2")
			end)
		),
		"talent refresh queues behind equipment"
	)
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
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
		end,
		Raid = {
			GetUnitID = function(_, name)
				return name == "Alpha" and "raid1" or "none"
			end,
			GetPlayers = function()
				return { { name = "Alpha" } }
			end,
			GetPlayerClass = function()
				return "PRIEST"
			end,
		},
	}
	addon.Database.GetCurrentRaid = function()
		return 1
	end
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
	}
	addon.Events = {
		Internal = { SpecInspectUpdated = "SpecInspectUpdated" },
		ResolveWowForwardedName = function(name)
			return name
		end,
	}
	addon.Bus = {
		TriggerEvent = function() end,
		RegisterCallback = function(name, callback)
			busCallbacks[name] = callback
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			fixture:InstallTimers(target)
		end,
	}
	_G.GetTime = function()
		return fixture.now
	end
	_G.UnitAffectingCombat = function()
		return false
	end
	_G.ClearInspectPlayer = function()
		fixture.clearInspectCount = (fixture.clearInspectCount or 0) + 1
	end
	_G.UnitGUID = function(unit)
		return unit == "raid1" and "guid-alpha" or "guid-other"
	end
	local lgt = {
		CheckInspectQueue = function() end,
		RegisterCallback = function(_, name, callback)
			lgtCallbacks[name] = callback
		end,
		RefreshTalentsByUnit = function(_, unit)
			assertEqual("raid1", unit, "SpecInspect refreshes requested unit")
			refreshCalls = refreshCalls + 1
		end,
		GetNumTalentGroups = function()
			return 1
		end,
		GetActiveTalentGroup = function()
			return 1
		end,
		GetUnitTalentSpec = function()
			if resolved then
				return "Discipline", 57, 14, 0
			end
		end,
		GetGUIDTalentSpec = function(_, guid)
			if resolved and guid == "guid-alpha" then
				return "Discipline", 57, 14, 0
			end
		end,
		GetTalentTabInfo = function()
			return "Discipline", "spec-icon"
		end,
		GetUnitRole = function()
			return "healer"
		end,
	}
	_G.LibStub = function(name)
		if name == "LibGroupTalents-1.0" or name == "LibTalentQuery-1.0" then
			return lgt
		end
	end
	loadAddonFile(addon, "Raid Management Addon/Services/InspectCoordinator.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/SpecInspect.lua")
	local spec = addon.Services.SpecInspect
	assertEqual(true, spec:RefreshPlayer("Alpha", { force = true }), "production SpecInspect queues LGT refresh")
	assertEqual(1, refreshCalls, "LGT refresh starts through coordinator")
	lgtCallbacks.LibGroupTalents_UpdateComplete(nil, "guid-other")
	assertEqual(
		true,
		addon.Services.InspectCoordinator:IsCategoryOwner("talents"),
		"unrelated UpdateComplete cannot release talent owner"
	)
	addon.Services.InspectCoordinator:Request("equipment-after-spec", "raid2", "guid-other", function()
		equipmentStarts = equipmentStarts + 1
	end, nil, "equipment")
	assertEqual(0, equipmentStarts, "equipment remains queued behind unresolved talent operation")
	resolved = true
	lgtCallbacks.LibGroupTalents_Update(nil, "guid-alpha", "raid1")
	assertEqual(0, equipmentStarts, "matching talent data still respects global throttle")
	fixture:AdvanceTime(1.75)
	assertEqual(1, equipmentStarts, "matching GUID terminal data releases the talent owner")
	addon.Services.InspectCoordinator:Release("equipment-after-spec", "guid-other")
	local scheduleTimer = addon.Services.InspectCoordinator.ScheduleTimer
	addon.Services.InspectCoordinator.ScheduleTimer = function()
		return nil
	end
	local timerOk, timerReason = spec:RefreshPlayer("Alpha", { force = true })
	assertEqual(false, timerOk, "SpecInspect reports coordinator timer failure")
	assertEqual("inspect_timer_failed", timerReason, "SpecInspect exposes stable timer failure")
	addon.Services.InspectCoordinator.ScheduleTimer = scheduleTimer
	local request = addon.Services.InspectCoordinator.Request
	addon.Services.InspectCoordinator.Request = function()
		return false, "queue_full"
	end
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
	raidA.players[1].inspect = raidA.inspect.players[11]
	fixture.itemLinks[1], fixture.itemInfo[1001] = itemLink(1001), 251
	local coordinator = addon.Services.InspectCoordinator
	assertEqual(
		"active",
		select(2, coordinator:Request("talent-blocker", "raid1", "talent-guid", function() end, nil, "talents")),
		"talent flow owns active target"
	)
	fixture.currentRaid = 1
	assertEqual("queued", select(2, inspect:ForcePlayer(1, 11)), "raid A replacement queues")
	local scheduleTimer = coordinator.ScheduleTimer
	coordinator.ScheduleTimer = function(self, callback, delay)
		if delay == 1.75 then
			return nil
		end
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
		if
			eventName == "EquipInspectUpdated"
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
	assertEqual(
		"pending",
		inspect:GetSnapshot(fixture.raids[2], 21).status,
		"stale rejection must preserve replacement status"
	)
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
			if
				event.name == "EquipInspectUpdated"
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
		raidA.players[1].inspect = raidA.inspect.players[11]
		assertEqual("pending", select(2, inspect:ForcePlayer(2, 21)), failureMode .. " handoff blocker starts")
		fixture.currentRaid = 1
		assertEqual("queued", select(2, inspect:ForcePlayer(1, 11)), failureMode .. " handoff work queues")
		local coordinator = addon.Services.InspectCoordinator
		local scheduleTimer = coordinator.ScheduleTimer
		local injected = false
		coordinator.ScheduleTimer = function(self, callback, delay)
			if delay == 1.75 and not injected then
				injected = true
				if failureMode == "throw" then
					error("injected InspectCoordinator handoff timer failure")
				end
				return nil
			end
			return scheduleTimer(self, callback, delay)
		end
		local reentered = false
		fixture.onEvent = function(eventName, raidNid, playerNid, snapshot)
			if
				eventName == "EquipInspectUpdated"
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
		assertEqual(
			"old-guid",
			inspect:GetPersistedSnapshot(raidA, 11).guid,
			failureMode .. " handoff preserves last good snapshot"
		)
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
			if failureMode == "throw" then
				error("injected EquipInspect item timer failure")
			end
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
	_G.IsLoggedIn = function()
		return true
	end
	_G.GetTime = function()
		return nowValue
	end
	_G.GetNumRaidMembers = function()
		return 1
	end
	_G.GetNumPartyMembers = function()
		return 0
	end
	_G.UnitName = function(unit)
		if unit == "raid1" or unit == "Alpha" then
			return "Alpha", "Realm"
		end
		return "Player", "Realm"
	end
	_G.UnitGUID = function(unit)
		if unit == "raid1" or unit == "Alpha-Realm" or unit == "Alpha" then
			return "guid-alpha"
		end
		return "guid-player"
	end
	_G.UnitExists = function(unit)
		return unit == "raid1" or unit == "Alpha-Realm" or unit == "player"
	end
	_G.UnitIsPlayer = function()
		return true
	end
	_G.UnitIsVisible = function()
		return true
	end
	_G.UnitIsConnected = function()
		return true
	end
	_G.UnitCanAttack = function()
		return false
	end
	_G.UnitClass = function()
		return "Priest", "PRIEST"
	end
	_G.UnitLevel = function()
		return 80
	end
	_G.UnitIsUnit = function(a, b)
		return a == b
	end
	_G.UnitInRaid = function()
		return 1
	end
	_G.UnitInParty = function()
		return false
	end
	_G.CanInspect = function()
		return true
	end
	_G.CheckInteractDistance = function()
		return true
	end
	_G.GetActiveTalentGroup = function()
		return 1
	end
	_G.GetNumTalentGroups = function()
		return 1
	end
	_G.GetNumTalentTabs = function()
		return 3
	end
	_G.GetTalentTabInfo = function(tab)
		return ({ "Discipline", "Holy", "Shadow" })[tab], "icon" .. tostring(tab), ({ 57, 14, 0 })[tab]
	end
	_G.GetNumTalents = function()
		return 1
	end
	_G.GetTalentInfo = function(tab)
		return "Talent" .. tostring(tab), "talent-icon", 1, 1, ({ 5, 1, 0 })[tab], 5
	end
	_G.GetUnspentTalentPoints = function()
		return 0
	end
	_G.GetSpellInfo = function(id)
		return "Spell" .. tostring(id)
	end
	_G.GetGlyphSocketInfo = function()
		return nil
	end
	_G.SendAddonMessage = function() end
	_G.RegisterAddonMessagePrefix = function() end
	_G.strsplit = function(_, value)
		local a, b = string.match(value, "^([^-]+)%-?(.*)$")
		return a, b ~= "" and b or nil
	end
	_G.wipe = function(t)
		for key in pairs(t) do
			t[key] = nil
		end
		return t
	end
	_G.geterrorhandler = function()
		return function(err)
			error(err)
		end
	end
	_G.securecall = function(func, ...)
		return func(...)
	end
	_G.CreateFrame = function(_, name)
		local frame = { shown = false }
		function frame:UnregisterAllEvents() end
		function frame:RegisterEvent() end
		function frame:SetScript(kind, callback)
			self[kind] = callback
		end
		function frame:Show()
			self.shown = true
		end
		function frame:Hide()
			self.shown = false
		end
		function frame:IsShown()
			return self.shown
		end
		frames[name] = frame
		return frame
	end
	_G.NotifyInspect = function()
		notifyCount = notifyCount + 1
	end
	_G.hooksecurefunc = function(name, hook)
		local original = _G[name]
		_G[name] = function(...)
			local values = { original(...) }
			hook(...)
			return unpack(values)
		end
	end
	loadAddonFile(addon, "Raid Management Addon/Libs/LibStub/LibStub.lua")
	loadAddonFile(addon, "Raid Management Addon/Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua")
	loadAddonFile(addon, "Raid Management Addon/Libs/LibTalentQuery-1.0/LibTalentQuery-1.0.lua")
	loadAddonFile(addon, "Raid Management Addon/Libs/LibGroupTalents-1.0/LibGroupTalents-1.0.lua")
	local lgt = LibStub("LibGroupTalents-1.0")
	local ltq, terminalReady = LibStub("LibTalentQuery-1.0"), 0
	local terminalOwner = {}
	ltq.RegisterCallback(terminalOwner, "TalentQuery_Ready", function()
		terminalReady = terminalReady + 1
	end)
	lgt.roster["guid-alpha"] = { unit = "raid1", name = "Alpha", realm = "Realm", class = "PRIEST", level = 80 }
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
		end,
		Raid = {
			GetUnitID = function()
				return "raid1"
			end,
			GetPlayers = function()
				return { { name = "Alpha" } }
			end,
			GetPlayerClass = function()
				return "PRIEST"
			end,
		},
	}
	addon.Database = {
		GetCurrentRaid = function()
			return 1
		end,
	}
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
	}
	addon.Events = {
		Internal = { SpecInspectUpdated = "SpecInspectUpdated" },
		ResolveWowForwardedName = function(name)
			return name
		end,
	}
	local callbacks = {}
	addon.Bus = {
		RegisterCallback = function(name, callback)
			callbacks[name] = callback
		end,
		TriggerEvent = function() end,
	}
	addon.Timer = {
		BindMixin = function(target)
			target.ScheduleTimer = function()
				return {}
			end
			target.CancelTimer = function() end
		end,
	}
	_G.UnitAffectingCombat = function()
		return false
	end
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
		if fixture.timers[i].active then
			activeTimers = activeTimers + 1
		end
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
			if fixture.timers[i].active then
				count = count + 1
			end
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
		startedAt = 51,
		completedAt = 52,
		mode = "auto",
		transient = "discard",
		players = {
			[11] = {
				status = "ready",
				playerNid = 11,
				name = "Alpha",
				specName = "Holy",
				avgIlvl = 226,
				inspectedAt = 12345,
				reason = "stale",
				items = { [1] = { itemId = 1 } },
				transient = true,
			},
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
	assertEqual(
		initialRevision + 1,
		fixture.store:GetRaidSyncRevision(raid),
		"identical ready snapshot is revision no-op"
	)
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

function cases.equip_inspect_semantic_store_failure_is_atomic(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	local before = deepCopy(raid)
	local commitCalls = 0
	fixture.store.CommitAuthoritativeEvent = function()
		commitCalls = commitCalls + 1
		return nil, "INJECTED_STORE_FAILURE"
	end
	assertEqual(true, inspect:ForcePlayer(2, 21), "inspect request must reach ready persistence")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	assertEqual(1, commitCalls, "inspect owner must reach semantic store")
	assertTrue(deepEqual(before, raid), "failed inspect commit mutated canonical raid")
	for i = 1, #fixture.events do
		local event = fixture.events[i]
		assertTrue(
			not (event.name == "EquipInspectUpdated" and event.args[3] and event.args[3].status == "ready"),
			"failed inspect commit published ready canonical data"
		)
	end
	print("PASS equip_inspect_semantic_store_failure_is_atomic")
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
	assertTrue(
		deepEqual(canonicalInspect, raid.inspect),
		"skipped attempt must preserve canonical inspect state deeply"
	)
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
	local persisted = deepCopy(raid.players[1].inspect)
	assertTrue((tonumber(persisted.inspectedAt) or 0) >= 1700000000, "persisted inspect time must use epoch time")

	local reloadedFixture, reloadedInspect = installEquipInspectFixture(addon)
	reloadedFixture.raids[2].players[1].inspect = persisted
	local restored = reloadedInspect:GetSnapshot(reloadedFixture.raids[2], 21)
	assertEqual("ready", restored.status, "reload must restore canonical ready status")
	assertEqual(persisted.specName, restored.specName, "reload must restore canonical spec")
	assertEqual(persisted.avgIlvl, restored.avgIlvl, "reload must restore canonical gear summary")
	print("PASS equip_inspect_ready_snapshot_survives_reload_with_epoch_timestamp")
end

function cases.equip_inspect_persists_truncated_item_level_with_reload_stable_digest(addon)
	installRaidReplicationEventFixture(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	local raid = fixture.raids[2]
	local slots = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }
	for i = 1, #slots do
		local itemId = 2000 + i
		fixture.itemLinks[slots[i]] = itemLink(itemId)
		fixture.itemInfo[itemId] = i == #slots and 245 or 243
	end

	local committedPayload
	local originalCommit = fixture.store.CommitAuthoritativeEvent
	fixture.store.CommitAuthoritativeEvent = function(self, raidUid, eventType, payload)
		if eventType == "PLAYER_UPDATED" then
			committedPayload = deepCopy(payload)
		end
		return originalCommit(self, raidUid, eventType, payload)
	end

	assertEqual(true, inspect:ForcePlayer(2, 21), "fractional inspect starts")
	fixture.inspectCallbacks.INSPECT_TALENT_READY(nil, "guid-raid1")
	local persisted = assert(raid.players[1].inspect)
	assertEqual(243, persisted.avgIlvl, "persisted average must truncate toward zero")
	assertEqual(
		243,
		assert(raid.inspect.players[21]).avgIlvl,
		"canonical inspect mirror must use the truncated average"
	)
	assertEqual(243, assert(committedPayload).player.inspect.avgIlvl, "PLAYER_UPDATED must carry the truncated average")

	local digestBeforeReload = assert(addon.DB.RaidEvents.DigestState(raid))
	local reloaded = deepCopy(raid)
	reloaded.players[1].inspect.avgIlvl = tonumber(string.format("%.15g", persisted.avgIlvl))
	reloaded.inspect.players[21].avgIlvl = tonumber(string.format("%.15g", persisted.avgIlvl))
	assertEqual(
		digestBeforeReload,
		addon.DB.RaidEvents.DigestState(reloaded),
		"SavedVariables numeric reload must preserve the raid digest"
	)
	print("PASS equip_inspect_persists_truncated_item_level_with_reload_stable_digest")
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
		if scenario[3] ~= true then
			fixture[scenario[2]] = false
		end
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
		if fixture.timers[i].active then
			activeTimers = activeTimers + 1
		end
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
	assertEqual(
		clearBaseline,
		fixture.clearInspectCount,
		"orphan without global target must not clear unrelated inspect"
	)
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
		if
			event.name == "EquipInspectStarted"
			or event.name == "EquipInspectCompleted"
			or event.name == "EquipInspectUpdated"
		then
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
	local before = deepCopy(raid)
	local commitCalls = 0
	fixture.store.CommitAuthoritativeEvent = function()
		commitCalls = commitCalls + 1
		return nil, "INJECTED_STORE_FAILURE"
	end
	local committed, reason = actions:RecordLoot({
		raidId = 2,
		lootNid = 7,
		looter = "Beta",
		rollType = "MS",
		rollValue = 97,
	})
	assertEqual(false, committed, "semantic store failure must reject RecordLoot")
	assertEqual("WRITE_FAILED", reason, "failed semantic edit preserves public error shape")
	assertEqual(1, commitCalls, "valid logger edit must reach the semantic store")
	assertTrue(deepEqual(before, raid), "failed semantic store edit must preserve canonical state")
	assertEqual(0, #fixture.events, "failed semantic store edit must publish nothing")
	print("PASS logger_atomic_commit_failure_matrix")
end

function cases.logger_history_validation_is_strict_and_complete(addon)
	local fixture = installLoggerAtomicFixture(addon)
	local raid = prepareCompletedRebuildRaid(fixture)
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
	reject(function(staged)
		staged.players[2] = { playerNid = 21, name = "Duplicate" }
	end)
	reject(function(staged)
		staged.loot[2] = { lootNid = 7, itemId = 1 }
	end)
	reject(function(staged)
		staged.loot[3] = { lootNid = 9, itemId = 1 }
	end)
	reject(function(staged)
		staged.players.hidden = { playerNid = 22, name = "Hidden" }
	end)
	reject(function(staged)
		staged.bossKills[1] = { bossNid = 4, players = { [2] = 21 } }
	end)
	local staged = fixture.store:StageRaidHistoryMutation(raid)
	local ok, reason = fixture.store:CommitRaidHistoryMutation(raid, staged, { lootNid = "7", reason = "test" })
	assertEqual(false, ok, "numeric string loot scope must reject")
	assertEqual("INVALID_LOOT_SCOPE", reason, "loot scope reason differs")
	print("PASS logger_history_validation_is_strict_and_complete")
end

function cases.raid_store_uses_validator_first_error(addon)
	local fixture = installLoggerAtomicFixture(addon)
	local raid = prepareCompletedRebuildRaid(fixture)
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
		local fixture = installLoggerAtomicFixture(addon)
		local raid = prepareCompletedRebuildRaid(fixture)
		local realValidator = addon.Database.GetRaidValidator()
		addon.Database.GetRaidValidator = function()
			return {
				ValidateArchive = function(_, archive)
					return realValidator:ValidateArchive(archive)
				end,
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

	print("PASS raid_store_rejects_malformed_validator_reports")
end

function cases.logger_async_rebuild_outcomes_and_conflict(addon)
	local fixture, actions = installLoggerAtomicFixture(addon)
	local raid = prepareCompletedRebuildRaid(fixture)
	local callbackResult, callbackComplete
	local handle = actions:StartLootSourceRebuild(function(result, complete)
		callbackResult, callbackComplete = result, complete
	end, { chunkSize = 1, delaySeconds = 0.1 })
	fixture:AdvanceTime(0.1)
	local recordOk, recordReason =
		actions:RecordLoot({ raidId = 1, lootNid = 7, looter = "Beta", rollType = "MS", rollValue = 98 })
	assertEqual(true, recordOk, "concurrent RecordLoot setup must commit: " .. tostring(recordReason))
	fixture.events = {}
	fixture:AdvanceTime(0.1)
	fixture:AdvanceTime(0.1)
	assertEqual(false, callbackComplete, "conflict must be incomplete")
	assertEqual(true, callbackResult.failed, "conflict must fail")
	assertEqual(true, callbackResult.conflict, "conflict must be stable and retryable")
	assertEqual(0, callbackResult.repaired, "conflicted staged repairs are not committed counters")
	assertEqual(0, callbackResult.bossesCreated, "conflicted staged bosses are not committed counters")
	assertEqual(0, #fixture.events, "conflicted rebuild must not publish")
	raid = fixture:GetRaid(1)
	assertEqual(98, raid.loot[1].rollValue, "conflicted rebuild must not overwrite concurrent RecordLoot")
	assertEqual(false, handle:Cancel(), "conflicted handle is terminal")

	fixture, actions = installLoggerAtomicFixture(addon)
	raid = prepareCompletedRebuildRaid(fixture)
	local changedResult, changedComplete
	actions:StartLootSourceRebuild(function(result, complete)
		changedResult, changedComplete = result, complete
	end, { chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	assertEqual(true, changedComplete, "changed rebuild completes")
	assertEqual(1, changedResult.repaired, "changed rebuild reports repair")
	assertEqual(1, #fixture.events, "changed rebuild publishes once")
	raid = fixture:GetRaid(1)
	fixture.events = {}
	local noopResult, noopComplete
	actions:StartLootSourceRebuild(function(result, complete)
		noopResult, noopComplete = result, complete
	end, { chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	assertEqual(true, noopComplete, "no-op rebuild completes")
	assertEqual(0, noopResult.repaired, "no-op rebuild reports no repair")
	assertEqual(0, #fixture.events, "no-op rebuild does not publish")
	raid.loot[2] = { lootNid = 8, itemId = 99999 }
	raid.nextLootNid = 9
	fixture:RefreshRaidRecord(raid)
	fixture.store:EnsureRaidRuntime(raid)
	local unresolvedResult
	actions:StartLootSourceRebuild(function(result)
		unresolvedResult = result
	end, { chunkSize = 20, delaySeconds = 0 })
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
	fixture.currentRaid = nil
	local root = fixture.archive
	local firstKey, secondKey = root.order[1], root.order[2]
	local firstRecord, secondRecord = root.raids[firstKey], root.raids[secondKey]
	local firstRaid, movedRaid = firstRecord.state, secondRecord.state
	local firstRuntime = fixture.store:EnsureRaidRuntime(firstRaid)
	local movedRuntime = fixture.store:EnsureRaidRuntime(movedRaid)
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
	assertEqual(1, getAllCalls, "pre-commit cancellation should build one detached ordered projection")
	assertEqual(0, commitCalls, "pre-commit cancellation must not call the store commit")
	assertEqual(1, callbackCount, "pre-commit cancellation callback must run once")
	assertTrue(root == fixture.archive, "pre-commit cancellation must preserve archive identity")
	assertTrue(
		root.raids[firstKey] == firstRecord and root.raids[secondKey] == secondRecord,
		"pre-commit cancellation must preserve record identities"
	)
	assertTrue(
		root.raids[firstKey].state == firstRaid and root.raids[secondKey].state == movedRaid,
		"pre-commit cancellation must preserve raid identities"
	)
	assertTrue(deepEqual(before, root), "cancelled staged cleanup must preserve canonical archive exactly")
	assertTrue(
		fixture.store:EnsureRaidRuntime(firstRaid) == firstRuntime,
		"pre-commit cancellation must preserve first runtime"
	)
	assertTrue(
		fixture.store:EnsureRaidRuntime(movedRaid) == movedRuntime,
		"pre-commit cancellation must preserve moved runtime"
	)
	assertEqual(
		firstRevision,
		firstRuntime and firstRuntime.syncRevision or nil,
		"pre-commit cancellation changed first revision"
	)
	assertEqual(
		movedRevision,
		movedRuntime and movedRuntime.syncRevision or nil,
		"pre-commit cancellation changed moved revision"
	)
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
	fixture.store.CommitRaidHistoryCleanup = function()
		return nil, "INJECTED_FAILURE"
	end
	local handle = actions:StartRaidHistoryCleanup(function(result, complete)
		callbackCount = callbackCount + 1
		callbackResult, callbackComplete = result, complete
	end, { emptyRaids = true, nonEpicLoot = true, chunkSize = 20, delaySeconds = 0 })
	fixture:AdvanceTime(0)
	fixture.store.CommitRaidHistoryCleanup = originalCommit
	local restoredRaids = deepCopy(fixture.raids)
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
	local root = fixture.archive
	local before = deepCopy(root)
	local originalCommit = fixture.store.CommitRaidHistoryCleanup
	fixture.store.CommitRaidHistoryCleanup = function()
		return nil, "INJECTED_FAILURE"
	end
	local result = actions:CleanupRaidHistory({ emptyRaids = true, nonEpicLoot = true })
	fixture.store.CommitRaidHistoryCleanup = originalCommit
	assertEqual(true, result.failed, "store rejection must fail cleanup")
	assertEqual("INJECTED_FAILURE", result.error)
	assertTrue(root == fixture.archive, "cleanup must preserve archive identity")
	assertTrue(deepEqual(before, root), "failed detached commit must preserve history")
	assertEqual(nil, result.rollbackFailed, "rollback protocol must be absent")
	assertEqual(0, #fixture.events)
	print("PASS logger_cleanup_detached_failure_is_atomic")
end

function cases.logger_cleanup_planning_is_non_mutating(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	fixture.currentRaid = nil
	local root = fixture.archive
	local firstKey, secondKey = root.order[1], root.order[2]
	local firstRecord, secondRecord = root.raids[firstKey], root.raids[secondKey]
	local firstRaid, movedRaid = firstRecord.state, secondRecord.state
	local firstRuntime = fixture.store:EnsureRaidRuntime(firstRaid)
	local movedRuntime = fixture.store:EnsureRaidRuntime(movedRaid)
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
	fixture.store.CommitRaidHistoryCleanup = function()
		return nil, "INJECTED_FAILURE"
	end
	local result = actions:CleanupRaidHistory({ emptyRaids = true, nonEpicLoot = true })
	fixture.store.GetAllRaids = originalGetAll
	fixture.store.CommitRaidHistoryCleanup = originalCommit
	assertEqual(true, result.failed, "rejected cleanup must fail")
	assertEqual("INJECTED_FAILURE", result.error, "rejected cleanup reason differs")
	assertEqual(1, getAllCalls, "cleanup planning should build one detached ordered projection")
	assertTrue(root == fixture.archive, "cleanup planning must preserve archive identity")
	assertTrue(
		root.raids[firstKey] == firstRecord and root.raids[secondKey] == secondRecord,
		"cleanup planning must preserve record identities"
	)
	assertTrue(
		root.raids[firstKey].state == firstRaid and root.raids[secondKey].state == movedRaid,
		"cleanup planning must preserve raid identities"
	)
	assertTrue(deepEqual(before, root), "cleanup planning must preserve canonical archive exactly")
	assertTrue(
		fixture.store:EnsureRaidRuntime(firstRaid) == firstRuntime,
		"cleanup planning must preserve first raid runtime"
	)
	assertTrue(
		fixture.store:EnsureRaidRuntime(movedRaid) == movedRuntime,
		"cleanup planning must preserve active runtime identity"
	)
	assertEqual(firstRevision, firstRuntime and firstRuntime.syncRevision or nil, "first revision changed")
	assertEqual(movedRevision, movedRuntime and movedRuntime.syncRevision or nil, "moved revision changed")
	assertEqual(0, #fixture.events, "rejected planning must not publish")
	print("PASS logger_cleanup_planning_is_non_mutating")
end

function cases.logger_cleanup_noop_preserves_canonical_identities(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local root = fixture.archive
	local firstKey, secondKey = root.order[1], root.order[2]
	local firstRecord, secondRecord = root.raids[firstKey], root.raids[secondKey]
	local firstRaid, secondRaid = firstRecord.state, secondRecord.state
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
	assertTrue(root == fixture.archive, "synchronous no-op must preserve archive identity")
	assertTrue(
		root.raids[firstKey] == firstRecord and root.raids[secondKey] == secondRecord,
		"synchronous no-op must preserve record identities"
	)
	assertTrue(
		root.raids[firstKey].state == firstRaid and root.raids[secondKey].state == secondRaid,
		"synchronous no-op must preserve raid identities"
	)
	assertTrue(
		fixture.store:EnsureRaidRuntime(firstRaid) == firstRuntime,
		"synchronous no-op must preserve first runtime index"
	)
	assertTrue(
		fixture.store:EnsureRaidRuntime(secondRaid) == secondRuntime,
		"synchronous no-op must preserve second runtime index"
	)
	assertTrue(deepEqual(before, root), "synchronous no-op must preserve canonical history exactly")
	assertEqual(firstRevision, fixture.store:GetRaidSyncRevision(firstRaid), "synchronous no-op changed first revision")
	assertEqual(
		secondRevision,
		fixture.store:GetRaidSyncRevision(secondRaid),
		"synchronous no-op changed second revision"
	)
	assertEqual(0, #fixture.events, "synchronous no-op must publish no event")
	print("PASS logger_cleanup_noop_preserves_canonical_identities")
end

function cases.logger_async_cleanup_noop_preserves_canonical_identities(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	fixture.currentRaid = nil
	local root = fixture.archive
	local firstKey, secondKey = root.order[1], root.order[2]
	local firstRecord, secondRecord = root.raids[firstKey], root.raids[secondKey]
	local firstRaid, secondRaid = firstRecord.state, secondRecord.state
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
	assertEqual(1, getAllCalls, "asynchronous no-op should build one detached ordered projection")
	assertEqual(1, callbackCount, "asynchronous no-op callback must run once")
	assertEqual(true, callbackComplete, "asynchronous no-op cleanup must complete")
	assertEqual(true, callbackResult.complete, "asynchronous no-op result must be complete")
	assertEqual(false, callbackResult.changed, "asynchronous no-op cleanup must report no change")
	assertEqual(0, callbackResult.raidsRemoved, "asynchronous no-op cleanup removed raids")
	assertEqual(0, callbackResult.lootRemoved, "asynchronous no-op cleanup removed loot")
	assertEqual(0, #callbackResult.affectedRaidNids, "asynchronous no-op cleanup affected raids")
	assertTrue(root == fixture.archive, "asynchronous no-op must preserve archive identity")
	assertTrue(
		root.raids[firstKey] == firstRecord and root.raids[secondKey] == secondRecord,
		"asynchronous no-op must preserve record identities"
	)
	assertTrue(
		root.raids[firstKey].state == firstRaid and root.raids[secondKey].state == secondRaid,
		"asynchronous no-op must preserve raid identities"
	)
	assertTrue(
		fixture.store:EnsureRaidRuntime(firstRaid) == firstRuntime,
		"asynchronous no-op must preserve first runtime index"
	)
	assertTrue(
		fixture.store:EnsureRaidRuntime(secondRaid) == secondRuntime,
		"asynchronous no-op must preserve second runtime index"
	)
	assertTrue(deepEqual(before, root), "asynchronous no-op must preserve canonical history exactly")
	assertEqual(
		firstRevision,
		fixture.store:GetRaidSyncRevision(firstRaid),
		"asynchronous no-op changed first revision"
	)
	assertEqual(
		secondRevision,
		fixture.store:GetRaidSyncRevision(secondRaid),
		"asynchronous no-op changed second revision"
	)
	assertEqual(0, #fixture.events, "asynchronous no-op must publish no event")
	assertEqual(false, handle:IsCancelled(), "completed asynchronous no-op is not cancelled")
	assertEqual(false, handle:Cancel(), "completed asynchronous no-op must be terminal")
	assertEqual(1, callbackCount, "terminal no-op handle must not call back again")
	print("PASS logger_async_cleanup_noop_preserves_canonical_identities")
end

function cases.raid_store_cleanup_conflict_is_atomic(addon)
	local fixture = installLoggerCleanupFixture(addon)
	local root = fixture.archive
	local firstKey, secondKey = root.order[1], root.order[2]
	local firstRecord, secondRecord = root.raids[firstKey], root.raids[secondKey]
	local firstRaid, secondRaid = firstRecord.state, secondRecord.state
	local firstRuntime = fixture.store:EnsureRaidRuntime(firstRaid)
	local secondRuntime = fixture.store:EnsureRaidRuntime(secondRaid)
	local firstRevision = fixture.store:GetRaidSyncRevision(firstRaid)
	local secondRevision = fixture.store:GetRaidSyncRevision(secondRaid)
	local before = deepCopy(root)
	local committed, reason = fixture.store:CommitRaidHistoryCleanup({
		protectedArchiveKey = secondKey,
		raidCandidates = { { archiveKey = firstKey, baseDigest = "stale-digest" } },
		lootCandidates = {},
	}, secondKey)
	assertEqual(nil, committed, "revision conflict must reject cleanup")
	assertEqual("CONFLICT", reason, "revision conflict reason differs")
	assertTrue(root == fixture.archive, "conflict must preserve archive identity")
	assertTrue(
		root.raids[firstKey] == firstRecord and root.raids[secondKey] == secondRecord,
		"conflict must preserve record identities"
	)
	assertTrue(
		root.raids[firstKey].state == firstRaid and root.raids[secondKey].state == secondRaid,
		"conflict must preserve raid identities"
	)
	assertTrue(fixture.store:EnsureRaidRuntime(firstRaid) == firstRuntime, "conflict must preserve first runtime index")
	assertTrue(
		fixture.store:EnsureRaidRuntime(secondRaid) == secondRuntime,
		"conflict must preserve second runtime index"
	)
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
		function defer:Show()
			self.shown = true
		end
		function defer:Hide()
			self.shown = false
		end
		return defer
	end
	addon.Diag = { E = { LogListUIError = "%s %s" }, W = { LogListUIMissingWidgets = "%s" }, D = {} }
	addon.warn = function() end
	addon.error = function(_, message)
		error(message)
	end
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.UI = {
		Frames = {
			SetScriptSafely = function(frame, name, callback)
				frame[name] = callback
			end,
			HookScriptSafely = function(frame, name, callback)
				frame[name] = callback
			end,
		},
		Rows = {},
		Primitives = {},
	}
	loadAddonFile(addon, "Raid Management Addon/Modules/UI/ListController.lua")
	local refreshCount = 0
	local controller = addon.UI.Lists.CreateController({
		getData = function()
			refreshCount = refreshCount + 1
		end,
	})
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
	assert(fixture.store:ConcludeActiveRaid(fixture.archive.activeRaidUid, fixture.now + 1))
	fixture:GetRaids()
	for i = #fixture.events, 1, -1 do
		fixture.events[i] = nil
	end
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

local function installBossYellFixture(locale, localePath)
	local fixtureAddon = newAddon()
	fixtureAddon.L = {}
	installInitStubs(fixtureAddon)
	_G.GetLocale = function()
		return locale
	end
	loadAddonFile(fixtureAddon, "Raid Management Addon/Localization/localization.en.lua")
	loadAddonFile(fixtureAddon, localePath)

	local activeInstanceKey
	local currentRaid = {}
	local addedBosses = {}
	local combatCall
	fixtureAddon.LootSourcesData = {
		GetActiveInstanceKey = function()
			return activeInstanceKey
		end,
	}
	fixtureAddon.Database.GetCurrentRaid = function()
		return currentRaid
	end
	fixtureAddon.Services.Raid = {
		AddBoss = function(_, boss)
			addedBosses[#addedBosses + 1] = boss
		end,
		COMBAT_LOG_EVENT_UNFILTERED = function(_, ...)
			combatCall = { count = select("#", ...), ... }
		end,
	}
	loadAddonFile(fixtureAddon, "Raid Management Addon/Init.lua")

	return {
		addon = fixtureAddon,
		addedBosses = addedBosses,
		setActiveInstanceKey = function(value)
			activeInstanceKey = value
		end,
		setCurrentRaid = function(value)
			currentRaid = value
		end,
		getCombatCall = function()
			return combatCall
		end,
	}
end

function cases.boss_yells_require_exact_text_and_canonical_instance(addon)
	local localeFiles = {
		{ "ruRU", "Raid Management Addon/Localization/localization.ru.lua" },
		{ "zhCN", "Raid Management Addon/Localization/localization.zhCN.lua" },
		{ "esES", "Raid Management Addon/Localization/localization.es.lua" },
		{ "frFR", "Raid Management Addon/Localization/localization.fr.lua" },
	}
	for localeIndex = 1, #localeFiles do
		local fixture = installBossYellFixture(localeFiles[localeIndex][1], localeFiles[localeIndex][2])
		local definitions = fixture.addon.L.BossYellDefinitions
		assertEqual(15, #definitions, "fallback definition count differs")
		for definitionIndex = 1, #definitions do
			local definition = definitions[definitionIndex]
			fixture.setCurrentRaid({})
			fixture.setActiveInstanceKey(definition.instanceKey)
			local before = #fixture.addedBosses

			fixture.addon:CHAT_MSG_MONSTER_YELL(definition.englishText)
			assertEqual(before + 1, #fixture.addedBosses, "exact English yell was rejected")
			assertEqual(definition.boss, fixture.addedBosses[#fixture.addedBosses])

			fixture.addon:CHAT_MSG_MONSTER_YELL(fixture.addon.L[definition.localeKey])
			assertEqual(before + 2, #fixture.addedBosses, "exact current-locale yell was rejected")
			assertEqual(definition.boss, fixture.addedBosses[#fixture.addedBosses])

			local englishText = definition.englishText
			local rejected = {
				string.lower(englishText),
				englishText .. " ",
				englishText .. "!",
				string.sub(englishText, 1, #englishText - 1),
			}
			for rejectedIndex = 1, #rejected do
				fixture.addon:CHAT_MSG_MONSTER_YELL(rejected[rejectedIndex])
			end
			assertEqual(before + 2, #fixture.addedBosses, "altered yell text was accepted")

			fixture.setActiveInstanceKey(definition.instanceKey == "ulduar" and "naxxramas" or "ulduar")
			fixture.addon:CHAT_MSG_MONSTER_YELL(definition.englishText)
			assertEqual(before + 2, #fixture.addedBosses, "wrong canonical instance accepted yell")

			fixture.setActiveInstanceKey(definition.instanceKey)
			fixture.setCurrentRaid(nil)
			fixture.addon:CHAT_MSG_MONSTER_YELL(fixture.addon.L[definition.localeKey])
			assertEqual(before + 2, #fixture.addedBosses, "missing current raid accepted yell")
		end

		fixture.addon:COMBAT_LOG_EVENT_UNFILTERED("UNIT_DIED", 42, "Boss")
		local combatCall = fixture.getCombatCall()
		assertEqual(3, combatCall.count, "combat-log argument count changed")
		assertEqual("UNIT_DIED", combatCall[1], "combat-log event was not delegated")
		assertEqual(42, combatCall[2], "combat-log numeric argument changed")
		assertEqual("Boss", combatCall[3], "combat-log boss argument changed")
	end
	print("PASS boss_yells_require_exact_text_and_canonical_instance")
end

function cases.localized_raid_identity_uses_instance_map_id(addon)
	addon.LootSourceCandidates = {
		GetModeSignature = function()
			return ""
		end,
	}
	addon.LootSourcesData = { Raw = {} }
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSources/Vanilla.lua")
	loadAddonFile(addon, "Raid Management Addon/Modules/Dataset/LootSources/BurningCrusade.lua")
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
		"karazhan",
		addon.LootSourcesData.ResolveInstanceKey("Tour de Medivh", 532),
		"Burning Crusade raids must use the same locale-independent identity"
	)
	assertEqual(
		"molten core",
		addon.LootSourcesData.ResolveInstanceKey("Icecrown Citadel", 409),
		"recognized map IDs must win over conflicting supported display names"
	)
	assertEqual(
		"icecrown citadel",
		addon.LootSourcesData.ResolveInstanceKey("Icecrown Citadel", nil),
		"English and custom-server name fallback must remain supported"
	)
	assertEqual("icecrown citadel", addon.LootSourcesData.ResolveInstanceKey("Icecrown Citadel", 0))
	assertEqual("icecrown citadel", addon.LootSourcesData.ResolveInstanceKey("Icecrown Citadel", 999999))
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
	local instance = {
		name = "Citadelle de la Couronne de glace",
		instanceType = "raid",
		difficulty = 2,
		mapId = 631,
	}
	addon.L = {
		RaidZones = {},
		MsgRaidInstanceUnsupported = "unsupported raid",
	}
	addon.Diag = {
		D = {
			LogRaidInstanceRecognized = "%s %s",
			LogRaidUnknownInstance = "%s %s %s",
		},
		W = { LogRaidUnmappedZone = "%s %s" },
	}
	addon.warn = function() end
	addon.LootSourcesData = {
		ResolveInstanceKey = function(name, instanceMapId)
			if name == "Citadelle de la Couronne de glace" and instanceMapId == 631 then
				return "icecrown citadel"
			end
		end,
		ActivateInstance = function(key)
			activated.loot = key
			return true
		end,
		DeactivateInstance = function()
			activated.loot = nil
		end,
		GetActiveInstanceKey = function()
			return activated.loot
		end,
		CaptureActivationState = function()
			return { activeInstanceKey = activated.loot }
		end,
		RestoreActivationState = function(snapshot)
			activated.loot = snapshot.activeInstanceKey
			return true
		end,
	}
	addon.IgnoredMobs = {
		ActivateInstance = function(key)
			activated.ignored = key
			return true
		end,
		DeactivateInstance = function()
			activated.ignored = nil
		end,
		GetActiveInstanceKey = function()
			return activated.ignored
		end,
		CaptureActivationState = function()
			return { activeInstanceKey = activated.ignored }
		end,
		RestoreActivationState = function(snapshot)
			activated.ignored = snapshot.activeInstanceKey
			return true
		end,
	}
	_G.GetInstanceInfo = function()
		return instance.name, instance.instanceType, instance.difficulty, nil, 25, 0, false, instance.mapId
	end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	addon:ZONE_CHANGED_NEW_AREA()
	assertEqual("icecrown citadel", activated.loot, "loot dataset must receive the canonical key")
	assertEqual("icecrown citadel", activated.ignored, "ignored-mob dataset must receive the same canonical key")
	instance.name = "Unknown Custom Raid"
	instance.mapId = 999999
	addon:ZONE_CHANGED_NEW_AREA()
	assertEqual(nil, activated.loot, "recognized-to-unknown transition retained the loot key")
	assertEqual(nil, activated.ignored, "recognized-to-unknown transition retained the ignored-mob key")
	print("PASS instance_datasets_share_canonical_identity")
end

function cases.real_roster_runtime_only_change_does_not_publish_nil_delta(addon)
	local fixture = newRaidRecordingFixture(addon)
	fixture.currentRaid = 1
	fixture.inRaid = true
	fixture.raids[1].players = {
		{ playerNid = 1, name = "Alpha", rank = 0, subgroup = 1, class = "WARRIOR", join = fixture.now, countMS = 0 },
	}
	fixture.roster = {
		{ name = "Alpha", rank = 0, subgroup = 1, level = 80, class = "Warrior", online = true },
	}
	local raid = installRealRosterFixture(addon, fixture)
	local delta = raid:RefreshAndPublish()
	assertEqual(nil, delta, "runtime-only roster settlement produced a canonical delta")
	assertEqual(0, #fixture.events, "runtime-only roster settlement published a nil payload")
	print("PASS real_roster_runtime_only_change_does_not_publish_nil_delta")
end

function cases.player_entering_world_remains_registered_for_instance_entry(addon)
	local frame = installInitStubs(addon)
	local scheduledChecks = 0
	addon.LootSourcesData = {
		ResolveInstanceKey = function()
			return nil
		end,
		DeactivateInstance = function() end,
	}
	addon.IgnoredMobs = { DeactivateInstance = function() end }
	addon.Services.Raid = {
		CancelInstanceChecks = function() end,
		CancelTimer = function() end,
		ScheduleTimer = function(_, callback)
			scheduledChecks = scheduledChecks + 1
			return callback
		end,
		CheckInitialRaidState = function() end,
	}
	_G.GetInstanceInfo = function()
		return "Dalaran", "none", 0, nil, 0, 0, false, 571
	end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	addon:RegisterEvent("PLAYER_ENTERING_WORLD")

	frame.OnEvent(frame, "PLAYER_ENTERING_WORLD")
	assertEqual(
		true,
		frame.registered.PLAYER_ENTERING_WORLD,
		"login must keep PLAYER_ENTERING_WORLD registered for later instance transitions"
	)
	assertEqual(1, scheduledChecks, "world entry must schedule a settled-state raid check")
	print("PASS player_entering_world_remains_registered_for_instance_entry")
end

function cases.dataset_activation_requires_snapshot_contract(addon)
	installInitStubs(addon)
	addon.L = { RaidZones = {} }
	addon.Diag = { D = { LogRaidInstanceRecognized = "%s %s" }, W = { LogRaidUnmappedZone = "%s %s" } }
	addon.warn = function() end
	local lootKey
	local ignoredKey
	addon.LootSourcesData = {
		ResolveInstanceKey = function()
			return "icecrown citadel"
		end,
		GetActiveInstanceKey = function()
			return lootKey
		end,
		ActivateInstance = function(key)
			lootKey = key
			return true
		end,
		DeactivateInstance = function()
			lootKey = nil
			return true
		end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function()
			return ignoredKey
		end,
		ActivateInstance = function(key)
			ignoredKey = key
			return true
		end,
		DeactivateInstance = function()
			ignoredKey = nil
			return true
		end,
	}
	_G.GetInstanceInfo = function()
		return "Localized", "raid", 1, nil, 10, 0, false, 631
	end
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
			if failBuild then
				error("injected dataset failure")
			end
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
	assertEqual(
		oldCandidate,
		data.ByItemId[50424] and data.ByItemId[50424][1],
		"attribution identity must remain unchanged"
	)
	print("PASS loot_dataset_build_failure_preserves_active_generation")
end

function cases.loot_dataset_handles_duplicate_nil_and_malformed_entries(addon)
	addon.LootSourceCandidates = {
		GetModeSignature = function()
			return ""
		end,
	}
	addon.LootSourcesData = {
		Raw = {
			{
				name = "Test Raid",
				sources = {
					{ npcId = 7, name = "Boss", kind = "boss", items = { { 100 }, { 100 }, nil, "bad", { nil } } },
					{ npcId = nil, name = "Malformed", items = { { 101 } } },
				},
			},
		},
	}
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
		ResolveInstanceKey = function()
			return "new raid"
		end,
		GetActiveInstanceKey = function()
			return lootKey
		end,
		ActivateInstance = function(key)
			lootKey = key
			return true
		end,
		DeactivateInstance = function()
			lootKey = nil
			return true
		end,
		CaptureActivationState = function()
			return { activeInstanceKey = lootKey }
		end,
		RestoreActivationState = function(snapshot)
			lootKey = snapshot.activeInstanceKey
			return true
		end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function()
			return ignoredKey
		end,
		ActivateInstance = function(key)
			if key == "new raid" then
				error("injected ignored failure")
			end
			ignoredKey = key
			return true
		end,
		DeactivateInstance = function()
			ignoredKey = nil
			return true
		end,
		CaptureActivationState = function()
			return { activeInstanceKey = ignoredKey }
		end,
		RestoreActivationState = function(snapshot)
			ignoredKey = snapshot.activeInstanceKey
			return true
		end,
	}
	_G.GetInstanceInfo = function()
		return "Localized", "raid", 1, nil, 10, 0, false, 999
	end
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
		ResolveInstanceKey = function()
			return "new raid"
		end,
		GetActiveInstanceKey = function()
			return lootKey
		end,
		ActivateInstance = function(key)
			if key == "new raid" then
				return false, "loot-rejected"
			end
			lootKey = key
			return true
		end,
		DeactivateInstance = function()
			lootKey = nil
			return true
		end,
		CaptureActivationState = function()
			return { activeInstanceKey = lootKey }
		end,
		RestoreActivationState = function(snapshot)
			lootKey = snapshot.activeInstanceKey
			return true
		end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function()
			return ignoredKey
		end,
		ActivateInstance = function(key)
			ignoredCalls = ignoredCalls + 1
			ignoredKey = key
			return true
		end,
		DeactivateInstance = function()
			ignoredKey = nil
			return true
		end,
		CaptureActivationState = function()
			return { activeInstanceKey = ignoredKey }
		end,
		RestoreActivationState = function(snapshot)
			ignoredKey = snapshot.activeInstanceKey
			return true
		end,
	}
	_G.GetInstanceInfo = function()
		return "Localized", "raid", 1, nil, 10, 0, false, 999
	end
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
		ResolveInstanceKey = function()
			return "new raid"
		end,
		GetActiveInstanceKey = function()
			return lootKey
		end,
		ActivateInstance = function(key)
			if key == "old raid" and lootKey == "new raid" then
				return false, "rollback-refused"
			end
			lootKey = key
			return true
		end,
		DeactivateInstance = function()
			lootKey = nil
			return true
		end,
		CaptureActivationState = function()
			return { activeInstanceKey = lootKey }
		end,
		RestoreActivationState = function()
			return false
		end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function()
			return ignoredKey
		end,
		ActivateInstance = function(key)
			if key == "new raid" then
				ignoredKey = nil
				return false, "ignored-rejected"
			end
			ignoredKey = key
			return true
		end,
		DeactivateInstance = function()
			ignoredKey = nil
			return true
		end,
		CaptureActivationState = function()
			return { activeInstanceKey = ignoredKey }
		end,
		RestoreActivationState = function(snapshot)
			ignoredKey = snapshot.activeInstanceKey
			return true
		end,
	}
	_G.GetInstanceInfo = function()
		return "Localized", "raid", 1, nil, 10, 0, false, 999
	end
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
	addon.LootSourceCandidates = {
		GetModeSignature = function()
			return ""
		end,
	}
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
	addon.error = function(_, message)
		error(message, 2)
	end
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
	options.RegisterNamespace("Tables", { settings = first })

	local equivalent = { nested = { enabled = true }, mode = "clean" }
	local equivalentOk = pcall(options.RegisterNamespace, "Tables", { settings = equivalent })
	assertEqual(true, equivalentOk, "structurally equivalent table defaults should be accepted")

	local incompatible = { mode = "different", nested = { enabled = true } }
	local incompatibleOk, incompatibleErr = pcall(options.RegisterNamespace, "Tables", { settings = incompatible })
	assertEqual(false, incompatibleOk, "structurally incompatible table defaults should be rejected")
	assertTrue(
		string.find(tostring(incompatibleErr), "has an incompatible declaration", 1, true),
		"incompatible table defaults should retain the stable declaration error"
	)
	print("PASS options_table_default_redeclaration")
end

function cases.options_reject_cyclic_defaults(addon)
	local options = installOptionsStubs(addon)
	local cyclic = { mode = "clean" }
	cyclic.self = cyclic
	local ok, err = pcall(options.RegisterNamespace, "Cyclic", { settings = cyclic })
	assertEqual(false, ok, "cyclic option defaults must be rejected")
	assertContains(err, "Options: cyclic option values are not supported")
	assertEqual(nil, options.Get("Cyclic"), "rejected cyclic namespace must not be registered")
	print("PASS options_reject_cyclic_defaults")
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

	_G.RMA_Raids = {
		formatVersion = 1,
		activeRaidUid = nil,
		order = { "future-schema" },
		raids = { ["future-schema"] = { state = deepCopy(future) } },
	}
	local allBefore = deepCopy(_G.RMA_Raids.raids["future-schema"].state)
	local prepared, prepareError = addon.DB.RaidStore:PrepareAllRaidsForSave()
	assertEqual(nil, prepared, "bulk save preparation should report rejection")
	assertEqual("unsupported raid schema", prepareError, "bulk save preparation should return stable error")
	assertTrue(
		deepEqual(allBefore, _G.RMA_Raids.raids["future-schema"].state),
		"bulk save preparation must preserve future record"
	)
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

	local getRawRaids = addon.DB.RaidStore.GetRawRaids
	addon.DB.RaidStore.GetRawRaids = function()
		return { [2] = raid, mapped = "malformed raid" }
	end
	local report = addon.DB.RaidValidator:ValidateAllRaids({ maxDetails = 200 })
	addon.DB.RaidStore.GetRawRaids = getRawRaids
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
	local readRuntimeName = "GetRaidRuntime" .. "ForRead"
	assertEqual(nil, addon.DB.RaidStore[readRuntimeName], "whole-raid read index API must be absent")

	local queries = addon.DB.RaidQueries
	assertEqual(1, #queries:GetLoot(raid, 1, "Alpha"), "initial query should use current content")
	raid.players[1].name = "Gamma"
	raid.loot[1].looterNid = 2
	addon.DB.RaidStore:UpsertLootIndex(raid, raid.loot[1], 1)
	assertEqual(0, #queries:GetLoot(raid, 1, "Alpha"), "query must observe same-length player and loot changes")
	assertEqual(1, #queries:GetLoot(raid, 1, "Beta"), "query must observe the replacement looter")
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
				return raid.players
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
		local rows = spec.call(raid, raid)
		assertEqual(spec.expected, #rows, "raid-root output alias should return complete query " .. i)
		assertTrue(rows ~= raid, "raid-root output alias should allocate a fresh output table for query " .. i)
		assertTrue(
			rows[1] ~= spec.collection(raid)[1],
			"raid-root output alias should allocate fresh rows for query " .. i
		)
		assertTrue(deepEqual(before, raid), "raid-root output alias must preserve raid for query " .. i)

		raid = canonicalRaidFixture()
		before = deepCopy(raid)
		local canonicalOut = spec.collection(raid)
		rows = spec.call(raid, canonicalOut)
		assertEqual(spec.expected, #rows, "top-level canonical output alias should return complete query " .. i)
		assertTrue(rows ~= canonicalOut, "top-level canonical output alias should be replaced for query " .. i)
		assertTrue(deepEqual(before, raid), "top-level output alias must preserve raid for query " .. i)

		raid = canonicalRaidFixture()
		before = deepCopy(raid)
		local sourceRow = spec.collection(raid)[1]
		local sourceRowOut = { sourceRow }
		rows = spec.call(raid, sourceRowOut)
		assertTrue(rows == sourceRowOut, "caller-owned source-row output table should remain reusable for query " .. i)
		assertTrue(rows[1] ~= sourceRow, "direct source-row reuse should allocate a fresh row for query " .. i)
		assertTrue(deepEqual(before, raid), "direct source-row reuse must preserve raid for query " .. i)

		raid = canonicalRaidFixture()
		local callerOut = { { stale = true }, { stale = true }, { stale = true } }
		rows = spec.call(raid, callerOut)
		assertTrue(rows == callerOut, "caller-owned output table should remain reusable for query " .. i)
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
	table.wipe = table.wipe
		or function(value)
			for key in pairs(value) do
				value[key] = nil
			end
			return value
		end
	_G.GetItemInfo = function(itemRef)
		return tostring(itemRef), "item:" .. tostring(itemRef), nil, nil, nil, nil, nil, nil, nil, "icon"
	end
	addon.L = setmetatable({ StrUnknown = "Unknown" }, {
		__index = function(_, key)
			return key
		end,
	})
	addon.Diag = {
		D = setmetatable({}, {
			__index = function()
				return "%s"
			end,
		}),
		E = setmetatable({}, {
			__index = function()
				return "%s"
			end,
		}),
	}
	addon.C = { RESERVES_ITEM_FALLBACK_ICON = "fallback" }
	addon.Events.Internal = { ReservesDataChanged = "ReservesDataChanged" }
	addon.Bus.TriggerEvent = function(_, ...)
		if fixture.failStage == "event" then
			error("injected event failure")
		end
		fixture.events[#fixture.events + 1] = { ... }
	end
	addon.debug = function()
		if fixture.failStage == "debug" then
			error("injected debug failure")
		end
	end
	addon.info = function()
		if fixture.failStage == "info" then
			error("injected info failure")
		end
	end
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
		NormalizeLower = function(value)
			if type(value) ~= "string" then
				return nil
			end
			return string.lower(value)
		end,
		TrimText = function(value)
			return value
		end,
	}
	addon.Item = {
		GetItemIdFromLink = function(value)
			return tonumber(value)
		end,
	}
	addon.LootSources = {}
	addon.Timer = {
		BindMixin = function(target)
			target.ScheduleTimer = function(_, callback)
				local failure = fixture.scheduleFailures and table.remove(fixture.scheduleFailures, 1)
				if failure == "throw" then
					error("injected schedule failure")
				end
				if failure == "nil" then
					return nil
				end
				local timer = { callback = callback, active = true }
				fixture.timers[#fixture.timers + 1] = timer
				return timer
			end
			target.CancelTimer = function(_, timer)
				if not timer or not timer.active then
					return false
				end
				timer.active = false
				return true
			end
		end,
	}
	addon.Options = {
		IsDebugEnabled = function()
			return fixture.failStage == "debug"
		end,
		RegisterNamespace = function(_, defaults)
			local values = deepCopy(defaults)
			fixture.optionValues = values
			return {
				Get = function(_, key)
					return values[key]
				end,
				Set = function(_, key, value)
					if fixture.failStage == "alias_option" and key == "nameAliases" then
						fixture.failStage = nil
						error("injected alias option failure")
					end
					local old = values[key]
					if old == value then
						return true
					end
					values[key] = value
					if key == "srImportMode" and fixture.optionObserver then
						fixture.optionObserver(key, old, value)
					end
					return true
				end,
			}
		end,
	}
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
	end
	addon.warn = function() end
	addon.error = function(_, message, detail)
		fixture.diagnostics[#fixture.diagnostics + 1] = detail and string.format(message, detail) or tostring(message)
	end
	addon.debug = function() end
	addon.Services.Reserves = {
		_Aliases = {
			CopyAliasMap = function(source)
				local copied = {}
				for key, value in pairs(source or {}) do
					copied[key] = value
				end
				return copied
			end,
			SetAlias = function(target, reserveName, raidName)
				target[string.lower(reserveName)] = raidName
				return true
			end,
			ClearAlias = function(target, reserveName)
				local key = string.lower(reserveName)
				if target[key] == nil then
					return false, "missing_alias"
				end
				target[key] = nil
				return true
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
				if key and data[key] then
					return key
				end
				local reserveKey = key and state.reserveKeyByRaidKey[key] or nil
				return reserveKey and data[reserveKey] and reserveKey or nil
			end,
			GetAliasMatches = function()
				return {}
			end,
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
			GetDisplayList = function()
				return {}
			end,
		},
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Reserves/Import.lua")
	addon.Database.GetCurrentRaid = function()
		return nil
	end
	addon.Database.SavedVariables = {
		GetReserves = function()
			_G.RMA_Reserves = _G.RMA_Reserves or {}
			return _G.RMA_Reserves
		end,
		ReplaceReserves = function(value)
			if fixture.failReplace then
				error("injected reserve persistence failure")
			end
			fixture.saveCount = (fixture.saveCount or 0) + 1
			_G.RMA_Reserves = deepCopy(value or {})
			return _G.RMA_Reserves
		end,
		ClearReserves = function()
			_G.RMA_Reserves = nil
		end,
	}
	_G.RMA_Reserves = {}
	loadAddonFile(addon, "Raid Management Addon/Services/Reserves.lua")
	function fixture:RunTimer(index, includeCancelled)
		local timer = self.timers[index]
		assertTrue(timer ~= nil, "missing reserves fixture timer " .. tostring(index))
		if not timer.active and not includeCancelled then
			return false
		end
		timer.active = false
		timer.callback()
		return true
	end
	return addon.Services.Reserves, fixture
end
