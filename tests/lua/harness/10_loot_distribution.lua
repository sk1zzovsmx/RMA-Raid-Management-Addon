local cases = {}

local function createDistributionSessionFixture(addon, localName)
	local fixture = {
		now = 10,
		authority = "LeaderA",
		failKind = nil,
		failOccurrence = nil,
		kindAttempts = {},
		sent = {},
		events = {},
	}
	local payload = installPayloadCodec(addon)
	_G.GetTime = function()
		return fixture.now
	end
	addon.Database = {
		GetPlayerName = function()
			return localName or "Tester"
		end,
	}
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
	local function recordMessage(prefix, message, channel, target, opts)
		local envelope = payload.Deserialize(message)
		local kind = type(envelope) == "table" and envelope[2] or nil
		local queueName = opts and opts.queueName
		if queueName == nil then
			queueName = tostring(prefix) .. ":" .. tostring(channel) .. ":" .. string.lower(tostring(target or "group"))
		end
		fixture.kindAttempts[kind] = (fixture.kindAttempts[kind] or 0) + 1
		if kind == fixture.failKind and fixture.kindAttempts[kind] == fixture.failOccurrence then
			return false
		end
		fixture.sent[#fixture.sent + 1] = {
			prefix = prefix,
			message = message,
			kind = kind,
			envelope = deepCopy(envelope),
			body = envelope and deepCopy(envelope[5]) or nil,
			channel = channel,
			target = target,
			priority = opts and opts.priority or "NORMAL",
			queueName = queueName,
		}
		return true
	end
	addon.Comms = {
		Payload = payload,
		RegisterPrefixIfAvailable = function()
			return true
		end,
		QueueAddonMessage = function(prefix, message, channel, target, opts)
			return recordMessage(prefix, message, channel, target, opts)
		end,
		QueueAddonMessages = function(prefix, messages, channel, target, opts)
			for i = 1, #messages do
				if not recordMessage(prefix, messages[i], channel, target, opts) then
					return false
				end
			end
			return true
		end,
		SendAddonBatch = function(prefix, messages, target, opts)
			local channel = target and "WHISPER" or "RAID"
			for i = 1, #messages do
				if not recordMessage(prefix, messages[i], channel, target, opts) then
					return false
				end
			end
			return true
		end,
		NormalizeSender = function(value)
			return tostring(value or ""):match("^[^-]+") or ""
		end,
	}
	addon.Item = {
		GetItemKey = function(value)
			return value and tostring(value) or nil
		end,
	}
	addon.Strings = {
		NormalizeText = function(value)
			return value and value ~= "" and tostring(value) or nil
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
		Raid = {
			IsGroupMember = function()
				return true
			end,
			IsLootAuthority = function(_, sender)
				return sender == fixture.authority
			end,
			CanUseCapability = function()
				return true
			end,
		},
		Loot = {},
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Loot/DistributionSession.lua")
	fixture.owner = addon.Services.Loot.DistributionSession
	function fixture:Deliver(kind, body, sender, requestId, target)
		local message = assert(payload.Serialize({ 5, kind, requestId or false, target or false, body }))
		local channel = target and "WHISPER" or "RAID"
		return self.owner.HandleMessage("RMADist", message, channel, sender or self.authority)
	end
	function fixture:SnapshotBody(sessionId, rows)
		return { sessionId, assert(payload.Serialize(rows)) }
	end
	function fixture:CountSent(kind)
		local count = 0
		for i = 1, #self.sent do
			if self.sent[i].kind == kind then
				count = count + 1
			end
		end
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

local function distributionSnapshotRow(itemKey, itemName)
	return {
		itemKey = itemKey,
		count = 1,
		quality = 4,
		itemLink = itemKey,
		itemName = itemName,
		itemTexture = "texture",
		slot = 1,
		state = "active",
		rollType = false,
		duration = false,
		winnerName = false,
		rollValue = false,
		reason = false,
		remaining = false,
		tieNamesText = false,
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
	assertEqual(
		true,
		owner.PublishWindowItems({
			distributionItem("item:1", 1),
			distributionItem("item:2", 2),
			distributionItem("item:3", 3),
		}, retryRevision),
		"complete same-revision retry must commit"
	)
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
	assertR5Envelope(addon, begin.message, "WINDOW_BEGIN")
	assertEqual(0, begin.body[3], "WINDOW_BEGIN must append expected row count")
	local nextRevision = assert(owner.BeginWindow(0))
	assertEqual(endRetryRevision + 1, nextRevision, "successful END retry did not advance revision")
	assertEqual(true, owner.PublishWindowItems({}, nextRevision), "post-retry next revision must commit")
	print("PASS loot_distribution_window_sender_is_atomic")
end

function cases.loot_distribution_window_receiver_is_session_scoped(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:1:10", 1, 1 })
	fixture:Deliver("WINDOW_ITEM", { "LeaderA:1:10", 1, "item:old", 1, 4, "item:old", "Old", "texture", 1 })
	fixture:Deliver("WINDOW_END", { "LeaderA:1:10", 1 })
	local committed = owner.GetDisplayModel()
	assertEqual(1, committed.revision, "initial complete revision did not commit")
	assertEqual("item:old", committed.rows[1].itemKey, "initial row differs")

	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:1:10", 2, 2 })
	fixture:Deliver("WINDOW_ITEM", { "LeaderA:1:10", 2, "item:new", 1, 4, "item:new", "New", "texture", 1 })
	fixture:Deliver("WINDOW_END", { "LeaderA:1:10", 2 })
	assertTrue(deepEqual(committed, owner.GetDisplayModel()), "missing row replaced complete display")

	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:1:10", 2, 1 })
	fixture:Deliver("WINDOW_ITEM", { "LeaderA:1:10", 2, "item:dup", 1, 4, "item:dup", "Dup", "texture", 1 })
	fixture:Deliver("WINDOW_ITEM", { "LeaderA:1:10", 2, "item:dup", 1, 4, "item:dup", "Changed", "texture", 1 })
	fixture:Deliver("WINDOW_END", { "LeaderA:1:10", 2 })
	assertTrue(deepEqual(committed, owner.GetDisplayModel()), "duplicate row replaced complete display")

	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:1:10", 2, 0 })
	fixture:Deliver("WINDOW_END", { "LeaderA:1:10", 2 })
	local empty = owner.GetDisplayModel()
	assertEqual(2, empty.revision, "complete zero-row revision did not commit")
	assertEqual(0, #empty.rows, "zero-row window retained rows")

	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:1:10", 3, 129 })
	fixture:Deliver("WINDOW_ITEM", { "LeaderA:1:10", 3, "item:oversized", 1, 4, "item:oversized", "Oversized", "texture", 1 })
	fixture:Deliver("WINDOW_END", { "LeaderA:1:10", 3 })
	assertTrue(deepEqual(empty, owner.GetDisplayModel()), "oversized expected row count mutated display")

	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:1:10", 2, 1 })
	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:1:10", 4, 1 })
	fixture:Deliver("WINDOW_ITEM", { "LeaderA:1:10", 4, "item:gap", 1, 4, "item:gap", "Gap", "texture", 1 })
	fixture:Deliver("WINDOW_END", { "LeaderA:1:10", 4 })
	assertTrue(deepEqual(empty, owner.GetDisplayModel()), "equal or gapped revision mutated display")
	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:2:20", 1, 0 })
	fixture:Deliver("WINDOW_END", { "LeaderA:2:20", 1 })
	local nextSession = owner.GetDisplayModel()
	assertEqual("LeaderA:2:20", nextSession.sessionId, "same authority could not advance to a new session")
	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:1:10", 3, 0 })
	fixture:Deliver("WINDOW_END", { "LeaderA:1:10", 3 })
	assertTrue(deepEqual(nextSession, owner.GetDisplayModel()), "superseded same-authority session resurrected")

	fixture.authority = "LeaderB"
	fixture:Deliver("WINDOW_BEGIN", { "LeaderB:1:30", 1, 1 }, "LeaderB")
	assertTrue(
		owner._streams["LeaderB|LeaderB:1:30"] and owner._streams["LeaderB|LeaderB:1:30"].window,
		"new authority begin was rejected"
	)
	fixture:Deliver("WINDOW_ITEM", { "LeaderB:1:30", 1, "item:b", 1, 4, "item:b", "B", "texture", 1 }, "LeaderB")
	assertEqual(1, #owner._streams["LeaderB|LeaderB:1:30"].window.order, "new authority row was rejected")
	fixture:Deliver("WINDOW_END", { "LeaderB:1:30", 1 }, "LeaderB")
	local authorityDisplay = owner.GetDisplayModel()
	assertEqual("LeaderB:1:30", authorityDisplay.sessionId, "new authority did not replace session")
	fixture:Deliver("WINDOW_BEGIN", { "LeaderA:3:30", 4, 0 }, "LeaderA")
	fixture:Deliver("WINDOW_END", { "LeaderA:3:30", 4 }, "LeaderA")
	assertTrue(deepEqual(authorityDisplay, owner.GetDisplayModel()), "delayed old-authority window mutated display")
	print("PASS loot_distribution_window_receiver_is_session_scoped")
end

function cases.loot_distribution_snapshot_cannot_resurrect_ended_session(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	fixture:Deliver("WINDOW_BEGIN", { "ended", 1, 1 })
	fixture:Deliver("WINDOW_ITEM", { "ended", 1, "item:old", 1, 4, "item:old", "Old", "texture", 1 })
	fixture:Deliver("WINDOW_END", { "ended", 1 })
	fixture:Deliver("SESSION_END", { "ended", 1 })
	local ended = owner.GetDisplayModel()
	assertEqual(0, #ended.rows, "session end must clear owned display")
	local snapshot = {
		itemKey = "item:resurrect", count = 1, quality = 4, itemLink = "item:resurrect",
		itemName = "Resurrect", itemTexture = "texture", slot = 1, state = "active",
		rollType = false, duration = false, winnerName = false, rollValue = false,
		reason = false, remaining = false, tieNamesText = false,
	}
	fixture:Deliver("SNAP", fixture:SnapshotBody("ended", { snapshot }), nil, "request")
	assertTrue(deepEqual(ended, owner.GetDisplayModel()), "snapshot resurrected ended session")
	fixture:Deliver("WINDOW_BEGIN", { "ended", 2, 0 })
	fixture:Deliver("WINDOW_END", { "ended", 2 })
	assertTrue(deepEqual(ended, owner.GetDisplayModel()), "atomic traffic resurrected tombstoned session")
	fixture:Deliver("ROLL_END", { "ended", "item:old", "Winner", 100, "late" })
	assertTrue(deepEqual(ended, owner.GetDisplayModel()), "late state traffic resurrected tombstoned session")
	print("PASS loot_distribution_snapshot_cannot_resurrect_ended_session")
end

function cases.loot_distribution_r5_snapshot_chunks_and_rejections()
	local leaderAddon = newAddon()
	local receiverAddon = newAddon()
	local leader = createDistributionSessionFixture(leaderAddon, "LeaderA")
	local receiver = createDistributionSessionFixture(receiverAddon, "Follower")
	for i = 1, 24 do
		local text = {}
		for j = 1, 12 do
			text[j] = string.char(33 + ((i * 37 + j * 53) % 90))
		end
		local suffix = table.concat(text)
		assertTrue(leader.owner.PublishItem({
			itemKey = "item:r5:" .. tostring(i),
			itemLink = "item:r5:" .. tostring(i) .. ":" .. suffix,
			itemName = "R5 item " .. tostring(i) .. " " .. suffix,
			itemTexture = "Interface\\Icons\\R5_" .. tostring(i) .. suffix,
			count = (i % 3) + 1,
			quality = 4,
			slot = i,
		}), "distribution fixture item did not publish")
	end
	local expected = leader.owner.GetDisplayModel()
	for key in pairs(leader.sent) do
		leader.sent[key] = nil
	end
	local snapshotRequestId = assert(receiver.owner.RequestSnapshot())
	assertTrue(leader.owner.PublishSnapshot("Follower", snapshotRequestId), "R5 snapshot did not publish")
	assertTrue(#leader.sent > 1, "distribution snapshot did not exercise chunking")
	local queueName
	for i = 1, #leader.sent do
		local sent = leader.sent[i]
		local raw = assertR5Envelope(leaderAddon, sent.message, "SNAP_CHUNK")
		assertEqual("NORMAL", sent.priority, "distribution chunk priority differs")
		queueName = queueName or sent.queueName
		assertEqual(queueName, sent.queueName, "distribution chunk queue changed")
		assertEqual(snapshotRequestId, raw[3], "distribution snapshot request differs")
		assertEqual("Follower", raw[4], "distribution snapshot target differs")
		assertTrue(#sent.message <= 243, "distribution chunk exceeded the addon wire limit")
	end
	for i = #leader.sent, 1, -1 do
		assertTrue(receiver.owner.HandleMessage("RMADist", leader.sent[i].message, "WHISPER", "LeaderA"))
	end
	local actual = receiver.owner.GetDisplayModel()
	assertEqual(expected.sessionId, actual.sessionId, "out-of-order distribution snapshot session differs")
	assertEqual(#expected.rows, #actual.rows, "out-of-order distribution snapshot row count differs")
	for i = 1, #expected.rows do
		for _, field in ipairs({
			"itemKey", "count", "quality", "itemLink", "itemName", "itemTexture", "slot", "state",
			"rollType", "duration", "winnerName", "rollValue", "reason", "remaining", "tieNamesText",
		}) do
			assertEqual(expected.rows[i][field], actual.rows[i][field], "distribution snapshot field differs: " .. field)
		end
	end

	local before = receiver.owner.GetDisplayModel()
	local codec = receiverAddon.Comms.Payload
	local invalid = {
		assert(codec.Serialize({ 4, "CLEAR", false, false, { sessionId = "bad-version" } })),
		assert(codec.Serialize({ [1] = 5, [2] = "CLEAR", [3] = false, [5] = { sessionId = "sparse" } })),
		assert(codec.Serialize({ 5, "NOT_A_KIND", false, false, {} })),
		assert(codec.Serialize({ 5, "SNAP_CHUNK", "too-many", "Follower", { before.sessionId, 1, 65, "x" } })),
		assert(codec.Serialize({ 5, "SNAP_CHUNK", "oversized", "Follower", { before.sessionId, 1, 1, string.rep("x", 181) } })),
		"\001malformed",
		"CLEAR|2|legacy",
	}
	for i = 1, #invalid do
		receiver.owner.HandleMessage("RMADist", invalid[i], "WHISPER", "LeaderA")
		assertTrue(deepEqual(before, receiver.owner.GetDisplayModel()), "invalid distribution message mutated state " .. i)
	end
	assertEqual(nil, next(receiver.owner._incomingSnapshots), "invalid distribution chunks allocated assembly state")
	print("PASS loot_distribution_r5_snapshot_chunks_and_rejections")
end

function cases.loot_distribution_ordered_flow_uses_one_normal_queue()
	local fixture = createDistributionSessionFixture(newAddon(), "LeaderA")
	local owner = fixture.owner
	assertTrue(owner.Clear(), "ordered flow clear failed")
	assertTrue(owner.PublishItem(distributionItem("item:ordered", 1)), "ordered flow item failed")
	local revision = assert(owner.BeginWindow(1))
	assertTrue(owner.PublishWindowItems({ distributionItem("item:ordered", 1) }, revision), "ordered flow window failed")
	assertTrue(owner.PublishRollStart("item:ordered", 1, 30), "ordered flow roll start failed")
	assertTrue(owner.PublishTieStart("item:ordered", { "Alpha", "Bravo" }), "ordered flow tie failed")
	assertTrue(owner.PublishRollEnd("item:ordered", "Alpha", 99, "ms"), "ordered flow roll end failed")
	assertTrue(owner.PublishItemDone("item:ordered", "Alpha"), "ordered flow completion failed")

	local requestId = assert(owner.RequestSnapshot())
	assertTrue(owner.PublishSnapshot("Follower", requestId), "ordered flow snapshot failed")
	assertTrue(owner.PublishSessionEnd(), "ordered flow session end failed")

	local groupQueue
	local snapshotQueue
	for i = 1, #fixture.sent do
		local sent = fixture.sent[i]
		if sent.kind == "SNAP_REQ" or sent.kind == "HELLO" then
			assertEqual("ALERT", sent.priority, sent.kind .. " must remain out-of-band")
		else
			assertEqual("NORMAL", sent.priority, sent.kind .. " crossed the ordered state queue")
			if sent.target then
				snapshotQueue = snapshotQueue or sent.queueName
				assertEqual(snapshotQueue, sent.queueName, "snapshot response queue changed")
			else
				groupQueue = groupQueue or sent.queueName
				assertEqual(groupQueue, sent.queueName, "ordered group mutation queue changed")
			end
		end
		assertTrue(sent.priority ~= "BULK", sent.kind .. " used a reorderable BULK classification")
	end
	assertTrue(groupQueue ~= nil, "ordered group flow did not enqueue")
	assertTrue(snapshotQueue ~= nil, "ordered snapshot flow did not enqueue")
	print("PASS loot_distribution_ordered_flow_uses_one_normal_queue")
end

function cases.loot_distribution_r5_rejects_invalid_body_scalars()
	local addon = newAddon()
	local fixture = createDistributionSessionFixture(addon, "Follower")
	local owner = fixture.owner
	fixture:Deliver("CLEAR", { sessionId = "scalar-session" })
	local beforeRoll = owner.GetDisplayModel()
	local invalidRoll = assert(addon.Comms.Payload.Serialize({
		5,
		"ROLL_START",
		false,
		false,
		{ "scalar-session", "item:invalid-roll", {}, 30 },
	}))
	owner.HandleMessage("RMADist", invalidRoll, "RAID", "LeaderA")
	assertTrue(deepEqual(beforeRoll, owner.GetDisplayModel()), "table roll type mutated distribution state")

	local malformedRows = {
		{
			itemKey = "item:invalid-snapshot",
			count = "many",
			quality = 4,
			itemLink = "item:invalid-snapshot",
			itemName = {},
			itemTexture = "texture",
			slot = 1,
			state = "active",
			rollType = false,
			duration = false,
			winnerName = false,
			rollValue = false,
			reason = false,
			remaining = false,
			tieNamesText = false,
		},
	}
	local malformedRequest = assert(owner.RequestSnapshot())
	local malformedEncoded = assert(addon.Comms.Payload.Serialize(malformedRows))
	local malformedChunkSize = 80
	local malformedChunkCount = math.ceil(#malformedEncoded / malformedChunkSize)
	local beforeSnapshot = owner.GetDisplayModel()
	for index = 1, malformedChunkCount do
		local malformedSnapshotChunk = assert(addon.Comms.Payload.Serialize({
			5,
			"SNAP_CHUNK",
			malformedRequest,
			"Follower",
			{
				"scalar-session",
				index,
				malformedChunkCount,
				string.sub(malformedEncoded, ((index - 1) * malformedChunkSize) + 1, index * malformedChunkSize),
			},
		}))
		owner.HandleMessage("RMADist", malformedSnapshotChunk, "WHISPER", "LeaderA")
	end
	assertTrue(deepEqual(beforeSnapshot, owner.GetDisplayModel()), "malformed snapshot scalars mutated state")
	print("PASS loot_distribution_r5_rejects_invalid_body_scalars")
end

function cases.loot_distribution_snapshot_requests_are_correlated_and_bounded()
	local addon = newAddon()
	local fixture = createDistributionSessionFixture(addon, "Follower")
	local owner = fixture.owner
	local payload = addon.Comms.Payload
	fixture:Deliver("CLEAR", { sessionId = "unsolicited-session" })
	local unsolicited = assert(payload.Serialize({
		5,
		"SNAP_CHUNK",
		"not-requested",
		"Follower",
		{ "unsolicited-session", 1, 2, "x" },
	}))
	local before = owner.GetDisplayModel()
	owner.HandleMessage("RMADist", unsolicited, "WHISPER", "LeaderA")
	assertTrue(deepEqual(before, owner.GetDisplayModel()), "unsolicited snapshot mutated distribution state")
	assertEqual(nil, next(owner._incomingSnapshots), "unsolicited snapshot allocated assembly state")

	local perSenderIds = {}
	for i = 1, 5 do
		perSenderIds[i] = assert(owner.RequestSnapshot())
	end
	for i = 1, #perSenderIds do
		local chunk = assert(payload.Serialize({
			5,
			"SNAP_CHUNK",
			perSenderIds[i],
			"Follower",
			{ "unsolicited-session", 1, 2, "x" },
		}))
		owner.HandleMessage("RMADist", chunk, "WHISPER", "LeaderA")
	end
	local perSenderCount = 0
	for _ in pairs(owner._incomingSnapshots) do
		perSenderCount = perSenderCount + 1
	end
	assertEqual(4, perSenderCount, "per-sender snapshot assembly cap differs")
	assertEqual(nil, owner._pendingSnapshots[perSenderIds[5]], "per-sender overflow retained pending state")

	local globalAddon = newAddon()
	local globalFixture = createDistributionSessionFixture(globalAddon, "Follower")
	local globalOwner = globalFixture.owner
	local globalPayload = globalAddon.Comms.Payload
	local globalIds = {}
	for i = 1, 17 do
		globalIds[i] = assert(globalOwner.RequestSnapshot())
		local sender = "Leader" .. tostring(i)
		globalFixture.authority = sender
		local chunk = assert(globalPayload.Serialize({
			5,
			"SNAP_CHUNK",
			globalIds[i],
			"Follower",
			{ "global-capacity", 1, 2, "x" },
		}))
		globalOwner.HandleMessage("RMADist", chunk, "WHISPER", sender)
	end
	local globalCount = 0
	for _ in pairs(globalOwner._incomingSnapshots) do
		globalCount = globalCount + 1
	end
	assertEqual(16, globalCount, "global snapshot assembly cap differs")
	assertEqual(nil, globalOwner._pendingSnapshots[globalIds[17]], "global overflow retained pending state")
	print("PASS loot_distribution_snapshot_requests_are_correlated_and_bounded")
end

function cases.loot_distribution_clear_requires_ordered_owner_transition(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	local function commit(sessionId, revision, itemKey)
		fixture:Deliver("WINDOW_BEGIN", { sessionId, revision, 1 })
		fixture:Deliver("WINDOW_ITEM", { sessionId, revision, itemKey, 1, 4, itemKey, "Item", "texture", 1 })
		fixture:Deliver("WINDOW_END", { sessionId, revision })
	end
	commit("LeaderA:3:30", 1, "item:c")
	local ownerC = owner.GetDisplayModel()
	fixture:Deliver("CLEAR", { sessionId = "LeaderA:2:20" })
	assertTrue(deepEqual(ownerC, owner.GetDisplayModel()), "delayed CLEAR replaced the newer owner")
	local rejectedRequest = assert(owner.RequestSnapshot())
	fixture:Deliver(
		"SNAP",
		fixture:SnapshotBody("LeaderA:4:40", { distributionSnapshotRow("item:snap", "Snap") }),
		nil,
		rejectedRequest
	)
	assertTrue(deepEqual(ownerC, owner.GetDisplayModel()), "snapshot changed session without an explicit transition")
	fixture:Deliver("CLEAR", { sessionId = "LeaderA:4:40" })
	local cleared = owner.GetDisplayModel()
	assertEqual("LeaderA:4:40", cleared.sessionId, "newer ordered CLEAR did not transition session")
	local acceptedRequest = assert(owner.RequestSnapshot())
	fixture:Deliver(
		"SNAP",
		fixture:SnapshotBody("LeaderA:4:40", { distributionSnapshotRow("item:snap", "Snap") }),
		nil,
		acceptedRequest
	)
	local snapshotOwner = owner.GetDisplayModel()
	assertEqual("item:snap", snapshotOwner.rows[1].itemKey, "snapshot after explicit CLEAR did not apply")
	fixture:Deliver("CLEAR", { sessionId = "LeaderA:5:50" })
	local afterSnapshotClear = owner.GetDisplayModel()
	fixture:Deliver(
		"SNAP",
		fixture:SnapshotBody("LeaderA:4:40", { distributionSnapshotRow("item:late", "Late") }),
		nil,
		"late"
	)
	assertTrue(deepEqual(afterSnapshotClear, owner.GetDisplayModel()), "superseded snapshot-only owner resurrected")
	print("PASS loot_distribution_clear_requires_ordered_owner_transition")
end

function cases.loot_distribution_generated_session_order_is_validated(addon)
	local fixture = createDistributionSessionFixture(addon)
	local owner = fixture.owner
	fixture.authority = "Authority"
	local function commit(sessionId, revision, itemKey)
		fixture:Deliver("WINDOW_BEGIN", { sessionId, revision, 1 })
		fixture:Deliver("WINDOW_ITEM", { sessionId, revision, itemKey, 1, 4, itemKey, "Item", "texture", 1 })
		fixture:Deliver("WINDOW_END", { sessionId, revision })
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
		fixture:Deliver("WINDOW_BEGIN", { sessionId, 1, 0 })
		fixture:Deliver("WINDOW_END", { sessionId, 1 })
		assertTrue(
			deepEqual(current, owner.GetDisplayModel()),
			"invalid generated window replaced current session: " .. sessionId
		)
		fixture:Deliver("CLEAR", { sessionId = sessionId })
		assertTrue(
			deepEqual(current, owner.GetDisplayModel()),
			"invalid generated CLEAR replaced current session: " .. sessionId
		)
	end
	fixture.authority = "NextAuthority"
	fixture:Deliver("CLEAR", { sessionId = "Other:1:101" }, "NextAuthority")
	assertTrue(
		deepEqual(current, owner.GetDisplayModel()),
		"new authority admitted a session ID owned by another sender"
	)
	fixture.authority = "Authority"

	fixture:Deliver("CLEAR", { sessionId = "Authority:2:101" })
	local newer = owner.GetDisplayModel()
	assertEqual("Authority:2:101", newer.sessionId, "newer timestamp did not replace current session")
	fixture:Deliver("CLEAR", { sessionId = "Authority:1:101" })
	assertTrue(deepEqual(newer, owner.GetDisplayModel()), "lower ordinal replaced session at the same timestamp")
	fixture:Deliver("CLEAR", { sessionId = "Authority:3:101" })
	assertEqual(
		"Authority:3:101",
		owner.GetDisplayModel().sessionId,
		"higher ordinal did not replace session at the same timestamp"
	)
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
	fixture:Deliver("CLEAR", { sessionId = "NewLeader:1:20" }, "NewLeader")
	assertEqual(
		"NewLeader:1:20",
		owner.GetDisplayModel().sessionId,
		"new authority CLEAR was rejected without owner provenance"
	)
	fixture:Deliver("WINDOW_BEGIN", { "NewLeader:2:30", 1, 1 }, "NewLeader")
	fixture:Deliver("WINDOW_ITEM", { "NewLeader:2:30", 1, "item:new", 1, 4, "item:new", "New", "texture", 1 }, "NewLeader")
	fixture:Deliver("WINDOW_END", { "NewLeader:2:30", 1 }, "NewLeader")
	local active = owner.GetDisplayModel()
	assertEqual("NewLeader:2:30", active.sessionId, "new authority window did not become active")
	assertEqual("item:new", active.rows[1].itemKey, "new authority window row differs")

	fixture:Deliver("CLEAR", { sessionId = "NewLeader:1:29" }, "NewLeader")
	assertTrue(deepEqual(active, owner.GetDisplayModel()), "older same-authority candidate replaced active session")
	fixture:Deliver("CLEAR", { sessionId = "NewLeader:invalid" }, "NewLeader")
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
	_G.table.wipe = _G.table.wipe
		or function(target)
			for key in pairs(target) do
				target[key] = nil
			end
			return target
		end
	_G.GetLootThreshold = function()
		return 2
	end
	_G.GetNumLootItems = function()
		return 0
	end
	addon.C = { itemColors = {}, rollTypes = {}, RESERVES_ITEM_FALLBACK_ICON = "fallback" }
	addon.L = {}
	addon.Diag = { D = setmetatable({}, {
		__index = function()
			return "%s %s %s %s"
		end,
	}) }
	addon.Events = {
		Internal = {
			RaidLootUpdate = "RaidLootUpdate",
			SetItem = "SetItem",
			LootDistributionSessionChanged = "LootDistributionSessionChanged",
		},
	}
	addon.Bus = { TriggerEvent = function() end, RegisterCallback = function() end }
	addon.Deformat = function() end
	addon.Options = {
		GetValue = function()
			return false
		end,
		NormalizeLoggerLootQualityThreshold = function(value)
			return tonumber(value) or 2
		end,
	}
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
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleTimer()
				return {}
			end
			function target:CancelTimer()
				return true
			end
		end,
	}
	addon.Item = {
		GetItemStringFromLink = function(value)
			return value
		end,
		GetItemIdFromLink = function()
			return 1
		end,
		GetItemKey = function(value)
			return value
		end,
	}
	addon.Database = {
		EnsureLootRuntimeState = function()
			return {}, lootState, itemInfo, raidState
		end,
		GetCurrentRaid = function()
			return 1
		end,
		GetPlayerName = function()
			return "Tester"
		end,
		GetRaidQueries = function()
			return { ResolveLootLooterName = function() end }
		end,
	}
	local noopOwner = setmetatable({}, {
		__index = function()
			return function() end
		end,
	})
	local distribution = {
		BeginWindow = function()
			return beginResult, beginReason
		end,
		PublishWindowItems = function()
			publishCalls = publishCalls + 1
			return publishResult, publishReason
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
		Loot = {
			LootAttribution = noopOwner,
			_PassiveGroupLoot = noopOwner,
			_Tracking = noopOwner,
			_Workflow = setmetatable({ BeginLootWindow = function() end }, getmetatable(noopOwner)),
			_Recording = noopOwner,
			_Rules = {
				_IsIgnoredItem = function()
					return false
				end,
			},
			AwardPlanner = noopOwner,
			Inventory = noopOwner,
			DistributionSession = distribution,
			_Context = {
				ResolveRaidRecord = function()
					return nil
				end,
			},
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
	_G.GetTime = function()
		return 10
	end
	addon.Database = {
		GetPlayerName = function()
			return "Tester"
		end,
	}
	addon.Diag = {}
	addon.Events = { Internal = { LootDistributionSessionChanged = "LootDistributionSessionChanged" } }
	addon.Bus = {
		TriggerEvent = function(_, reason, row)
			events[#events + 1] = { reason = reason, row = row }
		end,
	}
	installPayloadCodec(addon)
	addon.Comms.RegisterPrefixIfAvailable = function()
			return true
		end
	addon.Comms.SendAddonBatch = function()
			sends = sends + 1
			return sends > 1
		end
	addon.Comms.QueueAddonMessage = function()
			return true
		end
	addon.Comms.QueueAddonMessages = function()
			return true
		end
	addon.Comms.NormalizeSender = function(value)
			return tostring(value or ""):match("^[^-]+") or ""
		end
	addon.Item = {
		GetItemKey = function(value)
			return value
		end,
	}
	addon.Strings = {
		NormalizeText = function(value)
			return value and tostring(value) or nil
		end,
	}
	addon.Services = {
		EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end,
		Raid = {
			IsGroupMember = function()
				return true
			end,
			IsLootAuthority = function()
				return true
			end,
			CanUseCapability = function()
				return true
			end,
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

function cases.loot_distribution_remote_final_award_is_complete_and_idempotent(addon)
	local fixture = createDistributionSessionFixture(addon)
	fixture:Deliver("ITEM", { "LeaderA:1:10", "item:19019", 3, 4, "item:19019", "Thunderfury", "texture", 1 })
	fixture:Deliver("ROLL_START", { "LeaderA:1:10", "item:19019", 1, false })
	fixture:Deliver("ROLL_END", { "LeaderA:1:10", "item:19019", "Winner", 99, "master_loot:AT:1" })
	fixture:Deliver("ITEM_DONE", { "LeaderA:1:10", "item:19019", "Winner" })
	local doneEvents = 0
	local final
	for i = 1, #fixture.events do
		if fixture.events[i].reason == "item_done" then
			doneEvents = doneEvents + 1
			final = fixture.events[i]
		end
	end
	assertEqual(1, doneEvents, "first final award notification count differs")
	assertEqual("LeaderA:1:10", final.sessionId, "final award session differs")
	assertEqual("LeaderA", final.row.sender, "final award sender differs")
	assertEqual("item:19019", final.row.itemLink, "final award item link differs")
	assertEqual(3, final.row.count, "final award count differs")
	assertEqual(1, final.row.rollType, "final award roll type differs")
	assertEqual(99, final.row.rollValue, "final award roll value differs")
	assertEqual("master_loot:AT:1", final.row.reason, "final award transaction reason differs")
	assertEqual("Winner", final.row.winnerName, "final award winner differs")

	fixture:Deliver("ITEM_DONE", { "LeaderA:1:10", "item:19019", "Winner" })
	doneEvents = 0
	local replayEvents = 0
	for i = 1, #fixture.events do
		if fixture.events[i].reason == "item_done" then
			doneEvents = doneEvents + 1
		end
		if fixture.events[i].reason == "item_done_replay" then
			replayEvents = replayEvents + 1
		end
	end
	assertEqual(1, doneEvents, "duplicate remote ITEM_DONE repeated final state")
	assertEqual(1, replayEvents, "duplicate remote ITEM_DONE did not expose a retry-safe final fact")
	print("PASS loot_distribution_remote_final_award_is_complete_and_idempotent")
end

function cases.loot_master_split_authority_publishes_final_facts_without_local_writes(addon)
	local fixture = installLootHardeningMasterFixture(addon, { canonicalAuthority = false })
	assertTrue(fixture.awardSequence:TrySingleCopy("item:19019", "Winner"), "split-authority award did not start")
	assertTrue(fixture.master._awardConfirmation:Confirm(1), "split-authority award did not confirm")
	assertEqual(1, fixture.itemPublications or 0, "confirmed award did not publish item facts")
	assertEqual(1, fixture.rollStartCalls or 0, "confirmed award did not publish roll facts")
	assertEqual(1, fixture.rollEndCalls or 0, "confirmed award did not publish winner facts")
	assertEqual(1, fixture.distributionCalls, "confirmed award did not publish terminal facts")
	assertEqual(1, fixture.lastPublishedItem and fixture.lastPublishedItem.count, "master-loot award count differs")
	assertEqual(4, fixture.lastPublishedRollType, "master-loot award roll type differs")
	assertTrue(
		type(fixture.lastPublishedReason) == "string"
			and string.find(fixture.lastPublishedReason, "master_loot:AT:", 1, true) == 1,
		"master-loot award did not publish a transaction identity"
	)
	assertTrue(
		deepEqual({ "ITEM", "ROLL_START", "ROLL_END", "ITEM_DONE" }, fixture.publicationOrder),
		"confirmed award fact order differs"
	)
	assertEqual(0, fixture.counterCalls, "non-authoritative master looter mutated the canonical counter")
	print("PASS loot_master_split_authority_publishes_final_facts_without_local_writes")
end

function cases.loot_master_split_authority_cancels_local_delayed_attribution(addon)
	local function pendingCount(fixture)
		local count = 0
		for _, list in pairs(fixture.lootState.pendingAwards or {}) do
			count = count + #list
		end
		return count
	end

	local split = installLootHardeningMasterFixture(addon, {
		realLootFlow = true,
		canonicalAuthority = false,
	})
	local rejectedCanonicalWrites = 0
	split.lootStore.CommitAuthoritativeEvent = function()
		rejectedCanonicalWrites = rejectedCanonicalWrites + 1
		return nil, "NOT_RAID_LEADER"
	end
	assertTrue(split.awardSequence:TrySingleCopy("item:19019", "Winner"), "split real award did not start")
	assertTrue(split.master._awardConfirmation:Confirm(1), "split real award did not confirm")
	split.runScheduledTimers()
	assertEqual(0, split.realProvisionalConfirmCalls or 0, "split ML entered local provisional attribution")
	assertEqual(0, pendingCount(split), "split ML retained a local pending attribution")
	assertEqual(0, rejectedCanonicalWrites, "split ML attempted a delayed canonical write")
	assertEqual(0, #split.raid.loot, "split ML appended local canonical loot")
	assertEqual(0, split.warningCount, "split ML emitted a false attribution warning")
	assertEqual(1, split.distributionCalls, "split ML did not publish the terminal award fact")

	local nonRaid = installLootHardeningMasterFixture(newAddon(), {
		realLootFlow = true,
		canonicalAuthority = false,
	})
	nonRaid.addon.Database.GetCurrentRaid = function()
		return nil
	end
	assertTrue(nonRaid.awardSequence:TrySingleCopy("item:19019", "Winner"), "non-raid real award did not start")
	assertTrue(nonRaid.master._awardConfirmation:Confirm(1), "non-raid real award did not confirm")
	assertEqual(1, nonRaid.realProvisionalConfirmCalls or 0, "non-raid award lost local provisional attribution")
	nonRaid.runScheduledTimers()
	assertEqual(1, #nonRaid.raid.loot, "non-raid delayed attribution no longer finalized")
	assertEqual(0, nonRaid.warningCount, "non-raid delayed attribution warned unexpectedly")
	print("PASS loot_master_split_authority_cancels_local_delayed_attribution")
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
				assertEqual(
					true,
					attempt:RunCheckpoint("publish", function()
						publishCalls = publishCalls + 1
						return true
					end),
					"successful checkpoint must commit"
				)
				reentrantConfirm = attempt:Confirm()
				reentrantFail = attempt:Fail("reentrant")
				return nil, "confirmation_rejected"
			end
			assertEqual(
				true,
				attempt:RunCheckpoint("publish", function()
					publishCalls = publishCalls + 1
					return true
				end),
				"retry must accept completed checkpoint"
			)
			return true
		end,
	})

	local throwOk, throwReason = attempt:RunCheckpoint("throw", function()
		error("checkpoint exploded")
	end)
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
	assertTrue(
		tostring(failedReason):find("failure callback exploded", 1, true) ~= nil,
		"failure callback reason missing"
	)
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
	assertEqual(
		true,
		attempt:RunCheckpoint("publish", function()
			return true
		end),
		"checkpoint must complete"
	)
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
			if confirmCalls == 1 then
				return nil, "effect_rejected"
			end
			return true
		end,
	})
	local confirmation = addon.Services.Master.AwardConfirmation.Create({
		timeoutSeconds = 4,
		scheduleTimer = function(callback)
			scheduled[#scheduled + 1] = callback
			return callback
		end,
		cancelTimer = function()
			cancelled = cancelled + 1
		end,
		requestRefresh = function()
			refreshes = refreshes + 1
		end,
		warnFailure = function()
			warnings = warnings + 1
		end,
		warnUncertain = function()
			warnings = warnings + 1
		end,
		warnTimeout = function()
			warnings = warnings + 1
		end,
		warnUnresolved = function()
			warnings = warnings + 1
		end,
		onUnresolved = function() end,
		confirmProvisional = function()
			provisionalCalls = provisionalCalls + 1
			return true
		end,
	})
	assertTrue(
		confirmation:Queue({ itemLink = "item:19019", itemIndex = 1, playerName = "Winner", effect = effect }),
		"confirmation must queue"
	)
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

	local timeoutEffect = addon.Services.Master.AwardAttempt.CreateExecuting({
		onConfirm = function()
			return true
		end,
	})
	assertTrue(
		confirmation:Queue({ itemLink = "item:2", itemIndex = 2, playerName = "Runner", effect = timeoutEffect }),
		"timeout confirmation must queue"
	)
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
	"PARTY_LOOT_METHOD_CHANGED",
	"PLAYER_LOGOUT",
}
