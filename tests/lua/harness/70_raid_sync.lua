local function installRaidTransferSessionFixture(addon, options)
	options = options or {}
	local fixture = {
		now = 100,
		queued = {},
		batches = {},
		timers = {},
		cancelled = {},
		nextRequest = 0,
		channelEncodeCalls = 0,
		channelDecodeCalls = 0,
		deflateCalls = 0,
		protocolEncodeBodyCalls = 0,
		protocolDecodeBodyCalls = 0,
	}
	_G.GetTime = function()
		return fixture.now
	end
	_G.UnitName = function(unit)
		if unit == "player" then
			return options.playerName or "Tester"
		end
	end
	local transferLibStub = function(name)
		assertEqual("LibDeflate", name)
		return {
			CompressDeflate = function()
				fixture.deflateCalls = fixture.deflateCalls + 1
				error("Deflate compression must never be called")
			end,
			DecompressDeflate = function()
				fixture.deflateCalls = fixture.deflateCalls + 1
				error("Deflate decompression must never be called")
			end,
			EncodeForWoWAddonChannel = function(_, text)
				fixture.channelEncodeCalls = fixture.channelEncodeCalls + 1
				if options.safeChannelEncoding then
					return (
						string.gsub(text, ".", function(character)
							return string.format("%02x", string.byte(character))
						end)
					)
				end
				return text
			end,
			DecodeForWoWAddonChannel = function(_, text)
				fixture.channelDecodeCalls = fixture.channelDecodeCalls + 1
				if fixture.decodedText then
					return fixture.decodedText
				end
				if options.safeChannelEncoding then
					return (
						string.gsub(text, "(%x%x)", function(pair)
							return string.char(tonumber(pair, 16))
						end)
					)
				end
				return text
			end,
		}
	end
	addon.Timer = {
		BindMixin = function(target)
			target.ScheduleTimer = function(_, callback, delay)
				local handle = { callback = callback, delay = delay }
				fixture.timers[#fixture.timers + 1] = handle
				return handle
			end
			target.CancelTimer = function(_, handle)
				if not handle or handle.cancelled then
					return false
				end
				handle.cancelled = true
				fixture.cancelled[#fixture.cancelled + 1] = handle
				return true
			end
		end,
	}
	local protocol = installRaidReplicationProtocolFixture(addon)
	local encodeBody = protocol.EncodeBody
	protocol.EncodeBody = function(...)
		fixture.protocolEncodeBodyCalls = fixture.protocolEncodeBodyCalls + 1
		return encodeBody(...)
	end
	local decodeBody = protocol.DecodeBody
	protocol.DecodeBody = function(...)
		fixture.protocolDecodeBodyCalls = fixture.protocolDecodeBodyCalls + 1
		return decodeBody(...)
	end
	_G.LibStub = transferLibStub
	addon.Comms.NormalizeSender = function(value)
		return string.lower(string.match(tostring(value or ""), "^([^%-]+)") or tostring(value or ""))
	end
	addon.Comms.QueueAddonMessage = function(prefix, message, channel, target, opts)
		if options.rejectSingle then
			return false, "backpressure"
		end
		fixture.queued[#fixture.queued + 1] = {
			prefix = prefix,
			message = message,
			channel = channel,
			target = target,
			priority = opts and opts.priority or "NORMAL",
			queueName = opts and opts.queueName or nil,
		}
		return true
	end
	addon.Comms.QueueAddonMessages = function(prefix, messages, channel, target, opts)
		local copy = {}
		for i = 1, #messages do
			copy[i] = messages[i]
		end
		fixture.batches[#fixture.batches + 1] = {
			prefix = prefix,
			messages = copy,
			channel = channel,
			target = target,
			priority = opts and opts.priority or "NORMAL",
			queueName = opts and opts.queueName or nil,
		}
		if options.rejectBatch then
			return false, "backpressure"
		end
		return true
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncSession.lua")
	fixture.session = addon.DB.SyncSession
	fixture.protocol = protocol
	return fixture
end

local function rangeMetadata()
	return { raidUid = "r1", authorityEpoch = 1, fromSequence = 1, toSequence = 2 }
end

local function beginRangeRequest(fixture, callback, target)
	fixture.nextRequest = fixture.nextRequest + 1
	return assert(
		fixture.session:BeginRequest(
			"RANGE_REQ",
			target or "Leader",
			rangeMetadata(),
			"RANGE_DATA",
			rangeMetadata(),
			callback,
			fixture.session.RATE_CLASS_LIVE
		)
	)
end

function cases.raid_transfer_session_assembly(addon)
	local fixture = installRaidTransferSessionFixture(addon)
	local calls, injectedCalls, succeeded, completedBody = 0, 0
	local requestId = beginRangeRequest(fixture, function(ok, reason, body)
		calls, succeeded, completedBody = calls + 1, ok, body
	end)
	local injected = function()
		injectedCalls = injectedCalls + 1
	end
	local transfer = { events = { string.rep("a", 260), string.rep("b", 260) } }
	assertTrue(
		fixture.session:QueueTransfer(
			"RANGE_DATA",
			requestId,
			"Tester",
			rangeMetadata(),
			transfer,
			fixture.session.RATE_CLASS_LIVE
		)
	)
	local messages = fixture.batches[1].messages
	assertTrue(#messages > 1, "assembly test must use multiple chunks")
	local last = assert(fixture.protocol.Decode(messages[#messages]))
	assertEqual(
		true,
		fixture.session:ReceiveChunk("Leader-Realm", last, injected),
		"out-of-order final chunk was rejected"
	)
	assertEqual(
		true,
		fixture.session:ReceiveChunk("Leader-Realm", last, injected),
		"identical duplicate was not a no-op"
	)
	for i = #messages - 1, 1, -1 do
		assertTrue(fixture.session:ReceiveChunk("Leader-Realm", assert(fixture.protocol.Decode(messages[i])), injected))
	end
	assertEqual(1, calls, "completed assembly callback count differs")
	assertEqual(0, injectedCalls, "ReceiveChunk replaced the immutable request callback")
	assertEqual(true, succeeded, "completed assembly did not succeed")
	assertTrue(deepEqual(transfer, completedBody), "chunks were not concatenated in numeric order")

	local failureCalls, failureReason = 0
	requestId = beginRangeRequest(fixture, function(ok, reason)
		failureCalls, failureReason = failureCalls + 1, reason
	end)
	assertTrue(
		fixture.session:QueueTransfer(
			"RANGE_DATA",
			requestId,
			"Tester",
			rangeMetadata(),
			transfer,
			fixture.session.RATE_CLASS_LIVE
		)
	)
	messages = fixture.batches[#fixture.batches].messages
	local first = assert(fixture.protocol.Decode(messages[1]))
	assertTrue(fixture.session:ReceiveChunk("Leader", first))
	local conflicting = deepCopy(first)
	conflicting.body.chunk = conflicting.body.chunk .. "x"
	local accepted, reason = fixture.session:ReceiveChunk("Leader", conflicting)
	assertEqual(nil, accepted, "conflicting duplicate was accepted")
	assertEqual("CONFLICTING_CHUNK", reason, "conflicting duplicate reason differs")
	assertEqual(1, failureCalls, "conflict terminal callback count differs")
	assertEqual("CONFLICTING_CHUNK", failureReason, "conflict terminal callback reason differs")
	print("PASS raid_transfer_session_assembly")
end

function cases.raid_transfer_session_capacity(addon)
	local fixture = installRaidTransferSessionFixture(addon)
	local ids = {}
	for i = 1, 9 do
		if i == 5 or i == 9 then
			fixture.now = fixture.now + 30
		end
		ids[i] = beginRangeRequest(fixture, function() end)
	end
	for i = 1, 8 do
		local envelope = {
			kind = "RANGE_DATA",
			requestId = ids[i],
			target = "Tester",
			body = {
				raidUid = "r1",
				authorityEpoch = 1,
				fromSequence = 1,
				toSequence = 2,
				partIndex = 1,
				partCount = 2,
				chunk = "x",
			},
		}
		assertTrue(fixture.session:ReceiveChunk("Leader", envelope), "bounded assembly allocation failed")
	end
	assertEqual(8, fixture.session._assemblyCount, "per-sender setup count differs")
	local overflow = {
		kind = "RANGE_DATA",
		requestId = ids[9],
		target = "Tester",
		body = {
			raidUid = "r1",
			authorityEpoch = 1,
			fromSequence = 1,
			toSequence = 2,
			partIndex = 1,
			partCount = 2,
			chunk = "x",
		},
	}
	local accepted, reason = fixture.session:ReceiveChunk("Leader", overflow)
	assertEqual(nil, accepted, "ninth sender assembly was accepted")
	assertEqual("ASSEMBLY_CAPACITY", reason, "capacity rejection reason differs")
	assertEqual(8, fixture.session._assemblyCount, "capacity rejection allocated state")

	fixture.now = fixture.now + 100
	fixture.session:Expire(fixture.now)
	assertEqual(0, fixture.session._assemblyCount, "expired per-sender assemblies were not released")
	assertEqual(nil, next(fixture.session._assemblies), "expired assembly map was not cleared")

	local globalIds = {}
	for i = 1, 65 do
		local sender = "Sender" .. i
		globalIds[i] = beginRangeRequest(fixture, function() end, sender)
		local envelope = {
			kind = "RANGE_DATA",
			requestId = globalIds[i],
			target = "Tester",
			body = {
				raidUid = "r1",
				authorityEpoch = 1,
				fromSequence = 1,
				toSequence = 2,
				partIndex = 1,
				partCount = 2,
				chunk = "x",
			},
		}
		local allocated, allocationReason = fixture.session:ReceiveChunk(sender, envelope)
		if i <= 64 then
			assertEqual(true, allocated, "global assembly within capacity was rejected")
		else
			assertEqual(nil, allocated, "65th global assembly was accepted")
			assertEqual("ASSEMBLY_CAPACITY", allocationReason, "global capacity reason differs")
		end
	end
	assertEqual(64, fixture.session._assemblyCount, "global assembly count exceeded its bound")
	fixture.now = fixture.now + 46
	fixture.session:Expire(fixture.now)
	assertEqual(0, fixture.session._assemblyCount, "assembly expiry did not release global capacity")
	print("PASS raid_transfer_session_capacity")
end

function cases.raid_transfer_session_correlation(addon)
	local fixture = installRaidTransferSessionFixture(addon)
	local failures = {
		{
			"wrong kind",
			function(envelope)
				envelope.kind = "SNAP_DATA"
			end,
			"RESPONSE_KIND_MISMATCH",
		},
		{
			"wrong raid",
			function(envelope)
				envelope.body.raidUid = "other"
			end,
			"RESPONSE_METADATA_MISMATCH",
		},
		{
			"wrong epoch",
			function(envelope)
				envelope.body.authorityEpoch = 2
			end,
			"RESPONSE_METADATA_MISMATCH",
		},
		{
			"wrong from",
			function(envelope)
				envelope.body.fromSequence = 2
			end,
			"RESPONSE_METADATA_MISMATCH",
		},
		{
			"wrong to",
			function(envelope)
				envelope.body.toSequence = 3
			end,
			"RESPONSE_METADATA_MISMATCH",
		},
	}
	for i = 1, #failures do
		if i == 5 then
			fixture.now = fixture.now + 30
		end
		local callbackCalls, callbackReason = 0
		local requestId = beginRangeRequest(fixture, function(ok, reason)
			callbackCalls, callbackReason = callbackCalls + 1, reason
		end)
		local envelope = {
			kind = "RANGE_DATA",
			requestId = requestId,
			target = "Tester",
			body = {
				raidUid = "r1",
				authorityEpoch = 1,
				fromSequence = 1,
				toSequence = 2,
				partIndex = 1,
				partCount = 1,
				chunk = '{"ok":true}',
			},
		}
		failures[i][2](envelope)
		local accepted, reason = fixture.session:ReceiveChunk("Leader", envelope)
		assertEqual(nil, accepted, failures[i][1] .. " was accepted")
		assertEqual(failures[i][3], reason, failures[i][1] .. " reason differs")
		assertEqual(1, callbackCalls, failures[i][1] .. " callback count differs")
		assertEqual(reason, callbackReason, failures[i][1] .. " callback reason differs")
	end

	fixture.now = fixture.now + 30
	local sequenceCalls = 0
	local snapId = assert(
		fixture.session:BeginRequest(
			"SNAP_REQ",
			"Leader",
			{ raidUid = "r1" },
			"SNAP_DATA",
			{ raidUid = "r1", authorityEpoch = 1, sequence = 7 },
			function()
				sequenceCalls = sequenceCalls + 1
			end,
			fixture.session.RATE_CLASS_LIVE
		)
	)
	local wrongSequence = {
		kind = "SNAP_DATA",
		requestId = snapId,
		target = "Tester",
		body = {
			raidUid = "r1",
			authorityEpoch = 1,
			sequence = 8,
			partIndex = 1,
			partCount = 1,
			chunk = '{"ok":true}',
		},
	}
	assertEqual(nil, fixture.session:ReceiveChunk("Leader", wrongSequence), "wrong snapshot sequence was accepted")
	assertEqual(1, sequenceCalls, "wrong snapshot sequence was not terminal once")

	local crossCalls, crossReason = 0
	local crossId = beginRangeRequest(fixture, function(ok, reason)
		crossCalls, crossReason = crossCalls + 1, reason
	end)
	local first = {
		kind = "RANGE_DATA",
		requestId = crossId,
		target = "Tester",
		body = {
			raidUid = "r1",
			authorityEpoch = 1,
			fromSequence = 1,
			toSequence = 2,
			partIndex = 1,
			partCount = 2,
			chunk = '{"ok":',
		},
	}
	assertTrue(fixture.session:ReceiveChunk("Leader", first))
	local changed = deepCopy(first)
	changed.body.partIndex = 2
	changed.body.chunk = "true}"
	changed.body.authorityEpoch = 2
	local accepted, reason = fixture.session:ReceiveChunk("Leader", changed)
	assertEqual(nil, accepted, "cross-chunk metadata conflict was accepted")
	assertEqual("RESPONSE_METADATA_MISMATCH", reason, "cross-chunk metadata reason differs")
	assertEqual(1, crossCalls, "cross-chunk conflict callback count differs")
	assertEqual(reason, crossReason, "cross-chunk callback reason differs")
	print("PASS raid_transfer_session_correlation")
end

function cases.raid_transfer_session_decode_bounds(addon)
	local fixture = installRaidTransferSessionFixture(addon)
	local requestId = beginRangeRequest(fixture, function() end)
	local oversized = {
		kind = "RANGE_DATA",
		requestId = requestId,
		target = "Tester",
		body = {
			raidUid = "r1",
			authorityEpoch = 1,
			fromSequence = 1,
			toSequence = 2,
			partIndex = 1,
			partCount = 256,
			chunk = string.rep("x", 221),
		},
	}
	local decodeCalls = fixture.channelDecodeCalls
	local parseCalls = fixture.protocolDecodeBodyCalls
	local accepted, reason = fixture.session:ReceiveChunk("Leader", oversized)
	assertEqual(nil, accepted, "oversized encoded chunk was accepted")
	assertEqual("TRANSFER_TOO_LARGE", reason, "oversized encoded rejection reason differs")
	assertEqual(decodeCalls, fixture.channelDecodeCalls, "oversized encoded input reached channel decode")
	assertEqual(parseCalls, fixture.protocolDecodeBodyCalls, "oversized encoded input reached structured parsing")
	assertEqual(0, fixture.session._assemblyCount, "oversized encoded input allocated assembly state")

	requestId = beginRangeRequest(fixture, function() end)
	local malformedEncoded = {
		kind = "RANGE_DATA",
		requestId = requestId,
		target = "Tester",
		body = {
			raidUid = "r1",
			authorityEpoch = 1,
			fromSequence = 1,
			toSequence = 2,
			partIndex = 1,
			partCount = 1,
			chunk = "not-a-shared-codec-payload",
		},
	}
	parseCalls = fixture.protocolDecodeBodyCalls
	accepted, reason = fixture.session:ReceiveChunk("Leader", malformedEncoded)
	assertEqual(nil, accepted, "malformed encoded body was accepted")
	assertEqual("DESERIALIZE_FAILED", reason, "malformed encoded rejection reason differs")
	assertEqual(parseCalls + 1, fixture.protocolDecodeBodyCalls, "malformed encoded body skipped shared decoding")
	assertEqual(0, fixture.deflateCalls, "session invoked a Deflate method")

	local noise = {}
	local seed = 17
	for i = 1, 65536 do
		seed = (seed * 48271) % 2147483647
		noise[i] = string.char(33 + (seed % 90))
	end
	local encodeCalls = fixture.channelEncodeCalls
	local protocolEncodeCalls = fixture.protocolEncodeBodyCalls
	local batchCalls = #fixture.batches
	local queued, queueReason = fixture.session:QueueTransfer(
		"SNAP_DATA",
		"oversized",
		"Recipient",
		{ raidUid = "r1", authorityEpoch = 1, sequence = 1 },
		{ snapshot = table.concat(noise) },
		fixture.session.RATE_CLASS_LIVE
	)
	assertEqual(false, queued, "oversized outgoing body was accepted")
	assertEqual("TRANSFER_TOO_LARGE", queueReason, "oversized outgoing reason differs")
	assertEqual(protocolEncodeCalls + 1, fixture.protocolEncodeBodyCalls, "outgoing body skipped shared encoding")
	assertEqual(encodeCalls, fixture.channelEncodeCalls, "session performed a second channel encoding")
	assertEqual(batchCalls, #fixture.batches, "oversized outgoing body allocated a queue batch")
	assertEqual(0, fixture.deflateCalls, "outgoing transfer invoked a Deflate method")
	print("PASS raid_transfer_session_decode_bounds")
end

function cases.raid_transfer_session_retry(addon)
	local fixture = installRaidTransferSessionFixture(addon)
	local calls, terminalReason = 0
	local requestId = beginRangeRequest(fixture, function(ok, reason)
		calls, terminalReason = calls + 1, reason
	end)
	assertEqual(1, #fixture.queued, "initial request was not queued")
	fixture.now = 131
	fixture.session:Expire(fixture.now)
	assertEqual(2, #fixture.queued, "first timeout did not enqueue exactly one retry")
	assertEqual(fixture.queued[1].message, fixture.queued[2].message, "retry did not reuse original request")
	assertEqual(1, #fixture.cancelled, "retry did not cancel the replaced request timer")
	assertEqual(0, calls, "first timeout completed the request")
	fixture.now = 162
	fixture.session:Expire(fixture.now)
	assertEqual(2, #fixture.queued, "second timeout enqueued another retry")
	assertEqual(1, calls, "second timeout callback count differs")
	assertEqual("TIMEOUT", terminalReason, "second timeout reason differs")
	assertEqual(nil, fixture.session._pendingRequests[requestId], "terminal request remained pending")
	fixture.session:Expire(1000)
	assertEqual(1, calls, "terminal timeout callback repeated")
	print("PASS raid_transfer_session_retry")
end

function cases.raid_transfer_session_atomic_batch(addon)
	local fixture = installRaidTransferSessionFixture(addon, { rejectBatch = true })
	local queued, reason = fixture.session:QueueTransfer(
		"SNAP_DATA",
		"request-1",
		"Recipient",
		{ raidUid = "r1", authorityEpoch = 1, sequence = 1 },
		{ snapshot = string.rep("x", 600) },
		fixture.session.RATE_CLASS_LIVE
	)
	assertEqual(false, queued, "rejected batch reported success")
	assertEqual("backpressure", reason, "batch rejection reason differs")
	assertEqual(1, #fixture.batches, "transfer was not offered as one batch")
	assertTrue(#fixture.batches[1].messages > 1, "atomic test must use multiple messages")
	assertEqual("BULK", fixture.batches[1].priority, "raid transfer priority differs")
	assertEqual("RMARaidSync:WHISPER:recipient", fixture.batches[1].queueName, "raid transfer queue differs")
	assertEqual(0, #fixture.queued, "batch failure partially used single-message enqueue")
	for i = 1, #fixture.batches[1].messages do
		assertTrue(fixture.protocol.Decode(fixture.batches[1].messages[i]) ~= nil, "wire message was not preflighted")
	end
	assertEqual(0, fixture.deflateCalls, "atomic transfer invoked a Deflate method")
	print("PASS raid_transfer_session_atomic_batch")
end

function cases.raid_transfer_session_rechunks_snapshot_at_safe_wire_limit(addon)
	local fixture = installRaidTransferSessionFixture(addon)
	local queued, reason = fixture.session:QueueTransfer(
		"SNAP_DATA",
		"request-1",
		"Recipient",
		{ raidUid = "r1", authorityEpoch = 1, sequence = 1 },
		{ snapshot = string.rep("x", 300) },
		fixture.session.RATE_CLASS_LIVE
	)
	assertEqual(true, queued, "snapshot transfer was rejected: " .. tostring(reason))
	local messages = fixture.batches[1].messages
	assertEqual(3, #messages, "snapshot was not rechunked at the safe wire limit")
	assertEqual("BULK", fixture.batches[1].priority, "snapshot chunk priority differs")
	assertEqual("RMARaidSync:WHISPER:recipient", fixture.batches[1].queueName, "snapshot chunk queue differs")
	for i = 1, #messages do
		assertTrue(#messages[i] <= 243, "snapshot envelope " .. i .. " exceeds the safe wire limit")
		assertTrue(fixture.protocol.Decode(messages[i]) ~= nil, "rechunked snapshot envelope did not decode")
	end
	print("PASS raid_transfer_session_rechunks_snapshot_at_safe_wire_limit")
end

function cases.raid_transfer_session_rate_limits(addon)
	local fixture = installRaidTransferSessionFixture(addon)
	for i = 1, 6 do
		assertEqual(
			true,
			fixture.session:AllowIncomingRequest("Sender-Realm", fixture.session.RATE_CLASS_LIVE),
			"live inbound request within limit failed"
		)
	end
	local allowed, reason, retryDelay =
		fixture.session:AllowIncomingRequest("sender-OtherRealm", fixture.session.RATE_CLASS_LIVE)
	assertEqual(false, allowed, "seventh live inbound request was accepted")
	assertEqual("RATE_LIMIT", reason, "live inbound rate reason differs")
	assertEqual(30, retryDelay, "live inbound retry delay differs")
	for i = 1, 6 do
		assertEqual(
			true,
			fixture.session:AllowIncomingRequest("Sender-Realm", fixture.session.RATE_CLASS_HISTORY),
			"history inbound request within limit failed"
		)
	end
	allowed, reason, retryDelay =
		fixture.session:AllowIncomingRequest("sender-OtherRealm", fixture.session.RATE_CLASS_HISTORY)
	assertEqual(false, allowed, "seventh history inbound request was accepted")
	assertEqual("RATE_LIMIT", reason, "history inbound rate reason differs")
	assertEqual(30, retryDelay, "history inbound retry delay differs")

	for i = 1, 4 do
		assertTrue(beginRangeRequest(fixture, function() end, "Peer"), "live outbound request within limit failed")
	end
	local encodeBodyCalls = fixture.protocolEncodeBodyCalls
	local queueCalls = #fixture.queued
	local requestId, requestReason, requestRetryDelay = fixture.session:BeginRequest(
		"RANGE_REQ",
		"Peer",
		rangeMetadata(),
		"RANGE_DATA",
		rangeMetadata(),
		function() end,
		fixture.session.RATE_CLASS_LIVE
	)
	assertEqual(nil, requestId, "fifth live outbound request was accepted")
	assertEqual("RATE_LIMIT", requestReason, "live outbound request rate reason differs")
	assertEqual(30, requestRetryDelay, "live outbound retry delay differs")
	assertEqual(encodeBodyCalls, fixture.protocolEncodeBodyCalls, "rate-limited request reached protocol encoding")
	assertEqual(queueCalls, #fixture.queued, "rate-limited request allocated queue work")

	for i = 1, 4 do
		assertTrue(
			fixture.session:QueueTransfer(
				"SNAP_DATA",
				"history-" .. i,
				"Peer",
				{ raidUid = "r1", authorityEpoch = 1, sequence = 1 },
				{ snapshot = "x" },
				fixture.session.RATE_CLASS_HISTORY
			),
			"history transfer within limit failed"
		)
	end
	encodeBodyCalls = fixture.protocolEncodeBodyCalls
	local channelCalls = fixture.channelEncodeCalls
	local batchCalls = #fixture.batches
	allowed, reason, retryDelay = fixture.session:QueueTransfer(
		"SNAP_DATA",
		"history-5",
		"Peer",
		{ raidUid = "r1", authorityEpoch = 1, sequence = 1 },
		{ snapshot = "x" },
		fixture.session.RATE_CLASS_HISTORY
	)
	assertEqual(false, allowed, "fifth history transfer was accepted")
	assertEqual("RATE_LIMIT", reason, "history transfer rate reason differs")
	assertEqual(30, retryDelay, "history transfer retry delay differs")
	assertEqual(encodeBodyCalls, fixture.protocolEncodeBodyCalls, "rate-limited batch reached serialization")
	assertEqual(channelCalls, fixture.channelEncodeCalls, "rate-limited batch reached channel encoding")
	assertEqual(batchCalls, #fixture.batches, "rate-limited batch allocated queue work")
	requestId, requestReason = fixture.session:BeginRequest(
		"RANGE_REQ",
		"Peer",
		rangeMetadata(),
		"RANGE_DATA",
		rangeMetadata(),
		function() end,
		fixture.session.RATE_CLASS_LIVE
	)
	assertEqual(nil, requestId, "history transfer released the capped live rate class")
	assertEqual("RATE_LIMIT", requestReason, "live class did not remain capped")
	fixture.now = fixture.now + 30
	assertTrue(
		fixture.session:QueueTransfer(
			"SNAP_DATA",
			"history-expired",
			"Peer",
			{ raidUid = "r1", authorityEpoch = 1, sequence = 1 },
			{ snapshot = "x" },
			fixture.session.RATE_CLASS_HISTORY
		),
		"history transfer rate did not expire at exactly 30 seconds"
	)
	assertTrue(
		fixture.session:BeginRequest(
			"RANGE_REQ",
			"Peer",
			rangeMetadata(),
			"RANGE_DATA",
			rangeMetadata(),
			function() end,
			fixture.session.RATE_CLASS_LIVE
		),
		"live request rate did not expire at exactly 30 seconds"
	)

	for i = 1, 140 do
		fixture.session:AllowIncomingRequest("Unique" .. i, fixture.session.RATE_CLASS_LIVE)
	end
	local ratePeers = 0
	for _ in pairs(fixture.session._incomingRates.live) do
		ratePeers = ratePeers + 1
	end
	assertTrue(ratePeers <= 128, "inbound rate map grew beyond its bound")
	fixture.now = fixture.now + 31
	fixture.session:AllowIncomingRequest("Fresh", fixture.session.RATE_CLASS_LIVE)
	ratePeers = 0
	for _ in pairs(fixture.session._incomingRates.live) do
		ratePeers = ratePeers + 1
	end
	assertEqual(1, ratePeers, "expired inbound rate entries were not pruned")

	addon.DB.SyncSession = nil
	local expiryFixture = installRaidTransferSessionFixture(addon)
	local timeoutRequest = beginRangeRequest(expiryFixture, function() end, "TimeoutPeer")
	assertEqual(1, expiryFixture.session:Expire(131), "first request timeout did not run")
	assertTrue(
		type(expiryFixture.session._incomingRates.live) == "table",
		"expiry removed the live incoming rate class"
	)
	assertTrue(
		type(expiryFixture.session._incomingRates.history) == "table",
		"expiry removed the history incoming rate class"
	)
	assertTrue(
		type(expiryFixture.session._outgoingRates.live) == "table",
		"expiry removed the live outgoing rate class"
	)
	assertTrue(
		type(expiryFixture.session._outgoingRates.history) == "table",
		"expiry removed the history outgoing rate class"
	)
	assertEqual(1, expiryFixture.session:Expire(162), "second request timeout did not clean up")
	assertEqual(nil, expiryFixture.session._pendingRequests[timeoutRequest], "timed-out request remained pending")
	assertTrue(
		expiryFixture.session:AllowIncomingRequest("AfterExpiry", expiryFixture.session.RATE_CLASS_LIVE),
		"live admission failed after expiry"
	)
	assertTrue(
		expiryFixture.session:AllowIncomingRequest("AfterExpiry", expiryFixture.session.RATE_CLASS_HISTORY),
		"history admission failed after expiry"
	)

	addon.DB.SyncSession = nil
	local capacityFixture = installRaidTransferSessionFixture(addon)
	assertTrue(capacityFixture.session:AllowIncomingRequest("Capacity1", capacityFixture.session.RATE_CLASS_LIVE))
	capacityFixture.now = 102
	for i = 2, 128 do
		assertTrue(
			capacityFixture.session:AllowIncomingRequest("Capacity" .. i, capacityFixture.session.RATE_CLASS_LIVE)
		)
	end
	capacityFixture.now = 105
	assertTrue(capacityFixture.session:AllowIncomingRequest("Capacity1", capacityFixture.session.RATE_CLASS_LIVE))
	local capacityAllowed, capacityReason, capacityDelay =
		capacityFixture.session:AllowIncomingRequest("CapacityNew", capacityFixture.session.RATE_CLASS_LIVE)
	assertEqual(false, capacityAllowed, "full rate class accepted a new peer")
	assertEqual("RATE_CAPACITY", capacityReason, "full rate class reason differs")
	assertEqual(27, capacityDelay, "capacity retry delay did not wait for a peer slot")
	capacityFixture.now = capacityFixture.now + capacityDelay
	assertTrue(
		capacityFixture.session:AllowIncomingRequest("CapacityNew", capacityFixture.session.RATE_CLASS_LIVE),
		"capacity admission did not succeed at the returned retry delay"
	)
	print("PASS raid_transfer_session_rate_limits")
end

local function newLiveReplicationNetwork()
	local network = {
		clients = {},
		messages = {},
		nextMessage = 0,
		now = 100,
		raidLeader = "Leader",
		heldTransfers = {},
	}

	function network:encode(kind, requestId, target, body)
		self.nextMessage = self.nextMessage + 1
		local wire = "wire-" .. tostring(self.nextMessage)
		self.messages[wire] = {
			kind = kind,
			requestId = requestId or "-",
			target = target or "-",
			body = deepCopy(body),
		}
		return wire
	end

	function network:decode(wire)
		return deepCopy(self.messages[wire])
	end

	function network:deliver(sender, prefix, wire, channel, target)
		local accepted, reason
		for name, client in pairs(self.clients) do
			if name ~= sender and (not target or string.lower(target) == string.lower(name)) then
				accepted, reason = client.syncer:OnAddonMessage(prefix, wire, channel, sender .. "-Test Realm")
			end
		end
		return accepted, reason
	end

	return network
end

local function newLiveReplicationStore(callbacks, initialRecord)
	local store = { record = deepCopy(initialRecord), committed = {} }

	function store:SetAuthorityGuard(guard)
		self.authorityGuard = guard
		return true
	end

	function store:GetActiveRecord()
		return self.record and self.record.status == "active" and self.record or nil
	end

	function store:GetRecord(raidUid)
		return self.record and self.record.raidUid == raidUid and self.record or nil
	end

	function store:GetRaidUid(state)
		return self.record and self.record.state == state and self.record.raidUid or nil
	end

	function store:GetIndexByUid(raidUid)
		return self.record and self.record.raidUid == raidUid and 1 or nil
	end

	function store:GetStateDigest(state)
		if self.record and self.record.state == state then
			return state.computedDigest or self.record.digest
		end
		return nil
	end

	function store:UpsertLootIndex()
		return true
	end

	function store:ApplyReplicaEvent(event)
		local current = self.record
		if not current then
			return nil, "RAID_NOT_ACTIVE"
		end
		if event.raidUid ~= current.raidUid then
			return nil, "RAID_NOT_FOUND"
		end
		if event.authorityEpoch ~= current.authorityEpoch then
			return nil, "AUTHORITY_EPOCH_MISMATCH"
		end
		if event.sequence ~= current.sequence + 1 then
			return nil, "SEQUENCE_MISMATCH"
		end
		self.record.sequence = event.sequence
		self.record.digest = event.resultDigest
		if event.eventType == "RAID_CONCLUDED" then
			self.record.status = "complete"
			self.record.checkpointSequence = event.sequence
			self.record.events = {}
		else
			if event.eventType == "RAID_METADATA_UPDATED" then
				for key, value in pairs(event.payload and event.payload.metadata or {}) do
					self.record.state[key] = deepCopy(value)
				end
			elseif event.eventType == "LOOT_ADDED" then
				self.record.state.loot = self.record.state.loot or {}
				self.record.state.loot[#self.record.state.loot + 1] = deepCopy(event.payload.loot)
				local lootNid = tonumber(event.payload.loot and event.payload.loot.lootNid) or 0
				self.record.state.nextLootNid = math.max(tonumber(self.record.state.nextLootNid) or 1, lootNid + 1)
				if event.payload.loot.source == "DISTRIBUTION_AWARD" then
					local fields = { [1] = "countMS", [2] = "countOs", [3] = "countSR", [4] = "countFree" }
					local field = fields[tonumber(event.payload.loot.rollType)]
					if field then
						for i = 1, #(self.record.state.players or {}) do
							local player = self.record.state.players[i]
							if tonumber(player.playerNid) == tonumber(event.payload.loot.looterNid) then
								player[field] = (tonumber(player[field]) or 0)
									+ (tonumber(event.payload.loot.itemCount) or 1)
								break
							end
						end
					end
				end
			elseif event.eventType == "LOOT_UPDATED" then
				for i = 1, #(self.record.state.loot or {}) do
					if
						tonumber(self.record.state.loot[i].lootNid)
						== tonumber(event.payload.loot and event.payload.loot.lootNid)
					then
						self.record.state.loot[i] = deepCopy(event.payload.loot)
						break
					end
				end
			elseif event.eventType == "PLAYER_UPDATED" then
				self.record.state.players = self.record.state.players or {}
				local incoming = event.payload and event.payload.player
				local replaced = false
				for i = 1, #self.record.state.players do
					if
						tonumber(self.record.state.players[i].playerNid)
							== tonumber(incoming and incoming.playerNid)
						or self.record.state.players[i].name == (incoming and incoming.name)
					then
						self.record.state.players[i] = deepCopy(incoming)
						replaced = true
						break
					end
				end
				if not replaced then
					self.record.state.players[#self.record.state.players + 1] = deepCopy(incoming)
				end
			end
			self.record.events[#self.record.events + 1] = deepCopy(event)
		end
		return deepCopy(event), self.record.state
	end

	function store:GetEventRange(raidUid, afterSequence, maximumCount)
		local current = self:GetRecord(raidUid)
		if not current then
			return nil, "RAID_NOT_FOUND"
		end
		if afterSequence < current.checkpointSequence then
			return nil, "SNAPSHOT_REQUIRED"
		end
		local events = {}
		for i = 1, #current.events do
			if current.events[i].sequence > afterSequence then
				events[#events + 1] = deepCopy(current.events[i])
				if #events >= maximumCount then
					break
				end
			end
		end
		return events
	end

	function store:BuildSnapshot(raidUid)
		local current = self:GetRecord(raidUid)
		if not current then
			return nil, "RAID_NOT_FOUND"
		end
		return deepCopy(current)
	end

	function store:ReplaceActiveFromSnapshot(snapshot)
		if type(snapshot) ~= "table" or snapshot.status ~= "active" then
			return nil, "INVALID_SNAPSHOT"
		end
		if self.record and self.record.raidUid == snapshot.raidUid and self.record.digest ~= snapshot.digest then
			return nil, "RAID_CONFLICT"
		end
		self.record = deepCopy(snapshot)
		return self.record.state
	end

	function store:RepairActiveFromSnapshot(snapshot)
		if not self.record or self.record.status ~= "active" or self.record.raidUid ~= snapshot.raidUid then
			return nil, "RAID_NOT_ACTIVE"
		end
		self.record = deepCopy(snapshot)
		return self.record.state
	end

	function store:CaptureRaidHistoryState()
		return deepCopy(self.record)
	end

	function store:RestoreRaidHistoryState(snapshot)
		self.record = deepCopy(snapshot)
		return true
	end

	function store:Commit(event)
		if type(self.authorityGuard) ~= "function" then
			return nil, "NOT_RAID_LEADER"
		end
		local allowed, reason = self.authorityGuard()
		if allowed ~= true then
			return nil, reason or "NOT_RAID_LEADER"
		end
		if not self.record then
			self.record = {
				raidUid = event.raidUid,
				status = "active",
				authorityEpoch = event.authorityEpoch,
				sequence = 0,
				checkpointSequence = 0,
				digest = "00000000:1",
				state = {},
				events = {},
			}
		end
		assert(self:ApplyReplicaEvent(event))
		self.committed[#self.committed + 1] = deepCopy(event)
		local listeners = callbacks.RaidReplicationCommitted or {}
		for i = 1, #listeners do
			listeners[i](nil, deepCopy(event))
		end
		return true
	end

	function store:CreateActiveRaid(args)
		if type(self.authorityGuard) ~= "function" or self.authorityGuard("create") ~= true then
			return nil, "NOT_RAID_LEADER"
		end
		if self:GetActiveRecord() then
			return nil, "ACTIVE_RAID_EXISTS"
		end
		args = args or {}
		local raidUid = "raid-created-" .. tostring(args.authorityKey or "unknown")
		local state = deepCopy(args.state or {
			raidNid = 1,
			zone = args.zone,
			size = args.size,
			difficulty = args.difficulty,
			players = args.players or {},
			bossKills = {},
			attendance = {},
			loot = {},
			nextPlayerNid = #(args.players or {}) + 1,
			nextBossNid = 1,
			nextLootNid = 1,
		})
		local event = {
			raidUid = raidUid,
			authorityEpoch = 1,
			sequence = 1,
			eventUid = raidUid .. ":1:1",
			eventType = "RAID_CREATED",
			payload = { state = deepCopy(state) },
			resultDigest = "00000001:1",
		}
		self.record = {
			raidUid = raidUid,
			status = "active",
			authorityEpoch = 1,
			sequence = 1,
			checkpointSequence = 0,
			digest = event.resultDigest,
			state = state,
			events = { deepCopy(event) },
		}
		self.committed[#self.committed + 1] = deepCopy(event)
		local listeners = callbacks.RaidReplicationCommitted or {}
		for i = 1, #listeners do
			listeners[i](nil, deepCopy(event))
		end
		return deepCopy(event), state
	end

	function store:CommitAuthoritativeEvent(raidUid, eventType, payload)
		if type(self.authorityGuard) ~= "function" then
			return nil, "NOT_RAID_LEADER"
		end
		local allowed, reason = self.authorityGuard()
		if allowed ~= true then
			return nil, reason or "NOT_RAID_LEADER"
		end
		local nextSequence = self.record.sequence + 1
		local event = {
			raidUid = raidUid,
			authorityEpoch = self.record.authorityEpoch,
			sequence = nextSequence,
			eventUid = raidUid .. ":" .. tostring(self.record.authorityEpoch) .. ":" .. tostring(nextSequence),
			eventType = eventType,
			payload = deepCopy(payload),
			resultDigest = string.format("%08d:1", nextSequence),
		}
		if not self:Commit(event) then
			return nil
		end
		return event, self.record.state
	end

	function store:PromoteAuthority(raidUid, recoveredSequence)
		if not self.record or self.record.raidUid ~= raidUid or self.record.sequence ~= recoveredSequence then
			return nil, "RECOVERED_SEQUENCE_MISMATCH"
		end
		local candidate = deepCopy(self.record)
		candidate.authorityEpoch = candidate.authorityEpoch + 1
		candidate.checkpointSequence = recoveredSequence
		candidate.events = {}
		self.record = candidate
		return candidate
	end

	return store
end

local function makeLiveRecord(sequence, digest)
	local events = {}
	for i = 1, sequence do
		events[i] = {
			raidUid = "raid-live",
			authorityEpoch = 1,
			sequence = i,
			eventUid = "raid-live:1:" .. tostring(i),
			eventType = "TEST",
			payload = { value = i },
			resultDigest = "0000000" .. tostring(i) .. ":1",
		}
	end
	return {
		raidUid = "raid-live",
		status = "active",
		authorityEpoch = 1,
		sequence = sequence,
		checkpointSequence = 0,
		digest = digest or (sequence > 0 and events[sequence].resultDigest or "00000000:1"),
		state = {
			value = sequence,
			zone = "Naxxramas",
			size = 10,
			difficulty = 1,
		},
		events = events,
	}
end

local function installLiveReplicationRealStore(addon, client, seedActiveRaid, seedServerTime)
	resetSavedVariables()
	_G.GetTime = function()
		return 100
	end
	addon.Time = {
		GetCurrentTime = function()
			return 100
		end,
	}
	addon.IgnoredMobs = {
		IsTrashMobName = function()
			return false
		end,
		GetTrashMobName = function()
			return "Trash"
		end,
	}
	installRaidReplicationEventFixture(addon)
	loadAddonFile(addon, "Raid Management Addon/Database/DB.lua")
	addon.Services.Reserves = { Save = function() end }
	loadAddonFile(addon, "Raid Management Addon/Database/SavedVariables.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidValidator.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidStore.lua")
	local rawStore = addon.Database.GetRaidStore()
	assert(rawStore:SetAuthorityGuard(function()
		return true
	end))
	if seedActiveRaid then
		local _, index, raidUid = assert(rawStore:CreateActiveRaid({
			authorityKey = client.name .. "-TestRealm",
			serverTime = seedServerTime or 100,
			realm = "Test Realm",
			zone = "Naxxramas",
			size = 10,
			difficulty = 1,
			players = {
				{ playerNid = 1, name = client.name, rank = 2, subgroup = 1, class = "WARRIOR", join = 100 },
			},
			nextPlayerNid = 2,
		}))
		client.seedRaidIndex = index
		client.seedRaidUid = raidUid
		client.seedRecord = assert(rawStore:BuildSnapshot(raidUid))
	end
	client.raidArchive = _G.RMA_Raids
	local function withClientArchive(callback)
		local previousArchive = _G.RMA_Raids
		_G.RMA_Raids = client.raidArchive
		local first, second, third, fourth, fifth, sixth
		local succeeded, failureReason = pcall(function()
			first, second, third, fourth, fifth, sixth = callback()
		end)
		client.raidArchive = _G.RMA_Raids
		_G.RMA_Raids = previousArchive
		if not succeeded then
			error(failureReason, 0)
		end
		return first, second, third, fourth, fifth, sixth
	end
	return setmetatable({}, {
		__index = function(_, key)
			local method = rawStore[key]
			if type(method) ~= "function" then
				return method
			end
			return function(_, ...)
				local argumentCount = select("#", ...)
				local arguments = { ... }
				return withClientArchive(function()
					return method(rawStore, unpack(arguments, 1, argumentCount))
				end)
			end
		end,
	})
end

local installProductionReentryRuntime

local function installLiveReplicationClient(network, name, initialRecord, options)
	options = options or {}
	local productionRosterSettled = options.productionRosterSettled ~= false
	local productionLeaderRoleSettled = productionRosterSettled
	if options.productionLeaderRoleSettled ~= nil then
		productionLeaderRoleSettled = options.productionLeaderRoleSettled == true
	end
	local productionLeaderIdentitySettled = productionRosterSettled
	if options.productionLeaderIdentitySettled ~= nil then
		productionLeaderIdentitySettled = options.productionLeaderIdentitySettled == true
	end
	local client = {
		name = name,
		callbacks = {},
		requests = {},
		transfers = {},
		sentEnvelopes = {},
		sentWires = {},
		cancelledRequests = {},
		traces = {},
		warnings = {},
		recoveryFinished = {},
		reentryReady = {},
		currentRaid = initialRecord and 1 or nil,
		productionInstanceReady = options.productionInstanceReady ~= false,
		productionLeaderRoleSettled = productionLeaderRoleSettled,
		productionLeaderIdentitySettled = productionLeaderIdentitySettled,
	}
	local addon = newAddon()
	client.addon = addon
	addon.DB = {}
	addon.Database = {
		GetCurrentRaid = function()
			return client.currentRaid
		end,
	}
	addon.L = {
		WarnRaidDatabaseAuthorityReleased = "Raid database authority passed to %s. This client now holds a read-only replica.",
		WarnRaidDatabaseAuthorityReceived = "Raid database authority received from %s. Recovery is in progress; raid history writes are temporarily paused.",
	}
	addon.Diagnose = { D = { RaidSyncTrace = "%s %s" } }
	addon.Diag = addon.Diagnose
	addon.warn = function(_, message)
		client.warnings[#client.warnings + 1] = message
	end
	addon.debug = function(_, message)
		client.traces[#client.traces + 1] = message
	end
	addon.IsInGroup = function()
		return true
	end
	addon.IsInRaid = function()
		return true
	end
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleTimer(callback, delay)
				client.timers = client.timers or {}
				client.timers[#client.timers + 1] = { callback = callback, delay = delay }
				return #client.timers
			end
			function target:CancelTimer(handle)
				if client.timers and client.timers[handle] then
					client.timers[handle] = nil
					return true
				end
				return false
			end
		end,
	}
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
		NormalizeLower = function(value)
			return value and string.lower(string.match(value, "^([^%-]+)") or value)
		end,
	}
	addon.Events = {
		Internal = {
			OptionsLoaded = "OptionsLoaded",
			RaidCreate = "RaidCreate",
			RaidRosterDelta = "RaidRosterDelta",
			RaidReplicationCommitted = "RaidReplicationCommitted",
			LoggerSelectRaid = "LoggerSelectRaid",
			LoggerDataChanged = "LoggerDataChanged",
			LoggerRaidOfferReceived = "LoggerRaidOfferReceived",
			RaidAuthorityRecoveryFinished = "RaidAuthorityRecoveryFinished",
			RaidReentryRecoveryReady = "RaidReentryRecoveryReady",
			RaidReentryDecisionRequired = "RaidReentryDecisionRequired",
			RaidReentryDecisionResolved = "RaidReentryDecisionResolved",
			RaidInstanceRecognized = "RaidInstanceRecognized",
		},
		Wow = { ZoneChangedNewArea = "ZoneChangedNewArea", PartyLootMethodChanged = "PartyLootMethodChanged" },
	}
	addon.Bus = {}
	function addon.Bus.RegisterCallback(eventName, callback)
		client.callbacks[eventName] = client.callbacks[eventName] or {}
		client.callbacks[eventName][#client.callbacks[eventName] + 1] = callback
	end
	function addon.Bus.TriggerEvent(eventName, ...)
		local args = { ... }
		if eventName == addon.Events.Internal.RaidAuthorityRecoveryFinished then
			client.recoveryFinished[#client.recoveryFinished + 1] = {
				raidUid = args[1],
				succeeded = args[2],
				reason = args[3],
				recovering = client.syncer and client.syncer:IsAuthorityRecovering(args[1]) or false,
			}
		end
		if eventName == addon.Events.Internal.RaidReentryRecoveryReady then
			client.reentryReady[#client.reentryReady + 1] = deepCopy(args[1])
		end
		local listeners = client.callbacks[eventName] or {}
		for i = 1, #listeners do
			listeners[i](eventName, unpack(args))
		end
	end
	if options.realStore then
		client.store =
			installLiveReplicationRealStore(addon, client, options.seedActiveRaid, options.seedServerTime)
	else
		client.store = newLiveReplicationStore(client.callbacks, initialRecord)
	end
	client.raidStore = client.store
	addon.DB.RaidStore = client.store
	if options.realProtocol then
		client.protocol = installRaidReplicationProtocolFixture(addon)
	else
		client.protocol = {
			VERSION = 5,
			Encode = function(kind, requestId, target, body)
				return network:encode(kind, requestId, target, body)
			end,
			Decode = function(wire)
				return network:decode(wire)
			end,
		}
	end
	addon.DB.SyncProtocol = client.protocol
	local pending, nextRequest = {}, 0
	local protocolPayload = addon.Comms and addon.Comms.Payload
	addon.Comms = {
		Payload = protocolPayload,
		RegisterPrefixIfAvailable = function(prefix)
			client.prefix = prefix
			return true
		end,
		NormalizeSender = function(sender)
			return type(sender) == "string" and (string.match(sender, "^([^%-]+)") or sender) or nil
		end,
		QueueAddonMessage = function(prefix, wire, channel, target)
			local envelope = client.protocol.Decode(wire)
			client.requests[#client.requests + 1] = envelope.kind
			local accepted, reason = network:deliver(name, prefix, wire, channel, target)
			local request = pending and pending[envelope.requestId]
			if request and accepted == false then
				pending[envelope.requestId] = nil
				request.callback(false, reason)
			end
			return true
		end,
		SendAddonBatch = function(prefix, messages, target)
			for i = 1, #messages do
				local envelope = client.protocol.Decode(messages[i])
				client.requests[#client.requests + 1] = envelope.kind
				client.sentEnvelopes[#client.sentEnvelopes + 1] = deepCopy(envelope)
				client.sentWires[#client.sentWires + 1] = messages[i]
				network:deliver(name, prefix, messages[i], target and "WHISPER" or "RAID", target)
			end
			return true
		end,
	}
	addon.DB.SyncSession = {
		AllowIncomingRequest = function()
			return true
		end,
		BeginRequest = function(_, kind, target, body, expectedKind, metadata, callback)
			client.lastBeginRequestCallback = callback
			client.lastBeginRequestTarget = target
			local injectedReason = options.beginRequestFailures and options.beginRequestFailures[kind]
			if injectedReason then
				return nil, injectedReason
			end
			nextRequest = nextRequest + 1
			local requestId = name .. "-" .. tostring(nextRequest)
			pending[requestId] = { callback = callback, expectedKind = expectedKind, metadata = deepCopy(metadata) }
			local wire = assert(client.protocol.Encode(kind, requestId, target, body))
			addon.Comms.QueueAddonMessage("RMARaidSync", wire, "WHISPER", target)
			return requestId
		end,
		QueueTransfer = function(_, kind, requestId, target, metadata, body)
			client.requests[#client.requests + 1] = kind
			if options.realProtocol then
				client.transfers[#client.transfers + 1] = kind
				local recipient = network.clients[target]
					or network.clients[string.upper(string.sub(target, 1, 1)) .. string.sub(target, 2)]
				if not recipient then
					for clientName, candidate in pairs(network.clients) do
						if string.lower(clientName) == string.lower(target) then
							recipient = candidate
							break
						end
					end
				end
				return recipient and recipient.receiveTransfer(name, kind, requestId, metadata, body) or false
			end
			local envelopeBody = deepCopy(metadata)
			envelopeBody.transferBody = deepCopy(body)
			local wire = network:encode(kind, requestId, target, envelopeBody)
			client.transfers[#client.transfers + 1] = kind
			if network.holdTransfers then
				network.heldTransfers[#network.heldTransfers + 1] = {
					sender = name,
					prefix = "RMARaidSync",
					wire = wire,
					target = target,
				}
				return true
			end
			network:deliver(name, "RMARaidSync", wire, "WHISPER", target)
			return true
		end,
		ReceiveChunk = function(_, sender, envelope)
			local request = pending[envelope.requestId]
			if not request then
				return nil, "UNKNOWN_REQUEST"
			end
			if envelope.kind ~= request.expectedKind then
				return nil, "RESPONSE_KIND_MISMATCH"
			end
			pending[envelope.requestId] = nil
			request.callback(true, "COMPLETE", envelope.body.transferBody)
			return true
		end,
		CancelRequest = function(_, requestId, reason)
			local request = pending[requestId]
			if not request then
				return false, "UNKNOWN_REQUEST"
			end
			pending[requestId] = nil
			client.cancelledRequests[#client.cancelledRequests + 1] = {
				requestId = requestId,
				reason = reason,
			}
			request.callback(false, reason or "CANCELLED")
			return true
		end,
	}
	local raidService = {
		ResolveRaidInstanceContext = function(_, instanceName, instanceDiff)
			local difficulty = tonumber(instanceDiff)
			if difficulty ~= 1 and difficulty ~= 2 and difficulty ~= 3 and difficulty ~= 4 then
				return nil, "INVALID_RAID_CONTEXT"
			end
			local size = (difficulty == 1 or difficulty == 3) and 10 or 25
			return { zone = instanceName, size = size, difficulty = difficulty }
		end,
	}
	if not options.productionCapabilities then
		raidService.GetRaidLeaderName = function()
			if options.overrideRaidLeaderIdentity then
				return options.reportedRaidLeaderName
			end
			return network.raidLeader
		end
		raidService.IsRaidLeader = function()
			if options.localRaidLeaderRole ~= nil then
				return options.localRaidLeaderRole == true
			end
			return name == network.raidLeader
		end
		raidService.IsGroupMember = function(_, sender)
			local short = type(sender) == "string" and (string.match(sender, "^([^%-]+)") or sender) or nil
			if not short then
				return false
			end
			local normalized = string.lower(short)
			if type(network.raidLeader) == "string" and string.lower(network.raidLeader) == normalized then
				return true
			end
			for clientName in pairs(network.clients) do
				if string.lower(clientName) == normalized then
					return true
				end
			end
			return false
		end
	end
	addon.Services = { Raid = raidService }
	if options.productionCapabilities then
		installProductionReentryRuntime(client)
	end
	if not options.productionCapabilities then
		_G.UnitName = function(unit)
			return unit == "player" and name or nil
		end
	end
	_G.GetTime = function()
		return network.now
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncer.lua")
	client.syncer = addon.DB.Syncer
	function client:FireHandoverTimer()
		local timer = self.timers and table.remove(self.timers, 1) or nil
		if timer then
			timer.callback()
			return true
		end
		return false
	end
	function client:FireTimerByDelay(expectedDelay)
		for index, timer in pairs(self.timers or {}) do
			if timer and timer.delay == expectedDelay and not timer.cancelled then
				self.timers[index] = nil
				timer.callback()
				return true
			end
		end
		return false
	end
	client.receiveTransfer = function(sender, kind, requestId, metadata, body)
		local request = pending[requestId]
		if not request or request.expectedKind ~= kind then
			return false
		end
		pending[requestId] = nil
		request.callback(true, "COMPLETE", deepCopy(body))
		return true
	end
	network.clients[name] = client
	return client
end

local function makeLiveEvent(sequence, epoch)
	return {
		raidUid = "raid-live",
		authorityEpoch = epoch or 1,
		sequence = sequence,
		eventUid = "raid-live:" .. tostring(epoch or 1) .. ":" .. tostring(sequence),
		eventType = "TEST",
		payload = { value = sequence },
		resultDigest = "0000000" .. tostring(sequence) .. ":1",
	}
end

local function makeConclusionEvent(sequence)
	local event = makeLiveEvent(sequence)
	event.eventType = "RAID_CONCLUDED"
	event.payload = { endTime = 1721120200 }
	return event
end

local function installFaithfulLiveReplica(addon, options)
	options = options or {}
	local realStore
	if options.realStore then
		realStore = installRaidArchiveFixture(addon)
		assert(realStore:CreateActiveRaid("Leader-Realm", newReplicationState(), 1721120000, 1))
	end
	local fixture = installRaidTransferSessionFixture(addon, { playerName = "Member" })
	fixture.raidLeader = "Leader"
	fixture.localRaidLeader = false
	local callbacks = {}
	fixture.callbacks = callbacks
	addon.L = {
		WarnRaidDatabaseAuthorityReleased = "Raid database authority passed to %s. This client now holds a read-only replica.",
		WarnRaidDatabaseAuthorityReceived = "Raid database authority received from %s. Recovery is in progress; raid history writes are temporarily paused.",
	}
	addon.Diagnose = { D = { LogRaidSyncTrace = "%s %s" } }
	addon.Diag = addon.Diagnose
	addon.warn = function() end
	addon.debug = function() end
	addon.IsInGroup = function()
		return true
	end
	addon.IsInRaid = function()
		return true
	end
	addon.Options = {
		RegisterNamespace = function() end,
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Events = {
		Internal = {
			OptionsLoaded = "OptionsLoaded",
			RaidCreate = "RaidCreate",
			RaidRosterDelta = "RaidRosterDelta",
			RaidReplicationCommitted = "RaidReplicationCommitted",
			LoggerSelectRaid = "LoggerSelectRaid",
			LoggerRaidOfferReceived = "LoggerRaidOfferReceived",
			RaidAuthorityRecoveryFinished = "RaidAuthorityRecoveryFinished",
			RaidInstanceRecognized = "RaidInstanceRecognized",
		},
		Wow = { ZoneChangedNewArea = "ZoneChangedNewArea", PartyLootMethodChanged = "PartyLootMethodChanged" },
	}
	addon.Bus = {
		RegisterCallback = function(eventName, callback)
			callbacks[eventName] = callbacks[eventName] or {}
			callbacks[eventName][#callbacks[eventName] + 1] = callback
		end,
		TriggerEvent = function() end,
	}
	fixture.store = realStore or newLiveReplicationStore(callbacks, makeLiveRecord(1))
	addon.DB.RaidStore = fixture.store
	addon.Services = {
		Raid = {
			GetRaidLeaderName = function()
				return fixture.raidLeader
			end,
			IsRaidLeader = function()
				return fixture.localRaidLeader
			end,
			IsGroupMember = function(_, sender)
				return string.match(tostring(sender or ""), "^([^%-]+)") == "Leader"
					or string.match(tostring(sender or ""), "^([^%-]+)") == "Member"
			end,
		},
	}
	addon.Comms.RegisterPrefixIfAvailable = function()
		return true
	end
	addon.Comms.SendAddonBatch = function(prefix, messages, target)
		if target then
			return addon.Comms.QueueAddonMessages(prefix, messages, "WHISPER", target)
		end
		return addon.Comms.QueueAddonMessages(prefix, messages, "RAID")
	end
	_G.UnitName = function(unit)
		if unit == "player" then
			return "Member"
		end
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncer.lua")
	fixture.syncer = addon.DB.Syncer
	return fixture
end

local function deliverFaithfulFinalSnapshot(fixture, requestEnvelope, finalSnapshot)
	assert(fixture.session:QueueTransfer("SNAP_DATA", requestEnvelope.requestId, "Member", {
		raidUid = finalSnapshot.raidUid,
		authorityEpoch = finalSnapshot.authorityEpoch,
		sequence = finalSnapshot.sequence,
	}, { snapshot = finalSnapshot }, fixture.session.RATE_CLASS_LIVE))
	local batch = fixture.batches[#fixture.batches]
	for i = 1, #batch.messages do
		local accepted, reason =
			fixture.syncer:OnAddonMessage("RMARaidSync", batch.messages[i], "WHISPER", "Leader-Test Realm")
		assertTrue(accepted ~= nil and accepted ~= false, "faithful final chunk rejected: " .. tostring(reason))
	end
end

local function deliverFaithfulRange(fixture, requestEnvelope, events)
	assert(fixture.session:QueueTransfer("RANGE_DATA", requestEnvelope.requestId, "Member", {
		raidUid = requestEnvelope.body.raidUid,
		authorityEpoch = requestEnvelope.body.authorityEpoch,
		fromSequence = requestEnvelope.body.fromSequence,
		toSequence = requestEnvelope.body.toSequence,
	}, { events = events }, fixture.session.RATE_CLASS_LIVE))
	local batch = fixture.batches[#fixture.batches]
	for i = 1, #batch.messages do
		local accepted, reason =
			fixture.syncer:OnAddonMessage("RMARaidSync", batch.messages[i], "WHISPER", "Leader-Test Realm")
		assertTrue(accepted ~= nil and accepted ~= false, "faithful range chunk rejected: " .. tostring(reason))
	end
end

function cases.raid_live_sync_event()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(0), { realProtocol = true })
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(0), { realProtocol = true })
	local event = makeLiveEvent(1)
	event.eventType = "RAID_METADATA_UPDATED"
	event.payload = { metadata = { zone = "Naxxramas", size = 25, difficulty = 1 } }
	leader.store:Commit(event)
	assertR5Envelope(leader.addon, leader.sentWires[#leader.sentWires], "EVENT")
	assertEqual(1, member.store.record.sequence, "replica did not apply authoritative event")
	assertEqual(leader.store.record.digest, member.store.record.digest, "replica digest diverged")
	print("PASS raid_live_sync_event")
end

function cases.raid_handover_real_recovery(addon)
	local fixture = installFaithfulLiveReplica(addon, { realStore = true })
	local store = fixture.store
	local original = store:CaptureRaidHistoryState()
	assert(store:SetAuthorityGuard(function()
		return true
	end))
	local active = assert(store:GetActiveRecord())
	local raidUid = assert(store:GetRaidUid(active.state))
	assert(store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
		metadata = { zone = "Naxxramas", size = 25, difficulty = 1 },
	}))
	local sourceSnapshot = assert(store:BuildSnapshot(raidUid))
	assert(store:RestoreRaidHistoryState(original))
	assert(store:SetAuthorityGuard(function()
		return fixture.localRaidLeader
	end))

	fixture.raidLeader = "Member"
	fixture.localRaidLeader = true
	local rosterCallbacks = assert(fixture.callbacks.RaidRosterDelta, "real roster callback missing")
	for i = 1, #rosterCallbacks do
		rosterCallbacks[i]("RaidRosterDelta")
	end
	assertTrue(fixture.syncer._handover ~= nil, "real handover transition was not detected")
	local head = {
		raidUid = sourceSnapshot.raidUid,
		authorityEpoch = sourceSnapshot.authorityEpoch,
		sequence = sourceSnapshot.sequence,
		checkpointSequence = sourceSnapshot.sequence,
		digest = sourceSnapshot.digest,
		status = "active",
	}
	local headWire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
	assert(fixture.syncer:OnAddonMessage("RMARaidSync", headWire, "RAID", "Leader-Test Realm"))
	local timer = assert(fixture.timers[1], "real handover selection timer missing")
	timer.callback()
	local request = assert(fixture.protocol.Decode(fixture.queued[#fixture.queued].message))
	assertEqual("SNAP_REQ", request.kind, "checkpointed handover did not request a snapshot")
	deliverFaithfulFinalSnapshot(fixture, request, sourceSnapshot)
	local promoted = assert(store:GetActiveRecord())
	assertEqual(sourceSnapshot.sequence, promoted.checkpointSequence, "real recovery checkpoint differs")
	assertEqual(sourceSnapshot.authorityEpoch + 1, promoted.authorityEpoch, "real recovery did not promote epoch")
	assertEqual(nil, fixture.syncer._handover, "real recovery retained handover state")
	print("PASS raid_handover_real_recovery")
end

function cases.raid_handover_store_promotion_is_recovery_only(addon)
	local store = installRaidArchiveFixture(addon)
	local recovering = false
	assert(store:SetAuthorityGuard(function(operation)
		if operation == "promote" then
			return true
		end
		if recovering then
			return false, "AUTHORITY_RECOVERING"
		end
		return true
	end))
	local _, _, raidUid = assert(store:CreateActiveRaid({
		authorityKey = "Leader-Realm",
		serverTime = 1721120000,
		zone = "Naxxramas",
		size = 25,
		difficulty = 1,
		players = {},
		bossKills = {},
		attendance = {},
		loot = {},
	}))
	local before = deepCopy(assert(store:GetRecord(raidUid)))
	recovering = true
	local rejected, reason = store:CommitAuthoritativeEvent(raidUid, "PLAYER_UPDATED", {
		player = { playerNid = 2, name = "Marco", join = 1721120001, countMS = 0 },
	})
	assertEqual(nil, rejected, "recovering store accepted a canonical mutation")
	assertEqual("AUTHORITY_RECOVERING", reason, "recovering rejection reason differs")
	assertTrue(deepEqual(before, store:GetRecord(raidUid)), "rejected mutation changed state")

	local promoted = assert(store:PromoteAuthority(raidUid, before.sequence))
	assertEqual(before.authorityEpoch + 1, promoted.authorityEpoch, "promotion did not increment epoch")
	assertEqual(before.sequence, promoted.sequence, "promotion replayed an event")
	assertEqual(before.sequence, promoted.checkpointSequence, "checkpoint differs")
	assertEqual(0, #promoted.events, "promotion retained a staged ledger")
	print("PASS raid_handover_store_promotion_is_recovery_only")
end

function cases.raid_handover_mutation_detects_authority_change()
	local network = newLiveReplicationNetwork()
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(2))
	network.raidLeader = "Member"
	local committed, reason = member.store:CommitAuthoritativeEvent("raid-live", "TEST", { value = 3 })
	assertEqual(nil, committed, "pre-event mutation bypassed recovery read-only mode")
	assertEqual("AUTHORITY_RECOVERING", reason, "pre-event mutation rejection reason differs")
	assertEqual("handover", member.syncer:GetStatus(), "pre-event mutation did not enter handover status")
	assertEqual(2, member.store.record.sequence, "pre-event mutation changed canonical state")
	assertEqual(0, #member.requests, "pre-event mutation emitted sync traffic")
	assertTrue(member.syncer:IsAuthorityRecovering("raid-live"), "pre-event mutation did not leave recovery active")
	print("PASS raid_handover_mutation_detects_authority_change")
end

function cases.raid_handover_repeated_authority_change(addon)
	local fixture = installFaithfulLiveReplica(addon, { realStore = true })
	local store = fixture.store
	local raidUid = assert(store:GetRaidUid(store:GetActiveRecord().state))
	local function countArchiveRecords(archive)
		local recordCount = 0
		local distinctRaidUids = {}
		for archiveRaidUid in pairs(archive.raids or {}) do
			recordCount = recordCount + 1
			if type(archiveRaidUid) == "string" then
				distinctRaidUids[archiveRaidUid] = true
			end
		end
		local distinctRaidUidCount = 0
		for _ in pairs(distinctRaidUids) do
			distinctRaidUidCount = distinctRaidUidCount + 1
		end
		return recordCount, distinctRaidUidCount
	end
	local originalArchiveRecordCount, originalDistinctRaidUidCount = countArchiveRecords(store:EnsureArchive())
	assertEqual(1, originalArchiveRecordCount, "real handover fixture record count differs")
	assertEqual(1, originalDistinctRaidUidCount, "real handover fixture UID count differs")
	local source = assert(store:BuildSnapshot(raidUid))
	source.sequence = source.sequence + 1
	source.checkpointSequence = source.sequence
	source.digest = "12345678:42"

	fixture.raidLeader = "Member"
	fixture.localRaidLeader = true
	local callbacks = assert(fixture.callbacks.PartyLootMethodChanged, "loot-method callback missing")
	for i = 1, #callbacks do
		callbacks[i]("PartyLootMethodChanged")
	end
	local head = {
		raidUid = raidUid,
		authorityEpoch = source.authorityEpoch,
		sequence = source.sequence,
		checkpointSequence = source.checkpointSequence,
		digest = source.digest,
		status = "active",
	}
	local headWire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
	assert(fixture.syncer:OnAddonMessage("RMARaidSync", headWire, "RAID", "Leader-Test Realm"))
	local oldSelection = assert(fixture.timers[1], "first handover timer missing")
	oldSelection.callback()
	local oldRequestId
	for requestId in pairs(fixture.session._pendingRequests) do
		oldRequestId = requestId
	end
	assertTrue(oldRequestId ~= nil, "first handover did not start recovery")

	fixture.raidLeader = "Leader"
	fixture.localRaidLeader = false
	for i = 1, #callbacks do
		callbacks[i]("PartyLootMethodChanged")
	end
	assertEqual(nil, fixture.syncer._handover, "lost authority retained handover")
	assertEqual(nil, fixture.session._pendingRequests[oldRequestId], "lost authority retained pending recovery")
	oldSelection.callback()
	assertEqual(1, store:GetActiveRecord().authorityEpoch, "stale handover callback promoted authority")
	local finalArchive = store:EnsureArchive()
	local finalArchiveRecordCount, finalDistinctRaidUidCount = countArchiveRecords(finalArchive)
	assertEqual(raidUid, finalArchive.activeRaidUid, "real handover changed the active raid UID")
	assertEqual(originalArchiveRecordCount, finalArchiveRecordCount, "real handover created a second archive record")
	assertEqual(originalDistinctRaidUidCount, finalDistinctRaidUidCount, "real handover created a second raid UID")

	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(1))
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))
	local originalUid = member.store.record.raidUid
	local originalState = deepCopy(member.store.record.state)
	network.raidLeader = "Member"
	for i = 1, #(member.callbacks.PartyLootMethodChanged or {}) do
		member.callbacks.PartyLootMethodChanged[i]()
	end
	for i = 1, #(leader.callbacks.PartyLootMethodChanged or {}) do
		leader.callbacks.PartyLootMethodChanged[i]()
	end
	local staleCallback = assert(member.timers[1], "B handover timer missing").callback
	network.raidLeader = "Leader"
	for i = 1, #(member.callbacks.PartyLootMethodChanged or {}) do
		member.callbacks.PartyLootMethodChanged[i]()
	end
	for i = 1, #(leader.callbacks.PartyLootMethodChanged or {}) do
		leader.callbacks.PartyLootMethodChanged[i]()
	end
	staleCallback()
	assertEqual(1, member.store.record.authorityEpoch, "stale B handover promoted after A regained authority")
	assertEqual(1, #member.recoveryFinished, "stale B handover failure event count differs")
	assertEqual(false, member.recoveryFinished[1].succeeded, "stale B handover published success")
	assertTrue(leader:FireHandoverTimer(), "replacement A handover timer missing")
	assertEqual(2, leader.store.record.authorityEpoch, "replacement A handover did not promote")
	assertEqual(1, #member.recoveryFinished, "replacement A duplicated B's failure event")
	assertEqual(1, #leader.recoveryFinished, "replacement A success event count differs")
	assertEqual(true, leader.recoveryFinished[1].succeeded, "replacement A did not publish success")
	assertEqual(originalUid, leader.store.record.raidUid, "handover changed the stable raid UID")
	assertEqual(originalUid, member.store.record.raidUid, "old leader retained a different raid UID")
	assertTrue(deepEqual(originalState, leader.store.record.state), "handover changed the leader raid state")
	assertTrue(deepEqual(originalState, member.store.record.state), "old leader retained different raid state")
	print("PASS raid_handover_repeated_authority_change")
end

function cases.raid_live_sync_replica_loot_refreshes_history()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(1))
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))
	local refreshes = 0
	member.addon.Bus.RegisterCallback(member.addon.Events.Internal.LoggerDataChanged, function()
		refreshes = refreshes + 1
	end)
	local event = makeLiveEvent(2)
	event.eventType = "LOOT_ADDED"
	event.payload = { loot = { lootNid = 1, itemLink = "item:19019", itemCount = 1 } }
	assert(leader.store:Commit(event))
	assertEqual(1, #(member.store.record.state.loot or {}), "replica did not persist the loot row")
	assertEqual(1, refreshes, "replica loot did not invalidate Loot History")
	print("PASS raid_live_sync_replica_loot_refreshes_history")
end

function cases.raid_live_sync_new_replica_selects_loot_history_once()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(0))
	local member = installLiveReplicationClient(network, "Member", nil)
	member.selections = {}
	local refreshes = 0
	member.addon.Bus.RegisterCallback(member.addon.Events.Internal.LoggerSelectRaid, function(_, raidIndex, reason)
		member.selections[#member.selections + 1] = { raidIndex = raidIndex, reason = reason }
	end)
	member.addon.Bus.RegisterCallback(member.addon.Events.Internal.LoggerDataChanged, function()
		refreshes = refreshes + 1
	end)

	local initial = makeLiveEvent(1)
	initial.eventType = "LOOT_ADDED"
	initial.payload = { loot = { lootNid = 1, itemLink = "item:19019", itemCount = 1 } }
	assert(leader.store:Commit(initial))
	assertEqual(nil, member.addon.Database.GetCurrentRaid(), "replica became B's current raid")
	assertEqual(1, #member.selections, "new replica was not selected exactly once")
	assertEqual("sync", member.selections[1].reason, "selection reason differs")
	assertEqual(1, #(member.raidStore:GetActiveRecord().state.loot or {}), "loot did not reach B")
	assertEqual(1, refreshes, "new replica did not refresh Loot History")

	local delta = makeLiveEvent(2)
	delta.eventType = "LOOT_UPDATED"
	delta.payload = { loot = { lootNid = 1, itemLink = "item:19019", itemCount = 2 } }
	assert(leader.store:Commit(delta))
	assertEqual(1, #member.selections, "replica delta stole Loot History selection")
	assertEqual(2, refreshes, "replica delta did not refresh Loot History")
	print("PASS raid_live_sync_new_replica_selects_loot_history_once")
end

local function fireLiveReplicationCallback(client, eventName)
	local callbacks = client.callbacks[eventName] or {}
	for i = 1, #callbacks do
		callbacks[i](eventName)
	end
end

function cases.raid_fresh_leader_entry_creates_without_recovery()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", nil)
	assertEqual(nil, leader.addon.Database.GetCurrentRaid(), "fresh runtime unexpectedly had a current raid")
	assertEqual(nil, leader.store:GetActiveRecord(), "fresh archive unexpectedly had an active record")
	assertEqual("leader", leader.syncer._knownAuthority, "fresh leader authority was not already known")
	assertEqual(nil, leader.syncer._reentry, "fresh leader started with reentry state")
	assertEqual(nil, leader.syncer._handover, "fresh leader started with handover state")

	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assertEqual(nil, leader.syncer._reentry, "fresh leader entry started archive recovery")
	assertEqual(nil, leader.syncer._handover, "fresh leader entry started authority handover")
	assertEqual(false, leader.syncer:IsAuthorityRecovering(), "fresh leader entry closed the write barrier")

	leader.store.record = makeLiveRecord(1)
	leader.currentRaid = 1
	local committed, reason = leader.store:Commit(makeLiveEvent(2))
	assertTrue(committed ~= nil, "fresh raid write remained blocked: " .. tostring(reason))
	assertEqual(2, leader.store.record.sequence, "fresh raid write did not commit")
	print("PASS raid_fresh_leader_entry_creates_without_recovery")
end

function cases.raid_initial_authority_discovery_is_not_handover()
	local network = newLiveReplicationNetwork()
	local options = {
		overrideRaidLeaderIdentity = true,
		localRaidLeaderRole = true,
	}
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(1), options)
	assertEqual(1, leader.addon.Database.GetCurrentRaid(), "runtime current raid was not independent")
	assertTrue(leader.store:GetActiveRecord() ~= nil, "archive active record was not independent")
	assertEqual(nil, leader.syncer._knownAuthority, "initial authority was unexpectedly known")
	assertEqual(nil, leader.syncer._reentry, "initial discovery started with reentry state")
	assertEqual(nil, leader.syncer._handover, "initial discovery started with handover state")

	options.reportedRaidLeaderName = "Leader"
	fireLiveReplicationCallback(leader, "RaidRosterDelta")
	assertEqual("leader", leader.syncer._knownAuthority, "initial authority was not recorded")
	assertEqual(nil, leader.syncer._reentry, "initial authority discovery started reentry")
	assertEqual(nil, leader.syncer._handover, "initial authority discovery was classified as handover")
	assertEqual(
		false,
		leader.syncer:IsAuthorityRecovering("raid-live"),
		"initial authority discovery closed the write barrier"
	)
	print("PASS raid_initial_authority_discovery_is_not_handover")
end

function cases.raid_reentry_and_handover_are_mutually_exclusive()
	local reentryNetwork = newLiveReplicationNetwork()
	local reentryOptions = {
		overrideRaidLeaderIdentity = true,
		localRaidLeaderRole = true,
	}
	local returning = installLiveReplicationClient(reentryNetwork, "Leader", makeLiveRecord(2), reentryOptions)
	returning.currentRaid = nil
	assertEqual(nil, returning.addon.Database.GetCurrentRaid(), "reentry runtime still had a current raid")
	assertTrue(returning.store:GetActiveRecord() ~= nil, "reentry archive lost its active record")
	assertEqual(nil, returning.syncer._knownAuthority, "reentry authority was unexpectedly known")
	reentryOptions.reportedRaidLeaderName = "Leader"
	returning.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assertTrue(returning.syncer._reentry ~= nil, "returning leader did not start reentry")
	assertEqual(nil, returning.syncer._handover, "reentry also created handover state")

	local handoverNetwork = newLiveReplicationNetwork()
	local promoted = installLiveReplicationClient(handoverNetwork, "Member", makeLiveRecord(2))
	promoted.currentRaid = nil
	assertEqual("leader", promoted.syncer._knownAuthority, "previous handover authority was not known")
	handoverNetwork.raidLeader = "Member"
	local started, reason = promoted.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assertEqual(false, started, "active handover allowed reentry to start")
	assertEqual("HANDOVER_ACTIVE", reason, "active handover rejection reason differs")
	assertEqual(nil, promoted.syncer._reentry, "handover also created reentry state")
	assertTrue(promoted.syncer._handover ~= nil, "real authority change did not retain handover")
	print("PASS raid_reentry_and_handover_are_mutually_exclusive")
end

function cases.raid_handover_recovery_lifecycle_and_warnings()
	local network = newLiveReplicationNetwork()
	local oldLeader = installLiveReplicationClient(network, "Leader", makeLiveRecord(3))
	local newLeader = installLiveReplicationClient(network, "Member", makeLiveRecord(2))
	local ordinary = installLiveReplicationClient(network, "Other", makeLiveRecord(2))
	oldLeader.warnings, newLeader.warnings, ordinary.warnings = {}, {}, {}
	network.raidLeader = "Member"
	fireLiveReplicationCallback(oldLeader, "RaidRosterDelta")
	fireLiveReplicationCallback(newLeader, "RaidRosterDelta")
	fireLiveReplicationCallback(ordinary, "RaidRosterDelta")
	fireLiveReplicationCallback(oldLeader, "RaidRosterDelta")
	fireLiveReplicationCallback(newLeader, "RaidRosterDelta")
	assertEqual(1, #oldLeader.warnings, "old leader warning count differs")
	assertEqual(1, #newLeader.warnings, "new leader warning count differs")
	assertEqual(0, #ordinary.warnings, "ordinary member received authority warning")
	assertTrue(newLeader.syncer:IsAuthorityRecovering("raid-live"), "handover is not read-only")
	assertTrue(newLeader:FireHandoverTimer(), "handover timer was not fired")
	assertEqual(false, newLeader.syncer:IsAuthorityRecovering("raid-live"), "recovery remained closed")
	assertEqual(1, #newLeader.recoveryFinished, "recovery event count differs")
	assertEqual(true, newLeader.recoveryFinished[1].succeeded, "recovery did not publish success")
	print("PASS raid_handover_recovery_lifecycle_and_warnings")
end

function cases.raid_handover_begin_request_failures_close_recovery_once()
	local function assertHandoverFailure(kind, sourceRecord, reason)
		local network = newLiveReplicationNetwork()
		local oldLeader = installLiveReplicationClient(network, "Leader", sourceRecord)
		local newLeader = installLiveReplicationClient(network, "Member", makeLiveRecord(1), {
			beginRequestFailures = { [kind] = reason },
		})
		network.raidLeader = "Member"
		fireLiveReplicationCallback(oldLeader, "RaidRosterDelta")
		local staleTimer = assert(newLeader.timers[1], kind .. " handover timer missing").callback
		assertTrue(newLeader:FireHandoverTimer(), kind .. " handover timer did not fire")
		assertEqual(false, newLeader.syncer:IsAuthorityRecovering("raid-live"), kind .. " recovery remained open")
		assertEqual(1, #newLeader.recoveryFinished, kind .. " failure event count differs")
		assertEqual(false, newLeader.recoveryFinished[1].succeeded, kind .. " published success")
		assertEqual(reason, newLeader.recoveryFinished[1].reason, kind .. " failure reason differs")
		assertEqual(true, newLeader.recoveryFinished[1].recovering, kind .. " cleared handover before failure event")
		local status, statusReason = newLeader.syncer:GetStatus()
		assertEqual("suspended", status, kind .. " BeginRequest failure did not suspend")
		assertEqual(reason, statusReason, kind .. " suspended reason differs")
		assertTrue(newLeader.lastBeginRequestCallback ~= nil, kind .. " BeginRequest callback was not captured")
		newLeader.lastBeginRequestCallback(false, "STALE_CALLBACK")
		staleTimer()
		fireLiveReplicationCallback(oldLeader, "RaidRosterDelta")
		fireLiveReplicationCallback(newLeader, "RaidRosterDelta")
		assertEqual(1, #newLeader.recoveryFinished, kind .. " stale work duplicated the failure event")
		assertEqual(false, newLeader.recoveryFinished[1].succeeded, kind .. " stale work published success")
	end

	assertHandoverFailure("RANGE_REQ", makeLiveRecord(3), "INJECTED_RANGE_BEGIN_FAILURE")
	local snapshotSource = makeLiveRecord(3)
	snapshotSource.checkpointSequence = snapshotSource.sequence
	assertHandoverFailure("SNAP_REQ", snapshotSource, "INJECTED_SNAPSHOT_BEGIN_FAILURE")

	local network = newLiveReplicationNetwork()
	installLiveReplicationClient(network, "Leader", makeLiveRecord(3))
	local replica = installLiveReplicationClient(network, "Member", makeLiveRecord(1), {
		beginRequestFailures = { SNAP_REQ = "INJECTED_REPLICA_BEGIN_FAILURE" },
	})
	local head = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 3,
		digest = "00000003:1",
		status = "active",
	}
	local requested, requestReason = replica.syncer:RequestSnapshot("Leader", head)
	assertEqual(false, requested, "non-handover BeginRequest failure was accepted")
	assertEqual("INJECTED_REPLICA_BEGIN_FAILURE", requestReason, "non-handover failure reason differs")
	local status, statusReason = replica.syncer:GetStatus()
	assertEqual("failed", status, "non-handover BeginRequest failure did not retain failed status")
	assertEqual("INJECTED_REPLICA_BEGIN_FAILURE", statusReason, "non-handover failed reason differs")
	assertEqual(0, #replica.recoveryFinished, "non-handover failure published authority lifecycle")
	print("PASS raid_handover_begin_request_failures_close_recovery_once")
end

function cases.raid_handover_previous_authority()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(3))
	local outsider = installLiveReplicationClient(network, "Outsider", makeLiveRecord(4))
	network.raidLeader = "Member"
	fireLiveReplicationCallback(member, "RaidRosterDelta")
	fireLiveReplicationCallback(outsider, "RaidRosterDelta")
	fireLiveReplicationCallback(leader, "RaidRosterDelta")
	local oldWrite = network:encode("EVENT", "-", "-", { event = makeLiveEvent(4) })
	local accepted = member.syncer:OnAddonMessage("RMARaidSync", oldWrite, "RAID", "Leader-Test Realm")
	assertEqual(false, accepted, "previous authority write was accepted after role change")
	assertTrue(member:FireHandoverTimer(), "handover selection was not scheduled")
	assertEqual(2, member.store.record.authorityEpoch, "previous authority recovery did not promote")
	assertEqual(2, member.store.record.sequence, "previous authority was not preferred as recovery source")

	local fallbackNetwork = newLiveReplicationNetwork()
	local fallbackMember = installLiveReplicationClient(fallbackNetwork, "Member", makeLiveRecord(1))
	local highest = installLiveReplicationClient(fallbackNetwork, "Outsider", makeLiveRecord(4))
	fallbackNetwork.clients.Leader = nil
	fallbackNetwork.raidLeader = "Member"
	fireLiveReplicationCallback(fallbackMember, "RaidRosterDelta")
	fireLiveReplicationCallback(highest, "RaidRosterDelta")
	assertTrue(fallbackMember:FireHandoverTimer(), "fallback handover selection was not scheduled")
	assertEqual(
		4,
		fallbackMember.store.record.sequence,
		"highest valid peer was not selected without previous authority"
	)
	assertEqual(2, fallbackMember.store.record.authorityEpoch, "fallback recovery did not promote")
	print("PASS raid_handover_previous_authority")
end

function cases.raid_handover_digest_conflict()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(3, "00000003:1"))
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(2))
	local outsider = installLiveReplicationClient(network, "Outsider", makeLiveRecord(3, "99999999:1"))
	network.raidLeader = "Member"
	fireLiveReplicationCallback(member, "RaidRosterDelta")
	fireLiveReplicationCallback(leader, "RaidRosterDelta")
	fireLiveReplicationCallback(outsider, "RaidRosterDelta")
	assertTrue(member:FireHandoverTimer(), "handover selection was not scheduled")
	local status, reason = member.syncer:GetStatus()
	assertEqual("suspended", status, "divergent tied heads did not suspend synchronization")
	assertEqual("DIGEST_CONFLICT", reason, "handover conflict reason differs")
	assertEqual(1, member.store.record.authorityEpoch, "conflicted handover advanced epoch")
	assertEqual(2, member.store.record.sequence, "conflicted handover changed local state")
	print("PASS raid_handover_digest_conflict")
end

function cases.raid_handover_digest_conflict_keeps_write_barrier(addon)
	local fixture = installFaithfulLiveReplica(addon, { realStore = true })
	local store = fixture.store
	local active = assert(store:GetActiveRecord(), "real conflict fixture has no active raid")
	local raidUid = assert(store:GetRaidUid(active.state), "real conflict fixture has no active UID")
	local before = store:CaptureRaidHistoryState()

	fixture.raidLeader = "Member"
	fixture.localRaidLeader = true
	local rosterCallbacks = assert(fixture.callbacks.RaidRosterDelta, "real roster callback missing")
	for i = 1, #rosterCallbacks do
		rosterCallbacks[i]("RaidRosterDelta")
	end
	assertTrue(fixture.syncer._handover ~= nil, "real digest conflict did not start handover")

	local conflictingHead = {
		raidUid = raidUid,
		authorityEpoch = active.authorityEpoch,
		sequence = active.sequence,
		checkpointSequence = active.checkpointSequence,
		digest = "ffffffff:1",
		status = "active",
	}
	local headWire = assert(fixture.protocol.Encode("HEAD", "-", "-", conflictingHead))
	assert(fixture.syncer:OnAddonMessage("RMARaidSync", headWire, "RAID", "Leader-Test Realm"))
	assert(fixture.timers[1], "real conflict selection timer missing").callback()

	local status, statusReason = fixture.syncer:GetStatus()
	assertEqual("suspended", status, "real digest conflict did not remain suspended")
	assertEqual("DIGEST_CONFLICT", statusReason, "real digest conflict status reason differs")
	assertTrue(fixture.syncer:IsAuthorityRecovering(raidUid), "digest conflict reopened the authority barrier")

	local created, createReason = store:CreateActiveRaid({
		authorityKey = "Member-Test Realm",
		serverTime = 101,
		zone = "Naxxramas",
		size = 10,
		difficulty = 1,
	})
	assertEqual(nil, created, "digest conflict allowed a competing active raid")
	assertEqual("AUTHORITY_RECOVERING", createReason, "conflicted create rejection reason differs")
	local committed, commitReason = store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
		metadata = { zone = "Icecrown Citadel" },
	})
	assertEqual(nil, committed, "digest conflict allowed an authoritative event")
	assertEqual("AUTHORITY_RECOVERING", commitReason, "conflicted commit rejection reason differs")
	assertTrue(deepEqual(before, store:CaptureRaidHistoryState()), "digest conflict overwrote the local copy")

	fixture.raidLeader = "Leader"
	fixture.localRaidLeader = false
	for i = 1, #rosterCallbacks do
		rosterCallbacks[i]("RaidRosterDelta")
	end
	assertEqual(nil, fixture.syncer._handover, "authority change retained the obsolete conflicted transition")
	assertEqual(
		false,
		fixture.syncer:IsAuthorityRecovering(raidUid),
		"authority change retained the obsolete conflict barrier"
	)
	print("PASS raid_handover_digest_conflict_keeps_write_barrier")
end

function cases.raid_handover_without_local_head_discovers_before_create(addon)
	local sourceAddon = newAddon()
	local sourceStore = installRaidArchiveFixture(sourceAddon)
	local _, _, sourceRaidUid = assert(sourceStore:CreateActiveRaid({
		authorityKey = "ReplicaB-TestRealm",
		serverTime = 100,
		zone = "Naxxramas",
		size = 10,
		difficulty = 1,
		players = {
			{ playerNid = 1, name = "ReplicaB", rank = 2, subgroup = 1, class = "MAGE", join = 100 },
		},
		nextPlayerNid = 2,
	}))
	local sourceSnapshot = assert(sourceStore:BuildSnapshot(sourceRaidUid))

	local recoveryNetwork = newLiveReplicationNetwork()
	recoveryNetwork.raidLeader = "Member"
	local promoted = installLiveReplicationClient(
		recoveryNetwork,
		"Member",
		nil,
		{ realStore = true, productionCapabilities = true }
	)
	promoted.syncer._knownAuthority = "replicab"
	promoted:RestoreProductionUnitApi()
	assertEqual(
		"Member",
		promoted.addon.Services.Raid:GetRaidLeaderName(),
		"production headless recovery leader identity differs"
	)
	assertEqual(
		true,
		promoted.addon.Services.Raid:IsRaidLeader(),
		"production headless recovery leader capability differs"
	)
	assertEqual(
		true,
		promoted.addon.Services.Raid:IsGroupMember("ReplicaB-Test Realm"),
		"production headless recovery does not recognize the previous authority"
	)
	local recoveredCreatedEvents = 0
	promoted.addon.Bus.RegisterCallback(promoted.addon.Events.Internal.RaidReplicationCommitted, function(_, event)
		if event and event.eventType == "RAID_CREATED" then
			recoveredCreatedEvents = recoveredCreatedEvents + 1
		end
	end)

	promoted.addon:ZONE_CHANGED_NEW_AREA()
	assertTrue(promoted.syncer._handover ~= nil, "headless authority transition did not start handover discovery")
	assertTrue(promoted.syncer:IsAuthorityRecovering(), "headless handover did not close the write barrier")
	assertEqual(nil, promoted.store:GetActiveRecord(), "instance check created before remote HEAD discovery")
	assertEqual(nil, promoted.addon.Database.GetCurrentRaid(), "instance check selected a competing raid before HEAD")
	local checked, checkReason = promoted.addon.Services.Raid:Check("Naxxramas", 1)
	assertEqual(false, checked, "production Session check bypassed headless discovery")
	assertEqual("AUTHORITY_RECOVERING", checkReason, "headless Session rejection reason differs")
	assertEqual(
		"AUTHORITY_RECOVERING",
		select(
			2,
			promoted.store:CreateActiveRaid({
				authorityKey = "Member-Test Realm",
				serverTime = 101,
				zone = "Naxxramas",
				size = 10,
				difficulty = 1,
			})
		),
		"headless direct create bypassed the real authority guard"
	)
	assertEqual(
		"AUTHORITY_RECOVERING",
		select(
			2,
			promoted.store:CommitAuthoritativeEvent(
				sourceRaidUid,
				"RAID_METADATA_UPDATED",
				{ metadata = { zone = "Icecrown Citadel" } }
			)
		),
		"headless authoritative event bypassed the real authority guard"
	)

	local source = installLiveReplicationClient(recoveryNetwork, "ReplicaB", sourceSnapshot)
	promoted:RestoreProductionUnitApi()
	local sourceHead = {
		raidUid = sourceSnapshot.raidUid,
		authorityEpoch = sourceSnapshot.authorityEpoch,
		sequence = sourceSnapshot.sequence,
		checkpointSequence = sourceSnapshot.checkpointSequence,
		digest = sourceSnapshot.digest,
		status = sourceSnapshot.status,
	}
	local headWire = recoveryNetwork:encode("HEAD", "-", "-", sourceHead)
	local acceptedHead, headReason =
		promoted.syncer:OnAddonMessage("RMARaidSync", headWire, "RAID", "ReplicaB-Test Realm")
	assertTrue(acceptedHead == true, "valid headless recovery HEAD was rejected: " .. tostring(headReason))
	assertTrue(promoted:FireHandoverTimer(), "headless handover selection timer was not fired")
	local recovered = assert(promoted.store:GetActiveRecord(), "valid remote snapshot was not installed")
	assertEqual(
		sourceSnapshot.raidUid,
		promoted.store:GetRaidUid(recovered.state),
		"headless recovery installed a competing raid UID"
	)
	assertEqual(
		sourceSnapshot.authorityEpoch + 1,
		recovered.authorityEpoch,
		"headless recovery did not promote the recovered authority epoch"
	)
	assertEqual(0, recoveredCreatedEvents, "headless recovery emitted a competing RAID_CREATED event")
	local recoveredIndex = assert(promoted.store:GetIndexByUid(sourceRaidUid), "recovered raid index is missing")
	assertEqual(
		recoveredIndex,
		promoted.addon.Database.GetCurrentRaid(),
		"headless recovery did not select the recovered raid"
	)
	assertEqual(
		false,
		promoted.syncer:IsAuthorityRecovering(sourceRaidUid),
		"headless recovery retained the write barrier after selection"
	)
	local beforeRecoveredWrite = recovered.sequence
	local terminalEvent, terminalReason = promoted.store:CommitAuthoritativeEvent(
		sourceRaidUid,
		"RAID_METADATA_UPDATED",
		{ metadata = { zone = "Icecrown Citadel" } }
	)
	assertTrue(
		terminalEvent ~= nil,
		"headless recovery did not enable authoritative writes: " .. tostring(terminalReason)
	)
	local terminalRecord = assert(promoted.store:GetRecord(sourceRaidUid), "terminal recovered raid is missing")
	assertEqual(beforeRecoveredWrite + 1, terminalRecord.sequence, "terminal authoritative write sequence differs")
	assertEqual(
		"Icecrown Citadel",
		terminalRecord.state.zone,
		"terminal authoritative write did not mutate recovered state"
	)
	assertEqual(1, #RMA_Raids.order, "headless terminal recovery stored more than one raid UID")
	assertTrue(source.store:GetActiveRecord() ~= nil, "remote recovery source was overwritten")

	local freshNetwork = newLiveReplicationNetwork()
	freshNetwork.raidLeader = "Solo"
	local fresh =
		installLiveReplicationClient(freshNetwork, "Solo", nil, { realStore = true, productionCapabilities = true })
	fresh.syncer._knownAuthority = "replicab"
	fresh:RestoreProductionUnitApi()
	assertEqual("Solo", fresh.addon.Services.Raid:GetRaidLeaderName(), "production no-copy leader identity differs")
	assertEqual(true, fresh.addon.Services.Raid:IsRaidLeader(), "production no-copy leader capability differs")
	local freshCreatedEvents = 0
	fresh.addon.Bus.RegisterCallback(fresh.addon.Events.Internal.RaidReplicationCommitted, function(_, event)
		if event and event.eventType == "RAID_CREATED" then
			freshCreatedEvents = freshCreatedEvents + 1
		end
	end)
	fresh.addon:ZONE_CHANGED_NEW_AREA()
	assertTrue(fresh.syncer:IsAuthorityRecovering(), "no-copy discovery did not close the write barrier")
	assertEqual(nil, fresh.store:GetActiveRecord(), "no-copy discovery created before its bound")
	assertTrue(fresh:FireHandoverTimer(), "no-copy discovery timer was not fired")
	assertEqual(nil, fresh.syncer._handover, "bounded no-copy discovery retained handover")
	assertEqual(false, fresh.syncer:IsAuthorityRecovering(), "bounded no-copy discovery retained the write barrier")
	fresh.addon.Services.Raid:Check("Naxxramas", 1)
	local created = assert(fresh.store:GetActiveRecord(), "bounded no-copy outcome did not allow fresh creation")
	local createdUid = assert(fresh.store:GetRaidUid(created.state))
	assertEqual(
		fresh.addon.Database.GetCurrentRaid(),
		fresh.store:GetIndexByUid(createdUid),
		"fresh lifecycle did not select the created raid"
	)
	fresh.addon.Services.Raid:Check("Naxxramas", 1)
	assertEqual(1, freshCreatedEvents, "bounded no-copy outcome created more than one raid")
	assertEqual(1, #RMA_Raids.order, "bounded no-copy outcome stored more than one raid")
	print("PASS raid_handover_without_local_head_discovers_before_create")
end

local function countMessageKind(kinds, expected)
	local count = 0
	for i = 1, #kinds do
		if kinds[i] == expected then
			count = count + 1
		end
	end
	return count
end

function cases.raid_live_sync_oversized_event_head_fallback()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(0), { realProtocol = true })
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(0), { realProtocol = true })
	local raidEvents = leader.addon.DB.RaidEvents
	local event = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 1,
		eventUid = assert(raidEvents.BuildEventUid("raid-live", 1, 1)),
		eventType = "PLAYER_UPDATED",
		payload = { player = { playerNid = 1, name = string.rep("A", 300) } },
		resultDigest = "00000001:1",
	}
	local direct, directReason = leader.protocol.Encode("EVENT", "-", "-", { event = event })
	assertEqual(nil, direct, "representative oversized event unexpectedly fit direct wire")
	assertEqual("MESSAGE_TOO_LARGE", directReason, "oversized protocol rejection reason differs")
	assert(leader.store:Commit(event))
	assertEqual(0, countMessageKind(leader.requests, "HEAD"), "oversized event sent an immediate HEAD")
	assertEqual(
		0,
		countMessageKind(member.requests, "RANGE_REQ"),
		"oversized event started range recovery before trailing HEAD"
	)
	assertTrue(leader:FireTimerByDelay(0.25), "oversized event did not schedule trailing HEAD")
	assertEqual(1, member.store.record.sequence, "trailing HEAD did not converge oversized event")
	assertEqual(1, countMessageKind(leader.requests, "HEAD"), "oversized event did not publish one trailing HEAD")
	assertEqual(1, countMessageKind(member.requests, "RANGE_REQ"), "trailing HEAD did not request missing range")
	print("PASS raid_live_sync_oversized_event_head_fallback")
end

local function commitRealCompactLiveLoot(leader, lootNid)
	local record = assert(leader.store:GetActiveRecord())
	local raidUid = assert(leader.store:GetRaidUid(record.state))
	local loot = deepCopy(protocolBodies().LIVE_LOOT.event.payload.loot)
	loot.lootNid = lootNid
	loot.looterNid = 1
	loot.source = nil
	return assert(leader.store:CommitAuthoritativeEvent(raidUid, "LOOT_ADDED", {
		loot = loot,
	}))
end

local function installAlignedRealLiveReplicationClients(network, options)
	options = options or {}
	local leader = installLiveReplicationClient(network, "Leader", nil, {
		realProtocol = true,
		realStore = true,
		seedActiveRaid = true,
		seedServerTime = options.seedServerTime,
	})
	local snapshot = assert(leader.store:BuildSnapshot(leader.seedRaidUid))
	local memberB = installLiveReplicationClient(network, "MemberB", nil, { realProtocol = true, realStore = true })
	local memberC = installLiveReplicationClient(network, "MemberC", nil, { realProtocol = true, realStore = true })
	assert(memberB.store:ReplaceActiveFromSnapshot(snapshot))
	assert(memberC.store:ReplaceActiveFromSnapshot(snapshot))
	leader.currentRaid, memberB.currentRaid, memberC.currentRaid = 1, 1, 1
	return leader, memberB, memberC
end

local function realisticGroupLootPayload(lootNid, lootSource)
	return {
		loot = {
			lootNid = lootNid,
			itemId = 50732,
			itemName = "Bloodsurge, Kel'Thuzad's Blade of Agony",
			itemString = "item:50732:0:0:0:0:0:0:0",
			itemLink = "|cffa335ee|Hitem:50732:0:0:0:0:0:0:0|h[Bloodsurge, Kel'Thuzad's Blade of Agony]|h|r",
			itemRarity = 4,
			itemTexture = "Interface\\Icons\\INV_Sword_150",
			itemCount = 1,
			looterNid = 1,
			rollType = 8,
			rollValue = 100,
			rollSessionId = "GL:4294967295",
			bossNid = lootSource and lootSource.bossNid or 0,
			time = 1721120200,
			source = "CHAT_MSG_LOOT",
			lootSource = lootSource,
		},
	}
end

local function realisticLootSource(kind)
	local source = {
		kind = kind,
		bossNid = kind == "boss" and 12 or 13,
		sourceNpcId = kind == "boss" and 36597 or 0,
		sourceName = kind == "boss" and "The Lich King" or "Shared",
		sourceKey = kind == "boss" and "icecrown-citadel:the-lich-king" or nil,
		openedAt = 1721120190,
		snapshotId = 4294967295,
	}
	if kind == "shared" then
		source.candidates = {
			{ name = "Blood Prince Council", kind = "boss", sourceKey = "icecrown-citadel:blood-prince-council", npcId = 37970 },
			{ name = "Queen Lana'thel", kind = "boss", sourceKey = "icecrown-citadel:blood-queen-lanathel", npcId = 37955 },
		}
	end
	return source
end

function cases.raid_live_loot_broadcast_advances_multiple_replicas()
	local network = newLiveReplicationNetwork()
	local leader, memberB, memberC = installAlignedRealLiveReplicationClients(network)
	for lootNid = 1, 4 do
		commitRealCompactLiveLoot(leader, lootNid)
	end
	local leaderRecord = assert(leader.store:GetActiveRecord())
	for _, member in pairs({ memberB, memberC }) do
		local replica = assert(member.store:GetActiveRecord())
		assertEqual(leaderRecord.sequence, replica.sequence, "compact loot replica sequence differs")
		assertEqual(leaderRecord.digest, replica.digest, "compact loot replica digest differs")
		assertEqual(4, #(replica.state.loot or {}), "compact loot replica count differs")
		assertEqual(0, countMessageKind(member.requests, "RANGE_REQ"), "compact loot opened range recovery")
		assertEqual(0, countMessageKind(member.requests, "SNAP_REQ"), "compact loot opened snapshot recovery")
	end
	assertEqual(4, countMessageKind(leader.requests, "LIVE_LOOT"), "compact loot broadcast count differs")
	assertEqual(0, countMessageKind(leader.requests, "HEAD"), "compact loot sent an immediate HEAD")
	assertTrue(leader:FireTimerByDelay(0.25), "compact loot did not schedule a trailing HEAD")
	assertEqual(1, countMessageKind(leader.requests, "HEAD"), "compact loot trailing HEAD count differs")
	assertEqual(
		leaderRecord.sequence,
		leader.sentEnvelopes[#leader.sentEnvelopes].body.sequence,
		"trailing HEAD position differs"
	)
	print("PASS raid_live_loot_broadcast_advances_multiple_replicas")
end

function cases.raid_live_loot_lost_final_recovers_from_trailing_head()
	local network = newLiveReplicationNetwork()
	local leader, memberB, memberC = installAlignedRealLiveReplicationClients(network)
	for lootNid = 1, 3 do
		commitRealCompactLiveLoot(leader, lootNid)
	end
	network.clients.MemberB = nil
	commitRealCompactLiveLoot(leader, 4)
	network.clients.MemberB = memberB
	local leaderRecord = assert(leader.store:GetActiveRecord())
	assertEqual(
		leaderRecord.sequence - 1,
		assert(memberB.store:GetActiveRecord()).sequence,
		"test setup did not lose final compact loot"
	)
	assertTrue(leader:FireTimerByDelay(0.25), "lost compact loot did not schedule a trailing HEAD")
	assertEqual(1, countMessageKind(memberB.requests, "RANGE_REQ"), "lost compact loot did not request one range")
	assertEqual(1, countMessageKind(leader.transfers, "RANGE_DATA"), "authority did not serve one recovery range")
	local repaired = assert(memberB.store:GetActiveRecord())
	assertEqual(leaderRecord.sequence, repaired.sequence, "lost compact loot did not converge from trailing HEAD")
	assertEqual(leaderRecord.digest, repaired.digest, "lost compact loot digest did not converge from trailing HEAD")
	assertEqual(4, #(repaired.state.loot or {}), "lost compact loot count did not converge from trailing HEAD")
	assertEqual(0, countMessageKind(memberC.requests, "RANGE_REQ"), "aligned replica requested a range")
	assertEqual(0, countMessageKind(memberC.requests, "SNAP_REQ"), "aligned replica requested a snapshot")
	print("PASS raid_live_loot_lost_final_recovers_from_trailing_head")
end

function cases.raid_live_sync_range_recovery()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(3))
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))
	local wire = network:encode("EVENT", "-", "-", { event = makeLiveEvent(3) })
	member.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(3, member.store.record.sequence, "replica did not converge through range recovery")
	assertEqual("RANGE_REQ", member.requests[1], "gap did not request a range")
	assertEqual("RANGE_DATA", leader.transfers[1], "authority did not answer range request")
	print("PASS raid_live_sync_range_recovery")
end

function cases.raid_live_sync_snapshot_bootstrap()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local member = installLiveReplicationClient(network, "Member", nil)
	leader.syncer:AdvertiseHead()
	assertEqual(2, member.store.record.sequence, "late join did not install snapshot")
	assertEqual("SNAP_REQ", member.requests[1], "late join did not request snapshot")
	assertEqual("SNAP_DATA", leader.transfers[1], "authority did not answer snapshot request")
	print("PASS raid_live_sync_snapshot_bootstrap")
end

local function countKind(kinds, expected)
	local count = 0
	for i = 1, #kinds do
		if kinds[i] == expected then
			count = count + 1
		end
	end
	return count
end

function cases.raid_live_sync_snapshot_coalesces_newer_event_burst()
	local network = newLiveReplicationNetwork()
	network.holdTransfers = true
	local leaderRecord = makeLiveRecord(2)
	leaderRecord.checkpointSequence = 2
	local leader = installLiveReplicationClient(network, "Leader", leaderRecord)
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))

	assertTrue(leader.syncer:AdvertiseHead(), "leader did not advertise bootstrap HEAD")
	local heldSnapshot = assert(network.heldTransfers[1], "initial snapshot response was not held")
	assertEqual(1, countKind(member.requests, "SNAP_REQ"), "bootstrap did not start one snapshot")

	for sequence = 3, 8 do
		assertTrue(
			leader.store:Commit(makeLiveEvent(sequence)),
			"leader could not commit burst event " .. tostring(sequence)
		)
	end
	assertEqual(1, countKind(member.requests, "SNAP_REQ"), "newer events replaced the in-flight snapshot")
	assertEqual(0, #member.cancelledRequests, "newer events cancelled the compatible in-flight snapshot")

	network.holdTransfers = false
	assertTrue(
		network:deliver(heldSnapshot.sender, heldSnapshot.prefix, heldSnapshot.wire, "WHISPER", heldSnapshot.target),
		"held snapshot was not accepted"
	)
	assertEqual(1, countKind(member.requests, "RANGE_REQ"), "snapshot completion did not request one catch-up range")
	assertEqual(
		leader.store.record.sequence,
		member.store.record.sequence,
		"member sequence did not converge after the burst"
	)
	assertEqual(
		leader.store.record.digest,
		member.store.record.digest,
		"member digest did not converge after the burst"
	)
	local status, reason = member.syncer:GetStatus()
	assertEqual("synchronized", status, "member did not finish synchronized")
	assertEqual("UP_TO_DATE", reason, "member retained a recovery failure")
	print("PASS raid_live_sync_snapshot_coalesces_newer_event_burst")
end

function cases.raid_live_sync_snapshot_coalesces_newer_snapshot_burst()
	local network = newLiveReplicationNetwork()
	network.holdTransfers = true
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local member = installLiveReplicationClient(network, "Member", nil)

	assertTrue(leader.syncer:AdvertiseHead(), "leader did not advertise bootstrap HEAD")
	local heldSnapshot = assert(network.heldTransfers[1], "initial snapshot response was not held")
	assertEqual(1, countKind(member.requests, "SNAP_REQ"), "bootstrap did not start one snapshot")

	for sequence = 3, 8 do
		assertTrue(
			leader.store:Commit(makeLiveEvent(sequence)),
			"leader could not commit burst event " .. tostring(sequence)
		)
	end
	assertEqual(1, countKind(member.requests, "SNAP_REQ"), "newer snapshots replaced the in-flight snapshot")
	assertEqual(0, #member.cancelledRequests, "newer snapshots cancelled the compatible in-flight snapshot")

	network.holdTransfers = false
	assertTrue(
		network:deliver(heldSnapshot.sender, heldSnapshot.prefix, heldSnapshot.wire, "WHISPER", heldSnapshot.target),
		"held snapshot was not accepted"
	)
	assertEqual(0, countKind(member.requests, "RANGE_REQ"), "checkpointed follow-up bypassed snapshot recovery")
	assertEqual(2, countKind(member.requests, "SNAP_REQ"), "snapshot completion did not request one catch-up snapshot")
	assertEqual(
		leader.store.record.sequence,
		member.store.record.sequence,
		"member sequence did not converge after the burst"
	)
	assertEqual(
		leader.store.record.digest,
		member.store.record.digest,
		"member digest did not converge after the burst"
	)
	local status, reason = member.syncer:GetStatus()
	assertEqual("synchronized", status, "member did not finish synchronized")
	assertEqual("UP_TO_DATE", reason, "member retained a recovery failure")
	print("PASS raid_live_sync_snapshot_coalesces_newer_snapshot_burst")
end

function cases.raid_live_sync_snapshot_follow_up_digest_conflict()
	local network = newLiveReplicationNetwork()
	network.holdTransfers = true
	local leaderRecord = makeLiveRecord(2)
	leaderRecord.checkpointSequence = 2
	local leader = installLiveReplicationClient(network, "Leader", leaderRecord)
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))

	assertTrue(leader.syncer:AdvertiseHead(), "leader did not advertise bootstrap HEAD")
	local heldSnapshot = assert(network.heldTransfers[1], "initial snapshot response was not held")
	assertTrue(leader.store:Commit(makeLiveEvent(3)), "leader could not commit retained follow-up")
	assertEqual(1, countKind(member.requests, "SNAP_REQ"), "follow-up replaced the held snapshot")
	assertEqual(0, countKind(member.requests, "RANGE_REQ"), "follow-up started range recovery before snapshot")

	local conflicting = makeLiveEvent(3)
	conflicting.resultDigest = "ffffffff:1"
	local wire = network:encode("EVENT", "-", "-", { event = conflicting })
	local accepted, conflictReason = member.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(false, accepted, "conflicting retained position was accepted")
	assertEqual("DIGEST_CONFLICT", conflictReason, "conflicting retained position reason differs")
	assertEqual(1, #member.cancelledRequests, "digest conflict did not cancel the held snapshot")
	assertEqual("DIGEST_CONFLICT", member.cancelledRequests[1].reason, "snapshot cancellation reason differs")
	local status, reason = member.syncer:GetStatus()
	assertEqual("suspended", status, "retained digest conflict did not suspend replication")
	assertEqual("DIGEST_CONFLICT", reason, "retained digest conflict status reason differs")

	network.holdTransfers = false
	local beforeLate = deepCopy(member.store.record)
	network:deliver(heldSnapshot.sender, heldSnapshot.prefix, heldSnapshot.wire, "WHISPER", heldSnapshot.target)
	assertTrue(deepEqual(beforeLate, member.store.record), "late cancelled snapshot installed state")
	print("PASS raid_live_sync_snapshot_follow_up_digest_conflict")
end

function cases.raid_live_sync_late_join_discovers_existing_active_raid()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local member = installLiveReplicationClient(network, "Member", nil)

	local recognized = assert(member.callbacks.RaidInstanceRecognized, "recognized-instance callback missing")
	recognized[1](nil, "Naxxramas", "naxxramas")

	assertEqual("HEAD_REQ", member.requests[1], "late member did not request the active HEAD")
	assertEqual("HEAD", leader.requests[1], "leader did not advertise its active HEAD")
	assertEqual("SNAP_REQ", member.requests[2], "late member did not request the snapshot")
	assertEqual("SNAP_DATA", leader.requests[2], "leader did not transfer the snapshot")
	assertEqual(leader.store.record.raidUid, member.store.record.raidUid, "replica UID differs")
	assertEqual(leader.store.record.sequence, member.store.record.sequence, "replica sequence differs")
	assertEqual(leader.store.record.digest, member.store.record.digest, "replica digest differs")
	assertEqual(nil, member.store.committed[1], "non-leader committed an authoritative event")

	local isolatedNetwork = newLiveReplicationNetwork()
	isolatedNetwork.raidLeader = "AbsentLeader"
	local isolated = installLiveReplicationClient(isolatedNetwork, "Member", nil)
	local isolatedRecognized = assert(isolated.callbacks.RaidInstanceRecognized)
	isolatedRecognized[1](nil, "Naxxramas", "naxxramas")
	isolatedRecognized[1](nil, "Naxxramas", "naxxramas")
	assertEqual(1, countKind(isolated.requests, "HEAD_REQ"), "duplicate signals did not coalesce")
	local retry = assert(isolated.timers[#isolated.timers], "discovery retry missing")
	assertEqual(3, retry.delay, "discovery retry delay differs")
	retry.callback()
	assertEqual(2, countKind(isolated.requests, "HEAD_REQ"), "bounded retry count differs")
	retry.callback()
	assertEqual(2, countKind(isolated.requests, "HEAD_REQ"), "stale retry sent again")
	assertEqual(nil, isolated.store.record, "non-leader created without an addon-enabled authority")

	print("PASS raid_live_sync_late_join_discovers_existing_active_raid")
end

function cases.raid_leader_reentry_recovers_highest_replica_before_write()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	leader.currentRaid = nil
	local replicaB = installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5))
	installLiveReplicationClient(network, "ReplicaC", makeLiveRecord(4))
	local recognized = assert(leader.callbacks.RaidInstanceRecognized)
	recognized[1](nil, "Naxxramas", "naxxramas", 1)
	assertEqual(nil, leader.store:Commit(makeLiveEvent(3)), "Leader wrote during recovery")
	assertEqual("AUTHORITY_RECOVERING", select(2, leader.store:CommitAuthoritativeEvent("raid-live", "TEST", {})))
	assert(leader:FireHandoverTimer())
	assertEqual(5, leader.store.record.sequence, "Leader did not recover the highest sequence")
	assertEqual(replicaB.store.record.digest, leader.store.record.digest, "Leader recovered the wrong digest")
	assertEqual(1, #leader.reentryReady, "recovery did not publish one ready decision")
	assertTrue(leader.syncer:IsAuthorityRecovering("raid-live"), "write barrier opened before decision")
	print("PASS raid_leader_reentry_recovers_highest_replica_before_write")
end

function cases.raid_leader_reentry_repairs_corrupt_equal_position()
	local network = newLiveReplicationNetwork()
	local localRecord = makeLiveRecord(5)
	localRecord.state.computedDigest = "corrupt-local-state"
	localRecord.state.loot = {}
	local leader = installLiveReplicationClient(network, "Leader", localRecord)
	leader.currentRaid = nil
	local remoteRecord = makeLiveRecord(5)
	remoteRecord.state.computedDigest = remoteRecord.digest
	remoteRecord.state.loot = { { lootNid = 1, itemLink = "item:19019" } }
	installLiveReplicationClient(network, "ReplicaB", remoteRecord)
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assertEqual(
		1,
		countKind(leader.requests, "SNAP_REQ"),
		"corrupt equal-position local state skipped replica snapshot repair"
	)
	assertEqual(
		1,
		#(leader.store.record.state.loot or {}),
		"replica snapshot did not restore the missing Loot History row status="
			.. tostring(leader.syncer:GetStatus())
			.. " target="
			.. tostring(leader.lastBeginRequestTarget)
			.. " computed="
			.. tostring(leader.store.record.state.computedDigest)
	)
	print("PASS raid_leader_reentry_repairs_corrupt_equal_position")
end

function cases.raid_leader_reentry_authority_change_cancels_pending_snapshot()
	local network = newLiveReplicationNetwork()
	network.holdTransfers = true
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	leader.currentRaid = nil
	installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assertEqual("snapshot", leader.syncer._reentry.phase, "reentry did not request its snapshot")
	local held = assert(network.heldTransfers[1], "snapshot response was not held")
	network.raidLeader = "ReplicaB"
	fireLiveReplicationCallback(leader, "RaidRosterDelta")
	assertEqual(nil, leader.syncer._reentry, "authority change retained stale reentry state")
	assertEqual(nil, leader.syncer._recovery, "authority change retained stale snapshot request")
	network:deliver(held.sender, held.prefix, held.wire, "WHISPER", held.target)
	assertEqual(2, leader.store.record.sequence, "late snapshot repaired after authority loss")
	assertEqual(0, #leader.reentryReady, "late snapshot published a ready decision")
	assertEqual(false, leader.syncer:IsAuthorityRecovering("raid-live"), "cancelled reentry retained the write barrier")
	print("PASS raid_leader_reentry_authority_change_cancels_pending_snapshot")
end

function cases.raid_leader_reentry_suspends_on_tied_digest_conflict()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	leader.currentRaid = nil
	installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5, "aaaaaaaa:1"))
	installLiveReplicationClient(network, "ReplicaC", makeLiveRecord(5, "bbbbbbbb:1"))
	assert(leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1) == nil)
	assert(leader:FireHandoverTimer())
	local status, reason = leader.syncer:GetStatus()
	assertEqual("suspended", status)
	assertEqual("DIGEST_CONFLICT", reason)
	assertEqual(2, leader.store.record.sequence, "conflict overwrote local state")
	assertEqual(1, #leader.warnings, "conflict WARN count differs")
	assertEqual(0, #leader.reentryReady, "conflict opened the decision flow")
	print("PASS raid_leader_reentry_suspends_on_tied_digest_conflict")
end

function cases.raid_leader_reentry_unknown_uid_requires_consensus()
	local unanimousNetwork = newLiveReplicationNetwork()
	local unknownRecord = makeLiveRecord(0)
	unknownRecord.raidUid = nil
	local leader = installLiveReplicationClient(unanimousNetwork, "Leader", unknownRecord)
	leader.currentRaid = nil
	installLiveReplicationClient(unanimousNetwork, "ReplicaB", makeLiveRecord(3))
	installLiveReplicationClient(unanimousNetwork, "ReplicaC", makeLiveRecord(5))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assertEqual("raid-live", leader.store.record.raidUid, "unanimous UID was not recovered")
	assertEqual(5, leader.store.record.sequence, "unanimous recovery did not select the highest sequence")

	local splitNetwork = newLiveReplicationNetwork()
	local splitUnknownRecord = makeLiveRecord(0)
	splitUnknownRecord.raidUid = nil
	local splitLeader = installLiveReplicationClient(splitNetwork, "Leader", splitUnknownRecord)
	splitLeader.currentRaid = nil
	local left = makeLiveRecord(3)
	local right = makeLiveRecord(4)
	right.raidUid = "raid-other"
	installLiveReplicationClient(splitNetwork, "ReplicaB", left)
	installLiveReplicationClient(splitNetwork, "ReplicaC", right)
	splitLeader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(splitLeader:FireHandoverTimer())
	assertEqual("suspended", splitLeader.syncer:GetStatus())
	assertEqual(nil, splitLeader.store.record.raidUid, "discordant replicas selected an arbitrary UID")
	print("PASS raid_leader_reentry_unknown_uid_requires_consensus")
end

function cases.raid_leader_reentry_retry_is_bounded()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(1))
	leader.currentRaid = nil
	local recognized = assert(leader.callbacks.RaidInstanceRecognized)
	recognized[1](nil, "Naxxramas", "naxxramas", 1)
	recognized[1](nil, "Naxxramas", "naxxramas", 1)
	assertEqual(1, countKind(leader.requests, "HEAD_REQ"), "duplicate recognition sent twice")
	assert(leader:FireHandoverTimer())
	assertEqual(2, countKind(leader.requests, "HEAD_REQ"), "missing reply did not use exactly one retry")
	assert(leader:FireHandoverTimer())
	assertEqual(2, countKind(leader.requests, "HEAD_REQ"), "recovery exceeded its request bound")
	assertEqual(1, #leader.reentryReady, "empty recovery did not reach one terminal decision")
	assertEqual("raid-live", leader.store.record.raidUid, "retry lost the archived raid identity")
	print("PASS raid_leader_reentry_retry_is_bounded")
end

local function installReentryDecisionBridge(client)
	client.currentRaidUid = nil
	client.createdRaids = 0
	client.concludedRaids = 0
	client.resumedRaids = 0
	client.decisionRequests = {}
	client.completedRecords = {}
	local getRecord = client.store.GetRecord
	client.store.GetRecord = function(store, raidUid)
		return getRecord(store, raidUid) or client.completedRecords[raidUid]
	end
	client.addon.Services.Raid.NotifyDeferredRaidCreate = function()
		local record = assert(client.store.record, "deferred attendance requires the created raid")
		local event = {
			raidUid = record.raidUid,
			authorityEpoch = record.authorityEpoch,
			sequence = record.sequence + 1,
			eventUid = record.raidUid .. ":attendance",
			eventType = "ATTENDANCE_UPDATED",
			payload = { attendance = { playerNid = 1, segments = { { startTime = 101 } } } },
			resultDigest = "attendance:1",
		}
		record.sequence = event.sequence
		record.digest = event.resultDigest
		record.events[#record.events + 1] = deepCopy(event)
		client.addon.Bus.TriggerEvent(client.addon.Events.Internal.RaidReplicationCommitted, event)
		return true
	end
	client.addon.Services.Raid.ApplyReentryDecision = function(_, raidUid, decision, context)
		if decision == "resume" then
			client.resumedRaids = client.resumedRaids + 1
			client.currentRaidUid = raidUid
			return true, raidUid
		end
		if decision == "replace" then
			client.concludedRaids = client.concludedRaids + 1
			local previous = assert(client.store.record, "replacement requires the recovered active raid")
			local concluded = {
				raidUid = previous.raidUid,
				authorityEpoch = previous.authorityEpoch,
				sequence = previous.sequence + 1,
				eventUid = previous.raidUid .. ":concluded",
				eventType = "RAID_CONCLUDED",
				payload = { endTime = 101 },
				resultDigest = "concluded:1",
			}
			previous.sequence = concluded.sequence
			previous.digest = concluded.resultDigest
			previous.status = "complete"
			previous.events = {}
			client.completedRecords[previous.raidUid] = deepCopy(previous)
			client.addon.Bus.TriggerEvent(client.addon.Events.Internal.RaidReplicationCommitted, concluded)
			if client.failReplacement then
				return false, "CREATE_ROLLED_BACK"
			end
			client.createdRaids = client.createdRaids + 1
			client.store.record = makeLiveRecord(1)
			client.store.record.raidUid = "raid-replacement-" .. tostring(client.createdRaids)
			client.store.record.events[1].raidUid = client.store.record.raidUid
			client.store.record.events[1].eventUid = client.store.record.raidUid .. ":1:1"
			client.store.record.events[1].eventType = "RAID_CREATED"
			client.addon.Bus.TriggerEvent(
				client.addon.Events.Internal.RaidReplicationCommitted,
				deepCopy(client.store.record.events[1])
			)
			client.currentRaidUid = client.store.record.raidUid
			return true, client.currentRaidUid
		end
		if decision == "new" and raidUid == nil then
			client.createdRaids = client.createdRaids + 1
			client.store.record = makeLiveRecord(1)
			client.store.record.raidUid = "raid-new-" .. tostring(client.createdRaids)
			client.store.record.events[1].raidUid = client.store.record.raidUid
			client.store.record.events[1].eventUid = client.store.record.raidUid .. ":1:1"
			client.store.record.events[1].eventType = "RAID_CREATED"
			client.addon.Bus.TriggerEvent(
				client.addon.Events.Internal.RaidReplicationCommitted,
				deepCopy(client.store.record.events[1])
			)
			client.currentRaidUid = client.store.record.raidUid
			return true, client.currentRaidUid
		end
		return false, "INVALID_REENTRY_DECISION"
	end
	client.addon.Bus.RegisterCallback(client.addon.Events.Internal.RaidReentryRecoveryReady, function(_, summary)
		local raid, context = summary.raid, summary.context
		if
			raid
			and raid.zone == context.zone
			and tonumber(raid.size) == tonumber(context.size)
			and tonumber(raid.difficulty) == tonumber(context.difficulty)
		then
			client.decisionRequests[#client.decisionRequests + 1] = deepCopy(summary)
			client.addon.Bus.TriggerEvent(client.addon.Events.Internal.RaidReentryDecisionRequired, summary)
		else
			client.addon.Bus.TriggerEvent(
				client.addon.Events.Internal.RaidReentryDecisionResolved,
				summary.raidUid,
				raid and "replace" or "new",
				context
			)
		end
	end)
end

local function resolveReentry(client, decision)
	local summary = assert(client.decisionRequests[#client.decisionRequests], "re-entry decision missing")
	client.addon.Bus.TriggerEvent(
		client.addon.Events.Internal.RaidReentryDecisionResolved,
		summary.raidUid,
		decision,
		summary.context
	)
end

installProductionReentryRuntime = function(client)
	local addon = client.addon
	local function getProductionInstanceInfo()
		if client.productionInstanceReady ~= true then
			return nil, "none", 0, nil, nil, nil, nil, nil
		end
		return "Naxxramas", "raid", 1, nil, nil, nil, nil, 533
	end
	addon.State.raid = {}
	addon.C = {}
	addon.Events.Internal.RaidAttendanceChanged = "RaidAttendanceChanged"
	addon.L.RaidZones = { Naxxramas = true }
	addon.L.StrNewRaidSessionChange = "New raid session"
	addon.Diag.I = {
		LogRaidCreated = "%d %s %d %d",
		LogRaidEnded = "%d %s %d %d %d %d",
	}
	addon.Diag.D.LogRaidCheck = "%s %s %s"
	addon.Diag.D.LogRaidSessionCreate = "%s %s %s"
	addon.Diag.D.LogRaidSessionChange = "%s %s %s"
	addon.Strings.TrimText = function(value)
		return value
	end
	addon.Strings.NormalizeName = function(value)
		if type(value) ~= "string" then
			return value
		end
		return string.lower(string.match(value, "^([^%-]+)") or value)
	end
	addon.Time = {
		GetCurrentTime = function()
			return 100
		end,
	}
	addon.Base64 = {
		Encode = function(value)
			return tostring(value)
		end,
	}
	addon.LootSources = {}
	addon.LootSourceCandidates = {}
	addon.Options.IsDebugEnabled = function()
		return false
	end
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
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
	addon.GetGroupTypeAndCount = function()
		return "raid", 2
	end
	addon.GetNumGroupMembers = function()
		return 2
	end
	addon.GetCreatureId = function()
		return nil
	end
	addon.tLength = function()
		return 0
	end
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
	_G.UnitInRaid = function()
		return 1
	end
	_G.UnitIsGroupLeader = nil
	_G.IsRaidLeader = function()
		return client.productionLeaderRoleSettled
	end
	_G.UnitRace = function()
		return "Human", "Human"
	end
	_G.UnitSex = function()
		return 2
	end
	local function getProductionUnitName(unit)
		if unit == "player" or unit == "raid1" then
			return client.name
		end
		if unit == "raid2" then
			return "ReplicaB"
		end
		return nil
	end
	_G.UnitName = getProductionUnitName
	client.RestoreProductionUnitApi = function()
		_G.UnitName = getProductionUnitName
	end
	_G.UnitFullName = function()
		return client.name, "Test Realm"
	end
	_G.GetInstanceInfo = getProductionInstanceInfo
	_G.GetNumRaidMembers = function()
		return 2
	end
	_G.GetNumPartyMembers = function()
		return 0
	end
	_G.GetRaidRosterInfo = function(index)
		if index == 1 then
			return client.name,
				client.productionLeaderIdentitySettled and 2 or 0,
				1,
				80,
				"Warrior",
				"WARRIOR",
				nil,
				true
		end
		if index == 2 then
			return "ReplicaB", 0, 1, 80, "Mage", "MAGE", nil, true
		end
		return nil
	end
	_G.SetRaidTarget = function() end
	_G.GetLootMethod = function()
		return "group"
	end
	_G.UnitIsUnit = function(left, right)
		return left == right
	end
	_G.UNKNOWNOBJECT = "Unknown"
	_G.UNKNOWNBEING = "Unknown Being"
	loadAddonFile(addon, "Raid Management Addon/Modules/Group.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/State.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Roster.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Session.lua")

	local function newDatasetOwner()
		local activeKey
		return {
			ResolveInstanceKey = function()
				return "naxxramas"
			end,
			GetActiveInstanceKey = function()
				return activeKey
			end,
			CaptureActivationState = function()
				return { activeKey = activeKey }
			end,
			RestoreActivationState = function(snapshot)
				activeKey = snapshot and snapshot.activeKey
				return true
			end,
			ActivateInstance = function(key)
				activeKey = key
				return true
			end,
			DeactivateInstance = function()
				activeKey = nil
				return true
			end,
		}
	end
	addon.LootSourcesData = newDatasetOwner()
	local ignoredDataset = newDatasetOwner()
	for key, value in pairs(ignoredDataset) do
		addon.IgnoredMobs[key] = value
	end
	installInitStubs(addon)
	client:RestoreProductionUnitApi()
	_G.GetNumRaidMembers = function()
		return 2
	end
	_G.GetRaidRosterInfo = function(index)
		if index == 1 then
			return client.name,
				client.productionLeaderIdentitySettled and 2 or 0,
				1,
				80,
				"Warrior",
				"WARRIOR",
				nil,
				true
		end
		if index == 2 then
			return "ReplicaB", 0, 1, 80, "Mage", "MAGE", nil, true
		end
		return nil
	end
	_G.GetInstanceInfo = getProductionInstanceInfo
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	addon.UnitIterator = function()
		local index = 0
		return function()
			index = index + 1
			if index <= 2 then
				return "raid" .. tostring(index)
			end
			return nil
		end
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Raid/Capabilities.lua")
	client.productionRuntimeInstalled = true
	return addon.Services.Raid
end

local function installReentryEntryWiring(client)
	assert(client.productionRuntimeInstalled, "production re-entry runtime is not installed")
	client.emittedEvents = {}
	client.popupShows = {}
	client.popupDialogs = {}
	local addon = client.addon
	addon.L.PopupRaidReentryConfirm = "Resume the previous raid?\nZone: %s\nSize: %d\nDifficulty: %s"
	addon.Services.Raid.Projections = {
		GetDifficultyLabel = function()
			return "10N"
		end,
	}
	addon.UI = {
		Popups = {
			Define = function(key, dialog)
				client.popupDialogs[key] = dialog
				return true
			end,
			IsDefined = function(key)
				return client.popupDialogs[key] ~= nil
			end,
			Show = function(key, text, _, data)
				client.popupShows[#client.popupShows + 1] = { key = key, text = text, data = data }
				return true
			end,
		},
	}
	_G.YES, _G.NO = "Yes", "No"
	-- Logger's production popup wiring is covered by raid_reentry_popup_routes_explicit_decisions.
	-- This live-replication fixture keeps only the decision boundary so it can isolate the sync runtime.
	local popupKey = "RMA_RAID_REENTRY_CONFIRM"
	addon.UI.Popups.Define(popupKey, {
		OnAccept = function(_, data)
			addon.Bus.TriggerEvent(addon.Events.Internal.RaidReentryDecisionResolved, data.raidUid, "resume", data.context)
		end,
		OnCancel = function(_, data)
			addon.Bus.TriggerEvent(addon.Events.Internal.RaidReentryDecisionResolved, data.raidUid, "replace", data.context)
		end,
	})
	addon.Bus.RegisterCallback(addon.Events.Internal.RaidReentryDecisionRequired, function(_, summary)
		addon.UI.Popups.Show(popupKey, nil, nil, summary)
	end)
	local observedEvents = {
		addon.Events.Internal.RaidReentryRecoveryReady,
		addon.Events.Internal.RaidReentryDecisionRequired,
		addon.Events.Internal.RaidReentryDecisionResolved,
		addon.Events.Internal.RaidReplicationCommitted,
	}
	for i = 1, #observedEvents do
		local observed = observedEvents[i]
		addon.Bus.RegisterCallback(observed, function(eventName, firstArg)
			client.emittedEvents[#client.emittedEvents + 1] = {
				name = eventName,
				eventType = type(firstArg) == "table" and firstArg.eventType or nil,
			}
		end)
	end
end

local function assertProductionRaidAuthority(client)
	client:RestoreProductionUnitApi()
	local raid = client.addon.Services.Raid
	assertEqual(client.name, raid:GetRaidLeaderName(), "production raid leader identity differs")
	assertEqual(true, raid:IsRaidLeader(), "production raid leader capability differs")
	assertEqual(true, raid:IsGroupMember("ReplicaB-Test Realm"), "production raid membership differs")
end

local function countEmittedEvent(client, eventName, eventType)
	local count = 0
	for i = 1, #(client.emittedEvents or {}) do
		local emitted = client.emittedEvents[i]
		if emitted.name == eventName and (eventType == nil or emitted.eventType == eventType) then
			count = count + 1
		end
	end
	return count
end

local function firstEmittedEventIndex(client, eventName, eventType)
	for i = 1, #(client.emittedEvents or {}) do
		local emitted = client.emittedEvents[i]
		if emitted.name == eventName and emitted.eventType == eventType then
			return i
		end
	end
	return nil
end

local function enterRaidThroughInit(client)
	client.addon:ZONE_CHANGED_NEW_AREA()
end

local function resolveShownReentry(client, accept)
	local shown = assert(client.popupShows[#client.popupShows], "re-entry popup missing")
	local dialog = assert(client.popupDialogs[shown.key], "re-entry popup definition missing")
	if accept then
		dialog.OnAccept(nil, shown.data)
	else
		dialog.OnCancel(nil, shown.data, "clicked")
	end
end

function cases.raid_reentry_entry_wiring_emits_one_popup()
	local freshNetwork = newLiveReplicationNetwork()
	local fresh =
		installLiveReplicationClient(freshNetwork, "Leader", nil, { realStore = true, productionCapabilities = true })
	installReentryEntryWiring(fresh)
	assertProductionRaidAuthority(fresh)
	enterRaidThroughInit(fresh)
	local freshRecord = assert(fresh.store:GetActiveRecord(), "fresh entry did not create a real active raid")
	assertEqual(
		fresh.store:GetIndexByUid(fresh.store:GetRaidUid(freshRecord.state)),
		fresh.addon.Database.GetCurrentRaid(),
		"fresh entry did not select the real created raid"
	)
	assertEqual(
		1,
		countEmittedEvent(fresh, fresh.addon.Events.Internal.RaidReplicationCommitted, "RAID_CREATED"),
		"fresh entry did not create exactly one raid"
	)
	assertEqual(0, #fresh.popupShows, "fresh entry displayed the reuse popup without a replica")

	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(
		network,
		"Leader",
		nil,
		{ realStore = true, seedActiveRaid = true, productionCapabilities = true }
	)
	installReentryEntryWiring(leader)
	installLiveReplicationClient(network, "ReplicaB", leader.seedRecord)
	assertProductionRaidAuthority(leader)

	enterRaidThroughInit(leader)
	assertEqual(
		nil,
		leader.addon.Database.GetCurrentRaid(),
		"active re-entry selected the archived raid before the decision"
	)
	assertEqual(
		leader.seedRaidUid,
		leader.store:GetRaidUid(leader.store:GetActiveRecord().state),
		"active re-entry created a competing raid"
	)
	assert(leader:FireHandoverTimer())
	assertEqual(1, #leader.popupShows, "recognized entry did not show exactly one reuse popup")
	assertEqual(
		1,
		countEmittedEvent(leader, leader.addon.Events.Internal.RaidReentryRecoveryReady),
		"recognized entry emitted recovery-ready more than once"
	)
	assertEqual(
		1,
		countEmittedEvent(leader, leader.addon.Events.Internal.RaidReentryDecisionRequired),
		"recognized entry emitted decision-required more than once"
	)
	enterRaidThroughInit(leader)
	assertEqual(1, #leader.popupShows, "duplicate recognition showed another reuse popup")
	print("PASS raid_reentry_entry_wiring_emits_one_popup")
end

function cases.raid_reentry_starts_when_instance_context_settles_after_login()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", nil, {
		realStore = true,
		seedActiveRaid = true,
		productionCapabilities = true,
		productionInstanceReady = false,
	})
	installReentryEntryWiring(leader)
	installLiveReplicationClient(network, "ReplicaB", leader.seedRecord)
	leader:RestoreProductionUnitApi()

	leader.addon:PLAYER_ENTERING_WORLD()
	assertEqual(nil, leader.syncer._reentry, "unavailable login context started re-entry recovery")
	assertEqual(nil, leader.addon.Database.GetCurrentRaid(), "unavailable login context selected a current raid")
	local initialCheckHandle =
		assert(leader.addon.Services.Raid.CheckInitialRaidStateHandle, "delayed initial raid check timer missing")
	local initialCheck = assert(leader.timers[initialCheckHandle], "delayed initial raid check callback missing")

	leader.productionInstanceReady = true
	initialCheck.callback()
	assertTrue(leader.syncer._reentry ~= nil, "settled delayed instance context did not start re-entry recovery")
	assertEqual(nil, leader.addon.Database.GetCurrentRaid(), "delayed recognition bypassed re-entry recovery")
	assertEqual(
		0,
		countEmittedEvent(leader, leader.addon.Events.Internal.RaidReplicationCommitted, "RAID_CREATED"),
		"delayed recognition created a competing raid"
	)

	local completionHandle = assert(leader.syncer._reentry.timer, "delayed re-entry completion timer missing")
	assert(leader.timers[completionHandle]).callback()
	assertEqual(1, #leader.popupShows, "delayed instance recognition did not show exactly one re-entry popup")

	print("PASS raid_reentry_starts_when_instance_context_settles_after_login")
end

function cases.raid_reentry_retries_once_after_leader_roster_settlement()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", nil, {
		realStore = true,
		seedActiveRaid = true,
		productionCapabilities = true,
		productionLeaderRoleSettled = false,
		productionLeaderIdentitySettled = false,
	})
	installReentryEntryWiring(leader)
	installLiveReplicationClient(network, "ReplicaB", leader.seedRecord)

	leader.addon:PLAYER_ENTERING_WORLD()
	assertEqual(nil, leader.addon.Database.GetCurrentRaid(), "unsettled entry selected the archived raid")
	assertEqual(nil, leader.syncer._reentry, "unsettled entry started recovery before raid leadership resolved")
	assertTrue(leader.syncer._discovery ~= nil, "unsettled leader discovery did not retain the recognized context")
	local discoveryTimerHandle =
		assert(leader.syncer._discovery.timer, "unsettled leader discovery timer handle missing")
	local discoveryTimer = assert(leader.timers[discoveryTimerHandle], "unsettled leader discovery timer missing")
	assertEqual(3, discoveryTimer.delay, "unsettled leader retry delay differs")
	local initialCheckHandle = assert(
		leader.addon.Services.Raid.CheckInitialRaidStateHandle,
		"PLAYER_ENTERING_WORLD initial check timer missing"
	)
	assertTrue(
		initialCheckHandle ~= discoveryTimerHandle,
		"discovery and initial raid check unexpectedly share a timer"
	)
	assertEqual(3, leader.timers[initialCheckHandle].delay, "initial raid check delay differs")

	leader.productionLeaderRoleSettled = true
	leader.productionLeaderIdentitySettled = true
	discoveryTimer.callback()
	assertTrue(leader.syncer._reentry ~= nil, "settled raid leader did not start re-entry recovery")
	leader.timers[initialCheckHandle].callback()
	assertEqual(nil, leader.addon.Database.GetCurrentRaid(), "concurrent initial raid check bypassed re-entry recovery")
	local function fireReentryCompletion()
		local completionTimerHandle = assert(leader.syncer._reentry.timer, "re-entry completion timer handle missing")
		local completionTimer = assert(leader.timers[completionTimerHandle], "re-entry completion timer missing")
		assertEqual(3, completionTimer.delay, "re-entry completion delay differs")
		completionTimer.callback()
	end
	fireReentryCompletion()
	if leader.syncer._reentry and leader.syncer._reentry.phase == "collecting" then
		fireReentryCompletion()
	end
	assertEqual(1, #leader.popupShows, "settled raid leader did not receive exactly one re-entry popup")
	assertEqual(
		1,
		countEmittedEvent(leader, leader.addon.Events.Internal.RaidReentryDecisionRequired),
		"settled raid leader emitted more than one re-entry decision"
	)

	print("PASS raid_reentry_retries_once_after_leader_roster_settlement")
end

function cases.raid_reentry_waits_for_leader_identity_after_role_settlement()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", nil, {
		realStore = true,
		seedActiveRaid = true,
		productionCapabilities = true,
		productionLeaderRoleSettled = false,
		productionLeaderIdentitySettled = false,
	})
	installReentryEntryWiring(leader)

	leader.addon:PLAYER_ENTERING_WORLD()
	local discoveryTimerHandle =
		assert(leader.syncer._discovery.timer, "partial settlement discovery timer handle missing")
	local discoveryTimer = assert(leader.timers[discoveryTimerHandle], "partial settlement discovery timer missing")
	leader.productionLeaderRoleSettled = true
	leader.addon:ZONE_CHANGED_NEW_AREA()
	assertEqual(
		nil,
		leader.syncer._reentry,
		"leader role without matching identity started immediate re-entry recovery"
	)
	assertTrue(leader.syncer._discovery ~= nil, "partial settlement cancelled the bounded discovery retry")
	assertEqual(
		discoveryTimerHandle,
		leader.syncer._discovery.timer,
		"partial settlement replaced the bounded discovery retry"
	)
	assertEqual(0, #leader.popupShows, "partial settlement displayed a re-entry popup before retry")
	discoveryTimer.callback()

	assertEqual(
		true,
		leader.addon.Services.Raid:IsRaidLeader(),
		"partial settlement did not expose the local leader role"
	)
	assertEqual(
		nil,
		leader.addon.Services.Raid:GetRaidLeaderName(),
		"partial settlement unexpectedly exposed the leader identity"
	)
	assertEqual(nil, leader.syncer._reentry, "leader role without matching identity started re-entry recovery")
	assertEqual(nil, leader.syncer._discovery, "partial settlement retained the bounded discovery retry")
	assertEqual(0, #leader.popupShows, "partial settlement displayed a re-entry popup")

	print("PASS raid_reentry_waits_for_leader_identity_after_role_settlement")
end

function cases.raid_reentry_yes_resumes_once()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(
		network,
		"Leader",
		nil,
		{ realStore = true, seedActiveRaid = true, productionCapabilities = true }
	)
	installReentryEntryWiring(leader)
	installLiveReplicationClient(network, "ReplicaB", leader.seedRecord)
	assertProductionRaidAuthority(leader)

	enterRaidThroughInit(leader)
	assert(leader:FireHandoverTimer())
	local record = assert(leader.store:GetRecord(leader.seedRaidUid))
	local sequence, digest = record.sequence, record.digest
	resolveShownReentry(leader, true)
	resolveShownReentry(leader, true)
	assertEqual(leader.seedRaidIndex, leader.addon.Database.GetCurrentRaid(), "Yes did not resume the recovered raid")
	assertEqual(sequence, record.sequence, "Yes created a recovered-raid revision")
	assertEqual(digest, record.digest, "Yes changed the recovered digest")
	assertEqual(
		0,
		countEmittedEvent(leader, leader.addon.Events.Internal.RaidReplicationCommitted, "RAID_CREATED"),
		"Yes created a new raid"
	)
	assertEqual(nil, leader.syncer._reentry, "Yes retained the chosen recovery state")
	print("PASS raid_reentry_yes_resumes_once")
end

function cases.raid_reentry_no_replaces_once_without_digest_conflict()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(
		network,
		"Leader",
		nil,
		{ realStore = true, seedActiveRaid = true, productionCapabilities = true }
	)
	installReentryEntryWiring(leader)
	installLiveReplicationClient(network, "ReplicaB", leader.seedRecord)
	assertProductionRaidAuthority(leader)

	enterRaidThroughInit(leader)
	assert(leader:FireHandoverTimer())
	resolveShownReentry(leader, false)
	resolveShownReentry(leader, false)
	local previous = assert(leader.store:GetRecord(leader.seedRaidUid))
	local replacement = assert(leader.store:GetActiveRecord())
	local replacementUid = assert(leader.store:GetRaidUid(replacement.state))
	assertEqual("complete", previous.status, "No did not conclude the recovered raid")
	assertTrue(replacementUid ~= leader.seedRaidUid, "No did not create a replacement raid")
	assertEqual(
		leader.store:GetIndexByUid(replacementUid),
		leader.addon.Database.GetCurrentRaid(),
		"No did not select the replacement"
	)
	assertEqual(
		1,
		countEmittedEvent(leader, leader.addon.Events.Internal.RaidReplicationCommitted, "RAID_CONCLUDED"),
		"No emitted the conclusion lifecycle event more than once"
	)
	assertEqual(
		1,
		countEmittedEvent(leader, leader.addon.Events.Internal.RaidReplicationCommitted, "RAID_CREATED"),
		"No emitted the creation lifecycle event more than once"
	)
	local conclusionIndex =
		assert(firstEmittedEventIndex(leader, leader.addon.Events.Internal.RaidReplicationCommitted, "RAID_CONCLUDED"))
	local creationIndex =
		assert(firstEmittedEventIndex(leader, leader.addon.Events.Internal.RaidReplicationCommitted, "RAID_CREATED"))
	assertTrue(conclusionIndex < creationIndex, "No published the new raid before concluding the recovered raid")
	assertEqual(nil, leader.syncer._reentry, "No retained the chosen recovery state")
	assertTrue(select(2, leader.syncer:GetStatus()) ~= "DIGEST_MISMATCH", "No ended in a digest mismatch")
	print("PASS raid_reentry_no_replaces_once_without_digest_conflict")
end

function cases.raid_leader_reentry_resume_keeps_identity()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	leader.currentRaid = nil
	installReentryDecisionBridge(leader)
	installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	local sequence, digest = leader.store.record.sequence, leader.store.record.digest
	resolveReentry(leader, "resume")
	assertEqual("raid-live", leader.currentRaidUid)
	assertEqual(sequence, leader.store.record.sequence, "resume created a revision")
	assertEqual(digest, leader.store.record.digest, "resume changed the digest")
	assertEqual(0, leader.createdRaids)
	print("PASS raid_leader_reentry_resume_keeps_identity")
end

function cases.raid_leader_reentry_replace_uses_recovered_base()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	leader.currentRaid = nil
	installReentryDecisionBridge(leader)
	installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assertEqual(5, leader.store.record.sequence, "replacement did not first recover the best base")
	resolveReentry(leader, "replace")
	assertEqual(1, leader.concludedRaids)
	assertEqual(1, leader.createdRaids)
	assertEqual("raid-replacement-1", leader.currentRaidUid)
	print("PASS raid_leader_reentry_replace_uses_recovered_base")
end

function cases.raid_leader_reentry_replace_publishes_lifecycle_before_head()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	leader.currentRaid = nil
	installReentryDecisionBridge(leader)
	local replica = installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	resolveReentry(leader, "replace")
	assertEqual("raid-replacement-1", leader.store.record.raidUid)
	assertEqual(
		nil,
		leader.syncer._reentry,
		"replacement suspended before publishing lifecycle events: " .. tostring(select(2, leader.syncer:GetStatus()))
	)
	assertEqual(
		"raid-replacement-1",
		replica.store.record.raidUid,
		"replica retained the concluded active raid after replacement"
	)
	assertEqual("active", replica.store.record.status, "replica did not converge to the replacement")
	assertEqual(
		leader.store.record.sequence,
		replica.store.record.sequence,
		"replica missed the post-create attendance event"
	)
	print("PASS raid_leader_reentry_replace_publishes_lifecycle_before_head")
end

function cases.raid_leader_reentry_discards_deferred_events_on_rollback()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	leader.currentRaid = nil
	installReentryDecisionBridge(leader)
	local replica = installLiveReplicationClient(network, "ReplicaB", makeLiveRecord(5))
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	leader.failReplacement = true
	resolveReentry(leader, "replace")
	assertEqual("raid-live", replica.store.record.raidUid, "rolled-back transition published a lifecycle event")
	assertEqual(5, replica.store.record.sequence, "rolled-back transition changed the replica")
	assertTrue(leader.syncer:IsAuthorityRecovering("raid-live"), "failed transition reopened the write barrier")
	print("PASS raid_leader_reentry_discards_deferred_events_on_rollback")
end

function cases.raid_leader_reentry_context_mismatch_skips_popup()
	local network = newLiveReplicationNetwork()
	local previous = makeLiveRecord(2)
	previous.state.zone = "Ulduar"
	local leader = installLiveReplicationClient(network, "Leader", previous)
	leader.currentRaid = nil
	installReentryDecisionBridge(leader)
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assert(leader:FireHandoverTimer())
	assertEqual(0, #leader.decisionRequests, "mismatched context opened the popup")
	assertEqual(1, leader.concludedRaids)
	assertEqual(1, leader.createdRaids)
	print("PASS raid_leader_reentry_context_mismatch_skips_popup")
end

function cases.raid_leader_reentry_dismissal_stays_suspended()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	leader.currentRaid = nil
	installReentryDecisionBridge(leader)
	leader.callbacks.RaidInstanceRecognized[1](nil, "Naxxramas", "naxxramas", 1)
	assert(leader:FireHandoverTimer())
	assert(leader:FireHandoverTimer())
	assertEqual(1, #leader.decisionRequests)
	assertTrue(leader.syncer:IsAuthorityRecovering("raid-live"), "dismissal opened writes")
	assertEqual(nil, leader.store:Commit(makeLiveEvent(3)), "dismissal allowed a commit")
	assertEqual(0, leader.createdRaids)
	print("PASS raid_leader_reentry_dismissal_stays_suspended")
end

function cases.raid_live_sync_unresolved_authority_retries_after_roster_settlement()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local memberOptions = { overrideRaidLeaderIdentity = true }
	local member = installLiveReplicationClient(network, "Member", nil, memberOptions)
	local recognized = assert(member.callbacks.RaidInstanceRecognized)

	recognized[1](nil, "Naxxramas", "naxxramas")
	recognized[1](nil, "Naxxramas", "naxxramas")
	assertEqual(0, countKind(member.requests, "HEAD_REQ"), "unresolved authority sent an immediate request")
	assertEqual(nil, member.store.record, "unresolved member created a raid")
	assertEqual(1, #(member.timers or {}), "duplicate unresolved signals did not coalesce")

	local retry = assert(member.timers[1], "unresolved discovery retry missing")
	assertEqual(3, retry.delay, "unresolved discovery retry delay differs")
	memberOptions.reportedRaidLeaderName = "Leader"
	retry.callback()

	assertEqual(1, countKind(member.requests, "HEAD_REQ"), "settled authority request count differs")
	assertEqual("HEAD_REQ", member.requests[1], "settled member did not request the active HEAD")
	assertEqual("HEAD", leader.requests[1], "leader did not advertise its active HEAD")
	assertEqual("SNAP_REQ", member.requests[2], "settled member did not request the snapshot")
	assertEqual("SNAP_DATA", leader.requests[2], "leader did not transfer the snapshot")
	assertEqual(leader.store.record.raidUid, member.store.record.raidUid, "replica UID differs")
	assertEqual(leader.store.record.sequence, member.store.record.sequence, "replica sequence differs")
	assertEqual(leader.store.record.digest, member.store.record.digest, "replica digest differs")
	assertEqual(nil, member.store.committed[1], "non-leader committed an authoritative event")

	retry.callback()
	assertEqual(1, countKind(member.requests, "HEAD_REQ"), "settled discovery retried more than once")

	print("PASS raid_live_sync_unresolved_authority_retries_after_roster_settlement")
end

function cases.raid_live_sync_member_enters_before_designated_leader()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", nil)
	local member = installLiveReplicationClient(network, "Member", nil)
	local recognized = assert(member.callbacks.RaidInstanceRecognized)
	recognized[1](nil, "Naxxramas", "naxxramas")
	assertEqual("HEAD_REQ", member.requests[1], "member did not request the designated leader record")
	assertEqual(nil, member.store.record, "member created before the designated leader")

	leader.store.record = makeLiveRecord(2)
	leader.currentRaid = 1
	local created = assert(leader.callbacks.RaidCreate)
	created[1](nil, "raid-live")
	assertEqual(leader.store.record.raidUid, member.store.record.raidUid, "member did not import after leader entry")
	assertEqual(leader.store.record.sequence, member.store.record.sequence, "member imported a different sequence")
	assertEqual(leader.store.record.digest, member.store.record.digest, "member imported a different digest")
	assertEqual(nil, member.store.committed[1], "member became authority from entry order")
	print("PASS raid_live_sync_member_enters_before_designated_leader")
end

function cases.raid_live_sync_range_snapshot_fallback()
	local network = newLiveReplicationNetwork()
	local leaderRecord = makeLiveRecord(3)
	leaderRecord.checkpointSequence = 2
	local leader = installLiveReplicationClient(network, "Leader", leaderRecord)
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))
	local wire = network:encode("EVENT", "-", "-", { event = makeLiveEvent(3) })
	member.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(3, member.store.record.sequence, "unavailable range did not fall back to snapshot")
	assertEqual("RANGE_REQ", member.requests[1], "gap did not attempt range first")
	assertEqual("SNAP_REQ", member.requests[2], "range failure did not request snapshot")
	print("PASS raid_live_sync_range_snapshot_fallback")
end

function cases.raid_live_sync_conclusion_snapshot_recovery()
	local network = newLiveReplicationNetwork()
	local leaderRecord = makeLiveRecord(2)
	leaderRecord.checkpointSequence = 2
	local leader = installLiveReplicationClient(network, "Leader", leaderRecord)
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))
	assert(leader.store:Commit(makeConclusionEvent(3)))
	assertEqual(3, member.store.record.sequence, "replica did not recover final sequence")
	assertEqual("complete", member.store.record.status, "replica did not compact concluded raid")
	assertEqual(0, #member.store.record.events, "replica retained concluded event ledger")
	assertEqual("SNAP_REQ", member.requests[1], "future conclusion did not request final snapshot immediately")
	assertEqual(1, #member.requests, "future conclusion emitted an unnecessary recovery request")
	assertEqual("SNAP_DATA", leader.transfers[1], "authority did not serve bounded final snapshot")
	assertEqual("EVENT", leader.requests[1], "authority did not announce conclusion event")
	assertEqual("HEAD", leader.requests[#leader.requests], "authority did not always announce final HEAD")
	assertEqual(1, countKind(leader.requests, "HEAD"), "authority final HEAD count differs")
	print("PASS raid_live_sync_conclusion_snapshot_recovery")
end

function cases.raid_live_sync_real_session_future_conclusion(addon)
	local fixture = installFaithfulLiveReplica(addon)
	local raidEvents = addon.DB.RaidEvents
	local event = makeConclusionEvent(3)
	event.eventUid = assert(raidEvents.BuildEventUid(event.raidUid, event.authorityEpoch, event.sequence))
	local wire = assert(fixture.protocol.Encode("EVENT", "-", "-", { event = event }))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(1, #fixture.queued, "future conclusion did not send exactly one immediate request")
	local request = assert(fixture.protocol.Decode(fixture.queued[1].message))
	assertEqual("SNAP_REQ", request.kind, "future conclusion attempted range before final snapshot")
	assertEqual(
		1,
		#fixture.session._outgoingRates.live.leader,
		"active snapshot request did not use the live rate class"
	)
	assertEqual(
		nil,
		fixture.session._outgoingRates.history.leader,
		"active snapshot request consumed history rate budget"
	)
	assertEqual(1, #fixture.timers, "immediate final snapshot request did not use real session timer")
	assertEqual(100, fixture.now, "future conclusion required timeout advancement before snapshot request")
	print("PASS raid_live_sync_real_session_future_conclusion")
end

function cases.raid_live_sync_real_session_final_head(addon)
	local fixture = installFaithfulLiveReplica(addon)
	local head = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 3,
		digest = "00000003:1",
		status = "complete",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(1, #fixture.queued, "final HEAD did not request recovery immediately")
	local request = assert(fixture.protocol.Decode(fixture.queued[1].message))
	assertEqual("SNAP_REQ", request.kind, "final HEAD requested range")
	local finalSnapshot = makeLiveRecord(3)
	finalSnapshot.status = "complete"
	finalSnapshot.checkpointSequence = 3
	finalSnapshot.events = {}
	deliverFaithfulFinalSnapshot(fixture, request, finalSnapshot)
	assertEqual(1, #fixture.session._outgoingRates.live.member, "active snapshot data did not use the live rate class")
	assertEqual(nil, fixture.session._outgoingRates.history.member, "active snapshot data consumed history rate budget")
	local status, statusReason = fixture.syncer:GetStatus()
	assertEqual(
		3,
		fixture.store.record.sequence,
		"final HEAD snapshot did not converge status=" .. tostring(status) .. " reason=" .. tostring(statusReason)
	)
	assertEqual("complete", fixture.store.record.status, "final HEAD snapshot did not compact raid")
	assertEqual(0, #fixture.store.record.events, "final HEAD snapshot retained event ledger")
	local queued = #fixture.queued
	fixture.now = 200
	fixture.session:Expire(fixture.now)
	assertEqual(queued, #fixture.queued, "completed final snapshot request retried")
	print("PASS raid_live_sync_real_session_final_head")
end

function cases.raid_live_sync_real_session_conclusion_coalescing(addon)
	local fixture = installFaithfulLiveReplica(addon)
	local raidEvents = addon.DB.RaidEvents
	local event = makeConclusionEvent(3)
	event.eventUid = assert(raidEvents.BuildEventUid(event.raidUid, event.authorityEpoch, event.sequence))
	local eventWire = assert(fixture.protocol.Encode("EVENT", "-", "-", { event = event }))
	fixture.syncer:OnAddonMessage("RMARaidSync", eventWire, "RAID", "Leader-Test Realm")
	local head = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 3,
		digest = "00000003:1",
		status = "complete",
	}
	local headWire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
	fixture.syncer:OnAddonMessage("RMARaidSync", headWire, "RAID", "Leader-Test Realm")
	assertEqual(1, #fixture.queued, "EVENT plus final HEAD opened duplicate snapshot requests")
	local request = assert(fixture.protocol.Decode(fixture.queued[1].message))
	assertEqual("SNAP_REQ", request.kind, "coalesced conclusion recovery kind differs")
	local finalSnapshot = makeLiveRecord(3)
	finalSnapshot.status = "complete"
	finalSnapshot.checkpointSequence = 3
	finalSnapshot.events = {}
	deliverFaithfulFinalSnapshot(fixture, request, finalSnapshot)
	local status = fixture.syncer:GetStatus()
	assertEqual("synchronized", status, "coalesced conclusion did not finish synchronized")
	local queued = #fixture.queued
	fixture.now = 200
	fixture.session:Expire(fixture.now)
	assertEqual(queued, #fixture.queued, "completed coalesced recovery retried")
	print("PASS raid_live_sync_real_session_conclusion_coalescing")
end

function cases.raid_live_sync_real_session_range_coalescing(addon)
	local fixture = installFaithfulLiveReplica(addon)
	local head = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 0,
		digest = "00000003:1",
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(1, #fixture.queued, "identical active HEAD opened duplicate range requests")
	local request = assert(fixture.protocol.Decode(fixture.queued[1].message))
	assertEqual("RANGE_REQ", request.kind, "identical active HEAD recovery kind differs")
	print("PASS raid_live_sync_real_session_range_coalescing")
end

function cases.raid_live_sync_range_coalesces_newer_head_burst(addon)
	local fixture = installFaithfulLiveReplica(addon)
	local firstHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 0,
		digest = "00000003:1",
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", firstHead))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local firstRequest = assert(fixture.protocol.Decode(fixture.queued[1].message))
	assertEqual("RANGE_REQ", firstRequest.kind, "first recovery is not a range request")

	for sequence = 4, 7 do
		local head = {
			raidUid = "raid-live",
			authorityEpoch = 1,
			sequence = sequence,
			checkpointSequence = 0,
			digest = "0000000" .. tostring(sequence) .. ":1",
			status = "active",
		}
		wire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
		fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	end
	assertEqual(1, #fixture.queued, "newer HEAD burst opened replacement requests")
	assertEqual(0, #fixture.cancelled, "newer HEAD burst cancelled the active range")
	assertEqual(7, fixture.syncer._recovery.followUp.sequence, "newest HEAD was not retained")

	deliverFaithfulRange(fixture, firstRequest, { makeLiveEvent(2), makeLiveEvent(3) })
	assertEqual(2, #fixture.queued, "initial range did not open one catch-up range")
	local catchUp = assert(fixture.protocol.Decode(fixture.queued[2].message))
	assertEqual("RANGE_REQ", catchUp.kind, "catch-up recovery is not a range request")
	assertEqual(4, catchUp.body.fromSequence, "catch-up range begins at the wrong sequence")
	assertEqual(7, catchUp.body.toSequence, "catch-up range omits the newest HEAD")
	deliverFaithfulRange(fixture, catchUp, { makeLiveEvent(4), makeLiveEvent(5), makeLiveEvent(6), makeLiveEvent(7) })
	assertEqual(7, fixture.store.record.sequence, "catch-up range did not install the newest sequence")
	assertEqual("00000007:1", fixture.store.record.digest, "catch-up range did not install the newest digest")
	assertEqual("synchronized", fixture.syncer:GetStatus(), "catch-up range did not finish synchronized")
	print("PASS raid_live_sync_range_coalesces_newer_head_burst")
end

function cases.raid_live_sync_real_session_monotonic_supersession(addon)
	local fixture = installFaithfulLiveReplica(addon)
	local rangeHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 0,
		digest = "00000003:1",
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", rangeHead))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local first = assert(fixture.protocol.Decode(fixture.queued[1].message))
	assertEqual("RANGE_REQ", first.kind, "initial pending recovery is not range")

	local finalHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 4,
		checkpointSequence = 4,
		digest = "00000004:1",
		status = "complete",
	}
	wire = assert(fixture.protocol.Encode("HEAD", "-", "-", finalHead))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(1, #fixture.queued, "newer conclusion replaced the active range before it finished")
	assertEqual(0, #fixture.cancelled, "newer conclusion cancelled the active range")
	assertEqual(4, fixture.syncer._recovery.followUp.sequence, "newer conclusion was not retained")
	deliverFaithfulRange(fixture, first, { makeLiveEvent(2), makeLiveEvent(3) })
	assertEqual(2, #fixture.queued, "completed follow-up did not open one final request")
	local finalRequest = assert(fixture.protocol.Decode(fixture.queued[2].message))
	assertEqual("SNAP_REQ", finalRequest.kind, "newer conclusion replacement is not snapshot")
	local snapshot = makeLiveRecord(4)
	snapshot.status = "complete"
	snapshot.checkpointSequence = 4
	snapshot.events = {}
	deliverFaithfulFinalSnapshot(fixture, finalRequest, snapshot)
	assertEqual("synchronized", fixture.syncer:GetStatus(), "superseded recovery did not finish synchronized")
	local queued = #fixture.queued
	fixture.now = 200
	fixture.session:Expire(fixture.now)
	assertEqual(queued, #fixture.queued, "superseded range or completed snapshot retried")
	print("PASS raid_live_sync_real_session_monotonic_supersession")
end

local function consumeLiveRecoveryBudget(fixture)
	for i = 1, 4 do
		assert(
			fixture.session:BeginRequest(
				"RANGE_REQ",
				"Leader",
				rangeMetadata(),
				"RANGE_DATA",
				rangeMetadata(),
				function() end,
				fixture.session.RATE_CLASS_LIVE
			)
		)
	end
end

function cases.raid_live_sync_retries_latest_rate_limited_head(addon)
	local fixture = installFaithfulLiveReplica(addon)
	consumeLiveRecoveryBudget(fixture)
	local initialQueued = #fixture.queued
	local firstHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 0,
		digest = "00000003:1",
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", firstHead))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(initialQueued, #fixture.queued, "rate-limited HEAD opened a request immediately")
	local retry = assert(fixture.syncer._admissionRetry, "rate-limited HEAD did not retain a retry target")
	assertEqual(30, retry.timer.delay, "rate retry delay differs from the session boundary")
	local scheduledTimer = retry.timer

	local newestHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 4,
		checkpointSequence = 0,
		digest = "00000004:1",
		status = "active",
	}
	wire = assert(fixture.protocol.Encode("HEAD", "-", "-", newestHead))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(scheduledTimer, fixture.syncer._admissionRetry.timer, "newer HEAD allocated a second retry timer")
	assertEqual(4, fixture.syncer._admissionRetry.head.sequence, "newer HEAD did not replace the retry target")
	fixture.now = fixture.now + 30
	scheduledTimer.callback()
	assertEqual(initialQueued + 1, #fixture.queued, "retry did not request the retained newest HEAD")
	local retriedRequest = assert(fixture.protocol.Decode(fixture.queued[#fixture.queued].message))
	assertEqual(4, retriedRequest.body.toSequence, "retry requested a stale HEAD position")

	local secondFixture = installFaithfulLiveReplica(newAddon())
	consumeLiveRecoveryBudget(secondFixture)
	wire = assert(secondFixture.protocol.Encode("HEAD", "-", "-", firstHead))
	secondFixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local secondRetry = assert(secondFixture.syncer._admissionRetry, "second rate-limited HEAD did not schedule retry")
	secondRetry.timer.callback()
	assertEqual(nil, secondFixture.syncer._admissionRetry, "second admission failure retained another retry")
	assertEqual("failed", secondFixture.syncer:GetStatus(), "second admission failure was not terminal")
	print("PASS raid_live_sync_retries_latest_rate_limited_head")
end

function cases.raid_live_sync_retained_retry_ignores_delayed_head(addon)
	local fixture = installFaithfulLiveReplica(addon)
	consumeLiveRecoveryBudget(fixture)
	local retainedHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 4,
		checkpointSequence = 0,
		digest = "00000004:1",
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", retainedHead))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assert(fixture.syncer._admissionRetry, "newest target was not retained")
	fixture.now = fixture.now + 30
	local delayedHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 0,
		digest = "00000003:1",
		status = "active",
	}
	wire = assert(fixture.protocol.Encode("HEAD", "-", "-", delayedHead))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local request = assert(fixture.protocol.Decode(fixture.queued[#fixture.queued].message))
	assertEqual("RANGE_REQ", request.kind, "delayed HEAD did not start recovery")
	assertEqual(4, request.body.toSequence, "delayed HEAD discarded the retained newest target")
	assertEqual(nil, fixture.syncer._admissionRetry, "admitted retained target kept a retry timer")
	print("PASS raid_live_sync_retained_retry_ignores_delayed_head")
end

function cases.raid_live_sync_retained_retry_rejects_delayed_digest_conflict(addon)
	local fixture = installFaithfulLiveReplica(addon)
	fixture.store.record = makeLiveRecord(3)
	consumeLiveRecoveryBudget(fixture)
	local retainedHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 4,
		checkpointSequence = 0,
		digest = "00000004:1",
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", retainedHead))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local retry = assert(fixture.syncer._admissionRetry, "newest target was not retained")
	local retryTimer = retry.timer
	local queued = #fixture.queued
	local conflictingHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 0,
		digest = "ffffffff:3",
		status = "active",
	}
	wire = assert(fixture.protocol.Encode("HEAD", "-", "-", conflictingHead))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local status, reason = fixture.syncer:GetStatus()
	assertEqual("suspended", status, "delayed digest conflict did not suspend recovery")
	assertEqual("DIGEST_CONFLICT", reason, "delayed digest conflict reason differs")
	assertEqual(nil, fixture.syncer._admissionRetry, "delayed digest conflict retained retry state")
	assertEqual(true, retryTimer.cancelled, "delayed digest conflict did not cancel retry timer")
	assertEqual(queued, #fixture.queued, "delayed digest conflict opened a recovery request")
	print("PASS raid_live_sync_retained_retry_rejects_delayed_digest_conflict")
end

local function makeFaithfulReplicaEvent(fixture)
	local store = fixture.store
	local original = assert(store:CaptureRaidHistoryState())
	local active = assert(store:GetActiveRecord())
	local raidUid = assert(store:GetRaidUid(active.state))
	assert(store:SetAuthorityGuard(function()
		return true
	end))
	local event = assert(store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
		metadata = { zone = "Ulduar" },
	}))
	assert(store:RestoreRaidHistoryState(original))
	assert(store:SetAuthorityGuard(function()
		return fixture.localRaidLeader
	end))
	return event
end

function cases.raid_live_sync_real_store_event_clears_admission_retry(addon)
	local fixture = installFaithfulLiveReplica(addon, { realStore = true })
	local event = makeFaithfulReplicaEvent(fixture)
	consumeLiveRecoveryBudget(fixture)
	local head = {
		raidUid = event.raidUid,
		authorityEpoch = event.authorityEpoch,
		sequence = event.sequence,
		checkpointSequence = 0,
		digest = event.resultDigest,
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local retry = assert(fixture.syncer._admissionRetry, "real-store retry was not scheduled")
	local retryTimer = retry.timer
	wire = assert(fixture.protocol.Encode("EVENT", "-", "-", { event = event }))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(nil, fixture.syncer._admissionRetry, "real-store event did not clear its retry target")
	assertEqual(true, retryTimer.cancelled, "real-store event did not cancel the retry timer")
	local queued = #fixture.queued
	retryTimer.callback()
	assertEqual(queued, #fixture.queued, "cancelled retry callback opened a stale request")
	print("PASS raid_live_sync_real_store_event_clears_admission_retry")
end

function cases.raid_live_sync_digest_mismatch_clears_admission_retry(addon)
	local fixture = installFaithfulLiveReplica(addon, { realStore = true })
	local record = assert(fixture.store:GetActiveRecord())
	local raidUid = assert(fixture.store:GetRaidUid(record.state))
	consumeLiveRecoveryBudget(fixture)
	local head = {
		raidUid = raidUid,
		authorityEpoch = record.authorityEpoch,
		sequence = 2,
		checkpointSequence = 0,
		digest = "ffffffff:2",
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local retry = assert(fixture.syncer._admissionRetry, "digest-mismatch retry was not scheduled")
	local retryTimer = retry.timer
	local event = {
		raidUid = raidUid,
		authorityEpoch = record.authorityEpoch,
		sequence = 2,
		eventUid = assert(addon.DB.RaidEvents.BuildEventUid(raidUid, record.authorityEpoch, 2)),
		eventType = "RAID_METADATA_UPDATED",
		payload = { metadata = { zone = "Ulduar" } },
		resultDigest = "ffffffff:2",
	}
	wire = assert(fixture.protocol.Encode("EVENT", "-", "-", { event = event }))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual("suspended", fixture.syncer:GetStatus(), "digest mismatch did not suspend recovery")
	assertEqual(nil, fixture.syncer._admissionRetry, "digest mismatch retained the retry target")
	assertEqual(true, retryTimer.cancelled, "digest mismatch did not cancel the retry timer")
	print("PASS raid_live_sync_digest_mismatch_clears_admission_retry")
end

function cases.raid_live_sync_admission_retry_timer_unavailable_is_terminal(addon)
	local fixture = installFaithfulLiveReplica(addon)
	consumeLiveRecoveryBudget(fixture)
	fixture.syncer.ScheduleTimer = function()
		return nil
	end
	local head = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 0,
		digest = "00000003:1",
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local status, reason = fixture.syncer:GetStatus()
	assertEqual("failed", status, "unavailable retry timer did not fail recovery")
	assertEqual("TIMER_UNAVAILABLE", reason, "unavailable retry timer reported the admission reason")
	assertEqual(nil, fixture.syncer._admissionRetry, "unavailable retry timer retained state")
	print("PASS raid_live_sync_admission_retry_timer_unavailable_is_terminal")
end

function cases.raid_live_sync_real_session_direct_event_cancellation(addon)
	local fixture = installFaithfulLiveReplica(addon)
	local head = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 2,
		checkpointSequence = 0,
		digest = "00000002:1",
		status = "active",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", head))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual("RANGE_REQ", assert(fixture.protocol.Decode(fixture.queued[1].message)).kind)
	local event = makeLiveEvent(2)
	event.eventUid = assert(addon.DB.RaidEvents.BuildEventUid(event.raidUid, event.authorityEpoch, event.sequence))
	event.eventType = "PLAYER_UPDATED"
	event.payload = { player = { playerNid = 2, name = "Beta" } }
	wire = assert(fixture.protocol.Encode("EVENT", "-", "-", { event = event }))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(1, #fixture.cancelled, "direct event did not cancel obsolete range timer")
	assertEqual("synchronized", fixture.syncer:GetStatus(), "direct event did not remain synchronized")
	local queued = #fixture.queued
	fixture.now = 200
	fixture.session:Expire(fixture.now)
	assertEqual(queued, #fixture.queued, "cancelled obsolete range retried")
	assertEqual("synchronized", fixture.syncer:GetStatus(), "stale cancel callback changed synchronized status")
	print("PASS raid_live_sync_real_session_direct_event_cancellation")
end

local function assertRealStoreConflictOutcome(fixture)
	local before = deepCopy(assert(fixture.store:GetActiveRecord()))
	assertEqual(1, #fixture.cancelled, "conflicting in-flight recovery was not cancelled")
	assertEqual("suspended", fixture.syncer:GetStatus(), "in-flight digest conflict did not suspend")
	local _, reason = fixture.syncer:GetStatus()
	assertEqual("DIGEST_CONFLICT", reason, "in-flight digest conflict reason differs")
	local after = assert(fixture.store:GetActiveRecord())
	assertEqual(before.sequence, after.sequence, "digest conflict changed real store sequence")
	assertEqual(before.digest, after.digest, "digest conflict changed real store digest")
	fixture.now = 200
	fixture.session:Expire(fixture.now)
	assertEqual(1, #fixture.queued, "cancelled conflicting recovery retried")
	assertEqual("suspended", fixture.syncer:GetStatus(), "stale conflict callback changed status")
end

function cases.raid_live_sync_real_store_pending_head_digest_conflict(addon)
	local fixture = installFaithfulLiveReplica(addon, { realStore = true })
	local record = assert(fixture.store:GetActiveRecord())
	local raidUid = assert(fixture.store:GetRaidUid(record.state))
	local headA = {
		raidUid = raidUid,
		authorityEpoch = record.authorityEpoch,
		sequence = 2,
		checkpointSequence = 0,
		digest = "aaaaaaaa:1",
		status = "active",
	}
	local wire, encodeReason = fixture.protocol.Encode("HEAD", "-", "-", headA)
	assert(wire, tostring(encodeReason) .. " uid=" .. tostring(raidUid) .. " digest=" .. tostring(record.digest))
	assertTrue(fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm"))
	local headB = deepCopy(headA)
	headB.digest = "bbbbbbbb:1"
	wire = assert(fixture.protocol.Encode("HEAD", "-", "-", headB))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertRealStoreConflictOutcome(fixture)
	print("PASS raid_live_sync_real_store_pending_head_digest_conflict")
end

function cases.raid_live_sync_real_store_pending_event_digest_conflict(addon)
	local fixture = installFaithfulLiveReplica(addon, { realStore = true })
	local record = assert(fixture.store:GetActiveRecord())
	local raidUid = assert(fixture.store:GetRaidUid(record.state))
	local head = {
		raidUid = raidUid,
		authorityEpoch = record.authorityEpoch,
		sequence = 2,
		checkpointSequence = 0,
		digest = "aaaaaaaa:1",
		status = "active",
	}
	local wire, encodeReason = fixture.protocol.Encode("HEAD", "-", "-", head)
	assert(wire, tostring(encodeReason) .. " uid=" .. tostring(raidUid) .. " digest=" .. tostring(record.digest))
	assertTrue(fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm"))
	local event = {
		raidUid = raidUid,
		authorityEpoch = record.authorityEpoch,
		sequence = 2,
		eventUid = assert(addon.DB.RaidEvents.BuildEventUid(raidUid, record.authorityEpoch, 2)),
		eventType = "RAID_METADATA_UPDATED",
		payload = { metadata = { zone = "Ulduar" } },
		resultDigest = "bbbbbbbb:1",
	}
	wire = assert(fixture.protocol.Encode("EVENT", "-", "-", { event = event }))
	fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertRealStoreConflictOutcome(fixture)
	print("PASS raid_live_sync_real_store_pending_event_digest_conflict")
end

function cases.raid_live_sync_complete_head_consent_boundary(addon)
	local fixture = installFaithfulLiveReplica(addon)
	fixture.store.record.raidUid = "active-a"
	local other = {
		raidUid = "complete-b",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 3,
		digest = "00000003:1",
		status = "complete",
	}
	local wire = assert(fixture.protocol.Encode("HEAD", "-", "-", other))
	local accepted, reason = fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(false, accepted, "different completed UID was accepted for live repair")
	assertEqual("HISTORY_CONSENT_REQUIRED", reason, "different completed UID rejection differs")
	assertEqual(0, #fixture.queued, "different completed UID opened snapshot request")

	fixture.store.record = nil
	local missing = deepCopy(other)
	missing.raidUid = "complete-missing"
	wire = assert(fixture.protocol.Encode("HEAD", "-", "-", missing))
	accepted, reason = fixture.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	assertEqual(false, accepted, "missing live raid accepted completed HEAD")
	assertEqual("HISTORY_CONSENT_REQUIRED", reason, "missing live raid rejection differs")
	assertEqual(0, #fixture.queued, "missing live raid opened snapshot request")
	print("PASS raid_live_sync_complete_head_consent_boundary")
end

function cases.raid_live_sync_conclusion_snapshot_scope()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(2))
	assert(leader.store:Commit(makeConclusionEvent(3)))
	local transferCount = #leader.transfers
	network.now = 146
	member.store.record = makeLiveRecord(2)
	local finalHead = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 3,
		checkpointSequence = 3,
		digest = "00000003:1",
		status = "complete",
	}
	member.syncer:RequestSnapshot("Leader", finalHead)
	assertEqual(transferCount, #leader.transfers, "expired final snapshot was served as history")
	local unrelated = deepCopy(finalHead)
	unrelated.raidUid = "unrelated-history"
	member.syncer:RequestSnapshot("Leader", unrelated)
	assertEqual(transferCount, #leader.transfers, "unrelated completed raid was served without consent")
	print("PASS raid_live_sync_conclusion_snapshot_scope")
end

function cases.raid_live_sync_reload_noop()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(2))
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(2))
	leader.syncer:AdvertiseHead()
	assertEqual(0, #member.requests, "matching persisted head caused recovery traffic")
	print("PASS raid_live_sync_reload_noop")
end

function cases.raid_live_sync_authority_rejection()
	local network = newLiveReplicationNetwork()
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))
	local outsiderEvent = network:encode("EVENT", "-", "-", { event = makeLiveEvent(2) })
	member.syncer:OnAddonMessage("RMARaidSync", outsiderEvent, "RAID", "Outsider-Test Realm")
	assertEqual(1, member.store.record.sequence, "wrong sender mutated replica")
	local oldEpoch = network:encode("EVENT", "-", "-", { event = makeLiveEvent(2, 0) })
	member.syncer:OnAddonMessage("RMARaidSync", oldEpoch, "RAID", "Leader-Test Realm")
	assertEqual(1, member.store.record.sequence, "old epoch mutated replica")
	assertEqual(0, #member.requests, "rejected authority message caused recovery")
	print("PASS raid_live_sync_authority_rejection")
end

function cases.raid_live_sync_local_authority_guard()
	local network = newLiveReplicationNetwork()
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))
	local committed, reason = member.store:Commit(makeLiveEvent(2))
	assertEqual(nil, committed, "non-raid-leader client originated event")
	assertEqual("NOT_RAID_LEADER", reason, "non-raid-leader local rejection reason differs")
	assertEqual(1, member.store.record.sequence, "non-raid-leader local event mutated replica")
	print("PASS raid_live_sync_local_authority_guard")
end

function cases.raid_live_sync_authority_requires_role_identity_agreement()
	local nilIdentityNetwork = newLiveReplicationNetwork()
	local nilIdentity = installLiveReplicationClient(nilIdentityNetwork, "Leader", makeLiveRecord(1), {
		localRaidLeaderRole = true,
		overrideRaidLeaderIdentity = true,
		reportedRaidLeaderName = nil,
	})
	local committed, reason = nilIdentity.store:Commit(makeLiveEvent(2))
	assertEqual(nil, committed, "leader role with nil identity originated an event")
	assertEqual("NOT_RAID_LEADER", reason, "nil leader identity rejection reason differs")
	assertEqual(1, nilIdentity.store.record.sequence, "nil leader identity mutated the replica")

	local staleIdentityNetwork = newLiveReplicationNetwork()
	local staleIdentity = installLiveReplicationClient(staleIdentityNetwork, "Leader", makeLiveRecord(1), {
		localRaidLeaderRole = true,
		overrideRaidLeaderIdentity = true,
		reportedRaidLeaderName = "PreviousLeader-Test Realm",
	})
	committed, reason = staleIdentity.store:Commit(makeLiveEvent(2))
	assertEqual(nil, committed, "leader role with stale identity originated an event")
	assertEqual("NOT_RAID_LEADER", reason, "stale leader identity rejection reason differs")
	assertEqual(1, staleIdentity.store.record.sequence, "stale leader identity mutated the replica")

	local matchingIdentityNetwork = newLiveReplicationNetwork()
	local matchingIdentity = installLiveReplicationClient(matchingIdentityNetwork, "Leader", makeLiveRecord(1), {
		localRaidLeaderRole = true,
		overrideRaidLeaderIdentity = true,
		reportedRaidLeaderName = "Leader-Test Realm",
	})
	committed, reason = matchingIdentity.store:Commit(makeLiveEvent(2))
	assertTrue(committed ~= nil, "matching leader role and identity were rejected: " .. tostring(reason))
	assertEqual(2, matchingIdentity.store.record.sequence, "matching leader identity did not commit")
	print("PASS raid_live_sync_authority_requires_role_identity_agreement")
end

local function installAuthorityRecoveryLootFixture(addon)
	local fixture = installLootHardeningMasterFixture(addon, { realLootFlow = true })
	local recovering = true
	fixture.itemRarity = 5
	fixture.itemType = "Weapon"
	_G.GetItemInfo = function()
		return "Thunderfury", nil, fixture.itemRarity, nil, nil, fixture.itemType, nil, nil, nil, "texture"
	end
	fixture.raidUid = "fixture-loot"
	fixture.sequence = 0
	fixture.commitCalls = 0
	fixture.workflowReceipts = 0
	fixture.workflowKeys = {}
	fixture.pendingConsumeCalls = 0
	fixture.passiveDuplicateChecks = 0
	fixture.passiveDuplicateMarks = 0
	fixture.passiveContextConsumes = 0
	fixture.passiveRollConsumeCalls = 0
	fixture.lootWindowContextConsumeCalls = 0
	fixture.bossContextCalls = 0
	fixture.playerMutationCalls = 0
	fixture.atomicCounterCalls = 0
	fixture.logTradeOnlyCalls = 0
	fixture.passiveApplyCalls = 0
	fixture.passiveApplyByKind = {}
	fixture.passiveParseCalls = 0
	fixture.passiveParseWinnerOnly = {}
	fixture.passiveObservationState = {}
	fixture.parsedLootByMessage = {}
	fixture.raid = {
		players = { { playerNid = 1, name = "Stale", countMS = 0 } },
		loot = {},
		nextPlayerNid = 2,
		nextBossNid = 1,
		nextLootNid = 1,
	}

	addon.DB = {
		Syncer = {
			IsAuthorityRecovering = function(_, raidUid)
				return recovering and raidUid == fixture.raidUid
			end,
		},
	}
	addon.Database.EnsureRaidByIndex = function()
		return fixture.raid
	end
	addon.Strings.NormalizeLower = function(value)
		return type(value) == "string" and string.lower(value) or nil
	end
	addon.Database.GetRaidQueries = function()
		return {
			ResolveLootLooterName = function(_, raid, loot)
				for i = 1, #(raid.players or {}) do
					if tonumber(raid.players[i].playerNid) == tonumber(loot and loot.looterNid) then
						return raid.players[i].name
					end
				end
			end,
		}
	end

	fixture.lootStore.GetRaidUid = function(_, raid)
		return raid == fixture.raid and fixture.raidUid or nil
	end
	fixture.lootStore.GetActiveRecord = function()
		return { raidUid = fixture.raidUid, status = "active", state = fixture.raid }
	end
	fixture.lootStore.EnsureRaidByIndex = function()
		return fixture.raid
	end
	fixture.lootStore.CommitAuthoritativeEvent = function(_, raidUid, eventType, payload)
		fixture.commitCalls = fixture.commitCalls + 1
		if recovering then
			return nil, "AUTHORITY_RECOVERING"
		end
		assertEqual(fixture.raidUid, raidUid, "recovery loot commit raid UID differs")
		if eventType == "LOOT_ADDED" and fixture.rejectNextLootAdded then
			fixture.rejectNextLootAdded = false
			return nil, "INJECTED_LOOT_REJECTION"
		end
		if eventType == "LOOT_ADDED" then
			local loot = deepCopy(payload.loot)
			fixture.raid.loot[#fixture.raid.loot + 1] = loot
			fixture.raid.nextLootNid =
				math.max(tonumber(fixture.raid.nextLootNid) or 1, (tonumber(loot.lootNid) or 0) + 1)
			if loot.source == "DISTRIBUTION_AWARD" and tonumber(loot.rollType) == 1 then
				for i = 1, #fixture.raid.players do
					local player = fixture.raid.players[i]
					if tonumber(player.playerNid) == tonumber(loot.looterNid) then
						player.countMS = (tonumber(player.countMS) or 0) + (tonumber(loot.itemCount) or 1)
						fixture.atomicCounterCalls = fixture.atomicCounterCalls + 1
						break
					end
				end
			end
		elseif eventType == "PLAYER_UPDATED" then
			fixture.raid.players[#fixture.raid.players + 1] = deepCopy(payload.player)
			fixture.raid.nextPlayerNid = math.max(
				tonumber(fixture.raid.nextPlayerNid) or 1,
				(tonumber(payload.player and payload.player.playerNid) or 0) + 1
			)
		elseif eventType == "LOOT_UPDATED" then
			for i = 1, #fixture.raid.loot do
				if tonumber(fixture.raid.loot[i].lootNid) == tonumber(payload.loot and payload.loot.lootNid) then
					fixture.raid.loot[i] = deepCopy(payload.loot)
					break
				end
			end
		end
		fixture.sequence = fixture.sequence + 1
		return { eventType = eventType, sequence = fixture.sequence }, fixture.raid
	end

	local workflow = fixture.loot._Workflow
	workflow.RecordReceipt = function(_, receipt)
		fixture.workflowReceipts = fixture.workflowReceipts + 1
		local key = tostring(receipt.rollSessionId or receipt.msg or "")
		fixture.workflowKeys[key] = true
	end

	local passive = fixture.loot._PassiveGroupLoot
	passive.IsPassiveGroupLootMethod = function()
		return true
	end
	passive.ParseGroupLootMessage = function(msg, winnerOnly)
		fixture.passiveParseCalls = fixture.passiveParseCalls + 1
		fixture.passiveParseWinnerOnly[#fixture.passiveParseWinnerOnly + 1] = winnerOnly == true
		local parsed = fixture.parsedLootByMessage[msg]
		if winnerOnly and parsed and parsed.kind ~= "winner" then
			return nil
		end
		return parsed and (parsed.kind == "winner" and "winner" or "selection") or nil, parsed
	end
	passive.ApplyGroupLootObservation = function(owner, observedType, parsed, skipPendingAward)
		fixture.passiveApplyCalls = fixture.passiveApplyCalls + 1
		local kind = tostring(parsed and parsed.kind or "none")
		fixture.passiveApplyByKind[kind] = (fixture.passiveApplyByKind[kind] or 0) + 1
		fixture.passiveObservationState[tostring(parsed and parsed.sessionId or parsed and parsed.rollId or "none")] =
			true
		if parsed and not skipPendingAward then
			owner:AddPendingAward(
				parsed.itemLink,
				parsed.playerName,
				parsed.rollType,
				parsed.rollValue,
				parsed.sessionId,
				parsed.expiresAt
			)
		end
		return observedType, parsed
	end
	passive.ObserveGroupLootMessage = function(owner, msg)
		local observedType, parsed = passive.ParseGroupLootMessage(msg)
		return passive.ApplyGroupLootObservation(owner, observedType, parsed)
	end
	passive.ObserveGroupLootWinnerMessage = passive.ObserveGroupLootMessage
	passive.GetPassiveLootRollEntryByRollId = function(rollId)
		local id = tonumber(rollId)
		if not id then
			return nil
		end
		return {
			sessionId = id == 41 and "GL:marco" or "GL:luca",
			winner = { playerName = id == 41 and "Marco" or "Luca", rollType = 1, rollValue = 88 },
		}
	end
	passive.GetPassiveLootRollEntry = function()
		return nil
	end
	passive.HasLoggedPassiveLoot = function(_, _, rollSessionId)
		fixture.passiveDuplicateChecks = fixture.passiveDuplicateChecks + 1
		return fixture.loggedPassiveSession == tostring(rollSessionId or "")
	end
	passive.RememberLoggedPassiveLoot = function(_, _, rollSessionId)
		fixture.passiveDuplicateMarks = fixture.passiveDuplicateMarks + 1
		fixture.loggedPassiveSession = tostring(rollSessionId or "")
	end
	passive.ConsumePassiveLootRollEntry = function()
		fixture.passiveContextConsumes = fixture.passiveContextConsumes + 1
		fixture.passiveRollConsumeCalls = fixture.passiveRollConsumeCalls + 1
	end

	local removePendingAward = fixture.loot.RemovePendingAward
	function fixture.loot:RemovePendingAward(...)
		fixture.pendingConsumeCalls = fixture.pendingConsumeCalls + 1
		return removePendingAward(self, ...)
	end
	if fixture.loot.LootAttribution and fixture.loot.LootAttribution.CommitPrepared then
		local commitPendingAward = fixture.loot.LootAttribution.CommitPrepared
		fixture.loot.LootAttribution.CommitPrepared = function(...)
			fixture.pendingConsumeCalls = fixture.pendingConsumeCalls + 1
			return commitPendingAward(...)
		end
	end
	local logTradeOnlyLoot = fixture.loot.LogTradeOnlyLoot
	function fixture.loot:LogTradeOnlyLoot(...)
		fixture.logTradeOnlyCalls = fixture.logTradeOnlyCalls + 1
		return logTradeOnlyLoot(self, ...)
	end

	addon.Services.Raid.EnsureRaidPlayerNid = function(_, name)
		for i = 1, #fixture.raid.players do
			if fixture.raid.players[i].name == name then
				return fixture.raid.players[i].playerNid, name
			end
		end
		local playerNid = tonumber(fixture.raid.nextPlayerNid) or 1
		local event = fixture.lootStore:CommitAuthoritativeEvent(fixture.raidUid, "PLAYER_UPDATED", {
			player = { playerNid = playerNid, name = name, countMS = 0 },
		})
		if not event then
			return 0, name
		end
		fixture.playerMutationCalls = fixture.playerMutationCalls + 1
		return playerNid, name
	end
	addon.Services.Raid.AddPlayerCountForRollType = function(_, name, rollType, count)
		fixture.counterCalls = fixture.counterCalls + 1
		for i = 1, #fixture.raid.players do
			local player = fixture.raid.players[i]
			if player.name == name and tonumber(rollType) == 1 then
				player.countMS = (tonumber(player.countMS) or 0) + (tonumber(count) or 1)
			end
		end
		return true
	end
	addon.Services.Raid.FindOrCreateBossNidForLoot = function()
		fixture.bossContextCalls = fixture.bossContextCalls + 1
		return 0
	end
	addon.Services.Raid.ConsumeLootWindowItemContext = function()
		fixture.passiveContextConsumes = fixture.passiveContextConsumes + 1
		fixture.lootWindowContextConsumeCalls = fixture.lootWindowContextConsumeCalls + 1
	end
	addon.Services.Raid.GetActiveLootSource = function()
		return nil
	end
	addon.Services.Raid.IsLootAuthority = function(_, sender)
		return sender == "Master"
	end
	addon.Services.Raid.CanCommitRaidHistory = function()
		return true
	end
	addon.Services.Raid.IsRaidLeader = function()
		return true
	end
	addon.Services.Raid.CanObservePassiveLoot = function()
		return true
	end

	function fixture:SetRecovering(value)
		recovering = value == true
	end

	function fixture:InstallRecoveredSnapshot(includeDuplicate)
		self.raid = {
			players = { { playerNid = 2, name = "Luca", countMS = 0 } },
			loot = {},
			nextPlayerNid = 3,
			nextBossNid = 1,
			nextLootNid = 1,
		}
		if includeDuplicate then
			self.raid.loot[1] = {
				lootNid = 1,
				looterNid = 2,
				itemId = 19019,
				itemString = "item:19019",
				itemLink = "item:19019",
				itemCount = 1,
				rollType = 1,
				rollValue = 77,
				rollSessionId = "GL:luca",
				bossNid = 0,
				time = 100,
				source = "CHAT_MSG_LOOT",
			}
			self.raid.nextLootNid = 2
		end
		self.sequence = 7
		self.commitCalls = 0
		self.counterCalls = 0
		self.atomicCounterCalls = 0
		self.playerMutationCalls = 0
		self.workflowReceipts = 0
		self.workflowKeys = {}
		self.pendingConsumeCalls = 0
		self.passiveApplyCalls = 0
		self.passiveApplyByKind = {}
		self.passiveContextConsumes = 0
		self.passiveRollConsumeCalls = 0
		self.lootWindowContextConsumeCalls = 0
		self.passiveDuplicateChecks = 0
		self.passiveDuplicateMarks = 0
		self.loggedPassiveSession = nil
	end

	installInitStubs(addon)
	loadAddonFile(addon, "Raid Management Addon/Init.lua")

	return fixture
end

function cases.raid_handover_replays_group_loot_after_snapshot(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	local loot = fixture.loot
	local marco = {
		msg = "Marco receives loot: [Thunderfury]",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 1,
		playerName = "Marco",
		rollType = 1,
		rollValue = 88,
		sessionId = "GL:marco",
		rollId = 41,
		playerNid = 71,
		bossNid = 91,
		lootNid = 81,
	}
	local luca = {
		msg = "Luca receives loot: [Thunderfury]",
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 1,
		playerName = "Luca",
		rollType = 1,
		rollValue = 77,
		sessionId = "GL:luca",
		rollId = 42,
		playerNid = 72,
		bossNid = 92,
		lootNid = 82,
	}
	loot:AddLoot(marco.msg, nil, nil, marco)
	loot:AddLoot(marco.msg, nil, nil, deepCopy(marco))
	loot:AddLoot(luca.msg, nil, nil, luca)
	assertEqual(0, fixture.sequence, "recovering Group Loot advanced canonical sequence")
	assertEqual(0, fixture.commitCalls, "recovering Group Loot reached the canonical store")
	assertEqual(0, fixture.workflowReceipts, "recovering Group Loot consumed workflow receipt state")
	assertEqual(0, fixture.pendingConsumeCalls, "recovering Group Loot consumed pending award state")
	assertEqual(0, fixture.counterCalls, "recovering Group Loot changed a player counter")
	assertEqual(0, fixture.passiveDuplicateChecks, "recovering Group Loot consulted duplicate memory")
	assertEqual(0, fixture.passiveDuplicateMarks, "recovering Group Loot changed duplicate memory")
	assertEqual(0, fixture.passiveContextConsumes, "recovering Group Loot consumed runtime context")
	assertEqual(0, fixture.bossContextCalls, "recovering Group Loot resolved boss context")
	assertEqual(0, fixture.playerMutationCalls, "recovering Group Loot allocated a player NID")
	assertEqual(0, #fixture.raid.loot, "recovering Group Loot changed loot rows")

	fixture:InstallRecoveredSnapshot(true)
	fixture:SetRecovering(false)
	assertEqual(true, loot:ReplayAuthorityRecoveryFacts(fixture.raidUid), "Group Loot recovery replay failed")
	assertEqual(9, fixture.sequence, "Group Loot recovery did not commit player and loot events")
	assertEqual(2, #fixture.raid.loot, "snapshot duplicate or recovery receipt changed loot cardinality")
	assertEqual(2, fixture.raid.players[1].playerNid, "snapshot Luca NID was renumbered")
	assertEqual("Luca", fixture.raid.players[1].name, "snapshot Luca identity changed")
	assertEqual(3, fixture.raid.players[2].playerNid, "Marco did not receive the next recovered player NID")
	assertEqual("Marco", fixture.raid.players[2].name, "Marco recovery player differs")
	assertEqual(1, fixture.raid.players[2].countMS, "Marco recovery counter differs")
	assertEqual(2, fixture.raid.loot[2].lootNid, "Marco recovery loot NID differs")
	assertEqual(3, fixture.raid.loot[2].looterNid, "Marco recovery looter NID differs")
	assertEqual(0, fixture.raid.loot[2].bossNid, "stale staged boss NID leaked into recovery")
	assertEqual(1, fixture.counterCalls, "Group Loot recovery counter count differs")
	assertEqual(1, fixture.workflowReceipts, "Group Loot recovery workflow receipt count differs")
	assertEqual(nil, fixture.workflowKeys["GL:luca"], "canonical snapshot duplicate reached workflow state")
	assertEqual(true, loot:ReplayAuthorityRecoveryFacts(fixture.raidUid), "empty Group Loot replay failed")
	assertEqual(9, fixture.sequence, "repeat Group Loot replay duplicated canonical state")
	print("PASS raid_handover_replays_group_loot_after_snapshot")
end

function cases.raid_live_group_loot_service_rows_broadcast_compactly(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	fixture:SetRecovering(false)
	fixture.loot._PassiveGroupLoot.GetPassiveLootRollEntryByRollId = function(rollId)
		return {
			sessionId = "GL:live:" .. tostring(rollId),
			winner = { playerName = "Stale" },
		}
	end
	local rollTypes = { 8, 9 }
	local rollValues = { 71, 72 }
	for index = 1, 4 do
		local message = "Stale receives loot: [Group Loot " .. tostring(index) .. "]"
		local itemLink = "|cffff8000|Hitem:19019|h[Thunderfury]|h|r"
		local handled, reason = fixture.loot:AddLoot(message, nil, nil, {
			msg = message,
			kind = "winner",
			itemLink = itemLink,
			itemCount = 1,
			playerName = "Stale",
			rollType = rollTypes[index],
			rollValue = rollValues[index],
			sessionId = "GL:live:" .. tostring(index),
			rollId = 100 + index,
		})
		assertTrue(handled, "Group Loot service receipt was rejected: " .. tostring(reason))
	end
	assertEqual(4, #fixture.raid.loot, "Group Loot service did not commit four rows")
	for index = 1, #fixture.raid.loot do
		assertEqual(nil, fixture.raid.loot[index].looter, "Group Loot row retained a display-only looter name")
	end
	assertEqual(8, fixture.raid.loot[1].rollType, "Need roll type changed")
	assertEqual(9, fixture.raid.loot[2].rollType, "Greed roll type changed")
	assertEqual(nil, fixture.raid.loot[3].rollType, "missing Group Loot roll type was invented")
	assertEqual(nil, fixture.raid.loot[4].rollType, "missing Group Loot roll type was invented")
	assertEqual(0, fixture.raid.loot[3].rollValue, "missing Group Loot roll value was not normalized")
	assertEqual(0, fixture.raid.loot[4].rollValue, "missing Group Loot roll value was not normalized")

	local network = newLiveReplicationNetwork()
	local leader, memberB = installAlignedRealLiveReplicationClients(network)
	local leaderRecord = assert(leader.store:GetActiveRecord())
	local raidUid = assert(leader.store:GetRaidUid(leaderRecord.state))
	for index = 1, #fixture.raid.loot do
		assert(leader.store:CommitAuthoritativeEvent(raidUid, "LOOT_ADDED", {
			loot = deepCopy(fixture.raid.loot[index]),
		}))
	end

	leaderRecord = assert(leader.store:GetActiveRecord())
	local replica = assert(memberB.store:GetActiveRecord())
	assertEqual(4, #(leaderRecord.state.loot or {}), "leader Group Loot count differs")
	assertEqual(4, #(replica.state.loot or {}), "replica Group Loot count differs before trailing HEAD")
	assertEqual(leaderRecord.sequence, replica.sequence, "Group Loot replica sequence differs")
	assertEqual(leaderRecord.digest, replica.digest, "Group Loot replica digest differs")
	assertEqual(4, countMessageKind(leader.requests, "LIVE_LOOT"), "Group Loot compact broadcast count differs")
	assertEqual(0, countMessageKind(memberB.requests, "RANGE_REQ"), "Group Loot opened range recovery")
	assertEqual(0, countMessageKind(memberB.requests, "SNAP_REQ"), "Group Loot opened snapshot recovery")
	print("PASS raid_live_group_loot_service_rows_broadcast_compactly")
end

function cases.raid_live_group_loot_realistic_sources_do_not_stall()
	local network = newLiveReplicationNetwork()
	local leader, memberB = installAlignedRealLiveReplicationClients(network, { seedServerTime = 1721120000 })
	local raidUid = assert(leader.store:GetRaidUid(assert(leader.store:GetActiveRecord()).state))
	commitRealCompactLiveLoot(leader, 1)
	commitRealCompactLiveLoot(leader, 2)
	local sources = { realisticLootSource("boss"), realisticLootSource("shared") }
	for index = 1, #sources do
		assert(leader.store:CommitAuthoritativeEvent(
			raidUid,
			"LOOT_ADDED",
			realisticGroupLootPayload(index + 2, sources[index])
		))
	end
	local leaderCount = #(assert(leader.store:GetActiveRecord()).state.loot or {})
	local replicaCount = #(assert(memberB.store:GetActiveRecord()).state.loot or {})
	local partCount, maximumWireBytes = 0, 0
	for index = 1, #leader.sentWires do
		local wire = leader.sentWires[index]
		local envelope = assert(leader.protocol.Decode(wire))
		if envelope.kind == "LIVE_LOOT_PART" then
			partCount = partCount + 1
			maximumWireBytes = math.max(maximumWireBytes, #wire)
		end
	end
	print(string.format(
		"STALL before_trailing_head leader=%d replica=%d live_loot=%d parts=%d max_wire=%d head=%d",
		leaderCount,
		replicaCount,
		countMessageKind(leader.requests, "LIVE_LOOT"),
		partCount,
		maximumWireBytes,
		countMessageKind(leader.requests, "HEAD")
	))
	assertEqual(4, leaderCount, "realistic Group Loot authority count differs")
	assertEqual(4, replicaCount, "realistic Group Loot replica stalled before trailing recovery")
	assertTrue(partCount >= 2, "oversized Group Loot did not use live fragments")
	assertTrue(maximumWireBytes <= 243, "live loot fragment exceeded addon wire bound")
	print("PASS raid_live_group_loot_realistic_sources_do_not_stall")
end

function cases.raid_live_loot_parts_are_bounded_and_order_independent()
	local network = newLiveReplicationNetwork()
	local leader, member = installAlignedRealLiveReplicationClients(network, { seedServerTime = 1721120000 })
	local raidUid = assert(leader.store:GetRaidUid(assert(leader.store:GetActiveRecord()).state))
	local memberClient = network.clients.MemberB
	network.clients.MemberB = nil
	local firstWire = #leader.sentWires + 1
	assert(leader.store:CommitAuthoritativeEvent(
		raidUid,
		"LOOT_ADDED",
		realisticGroupLootPayload(1, realisticLootSource("shared"))
	))
	local parts = {}
	for index = firstWire, #leader.sentWires do
		local wire = leader.sentWires[index]
		local envelope = assert(leader.protocol.Decode(wire))
		if envelope.kind == "LIVE_LOOT_PART" then
			parts[#parts + 1] = wire
		end
	end
	assertTrue(#parts > 1, "representative oversized loot did not fragment")
	network.clients.MemberB = memberClient
	local duplicateAccepted = member.syncer:OnAddonMessage(
		"RMARaidSync",
		parts[#parts],
		"RAID",
		"Leader-Test Realm"
	)
	assertTrue(duplicateAccepted, "first out-of-order fragment was rejected")
	assertTrue(member.syncer:OnAddonMessage(
		"RMARaidSync",
		parts[#parts],
		"RAID",
		"Leader-Test Realm"
	), "identical duplicate fragment was rejected")
	for index = #parts - 1, 1, -1 do
		assertTrue(member.syncer:OnAddonMessage(
			"RMARaidSync",
			parts[index],
			"RAID",
			"Leader-Test Realm"
		), "out-of-order fragment was rejected")
	end
	assertEqual(1, #(assert(member.store:GetActiveRecord()).state.loot or {}), "reordered fragments did not apply once")
	assertEqual(nil, leader.protocol.Encode("LIVE_LOOT_PART", "-", "-", {
		raidUid = raidUid,
		authorityEpoch = 1,
		sequence = 2,
		partIndex = 0,
		partCount = 2,
		chunk = "x",
	}), "zero fragment index was accepted")
	assertEqual(nil, leader.protocol.Encode("LIVE_LOOT_PART", "-", "-", {
		raidUid = raidUid,
		authorityEpoch = 1,
		sequence = 2,
		partIndex = 1,
		partCount = 33,
		chunk = "x",
	}), "excessive fragment count was accepted")
	assertEqual(nil, leader.protocol.Encode("LIVE_LOOT_PART", "-", "-", {
		raidUid = raidUid,
		authorityEpoch = 1,
		sequence = 2,
		partIndex = 1,
		partCount = 1,
		chunk = string.rep("x", 221),
	}), "oversized fragment chunk was accepted")
	print("PASS raid_live_loot_parts_are_bounded_and_order_independent")
end

function cases.raid_handover_loot_chat_gate_is_side_effect_free(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	local message = "Marco receives loot: [Thunderfury]"
	local parsed = {
		msg = message,
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 1,
		playerName = "Marco",
		rollType = 1,
		rollValue = 88,
		sessionId = "GL:cycle",
		rollId = 43,
		playerNid = 71,
		bossNid = 91,
		lootNid = 81,
		nested = { bossNid = 92 },
	}
	parsed.self = parsed
	fixture.parsedLootByMessage[message] = parsed

	local pendingBefore = deepCopy(fixture.lootState.pendingAwards or {})
	local passiveBefore = deepCopy(fixture.passiveObservationState)
	local handled, reason = pcall(addon.CHAT_MSG_LOOT, addon, message)
	assertEqual(true, handled, "recovering CHAT_MSG_LOOT failed on cyclic parsed input: " .. tostring(reason))
	assertEqual(1, fixture.passiveParseCalls, "recovering CHAT_MSG_LOOT did not parse once")
	assertEqual(0, fixture.passiveApplyCalls, "recovering CHAT_MSG_LOOT applied passive observation state")
	assertTrue(
		deepEqual(pendingBefore, fixture.lootState.pendingAwards or {}),
		"recovering CHAT_MSG_LOOT changed pending award state"
	)
	assertTrue(
		deepEqual(passiveBefore, fixture.passiveObservationState),
		"recovering CHAT_MSG_LOOT changed passive observation state"
	)
	assertEqual(0, fixture.workflowReceipts, "recovering CHAT_MSG_LOOT changed workflow state")
	assertEqual(0, fixture.counterCalls, "recovering CHAT_MSG_LOOT changed player counters")
	assertEqual(0, fixture.commitCalls, "recovering CHAT_MSG_LOOT reached the canonical store")

	fixture:InstallRecoveredSnapshot(false)
	fixture:SetRecovering(false)
	assertEqual(
		true,
		fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid),
		"side-effect-free CHAT_MSG_LOOT fact did not replay"
	)
	assertEqual(1, #fixture.raid.loot, "CHAT_MSG_LOOT replay did not append exactly one loot row")
	assertEqual(3, fixture.raid.loot[1].looterNid, "staged player NID leaked through CHAT_MSG_LOOT replay")
	assertEqual(0, fixture.raid.loot[1].bossNid, "staged boss NID leaked through CHAT_MSG_LOOT replay")
	assertEqual(1, fixture.passiveApplyCalls, "CHAT_MSG_LOOT replay did not apply passive observation once")
	print("PASS raid_handover_loot_chat_gate_is_side_effect_free")
end

function cases.raid_handover_keeps_selection_and_winner_facts(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	local selectionMessage = "Marco selected Need for: [Thunderfury]"
	local winnerMessage = "Marco receives loot: [Thunderfury]"
	fixture.parsedLootByMessage[selectionMessage] = {
		msg = selectionMessage,
		kind = "selection",
		itemLink = "item:19019",
		itemCount = 1,
		playerName = "Marco",
		rollType = 1,
		rollValue = 0,
		sessionId = "GL:same-roll",
		rollId = 45,
	}
	fixture.parsedLootByMessage[winnerMessage] = {
		msg = winnerMessage,
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 1,
		playerName = "Marco",
		rollType = 1,
		rollValue = 88,
		sessionId = "GL:same-roll",
		rollId = 45,
	}

	addon:CHAT_MSG_LOOT(selectionMessage)
	addon:CHAT_MSG_LOOT(winnerMessage)
	assertEqual(0, fixture.passiveApplyCalls, "recovering same-roll facts applied passive state")
	assertEqual(0, fixture.commitCalls, "recovering same-roll facts reached the canonical store")

	fixture:InstallRecoveredSnapshot(false)
	fixture:SetRecovering(false)
	assertEqual(
		true,
		fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid),
		"same-roll selection and winner facts did not replay"
	)
	assertEqual(1, fixture.passiveApplyByKind.selection or 0, "same-roll selection observation replay count differs")
	assertEqual(1, fixture.passiveApplyByKind.winner or 0, "same-roll winner observation replay count differs")
	assertEqual(1, #fixture.raid.loot, "same-roll winner did not append exactly one loot row")
	assertEqual(1, fixture.counterCalls, "same-roll winner did not increment exactly one counter")
	assertEqual(true, fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid), "empty same-roll replay failed")
	assertEqual(1, #fixture.raid.loot, "empty same-roll replay duplicated loot")
	assertEqual(1, fixture.counterCalls, "empty same-roll replay duplicated the counter")
	print("PASS raid_handover_keeps_selection_and_winner_facts")
end

function cases.raid_system_loot_parse_is_winner_only(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	fixture:InstallRecoveredSnapshot(false)
	fixture:SetRecovering(false)
	local selectionMessage = "Marco selected Need for: [Thunderfury]"
	local winnerMessage = "Marco receives loot: [Thunderfury]"
	fixture.parsedLootByMessage[selectionMessage] = {
		msg = selectionMessage,
		kind = "selection",
		itemLink = "item:19019",
		playerName = "Marco",
		rollType = 1,
		rollValue = 0,
		sessionId = "GL:system",
		rollId = 46,
	}
	fixture.parsedLootByMessage[winnerMessage] = {
		msg = winnerMessage,
		kind = "winner",
		itemLink = "item:19019",
		playerName = "Marco",
		rollType = 1,
		rollValue = 91,
		sessionId = "GL:system",
		rollId = 46,
	}
	local forwarded = {}
	addon.Services.Raid.CanUseCapability = function()
		return true
	end
	addon.Services.Rolls = addon.Services.Rolls or {}
	addon.Services.Rolls.CHAT_MSG_SYSTEM = function(_, message)
		forwarded[#forwarded + 1] = message
	end

	addon:CHAT_MSG_SYSTEM(selectionMessage)
	assertEqual(true, fixture.passiveParseWinnerOnly[1], "CHAT_MSG_SYSTEM did not request winner-only parsing")
	assertEqual(0, fixture.passiveApplyCalls, "CHAT_MSG_SYSTEM applied a selection observation")
	assertEqual(1, #forwarded, "CHAT_MSG_SYSTEM selection was not forwarded to Rolls")
	assertEqual(selectionMessage, forwarded[1], "CHAT_MSG_SYSTEM forwarded the wrong selection message")

	addon:CHAT_MSG_SYSTEM(winnerMessage)
	assertEqual(true, fixture.passiveParseWinnerOnly[2], "CHAT_MSG_SYSTEM winner parse was not winner-only")
	assertEqual(0, fixture.passiveApplyByKind.selection or 0, "CHAT_MSG_SYSTEM applied selection state")
	assertEqual(1, fixture.passiveApplyByKind.winner or 0, "CHAT_MSG_SYSTEM did not apply the winner once")
	assertEqual(1, #fixture.raid.loot, "CHAT_MSG_SYSTEM winner was not logged once")
	assertEqual(2, #forwarded, "CHAT_MSG_SYSTEM winner was not forwarded to Rolls")
	assertEqual(winnerMessage, forwarded[2], "CHAT_MSG_SYSTEM forwarded the wrong winner message")
	print("PASS raid_system_loot_parse_is_winner_only")
end

local function stageAuthorityRecoveryWinner(fixture, message, sessionId, rollId)
	fixture.parsedLootByMessage[message] = {
		msg = message,
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 1,
		playerName = "Marco",
		rollType = 1,
		rollValue = 88,
		sessionId = sessionId,
		rollId = rollId,
	}
end

local function assertTerminalPassiveWinner(fixture, label)
	assertEqual(1, fixture.pendingConsumeCalls, label .. " pending consume count differs")
	assertEqual(1, fixture.passiveApplyCalls, label .. " winner observation count differs")
	assertEqual(1, fixture.passiveRollConsumeCalls, label .. " passive roll consume count differs")
	assertEqual(0, fixture.lootWindowContextConsumeCalls, label .. " consumed loot-window context")
	assertTrue(deepEqual({}, fixture.lootState.pendingAwards or {}), label .. " retained pending state")
	assertEqual(0, #fixture.raid.loot, label .. " appended loot")
	assertEqual(0, fixture.counterCalls, label .. " changed a player counter")
end

function cases.raid_loot_normal_ignored_passive_winner_is_terminal(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	fixture:InstallRecoveredSnapshot(false)
	fixture:SetRecovering(false)
	fixture.itemRarity = 2
	local message = "Marco receives ignored loot: [Thunderfury]"
	stageAuthorityRecoveryWinner(fixture, message, "GL:ignored-normal", 47)
	fixture.loot:AddPendingAward("item:19019", "Marco", 1, 88, "GL:ignored-normal", 60)

	addon:CHAT_MSG_LOOT(message)
	assertTerminalPassiveWinner(fixture, "normal ignored passive winner")
	print("PASS raid_loot_normal_ignored_passive_winner_is_terminal")
end

function cases.raid_loot_recovery_ignored_passive_winner_is_terminal(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	fixture.itemRarity = 2
	local message = "Marco receives ignored loot: [Thunderfury]"
	stageAuthorityRecoveryWinner(fixture, message, "GL:ignored-recovery", 48)
	addon:CHAT_MSG_LOOT(message)

	fixture:InstallRecoveredSnapshot(false)
	fixture:SetRecovering(false)
	fixture.loot:AddPendingAward("item:19019", "Marco", 1, 88, "GL:ignored-recovery", 60)
	assertEqual(
		true,
		fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid),
		"recovery ignored passive winner replay failed"
	)
	assertTerminalPassiveWinner(fixture, "recovery ignored passive winner")
	assertEqual(
		true,
		fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid),
		"empty ignored passive winner replay failed"
	)
	assertEqual(1, fixture.passiveApplyCalls, "ignored passive winner fact remained queued")
	assertEqual(1, fixture.passiveRollConsumeCalls, "ignored passive winner context repeated")
	print("PASS raid_loot_recovery_ignored_passive_winner_is_terminal")
end

function cases.raid_loot_normal_passive_duplicate_is_terminal(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	fixture:InstallRecoveredSnapshot(false)
	fixture:SetRecovering(false)
	local message = "Marco receives duplicate loot: [Thunderfury]"
	stageAuthorityRecoveryWinner(fixture, message, "GL:duplicate-normal", 49)
	fixture.loggedPassiveSession = "GL:duplicate-normal"
	fixture.loot:AddPendingAward("item:19019", "Marco", 1, 88, "GL:duplicate-normal", 60)

	addon:CHAT_MSG_LOOT(message)
	assertTerminalPassiveWinner(fixture, "normal passive duplicate")
	assertEqual(1, fixture.passiveDuplicateChecks, "normal passive duplicate check count differs")
	assertEqual(0, fixture.passiveDuplicateMarks, "normal passive duplicate changed duplicate memory")
	print("PASS raid_loot_normal_passive_duplicate_is_terminal")
end

function cases.raid_loot_recovery_passive_duplicate_is_terminal(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	local message = "Marco receives duplicate loot: [Thunderfury]"
	stageAuthorityRecoveryWinner(fixture, message, "GL:duplicate-recovery", 50)
	addon:CHAT_MSG_LOOT(message)

	fixture:InstallRecoveredSnapshot(false)
	fixture:SetRecovering(false)
	fixture.loggedPassiveSession = "GL:duplicate-recovery"
	fixture.loot:AddPendingAward("item:19019", "Marco", 1, 88, "GL:duplicate-recovery", 60)
	assertEqual(
		true,
		fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid),
		"recovery passive duplicate replay failed"
	)
	assertTerminalPassiveWinner(fixture, "recovery passive duplicate")
	assertEqual(1, fixture.passiveDuplicateChecks, "recovery passive duplicate check count differs")
	assertEqual(
		true,
		fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid),
		"empty passive duplicate replay failed"
	)
	assertEqual(1, fixture.passiveDuplicateChecks, "passive duplicate fact remained queued")
	assertEqual(1, fixture.passiveApplyCalls, "passive duplicate observation repeated")
	print("PASS raid_loot_recovery_passive_duplicate_is_terminal")
end

function cases.raid_handover_group_loot_retry_is_counter_safe(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	local message = "Marco receives loot: [Thunderfury]"
	fixture.parsedLootByMessage[message] = {
		msg = message,
		kind = "winner",
		itemLink = "item:19019",
		itemCount = 1,
		playerName = "Marco",
		rollType = 1,
		rollValue = 88,
		sessionId = "GL:retry",
		rollId = 44,
	}
	addon:CHAT_MSG_LOOT(message)
	assertEqual(0, fixture.passiveApplyCalls, "recovering retry fact applied passive state before admission")

	fixture:InstallRecoveredSnapshot(false)
	fixture:SetRecovering(false)
	fixture.loot:AddPendingAward("item:19019", "Marco", 1, 88, "GL:retry", 60)
	local pendingBefore = deepCopy(fixture.lootState.pendingAwards or {})
	fixture.rejectNextLootAdded = true
	assertEqual(
		true,
		fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid),
		"rejected Group Loot replay did not remain retryable"
	)
	assertEqual(0, #fixture.raid.loot, "rejected Group Loot replay appended loot")
	assertEqual(0, fixture.counterCalls, "rejected Group Loot replay incremented the player counter")
	assertEqual(0, fixture.workflowReceipts, "rejected Group Loot replay consumed workflow receipt state")
	assertEqual(0, fixture.passiveDuplicateMarks, "rejected Group Loot replay changed duplicate memory")
	assertEqual(0, fixture.pendingConsumeCalls, "rejected Group Loot replay consumed a pending award")
	assertEqual(0, fixture.passiveApplyCalls, "rejected Group Loot replay applied passive observation state")
	assertEqual(0, fixture.passiveRollConsumeCalls, "rejected Group Loot replay consumed passive roll context")
	assertEqual(0, fixture.lootWindowContextConsumeCalls, "rejected Group Loot replay consumed loot-window context")
	assertTrue(
		deepEqual(pendingBefore, fixture.lootState.pendingAwards or {}),
		"rejected Group Loot replay changed pending award state"
	)

	assertEqual(
		true,
		fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid),
		"Group Loot fact did not survive one store rejection"
	)
	assertEqual(1, #fixture.raid.loot, "Group Loot retry did not append exactly one loot row")
	assertEqual(1, fixture.counterCalls, "Group Loot retry incremented the player counter more than once")
	assertEqual(1, fixture.workflowReceipts, "Group Loot retry recorded the workflow receipt more than once")
	assertEqual(1, fixture.passiveDuplicateMarks, "Group Loot retry changed duplicate memory more than once")
	assertEqual(1, fixture.pendingConsumeCalls, "Group Loot retry did not consume the pending award once")
	assertEqual(1, fixture.passiveApplyCalls, "Group Loot retry did not apply passive observation once")
	assertEqual(1, fixture.passiveRollConsumeCalls, "Group Loot retry did not consume passive roll context once")
	assertEqual(1, fixture.lootWindowContextConsumeCalls, "Group Loot retry did not consume loot-window context once")
	assertTrue(deepEqual({}, fixture.lootState.pendingAwards or {}), "Group Loot retry retained pending award state")
	assertEqual(1, fixture.raid.players[2].countMS, "Group Loot retry player counter differs")
	assertEqual(true, fixture.loot:ReplayAuthorityRecoveryFacts(fixture.raidUid), "empty retry replay failed")
	assertEqual(1, fixture.counterCalls, "empty retry replay incremented the player counter")
	assertEqual(1, #fixture.raid.loot, "empty retry replay duplicated loot")
	print("PASS raid_handover_group_loot_retry_is_counter_safe")
end

function cases.raid_handover_master_loot_uses_existing_retry(addon)
	local fixture = installAuthorityRecoveryLootFixture(addon)
	local callbacks =
		assert(fixture.busCallbacks.LootDistributionSessionChanged, "distribution callback was not registered")
	local row = {
		sender = "Master",
		itemLink = "item:19019",
		winnerName = "Marco",
		rollType = 1,
		rollValue = 99,
		count = 2,
		reason = "master_loot:AT:recovery",
	}
	local setupTimerCount = fixture.activeTimerCount()
	local setupCallbackCount = #fixture.timerCallbacks
	callbacks[1]("LootDistributionSessionChanged", "item_done", row, "RS:recovery")
	callbacks[1]("LootDistributionSessionChanged", "item_done", deepCopy(row), "RS:recovery")
	assertEqual(0, fixture.sequence, "recovering Master Loot advanced canonical sequence")
	assertEqual(0, fixture.commitCalls, "recovering Master Loot reached the canonical store")
	assertEqual(0, fixture.logTradeOnlyCalls, "recovering Master Loot entered LogTradeOnlyLoot")
	assertEqual(setupTimerCount + 1, fixture.activeTimerCount(), "one awardId did not coalesce onto the existing retry")
	assertEqual(setupCallbackCount + 1, #fixture.timerCallbacks, "one awardId allocated more than one retry timer")

	fixture:InstallRecoveredSnapshot(false)
	fixture:SetRecovering(false)
	fixture.timerCallbacks[#fixture.timerCallbacks]()
	assertEqual(9, fixture.sequence, "Master Loot retry did not commit player and loot events")
	assertEqual(1, #fixture.raid.loot, "Master Loot retry loot count differs")
	assertEqual(1, fixture.logTradeOnlyCalls, "Master Loot retry entered LogTradeOnlyLoot more than once")
	assertEqual(1, fixture.atomicCounterCalls, "Master Loot retry counter event count differs")
	assertEqual(2, fixture.raid.players[1].playerNid, "Master Loot recovery renumbered Luca")
	assertEqual(3, fixture.raid.players[2].playerNid, "Master Loot recovery Marco NID differs")
	assertEqual(2, fixture.raid.players[2].countMS, "Master Loot recovery counter differs")
	assertEqual(setupTimerCount, fixture.activeTimerCount(), "successful Master Loot retry retained timer ownership")
	print("PASS raid_handover_master_loot_uses_existing_retry")
end

function cases.raid_live_sync_group_loot_leader_authority()
	local network = newLiveReplicationNetwork()
	network.lootMethod = "group"
	local leader = installLiveReplicationClient(network, "Leader", nil)
	local member = installLiveReplicationClient(network, "Member", nil)
	local function installRecognizedInstanceFlow(client)
		local addon = client.addon
		local raid = addon.Services.Raid
		addon.Services.EnsureNamespace = function(name)
			addon.Services[name] = addon.Services[name] or {}
			return addon.Services[name]
		end
		client.createAttempts = 0
		client.createSuccesses = 0
		addon.L.RaidZones = { ["Icecrown Citadel"] = true }
		addon.Diag = { D = setmetatable({}, {
			__index = function()
				return "%s %s %s"
			end,
		}) }
		addon.info = function() end
		addon.Database = {
			GetCurrentRaid = function()
				return client.store:GetActiveRecord() and 1 or nil
			end,
			EnsureRaidByIndex = function()
				return client.store:GetActiveRecord() and client.store.record.state or nil
			end,
			EnsureRaidSchema = function() end,
		}
		addon.Timer.BindMixin(raid, "test-recognized-instance")
		raid._ResolveRaidDifficultyInternal = function(value)
			return tonumber(value)
		end
		raid._GetRaidSizeFromDifficultyInternal = function(value)
			return tonumber(value) == 4 and 25 or nil
		end
		raid.Create = function(_, zone, size, difficulty)
			client.createAttempts = client.createAttempts + 1
			local event, reason = client.store:CreateActiveRaid({
				authorityKey = client.name,
				zone = zone,
				size = size,
				difficulty = difficulty,
				players = { { playerNid = 1, name = "Winner", countMS = 0 } },
			})
			if event then
				client.createSuccesses = client.createSuccesses + 1
				client.currentRaid = 1
			end
			return event ~= nil, reason
		end
		_G.SetRaidTarget = function() end
		loadAddonFile(addon, "Raid Management Addon/Services/Raid/Session.lua")
		return raid
	end

	local memberRaid = installRecognizedInstanceFlow(member)
	local leaderRaid = installRecognizedInstanceFlow(leader)
	_G.GetInstanceInfo = function()
		return "Icecrown Citadel", "raid", 4
	end
	memberRaid:ScheduleInstanceChecks()
	assertEqual(1, member.createAttempts, "ordinary member did not exercise recognized-instance creation")
	assertEqual(0, member.createSuccesses, "ordinary member created a competing raid")
	assertEqual(nil, member.store.record, "rejected member creation left a local candidate")

	leaderRaid:ScheduleInstanceChecks()
	assertEqual(1, leader.createAttempts, "raid leader recognized-instance create count differs")
	assertEqual(1, leader.createSuccesses, "raid leader did not create the recognized Group Loot raid")
	assertTrue(leader.store.record ~= nil, "raid leader has no canonical active raid")
	assertTrue(member.store.record ~= nil, "ordinary member did not bootstrap the active raid")
	assertEqual(leader.store.record.raidUid, member.store.record.raidUid, "snapshot bootstrap raid UID differs")
	assertEqual(leader.store.record.sequence, member.store.record.sequence, "snapshot bootstrap sequence differs")
	assertEqual(leader.store.record.digest, member.store.record.digest, "snapshot bootstrap digest differs")
	assertEqual("SNAP_REQ", member.requests[1], "empty member did not bootstrap through snapshot recovery")

	local raidUid = leader.store.record.raidUid
	local delta, reason = leader.store:CommitAuthoritativeEvent(raidUid, "RAID_METADATA_UPDATED", {
		metadata = { difficulty = 3 },
	})
	assertTrue(delta ~= nil, "raid leader semantic delta was rejected: " .. tostring(reason))
	assertEqual(2, leader.store.record.sequence, "raid leader semantic delta sequence differs")
	assertEqual(2, member.store.record.sequence, "ordinary member did not apply the semantic delta")
	assertEqual(3, member.store.record.state.difficulty, "ordinary member semantic state differs")
	assertEqual(leader.store.record.digest, member.store.record.digest, "member delta digest did not converge")
	assertTrue(deepEqual(leader.store.record.state, member.store.record.state), "member state did not converge")
	print("PASS raid_live_sync_group_loot_leader_authority")
end

function cases.raid_live_sync_split_loot_authority_records_trade_award_once()
	local network = newLiveReplicationNetwork()
	local initial = makeLiveRecord(0)
	initial.state = {
		raidNid = 1,
		zone = "Icecrown Citadel",
		size = 25,
		difficulty = 4,
		players = {
			{ playerNid = 1, name = "Winner", countMS = 0, countOs = 0, countFree = 0, countSR = 0 },
			{ playerNid = 2, name = "Other", countMS = 0, countOs = 0, countFree = 0, countSR = 0 },
		},
		bossKills = {},
		attendance = {},
		loot = {},
		nextPlayerNid = 3,
		nextBossNid = 1,
		nextLootNid = 1,
	}
	local leader = installLiveReplicationClient(network, "Leader", initial)
	local master = installLiveReplicationClient(network, "Master", initial)
	local member = installLiveReplicationClient(network, "Member", initial)

	local function installDistributionPayloadCodec(clientAddon)
		return installPayloadCodec(clientAddon)
	end

	local leaderAddon = leader.addon
	local leaderRaid = leaderAddon.Services.Raid
	leaderAddon.Services.EnsureNamespace = function(name)
		leaderAddon.Services[name] = leaderAddon.Services[name] or {}
		return leaderAddon.Services[name]
	end
	leaderAddon.Events.Internal.LootDistributionSessionChanged = "LootDistributionSessionChanged"
	leaderAddon.Events.Internal.RaidLootUpdate = "RaidLootUpdate"
	leaderAddon.Events.Internal.SetItem = "SetItem"
	leaderAddon.Events.Internal.PlayerCountChanged = "PlayerCountChanged"
	leaderAddon.Bus.TriggerEvent = function(eventName, ...)
		local listeners = leader.callbacks[eventName] or {}
		for i = 1, #listeners do
			listeners[i](eventName, ...)
		end
	end
	leaderAddon.C = {
		itemColors = {},
		rollTypes = {
			MANUAL = 0,
			MAINSPEC = 1,
			OFFSPEC = 2,
			RESERVED = 3,
			FREE = 4,
			BANK = 5,
			DISENCHANT = 6,
			HOLD = 7,
		},
		PENDING_AWARD_TTL_SECONDS = 8,
		GROUP_LOOT_PENDING_AWARD_TTL_SECONDS = 60,
		BOSS_EVENT_CONTEXT_TTL_SECONDS = 30,
		RESERVES_ITEM_FALLBACK_ICON = "texture",
	}
	leaderAddon.Diag = { D = setmetatable({}, {
		__index = function()
			return "%s %s %s %s %s"
		end,
	}) }
	leaderAddon.Deformat = function()
		return nil
	end
	leaderAddon.Options.GetValue = function()
		return false
	end
	leaderAddon.Options.NormalizeLoggerLootQualityThreshold = function(value)
		return tonumber(value) or 2
	end
	leaderAddon.Strings.NormalizeName = function(value)
		return value and (string.match(value, "^([^%-]+)") or value) or nil
	end
	leaderAddon.Strings.NormalizeText = function(value)
		return value and value ~= "" and tostring(value) or nil
	end
	local currentTime = 100
	leaderAddon.Time = {
		GetCurrentTime = function()
			return currentTime
		end,
	}
	leaderAddon.Item = {
		GetItemKey = function(value, fallback)
			return value or fallback
		end,
		GetItemStringFromLink = function(value)
			local itemId = string.match(tostring(value or ""), "item:(%d+)")
			return itemId and "item:" .. itemId or nil
		end,
		GetItemIdFromLink = function(value)
			return tonumber(string.match(tostring(value or ""), "item:(%d+)"))
		end,
	}
	local leaderLootState, leaderItemInfo, leaderRaidState = {}, {}, {}
	leaderAddon.Database = {
		EnsureLootRuntimeState = function()
			return {}, leaderLootState, leaderItemInfo, leaderRaidState
		end,
		GetCurrentRaid = function()
			return leader.store:GetActiveRecord() and 1 or nil
		end,
		EnsureRaidByIndex = function()
			return leader.store:GetActiveRecord() and leader.store.record.state or nil
		end,
		EnsureRaidSchema = function() end,
		GetRaidStore = function()
			return leader.store
		end,
		GetPlayerName = function()
			return "Leader"
		end,
		GetRaidQueries = function()
			return {
				ResolveLootLooterName = function(_, raid, loot)
					for i = 1, #(raid.players or {}) do
						if tonumber(raid.players[i].playerNid) == tonumber(loot.looterNid) then
							return raid.players[i].name
						end
					end
				end,
			}
		end,
	}
	leaderRaid.IsRaidLeader = function()
		return true
	end
	leaderRaid.CanCommitRaidHistory = function()
		return leader.acceptDistributionAwards ~= false
	end
	leaderRaid.IsLootAuthority = function(_, sender)
		local normalized = type(sender) == "string" and (string.match(sender, "^([^%-]+)") or sender) or nil
		return normalized == "Master" or normalized == "Leader"
	end
	leaderRaid.CanUseCapability = function()
		return false
	end
	leaderRaid.EnsureRaidPlayerNid = function(_, name)
		local normalized = leaderAddon.Strings.NormalizeName(name)
		return normalized == "Other" and 2 or 1, normalized
	end
	leaderRaid.FindOrCreateBossNidForLoot = function()
		return 0
	end
	leaderRaid.GetActiveLootSource = function()
		return nil
	end
	leaderRaid.GetPlayerID = function(_, name)
		local normalized = leaderAddon.Strings.NormalizeName(name)
		if normalized == "Winner" then
			return 1
		end
		if normalized == "Other" then
			return 2
		end
		return 0
	end
	leaderRaid.AddPlayer = function(_, player)
		local event =
			leader.store:CommitAuthoritativeEvent(leader.store.record.raidUid, "PLAYER_UPDATED", { player = player })
		return event and player or nil
	end
	installDistributionPayloadCodec(leaderAddon)
	local leaderDistribution
	local leaderSendAddonBatch = leaderAddon.Comms.SendAddonBatch
	local leaderQueueAddonMessages = leaderAddon.Comms.QueueAddonMessages
	local leaderQueueAddonMessage = leaderAddon.Comms.QueueAddonMessage
	local function deliverLeaderMessages(prefix, messages, target)
		for i = 1, #messages do
			if not leaderDistribution
				or leaderDistribution.HandleMessage(prefix, messages[i], target and "WHISPER" or "RAID", "Leader") ~= true
			then
				return false
			end
		end
		return true
	end
	leaderAddon.Comms.SendAddonBatch = function(prefix, messages, target, opts)
		if prefix ~= "RMADist" then
			return leaderSendAddonBatch(prefix, messages, target, opts)
		end
		return deliverLeaderMessages(prefix, messages, target)
	end
	leaderAddon.Comms.QueueAddonMessages = function(prefix, messages, channel, target, opts)
		if prefix ~= "RMADist" then
			return leaderQueueAddonMessages(prefix, messages, channel, target, opts)
		end
		return deliverLeaderMessages(prefix, messages, target)
	end
	leaderAddon.Comms.QueueAddonMessage = function(prefix, message, channel, target, opts)
		if prefix ~= "RMADist" then
			return leaderQueueAddonMessage(prefix, message, channel, target, opts)
		end
		return deliverLeaderMessages(prefix, { message }, target)
	end
	leaderAddon.Comms.NormalizeSender = function(value)
		return tostring(value or ""):match("^[^-]+") or ""
	end
	local noopOwner = setmetatable({}, {
		__index = function()
			return function() end
		end,
	})
	local workflowReceipts = 0
	local workflowOwner = setmetatable({
		RecordReceipt = function()
			workflowReceipts = workflowReceipts + 1
		end,
	}, getmetatable(noopOwner))
	leaderAddon.Services.Loot = {
		LootAttribution = noopOwner,
		_PassiveGroupLoot = setmetatable({
			IsPassiveGroupLootMethod = function()
				return false
			end,
			IsPassiveLootWinnerMessage = function()
				return false
			end,
			GetPassiveLootRollItemKey = function(value)
				return value
			end,
		}, getmetatable(noopOwner)),
		_Tracking = noopOwner,
		_Workflow = workflowOwner,
		_Rules = {
			_IsIgnoredItem = function()
				return false
			end,
		},
		AwardPlanner = noopOwner,
		Inventory = noopOwner,
		_Context = {
			ResolveRaidRecord = function()
				return 1, leader.store.record.state
			end,
		},
	}
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
	_G.GetItemInfo = function()
		return "Thunderfury", nil, 5, nil, nil, "Weapon", nil, nil, nil, "texture"
	end
	loadAddonFile(leaderAddon, "Raid Management Addon/Services/Loot/Recording.lua")
	loadAddonFile(leaderAddon, "Raid Management Addon/Services/Loot/DistributionSession.lua")
	loadAddonFile(leaderAddon, "Raid Management Addon/Services/Raid/Counts.lua")
	loadAddonFile(leaderAddon, "Raid Management Addon/Services/Loot/Service.lua")
	leaderDistribution = leaderAddon.Services.Loot.DistributionSession

	local masterAddon = master.addon
	masterAddon.Services.EnsureNamespace = function(name)
		masterAddon.Services[name] = masterAddon.Services[name] or {}
		return masterAddon.Services[name]
	end
	masterAddon.Database = {
		GetPlayerName = function()
			return "Master"
		end,
	}
	masterAddon.Diag = {}
	masterAddon.Events.Internal.LootDistributionSessionChanged = "LootDistributionSessionChanged"
	masterAddon.Bus.TriggerEvent = function() end
	masterAddon.Item = {
		GetItemKey = function(value, fallback)
			return value or fallback
		end,
		GetItemStringFromLink = function()
			return "item:19019"
		end,
	}
	masterAddon.Strings.NormalizeText = function(value)
		return value and value ~= "" and tostring(value) or nil
	end
	masterAddon.Services.Raid.CanUseCapability = function()
		return true
	end
	masterAddon.Services.Raid.IsLootAuthority = function(_, sender)
		return sender == "Master"
	end
	installDistributionPayloadCodec(masterAddon)
	local masterSendAddonBatch = masterAddon.Comms.SendAddonBatch
	local masterQueueAddonMessages = masterAddon.Comms.QueueAddonMessages
	local masterQueueAddonMessage = masterAddon.Comms.QueueAddonMessage
	local function deliverMasterMessages(prefix, messages, target)
		for i = 1, #messages do
			if leaderDistribution.HandleMessage(prefix, messages[i], target and "WHISPER" or "RAID", "Master") ~= true then
				return false
			end
		end
		return true
	end
	masterAddon.Comms.SendAddonBatch = function(prefix, messages, target, opts)
		if prefix ~= "RMADist" then
			return masterSendAddonBatch(prefix, messages, target, opts)
		end
		return deliverMasterMessages(prefix, messages, target)
	end
	masterAddon.Comms.QueueAddonMessages = function(prefix, messages, channel, target, opts)
		if prefix ~= "RMADist" then
			return masterQueueAddonMessages(prefix, messages, channel, target, opts)
		end
		return deliverMasterMessages(prefix, messages, target)
	end
	masterAddon.Comms.QueueAddonMessage = function(prefix, message, channel, target, opts)
		if prefix ~= "RMADist" then
			return masterQueueAddonMessage(prefix, message, channel, target, opts)
		end
		return deliverMasterMessages(prefix, { message }, target)
	end
	masterAddon.Comms.NormalizeSender = function(value)
		return tostring(value or ""):match("^[^-]+") or ""
	end
	loadAddonFile(masterAddon, "Raid Management Addon/Services/Loot/DistributionSession.lua")
	local distribution = masterAddon.Services.Loot.DistributionSession
	assertTrue(
		distribution.PublishItem({
			itemKey = "item:19019",
			itemLink = "item:19019",
			itemName = "Thunderfury",
			itemTexture = "texture",
			quality = 5,
			count = 1,
		}),
		"master looter could not publish trade-only item facts"
	)
	assertTrue(distribution.PublishRollStart("item:19019", 1), "master looter could not publish roll facts")
	assertTrue(
		distribution.PublishRollEnd("item:19019", "Winner", 99, "master_loot:AT:1"),
		"master looter could not publish winner facts"
	)
	leader.acceptDistributionAwards = false
	assertTrue(distribution.PublishItemDone("item:19019", "Winner"), "master looter could not finalize the award")
	assertEqual(0, leader.store.record.sequence, "unavailable raid authority partially committed the award")
	assertTrue(
		distribution.PublishItemDone("item:19019", "Winner"),
		"duplicate final fact was rejected while authority settled"
	)
	assertEqual(1, #(leader.timers or {}), "duplicate final facts did not coalesce onto one authority retry")
	assertTrue(leader:FireHandoverTimer(), "raid leader consumer did not run its first authority retry")
	assertEqual(0, leader.store.record.sequence, "stale raid leader identity committed during retry")
	assertEqual(1, #(leader.timers or {}), "retryable raid leader identity did not schedule its final retry")
	leader.acceptDistributionAwards = true
	assertTrue(leader:FireHandoverTimer(), "raid leader consumer did not run its final authority retry")
	for _, client in pairs({ leader, master, member }) do
		assertEqual(1, client.store.record.sequence, client.name .. " final award sequence differs")
		assertEqual(1, #client.store.record.state.loot, client.name .. " final loot count differs")
		assertEqual(1, client.store.record.state.loot[1].itemCount, client.name .. " trade-only item count differs")
		assertEqual(1, client.store.record.state.loot[1].rollType, client.name .. " roll type differs")
		assertEqual(99, client.store.record.state.loot[1].rollValue, client.name .. " roll value differs")
		assertEqual(
			"DISTRIBUTION_AWARD",
			client.store.record.state.loot[1].source,
			client.name .. " loot source differs"
		)
		assertEqual(1, client.store.record.state.players[1].countMS, client.name .. " counter differs")
		assertEqual(leader.store.record.digest, client.store.record.digest, client.name .. " digest differs")
		assertTrue(
			deepEqual(leader.store.record.state, client.store.record.state),
			client.name .. " replica state differs"
		)
	end
	assertEqual(1, #leader.store.committed, "raid leader canonical event count differs")
	assertEqual(0, #master.store.committed, "master looter originated canonical raid events")
	assertEqual(0, #member.store.committed, "ordinary member originated canonical raid events")
	local sequence = leader.store.record.sequence
	assertTrue(distribution.PublishItemDone("item:19019", "Winner"), "duplicate terminal publication was rejected")
	assertEqual(sequence, leader.store.record.sequence, "duplicate terminal publication repeated canonical writes")
	assertEqual(1, #leader.store.record.state.loot, "duplicate terminal publication repeated loot")
	assertEqual(1, leader.store.record.state.players[1].countMS, "duplicate terminal publication repeated counter")

	local awarded = leader.store.record.state.loot[1]
	local awardedLootNid = awarded.lootNid
	local awardedRollSessionId = awarded.rollSessionId
	local beforeChatSequence = leader.store.record.sequence
	local matchingChat = {
		kind = "winner",
		msg = "Winner receives loot: [Thunderfury].",
		playerName = "Winner-Realm",
		itemLink = "|cffff8000|Hitem:19019:0:0:0:0:0:0:0|h[Thunderfury]|h|r",
		itemCount = 1,
		rollType = 1,
		rollValue = 99,
	}
	local beforeChat = #leader.store.record.state.loot
	local handled, outcome = leaderAddon.Services.Loot:AddLoot(matchingChat.msg, nil, nil, matchingChat)
	assertTrue(handled, "matching chat receipt was not handled")
	assertEqual(beforeChat, #leader.store.record.state.loot, "matching chat receipt created a duplicate loot row")
	assertEqual(1, #leader.store.record.state.loot, "one award produced more than one canonical receipt")
	assertEqual("reconciled", outcome, "matching chat receipt outcome differs")
	assertEqual(
		beforeChatSequence + 1,
		leader.store.record.sequence,
		"matching chat receipt did not commit exactly one canonical update"
	)
	assertEqual(
		"LOOT_UPDATED",
		leader.store.committed[#leader.store.committed].eventType,
		"matching chat reconciliation did not commit LOOT_UPDATED"
	)
	assertEqual(1, workflowReceipts, "matching chat path recorded more than one workflow receipt")
	assertEqual(
		awardedLootNid,
		leader.store.record.state.loot[1].lootNid,
		"matching chat receipt replaced the authoritative lootNid"
	)
	assertEqual(
		awardedRollSessionId,
		leader.store.record.state.loot[1].rollSessionId,
		"matching chat receipt replaced the authoritative rollSessionId"
	)
	assertEqual(
		1,
		leader.store.record.state.players[1].countMS,
		"matching chat receipt incremented the authoritative counter twice"
	)

	local otherRecipient = deepCopy(matchingChat)
	otherRecipient.msg = "Other receives loot: [Thunderfury]."
	otherRecipient.playerName = "Other-Realm"
	assertTrue(leaderAddon.Services.Loot:AddLoot(otherRecipient.msg, nil, nil, otherRecipient))
	assertEqual(2, #leader.store.record.state.loot, "different recipient was reconciled with the award")
	assertEqual(1, leader.store.record.state.players[2].countMS, "different recipient counter differs")

	local differentCount = deepCopy(matchingChat)
	differentCount.itemCount = 2
	assertTrue(leaderAddon.Services.Loot:AddLoot(differentCount.msg, nil, nil, differentCount))
	assertEqual(3, #leader.store.record.state.loot, "different item count was reconciled with the award")
	assertEqual(3, leader.store.record.state.players[1].countMS, "different-count receipt counter differs")

	currentTime = currentTime + leaderAddon.C.PENDING_AWARD_TTL_SECONDS + 1
	assertTrue(leaderAddon.Services.Loot:AddLoot(matchingChat.msg, nil, nil, matchingChat))
	assertEqual(4, #leader.store.record.state.loot, "stale authoritative award was reconciled with chat")
	assertEqual(4, leader.store.record.state.players[1].countMS, "stale receipt counter differs")

	local nonCountableRollTypes = { 0, 5, 6, 7 }
	for i = 1, #nonCountableRollTypes do
		local rollType = nonCountableRollTypes[i]
		local itemKey = "item:" .. tostring(19019 + i)
		local transactionId = "AT:direct:" .. tostring(rollType)
		assertTrue(
			distribution.PublishItem({
				itemKey = itemKey,
				itemLink = itemKey,
				itemName = "Direct Award " .. tostring(rollType),
				itemTexture = "texture",
				quality = 4,
				count = 1,
			}),
			"master looter could not publish non-countable item facts"
		)
		assertTrue(
			distribution.PublishRollStart(itemKey, rollType),
			"master looter could not publish non-countable roll facts"
		)
		assertTrue(
			distribution.PublishRollEnd(itemKey, "Winner", 0, "master_loot:" .. transactionId),
			"master looter could not publish non-countable winner facts"
		)
		assertTrue(
			distribution.PublishItemDone(itemKey, "Winner"),
			"master looter could not finalize non-countable award"
		)
		local committedSequence = leader.store.record.sequence
		assertTrue(distribution.PublishItemDone(itemKey, "Winner"), "non-countable terminal replay was rejected")
		assertEqual(committedSequence, leader.store.record.sequence, "non-countable replay repeated canonical writes")
	end
	for _, client in pairs({ leader, master, member }) do
		assertEqual(8, #client.store.record.state.loot, client.name .. " non-countable loot count differs")
		assertEqual(4, client.store.record.state.players[1].countMS, client.name .. " non-countable award changed MS")
		assertEqual(0, client.store.record.state.players[1].countOs, client.name .. " non-countable award changed OS")
		assertEqual(0, client.store.record.state.players[1].countSR, client.name .. " non-countable award changed SR")
		assertEqual(
			0,
			client.store.record.state.players[1].countFree,
			client.name .. " non-countable award changed Free"
		)
		assertEqual(
			leader.store.record.digest,
			client.store.record.digest,
			client.name .. " non-countable digest differs"
		)
		assertTrue(
			deepEqual(leader.store.record.state, client.store.record.state),
			client.name .. " non-countable replica state differs"
		)
	end

	local beforeExhaustedRetry = leader.store.record.sequence
	leader.acceptDistributionAwards = false
	assertTrue(
		distribution.PublishItem({
			itemKey = "item:19100",
			itemLink = "item:19100",
			itemName = "Bounded Retry",
			itemTexture = "texture",
			quality = 4,
			count = 1,
		}),
		"master looter could not publish bounded-retry item facts"
	)
	assertTrue(
		distribution.PublishRollStart("item:19100", 0),
		"master looter could not publish bounded-retry roll facts"
	)
	assertTrue(
		distribution.PublishRollEnd("item:19100", "Winner", 0, "master_loot:AT:bounded"),
		"master looter could not publish bounded-retry winner facts"
	)
	assertTrue(
		distribution.PublishItemDone("item:19100", "Winner"),
		"master looter could not finalize bounded-retry award"
	)
	assertTrue(leader:FireTimerByDelay(1), "bounded authority retry one was not scheduled")
	assertTrue(leader:FireTimerByDelay(1), "bounded authority retry two was not scheduled")
	assertTrue(leader:FireTimerByDelay(0.25), "bounded authority retry did not retain the trailing HEAD")
	assertEqual(0, #(leader.timers or {}), "exhausted authority retry continued scheduling")
	assertEqual(beforeExhaustedRetry, leader.store.record.sequence, "exhausted authority retry mutated canonical state")
	leader.acceptDistributionAwards = true

	loadAddonFile(leaderAddon, "Raid Management Addon/Services/Loot/LootAttribution.lua")
	local loot = leaderAddon.Services.Loot
	leaderRaid.CanUseCapability = function(_, capability)
		return capability == "loot"
	end
	network.now = currentTime

	local function queueLocalAttribution(itemLink, rollValue, rollSessionId, transactionId)
		loot:AddPendingAward(itemLink, "Winner", 4, rollValue, rollSessionId, nil, {
			counterApplied = true,
			transactionId = transactionId,
		})
	end

	local function confirmLocalAttribution(itemLink, rollSessionId, transactionId)
		local provisional = loot.LootAttribution.ConfirmProvisional(
			itemLink,
			"Winner",
			rollSessionId,
			1,
			transactionId,
			1,
			function(callback, delay)
				return loot:ScheduleTimer(callback, delay)
			end,
			function(handle)
				return loot:CancelTimer(handle)
			end,
			function(award)
				return loot:LogTradeOnlyLoot(
					award.itemLink,
					award.looter,
					award.rollType,
					award.rollValue,
					1,
					"LOOT_SLOT_CLEARED",
					nil,
					nil,
					award.rollSessionId
				)
			end
		)
		assertTrue(provisional ~= nil, "local slot confirmation did not use the attribution owner")
	end

	local function publishLocalDistribution(itemLink, rollValue, transactionId)
		assertTrue(
			leaderDistribution.PublishItem({
				itemKey = itemLink,
				itemLink = itemLink,
				itemName = "Local Award",
				itemTexture = "texture",
				quality = 5,
				count = 1,
			}),
			"local leader could not publish item facts"
		)
		assertTrue(leaderDistribution.PublishRollStart(itemLink, 4), "local leader could not publish roll facts")
		assertTrue(
			leaderDistribution.PublishRollEnd(itemLink, "Winner", rollValue, "master_loot:" .. transactionId),
			"local leader could not publish winner facts"
		)
		assertTrue(
			leaderDistribution.PublishItemDone(itemLink, "Winner"),
			"local leader could not publish terminal facts"
		)
	end

	local function observeLocalChat(itemLink, rollValue)
		local parsed = {
			msg = "Winner receives loot: [Local Award].",
			kind = "winner",
			itemLink = itemLink,
			itemCount = 1,
			playerName = "Winner",
			rollType = 4,
			rollValue = rollValue,
		}
		loot:AddLoot(parsed.msg, nil, nil, parsed)
	end

	local function assertLocalAwardConverged(beforeRows, beforeCounter, label)
		assertEqual(
			beforeRows + 1,
			#leader.store.record.state.loot,
			label .. " did not produce exactly one canonical row"
		)
		assertEqual(
			beforeCounter + 1,
			leader.store.record.state.players[1].countFree,
			label .. " counter delta differs"
		)
		assertEqual(beforeRows + 1, #member.store.record.state.loot, label .. " replica row count differs")
		assertEqual(
			beforeCounter + 1,
			member.store.record.state.players[1].countFree,
			label .. " replica counter delta differs"
		)
		assertEqual(leader.store.record.digest, member.store.record.digest, label .. " replica digest differs")
		assertTrue(deepEqual(leader.store.record.state, member.store.record.state), label .. " replica state differs")
	end

	local beforeRows = #leader.store.record.state.loot
	local beforeCounter = leader.store.record.state.players[1].countFree
	queueLocalAttribution("item:19200", 94, "RS:local:1", "AT:local:1")
	observeLocalChat("item:19200", 94)
	publishLocalDistribution("item:19200", 94, "AT:local:1")
	assertTrue(
		leaderRaid:AddPlayerCountForRollType("Winner", 4, 1, 1),
		"chat-first local counter owner rejected the award"
	)
	confirmLocalAttribution("item:19200", "RS:local:1", "AT:local:1")
	assertLocalAwardConverged(beforeRows, beforeCounter, "chat-first local award")

	beforeRows = #leader.store.record.state.loot
	beforeCounter = leader.store.record.state.players[1].countFree
	queueLocalAttribution("item:19201", 55, "RS:local:2", "AT:local:2")
	publishLocalDistribution("item:19201", 55, "AT:local:2")
	assertTrue(
		leaderRaid:AddPlayerCountForRollType("Winner", 4, 1, 1),
		"slot-first local counter owner rejected the award"
	)
	confirmLocalAttribution("item:19201", "RS:local:2", "AT:local:2")
	observeLocalChat("item:19201", 55)
	assertLocalAwardConverged(beforeRows, beforeCounter, "slot-first local award")
	print("PASS raid_live_sync_split_loot_authority_records_trade_award_once")
end

function cases.raid_live_sync_digest_conflict()
	local network = newLiveReplicationNetwork()
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(2))
	local body = {
		raidUid = "raid-live",
		authorityEpoch = 1,
		sequence = 2,
		checkpointSequence = 0,
		digest = "ffffffff:1",
		status = "active",
	}
	local wire = network:encode("HEAD", "-", "-", body)
	member.syncer:OnAddonMessage("RMARaidSync", wire, "RAID", "Leader-Test Realm")
	local status, reason = member.syncer:GetStatus()
	assertEqual("suspended", status, "digest conflict did not suspend replication")
	assertEqual("DIGEST_CONFLICT", reason, "digest conflict reason differs")
	assertEqual(0, #member.requests, "digest conflict requested unsafe recovery")
	print("PASS raid_live_sync_digest_conflict")
end

local function installLoggerShareFixture(addon)
	local raids = {
		[1] = { zone = "Icecrown Citadel", startTime = 1721120000, difficulty = 4, loot = {} },
		[2] = { zone = "Ulduar", startTime = 1721110000, difficulty = 3, loot = {} },
	}
	local records = {
		["raid-complete"] = { status = "complete", state = raids[1] },
		["raid-active"] = { status = "active", state = raids[2] },
	}
	local raidUids = { [raids[1]] = "raid-complete", [raids[2]] = "raid-active" }
	local grouped = true
	local currentRaid = 2
	local activeRaidIndex = 2
	local isRaidLeader = true
	local warnings = {}
	local offers = {}
	local callbacks, dialogs, resolved = {}, {}, {}
	local shown
	local offerResult, offerReason = true, nil
	local frameBinding
	local scaffoldDefinition

	local function noop() end
	local function newControl(name)
		return {
			name = name,
			shown = false,
			enabled = true,
			text = "",
			scripts = {},
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
			end,
			GetScript = function(self, scriptName)
				return self.scripts[scriptName]
			end,
			Show = function(self)
				self.shown = true
			end,
			Hide = function(self)
				self.shown = false
				local callback = self.scripts.OnHide
				if callback then
					callback(self)
				end
			end,
			IsShown = function(self)
				return self.shown
			end,
			Enable = function(self)
				self.enabled = true
			end,
			Disable = function(self)
				self.enabled = false
			end,
			SetEnabled = function(self, enabled)
				self.enabled = enabled == true
			end,
			GetWidth = function()
				return 335
			end,
			SetWidth = noop,
			SetHeight = noop,
			SetSize = noop,
			ClearAllPoints = noop,
			SetPoint = noop,
			EnableMouse = noop,
			SetAlpha = noop,
		}
	end

	local listName = "RMALootHistoryRaids"
	local listSuffixes = {
		"Title",
		"HeaderNum",
		"HeaderDate",
		"HeaderZone",
		"HeaderSize",
		"CurrentBtn",
		"ShareBtn",
		"DeleteBtn",
		"EmptyState",
		"ScrollFrame",
	}
	_G[listName] = newControl(listName)
	for i = 1, #listSuffixes do
		_G[listName .. listSuffixes[i]] = newControl(listName .. listSuffixes[i])
	end

	local shareName = "RMALootHistoryShareFrame"
	_G[shareName] = newControl(shareName)
	for _, suffix in ipairs({ "RecipientLabel", "RecipientDropDown", "SendBtn", "Summary", "Status" }) do
		_G[shareName .. suffix] = newControl(shareName .. suffix)
	end

	addon.L = setmetatable({
		BtnShare = "Share",
		BtnDelete = "Delete",
		BtnLoggerSendRaid = "Send",
		StrLoggerShareTitle = "Share Raid History",
		StrLoggerShareRecipient = "Group member",
		StrLoggerShareSummary = "%s\n%s - %s - %d loot records",
		StrLoggerShareNoRaid = "Select a raid to share.",
		StrLoggerShareCompletedOnly = "Raid history sharing is available for completed raids only.",
		StrLoggerShareRequiresGroup = "Join a group to share raid history.",
		StrLoggerSyncStatus = "Status: %s",
		RaidSyncStatusUpToDate = "Up to date",
		RaidSyncStatusRecovering = "Recovering",
		RaidSyncStatusHandover = "Handover",
		RaidSyncStatusTransferringHistory = "Transferring",
		RaidSyncStatusSuspended = "Suspended",
		RaidSyncStatusFailed = "Failed",
		StrUnknown = "Unknown",
		PopupRaidReentryConfirm = "Resume the previous raid?\nZone: %s\nSize: %d\nDifficulty: %s",
	}, {
		__index = function(_, key)
			return key
		end,
	})
	addon.Diag = { W = setmetatable({}, {
		__index = function(_, key)
			return key
		end,
	}) }
	addon.Controllers = {}
	addon.C = { rollTypes = {}, lootTypesColored = {}, itemColors = {}, RESERVES_ITEM_FALLBACK_ICON = "fallback" }
	addon.Options = {}
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
		NormalizeLower = function(value)
			return value and string.lower(value) or value
		end,
		TrimText = function(value)
			return value
		end,
	}
	addon.Colors = {
		NormalizeHexColor = function(value)
			return value
		end,
		GetClassColor = function()
			return 1, 1, 1
		end,
	}
	addon.Base64 = {}
	addon.Sort = {
		CompareValues = function(a, b, asc)
			return asc and a < b or a > b
		end,
		CompareNumbers = function(a, b, asc)
			return asc and a < b or a > b
		end,
		GetLootSortName = function()
			return ""
		end,
	}
	addon.IgnoredMobs = {
		IsTrashMobName = function()
			return false
		end,
		GetTrashMobName = function()
			return nil
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
	addon.Events = {
		Internal = {
			RaidCreate = "RaidCreate",
			LoggerSelectRaid = "LoggerSelectRaid",
			LoggerSelectBoss = "LoggerSelectBoss",
			LoggerSelectPlayer = "LoggerSelectPlayer",
			LoggerSelectBossPlayer = "LoggerSelectBossPlayer",
			LoggerClearPlayerSelections = "LoggerClearPlayerSelections",
			LoggerSelectItem = "LoggerSelectItem",
			LoggerLootChanged = "LoggerLootChanged",
			LoggerDataChanged = "LoggerDataChanged",
			RaidLootUpdate = "RaidLootUpdate",
			LoggerRaidOfferReceived = "LoggerRaidOfferReceived",
			RaidRosterDelta = "RaidRosterDelta",
			RaidReentryDecisionRequired = "RaidReentryDecisionRequired",
			RaidReentryDecisionResolved = "RaidReentryDecisionResolved",
		},
	}
	addon.Bus = {
		RegisterCallback = function(eventName, callback)
			callbacks[eventName] = callbacks[eventName] or {}
			callbacks[eventName][#callbacks[eventName] + 1] = callback
		end,
		TriggerEvent = function(eventName, ...)
			if eventName == "RaidReentryDecisionResolved" then
				resolved[#resolved + 1] =
					{ raidUid = select(1, ...), decision = select(2, ...), context = select(3, ...) }
			end
			local listeners = callbacks[eventName] or {}
			for i = 1, #listeners do
				listeners[i](eventName, ...)
			end
		end,
	}
	addon.Services = {
		Logger = {
			Store = {
				GetRaid = function(_, raidId)
					return raids[raidId]
				end,
			},
			View = {},
			Export = {},
			Actions = {},
			Helpers = {
				FormatRollValueForRow = function(value)
					return value
				end,
				NormalizeRollType = function(value)
					return value
				end,
				GetRollTypeSortValue = function(value)
					return value
				end,
			},
		},
		Raid = {
			Projections = {
				FillRaidList = noop,
				FormatTimestamp = function()
					return "2024-07-16"
				end,
				GetDifficultyLabel = function()
					return "25 Heroic"
				end,
			},
			IsGroupMember = function(_, name)
				return grouped and name == "Member"
			end,
			IsRaidExpired = function()
				return false
			end,
			IsRaidLeader = function()
				return isRaidLeader
			end,
			GetRaidSize = function()
				return 25
			end,
			GetPlayerClass = function()
				return nil
			end,
		},
	}
	local syncer = {
		GetStatus = function()
			return "synchronized"
		end,
		OfferHistoricalRaid = function(_, raidUid, target)
			offers[#offers + 1] = { raidUid = raidUid, target = target }
			return offerResult, offerReason
		end,
	}
	local raidStore = {
		GetRaidUid = function(_, raid)
			return raidUids[raid]
		end,
		GetRecord = function(_, raidUid)
			return records[raidUid]
		end,
		GetActiveRecord = function()
			return records[raidUids[raids[activeRaidIndex]]]
		end,
		GetIndexByArchiveKey = function(_, archiveKey)
			for index = 1, #raids do
				if raidUids[raids[index]] == archiveKey then
					return index
				end
			end
		end,
	}
	addon.Database.GetRaidStore = function()
		return raidStore
	end
	addon.Database.GetSyncer = function()
		return syncer
	end
	addon.Database.EnsureRaidByIndex = function(raidId)
		return raids[raidId]
	end
	addon.Database.GetCurrentRaid = function()
		return currentRaid
	end
	addon.Database.GetRaidNidByIndex = function(raidId)
		return raidId
	end
	addon.IsInGroup = function()
		return grouped
	end
	addon.IsInRaid = function()
		return grouped
	end
	addon.Group = {
		GetTypeAndCount = function()
			return "raid", 1, 2
		end,
	}
	addon.WrapTextInColorCode = function(value)
		return value
	end
	addon.warn = function(_, message)
		warnings[#warnings + 1] = message
	end

	addon.UI = {
		Rows = { SetLoggerRowIndex = noop, ApplyLoggerSkin = noop },
		Popups = {
			Define = function(key, dialog)
				dialogs[key] = dialog
				return true
			end,
			IsDefined = function(key)
				return dialogs[key] ~= nil
			end,
			Show = function(key, text, _, data)
				shown = { key = key, text = text, data = data }
				return true
			end,
			Hide = noop,
			Resize = noop,
			ShowConfirm = noop,
			ShowEditBox = noop,
		},
		Tooltips = { ShowItem = noop, ShowLines = noop, Hide = noop, Bind = noop, BindModel = noop },
		Frames = {
			GetRef = function()
				return nil
			end,
			SetScriptSafely = function(control, scriptName, callback)
				control:SetScript(scriptName, callback)
			end,
			SetFrameTitle = noop,
			BindModuleFrame = function(_, frame, options)
				frameBinding = options
				return frame:GetName()
			end,
			MakeModuleFrameGetter = function()
				return function()
					return nil
				end
			end,
			MakeFrameGetter = function()
				return function()
					return nil
				end
			end,
		},
		Lists = {
			CalculateColumnWidths = function(_, minimums)
				return minimums
			end,
			CreateController = function(config)
				local controller = { config = config, data = {} }
				function controller:Dirty() end
				function controller:Touch() end
				function controller:Sort() end
				return controller
			end,
			MakeIndexedRowName = function(prefix)
				return function(index)
					return prefix .. index
				end
			end,
			CreateRowRenderer = function(callback)
				return callback
			end,
			BindController = noop,
		},
		Selection = {
			SetModifierPolicy = noop,
			EnsureState = noop,
			SetAnchor = noop,
			GetCount = function()
				return 0
			end,
			GetSelected = function()
				return {}
			end,
			IsSelected = function()
				return false
			end,
			GetVersion = function()
				return 0
			end,
			ResolveModifiers = function()
				return false, false
			end,
			Toggle = function()
				return nil, 0
			end,
			SelectRange = function()
				return nil, 0
			end,
			Clear = noop,
		},
		ModuleState = {
			Ensure = function()
				return {}
			end,
		},
		Scaffold = {
			DefineModule = function(definition)
				scaffoldDefinition = definition
			end,
		},
		Primitives = {
			SetEnabled = function(control, enabled)
				if control then
					control.enabled = enabled == true
				end
			end,
			SetShown = function(control, shown)
				if control then
					control.shown = shown == true
				end
			end,
			SetButtonCount = noop,
		},
		ExportDialog = {},
	}

	_G.GetItemIcon = function()
		return nil
	end
	_G.CreateFrame = function()
		return newControl("DynamicFrame")
	end
	_G.UIParent = newControl("UIParent")
	_G.UnitName = function(unit)
		return unit == "raid2" and "Member" or "Player"
	end
	_G.UnitIsUnit = function(unit)
		return unit == "raid1"
	end
	_G.UIDropDownMenu_Initialize = function(dropdown, callback)
		dropdown.initialize = callback
	end
	_G.UIDropDownMenu_CreateInfo = function()
		return {}
	end
	_G.UIDropDownMenu_AddButton = noop
	_G.UIDropDownMenu_SetWidth = noop
	_G.UIDropDownMenu_SetButtonWidth = noop
	_G.UIDropDownMenu_SetText = function(dropdown, text)
		dropdown:SetText(text)
	end
	_G.GetInstanceInfo = function()
		return "Ulduar", "raid", 3, nil, nil, 0, false
	end
	_G.YES, _G.NO = "Yes", "No"

	loadAddonFile(addon, "Raid Management Addon/Controllers/Logger.lua")
	local raidController = addon.Controllers.Logger.Raids._ctrl
	raidController.config.localize(listName)

	return {
		controller = addon.Controllers.Logger,
		raidController = raidController,
		shareButton = _G[listName .. "ShareBtn"],
		shareFrame = _G[shareName],
		sendButton = _G[shareName .. "SendBtn"],
		warnings = warnings,
		offers = offers,
		callbacks = callbacks,
		dialogs = dialogs,
		resolved = resolved,
		getShownPopup = function()
			return shown
		end,
		currentButton = _G[listName .. "CurrentBtn"],
		setGrouped = function(value)
			grouped = value == true
		end,
		setCurrentRaid = function(value)
			currentRaid = value
		end,
		setActiveRaidIndex = function(value)
			activeRaidIndex = value
		end,
		setRaidLeader = function(value)
			isRaidLeader = value == true
		end,
		showLogger = function()
			local frame = newControl("RMALootHistoryFrame")
			assert(scaffoldDefinition and scaffoldDefinition.onLoad, "Logger frame scaffold was not defined")
			scaffoldDefinition.onLoad(frame)
			assert(frameBinding and frameBinding.hookOnShow, "Logger show hook was not bound")
			frameBinding.hookOnShow()
		end,
		hideLogger = function()
			assert(frameBinding and frameBinding.hookOnHide, "Logger hide hook was not bound")
			frameBinding.hookOnHide()
		end,
		setOfferResult = function(result, reason)
			offerResult, offerReason = result, reason
		end,
	}
end

function cases.raid_reentry_popup_routes_explicit_decisions(addon)
	local fixture = installLoggerShareFixture(addon)
	addon.Bus.TriggerEvent(addon.Events.Internal.RaidReentryDecisionRequired, {
		raidUid = "raid-live",
		context = { zone = "Naxxramas", size = 10, difficulty = 1 },
		raid = { zone = "Naxxramas", size = 10, difficulty = 1 },
	})
	local shown = assert(fixture.getShownPopup(), "re-entry popup was not shown")
	assertEqual("RMA_RAID_REENTRY_CONFIRM", shown.key)
	assertTrue(string.find(shown.text, "Naxxramas", 1, true) ~= nil)
	assertTrue(string.find(shown.text, "10", 1, true) ~= nil)
	assertTrue(string.find(shown.text, "25 Heroic", 1, true) ~= nil)
	local dialog = assert(fixture.dialogs[shown.key], "re-entry popup was not defined")
	dialog.OnAccept(nil, shown.data)
	assertEqual("resume", fixture.resolved[1].decision)
	dialog.OnCancel(nil, shown.data, "clicked")
	assertEqual("replace", fixture.resolved[2].decision)
	if dialog.hideOnEscape then
		dialog.OnCancel(nil, shown.data, "escape")
	end
	assertEqual(false, dialog.hideOnEscape, "Escape could silently choose No")
	assertEqual(2, #fixture.resolved, "Escape emitted a recovery decision")
	assertEqual(nil, dialog.OnHide, "popup hide mutated recovery")
	print("PASS raid_reentry_popup_routes_explicit_decisions")
end

function cases.logger_replica_defaults_to_active_archive_without_promoting_current(addon)
	local fixture = installLoggerShareFixture(addon)
	local logger = fixture.controller

	fixture.setCurrentRaid(nil)
	fixture.setActiveRaidIndex(2)
	fixture.setRaidLeader(false)
	logger._SetSelectedRaid(nil)
	fixture.showLogger()
	assertEqual(2, logger.selectedRaid, "read-only replica did not select the active archive row")
	assertEqual(nil, addon.Database.GetCurrentRaid(), "viewing a replica promoted it to current raid")
	fixture.raidController.config.postUpdate("RMALootHistoryRaids")
	assertEqual(false, fixture.currentButton.enabled, "read-only replica enabled Set Current")

	fixture.hideLogger()
	fixture.setActiveRaidIndex(1)
	fixture.showLogger()
	assertEqual(1, logger.selectedRaid, "reopened read-only replica kept a stale active archive row")
	assertEqual(nil, addon.Database.GetCurrentRaid(), "reopening a replica promoted it to current raid")

	fixture.setRaidLeader(true)
	fixture.setCurrentRaid(1)
	logger._SetSelectedRaid(nil)
	fixture.showLogger()
	assertEqual(1, logger.selectedRaid, "local current raid did not take precedence over active archive row")
	print("PASS logger_replica_defaults_to_active_archive_without_promoting_current")
end

function cases.logger_share_eligibility_is_consistent_and_observable(addon)
	local fixture = installLoggerShareFixture(addon)
	local logger = fixture.controller

	logger._SetSelectedRaid(1)
	fixture.raidController.config.postUpdate("RMALootHistoryRaids")
	assertEqual(true, fixture.shareButton.enabled, "completed grouped raid did not enable SHARE")
	fixture.shareButton.scripts.OnClick(fixture.shareButton, "LeftButton")
	assertEqual(true, fixture.shareFrame:IsShown(), "completed grouped raid click did not open SHARE dialog")
	fixture.shareFrame:Hide()

	logger._SetSelectedRaid(2)
	fixture.raidController.config.postUpdate("RMALootHistoryRaids")
	assertEqual(false, fixture.shareButton.enabled, "active raid enabled SHARE")
	local opened, reason = logger.ShowShareDialog()
	assertEqual(false, opened, "active raid opened SHARE dialog")
	assertEqual(addon.L.StrLoggerShareCompletedOnly, reason, "active raid rejection reason differs")
	assertEqual(reason, fixture.warnings[#fixture.warnings], "active raid rejection was silent")

	logger._SetSelectedRaid(1)
	fixture.setGrouped(false)
	fixture.raidController.config.postUpdate("RMALootHistoryRaids")
	assertEqual(false, fixture.shareButton.enabled, "non-grouped raid enabled SHARE")
	opened, reason = logger.ShowShareDialog()
	assertEqual(false, opened, "non-grouped raid opened SHARE dialog")
	assertEqual(addon.L.StrLoggerShareRequiresGroup, reason, "non-group rejection reason differs")
	assertEqual(reason, fixture.warnings[#fixture.warnings], "non-group rejection was silent")
	print("PASS logger_share_eligibility_is_consistent_and_observable")
end

function cases.logger_share_send_surfaces_backend_rejection(addon)
	local fixture = installLoggerShareFixture(addon)
	local logger = fixture.controller
	logger._SetSelectedRaid(1)

	fixture.shareButton.scripts.OnClick(fixture.shareButton, "LeftButton")
	logger._shareTarget = "Member"
	fixture.sendButton.scripts.OnClick(fixture.sendButton, "LeftButton")
	assertEqual(1, #fixture.offers, "valid Send did not offer exactly once")
	assertEqual("raid-complete", fixture.offers[1].raidUid, "Send offered the wrong raid")
	assertEqual("Member", fixture.offers[1].target, "Send offered to the wrong target")
	assertEqual(false, fixture.shareFrame:IsShown(), "successful Send left SHARE dialog open")

	fixture.shareButton.scripts.OnClick(fixture.shareButton, "LeftButton")
	logger._shareTarget = "Member"
	fixture.setOfferResult(false, "history_transfer_busy")
	fixture.sendButton.scripts.OnClick(fixture.sendButton, "LeftButton")
	assertEqual(2, #fixture.offers, "rejected Send did not offer exactly once")
	assertEqual(true, fixture.shareFrame:IsShown(), "backend rejection closed SHARE dialog")
	assertEqual("history_transfer_busy", fixture.warnings[#fixture.warnings], "backend rejection was silent")
	print("PASS logger_share_send_surfaces_backend_rejection")
end

function cases.raid_history_import_outcomes(addon)
	local store = installRaidArchiveFixture(addon)
	local created = assert(store:CreateActiveRaid("Leader-Realm", newReplicationState(), 1721120000))
	local raidUid = created.raidUid
	assert(store:ConcludeActiveRaid(raidUid, 1721120200))
	local snapshot = assert(store:BuildSnapshot(raidUid))
	_G.RMA_Raids = { formatVersion = 1, activeRaidUid = nil, order = {}, raids = {} }
	local invalidUid = deepCopy(snapshot)
	invalidUid.raidUid = "invalid\nuid"
	local pristine = deepCopy(store:EnsureArchive())
	local invalidResult, invalidReason = store:ImportHistoricalSnapshot(invalidUid)
	assertEqual(nil, invalidResult, "direct historical import accepted an invalid source UID")
	assertEqual("INVALID_RAID_UID", invalidReason, "invalid source UID reason differs")
	assertTrue(deepEqual(pristine, store:EnsureArchive()), "invalid source UID mutated the archive")
	snapshot.sourceRaidUid = "forged-source"
	snapshot.conflictOfRaidUid = "forged-source"
	assertEqual("IMPORTED", store:ImportHistoricalSnapshot(snapshot), "new history outcome differs")
	local firstRecord = assert(store:GetRecord(raidUid))
	assertEqual(raidUid, firstRecord.sourceRaidUid, "remote provenance replaced the local source UID")
	assertEqual(nil, firstRecord.conflictOfRaidUid, "first import was classified as a conflict variant")
	assertEqual(1, store:GetRaidIndexByNid(snapshot.state.raidNid), "first import was excluded from raidNid lookup")
	local firstWireSnapshot = assert(store:BuildSnapshot(raidUid))
	assertEqual(nil, firstWireSnapshot.sourceRaidUid, "wire snapshot exposed local source provenance")
	assertEqual(nil, firstWireSnapshot.conflictOfRaidUid, "wire snapshot exposed local conflict provenance")
	assertEqual("ALREADY_PRESENT", store:ImportHistoricalSnapshot(snapshot), "duplicate history outcome differs")
	local before = deepCopy(store:EnsureArchive())
	local conflict = deepCopy(snapshot)
	conflict.state.zone = "Ulduar"
	conflict.digest = assert(addon.DB.RaidEvents.DigestState(conflict.state))
	local conflictOutcome, conflictReason, conflictIndex, conflictUid = store:ImportHistoricalSnapshot(conflict)
	assertEqual("CONFLICT", conflictOutcome, "conflicting history outcome differs")
	assertEqual("RAID_CONFLICT", conflictReason, "conflicting history reason differs")
	assertEqual(2, conflictIndex, "conflicting history row index differs")
	assertEqual(2, #store:EnsureArchive().order, "conflicting history was not preserved")
	assertTrue(conflictUid ~= raidUid, "conflicting history reused its source archive key")
	local conflictRecord = assert(store:GetRecord(conflictUid))
	assertEqual(raidUid, conflictRecord.sourceRaidUid, "conflicting history lost its source UID")
	assertEqual(raidUid, conflictRecord.conflictOfRaidUid, "conflicting history lost its conflict relation")
	local conflictWireSnapshot = assert(store:BuildSnapshot(conflictUid))
	assertEqual(raidUid, conflictWireSnapshot.raidUid, "conflicting history leaked its local archive key on the wire")
	assertEqual(nil, conflictWireSnapshot.sourceRaidUid, "variant wire snapshot exposed local source provenance")
	assertEqual(nil, conflictWireSnapshot.conflictOfRaidUid, "variant wire snapshot exposed local conflict provenance")
	assertEqual(
		"ALREADY_PRESENT",
		store:ImportHistoricalSnapshot(conflict),
		"reimported conflict variant was not deduplicated"
	)
	assertEqual(2, #store:EnsureArchive().order, "reimported conflict created a third row")
	assertEqual(
		1,
		store:GetRaidIndexByNid(snapshot.state.raidNid),
		"conflict variant polluted the canonical raidNid index"
	)
	local reloaded = deepCopy(store:EnsureArchive())
	_G.RMA_Raids = reloaded
	addon.Database.SavedVariables.NormalizeAfterLoad()
	assertEqual(2, #store:EnsureArchive().order, "conflict variant did not survive SavedVariables reload")
	assertEqual(raidUid, store:GetRecord(conflictUid).sourceRaidUid, "reload lost conflict source provenance")
	assertTrue(
		addon.DB.RaidValidator:ValidateArchive(store:EnsureArchive()),
		"reloaded archive with conflict metadata is invalid"
	)
	local invalidProvenance = deepCopy(store:EnsureArchive())
	invalidProvenance.raids[conflictUid].sourceRaidUid = "source\nuid"
	assertEqual(
		nil,
		addon.DB.RaidValidator:ValidateArchive(invalidProvenance),
		"unsafe persisted source UID was accepted"
	)
	assertTrue(not deepEqual(before, store:EnsureArchive()), "conflicting history did not mutate the archive")
	print("PASS raid_history_import_outcomes")
end

local function installHistoricalConsentFixture(addon)
	local store = installRaidArchiveFixture(addon)
	local initial = newReplicationState()
	initial.raidNid = 88
	initial.zone = "Icecrown Citadel"
	initial.size = 25
	initial.difficulty = 4
	local created = assert(store:CreateActiveRaid("Leader-Realm", initial, 1721120000))
	local raidUid = created.raidUid
	assert(store:ConcludeActiveRaid(raidUid, 1721120200))
	local sourceSnapshot = assert(store:BuildSnapshot(raidUid))
	_G.RMA_Raids = { formatVersion = 1, activeRaidUid = nil, order = {}, raids = {} }

	addon.DB.SyncSession = nil
	addon.DB.Syncer = nil
	local fixture = installRaidTransferSessionFixture(addon, { playerName = "Member", safeChannelEncoding = true })
	fixture.leaderInGroup = true
	fixture.memberInGroup = true
	fixture.offers = {}
	fixture.selections = {}
	fixture.callbacks = {}
	addon.L = {
		WarnRaidDatabaseAuthorityReleased = "Raid database authority passed to %s. This client now holds a read-only replica.",
		WarnRaidDatabaseAuthorityReceived = "Raid database authority received from %s. Recovery is in progress; raid history writes are temporarily paused.",
	}
	addon.Diagnose = { D = { LogRaidSyncTrace = "%s %s" } }
	addon.Diag = addon.Diagnose
	addon.Options = {
		RegisterNamespace = function() end,
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Events = {
		Internal = {
			OptionsLoaded = "OptionsLoaded",
			RaidCreate = "RaidCreate",
			RaidRosterDelta = "RaidRosterDelta",
			RaidReplicationCommitted = "RaidReplicationCommitted",
			LoggerSelectRaid = "LoggerSelectRaid",
			LoggerRaidOfferReceived = "LoggerRaidOfferReceived",
			RaidAuthorityRecoveryFinished = "RaidAuthorityRecoveryFinished",
			RaidInstanceRecognized = "RaidInstanceRecognized",
		},
		Wow = { ZoneChangedNewArea = "ZoneChangedNewArea", PartyLootMethodChanged = "PartyLootMethodChanged" },
	}
	addon.Bus = {
		RegisterCallback = function(eventName, callback)
			fixture.callbacks[eventName] = fixture.callbacks[eventName] or {}
			fixture.callbacks[eventName][#fixture.callbacks[eventName] + 1] = callback
		end,
		TriggerEvent = function(eventName, ...)
			if eventName == "LoggerRaidOfferReceived" then
				fixture.offers[#fixture.offers + 1] = ...
			elseif eventName == "LoggerSelectRaid" then
				fixture.selections[#fixture.selections + 1] = { ... }
			end
		end,
	}
	addon.Services = {
		Raid = {
			GetRaidLeaderName = function()
				return "Leader"
			end,
			IsRaidLeader = function()
				return false
			end,
			IsGroupMember = function(_, name)
				local short = string.lower(string.match(tostring(name or ""), "^([^%-]+)") or tostring(name or ""))
				if short == "leader" then
					return fixture.leaderInGroup
				end
				if short == "member" then
					return fixture.memberInGroup
				end
				return false
			end,
		},
	}
	addon.Comms.RegisterPrefixIfAvailable = function()
		return true
	end
	addon.Comms.SendAddonBatch = function(prefix, messages)
		return addon.Comms.QueueAddonMessages(prefix, messages, "RAID")
	end
	loadAddonFile(addon, "Raid Management Addon/Database/DBSyncer.lua")
	loadAddonFile(addon, "Raid Management Addon/Database/DBRaidQueries.lua")
	fixture.store = store
	fixture.snapshot = sourceSnapshot
	fixture.syncer = addon.DB.Syncer
	fixture.queries = addon.DB.RaidQueries

	function fixture:Offer(offerId, snapshot)
		snapshot = snapshot or self.snapshot
		local body = {
			raidUid = snapshot.raidUid,
			authorityEpoch = snapshot.authorityEpoch,
			sequence = snapshot.sequence,
			digest = snapshot.digest,
			zone = snapshot.state.zone,
			startTime = snapshot.state.startTime,
			size = snapshot.state.size,
			difficulty = snapshot.state.difficulty,
			lootCount = #(snapshot.state.loot or {}),
		}
		local wire = assert(self.protocol.Encode("OFFER", offerId, "Member", body))
		return self.syncer:OnAddonMessage("RMARaidSync", wire, "WHISPER", "Leader-TestRealm")
	end

	function fixture:Accept(offerId)
		local accepted, requestId = self.syncer:AcceptHistoricalOffer("Leader-TestRealm", offerId)
		assertEqual(true, accepted, "historical offer acceptance failed: " .. tostring(requestId))
		local request = assert(self.protocol.Decode(self.queued[#self.queued].message))
		assertEqual("SNAP_REQ", request.kind, "acceptance did not request a snapshot")
		assertEqual(requestId, request.requestId, "accepted request correlation differs")
		return request
	end

	function fixture:Transfer(request, snapshot, parts)
		snapshot = snapshot or self.snapshot
		local serialized, serializedReason = self.protocol.EncodeBody({ snapshot = snapshot })
		assertTrue(serialized ~= nil, "historical snapshot serialization failed: " .. tostring(serializedReason))
		local queued, queueReason = self.session:QueueTransfer("SNAP_DATA", request.requestId, "Member", {
			raidUid = snapshot.raidUid,
			authorityEpoch = snapshot.authorityEpoch,
			sequence = snapshot.sequence,
		}, { snapshot = snapshot }, self.session.RATE_CLASS_HISTORY)
		assertTrue(queued, "historical snapshot transfer failed: " .. tostring(queueReason))
		local messages = self.batches[#self.batches].messages
		local maximum = parts or #messages
		for i = 1, maximum do
			assert(self.syncer:OnAddonMessage("RMARaidSync", messages[i], "WHISPER", "Leader-TestRealm"))
		end
		return #messages
	end

	return fixture
end

local function latestQueuedEnvelope(fixture, kind)
	for i = #fixture.queued, 1, -1 do
		local envelope = fixture.protocol.Decode(fixture.queued[i].message)
		if envelope and envelope.kind == kind then
			return envelope
		end
	end
	return nil
end

local function newHistoricalPeerNetwork()
	local network = { now = 100, clients = {}, messages = {}, held = {}, snapRequests = 0 }

	function network:deliver(sender, prefix, message, channel, target)
		local envelope = assert(self.clients[sender].protocol.Decode(message))
		if envelope.kind == "SNAP_REQ" then
			self.snapRequests = self.snapRequests + 1
			if self.dropFirstSnapshotRequest and self.snapRequests == 1 then
				return true
			end
		end
		local targetName = string.lower(string.match(tostring(target or ""), "^([^%-]+)") or "")
		local recipient
		for peerName, peer in pairs(self.clients) do
			if string.lower(peerName) == targetName then
				recipient = peer
				break
			end
		end
		if not recipient then
			return false, "UNKNOWN_TARGET"
		end
		self.messages[#self.messages + 1] = { sender = sender, envelope = envelope }
		return recipient.syncer:OnAddonMessage(prefix, message, channel, sender .. "-TestRealm")
	end

	function network:releaseHeld()
		local held = self.held
		self.held = {}
		for i = 1, #held do
			local row = held[i]
			assert(self:deliver(row.sender, row.prefix, row.message, row.channel, row.target))
		end
	end

	return network
end

local function installHistoricalPeer(network, name, withCompletedRaid)
	local client = { name = name, feedback = {}, offers = {}, selections = {}, timers = {} }
	local peerAddon = newAddon()
	client.addon = peerAddon
	_G.RMA_Raids = { formatVersion = 1, activeRaidUid = nil, order = {}, raids = {} }
	local store = installRaidArchiveFixture(peerAddon)
	local sourceUid
	if withCompletedRaid then
		local state = newReplicationState()
		state.raidNid, state.zone, state.size, state.difficulty = 88, "Icecrown Citadel", 25, 4
		local created = assert(store:CreateActiveRaid("Leader-Realm", state, 1721120000))
		sourceUid = created.raidUid
		assert(store:ConcludeActiveRaid(sourceUid, 1721120200))
	end
	client.archive = deepCopy(store:EnsureArchive())
	peerAddon.Database.SavedVariables.GetRaids = function()
		return client.archive
	end
	peerAddon.DB.SyncSession = nil
	peerAddon.DB.Syncer = nil
	client.protocol = installRaidReplicationProtocolFixture(peerAddon)
	local channel = {
		EncodeForWoWAddonChannel = function(_, text)
			return (
				string.gsub(text, ".", function(character)
					return string.format("%02x", string.byte(character))
				end)
			)
		end,
		DecodeForWoWAddonChannel = function(_, text)
			return (string.gsub(text, "(%x%x)", function(pair)
				return string.char(tonumber(pair, 16))
			end))
		end,
	}
	_G.LibStub = function(libraryName)
		assertEqual("LibDeflate", libraryName)
		return channel
	end
	_G.GetTime = function()
		return network.now
	end
	_G.UnitName = function(unit)
		if unit == "player" then
			return name
		end
	end
	peerAddon.Timer = {
		BindMixin = function(target)
			target.ScheduleTimer = function(_, callback, delay)
				local timer = { callback = callback, deadline = network.now + delay }
				client.timers[#client.timers + 1] = timer
				return timer
			end
			target.CancelTimer = function(_, timer)
				timer.cancelled = true
				return true
			end
		end,
	}
	peerAddon.Comms.NormalizeSender = function(value)
		return string.lower(string.match(tostring(value or ""), "^([^%-]+)") or tostring(value or ""))
	end
	peerAddon.Comms.RegisterPrefixIfAvailable = function()
		return true
	end
	peerAddon.Comms.QueueAddonMessage = function(prefix, message, channelName, target)
		return network:deliver(name, prefix, message, channelName, target)
	end
	peerAddon.Comms.QueueAddonMessages = function(prefix, messages, channelName, target)
		for i = 1, #messages do
			if network.holdSnapshotData and assert(client.protocol.Decode(messages[i])).kind == "SNAP_DATA" then
				network.held[#network.held + 1] = {
					sender = name,
					prefix = prefix,
					message = messages[i],
					channel = channelName,
					target = target,
				}
			else
				assert(network:deliver(name, prefix, messages[i], channelName, target))
			end
		end
		return true
	end
	peerAddon.Comms.SendAddonBatch = function(prefix, messages, target)
		return peerAddon.Comms.QueueAddonMessages(prefix, messages, target and "WHISPER" or "RAID", target)
	end
	peerAddon.L = {
		StrLoggerHistoryShareImported = "IMPORTED %s",
		StrLoggerHistoryShareAlreadyPresent = "ALREADY %s",
		StrLoggerHistoryShareConflict = "CONFLICT %s",
		StrLoggerHistoryShareDeclined = "DECLINED %s",
		StrLoggerHistoryShareFailed = "FAILED %s",
		WarnRaidDatabaseAuthorityReleased = "Raid database authority passed to %s. This client now holds a read-only replica.",
		WarnRaidDatabaseAuthorityReceived = "Raid database authority received from %s. Recovery is in progress; raid history writes are temporarily paused.",
	}
	peerAddon.info = function(_, message)
		client.feedback[#client.feedback + 1] = message
	end
	peerAddon.warn = function(_, message)
		client.feedback[#client.feedback + 1] = message
	end
	peerAddon.debug = function() end
	peerAddon.Diagnose = { D = { LogRaidSyncTrace = "%s %s", LogRaidHistoryShareTrace = "%s %s" } }
	peerAddon.Diag = peerAddon.Diagnose
	peerAddon.Options = {
		RegisterNamespace = function() end,
		IsDebugEnabled = function()
			return false
		end,
	}
	peerAddon.Events = {
		Internal = {
			OptionsLoaded = "OptionsLoaded",
			RaidCreate = "RaidCreate",
			RaidRosterDelta = "RaidRosterDelta",
			RaidReplicationCommitted = "RaidReplicationCommitted",
			LoggerSelectRaid = "LoggerSelectRaid",
			LoggerRaidOfferReceived = "LoggerRaidOfferReceived",
			RaidAuthorityRecoveryFinished = "RaidAuthorityRecoveryFinished",
			RaidInstanceRecognized = "RaidInstanceRecognized",
		},
		Wow = { ZoneChangedNewArea = "ZoneChangedNewArea", PartyLootMethodChanged = "PartyLootMethodChanged" },
	}
	peerAddon.Bus = {
		RegisterCallback = function() end,
		TriggerEvent = function(eventName, ...)
			if eventName == "LoggerRaidOfferReceived" then
				client.offers[#client.offers + 1] = ...
			end
			if eventName == "LoggerSelectRaid" then
				client.selections[#client.selections + 1] = { ... }
			end
		end,
	}
	peerAddon.Services = {
		Raid = {
			GetRaidLeaderName = function()
				return "Leader"
			end,
			IsRaidLeader = function()
				return name == "Leader"
			end,
			IsGroupMember = function(_, value)
				local short = string.lower(string.match(tostring(value or ""), "^([^%-]+)") or "")
				return short == "leader" or short == "member"
			end,
		},
	}
	loadAddonFile(peerAddon, "Raid Management Addon/Database/DBSyncSession.lua")
	loadAddonFile(peerAddon, "Raid Management Addon/Database/DBSyncer.lua")
	loadAddonFile(peerAddon, "Raid Management Addon/Database/DBRaidQueries.lua")
	client.store, client.session, client.syncer = store, peerAddon.DB.SyncSession, peerAddon.DB.Syncer
	client.sourceUid = sourceUid
	network.clients[name] = client
	return client
end

function cases.raid_history_two_peer_retry_and_result_matrix()
	local network = newHistoricalPeerNetwork()
	local leader = installHistoricalPeer(network, "Leader", true)
	local member = installHistoricalPeer(network, "Member", false)
	network.dropFirstSnapshotRequest = true
	local offered, offerId = leader.syncer:OfferHistoricalRaid(leader.sourceUid, "Member")
	assertTrue(offered, "leader did not offer completed history")
	assertEqual(1, #member.offers, "member did not receive the real offer")
	local accepted, requestId = member.syncer:AcceptHistoricalOffer("Leader-TestRealm", offerId)
	assertTrue(accepted, "member did not accept the real offer")
	assertEqual(
		1,
		#member.session._outgoingRates.history.leader,
		"accepted historical SNAP_REQ did not use history rate class"
	)
	assertEqual(
		nil,
		member.session._outgoingRates.live.leader,
		"accepted historical SNAP_REQ consumed live rate budget"
	)
	assertEqual(0, #member.archive.order, "dropped first request imported history")
	assertEqual("transferring_history", member.syncer:GetStatus(), "accepted transfer status differs")
	local feedbackBefore = #leader.feedback
	local wrongOffered = assert(member.protocol.Encode("RESULT", offerId, "Leader", { outcome = "IMPORTED" }))
	assertEqual(
		false,
		leader.syncer:OnAddonMessage("RMARaidSync", wrongOffered, "WHISPER", "Member-TestRealm"),
		"offered state accepted a completed outcome"
	)
	assertEqual(feedbackBefore, #leader.feedback, "invalid RESULT changed visible feedback")
	network.now = 129
	member.syncer:GetStatus()
	assertTrue(member.syncer._historyTransfer ~= nil, "GetStatus pruned a legitimate pre-retry transfer")
	network.now = 130.25
	assertEqual(1, member.session:Expire(network.now), "first request timeout did not retry")
	assertEqual(2, network.snapRequests, "retry did not traverse the real sender")
	assertEqual(
		1,
		#leader.session._outgoingRates.history.member,
		"accepted historical SNAP_DATA did not use history rate class"
	)
	assertEqual(
		nil,
		leader.session._outgoingRates.live.member,
		"accepted historical SNAP_DATA consumed live rate budget"
	)
	local messageKinds = {}
	for i = 1, #network.messages do
		messageKinds[#messageKinds + 1] = network.messages[i].envelope.kind
	end
	local memberStatus, memberReason = member.syncer:GetStatus()
	assertEqual(
		1,
		#member.archive.order,
		"retry response did not import history; messages="
			.. table.concat(messageKinds, ",")
			.. " status="
			.. tostring(memberStatus)
			.. "/"
			.. tostring(memberReason)
			.. " held="
			.. tostring(#network.held)
			.. " pending="
			.. tostring(next(member.session._pendingRequests))
	)
	assertEqual(
		"Icecrown Citadel",
		assert(member.addon.DB.RaidQueries:GetRaidSummary(assert(member.store:GetStateByIndex(1)))).zone,
		"real two-peer import is not visible in Loot History queries"
	)
	assertEqual(1, #member.selections, "real import did not select Loot History once")
	assertEqual(1, #leader.feedback, "sender did not receive terminal visible feedback")
	assertEqual(1, #member.feedback, "receiver did not receive terminal visible feedback")
	assertEqual(
		nil,
		leader.syncer._outgoingOffers[next(leader.syncer._outgoingOffers)],
		"terminal result did not clean sender offer state"
	)
	assertEqual(nil, member.syncer._historyTransfer, "terminal result did not clean receiver transfer state")
	assertTrue(requestId ~= offerId, "accepted request reused the offer ID")
	local _, graceOfferId = assert(leader.syncer:OfferHistoricalRaid(leader.sourceUid, "Member"))
	network.now = 196
	local lateRequest = assert(member.protocol.Encode("SNAP_REQ", "late-after-grace", "Leader", {
		raidUid = leader.sourceUid,
	}))
	assertEqual(
		false,
		leader.syncer:OnAddonMessage("RMARaidSync", lateRequest, "WHISPER", "Member-TestRealm"),
		"sender retained an unaccepted offer beyond its 65-second grace"
	)
	assertTrue(graceOfferId ~= nil, "grace offer ID was not created")
	print("PASS raid_history_two_peer_retry_and_result_matrix")
end

function cases.raid_history_result_matrix_and_feedback()
	local network = newHistoricalPeerNetwork()
	local leader = installHistoricalPeer(network, "Leader", true)
	local member = installHistoricalPeer(network, "Member", false)
	network.holdSnapshotData = true
	local _, offerId = assert(leader.syncer:OfferHistoricalRaid(leader.sourceUid, "Member"))
	local _, requestId = assert(member.syncer:AcceptHistoricalOffer("Leader-TestRealm", offerId))
	assertTrue(#network.held > 0, "accepted real transfer did not reach the held transport")
	local function injectResult(outcome, id)
		local wire = assert(member.protocol.Encode("RESULT", id, "Leader", { outcome = outcome }))
		return leader.syncer:OnAddonMessage("RMARaidSync", wire, "WHISPER", "Member-TestRealm")
	end
	local feedbackBefore = #leader.feedback
	assertEqual(false, injectResult("DECLINED", offerId), "accepted offer accepted DECLINED by offer ID")
	assertEqual(false, injectResult("IMPORTED", offerId), "accepted offer accepted terminal outcome by offer ID")
	assertEqual(false, injectResult("DECLINED", requestId), "accepted request accepted DECLINED")
	assertEqual(false, injectResult("IMPORTED", "wrong-request"), "accepted offer accepted wrong request ID")
	assertEqual(feedbackBefore, #leader.feedback, "rejected RESULT changed sender feedback")
	network:releaseHeld()
	assertEqual("IMPORTED member", leader.feedback[#leader.feedback], "sender IMPORTED feedback differs")
	assertEqual("IMPORTED Leader-TestRealm", member.feedback[#member.feedback], "receiver IMPORTED feedback differs")

	network.holdSnapshotData = false
	local _, duplicateOfferId = assert(leader.syncer:OfferHistoricalRaid(leader.sourceUid, "Member"))
	assert(member.syncer:AcceptHistoricalOffer("Leader-TestRealm", duplicateOfferId))
	assertEqual("ALREADY member", leader.feedback[#leader.feedback], "sender duplicate feedback differs")
	assertEqual("ALREADY Leader-TestRealm", member.feedback[#member.feedback], "receiver duplicate feedback differs")
	assertEqual(1, #member.archive.order, "duplicate feedback path created another row")

	local divergent = assert(leader.store:BuildSnapshot(leader.sourceUid))
	divergent.state.zone = "Ulduar"
	divergent.digest = assert(leader.addon.DB.RaidEvents.DigestState(divergent.state))
	local conflictOutcome, _, _, conflictLocalUid = leader.store:ImportHistoricalSnapshot(divergent)
	assertEqual("CONFLICT", conflictOutcome, "sender conflict fixture was not preserved")
	local _, conflictOfferId = assert(leader.syncer:OfferHistoricalRaid(conflictLocalUid, "Member"))
	local conflictEnvelope = network.messages[#network.messages].envelope
	assertEqual(leader.sourceUid, conflictEnvelope.body.raidUid, "variant offer leaked its local archive key")
	assert(member.syncer:AcceptHistoricalOffer("Leader-TestRealm", conflictOfferId))
	assertEqual(2, #member.archive.order, "conflict transfer did not preserve both histories")
	assertEqual("CONFLICT member", leader.feedback[#leader.feedback], "sender conflict warning differs")
	assertEqual("CONFLICT Leader-TestRealm", member.feedback[#member.feedback], "receiver conflict warning differs")
	assertEqual(2, #member.selections, "conflict import was not selected in Loot History")

	local _, declineOfferId = assert(leader.syncer:OfferHistoricalRaid(leader.sourceUid, "Member"))
	assert(member.syncer:DeclineHistoricalOffer("Leader-TestRealm", declineOfferId))
	assertEqual("DECLINED member", leader.feedback[#leader.feedback], "sender decline feedback differs")
	assertEqual("DECLINED Leader-TestRealm", member.feedback[#member.feedback], "receiver decline feedback differs")

	network.holdSnapshotData = true
	local _, failedOfferId = assert(leader.syncer:OfferHistoricalRaid(leader.sourceUid, "Member"))
	local _, failedRequestId = assert(member.syncer:AcceptHistoricalOffer("Leader-TestRealm", failedOfferId))
	assert(member.session:CancelRequest(failedRequestId, "TEST_FAILURE"))
	assertEqual("FAILED member", leader.feedback[#leader.feedback], "sender failure feedback differs")
	assertEqual("FAILED Leader-TestRealm", member.feedback[#member.feedback], "receiver failure feedback differs")
	assertEqual(2, #member.archive.order, "failed transfer mutated history")
	print("PASS raid_history_result_matrix_and_feedback")
end

function cases.raid_history_consent_transfer(addon)
	local fixture = installHistoricalConsentFixture(addon)
	assert(fixture:Offer("history-offer-1"))
	assertEqual(1, #fixture.offers, "recipient did not receive the offer summary")
	assertEqual(0, #fixture.batches, "snapshot bytes were queued before consent")
	local request = fixture:Accept("history-offer-1")
	fixture:Transfer(request)
	assertEqual(
		"IMPORTED",
		assert(latestQueuedEnvelope(fixture, "RESULT")).body.outcome,
		"terminal import result differs"
	)
	assertEqual(1, #fixture.store:EnsureArchive().order, "imported history did not appear exactly once")
	local imported = assert(fixture.store:GetStateByIndex(1))
	local summary = assert(fixture.queries:GetRaidSummary(imported))
	assertEqual("Icecrown Citadel", summary.zone, "Loot History query missed imported raid")
	assertEqual(1, #fixture.selections, "import did not select the new Loot History row")
	assertEqual(1, fixture.selections[1][1], "selected Loot History row differs")

	fixture.now = fixture.now + 30
	assert(fixture:Offer("history-offer-2"))
	request = fixture:Accept("history-offer-2")
	fixture:Transfer(request)
	assertEqual(
		"ALREADY_PRESENT",
		assert(latestQueuedEnvelope(fixture, "RESULT")).body.outcome,
		"duplicate import result differs"
	)
	assertEqual(1, #fixture.store:EnsureArchive().order, "duplicate history created another row")
	assertEqual(1, #fixture.selections, "duplicate history selected a new row")
	local conflicting = deepCopy(fixture.snapshot)
	conflicting.state.zone = "Ulduar"
	conflicting.digest = assert(addon.DB.RaidEvents.DigestState(conflicting.state))
	assert(fixture:Offer("history-offer-3", conflicting))
	request = fixture:Accept("history-offer-3")
	fixture:Transfer(request, conflicting)
	assertEqual(
		"CONFLICT",
		assert(latestQueuedEnvelope(fixture, "RESULT")).body.outcome,
		"divergent import result differs"
	)
	assertEqual(2, #fixture.store:EnsureArchive().order, "divergent import did not preserve both histories")
	assertEqual(2, #fixture.selections, "divergent import did not select the preserved row")

	local sentBefore = #fixture.queued
	assert(fixture.syncer:OfferHistoricalRaid(fixture.snapshot.raidUid, "Leader-TestRealm"))
	local outbound = assert(fixture.protocol.Decode(fixture.queued[#fixture.queued].message))
	assertEqual("OFFER", outbound.kind, "historical API did not send an offer")
	assertEqual(sentBefore + 1, #fixture.queued, "historical API sent more than the summary")
	assertEqual(nil, outbound.body.snapshot, "historical API leaked snapshot bytes before consent")
	print("PASS raid_history_consent_transfer")
end

function cases.raid_history_sequence_zero_consent_transfer()
	local network = newHistoricalPeerNetwork()
	local leader = installHistoricalPeer(network, "Leader", true)
	local member = installHistoricalPeer(network, "Member", false)
	local sourceRecord = assert(leader.store:GetRecord(leader.sourceUid))
	sourceRecord.sequence = 0
	sourceRecord.checkpointSequence = 0
	sourceRecord.events = {}

	local offered, offerId = leader.syncer:OfferHistoricalRaid(leader.sourceUid, "Member")
	assertTrue(offered, "leader did not offer sequence-zero completed history")
	assertEqual(
		0,
		network.messages[#network.messages].envelope.body.sequence,
		"real OFFER did not preserve sequence zero"
	)
	local accepted, acceptReason = member.syncer:AcceptHistoricalOffer("Leader-TestRealm", offerId)
	assertTrue(accepted, "member did not accept sequence-zero history: " .. tostring(acceptReason))

	local snapshotEnvelope
	for i = 1, #network.messages do
		if network.messages[i].envelope.kind == "SNAP_DATA" then
			snapshotEnvelope = network.messages[i].envelope
			break
		end
	end
	assertTrue(snapshotEnvelope ~= nil, "accepted sequence-zero offer sent no SNAP_DATA")
	assertEqual(0, snapshotEnvelope.body.sequence, "real SNAP_DATA did not preserve sequence zero")
	assertEqual(1, #member.archive.order, "sequence-zero history did not import exactly once")
	local imported, _, importedRecord = member.store:GetStateByIndex(1)
	assertTrue(imported ~= nil, "sequence-zero history is not visible by archive index")
	assertEqual(0, importedRecord.sequence, "imported record sequence differs")
	assertEqual("complete", importedRecord.status, "imported record status differs")
	assertEqual(0, #importedRecord.events, "imported sequence-zero record gained a ledger")
	assertEqual(
		true,
		member.addon.Database.GetRaidValidator():ValidateRecord(importedRecord),
		"sequence-zero completed record failed validation"
	)
	local invalidActive = deepCopy(importedRecord)
	invalidActive.status = "active"
	invalidActive.sourceRaidUid = nil
	invalidActive.conflictOfRaidUid = nil
	invalidActive.state.endTime = nil
	invalidActive.digest = assert(member.addon.DB.RaidEvents.DigestState(invalidActive.state))
	local activeValid, activeReason = member.addon.Database.GetRaidValidator():ValidateRecord(invalidActive)
	assertEqual(nil, activeValid, "sequence-zero active record passed validation")
	assertEqual("INVALID_RECORD_POSITION", activeReason, "sequence-zero active rejection reason differs")
	local invalidLedger = deepCopy(importedRecord)
	invalidLedger.events = { {} }
	local ledgerValid, ledgerReason = member.addon.Database.GetRaidValidator():ValidateRecord(invalidLedger)
	assertEqual(nil, ledgerValid, "sequence-zero completed record with a ledger passed validation")
	assertEqual("INVALID_COMPLETE_LEDGER", ledgerReason, "sequence-zero ledger rejection reason differs")
	assertEqual(
		"Icecrown Citadel",
		assert(member.addon.DB.RaidQueries:GetRaidSummary(imported)).zone,
		"sequence-zero import is not visible in Loot History queries"
	)
	print("PASS raid_history_sequence_zero_consent_transfer")
end

function cases.raid_history_consent_rejections(addon)
	local fixture = installHistoricalConsentFixture(addon)
	local pristine = deepCopy(fixture.store:EnsureArchive())
	assert(fixture:Offer("decline-offer"))
	assertTrue(fixture.syncer:DeclineHistoricalOffer("Leader-TestRealm", "decline-offer"))
	assertEqual(
		"DECLINED",
		assert(latestQueuedEnvelope(fixture, "RESULT")).body.outcome,
		"decline did not send a terminal result"
	)
	assertTrue(deepEqual(pristine, fixture.store:EnsureArchive()), "decline mutated history")

	assert(fixture:Offer("boundary-expired-offer"))
	local queuedBeforeBoundaryAccept = #fixture.queued
	fixture.now = fixture.now + 30
	assertEqual(
		false,
		fixture.syncer:AcceptHistoricalOffer("Leader-TestRealm", "boundary-expired-offer"),
		"offer was accepted exactly at its 30-second expiry"
	)
	assertEqual(queuedBeforeBoundaryAccept, #fixture.queued, "expired boundary acceptance queued a snapshot request")
	assertTrue(deepEqual(pristine, fixture.store:EnsureArchive()), "boundary-expired offer mutated history")

	assert(fixture:Offer("expired-offer"))
	fixture.now = fixture.now + 31
	assertEqual(
		false,
		fixture.syncer:AcceptHistoricalOffer("Leader-TestRealm", "expired-offer"),
		"expired offer was accepted"
	)
	assertTrue(deepEqual(pristine, fixture.store:EnsureArchive()), "expired offer mutated history")

	assert(fixture:Offer("left-group-offer"))
	fixture.leaderInGroup = false
	assertEqual(
		false,
		fixture.syncer:AcceptHistoricalOffer("Leader-TestRealm", "left-group-offer"),
		"offer from a departed group member was accepted"
	)
	assertTrue(deepEqual(pristine, fixture.store:EnsureArchive()), "departed sender mutated history")
	fixture.leaderInGroup = true

	assert(fixture:Offer("partial-offer"))
	local request = fixture:Accept("partial-offer")
	local partCount = fixture:Transfer(request, fixture.snapshot, 1)
	assertTrue(partCount > 1, "partial-transfer case did not create multiple chunks")
	assertTrue(deepEqual(pristine, fixture.store:EnsureArchive()), "partial transfer mutated history")
	assert(fixture:Offer("parallel-offer"))
	assertEqual(
		false,
		fixture.syncer:AcceptHistoricalOffer("Leader-TestRealm", "parallel-offer"),
		"second historical transfer replaced the bounded in-flight transfer"
	)
	assertTrue(deepEqual(pristine, fixture.store:EnsureArchive()), "parallel transfer rejection mutated history")
	fixture.now = fixture.now + 64
	fixture.syncer:GetStatus()
	assertTrue(fixture.syncer._historyTransfer ~= nil, "accepted transfer expired before its 65-second budget")
	fixture.now = fixture.now + 2
	fixture.syncer:GetStatus()
	assertEqual(nil, fixture.syncer._historyTransfer, "stale accepted transfer survived its cleanup budget")
	print("PASS raid_history_consent_rejections")
end

function cases.rma_quick_bar_config_panel_routes_settings(addon)
	local fixture = {
		orientation = "vertical",
		shown = { ML = true, GL = true, SR = true, HIS = true, RW = true },
		directQuickBarOptionWrites = 0,
	}

	local function makeWidget(name)
		local widget = { name = name, shown = false }
		function widget:GetName() return self.name end
		function widget:SetText(value) self.text = value end
		function widget:SetChecked(value) self.checked = value end
		function widget:GetChecked() return self.checked end
		function widget:SetMinMaxValues() end
		function widget:SetValueStep() end
		function widget:SetValue(value) self.value = value end
		function widget:GetValue() return self.value end
		function widget:Enable() self.enabled = true end
		function widget:Disable() self.enabled = false end
		function widget:SetTextColor() end
		function widget:SetScript(kind, callback) self[kind] = callback end
		function widget:HookScript(kind, callback) self[kind] = callback end
		function widget:Show()
			self.shown = true
			if self.OnShow then self.OnShow(self) end
		end
		function widget:Click(checked)
			self.checked = checked
			if self.OnClick then self.OnClick(self) end
		end
		return widget
	end

	local refs = {
		OrientationDropDown = makeWidget("RMAInterfaceOptionsQuickBarPanelScrollChildOrientationDropDown"),
		ShowML = makeWidget("RMAInterfaceOptionsQuickBarPanelScrollChildShowML"),
		ShowGL = makeWidget("RMAInterfaceOptionsQuickBarPanelScrollChildShowGL"),
		ShowSR = makeWidget("RMAInterfaceOptionsQuickBarPanelScrollChildShowSR"),
		ShowHIS = makeWidget("RMAInterfaceOptionsQuickBarPanelScrollChildShowHIS"),
		ShowRW = makeWidget("RMAInterfaceOptionsQuickBarPanelScrollChildShowRW"),
	}
	local genericRefs = {}
	local function getGenericRef(suffix)
		if not genericRefs[suffix] then genericRefs[suffix] = makeWidget("Generic" .. tostring(suffix)) end
		return genericRefs[suffix]
	end
	local quickBarPanel = makeWidget("RMAInterfaceOptionsQuickBarPanel")
	local quickBarContent = makeWidget("RMAInterfaceOptionsQuickBarPanelScrollChild")
	_G.RMAInterfaceOptionsQuickBarPanel = quickBarPanel
	_G.RMAInterfaceOptionsQuickBarPanelScrollChild = quickBarContent
	for _, frameName in ipairs({
		"RMAInterfaceOptionsPanel", "RMAInterfaceOptionsMasterLootPanel", "RMAInterfaceOptionsLootHistoryPanel",
		"RMAInterfaceOptionsLFMSpamPanel", "RMAInterfaceOptionsRaidWarningPanel", "RMAInterfaceOptionsHelpPanel",
	}) do
		_G[frameName] = makeWidget(frameName)
	end
	_G.RMAInterfaceOptionsMasterLootPanelScrollChild = makeWidget("RMAInterfaceOptionsMasterLootPanelScrollChild")
	_G.RMAInterfaceOptionsLootHistoryPanelScrollChild = makeWidget("RMAInterfaceOptionsLootHistoryPanelScrollChild")
	_G.RMAInterfaceOptionsLFMSpamPanelScrollChild = makeWidget("RMAInterfaceOptionsLFMSpamPanelScrollChild")
	_G.RMAInterfaceOptionsRaidWarningPanelScrollChild = makeWidget("RMAInterfaceOptionsRaidWarningPanelScrollChild")
	_G.RMAInterfaceOptionsHelpPanelScrollChild = makeWidget("RMAInterfaceOptionsHelpPanelScrollChild")

	addon.L = setmetatable({
		StrConfigPanelTitle = "Raid Management Addon",
		StrConfigPanelQuickBar = "QuickBar",
		StrConfigQuickBarHorizontal = "Horizontal",
		StrConfigQuickBarVertical = "Vertical",
	}, { __index = function() return "" end })
	addon.EntryPoints = { Debug = { GetHelpText = function() return "" end } }
	addon.Options = {
		RegisterNamespace = function() return {} end,
		GetByKey = function() return nil end,
		Set = function(_, key)
			if string.find(tostring(key), "quickBar", 1, true) then fixture.directQuickBarOptionWrites = fixture.directQuickBarOptionWrites + 1 end
		end,
		ResetAllDefaults = function() end,
		SetDebugEnabled = function() end,
		IsDebugEnabled = function() return false end,
		NormalizeLoggerLootQualityThreshold = function(value) return value or 0 end,
	}
	addon.Diag = { D = { LogSyncConfigAction = "%s" } }
	addon.Events = { Internal = { OptionsLoaded = "OPTIONS" }, BuildConfigOptionChangedName = function() return nil end }
	local callbacks = {}
	addon.Bus = { RegisterCallback = function(eventName, callback) callbacks[eventName] = callback end, TriggerEvent = function() end }
	addon.Strings = { TrimText = function(value) return value end }
	addon.Controllers = { Spammer = {}, Warnings = {} }
	addon.Widgets = {
		QuickBar = {
			GetOrientation = function() return fixture.orientation end,
			SetOrientation = function(_, value) fixture.requestedOrientation = value; fixture.orientation = value end,
			IsButtonShown = function(_, key) return fixture.shown[key] end,
			SetButtonShown = function(_, key, shown) fixture.buttonKey = key; fixture.buttonShown = shown; fixture.shown[key] = shown end,
		},
	}
	addon.Services = { Spammer = { Draft = {} }, Warnings = { Store = {} }, Logger = { Actions = {} } }
	addon.UI = {
		ModuleState = { Ensure = function() return {} end },
		Frames = {
			MakeModuleFrameGetter = function() return function() return nil end end,
			GetRef = function(frameOrName, suffix)
				if frameOrName == quickBarContent or frameOrName == "RMAInterfaceOptionsQuickBarPanelScrollChild" then return refs[suffix] end
				return getGenericRef(suffix)
			end,
			SetScriptSafely = function(widget, kind, callback) if widget then widget:SetScript(kind, callback) end end,
			HookScriptSafely = function(widget, kind, callback) if widget then widget:HookScript(kind, callback) end end,
			SetFrameTitle = function() end,
			BindModuleFrame = function(_, frame) return frame and frame:GetName() end,
		},
		Scaffold = { DefineModule = function() end },
		Layout = {
			ApplyRows = function() end,
			CheckRow = function() return {} end, DropDownRow = function() return {} end, TextRow = function() return {} end,
			EditRow = function() return {} end, SliderRow = function() return {} end, CommandRow = function() return {} end,
			EditCommandRow = function() return {} end, ButtonRow = function() return {} end,
		},
		Popups = { ShowConfirm = function() end },
	}
	_G.SETTINGS = "Settings"
	_G.HIGHLIGHT_FONT_COLOR = { r = 1, g = 1, b = 1 }
	_G.NORMAL_FONT_COLOR = { r = 1, g = 1, b = 1 }
	_G.UIDROPDOWNMENU_OPEN_MENU = "OPEN"
	_G.UIDROPDOWNMENU_MENU_LEVEL = 1
	_G.UIDropDownMenu_Initialize = function(dropDown, initializer) dropDown.initializer = initializer; initializer() end
	_G.UIDropDownMenu_CreateInfo = function() return {} end
	_G.UIDropDownMenu_AddButton = function(info) refs.OrientationDropDown.options = refs.OrientationDropDown.options or {}; table.insert(refs.OrientationDropDown.options, info) end
	_G.UIDropDownMenu_SetWidth = function() end
	_G.UIDropDownMenu_SetButtonWidth = function() end
	_G.UIDropDownMenu_SetText = function(_, value) fixture.orientationSelection = value == "Vertical" and "vertical" or "horizontal" end
	_G.UIDropDownMenu_SetSelectedValue = function(_, value) fixture.orientationSelection = value end
	_G.UIDropDownMenu_EnableDropDown = function() end
	_G.UIDropDownMenu_DisableDropDown = function() end
	_G.CloseDropDownMenus = function() end
	_G.InterfaceOptions_AddCategory = function() end

	function fixture.selectOrientation(value)
		for i = 1, #refs.OrientationDropDown.options do
			local info = refs.OrientationDropDown.options[i]
			if info.value == value then return info.func(nil, info.arg1, info.arg2) end
		end
		fail("orientation option missing: " .. tostring(value))
	end

	loadAddonFile(addon, "Raid Management Addon/Controllers/Config.lua")
	assert(callbacks.OPTIONS)()
	assertEqual("QuickBar", quickBarPanel.name, "QuickBar panel title differs")
	assertEqual("Raid Management Addon", quickBarPanel.parent, "QuickBar panel parent differs")
	quickBarPanel:Show()
	assertEqual("vertical", fixture.orientationSelection, "orientation refresh differs")
	refs.ShowML:Click(false)
	assertEqual("ML", fixture.buttonKey, "ML config key differs")
	assertEqual(false, fixture.buttonShown, "ML config value differs")
	fixture.selectOrientation("horizontal")
	assertEqual("horizontal", fixture.requestedOrientation, "orientation request differs")
	assertEqual(0, fixture.directQuickBarOptionWrites, "Config must not write QuickBar options directly")
	print("PASS rma_quick_bar_config_panel_routes_settings")
end
