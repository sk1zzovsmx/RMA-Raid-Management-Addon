-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: defines addon.Database.GetFeatureShared()
-- exports: publish module APIs on addon.*
-- events: seeds Internal/Wow event names; marks Init bootstrap load

local addon = select(2, ...)
local addonName = select(1, ...)

if not addon then
	error("RMA addon table not found in Init.lua")
end

-- ----- Internal state ----- --
addon.name = addon.name or addonName
addon.Database = addon.Database or {}
addon.L = addon.L or {}
addon.Diagnose = addon.Diagnose or {}
addon.State = addon.State or {}
addon.C = addon.C or {}
addon.Events = addon.Events or {}
addon.Events.Internal = addon.Events.Internal or {}
addon.Events.Wow = addon.Events.Wow or {}
addon.DB = addon.DB or {}
addon.Features = addon.Features or {}
addon.Controllers = addon.Controllers or {}
addon.Services = addon.Services or {}
addon.Services.Logger = addon.Services.Logger or {}
addon.Widgets = addon.Widgets or {}
addon.Bus = addon.Bus or {}
addon.UI = addon.UI or {}
addon.UI.Frames = addon.UI.Frames or {}
addon.Time = addon.Time or {}

local _G = _G
local pairs, select, type = pairs, select, type
local setmetatable = setmetatable
local tostring, tonumber = tostring, tonumber
local tsort = table.sort
local GetTime = assert(_G.GetTime, "RMA time API is not initialized")
local GetRealmName = assert(_G.GetRealmName, "RMA realm name API is not initialized")
local UnitIsGroupLeader = _G.UnitIsGroupLeader
local UnitIsGroupAssistant = _G.UnitIsGroupAssistant
local IsInRaid = _G.IsInRaid
local IsRaidLeader = _G.IsRaidLeader
local IsRaidOfficer = _G.IsRaidOfficer
local IsPartyLeader = _G.IsPartyLeader
local GetPartyLeaderIndex = assert(_G.GetPartyLeaderIndex, "RMA party leader index API is not initialized")
local GetRaidRosterInfo = assert(_G.GetRaidRosterInfo, "RMA raid roster API is not initialized")
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, "RMA raid member count API is not initialized")
local GetNumPartyMembers = assert(_G.GetNumPartyMembers, "RMA party member count API is not initialized")

local Database = addon.Database
local Diagnose = addon.Diagnose
local DEFAULT_PERF_THRESHOLD_MS = 5
local featureShared
local FEATURE_CONSTANT_KEYS = {
	ITEM_LINK_PATTERN = true,
	rollTypes = true,
	lootTypesColored = true,
	itemColors = true,
	RAID_TARGET_MARKERS = true,
	K_COLOR = true,
	RT_COLOR = true,
}
local FEATURE_RUNTIME_KEYS = {
	coreState = true,
	raidState = true,
	lootState = true,
	itemInfo = true,
}

