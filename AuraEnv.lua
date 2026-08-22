-- WeakestAuras -- the environment user-authored Lua runs in: the sandbox table,
-- the `aura_env` push/pop pair, and the one compiler and one runner every
-- custom-code site goes through. Mirrors WA2's AuraEnvironment.lua (§12).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- Loads before every consumer, which is the point of it being its own file: the
-- environment used to be file-local to GenericTrigger.lua, three .toc lines
-- *after* the files that compile into it, and survived only because every use is
-- at WA.Add time. A missing environment must be impossible by construction --
-- the alternative is compiling user code straight into the global namespace with
-- no error to say so.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- Sandbox for user-authored code. Reads fall through to the real globals (so a
-- custom function can call UnitName/GetSpellInfo/C_UnitAuras/string/table/math
-- without an explicit whitelist), but writes land in this table, never the
-- global namespace -- user code can't clobber a real global. Permissive on
-- purpose (drift §D2); every call is safecall-wrapped at run time, so a runtime
-- error names the aura and can't take down the tick it was reached from. Same
-- __index-passthrough idiom pfUI uses for its module env.
local customEnv = setmetatable({}, { __index = getfenv(0) })
WA.customEnv = customEnv

-- ---------------------------------------------------------------------------
-- The `WeakAuras` name inside user code
--
-- An imported aura's Lua reaches for `WeakAuras`, and its authors also use that
-- table as a scratch namespace (`WeakAuras.ComboFill1 = ...`), so it has to be
-- a real writable table and not only a function set.
--
-- It lives in customEnv rather than in _G, and that is the load-bearing part:
-- `if WeakAuras then` is how an addon probes for WeakAuras being loaded, so a
-- global of this name tells every one of them that it is -- and they would then
-- call the rest of an API this table answers a fraction of. Inside user code the
-- name resolves here; outside, nothing changed.
--
-- Only calls this addon can answer *faithfully* are here. An upstream function
-- given a lookalike that behaves differently is worse than an absent one: the
-- absent one errors at the call, names itself, and is reported at import --
-- WA.ForeignApiNames is what the import report reads to say so.
-- ---------------------------------------------------------------------------

-- Upstream's WeakAuras.regions[id] is a record whose `region` is the base
-- clone's frame. One proxy per id, cached, so identity holds across reads the
-- way a real table's would; `region` resolves on every read because ours are
-- pooled and the frame for an id changes. Peek, not Ensure -- reading this must
-- not conjure a frame for an aura nothing has drawn.
--
-- An id with no display answers **nil**, not an empty record. Upstream's is a
-- real table, so `if WeakAuras.regions[id] then` is how code asks whether an
-- aura exists at all; a metatable that manufactured a proxy for every key would
-- answer yes to every id ever spelled, including a typo.
local regionProxies = {}
local regionsProxy = setmetatable({}, { __index = function(_, id)
	if not (WeakestAurasDB and WeakestAurasDB.displays[id]) then return nil end
	local proxy = regionProxies[id]
	if not proxy then
		proxy = setmetatable({}, { __index = function(_, key)
			if key == "region" then return WA.PeekRegion and WA.PeekRegion(id, "") or nil end
			if key == "regionType" then
				local data = WeakestAurasDB and WeakestAurasDB.displays[id]
				return data and data.regionType or nil
			end
			return nil
		end })
		regionProxies[id] = proxy
	end
	return proxy
end })

local weakAurasCompat = {
	ScanEvents = function(...) return WA.ScanEvents(unpack(arg)) end,
	GetRegion = function(id, cloneId) return WA.GetRegion(id, cloneId) end,
	GetTriggerStateForTrigger = function(id, triggernum)
		return WA.GetTriggerStateForTrigger(id, triggernum)
	end,
	GetData = function(id) return WeakestAurasDB and WeakestAurasDB.displays[id] or nil end,
	IsOptionsOpen = function() return WA.optionsOpen and true or false end,
	GetHSVTransition = function(p, r1, g1, b1, a1, r2, g2, b2, a2)
		return WA.GetHSVTransition(p, r1, g1, b1, a1, r2, g2, b2, a2)
	end,
	-- Guards an author puts around retail-only branches. This client is neither,
	-- and no import runs user code -- the importer writes data and WA.Add
	-- compiles afterwards -- so both answers are the steady-state truth here
	-- rather than a stand-in for something we do not track.
	IsRetail = function() return false end,
	IsImporting = function() return false end,
	regions = regionsProxy,
}

