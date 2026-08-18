-- WeakestAuras -- the per-aura warning registry: keyed problem reports the aura
-- list's status strip and the Info tab read back. Mirrors WA2's AuraWarnings.lua.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

-- The status strip's art, shared with the load indicator's three states. Spelled
-- here rather than in Widgets.lua because this file loads first and every
-- consumer of the folder can reach it from here.
WA.STATUS_TEXTURES = "Interface\\AddOns\\WeakestAuras\\textures\\status\\"

-- uid -> key -> { severity = ..., message = ... }. Session-only: everything that
-- sets a warning re-derives it on the next compile or the next dispatch, so the
-- registry rebuilds itself rather than being saved.
local warnings = {}
-- uid -> key -> true, the once-per-key guard behind printOnConsole.
local printed = {}

local RANK = { info = 0, sound = 1, tts = 2, warning = 3, error = 4 }

local ICONS = {
	info = WA.STATUS_TEXTURES .. "info.tga",
	-- The guild MOTD horn, which is the client's own "this makes a noise" mark and
	-- the one the sound picker shows against every entry. 16x16 native -- exactly
	-- the strip's size -- amber, and a bare glyph rather than a button face, so it
	-- needs no crop and no tint.
	sound = "Interface\\Buttons\\UI-GuildButton-MOTD-Up",
	-- The gossip speech balloon, for the severity that speaks rather than plays.
	-- Also 16x16 and also a bare glyph, so the pair matches in size and weight; it
	-- ships white, which is what lets it be tinted into the horn's amber. Drawn
	-- tail-up-right for the gossip frame it belongs to, so it is flipped -- see
	-- LOOKS.
	tts = "Interface\\GossipFrame\\GossipGossipIcon",
	warning = WA.STATUS_TEXTURES .. "exclamation-mark.tga",
	error = WA.STATUS_TEXTURES .. "bug_report.tga",
}

