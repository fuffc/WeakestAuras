-- WeakestAuras -- the overflow cache: harmful auras recovered from Nampower's
-- aura-cast events, so a debuff the unit descriptor's 16 harmful slots could not
-- carry is still knowable. No upstream counterpart -- retail has no aura cap.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

WA.AuraOverflow = {}
local AO = WA.AuraOverflow

local AURA_CAST_CVAR = "NP_EnableAuraCastEvents"
local AURA_CAST_MIN = "2.20.0"
local DEDUPE_WINDOW = 0.1
local NULL_GUID = "0x0000000000000000"
local HARMFUL_SLOTS = 16
local EVICT_GRACE = 2
local SWEEP_INTERVAL = 5
local UNKNOWN_MAX_AGE = 120

-- [targetGuid][spellId][casterKey] = { spellId, caster, start, duration, name, cap }
--
-- The caster is part of the key because it is part of the aura's identity: two
-- casters of one debuff are two auras holding two of the unit's slots, and one
-- entry per (target, spell) would let the second cast overwrite the first's
-- duration and let either one's removal retire both.
local store = {}
local enabled = false

local UNKNOWN_CASTER = "?"

function AO.Enabled() return enabled end

-- GUIDs reach this addon from two sources that need not agree on hex case: the
-- client's UnitGUID and Nampower's event payload.
function AO.SameGuid(a, b)
	if not a or not b then return false end
	return string.lower(tostring(a)) == string.lower(tostring(b))
end

-- Keys are case-folded for the same reason SameGuid folds: a lookup by
-- UnitGUID has to reach an entry written from a Nampower payload.
local function casterKey(guid)
	if not guid or guid == "" then return UNKNOWN_CASTER end
	return string.lower(tostring(guid))
end

-- A zero duration means Nampower carried none, not that the aura is already
-- over, so those are never expired on the clock -- the trust gate, a death and
-- the sweep's own age bound are what reclaim them.
local function expired(entry, now)
	return entry.duration > 0 and (entry.start + entry.duration) <= now
end

-- The harmful descriptor as a count and a spellId set. 16 is the whole range and
-- slot 17 is nil on every unit, always, so this never scans past it. nil when
-- the token is not addressable at all.
local function harmfulSnapshot(unit)
	local count, present = 0, {}
	local ok = pcall(function()
		for i = 1, HARMFUL_SLOTS do
			local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
			if aura then
				count = count + 1
				if aura.spellId then present[aura.spellId] = true end
			end
		end
	end)
	if not ok then return nil end
	return count, present
end

-- Aura-cast events arrive with Nampower 2.20. Below that, or with no Nampower at
-- all, nothing here registers and every query answers nil, which leaves the
-- descriptor the only aura source exactly as it was. Asked through the shared
-- gate so the refusal shows up in the options footer's mod list.
local function nampowerReady()
	return WA.RequireNampower(AURA_CAST_MIN, "debuff overflow recovery (aura-cast events)")
end

-- Nampower sends no aura-cast event at all while this reads 0, so the cache has
-- to turn it on to be fed. pfUI sets the same CVar when it is loaded, which
-- makes this a repeat rather than a fight over it.
local function enableEvents()
	if type(SetCVar) == "function" then pcall(SetCVar, AURA_CAST_CVAR, "1") end
end

-- arg1 spellId, arg2 casterGuid, arg3 targetGuid, arg4 effect,
-- arg5 effectAuraName (a numeric aura type, not a name), arg6 effectAmplitude,
-- arg7 effectMiscValue, arg8 durationMs, arg9 auraCapStatus.
local function record()
	local spellId, casterGuid, targetGuid = arg1, arg2, arg3
	local durationMs, capStatus = arg8, arg9
	if not spellId or not targetGuid then return end
	if targetGuid == "" or targetGuid == NULL_GUID then return end

	-- Helpful auras land through the same two events and are kept with a marker
	-- rather than dropped. The overflow reader asks for harmful ones only -- the
	-- helpful range is 32 slots and has not been seen to overflow -- but a
	-- multi-target trigger's subject is any unit at all, buffs included, and this
	-- store is the only place an aura on a unit nobody is targeting is knowable.
	-- A client whose ClassicAPI predates the classifier calls everything harmful,
	-- which is what every reader here assumed of the whole cache anyway.
	local harmful = true
	if C_Spell and C_Spell.IsSpellHarmful then
		harmful = C_Spell.IsSpellHarmful(spellId) and true or false
	end

	local now = GetTime()
	local unitStore = store[targetGuid]
	if not unitStore then
		unitStore = {}
		store[targetGuid] = unitStore
	end
	local byCaster = unitStore[spellId]
	if not byCaster then
		byCaster = {}
		unitStore[spellId] = byCaster
	end

	-- One event fires per spell *effect*, so a multi-effect spell arrives two or
	-- three times within a frame, every copy describing the same application.
	-- Keeping the first is what pfUI's AURA_CAST_DEDUPE_WINDOW does; a later
	-- copy's amplitude and misc value belong to a different effect of the same
	-- aura, not to a newer cast.
	local key = casterKey(casterGuid)
	local prev = byCaster[key]
	if prev and (now - prev.start) < DEDUPE_WINDOW then return end

	byCaster[key] = {
		spellId = spellId,
		caster = casterGuid,
		start = now,
		duration = (tonumber(durationMs) or 0) / 1000,
		name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellId)) or nil,
		cap = tonumber(capStatus) or 0,
		harmful = harmful,
	}
