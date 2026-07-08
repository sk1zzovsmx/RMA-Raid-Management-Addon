-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: owns chat output helpers and LFM spam Timer ticker
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L

local C = feature.C
local Database = feature.Database
local Comms = feature.Comms
local Deformat = feature.Deformat
local Options = feature.Options
local Services = feature.Services
local Strings = feature.Strings
local Timer = feature.Timer

local GetGroupTypeAndCount = assert(feature.GetGroupTypeAndCount, "Chat group policy helper is not initialized")

local find = string.find
local len = string.len
local upper = string.upper
local tostring = tostring
local tonumber = tonumber
local type = type
local ipairs = ipairs

-- =========== Chat Output Helpers  =========== --
do
	feature.EnsureServiceNamespace("Chat")
	local module = Services.Chat

	-- Timer ownership: ticker for controlled LFM spammer output.
	Timer.BindMixin(module, "Chat")

	-- ----- Internal state ----- --
	local chatOutputFormat = C.CHAT_OUTPUT_FORMAT
	local chatPrefixShort = C.CHAT_PREFIX_SHORT
	local chatPrefixHex = C.CHAT_PREFIX_HEX
	local DEFAULT_SPAM_DURATION_SECONDS = 60
	local DEFAULT_SPAM_OUTPUT = "LFM"
	local MAX_SPAM_RUNTIME_SECONDS = 1800
	local MAX_SPAM_MESSAGES_PER_RUN = 30
	local GetOption = Options.GetValue

	local spamRuntime = {
		ticking = false,
		paused = false,
		countdownRemaining = 0,
		runElapsedSeconds = 0,
		messagesSent = 0,
		durationSeconds = DEFAULT_SPAM_DURATION_SECONDS,
		output = DEFAULT_SPAM_OUTPUT,
		channels = {},
		ticker = nil,
		onTick = nil,
		onAutoStop = nil,
		sendFn = nil,
	}

	-- ----- Private helpers ----- --
	local function isCountdownMessage(text)
		local seconds = Deformat(text, L.ChatCountdownTic)
		return (seconds ~= nil) or (find(text, L.ChatCountdownEnd) ~= nil)
	end

	local function canUseRaidWarning()
		local raidService = Services.Raid
		if raidService and type(raidService.CanUseCapability) == "function" then
			return raidService:CanUseCapability("raid_warning")
		end

		return Database.GetUnitRank("player", 0) > 0
	end

	local function resolveGroupType()
		local groupType = GetGroupTypeAndCount()
		if groupType == "raid" or groupType == "party" then
			return groupType
		end
		return nil
	end

	local function resolveAnnounceChannel(text, preferredChannel)
		if preferredChannel then
			return preferredChannel
		end

		local groupType = resolveGroupType()
		if groupType == "raid" then
			if isCountdownMessage(text) and GetOption("Rolls", "countdownSimpleRaidMsg") == true then
				return "RAID"
			end
			if GetOption("Master", "useRaidWarning") == true and canUseRaidWarning() then
				return "RAID_WARNING"
			end
			return "RAID"
		end
		if groupType == "party" then
			return "PARTY"
		end
		return nil
	end

	local function cloneChannels(channels)
		if type(channels) ~= "table" then
			return {}
		end

		local copy = {}
		for i = 1, #channels do
			copy[#copy + 1] = channels[i]
		end
		return copy
	end

	local function cancelSpamTicker()
		if spamRuntime.ticker then
			module:CancelTimer(spamRuntime.ticker)
			spamRuntime.ticker = nil
		end
	end

	local function getSpamRuntimeSnapshot()
		return {
			ticking = spamRuntime.ticking,
			paused = spamRuntime.paused,
			countdownRemaining = spamRuntime.countdownRemaining,
			runElapsedSeconds = spamRuntime.runElapsedSeconds,
			messagesSent = spamRuntime.messagesSent,
			durationSeconds = spamRuntime.durationSeconds,
			output = spamRuntime.output,
			channels = cloneChannels(spamRuntime.channels),
		}
	end

	local function normalizeSpamDuration(durationValue, fallbackValue)
		local durationSeconds = tonumber(durationValue)
		if not durationSeconds or durationSeconds <= 0 then
			durationSeconds = tonumber(fallbackValue)
		end
		if not durationSeconds or durationSeconds <= 0 then
			durationSeconds = DEFAULT_SPAM_DURATION_SECONDS
		end
		return math.floor(durationSeconds)
	end

	local function normalizeWarningMessage(content)
		if type(content) ~= "string" then
			return nil
		end

		local message = Strings.TrimText(content)
		if message == "" then
			return nil
		end
		return message
	end

	local function sendSpamOutput(output, channels)
		local text = tostring(output or "")
		if len(text) > 255 then
			return false, "too_long"
		end

		local channelList = cloneChannels(channels)
		if #channelList <= 0 then
			local groupType = GetGroupTypeAndCount()
			if groupType == "raid" then
				Comms.SendChat(text, "RAID", nil, nil, true)
			elseif groupType == "party" then
				Comms.SendChat(text, "PARTY", nil, nil, true)
			else
				module:Print(text)
			end
			return true
		end

		for _, channel in ipairs(channelList) do
			if type(channel) == "number" then
				Comms.SendChat(text, "CHANNEL", nil, channel, true)
			else
				Comms.SendChat(text, upper(channel), nil, nil, true)
			end
		end

		return true
	end

	local function fireSpamTick()
		local onTick = spamRuntime.onTick
		if type(onTick) == "function" then
			onTick(getSpamRuntimeSnapshot())
		end
	end

	local function finalizeAutoStop(reason)
		local onAutoStop = spamRuntime.onAutoStop
		module:StopSpamCycle(true, true)
		if type(onAutoStop) == "function" then
			onAutoStop(reason, getSpamRuntimeSnapshot())
		end
	end

	local function runSpamTick()
		if not spamRuntime.ticking or spamRuntime.paused then
			return
		end

		spamRuntime.runElapsedSeconds = spamRuntime.runElapsedSeconds + 1
		if spamRuntime.runElapsedSeconds >= MAX_SPAM_RUNTIME_SECONDS then
			addon:warn(L.MsgSpammerAutoStopDuration:format(MAX_SPAM_RUNTIME_SECONDS))
			finalizeAutoStop("duration_limit")
			return
		end

		spamRuntime.countdownRemaining = spamRuntime.countdownRemaining - 1
		if spamRuntime.countdownRemaining <= 0 then
			local sendFn = spamRuntime.sendFn
			local ok
			if type(sendFn) == "function" then
				ok = sendFn(spamRuntime.output, spamRuntime.channels)
			else
				ok = sendSpamOutput(spamRuntime.output, spamRuntime.channels)
			end

			if ok == false then
				finalizeAutoStop("send_failed")
				return
			end

			spamRuntime.messagesSent = spamRuntime.messagesSent + 1
			if spamRuntime.messagesSent >= MAX_SPAM_MESSAGES_PER_RUN then
				addon:warn(L.MsgSpammerAutoStopMessages:format(MAX_SPAM_MESSAGES_PER_RUN))
				finalizeAutoStop("message_limit")
				return
			end

			spamRuntime.countdownRemaining = normalizeSpamDuration(spamRuntime.durationSeconds)
		end

		fireSpamTick()
	end

	-- ----- Public methods ----- --
	function module:Print(text, prefix)
		local msg = Strings.FormatChatMessage(text, prefix or chatPrefixShort, chatOutputFormat, chatPrefixHex)
		addon:info("%s", msg)
	end

	function module:Announce(text, channel)
		local msg = tostring(text)
		local selectedChannel = resolveAnnounceChannel(msg, channel)
		if not selectedChannel or selectedChannel == "" then
			return module:Print(msg)
		end
		Comms.SendChat(msg, selectedChannel)
	end

	function module:AnnounceWarningMessage(content)
		local message = normalizeWarningMessage(content)
		if not message then
			return false, "empty"
		end

		if addon.IsInRaid and addon.IsInRaid() and GetOption("Master", "useRaidWarning") == true then
			local raidService = Services.Raid
			if
				raidService
				and type(raidService.CanUseCapability) == "function"
				and not raidService:CanUseCapability("raid_warning")
			then
				addon:warn(L.WarnRaidWarningFallback)
			end
		end

		module:Announce(message)
		return true
	end

	function module:GetSpamRuntimeState()
		return getSpamRuntimeSnapshot()
	end

	function module:StartSpamCycle(config)
		config = (type(config) == "table") and config or {}

		cancelSpamTicker()

		spamRuntime.durationSeconds = normalizeSpamDuration(config.duration, spamRuntime.durationSeconds)
		if config.resetRun then
			spamRuntime.runElapsedSeconds = 0
			spamRuntime.messagesSent = 0
		end

		if config.output ~= nil then
			spamRuntime.output = tostring(config.output)
		end
		if config.channels ~= nil then
			spamRuntime.channels = cloneChannels(config.channels)
		end

		spamRuntime.sendFn = (type(config.sendFn) == "function") and config.sendFn or nil
		spamRuntime.onTick = (type(config.onTick) == "function") and config.onTick or nil
		spamRuntime.onAutoStop = (type(config.onAutoStop) == "function") and config.onAutoStop or nil

		if config.resetCountdown or spamRuntime.countdownRemaining <= 0 then
			spamRuntime.countdownRemaining = spamRuntime.durationSeconds
		end

		spamRuntime.ticking = true
		spamRuntime.paused = false

		spamRuntime.ticker = module:ScheduleRepeatingTimer(runSpamTick, 1)
		fireSpamTick()

		return true, getSpamRuntimeSnapshot()
	end

	function module:StopSpamCycle(resetCountdown, resetRun)
		cancelSpamTicker()

		spamRuntime.ticking = false
		spamRuntime.paused = false

		if resetCountdown then
			spamRuntime.countdownRemaining = 0
		end
		if resetRun then
			spamRuntime.runElapsedSeconds = 0
			spamRuntime.messagesSent = 0
		end

		spamRuntime.sendFn = nil
		spamRuntime.onTick = nil
		spamRuntime.onAutoStop = nil

		return getSpamRuntimeSnapshot()
	end

	function module:PauseSpamCycle()
		if not spamRuntime.ticking or spamRuntime.paused then
			return false, getSpamRuntimeSnapshot()
		end

		spamRuntime.paused = true
		cancelSpamTicker()
		fireSpamTick()
		return true, getSpamRuntimeSnapshot()
	end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Chat", {
		deps = {
			"Init",
			"Database/DBOptions",
			"Modules/ModuleRegistry",
			"Modules/C",
			"Modules/Timer",
			"Modules/Strings",
			"Modules/Comms",
		},
	})
	registry.SetLoaded("Services/Chat")
end
