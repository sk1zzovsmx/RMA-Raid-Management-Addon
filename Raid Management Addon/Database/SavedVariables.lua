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
local RAID_ARCHIVE_FORMAT_VERSION = 1
local raidArchiveError

-- ----- Private helpers -----
local function ensureTable(key)
	if type(_G[key]) ~= "table" then
		_G[key] = {}
	end
	return _G[key]
end

local function newRaidArchive()
	return {
		formatVersion = RAID_ARCHIVE_FORMAT_VERSION,
		activeRaidUid = nil,
		order = {},
		raids = {},
	}
end

local function ensureRaidArchive()
	local current = _G.RMA_Raids
	if
		type(current) ~= "table"
		or current.formatVersion ~= RAID_ARCHIVE_FORMAT_VERSION
	then
		current = newRaidArchive()
		_G.RMA_Raids = current
	end
	return current
end

local function getReservesSave()
	local reservesService = assert(Services.Reserves, "SavedVariables reserves service is not initialized")
	return assert(reservesService.Save, "SavedVariables reserves save handler is not initialized"), reservesService
end

-- ----- Public methods -----
function SavedVariables.EnsureAll()
	ensureRaidArchive()
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
	return ensureRaidArchive()
end

function SavedVariables.ReplaceRaids(archive)
	local validator = Database.GetRaidValidator and Database.GetRaidValidator() or nil
	local valid, reason
	if validator then
		valid, reason = validator:ValidateArchive(archive)
	end
	if validator and not valid then
		return nil, reason or "INVALID_RAID_ARCHIVE"
	end
	_G.RMA_Raids = archive
	return archive
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
	local archive = ensureRaidArchive()
	local raidStore = GetRaidStore()
	local validator = Database.GetRaidValidator and Database.GetRaidValidator() or nil
	local valid, reason
	if validator then
		valid, reason = validator:ValidateArchive(archive)
	end
	if validator and not valid then
		raidArchiveError = reason or "INVALID_RAID_ARCHIVE"
		return nil, raidArchiveError
	end
	raidArchiveError = nil
	raidStore:NormalizeAllRaids("load")
	return archive
end

function SavedVariables.PrepareForSave(contextTag)
	local raidStore = GetRaidStore()
	local archive = _G.RMA_Raids
	local validator = Database.GetRaidValidator and Database.GetRaidValidator() or nil
	local valid, reason
	if validator then
		valid, reason = validator:ValidateArchive(archive)
	end
	if validator and not valid then
		raidArchiveError = reason or "INVALID_RAID_ARCHIVE"
		return nil, raidArchiveError
	end
	raidArchiveError = nil
	local prepared, prepareError, raidIndex = raidStore:PrepareAllRaidsForSave()
	if not prepared then
		return nil, prepareError, raidIndex
	end

	local saveReserves, reservesService = getReservesSave()
	saveReserves(reservesService, contextTag or "save")
	return prepared
end

function SavedVariables.GetRaidArchiveError()
	return raidArchiveError
end

SavedVariables.EnsureAll()
