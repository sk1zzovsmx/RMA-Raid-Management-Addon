-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: owns spammer UI scripts; Services.Spammer.Runtime owns lifecycle state
-- notes: Services.Chat owns spam transport and announcement policy
local addon = select(2, ...)
local L = addon.L
local Controllers = addon.Controllers
local Database = addon.Database

local UI = addon.UI
local Frames = UI.Frames
local Scaffold = UI.Scaffold
local Primitives = UI.Primitives
local EditBoxes = UI.EditBoxes
local Tooltips = UI.Tooltips
local Strings = addon.Strings
local Services = addon.Services

local SpammerSvc = assert(Services.Spammer, "Spammer controller service namespace is not initialized")

local _G = _G
local pairs, ipairs, type, select = pairs, ipairs, type, select
local find, strlen = string.find, string.len
local gsub = string.gsub
local tostring, tonumber = tostring, tonumber

local requireServiceMethod = Database.RequireServiceMethod

assert(Services.Chat, "Spammer controller chat service is not initialized")
local DraftSvc = assert(SpammerSvc.Draft, "Spammer controller draft service is not initialized")
local RuntimeSvc = assert(SpammerSvc.Runtime, "Spammer controller runtime service is not initialized")
local GetRuntimeState = requireServiceMethod("Spammer.Runtime", RuntimeSvc, "GetState")
local StartRuntime = requireServiceMethod("Spammer.Runtime", RuntimeSvc, "Start")
local StopRuntime = requireServiceMethod("Spammer.Runtime", RuntimeSvc, "Stop")
local PauseRuntime = requireServiceMethod("Spammer.Runtime", RuntimeSvc, "Pause")
local Draft = {
	GetDefaultDuration = requireServiceMethod("Spammer.Draft", DraftSvc, "GetDefaultDuration"),
	GetDefaultOutput = requireServiceMethod("Spammer.Draft", DraftSvc, "GetDefaultOutput"),
	GetStore = requireServiceMethod("Spammer.Draft", DraftSvc, "GetStore"),
	GetChannels = requireServiceMethod("Spammer.Draft", DraftSvc, "GetChannels"),
	SetField = requireServiceMethod("Spammer.Draft", DraftSvc, "SetField"),
	SetChannelChecked = requireServiceMethod("Spammer.Draft", DraftSvc, "SetChannelChecked"),
	BuildOutput = requireServiceMethod("Spammer.Draft", DraftSvc, "BuildOutput"),
	BuildPreview = requireServiceMethod("Spammer.Draft", DraftSvc, "BuildPreview"),
	ClearDraft = requireServiceMethod("Spammer.Draft", DraftSvc, "ClearDraft"),
}

