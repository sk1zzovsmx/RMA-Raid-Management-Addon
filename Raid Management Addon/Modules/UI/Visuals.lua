-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.UI.Primitives, addon.UI.Rows
-- events: none
-- ui ownership: XML owns row/header visual skeletons; Lua resolves named parts and applies runtime state.

local addon = select(2, ...)
local tostring, tonumber, type = tostring, tonumber, type

local UI = addon.UI or {}
local Colors = addon.Colors
local Effects = UI.Effects
local Frames = UI.Frames

local Primitives = UI.Primitives or {}
UI.Primitives = Primitives

local Rows = UI.Rows or {}
UI.Rows = Rows

-- ----- Internal state ----- --
local LOGGER_HEADER_TAB_INSET = 1
local loggerHeaderSuffixes = {
	"HeaderNum",
	"HeaderDate",
	"HeaderZone",
	"HeaderSize",
	"HeaderName",
	"HeaderTime",
	"HeaderMode",
	"HeaderJoin",
	"HeaderLeave",
	"HeaderIlvl",
	"HeaderSpec",
	"HeaderInspect",
	"HeaderItem",
	"HeaderSource",
	"HeaderWinner",
	"HeaderType",
	"HeaderRoll",
}

-- ----- Private helpers ----- --
local function setTextureColor(texture, r, g, b, a)
	if texture and texture.SetTexture then
		texture:SetTexture(r, g, b, a)
	end
end

local function resolveRowTextures(row)
	if not row or row._RMAVisualsResolved then
		return
	end

	local rowName = row.GetName and row:GetName() or nil

	row._RMASelTex = row._RMASelTex or (rowName and _G[rowName .. "SelectedTexture"])
	row._RMAFocusTex = row._RMAFocusTex or (rowName and _G[rowName .. "FocusTexture"])

	if row._RMASelTex and row._RMASelTex.Hide then
		row._RMASelTex:Hide()
	end
	if row._RMAFocusTex and row._RMAFocusTex.Hide then
		row._RMAFocusTex:Hide()
	end

	if row._RMASelTex and row._RMASelTex.SetDrawLayer then
		row._RMASelTex:SetDrawLayer("BORDER")
	end
	if row._RMAFocusTex and row._RMAFocusTex.SetDrawLayer then
		row._RMAFocusTex:SetDrawLayer("BORDER")
	end

	row._RMAVisualsResolved = true
end

local function isLoggerRow(row)
	return row and row._RMARowVisualStyle == "logger"
end

local function resolveLoggerHeaderTab(header)
	if not header or header._RMAHeaderTab then
		return
	end

	local headerName = header.GetName and header:GetName() or nil
	local fill = headerName and _G[headerName .. "Fill"] or nil
	header._RMAHeaderFill = fill

	local top = headerName and _G[headerName .. "Top"] or nil
	header._RMAHeaderTop = top

	local bottom = headerName and _G[headerName .. "Bottom"] or nil
	header._RMAHeaderBottom = bottom

	local left = headerName and _G[headerName .. "Left"] or nil
	header._RMAHeaderLeft = left

	local right = headerName and _G[headerName .. "Right"] or nil
	header._RMAHeaderRight = right

	if fill and fill.SetDrawLayer then
		fill:SetDrawLayer("BACKGROUND")
	end
	if top and top.SetDrawLayer then
		top:SetDrawLayer("BORDER")
	end
	if bottom and bottom.SetDrawLayer then
		bottom:SetDrawLayer("BORDER")
	end
	if left and left.SetDrawLayer then
		left:SetDrawLayer("BORDER")
	end
	if right and right.SetDrawLayer then
		right:SetDrawLayer("BORDER")
	end

	header._RMAHeaderTab = true
end

local function styleLoggerHeader(header)
	if not header then
		return
	end

	resolveLoggerHeaderTab(header)

	local text = header.GetFontString and header:GetFontString() or nil
	if text and text.SetTextColor then
		text:SetTextColor(1.00, 0.86, 0.20)
	end
	if text and text.SetJustifyH then
		text:SetJustifyH("LEFT")
	end

	local bg = header.GetName and _G[header:GetName() .. "Bg"] or nil
	if bg and bg.SetTexture then
		bg:SetTexture(0.02, 0.02, 0.02, 0.00)
	end

	setTextureColor(header._RMAHeaderFill, 0.015, 0.014, 0.012, 0.88)
	setTextureColor(header._RMAHeaderTop, 0.72, 0.62, 0.38, 0.92)
	setTextureColor(header._RMAHeaderBottom, 0.25, 0.22, 0.16, 0.95)
	setTextureColor(header._RMAHeaderLeft, 0.38, 0.34, 0.24, 0.72)
	setTextureColor(header._RMAHeaderRight, 0.38, 0.34, 0.24, 0.72)
end

local function getNamedFramePart(frameName, suffix)
	if type(frameName) ~= "string" or frameName == "" then
		return nil
	end
	if type(suffix) ~= "string" or suffix == "" then
		return nil
	end
	return _G[frameName .. suffix]
end

