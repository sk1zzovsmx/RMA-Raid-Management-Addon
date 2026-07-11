-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local _G = _G
local tostring, type = tostring, type

local GetClassColor = addon.GetClassColor
local Colors = addon.Colors or {}
local C = addon.C or {}
addon.Colors = Colors

-- ----- Internal state ----- --

-- ----- Private helpers ----- --

-- ----- Public methods ----- --

function Colors.NormalizeClassToken(className)
	if not className then
		return nil
	end

	local token = tostring(className):upper()
	token = token:gsub("%s+", ""):gsub("%-", "")
	if C.CLASS_COLORS and C.CLASS_COLORS[token] then
		return token
	end
	if _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[token] then
		return token
	end
	return nil
end

function Colors.NormalizeHexColor(color)
	if type(color) == "string" then
		local hex = color:gsub("^|c", ""):gsub("|r$", ""):gsub("^#", "")
		if #hex == 6 then
			hex = "ff" .. hex
		end
		return hex
	end

	if type(color) == "table" and color.GenerateHexColor then
		local hex = color:GenerateHexColor():gsub("^#", "")
		if #hex == 6 then
			hex = "ff" .. hex
		end
		return hex
	end

	return "ffffffff"
end

function Colors.GetClassColor(className)
	local r, g, b = GetClassColor(className)
	return (r or 1), (g or 1), (b or 1)
end

function Colors.GetClassColorHex(className)
	local token = Colors.NormalizeClassToken(className) or "UNKNOWN"
	if C.CLASS_COLORS and C.CLASS_COLORS[token] then
		return token, C.CLASS_COLORS[token]
	end
	return token, "ffffffff"
end
