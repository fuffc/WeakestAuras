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

if WeakestAuras.disabled then return end

-- ClassicAPI is the hard gate, in Bootstrap.lua. Nampower is optional: where it
-- is installed, the swing timer reads the queued on-next-swing ability from its
-- SPELL_QUEUE_EVENT instead of polling the warrior's action slots.
WeakestAuras.hasNampower = type(GetNampowerVersion) == "function"

-- The .toc's `## Version`, resolved once.
WeakestAuras.version = GetAddOnMetadata("WeakestAuras", "Version")

-- The companion website. Shown in the options footer; there is no way to open
-- a browser from this client, so every reference offers the URL as copyable
-- text instead of a link.
WeakestAuras.WEBSITE = "https://weako.xyz"

-- Nampower's version as "X.Y.Z", nil when absent or not answering.
function WeakestAuras.NampowerVersionString()
	if not WeakestAuras.hasNampower then return nil end
	local ok, major, minor, patch = pcall(GetNampowerVersion)
	if not ok or type(major) ~= "number" then return nil end
	return major .. "." .. (minor or 0) .. "." .. (patch or 0)
end

-- Where each client mod is kept. Offered as copyable text from the options
-- footer, since this client cannot open a browser.
WeakestAuras.MOD_SOURCES = {
	{ mod = "ClassicAPI", url = "https://github.com/brues-code/ClassicAPI/releases/" },
	{ mod = "Nampower", url = "https://github.com/Emyrk/nampower/releases/" },
}

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

-- ClassicAPI's inline |T...|t texture escapes -- an icon drawn inside a run of
-- text -- and FontString rotation, which the DLL applies inside the same
-- g_inlineEnabled branch. The feature has a runtime kill switch and an SEH
-- latch that trips it off after a fault, so the probe measures whether icons
-- are rendering right now: a client that does not honour the escape lays the
-- texture path out character by character, thirty-odd characters against one
-- icon's ~one line.
--
-- Never call _classicapi_InlineTexEnable to find out. Called with no arguments
-- it ENABLES the feature, so a probe would turn back on what the latch or the
-- user deliberately switched off.
do
	local probe = CreateFrame("Frame")
	local fs = probe:CreateFontString(nil, "ARTWORK")
	fs:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
	local rendered = false
	if fs:GetFont() then
		fs:SetText("MMMM")
		local ref = fs:GetStringWidth() or 0
		fs:SetText("|TInterface\\Icons\\INV_Misc_QuestionMark:0|t")
		local icon = fs:GetStringWidth() or 0
		rendered = ref > 0 and icon > 0 and icon < ref
	end
	WeakestAuras.hasInlineText = rendered
	probe:Hide()
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
for i = 1, #WeakestAuras.unit_tokens do
	table.insert(WeakestAuras.unit_tokens_multi, WeakestAuras.unit_tokens[i])
end
for key, label in pairs(WeakestAuras.unit_labels) do
	WeakestAuras.unit_labels_multi[key] = label
end
for i = 1, #WeakestAuras.multi_unit_tokens do
	local family = WeakestAuras.multi_unit_tokens[i]
	table.insert(WeakestAuras.unit_tokens_multi, family)
	WeakestAuras.unit_labels_multi[family] = WeakestAuras.multi_unit_labels[family]
end

-- The aura trigger's own dropdown: the families above, plus upstream's `multi`.
-- `multi` is not a family and ForEachMultiUnit cannot iterate it -- it names the
-- units the aura cache is tracking, whether or not a token points at any of
-- them, so only a trigger system with a GUID-keyed producer may offer it. That
-- is TriggerAura and nothing else, which is why the generic prototypes keep
-- unit_tokens_multi.
WeakestAuras.unit_tokens_aura = {}
WeakestAuras.unit_labels_aura = {}
for i = 1, #WeakestAuras.unit_tokens_multi do
	table.insert(WeakestAuras.unit_tokens_aura, WeakestAuras.unit_tokens_multi[i])
end
for key, label in pairs(WeakestAuras.unit_labels_multi) do
	WeakestAuras.unit_labels_aura[key] = label
end
table.insert(WeakestAuras.unit_tokens_aura, "multi")
WeakestAuras.unit_labels_aura.multi = "Multi-target"

-- The family a trigger's saved `unit` selects, or nil for a single token.
function WeakestAuras.MultiUnitFamily(trigger)
	local unit = trigger and trigger.unit
	return (unit and WeakestAuras.multi_unit_labels[unit]) and unit or nil
end

