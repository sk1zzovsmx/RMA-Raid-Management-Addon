-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Reserves._Import
-- events: no bus events; import parsing helpers only
-- notes: reserves import parsing helpers

local addon = select(2, ...)
local L = addon.L
local Diag = addon.Diag
local Options = addon.Options
local Strings = addon.Strings
local Base64 = addon.Base64
local Json = addon.Json
local Services = addon.Services
local pcall = pcall
local tostring = tostring
local tonumber = tonumber
local type = type
local byte = string.byte
local floor = math.floor
local huge = math.huge

-- Import limits are sized for a full 40-player raid plus administrative exports.
-- Compressed input is intentionally unsupported because LibDeflate has no bounded-output inflate API.
local MAX_ENCODED_BYTES = 262144
local MAX_DECODED_BYTES = 131072
local MAX_ROWS = 5000
local MAX_PLAYERS = 1000
local MAX_RESERVES_PER_PLAYER = 20
local MAX_PLAYER_NAME_BYTES = 64
local MAX_SHORT_FIELD_BYTES = 64
local MAX_NOTE_BYTES = 256
local MAX_QUANTITY = 100
local MAX_CSV_FIELDS = 32
local MAX_INTEGER = 2147483647

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Reserves")
local Reserves = Services.Reserves
local module = Reserves
module._Import = module._Import or {}

local Import = module._Import

-- ----- Private helpers ----- --
local isDebugEnabled = Options.IsDebugEnabled

local normalizeLower = Strings.NormalizeLower

local function cleanCSVField(field)
	if not field then
		return nil
	end
	return Strings.NormalizeText(field:gsub('^"(.-)"$', "%1"), true)
end

