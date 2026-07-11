-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
local addon = select(2, ...)
local Strings = addon.Strings
local Database = addon.Database
local Services = addon.Services

local type, tonumber = type, tonumber

-- ----- Internal state ----- --
addon.Database.EnsureServiceNamespace("Logger", "Store")
local Logger = Services.Logger
local Store = Logger.Store
local bossIdx
local lootIdx
local playerIdx
local resolvePlayerNameByNid
local resolvePlayerClassByNid
local resolveLootLooterNid
local resolveLootLooterName
local resolveLootLooterClass
local invalidateIndexes

-- ----- Private helpers ----- --
-- ----- Public methods ----- --

resolvePlayerNameByNid = function(raid, playerNid)
	local player = Store:GetPlayer(raid, playerNid)
	return player and player.name or nil
end

resolvePlayerClassByNid = function(raid, playerNid)
	local player = Store:GetPlayer(raid, playerNid)
	return player and player.class or nil
end

resolveLootLooterNid = function(raid, looter)
	local looterNid = tonumber(looter)
	if looterNid and looterNid > 0 then
		return looterNid
	end
	local normalizedName = Strings.NormalizeName(looter, true)
	if not normalizedName or normalizedName == "" then
		return nil
	end

	if raid and raid.players then
		for i = #raid.players, 1, -1 do
			local player = raid.players[i]
			if player and player.name == normalizedName then
				local nid = tonumber(player.playerNid)
				if nid and nid > 0 then
					return nid
				end
			end
		end
	end
	return nil
end

resolveLootLooterName = function(raid, loot)
	local queries = Database.GetRaidQueries()
	return queries:ResolveLootLooterName(raid, loot)
end

resolveLootLooterClass = function(raid, loot)
	if type(loot) ~= "table" then
		return nil
	end
	local looterNid = tonumber(loot.looterNid)
	if looterNid and looterNid > 0 then
		return resolvePlayerClassByNid(raid, looterNid)
	end
	return nil
end

function Store:GetRaid(rID)
	return rID and Database.GetRaidStore():EnsureRaidByIndex(rID) or nil
end

function Store:EnsureRaidByNid(raidNid)
	return raidNid and Database.GetRaidStore():EnsureRaidByNid(raidNid) or nil
end

invalidateIndexes = function(raid)
	if type(raid) ~= "table" then
		return
	end
	Database.StripRuntimeRaidCaches(raid)
end

Store._ResolvePlayerNameByNid = resolvePlayerNameByNid
Store._ResolvePlayerClassByNid = resolvePlayerClassByNid
Store._ResolveLootLooterNid = resolveLootLooterNid
Store._ResolveLootLooterName = resolveLootLooterName
Store._ResolveLootLooterClass = resolveLootLooterClass
Store._InvalidateIndexes = invalidateIndexes

bossIdx = function(raid, bossNid)
	local queryNid = tonumber(bossNid)
	if not (raid and queryNid) then
		return nil
	end
	local runtime = Database.GetRaidStore():EnsureRaidRuntime(raid)
	local idxByNid = runtime and runtime.bossIdxByNid or nil
	return idxByNid and idxByNid[queryNid] or nil
end

lootIdx = function(raid, lootNid)
	local queryNid = tonumber(lootNid)
	if not (raid and queryNid) then
		return nil
	end
	local runtime = Database.GetRaidStore():EnsureRaidRuntime(raid)
	local idxByNid = runtime and runtime.lootIdxByNid or nil
	return idxByNid and idxByNid[queryNid] or nil
end

function Store:GetBoss(raid, bossNid)
	local idx = bossIdx(raid, bossNid)
	return idx and raid.bossKills[idx] or nil, idx
end

function Store:GetLoot(raid, lootNid)
	local idx = lootIdx(raid, lootNid)
	return idx and raid.loot[idx] or nil, idx
end

playerIdx = function(raid, playerNid)
	local queryNid = tonumber(playerNid)
	if not (raid and queryNid) then
		return nil
	end
	local runtime = Database.GetRaidStore():EnsureRaidRuntime(raid)
	local idxByNid = runtime and runtime.playerIdxByNid or nil
	return idxByNid and idxByNid[queryNid] or nil
end

function Store:GetPlayer(raid, playerNid)
	local idx = playerIdx(raid, playerNid)
	return idx and raid.players[idx] or nil, idx
end