local function setTextNamedPart(frameName, suffix, str1, str2, cond)
	local frame = getNamedFramePart(frameName, suffix)
	if frame then
		Primitives.SetText(frame, str1, str2, cond)
	end
	return frame
end

local function getMasterRollRowRefs(row)
	if not row then
		return nil
	end
	if row._p then
		return row._p
	end
	if Frames and Frames.GetNamedParts then
		return Frames.GetNamedParts(row, {
			name = "Name",
			roll = "Roll",
			counter = "Counter",
			info = "Info",
			star = "Star",
			specIcon = "SpecIcon",
		})
	end
	return nil
end

local function clearPoints(frame)
	if frame and frame.ClearAllPoints then
		frame:ClearAllPoints()
	end
end

local function setPoint(frame, point, relativeTo, relativePoint, x, y)
	if frame and frame.SetPoint then
		frame:SetPoint(point, relativeTo, relativePoint, x, y)
	end
end

local function setSinglePoint(frame, point, relativeTo, relativePoint, x, y)
	clearPoints(frame)
	setPoint(frame, point, relativeTo, relativePoint, x, y)
end

local function setFrameShown(frame, cond)
	if not frame then
		return
	end
	if cond then
		if frame.Show then
			frame:Show()
		end
	elseif frame.Hide then
		frame:Hide()
	end
end

local function setMasterRollNamePoints(nameStr, row, infoStr, leftOffset)
	clearPoints(nameStr)
	setPoint(nameStr, "LEFT", row, "LEFT", leftOffset, 0)
	if infoStr then
		setPoint(nameStr, "RIGHT", infoStr, "LEFT", -3, 0)
	end
end

-- ----- Public methods ----- --
function Primitives.SetEnabled(frame, cond)
	if not frame then
		return
	end
	if cond and frame:IsEnabled() == 0 then
		frame:Enable()
	elseif not cond and frame:IsEnabled() == 1 then
		frame:Disable()
	end
end

function Primitives.Toggle(frame)
	if not frame then
		return
	end
	if frame:IsVisible() then
		frame:Hide()
	else
		frame:Show()
	end
end

function Primitives.SetShown(frame, cond)
	if not frame then
		return
	end
	if cond and not frame:IsShown() then
		frame:Show()
	elseif not cond and frame:IsShown() then
		frame:Hide()
	end
end

function Primitives.SetHighlighted(frame, cond)
	if not frame then
		return
	end
	if cond then
		frame:LockHighlight()
	else
		frame:UnlockHighlight()
	end
end

function Primitives.SetButtonCount(btn, baseText, n)
	if not btn then
		return
	end
	if not btn._RMABaseText then
		btn._RMABaseText = baseText or btn:GetText() or ""
	end
	local base = baseText or btn._RMABaseText or ""
	if n and n > 1 then
		btn:SetText(("%s (%d)"):format(base, n))
	else
		btn:SetText(base)
	end
end

function Primitives.SetButtonGlow(button, enabled, r, g, b, style, options)
	if Effects and Effects.SetButtonGlow then
		Effects.SetButtonGlow(button, enabled, r, g, b, style, options)
	end
end

function Primitives.SetTextureColor(texture, r, g, b, a)
	setTextureColor(texture, r, g, b, a)
end

function Primitives.SetTextureColorRgba(texture, rgba)
	if texture and rgba then
		setTextureColor(texture, rgba[1], rgba[2], rgba[3], rgba[4])
	end
end

function Primitives.SetText(frame, str1, str2, cond)
	if not frame then
		return
	end
	if cond then
		frame:SetText(str1)
	else
		frame:SetText(str2)
	end
end

function Primitives.SetNamedPartEnabled(frameName, suffix, cond)
	local frame = getNamedFramePart(frameName, suffix)
	if frame then
		Primitives.SetEnabled(frame, cond)
	end
	return frame
end

function Primitives.UpdateNamedPartModeText(frameName, suffix, str1, str2, mode, lastMode)
	if mode ~= lastMode then
		setTextNamedPart(frameName, suffix, str1, str2, mode)
		return mode
	end
	return lastMode
end

function Rows.EnsureVisuals(row)
	resolveRowTextures(row)
end

function Rows.SetSelected(row, cond)
	resolveRowTextures(row)
	if not row or not row._RMASelTex then
		return
	end
	if cond then
		if isLoggerRow(row) then
			row._RMASelTex:SetVertexColor(0.08, 0.52, 0.10, 0.76)
		else
			row._RMASelTex:SetVertexColor(0.20, 0.60, 1.00, 0.52)
		end
		row._RMASelTex:Show()
	else
		row._RMASelTex:Hide()
	end
end

function Rows.SetFocused(row, cond)
	resolveRowTextures(row)
	local texture = row and row._RMAFocusTex
	if not texture then
		return
	end
	if cond then
		if isLoggerRow(row) then
			texture:SetVertexColor(0.95, 0.72, 0.20, 0.26)
		else
			texture:SetVertexColor(0.20, 0.60, 1.00, 0.72)
		end
		texture:Show()
	else
		texture:Hide()
	end
end

