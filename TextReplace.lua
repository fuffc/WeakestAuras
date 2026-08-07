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
	i = {
		get = function(state) return state.icon end,
		func = function(v) return v and ("|T" .. v .. ":0|t") or "" end,
	},
	s = {
		get = function(state)
			if not state.stacks or state.stacks == 0 then return "" end
			return state.stacks
		end,
		func = function(v) return v end,
	},
}

-- The bare symbol name behind an optional "N." trigger scope.
local function bareSymbol(symbol)
	local _, _, _, sym = string.find(symbol, "^(%d+)%.(.+)$")
	return sym or symbol
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

WA.format_types = {
	none = {
		display = "None",
		CreateFormatter = function() return nil end,
	},
	Number = {
		display = "Number",
		CreateFormatter = function(symbol, get)
			local precision = get(symbol .. "_decimal_precision", 1)
			if precision == 0 then
				local round = ROUNDERS[get(symbol .. "_round_type", "floor")] or math.floor
				return function(v)
					local n = asNumber(v)
					if n == nil then return v end
					return round(n)
				end
			end
			local fmt = "%." .. precision .. "f"
			return function(v)
				local n = asNumber(v)
				if n == nil then return v end
				return string.format(fmt, n)
			end
		end,
		summary = function(symbol, get)
			local precision = get(symbol .. "_decimal_precision", 1)
			local s = "Number " .. (PRECISION_LABELS[precision] or tostring(precision))
			if precision == 0 then
				s = s .. " " .. (ROUND_LABELS[get(symbol .. "_round_type", "floor")] or "Floor")
			end
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

-- Walks the distinct formattable symbols of `text`. %i is skipped throughout:
-- it renders a |T...|t texture escape, which no number format can do anything
-- but break (upstream skips it in the same two places).
local function eachFormattableSymbol(text, fn)
	if not text or text == "" then return end
	local seen = {}
	walk(text, function() end, function(symbol)
		if not seen[symbol] and bareSymbol(symbol) ~= "i" then
			seen[symbol] = true
			fn(symbol)
		end
	end)
end

-- symbol -> formatter for every symbol in `text` (§9 CreateFormatters).
-- get(key, default) reads the owning sub-region's text_text_format_* settings.
-- A symbol left on "none" gets no entry, so its built-in formatting stands.
function WA.CreateFormatters(text, get)
	local formatters = {}
	eachFormattableSymbol(text, function(symbol)
		local spec = WA.format_types[get(symbol .. "_format", "none")]
		if spec then formatters[symbol] = spec.CreateFormatter(symbol, get) end
	end)
	return formatters
end

-- Option field descriptors for `text`: a Format select per symbol, followed by
-- whatever the picked format adds (§9 AddTextFormatOption). `set(key, value)`
-- writes the setting back; picking a format re-renders the tab, since that is
-- what brings the format's own fields in.
function WA.FormatOptionFields(text, get, set)
	local fields = {}
	eachFormattableSymbol(text, function(symbol)
		local fmtKey = symbol .. "_format"
		table.insert(fields, {
			type = "select", name = "Format %" .. symbol,
			key = "text_text_format_" .. fmtKey,
			values = FORMAT_ORDER, labels = FORMAT_LABELS, half = true,
			get = function() return get(fmtKey, "none") end,
			set = function(v) set(fmtKey, v); WA.RefreshOptions() end,
		})
		local spec = WA.format_types[get(fmtKey, "none")]
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
function WA.FormatSummary(text, get)
	local parts = {}
	eachFormattableSymbol(text, function(symbol)
		local name = get(symbol .. "_format", "none")
		local spec = WA.format_types[name]
		if spec and name ~= "none" then
			local desc = spec.summary and spec.summary(symbol, get) or spec.display
			table.insert(parts, "%" .. symbol .. " " .. desc)
		end
	end)
	if table.getn(parts) == 0 then return nil end
	return table.concat(parts, ", ")
end

-- Whether a string references a %p (remaining-time) symbol -- the only one that
-- must repaint every frame. Drives SubText's FrameTick subscription (§8/§9): no
-- %p means the text repaints on state change only.
local function symbolIsP(symbol)
	return bareSymbol(symbol) == "p"
end

function WA.TextNeedsFrameTick(text)
	if not text or text == "" then return false end
	local found = false
	walk(text, function() end, function(sym) if symbolIsP(sym) then found = true end end)
	return found
end
