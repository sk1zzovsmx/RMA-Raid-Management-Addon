-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish selection APIs on addon.UI.Selection
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Diag = feature.Diag
local coreState = feature.coreState

local pairs, tostring, tonumber, type = pairs, tostring, tonumber, type

local UI = feature.UI or {}
local Selection = UI.Selection or {}
UI.Selection = Selection

-- ----- Internal state ----- --
local stateByContext = Selection._stateByContext or {}
Selection._stateByContext = stateByContext

local modifierPolicyByScope = Selection._modifierPolicyByScope or {}
Selection._modifierPolicyByScope = modifierPolicyByScope

-- ----- Private helpers ----- --
local function normalizeScopeKey(scopeKey)
	if not scopeKey or scopeKey == "" then
		return "_default"
	end
	return scopeKey
end

local function normalizeModifierPolicy(policy)
	local normalized = {
		allowMulti = true,
		allowRange = true,
	}

	if policy == false then
		normalized.allowMulti = false
		normalized.allowRange = false
		return normalized
	end

	if type(policy) ~= "table" then
		return normalized
	end

	if policy.allowMulti ~= nil then
		normalized.allowMulti = policy.allowMulti and true or false
	end
	if policy.allowRange ~= nil then
		normalized.allowRange = policy.allowRange and true or false
	end

	return normalized
end

if not modifierPolicyByScope._default then
	modifierPolicyByScope._default = normalizeModifierPolicy(nil)
end

local function debugLog(msg)
	if coreState and coreState.debugEnabled and addon.debug then
		addon:debug(msg)
	end
end

local function msKey(id)
	if id == nil then
		return nil
	end
	local n = tonumber(id)
	return n or id
end

local function ensureContext(contextKey)
	contextKey = normalizeScopeKey(contextKey)
	local st = stateByContext[contextKey]
	if not st then
		st = { set = {}, count = 0, ver = 0 }
		stateByContext[contextKey] = st
	end
	return st, contextKey
end

local function idOf(value)
	if type(value) == "table" then
		return value.id
	end
	return value
end

local function findIndex(ordered, key)
	if not ordered or not key then
		return nil
	end
	for i = 1, #ordered do
		local id = idOf(ordered[i])
		if msKey(id) == key then
			return i
		end
	end
	return nil
end

-- ----- Public methods ----- --
local function getModifierPolicy(scopeKey)
	local key = normalizeScopeKey(scopeKey)
	local policy = modifierPolicyByScope[key] or modifierPolicyByScope._default or normalizeModifierPolicy(nil)
	return policy.allowMulti ~= false, policy.allowRange ~= false
end

function Selection.EnsureState(contextKey)
	local st, key = ensureContext(contextKey)
	st.set = {}
	st.count = 0
	st.ver = (st.ver or 0) + 1
	debugLog((Diag.D.LogLoggerSelectInit):format(tostring(key), st.ver))
	return st
end

function Selection.SetModifierPolicy(scopeKey, policy)
	local key = normalizeScopeKey(scopeKey)

	if policy == nil then
		if key == "_default" then
			modifierPolicyByScope[key] = normalizeModifierPolicy(nil)
		else
			modifierPolicyByScope[key] = nil
		end
		return
	end

	modifierPolicyByScope[key] = normalizeModifierPolicy(policy)
end

function Selection.ResolveModifiers(scopeKey, opts)
	local policyAllowMulti, policyAllowRange = getModifierPolicy(scopeKey)
	local allowMulti = policyAllowMulti
	local allowRange = policyAllowRange

	if type(opts) == "table" then
		if opts.singleOnly == true or opts.forceSingle == true then
			allowMulti = false
			allowRange = false
		end

		-- Per-call overrides can only narrow the policy (never re-enable a disabled modifier).
		if opts.allowMulti == false then
			allowMulti = false
		end
		if opts.allowRange == false then
			allowRange = false
		end
	end

	if not policyAllowMulti then
		allowMulti = false
	end
	if not policyAllowRange then
		allowRange = false
	end

	local isMulti = allowMulti and ((IsControlKeyDown and IsControlKeyDown()) or false) or false
	local isRange = allowRange and ((IsShiftKeyDown and IsShiftKeyDown()) or false) or false
	return isMulti, isRange
end

