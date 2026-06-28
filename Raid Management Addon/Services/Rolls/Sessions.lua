-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Rolls._Sessions
-- events: none
-- notes: session and context helpers for rolls service

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Item = feature.Item
local Services = feature.Services
local Strings = feature.Strings

local rollTypes = feature.rollTypes
local tostring, tonumber = tostring, tonumber
local next = next

-- ----- Internal state ----- --
feature.EnsureServiceNamespace("Rolls")
local Rolls = Services.Rolls
local module = Rolls
module._Sessions = module._Sessions or {}

local Sessions = module._Sessions

-- ----- Private helpers ----- --
local function assertContext(ctx)
    assert(type(ctx) == "table", "Rolls sessions context is required")
    assert(type(ctx.lootState) == "table", "Rolls loot state is required")
    assert(type(ctx.state) == "table", "Rolls session state is required")
    return ctx, ctx.lootState, ctx.state
end

local function normalizeCandidateKey(name)
    local normalized = Strings and Strings.NormalizeLower and Strings.NormalizeLower(name) or nil
    if normalized and normalized ~= "" then
        return normalized
    end
    if type(name) == "string" and name ~= "" then
        return string.lower(name)
    end
    return nil
end

Sessions._NormalizeCandidateKey = normalizeCandidateKey

-- ----- Public methods ----- --

function Sessions.GetRollSession(ctx)
    local _, lootState = assertContext(ctx)
    local session = lootState.rollSession

    if type(session) ~= "table" then
        return nil
    end
    if not session.id or session.id == "" then
        return nil
    end
    return session
end

function Sessions.ClearTieRerollFilter(ctx)
    local _, _, state = assertContext(ctx)
    state.tieReroll = nil
end