function Rows.StyleLoggerRow(row)
	if not row then
		return
	end

	row._RMARowVisualStyle = "logger"
	local rowName = row.GetName and row:GetName() or nil
	row._RMALoggerBg = row._RMALoggerBg or (rowName and _G[rowName .. "LoggerBg"])
	row._RMALoggerLine = row._RMALoggerLine or (rowName and _G[rowName .. "LoggerBottomLine"])
	if row._RMALoggerBg and row._RMALoggerBg.SetDrawLayer then
		row._RMALoggerBg:SetDrawLayer("BACKGROUND")
	end
	if row._RMALoggerLine and row._RMALoggerLine.SetDrawLayer then
		row._RMALoggerLine:SetDrawLayer("BORDER")
	end

	if row._RMALoggerLine then
		row._RMALoggerLine:SetTexture(0.32, 0.30, 0.25, 0.42)
	end
end

function Rows.SetLoggerRowIndex(row, index)
	if not row then
		return
	end

	Rows.StyleLoggerRow(row)
	row._RMALoggerRowIndex = index
	if row._RMALoggerBg then
		if (tonumber(index) or 0) % 2 == 0 then
			row._RMALoggerBg:SetTexture(0.07, 0.07, 0.07, 0.74)
		else
			row._RMALoggerBg:SetTexture(0.025, 0.025, 0.025, 0.76)
		end
	end
end

function Rows.StyleLoggerPanel(frameName)
	local frame = frameName and _G[frameName] or nil
	if not frame then
		return
	end

	if frame.SetBackdropColor then
		frame:SetBackdropColor(0.01, 0.01, 0.01, 0.88)
	end
	if frame.SetBackdropBorderColor then
		frame:SetBackdropBorderColor(0.56, 0.52, 0.45, 0.95)
	end

	local title = _G[frameName .. "Title"]
	if title then
		title:SetTextColor(1.00, 0.82, 0.00)
		title:SetJustifyH("LEFT")
	end

	for i = 1, #loggerHeaderSuffixes do
		styleLoggerHeader(_G[frameName .. loggerHeaderSuffixes[i]])
	end
end

function Rows.ApplyLoggerSkin(panelNames)
	if type(panelNames) ~= "table" then
		return
	end
	for i = 1, #panelNames do
		Rows.StyleLoggerPanel(panelNames[i])
	end
end

function Rows.DrawMasterRollRow(row, data, onClick)
	if not row or not data then
		return
	end

	if onClick and not row.RMAHasOnClick then
		Frames.SetScriptSafely(row, "OnClick", onClick)
		row.RMAHasOnClick = true
	end

	row.playerName = data.name
	if row.EnableMouse then
		row:EnableMouse(data.canClick == true)
	end

	local ui = getMasterRollRowRefs(row)
	local nameStr = ui and (ui.name or ui.Name) or nil
	local rollStr = ui and (ui.roll or ui.Roll) or nil
	local counterStr = ui and (ui.counter or ui.Counter) or nil
	local infoStr = ui and (ui.info or ui.Info) or nil
	local star = ui and (ui.star or ui.Star) or nil
	local hasSpecIcon = data.specIcon ~= nil and data.specIcon ~= ""
	local hasStar = data.showStar == true

	if nameStr then
		local class = data.class or "UNKNOWN"
		if data.isReserved then
			nameStr:SetVertexColor(0.4, 0.6, 1.0)
		else
			local r, g, b = Colors.GetClassColor(class)
			nameStr:SetVertexColor(r, g, b)
		end
		nameStr:SetText(data.displayName or data.name or "")
		nameStr:Show()
	end

	local specIcon = ui and (ui.specIcon or ui.SpecIcon) or nil
	if specIcon then
		if hasSpecIcon then
			if specIcon.SetTexture then
				specIcon:SetTexture(data.specIcon)
			end
			if specIcon.SetTexCoord then
				specIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
			end
			if specIcon.SetSize then
				specIcon:SetSize(12, 12)
			else
				if specIcon.SetWidth then
					specIcon:SetWidth(12)
				end
				if specIcon.SetHeight then
					specIcon:SetHeight(12)
				end
			end
			if hasStar then
				setSinglePoint(specIcon, "LEFT", row, "LEFT", 16, 0)
			else
				setSinglePoint(specIcon, "LEFT", row, "LEFT", 2, 0)
			end
			setFrameShown(specIcon, true)
		else
			setFrameShown(specIcon, false)
		end
	end

	if rollStr then
		rollStr:SetText(tostring(data.roll or ""))
		rollStr:Show()
	end
	if counterStr then
		counterStr:SetText(data.counterText or "")
		counterStr:Show()
	end
	if infoStr then
		infoStr:SetText(data.infoText or "")
		infoStr:Show()
	end

	if nameStr then
		local nameLeft = 18
		if hasSpecIcon and hasStar then
			nameLeft = 30
		end
		setMasterRollNamePoints(nameStr, row, infoStr, nameLeft)
	end

	if star then
		setSinglePoint(star, "LEFT", row, "LEFT", 2, 0)
		setFrameShown(star, hasStar)
	end
end
