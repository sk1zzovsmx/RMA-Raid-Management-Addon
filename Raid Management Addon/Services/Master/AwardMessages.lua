-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.AwardMessages
-- events: none
-- notes: pure Master award chat message models
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")

local AwardMessages = Master.AwardMessages or {}
Master.AwardMessages = AwardMessages

local L = feature.L
local rollTypes = feature.rollTypes

local type = type

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function isEnabled(options, key)
	return type(options) == "table" and options[key] == true
end

-- ----- Public methods ----- --

function AwardMessages.BuildAssignMessages(opts)
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

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/AwardMessages", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
		},
	})
	registry.SetLoaded("Services/Master/AwardMessages")
end
