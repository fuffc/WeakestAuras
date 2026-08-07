-- WeakestAuras -- dynamic text: the %-placeholder parser and the built-in
-- symbols it resolves. Mirrors WA2's ReplacePlaceHolders / dynamic_texts (§9),
-- 5.0-clean (no string.match, no string method syntax -- string.byte/sub state
-- machine only).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md
--
-- WA.ReplacePlaceHolders(text, region, formatters) walks `text` a byte at a
-- time, emitting literals verbatim and replacing each %symbol from the region's
-- active state (region.state) or a specific trigger's state (region.states[N]
-- via "%N.sym"). `formatters` is the symbol -> formatter map WA.CreateFormatters
-- builds from the owning sub-region's per-symbol format settings.
-- Only %p (remaining time) changes between state applies, so
-- WA.TextNeedsFrameTick reports whether a string needs the per-frame FrameTick
-- subscription (RegionPrototype.lua) rather than every text polling every frame.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- Shared m:ss / decimal-seconds formatter (upstream's default precision-1
-- behavior, §9): m:ss above a minute, one decimal below, blank at/under 0.
local function timeFmt(t)
	if type(t) ~= "number" then return "" end
	if t > 60 then
		return string.format("%d:%02d", math.floor(t / 60), math.floor(math.mod(t, 60)))
	elseif t > 0 then
		return string.format("%.1f", t)
	end
	return ""
end

-- The five classic symbols (§9). get(state) pulls the raw value, func
-- formats it. A symbol whose name matches a real state field never reaches
-- here (field-by-name wins first, see resolveInState) -- these are the
-- fallbacks. `func` is the built-in formatting, which a format chosen in the
-- options for that symbol replaces (see WA.format_types).
WA.dynamic_texts = {
	p = {
		get = function(state)
			if state.progressType == "timed" then
				if not state.expirationTime then return nil end
				local remaining = state.expirationTime - GetTime()
				return remaining >= 0 and remaining or nil
			elseif state.progressType == "static" then
				return state.value
			end
			return nil
		end,
		func = function(v, state)
			if state.progressType ~= "timed" then return v end
			return timeFmt(v)
		end,
	},
	t = {
		get = function(state)
			if state.progressType == "timed" then return state.duration
			elseif state.progressType == "static" then return state.total end
			return nil
		end,
		func = function(v, state)
			if state.progressType ~= "timed" then return v end
			return timeFmt(v)
		end,
	},
	n = {
		-- An *empty* name falls through to the display's own id, not just a nil
		-- one: a trigger system with nothing configured yet reports "" rather
		-- than nil (TriggerAura.GetNameAndIcon), and "" is truthy in Lua, so a
		-- plain `or` chain would render a blank instead of the fallback.
		get = function(state)
			local name = state.name
			if name ~= nil and name ~= "" then return name end
			return state.id or ""
		end,
		func = function(v) return v end,
	},
	-- Always empty. Upstream renders the icon inline as a |T...|t escape, which
	-- this client's FontString lays out as literal *text* -- so emitting one puts
	-- "Interface\Icons\..." on screen rather than an icon (design/client/
	-- gotchas.md). The symbol stays, resolving to nothing, because an imported
	-- upstream aura that uses it must not spew a texture path.
	i = {
		get = function(state) return state.icon end,
		func = function() return "" end,
	},
	s = {
		get = function(state)
			if not state.stacks or state.stacks == 0 then return "" end
			return state.stacks
		end,
		func = function(v) return v end,
	},
}

-- The state fields this aura's triggers declare, as the %symbols a text can
-- reference: a sorted name array plus name -> { display, type }. Bools are
-- dropped, matching upstream's GetAdditionalProperties -- "true"/"false" is not
-- something anyone writes a placeholder for. Single-trigger here, so every
-- trigger's variables flatten into one list rather than being scoped per
-- trigger.
function WA.TextSymbols(data)
	local names, byName = {}, {}
	local templates = (data and WA.GetConditionTemplates) and WA.GetConditionTemplates(data) or {}
	for _, vars in pairs(templates) do
		for name, spec in pairs(vars) do
			if spec.type ~= "bool" and not byName[name] then
				byName[name] = spec
				table.insert(names, name)
			end
		end
	end
	table.sort(names)
	return names, byName
end

-- The line naming those codes, for a `description` row under a text field.
-- resolveInState accepts any state field by name, so the placeholder set is
-- open-ended and nothing else in the options window says which names are live.
-- nil when the triggers declare none, so the row is absent rather than empty.
function WA.TextSymbolHint(data)
	local names = WA.TextSymbols(data)
	local n = table.getn(names)
	if n == 0 then return nil end
	local parts = {}
	for i = 1, n do parts[i] = "%" .. names[i] end
	return "This aura's triggers also supply: " .. table.concat(parts, ", ")
