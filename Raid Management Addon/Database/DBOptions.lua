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
local function copyOptionValue(value, seen)
	if type(value) ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] then
		return seen[value]
	end

	local copied = {}
	seen[value] = copied
	for key, nestedValue in pairs(value) do
		copied[copyOptionValue(key, seen)] = copyOptionValue(nestedValue, seen)
	end
	return copied
end

local function optionValuesEquivalent(left, right, leftSeen, rightSeen)
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end

	leftSeen = leftSeen or {}
	rightSeen = rightSeen or {}
	if leftSeen[left] or rightSeen[right] then
		return leftSeen[left] == right and rightSeen[right] == left
	end

	leftSeen[left] = right
	rightSeen[right] = left
	local rightCount = 0
	for _ in pairs(right) do
		rightCount = rightCount + 1
	end
	for key, value in pairs(left) do
		rightCount = rightCount - 1
		if rightCount < 0 or not optionValuesEquivalent(value, right[key], leftSeen, rightSeen) then
			return false
		end
	end
	return rightCount == 0
end

local function validateDefaultKeys(defaults)
	for key in pairs(defaults) do
		if type(key) ~= "string" or key == "" then
			error("Options.RegisterNamespace: option keys must be non-empty strings", 3)
		end
	end
end

local function ensureSavedTable()
	return SavedVariables.GetOptions()
end

local function normalizeOptionStore(store, defaults, removeUnknown)
	if removeUnknown then
		for key in pairs(store) do
			if type(key) ~= "string" or defaults[key] == nil then
				store[key] = nil
			end
		end
	end

	for key, defaultValue in pairs(defaults) do
		if type(store[key]) ~= type(defaultValue) then
			store[key] = copyOptionValue(defaultValue)
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

	normalizeOptionStore(store, defaults, loaded)

	return store
end

local function prepareStrictStorage()
	local saved = ensureSavedTable()

	for key in pairs(saved) do
		if type(key) ~= "string" or (key ~= "_schema" and namespaces[key] == nil) then
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
	local fresh = copyOptionValue(self._defaults)
	saved[self._name] = fresh
	self._store = fresh
	emit(Events.OptionsReset, self._name)
	return fresh
end

function namespaceMt:All()
	local out = copyOptionValue(self._defaults)
	local stored = copyOptionValue(self._store)
	for k, v in pairs(stored) do
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
	validateDefaultKeys(defaults)

	local existing = namespaces[name]
	if existing then
		-- Allow modular re-registration: each owner contributes its own keys.
		for key, defaultValue in pairs(defaults) do
			local registeredDefault = existing._defaults[key]
			if registeredDefault ~= nil and not optionValuesEquivalent(registeredDefault, defaultValue) then
				error(
					format(
						"Options.RegisterNamespace: key %q has an incompatible declaration in namespace %q",
						key,
						name
					),
					2
				)
			end
			local owner = keyToNamespace[key]
			if owner and owner ~= existing then
				error(format("Options.RegisterNamespace: key %q is already owned by namespace %q", key, owner._name), 2)
			end
		end
		for key, defaultValue in pairs(defaults) do
			if existing._defaults[key] == nil then
				existing._defaults[key] = copyOptionValue(defaultValue)
				if type(existing._store[key]) ~= type(defaultValue) then
					existing._store[key] = copyOptionValue(defaultValue)
				end
				keyToNamespace[key] = existing
			end
		end
		return existing
	end

	for key in pairs(defaults) do
		local owner = keyToNamespace[key]
		if owner then
			error(format("Options.RegisterNamespace: key %q is already owned by namespace %q", key, owner._name), 2)
		end
	end

	local copiedDefaults = copyOptionValue(defaults)
	local store = applyDefaultsToStorage(name, copiedDefaults)
	local ns = setmetatable({
		_name = name,
		_defaults = copiedDefaults,
		_store = store,
	}, namespaceMt)

	namespaces[name] = ns
	-- Reverse key-to-namespace index for the read-only `addon.options` proxy.
	-- Ownership is unique so the read-only option proxy remains unambiguous.
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
		normalizeOptionStore(store, ns._defaults, true)
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

function Options.ResetAllDefaults()
	for _, ns in pairs(namespaces) do
		ns:ResetDefaults()
	end
	return true
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
