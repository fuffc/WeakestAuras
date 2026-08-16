-- WeakestAuras: a WeakAuras-style buff/debuff/cooldown display addon for the
-- 1.12 client. Built on the modern C_UnitAuras/C_Spell/C_Timer surface that
-- the ClassicAPI client patch backports.
--
-- Copyright (C) 2026 fuffc
--
-- This addon reimplements the architecture of WeakAuras (the WeakAuras team,
-- https://github.com/WeakAuras/WeakAuras2) for a client its own source cannot
-- run on, and parts of it -- the trigger-state glue above all -- follow that
-- source closely enough to be a derived work. It is therefore distributed
-- under the same terms: GNU General Public License version 2 or later, in
-- LICENSE. There is NO WARRANTY, to the extent permitted by law.

WeakestAuras = CreateFrame("Frame")

-- ClassicAPI publishes this global (packed X*10000+Y*100+Z) on every load/
-- reload. Its absence means the client patch isn't installed, and none of
-- the aura APIs this addon needs exist.
if not CLASSIC_API_VERSION then
  WeakestAuras.disabled = true
  DEFAULT_CHAT_FRAME:AddMessage(
    "|cffff0000WeakestAuras|r requires the ClassicAPI client patch, which was not detected. " ..
    "Get it from https://github.com/brues-code/ClassicAPI",
    1, 0.2, 0.2
  )
  return
end

WeakestAurasDB = WeakestAurasDB or {}

-- Capability probes, resolved once at load. ClassicAPI is the hard gate above;
-- SuperWoW and Nampower feed per-trigger version-skew guards (a prototype
-- declaring `enable = function() return WA.hasNampower end`) rather than a
-- second load gate, so a missing mod degrades feature-by-feature.
--
-- All three are meant to hard-disable. The blocker is SUPERWOW_VERSION /
-- SUPERWOW_STRING: DoiteAuras only ever gates on GetNampowerVersion and never
-- reads a SuperWoW global, so neither name is confirmed on a live client. Probe
-- them in-game before making either one brick the load.
WeakestAuras.hasClassicAPI = CLASSIC_API_VERSION ~= nil
WeakestAuras.hasSuperWoW = (SUPERWOW_VERSION ~= nil) or (SUPERWOW_STRING ~= nil)
WeakestAuras.hasNampower = type(GetNampowerVersion) == "function"

-- The .toc's `## Version`, resolved once. Nil rather than a fallback string when
-- the client cannot answer: everything version-facing reads this, and a
-- made-up number put on the addon channel would tell an up-to-date guild it is
-- behind. pfUI calls GetAddOnMetadata unguarded in its own load path
-- (../pfUI/pfUI.lua), so it is present here.
WeakestAuras.version = GetAddOnMetadata and GetAddOnMetadata("WeakestAuras", "Version") or nil

-- `x.y` or `x.y.z`, each part at most 999, packed into one comparable number.
-- Anything else is nil: a version string reaching this also arrives from
-- strangers over the addon channel, where "99.0.0" and "9.9.9.9" are both things
-- someone will send.
function WeakestAuras.ParseVersion(s)
	if type(s) ~= "string" then return nil end
	local _, _, major, minor, patch = string.find(s, "^(%d+)%.(%d+)%.(%d+)$")
	if not major then
		_, _, major, minor = string.find(s, "^(%d+)%.(%d+)$")
		patch = "0"
	end
	if not major then return nil end
	major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
	if major > 999 or minor > 999 or patch > 999 then return nil end
	return major * 1000000 + minor * 1000 + patch
end

-- True when `a` is a strictly newer release than `b`, nil when either side
-- cannot be parsed -- which is not the same answer as false, and callers that
-- act on a claim need to tell them apart.
function WeakestAuras.VersionNewer(a, b)
	local packedA, packedB = WeakestAuras.ParseVersion(a), WeakestAuras.ParseVersion(b)
	if not packedA or not packedB then return nil end
	return packedA > packedB
end

-- WeakAuras2's active-trigger sentinel (Private.trigger_modes.first_active):
-- an activeTriggerMode of this value means "the display follows whichever
-- trigger is the first one currently active" rather than a fixed trigger
-- number. Lives here so both Data.lua (schema default) and StateMachine.lua
-- (resolution) share the one constant.
WeakestAuras.trigger_modes = { first_active = -10 }

-- Unit tokens a single-state trigger may target. All are native or
-- ClassicAPI-backed. raid1..raid40 and partyN are reachable through the
-- "specific" entry's free-text field rather than bloating every dropdown.
WeakestAuras.unit_tokens = {
	"player", "target", "targettarget", "focus", "focustarget",
	"pet", "pettarget", "mouseover", "specific",
}
WeakestAuras.unit_labels = {
	player = "Player", target = "Target", targettarget = "Target of Target",
	focus = "Focus", focustarget = "Target of Focus",
	pet = "Pet", pettarget = "Target of Pet", mouseover = "Mouseover",
	specific = "Specific Unit",
}

-- The multi-unit families a clone-producing trigger iterates instead of a single
-- token. Upstream's saved `unit` values; ForEachMultiUnit below decides what
-- each one currently contains. unit_tokens_multi is the dropdown a prototype
-- that can produce clones offers -- the single tokens, then the families.
WeakestAuras.multi_unit_tokens = { "group", "party", "raid", "nameplate" }
WeakestAuras.multi_unit_labels = {
	group = "Group", party = "Party", raid = "Raid", nameplate = "Nameplates",
}
WeakestAuras.unit_tokens_multi = {}
WeakestAuras.unit_labels_multi = {}
for i = 1, table.getn(WeakestAuras.unit_tokens) do
	table.insert(WeakestAuras.unit_tokens_multi, WeakestAuras.unit_tokens[i])
end
for key, label in pairs(WeakestAuras.unit_labels) do
	WeakestAuras.unit_labels_multi[key] = label
end
for i = 1, table.getn(WeakestAuras.multi_unit_tokens) do
	local family = WeakestAuras.multi_unit_tokens[i]
	table.insert(WeakestAuras.unit_tokens_multi, family)
	WeakestAuras.unit_labels_multi[family] = WeakestAuras.multi_unit_labels[family]
end

-- The family a trigger's saved `unit` selects, or nil for a single token.
function WeakestAuras.MultiUnitFamily(trigger)
	local unit = trigger and trigger.unit
	return (unit and WeakestAuras.multi_unit_labels[unit]) and unit or nil
end

-- Stable clone identity for unit-producing triggers. A nameplate slot or raid
-- index can be reused for another unit; the GUID keeps the allstates key tied
-- to the unit while `state.unit` retains the live token used by Unit* APIs.
function WeakestAuras.UnitCloneId(unit)
	local guid = UnitGUID and UnitGUID(unit)
	return guid or unit
end

-- Calls fn(unit, cloneId) for every usable token in an upstream multi-unit
-- family. Group/party include the player outside raids; raid tokens already
-- include the player. Nameplate slots may contain holes, so all 40 confirmed
-- ClassicAPI slots are checked instead of stopping at the first empty one.
function WeakestAuras.ForEachMultiUnit(unitType, fn)
	if type(fn) ~= "function" then return end
	local seen = {}
	local function emit(unit)
		if UnitExists and UnitExists(unit) then
			local cloneId = WeakestAuras.UnitCloneId(unit)
			if cloneId ~= nil and not seen[cloneId] then
				seen[cloneId] = true
				fn(unit, cloneId)
			end
		end
	end

	if unitType == "nameplate" then
		for i = 1, 40 do emit("nameplate" .. i) end
		return
	end

	local raid = GetNumRaidMembers and (GetNumRaidMembers() or 0) or 0
	if unitType == "raid" or (unitType == "group" and raid > 0) then
		if raid > 40 then raid = 40 end
		for i = 1, raid do emit("raid" .. i) end
		return
	end

	if unitType == "party" or unitType == "group" then
		emit("player")
		local party = GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
		if party > 4 then party = 4 end
		for i = 1, party do emit("party" .. i) end
	end
end

-- Whether a family currently iterates `unit`, by the same membership rules
-- ForEachMultiUnit applies -- the token test a producer needs to answer "is this
-- unit event mine?" without walking the whole family per event. A unit reachable
-- through several tokens (the player in a raid is also raid7) answers false for
-- the tokens the family does not iterate; a producer keyed by GUID recognizes
-- those through its own state table instead.
function WeakestAuras.MultiUnitHasToken(unitType, unit)
	if type(unit) ~= "string" then return false end
	local function slot(pattern, limit)
		local _, _, n = string.find(unit, pattern)
		n = n and tonumber(n)
		return n ~= nil and n >= 1 and n <= limit
	end

	if unitType == "nameplate" then return slot("^nameplate(%d+)$", 40) end

	local raid = GetNumRaidMembers and (GetNumRaidMembers() or 0) or 0
	if unitType == "raid" or (unitType == "group" and raid > 0) then
		if raid > 40 then raid = 40 end
		return slot("^raid(%d+)$", raid)
	end

	if unitType == "party" or unitType == "group" then
		if unit == "player" then return true end
		local party = GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
		if party > 4 then party = 4 end
		return slot("^party(%d+)$", party)
	end
	return false
end

-- Upstream-compatible numeric clone ids for event producers. The optional
-- allstates argument closes wrap-around collisions for the table receiving the
-- key; clone ids are scoped to one trigger's allstates table.
local nextCloneId = 0
function WeakestAuras.GetUniqueCloneId(allstates)
	for _ = 1, 1000000 do
		nextCloneId = math.mod(nextCloneId + 1, 1000000)
		if not allstates or allstates[nextCloneId] == nil then return nextCloneId end
	end
	return nil
end

DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WeakestAuras|r loaded.", 1, 1, 1)
