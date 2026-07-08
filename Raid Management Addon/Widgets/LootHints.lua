-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Widgets.LootHints
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Widgets = feature.Widgets
local UI = feature.UI
local UIWidgets = UI.Widgets
local Frames = UI.Frames
local Tooltips = UI.Tooltips
local SetScriptSafely = assert(Frames.SetScriptSafely, "Loot hints frame script binder is not initialized")
local HookScriptSafely = assert(Frames.HookScriptSafely, "Loot hints frame hook binder is not initialized")
local ShowItemTooltip = assert(Tooltips.ShowItem, "Loot hints item tooltip presenter is not initialized")
local HideTooltip = assert(Tooltips.Hide, "Loot hints tooltip hider is not initialized")
local Item = feature.Item
local L = feature.L
local Options = feature.Options
local Services = feature.Services
local Reserves = assert(Services.Reserves, "Loot hints reserves service is not initialized")
local GetPlayersForItem = assert(Reserves.GetPlayersForItem, "Loot hints reserve player lookup is not initialized")
local HasItemReserves = assert(Reserves.HasItemReserves, "Loot hints reserve-state resolver is not initialized")

local _G = _G
local HookSecureFunc = assert(_G.hooksecurefunc, "Loot hints secure hook API is not initialized")
assert(_G.LootFrame_Update, "Loot hints loot-frame update API is not initialized")
local type = type
local tostring, tonumber = tostring, tonumber

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Widgets/LootHints", {
		deps = {
			"Init",
			"Database/DBOptions",
			"Modules/ModuleRegistry",
			"Modules/Item",
			"Modules/UI/Facade",
			"Modules/UI/Frames",
			"Services/Reserves",
		},
	})
	registry.SetLoaded("Widgets/LootHints")
end

