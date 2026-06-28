-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Database = feature.Database
local Diag = feature.Diag

assert(type(addon.DB) == "table", "RMA DB bootstrap missing addon.DB")
local DB = feature.DB
assert(type(DB) == "table", "RMA DB bootstrap missing feature.DB")
addon.DB = DB
local DBSchema = feature.DBSchema or {}
addon.DBSchema = DBSchema
feature.DBSchema = DBSchema
local DBManager = feature.DBManager or {}
addon.DBManager = DBManager
feature.DBManager = DBManager

local strsub = string.sub

-- ----- Internal state ----- --
DB._manager = DB._manager or nil
DBManager.SavedVariables = DBManager.SavedVariables or {}
local SavedVariablesManager = DBManager.SavedVariables
local DEFAULT_RAID_SCHEMA_VERSION = 6
local missingRaidStoreWarned = {}

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
    local db = feature.DB
    if type(db) ~= "table" then
        return nil
    end
    return db[storeKey]
end

local function getDefaultManager()
    local dbManager = feature.DBManager
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

local function warnMissingRaidStoreOnce(warnKey, template, fallbackFmt, arg1, arg2)
    if missingRaidStoreWarned[warnKey] then
        return
    end

    missingRaidStoreWarned[warnKey] = true
    if type(template) == "string" then
        addon:warn(template:format(arg1, arg2))
    else
        addon:warn(fallbackFmt, arg1, arg2)
    end
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

function Database.GetRaidStoreOrNil(contextTag, requiredMethods)
    local raidStore = getManagerStore("GetRaidStore")
    local ctx = tostring(contextTag or "?")

    if type(raidStore) ~= "table" then
        local warnKey = "store:" .. ctx
        local template = Diag.W and Diag.W.LogRaidStoreUnavailable
        warnMissingRaidStoreOnce(warnKey, template, "[Database] RaidStore unavailable (context=%s)", ctx)
        return nil
    end

    if type(requiredMethods) == "table" then
        for i = 1, #requiredMethods do
            local method = requiredMethods[i]
            if type(method) == "string" and method ~= "" and type(raidStore[method]) ~= "function" then
                local warnKey = "method:" .. ctx .. ":" .. method
                local template = Diag.W and Diag.W.LogRaidStoreMethodMissing
                warnMissingRaidStoreOnce(warnKey, template, "[Database] RaidStore missing method %s (context=%s)", method, ctx)
                return nil
            end
        end
    end

    return raidStore
end

function Database.GetRaidQueries()
    return getManagerStore("GetRaidQueries")
end

function Database.GetRaidQueriesOrNil()
    if type(Database.GetRaidQueries) ~= "function" then
        return nil
    end

    return Database.GetRaidQueries()
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

function SavedVariablesManager:GetRaidStore()
    return getAddonDbStore("RaidStore")
end

function SavedVariablesManager:GetRaidQueries()
    return getAddonDbStore("RaidQueries")
end

function SavedVariablesManager:GetRaidMigrations()
    return getAddonDbStore("RaidMigrations")
end

function SavedVariablesManager:GetRaidValidator()
    return getAddonDbStore("RaidValidator")
end

function SavedVariablesManager:GetSyncer()
    return getAddonDbStore("Syncer")
end

function DBManager.GetDefaultManager()
    return SavedVariablesManager
end

local function registerBootstrapModule(name, deps)
    -- Bootstrap exception: ModuleRegistry may not be loaded yet.
    local registry = addon.ModuleRegistry
    if registry then
        registry.AddModule(name, { deps = deps })
        registry.SetLoaded(name)
    else
        addon.ModuleRegistryPendingRegistrations = addon.ModuleRegistryPendingRegistrations or {}
        local pending = addon.ModuleRegistryPendingRegistrations
        pending[#pending + 1] = { name = name, deps = deps, loaded = true }
    end
end

do
    local name = "Database/DB"
    local deps = { "Init" }
    registerBootstrapModule(name, deps)
end

do
    local name = "Database/DBSchema"
    local deps = { "Init" }
    registerBootstrapModule(name, deps)
end

do
    local name = "Database/DBManager"
    local deps = { "Init", "Database/DB" }
    registerBootstrapModule(name, deps)
end

