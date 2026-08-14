-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: owns chat output helpers and LFM spam transport
local addon = select(2, ...)
local Diag = addon.Diag
local L = addon.L

local C = addon.C
local Database = addon.Database
local Comms = addon.Comms
local Deformat = addon.Deformat
local Options = addon.Options
local Services = addon.Services
local Strings = addon.Strings
local Group = assert(addon.Group, Diag.A.ChatGroupHelperOwnerNotInitialized)
local GetGroupTypeAndCount = assert(Group.GetTypeAndCount, Diag.A.ChatGroupPolicyHelperNotInitialized)

local find = string.find
local len = string.len
local tostring = tostring
local tonumber = tonumber
local type = type
local ipairs = ipairs

-- =========== Chat Output Helpers  =========== --
do
	addon.Services.EnsureNamespace("Chat")
	local module = Services.Chat

	-- ----- Internal state ----- --
	local chatOutputFormat = C.CHAT_OUTPUT_FORMAT
	local chatPrefixShort = C.CHAT_PREFIX_SHORT
	local chatPrefixHex = C.CHAT_PREFIX_HEX
	local GetOption = Options.GetValue

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
				return Comms.SendChat(text, "RAID", nil, nil, true)
			elseif groupType == "party" then
				return Comms.SendChat(text, "PARTY", nil, nil, true)
			else
				module:Print(text)
				return true
			end
		end

		local firstFailure = nil
		for _, channel in ipairs(channelList) do
			local sent, reason
			if type(channel) == "string" then
				sent, reason = Comms.SendChat(text, channel, nil, nil, true)
			end
			if sent ~= true and not firstFailure then firstFailure = reason or "send_failed" end
		end

		if firstFailure then return nil, firstFailure end
		return true
	end


	-- ----- Public methods ----- --
	function module:Print(text, prefix)
		local msg = Strings.FormatChatMessage(text, prefix or chatPrefixShort, chatOutputFormat, chatPrefixHex)
		addon:info("%s", msg)
		return true
	end

	function module:Announce(text, channel)
		local msg = tostring(text)
		if len(msg) > 255 then
			return nil, "too_long", { sent = false, channel = channel, fallback = false, reason = "too_long" }
		end
		local selectedChannel = resolveAnnounceChannel(msg, channel)
		if not selectedChannel or selectedChannel == "" then
			module:Print(msg)
			return true, nil, { sent = false, channel = "LOCAL", fallback = true }
		end
		local sent, reason = Comms.SendChat(msg, selectedChannel)
		if sent ~= true then
			return nil, reason or "send_failed", {
				sent = false,
				channel = selectedChannel,
				fallback = false,
				reason = reason or "send_failed",
			}
		end
		return true, nil, { sent = true, channel = selectedChannel, fallback = false }
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

		return module:Announce(message)
	end

	function module:SendSpamOutput(output, channels)
		return sendSpamOutput(output, channels)
	end
end
