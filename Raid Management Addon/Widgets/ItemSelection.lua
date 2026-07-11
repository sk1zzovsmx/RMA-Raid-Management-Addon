-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Widgets.ItemSelection
-- events: none
-- notes: owns Master item-selection child frame creation and inventory cursor acceptance
local addon = select(2, ...)
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

	local wow = assert(opts.wow, "Master item selection WoW API table is not initialized")
	local controller = {
		state = assert(opts.state, "Master item selection state is not initialized"),
		createFrame = assert(opts.createFrame, "Master item selection frame factory is not initialized"),
		getFrame = assert(opts.getFrame, "Master item selection frame resolver is not initialized"),
		getFrameName = assert(opts.getFrameName, "Master item selection frame-name resolver is not initialized"),
		getNamedParts = assert(opts.getNamedParts, "Master item selection named-parts resolver is not initialized"),
		setScriptSafely = assert(opts.setScriptSafely, "Master item selection script binder is not initialized"),
		getSelectItemButton = assert(
			opts.getSelectItemButton,
			"Master item selection anchor-button resolver is not initialized"
		),
		clearItemCountInput = assert(
			opts.clearItemCountInput,
			"Master item selection item-count resetter is not initialized"
		),
		getLootItem = assert(opts.getLootItem, "Master item selection loot-item resolver is not initialized"),
		getLootItemName = assert(
			opts.getLootItemName,
			"Master item selection loot-item-name resolver is not initialized"
		),
		getLootItemTexture = assert(
			opts.getLootItemTexture,
			"Master item selection loot-item-texture resolver is not initialized"
		),
		addLootItem = assert(opts.addLootItem, "Master item selection loot-item adder is not initialized"),
		prepareLootItem = assert(opts.prepareLootItem, "Master item selection loot-item preparer is not initialized"),
		inventory = assert(opts.inventory, "Master item selection inventory owner is not initialized"),
		lootState = assert(opts.lootState, "Master item selection loot state is not initialized"),
		itemInfo = assert(opts.itemInfo, "Master item selection item state is not initialized"),
		isCountdownRunning = assert(
			opts.isCountdownRunning,
			"Master item selection countdown-state resolver is not initialized"
		),
		onSelectLootItem = assert(
			opts.onSelectLootItem,
			"Master item selection row-selection callback is not initialized"
		),
		onInventoryItemApplied = assert(
			opts.onInventoryItemApplied,
			"Master item selection post-apply callback is not initialized"
		),
		setAnnounced = assert(opts.setAnnounced, "Master item selection announce-state setter is not initialized"),
		L = assert(opts.L, "Master item selection localized strings are not initialized"),
		wow = {
			ClearCursor = assert(wow.ClearCursor, "Master item selection clear-cursor API is not initialized"),
			CursorHasItem = assert(wow.CursorHasItem, "Master item selection cursor-item API is not initialized"),
			GetCursorInfo = assert(wow.GetCursorInfo, "Master item selection cursor-info API is not initialized"),
			GetContainerItemLink = assert(
				wow.GetContainerItemLink,
				"Master item selection container-item-link API is not initialized"
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
