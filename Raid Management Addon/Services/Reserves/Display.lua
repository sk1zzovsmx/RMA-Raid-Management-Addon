-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Reserves._Display
-- events: no bus events; display helpers only
-- notes: reserves display/grouping helpers

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Colors = feature.Colors
local Strings = feature.Strings
local Services = feature.Services

local format = string.format
local sort = table.sort
local tconcat, twipe = table.concat, table.wipe
local pairs, tostring, tonumber, type = pairs, tostring, tonumber, type

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Reserves")
local Reserves = Services.Reserves
local module = Reserves
module._Display = module._Display or {}

local Display = module._Display
local Aliases = assert(module._Aliases, "Reserves alias helpers are not initialized")
local normalizeAliasKey = assert(Aliases._NormalizeKey, "Reserves alias key normalizer is not initialized")

local RESERVE_ROW_MAX_PLAYERS_INLINE = 6
local playerTextTemp = {}

-- ----- Private helpers ----- --
local function colorizeReserveName(ctx, itemId, playerName, className)
	if not playerName then
		return playerName
	end

	local classToken = className
	if (not classToken or classToken == "") and itemId then
		local reserveEntry = ctx.getReserveEntryForItem(itemId, playerName)
		classToken = reserveEntry and reserveEntry.class
	end

	local raidService = ctx.getRaidService()
	if (not classToken or classToken == "") and raidService and raidService.GetPlayerClass then
		classToken = raidService:GetPlayerClass(playerName)
	end

	if not classToken or classToken == "" then
		return playerName
	end

	local _, colorStr = Colors.GetClassColorHex(classToken)
	if colorStr and colorStr ~= "ffffffff" then
		return "|c" .. colorStr .. playerName .. "|r"
	end
	return playerName
end

local function normalizePlayerEntry(player)
	if type(player) == "table" then
		return player.name or player.displayName or player.playerName or player.playerNameDisplay
	end
	return player
end

local function getStructuredPlayerQuantity(player)
	if type(player) == "table" then
		return tonumber(player.quantity) or 1
	end
	return 1
end

local function resolvePlayerClassInfo(ctx, itemId, playerName, className)
	local classToken = Colors.NormalizeClassToken(className)
	if not classToken and itemId and playerName then
		local reserveEntry = ctx.getReserveEntryForItem(itemId, playerName)
		if reserveEntry then
			classToken = Colors.NormalizeClassToken(reserveEntry.class)
		end
	end

	if not classToken then
		local raidService = ctx.getRaidService()
		if raidService and raidService.GetPlayerClass then
			classToken = Colors.NormalizeClassToken(raidService:GetPlayerClass(playerName))
		end
	end

	if not classToken then
		return nil, nil
	end

	local token, classColor = Colors.GetClassColorHex(classToken)
	if token == "UNKNOWN" then
		return nil, nil
	end
	return token, classColor
end

