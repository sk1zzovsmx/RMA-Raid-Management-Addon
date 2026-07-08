-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Database.SavedVariables
-- events: none
-- notes: single owner for public RMA_* SavedVariables access
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Services = feature.Services
local _G = _G
local type = type
local GetRaidStoreOrNil = assert(Database.GetRaidStoreOrNil, "SavedVariables raid store resolver is not initialized")

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

local function getRaidStore(contextTag, requiredMethods)
	return assert(GetRaidStoreOrNil(contextTag, requiredMethods), "SavedVariables raid store is not initialized")
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

function SavedVariables.WasWarningsFresh()
	return warningsFresh == true
end

function SavedVariables.GetSpammer()
	return ensureTable("RMA_Spammer")
end

function SavedVariables.GetOptions()
	return ensureTable("RMA_Options")
end

function SavedVariables.NormalizeAfterLoad()
	local raidStore = getRaidStore("SavedVariables.NormalizeAfterLoad", { "NormalizeAllRaids" })
	raidStore:NormalizeAllRaids("load")
end

function SavedVariables.PrepareForSave(contextTag)
	local raidStore = getRaidStore("SavedVariables.PrepareForSave", { "PrepareAllRaidsForSave" })
	raidStore:PrepareAllRaidsForSave()

	local saveReserves, reservesService = getReservesSave()
	saveReserves(reservesService, contextTag or "save")
end

SavedVariables.EnsureAll()

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Database/SavedVariables", {
		deps = { "Init", "Database/DB" },
	})
	registry.SetLoaded("Database/SavedVariables")
end
