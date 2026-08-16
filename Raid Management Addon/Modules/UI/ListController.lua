-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.UI.Lists
-- events: none; owns deferred list refresh driver
-- ui ownership: Lua owns list virtualization, row reuse, row placement, and scroll sizing.

local addon = select(2, ...)
local Diag = addon.Diag
local Options = addon.Options
local UI = addon.UI or {}
local Frames = UI.Frames
local Rows = UI.Rows
local Primitives = UI.Primitives

local _G = _G
local type, pairs, tostring = type, pairs, tostring
local floor = math.floor
local twipe = table.wipe

local CreateFrame = assert(_G.CreateFrame, Diag.A.ListControllerFrameCreationApiNotInitialized)

local Lists = UI.Lists or {}
UI.Lists = Lists

-- ----- Internal state ----- --

-- ----- Private helpers ----- --
local function getRowVisuals()
	return Rows or {}
end

local function getPrimitives()
	return Primitives or {}
end

local function getListDiag(bucketName, keyName)
	local bucket = Diag and Diag[bucketName]
	if not bucket then
		return nil
	end
	return bucket[keyName]
end

local isDebugEnabled = Options.IsDebugEnabled

-- ----- Public methods ----- --
function Lists.CreateRowRenderer(fn)
	local rowHeight
	return function(row, it, ...)
		if not rowHeight then
			rowHeight = (row and row:GetHeight()) or 20
		end
		fn(row, it, ...)
		return rowHeight
	end
end

function Lists.MakeIndexedRowName(suffix)
	suffix = tostring(suffix or "")
	return function(frameName, _, index)
		return tostring(frameName or "") .. suffix .. tostring(index or "")
	end
end

