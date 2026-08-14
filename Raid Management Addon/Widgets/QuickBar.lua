-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.Widgets.QuickBar QuickBar action bar API
-- events: refreshes active loot-method highlight from forwarded WoW event
local addon = select(2, ...)
local Diag = addon.Diag
local L = addon.L
local Options = addon.Options
local UI = addon.UI
local Frames = UI.Frames
local Tooltips = UI.Tooltips
local Popups = UI.Popups
local Bus = addon.Bus
local Events = addon.Events
local Controllers = addon.Controllers
local Widgets = addon.Widgets
local Services = addon.Services

local Raid = assert(Services.Raid, Diag.A.QuickBarRaidServiceNotInitialized)
local LoggerController = assert(Controllers.Logger, Diag.A.QuickBarLoggerControllerNotInitialized)
local ReservesWidget = assert(Widgets.ReservesUI, Diag.A.QuickBarReservesWidgetNotInitialized)
local WarningsController = assert(Controllers.Warnings, Diag.A.QuickBarWarningsControllerNotInitialized)
local PartyLootMethodChanged = assert(
	Events.Wow.PartyLootMethodChanged,
	Diag.A.QuickBarLootMethodEventNotInitialized
)
local RaidRosterDelta = assert(
	Events.Internal.RaidRosterDelta,
	Diag.A.QuickBarRaidRosterEventNotInitialized
)
local RaidRosterUpdate = assert(
	Events.Wow.RaidRosterUpdate,
	Diag.A.QuickBarForwardedRaidRosterEventNotInitialized
)
local IsPlayerInRaid = assert(Raid.IsPlayerInRaid, Diag.A.QuickBarRaidMembershipResolverNotInitialized)

local _G = _G
local mathMax, mathMin = math.max, math.min

Widgets.QuickBar = Widgets.QuickBar or {}
local module = Widgets.QuickBar

local quickBarNs = Options.RegisterNamespace("Minimap", {
	quickBar = false,
	quickBarX = 0,
	quickBarY = -180,
	quickBarOrientation = "horizontal",
	quickBarShowML = true,
	quickBarShowGL = true,
	quickBarShowSR = true,
	quickBarShowHIS = true,
	quickBarShowRW = true,
})

local buttonOptionKeys = {
	ML = "quickBarShowML",
	GL = "quickBarShowGL",
	SR = "quickBarShowSR",
	HIS = "quickBarShowHIS",
	RW = "quickBarShowRW",
}

local groups = {
	{ "ML", "GL" },
	{ "SR" },
	{ "HIS" },
	{ "RW" },
}

local PADDING = 4
local GAP = 2
local HORIZONTAL_SEPARATOR_WIDTH = 1
local HORIZONTAL_SEPARATOR_HEIGHT = 16
local VERTICAL_SEPARATOR_WIDTH = 24
local VERTICAL_SEPARATOR_HEIGHT = 1

local state = {
	bound = false,
}

local function normalizeOrientation(value)
	if value == "vertical" then
		return "vertical"
	end
	return "horizontal"
end

local function clampCenterOffsets(frame, x, y)
	local parentWidth = UIParent:GetWidth() or 0
	local parentHeight = UIParent:GetHeight() or 0
	local halfWidth = (frame:GetWidth() or 0) / 2
	local halfHeight = (frame:GetHeight() or 0) / 2
	local maxX = mathMax(0, parentWidth / 2 - halfWidth)
	local maxY = mathMax(0, parentHeight / 2 - halfHeight)
	x = mathMax(-maxX, mathMin(maxX, tonumber(x) or 0))
	y = mathMax(-maxY, mathMin(maxY, tonumber(y) or -180))
	return x, y
end

local function applySavedPosition(frame)
	local x, y = clampCenterOffsets(frame, quickBarNs:Get("quickBarX"), quickBarNs:Get("quickBarY"))
	frame:ClearAllPoints()
	frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

local function savePosition(frame)
	local parentX, parentY = UIParent:GetCenter()
	local frameX, frameY = frame:GetCenter()
	if not (parentX and parentY and frameX and frameY) then
		return
	end
	local x, y = clampCenterOffsets(frame, frameX - parentX, frameY - parentY)
	quickBarNs:Set("quickBarX", x)
	quickBarNs:Set("quickBarY", y)
	applySavedPosition(frame)
end

local function requestWithConfirmation(method, popupKey, text)
	if not IsPlayerInRaid(Raid) or Raid:GetLootMethodName() == method then
		return false
	end
	Popups.ShowConfirm(popupKey, text, function()
		if Raid:RequestLootMethod(method) then
			module:RefreshLootMethod(method)
		end
	end)
	return true