local function markBootstrapModuleLoaded()
	-- Bootstrap exception: ModuleRegistry may not be loaded yet.
	local registry = addon.ModuleRegistry
	if registry and type(registry.SetLoaded) == "function" then
		registry.SetLoaded("Init")
		return
	end

	addon.ModuleRegistryPendingLoads = addon.ModuleRegistryPendingLoads or {}
	local pending = addon.ModuleRegistryPendingLoads
	pending[#pending + 1] = "Init"
end

markBootstrapModuleLoaded()

local Diag = setmetatable({}, {
	__index = Diagnose,
	__newindex = function(_, key, value)
		Diagnose[key] = value
	end,
})

-- ----- Private helpers ----- --
local function seedBootstrapEvents()
	addon.Events = addon.Events or {}
	addon.Events.Internal = addon.Events.Internal or {}
	addon.Events.Wow = addon.Events.Wow or {}

	local Internal = addon.Events.Internal
	local Wow = addon.Events.Wow

	Internal.RaidRosterDelta = Internal.RaidRosterDelta or "RaidRosterDelta"
	Internal.LootDistributionSessionChanged = Internal.LootDistributionSessionChanged
		or "LootDistributionSessionChanged"

	-- Canonical forwarded WoW-event names are PascalCase.
	Wow.LootOpened = Wow.LootOpened or "wow.LOOT_OPENED"
	Wow.LootClosed = Wow.LootClosed or "wow.LOOT_CLOSED"
	Wow.LootSlotCleared = Wow.LootSlotCleared or "wow.LOOT_SLOT_CLEARED"
	Wow.OpenMasterLootList = Wow.OpenMasterLootList or "wow.OPEN_MASTER_LOOT_LIST"
	Wow.UpdateMasterLootList = Wow.UpdateMasterLootList or "wow.UPDATE_MASTER_LOOT_LIST"
	Wow.ReadyCheck = Wow.ReadyCheck or "wow.READY_CHECK"
	Wow.InspectTalentReady = Wow.InspectTalentReady or "wow.INSPECT_TALENT_READY"
	Wow.PlayerRegenEnabled = Wow.PlayerRegenEnabled or "wow.PLAYER_REGEN_ENABLED"
	Wow.PlayerTargetChanged = Wow.PlayerTargetChanged or "wow.PLAYER_TARGET_CHANGED"
	Wow.UiErrorMessage = Wow.UiErrorMessage or "wow.UI_ERROR_MESSAGE"
	Wow.UiInfoMessage = Wow.UiInfoMessage or "wow.UI_INFO_MESSAGE"
	Wow.ChatMsgWhisper = Wow.ChatMsgWhisper or "wow.CHAT_MSG_WHISPER"
	Wow.TradeAcceptUpdate = Wow.TradeAcceptUpdate or "wow.TRADE_ACCEPT_UPDATE"
	Wow.TradeShow = Wow.TradeShow or "wow.TRADE_SHOW"
	Wow.TradeRequestCancel = Wow.TradeRequestCancel or "wow.TRADE_REQUEST_CANCEL"
	Wow.TradeClosed = Wow.TradeClosed or "wow.TRADE_CLOSED"
	Wow.TradePlayerItemChanged = Wow.TradePlayerItemChanged or "wow.TRADE_PLAYER_ITEM_CHANGED"
	Wow.TradeTargetItemChanged = Wow.TradeTargetItemChanged or "wow.TRADE_TARGET_ITEM_CHANGED"

	return addon.Events
end

local function isDebugEnabled()
	local state = addon.State
	return state and state.debugEnabled == true
end

local function isTraceEnabled()
	return addon.hasTrace ~= nil
end

local function getPerfThresholdMs()
	local threshold = tonumber(addon.State and addon.State.perfThresholdMs) or DEFAULT_PERF_THRESHOLD_MS
	if threshold < 0 then
		threshold = DEFAULT_PERF_THRESHOLD_MS
	end
	return threshold
end

local function ensurePerfStats()
	addon.State.perfStats = addon.State.perfStats or {}
	return addon.State.perfStats
end

local function clearArray(out)
	for i = 1, #out do
		out[i] = nil
	end
end

local function recordPerfStat(label, elapsedMs)
	local key = tostring(label or "?")
	local stats = ensurePerfStats()
	local row = stats[key]
	if not row then
		row = {
			label = key,
			count = 0,
			totalMs = 0,
			maxMs = 0,
		}
		stats[key] = row
	end

	row.count = row.count + 1
	row.totalMs = row.totalMs + elapsedMs
	if elapsedMs > row.maxMs then
		row.maxMs = elapsedMs
	end
	row.avgMs = row.totalMs / row.count
	return row
end

local function sortPerfSnapshot(a, b)
	if a.totalMs ~= b.totalMs then
		return a.totalMs > b.totalMs
	end
	if a.maxMs ~= b.maxMs then
		return a.maxMs > b.maxMs
	end
	return tostring(a.label or "") < tostring(b.label or "")
end

-- ----- Public methods ----- --
function Database.EnsureBootstrapEvents()
	return seedBootstrapEvents()
end

Database.EnsureBootstrapEvents()

addon._PerfStart = function(self)
	if not self.hasPerf then
		return nil
	end
	return GetTime()
end

addon._PerfFinish = function(self, label, startedAt, details)
	if not (self.hasPerf and startedAt) then
		return nil
	end

	local elapsedMs = (GetTime() - startedAt) * 1000
	recordPerfStat(label, elapsedMs)
	if elapsedMs < getPerfThresholdMs() then
		return elapsedMs
	end

	local suffix = ""
	if details and details ~= "" then
		suffix = " " .. tostring(details)
	end
	local template = (Diag.I and Diag.I.LogPerfBlock) or "[Perf] %s %.1fms%s"
	if self.info then
		self:info(template:format(tostring(label or "?"), elapsedMs, suffix))
	end
	return elapsedMs
end

addon._PerfGetStats = function(self, out)
	out = out or {}
	clearArray(out)

	local state = self and self.State or addon.State
	local stats = state and state.perfStats or nil
	if not stats then
		return out
	end

	local n = 0
	for _, row in pairs(stats) do
		n = n + 1
		local count = tonumber(row.count) or 0
		local totalMs = tonumber(row.totalMs) or 0
		out[n] = {
			label = tostring(row.label or "?"),
			count = count,
			totalMs = totalMs,
			maxMs = tonumber(row.maxMs) or 0,
			avgMs = count > 0 and (totalMs / count) or 0,
		}
	end

	tsort(out, sortPerfSnapshot)
	return out
end

addon._PerfResetStats = function(self)
	local state = self and self.State or addon.State
	if state then
		state.perfStats = {}
	end
	return true
end

local function getController(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local controllers = addon.Controllers
	return controllers and controllers[name] or nil
end

function Database.RequestControllerMethod(name, methodName, ...)
	if type(methodName) ~= "string" or methodName == "" then
		return nil
	end
	local controller = getController(name)
	local method = controller and controller[methodName]
	if type(method) ~= "function" then
		return nil
	end
	return method(controller, ...)
end

local function ensureNamespace(root, ...)
	assert(type(root) == "table", "ensureNamespace requires a root table")

	local target = root
	for i = 1, select("#", ...) do
		local key = select(i, ...)
		assert(type(key) == "string" and key ~= "", "ensureNamespace requires non-empty string keys")

		local child = target[key]
		if type(child) ~= "table" then
			child = {}
			target[key] = child
		end
		target = child
	end

	return target
end

function Database.EnsureServiceNamespace(...)
	return ensureNamespace(addon.Services, ...)
end

function Database.GetPlayerName()
	local state = addon.State
	state.player = state.player or {}
	local name = state.player.name or addon.UnitFullName("player")
	state.player.name = name
	return name
end

function Database.GetRealmName()
	local realm = GetRealmName()
	if type(realm) ~= "string" then
		return ""
	end
	return realm
end

local function getUnitIndex(unit)
	if type(unit) ~= "string" then
		return nil
	end
	return tonumber(unit:match("%d+"))
end

local function isInRaid()
	if type(IsInRaid) == "function" then
		return IsInRaid() and true or false
	end
	return (tonumber(GetNumRaidMembers()) or 0) > 0
end

local function isInGroup()
	return isInRaid() or (tonumber(GetNumPartyMembers()) or 0) > 0
end

local function isGroupLeader(unit)
	if type(UnitIsGroupLeader) == "function" then
		return UnitIsGroupLeader(unit) and true or false
	end
	if not isInGroup() then
		return false
	end
	if unit == "player" then
		if isInRaid() then
			return type(IsRaidLeader) == "function" and IsRaidLeader() and true or false
		end
		return type(IsPartyLeader) == "function" and IsPartyLeader() and true or false
	end
	local index = getUnitIndex(unit)
	if not index then
		return false
	end
	if isInRaid() then
		return select(2, GetRaidRosterInfo(index)) == 2
	end
	return GetPartyLeaderIndex() == index
end

local function isGroupAssistant(unit)
	if type(UnitIsGroupAssistant) == "function" then
		return UnitIsGroupAssistant(unit) and true or false
	end
	if not isInRaid() then
		return false
	end
	if unit == "player" then
		return type(IsRaidOfficer) == "function" and IsRaidOfficer() and true or false
	end
	local index = getUnitIndex(unit)
	if not index then
		return false
	end
	return select(2, GetRaidRosterInfo(index)) == 1
end

function Database.GetUnitRank(unit, fallback)
	if isGroupLeader(unit) then
		return 2
	end
	if isGroupAssistant(unit) then
		return 1
	end
	return fallback or 0
end

-- Options/SavedVariables management lives in Database/DBOptions.lua.
-- IsDebugEnabled / ApplyDebugSetting are exposed on addon.Options there.
-- Namespace registrations are owned by the modules that use them.

local function getFeatureRuntimeValue(key)
	local core = addon.Database
	local state = addon.State
	state.raid = state.raid or {}
	if key == "coreState" then
		return state
	end
	if key == "raidState" then
		return state.raid
	end
	if type(core.EnsureLootRuntimeState) ~= "function" then
		state.loot = state.loot or {}
		state.loot.itemInfo = state.loot.itemInfo or {}
		if key == "lootState" then
			return state.loot
		end
		if key == "itemInfo" then
			return state.loot.itemInfo
		end
		return nil
	end
	local _, lootState, itemInfo, raidState = core.EnsureLootRuntimeState()
	if key == "coreState" then
		return state
	end
	if key == "raidState" then
		return raidState
	end
	if key == "lootState" then
		return lootState
	end
	if key == "itemInfo" then
		return itemInfo
	end
	return nil
end

local function getFeatureSharedValue(key)
	if key == "Diag" then
		return Diag
	end
	if key == "Database" then
		return addon.Database
	end
	if key == "EnsureServiceNamespace" then
		return addon.Database.EnsureServiceNamespace
	end
	if FEATURE_RUNTIME_KEYS[key] then
		return getFeatureRuntimeValue(key)
	end
	if FEATURE_CONSTANT_KEYS[key] then
		return (addon.C or {})[key]
	end
	return addon[key]
end

function Database.GetFeatureShared()
	if not featureShared then
		featureShared = setmetatable({}, {
			__index = function(_, key)
				return getFeatureSharedValue(key)
			end,
			__newindex = function(t, key, value)
				if FEATURE_RUNTIME_KEYS[key] then
					return
				end
				rawset(t, key, value)
			end,
		})
	end
	return featureShared
end

do
	-- ----- RMA Lua Contract ----- --
	-- deps: local addon = select(2, ...)
	-- shared: local feature = addon.Database.GetFeatureShared()
	-- exports: publish module APIs on addon.*
	-- events: owns main WoW event dispatcher; forwards events to Bus and Services

	local addon = select(2, ...)
	local feature = addon.Database.GetFeatureShared()

	local addonName = addon.name

	local L = feature.L
	local Diag = feature.Diag

	local Bus = feature.Bus
	local UI = feature.UI
	local Frames = UI and UI.Frames
	local Time = feature.Time
	local Events = feature.Events
	local C = feature.C

	local InternalEvents = assert(Events.Internal, "RMA internal events are not initialized")
	local WowEvents = Events.Wow

	local _G = _G
	local tremove = table.remove
	local pairs, select, type = pairs, select, type
	local error, pcall = error, pcall
	local tostring, tonumber = tostring, tonumber

	_G["RMA"] = addon

	-- =========== External Libraries / Bootstrap  =========== --
	local Compat = LibStub("LibCompat-1.0")
	addon.Compat = Compat
	addon.BossIDs = LibStub("LibBossIDs-1.0")
	addon.Debugger = LibStub("LibLogger-1.0")
	addon.Deformat = LibStub("LibDeformat-3.0")

	Compat:Embed(addon) -- mixin: After, UnitIterator, GetCreatureId, etc.
	addon.Debugger:Embed(addon)
	addon.IsInRaid = isInRaid
	addon.IsInGroup = isInGroup

	-- Remove global timer APIs injected by LibCompat:Embed. Modules must use
	-- the addon.Timer mixin (Timer.BindMixin + self:ScheduleTimer/...).
	-- Timer loads later than this bootstrap block, and addon embedding happens
	-- in ADDON_LOADED before event handlers are registered.
	addon.After = nil
	addon.NewTimer = nil
	addon.NewTicker = nil
	addon.CancelTimer = nil

	-- =========== LibCompat  =========== --

	-- Keep LibCompat chat output behavior, but without prepending tostring(addon) ("table: ...").
	function addon:Print(...)
		return Compat.Print(Compat, ...)
	end

	do
		local lv = addon.Debugger.logLevels.INFO
		if addon.State and addon.State.debugEnabled then
			lv = addon.Debugger.logLevels.DEBUG
		end
		addon:SetLogLevel(lv)
	end

	-- =========== Database Addon Frames & Locals  =========== --

	-- Centralized addon state
	local coreState = addon.State
	coreState.frames = coreState.frames or {}
	local frames = coreState.frames
	frames.main = frames.main or CreateFrame("Frame")

	-- Addon UI frame used by event dispatcher
	local mainFrame = frames.main

	local Database = addon.Database

	-- =========== Event System (WoW API events)  =========== --
	-- Clean frame-based dispatcher (NO CallbackHandler here)
	do
		-- listeners[event] = { obj1, obj2, ... }
		local listeners = {}

		local function handleEvent(_, eventName, ...)
			local list = listeners[eventName]
			if not list then
				return
			end

			for i = 1, #list do
				local obj = list[i]
				local fn = obj and obj[eventName]
				if type(fn) == "function" then
					local ok, err = pcall(fn, obj, ...)
					if not ok then
						addon:error(Diag.E.LogDatabaseEventHandlerFailed:format(tostring(eventName), tostring(err)))
					end
				end
			end
		end

		local function addListener(obj, eventName)
			if type(eventName) ~= "string" or eventName == "" then
				error('Usage: RegisterEvent("EVENT_NAME")', 3)
			end

			local list = listeners[eventName]
			if not list then
				list = {}
				listeners[eventName] = list
				mainFrame:RegisterEvent(eventName)
			else
				for i = 1, #list do
					if list[i] == obj then
						return
					end -- already registered
				end
			end

			list[#list + 1] = obj
		end

		local function removeListener(obj, eventName)
			local list = listeners[eventName]
			if not list then
				return
			end

			for i = #list, 1, -1 do
				if list[i] == obj then
					tremove(list, i)
				end
			end

			if #list == 0 then
				listeners[eventName] = nil
				mainFrame:UnregisterEvent(eventName)
			end
		end

		function addon:RegisterEvent(eventName)
			addListener(self, eventName)
		end

		function addon:UnregisterEvent(eventName)
			removeListener(self, eventName)
		end

		mainFrame:SetScript("OnEvent", handleEvent)

		-- bootstrap
		addon:RegisterEvent("ADDON_LOADED")
	end

	function Database.RequireServiceMethod(serviceName, serviceTable, methodName)
		assert(type(serviceTable) == "table", "RMA missing service: " .. tostring(serviceName))
		local method = serviceTable[methodName]
		assert(
			type(method) == "function",
			"RMA missing service method: " .. tostring(serviceName) .. "." .. tostring(methodName)
		)
		return method
	end

	local function getService(serviceName)
		local services = addon.Services
		if type(services) ~= "table" then
			return nil
		end
		return services[serviceName]
	end

	local function ensureDBManager()
		local db = addon.DB
		if not (db and type(db.SetManager) == "function" and type(db.GetManager) == "function") then
			return nil
		end

		local manager = db.GetManager()
		if manager then
			return manager
		end

		local dbManager = addon.DBManager
		local defaultManager = dbManager and dbManager.GetDefaultManager and dbManager.GetDefaultManager() or nil
		if defaultManager then
			db.SetManager(defaultManager)
			return defaultManager
		end

		return nil
	end

	ensureDBManager()

	-- =========== Main Event Handlers  =========== --
	local addonEvents = {
		CHAT_MSG_SYSTEM = "CHAT_MSG_SYSTEM",
		CHAT_MSG_LOOT = "CHAT_MSG_LOOT",
		CHAT_MSG_WHISPER = "CHAT_MSG_WHISPER",
		START_LOOT_ROLL = "START_LOOT_ROLL",
		CHAT_MSG_ADDON = "CHAT_MSG_ADDON",
		CHAT_MSG_MONSTER_YELL = "CHAT_MSG_MONSTER_YELL",
		RAID_ROSTER_UPDATE = "RAID_ROSTER_UPDATE",
		PLAYER_ENTERING_WORLD = "PLAYER_ENTERING_WORLD",
		COMBAT_LOG_EVENT_UNFILTERED = "COMBAT_LOG_EVENT_UNFILTERED",
		RAID_INSTANCE_WELCOME = "RAID_INSTANCE_WELCOME",
		PLAYER_DIFFICULTY_CHANGED = "PLAYER_DIFFICULTY_CHANGED",
		UPDATE_INSTANCE_INFO = "UPDATE_INSTANCE_INFO",
		LOOT_CLOSED = "LOOT_CLOSED",
		LOOT_OPENED = "LOOT_OPENED",
		LOOT_SLOT_CLEARED = "LOOT_SLOT_CLEARED",
		OPEN_MASTER_LOOT_LIST = "OPEN_MASTER_LOOT_LIST",
		UPDATE_MASTER_LOOT_LIST = "UPDATE_MASTER_LOOT_LIST",
		PLAYER_TARGET_CHANGED = "PLAYER_TARGET_CHANGED",
		UI_ERROR_MESSAGE = "UI_ERROR_MESSAGE",
		UI_INFO_MESSAGE = "UI_INFO_MESSAGE",
		TRADE_SHOW = "TRADE_SHOW",
		TRADE_ACCEPT_UPDATE = "TRADE_ACCEPT_UPDATE",
		TRADE_PLAYER_ITEM_CHANGED = "TRADE_PLAYER_ITEM_CHANGED",
		TRADE_REQUEST_CANCEL = "TRADE_REQUEST_CANCEL",
		TRADE_CLOSED = "TRADE_CLOSED",
		TRADE_TARGET_ITEM_CHANGED = "TRADE_TARGET_ITEM_CHANGED",
		READY_CHECK = "READY_CHECK",
		INSPECT_TALENT_READY = "INSPECT_TALENT_READY",
		PLAYER_REGEN_ENABLED = "PLAYER_REGEN_ENABLED",
		PLAYER_LOGOUT = "PLAYER_LOGOUT",
	}
	local ADDON_EVENTS_COUNT = 0
	for _ in pairs(addonEvents) do
		ADDON_EVENTS_COUNT = ADDON_EVENTS_COUNT + 1
	end

	do
		local wowBusEvents = {
			LOOT_OPENED = WowEvents.LootOpened,
			LOOT_CLOSED = WowEvents.LootClosed,
			LOOT_SLOT_CLEARED = WowEvents.LootSlotCleared,
			OPEN_MASTER_LOOT_LIST = WowEvents.OpenMasterLootList,
			UPDATE_MASTER_LOOT_LIST = WowEvents.UpdateMasterLootList,
			PLAYER_TARGET_CHANGED = WowEvents.PlayerTargetChanged,
			UI_ERROR_MESSAGE = WowEvents.UiErrorMessage,
			UI_INFO_MESSAGE = WowEvents.UiInfoMessage,
			CHAT_MSG_WHISPER = WowEvents.ChatMsgWhisper,
			TRADE_SHOW = WowEvents.TradeShow,
			TRADE_ACCEPT_UPDATE = WowEvents.TradeAcceptUpdate,
			TRADE_PLAYER_ITEM_CHANGED = WowEvents.TradePlayerItemChanged,
			TRADE_REQUEST_CANCEL = WowEvents.TradeRequestCancel,
			TRADE_CLOSED = WowEvents.TradeClosed,
			TRADE_TARGET_ITEM_CHANGED = WowEvents.TradeTargetItemChanged,
			READY_CHECK = WowEvents.ReadyCheck,
			INSPECT_TALENT_READY = WowEvents.InspectTalentReady,
			PLAYER_REGEN_ENABLED = WowEvents.PlayerRegenEnabled,
		}

		for eventName, busEventName in pairs(wowBusEvents) do
			local eventKey = busEventName
			addon[eventName] = function(_, ...)
				Bus.TriggerEvent(eventKey, ...)
			end
		end
	end

	-- ADDON_LOADED: Initializes the addon after loading.
	function addon:ADDON_LOADED(name)
		if name ~= addonName then
			return
		end
		self:UnregisterEvent("ADDON_LOADED")
		ensureDBManager()
		local SavedVariables = Database.SavedVariables
		SavedVariables.EnsureAll()
		local lvl = addon.GetLogLevel and addon:GetLogLevel()
		addon:info(
			Diag.I.LogDatabaseLoaded:format(
				tostring(GetAddOnMetadata(addonName, "Version")),
				tostring(lvl),
				tostring(true)
			)
		)
		if addon.Options and addon.Options.EnsureLoaded then
			addon.Options.EnsureLoaded()
			addon.Options.SetDebugEnabled(false)
		end
		-- Bind the Timer mixin after its module has loaded so Init-owned timers use the canonical API.
		if addon.Timer and addon.Timer.BindMixin then
			addon.Timer.BindMixin(addon, "Database")
		end
		local minimap = addon.Minimap
		if minimap and minimap.EnsureUI then
			minimap:EnsureUI()
		end
		local reservesService = getService("Reserves")
		if reservesService and reservesService.Load then
			reservesService:Load()
		end
		if addon.Comms and addon.Comms.EnsureVersionPrefix then
			addon.Comms:EnsureVersionPrefix()
		end
		SavedVariables.NormalizeAfterLoad()
		for event in pairs(addonEvents) do
			self:RegisterEvent(event)
		end
		if isDebugEnabled() then
			addon:debug(Diag.D.LogDatabaseEventsRegistered:format(ADDON_EVENTS_COUNT))
		end
		self:RAID_ROSTER_UPDATE(true)
	end

	local rosterUpdateDebounceSeconds = 0.2

	local function scheduleRaidInstanceChecksIfRecognized(instanceName, instanceType, instanceDiff, emitRecognizedLog)
		local raidService = getService("Raid")
		if instanceType ~= "raid" or L.RaidZones[instanceName] == nil then
			return false
		end
		if not raidService then
			return false
		end
		if emitRecognizedLog then
			if isDebugEnabled() then
				addon:debug(Diag.D.LogRaidInstanceRecognized:format(tostring(instanceName), tostring(instanceDiff)))
			end
		end
		raidService:ScheduleInstanceChecks()
		return true
	end

	local function processRaidRosterUpdate()
		local raidService = getService("Raid")
		if not raidService then
			return
		end

		local changed, delta = raidService:UpdateRaidRoster()
		if not changed then
			return
		end

		-- Single source of truth for roster change notifications (join/update/leave delta).
		Bus.TriggerEvent(
			InternalEvents.RaidRosterDelta,
			delta,
			raidService:GetRosterVersion(),
			Database.GetCurrentRaid()
		)
	end

	-- RAID_ROSTER_UPDATE: Updates the raid roster when it changes.
	function addon:RAID_ROSTER_UPDATE(forceImmediate)
		if self._raidRosterUpdateHandle then
			self:CancelTimer(self._raidRosterUpdateHandle)
			self._raidRosterUpdateHandle = nil
		end

		if forceImmediate then
			processRaidRosterUpdate()
			return
		end

		self._raidRosterUpdateHandle = self:ScheduleTimer(function()
			self._raidRosterUpdateHandle = nil
			processRaidRosterUpdate()
		end, rosterUpdateDebounceSeconds)
	end

	-- RAID_INSTANCE_WELCOME: Triggered when entering a raid instance.
	function addon:RAID_INSTANCE_WELCOME(...)
		local instanceName, instanceType, instanceDiff = GetInstanceInfo()
		local _, nextReset = ...
		local resolvedNextReset = Database.SetNextReset(nextReset)
		if isTraceEnabled() then
			addon:trace(
				Diag.D.LogRaidInstanceWelcome:format(
					tostring(instanceName),
					tostring(instanceType),
					tostring(instanceDiff),
					tostring(resolvedNextReset)
				)
			)
		end
		if instanceType == "raid" and not L.RaidZones[instanceName] then
			addon:warn(Diag.W.LogRaidUnmappedZone:format(tostring(instanceName), tostring(instanceDiff)))
		end
		if instanceType == "raid" then
			RequestRaidInfo()
		end
		scheduleRaidInstanceChecksIfRecognized(instanceName, instanceType, instanceDiff, true)
	end

	local function handleRaidInstanceInfoChanged()
		local instanceName, instanceType, instanceDiff = GetInstanceInfo()
		scheduleRaidInstanceChecksIfRecognized(instanceName, instanceType, instanceDiff, false)
	end

	-- PLAYER_DIFFICULTY_CHANGED: Re-check raid session when raid difficulty changes.
	function addon:PLAYER_DIFFICULTY_CHANGED()
		handleRaidInstanceInfoChanged()
	end

	-- UPDATE_INSTANCE_INFO: Re-check raid session after server pushes instance-save info refreshes.
	function addon:UPDATE_INSTANCE_INFO()
		handleRaidInstanceInfoChanged()
	end

	-- PLAYER_ENTERING_WORLD: Performs initial checks when the player logs in.
	function addon:PLAYER_ENTERING_WORLD()
		self:UnregisterEvent("PLAYER_ENTERING_WORLD")
		local module = getService("Raid")
		if not module then
			return
		end
		if isTraceEnabled() then
			addon:trace(Diag.D.LogDatabasePlayerEnteringWorld)
		end
		module:CancelInstanceChecks()
		-- Restart the first-check timer on login (timer owned by raid service module).
		if module.CheckInitialRaidStateHandle then
			module:CancelTimer(module.CheckInitialRaidStateHandle)
			module.CheckInitialRaidStateHandle = nil
		end
		module.CheckInitialRaidStateHandle = module:ScheduleTimer(function()
			module:CheckInitialRaidState()
		end, 3)
	end

	local function observePassiveLootMessage(msg, winnerOnly)
		local currentRaid = Database.GetCurrentRaid()
		local raidService = getService("Raid")
		local lootService = getService("Loot")
		if not currentRaid then
			return raidService, nil
		end

		if lootService and lootService.ObservePassiveLootMessage then
			local observedType, parsedLoot = lootService:ObservePassiveLootMessage(msg, winnerOnly)
			return raidService, observedType, parsedLoot
		end

		if lootService and lootService.AddGroupLootMessage then
			return raidService, lootService:AddGroupLootMessage(msg)
		end

		return raidService, nil
	end

	-- CHAT_MSG_LOOT: Adds looted items to the raid log.
	function addon:CHAT_MSG_LOOT(msg)
		local perfStart = addon.hasPerf and addon:_PerfStart() or nil
		if isTraceEnabled() then
			addon:trace(Diag.D.LogLootChatMsgLootRaw:format(tostring(msg)))
		end
		local currentRaid = Database.GetCurrentRaid()
		local raidService, observedType, parsedLoot = observePassiveLootMessage(msg)
		local lootService = getService("Loot")
		if not (currentRaid and raidService) then
			if perfStart then
				addon:_PerfFinish("CHAT_MSG_LOOT", perfStart, "raid=none")
			end
			return
		end

		local canObservePassiveLoot = raidService.CanObservePassiveLoot and raidService:CanObservePassiveLoot()
		if canObservePassiveLoot and (observedType == nil or observedType == "winner") then
			if lootService and lootService.AddLoot then
				lootService:AddLoot(msg, nil, nil, parsedLoot)
			end
		end
		if perfStart then
			addon:_PerfFinish(
				"CHAT_MSG_LOOT",
				perfStart,
				"raid=" .. tostring(currentRaid) .. " observed=" .. tostring(observedType)
			)
		end
	end

	-- CHAT_MSG_SYSTEM: Forwards roll messages to the Rolls module.
	function addon:CHAT_MSG_SYSTEM(msg)
		local perfStart = addon.hasPerf and addon:_PerfStart() or nil
		local currentRaid = Database.GetCurrentRaid()
		local raidService, observedType, parsedLoot = observePassiveLootMessage(msg)
		local lootService = getService("Loot")
		if currentRaid and raidService then
			local canObservePassiveLoot = raidService.CanObservePassiveLoot and raidService:CanObservePassiveLoot()
			if canObservePassiveLoot and observedType == "winner" then
				if lootService and lootService.AddLoot then
					lootService:AddLoot(msg, nil, nil, parsedLoot)
				end
			end
		end

		if
			Database.GetCurrentRaid()
			and raidService
			and raidService.CanUseCapability
			and not raidService:CanUseCapability("loot")
		then
			if perfStart then
				addon:_PerfFinish(
					"CHAT_MSG_SYSTEM",
					perfStart,
					"raid=" .. tostring(currentRaid) .. " observed=" .. tostring(observedType) .. " blocked=loot"
				)
			end
			return
		end
		local rollsService = getService("Rolls")
		if rollsService and rollsService.CHAT_MSG_SYSTEM then
			rollsService:CHAT_MSG_SYSTEM(msg)
		end
		if perfStart then
			addon:_PerfFinish(
				"CHAT_MSG_SYSTEM",
				perfStart,
				"raid=" .. tostring(currentRaid) .. " observed=" .. tostring(observedType)
			)
		end
	end

	function addon:START_LOOT_ROLL(rollId, rollTime)
		local perfStart = addon.hasPerf and addon:_PerfStart() or nil
		local currentRaid = Database.GetCurrentRaid()
		local lootService = getService("Loot")
		if currentRaid and lootService and lootService.AddPassiveLootRoll then
			lootService:AddPassiveLootRoll(rollId, rollTime)
		end
		if perfStart then
			addon:_PerfFinish(
				"START_LOOT_ROLL",
				perfStart,
				"raid=" .. tostring(currentRaid) .. " rollId=" .. tostring(rollId)
			)
		end
	end

	-- CHAT_MSG_ADDON: Forwards addon communication messages to service-specific handlers, then Syncer.
	function addon:CHAT_MSG_ADDON(prefix, msg, channel, sender)
		if
			addon.Comms
			and addon.Comms.HandleVersionMessage
			and addon.Comms:HandleVersionMessage(prefix, msg, channel, sender)
		then
			return
		end
		local reservesService = getService("Reserves")
		if
			reservesService
			and reservesService.HandleSyncMessage
			and reservesService:HandleSyncMessage(prefix, msg, channel, sender)
		then
			return
		end
		local lootService = getService("Loot")
		if
			lootService
			and lootService.HandleDistributionMessage
			and lootService:HandleDistributionMessage(prefix, msg, channel, sender)
		then
			return
		end
		local syncer = Database.GetSyncer()
		if syncer and syncer.OnAddonMessage then
			syncer:OnAddonMessage(prefix, msg, channel, sender)
		end
	end

	-- CHAT_MSG_MONSTER_YELL: Logs a boss kill based on specific boss yells.
	function addon:CHAT_MSG_MONSTER_YELL(...)
		local text = ...
		local raidService = getService("Raid")
		if raidService and L.BossYells[text] and Database.GetCurrentRaid() then
			if isTraceEnabled() then
				addon:trace(Diag.D.LogBossYellMatched:format(tostring(text), tostring(L.BossYells[text])))
			end
			raidService:AddBoss(L.BossYells[text])
		end
	end

	-- COMBAT_LOG_EVENT_UNFILTERED: Delegates boss-kill detection to the Raid service.
	function addon:COMBAT_LOG_EVENT_UNFILTERED(...)
		local raidService = getService("Raid")
		if raidService and raidService.COMBAT_LOG_EVENT_UNFILTERED then
			raidService:COMBAT_LOG_EVENT_UNFILTERED(...)
		end
	end

	-- PLAYER_LOGOUT: Prepare canonical SavedVariables payloads before persistence.
	function addon:PLAYER_LOGOUT()
		Database.SavedVariables.PrepareForSave("logout")
	end
end
