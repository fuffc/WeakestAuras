-- WeakestAuras -- the load system: decides whether a display is *active at all*
-- (registered with its trigger systems, allowed to show) based on data.load --
-- class(es)/race/faction/level/zone/combat/group-size-or-type/stance/alive/
-- mounted/on-taxi/name/realm/guild/spell-known/item-equipped. Mirrors WA2's
-- load system (§11), trimmed to the subset with a real 1.12+ClassicAPI/SuperWoW
-- data source: encounter, warmode, spec role and talent introspection have no
-- API on this client.
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- One deliberate divergence, matching Conditions.lua's: upstream compiles
-- data.load to a loadFunc via ConstructFunction; we *interpret* a small fixed
-- prototype instead. The load args are few and simple (a handful of AND'd
-- constraints), so an interpreter is clearer and lower-risk than assembling Lua
-- source with no offline linter.
--
-- The transition machinery lives in StateMachine.lua (WA.SetDisplayLoaded), which
-- owns the trigger systems and regions; this file only *evaluates* load state
-- (WA.EvalLoad) and drives a re-scan on load-relevant events (WA.ScanForLoads).

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local function numCmp(op, a, b)
	if a == nil or b == nil then return false end
	if op == "==" then return a == b
	elseif op == "~=" then return a ~= b
	elseif op == ">" then return a > b
	elseif op == ">=" then return a >= b
	elseif op == "<" then return a < b
	elseif op == "<=" then return a <= b end
	return false
end

-- Members in the current group (raid count, else party members + self). Drives
-- the "group size" load constraint.
local function groupSize()
	local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
	if raid and raid > 0 then return raid end
	local party = GetNumPartyMembers and GetNumPartyMembers() or 0
	return party + 1
end

-- "solo"/"group"/"raid" -- mirrors WA2's Private.ExecEnv.GroupType(), which
-- uses IsInRaid()/IsInGroup() (not on this client); GetNumRaidMembers/
-- GetNumPartyMembers already distinguish the same three states.
local function groupType()
	local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
	if raid and raid > 0 then return "raid" end
	local party = GetNumPartyMembers and GetNumPartyMembers() or 0
	if party and party > 0 then return "group" end
	return "solo"
end

-- Case-insensitive substring match, shared by the zone/player/realm/guild
-- text constraints (all "does this contain what I typed" checks).
local function substrMatch(hay, needle)
	if not needle or needle == "" then return true end
	return string.find(string.lower(hay or ""), string.lower(needle), 1, true) ~= nil
end

