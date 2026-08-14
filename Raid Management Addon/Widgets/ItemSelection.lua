-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Widgets.ItemSelection
-- events: none
-- notes: owns Master item-selection child frame creation and inventory cursor acceptance
local addon = select(2, ...)
local Diag = addon.Diag
local Widgets = addon.Widgets

local ItemSelection = Widgets.ItemSelection or {}
Widgets.ItemSelection = ItemSelection

local tonumber = tonumber
local tostring = tostring
local type = type

local function getSelectionButtonRefs(controller, button)
	return controller.getNamedParts(button, {
		name = "Name",
		icon = "Icon",
	})
end

local function hideButtons(controller, startIndex)
	local buttons = controller.state.buttons
	local first = tonumber(startIndex) or 1
	if first < 1 then
		first = 1
	end
	for i = first, #buttons do
		local button = buttons[i]
		if button then
			button:Hide()
		end
	end
end

local function anchorSelectionFrame(controller)
	local frame = controller.state.frame
	if not frame then
		return
	end
	local selectItemButton = controller.getSelectItemButton()
	if not selectItemButton then
		return
	end
	if frame.ClearAllPoints then
		frame:ClearAllPoints()
	end
	if frame.SetPoint then
		frame:SetPoint("TOPLEFT", selectItemButton, "BOTTOMLEFT", 0, -3)
	end
end

local function ensureSelectionButton(controller, index)
	local frameName = controller.getFrameName()
	local state = controller.state
	if not frameName or not state.frame then
		return nil
	end

	local button = state.buttons[index]
	if button then
		return button
	end

	local btnName = frameName .. "ItemSelectionBtn" .. index
	button = controller.createFrame("Button", btnName, state.frame, "RMAItemSelectionButton")
	button:SetID(index)
	if button.RegisterForClicks then
		button:RegisterForClicks("AnyUp")
	end
	controller.setScriptSafely(button, "OnClick", function(self)
		local buttonIndex = self and self.GetID and self:GetID() or nil
		if buttonIndex ~= nil then
			controller:HideFrame()
			controller.onSelectLootItem(buttonIndex)
		end
	end)
	state.buttons[index] = button
	return button
end

local function ensureSelectionFrame(controller)
	local state = controller.state
	if state.frame == nil then
		local frame = controller.getFrame()
		if not frame then
			return nil
		end
		local frameName = controller.getFrameName()
		local selectionName = frameName and (frameName .. "ItemSelectionFrame") or nil
		state.frame = controller.createFrame("Frame", selectionName, frame, "RMAItemSelectionFrame")
		state.frame:Hide()
	end
	anchorSelectionFrame(controller)
	hideButtons(controller)
	return state.frame
end

