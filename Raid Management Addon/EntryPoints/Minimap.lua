-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: owns minimap frame scripts; drag uses allowed OnUpdate exception
local addon = select(2, ...)
local L = addon.L

local Options = addon.Options
local UI = addon.UI
local Frames = UI.Frames
local Tooltips = UI.Tooltips
local ShowTooltipLines = assert(Tooltips.ShowLines, "Minimap tooltip presenter is not initialized")
local HideTooltip = assert(Tooltips.Hide, "Minimap tooltip hider is not initialized")
local Colors = addon.Colors
local Services = addon.Services
local Controllers = addon.Controllers
local Widgets = addon.Widgets
local LootCounterWidget = assert(Widgets.LootCounter, "Minimap loot counter widget is not initialized")
local ReservesWidget = assert(Widgets.ReservesUI, "Minimap reserves widget is not initialized")
local MasterController = assert(Controllers.Master, "Minimap master controller is not initialized")
local LoggerController = assert(Controllers.Logger, "Minimap logger controller is not initialized")
local AttendanceController = assert(Controllers.Attendance, "Minimap attendance controller is not initialized")
local WarningsController = assert(Controllers.Warnings, "Minimap warnings controller is not initialized")
local SpammerController = assert(Controllers.Spammer, "Minimap spammer controller is not initialized")
local Raid = assert(Services.Raid, "Minimap raid service is not initialized")
local IsPlayerInRaid = assert(Raid.IsPlayerInRaid, "Minimap raid membership resolver is not initialized")
local CanUseCapability = assert(Raid.CanUseCapability, "Minimap raid capability resolver is not initialized")
local CanObservePassiveLoot = assert(Raid.CanObservePassiveLoot, "Minimap passive-loot observer is not initialized")
local ClearRaidIcons = assert(Raid.ClearRaidIcons, "Minimap raid-icon cleaner is not initialized")
local R_COLOR = addon.C.R_COLOR

-- =========== Minimap Button Module  =========== --
addon.Minimap = addon.Minimap or {}
addon.Minimap = addon.Minimap
local module = addon.Minimap

-- Namespace registration: minimap options (visibility and angular position).
local minimapNs = Options.RegisterNamespace("Minimap", {
	minimapButton = true,
	minimapPos = 325,
})

-- ----- Internal state ----- --
local addonMenu
local dragMode
local dragActive = false
local uiState = {
	Bound = false,
}

-- Cached math functions
local sqrt = math.sqrt
local cos, sin = math.cos, math.sin
local rad, atan2, deg = math.rad, math.atan2, math.deg
local MINIMAP_RING_RADIUS = 80
local MIN_DRAG_DISTANCE = 0.001

-- ----- Private helpers ----- --
function uiState.AcquireRefs(frame)
	return {
		button = frame,
	}
end

local function buildMenu()
	local hasRaidGroup = IsPlayerInRaid(Raid)
	local hasLootAccess = CanUseCapability(Raid, "loot")
	local hasRaidIconsAccess = CanUseCapability(Raid, "raid_icons")
	local canOpenLootFrame = (not hasRaidGroup) or hasLootAccess
	if hasRaidGroup and CanObservePassiveLoot(Raid) then
		canOpenLootFrame = true
	end
	local disableLootActions = nil
	if not canOpenLootFrame then
		disableLootActions = 1
	end
	local disableRaidActions = nil
	if not hasRaidIconsAccess then
		disableRaidActions = 1
	end
	local disableLootRaidActions = 1
	if hasRaidGroup then
		disableLootRaidActions = nil
	end
	return {
		{
			text = L.StrLootMaster,
			notCheckable = 1,
			disabled = disableLootActions,
			func = function()
				MasterController:Toggle()
			end,
		},
		{
			text = L.StrLootReserve,
			notCheckable = 1,
			func = function()
				ReservesWidget:Toggle()
			end,
		},
		{ text = " ", disabled = 1, notCheckable = 1 },
		{
			text = L.StrLootCounter,
			notCheckable = 1,
			disabled = disableLootRaidActions,
			func = function()
				if not IsPlayerInRaid(Raid) then
					return
				end
				LootCounterWidget:Toggle()
			end,
		},
		{
			text = L.StrLootHistory,
			notCheckable = 1,
			func = function()
				LoggerController:ToggleLootHistory()
			end,
		},
		{ text = " ", disabled = 1, notCheckable = 1 },
		{
			text = L.StrRaidAttendance,
			notCheckable = 1,
			func = function()
				AttendanceController:Toggle()
			end,
		},
		{ text = " ", disabled = 1, notCheckable = 1 },
		{
			text = RAID_WARNING,
			notCheckable = 1,
			func = function()
				WarningsController:Toggle()
			end,
		},
		{ text = " ", disabled = 1, notCheckable = 1 },
		{
			text = L.StrLFMSpam,
			notCheckable = 1,
			func = function()
				SpammerController:Toggle()
			end,
		},
		{ text = " ", disabled = 1, notCheckable = 1 },
		{
			text = L.StrClearIcons,
			notCheckable = 1,
			disabled = disableRaidActions,
			func = function()
				ClearRaidIcons(Raid)
			end,
		},
	}
end