WA.CLASS_TOKENS = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
WA.CLASS_LABELS = {
	WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue",
	PRIEST = "Priest", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
-- Class-colored labels: WoW's `|cAARRGGBB...|r` escape codes render in any
-- plain FontString (dropdown option, checkbox label, ...), so no widget-level
-- change is needed to color-code the class picker -- just embed the codes in
-- the label text. RAID_CLASS_COLORS is a stock FrameXML global; falls back to
-- a plain label on the off chance it's missing.
WA.CLASS_COLOR_LABELS = {}
for ti = 1, table.getn(WA.CLASS_TOKENS) do
	local token = WA.CLASS_TOKENS[ti]
	local label = WA.CLASS_LABELS[token] or token
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
	if c then
		local hex = string.format("ff%02x%02x%02x",
			math.floor((c.r or 1) * 255 + 0.5), math.floor((c.g or 1) * 255 + 0.5), math.floor((c.b or 1) * 255 + 0.5))
		WA.CLASS_COLOR_LABELS[token] = "|c" .. hex .. label .. "|r"
	else
		WA.CLASS_COLOR_LABELS[token] = label
	end
end
local COMBAT_VALUES = { "incombat", "outofcombat" }
local COMBAT_LABELS = { incombat = "In Combat", outofcombat = "Out of Combat" }
local ALIVE_VALUES = { "alive", "dead" }
local ALIVE_LABELS = { alive = "Alive", dead = "Dead or Ghost" }
local MOUNTED_VALUES = { "mounted", "notmounted" }
local MOUNTED_LABELS = { mounted = "Mounted", notmounted = "Not Mounted" }
local TAXI_VALUES = { "ontaxi", "nottaxi" }
local TAXI_LABELS = { ontaxi = "On Taxi", nottaxi = "Not On Taxi" }
-- Mirrors WA2's Private.group_types (solo / party / raid) -- see groupType().
local INGROUP_VALUES = { "solo", "group", "raid" }
local INGROUP_LABELS = { solo = "Not in Group", group = "In Party", raid = "In Raid" }
-- UnitRaceBase's locale-independent tokens (ClassicAPI). "Scourge" is the
-- internal token for Undead, relabeled for the picker.
local RACE_TOKENS = { "Human", "Orc", "Dwarf", "NightElf", "Scourge", "Tauren", "Gnome", "Troll" }
local RACE_LABELS = {
	Human = "Human", Orc = "Orc", Dwarf = "Dwarf", NightElf = "Night Elf",
	Scourge = "Undead", Tauren = "Tauren", Gnome = "Gnome", Troll = "Troll",
}
local FACTION_VALUES = { "Horde", "Alliance" }
local FACTION_LABELS = { Horde = "Horde", Alliance = "Alliance" }

-- The load prototype: one descriptor per optional constraint (§11's
-- load_prototype args). Each has a `use_<name>` gate in data.load; when set, its
-- eval(L) must pass. OptionsFrame.lua's Load tab builds its editor from this same
-- list, so adding a constraint is one entry here (the args economy of §4.1/§11).
-- `optional = true` marks a constraint the *current moment* decides rather than
-- the character (combat, zone, group, stance, alive, mounted, taxi). Skipping
-- exactly those is what separates "this aura isn't for this character" from
-- "this aura is mine but the moment doesn't qualify" -- see WA.EvalLoadStatic.
-- `never` is handled outside this list (a plain gate-less kill switch). `class`
-- is the one entry the options renderer special-cases: its gate isn't a plain
-- on/off toggle but a 3-way "off"/"single"/"multi" mode select (`use_class`
-- holds the string, not a boolean) -- see OptionsFrame.lua's appendLoadOptions.
WA.loadPrototype = {
	{
		name = "combat", display = "Combat", widget = "select", optional = true,
		values = COMBAT_VALUES, labels = COMBAT_LABELS, default = "incombat",
		eval = function(L)
			local inCombat = UnitAffectingCombat("player") and true or false
			if L.combat == "outofcombat" then return not inCombat end
			return inCombat
		end,
	},
	{
		-- Two tiers, matching WA2's multiselect single/multi toggle: `use_class`
		-- is "single" (L.class, one token) or "multi" (L.classes, a token set),
		-- not a plain on/off boolean -- see OptionsFrame.lua's appendLoadOptions.
		-- isActive is required here: WA.EvalLoad's default gate treats *any*
		-- truthy L.use_class as "constraint on", but a stray non-"single"/"multi"
		-- value (a leftover "off" from an older save, say) is truthy in Lua and
		-- would permanently fail eval() below, silently hard-blocking the aura
		-- while the Load tab's own dropdown still displays "Ignored".
		name = "class", display = "Class", widget = "classtier",
		isActive = function(L) return L.use_class == "single" or L.use_class == "multi" end,
		eval = function(L)
			local _, cls = UnitClass("player")
			if L.use_class == "single" then
				return cls == L.class
			elseif L.use_class == "multi" then
				return L.classes ~= nil and L.classes[cls] and true or false
			end
			return false
		end,
	},
	{
		name = "race", display = "Race", widget = "select",
		values = RACE_TOKENS, labels = RACE_LABELS, default = "Human",
		eval = function(L)
			local token = UnitRaceBase and UnitRaceBase("player")
			return token == L.race
		end,
	},
	{
		name = "faction", display = "Faction", widget = "select",
		values = FACTION_VALUES, labels = FACTION_LABELS, default = "Alliance",
		eval = function(L)
			local faction = UnitFactionGroup("player")
			return faction == L.faction
		end,
	},
	{
		name = "level", display = "Level", widget = "opnumber", operator = ">=", default = 1,
		eval = function(L)
			return numCmp(L.level_operator or ">=", UnitLevel("player"), L.level or 1)
		end,
	},
	{
		name = "zone", display = "Zone (substring)", widget = "input", default = "", optional = true,
		eval = function(L) return substrMatch(GetRealZoneText(), L.zone) end,
	},
	{
		name = "size", display = "Group Size", widget = "opnumber", operator = ">=", default = 0, optional = true,
		eval = function(L)
			return numCmp(L.size_operator or ">=", groupSize(), L.size or 0)
		end,
	},
	{
		name = "ingroup", display = "Group Type", widget = "select", optional = true,
		values = INGROUP_VALUES, labels = INGROUP_LABELS, default = "solo",
		eval = function(L) return groupType() == (L.ingroup or "solo") end,
	},
	{
		name = "stance", display = "Stance/Form (0 = none)", widget = "range", optional = true,
		min = 0, max = 10, step = 1, default = 0,
		eval = function(L)
			local form = GetShapeshiftForm and GetShapeshiftForm() or 0
			return (form or 0) == (L.stance or 0)
		end,
	},
	{
		name = "alive", display = "Alive", widget = "select", optional = true,
		values = ALIVE_VALUES, labels = ALIVE_LABELS, default = "alive",
		eval = function(L)
			local dead = UnitIsDeadOrGhost("player") and true or false
			if L.alive == "dead" then return dead end
			return not dead
		end,
	},
	{
		name = "mounted", display = "Mounted", widget = "select", optional = true,
		values = MOUNTED_VALUES, labels = MOUNTED_LABELS, default = "mounted",
		eval = function(L)
			local m = IsMounted and IsMounted() and true or false
			if L.mounted == "notmounted" then return not m end
			return m
		end,
	},
	{
		name = "vehicle", display = "On Taxi", widget = "select", optional = true,
		values = TAXI_VALUES, labels = TAXI_LABELS, default = "ontaxi",
		eval = function(L)
			local t = UnitOnTaxi and UnitOnTaxi("player") and true or false
			if L.vehicle == "nottaxi" then return not t end
			return t
		end,
	},
	{
		name = "player", display = "Character Name (substring)", widget = "input", default = "",
		eval = function(L) return substrMatch(UnitName("player"), L.player) end,
	},
	{
		name = "realm", display = "Realm (substring)", widget = "input", default = "",
		eval = function(L) return substrMatch(GetRealmName(), L.realm) end,
	},
	{
		name = "guild", display = "Guild (substring)", widget = "input", default = "",
		eval = function(L) return substrMatch(GetGuildInfo("player"), L.guild) end,
	},
	{
		name = "spellknown", display = "Spell Known", widget = "spell", default = "",
		eval = function(L)
			local id = WA.ResolveSpellID(L.spellknown)
			return id ~= nil and IsSpellKnown(id) and true or false
		end,
	},
	{
		name = "not_spellknown", display = "Spell NOT Known", widget = "spell", default = "",
		eval = function(L)
			local id = WA.ResolveSpellID(L.not_spellknown)
			return id == nil or not IsSpellKnown(id)
		end,
	},
	{
		name = "itemequiped", display = "Item Equipped (item ID)", widget = "input", default = "",
		eval = function(L)
			local id = tonumber(L.itemequiped)
			if not id then return false end
			for slot = 1, 19 do
				if GetInventoryItemID("player", slot) == id then return true end
			end
			return false
		end,
	},
	{
		name = "not_itemequiped", display = "Item NOT Equipped (item ID)", widget = "input", default = "",
		eval = function(L)
			local id = tonumber(L.not_itemequiped)
			if not id then return true end
			for slot = 1, 19 do
				if GetInventoryItemID("player", slot) == id then return false end
			end
			return true
		end,
	},
}

-- All enabled constraints AND together (§11); `never` short-circuits to
-- unloaded. skipOptional drops the moment-dependent entries, leaving only what
-- the character decides. An empty data.load loads unconditionally, preserving
-- the "loaded = added" default every earlier phase assumed.
local function evalLoad(data, skipOptional)
	local L = data.load or {}
	if L.never then return false end
	for i = 1, table.getn(WA.loadPrototype) do
		local arg = WA.loadPrototype[i]
		if not (skipOptional and arg.optional) then
			-- Most entries gate on a plain boolean use_<name>; a few (class's
			-- "off"/"single"/"multi" tier) need their own isActive since a stray
			-- truthy-but-not-a-real-mode value would otherwise read as "enabled".
			-- isActive must be branched on, not `and`/`or`-ed with the default
			-- gate: `isActive(L) or default` can't express a false isActive, and
			-- would fall back to the very gate isActive exists to override.
			local active
			if arg.isActive then
				active = arg.isActive(L) and true or false
			else
				active = L["use_" .. arg.name] and true or false
			end
			if active and not arg.eval(L) then
				return false
			end
		end
	end
	return true
end

-- Overrides Data.lua's stub: the load state the engine acts on.
function WA.EvalLoad(data)
	return evalLoad(data, false)
end

-- The same check with the transient constraints skipped: true for a display
-- that belongs to this character even when the moment doesn't qualify. Drives
-- the Standby label only -- what loads is WA.EvalLoad alone (§11).
function WA.EvalLoadStatic(data)
	return evalLoad(data, true)
end

-- Re-evaluates every leaf display's load state and applies any transitions (ref
-- §11 ScanForLoads). No loadEvents->candidate-ids map: at tens of auras a full
-- re-scan on a load-relevant event is cheap, same "unconditional, cheap at this
-- scale" choice Conditions.lua's global-event handler makes. SetDisplayLoaded is
-- itself a no-op on displays whose state didn't change.
function WA.ScanForLoads()
	if not WA.SetDisplayLoaded then return end
	for id, data in pairs(WeakestAurasDB.displays) do
		if not WA.IsGroup(data) then
			WA.safecall(id, WA.SetDisplayLoaded, data, WA.EvalLoad(data))
		end
	end
