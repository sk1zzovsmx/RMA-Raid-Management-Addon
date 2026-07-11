-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.UI.Frames/Scaffold/ModuleState/EditBoxes/Popups/Tooltips/ExportDialog
-- events: none; owns shared refresh driver
-- ui ownership: Lua owns frame binding, named-reference resolution, scripts, and refresh drivers.

local addon = select(2, ...)
local type = type
local format = string.format
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local strsub = string.sub

local _G = _G
local CreateFrame = assert(_G.CreateFrame, "UI frame creation API is not initialized")
local InCombatLockdown = assert(_G.InCombatLockdown, "UI combat-lockdown API is not initialized")

local C = addon.C
local Strings = addon.Strings
local coreState = addon.State
local TrimText = assert(Strings.TrimText, "UI edit-box text normalizer is not initialized")

local UI = addon.UI or {}
local Frames = UI.Frames or {}
UI.Frames = Frames

local Scaffold = UI.Scaffold or {}
UI.Scaffold = Scaffold

local ModuleState = UI.ModuleState or {}
UI.ModuleState = ModuleState

local EditBoxes = UI.EditBoxes or {}
local ExportDialog = UI.ExportDialog or {}
UI.ExportDialog = ExportDialog
UI.EditBoxes = EditBoxes

local Popups = UI.Popups or {}
UI.Popups = Popups

local Tooltips = UI.Tooltips or {}
UI.Tooltips = Tooltips
local tooltipColor = HIGHLIGHT_FONT_COLOR or { r = 1, g = 1, b = 1 }

-- ----- Internal state ----- --
local stateByModule = setmetatable({}, { __mode = "k" })

-- ----- Private helpers ----- --
local function resolveFrameName(frameOrName)
	if type(frameOrName) == "string" then
		return frameOrName
	end
	if frameOrName and frameOrName.GetName then
		return frameOrName:GetName()
	end
	return nil
end

local function isModuleUiBound(module, uiState)
	return uiState and uiState.Bound and module and module.frame and module.refs
end

-- ----- Public methods ----- --
local function createModuleState()
	return {
		Loaded = false,
		Bound = false,
		Localized = false,
		Dirty = true,
		Reason = nil,
		FrameName = nil,
	}
end

function ModuleState.Ensure(module)
	if type(module) ~= "table" then
		return nil
	end

	local uiState = stateByModule[module]
	if not uiState then
		uiState = createModuleState()
		stateByModule[module] = uiState
	end
	return uiState
end

function ModuleState.MarkDirty(module, reason)
	local uiState = ModuleState.Ensure(module)
	if not uiState then
		return nil
	end

	uiState.Dirty = true
	if reason then
		uiState.Reason = reason
	end
	return uiState
end

function Frames.EnableDrag(frame, dragButton)
	if not frame or not frame.RegisterForDrag then
		return
	end
	if frame.SetMovable then
		frame:SetMovable(true)
	end
	if frame.EnableMouse then
		frame:EnableMouse(true)
	end
	if frame.SetClampedToScreen then
		frame:SetClampedToScreen(true)
	end

	if frame.GetScript then
		if not frame:GetScript("OnDragStart") then
			Frames.SetScriptSafely(frame, "OnDragStart", function(self)
				if InCombatLockdown() then
					return
				end
				if self.StartMoving then
					self:StartMoving()
				end
			end)
		end
		if not frame:GetScript("OnDragStop") then
			Frames.SetScriptSafely(frame, "OnDragStop", function(self)
				if InCombatLockdown() then
					return
				end
				if self.StopMovingOrSizing then
					self:StopMovingOrSizing()
				end
			end)
		end
	end

	frame:RegisterForDrag(dragButton or "LeftButton")
end

function Popups.DefineConfirm(key, text, onAccept, cancels, options)
	options = options or {}
	return Popups.Define(key, {
		text = text,
		button1 = options.button1 or OKAY,
		button2 = options.button2 or CANCEL,
		button3 = options.button3,
		OnAccept = onAccept,
		OnCancel = options.onCancel,
		cancels = cancels or key,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
		preferredIndex = options.preferredIndex,
	})