end

-- The bare symbol name behind an optional "N." trigger scope.
local function bareSymbol(symbol)
	local _, _, _, sym = string.find(symbol, "^(%d+)%.(.+)$")
	return sym or symbol
end

-- The format a symbol takes when nothing has been picked for it (§9
-- DefaultFormatterFor). Upstream infers from the arg's options *control* type,
-- which says nothing about a stored state field, so it hand-writes 33
-- `formatter =` entries to cover them; `conditionType` describes the value
-- itself, so the same answer falls out of a declaration that is already there.
--
-- number and bool are absent deliberately: blanket decimal formatting of every
-- numeric field is a downgrade, and upstream drops bools from the metadata
-- entirely.
local DEFAULT_FORMAT_FOR_TYPE = {
	timer = "timed",
	elapsedTimer = "timed",
	string = "string",
}

-- `byName` is WA.TextSymbols' second return, passed in by callers resolving
-- several symbols so the trigger walk happens once.
function WA.DefaultFormatFor(symbol, data, byName)
	local sym = bareSymbol(symbol)
	-- %p and %t are the one place we keep "none" against upstream's hardcoded
	-- `timed`: their built-in rendering already *is* a time format at precision
	-- 1, so adopting it would change the sub-minute look of every deployed
	-- countdown to arrive at the same place.
	if sym == "p" or sym == "t" then return "none" end
	if not byName then
		local _
		_, byName = WA.TextSymbols(data)
	end
	local spec = byName[sym]
	if not spec then return "none" end
	-- An arg may override the mapping by declaring `formatter`; none does yet,
	-- and none should until the mapping is actually wrong for it.
	return spec.formatter or DEFAULT_FORMAT_FOR_TYPE[spec.type] or "none"
end

-- Per-symbol output formatting (§9 format_types). Every symbol renders through
-- tostring by default, so a float state field like %distance shows its full
-- precision; picking a format for it in the text sub-region's options routes it
-- through the formatter built here instead. Settings live on the sub-region
-- under upstream's key layout, text_text_format_<symbol>_<setting>.
local PRECISIONS = { 0, 1, 2, 3 }
local PRECISION_LABELS = { [0] = "12", [1] = "12.3", [2] = "12.34", [3] = "12.345" }
local ROUND_MODES = { "floor", "ceil", "round" }
local ROUND_LABELS = { floor = "Floor", ceil = "Ceil", round = "Round" }
local ROUNDERS = {
	floor = math.floor,
	ceil = math.ceil,
	round = function(v) return math.floor(v + 0.5) end,
}

-- A value that isn't a number (and isn't a string spelling one) passes through
-- untouched rather than becoming nil -- a format picked for one symbol must not
-- blank it out when a trigger reports something non-numeric there.
local function asNumber(v)
	if type(v) == "number" then return v end
	if type(v) == "string" then return tonumber(v) end
	return nil
end

-- ---------------------------------------------------------------------------
-- Padding, shared by string / BigNumber / Number
-- ---------------------------------------------------------------------------

local PAD_MODES = { "left", "right" }
local PAD_LABELS = { left = "Left", right = "Right" }

local function padString(input, mode, length)
	local s = tostring(input)
	local toAdd = length - string.len(s)
	if toAdd <= 0 then return s end
	if mode == "right" then return s .. string.rep(" ", toAdd) end
	return string.rep(" ", toAdd) .. s
end

-- Wraps `fn` (which may be nil, meaning "render as-is") in the symbol's padding
-- if it asked for any, and returns it unchanged otherwise -- so a format with
-- nothing switched on still contributes no formatter and the built-in stands.
local function withPad(symbol, get, fn)
	if not get(symbol .. "_pad", false) then return fn end
	local mode = get(symbol .. "_pad_mode", "left")
	local length = get(symbol .. "_pad_max", 8)
	if fn then
		return function(v, state) return padString(fn(v, state), mode, length) end
	end
	return function(v) return padString(v, mode, length) end
end

