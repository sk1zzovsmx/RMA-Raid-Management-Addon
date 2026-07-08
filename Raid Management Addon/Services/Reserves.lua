-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: emits ReservesDataChanged via addon.Bus
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Diag = feature.Diag

local Events = feature.Events
local C = feature.C
local Options = feature.Options
local Bus = feature.Bus
local Strings = feature.Strings
local Database = feature.Database
local SavedVariables = Database.SavedVariables
local Services = feature.Services
local Item = feature.Item
local LootSources = feature.LootSources
local Timer = feature.Timer

local tconcat, twipe = table.concat, table.wipe
local pairs, ipairs, type, next = pairs, ipairs, type, next
local format = string.format
local match = string.match

local tostring, tonumber = tostring, tonumber
local _G = _G
local GetItemInfo = assert(_G.GetItemInfo, "Reserves item info API is not initialized")
local NormalizeName = assert(Strings.NormalizeName, "Reserves display name normalizer is not initialized")

local InternalEvents = assert(Events.Internal, "Reserves internal events are not initialized")
local TriggerEvent = assert(Bus.TriggerEvent, "Reserves event publisher is not initialized")
local ReservesDataChangedEvent =
	assert(InternalEvents.ReservesDataChanged, "Reserves data-changed event is not initialized")
local IMPORT_APPLY_CHUNK_SIZE = 25
local IMPORT_APPLY_DELAY_SECONDS = 0.01

