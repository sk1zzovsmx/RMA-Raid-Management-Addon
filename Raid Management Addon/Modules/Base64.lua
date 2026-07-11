-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none

local addon = select(2, ...)
local gsub = string.gsub
local strsub = string.sub
local char, byte = string.char, string.byte
local floor = math.floor
local tconcat = table.concat

-- ----- Internal state ----- --
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_DECODE = {}
for i = 1, #BASE64_ALPHABET do
	BASE64_DECODE[strsub(BASE64_ALPHABET, i, i)] = i - 1
end

local Base64 = addon.Base64 or {}
addon.Base64 = Base64

-- ----- Private helpers ----- --

-- ----- Public methods ----- --

function Base64.Encode(data)
	local len = #data
	local out = {}
	local outN = 0

	for i = 1, len, 3 do
		local remaining = len - i + 1
		local b1 = byte(data, i)
		local b2 = remaining > 1 and byte(data, i + 1) or 0
		local b3 = remaining > 2 and byte(data, i + 2) or 0

		outN = outN + 1
		out[outN] = strsub(BASE64_ALPHABET, floor(b1 / 4) + 1, floor(b1 / 4) + 1)
		outN = outN + 1
		out[outN] = strsub(BASE64_ALPHABET, ((b1 % 4) * 16) + floor(b2 / 16) + 1, ((b1 % 4) * 16) + floor(b2 / 16) + 1)

		if remaining == 1 then
			outN = outN + 1
			out[outN] = "=="
		elseif remaining == 2 then
			outN = outN + 1
			out[outN] = strsub(BASE64_ALPHABET, ((b2 % 16) * 4) + 1, ((b2 % 16) * 4) + 1)
			outN = outN + 1
			out[outN] = "="
		else
			outN = outN + 1
			out[outN] =
				strsub(BASE64_ALPHABET, ((b2 % 16) * 4) + floor(b3 / 64) + 1, ((b2 % 16) * 4) + floor(b3 / 64) + 1)
			outN = outN + 1
			out[outN] = strsub(BASE64_ALPHABET, (b3 % 64) + 1, (b3 % 64) + 1)
		end
	end

	return tconcat(out)
end

function Base64.Decode(data)
	data = gsub(data, "[^" .. BASE64_ALPHABET .. "=]", "")
	local len = #data
	local out = {}
	local outN = 0

	for i = 1, len, 4 do
		local c1 = strsub(data, i, i)
		local c2 = strsub(data, i + 1, i + 1)
		local c3 = strsub(data, i + 2, i + 2)
		local c4 = strsub(data, i + 3, i + 3)
		local v1 = BASE64_DECODE[c1]
		local v2 = BASE64_DECODE[c2]

		if v1 == nil or v2 == nil then
			break
		end

		local v3 = BASE64_DECODE[c3] or 0
		local v4 = BASE64_DECODE[c4] or 0
		local n = (v1 * 262144) + (v2 * 4096) + (v3 * 64) + v4

		outN = outN + 1
		out[outN] = char(floor(n / 65536) % 256)
		if c3 ~= "" and c3 ~= "=" then
			outN = outN + 1
			out[outN] = char(floor(n / 256) % 256)
		end
		if c4 ~= "" and c4 ~= "=" then
			outN = outN + 1
			out[outN] = char(n % 256)
		end
	end

	return tconcat(out)
end
