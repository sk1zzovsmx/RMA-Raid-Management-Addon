-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Database.Syncer._Metrics
-- events: none

local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local DB = feature.DB
-- ----- Internal state ----- --

DB.Syncer = DB.Syncer or {}
local module = DB.Syncer
module._Metrics = module._Metrics or {}
local Metrics = module._Metrics

local tsort = table.sort
local pairs, type = pairs, type
local tonumber, tostring = tonumber, tostring

-- ----- Private helpers ----- --

local function isSyncMetricsEnabled()
	return addon.hasPerf == true
end

local function addMetric(row, key, amount)
	row[key] = (tonumber(row[key]) or 0) + (tonumber(amount) or 0)
end

local function ensureMetricRow(row)
	row.outgoingMessages = tonumber(row.outgoingMessages) or 0
	row.outgoingBytes = tonumber(row.outgoingBytes) or 0
	row.outgoingChunks = tonumber(row.outgoingChunks) or 0
	row.outgoingRequests = tonumber(row.outgoingRequests) or 0
	row.outgoingSnapshots = tonumber(row.outgoingSnapshots) or 0
	row.incomingMessages = tonumber(row.incomingMessages) or 0
	row.incomingBytes = tonumber(row.incomingBytes) or 0
	row.incomingChunks = tonumber(row.incomingChunks) or 0
	row.incomingRequests = tonumber(row.incomingRequests) or 0
	row.incomingSnapshots = tonumber(row.incomingSnapshots) or 0
	return row
end

local function ensureSyncMetrics()
	if type(module._syncMetrics) ~= "table" then
		module._syncMetrics = {}
	end
	local metrics = ensureMetricRow(module._syncMetrics)
	if type(metrics.byMode) ~= "table" then
		metrics.byMode = {}
	end
	return metrics
end

local function ensureModeMetrics(metrics, mode)
	local key = tostring(mode or "")
	if key == "" then
		key = "?"
	end
	local byMode = metrics.byMode
	local row = byMode[key]
	if type(row) ~= "table" then
		row = { mode = key }
		byMode[key] = row
	end
	row.mode = key
	return ensureMetricRow(row)
end

local function copyMetricFields(src, dst)
	dst.outgoingMessages = tonumber(src and src.outgoingMessages) or 0
	dst.outgoingBytes = tonumber(src and src.outgoingBytes) or 0
	dst.outgoingChunks = tonumber(src and src.outgoingChunks) or 0
	dst.outgoingRequests = tonumber(src and src.outgoingRequests) or 0
	dst.outgoingSnapshots = tonumber(src and src.outgoingSnapshots) or 0
	dst.incomingMessages = tonumber(src and src.incomingMessages) or 0
	dst.incomingBytes = tonumber(src and src.incomingBytes) or 0
	dst.incomingChunks = tonumber(src and src.incomingChunks) or 0
	dst.incomingRequests = tonumber(src and src.incomingRequests) or 0
	dst.incomingSnapshots = tonumber(src and src.incomingSnapshots) or 0
	return dst
end

-- ----- Public methods ----- --

function Metrics.RecordOutgoingRequest(mode, bytes)
	if not isSyncMetricsEnabled() then
		return
	end
	local metrics = ensureSyncMetrics()
	local modeMetrics = ensureModeMetrics(metrics, mode)

	addMetric(metrics, "outgoingMessages", 1)
	addMetric(metrics, "outgoingBytes", bytes)
	addMetric(metrics, "outgoingRequests", 1)
	addMetric(modeMetrics, "outgoingMessages", 1)
	addMetric(modeMetrics, "outgoingBytes", bytes)
	addMetric(modeMetrics, "outgoingRequests", 1)
end

function Metrics.RecordOutgoingSnapshot(mode, bytes, chunks)
	if not isSyncMetricsEnabled() then
		return
	end
	local metrics = ensureSyncMetrics()
	local modeMetrics = ensureModeMetrics(metrics, mode)
	local chunkCount = tonumber(chunks) or 0

	addMetric(metrics, "outgoingMessages", chunkCount)
	addMetric(metrics, "outgoingBytes", bytes)
	addMetric(metrics, "outgoingChunks", chunkCount)
	addMetric(metrics, "outgoingSnapshots", 1)
	addMetric(modeMetrics, "outgoingMessages", chunkCount)
	addMetric(modeMetrics, "outgoingBytes", bytes)
	addMetric(modeMetrics, "outgoingChunks", chunkCount)
	addMetric(modeMetrics, "outgoingSnapshots", 1)
end

function Metrics.RecordIncomingRequest(mode, bytes)
	if not isSyncMetricsEnabled() then
		return
	end
	local metrics = ensureSyncMetrics()
	local modeMetrics = ensureModeMetrics(metrics, mode)

	addMetric(metrics, "incomingMessages", 1)
	addMetric(metrics, "incomingBytes", bytes)
	addMetric(metrics, "incomingRequests", 1)
	addMetric(modeMetrics, "incomingMessages", 1)
	addMetric(modeMetrics, "incomingBytes", bytes)
	addMetric(modeMetrics, "incomingRequests", 1)
end

function Metrics.RecordIncomingSnapshotChunk(mode, bytes)
	if not isSyncMetricsEnabled() then
		return
	end
	local metrics = ensureSyncMetrics()
	local modeMetrics = ensureModeMetrics(metrics, mode)

	addMetric(metrics, "incomingMessages", 1)
	addMetric(metrics, "incomingBytes", bytes)
	addMetric(metrics, "incomingChunks", 1)
	addMetric(modeMetrics, "incomingMessages", 1)
	addMetric(modeMetrics, "incomingBytes", bytes)
	addMetric(modeMetrics, "incomingChunks", 1)
end

function Metrics.RecordIncomingSnapshotComplete(mode)
	if not isSyncMetricsEnabled() then
		return
	end
	local metrics = ensureSyncMetrics()
	local modeMetrics = ensureModeMetrics(metrics, mode)

	addMetric(metrics, "incomingSnapshots", 1)
	addMetric(modeMetrics, "incomingSnapshots", 1)
end

function Metrics.Get()
	local metrics = ensureSyncMetrics()
	local out = copyMetricFields(metrics, { modes = {} })
	local byMode = metrics.byMode or {}

	for _, row in pairs(byMode) do
		local copy = copyMetricFields(row, { mode = tostring(row and row.mode or "?") })
		out.modes[#out.modes + 1] = copy
	end

	tsort(out.modes, function(a, b)
		return tostring(a and a.mode or "") < tostring(b and b.mode or "")
	end)
	return out
end

function Metrics.Reset()
	module._syncMetrics = nil
	return true
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Database/DBSyncMetrics", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
			"Database/DB",
		},
	})
	registry.SetLoaded("Database/DBSyncMetrics")
end
