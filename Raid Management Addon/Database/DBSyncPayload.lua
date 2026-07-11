-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Database.Syncer._Payload
-- events: none

local addon = select(2, ...)
local Diag = addon.Diag

local DB = addon.DB
local Database = addon.Database
local Options = addon.Options
local Strings = addon.Strings
local Comms = addon.Comms

local tinsert = table.insert
local tconcat = table.concat
local tsort = table.sort
local pcall, type = pcall, type
local _G = _G
local strgmatch = string.gmatch
local tonumber, tostring = tonumber, tostring

local NormalizeName = Strings.NormalizeName
local NormalizeLower = Strings.NormalizeLower
local Payload = assert(Comms.Payload, "Comms payload helpers are not initialized")

-- ----- Internal state ----- --

DB.Syncer = DB.Syncer or {}
local module = DB.Syncer
module._Payload = module._Payload or {}
local SnapshotPayload = module._Payload

local PROTOCOL_VERSION = 2
local COMPRESSED_PREFIX = "D1:"
local FIELD_SEP = "\t"
local RECORD_SEP = "\n"
local LIST_SEP = "\031"
local splitFields = Payload.SplitFields
local packFields = Payload.PackFields

local isDebugEnabled = Options.IsDebugEnabled

-- ----- Private helpers ----- --

local function parseNumber(value, fallback)
	local n = tonumber(value)
	if n == nil then
		return fallback
	end
	return n
end

local function getLibDeflate()
	local libstub = _G.LibStub
	if type(libstub) == "table" and type(libstub.GetLibrary) == "function" then
		local ok, lib = pcall(libstub.GetLibrary, libstub, "LibDeflate", true)
		if ok and type(lib) == "table" then
			return lib
		end
	elseif type(libstub) == "function" then
		local ok, lib = pcall(libstub, "LibDeflate", true)
		if ok and type(lib) == "table" then
			return lib
		end
	end
	return nil
end

local function encodeText(value)
	if value == nil or value == "" then
		return ""
	end
	local input = tostring(value or "")
	local out = Payload.EncodeText(input)
	if out == "" and input ~= "" and isDebugEnabled() then
		addon:debug(Diag.D.LogSyncBase64EncodeFailed)
	end
	return out
end

local function decodeText(value)
	local input = tostring(value or "")
	if input == "" then
		return ""
	end
	local out = Payload.DecodeText(input)
	if out == nil and isDebugEnabled() then
		addon:debug(Diag.D.LogSyncBase64DecodeFailed)
	end
	return out
end

local function buildPlayerNameMaps(players)
	local byNid = {}
	local byNameLower = {}
	local validNids = {}
	if type(players) ~= "table" then
		return byNid, byNameLower, validNids
	end

	for i = 1, #players do
		local player = players[i]
		if type(player) == "table" then
			local playerNid = tonumber(player.playerNid)
			local playerName = player.name
			if playerNid and playerNid > 0 then
				validNids[playerNid] = true
				if type(playerName) == "string" and playerName ~= "" then
					byNid[playerNid] = playerName
					local normalized = NormalizeLower(playerName, true)
					if normalized and normalized ~= "" and byNameLower[normalized] == nil then
						byNameLower[normalized] = playerNid
					end
				end
			end
		end
	end

	return byNid, byNameLower, validNids
end

