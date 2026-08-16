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

-- Reports a compile failure the way WA.safecall reports a runtime one, so a
-- broken aura reads the same whichever half of user code broke.
local function refuse(errTag, err)
	if errTag then
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cffff0000WeakestAuras|r [" .. tostring(errTag) .. "] " .. tostring(err), 1, 0.3, 0.3)
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
