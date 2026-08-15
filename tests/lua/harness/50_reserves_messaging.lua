function cases.reserves_bulk_edits_are_atomic(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	local synced = {
		alpha = {
			playerNameDisplay = "Alpha",
			reserves = {
				{ rawID = 100, itemName = "Item", quantity = 2, plus = 3 },
				{ rawID = 200, itemName = "Other", quantity = 1, plus = 0 },
			},
		},
	}
	assertTrue(reserves:SetSyncedData(synced, { source = "Leader", checksum = "fixture", mode = "multi" }))
	assertEqual(true, reserves:HasItemReserves(100), "synced baseline must build the item index")
	assertEqual(true, reserves:HasItemReserves(200), "synced baseline must index every reserve item")
	local serializationName = table.concat({ "Build", "Canonical", "Serialization" })
	assertEqual(
		nil,
		reserves[serializationName],
		"canonical serialization must remain a private reserve implementation detail"
	)
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
	assertTrue(
		deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
		"failed detached build must preserve runtime values"
	)
	assertEqual(
		2,
		reserves:GetReserveCountForItem(100, "Alpha"),
		"derived reserve lookup must match the preserved state"
	)
	assertEqual(true, reserves:HasItemReserves(100), "failed detached build must preserve the published item index")
	assertEqual(true, reserves:GetSyncMetadata().runtime, "detached index failure must retain synced cache ownership")
	assertEqual(savesBefore, fixture.saveCount or 0, "failed detached build must not save")
	assertEqual(eventsBefore, #fixture.events, "failed detached build must not publish")

	for _, malformed in ipairs({
		{
			[1] = { kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
			[3] = { kind = "plus", playerName = "Alpha", itemId = 200, value = 1 },
		},
		{ alpha = { kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 } },
		{ { kind = "quantity", playerName = "Alpha", itemId = "100", value = 4 } },
		{ { kind = "quantity", playerName = "Alpha", itemId = 100, value = 4, extra = true } },
	}) do
		ok, reason = reserves:ApplyBatch(malformed)
		assertEqual(nil, ok, "malformed batch must fail")
		assertEqual("invalid_input", reason, "malformed batch reason differs")
	end
	local oversized = {}
	for i = 1, 501 do
		oversized[i] = { kind = "quantity", playerName = "Alpha", itemId = 100, value = i + 2 }
	end
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
	assertEqual(
		2,
		reserves:GetPlayerReserveEntries("Alpha")[1].quantity,
		"reverted quantity must retain original value"
	)
	assertEqual(5, reserves:GetPlayerReserveEntries("Alpha")[2].plus, "plus edit missing")
	assertEqual(true, reserves:HasItemReserves(200), "successful batch must publish the detached item index")
	assertEqual(false, reserves:GetSyncMetadata().runtime, "successful batch must promote synced cache once")
	print("PASS reserves_bulk_edits_are_atomic")
end

function cases.reserves_single_edits_rollback_exact_state(addon)
	local operations = {
		{
			name = "quantity",
			call = function(reserves)
				return reserves:SetPlayerReserveQuantity("Alpha", 100, 4)
			end,
		},
		{
			name = "plus",
			call = function(reserves)
				return reserves:SetPlayerReservePlus("Alpha", 100, 7)
			end,
		},
		{
			name = "remove",
			call = function(reserves)
				return reserves:RemovePlayerReserve("Alpha", 100)
			end,
		},
	}
	for _, operation in ipairs(operations) do
		for _, fault in ipairs({ "replace", "index" }) do
			local reserves, fixture = installRealReservesMutationFixture(addon)
			local player = {
				playerNameDisplay = "Alpha",
				reserves = {
					{ rawID = 100, itemName = "Item 100", quantity = 1, plus = 0 },
				},
			}
			assertTrue(
				reserves:SetSyncedData({ alpha = player }, { source = "Leader", checksum = "fixture", mode = "multi" }),
				"synced baseline must load"
			)
			local savedBefore = deepCopy(_G.RMA_Reserves)
			local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
			local eventsBefore, savesBefore = #fixture.events, fixture.saveCount or 0
			if fault == "replace" then
				fixture.failReplace = true
			else
				fixture.failStage = "index"
			end
			local invoked, changed, reason = pcall(operation.call, reserves)
			fixture.failReplace, fixture.failStage = nil, nil
			assertEqual(true, invoked, operation.name .. " must contain " .. fault .. " fault")
			assertTrue(not changed, operation.name .. " must fail on " .. fault .. " fault")
			assertEqual("publish_failed", reason, operation.name .. " fault reason differs")
			assertTrue(
				deepEqual(savedBefore, _G.RMA_Reserves),
				operation.name .. " must preserve SavedVariables values"
			)
			assertTrue(
				deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
				operation.name .. " must preserve runtime values"
			)
			assertEqual(
				1,
				reserves:GetReserveCountForItem(100, "Alpha"),
				operation.name .. " derived lookup must match the preserved state"
			)
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
		BtnSave = "Save",
		BtnCancel = "Cancel",
		BtnEdit = "Edit",
		ErrReserveEditRow = "Row %d: %s",
		ErrReserveEditMissingItem = "missing item",
		ErrReserveEditFailed = "failed",
		StrConfirmApplyReserveEdits = "Apply %d?",
	}, {
		__index = function(_, key)
			return key
		end,
	})
	addon.Diag = { D = setmetatable({}, {
		__index = function()
			return "%s"
		end,
	}) }
	addon.C = { RESERVES_QUERY_COOLDOWN_SECONDS = 2, RESERVES_ITEM_FALLBACK_ICON = "fallback" }
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
		Get = function()
			return nil
		end,
	}
	addon.Events.Internal = { ReservesDataChanged = "ReservesDataChanged" }
	addon.Bus.RegisterCallback = noop
	addon.Colors = {
		GetClassColor = function()
			return 1, 1, 1
		end,
	}
	addon.Services.Chat = { Announce = noop }
	addon.Services.Raid = {
		GetPlayerClass = function()
			return nil
		end,
	}
	addon.Services.Reserves = {
		HasData = function()
			return true
		end,
		IsPlusSystem = function()
			return false
		end,
		HasPendingItem = function()
			return false
		end,
		RemovePlayerReserve = noop,
		ClearSavedReserves = noop,
		GetDisplayList = function()
			return {}
		end,
		GetImportMode = function()
			return "multi"
		end,
		ParseImport = noop,
		RequestApplyImport = noop,
		SetImportMode = noop,
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
			MakeModuleFrameGetter = function()
				return function()
					return nil
				end
			end,
			SetScriptSafely = function(widget, name, callback)
				widget[name] = callback
			end,
			SetFrameTitle = noop,
			BindModuleFrame = noop,
		},
		Scaffold = {
			DefineModule = function(config)
				configs[#configs + 1] = config
				config.module.RequestRefresh = function()
					refreshCount = refreshCount + 1
				end
			end,
		},
		Popups = {
			Define = noop,
			DefineConfirm = noop,
			IsDefined = function()
				return false
			end,
			Show = function()
				return false
			end,
			ShowConfirm = function(_, _, onAccept)
				if deferConfirmation then
					deferredAccept = onAccept
					deferredAccepts[#deferredAccepts + 1] = onAccept
				else
					onAccept()
				end
				return true
			end,
		},
		Primitives = { SetEnabled = noop },
		EditBoxes = {},
		Tooltips = { Hide = noop, ShowItem = noop, Bind = noop },
		ModuleState = {
			Ensure = function(module)
				local state = moduleStates[module]
				if not state then
					state = { FrameName = "RMAReserveListFrame" }
					moduleStates[module] = state
				end
				return state
			end,
		},
	}
	_G.GetTime = function()
		return 0
	end
	_G.GetNumRaidMembers = function()
		return 0
	end
	_G.UnitName = function()
		return "Tester"
	end
	_G.RMAReserveListFrameSoftResStatusText = {
		SetText = function(self, value)
			self.text = value
		end,
		SetTextColor = function(self, r, g, b)
			self.color = { r, g, b }
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Widgets/ReservesUI.lua")
	local editButton = {}
	configs[1].bind(nil, nil, { editButton = editButton })
	assertTrue(type(editButton.OnClick) == "function", "reserve edit handler missing")

	local collect
	for i = 1, 20 do
		local name, value = debug.getupvalue(editButton.OnClick, i)
		if not name then
			break
		end
		if name == "collectVisibleReserveEdits" then
			collect = value
			break
		end
	end
	assertTrue(type(collect) == "function", "reserve edit collector upvalue missing")
	local rows
	for i = 1, 20 do
		local name, value = debug.getupvalue(collect, i)
		if not name then
			break
		end
		if name == "reserveItemRows" then
			rows = value
			break
		end
	end
	assertTrue(type(rows) == "table", "reserve row storage upvalue missing")
	local editBox = {
		_RMAReserveEditBase = "2",
		text = "4",
		GetText = function(self)
			return self.text
		end,
		SetText = function(self, value)
			self.text = value
		end,
		SetTextColor = function(self, r, g, b)
			self.color = { r, g, b }
		end,
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
		_RMAReserveEditBase = "8",
		text = "9",
		GetText = function(self)
			return self.text
		end,
		SetTextColor = function(self, r, g, b)
			self.color = { r, g, b }
		end,
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
	local parsed = {
		mode = "multi",
		reservesData = {
			alpha = reserveImportPlayer("Alpha", 100),
			beta = reserveImportPlayer("Beta", 200),
		},
	}
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
	local first = reserves:RequestApplyImport(
		{
			reservesData = {
				alpha = reserveImportPlayer("Alpha", 100),
				beta = reserveImportPlayer("Beta", 200),
			},
		},
		nil,
		function(...)
			firstResults[#firstResults + 1] = { ... }
		end,
		{ chunkSize = 1, silentInfo = true }
	)
	local staleTimerIndex = #fixture.timers
	local second = reserves:RequestApplyImport(
		{
			reservesData = {
				gamma = reserveImportPlayer("Gamma", 300),
				delta = reserveImportPlayer("Delta", 400),
			},
		},
		nil,
		function(...)
			secondResults[#secondResults + 1] = { ... }
		end,
		{ chunkSize = 1, silentInfo = true }
	)
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
	assertTrue(
		reserves:ApplyImport({ reservesData = { base = reserveImportPlayer("Base", 50) } }, nil, { silentInfo = true }),
		"baseline import must succeed"
	)
	local savedBefore = deepCopy(_G.RMA_Reserves)
	local eventsBefore = #fixture.events
	fixture.failReplace = true
	local failed = {}
	reserves:RequestApplyImport({ reservesData = { alpha = reserveImportPlayer("Alpha", 100) } }, nil, function(...)
		failed[#failed + 1] = { ... }
	end, { chunkSize = 1, silentInfo = true })
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
	reserves:RequestApplyImport(
		{ reservesData = {
			old = reserveImportPlayer("Old", 200),
			extra = reserveImportPlayer("Extra", 201),
		} },
		nil,
		function(ok, result)
			if not ok and result == "cancelled" then
				reserves:RequestApplyImport(
					{ reservesData = { newest = reserveImportPlayer("Newest", 300) } },
					nil,
					function(...)
						nestedResults[#nestedResults + 1] = { ... }
					end,
					{ chunkSize = 1, silentInfo = true }
				)
			end
		end,
		{ chunkSize = 1, silentInfo = true }
	)
	reserves:RequestApplyImport(
		{ reservesData = { outer = reserveImportPlayer("Outer", 400) } },
		nil,
		function() end,
		{ chunkSize = 1, silentInfo = true }
	)
	fixture:RunTimer(#fixture.timers)
	assertEqual(1, #nestedResults, "reentrant replacement must remain the active import")
	assertEqual(true, nestedResults[1][1], "reentrant replacement must complete")
	assertEqual(300, reserves:GetPlayerReserveEntries("Newest")[1].rawID, "reentrant callback import must win")
	assertEqual(0, #reserves:GetPlayerReserveEntries("Outer"), "outer replacement must not clobber reentrant import")
	print("PASS reserves_async_import_failure_rolls_back_and_callbacks_are_reentrant")
end

function cases.reserves_async_import_rejects_noncanonical_and_sparse_sources(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(
		reserves:ApplyImport({ reservesData = { base = reserveImportPlayer("Base", 50) } }, nil, { silentInfo = true }),
		"baseline import must succeed"
	)
	local savedBefore = deepCopy(_G.RMA_Reserves)
	local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
	local malformed = {
		{
			reservesData = {
				alpha = {
					playerNameDisplay = "Alpha",
					reserves = {
						[1] = { rawID = 100, quantity = 1, plus = 0 },
						[3] = { rawID = 300, quantity = 1, plus = 0 },
					},
				},
			},
		},
		{
			reservesData = {
				alpha = {
					playerNameDisplay = "Alpha",
					reserves = {
						{ rawID = 100, quantity = 1, plus = 0, source = { mutable = true } },
					},
				},
			},
		},
		{
			reservesData = {
				alpha = {
					playerNameDisplay = "Alpha",
					reserves = {
						{ rawID = 100, quantity = 1, plus = 0, unknown = {} },
					},
				},
			},
		},
	}
	for i = 1, #malformed do
		local results = {}
		reserves:RequestApplyImport(malformed[i], nil, function(...)
			results[#results + 1] = { ... }
		end, { chunkSize = 1, silentInfo = true })
		assertEqual(1, #results, "malformed import callback must be terminal at row " .. i)
		assertEqual(false, results[1][1], "malformed import must fail at row " .. i)
		assertEqual("failed", results[1][2], "malformed import must use stable result at row " .. i)
		assertEqual("INVALID_IMPORT_DATA", results[1][3], "malformed reason differs at row " .. i)
	end
	assertEqual(0, #fixture.timers, "malformed imports must not schedule work")
	assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "malformed imports must preserve values")
	assertTrue(
		deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
		"malformed imports must preserve runtime values"
	)
	assertEqual(
		1,
		reserves:GetReserveCountForItem(50, "Base"),
		"malformed imports must preserve derived reserve lookup"
	)
	print("PASS reserves_async_import_rejects_noncanonical_and_sparse_sources")
end

function cases.reserves_async_import_scheduler_failures_are_terminal(addon)
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(
		reserves:ApplyImport({ reservesData = { base = reserveImportPlayer("Base", 50) } }, nil, { silentInfo = true }),
		"baseline import must succeed"
	)
	local savedBefore = deepCopy(_G.RMA_Reserves)
	for _, failure in ipairs({ "throw", "nil" }) do
		fixture.scheduleFailures = { failure }
		local results = {}
		reserves:RequestApplyImport({ reservesData = { alpha = reserveImportPlayer("Alpha", 100) } }, nil, function(...)
			results[#results + 1] = { ... }
		end, { chunkSize = 1, silentInfo = true })
		assertEqual(1, #results, "initial scheduler failure must callback once for " .. failure)
		assertEqual(false, results[1][1], "initial scheduler failure must reject for " .. failure)
		assertEqual("failed", results[1][2], "initial scheduler result differs for " .. failure)
		assertEqual("SCHEDULE_FAILED", results[1][3], "initial scheduler reason differs for " .. failure)
	end
	for _, failure in ipairs({ "throw", "nil" }) do
		fixture.scheduleFailures = { false, failure }
		local results = {}
		reserves:RequestApplyImport(
			{
				reservesData = {
					alpha = reserveImportPlayer("Alpha", 100),
					beta = reserveImportPlayer("Beta", 200),
				},
			},
			nil,
			function(...)
				results[#results + 1] = { ... }
			end,
			{ chunkSize = 1, silentInfo = true }
		)
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
	assertTrue(
		reserves:ApplyImport(
			{ mode = "multi", reservesData = { base = reserveImportPlayer("Base", 50) } },
			nil,
			{ silentInfo = true }
		),
		"baseline import must succeed"
	)
	for _, stage in ipairs({ "index" }) do
		local savedRoot = _G.RMA_Reserves
		local savedBefore = deepCopy(savedRoot)
		local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
		local eventsBefore = #fixture.events
		fixture.failStage = stage
		local results = {}
		reserves:RequestApplyImport(
			{ mode = "plus", reservesData = { alpha = reserveImportPlayer("Alpha", 100) } },
			nil,
			function(...)
				results[#results + 1] = { ... }
			end,
			{ chunkSize = 1, silentInfo = true }
		)
		fixture:RunTimer(#fixture.timers)
		assertEqual(1, #results, "publish fault callback must run once for " .. stage)
		assertEqual(false, results[1][1], "publish fault must fail for " .. stage)
		assertEqual("failed", results[1][2], "publish fault result differs for " .. stage)
		assertTrue(
			deepEqual(savedBefore, _G.RMA_Reserves),
			"publish fault must preserve SavedVariables values for " .. stage
		)
		assertTrue(
			deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
			"publish fault must preserve runtime values for " .. stage
		)
		assertEqual(
			1,
			reserves:GetReserveCountForItem(50, "Base"),
			"publish fault derived lookup must match preserved state for " .. stage
		)
		assertEqual("multi", reserves:GetImportMode(), "publish fault must restore mode for " .. stage)
		assertEqual(eventsBefore, #fixture.events, "publish fault must emit no event for " .. stage)
	end
	for _, stage in ipairs({ "debug", "info", "event" }) do
		fixture.failStage = stage
		local results = {}
		reserves:RequestApplyImport({ reservesData = { ok = reserveImportPlayer("Ok", 500) } }, nil, function(...)
			results[#results + 1] = { ... }
		end, { chunkSize = 1, silentInfo = stage ~= "info" })
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
		alpha = {
			playerNameDisplay = "Alpha",
			reserves = {
				{ rawID = 100, itemName = "Indexed", quantity = 2, plus = 1 },
				{ rawID = 200, itemName = "Fallback", quantity = 3, plus = 0 },
			},
		},
		raider = {
			playerNameDisplay = "Raider",
			reserves = {
				{ rawID = 100, itemName = "Exact", quantity = 5, plus = 0 },
			},
		},
	}
	fixture.skipPlayerIndexItem = 200
	assertTrue(
		reserves:SetSyncedData(data, { source = "Leader", checksum = "lookup", mode = "multi" }),
		"lookup fixture import failed"
	)
	assertTrue(reserves:SetNameAlias("Alpha", "Raider"), "lookup fixture alias failed")
	assertEqual(
		5,
		reserves:GetReserveCountForItem(100, "Raider"),
		"exact reserve identity must take precedence over an alias target"
	)
	assertTrue(reserves:SetNameAlias("Alpha", "AliasRaid"), "lookup alias replacement failed")
	assertEqual(
		2,
		reserves:GetReserveCountForItem(100, "AliasRaid"),
		"raid-name alias must resolve to the reserve owner"
	)
	assertEqual(2, reserves:GetReserveCountForItem(100, "Alpha"), "indexed lookup quantity differs")
	assertEqual(3, reserves:GetReserveCountForItem(200, "Alpha"), "fallback traversal quantity differs")

	fixture.lookupProbe = { itemId = 100, playerName = "Alpha" }
	assertTrue(
		reserves:ApplyBatch({
			{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
		}),
		"detached publication mutation failed"
	)
	assertEqual(4, fixture.detachedLookupQuantity, "detached publication lookup did not observe candidate state")
	assertEqual(
		4,
		reserves:GetReserveCountForItem(100, "Alpha"),
		"published lookup did not observe committed candidate state"
	)
	print("PASS reserves_lookup_preserves_identity_index_fallback_and_detached_state")
end

function cases.reserves_import_option_notification_is_post_commit(addon)
	do
		local reserves, fixture = installRealReservesMutationFixture(addon)
		assertTrue(
			reserves:SetSyncedData(
				{ base = reserveImportPlayer("Base", 50) },
				{ source = "Leader", checksum = "fixture", mode = "multi" }
			)
		)
		local savedBefore = deepCopy(_G.RMA_Reserves)
		local runtimeBefore = deepCopy(reserves:GetPlayerReserveEntries("Base"))
		local savesBefore, eventsBefore = fixture.saveCount or 0, #fixture.events
		fixture.failReplace = true
		local ok, reason = reserves:ApplyImport(
			{ mode = "plus", reservesData = {
				alpha = reserveImportPlayer("Alpha", 100),
			} },
			nil,
			{ silentInfo = true }
		)
		fixture.failReplace = nil
		assertEqual(false, ok, "reserve replacement failure must reject the import")
		assertEqual("PUBLISH_FAILED", reason, "reserve replacement failure reason differs")
		assertEqual(0, fixture.optionValues.srImportMode, "replacement failure must preserve the stored mode")
		assertEqual("multi", reserves:GetImportMode(), "replacement failure must preserve the local mode")
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "replacement failure must preserve SavedVariables")
		assertTrue(
			deepEqual(runtimeBefore, reserves:GetPlayerReserveEntries("Base")),
			"replacement failure must preserve runtime roots"
		)
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
		fixture.optionObserver = function()
			error("injected OptionChanged observer failure")
		end
		local ok = reserves:ApplyImport(
			{ mode = "plus", reservesData = {
				alpha = reserveImportPlayer("Alpha", 100),
			} },
			nil,
			{ silentInfo = true }
		)
		assertEqual(true, ok, "OptionChanged failure must not invalidate the committed import")
		assertEqual(1, fixture.optionValues.srImportMode, "OptionChanged failure must retain the stored mode")
		assertEqual("plus", reserves:GetImportMode(), "OptionChanged failure must retain the local mode")
		assertEqual(
			100,
			reserves:GetPlayerReserveEntries("Alpha")[1].rawID,
			"OptionChanged failure must retain the published reserve roots"
		)
		assertEqual(true, reserves:HasItemReserves(100), "OptionChanged failure must retain the published index")
		assertEqual(
			false,
			reserves:GetSyncMetadata().runtime,
			"OptionChanged failure must retain local cache ownership"
		)
		assertEqual(savesBefore + 1, fixture.saveCount or 0, "OptionChanged failure must save exactly once")
		assertEqual(eventsBefore + 1, #fixture.events, "OptionChanged failure must publish one data event")
		assertEqual(1, #fixture.diagnostics, "OptionChanged failure must report one contained diagnostic")
	end

	do
		local reserves, fixture = installRealReservesMutationFixture(addon)
		assertTrue(
			reserves:ApplyImport(
				{ mode = "multi", reservesData = {
					base = reserveImportPlayer("Base", 50),
				} },
				nil,
				{ silentInfo = true }
			),
			"reentrant observer baseline import must succeed"
		)
		local observed = {}
		fixture.optionObserver = function()
			observed.mode = reserves:GetImportMode()
			observed.hasNewItem = reserves:HasItemReserves(200)
			observed.hasOldItem = reserves:HasItemReserves(50)
			observed.rawID = reserves:GetPlayerReserveEntries("Bravo")[1].rawID
			observed.runtime = reserves:GetSyncMetadata().runtime
		end
		local ok = reserves:ApplyImport(
			{ mode = "plus", reservesData = {
				bravo = reserveImportPlayer("Bravo", 200),
			} },
			nil,
			{ silentInfo = true }
		)
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
	assertTrue(
		reserves:ApplyImport(
			{ mode = "multi", reservesData = { base = reserveImportPlayer("Base", 50) } },
			nil,
			{ silentInfo = true }
		),
		"baseline import must succeed"
	)
	local savedBefore = deepCopy(_G.RMA_Reserves)
	local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
	local timersBefore, eventsBefore = #fixture.timers, #fixture.events
	local invalid = {}
	local tooManyPlayers = {}
	for i = 1, 1001 do
		tooManyPlayers["player" .. i] = reserveImportPlayer("Player" .. i, i)
	end
	invalid[#invalid + 1] = tooManyPlayers
	local tooManyRows = { alpha = { playerNameDisplay = "Alpha", reserves = {} } }
	for i = 1, 21 do
		tooManyRows.alpha.reserves[i] = { rawID = i, quantity = 1, plus = 0 }
	end
	invalid[#invalid + 1] = tooManyRows
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = string.rep("A", 65), reserves = { { rawID = 1 } } } }
	invalid[#invalid + 1] =
		{ alpha = { playerNameDisplay = "Alpha", reserves = { { rawID = 1, note = string.rep("N", 257) } } } }
	invalid[#invalid + 1] =
		{ alpha = { playerNameDisplay = "Alpha", reserves = { { rawID = 1, quantity = math.huge } } } }
	invalid[#invalid + 1] =
		{ alpha = { playerNameDisplay = "Alpha", reserves = { [1] = { rawID = 1 }, [3] = { rawID = 3 } } } }
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = "Alpha", reserves = { { rawID = 1 }, { rawID = 1 } } } }
	invalid[#invalid + 1] = { [1] = reserveImportPlayer("Alpha", 1) }
	invalid[#invalid + 1] = { alpha = { playerNameDisplay = "Alpha", reserves = {} } }
	invalid[#invalid + 1] = { ["Al" .. string.char(0xc3, 0xa9)] = reserveImportPlayer("Alpha", 1) }
	invalid[#invalid + 1] = { alpha = reserveImportPlayer("Al" .. string.char(0xc3, 0xa9), 1) }
	invalid[#invalid + 1] =
		{ alpha = { playerNameDisplay = "Alpha", reserves = {
			{ rawID = 1, source = "bad\nsource" },
		} } }
	invalid[#invalid + 1] = {
		alpha = {
			playerNameDisplay = "Alpha",
			reserves = {
				{ rawID = 1, itemName = string.char(0xc3, 0xa9) },
			},
		},
	}
	for i = 1, #invalid do
		local ok, reason = reserves:ApplyImport(
			{ mode = "multi", reservesData = invalid[i] },
			nil,
			{ silentInfo = true }
		)
		assertEqual(false, ok, "sync direct import must reject invalid graph " .. i)
		assertEqual("INVALID_IMPORT_DATA", reason, "sync rejection reason differs at " .. i)
		local callbacks = {}
		local handle = reserves:RequestApplyImport({ mode = "multi", reservesData = invalid[i] }, nil, function(...)
			callbacks[#callbacks + 1] = { ... }
		end, { silentInfo = true })
		assertEqual(true, handle:IsCancelled(), "invalid async request must be terminal at " .. i)
		assertEqual(1, #callbacks, "invalid async callback must run once at " .. i)
		assertEqual(false, callbacks[1][1], "invalid async callback must fail at " .. i)
		assertEqual(#fixture.timers, timersBefore, "invalid async request must allocate no timer at " .. i)
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "invalid import must preserve values at " .. i)
		assertTrue(
			deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
			"invalid import must preserve runtime values at " .. i
		)
		assertEqual(
			1,
			reserves:GetReserveCountForItem(50, "Base"),
			"invalid import derived lookup must match preserved state at " .. i
		)
		assertEqual(eventsBefore, #fixture.events, "invalid import must not publish at " .. i)
	end
	for _, stage in ipairs({ "replace", "index" }) do
		if stage == "replace" then
			fixture.failReplace = true
		else
			fixture.failStage = stage
		end
		local ok, reason = reserves:ApplyImport(
			{ mode = "plus", reservesData = {
				alpha = reserveImportPlayer("Alpha", 100),
			} },
			nil,
			{ silentInfo = true }
		)
		fixture.failReplace, fixture.failStage = nil, nil
		assertEqual(false, ok, "synchronous import must contain " .. stage .. " fault")
		assertEqual("PUBLISH_FAILED", reason, "synchronous publish reason differs for " .. stage)
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "sync fault must preserve values")
		assertTrue(
			deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
			"sync fault must preserve runtime values"
		)
		assertEqual(
			1,
			reserves:GetReserveCountForItem(50, "Base"),
			"sync fault derived lookup must match preserved state"
		)
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
	assertTrue(
		reserves:ApplyImport({ mode = "multi", reservesData = exactGraph }, nil, { silentInfo = true }),
		"exact 1000-player/5000-row bounds must succeed"
	)
	local exactPlayerRows = {}
	for i = 1, 20 do
		exactPlayerRows[i] = { rawID = i, note = string.rep("N", 256) }
	end
	assertTrue(
		reserves:ApplyImport({
			mode = "multi",
			reservesData = {
				[string.rep("k", 64)] = { playerNameDisplay = string.rep("P", 64), reserves = exactPlayerRows },
			},
		}, nil, { silentInfo = true }),
		"exact per-player and string bounds must succeed"
	)
	local successSource = { alpha = reserveImportPlayer("Alpha", 100) }
	assertTrue(
		reserves:ApplyImport({ mode = "multi", reservesData = successSource }, nil, { silentInfo = true }),
		"bounded direct import must succeed"
	)
	successSource.alpha.reserves[1].rawID = 999
	successSource.alpha.reserves[1].note = "caller mutation"
	assertEqual(
		100,
		reserves:GetPlayerReserveEntries("Alpha")[1].rawID,
		"successful direct import must detach caller rows"
	)
	assertEqual(
		nil,
		reserves:GetPlayerReserveEntries("Alpha")[1].note,
		"successful direct import must detach caller strings"
	)
	print("PASS reserves_direct_import_apis_revalidate_bounded_canonical_input")
end

function cases.reserves_add_player_reserve_is_transactional(addon)
	for _, fault in ipairs({ "replace", "index" }) do
		local reserves, fixture = installRealReservesMutationFixture(addon)
		local synced = { alpha = reserveImportPlayer("Alpha", 100) }
		assertTrue(
			reserves:SetSyncedData(synced, { source = "Leader", checksum = "fixture", mode = "multi" }),
			"synced add baseline must load"
		)
		local savedBefore = deepCopy(_G.RMA_Reserves)
		local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
		local eventsBefore = #fixture.events
		if fault == "replace" then
			fixture.failReplace = true
		else
			fixture.failStage = "index"
		end
		local invoked, ok, reason = pcall(reserves.AddPlayerReserve, reserves, "Alpha", 200)
		fixture.failReplace, fixture.failStage = nil, nil
		assertEqual(true, invoked, "add must contain " .. fault .. " fault")
		assertEqual(false, ok, "add must fail on " .. fault .. " fault")
		assertEqual("publish_failed", reason, "add publish reason differs")
		assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "add fault must preserve SavedVariables values")
		assertTrue(
			deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
			"add fault must preserve runtime values"
		)
		assertEqual(
			1,
			reserves:GetReserveCountForItem(100, "Alpha"),
			"add fault derived lookup must match preserved state"
		)
		assertEqual(true, reserves:GetSyncMetadata().runtime, "add fault must preserve synced cache ownership")
		assertEqual(eventsBefore, #fixture.events, "add fault must publish no event")
	end
	local reserves, fixture = installRealReservesMutationFixture(addon)
	assertTrue(
		reserves:SetSyncedData(
			{ alpha = reserveImportPlayer("Alpha", 100) },
			{ source = "Leader", checksum = "fixture", mode = "multi" }
		)
	)
	local eventsBefore = #fixture.events
	local ok, row = reserves:AddPlayerReserve("Alpha", 200)
	assertEqual(true, ok, "valid add must commit")
	assertTrue(
		deepEqual(row, reserves:GetPlayerReserveEntries("Alpha")[2]),
		"successful add must return the committed reserve value"
	)
	assertEqual(
		1,
		reserves:GetReserveCountForItem(200, "Alpha"),
		"successful add derived lookup must match the published candidate"
	)
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
		{
			call = function()
				return reserves:SetPlayerReserveQuantity("Missing", 100, 4)
			end,
			reason = "invalid_player",
		},
		{
			call = function()
				return reserves:SetPlayerReserveQuantity("Alpha", 999, 4)
			end,
			reason = "missing_item",
		},
		{
			call = function()
				return reserves:SetPlayerReserveQuantity("Alpha", 100, 2)
			end,
			reason = "no_change",
		},
		{
			call = function()
				return reserves:SetPlayerReservePlus("Missing", 100, 4)
			end,
			reason = "invalid_player",
		},
		{
			call = function()
				return reserves:SetPlayerReservePlus("Alpha", 999, 4)
			end,
			reason = "missing_item",
		},
		{
			call = function()
				return reserves:SetPlayerReservePlus("Alpha", 100, 3)
			end,
			reason = "no_change",
		},
		{
			call = function()
				return reserves:RemovePlayerReserve("Missing", 100)
			end,
			reason = "invalid_player",
		},
		{
			call = function()
				return reserves:RemovePlayerReserve("Alpha", 999)
			end,
			reason = "missing_item",
		},
	}
	for i = 1, #failures do
		local changed, mutationReason = failures[i].call()
		assertEqual(false, changed, "failed synced mutation must remain false at row " .. i)
		assertEqual(failures[i].reason, mutationReason, "failed synced mutation reason differs at row " .. i)
		reserves:Save("test")
		reserves:Load()
		assertTrue(deepEqual({}, _G.RMA_Reserves), "failed synced mutation must not persist cache at row " .. i)
		assertEqual(
			true,
			reserves:GetSyncMetadata().runtime,
			"failed synced mutation must retain cache ownership at row " .. i
		)
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
	assertEqual(
		"al" .. string.char(0xc3, 0xa9) .. "a-quelthalaseast",
		normalizedIdentity,
		"canonical identity must share the owner contract"
	)
	for _, invalid in ipairs({
		"",
		"Bad--Realm",
		"Bad-Realm-",
		"Bad- Realm",
		"Bad-Realm ",
		"'Bad-Realm",
		"Bad|Name-Realm",
		"Bad\tName-Realm",
		string.char(0xff) .. "Bad-Realm",
	}) do
		assertEqual(
			nil,
			reserves:NormalizeWhisperPlayerIdentity(invalid, "Local Realm"),
			"invalid owner identity must fail closed"
		)
	end

	assertTrue(
		reserves:ApplyImport({ mode = "multi", reservesData = { alpha = player("Alpha") } }, nil, { silentInfo = true }),
		"short-name fixture must import"
	)
	local target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual("Alpha", target, "local qualified sender must reuse the existing short participant")
	assertEqual(nil, reason, "unambiguous short participant must resolve")
	assertTrue(reserves:AddPlayerReserve(target, 2), "resolved local participant must accept the reserve")
	assertEqual(1, reserves:GetCounts(), "resolved local sender must not create a qualified duplicate participant")
	assertEqual(
		2,
		#reserves:GetPlayerReserveEntries("Alpha"),
		"resolved reserve must update the existing short participant"
	)

	assertTrue(
		reserves:ApplyImport({
			mode = "multi",
			reservesData = {
				alpha = player("Alpha"),
				["alpha-otherrealm"] = player("Alpha-otherrealm"),
			},
		}, nil, { silentInfo = true }),
		"ambiguous fixture must import"
	)
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual(nil, target, "short plus cross-realm candidates must fail closed")
	assertEqual("ambiguous_player", reason, "ambiguous reason differs")
	assertTrue(
		reserves:ApplyImport(
			{ mode = "multi", reservesData = {
				["alpha-otherrealm"] = player("Alpha-otherrealm"),
			} },
			nil,
			{ silentInfo = true }
		),
		"cross-only fixture must import"
	)
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual(nil, target, "local sender must not reuse another realm's participant")
	assertEqual("ambiguous_player", reason, "cross-realm collision reason differs")

	assertTrue(
		reserves:ApplyImport({
			mode = "multi",
			reservesData = {
				alpha = player("Alpha"),
				["alpha-localrealm"] = player("Alpha-localrealm"),
				["alpha-otherrealm"] = player("Alpha-otherrealm"),
			},
		}, nil, { silentInfo = true }),
		"qualified fixture must import"
	)
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual("Alpha-localrealm", target, "exact qualified participant must take precedence")
	assertEqual(nil, reason, "exact qualified participant must resolve")
	target = reserves:ResolveWhisperPlayerName("Alpha", "thirdrealm", "localrealm")
	assertEqual("Alpha-thirdrealm", target, "new cross-realm participant must remain qualified")

	assertTrue(
		reserves:ApplyImport({
			mode = "multi",
			reservesData = {
				["alpha-local realm"] = player("Alpha-Local Realm"),
				["bravo-quel'thalas-east"] = player("Bravo-Quel'Thalas-East"),
			},
		}, nil, { silentInfo = true }),
		"punctuated realm fixture must import"
	)
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual("Alpha-Local Realm", target, "normalized local realm must reuse the exact stored display")
	assertEqual(nil, reason, "normalized local exact identity must resolve")
	target, reason = reserves:ResolveWhisperPlayerName("Bravo", "quelthalaseast", "localrealm")
	assertEqual("Bravo-Quel'Thalas-East", target, "internal realm punctuation must reuse exact storage")
	assertEqual(nil, reason, "punctuated remote exact identity must resolve")

	assertTrue(
		reserves:ApplyImport({
			mode = "multi",
			reservesData = {
				["alpha-local realm"] = player("Alpha-Local Realm"),
				["alpha-localrealm"] = player("Alpha-localrealm"),
			},
		}, nil, { silentInfo = true }),
		"normalized collision fixture must import"
	)
	target, reason = reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm")
	assertEqual(nil, target, "stored identities collapsing to one normalized identity must fail closed")
	assertEqual("ambiguous_player", reason, "normalized collision reason differs")

	assertTrue(
		reserves:ApplyImport({ mode = "multi", reservesData = {} }, nil, { silentInfo = true }),
		"empty fixture must import"
	)
	assertEqual(
		"Alpha",
		reserves:ResolveWhisperPlayerName("Alpha", "localrealm", "localrealm"),
		"new local participant must use established short-name storage"
	)
	print("PASS reserves_whisper_storage_identity_resolution_is_owner_bound")
end

local function installRealReservesSyncFixture(addon, localName)
	local reserves = installRealReservesMutationFixture(addon)
	loadAddonFile(addon, "Raid Management Addon/Localization/DiagnoseLog.en.lua")
	addon.L.MsgReservesSyncFailed = "failed:%s"
	addon.L.MsgReservesSyncMeta = "%s %s %s %d %d"
	addon.L.MsgReservesSyncApplied = "applied:%s"
	local infos = {}
	addon.info = function(_, message)
		infos[#infos + 1] = message
	end
	local warnings = {}
	addon.warn = function(_, message)
		warnings[#warnings + 1] = message
	end
	local debugMessages = {}
	addon.hasDebug = nil
	addon.debug = function(_, message)
		debugMessages[#debugMessages + 1] = message
	end
	local sent = {}
	local payload = installPayloadCodec(addon)
	local work = {
		payloadCalls = 0,
		serializeCalls = 0,
		directQueueAttempts = 0,
		batchQueueAttempts = 0,
		emittedPackets = 0,
	}
	local serializePayload = payload.Serialize
	function payload.Serialize(value)
		work.serializeCalls = work.serializeCalls + 1
		return serializePayload(value)
	end
	function payload.PackFields(separator, ...)
		local fields = { ... }
		for i = 1, #fields do
			fields[i] = tostring(fields[i] or "")
		end
		return table.concat(fields, separator)
	end
	function payload.SplitFields(text, separator, destination)
		destination = destination or {}
		for key in pairs(destination) do
			destination[key] = nil
		end
		local from = 1
		while true do
			local at = string.find(text, separator, from, true)
			if not at then
				destination[#destination + 1] = string.sub(text, from)
				break
			end
			destination[#destination + 1] = string.sub(text, from, at - 1)
			from = at + #separator
		end
		return destination
	end
	function payload.EncodeText(value)
		return (tostring(value or ""):gsub(".", function(char)
			return string.format("%02X", string.byte(char))
		end))
	end
	function payload.DecodeText(value)
		if type(value) ~= "string" or (#value % 2) ~= 0 or value:find("[^0-9A-F]") then
			return nil
		end
		return (value:gsub("..", function(pair)
			return string.char(tonumber(pair, 16))
		end))
	end
	local function recordMessage(prefix, target, message, channel, opts)
		local envelope = payload.Deserialize(message)
		work.emittedPackets = work.emittedPackets + 1
		sent[#sent + 1] = {
			prefix = prefix,
			target = target,
			message = message,
			channel = channel,
			priority = opts and opts.priority or "NORMAL",
			queueName = opts and opts.queueName or nil,
			envelope = type(envelope) == "table" and deepCopy(envelope) or nil,
			kind = type(envelope) == "table" and envelope[2] or nil,
			body = type(envelope) == "table" and deepCopy(envelope[5]) or nil,
		}
		return true
	end
	addon.Comms = {
		Payload = payload,
		NormalizeSender = function(value)
			return tostring(value or ""):match("^[^-]+") or ""
		end,
		SendAddonWhisper = function(prefix, target, message)
			work.directQueueAttempts = work.directQueueAttempts + 1
			return recordMessage(prefix, target, message, "WHISPER")
		end,
		QueueAddonMessage = function(prefix, message, channel, target, opts)
			work.directQueueAttempts = work.directQueueAttempts + 1
			return recordMessage(prefix, target, message, channel, opts)
		end,
		QueueAddonMessages = function(prefix, messages, channel, target, opts)
			work.batchQueueAttempts = work.batchQueueAttempts + 1
			for i = 1, #messages do
				recordMessage(prefix, target, messages[i], channel, opts)
			end
			return true
		end,
		SendAddonBatch = function(prefix, messages, target, opts)
			work.batchQueueAttempts = work.batchQueueAttempts + 1
			local channel = target and "WHISPER" or "RAID"
			for i = 1, #messages do
				recordMessage(prefix, target, messages[i], channel, opts)
			end
			return true
		end,
		RegisterPrefixIfAvailable = function() end,
		Sync = function(prefix, message)
			return recordMessage(prefix, nil, message, "RAID")
		end,
	}
	local defaultMembership = true
	local membershipBySender = {}
	local membershipChecks = {}
	addon.Services.Raid = {
		GetPlayerRoleState = function()
			return { isLeader = true }
		end,
		IsGroupMember = function(_, sender)
			membershipChecks[#membershipChecks + 1] = sender
			local allowed = membershipBySender[sender]
			if allowed == nil then
				return defaultMembership
			end
			return allowed
		end,
		IsReservesAuthority = function()
			return true
		end,
	}
	_G.UnitName = function()
		return localName or "Tester"
	end
	local now = 10
	_G.GetTime = function()
		return now
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Reserves/Sync.lua")
	local sync = reserves._Sync
	local getPayload = sync.GetPayload
	function sync:GetPayload()
		work.payloadCalls = work.payloadCalls + 1
		return getPayload(self)
	end
	local forcedLocalDataAvailability
	local isLocalDataAvailable = reserves.IsLocalDataAvailable
	function reserves:IsLocalDataAvailable()
		if forcedLocalDataAvailability ~= nil then
			return forcedLocalDataAvailability
		end
		return isLocalDataAvailable(self)
	end
	return {
		reserves = reserves,
		sync = sync,
		payload = payload,
		sent = sent,
		infos = infos,
		debugMessages = debugMessages,
		work = work,
		resetWork = function()
			work.payloadCalls = 0
			work.serializeCalls = 0
			work.directQueueAttempts = 0
			work.batchQueueAttempts = 0
			work.emittedPackets = 0
		end,
		setNow = function(value)
			now = value
		end,
		setDebug = function(enabled)
			addon.hasDebug = enabled and true or nil
		end,
		setDefaultMembership = function(allowed)
			defaultMembership = allowed == true
		end,
		setMember = function(sender, allowed)
			membershipBySender[sender] = allowed
		end,
		membershipChecks = membershipChecks,
		setLocalDataAvailable = function(available)
			forcedLocalDataAvailability = available
		end,
		warnings = warnings,
		encode = function(kind, requestId, target, body, version)
			return assert(payload.Serialize({ version or 5, kind, requestId or false, target or false, body or {} }))
		end,
	}
end

function cases.reserves_sync_checksums_and_payloads_are_verified(addon)
	local fixture = installRealReservesSyncFixture(addon)
	local first = {
		bravo = {
			playerNameDisplay = "Bravo",
			reserves = {
				{ rawID = 202, quantity = 1, plus = 0, class = "MAGE", spec = "Arcane", note = "b", source = "csv" },
				{ rawID = 201, quantity = 2, plus = 1, class = "MAGE", spec = "Fire", note = "a", source = "chat" },
			},
		},
		alpha = {
			playerNameDisplay = "Alpha",
			reserves = {
				{ rawID = 101, quantity = 1, plus = 0, class = "PRIEST", spec = "Holy", note = "", source = "csv" },
			},
		},
	}
	local reordered = {
		alpha = deepCopy(first.alpha),
		bravo = {
			playerNameDisplay = "Bravo",
			reserves = {
				deepCopy(first.bravo.reserves[2]),
				deepCopy(first.bravo.reserves[1]),
			},
		},
	}
	assertEqual(
		fixture.reserves.BuildCanonicalChecksum(first),
		fixture.reserves.BuildCanonicalChecksum(reordered),
		"equivalent reserve maps and rows need one canonical checksum"
	)

	local function transferTable(data, mode)
		local projection = assert(fixture.reserves.BuildCanonicalProjection(data))
		local transfer = { mode = mode or "multi", players = {} }
		for i = 1, #projection do
			local player = { name = projection[i].name, rows = {} }
			transfer.players[i] = player
			for j = 1, #projection[i].rows do
				local row = projection[i].rows[j]
				player.rows[j] = {
					rawID = row.rawID,
					quantity = row.quantity,
					plus = row.plus,
					class = row.class,
					spec = row.spec,
					note = row.note,
					source = row.source,
				}
			end
		end
		return transfer
	end
	local validTransfer = transferTable(first)
	local checksum = fixture.reserves.BuildCanonicalChecksum(first)
	local setCalls = 0
	local originalSet = fixture.sync.SetSyncedData
	fixture.sync.SetSyncedData = function(self, data, meta)
		setCalls = setCalls + 1
		return originalSet(self, data, meta)
	end
	local function transfer(requestId, announcedChecksum, players, entries, encoded, totalChunks)
		fixture.sync._pendingRequests[requestId] = { stage = "metadata", createdAt = 10 }
		fixture.sync:HandleMessage(
			"RMAResSync",
			fixture.encode("META_ACK", requestId, "Tester", {
				checksum = announcedChecksum,
				mode = "multi",
				players = players,
				entries = entries,
				source = "Leader",
			}),
			"WHISPER",
			"Leader-Realm"
		)
		local chunkSize = 80
		local encodedChunks = math.ceil(#encoded / chunkSize)
		local announcedChunks = totalChunks or encodedChunks
		local deliveredChunks = totalChunks and 1 or encodedChunks
		for index = 1, deliveredChunks do
			fixture.sync:HandleMessage(
				"RMAResSync",
				fixture.encode("DATA_CHUNK", requestId, "Tester", {
					index = index,
					count = announcedChunks,
					chunk = string.sub(encoded, ((index - 1) * chunkSize) + 1, index * chunkSize),
				}),
				"WHISPER",
				"Leader-Realm"
			)
		end
		fixture.sync:HandleMessage(
			"RMAResSync",
			fixture.encode("DATA_DONE", requestId, "Tester", { checksum = announcedChecksum }),
			"WHISPER",
			"Leader-Realm"
		)
	end
	local validEncoded = assert(fixture.payload.Serialize(validTransfer))
	transfer("valid", checksum, 2, 3, validEncoded)
	assertEqual(
		1,
		setCalls,
		"valid verified payload must publish once; warning=" .. tostring(fixture.warnings[#fixture.warnings])
	)
	local validView = fixture.reserves:GetDisplayList()
	local validAlphaEntries = deepCopy(fixture.reserves:GetPlayerReserveEntries("Alpha"))
	local validMeta = deepCopy(fixture.reserves:GetSyncMetadata())

	local corruptTransfer = deepCopy(validTransfer)
	corruptTransfer.players[2].rows[1].rawID = 999
	local malformedTransfer = deepCopy(validTransfer)
	malformedTransfer.players[1].rows[1].source = nil
	local invalid = {
		{
			id = "corrupt",
			checksum = checksum .. "1",
			players = 2,
			entries = 3,
			encoded = assert(fixture.payload.Serialize(corruptTransfer)),
		},
		{
			id = "truncated",
			checksum = checksum .. "2",
			players = 2,
			entries = 3,
			encoded = string.sub(validEncoded, 1, #validEncoded - 1),
		},
		{
			id = "schema",
			checksum = checksum .. "3",
			players = 2,
			entries = 3,
			encoded = assert(fixture.payload.Serialize(malformedTransfer)),
		},
		{ id = "counts", checksum = checksum .. "4", players = 9, entries = 3, encoded = validEncoded },
		{
			id = "missing",
			checksum = checksum .. "5",
			players = 2,
			entries = 3,
			encoded = validEncoded,
			totalChunks = 2,
		},
		{
			id = "mode",
			checksum = checksum .. "6",
			players = 2,
			entries = 3,
			encoded = assert(fixture.payload.Serialize(transferTable(first, "plus"))),
		},
	}
	for i = 1, #invalid do
		transfer(
			invalid[i].id,
			invalid[i].checksum,
			invalid[i].players,
			invalid[i].entries,
			invalid[i].encoded,
			invalid[i].totalChunks
		)
		assertEqual(1, setCalls, "rejected transfer must not reach SetSyncedData at row " .. i)
		assertTrue(
			deepEqual(validView, fixture.reserves:GetDisplayList()),
			"rejected transfer changed active view at row " .. i
		)
		assertTrue(
			deepEqual(validAlphaEntries, fixture.reserves:GetPlayerReserveEntries("Alpha")),
			"rejected transfer changed reserve rows at row " .. i
		)
		assertTrue(
			deepEqual(validMeta, fixture.reserves:GetSyncMetadata()),
			"rejected transfer changed metadata at row " .. i
		)
		if invalid[i].totalChunks then
			assertEqual(
				invalid[i].checksum,
				fixture.sync._pendingRequests[invalid[i].id].doneChecksum,
				"early DONE marker was not retained at row " .. i
			)
			assertTrue(
				fixture.sync._incoming["Leader:" .. invalid[i].id] ~= nil,
				"partial early-DONE chunks were discarded at row " .. i
			)
		else
			assertEqual(
				nil,
				fixture.sync._pendingRequests[invalid[i].id],
				"rejected request was not cleared at row " .. i
			)
			assertEqual(
				nil,
				fixture.sync._incoming["Leader:" .. invalid[i].id],
				"rejected chunks were not cleared at row " .. i
			)
		end
	end
	fixture.sync._pendingRequests.expired = { source = "Leader", checksum = "old", createdAt = 10 }
	fixture.sync._incoming["Leader:expired"] = { total = 1, chunks = { "old" }, createdAt = 10 }
	fixture.setNow(190)
	fixture.sync:HandleMessage("RMAResSync", fixture.encode("UNKNOWN", "expired", "Tester", {}), "WHISPER", "Leader-Realm")
	assertEqual(nil, fixture.sync._pendingRequests.expired, "expired request must be cleared deterministically")
	assertEqual(nil, fixture.sync._incoming["Leader:expired"], "expired assembly must be cleared deterministically")
	print("PASS reserves_sync_checksums_and_payloads_are_verified")
end

function cases.reserves_sync_protocol_projection_and_chunks_fail_closed(addon)
	local fixture = installRealReservesSyncFixture(addon)
	local canonical = {
		alpha = {
			playerNameDisplay = "Alpha",
			reserves = {
				{ rawID = 100, quantity = 1, plus = 0, class = "MAGE", spec = "Fire", note = "", source = "csv" },
			},
		},
	}
	local wireEquivalent = {
		alpha = {
			playerNameDisplay = "Alpha",
			reserves = {
				{ rawID = "100", quantity = nil, plus = nil, class = "MAGE", spec = "Fire", note = "", source = "csv" },
			},
		},
	}
	local checksum = fixture.reserves.BuildCanonicalChecksum(canonical)
	assertTrue(
		type(checksum) == "string" and checksum:match("^C2:%d+:%d+$") ~= nil,
		"new checksums need a tagged semantic version"
	)
	assertEqual(
		checksum,
		fixture.reserves.BuildCanonicalChecksum(wireEquivalent),
		"hashing and wire defaults must share one projection"
	)
	local sparse = {
		alpha = {
			playerNameDisplay = "Alpha",
			reserves = { [1] = canonical.alpha.reserves[1], [3] = canonical.alpha.reserves[1] },
		},
	}
	local sparseChecksum, sparseReason = fixture.reserves.BuildCanonicalChecksum(sparse)
	assertEqual(nil, sparseChecksum, "sparse reserve sequences must be rejected")
	assertEqual("invalid_reserve_sequence", sparseReason, "sparse rejection reason differs")

	-- Delimited metadata is not an R5 envelope and must fail closed without allocating state.
	fixture.sync:HandleMessage("RMAResSync", "META_ACK|legacy|12345|multi|1|1|Leader|C1", "WHISPER", "Leader-Realm")
	assertEqual(
		nil,
		fixture.sync._pendingRequests.legacy,
		"untagged legacy metadata must not start an unverifiable transfer"
	)
	local invalidMeta = {
		{ id = "bad-mode", body = { checksum = checksum, mode = "broken", players = 1, entries = 1, source = "Leader" } },
		{ id = "bad-count", body = { checksum = checksum, mode = "multi", players = 1.5, entries = 1, source = "Leader" } },
		{ id = "negative", body = { checksum = checksum, mode = "multi", players = -1, entries = 1, source = "Leader" } },
		{ id = "huge", body = { checksum = checksum, mode = "multi", players = 999999, entries = 1, source = "Leader" } },
		{ id = "bad-hash", body = { checksum = "C2:nope", mode = "multi", players = 1, entries = 1, source = "Leader" } },
	}
	for i = 1, #invalidMeta do
		fixture.sync:HandleMessage(
			"RMAResSync",
			fixture.encode("META_ACK", invalidMeta[i].id, "Tester", invalidMeta[i].body),
			"WHISPER",
			"Leader-Realm"
		)
	end
	for _, id in ipairs({ "bad-mode", "bad-count", "negative", "huge", "bad-hash" }) do
		assertEqual(nil, fixture.sync._pendingRequests[id], "invalid META allocated request " .. id)
	end

	fixture.sync._pendingRequests.chunks = { stage = "metadata", createdAt = 10 }
	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("META_ACK", "chunks", "Tester", {
			checksum = checksum, mode = "multi", players = 1, entries = 1, source = "Leader",
		}),
		"WHISPER",
		"Leader-Realm"
	)
	local firstChunk = fixture.encode("DATA_CHUNK", "chunks", "Tester", { index = 1, count = 2, chunk = "AAAA" })
	fixture.sync:HandleMessage("RMAResSync", firstChunk, "WHISPER", "Leader-Realm")
	fixture.sync:HandleMessage("RMAResSync", firstChunk, "WHISPER", "Leader-Realm")
	assertTrue(fixture.sync._incoming["Leader:chunks"] ~= nil, "identical duplicate chunk should be idempotent")
	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("DATA_CHUNK", "chunks", "Tester", { index = 1, count = 2, chunk = "BBBB" }),
		"WHISPER",
		"Leader-Realm"
	)
	assertEqual(nil, fixture.sync._incoming["Leader:chunks"], "conflicting duplicate must invalidate assembly")
	assertEqual(nil, fixture.sync._pendingRequests.chunks, "conflicting duplicate must invalidate request")

	local malformedChunks = {
		{ id = "fractional", body = { index = 1.5, count = 2, chunk = "AAAA" } },
		{ id = "empty", body = { index = 1, count = 1, chunk = "" } },
		{ id = "zero", body = { index = 0, count = 1, chunk = "AAAA" } },
	}
	for i = 1, #malformedChunks do
		local id = malformedChunks[i].id
		fixture.sync._pendingRequests[id] =
			{ source = "Leader", checksum = checksum, players = 1, entries = 1, createdAt = 10 }
		fixture.sync:HandleMessage(
			"RMAResSync",
			fixture.encode("DATA_CHUNK", id, "Tester", malformedChunks[i].body),
			"WHISPER",
			"Leader-Realm"
		)
		assertEqual(nil, fixture.sync._incoming["Leader:" .. id], "malformed chunk allocated assembly " .. id)
		assertEqual(nil, fixture.sync._pendingRequests[id], "malformed chunk retained request " .. id)
	end

	-- A new sender publishes canonical structured R5 metadata and transfer tables.
	_G.RMA_Reserves = deepCopy(wireEquivalent)
	fixture.reserves:Load()
	for key in pairs(fixture.sent) do
		fixture.sent[key] = nil
	end
	fixture.sync:HandleMessage("RMAResSync", fixture.encode("META_REQ", "r5-meta", nil, {}), "RAID", "Old-Realm")
	local metaEnvelope = assertR5Envelope(addon, fixture.sent[#fixture.sent].message, "META_ACK")
	assertEqual(
		fixture.reserves.BuildCanonicalChecksum(wireEquivalent),
		metaEnvelope[5].checksum,
		"outbound META must hash serialized projection"
	)
	local outboundChecksum = metaEnvelope[5].checksum
	for key in pairs(fixture.sent) do
		fixture.sent[key] = nil
	end
	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("DATA_REQ", "r5-data", "Tester", { checksum = outboundChecksum }),
		"WHISPER",
		"Old-Realm"
	)
	local encodedParts = {}
	local doneChecksum
	for i = 1, #fixture.sent do
		local sent = fixture.sent[i]
		if sent.kind == "DATA_CHUNK" then
			encodedParts[sent.body.index] = sent.body.chunk
			assertEqual("BULK", sent.priority, "R5 reserve chunk priority differs")
		end
		if sent.kind == "DATA_DONE" then
			doneChecksum = sent.body.checksum
		end
	end
	assertEqual(outboundChecksum, doneChecksum, "R5 DATA_DONE checksum differs")
	local transfer = assert(fixture.payload.Deserialize(table.concat(encodedParts, "")))
	assertEqual("multi", transfer.mode, "R5 transfer mode differs")
	assertEqual("Alpha", transfer.players[1].name, "R5 transfer player differs")
	assertEqual(100, transfer.players[1].rows[1].rawID, "R5 transfer item differs")
	assertEqual(1, transfer.players[1].rows[1].quantity, "R5 transfer quantity default differs")
	assertEqual(0, transfer.players[1].rows[1].plus, "R5 transfer plus default differs")
	print("PASS reserves_sync_protocol_projection_and_chunks_fail_closed")
end

function cases.reserves_sync_r5_envelopes_chunks_and_rejections()
	local providerAddon = newAddon()
	local receiverAddon = newAddon()
	local provider = installRealReservesSyncFixture(providerAddon, "Leader")
	local canonical = {}
	for i = 1, 48 do
		local name = "Player" .. tostring(i)
		local note = {}
		for j = 1, 48 do
			note[j] = string.char(33 + ((i * 41 + j * 29) % 90))
		end
		canonical[string.lower(name)] = {
			playerNameDisplay = name,
			reserves = {
				{
					rawID = 10000 + i,
					quantity = (i % 3) + 1,
					plus = i % 2,
					class = "CLASS" .. tostring(i),
					spec = "SPEC" .. tostring(i),
					note = table.concat(note),
					source = "r5-test-" .. tostring(i),
				},
			},
		}
	end
	_G.RMA_Reserves = deepCopy(canonical)
	provider.reserves:Load()
	assertTrue(provider.reserves:IsLocalDataAvailable(), "provider reserves fixture did not load")

	_G.RMA_Reserves = {}
	local receiver = installRealReservesSyncFixture(receiverAddon, "Receiver")
	assertEqual(false, receiver.reserves:IsLocalDataAvailable(), "receiver unexpectedly started with reserves data")
	assertTrue(receiver.sync:RequestMetadata(), "R5 metadata request did not publish")
	local metaRequest = receiver.sent[#receiver.sent]
	local metaRequestRaw = assertR5Envelope(receiverAddon, metaRequest.message, "META_REQ")
	assertEqual(false, metaRequestRaw[4], "metadata request target must be broadcast")
	assertEqual("ALERT", metaRequest.priority, "metadata request priority differs")

	assertTrue(provider.sync:HandleMessage("RMAResSync", metaRequest.message, "RAID", "Receiver-Realm"))
	local metaAck = provider.sent[#provider.sent]
	local metaAckRaw = assertR5Envelope(providerAddon, metaAck.message, "META_ACK")
	assertEqual("Receiver", metaAckRaw[4], "metadata acknowledgement target differs")
	assertEqual("ALERT", metaAck.priority, "metadata acknowledgement priority differs")
	assertTrue(receiver.sync:HandleMessage("RMAResSync", metaAck.message, "WHISPER", "Leader-Realm"))
	assertTrue(
		receiver.sync._pendingRequests[metaAckRaw[3]] ~= nil,
		"R5 metadata acknowledgement did not register a pending request"
	)
	local dataRequest = receiver.sent[#receiver.sent]
	assertR5Envelope(receiverAddon, dataRequest.message, "DATA_REQ")
	assertEqual("ALERT", dataRequest.priority, "data request priority differs")

	for key in pairs(provider.sent) do
		provider.sent[key] = nil
	end
	assertTrue(provider.sync:HandleMessage("RMAResSync", dataRequest.message, "WHISPER", "Receiver-Realm"))
	local chunks = {}
	local done
	local queueName
	for i = 1, #provider.sent do
		local sent = provider.sent[i]
		if sent.kind == "DATA_CHUNK" then
			local raw = assertR5Envelope(providerAddon, sent.message, "DATA_CHUNK")
			assertEqual("BULK", sent.priority, "reserves chunk priority differs")
			queueName = queueName or sent.queueName
			assertEqual(queueName, sent.queueName, "reserves chunk queue changed")
			assertTrue(#sent.message <= 243, "reserves chunk exceeded the addon wire limit")
			chunks[#chunks + 1] = sent
			assertEqual(#chunks, raw[5].index, "reserves chunk index differs")
		elseif sent.kind == "DATA_DONE" then
			done = sent
		end
	end
	assertTrue(#chunks > 1, "reserves transfer did not exercise chunking")
	assertTrue(done ~= nil, "reserves transfer omitted DATA_DONE")
	local doneRaw = assertR5Envelope(providerAddon, done.message, "DATA_DONE")
	assertEqual("Receiver", doneRaw[4], "reserves DATA_DONE target differs")
	assertEqual("ALERT", done.priority, "reserves DATA_DONE priority differs")
	for i = #chunks, 1, -1 do
		assertTrue(receiver.sync:HandleMessage("RMAResSync", chunks[i].message, "WHISPER", "Leader-Realm"))
	end
	assertTrue(receiver.sync._pendingRequests[metaAckRaw[3]] ~= nil, "reserves chunks cleared the pending request")
	assertTrue(receiver.sync._incoming["Leader:" .. metaAckRaw[3]] ~= nil, "reserves chunks did not assemble")
	assertEqual(
		receiver.sync._pendingRequests[metaAckRaw[3]].checksum,
		doneRaw[5].checksum,
		"reserves DATA_DONE checksum differs"
	)
	assertTrue(receiver.sync:HandleMessage("RMAResSync", done.message, "WHISPER", "Leader-Realm"))
	local receivedData = {}
	for key, player in pairs(canonical) do
		receivedData[key] = {
			playerNameDisplay = player.playerNameDisplay,
			reserves = receiver.reserves:GetPlayerReserveEntries(player.playerNameDisplay),
		}
	end
	assertEqual(
		provider.reserves.BuildCanonicalChecksum(canonical),
		receiver.reserves.BuildCanonicalChecksum(receivedData),
		"out-of-order reserves transfer changed canonical state: " .. tostring(receiver.warnings[#receiver.warnings])
	)

	local checksumBefore = receiver.reserves:GetSyncMetadata().checksum
	local codec = receiverAddon.Comms.Payload
	local invalid = {
		assert(codec.Serialize({ 4, "META_ACK", "v4", "Receiver", metaAckRaw[5] })),
		assert(codec.Serialize({ [1] = 5, [2] = "META_ACK", [3] = "sparse", [5] = metaAckRaw[5] })),
		assert(codec.Serialize({ 5, "NOT_A_KIND", false, false, {} })),
		assert(codec.Serialize({ 5, "DATA_CHUNK", "too-many", "Receiver", { index = 1, count = 65, chunk = "x" } })),
		assert(codec.Serialize({ 5, "DATA_CHUNK", "oversized", "Receiver", { index = 1, count = 1, chunk = string.rep("x", 221) } })),
		"\001malformed",
		"META_ACK|legacy|checksum|multi|1|1|Leader|C2",
	}
	for i = 1, #invalid do
		receiver.sync:HandleMessage("RMAResSync", invalid[i], "WHISPER", "Leader-Realm")
		assertEqual(checksumBefore, receiver.reserves:GetSyncMetadata().checksum, "invalid reserves message mutated state " .. i)
	end
	assertEqual(nil, next(receiver.sync._incoming), "invalid reserves messages allocated assembly state")
	print("PASS reserves_sync_r5_envelopes_chunks_and_rejections")
end

function cases.reserves_sync_done_before_chunks_and_foreign_error_are_safe()
	_G.RMA_Reserves = {}
	local addon = newAddon()
	local fixture = installRealReservesSyncFixture(addon, "Receiver")
	local canonical = {
		alpha = {
			playerNameDisplay = "Alpha",
			reserves = {
				{
					rawID = 19019,
					quantity = 2,
					plus = 1,
					class = "WARRIOR",
					spec = "Fury",
					note = string.rep("abcdefghij", 16),
					source = "reviewer-race",
				},
			},
		},
	}
	local projection = assert(fixture.reserves.BuildCanonicalProjection(canonical))
	local transfer = { mode = "multi", players = {} }
	for i = 1, #projection do
		local player = { name = projection[i].name, rows = {} }
		transfer.players[i] = player
		for j = 1, #projection[i].rows do
			local row = projection[i].rows[j]
			player.rows[j] = {
				rawID = row.rawID,
				quantity = row.quantity,
				plus = row.plus,
				class = row.class,
				spec = row.spec,
				note = row.note,
				source = row.source,
			}
		end
	end
	local encoded = assert(fixture.payload.Serialize(transfer))
	local chunkSize = 80
	local chunkCount = math.ceil(#encoded / chunkSize)
	assertTrue(chunkCount > 1, "early-DONE fixture did not produce multiple chunks")
	local checksum = fixture.reserves.BuildCanonicalChecksum(canonical)
	assertTrue(fixture.sync:RequestMetadata(), "early-DONE metadata request was not sent")
	local requestId = fixture.sent[#fixture.sent].envelope[3]
	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("META_ACK", requestId, "Receiver", {
			checksum = checksum,
			mode = "multi",
			players = 1,
			entries = 1,
			source = "Leader",
		}),
		"WHISPER",
		"Leader-Realm"
	)
	local applyCalls = 0
	local originalSet = fixture.sync.SetSyncedData
	fixture.sync.SetSyncedData = function(self, data, meta)
		applyCalls = applyCalls + 1
		return originalSet(self, data, meta)
	end
	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("DATA_DONE", requestId, "Receiver", { checksum = checksum }),
		"WHISPER",
		"Leader-Realm"
	)
	local pending = fixture.sync._pendingRequests[requestId]
	assertTrue(pending ~= nil, "early DATA_DONE cleared the correlated request")
	assertEqual(checksum, pending.doneChecksum, "early DATA_DONE marker differs")
	assertEqual(0, applyCalls, "early DATA_DONE applied before chunks arrived")

	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("DATA_ERR", requestId, "Receiver", { reason = "foreign" }),
		"WHISPER",
		"Other-Realm"
	)
	assertTrue(fixture.sync._pendingRequests[requestId] ~= nil, "non-selected authority cancelled pending reserves")
	assertEqual(0, applyCalls, "non-selected authority error applied reserves")

	for index = 1, chunkCount do
		fixture.sync:HandleMessage(
			"RMAResSync",
			fixture.encode("DATA_CHUNK", requestId, "Receiver", {
				index = index,
				count = chunkCount,
				chunk = string.sub(encoded, ((index - 1) * chunkSize) + 1, index * chunkSize),
			}),
			"WHISPER",
			"Leader-Realm"
		)
	end
	assertEqual(1, applyCalls, "last chunk did not complete early-DONE transfer exactly once")
	assertEqual(nil, fixture.sync._pendingRequests[requestId], "completed early-DONE request was retained")
	assertEqual(nil, fixture.sync._incoming["Leader:" .. requestId], "completed early-DONE assembly was retained")
	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("DATA_DONE", requestId, "Receiver", { checksum = checksum }),
		"WHISPER",
		"Leader-Realm"
	)
	assertEqual(1, applyCalls, "duplicate DATA_DONE reapplied reserves")
	print("PASS reserves_sync_done_before_chunks_and_foreign_error_are_safe")
end

function cases.reserves_sync_metadata_requests_are_correlated_and_bounded()
	_G.RMA_Reserves = {}
	local addon = newAddon()
	local fixture = installRealReservesSyncFixture(addon, "Receiver")
	local metadata = {
		checksum = "C2:1:1",
		mode = "multi",
		players = 1,
		entries = 1,
		source = "Leader",
	}

	local sentBefore = #fixture.sent
	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("META_ACK", "never-issued", "Receiver", metadata),
		"WHISPER",
		"Leader-Realm"
	)
	assertEqual(sentBefore, #fixture.sent, "unsolicited metadata acknowledgement triggered a data request")
	assertEqual(nil, fixture.sync._pendingRequests["never-issued"], "unsolicited metadata allocated pending state")

	assertTrue(fixture.sync:RequestMetadata(), "metadata request did not use the real Comms surface")
	local request = fixture.sent[#fixture.sent].envelope
	local requestId = request[3]
	assertTrue(type(requestId) == "string" and requestId ~= "", "reserves did not generate its own request ID")
	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("META_ACK", requestId, "Receiver", metadata),
		"WHISPER",
		"Leader-Realm"
	)
	local selected = fixture.sync._pendingRequests[requestId]
	assertEqual("Leader", selected and selected.source, "first correlated metadata source was not selected")
	local afterSelection = #fixture.sent
	fixture.sync:HandleMessage(
		"RMAResSync",
		fixture.encode("META_ACK", requestId, "Receiver", metadata),
		"WHISPER",
		"Other-Realm"
	)
	assertEqual(afterSelection, #fixture.sent, "second metadata authority replaced the selected source")
	assertEqual("Leader", fixture.sync._pendingRequests[requestId].source, "selected metadata source changed")

	fixture.sync._pendingRequests = {}
	fixture.sync._nextRequestId = 999998
	for i = 1, 32 do
		assertTrue(fixture.sync:RequestMetadata(), "pending metadata capacity rejected request " .. i)
	end
	local firstBoundedId = fixture.sent[afterSelection + 1].envelope[3]
	local secondBoundedId = fixture.sent[afterSelection + 2].envelope[3]
	assertEqual("R999999", firstBoundedId, "reserves request sequence did not reach its bounded maximum")
	assertEqual("R1", secondBoundedId, "reserves request sequence did not wrap at its bounded maximum")
	local beforeCapacityReject = #fixture.sent
	assertEqual(false, fixture.sync:RequestMetadata(), "pending metadata capacity was not enforced")
	assertEqual(beforeCapacityReject, #fixture.sent, "capacity rejection reached the transport")

	fixture.setNow(190)
	assertTrue(fixture.sync:RequestMetadata(), "expired metadata requests did not release capacity")
	assertEqual(1, (function()
		local count = 0
		for _ in pairs(fixture.sync._pendingRequests) do count = count + 1 end
		return count
	end)(), "expired metadata requests were retained")
	print("PASS reserves_sync_metadata_requests_are_correlated_and_bounded")
end

function cases.reserves_sync_incoming_requests_are_rate_limited_before_response_work()
	local function countKeys(value)
		local count = 0
		for _ in pairs(type(value) == "table" and value or {}) do
			count = count + 1
		end
		return count
	end

	local function installProvider(localName)
		_G.RMA_Reserves = {}
		local providerAddon = newAddon()
		local fixture = installRealReservesSyncFixture(providerAddon, localName or "Provider")
		_G.RMA_Reserves = {
			alpha = {
				playerNameDisplay = "Alpha",
				reserves = {
					{
						rawID = 10001,
						quantity = 1,
						plus = 0,
						class = "MAGE",
						spec = "Arcane",
						note = "bounded",
						source = "test",
					},
				},
			},
		}
		fixture.reserves:Load()
		assertTrue(fixture.reserves:IsLocalDataAvailable(), "reserve provider fixture did not load local data")
		return providerAddon, fixture
	end

	local function assertHandledWithoutResponseWork(fixture, message, sender, label, expectedDebugDelta)
		local sentBefore = #fixture.sent
		local infoBefore = #fixture.infos
		local warningBefore = #fixture.warnings
		local debugBefore = #fixture.debugMessages
		fixture.resetWork()
		assertEqual(
			true,
			fixture.sync:HandleMessage("RMAResSync", message, "WHISPER", sender),
			label .. " was not consumed"
		)
		assertEqual(0, fixture.work.payloadCalls, label .. " constructed a reserve payload")
		assertEqual(0, fixture.work.serializeCalls, label .. " serialized a response")
		assertEqual(0, fixture.work.directQueueAttempts, label .. " reached the direct queue")
		assertEqual(0, fixture.work.batchQueueAttempts, label .. " built or queued a response batch")
		assertEqual(0, fixture.work.emittedPackets, label .. " emitted a response packet")
		assertEqual(sentBefore, #fixture.sent, label .. " changed the captured transport")
		assertEqual(infoBefore, #fixture.infos, label .. " emitted ordinary chat output")
		assertEqual(warningBefore, #fixture.warnings, label .. " emitted a warning")
		assertEqual(expectedDebugDelta or 0, #fixture.debugMessages - debugBefore, label .. " debug output differs")
	end

	local providerAddon, fixture = installProvider("Provider")
	fixture.setNow(10)
	local metaRequest = fixture.encode("META_REQ", "meta-first", false, {})
	local dataRequest = fixture.encode("DATA_REQ", "data-first", "Provider", { checksum = "C2:0:0" })
	fixture.resetWork()
	assertTrue(fixture.sync:HandleMessage("RMAResSync", metaRequest, "RAID", "Player-Realm"))
	assertEqual(1, fixture.work.payloadCalls, "first metadata request payload count differs")
	assertEqual(1, fixture.work.serializeCalls, "first metadata response serialization count differs")
	assertEqual(1, fixture.work.directQueueAttempts, "first metadata response queue count differs")
	assertEqual(1, fixture.work.emittedPackets, "first metadata response packet count differs")
	local metaAck = fixture.sent[#fixture.sent]
	local metaEnvelope = assertR5Envelope(providerAddon, metaAck.message, "META_ACK")
	assertEqual("RMAResSync", metaAck.prefix, "metadata response prefix differs")
	assertEqual("meta-first", metaEnvelope[3], "metadata response request ID differs")
	assertEqual("Player", metaEnvelope[4], "metadata response target differs")
	assertEqual("ALERT", metaAck.priority, "metadata response priority differs")
	assertEqual("WHISPER", metaAck.channel, "metadata response channel differs")
	assertTrue(type(metaEnvelope[5].checksum) == "string", "metadata checksum is absent")
	assertEqual("multi", metaEnvelope[5].mode, "metadata mode differs")
	assertEqual(1, metaEnvelope[5].players, "metadata player count differs")
	assertEqual(1, metaEnvelope[5].entries, "metadata entry count differs")
	assertEqual("Provider", metaEnvelope[5].source, "metadata source differs")

	local dataSentAt = #fixture.sent
	fixture.resetWork()
	assertTrue(fixture.sync:HandleMessage("RMAResSync", dataRequest, "WHISPER", "Player-Realm"))
	assertEqual(1, fixture.work.payloadCalls, "independent first data request payload count differs")
	assertEqual(1, fixture.work.batchQueueAttempts, "first data response batch count differs")
	assertEqual(1, fixture.work.directQueueAttempts, "first data completion queue count differs")
	local dataChunks = 0
	local dataDone
	for i = dataSentAt + 1, #fixture.sent do
		local packet = fixture.sent[i]
		local envelope = assertR5Envelope(providerAddon, packet.message, packet.kind)
		assertEqual("RMAResSync", packet.prefix, "data response prefix differs")
		assertEqual("data-first", envelope[3], "data response request ID differs")
		assertEqual("Player", envelope[4], "data response target differs")
		if packet.kind == "DATA_CHUNK" then
			dataChunks = dataChunks + 1
			assertEqual("BULK", packet.priority, "data chunk priority differs")
			assertTrue(type(envelope[5].chunk) == "string" and envelope[5].chunk ~= "", "data chunk body differs")
		elseif packet.kind == "DATA_DONE" then
			dataDone = envelope
			assertEqual("ALERT", packet.priority, "data completion priority differs")
		end
	end
	assertTrue(dataChunks >= 1, "first data request emitted no chunks")
	assertTrue(dataDone ~= nil, "first data request emitted no DATA_DONE")
	assertTrue(type(dataDone[5].checksum) == "string", "data completion checksum is absent")

	fixture.setNow(14.999)
	local aliasLower = fixture.encode("META_REQ", "meta-lower", false, {})
	local aliasRealm = fixture.encode("META_REQ", "meta-realm", false, {})
	assertHandledWithoutResponseWork(fixture, aliasLower, "player", "case alias replay before five seconds")
	assertHandledWithoutResponseWork(fixture, aliasRealm, "Player-OtherRealm", "realm alias replay before five seconds")
	fixture.setNow(15)
	local exactBoundary = fixture.encode("META_REQ", "meta-boundary", false, {})
	fixture.resetWork()
	assertTrue(fixture.sync:HandleMessage("RMAResSync", exactBoundary, "RAID", "Player-Realm"))
	assertEqual(1, fixture.work.payloadCalls, "exact five-second metadata boundary was not admitted")
	assertEqual("meta-boundary", fixture.sent[#fixture.sent].envelope[3], "boundary response request ID differs")

	local _, validationFixture = installProvider("Validator")
	validationFixture.setNow(30)
	local wrongVersion = validationFixture.encode("META_REQ", "invalid-version", false, {}, 4)
	local wrongTarget = validationFixture.encode("META_REQ", "invalid-target", "Validator", {})
	local wrongBody = validationFixture.encode("META_REQ", "invalid-body", false, { unexpected = true })
	local validAfterMalformed = validationFixture.encode("META_REQ", "valid-after-malformed", false, {})
	assertHandledWithoutResponseWork(validationFixture, wrongVersion, "Validator-Realm", "wrong-version request")
	assertHandledWithoutResponseWork(validationFixture, wrongTarget, "Validator-Realm", "mistargeted request")
	assertHandledWithoutResponseWork(validationFixture, wrongBody, "Validator-Realm", "malformed-body request")
	assertHandledWithoutResponseWork(validationFixture, validAfterMalformed, "-Realm", "invalid normalized identity")
	assertEqual(0, countKeys(validationFixture.sync._requestAdmissions), "invalid requests allocated admission state")
	validationFixture.resetWork()
	assertTrue(validationFixture.sync:HandleMessage("RMAResSync", validAfterMalformed, "RAID", "Validator-Realm"))
	assertEqual(1, validationFixture.work.payloadCalls, "malformed requests consumed the later valid admission")

	local deniedRequest = validationFixture.encode("META_REQ", "denied", false, {})
	validationFixture.setMember("Denied-Realm", false)
	assertHandledWithoutResponseWork(validationFixture, deniedRequest, "Denied-Realm", "non-member request")
	assertEqual("Denied-Realm", validationFixture.membershipChecks[#validationFixture.membershipChecks], "membership did not receive raw sender")
	validationFixture.setMember("Denied-Realm", true)
	validationFixture.resetWork()
	assertTrue(validationFixture.sync:HandleMessage("RMAResSync", deniedRequest, "RAID", "Denied-Realm"))
	assertEqual(1, validationFixture.work.payloadCalls, "non-member request consumed admission state")
	validationFixture.setNow(31)
	validationFixture.setMember("Denied-Realm", false)
	assertHandledWithoutResponseWork(validationFixture, deniedRequest, "Denied-Realm", "sender after leaving group")
	validationFixture.setMember("Denied-Realm", true)
	assertHandledWithoutResponseWork(validationFixture, deniedRequest, "Denied-Realm", "re-entered sender with active cooldown")
	validationFixture.setNow(35)
	validationFixture.resetWork()
	assertTrue(validationFixture.sync:HandleMessage("RMAResSync", deniedRequest, "RAID", "Denied-Realm"))
	assertEqual(1, validationFixture.work.payloadCalls, "re-entered sender was not admitted at the original expiry")

	_G.RMA_Reserves = {}
	local noDataAddon = newAddon()
	local noDataFixture = installRealReservesSyncFixture(noDataAddon, "NoDataProvider")
	noDataFixture.setNow(40)
	local noDataRequest = noDataFixture.encode("META_REQ", "no-data", false, {})
	noDataFixture.resetWork()
	assertTrue(noDataFixture.sync:HandleMessage("RMAResSync", noDataRequest, "RAID", "NoData-Realm"))
	assertEqual(0, noDataFixture.work.payloadCalls, "no-data path unexpectedly built a reserve payload")
	assertEqual(1, noDataFixture.work.directQueueAttempts, "no-data path did not preserve its error response")
	local noDataError = assertR5Envelope(noDataAddon, noDataFixture.sent[#noDataFixture.sent].message, "DATA_ERR")
	assertEqual("no-data", noDataError[3], "no-data error request ID differs")
	assertEqual("NoData", noDataError[4], "no-data error target differs")
	assertEqual("no_data", noDataError[5].reason, "no-data error reason differs")
	noDataFixture.setNow(41)
	assertHandledWithoutResponseWork(noDataFixture, noDataRequest, "NoData-Realm", "no-data replay with debug disabled")
	noDataFixture.setDebug(true)
	assertHandledWithoutResponseWork(noDataFixture, noDataRequest, "NoData-Realm", "first debug-visible cooldown rejection", 1)
	assertContains(
		noDataFixture.debugMessages[1],
		"service=reserves kind=META_REQ sender=nodata",
		"rate-limit diagnostic omitted bounded identity fields"
	)
	assertHandledWithoutResponseWork(noDataFixture, noDataRequest, "NoData-Realm", "deduplicated debug cooldown rejection")

	local _, capacityFixture = installProvider("CapacityProvider")
	capacityFixture.setNow(60)
	local capacityRequests = {}
	for i = 1, 128 do
		capacityRequests[i] = capacityFixture.encode("META_REQ", "capacity-" .. tostring(i), false, {})
	end
	capacityFixture.resetWork()
	for i = 1, 128 do
		assertTrue(
			capacityFixture.sync:HandleMessage("RMAResSync", capacityRequests[i], "RAID", "Cap" .. tostring(i) .. "-Realm"),
			"capacity sender was not handled " .. tostring(i)
		)
	end
	assertEqual(128, countKeys(capacityFixture.sync._requestAdmissions), "reserve admission sender map bound differs")
	local existingOtherKind = capacityFixture.encode(
		"DATA_REQ",
		"capacity-data",
		"CapacityProvider",
		{ checksum = "C2:0:0" }
	)
	capacityFixture.resetWork()
	assertTrue(capacityFixture.sync:HandleMessage("RMAResSync", existingOtherKind, "WHISPER", "Cap1-Realm"))
	assertEqual(1, capacityFixture.work.payloadCalls, "existing sender's other request kind was blocked at capacity")
	assertEqual(128, countKeys(capacityFixture.sync._requestAdmissions), "independent request kind expanded sender capacity")
	local overflow = capacityFixture.encode("META_REQ", "capacity-overflow", false, {})
	assertHandledWithoutResponseWork(capacityFixture, overflow, "Cap129-Realm", "unseen sender at capacity")
	assertEqual(128, countKeys(capacityFixture.sync._requestAdmissions), "capacity rejection changed the map bound")
	assertTrue(capacityFixture.sync._requestAdmissions.cap1 ~= nil, "capacity rejection evicted an active sender")
	capacityFixture.setNow(65)
	local afterExpiry = capacityFixture.encode("META_REQ", "capacity-expired", false, {})
	capacityFixture.resetWork()
	assertTrue(capacityFixture.sync:HandleMessage("RMAResSync", afterExpiry, "RAID", "Cap129-Realm"))
	assertEqual(1, capacityFixture.work.payloadCalls, "lazy exact-boundary expiry did not admit a new sender")
	assertEqual(1, countKeys(capacityFixture.sync._requestAdmissions), "lazy expiry retained inactive reserve senders")
	assertTrue(capacityFixture.sync._requestAdmissions.cap129 ~= nil, "new sender was not recorded after lazy expiry")

	print("PASS reserves_sync_incoming_requests_are_rate_limited_before_response_work")
end

function cases.reserves_sync_assembly_admission_is_globally_and_per_sender_bounded()
	_G.RMA_Reserves = {}
	local addon = newAddon()
	local fixture = installRealReservesSyncFixture(addon, "Receiver")
	local requests = {}
	for i = 1, 22 do
		assertTrue(fixture.sync:RequestMetadata(), "assembly fixture metadata request failed " .. i)
		local requestId = fixture.sent[#fixture.sent].envelope[3]
		local sender
		if i <= 5 then
			sender = "PerSender"
		else
			sender = "Global" .. tostring(math.floor((i - 6) / 4) + 1)
		end
		fixture.sync:HandleMessage(
			"RMAResSync",
			fixture.encode("META_ACK", requestId, "Receiver", {
				checksum = "C2:" .. tostring(i) .. ":" .. tostring(i),
				mode = "multi",
				players = 1,
				entries = 1,
				source = sender,
			}),
			"WHISPER",
			sender .. "-Realm"
		)
		requests[i] = { id = requestId, sender = sender }
	end

	for i = 1, 5 do
		local request = requests[i]
		fixture.sync:HandleMessage(
			"RMAResSync",
			fixture.encode("DATA_CHUNK", request.id, "Receiver", { index = 1, count = 2, chunk = "part" }),
			"WHISPER",
			request.sender .. "-Realm"
		)
	end
	local perSenderCount = 0
	for _ in pairs(fixture.sync._incoming) do perSenderCount = perSenderCount + 1 end
	assertEqual(4, perSenderCount, "per-sender reserves assembly cap differs")
	assertEqual(nil, fixture.sync._incoming["PerSender:" .. requests[5].id], "per-sender cap rejection allocated state")

	fixture.sync._incoming = {}
	for i = 6, 22 do
		local request = requests[i]
		fixture.sync:HandleMessage(
			"RMAResSync",
			fixture.encode("DATA_CHUNK", request.id, "Receiver", { index = 1, count = 2, chunk = "part" }),
			"WHISPER",
			request.sender .. "-Realm"
		)
	end
	local globalCount = 0
	local perSender = {}
	for _, incoming in pairs(fixture.sync._incoming) do
		globalCount = globalCount + 1
		perSender[incoming.source] = (perSender[incoming.source] or 0) + 1
	end
	assertEqual(16, globalCount, "global reserves assembly cap differs")
	for sender, count in pairs(perSender) do
		assertTrue(count <= 4, "per-sender reserves assembly cap exceeded for " .. tostring(sender))
	end
	assertEqual(nil, fixture.sync._incoming["Global5:" .. requests[22].id], "global cap rejection allocated state")
	print("PASS reserves_sync_assembly_admission_is_globally_and_per_sender_bounded")
end

local function installSharedCommsFixture(addon)
	local calls = {}
	_G.strmatch = string.match
	_G.LibStub = nil
	assert(loadfile("Raid Management Addon/Libs/LibStub/LibStub.lua"))()
	assert(loadfile("Raid Management Addon/Libs/LibSerialize/LibSerialize.lua"))()
	assert(loadfile("Raid Management Addon/Libs/LibDeflate/LibDeflate.lua"))()
	_G.ChatThrottleLib = {
		SendAddonMessage = function(_, priority, prefix, msg, channel, target, queueName)
			calls[#calls + 1] = {
				priority = priority,
				prefix = prefix,
				msg = msg,
				channel = channel,
				target = target,
				queueName = queueName,
			}
		end,
		SendChatMessage = function() end,
	}
	_G.SendAddonMessage = function() end
	_G.SendChatMessage = function() end
	_G.GetAddOnMetadata = function()
		return "test"
	end
	_G.UnitName = function()
		return localName or "Tester"
	end
	_G.IsInInstance = function()
		return false, "none"
	end
	_G.GetNumRaidMembers = function()
		return 1
	end
	_G.GetNumPartyMembers = function()
		return 0
	end
	addon.L = {
		MsgVersionCheckSent = "sent",
		MsgVersionCheckNotInGroup = "not in group",
		MsgVersionCheckPeer = "%s %s %s %s %s",
	}
	addon.info = function() end
	addon.warn = function() end
	addon.Database.GetSyncer = function()
		return nil
	end
	addon.Database.GetRaidSchemaVersion = function()
		return 1
	end
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Modules/Comms.lua")
	return calls
end

function cases.comms_shared_wire_codec_round_trip_and_rejection(addon)
	installSharedCommsFixture(addon)
	local value = { 5, "EVENT", false, "Peer", { count = 2, enabled = true, nested = { "a", false, "b" } } }
	local encoded = assert(addon.Comms.Payload.Serialize(value))
	assertTrue(type(encoded) == "string" and encoded ~= "", "wire codec returned no text")
	assertTrue(deepEqual(value, assert(addon.Comms.Payload.Deserialize(encoded))), "wire round trip changed values")
	assertEqual(nil, addon.Comms.Payload.Deserialize("\001broken"), "malformed payload was accepted")
	print("PASS comms_shared_wire_codec_round_trip_and_rejection")
end

function cases.comms_chat_throttle_priority_and_queue_names(addon)
	local calls = installSharedCommsFixture(addon)
	assertTrue(addon.Comms.QueueAddonMessage("RMARaidSync", "live", "WHISPER", "Peer", { priority = "NORMAL" }))
	assertTrue(addon.Comms.QueueAddonMessages(
		"RMARaidSync",
		{ "part-1", "part-2" },
		"WHISPER",
		"Peer",
		{ priority = "BULK" }
	))
	assertEqual("NORMAL", calls[1].priority, "live priority differs")
	assertEqual("BULK", calls[2].priority, "bulk priority differs")
	assertEqual(calls[2].queueName, calls[3].queueName, "batch flow name changed")
	assertEqual("RMARaidSync:WHISPER:peer", calls[2].queueName, "stable flow name differs")
	print("PASS comms_chat_throttle_priority_and_queue_names")
end

function cases.comms_transport_options_fail_closed(addon)
	local calls = installSharedCommsFixture(addon)
	local before = #calls
	local queued, reason = addon.Comms.QueueAddonMessage("RMARaidSync", "scalar", "RAID", nil, "BULK")
	assertEqual(false, queued, "scalar transport options were accepted")
	assertEqual("invalid_options", reason, "scalar transport options reason differs")
	assertEqual(before, #calls, "scalar transport options reached the throttler")

	queued, reason = addon.Comms.QueueAddonMessage("RMARaidSync", "empty-queue", "RAID", nil, { queueName = "" })
	assertEqual(false, queued, "empty queue name was accepted")
	assertEqual("invalid_queue_name", reason, "empty queue name reason differs")
	assertEqual(before, #calls, "empty queue name reached the throttler")

	queued, reason = addon.Comms.QueueAddonMessages("RMARaidSync", { "one", "two" }, "RAID", nil, 4)
	assertEqual(false, queued, "scalar batch transport options were accepted")
	assertEqual("invalid_options", reason, "scalar batch options reason differs")
	assertEqual(before, #calls, "scalar batch options partially enqueued")

	queued, reason = addon.Comms.QueueAddonMessages(
		"RMARaidSync",
		{ "one", "two" },
		"RAID",
		nil,
		{ priority = "NORMAL", queueName = false }
	)
	assertEqual(false, queued, "non-string batch queue name was accepted")
	assertEqual("invalid_queue_name", reason, "non-string batch queue reason differs")
	assertEqual(before, #calls, "invalid batch queue name partially enqueued")
	print("PASS comms_transport_options_fail_closed")
end

function cases.comms_batch_preflight_prevents_malformed_partial_enqueue(addon)
	local calls = installSharedCommsFixture(addon)
	local before = #calls
	local queued, reason = addon.Comms.QueueAddonMessages("RMARaidSync", { "valid", false }, "RAID")
	assertEqual(false, queued, "malformed batch was accepted")
	assertEqual("invalid", reason, "malformed batch reason differs")
	assertEqual(before, #calls, "malformed batch partially enqueued")
	print("PASS comms_batch_preflight_prevents_malformed_partial_enqueue")
end

function cases.comms_addon_destination_validation(addon)
	local calls = installSharedCommsFixture(addon)
	local before = #calls
	local queued, reason = addon.Comms.QueueAddonMessage("RMARaidSync", "bad", "CHANNEL", nil)
	assertEqual(false, queued, "invalid addon channel was accepted")
	assertEqual("invalid_destination", reason, "invalid addon channel reason differs")
	assertEqual(before, #calls, "invalid addon channel reached the throttler")

	queued, reason = addon.Comms.QueueAddonMessage("RMARaidSync", "missing", "WHISPER")
	assertEqual(false, queued, "targetless whisper was accepted")
	assertEqual("invalid_destination", reason, "targetless whisper reason differs")
	assertEqual(before, #calls, "targetless whisper reached the throttler")

	queued, reason = addon.Comms.QueueAddonMessages("RMARaidSync", { "group" }, "RAID", "Peer")
	assertEqual(false, queued, "targeted group batch was accepted")
	assertEqual("invalid_destination", reason, "targeted group batch reason differs")
	assertEqual(before, #calls, "targeted group batch reached the throttler")

	assertTrue(addon.Comms.QueueAddonMessage("RMARaidSync", "raid", "RAID"), "targetless RAID was rejected")
	assertTrue(
		addon.Comms.QueueAddonMessage("RMARaidSync", "whisper", "WHISPER", "Peer"),
		"targeted WHISPER was rejected"
	)
	assertEqual(before + 2, #calls, "valid addon destinations did not enqueue exactly once each")
	print("PASS comms_addon_destination_validation")
end

function cases.comms_version_r5_envelope_and_alert_ack(addon)
	local calls = installSharedCommsFixture(addon)
	assertTrue(addon.Comms:RequestVersionCheck(), "version request was not sent")
	assertEqual(1, #calls, "version request did not use the throttler")
	assertEqual("RMAVersion", calls[1].prefix, "version request prefix differs")
	assertEqual("ALERT", calls[1].priority, "version request priority differs")
	local request = assert(addon.Comms.Payload.Deserialize(calls[1].msg))
	assertEqual(5, request[1], "version request wire version differs")
	assertEqual("REQ", request[2], "version request kind differs")
	assertEqual(false, request[3], "version request third slot differs")
	assertEqual(false, request[4], "version request fourth slot differs")
	assertTrue(type(request[5]) == "table", "version request body is absent")
	assertTrue(type(request[5].addonVersion) == "string", "version request addon version is absent")

	local before = #calls
	assertTrue(addon.Comms:HandleVersionMessage("RMAVersion", "\001broken", "RAID", "Peer"))
	assertEqual(before, #calls, "malformed version message produced an acknowledgement")
	local oldWire = assert(addon.Comms.Payload.Serialize({ 4, "REQ", false, false, request[5] }))
	assertTrue(addon.Comms:HandleVersionMessage("RMAVersion", oldWire, "RAID", "Peer"))
	assertEqual(before, #calls, "non-R5 version message produced an acknowledgement")

	local validRequest = assert(addon.Comms.Payload.Serialize({ 5, "REQ", false, false, request[5] }))
	assertTrue(addon.Comms:HandleVersionMessage("RMAVersion", validRequest, "RAID", "Peer"))
	assertEqual(before + 1, #calls, "valid R5 request did not produce one acknowledgement")
	assertEqual("ALERT", calls[#calls].priority, "version acknowledgement priority differs")
	assertEqual("RMAVersion", calls[#calls].prefix, "version acknowledgement prefix differs")
	local acknowledgement = assert(addon.Comms.Payload.Deserialize(calls[#calls].msg))
	assertEqual(5, acknowledgement[1], "version acknowledgement wire version differs")
	assertEqual("ACK", acknowledgement[2], "version acknowledgement kind differs")
	assertEqual(false, acknowledgement[3], "version acknowledgement third slot differs")
	assertEqual(false, acknowledgement[4], "version acknowledgement fourth slot differs")
	assertTrue(type(acknowledgement[5]) == "table", "version acknowledgement body is absent")
	print("PASS comms_version_r5_envelope_and_alert_ack")
end

function cases.reserves_import_limits_and_schema_fail_closed(addon)
	addon.L = addon.L or {}
	addon.warn = function() end
	addon.debug = function() end
	addon.L.WarnNoValidRows = "no rows"
	addon.L.WarnReservesHeaderHint = "header"
	addon.L.WarnReservesEncodedImportCompressed = "compressed"
	addon.L.WarnReservesEncodedImportInvalid = "invalid"
	addon.Diag = {
		D = {
			LogReservesParseStart = "start",
			LogReservesImportRows = "%d %d %s %d",
			LogReservesEncodedImportStart = "encoded",
			LogReservesEncodedImportRows = "%d %d %s",
		},
		W = { LogReservesImportFailedEmpty = "empty", LogReservesEncodedImportFailed = "%s" },
	}
	addon.Options = {
		IsDebugEnabled = function()
			return false
		end,
	}
	addon.Strings = {
		NormalizeText = function(value)
			return value
		end,
		NormalizeLower = function(value)
			if type(value) ~= "string" or value == "" then
				return nil
			end
			return string.lower(value)
		end,
	}
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
		return addon.Services[name]
	end
	addon.Services.EnsureNamespace("Reserves")
	addon.Services.Reserves.GetImportMode = function()
		return "multi"
	end
	loadAddonFile(addon, "Raid Management Addon/Modules/Base64.lua")
	local jsonValue
	addon.Json = {
		Decode = function()
			return jsonValue
		end,
	}
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
	assertTrue(
		parser.ParseImport(service, atDecodedLimit, "multi", { format = "json" }) ~= nil,
		"exact decoded limit must import"
	)
	local overDecodedLimit = addon.Base64.Encode(string.rep("j", 131073))
	parsed, reason = parser.ParseImport(service, overDecodedLimit, "multi", { format = "json" })
	assertEqual(nil, parsed, "decoded max plus one must fail")
	assertEqual("IMPORT_DECODED_TOO_LARGE", reason, "decoded size reason differs")

	jsonValue = { softreserves = { { name = "Alpha", items = { { id = 1 } } } } }
	parsed = parser.ParseImport(service, addon.Base64.Encode("json"), "multi", { format = "json" })
	assertTrue(parsed ~= nil, "normal encoded JSON must import")
	parsed, reason = parser.ParseImport(
		service,
		addon.Base64.Encode(string.char(0x78, 0x9c) .. "bomb"),
		"multi",
		{ format = "json" }
	)
	assertEqual(nil, parsed, "compressed import must fail before inflate")
	assertEqual("COMPRESSED_UNSUPPORTED", reason, "compressed import reason differs")

	jsonValue = {
		softreserves = {
			[1] = { name = "Alpha", items = { { id = 1 } } },
			[3] = { name = "Beta", items = { { id = 2 } } },
		},
	}
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
	for i = 3, 32 do
		wideHeader[i], wideRow[i] = "legacy" .. i, "value" .. i
	end
	local exactFieldsCsv = table.concat(wideHeader, ",") .. "\n" .. table.concat(wideRow, ",")
	assertTrue(
		parser.ParseImport(service, exactFieldsCsv, "multi", { format = "csv" }) ~= nil,
		"exact CSV field limit must import"
	)
	local overFieldsCsv = table.concat(wideHeader, ",") .. ",extra\n" .. table.concat(wideRow, ",") .. ",value"
	parsed, reason = parser.ParseImport(service, overFieldsCsv, "multi", { format = "csv" })
	assertEqual(nil, parsed, "CSV field max plus one must fail")
	assertEqual("CSV_FIELDS_LIMIT", reason, "CSV field count reason differs")
	parsed, reason = parser.ParseImport(
		service,
		csvHeader .. "x,1,raid," .. string.rep("A", 65) .. ",WARRIOR,tank,note,0",
		"multi",
		{ format = "csv" }
	)
	assertEqual(nil, parsed, "overlong CSV name must fail")
	assertEqual("FIELD_LIMIT", reason, "CSV field reason differs")
	local duplicateRows = csvHeader
	for _ = 1, 100 do
		duplicateRows = duplicateRows .. "x,1,raid,Alpha,WARRIOR,tank,note,0\n"
	end
	assertTrue(
		parser.ParseImport(service, duplicateRows, "multi", { format = "csv" }) ~= nil,
		"quantity exact limit must import"
	)
	duplicateRows = duplicateRows .. "x,1,raid,Alpha,WARRIOR,tank,note,0\n"
	parsed, reason = parser.ParseImport(service, duplicateRows, "multi", { format = "csv" })
	assertEqual(nil, parsed, "quantity over limit must fail")
	assertEqual("QUANTITY_LIMIT", reason, "quantity reason differs")
	local hugeField = csvHeader .. "x,1,raid,Alpha,WARRIOR,tank," .. string.rep("n", 257) .. ",0"
	parsed, reason = parser.ParseImport(service, hugeField, "multi", { format = "csv" })
	assertEqual(nil, parsed, "huge CSV field must fail")
	assertEqual("FIELD_LIMIT", reason, "huge field reason differs")
	local reserveRows = csvHeader
	for itemId = 1, 20 do
		reserveRows = reserveRows .. "x," .. itemId .. ",raid,Alpha,WARRIOR,tank,note,0\n"
	end
	assertTrue(
		parser.ParseImport(service, reserveRows, "multi", { format = "csv" }) ~= nil,
		"reserves per player exact limit must import"
	)
	reserveRows = reserveRows .. "x,21,raid,Alpha,WARRIOR,tank,note,0\n"
	parsed, reason = parser.ParseImport(service, reserveRows, "multi", { format = "csv" })
	assertEqual(nil, parsed, "reserves per player over limit must fail")
	assertEqual("RESERVES_PER_PLAYER_LIMIT", reason, "reserve count reason differs")
	local playerParts = { csvHeader }
	for i = 1, 1000 do
		playerParts[#playerParts + 1] = "x,1,raid,P" .. i .. ",WARRIOR,tank,note,0\n"
	end
	local playerRows = table.concat(playerParts)
	assertTrue(
		parser.ParseImport(service, playerRows, "multi", { format = "csv" }) ~= nil,
		"player exact limit must import"
	)
	playerRows = playerRows .. "x,1,raid,P1001,WARRIOR,tank,note,0\n"
	parsed, reason = parser.ParseImport(service, playerRows, "multi", { format = "csv" })
	assertEqual(nil, parsed, "player max plus one must fail")
	assertEqual("PLAYERS_LIMIT", reason, "player limit reason differs")
	local rowParts = { csvHeader }
	for player = 1, 250 do
		for itemId = 1, 20 do
			rowParts[#rowParts + 1] = "x," .. itemId .. ",raid,R" .. player .. ",WARRIOR,tank,note,0\n"
		end
	end
	local maxRows = table.concat(rowParts)
	assertTrue(parser.ParseImport(service, maxRows, "multi", { format = "csv" }) ~= nil, "row exact limit must import")
	parsed, reason =
		parser.ParseImport(service, maxRows .. "x,1,raid,R1,WARRIOR,tank,note,0\n", "multi", { format = "csv" })
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
		WhisperSoftResHeader = "header",
		WhisperSoftResEntry = "%d. %s",
		WhisperSoftResNone = "none %s",
		WhisperSoftResAdded = "added %s",
		WhisperSoftResInvalidItem = "invalid item",
		WhisperSoftResAdmissionLimited = "slow down",
		WhisperSoftResCapacity = "full",
		WhisperSoftResInvalidSender = "invalid sender",
		StrReservesItemFallback = "[Item %s]",
	}
	addon.Strings = {
		TrimText = function(value)
			return tostring(value or ""):match("^%s*(.-)%s*$")
		end,
		NormalizeLower = function(value)
			return string.lower(tostring(value or ""))
		end,
		NormalizeName = function(value)
			return tostring(value or "")
		end,
	}
	addon.Database = {
		GetRealmName = function()
			return "Local Realm"
		end,
	}
	addon.Options = {
		GetValue = function()
			return true
		end,
	}
	addon.Events.Wow = { ChatMsgWhisper = "CHAT_MSG_WHISPER" }
	addon.Bus.RegisterCallback = function(_, callback)
		callbacks[#callbacks + 1] = callback
	end
	addon.Comms = {
		SendWhisper = function(target, text)
			sent[#sent + 1] = { target, text }
			return true
		end,
	}
	addon.Time = {
		GetCurrentTime = function()
			return now
		end,
	}
	addon.Services.Raid = {
		GetPlayerRoleState = function()
			return { inRaid = true, isMasterLooter = true }
		end,
		CanUseCapability = function()
			return true
		end,
	}
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
	end
	addon.Services.EnsureNamespace("Reserves")
	local reserves = addon.Services.Reserves
	reserves.ScheduleTimer = function(_, callback)
		timers[#timers + 1] = callback
		return #timers
	end
	reserves.IsPlusSystem = function()
		return false
	end
	reserves.GetCounts = function()
		local players, entries = 0, 0
		for _, rows in pairs(data) do
			players = players + 1
			entries = entries + #rows
		end
		return players, entries
	end
	reserves.GetPlayerReserveEntries = function(_, name)
		return data[string.lower(name)] or {}
	end
	reserves.NormalizeWhisperPlayerIdentity = function(_, value, localRealm)
		if
			type(value) ~= "string"
			or value == ""
			or #value > 64
			or value:find("[%c|]")
			or value:find(string.char(0xff), 1, true)
		then
			return nil
		end
		local character, realm = value:match("^([^-]+)%-(.+)$")
		character, realm = character or value, realm or localRealm
		if
			character:find("[^A-Za-z\128-\255']")
			or character:match("^'")
			or character:match("'$+")
			or realm:match("^[ %'-]")
			or realm:match("[ %'-]$")
		then
			return nil
		end
		local realmKey = string.lower((realm:gsub("[ '%-]", "")))
		local localKey = string.lower((localRealm:gsub("[ '%-]", "")))
		return character, realmKey, string.lower(character) .. "-" .. realmKey, localKey
	end
	reserves.ResolveWhisperPlayerName = function(_, character, senderRealm, localRealm)
		if senderRealm == localRealm then
			return character
		end
		return character .. "-" .. senderRealm
	end
	reserves.AddPlayerReserve = function(_, name, itemRef)
		if itemRef == "[PublishFail]" then
			return false, "publish_failed"
		end
		if itemRef ~= "[Valid]" then
			return false, "invalid_item"
		end
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
	assertTrue(
		data["al" .. string.char(0xc3, 0xa9) .. "a-r" .. string.char(0xc3, 0xa9) .. "alm"] ~= nil,
		"valid UTF-8 player and realm bytes must be accepted"
	)

	-- Short local and explicit local realm share one admission identity.
	drainTimers()
	local deliveredBeforeBurst = #sent
	for _ = 1, 5 do
		whisper(nil, "+sr", "Burst")
	end
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
	for i = 1, 20 do
		data["capped-realm"][i] = { rawID = i, itemName = tostring(i) }
	end
	whisper(nil, "+sr [Valid]", "Capped-Realm")
	assertEqual(20, #data["capped-realm"], "per-player reserve cap must reject before mutation")
	for i = 1, 1000 do
		data["player" .. i .. "-realm"] = {}
	end
	whisper(nil, "+sr [Valid]", "Overflow-Realm")
	assertEqual(nil, data["overflow-realm"], "participant cap must reject before mutation")
	data = {}
	for player = 1, 250 do
		local rows = {}
		for item = 1, 20 do
			rows[item] = { rawID = item, itemName = tostring(item) }
		end
		data["full" .. player .. "-realm"] = rows
	end
	whisper(nil, "+sr [Valid]", "Total-Realm")
	assertEqual(nil, data["total-realm"], "total reserve cap must reject before mutation")
	data = {}
	whisper(nil, "+sr [Valid]", "Twin-RealmA")
	whisper(nil, "+sr [Valid]", "Twin-RealmB")
	assertTrue(data["twin-realma"] ~= data["twin-realmb"], "realm-qualified identities must remain distinct")

	data = {}
	for i = 1, 110 do
		whisper(nil, "+sr", "Query" .. i .. "-Realm")
	end
	local deliveredBeforeQueue = #sent
	drainTimers()
	assertTrue(#sent - deliveredBeforeQueue <= 100, "response queue must retain at most 100 queued replies")

	now = 111
	local beforeExpiryReply = #sent
	whisper(nil, "+sr", "Burst-Local Realm")
	drainTimers()
	assertEqual(beforeExpiryReply + 1, #sent, "expired sender must receive a fresh admission")
	for _ = 1, 4 do
		whisper(nil, "+sr", "Burst")
	end
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
		[5] = {
			name = string.rep("N", 63) .. string.char(0xc3, 0xa9),
			content = string.rep("C", 254) .. string.char(0xc3, 0xa9),
		},
		mapped = { name = "  Stack  ", content = "  Stack now  " },
		invalidUtf8 = { name = "Safe", content = "Good" .. string.char(0xff) .. "discard" },
		bad = "not a warning",
	}

	local warningEvents = {}
	local failWarningEvent = false
	addon.L = {
		StrTank = "tank",
		StrHealer = "healer",
		StrMelee = "melee",
		StrRanged = "ranged",
		StrSpammerNeedStr = "need",
		StrConfigRaidWarningPreviewEmpty = "empty",
		StrRaidWarningTemplatePullName = string.rep("T", 63) .. string.char(0xc3, 0xa9),
		StrRaidWarningTemplatePullContent = string.rep("P", 254) .. string.char(0xc3, 0xa9),
	}
	addon.Strings = {
		TrimText = function(value)
			if type(value) ~= "string" then
				return ""
			end
			return value:match("^%s*(.-)%s*$")
		end,
	}
	addon.Database.SavedVariables = {
		GetSpammer = function()
			return spammerStore
		end,
		GetWarnings = function()
			return warningsStore
		end,
	}
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then
			addon.Services[owner][child] = addon.Services[owner][child] or {}
		end
	end
	addon.Events.Internal = { WarningsDataChanged = "WarningsDataChanged" }
	addon.Bus.TriggerEvent = function(_, reason)
		if failWarningEvent then
			error("listener failure")
		end
		local snapshot = {}
		for i = 1, #warningsStore do
			snapshot[i] = { name = warningsStore[i].name, content = warningsStore[i].content }
		end
		warningEvents[#warningEvents + 1] = { reason = reason, warnings = snapshot }
	end
	_G.GetChannelName = function(id)
		if id == 7 then
			return 7, "LookingForGroup"
		end
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
		assertTrue(
			rawequal(normalizedRefs[i], warnings[i]),
			"template insertion must preserve existing row identity " .. i
		)
	end
	local exactWarningName = string.rep("W", 62) .. string.char(0xc3, 0xa9)
	local exactWarningContent = string.rep("Q", 253) .. string.char(0xc3, 0xa9)
	local savedWarning = warningStore.SaveWarning(exactWarningContent, exactWarningName)
	assertEqual(10, savedWarning, "exact-boundary UTF-8 warning must save")
	assertEqual(exactWarningName, warnings[savedWarning].name, "exact-boundary warning name must remain intact")
	assertEqual(
		exactWarningContent,
		warnings[savedWarning].content,
		"exact-boundary warning content must remain intact"
	)
	for i = 1, 4 do
		assertTrue(rawequal(normalizedRefs[i], warnings[i]), "append must preserve existing row identity " .. i)
	end
	local beforeEditRefs = {}
	for i = 1, #warnings do
		beforeEditRefs[i] = warnings[i]
	end
	local editedID = warningStore.SaveWarning("edited content", "Edited exact", savedWarning, true)
	assertEqual(savedWarning, editedID, "valid edit must preserve warning ID")
	for i = 1, savedWarning - 1 do
		assertTrue(rawequal(beforeEditRefs[i], warnings[i]), "edit must preserve unchanged row identity " .. i)
	end
	assertTrue(
		not rawequal(beforeEditRefs[savedWarning], warnings[savedWarning]),
		"edit must replace only the changed row"
	)
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
	for i = 1, #warnings do
		beforeNotificationRefs[i] = warnings[i]
	end
	failWarningEvent = true
	local committedID, committedReason, commitDetail = warningStore.SaveWarning("committed", "Notification contained")
	assertEqual(
		#beforeNotificationRefs + 1,
		committedID,
		"notification failure must not turn a committed save into failure"
	)
	assertEqual(nil, committedReason, "committed save has no mutation failure")
	assertEqual(true, commitDetail.notificationFailed, "save must expose contained notification failure")
	assertTrue(rawequal(stableRoot, warningsStore), "save must preserve SavedVariables root identity")
	for i = 1, #beforeNotificationRefs do
		assertTrue(
			rawequal(beforeNotificationRefs[i], warnings[i]),
			"contained notification failure must preserve row identity " .. i
		)
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
		if
			warning.name == string.rep("T", 63)
			or warning.name == "Spread"
			or warning.name == "Stack"
			or warning.name == "Stop DPS"
			or warning.name == "Bloodlust"
			or warning.name == "Break"
		then
			stockRefs[warning.name] = warning
		end
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
	addon.warn = function(_, message)
		warnings[#warnings + 1] = message
	end
	addon.Services = addon.Services or {}
	addon.Services.Spammer = addon.Services.Spammer or {}
	addon.Services.EnsureNamespace = function()
		return addon.Services.Spammer
	end
	addon.Timer = addon.Timer or {}
	addon.Timer.BindMixin = function(target)
		function target:ScheduleRepeatingTimer(callback)
			local handle = { callback = callback, cancelled = false }
			scheduled[#scheduled + 1] = handle
			return handle
		end
		function target:CancelTimer(handle)
			handle.cancelled = true
			return true
		end
	end
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	local runtime = addon.Services.Spammer.Runtime
	local workingScheduler = runtime.ScheduleRepeatingTimer
	local attempts, terminal = {}, 0
	local ok = runtime:Start({
		duration = 1,
		output = "saved draft",
		channels = { "GUILD", "YELL" },
		sendFn = function(text, channel)
			attempts[#attempts + 1] = text .. ":" .. channel
			return true
		end,
		onTerminal = function()
			terminal = terminal + 1
		end,
	})
	assertEqual(ok, true, "runtime starts")
	for _ = 1, 60 do
		scheduled[1].callback()
	end
	assertEqual(#attempts, 30, "global cap counts destination attempts")
	assertEqual(terminal, 1, "terminal callback fires once")
	assertEqual(runtime:GetState().ticking, false, "cap stops runtime")
	assertEqual(0, #warnings, "runtime owner must not duplicate controller terminal feedback")

	local stale = scheduled[1].callback
	assertEqual(
		runtime:Start({
			duration = 1,
			output = "restart",
			channels = { "GUILD" },
			sendFn = function()
				return true
			end,
		}),
		true,
		"restart"
	)
	stale()
	assertEqual(runtime:GetState().attempts, 0, "stale callback ignored")
	runtime:Stop(true, true)
	assertEqual(runtime:GetState().ticking, false, "explicit stop")

	local clock, sendTimes = 0, {}
	assertEqual(
		runtime:Start({
			duration = 3,
			output = "timed",
			channels = { "GUILD", "YELL" },
			sendFn = function()
				sendTimes[#sendTimes + 1] = clock
				return true
			end,
		}),
		true,
		"timed run starts"
	)
	local timedCallback = scheduled[#scheduled].callback
	for second = 1, 6 do
		clock = second
		timedCallback()
	end
	assertEqual(sendTimes[1], 3, "first destination uses exact interval")
	assertEqual(sendTimes[2], 4, "destinations are throttled")
	assertEqual(sendTimes[3], 6, "cycle interval is measured from first destination")
	assertEqual(runtime:GetState().countdownRemaining, 3, "remaining time advances immediately after send")
	runtime:Stop(true, true)

	local stopTerminal = 0
	assertEqual(
		runtime:Start({
			duration = 1,
			output = "stop",
			channels = { "GUILD" },
			sendFn = function()
				runtime:Stop(true, true)
				return true
			end,
			onTerminal = function()
				stopTerminal = stopTerminal + 1
			end,
		}),
		true,
		"reentrant stop run"
	)
	scheduled[#scheduled].callback()
	assertEqual(runtime:GetState().ticking, false, "send callback stop remains authoritative")
	assertEqual(runtime:GetState().attempts, 0, "stopped run cannot restore reserved attempt")
	assertEqual(stopTerminal, 0, "explicit reentrant stop does not emit terminal callback")

	local replacementTerminal = 0
	assertEqual(
		runtime:Start({
			duration = 1,
			output = "old",
			channels = { "GUILD" },
			sendFn = function()
				return runtime:Start({
					duration = 5,
					output = "replacement",
					channels = { "YELL" },
					sendFn = function()
						return true
					end,
					onTerminal = function()
						replacementTerminal = replacementTerminal + 1
					end,
				})
			end,
		}),
		true,
		"reentrant replacement run"
	)
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
	assertEqual(
		runtime:Start({
			duration = 1,
			output = "false",
			channels = { "GUILD" },
			sendFn = function()
				return false
			end,
			onTerminal = function(reason)
				failureReasons[#failureReasons + 1] = reason
			end,
		}),
		true,
		"false transport run"
	)
	scheduled[#scheduled].callback()
	assertEqual("send_failed", failureReasons[1], "false transport terminates run")
	assertEqual(1, runtime:GetState().attempts, "false transport counts the actual attempt")
	assertEqual(0, runtime:GetState().messagesSent, "failed transport must not count as delivered")
	assertEqual(
		runtime:Start({
			duration = 1,
			output = "nil",
			channels = { "GUILD" },
			sendFn = function()
				return nil
			end,
			onTerminal = function(reason)
				failureReasons[#failureReasons + 1] = reason
			end,
		}),
		true,
		"nil transport run"
	)
	scheduled[#scheduled].callback()
	assertEqual("send_failed", failureReasons[2], "nil transport result must not report success")
	assertEqual(
		runtime:Start({
			duration = 1,
			output = "throw",
			channels = { "GUILD" },
			sendFn = function()
				error("transport")
			end,
			onTerminal = function(reason)
				failureReasons[#failureReasons + 1] = reason
			end,
		}),
		true,
		"throwing transport run"
	)
	scheduled[#scheduled].callback()
	assertEqual("send_failed", failureReasons[3], "throwing transport terminates run")
	assertEqual(3, #failureReasons, "each failed run emits terminal callback once")
	assertEqual(0, #warnings, "send failures emit no runtime-owner user feedback")
	local destinationAvailable = true
	assertEqual(
		runtime:Start({
			duration = 1,
			output = "transition",
			channels = { "GUILD", "YELL" },
			sendFn = function(_, destination)
				if destination == "GUILD" then
					destinationAvailable = false
					return true
				end
				return destinationAvailable
			end,
			onTerminal = function(reason)
				failureReasons[#failureReasons + 1] = reason
			end,
		}),
		true,
		"channel transition run"
	)
	local transitionCallback = scheduled[#scheduled].callback
	transitionCallback()
	transitionCallback()
	assertEqual("send_failed", failureReasons[4], "destination transition terminates through injected transport result")
	assertEqual(2, runtime:GetState().attempts, "transition counts both destination attempts")
	assertEqual(1, runtime:GetState().messagesSent, "transition counts only confirmed deliveries")
	assertEqual(0, #warnings, "destination transition emits no runtime-owner user feedback")

	assertEqual(
		runtime:Start({
			duration = 999,
			output = "duration",
			channels = { "GUILD" },
			sendFn = function()
				return true
			end,
		}),
		true,
		"duration cap run"
	)
	local durationCallback = scheduled[#scheduled].callback
	for _ = 1, 1800 do
		durationCallback()
	end
	assertEqual(0, #warnings, "duration cap feedback belongs to controller")
	runtime:Stop(true, true)
	assertEqual(0, #warnings, "explicit stop emits no runtime-owner user feedback")

	runtime.ScheduleRepeatingTimer = function()
		return nil
	end
	local failed = runtime:Start({ duration = 1, output = "fail", channels = { "GUILD" } })
	assertEqual(failed, false, "nil scheduler fails atomically")
	assertEqual(runtime:GetState().ticking, false, "failed start does not tick")
	runtime.ScheduleRepeatingTimer = function()
		error("scheduler unavailable")
	end
	failed = runtime:Start({
		duration = 0,
		output = "fail",
		channels = { "GUILD" },
		sendFn = function()
			return true
		end,
	})
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
	addon.Services.EnsureNamespace = function()
		return addon.Services.Spammer
	end
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleRepeatingTimer(callback)
				local handle = { callback = callback }
				scheduled[#scheduled + 1] = handle
				return handle
			end
			function target:CancelTimer()
				return true
			end
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	local runtime = addon.Services.Spammer.Runtime

	local callOk, started = pcall(runtime.Start, runtime, {
		duration = 1,
		output = "callback",
		channels = { "GUILD" },
		sendFn = function()
			return true
		end,
		onTick = function()
			error("tick start")
		end,
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
	assertEqual(
		true,
		runtime:Start({
			duration = 1,
			output = "failure",
			channels = { "GUILD" },
			sendFn = function()
				return nil, "not_in_guild"
			end,
			onTerminal = function(reason)
				terminalReason = reason
				error("terminal callback")
			end,
		}),
		"terminal callback containment run must start"
	)
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
		StrTank = "tank",
		StrHealer = "healer",
		StrMelee = "melee",
		StrRanged = "ranged",
		StrSpammerNeedStr = "need",
		BtnResume = "Resume",
		BtnStop = "Stop",
		BtnStart = "Start",
		ErrSpammerRuntime = "spammer failed: %s",
		MsgSpammerAutoStopDuration = "duration %d",
		MsgSpammerAutoStopMessages = "messages %d",
		WarnSpammerCallbackFailed = "callback failed: %s",
	}
	addon.error = function(_, message, reason)
		errors[#errors + 1] = string.format(message, reason)
	end
	addon.info = function(_, message)
		infos[#infos + 1] = message
	end
	addon.warn = function() end
	addon.Strings = {
		TrimText = function(value)
			return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
		end,
	}
	addon.Database.SavedVariables = {
		GetSpammer = function()
			return store
		end,
	}
	addon.Database.RequireServiceMethod = function(_, owner, method)
		return assert(owner[method])
	end
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then
			addon.Services[owner][child] = addon.Services[owner][child] or {}
		end
	end
	addon.Services.Chat = {
		SendSpamOutput = function()
			return nil, "not_in_guild"
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleRepeatingTimer()
				return nil
			end
			function target:CancelTimer()
				return true
			end
		end,
	}
	addon.Controllers = {}
	addon.UI = {
		Frames = {
			MakeModuleFrameGetter = function()
				return function()
					return nil
				end
			end,
		},
		ModuleState = {
			Ensure = function()
				return {}
			end,
		},
		Scaffold = { DefineModule = function() end },
		Primitives = { SetEnabled = function() end },
		EditBoxes = {},
		Tooltips = {},
	}
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
	addon.L = {
		StrTank = "tank",
		StrHealer = "healer",
		StrMelee = "melee",
		StrRanged = "ranged",
		StrSpammerNeedStr = "need",
		MsgSpammerAutoStopDuration = "duration %d",
		MsgSpammerAutoStopMessages = "messages %d",
	}
	addon.warn = function(_, message)
		warnings[#warnings + 1] = message
	end
	addon.Strings = {
		TrimText = function(value)
			return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
		end,
	}
	addon.Database.SavedVariables = {
		GetSpammer = function()
			return store
		end,
	}
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then
			addon.Services[owner][child] = addon.Services[owner][child] or {}
		end
	end
	addon.Services.Chat = {
		SendSpamOutput = function(_, output, channels)
			sent[#sent + 1] = { output = output, channel = channels[1] }
			return true
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleRepeatingTimer(callback)
				local handle = { callback = callback }
				scheduled[#scheduled + 1] = handle
				return handle
			end
			function target:CancelTimer()
				return true
			end
		end,
	}
	loadAddonFile(addon, "Raid Management Addon/Modules/Strings.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Draft.lua")
	loadAddonFile(addon, "Raid Management Addon/Services/Spammer/Runtime.lua")
	local draft = addon.Services.Spammer.Draft
	local runtime = addon.Services.Spammer.Runtime
	local preview = draft.BuildPreview(draft.GetStore(), draft.GetDefaultOutput())
	assertTrue(preview.output ~= "LFM", "saved draft must produce non-default headless output")
	assertEqual(
		runtime:Start({
			duration = preview.duration,
			output = preview.output,
			channels = draft.GetChannels(store),
			resetCountdown = true,
			resetRun = true,
		}),
		true,
		"runtime owner starts headless run"
	)
	scheduled[1].callback()
	assertEqual(0, #sent, "headless start respects saved duration")
	scheduled[1].callback()
	assertEqual(preview.output, sent[1].output, "headless send uses canonical saved preview")
	assertEqual("GUILD", sent[1].channel, "headless send uses stable saved destination")
	runtime:Stop(true, true)
	assertEqual(
		runtime:Start({ duration = 1, output = preview.output, channels = { "GUILD", "YELL" }, resetRun = true }),
		true,
		"runtime cap run"
	)
	local capCallback = scheduled[#scheduled].callback
	for _ = 1, 60 do
		capCallback()
	end
	assertEqual(0, #warnings, "headless runtime cap must not bypass controller feedback ownership")
	assertEqual(
		runtime:Start({ duration = 999, output = preview.output, channels = { "GUILD" }, resetRun = true }),
		true,
		"runtime duration run"
	)
	local durationCallback = scheduled[#scheduled].callback
	for _ = 1, 1800 do
		durationCallback()
	end
	assertEqual(0, #warnings, "headless runtime duration cap must not emit duplicate user feedback")
	print("PASS headless_spammer_uses_saved_draft_through_runtime_owner")
end

function cases.controller_request_start_uses_saved_draft_without_frame(addon)
	local store = { Name = "Ulduar 25", Healer = 2, Message = "hard modes", Duration = "1", Channels = { "GUILD" } }
	local scheduled, sent, enabledStates = {}, {}, {}
	addon.L =
		{ StrTank = "tank", StrHealer = "healer", StrMelee = "melee", StrRanged = "ranged", StrSpammerNeedStr = "need" }
	addon.Strings = {
		TrimText = function(value)
			return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
		end,
	}
	addon.Database.SavedVariables = {
		GetSpammer = function()
			return store
		end,
	}
	addon.Database.RequireServiceMethod = function(_, owner, method)
		return assert(owner[method])
	end
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then
			addon.Services[owner][child] = addon.Services[owner][child] or {}
		end
	end
	addon.Services.Chat = {
		SendSpamOutput = function(_, output, channels)
			sent[#sent + 1] = { output = output, channel = channels[1] }
			return true
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleRepeatingTimer(callback)
				local handle = { callback = callback }
				scheduled[#scheduled + 1] = handle
				return handle
			end
			function target:CancelTimer()
				return true
			end
		end,
	}
	addon.Controllers = {}
	addon.UI = {
		Frames = {
			MakeModuleFrameGetter = function()
				return function()
					return nil
				end
			end,
		},
		ModuleState = {
			Ensure = function()
				return {}
			end,
		},
		Scaffold = { DefineModule = function() end },
		Primitives = {
			SetEnabled = function(_, enabled)
				enabledStates[#enabledStates + 1] = enabled
			end,
		},
		EditBoxes = {},
		Tooltips = {},
	}
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
		StrTank = "tank",
		StrHealer = "healer",
		StrMelee = "melee",
		StrRanged = "ranged",
		StrSpammerNeedStr = "need",
		BtnResume = "Resume",
		BtnStop = "Stop",
		BtnStart = "Start",
	}
	addon.Strings = {
		TrimText = function(value)
			return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
		end,
	}
	addon.Database.SavedVariables = {
		GetSpammer = function()
			return store
		end,
	}
	addon.Database.RequireServiceMethod = function(_, owner, method)
		return assert(owner[method])
	end
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then
			addon.Services[owner][child] = addon.Services[owner][child] or {}
		end
	end
	addon.Services.Chat = {
		SendSpamOutput = function(_, output, channels)
			sent[#sent + 1] = { output = output, channel = channels[1] }
			return true
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleRepeatingTimer(callback)
				local handle = { callback = callback }
				scheduled[#scheduled + 1] = handle
				return handle
			end
			function target:CancelTimer()
				return true
			end
		end,
	}
	addon.Controllers = {}
	local function newControl(text)
		return {
			text = text or "",
			checked = false,
			GetText = function(self)
				return self.text
			end,
			SetText = function(self, value)
				self.text = tostring(value or "")
			end,
			SetTextColor = function() end,
			SetMaxLetters = function() end,
			SetAlpha = function() end,
			SetEnabled = function() end,
			ClearFocus = function() end,
			GetChecked = function(self)
				return self.checked
			end,
			SetChecked = function(self, value)
				self.checked = value == true
			end,
		}
	end
	local frame = {
		shown = true,
		IsShown = function(self)
			return self.shown
		end,
	}
	local suffixes = {
		"Name",
		"Duration",
		"Tank",
		"TankClass",
		"Healer",
		"HealerClass",
		"Melee",
		"MeleeClass",
		"Ranged",
		"RangedClass",
		"Message",
		"Output",
		"Length",
		"Tick",
		"StartBtn",
		"ClearBtn",
		"ChatGuild",
		"ChatYell",
	}
	for i = 1, #suffixes do
		_G["RMASpammer" .. suffixes[i]] = newControl()
	end
	for i = 1, 8 do
		_G["RMASpammerChat" .. i] = newControl()
	end
	addon.UI = {
		Frames = {
			MakeModuleFrameGetter = function()
				return function()
					return currentFrame
				end
			end,
			BindModuleFrame = function()
				currentFrame = frame
				return "RMASpammer"
			end,
			GetRef = function(_, suffix)
				return _G["RMASpammer" .. suffix]
			end,
			SetScriptSafely = function() end,
		},
		ModuleState = {
			Ensure = function()
				return { Localized = true }
			end,
		},
		Scaffold = {
			DefineModule = function(spec)
				scaffoldSpec = spec
				spec.module.RequestRefresh = function()
					spec.refresh()
				end
			end,
		},
		Primitives = { SetEnabled = function() end, SetText = function() end },
		EditBoxes = {
			Reset = function(box)
				if box then
					box:SetText("")
				end
			end,
		},
		Tooltips = {},
	}
	_G.GetChannelName = function()
		return 0, nil
	end

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
	assertEqual(
		false,
		addon.Services.Spammer.Runtime:GetState().ticking,
		"later headless start must use cleared canonical draft"
	)
	assertEqual(1, #scheduled, "cleared canonical draft must not schedule a replacement run")
	print("PASS spammer_clear_invalidates_ui_without_mutating_active_snapshot")
end

function cases.spammer_frame_binding_applies_uncached_clear_state(addon)
	local function installFixture(target, store)
		local scheduled, sent, currentFrame, scaffoldSpec = {}, {}, nil, nil
		target.L = {
			StrTank = "tank",
			StrHealer = "healer",
			StrMelee = "melee",
			StrRanged = "ranged",
			StrSpammerNeedStr = "need",
			BtnResume = "Resume",
			BtnStop = "Stop",
			BtnStart = "Start",
		}
		target.Strings = {
			TrimText = function(value)
				return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
			end,
		}
		target.Database.SavedVariables = {
			GetSpammer = function()
				return store
			end,
		}
		target.Database.RequireServiceMethod = function(_, owner, method)
			return assert(owner[method])
		end
		target.Services.EnsureNamespace = function(owner, child)
			target.Services[owner] = target.Services[owner] or {}
			if child then
				target.Services[owner][child] = target.Services[owner][child] or {}
			end
		end
		target.Services.Chat = {
			SendSpamOutput = function(_, output, channels)
				sent[#sent + 1] = { output = output, channel = channels[1] }
				return true
			end,
		}
		target.Timer = {
			BindMixin = function(owner)
				function owner:ScheduleRepeatingTimer(callback)
					local handle = { callback = callback }
					scheduled[#scheduled + 1] = handle
					return handle
				end
				function owner:CancelTimer()
					return true
				end
			end,
		}
		target.Controllers = {}

		local function newControl(text)
			return {
				text = text or "",
				checked = false,
				enabled = true,
				GetText = function(self)
					return self.text
				end,
				SetText = function(self, value)
					self.text = tostring(value or "")
				end,
				SetTextColor = function() end,
				SetMaxLetters = function() end,
				SetAlpha = function() end,
				SetEnabled = function(self, enabled)
					self.enabled = enabled == true
				end,
				ClearFocus = function() end,
				GetChecked = function(self)
					return self.checked
				end,
				SetChecked = function(self, value)
					self.checked = value == true
				end,
			}
		end
		local function bindFrame()
			local frame = {
				shown = true,
				IsShown = function(self)
					return self.shown
				end,
			}
			local suffixes = {
				"Name",
				"Duration",
				"Tank",
				"TankClass",
				"Healer",
				"HealerClass",
				"Melee",
				"MeleeClass",
				"Ranged",
				"RangedClass",
				"Message",
				"Output",
				"Length",
				"Tick",
				"StartBtn",
				"ClearBtn",
				"ChatGuild",
				"ChatYell",
			}
			for i = 1, #suffixes do
				_G["RMASpammer" .. suffixes[i]] = newControl()
			end
			for i = 1, 8 do
				_G["RMASpammerChat" .. i] = newControl()
			end
			currentFrame = frame
			scaffoldSpec.onLoad(frame)
			target.Controllers.Spammer:RequestRefresh()
			return frame
		end

		target.UI = {
			Frames = {
				MakeModuleFrameGetter = function()
					return function()
						return currentFrame
					end
				end,
				BindModuleFrame = function(_, frame)
					currentFrame = frame
					return "RMASpammer"
				end,
				GetRef = function(_, suffix)
					return _G["RMASpammer" .. suffix]
				end,
				SetScriptSafely = function() end,
			},
			ModuleState = {
				Ensure = function()
					return { Localized = true }
				end,
			},
			Scaffold = {
				DefineModule = function(spec)
					scaffoldSpec = spec
					spec.module.RequestRefresh = function()
						spec.refresh()
					end
				end,
			},
			Primitives = {
				SetEnabled = function(control, enabled)
					if control then
						control.enabled = enabled == true
					end
				end,
				SetText = function(control, activeText, defaultText, active)
					if control then
						control:SetText(active and activeText or defaultText)
					end
				end,
			},
			EditBoxes = {
				Reset = function(box)
					if box then
						box:SetText("")
					end
				end,
			},
			Tooltips = {},
		}
		target.WithinRange = function(value, minimum, maximum)
			return value >= minimum and value <= maximum
		end
		_G.GetChannelName = function()
			return 0, nil
		end
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
	assertTrue(
		activeFixture.sent[1].output:find("active headless", 1, true) ~= nil,
		"active output snapshot must survive clear"
	)
	assertTrue(
		activeFixture.sent[1].output:find("snapshot", 1, true) ~= nil,
		"active message snapshot must survive clear"
	)
	activeAddon.Services.Spammer.Runtime:Pause()
	activeAddon.Controllers.Spammer:RequestRefresh()
	assertEqual(true, _G.RMASpammerStartBtn.enabled, "paused clear must keep Resume enabled")
	assertEqual("Resume", _G.RMASpammerStartBtn:GetText(), "paused clear must render Resume action")
	activeAddon.Controllers.Spammer:RequestStart()
	assertEqual(
		false,
		activeAddon.Services.Spammer.Runtime:GetState().paused,
		"Resume action must work with cleared draft"
	)
	activeAddon.Controllers.Spammer:RequestStart()
	assertEqual(
		false,
		activeAddon.Services.Spammer.Runtime:GetState().ticking,
		"Stop action must work with cleared draft"
	)
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
		StrTank = "tank",
		StrHealer = "healer",
		StrMelee = "melee",
		StrRanged = "ranged",
		StrSpammerNeedStr = "need",
		StrSpammerChannelUnavailable = "%s (unavailable)",
		StrChannels = "Channels",
		BtnResume = "Resume",
		BtnStop = "Stop",
		BtnStart = "Start",
	}
	addon.Strings = {
		TrimText = function(value)
			return type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
		end,
	}
	addon.Database.SavedVariables = {
		GetSpammer = function()
			return store
		end,
	}
	addon.Database.RequireServiceMethod = function(_, owner, method)
		return assert(owner[method])
	end
	addon.Services.EnsureNamespace = function(owner, child)
		addon.Services[owner] = addon.Services[owner] or {}
		if child then
			addon.Services[owner][child] = addon.Services[owner][child] or {}
		end
	end
	addon.Services.Chat = {
		SendSpamOutput = function()
			return true
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			function target:ScheduleRepeatingTimer()
				return {}
			end
			function target:CancelTimer()
				return true
			end
		end,
	}
	addon.Controllers = {}

	local function newControl()
		return {
			text = "",
			enabled = true,
			GetText = function(self)
				return self.text
			end,
			SetText = function(self, value)
				self.text = tostring(value or "")
			end,
			SetTextColor = function() end,
			SetMaxLetters = function() end,
			SetAlpha = function() end,
			ClearFocus = function() end,
			SetEnabled = function(self, enabled)
				self.enabled = enabled == true
			end,
		}
	end
	local frame = {
		shown = true,
		IsShown = function(self)
			return self.shown
		end,
	}
	local suffixes = {
		"Name",
		"Duration",
		"Tank",
		"TankClass",
		"Healer",
		"HealerClass",
		"Melee",
		"MeleeClass",
		"Ranged",
		"RangedClass",
		"Message",
		"Output",
		"Length",
		"Tick",
		"StartBtn",
		"ClearBtn",
		"ChannelMenu",
	}
	for i = 1, #suffixes do
		_G["RMASpammer" .. suffixes[i]] = newControl()
	end
	addon.UI = {
		Frames = {
			MakeModuleFrameGetter = function()
				return function()
					return currentFrame
				end
			end,
			BindModuleFrame = function()
				currentFrame = frame
				return "RMASpammer"
			end,
			GetRef = function(_, suffix)
				return _G["RMASpammer" .. suffix]
			end,
			SetScriptSafely = function() end,
		},
		ModuleState = {
			Ensure = function()
				return { Localized = true }
			end,
		},
		Scaffold = {
			DefineModule = function(spec)
				scaffoldSpec = spec
				spec.module.RequestRefresh = function()
					spec.refresh()
				end
			end,
		},
		Primitives = {
			SetEnabled = function(control, enabled)
				if control then
					control.enabled = enabled == true
				end
			end,
			SetText = function() end,
		},
		EditBoxes = {
			Reset = function(box)
				if box then
					box:SetText("")
				end
			end,
		},
		Tooltips = {},
	}
	_G.GetChannelList = function()
		return 2, "Trade", 7, "LookingForGroup"
	end
	_G.IsInGuild = function()
		return false
	end
	_G.UIDropDownMenu_Initialize = function(menu, initialize)
		menu.initialize = initialize
	end
	_G.UIDropDownMenu_CreateInfo = function()
		return {}
	end
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
	_G.UIDropDownMenu_DisableDropDown = function(menu)
		menu.enabled = false
	end
	_G.UIDropDownMenu_EnableDropDown = function(menu)
		menu.enabled = true
	end
	_G.UIDropDownMenu_SetWidth = function(menu, width, padding)
		menu.dropdownWidth = width
		menu.dropdownPadding = padding
		menu.dropdownOuterWidth = width + (padding or 50)
	end
	_G.UIDropDownMenu_SetText = function(menu, text)
		menu.dropdownText = text
	end

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
	assertEqual(
		normalizationCallCount + 1,
		#setChannelCalls,
		"first live channel click must update saved preferences once"
	)
	assertEqual(
		"LookingForGroup",
		setChannelCalls[normalizationCallCount + 1].channel,
		"live channel click target differs"
	)
	assertEqual(
		true,
		setChannelCalls[normalizationCallCount + 1].checked,
		"live channel click must add an unchecked choice"
	)
	assertSameChannels({ "Trade", "LookingForGroup" }, draft.GetChannels(store), "live click did not add channel")
	lookingForGroup.click(false)
	assertEqual(
		normalizationCallCount + 2,
		#setChannelCalls,
		"second live channel click must update saved preferences once"
	)
	assertEqual(
		false,
		setChannelCalls[normalizationCallCount + 2].checked,
		"second live channel click must remove the kept-open choice"
	)
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
	_G.GetChannelList = function()
		error("channel discovery failed")
	end
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
		if message == "throw" then
			error("chat unavailable")
		end
		if message == "false" then
			return false
		end
		sent[#sent + 1] = { message = message, channel = channel, target = target }
		return nil
	end
	_G.GetAddOnMetadata = function()
		return "test"
	end
	_G.UnitName = function()
		return "Tester"
	end
	_G.IsInInstance = function()
		return false, "none"
	end
	_G.GetNumRaidMembers = function()
		return raidCount
	end
	_G.GetNumPartyMembers = function()
		return partyCount
	end
	_G.GetChannelList = function()
		return unpack(channelRows)
	end
	_G.GetChannelName = function(name)
		for i = 1, #channelRows, 2 do
			if string.lower(tostring(channelRows[i + 1])) == string.lower(tostring(name)) then
				return channelRows[i], channelRows[i + 1]
			end
		end
		return 0, nil
	end
	_G.IsInGuild = function()
		return inGuild
	end
	_G.GetGuildInfo = function()
		return "Officer", "Officer", 1
	end
	_G.GuildControlGetRankFlags = function()
		return true, true, true, officerSpeak
	end
	addon.L = {}
	addon.C = { CHAT_OUTPUT_FORMAT = "%s", CHAT_PREFIX_SHORT = "RMA", CHAT_PREFIX_HEX = "" }
	addon.Database.GetSyncer = function()
		return nil
	end
	addon.Database.GetRaidSchemaVersion = function()
		return 1
	end
	addon.Database.GetUnitRank = function()
		return unitRank
	end
	addon.Strings = {
		NormalizeName = function(value)
			return value
		end,
		TrimText = function(value)
			return value
		end,
		FormatChatMessage = function(value)
			return value
		end,
	}
	addon.Timer = {
		BindMixin = function(target)
			target.ScheduleTimer = function()
				return {}
			end
		end,
	}
	addon.Services.EnsureNamespace = function(name)
		addon.Services[name] = addon.Services[name] or {}
	end
	addon.Deformat = function()
		return nil
	end
	addon.Options = {
		GetValue = function()
			return false
		end,
	}
	addon.Group = {
		GetTypeAndCount = function()
			if raidCount > 0 then
				return "raid", 1, raidCount
			end
			if partyCount > 0 then
				return "party", 0, partyCount
			end
			return nil, 0, 0
		end,
	}
	local localPrints = 0
	addon.info = function()
		localPrints = localPrints + 1
	end
	_G.LibStub = function(name)
		if name == "LibSerialize" or name == "LibDeflate" then
			return {}
		end
	end
	_G.ChatThrottleLib = {
		SendAddonMessage = function() end,
		SendChatMessage = function(_, _, _, message, destination, language, target)
			return _G.SendChatMessage(message, destination, language, target)
		end,
	}
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
	addon.Services.Chat.Announce = function()
		return nil, "send_failed"
	end
	ok, reason = addon.Services.Chat:AnnounceWarningMessage("warning")
	assertEqual(nil, ok, "warning facade must propagate announcement failure")
	assertEqual("send_failed", reason, "warning facade failure reason differs")
	print("PASS chat_delivery_uses_live_destinations_and_reports_failures")
end