end

local function bindTooltip(button, text)
	Tooltips.Bind(button, text, "ANCHOR_RIGHT")
end

local function bindUi(frame, refs)
	refs.Handle:RegisterForClicks("LeftButtonUp")
	refs.ML:RegisterForClicks("LeftButtonUp")
	refs.GL:RegisterForClicks("LeftButtonUp")
	refs.HIS:RegisterForClicks("LeftButtonUp")
	refs.SR:RegisterForClicks("LeftButtonUp")
	refs.RW:RegisterForClicks("LeftButtonUp")

	refs.ML:SetText(L.BtnQuickBarML)
	refs.GL:SetText(L.BtnQuickBarGL)
	refs.HIS:SetText(L.BtnQuickBarHIS)
	refs.SR:SetText(L.BtnQuickBarSR)
	refs.RW:SetText(L.BtnQuickBarRW)
	refs.MLGlow:SetVertexColor(0.20, 1.00, 0.20)
	refs.GLGlow:SetVertexColor(0.20, 1.00, 0.20)

	bindTooltip(refs.Handle, L.StrQuickBarHandleTooltip)
	bindTooltip(refs.ML, L.StrQuickBarMasterLootTooltip)
	bindTooltip(refs.GL, L.StrQuickBarGroupLootTooltip)
	bindTooltip(refs.HIS, L.StrQuickBarHistoryTooltip)
	bindTooltip(refs.SR, L.StrQuickBarSoftResTooltip)
	bindTooltip(refs.RW, L.StrQuickBarRaidWarningTooltip)

	Frames.SetScriptSafely(refs.Handle, "OnMouseDown", function(_, button)
		if button == "LeftButton" and frame.StartMoving then
			frame:StartMoving()
		end
	end)
	Frames.SetScriptSafely(refs.Handle, "OnMouseUp", function(_, button)
		if button ~= "LeftButton" then
			return
		end
		if frame.StopMovingOrSizing then
			frame:StopMovingOrSizing()
		end
		savePosition(frame)
	end)
	Frames.SetScriptSafely(refs.ML, "OnClick", function()
		requestWithConfirmation("master", "RMA_QUICK_BAR_MASTER_LOOT", L.PopupQuickBarMasterLoot)
	end)
	Frames.SetScriptSafely(refs.GL, "OnClick", function()
		requestWithConfirmation("group", "RMA_QUICK_BAR_GROUP_LOOT", L.PopupQuickBarGroupLoot)
	end)
	Frames.SetScriptSafely(refs.HIS, "OnClick", function()
		LoggerController:ToggleLootHistory()
	end)
	Frames.SetScriptSafely(refs.SR, "OnClick", function()
		ReservesWidget:Toggle()
	end)
	Frames.SetScriptSafely(refs.RW, "OnClick", function()
		WarningsController:Toggle()
	end)
end

function module:GetOrientation()
	return normalizeOrientation(quickBarNs:Get("quickBarOrientation"))
end

function module:SetOrientation(value)
	if value ~= "horizontal" and value ~= "vertical" then
		return false
	end
	quickBarNs:Set("quickBarOrientation", value)
	self:RefreshLayout()
	return true
end

function module:IsButtonShown(key)
	local optionKey = buttonOptionKeys[key]
	if not optionKey then
		return nil
	end
	return quickBarNs:Get(optionKey) == true
end

function module:SetButtonShown(key, shown)
	local optionKey = buttonOptionKeys[key]
	if not optionKey then
		return false
	end
	quickBarNs:Set(optionKey, shown == true)
	self:RefreshLayout()
	return true
end