-- The names above, for the import report to tell a call it will answer from one
-- it will not. `regions` included: it is read as a table, not called; `myGUID`
-- likewise, resolved by the metatable below.
WA.ForeignApiNames = { myGUID = true }
for name in pairs(weakAurasCompat) do WA.ForeignApiNames[name] = true end

-- `myGUID` is a field upstream, not a call, and UnitGUID is not answerable at
-- file scope -- SuperWoW fills it in once the player exists. Resolved on the
-- miss so it is read at call time without a login hook of its own.
customEnv.WeakAuras = setmetatable(weakAurasCompat, { __index = function(_, key)
	if key == "myGUID" then return UnitGUID and UnitGUID("player") or nil end
	return nil
end })

-- ---------------------------------------------------------------------------
-- The `WA_` helpers
--
-- Not WoW globals and not part of the table above: upstream keeps them in the
-- environment it runs an author's Lua in (AuraEnvironment.lua's `overridden`),
-- so imported code calls them by bare name and they belong here for exactly the
-- reason `WeakAuras` does.
--
-- Same rule, too -- only what can be answered faithfully. `WA_ClassColorName`
-- cannot be: it reads `RAID_CLASS_COLORS[class].colorStr`, a field vanilla's
-- table does not carry, on a table not confirmed to exist here at all. It stays
-- absent and the import report names it instead (WA.AuraEnvNames is what tells
-- the report which names are answered).
-- ---------------------------------------------------------------------------

-- Upstream's group iterator: in a party it yields `player` first and then
-- party1..N, in a raid raid1..N and no player token, the raid roster already
-- holding one. `reversed` counts down and `forceParty` reads the party roster
-- while in a raid -- both are upstream's signature, and imported code passes
-- them. A token is yielded whether or not the unit exists, as upstream's does:
-- the caller's own UnitExists check is the one an author wrote.
local function iterateGroupMembers(reversed, forceParty)
	local raid = GetNumRaidMembers and (GetNumRaidMembers() or 0) or 0
	if raid > 40 then raid = 40 end
	local prefix = (not forceParty and raid > 0) and "raid" or "party"
	local count = raid
	if prefix == "party" then
		count = GetNumPartyMembers and (GetNumPartyMembers() or 0) or 0
		if count > 4 then count = 4 end
	end
	local i = reversed and count or (prefix == "party" and 0 or 1)
	return function()
		local unit
		if i == 0 and prefix == "party" then unit = "player"
		elseif i > 0 and i <= count then unit = prefix .. i end
		i = i + (reversed and -1 or 1)
		return unit
	end
end
customEnv.WA_IterateGroupMembers = iterateGroupMembers

-- Retail's aura tuple, which is what upstream's aura getters hand back:
-- `UnitAura(unit, index, filter)`'s fifteen named returns, in that order.
--
-- The order is not inferred -- BuffTrigger2 reads it positionally (§5,
-- `name, icon, stacks, debuffClass, duration, expirationTime, unitCaster,
-- isStealable, _, spellId, _, isBossDebuff, isCastByPlayer, _, modRate`) and
-- every position maps onto a named field of ClassicAPI's AuraData, the ones
-- vanilla has no concept of included: those are documented as constant `false`
-- (or `1` for timeMod) rather than absent, so an author reading position 8 gets
-- the same answer they would on a retail client with nothing stealable.
--
-- `castByPlayer` (13) is derived rather than taken from its stub: AuraData
-- carries `sourceUnit`, so the question is answerable, and a constant false
-- would silently fail every "did I cast this" branch. It degrades the way
-- ClassicAPI's own PLAYER filter does -- an aura already up before its cast was
-- observed has no caster and reads false.
--
-- **Position 16 onward is the aura's `points` values, and this client has
-- none.** A caller reading that far gets nothing back, which is the honest
-- answer and the one the corpus's single such caller already guards with `or ""`.
local function unpackAura(aura)
	if not aura then return nil end
	return aura.name, aura.icon, aura.applications, aura.dispelName,
		aura.duration, aura.expirationTime, aura.sourceUnit, aura.isStealable,
		aura.nameplateShowPersonal, aura.spellId, aura.canApplyAura, aura.isBossAura,
		aura.sourceUnit == "player", aura.nameplateShowAll, aura.timeMod
