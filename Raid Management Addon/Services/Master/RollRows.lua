-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.RollRows
-- events: none
-- notes: pure Master roll row display models and list row adapters
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")
local Services = feature.Services

local RollRows = Master.RollRows or {}
Master.RollRows = RollRows

local tonumber = tonumber
local pairs = pairs
local type = type

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function isSelectableRollRow(row)
	return row and row.selectionAllowed ~= false
end

local function shouldShowRollRow(row)
	return row and (row.roll ~= nil or row.hasExplicitResponse == true)
end

local function buildStarWinnerMap(resolution)
	local starMap = {}

	for i = 1, #(resolution.autoWinners or {}) do
		local winner = resolution.autoWinners[i]
		if winner and winner.name then
			starMap[winner.name] = true
		end
	end

	if not next(starMap) and resolution.requiresManualResolution then
		for i = 1, #(resolution.tiedNames or {}) do
			local name = resolution.tiedNames[i]
			if name and name ~= "" then
				starMap[name] = true
			end
		end
	end

	if not next(starMap) and resolution.topRollName then
		starMap[resolution.topRollName] = true
	end

	return starMap
end

-- ----- Public methods ----- --

function RollRows.BuildListRow(source, id)
	if type(source) ~= "table" then
		return nil
	end

	if id ~= nil then
		source.id = id
	end

	local copy = {}
	for key, value in pairs(source) do
		copy[key] = value
	end

	local specInspect = Services.SpecInspect
	if specInspect and specInspect.GetPlayerSpecSnapshot and copy.name then
		local spec = specInspect:GetPlayerSpecSnapshot(copy.name)
		if spec then
			copy.specIcon = spec.icon
			copy.specName = spec.specName
			copy.specRole = spec.role
		end
	end

	return copy
end

function RollRows.IsSelectableRow(row)
	return isSelectableRollRow(row)
end

function RollRows.BuildSelectionState(opts)
	opts = opts or {}
	local resolution = opts.resolution or {}
	local selectedWinners = opts.selectedWinners or {}
	local requiredWinnerCount = tonumber(opts.requiredWinnerCount) or 1
	local selectionAllowed = opts.selectionAllowed == true
	local mode = opts.mode
	local inventoryMultiSelectMode = opts.fromInventory and (requiredWinnerCount > 1 or mode == "MANUAL_MULTI")
	local pickMode = selectionAllowed and ((not opts.fromInventory) or inventoryMultiSelectMode)
	local selectedNames = {}
	local autoWinner = resolution.autoWinners and resolution.autoWinners[1] or nil
	local autoWinnerName = autoWinner and autoWinner.name or nil
	local msCount = pickMode and #selectedWinners or 0
	local manualEmptySelection = pickMode and mode == "MANUAL_MULTI" and msCount == 0
	local resetSelectionToAuto = false
	local winnerName

	for i = 1, #selectedWinners do
		local winner = selectedWinners[i]
		if winner and winner.name then
			selectedNames[winner.name] = true
		end
	end

	if pickMode then
		if mode == "MANUAL_MULTI" then
			winnerName = selectedWinners[1] and selectedWinners[1].name or nil
		else
			winnerName = autoWinnerName
		end
	else
		if mode == "MANUAL_SINGLE" and selectedWinners[1] and selectedWinners[1].name then
			winnerName = selectedWinners[1].name
		elseif selectionAllowed and resolution.requiresManualResolution and not autoWinnerName then
			winnerName = nil
		else
			if mode == "MANUAL_SINGLE" and not (selectedWinners[1] and selectedWinners[1].name) then
				resetSelectionToAuto = true
			end
			winnerName = autoWinnerName
		end
	end

	local pickName = selectionAllowed and winnerName or nil
	local starTarget = resolution.topRollName
	local highlightTarget = selectionAllowed and (pickName or starTarget) or starTarget
	local singleWinnerSelected = selectionAllowed and not pickMode and winnerName ~= nil and winnerName ~= ""
	if msCount > 0 or singleWinnerSelected or manualEmptySelection then
		highlightTarget = nil
	end

	return {
		highlightTarget = highlightTarget,
		msCount = msCount,
		pickMode = pickMode and true or false,
		selectedNames = selectedNames,
		selectionAllowed = selectionAllowed and true or false,
		resetSelectionToAuto = resetSelectionToAuto,
		singleWinnerSelected = singleWinnerSelected,
		winnerName = winnerName,
	}
end

function RollRows.BuildModel(opts)
	opts = opts or {}
	local baseRows = opts.rows or {}
	local resolution = opts.resolution or {}
	local selectionState = opts.selectionState or {}
	local selectedNames = selectionState.selectedNames or {}
	local starWinners = buildStarWinnerMap(resolution)
	local decoratedRows = {}
	local visibleRows = {}

	for i = 1, #baseRows do
		local row = baseRows[i]
		local isSelected
		local isFocused

		if row then
			isSelected = selectedNames[row.name] == true
				or (selectionState.singleWinnerSelected and selectionState.winnerName == row.name)
			isFocused = (selectionState.highlightTarget and selectionState.highlightTarget == row.name) or false
			row.displayName = (selectionState.selectionAllowed and isSelected) and ("> " .. row.name .. " <")
				or row.name
			row.isSelected = isSelected and true or false
			row.isFocused = isFocused and true or false
			row.canClick = selectionState.selectionAllowed and isSelectableRollRow(row)
			row.showStar = starWinners[row.name] and true or false
			decoratedRows[#decoratedRows + 1] = row

			if opts.showRollsOnly ~= true or shouldShowRollRow(row) then
				visibleRows[#visibleRows + 1] = row
			end
		end
	end

	return decoratedRows, visibleRows
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/RollRows", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
		},
	})
	registry.SetLoaded("Services/Master/RollRows")
end
