-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.Options
-- events: emits OptionChanged, OptionsReset, OptionsLoaded via addon.Bus
local addon = select(2, ...)
local type, pairs, tostring, tonumber = type, pairs, tostring, tonumber
local format = string.format

local Options = addon.Options or {}
addon.Options = Options
local SavedVariables = addon.Database.SavedVariables
local Bus = addon.Bus
local coreState = addon.State

local eventRoot = addon.Events
addon.Events = eventRoot
eventRoot.Internal = eventRoot.Internal or {}
local Events = eventRoot.Internal
Events.OptionChanged = Events.OptionChanged or "OptionChanged"
Events.OptionsReset = Events.OptionsReset or "OptionsReset"
Events.OptionsLoaded = Events.OptionsLoaded or "OptionsLoaded"

local SCHEMA_VERSION = 2
local DEFAULT_LOGGER_LOOT_QUALITY_THRESHOLD = 4
local LOGGER_LOOT_QUALITY_THRESHOLDS = {
	[0] = true,
	[2] = true,
	[3] = true,
	[4] = true,
	[5] = true,
}

-- ----- Internal state ----- --
local namespaces = {}
local keyToNamespace = {}
local loaded = false

-- ----- Private helpers ----- --
local function shallowCopy(src)
	local dst = {}
	if type(src) == "table" then
		for k, v in pairs(src) do
			dst[k] = v
		end
	end
	return dst
end

local function ensureSavedTable()
	return SavedVariables.GetOptions()
end

local function applyMissingDefaults(store, defaults)
	for key, defaultValue in pairs(defaults) do
		if store[key] == nil then
			store[key] = defaultValue
		end
	end
end

local function emit(eventName, ...)
	local triggerEvent = assert(Bus.TriggerEvent, "Options event bus sender is not initialized")
	triggerEvent(eventName, ...)
end

local function applyDefaultsToStorage(name, defaults)
	local saved = ensureSavedTable()
	local store = saved[name]
	if type(store) ~= "table" then
		store = {}
		saved[name] = store
	end

	applyMissingDefaults(store, defaults)

	return store
end

local function prepareStrictStorage()
	local saved = ensureSavedTable()

	for key in pairs(saved) do
		if key == "debug" then
			saved[key] = nil
		elseif type(key) == "string" and key ~= "_schema" and namespaces[key] == nil then
			saved[key] = nil
		end
	end

	saved._schema = SCHEMA_VERSION
	return saved
end

-- ----- Namespace prototype ----- --
local namespaceMt = {}
namespaceMt.__index = namespaceMt

function namespaceMt:Get(key)
	local store = self._store
	local value = store[key]
	if value == nil then
		return self._defaults[key]
	end
	return value
end

function namespaceMt:Set(key, value)
	if type(key) ~= "string" or key == "" then
		return false
	end
	if self._defaults[key] == nil then
		addon:warn(format("Options: namespace %q has no default for key %q (rejected)", self._name, tostring(key)))
		return false
	end

	local defaultType = type(self._defaults[key])
	if value ~= nil and type(value) ~= defaultType then
		addon:warn(
			format(
				"Options: namespace %q key %q expects %s, got %s (rejected)",
				self._name,
				tostring(key),
				defaultType,
				type(value)
			)
		)
		return false
	end

	local store = self._store
	local old = store[key]
	if old == value then
		return true
	end

	store[key] = value
	emit(Events.OptionChanged, self._name, key, old, value)
	return true
end

function namespaceMt:ResetDefaults()
	local saved = ensureSavedTable()
	local fresh = shallowCopy(self._defaults)
	saved[self._name] = fresh
	self._store = fresh
	emit(Events.OptionsReset, self._name)
	return fresh
end

function namespaceMt:All()
	local out = shallowCopy(self._defaults)
	for k, v in pairs(self._store) do
		out[k] = v
	end
	return out
end

function namespaceMt:Name()
	return self._name
end

