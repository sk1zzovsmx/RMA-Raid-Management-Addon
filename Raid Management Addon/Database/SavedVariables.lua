-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Database.SavedVariables
-- events: none
-- notes: single owner for public RMA_* SavedVariables access
local addon = select(2, ...)
local Diag = addon.Diag
local Database = addon.Database
local Services = addon.Services
local _G = _G
local type = type
local GetRaidStore = assert(Database.GetRaidStore, Diag.A.SavedVariablesRaidStoreResolverNotInitialized)

local SavedVariables = Database.SavedVariables or {}
Database.SavedVariables = SavedVariables
addon.Database.SavedVariables = SavedVariables

-- ----- Internal state -----
local warningsFresh = false
local RAID_ARCHIVE_FORMAT_VERSION = 1
local raidArchiveError
local raidArchiveErrorDetail
local raidArchiveFormatVersion

local RAID_ARCHIVE_CATEGORY_INVALID_TYPE = "INVALID_RAID_ARCHIVE_TYPE"
local RAID_ARCHIVE_CATEGORY_UNSUPPORTED_FORMAT = "UNSUPPORTED_RAID_ARCHIVE_FORMAT"
local RAID_ARCHIVE_CATEGORY_CORRUPT = "CORRUPT_RAID_ARCHIVE"

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
	if current == nil then
		current = newRaidArchive()
		_G.RMA_Raids = current
	end
	return current
end

local function validateRaidArchive(archive)
	if type(archive) ~= "table" then
		return nil, RAID_ARCHIVE_CATEGORY_INVALID_TYPE, "INVALID_RAID_ARCHIVE_TYPE"
	end
	if archive.formatVersion ~= RAID_ARCHIVE_FORMAT_VERSION then
		return nil, RAID_ARCHIVE_CATEGORY_UNSUPPORTED_FORMAT, "UNSUPPORTED_RAID_ARCHIVE_FORMAT"
	end
	local validator = Database.GetRaidValidator and Database.GetRaidValidator() or nil
	if validator then
		local valid, reason = validator:ValidateArchive(archive)
		if not valid then
			return nil, RAID_ARCHIVE_CATEGORY_CORRUPT, reason or "INVALID_RAID_ARCHIVE"
		end
	end
	return true
end

local function setRaidArchiveError(category, detail, archive)
	raidArchiveError = category
	raidArchiveErrorDetail = detail
	raidArchiveFormatVersion = type(archive) == "table" and archive.formatVersion or nil
end

local function clearRaidArchiveError()
	raidArchiveError = nil
	raidArchiveErrorDetail = nil
	raidArchiveFormatVersion = nil
end

local function getReservesSave()
	local reservesService = assert(Services.Reserves, Diag.A.SavedVariablesReservesServiceNotInitialized)
	return assert(reservesService.Save, Diag.A.SavedVariablesReservesSaveHandlerNotInitialized), reservesService
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
	local valid, category, detail = validateRaidArchive(archive)
	if not valid then
		setRaidArchiveError(category, detail, archive)
		return nil, raidArchiveError, raidArchiveErrorDetail
	end
	clearRaidArchiveError()
	raidStore:NormalizeAllRaids("load")
	return archive
end

function SavedVariables.PrepareForSave(contextTag)
	local raidStore = GetRaidStore()
	local archive = _G.RMA_Raids
	local valid, category, detail = validateRaidArchive(archive)
	if not valid then
		setRaidArchiveError(category, detail, archive)
		return nil, raidArchiveError, raidArchiveErrorDetail
	end
	clearRaidArchiveError()
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

function SavedVariables.GetRaidArchiveCategory()
	return raidArchiveError
end

function SavedVariables.GetRaidArchiveErrorDetail()
	return raidArchiveErrorDetail
end

function SavedVariables.GetRaidArchiveFormatVersion()
	return raidArchiveFormatVersion
end

SavedVariables.EnsureAll()