function Selection.Toggle(contextKey, id, isMulti, allowDeselect)
	local st, key = ensureContext(contextKey)
	local k = msKey(id)
	if k == nil then
		return nil, st.count or 0
	end

	local before = st.count or 0
	local action

	local allow = false
	if allowDeselect == true then
		allow = true
	elseif type(allowDeselect) == "table" and allowDeselect.allowDeselect == true then
		allow = true
	end

	if isMulti then
		if st.set[k] then
			st.set[k] = nil
			st.count = before - 1
			action = "TOGGLE_OFF"
		else
			st.set[k] = true
			st.count = before + 1
			action = "TOGGLE_ON"
		end
	else
		local already = (st.set[k] == true)
		if allow and already and before == 1 then
			st.set = {}
			st.count = 0
			action = "SINGLE_DESELECT"
		else
			st.set = {}
			st.set[k] = true
			st.count = 1
			action = "SINGLE_CLEAR+SELECT"
		end
	end

	st.ver = (st.ver or 0) + 1

	debugLog(
		(Diag.D.LogLoggerSelectToggle):format(
			tostring(key),
			tostring(id),
			isMulti and "1" or "0",
			tostring(action),
			before,
			st.count or 0,
			st.ver
		)
	)

	return action, st.count or 0
end

function Selection.SetAnchor(contextKey, id)
	local st, key = ensureContext(contextKey)
	local before = st.anchor
	local k = msKey(id)
	st.anchor = k
	local ver = st.ver or 0
	debugLog((Diag.D.LogLoggerSelectAnchor):format(tostring(key), tostring(before), tostring(st.anchor), ver))
	return st.anchor
end

function Selection.GetAnchor(contextKey)
	local st = stateByContext[contextKey or "_default"]
	return st and st.anchor or nil
end

function Selection.SelectRange(contextKey, ordered, id, isAdd)
	local st, key = ensureContext(contextKey)
	local k = msKey(id)
	if k == nil then
		return nil, st.count or 0
	end

	local before = st.count or 0
	local action

	local anchorKey = st.anchor
	local ai = findIndex(ordered, anchorKey)
	local bi = findIndex(ordered, k)

	if not ai or not bi then
		st.set = {}
		st.set[k] = true
		st.count = 1
		if not st.anchor then
			st.anchor = k
		end
		action = st.anchor == k and "RANGE_NOANCHOR_SINGLE" or "RANGE_FALLBACK_SINGLE"
	else
		if not isAdd then
			st.set = {}
			st.count = 0
		end
		local from = ai
		local to = bi
		if from > to then
			from, to = to, from
		end

		for i = from, to do
			local id2 = idOf(ordered[i])
			local k2 = msKey(id2)
			if k2 ~= nil and not st.set[k2] then
				st.set[k2] = true
				st.count = (st.count or 0) + 1
			end
		end
		action = isAdd and "RANGE_ADD" or "RANGE_SET"
	end

	st.ver = (st.ver or 0) + 1
	debugLog(
		(Diag.D.LogLoggerSelectRange):format(
			tostring(key),
			tostring(id),
			isAdd and "1" or "0",
			tostring(action),
			before,
			st.count or 0,
			st.ver,
			tostring(st.anchor)
		)
	)
	return action, st.count or 0
end

function Selection.IsSelected(contextKey, id)
	local st = stateByContext[contextKey or "_default"]
	if not st or not st.set then
		return false
	end
	local k = msKey(id)
	return (k ~= nil) and (st.set[k] == true) or false
end

function Selection.GetCount(contextKey)
	local st = stateByContext[contextKey or "_default"]
	return (st and st.count) or 0
end

function Selection.GetVersion(contextKey)
	local st = stateByContext[contextKey or "_default"]
	return (st and st.ver) or 0
end

function Selection.GetSelected(contextKey)
	local st = stateByContext[contextKey or "_default"]
	local out = {}
	if not st or not st.set then
		return out
	end
	local n = 0
	for id, selected in pairs(st.set) do
		if selected then
			n = n + 1
			out[n] = id
		end
	end
	table.sort(out, function(a, b)
		local na, nb = tonumber(a), tonumber(b)
		if na and nb then
			return na < nb
		end
		return tostring(a) < tostring(b)
	end)
	return out
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Modules/UI/MultiSelect", { deps = { "Init", "Modules/ModuleRegistry" } })
	registry.SetLoaded("Modules/UI/MultiSelect")
end
