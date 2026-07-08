-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Time = feature.Time or {}
addon.Time = Time

-- ----- Internal state ----- --

-- ----- Private helpers ----- --

-- ----- Public methods ----- --
function Time.GetDifficulty()
	local difficulty = nil
	local inInstance, instanceType = IsInInstance()
	if inInstance and instanceType == "raid" then
		difficulty = GetRaidDifficulty()
	end
	return difficulty
end

function Time.GetCurrentTime(server)
	if server == nil then
		server = true
	end
	local ts = time()
	if server == true then
		local _, month, day, year = CalendarGetDate()
		local hour, minute = GetGameTime()
		ts = time({ year = year, month = month, day = day, hour = hour, min = minute })
	end
	return ts
end

do
	local name = "Modules/Time"
	local deps = { "Init" }
	local registry = feature.ModuleRegistry
	if registry then
		registry.AddModule(name, { deps = deps })
		registry.SetLoaded(name)
	else
		addon.ModuleRegistryPendingRegistrations = addon.ModuleRegistryPendingRegistrations or {}
		local pending = addon.ModuleRegistryPendingRegistrations
		pending[#pending + 1] = { name = name, deps = deps, loaded = true }
	end
end