end

function Popups.Define(key, dialog)
	if type(StaticPopupDialogs) ~= "table" or type(dialog) ~= "table" then
		return false
	end
	StaticPopupDialogs[key] = dialog
	return true
end

function Popups.IsDefined(key)
	return type(StaticPopupDialogs) == "table" and StaticPopupDialogs[key] ~= nil
end

function Popups.Show(key, textArg1, textArg2, data)
	if type(StaticPopup_Show) ~= "function" then
		return false
	end
	StaticPopup_Show(key, textArg1, textArg2, data)
	return true
end

function Popups.Hide(key)
	if type(StaticPopup_Hide) ~= "function" then
		return false
	end
	StaticPopup_Hide(key)
	return true
end

function Popups.Resize(dialog, key)
	if type(StaticPopup_Resize) ~= "function" then
		return false
	end
	StaticPopup_Resize(dialog, key)
	return true
end

function Popups.ShowConfirm(key, text, onAccept, cancels, options)
	if type(StaticPopupDialogs) ~= "table" then
		return false
	end
	if not StaticPopupDialogs[key] then
		Popups.DefineConfirm(key, text, onAccept, cancels, options)
	end
	return Popups.Show(key)
end

function Popups.DefineEditBox(key, text, onAccept, onShow, validate)
	return Popups.Define(key, {
		text = text,
		button1 = SAVE,
		button2 = CANCEL,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
		hasEditBox = 1,
		cancels = key,
		OnShow = function(self)
			if onShow then
				onShow(self)
			end
		end,
		OnHide = function(self)
			self.editBox:SetText("")
			self.editBox:ClearFocus()
		end,
		OnAccept = function(self)
			local value = TrimText(self.editBox:GetText(), true)
			if validate then
				local ok, cleanValue = validate(self, value)
				if not ok then
					return
				end
				if cleanValue ~= nil then
					value = cleanValue
				end
			end
			onAccept(self, value)
		end,
	})
end

function Popups.ShowEditBox(key, text, onAccept, onShow, validate)
	if type(StaticPopupDialogs) ~= "table" then
		return false
	end
	if not StaticPopupDialogs[key] then
		Popups.DefineEditBox(key, text, onAccept, onShow, validate)
	end
	return Popups.Show(key)
end

function Frames.SetFrameTitle(frameOrName, titleText, titleFormat)
	local frameName = resolveFrameName(frameOrName)
	if not frameName then
		return
	end
	local titleFrame = _G[frameName .. "Title"]
	if not titleFrame then
		return
	end
	local fmt = titleFormat or (C and C.titleString) or "%s"
	titleFrame:SetText(format(fmt, titleText))
end

function EditBoxes.Reset(editBox, hide)
	if not editBox then
		return
	end
	editBox:SetText("")
	editBox:ClearFocus()
	if hide then
		editBox:Hide()
	end
end

function EditBoxes.SetValue(editBox, value, focus)
	if not editBox then
		return
	end
	editBox:SetText(value)
	editBox:Show()
	if focus then
		editBox:SetFocus()
	end
end

function Frames.SetShown(frame, show)
	if not frame then
		return
	end
	if show then
		if not frame:IsShown() then
			frame:Show()
		end
	elseif frame:IsShown() then
		frame:Hide()
	end
end

function Frames.Get(frameName)
	if type(frameName) ~= "string" or frameName == "" then
		return nil
	end
	return _G[frameName]
end

