-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: owns warning UI scripts; sends announcements through Services/Chat
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local L = feature.L
local Controllers = feature.Controllers
local coreState = feature.coreState
local Database = feature.Database
local Bus = feature.Bus
local Events = feature.Events

local UI = feature.UI
local Lists = UI.Lists
local Frames = UI.Frames
local Scaffold = UI.Scaffold
local Primitives = UI.Primitives
local EditBoxes = UI.EditBoxes
local Strings = feature.Strings
local Services = feature.Services
local WarningsSvc = assert(Services.Warnings, "Warnings controller service namespace is not initialized")
local WarningStore = assert(WarningsSvc.Store, "Warnings controller store service is not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "Warnings controller event listener is not initialized")
local InternalEvents = assert(Events.Internal, "Warnings controller internal events are not initialized")
local WarningsDataChangedEvent =
	assert(InternalEvents.WarningsDataChanged, "Warnings controller data-changed event is not initialized")

local _G = _G

local tonumber, tostring = tonumber, tostring

local requireServiceMethod = Database.RequireServiceMethod

local Chat = assert(Services.Chat, "Warnings controller chat service is not initialized")
local AnnounceWarningMessage = requireServiceMethod("Chat", Chat, "AnnounceWarningMessage")
local GetStore = requireServiceMethod("Warnings.Store", WarningStore, "GetStore")
local GetWarning = requireServiceMethod("Warnings.Store", WarningStore, "GetWarning")
local EnsureDefaultTemplates = requireServiceMethod("Warnings.Store", WarningStore, "EnsureDefaultTemplates")
local BuildTemplatePreview = requireServiceMethod("Warnings.Store", WarningStore, "BuildTemplatePreview")
local ClearSavedWarnings = requireServiceMethod("Warnings.Store", WarningStore, "ClearSavedWarnings")
local DeleteWarning = requireServiceMethod("Warnings.Store", WarningStore, "DeleteWarning")
local SaveWarning = requireServiceMethod("Warnings.Store", WarningStore, "SaveWarning")

-- =========== Warnings Frame Module  =========== --
do
	Controllers.Warnings = Controllers.Warnings or {}
	local module = Controllers.Warnings
	local uiState = Scaffold.EnsureModuleState(module)

	local getFrame = Frames.MakeModuleFrameGetter(module, "RMAWarnings")
	-- ----- Internal state ----- --
	local fetched = false
	local warningsDirty = false

	local selectedID, tempSelectedID
	local lastSelectedID = false
	local lastEditBtnMode

	local tempName, tempContent
	local saveWarning, editWarning, deleteWarning, announceWarning
	local isEdit = false

	-- ----- Private helpers ----- --

	local function resetWarningState()
		selectedID = nil
		tempSelectedID = nil
		lastSelectedID = false
		lastEditBtnMode = nil
		tempName = nil
		tempContent = nil
		isEdit = false
	end

	RegisterCallback(WarningsDataChangedEvent, function(_, reason)
		if reason == "clear_saved" then
			resetWarningState()
		end
		warningsDirty = true
		fetched = false
		if module.RequestRefresh then
			module:RequestRefresh("data_changed")
		end
	end)

	function uiState.AcquireRefs(frame)
		return {
			name = Frames.GetRef(frame, "Name"),
			content = Frames.GetRef(frame, "Content"),
			editBtn = Frames.GetRef(frame, "EditBtn"),
			deleteBtn = Frames.GetRef(frame, "DeleteBtn"),
			announceBtn = Frames.GetRef(frame, "AnnounceBtn"),
		}
	end

	local function cancelWarning()
		local frameName = uiState.FrameName
		if not frameName then
			return
		end
		EditBoxes.Reset(_G[frameName .. "Name"])
		EditBoxes.Reset(_G[frameName .. "Content"])
		selectedID = nil
		tempSelectedID = nil
		isEdit = false
		module:RequestRefresh()
	end

	local function selectWarning(btn)
		if btn == nil or isEdit == true then
			return
		end
		local bName = btn:GetName()
		local wID = tonumber(_G[bName .. "ID"]:GetText())
		local warning = GetWarning(wID)
		if warning == nil then
			return
		end
		if IsControlKeyDown() then
			selectedID = nil
			tempSelectedID = wID
			return announceWarning(tempSelectedID)
		end
		selectedID = (wID ~= selectedID) and wID or nil
		module:RequestRefresh()
	end

	local function bindWarningRow(row)
		if not row or row._RMABound then
			return
		end
		if row.RegisterForClicks then
			row:RegisterForClicks("LeftButtonUp")
		end
		Frames.SetScriptSafely(row, "OnClick", function(self, button)
			selectWarning(self, button)
		end)
		row._RMABound = true
	end

	-- ----- Public methods ----- --

	local controller = Lists.CreateController({
		keyName = "WarningsList",
		poolTag = "warnings",
		_rowParts = { "ID", "Name" },

		getData = function(out)
			local warnings = GetStore()
			for i = 1, #warnings do
				local w = warnings[i]
				out[i] = { id = i, name = w and w.name or "" }
			end
		end,

		rowName = Lists.MakeIndexedRowName("WarningBtn"),
		rowTmpl = "RMAWarningButtonTemplate",

		drawRow = Lists.CreateRowRenderer(function(row, it)
			bindWarningRow(row)
			local ui = row._p
			ui.ID:SetText(it.id)
			ui.Name:SetText(it.name)
		end),

		highlightId = function()
			return selectedID
		end,
	})

	local function bindWarningsListPanel(frame)
		local frameName = Frames.BindModuleFrame(module, frame, {
			enableDrag = true,
			hookOnShow = function()
				warningsDirty = true
				lastSelectedID = false
			end,
		})
		if not frameName then
			return nil
		end
		if controller.OnLoad then
			controller:OnLoad(frame)
		end
		return frameName
	end

	local function refreshWarningsListPanel()
		local frame = getFrame()
		if not frame then
			return
		end
		uiState.Localize()
		uiState.Refresh()
	end

	local function BindHandlers(_, frame, refs)
		if not (refs and refs.name and refs.content and refs.editBtn and refs.deleteBtn and refs.announceBtn) then
			return
		end
		if refs.editBtn and refs.editBtn.RegisterForClicks then
			refs.editBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		end
		if refs.deleteBtn and refs.deleteBtn.RegisterForClicks then
			refs.deleteBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		end
		if refs.announceBtn and refs.announceBtn.RegisterForClicks then
			refs.announceBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		end
		Frames.HookScriptSafely(frame, "OnShow", function()
			cancelWarning()
		end)
		Frames.HookScriptSafely(frame, "OnHide", function()
			cancelWarning()
		end)
		Frames.SetScriptSafely(refs.announceBtn, "OnClick", function()
			announceWarning()
		end)
		Frames.SetScriptSafely(refs.deleteBtn, "OnClick", function(self, button)
			deleteWarning(self, button)
		end)
		Frames.SetScriptSafely(refs.editBtn, "OnClick", function(self, button)
			editWarning(self, button)
		end)
		Frames.SetScriptSafely(refs.name, "OnTabPressed", function(self)
			local content = Frames.GetRef(self:GetParent(), "Content")
			if content and content.SetFocus then
				content:SetFocus()
			end
		end)
		Frames.SetScriptSafely(refs.content, "OnTabPressed", function(self)
			local name = Frames.GetRef(self:GetParent(), "Name")
			if name and name.SetFocus then
				name:SetFocus()
			end
		end)
	end

	local function OnLoadFrame(frame)
		uiState.FrameName = bindWarningsListPanel(frame)
			or (frame and frame.GetName and frame:GetName() or uiState.FrameName)
		uiState.Loaded = uiState.FrameName ~= nil
		return uiState.FrameName
	end

	Scaffold.DefineModule({
		module = module,
		getFrame = getFrame,
		acquireRefs = uiState.AcquireRefs,
		bind = BindHandlers,
		localize = function()
			uiState.Localize()
		end,
		onLoad = OnLoadFrame,
		refresh = function()
			refreshWarningsListPanel()
		end,
	})

	-- Edit/Save warning:
	function editWarning()
		local wName, wContent
		local frameName = uiState.FrameName
		if not frameName then
			return
		end
		local nameBox = _G[frameName .. "Name"]
		local contentBox = _G[frameName .. "Content"]
		if not (nameBox and contentBox) then
			return
		end
		local draftName = Strings.TrimText(nameBox:GetText())
		local draftContent = Strings.TrimText(contentBox:GetText())

		if selectedID ~= nil then
			local w = GetWarning(selectedID)
			if w == nil then
				selectedID = nil
				return
			end
			if not isEdit and draftName == "" and draftContent == "" then
				nameBox:SetText(w.name)
				nameBox:SetFocus()
				contentBox:SetText(w.content)
				isEdit = true
				module:RequestRefresh()
				return
			end
		end
		wName = nameBox:GetText()
		wContent = contentBox:GetText()
		return saveWarning(wContent, wName, selectedID)
	end

	-- Delete Warning:
	function deleteWarning(btn)
		if btn == nil or selectedID == nil then
			return
		end
		local deleteResult = DeleteWarning(selectedID)
		if deleteResult and deleteResult.deleted ~= true then
			selectedID = nil
			warningsDirty = true
			module:RequestRefresh()
			return
		end
		local count = deleteResult and deleteResult.total or 0
		if count <= 0 then
			selectedID = nil
		elseif count == 1 then
			selectedID = 1
		elseif selectedID > count then
			selectedID = selectedID - 1
		end
		warningsDirty = true
		module:RequestRefresh()
	end

	-- Announce Warning:
	function announceWarning(wID)
		if wID == nil then
			wID = (selectedID ~= nil) and selectedID or tempSelectedID
		end

		wID = tonumber(wID)
		local warning = GetWarning(wID)
		if warning == nil then
			return
		end

		tempSelectedID = nil -- Always clear temporary selected id:

		return AnnounceWarningMessage(Chat, warning.content)
	end

	function module:RequestAnnounce(wID)
		return announceWarning(wID)
	end

	function module:RequestEnsureDefaultTemplates()
		local result = EnsureDefaultTemplates()
		return result
	end

	function module:RequestTemplatePreview()
		return BuildTemplatePreview(L.StrConfigRaidWarningPreviewEmpty or "")
	end

	function module:RequestClearSavedWarnings(includeStock)
		local result = ClearSavedWarnings(includeStock)
		return result
	end

	-- Localizing UI frame:
	function uiState.Localize()
		if uiState.Localized then
			return
		end
		local frameName = uiState.FrameName
		if not frameName then
			return
		end
		_G[frameName .. "NameStr"]:SetText(L.StrName)
		_G[frameName .. "MessageStr"]:SetText(L.StrMessage)
		_G[frameName .. "EditBtn"]:SetText(L.BtnSave)
		_G[frameName .. "DeleteBtn"]:SetText(L.BtnDelete)
		_G[frameName .. "AnnounceBtn"]:SetText(L.BtnAnnounce)
		_G[frameName .. "OutputName"]:SetText(L.StrWarningsHelpTitle)
		Frames.SetFrameTitle(frameName, RAID_WARNING)
		EditBoxes.BindHandlers(frameName, {
			{ suffix = "Name", onEscape = cancelWarning, onEnter = editWarning },
			{ suffix = "Content", onEscape = cancelWarning, onEnter = editWarning },
		}, function()
			module:RequestRefresh()
		end)
		uiState.Localized = true
	end

	local function updateSelectionUI()
		local frameName = uiState.FrameName
		if not frameName then
			return
		end
		local warning = GetWarning(selectedID)
		if warning then
			_G[frameName .. "OutputName"]:SetText(warning.name)
			_G[frameName .. "OutputContent"]:SetText(warning.content)
			_G[frameName .. "OutputContent"]:SetTextColor(1, 1, 1)
		else
			_G[frameName .. "OutputName"]:SetText(L.StrWarningsHelpTitle)
			_G[frameName .. "OutputContent"]:SetText(L.StrWarningsHelpBody)
			_G[frameName .. "OutputContent"]:SetTextColor(0.5, 0.5, 0.5)
		end
		lastSelectedID = selectedID
	end

	-- UI refresh.
	function uiState.Refresh()
		local frameName = uiState.FrameName
		if not frameName then
			return
		end
		if warningsDirty or not fetched then
			controller:Dirty()
			warningsDirty = false
			fetched = true
		end
		if selectedID ~= lastSelectedID then
			updateSelectionUI()
			controller:Touch()
		end
		tempName = _G[frameName .. "Name"]:GetText()
		tempContent = _G[frameName .. "Content"]:GetText()
		Primitives.SetNamedPartEnabled(frameName, "EditBtn", (tempName ~= "" or tempContent ~= "") or selectedID ~= nil)
		Primitives.SetNamedPartEnabled(frameName, "DeleteBtn", selectedID ~= nil)
		Primitives.SetNamedPartEnabled(frameName, "AnnounceBtn", selectedID ~= nil)
		local editBtnMode = (tempName ~= "" or tempContent ~= "") or selectedID == nil
		lastEditBtnMode =
			Primitives.UpdateNamedPartModeText(frameName, "EditBtn", L.BtnSave, L.BtnEdit, editBtnMode, lastEditBtnMode)
	end

	-- Saving a Warning:
	function saveWarning(wContent, wName, wID)
		local frameName = uiState.FrameName
		if not frameName then
			return
		end
		local savedID, reason = SaveWarning(wContent, wName, wID, isEdit)
		if savedID == nil and reason == "empty" then
			addon:error(L.StrWarningsError)
			return
		end
		if savedID == nil then
			return
		end

		EditBoxes.Reset(_G[frameName .. "Name"])
		EditBoxes.Reset(_G[frameName .. "Content"])
		selectedID = savedID
		tempSelectedID = nil
		isEdit = false
		lastSelectedID = false

		warningsDirty = true
		fetched = false
		controller:Dirty()
		module:RequestRefresh()
	end

	if coreState and coreState.warningsSavedVariablesFresh == true then
		module:RequestEnsureDefaultTemplates()
		coreState.warningsSavedVariablesFresh = false
	end
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Controllers/Warnings", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Modules/Bus",
			"Modules/Events",
			"Modules/Strings",
			"Modules/UI/Frames",
			"Modules/UI/Visuals",
			"Modules/UI/ListController",
			"Services/Warnings/Store",
			"Services/Chat",
		},
	})
	registry.SetLoaded("Controllers/Warnings")
end
