-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local Database = addon.Database
local Services = addon.Services

local twipe = table.wipe
local tostring, tonumber = tostring, tonumber
local date = date
local floor = math.floor

-- ----- Internal state ----- --
addon.Services.EnsureNamespace("Logger", "View")
local Logger = Services.Logger
local View = Logger.View
local isBossFightRecord = Database.IsBossFightRecord

-- ----- Private helpers ----- --
local function getOutputCount(out)
	if type(out) ~= "table" then
		return 0
	end
	return #out
end

local function getRaidPerfId(raid)
	return tostring((raid and raid.raidNid) or "?")
end

local function finishPerf(label, startedAt, raid, out, extraDetails)
	if not (startedAt and addon._PerfFinish) then
		return
	end

	local details = "raid=" .. getRaidPerfId(raid) .. " rows=" .. tostring(getOutputCount(out))
	if extraDetails and extraDetails ~= "" then
		details = details .. " " .. tostring(extraDetails)
	end
	addon:_PerfFinish(label, startedAt, details)
end

-- ----- Public methods ----- --

function View:GetBossModeLabel(bossData)
	if not bossData then
		return "?"
	end
	local mode = bossData.mode
	if not mode and bossData.difficulty then
		mode = (bossData.difficulty == 3 or bossData.difficulty == 4) and "h" or "n"
	end
	return (mode == "h") and "H" or "N"
end

function View:FillBossList(out, raid)
	local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
	local queries = Database.GetRaidQueries()
	local result = queries:GetBossKills(raid, out)
	finishPerf("Logger.View.FillBossList", perfStart, raid, out)
	return result
end

function View:FillBossAttendeesList(out, raid, bossNid)
	local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
	local queries = Database.GetRaidQueries()
	local result = queries:GetBossAttendance(raid, bossNid, out)
	finishPerf("Logger.View.FillBossAttendeesList", perfStart, raid, out, "boss=" .. tostring(bossNid or "?"))
	return result
end

function View:FillPlayerBossParticipationList(out, raid, playerNid)
	local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
	if not out then
		finishPerf(
			"Logger.View.FillPlayerBossParticipationList",
			perfStart,
			raid,
			out,
			"player=" .. tostring(playerNid or "?")
		)
		return
	end
	twipe(out)
	local selectedPlayerNid = tonumber(playerNid)
	if not (raid and selectedPlayerNid) then
		finishPerf(
			"Logger.View.FillPlayerBossParticipationList",
			perfStart,
			raid,
			out,
			"player=" .. tostring(playerNid or "?")
		)
		return
	end

	local bosses = raid.bossKills or {}
	local n = 0
	for i = 1, #bosses do
		local boss = bosses[i]
		local players = boss and boss.players
		if isBossFightRecord(boss) and type(players) == "table" then
			for j = 1, #players do
				if tonumber(players[j]) == selectedPlayerNid then
					n = n + 1
					local it = {}
					local killTime = tonumber(boss.time) or 0
					it.id = tonumber(boss.bossNid)
					it.seq = i
					it.name = boss.name or ""
					it.time = killTime
					it.timeFmt = (killTime > 0) and date("%H:%M", killTime) or ""
					it.mode = self:GetBossModeLabel(boss)
					out[n] = it
					break
				end
			end
		end
	end
	finishPerf(
		"Logger.View.FillPlayerBossParticipationList",
		perfStart,
		raid,
		out,
		"player=" .. tostring(playerNid or "?")
	)
end

function View:FillLootList(out, raid, bossNid, playerName)
	local perfStart = addon.hasPerf and addon._PerfStart and addon:_PerfStart() or nil
	local queries = Database.GetRaidQueries()
	local result = queries:GetLoot(raid, bossNid, playerName, out)
	finishPerf(
		"Logger.View.FillLootList",
		perfStart,
		raid,
		out,
		"boss=" .. tostring(bossNid or "?") .. " player=" .. tostring(playerName or "")
	)
	return result
end