-- ---------------------------------------------------------------------------
-- Multi-select filters: one value, or a set of them
--
-- A filter that can hold either, spelled the same way wherever it appears --
-- generic trigger args and load constraints both. Three keys:
--
--   use_<name>     the mode: false, "single" or "multi"
--   <name>         the single value
--   <name>_multi   the set, { [value] = true }
--
-- The mode is a string rather than a boolean because there are genuinely three
-- states, and because WeakAuras2 overloads *one* gate for them: `use_<name>`
-- true is "one value" and **false is several**, not off. That overload is the
-- one a boolean gate misreads in the direction of matching too much, so the
-- importer undoes it here rather than letting each caller rediscover it.
--
-- An "off" filter passes everything. A "multi" set nothing was ticked in passes
-- **nothing** -- the only reading under which unticking an entry narrows the
-- match rather than silently widening it to everything. Upstream's
-- TestForMultiSelect agrees.
-- ---------------------------------------------------------------------------

WeakestAuras.multiselect_modes = { "off", "single", "multi" }
WeakestAuras.multiselect_mode_labels = { off = "Ignored", single = "One Of", multi = "Any Of" }

-- The mode `config` stores for `name`, normalised: anything that is not one of
-- the two real modes reads as off. A stray truthy value left by older saved data
-- would otherwise be an enabled filter nothing can satisfy.
function WeakestAuras.MultiSelectMode(config, name)
	local mode = config and config["use_" .. name]
	if mode == "single" or mode == "multi" then return mode end
	return "off"
end

-- Whether `value` passes the filter. The runtime half -- the load system tests
-- with this; the trigger compiler generates equivalent source instead, since its
-- tests are compiled once rather than evaluated per check.
function WeakestAuras.MultiSelectMatches(config, name, value)
	local mode = WeakestAuras.MultiSelectMode(config, name)
	if mode == "off" then return true end
	-- A numeric domain (the shapeshift bar position) is matched loosely, since a
	-- stored key survives a round trip through a foreign serialiser as a string
	-- and would otherwise miss the number the client reports. The compiled half
	-- coerces the same way -- GenericTrigger's multiSelectSource.
	if mode == "single" then
		if config[name] == value then return true end
		return type(value) == "number" and tonumber(config[name] or "") == value
	end
	local set = config[name .. "_multi"]
	if set == nil then return false end
	if set[value] then return true end
	return (type(value) == "number" and set[tostring(value)]) and true or false
end

-- Folds a filter that used to be a plain on/off gate into the tier: a stored
-- `true` meant the one value in `<name>`. Idempotent -- a real mode string and a
-- false gate are both left alone -- so it is safe wherever it is called
-- repeatedly, which a trigger's `migrate` hook is.
function WeakestAuras.MultiSelectMigrateGate(config, name)
	if config and config["use_" .. name] == true then
		config["use_" .. name] = "single"
	end
end

-- Appends the filter's editor rows to `fields`: the mode tier, then either one
-- dropdown or a toggle per value. `spec` carries `config` (the table holding the
-- three keys), `name`, `display`, `values`, `labels`, an optional `default` for
-- the single value, and `onChange(needsRepaint)` -- the caller owns committing
-- and repainting, which differs between the Load tab and a trigger's editor.
--
-- Layout. The mode and the one value it applies are both `half`, so they land
-- side by side on one row and read as one setting rather than two stacked ones.
--
-- **The whole filter is fenced, in every mode.** The layout pairs consecutive
-- `half` fields onto one row, so a filter that emits an odd number of them
-- leaves a dangling half that the *next* field pairs onto -- and every mode here
-- can emit an odd number: "Ignored" is the mode row alone, and a set can have an
-- odd count. Unfenced, an ignored Class lands beside Race's mode row and Race's
-- value beside Faction's, which is three filters bleeding across two rows.
-- The zero-height spacers are what make one filter occupy its own rows; they are
-- structure, not spacing. Upstream fences the same two seams for the same
-- reason -- a full-width spacer before the filter, and a half-width empty
-- description after the gate when it is off, to fill the cell that would
-- otherwise swallow a neighbour (`WeakAurasOptions/LoadOptions.lua`). It needs a
-- filler where this layout has a real flush, which is the only difference.
--
-- What is *not* copied is the box: AceConfigDialog draws a titled inline group
-- round the checkbox set, and this options window has no container that draws
-- one round a run of fields. The indent stands in for it.
function WeakestAuras.MultiSelectFields(fields, spec)
	local config, name = spec.config, spec.name
	local display = spec.display or name
	local useKey, setKey = "use_" .. name, spec.name .. "_multi"
	local function changed(repaint)
		if spec.onChange then spec.onChange(repaint) end
	end

	-- Opens the fence: a dangling half left by whatever came before must not pair
	-- onto this filter's mode row.
	table.insert(fields, { type = "space", useHeight = true, height = 0 })
	table.insert(fields, {
		type = "select", name = display, key = useKey, half = true,
		values = WeakestAuras.multiselect_modes,
		labels = spec.modeLabels or WeakestAuras.multiselect_mode_labels,
		get = function() return WeakestAuras.MultiSelectMode(config, name) end,
		set = function(v)
			-- Branched, not `(v == "off") and false or v` -- that idiom yields
			-- "off" for the very case it means to store false, and "off" is
			-- truthy, so the filter would read as enabled while showing Ignored.
			if v == "off" then
				config[useKey] = false
			else
				config[useKey] = v
				if v == "single" and config[name] == nil then config[name] = spec.default end
				if v == "multi" then
					local set = config[setKey] or {}
					config[setKey] = set
					-- The value the filter was narrowed to carries into the set it
					-- is being widened into, so "one of" -> "any of" starts from
					-- what was already chosen instead of from nothing (upstream
					-- does the same on this transition). Only into an empty set,
					-- so a set the user has already built is never added to.
					if config[name] ~= nil and next(set) == nil then
						set[config[name]] = true
					end
				end
			end
			changed(true)
		end,
	})

	local mode = WeakestAuras.MultiSelectMode(config, name)
	if mode == "single" then
		table.insert(fields, {
			type = "select", name = display, key = name, half = true,
			values = spec.values, labels = spec.labels,
			get = function() return config[name] or spec.default end,
			set = function(v) config[name] = v; changed(false) end,
		})
	elseif mode == "multi" then
		-- Seeded here rather than only in the mode setter: a trigger that arrived
		-- from an import is already in "multi" and has never been through it.
		local set = config[setKey] or {}
		config[setKey] = set
		-- The mode row keeps its own row; the set starts on the next one.
		table.insert(fields, { type = "space", useHeight = true, height = 0 })
		local values = spec.values or {}
		for i = 1, #values do
			local value = values[i]
			table.insert(fields, {
				type = "toggle", key = setKey .. "." .. tostring(value), half = true,
				name = (spec.labels and spec.labels[value]) or tostring(value),
				indent = 1,
				get = function() return set[value] and true or false end,
				set = function(v) set[value] = v and true or nil; changed(false) end,
			})
		end
	end
	-- Closes the fence. The gap is only worth spending after a set, which reads
	-- as a block; an ignored or single-valued filter is one row like any other.
	table.insert(fields, {
		type = "space", useHeight = true, height = mode == "multi" and 0.35 or 0,
	})
	return fields
