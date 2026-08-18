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

-- The companion website. Shown in the options footer; there is no way to open
-- a browser from this client, so every reference offers the URL as copyable
-- text instead of a link.
WeakestAuras.WEBSITE = "https://weako.xyz"

-- ClassicAPI packs its version as X*10000 + Y*100 + Z; untagged local builds
-- carry a sentinel meaning "newer than every release".
local CLASSICAPI_DEV = 99999999

-- The oldest ClassicAPI whose feature set version gates can reason about.
-- Everything this addon calls unconditionally is assumed present from here on;
-- an API added in a later release must go through WeakestAuras.RequireClassicAPI
-- instead of a bare call. A client below this baseline predates that convention
-- entirely, so the options footer flags it as "update" rather than pretending
-- to know what it has.
WeakestAuras.CLASSICAPI_BASELINE = 10911 -- 1.9.11

-- "X.Y.Z" from a packed ClassicAPI version, "dev" for the sentinel. With no
-- argument, the running client's own; nil when it cannot answer.
function WeakestAuras.ClassicAPIVersionString(packed)
	if packed == nil then packed = CLASSIC_API_VERSION end
	if type(packed) ~= "number" then return nil end
	if packed == CLASSICAPI_DEV then return "dev" end
	return math.floor(packed / 10000) .. "."
		.. math.floor(math.mod(packed, 10000) / 100) .. "."
		.. math.mod(packed, 100)
end

-- SuperWoW's version as a display string, nil when the mod is absent. Neither
-- global is confirmed on a live client (see the capability-probe note above),
-- so a present-but-versionless SuperWoW answers "" and callers show the bare
-- mod name.
function WeakestAuras.SuperWoWVersionString()
	if SUPERWOW_VERSION ~= nil then return tostring(SUPERWOW_VERSION) end
	if type(SUPERWOW_STRING) == "string" then
		local _, _, v = string.find(SUPERWOW_STRING, "(%d[%d%.]*)")
		return v or ""
	end
	return nil
end

-- Nampower's version as "X.Y.Z", nil when absent or not answering.
function WeakestAuras.NampowerVersionString()
	if not WeakestAuras.hasNampower then return nil end
	local ok, major, minor, patch = pcall(GetNampowerVersion)
	if not ok or type(major) ~= "number" then return nil end
	return major .. "." .. (minor or 0) .. "." .. (patch or 0)
end

-- Feature gates against the client mods' versions. Each Require* answers
-- whether the running client has at least `minVersion` of its mod; false means
-- the caller must fall back gracefully. A false with a `label` is also
-- recorded, once per label, so the options footer can list what this client is
-- missing out on. ClassicAPI takes its own packed integer; SuperWoW and
-- Nampower take an "X.Y" / "X.Y.Z" string through ParseVersion.
WeakestAuras.degradedFeatures = {}
local function recordDegraded(mod, needs, label)
	if not label then return end
	local list = WeakestAuras.degradedFeatures
	for i = 1, table.getn(list) do
		if list[i].label == label then return end
	end
	table.insert(list, { mod = mod, needs = needs, label = label })
end

function WeakestAuras.RequireClassicAPI(minVersion, label)
	if type(CLASSIC_API_VERSION) == "number" and CLASSIC_API_VERSION >= minVersion then
		return true
	end
	recordDegraded("ClassicAPI", WeakestAuras.ClassicAPIVersionString(minVersion) or "?", label)
	return false
end

-- A present mod whose version cannot be read still fails a version gate: the
-- feature stays off rather than running against an unprovable surface, and the
-- footer says which version would turn it on.
function WeakestAuras.RequireSuperWoW(minVersion, label)
	local have = WeakestAuras.ParseVersion(WeakestAuras.SuperWoWVersionString() or "")
	local need = WeakestAuras.ParseVersion(minVersion)
	if have and need and have >= need then return true end
	recordDegraded("SuperWoW", tostring(minVersion), label)
	return false
end

function WeakestAuras.RequireNampower(minVersion, label)
	local have = WeakestAuras.ParseVersion(WeakestAuras.NampowerVersionString() or "")
	local need = WeakestAuras.ParseVersion(minVersion)
	if have and need and have >= need then return true end
	recordDegraded("Nampower", tostring(minVersion), label)
	return false
end

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
