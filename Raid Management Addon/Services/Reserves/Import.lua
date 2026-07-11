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
local _G = _G
local pcall = pcall
local tostring = tostring
local tonumber = tonumber
local type = type
local byte = string.byte

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
	local out, field = {}, ""
	local inQuotes = false
	local i = 1
	while i <= #line do
		local ch = line:sub(i, i)
		if ch == '"' then
			local nextCh = line:sub(i + 1, i + 1)
			if inQuotes and nextCh == '"' then
				field = field .. '"'
				i = i + 1
			else
				inQuotes = not inQuotes
			end
		elseif ch == "," and not inQuotes then
			out[#out + 1] = field
			field = ""
		else
			field = field .. ch
		end
		i = i + 1
	end
	out[#out + 1] = field
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
			local maybeHeader = splitCSVLine(line)
			local map, isHeader = buildHeaderMap(maybeHeader)
			if isHeader then
				stats.headerDetected = true
				headerMap = map
			else
				stats.dataLines = stats.dataLines + 1
				if appendParsedCSVRow(rows, maybeHeader, headerMap, line, false) then
					stats.validRows = stats.validRows + 1
				else
					stats.skippedRows = stats.skippedRows + 1
				end
			end
		else
			stats.dataLines = stats.dataLines + 1
			local fields = splitCSVLine(line)
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
	local codec = getBase64()
	if not (codec and type(codec.Decode) == "function") then
		return nil, "BASE64_UNAVAILABLE"
	end
	local ok, decoded = pcall(codec.Decode, tostring(text or ""))
	if ok and type(decoded) == "string" and decoded ~= "" then
		return decoded
	end
	return nil, "BASE64_FAILED"
end

local function maybeDecompressZlib(text)
	local libstub = _G and _G.LibStub
	if type(libstub) ~= "function" and type(libstub) ~= "table" then
		return nil, "DEFLATE_UNAVAILABLE"
	end

	local ok, lib
	if type(libstub) == "table" and type(libstub.GetLibrary) == "function" then
		ok, lib = pcall(libstub.GetLibrary, libstub, "LibDeflate", true)
	else
		ok, lib = pcall(libstub, "LibDeflate")
	end
	if not ok or type(lib) ~= "table" or type(lib.DecompressZlib) ~= "function" then
		return nil, "DEFLATE_UNAVAILABLE"
	end
	local okDecompress, decompressed = pcall(lib.DecompressZlib, lib, text)
	if okDecompress and type(decompressed) == "string" and decompressed ~= "" then
		return decompressed
	end
	return nil, "DEFLATE_FAILED"
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
	return tonumber(item.id or item.itemId or item.itemID or item.item_id)
end

local function getJsonPlus(item, entry)
	if type(item) == "table" then
		local value = tonumber(item.sr_plus or item.srPlus or item.plus)
		if value then
			return value
		end
	end
	if type(entry) == "table" then
		return tonumber(entry.sr_plus or entry.srPlus or entry.plus or entry.plusOnes) or 0
	end
	return 0
end

local function appendSoftResJsonRows(rows, data)
	local softreserves = getSoftResArray(data)
	if type(softreserves) ~= "table" then
		return false, "JSON_NO_SOFTRESERVES"
	end

	local playerKeys = {}
	local playerCount = 0
	for i = 1, #softreserves do
		local entry = softreserves[i]
		local playerName = getJsonPlayerName(entry)
		local playerKey = normalizeLower(playerName)
		local items = getJsonItems(entry)
		if playerKey and type(items) == "table" then
			if not playerKeys[playerKey] then
				playerKeys[playerKey] = true
				playerCount = playerCount + 1
			end

			for j = 1, #items do
				local item = items[j]
				local itemId = getJsonItemId(item)
				if itemId and itemId > 0 then
					rows[#rows + 1] = {
						itemId = itemId,
						player = playerName,
						playerKey = playerKey,
						source = nil,
						class = entry.class,
						spec = entry.role or entry.spec,
						note = item.note or entry.note,
						plus = getJsonPlus(item, entry),
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
	local data, reason = parseJsonText(decoded)
	if data then
		return data
	end

	local decompressed, decompressReason = maybeDecompressZlib(decoded)
	if not decompressed then
		return nil, reason or decompressReason, decompressReason
	end

	data, reason = parseJsonText(decompressed)
	if data then
		return data
	end
	return nil, reason or "JSON_INVALID", decompressReason
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

		local resolvedMode = (mode == "plus" or mode == "multi") and mode or service:GetImportMode()
		local requestedFormat = type(opts) == "table" and opts.format or nil
		requestedFormat = (requestedFormat == "json" or requestedFormat == "csv") and requestedFormat or nil
		local strategy = getImportStrategy(service, resolvedMode)

		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesParseStart)
		end

		local csvAttempted = requestedFormat == "csv" or (not requestedFormat and looksLikeCSV(text))
		local rows, importStats
		local encodedData
		if csvAttempted then
			rows, importStats = parseCSVRows(text)
		end
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
					addon:warn(L.WarnReservesEncodedImportInvalid)
					if isDebugEnabled() then
						addon:warn(
							Diag.W.LogReservesEncodedImportFailed:format(tostring(encodedReason or "JSON_INVALID"))
						)
					end
					return nil, "JSON_INVALID"
				elseif csvAttempted then
					addon:warn(L.WarnNoValidRows)
					return nil, "NO_ROWS"
				end
				if decompressionReason == "DEFLATE_UNAVAILABLE" and looksLikeZlibPayload(decodedText) then
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
