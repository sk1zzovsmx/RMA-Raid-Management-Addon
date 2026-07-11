-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Services.Master.RollSelection
-- events: none
-- notes: owns Master roll winner selection state and display model assembly
local addon = select(2, ...)
local Master = addon.Services.EnsureNamespace("Master")

local RollSelection = Master.RollSelection or {}
Master.RollSelection = RollSelection

local type = type
local tonumber = tonumber
local tostring = tostring
local select = select

local IsControlKeyDown = IsControlKeyDown

local ROLL_WINNERS_CTX = "MLRollWinners"
local MODE = {
	AUTO = "AUTO",
	MANUAL_SINGLE = "MANUAL_SINGLE",
	MANUAL_MULTI = "MANUAL_MULTI",
}

RollSelection.ContextKey = ROLL_WINNERS_CTX
RollSelection.Mode = MODE

local function getState(controller)
	local state = controller.state
	state.mode = state.mode or MODE.AUTO
	state.showRollsOnly = state.showRollsOnly ~= false
	return state
end

local function getSelection(controller)
	return controller.selection
end

local function isFromInventory(controller)
	local resolver = controller.isFromInventory
	return type(resolver) == "function" and resolver() == true
end

local function getDisplayModel(controller)
	local resolver = controller.getDisplayModel
	if type(resolver) ~= "function" then
		return {}
	end
	return resolver() or {}
end

local function getSessionKey(controller)
	local resolver = controller.getSessionKey
	if type(resolver) ~= "function" then
		return nil
	end
	local sessionKey = resolver()
	return sessionKey and tostring(sessionKey) or nil
end

local function isSelectableRow(controller, row)
	local rollRows = controller.rollRows
	if rollRows and type(rollRows.IsSelectableRow) == "function" then
		return rollRows.IsSelectableRow(row)
	end
	return row and row.selectionAllowed ~= false
end

local function resetSelection(controller, mode)
	local selection = getSelection(controller)
	local state = getState(controller)
	selection.EnsureState(ROLL_WINNERS_CTX)
	selection.SetAnchor(ROLL_WINNERS_CTX, nil)
	state.mode = mode or MODE.AUTO
	state.model = nil
end

local function getSelectedOrdered(controller, rows)
	local selection = getSelection(controller)
	local selected = {}
	if type(rows) ~= "table" then
		return selected
	end

	for i = 1, #rows do
		local row = rows[i]
		if
			row
			and row.name
			and isSelectableRow(controller, row)
			and selection.IsSelected(ROLL_WINNERS_CTX, row.name)
		then
			selected[#selected + 1] = {
				name = row.name,
				roll = tonumber(row.roll) or 0,
			}
		end
	end

	return selected
end

local function replaceSelection(controller, names, mode)
	local selection = getSelection(controller)
	local lastName = nil

	resetSelection(controller, mode)
	if type(names) ~= "table" then
		return 0
	end

	for i = 1, #names do
		local name = names[i]
		if type(name) == "string" and name ~= "" then
			selection.Toggle(ROLL_WINNERS_CTX, name, true)
			lastName = name
		end
	end

	selection.SetAnchor(ROLL_WINNERS_CTX, lastName)
	return selection.GetCount(ROLL_WINNERS_CTX) or 0
end

