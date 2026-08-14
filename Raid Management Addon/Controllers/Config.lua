-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: emits option-specific events; listens OptionsLoaded
local addon = select(2, ...)
local Diag = addon.Diag
local L = addon.L
local DebugEntryPoint = assert(addon.EntryPoints.Debug, Diag.A.ConfigDebugEntrypointNotInitialized)

local Database = addon.Database
local Options = addon.Options
local UI = addon.UI
local Frames = UI.Frames
local Scaffold = UI.Scaffold
local Layout = assert(UI.Layout, Diag.A.ConfigOptionsLayoutOwnerNotInitialized)
local ApplyOptionsRows = assert(Layout.ApplyRows, Diag.A.ConfigOptionsRowLayoutApplierNotInitialized)
local Popups = assert(UI.Popups, Diag.A.ConfigPopupNamespaceNotInitialized)
local ShowConfirmPopup = assert(Popups.ShowConfirm, Diag.A.ConfigConfirmPopupShowerNotInitialized)
local Strings = addon.Strings
local Events = addon.Events
local Bus = addon.Bus
local Services = addon.Services
local Controllers = addon.Controllers
local Widgets = addon.Widgets
local SpammerController = assert(Controllers.Spammer, Diag.A.ConfigSpammerControllerNotInitialized)
local WarningsController = assert(Controllers.Warnings, Diag.A.ConfigWarningsControllerNotInitialized)
local SpammerDraft = assert(Services.Spammer.Draft, Diag.A.ConfigSpammerDraftServiceNotInitialized)
local WarningStore = assert(Services.Warnings.Store, Diag.A.ConfigWarningsStoreServiceNotInitialized)
local InternalEvents = assert(Events.Internal, Diag.A.ConfigInternalEventsNotInitialized)
local RegisterCallback = assert(Bus.RegisterCallback, Diag.A.ConfigEventBusListenerNotInitialized)
local TriggerEvent = assert(Bus.TriggerEvent, Diag.A.ConfigEventBusSenderNotInitialized)
local BuildConfigOptionChangedName =
	assert(Events.BuildConfigOptionChangedName, Diag.A.ConfigOptionChangeEventResolverNotInitialized)
local OptionsLoadedEvent = assert(InternalEvents.OptionsLoaded, Diag.A.ConfigOptionsLoadedEventNotInitialized)
local ResetAllOptionDefaults = assert(Options.ResetAllDefaults, Diag.A.ConfigOptionsResetOperationNotInitialized)
local SetDebugEnabled = assert(Options.SetDebugEnabled, Diag.A.ConfigDebugOptionSetterNotInitialized)

local _G = _G
local InterfaceOptions_AddCategory =
	assert(_G.InterfaceOptions_AddCategory, Diag.A.ConfigInterfaceOptionsRegistrationApiNotInitialized)

local format = string.format
local gsub = string.gsub
local strlen = string.len
local strsub = string.sub
local type, tostring, tonumber = type, tostring, tonumber
local floor = math.floor

Controllers.Config = Controllers.Config or {}
local module = Controllers.Config