end

-- auraCapStatus bit 2: the server's own statement that the aura got no visible
-- slot, rather than an inference drawn from a full descriptor. Bit 1 is the buff
-- bar's, recorded and unread.
local function wasCapped(entry)
	if not entry then return false end
	return math.mod(math.floor((entry.cap or 0) / 2), 2) == 1
end
AO.WasCapped = wasCapped

-- Remaining time, with an unknown duration ranking below anything still
-- running -- and still the answer when it is the only candidate.
local function remaining(entry, now)
	if entry.duration > 0 then return (entry.start + entry.duration) - now end
	return 0
end

-- The best of the live instances `pick` accepts, over every cached spellId on
-- the unit. "Best" is longest-remaining, which is what the ranks of one spell
-- and two casters' copies of it come down to in practice -- without the
-- maintained downrank and variant tables that would otherwise be needed to
-- choose between them. Expired entries are dropped as they are walked, so a
-- query is also what keeps the unit's table honest.
local function best(guid, pick)
	local unitStore = store[guid]
	if not unitStore then return nil end
	local now = GetTime()
	local found, foundRemain
	for spellId, byCaster in pairs(unitStore) do
		for key, entry in pairs(byCaster) do
			if expired(entry, now) then
				byCaster[key] = nil
			elseif pick(entry, spellId) then
				local remain = remaining(entry, now)
				if not found or remain > foundRemain then
					found, foundRemain = entry, remain
				end
			end
		end
	end
	return found
end

-- The cached instance of `spellId` on `guid`. `caster` names one, which is the
-- only way to ask for a specific player's copy when several hold the same
-- debuff; without it the longest-remaining instance answers.
function AO.Get(guid, spellId, caster)
	if not enabled or not guid then return nil end
	local id = tonumber(spellId) or spellId
	local wanted = caster and casterKey(caster)
	local entry = best(guid, function(e, sid)
		if sid ~= id then return false end
		return not wanted or casterKey(e.caster) == wanted
	end)
	return entry
end

-- As Get, matched on the aura's name rather than a spellId -- so it spans the
-- ranks of one spell as well as its casters. Returns the entry and its spellId.
function AO.GetByName(guid, name, caster)
	if not enabled or not guid or not name then return nil end
	local wanted = caster and casterKey(caster)
	local entry = best(guid, function(e)
		if e.name ~= name then return false end
		return not wanted or casterKey(e.caster) == wanted
	end)
	if not entry then return nil end
	return entry, entry.spellId
end

-- Every GUID with something cached, in no order, as a snapshot the caller may
-- walk while queries evict from under it.
--
-- Deliberately ungated, which is the whole difference between this and
-- Reconcile below: that gate answers "is the descriptor full", the question
-- overflow *recovery* has to ask before it may believe the cache over a unit it
-- can address. A multi-target trigger's subject is the opposite case -- a unit
-- carrying one aura that nobody is looking at -- so it takes the store as it is
-- and leaves reconciliation to the units that do have a token.
function AO.TrackedGuids()
	local out = {}
	if not enabled then return out end
	for guid in pairs(store) do table.insert(out, guid) end
	return out
end

-- Every live entry on the unit, flat, each carrying its own spellId and caster.
-- nil when the unit has nothing cached at all.
function AO.EntriesFor(guid)
	if not enabled or not guid then return nil end
	local unitStore = store[guid]
	if not unitStore then return nil end
	local out = {}
	for _, byCaster in pairs(unitStore) do
		for _, entry in pairs(byCaster) do table.insert(out, entry) end
	end
	if table.getn(out) == 0 then return nil end
	return out
end