end

-- Upstream's "the first aura on this unit matching a name or a spell id", with
-- its filter argument passed through untouched: ClassicAPI takes the modern
-- AuraFilters format -- `|`-separated tokens, `!` negation, HELPFUL/HARMFUL/
-- PLAYER/DISPELLABLE/CROWD_CONTROL honoured and the rest accepted and ignored --
-- which is the same string upstream builds. A filter naming neither polarity
-- gets HELPFUL added, as upstream's does.
local function getUnitAura(unit, spell, filter)
	if filter and not string.find(string.upper(filter), "FUL") then
		filter = filter .. "|HELPFUL"
	end
	for i = 1, 255 do
		local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
		if not aura then return nil end
		if spell == aura.spellId or spell == aura.name then return unpackAura(aura) end
	end
end
customEnv.WA_GetUnitAura = getUnitAura
customEnv.WA_GetUnitBuff = function(unit, spell, filter)
	return getUnitAura(unit, spell, filter and (filter .. "|HELPFUL") or "HELPFUL")
end
customEnv.WA_GetUnitDebuff = function(unit, spell, filter)
	return getUnitAura(unit, spell, filter and (filter .. "|HARMFUL") or "HARMFUL")
end

-- The `WA_` names above, for the import report. Anything else an author calls
-- under that prefix is either one of upstream's this addon does not answer or
-- their own helper, and the report says which by looking for a definition.
WA.AuraEnvNames = {
	WA_IterateGroupMembers = true,
	WA_GetUnitAura = true, WA_GetUnitBuff = true, WA_GetUnitDebuff = true,
}

-- ---------------------------------------------------------------------------
-- aura_env
-- ---------------------------------------------------------------------------

