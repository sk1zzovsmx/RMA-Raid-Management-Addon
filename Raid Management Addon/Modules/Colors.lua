-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local _G = _G
local tostring, tonumber, type = tostring, tonumber, type
local strsub = string.sub
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
	local token = Colors.NormalizeClassToken(className) or "UNKNOWN"
	local hex = C.CLASS_COLORS and C.CLASS_COLORS[token]
	if hex then
		local normalized = Colors.NormalizeHexColor(hex)
		return (tonumber(strsub(normalized, 3, 4), 16) or 255) / 255,
			(tonumber(strsub(normalized, 5, 6), 16) or 255) / 255,
			(tonumber(strsub(normalized, 7, 8), 16) or 255) / 255,
			normalized
	end
	local color = _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[token]
	if color then
		return color.r or 1, color.g or 1, color.b or 1, color.colorStr or "ffffffff"
	end
	return 1, 1, 1, "ffffffff"
end

function Colors.GetClassColorHex(className)
	local token = Colors.NormalizeClassToken(className) or "UNKNOWN"
	if C.CLASS_COLORS and C.CLASS_COLORS[token] then
		return token, C.CLASS_COLORS[token]
	end
	return token, "ffffffff"
end

function Colors.WrapText(text, colorHex)
	return "|c" .. Colors.NormalizeHexColor(colorHex) .. tostring(text or "") .. "|r"
end