-- The trust gate, and the reconciliation that comes with it. It governs the
-- overflow reader -- the one that has a unit token and could have read the
-- descriptor instead (TrackedGuids above is the reader that has neither). An
-- overflow entry may only ever be surfaced for a unit whose harmful descriptor
-- is *full*:
-- below 16 the descriptor is the whole truth, so an entry the descriptor does
-- not carry is stale by definition and goes. That is what keeps the common case
-- self-correcting -- as a unit's debuff count falls the cache is reconciled
-- against truth instead of accumulating ghosts.
--
-- Entries younger than the grace window are exempt from the absence rule, since
-- the cast event arrives before the descriptor update and a fresh entry would
-- otherwise evict itself the instant it landed.
--
-- So is an entry the server flagged as capped. That one never had a slot, so its
-- absence from the descriptor is expected rather than evidence, and retiring it
-- on a bar that has since dropped below 16 would assume the server promotes a
-- slotless aura into a freed slot -- which is not established. An entry that did
-- get a slot is still retired by its absence.
--
-- Returns whether the gate passes, and the descriptor's harmful count.
function AO.Reconcile(unit, guid)
	if not enabled or not unit or not guid then return false, nil end
	local count, present = harmfulSnapshot(unit)
	if not count then return false, nil end
	local unitStore = store[guid]
	if unitStore then
		local now = GetTime()
		local live = false
		for spellId, byCaster in pairs(unitStore) do
			local anyCaster = false
			for key, entry in pairs(byCaster) do
				local drop = expired(entry, now)
				-- The snapshot is the harmful range, so a helpful entry's absence
				-- from it is not evidence of anything.
				if not drop and entry.harmful ~= false and count < HARMFUL_SLOTS
					and not present[spellId]
					and not wasCapped(entry)
					and (now - entry.start) >= EVICT_GRACE then
					drop = true
				end
				if drop then byCaster[key] = nil else anyCaster = true end
			end
			if anyCaster then live = true else unitStore[spellId] = nil end
		end
		if not live then store[guid] = nil end
	end
	return count >= HARMFUL_SLOTS, count
end

-- Reclaims what no query will reach: a unit nobody is looking at still collects
-- entries, and an entry whose duration never arrived cannot expire on its own.
function AO.Sweep()
	local now = GetTime()
	for guid, unitStore in pairs(store) do
		local live = false
		for spellId, byCaster in pairs(unitStore) do
			local anyCaster = false
			for key, entry in pairs(byCaster) do
				if expired(entry, now)
					or (entry.duration <= 0 and (now - entry.start) > UNKNOWN_MAX_AGE) then
					byCaster[key] = nil
				else
					anyCaster = true
				end
			end
			if anyCaster then live = true else unitStore[spellId] = nil end
		end
		if not live then store[guid] = nil end
	end
end

-- A death ends every aura on the unit at once, and nothing else reports it.
local function onUnitDied()
	if arg1 then store[arg1] = nil end
end

-- arg1 guid, arg2 display slot, arg3 spellId. Covers an overflow aura that had
-- been promoted into a visible slot and then removed from it: the removal is
-- reported for the slot, and the cached copy has to go with it.
--
-- The payload names no caster, so with several holding the same debuff there is
-- nothing to say whose copy fell off. Retiring all of them would drop live
-- auras; the survivors are left to the reconcile pass and their own clocks.
local function onDebuffRemoved()
	local unitStore = arg1 and store[arg1]
	local byCaster = unitStore and arg3 and unitStore[arg3]
	if not byCaster then return end
	local n, only = 0
	for key in pairs(byCaster) do n = n + 1; only = key end
	if n == 1 then
		byCaster[only] = nil
		unitStore[arg3] = nil
	end
end

if nampowerReady() then
	enabled = true
	enableEvents()

	local frame = CreateFrame("Frame")
	frame:RegisterEvent("AURA_CAST_ON_SELF")
	frame:RegisterEvent("AURA_CAST_ON_OTHER")
	frame:RegisterEvent("DEBUFF_REMOVED_SELF")
	frame:RegisterEvent("DEBUFF_REMOVED_OTHER")
	frame:RegisterEvent("UNIT_DIED")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:SetScript("OnEvent", function()
		if event == "PLAYER_ENTERING_WORLD" then
			enableEvents()
		elseif event == "UNIT_DIED" then
			WA.safecall("AuraOverflow", onUnitDied)
		elseif event == "DEBUFF_REMOVED_SELF" or event == "DEBUFF_REMOVED_OTHER" then
			WA.safecall("AuraOverflow", onDebuffRemoved)
		else
			WA.safecall("AuraOverflow", record)
		end
	end)

	C_Timer.NewTicker(SWEEP_INTERVAL, AO.Sweep)
end