-- =========== Reserves Module  =========== --
-- Manages item reserves, import, and display.
do
	feature.EnsureServiceNamespace("Reserves")
	local Reserves = Services.Reserves
	local module = Reserves
	module._Sync = module._Sync or {}
	local Sync = module._Sync

	-- Timer ownership: display refresh debounce for reserves.
	Timer.BindMixin(module, "Reserves")

	-- Namespace registration: reserve options (whisper replies and import mode).
	local reservesNs = Options.AddNamespace("Reserves", {
		softResWhisperAdds = false,
		softResWhisperReplies = false,
		srImportMode = 0,
		nameAliases = {},
	})

	local ImportHelpers = assert(module._Import, "Reserves import helpers are not initialized")
	local AliasHelpers = assert(module._Aliases, "Reserves alias helpers are not initialized")
	local DisplayHelpers = assert(module._Display, "Reserves display helpers are not initialized")
	local importParser =
		assert(ImportHelpers.BuildParser and ImportHelpers.BuildParser(), "Missing Reserves import parser")
	local fallbackIcon = C.RESERVES_ITEM_FALLBACK_ICON
	local reserveListClearedKey = "StrReserve" .. "ListCleared"

	-- ----- Internal state ----- --
	local reservesData = {}
	local persistedReservesData = {}
	local reservesByItemID = {}
	local reservesByItemPlayer = {}
	local playerItemsByName = {}
	local reservesDisplayList = {}
	local reservesDisplayRowsByKey = {}
	local reservesDisplayActiveKeys = {}
	local reservesDirty = false
	local importMode = nil -- 'multi' or 'plus'
	local pendingItemInfo = {}
	local pendingItemCount = 0
	local pendingDisplayRefreshHandle = nil
	local pendingDisplayRefreshQueued = false
	local pendingDisplayRefreshDelaySeconds = 0.05
	local grouped = {}
	local syncedCacheMeta = nil
	local syncedCacheActive = false
	local aliasState = nil
	local RebuildIndex
	local hasPendingItem
	local activeImportApply

	-- ----- Private helpers ----- --

	local isDebugEnabled = Options.IsDebugEnabled

	local function normalizeImportMode(mode)
		return (mode == "plus") and "plus" or "multi"
	end

	local function importModeToOptionValue(mode)
		return (normalizeImportMode(mode) == "plus") and 1 or 0
	end

	local function setImportMode(mode, syncOptions)
		local resolved = normalizeImportMode(mode)
		importMode = resolved

		if syncOptions ~= false then
			local value = importModeToOptionValue(resolved)
			reservesNs:Set("srImportMode", value)
		end

		return importMode
	end

	local function getNameAliasMap()
		local value = reservesNs:Get("nameAliases")
		return type(value) == "table" and value or {}
	end

	local function getAliasState()
		if aliasState == nil then
			aliasState = AliasHelpers.BuildAliasState(getNameAliasMap())
		end
		return aliasState
	end

	local function invalidateAliasState()
		aliasState = nil
	end

	local function resolveReservePlayerKey(playerName)
		local exact = Strings.NormalizeLower(playerName, true)
		if exact and reservesData[exact] then
			return exact
		end
		return AliasHelpers.ResolveReserveKey(getAliasState(), reservesData, playerName)
	end

	local function getReserveEntryForItem(itemId, playerName)
		if not itemId or not playerName then
			return nil
		end
		local playerKey = resolveReservePlayerKey(playerName)
		if not playerKey then
			return nil
		end

		local byP = reservesByItemPlayer[itemId]
		if type(byP) == "table" then
			local r = byP[playerKey]
			if r then
				return r
			end
		end

		-- Fallback (should be rare if indices are up to date)
		local entry = reservesData[playerKey]
		if not entry then
			return nil
		end
		for _, r in ipairs(entry.reserves or {}) do
			if r and r.rawID == itemId then
				return r
			end
		end
		return nil
	end

	local RESERVE_ENTRY_PERSISTED_FIELDS = {
		"rawID",
		"itemLink",
		"itemName",
		"itemIcon",
		"quantity",
		"class",
		"spec",
		"note",
		"plus",
		"source",
	}

	local function resolvePlayerNameDisplay(playerKey, player, fallbackName)
		local candidate = fallbackName
		if type(player) == "table" then
			candidate = player.playerNameDisplay or candidate
		end
		if candidate == nil or candidate == "" then
			candidate = playerKey
		end
		candidate = NormalizeName(candidate, true)
		if candidate == nil or candidate == "" then
			return "?"
		end
		return candidate
	end

	local function copyReserveEntryForSave(src)
		if type(src) ~= "table" or not src.rawID then
			return nil
		end

		local dst = {}
		for i = 1, #RESERVE_ENTRY_PERSISTED_FIELDS do
			local key = RESERVE_ENTRY_PERSISTED_FIELDS[i]
			local value = src[key]
			if value ~= nil then
				dst[key] = value
			end
		end

		dst.quantity = tonumber(dst.quantity) or 1
		if dst.quantity < 1 then
			dst.quantity = 1
		end
		dst.plus = tonumber(dst.plus) or 0
		return dst
	end

	local function appendRuntimeReservePlayer(target, rawPlayerKey, player)
		if type(player) ~= "table" then
			return false
		end
		local displayName = resolvePlayerNameDisplay(rawPlayerKey, player, rawPlayerKey)
		local playerKey = Strings.NormalizeLower(displayName, true)
			or Strings.NormalizeLower(rawPlayerKey, true)
			or rawPlayerKey
		if type(playerKey) ~= "string" then
			playerKey = tostring(rawPlayerKey or "")
		end
		if playerKey == "" then
			playerKey = "?"
		end

		local container = target[playerKey]
		if not container then
			container = {
				playerNameDisplay = displayName,
				reserves = {},
			}
			target[playerKey] = container
		elseif not container.playerNameDisplay or container.playerNameDisplay == "?" then
			container.playerNameDisplay = displayName
		end

		local rows = player.reserves
		if type(rows) == "table" then
			for i = 1, #rows do
				local row = rows[i]
				local copied = copyReserveEntryForSave(row)
				if copied then
					container.reserves[#container.reserves + 1] = copied
				end
			end
		end
		return true
	end

	local function buildRuntimeReservesData(sourceData, phaseTag)
		local normalized = {}

		for rawPlayerKey, player in pairs(sourceData or {}) do
			appendRuntimeReservePlayer(normalized, rawPlayerKey, player)
		end
		return normalized
	end

	local function copyReservesData(sourceData, target)
		twipe(target)
		for playerKey, player in pairs(sourceData or {}) do
			target[playerKey] = player
		end
	end

	local function applyRuntimeReservesData(sourceData, phaseTag, target)
		local normalized = buildRuntimeReservesData(sourceData, phaseTag)
		copyReservesData(normalized, target or reservesData)
		return normalized
	end

	local function buildSavedReservesData(sourceData)
		local normalized = {}

		for playerKey, player in pairs(sourceData or {}) do
			if type(player) == "table" then
				local persistedPlayerName = resolvePlayerNameDisplay(playerKey, player, playerKey)
				local container = normalized[persistedPlayerName]
				if not container then
					container = { reserves = {} }
					normalized[persistedPlayerName] = container
				end

				local rows = player.reserves
				if type(rows) == "table" then
					for i = 1, #rows do
						local copied = copyReserveEntryForSave(rows[i])
						if copied then
							container.reserves[#container.reserves + 1] = copied
						end
					end
				end
			end
		end

		return normalized
	end

	local function markPendingItem(itemId, hasName, hasIcon, name, link, icon)
		if not itemId then
			return nil
		end
		local pending = pendingItemInfo[itemId]
		if not pending then
			pending = {
				nameReady = false,
				iconReady = false,
				name = nil,
				link = nil,
				icon = nil,
				requestHandle = nil,
			}
			pendingItemInfo[itemId] = pending
			pendingItemCount = pendingItemCount + 1
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesTrackPending:format(itemId, pendingItemCount))
			end
		end
		if type(name) == "string" and name ~= "" then
			pending.name = name
		end
		if type(link) == "string" and link ~= "" then
			pending.link = link
		end
		if type(icon) == "string" and icon ~= "" then
			pending.icon = icon
		end
		if hasName then
			pending.nameReady = true
		end
		if hasIcon then
			pending.iconReady = true
		end
		return pending
	end

	local function getPendingItemInfo(pending)
		if not pending then
			return nil
		end
		return pending.name, pending.link, pending.icon
	end

	local function notifyReservesDataChanged(reason, raidId, mode, nPlayers)
		TriggerEvent(ReservesDataChangedEvent, reason, raidId, mode, nPlayers)
	end

	local function countReserves(sourceData)
		local players = 0
		local entries = 0
		if type(sourceData) ~= "table" then
			return 0, 0
		end
		for _, player in pairs(sourceData or {}) do
			if type(player) == "table" then
				players = players + 1
				local rows = player.reserves
				if type(rows) == "table" then
					entries = entries + #rows
				end
			end
		end
		return players, entries
	end

	function module:GetCounts(sourceData)
		if sourceData ~= nil then
			return countReserves(sourceData)
		end
		return countReserves(SavedVariables.GetReserves())
	end

	local function finishPerf(label, startedAt, details)
		if not (startedAt and addon._PerfFinish) then
			return
		end
		addon:_PerfFinish(label, startedAt, tostring(details or ""))
	end

	local function getParsedReserveCounts(parsed)
		local players, entries = countReserves(parsed and parsed.reservesData)
		if players == 0 and parsed and parsed.nPlayers then
			players = tonumber(parsed.nPlayers) or players
		end
		return players, entries
	end

	local function perfBool(value)
		return value and "1" or "0"
	end

	local function normalizeImportApplyChunkSize(value)
		local chunkSize = tonumber(value) or IMPORT_APPLY_CHUNK_SIZE
		if chunkSize < 1 then
			return IMPORT_APPLY_CHUNK_SIZE
		end
		return chunkSize
	end

	local function normalizeImportApplyDelay(value)
		local delay = tonumber(value) or IMPORT_APPLY_DELAY_SECONDS
		if delay < 0 then
			return IMPORT_APPLY_DELAY_SECONDS
		end
		return delay
	end

	local function cancelImportApply(state)
		if state and state.handle then
			module:CancelTimer(state.handle)
			state.handle = nil
		end
		if activeImportApply == state then
			activeImportApply = nil
		end
	end

	local function buildReservesChecksum(sourceData, mode)
		local parts = { normalizeImportMode(mode) }
		for playerKey, player in pairs(sourceData or {}) do
			if type(player) == "table" then
				parts[#parts + 1] = tostring(playerKey)
				parts[#parts + 1] = tostring(player.playerNameDisplay or "")
				local rows = player.reserves
				if type(rows) == "table" then
					for i = 1, #rows do
						local row = rows[i]
						if type(row) == "table" then
							parts[#parts + 1] = tostring(row.rawID or "")
							parts[#parts + 1] = tostring(row.quantity or "")
							parts[#parts + 1] = tostring(row.plus or "")
							parts[#parts + 1] = tostring(row.class or "")
						end
					end
				end
			end
		end
		local text = tconcat(parts, "|")
		local checksum = 0
		for i = 1, #text do
			checksum = (checksum + (text:byte(i) * i)) % 1000000007
		end
		return tostring(checksum)
	end

	local function getActiveSyncMetadata()
		local players, entries = countReserves(reservesData)
		return {
			source = syncedCacheActive and (syncedCacheMeta and syncedCacheMeta.source or L.StrUnknown) or "local",
			checksum = syncedCacheActive and (syncedCacheMeta and syncedCacheMeta.checksum)
				or buildReservesChecksum(reservesData, importMode),
			mode = normalizeImportMode(importMode),
			players = players,
			entries = entries,
			runtime = syncedCacheActive == true,
		}
	end

	local function rebuildReserveIndexes(reason, raidId, mode, nPlayers)
		if not RebuildIndex then
			return false
		end
		RebuildIndex()
		if reason then
			notifyReservesDataChanged(reason, raidId, mode, nPlayers)
		end
		return true
	end

	local function saveCanonicalReservesData(canonical)
		rebuildReserveIndexes()
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesSaveEntries:format(addon.tLength(reservesData)))
		end
		SavedVariables.ReplaceReserves(buildSavedReservesData(canonical))
	end

	local function normalizeReserveItemRef(itemRef)
		if type(itemRef) ~= "string" then
			return itemRef
		end

		local text = Strings.TrimText(itemRef, true)
		if text == nil or text == "" then
			return nil
		end

		return match(text, "^%[(.+)%]$") or text
	end

	local function getReserveItemSnapshot(itemRef)
		local normalizedRef = normalizeReserveItemRef(itemRef)
		if normalizedRef == nil then
			return nil
		end

		local itemId = Item.GetItemIdFromLink(normalizedRef)
		local itemName
		local itemLink
		local itemIcon

		local fetchedName, fetchedLink, _, _, _, _, _, _, _, fetchedIcon = GetItemInfo(normalizedRef)
		itemName = fetchedName
		itemLink = fetchedLink
		itemIcon = fetchedIcon

		itemId = itemId or Item.GetItemIdFromLink(itemLink)
		if not itemId then
			return nil
		end

		if type(itemLink) ~= "string" or itemLink == "" then
			if type(normalizedRef) == "string" and normalizedRef:find("|Hitem:", 1, true) then
				itemLink = normalizedRef
			else
				itemLink = nil
			end
		end

		if type(itemName) ~= "string" or itemName == "" then
			itemName = type(itemLink) == "string" and match(itemLink, "|h%[(.-)%]|h") or nil
		end

		if type(itemName) ~= "string" or itemName == "" then
			itemName = type(itemRef) == "string" and match(Strings.TrimText(itemRef), "^%[(.+)%]$") or nil
		end

		if type(itemIcon) ~= "string" or itemIcon == "" then
			itemIcon = type(GetItemIcon) == "function" and GetItemIcon(itemId) or nil
		end
		if type(itemIcon) ~= "string" or itemIcon == "" then
			itemIcon = fallbackIcon
		end

		return {
			rawID = itemId,
			itemLink = itemLink,
			itemName = itemName,
			itemIcon = itemIcon,
			quantity = 1,
			plus = 0,
		}
	end

	local function getCurrentRaidForReserveSource()
		local currentRaid = Database.GetCurrentRaid()
		if type(currentRaid) == "table" then
			return currentRaid
		end
		return Database.EnsureRaidById(currentRaid)
	end

	local function buildReserveSourceContext()
		local raid = getCurrentRaidForReserveSource()
		if type(raid) ~= "table" then
			return nil
		end

		local zone = raid.zone
		return {
			raid = zone,
			zoneName = zone,
			instanceName = zone,
			raidSize = tonumber(raid.size) or 0,
			difficulty = tonumber(raid.difficulty) or 0,
		}
	end

	local function resolveReserveSourceName(itemId)
		local resolver = LootSources
		if type(resolver) ~= "table" or type(resolver.FindSource) ~= "function" then
			return nil
		end

		local source = resolver.FindSource(itemId, buildReserveSourceContext())
		if type(source) ~= "table" then
			return nil
		end

		if source.kind == "shared" and source.shared == true and type(source.npcName) == "string" then
			return source.npcName ~= "" and source.npcName or nil
		end

		if source.reason ~= nil or source.confidence ~= "exact" then
			return nil
		end

		if source.kind ~= "boss" and source.kind ~= "trash" then
			return nil
		end
		if type(source.npcName) ~= "string" or source.npcName == "" then
			return nil
		end
		return source.npcName
	end

	local function getCanonicalReserveRow(player, itemId)
		if type(player) ~= "table" or type(player.reserves) ~= "table" then
			return nil, false
		end

		local first
		local rowCount = #player.reserves
		local kept = {}
		for i = 1, rowCount do
			local row = player.reserves[i]
			if type(row) == "table" and row.rawID == itemId then
				if not first then
					first = row
					kept[#kept + 1] = row
				end
			else
				kept[#kept + 1] = row
			end
		end

		local changed = #kept ~= rowCount
		if changed then
			player.reserves = kept
		end

		return first, changed
	end

	local function ensureMutableLocalReserves()
		if not syncedCacheActive then
			return false
		end
		local normalized = buildRuntimeReservesData(reservesData, "edit")
		copyReservesData(normalized, persistedReservesData)
		copyReservesData(persistedReservesData, reservesData)
		syncedCacheMeta = nil
		syncedCacheActive = false
		return true
	end

	local function normalizeEditNumber(value)
		local n = tonumber(value)
		if n == nil then
			return nil
		end
		return math.floor(n)
	end

	local function getPlayerReserveContainer(playerName)
		local playerKey = resolveReservePlayerKey(playerName)
		if not playerKey then
			return nil, "invalid_player"
		end
		local player = persistedReservesData[playerKey]
		if type(player) ~= "table" then
			return nil, "invalid_player"
		end
		return player, playerKey
	end

	local function upsertPlayerReserve(target, playerKey, displayName, reserveEntry)
		local player = target[playerKey]
		if not player then
			player = {
				playerNameDisplay = displayName,
				reserves = {},
			}
			target[playerKey] = player
		elseif type(player.reserves) ~= "table" then
			player.reserves = {}
		end

		player.playerNameDisplay = player.playerNameDisplay or displayName

		for i = 1, #player.reserves do
			local row = player.reserves[i]
			if type(row) == "table" and row.rawID == reserveEntry.rawID then
				row.itemLink = reserveEntry.itemLink or row.itemLink
				row.itemName = reserveEntry.itemName or row.itemName
				row.itemIcon = reserveEntry.itemIcon or row.itemIcon
				row.quantity = tonumber(row.quantity) or 1
				row.plus = tonumber(row.plus) or 0
				row.source = reserveEntry.source or row.source
				return row, false
			end
		end

		local copied = copyReserveEntryForSave(reserveEntry)
		if not copied then
			return nil, false
		end
		player.reserves[#player.reserves + 1] = copied
		return copied, true
	end

	local function clearDisplayRefreshQueue()
		if pendingDisplayRefreshHandle then
			module:CancelTimer(pendingDisplayRefreshHandle)
			pendingDisplayRefreshHandle = nil
		end
		pendingDisplayRefreshQueued = false
	end

	local function flushDisplayRefresh()
		if pendingDisplayRefreshHandle then
			module:CancelTimer(pendingDisplayRefreshHandle)
			pendingDisplayRefreshHandle = nil
		end
		if pendingDisplayRefreshQueued ~= true or not RebuildIndex then
			return false
		end
		pendingDisplayRefreshQueued = false
		return rebuildReserveIndexes("iteminfo-batch")
	end

	local function scheduleDisplayRefresh(forceImmediate)
		pendingDisplayRefreshQueued = true
		if forceImmediate then
			return flushDisplayRefresh()
		end
		if pendingDisplayRefreshHandle then
			return false
		end
		pendingDisplayRefreshHandle = module:ScheduleTimer(function()
			pendingDisplayRefreshHandle = nil
			flushDisplayRefresh()
		end, pendingDisplayRefreshDelaySeconds)
		return false
	end

	local function finishApplyImport(parsed, raidId, opts, normalized, perfLabel, perfStart, extraDetails)
		clearDisplayRefreshQueue()
		local mode = (parsed.mode == "plus" or parsed.mode == "multi") and parsed.mode or module:GetImportMode()
		copyReservesData(normalized, persistedReservesData)
		copyReservesData(persistedReservesData, reservesData)
		syncedCacheMeta = nil
		syncedCacheActive = false
		setImportMode(mode, true)
		saveCanonicalReservesData(normalized)

		local nPlayers = tonumber(parsed.nPlayers) or addon.tLength(reservesData)
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesParseComplete:format(nPlayers))
		end
		if not (opts and opts.silentInfo) then
			addon:info(format(L.SuccessReservesParsed, tostring(nPlayers)))
			local stats = parsed.importStats or {}
			addon:info(L.MsgReservesImportRows:format(tonumber(stats.validRows) or 0, tonumber(stats.skippedRows) or 0))
		end

		local reason = (opts and opts.reason) or "import"
		notifyReservesDataChanged(reason, raidId, mode, nPlayers)
		local players, entries = countReserves(reservesData)
		finishPerf(
			perfLabel,
			perfStart,
			"mode="
				.. tostring(mode)
				.. " players="
				.. tostring(players)
				.. " entries="
				.. tostring(entries)
				.. " nPlayers="
				.. tostring(nPlayers)
				.. " ok=1"
				.. tostring(extraDetails or "")
		)
		return true, nPlayers
	end

	local function completePendingItem(itemId)
		if not itemId or not pendingItemInfo[itemId] then
			return
		end
		pendingItemInfo[itemId] = nil
		if pendingItemCount > 0 then
			pendingItemCount = pendingItemCount - 1
		end
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesItemReady:format(itemId, pendingItemCount))
		end
		if pendingItemCount == 0 then
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesPendingComplete)
			end
			scheduleDisplayRefresh(true)
			return
		end
		scheduleDisplayRefresh(false)
	end

	local function visitReserveEntriesByItemId(itemId, visitFn)
		if not itemId or type(visitFn) ~= "function" then
			return false
		end

		local list = reservesByItemID[itemId]
		if type(list) == "table" then
			for i = 1, #list do
				local reserveEntry = list[i]
				if type(reserveEntry) == "table" and reserveEntry.rawID == itemId then
					if visitFn(reserveEntry) == true then
						return true
					end
				end
			end
			return false
		end

		for _, player in pairs(reservesData) do
			if type(player) == "table" and type(player.reserves) == "table" then
				for i = 1, #player.reserves do
					local reserveEntry = player.reserves[i]
					if type(reserveEntry) == "table" and reserveEntry.rawID == itemId then
						if visitFn(reserveEntry) == true then
							return true
						end
					end
				end
			end
		end

		return false
	end

	local function getDisplayContext()
		return {
			reservesData = reservesData,
			reservesByItemID = reservesByItemID,
			reservesByItemPlayer = reservesByItemPlayer,
			playerItemsByName = playerItemsByName,
			reservesDisplayList = reservesDisplayList,
			reservesDisplayRowsByKey = reservesDisplayRowsByKey,
			reservesDisplayActiveKeys = reservesDisplayActiveKeys,
			grouped = grouped,
			resolvePlayerNameDisplay = resolvePlayerNameDisplay,
			getReserveEntryForItem = getReserveEntryForItem,
			getPlusForItem = function(itemId, playerName)
				return module:GetPlusForItem(itemId, playerName)
			end,
			isPlusSystem = function()
				return module:GetImportMode() == "plus"
			end,
			isMultiReserve = function()
				return module:GetImportMode() == "multi"
			end,
			getRaidService = function()
				return Services.Raid
			end,
			getCurrentRaid = function()
				return Database.GetCurrentRaid()
			end,
			getAliasState = getAliasState,
			getAliasMatches = function(reservePlayers, raidPlayers)
				return AliasHelpers.GetAliasMatches(getAliasState(), reservePlayers, raidPlayers)
			end,
			setDirty = function(value)
				reservesDirty = value == true
			end,
			isDirty = function()
				return reservesDirty == true
			end,
		}
	end

	RebuildIndex = function()
		DisplayHelpers.RebuildIndex(getDisplayContext())
	end

	-- ----- Public methods ----- --

	-- ----- Saved Data Management ----- --

	function module:Save(contextTag)
		local canonical = applyRuntimeReservesData(persistedReservesData, contextTag or "save", persistedReservesData)
		if not syncedCacheActive then
			copyReservesData(canonical, reservesData)
		end
		saveCanonicalReservesData(canonical)
	end

	function module:Load()
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesLoadData:format(tostring(SavedVariables.GetReserves() ~= nil)))
		end
		clearDisplayRefreshQueue()
		local savedReserves = SavedVariables.GetReserves()
		local normalized = applyRuntimeReservesData(savedReserves, "load", persistedReservesData)
		if not syncedCacheActive then
			copyReservesData(normalized, reservesData)
		end

		importMode = nil
		setImportMode(self:GetImportMode(), true)
		invalidateAliasState()

		rebuildReserveIndexes()
	end

	function module:ClearSavedReserves()
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesClearSavedReserves)
		end
		clearDisplayRefreshQueue()
		SavedVariables.ClearReserves()
		twipe(persistedReservesData)
		twipe(reservesData)
		syncedCacheMeta = nil
		syncedCacheActive = false
		rebuildReserveIndexes("clear")
		local clearMessage = L[reserveListClearedKey]
		if clearMessage then
			addon:info(clearMessage)
		end
	end

	function module:HasData()
		return next(reservesData) ~= nil
	end

	function module:IsLocalDataAvailable()
		return next(persistedReservesData) ~= nil
	end

	function module:HasItemReserves(itemId)
		if not itemId then
			return false
		end
		local list = reservesByItemID[itemId]
		return type(list) == "table" and #list > 0
	end

	-- ----- Reserve Data Handling ----- --

	local function getReserve(playerName)
		if type(playerName) ~= "string" then
			return nil
		end
		local player = resolveReservePlayerKey(playerName)
		local reserve = player and reservesData[player] or nil

		-- Log when the function is called and show the reserve for the player
		if isDebugEnabled() then
			if reserve then
				addon:debug(Diag.D.LogReservesPlayerFound:format(playerName, tostring(reserve)))
			else
				addon:debug(Diag.D.LogReservesPlayerNotFound:format(playerName))
			end
		end

		return reserve
	end

	function module:GetNameAliases()
		return AliasHelpers.CopyAliasMap(getNameAliasMap())
	end

	function module:SetNameAlias(reserveName, raidName)
		local nextMap = AliasHelpers.CopyAliasMap(getNameAliasMap())
		local ok, reason = AliasHelpers.SetAlias(nextMap, reserveName, raidName)
		if not ok then
			return false, reason
		end
		reservesNs:Set("nameAliases", nextMap)
		invalidateAliasState()
		rebuildReserveIndexes("alias", nil, self:GetImportMode(), addon.tLength(reservesData))
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesAliasSet:format(tostring(reserveName), tostring(raidName)))
		end
		return true
	end

	function module:RemoveNameAlias(reserveName)
		local nextMap = AliasHelpers.CopyAliasMap(getNameAliasMap())
		local ok, reason = AliasHelpers.ClearAlias(nextMap, reserveName)
		if not ok then
			return false, reason
		end
		reservesNs:Set("nameAliases", nextMap)
		invalidateAliasState()
		rebuildReserveIndexes("alias", nil, self:GetImportMode(), addon.tLength(reservesData))
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesAliasCleared:format(tostring(reserveName)))
		end
		return true
	end

	function module:GetPlayerReserveEntries(playerName)
		local reserve = getReserve(playerName)
		if type(reserve) ~= "table" or type(reserve.reserves) ~= "table" then
			return {}
		end

		local entries = {}
		for i = 1, #reserve.reserves do
			local row = reserve.reserves[i]
			if type(row) == "table" then
				entries[#entries + 1] = row
			end
		end
		return entries
	end

	function module:SetPlayerReserveQuantity(playerName, itemId, quantity)
		if not playerName or not itemId then
			return false, "invalid_input"
		end

		local numericQuantity = normalizeEditNumber(quantity)
		if not numericQuantity then
			return false, "invalid_quantity"
		end

		numericQuantity = tonumber(numericQuantity) or 1
		if numericQuantity < 1 then
			numericQuantity = 1
		end

		ensureMutableLocalReserves()

		local player, playerKey = getPlayerReserveContainer(playerName)
		if not player then
			return false, playerKey
		end

		local row, changed = getCanonicalReserveRow(player, tonumber(itemId))
		if not row then
			return false, "missing_item"
		end
		if tonumber(row.quantity) == numericQuantity and not changed then
			return false, "no_change"
		end

		row.quantity = numericQuantity
		copyReservesData(persistedReservesData, reservesData)
		saveCanonicalReservesData(persistedReservesData)
		rebuildReserveIndexes("edit-reserve", nil, self:GetImportMode(), addon.tLength(reservesData))
		return true
	end

	function module:SetPlayerReservePlus(playerName, itemId, plus)
		if not playerName or not itemId then
			return false, "invalid_input"
		end

		local numericPlus = normalizeEditNumber(plus)
		if not numericPlus then
			return false, "invalid_plus"
		end

		if numericPlus < 0 then
			numericPlus = 0
		end

		ensureMutableLocalReserves()

		local player, playerKey = getPlayerReserveContainer(playerName)
		if not player then
			return false, playerKey
		end

		local row, changed = getCanonicalReserveRow(player, tonumber(itemId))
		if not row then
			return false, "missing_item"
		end
		if tonumber(row.plus) == numericPlus and not changed then
			return false, "no_change"
		end

		row.plus = numericPlus
		copyReservesData(persistedReservesData, reservesData)
		saveCanonicalReservesData(persistedReservesData)
		rebuildReserveIndexes("edit-reserve", nil, self:GetImportMode(), addon.tLength(reservesData))
		return true
	end

	function module:RemovePlayerReserve(playerName, itemId)
		if not playerName or not itemId then
			return false, "invalid_input"
		end

		ensureMutableLocalReserves()

		local player, playerKey = getPlayerReserveContainer(playerName)
		if not player then
			return false, playerKey
		end

		if type(player.reserves) ~= "table" then
			return false, "missing_item"
		end

		local itemKey = tonumber(itemId)
		local keep = {}
		local removed = false
		for i = 1, #player.reserves do
			local row = player.reserves[i]
			if type(row) == "table" and row.rawID == itemKey then
				removed = true
			else
				keep[#keep + 1] = row
			end
		end

		if not removed then
			return false, "missing_item"
		end

		if #keep > 0 then
			player.reserves = keep
		else
			persistedReservesData[playerKey] = nil
			reservesData[playerKey] = nil
		end

		copyReservesData(persistedReservesData, reservesData)
		saveCanonicalReservesData(persistedReservesData)
		rebuildReserveIndexes("edit-reserve", nil, self:GetImportMode(), addon.tLength(reservesData))
		return true
	end

	function module:AddPlayerReserve(playerName, itemRef)
		local displayName = resolvePlayerNameDisplay(nil, nil, playerName)
		if displayName == "?" then
			return false, "invalid_player"
		end

		local reserveEntry = getReserveItemSnapshot(itemRef)
		if not reserveEntry then
			return false, "invalid_item"
		end

		reserveEntry.source = resolveReserveSourceName(reserveEntry.rawID)

		local playerKey = resolveReservePlayerKey(displayName) or Strings.NormalizeLower(displayName, true)
		if playerKey == nil or playerKey == "" then
			return false, "invalid_player"
		end

		local row = upsertPlayerReserve(persistedReservesData, playerKey, displayName, reserveEntry)
		if not row then
			return false, "invalid_item"
		end

		syncedCacheMeta = nil
		syncedCacheActive = false
		copyReservesData(persistedReservesData, reservesData)
		saveCanonicalReservesData(persistedReservesData)
		notifyReservesDataChanged("whisper-reserve", nil, self:GetImportMode(), addon.tLength(reservesData))
		return true, row
	end

	-- Parse imported text (SoftRes CSV)
	-- mode: "multi" (multi-reserve enabled; Plus ignored) or "plus" (priority; requires 1 item per player)
	function module:GetImportMode()
		if importMode == nil then
			local inferred

			-- Infer import mode from loaded data when possible.
			-- If we detect any multi-item or quantity>1 entries, treat it as Multi-reserve.
			for _, player in pairs(reservesData) do
				if type(player) == "table" and type(player.reserves) == "table" then
					if #player.reserves > 1 then
						inferred = "multi"
						break
					end
					for i = 1, #player.reserves do
						local reserveEntry = player.reserves[i]
						local quantity = (type(reserveEntry) == "table" and tonumber(reserveEntry.quantity)) or 1
						if quantity and quantity > 1 then
							inferred = "multi"
							break
						end
					end
				end
				if inferred == "multi" then
					break
				end
			end

			if not inferred then
				local optionValue = reservesNs:Get("srImportMode")
				inferred = (optionValue == 1) and "plus" or "multi"
			end

			setImportMode(inferred, false)
		end
		return importMode
	end

	-- Count of players and total reserve entries currently loaded in-memory.

	-- Strategy-based CSV parsing moved to Services/Reserves/Import.lua.
	local updateReserveItemData

	local function requestReserveItemInfo(itemId, pending)
		if not itemId or not Item or type(Item.RequestItemInfo) ~= "function" then
			return false
		end
		if pending and pending.requestHandle and not pending.requestHandle:IsCancelled() then
			return true
		end

		local handle
		handle = Item.RequestItemInfo(itemId, function(snapshot, ok)
			local current = pendingItemInfo[itemId]
			if not current or current.requestHandle ~= handle then
				return
			end
			current.requestHandle = nil

			if ok ~= true or type(snapshot) ~= "table" then
				return
			end

			local name = snapshot.itemName
			local link = snapshot.itemLink
			local icon = snapshot.itemTexture
			if (type(icon) ~= "string" or icon == "") and type(GetItemIcon) == "function" then
				local fetchedIcon = GetItemIcon(itemId)
				if type(fetchedIcon) == "string" and fetchedIcon ~= "" then
					icon = fetchedIcon
				end
			end

			local hasName = type(name) == "string" and name ~= "" and type(link) == "string" and link ~= ""
			local hasIcon = type(icon) == "string" and icon ~= ""
			if hasName then
				updateReserveItemData(itemId, name, link, icon)
			end
			markPendingItem(itemId, hasName, hasIcon, name, link, icon)
			if hasName and hasIcon then
				if isDebugEnabled() then
					addon:debug(Diag.D.LogReservesItemInfoReady:format(itemId, name))
				end
				completePendingItem(itemId)
			end
		end)

		if handle then
			local current = pendingItemInfo[itemId]
			if current then
				current.requestHandle = handle
			end
			return true
		end
		return false
	end

	function module:SetImportMode(mode, syncOptions)
		return setImportMode(mode, syncOptions)
	end

	function module:IsPlusSystem()
		return self:GetImportMode() == "plus"
	end

	function module:ParseImport(text, mode, opts)
		local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
		local parsed, errCode, errData = importParser.ParseImport(self, text, mode, opts)
		local players, entries = getParsedReserveCounts(parsed)
		finishPerf(
			"Reserves.ParseImport",
			perfStart,
			"mode="
				.. normalizeImportMode(mode)
				.. " bytes="
				.. tostring(type(text) == "string" and #text or 0)
				.. " players="
				.. tostring(players)
				.. " entries="
				.. tostring(entries)
				.. " ok="
				.. perfBool(type(parsed) == "table")
				.. " reason="
				.. tostring(errCode or "")
		)
		return parsed, errCode, errData
	end

	function module:ApplyImport(parsed, raidId, opts)
		local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
		if type(parsed) ~= "table" or type(parsed.reservesData) ~= "table" then
			finishPerf("Reserves.ApplyImport", perfStart, "ok=0 reason=INVALID_PARSED")
			return false, "INVALID_PARSED"
		end

		local normalized = buildRuntimeReservesData(parsed.reservesData, "import")
		return finishApplyImport(parsed, raidId, opts, normalized, "Reserves.ApplyImport", perfStart)
	end

	function module:RequestApplyImport(parsed, raidId, callback, opts)
		opts = (type(opts) == "table") and opts or {}
		local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
		if type(parsed) ~= "table" or type(parsed.reservesData) ~= "table" then
			finishPerf("Reserves.RequestApplyImport", perfStart, "ok=0 reason=INVALID_PARSED")
			if type(callback) == "function" then
				callback(false, "INVALID_PARSED")
			end
			return {
				Cancel = function()
					return false
				end,
				IsCancelled = function()
					return true
				end,
			}
		end

		if activeImportApply then
			activeImportApply.cancelled = true
			cancelImportApply(activeImportApply)
		end

		local state = {
			parsed = parsed,
			raidId = raidId,
			callback = callback,
			opts = opts,
			normalized = {},
			sourceData = parsed.reservesData,
			nextKey = nil,
			chunkSize = normalizeImportApplyChunkSize(opts.chunkSize),
			delay = normalizeImportApplyDelay(opts.delaySeconds),
			processed = 0,
			chunks = 0,
			perfStart = perfStart,
			cancelled = false,
		}
		activeImportApply = state

		local function completeImportApply()
			if activeImportApply == state then
				activeImportApply = nil
			end
			local ok, nPlayers = finishApplyImport(
				state.parsed,
				state.raidId,
				state.opts,
				state.normalized,
				"Reserves.RequestApplyImport",
				state.perfStart,
				" chunks=" .. tostring(state.chunks) .. " processed=" .. tostring(state.processed)
			)
			if type(state.callback) == "function" then
				state.callback(ok, nPlayers)
			end
		end

		local runChunk

		runChunk = function()
			state.handle = nil
			if state.cancelled then
				return
			end

			local processed = 0
			while processed < state.chunkSize do
				local key, player = next(state.sourceData, state.nextKey)
				state.nextKey = key
				if key == nil then
					completeImportApply()
					return
				end
				appendRuntimeReservePlayer(state.normalized, key, player)
				processed = processed + 1
				state.processed = state.processed + 1
			end

			state.chunks = state.chunks + 1
			if next(state.sourceData, state.nextKey) == nil then
				completeImportApply()
				return
			end
			state.handle = module:ScheduleTimer(runChunk, state.delay)
		end

		state.handle = module:ScheduleTimer(runChunk, state.delay)

		local handle = {}
		function handle:Cancel()
			if state.cancelled then
				return false
			end
			state.cancelled = true
			cancelImportApply(state)
			finishPerf(
				"Reserves.RequestApplyImport",
				state.perfStart,
				"ok=0 reason=CANCELLED chunks=" .. tostring(state.chunks) .. " processed=" .. tostring(state.processed)
			)
			return true
		end
		function handle:IsCancelled()
			return state.cancelled == true or activeImportApply ~= state
		end
		return handle
	end

	-- ----- Item Info Querying ----- --
	function module:QueryItemInfo(itemId)
		local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
		if not itemId then
			finishPerf("Reserves.QueryItemInfo", perfStart, "item=? ready=0 pending=" .. tostring(pendingItemCount))
			return
		end
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesQueryItemInfo:format(itemId))
		end
		local pending = pendingItemInfo[itemId]
		local name, link, icon = getPendingItemInfo(pending)
		local hasName = type(name) == "string" and name ~= "" and type(link) == "string" and link ~= ""
		local hasIcon = type(icon) == "string" and icon ~= ""

		if not hasName then
			local fetchedName, fetchedLink, _, _, _, _, _, _, _, tex = GetItemInfo(itemId)
			if type(fetchedName) == "string" and fetchedName ~= "" then
				name = fetchedName
			end
			if type(fetchedLink) == "string" and fetchedLink ~= "" then
				link = fetchedLink
			end
			if type(tex) == "string" and tex ~= "" then
				icon = icon or tex
			end
		end

		if not hasIcon then
			local fetchedIcon = GetItemIcon(itemId)
			if type(fetchedIcon) == "string" and fetchedIcon ~= "" then
				icon = fetchedIcon
			end
		end

		hasName = type(name) == "string" and name ~= "" and type(link) == "string" and link ~= ""
		hasIcon = type(icon) == "string" and icon ~= ""
		if hasName then
			updateReserveItemData(itemId, name, link, icon)
		end
		pending = markPendingItem(itemId, hasName, hasIcon, name, link, icon)
		if hasName and hasIcon then
			if isDebugEnabled() then
				addon:debug(Diag.D.LogReservesItemInfoReady:format(itemId, name))
			end
			completePendingItem(itemId)
			finishPerf(
				"Reserves.QueryItemInfo",
				perfStart,
				"item=" .. tostring(itemId) .. " ready=1 pending=" .. tostring(pendingItemCount)
			)
			return true
		end

		requestReserveItemInfo(itemId, pending)

		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesItemInfoPendingQuery:format(itemId))
		end
		finishPerf(
			"Reserves.QueryItemInfo",
			perfStart,
			"item=" .. tostring(itemId) .. " ready=0 pending=" .. tostring(pendingItemCount)
		)
		return false
	end

	-- Query all missing items for reserves
	function module:QueryMissingItems(silent, primeFn)
		local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
		local seen = {}
		local count = 0
		local updated = false
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesQueryMissingItems)
		end
		for _, player in pairs(reservesData) do
			if type(player) == "table" and type(player.reserves) == "table" then
				for _, r in ipairs(player.reserves) do
					local itemId = r.rawID
					if itemId and not seen[itemId] and (not r.itemLink or not r.itemIcon) then
						seen[itemId] = true
						if not self:QueryItemInfo(itemId) then
							if type(primeFn) == "function" then
								primeFn(itemId)
							end
							count = count + 1
						else
							updated = true
						end
					end
				end
			end
		end
		if not silent then
			if count > 0 then
				addon:info(L.MsgReserveItemsRequested, count)
			else
				addon:info(L.MsgReserveItemsReady)
			end
		end
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesMissingItems:format(count))
			addon:debug(Diag.D.LogSRQueryMissingItems:format(tostring(updated), count))
		end
		finishPerf(
			"Reserves.QueryMissingItems",
			perfStart,
			"missing=" .. tostring(count) .. " updated=" .. perfBool(updated)
		)
		return updated, count
	end

	-- Update reserve item data
	updateReserveItemData = function(itemId, itemName, itemLink, itemIcon)
		if not itemId then
			return
		end
		local icon = itemIcon
		if (type(icon) ~= "string" or icon == "") and itemName then
			icon = fallbackIcon
		end
		reservesDirty = true

		visitReserveEntriesByItemId(itemId, function(reserveEntry)
			reserveEntry.itemName = itemName
			reserveEntry.itemLink = itemLink
			reserveEntry.itemIcon = icon
			return false
		end)

		scheduleDisplayRefresh(false)

		return icon
	end

	function module:GetReserveCountForItem(itemId, playerName)
		local r = getReserveEntryForItem(itemId, playerName)
		if not r then
			return 0
		end
		return tonumber(r.quantity) or 1
	end

	-- Gets the "Plus" value for a reserved item for a player (0 if missing).
	function module:GetPlusForItem(itemId, playerName)
		-- Plus values are meaningful only in Plus System mode.
		if self:GetImportMode() ~= "plus" then
			return 0
		end
		local r = getReserveEntryForItem(itemId, playerName)
		return (r and tonumber(r.plus)) or 0
	end

	-- Returns true when at least one reserve player for the item is present in
	-- the current raid (or in raidNum when provided).
	-- If raid context is unavailable, keeps backward-compatible behavior and
	-- treats any reserve entry as eligible.

	function module:HasCurrentRaidPlayersForItem(itemId, raidNum)
		return DisplayHelpers.HasCurrentRaidPlayersForItem(getDisplayContext(), itemId, raidNum)
	end

	function module:GetItemReserveContext(itemId, raidNum)
		return DisplayHelpers.GetItemReserveContext(getDisplayContext(), itemId, raidNum)
	end

	function module:GetReadinessReport(itemId, raidNum)
		local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
		local report = DisplayHelpers.GetReadinessReport(getDisplayContext(), itemId, raidNum)
		local rosterReport = report and report.rosterReport or {}
		finishPerf(
			"Reserves.GetReadinessReport",
			perfStart,
			"item="
				.. tostring(itemId or "")
				.. " players="
				.. tostring(rosterReport.totalReservePlayers or 0)
				.. " hasData="
				.. perfBool(report and report.hasReserveData == true)
				.. " hasItem="
				.. perfBool(report and report.hasItemReserves == true)
		)
		return report
	end

	function module:GetPlayersForItem(itemId, useColor, showPlus, showMulti, onlyCurrentRaidPlayers, raidNum)
		return DisplayHelpers.GetPlayersForItem(
			getDisplayContext(),
			itemId,
			useColor,
			showPlus,
			showMulti,
			onlyCurrentRaidPlayers,
			raidNum
		)
	end

	-- ----- SR Announcement Formatting ----- --

	-- Returns a list of formatted player tokens for an item.
	-- useColor:
	--   true/nil -> UI rendering (class colors)
	--   false    -> chat-safe rendering (no class color codes)
	-- showPlus:
	--   true/nil -> include "(P+N)" when Plus System is enabled
	--   false    -> hide Plus suffixes from formatted player tokens
	-- showMulti:
	--   true/nil -> include "(xN)" when Multi-reserve is enabled
	--   false    -> hide multi-reserve count suffixes from player tokens
	-- onlyCurrentRaidPlayers:
	--   true -> include only players present in the current raid (or raidNum if provided)
	-- raidNum:
	--   optional explicit raid id used when onlyCurrentRaidPlayers is true

	-- Returns the formatted player list for an item (comma-separated).
	-- useColor, showPlus, showMulti, onlyCurrentRaidPlayers, and raidNum
	-- follow the same rules as GetPlayersForItem.
	function module:FormatReservedPlayersLine(itemId, useColor, showPlus, showMulti, onlyCurrentRaidPlayers, raidNum)
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesFormatPlayers:format(itemId))
		end
		local list = self:GetPlayersForItem(itemId, useColor, showPlus, showMulti, onlyCurrentRaidPlayers, raidNum)
		-- Log the list of players found for the item
		if isDebugEnabled() then
			addon:debug(Diag.D.LogReservesPlayersList:format(itemId, tconcat(list, ", ")))
		end
		return #list > 0 and tconcat(list, ", ") or ""
	end

	function module:GetDisplayList()
		local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
		local wasDirty = reservesDirty == true
		local list = DisplayHelpers.GetDisplayList(getDisplayContext())
		finishPerf(
			"Reserves.GetDisplayList",
			perfStart,
			"rows=" .. tostring(type(list) == "table" and #list or 0) .. " dirty=" .. perfBool(wasDirty)
		)
		return list
	end

	function module:GetSyncMetadata()
		return getActiveSyncMetadata()
	end

	function Sync:GetPayload()
		return persistedReservesData, getActiveSyncMetadata()
	end

	function Sync:SetSyncedData(sourceData, meta)
		if module:IsLocalDataAvailable() then
			return false, "local_data_present"
		end

		local normalized = applyRuntimeReservesData(sourceData, "sync", reservesData)
		local mode = normalizeImportMode(meta and meta.mode)
		setImportMode(mode, false)

		local players, entries = countReserves(normalized)
		syncedCacheMeta = {
			source = tostring((meta and meta.source) or L.StrUnknown),
			checksum = tostring((meta and meta.checksum) or buildReservesChecksum(normalized, mode)),
			mode = mode,
			players = players,
			entries = entries,
			runtime = true,
		}
		syncedCacheActive = true
		rebuildReserveIndexes("sync", nil, mode, players)
		return true
	end

	function module:SetSyncedData(sourceData, meta)
		return Sync:SetSyncedData(sourceData, meta)
	end

	function module:DeleteSyncedReservesCache()
		if not syncedCacheActive then
			return false
		end
		syncedCacheMeta = nil
		syncedCacheActive = false
		copyReservesData(persistedReservesData, reservesData)
		rebuildReserveIndexes("sync-clear", nil, importMode, addon.tLength(reservesData))
		return true
	end

	function module:RequestSyncMetadata()
		if not (Sync and Sync.RequestMetadata) then
			return false
		end
		return Sync:RequestMetadata()
	end

	function module:HandleSyncMessage(prefix, msg, channel, sender)
		if not (Sync and Sync.HandleMessage) then
			return false
		end
		return Sync:HandleMessage(prefix, msg, channel, sender)
	end

	hasPendingItem = function(itemId)
		if not itemId then
			return false
		end
		return pendingItemInfo[itemId] ~= nil
	end

	function module:HasPendingItem(itemId)
		return hasPendingItem(itemId)
	end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Reserves", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/DB",
			"Database/DBRaidStore",
			"Database/SavedVariables",
			"Database/DBOptions",
			"Modules/C",
			"Modules/Timer",
			"Modules/Events",
			"Modules/Bus",
			"Modules/Strings",
			"Modules/Item",
			"Modules/LootSources",
			"Services/Reserves/Import",
			"Services/Reserves/Aliases",
			"Services/Reserves/Display",
		},
	})
	registry.SetLoaded("Services/Reserves")
end
