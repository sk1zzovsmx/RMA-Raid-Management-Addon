-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
-- notes: pure spammer draft/store/preview model helpers
local addon = select(2, ...)
local L = addon.L
local SavedVariables = addon.Database.SavedVariables
local Services = addon.Services
local Strings = addon.Strings

local tconcat, tonumber, tostring, type = table.concat, tonumber, tostring, type
local floor = math.floor
local lower, strlen = string.lower, string.len
local sort = table.sort

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Spammer", "Draft")
local Spammer = Services.Spammer
Spammer.Draft = Spammer.Draft or {}

local Draft = Spammer.Draft

local DEFAULT_DURATION_STR = "60"
local DEFAULT_OUTPUT = "LFM"
local MAX_COUNT = 9
local MAX_DURATION = 999
local MAX_TEXT_BYTES = 255
local MAX_NAME_BYTES = 64

local fieldRules = {
	Name = { kind = "text", maxBytes = MAX_NAME_BYTES },
	Tank = { kind = "count" },
	TankClass = { kind = "text", maxBytes = MAX_NAME_BYTES },
	Healer = { kind = "count" },
	HealerClass = { kind = "text", maxBytes = MAX_NAME_BYTES },
	Melee = { kind = "count" },
	MeleeClass = { kind = "text", maxBytes = MAX_NAME_BYTES },
	Ranged = { kind = "count" },
	RangedClass = { kind = "text", maxBytes = MAX_NAME_BYTES },
	Message = { kind = "text", maxBytes = MAX_TEXT_BYTES },
	Duration = { kind = "duration" },
	Channels = { kind = "channels" },
}

-- ----- Private helpers ----- --
local function normalizeText(value, maxBytes)
	if type(value) ~= "string" then
		return ""
	end
	local text = Strings.TrimText(value)
	return Strings.Utf8SafePrefix(text, maxBytes)
end

local function normalizeCount(value)
	local count = tonumber(value)
	if not count or count < 0 then
		return 0
	end
	return math.min(MAX_COUNT, floor(count))
end

local function normalizeDuration(value)
	local duration = tonumber(value)
	if not duration or duration <= 0 then
		return DEFAULT_DURATION_STR
	end
	return tostring(math.min(MAX_DURATION, floor(duration)))
end

local function normalizeChannel(value)
	if type(value) ~= "string" then
		return nil
	end
	local channel = normalizeText(value, MAX_NAME_BYTES)
	if channel == "" or channel:find("[%c|]") then
		return nil
	end
	return channel
end

