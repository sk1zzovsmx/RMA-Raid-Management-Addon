-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: addon.UI.ScreenNotice
-- events: listens Internal.ScreenNotice; delegates fade timing to UI.Effects
-- ui ownership: XML owns static notice frame parts; Lua owns text, sizing, timing, and fade state.

local addon = select(2, ...)
local UI = addon.UI or {}
local ScreenNotice = UI.ScreenNotice or {}
UI.ScreenNotice = ScreenNotice

local Effects = UI.Effects
local Bus = addon.Bus
local Events = addon.Events
local InternalEvents = assert(Events.Internal, "Screen notice internal events are not initialized")
local RegisterCallback = assert(Bus.RegisterCallback, "Screen notice event bus listener is not initialized")
local ScreenNoticeEvent = assert(InternalEvents.ScreenNotice, "Screen notice event name is not initialized")

local max = math.max
local min = math.min
local gsub = string.gsub
local tonumber, tostring, type = tonumber, tostring, type

-- ----- Internal state ----- --
local FRAME_NAME = "RMAScreenNoticeFrame"
local DEFAULT_DURATION_SECONDS = 1.25
local FADE_SECONDS = 0.35

local frame
local titleText
local detailText
local detailVisible = false

-- ----- Private helpers ----- --
local function colorizeTitle(message)
	return gsub(tostring(message), "Master Loot", "|cffff2020Master Loot|r")
end

local function ensureFrame()
	if frame then
		return frame
	end

	frame = _G[FRAME_NAME]
	if not frame then
		return nil
	end

	titleText = _G[FRAME_NAME .. "TitleText"]
	detailText = _G[FRAME_NAME .. "DetailText"]
	if not titleText or not detailText then
		frame = nil
		titleText = nil
		detailText = nil
		return nil
	end

	if frame.SetFrameLevel then
		frame:SetFrameLevel(1000)
	end

	return frame
end

local function updateFrameSize()
	if not frame or not titleText then
		return
	end

	local width = titleText.GetWidth and titleText:GetWidth() or 1
	if detailText and detailVisible and detailText.GetWidth then
		width = max(width, detailText:GetWidth() or 1)
	end

	frame:SetWidth(max(width, 1))
	frame:SetHeight(detailVisible and 42 or 24)
end

local function hideNotice(noticeFrame)
	noticeFrame:Hide()
	noticeFrame:SetAlpha(1)
end

local function showNotice(_eventName, message, requestedDuration)
	if not message or message == "" then
		return false
	end

	local noticeFrame = ensureFrame()
	if not noticeFrame or not titleText then
		return false
	end
	if not (Effects and Effects.SetTimedFade) then
		return false
	end

	local duration = max(tonumber(requestedDuration) or DEFAULT_DURATION_SECONDS, 0.1)
	duration = min(duration, 5)

	titleText:SetText(colorizeTitle(message))
	if detailText then
		detailText:SetText("")
		detailText:Hide()
	end
	detailVisible = false
	updateFrameSize()
	noticeFrame:SetAlpha(1)
	noticeFrame:Show()
	Effects.SetTimedFade(noticeFrame, duration, FADE_SECONDS, hideNotice)
	return true
end

-- ----- Public methods ----- --
function ScreenNotice.Show(message, requestedDuration)
	return showNotice(nil, message, requestedDuration)
end

RegisterCallback(ScreenNoticeEvent, showNotice)
