-- WeakestAuras -- Lua 5.0 shims the ported WeakAuras2 idioms lean on. Kept
-- deliberately small: only what's actually used, no speculative polyfills.
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- 5.1 added `math.huge`; 5.0 reads it back as nil, so `x or math.huge` inside a
-- comparison is a runtime error rather than the large number it looks like. The
-- division is how 5.0 spells the same infinity.
WA.INF = 1 / 0

-- 5.0 has no `wipe`; clearing keys in place preserves the table identity that
-- callers (memoization caches, per-tick scratch tables) hold a reference to.
function WA.wipe(t)
	for k in pairs(t) do t[k] = nil end
	return t
end

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
-- (§12's error-attribution pattern, minus the sandbox). 5.0's xpcall
-- takes no call args, so the arguments are captured as upvalues in a wrapper
-- closure instead of forwarded -- capped at eleven, which is what the widest
-- call site needs: a compiled trigger function takes (state, event, arg1..arg9).
-- Returns the pcall-style (ok, result-or-error) so callers can branch on success.
function WA.safecall(errTag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	if type(fn) ~= "function" then return false, "not a function" end
	local ok, res = xpcall(function() return fn(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11) end, function(err)
		return err
	end)
	if not ok then
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cffff0000WeakestAuras|r [" .. tostring(errTag) .. "] " .. tostring(res), 1, 0.3, 0.3)
	end
	return ok, res
end