function Sessions.SetTieRerollFilter(ctx, names)
    local _, _, state = assertContext(ctx)
    local ordered = {}
    local keyed = {}
    local reroll

    if type(names) ~= "table" then
        Sessions.ClearTieRerollFilter(ctx)
        return nil
    end

    for i = 1, #names do
        local name = names[i]
        local key = normalizeCandidateKey(name)
        if key and not keyed[key] then
            ordered[#ordered + 1] = name
            keyed[key] = name
        end
    end

    if #ordered <= 0 then
        Sessions.ClearTieRerollFilter(ctx)
        return nil
    end

    reroll = {
        ordered = ordered,
        keyed = keyed,
    }
    state.tieReroll = reroll
    return reroll
end

function Sessions.IsTieRerollRestricted(ctx, name)
    local _, _, state = assertContext(ctx)
    local reroll = state.tieReroll
    local key

    if not (reroll and reroll.keyed and next(reroll.keyed)) then
        return false
    end

    key = normalizeCandidateKey(name)
    return not key or reroll.keyed[key] == nil
end

function Sessions.GetManualExclusionEntry(ctx, name)
    local _, _, state = assertContext(ctx)
    local key = normalizeCandidateKey(name)
    if not key then
        return nil
    end
    return state.manualExclusions[key]
end

function Sessions.GetActiveRollType(ctx)
    local _, lootState = assertContext(ctx)
    local session = Sessions.GetRollSession(ctx)
    local rollType = session and tonumber(session.rollType) or tonumber(lootState.currentRollType)
    return rollType or rollTypes.FREE
end

function Sessions.GetCurrentItemLink(ctx)
    local session = Sessions.GetRollSession(ctx)
    local item

    if session and session.itemLink then
        return session.itemLink
    end

    item = ctx.getItem and ctx.getItem(ctx.getItemIndex and ctx.getItemIndex() or nil)
    return item and item.itemLink or nil
end

function Sessions.SyncSessionState(ctx, session)
    local _, lootState = assertContext(ctx)

    if not session then
        return
    end
    if tonumber(session.rollType) then
        lootState.currentRollType = tonumber(session.rollType)
    end
    if tonumber(session.lootNid) then
        lootState.currentRollItem = tonumber(session.lootNid)
    end
end

function Sessions.NormalizeExpectedWinners(ctx, count)
    local _, lootState = assertContext(ctx)

    count = tonumber(count) or tonumber(lootState.selectedItemCount) or 1
    if count < 1 then
        count = 1
    end
    return count
end

function Sessions.AllocateRollSessionId(ctx)
    local _, lootState = assertContext(ctx)
    local nextId = tonumber(lootState.nextRollSessionId) or 1

    if nextId < 1 then
        nextId = 1
    end
    lootState.nextRollSessionId = nextId + 1
    return "RS:" .. tostring(nextId)
end

local function getRollSessionItemKey(itemLink)
    if not itemLink then
        return nil
    end
    return Item.GetItemStringFromLink(itemLink) or itemLink
end

function Sessions.GetCurrentRollItemId(ctx, onResolved)
    local session = Sessions.GetRollSession(ctx)
    local sessionItemId = session and tonumber(session.itemId) or nil

    if sessionItemId and sessionItemId > 0 then
        if onResolved then
            onResolved(sessionItemId)
        end
        return sessionItemId
    end

    local index = ctx.getItemIndex and ctx.getItemIndex() or nil
    local item = ctx.getItem and ctx.getItem(index) or nil
    local itemLink = item and item.itemLink
    if not itemLink then
        return nil
    end

    local itemId = Item.GetItemIdFromLink(itemLink)
    if itemId and session then
        session.itemId = itemId
        session.itemLink = itemLink
        session.itemKey = getRollSessionItemKey(itemLink) or itemLink
    end

    if onResolved then
        onResolved(itemId)
    end
    return itemId
end

function Sessions.OpenRollSession(ctx, itemLink, rollType, source)
    local _, lootState = assertContext(ctx)
    local itemId
    local session

    if not itemLink then
        return nil
    end

    itemId = Item.GetItemIdFromLink(itemLink)
    session = {
        id = Sessions.AllocateRollSessionId(ctx),
        itemKey = getRollSessionItemKey(itemLink),
        itemId = tonumber(itemId) or nil,
        itemLink = itemLink,
        rollType = tonumber(rollType) or tonumber(lootState.currentRollType) or rollTypes.FREE,
        lootNid = tonumber(lootState.currentRollItem) or 0,
        bossNid = nil,
        startedAt = GetTime(),
        endsAt = nil,
        source = source or (lootState.fromInventory and "inventory" or "lootWindow"),
        expectedWinners = Sessions.NormalizeExpectedWinners(ctx),
        active = true,
    }

    lootState.rollSession = session
    lootState.rollStarted = true
    Sessions.SyncSessionState(ctx, session)
    return session
end

function Sessions.EnsureAdHocRollSession(ctx)
    local _, lootState = assertContext(ctx)
    local session = Sessions.GetRollSession(ctx)
    local itemLink
    local itemId

    if session then
        return session
    end

    itemLink = Sessions.GetCurrentItemLink(ctx)
    itemId = itemLink and Item.GetItemIdFromLink(itemLink) or nil
    if not itemLink and not itemId then
        return nil
    end

    session = {
        id = Sessions.AllocateRollSessionId(ctx),
        itemKey = getRollSessionItemKey(itemLink),
        itemId = itemId,
        itemLink = itemLink,
        rollType = tonumber(lootState.currentRollType) or rollTypes.FREE,
        lootNid = tonumber(lootState.currentRollItem) or 0,
        bossNid = nil,
        startedAt = GetTime(),
        endsAt = nil,
        source = lootState.fromInventory and "inventory" or "lootWindow",
        expectedWinners = Sessions.NormalizeExpectedWinners(ctx),
        active = true,
    }
    lootState.rollSession = session
    Sessions.SyncSessionState(ctx, session)
    return session
end

function Sessions.EnsureRollSession(ctx, itemLink, rollType, source)
    local _, lootState = assertContext(ctx)
    local session = Sessions.GetRollSession(ctx)

    if not session then
        return Sessions.OpenRollSession(ctx, itemLink, rollType, source)
    end

    if itemLink then
        local previousItemKey = session.itemKey
        local previousItemId = tonumber(session.itemId) or nil
        local nextItemKey = getRollSessionItemKey(itemLink)
        local itemId = Item.GetItemIdFromLink(itemLink)
        local nextItemId = tonumber(itemId) or nil
        local isSameItem = false

        session.itemLink = itemLink
        session.itemKey = nextItemKey

        if nextItemKey and previousItemKey and nextItemKey == previousItemKey then
            isSameItem = true
        elseif nextItemId and previousItemId and nextItemId == previousItemId then
            isSameItem = true
        end

        session.itemId = nextItemId or session.itemId
        if not isSameItem then
            session.lootNid = 0
            session.bossNid = nil
        end
    end

    if rollType ~= nil then
        session.rollType = tonumber(rollType) or session.rollType
    end
    session.source = source or session.source or (lootState.fromInventory and "inventory" or "lootWindow")
    session.lootNid = tonumber(session.lootNid) or 0
    session.active = true
    session.endsAt = nil
    if not session.startedAt then
        session.startedAt = GetTime()
    end

    session.expectedWinners = Sessions.NormalizeExpectedWinners(ctx)
    Sessions.SyncSessionState(ctx, session)
    return session
end

function Sessions.UpdateSessionRollWindow(ctx, opened)
    local session = Sessions.GetRollSession(ctx)

    if not session then
        return
    end
    if opened then
        session.endsAt = nil
    elseif session.endsAt == nil then
        session.endsAt = GetTime()
    end
    Sessions.SyncSessionState(ctx, session)
end

function Sessions.CloseRollSession(ctx)
    local _, lootState = assertContext(ctx)
    local session = Sessions.GetRollSession(ctx)

    if session and session.endsAt == nil then
        session.endsAt = GetTime()
    end
    lootState.rollSession = nil
end

function Sessions.GetSelectionTargetCount(ctx)
    local _, lootState = assertContext(ctx)
    local count = tonumber(lootState.selectedItemCount) or 1

    if count < 1 then
        count = 1
    end

    if lootState.fromInventory then
        local traded = tonumber(lootState.itemTraded) or 0
        local remaining = count - traded
        if remaining > 0 then
            count = remaining
        end
    end

    return count
end

function Sessions.GetExpectedWinnerCount(ctx)
    local session = Sessions.GetRollSession(ctx)
    local count = session and tonumber(session.expectedWinners) or Sessions.GetSelectionTargetCount(ctx)

    if not count or count < 1 then
        count = 1
    end
    return count
end

function Sessions.GetCurrentRollContext(ctx, itemLink, rollType)
    local currentItemLink = itemLink or Sessions.GetCurrentItemLink(ctx)
    local currentItemId = currentItemLink and Item.GetItemIdFromLink(currentItemLink) or nil

    if not currentItemId and ctx.getCurrentRollItemID then
        currentItemId = ctx.getCurrentRollItemID()
    end

    return {
        itemId = currentItemId and tonumber(currentItemId) or nil,
        itemLink = currentItemLink,
        rollType = tonumber(rollType) or Sessions.GetActiveRollType(ctx),
    }
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
    registry.AddModule("Services/Rolls/Sessions", {
        deps = {
            "Init",
            "Modules/ModuleRegistry",
            "Modules/Item",
            "Modules/Strings",
        },
    })
    registry.SetLoaded("Services/Rolls/Sessions")
end