-- Initializes and opens the menu for the minimap button.
local function openMenu()
	addonMenu = addonMenu or CreateFrame("Frame", "RMAMenu", UIParent, "UIDropDownMenuTemplate")
	local menu = buildMenu()
	-- EasyMenu handles UIDropDownMenu initialization and opening.
	EasyMenu(menu, addonMenu, RMA_MINIMAP_GUI, 0, 0, "MENU")
end

local function isMenuOpen()
	return addonMenu and UIDROPDOWNMENU_OPEN_MENU == addonMenu and DropDownList1 and DropDownList1:IsShown()
end

local function toggleMenu()
	if isMenuOpen() then
		CloseDropDownMenus()
		return
	end
	openMenu()
end

-- Moves the minimap button while dragging.
local function moveButton(self)
	if not dragActive then
		return
	end

	local scale = self and self.GetEffectiveScale and self:GetEffectiveScale()
	if not scale or scale == 0 then
		return
	end

	local centerX, centerY = Minimap:GetCenter()
	if not centerX or not centerY then
		return
	end

	local cursorX, cursorY = GetCursorPosition()
	if not cursorX or not cursorY then
		return
	end

	local x, y = cursorX / scale - centerX, cursorY / scale - centerY

	if dragMode == "free" then
		-- Free drag mode
		self:ClearAllPoints()
		self:SetPoint("CENTER", x, y)
	else
		-- Circular drag mode (snap to ring radius ~80)
		local dist = sqrt(x * x + y * y)
		if dist <= MIN_DRAG_DISTANCE then
			return
		end
		local px, py = (x / dist) * MINIMAP_RING_RADIUS, (y / dist) * MINIMAP_RING_RADIUS
		self:ClearAllPoints()
		self:SetPoint("CENTER", px, py)
	end
end

local function setMinimapShown(show)
	Frames.SetShown(RMA_MINIMAP_GUI, show)
end

-- ----- Public methods ----- --
function module:GetPos()
	return minimapNs:Get("minimapPos") or 325
end

function module:SetPos(angle)
	local frame = self.frame or Frames.Get("RMA_MINIMAP_GUI") or RMA_MINIMAP_GUI
	if not frame then
		return
	end
	angle = angle % 360
	minimapNs:Set("minimapPos", angle)
	local r = rad(angle)
	frame:ClearAllPoints()
	frame:SetPoint("CENTER", cos(r) * MINIMAP_RING_RADIUS, sin(r) * MINIMAP_RING_RADIUS)
end

local function loadMinimapFrame(frame)
	frame = frame or Frames.Get("RMA_MINIMAP_GUI") or RMA_MINIMAP_GUI
	if not frame then
		return nil
	end

	module.frame = frame
	local minimapPos = minimapNs:Get("minimapPos") or 325
	local minimapButton = minimapNs:Get("minimapButton")
	frame:SetUserPlaced(true)
	module:SetPos(minimapPos)
	setMinimapShown(minimapButton ~= false)
	frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	Frames.SetScriptSafely(frame, "OnMouseDown", function(self, button)
		if button ~= "LeftButton" then
			return
		end
		if IsAltKeyDown() then
			dragMode = "free"
		elseif IsShiftKeyDown() then
			dragMode = "ring"
		else
			return
		end
		dragActive = true
		Frames.SetScriptSafely(self, "OnUpdate", moveButton)
	end)
	Frames.SetScriptSafely(frame, "OnMouseUp", function(self, button)
		Frames.SetScriptSafely(self, "OnUpdate", nil)
		if not dragActive then
			return
		end
		local wasFreeDrag = (dragMode == "free")
		dragActive = false
		dragMode = nil
		if wasFreeDrag then
			return
		end
		local mx, my = Minimap:GetCenter()
		local bx, by = self:GetCenter()
		if not (mx and my and bx and by) then
			return
		end
		module:SetPos(deg(atan2(by - my, bx - mx)))
	end)
	Frames.SetScriptSafely(frame, "OnClick", function(self, button)
		-- Ignore clicks if Shift or Alt keys are held:
		if IsShiftKeyDown() or IsAltKeyDown() then
			return
		end
		if button == "RightButton" then
			Controllers.Config:Toggle()
		elseif button == "LeftButton" then
			toggleMenu()
		end
	end)
	Frames.SetScriptSafely(frame, "OnEnter", function(self)
		ShowTooltipLines(self, {
			defaultAnchor = true,
			title = Colors.WrapText("Raid Management Addon", Colors.NormalizeHexColor(R_COLOR)),
			lines = {
				L.StrMinimapLClick,
				L.StrMinimapRClick,
				L.StrMinimapSClick,
				L.StrMinimapAClick,
			},
		})
	end)
	Frames.SetScriptSafely(frame, "OnLeave", HideTooltip)
	return frame
end

function module:BindUI()
	if uiState.Bound and self.frame and self.refs then
		return self.frame, self.refs
	end

	local frame = Frames.Get("RMA_MINIMAP_GUI") or RMA_MINIMAP_GUI
	if not frame then
		return nil
	end

	local refs = uiState.AcquireRefs(frame)
	self.refs = refs

	loadMinimapFrame(frame)

	uiState.Bound = true
	return frame, refs
end

function module:EnsureUI()
	if uiState.Bound and self.frame and self.refs then
		return self.frame
	end
	return self:BindUI()
end

function module:SetMinimapButtonShown(show)
	minimapNs:Set("minimapButton", show == true)
	if not self:EnsureUI() then
		return
	end
	setMinimapShown(show == true)
end
