-- ----- RMA Lua Contract ----- --
-- deps: bootstrap, options, localization
-- shared: command-point registry used by runtime modules
-- exports: addon.EntryPoints.Debug
-- events: no direct event registrations
local addon = select(2, ...)
local L = addon.L
local Options = addon.Options

local type, tostring = type, tostring
local format = string.format
local match = string.match
local sort = table.sort
local concat = table.concat

addon.EntryPoints = addon.EntryPoints or {}
local module = {}
addon.EntryPoints.Debug = module

local commands = {}
local commandsByName = {}

local function splitArgs(value)
	local command, rest = match(value or "", "^%s*(%S*)%s*(.-)%s*$")
	return command or "", rest or ""
end

local function printHelp(usage, description)
	local colors = addon.Colors
	local color = addon.C and addon.C.MA_COLOR
	local text = "/rma debug " .. usage
	if colors and color and colors.WrapText then
		text = colors.WrapText(text, colors.NormalizeHexColor(color))
	end
	addon:info("%s: %s", text, description)
end

local function getLogLevelName(level)
	for name, value in pairs(addon.logLevels or {}) do
		if value == level then
			return tostring(name)
		end
	end
	return tostring(level or L.StrUnknown)
end

-- Registers one Debug command point owned by a runtime module.
function module.RegisterCommand(command, usage, description, handler)
	if type(command) ~= "string" or command == "" or type(usage) ~= "string" or type(handler) ~= "function" then
		return nil, "invalid_debug_command"
	end
	if commandsByName[command] then
		return nil, "duplicate_debug_command"
	end
	local entry = {
		command = command,
		usage = usage,
		description = description or "",
		handler = handler,
	}
	commandsByName[command] = entry
	commands[#commands + 1] = entry
	sort(commands, function(left, right)
		return left.command < right.command
	end)
	return true
end

-- Returns the currently registered command reference for the Config Help panel.
function module.GetHelpText()
	local lines = { L.StrConfigHelpDebugCommandsTitle }
	for i = 1, #commands do
		local entry = commands[i]
		lines[#lines + 1] = "/rma debug " .. entry.usage .. ": " .. entry.description
	end
	return concat(lines, "\n")
end

-- Shows the command reference in chat.
function module.ShowHelp()
	addon:info(format(L.StrCmdCommands, "RMA debug"), "RMA")
	for i = 1, #commands do
		local entry = commands[i]
		printHelp(entry.usage, entry.description)
	end
end

-- Dispatches a Debug command to its registered owner.
function module.Handle(rest)
	local command, argument = splitArgs(rest)
	if command == "" then
		command = "toggle"
	elseif command == "help" then
		module.ShowHelp()
		return
	end
	local entry = commandsByName[command]
	if not entry then
		module.ShowHelp()
		return
	end
	return entry.handler(argument)
end

module.RegisterCommand("toggle", "toggle", L.StrCmdToggle, function()
	Options.SetDebugEnabled(not Options.IsDebugEnabled())
	addon:info(Options.IsDebugEnabled() and L.MsgDebugOn or L.MsgDebugOff)
end)

module.RegisterCommand("on", "on", L.StrCmdToggle, function()
	Options.SetDebugEnabled(true)
	addon:info(L.MsgDebugOn)
end)

module.RegisterCommand("off", "off", L.StrCmdToggle, function()
	Options.SetDebugEnabled(false)
	addon:info(L.MsgDebugOff)
end)

module.RegisterCommand("levels", "levels", L.MsgLogLevelList, function()
	addon:info(L.MsgLogLevelList)
end)

module.RegisterCommand("level", "level <name|num>", L.StrCmdDebugLevel, function(argument)
	if argument == "" then
		addon:info(L.MsgLogLevelCurrent, getLogLevelName(addon.GetLogLevel and addon:GetLogLevel()))
		addon:info(L.MsgLogLevelList)
		return
	end
	local level = tonumber(argument)
	if not level and addon.logLevels then
		level = addon.logLevels[string.upper(argument)]
	end
	if not level then
		addon:warn(L.MsgLogLevelUnknown, argument)
		return
	end
	addon:SetLogLevel(level)
	addon:info(L.MsgLogLevelSet, argument)
end)
