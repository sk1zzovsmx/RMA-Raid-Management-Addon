-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: no bus events; item cache polling uses the Timer dependency
-- notes: consolidated item helpers + tooltip-based item metadata probing

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()
local Timer = feature.Timer
local Deformat = feature.Deformat
local Strings = feature.Strings

local Item = feature.Item or {}
addon.Item = Item

-- Timer ownership: ticker for polling item-cache requests.
Timer.BindMixin(Item, "Item")

local _G = _G
local type, tostring = type, tostring
local tonumber = tonumber
local pcall = pcall
local GetTime = assert(_G.GetTime, "Item cache time API is not initialized")
local GetItemInfo = assert(_G.GetItemInfo, "Item cache item info API is not initialized")

local ITEM_LINK_FORMAT = "|c%s|Hitem:%d:%s|h[%s]|h|r"
local TOOLTIP_NAME = "RMA_ItemTooltip"
local tooltip
local ITEM_CACHE_POLL_SECONDS = 0.30
local ITEM_CACHE_TIMEOUT_SECONDS = 3.00
local BIND_ON_PICKUP = _G.LE_ITEM_BIND_ON_ACQUIRE or 1
local BIND_ON_EQUIP = _G.LE_ITEM_BIND_ON_EQUIP or 2
local BIND_ON_USE = _G.LE_ITEM_BIND_ON_USE or 3
local BIND_QUEST = _G.LE_ITEM_BIND_QUEST or 4
local ITEM_INFO_METRIC_KEYS = {
	"requestsStarted",
	"requestsJoined",
	"requestsImmediate",
	"requestsCompleted",
	"requestTimeouts",
	"requestCancels",
	"callbacks",
	"getItemInfoCalls",
	"tooltipProbes",
}

-- ----- Internal state ----- --
local pendingItemRequests = {}
local pendingItemRequestsByKey = {}
local itemRequestTicker
local itemRequestRepeats = false
local itemInfoMetrics = {}

-- ----- Private helpers ----- --
local function resetItemInfoMetrics()
	for i = 1, #ITEM_INFO_METRIC_KEYS do
		itemInfoMetrics[ITEM_INFO_METRIC_KEYS[i]] = 0
	end
end

resetItemInfoMetrics()

local function incrementItemInfoMetric(key, amount)
	itemInfoMetrics[key] = (tonumber(itemInfoMetrics[key]) or 0) + (tonumber(amount) or 1)
end

local function ensureTooltip()
	if tooltip then
		return tooltip
	end

	tooltip = _G[TOOLTIP_NAME] or CreateFrame("GameTooltip", TOOLTIP_NAME, nil, "GameTooltipTemplate")
	return tooltip
end

local function setTooltipOwner(tip)
	local owner = UIParent or WorldFrame
	if owner and type(tip.SetOwner) == "function" then
		tip:SetOwner(owner, "ANCHOR_NONE")
	end
end

local function getNow()
	return GetTime()
end

local function safeCallback(callback, ...)
	if type(callback) == "function" then
		callback(...)
	end
end

local function normalizeTimeoutSeconds(timeoutSeconds)
	local timeout = tonumber(timeoutSeconds) or ITEM_CACHE_TIMEOUT_SECONDS
	if timeout <= 0 then
		timeout = ITEM_CACHE_TIMEOUT_SECONDS
	end
	return timeout
end

local function buildItemFallbackLink(itemId)
	itemId = tonumber(itemId)
	if not itemId then
		return nil
	end
	return "item:" .. tostring(itemId) .. ":0:0:0:0:0:0:0"
end

local function getItemSnapshot(itemRef)
	incrementItemInfoMetric("getItemInfoCalls")
	local name, link, rarity, _, _, _, _, _, _, texture = GetItemInfo(itemRef)
	if not name and type(itemRef) == "number" then
		incrementItemInfoMetric("getItemInfoCalls")
		name, link, rarity, _, _, _, _, _, _, texture = GetItemInfo(buildItemFallbackLink(itemRef))
	end
	if not name and not link then
		return nil
	end

	local itemId = Item.GetItemIdFromLink(link) or Item.GetItemIdFromLink(itemRef)
	return {
		itemId = itemId,
		itemName = name,
		itemLink = link,
		itemRarity = rarity,
		itemTexture = texture,
		itemRef = itemRef,
	}
