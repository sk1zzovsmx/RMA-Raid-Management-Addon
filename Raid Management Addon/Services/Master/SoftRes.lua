-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.SoftRes
-- events: none
-- notes: pure Master SoftRes summary models
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")

local SoftRes = Master.SoftRes or {}
Master.SoftRes = SoftRes

local L = feature.L

local type = type
local tonumber = tonumber

-- ----- Internal state ----- --

-- ----- Private helpers ----- --

-- ----- Public methods ----- --

function SoftRes.BuildSummaryText(opts, rollModel)
	opts = opts or {}
	local srSummaryText = rollModel and rollModel.srSummaryText
	if srSummaryText and srSummaryText ~= "" then
		return srSummaryText
	end

	local reserveContext = (rollModel and rollModel.srContext) or opts.reserveContext
	if type(reserveContext) ~= "table" then
		return nil
	end

	local eligible = tonumber(reserveContext.eligibleReserveCount or reserveContext.presentReserveCount) or 0
	local total = tonumber(reserveContext.totalReserveCount) or 0
	local missing = tonumber(reserveContext.missingReserveCount)
	if not missing then
		missing = total - eligible
	end
	if missing < 0 then
		missing = 0
	end

	if eligible > 0 and missing > 0 then
		return L.StrRollSrSummaryPresentMissing:format(eligible, missing)
	end
	if eligible > 0 then
		return L.StrRollSrSummaryPresent:format(eligible)
	end
	if total > 0 or reserveContext.hasReserves == true then
		return L.StrRollSrSummaryNoPresent
	end
	if rollModel and rollModel.isSR == true then
		return L.StrRollSrSummaryFallback
	end
	return nil
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/SoftRes", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
		},
	})
	registry.SetLoaded("Services/Master/SoftRes")
end