local function pruneSelection(controller, rows)
	local selection = getSelection(controller)
	local valid = {}
	local selected = selection.GetSelected(ROLL_WINNERS_CTX) or {}
	local changed = false
	local ordered

	if type(rows) ~= "table" then
		return 0
	end

	for i = 1, #rows do
		local row = rows[i]
		if row and row.name and isSelectableRow(controller, row) then
			valid[row.name] = true
		end
	end

	for i = 1, #selected do
		local name = selected[i]
		if not valid[name] then
			selection.Toggle(ROLL_WINNERS_CTX, name, true)
			changed = true
		end
	end

	if changed then
		ordered = getSelectedOrdered(controller, rows)
		selection.SetAnchor(ROLL_WINNERS_CTX, ordered[#ordered] and ordered[#ordered].name or nil)
	end

	return selection.GetCount(ROLL_WINNERS_CTX) or 0
end

local function applySelection(controller, name, pickMode, maxSel)
	local selection = getSelection(controller)
	local state = getState(controller)
	local isMulti
	local isSelected
	local currentCount

	if not name or name == "" then
		return false
	end

	if not pickMode then
		selection.Toggle(ROLL_WINNERS_CTX, name, false, false)
		selection.SetAnchor(ROLL_WINNERS_CTX, name)
		state.mode = MODE.MANUAL_SINGLE
		return true
	end

	isMulti = selection.ResolveModifiers
			and select(1, selection.ResolveModifiers(ROLL_WINNERS_CTX, { allowRange = false }))
		or ((IsControlKeyDown and IsControlKeyDown()) or false)
	isSelected = selection.IsSelected(ROLL_WINNERS_CTX, name)
	currentCount = selection.GetCount(ROLL_WINNERS_CTX) or 0

	if isMulti then
		if (not isSelected) and currentCount >= maxSel then
			if maxSel == 1 then
				replaceSelection(controller, { name }, MODE.MANUAL_MULTI)
				return true
			end
			if type(controller.warnTooMany) == "function" then
				controller.warnTooMany(maxSel)
			end
			return false
		end
		selection.Toggle(ROLL_WINNERS_CTX, name, true, true)
	else
		selection.Toggle(ROLL_WINNERS_CTX, name, false, false)
	end

	state.mode = MODE.MANUAL_MULTI
	if (selection.GetCount(ROLL_WINNERS_CTX) or 0) > 0 then
		selection.SetAnchor(ROLL_WINNERS_CTX, name)
	else
		selection.SetAnchor(ROLL_WINNERS_CTX, nil)
	end
	return true
end

local function syncSelectionState(controller, baseRows, resolution, selectionAllowed, requiredWinnerCount)
	local selection = getSelection(controller)
	local state = getState(controller)
	local fromInventory = isFromInventory(controller)
	local selectionState

	if selectionAllowed then
		pruneSelection(controller, baseRows)
	elseif (selection.GetCount(ROLL_WINNERS_CTX) or 0) > 0 then
		resetSelection(controller, MODE.AUTO)
	end

	local inventoryMultiSelectMode = fromInventory and (requiredWinnerCount > 1 or state.mode == MODE.MANUAL_MULTI)
	local pickMode = selectionAllowed and ((not fromInventory) or inventoryMultiSelectMode)

	if pickMode and state.mode == MODE.AUTO then
		local prefillNames = {}
		for i = 1, #(resolution.autoWinners or {}) do
			local winner = resolution.autoWinners[i]
			if winner and winner.name then
				prefillNames[#prefillNames + 1] = winner.name
			end
		end
		replaceSelection(controller, prefillNames, MODE.AUTO)
	elseif not pickMode and state.mode ~= MODE.MANUAL_SINGLE and (selection.GetCount(ROLL_WINNERS_CTX) or 0) > 0 then
		resetSelection(controller, MODE.AUTO)
	end

	selectionState = controller.rollRows.BuildSelectionState({
		fromInventory = fromInventory,
		mode = state.mode,
		resolution = resolution,
		requiredWinnerCount = requiredWinnerCount,
		selectedWinners = getSelectedOrdered(controller, baseRows),
		selectionAllowed = selectionAllowed and true or false,
	})
	if selectionState.resetSelectionToAuto then
		resetSelection(controller, MODE.AUTO)
	end
	return selectionState
end

local function syncSession(controller)
	local state = getState(controller)
	local sessionKey = getSessionKey(controller)
	if state.sessionKey == sessionKey then
		return sessionKey
	end
	resetSelection(controller, MODE.AUTO)
	state.sessionKey = sessionKey
	return sessionKey
end

function RollSelection.CreateController(opts)
	opts = opts or {}
	local controller = {
		getDisplayModel = assert(
			opts.getDisplayModel,
			"Master RollSelection display model resolver is not initialized"
		),
		getSessionKey = opts.getSessionKey,
		isSelectionBlocked = opts.isSelectionBlocked,
		isFromInventory = opts.isFromInventory,
		onSelectionBlocked = opts.onSelectionBlocked,
		rollRows = assert(opts.rollRows, "Master RollSelection row model owner is not initialized"),
		selection = assert(opts.selection, "Master RollSelection selection owner is not initialized"),
		state = assert(opts.state, "Master RollSelection state table is not initialized"),
		warnTooMany = opts.warnTooMany,
	}

	function controller:ResetSelection(mode)
		return resetSelection(self, mode)
	end

	function controller:Invalidate()
		getState(self).model = nil
	end

	function controller:GetSelectedCount()
		return getSelection(self).GetCount(ROLL_WINNERS_CTX) or 0
	end

	function controller:ClearAnchor()
		local selection = getSelection(self)
		selection.EnsureState(ROLL_WINNERS_CTX)
		selection.SetAnchor(ROLL_WINNERS_CTX, nil)
	end

	function controller:DeselectWinner(name)
		local selection = getSelection(self)
		if name and selection.IsSelected(ROLL_WINNERS_CTX, name) then
			selection.Toggle(ROLL_WINNERS_CTX, name, true)
			if selection.GetAnchor and selection.GetAnchor(ROLL_WINNERS_CTX) == name then
				selection.SetAnchor(ROLL_WINNERS_CTX, nil)
			end
			self:Invalidate()
			return true
		end
		return false
	end

	function controller:GetSelectedWinnersOrdered(rows)
		return getSelectedOrdered(self, rows)
	end

	function controller:BuildModel(forceRefresh)
		local state = getState(self)
		if forceRefresh ~= true and state.model then
			return state.model
		end

		local model = getDisplayModel(self)
		local baseRows = model.rows or {}
		local resolution = model.resolution or {}
		local selectionAllowed = model.selectionAllowed == true
		local requiredWinnerCount = tonumber(model.requiredWinnerCount) or 1

		syncSession(self)
		local selectionState = syncSelectionState(self, baseRows, resolution, selectionAllowed, requiredWinnerCount)
		local decoratedRows, visibleRows = self.rollRows.BuildModel({
			rows = baseRows,
			resolution = resolution,
			selectionState = selectionState,
			showRollsOnly = state.showRollsOnly == true,
		})

		model.rows = decoratedRows
		model.visibleRows = visibleRows
		model.pickMode = selectionState.pickMode
		model.msCount = selectionState.msCount
		model.highlightTarget = selectionState.highlightTarget
		model.winner = selectionState.winnerName
		model.selectionAllowed = selectionState.selectionAllowed
		model.showRollsOnly = state.showRollsOnly == true
		state.model = model
		return model
	end

	function controller:SelectWinnerRow(name)
		local model = self:BuildModel(true)
		local rows = model and model.rows or {}
		local requiredWinnerCount = tonumber(model and model.requiredWinnerCount) or 1
		local pickMode = model and model.pickMode == true
		local maxSel = requiredWinnerCount
		local row

		if not (model and model.selectionAllowed == true) then
			return false
		end

		if type(self.isSelectionBlocked) == "function" and self.isSelectionBlocked() then
			if type(self.onSelectionBlocked) == "function" then
				self.onSelectionBlocked()
			end
			return false
		end

		for i = 1, #rows do
			if rows[i] and rows[i].name == name then
				row = rows[i]
				break
			end
		end

		if not isSelectableRow(self, row) then
			return false
		end

		if maxSel > #rows then
			maxSel = #rows
		end
		if maxSel < 1 then
			maxSel = 1
		end

		if not applySelection(self, name, pickMode, maxSel) then
			return false
		end

		self:Invalidate()
		self:BuildModel()
		return true
	end

	function controller:CopyVisibleRows(out)
		local state = getState(self)
		local model = state.model
		local visibleRows = model and model.visibleRows or {}

		for i = 1, #visibleRows do
			local source = visibleRows[i]
			if source then
				local copy = self.rollRows.BuildListRow(source, i)
				if copy then
					out[#out + 1] = copy
				end
			end
		end
	end

	function controller:GetFocusedRowId()
		local state = getState(self)
		local model = state.model
		local visibleRows = model and model.visibleRows or nil

		if type(visibleRows) ~= "table" then
			return nil
		end

		for i = 1, #visibleRows do
			local row = visibleRows[i]
			if row and row.isFocused == true then
				return i
			end
		end

		return nil
	end

	function controller:GetVisibleRows()
		local state = getState(self)
		local model = state.model
		return model and model.visibleRows or nil
	end

	return controller
end