local function joinBossAttendeeRefList(players, validPlayerNids)
	if type(players) ~= "table" or #players == 0 then
		return ""
	end
	local out = {}
	local seen = {}
	for i = 1, #players do
		local raw = players[i]
		local playerNid = tonumber(raw)
		if playerNid and playerNid > 0 then
			if (not validPlayerNids) or validPlayerNids[playerNid] then
				local key = tostring(playerNid)
				if not seen[key] then
					seen[key] = true
					out[#out + 1] = key
				end
			end
		elseif type(raw) == "string" then
			local playerName = NormalizeName(raw, true) or raw
			if playerName and playerName ~= "" and not seen[playerName] then
				seen[playerName] = true
				out[#out + 1] = tostring(playerName)
			end
		end
	end
	return tconcat(out, LIST_SEP)
end

local function splitNameList(raw, out)
	local names = out or {}
	if not raw or raw == "" then
		for i = 1, #names do
			names[i] = nil
		end
		return names, 0
	end
	return splitFields(raw, LIST_SEP, names)
end

local function resolveLootLooterNameFromMap(loot, playerNameByNid)
	local queries = Database.GetRaidQueries()
	return queries:ResolveLootLooterNameFromMap(loot, playerNameByNid)
end

local function resolveLootLooterRef(loot, playerNameByNid, playerNidByName, validPlayerNids)
	local looterNid = tonumber(loot and loot.looterNid)
	if looterNid and looterNid > 0 and ((not validPlayerNids) or validPlayerNids[looterNid]) then
		return tostring(looterNid)
	end
	local resolvedLooterName = resolveLootLooterNameFromMap(loot, playerNameByNid)
	if type(resolvedLooterName) == "string" and resolvedLooterName ~= "" then
		local normalizedLooterName = NormalizeLower(resolvedLooterName, true)
		if normalizedLooterName and normalizedLooterName ~= "" and playerNidByName then
			local mappedLooterNid = tonumber(playerNidByName[normalizedLooterName])
			if mappedLooterNid and mappedLooterNid > 0 then
				local isValidMappedLooter = (not validPlayerNids) or validPlayerNids[mappedLooterNid]
				if isValidMappedLooter then
					return tostring(mappedLooterNid)
				end
			end
		end
	end
	return resolvedLooterName
end

local function sortedByNid(list, nidKey, tieKey)
	local out = {}
	if type(list) ~= "table" then
		return out
	end

	for i = 1, #list do
		local v = list[i]
		if v then
			tinsert(out, v)
		end
	end

	tsort(out, function(a, b)
		local aNid = tonumber(a and a[nidKey]) or 0
		local bNid = tonumber(b and b[nidKey]) or 0
		if aNid ~= bNid then
			return aNid < bNid
		end
		local aTie = tostring((a and a[tieKey]) or "")
		local bTie = tostring((b and b[tieKey]) or "")
		return aTie < bTie
	end)

	return out
end

-- ----- Public methods ----- --

function SnapshotPayload.EncodeText(value)
	return encodeText(value)
end

function SnapshotPayload.DecodeText(value)
	return decodeText(value)
end

function SnapshotPayload.EncodeTransportText(value, opts)
	local input = tostring(value or "")
	if opts and opts.compress == true then
		local lib = getLibDeflate()
		if lib and type(lib.CompressDeflate) == "function" and type(lib.EncodeForWoWAddonChannel) == "function" then
			local okCompress, compressed = pcall(lib.CompressDeflate, lib, input)
			if okCompress and compressed then
				local okEncode, encoded = pcall(lib.EncodeForWoWAddonChannel, lib, compressed)
				if okEncode and encoded and encoded ~= "" then
					return COMPRESSED_PREFIX .. encoded, "deflate"
				end
			end
		end
	end
	return encodeText(input), "base64"
end

function SnapshotPayload.DecodeTransportText(value)
	local input = tostring(value or "")
	if input:sub(1, #COMPRESSED_PREFIX) == COMPRESSED_PREFIX then
		local lib = getLibDeflate()
		if
			not (lib and type(lib.DecodeForWoWAddonChannel) == "function" and type(lib.DecompressDeflate) == "function")
		then
			return nil
		end
		local body = input:sub(#COMPRESSED_PREFIX + 1)
		local okDecode, compressed = pcall(lib.DecodeForWoWAddonChannel, lib, body)
		if not (okDecode and compressed) then
			return nil
		end
		local okInflate, inflated = pcall(lib.DecompressDeflate, lib, compressed)
		if okInflate and inflated then
			return inflated
		end
		return nil
	end
	return decodeText(input)
end

function SnapshotPayload.BuildPlayerNameMaps(players)
	return buildPlayerNameMaps(players)
end

function SnapshotPayload.Build(raid)
	if type(raid) ~= "table" then
		return nil
	end

	Database.EnsureRaidSchema(raid)

	local lines = {}
	local schemaVersion = tonumber(raid.schemaVersion) or tonumber(Database.GetRaidSchemaVersion()) or 1
	local raidStore = Database.GetRaidStore()
	local revision = raidStore:GetRaidSyncRevision(raid)

	lines[#lines + 1] = packFields(
		FIELD_SEP,
		"H",
		PROTOCOL_VERSION,
		schemaVersion,
		tonumber(raid.raidNid) or 0,
		encodeText(raid.zone),
		tonumber(raid.size) or 0,
		tonumber(raid.difficulty) or 0,
		encodeText(raid.realm),
		tonumber(raid.startTime) or 0,
		tonumber(raid.endTime) or 0,
		tonumber(raid.nextPlayerNid) or 1,
		tonumber(raid.nextBossNid) or 1,
		tonumber(raid.nextLootNid) or 1,
		revision
	)

	local players = sortedByNid(raid.players, "playerNid", "name")
	local playerNameByNid, playerNidByName, validPlayerNids = buildPlayerNameMaps(players)
	for i = 1, #players do
		local p = players[i]
		lines[#lines + 1] = packFields(
			FIELD_SEP,
			"P",
			tonumber(p.playerNid) or 0,
			encodeText(p.name),
			tonumber(p.rank) or 0,
			tonumber(p.subgroup) or 1,
			encodeText(p.class),
			tonumber(p.join) or 0,
			tonumber(p.leave) or 0,
			tonumber(p.countMS) or 0
		)
	end

	local attendance = sortedByNid(raid.attendance, "playerNid", "playerNid")
	for i = 1, #attendance do
		local entry = attendance[i]
		local playerNid = type(entry) == "table" and (tonumber(entry.playerNid) or 0) or 0
		local segments = type(entry) == "table" and entry.segments or nil
		if playerNid > 0 and type(segments) == "table" then
			for j = 1, #segments do
				local segment = segments[j]
				if type(segment) == "table" then
					lines[#lines + 1] = packFields(
						FIELD_SEP,
						"A",
						playerNid,
						tonumber(segment.startTime) or 0,
						tonumber(segment.endTime) or 0,
						tonumber(segment.subgroup) or 1,
						segment.online == false and 0 or 1
					)
				end
			end
		end
	end

	local bosses = sortedByNid(raid.bossKills, "bossNid", "name")
	for i = 1, #bosses do
		local b = bosses[i]
		lines[#lines + 1] = packFields(
			FIELD_SEP,
			"B",
			tonumber(b.bossNid) or 0,
			encodeText(b.name),
			encodeText(b.mode),
			tonumber(b.difficulty) or 0,
			tonumber(b.time) or 0,
			encodeText(b.hash),
			encodeText(joinBossAttendeeRefList(b.players, validPlayerNids))
		)
	end

	local lootRows = sortedByNid(raid.loot, "lootNid", "itemName")
	for i = 1, #lootRows do
		local loot = lootRows[i]
		lines[#lines + 1] = packFields(
			FIELD_SEP,
			"L",
			tonumber(loot.lootNid) or 0,
			tonumber(loot.itemId) or 0,
			encodeText(loot.itemName),
			encodeText(loot.itemString),
			encodeText(loot.itemLink),
			tonumber(loot.itemRarity) or 0,
			encodeText(loot.itemTexture),
			tonumber(loot.itemCount) or 1,
			encodeText(resolveLootLooterRef(loot, playerNameByNid, playerNidByName, validPlayerNids)),
			tonumber(loot.rollType) or 0,
			tonumber(loot.rollValue) or 0,
			tonumber(loot.bossNid) or 0,
			tonumber(loot.time) or 0
		)
	end

	return tconcat(lines, RECORD_SEP)
end

function SnapshotPayload.BuildDelta(raid, sinceRevision)
	if type(raid) ~= "table" then
		return nil, 0
	end

	local raidStore = Database.GetRaidStore()
	local fromRevision = tonumber(sinceRevision) or 0
	if fromRevision < 0 then
		fromRevision = 0
	end
	if raidStore:RequiresFullSyncSince(raid, fromRevision) then
		return nil, 0
	end

	local revision = raidStore:GetRaidSyncRevision(raid)
	if revision <= 0 or fromRevision > revision then
		return nil, 0
	end
	local lines = {
		packFields(FIELD_SEP, "D", PROTOCOL_VERSION, tonumber(raid.raidNid) or 0, fromRevision, revision),
	}
	local deltaRows = 0

	local lootRows = sortedByNid(raid.loot, "lootNid", "itemName")
	local playerNameByNid, playerNidByName, validPlayerNids = buildPlayerNameMaps(raid.players)
	for i = 1, #lootRows do
		local row = lootRows[i]
		local rowRevision = raidStore:GetLootSyncRevision(raid, row) or 0
		if rowRevision > fromRevision then
			deltaRows = deltaRows + 1
			lines[#lines + 1] = packFields(
				FIELD_SEP,
				"LD",
				rowRevision,
				tonumber(row.lootNid) or 0,
				tonumber(row.itemId) or 0,
				encodeText(row.itemName),
				encodeText(row.itemString),
				encodeText(row.itemLink),
				tonumber(row.itemRarity) or 0,
				encodeText(row.itemTexture),
				tonumber(row.itemCount) or 1,
				encodeText(resolveLootLooterRef(row, playerNameByNid, playerNidByName, validPlayerNids)),
				tonumber(row.rollType) or 0,
				tonumber(row.rollValue) or 0,
				tonumber(row.bossNid) or 0,
				tonumber(row.time) or 0
			)
		end
	end

	return tconcat(lines, RECORD_SEP), deltaRows
end

function SnapshotPayload.Parse(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end

	local currentSchemaVersion = Database.GetRaidSchemaVersion() or 1
	currentSchemaVersion = tonumber(currentSchemaVersion) or 1
	if currentSchemaVersion < 1 then
		currentSchemaVersion = 1
	end

	local snapshot = {
		header = nil,
		players = {},
		bosses = {},
		loot = {},
		attendance = {},
	}

	local fields = {}
	local listFields = {}
	local lineCount = 0

	for line in strgmatch(payload, "[^\n]+") do
		lineCount = lineCount + 1
		local f, n = splitFields(line, FIELD_SEP, fields)
		local kind = f[1]

		if kind == "H" then
			if lineCount ~= 1 or snapshot.header or n < 13 then
				return nil
			end
			local zone = decodeText(f[5])
			local realm = decodeText(f[8])
			if zone == nil or realm == nil then
				return nil
			end
			local protocolVersion = parseNumber(f[2], 0)
			local schemaVersion = parseNumber(f[3], 1)
			local raidNid = parseNumber(f[4], nil)
			local nextPlayerNid = parseNumber(f[11], 1)
			local nextBossNid = parseNumber(f[12], 1)
			local nextLootNid = parseNumber(f[13], 1)
			if not raidNid or raidNid <= 0 or schemaVersion > currentSchemaVersion then
				return nil
			end
			if nextPlayerNid < 1 or nextBossNid < 1 or nextLootNid < 1 then
				return nil
			end
			snapshot.header = {
				protocolVersion = protocolVersion,
				schemaVersion = schemaVersion,
				raidNid = raidNid,
				zone = zone,
				size = parseNumber(f[6], 0),
				difficulty = parseNumber(f[7], 0),
				realm = realm,
				startTime = parseNumber(f[9], 0),
				endTime = parseNumber(f[10], 0),
				nextPlayerNid = nextPlayerNid,
				nextBossNid = nextBossNid,
				nextLootNid = nextLootNid,
				revision = parseNumber(f[14], 0),
			}
		elseif kind == "P" then
			if not snapshot.header or n < 9 then
				return nil
			end
			local name = decodeText(f[3])
			local className = decodeText(f[6])
			if name == nil or className == nil then
				return nil
			end
			local playerNid = parseNumber(f[2], nil)
			if not playerNid or playerNid <= 0 then
				return nil
			end
			tinsert(snapshot.players, {
				playerNid = playerNid,
				name = name,
				rank = parseNumber(f[4], 0),
				subgroup = parseNumber(f[5], 1),
				class = className,
				join = parseNumber(f[7], 0),
				leave = parseNumber(f[8], 0),
				count = parseNumber(f[9], 0),
			})
		elseif kind == "A" then
			if not snapshot.header or n < 6 then
				return nil
			end
			local playerNid = parseNumber(f[2], nil)
			if not playerNid or playerNid <= 0 then
				return nil
			end
			tinsert(snapshot.attendance, {
				playerNid = playerNid,
				startTime = parseNumber(f[3], 0),
				endTime = parseNumber(f[4], 0),
				subgroup = parseNumber(f[5], 1),
				online = parseNumber(f[6], 1) ~= 0,
			})
		elseif kind == "B" then
			if not snapshot.header or n < 8 then
				return nil
			end
			local name = decodeText(f[3])
			local mode = decodeText(f[4])
			local hash = decodeText(f[7])
			local playersRaw = decodeText(f[8])
			if name == nil or mode == nil or hash == nil or playersRaw == nil then
				return nil
			end
			local bossNid = parseNumber(f[2], nil)
			if not bossNid or bossNid <= 0 then
				return nil
			end

			local names, namesCount = splitNameList(playersRaw, listFields)
			local players = {}
			for i = 1, namesCount do
				if names[i] and names[i] ~= "" then
					players[#players + 1] = names[i]
				end
			end

			tinsert(snapshot.bosses, {
				bossNid = bossNid,
				name = name,
				mode = mode,
				difficulty = parseNumber(f[5], 0),
				time = parseNumber(f[6], 0),
				hash = hash,
				players = players,
			})
		elseif kind == "L" then
			if not snapshot.header or n < 14 then
				return nil
			end
			local itemName = decodeText(f[4])
			local itemString = decodeText(f[5])
			local itemLink = decodeText(f[6])
			local itemTexture = decodeText(f[8])
			local looterName = decodeText(f[10])
			local looterNid = tonumber(looterName)
			if itemName == nil or itemString == nil or itemLink == nil then
				return nil
			end
			if itemTexture == nil or looterName == nil then
				return nil
			end
			local lootNid = parseNumber(f[2], nil)
			if not lootNid or lootNid <= 0 then
				return nil
			end
			tinsert(snapshot.loot, {
				lootNid = lootNid,
				itemId = parseNumber(f[3], 0),
				itemName = itemName,
				itemString = itemString,
				itemLink = itemLink,
				itemRarity = parseNumber(f[7], 0),
				itemTexture = itemTexture,
				itemCount = parseNumber(f[9], 1),
				looterName = looterName,
				looterNid = looterNid,
				rollType = parseNumber(f[11], 0),
				rollValue = parseNumber(f[12], 0),
				bossNid = parseNumber(f[13], 0),
				time = parseNumber(f[14], 0),
			})
		elseif kind == "C" then
			if not snapshot.header or n < 3 then
				return nil
			end
			local name = decodeText(f[2])
			local spec = decodeText(f[3])
			if name == nil or spec == nil then
				return nil
			end
			-- Legacy MS Changes records are accepted for backward-compatible
			-- snapshot parsing, but the retired feature is no longer merged.
		else
			return nil
		end
	end

	if lineCount == 0 or not snapshot.header or not tonumber(snapshot.header.raidNid) then
		return nil
	end

	return snapshot
end

function SnapshotPayload.ParseDelta(payload)
	if type(payload) ~= "string" or payload == "" then
		return nil
	end

	local delta = {
		header = nil,
		loot = {},
	}
	local fields = {}
	local lineCount = 0

	for line in strgmatch(payload, "[^\n]+") do
		lineCount = lineCount + 1
		local f, n = splitFields(line, FIELD_SEP, fields)
		local kind = f[1]
		if kind == "D" then
			if lineCount ~= 1 or delta.header or n < 5 then
				return nil
			end
			local raidNid = parseNumber(f[3], nil)
			if not raidNid or raidNid <= 0 then
				return nil
			end
			delta.header = {
				protocolVersion = parseNumber(f[2], 0),
				raidNid = raidNid,
				sinceRevision = parseNumber(f[4], 0),
				revision = parseNumber(f[5], 0),
			}
		elseif kind == "LD" then
			if not delta.header or n < 15 then
				return nil
			end
			local itemName = decodeText(f[5])
			local itemString = decodeText(f[6])
			local itemLink = decodeText(f[7])
			local itemTexture = decodeText(f[9])
			local looterName = decodeText(f[11])
			if itemName == nil or itemString == nil or itemLink == nil or itemTexture == nil or looterName == nil then
				return nil
			end
			local lootNid = parseNumber(f[3], nil)
			if not lootNid or lootNid <= 0 then
				return nil
			end
			local looterNid = tonumber(looterName)
			tinsert(delta.loot, {
				syncRevision = parseNumber(f[2], 0),
				lootNid = lootNid,
				itemId = parseNumber(f[4], 0),
				itemName = itemName,
				itemString = itemString,
				itemLink = itemLink,
				itemRarity = parseNumber(f[8], 0),
				itemTexture = itemTexture,
				itemCount = parseNumber(f[10], 1),
				looterName = looterName,
				looterNid = looterNid,
				rollType = parseNumber(f[12], 0),
				rollValue = parseNumber(f[13], 0),
				bossNid = parseNumber(f[14], 0),
				time = parseNumber(f[15], 0),
			})
		else
			return nil
		end
	end

	if lineCount == 0 or not delta.header then
		return nil
	end
	return delta
end
