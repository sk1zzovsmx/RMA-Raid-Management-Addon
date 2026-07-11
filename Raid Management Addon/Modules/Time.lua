-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local Time = addon.Time or {}
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
