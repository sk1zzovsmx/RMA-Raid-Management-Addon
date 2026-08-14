-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: emits SetItem/RaidLootUpdate; delegates distribution messages
local addon = select(2, ...)
local Diag = addon.Diag
local L = addon.L

local Events = addon.Events
local C = addon.C
local Database = addon.Database
local Bus = addon.Bus
local Deformat = addon.Deformat
local Item = addon.Item
local Options = addon.Options
local Strings = addon.Strings
local Time = addon.Time
local Timer = addon.Timer

local NormalizeName = Strings.NormalizeName

local Services = addon.Services

local itemColors = addon.C.itemColors

local InternalEvents = assert(Events.Internal, Diag.A.LootServiceInternalEventsNotInitialized)
local TriggerEvent = assert(Bus.TriggerEvent, Diag.A.LootServiceEventPublisherNotInitialized)
local RaidLootUpdateEvent =
	assert(InternalEvents.RaidLootUpdate, Diag.A.LootServiceRaidLootUpdateEventNotInitialized)
local SetItemEvent = assert(InternalEvents.SetItem, Diag.A.LootServiceSelectedItemEventNotInitialized)
local DistributionChangedEvent =
	assert(InternalEvents.LootDistributionSessionChanged, Diag.A.LootServiceDistributionEventNotInitialized)

local _, lootState, itemInfo, raidState = Database.EnsureLootRuntimeState()
local rollTypes = addon.C.rollTypes

lootState.lootCount = tonumber(lootState.lootCount) or 0
lootState.currentItemIndex = tonumber(lootState.currentItemIndex) or 0
lootState.currentRollType = tonumber(lootState.currentRollType) or lootState.currentRollType
lootState.currentRollItem = tonumber(lootState.currentRollItem) or 0
lootState.selectedItemCount = tonumber(lootState.selectedItemCount) or 1
lootState.pendingAwards = lootState.pendingAwards or {}
if lootState.opened == nil then
	lootState.opened = false
end
if lootState.fromInventory == nil then
	lootState.fromInventory = false
end

local itemExists, getItem
local getItemName, getItemLink, getItemTexture

local tinsert, tconcat, twipe = table.insert, table.concat, table.wipe
local type, pairs = type, pairs
local strmatch, strlower = string.match, string.lower

local tostring, tonumber = tostring, tonumber
local _G = _G
local GetLootThreshold = assert(_G.GetLootThreshold, Diag.A.LootServiceLootThresholdApiNotInitialized)
local PENDING_AWARD_TTL_SECONDS = tonumber(C.PENDING_AWARD_TTL_SECONDS) or 8
local GROUP_LOOT_PENDING_AWARD_TTL_SECONDS = tonumber(C.GROUP_LOOT_PENDING_AWARD_TTL_SECONDS) or 60
local BOSS_EVENT_CONTEXT_TTL_SECONDS = tonumber(C.BOSS_EVENT_CONTEXT_TTL_SECONDS) or 30
local GROUP_LOOT_RECOVERY_FACT_LIMIT = 64
local UNCOMMON_ITEM_RARITY = 2
local UNCOMMON_ITEM_LINK_COLOR = "ff1eff00"

