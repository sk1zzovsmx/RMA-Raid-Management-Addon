-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: local feature = addon.Database.GetFeatureShared()
-- exports: addon.Services.Master.SessionWinners
-- events: none
-- notes: pure Master session winner display models
local addon = select(2, ...)
local feature = addon.Database.GetFeatureShared()

local Master = feature.EnsureServiceNamespace("Master")

local SessionWinners = Master.SessionWinners or {}
Master.SessionWinners = SessionWinners

local L = feature.L

local tconcat = table.concat
local type = type

-- ----- Internal state ----- --

-- ----- Private helpers ----- --

-- ----- Public methods ----- --

function SessionWinners.BuildModel(model)
	local resolution = model and model.resolution or {}
	local autoWinners = resolution.autoWinners or {}
	local tiedNames = resolution.tiedNames or {}
	local rows = {}
	local autoNames = {}
	local tieNames = {}
	local included = {}

	for i = 1, #autoWinners do
		local winner = autoWinners[i]
		if winner and winner.name and winner.name ~= "" then
			rows[#rows + 1] = {
				name = winner.name,
				roll = winner.roll,
				state = "auto",
			}
			autoNames[#autoNames + 1] = winner.name
			included[winner.name] = true
		end
	end

	for i = 1, #tiedNames do
		local name = tiedNames[i]
		if name and name ~= "" and not included[name] then
			rows[#rows + 1] = {
				name = name,
				state = "tied",
			}
			tieNames[#tieNames + 1] = name
			included[name] = true
		end
	end

	local parts = {}
	if #autoNames > 0 then
		parts[#parts + 1] = L.StrMasterSessionWinnerSummary:format(tconcat(autoNames, ", "))
	end
	if #tieNames > 0 then
		parts[#parts + 1] = L.StrMasterSessionTieSummary:format(tconcat(tieNames, ", "))
	end

	return {
		rows = rows,
		summaryText = tconcat(parts, "; "),
	}
end

local registry = feature.ModuleRegistry
if type(registry) == "table" and type(registry.AddModule) == "function" and type(registry.SetLoaded) == "function" then
	registry.AddModule("Services/Master/SessionWinners", {
		deps = {
			"Init",
			"Modules/ModuleRegistry",
		},
	})
	registry.SetLoaded("Services/Master/SessionWinners")
end
