-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local type, tostring, tonumber = type, tostring, tonumber
local byte, strlen, strsub = string.byte, string.len, string.sub
local find, gsub = string.find, string.gsub
local format = string.format
local lower, upper = string.lower, string.upper
local concat = table.concat

local GetAchievementLink = GetAchievementLink

local Colors = addon.Colors or {}

local Strings = addon.Strings or {}
addon.Strings = Strings

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function trimRaw(value)
	if value == nil then
		return ""
	end
	return gsub(tostring(value), "^%s*(.-)%s*$", "%1")
end

local function upperFirst(value)
	if type(value) ~= "string" then
		value = tostring(value or "")
	end
	value = lower(value)
	return gsub(value, "%a", upper, 1)
end

local function encodeCSVField(value)
	if value == nil then
		return ""
	end
	local text = tostring(value)
	if find(text, '[",\r\n]') then
		return '"' .. gsub(text, '"', '""') .. '"'
	end
	return text
end

local function utf8SequenceLength(firstByte)
	if firstByte <= 0x7f then
		return 1
	end
	if firstByte >= 0xc2 and firstByte <= 0xdf then
		return 2
	end
	if firstByte >= 0xe0 and firstByte <= 0xef then
		return 3
	end
	if firstByte >= 0xf0 and firstByte <= 0xf4 then
		return 4
	end
	return nil
end

local function isValidUtf8Sequence(text, index, sequenceLength)
	local firstByte = byte(text, index)
	for offset = 1, sequenceLength - 1 do
		local continuation = byte(text, index + offset)
		if not continuation or continuation < 0x80 or continuation > 0xbf then
			return false
		end
		if offset == 1 then
			if firstByte == 0xe0 and continuation < 0xa0 then
				return false
			end
			if firstByte == 0xed and continuation > 0x9f then
				return false
			end
			if firstByte == 0xf0 and continuation < 0x90 then
				return false
			end
			if firstByte == 0xf4 and continuation > 0x8f then
				return false
			end
		end
	end
	return true
end

-- ----- Public methods ----- --
function Strings.TrimText(value, allowNil)
	if value == nil then
		return allowNil and nil or ""
	end
	return trimRaw(value)
end

function Strings.Utf8SafePrefix(text, maxBytes)
	if type(text) ~= "string" then
		return ""
	end
	local limit = tonumber(maxBytes) or 0
	if limit <= 0 then
		return ""
	end
	local index, lastValid, textLength = 1, 0, strlen(text)
	while index <= textLength do
		local sequenceLength = utf8SequenceLength(byte(text, index))
		if not sequenceLength or index + sequenceLength - 1 > limit then
			break
		end
		if not isValidUtf8Sequence(text, index, sequenceLength) then
			break
		end
		lastValid = index + sequenceLength - 1
		index = lastValid + 1
	end
	return strsub(text, 1, lastValid)
end

function Strings.AppendCSVRow(lines, fields, encoded, fieldCount)
	local count = fieldCount or #fields
	for i = 1, count do
		encoded[i] = encodeCSVField(fields[i])
	end
	lines[#lines + 1] = concat(encoded, ",", 1, count)
end

function Strings.NilIfEmpty(value)
	local text = Strings.TrimText(value, true)
	if text == nil or text == "" then
		return nil
	end
	return text
end

function Strings.NormalizeText(value, allowNil)
	local text = Strings.TrimText(value, allowNil)
	if allowNil and text == "" then
		return nil
	end
	return text
end

function Strings.NormalizeName(value, allowNil)
	local text = Strings.TrimText(value, allowNil)
	if text == nil then
		return nil
	end
	return upperFirst(text)
end

function Strings.NormalizeLower(value, allowNil)
	local text = Strings.TrimText(value, allowNil)
	if text == nil then
		return nil
	end
	return lower(text)
end

function Strings.FindAchievement(inp)
	local out = trimRaw(inp)
	if out ~= "" and find(out, "%{%d*%}") then
		local b, e = find(out, "%{%d*%}")
		local id = strsub(out, b + 1, e - 1)
		local link = (id and id ~= "" and GetAchievementLink(id)) or ("[" .. id .. "]")
		out = strsub(out, 1, b - 1) .. link .. strsub(out, e + 1)
	end
	return out
end

function Strings.FormatChatMessage(text, prefix, outputFormat, prefixHex)
	local msgPrefix = prefix or ""
	if prefixHex then
		local normalized = Colors.NormalizeHexColor and Colors.NormalizeHexColor(prefixHex) or "ffffffff"
		msgPrefix = Colors.WrapText(msgPrefix, normalized)
	end
	return format(outputFormat or "%s%s", msgPrefix, tostring(text))
end

function Strings.SplitArgs(msg)
	msg = Strings.TrimText(msg)
	if msg == "" then
		return "", ""
	end
	local cmd, rest = msg:match("^(%S+)%s*(.-)$")
	return Strings.NormalizeLower(cmd), Strings.TrimText(rest)
end
