-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
-- notes: pure spammer draft/store/preview model helpers
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local SavedVariables = feature.Database.SavedVariables
local Services = feature.Services
local Strings = feature.Strings

local tconcat, tonumber, tostring, type = table.concat, tonumber, tostring, type
local strlen = string.len

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Spammer", "Draft")
local Spammer = Services.Spammer
Spammer.Draft = Spammer.Draft or {}

local Draft = Spammer.Draft

local DEFAULT_DURATION_STR = "60"
local DEFAULT_OUTPUT = "LFM"

-- ----- Private helpers ----- --
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
	return SavedVariables.GetSpammer()
end

function Draft.GetChannels(store)
	store = store or Draft.GetStore()
	if type(store.Channels) ~= "table" then
		store.Channels = {}
	end
	return store.Channels
end

function Draft.SetField(store, key, value)
	store = store or Draft.GetStore()
	if type(key) ~= "string" or key == "" then
		return false
	end
	store[key] = value
	return true
end

function Draft.SetChannelChecked(store, channel, checked)
	store = store or Draft.GetStore()
	local channels = Draft.GetChannels(store)
	local existsAt = nil

	for i = 1, #channels do
		if channels[i] == channel then
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
			if channels[i] == channel then
				existsAt = i
				break
			end
		end
	end
	return true
end

function Draft.BuildStateFromStore(store)
	store = store or Draft.GetStore()
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
	local state = Draft.BuildStateFromStore(store)
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
	return store
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Spammer/Draft", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/SavedVariables",
			"Modules/Strings",
		},
	})
	registry.SetLoaded("Services/Spammer/Draft")
end
