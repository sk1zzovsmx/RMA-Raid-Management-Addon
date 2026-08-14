-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Database.SavedVariables
-- events: none
-- notes: single owner for public RMA_* SavedVariables access
local addon = select(2, ...)
local Database = addon.Database
local Services = addon.Services
local _G = _G
local type = type
local GetRaidStore = assert(Database.GetRaidStore, "SavedVariables raid store resolver is not initialized")

local SavedVariables = Database.SavedVariables or {}
Database.SavedVariables = SavedVariables
addon.Database.SavedVariables = SavedVariables

-- ----- Internal state -----
local warningsFresh = false

-- ----- Private helpers -----
local function ensureTable(key)
	if type(_G[key]) ~= "table" then
		_G[key] = {}
	end
	return _G[key]
end

local function getReservesSave()
	local reservesService = assert(Services.Reserves, "SavedVariables reserves service is not initialized")
	return assert(reservesService.Save, "SavedVariables reserves save handler is not initialized"), reservesService
end

-- ----- Public methods -----
function SavedVariables.EnsureAll()
	ensureTable("RMA_Raids")
	ensureTable("RMA_Players")
	ensureTable("RMA_Reserves")
	warningsFresh = type(_G.RMA_Warnings) ~= "table"
	addon.State.warningsSavedVariablesFresh = warningsFresh
	ensureTable("RMA_Warnings")
	ensureTable("RMA_Spammer")
	ensureTable("RMA_Options")
	return SavedVariables
end

function SavedVariables.GetRaids()
	return ensureTable("RMA_Raids")
end

function SavedVariables.GetPlayers()
	return ensureTable("RMA_Players")
end

function SavedVariables.GetReserves()
	return ensureTable("RMA_Reserves")
end

function SavedVariables.ReplaceReserves(value)
	_G.RMA_Reserves = type(value) == "table" and value or {}
	return _G.RMA_Reserves
end

function SavedVariables.ClearReserves()
	_G.RMA_Reserves = nil
	return nil
end

function SavedVariables.GetWarnings()
	return ensureTable("RMA_Warnings")
end

function SavedVariables.GetSpammer()
	return ensureTable("RMA_Spammer")
end

function SavedVariables.GetOptions()
	return ensureTable("RMA_Options")
end

function SavedVariables.NormalizeAfterLoad()
	local raidStore = GetRaidStore()
	raidStore:NormalizeAllRaids("load")
end

function SavedVariables.PrepareForSave(contextTag)
	local raidStore = GetRaidStore()
	local prepared, prepareError, raidIndex = raidStore:PrepareAllRaidsForSave()
	if not prepared then
		return nil, prepareError, raidIndex
	end

	local saveReserves, reservesService = getReservesSave()
	saveReserves(reservesService, contextTag or "save")
	return prepared
end

SavedVariables.EnsureAll()
