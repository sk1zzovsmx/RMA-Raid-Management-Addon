local addon = select(2, ...)
local Database = addon.Database
local Services = addon.Services
local Strings = addon.Strings
local Bus = addon.Bus
local InternalEvents = addon.Events.Internal
local type = type
local strlen = string.len

local Raid = assert(Services.Raid, "Raid service namespace is not initialized")
Raid.LootBans = Raid.LootBans or {}
local LootBans = Raid.LootBans
local NOTE_MAX_LENGTH = 240

local function getPlayerRecord(playerName, create)
	local realm = Database.GetRealmName()
	local name = Strings.NormalizeName(playerName, true)
	local players = Database.SavedVariables.GetPlayers()
	if not realm or realm == "" or not name or name == "" then
		return nil, name
	end
	if create then
		players[realm] = players[realm] or {}
		players[realm][name] = players[realm][name] or {}
	end
	return players[realm] and players[realm][name] or nil, name
end

function LootBans.ValidateNote(note)
	local clean = Strings.TrimText(note, true)
	if clean == "" then
		return nil
	end
	if strlen(clean) > NOTE_MAX_LENGTH then
		return nil, "note_too_long"
	end
	return clean
end

function LootBans.Get(playerName)
	local player = getPlayerRecord(playerName, false)
	local ban = player and player.lootBan
	if type(ban) ~= "table" or ban.active ~= true then
		return false, nil
	end
	local note = type(ban.note) == "string" and ban.note or nil
	return true, note
end

function LootBans.IsActive(playerName)
	return LootBans.Get(playerName) == true
end

function LootBans.Set(playerName, note)
	local cleanNote, err = LootBans.ValidateNote(note)
	if err then
		return nil, err
	end
	local player, name = getPlayerRecord(playerName, true)
	if not player then
		return nil, "invalid_player"
	end
	player.lootBan = { active = true, note = cleanNote }
	Bus.TriggerEvent(InternalEvents.LootBansChanged, name, true, cleanNote)
	return true
end

function LootBans.Remove(playerName)
	local player, name = getPlayerRecord(playerName, false)
	if not player or player.lootBan == nil then
		return false
	end
	player.lootBan = nil
	Bus.TriggerEvent(InternalEvents.LootBansChanged, name, false, nil)
	return true
end

return LootBans