local function orderedValues(source)
	local numericKeys, otherKeys = {}, {}
	for key in pairs(source) do
		if type(key) == "number" and key > 0 and floor(key) == key then
			numericKeys[#numericKeys + 1] = key
		else
			otherKeys[#otherKeys + 1] = key
		end
	end
	sort(numericKeys)
	sort(otherKeys, function(left, right)
		return tostring(left) < tostring(right)
	end)
	local values = {}
	for i = 1, #numericKeys do
		values[#values + 1] = source[numericKeys[i]]
	end
	for i = 1, #otherKeys do
		values[#values + 1] = source[otherKeys[i]]
	end
	return values
end

local function normalizeChannels(source)
	local channels, seen = {}, {}
	if type(source) ~= "table" then
		return channels
	end
	local values = orderedValues(source)
	for i = 1, #values do
		local channel = normalizeChannel(values[i])
		local key = channel and lower(channel) or nil
		if key and not seen[key] then
			seen[key] = true
			channels[#channels + 1] = channel
		end
	end
	return channels
end

local function normalizeStore(store)
	for key in pairs(store) do
		if fieldRules[key] == nil then
			store[key] = nil
		end
	end
	for key, rule in pairs(fieldRules) do
		if rule.kind == "text" then
			store[key] = normalizeText(store[key], rule.maxBytes)
		elseif rule.kind == "count" then
			store[key] = tostring(normalizeCount(store[key]))
		elseif rule.kind == "duration" then
			store[key] = normalizeDuration(store[key])
		elseif rule.kind == "channels" then
			store[key] = normalizeChannels(store[key])
		end
	end
	return store
end

local function getOutputNeeds(state)
	local needParts = {}
	local function addNeed(count, label, class)
		count = tonumber(count) or 0
		if count <= 0 then
			return
		end

		local text = count .. " " .. label
		if class and class ~= "" then
			text = text .. " (" .. class .. ")"
		end
		needParts[#needParts + 1] = text
	end

	addNeed(state.tank, L.StrTank, state.tankClass)
	addNeed(state.healer, L.StrHealer, state.healerClass)
	addNeed(state.melee, L.StrMelee, state.meleeClass)
	addNeed(state.ranged, L.StrRanged, state.rangedClass)

	return needParts
end

-- ----- Public methods ----- --
function Draft.GetDefaultDuration()
	return DEFAULT_DURATION_STR
end

function Draft.GetDefaultOutput()
	return DEFAULT_OUTPUT
end

function Draft.GetStore()
	return normalizeStore(SavedVariables.GetSpammer())
end

function Draft.GetChannels(store)
	store = normalizeStore(store or SavedVariables.GetSpammer())
	return store.Channels
end

function Draft.SetField(store, key, value)
	store = store or Draft.GetStore()
	local rule = type(key) == "string" and fieldRules[key] or nil
	if not rule or rule.kind == "channels" then
		return false, "invalid_field"
	end
	if rule.kind == "duration" and (not tonumber(value) or tonumber(value) <= 0) then
		return false, "invalid_duration"
	end
	if rule.kind == "count" and (not tonumber(value) or tonumber(value) < 0) then
		return false, "invalid_count"
	end
	if rule.kind == "text" and type(value) ~= "string" then
		return false, "invalid_text"
	end
	if rule.kind == "text" then
		store[key] = normalizeText(value, rule.maxBytes)
	elseif rule.kind == "count" then
		store[key] = tostring(normalizeCount(value))
	elseif rule.kind == "duration" then
		store[key] = normalizeDuration(value)
	end
	return true
end

function Draft.SetChannelChecked(store, channel, checked)
	store = store or Draft.GetStore()
	local channels = Draft.GetChannels(store)
	channel = normalizeChannel(channel)
	if not channel then
		return false, "invalid_channel"
	end
	local existsAt = nil

	for i = 1, #channels do
		if lower(channels[i]) == lower(channel) then
			existsAt = i
			break
		end
	end

	if checked == true then
		if not existsAt then
			channels[#channels + 1] = channel
		end
		return true
	end

	while existsAt do
		table.remove(channels, existsAt)
		existsAt = nil
		for i = 1, #channels do
			if lower(channels[i]) == lower(channel) then
				existsAt = i
				break
			end
		end
	end
	return true
end

function Draft.BuildState(store)
	store = normalizeStore(store or SavedVariables.GetSpammer())
	return {
		name = store.Name or "",
		tank = tonumber(store.Tank) or 0,
		tankClass = store.TankClass or "",
		healer = tonumber(store.Healer) or 0,
		healerClass = store.HealerClass or "",
		melee = tonumber(store.Melee) or 0,
		meleeClass = store.MeleeClass or "",
		ranged = tonumber(store.Ranged) or 0,
		rangedClass = store.RangedClass or "",
		message = store.Message or "",
		duration = tostring(store.Duration or DEFAULT_DURATION_STR),
	}
end

function Draft.BuildOutput(state, defaultOutput)
	local baseOutput = defaultOutput or DEFAULT_OUTPUT
	local source = (type(state) == "table") and state or {}
	local outBuf = { baseOutput }

	local name = source.name or ""
	if name ~= "" then
		outBuf[#outBuf + 1] = " "
		outBuf[#outBuf + 1] = name
	end

	local needParts = getOutputNeeds(source)
	if #needParts > 0 then
		outBuf[#outBuf + 1] = " - "
		outBuf[#outBuf + 1] = L.StrSpammerNeedStr
		outBuf[#outBuf + 1] = " "
		outBuf[#outBuf + 1] = tconcat(needParts, ", ")
	end

	if source.message and source.message ~= "" then
		outBuf[#outBuf + 1] = " - "
		if Strings.FindAchievement then
			outBuf[#outBuf + 1] = Strings.FindAchievement(source.message)
		else
			outBuf[#outBuf + 1] = source.message
		end
	end

	local output = tconcat(outBuf)
	if output == baseOutput then
		return output
	end

	local total = (tonumber(source.tank) or 0)
		+ (tonumber(source.healer) or 0)
		+ (tonumber(source.melee) or 0)
		+ (tonumber(source.ranged) or 0)

	local is25 = (name ~= "" and name:match("%f[%d]25%f[%D]")) ~= nil
	local maxSize = is25 and 25 or 10
	return output .. " (" .. (maxSize - total) .. "/" .. maxSize .. ")"
end

function Draft.BuildPreview(store, defaultOutput)
	local state = Draft.BuildState(store)
	local output = Draft.BuildOutput(state, defaultOutput)
	return {
		output = output,
		length = strlen(output),
		duration = state.duration,
	}
end

function Draft.ClearDraft(store)
	store = store or Draft.GetStore()
	for k in pairs(store) do
		if k ~= "Channels" then
			store[k] = nil
		end
	end
	store.Duration = DEFAULT_DURATION_STR
	return normalizeStore(store)
end