-- What a severity's art needs past its path. `color` is a vertex tint, which is a
-- **multiply** -- so it can only darken a channel or remove it, which is why every
-- tint here is on art that ships white and why `sound` (already the client's amber)
-- takes none.
--
-- `sound` and `tts` are two *glyphs* rather than two shades of one, which is the
-- less obvious choice and the only workable one: no tint of an amber mark reaches
-- a second hue. A horn and a speech balloon say which is which on their own, and
-- sharing one amber is what makes them read as the pair they are.
local AMBER = { 1, 0.82, 0.15 }

local LOOKS = {
	-- Red is what separates a fault from the amber marks above it and from the
	-- grey unloaded load state.
	error = { color = { 1, 0.25, 0.25 } },
	-- Flipped because the balloon is drawn with its tail up and to the right, which
	-- is the orientation the gossip frame wants beside a line of text. Standing
	-- alone at 16px that reads as a blob; a half turn puts the tail bottom-left,
	-- where a speech balloon's belongs.
	tts = { color = AMBER, flip = true },
}

local TITLES = {
	info = "Information",
	sound = "Sound",
	tts = "Text-to-speech",
	warning = "Warning",
	error = "Error",
}

-- Worst first, which is the order a body lists in.
local ORDER = { "error", "warning", "sound", "tts", "info" }

function WA.WarningRank(severity)
	return RANK[severity]
end

-- Upstream fires an AuraWarningsUpdated callback where this pokes the list; the
-- guarded repaint is that bus, and a no-op while the options panel is closed.
--
-- The deferral is not an optimisation. A row's icon is resolved by running the
-- trigger prototype's own iconFunc, and those read the compile-time ambient
-- GenericTrigger keeps to credit an unresolved spell or item name -- so a repaint
-- nested inside a compile runs *other* auras' resolvers under the id of the aura
-- being compiled, and attributes their unresolved names to it. Held until WA.Add
-- unwinds instead, which also collapses the several warnings one Add can change
-- into one repaint.
local repaintPending = false

local function pokeList()
	if WA.compilingAuraId then repaintPending = true; return end
	if WA.RefreshList then WA.RefreshList() end
end

function WA.FlushWarningRepaint()
	if WA.compilingAuraId or not repaintPending then return end
	repaintPending = false
	if WA.RefreshList then WA.RefreshList() end
end

-- The uid of a display named by id, for a reporter that has one in hand and so
-- needs no ambient. Nil for an id that no longer exists, which is a report with
-- nothing to attach to rather than an error.
function WA.WarningUidFor(id)
	local data = id and WeakestAurasDB and WeakestAurasDB.displays
		and WeakestAurasDB.displays[id]
	return data and data.uid or nil
end

-- The uid a report with no aura in hand should be attributed to: the aura whose
-- code is running, else the one being compiled. Nil for a caller that is not an
-- aura at all (Comm, the trigger-system dispatch), which means "chat only".
function WA.CurrentWarningUid()
	return WA.WarningUidFor((WA.CurrentAuraId and WA.CurrentAuraId()) or WA.compilingAuraId)
end

-- Sets one keyed warning, or clears it when severity or message is omitted.
-- Nothing sweeps this registry, so every source owes a driven clear as well as a
-- driven set: a warning that outlives what it describes is worse than none.
--
-- `printOnConsole` prints the message once per key and not again until that key
-- is cleared, which is what stops a custom function erroring on a frame tick
-- from filling chat until the next reload. `message` is a complete chat line,
-- prefix included -- a caller that used to print for itself passes the same
-- string it printed, so the line the user sees is unchanged apart from the
-- dedupe.
function WA.UpdateWarning(uid, key, severity, message, printOnConsole)
	if not uid or not key then return end
	if printOnConsole and severity and message then
		local own = printed[uid]
		if not own then own = {}; printed[uid] = own end
		if not own[key] then
			own[key] = true
			if DEFAULT_CHAT_FRAME then
				DEFAULT_CHAT_FRAME:AddMessage("|cffff0000WeakestAuras|r " .. tostring(message), 1, 0.3, 0.3)
			end
		end
	end

	local own = warnings[uid]
	local prev = own and own[key]
	local changed = false
	if severity and message and RANK[severity] then
		if not (prev and prev.severity == severity and prev.message == message) then
			if not own then own = {}; warnings[uid] = own end
			own[key] = { severity = severity, message = message }
			changed = true
		end
	elseif prev then
		own[key] = nil
		if printed[uid] then printed[uid][key] = nil end
		changed = true
	end
	if changed then pokeList() end
end

-- Reports against a display named by id, for the sources that have one in hand and
-- so need no ambient. Falls back to a plain chat line when the id no longer
-- resolves to a display, so a report is never silently dropped -- but only if it
-- was going to be printed anyway. Omitting `severity` clears the key, as above.
function WA.ReportForAura(id, key, severity, message, printOnConsole)
	local uid = WA.WarningUidFor(id)
	if uid then
		WA.UpdateWarning(uid, key, severity, message, printOnConsole)
	elseif printOnConsole and severity and message and DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffff0000WeakestAuras|r " .. tostring(message), 1, 0.3, 0.3)
	end
end

function WA.ClearWarningsFor(uid)
	if not uid then return end
	if not warnings[uid] and not printed[uid] then return end
	warnings[uid] = nil
	printed[uid] = nil
	pokeList()
end

-- Drops every key under one namespace, for a source whose keys name the code
-- site they came from and so cannot be cleared one at a time.
function WA.ClearWarningPrefix(uid, prefix)
	local own = uid and warnings[uid]
	if not own then return end
	local n = string.len(prefix)
	local doomed = {}
	for key in pairs(own) do
		if string.sub(key, 1, n) == prefix then table.insert(doomed, key) end
	end
	for i = 1, table.getn(doomed) do
		own[doomed[i]] = nil
		if printed[uid] then printed[uid][doomed[i]] = nil end
	end
	if table.getn(doomed) > 0 then pokeList() end
end

function WA.MaxWarningSeverity(uid)
	local own = uid and warnings[uid]
	if not own then return nil end
	local max
	for _, warning in pairs(own) do
		local rank = RANK[warning.severity]
		if rank and (not max or rank > RANK[max]) then max = warning.severity end
	end
	return max
end

-- Read-only, for a driver or a reader that wants the raw entries.
function WA.GetWarnings(uid)
	return uid and warnings[uid] or nil
end

-- The registry collapsed to one summary: the worst severity's icon, title and
-- look, plus a body listing every message worst-first. Returns nil when the aura
-- has nothing to report.
--
-- Upstream renders up to five strip icons from a GetAllWarnings counterpart
-- instead. One is what our row has room for: the trigger summary is pinned to
-- the strip's left edge, so every extra icon truncates it.
--
-- Each line of a mixed-severity body is labelled with its own severity, where
-- upstream prefixes an inline texture escape -- this client draws none, so
-- emitting one would print a path.
function WA.FormatWarnings(uid)
	local own = uid and warnings[uid]
	if not own then return nil end

	local maxSeverity, mixed = nil, false
	local perSeverity = {}
	for _, warning in pairs(own) do
		local rank = RANK[warning.severity]
		if rank then
			if not maxSeverity then
				maxSeverity = warning.severity
			elseif rank > RANK[maxSeverity] then
				maxSeverity = warning.severity
				mixed = true
			elseif rank < RANK[maxSeverity] then
				mixed = true
			end
			local list = perSeverity[warning.severity]
			if not list then list = {}; perSeverity[warning.severity] = list end
			table.insert(list, warning.message)
		end
	end
	if not maxSeverity then return nil end

	local body = ""
	for i = 1, table.getn(ORDER) do
		local severity = ORDER[i]
		local list = perSeverity[severity]
		for j = 1, table.getn(list or {}) do
			if body ~= "" then body = body .. "\n\n" end
			if mixed then body = body .. TITLES[severity] .. ": " end
			body = body .. list[j]
		end
	end
	return ICONS[maxSeverity], TITLES[maxSeverity], body, LOOKS[maxSeverity]
end