end

local function warmItemRef(itemRef)
	if type(itemRef) == "string" then
		return Item.WarmItemCache(itemRef)
	end

	local fallbackLink = buildItemFallbackLink(itemRef)
	if fallbackLink then
		return Item.WarmItemCache(fallbackLink)
	end
	return false
end

local function getItemRequestKey(itemRef)
	local itemId = Item.GetItemIdFromLink(itemRef)
	if itemId then
		return "item:" .. tostring(itemId)
	end

	if type(itemRef) == "string" then
		local itemString = Item.GetItemStringFromLink(itemRef)
		return Strings.NormalizeText(itemString or itemRef, true)
	end
	return Strings.NormalizeText(itemRef, true)
end

local function cancelItemRequestTicker()
	if itemRequestTicker then
		Item:CancelTimer(itemRequestTicker)
		itemRequestTicker = nil
		itemRequestRepeats = false
	end
end

local processItemRequests

local function ensureItemRequestTicker()
	if itemRequestTicker then
		return
	end
	itemRequestTicker = Item:ScheduleRepeatingTimer(processItemRequests, ITEM_CACHE_POLL_SECONDS)
	itemRequestRepeats = true
end

local function addRequestCallback(request, callback, timeoutSeconds)
	local listener = {
		callback = callback,
		expiresAt = getNow() + normalizeTimeoutSeconds(timeoutSeconds),
		cancelled = false,
	}
	request.callbacks[#request.callbacks + 1] = listener
	if listener.expiresAt > request.expiresAt then
		request.expiresAt = listener.expiresAt
	end
	return listener
end

local function dispatchRequestCallback(listener, snapshot, ok, reason)
	if listener.cancelled then
		return false
	end
	listener.cancelled = true
	incrementItemInfoMetric("callbacks")
	safeCallback(listener.callback, snapshot, ok, reason)
	return true
end

local function hasActiveRequestCallbacks(request)
	local callbacks = request.callbacks
	for i = 1, #callbacks do
		if not callbacks[i].cancelled then
			return true
		end
	end
	return false
end

local function countPendingRequests()
	local count = 0
	for i = 1, #pendingItemRequests do
		local request = pendingItemRequests[i]
		if request and not request.cancelled and hasActiveRequestCallbacks(request) then
			count = count + 1
		end
	end
	return count
end

local function countPendingCallbacks()
	local count = 0
	for i = 1, #pendingItemRequests do
		local request = pendingItemRequests[i]
		if request and not request.cancelled then
			local callbacks = request.callbacks
			for j = 1, #callbacks do
				if not callbacks[j].cancelled then
					count = count + 1
				end
			end
		end
	end
	return count
end

local function removePendingRequest(request)
	request.cancelled = true
	if request.key and pendingItemRequestsByKey[request.key] == request then
		pendingItemRequestsByKey[request.key] = nil
	end
end

local function createRequestHandle(listener)
	local handle = {}
	function handle:Cancel()
		if listener.cancelled then
			return false
		end
		listener.cancelled = true
		incrementItemInfoMetric("requestCancels")
		return true
	end
	function handle:IsCancelled()
		return listener.cancelled == true
	end
	return handle
end

processItemRequests = function()
	if not itemRequestRepeats then
		itemRequestTicker = nil
	end

	local now = getNow()
	local nextRequests = {}

	for i = 1, #pendingItemRequests do
		local request = pendingItemRequests[i]
		if request.cancelled then
			removePendingRequest(request)
		elseif not hasActiveRequestCallbacks(request) then
			removePendingRequest(request)
		else
			local snapshot = getItemSnapshot(request.itemRef)
			if snapshot then
				removePendingRequest(request)
				incrementItemInfoMetric("requestsCompleted")
				local callbacks = request.callbacks
				for j = 1, #callbacks do
					dispatchRequestCallback(callbacks[j], snapshot, true)
				end
			else
				local callbacks = request.callbacks
				for j = 1, #callbacks do
					local listener = callbacks[j]
					if not listener.cancelled and now >= listener.expiresAt then
						incrementItemInfoMetric("requestTimeouts")
						dispatchRequestCallback(listener, nil, false, "timeout")
					end
				end
				if hasActiveRequestCallbacks(request) then
					warmItemRef(request.itemRef)
					nextRequests[#nextRequests + 1] = request
				else
					removePendingRequest(request)
				end
			end
		end
	end

	pendingItemRequests = nextRequests
	if #pendingItemRequests == 0 then
		cancelItemRequestTicker()
	elseif not itemRequestTicker then
		ensureItemRequestTicker()
	end
end

local function scanSoulboundFlag(tip)
	if not tip or type(tip.NumLines) ~= "function" then
		return false
	end
	local numLines = tip:NumLines() or 0
	for i = numLines, 1, -1 do
		local line = _G[TOOLTIP_NAME .. "TextLeft" .. i]
		local text = line and line:GetText() or nil
		if text and text ~= "" then
			if text == ITEM_SOULBOUND then
				return true
			end

			if Deformat and Deformat(text, BIND_TRADE_TIME_REMAINING) ~= nil then
				return false
			end
		end
	end

	return false
end

local function scanBindType(tip)
	if not tip or type(tip.NumLines) ~= "function" then
		return nil
	end
	local numLines = tip:NumLines() or 0
	local bindOnPickup = _G.ITEM_BIND_ON_PICKUP or "Binds when picked up"
	local bindOnEquip = _G.ITEM_BIND_ON_EQUIP or "Binds when equipped"
	local bindOnUse = _G.ITEM_BIND_ON_USE or "Binds when used"
	local bindQuest = _G.ITEM_BIND_QUEST or "Quest Item"

	for i = 1, numLines do
		local line = _G[TOOLTIP_NAME .. "TextLeft" .. i]
		local text = line and line:GetText() or nil
		if text and text ~= "" then
			if text == bindOnPickup or text == ITEM_SOULBOUND then
				return BIND_ON_PICKUP
			end
			if text == bindOnEquip then
				return BIND_ON_EQUIP
			end
			if text == bindOnUse then
				return BIND_ON_USE
			end
			if text == bindQuest then
				return BIND_QUEST
			end
		end
	end

	return nil
end

-- ----- Public methods ----- --
function Item.GetItemIdFromLink(itemLink)
	if type(itemLink) == "number" then
		return itemLink
	end
	if type(itemLink) ~= "string" or itemLink == "" then
		return nil
	end
	local directId = itemLink:match("item:(%d+)")
	if directId then
		return tonumber(directId)
	end
	local _, itemId = Deformat(itemLink, ITEM_LINK_FORMAT)
	return itemId
end

function Item.GetItemStringFromLink(itemLink)
	if type(itemLink) ~= "string" or itemLink == "" then
		return nil
	end

	local itemString = itemLink:match("|H(item:[%-%d:]+)|h")
	if itemString then
		return itemString
	end

	local _, itemId, rest = Deformat(itemLink, ITEM_LINK_FORMAT)
	if itemId then
		if rest and rest ~= "" then
			return "item:" .. tostring(itemId) .. ":" .. tostring(rest)
		end
		return "item:" .. tostring(itemId)
	end

	return nil
end

function Item.GetItemKey(itemKeyOrLink, itemLink)
	local key = Strings.NormalizeText(itemKeyOrLink, true)
	local link = Strings.NormalizeText(itemLink, true)

	if link and type(Item.GetItemStringFromLink) == "function" then
		key = Item.GetItemStringFromLink(link) or key
	elseif key and key:find("|Hitem:", 1, true) and type(Item.GetItemStringFromLink) == "function" then
		key = Item.GetItemStringFromLink(key) or key
	end

	return Strings.NormalizeText(key or link, true)
end

function Item.WarmItemCache(itemLink)
	if type(itemLink) ~= "string" or itemLink == "" then
		return false
	end
	if not itemLink:find("item:", 1, true) then
		return false
	end

	local tip = ensureTooltip()
	setTooltipOwner(tip)
	if type(tip.ClearLines) == "function" then
		tip:ClearLines()
	end
	incrementItemInfoMetric("tooltipProbes")
	local ok = pcall(tip.SetHyperlink, tip, itemLink)
	if type(tip.Hide) == "function" then
		tip:Hide()
	end
	return ok == true
end

function Item.RequestItemInfo(itemRef, callback, timeoutSeconds)
	if type(callback) ~= "function" then
		return nil, "callback_required"
	end
	if type(itemRef) ~= "string" and type(itemRef) ~= "number" then
		return nil, "invalid_item"
	end

	local requestKey = getItemRequestKey(itemRef)
	local pendingRequest = requestKey and pendingItemRequestsByKey[requestKey] or nil
	if pendingRequest and not pendingRequest.cancelled then
		incrementItemInfoMetric("requestsJoined")
		local listener = addRequestCallback(pendingRequest, callback, timeoutSeconds)
		ensureItemRequestTicker()
		return createRequestHandle(listener)
	end

	local snapshot = getItemSnapshot(itemRef)
	if snapshot then
		incrementItemInfoMetric("requestsImmediate")
		incrementItemInfoMetric("callbacks")
		safeCallback(callback, snapshot, true)
		return {
			Cancel = function()
				return false
			end,
			IsCancelled = function()
				return true
			end,
		}
	end

	warmItemRef(itemRef)

	local request = {
		key = requestKey,
		itemRef = itemRef,
		callbacks = {},
		expiresAt = 0,
		cancelled = false,
	}
	local listener = addRequestCallback(request, callback, timeoutSeconds)
	pendingItemRequests[#pendingItemRequests + 1] = request
	if requestKey then
		pendingItemRequestsByKey[requestKey] = request
	end
	incrementItemInfoMetric("requestsStarted")
	ensureItemRequestTicker()

	return createRequestHandle(listener)
end

function Item.GetItemBindFromTooltip(itemLink)
	if type(itemLink) ~= "string" or itemLink == "" then
		return nil
	end

	local tip = ensureTooltip()
	setTooltipOwner(tip)
	if type(tip.ClearLines) == "function" then
		tip:ClearLines()
	end
	incrementItemInfoMetric("tooltipProbes")
	local ok = pcall(tip.SetHyperlink, tip, itemLink)
	if not ok then
		if type(tip.Hide) == "function" then
			tip:Hide()
		end
		return nil
	end

	local bindType = scanBindType(tip)
	if type(tip.Hide) == "function" then
		tip:Hide()
	end
	return bindType
end

function Item.IsBagItemSoulbound(bag, slot)
	if bag == nil or slot == nil then
		return false
	end

	local tip = ensureTooltip()
	setTooltipOwner(tip)
	if type(tip.ClearLines) == "function" then
		tip:ClearLines()
	end
	incrementItemInfoMetric("tooltipProbes")
	local ok = pcall(tip.SetBagItem, tip, bag, slot)
	if not ok then
		if type(tip.Hide) == "function" then
			tip:Hide()
		end
		return false
	end

	local isSoulbound = scanSoulboundFlag(tip)
	if type(tip.Hide) == "function" then
		tip:Hide()
	end
	return isSoulbound
end

function Item.GetInfoMetrics(out)
	out = out or {}
	for i = 1, #ITEM_INFO_METRIC_KEYS do
		local key = ITEM_INFO_METRIC_KEYS[i]
		out[key] = tonumber(itemInfoMetrics[key]) or 0
	end
	out.totalRequests = out.requestsStarted + out.requestsJoined + out.requestsImmediate
	out.pendingRequests = countPendingRequests()
	out.pendingCallbacks = countPendingCallbacks()
	return out
end

function Item.ResetInfoMetrics()
	resetItemInfoMetrics()
	return true
end

do
	local name = "Modules/Item"
	local deps = { "Init", "Modules/Timer", "Modules/Strings" }
	local registry = feature.ModuleRegistry
	if registry then
		registry.AddModule(name, { deps = deps })
		registry.SetLoaded(name)
	else
		addon.ModuleRegistryPendingRegistrations = addon.ModuleRegistryPendingRegistrations or {}
		local pending = addon.ModuleRegistryPendingRegistrations
		pending[#pending + 1] = { name = name, deps = deps, loaded = true }
	end
end