local function addReservePlayer(ctx, data, reserveEntry, countOverride, fallbackName)
	if not data.players then
		data.players = {}
	end
	if not data.playerCounts then
		data.playerCounts = {}
	end
	if not data.playerMeta then
		data.playerMeta = {}
	end

	local name
	local count
	local className
	local classColor
	local plus

	if type(reserveEntry) == "table" then
		name = reserveEntry.playerNameDisplay or fallbackName or "?"
		count = tonumber(reserveEntry.quantity) or 1
		className = reserveEntry.class
		plus = tonumber(reserveEntry.plus) or 0
		className, classColor = resolvePlayerClassInfo(ctx, reserveEntry.rawID, name, className)
	else
		name = reserveEntry or "?"
		count = tonumber(countOverride) or 1
	end
	count = count or 1

	local playerRowsByName = data._playerRowsByName
	if type(playerRowsByName) ~= "table" then
		playerRowsByName = {}
		data._playerRowsByName = playerRowsByName
	end

	local existing = playerRowsByName[name]
	if existing then
		existing.quantity = (tonumber(existing.quantity) or 1) + count
		local existingPlus = tonumber(existing.plus) or 0
		if plus > existingPlus then
			existing.plus = plus
		end
		if className and className ~= "" and (not existing.class or existing.class == "") then
			existing.class = className
			existing.classColor = classColor
		end
		data.playerCounts[name] = (tonumber(data.playerCounts[name]) or 0) + count
	else
		existing = {
			name = name,
			displayName = (type(reserveEntry) == "table" and reserveEntry.playerNameDisplay) or name,
			class = className,
			classColor = classColor,
			quantity = count,
			plus = plus,
			checked = true,
		}
		playerRowsByName[name] = existing
		data.players[#data.players + 1] = existing
		data.playerCounts[name] = count
	end

	local meta = data.playerMeta[name]
	if not meta then
		meta = { plus = 0, class = nil }
		data.playerMeta[name] = meta
	end
	if className and className ~= "" and (not meta.class or meta.class == "") then
		meta.class = className
	end
	if plus and plus > (meta.plus or 0) then
		meta.plus = plus
	end
end

local function getMetaForPlayer(ctx, metaByName, itemId, playerName)
	playerName = normalizePlayerEntry(playerName)
	local meta = metaByName and metaByName[playerName]
	if meta and (meta.class or meta.plus) then
		return meta
	end

	if not meta then
		meta = { plus = 0, class = nil }
	end
	if itemId and playerName then
		local reserveEntry = ctx.getReserveEntryForItem(itemId, playerName)
		if reserveEntry then
			if reserveEntry.class and reserveEntry.class ~= "" and (not meta.class or meta.class == "") then
				meta.class = reserveEntry.class
			end
			local plus = tonumber(reserveEntry.plus) or 0
			if plus > (meta.plus or 0) then
				meta.plus = plus
			end
		end

		local raidService = ctx.getRaidService()
		if (not meta.class or meta.class == "") and raidService and raidService.GetPlayerClass then
			meta.class = raidService:GetPlayerClass(playerName)
		end
	end
	return meta
end

local function formatReservePlayerName(ctx, itemId, name, count, metaByName, useColor, showPlus, showMulti)
	if type(name) == "table" then
		count = tonumber(name.quantity) or count
		name = normalizePlayerEntry(name) or name
	end

	local meta = getMetaForPlayer(ctx, metaByName, itemId, name)
	if type(meta) ~= "table" then
		meta = getMetaForPlayer(ctx, nil, itemId, name)
	end
	local out

	if useColor == false then
		out = name
	else
		out = colorizeReserveName(ctx, itemId, name, meta and meta.class)
	end

	if showMulti ~= false and ctx.isMultiReserve() and count and count > 1 then
		out = out .. format(L.StrReserveCountSuffix, count)
	end

	if showPlus ~= false and ctx.isPlusSystem() and itemId then
		local plus = (meta and tonumber(meta.plus)) or ctx.getPlusForItem(itemId, name) or 0
		if plus and plus > 0 then
			out = out .. format(" (P+%d)", plus)
		end
	end

	return out
end

local function sortPlayersForDisplay(ctx, itemId, players, counts, metaByName)
	if not players then
		return
	end

	if ctx.isPlusSystem() and itemId then
		sort(players, function(a, b)
			local aName = normalizePlayerEntry(a)
			local bName = normalizePlayerEntry(b)
			local aMeta = getMetaForPlayer(ctx, metaByName, itemId, aName)
			local bMeta = getMetaForPlayer(ctx, metaByName, itemId, bName)
			local aPlus = (aMeta and tonumber(aMeta.plus)) or 0
			local bPlus = (bMeta and tonumber(bMeta.plus)) or 0
			if aPlus ~= bPlus then
				return aPlus > bPlus
			end
			return tostring(aName) < tostring(bName)
		end)
	elseif ctx.isMultiReserve() and counts then
		sort(players, function(a, b)
			local aName = normalizePlayerEntry(a)
			local bName = normalizePlayerEntry(b)
			local aQuantity = counts[aName] or getStructuredPlayerQuantity(a)
			local bQuantity = counts[bName] or getStructuredPlayerQuantity(b)
			if aQuantity ~= bQuantity then
				return aQuantity > bQuantity
			end
			return tostring(aName) < tostring(bName)
		end)
	end
end

local function buildPlayerTokens(ctx, itemId, players, counts, metaByName, useColor, showPlus, showMulti)
	if not players then
		return {}
	end

	sortPlayersForDisplay(ctx, itemId, players, counts, metaByName)
	twipe(playerTextTemp)
	for i = 1, #players do
		local name = players[i]
		local normalizedName = normalizePlayerEntry(name)
		playerTextTemp[#playerTextTemp + 1] = formatReservePlayerName(
			ctx,
			itemId,
			name,
			counts and counts[normalizedName] or 1,
			metaByName,
			useColor,
			showPlus,
			showMulti
		)
	end
	return playerTextTemp
end

local function formatReservePlayerNameBase(ctx, itemId, name, metaByName)
	local meta = getMetaForPlayer(ctx, metaByName, itemId, name)
	return colorizeReserveName(ctx, itemId, name, meta and meta.class)
end

local function buildPlayersTooltipLines(ctx, itemId, players, counts, metaByName, shownCount, hiddenCount, out)
	local lines = out or {}
	twipe(lines)
	local total = players and #players or 0

	lines[#lines + 1] = format(L.StrReservesTooltipTotal, total)
	if hiddenCount and hiddenCount > 0 and shownCount and shownCount > 0 then
		lines[#lines + 1] = format(L.StrReservesTooltipShownHidden, shownCount, hiddenCount)
	end

	if not players or total == 0 then
		return lines
	end

	if ctx.isPlusSystem() and itemId then
		local groups = {}
		local keys = {}
		for i = 1, #players do
			local name = players[i]
			local normalizedName = normalizePlayerEntry(name)
			local meta = getMetaForPlayer(ctx, metaByName, itemId, normalizedName)
			local plus = (meta and tonumber(meta.plus)) or 0
			if type(name) == "table" and tonumber(name.plus) then
				plus = tonumber(name.plus)
			end
			if groups[plus] == nil then
				groups[plus] = {}
				keys[#keys + 1] = plus
			end
			groups[plus][#groups[plus] + 1] = formatReservePlayerNameBase(ctx, itemId, normalizedName, metaByName)
		end
		sort(keys, function(a, b)
			return a > b
		end)
		for i = 1, #keys do
			local plus = keys[i]
			lines[#lines + 1] = format(L.StrReservesTooltipPlus, plus, tconcat(groups[plus], ", "))
		end
	elseif ctx.isMultiReserve() and counts then
		local groups = {}
		local keys = {}
		for i = 1, #players do
			local name = players[i]
			local normalizedName = normalizePlayerEntry(name)
			local quantity = counts[normalizedName] or getStructuredPlayerQuantity(name)
			if groups[quantity] == nil then
				groups[quantity] = {}
				keys[#keys + 1] = quantity
			end
			groups[quantity][#groups[quantity] + 1] =
				formatReservePlayerNameBase(ctx, itemId, normalizedName, metaByName)
		end
		sort(keys, function(a, b)
			return a > b
		end)
		for i = 1, #keys do
			local quantity = keys[i]
			lines[#lines + 1] = format(L.StrReservesTooltipQuantity, quantity, tconcat(groups[quantity], ", "))
		end
	else
		local names = {}
		for i = 1, #players do
			names[i] = formatReservePlayerNameBase(ctx, itemId, players[i], metaByName)
		end
		lines[#lines + 1] = tconcat(names, ", ")
	end

	return lines
end

local function buildPlayersText(ctx, itemId, players, counts, metaByName, tooltipLinesOut)
	if not players then
		local tooltipLines = tooltipLinesOut or {}
		twipe(tooltipLines)
		return "", tooltipLines, ""
	end

	buildPlayerTokens(ctx, itemId, players, counts, metaByName)
	local total = #playerTextTemp
	local shown = total
	if RESERVE_ROW_MAX_PLAYERS_INLINE and RESERVE_ROW_MAX_PLAYERS_INLINE > 0 then
		shown = math.min(total, RESERVE_ROW_MAX_PLAYERS_INLINE)
	end

	local hidden = total - shown
	local shortText = tconcat(playerTextTemp, ", ", 1, shown)
	if hidden > 0 then
		shortText = shortText .. format(L.StrReservesPlayersHiddenSuffix, hidden)
	end

	local fullText = tconcat(playerTextTemp, ", ")
	local tooltipLines =
		buildPlayersTooltipLines(ctx, itemId, players, counts, metaByName, shown, hidden, tooltipLinesOut)
	return shortText, tooltipLines, fullText
end

local function getDisplayRowKey(_source, itemId)
	return tostring(itemId or "")
end

local function resetReserveDisplayRow(row)
	if type(row) ~= "table" then
		return
	end

	local players = row._players
	local playerRowsByName = row._playerRowsByName
	local playerCounts = row._playerCounts
	local playerMeta = row._playerMeta
	local tooltipLines = row._playersTooltipLines or row.playersTooltipLines

	if type(players) == "table" then
		twipe(players)
	end
	if type(playerRowsByName) == "table" then
		twipe(playerRowsByName)
	end
	if type(playerCounts) == "table" then
		twipe(playerCounts)
	end
	if type(playerMeta) == "table" then
		twipe(playerMeta)
	end
	if type(tooltipLines) == "table" then
		twipe(tooltipLines)
	end

	twipe(row)

	if type(players) == "table" then
		row._players = players
	end
	if type(playerRowsByName) == "table" then
		row._playerRowsByName = playerRowsByName
	end
	if type(playerCounts) == "table" then
		row._playerCounts = playerCounts
	end
	if type(playerMeta) == "table" then
		row._playerMeta = playerMeta
	end
	if type(tooltipLines) == "table" then
		row._playersTooltipLines = tooltipLines
	end
end

local function prepareReserveDisplayRow(row, itemId, reserveEntry, source)
	resetReserveDisplayRow(row)

	local players = row._players or {}
	local playerRowsByName = row._playerRowsByName or {}
	local playerCounts = row._playerCounts or {}
	local playerMeta = row._playerMeta or {}
	local tooltipLines = row._playersTooltipLines or {}

	row.itemId = itemId
	row.itemLink = reserveEntry.itemLink
	row.itemName = reserveEntry.itemName
	row.itemIcon = reserveEntry.itemIcon
	row.source = source
	row.players = players
	row._playerRowsByName = playerRowsByName
	row.playerCounts = playerCounts
	row.playerMeta = playerMeta
	row.playersTooltipLines = tooltipLines
	row._players = players
	row._playerCounts = playerCounts
	row._playerMeta = playerMeta
	row._playersTooltipLines = tooltipLines

	return row
end

local function getReserveSource(source)
	if source and source ~= "" then
		return source
	end
	return L.StrUnknown
end

local function getAliasRaidNameForReserve(ctx, reserveName)
	local state = ctx.getAliasState and ctx.getAliasState() or nil
	local reserveKey = normalizeAliasKey(reserveName)
	if not (state and state.byReserveKey and reserveKey) then
		return nil
	end
	return state.byReserveKey[reserveKey]
end

local function getPlayerIdWithAlias(ctx, raidService, playerName, raidNum)
	local playerNid = raidService:GetPlayerID(playerName, raidNum)
	if tonumber(playerNid) and playerNid > 0 then
		return playerNid
	end

	local aliasRaidName = getAliasRaidNameForReserve(ctx, playerName)
	if aliasRaidName and aliasRaidName ~= playerName then
		playerNid = raidService:GetPlayerID(aliasRaidName, raidNum)
		if tonumber(playerNid) and playerNid > 0 then
			return playerNid
		end
	end
	return 0
end

local function filterPlayersByCurrentRaid(ctx, players, raidNum)
	local raidService = ctx.getRaidService()
	if not (raidService and raidService.GetPlayerID) then
		return players, false
	end

	local targetRaidNum = raidNum
	if not targetRaidNum then
		targetRaidNum = ctx.getCurrentRaid()
	end
	if not targetRaidNum then
		return players, false
	end

	local filteredPlayers = {}
	for i = 1, #players do
		local name = normalizePlayerEntry(players[i])
		if type(name) == "string" and name ~= "" then
			local playerNid = getPlayerIdWithAlias(ctx, raidService, name, targetRaidNum)
			if tonumber(playerNid) and playerNid > 0 then
				filteredPlayers[#filteredPlayers + 1] = name
			end
		end
	end

	return filteredPlayers, true
end

local function hasCurrentRaidPlayer(ctx, list, raidNum)
	local raidService = ctx.getRaidService()
	if not (raidService and raidService.GetPlayerID) then
		return true, false
	end

	local targetRaidNum = raidNum
	if not targetRaidNum then
		targetRaidNum = ctx.getCurrentRaid()
	end
	if not targetRaidNum then
		return true, false
	end

	for i = 1, #list do
		local reserveEntry = list[i]
		local name = reserveEntry and reserveEntry.playerNameDisplay
		if type(name) == "string" and name ~= "" then
			local playerNid = getPlayerIdWithAlias(ctx, raidService, name, targetRaidNum)
			if tonumber(playerNid) and playerNid > 0 then
				return true, true
			end
		end
	end

	return false, true
end

local function copyPlayers(players)
	local out = {}
	for i = 1, #(players or {}) do
		out[i] = players[i]
	end
	return out
end

local function sortPlayerNames(players)
	sort(players, function(a, b)
		return tostring(a or "") < tostring(b or "")
	end)
	return players
end

local function buildTextForPlayers(ctx, itemId, players, counts, metaByName, showPlus, showMulti)
	local tokens = buildPlayerTokens(ctx, itemId, copyPlayers(players), counts, metaByName, false, showPlus, showMulti)
	local out = {}
	for i = 1, #tokens do
		out[i] = tokens[i]
	end
	return tconcat(out, ", ")
end

local function normalizePlayerNameList(players)
	if not players then
		return {}
	end
	local names = {}
	for i = 1, #players do
		names[i] = normalizePlayerEntry(players[i]) or ""
	end
	return names
end

local function splitPresentAndMissingPlayers(ctx, players, raidNum)
	if not players then
		return {}, {}, false
	end

	local presentPlayers, filterApplied = filterPlayersByCurrentRaid(ctx, players, raidNum)
	if not filterApplied then
		return normalizePlayerNameList(players), {}, false
	end

	local presentByName = {}
	for i = 1, #presentPlayers do
		presentByName[normalizePlayerEntry(presentPlayers[i])] = true
	end

	local missingPlayers = {}
	for i = 1, #players do
		local name = normalizePlayerEntry(players[i])
		if not presentByName[name] then
			missingPlayers[#missingPlayers + 1] = name
		end
	end

	return normalizePlayerNameList(presentPlayers), missingPlayers, true
end

local function levenshteinDistance(left, right)
	left = tostring(left or "")
	right = tostring(right or "")

	local leftLen = string.len(left)
	local rightLen = string.len(right)
	if left == right then
		return 0
	end
	if leftLen == 0 then
		return rightLen
	end
	if rightLen == 0 then
		return leftLen
	end

	local previous = {}
	local current = {}
	for j = 0, rightLen do
		previous[j] = j
	end

	for i = 1, leftLen do
		current[0] = i
		local leftByte = string.byte(left, i)
		for j = 1, rightLen do
			local cost = leftByte == string.byte(right, j) and 0 or 1
			local deletion = previous[j] + 1
			local insertion = current[j - 1] + 1
			local substitution = previous[j - 1] + cost
			current[j] = math.min(deletion, insertion, substitution)
		end
		previous, current = current, previous
	end

	return previous[rightLen] or rightLen
end

local function nameSimilarity(left, right, distance)
	local maxLen = math.max(string.len(tostring(left or "")), string.len(tostring(right or "")))
	if maxLen <= 0 then
		return 1
	end
	local score = 1 - ((tonumber(distance) or maxLen) / maxLen)
	if score < 0 then
		return 0
	end
	return score
end

local function classifyNameMatch(distance, similarity)
	if distance <= 1 and similarity >= 0.75 then
		return "strong"
	end
	if distance <= 2 and similarity >= 0.30 then
		return "weak"
	end
	return nil
end

local function buildNameMatch(reserveName, raidName, distance, similarity, strength)
	return {
		reserveName = reserveName,
		raidName = raidName,
		distance = distance,
		similarity = similarity,
		strength = strength,
	}
end

local function compareNameMatch(a, b)
	if a.reserveName ~= b.reserveName then
		return tostring(a.reserveName) < tostring(b.reserveName)
	end
	if a.distance ~= b.distance then
		return (tonumber(a.distance) or 0) < (tonumber(b.distance) or 0)
	end
	if a.similarity ~= b.similarity then
		return (tonumber(a.similarity) or 0) > (tonumber(b.similarity) or 0)
	end
	return tostring(a.raidName) < tostring(b.raidName)
end

local function formatAliasMatches(aliasMatches)
	local out = {}
	for i = 1, #(aliasMatches or {}) do
		local match = aliasMatches[i]
		if match and match.reserveName and match.raidName then
			out[#out + 1] = tostring(match.reserveName) .. " -> " .. tostring(match.raidName)
		end
	end
	return tconcat(out, ", ")
end

local function filterAliasMatchedNames(names, matchedKeys)
	local out = {}
	for i = 1, #(names or {}) do
		local name = names[i]
		local key = normalizeAliasKey(name)
		if not (key and matchedKeys[key]) then
			out[#out + 1] = name
		end
	end
	return sortPlayerNames(out)
end

local function getReservePlayerNames(ctx)
	local players = {}
	for playerKey, player in pairs(ctx.reservesData or {}) do
		if type(player) == "table" then
			local displayName = ctx.resolvePlayerNameDisplay(playerKey, player, playerKey)
			if displayName and displayName ~= "" then
				players[#players + 1] = displayName
			end
		end
	end
	return sortPlayerNames(players)
end

local function getRaidPlayerNames(ctx, raidNum)
	local raid = ctx.getRaidService()
	local targetRaidNum = raidNum or ctx.getCurrentRaid()
	local players = {}
	if not (raid and raid.GetPlayers and targetRaidNum) then
		return players, false
	end

	local raidPlayers = raid:GetPlayers(targetRaidNum) or {}
	for i = 1, #raidPlayers do
		local player = raidPlayers[i]
		local name = player and player.name
		if type(name) == "string" and name ~= "" then
			players[#players + 1] = name
		end
	end
	return sortPlayerNames(players), true
end

local function splitExactNameMatches(reservePlayers, raidPlayers)
	local reserveByKey = {}
	local raidByKey = {}
	local reserveMissing = {}
	local raidMissing = {}

	for i = 1, #reservePlayers do
		local name = reservePlayers[i]
		local key = normalizeAliasKey(name)
		if key then
			reserveByKey[key] = true
		end
	end
	for i = 1, #raidPlayers do
		local name = raidPlayers[i]
		local key = normalizeAliasKey(name)
		if key then
			raidByKey[key] = true
		end
	end

	for i = 1, #reservePlayers do
		local name = reservePlayers[i]
		local key = normalizeAliasKey(name)
		if key and not raidByKey[key] then
			reserveMissing[#reserveMissing + 1] = name
		end
	end
	for i = 1, #raidPlayers do
		local name = raidPlayers[i]
		local key = normalizeAliasKey(name)
		if key and not reserveByKey[key] then
			raidMissing[#raidMissing + 1] = name
		end
	end

	return sortPlayerNames(reserveMissing), sortPlayerNames(raidMissing)
end

local function findBestNameCandidate(reserveName, raidPlayers, usedRaidNames)
	local reserveKey = normalizeAliasKey(reserveName)
	local best

	if not reserveKey then
		return nil
	end

	for i = 1, #raidPlayers do
		local raidName = raidPlayers[i]
		local raidKey = normalizeAliasKey(raidName)
		if raidKey and not usedRaidNames[raidName] then
			local distance = levenshteinDistance(reserveKey, raidKey)
			local similarity = nameSimilarity(reserveKey, raidKey, distance)
			local strength = classifyNameMatch(distance, similarity)
			if strength then
				local candidate = buildNameMatch(reserveName, raidName, distance, similarity, strength)
				if not best or compareNameMatch(candidate, best) then
					best = candidate
				end
			end
		end
	end

	return best
end

local function buildReadinessSummaryToken(report)
	local itemContext = report.itemContext or {}
	local rosterReport = report.rosterReport or {}
	local nameMatchReport = report.nameMatchReport or {}

	return tconcat({
		tostring(report.itemId or ""),
		report.hasReserveData and "1" or "0",
		report.hasItemReserves and "1" or "0",
		tostring(itemContext.totalReserveCount or ""),
		tostring(rosterReport.totalReservePlayers or ""),
		tostring(rosterReport.presentReservePlayers or ""),
		tostring(rosterReport.missingReservePlayers or ""),
		tostring(#(nameMatchReport.strongMatches or {})),
		tostring(#(nameMatchReport.weakMatches or {})),
		tostring(nameMatchReport.unmatchedReservePlayersText or ""),
	}, "|")
end

local function buildReadinessHealth(report)
	local itemContext = report.itemContext or {}
	local rosterReport = report.rosterReport or {}
	local nameMatchReport = report.nameMatchReport or {}
	local health = {
		severity = "ok",
		issueCount = 0,
		hasNoData = false,
		hasCurrentItemIssue = false,
		currentItemIssue = nil,
		importedPlayersOutsideRaidCount = tonumber(rosterReport.missingReservePlayers) or 0,
		raidPlayersWithoutReserveCount = #(nameMatchReport.raidPlayersWithoutReserve or {}),
		aliasMatchCount = #(nameMatchReport.aliasMatches or {}),
		suggestedNameMatchCount = #(nameMatchReport.strongMatches or {}) + #(nameMatchReport.weakMatches or {}),
		unmatchedReserveCount = #(nameMatchReport.unmatchedReservePlayers or {}),
		unmatchedRaidCount = #(nameMatchReport.unmatchedRaidPlayers or {}),
	}

	local function addIssue()
		health.issueCount = health.issueCount + 1
	end

	if report.hasReserveData ~= true then
		health.severity = "error"
		health.hasNoData = true
		addIssue()
		return health
	end

	if report.itemId then
		if report.hasItemReserves ~= true then
			health.hasCurrentItemIssue = true
			health.currentItemIssue = "no_reserves"
			addIssue()
		elseif report.hasEligibleItemReserve ~= true then
			health.hasCurrentItemIssue = true
			health.currentItemIssue = "no_eligible_reservers"
			addIssue()
		end
	end

	if health.importedPlayersOutsideRaidCount > 0 then
		addIssue()
	end
	if health.suggestedNameMatchCount > 0 then
		addIssue()
	end
	if health.unmatchedReserveCount > 0 then
		addIssue()
	end
	if health.unmatchedRaidCount > 0 then
		addIssue()
	end

	if health.issueCount > 0 then
		health.severity = "warning"
	end
	return health
end

-- ----- Public methods ----- --
function Display.RebuildIndex(ctx)
	twipe(ctx.reservesByItemID)
	twipe(ctx.reservesByItemPlayer)
	twipe(ctx.playerItemsByName)
	ctx.setDirty(true)

	for playerKey, player in pairs(ctx.reservesData) do
		if type(player) == "table" and type(player.reserves) == "table" then
			local playerName = ctx.resolvePlayerNameDisplay(playerKey, player)
			player.playerNameDisplay = playerName
			player.original = nil

			local normalizedPlayer = Strings.NormalizeLower(playerName, true) or playerKey
			if type(normalizedPlayer) ~= "string" then
				normalizedPlayer = tostring(playerKey or "")
			end
			if normalizedPlayer == "" then
				normalizedPlayer = "?"
			end

			ctx.playerItemsByName[normalizedPlayer] = ctx.playerItemsByName[normalizedPlayer] or {}

			for i = 1, #player.reserves do
				local reserveEntry = player.reserves[i]
				if type(reserveEntry) == "table" and reserveEntry.rawID then
					reserveEntry.player = nil
					reserveEntry.playerNameDisplay = playerName

					local itemId = reserveEntry.rawID
					local list = ctx.reservesByItemID[itemId]
					if not list then
						list = {}
						ctx.reservesByItemID[itemId] = list
					end
					list[#list + 1] = reserveEntry

					local byPlayer = ctx.reservesByItemPlayer[itemId]
					if not byPlayer then
						byPlayer = {}
						ctx.reservesByItemPlayer[itemId] = byPlayer
					end
					byPlayer[normalizedPlayer] = reserveEntry
					ctx.playerItemsByName[normalizedPlayer][itemId] = true
				end
			end
		end
	end

	twipe(ctx.reservesDisplayList)
	twipe(ctx.grouped)
	if ctx.reservesDisplayActiveKeys then
		twipe(ctx.reservesDisplayActiveKeys)
	end
	for itemId, list in pairs(ctx.reservesByItemID) do
		if type(list) == "table" then
			for i = 1, #list do
				local reserveEntry = list[i]
				if type(reserveEntry) == "table" then
					local source = getReserveSource(reserveEntry.source)
					local byItem = ctx.grouped[itemId]

					if not byItem then
						byItem = {}
						ctx.grouped[itemId] = byItem
					end

					local data = byItem[itemId]
					if not data then
						local rowKey = getDisplayRowKey(nil, itemId)
						if ctx.reservesDisplayActiveKeys then
							ctx.reservesDisplayActiveKeys[rowKey] = true
						end
						if ctx.reservesDisplayRowsByKey then
							data = ctx.reservesDisplayRowsByKey[rowKey]
							if not data then
								data = {}
								ctx.reservesDisplayRowsByKey[rowKey] = data
							end
						else
							data = {}
						end
						prepareReserveDisplayRow(data, itemId, reserveEntry, source)
						byItem[itemId] = data
					end

					addReservePlayer(ctx, data, reserveEntry)
				end
			end
		end
	end

	for _, byItem in pairs(ctx.grouped) do
		for _, data in pairs(byItem) do
			data.playersText, data.playersTooltipLines, data.playersTextFull = buildPlayersText(
				ctx,
				data.itemId,
				data.players,
				data.playerCounts,
				data.playerMeta,
				data.playersTooltipLines
			)
			ctx.reservesDisplayList[#ctx.reservesDisplayList + 1] = data
		end
	end

	if ctx.reservesDisplayRowsByKey and ctx.reservesDisplayActiveKeys then
		for rowKey, row in pairs(ctx.reservesDisplayRowsByKey) do
			if ctx.reservesDisplayActiveKeys[rowKey] ~= true then
				resetReserveDisplayRow(row)
				ctx.reservesDisplayRowsByKey[rowKey] = nil
			end
		end
	end
end

function Display.HasCurrentRaidPlayersForItem(ctx, itemId, raidNum)
	if not itemId then
		return false
	end

	local list = ctx.reservesByItemID[itemId]
	if type(list) ~= "table" or #list == 0 then
		return false
	end

	local hasMatch, filterApplied = hasCurrentRaidPlayer(ctx, list, raidNum)
	if not filterApplied then
		return true
	end

	return hasMatch
end

function Display.GetPlayersForItem(ctx, itemId, useColor, showPlus, showMulti, onlyCurrentRaidPlayers, raidNum)
	if not itemId then
		return {}
	end

	local list = ctx.reservesByItemID[itemId]
	if type(list) ~= "table" then
		return {}
	end

	local data = { players = {}, playerCounts = {}, playerMeta = {} }
	for i = 1, #list do
		local reserveEntry = list[i]
		if type(reserveEntry) == "table" then
			addReservePlayer(ctx, data, reserveEntry)
		end
	end

	if onlyCurrentRaidPlayers == true then
		local filteredPlayers, filterApplied = filterPlayersByCurrentRaid(ctx, data.players, raidNum)
		if filterApplied then
			data.players = filteredPlayers
		end
	end

	local tokens =
		buildPlayerTokens(ctx, itemId, data.players, data.playerCounts, data.playerMeta, useColor, showPlus, showMulti)
	local out = {}
	for i = 1, #tokens do
		out[i] = tokens[i]
	end
	return out
end

function Display.GetItemReserveContext(ctx, itemId, raidNum)
	local context = {
		itemId = itemId,
		mode = ctx.isPlusSystem() and "plus" or "multi",
		hasReserves = false,
		hasPresentReserve = false,
		totalReserveCount = 0,
		presentReserveCount = 0,
		missingReserveCount = 0,
		presentPlayers = {},
		missingPlayers = {},
		presentPlayersText = "",
		missingPlayersText = "",
		isPlusSystem = ctx.isPlusSystem(),
		isMultiReserve = ctx.isMultiReserve(),
		rosterFilterApplied = false,
	}
	if not itemId then
		return context
	end

	local list = ctx.reservesByItemID[itemId]
	if type(list) ~= "table" or #list == 0 then
		return context
	end

	local data = { players = {}, playerCounts = {}, playerMeta = {} }
	for i = 1, #list do
		local reserveEntry = list[i]
		if type(reserveEntry) == "table" then
			addReservePlayer(ctx, data, reserveEntry)
		end
	end

	sortPlayersForDisplay(ctx, itemId, data.players, data.playerCounts, data.playerMeta)
	local presentPlayers, missingPlayers, filterApplied = splitPresentAndMissingPlayers(ctx, data.players, raidNum)
	context.hasReserves = #data.players > 0
	context.hasPresentReserve = #presentPlayers > 0
	context.totalReserveCount = #data.players
	context.presentReserveCount = #presentPlayers
	context.missingReserveCount = #missingPlayers
	context.presentPlayers = presentPlayers
	context.missingPlayers = missingPlayers
	context.presentPlayersText =
		buildTextForPlayers(ctx, itemId, presentPlayers, data.playerCounts, data.playerMeta, true, true)
	context.missingPlayersText =
		buildTextForPlayers(ctx, itemId, missingPlayers, data.playerCounts, data.playerMeta, true, true)
	context.rosterFilterApplied = filterApplied == true
	return context
end

function Display.GetRosterReserveMatchReport(ctx, raidNum)
	local report = {
		mode = ctx.isPlusSystem() and "plus" or "multi",
		totalReservePlayers = 0,
		presentReservePlayers = 0,
		missingReservePlayers = 0,
		presentPlayers = {},
		missingPlayers = {},
		presentPlayersText = "",
		missingPlayersText = "",
		rosterFilterApplied = false,
	}
	local players = getReservePlayerNames(ctx)
	local presentPlayers, missingPlayers, filterApplied = splitPresentAndMissingPlayers(ctx, players, raidNum)
	sortPlayerNames(presentPlayers)
	sortPlayerNames(missingPlayers)

	report.totalReservePlayers = #players
	report.presentReservePlayers = #presentPlayers
	report.missingReservePlayers = #missingPlayers
	report.presentPlayers = presentPlayers
	report.missingPlayers = missingPlayers
	report.presentPlayersText = tconcat(presentPlayers, ", ")
	report.missingPlayersText = tconcat(missingPlayers, ", ")
	report.rosterFilterApplied = filterApplied == true
	return report
end

function Display.GetNameMatchReport(ctx, raidNum)
	local reservePlayers = getReservePlayerNames(ctx)
	local raidPlayers, rosterFilterApplied = getRaidPlayerNames(ctx, raidNum)
	local reserveMissing, raidMissing = splitExactNameMatches(reservePlayers, raidPlayers)
	local aliasMatches = ctx.getAliasMatches and ctx.getAliasMatches(reservePlayers, raidPlayers) or {}
	local aliasReserveKeys = {}
	local aliasRaidKeys = {}
	local usedRaidNames = {}
	local usedReserveNames = {}
	local strongMatches = {}
	local weakMatches = {}
	local unmatchedReservePlayers = {}
	local unmatchedRaidPlayers = {}

	for i = 1, #aliasMatches do
		local match = aliasMatches[i]
		local reserveKey = normalizeAliasKey(match and match.reserveName)
		local raidKey = normalizeAliasKey(match and match.raidName)
		if reserveKey then
			aliasReserveKeys[reserveKey] = true
		end
		if raidKey then
			aliasRaidKeys[raidKey] = true
		end
	end

	reserveMissing = filterAliasMatchedNames(reserveMissing, aliasReserveKeys)
	raidMissing = filterAliasMatchedNames(raidMissing, aliasRaidKeys)

	for i = 1, #reserveMissing do
		local reserveName = reserveMissing[i]
		local candidate = findBestNameCandidate(reserveName, raidMissing, usedRaidNames)
		if candidate then
			usedReserveNames[reserveName] = true
			usedRaidNames[candidate.raidName] = true
			if candidate.strength == "strong" then
				strongMatches[#strongMatches + 1] = candidate
			else
				weakMatches[#weakMatches + 1] = candidate
			end
		end
	end

	for i = 1, #reserveMissing do
		local reserveName = reserveMissing[i]
		if not usedReserveNames[reserveName] then
			unmatchedReservePlayers[#unmatchedReservePlayers + 1] = reserveName
		end
	end
	for i = 1, #raidMissing do
		local raidName = raidMissing[i]
		if not usedRaidNames[raidName] then
			unmatchedRaidPlayers[#unmatchedRaidPlayers + 1] = raidName
		end
	end

	sort(strongMatches, compareNameMatch)
	sort(weakMatches, compareNameMatch)
	sortPlayerNames(unmatchedReservePlayers)
	sortPlayerNames(unmatchedRaidPlayers)

	return {
		reservePlayersOutsideRaid = reserveMissing,
		raidPlayersWithoutReserve = raidMissing,
		aliasMatches = aliasMatches,
		aliasMatchesText = formatAliasMatches(aliasMatches),
		strongMatches = strongMatches,
		weakMatches = weakMatches,
		unmatchedReservePlayers = unmatchedReservePlayers,
		unmatchedRaidPlayers = unmatchedRaidPlayers,
		reservePlayersOutsideRaidText = tconcat(reserveMissing, ", "),
		raidPlayersWithoutReserveText = tconcat(raidMissing, ", "),
		unmatchedReservePlayersText = tconcat(unmatchedReservePlayers, ", "),
		unmatchedRaidPlayersText = tconcat(unmatchedRaidPlayers, ", "),
		rosterFilterApplied = rosterFilterApplied == true,
	}
end

function Display.GetReadinessReport(ctx, itemId, raidNum)
	local itemContext = Display.GetItemReserveContext(ctx, itemId, raidNum)
	local rosterReport = Display.GetRosterReserveMatchReport(ctx, raidNum)
	local nameMatchReport = Display.GetNameMatchReport(ctx, raidNum)
	local report = {
		itemId = itemId,
		mode = ctx.isPlusSystem() and "plus" or "multi",
		hasReserveData = (tonumber(rosterReport.totalReservePlayers) or 0) > 0,
		hasItemReserves = itemContext.hasReserves == true,
		hasEligibleItemReserve = itemContext.hasPresentReserve == true,
		itemContext = itemContext,
		rosterReport = rosterReport,
		nameMatchReport = nameMatchReport,
		rosterFilterApplied = itemContext.rosterFilterApplied == true
			or rosterReport.rosterFilterApplied == true
			or nameMatchReport.rosterFilterApplied == true,
	}

	report.summaryToken = buildReadinessSummaryToken(report)
	report.health = buildReadinessHealth(report)
	return report
end

function Display.GetDisplayList(ctx)
	if ctx.isDirty() then
		sort(ctx.reservesDisplayList, function(a, b)
			local aItemId = tonumber(a.itemId) or 0
			local bItemId = tonumber(b.itemId) or 0
			if aItemId ~= bItemId then
				return aItemId < bItemId
			end
			return false
		end)
		ctx.setDirty(false)
	end
	return ctx.reservesDisplayList
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Reserves/Display", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Modules/Colors",
			"Modules/Strings",
			"Services/Reserves/Aliases",
		},
	})
	registry.SetLoaded("Services/Reserves/Display")
end
