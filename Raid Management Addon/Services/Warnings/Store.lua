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
	TriggerEvent(WarningsDataChangedEvent, reason)
end

local tconcat = table.concat
local tinsert = table.insert
local tremove = table.remove
local tonumber, tostring, type = tonumber, tostring, type
local lower = string.lower

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Warnings", "Store")
local Warnings = Services.Warnings
local Store = Warnings.Store

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
		local templateName = normalizeTemplateName(getTemplateValue(template, "name", "fallbackName"))
		local templateContent = getTemplateValue(template, "content", "fallbackContent")
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
			stock[#stock + 1] = {
				name = warning.name,
				content = warning.content,
			}
		end
	end
	return stock
end

-- ----- Public methods ----- --

function Store.GetStore()
	return SavedVariables.GetWarnings()
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
		local name = getTemplateValue(template, "name", "fallbackName")
		local key = normalizeTemplateName(name)
		if key and not existing[key] then
			tinsert(warnings, {
				name = name,
				content = getTemplateValue(template, "content", "fallbackContent"),
			})
			existing[key] = true
			added = added + 1
		end
	end
	if added > 0 then
		notifyWarningsDataChanged("templates")
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
	for i = #warnings, 1, -1 do
		tremove(warnings, i)
	end

	if keptStock then
		for i = 1, #keptStock do
			warnings[i] = keptStock[i]
		end
		removed = removed - #keptStock
		if removed < 0 then
			removed = 0
		end
	end
	if removed > 0 then
		notifyWarningsDataChanged("clear_saved")
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
	tremove(warnings, wID)
	notifyWarningsDataChanged("delete")
	return {
		deleted = true,
		total = #warnings,
	}
end

function Store.SaveWarning(wContent, wName, wID, isEdit)
	local warnings = Store.GetStore()
	wID = tonumber(wID) or 0
	wName = Strings.TrimText(wName)
	wContent = Strings.TrimText(wContent)

	if wName == "" then
		wName = (isEdit and wID > 0) and wID or (#warnings + 1)
	end
	if wContent == "" then
		return nil, "empty"
	end

	if isEdit and wID > 0 and warnings[wID] ~= nil then
		warnings[wID].name = wName
		warnings[wID].content = wContent
		notifyWarningsDataChanged("save")
		return wID
	end

	warnings[#warnings + 1] = {
		name = wName,
		content = wContent,
	}
	notifyWarningsDataChanged("save")
	return #warnings
end
