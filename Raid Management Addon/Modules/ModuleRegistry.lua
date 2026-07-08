-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local type = type

local ModuleRegistry = feature.ModuleRegistry or {}
addon.ModuleRegistry = ModuleRegistry

-- ----- Internal state ----- --
local modules = {}
local modulesByName = {}
local registrationOrder = 0
local loadOrder = 0

-- ----- Private helpers ----- --
local function copyDeps(deps)
	local out = {}
	if type(deps) ~= "table" then
		return out
	end

	for i = 1, #deps do
		out[i] = deps[i]
	end
	return out
end

local function ensureRecord(name)
	local record = modulesByName[name]
	if record then
		return record
	end

	registrationOrder = registrationOrder + 1
	record = {
		Name = name,
		Deps = {},
		Loaded = false,
		RegisteredOrder = registrationOrder,
	}
	modules[#modules + 1] = record
	modulesByName[name] = record
	return record
end

local function copyRecord(record)
	if not record then
		return nil
	end

	return {
		Name = record.Name,
		Deps = copyDeps(record.Deps),
		Loaded = record.Loaded == true,
		LoadOrder = record.LoadOrder,
		RegisteredOrder = record.RegisteredOrder,
	}
end

local function clearArray(out)
	for i = #out, 1, -1 do
		out[i] = nil
	end
end

-- ----- Public methods ----- --
function ModuleRegistry.AddModule(name, cfg)
	if type(name) ~= "string" or name == "" then
		return nil
	end

	local record = ensureRecord(name)
	record.Deps = copyDeps(cfg and cfg.deps)
	return copyRecord(record)
end

function ModuleRegistry.SetLoaded(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end

	local record = ensureRecord(name)
	record.Loaded = true
	if not record.LoadOrder then
		loadOrder = loadOrder + 1
		record.LoadOrder = loadOrder
	end
	return copyRecord(record)
end

function ModuleRegistry.GetStatus(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return copyRecord(modulesByName[name])
end

function ModuleRegistry.GetModules(out)
	out = type(out) == "table" and out or {}
	clearArray(out)
	for i = 1, #modules do
		out[i] = copyRecord(modules[i])
	end
	return out
end

function ModuleRegistry.GetLoadOrderStatus()
	local issues
	for i = 1, #modules do
		local record = modules[i]
		for j = 1, #record.Deps do
			local depName = record.Deps[j]
			local dep = modulesByName[depName]
			if not dep or dep.Loaded ~= true then
				issues = issues or {}
				issues[#issues + 1] = {
					module = record.Name,
					dependency = depName,
					reason = "missing",
				}
			elseif
				record.Loaded == true
				and record.LoadOrder
				and dep.LoadOrder
				and dep.LoadOrder > record.LoadOrder
			then
				issues = issues or {}
				issues[#issues + 1] = {
					module = record.Name,
					dependency = depName,
					reason = "out_of_order",
				}
			end
		end
	end

	if issues then
		return false, issues
	end
	return true, nil
end

local pendingLoads = addon.ModuleRegistryPendingLoads
if type(pendingLoads) == "table" then
	for i = 1, #pendingLoads do
		ModuleRegistry.SetLoaded(pendingLoads[i])
		pendingLoads[i] = nil
	end
end

local pendingRegistrations = addon.ModuleRegistryPendingRegistrations
if type(pendingRegistrations) == "table" then
	for i = 1, #pendingRegistrations do
		local entry = pendingRegistrations[i]
		if type(entry) == "table" then
			ModuleRegistry.AddModule(entry.name, { deps = entry.deps })
			if entry.loaded == true then
				ModuleRegistry.SetLoaded(entry.name)
			end
		end
		pendingRegistrations[i] = nil
	end
end

ModuleRegistry.AddModule("Modules/ModuleRegistry", { deps = { "Init" } })
ModuleRegistry.SetLoaded("Modules/ModuleRegistry")