do
	if not UIWidgets.IsEnabled("LootHints") then
		return
	end

	Widgets.LootHints = Widgets.LootHints or {}
	local module = Widgets.LootHints
	addon.Widgets.LootHints = module

	-- ----- Internal state ----- --
	local hooksBound = false
	local GetOption = Options.GetValue

	-- ----- Private helpers ----- --
	local function buildLootReserveUiState(itemLink)
		local state = {
			itemId = nil,
			hasReserves = false,
			playerLines = {},
		}
		local itemId = Item.GetItemIdFromLink(itemLink)
		if not itemId then
			return state
		end

		state.itemId = itemId

		local playerLines = GetPlayersForItem(Reserves, itemId, true, true, true, false)
		if type(playerLines) == "table" and #playerLines > 0 then
			state.hasReserves = true
			state.playerLines = playerLines
			return state
		end

		if HasItemReserves(Reserves, itemId) then
			state.hasReserves = true
		end

		return state
	end

	local function ensureLootReserveBorder(frame)
		if not frame then
			return nil
		end
		if frame._RMALootReserveBorder ~= nil then
			return frame._RMALootReserveBorder
		end
		if not frame.CreateTexture then
			return nil
		end

		local border = frame:CreateTexture(nil, "OVERLAY")
		border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
		if border.SetBlendMode then
			border:SetBlendMode("ADD")
		end
		if border.SetVertexColor then
			border:SetVertexColor(1, 0.35, 0.85, 1)
		end
		if border.SetWidth then
			border:SetWidth(42)
		end
		if border.SetHeight then
			border:SetHeight(42)
		end
		border:Hide()
		frame._RMALootReserveBorder = border
		return border
	end

	local function setLootReserveBorder(frame, icon, shown)
		if not frame then
			return
		end

		frame._RMALootReserveMarked = shown == true
		local border = ensureLootReserveBorder(frame)
		if not border then
			return
		end

		if border.ClearAllPoints then
			border:ClearAllPoints()
		end
		if icon then
			border:SetPoint("CENTER", icon, "CENTER", 0, 0)
		else
			border:SetPoint("CENTER", frame, "CENTER", 0, 0)
		end

		if shown then
			border:Show()
		else
			border:Hide()
		end
	end

	local function showLootItemTooltip(frame)
		if not (frame and frame._RMALootItemLink) then
			return
		end
		if GetOption("UI", "showTooltips") ~= true then
			return
		end

		local playerLines = frame._RMALootReservePlayerLines
		if type(playerLines) ~= "table" or #playerLines <= 0 then
			return
		end

		local anchor = frame._RMALootTooltipAnchor or "ANCHOR_CURSOR"
		ShowItemTooltip(frame, frame._RMALootItemLink, nil, anchor, {
			spacer = true,
			heading = L.StrLootReservedBy,
			headingColor = { 0.82, 0.58, 1 },
			lines = playerLines,
			lineColor = { 1, 1, 1 },
		})
	end

	local function bindLootItemTooltip(frame, itemLink, reserveState, anchor)
		if not frame then
			return
		end

		frame._RMALootItemLink = itemLink
		frame._RMALootReservePlayerLines = reserveState and reserveState.playerLines or nil
		frame._RMALootTooltipAnchor = anchor or "ANCHOR_CURSOR"

		if itemLink and GetOption("UI", "showTooltips") then
			SetScriptSafely(frame, "OnEnter", showLootItemTooltip)
			SetScriptSafely(frame, "OnLeave", HideTooltip)
		else
			SetScriptSafely(frame, "OnEnter", nil)
			SetScriptSafely(frame, "OnLeave", nil)
		end
	end

	local function getLootFrameButton(index)
		local button = _G["LootButton" .. tostring(index)]
		if button then
			return button
		end
		local lootFrame = _G.LootFrame
		if lootFrame and type(lootFrame.buttons) == "table" then
			return lootFrame.buttons[index]
		end
		return nil
	end

	local function getLootFrameButtonSlot(button, fallbackSlot)
		local slot = tonumber(button and button.slot)
		if slot and slot > 0 then
			return slot
		end
		if button and button.GetID then
			slot = tonumber(button:GetID())
			if slot and slot > 0 then
				return slot
			end
		end
		return fallbackSlot
	end

	local function getLootFrameButtonIcon(button, index)
		if not button then
			return nil
		end

		local buttonName = button.GetName and button:GetName() or nil
		if buttonName then
			local icon = _G[buttonName .. "IconTexture"] or _G[buttonName .. "Icon"]
			if icon then
				return icon
			end
		end

		local fallbackName = "LootButton" .. tostring(index)
		return _G[fallbackName .. "IconTexture"]
			or _G[fallbackName .. "Icon"]
			or button.IconTexture
			or button.iconTexture
			or button.Icon
			or button.icon
	end

	local function getLootFrameButtonCount(activeCount)
		local buttonCount = tonumber(_G.LOOTFRAME_NUMBUTTONS) or 0
		if activeCount and activeCount > buttonCount then
			buttonCount = activeCount
		end
		if buttonCount > 0 then
			return buttonCount
		end

		buttonCount = 0
		for i = 1, 32 do
			if getLootFrameButton(i) then
				buttonCount = i
			elseif buttonCount > 0 then
				return buttonCount
			end
		end
		return buttonCount
	end

	local function bindLootFrameButtonTooltip(button, itemLink, reserveState, anchor)
		if not button then
			return
		end

		button._RMALootItemLink = itemLink
		button._RMALootReservePlayerLines = reserveState and reserveState.playerLines or nil
		button._RMALootTooltipAnchor = anchor or "ANCHOR_RIGHT"

		if not button._RMALootReserveTooltipHooked then
			HookScriptSafely(button, "OnEnter", showLootItemTooltip)
			HookScriptSafely(button, "OnLeave", HideTooltip)
			button._RMALootReserveTooltipHooked = true
		end
	end

	-- ----- Public methods ----- --
	module.ApplyLootFrameReserveHints = function()
		if not _G.LootFrame then
			return
		end

		local activeCount = 0
		if type(GetNumLootItems) == "function" then
			activeCount = tonumber(GetNumLootItems()) or 0
		end

		local buttonCount = getLootFrameButtonCount(activeCount)
		for i = 1, buttonCount do
			local button = getLootFrameButton(i)
			if button then
				local slot = getLootFrameButtonSlot(button, i)
				local itemLink = nil
				if type(GetLootSlotLink) == "function" and slot and slot <= activeCount then
					itemLink = GetLootSlotLink(slot)
				end

				local reserveState = buildLootReserveUiState(itemLink)
				setLootReserveBorder(button, getLootFrameButtonIcon(button, i), reserveState.hasReserves)
				bindLootFrameButtonTooltip(button, itemLink, reserveState, "ANCHOR_RIGHT")
			end
		end
	end

	module.ClearLootFrameReserveHints = function()
		local buttonCount = getLootFrameButtonCount(0)
		for i = 1, buttonCount do
			local button = getLootFrameButton(i)
			if button then
				button._RMALootItemLink = nil
				button._RMALootReservePlayerLines = nil
				setLootReserveBorder(button, nil, false)
			end
		end
	end

	module.EnsureLootFrameHooks = function()
		if hooksBound then
			return
		end
		hooksBound = true

		HookSecureFunc("LootFrame_Update", module.ApplyLootFrameReserveHints)
	end

	module.EnsureLootFrameHooks()

	UIWidgets.Register("LootHints", module)
	UIWidgets.RegisterFunction("LootHints", "ApplyLootFrameReserveHints", module.ApplyLootFrameReserveHints)
	UIWidgets.RegisterFunction("LootHints", "ClearLootFrameReserveHints", module.ClearLootFrameReserveHints)
	UIWidgets.RegisterFunction("LootHints", "EnsureLootFrameHooks", module.EnsureLootFrameHooks)
end