-- Per-aura storage, keyed by id: clones share one table, with cloneId a *field*
-- on it rather than a table of its own (upstream's aura_environments[id]). The
-- table persists between calls, which is what makes it the place to cache
-- anything expensive.
local environments = {}

-- One aura's code can call into another's, so the previous binding is stacked
-- rather than assumed nil. The depth is an explicit counter because the saved
-- value is legitimately nil at the outermost level and table.insert cannot
-- append that.
local stack, depth = {}, 0

-- `aura_env` is assigned straight onto the environment table rather than
-- answered by a function __index, and that is a decision rather than a
-- shortcut. With a table __index a global read that misses customEnv chains to
-- the globals table at C level; with a function __index every miss becomes a Lua
-- call plus a comparison -- and almost every read from user code *is* a miss
-- (UnitHealth, GetTime), on code that runs per event and, in the custom text
-- region's `update` mode, per frame. Upstream needs a function there because it
-- resolves five special keys and consults two blocklists; we resolve one and
-- have declined the blocklists, so we do not inherit the reason.
--
-- What that gives up is upstream's __newindex refusal of a user assignment to
-- `aura_env`: ours lets it through until the next push overwrites it. Bounded to
-- the offending call, and not worth taxing every global *write* to prevent.
--
-- The trap: `getglobal("x")` still reads the real _G, because 1.12's getglobal
-- is a real function that ignores its caller's environment. So inside user code
-- `getglobal("aura_env")` and `aura_env` disagree. Nobody spells their own
-- variables that way, but nothing here can make them agree either.
function WA.ActivateAuraEnv(id, cloneId, state, states)
	local env = id and environments[id]
	local created = false
	if not env then
		env = {}
		created = true
		-- An id-less caller is a bug, but one whose blast radius is a repaint that
		-- dies rather than an aura_env that doesn't persist. Take the second.
		if id then environments[id] = env end
	end
	env.id = id
	env.cloneId = cloneId
	env.state = state
	env.states = states
	if created then
		local data = id and WeakestAurasDB.displays[id]
		if data and not WA.IsGroup(data) then
			env.config = WA.DeepCopy(data.config)
		end
	end
	-- Peek, not Ensure: filling this in must not spin up a frame for an aura
	-- nothing has drawn yet.
	env.region = WA.PeekRegion and WA.PeekRegion(id, cloneId) or nil
	depth = depth + 1
	stack[depth] = customEnv.aura_env
	customEnv.aura_env = env
	return env
end

function WA.ActivateAuraEnvForRegion(region)
	return WA.ActivateAuraEnv(region.id, region.cloneId, region.state, region.states)
end

function WA.DeactivateAuraEnv()
	if depth == 0 then return end
	customEnv.aura_env = stack[depth]
	stack[depth] = nil
	depth = depth - 1
end

-- The aura whose code is running, or nil outside any. This is the whole of the
-- runtime half of error attribution: the stack above already tracks it for the
-- benefit of user code, so a reporter that has no aura in hand -- WA.safecall,
-- reached from dozens of sites of which only some are an aura at all -- reads it
-- here rather than having a uid threaded down to it. Upstream's current_uid, for
-- the same reason and off the same stack.
function WA.CurrentAuraId()
	local env = customEnv.aura_env
	return env and env.id or nil
end

-- Drops an aura's stored environment. The seams are deletion and the aura's
-- custom source changing -- **not** WA.Add, which upstream's equivalent reset
-- hangs off. WA.Add fires per drag step here (a `range` field's `set` calls it,
-- and NewSlider's onChange fires on every frame of a drag), so resetting there
-- would wipe a user function's accumulated state once a frame, which is the
-- whole reason anyone stores anything in aura_env. Cached state belonging to
-- code that no longer exists is the only staleness worth spending on.
--
-- Whole-aura rather than per compiled function: editing one of an aura's custom
-- fields drops what its other ones cached. Upstream resets the environment on
-- any options edit at all, so this is the narrower rule, not a wider one.
function WA.ClearAuraEnv(id)
	environments[id] = nil
end

function WA.RenameAuraEnv(oldId, newId)
	environments[newId] = environments[oldId]
	environments[oldId] = nil
end

function WA.RefreshAuraEnvConfig(id)
	local env = id and environments[id]
	local data = id and WeakestAurasDB.displays[id]
	if not env or not data then return end
	if WA.IsGroup(data) then
		env.config = nil
	else
		env.config = WA.DeepCopy(data.config)
	end
end

-- ---------------------------------------------------------------------------
-- The compiler
-- ---------------------------------------------------------------------------

-- The source a user-authored field becomes before loadstring sees it. Public
-- because the options editor's syntax check has to report line numbers against
-- the same string the compiler builds, and a second spelling of the wrapper
-- drifts silently -- the symptom is an error line off by one. "return " carries
-- no newline for exactly that reason.
--
-- `encloseInFunction` is upstream's flag for a source that is a function *body*
-- rather than a function expression.
function WA.WrapFunctionSource(source, encloseInFunction)
	source = source or ""
	if encloseInFunction then source = "function() " .. source .. "\nend" end
	return "return " .. source
end

-- The aura being compiled, which WA.Add sets around its whole re-derivation. The
-- compile half of attribution needs its own ambient because compiling happens
-- *outside* the aura-env sandwich above -- and one variable set at the top of
-- WA.Add covers every custom-code site at once, since Add is the funnel every
-- trigger, condition, action and region compile hangs off.
WA.compilingAuraId = nil

-- Reports a compile failure the way WA.safecall reports a runtime one, so a
-- broken aura reads the same whichever half of user code broke. A nil errTag
-- suppresses the report entirely, which is how the options editor's own syntax
-- check stays quiet while the user is still typing.
--
-- Keyed by the code site, so two broken fields on one aura are two reports rather
-- than one overwriting the other. Nothing here clears them: WA.Add drops the
-- whole `compile:` namespace before it recompiles, which is what makes a fixed
-- field's warning go away without every compile site remembering to.
local function refuse(errTag, err)
	if not errTag then return nil, err end
	local message = "[" .. tostring(errTag) .. "] " .. tostring(err)
	local uid = WA.CurrentWarningUid and WA.CurrentWarningUid()
	if uid and WA.UpdateWarning then
		WA.UpdateWarning(uid, "compile:" .. tostring(errTag), "error", message, true)
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cffff0000WeakestAuras|r " .. message, 1, 0.3, 0.3)
	end
	return nil, err
end

local function compile(source, errTag, env)
	local chunk, err = loadstring(source)
	if not chunk then return refuse(errTag, err) end
	if env then setfenv(chunk, env) end
	local ok, fn = pcall(chunk)
	if not ok then return refuse(errTag, fn) end
	if type(fn) ~= "function" then return refuse(errTag, "must be a function") end
	return fn
end

-- The compiler for user-authored code: wraps, loadstrings, sandboxes and
-- reports, returning the function or nil plus the error string. A nil `errTag`
-- suppresses the chat message, which is how a caller driving its own error line
-- (the options editor) stays quiet.
--
-- There is no legitimate reason for a call site to hand-roll loadstring +
-- setfenv + pcall instead; a site whose *failure policy* differs expresses that
-- in what it does with the return, not in a second copy of the machinery.
function WA.LoadFunction(source, errTag, encloseInFunction)
	return compile(WA.WrapFunctionSource(source, encloseInFunction), errTag, customEnv)
end

-- The same for engine-generated source -- a trigger prototype's assembled test.
-- It keeps the real globals: the sandbox belongs to the code's *author*, not to
-- the call site, which is upstream's WeakAuras.LoadFunction / Private.LoadFunction
-- split. The source arrives complete, wrapper included, since the engine built it.
function WA.LoadBuiltinFunction(source, errTag)
	return compile(source, errTag, nil)
end

-- ---------------------------------------------------------------------------
-- The runner
-- ---------------------------------------------------------------------------

-- push + safecall + pop, the sandwich upstream repeats at every one of its
-- user-code sites. It exists once because the *pop* is the part that breaks:
-- safecall swallows, so a pop that only ran on success would leave aura_env
-- pointing at the wrong aura for everything that follows -- a bug that presents
-- as some *other* aura misbehaving. Popping off safecall's return rather than
-- inside the wrapped closure is what makes the error path unconditional.
--
-- `who` is a region -- id, cloneId, state and states are read off it -- or a
-- bare aura id, for a caller with no region to hand. The id form leaves
-- aura_env.state nil, as upstream does around a trigger scan: generated trigger
-- functions receive their state directly, while custom functions receive the
-- event payload.
--
-- Returns safecall's (ok, result) and decides nothing else. The failure policy
-- is the caller's, because the call sites genuinely disagree about it -- a
-- failed custom text leaves the rest of the string rendering, a failed trigger
-- means don't show.
function WA.RunAuraFunc(who, errTag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	if type(who) == "table" then
		WA.ActivateAuraEnvForRegion(who)
	else
		WA.ActivateAuraEnv(who)
	end
	local ok, res = WA.safecall(errTag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	WA.DeactivateAuraEnv()
	return ok, res
end

-- The same sandwich with the function's whole return list packed into an array,
-- for a caller that wants N values (custom text, whose every return is a %c).
-- 5.0's xpcall takes no call arguments, so the call is a closure either way;
-- this one packs instead of keeping the first value. Delegating rather than
-- re-spelling keeps the push/pop at one site.
function WA.RunAuraFuncPacked(who, errTag, fn, a1, a2, a3, a4, a5, a6, a7)
	local packed
	local ok = WA.RunAuraFunc(who, errTag, function()
		packed = { fn(a1, a2, a3, a4, a5, a6, a7) }
	end)
	if not ok then return false, nil end
	return true, packed
end
