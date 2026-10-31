-- WeakestAuras -- BuffTrigger-lite: the runtime trigger system for aura
-- triggers. Registered via WA.RegisterTriggerSystem({"aura"}, ...). Mirrors
-- WA2's BuffTrigger2 (§5).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- It is a *watcher* (§4.4): the game gives us no reliable aura-refresh
-- event on this client, so a 0.2s poll (nudged by UNIT_AURA/PLAYER_TARGET_CHANGED)
-- is the real drive. Per tick it walks C_UnitAuras once per watched unit, and for
-- each registered trigger info (ti) forward-scans its configured name/spellId
-- entries against that unit's aura list(s), writing state through field-by-field
-- change detection -- only displays whose states actually changed get
-- re-combined. A ti may carry several entries ("any of these") and up to two
-- filters (debuffType = "BOTH"), so match lookup is forward (per-ti) rather than
-- a name-keyed reverse index -- trigger counts here are small enough (dozens,
-- not thousands) that this is simpler without being slower in practice.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

local TriggerAura = {}

-- scanIndex[unit] = { triggerInfo, ... } -- everything watching that unit;
-- findMatch (below) walks each ti's own entries/filters against the unit's
-- (memoized) aura list rather than a name-keyed reverse index.
local scanIndex = {}
-- perId[id] = { triggerInfo, ... } -- everything this display compiled, for
-- Load/Unload/Delete/Rename bookkeeping. Present after Add (compile); its TIs
-- only enter scanIndex (become scannable) once the display is loaded.
local perId = {}
-- activeIds[id] = true while this display's TIs are in scanIndex (it's loaded).
-- Keeps Load/Unload idempotent so a redundant call can't double-register or
-- unregister a TI that isn't there.
local activeIds = {}

-- pool[unit][filter] = { n = live entries, gen = the scan that filled them,
-- [1..] = reusable aura tables }. Several triggers on one unit share one scan,
-- and the tables outlive the tick so that a steady-state scan allocates nothing.
-- Entries above `n` still hold an earlier scan's values, so every walk of a
-- list is bounded by `list.n`, never `#list`.
--
-- Safe only while no aura table outlives the scan that filled it: nothing may
-- store one. updateTriggerInfoState copies scalars into the state, and a match
-- is consumed before the next findMatch can refill what it points at.
local pool = {}
local poolSeen = {} -- unit -> the scan that last read it, for the sweep in scanTick
local scanGen = 0
local slots = {} -- GetAuraSlots fill target, reused across scans

local function cmp(op, a, b)
	if a == nil or b == nil then return false end
	if op == "==" then return a == b
	elseif op == "~=" then return a ~= b
	elseif op == ">" then return a > b
	elseif op == ">=" then return a >= b
	elseif op == "<" then return a < b
	elseif op == "<=" then return a <= b end
	return false
end

-- Refills one pooled entry through UnitAuraBySlot, the same aura as
-- GetAuraDataBySlot pushed as values instead of built into a fresh ~22-field
-- table. Reads up to position 10 (spellId) and stops: position 13,
-- `castByPlayer`, means "cast by any player", not "cast by me", and leaving it
-- unread keeps an ownership test from being built on it. `sourceGUID` has no
-- position at all, so it is cleared for casterGUID to resolve on demand --
-- clearing matters, since the entry is reused and the last scan's caster would
-- otherwise read as this aura's.
local function fillEntry(a, unit, slot)
	local name, icon, count, dispelType, duration, expirationTime, source,
		_, _, spellId = C_UnitAuras.UnitAuraBySlot(unit, slot)
	a.name = name
	a.icon = icon
	a.applications = count
	a.dispelName = dispelType
	a.duration = duration
	a.expirationTime = expirationTime
	a.sourceUnit = source
	a.spellId = spellId
	a.unit = unit
	a.slot = slot
	a.sourceGUID = nil
	a.guidChecked = nil
end

-- One GetAuraSlots walk plus a positional by-slot read per aura; a by-index
-- loop would re-walk the aura array for every index. Slots come back in index
-- order, so a list position is still the aura's C_UnitAuras index. Shared per
-- unit and filter for the scan -- two levels rather than a concatenated key,
-- since this lookup runs per entry per filter per trigger.
local function scanUnit(unit, filter)
	poolSeen[unit] = scanGen
	local byFilter = pool[unit]
	if not byFilter then
		byFilter = {}
		pool[unit] = byFilter
	end
	local list = byFilter[filter]
	if not list then
		list = { n = 0, gen = -1 }
		byFilter[filter] = list
	end
	if list.gen == scanGen then return list end
	list.gen = scanGen
	local _, n = C_UnitAuras.GetAuraSlots(unit, filter, nil, nil, slots)
	for i = 1, n do
		local a = list[i]
		if not a then
			a = {}
			list[i] = a
		end
		fillEntry(a, unit, slots[i])
	end
	list.n = n
	return list
