-- ----- RMA Lua Contract ----- --
-- deps: local addon = select(2, ...)
-- shared: direct addon namespace bindings
-- exports: publish module APIs on addon.*
-- events: none
-- notes: raid-only encounter helpers/adds from LibBossIDs that should not own loot context

local addon = select(2, ...)
local tonumber = tonumber
local type = type

local IgnoredMobs = addon.IgnoredMobs or {}
addon.IgnoredMobs = IgnoredMobs
local L = addon.L

-- ----- Internal state ----- --
local DEFAULT_TRASH_MOB_NAME = "_TrashMob_"
local cachedTrashMobName

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

IgnoredMobs.Ids = {
	-- Classic raids
	[12557] = true, -- Grethok the Controller (Razorgore event)
	[10162] = true, -- Lord Victor Nefarius (Nefarian pre-event)
	[15589] = true, -- Eye of C'Thun
	[16803] = true, -- Death Knight Understudy
	[15930] = true, -- Feugen
	[15929] = true, -- Stalagg
	[30549] = true, -- Baron Rivendare (Four Horsemen member)
	[16065] = true, -- Lady Blaumeux
	[16064] = true, -- Thane Korth'azz
	[16062] = true, -- Highlord Mograine
	[16063] = true, -- Sir Zeliek

	-- The Burning Crusade raids
	[16151] = true, -- Midnight
	[17229] = true, -- Kil'rek
	[17535] = true, -- Dorothee
	[17546] = true, -- Roar
	[17543] = true, -- Strawman
	[17547] = true, -- Tinhead
	[17548] = true, -- Tito
	[18835] = true, -- Kiggler the Crazed
	[18836] = true, -- Blindeye the Seer
	[18834] = true, -- Olm the Summoner
	[18832] = true, -- Krosh Firehand
	[21875] = true, -- Shadow of Leotheras
	[20064] = true, -- Thaladred the Darkener
	[20060] = true, -- Lord Sanguinar
	[20062] = true, -- Grand Astromancer Capernian
	[20063] = true, -- Master Engineer Telonicus
	[21270] = true, -- Cosmic Infuser
	[21269] = true, -- Devastation
	[21271] = true, -- Infinity Blades
	[21268] = true, -- Netherstrand Longbow
	[21273] = true, -- Phaseshift Bulwark
	[21274] = true, -- Staff of Disintegration
	[21272] = true, -- Warp Slicer
	[22949] = true, -- Gathios the Shatterer
	[22950] = true, -- High Nethermancer Zerevor
	[22951] = true, -- Lady Malande
	[22952] = true, -- Veras Darkshadow

	-- Wrath of the Lich King raids
	[30451] = true, -- Shadron
	[30452] = true, -- Tenebron
	[30449] = true, -- Vesperon
	[33670] = true, -- Aerial Command Unit
	[33329] = true, -- Heart of the Deconstructor
	[33651] = true, -- VX-001
	[32867] = true, -- Steelbreaker
	[32927] = true, -- Runemaster Molgeim
	[32857] = true, -- Stormcaller Brundir
	[34035] = true, -- Feral Defender
	[32933] = true, -- Left Arm
	[32934] = true, -- Right Arm
	[33524] = true, -- Saronite Animus
	[33890] = true, -- Brain of Yogg-Saron
	[33136] = true, -- Guardian of Yogg-Saron
	[32915] = true, -- Elder Brightleaf
	[32913] = true, -- Elder Ironbranch
	[32914] = true, -- Elder Stonebark
	[34014] = true, -- Sanctum Sentry
	[33432] = true, -- Leviathan Mk II
	[34461] = true, -- Tyrius Duskblade
	[34460] = true, -- Kavina Grovesong
	[34469] = true, -- Melador Valestrider
	[34467] = true, -- Alyssia Moonstalker
	[34468] = true, -- Noozle Whizzlestick
	[34465] = true, -- Velanaa
	[34471] = true, -- Baelnor Lightbearer
	[34466] = true, -- Anthar Forgemender
	[34473] = true, -- Brienna Nightfell
	[34472] = true, -- Irieth Shadowstep
	[34470] = true, -- Saamul
	[34463] = true, -- Shaabad
	[34474] = true, -- Serissa Grimdabbler
	[34475] = true, -- Shocuul
	[34458] = true, -- Gorgrim Shadowcleave
	[34451] = true, -- Birana Stormhoof
	[34459] = true, -- Erin Misthoof
	[34448] = true, -- Ruj'kah
	[34449] = true, -- Ginselle Blightslinger
	[34445] = true, -- Liandra Suncaller
	[34456] = true, -- Malithas Brightblade
	[34447] = true, -- Caiphus the Stern
	[34441] = true, -- Vivienne Blackwhisper
	[34454] = true, -- Maz'dinah
	[34444] = true, -- Thrakgar
	[34455] = true, -- Broln Stouthorn
	[34450] = true, -- Harkzog
	[34453] = true, -- Narrhok Steelbreaker
	[35610] = true, -- Cat
	[35465] = true, -- Zhaagrym
	[34497] = true, -- Fjola Lightbane
	[34496] = true, -- Eydis Darkbane
	[37972] = true, -- Prince Keleseth
	[37970] = true, -- Prince Valanar
	[37973] = true, -- Prince Taldaram
	[37950] = true, -- Valithria Dreamwalker (Phased)
	[37868] = true, -- Risen Archmage
	[36791] = true, -- Blazing Skeleton
	[37934] = true, -- Blistering Zombie
	[37886] = true, -- Gluttonous Abomination
	[37985] = true, -- Dream Cloud
	[39899] = true, -- Baltharus the Warborn (clone)
}

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
	return IgnoredMobs.Ids[tonumber(npcId)] == true
end