function Lists.CalculateColumnWidths(totalWidth, minWidths, ratios, fixedKeys)
	local widths = {}
	local variableKeys = {}
	local fixed = {}
	local usedWidth = 0
	local ratioTotal = 0

	if fixedKeys then
		for i = 1, #fixedKeys do
			fixed[fixedKeys[i]] = true
		end
	end

	for key, minWidth in pairs(minWidths) do
		local width = tonumber(minWidth) or 0
		widths[key] = width
		usedWidth = usedWidth + width
		if not fixed[key] then
			variableKeys[#variableKeys + 1] = key
			ratioTotal = ratioTotal + (tonumber(ratios[key]) or 0)
		end
	end

	local extraWidth = floor((tonumber(totalWidth) or 0) - usedWidth)
	if extraWidth <= 0 or ratioTotal <= 0 then
		return widths
	end

	local allocated = 0
	for i = 1, #variableKeys do
		local key = variableKeys[i]
		local ratio = (tonumber(ratios[key]) or 0) / ratioTotal
		local addition = floor(extraWidth * ratio)
		widths[key] = widths[key] + addition
		allocated = allocated + addition
	end

	local remainder = extraWidth - allocated
	if remainder > 0 then
		for i = 1, #variableKeys do
			local key = variableKeys[i]
			widths[key] = widths[key] + 1
			remainder = remainder - 1
			if remainder <= 0 then
				break
			end
		end
	end

	return widths
end

function Lists.GetContentWidth(frameName, fallbackWidth, gutterWidth)
	local fallback = floor(tonumber(fallbackWidth) or 0)
	local scroll = frameName and _G[frameName .. "ScrollFrame"] or nil
	local width = scroll and scroll.GetWidth and scroll:GetWidth() or nil
	if type(width) ~= "number" or width <= 0 then
		local frame = frameName and _G[frameName] or nil
		width = frame and frame.GetWidth and frame:GetWidth() or nil
		local gutter = tonumber(gutterWidth) or 0
		if type(width) == "number" and width > gutter then
			width = width - gutter
		end
	end

	width = tonumber(width) or fallback
	return math.max(fallback, floor(width))
end

function Lists.CalculateColumnBudget(
	frameName,
	fallbackWidth,
	gutterWidth,
	leadOffset,
	gapCount,
	gapWidth,
	returnedWidthOffset
)
	local fallback = floor(tonumber(fallbackWidth) or 0)
	local budget = Lists.GetContentWidth(frameName, fallbackWidth, gutterWidth)
		- (tonumber(leadOffset) or 0)
		- ((tonumber(gapCount) or 0) * (tonumber(gapWidth) or 0))
		+ (tonumber(returnedWidthOffset) or 0)
	return math.max(fallback, floor(budget))
end

function Lists.ApplyHeaderLayout(frameName, widths, columns, startOffset, topOffset, gapWidth)
	local frame = frameName and _G[frameName] or nil
	if not frame then
		return
	end

	local offset = tonumber(startOffset) or 0
	local top = tonumber(topOffset) or 0
	local gap = tonumber(gapWidth) or 0
	for i = 1, #(columns or {}) do
		local column = columns[i]
		local width = tonumber(widths and widths[column.widthKey]) or 0
		if column.headerExtraWidthKey then
			width = width + (tonumber(widths and widths[column.headerExtraWidthKey]) or 0)
		end
		local trailingGap = column.trailingGap and gap or 0
		local header = column.headerSuffix and _G[frameName .. column.headerSuffix] or nil
		if header then
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", frame, "TOPLEFT", offset, top)
			header:SetWidth(width + trailingGap)
		end
		offset = offset + width + trailingGap
	end
end

function Lists.ApplyRowWidths(ui, widths, columns)
	if not ui then
		return
	end
	for i = 1, #(columns or {}) do
		local column = columns[i]
		local width = tonumber(widths and widths[column.widthKey]) or 0
		local widget = column.rowKey and ui[column.rowKey] or nil
		if widget and widget.SetWidth then
			widget:SetWidth(width)
		end
		local hitBox = column.hitBoxKey and ui[column.hitBoxKey] or nil
		if hitBox and hitBox.SetWidth then
			hitBox:SetWidth(width)
		end
	end
end

function Lists.BindSortHeaders(frameName, columns, listRef, boundFlag)
	local frame = frameName and _G[frameName] or nil
	if not frame or not boundFlag or not listRef or type(listRef.Sort) ~= "function" or frame[boundFlag] then
		return
	end

	for i = 1, #(columns or {}) do
		local column = columns[i]
		if column.sortKey and column.headerSuffix then
			local header = _G[frameName .. column.headerSuffix]
			if header then
				local sortKey = column.sortKey
				Frames.SetScriptSafely(header, "OnClick", function()
					listRef:Sort(sortKey)
				end)
			end
		end
	end
	frame[boundFlag] = true
end

function Lists.FormatCountTitle(baseText, count, contextText, fallbackContext)
	local title = ("%s (%d)"):format(tostring(baseText or ""), tonumber(count) or 0)
	local context = contextText
	if context == nil or context == "" then
		context = fallbackContext
	end
	if context ~= nil and context ~= "" then
		return ("%s - %s"):format(title, context)
	end
	return title
end

function Lists.SetLabel(frameName, suffix, text, manageVisibility)
	local label = frameName and suffix and _G[frameName .. suffix] or nil
	if not label then
		return
	end
	if label.SetText then
		label:SetText(text or "")
	end
	if manageVisibility == true then
		Primitives.SetShown(label, type(text) == "string" and text ~= "")
	end
end

function Lists.CreateController(cfg)
	local self = {
		frameName = nil,
		data = {},
		_rows = {},
		_rowByName = {},
		_usedNames = {},
		_asc = false,
		_sortKey = nil,
		_lastHL = nil,
		_active = false,
		_localized = false,
		_lastWidth = nil,
		_dirty = true,
	}

	local defer = CreateFrame("Frame")
	defer:Hide()

	local function buildRowParts(btnName, row)
		if cfg._rowParts and not row._p then
			local p = {}
			for i = 1, #cfg._rowParts do
				local part = cfg._rowParts[i]
				p[part] = _G[btnName .. part]
			end
			row._p = p
		end
	end

	local function acquireRow(btnName, parent)
		local row = self._rowByName[btnName]
		if row then
			row:Show()
			local RowVisuals = getRowVisuals()
			if RowVisuals.EnsureVisuals then
				RowVisuals.EnsureVisuals(row)
			end
			return row
		end

		row = CreateFrame("Button", btnName, parent, cfg.rowTmpl)
		self._rowByName[btnName] = row
		buildRowParts(btnName, row)
		local RowVisuals = getRowVisuals()
		if RowVisuals.EnsureVisuals then
			RowVisuals.EnsureVisuals(row)
		end
		return row
	end

	local function releaseData()
		for i = 1, #self.data do
			twipe(self.data[i])
		end
		twipe(self.data)
	end

	local function refreshData()
		releaseData()
		if cfg.getData then
			cfg.getData(self.data)
		end
	end

	local function ensureLocalized()
		if not self._localized and cfg.localize then
			cfg.localize(self.frameName)
			self._localized = true
		end
	end

	local function setActive(active)
		self._active = active
		if self._active then
			ensureLocalized()
			self._loggedFetch = nil
			self._loggedWidgets = nil
			self._warnW0 = nil
			self._missingScroll = nil
			self:Dirty()
			return
		end
		releaseData()
		for i = 1, #self._rows do
			local row = self._rows[i]
			if row then
				row:Hide()
			end
		end
		self._lastHL = nil
	end

	local function safeRightInset(sf, sc, frameName)
		if cfg.rightInset ~= nil then
			return cfg.rightInset
		end

		if sf and sf.GetVerticalScrollRange then
			local range = sf:GetVerticalScrollRange()
			if type(range) == "number" and range <= 0 then
				return 0
			end
		end

		local sb = nil
		if sf and sf.GetName then
			sb = _G[sf:GetName() .. "ScrollBar"]
		end
		if not sb and sf then
			sb = sf.ScrollBar
		end
		if not sb and frameName then
			sb = _G[frameName .. "ScrollFrameScrollBar"]
		end

		if sb and sc and sb.IsShown and sb:IsShown() and sb.GetLeft and sc.GetRight then
			local sbL = sb:GetLeft()
			local scR = sc:GetRight()
			if sbL and scR then
				local overlap = scR - sbL
				if overlap > 0 then
					return math.max(0, overlap - 1)
				end
				return 0
			end
		end

		local width = sb and sb.GetWidth and sb:GetWidth()
		if width and width > 0 then
			return math.max(0, width - 1)
		end
		return 0
	end

	local function safeRowHeight(row, declaredHeight)
		local height = declaredHeight
		if height == nil and row and row.GetHeight then
			height = row:GetHeight()
		end
		if type(height) ~= "number" or height < 1 then
			return 20
		end
		return height
	end

	local function syncScrollChildWidth(sc, scrollW)
		if not (sc and sc.SetWidth) then
			return
		end

		local width = scrollW or 0
		if width >= 10 then
			sc:SetWidth(width)
		end
	end

	local function applyHighlight()
		local selectedId = cfg.highlightId and cfg.highlightId() or nil
		local focusId = (cfg.focusId and cfg.focusId()) or selectedId

		local selKey
		if cfg.highlightId then
			selKey = selectedId and ("id:" .. tostring(selectedId)) or "id:nil"
		elseif cfg.highlightFn then
			selKey = (cfg.highlightKey and cfg.highlightKey()) or false
		else
			selKey = false
		end

		local focusKey = (cfg.focusKey and cfg.focusKey())
			or (focusId ~= nil and ("f:" .. tostring(focusId)) or "f:nil")
		local combo = tostring(selKey) .. "|" .. tostring(focusKey)
		if combo == self._lastHL then
			return
		end
		self._lastHL = combo

		local RowVisuals = getRowVisuals()
		local Primitives = getPrimitives()
		for i = 1, #self.data do
			local it = self.data[i]
			local row = self._rows[i]
			if row then
				local isSel = false
				if cfg.highlightId then
					isSel = (selectedId ~= nil and it.id == selectedId)
				elseif cfg.highlightFn then
					isSel = cfg.highlightFn(it.id, it, i, row) and true or false
				end

				if RowVisuals.SetSelected then
					RowVisuals.SetSelected(row, isSel)
				elseif Primitives.SetHighlighted then
					Primitives.SetHighlighted(row, isSel)
				end

				if RowVisuals.SetFocused then
					RowVisuals.SetFocused(row, focusId ~= nil and it.id == focusId)
				end
			end
		end

		if cfg.highlightDebugTag and isDebugEnabled() then
			local info = (cfg.highlightDebugInfo and cfg.highlightDebugInfo(self)) or ""
			if info ~= "" then
				info = " " .. info
			end
			addon:debug(
				(Diag.D.LogListHighlightRefresh):format(tostring(cfg.highlightDebugTag), tostring(selKey), info)
			)
		end
	end

	local function postUpdate()
		if cfg.postUpdate then
			cfg.postUpdate(self.frameName)
		end
	end

	function self:Touch()
		defer:Show()
	end

	function self:Dirty()
		self._dirty = true
		defer:Show()
	end

	local fetchRows

	local function runUpdate()
		if not self._active or not self.frameName then
			return
		end

		if self._dirty then
			refreshData()
			local okFetch = fetchRows()
			if okFetch ~= false then
				self._dirty = false
			end
		end

		applyHighlight()
		postUpdate()
	end

	function self:UpdateNow()
		defer:Hide()

		local ok, err = pcall(runUpdate)
		if not ok then
			if err ~= self._lastErr then
				self._lastErr = err
				addon:error((getListDiag("E", "LogListUIError")):format(tostring(cfg.keyName or "?"), tostring(err)))
			end
			return false, err
		end

		return true
	end

	Frames.SetScriptSafely(defer, "OnUpdate", function(frame)
		frame:Hide()
		local ok, err = pcall(runUpdate)
		if not ok then
			if err ~= self._lastErr then
				self._lastErr = err
				addon:error((getListDiag("E", "LogListUIError")):format(tostring(cfg.keyName or "?"), tostring(err)))
			end
		end
	end)

	function self:OnLoad(frame)
		if not frame then
			return
		end
		self.frameName = frame:GetName()

		Frames.HookScriptSafely(frame, "OnShow", function()
			if not self._shownOnce then
				self._shownOnce = true
				if isDebugEnabled() then
					addon:debug(
						(getListDiag("D", "LogListUIShow")):format(
							tostring(cfg.keyName or "?"),
							tostring(self.frameName)
						)
					)
				end
			end
			setActive(true)
			if not self._loggedWidgets then
				self._loggedWidgets = true
				local n = self.frameName
				local sf = n and _G[n .. "ScrollFrame"]
				local sc = n and _G[n .. "ScrollFrameScrollChild"]
				if isDebugEnabled() then
					addon:debug(
						(getListDiag("D", "LogListUIWidgets")):format(
							tostring(cfg.keyName or "?"),
							tostring(sf),
							tostring(sc),
							sf and (sf:GetWidth() or 0) or 0,
							sf and (sf:GetHeight() or 0) or 0,
							sc and (sc:GetWidth() or 0) or 0,
							sc and (sc:GetHeight() or 0) or 0
						)
					)
				end
			end
		end)

		Frames.HookScriptSafely(frame, "OnHide", function()
			setActive(false)
		end)

		if frame:IsShown() then
			setActive(true)
		end
	end

	fetchRows = function()
		local n = self.frameName
		if not n then
			return
		end

		local sf = _G[n .. "ScrollFrame"]
		local sc = _G[n .. "ScrollFrameScrollChild"]
		if not (sf and sc) then
			if not self._missingScroll then
				self._missingScroll = true
				addon:warn(
					(getListDiag("W", "LogListUIMissingWidgets")):format(tostring(cfg.keyName or "?"), tostring(n))
				)
			end
			return
		end

		local scrollW = sf:GetWidth() or 0
		self._lastWidth = scrollW

		if scrollW < 10 then
			if not self._warnW0 then
				self._warnW0 = true
				if isDebugEnabled() then
					addon:debug(
						(getListDiag("D", "LogListUIDeferLayout")):format(tostring(cfg.keyName or "?"), scrollW)
					)
				end
			end
			defer:Show()
			return false
		end
		syncScrollChildWidth(sc, scrollW)

		if not self._loggedFetch then
			self._loggedFetch = true
			if isDebugEnabled() then
				addon:debug(
					(getListDiag("D", "LogListUIFetch")):format(
						tostring(cfg.keyName or "?"),
						#self.data,
						sf:GetWidth() or 0,
						sf:GetHeight() or 0,
						sc:GetWidth() or 0,
						sc:GetHeight() or 0,
						(_G[n] and _G[n]:GetWidth() or 0),
						(_G[n] and _G[n]:GetHeight() or 0)
					)
				)
			end
		end

		local totalH = 0
		local count = #self.data
		local used = self._usedNames
		if twipe then
			twipe(used)
		else
			for key in pairs(used) do
				used[key] = nil
			end
		end
		local rightInset = safeRightInset(sf, sc, n)

		for i = 1, count do
			local it = self.data[i]
			local btnName = cfg.rowName(n, it, i)
			used[btnName] = true

			local row = self._rows[i]
			if not row or row:GetName() ~= btnName then
				row = acquireRow(btnName, sc)
				self._rows[i] = row
			end

			row:SetID(it.id)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, -totalH)
			row:SetPoint("TOPRIGHT", -rightInset, -totalH)

			local rowHeight = cfg.drawRow(row, it, i)
			local usedH = safeRowHeight(row, rowHeight)
			totalH = totalH + usedH
			row:Show()
		end

		for i = count + 1, #self._rows do
			local row = self._rows[i]
			if row then
				row:Hide()
			end
		end
		for name, row in pairs(self._rowByName) do
			if not used[name] and row and row.IsShown and row:IsShown() then
				row:Hide()
			end
		end

		sc:SetHeight(math.max(totalH, sf:GetHeight()))
		if sf.UpdateScrollChildRect then
			sf:UpdateScrollChildRect()
		end
		self._lastHL = nil
	end

	function self:Sort(key)
		local cmp = cfg.sorters and cfg.sorters[key]
		if not cmp or #self.data <= 1 then
			return
		end
		if self._sortKey ~= key then
			self._sortKey = key
			self._asc = false
		end
		self._asc = not self._asc
		table.sort(self.data, function(a, b)
			return cmp(a, b, self._asc)
		end)
		fetchRows()
		applyHighlight()
		postUpdate()
	end

	return self
end

function Lists.BindController(module, controller)
	module.OnLoad = function(_, frame)
		controller:OnLoad(frame)
	end
	module.Sort = function(_, key)
		controller:Sort(key)
	end
end