function ItemSelection.CreateController(opts)
	opts = opts or {}

	local wow = assert(opts.wow, Diag.A.MasterItemSelectionWoWApiTableNotInitialized)
	local controller = {
		state = assert(opts.state, Diag.A.MasterItemSelectionStateNotInitialized),
		createFrame = assert(opts.createFrame, Diag.A.MasterItemSelectionFrameFactoryNotInitialized),
		getFrame = assert(opts.getFrame, Diag.A.MasterItemSelectionFrameResolverNotInitialized),
		getFrameName = assert(opts.getFrameName, Diag.A.MasterItemSelectionFrameNameResolverNotInitialized),
		getNamedParts = assert(opts.getNamedParts, Diag.A.MasterItemSelectionNamedPartsResolverNotInitialized),
		setScriptSafely = assert(opts.setScriptSafely, Diag.A.MasterItemSelectionScriptBinderNotInitialized),
		getSelectItemButton = assert(
			opts.getSelectItemButton,
			Diag.A.MasterItemSelectionAnchorButtonResolverNotInitialized
		),
		clearItemCountInput = assert(
			opts.clearItemCountInput,
			Diag.A.MasterItemSelectionItemCountResetterNotInitialized
		),
		getLootItem = assert(opts.getLootItem, Diag.A.MasterItemSelectionLootItemResolverNotInitialized),
		getLootItemName = assert(
			opts.getLootItemName,
			Diag.A.MasterItemSelectionLootItemNameResolverNotInitialized
		),
		getLootItemTexture = assert(
			opts.getLootItemTexture,
			Diag.A.MasterItemSelectionLootItemTextureResolverNotInitialized
		),
		addLootItem = assert(opts.addLootItem, Diag.A.MasterItemSelectionLootItemAdderNotInitialized),
		prepareLootItem = assert(opts.prepareLootItem, Diag.A.MasterItemSelectionLootItemPreparerNotInitialized),
		inventory = assert(opts.inventory, Diag.A.MasterItemSelectionInventoryOwnerNotInitialized),
		lootState = assert(opts.lootState, Diag.A.MasterItemSelectionLootStateNotInitialized),
		itemInfo = assert(opts.itemInfo, Diag.A.MasterItemSelectionItemStateNotInitialized),
		isCountdownRunning = assert(
			opts.isCountdownRunning,
			Diag.A.MasterItemSelectionCountdownStateResolverNotInitialized
		),
		onSelectLootItem = assert(
			opts.onSelectLootItem,
			Diag.A.MasterItemSelectionRowSelectionCallbackNotInitialized
		),
		onInventoryItemApplied = assert(
			opts.onInventoryItemApplied,
			Diag.A.MasterItemSelectionPostApplyCallbackNotInitialized
		),
		setAnnounced = assert(opts.setAnnounced, Diag.A.MasterItemSelectionAnnounceStateSetterNotInitialized),
		L = assert(opts.L, Diag.A.MasterItemSelectionLocalizedStringsNotInitialized),
		wow = {
			ClearCursor = assert(wow.ClearCursor, Diag.A.MasterItemSelectionClearCursorApiNotInitialized),
			CursorHasItem = assert(wow.CursorHasItem, Diag.A.MasterItemSelectionCursorItemApiNotInitialized),
			GetCursorInfo = assert(wow.GetCursorInfo, Diag.A.MasterItemSelectionCursorInfoApiNotInitialized),
			GetContainerItemLink = assert(
				wow.GetContainerItemLink,
				Diag.A.MasterItemSelectionContainerItemLinkApiNotInitialized
			),
		},
		debug = opts.debug,
		warn = opts.warn,
	}

	controller.state.buttons = controller.state.buttons or {}

	function controller:ApplyInventoryItem(itemLink, totalCount, bag, slot, slotCount)
		if self.isCountdownRunning() then
			return false
		end
		if not itemLink then
			return false
		end

		local itemCount = tonumber(totalCount) or 1
		if itemCount < 1 then
			itemCount = 1
		end

		self.clearItemCountInput()

		self.lootState.fromInventory = true
		self.addLootItem(itemLink, itemCount)
		self.prepareLootItem()
		self.setAnnounced(false)

		self.itemInfo.bagID = bag
		self.itemInfo.slotID = slot
		self.itemInfo.count = itemCount
		self.itemInfo.isStack = (tonumber(slotCount) or 1) > 1

		self.wow.ClearCursor()
		self.onInventoryItemApplied(true)
		return true
	end

	function controller:TryAcceptFromCursor()
		if self.isCountdownRunning() then
			return false
		end
		if not self.wow.CursorHasItem() then
			return false
		end

		local infoType, itemId, itemLink = self.wow.GetCursorInfo()
		if infoType ~= "item" then
			return false
		end

		local totalCount, bag, slot, slotCount, hasMatch = self.inventory.FindTradeableInventoryMatch(itemLink, itemId)
		if not totalCount or totalCount < 1 then
			local itemRef = tostring(itemLink or itemId or "unknown")
			if hasMatch then
				if type(self.warn) == "function" then
					self.warn(self.L.ErrMLInventorySoulbound:format(itemRef))
				end
				if type(self.debug) == "function" then
					self.debug(addon.Diag.D.LogMLInventorySoulbound:format(itemRef))
				end
			elseif type(self.warn) == "function" then
				self.warn(self.L.ErrMLInventoryItemMissing:format(itemRef))
			end
			self.wow.ClearCursor()
			return true
		end

		if not itemLink and bag and slot then
			itemLink = self.wow.GetContainerItemLink(bag, slot)
		end
		if not itemLink then
			if type(self.warn) == "function" then
				self.warn(self.L.ErrMLInventoryItemMissing:format(tostring(itemLink or itemId or "unknown")))
			end
			self.wow.ClearCursor()
			return true
		end

		return self:ApplyInventoryItem(itemLink, totalCount, bag, slot, slotCount)
	end

	function controller:UpdateFrame()
		local frame = ensureSelectionFrame(self)
		if not frame then
			return
		end

		local lootCount = tonumber(self.lootState.lootCount) or 0
		local height = 5
		for i = 1, lootCount do
			local button = ensureSelectionButton(self, i)
			if button then
				local refs = getSelectionButtonRefs(self, button)
				local item = self.getLootItem(i)
				local count = item and item.count or 1
				local itemName = self.getLootItemName(i)
				local itemTexture = self.getLootItemTexture(i)
				local itemNameButton = refs and refs.name or nil
				local itemTextureButton = refs and refs.icon or nil

				button:Show()
				if itemNameButton then
					if count and count > 1 then
						itemNameButton:SetText(itemName .. " x" .. count)
					else
						itemNameButton:SetText(itemName)
					end
				end
				if itemTextureButton then
					itemTextureButton:SetTexture(itemTexture)
				end
				button:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -height)
				height = height + 37
			end
		end

		hideButtons(self, lootCount + 1)
		frame:SetHeight(height)
		if lootCount <= 0 then
			frame:Hide()
		end
	end

	function controller:HideFrame()
		local frame = self.state.frame
		if frame then
			frame:Hide()
		end
	end

	function controller:ToggleFrame()
		local frame = self.state.frame
		if not frame then
			return
		end
		if frame:IsVisible() then
			frame:Hide()
		else
			frame:Show()
		end
	end

	function controller:Reset()
		hideButtons(self)
		self:HideFrame()
	end

	return controller
end

return ItemSelection