-- BuildOptions has no disabled state, so the two dependent rows are omitted
-- rather than greyed -- the same rule Round Mode follows.
local function padOptionFields(symbol, get, set, fields)
	table.insert(fields, {
		type = "toggle", name = "Pad", key = "text_text_format_" .. symbol .. "_pad",
		get = function() return get(symbol .. "_pad", false) end,
		set = function(v) set(symbol .. "_pad", v); WA.RefreshOptions() end,
	})
	if not get(symbol .. "_pad", false) then return end
	table.insert(fields, {
		type = "select", name = "Pad Mode", key = "text_text_format_" .. symbol .. "_pad_mode",
		values = PAD_MODES, labels = PAD_LABELS, half = true,
		get = function() return get(symbol .. "_pad_mode", "left") end,
		set = function(v) set(symbol .. "_pad_mode", v) end,
	})
	table.insert(fields, {
		type = "range", name = "Pad To", key = "text_text_format_" .. symbol .. "_pad_max",
		min = 1, max = 20, step = 1, half = true,
		get = function() return get(symbol .. "_pad_max", 8) end,
		set = function(v) set(symbol .. "_pad_max", v) end,
	})
end

local function padSummary(symbol, get)
	if not get(symbol .. "_pad", false) then return nil end
	return "pad " .. (PAD_LABELS[get(symbol .. "_pad_mode", "left")] or "Left")
		.. " " .. tostring(get(symbol .. "_pad_max", 8))
end

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

-- Three complete renderings of a number of seconds, not deltas on one another:
-- a chosen format *replaces* a symbol's built-in formatting, so each has to
-- stand on its own above and below a minute.
local TIME_FORMATS = { 0, 1, 2 }
local TIME_FORMAT_LABELS = {
	[0] = "63:42 | 3:07 | 10",
	[1] = "1h | 3m | 10s",
	[2] = "1h 3m | 3m 7s | 10s",
}
local TIME_PRECISIONS = { 1, 2, 3 }
local TIME_PRECISION_LABELS = { [1] = "12.3", [2] = "12.34", [3] = "12.345" }

local TIME_RENDERERS = {
	[0] = function(t)
		if t >= 60 then
			return string.format("%d:%02d", math.floor(t / 60), math.floor(math.mod(t, 60)))
		end
		return string.format("%d", math.floor(t))
	end,
	[1] = function(t)
		if t >= 3600 then return string.format("%dh", math.floor(t / 3600)) end
		if t >= 60 then return string.format("%dm", math.floor(t / 60)) end
		return string.format("%ds", math.floor(t))
	end,
	[2] = function(t)
		if t >= 3600 then
			return string.format("%dh %dm", math.floor(t / 3600),
				math.floor(math.mod(t, 3600) / 60))
		end
		if t >= 60 then
			return string.format("%dm %ds", math.floor(t / 60), math.floor(math.mod(t, 60)))
		end
		return string.format("%ds", math.floor(t))
	end,
}

-- Whether this symbol's state field holds an absolute timestamp rather than a
-- span. Those are what the `timer`/`elapsedTimer` condition types describe, and
-- rendering one as a duration means subtracting the clock -- which is also the
-- one thing here that genuinely has to happen every frame.
local function isTimePoint(symbol, data)
	if not data then return false end
	local _, byName = WA.TextSymbols(data)
	local spec = byName[bareSymbol(symbol)]
	return (spec and (spec.type == "timer" or spec.type == "elapsedTimer")) and true or false
end

-- ---------------------------------------------------------------------------
-- Big numbers
--
-- Hand-rolled: neither AbbreviateNumbers nor BreakUpLargeNumbers exists on 1.12.
-- ---------------------------------------------------------------------------

local BIG_NUMBER_MODES = { "abbreviate", "separate" }
local BIG_NUMBER_LABELS = { abbreviate = "1.2m", separate = "1,234,567" }

local function abbreviateNumber(n)
	local mag = n < 0 and -n or n
	if mag >= 1000000 then return string.format("%.1fm", n / 1000000) end
	if mag >= 1000 then return string.format("%.1fk", n / 1000) end
	return string.format("%d", n)
end

local function separateNumber(n)
	local neg = n < 0
	local out = string.format("%d", math.floor(neg and -n or n))
	while true do
		local grouped, count = string.gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
		out = grouped
		if count == 0 then break end
	end
	if neg then return "-" .. out end
	return out
end

-- ---------------------------------------------------------------------------
-- Money
-- ---------------------------------------------------------------------------

-- Letters, not upstream's three coin textures: this client's FontString does not
-- honour an inline |T...|t escape and prints the texture path as text instead
-- (/wa textprobe measures it). The same absence is why %i renders a path.
local COIN_GOLD = "g"
local COIN_SILVER = "s"
local COIN_COPPER = "c"
local COIN_PRECISIONS = { 1, 2, 3 }
local COIN_PRECISION_LABELS = { [1] = "Gold", [2] = "Gold, Silver", [3] = "Gold, Silver, Copper" }