local function splitCSVLine(line)
	local out, fieldParts, fieldLength = {}, {}, 0
	local inQuotes = false
	local i = 1
	local function appendPart(part)
		fieldLength = fieldLength + #part
		if fieldLength > MAX_NOTE_BYTES then return false end
		fieldParts[#fieldParts + 1] = part
		return true
	end
	local function finishField()
		if #out >= MAX_CSV_FIELDS then return false end
		out[#out + 1] = table.concat(fieldParts)
		fieldParts, fieldLength = {}, 0
		return true
	end
	while i <= #line do
		local ch = line:sub(i, i)
		if ch == '"' then
			local nextCh = line:sub(i + 1, i + 1)
			if inQuotes and nextCh == '"' then
				if not appendPart('"') then return nil, "FIELD_LIMIT" end
				i = i + 1
			else
				inQuotes = not inQuotes
			end
		elseif ch == "," and not inQuotes then
			if not finishField() then return nil, "CSV_FIELDS_LIMIT" end
		else
			if not appendPart(ch) then return nil, "FIELD_LIMIT" end
		end
		i = i + 1
	end
	if inQuotes then return nil, "CSV_INVALID" end
	if not finishField() then return nil, "CSV_FIELDS_LIMIT" end
	return out
end

local function buildHeaderMap(fields)
	local map = {}
	for i = 1, #fields do
		local key = cleanCSVField(fields[i])
		if key and key ~= "" then
			map[normalizeLower(key)] = i
		end
	end
	if map["itemid"] and map["name"] then
		return map, true
	end
	return map, false
end

local function getField(fields, headerMap, key, fallbackIndex)
	if headerMap and headerMap[key] then
		return fields[headerMap[key]]
	end
	return fields[fallbackIndex]
end

local function normalizeOptionalCSVField(value)
	if value == nil or value == "" then
		return nil
	end
	return value
end

local function isAsciiText(value, maxBytes, allowEmpty)
	if type(value) ~= "string" or #value > maxBytes or (not allowEmpty and value == "") then
		return false
	end
	return value:find("[^\32-\126]") == nil
end

local function isPositiveInteger(value)
	return type(value) == "number" and value > 0 and value < huge and value == floor(value)
end

local function isBoundedNumber(value, minimum, maximum)
	return type(value) == "number" and value >= minimum and value <= maximum and value < huge and value == floor(value)
end

local function denseArrayLength(value)
	if type(value) ~= "table" then return false end
	local count, highest = 0, 0
	for key in pairs(value) do
		if not isPositiveInteger(key) then return nil end
		count = count + 1
		if key > highest then highest = key end
	end
	if count ~= highest then return nil end
	return count
end

local function validateRow(row)
	if type(row) ~= "table" or not isPositiveInteger(row.itemId) then return false, "ITEM_ID_INVALID" end
	if not isAsciiText(row.player, MAX_PLAYER_NAME_BYTES, false)
		or not isAsciiText(row.playerKey, MAX_PLAYER_NAME_BYTES, false)
		or (row.source == nil or isAsciiText(row.source, MAX_SHORT_FIELD_BYTES, true)) == false
		or (row.class == nil or isAsciiText(row.class, MAX_SHORT_FIELD_BYTES, true)) == false
		or (row.spec == nil or isAsciiText(row.spec, MAX_SHORT_FIELD_BYTES, true)) == false
		or (row.note == nil or isAsciiText(row.note, MAX_NOTE_BYTES, true)) == false then
		return false, "FIELD_LIMIT"
	end
	if not isBoundedNumber(row.plus, 0, MAX_QUANTITY) then return false, "QUANTITY_LIMIT" end
	return true
end

local function validateRows(rows)
	local players, playerCount = {}, 0
	for i = 1, #rows do
		local row = rows[i]
		local ok, reason = validateRow(row)
		if not ok then return false, reason end
		local player = players[row.playerKey]
		if not player then
			playerCount = playerCount + 1
			if playerCount > MAX_PLAYERS then return false, "PLAYERS_LIMIT" end
			player = { itemCount = 0, quantities = {} }
			players[row.playerKey] = player
		end
		local quantity = player.quantities[row.itemId]
		if quantity then
			quantity = quantity + 1
			if quantity > MAX_QUANTITY then return false, "QUANTITY_LIMIT" end
			player.quantities[row.itemId] = quantity
		else
			player.itemCount = player.itemCount + 1
			if player.itemCount > MAX_RESERVES_PER_PLAYER then return false, "RESERVES_PER_PLAYER_LIMIT" end
			player.quantities[row.itemId] = 1
		end
	end
	return true
end

local function buildParsedCSVRow(fields, headerMap)
	local itemIdStr = cleanCSVField(getField(fields, headerMap, "itemid", 2))
	local source = cleanCSVField(getField(fields, headerMap, "from", 3))
	local playerName = cleanCSVField(getField(fields, headerMap, "name", 4))
	local className = cleanCSVField(getField(fields, headerMap, "class", 5))
	local spec = cleanCSVField(getField(fields, headerMap, "spec", 6))
	local note = cleanCSVField(getField(fields, headerMap, "note", 7))
	local plus = cleanCSVField(getField(fields, headerMap, "plus", 8))

	local itemId = tonumber(itemIdStr)
	local playerKey = normalizeLower(playerName)
	if not itemId or not playerKey then
		return nil
	end

	return {
		itemId = itemId,
		player = playerName,
		playerKey = playerKey,
		source = normalizeOptionalCSVField(source),
		class = normalizeOptionalCSVField(className),
		spec = normalizeOptionalCSVField(spec),
		note = normalizeOptionalCSVField(note),
		plus = tonumber(plus) or 0,
	}
end

local function appendParsedCSVRow(rows, fields, headerMap, line, logSkipped)
	local row = buildParsedCSVRow(fields, headerMap)
	if row then
		rows[#rows + 1] = row
		return true
	end
	if logSkipped and isDebugEnabled() then
		addon:debug(Diag.D.LogSRParseSkippedLine:format(tostring(line)))
	end
	return false
end

local function parseCSVRows(csv)
	local rows = {}
	local headerMap = nil
	local firstLine = true
	local stats = {
		headerDetected = false,
		totalLines = 0,
		dataLines = 0,
		validRows = 0,
		skippedRows = 0,
	}

	for line in csv:gmatch("[^\n]+") do
		stats.totalLines = stats.totalLines + 1
		line = line:gsub("\r$", "")
		if firstLine then
			firstLine = false
			local maybeHeader, splitReason = splitCSVLine(line)
			if not maybeHeader then return nil, stats, splitReason end
			local map, isHeader = buildHeaderMap(maybeHeader)
			if isHeader then
				stats.headerDetected = true
				headerMap = map
			else
				if #rows >= MAX_ROWS then return nil, stats, "ROWS_LIMIT" end
				stats.dataLines = stats.dataLines + 1
				if appendParsedCSVRow(rows, maybeHeader, headerMap, line, false) then
					stats.validRows = stats.validRows + 1
				else
					stats.skippedRows = stats.skippedRows + 1
				end
			end
		else
			stats.dataLines = stats.dataLines + 1
			if #rows >= MAX_ROWS then return nil, stats, "ROWS_LIMIT" end
			local fields, splitReason = splitCSVLine(line)
			if not fields then return nil, stats, splitReason end
			if appendParsedCSVRow(rows, fields, headerMap, line, true) then
				stats.validRows = stats.validRows + 1
			else
				stats.skippedRows = stats.skippedRows + 1
			end
		end
	end

	return rows, stats
end

local function getBase64()
	Base64 = Base64 or addon.Base64
	return Base64
end

local function getJson()
	Json = Json or addon.Json
	return Json
end

local function looksLikeCSV(text)
	return type(text) == "string" and (text:find(",", 1, true) ~= nil or text:find("\n", 1, true) ~= nil)
end

local function looksLikeZlibPayload(text)
	if type(text) ~= "string" or #text < 2 then
		return false
	end
	local first, second = byte(text, 1, 2)
	return first == 0x78 and second ~= nil
end

local function decodeBase64Text(text)
	if type(text) ~= "string" or #text > MAX_ENCODED_BYTES then
		return nil, "IMPORT_ENCODED_TOO_LARGE"
	end
	local codec = getBase64()
	if not (codec and type(codec.Decode) == "function") then
		return nil, "BASE64_UNAVAILABLE"
	end
	local ok, decoded = pcall(codec.Decode, tostring(text or ""))
	if ok and type(decoded) == "string" and decoded ~= "" then
		if #decoded > MAX_DECODED_BYTES then return nil, "IMPORT_DECODED_TOO_LARGE" end
		return decoded
	end
	return nil, "BASE64_FAILED"
end

local function parseJsonText(text)
	local decoder = getJson()
	if not (decoder and type(decoder.Decode) == "function") then
		return nil, "JSON_UNAVAILABLE"
	end
	local data, reason = decoder.Decode(text)
	if type(data) == "table" then
		return data
	end
	return nil, reason or "JSON_INVALID"
end

local function getSoftResArray(data)
	if type(data) ~= "table" then
		return nil
	end
	return data.softreserves or data.softReserves or data.reserves or data.players
end

local function getJsonPlayerName(entry)
	if type(entry) ~= "table" then
		return nil
	end
	return entry.name or entry.player or entry.character or entry.characterName or entry.playerName
end

local function getJsonItems(entry)
	if type(entry) ~= "table" then
		return nil
	end
	local items = entry.items or entry.reserves or entry.softreserves or entry.softReserves
	if type(items) == "table" then
		return items
	end
	if entry.id or entry.itemId or entry.itemID or entry.item_id then
		return { entry }
	end
	return nil
end

local function getJsonItemId(item)
	if type(item) ~= "table" then
		return nil
	end
	return item.id or item.itemId or item.itemID or item.item_id
end

local function getJsonPlus(item, entry)
	if type(item) == "table" then
		local value = item.sr_plus or item.srPlus or item.plus
		if value ~= nil then
			return value
		end
	end
	if type(entry) == "table" then
		return entry.sr_plus or entry.srPlus or entry.plus or entry.plusOnes or 0
	end
	return 0
end

local function appendSoftResJsonRows(rows, data)
	local softreserves = getSoftResArray(data)
	local softreserveCount = denseArrayLength(softreserves)
	if not softreserveCount then
		return false, "JSON_INVALID_SCHEMA"
	end
	if softreserveCount > MAX_PLAYERS then return false, "PLAYERS_LIMIT" end

	local playerKeys = {}
	local playerCount = 0
	for i = 1, #softreserves do
		local entry = softreserves[i]
		if type(entry) ~= "table" then return false, "JSON_INVALID_SCHEMA" end
		local playerName = getJsonPlayerName(entry)
		local playerKey = normalizeLower(playerName)
		local items = getJsonItems(entry)
		local itemCount = denseArrayLength(items)
		if not itemCount then return false, "JSON_INVALID_SCHEMA" end
		if not isAsciiText(playerName, MAX_PLAYER_NAME_BYTES, false)
			or not isAsciiText(playerKey, MAX_PLAYER_NAME_BYTES, false)
			or (entry.class ~= nil and not isAsciiText(entry.class, MAX_SHORT_FIELD_BYTES, true))
			or (entry.role ~= nil and not isAsciiText(entry.role, MAX_SHORT_FIELD_BYTES, true))
			or (entry.spec ~= nil and not isAsciiText(entry.spec, MAX_SHORT_FIELD_BYTES, true))
			or (entry.note ~= nil and not isAsciiText(entry.note, MAX_NOTE_BYTES, true)) then
			return false, "FIELD_LIMIT"
		end
		if itemCount > MAX_RESERVES_PER_PLAYER then return false, "RESERVES_PER_PLAYER_LIMIT" end
		if playerKey then
			if playerKeys[playerKey] then return false, "JSON_DUPLICATE_PLAYER" end
			playerKeys[playerKey] = true
			playerCount = playerCount + 1
			local itemKeys = {}

			for j = 1, #items do
				local item = items[j]
				local itemId = getJsonItemId(item)
				local plus = getJsonPlus(item, entry)
				if type(item) ~= "table" or not isPositiveInteger(itemId) then return false, "ITEM_ID_INVALID" end
				if not isBoundedNumber(plus, 0, MAX_QUANTITY) then return false, "QUANTITY_LIMIT" end
				if item.note ~= nil and not isAsciiText(item.note, MAX_NOTE_BYTES, true) then return false, "FIELD_LIMIT" end
				if itemKeys[itemId] then return false, "JSON_DUPLICATE_ITEM" end
				itemKeys[itemId] = true
				if itemId then
					if #rows >= MAX_ROWS then return false, "ROWS_LIMIT" end
					rows[#rows + 1] = {
						itemId = itemId,
						player = playerName,
						playerKey = playerKey,
						source = nil,
						class = entry.class,
						spec = entry.role or entry.spec,
						note = item.note or entry.note,
						plus = plus,
					}
				end
			end
		end
	end

	if #rows <= 0 then
		return false, "JSON_NO_ROWS"
	end
	return true, nil, playerCount
end

local function parseDecodedJsonPayload(decoded)
	if #decoded > MAX_DECODED_BYTES then return nil, "IMPORT_DECODED_TOO_LARGE" end
	if looksLikeZlibPayload(decoded) then return nil, "COMPRESSED_UNSUPPORTED", "COMPRESSED_UNSUPPORTED" end
	local data, reason = parseJsonText(decoded)
	if data then
		return data
	end

	return nil, reason or "JSON_INVALID"
end

local function parseEncodedRows(text)
	local decoded, decodeReason = decodeBase64Text(text)
	if not decoded then
		return nil, nil, nil, decodeReason
	end

	local data, jsonReason, decompressReason = parseDecodedJsonPayload(decoded)
	if not data then
		return nil, nil, nil, jsonReason or "JSON_INVALID", decompressReason, decoded
	end

	local rows = {}
	local ok, rowReason, playerCount = appendSoftResJsonRows(rows, data)
	if not ok then
		return nil, nil, nil, rowReason or "JSON_NO_ROWS", nil, decoded
	end

	local stats = {
		headerDetected = false,
		totalLines = 1,
		dataLines = 1,
		validRows = #rows,
		skippedRows = 0,
		format = "encoded-json",
		players = playerCount or 0,
	}
	return rows, stats, data, nil, nil, decoded
end

local function validatePlusRows(rows)
	local seen = {}
	for i = 1, #rows do
		local row = rows[i]
		local rec = seen[row.playerKey]
		if not rec then
			seen[row.playerKey] = { itemId = row.itemId, player = row.player, count = 1 }
		else
			rec.count = (rec.count or 1) + 1
			if rec.itemId ~= row.itemId then
				return false,
					"CSV_WRONG_FOR_PLUS",
					{
						player = row.player,
						reason = "multi_item",
						first = rec.itemId,
						second = row.itemId,
						count = rec.count,
					}
			end
			return false,
				"CSV_WRONG_FOR_PLUS",
				{
					player = row.player,
					reason = "duplicate",
					itemId = row.itemId,
					count = rec.count,
				}
		end
	end
	return true
end

local function aggregateRows(rows, allowMulti)
	local newReservesData = {}
	local byItemPerPlayer = {}

	for i = 1, #rows do
		local row = rows[i]
		local pKey = row.playerKey

		local container = newReservesData[pKey]
		if not container then
			container = {
				playerNameDisplay = row.player,
				reserves = {},
			}
			newReservesData[pKey] = container
			byItemPerPlayer[pKey] = {}
		end

		local idx = byItemPerPlayer[pKey]
		local entry = idx[row.itemId]
		if entry then
			if allowMulti then
				entry.quantity = (tonumber(entry.quantity) or 1) + 1
			else
				entry.quantity = 1
			end
			local p = tonumber(row.plus) or 0
			if p > (tonumber(entry.plus) or 0) then
				entry.plus = p
			end
		else
			entry = {
				rawID = row.itemId,
				itemLink = nil,
				itemName = nil,
				itemIcon = nil,
				quantity = 1,
				class = row.class,
				spec = row.spec,
				note = row.note,
				plus = tonumber(row.plus) or 0,
				source = row.source,
			}
			idx[row.itemId] = entry
			container.reserves[#container.reserves + 1] = entry
		end
	end

	return newReservesData
end

local function isBoundedInteger(value, minimum, maximum)
	return type(value) == "number" and value == value and value ~= huge and value == floor(value)
		and value >= minimum and value <= maximum
end

local function isBoundedCanonicalText(value, maximum)
	return value == nil or isAsciiText(value, maximum, true)
end

function Import.ValidateCanonicalData(sourceData)
	if type(sourceData) ~= "table" then return nil, "INVALID_IMPORT_DATA" end
	local snapshot, seenPlayers = {}, {}
	local playerCount, totalRows = 0, 0
	for playerKey, player in pairs(sourceData) do
		playerCount = playerCount + 1
		if playerCount > MAX_PLAYERS then return nil, "INVALID_IMPORT_DATA" end
		if not isAsciiText(playerKey, MAX_PLAYER_NAME_BYTES, false)
			or type(player) ~= "table" or type(player.reserves) ~= "table" then
			return nil, "INVALID_IMPORT_DATA"
		end
		for key in pairs(player) do
			if key ~= "playerNameDisplay" and key ~= "reserves" then return nil, "INVALID_IMPORT_DATA" end
		end
		local displayName = player.playerNameDisplay or playerKey
		if not isAsciiText(displayName, MAX_PLAYER_NAME_BYTES, false) then
			return nil, "INVALID_IMPORT_DATA"
		end
		local canonicalPlayer = normalizeLower(displayName)
		if not canonicalPlayer or canonicalPlayer == "" or seenPlayers[canonicalPlayer] then
			return nil, "INVALID_IMPORT_DATA"
		end
		seenPlayers[canonicalPlayer] = true
		local rowCount, maxIndex = 0, 0
		for key in pairs(player.reserves) do
			if type(key) ~= "number" or key < 1 or key ~= floor(key) then return nil, "INVALID_IMPORT_DATA" end
			rowCount = rowCount + 1
			if rowCount > MAX_RESERVES_PER_PLAYER then return nil, "INVALID_IMPORT_DATA" end
			if key > maxIndex then maxIndex = key end
		end
		if rowCount < 1 or rowCount ~= maxIndex then return nil, "INVALID_IMPORT_DATA" end
		totalRows = totalRows + rowCount
		if totalRows > MAX_ROWS then return nil, "INVALID_IMPORT_DATA" end
		local copiedPlayer, seenItems = { playerNameDisplay = displayName, reserves = {} }, {}
		for i = 1, rowCount do
			local row = player.reserves[i]
			if type(row) ~= "table" then return nil, "INVALID_IMPORT_DATA" end
			for key in pairs(row) do
				if key ~= "rawID" and key ~= "itemLink" and key ~= "itemName" and key ~= "itemIcon"
					and key ~= "quantity" and key ~= "class" and key ~= "spec" and key ~= "note"
					and key ~= "plus" and key ~= "source" then return nil, "INVALID_IMPORT_DATA" end
			end
			local rawID = row.rawID
			local quantity = row.quantity == nil and 1 or row.quantity
			local plus = row.plus == nil and 0 or row.plus
			if not isBoundedInteger(rawID, 1, MAX_INTEGER) or not isBoundedInteger(quantity, 1, MAX_QUANTITY)
				or not isBoundedInteger(plus, 0, MAX_QUANTITY) or seenItems[rawID]
				or not isBoundedCanonicalText(row.itemLink, MAX_NOTE_BYTES)
				or not isBoundedCanonicalText(row.itemName, MAX_SHORT_FIELD_BYTES)
				or not isBoundedCanonicalText(row.itemIcon, MAX_NOTE_BYTES)
				or not isBoundedCanonicalText(row.class, MAX_SHORT_FIELD_BYTES)
				or not isBoundedCanonicalText(row.spec, MAX_SHORT_FIELD_BYTES)
				or not isBoundedCanonicalText(row.note, MAX_NOTE_BYTES)
				or not isBoundedCanonicalText(row.source, MAX_SHORT_FIELD_BYTES) then
				return nil, "INVALID_IMPORT_DATA"
			end
			seenItems[rawID] = true
			local copied = { rawID = rawID, quantity = quantity, plus = plus }
			for _, key in ipairs({ "itemLink", "itemName", "itemIcon", "class", "spec", "note", "source" }) do
				if row[key] ~= nil then copied[key] = row[key] end
			end
			copiedPlayer.reserves[i] = copied
		end
		snapshot[playerKey] = copiedPlayer
	end
	return snapshot
end

-- ----- Public methods ----- --
function Import.BuildParser()
	local importStrategies = {
		multi = {
			id = "multi",
			Validate = function(rows)
				return true
			end,
			Aggregate = function(rows)
				return aggregateRows(rows, true)
			end,
		},
		plus = {
			id = "plus",
			Validate = validatePlusRows,
			Aggregate = function(rows)
				return aggregateRows(rows, false)
			end,
		},
	}

	local function getImportStrategy(service, mode)
		mode = (mode == "plus" or mode == "multi") and mode or service:GetImportMode()
		return importStrategies[mode] or importStrategies.multi
	end

	local function parseImport(service, text, mode, opts)
		if type(text) ~= "string" or not text:match("%S") then
			addon:warn(Diag.W.LogReservesImportFailedEmpty)
			return nil, "EMPTY"
		end
		if #text > MAX_ENCODED_BYTES then
			return nil, "IMPORT_ENCODED_TOO_LARGE"
		end

		local resolvedMode = (mode == "plus" or mode == "multi") and mode or service:GetImportMode()
		local requestedFormat = type(opts) == "table" and opts.format or nil
		requestedFormat = (requestedFormat == "json" or requestedFormat == "csv") and requestedFormat or nil
		local strategy = getImportStrategy(service, resolvedMode)

		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesParseStart)
		end

		local csvAttempted = requestedFormat == "csv" or (not requestedFormat and looksLikeCSV(text))
		local rows, importStats, csvReason
		local encodedData
		if csvAttempted then
			rows, importStats, csvReason = parseCSVRows(text)
		end
		if csvReason then return nil, csvReason end
		if requestedFormat == "csv" and (not rows or #rows == 0) then
			addon:warn(L.WarnNoValidRows)
			return nil, "NO_ROWS"
		end
		if requestedFormat ~= "csv" and (not rows or #rows == 0) then
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesEncodedImportStart)
			end

			local encodedReason, decompressionReason, decodedText
			rows, importStats, encodedData, encodedReason, decompressionReason, decodedText = parseEncodedRows(text)
			if not rows or #rows == 0 then
				if requestedFormat == "json" then
					if encodedReason == "COMPRESSED_UNSUPPORTED" then
						addon:warn(L.WarnReservesEncodedImportCompressed)
					else
						addon:warn(L.WarnReservesEncodedImportInvalid)
					end
					if isDebugEnabled() then
						addon:warn(
							Diag.W.LogReservesEncodedImportFailed:format(tostring(encodedReason or "JSON_INVALID"))
						)
					end
					return nil, encodedReason or "JSON_INVALID"
				elseif csvAttempted then
					addon:warn(L.WarnNoValidRows)
					return nil, "NO_ROWS"
				end
				if decompressionReason == "COMPRESSED_UNSUPPORTED" and looksLikeZlibPayload(decodedText) then
					addon:warn(L.WarnReservesEncodedImportCompressed)
				else
					addon:warn(L.WarnReservesEncodedImportInvalid)
				end
				if isDebugEnabled() then
					addon:warn(Diag.W.LogReservesEncodedImportFailed:format(tostring(encodedReason or "NO_ROWS")))
				end
				return nil, encodedReason or "NO_ROWS"
			end

			if isDebugEnabled() then
				local metadata = type(encodedData) == "table" and encodedData.metadata or nil
				addon:debug(
					Diag.D.LogReservesEncodedImportRows:format(
						tonumber(importStats.validRows) or #rows,
						tonumber(importStats.players) or 0,
						tostring(metadata and (metadata.origin or metadata.source) or "?")
					)
				)
			end
		end

		importStats = importStats or {}
		if #rows > MAX_ROWS then return nil, "IMPORT_TOO_MANY_ROWS" end
		local rowsValid, rowsReason = validateRows(rows)
		if not rowsValid then return nil, rowsReason end
		if isDebugEnabled() then
			addon:debug(
				Diag.D.LogReservesImportRows:format(
					tonumber(importStats.validRows) or #rows,
					tonumber(importStats.skippedRows) or 0,
					tostring(importStats.headerDetected),
					tonumber(importStats.dataLines) or 0
				)
			)
		end
		if importStats.headerDetected ~= true and (tonumber(importStats.skippedRows) or 0) > 0 then
			addon:warn(L.WarnReservesHeaderHint)
		end

		local ok, errCode, errData = strategy.Validate(rows)
		if not ok then
			if isDebugEnabled() then
				addon:debug(
					Diag.D.LogReservesImportWrongModePlus
							and Diag.D.LogReservesImportWrongModePlus:format(tostring(errData and errData.player))
						or ("Wrong CSV for Plus System: " .. tostring(errData and errData.player))
				)
			end
			return nil, errCode or "CSV_INVALID", errData
		end

		local newReservesData = strategy.Aggregate(rows)
		local result = {
			mode = resolvedMode,
			reservesData = newReservesData,
			nPlayers = addon.tLength(newReservesData),
			opts = opts,
			importStats = importStats,
		}
		if importStats.format == "encoded-json" then
			local metadata = type(encodedData) == "table" and encodedData.metadata or nil
			result.format = "encoded-json"
			result.sourceId = type(metadata) == "table" and (metadata.id or metadata.raidId or metadata.uuid) or nil
			result.sourceOrigin = type(metadata) == "table" and (metadata.origin or metadata.source) or nil
		end
		return result
	end

	return {
		ParseImport = parseImport,
	}
end
