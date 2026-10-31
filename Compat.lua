-- WeakestAuras -- helpers the ported WeakAuras2 idioms lean on that ClassicAPI
-- does not provide. Kept deliberately small: only what's actually used, no speculative polyfills.
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- The first `n` *characters* of a UTF-8 string. A plain string.sub cuts on a
-- byte and can land inside a multi-byte sequence, which renders as a garbage
-- glyph -- and every accented spell name on this client is Latin-1 encoded as
-- UTF-8, so that is the common case rather than the exotic one. Continuation
-- bytes are 0x80-0xBF, so anything outside that range starts a character.
function WA.Utf8Sub(s, n)
	if type(s) ~= "string" or type(n) ~= "number" or n < 0 then return s end
	local len = string.len(s)
	local chars = 0
	for i = 1, len do
		local b = string.byte(s, i)
		if b < 128 or b >= 192 then
			if chars == n then return string.sub(s, 1, i - 1) end
			chars = chars + 1
		end
	end
	return s
end

-- xpcall-wrapped call with the aura id prefixed onto any error, so a broken
-- aura reports itself and fails alone rather than taking down a whole tick
-- (§12's error-attribution pattern, minus the sandbox). ClassicAPI's xpcall
-- forwards trailing arguments to the callee. The arguments are fixed
-- parameters, capped at eleven -- what the widest call site needs: a compiled
-- trigger function takes (state, event, arg1..arg9). A `...` signature would
-- not do: ClassicAPI rewrites it to 5.0's `arg`, a fresh table per call, and
-- safecall sits under nearly every dispatch in the addon. Returns the
-- pcall-style (ok, result-or-error) so callers can branch on success.
local errHandler = function(err) return err end
local function reportError(errTag, res)
	-- The options preview runs trigger code that was written to read a live
	-- event payload, and an aura opted into swallowing that (WA2's
	-- ignoreOptionsEventErrors) wants the failure gone, not reported once per
	-- preview. Nothing else sets this, and the one setter clears it in the
	-- same call.
	if WA.silenceErrors then return end
	local message = "[" .. tostring(errTag) .. "] " .. tostring(res)
	-- `errTag` is a label for a chat line, and half the call sites are not an
	-- aura at all (Comm, the trigger-system dispatch), so it cannot key a
	-- per-aura registry. The aura is read off the ambient instead; nil means
	-- chat only, which is what a non-aura caller gets. Late-bound because this
	-- file loads before both the registry and the aura environment.
	local uid = WA.CurrentWarningUid and WA.CurrentWarningUid()
	if uid and WA.UpdateWarning then
		WA.UpdateWarning(uid, "runtime:" .. tostring(errTag), "error", message, true)
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cffff0000WeakestAuras|r " .. message, 1, 0.3, 0.3)
	end
end
function WA.safecall(errTag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	if type(fn) ~= "function" then return false, "not a function" end
	local ok, res = xpcall(fn, errHandler, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	if not ok then reportError(errTag, res) end
	return ok, res
end

-- Up to four results, for a caller that needs more than safecall's one. The
-- animation curves return two or four values every frame, and the closure and
-- results table that otherwise carry them out of a protected call were
-- per-frame garbage. Stock 5.0 pcall, not xpcall: it forwards arguments and
-- returns every result by itself, and with safecall's identity handler the
-- error value is the same either way.
function WA.safecall4(errTag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	if type(fn) ~= "function" then return false end
	local ok, r1, r2, r3, r4 = pcall(fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	if not ok then
		reportError(errTag, r1)
		return false
	end
	return true, r1, r2, r3, r4
end

-- Pooled scratch tables for the per-dispatch sets (the dirty ids a scan
-- collects). Each acquire hands out a distinct table, so a nested dispatch
-- gets its own; a table an error strands is simply collected.
local scratchFree, scratchFreeN = {}, 0
function WA.AcquireScratch()
	if scratchFreeN == 0 then return {} end
	local t = scratchFree[scratchFreeN]
	scratchFree[scratchFreeN] = nil
	scratchFreeN = scratchFreeN - 1
	return t
end
function WA.ReleaseScratch(t)
	for k in pairs(t) do t[k] = nil end
	scratchFreeN = scratchFreeN + 1
	scratchFree[scratchFreeN] = t
end