-- =========== Configuration Frame Module  =========== --
do
	local uiState = UI.ModuleState.Ensure(module)

	-- Namespace registration: generic UI options (tooltip toggle).
	-- Other options exposed by this widget are owned by their source modules
	-- (Master, Loot, Rolls, Reserves, Minimap, LootCounter).
	Options.RegisterNamespace("UI", {
		showTooltips = true,
	})

	local getFrame = Frames.MakeModuleFrameGetter(module, "RMAConfig")
	-- ----- Internal state ----- --

	local countdownDurationValues = { 3, 5, 7, 10, 13, 15, 20, 25, 30, 40, 50, 60 }
	local loggerLootQualityOptions = {
		{ value = 0, labelKey = "StrLootQualityPoor" },
		{ value = 2, labelKey = "StrLootQualityUncommon" },
		{ value = 3, labelKey = "StrLootQualityRare" },
		{ value = 4, labelKey = "StrLootQualityEpic" },
		{ value = 5, labelKey = "StrLootQualityLegendary" },
	}
	local MIN_COUNTDOWN = countdownDurationValues[1]
	local MAX_COUNTDOWN = countdownDurationValues[#countdownDurationValues]
	local DEFAULT_AUTO_MASTER_LOOT_NOTICE_SECONDS = 1.25
	local MIN_AUTO_MASTER_LOOT_NOTICE_SECONDS = 0.1
	local MAX_AUTO_MASTER_LOOT_NOTICE_SECONDS = 5
	local interfacePanelFrameName = "RMAInterfaceOptionsPanel"
	local masterLootPanelFrameName = "RMAInterfaceOptionsMasterLootPanel"
	local masterLootContentFrameName = "RMAInterfaceOptionsMasterLootPanelScrollChild"
	local quickBarPanelFrameName = "RMAInterfaceOptionsQuickBarPanel"
	local quickBarContentFrameName = "RMAInterfaceOptionsQuickBarPanelScrollChild"
	local lootHistoryPanelFrameName = "RMAInterfaceOptionsLootHistoryPanel"
	local lootHistoryContentFrameName = "RMAInterfaceOptionsLootHistoryPanelScrollChild"
	local lfmSpamPanelFrameName = "RMAInterfaceOptionsLFMSpamPanel"
	local lfmSpamContentFrameName = "RMAInterfaceOptionsLFMSpamPanelScrollChild"
	local raidWarningPanelFrameName = "RMAInterfaceOptionsRaidWarningPanel"
	local raidWarningContentFrameName = "RMAInterfaceOptionsRaidWarningPanelScrollChild"
	local helpPanelFrameName = "RMAInterfaceOptionsHelpPanel"
	local helpContentFrameName = "RMAInterfaceOptionsHelpPanelScrollChild"
	local cleanupPopupFrameName = "RMALootHistoryCleanupPopup"
	local interfacePanelBound = false
	local quickBarPanelBound = false
	local lootHistoryPanelBound = false
	local cleanupPopupBound = false
	local lfmSpamPanelBound = false
	local raidWarningPanelBound = false
	local interfacePanelsRegistered = false
	local refreshInterfaceOptionsPanel

	local optionSuffixes = {
		"sortAscending",
		"useRaidWarning",
		"countdownSimpleRaidMsg",
		"announceOnWin",
		"announceOnHold",
		"announceOnBank",
		"announceOnDisenchant",
		"lootWhispers",
		"countdownRollsBlock",
		"screenReminder",
		"ignoreStacks",
		"showTooltips",
		"showLootCounterDuringMSRoll",
		"minimapButton",
		"autoMasterLootOnBossTarget",
		"askGroupLootAfterBossLoot",
		"autoSpamLootOnLootOpened",
		"autoSpamSoftResOnLootOpened",
	}
	local quickBarButtonSuffixes = {
		ShowML = "ML",
		ShowGL = "GL",
		ShowSR = "SR",
		ShowHIS = "HIS",
		ShowRW = "RW",
	}
	local quickBarOrientations = {
		{ value = "horizontal", labelKey = "StrConfigQuickBarHorizontal" },
		{ value = "vertical", labelKey = "StrConfigQuickBarVertical" },
	}

	-- ----- Private helpers ----- --
	local function collectConfigRefs(frame, includeClose)
		local refs = {
			defaultsBtn = Frames.GetRef(frame, "DefaultsBtn"),
			countdownDuration = Frames.GetRef(frame, "countdownDuration"),
			autoMasterLootNoticeSecondsEditBox = Frames.GetRef(frame, "autoMasterLootNoticeSecondsEditBox"),
			options = {},
		}
		if includeClose then
			refs.closeBtn = Frames.GetRef(frame, "CloseBtn")
		end
		for i = 1, #optionSuffixes do
			local suffix = optionSuffixes[i]
			refs.options[suffix] = Frames.GetRef(frame, suffix)
		end
		return refs
	end

	function uiState.AcquireRefs(frame)
		return collectConfigRefs(frame, true)
	end

	local GetOptionByKey = Options.GetByKey

	-- ----- Public methods ----- --

	local function setText(frameName, suffix, value)
		local widget = _G[frameName .. suffix]
		if widget then
			widget:SetText(value)
		end
	end

	local function setChecked(frameName, suffix, checked)
		local widget = _G[frameName .. suffix]
		if widget then
			widget:SetChecked(checked == true)
		end
	end

	local function setOptionControlEnabled(frameName, suffix, enabled)
		local button = _G[frameName .. suffix]
		local label = _G[frameName .. suffix .. "Str"]
		local desc = _G[frameName .. suffix .. "Desc"]
		if button then
			if enabled and button.Enable then
				button:Enable()
			elseif button.Disable then
				button:Disable()
			end
		end
		if label and label.SetTextColor then
			if enabled then
				label:SetTextColor(HIGHLIGHT_FONT_COLOR.r, HIGHLIGHT_FONT_COLOR.g, HIGHLIGHT_FONT_COLOR.b)
			else
				label:SetTextColor(0.5, 0.5, 0.5)
			end
		end
		if desc and desc.SetTextColor then
			if enabled then
				desc:SetTextColor(NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
			else
				desc:SetTextColor(0.5, 0.5, 0.5)
			end
		end
	end

	local function getChecked(frameOrName, suffix)
		local widget = Frames.GetRef(frameOrName, suffix)
		if widget and widget.GetChecked then
			local checked = widget:GetChecked()
			return checked == true or checked == 1
		end
		return false
	end

	local function getEditBoxText(frameOrName, suffix)
		local widget = Frames.GetRef(frameOrName, suffix)
		if widget and widget.GetText then
			return Strings.TrimText(widget:GetText() or "") or ""
		end
		return ""
	end

	local function setEditBoxText(frameName, suffix, value)
		local widget = Frames.GetRef(frameName, suffix)
		if widget and widget.SetText then
			widget:SetText(value or "")
		end
	end

	local function formatCleanupOptionLabel(label, count)
		if count == nil then
			return label
		end
		return format("%s (%d)", label or "", tonumber(count) or 0)
	end

	local function normalizeCountdownDuration(value)
		local duration = tonumber(value) or 5
		local selected = countdownDurationValues[1]
		local selectedDelta = math.abs(duration - selected)
		for i = 2, #countdownDurationValues do
			local candidate = countdownDurationValues[i]
			local delta = math.abs(duration - candidate)
			if delta < selectedDelta then
				selected = candidate
				selectedDelta = delta
			end
		end
		return selected
	end

	local function normalizeAutoMasterLootNoticeSeconds(value)
		local text = tostring(value or "")
		local normalizedText = gsub(text, ",", ".")
		local seconds = tonumber(normalizedText) or DEFAULT_AUTO_MASTER_LOOT_NOTICE_SECONDS
		if seconds < MIN_AUTO_MASTER_LOOT_NOTICE_SECONDS then
			seconds = MIN_AUTO_MASTER_LOOT_NOTICE_SECONDS
		elseif seconds > MAX_AUTO_MASTER_LOOT_NOTICE_SECONDS then
			seconds = MAX_AUTO_MASTER_LOOT_NOTICE_SECONDS
		end
		return floor((seconds * 100) + 0.5) / 100
	end

	local NormalizeLoggerLootQualityThreshold = Options.NormalizeLoggerLootQualityThreshold

	local function getLoggerLootQualityLabel(value)
		local threshold = NormalizeLoggerLootQualityThreshold(value)
		for i = 1, #loggerLootQualityOptions do
			local option = loggerLootQualityOptions[i]
			if option.value == threshold then
				return L[option.labelKey] or tostring(threshold)
			end
		end
		return tostring(threshold)
	end

	local function setLoggerLootQualityDropDown(dropDown, value, enabled)
		if not dropDown then
			return
		end

		local threshold = NormalizeLoggerLootQualityThreshold(value)
		if UIDropDownMenu_SetText then
			UIDropDownMenu_SetText(dropDown, getLoggerLootQualityLabel(threshold))
		end
		if UIDropDownMenu_SetSelectedValue then
			UIDropDownMenu_SetSelectedValue(dropDown, threshold)
		end
		if enabled then
			if UIDropDownMenu_EnableDropDown then
				UIDropDownMenu_EnableDropDown(dropDown)
			end
		elseif UIDropDownMenu_DisableDropDown then
			UIDropDownMenu_DisableDropDown(dropDown)
		end
	end

	local function setCountdownDurationDisplay(frameName, value)
		local duration = normalizeCountdownDuration(value)
		local slider = _G[frameName .. "countdownDuration"]
		if slider then
			slider._RMASuppressOption = true
			slider:SetValue(duration)
			slider._RMASuppressOption = nil
		end
		setText(frameName, "countdownDurationText", duration)
		return duration
	end

	local function refreshAutoSpamSoftResDependency(frameName)
		local autoLootEnabled = GetOptionByKey("autoSpamLootOnLootOpened") == true
		if not autoLootEnabled and GetOptionByKey("autoSpamSoftResOnLootOpened") == true then
			Options.Set("autoSpamSoftResOnLootOpened", false)
		end
		setChecked(
			frameName,
			"autoSpamSoftResOnLootOpened",
			autoLootEnabled and GetOptionByKey("autoSpamSoftResOnLootOpened") == true
		)
		setOptionControlEnabled(frameName, "autoSpamSoftResOnLootOpened", autoLootEnabled)
	end

	local function setConfigTitle(frameName, titleText, plainTitle)
		if plainTitle then
			setText(frameName, "Title", titleText)
		else
			Frames.SetFrameTitle(frameName, titleText or SETTINGS)
		end
	end

	local function applyOptionsLayout(frameName, rows, cfg)
		return ApplyOptionsRows(frameName, rows, cfg)
	end

	local function getQuickBarWidget()
		local widget = Widgets.QuickBar
		if widget and widget.GetOrientation and widget.SetOrientation
			and widget.IsButtonShown and widget.SetButtonShown then
			return widget
		end
		return nil
	end

	local function layoutRootPanel()
		applyOptionsLayout(interfacePanelFrameName, {
			{ type = "title", suffix = "Title", gap = 18 },
			Layout.TextRow("OverviewTitle", "OverviewBody", { bodyHeight = 46, gap = 18 }),
			Layout.TextRow("WhatTitle", "WhatBody", { bodyHeight = 58, gap = 18 }),
			Layout.TextRow("HowTitle", "HowBody", { bodyHeight = 58, gap = 18 }),
			Layout.TextRow("WhyTitle", "WhyBody", { bodyHeight = 58, gap = 0 }),
		}, {
			contentWidth = 440,
			scrollChildWidth = 560,
			minHeight = 560,
		})
	end

	local optionsPanelLayoutCfg = {
		contentWidth = 380,
		scrollChildWidth = 420,
		textWidth = 240,
		commandWidth = 105,
		columnGap = 12,
		rowGap = 7,
		bottomPadding = 28,
		minHeight = 500,
	}

	local function layoutMasterLootPanel()
		local rows = {
			{ type = "title", suffix = "Title", gap = 16 },
		}
		for i = 1, #optionSuffixes do
			local suffix = optionSuffixes[i]
			rows[#rows + 1] = Layout.CheckRow(suffix, {
				descHeight = 22,
				height = 40,
				gap = 4,
			})
		end
		rows[#rows + 1] = Layout.EditRow("autoMasterLootNoticeSeconds", "autoMasterLootNoticeSecondsEditBox", {
			descHeight = 22,
			height = 40,
			gap = 10,
		})
		rows[#rows + 1] = Layout.SliderRow("countdownDuration", "countdownDuration", {
			descHeight = 20,
			height = 74,
			gap = 12,
		})
		rows[#rows + 1] = { type = "section", suffix = "PresetsTitle", gap = 10 }
		rows[#rows + 1] = Layout.CommandRow("DefaultsPreset", "DefaultsBtn", {
			descHeight = 34,
			height = 52,
			gap = 4,
		})
		rows[#rows + 1] = Layout.CommandRow("QuietPreset", "QuietPresetBtn", {
			descHeight = 34,
			height = 52,
			gap = 4,
		})
		rows[#rows + 1] = Layout.CommandRow("StandardPreset", "StandardPresetBtn", {
			descHeight = 34,
			height = 52,
			gap = 4,
		})
		rows[#rows + 1] = Layout.CommandRow("VerbosePreset", "VerbosePresetBtn", {
			descHeight = 34,
			height = 52,
			gap = 10,
		})
		rows[#rows + 1] = Layout.TextRow("AnnouncementPreviewTitle", "AnnouncementPreviewBody", {
			bodyHeight = 88,
			gap = 0,
		})
		applyOptionsLayout(masterLootContentFrameName, rows, optionsPanelLayoutCfg)
	end

	local function layoutQuickBarPanel()
		applyOptionsLayout(quickBarContentFrameName, {
			{ type = "title", suffix = "Title", gap = 16 },
			Layout.DropDownRow("Orientation", "OrientationDropDown", {
				descHeight = 22,
				height = 48,
				gap = 8,
			}),
			Layout.CheckRow("ShowML", { height = 40, gap = 4 }),
			Layout.CheckRow("ShowGL", { height = 40, gap = 4 }),
			Layout.CheckRow("ShowSR", { height = 40, gap = 4 }),
			Layout.CheckRow("ShowHIS", { height = 40, gap = 4 }),
			Layout.CheckRow("ShowRW", { height = 40, gap = 0 }),
		}, optionsPanelLayoutCfg)
	end

	local function layoutLootHistoryPanel()
		applyOptionsLayout(lootHistoryContentFrameName, {
			{ type = "title", suffix = "Title", gap = 16 },
			Layout.TextRow("ReportTitle", "ReportSummary", { bodyHeight = 116, gap = 16 }),
			Layout.CheckRow("IgnoreGroupLoot", {
				check = "IgnoreGroupLootCheck",
				height = 42,
				gap = 6,
			}),
			Layout.CheckRow("IgnoreSelectionThreshold", {
				check = "IgnoreSelectionThresholdCheck",
				height = 42,
				gap = 8,
			}),
			Layout.DropDownRow("LoggerLootQuality", "LoggerLootQualityDropDown", {
				descHeight = 34,
				height = 56,
				gap = 8,
			}),
			{ type = "section", suffix = "DataHealthTitle", gap = 10 },
			Layout.CommandRow("ScanHistory", "ScanHistoryBtn", {
				descHeight = 54,
				height = 74,
				gap = 14,
			}),
			{ type = "section", suffix = "MaintenanceTitle", gap = 10 },
			Layout.CommandRow("PurgeHistory", "PurgeHistoryBtn", {
				descHeight = 54,
				height = 74,
				gap = 8,
			}),
			Layout.CommandRow("RebuildSources", "RebuildSourcesBtn", {
				descHeight = 54,
				height = 74,
				gap = 8,
			}),
			Layout.CommandRow("CleanUp", "CleanUpBtn", {
				descHeight = 54,
				height = 74,
				gap = 0,
			}),
		}, optionsPanelLayoutCfg)
	end

	local function layoutLFMSpamPanel()
		applyOptionsLayout(lfmSpamContentFrameName, {
			{ type = "title", suffix = "Title", gap = 16 },
			Layout.TextRow("MessagePreviewTitle", "MessagePreviewBody", { bodyHeight = 66, gap = 8 }),
			Layout.ButtonRow({ "RefreshPreviewBtn", "ClearPreviewBtn" }, {
				buttonWidth = 105,
				buttonGap = 12,
				gap = 14,
			}),
			Layout.TextRow("SafetyTitle", "SafetyBody", { bodyHeight = 86, gap = 10 }),
			Layout.ButtonRow({ "OpenBtn", "StartBtn", "StopBtn" }, {
				buttonWidth = 105,
				buttonGap = 12,
				gap = 0,
			}),
		}, optionsPanelLayoutCfg)
	end

	local function layoutRaidWarningPanel()
		applyOptionsLayout(raidWarningContentFrameName, {
			{ type = "title", suffix = "Title", gap = 16 },
			Layout.TextRow("TemplatesTitle", "TemplatesBody", { bodyHeight = 44, gap = 8 }),
			Layout.ButtonRow({ "PreviewBtn", "OpenBtn" }, {
				buttonWidth = 105,
				buttonGap = 12,
				gap = 14,
			}),
			Layout.TextRow("PreviewTitle", "PreviewBody", { bodyHeight = 112, gap = 12 }),
			Layout.TextRow("PermissionTitle", "PermissionBody", { bodyHeight = 54, gap = 14 }),
			{ type = "section", suffix = "MaintenanceTitle", gap = 10 },
			Layout.CommandRow("ClearSaved", "ClearSavedBtn", {
				descHeight = 42,
				height = 62,
				gap = 0,
			}),
		}, optionsPanelLayoutCfg)
	end

	local function layoutHelpPanel()
		applyOptionsLayout(helpContentFrameName, {
			{ type = "title", suffix = "Title", gap = 16 },
			Layout.TextRow("MasterLootTitle", "MasterLootBody", { bodyHeight = 76, gap = 12 }),
			Layout.TextRow("LootHistoryTitle", "LootHistoryBody", { bodyHeight = 94, gap = 12 }),
			Layout.TextRow("LFMSpamTitle", "LFMSpamBody", { bodyHeight = 86, gap = 12 }),
			Layout.TextRow("RaidWarningTitle", "RaidWarningBody", { bodyHeight = 64, gap = 12 }),
			Layout.TextRow("CommandPermissionsTitle", "CommandPermissionsBody", {
				bodyHeight = 80,
				gap = 12,
			}),
			Layout.TextRow("DiagnosticsTitle", "DiagnosticsBody", { bodyHeight = 68, gap = 0 }),
			Layout.TextRow("CommandsTitle", "CommandsBody", { bodyHeight = 660, gap = 0 }),
		}, {
			contentWidth = 380,
			scrollChildWidth = 420,
			rowGap = 7,
			bottomPadding = 28,
			minHeight = 1280,
		})
	end

	local function layoutCleanupPopup()
		applyOptionsLayout(cleanupPopupFrameName, {
			{
				type = "title",
				suffix = "Title",
				leftX = 20,
				width = 340,
				height = 20,
				justifyH = "CENTER",
				gap = 10,
			},
			{ type = "body", suffix = "Body", leftX = 30, width = 320, height = 34, gap = 12 },
			Layout.CheckRow("EmptyRaids", {
				check = "EmptyRaidsCheck",
				label = "EmptyRaidsLabel",
				leftX = 30,
				textWidth = 292,
				descHeight = 34,
				height = 54,
				gap = 8,
			}),
			Layout.CheckRow("NonEpicLoot", {
				check = "NonEpicLootCheck",
				label = "NonEpicLootLabel",
				leftX = 30,
				textWidth = 292,
				descHeight = 34,
				height = 54,
				gap = 8,
			}),
			Layout.CheckRow("NoBossEncounter", {
				check = "NoBossEncounterCheck",
				label = "NoBossEncounterLabel",
				leftX = 30,
				textWidth = 292,
				descHeight = 34,
				height = 54,
				gap = 12,
			}),
			Layout.ButtonRow({ "DeleteBtn", "CancelBtn" }, {
				leftX = 62,
				buttonWidth = 110,
				buttonGap = 40,
				gap = 0,
			}),
		}, {
			contentWidth = 340,
			scrollChildWidth = 380,
			rowGap = 6,
			bottomPadding = 18,
			minHeight = 320,
			preserveFrameSize = true,
		})
	end

	local function localizeRootPanel()
		setText(interfacePanelFrameName, "Title", L.StrConfigPanelTitle)
		setText(interfacePanelFrameName, "OverviewTitle", L.StrConfigRootOverviewTitle)
		setText(interfacePanelFrameName, "OverviewBody", L.StrConfigRootOverviewBody)
		setText(interfacePanelFrameName, "WhatTitle", L.StrConfigRootWhatTitle)
		setText(interfacePanelFrameName, "WhatBody", L.StrConfigRootWhatBody)
		setText(interfacePanelFrameName, "HowTitle", L.StrConfigRootHowTitle)
		setText(interfacePanelFrameName, "HowBody", L.StrConfigRootHowBody)
		setText(interfacePanelFrameName, "WhyTitle", L.StrConfigRootWhyTitle)
		setText(interfacePanelFrameName, "WhyBody", L.StrConfigRootWhyBody)
		layoutRootPanel()
	end

	local function updateMasterLootPreview(frameName)
		if not frameName then
			return
		end
		local channel = (GetOptionByKey("useRaidWarning") == true) and (RAID_WARNING or L.StrConfigPanelRaidWarning) or "RAID"
		local countdownMode = (GetOptionByKey("countdownSimpleRaidMsg") == true) and L.StrConfigMasterLootPreviewSimple
			or L.StrConfigMasterLootPreviewDetailed
		local countdownDuration = tostring(GetOptionByKey("countdownDuration") or 5)
		local lines = {
			format(L.StrConfigMasterLootPreviewWin, channel),
			format(
				L.StrConfigMasterLootPreviewHold,
				GetOptionByKey("announceOnHold") and "on" or "off"
			),
			format(
				L.StrConfigMasterLootPreviewBank,
				GetOptionByKey("announceOnBank") and "on" or "off"
			),
			format(
				L.StrConfigMasterLootPreviewDisenchant,
				GetOptionByKey("announceOnDisenchant") and "on" or "off"
			),
			format(L.StrConfigMasterLootPreviewCountdown, countdownDuration, countdownMode),
		}
		setText(frameName, "AnnouncementPreviewBody", table.concat(lines, "\n"))
	end

	local function setOptions(values)
		if type(values) ~= "table" then
			return
		end
		for key, value in pairs(values) do
			Options.Set(key, value)
			local eventName = BuildConfigOptionChangedName(key)
			if eventName then
				TriggerEvent(eventName, value)
			end
		end
	end

	local function saveAutoMasterLootNoticeSeconds(editBox)
		if not editBox then
			return nil
		end
		local value = normalizeAutoMasterLootNoticeSeconds(editBox:GetText())
		setOptions({
			autoMasterLootNoticeSeconds = value,
		})
		editBox:SetText(tostring(value))
		return value
	end

	local function bindAutoMasterLootNoticeEditBox(editBox)
		if not editBox then
			return
		end
		Frames.SetScriptSafely(editBox, "OnEnterPressed", function(self)
			saveAutoMasterLootNoticeSeconds(self)
			self:ClearFocus()
		end)
		Frames.SetScriptSafely(editBox, "OnEditFocusLost", function(self)
			saveAutoMasterLootNoticeSeconds(self)
		end)
		Frames.SetScriptSafely(editBox, "OnEscapePressed", function(self)
			self:SetText(tostring(normalizeAutoMasterLootNoticeSeconds(GetOptionByKey("autoMasterLootNoticeSeconds"))))
			self:ClearFocus()
		end)
	end

	function module:ApplyMasterLootPreset(presetName)
		if presetName == "quiet" then
			setOptions({
				useRaidWarning = false,
				countdownSimpleRaidMsg = true,
				announceOnWin = true,
				announceOnHold = false,
				announceOnBank = false,
				announceOnDisenchant = false,
				lootWhispers = false,
				countdownDuration = 5,
			})
		elseif presetName == "verbose" then
			setOptions({
				useRaidWarning = true,
				countdownSimpleRaidMsg = false,
				announceOnWin = true,
				announceOnHold = true,
				announceOnBank = true,
				announceOnDisenchant = true,
				lootWhispers = true,
				countdownDuration = 10,
			})
		else
			setOptions({
				useRaidWarning = true,
				countdownSimpleRaidMsg = false,
				announceOnWin = true,
				announceOnHold = true,
				announceOnBank = false,
				announceOnDisenchant = false,
				lootWhispers = false,
				countdownDuration = 5,
			})
		end
		module:RequestRefresh("master_loot_preset")
		refreshInterfaceOptionsPanel()
		addon:info(L.MsgConfigPresetApplied)
	end

	local function localizeConfigControls(frameName, titleText, plainTitle)
		if not frameName then
			return
		end

		setText(frameName, "sortAscendingStr", L.StrConfigSortAscending)
		setText(frameName, "useRaidWarningStr", L.StrConfigUseRaidWarning)
		setText(frameName, "announceOnWinStr", L.StrConfigAnnounceOnWin)
		setText(frameName, "announceOnHoldStr", L.StrConfigAnnounceOnHold)
		setText(frameName, "announceOnBankStr", L.StrConfigAnnounceOnBank)
		setText(frameName, "announceOnDisenchantStr", L.StrConfigAnnounceOnDisenchant)
		setText(frameName, "lootWhispersStr", L.StrConfigLootWhisper)
		setText(frameName, "countdownRollsBlockStr", L.StrConfigCountdownRollsBlock)
		setText(frameName, "screenReminderStr", L.StrConfigScreenReminder)
		setText(frameName, "ignoreStacksStr", L.StrConfigIgnoreStacks)
		setText(frameName, "showTooltipsStr", L.StrConfigShowTooltips)
		setText(frameName, "showLootCounterDuringMSRollStr", L.StrConfigShowLootCounterDuringMSRoll)
		setText(frameName, "minimapButtonStr", L.StrConfigMinimapButton)
		setText(frameName, "autoMasterLootOnBossTargetStr", L.StrConfigAutoMasterLootOnBossTarget)
		setText(frameName, "autoMasterLootNoticeSecondsStr", L.StrConfigAutoMasterLootNoticeSeconds)
		setText(frameName, "askGroupLootAfterBossLootStr", L.StrConfigAskGroupLootAfterBossLoot)
		setText(frameName, "autoSpamLootOnLootOpenedStr", L.StrConfigAutoSpamLootOnLootOpened)
		setText(frameName, "autoSpamSoftResOnLootOpenedStr", L.StrConfigAutoSpamSoftResOnLootOpened)
		setText(frameName, "countdownDurationStr", L.StrConfigCountdownDuration)
		setText(frameName, "countdownSimpleRaidMsgStr", L.StrConfigCountdownSimpleRaidMsg)
		setText(frameName, "sortAscendingDesc", L.StrConfigSortAscendingDesc)
		setText(frameName, "useRaidWarningDesc", L.StrConfigUseRaidWarningDesc)
		setText(frameName, "announceOnWinDesc", L.StrConfigAnnounceOnWinDesc)
		setText(frameName, "announceOnHoldDesc", L.StrConfigAnnounceOnHoldDesc)
		setText(frameName, "announceOnBankDesc", L.StrConfigAnnounceOnBankDesc)
		setText(frameName, "announceOnDisenchantDesc", L.StrConfigAnnounceOnDisenchantDesc)
		setText(frameName, "lootWhispersDesc", L.StrConfigLootWhisperDesc)
		setText(frameName, "countdownRollsBlockDesc", L.StrConfigCountdownRollsBlockDesc)
		setText(frameName, "screenReminderDesc", L.StrConfigScreenReminderDesc)
		setText(frameName, "ignoreStacksDesc", L.StrConfigIgnoreStacksDesc)
		setText(frameName, "showTooltipsDesc", L.StrConfigShowTooltipsDesc)
		setText(frameName, "showLootCounterDuringMSRollDesc", L.StrConfigShowLootCounterDuringMSRollDesc)
		setText(frameName, "minimapButtonDesc", L.StrConfigMinimapButtonDesc)
		setText(frameName, "autoMasterLootOnBossTargetDesc", L.StrConfigAutoMasterLootOnBossTargetDesc)
		setText(frameName, "autoMasterLootNoticeSecondsDesc", L.StrConfigAutoMasterLootNoticeSecondsDesc)
		setText(frameName, "askGroupLootAfterBossLootDesc", L.StrConfigAskGroupLootAfterBossLootDesc)
		setText(frameName, "autoSpamLootOnLootOpenedDesc", L.StrConfigAutoSpamLootOnLootOpenedDesc)
		setText(frameName, "autoSpamSoftResOnLootOpenedDesc", L.StrConfigAutoSpamSoftResOnLootOpenedDesc)
		setText(frameName, "countdownDurationDesc", L.StrConfigCountdownDurationDesc)
		setText(frameName, "countdownSimpleRaidMsgDesc", L.StrConfigCountdownSimpleRaidMsgDesc)
		setText(frameName, "PresetsTitle", L.StrConfigMasterLootPresetsTitle)
		setText(frameName, "DefaultsPresetTitle", L.StrConfigMasterLootPresetDefaultsTitle)
		setText(frameName, "DefaultsPresetDesc", L.StrConfigMasterLootPresetDefaultsDesc)
		setText(frameName, "QuietPresetTitle", L.StrConfigMasterLootPresetQuietTitle)
		setText(frameName, "QuietPresetDesc", L.StrConfigMasterLootPresetQuietDesc)
		setText(frameName, "StandardPresetTitle", L.StrConfigMasterLootPresetStandardTitle)
		setText(frameName, "StandardPresetDesc", L.StrConfigMasterLootPresetStandardDesc)
		setText(frameName, "VerbosePresetTitle", L.StrConfigMasterLootPresetVerboseTitle)
		setText(frameName, "VerbosePresetDesc", L.StrConfigMasterLootPresetVerboseDesc)
		setText(frameName, "QuietPresetBtn", L.BtnConfigPresetQuiet)
		setText(frameName, "StandardPresetBtn", L.BtnConfigPresetStandard)
		setText(frameName, "VerbosePresetBtn", L.BtnConfigPresetVerbose)
		setText(frameName, "AnnouncementPreviewTitle", L.StrConfigMasterLootAnnouncementPreviewTitle)

		setConfigTitle(frameName, titleText, plainTitle)
		setText(frameName, "DefaultsBtn", L.BtnDefaults)
		setText(frameName, "CloseBtn", L.BtnClose)
		if frameName == masterLootContentFrameName then
			layoutMasterLootPanel()
		end
	end

	local function localizeQuickBarPanel()
		setText(quickBarContentFrameName, "Title", L.StrConfigPanelQuickBar)
		setText(quickBarContentFrameName, "OrientationStr", L.StrConfigQuickBarOrientation)
		setText(quickBarContentFrameName, "OrientationDesc", L.StrConfigQuickBarOrientationDesc)
		for suffix in pairs(quickBarButtonSuffixes) do
			setText(quickBarContentFrameName, suffix .. "Str", L["StrConfigQuickBar" .. suffix])
			setText(quickBarContentFrameName, suffix .. "Desc", L["StrConfigQuickBar" .. suffix .. "Desc"])
		end
		layoutQuickBarPanel()
	end

	local function refreshQuickBarPanel()
		local widget = getQuickBarWidget()
		local dropDown = Frames.GetRef(quickBarContentFrameName, "OrientationDropDown")
		if widget then
			local orientation = widget:GetOrientation()
			UIDropDownMenu_SetText(dropDown, orientation == "vertical"
				and L.StrConfigQuickBarVertical or L.StrConfigQuickBarHorizontal)
			UIDropDownMenu_SetSelectedValue(dropDown, orientation)
			if UIDropDownMenu_EnableDropDown then
				UIDropDownMenu_EnableDropDown(dropDown)
			end
		elseif UIDropDownMenu_DisableDropDown then
			UIDropDownMenu_DisableDropDown(dropDown)
		end
		for suffix, key in pairs(quickBarButtonSuffixes) do
			setChecked(quickBarContentFrameName, suffix, widget and widget:IsButtonShown(key) == true)
			setOptionControlEnabled(quickBarContentFrameName, suffix, widget ~= nil)
		end
	end

	local function onQuickBarOrientationClick(_button, _owner, value)
		local widget = getQuickBarWidget()
		if widget then
			widget:SetOrientation(value)
		end
		if CloseDropDownMenus then
			CloseDropDownMenus()
		end
		refreshQuickBarPanel()
	end

	local function initializeQuickBarOrientationDropDown()
		for i = 1, #quickBarOrientations do
			local option = quickBarOrientations[i]
			local info = UIDropDownMenu_CreateInfo()
			info.hasArrow = false
			info.notCheckable = 1
			info.text = L[option.labelKey]
			info.value = option.value
			info.func = onQuickBarOrientationClick
			info.arg1 = UIDROPDOWNMENU_OPEN_MENU
			info.arg2 = option.value
			UIDropDownMenu_AddButton(info, UIDROPDOWNMENU_MENU_LEVEL)
		end
	end

	local function bindQuickBarPanel()
		if quickBarPanelBound then
			return
		end
		local content = _G[quickBarContentFrameName]
		if not content then
			return
		end
		local dropDown = Frames.GetRef(content, "OrientationDropDown")
		UIDropDownMenu_Initialize(dropDown, initializeQuickBarOrientationDropDown)
		UIDropDownMenu_SetWidth(dropDown, 110)
		UIDropDownMenu_SetButtonWidth(dropDown, 130)
		for suffix, key in pairs(quickBarButtonSuffixes) do
			local buttonKey = key
			Frames.SetScriptSafely(Frames.GetRef(content, suffix), "OnClick", function(self)
				local widget = getQuickBarWidget()
				if widget then
					local checked = self:GetChecked()
					widget:SetButtonShown(buttonKey, checked == true or checked == 1)
				end
				refreshQuickBarPanel()
			end)
		end
		quickBarPanelBound = true
	end

	local function localizeHelpPanel()
		setText(helpContentFrameName, "Title", L.StrConfigPanelHelp)
		setText(helpContentFrameName, "MasterLootTitle", L.StrConfigHelpMasterLootTitle)
		setText(helpContentFrameName, "MasterLootBody", L.StrConfigHelpMasterLootBody)
		setText(helpContentFrameName, "LootHistoryTitle", L.StrConfigHelpLootHistoryTitle)
		setText(helpContentFrameName, "LootHistoryBody", L.StrConfigHelpLootHistoryBody)
		setText(helpContentFrameName, "LFMSpamTitle", L.StrConfigHelpLFMSpamTitle)
		setText(helpContentFrameName, "LFMSpamBody", L.StrConfigHelpLFMSpamBody)
		setText(helpContentFrameName, "RaidWarningTitle", L.StrConfigHelpRaidWarningTitle)
		setText(helpContentFrameName, "RaidWarningBody", L.StrConfigHelpRaidWarningBody)
		setText(helpContentFrameName, "CommandPermissionsTitle", L.StrConfigHelpCommandPermissionsTitle)
		setText(helpContentFrameName, "CommandPermissionsBody", L.StrConfigHelpCommandPermissionsBody)
		setText(helpContentFrameName, "DiagnosticsTitle", L.StrConfigHelpDiagnosticsTitle)
		setText(helpContentFrameName, "DiagnosticsBody", L.StrConfigHelpDiagnosticsBody)
		setText(helpContentFrameName, "CommandsTitle", L.StrConfigHelpCommandsTitle)
		setText(
			helpContentFrameName,
			"CommandsBody",
			L.StrConfigHelpCommandsBody .. "\n\n" .. DebugEntryPoint.GetHelpText()
		)
		layoutHelpPanel()
	end

	local function localizeLootHistoryPanel()
		setText(lootHistoryContentFrameName, "Title", L.StrLootHistory)
		setText(lootHistoryContentFrameName, "ReportTitle", L.StrConfigLootHistoryReportTitle)
		setText(lootHistoryContentFrameName, "IgnoreGroupLootStr", L.StrConfigLootHistoryIgnoreGroupLoot)
		setText(lootHistoryContentFrameName, "IgnoreGroupLootDesc", L.StrConfigLootHistoryIgnoreGroupLootDesc)
		setText(
			lootHistoryContentFrameName,
			"IgnoreSelectionThresholdStr",
			L.StrConfigLootHistoryIgnoreSelectionThreshold
		)
		setText(
			lootHistoryContentFrameName,
			"IgnoreSelectionThresholdDesc",
			L.StrConfigLootHistoryIgnoreSelectionThresholdDesc
		)
		setText(lootHistoryContentFrameName, "LoggerLootQualityTitle", L.StrConfigLootHistoryLoggerLootQuality)
		setText(lootHistoryContentFrameName, "LoggerLootQualityDesc", L.StrConfigLootHistoryLoggerLootQualityDesc)
		setText(lootHistoryContentFrameName, "DataHealthTitle", L.StrConfigLootHistoryDataHealthTitle)
		setText(lootHistoryContentFrameName, "ScanHistoryTitle", L.StrConfigLootHistoryScanHistoryTitle)
		setText(lootHistoryContentFrameName, "ScanHistoryDesc", L.StrConfigLootHistoryScanHistoryDesc)
		setText(lootHistoryContentFrameName, "ScanHistoryBtn", L.BtnLoggerScanHistory)
		setText(lootHistoryContentFrameName, "MaintenanceTitle", L.StrConfigLootHistoryMaintenanceTitle)
		setText(lootHistoryContentFrameName, "PurgeHistoryTitle", L.StrConfigLootHistoryPurgeHistoryTitle)
		setText(lootHistoryContentFrameName, "PurgeHistoryDesc", L.StrConfigLootHistoryPurgeHistoryDesc)
		setText(lootHistoryContentFrameName, "PurgeHistoryBtn", L.BtnLoggerPurgeHistory)
		setText(lootHistoryContentFrameName, "RebuildSourcesTitle", L.StrConfigLootHistoryRebuildSourcesTitle)
		setText(lootHistoryContentFrameName, "RebuildSourcesDesc", L.StrConfigLootHistoryRebuildSourcesDesc)
		setText(lootHistoryContentFrameName, "RebuildSourcesBtn", L.BtnLoggerRebuildSources)
		setText(lootHistoryContentFrameName, "CleanUpTitle", L.StrConfigLootHistoryCleanUpTitle)
		setText(lootHistoryContentFrameName, "CleanUpDesc", L.StrConfigLootHistoryCleanUpDesc)
		setText(lootHistoryContentFrameName, "CleanUpBtn", L.BtnLoggerCleanUp)
		layoutLootHistoryPanel()
	end

	local function localizeCleanupPopup(preview)
		preview = preview or {}
		setText(cleanupPopupFrameName, "Title", L.StrConfigLootHistoryCleanupPopupTitle)
		setText(cleanupPopupFrameName, "Body", L.StrConfigLootHistoryCleanupPopupBody)
		setText(
			cleanupPopupFrameName,
			"EmptyRaidsLabel",
			formatCleanupOptionLabel(L.StrConfigLootHistoryCleanupEmptyRaids, preview.emptyRaids)
		)
		setText(cleanupPopupFrameName, "EmptyRaidsDesc", L.StrConfigLootHistoryCleanupEmptyRaidsDesc)
		setText(
			cleanupPopupFrameName,
			"NonEpicLootLabel",
			formatCleanupOptionLabel(L.StrConfigLootHistoryCleanupNonEpicLoot, preview.nonEpicLoot)
		)
		setText(cleanupPopupFrameName, "NonEpicLootDesc", L.StrConfigLootHistoryCleanupNonEpicLootDesc)
		setText(
			cleanupPopupFrameName,
			"NoBossEncounterLabel",
			formatCleanupOptionLabel(L.StrConfigLootHistoryCleanupNoBossEncounter, preview.raidsWithoutBosses)
		)
		setText(cleanupPopupFrameName, "NoBossEncounterDesc", L.StrConfigLootHistoryCleanupNoBossEncounterDesc)
		setText(cleanupPopupFrameName, "DeleteBtn", L.BtnDelete)
		setText(cleanupPopupFrameName, "CancelBtn", L.BtnCancel)
		layoutCleanupPopup()
	end

	local function localizeLFMSpamPanel()
		setText(lfmSpamContentFrameName, "Title", L.StrLFMSpam)
		setText(lfmSpamContentFrameName, "MessagePreviewTitle", L.StrConfigLFMSpamPreviewTitle)
		setText(lfmSpamContentFrameName, "MessagePreviewBody", L.StrConfigLFMSpamPreviewPending)
		setText(lfmSpamContentFrameName, "SafetyTitle", L.StrConfigLFMSpamSafetyTitle)
		setText(lfmSpamContentFrameName, "SafetyBody", L.StrConfigLFMSpamSafetyBody)
		setText(lfmSpamContentFrameName, "OpenBtn", L.BtnOpen)
		setText(lfmSpamContentFrameName, "StartBtn", L.BtnStart)
		setText(lfmSpamContentFrameName, "StopBtn", L.BtnStop)
		setText(lfmSpamContentFrameName, "RefreshPreviewBtn", L.BtnRefresh)
		setText(lfmSpamContentFrameName, "ClearPreviewBtn", L.BtnClear)
		layoutLFMSpamPanel()
	end

	local function localizeRaidWarningPanel()
		setText(raidWarningContentFrameName, "Title", L.StrConfigPanelRaidWarning)
		setText(raidWarningContentFrameName, "TemplatesTitle", L.StrConfigRaidWarningTemplatesTitle)
		setText(raidWarningContentFrameName, "TemplatesBody", L.StrConfigRaidWarningTemplatesBody)
		setText(raidWarningContentFrameName, "PreviewTitle", L.StrConfigRaidWarningPreviewTitle)
		setText(raidWarningContentFrameName, "PreviewBody", L.StrConfigRaidWarningPreviewPending)
		setText(raidWarningContentFrameName, "PermissionTitle", L.StrConfigRaidWarningPermissionTitle)
		setText(raidWarningContentFrameName, "PermissionBody", L.StrConfigRaidWarningPermissionBody)
		setText(raidWarningContentFrameName, "MaintenanceTitle", L.StrConfigRaidWarningMaintenanceTitle)
		setText(raidWarningContentFrameName, "ClearSavedTitle", L.StrConfigRaidWarningClearSavedTitle)
		setText(raidWarningContentFrameName, "ClearSavedDesc", L.StrConfigRaidWarningClearSavedDesc)
		setText(raidWarningContentFrameName, "OpenBtn", L.BtnOpen)
		setText(raidWarningContentFrameName, "PreviewBtn", L.BtnPreview)
		setText(raidWarningContentFrameName, "ClearSavedBtn", L.BtnClearAll)
		layoutRaidWarningPanel()
	end

	local function refreshConfigControls(frameName)
		if not frameName then
			return
		end

		setChecked(frameName, "sortAscending", GetOptionByKey("sortAscending") == true)
		setChecked(frameName, "useRaidWarning", GetOptionByKey("useRaidWarning") == true)
		setChecked(frameName, "announceOnWin", GetOptionByKey("announceOnWin") == true)
		setChecked(frameName, "announceOnHold", GetOptionByKey("announceOnHold") == true)
		setChecked(frameName, "announceOnBank", GetOptionByKey("announceOnBank") == true)
		setChecked(frameName, "announceOnDisenchant", GetOptionByKey("announceOnDisenchant") == true)
		setChecked(frameName, "lootWhispers", GetOptionByKey("lootWhispers") == true)
		setChecked(frameName, "countdownRollsBlock", GetOptionByKey("countdownRollsBlock") == true)
		setChecked(frameName, "screenReminder", GetOptionByKey("screenReminder") == true)
		setChecked(frameName, "ignoreStacks", GetOptionByKey("ignoreStacks") == true)
		setChecked(frameName, "showTooltips", GetOptionByKey("showTooltips") == true)
		setChecked(frameName, "showLootCounterDuringMSRoll", GetOptionByKey("showLootCounterDuringMSRoll") == true)
		setChecked(frameName, "minimapButton", GetOptionByKey("minimapButton") == true)
		setChecked(frameName, "countdownSimpleRaidMsg", GetOptionByKey("countdownSimpleRaidMsg") == true)
		setChecked(frameName, "autoSpamLootOnLootOpened", GetOptionByKey("autoSpamLootOnLootOpened") == true)
		for i = 1, #optionSuffixes do
			local suffix = optionSuffixes[i]
			setChecked(frameName, suffix, GetOptionByKey(suffix) == true)
		end

		setEditBoxText(
			frameName,
			"autoMasterLootNoticeSecondsEditBox",
			tostring(normalizeAutoMasterLootNoticeSeconds(GetOptionByKey("autoMasterLootNoticeSeconds")))
		)
		setCountdownDurationDisplay(frameName, GetOptionByKey("countdownDuration"))
		refreshAutoSpamSoftResDependency(frameName)

		local useRaidWarning = GetOptionByKey("useRaidWarning") == true
		local countdownSimpleRaidMsgBtn = _G[frameName .. "countdownSimpleRaidMsg"]
		local countdownSimpleRaidMsgStr = _G[frameName .. "countdownSimpleRaidMsgStr"]

		if countdownSimpleRaidMsgBtn and countdownSimpleRaidMsgStr then
			if useRaidWarning then
				countdownSimpleRaidMsgBtn:Enable()
				countdownSimpleRaidMsgStr:SetTextColor(
					HIGHLIGHT_FONT_COLOR.r,
					HIGHLIGHT_FONT_COLOR.g,
					HIGHLIGHT_FONT_COLOR.b
				)
			else
				countdownSimpleRaidMsgBtn:Disable()
				countdownSimpleRaidMsgStr:SetTextColor(0.5, 0.5, 0.5)
			end
		end
		updateMasterLootPreview(frameName)
	end

	refreshInterfaceOptionsPanel = function()
		refreshConfigControls(masterLootContentFrameName)
	end

	-- Loads the default options into the settings table.
	local function loadDefaultOptions()
		ResetAllOptionDefaults()
		SetDebugEnabled(false)
		module:RequestRefresh("defaults")
		refreshInterfaceOptionsPanel()
		addon:info(L.MsgDefaultsRestored)
	end

	local function loadConfigFrame(frame)
		uiState.FrameName = Frames.BindModuleFrame(module, frame, {
			enableDrag = true,
			hookOnShow = function()
				module:MarkDirty("show")
			end,
		}) or uiState.FrameName
		if not uiState.FrameName then
			return
		end
	end

	local function initCountdownSlider(slider)
		if not slider then
			return
		end
		local sliderName = slider:GetName()
		if not sliderName then
			return
		end
		slider:SetMinMaxValues(MIN_COUNTDOWN, MAX_COUNTDOWN)
		slider:SetValueStep(1)
		local low = _G[sliderName .. "Low"]
		if low then
			low:SetText(tostring(MIN_COUNTDOWN))
		end
		local high = _G[sliderName .. "High"]
		if high then
			high:SetText(tostring(MAX_COUNTDOWN))
		end
	end

	-- OnClick handler for option controls.
	local function onOptionClick(btn, frameName)
		if not btn then
			return
		end
		if btn._RMASuppressOption == true then
			return
		end
		if not frameName and btn.GetParent then
			local parent = btn:GetParent()
			frameName = parent and parent.GetName and parent:GetName() or nil
		end
		if not frameName then
			return
		end

		local value
		local name = btn:GetName()
		if type(name) ~= "string" or name == "" then
			return
		end

		if name ~= frameName .. "countdownDuration" then
			value = (btn:GetChecked() == 1) or false
			if name == frameName .. "minimapButton" then
				addon.Minimap:SetMinimapButtonShown(value)
			end
		else
			value = normalizeCountdownDuration(btn:GetValue())
			if btn.SetValue and btn:GetValue() ~= value then
				btn._RMASuppressOption = true
				btn:SetValue(value)
				btn._RMASuppressOption = nil
			end
			setText(frameName, "countdownDurationText", value)
		end

		name = strsub(name, strlen(frameName) + 1)
		if name == "autoSpamLootOnLootOpened" and value ~= true then
			Options.Set("autoSpamSoftResOnLootOpened", false)
		end
		Options.Set(name, value)
		local eventName = BuildConfigOptionChangedName(name)
		if eventName then
			TriggerEvent(eventName, value)
		end

		module:RequestRefresh("option_changed")
		refreshInterfaceOptionsPanel()
	end

	local function bindConfigHandlers(frameName, refs, includeClose)
		if not refs then
			return
		end
		if includeClose then
			Frames.SetScriptSafely(refs.closeBtn, "OnClick", function()
				module:Hide()
			end)
		end
		Frames.SetScriptSafely(refs.defaultsBtn, "OnClick", function()
			loadDefaultOptions()
		end)
		Frames.SetScriptSafely(refs.countdownDuration, "OnValueChanged", function(self)
			onOptionClick(self, frameName)
		end)
		initCountdownSlider(refs.countdownDuration)
		bindAutoMasterLootNoticeEditBox(refs.autoMasterLootNoticeSecondsEditBox)

		for i = 1, #optionSuffixes do
			local suffix = optionSuffixes[i]
			local optionBtn = refs.options[suffix]
			Frames.SetScriptSafely(optionBtn, "OnClick", function(self)
				onOptionClick(self, frameName)
			end)
		end
	end

	local function scanCleanupPreview()
		local actions = Services.Logger.Actions
		if actions and actions.ScanRaidHistory then
			return actions:ScanRaidHistory()
		end
		return nil
	end

	local function formatLootHistoryReport(result)
		result = result or {}
		return format(
			L.StrConfigLootHistoryReportSummary,
			tonumber(result.raids) or 0,
			tonumber(result.emptyRaids) or 0,
			tonumber(result.raidsWithoutBosses) or 0,
			tonumber(result.nonEpicLoot) or 0,
			tonumber(result.missingSources) or 0,
			tonumber(result.invalidSources) or 0,
			tonumber(result.orphanLoot) or 0,
			tonumber(result.duplicateRaidCandidates) or 0
		)
	end

	local function refreshLootHistoryReport()
		local actions = Services.Logger.Actions
		if not (actions and actions.ScanRaidHistory) then
			setText(lootHistoryContentFrameName, "ReportSummary", formatLootHistoryReport(nil))
			return nil
		end
		local result = actions:ScanRaidHistory()
		setText(lootHistoryContentFrameName, "ReportSummary", formatLootHistoryReport(result))
		return result
	end

	local function refreshLootHistorySyncControls()
		local thresholdOverride = GetOptionByKey("ignoreSelectionThreshold") == true
		setChecked(lootHistoryContentFrameName, "IgnoreGroupLootCheck", GetOptionByKey("ignoreGroupLoot") == true)
		setChecked(lootHistoryContentFrameName, "IgnoreSelectionThresholdCheck", thresholdOverride)
		setLoggerLootQualityDropDown(
			Frames.GetRef(lootHistoryContentFrameName, "LoggerLootQualityDropDown"),
			GetOptionByKey("loggerLootQualityThreshold"),
			thresholdOverride
		)
	end

	local function refreshLootHistoryPanel()
		local result = refreshLootHistoryReport()
		refreshLootHistorySyncControls()
		return result
	end

	function module:RequestLoggerMaintenance(actionName, options)
		local actions = Services.Logger.Actions
		if not actions then
			addon:warn(L.MsgLoggerMaintenanceUnavailable)
			return nil
		end

		local result
		if actionName == "scan" and actions.StartRaidHistoryScan then
			return actions:StartRaidHistoryScan(function(scanResult)
				setText(lootHistoryContentFrameName, "ReportSummary", formatLootHistoryReport(scanResult))
				addon:info(
					L.MsgLoggerHistoryScanned:format(
						tonumber(scanResult and scanResult.raids) or 0,
						tonumber(scanResult and scanResult.emptyRaids) or 0,
						tonumber(scanResult and scanResult.missingSources) or 0,
						tonumber(scanResult and scanResult.invalidSources) or 0
					)
				)
			end)
		elseif actionName == "scan" and actions.ScanRaidHistory then
			result = refreshLootHistoryReport()
			addon:info(
				L.MsgLoggerHistoryScanned:format(
					tonumber(result and result.raids) or 0,
					tonumber(result and result.emptyRaids) or 0,
					tonumber(result and result.missingSources) or 0,
					tonumber(result and result.invalidSources) or 0
				)
			)
		elseif actionName == "purge" and actions.PurgeRaidHistory then
			result = actions:PurgeRaidHistory()
			addon:info(L.MsgLoggerHistoryPurged:format(tonumber(result and result.removed) or 0))
		elseif actionName == "rebuildSources" and actions.StartLootSourceRebuild then
			return actions:StartLootSourceRebuild(function(rebuildResult, complete)
				if complete ~= true then
					if rebuildResult and rebuildResult.partial then
						addon:warn(
							L.MsgLoggerMaintenancePartial:format(
								tonumber(rebuildResult.bossesCreated) or 0,
								tonumber(rebuildResult.repaired) or 0
							)
						)
						refreshLootHistoryReport()
					end
					return
				end
				addon:info(
					L.MsgLoggerLootSourcesRebuilt:format(
						tonumber(rebuildResult and rebuildResult.repaired) or 0,
						tonumber(rebuildResult and rebuildResult.bossesCreated) or 0,
						tonumber(rebuildResult and rebuildResult.unresolved) or 0
					)
				)
				refreshLootHistoryReport()
			end)
		elseif actionName == "rebuildSources" and actions.RebuildLootSources then
			result = actions:RebuildLootSources()
			addon:info(
				L.MsgLoggerLootSourcesRebuilt:format(
					tonumber(result and result.repaired) or 0,
					tonumber(result and result.bossesCreated) or 0,
					tonumber(result and result.unresolved) or 0
				)
			)
		elseif actionName == "cleanUp" and actions.StartRaidHistoryCleanup then
			options = options or {}
			if options.emptyRaids ~= true and options.nonEpicLoot ~= true and options.noBossEncounter ~= true then
				addon:warn(L.MsgLoggerCleanupNoSelection)
				return nil
			end
			return actions:StartRaidHistoryCleanup(function(cleanupResult, complete)
				if complete ~= true then
					if cleanupResult and cleanupResult.partial then
						addon:warn(
							L.MsgLoggerMaintenancePartial:format(
								tonumber(cleanupResult.raidsRemoved) or 0,
								tonumber(cleanupResult.lootRemoved) or 0
							)
						)
						refreshLootHistoryReport()
					end
					return
				end
				addon:info(
					L.MsgLoggerCleanupDone:format(
						tonumber(cleanupResult and cleanupResult.raidsRemoved) or 0,
						tonumber(cleanupResult and cleanupResult.lootRemoved) or 0
					)
				)
				refreshLootHistoryReport()
			end, options)
		elseif actionName == "cleanUp" and actions.CleanupRaidHistory then
			options = options or {}
			if options.emptyRaids ~= true and options.nonEpicLoot ~= true and options.noBossEncounter ~= true then
				addon:warn(L.MsgLoggerCleanupNoSelection)
				return nil
			end
			result = actions:CleanupRaidHistory(options)
			addon:info(
				L.MsgLoggerCleanupDone:format(
					tonumber(result and result.raidsRemoved) or 0,
					tonumber(result and result.lootRemoved) or 0
				)
			)
		else
			addon:warn(L.MsgLoggerMaintenanceUnavailable)
			return nil
		end

		if actionName ~= "scan" then
			refreshLootHistoryReport()
		end
		return result
	end

	local function showConfirmOrRun(popupKey, actionName)
		ShowConfirmPopup(popupKey, L.StrConfirmPurgeLootHistory, function()
			module:RequestLoggerMaintenance(actionName)
		end)
	end

	local function resetCleanupPopupOptions(frame)
		if not frame then
			return
		end
		local emptyRaidsCheck = Frames.GetRef(frame, "EmptyRaidsCheck")
		local nonEpicLootCheck = Frames.GetRef(frame, "NonEpicLootCheck")
		local noBossEncounterCheck = Frames.GetRef(frame, "NoBossEncounterCheck")
		if emptyRaidsCheck and emptyRaidsCheck.SetChecked then
			emptyRaidsCheck:SetChecked(false)
		end
		if nonEpicLootCheck and nonEpicLootCheck.SetChecked then
			nonEpicLootCheck:SetChecked(false)
		end
		if noBossEncounterCheck and noBossEncounterCheck.SetChecked then
			noBossEncounterCheck:SetChecked(false)
		end
	end

	local function bindCleanupPopup()
		if cleanupPopupBound then
			return true
		end
		local frame = _G[cleanupPopupFrameName]
		if not frame then
			return false
		end

		local deleteBtn = Frames.GetRef(frame, "DeleteBtn")
		local cancelBtn = Frames.GetRef(frame, "CancelBtn")
		Frames.SetScriptSafely(deleteBtn, "OnClick", function()
			module:RequestLoggerMaintenance("cleanUp", {
				emptyRaids = getChecked(frame, "EmptyRaidsCheck"),
				nonEpicLoot = getChecked(frame, "NonEpicLootCheck"),
				noBossEncounter = getChecked(frame, "NoBossEncounterCheck"),
			})
			frame:Hide()
		end)
		Frames.SetScriptSafely(cancelBtn, "OnClick", function()
			frame:Hide()
		end)

		cleanupPopupBound = true
		return true
	end

	local function showCleanupPopup()
		local frame = _G[cleanupPopupFrameName]
		if not frame then
			addon:warn(L.MsgLoggerMaintenanceUnavailable)
			return
		end
		bindCleanupPopup()
		localizeCleanupPopup(scanCleanupPreview())
		resetCleanupPopupOptions(frame)
		frame:Show()
		if frame.Raise then
			frame:Raise()
		end
	end

	local function saveLootHistoryOption(optionKey, value)
		setOptions({
			[optionKey] = value,
		})
		refreshLootHistorySyncControls()
	end

	local function onLoggerLootQualityDropDownClick(_button, owner, value)
		local threshold = NormalizeLoggerLootQualityThreshold(value)
		saveLootHistoryOption("loggerLootQualityThreshold", threshold)
		if owner then
			setLoggerLootQualityDropDown(owner, threshold, GetOptionByKey("ignoreSelectionThreshold") == true)
		end
		if CloseDropDownMenus then
			CloseDropDownMenus()
		end
	end

	local function initializeLoggerLootQualityDropDown()
		for i = 1, #loggerLootQualityOptions do
			local option = loggerLootQualityOptions[i]
			local info = UIDropDownMenu_CreateInfo()
			info.hasArrow = false
			info.notCheckable = 1
			info.text = getLoggerLootQualityLabel(option.value)
			info.value = option.value
			info.func = onLoggerLootQualityDropDownClick
			info.arg1 = UIDROPDOWNMENU_OPEN_MENU
			info.arg2 = option.value
			UIDropDownMenu_AddButton(info, UIDROPDOWNMENU_MENU_LEVEL)
		end
	end

	local function bindLootHistoryPanel()
		if lootHistoryPanelBound then
			return
		end
		local content = _G[lootHistoryContentFrameName]
		if not content then
			return
		end

		local scanBtn = Frames.GetRef(content, "ScanHistoryBtn")
		local purgeBtn = Frames.GetRef(content, "PurgeHistoryBtn")
		local rebuildSourcesBtn = Frames.GetRef(content, "RebuildSourcesBtn")
		local cleanUpBtn = Frames.GetRef(content, "CleanUpBtn")
		local ignoreGroupLootCheck = Frames.GetRef(content, "IgnoreGroupLootCheck")
		local ignoreSelectionThresholdCheck = Frames.GetRef(content, "IgnoreSelectionThresholdCheck")
		local loggerLootQualityDropDown = Frames.GetRef(content, "LoggerLootQualityDropDown")

		Frames.SetScriptSafely(scanBtn, "OnClick", function()
			module:RequestLoggerMaintenance("scan")
		end)
		Frames.SetScriptSafely(purgeBtn, "OnClick", function()
			showConfirmOrRun("RMA_CONFIG_PURGE_LOOT_HISTORY", "purge")
		end)
		Frames.SetScriptSafely(rebuildSourcesBtn, "OnClick", function()
			module:RequestLoggerMaintenance("rebuildSources")
		end)
		Frames.SetScriptSafely(cleanUpBtn, "OnClick", function()
			showCleanupPopup()
		end)
		Frames.SetScriptSafely(ignoreGroupLootCheck, "OnClick", function(self)
			local checked = self:GetChecked()
			saveLootHistoryOption("ignoreGroupLoot", checked == true or checked == 1)
		end)
		Frames.SetScriptSafely(ignoreSelectionThresholdCheck, "OnClick", function(self)
			local checked = self:GetChecked()
			saveLootHistoryOption("ignoreSelectionThreshold", checked == true or checked == 1)
		end)
		if loggerLootQualityDropDown and UIDropDownMenu_Initialize then
			UIDropDownMenu_Initialize(loggerLootQualityDropDown, initializeLoggerLootQualityDropDown)
			if UIDropDownMenu_SetWidth then
				UIDropDownMenu_SetWidth(loggerLootQualityDropDown, 72)
			end
			if UIDropDownMenu_SetButtonWidth then
				UIDropDownMenu_SetButtonWidth(loggerLootQualityDropDown, 92)
			end
			if UIDropDownMenu_JustifyText then
				UIDropDownMenu_JustifyText(loggerLootQualityDropDown, "LEFT")
			end
		end
		lootHistoryPanelBound = true
	end

	function module:RequestSpammerPanelAction(actionName)
		local result
		if actionName == "open" then
			SpammerController:Toggle()
		elseif actionName == "start" then
			SpammerController:RequestStart()
		elseif actionName == "stop" then
			SpammerController:RequestStop()
		elseif actionName == "clear" then
			result = SpammerController:RequestClearDraft()
		else
			result = SpammerDraft.BuildPreview(SpammerDraft.GetStore(), SpammerDraft.GetDefaultOutput())
		end
		if result and result.output then
			local previewLength = format(L.StrConfigLFMSpamPreviewLength, tonumber(result.length) or 0)
			setText(lfmSpamContentFrameName, "MessagePreviewBody", result.output .. "\n" .. previewLength)
		end
		return result
	end

	local function bindLFMSpamPanel()
		if lfmSpamPanelBound then
			return
		end
		local content = _G[lfmSpamContentFrameName]
		if not content then
			return
		end

		Frames.SetScriptSafely(Frames.GetRef(content, "OpenBtn"), "OnClick", function()
			module:RequestSpammerPanelAction("open")
		end)
		Frames.SetScriptSafely(Frames.GetRef(content, "StartBtn"), "OnClick", function()
			module:RequestSpammerPanelAction("start")
		end)
		Frames.SetScriptSafely(Frames.GetRef(content, "StopBtn"), "OnClick", function()
			module:RequestSpammerPanelAction("stop")
		end)
		Frames.SetScriptSafely(Frames.GetRef(content, "RefreshPreviewBtn"), "OnClick", function()
			module:RequestSpammerPanelAction("preview")
		end)
		Frames.SetScriptSafely(Frames.GetRef(content, "ClearPreviewBtn"), "OnClick", function()
			module:RequestSpammerPanelAction("clear")
		end)

		lfmSpamPanelBound = true
	end

	function module:RequestRaidWarningPanelAction(actionName, includeStock)
		local result, reason
		if actionName == "open" then
			WarningsController:Toggle()
		elseif actionName == "clearSaved" then
			result, reason = WarningStore.ClearSavedWarnings(includeStock == true)
			if result == nil then
				addon:error(L.ErrWarningClear, reason or "clear_failed")
				return nil, reason or "clear_failed"
			end
			addon:info(L.MsgRaidWarningsCleared:format(tonumber(result and result.removed) or 0))
			local preview = WarningStore.BuildTemplatePreview(L.StrConfigRaidWarningPreviewEmpty or "")
			if preview and preview.text then
				setText(raidWarningContentFrameName, "PreviewBody", preview.text)
			end
		else
			result = WarningStore.BuildTemplatePreview(L.StrConfigRaidWarningPreviewEmpty or "")
			if result and result.text then
				setText(raidWarningContentFrameName, "PreviewBody", result.text)
			end
		end
		return result
	end

	local function showRaidWarningConfirmOrRun(popupKey, actionName)
		ShowConfirmPopup(
			popupKey,
			L.StrConfirmClearRaidWarnings,
			function()
				module:RequestRaidWarningPanelAction(actionName, true)
			end,
			popupKey,
			{
				button1 = YES or "Yes",
				button2 = NO or "No",
				button3 = CANCEL or L.BtnCancel,
				onCancel = function(_, _, reason)
					if reason == "clicked" then
						module:RequestRaidWarningPanelAction(actionName, false)
					end
				end,
			}
		)
	end

	local function bindRaidWarningPanel()
		if raidWarningPanelBound then
			return
		end
		local content = _G[raidWarningContentFrameName]
		if not content then
			return
		end

		Frames.SetScriptSafely(Frames.GetRef(content, "OpenBtn"), "OnClick", function()
			module:RequestRaidWarningPanelAction("open")
		end)
		Frames.SetScriptSafely(Frames.GetRef(content, "PreviewBtn"), "OnClick", function()
			module:RequestRaidWarningPanelAction("preview")
		end)
		Frames.SetScriptSafely(Frames.GetRef(content, "ClearSavedBtn"), "OnClick", function()
			showRaidWarningConfirmOrRun("RMA_CONFIG_CLEAR_RAID_WARNINGS", "clearSaved")
		end)
		raidWarningPanelBound = true
	end

	local function BindHandlers(frameName, _, refs)
		bindConfigHandlers(frameName, refs, true)
	end

	local function bindInterfaceOptionsPanel(panel)
		if interfacePanelBound or not panel then
			return
		end

		local content = _G[masterLootContentFrameName]
		if not content then
			return
		end

		local refs = collectConfigRefs(content, false)
		bindConfigHandlers(masterLootContentFrameName, refs, false)
		Frames.SetScriptSafely(Frames.GetRef(content, "QuietPresetBtn"), "OnClick", function()
			module:ApplyMasterLootPreset("quiet")
		end)
		Frames.SetScriptSafely(Frames.GetRef(content, "StandardPresetBtn"), "OnClick", function()
			module:ApplyMasterLootPreset("standard")
		end)
		Frames.SetScriptSafely(Frames.GetRef(content, "VerbosePresetBtn"), "OnClick", function()
			module:ApplyMasterLootPreset("verbose")
		end)
		localizeConfigControls(masterLootContentFrameName, L.StrConfigPanelMasterLoot, true)
		refreshConfigControls(masterLootContentFrameName)
		if panel.HookScript then
			Frames.HookScriptSafely(panel, "OnShow", function()
				refreshConfigControls(masterLootContentFrameName)
			end)
		end
		interfacePanelBound = true
	end

	local function getInterfacePanelSpecs()
		return {
			{
				frameName = interfacePanelFrameName,
				title = L.StrConfigPanelTitle,
				root = true,
			},
			{
				frameName = masterLootPanelFrameName,
				title = L.StrConfigPanelMasterLoot,
				parent = L.StrConfigPanelTitle,
				controls = true,
			},
			{
				frameName = quickBarPanelFrameName,
				title = L.StrConfigPanelQuickBar,
				parent = L.StrConfigPanelTitle,
				quickBar = true,
			},
			{
				frameName = lootHistoryPanelFrameName,
				title = L.StrLootHistory,
				parent = L.StrConfigPanelTitle,
				maintenance = true,
			},
			{
				frameName = lfmSpamPanelFrameName,
				title = L.StrLFMSpam,
				parent = L.StrConfigPanelTitle,
				lfmSpam = true,
			},
			{
				frameName = raidWarningPanelFrameName,
				title = L.StrConfigPanelRaidWarning,
				parent = L.StrConfigPanelTitle,
				raidWarning = true,
			},
			{
				frameName = helpPanelFrameName,
				title = L.StrConfigPanelHelp,
				parent = L.StrConfigPanelTitle,
				help = true,
			},
		}
	end

	local function registerInterfaceOptionsPanel()
		if interfacePanelsRegistered then
			return true
		end

		local specs = getInterfacePanelSpecs()
		for i = 1, #specs do
			local spec = specs[i]
			local panel = _G[spec.frameName]
			if not panel then
				return false
			end

			panel.name = spec.title
			panel.parent = spec.parent
			setConfigTitle(spec.frameName, spec.title, true)

			if spec.controls then
				panel.default = function()
					loadDefaultOptions()
				end
				panel.refresh = function()
					refreshConfigControls(masterLootContentFrameName)
				end
				panel.cancel = function()
					refreshConfigControls(masterLootContentFrameName)
				end
				bindInterfaceOptionsPanel(panel)
			elseif spec.quickBar then
				localizeQuickBarPanel()
				bindQuickBarPanel()
				refreshQuickBarPanel()
				if panel.HookScript then
					Frames.HookScriptSafely(panel, "OnShow", function()
						localizeQuickBarPanel()
						bindQuickBarPanel()
						refreshQuickBarPanel()
					end)
				end
			elseif spec.root then
				localizeRootPanel()
				if panel.HookScript then
					Frames.HookScriptSafely(panel, "OnShow", function()
						localizeRootPanel()
					end)
				end
			elseif spec.maintenance then
				localizeLootHistoryPanel()
				bindLootHistoryPanel()
				refreshLootHistoryPanel()
				if panel.HookScript then
					Frames.HookScriptSafely(panel, "OnShow", function()
						localizeLootHistoryPanel()
						bindLootHistoryPanel()
						refreshLootHistoryPanel()
					end)
				end
			elseif spec.lfmSpam then
				localizeLFMSpamPanel()
				bindLFMSpamPanel()
				if panel.HookScript then
					Frames.HookScriptSafely(panel, "OnShow", function()
						localizeLFMSpamPanel()
						bindLFMSpamPanel()
						module:RequestSpammerPanelAction("preview")
					end)
				end
			elseif spec.raidWarning then
				localizeRaidWarningPanel()
				bindRaidWarningPanel()
				if panel.HookScript then
					Frames.HookScriptSafely(panel, "OnShow", function()
						localizeRaidWarningPanel()
						bindRaidWarningPanel()
						module:RequestRaidWarningPanelAction("preview")
					end)
				end
			elseif spec.help then
				localizeHelpPanel()
				if panel.HookScript then
					Frames.HookScriptSafely(panel, "OnShow", function()
						localizeHelpPanel()
					end)
				end
			end

			InterfaceOptions_AddCategory(panel)
		end

		interfacePanelsRegistered = true
		return true
	end

	local function OnLoadFrame(frame)
		loadConfigFrame(frame)
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
		refresh = function(_, _, _, dirty)
			uiState.Refresh(dirty)
		end,
	})

	-- Localizes UI elements.
	function uiState.Localize()
		local frameName = uiState.FrameName
		if not frameName then
			return
		end

		localizeConfigControls(frameName, SETTINGS)
	end

	-- UI refresh handler for the configuration frame.
	function uiState.Refresh(dirty)
		if not dirty and not uiState.Dirty then
			return
		end

		local frameName = uiState.FrameName
		if not frameName then
			return
		end
		refreshConfigControls(frameName)

		uiState.Dirty = false
	end

	function module:Default()
		return loadDefaultOptions()
	end

	RegisterCallback(OptionsLoadedEvent, function()
		registerInterfaceOptionsPanel()
	end)
end
