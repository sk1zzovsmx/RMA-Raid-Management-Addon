-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: emits WarningsDataChanged after saved warning mutations
-- notes: pure warnings saved-variable and template helpers
local addon = select(2, ...)
local L = addon.L
local SavedVariables = addon.Database.SavedVariables
local Services = addon.Services
local Strings = addon.Strings
local Bus = addon.Bus
local Events = addon.Events
local TriggerEvent = assert(Bus.TriggerEvent, "Warnings store event publisher is not initialized")
local InternalEvents = assert(Events.Internal, "Warnings store internal events are not initialized")
local WarningsDataChangedEvent =
	assert(InternalEvents.WarningsDataChanged, "Warnings store data-changed event is not initialized")

local function notifyWarningsDataChanged(reason)
	local ok, err = pcall(TriggerEvent, WarningsDataChangedEvent, reason)
	if not ok and type(L.ErrWarningNotification) == "string" then
		addon:error(L.ErrWarningNotification, tostring(err))
	end
	return ok
end

local tconcat = table.concat
local tinsert = table.insert
local tremove = table.remove
local tonumber, tostring, type = tonumber, tostring, type
local floor = math.floor
local byte = string.byte
local lower, strlen, strsub = string.lower, string.len, string.sub
local sort = table.sort

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Warnings", "Store")
local Warnings = Services.Warnings
local Store = Warnings.Store
local MAX_WARNING_NAME_BYTES = 64
local MAX_WARNING_CONTENT_BYTES = 255

local defaultWarningTemplates = {
	{
		name = "StrRaidWarningTemplatePullName",
		content = "StrRaidWarningTemplatePullContent",
		fallbackName = "Pull",
		fallbackContent = "Pull in 10 seconds.",
	},
	{
		name = "StrRaidWarningTemplateSpreadName",
		content = "StrRaidWarningTemplateSpreadContent",
		fallbackName = "Spread",
		fallbackContent = "Spread out.",
	},
	{
		name = "StrRaidWarningTemplateStackName",
		content = "StrRaidWarningTemplateStackContent",
		fallbackName = "Stack",
		fallbackContent = "Stack on marker.",
	},
	{
		name = "StrRaidWarningTemplateStopDpsName",
		content = "StrRaidWarningTemplateStopDpsContent",
		fallbackName = "Stop DPS",
		fallbackContent = "Stop DPS now.",
	},
	{
		name = "StrRaidWarningTemplateBloodlustName",
		content = "StrRaidWarningTemplateBloodlustContent",
		fallbackName = "Bloodlust",
		fallbackContent = "Use Bloodlust/Heroism now.",
	},
	{
		name = "StrRaidWarningTemplateBreakName",
		content = "StrRaidWarningTemplateBreakContent",
		fallbackName = "Break",
		fallbackContent = "Break time. Be back soon.",
	},
}

-- ----- Private helpers ----- --
local function utf8SequenceLength(firstByte)
	if firstByte <= 0x7f then return 1 end
	if firstByte >= 0xc2 and firstByte <= 0xdf then return 2 end
	if firstByte >= 0xe0 and firstByte <= 0xef then return 3 end
	if firstByte >= 0xf0 and firstByte <= 0xf4 then return 4 end
	return nil
end

local function isValidUtf8Sequence(text, index, sequenceLength)
	local firstByte = byte(text, index)
	for offset = 1, sequenceLength - 1 do
		local continuation = byte(text, index + offset)
		if not continuation or continuation < 0x80 or continuation > 0xbf then return false end
		if offset == 1 then
			if firstByte == 0xe0 and continuation < 0xa0 then return false end
			if firstByte == 0xed and continuation > 0x9f then return false end
			if firstByte == 0xf0 and continuation < 0x90 then return false end
			if firstByte == 0xf4 and continuation > 0x8f then return false end
		end
	end
	return true
end

local function utf8SafePrefix(text, maxBytes)
	local index, lastValid, textLength = 1, 0, strlen(text)
	while index <= textLength do
		local sequenceLength = utf8SequenceLength(byte(text, index))
		if not sequenceLength or index + sequenceLength - 1 > maxBytes then break end
		if not isValidUtf8Sequence(text, index, sequenceLength) then break end
		lastValid = index + sequenceLength - 1
		index = lastValid + 1
	end
	return strsub(text, 1, lastValid)