WA.format_types = {
	none = {
		display = "None",
		CreateFormatter = function() return nil end,
	},
	string = {
		display = "String",
		CreateFormatter = function(symbol, get)
			local base
			if get(symbol .. "_abbreviate", false) then
				local max = get(symbol .. "_abbreviate_max", 8)
				base = function(v) return WA.Utf8Sub(tostring(v), max) end
			end
			return withPad(symbol, get, base)
		end,
		summary = function(symbol, get)
			local parts = {}
			if get(symbol .. "_abbreviate", false) then
				table.insert(parts, "to " .. tostring(get(symbol .. "_abbreviate_max", 8)))
			end
			local pad = padSummary(symbol, get)
			if pad then table.insert(parts, pad) end
			if table.getn(parts) == 0 then return "String" end
			return "String " .. table.concat(parts, ", ")
		end,
		options = function(symbol, get, set)
			local fields = { {
				type = "toggle", name = "Abbreviate",
				key = "text_text_format_" .. symbol .. "_abbreviate",
				get = function() return get(symbol .. "_abbreviate", false) end,
				set = function(v) set(symbol .. "_abbreviate", v); WA.RefreshOptions() end,
			} }
			if get(symbol .. "_abbreviate", false) then
				table.insert(fields, {
					type = "range", name = "Max Characters",
					key = "text_text_format_" .. symbol .. "_abbreviate_max",
					min = 1, max = 40, step = 1,
					get = function() return get(symbol .. "_abbreviate_max", 8) end,
					set = function(v) set(symbol .. "_abbreviate_max", v) end,
				})
			end
			padOptionFields(symbol, get, set, fields)
			return fields
		end,
	},
	timed = {
		display = "Time",
		CreateFormatter = function(symbol, get, data)
			local renderer = TIME_RENDERERS[get(symbol .. "_time_format", 0)] or TIME_RENDERERS[0]
			local threshold = get(symbol .. "_time_dynamic_threshold", 60)
			local decimals = "%." .. get(symbol .. "_time_precision", 1) .. "f"
			local timePoint = isTimePoint(symbol, data)
			local sym = bareSymbol(symbol)

			local render = function(v, state)
				local t = asNumber(v)
				if t == nil then return v end
				if timePoint then
					t = GetTime() - t
					if t < 0 then t = -t end
				end
				if t <= 0 then return "" end
				if threshold > 0 and t < threshold then return string.format(decimals, t) end
				return renderer(t)
			end

			-- %p and %t carry a progress type, and their built-in formatting has
			-- always been "seconds only when the progress is timed" -- a static
			-- progress is a count, not a clock. Upstream special-cases the same two.
			if sym == "p" or sym == "t" then
				return function(v, state)
					if not state or state.progressType ~= "timed" then return v end
					return render(v, state)
				end
			end
			-- Only a timestamp has to be recomputed between state updates; a span
			-- renders the same until the state behind it changes, threshold or not.
			return render, timePoint
		end,
		summary = function(symbol, get)
			local s = "Time " .. (TIME_FORMAT_LABELS[get(symbol .. "_time_format", 0)] or "")
			local threshold = get(symbol .. "_time_dynamic_threshold", 60)
			if threshold > 0 then
				s = s .. ", " .. (TIME_PRECISION_LABELS[get(symbol .. "_time_precision", 1)] or "")
					.. " under " .. tostring(threshold) .. "s"
			end
			return s
		end,
		options = function(symbol, get, set)
			local fields = { {
				type = "select", name = "Time Format",
				key = "text_text_format_" .. symbol .. "_time_format",
				values = TIME_FORMATS, labels = TIME_FORMAT_LABELS,
				get = function() return get(symbol .. "_time_format", 0) end,
				set = function(v) set(symbol .. "_time_format", v) end,
			}, {
				type = "range", name = "Decimals Below",
				key = "text_text_format_" .. symbol .. "_time_dynamic_threshold",
				min = 0, max = 60, step = 1, half = true,
				get = function() return get(symbol .. "_time_dynamic_threshold", 60) end,
				set = function(v) set(symbol .. "_time_dynamic_threshold", v); WA.RefreshOptions() end,
			} }
			-- Precision decides nothing with the threshold at zero, where the
			-- decimal branch is never taken.
			if get(symbol .. "_time_dynamic_threshold", 60) > 0 then
				table.insert(fields, {
					type = "select", name = "Precision",
					key = "text_text_format_" .. symbol .. "_time_precision",
					values = TIME_PRECISIONS, labels = TIME_PRECISION_LABELS, half = true,
					get = function() return get(symbol .. "_time_precision", 1) end,
					set = function(v) set(symbol .. "_time_precision", v) end,
				})
			end
			return fields
		end,
	},
	BigNumber = {
		display = "Big Number",
		CreateFormatter = function(symbol, get)
			local mode = get(symbol .. "_big_number_format", "abbreviate")
			local render = (mode == "separate") and separateNumber or abbreviateNumber
			return withPad(symbol, get, function(v)
				local n = asNumber(v)
				if n == nil then return v end
				return render(n)
			end)
		end,
		summary = function(symbol, get)
			local s = "Big Number "
				.. (BIG_NUMBER_LABELS[get(symbol .. "_big_number_format", "abbreviate")] or "")
			local pad = padSummary(symbol, get)
			if pad then s = s .. ", " .. pad end
			return s
		end,
		options = function(symbol, get, set)
			local fields = { {
				type = "select", name = "Number Format",
				key = "text_text_format_" .. symbol .. "_big_number_format",
				values = BIG_NUMBER_MODES, labels = BIG_NUMBER_LABELS,
				get = function() return get(symbol .. "_big_number_format", "abbreviate") end,
				set = function(v) set(symbol .. "_big_number_format", v) end,
			} }
			padOptionFields(symbol, get, set, fields)
			return fields
		end,
	},
	Money = {
		display = "Money",
		CreateFormatter = function(symbol, get)
			local precision = get(symbol .. "_money_precision", 3)
			return function(v)
				local n = asNumber(v)
				if n == nil then return v end
				n = math.floor(n)
				local gold = math.floor(n / 10000)
				local silver = math.floor(math.mod(math.floor(n / 100), 100))
				local copper = math.floor(math.mod(n, 100))
				if precision == 1 then
					return separateNumber(gold) .. COIN_GOLD
				elseif precision == 2 then
					return separateNumber(gold) .. COIN_GOLD .. " " .. silver .. COIN_SILVER
				end
				return separateNumber(gold) .. COIN_GOLD .. " " .. silver .. COIN_SILVER
					.. " " .. copper .. COIN_COPPER
			end
		end,
		summary = function(symbol, get)
			return "Money " .. (COIN_PRECISION_LABELS[get(symbol .. "_money_precision", 3)] or "")
		end,
		options = function(symbol, get, set)
			return { {
				type = "select", name = "Coin Precision",
				key = "text_text_format_" .. symbol .. "_money_precision",
				values = COIN_PRECISIONS, labels = COIN_PRECISION_LABELS,
				get = function() return get(symbol .. "_money_precision", 3) end,
				set = function(v) set(symbol .. "_money_precision", v) end,
			} }
		end,
	},
	Number = {
		display = "Number",
		CreateFormatter = function(symbol, get)
			local precision = get(symbol .. "_decimal_precision", 1)
			local render
			if precision == 0 then
				local round = ROUNDERS[get(symbol .. "_round_type", "floor")] or math.floor
				render = function(v)
					local n = asNumber(v)
					if n == nil then return v end
					return round(n)
				end
			else
				local fmt = "%." .. precision .. "f"
				render = function(v)
					local n = asNumber(v)
					if n == nil then return v end
					return string.format(fmt, n)
				end
			end
			return withPad(symbol, get, render)
		end,
		summary = function(symbol, get)
			local precision = get(symbol .. "_decimal_precision", 1)
			local s = "Number " .. (PRECISION_LABELS[precision] or tostring(precision))
			if precision == 0 then
				s = s .. " " .. (ROUND_LABELS[get(symbol .. "_round_type", "floor")] or "Floor")
			end
			local pad = padSummary(symbol, get)
			if pad then s = s .. ", " .. pad end
			return s
		end,
		options = function(symbol, get, set)
			local fields = {
				{
					type = "select", name = "Precision",
					key = "text_text_format_" .. symbol .. "_decimal_precision",
					values = PRECISIONS, labels = PRECISION_LABELS, half = true,
					get = function() return get(symbol .. "_decimal_precision", 1) end,
					set = function(v) set(symbol .. "_decimal_precision", v); WA.RefreshOptions() end,
				},
			}
			-- Round Mode decides nothing above precision 0, where string.format
			-- does the rounding. Upstream greys it out; BuildOptions has no
			-- disabled state, so the generator drops the row instead.
			if get(symbol .. "_decimal_precision", 1) == 0 then
				table.insert(fields, {
					type = "select", name = "Round Mode",
					key = "text_text_format_" .. symbol .. "_round_type",
					values = ROUND_MODES, labels = ROUND_LABELS, half = true,
					get = function() return get(symbol .. "_round_type", "floor") end,
					set = function(v) set(symbol .. "_round_type", v) end,
				})
			end
			padOptionFields(symbol, get, set, fields)
			return fields
		end,
	},
}