-- ----- Public methods ----- --
function Options.RegisterNamespace(name, defaults)
	if type(name) ~= "string" or name == "" then
		error("Options.RegisterNamespace: name must be a non-empty string", 2)
	end
	if type(defaults) ~= "table" then
		error("Options.RegisterNamespace: defaults must be a table", 2)
	end

	local existing = namespaces[name]
	if existing then
		-- Allow modular re-registration: each owner contributes its own keys.
		for key, defaultValue in pairs(defaults) do
			if existing._defaults[key] == nil then
				existing._defaults[key] = defaultValue
				if existing._store[key] == nil then
					existing._store[key] = defaultValue
				end
				keyToNamespace[key] = existing
			end
		end
		return existing
	end

	local store = applyDefaultsToStorage(name, defaults)
	local ns = setmetatable({
		_name = name,
		_defaults = shallowCopy(defaults),
		_store = store,
	}, namespaceMt)

	namespaces[name] = ns
	-- Reverse key-to-namespace index for the read-only `addon.options` proxy.
	-- If the same key is registered in two namespaces, the last registration wins.
	for key in pairs(defaults) do
		keyToNamespace[key] = ns
	end
	return ns
end

function Options.Get(name)
	return namespaces[name]
end

function Options.GetValue(name, key, defaultValue)
	local ns = namespaces[name]
	if ns and ns.Get then
		local value = ns:Get(key)
		if value ~= nil then
			return value
		end
	end
	return defaultValue
end

function Options.GetByKey(key, defaultValue)
	local ns = keyToNamespace[key]
	if ns and ns.Get then
		local value = ns:Get(key)
		if value ~= nil then
			return value
		end
	end
	return defaultValue
end

function Options.NormalizeLoggerLootQualityThreshold(value)
	local threshold = tonumber(value)
	if threshold and LOGGER_LOOT_QUALITY_THRESHOLDS[threshold] then
		return threshold
	end
	return DEFAULT_LOGGER_LOOT_QUALITY_THRESHOLD
end

function Options.EnsureLoaded()
	if loaded then
		return
	end
	local saved = prepareStrictStorage()

	-- Rebind storage references for namespaces registered before ADDON_LOADED.
	for name, ns in pairs(namespaces) do
		local store = saved[name]
		if type(store) ~= "table" then
			store = {}
			saved[name] = store
		end
		applyMissingDefaults(store, ns._defaults)
		ns._store = store
	end

	loaded = true
	emit(Events.OptionsLoaded)
end

-- ----- Read-only option proxy ----- --
-- `addon.options.<key>` resolves through the namespace that owns the key
-- (O(1) lookup via keyToNamespace). Writes must go through namespace:Set.
-- This avoids adding extra upvalues in files near Lua 5.1 limits (for example Master.lua).
addon.options = setmetatable({}, {
	__index = function(_, key)
		local ns = keyToNamespace[key]
		if ns then
			return ns:Get(key)
		end
		return nil
	end,
	__newindex = function(_, key)
		error(format("addon.options is read-only (key %q): use addon.Options.Get(ns):Set", tostring(key)), 2)
	end,
	__metatable = false,
})

-- Iterate via this getter to avoid exposing the internal table directly.
function Options.GetNamespaces()
	return namespaces
end

-- Convenience write when the caller does not know the namespace (for example Config UI).
-- Resolves `key` through keyToNamespace and delegates to namespace:Set. Returns false
-- when no registered namespace owns the key.
function Options.Set(key, value)
	local ns = keyToNamespace[key]
	if not ns then
		return false
	end
	return ns:Set(key, value)
end

-- ----- Debug toggle (not namespace-backed) ----- --
-- Controls only the runtime coreState.debugEnabled flag and the log level.
-- This is not persisted to SavedVariables and resets to false on each load.
function Options.IsDebugEnabled()
	return coreState and coreState.debugEnabled == true
end

function Options.SetDebugEnabled(enabled)
	coreState.debugEnabled = enabled and true or false

	local levels = addon and addon.Debugger and addon.Debugger.logLevels
	local level = enabled and (levels and levels.DEBUG) or (levels and levels.INFO)
	if level and addon and addon.SetLogLevel then
		addon:SetLogLevel(level)
	end
end