end

-- The caster's GUID, the only field that separates "nobody knows who cast
-- this" from "someone we know cast it and no token names them": the tuple's
-- `sourceUnit` is nil for both. Pays one GetAuraDataBySlot for that ambiguous
-- aura alone and caches the answer on the pooled entry, so findMatch's counting
-- walk does not pay it again. Slot ids hold for the frame, and this runs inside
-- the scan that filled the entry.
local function casterGUID(aura)
	if not aura.guidChecked then
		aura.guidChecked = true
		local d = C_UnitAuras.GetAuraDataBySlot(aura.unit, aura.slot)
		aura.sourceGUID = d and d.sourceGUID or nil
	end
	return aura.sourceGUID
end

local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- The Dispel Type condition's values: SpellDispelType.dbc ids 1..4, the names
-- an aura's dispelName carries.
local DISPEL_TYPES = { "Magic", "Curse", "Disease", "Poison" }

local playerGuid
local function playerGUID()
	if not playerGuid then playerGuid = UnitGUID("player") end
	return playerGuid
end

-- name, icon for a ti's configured entries (the fallback identity for
-- showOnMissing/showAlways with no current match, and what the options list
-- resolves a row's icon from). Walks the entries until one resolves to a real
-- icon, matching upstream's BuffTrigger.GetNameAndIcon: a numeric entry is a
-- spellID, a text entry goes through WA.ResolveSpellID (bounded to the player's
-- own spellbook, so a debuff only another class casts legitimately won't
-- resolve) -- matching itself is still by literal aura.name for those, this is
-- display only. `icon` comes back nil when nothing resolved, so a caller with a
-- better fallback than the question mark (the options row's manual icon) can
-- use it.
local function resolveNameIcon(ti)
	local entries = ti.entries or {}
	local firstRaw
	for i = 1, #entries do
		local entry = entries[i]
		firstRaw = firstRaw or entry.raw
		local id = entry.id or WA.ResolveSpellID(entry.raw)
		if id then
			local name, _, icon = GetSpellInfo(id)
			if icon then return name or entry.raw or "", icon end
		end
	end
	return firstRaw or "", nil
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

-- Compiles a name list into match entries: a tonumber-able entry matches by
-- AuraData.spellId (precise -- disambiguates same-name ranks), a text entry by
-- aura.name. Takes the list rather than the trigger, since the match list and
-- the ignore list are the same shape and both go through here.
local function buildEntries(names)
	local entries = {}
	names = names or {}
	for i = 1, #names do
		local raw = names[i]
		if raw and raw ~= "" then
			table.insert(entries, { raw = raw, id = tonumber(raw) })
		end
	end
	return entries
end

local function buildTriggerInfo(id, triggernum, t)
	local entries = buildEntries(t.auranames)
	local showOn = t.matchesShowOn or "showOnActive"
	-- With no names configured there is nothing to find, but showOnMissing and
	-- showAlways are defined by the absence of a match, so they still need a
	-- state; only showOnActive can never show and is skipped.
	if #entries == 0 and showOn == "showOnActive" then return nil end
	local filters
	if t.debuffType == "BOTH" then filters = { "HELPFUL", "HARMFUL" }
	else filters = { t.debuffType or "HELPFUL" } end
	return {
		id = id,
		triggernum = triggernum,
		unit = WA.TriggerUnit(t, "player"),
		-- Non-nil for a family (group/party/raid/nameplate): the scan runs once
		-- per member and writes one GUID-keyed clone each, instead of one base
		-- state for one token.
		multiUnit = WA.MultiUnitFamily(t),
		-- Upstream's `multi`, which is not a family of tokens at all: the clones
		-- come from the GUIDs the combat log saw gain an aura, one per unit
		-- carrying a match.
		multiGuid = t.unit == "multi",
		filters = filters,
		entries = entries,
		ignoreEntries = buildEntries(t.auraignorenames),
		ownOnly = t.ownOnly and true or false,
		castByPlayer = t.castByPlayer and true or false,
		unitExists = t.unitExists and true or false,
		use_debuffClass = t.use_debuffClass, debuffClass = t.debuffClass,
		matchesShowOn = t.matchesShowOn or "showOnActive",
		useStacks = t.useStacks, stacksOperator = t.stacksOperator, stacks = t.stacks,
		useRem = t.useRem, remOperator = t.remOperator, rem = t.rem,
		useTotal = t.useTotal, totalOperator = t.totalOperator, total = t.total,
		useCasterName = t.useCasterName, casterName = t.casterName,
		useNamePattern = t.useNamePattern, namePattern = t.namePattern,
		namePatternOperator = t.namePatternOperator or "match",
	}
end

-- Multi-target (`unit = "multi"`): the subject is every unit in the pull rather
-- than one token, so the combat log supplies the unit list, as it does for
-- upstream's BuffTrigger2 (§5, matchDataMulti). A GUID enters when one of the
-- watched auras lands on it and leaves when it dies; the scan reads it like any
-- other unit. Admitting only watched spells keeps the list to the units that can
-- match, not every unit in a raid that gained any aura. The event is registered
-- only while a multi trigger is loaded, since ClassicAPI builds no combat log
-- payload that nothing listens to.
local multiGuids = {}
local multiSpells = {} -- spellId or name -> true, from every loaded multi trigger's entries
local multiFrame = CreateFrame("Frame")
multiFrame:SetScript("OnEvent", function()
	local subevent = arg2
	if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_APPLIED_DOSE"
		or subevent == "SPELL_AURA_REFRESH" then
		if multiSpells[arg12] or multiSpells[arg13] then multiGuids[arg8] = true end
	elseif subevent == "UNIT_DIED" or subevent == "UNIT_DESTROYED" then
		multiGuids[arg8] = nil
	end
end)

-- UNIT_AURA is registered for the tokens the loaded triggers read, so raid
-- traffic for units nothing watches never reaches the scan nudge. A family adds
-- every token it can iterate; a multi trigger adds none, since its GUIDs are
-- not tokens UNIT_AURA names.
local auraFrame = CreateFrame("Frame")
auraFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
local FAMILY_TOKENS = {}
do
	local function append(list, prefix, n)
		for i = 1, n do table.insert(list, prefix .. i) end
		return list
	end
	FAMILY_TOKENS.party = append({ "player" }, "party", 4)
	FAMILY_TOKENS.raid = append({}, "raid", 40)
	FAMILY_TOKENS.group = append(append({ "player" }, "party", 4), "raid", 40)
	FAMILY_TOKENS.nameplate = append({}, "nameplate", 40)
end

-- scanIndex[unit] = { ti, ti, ... } -- a ti may need more than one filter
-- (debuffType = "BOTH"), so indexing is by unit only; findMatch below walks
-- each ti's own filters/entries against that unit's (memoized) aura lists.
local function registerTI(ti)
	local key = ti.unit
	scanIndex[key] = scanIndex[key] or {}
	table.insert(scanIndex[key], ti)
	ti._key = key
end

local function unregisterTI(ti)
	local list = scanIndex[ti._key]
	if not list then return end
	for i = #list, 1, -1 do
		if list[i] == ti then table.remove(list, i) end
	end
end

-- Re-derive both event registrations from scanIndex after a load or unload.
local function refreshEvents()
	local units, seen = {}, {}
	local function add(token)
		if not seen[token] then
			seen[token] = true
			table.insert(units, token)
		end
	end
	table.wipe(multiSpells)
	local multi = false
	for key, tis in pairs(scanIndex) do
		if #tis > 0 then
			if key == "multi" then
				multi = true
				for j = 1, #tis do
					local entries = tis[j].entries
					for e = 1, #entries do
						multiSpells[entries[e].id or entries[e].raw] = true
					end
				end
			elseif FAMILY_TOKENS[key] then
				local tokens = FAMILY_TOKENS[key]
				for i = 1, #tokens do add(tokens[i]) end
			else
				add(key)
			end
		end
	end
	-- A unit registration keeps its kind and units until it is unregistered.
	auraFrame:UnregisterEvent("UNIT_AURA")
	if #units > 0 then auraFrame:RegisterUnitEvent("UNIT_AURA", unpack(units)) end
	if multi then
		multiFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	else
		multiFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
		table.wipe(multiGuids)
	end
end

-- Compile only: build this display's triggerInfos into perId. Registration into
-- the live scanIndex is deferred to LoadDisplays (§11) -- an unloaded
-- aura is compiled but never scanned for.
function TriggerAura.Add(data)
	TriggerAura.Delete(data.id)
	local list = {}
	perId[data.id] = list
	for triggernum = 1, #data.triggers do
		local t = WA.GetTrigger(data, triggernum)
		if t and t.type == "aura" then
			local ti = buildTriggerInfo(data.id, triggernum, t)
			if ti then
				table.insert(list, ti)
			end
		end
	end
end

-- Load: put this display's compiled TIs into scanIndex so the next scan tick
-- sees them. Only touches ids this system actually compiled (perId[id]).
function TriggerAura.LoadDisplays(ids)
	local registered = false
	for k = 1, #ids do
		local id = ids[k]
		local list = perId[id]
		if list and not activeIds[id] then
			activeIds[id] = true
			for i = 1, #list do registerTI(list[i]) end
			registered = true
		end
	end
	if registered then refreshEvents() end
	-- Re-derive current match state synchronously (GenericTrigger does the same via
	-- force_events). WA.Add collapses the region before load, so without this an
	-- already-matching aura would blink hidden until the 0.2s scan ticker's next fire.
	if registered then TriggerAura.scanTick() end
end

-- Unload: pull this display's TIs out of scanIndex (it stops being scanned) but
-- keep them in perId, so a later reload re-registers without recompiling.
function TriggerAura.UnloadDisplays(ids)
	local unregistered = false
	for k = 1, #ids do
		local id = ids[k]
		if activeIds[id] then
			activeIds[id] = nil
			local list = perId[id]
			if list then
				for i = 1, #list do unregisterTI(list[i]) end
				unregistered = true
			end
		end
	end
	if unregistered then refreshEvents() end
end

function TriggerAura.Delete(id)
	TriggerAura.UnloadDisplays({ id })
	perId[id] = nil
end

-- scanIndex holds the same triggerInfo objects perId does, keyed by unit (not
-- id), so re-keying id in place is enough -- no re-registration.
function TriggerAura.Rename(oldId, newId)
	local list = perId[oldId]
	if not list then return end
	for i = 1, #list do list[i].id = newId end
	perId[newId] = list
	perId[oldId] = nil
	if activeIds[oldId] then
		activeIds[newId] = true
		activeIds[oldId] = nil
	end
end

-- ---------------------------------------------------------------------------
-- Contract methods the glue/options call
-- ---------------------------------------------------------------------------

function TriggerAura.GetNameAndIcon(data, triggernum)
	local t = WA.GetTrigger(data, triggernum)
	if not t then return nil, nil end
	return resolveNameIcon({ entries = buildEntries(t.auranames) })
end

function TriggerAura.CreateFallbackState(data, triggernum, state)
	local name, icon = TriggerAura.GetNameAndIcon(data, triggernum)
	state.name = name
	state.icon = icon or UNKNOWN_ICON
	state.stacks = 0
	state.progressType = nil
	state.active = false
	return state
end

-- The options preview (§14). This system does *not* scan: it synthesises, the
-- way WA2's BuffTrigger.CreateFakeStates does, because running the scanner over
-- the live unit answers a question the user is not asking -- they are configuring
-- an aura for a fight they are not in. A trigger that can produce clones gets two
-- extra ones on staggered timers, so a dynamic group's ordering, limits and
-- stagger are visible in the options window rather than only after closing it.
--
-- Diverges from upstream in taking `data` rather than an id (matching the other
-- contract methods here), and in what "can have clones" means: upstream's
-- `showClones` has no local counterpart, so it is a multi-unit family
-- (group/party/raid/nameplate) or multi-target -- the two shapes that write more
-- than the base state at runtime.
function TriggerAura.CreateFakeStates(data, triggernum)
	local states = WA.GetTriggerStateForTrigger(data.id, triggernum)
	if not states then return end

	local function fake(cloneId, expiresIn, duration)
		local state = TriggerAura.CreateFallbackState(data, triggernum, {})
		state.show = true
		state.changed = true
		state.progressType = "timed"
		state.duration = duration
		state.expirationTime = GetTime() + expiresIn
		state.stacks = 1
		-- The fallback describes the *unmatched* case, which is not what a preview
		-- carrying a countdown and a stack count is showing -- a condition on
		-- Active would otherwise read false against a state drawn as present.
		state.active = true
		states[cloneId] = state
	end

	fake("", 60, 65)
	local t = WA.GetTrigger(data, triggernum)
	if WA.MultiUnitFamily(t) or (t and t.unit == "multi") then
		for i = 1, 2 do fake(i, 60 + i * 20, 100) end
	end
end

-- Condition-variable templates (§5/§10): what this trigger's state exposes
-- to the conditions editor and interpreter. Each key is the state field a check
-- reads; type drives the editor widget and the comparison. `timer` compares
-- against remaining time (expiry - now) with an exact scheduled recheck;
-- `elapsedTimer` against time since a past timestamp -- both are information
-- DoiteAuras needs Nampower events for, falling out of our poll cadence for free.
local AURA_CONDITIONS = {
	stacks = { display = "Stacks", type = "number" },
	-- Upstream's trigger-wide totals: how many auras matched across everything
	-- this trigger watches, and their stacks summed. On a single unit that is
	-- the unit's own count; on a family the scan overwrites every clone with
	-- the group-wide sum.
	matchCount = { display = "Total Match Count", type = "number" },
	totalStacks = { display = "Total Stacks", type = "number" },
	name = { display = "Name", type = "string" },
	spellId = { display = "Spell ID", type = "number" },
	duration = { display = "Duration", type = "number" },
	-- "Aura(s) Found" rather than "Active", which is what the trigger-wide `show`
	-- variable is called: on a trigger set to show either way the two differ, and
	-- one label on both rows in the same dropdown reads as a duplicate.
	active = { display = "Aura(s) Found", type = "bool" },
	filter = { display = "Aura Type", type = "select", values = { "HELPFUL", "HARMFUL" } },
	dispelName = { display = "Dispel Type", type = "select", values = DISPEL_TYPES },
	expirationTime = { display = "Remaining Time", type = "timer" },
	initialTime = { display = "Time Since Apply", type = "elapsedTimer" },
	refreshTime = { display = "Time Since Refresh", type = "elapsedTimer" },
	stackGainTime = { display = "Time Since Stack Gain", type = "elapsedTimer" },
	stackLostTime = { display = "Time Since Stack Lost", type = "elapsedTimer" },
	-- ClassicAPI backport, a real 40yd position check; refreshed on this
	-- trigger's own poll cadence, not on movement.
	inRange = { display = "In Range", type = "bool" },
	unit = { display = "Unit", type = "string" },
	unitName = { display = "Unit Name", type = "string" },
	casterName = { display = "Caster Name", type = "string" },
	unitCaster = { display = "Caster Unit", type = "string" },
	index = { display = "Aura Slot", type = "number" },
}

function TriggerAura.GetTriggerConditions(data, triggernum)
	return AURA_CONDITIONS
end

-- ---------------------------------------------------------------------------
-- The scanner
-- ---------------------------------------------------------------------------

-- Whether the matched aura passes this trigger's extra filters.
local function passesMatch(ti, aura)
	-- The ignore list outranks the match list, so a broad name pattern can be
	-- narrowed by naming the few auras it shouldn't catch. Same entry shape, so
	-- an id entry is compared by spellId and a text one by name.
	local ignore = ti.ignoreEntries
	for i = 1, (ignore and #ignore or 0) do
		local e = ignore[i]
		if (e.id and aura.spellId == e.id) or (not e.id and aura.name == e.raw) then
			return false
		end
	end
	-- Caster attribution is best-effort here: it comes from ClassicAPI's
	-- SMSG_SPELL_GO cache, so an aura active at login -- or any
	-- aura when the cast packet wasn't observed -- reports no caster at all.
	-- Reject only when we positively know the caster is someone else; an unknown
	-- caster can't be proven foreign, so let it pass rather than hide a
	-- genuinely-own buff.
	--
	-- A resolved token settles most auras, since ClassicAPI tries `player`
	-- before any other token: a caster that is us always names us. Only a
	-- caster no token resolves for reaches the GUID, the sole field that tells a
	-- known foreign caster from an unknown one -- letting the first pass as
	-- "unknown" is how a stranger's debuff shows up as ours.
	if ti.ownOnly then
		if aura.sourceUnit ~= nil then
			if aura.sourceUnit ~= "player" then return false end
		else
			local guid = casterGUID(aura)
			if guid ~= nil and guid ~= playerGUID() then return false end
		end
	end
	-- Any player caster, as against ownOnly's "me". Inherits the same
	-- unknown-caster tolerance: nil sourceUnit can't be proven to be a mob.
	if ti.castByPlayer and aura.sourceUnit ~= nil and not UnitIsPlayer(aura.sourceUnit) then
		return false
	end
	if ti.useCasterName and ti.casterName and ti.casterName ~= "" then
		local cname = aura.sourceUnit and UnitName(aura.sourceUnit)
		if not cname or string.lower(cname) ~= string.lower(ti.casterName) then return false end
	end
	-- dispelName comes from SpellDispelType.dbc and is "" for anything that
	-- can't be dispelled, so an empty value never matches a chosen class.
	if ti.use_debuffClass and aura.dispelName ~= ti.debuffClass then return false end
	if ti.useNamePattern and ti.namePattern and ti.namePattern ~= "" then
		-- Plain substring search (find's 4th arg), not a Lua pattern -- spell
		-- names can contain magic characters ("-", "(", ")") that would
		-- otherwise need escaping the user shouldn't have to think about.
		local found = aura.name and string.find(aura.name, ti.namePattern, 1, true)
		if ti.namePatternOperator == "nomatch" then
			if found then return false end
		else
			if not found then return false end
		end
	end
	if ti.useStacks and not cmp(ti.stacksOperator or ">=", aura.applications or 0, ti.stacks or 0) then
		return false
	end
	if ti.useRem then
		local remain = (aura.expirationTime or 0) - GetTime()
		if not cmp(ti.remOperator or "<=", remain, ti.rem or 0) then return false end
	end
	-- The aura's full duration, not what's left of it: distinguishes a 30s
	-- version of a spell from its 5s one when both carry the same name.
	if ti.useTotal and not cmp(ti.totalOperator or ">=", aura.duration or 0, ti.total or 0) then
		return false
	end
	return true
end

-- Forward per-ti match: walk this ti's entries in configured (priority) order,
-- each against each of its filters, first passing hit wins. Small n (a
-- handful of entries/filters, <=40 auras per scan) makes this cheaper than
-- maintaining a name+id reverse index for the multi-entry/BOTH-filter case.
-- The winner also carries `count`/`stacksTotal` -- upstream's matchCount and
-- totalStacks (§5): every matching aura instance on this unit counted once (an
-- aura matching two entries is one aura), and their stacks summed. The second
-- walk re-reads scanUnit's pooled list, so it costs no second descriptor scan.
--
-- The winner is written into a record the ti keeps, not a fresh table: this
-- runs per matched trigger per scan. Every caller hands it to
-- updateTriggerInfoState before asking this ti for its next match.
local function findMatch(ti, unit)
	local best
	for e = 1, #ti.entries do
		local entry = ti.entries[e]
		for fi = 1, #ti.filters do
			local filter = ti.filters[fi]
			local list = scanUnit(unit, filter)
			for i = 1, list.n do
				local aura = list[i]
				local ok
				if entry.id then ok = aura.spellId == entry.id
				else ok = aura.name == entry.raw end
				if ok and passesMatch(ti, aura) then
					best = ti.match
					if not best then
						best = { aura = false, index = 0, filter = false, count = 0, stacksTotal = 0 }
						ti.match = best
					end
					best.aura, best.index, best.filter = aura, i, filter
					break
				end
			end
			if best then break end
		end
		if best then break end
	end
	if not best then return nil end
	local count, stacksTotal = 0, 0
	for fi = 1, #ti.filters do
		local list = scanUnit(unit, ti.filters[fi])
		for i = 1, list.n do
			local aura = list[i]
			local matched = false
			for e = 1, #ti.entries do
				local entry = ti.entries[e]
				if (entry.id and aura.spellId == entry.id)
					or (not entry.id and aura.name == entry.raw) then
					matched = true
					break
				end
			end
			if matched and passesMatch(ti, aura) then
				count = count + 1
				stacksTotal = stacksTotal + (aura.applications or 0)
			end
		end
	end
	best.count = count
	best.stacksTotal = stacksTotal
	return best
end

-- The field writer below, shared through upvalues rather than a closure per
-- call: this runs per trigger per 0.2s tick whether or not anything changed.
-- Safe because nothing between the assignments and the last set() call can
-- re-enter updateTriggerInfoState -- every call in that window is an engine
-- read (Unit*, GetSpellInfo), never user code.
local curState, curChanged
local function set(k, v)
	if curState[k] ~= v then curState[k] = v; curChanged = true end
end

-- Writes one state of ti with field-by-field change detection: the base `""`
-- state for a single token, or `cloneId`'s for one member of a multi-unit
-- family. `match` is the matched { aura, index, filter } (or nil). Returns true
-- if any field changed.
local function updateTriggerInfoState(ti, unit, cloneId, match)
	local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
	if not states then return false end

	local token = unit -- a multi-target clone's GUID is a ClassicAPI unit token too

	local aura = match and match.aura
	local matched = aura ~= nil

	local shown
	local showOn = ti.matchesShowOn
	if showOn == "showOnMissing" then shown = not matched
	elseif showOn == "showAlways" then shown = true
	else shown = matched end -- showOnActive

	-- A unit that isn't there has no auras, which makes "aura missing" trivially
	-- true on an empty target and would show the display whenever nothing is
	-- targeted at all. Showing that is opt-in.
	if token and not UnitExists(token) and not ti.unitExists then shown = false end

	local state = states[cloneId]

	if not shown then
		if not state or not state.show then return false end
		state.show = false
		state.changed = true
		return true
	end

	if not state then state = {}; states[cloneId] = state end
	local now = GetTime()
	curState = state
	curChanged = false

	-- Timestamp trio, computed before the fields they compare against get
	-- overwritten (§5: refresh = expirationTime jumped > 0.2s).
	if not state.show then
		state.initialTime = now
		state.refreshTime = now
		curChanged = true
	elseif matched and state.expirationTime and aura.expirationTime
		and (aura.expirationTime - state.expirationTime > 0.2) then
		state.refreshTime = now
		curChanged = true
	end
	if matched then
		local newStacks = aura.applications or 0
		if state.stacks and newStacks > state.stacks then state.stackGainTime = now; curChanged = true
		elseif state.stacks and newStacks < state.stacks then state.stackLostTime = now; curChanged = true end
	end

	set("show", true)
	set("active", matched and true or false)
	set("inRange", (token and UnitInRange(token)) and true or false)
	-- Per-unit here; the family scans overwrite both with the trigger-wide
	-- totals afterwards, which is what upstream's matchCount/totalStacks are.
	set("matchCount", match and (match.count or 1) or 0)
	set("totalStacks", match and (match.stacksTotal or 0) or 0)

	if matched then
		set("progressType", "timed")
		set("name", aura.name)
		set("icon", aura.icon)
		set("stacks", aura.applications or 0)
		set("duration", aura.duration)
		set("expirationTime", aura.expirationTime)
		set("spellId", aura.spellId)
		set("dispelName", aura.dispelName)
		set("unit", unit)
		set("unitName", token and UnitName(token) or nil)
		set("unitCaster", aura.sourceUnit)
		set("casterName", aura.sourceUnit and UnitName(aura.sourceUnit) or nil)
		set("filter", match.filter)
		set("index", match.index)
	else
		-- showOnMissing / showAlways with no match: fallback identity. The
		-- matched-only fields are cleared so a condition on them (Caster Name,
		-- Aura Index) doesn't read a caster/aura that is no longer there.
		local name, icon = resolveNameIcon(ti)
		set("progressType", nil)
		set("name", name)
		set("icon", icon or UNKNOWN_ICON)
		set("stacks", 0)
		set("duration", 0)
		set("expirationTime", 0)
		set("unit", unit)
		set("unitName", token and UnitName(token) or nil)
		set("unitCaster", nil)
		set("casterName", nil)
		set("spellId", nil)
		set("dispelName", nil)
		set("filter", nil)
		set("index", nil)
	end

	if curChanged then state.changed = true end
	return curChanged
end

-- One scan of a multi-unit ti: a GUID-keyed clone per current member, and every
-- state whose member has left the family dropped. Unlike the generic system's
-- producers there is no per-unit event to route -- the poll is the drive here,
-- so every tick is a full pass.
-- Overwrites every shown state's matchCount/totalStacks with the family-wide
-- sums, after the per-unit pass wrote each member's own: upstream's two
-- variables are trigger-wide totals, so a "nobody in the group has it" check
-- (matchCount == 0) reads the group, not the one member the clone stands for.
local function applyFamilyTotals(states, total, totalStacks)
	local dirty = false
	for _, state in pairs(states) do
		if state.show then
			if state.matchCount ~= total then
				state.matchCount = total
				state.changed = true
				dirty = true
			end
			if state.totalStacks ~= totalStacks then
				state.totalStacks = totalStacks
				state.changed = true
				dirty = true
			end
		end
	end
	return dirty
end

-- The member callback shares its running totals through upvalues rather than
-- being a fresh closure per scan. Safe for the reason `set` above is: nothing
-- it calls runs user code, so no second family scan can start inside one.
local famTi, famSeen, famDirty, famTotal, famStacks
local function scanFamilyMember(unit, cloneId)
	famSeen[cloneId] = true
	local match = findMatch(famTi, unit)
	if match then
		famTotal = famTotal + (match.count or 1)
		famStacks = famStacks + (match.stacksTotal or 0)
	end
	if updateTriggerInfoState(famTi, unit, cloneId, match) then famDirty = true end
end

-- Drops every non-base state no member claimed this scan. Clearing a field
-- mid-traversal is the one table edit `pairs` permits.
local function dropUnseen(states, seen)
	local dropped = false
	for cloneId in pairs(states) do
		if cloneId ~= "" and not seen[cloneId] then
			states[cloneId] = nil
			dropped = true
		end
	end
	return dropped
end

local function scanMultiUnit(ti)
	local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
	if not states then return false end
	famTi, famSeen, famDirty, famTotal, famStacks = ti, WA.AcquireScratch(), false, 0, 0
	WA.ForEachMultiUnit(ti.multiUnit, scanFamilyMember)
	local seen, dirty, total, totalStacks = famSeen, famDirty, famTotal, famStacks
	famTi, famSeen = nil, nil
	if dropUnseen(states, seen) then dirty = true end
	WA.ReleaseScratch(seen)
	if applyFamilyTotals(states, total, totalStacks) then dirty = true end
	return dirty
end

-- How many clones one multi-target trigger may stand up. A big pull can put
-- more units in range than that, and a display with a state per mob is not what
-- anyone asked for -- the same reason a dynamic group carries a `limit`. GUID
-- order decides who is kept, which is arbitrary but stable, so the survivors do
-- not churn between ticks.
local MULTI_CLONE_LIMIT = 40

-- One scan of a `multi` ti: the tracked GUIDs are the unit list, each read
-- through its GUID token like any other unit, one clone per GUID that carries a
-- match, and every clone whose match has gone dropped -- the same seen/stale
-- sweep scanMultiUnit runs over a family's departed members. A GUID the client
-- no longer resolves (out of range, despawned) leaves the list here.
local function scanMultiGuid(ti)
	local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
	if not states then return false end
	local guids = WA.AcquireScratch()
	for guid in pairs(multiGuids) do
		if UnitExists(guid) then table.insert(guids, guid) else multiGuids[guid] = nil end
	end
	table.sort(guids)
	local seen, dirty, clones = WA.AcquireScratch(), false, 0
	local total, totalStacks = 0, 0
	for i = 1, #guids do
		if clones >= MULTI_CLONE_LIMIT then break end
		local guid = guids[i]
		local match = findMatch(ti, guid)
		if match then
			clones = clones + 1
			seen[guid] = true
			total = total + (match.count or 1)
			totalStacks = totalStacks + (match.stacksTotal or 0)
			if updateTriggerInfoState(ti, guid, guid, match) then dirty = true end
		end
	end
	WA.ReleaseScratch(guids)

	if dropUnseen(states, seen) then dirty = true end
	WA.ReleaseScratch(seen)
	if applyFamilyTotals(states, total, totalStacks) then dirty = true end
	return dirty
end

local function updateDirty(dirty)
	for id in pairs(dirty) do WA.UpdatedTriggerState(id) end
end

local lastScan
local function scanTick()
	WA.ProfBegin("aura scan")
	lastScan = GetTime()
	-- A new generation is what invalidates the pool; its tables are kept.
	scanGen = scanGen + 1
	local dirty
	for _, tis in pairs(scanIndex) do
		for j = 1, #tis do
			local ti = tis[j]
			if not WA.forced[ti.id] then -- a forced leaf's state is owned by the preview
				local changed
				if ti.multiGuid then
					changed = scanMultiGuid(ti)
				elseif ti.multiUnit then
					changed = scanMultiUnit(ti)
				else
					changed = updateTriggerInfoState(ti, ti.unit, "", findMatch(ti, ti.unit))
				end
				if changed then
					dirty = dirty or WA.AcquireScratch()
					dirty[ti.id] = true
				end
			end
		end
	end
	-- Multi-target triggers scan by GUID, so without this the pool would keep a
	-- list for every mob a session ever saw. Kept tokens refill in place; a
	-- dropped unit costs one rebuild if it comes back.
	for unit, gen in pairs(poolSeen) do
		if gen ~= scanGen then
			pool[unit] = nil
			poolSeen[unit] = nil
		end
	end
	if dirty then
		WA.RunRelayoutBatch(updateDirty, dirty)
		WA.ReleaseScratch(dirty)
	end
	WA.ProfEnd("aura scan")
end
TriggerAura.scanTick = scanTick
-- Debug/test accessors: the harness drives a scan without the 0.2s ticker, and
-- reads how many units the pool holds.
WA.AuraScanTick = scanTick
function WA.AuraPoolUnits()
	local n = 0
	for _ in pairs(pool) do n = n + 1 end
	return n
end

WA.RegisterTriggerSystem({ "aura" }, TriggerAura)

-- 0.2s poll is the real drive; UNIT_AURA (unreliable on refresh) and
-- PLAYER_TARGET_CHANGED are just latency nudges, on auraFrame (UNIT_AURA's
-- tokens set by refreshEvents). A unit reachable through two watched tokens fires UNIT_AURA
-- once per token, harmless since scanTick doesn't count fires.
TriggerAura.ticker = C_Timer.NewTicker(0.2, scanTick)

-- Coalesced to one scan per frame: GetTime is frame-locked on this client, so
-- an equal stamp means a scan already ran this frame -- and raid combat
-- delivers UNIT_AURA in same-frame bursts that were each a full rescan. Only
-- the nudge dedupes; a direct scanTick call (LoadDisplays' synchronous
-- re-derive) always runs.
auraFrame:SetScript("OnEvent", function()
	if lastScan ~= GetTime() then scanTick() end
end)