-- Derived, so a new format type is one entry in the table above: "none" leads
-- the Format select (it's the default), the rest follow alphabetically.
local FORMAT_ORDER, FORMAT_LABELS = {}, {}
for name, spec in pairs(WA.format_types) do
	FORMAT_LABELS[name] = spec.display
	if name ~= "none" then table.insert(FORMAT_ORDER, name) end
end
table.sort(FORMAT_ORDER)
table.insert(FORMAT_ORDER, 1, "none")

-- Resolution within one state (§9): a real state field of this name wins,
-- then a dynamic_texts symbol, else empty. So %name/%stacks/%unitName read the
-- field directly while %p/%s/%n/%i/%t fall through to the formatters above.
local function resolveInState(sym, state, formatter)
	if not state then return "" end
	if state[sym] ~= nil then
		local v = state[sym]
		if formatter then v = formatter(v, state) end
		return v ~= nil and tostring(v) or ""
	end
	local dt = WA.dynamic_texts[sym]
	if dt then
		local v = dt.get(state)
		if v == nil then return "" end
		-- A chosen format replaces the symbol's built-in one rather than
		-- stacking on it (§9 ReplaceValuePlaceHolders), so %p as a Number shows
		-- raw seconds instead of m:ss.
		if formatter then
			local r = formatter(v, state)
			return r ~= nil and tostring(r) or ""
		end
		if dt.func then
			local r = dt.func(v, state)
			return r ~= nil and tostring(r) or ""
		end
		return tostring(v)
	end
	return ""
end

-- "%c" and "%c1".."%cN" name the Nth return of the region's custom text function
-- (§9), which the region ran and left in region.customValues. Bare "%c" is "%c1".
-- Not a state field: a real state field called `c` would still win, which is
-- resolveInState's rule and is why this is asked *after* it fails.
local function customIndex(symbol)
	local _, _, digits = string.find(symbol, "^c(%d*)$")
	if not digits then return nil end
	return tonumber(digits) or 1
end
WA.CustomTextIndex = customIndex

-- "%N.sym" scopes to trigger N's state (region.states[N]); "%sym" uses the
-- active state (region.state). A formatter is keyed by the whole symbol, "2.p"
-- included, since each occurrence is configured separately.
local function valueForSymbol(symbol, region, formatters)
	local formatter = formatters and formatters[symbol]
	local _, _, trigStr, sym = string.find(symbol, "^(%d+)%.(.+)$")
	if trigStr and sym then
		local states = region.states or {}
		return resolveInState(sym, states[tonumber(trigStr)], formatter)
	end
	local index = customIndex(symbol)
	if index and not (region.state and region.state[symbol] ~= nil) then
		local v = region.customValues and region.customValues[index]
		if v == nil then return "" end
		if formatter then v = formatter(v, region.state) end
		return v ~= nil and tostring(v) or ""
	end
	return resolveInState(symbol, region.state, formatter)
end

-- The state machine's next-state table (§9 nextState). 37=%, 123={, 125=},
-- 46=. ; 48-57/65-90/97-122 = alnum.
local function isWordByte(char)
	return (char >= 48 and char <= 57) or (char >= 65 and char <= 90)
		or (char >= 97 and char <= 122) or char == 46
end

local function nextState(char, state)
	if state == 0 then
		if char == 37 then return 1 end
		return 0
	elseif state == 1 then
		if char == 37 then return 0
		elseif char == 123 then return 3
		elseif isWordByte(char) then return 2 end
		return 0
	elseif state == 2 then
		if isWordByte(char) then return 2 end
		if char == 37 then return 1 end
		return 0
	elseif state == 3 then
		if char == 125 then return 0 end
		return 3
	end
	return 0
end

-- Runs the parser over `text`, calling onLiteral(str) for verbatim runs and
-- onSymbol(name) for each %symbol / %{braced} / %N.sym occurrence. Shared by
-- ReplacePlaceHolders and the FrameTick probe so the two never drift.
local function walk(text, onLiteral, onSymbol)
	local endPos = string.len(text)
	local currentPos = 1
	local state = 0
	local start = 1
	while currentPos <= endPos do
		local char = string.byte(text, currentPos)
		if state == 0 then
			if char == 37 and currentPos > start then
				onLiteral(string.sub(text, start, currentPos - 1))
			end
		elseif state == 1 then
			-- After '%': a '{' means the symbol body starts past the brace,
			-- anything else (incl. a second '%', which lands `start` on it so it
			-- prints as a literal) starts the body here.
			if char == 123 then start = currentPos + 1 else start = currentPos end
		elseif state == 2 then
			if not isWordByte(char) then
				onSymbol(string.sub(text, start, currentPos - 1))
				if char ~= 37 then start = currentPos end
			end
		elseif state == 3 then
			if char == 125 then
				onSymbol(string.sub(text, start, currentPos - 1))
				start = currentPos + 1
			end
		end
		state = nextState(char, state)
		currentPos = currentPos + 1
	end
	if state == 0 and currentPos > start then
		onLiteral(string.sub(text, start, currentPos - 1))
	elseif state == 2 and currentPos > start then
		onSymbol(string.sub(text, start, currentPos - 1))
	elseif state == 1 then
		onLiteral("%")
	end
end

function WA.ReplacePlaceHolders(text, region, formatters)
	if not text or text == "" then return "" end
	local out = {}
	walk(text,
		function(lit) table.insert(out, lit) end,
		function(sym) table.insert(out, valueForSymbol(sym, region, formatters)) end)
	local s = table.concat(out)
	return (string.gsub(s, "\\n", "\n"))
end

-- Walks the distinct formattable symbols of `text`, which may be one string or
-- an array of them -- a region whose text a condition can replace has to build
-- formatters for every string it might end up showing, not just the typed one.
-- The `seen` set spans the whole array, so a symbol shared by two of them is
-- visited once. %i is skipped throughout: it renders a |T...|t texture escape,
-- which no number format can do anything but break (upstream skips it in the
-- same two places).
local function eachFormattableSymbol(text, fn)
	if not text or text == "" then return end
	local seen = {}
	local function scan(str)
		if type(str) ~= "string" or str == "" then return end
		walk(str, function() end, function(symbol)
			if not seen[symbol] and bareSymbol(symbol) ~= "i" then
				seen[symbol] = true
				fn(symbol)
			end
		end)
	end
	if type(text) == "table" then
		for i = 1, table.getn(text) do scan(text[i]) end
	else
		scan(text)
	end
end

-- symbol -> formatter for every symbol in `text` (§9 CreateFormatters).
-- get(key, default) reads the owning sub-region's text_text_format_* settings.
-- A symbol left on "none" gets no entry, so its built-in formatting stands.
--
-- The second return is the subset whose formatter declared itself every-frame:
-- a format whose *output* changes with the clock even though the state behind it
-- did not. WA.TextNeedsFrameTick takes it, since the symbol alone can no longer
-- decide that.
-- The format actually in force for a symbol: the pick if there is one, the
-- conditionType default otherwise. Every layer that has to agree about a
-- symbol's format -- the formatter build, the options dropdown, the fold's
-- summary -- goes through this one function, which is what makes them agree.
local function formatFor(symbol, get, data, byName)
	local chosen = get(symbol .. "_format")
	if chosen ~= nil then return chosen end
	return WA.DefaultFormatFor(symbol, data, byName)
end
WA.FormatFor = formatFor

-- `text` is one string or an array of them (see eachFormattableSymbol). `data` is
-- the owning aura: the time format needs it to tell a timestamp state field from
-- a span, and the defaults above are read off it. A caller with none gets
-- duration formatting and no defaults.
function WA.CreateFormatters(text, get, data)
	local formatters, everyFrame = {}, {}
	local _, byName = WA.TextSymbols(data)
	eachFormattableSymbol(text, function(symbol)
		local spec = WA.format_types[formatFor(symbol, get, data, byName)]
		if spec then
			local fmt, isEveryFrame = spec.CreateFormatter(symbol, get, data)
			formatters[symbol] = fmt
			if isEveryFrame then everyFrame[symbol] = true end
		end
	end)
	return formatters, everyFrame
end

-- Materialises those defaults onto the sub-region (§9 SetDefaultFormatters), so
-- a symbol whose format was chosen *for* the user is a visible, editable pick
-- rather than something applied invisibly at render time. Called from a text
-- field's own `set`.
--
-- A format already chosen is never overwritten -- that includes an explicit
-- "none", which is how a user turns a default back off. Nothing is written where
-- the default is "none" anyway: the key would only pin an answer the resolution
-- above already gives, and would then survive a trigger retype that changed it.
function WA.SetDefaultFormatters(text, get, set, data)
	local _, byName = WA.TextSymbols(data)
	eachFormattableSymbol(text, function(symbol)
		if get(symbol .. "_format") == nil then
			local default = WA.DefaultFormatFor(symbol, data, byName)
			if default ~= "none" then set(symbol .. "_format", default) end
		end
	end)
end

-- Option field descriptors for `text`: a Format select per symbol, followed by
-- whatever the picked format adds (§9 AddTextFormatOption). `set(key, value)`
-- writes the setting back; picking a format re-renders the tab, since that is
-- what brings the format's own fields in.
--
-- `keyPrefix` is only the descriptor's identifying key, not storage -- `set`
-- owns that. It defaults to the sub-region's layout, the text region passing its
-- own so a row's key names the field it actually writes.
function WA.FormatOptionFields(text, get, set, data, keyPrefix)
	local fields = {}
	local _, byName = WA.TextSymbols(data)
	keyPrefix = keyPrefix or "text_text_format_"
	eachFormattableSymbol(text, function(symbol)
		local fmtKey = symbol .. "_format"
		local current = formatFor(symbol, get, data, byName)
		table.insert(fields, {
			type = "select", name = "Format %" .. symbol,
			key = keyPrefix .. fmtKey,
			values = FORMAT_ORDER, labels = FORMAT_LABELS, half = true,
			get = function() return current end,
			set = function(v) set(fmtKey, v); WA.RefreshOptions() end,
		})
		local spec = WA.format_types[current]
		if spec and spec.options then
			local extra = spec.options(symbol, get, set)
			for i = 1, table.getn(extra) do table.insert(fields, extra[i]) end
		end
	end)
	return fields
end

-- One line naming the formats picked for `text`'s symbols, for the collapsed
-- Format Options disclosure -- so folding the rows away doesn't hide what is set.
-- nil when every symbol is left on "none", which is the common case and wants no
-- decoration at all. A format type without its own `summary` reports its display
-- name, so a new one lands here without a second registration.
function WA.FormatSummary(text, get, data)
	local parts = {}
	local _, byName = WA.TextSymbols(data)
	eachFormattableSymbol(text, function(symbol)
		local name = formatFor(symbol, get, data, byName)
		local spec = WA.format_types[name]
		if spec and name ~= "none" then
			local desc = spec.summary and spec.summary(symbol, get) or spec.display
			table.insert(parts, "%" .. symbol .. " " .. desc)
		end
	end)
	if table.getn(parts) == 0 then return nil end
	return table.concat(parts, ", ")
end

-- Whether `text` references the custom text function at all (§9
-- ContainsCustomPlaceHolder). One string or an array of them, so a caller can ask
-- about a whole aura's worth at once.
function WA.ContainsCustomPlaceHolder(text)
	if not text then return false end
	local found = false
	local function scan(str)
		if type(str) ~= "string" or str == "" then return end
		walk(str, function() end, function(symbol)
			if customIndex(symbol) then found = true end
		end)
	end
	if type(text) == "table" then
		for i = 1, table.getn(text) do scan(text[i]) end
	else
		scan(text)
	end
	return found
end

-- Runs a region's custom text function and returns its results as an array, so
-- %c1..%cN can index it. Upstream's argument list, unchanged: the raw
-- expiration/duration behind the state, then the five classic symbols already
-- rendered -- a custom function should not have to re-derive what %p says.
--
-- safecall rather than a bare call: this is user-authored code reached from a
-- repaint, and an error in it must name the aura and leave the rest of the text
-- rendering rather than take the paint down. It is not sandboxed beyond the
-- environment GenericTrigger's own custom triggers get (drift §D2).
function WA.RunCustomTextFunc(region, fn)
	if not fn then return nil end
	local state = region.state
	local expirationTime, duration
	if state then
		if state.progressType == "timed" then
			expirationTime, duration = state.expirationTime, state.duration
		else
			expirationTime, duration = state.total, state.value
		end
	end
	local dt = WA.dynamic_texts
	local function classic(sym)
		if not state then return nil end
		local v = dt[sym].get(state)
		if v == nil then return nil end
		return dt[sym].func(v, state)
	end
	local ok, values = WA.safecall(region.id or "custom text", function()
		return { fn(expirationTime or WA.INF, duration or 0,
			classic("p"), classic("t"), classic("n"), classic("i"), classic("s")) }
	end)
	if not ok then return nil end
	return values
end

-- Whether a string has to repaint every frame. Drives SubText's FrameTick
-- subscription (§8/§9). Two independent reasons: it references %p, whose *value*
-- is the clock; or one of its symbols carries an every-frame formatter, whose
-- *rendering* is. `everyFrameFormatters` is WA.CreateFormatters' second return
-- and is optional -- omitting it asks the %p question alone.
local function symbolIsP(symbol)
	return bareSymbol(symbol) == "p"
end

function WA.TextNeedsFrameTick(text, everyFrameFormatters)
	if not text or text == "" then return false end
	local found = false
	walk(text, function() end, function(sym)
		if symbolIsP(sym) or (everyFrameFormatters and everyFrameFormatters[sym]) then
			found = true
		end
	end)
	return found
end
