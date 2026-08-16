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

local MAX_SLOT = 40 -- safe superset of any plausible buff/debuff cap on this client
local memo = {} -- per-tick unit|filter -> aura list; several triggers share one scan

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

-- Stops at the first nil slot: the aura list is a compacting array on this
-- client. Memoized per unit|filter for the tick.
local function scanUnit(unit, filter)
	local key = unit .. "|" .. filter
	local list = memo[key]
	if list then return list end
	list = {}
	for i = 1, MAX_SLOT do
		local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
		if not aura then break end
		list[i] = aura
	end
	memo[key] = list
	return list
end

local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- SpellDispelType.dbc ids 1..4, in the order the Dispel Type selector offers
-- them. C_Spell.GetSpellDispelType answers the id and nothing in Lua maps an id
-- to the localized name the descriptor carries, so this is the bridge for an
-- aura that never reached a descriptor. An id that stopped lining up would cost
-- a filter match, never produce a wrong one.
local DISPEL_TYPES = { "Magic", "Curse", "Disease", "Poison" }

local playerGuid
local function playerGUID()
	if not playerGuid then playerGuid = UnitGUID and UnitGUID("player") end
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
	for i = 1, table.getn(entries) do
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
	for i = 1, table.getn(names) do
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
	if table.getn(entries) == 0 and showOn == "showOnActive" then return nil end
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
	for i = table.getn(list), 1, -1 do
		if list[i] == ti then table.remove(list, i) end
	end
end

-- Compile only: build this display's triggerInfos into perId. Registration into
-- the live scanIndex is deferred to LoadDisplays (§11) -- an unloaded
-- aura is compiled but never scanned for.
function TriggerAura.Add(data)
	TriggerAura.Delete(data.id)
	local list = {}
	perId[data.id] = list
	for triggernum = 1, table.getn(data.triggers) do
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
	for k = 1, table.getn(ids) do
		local id = ids[k]
		local list = perId[id]
		if list and not activeIds[id] then
			activeIds[id] = true
			for i = 1, table.getn(list) do registerTI(list[i]) end
			registered = true
		end
	end
	-- Re-derive current match state synchronously (GenericTrigger does the same via
	-- force_events). WA.Add collapses the region before load, so without this an
	-- already-matching aura would blink hidden until the 0.2s scan ticker's next fire.
	if registered then TriggerAura.scanTick() end
end

-- Unload: pull this display's TIs out of scanIndex (it stops being scanned) but
-- keep them in perId, so a later reload re-registers without recompiling.
function TriggerAura.UnloadDisplays(ids)
	for k = 1, table.getn(ids) do
		local id = ids[k]
		if activeIds[id] then
			activeIds[id] = nil
			local list = perId[id]
			if list then
				for i = 1, table.getn(list) do unregisterTI(list[i]) end
			end
		end
	end
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
	for i = 1, table.getn(list) do list[i].id = newId end
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

