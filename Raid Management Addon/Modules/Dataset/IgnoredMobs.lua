-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
-- notes: raid-only encounter helpers/adds from LibBossIDs that should not own loot context

local addon = select(2, ...)
local tonumber = tonumber
local tostring = tostring
local type = type
local strlower = string.lower
local gsub = string.gsub

local IgnoredMobs = addon.IgnoredMobs or {}
addon.IgnoredMobs = IgnoredMobs
local L = addon.L

-- ----- Internal state ----- --
local DEFAULT_TRASH_MOB_NAME = "_TrashMob_"
local cachedTrashMobName
local activeInstanceKey
local generation = 0

local rawByInstance = {
	["blackwing lair"] = {
		12557, -- Grethok the Controller (Razorgore event)
		10162, -- Lord Victor Nefarius (Nefarian pre-event)
	},
	["temple of ahn'qiraj"] = {
		15589, -- Eye of C'Thun
	},
	naxxramas = {
		16803, -- Death Knight Understudy
		15930, -- Feugen
		15929, -- Stalagg
		30549, -- Baron Rivendare (Four Horsemen member)
		16065, -- Lady Blaumeux
		16064, -- Thane Korth'azz
		16062, -- Highlord Mograine
		16063, -- Sir Zeliek
	},
	karazhan = {
		16151, -- Midnight
		17229, -- Kil'rek
		17535, -- Dorothee
		17546, -- Roar
		17543, -- Strawman
		17547, -- Tinhead
		17548, -- Tito
	},
	["gruul's lair"] = {
		18835, -- Kiggler the Crazed
		18836, -- Blindeye the Seer
		18834, -- Olm the Summoner
		18832, -- Krosh Firehand
	},
	["serpentshrine cavern"] = {
		21875, -- Shadow of Leotheras
	},
	["the eye"] = {
		20064, -- Thaladred the Darkener
		20060, -- Lord Sanguinar
		20062, -- Grand Astromancer Capernian
		20063, -- Master Engineer Telonicus
		21270, -- Cosmic Infuser
		21269, -- Devastation
		21271, -- Infinity Blades
		21268, -- Netherstrand Longbow
		21273, -- Phaseshift Bulwark
		21274, -- Staff of Disintegration
		21272, -- Warp Slicer
	},
	["black temple"] = {
		22949, -- Gathios the Shatterer
		22950, -- High Nethermancer Zerevor
		22951, -- Lady Malande
		22952, -- Veras Darkshadow
	},
	["the obsidian sanctum"] = {
		30451, -- Shadron
		30452, -- Tenebron
		30449, -- Vesperon
	},
	ulduar = {
		33670, -- Aerial Command Unit
		33329, -- Heart of the Deconstructor
		33651, -- VX-001
		32867, -- Steelbreaker
		32927, -- Runemaster Molgeim
		32857, -- Stormcaller Brundir
		34035, -- Feral Defender
		32933, -- Left Arm
		32934, -- Right Arm
		33524, -- Saronite Animus
		33890, -- Brain of Yogg-Saron
		33136, -- Guardian of Yogg-Saron
		32915, -- Elder Brightleaf
		32913, -- Elder Ironbranch
		32914, -- Elder Stonebark
		34014, -- Sanctum Sentry
		33432, -- Leviathan Mk II
	},
	["trial of the crusader"] = {
		34461, -- Tyrius Duskblade
		34460, -- Kavina Grovesong
		34469, -- Melador Valestrider
		34467, -- Alyssia Moonstalker
		34468, -- Noozle Whizzlestick
		34465, -- Velanaa
		34471, -- Baelnor Lightbearer
		34466, -- Anthar Forgemender
		34473, -- Brienna Nightfell
		34472, -- Irieth Shadowstep
		34470, -- Saamul
		34463, -- Shaabad
		34474, -- Serissa Grimdabbler
		34475, -- Shocuul
		34458, -- Gorgrim Shadowcleave
		34451, -- Birana Stormhoof
		34459, -- Erin Misthoof
		34448, -- Ruj'kah
		34449, -- Ginselle Blightslinger
		34445, -- Liandra Suncaller
		34456, -- Malithas Brightblade
		34447, -- Caiphus the Stern
		34441, -- Vivienne Blackwhisper
		34454, -- Maz'dinah
		34444, -- Thrakgar
		34455, -- Broln Stouthorn
		34450, -- Harkzog
		34453, -- Narrhok Steelbreaker
		35610, -- Cat
		35465, -- Zhaagrym
		34497, -- Fjola Lightbane
		34496, -- Eydis Darkbane
	},
	["icecrown citadel"] = {
		37972, -- Prince Keleseth
		37970, -- Prince Valanar
		37973, -- Prince Taldaram
		37950, -- Valithria Dreamwalker (Phased)
		37868, -- Risen Archmage
		36791, -- Blazing Skeleton
		37934, -- Blistering Zombie
		37886, -- Gluttonous Abomination
		37985, -- Dream Cloud
	},
	["the ruby sanctum"] = {
		39899, -- Baltharus the Warborn (clone)
	},
}

-- ----- Private helpers ----- --
local function resolveTrashMobName()
	local localizedName = L and L.StrTrashMobName
	if type(localizedName) ~= "string" or localizedName == "" then
		return DEFAULT_TRASH_MOB_NAME
	end
	if localizedName == "StrTrashMobName" or localizedName == "L.StrTrashMobName" then
		return DEFAULT_TRASH_MOB_NAME
	end
	return localizedName
end

local function normalizeText(value)
	if value == nil then
		return nil
	end
	local text = gsub(tostring(value), "^%s*(.-)%s*$", "%1")
	if text == "" then
		return nil
	end
	return strlower(text)
end

IgnoredMobs.Ids = nil

-- ----- Public methods ----- --
function IgnoredMobs.GetTrashMobName()
	if cachedTrashMobName == nil then
		cachedTrashMobName = resolveTrashMobName()
	end

	return cachedTrashMobName
end

function IgnoredMobs.IsTrashMobName(name)
	return name == IgnoredMobs.GetTrashMobName()
end

function IgnoredMobs.Contains(npcId)
	local ids = IgnoredMobs.Ids
	return type(ids) == "table" and ids[tonumber(npcId)] == true
end

function IgnoredMobs.DeactivateInstance()
	if activeInstanceKey == nil then
		return false
	end

	IgnoredMobs.Ids = nil
	activeInstanceKey = nil
	generation = generation + 1
	return true
end

function IgnoredMobs.ActivateInstance(instanceName)
	local instanceKey = normalizeText(instanceName)
	if instanceKey ~= nil and instanceKey == activeInstanceKey then
		return true
	end

	local wasActive = activeInstanceKey ~= nil
	IgnoredMobs.DeactivateInstance()
	local rawIds = instanceKey and rawByInstance[instanceKey] or nil
	if rawIds == nil then
		return false, "unsupported-instance"
	end

	local ids = {}
	IgnoredMobs.Ids = ids
	for i = 1, #rawIds do
		ids[rawIds[i]] = true
	end
	activeInstanceKey = instanceKey
	if not wasActive then
		generation = generation + 1
	end
	return true
end

function IgnoredMobs.GetActiveInstanceKey()
	return activeInstanceKey
end

function IgnoredMobs.GetGeneration()
	return generation
end

function IgnoredMobs._SetRawForTests(raw)
	IgnoredMobs.DeactivateInstance()
	rawByInstance = raw or {}
end
