-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local Database = addon.Database

assert(type(addon.DB) == "table", "RMA DB bootstrap missing addon.DB")
local DB = addon.DB
assert(type(DB) == "table", "RMA DB bootstrap missing addon.DB")
addon.DB = DB
local DBSchema = addon.DBSchema or {}
addon.DBSchema = DBSchema
local DBManager = addon.DBManager or {}
addon.DBManager = DBManager

local strsub = string.sub

-- ----- Internal state ----- --
DB._manager = DB._manager or nil
local DEFAULT_RAID_SCHEMA_VERSION = 6
local defaultManager = {}

-- ----- Private helpers ----- --
local function normalizeSchemaVersion(value)
	local version = tonumber(value)
	if not version or version < 1 then
		return DEFAULT_RAID_SCHEMA_VERSION
	end
	return version
end

local function getCanonicalRaidSchemaVersion()
	local version = normalizeSchemaVersion(DBSchema.RAID_SCHEMA_VERSION)
	DBSchema.RAID_SCHEMA_VERSION = version
	return version
end

local function getAddonDbStore(storeKey)
	local db = addon.DB
	if type(db) ~= "table" then
		return nil
	end
	return db[storeKey]
end

local function getDefaultManager()
	local dbManager = addon.DBManager
	if dbManager and type(dbManager.GetDefaultManager) == "function" then
		return dbManager.GetDefaultManager()
	end
	return nil
end

local function ensureManager()
	if DB._manager then
		return DB._manager
	end
	DB._manager = getDefaultManager()
	return DB._manager
end

local function getManagerStore(methodName)
	local manager = ensureManager()
	if not manager then
		return nil
	end

	local getter = manager[methodName]
	if type(getter) ~= "function" then
		return nil
	end

	return getter(manager)
end

-- ----- Package-internal helpers ----- --
local function isBossFightRecord(boss)
	if type(boss) ~= "table" then
		return false
	end

	local sourceKind = boss.sourceKind
	if sourceKind == "shared" or sourceKind == "trash" or sourceKind == "object" then
		return false
	end

	if boss.source == "LootSources" then
		return false
	end

	local name = boss.name or boss.boss
	if type(name) == "string" and strsub(name, 1, 7) == "Shared:" then
		return false
	end

	return true
end

function Database.IsBossFightRecord(boss)
	return isBossFightRecord(boss)
end

DBSchema.RAID_SCHEMA_VERSION = normalizeSchemaVersion(DBSchema.RAID_SCHEMA_VERSION)

function Database.GetRaidSchemaVersion()
	return getCanonicalRaidSchemaVersion()
end

-- ----- Public methods ----- --
function DB.SetManager(manager)
	if manager == nil or type(manager) == "table" then
		DB._manager = manager
		return true
	end

	return false
end

function DB.GetManager()
	return ensureManager()
end

function Database.GetRaidStore()
	local raidStore = DB.RaidStore
	assert(type(raidStore) == "table", "RMA RaidStore is not initialized")
	return raidStore
end

function Database.GetRaidQueries()
	return getManagerStore("GetRaidQueries")
end

function Database.GetRaidMigrations()
	return getManagerStore("GetRaidMigrations")
end

function Database.GetRaidValidator()
	return getManagerStore("GetRaidValidator")
end

function Database.GetSyncer()
	return getManagerStore("GetSyncer")
end

function defaultManager:GetRaidStore()
	return getAddonDbStore("RaidStore")
end

function defaultManager:GetRaidQueries()
	return getAddonDbStore("RaidQueries")
end

function defaultManager:GetRaidMigrations()
	return getAddonDbStore("RaidMigrations")
end

function defaultManager:GetRaidValidator()
	return getAddonDbStore("RaidValidator")
end

function defaultManager:GetSyncer()
	return getAddonDbStore("Syncer")
end

function DBManager.GetDefaultManager()
	return defaultManager
end
