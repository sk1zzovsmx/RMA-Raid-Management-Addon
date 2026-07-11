-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Json
-- events: none

local addon = select(2, ...)
local char = string.char
local find = string.find
local format = string.format
local sub = string.sub
local tonumber = tonumber
local type = type

-- ----- Internal state ----- --
local Json = addon.Json or {}
addon.Json = Json
Json.NULL = Json.NULL or {}

-- ----- Private helpers ----- --
local function fail(state, reason)
	state.error = reason
	return nil, reason
end

local function peek(state)
	return sub(state.text, state.pos, state.pos)
end

local function advance(state, count)
	state.pos = state.pos + (count or 1)
end

local function skipWhitespace(state)
	local _, toPos = find(state.text, "^[ \t\r\n]*", state.pos)
	state.pos = (toPos or state.pos - 1) + 1
end

local function hexToNumber(value)
	if not value or not value:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
		return nil
	end
	return tonumber(value, 16)
end

local function codepointToUtf8(codepoint)
	if not codepoint then
		return nil
	end
	if codepoint <= 0x7F then
		return char(codepoint)
	end
	if codepoint <= 0x7FF then
		return char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
	end
	if codepoint <= 0xFFFF then
		return char(
			0xE0 + math.floor(codepoint / 0x1000),
			0x80 + (math.floor(codepoint / 0x40) % 0x40),
			0x80 + (codepoint % 0x40)
		)
	end
	if codepoint <= 0x10FFFF then
		return char(
			0xF0 + math.floor(codepoint / 0x40000),
			0x80 + (math.floor(codepoint / 0x1000) % 0x40),
			0x80 + (math.floor(codepoint / 0x40) % 0x40),
			0x80 + (codepoint % 0x40)
		)
	end
	return nil
end

local parseValue

local function isDigit(ch)
	return type(ch) == "string" and ch:match("%d") ~= nil
end

local function parseString(state)
	if peek(state) ~= '"' then
		return fail(state, "string_expected")
	end
	advance(state)

	local out = {}
	while state.pos <= state.len do
		local ch = peek(state)
		if ch == '"' then
			advance(state)
			return table.concat(out)
		end
		if ch == "\\" then
			advance(state)
			local escaped = peek(state)
			if escaped == '"' or escaped == "\\" or escaped == "/" then
				out[#out + 1] = escaped
				advance(state)
			elseif escaped == "b" then
				out[#out + 1] = "\b"
				advance(state)
			elseif escaped == "f" then
				out[#out + 1] = "\f"
				advance(state)
			elseif escaped == "n" then
				out[#out + 1] = "\n"
				advance(state)
			elseif escaped == "r" then
				out[#out + 1] = "\r"
				advance(state)
			elseif escaped == "t" then
				out[#out + 1] = "\t"
				advance(state)
			elseif escaped == "u" then
				local hex = sub(state.text, state.pos + 1, state.pos + 4)
				local codepoint = hexToNumber(hex)
				local encoded = codepointToUtf8(codepoint)
				if not encoded then
					return fail(state, "invalid_unicode_escape")
				end
				out[#out + 1] = encoded
				advance(state, 5)
			else
				return fail(state, "invalid_escape")
			end
		else
			if ch == "" or ch == "\n" or ch == "\r" then
				return fail(state, "unterminated_string")
			end
			out[#out + 1] = ch
			advance(state)
		end
	end

	return fail(state, "unterminated_string")
end

local function parseNumber(state)
	local startPos = state.pos
	local text = state.text

	if peek(state) == "-" then
		advance(state)
	end

	if not isDigit(peek(state)) then
		return fail(state, "number_expected")
	end

	if peek(state) == "0" then
		advance(state)
	else
		while isDigit(peek(state)) do
			advance(state)
		end
	end

	if peek(state) == "." then
		advance(state)
		if not isDigit(peek(state)) then
			return fail(state, "invalid_number")
		end
		while isDigit(peek(state)) do
			advance(state)
		end
	end

	local ch = peek(state)
	if ch == "e" or ch == "E" then
		advance(state)
		ch = peek(state)
		if ch == "+" or ch == "-" then
			advance(state)
		end
		if not isDigit(peek(state)) then
			return fail(state, "invalid_number")
		end
		while isDigit(peek(state)) do
			advance(state)
		end
	end

	local numberText = sub(text, startPos, state.pos - 1)
	local value = tonumber(numberText)
	if value == nil then
		return fail(state, "invalid_number")
	end
	return value
end

local function parseLiteral(state, literal, value)
	if sub(state.text, state.pos, state.pos + #literal - 1) ~= literal then
		return fail(state, "literal_expected")
	end
	advance(state, #literal)
	return value
end

local function parseArray(state)
	if peek(state) ~= "[" then
		return fail(state, "array_expected")
	end
	advance(state)
	skipWhitespace(state)

	local out = {}
	if peek(state) == "]" then
		advance(state)
		return out
	end

	while state.pos <= state.len do
		local value, reason = parseValue(state)
		if reason then
			return nil, reason
		end
		out[#out + 1] = value
		skipWhitespace(state)

		local ch = peek(state)
		if ch == "]" then
			advance(state)
			return out
		end
		if ch ~= "," then
			return fail(state, "array_separator_expected")
		end
		advance(state)
		skipWhitespace(state)
	end

	return fail(state, "unterminated_array")
end

local function parseObject(state)
	if peek(state) ~= "{" then
		return fail(state, "object_expected")
	end
	advance(state)
	skipWhitespace(state)

	local out = {}
	if peek(state) == "}" then
		advance(state)
		return out
	end

	while state.pos <= state.len do
		if peek(state) ~= '"' then
			return fail(state, "object_key_expected")
		end
		local key, keyReason = parseString(state)
		if keyReason then
			return nil, keyReason
		end
		skipWhitespace(state)
		if peek(state) ~= ":" then
			return fail(state, "object_colon_expected")
		end
		advance(state)
		skipWhitespace(state)

		local value, reason = parseValue(state)
		if reason then
			return nil, reason
		end
		out[key] = value
		skipWhitespace(state)

		local ch = peek(state)
		if ch == "}" then
			advance(state)
			return out
		end
		if ch ~= "," then
			return fail(state, "object_separator_expected")
		end
		advance(state)
		skipWhitespace(state)
	end

	return fail(state, "unterminated_object")
end

parseValue = function(state)
	skipWhitespace(state)
	local ch = peek(state)
	if ch == "{" then
		return parseObject(state)
	end
	if ch == "[" then
		return parseArray(state)
	end
	if ch == '"' then
		return parseString(state)
	end
	if ch == "-" or ch:match("%d") then
		return parseNumber(state)
	end
	if ch == "t" then
		return parseLiteral(state, "true", true)
	end
	if ch == "f" then
		return parseLiteral(state, "false", false)
	end
	if ch == "n" then
		return parseLiteral(state, "null", Json.NULL)
	end
	return fail(state, "value_expected")
end

-- ----- Public methods ----- --
function Json.Decode(text)
	if type(text) ~= "string" then
		return nil, "text_expected"
	end

	local state = {
		text = text,
		pos = 1,
		len = #text,
	}
	local value, reason = parseValue(state)
	if reason then
		return nil, reason
	end
	skipWhitespace(state)
	if state.pos <= state.len then
		return nil, format("trailing_data_at_%d", state.pos)
	end
	return value, nil
end