-- =========== LFM Spam Module  =========== --
do
	Controllers.Spammer = Controllers.Spammer or {}
	local module = Controllers.Spammer
	local uiState = UI.ModuleState.Ensure(module)
	-- ----- Internal state ----- --

	local getFrame = Frames.MakeModuleFrameGetter(module, "RMASpammer")
	-- Defaults / constants
	local DEFAULT_DURATION_STR = Draft.GetDefaultDuration()
	local DEFAULT_OUTPUT = Draft.GetDefaultOutput()

	-- Runtime state
	local loaded = false

	-- Duration kept as string for coherence with EditBox/SV
	local duration = DEFAULT_DURATION_STR

	local finalOutput = DEFAULT_OUTPUT

	local inputsLocked = false
	local inputsAppliedFrame = nil
	local previewDirty = true

	local inputFields = {
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
	}

	local resetFields = {
		"Name",
		"Tank",
		"TankClass",
		"Healer",
		"HealerClass",
		"Melee",
		"MeleeClass",
		"Ranged",
		"RangedClass",
		"Message",
	}

	local previewFields = {
		{ key = "name", box = "Name" },
		{ key = "tank", box = "Tank", number = true },
		{ key = "tankClass", box = "TankClass" },
		{ key = "healer", box = "Healer", number = true },
		{ key = "healerClass", box = "HealerClass" },
		{ key = "melee", box = "Melee", number = true },
		{ key = "meleeClass", box = "MeleeClass" },
		{ key = "ranged", box = "Ranged", number = true },
		{ key = "rangedClass", box = "RangedClass" },
		{ key = "message", box = "Message" },
	}

	local lastControls = {
		locked = nil,
		canStart = nil,
		btnLabel = nil,
		isStop = nil,
	}

	local lastState = {
		name = nil,
		tank = 0,
		tankClass = nil,
		healer = 0,
		healerClass = nil,
		melee = 0,
		meleeClass = nil,
		ranged = 0,
		rangedClass = nil,
		message = nil,
		duration = nil, -- string
	}
	-- Forward declarations
	local renderPreview
	local updateControls
	local updateTickDisplay
	local setInputsLocked
	local saveSpammer
	local startSpam
	local stopSpam
	local pauseSpam
	local focusTab
	local clearSpammer

	-- ----- Private helpers ----- --
	function uiState.AcquireRefs(frame)
		local refs = {
			clearBtn = Frames.GetRef(frame, "ClearBtn"),
			startBtn = Frames.GetRef(frame, "StartBtn"),
			duration = Frames.GetRef(frame, "Duration"),
			healer = Frames.GetRef(frame, "Healer"),
			healerClass = Frames.GetRef(frame, "HealerClass"),
			melee = Frames.GetRef(frame, "Melee"),
			meleeClass = Frames.GetRef(frame, "MeleeClass"),
			message = Frames.GetRef(frame, "Message"),
			name = Frames.GetRef(frame, "Name"),
			ranged = Frames.GetRef(frame, "Ranged"),
			rangedClass = Frames.GetRef(frame, "RangedClass"),
			tank = Frames.GetRef(frame, "Tank"),
			tankClass = Frames.GetRef(frame, "TankClass"),
			chatGuild = Frames.GetRef(frame, "ChatGuild"),
			chatYell = Frames.GetRef(frame, "ChatYell"),
			channels = {},
		}
		for i = 1, 8 do
			refs.channels[i] = Frames.GetRef(frame, "Chat" .. i)
		end
		return refs
	end

	-- Small helpers
	local function resetLastState()
		lastState.name = nil
		lastState.tank = 0
		lastState.tankClass = nil
		lastState.healer = 0
		lastState.healerClass = nil
		lastState.melee = 0
		lastState.meleeClass = nil
		lastState.ranged = 0
		lastState.rangedClass = nil
		lastState.message = nil
		lastState.duration = nil
	end

	local function getNamedPart(suffix)
		local frameName = uiState.FrameName
		if not frameName then
			return nil
		end
		return _G[frameName .. suffix]
	end

	local function setCheckbox(suffix, checked)
		local chk = getNamedPart(suffix)
		if chk and chk.SetChecked then
			chk:SetChecked(checked and true or false)
		end
	end

	local function resetAllChannelCheckboxes()
		for i = 1, 8 do
			setCheckbox("Chat" .. i, false)
		end
		setCheckbox("ChatGuild", false)
		setCheckbox("ChatYell", false)
	end

	-- Deterministic: sync Duration immediately from UI/SV (no waiting for preview tick)
	local function syncDurationNow()
		local value
		local frame = getFrame()
		local store = Draft.GetStore()

		if frame and frame:IsShown() then
			local box = getNamedPart("Duration")
			if box then
				value = box:GetText()
				if value == "" then
					value = DEFAULT_DURATION_STR
					box:SetText(value)
				end
				value = tostring(value)
			end
		end

		if not value or value == "" then
			value = store.Duration or DEFAULT_DURATION_STR
			value = tostring(value)
		end

		duration = value
		lastState.duration = value
		store.Duration = value
	end

	-- Deterministic: ensure preview/output is computed before Start/Resume
	local function ensureReadyForStart()
		syncDurationNow()

		local frame = getFrame()
		if frame and frame:IsShown() then
			if previewDirty or not finalOutput or finalOutput == "" then
				renderPreview()
				previewDirty = false
			end
		else
			local preview = Draft.BuildPreview(Draft.GetStore(), DEFAULT_OUTPUT)
			finalOutput = preview.output
			duration = preview.duration
		end
	end

	local function resetLengthUI()
		local frame = getFrame()
		if not frame then
			return
		end
		local len = strlen(DEFAULT_OUTPUT)
		local lenStr = len .. "/255"

		local out = getNamedPart("Output")
		if out then
			out:SetText(DEFAULT_OUTPUT)
		end

		local lengthText = getNamedPart("Length")
		if lengthText then
			lengthText:SetText(lenStr)
			lengthText:SetTextColor(0.5, 0.5, 0.5)
		end

		local msg = getNamedPart("Message")
		if msg and msg.SetMaxLetters then
			msg:SetMaxLetters(255)
		end
	end

	local function requestRefresh()
		if module.RequestRefresh then
			module:RequestRefresh()
		end
	end

	-- ----- Public methods ----- --
	local function loadSpammerFrame(frame)
		uiState.FrameName = Frames.BindModuleFrame(module, frame, {
			enableDrag = true,
			hookOnShow = function()
				requestRefresh()
			end,
		}) or uiState.FrameName
		uiState.Loaded = uiState.FrameName ~= nil
		if not uiState.Loaded then
			return
		end

		if frame:IsShown() then
			requestRefresh()
		end
	end

	local function BindHandlers(_, _, refs)
		Frames.SetScriptSafely(refs.clearBtn, "OnClick", function()
			clearSpammer()
		end)
		Frames.SetScriptSafely(refs.startBtn, "OnClick", function()
			startSpam()
		end)

		Frames.SetScriptSafely(refs.duration, "OnTabPressed", function()
			focusTab("Tank", "Name")
		end)
		Frames.SetScriptSafely(refs.healer, "OnTabPressed", function()
			focusTab("HealerClass", "TankClass")
		end)
		Frames.SetScriptSafely(refs.healerClass, "OnTabPressed", function()
			focusTab("Melee", "Healer")
		end)
		Frames.SetScriptSafely(refs.melee, "OnTabPressed", function()
			focusTab("MeleeClass", "HealerClass")
		end)
		Frames.SetScriptSafely(refs.meleeClass, "OnTabPressed", function()
			focusTab("Ranged", "Melee")
		end)
		Frames.SetScriptSafely(refs.message, "OnTabPressed", function()
			focusTab("Name", "RangedClass")
		end)
		Frames.SetScriptSafely(refs.name, "OnTabPressed", function()
			focusTab("Duration", "Message")
		end)
		Frames.SetScriptSafely(refs.ranged, "OnTabPressed", function()
			focusTab("RangedClass", "MeleeClass")
		end)
		Frames.SetScriptSafely(refs.rangedClass, "OnTabPressed", function()
			focusTab("Message", "Ranged")
		end)
		Frames.SetScriptSafely(refs.tank, "OnTabPressed", function()
			focusTab("TankClass", "Duration")
		end)
		Frames.SetScriptSafely(refs.tankClass, "OnTabPressed", function()
			focusTab("Healer", "Tank")
		end)

		for i = 1, #refs.channels do
			local channelBox = refs.channels[i]
			Frames.SetScriptSafely(channelBox, "OnClick", function(self, button)
				saveSpammer(self, button)
			end)
		end
		Frames.SetScriptSafely(refs.chatGuild, "OnClick", function(self, button)
			saveSpammer(self, button)
		end)
		Frames.SetScriptSafely(refs.chatYell, "OnClick", function(self, button)
			saveSpammer(self, button)
		end)
	end

	local function OnLoadFrame(frame)
		loadSpammerFrame(frame)
		return uiState.FrameName
	end

	Scaffold.DefineModule({
		module = module,
		getFrame = getFrame,
		acquireRefs = uiState.AcquireRefs,
		bind = BindHandlers,
		localize = function()
			uiState.Localize()
		end,
		onLoad = OnLoadFrame,
		refresh = function()
			if not uiState.Localized then
				uiState.Localize()
			end
			uiState.Refresh()
		end,
	})

	-- Save (EditBox / Checkbox)
	saveSpammer = function(box)
		if not box then
			return
		end

		local frameName = uiState.FrameName
		if not frameName then
			return
		end

		local boxName = box:GetName()
		local target = gsub(boxName, frameName, "")
		local store = Draft.GetStore()

		if find(target, "Chat") then
			local channel = gsub(target, "Chat", "")
			if channel == "Guild" or channel == "Yell" then
				channel = string.upper(channel)
			else
				local _, channelName = GetChannelName(tonumber(channel))
				channel = channelName
			end

			-- FIX: GetChecked can be true/false or 1/0
			local checked = box:GetChecked()
			checked = (checked == true or checked == 1)
			Draft.SetChannelChecked(store, channel, checked)
		else
			local value = Strings.TrimText(box:GetText())
			Draft.SetField(store, target, value)
			box:ClearFocus()
		end

		loaded = false
		previewDirty = true
		requestRefresh()
	end

	-- Start/Stop/Pause
	local function refreshSpamUi()
		requestRefresh()
	end

	local function unlockSpamInputsAndRefresh()
		setInputsLocked(false)
		requestRefresh()
	end

	local function reportRuntimeTerminal(reason, terminalState)
		if reason == "duration_limit" then
			addon:warn(L.MsgSpammerAutoStopDuration:format(tonumber(terminalState and terminalState.runElapsedSeconds) or 0))
		elseif reason == "message_limit" then
			addon:warn(L.MsgSpammerAutoStopMessages:format(tonumber(terminalState and terminalState.attempts) or 0))
		else
			addon:error(L.ErrSpammerRuntime, reason or "runtime_failed")
		end
	end

	local function handleRuntimeTerminal(reason, terminalState)
		unlockSpamInputsAndRefresh()
		reportRuntimeTerminal(reason, terminalState)
	end

	startSpam = function()
		local runtime = GetRuntimeState(RuntimeSvc)
		if runtime.ticking and runtime.paused then
			local started, reason = StartRuntime(RuntimeSvc, {
				duration = runtime.durationSeconds,
				output = runtime.output,
				channels = runtime.channels,
				resetCountdown = false,
				resetRun = false,
				onTick = refreshSpamUi,
				onTerminal = handleRuntimeTerminal,
			})
			setInputsLocked(started == true)
			if started ~= true then reportRuntimeTerminal(reason) end
		elseif runtime.ticking then
			StopRuntime(RuntimeSvc, true, true)
			setInputsLocked(false)
		else
			ensureReadyForStart()
			if not addon.WithinRange(strlen(finalOutput), 4, 255) then return end
			local store = Draft.GetStore()
			local started, reason = StartRuntime(RuntimeSvc, {
				duration = duration,
				output = finalOutput,
				channels = Draft.GetChannels(store),
				resetCountdown = true,
				resetRun = true,
				onTick = refreshSpamUi,
				onTerminal = handleRuntimeTerminal,
			})
			setInputsLocked(started == true)
			if started ~= true then reportRuntimeTerminal(reason) end
		end

		requestRefresh()
	end

	stopSpam = function()
		StopRuntime(RuntimeSvc, true, true)
		setInputsLocked(false)
		requestRefresh()
	end

	function module:RequestStart()
		return startSpam()
	end

	function module:RequestStop()
		return stopSpam()
	end

	function module:RequestClearDraft()
		return clearSpammer()
	end

	pauseSpam = function()
		local pausedOk = PauseRuntime(RuntimeSvc)
		if not pausedOk then
			return
		end

		setInputsLocked(false)
		requestRefresh()
	end

	-- Tab
	focusTab = function(a, b)
		local target
		if IsShiftKeyDown() and getNamedPart(b) ~= nil then
			target = getNamedPart(b)
		elseif getNamedPart(a) ~= nil then
			target = getNamedPart(a)
		end
		if target then
			target:SetFocus()
		end
	end

	-- Clear
	clearSpammer = function()
		local store = Draft.GetStore()
		Draft.ClearDraft(store)

		finalOutput = DEFAULT_OUTPUT
		resetLastState()

		for _, field in ipairs(resetFields) do
			EditBoxes.Reset(getNamedPart(field))
		end

		local durationBox = getNamedPart("Duration")
		duration = DEFAULT_DURATION_STR
		store.Duration = DEFAULT_DURATION_STR

		if durationBox then
			EditBoxes.Reset(durationBox)
			durationBox:SetText(DEFAULT_DURATION_STR)
		end

		loaded = false
		previewDirty = true

		-- FIX: reset UI immediately (len/255 included)
		resetLengthUI()
		updateControls()
		return Draft.BuildPreview(store, DEFAULT_OUTPUT)
	end

	-- Localize UI
	function uiState.Localize()
		if uiState.Localized then
			return
		end
		local frameName = uiState.FrameName
		if not frameName then
			return
		end

		getNamedPart("NameStr"):SetText(L.StrRaid)
		getNamedPart("DurationStr"):SetText(L.StrDuration)
		getNamedPart("Tick"):SetText("")
		getNamedPart("CompStr"):SetText(L.StrSpammerCompStr)
		getNamedPart("NeedStr"):SetText(L.StrSpammerNeedStr)
		getNamedPart("ClassStr"):SetText(L.StrClass)
		getNamedPart("TanksStr"):SetText(L.StrTank)
		getNamedPart("HealersStr"):SetText(L.StrHealer)
		getNamedPart("MeleesStr"):SetText(L.StrMelee)
		getNamedPart("RangedStr"):SetText(L.StrRanged)
		getNamedPart("MessageStr"):SetText(L.StrSpammerMessageStr)
		getNamedPart("ChannelsStr"):SetText(L.StrChannels)
		for i = 1, 8 do
			local label = getNamedPart("Channel" .. i .. "Str")
			if label then
				label:SetText(tostring(i))
			end
		end
		getNamedPart("ChannelGuildStr"):SetText(L.StrGuild)
		getNamedPart("ChannelYellStr"):SetText(L.StrYell)
		getNamedPart("PreviewStr"):SetText(L.StrSpammerPreviewStr)
		getNamedPart("ClearBtn"):SetText(L.BtnClear)
		getNamedPart("StartBtn"):SetText(L.BtnStart)

		Frames.SetFrameTitle(frameName, L.StrSpammer)

		local durationBox = getNamedPart("Duration")
		durationBox.tooltip_title = AUCTION_DURATION
		Tooltips.Bind(durationBox, L.StrSpammerDurationHelp)

		local messageBox = getNamedPart("Message")
		messageBox.tooltip_title = L.StrMessage
		Tooltips.Bind(messageBox, {
			L.StrSpammerMessageHelp1,
			L.StrSpammerMessageHelp2,
			L.StrSpammerMessageHelp3,
		})

		local function setupEditBox(target)
			local box = getNamedPart(target)
			if not box then
				return
			end

			Frames.SetScriptSafely(box, "OnEditFocusGained", function()
				local runtime = GetRuntimeState(RuntimeSvc)
				if runtime.ticking and not runtime.paused then
					pauseSpam()
				end
			end)

			Frames.SetScriptSafely(box, "OnTextChanged", function(_, isUserInput)
				if inputsLocked then
					return
				end
				if isUserInput then
					previewDirty = true
					requestRefresh()
				end
			end)

			Frames.SetScriptSafely(box, "OnEnterPressed", function(self)
				self:ClearFocus()
			end)

			Frames.SetScriptSafely(box, "OnEditFocusLost", function(self)
				saveSpammer(self)
			end)
		end

		for _, f in ipairs(inputFields) do
			setupEditBox(f)
		end

		-- Initialize default UI length once
		resetLengthUI()

		uiState.Localized = true
	end

	-- Tick display
	updateTickDisplay = function()
		local runtime = GetRuntimeState(RuntimeSvc)
		local countdownRemaining = tonumber(runtime.countdownRemaining) or 0
		local tickText = getNamedPart("Tick")
		if not tickText then
			return
		end
		if countdownRemaining > 0 then
			tickText:SetText(countdownRemaining)
		else
			tickText:SetText("")
		end
	end

	-- Lock/unlock inputs
	function setInputsLocked(locked)
		local frame = getFrame()
		if inputsLocked == locked and inputsAppliedFrame == frame then
			return
		end
		inputsLocked = locked

		local alpha = locked and 0.7 or 1.0

		local function setEditBoxState(box, enabled)
			if not box then
				return
			end
			if box.SetEnabled then
				box:SetEnabled(enabled)
			elseif enabled and box.Enable then
				box:Enable()
			elseif not enabled and box.Disable then
				box:Disable()
			end
		end

		for _, field in ipairs(inputFields) do
			local box = getNamedPart(field)
			if box then
				setEditBoxState(box, not locked)
				box:SetAlpha(alpha)
				if locked then
					box:ClearFocus()
				end
			end
		end

		for i = 1, 8 do
			Primitives.SetEnabled(getNamedPart("Chat" .. i), not locked)
		end
		Primitives.SetEnabled(getNamedPart("ChatGuild"), not locked)
		Primitives.SetEnabled(getNamedPart("ChatYell"), not locked)
		Primitives.SetEnabled(getNamedPart("ClearBtn"), not locked)
		inputsAppliedFrame = frame
	end

	-- Controls update
	function updateControls()
		local runtime = GetRuntimeState(RuntimeSvc)
		local locked = runtime.ticking and not runtime.paused
		local canStart = runtime.ticking or (strlen(finalOutput) > 3 and strlen(finalOutput) <= 255)
		local btnLabel = runtime.paused and L.BtnResume or L.BtnStop
		local isStop = runtime.ticking == true

		if
			lastControls.locked == locked
			and lastControls.canStart == canStart
			and lastControls.btnLabel == btnLabel
			and lastControls.isStop == isStop
		then
			return
		end

		local frame = getFrame()
		if frame then
			setInputsLocked(locked)
			if Primitives.SetText then
				Primitives.SetText(getNamedPart("StartBtn"), btnLabel, L.BtnStart, isStop)
			end
			if Primitives.SetEnabled then
				Primitives.SetEnabled(getNamedPart("StartBtn"), canStart)
			end

			lastControls.locked = locked
			lastControls.canStart = canStart
			lastControls.btnLabel = btnLabel
			lastControls.isStop = isStop
		end
	end

	-- Preview render
	function renderPreview()
		local frame = getFrame()
		if not frame or not frame:IsShown() then
			return
		end

		local changed = false

		for _, field in ipairs(previewFields) do
			local box = getNamedPart(field.box)
			local value
			if field.number then
				value = box and (tonumber(box:GetText()) or 0) or 0
			else
				value = box and Strings.TrimText(box:GetText()) or ""
			end

			if lastState[field.key] ~= value then
				lastState[field.key] = value
				changed = true
			end
		end

		local durationBox = getNamedPart("Duration")
		local durationValue = durationBox and durationBox:GetText() or ""
		if durationValue == "" then
			durationValue = DEFAULT_DURATION_STR
			if durationBox then
				durationBox:SetText(durationValue)
			end
		end

		if lastState.duration ~= durationValue then
			lastState.duration = durationValue
			changed = true
		end

		if changed then
			finalOutput = Draft.BuildOutput(lastState, DEFAULT_OUTPUT)

			local out = getNamedPart("Output")
			if out then
				out:SetText(finalOutput)
			end

			local len = strlen(finalOutput)
			local lenText = getNamedPart("Length")
			if lenText then
				lenText:SetText(len .. "/255")
				if finalOutput == DEFAULT_OUTPUT then
					lenText:SetTextColor(0.5, 0.5, 0.5)
				elseif len <= 255 then
					lenText:SetTextColor(0.0, 1.0, 0.0)
				else
					lenText:SetTextColor(1.0, 0.0, 0.0)
				end
			end

			local msg = getNamedPart("Message")
			if msg and msg.SetMaxLetters then
				if len <= 255 then
					msg:SetMaxLetters(255)
				else
					local messageValue = lastState.message or ""
					msg:SetMaxLetters(strlen(messageValue) - 1)
				end
			end
		end

		duration = lastState.duration or DEFAULT_DURATION_STR
		local store = Draft.GetStore()
		store.Duration = duration

		updateControls()
	end

	-- UI update tick
	function uiState.Refresh()
		local frame = getFrame()
		if not (frame and frame:IsShown()) then
			return
		end

		if not loaded then
			local store = Draft.GetStore()
			store.Duration = store.Duration or DEFAULT_DURATION_STR

			resetAllChannelCheckboxes()

			for k, v in pairs(store) do
				if k == "Channels" then
					for _, channel in ipairs(v) do
						if channel == "GUILD" then
							setCheckbox("ChatGuild", true)
						elseif channel == "YELL" then
							setCheckbox("ChatYell", true)
						else
							local id = select(1, GetChannelName(channel))
							if id and id > 0 then
								setCheckbox("Chat" .. id, true)
							end
						end
					end
				elseif getNamedPart(k) then
					getNamedPart(k):SetText(v)
				end
			end

			loaded = true
			previewDirty = true
		end

		local runtime = GetRuntimeState(RuntimeSvc)
		if runtime.ticking and not runtime.paused then
			updateControls()
			updateTickDisplay()
			return
		end

		if previewDirty then
			renderPreview()
			previewDirty = false
		else
			updateControls()
			updateTickDisplay()
		end
	end
end
