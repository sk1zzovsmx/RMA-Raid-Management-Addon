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

local strsub = string.sub

addon.Events = addon.Events or {}
addon.Events.Internal = addon.Events.Internal or {}
addon.Events.Internal.RaidReplicationCommitted = addon.Events.Internal.RaidReplicationCommitted
	or "RaidReplicationCommitted"

-- ----- Internal state ----- --
local DEFAULT_RAID_SCHEMA_VERSION = 6

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

local function getRequiredOwner(ownerKey)
	local owner = DB[ownerKey]
	assert(type(owner) == "table", "RMA " .. tostring(ownerKey) .. " is not initialized")
	return owner
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

function Database.GetRaidStore()
	return getRequiredOwner("RaidStore")
end

function Database.GetRaidQueries()
	return getRequiredOwner("RaidQueries")
end

function Database.GetRaidValidator()
	return getRequiredOwner("RaidValidator")
end

function Database.GetSyncer()
	return getRequiredOwner("Syncer")
end