end

-- Load-relevant events: any of these can flip a load constraint, so re-scan on
-- all of them. PLAYER_ENTERING_WORLD is the initial settle (zone/level/group are
-- only reliable once the world is loaded -- AddAllDisplays runs before that).
-- Guarded RegisterEvent for names that vary by build (the shapeshift events),
-- same defense GenericTrigger's ensureEventRegistered uses.
local LOAD_EVENTS = {
	"PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
	"PLAYER_LEVEL_UP", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
	"RAID_ROSTER_UPDATE", "PARTY_MEMBERS_CHANGED", "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS",
	"PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "UNIT_FLAGS",
	"PLAYER_GUILD_UPDATE", "SPELLS_CHANGED", "PLAYER_EQUIPMENT_CHANGED",
}

local loadFrame = CreateFrame("Frame")
for i = 1, table.getn(LOAD_EVENTS) do
	pcall(loadFrame.RegisterEvent, loadFrame, LOAD_EVENTS[i])
end
-- UNIT_AURA fires for every visible unit's aura changes (very chatty in a
-- raid), but only the player's own auras (the mount buff) matter to any load
-- constraint here -- filtered separately so it doesn't force a full re-scan
-- of every display on every other unit's buff tick.
loadFrame:RegisterEvent("UNIT_AURA")
loadFrame:SetScript("OnEvent", function()
	if event == "UNIT_AURA" and arg1 ~= "player" then return end
	WA.ScanForLoads()
end)