end

-- Stable clone identity for unit-producing triggers. A nameplate slot or raid
-- index can be reused for another unit; the GUID keeps the allstates key tied
-- to the unit while `state.unit` retains the live token used by Unit* APIs.
function WeakestAuras.UnitCloneId(unit)
	local guid = UnitGUID(unit)
	return guid or unit
end

local NAMEPLATE_TOKENS, RAID_TOKENS, PARTY_TOKENS = {}, {}, {}
for i = 1, 40 do
	NAMEPLATE_TOKENS[i] = "nameplate" .. i
	RAID_TOKENS[i] = "raid" .. i
end
for i = 1, 4 do PARTY_TOKENS[i] = "party" .. i end

local function emitMultiUnit(unit, seen, fn)
	if UnitExists(unit) then
		local cloneId = WeakestAuras.UnitCloneId(unit)
		if cloneId ~= nil and not seen[cloneId] then
			seen[cloneId] = true
			fn(unit, cloneId)
		end
	end
end

-- Calls fn(unit, cloneId) for every usable token in an upstream multi-unit
-- family. Group/party include the player outside raids; raid tokens already
-- include the player. Nameplate slots may contain holes, so all 40 confirmed
-- ClassicAPI slots are checked instead of stopping at the first empty one.
-- The aura scan walks a family five times a second, so the tokens are built
-- once and the duplicate set is pooled scratch.
function WeakestAuras.ForEachMultiUnit(unitType, fn)
	if type(fn) ~= "function" then return end
	local seen = WeakestAuras.AcquireScratch()
	local raid = GetNumRaidMembers()
	if unitType == "nameplate" then
		for i = 1, 40 do emitMultiUnit(NAMEPLATE_TOKENS[i], seen, fn) end
	elseif unitType == "raid" or (unitType == "group" and raid > 0) then
		if raid > 40 then raid = 40 end
		for i = 1, raid do emitMultiUnit(RAID_TOKENS[i], seen, fn) end
	elseif unitType == "party" or unitType == "group" then
		emitMultiUnit("player", seen, fn)
		local party = GetNumPartyMembers()
		if party > 4 then party = 4 end
		for i = 1, party do emitMultiUnit(PARTY_TOKENS[i], seen, fn) end
	end
	WeakestAuras.ReleaseScratch(seen)
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

	local raid = GetNumRaidMembers()
	if unitType == "raid" or (unitType == "group" and raid > 0) then
		if raid > 40 then raid = 40 end
		return slot("^raid(%d+)$", raid)
	end

	if unitType == "party" or unitType == "group" then
		if unit == "player" then return true end
		local party = GetNumPartyMembers()
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
		nextCloneId = math.fmod(nextCloneId + 1, 1000000)
		if not allstates or allstates[nextCloneId] == nil then return nextCloneId end
	end
	return nil
end

DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WeakestAuras|r loaded.", 1, 1, 1)