-- =========== Loot Helpers Module  =========== --
-- Manages the loot window items (fetching from loot/inventory).
do
	addon.Services.EnsureNamespace("Loot")
	local Loot = Services.Loot
	local module = Loot

	-- Timer ownership: cache-warm scheduling for loot items.
	Timer.BindMixin(module, "Loot")

	local LootAttribution = assert(module.LootAttribution, Diag.A.LootAttributionOwnerNotInitialized)
	local PassiveGroupLoot = assert(module._PassiveGroupLoot, Diag.A.LootPassiveGroupLootHelpersNotInitialized)
	local Tracking = assert(module._Tracking, Diag.A.LootTrackingHelpersNotInitialized)
	local Workflow = assert(module._Workflow, Diag.A.LootWorkflowHelpersNotInitialized)
	local Recording = assert(module._Recording, Diag.A.LootRecordingHelpersNotInitialized)
	local Rules = assert(module._Rules, Diag.A.LootRulesHelpersNotInitialized)
	local AwardPlanner = assert(module.AwardPlanner, Diag.A.LootAwardPlannerOwnerNotInitialized)
	local Inventory = assert(module.Inventory, Diag.A.LootInventoryOwnerNotInitialized)
	local DistributionSession = assert(module.DistributionSession, Diag.A.LootDistributionSessionOwnerNotInitialized)
	local ContextHelpers = assert(module._Context, Diag.A.LootContextHelpersNotInitialized)
	local resolveRaidRecord = assert(ContextHelpers.ResolveRaidRecord, Diag.A.MissingLootContextResolveRaidRecord)

	local function resolveStoredLootLooterName(raid, loot)
		local queries = Database.GetRaidQueries()
		return queries:ResolveLootLooterName(raid, loot)
	end
	local isIgnoredItem = assert(Rules._IsIgnoredItem, Diag.A.MissingLootRulesIsIgnoredItem)

	-- ----- Internal state ----- --
	local lootTable = {}
	local cacheWarmQueue = {}
	local cacheWarmQueued = {}
	local cacheWarmHead = 1
	local cacheWarmHandle
	local CACHE_WARM_DELAY_SECONDS = 0.15
	local CHEAP_SUGGESTION_OPTS = { allowItemInfo = false, allowTooltip = false }
	local workflowContext = lootState.workflowShadow or {}
	lootState.workflowShadow = workflowContext
	local authorityRecoveryLootFacts = {}
	local authorityRecoveryLootFactKeys = {}

	local function notifyRaidLootUpdate(raidNum, loot)
		TriggerEvent(RaidLootUpdateEvent, raidNum, loot)
	end

	local function notifySelectedItem(itemLink, item)
		TriggerEvent(SetItemEvent, itemLink, item)
	end

	-- ----- Private helpers ----- --
	local scheduleCacheWarm, refreshDeferredAutoLootSuggestion, evaluateAutoLootSuggestion
	local requestLootItemInfo, setSelectedItem

	local GetOption = Options.GetValue

	local function warmItemCacheNow(itemLink)
		local probe = Item
		if probe and probe.WarmItemCache then
			probe.WarmItemCache(itemLink)
		end
	end

	local function resetCacheWarmQueue()
		twipe(cacheWarmQueue)
		twipe(cacheWarmQueued)
		cacheWarmHead = 1
	end

	local function processCacheWarmQueue()
		cacheWarmHandle = nil

		local itemLink = cacheWarmQueue[cacheWarmHead]
		if not itemLink then
			resetCacheWarmQueue()
			return
		end

		cacheWarmQueue[cacheWarmHead] = nil
		cacheWarmHead = cacheWarmHead + 1
		cacheWarmQueued[itemLink] = nil
		warmItemCacheNow(itemLink)
		if refreshDeferredAutoLootSuggestion then
			refreshDeferredAutoLootSuggestion(itemLink)
		end

		if cacheWarmQueue[cacheWarmHead] then
			scheduleCacheWarm()
		else
			resetCacheWarmQueue()
		end
	end

	scheduleCacheWarm = function()
		if cacheWarmHandle then
			return
		end
		cacheWarmHandle = module:ScheduleTimer(processCacheWarmQueue, CACHE_WARM_DELAY_SECONDS)
	end

	local function warmItemCache(itemLink)
		if type(itemLink) ~= "string" or itemLink == "" then
			return
		end
		if cacheWarmQueued[itemLink] then
			return
		end

		cacheWarmQueued[itemLink] = true
		cacheWarmQueue[#cacheWarmQueue + 1] = itemLink
		scheduleCacheWarm()
	end

	local function resolveItemColor(itemLink, itemRarity, colorHint)
		if colorHint then
			return colorHint
		end
		if type(itemLink) == "string" then
			local color = itemLink:match("|c(%x%x%x%x%x%x%x%x)|Hitem:")
			if color then
				return color
			end
		end

		local rarity = tonumber(itemRarity) or 1
		return itemColors[rarity + 1] or itemColors[2]
	end

	local function buildDistributionWindowItems()
		local items = {}
		for i = 1, lootState.lootCount do
			local item = lootTable[i]
			if item and item.itemLink then
				items[#items + 1] = {
					itemKey = item.itemKey or (Item.GetItemStringFromLink(item.itemLink) or item.itemLink),
					itemLink = item.itemLink,
					itemName = item.itemName,
					itemTexture = item.itemTexture,
					itemColor = item.itemColor,
					quality = item.itemRarity,
					count = tonumber(item.count) or 1,
					slot = i,
				}
			end
		end
		return items
	end

	requestLootItemInfo = function(index, itemLink)
		local probe = Item
		if not (probe and type(probe.RequestItemInfo) == "function" and type(itemLink) == "string") then
			return false
		end

		local item = lootTable[index]
		if not item or item._itemInfoRequest then
			return false
		end

		local expectedKey = probe.GetItemStringFromLink and (probe.GetItemStringFromLink(itemLink) or itemLink)
			or itemLink
		local expectedId = probe.GetItemIdFromLink and probe.GetItemIdFromLink(itemLink) or nil
		local handle
		handle = probe.RequestItemInfo(itemLink, function(snapshot, ok)
			local current = lootTable[index]
			if not current or current._itemInfoRequest ~= handle then
				return
			end
			current._itemInfoRequest = nil
			if ok ~= true or type(snapshot) ~= "table" then
				return
			end

			local currentLink = current.itemLink
			local currentKey = probe.GetItemStringFromLink and (probe.GetItemStringFromLink(currentLink) or currentLink)
				or currentLink
			local currentId = probe.GetItemIdFromLink and probe.GetItemIdFromLink(currentLink) or nil
			if currentKey ~= expectedKey and not (expectedId and currentId and currentId == expectedId) then
				return
			end

			current.itemName = snapshot.itemName or current.itemName
			current.itemLink = snapshot.itemLink or current.itemLink
			current.itemRarity = snapshot.itemRarity or current.itemRarity
			current.itemTexture = snapshot.itemTexture or current.itemTexture or C.RESERVES_ITEM_FALLBACK_ICON
			current.itemColor = resolveItemColor(current.itemLink, current.itemRarity, current.itemColor)
			current.autoLootSuggestion = evaluateAutoLootSuggestion(current.itemLink, current.itemRarity, true)

			if index == lootState.currentItemIndex then
				setSelectedItem(current)
			end
		end)

		if handle then
			item._itemInfoRequest = handle
			return true
		end
		return false
	end

	local function resolveRollSessionIdForLoot(itemLink, itemString, itemId)
		local session = lootState.rollSession
		if type(session) ~= "table" then
			return nil
		end
		local sessionId = session.id
		if not sessionId or sessionId == "" then
			return nil
		end

		local sessionItemId = tonumber(session.itemId)
		local parsedItemId = tonumber(itemId)
		if sessionItemId and parsedItemId and sessionItemId == parsedItemId then
			return tostring(sessionId)
		end

		local sessionKey = session.itemKey
		if sessionKey and itemString and sessionKey == itemString then
			return tostring(sessionId)
		end
		if sessionKey and itemLink and sessionKey == itemLink then
			return tostring(sessionId)
		end
		return nil
	end

	local function bindLootNidToRollSession(lootNid, rollSessionId, itemId, itemString, itemLink)
		local resolvedLootNid = tonumber(lootNid)
		local session = lootState.rollSession
		if not resolvedLootNid or resolvedLootNid <= 0 or type(session) ~= "table" then
			return
		end

		local sessionId = session.id and tostring(session.id) or nil
		local matchedSessionId = rollSessionId and tostring(rollSessionId) or nil
		if not matchedSessionId then
			matchedSessionId = resolveRollSessionIdForLoot(itemLink, itemString, itemId)
		end
		if not sessionId or matchedSessionId ~= sessionId then
			return
		end

		session.lootNid = resolvedLootNid
		lootState.currentRollItem = resolvedLootNid
	end

	local function indexAppendedLootRuntime(raid, lootInfo, index)
		return Database.GetRaidStore():UpsertLootIndex(raid, lootInfo, index)
	end

	local function getLootItemKey(loot)
		if type(loot) ~= "table" then
			return nil
		end
		if type(loot.itemString) == "string" and loot.itemString ~= "" then
			return loot.itemString
		end
		return PassiveGroupLoot.GetPassiveLootRollItemKey(loot.itemLink)
	end

	local function getCurrentRaidRetryIdentity()
		local raidNum = Database.GetCurrentRaid()
		if raidNum == nil or type(Database.EnsureRaidByIndex) ~= "function" then
			return nil
		end
		local raid = Database.EnsureRaidByIndex(raidNum)
		local raidStore = Database.GetRaidStore()
		local raidUid = raidStore and raidStore.GetRaidUid and raidStore:GetRaidUid(raid) or nil
		if not raidUid then
			return nil
		end
		return raidNum, raidUid, raid
	end

	local function getActiveRaidRecoveryIdentity()
		local raidStore = Database.GetRaidStore()
		if not (raidStore and type(raidStore.GetActiveRecord) == "function") then
			return nil
		end
		local record = raidStore:GetActiveRecord()
		local raid = type(record) == "table" and record.state or nil
		local raidUid = record and record.raidUid or nil
		if type(raid) ~= "table" or not raidUid then
			return nil
		end
		return Database.GetCurrentRaid(), raidUid, raid
	end

	local function isAuthorityRecovering(raidUid)
		local syncer = addon.DB and addon.DB.Syncer
		return raidUid ~= nil
			and syncer ~= nil
			and type(syncer.IsAuthorityRecovering) == "function"
			and syncer:IsAuthorityRecovering(raidUid) == true
	end

	local function copyParsedGroupLootFact(parsedGroupLoot)
		if type(parsedGroupLoot) ~= "table" then
			return nil
		end
		local copy = {}
		if
			parsedGroupLoot.kind == "selection"
			or parsedGroupLoot.kind == "roll"
			or parsedGroupLoot.kind == "winner"
		then
			copy.kind = parsedGroupLoot.kind
		end
		if type(parsedGroupLoot.msg) == "string" then
			copy.msg = parsedGroupLoot.msg
		end
		if type(parsedGroupLoot.playerName) == "string" then
			copy.playerName = parsedGroupLoot.playerName
		end
		if type(parsedGroupLoot.itemLink) == "string" then
			copy.itemLink = parsedGroupLoot.itemLink
		end
		if type(parsedGroupLoot.sessionId) == "string" then
			copy.sessionId = parsedGroupLoot.sessionId
		end
		copy.rollType = tonumber(parsedGroupLoot.rollType)
		copy.rollValue = tonumber(parsedGroupLoot.rollValue)
		copy.rollId = tonumber(parsedGroupLoot.rollId)
		copy.itemCount = tonumber(parsedGroupLoot.itemCount) or 1
		copy.isPassiveWinner = parsedGroupLoot.isPassiveWinner == true or copy.kind == "winner"
		return copy
	end

	local function buildAuthorityRecoveryLootIdentity(raidUid, msg, parsedGroupLoot, observedAt)
		local parsed = type(parsedGroupLoot) == "table" and parsedGroupLoot or nil
		local sessionId = parsed and (parsed.sessionId or parsed.rollSessionId) or nil
		local rollId = parsed and parsed.rollId or nil
		local kind = parsed and parsed.kind or nil
		local looter = parsed and (parsed.playerName or parsed.looter or parsed.winnerName) or nil
		local itemLink = parsed and parsed.itemLink or nil
		sessionId = sessionId and tostring(sessionId) or nil
		rollId = rollId and tostring(rollId) or nil
		looter = NormalizeName(looter, true) or looter
		local itemKey = itemLink and PassiveGroupLoot.GetPassiveLootRollItemKey(itemLink) or nil
		if sessionId or rollId then
			local key = tconcat({
				tostring(raidUid),
				"kind=" .. tostring(kind or ""),
				"session=" .. tostring(sessionId or ""),
				"roll=" .. tostring(rollId or ""),
				"looter=" .. tostring(looter or ""),
				"item=" .. tostring(itemKey or itemLink or ""),
			}, "\031")
			return key,
				{
					kind = kind,
					sessionId = sessionId,
					rollId = rollId,
					looter = looter,
					itemKey = itemKey or itemLink,
				}
		end

		local bucket = math.floor((tonumber(observedAt) or 0) / GROUP_LOOT_PENDING_AWARD_TTL_SECONDS)
		return tconcat({
			tostring(raidUid),
			"kind=" .. tostring(kind or ""),
			"msg=" .. tostring(msg),
			"bucket=" .. tostring(bucket),
		}, "\031"),
			{
				kind = kind,
				msg = msg,
			}
	end

	local function removeAuthorityRecoveryLootFact(index)
		local fact = authorityRecoveryLootFacts[index]
		if fact then
			authorityRecoveryLootFactKeys[fact.key] = nil
			table.remove(authorityRecoveryLootFacts, index)
		end
	end

	local function queueAuthorityRecoveryLootFact(raidUid, msg, rollType, rollValue, parsedGroupLoot, winnerOnly)
		local observedAt = Time.GetCurrentTime()
		local parsedCopy = copyParsedGroupLootFact(parsedGroupLoot)
		local key, identity = buildAuthorityRecoveryLootIdentity(raidUid, msg, parsedCopy, observedAt)
		if authorityRecoveryLootFactKeys[key] then
			return true
		end
		if #authorityRecoveryLootFacts >= GROUP_LOOT_RECOVERY_FACT_LIMIT then
			removeAuthorityRecoveryLootFact(1)
		end

		local fact = {
			key = key,
			identity = identity,
			raidUid = raidUid,
			msg = msg,
			rollType = rollType,
			rollValue = rollValue,
			parsedGroupLoot = parsedCopy,
			winnerOnly = winnerOnly == true,
			observedAt = observedAt,
			expiresAt = GetTime() + GROUP_LOOT_PENDING_AWARD_TTL_SECONDS,
		}
		authorityRecoveryLootFacts[#authorityRecoveryLootFacts + 1] = fact
		authorityRecoveryLootFactKeys[key] = fact
		return true
	end

	local function resolveRecoveryFactSessionId(identity)
		if identity.sessionId then
			return identity.sessionId
		end
		if identity.rollId and type(PassiveGroupLoot.GetPassiveLootRollEntryByRollId) == "function" then
			local passiveRoll = PassiveGroupLoot.GetPassiveLootRollEntryByRollId(identity.rollId)
			return passiveRoll and passiveRoll.sessionId and tostring(passiveRoll.sessionId) or nil
		end
		return nil
	end

	local function hasCanonicalAuthorityRecoveryLoot(raid, fact)
		local identity = fact.identity or {}
		local sessionId = resolveRecoveryFactSessionId(identity)
		if not sessionId or not identity.itemKey or not identity.looter then
			return false
		end
		for i = 1, #(raid.loot or {}) do
			local loot = raid.loot[i]
			local looter = NormalizeName(resolveStoredLootLooterName(raid, loot), true)
			if
				tostring(loot.rollSessionId or "") == sessionId
				and getLootItemKey(loot) == identity.itemKey
				and looter == identity.looter
			then
				return true
			end
		end
		return false
	end

	local function findUpgradeablePassiveLootEntry(raid, raidNum, itemLink, looter, rollSessionId)
		if type(raid) ~= "table" or not itemLink or not looter then
			return nil
		end

		local targetItemKey = PassiveGroupLoot.GetPassiveLootRollItemKey(itemLink)
		local targetLooter = NormalizeName(looter, true) or looter
		local targetSessionId = rollSessionId and tostring(rollSessionId) or nil
		local currentTime = tonumber(Time.GetCurrentTime()) or 0
		local uniqueMatch = nil
		local sessionlessMatch = nil
		local lootList = raid.loot or {}

		for i = #lootList, 1, -1 do
			local loot = lootList[i]
			local lootTime = tonumber(loot and loot.time) or 0
			if currentTime > 0 and lootTime > 0 and (currentTime - lootTime) > GROUP_LOOT_PENDING_AWARD_TTL_SECONDS then
				break
			end

			if loot and getLootItemKey(loot) == targetItemKey then
				local lootLooter = resolveStoredLootLooterName(raid, loot)
				if lootLooter == targetLooter and (tonumber(loot.rollValue) or 0) <= 0 then
					local lootSessionId = loot.rollSessionId and tostring(loot.rollSessionId) or nil
					if targetSessionId and targetSessionId ~= "" then
						if lootSessionId == targetSessionId then
							return loot
						end
						if not lootSessionId or lootSessionId == "" then
							if sessionlessMatch then
								sessionlessMatch = false
							else
								sessionlessMatch = loot
							end
						end
					else
						if uniqueMatch then
							return nil
						end
						uniqueMatch = loot
					end
				end
			end
		end

		if targetSessionId and type(sessionlessMatch) == "table" then
			return sessionlessMatch
		end

		return uniqueMatch
	end

	local function addLootWindowSlot(indexByItemKey, slot)
		if not LootSlotIsItem(slot) then
			return
		end

		local itemLink = GetLootSlotLink(slot)
		if not itemLink or GetItemFamily(itemLink) == 64 then
			return
		end

		local key = Item.GetItemStringFromLink(itemLink) or itemLink
		local existing = indexByItemKey[key]
		if existing then
			lootTable[existing].count = (lootTable[existing].count or 1) + 1
			return
		end

		local icon, name, _, quality = GetLootSlotInfo(slot)
		local before = lootState.lootCount
		module:AddItem(itemLink, 1, name, quality, icon)
		if lootState.lootCount > before then
			indexByItemKey[key] = lootState.lootCount
			local item = lootTable[lootState.lootCount]
			if item then
				item.itemKey = key
			end
		end
	end

	local function findTrackedLootItemIndex(itemLink)
		if not itemLink then
			return nil
		end

		for i = 1, lootState.lootCount do
			local item = lootTable[i]
			if item and item.itemLink == itemLink then
				return i
			end
		end
		return nil
	end

	local function isParsedGroupLootResult(parsedGroupLoot, msg, kind)
		if type(parsedGroupLoot) ~= "table" then
			return false
		end
		if parsedGroupLoot.msg ~= msg then
			return false
		end
		if kind and parsedGroupLoot.kind ~= kind then
			return false
		end
		return true
	end

	local function parseLootChatMessage(msg, rollType, rollValue, parsedGroupLoot)
		-- Parse loot chat variants ("receives loot" and "receives item").
		local player, itemLink, count = Deformat(msg, LOOT_ITEM_MULTIPLE)
		local itemCount = count or 1

		if not player then
			player, itemLink = Deformat(msg, LOOT_ITEM)
			itemCount = 1
		end

		-- Self loot path (no player name in the string).
		if not itemLink then
			local link
			link, count = Deformat(msg, LOOT_ITEM_SELF_MULTIPLE)
			if link then
				itemLink = link
				itemCount = count or 1
				player = Database.GetPlayerName()
			end
		end

		if not itemLink then
			local link = Deformat(msg, LOOT_ITEM_SELF)
			if link then
				itemLink = link
				itemCount = 1
				player = Database.GetPlayerName()
			end
		end

		-- Fallback for alternate loot-roll chat formats.
		if not player or not itemLink then
			if isParsedGroupLootResult(parsedGroupLoot, msg, "winner") and parsedGroupLoot.itemLink then
				player = parsedGroupLoot.playerName
				itemLink = parsedGroupLoot.itemLink
				itemCount = tonumber(parsedGroupLoot.itemCount) or 1
				rollType = rollType or parsedGroupLoot.rollType
				if rollValue == nil then
					rollValue = parsedGroupLoot.rollValue
				end
			else
				local resolvedRollType, resolvedRollValue
				player, itemLink, resolvedRollType, resolvedRollValue = PassiveGroupLoot.ParseGroupLootWinner(msg)
				if itemLink then
					itemCount = 1
					rollType = rollType or resolvedRollType
					if rollValue == nil then
						rollValue = resolvedRollValue
					end
				end
			end
		end

		if not itemLink then
			return nil, nil, nil, rollType, rollValue
		end

		return NormalizeName(player, true) or player, tonumber(itemCount) or 1, itemLink, rollType, rollValue
	end

	local function getLootItemDetails(itemLink)
		local itemString = Item.GetItemStringFromLink(itemLink)
		local itemName, _, itemRarity, _, _, itemType, _, _, _, itemTexture = GetItemInfo(itemLink)
		local itemId = Item.GetItemIdFromLink(itemLink)
		return itemString, itemName, itemRarity, itemTexture, tonumber(itemId), itemType
	end

	local normalizeLoggerLootQualityThreshold = assert(
		Options.NormalizeLoggerLootQualityThreshold,
		Diag.A.LootLoggerQualityThresholdNormalizerNotInitialized
	)

	local function getRaidLootThreshold()
		return normalizeLoggerLootQualityThreshold(GetLootThreshold())
	end

	local function getEffectiveLoggerLootThreshold()
		if GetOption("Logger", "ignoreSelectionThreshold") == true then
			return normalizeLoggerLootQualityThreshold(GetOption("Logger", "loggerLootQualityThreshold"))
		end
		return getRaidLootThreshold()
	end

	local function shouldSkipLootEntry(itemRarity, itemId, itemLink)
		-- Ignore low-rarity and explicitly ignored items.
		local lootThreshold = getEffectiveLoggerLootThreshold()
		local rarity = tonumber(itemRarity)
		if rarity and rarity < lootThreshold then
			if addon.hasDebug then
				addon:debug(
					Diag.D.LogLootIgnoredBelowThreshold:format(
						tostring(rarity),
						tonumber(lootThreshold) or -1,
						tostring(itemLink)
					)
				)
			end
			return true
		end
		if itemId and isIgnoredItem(itemId) then
			if addon.hasDebug then
				addon:debug(Diag.D.LogLootIgnoredItemId:format(tostring(itemId), tostring(itemLink)))
			end
			return true
		end
		return false
	end

	local function normalizeItemClass(value)
		return Strings.NormalizeLower(value, true) or ""
	end

	local function itemClassMatches(itemType, globalKey, fallback)
		local className = normalizeItemClass(itemType)
		if className == "" then
			return false
		end

		local globalName = normalizeItemClass(_G[globalKey])
		return className == fallback or (globalName ~= "" and className == globalName)
	end

	local function isUncommonItem(itemRarity, itemLink)
		if tonumber(itemRarity) == UNCOMMON_ITEM_RARITY then
			return true
		end

		local color = type(itemLink) == "string" and itemLink:match("|c(%x%x%x%x%x%x%x%x)|Hitem:") or nil
		return color and strlower(color) == UNCOMMON_ITEM_LINK_COLOR
	end

	local function shouldSkipPassiveGroupLootEntry(itemRarity, itemType, itemLink)
		return isUncommonItem(itemRarity, itemLink)
			or itemClassMatches(itemType, "ITEM_CLASS_GEM", "gem")
			or itemClassMatches(itemType, "ITEM_CLASS_RECIPE", "recipe")
	end

	local function shouldSkipPassiveGroupLootCounter(rollType)
		local resolvedRollType = tonumber(rollType)
		return resolvedRollType == rollTypes.NEED
			or resolvedRollType == rollTypes.GREED
			or resolvedRollType == rollTypes.DISENCHANT
	end

	evaluateAutoLootSuggestion = function(itemLink, itemRarity, allowExpensiveMetadata)
		local opts
		if allowExpensiveMetadata == false then
			opts = CHEAP_SUGGESTION_OPTS
		end
		return Rules:GetItemSuggestion({
			itemId = Item.GetItemIdFromLink(itemLink),
			itemLink = itemLink,
			itemRarity = itemRarity,
		}, opts)
	end

	local function suggestionsMatch(a, b)
		if a == b then
			return true
		end
		if type(a) ~= "table" or type(b) ~= "table" then
			return false
		end
		return a.action == b.action
			and a.reason == b.reason
			and a.rollType == b.rollType
			and a.targetKey == b.targetKey
			and a.skipLogger == b.skipLogger
	end

	refreshDeferredAutoLootSuggestion = function(itemLink)
		if type(itemLink) ~= "string" or itemLink == "" then
			return
		end

		local itemKey = Item.GetItemStringFromLink(itemLink) or itemLink
		local selectedUpdated = false
		for i = 1, lootState.lootCount do
			local item = lootTable[i]
			if item and (item.itemLink == itemLink or item.itemKey == itemKey) then
				local suggestion = evaluateAutoLootSuggestion(item.itemLink, item.itemRarity, true)
				if not suggestionsMatch(item.autoLootSuggestion, suggestion) then
					item.autoLootSuggestion = suggestion
					if i == lootState.currentItemIndex then
						selectedUpdated = true
					end
				end
			end
		end

		if selectedUpdated then
			setSelectedItem(lootTable[lootState.currentItemIndex])
		end
	end

	local function resolveLootRollOutcome(itemLink, itemString, itemId, player, rollType, rollValue, parsedGroupLoot)
		local passiveGroupLoot = PassiveGroupLoot.IsPassiveGroupLootMethod()
		local preferredRollSessionId = nil
		if passiveGroupLoot and type(parsedGroupLoot) == "table" then
			preferredRollSessionId = parsedGroupLoot.sessionId and tostring(parsedGroupLoot.sessionId) or nil
		elseif not passiveGroupLoot then
			preferredRollSessionId = resolveRollSessionIdForLoot(itemLink, itemString, itemId)
		end

		local rollSessionId
		local outcome = {
			consumedPendingAward = false,
			matchedPassiveRoll = false,
			pendingCounterApplied = false,
		}
		local pendingAwardTtl = passiveGroupLoot and GROUP_LOOT_PENDING_AWARD_TTL_SECONDS or PENDING_AWARD_TTL_SECONDS
		-- In ML mode, block stale GL:* pending awards only when the current item
		-- maps to an active roll session. Without a preferred session, keep GL
		-- pending lookup enabled to preserve passive Group Loot logging in mixed
		-- transition windows (Group Loot -> ML).
		local allowGroupLootPendingAwards = passiveGroupLoot or not preferredRollSessionId
		local pendingAward = LootAttribution.Prepare(
			itemLink,
			player,
			pendingAwardTtl,
			preferredRollSessionId,
			passiveGroupLoot,
			allowGroupLootPendingAwards
		)
		if pendingAward then
			outcome.pendingAward = pendingAward
			if not rollType then
				rollType = pendingAward.rollType
			end
			if rollValue == nil then
				rollValue = pendingAward.rollValue
			elseif passiveGroupLoot then
				local currentRollValue = tonumber(rollValue) or 0
				local pendingRollValue = tonumber(pendingAward.rollValue) or 0
				if currentRollValue <= 0 and pendingRollValue > 0 then
					rollValue = pendingAward.rollValue
				end
			end
			if rollValue == nil then
				rollValue = pendingAward.rollValue
			end
			rollSessionId = pendingAward.rollSessionId and tostring(pendingAward.rollSessionId) or nil
			outcome.consumedPendingAward = true
			outcome.pendingCounterApplied = pendingAward.counterApplied == true
		end

		if not rollSessionId then
			if passiveGroupLoot then
				local passiveRoll = parsedGroupLoot
						and parsedGroupLoot.rollId
						and PassiveGroupLoot.GetPassiveLootRollEntryByRollId(parsedGroupLoot.rollId)
					or PassiveGroupLoot.GetPassiveLootRollEntry(itemLink)
				rollSessionId = passiveRoll and passiveRoll.sessionId or nil
				outcome.matchedPassiveRoll = passiveRoll ~= nil
				if passiveRoll then
					local winner = type(passiveRoll.winner) == "table" and passiveRoll.winner or nil
					local winnerName = winner and NormalizeName(winner.playerName, true) or nil
					local playerName = NormalizeName(player, true) or player
					local winnerMatches = winner and (not winnerName or not playerName or winnerName == playerName)
					if winnerMatches then
						if not rollType then
							rollType = winner.rollType
						end
						if rollValue == nil then
							rollValue = winner.rollValue
						end
					end

					local rollsByPlayer = type(passiveRoll.rollsByPlayer) == "table" and passiveRoll.rollsByPlayer
						or nil
					local playerRoll
					if rollsByPlayer then
						if playerName then
							playerRoll = rollsByPlayer[playerName]
						end
						if not playerRoll and player then
							playerRoll = rollsByPlayer[player]
						end
					end
					if type(playerRoll) == "table" then
						if not rollType then
							rollType = playerRoll.rollType
						end
						local currentRollValue = tonumber(rollValue) or 0
						local playerRollValue = tonumber(playerRoll.rollValue) or 0
						if rollValue == nil or (currentRollValue <= 0 and playerRollValue > 0) then
							rollValue = playerRoll.rollValue
						end
					end

					local choicesByPlayer = type(passiveRoll.choicesByPlayer) == "table" and passiveRoll.choicesByPlayer
						or nil
					local playerChoice
					if choicesByPlayer then
						if playerName then
							playerChoice = choicesByPlayer[playerName]
						end
						if not playerChoice and player then
							playerChoice = choicesByPlayer[player]
						end
					end
					if type(playerChoice) == "table" and not rollType then
						rollType = playerChoice.rollType
					end
				end
			else
				rollSessionId = preferredRollSessionId
			end
		end

		-- Resolve award source: pending award/group-loot choice -> manual ML tag -> current roll type.
		if not rollType then
			if passiveGroupLoot then
				rollValue = rollValue or 0
			else
				local raidService = Services.Raid
				local isMasterLooter = raidService and raidService:IsMasterLooter()
				if isMasterLooter and not lootState.fromInventory then
					rollType = rollTypes.MANUAL
					rollValue = 0

					-- Debug marker for manual-tagged loot.
					if addon.hasDebug then
						addon:debug(
							Diag.D.LogLootTaggedManual,
							tostring(itemLink),
							tostring(player),
							tostring(lootState.currentRollType)
						)
					end
				else
					rollType = lootState.currentRollType
				end
			end
		end

		if not rollSessionId then
			rollSessionId = resolveRollSessionIdForLoot(itemLink, itemString, itemId)
		end

		if not rollValue then
			if passiveGroupLoot then
				rollValue = 0
			else
				local services = Services
				local rollsService = services and services.Rolls or nil
				rollValue = rollsService and rollsService:GetHighestRoll() or 0
			end
		end

		return rollType, rollValue, rollSessionId, outcome
	end

	local function resolveBossNidForLoot(raid, raidNum, rollSessionId, passiveGroupLoot, now, itemId)
		local raidService = Services.Raid
		if not raidService then
			return 0
		end
		local ttlSeconds = passiveGroupLoot and GROUP_LOOT_PENDING_AWARD_TTL_SECONDS or BOSS_EVENT_CONTEXT_TTL_SECONDS
		local allowLootWindowContext = lootState.opened == true and lootState.fromInventory ~= true
		return tonumber(raidService:FindOrCreateBossNidForLoot(raid, raidNum, rollSessionId, {
			now = tonumber(now) or Time.GetCurrentTime(),
			itemId = itemId,
			allowContextRecovery = not passiveGroupLoot,
			allowContextFallback = not passiveGroupLoot,
			allowLootWindowContext = allowLootWindowContext and not passiveGroupLoot,
			allowTrashFallback = not passiveGroupLoot,
			ttlSeconds = ttlSeconds,
		})) or 0
	end

	local function copyLootSourceForRecord(raidService, raidNum, bossNid)
		if not (raidService and raidService.GetActiveLootSource) then
			return nil
		end
		return raidService:GetActiveLootSource(raidNum, bossNid)
	end

	local function buildLootRecord(
		raid,
		itemId,
		itemName,
		itemString,
		itemLink,
		itemRarity,
		itemTexture,
		itemCount,
		looterNid,
		rollType,
		rollValue,
		rollSessionId,
		bossNid,
		lootSource
	)
		return Recording.Build(raid, {
			itemId = itemId,
			itemName = itemName,
			itemString = itemString,
			itemLink = itemLink,
			itemRarity = itemRarity,
			itemTexture = itemTexture,
			itemCount = itemCount,
			looterNid = looterNid,
			rollType = rollType,
			rollValue = rollValue,
			rollSessionId = rollSessionId,
			bossNid = bossNid,
			source = "CHAT_MSG_LOOT",
			lootSource = lootSource,
		})
	end

	local function appendLootRecord(raid, raidNum, lootInfo, options)
		if not (raid and lootInfo) then
			return nil, 0
		end
		options = options or {}
		local appended, lootNid, index = Recording.Append(raid, lootInfo)
		if not appended then
			return nil, 0
		end
		local itemLink = appended.itemLink
		local raidService = options.raidService
		if
			options.consumeLootWindow
			and lootState.opened == true
			and lootState.fromInventory ~= true
			and raidService
			and raidService.ConsumeLootWindowItemContext
		then
			raidService:ConsumeLootWindowItemContext(itemLink)
		end
		indexAppendedLootRuntime(raid, appended, index or #raid.loot)
		bindLootNidToRollSession(lootNid, appended.rollSessionId, appended.itemId, appended.itemString, itemLink)
		if options.consumePassiveRoll then
			PassiveGroupLoot.ConsumePassiveLootRollEntry(appended.rollSessionId)
		end
		notifyRaidLootUpdate(raidNum, appended)
		return appended, lootNid
	end

	local function commitPreparedPendingAward(rollOutcome)
		local pendingAward = rollOutcome and rollOutcome.pendingAward or nil
		if pendingAward then
			LootAttribution.CommitPrepared(pendingAward)
		end
	end

	local function commitTerminalPassiveOutcome(rollOutcome, rollSessionId)
		commitPreparedPendingAward(rollOutcome)
		PassiveGroupLoot.ConsumePassiveLootRollEntry(rollSessionId)
	end

	setSelectedItem = function(i)
		if not i then
			notifySelectedItem(nil, nil)
			return
		end
		if not (i.itemName and i.itemLink and i.itemTexture and i.itemColor) then
			return
		end
		Workflow.SelectItem(workflowContext, i)
		notifySelectedItem(i.itemLink, i)
	end

	-- ----- Public methods ----- --

	function module:UpgradeLoggedPassiveLootRoll(itemLink, looter, rollType, rollValue, rollSessionId)
		local resolvedRollType = tonumber(rollType) or rollType
		local resolvedRollValue = tonumber(rollValue) or 0
		local hasRollType = resolvedRollType ~= nil
		local hasRollValue = resolvedRollValue > 0
		local currentRaidId, raid = resolveRaidRecord()
		if (not hasRollType and not hasRollValue) or not currentRaidId then
			return false
		end

		if not raid then
			return false
		end

		local loot = findUpgradeablePassiveLootEntry(raid, currentRaidId, itemLink, looter, rollSessionId)
		if not loot then
			return false
		end

		local updated = Recording.Copy(loot)
		local changed = false
		if hasRollType and updated.rollType ~= resolvedRollType then
			updated.rollType = resolvedRollType
			changed = true
		end
		if (hasRollValue or (tonumber(updated.rollValue) or 0) <= 0) and updated.rollValue ~= resolvedRollValue then
			updated.rollValue = resolvedRollValue
			changed = true
		end
		if rollSessionId and (not updated.rollSessionId or updated.rollSessionId == "") then
			updated.rollSessionId = tostring(rollSessionId)
			changed = true
		end
		if not changed then
			return false
		end

		local _, committed = Recording.MarkUpdated(raid, updated, "passive_roll")
		if not committed then
			return false
		end
		bindLootNidToRollSession(
			committed.lootNid,
			committed.rollSessionId,
			committed.itemId,
			committed.itemString,
			committed.itemLink
		)
		notifyRaidLootUpdate(currentRaidId, committed)
		return true
	end

	local function applyAuthoritativeProvisional(award, authoritative)
		local _, raid = resolveRaidRecord()
		if not (raid and type(raid.loot) == "table") then
			return
		end
		for i = 1, #raid.loot do
			local row = raid.loot[i]
			if row and tonumber(row.lootNid) == tonumber(award.recordIndex) then
				local updated = Recording.Copy(row)
				local changed = updated.source ~= "CHAT_MSG_LOOT"
				updated.source = "CHAT_MSG_LOOT"
				if type(authoritative) == "table" then
					local itemCount = tonumber(authoritative.itemCount) or updated.itemCount
					local itemName = authoritative.itemName or updated.itemName
					local itemRarity = authoritative.itemRarity or updated.itemRarity
					local itemTexture = authoritative.itemTexture or updated.itemTexture
					local itemString = authoritative.itemString or updated.itemString
					changed = changed
						or updated.itemCount ~= itemCount
						or updated.itemName ~= itemName
						or updated.itemRarity ~= itemRarity
						or updated.itemTexture ~= itemTexture
						or updated.itemString ~= itemString
					updated.itemCount = itemCount
					updated.itemName = itemName
					updated.itemRarity = itemRarity
					updated.itemTexture = itemTexture
					updated.itemString = itemString
				end
				if changed then
					local _, committed = Recording.MarkUpdated(raid, updated, "authoritative_loot")
					if committed then
						notifyRaidLootUpdate(Database.GetCurrentRaid(), committed)
					end
				end
				return
			end
		end
	end

	function module:ReplayAuthorityRecoveryFacts(raidUid)
		local _, currentRaidUid, raid = getCurrentRaidRetryIdentity()
		if currentRaidUid ~= raidUid or type(raid) ~= "table" or isAuthorityRecovering(raidUid) then
			return false
		end

		local currentTime = GetTime()
		local index = 1
		while index <= #authorityRecoveryLootFacts do
			local fact = authorityRecoveryLootFacts[index]
			if fact.raidUid ~= raidUid or currentTime >= (tonumber(fact.expiresAt) or 0) then
				removeAuthorityRecoveryLootFact(index)
			elseif hasCanonicalAuthorityRecoveryLoot(raid, fact) then
				removeAuthorityRecoveryLootFact(index)
			else
				local previousLootCount = #(raid.loot or {})
				local _, _, handled = self:HandleLootChatMessage(fact.msg, fact.winnerOnly, fact.parsedGroupLoot)
				local _, replayRaidUid, replayRaid = getCurrentRaidRetryIdentity()
				local consumed = replayRaidUid == raidUid
					and type(replayRaid) == "table"
					and (
						#(replayRaid.loot or {}) > previousLootCount
						or hasCanonicalAuthorityRecoveryLoot(replayRaid, fact)
						or handled == true
					)
				if consumed then
					raid = replayRaid
					removeAuthorityRecoveryLootFact(index)
				else
					index = index + 1
				end
			end
		end
		return true
	end

	-- Adds a loot item to the active raid log.
	function module:AddLoot(msg, rollType, rollValue, parsedGroupLoot)
		local _, recoveryRaidUid = getActiveRaidRecoveryIdentity()
		if recoveryRaidUid and isAuthorityRecovering(recoveryRaidUid) then
			queueAuthorityRecoveryLootFact(recoveryRaidUid, msg, rollType, rollValue, parsedGroupLoot)
			return
		end

		local player
		local itemCount
		local itemLink
		player, itemCount, itemLink, rollType, rollValue =
			parseLootChatMessage(msg, rollType, rollValue, parsedGroupLoot)
		if not itemLink then
			Workflow.RecordReceipt(
				workflowContext,
				Recording.FromParsedLoot({
					msg = msg,
				})
			)
			if addon.hasDebug then
				addon:debug(Diag.D.LogLootParseFailed:format(tostring(msg)))
			end
			return
		end

		local itemString, itemName, itemRarity, itemTexture, itemId, itemType = getLootItemDetails(itemLink)
		if addon.hasTrace then
			addon:trace(Diag.D.LogLootParsed:format(tostring(player), tostring(itemLink), itemCount))
		end

		if shouldSkipLootEntry(itemRarity, itemId, itemLink) then
			return
		end
		raidState.lastLootCount = itemCount

		local currentRaidId, raid = resolveRaidRecord()
		if not raid then
			return
		end

		local passiveGroupLoot = PassiveGroupLoot.IsPassiveGroupLootMethod()
		local isPassiveWinnerMessage = isParsedGroupLootResult(parsedGroupLoot, msg, "winner")
			or PassiveGroupLoot.IsPassiveLootWinnerMessage(msg)
		local authoritative = {
			itemCount = itemCount,
			itemName = itemName,
			itemRarity = itemRarity,
			itemTexture = itemTexture,
			itemString = itemString,
		}
		if
			not passiveGroupLoot
			and LootAttribution.StageAuthoritative(itemLink, player, authoritative, applyAuthoritativeProvisional)
		then
			return
		end
		local rollSessionId
		local rollOutcome
		rollType, rollValue, rollSessionId, rollOutcome =
			resolveLootRollOutcome(itemLink, itemString, itemId, player, rollType, rollValue, parsedGroupLoot)
		if
			module:ReconcileProvisionalAward(itemLink, player, rollSessionId, {
				itemCount = itemCount,
				itemName = itemName,
				itemRarity = itemRarity,
				itemTexture = itemTexture,
				itemString = itemString,
			})
		then
			return
		end
		local receipt = Recording.FromParsedLoot({
			msg = msg,
			playerName = player,
			itemLink = itemLink,
			itemString = itemString,
			itemCount = itemCount,
			itemId = itemId,
			itemName = itemName,
			itemRarity = itemRarity,
			itemTexture = itemTexture,
			itemType = itemType,
			rollType = rollType,
			rollValue = rollValue,
			rollSessionId = rollSessionId,
			passiveGroupLoot = passiveGroupLoot,
			parsedGroupLoot = parsedGroupLoot,
		})
		if not Recording.ShouldCreateRecord(receipt) then
			Workflow.RecordReceipt(workflowContext, receipt)
			return
		end

		if passiveGroupLoot and shouldSkipPassiveGroupLootEntry(itemRarity, itemType, itemLink) then
			commitTerminalPassiveOutcome(rollOutcome, rollSessionId)
			return true, "ignored_passive_item"
		end

		if
			Recording.ShouldSkipPassiveDuplicate({
				PassiveGroupLoot = PassiveGroupLoot,
				passiveGroupLoot = passiveGroupLoot,
				rollOutcome = rollOutcome,
				isPassiveWinnerMessage = isPassiveWinnerMessage,
				itemLink = itemLink,
				playerName = player,
				rollSessionId = rollSessionId,
			})
		then
			commitTerminalPassiveOutcome(rollOutcome, rollSessionId)
			return true, "passive_duplicate"
		end

		local raidService = Services.Raid
		local bossNid = 0
		local lootSource
		if isParsedGroupLootResult(parsedGroupLoot, msg, "winner") then
			bossNid = tonumber(parsedGroupLoot.bossNid) or 0
		end
		if bossNid <= 0 then
			local currentTime = Time.GetCurrentTime()
			bossNid = resolveBossNidForLoot(raid, currentRaidId, rollSessionId, passiveGroupLoot, currentTime, itemId)
		end
		if bossNid > 0 or not passiveGroupLoot then
			lootSource = copyLootSourceForRecord(raidService, currentRaidId, bossNid)
		end
		if bossNid <= 0 then
			if addon.hasDebug then
				addon:debug(Diag.D.LogBossNoContextTrash)
			end
		end

		local looterNid = 0
		if raidService then
			looterNid, player = raidService:EnsureRaidPlayerNid(player, currentRaidId)
		end

		local lootInfo = buildLootRecord(
			raid,
			itemId,
			itemName,
			itemString,
			itemLink,
			itemRarity,
			itemTexture,
			itemCount,
			looterNid,
			rollType,
			rollValue,
			rollSessionId,
			bossNid,
			lootSource
		)
		lootInfo.looter = player

		local authorityFallback, fallbackIndex = Recording.FindRecentAuthorityFallback(
			raid,
			lootInfo,
			passiveGroupLoot and GROUP_LOOT_PENDING_AWARD_TTL_SECONDS or PENDING_AWARD_TTL_SECONDS
		)
		if authorityFallback then
			local updated = Recording.Copy(authorityFallback)
			local _, changed = Recording.MergeTradeOnlyFallback(updated, lootInfo)
			changed = changed or (lootInfo.itemId ~= nil and updated.itemId ~= lootInfo.itemId)
			changed = changed or (lootInfo.itemName ~= nil and updated.itemName ~= lootInfo.itemName)
			changed = changed or (lootInfo.itemString ~= nil and updated.itemString ~= lootInfo.itemString)
			changed = changed or (lootInfo.itemLink ~= nil and updated.itemLink ~= lootInfo.itemLink)
			changed = changed or (lootInfo.itemRarity ~= nil and updated.itemRarity ~= lootInfo.itemRarity)
			changed = changed or (lootInfo.itemTexture ~= nil and updated.itemTexture ~= lootInfo.itemTexture)
			changed = changed or (updated.lootSource == nil and lootInfo.lootSource ~= nil)
			updated.itemId = lootInfo.itemId or updated.itemId
			updated.itemName = lootInfo.itemName or updated.itemName
			updated.itemString = lootInfo.itemString or updated.itemString
			updated.itemLink = lootInfo.itemLink or updated.itemLink
			updated.itemRarity = lootInfo.itemRarity or updated.itemRarity
			updated.itemTexture = lootInfo.itemTexture or updated.itemTexture
			if not updated.lootSource and lootInfo.lootSource then
				updated.lootSource = lootInfo.lootSource
			end

			local committed, committedRaid, committedIndex = authorityFallback, raid, fallbackIndex
			if changed then
				local _
				_, committed, committedRaid, committedIndex = Recording.MarkUpdated(raid, updated, "authority_receipt")
				if not committed then
					return false, "store_rejected"
				end
			end
			if
				lootState.opened == true
				and lootState.fromInventory ~= true
				and raidService
				and raidService.ConsumeLootWindowItemContext
			then
				raidService:ConsumeLootWindowItemContext(committed.itemLink)
			end
			indexAppendedLootRuntime(committedRaid, committed, committedIndex or fallbackIndex)
			bindLootNidToRollSession(
				committed.lootNid,
				committed.rollSessionId,
				committed.itemId,
				committed.itemString,
				committed.itemLink
			)
			PassiveGroupLoot.ConsumePassiveLootRollEntry(committed.rollSessionId)
			notifyRaidLootUpdate(currentRaidId, committed)
			commitPreparedPendingAward(rollOutcome)
			Workflow.RecordReceipt(workflowContext, receipt)
			Recording.MarkPassiveLogged({
				PassiveGroupLoot = PassiveGroupLoot,
				passiveGroupLoot = passiveGroupLoot,
				isPassiveWinnerMessage = isPassiveWinnerMessage,
				itemLink = committed.itemLink,
				playerName = player,
				rollSessionId = committed.rollSessionId,
			})
			return true, "reconciled"
		end

		lootInfo = appendLootRecord(raid, currentRaidId, lootInfo, {
			raidService = raidService,
			consumeLootWindow = true,
			consumePassiveRoll = true,
		})
		if not lootInfo then
			return false, "store_rejected"
		end

		commitPreparedPendingAward(rollOutcome)
		Workflow.RecordReceipt(workflowContext, receipt)

		-- LootCounter: passive/group loot credits on observed loot chat. Master-loot awards
		-- initiated by RMA may already be credited at GiveMasterLoot time because loot chat
		-- visibility is range-limited on 3.3.5 clients.
		if
			raidService
			and not (passiveGroupLoot and shouldSkipPassiveGroupLootCounter(rollType))
			and not (rollOutcome and rollOutcome.consumedPendingAward and rollOutcome.pendingCounterApplied == true)
		then
			raidService:AddPlayerCountForRollType(player, rollType, itemCount, currentRaidId)
		end

		Recording.MarkPassiveLogged({
			PassiveGroupLoot = PassiveGroupLoot,
			passiveGroupLoot = passiveGroupLoot,
			isPassiveWinnerMessage = isPassiveWinnerMessage,
			itemLink = itemLink,
			playerName = player,
			rollSessionId = rollSessionId,
		})
		if addon.hasDebug then
			addon:debug(
				Diag.D.LogLootLogged:format(
					tonumber(currentRaidId) or -1,
					tostring(itemId),
					tostring(lootInfo.bossNid),
					tostring(player)
				)
			)
		end
		return true, "recorded"
	end

	-- Creates a local raid loot entry for inventory-trade awards when no reliable loot context exists.
	function module:LogTradeOnlyLoot(
		itemLink,
		looter,
		rollType,
		rollValue,
		itemCount,
		source,
		raidNum,
		bossNid,
		rollSessionId
	)
		local resolvedRaidNum, raid = resolveRaidRecord(raidNum)
		raidNum = resolvedRaidNum
		if not raidNum or not itemLink or not looter or looter == "" then
			return 0, false
		end
		looter = NormalizeName(looter, true) or looter

		if not raid then
			return 0, false
		end

		local raidService = Services.Raid
		local looterNid = 0
		if raidService then
			looterNid, looter = raidService:EnsureRaidPlayerNid(looter, raidNum)
		end

		local count = tonumber(itemCount) or 1
		if count < 1 then
			count = 1
		end

		local itemString, itemName, itemRarity, itemTexture, itemId = getLootItemDetails(itemLink)
		if not itemName then
			itemName = strmatch(itemLink, "%[(.-)%]") or tostring(itemLink)
		end

		local currentTime = Time.GetCurrentTime()
		local resolvedBossNid = tonumber(bossNid) or 0
		if resolvedBossNid <= 0 and raidService then
			resolvedBossNid = raidService:FindOrCreateBossNidForLoot(raid, raidNum, rollSessionId, {
				now = currentTime,
				itemId = itemId,
				allowContextRecovery = false,
				allowTrashFallback = true,
				ttlSeconds = GROUP_LOOT_PENDING_AWARD_TTL_SECONDS,
			})
		end
		local lootSource = copyLootSourceForRecord(raidService, raidNum, resolvedBossNid)

		local lootInfo = {
			itemId = itemId,
			itemName = itemName,
			itemString = itemString,
			itemLink = itemLink,
			itemRarity = itemRarity,
			itemTexture = itemTexture,
			itemCount = count,
			looter = looter,
			looterNid = looterNid,
			rollType = tonumber(rollType),
			rollValue = tonumber(rollValue) or 0,
			rollSessionId = rollSessionId and tostring(rollSessionId) or nil,
			bossNid = resolvedBossNid,
			time = currentTime,
			source = source or "TRADE_ONLY",
			lootSource = lootSource,
		}

		local existing, existingIndex = Recording.FindTradeOnlyFallback(raid, lootInfo)
		if existing then
			local updated = Recording.Copy(existing)
			local _, changed = Recording.MergeTradeOnlyFallback(updated, lootInfo)
			local existingLootNid = tonumber(existing.lootNid) or 0
			if not changed then
				return existingLootNid, false
			end
			local _, committed, committedRaid, committedIndex = Recording.MarkUpdated(raid, updated, "trade_reconcile")
			if not committed then
				return 0, false
			end
			indexAppendedLootRuntime(committedRaid, committed, committedIndex or existingIndex)
			bindLootNidToRollSession(
				existingLootNid,
				committed.rollSessionId,
				committed.itemId,
				committed.itemString,
				committed.itemLink
			)
			notifyRaidLootUpdate(raidNum, committed)
			return existingLootNid, false
		end

		local appended, lootNid = appendLootRecord(raid, raidNum, lootInfo)
		if addon.hasDebug then
			addon:debug(
				Diag.D.LogLootTradeOnlyLogged:format(
					tonumber(raidNum) or -1,
					tostring(itemId),
					tostring(lootNid),
					tostring(looter),
					count,
					tostring(appended and appended.source or lootInfo.source)
				)
			)
		end
		return lootNid, lootNid > 0
	end

	-- ITEM_DONE is terminal on the wire. Keep a valid fact for two same-raid,
	-- one-shot retries while raid-leader and master-looter identity settles.
	local DISTRIBUTION_AWARD_RETRY_LIMIT = 2
	local DISTRIBUTION_AWARD_RETRY_DELAY_SECONDS = 1
	local distributionAwardRetries = {}

	local function normalizeDistributionAward(row, sessionId)
		if type(row) ~= "table" or type(row.sender) ~= "string" or row.sender == "" then
			return nil
		end
		local itemLink = row.itemLink or row.itemKey
		local winnerName = NormalizeName(row.winnerName, true)
		local rollType = tonumber(row.rollType)
		local count = tonumber(row.count) or 1
		local transactionId = type(row.reason) == "string" and strmatch(row.reason, "^master_loot:(.+)$") or nil
		local resolvedSessionId = sessionId and tostring(sessionId) or nil
		if
			type(itemLink) ~= "string"
			or itemLink == ""
			or not winnerName
			or not rollType
			or rollType ~= math.floor(rollType)
			or not transactionId
			or not resolvedSessionId
			or resolvedSessionId == ""
			or count < 1
			or count > 999999999
			or count ~= math.floor(count)
		then
			return nil
		end
		return {
			sender = row.sender,
			itemLink = itemLink,
			winnerName = winnerName,
			rollType = rollType,
			rollValue = row.rollValue,
			count = count,
			transactionId = transactionId,
			sessionId = resolvedSessionId,
			awardId = resolvedSessionId .. "|" .. transactionId,
		}
	end

	function module:RecordDistributionAward(row, sessionId, expectedRaidUid)
		local facts = normalizeDistributionAward(row, sessionId)
		if not facts then
			return false, "invalid_distribution_award", false
		end
		local raidNum
		local currentRaidUid
		if expectedRaidUid then
			raidNum, currentRaidUid = getCurrentRaidRetryIdentity()
			if currentRaidUid ~= expectedRaidUid then
				return false, "distribution_raid_changed", false, facts
			end
		else
			raidNum = Database.GetCurrentRaid()
			local identityRaidNum
			identityRaidNum, currentRaidUid = getCurrentRaidRetryIdentity()
			raidNum = raidNum or identityRaidNum
		end
		if isAuthorityRecovering(currentRaidUid) then
			return false, "distribution_authority_not_ready", true, facts
		end

		local raidService = Services.Raid
		if not raidService or not raidService.CanCommitRaidHistory or not raidService.IsLootAuthority then
			return false, "distribution_authority_unavailable", false, facts
		end
		if raidService:CanCommitRaidHistory() ~= true or raidService:IsLootAuthority(facts.sender) ~= true then
			local retryable = raidService.IsRaidLeader and raidService:IsRaidLeader() == true
			return false, "distribution_authority_not_ready", retryable, facts
		end
		local localPlayerName = Database.GetPlayerName and NormalizeName(Database.GetPlayerName(), true) or nil
		local distributionSender = NormalizeName(facts.sender, true)
		if
			raidService.IsRaidLeader
			and raidService:IsRaidLeader() == true
			and localPlayerName
			and distributionSender == localPlayerName
		then
			return true, nil, false, facts
		end
		local lootNid = self:LogTradeOnlyLoot(
			facts.itemLink,
			facts.winnerName,
			facts.rollType,
			facts.rollValue,
			facts.count,
			"DISTRIBUTION_AWARD",
			raidNum,
			nil,
			facts.awardId
		)
		if (tonumber(lootNid) or 0) <= 0 then
			return false, "distribution_record_failed", false, facts
		end
		return true, nil, false, facts
	end

	local function clearDistributionAwardRetry(awardId, cancelTimer)
		local entry = distributionAwardRetries[awardId]
		if not entry then
			return
		end
		distributionAwardRetries[awardId] = nil
		if cancelTimer and entry.handle then
			pcall(module.CancelTimer, module, entry.handle)
		end
		entry.handle = nil
	end

	local scheduleDistributionAwardRetry
	scheduleDistributionAwardRetry = function(entry)
		if entry.attempts >= DISTRIBUTION_AWARD_RETRY_LIMIT then
			clearDistributionAwardRetry(entry.awardId, false)
			return
		end
		entry.attempts = entry.attempts + 1
		local scheduled, handle = pcall(module.ScheduleTimer, module, function()
			entry.handle = nil
			if distributionAwardRetries[entry.awardId] ~= entry then
				return
			end
			local _, currentRaidUid = getCurrentRaidRetryIdentity()
			if currentRaidUid ~= entry.raidUid then
				clearDistributionAwardRetry(entry.awardId, false)
				return
			end
			local recorded, _, retryable = module:RecordDistributionAward(entry.row, entry.sessionId, entry.raidUid)
			if recorded or not retryable then
				clearDistributionAwardRetry(entry.awardId, false)
				return
			end
			scheduleDistributionAwardRetry(entry)
		end, DISTRIBUTION_AWARD_RETRY_DELAY_SECONDS)
		if not scheduled or not handle then
			clearDistributionAwardRetry(entry.awardId, false)
			return
		end
		entry.handle = handle
	end

	local function queueDistributionAwardRetry(facts)
		if distributionAwardRetries[facts.awardId] then
			return
		end
		local _, raidUid = getCurrentRaidRetryIdentity()
		if not raidUid then
			return
		end
		local entry = {
			awardId = facts.awardId,
			sessionId = facts.sessionId,
			raidUid = raidUid,
			attempts = 0,
			row = {
				sender = facts.sender,
				itemLink = facts.itemLink,
				winnerName = facts.winnerName,
				rollType = facts.rollType,
				rollValue = facts.rollValue,
				count = facts.count,
				reason = "master_loot:" .. facts.transactionId,
			},
		}
		distributionAwardRetries[entry.awardId] = entry
		scheduleDistributionAwardRetry(entry)
	end

	Bus.RegisterCallback(DistributionChangedEvent, function(_, reason, row, sessionId)
		if reason == "item_done" or reason == "item_done_replay" then
			local recorded, _, retryable, facts = module:RecordDistributionAward(row, sessionId)
			if recorded and facts then
				clearDistributionAwardRetry(facts.awardId, true)
			elseif retryable and facts then
				queueDistributionAwardRetry(facts)
			end
		end
	end)

	local function shouldIgnoreGroupLoot()
		return GetOption("Logger", "ignoreGroupLoot") == true
	end

	function module:HandleLootChatMessage(msg, winnerOnly, stagedParsedGroupLoot)
		local observedType
		local parsedGroupLoot = copyParsedGroupLootFact(stagedParsedGroupLoot)
		if parsedGroupLoot then
			observedType = parsedGroupLoot.kind == "winner" and "winner" or "selection"
		elseif not shouldIgnoreGroupLoot() then
			observedType, parsedGroupLoot = PassiveGroupLoot.ParseGroupLootMessage(msg, winnerOnly)
			parsedGroupLoot = copyParsedGroupLootFact(parsedGroupLoot)
		end

		local raidService = Services.Raid
		local canObservePassiveLoot = raidService
			and raidService.CanObservePassiveLoot
			and raidService:CanObservePassiveLoot()
		local shouldRecord = canObservePassiveLoot
			and (
				(winnerOnly and observedType == "winner")
				or (not winnerOnly and (observedType == nil or observedType == "winner"))
			)
		local _, recoveryRaidUid = getActiveRaidRecoveryIdentity()
		if recoveryRaidUid and isAuthorityRecovering(recoveryRaidUid) then
			if parsedGroupLoot or shouldRecord then
				queueAuthorityRecoveryLootFact(recoveryRaidUid, msg, nil, nil, parsedGroupLoot, winnerOnly)
			end
			return observedType, parsedGroupLoot, nil, "recovery_queued"
		end

		local handled
		local outcome
		if shouldRecord then
			handled, outcome = self:AddLoot(msg, nil, nil, parsedGroupLoot)
			if handled and parsedGroupLoot then
				observedType, parsedGroupLoot =
					PassiveGroupLoot.ApplyGroupLootObservation(self, observedType, parsedGroupLoot, true)
				parsedGroupLoot = copyParsedGroupLootFact(parsedGroupLoot)
			end
		elseif parsedGroupLoot then
			observedType, parsedGroupLoot =
				PassiveGroupLoot.ApplyGroupLootObservation(self, observedType, parsedGroupLoot)
			parsedGroupLoot = copyParsedGroupLootFact(parsedGroupLoot)
			handled = true
			outcome = "observation_applied"
		end
		return observedType, parsedGroupLoot, handled, outcome
	end

	function module:AddPassiveLootRoll(rollId, rollTime)
		if shouldIgnoreGroupLoot() then
			return nil
		end
		return PassiveGroupLoot.AddPassiveLootRoll(self, rollId, rollTime)
	end

	-- Pending award helpers (shared with Master/Raid flows).

	function module:AddPendingAward(itemLink, looter, rollType, rollValue, rollSessionId, expiresAt, options)
		Workflow.QueueAward(workflowContext, {
			itemLink = itemLink,
			playerName = looter,
			rollType = rollType,
			rollValue = rollValue,
			rollSessionId = rollSessionId,
		})
		return LootAttribution.Add(itemLink, looter, rollType, rollValue, rollSessionId, expiresAt, options)
	end

	function module:CancelPendingAward(transactionId)
		local resolvedTransactionId = transactionId and tostring(transactionId) or ""
		if resolvedTransactionId == "" then
			return false
		end
		return LootAttribution.Cancel(resolvedTransactionId)
	end

	function module:ReconcileProvisionalAward(itemLink, looter, rollSessionId, authoritative)
		local pending, reason = LootAttribution.ReconcileProvisional(
			itemLink,
			looter,
			rollSessionId,
			nil,
			function(handle)
				return module:CancelTimer(handle)
			end,
			function(award)
				applyAuthoritativeProvisional(award, authoritative)
			end
		)
		if not pending then
			return false, reason
		end
		return true
	end

	function module:RemovePendingAward(
		itemLink,
		looter,
		maxAge,
		rollSessionId,
		preferResolvedValue,
		allowGroupLootPendingAwards
	)
		return LootAttribution.Remove(
			itemLink,
			looter,
			maxAge,
			rollSessionId,
			preferResolvedValue,
			allowGroupLootPendingAwards
		)
	end

	-- Fetches items from the currently open loot window.
	function module:FetchLoot()
		local perfStart = addon.hasPerf and addon:_PerfStart() or nil
		local oldItem
		if lootState.lootCount >= 1 then
			oldItem = getItemLink(lootState.currentItemIndex)
		end
		local lootItemCount = GetNumLootItems() or 0
		if addon.hasTrace then
			addon:trace(Diag.D.LogLootFetchStart:format(lootItemCount, lootState.currentItemIndex or 0))
		end
		lootState.opened = true
		lootState.fromInventory = false
		Workflow.BeginLootWindow(workflowContext, {
			raidNum = Database.GetCurrentRaid(),
			source = "LOOT_OPENED",
		})
		self:ClearLoot()

		local indexByItemKey = {}
		for i = 1, lootItemCount do
			-- In loot window we treat each slot as one awardable copy (even if quantity > 1).
			addLootWindowSlot(indexByItemKey, i)
		end

		lootState.currentItemIndex = findTrackedLootItemIndex(oldItem) or 1
		self:PrepareItem()
		local distributionItems = buildDistributionWindowItems()
		local distributionRevision, publicationReason = DistributionSession.BeginWindow(#distributionItems)
		local publicationOk
		if distributionRevision then
			publicationOk, publicationReason =
				DistributionSession.PublishWindowItems(distributionItems, distributionRevision)
		end
		if addon.hasTrace then
			addon:trace(Diag.D.LogLootFetchDone:format(lootState.lootCount or 0, lootState.currentItemIndex or 0))
		end
		if perfStart then
			addon:_PerfFinish(
				"Loot.FetchLoot",
				perfStart,
				"slots=" .. tostring(lootItemCount) .. " items=" .. tostring(lootState.lootCount or 0)
			)
		end
		if not distributionRevision or publicationOk ~= true then
			return nil, publicationReason or "distribution_publication_failed"
		end
		return true
	end

	-- Adds an item to the loot table.
	-- Note: in 3.3.5a GetItemInfo can be nil for uncached items; we fall back to
	-- loot-slot data and the itemLink itself so Master Loot UI + Spam Loot keep working.
	-- When caller-supplied hints are available (loot window path), skip the blocking
	-- GetItemInfo call and warm the cache asynchronously to avoid micro-freezes.
	function module:AddItem(itemLink, itemCount, nameHint, rarityHint, textureHint, colorHint)
		local itemName, itemRarity, itemTexture
		local hasHints = nameHint and rarityHint and textureHint
		local needsAsyncItemInfo = false

		if hasHints then
			-- Loot-window path: slot data is already available, avoid blocking query.
			itemName = nameHint
			itemRarity = rarityHint
			itemTexture = textureHint
			-- Warm the item cache so subsequent GetItemInfo calls (tooltip, export)
			-- will resolve instantly without blocking the main thread.
			if type(itemLink) == "string" then
				warmItemCache(itemLink)
			end
		else
			-- Non-loot-window path (inventory, manual add): call GetItemInfo directly.
			local giiName, _, giiRarity, _, _, _, _, _, _, giiTexture = GetItemInfo(itemLink)
			itemName = giiName
			itemRarity = giiRarity
			itemTexture = giiTexture

			needsAsyncItemInfo = (not itemName or not itemRarity or not itemTexture) and type(itemLink) == "string"

			if not itemName then
				itemName = nameHint
				if not itemName and type(itemLink) == "string" then
					itemName = itemLink:match("%[(.-)%]")
				end
			end
			if not itemRarity then
				itemRarity = rarityHint
			end
			if not itemTexture then
				itemTexture = textureHint
			end
		end

		local itemColor = resolveItemColor(itemLink, itemRarity, colorHint)

		if not itemName then
			if addon.hasDebug then
				addon:debug(Diag.D.LogLootItemInfoMissing:format(tostring(itemLink)))
			end
			itemName = tostring(itemLink)
		end

		itemTexture = itemTexture or C.RESERVES_ITEM_FALLBACK_ICON

		if lootState.fromInventory == false then
			local lootThreshold = getRaidLootThreshold()
			local rarity = tonumber(itemRarity) or 1
			if rarity < lootThreshold then
				return
			end
			lootState.lootCount = lootState.lootCount + 1
		else
			lootState.lootCount = 1
			lootState.currentItemIndex = 1
		end
		local itemIndex = lootState.lootCount
		lootTable[itemIndex] = {}
		lootTable[itemIndex].itemName = itemName
		lootTable[itemIndex].itemColor = itemColor
		lootTable[itemIndex].itemLink = itemLink
		lootTable[itemIndex].itemTexture = itemTexture
		lootTable[itemIndex].itemRarity = itemRarity
		lootTable[itemIndex].count = itemCount or 1
		lootTable[itemIndex].autoLootSuggestion = evaluateAutoLootSuggestion(itemLink, itemRarity, not hasHints)

		if not hasHints and type(itemLink) == "string" and (needsAsyncItemInfo or itemName == tostring(itemLink)) then
			if not requestLootItemInfo(itemIndex, itemLink) then
				warmItemCache(itemLink)
			end
		end
	end

	-- Prepares the currently selected item for display.
	function module:PrepareItem()
		if itemExists(lootState.currentItemIndex) then
			setSelectedItem(lootTable[lootState.currentItemIndex])
		end
	end

	-- Selects an item from the loot list by its index.
	function module:SelectItem(i)
		if itemExists(i) then
			lootState.currentItemIndex = i
			self:PrepareItem()
		end
	end

	-- Clears all loot from the table and resets the UI display.
	function module:ClearLoot()
		lootTable = twipe(lootTable)
		lootState.lootCount = 0
		notifySelectedItem(nil, nil)
	end

	-- Returns the table for the currently selected item.
	function getItem(i)
		i = i or lootState.currentItemIndex
		return lootTable[i]
	end

	function module:GetAutoLootSuggestion(i)
		local item = getItem(i)
		return item and item.autoLootSuggestion or nil
	end

	-- Returns the name of the currently selected item.
	function getItemName(i)
		i = i or lootState.currentItemIndex
		return lootTable[i] and lootTable[i].itemName or nil
	end

	-- Returns the link of the currently selected item.
	function getItemLink(i)
		i = i or lootState.currentItemIndex
		return lootTable[i] and lootTable[i].itemLink or nil
	end

	-- Returns the texture of the currently selected item.
	function getItemTexture(i)
		i = i or lootState.currentItemIndex
		return lootTable[i] and lootTable[i].itemTexture or nil
	end

	function module:GetCurrentItemCount()
		if lootState.fromInventory then
			return itemInfo.count or lootState.selectedItemCount or 1
		end
		local item = getItem()
		local count = item and item.count
		if count and count > 0 then
			return count
		end
		return 1
	end

	function module:GetLootWindowItems()
		local items = {}
		for i = 1, lootState.lootCount do
			local item = lootTable[i]
			if item and item.itemLink then
				items[#items + 1] = {
					itemKey = item.itemKey or (Item.GetItemStringFromLink(item.itemLink) or item.itemLink),
					count = tonumber(item.count) or 1,
				}
			end
		end
		return items
	end

	-- Checks if a loot item exists at the given index.
	function itemExists(i)
		i = i or lootState.currentItemIndex
		return (lootTable[i] ~= nil)
	end

	-- Read API consumed by Rolls, Master, inventory, and slash-command entry points.
	module.GetItem = getItem
	module.GetItemName = getItemName
	module.GetItemLink = getItemLink
	module.GetItemTexture = getItemTexture
	module.ItemExists = itemExists

	function module:GetLootWindowItemCountByKey(itemKey)
		if not itemKey then
			return 0
		end

		for i = 1, (tonumber(lootState.lootCount) or 0) do
			local it = getItem(i)
			local currentKey = it and (it.itemKey or (Item.GetItemStringFromLink(it.itemLink) or it.itemLink)) or nil
			if currentKey == itemKey then
				return tonumber(it.count) or 1
			end
		end
		return 0
	end
end