function module:RefreshLayout()
	local frame, refs = self.frame, self.refs
	if not (frame and refs) then
		return self:EnsureUI()
	end

	local orientation = self:GetOrientation()
	local visible = { refs.Handle }
	local separatorIndex = 0
	local hasVisibleGroup = false
	for groupIndex = 1, #groups do
		local group = groups[groupIndex]
		local groupButtons = {}
		for i = 1, #group do
			local key = group[i]
			local shown = self:IsButtonShown(key)
			Frames.SetShown(refs[key], shown)
			if shown then
				groupButtons[#groupButtons + 1] = refs[key]
			end
		end
		if #groupButtons > 0 then
			if hasVisibleGroup then
				separatorIndex = separatorIndex + 1
				local separator = refs["Separator" .. separatorIndex]
				if orientation == "horizontal" then
					separator:SetSize(HORIZONTAL_SEPARATOR_WIDTH, HORIZONTAL_SEPARATOR_HEIGHT)
				else
					separator:SetSize(VERTICAL_SEPARATOR_WIDTH, VERTICAL_SEPARATOR_HEIGHT)
				end
				Frames.SetShown(separator, true)
				visible[#visible + 1] = separator
			end
			for i = 1, #groupButtons do
				visible[#visible + 1] = groupButtons[i]
			end
			hasVisibleGroup = true
		end
	end
	for i = separatorIndex + 1, 3 do
		Frames.SetShown(refs["Separator" .. i], false)
	end

	local contentWidth, contentHeight = 0, 0
	for i = 1, #visible do
		local widget = visible[i]
		widget:ClearAllPoints()
		if i == 1 then
			if orientation == "horizontal" then
				widget:SetPoint("LEFT", frame, "LEFT", PADDING, 0)
			else
				widget:SetPoint("TOP", frame, "TOP", 0, -PADDING)
			end
		elseif orientation == "horizontal" then
			widget:SetPoint("LEFT", visible[i - 1], "RIGHT", GAP, 0)
		else
			widget:SetPoint("TOP", visible[i - 1], "BOTTOM", 0, -GAP)
		end

		local width = widget:GetWidth() or 0
		local height = widget:GetHeight() or 0
		if orientation == "horizontal" then
			contentWidth = contentWidth + width + (i > 1 and GAP or 0)
			contentHeight = mathMax(contentHeight, height)
		else
			contentWidth = mathMax(contentWidth, width)
			contentHeight = contentHeight + height + (i > 1 and GAP or 0)
		end
	end
	frame:SetSize(contentWidth + PADDING * 2, contentHeight + PADDING * 2)
	applySavedPosition(frame)
	self:RefreshRaidAvailability()
	return frame
end

function module:EnsureUI()
	if state.bound and self.frame and self.refs then
		return self.frame
	end
	local frame = _G.RMAQuickBarFrame
	if not frame then
		return nil
	end
	local refs = {
		Handle = Frames.GetRef(frame, "Handle"),
		ML = Frames.GetRef(frame, "ML"),
		GL = Frames.GetRef(frame, "GL"),
		HIS = Frames.GetRef(frame, "HIS"),
		SR = Frames.GetRef(frame, "SR"),
		RW = Frames.GetRef(frame, "RW"),
		Separator1 = Frames.GetRef(frame, "Separator1"),
		Separator2 = Frames.GetRef(frame, "Separator2"),
		Separator3 = Frames.GetRef(frame, "Separator3"),
		MLGlow = Frames.GetRef(frame, "MLGlow"),
		GLGlow = Frames.GetRef(frame, "GLGlow"),
	}
	if not (
		refs.Handle and refs.ML and refs.GL and refs.HIS and refs.SR and refs.RW
		and refs.Separator1 and refs.Separator2 and refs.Separator3 and refs.MLGlow and refs.GLGlow
	) then
		return nil
	end
	self.frame = frame
	self.refs = refs
	bindUi(frame, refs)
	state.bound = true
	self:RefreshLayout()
	Frames.SetShown(frame, self:IsShown())
	return frame
end

function module:SetShown(show)
	quickBarNs:Set("quickBar", show == true)
	local frame = self:EnsureUI()
	if frame then
		Frames.SetShown(frame, show == true)
	end
end

function module:IsShown()
	return quickBarNs:Get("quickBar") == true
end

function module:RefreshLootMethod(method)
	local refs = self.refs
	if not refs then
		return
	end
	method = method or Raid:GetLootMethodName()
	local inRaid = IsPlayerInRaid(Raid) == true
	Frames.SetShown(refs.MLGlow, inRaid and method == "master" and self:IsButtonShown("ML"))
	Frames.SetShown(refs.GLGlow, inRaid and method == "group" and self:IsButtonShown("GL"))
end

function module:RefreshRaidAvailability()
	local refs = self.refs
	if not refs then
		return false
	end
	local inRaid = IsPlayerInRaid(Raid) == true
	if inRaid then
		refs.ML:Enable()
		refs.GL:Enable()
	else
		refs.ML:Disable()
		refs.GL:Disable()
	end
	self:RefreshLootMethod()
	return inRaid
end

Bus.RegisterCallback(PartyLootMethodChanged, function()
	module:RefreshLootMethod()
end)

Bus.RegisterCallback(RaidRosterDelta, function()
	module:RefreshRaidAvailability()
end)

Bus.RegisterCallback(RaidRosterUpdate, function()
	module:RefreshRaidAvailability()
end)