function Frames.GetRef(frameOrName, childName)
	local frameName = resolveFrameName(frameOrName)
	if type(frameName) ~= "string" or frameName == "" then
		return nil
	end
	if type(childName) ~= "string" or childName == "" then
		return nil
	end

	if strsub(childName, 1, #frameName) == frameName then
		return _G[childName]
	end

	local exact = _G[childName]
	if exact then
		return exact
	end

	return _G[frameName .. childName]
end

function Frames.GetNamedParts(widget, parts, cacheField)
	if not widget or type(parts) ~= "table" then
		return nil
	end

	cacheField = cacheField or "_RMARefs"
	if widget[cacheField] then
		return widget[cacheField]
	end

	local widgetName = widget.GetName and widget:GetName() or nil
	local refs = {}

	for key, suffix in pairs(parts) do
		local refKey = type(key) == "number" and suffix or key
		refs[refKey] = widgetName and _G[widgetName .. suffix] or nil
	end

	widget[cacheField] = refs
	return refs
end

function Frames.SetScriptSafely(widget, scriptType, handler)
	if not widget or not widget.SetScript then
		return false
	end
	if type(scriptType) ~= "string" or scriptType == "" then
		return false
	end
	if handler ~= nil and type(handler) ~= "function" then
		if coreState and coreState.debugEnabled then
			error("Frames.SetScriptSafely: handler must be a function or nil")
		end
		return false
	end

	widget:SetScript(scriptType, handler)
	return true
end

function Frames.HookScriptSafely(widget, scriptType, handler)
	if not widget then
		return false
	end
	if type(scriptType) ~= "string" or scriptType == "" then
		return false
	end
	if type(handler) ~= "function" then
		if coreState and coreState.debugEnabled then
			error("Frames.HookScriptSafely: handler must be a function")
		end
		return false
	end
	if widget.HookScript then
		widget:HookScript(scriptType, handler)
		return true
	end
	return Frames.SetScriptSafely(widget, scriptType, handler)
end

local function showTooltip(frame)
	if not frame.tooltip_anchor then
		GameTooltip_SetDefaultAnchor(GameTooltip, frame)
	else
		GameTooltip:SetOwner(frame, frame.tooltip_anchor)
	end

	if frame.tooltip_title then
		GameTooltip:SetText(frame.tooltip_title)
	end

	if frame.tooltip_text then
		if type(frame.tooltip_text) == "string" then
			GameTooltip:AddLine(frame.tooltip_text, tooltipColor.r, tooltipColor.g, tooltipColor.b, true)
		elseif type(frame.tooltip_text) == "table" then
			for _, line in ipairs(frame.tooltip_text) do
				GameTooltip:AddLine(line, tooltipColor.r, tooltipColor.g, tooltipColor.b, true)
			end
		end
	end

	if frame.tooltip_item then
		GameTooltip:SetHyperlink(frame.tooltip_item)
	end

	GameTooltip:Show()
end

local function addTooltipLine(text, color, wrap)
	if not text or not GameTooltip or not GameTooltip.AddLine then
		return false
	end

	local r = color and color[1] or tooltipColor.r
	local g = color and color[2] or tooltipColor.g
	local b = color and color[3] or tooltipColor.b
	GameTooltip:AddLine(text, r, g, b, wrap ~= false)
	return true
end

function Tooltips.Hide()
	GameTooltip:Hide()
end

function Tooltips.ShowLines(owner, model)
	if not owner or type(model) ~= "table" or not GameTooltip then
		return false
	end

	local hasContent = false
	if model.title and model.title ~= "" then
		hasContent = true
	end
	if model.heading and model.heading ~= "" then
		hasContent = true
	end
	if type(model.lines) == "table" and #model.lines > 0 then
		hasContent = true
	end
	if not hasContent then
		return false
	end

	local anchor = model.anchor or "ANCHOR_CURSOR"
	if model.defaultAnchor and type(GameTooltip_SetDefaultAnchor) == "function" then
		GameTooltip_SetDefaultAnchor(GameTooltip, owner)
	else
		GameTooltip:SetOwner(owner, anchor)
	end
	if model.title and model.title ~= "" then
		addTooltipLine(model.title, model.titleColor, model.wrap)
	end
	if model.heading and model.heading ~= "" then
		addTooltipLine(model.heading, model.headingColor, model.wrap)
	end
	if type(model.lines) == "table" then
		for i = 1, #model.lines do
			local line = model.lines[i]
			if type(line) == "table" then
				addTooltipLine(line.text, line.color, line.wrap)
			elseif line and line ~= "" then
				addTooltipLine(line, model.lineColor, model.wrap)
			end
		end
	end

	if GameTooltip.Show then
		GameTooltip:Show()
	end
	return true
end

function Tooltips.ShowItem(owner, itemLink, fallbackTitle, anchor, details)
	if not owner or not GameTooltip then
		return false
	end

	local hasItem = type(itemLink) == "string" and itemLink ~= ""
	local hasTitle = type(fallbackTitle) == "string" and fallbackTitle ~= ""
	local hasDetails = type(details) == "table"
	if not hasItem and not hasTitle and not hasDetails then
		return false
	end

	GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
	if hasItem then
		GameTooltip:SetHyperlink(itemLink)
	else
		GameTooltip:SetText(fallbackTitle, 1, 1, 1)
	end
	if hasDetails then
		if details.spacer then
			addTooltipLine(" ", details.spacerColor, false)
		end
		if details.heading and details.heading ~= "" then
			addTooltipLine(details.heading, details.headingColor, details.wrap)
		end
		if type(details.lines) == "table" then
			for i = 1, #details.lines do
				local line = details.lines[i]
				if type(line) == "table" then
					addTooltipLine(line.text, line.color, line.wrap)
				elseif line and line ~= "" then
					addTooltipLine(line, details.lineColor, details.wrap)
				end
			end
		end
	end
	GameTooltip:Show()
	return true
end

function Tooltips.PrimeItemInfo(itemId)
	local id = tonumber(itemId)
	if not id or not GameTooltip then
		return false
	end

	GameTooltip:SetOwner(_G.UIParent, "ANCHOR_NONE")
	GameTooltip:SetHyperlink("item:" .. id)
	GameTooltip:Hide()
	return true
end

function Tooltips.BindModel(frame, modelProvider, anchor)
	if not frame or type(modelProvider) ~= "function" then
		return false
	end

	frame._RMATooltipModelProvider = modelProvider
	frame._RMATooltipAnchor = anchor
	Frames.SetScriptSafely(frame, "OnEnter", function(self)
		local model = self._RMATooltipModelProvider and self._RMATooltipModelProvider(self) or nil
		if type(model) ~= "table" then
			return
		end
		if model.anchor == nil and self._RMATooltipAnchor then
			model.anchor = self._RMATooltipAnchor
		end
		Tooltips.ShowLines(self, model)
	end)
	Frames.SetScriptSafely(frame, "OnLeave", Tooltips.Hide)
	return true
end

function Tooltips.Bind(frame, text, anchor, title)
	if not frame then
		return
	end
	frame.tooltip_text = text and text or frame.tooltip_text
	frame.tooltip_anchor = anchor and anchor or frame.tooltip_anchor
	frame.tooltip_title = title and title or frame.tooltip_title
	if not frame.tooltip_title and not frame.tooltip_text and not frame.tooltip_item then
		return
	end
	Frames.SetScriptSafely(frame, "OnEnter", showTooltip)
	Frames.SetScriptSafely(frame, "OnLeave", Tooltips.Hide)
end

function Frames.MakeEventDrivenRefresher(targetOrGetter, updateFn)
	if type(updateFn) ~= "function" then
		error("Frames.MakeEventDrivenRefresher: updateFn must be a function")
	end

	local driver = CreateFrame("Frame")
	local pending = false
	local dirtyWhileHidden = false
	local hookedFrame = nil

	local function resolveTarget()
		if type(targetOrGetter) == "function" then
			return targetOrGetter()
		end
		return targetOrGetter
	end

	local function ensureHook(target)
		if not target then
			return
		end
		if hookedFrame == target then
			return
		end
		hookedFrame = target
		Frames.HookScriptSafely(target, "OnShow", function()
			if dirtyWhileHidden then
				dirtyWhileHidden = false
				updateFn()
			end
		end)
	end

	local function run()
		Frames.SetScriptSafely(driver, "OnUpdate", nil)
		pending = false

		local target = resolveTarget()
		if not target or not target.IsShown or not target:IsShown() then
			dirtyWhileHidden = true
			if target then
				ensureHook(target)
			end
			return
		end
		updateFn()
	end

	return function()
		local target = resolveTarget()
		if not target then
			return
		end
		ensureHook(target)

		if not target:IsShown() then
			dirtyWhileHidden = true
			return
		end

		if pending then
			return
		end
		pending = true
		Frames.SetScriptSafely(driver, "OnUpdate", run)
	end
end

function Frames.MakeFrameGetter(globalFrameName)
	local cached = nil
	return function()
		if cached then
			return cached
		end
		local frame = _G[globalFrameName]
		if frame then
			cached = frame
		end
		return frame
	end
end

function Frames.MakeModuleFrameGetter(module, globalFrameName)
	local getGlobalFrame = Frames.MakeFrameGetter(globalFrameName)
	return function()
		local frame = module.frame or getGlobalFrame()
		if frame and not module.frame then
			module.frame = frame
		end
		return frame
	end
end

function Frames.BindModuleFrame(module, frame, opts)
	if not frame then
		return nil
	end
	if module then
		module.frame = frame
	end

	local frameName = frame:GetName()
	opts = opts or {}

	if opts.enableDrag then
		Frames.EnableDrag(frame, opts.dragButton)
	end

	if opts.hookOnShow then
		Frames.HookScriptSafely(frame, "OnShow", opts.hookOnShow)
	end
	if opts.hookOnHide then
		Frames.HookScriptSafely(frame, "OnHide", opts.hookOnHide)
	end

	return frameName
end

local function makeUIFrameController(getFrame, requestRefreshFn)
	local function showFrame(frame)
		if requestRefreshFn then
			requestRefreshFn()
		end
		Frames.SetShown(frame, true)
	end

	return {
		Toggle = function(self)
			local frame = getFrame()
			if not frame then
				return
			end
			if frame:IsShown() then
				Frames.SetShown(frame, false)
			else
				showFrame(frame)
			end
		end,
		Hide = function(self)
			local frame = getFrame()
			if frame then
				Frames.SetShown(frame, false)
			end
		end,
		Show = function(self)
			local frame = getFrame()
			if frame then
				showFrame(frame)
			end
		end,
	}
end

local function validateScaffoldConfig(module, getFrame, acquireRefs, bindHandlers, localize, onLoadFrame, refreshFn)
	if type(module) ~= "table" then
		error("UI.Scaffold.DefineModule: cfg.module must be a table")
	end
	if type(getFrame) ~= "function" then
		error("UI.Scaffold.DefineModule: cfg.getFrame must be a function")
	end
	if acquireRefs and type(acquireRefs) ~= "function" then
		error("UI.Scaffold.DefineModule: cfg.acquireRefs must be a function")
	end
	if bindHandlers and type(bindHandlers) ~= "function" then
		error("UI.Scaffold.DefineModule: cfg.bind must be a function")
	end
	if localize and type(localize) ~= "function" then
		error("UI.Scaffold.DefineModule: cfg.localize must be a function")
	end
	if onLoadFrame and type(onLoadFrame) ~= "function" then
		error("UI.Scaffold.DefineModule: cfg.onLoad must be a function")
	end
	if refreshFn and type(refreshFn) ~= "function" then
		error("UI.Scaffold.DefineModule: cfg.refresh must be a function")
	end
end

local function dispatchModuleRefresh(module, refreshFn, uiState, frame, refs, dirty, reason)
	if refreshFn then
		return refreshFn(uiState.FrameName, frame, refs, dirty, reason)
	end
	if type(module.RefreshUI) == "function" then
		return module:RefreshUI(uiState.FrameName, frame, refs, dirty, reason)
	end
	if type(module.Refresh) == "function" then
		return module:Refresh(dirty, reason)
	end
end

local function loadModuleFrame(module, frame, uiState, onLoadFrame, initFrameOpts)
	if uiState.Loaded then
		return uiState.FrameName
	end

	local frameName
	if onLoadFrame then
		frameName = onLoadFrame(frame)
	else
		frameName = Frames.BindModuleFrame(module, frame, initFrameOpts)
	end

	uiState.FrameName = frameName or (frame.GetName and frame:GetName()) or uiState.FrameName
	uiState.Loaded = uiState.FrameName ~= nil

	return uiState.FrameName
end

local function acquireModuleRefs(frame, frameName, acquireRefs)
	return acquireRefs and acquireRefs(frame, frameName) or {}
end

function Scaffold.DefineModule(cfg)
	cfg = cfg or {}
	local module = cfg.module
	local getFrame = cfg.getFrame
	local acquireRefs = cfg.acquireRefs
	local bindHandlers = cfg.bind
	local localize = cfg.localize
	local onLoadFrame = cfg.onLoad
	local initFrameOpts = cfg.initFrameOpts
	local refreshFn = cfg.refresh
	validateScaffoldConfig(module, getFrame, acquireRefs, bindHandlers, localize, onLoadFrame, refreshFn)

	local uiState = ModuleState.Ensure(module)

	local function doRefresh()
		local frame = getFrame()
		if not frame then
			return
		end

		local dirty = uiState.Dirty
		local reason = uiState.Reason
		uiState.Dirty = false
		uiState.Reason = nil

		local refs = module.refs
		return dispatchModuleRefresh(module, refreshFn, uiState, frame, refs, dirty, reason)
	end

	local requestRefresh = Frames.MakeEventDrivenRefresher(getFrame, doRefresh)

	function module:MarkDirty(reason)
		ModuleState.MarkDirty(module, reason)
	end

	function module:RequestRefresh(reason)
		self:MarkDirty(reason)
		requestRefresh()
	end

	local uiController = makeUIFrameController(getFrame, function()
		module:RequestRefresh("toggle")
	end)

	function module:BindUI()
		if isModuleUiBound(self, uiState) then
			return self.frame, self.refs
		end

		local frame = getFrame()
		if not frame then
			return nil
		end

		if not uiState.Loaded then
			loadModuleFrame(module, frame, uiState, onLoadFrame, initFrameOpts)
		end

		local refs = acquireModuleRefs(frame, uiState.FrameName, acquireRefs)
		self.frame = frame
		self.refs = refs

		if bindHandlers then
			bindHandlers(uiState.FrameName, frame, refs)
		end

		if (not uiState.Localized) and localize then
			localize(uiState.FrameName, frame, refs)
			uiState.Localized = true
		end

		uiState.Bound = true

		if frame.IsShown and frame:IsShown() then
			self:RequestRefresh("bind")
		end

		return frame, refs
	end

	function module:EnsureUI()
		if isModuleUiBound(self, uiState) then
			return self.frame
		end
		local frame = self:BindUI()
		return frame
	end

	function module:Toggle()
		if not self:EnsureUI() then
			return
		end
		return uiController:Toggle()
	end

	function module:Hide()
		if not self:EnsureUI() then
			return
		end
		return uiController:Hide()
	end

	return uiState
end

function EditBoxes.BindHandlers(frameName, specs, requestRefreshFn)
	if type(frameName) ~= "string" or type(specs) ~= "table" then
		return
	end

	for i = 1, #specs do
		local spec = specs[i]
		local suffix = spec and spec.suffix
		local editBox = suffix and _G[frameName .. suffix] or nil
		if editBox then
			if spec.onEscape then
				Frames.SetScriptSafely(editBox, "OnEscapePressed", spec.onEscape)
			end
			if spec.onEnter then
				Frames.SetScriptSafely(editBox, "OnEnterPressed", spec.onEnter)
			end
			if spec.onFocusLost then
				Frames.SetScriptSafely(editBox, "OnEditFocusLost", spec.onFocusLost)
			end
			if requestRefreshFn then
				Frames.SetScriptSafely(editBox, "OnTextChanged", function(_, isUserInput)
					if isUserInput then
						requestRefreshFn()
					end
				end)
			end
		end
	end
end

local function acquireExportDialogRefs()
	local frame = Frames.Get("RMAExportFrame")
	if not frame then
		return nil
	end
	return {
		frame = frame,
		hint = Frames.GetRef(frame, "Hint"),
		lootBtn = Frames.GetRef(frame, "LootBtn"),
		output = Frames.GetRef(frame, "Output"),
		outputScroll = Frames.GetRef(frame, "OutputScroll"),
		closeBtn = Frames.GetRef(frame, "CloseBtn"),
	}
end

local function adjustExportDialogScrollBar(refs)
	local scroll = refs and refs.outputScroll
	if not (scroll and scroll.GetName) then
		return
	end

	local scrollName = scroll:GetName()
	local scrollBar = scroll.ScrollBar or _G[scrollName .. "ScrollBar"]
	if not scrollBar then
		return
	end

	local upButton = _G[scrollBar:GetName() .. "ScrollUpButton"]
	local downButton = _G[scrollBar:GetName() .. "ScrollDownButton"]
	if upButton then
		upButton:ClearAllPoints()
		upButton:SetPoint("TOP", scroll, "TOPRIGHT", 10, -4)
	end
	if downButton then
		downButton:ClearAllPoints()
		downButton:SetPoint("BOTTOM", scroll, "BOTTOMRIGHT", 10, 8)
	end

	scrollBar:ClearAllPoints()
	scrollBar:SetPoint("TOP", scroll, "TOPRIGHT", 10, -20)
	scrollBar:SetPoint("BOTTOM", scroll, "BOTTOMRIGHT", 10, 24)
end

function ExportDialog.Bind(config)
	config = config or {}
	local refs = acquireExportDialogRefs()
	if not refs then
		return nil
	end

	Frames.SetFrameTitle(refs.frame, config.title)
	Frames.EnableDrag(refs.frame)
	if refs.hint then
		refs.hint:SetText(config.hint or "")
	end
	if refs.lootBtn then
		if config.modeButtonText then
			refs.lootBtn:Show()
			refs.lootBtn:SetText(config.modeButtonText)
			Frames.SetScriptSafely(refs.lootBtn, "OnClick", config.onModeButtonClick)
		else
			refs.lootBtn:Hide()
			Frames.SetScriptSafely(refs.lootBtn, "OnClick", nil)
		end
	end
	if refs.output and refs.output.SetTextInsets then
		refs.output:SetTextInsets(8, 8, 8, 8)
	end
	if refs.output and refs.output.SetWordWrap then
		refs.output:SetWordWrap(true)
	end
	if refs.output then
		Frames.SetScriptSafely(refs.output, "OnTextChanged", function(self, userInput)
			if userInput then
				self:SetText((config.getText and config.getText()) or "")
				self:SetCursorPosition(0)
				self:HighlightText()
			end
		end)
	end
	if config.adjustScrollBar then
		adjustExportDialogScrollBar(refs)
	end
	if refs.closeBtn then
		refs.closeBtn:SetText(addon.L.BtnClose)
		Frames.SetScriptSafely(refs.closeBtn, "OnClick", function()
			refs.frame:Hide()
		end)
	end
	return refs
end

function ExportDialog.SetText(refs, text)
	local output = refs and refs.output
	if not output then
		return
	end

	if output.SetTextInsets then
		output:SetTextInsets(8, 8, 8, 8)
	end
	if output.SetJustifyH then
		output:SetJustifyH("LEFT")
	end
	if output.SetJustifyV then
		output:SetJustifyV("TOP")
	end
	output:SetText(text or "")
	output:SetCursorPosition(0)
	output:HighlightText()
	if output.SetFocus then
		output:SetFocus()
	end

	local scroll = refs.outputScroll
	if scroll and scroll.UpdateScrollChildRect then
		scroll:UpdateScrollChildRect()
	end
	if scroll and scroll.SetVerticalScroll then
		scroll:SetVerticalScroll(0)
	end
end