end

local function normalizeBoundedText(value, maxBytes)
	if type(value) ~= "string" then
		return nil
	end
	local text = Strings.TrimText(value)
	text = utf8SafePrefix(text, maxBytes)
	if text == "" then
		return nil
	end
	return text
end

local function validateBoundedText(value, maxBytes, field)
	if type(value) ~= "string" then return nil, "invalid_" .. field end
	local text = Strings.TrimText(value)
	if text == "" then return nil, "empty" end
	if strlen(text) > maxBytes then return nil, field .. "_too_long" end
	if utf8SafePrefix(text, maxBytes) ~= text then return nil, "invalid_" .. field end
	return text
end

local function cloneWarnings(warnings)
	local copy = {}
	for i = 1, #warnings do
		copy[i] = warnings[i]
	end
	return copy
end

local function replaceWarnings(target, source)
	for key in pairs(target) do target[key] = nil end
	for i = 1, #source do
		target[i] = source[i]
	end
end

local function publishMutation(warnings, candidate, reason)
	replaceWarnings(warnings, candidate)
	return true, { notificationFailed = not notifyWarningsDataChanged(reason) }
end

local function orderedWarningKeys(warnings)
	local numericKeys, otherKeys = {}, {}
	for key in pairs(warnings) do
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
	for i = 1, #otherKeys do
		numericKeys[#numericKeys + 1] = otherKeys[i]
	end
	return numericKeys
end

local function normalizeWarnings(warnings)
	local normalized = {}
	local keys = orderedWarningKeys(warnings)
	for i = 1, #keys do
		local warning = warnings[keys[i]]
		if type(warning) == "table" then
			local name = normalizeBoundedText(warning.name, MAX_WARNING_NAME_BYTES)
			local content = normalizeBoundedText(warning.content, MAX_WARNING_CONTENT_BYTES)
			if name and content then
				local canonical = warning.name == name and warning.content == content
				for key in pairs(warning) do
					if key ~= "name" and key ~= "content" then canonical = false break end
				end
				normalized[#normalized + 1] = canonical and warning or { name = name, content = content }
			end
		end
	end
	for key in pairs(warnings) do warnings[key] = nil end
	for i = 1, #normalized do warnings[i] = normalized[i] end
	return warnings
end

local function getTemplateValue(template, key, fallbackKey)
	local value = template and L[template[key]]
	if type(value) == "string" and value ~= "" and value ~= template[key] and value ~= ("L." .. template[key]) then
		return value
	end
	return template and template[fallbackKey] or ""
end

local function normalizeTemplateName(value)
	local text = Strings.TrimText(value or "")
	return text ~= "" and lower(text) or nil
end

local function isDefaultTemplateWarning(warning)
	if type(warning) ~= "table" then
		return false
	end
	local warningName = normalizeTemplateName(warning.name)
	local warningContent = tostring(warning.content or "")
	for i = 1, #defaultWarningTemplates do
		local template = defaultWarningTemplates[i]
		local templateName = normalizeTemplateName(
			normalizeBoundedText(getTemplateValue(template, "name", "fallbackName"), MAX_WARNING_NAME_BYTES)
		)
		local templateContent =
			normalizeBoundedText(getTemplateValue(template, "content", "fallbackContent"), MAX_WARNING_CONTENT_BYTES)
		if warningName == templateName and warningContent == templateContent then
			return true
		end
	end
	return false
end

local function collectStockWarnings(warnings)
	local stock = {}
	if type(warnings) ~= "table" then
		return stock
	end
	for i = 1, #warnings do
		local warning = warnings[i]
		if isDefaultTemplateWarning(warning) then
			stock[#stock + 1] = warning
		end
	end
	return stock
end

-- ----- Public methods ----- --

function Store.GetStore()
	return normalizeWarnings(SavedVariables.GetWarnings())
end

function Store.GetWarning(wID)
	wID = tonumber(wID) or 0
	if wID <= 0 then
		return nil
	end
	local warnings = Store.GetStore()
	return warnings[wID]
end

function Store.EnsureDefaultTemplates()
	local warnings = Store.GetStore()
	local candidate = cloneWarnings(warnings)
	local existing = {}
	for i = 1, #warnings do
		local key = normalizeTemplateName(warnings[i] and warnings[i].name)
		if key then
			existing[key] = true
		end
	end

	local added = 0
	for i = 1, #defaultWarningTemplates do
		local template = defaultWarningTemplates[i]
		local name = normalizeBoundedText(getTemplateValue(template, "name", "fallbackName"), MAX_WARNING_NAME_BYTES)
		local content =
			normalizeBoundedText(getTemplateValue(template, "content", "fallbackContent"), MAX_WARNING_CONTENT_BYTES)
		local key = normalizeTemplateName(name)
		if key and content and not existing[key] then
			tinsert(candidate, {
				name = name,
				content = content,
			})
			existing[key] = true
			added = added + 1
		end
	end
	if added > 0 then
		local _, detail = publishMutation(warnings, candidate, "templates")
		return { added = added, total = #warnings, notificationFailed = detail.notificationFailed }
	end

	return {
		added = added,
		total = #warnings,
	}
end

function Store.BuildTemplatePreview(emptyText)
	local warnings = Store.GetStore()
	local lines = {}
	for i = 1, #warnings do
		local warning = warnings[i]
		if warning then
			lines[#lines + 1] = tostring(i)
				.. ". "
				.. tostring(warning.name or "")
				.. ": "
				.. tostring(warning.content or "")
		end
	end
	if #lines == 0 then
		lines[1] = emptyText or L.StrConfigRaidWarningPreviewEmpty or ""
	end
	return {
		text = tconcat(lines, "\n"),
		total = #warnings,
	}
end

function Store.ClearSavedWarnings(includeStock)
	local warnings = Store.GetStore()
	local removed = #warnings
	local keptStock = includeStock == false and collectStockWarnings(warnings) or nil
	local candidate = keptStock or {}
	if keptStock then
		removed = removed - #keptStock
		if removed < 0 then
			removed = 0
		end
	end
	if removed > 0 then
		local _, detail = publishMutation(warnings, candidate, "clear_saved")
		return { removed = removed, total = #warnings, notificationFailed = detail.notificationFailed }
	end
	return {
		removed = removed,
		total = #warnings,
	}
end

function Store.DeleteWarning(wID)
	local warnings = Store.GetStore()
	wID = tonumber(wID) or 0
	if warnings[wID] == nil then
		return {
			deleted = false,
			total = #warnings,
		}
	end
	local candidate = cloneWarnings(warnings)
	tremove(candidate, wID)
	local _, detail = publishMutation(warnings, candidate, "delete")
	return {
		deleted = true,
		total = #warnings,
		notificationFailed = detail.notificationFailed,
	}
end

function Store.SaveWarning(wContent, wName, wID, isEdit)
	local warnings = Store.GetStore()
	wID = tonumber(wID) or 0
	local nameReason, contentReason
	if type(wName) == "string" and Strings.TrimText(wName) ~= "" then
		wName, nameReason = validateBoundedText(wName, MAX_WARNING_NAME_BYTES, "name")
		if not wName then return nil, nameReason end
	else
		wName = tostring((isEdit and wID > 0) and wID or (#warnings + 1))
	end
	wContent, contentReason = validateBoundedText(wContent, MAX_WARNING_CONTENT_BYTES, "content")
	if not wContent then return nil, contentReason end

	local normalizedName = lower(wName)
	for i = 1, #warnings do
		if (not isEdit or i ~= wID) and lower(warnings[i].name) == normalizedName then
			return nil, "duplicate_name"
		end
	end

	local candidate = cloneWarnings(warnings)

	if isEdit and wID > 0 and candidate[wID] ~= nil then
		candidate[wID] = { name = wName, content = wContent }
		local _, detail = publishMutation(warnings, candidate, "save")
		return wID, nil, detail
	end

	candidate[#candidate + 1] = {
		name = wName,
		content = wContent,
	}
	local _, detail = publishMutation(warnings, candidate, "save")
	return #warnings, nil, detail
end