-- Condition-variable templates (§5/§10): what this trigger's state exposes
-- to the conditions editor and interpreter. Each key is the state field a check
-- reads; type drives the editor widget and the comparison. `timer` compares
-- against remaining time (expiry - now) with an exact scheduled recheck;
-- `elapsedTimer` against time since a past timestamp -- both are information
-- DoiteAuras needs Nampower events for, falling out of our poll cadence for free.
local AURA_CONDITIONS = {
	stacks = { display = "Stacks", type = "number" },
	name = { display = "Name", type = "string" },
	spellId = { display = "Spell ID", type = "number" },
	duration = { display = "Duration", type = "number" },
	active = { display = "Active", type = "bool" },
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
	-- True for an aura recovered from the overflow cache rather than read off the
	-- descriptor. Reachable so a display can say why it shows no stack count.
	overflow = { display = "Overflow", type = "bool" },
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
	for i = 1, (ignore and table.getn(ignore) or 0) do
		local e = ignore[i]
		if (e.id and aura.spellId == e.id) or (not e.id and aura.name == e.raw) then
			return false
		end
	end
	-- Caster attribution is best-effort here: it comes from ClassicAPI's
	-- SMSG_SPELL_GO cache (SuperWoW GUIDs), so an aura active at login -- or any
	-- aura when the cast packet wasn't observed -- reports no caster at all.
	-- Reject only when we positively know the caster is someone else; an unknown
	-- caster can't be proven foreign, so let it pass rather than hide a
	-- genuinely-own buff.
	--
	-- Test sourceGUID rather than sourceUnit: the GUID is set whenever a caster
	-- is known, while the token is nil for any caster outside token range, which
	-- would read as "unknown" and pass someone else's debuff.
	if ti.ownOnly then
		if aura.sourceGUID ~= nil then
			if not WA.AuraOverflow.SameGuid(aura.sourceGUID, playerGUID()) then return false end
		elseif aura.sourceUnit ~= nil and aura.sourceUnit ~= "player" then
			return false
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

-- ---------------------------------------------------------------------------
-- Overflow fallback. A unit descriptor carries 16 harmful slots and a raid boss
-- carries more; the ones that got no slot are never transmitted, so a HARMFUL
-- miss is not proof of absence. AuraOverflow.lua holds them, recovered from
-- Nampower's aura-cast events, and this is where the miss gets to ask.
-- Upstream has no counterpart -- retail has no aura cap.
-- ---------------------------------------------------------------------------

-- Gate result per unit for the tick. Reconcile costs a descriptor scan and
-- evicts as it goes, so several triggers on one unit must not each run it.
local gateMemo = {}

-- An AuraData-shaped table built from a cache entry, marked so the filters that
-- degrade on it can tell, and so a display can say why.
local function synthesise(cached, spellId)
	local name, _, icon = GetSpellInfo(spellId)
	local duration = cached.duration or 0
	local dispelType = C_Spell and C_Spell.GetSpellDispelType and C_Spell.GetSpellDispelType(spellId)
	return {
		name = cached.name or name,
		icon = icon,
		spellId = spellId,
		-- Only the descriptor counts stacks, so an overflow entry reports the one
		-- application its cast event proves.
		applications = 1,
		duration = duration,
		expirationTime = duration > 0 and (cached.start + duration) or 0,
		dispelName = dispelType and DISPEL_TYPES[dispelType] or nil,
		isHarmful = true,
		isHelpful = false,
		-- Left as a GUID rather than resolved to a unit token: whether an
		-- arbitrary caster's GUID addresses a unit here is not established, and
		-- every Unit* call downstream would inherit the guess. sourceUnit is set
		-- only for the one caster that can be named without one.
		sourceGUID = cached.caster,
		sourceUnit = WA.AuraOverflow.SameGuid(cached.caster, playerGUID()) and "player" or nil,
		overflow = true,
	}
end

local function overflowMatch(ti, unit)
	local AO = WA.AuraOverflow
	if not (AO and AO.Enabled()) then return nil end
	if WA.Options().auraOverflow == false then return nil end

	local harmful = false
	for fi = 1, table.getn(ti.filters) do
		if ti.filters[fi] == "HARMFUL" then harmful = true end
	end
	if not harmful then return nil end

	local guid = UnitGUID and UnitGUID(unit)
	if not guid then return nil end

	local gate = gateMemo[unit]
	if gate == nil then
		gate = AO.Reconcile(unit, guid) and true or false
		gateMemo[unit] = gate
	end
	if not gate then return nil end

	-- Naming the caster is what picks our own copy out of several holding the
	-- same debuff; the longest-remaining one would otherwise answer, and
	-- passesMatch would then reject it and report the aura missing.
	local caster = ti.ownOnly and playerGUID() or nil

	for e = 1, table.getn(ti.entries) do
		local entry = ti.entries[e]
		local cached, spellId
		if entry.id then
			cached, spellId = AO.Get(guid, entry.id, caster), entry.id
		else
			cached, spellId = AO.GetByName(guid, entry.raw, caster)
		end
		if cached then
			local aura = synthesise(cached, spellId)
			if passesMatch(ti, aura) then
				return { aura = aura, filter = "HARMFUL" }
			end
		end
	end
	return nil
end

-- Forward per-ti match: walk this ti's entries in configured (priority) order,
-- each against each of its filters, first passing hit wins. Small n (a
-- handful of entries/filters, <=40 auras per scan) makes this cheaper than
-- maintaining a name+id reverse index for the multi-entry/BOTH-filter case.
local function findMatch(ti, unit)
	for e = 1, table.getn(ti.entries) do
		local entry = ti.entries[e]
		for fi = 1, table.getn(ti.filters) do
			local filter = ti.filters[fi]
			local list = scanUnit(unit, filter)
			for i = 1, table.getn(list) do
				local aura = list[i]
				local ok
				if entry.id then ok = aura.spellId == entry.id
				else ok = aura.name == entry.raw end
				if ok and passesMatch(ti, aura) then
					return { aura = aura, index = i, filter = filter }
				end
			end
		end
	end
	return overflowMatch(ti, unit)
end

-- Writes one state of ti with field-by-field change detection: the base `""`
-- state for a single token, or `cloneId`'s for one member of a multi-unit
-- family. `match` is the matched { aura, index, filter } (or nil). Returns true
-- if any field changed.
local function updateTriggerInfoState(ti, unit, cloneId, match)
	local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
	if not states then return false end

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
	if not UnitExists(unit) and not ti.unitExists then shown = false end

	local state = states[cloneId]

	if not shown then
		if not state or not state.show then return false end
		state.show = false
		state.changed = true
		return true
	end

	if not state then state = {}; states[cloneId] = state end
	local now = GetTime()
	local changed = false
	local function set(k, v)
		if state[k] ~= v then state[k] = v; changed = true end
	end

	-- Timestamp trio, computed before the fields they compare against get
	-- overwritten (§5: refresh = expirationTime jumped > 0.2s).
	if not state.show then
		state.initialTime = now
		state.refreshTime = now
		changed = true
	elseif matched and state.expirationTime and aura.expirationTime
		and (aura.expirationTime - state.expirationTime > 0.2) then
		state.refreshTime = now
		changed = true
	end
	if matched then
		local newStacks = aura.applications or 0
		if state.stacks and newStacks > state.stacks then state.stackGainTime = now; changed = true
		elseif state.stacks and newStacks < state.stacks then state.stackLostTime = now; changed = true end
	end

	set("show", true)
	set("active", matched and true or false)
	set("inRange", (UnitInRange and UnitInRange(unit)) and true or false)

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
		set("unitName", UnitName(unit))
		set("unitCaster", aura.sourceUnit)
		set("casterName", aura.sourceUnit and UnitName(aura.sourceUnit) or nil)
		set("filter", match.filter)
		set("index", match.index)
		set("overflow", aura.overflow and true or false)
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
		set("unitName", UnitName(unit))
		set("unitCaster", nil)
		set("casterName", nil)
		set("spellId", nil)
		set("dispelName", nil)
		set("filter", nil)
		set("index", nil)
		set("overflow", false)
	end

	if changed then state.changed = true end
	return changed
end

-- One scan of a multi-unit ti: a GUID-keyed clone per current member, and every
-- state whose member has left the family dropped. Unlike the generic system's
-- producers there is no per-unit event to route -- the poll is the drive here,
-- so every tick is a full pass.
local function scanMultiUnit(ti)
	local states = WA.GetTriggerStateForTrigger(ti.id, ti.triggernum)
	if not states then return false end
	local seen = {}
	local dirty = false
	WA.ForEachMultiUnit(ti.multiUnit, function(unit, cloneId)
		seen[cloneId] = true
		if updateTriggerInfoState(ti, unit, cloneId, findMatch(ti, unit)) then dirty = true end
	end)
	local stale = {}
	for cloneId in pairs(states) do
		if cloneId ~= "" and not seen[cloneId] then table.insert(stale, cloneId) end
	end
	for i = 1, table.getn(stale) do
		states[stale[i]] = nil
		dirty = true
	end
	return dirty
end

local function scanTick()
	WA.wipe(memo)
	WA.wipe(gateMemo)
	local dirty = {}
	for _, tis in pairs(scanIndex) do
		for j = 1, table.getn(tis) do
			local ti = tis[j]
			if not WA.forced[ti.id] then -- a forced leaf's state is owned by the preview
				local changed
				if ti.multiUnit then
					changed = scanMultiUnit(ti)
				else
					changed = updateTriggerInfoState(ti, ti.unit, "", findMatch(ti, ti.unit))
				end
				if changed then dirty[ti.id] = true end
			end
		end
	end
	for id in pairs(dirty) do WA.UpdatedTriggerState(id) end
end
TriggerAura.scanTick = scanTick
-- Debug/test accessor: the harness drives a scan without the 0.2s ticker.
WA.AuraScanTick = scanTick

WA.RegisterTriggerSystem({ "aura" }, TriggerAura)

-- 0.2s poll is the real drive; UNIT_AURA (unreliable on refresh) and
-- PLAYER_TARGET_CHANGED are just latency nudges. UNIT_AURA is deliberately
-- unfiltered by arg1 -- it double-fires under two addressing schemes here,
-- harmless since scanTick doesn't count fires.
TriggerAura.ticker = C_Timer.NewTicker(0.2, scanTick)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:SetScript("OnEvent", function() scanTick() end)
