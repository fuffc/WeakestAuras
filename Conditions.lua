-- WeakestAuras -- conditions: trigger-state-driven display overrides ("if
-- trigger state says X, change display property Y"). Mirrors WA2's Conditions
-- (§10), with one deliberate divergence:
-- upstream compiles the whole list to one loadstring'd function per aura; we
-- *interpret* the same descriptor data. At tens of auras the interpreter is
-- plenty fast, and with no offline Lua a generated-code bug would be an in-game
-- string-assembly hunt -- an interpreter's stack traces point at real lines.
-- The descriptor format and the three-phase algorithm are upstream's exactly,
-- so a compiler can replace the interpreter later without touching saved data.
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- The data (per condition): { check = { trigger, variable, op, value, checks },
-- changes = { { property, value }, ... } }. trigger -1 = a global condition,
-- -2 = an AND/OR combinator over check.checks. Everything meets the rest of the
-- engine at region.states (what to read) and the region/subregion property
-- setters (what to write) -- the same setters config-apply already calls.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- compiled[uid] = { data, properties (WA.GetProperties map), templates
-- ([triggernum] = condition-variable map), customChecks (source -> compiled
-- function, or false where it would not compile) }. Rebuilt on every WA.Add via
-- WA.LoadConditions; keyed by uid (stable across rename) so a rename needs no
-- fixup here.
local compiled = {}
-- activated[uid][cloneId][i] = was condition i active on the previous run --
-- drives deactivation restore (a condition that turned off restores its
-- properties' saved base values) and, later, edge-triggered actions.
local activated = {}
-- scheduled[uid.."\0"..cloneId] = the one pending exact-recheck C_Timer for a
-- timer/elapsedTimer check crossing its threshold (§10 ScheduleConditionCheck).
-- scheduledFlip/scheduledRegion record what that timer was armed for, so a run
-- that arrives at the same threshold keeps it instead of re-arming.
local scheduled, scheduledFlip, scheduledRegion = {}, {}, {}

-- ---------------------------------------------------------------------------
-- Global conditions (trigger == -1): a shared pseudo-state re-checked on the
-- events below. All three APIs exist on 1.12.
-- ---------------------------------------------------------------------------

WA.globalConditions = {
	incombat = { display = "In Combat", type = "bool",
		get = function() return UnitAffectingCombat("player") and true or false end },
	hastarget = { display = "Has Target", type = "bool",
		get = function() return UnitExists("target") and true or false end },
	attackabletarget = { display = "Target Attackable", type = "bool",
		get = function() return (UnitExists("target") and UnitCanAttack("player", "target")) and true or false end },
	-- Its own type rather than a bool that happens to return true: the check
	-- carries no operator and no value, so anything comparing them would read
	-- an absent value as false and invert the one condition that cannot fail.
	alwaystrue = { display = "Always True", type = "alwaystrue",
		get = function() return true end },
	-- The only route from an aura's `config` into a condition, and the reason it
	-- carries no `get`: the answer comes from running the author's Lua inside the
	-- aura environment, not from reading a shared state. `check.value` holds that
	-- source and `check.op` the whitespace-separated list of extra events it
	-- re-evaluates on.
	customcheck = { display = "Custom Check", type = "customcheck" },
}
local GLOBAL_EVENTS = { "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_TARGET_CHANGED" }

-- ---------------------------------------------------------------------------
-- Custom Check: compilation and its dynamic events (§10)
-- ---------------------------------------------------------------------------

-- [event] = { [uid] = true } -- which auras re-evaluate when a named event
-- fires. The events are the author's, so the set is unbounded and cannot live on
-- GLOBAL_EVENTS' fixed list.
local customCheckEvents = {}

-- Walks one check tree, compiling every Custom Check's source and collecting the
-- events they ask for. Compiled per WA.Add and cached on the aura's entry keyed
-- by the source itself, so two conditions sharing a snippet share one function
-- and no evaluation ever reaches loadstring. A source that fails to compile
-- caches `false`, which both stops the retry and answers the check false.
local function collectCustomChecks(check, entry, events, label)
	if type(check) ~= "table" then return end
	if check.trigger == -2 then
		local subs = check.checks or {}
		for i = 1, #subs do collectCustomChecks(subs[i], entry, events, label) end
		return
	end
	if check.trigger ~= -1 or check.variable ~= "customcheck" then return end
	local source = check.value
	if type(source) == "string" and source ~= "" and entry.customChecks[source] == nil then
		entry.customChecks[source] = WA.LoadFunction(source, label) or false
	end
	if type(check.op) == "string" then
		for event in string.gmatch(check.op, "[%w_:]+") do events[event] = true end
	end
end

-- This aura's event registrations replaced wholesale, so a check that dropped an
-- event stops waking on it. Registration rides the trigger system's frame: a
-- frame of our own registered for the same name would deliver it twice.
local function setCustomCheckEvents(uid, events)
	for _, listeners in pairs(customCheckEvents) do listeners[uid] = nil end
	for event in pairs(events) do
		customCheckEvents[event] = customCheckEvents[event] or {}
		customCheckEvents[event][uid] = true
		if WA.EnsureGameEventRegistered then WA.EnsureGameEventRegistered(event) end
	end
end

-- ---------------------------------------------------------------------------
-- Vocabulary: changeable properties + checkable variables
-- ---------------------------------------------------------------------------

-- The overridable properties for a display: the region type's own registry
-- (already carrying the AddProperties universals) plus each subtext's, keyed
-- sub.<n>.<key>. Normalized into one flat shape so the apply/base code and the
-- editor both read the same entries (§10 Private.GetProperties).
function WA.GetProperties(data)
	local out = {}
	local rt = WA.regionTypes[data.regionType]
	if rt and rt.properties then
		for key, spec in pairs(rt.properties) do
			out[key] = { display = spec.display or key, setter = spec.setter, action = spec.action, type = spec.type,
				min = spec.min, max = spec.max, softMin = spec.softMin, softMax = spec.softMax, step = spec.step, values = spec.values,
				base = spec.base, baseIndex = spec.baseIndex, dataKey = spec.dataKey or key }
		end
	end
	local subs = data.subRegions or {}
	local perType = {}
	for i = 1, #subs do
		local sspec = WA.subRegionTypes[subs[i].type]
		perType[subs[i].type] = (perType[subs[i].type] or 0) + 1
		if sspec and sspec.properties then
			-- Same label the Display Effects list gives the block this targets, so
			-- the two pages name one element the same way -- which means counting
			-- per type here too, not by list position. The position is still what
			-- the key `sub.<i>.<key>` addresses it by.
			local label = (sspec.displayName or subs[i].type) .. " " .. perType[subs[i].type] .. " "
			for key, pspec in pairs(sspec.properties) do
				out["sub." .. i .. "." .. key] = { display = label .. (pspec.display or key),
					setter = pspec.setter, action = pspec.action, type = pspec.type, min = pspec.min, max = pspec.max,
					softMin = pspec.softMin, softMax = pspec.softMax, step = pspec.step, values = pspec.values, base = pspec.base, baseIndex = pspec.baseIndex,
					isSub = true, subIndex = i, subKey = pspec.dataKey or key }
			end
		end
	end
	return out
end

-- Whether the trigger is currently active. Every state carries `show`, whatever
-- system produced it, so the variable is added over each system's own table
-- rather than repeated inside all three -- which is where upstream puts it too.
local SHOW_TEMPLATE = { display = "Active", type = "bool" }

-- The checkable variable templates per trigger (§10): each trigger system's
-- GetTriggerConditions. [triggernum] = { variable = { display, type, values } }.
function WA.GetConditionTemplates(data)
	local out = {}
	-- A group carries no triggers at all (MergeDefaults clears them), and its
	-- options window still reaches here for the conditions tab.
	for triggernum = 1, #(data.triggers or {}) do
		local system = WA.GetTriggerSystem(data, triggernum)
		local base = system and system.GetTriggerConditions
			and system.GetTriggerConditions(data, triggernum) or {}
		-- A system's table is shared across every display using that system --
		-- TriggerAura returns one file-local constant -- so `show` goes onto a
		-- copy. Writing into it would leak this display's entry into all of them.
		local templates = {}
		for name, template in pairs(base) do templates[name] = template end
		templates.show = SHOW_TEMPLATE
		out[triggernum] = templates
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Property read/write (the same setters config-apply uses, §6/§10)
-- ---------------------------------------------------------------------------

-- The saved base value a deactivated condition restores -- the config is the
-- source of truth, never a snapshot of live widget state (§10 GetBaseProperty).
local function getBase(data, entry)
	if entry.isSub then
		local sub = data.subRegions and data.subRegions[entry.subIndex]
		local value = sub and sub[entry.subKey]
		if entry.baseIndex and type(value) == "table" then return value[entry.baseIndex] end
		return value
	end
	if entry.base ~= nil then return entry.base end
	local value = data[entry.dataKey]
	if entry.baseIndex and type(value) == "table" then return value[entry.baseIndex] end
	return value
end

local function applyProperty(region, entry, value)
	local target = region
	if entry.isSub then
		target = region.subRegions and region.subRegions[entry.subIndex]
	end
	if not target or not entry.setter or not target[entry.setter] then return end
	-- A number setter does arithmetic on what it is handed, so a nil takes the
	-- aura down. Two things produce one: a change the author never filled in, and
	-- a deactivating condition restoring a property that has no base to restore
	-- to. Leaving the property where it stands beats erroring in a paint.
	if value == nil and entry.type == "number" then return end
	if entry.type == "color" then
		local c = value or { 1, 1, 1, 1 }
		target[entry.setter](target, c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1)
	else
		target[entry.setter](target, value)
	end
end

-- ---------------------------------------------------------------------------
-- Evaluation
-- ---------------------------------------------------------------------------

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

local function compareValue(vtype, op, actual, value)
	op = op or "=="
	if vtype == "number" then
		return numCmp(op, tonumber(actual), tonumber(value))
	elseif vtype == "bool" then
		local a = actual and true or false
		local b = (value == true or value == "true" or value == 1 or value == "1")
		if op == "~=" then return a ~= b end
		return a == b
	else -- string / select
		if op == "~=" then return tostring(actual) ~= tostring(value) end
		return tostring(actual) == tostring(value)
	end
end

-- The compiled Custom Check for this check, run inside the aura environment so
-- `aura_env.config` is what the author's `return aura_env.config.foo` reads.
-- Nothing else in this file needs the environment, so the push/pop is here
-- rather than around the whole run, where upstream puts its equivalent -- a
-- compiled condition function is one call, and there is nowhere cheaper inside
-- it to draw the line.
local function runCustomCheck(entry, check, region)
	local fn = entry.customChecks and entry.customChecks[check.value or ""]
	if not fn then return false end
	local who = region or entry.data.id
	local ok, res = WA.RunAuraFunc(who, entry.data.id .. ": custom check", fn, region and region.state)
	return (ok and res) and true or false
end

-- Returns (active, nextFlip): active is this check's boolean now; nextFlip is
-- the soonest future time a timer/elapsedTimer sub-result would change (or nil),
-- so the caller can schedule an exact recheck instead of polling.
local function evalCheck(check, states, entry, now, region)
	local trig = check.trigger
	if trig == -2 then
		-- AND/OR combinator over nested checks.
		local subs = check.checks or {}
		local isOr = check.variable == "OR"
		local res = not isOr -- AND starts true, OR starts false
		local nextFlip
		for i = 1, #subs do
			local r, f = evalCheck(subs[i], states, entry, now, region)
			if isOr then if r then res = true end
			else if not r then res = false end end
			if f and (not nextFlip or f < nextFlip) then nextFlip = f end
		end
		return res, nextFlip
	elseif trig == -1 then
		local g = WA.globalConditions[check.variable]
		if not g then return false end
		if g.type == "alwaystrue" then return true end
		if g.type == "customcheck" then return runCustomCheck(entry, check, region) end
		return compareValue("bool", check.op, g.get(), check.value)
	else
		local state = states[trig]
		local tmpl = entry.templates[trig] and entry.templates[trig][check.variable]
		if not tmpl then return false end
		if not state then
			-- A trigger that has never produced a state has nothing to read a
			-- variable off, so every check over it is false -- except `show`,
			-- which that absence answers: the trigger is not active. Without
			-- this, "trigger 2 is inactive" stays dark until trigger 2 first
			-- fires, which is the wrong way round for a "missing buff" display.
			if check.variable ~= "show" then return false end
			return compareValue("bool", check.op, false, check.value)
		end
		local vtype = tmpl.type
		if vtype == "timer" then
			-- state[variable] holds an absolute expiration; compare *remaining*.
			-- A fallback/missing state carries 0 here -- treat as "no timer" so a
			-- "remaining < N" check doesn't read the huge negative remaining as true.
			local expiry = state[check.variable]
			if not expiry or expiry <= 0 then return false end
			local target = tonumber(check.value) or 0
			local cur = numCmp(check.op, expiry - now, target)
			local flip = expiry - target -- remaining == target at this instant
			return cur, (flip > now and flip or nil)
		elseif vtype == "elapsedTimer" then
			-- state[variable] holds an absolute past timestamp; compare *elapsed*.
			local base = state[check.variable]
			if not base or base <= 0 then return false end
			local target = tonumber(check.value) or 0
			local cur = numCmp(check.op, now - base, target)
			local flip = base + target -- elapsed == target at this instant
			return cur, (flip > now and flip or nil)
		else
			return compareValue(vtype, check.op, state[check.variable], check.value)
		end
	end
end

-- ---------------------------------------------------------------------------
-- The run + recheck scheduling
-- ---------------------------------------------------------------------------

local function getActivated(uid, cloneId)
	activated[uid] = activated[uid] or {}
	activated[uid][cloneId] = activated[uid][cloneId] or {}
	return activated[uid][cloneId]
end

local runFor -- forward decl: scheduleRecheck's timer closure re-enters it.

local function cancelRecheck(key)
	local timer = scheduled[key]
	if timer then timer:Cancel() end
	scheduled[key], scheduledFlip[key], scheduledRegion[key] = nil, nil, nil
end

local function scheduleRecheck(region, uid, cloneId, nextFlip, now)
	-- Cached on the frame: this runs on every state change of every region with
	-- conditions, and the concatenation was a fresh string each time.
	local key = region.conditionKey
	if region.conditionKeyUid ~= uid or region.conditionKeyClone ~= cloneId then
		key = uid .. "\0" .. cloneId
		region.conditionKey, region.conditionKeyUid, region.conditionKeyClone = key, uid, cloneId
	end
	if not (nextFlip and region.toShow) then
		if scheduled[key] then cancelRecheck(key) end
		return
	end
	if scheduled[key] and scheduledFlip[key] == nextFlip and scheduledRegion[key] == region then return end
	cancelRecheck(key)
	-- Small epsilon so the boundary has actually passed when we re-evaluate
	-- (a strict "<" wouldn't flip at exactly the threshold instant).
	local delay = (nextFlip - now) + 0.05
	if delay < 0.05 then delay = 0.05 end
	scheduled[key] = C_Timer.NewTimer(delay, function()
		scheduled[key], scheduledFlip[key], scheduledRegion[key] = nil, nil, nil
		if region.toShow then runFor(region, uid, false) end
	end)
	scheduledFlip[key], scheduledRegion[key] = nextFlip, region
end

runFor = function(region, uid, hideRegion)
	local entry = compiled[uid]
	if not entry then return end
	local data = entry.data
	local conditions = data.conditions or {}
	local nConds = #conditions
	local cloneId = region.cloneId or ""
	local now = GetTime()

	if nConds == 0 then
		scheduleRecheck(region, uid, cloneId, nil, now)
		return
	end

	local states = region.states or {}
	local prev = getActivated(uid, cloneId)

	-- Phase 1: evaluate every condition, collecting the earliest timer flip.
	-- The three working sets are pooled scratch: this runs on every state change
	-- of every region with conditions. A custom check can re-enter dispatch, so
	-- each run takes its own tables rather than sharing file-level ones.
	local newActive = WA.AcquireScratch()
	local nextFlip
	for i = 1, nConds do
		local active, flip
		if hideRegion then
			active = false
		else
			active, flip = evalCheck(conditions[i].check, states, entry, now, region)
		end
		newActive[i] = active and true or false
		if flip and (not nextFlip or flip < nextFlip) then nextFlip = flip end
	end

	-- Phase 2 (deactivation): conditions active before but not now write their
	-- properties' base values. Phase 3 (activation): active conditions write
	-- their change values, later conditions overwriting earlier -- so a
	-- contested property goes to the last matching condition, and a property no
	-- active condition touches is restored. changeEntry/changeValue hold one
	-- entry per touched property; applied once each afterwards (no mid-run
	-- flicker, §10).
	local changeEntry, changeValue = WA.AcquireScratch(), WA.AcquireScratch()
	for i = 1, nConds do
		if prev[i] and not newActive[i] then
			local changes = conditions[i].changes or {}
			for c = 1, #changes do
				local prop = changes[c].property
				local pentry = prop and entry.properties[prop]
				if pentry and not pentry.action then
					changeEntry[prop], changeValue[prop] = pentry, getBase(data, pentry)
				elseif pentry and pentry.action == "SoundPlay"
					and type(changes[c].value) == "table"
					and changes[c].value.sound_type == "Loop" then
					local target = region
					if pentry.isSub then target = region.subRegions and region.subRegions[pentry.subIndex] end
					if target and target.SoundRepeatStop then target:SoundRepeatStop() end
				end
			end
		end
	end
	for i = 1, nConds do
		if newActive[i] then
			local changes = conditions[i].changes or {}
			for c = 1, #changes do
				local prop = changes[c].property
				local pentry = prop and entry.properties[prop]
				if pentry and pentry.action then
					if not prev[i] then
						local target = region
						if pentry.isSub then target = region.subRegions and region.subRegions[pentry.subIndex] end
						if target and target[pentry.action] then
							local value = changes[c].value
							if pentry.type == "customcode" and type(value) == "string" then
								value = WA.LoadFunction(value, uid .. ": condition custom code", true)
							end
							if pentry.type == "sound" then
								target[pentry.action](target, value)
							elseif pentry.type == "chat" then
								target[pentry.action](target, value)
							else
								target[pentry.action](target, value)
							end
						end
					end
				elseif pentry then
					changeEntry[prop], changeValue[prop] = pentry, changes[c].value
				end
			end
		end
	end
	for prop, pentry in pairs(changeEntry) do
		applyProperty(region, pentry, changeValue[prop])
	end

	for i = 1, nConds do prev[i] = newActive[i] end
	WA.ReleaseScratch(newActive)
	WA.ReleaseScratch(changeEntry)
	WA.ReleaseScratch(changeValue)
	scheduleRecheck(region, uid, cloneId, hideRegion and nil or nextFlip, now)
end

-- ---------------------------------------------------------------------------
-- Hooks the state machine calls (overriding Data.lua's no-op stubs). The
-- StateMachine looks these WA.* names up at call time, so overriding here --
-- loaded after StateMachine, before AddAllDisplays -- is enough.
-- ---------------------------------------------------------------------------

WA.RunConditions = function(region, uid, hideRegion)
	if not uid then return end
	WA.safecall(uid, runFor, region, uid, hideRegion)
end

function WA.ReleaseConditionsForClone(uid, cloneId)
	if not uid then return end
	local byClone = activated[uid]
	if byClone then byClone[cloneId] = nil end
	cancelRecheck(uid .. "\0" .. cloneId)
end

function WA.LoadConditions(data)
	if WA.IsGroup(data) then return end
	local uid = data.uid
	local entry = {
		data = data,
		properties = WA.GetProperties(data),
		templates = WA.GetConditionTemplates(data),
		customChecks = {},
	}
	compiled[uid] = entry
	local events = {}
	local conditions = data.conditions or {}
	for i = 1, #conditions do
		collectCustomChecks(conditions[i].check, entry, events,
			tostring(data.id) .. ": condition " .. i .. " custom check")
	end
	setCustomCheckEvents(uid, events)
	-- Forget prior activation so a recompiled aura re-evaluates from scratch
	-- (its regions get re-applied by the WA.Add that called us).
	activated[uid] = nil
end

function WA.UnloadConditions(data)
	local uid = data.uid
	compiled[uid] = nil
	activated[uid] = nil
	setCustomCheckEvents(uid, {})
	for key in pairs(scheduled) do
		local sep = string.find(key, "\0", 1, true)
		if sep and string.sub(key, 1, sep - 1) == uid then cancelRecheck(key) end
	end
end

-- Read-only debug view (Debug.lua's /wa conditions): per-clone activation flags
-- and whether an exact recheck is pending.
function WA.GetConditionDebug(uid)
	local pending = {}
	for key in pairs(scheduled) do
		local sep = string.find(key, "\0", 1, true)
		if sep and string.sub(key, 1, sep - 1) == uid then
			table.insert(pending, string.sub(key, sep + 1))
		end
	end
	return compiled[uid], activated[uid], pending
end

-- ---------------------------------------------------------------------------
-- Global-condition events: re-run every shown region's conditions on a combat/
-- target change. Cheap at this scale, so it runs unconditionally rather than
-- tracking which auras actually use a global condition (§10 dynamic events).
-- ---------------------------------------------------------------------------

local function rerunShown(region, id)
	if region.toShow then
		local data = WeakestAurasDB.displays[id]
		if data and data.uid then WA.RunConditions(region, data.uid, false) end
	end
end

local globalFrame = CreateFrame("Frame")
for i = 1, #GLOBAL_EVENTS do globalFrame:RegisterEvent(GLOBAL_EVENTS[i]) end
globalFrame:SetScript("OnEvent", function()
	if not WA.ForEachRegion then return end
	WA.ForEachRegion(rerunShown)
end)

-- ---------------------------------------------------------------------------
-- Custom Check events: only the auras that named an event, and only their shown
-- clones. Narrower than the global sweep above on purpose -- an author is free
-- to list a high-rate event, and a fixed list of three cannot be.
--
-- Delivered by wrapping WA.ScanEvents rather than by a frame of our own: that
-- is where the trigger system already funnels both game events and its internal
-- WA_* ones, so listing either kind in a check works and neither arrives twice.
-- ---------------------------------------------------------------------------

local function rerunConditions(uid)
	local entry = compiled[uid]
	if not entry or not WA.ForEachClone then return end
	WA.ForEachClone(entry.data.id, function(region)
		if region.toShow then WA.RunConditions(region, uid, false) end
	end)
end

local originalScanEvents = WA.ScanEvents
WA.ScanEvents = function(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	originalScanEvents(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	local listeners = customCheckEvents[event]
	if not listeners then return end
	for uid in pairs(listeners) do rerunConditions(uid) end
end
