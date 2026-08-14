-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.Messages
-- events: none
-- notes: pure Master chat and announcement message-plan models
local addon = select(2, ...)
local Master = addon.Services.EnsureNamespace("Master")

local Messages = Master.Messages or {}
Master.Messages = Messages

local L = addon.L
local rollTypes = addon.C.rollTypes

local tonumber = tonumber
local type = type

-- ----- Private helpers ----- --

local function isEnabled(options, key)
	return type(options) == "table" and options[key] == true
end

local function buildLootSpamHeader(sourceName)
	local template = L.ChatSpamLootFrom
	if sourceName and type(template) == "string" and template:find("%s", 1, true) then
		return template:format(sourceName)
	end
	return L.ChatSpamLoot
end

local function resolveRollAnnouncementSuffix(sortAscending)
	if sortAscending == true then
		return L.StrRollLow
	end
	return L.StrRollHigh
end

local function getTemplate(key)
	if type(key) ~= "string" or key == "" then
		return nil
	end
	return L[key]
end

-- ----- Public methods ----- --

function Messages.BuildAssignMessages(opts)
	opts = opts or {}
	local options = opts.options or {}
	local rollType = opts.rollType
	local output
	local whisper

	if
		rollType
		and rollType >= rollTypes.MAINSPEC
		and rollType <= rollTypes.FREE
		and isEnabled(options, "announceOnWin")
	then
		output = L.ChatAward:format(opts.playerName, opts.itemLink)
	elseif rollType == rollTypes.HOLD and isEnabled(options, "announceOnHold") then
		output = L.ChatHold:format(opts.playerName, opts.itemLink)
		if opts.lootWhispers then
			whisper = L.WhisperHoldAssign:format(opts.itemLink)
		end
	elseif rollType == rollTypes.BANK and isEnabled(options, "announceOnBank") then
		output = L.ChatBank:format(opts.playerName, opts.itemLink)
		if opts.lootWhispers then
			whisper = L.WhisperBankAssign:format(opts.itemLink)
		end
	elseif rollType == rollTypes.DISENCHANT and isEnabled(options, "announceOnDisenchant") then
		output = L.ChatDisenchant:format(opts.itemLink, opts.playerName)
		if opts.lootWhispers then
			whisper = L.WhisperDisenchantAssign:format(opts.itemLink)
		end
	end
	return output, whisper
end

function Messages.BuildLootSpamPlan(opts)
	opts = opts or {}
	local items = opts.items or {}
	local lootLines = {}
	local reservedLines = {}
	local reservedCount = 0

	for i = 1, #items do
		local item = items[i]
		if item and item.itemLink then
			local count = tonumber(item.count) or 1
			local suffix = count > 1 and (" x" .. count) or ""
			lootLines[#lootLines + 1] = (tonumber(item.index) or i) .. ". " .. item.itemLink .. suffix
			if item.reservedPlayers and item.reservedPlayers ~= "" then
				reservedCount = reservedCount + 1
				reservedLines[reservedCount] = L.ChatSpamLootReservedLine:format(
					reservedCount,
					item.itemLink,
					item.reservedPlayers
				)
			end
		end
	end

	return {
		header = buildLootSpamHeader(opts.sourceName),
		lootLines = lootLines,
		reservedHeader = reservedCount > 0 and L.ChatSpamLootReservedHeader or nil,
		reservedLines = reservedLines,
	}
end

function Messages.BuildRollAnnouncementPlan(opts)
	opts = opts or {}
	local chatKey = opts.chatKey
	local suffix = resolveRollAnnouncementSuffix(opts.sortAscending)
	local itemLink = opts.itemLink
	local selectedItemCount = tonumber(opts.selectedItemCount) or 1
	if selectedItemCount < 1 then
		selectedItemCount = 1
	end

	local message
	if opts.rollType == rollTypes.RESERVED then
		local srList = opts.srList or ""
		if selectedItemCount > 1 then
			message = getTemplate(chatKey .. "Multiple" .. suffix):format(srList, itemLink, selectedItemCount)
		else
			message = getTemplate(chatKey):format(srList, itemLink)
		end
		return {
			message = message,
			srList = srList,
			suffix = suffix,
		}
	end

	if selectedItemCount > 1 then
		message = getTemplate(chatKey .. "Multiple" .. suffix):format(itemLink, selectedItemCount)
	else
		message = getTemplate(chatKey):format(itemLink)
	end
	return {
		message = message,
		suffix = suffix,
	}
end
