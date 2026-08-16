-- WeakestAuras -- in-game probes and verification commands for the runtime
-- engine. Registers /wa probe, soundprobe, states, libs, addons, gen, load,
-- conditions, codeprobe, textprobe, texprobe, wa2probe, wa2, and cdtest.

if WeakestAuras.disabled then return end

local WA = WeakestAuras
WA.Debug = {}
local D = WA.Debug

local MAX_LOG_LINES = 500
local MAX_SLOT = 40 -- safe superset of any plausible buff/debuff cap on this client

-- ---------------------------------------------------------------------------
-- Output window: a scrollable EditBox so dumps can be Ctrl+C'd out instead of
-- scrolling off in chat. UIPanelScrollFrameTemplate is a stock Blizzard
-- template referenced by name, same "no XML of our own" approach the aura
-- list already uses with FauxScrollFrameTemplate (see OptionsFrame.lua).
-- ---------------------------------------------------------------------------

local buffer = {}
local frame, editBox

local function refresh()
	editBox:SetText(table.concat(buffer, "\n"))
end

local function ensureFrame()
	if frame then return end

	frame = CreateFrame("Frame", "WA_DebugFrame", UIParent)
	frame:SetWidth(560); frame:SetHeight(400)
	frame:SetPoint("CENTER", UIParent, "CENTER", 250, 0)
	frame:SetBackdrop(WA.Widgets.PANEL_BACKDROP)
	frame:SetBackdropColor(0, 0, 0, 1)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function() frame:StartMoving() end)
	frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
	frame:Hide()

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText("WeakestAuras Debug")
	title:SetTextColor(1, 0.82, 0)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() frame:Hide() end)

	local clearBtn = WA.Widgets.button(frame, "Clear", function() D.Clear() end)
	clearBtn:SetWidth(70)
	clearBtn:SetPoint("TOPLEFT", 12, -14)

	local selectBtn = WA.Widgets.button(frame, "Select All", function()
		editBox:SetFocus()
		editBox:HighlightText()
	end)
	selectBtn:SetWidth(90)
	selectBtn:SetPoint("LEFT", clearBtn, "RIGHT", 6, 0)

	local scroll = CreateFrame("ScrollFrame", "WA_DebugFrameScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -44)
	scroll:SetPoint("BOTTOMRIGHT", -30, 12)

	editBox = CreateFrame("EditBox", "WA_DebugFrameEditBox", scroll)
	editBox:SetMultiLine(true)
	editBox:SetAutoFocus(false)
	editBox:SetFontObject(ChatFontNormal)
	editBox:SetWidth(500)
	editBox:SetHeight(2000) -- generously tall; the scroll frame clips/scrolls it
	editBox:SetTextInsets(4, 4, 4, 4)
	editBox:SetScript("OnEscapePressed", function() editBox:ClearFocus() end)

	scroll:SetScrollChild(editBox)
end

function D.Log(line)
	ensureFrame()
	table.insert(buffer, line)
	if table.getn(buffer) > MAX_LOG_LINES then
		table.remove(buffer, 1)
	end
	refresh()
	frame:Show()
end

function D.Clear()
	buffer = {}
	if editBox then refresh() end
end

function D.Show()
	ensureFrame()
	frame:Show()
end

-- ---------------------------------------------------------------------------
-- /wa dump [unit] [filter] -- settles: exact AuraData field shapes, whether
-- `name` ever carries a "(Rank N)" suffix, and where the list actually
-- terminates (the buff-cap blind-spot question).
-- ---------------------------------------------------------------------------

local function dumpOne(unit, filter)
	D.Log(string.format("--- dump unit=%s filter=%s ---", unit, filter))
	local found, highest = 0, 0
	for i = 1, MAX_SLOT do
		local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
		if aura then
			found = found + 1
			highest = i
			local remain = -1
			if aura.expirationTime and aura.expirationTime > 0 then
				remain = aura.expirationTime - GetTime()
			end
			D.Log(string.format(
				"  i=%d name=%s apps=%s spellId=%s dispel=%s helpful=%s harmful=%s dur=%s exp=%s remain=%.1f src=%s srcGUID=%s",
				i, tostring(aura.name), tostring(aura.applications), tostring(aura.spellId), tostring(aura.dispelName),
				tostring(aura.isHelpful), tostring(aura.isHarmful), tostring(aura.duration), tostring(aura.expirationTime),
				remain, tostring(aura.sourceUnit), tostring(aura.sourceGUID)))
		end
	end
	D.Log(string.format("--- end dump: %d aura(s), highest occupied slot=%d (scanned 1..%d) ---", found, highest, MAX_SLOT))
end

function D.Dump(unit, filter)
	if not unit or unit == "" then unit = "player" end
	if filter and filter ~= "" then
		dumpOne(unit, string.upper(filter))
	else
		dumpOne(unit, "HELPFUL")
		dumpOne(unit, "HARMFUL")
	end
end

-- ---------------------------------------------------------------------------
-- /wa watch [unit] -- settles: does UNIT_AURA actually fire on every aura
-- change (including a same-buff refresh), or does it miss some the way
-- pfUI's own comment claims on their server? Diffs a snapshot on a timer and
-- flags any change that happened without a UNIT_AURA fire in that window.
-- ---------------------------------------------------------------------------

local WATCH_FILTERS = { "HELPFUL", "HARMFUL" }

local watch = {
	active = {},       -- [unit] = true
	lastSnapshot = {},  -- [unit] = { [filter..index] = packed string }
	eventSeen = {},     -- [unit] = true/false since last tick
	ticker = nil,
	eventFrame = nil,
}

local function snapshotUnit(unit)
	local snap = {}
	for f = 1, table.getn(WATCH_FILTERS) do
		local filter = WATCH_FILTERS[f]
		for i = 1, MAX_SLOT do
			local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
			if aura then
				snap[filter .. i] = tostring(aura.name) .. "|" .. tostring(aura.applications) .. "|" ..
					tostring(aura.duration) .. "|" .. tostring(aura.expirationTime)
			end
		end
	end
	return snap
end

local function diffAndLog(unit)
	local old = watch.lastSnapshot[unit] or {}
	local new = snapshotUnit(unit)
	for f = 1, table.getn(WATCH_FILTERS) do
		local filter = WATCH_FILTERS[f]
		for i = 1, MAX_SLOT do
			local key = filter .. i
			if old[key] ~= new[key] then
				D.Log(string.format("[watch:%s] %s slot %d changed: %s -> %s (UNIT_AURA seen: %s)",
					unit, filter, i, tostring(old[key]), tostring(new[key]), tostring(watch.eventSeen[unit] and true or false)))
			end
		end
	end
	watch.lastSnapshot[unit] = new
	watch.eventSeen[unit] = false
end

local function tickWatch()
	for unit in pairs(watch.active) do
		diffAndLog(unit)
	end
end

local function ensureWatchRunning()
	if not watch.eventFrame then
		watch.eventFrame = CreateFrame("Frame")
		watch.eventFrame:RegisterEvent("UNIT_AURA")
		watch.eventFrame:SetScript("OnEvent", function()
			if watch.active[arg1] then
				watch.eventSeen[arg1] = true
			end
		end)
	end
	if not watch.ticker then
		watch.ticker = C_Timer.NewTicker(0.5, tickWatch)
	end
end

function D.ToggleWatch(unit)
	if not unit or unit == "" then unit = "player" end
	if watch.active[unit] then
		watch.active[unit] = nil
		D.Log("[watch] stopped watching " .. unit)
	else
		watch.active[unit] = true
		watch.lastSnapshot[unit] = snapshotUnit(unit)
		watch.eventSeen[unit] = false
		D.Log("[watch] started watching " .. unit .. " (diffing every 0.5s against UNIT_AURA)")
		ensureWatchRunning()
	end
end

-- ---------------------------------------------------------------------------
-- /wa events [EVENT ...] -- raw event firehose, unfiltered and independent of
-- /wa watch's per-unit bookkeeping: logs every fire with its whole payload, so
-- the actual stream can be read instead of inferred from diffs (does it ever
-- double-fire for one change? fire for a unit nobody's watching?). Defaults to
-- UNIT_AURA. Naming events is how an unfamiliar one's argument order gets
-- settled -- a doc listing an order is not evidence of it on this client.
-- ---------------------------------------------------------------------------

local eventLogFrame
local eventLogActive = false
local eventLogCount = 0
local eventLogNames = {}

-- The payload as "arg1=x arg3=y", skipping the trailing nils a shorter event
-- leaves behind.
local function eventLogPayload()
	local vals = { arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9 }
	local parts = {}
	for i = 1, 9 do
		if vals[i] ~= nil then
			table.insert(parts, "arg" .. i .. "=" .. tostring(vals[i]))
		end
	end
	if table.getn(parts) == 0 then return "(no args)" end
	return table.concat(parts, " ")
end

function D.ToggleEventLog(rest)
	if eventLogActive then
		eventLogActive = false
		for i = 1, table.getn(eventLogNames) do
			eventLogFrame:UnregisterEvent(eventLogNames[i])
		end
		D.Log(string.format("[events] stopped (%d fire(s) logged this session)", eventLogCount))
		return
	end

	local wanted = {}
	for name in string.gfind(rest or "", "%S+") do
		table.insert(wanted, string.upper(name))
	end
	if table.getn(wanted) == 0 then wanted = { "UNIT_AURA" } end

	if not eventLogFrame then
		eventLogFrame = CreateFrame("Frame")
		eventLogFrame:SetScript("OnEvent", function()
			eventLogCount = eventLogCount + 1
			D.Log(string.format("[events] #%d t=%.2f %s %s",
				eventLogCount, GetTime(), event, eventLogPayload()))
		end)
	end

	eventLogNames = {}
	for i = 1, table.getn(wanted) do
		local name = wanted[i]
		-- RegisterEvent throws on a name this client doesn't know, which is
		-- itself the answer when the question is whether the event exists here.
		if pcall(function() eventLogFrame:RegisterEvent(name) end) then
			table.insert(eventLogNames, name)
		else
			D.Log("[events] " .. name .. " -- refused by the client, no such event")
		end
	end
	eventLogActive = true
	if table.getn(eventLogNames) == 0 then
		D.Log("[events] started, but nothing registered")
	else
		D.Log("[events] started on: " .. table.concat(eventLogNames, ", "))
	end
end

-- ---------------------------------------------------------------------------
-- /wa auraprobe [unit|all] -- Nampower's aura-cast events, decoded against the
-- watched unit's harmful descriptor. The question is whether a debuff the
-- descriptor never transmits (only 16 harmful slots exist, and a raid boss
-- carries more) is still knowable: whether AURA_CAST_ON_OTHER carries *other*
-- players' casts and not only ours, whether arg9's debuff-bar-full bit sets,
-- whether arg8 is a real talented duration, and whether an aura it reports is
-- one /wa dump cannot see.
--
-- Arg order is taken from two working consumers on this client,
-- ../SuperCleveRoidMacros/NampowerAPI.lua and ../pfUI/libs/libdebuff.lua:
--   arg1 spellId  arg2 casterGuid  arg3 targetGuid  arg4 effect
--   arg5 effectAuraName (a numeric aura type, whatever the name suggests)
--   arg6 effectAmplitude (a periodic effect's tick period, ms)
--   arg7 effectMiscValue  arg8 durationMs
--   arg9 auraCapStatus (bit 1 buff bar full, bit 2 debuff bar full)
-- The SELF/OTHER split is by *target*, not by caster.
-- ---------------------------------------------------------------------------

local AURA_CAST_EVENTS = { "AURA_CAST_ON_SELF", "AURA_CAST_ON_OTHER" }
local AURA_CAST_CVAR = "NP_EnableAuraCastEvents"
local AURA_CAST_MIN = "2.20.0"
local AURA_CAST_DEDUPE = 0.1 -- pfUI's window: one event fires per spell *effect*
local AURA_CAST_SETTLE = 2   -- the cast event precedes the descriptor update
local HARMFUL_SLOTS = 16     -- descriptor slots 32..47; see design/client/gotchas.md

local auraProbe = { registered = {}, session = 0, stats = {} }

local function auraProbeReset()
	auraProbe.n = 0
	auraProbe.last = {}
	auraProbe.pending = 0
	auraProbe.stats = {
		seen = 0, elsewhere = 0, onSelf = 0, onOther = 0,
		byPlayer = 0, byOther = 0, dupes = 0,
		capDebuff = 0, capBuff = 0, capNil = 0, zeroDur = 0,
		hit = 0, miss = 0, overflow = 0,
	}
end

-- GUIDs arrive as strings from two different sources here (Nampower's event and
-- the client's UnitGUID), so they are compared case-insensitively rather than
-- assumed to agree on hex case.
local function sameGuid(a, b)
	if not a or not b then return false end
	return string.lower(tostring(a)) == string.lower(tostring(b))
end

local function shortGuid(guid)
	local s = tostring(guid)
	if string.len(s) > 6 then return "~" .. string.sub(s, -6) end
	return s
end

-- nil when the token is not addressable at all, which a raw GUID used as a unit
-- token may well not be -- that is one of the things being probed.
local function harmfulScan(unit, wantSpellId)
	local count, highest, slot = 0, 0, nil
	local ok = pcall(function()
		for i = 1, MAX_SLOT do
			local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
			if aura then
				count = count + 1
				highest = i
				if wantSpellId and not slot and aura.spellId == wantSpellId then slot = i end
			end
		end
	end)
	if not ok then return nil end
	return count, highest, slot
end

local function capBits(status)
	local n = tonumber(status)
	if not n then return nil end
	return math.mod(n, 2) == 1, math.mod(math.floor(n / 2), 2) == 1
end

-- The descriptor lags the cast event, so the read that settles "did this one get
-- a slot?" is the one taken a couple of seconds later.
local function auraProbeCheckLater(unit, guid, spellId, name)
	local session = auraProbe.session
	auraProbe.pending = auraProbe.pending + 1
	C_Timer.After(AURA_CAST_SETTLE, function()
		if auraProbe.session ~= session then return end
		auraProbe.pending = auraProbe.pending - 1
		local label = string.format("[auraprobe]   +%ds %s(%s):", AURA_CAST_SETTLE, tostring(name), tostring(spellId))
		if not sameGuid(UnitGUID and UnitGUID(unit), guid) then
			D.Log(label .. " " .. unit .. " is a different unit now, cross-check skipped")
			return
		end
		local count, _, slot = harmfulScan(unit, spellId)
		if not count then
			D.Log(label .. " " .. unit .. " is no longer readable, cross-check skipped")
		elseif slot then
			auraProbe.stats.hit = auraProbe.stats.hit + 1
			D.Log(string.format("%s descriptor HIT slot %d (harm=%d)", label, slot, count))
		else
			auraProbe.stats.miss = auraProbe.stats.miss + 1
			if count >= HARMFUL_SLOTS then
				auraProbe.stats.overflow = auraProbe.stats.overflow + 1
				D.Log(string.format("%s descriptor MISS at harm=%d -- OVERFLOW, /wa dump cannot see this one", label, count))
			else
				D.Log(string.format("%s descriptor MISS at harm=%d -- not full, so it expired, was resisted, or never applied", label, count))
			end
		end
	end)
end

local function auraProbeEvent()
	local spellId, casterGuid, targetGuid = arg1, arg2, arg3
	local effect, auraName, amplitude, misc = arg4, arg5, arg6, arg7
	local durationMs, capStatus = arg8, arg9
	local st = auraProbe.stats
	st.seen = st.seen + 1

	if auraProbe.unit and not sameGuid(targetGuid, UnitGUID and UnitGUID(auraProbe.unit)) then
		st.elsewhere = st.elsewhere + 1
		return
	end

	if event == "AURA_CAST_ON_SELF" then st.onSelf = st.onSelf + 1 else st.onOther = st.onOther + 1 end

	local now = GetTime()
	local key = tostring(targetGuid) .. "|" .. tostring(spellId) .. "|" .. tostring(casterGuid)
	local prev = auraProbe.last[key]
	local dup = prev and (now - prev) < AURA_CAST_DEDUPE
	auraProbe.last[key] = now
	if dup then st.dupes = st.dupes + 1 end

	local mine = sameGuid(casterGuid, auraProbe.playerGuid)
	if mine then st.byPlayer = st.byPlayer + 1 else st.byOther = st.byOther + 1 end
	local casterLabel = "you"
	if not mine then
		casterLabel = "OTHER " .. shortGuid(casterGuid)
		-- SuperWoW makes a GUID a unit token, but whether an arbitrary caster
		-- resolves through one is part of what this probe answers.
		local ok, nm = pcall(UnitName, casterGuid)
		if ok and nm then casterLabel = casterLabel .. " " .. nm end
	end

	local buffFull, debuffFull = capBits(capStatus)
	if capStatus == nil then st.capNil = st.capNil + 1 end
	if debuffFull then st.capDebuff = st.capDebuff + 1 end
	if buffFull then st.capBuff = st.capBuff + 1 end
	local capText = tostring(capStatus)
	if debuffFull then capText = capText .. "(debuff-full)" end
	if buffFull then capText = capText .. "(buff-full)" end

	local ms = tonumber(durationMs)
	if not ms or ms == 0 then st.zeroDur = st.zeroDur + 1 end

	local count, highest = harmfulScan(auraProbe.unit or targetGuid)
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellId)

	auraProbe.n = auraProbe.n + 1
	D.Log(string.format(
		"[auraprobe] #%d %s %s(%s) by %s -> %s harm=%s%s dur=%s cap=%s eff=%s aura=%s amp=%s misc=%s%s",
		auraProbe.n,
		event == "AURA_CAST_ON_SELF" and "SELF " or "OTHER",
		tostring(name), tostring(spellId), casterLabel, shortGuid(targetGuid),
		tostring(count), (count and count >= HARMFUL_SLOTS) and " FULL" or "",
		ms and string.format("%.1fs", ms / 1000) or tostring(durationMs),
		capText, tostring(effect), tostring(auraName), tostring(amplitude), tostring(misc),
		dup and " DUP" or ""))
	if highest and count and highest > count then
		D.Log(string.format("[auraprobe]   ^ descriptor has a gap: %d aura(s) but highest slot %d", count, highest))
	end

	if auraProbe.unit and not dup then
		auraProbeCheckLater(auraProbe.unit, targetGuid, spellId, name)
	end
end

local function auraProbeStop()
	auraProbe.active = false
	for i = 1, table.getn(auraProbe.registered) do
		auraProbe.frame:UnregisterEvent(auraProbe.registered[i])
	end
	auraProbe.registered = {}

	local st = auraProbe.stats
	local where = auraProbe.unit or "any unit"
	D.Log("--- auraprobe summary ---")
	D.Log(string.format("  %d event(s) fired, %d on another unit, %d logged on %s",
		st.seen, st.elsewhere, auraProbe.n, where))
	D.Log(string.format("  event split on %s: ON_SELF %d, ON_OTHER %d", where, st.onSelf, st.onOther))
	D.Log(string.format("  caster split on %s: you %d, someone else %d   <- Q2, the load-bearing one",
		where, st.byPlayer, st.byOther))
	D.Log(string.format("  arg9: debuff-bar-full %d, buff-bar-full %d, nil %d   <- Q3",
		st.capDebuff, st.capBuff, st.capNil))
	D.Log(string.format("  arg8: %d carried a duration, %d were zero   <- Q4",
		auraProbe.n - st.zeroDur, st.zeroDur))
	D.Log(string.format("  descriptor at +%ds: %d hit, %d miss, %d of those missed while full   <- Q5",
		AURA_CAST_SETTLE, st.hit, st.miss, st.overflow))
	D.Log(string.format("  %d event(s) landed inside the %.1fs dedupe window (multi-effect spells)",
		st.dupes, AURA_CAST_DEDUPE))
	if auraProbe.pending > 0 then
		D.Log(string.format("  %d cross-check(s) still pending; their lines follow this summary",
			auraProbe.pending))
	end
	D.Log("--- end auraprobe ---")
end

function D.AuraProbe(rest)
	if auraProbe.active then
		auraProbeStop()
		return
	end

	local _, _, word = string.find(string.lower(rest or ""), "^%s*(%S*)")
	local unit = "target"
	if word == "all" then unit = nil
	elseif word ~= "" then unit = word end

	auraProbe.session = auraProbe.session + 1
	auraProbeReset()
	auraProbe.unit = unit
	auraProbe.playerGuid = (UnitGUID and UnitGUID("player")) or (GetPlayerGuid and GetPlayerGuid())

	D.Log("--- auraprobe ---")

	if not WA.hasNampower then
		D.Log("  GetNampowerVersion absent -- no aura-cast events on this client")
	else
		local ok, major, minor, patch = pcall(GetNampowerVersion)
		if not ok or not major then
			D.Log("  GetNampowerVersion did not answer")
		else
			minor, patch = minor or 0, patch or 0
			local have = WA.ParseVersion(major .. "." .. minor .. "." .. patch)
			local need = WA.ParseVersion(AURA_CAST_MIN)
			D.Log(string.format("  Nampower %s.%s.%s, aura-cast events need %s: %s   <- Q1",
				tostring(major), tostring(minor), tostring(patch), AURA_CAST_MIN,
				(have and have >= need) and "OK" or "TOO OLD"))
		end
	end

	-- Nampower sends nothing at all with this CVar off, so the probe turns it on
	-- rather than reporting an empty stream as a negative result.
	if type(GetCVar) ~= "function" then
		D.Log("  GetCVar absent -- cannot read " .. AURA_CAST_CVAR .. "   <- Q1")
	else
		local ok, value = pcall(GetCVar, AURA_CAST_CVAR)
		D.Log(string.format("  %s = %s   <- Q1", AURA_CAST_CVAR, ok and tostring(value) or "unreadable"))
		if ok and value ~= "1" and type(SetCVar) == "function" then
			pcall(SetCVar, AURA_CAST_CVAR, "1")
			local reread, after = pcall(GetCVar, AURA_CAST_CVAR)
			D.Log("  set it to 1 -> reads back " .. (reread and tostring(after) or "unreadable"))
		end
	end

	-- The overflow cache drops helpful auras on this classifier's word, so a
	-- client whose ClassicAPI does not carry it caches more than it needs to.
	if not (C_Spell and C_Spell.IsSpellHarmful) then
		D.Log("  C_Spell.IsSpellHarmful absent -- helpful auras cannot be filtered out")
	else
		local okHarm, harmful = pcall(C_Spell.IsSpellHarmful, 9835)
		local okHelp, helpful = pcall(C_Spell.IsSpellHarmful, 1126)
		D.Log(string.format("  C_Spell.IsSpellHarmful: Moonfire(9835)=%s, Mark of the Wild(1126)=%s (want true, false)",
			okHarm and tostring(harmful) or "errored", okHelp and tostring(helpful) or "errored"))
	end

	if not auraProbe.frame then
		auraProbe.frame = CreateFrame("Frame")
		auraProbe.frame:SetScript("OnEvent", function() WA.safecall("auraprobe", auraProbeEvent) end)
	end
	for i = 1, table.getn(AURA_CAST_EVENTS) do
		local name = AURA_CAST_EVENTS[i]
		-- RegisterEvent throws on an event this client does not know, which is
		-- itself the answer when the question is whether it exists here.
		if pcall(function() auraProbe.frame:RegisterEvent(name) end) then
			table.insert(auraProbe.registered, name)
		else
			D.Log("  " .. name .. " -- refused by the client, no such event")
		end
	end
	D.Log("  registered: " .. (table.getn(auraProbe.registered) > 0
		and table.concat(auraProbe.registered, ", ") or "nothing"))

	D.Log("  player GUID " .. tostring(auraProbe.playerGuid))
	if unit then
		local count, highest = harmfulScan(unit)
		D.Log(string.format("  watching %s (guid %s): %s harmful aura(s) now, highest slot %s",
			unit, tostring(UnitGUID and UnitGUID(unit)), tostring(count), tostring(highest)))
	else
		D.Log("  watching every target -- no descriptor cross-check without a unit token, and a raid is a firehose")
	end
	auraProbe.active = true
	D.Log("  running -- /wa auraprobe again to stop and print the summary")
end

-- ---------------------------------------------------------------------------
-- /wa overflow [unit] -- what the overflow cache holds for a unit, how long each
-- entry has left, and whether the trust gate currently lets any of it be used.
-- Runs the same reconcile a trigger would, so it evicts as it reports: the dump
-- is the state a scan would see, not the state before one.
-- ---------------------------------------------------------------------------

function D.Overflow(rest)
	local _, _, word = string.find(string.lower(rest or ""), "^%s*(%S*)")
	local unit = (word ~= "" and word) or "target"
	local AO = WA.AuraOverflow

	D.Log("--- overflow " .. unit .. " ---")
	if not (AO and AO.Enabled()) then
		D.Log("  the cache is not running -- Nampower absent or below 2.20")
		D.Log("--- end overflow ---")
		return
	end
	D.Log("  global toggle: " .. (WA.Options().auraOverflow == false and "OFF" or "on"))

	local guid = UnitGUID and UnitGUID(unit)
	if not guid then
		D.Log("  " .. unit .. " has no GUID")
		D.Log("--- end overflow ---")
		return
	end

	local gate, count = AO.Reconcile(unit, guid)
	D.Log(string.format("  %s guid %s, harmful descriptor %s/%d -- trust gate %s",
		unit, tostring(guid), tostring(count), HARMFUL_SLOTS, gate and "PASSES" or "fails"))

	local now = GetTime()
	local entries = AO.EntriesFor(guid) or {}
	local n = table.getn(entries)
	for i = 1, n do
		local e = entries[i]
		local remain = "unknown"
		if e.duration > 0 then remain = string.format("%.1fs", (e.start + e.duration) - now) end
		D.Log(string.format("  %s(%s) caster=%s remain=%s age=%.1fs capped=%s",
			tostring(e.name), tostring(e.spellId), tostring(e.caster), remain,
			now - e.start, tostring(AO.WasCapped(e))))
	end
	D.Log(string.format("  %d entry(ies)%s", n,
		gate and "" or " -- none of them can be surfaced while the gate fails"))
	D.Log("--- end overflow ---")
end

-- ---------------------------------------------------------------------------
-- /wa linkprobe -- which entry point, if any, a shift-clicked item actually
-- reaches on this client. Vanilla FrameXML routes a bag shift-click straight
-- into ChatEdit_InsertLink (and only when the chat box is open);
-- HandleModifiedItemClick is a later-expansion function that may not exist
-- here at all, and a replacement bag UI bypasses both. Wraps every candidate
-- and logs which one fires, so the answer comes from a click rather than a doc.
-- ---------------------------------------------------------------------------

local linkProbeOn = false

function D.LinkProbe()
	local names = {
		"HandleModifiedItemClick", "ChatEdit_InsertLink", "SetItemRef",
		"ContainerFrameItemButton_OnClick", "PickupContainerItem",
		"IsModifiedClick", "GetContainerItemLink",
	}
	for i = 1, table.getn(names) do
		D.Log("[link] " .. names[i] .. " = " .. type(getglobal(names[i])))
	end
	D.Log("[link] chat edit box visible = "
		.. tostring(ChatFrameEditBox and ChatFrameEditBox:IsVisible() and true or false))

	if linkProbeOn then
		D.Log("[link] already logging -- shift-click an item in your bags now")
		return
	end
	linkProbeOn = true

	-- Each wrapper logs and calls through, so nothing it touches changes
	-- behaviour. Left installed for the session: these are cold paths.
	for i = 1, table.getn(names) do
		local name = names[i]
		local orig = getglobal(name)
		if type(orig) == "function" then
			setglobal(name, function(a1, a2, a3, a4)
				D.Log("[link] " .. name .. "(" .. tostring(a1) .. ", " .. tostring(a2) .. ")")
				return orig(a1, a2, a3, a4)
			end)
		end
	end
	D.Log("[link] logging installed -- now shift-click an item in your bags")
end

-- ---------------------------------------------------------------------------
-- /wa timers -- what C_Timer offers a scheduler that has to retract a pending
-- callback. Two questions a type check cannot answer on its own: whether After
-- hands back any handle at all, and whether a Cancel that returns cleanly
-- actually suppresses the callback rather than just not erroring. Both are
-- settled behaviourally here, by scheduling one of each and reporting which
-- ones fired after the deadline has passed.
-- ---------------------------------------------------------------------------

function D.Timers()
	if type(C_Timer) ~= "table" then
		D.Log("[timers] C_Timer is " .. type(C_Timer) .. " -- nothing to probe")
		return
	end
	D.Log("[timers] After=" .. type(C_Timer.After)
		.. " NewTimer=" .. type(C_Timer.NewTimer)
		.. " NewTicker=" .. type(C_Timer.NewTicker))

	local fired = {}
	local function shape(label, h)
		local s = "[timers] " .. label .. " returned " .. type(h)
		if type(h) == "table" then s = s .. " (Cancel=" .. type(h.Cancel) .. ")" end
		D.Log(s)
	end

	if type(C_Timer.After) ~= "function" then
		D.Log("[timers] no After -- the rest of this probe cannot run")
		return
	end
	shape("After", C_Timer.After(1, function() fired.after = true end))

	local cancelled
	if type(C_Timer.NewTimer) == "function" then
		shape("NewTimer", C_Timer.NewTimer(1, function() fired.newtimer = true end))
		cancelled = C_Timer.NewTimer(1, function() fired.cancelled = true end)
	end

	if type(cancelled) == "table" and type(cancelled.Cancel) == "function" then
		local ok, err = pcall(function() cancelled:Cancel() end)
		D.Log("[timers] Cancel() " .. (ok and "returned cleanly" or ("errored: " .. tostring(err))))
	else
		D.Log("[timers] no cancellable handle -- a generation counter on the owner is the fallback")
	end

	local t0 = GetTime()
	C_Timer.After(2, function()
		D.Log(string.format("[timers] +%.2fs elapsed -- After fired=%s NewTimer fired=%s cancelled fired=%s",
			GetTime() - t0,
			tostring(fired.after and true or false),
			tostring(fired.newtimer and true or false),
			tostring(fired.cancelled and true or false)))
		D.Log("[timers] a cancelled timer reading true means Cancel does not suppress the callback")
	end)
	D.Log("[timers] scheduled -- results in ~2s. No follow-up line at all means After never fired.")
end

-- ---------------------------------------------------------------------------
-- /wa cdtest -- settles: can we render a native cooldown swipe on this client?
-- CreateFrame("Cooldown", ...) throws "Unknown frame type" here, but in vanilla
-- the swipe is really a 3D Model, so the working constructor is a "Model" frame
-- inheriting CooldownFrameTemplate -- the technique CooldownTracker uses on this
-- exact client (../reference/CooldownTracker/CooldownTracker.lua:502). This
-- probes that path; if the spiral shows in-world, the Icon region can adopt it.
-- ---------------------------------------------------------------------------

local cdTestFrame
local cdTestFailed = false

-- Guarded with pcall so a client that lacks CooldownFrameTemplate/the Model type
-- re-logs the finding instead of erroring on every re-run.
function D.CooldownTest()
	if cdTestFailed then
		D.Log("[cdtest] native cooldown swipe is not available on this client -- already confirmed, see previous log line.")
		return
	end

	if not cdTestFrame then
		cdTestFrame = CreateFrame("Frame", nil, UIParent)
		cdTestFrame:SetWidth(48); cdTestFrame:SetHeight(48)
		cdTestFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 150)

		local icon = cdTestFrame:CreateTexture(nil, "ARTWORK")
		icon:SetAllPoints(cdTestFrame)
		icon:SetTexture("Interface\\Icons\\Spell_Nature_LightningShield")

		local ok, cooldown = pcall(CreateFrame, "Model", nil, cdTestFrame, "CooldownFrameTemplate")
		if not ok or not cooldown then
			cdTestFailed = true
			D.Log("[cdtest] CreateFrame(\"Model\", ..., \"CooldownFrameTemplate\") failed: " .. tostring(cooldown) ..
				" -- no native cooldown swipe on this client; Icon region stays text-only.")
			return
		end
		cdTestFrame.cooldown = cooldown
		-- The Model swipe underfills and sits bottom-left at scale 1; CooldownTracker
		-- fixes it with SetScale((1/32)*iconSize) + a two-corner anchor (its
		-- CalculateCooldownScale, line 505-512). iconSize here is 48.
		cooldown:SetAllPoints(cdTestFrame)
		cooldown:SetScale(48 / 32)
		cooldown:ClearAllPoints()
		cooldown:SetPoint("TOPLEFT", cdTestFrame, "TOPLEFT")
		cooldown:SetPoint("BOTTOMRIGHT", cdTestFrame, "BOTTOMRIGHT")
		D.Log("[cdtest] CreateFrame(\"Model\", ..., \"CooldownFrameTemplate\") succeeded, scaled 48/32 -- watch for the swipe.")
	end
	cdTestFrame:Show()
	cdTestFrame.cooldown:Show()
	CooldownFrame_SetTimer(cdTestFrame.cooldown, GetTime(), 10, 1)
	D.Log("[cdtest] armed a 10s swipe on a test icon at CENTER,0,150 -- watch it in-world (not in this window). If it sweeps, the Model swipe works here.")
end

-- ---------------------------------------------------------------------------
-- /wa swipetest [sizes...] + /wa swipenudge <k> [yflat] -- fast, no-/reload
-- loop for tuning RegionPrototype.lua's SizeSwipe alignment constants.
-- swipetest spawns one real icon+swipe rig per size (default 16/32/64/128)
-- side by side so drift across sizes is visible in one screenshot; swipenudge
-- writes WA.regionPrototype.swipeNudgeK/swipeYFlat live and re-sizes every
-- active rig immediately, since SizeSwipe re-reads those fields on every call.
-- ---------------------------------------------------------------------------

local swipeTestRigs = {}
local swipeTestTicker
local SWIPE_TEST_DURATION = 6

-- Re-arms every active rig on a fresh 6s cycle -- CooldownFrame_SetTimer
-- doesn't loop on its own, so this ticker (period == duration) restarts each
-- swipe right as the previous one finishes.
local function swipeTestLoop()
	for i = 1, table.getn(swipeTestRigs) do
		local rig = swipeTestRigs[i]
		WA.regionPrototype.ArmSwipe(rig.swipe, GetTime() + SWIPE_TEST_DURATION, SWIPE_TEST_DURATION)
	end
end

function D.SwipeTest(sizesStr)
	for i = table.getn(swipeTestRigs), 1, -1 do
		swipeTestRigs[i]:Hide()
		swipeTestRigs[i] = nil
	end
	if swipeTestTicker then swipeTestTicker:Cancel(); swipeTestTicker = nil end

	if sizesStr == "0" then
		D.Log("[swipetest] cleared")
		return
	end

	-- Each entry is {w=, h=} -- a bare "64" means square (w=h=64), "64x32"
	-- means non-square, for testing swipeStretchMode against a real W ~= H.
	local sizes = {}
	if sizesStr and sizesStr ~= "" then
		local rest = sizesStr
		while true do
			local _, e, wStr, hStr = string.find(rest, "^%s*(%d+)x(%d+)")
			if wStr then
				table.insert(sizes, { w = tonumber(wStr), h = tonumber(hStr) })
				rest = string.sub(rest, e + 1)
			else
				local _, e2, numStr = string.find(rest, "^%s*(%d+)")
				if not numStr then break end
				table.insert(sizes, { w = tonumber(numStr), h = tonumber(numStr) })
				rest = string.sub(rest, e2 + 1)
			end
		end
	end
	if table.getn(sizes) == 0 then
		sizes = { { w = 16, h = 16 }, { w = 32, h = 32 }, { w = 64, h = 64 }, { w = 128, h = 128 } }
	end

	-- Enrage (5229) instead of a hardcoded texture -- brighter icon, easier to
	-- eyeball the swipe edge against than the dark LightningShield art.
	local _, _, testIcon = GetSpellInfo(5229)
	testIcon = testIcon or "Interface\\Icons\\Spell_Nature_LightningShield"

	-- Edge-tracked, not "prev size + gap": a flat per-icon increment ignores
	-- the NEXT icon's own half-width, so consecutive very-different sizes
	-- (64 -> 128) would actually overlap instead of just looking cramped.
	local gap = 30
	local rightEdge = -300
	for i = 1, table.getn(sizes) do
		local w, h = sizes[i].w, sizes[i].h
		local x = rightEdge + gap + w / 2
		rightEdge = x + w / 2

		local rig = CreateFrame("Frame", nil, UIParent)
		rig:SetWidth(w); rig:SetHeight(h)
		rig:SetPoint("CENTER", UIParent, "CENTER", x, 150)

		local tex = rig:CreateTexture(nil, "ARTWORK")
		tex:SetAllPoints(rig)
		tex:SetTexture(testIcon)
		tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)

		rig.swipe = WA.regionPrototype.CreateSwipe(rig)
		WA.regionPrototype.SizeSwipe(rig.swipe, w, h)
		WA.regionPrototype.ArmSwipe(rig.swipe, GetTime() + SWIPE_TEST_DURATION, SWIPE_TEST_DURATION)
		if rig.swipe then rig.swipe:Show() end

		local label = rig:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		label:SetPoint("TOP", rig, "BOTTOM", 0, -4)
		label:SetText(w == h and (tostring(w) .. "px") or (tostring(w) .. "x" .. tostring(h)))

		rig:Show()
		table.insert(swipeTestRigs, rig)
	end
	swipeTestTicker = C_Timer.NewTicker(SWIPE_TEST_DURATION, swipeTestLoop)
	D.Log("[swipetest] spawned " .. table.getn(swipeTestRigs) .. " rig(s) at CENTER,*,150, looping every " ..
		SWIPE_TEST_DURATION .. "s -- /wa swipenudge <k> [yflat] to tune live, /wa swipetest (no args) to respawn defaults, /wa swipetest 0 to clear")
end

function D.SwipeNudge(rest)
	local _, _, kStr, yStr = string.find(rest or "", "^(%S*)%s*(%S*)$")
	local k = tonumber(kStr)
	if not k then
		D.Log(string.format("[swipenudge] current: swipeNudgeK=%s swipeYFlat=%s -- usage: /wa swipenudge <k> [yflat]",
			tostring(WA.regionPrototype.swipeNudgeK), tostring(WA.regionPrototype.swipeYFlat)))
		return
	end
	local y = tonumber(yStr)
	WA.regionPrototype.swipeNudgeK = k
	if y then WA.regionPrototype.swipeYFlat = y end
	for i = 1, table.getn(swipeTestRigs) do
		local rig = swipeTestRigs[i]
		WA.regionPrototype.SizeSwipe(rig.swipe, rig:GetWidth(), rig:GetHeight())
	end
	D.Log(string.format("[swipenudge] swipeNudgeK=%s swipeYFlat=%s -- re-sized %d active rig(s)",
		tostring(WA.regionPrototype.swipeNudgeK), tostring(WA.regionPrototype.swipeYFlat), table.getn(swipeTestRigs)))
end

-- ---------------------------------------------------------------------------
-- /wa track <spellName> -- settles: is the player's own duration/
-- expirationTime actually monotonic and does it reset cleanly on recast, or
-- does it exhibit the same flakiness DoiteAuras had to work around?
-- ---------------------------------------------------------------------------

local trackSpell
local trackTicker

local function trackTick()
	if not trackSpell then return end
	local found
	for i = 1, MAX_SLOT do
		local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
		if not aura then break end
		if aura.name == trackSpell then
			found = aura
			break
		end
	end
	if found then
		local remain = -1
		if found.expirationTime and found.expirationTime > 0 then
			remain = found.expirationTime - GetTime()
		end
		D.Log(string.format("[track] t=%.1f %s stacks=%s dur=%s exp=%s remain=%.1f",
			GetTime(), trackSpell, tostring(found.applications), tostring(found.duration),
			tostring(found.expirationTime), remain))
	else
		D.Log(string.format("[track] t=%.1f %s NOT FOUND", GetTime(), trackSpell))
	end
end

function D.Track(spellName)
	if not spellName or spellName == "" then
		trackSpell = nil
		if trackTicker then trackTicker:Cancel(); trackTicker = nil end
		D.Log("[track] stopped")
		return
	end
	trackSpell = spellName
	D.Log("[track] now tracking \"" .. spellName .. "\" (logging every 1s)")
	if not trackTicker then
		trackTicker = C_Timer.NewTicker(1, trackTick)
	end
end

-- ---------------------------------------------------------------------------
-- /wa states <id> -- dumps triggerState[id]: the combination flags and every
-- trigger's per-clone states. The single most useful command for debugging the
-- state machine -- shows what the producers wrote and what the glue resolved.
-- ---------------------------------------------------------------------------

local STATE_FIELDS = {
	"show", "changed", "active", "progressType", "name", "stacks", "duration",
	"expirationTime", "value", "total", "spellId", "unit", "unitCaster",
	"initialTime", "refreshTime", "stackGainTime", "stackLostTime",
}

local function dumpState(triggernum, cloneId, state)
	local parts = {}
	for i = 1, table.getn(STATE_FIELDS) do
		local f = STATE_FIELDS[i]
		if state[f] ~= nil then
			local v = state[f]
			if f == "expirationTime" and type(v) == "number" and v > 0 then
				v = string.format("%s (rem %.1f)", tostring(v), v - GetTime())
			end
			table.insert(parts, f .. "=" .. tostring(v))
		end
	end
	D.Log(string.format("    [%d][%q] %s", triggernum, cloneId, table.concat(parts, " ")))
end

function D.States(id)
	if not id or id == "" then
		D.Log("[states] usage: /wa states <aura id>")
		return
	end
	local ts = WA.GetDisplayTriggerState and WA.GetDisplayTriggerState(id)
	if not ts then
		D.Log(string.format("[states] no triggerState for %q (unknown id, or a group)", id))
		return
	end
	local ftCount = WA.regionPrototype.CountFrameTick and WA.regionPrototype.CountFrameTick() or 0
	D.Log(string.format("--- states %q: show=%s disjunctive=%s numTriggers=%d triggerCount=%d activeMode=%s (global FrameTick subscribers: %d) ---",
		id, tostring(ts.show), tostring(ts.disjunctive), ts.numTriggers, ts.triggerCount, tostring(ts.activeTriggerMode), ftCount))
	for triggernum = 1, ts.numTriggers do
		D.Log(string.format("  trigger %d: active=%s", triggernum, tostring(ts.triggers[triggernum])))
		local allstates = ts[triggernum]
		if allstates then
			for cloneId, state in pairs(allstates) do
				dumpState(triggernum, cloneId, state)
			end
		end
	end
	D.Log("--- end states ---")
end

-- ---------------------------------------------------------------------------
-- /wa conditions <id> -- dumps data.conditions (each check + its changes) and
-- the live per-clone activation flags + whether an exact recheck timer is
-- pending. The verification tool for condition timing: confirms a
-- timer/elapsedTimer flip is scheduled rather than polled, and which
-- conditions the interpreter currently has active.
-- ---------------------------------------------------------------------------

function D.Conditions(id)
	if not id or id == "" then
		D.Log("[conditions] usage: /wa conditions <aura id>")
		return
	end
	local data = WeakestAurasDB.displays[id]
	if not data then
		D.Log("[conditions] unknown id " .. tostring(id))
		return
	end
	local conds = data.conditions or {}
	D.Log(string.format("--- conditions %q: %d condition(s) ---", id, table.getn(conds)))
	for i = 1, table.getn(conds) do
		local c = conds[i]
		local chk = c.check or {}
		D.Log(string.format("  [%d] check: trigger=%s var=%s op=%s value=%s",
			i, tostring(chk.trigger), tostring(chk.variable), tostring(chk.op), tostring(chk.value)))
		local changes = c.changes or {}
		for j = 1, table.getn(changes) do
			D.Log(string.format("       change: %s = %s", tostring(changes[j].property), tostring(changes[j].value)))
		end
	end
	if WA.GetConditionDebug then
		local _, act, pending = WA.GetConditionDebug(data.uid)
		if act then
			for cloneId, flags in pairs(act) do
				local parts = {}
				for i = 1, table.getn(conds) do table.insert(parts, tostring(flags[i] and 1 or 0)) end
				D.Log(string.format("  active[%q] = [%s]", cloneId, table.concat(parts, ",")))
			end
		end
		if pending and table.getn(pending) > 0 then
			D.Log("  pending recheck for clone(s): " .. table.concat(pending, ", "))
		else
			D.Log("  no pending timer recheck")
		end
	end
	D.Log("--- end conditions ---")
end

-- ---------------------------------------------------------------------------
-- /wa gen <id> -- dumps the Lua source ConstructFunction generated for this
-- display's generic trigger(s). A string-
-- assembly bug surfaces as readable source here rather than an opaque
-- loadstring error at Add-time.
-- ---------------------------------------------------------------------------

function D.Gen(id)
	if not id or id == "" then
		D.Log("[gen] usage: /wa gen <aura id>")
		return
	end
	local src = WA.GetGeneratedSource and WA.GetGeneratedSource(id)
	if not src then
		D.Log(string.format("[gen] no generated source for %q (not a generic trigger, or unknown id)", id))
		return
	end
	D.Log(string.format("--- generated source for %q ---", id))
	D.Log(src)
	D.Log("--- end generated source ---")
end

-- ---------------------------------------------------------------------------
-- /wa load <id> -- dumps data.load (the enabled constraints) and whether the
-- display is currently loaded (WA.IsDisplayLoaded) + what a fresh WA.EvalLoad
-- says at the time of the check. The verification tool for load state:
-- confirms an aura loads/unloads as its class/level/zone/combat/... change, and
-- that a transient-only failure reads as standby rather than not loaded.
-- ---------------------------------------------------------------------------

function D.Load(id)
	if not id or id == "" then
		D.Log("[load] usage: /wa load <aura id>")
		return
	end
	local data = WeakestAurasDB.displays[id]
	if not data then
		D.Log("[load] unknown id " .. tostring(id))
		return
	end
	local state, nLoaded, nStandby, nLeaves = WA.DisplayLoadState(id)
	if WA.IsGroup(data) then
		D.Log(string.format("[load] %q is a group: state=%s (%d loaded, %d standby of %d leaves)",
			id, state, nLoaded, nStandby, nLeaves))
		return
	end
	local L = data.load or {}
	local isLoaded = WA.IsDisplayLoaded and WA.IsDisplayLoaded(id)
	local evalNow = WA.EvalLoad and WA.EvalLoad(data)
	local evalStatic = WA.EvalLoadStatic and WA.EvalLoadStatic(data)
	D.Log(string.format("--- load %q: state=%s loaded=%s evalNow=%s evalStatic=%s ---",
		id, state, tostring(isLoaded), tostring(evalNow), tostring(evalStatic)))
	if WA.IsGenericTriggerActive then
		local genActive = WA.IsGenericTriggerActive(id)
		if genActive ~= nil then
			D.Log(string.format("  GenericTrigger registration: active=%s (if this is false while loaded=true above, the system's LoadDisplays never actually finished for this id)", tostring(genActive)))
		end
	end
	if L.never then D.Log("  never = true (force-disabled)") end
	local proto = WA.loadPrototype or {}
	local anyConstraint = L.never
	for i = 1, table.getn(proto) do
		local arg = proto[i]
		-- Branched, not `and`/`or`-ed -- see WA.EvalLoad's own gate.
		local active
		if arg.isActive then
			active = arg.isActive(L) and true or false
		else
			active = L["use_" .. arg.name] and true or false
		end
		if active then
			anyConstraint = true
			if arg.name == "class" then
				if L.use_class == "single" then
					D.Log("  class = " .. tostring(L.class) .. " (single)")
				else
					local picked = {}
					for ci = 1, table.getn(WA.CLASS_TOKENS) do
						local token = WA.CLASS_TOKENS[ci]
						if L.classes and L.classes[token] then table.insert(picked, token) end
					end
					D.Log("  class = " .. (table.getn(picked) > 0 and table.concat(picked, ",") or "(none picked)") .. " (multi)")
				end
			else
				local opKey = arg.name .. "_operator"
				local opPart = L[opKey] and (" op=" .. tostring(L[opKey])) or ""
				D.Log(string.format("  %s =%s value=%s%s", arg.name, opPart, tostring(L[arg.name]),
					arg.optional and "  (transient -- ignored by evalStatic)" or ""))
			end
		end
	end
	if L.use_class ~= nil and L.use_class ~= "single" and L.use_class ~= "multi" then
		D.Log("  note: use_class=" .. tostring(L.use_class) .. " is a stray/legacy value (ignored, not \"single\"/\"multi\")")
	end
	if not anyConstraint then D.Log("  (no constraints -- always loaded)") end
	D.Log("--- end load ---")
end

-- ---------------------------------------------------------------------------
-- /wa probe -- checks two client capabilities before relying on either:
-- (1) is C_EncodingUtil's full CBOR chain present (import/
-- export), and (2) does the border's WHITE8X8 edge texture actually render on
-- this client. Also reports the glow overlay pool count (leak check). Spawns a
-- visible bordered test frame at CENTER,0,150 -- watch it in-world, not here.
-- ---------------------------------------------------------------------------

local probeFrame

-- ---------------------------------------------------------------------------
-- /wa rows -- measured geometry of the aura list: the box, how many rows it
-- decided fit and what that leaves unused, and every part of the first two
-- rows. The one thing the headless harness structurally cannot see is where a
-- frame actually lands (its mock has no geometry engine), so a row whose
-- highlight doesn't cover its own text, or a list wasting a row's worth of
-- height, is answered here rather than by reading anchors.
-- ---------------------------------------------------------------------------

function D.Rows()
	local S = WA.OptionsState
	if not S or not S.listBg then
		D.Log("[rows] options window has never been built -- open it first")
		return
	end
	local function edges(name, f)
		if not f then D.Log("  " .. name .. " = (nil)") return end
		D.Log(string.format("  %-7s top=%.1f bottom=%.1f h=%.1f left=%.1f right=%.1f w=%.1f shown=%s",
			name, f:GetTop() or -1, f:GetBottom() or -1, f:GetHeight() or -1,
			f:GetLeft() or -1, f:GetRight() or -1, f:GetWidth() or -1, tostring(f:IsShown() and true or false)))
	end

	local h = S.listBg:GetHeight() or 0
	local used = S.visibleRows * S.ROW_H
	D.Log(string.format("--- rows: listBg h=%.1f, ROW_H=%d, visibleRows=%d ---", h, S.ROW_H, S.visibleRows))
	D.Log(string.format("  rows occupy %d px of %.1f, leaving %.1f unused (a further row needs %d)",
		used, h, h - used - 2, S.ROW_H))
	edges("listBg", S.listBg)
	edges("scroll", S.scroll)
	for i = 1, 2 do
		local row = S.rows and S.rows[i]
		if row then
			D.Log("  -- row " .. i .. " (" .. tostring(row.id) .. ")")
			edges("row", row)
			edges("sel", row.sel)
			edges("icon", row.icon)
			edges("thumb", row.thumb)
			edges("title", row.title)
			edges("sub", row.sub)
			edges("strip", row.statusStrip)
			edges("eye", row.eye)
		end
	end
	D.Log("--- end rows ---")
end

-- A leaf carrying one custom option of every type, for exercising the Custom
-- tab by hand. Built here rather than shipped as an import string because an
-- export string can only be produced by the client's own C_EncodingUtil --
-- a hand-rolled CBOR/zlib/base64 blob cannot be checked against tinycbor
-- offline, so it is not a fixture anything can trust.
function D.ConfigTest()
	local data = WA.NewAura("icon")
	data.authorOptions = {
		{ type = "toggle", key = "showIt", name = "Show It", default = true, width = 1 },
		{ type = "input", key = "label", name = "Label", default = "hello", width = 1 },
		{ type = "number", key = "count", name = "Count", default = 3, min = 0, max = 10, step = 1, width = 1 },
		{ type = "range", key = "size", name = "Size", default = 32, min = 8, max = 64, step = 1, width = 1 },
		{ type = "select", key = "mode", name = "Mode", default = 2,
			values = { "Alpha", "Beta", "Gamma" }, width = 1 },
		{ type = "color", key = "tint", name = "Tint", default = { 1, 0.5, 0, 1 }, width = 1 },
		{ type = "multiselect", key = "flags", name = "Flags", default = { true, false, true },
			values = { "One", "Two", "Three" }, width = 1 },
		{ type = "description", text = "Change a control, switch tabs, come back.", width = 2 },
		{ type = "header", useName = true, name = "Groups", text = "", width = 2 },
		{ type = "group", key = "grp", name = "Simple Group", groupType = "simple",
			useCollapse = true, collapse = false, width = 2, subOptions = {
				{ type = "toggle", key = "inner", name = "Inner Toggle", default = false, width = 1 },
				{ type = "input", key = "innerText", name = "Inner Text", default = "nested", width = 1 },
			} },
		{ type = "group", key = "arr", name = "Array Group", groupType = "array",
			limitType = "none", size = 10, nameSource = 1, hideReorder = false,
			useCollapse = true, collapse = false, width = 2, subOptions = {
				{ type = "input", key = "entryName", name = "Entry Name", default = "entry", width = 1 },
				{ type = "toggle", key = "entryOn", name = "Enabled", default = true, width = 1 },
			} },
	}
	data.config = {}
	WA.MergeDefaults(data)
	WA.Add(data)
	if WA.RefreshList then WA.RefreshList() end
	D.Log("--- configtest ---")
	D.Log("  created \"" .. tostring(data.id) .. "\" with "
		.. table.getn(data.authorOptions) .. " custom options")
	D.Log("  open the options window, pick it, and use the Custom tab")
	return data
end

-- Which vendored LibWidgets actually won, and whether it still has everything
-- this addon calls. Every addon vendoring the library shares one global
-- instance (highest MINOR wins, ties to whoever registered first), so a sibling
-- addon's older copy can silently be the one running -- see libs\LibWidgetsDev.lua.
function D.Libs()
	local W = WA.Widgets
	D.Log("--- libs ---")
	-- Whichever addon's LibStub loaded first is the one in force for everyone
	-- (equal LIBSTUB_MINOR means later copies skip). Upstream's NewLibrary calls
	-- string.match, absent here, so a copy that hasn't been patched to
	-- string.find throws on every registration -- worth being able to see which
	-- one is live rather than inferring it from a crash.
	D.Log("  string.match available = " .. tostring(string.match ~= nil))
	D.Log("  LibStub minor = " .. tostring(LibStub and LibStub.minor))
	D.Log("  LIBWIDGETS_DEV = " .. tostring(LIBWIDGETS_DEV))
	D.Log("  live LibWidgets MINOR = " .. tostring(LibWidgets and LibWidgets.MINOR))
	if LibStub and LibStub.minors then
		D.Log("  LibStub minors[LibWidgets-1.0] = " .. tostring(LibStub.minors["LibWidgets-1.0"]))
	end
	if LibWidgets then
		-- How the live LibStub would have read our MINOR (9). A backported
		-- string.match with string.find's return contract yields a position
		-- rather than the captured digits, which silently turns every version
		-- into the same number and hands the race to whoever registered first.
		D.Log("  MINOR 9 parses as: via string.match = " .. tostring(LibWidgets.PARSE_MATCH)
			.. ", via string.find capture = " .. tostring(LibWidgets.PARSE_FIND))
		D.Log("  minors[LibWidgets-1.0] before our registration = " .. tostring(LibWidgets.PRE_MINOR))
	end
	if LibStub and LibStub.libs then
		-- Every major reads back as LibStub's own minor (2) even though the
		-- libraries declare 3/6/8/44, while our own write of 9 into the same
		-- table reads back correctly. A plain table can't do that, so dump the
		-- raw value beside the indexed one and the metatables: if rawget differs,
		-- something has installed an __index on LibStub's bookkeeping.
		D.Log("  metatables: LibStub=" .. tostring(getmetatable(LibStub))
			.. " minors=" .. tostring(getmetatable(LibStub.minors))
			.. " libs=" .. tostring(getmetatable(LibStub.libs)))
		local majors = {}
		for major in pairs(LibStub.libs) do
			local raw, indexed = rawget(LibStub.minors, major), LibStub.minors[major]
			local entry = major .. "=" .. tostring(indexed)
			if raw ~= indexed then entry = entry .. "(raw " .. tostring(raw) .. ")" end
			table.insert(majors, entry)
		end
		table.sort(majors)
		D.Log("  all LibStub majors: " .. (table.getn(majors) > 0 and table.concat(majors, ", ") or "(none)"))
	end
	-- The decisive line: the numbers above look the same whether this copy won
	-- the version race or the dev flag forced it, since forcing it rewrites the
	-- registered minor to our own.
	if LibWidgets and LibWidgets.REPAIRED then
		D.Log("  LibStub refused the upgrade, so our MINOR " .. tostring(LibWidgets.MINOR)
			.. " took over the older live copy (MINOR " .. tostring(LibWidgets.DISPLACED_MINOR)
			.. ") on its own. This is the normal path on this client and needs no dev flag.")
	elseif LibWidgets and LibWidgets.DEV_OVERRIDE then
		D.Log("  our copy is live ONLY because LIBWIDGETS_DEV forced it -- it lost the"
			.. " race to a copy registered at MINOR " .. tostring(LibWidgets.DISPLACED_MINOR))
	elseif LibWidgets and LibWidgets.DEV_OVERRIDE == false then
		D.Log("  our copy won the version race on its own (displaced MINOR "
			.. tostring(LibWidgets.DISPLACED_MINOR) .. ") -- the dev flag isn't doing anything")
	else
		D.Log("  our copy is NOT live: some other addon's copy is (it predates DEV_OVERRIDE)")
	end
	-- Behavioural probe. Rather than keep hunting for whichever LibStub is live
	-- (LibWindow-1.1 is registered with no file on disk anywhere, so it isn't an
	-- addon's), just ask it: register a throwaway major at minor 1, then at 99.
	-- A working LibStub returns a table for the second call and records 99.
	local probeMajor = "WeakestAurasLibStubProbe-1.0"
	if LibStub and not LibStub.libs[probeMajor] then
		LibStub:NewLibrary(probeMajor, 1)
		local second = LibStub:NewLibrary(probeMajor, 99)
		D.probeResult = (second and "honours versions" or "IGNORES versions -- rejected minor 99 over minor 1")
			.. " (recorded minor = " .. tostring(LibStub.minors[probeMajor]) .. ")"
	end
	if D.probeResult then D.Log("  LibStub arbitration probe: " .. D.probeResult) end

	local missing = W and W.libWidgetsMissing or {}
	if table.getn(missing) == 0 then
		D.Log("  every required function present")
	else
		D.Log("  MISSING: " .. table.concat(missing, ", "))
	end
end

-- Every addon the engine enumerated, loaded or not. MPQ-resident addons (packed
-- into Data\patch-X.mpq under Interface\AddOns\) enumerate exactly like disk
-- ones but load *before* them, so anything listed here with no folder in
-- Interface\AddOns is MPQ-resident -- which is how a library can be registered
-- with no file for it anywhere on disk. Cheaper than opening the archives.
function D.Addons()
	D.Log("--- addons (" .. tostring(GetNumAddOns and GetNumAddOns() or "?") .. " enumerated) ---")
	if not GetNumAddOns then D.Log("  GetNumAddOns unavailable"); return end
	local line = {}
	for i = 1, GetNumAddOns() do
		local name = GetAddOnInfo(i)
		local loaded = IsAddOnLoaded and IsAddOnLoaded(i)
		table.insert(line, (name or "?") .. (loaded and "" or "(not loaded)"))
		if table.getn(line) == 6 then
			D.Log("  " .. table.concat(line, ", "))
			line = {}
		end
	end
	if table.getn(line) > 0 then D.Log("  " .. table.concat(line, ", ")) end
end

-- Both spell-cooldown sources for one spell, side by side. The slot read is what
-- the watcher uses; the C_Spell read is the documented spellID call it fell back
-- from. Run it while the spell is on cooldown -- if the slot reports a window and
-- C_Spell reports zeros, the spellID form does not see this client's cooldowns.
function D.CdProbe(rest)
	D.Log("--- cdprobe ---")
	if not rest or rest == "" then
		D.Log("  usage: /wa cdprobe <spell name or id>")
		D.Log("--- end cdprobe ---")
		return
	end
	local book = BOOKTYPE_SPELL or "spell"
	local id = WA.ResolveSpellID(rest)
	D.Log("  input " .. rest .. " -> spellID " .. tostring(id))
	if not id then
		D.Log("  does not resolve: a name only resolves through the player's own spellbook")
		D.Log("--- end cdprobe ---")
		return
	end
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
	D.Log("  name = " .. tostring(name))

	local slot = WA.SpellSlotByID(id)
	if slot then
		local sname, srank = GetSpellName(slot, book)
		D.Log("  slot " .. slot .. " = " .. tostring(sname) .. " " .. tostring(srank))
		local start, duration = WA.SpellSlotCooldown(slot)
		if start then
			D.Log(string.format("  slot cooldown: start %.2f, duration %.2f, %.2f left",
				start, duration, (start + duration) - GetTime()))
		else
			D.Log("  slot cooldown: unreadable")
		end
	else
		D.Log("  slot: none -- this spell is not in the player's book")
	end

	local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(id)
	if info then
		D.Log(string.format("  C_Spell.GetSpellCooldown(%d): start %s, duration %s",
			id, tostring(info.startTime), tostring(info.duration)))
		if (info.startTime or 0) < 0 then
			D.Log("    ^ signed-wrapped tick (ClassicAPI reads it into an int; uptime is past")
			D.Log("      2^31 ms). Repaired to " .. string.format("%.2f", WA.UnwrapTick(info.startTime)))
		end
	else
		D.Log("  C_Spell.GetSpellCooldown(" .. id .. ") = nil")
	end
	D.Log(string.format("  GetTime() = %.2f (uptime %.1f days -- ticks wrap signed past 24.9)",
		GetTime(), GetTime() / 86400))

	local wStart, wDuration = WA.SpellCdInfo(id)
	D.Log("  watcher answers: start " .. tostring(wStart) .. ", duration " .. tostring(wDuration))
	D.Log("  IsGcdCooldown(that duration) = " .. tostring(WA.IsGcdCooldown(wDuration)))
	D.Log("  => a Cooldown Ready trigger reads "
		.. (((wDuration or 0) <= 0 or WA.IsGcdCooldown(wDuration) or ((wStart or 0) + (wDuration or 0)) <= GetTime())
			and "READY" or "on cooldown"))

	-- Every rank, since a name resolves to one specific rank's ID and only the
	-- rank actually cast carries the cooldown.
	if name and GetNumSpellTabs then
		local shown = 0
		for tab = 1, (GetNumSpellTabs() or 0) do
			local _, _, offset, numSlots = GetSpellTabInfo(tab)
			for i = (offset or 0) + 1, (offset or 0) + (numSlots or 0) do
				local n, r = GetSpellName(i, book)
				if n == name then
					local s, d = WA.SpellSlotCooldown(i)
					D.Log("    rank slot " .. i .. " (" .. tostring(r) .. "): start "
						.. tostring(s) .. ", duration " .. tostring(d))
					shown = shown + 1
				end
			end
		end
		if shown == 0 then D.Log("    no spellbook slot carries that name") end
	end
	D.Log("--- end cdprobe ---")
end

-- Live view of the global-cooldown watcher, plus the two reads it deliberately
-- does not make. Upstream's GCD spells (29515 Classic, 61304 elsewhere) and the
-- spellID-shaped GetSpellCooldown call are both reported here rather than only
-- argued about in a comment: this is what settles whether they are dead on a
-- given build.
function D.Gcd()
	D.Log("--- gcd ---")
	local book = BOOKTYPE_SPELL or "spell"
	if not WA.GcdDebug then D.Log("  no GCD watcher in this build"); D.Log("--- end gcd ---"); return end
	WA.WatchGCD()
	local g = WA.GcdDebug()
	D.Log("  watching = " .. tostring(g.watching)
		.. ", book tabs = " .. tostring(GetNumSpellTabs and GetNumSpellTabs()))
	if g.probeSlot then
		local name, rank = GetSpellName(g.probeSlot, book)
		local ok, start, duration = pcall(GetSpellCooldown, g.probeSlot, book)
		D.Log("  probe slot " .. g.probeSlot .. " = " .. tostring(name) .. " " .. tostring(rank))
		D.Log("  slot reads " .. (ok and (tostring(start) .. " + " .. tostring(duration)) or ("ERROR " .. tostring(start))))
	else
		D.Log("  probe slot: none learned -- cast an instant that has no cooldown of its own, then run this again")
	end
	D.Log("  measured GCD length = " .. tostring(g.measured or "none yet (assuming 1.5)"))
	local start, duration = WA.GcdInfo()
	if duration > 0 then
		D.Log(string.format("  window: start %.2f, length %.2f, %.2f left", start, duration, (start + duration) - GetTime()))
	else
		D.Log("  window: closed")
	end
	local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(61304)
	D.Log("  C_Spell.GetSpellCooldown(61304) = " .. (info and (tostring(info.startTime) .. " + " .. tostring(info.duration)) or "nil (no Spell.dbc row)"))
	local ok, err = pcall(GetSpellCooldown, 61304, book)
	D.Log("  GetSpellCooldown(61304, bookType) = " .. (ok and "returned a value" or ("ERROR " .. tostring(err))))
	D.Log("--- end gcd ---")
end

function D.Probe()
	local E = C_EncodingUtil
	D.Log("--- probe ---")
	if E then
		local fns = { "SerializeCBOR", "DeserializeCBOR", "CompressString", "DecompressString", "EncodeBase64", "DecodeBase64" }
		local parts = {}
		for i = 1, table.getn(fns) do
			table.insert(parts, fns[i] .. "=" .. (E[fns[i]] and "yes" or "NO"))
		end
		D.Log("  C_EncodingUtil: " .. table.concat(parts, " "))
	else
		D.Log("  C_EncodingUtil: ABSENT (import/export disabled)")
	end
	D.Log("  WA.hasImportExport = " .. tostring(WA.hasImportExport))

	if WA.hasImportExport then
		-- Round-trip a small table to confirm the chain actually works, not just
		-- that the functions exist.
		local ok, err = pcall(function()
			local blob = C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(C_EncodingUtil.SerializeCBOR({ a = 1, b = "x", c = { 2, 3 } })))
			local back = C_EncodingUtil.DeserializeCBOR(C_EncodingUtil.DecompressString(C_EncodingUtil.DecodeBase64(blob)))
			if type(back) ~= "table" or back.a ~= 1 or back.b ~= "x" or back.c[2] ~= 3 then
				error("round-trip mismatch")
			end
		end)
		D.Log("  CBOR round-trip: " .. (ok and "OK" or ("FAILED -- " .. tostring(err))))
	end

	if WA.GetGlowPoolStats then
		local created, free = WA.GetGlowPoolStats()
		D.Log(string.format("  glow overlay pool: %d created, %d free (in-use = %d)", created, free, created - free))
	end

	-- Does our Model+CooldownFrameTemplate swipe (RegionPrototype.lua's
	-- CreateSwipe) support a reverse/inverse fill direction, the way retail's
	-- modern Cooldown widget does via SetReverse? Vanilla's cooldown model has
		-- no documented equivalent or addon reference on this client --
	-- pfUI, OmniCC, GearMenu -- references one), but this client is a patched
	-- fork, so check empirically rather than assume.
	do
		local testSwipe = WA.regionPrototype and WA.regionPrototype.CreateSwipe(UIParent)
		if not testSwipe then
			D.Log("  swipe reverse: CreateSwipe returned nil, can't probe")
		else
			D.Log("  swipe SetReverse method: " .. (testSwipe.SetReverse and "PRESENT" or "absent"))
			if testSwipe.SetReverse then
				local ok, err = pcall(testSwipe.SetReverse, testSwipe, true)
				D.Log("  swipe SetReverse(true) call: " .. (ok and "OK" or ("FAILED -- " .. tostring(err))))
			end
			testSwipe:Hide()
			testSwipe:SetParent(nil)
		end
	end

	if not probeFrame then
		probeFrame = CreateFrame("Frame", nil, UIParent)
		probeFrame:SetWidth(48); probeFrame:SetHeight(48)
		probeFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
		local ic = probeFrame:CreateTexture(nil, "ARTWORK")
		ic:SetAllPoints(probeFrame)
		ic:SetTexture("Interface\\Icons\\Spell_Nature_LightningShield")
		local border = CreateFrame("Frame", nil, probeFrame)
		border:SetPoint("TOPLEFT", -2, 2)
		border:SetPoint("BOTTOMRIGHT", 2, -2)
		border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 3 })
		border:SetBackdropBorderColor(1, 0.2, 0.2, 1)
	end
	probeFrame:Show()
	D.Log("  border texture: spawned a red WHITE8X8-edged test icon at CENTER,0,150 -- if you see a red border in-world, the border subregion renders here.")
	D.Log("--- end probe ---")
end

-- ---------------------------------------------------------------------------
-- /wa soundprobe -- measures the sound, combat-text and speech entry points
-- used by the action system. The scheduled files are judged by ear in-game;
-- return values only describe whether the call reached the client cleanly.
-- ---------------------------------------------------------------------------

local SOUND_PROBE_FILES = {
	"Sound\\interface\\RaidWarning.wav",
	"Sound\\interface\\levelup2.wav",
	"Sound\\interface\\iQuestComplete.wav",
	"Sound\\interface\\iTellMessage.wav",
	"Sound\\Spells\\LevelUp.wav",
	"Sound\\Spells\\ReputationLevelUp.wav",
	"Sound\\Spells\\PVPThroughQueue.wav",
	"Sound\\Spells\\ShaysBell.wav",
	"Sound\\Doodad\\BellTollNightElf.wav",
	"Sound\\Doodad\\BellTollAlliance.wav",
	"Sound\\Doodad\\BellTollHorde.wav",
	"Sound\\Doodad\\BellTollTribal.wav",
	"Sound\\Doodad\\DwarfHorn.wav",
	"Sound\\Doodad\\G_GongTroll01.wav",
	"Sound\\Doodad\\LightHouseFogHorn.wav",
	"Sound\\Doodad\\HornGoober.wav",
	"Sound\\interface\\AuctionWindowOpen.wav",
	"Sound\\Interface\\igQuestFailed.wav",
}

local soundProbeSession = 0

local function soundProbeCall(path, label)
	if type(PlaySoundFile) ~= "function" then
		D.Log("  " .. label .. " " .. path .. " -- PlaySoundFile absent")
		return
	end
	local ok, first, second, third = pcall(PlaySoundFile, path)
	D.Log(string.format("  %s %s -- call=%s return1=%s return2=%s return3=%s",
		label, path, tostring(ok and true or false), tostring(first), tostring(second), tostring(third)))
end

local function soundProbeSchedule(session, delay, path, label)
	if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
		D.Log("  playback sequence unavailable: C_Timer.After absent")
		return false
	end
	C_Timer.After(delay, function()
		if soundProbeSession ~= session then return end
		soundProbeCall(path, label)
	end)
	return true
end

function D.SoundProbe()
	soundProbeSession = soundProbeSession + 1
	local session = soundProbeSession
	D.Log("--- soundprobe ---")

	if type(PlaySoundFile) == "function" then
		D.Log("  MPQ internal paths: scheduled 18 curated SoundEntries paths; judge playback by ear")
	else
		D.Log("  MPQ internal paths: PlaySoundFile absent")
	end

	local delay = 0
	local scheduled = 0
	for i = 1, table.getn(SOUND_PROBE_FILES) do
		if soundProbeSchedule(session, delay, SOUND_PROBE_FILES[i], "[curated]") then
			scheduled = scheduled + 1
		end
		delay = delay + 1
	end

	local extensionFiles = {
		{ path = "Interface\\AddOns\\BigWigs\\Sounds\\bandage.wav", label = "[extension wav]" },
		{ path = "Interface\\AddOns\\BigWigs\\Sounds\\1.ogg", label = "[extension ogg]" },
		{ path = "Interface\\AddOns\\BigWigs\\Sounds\\Alarm.mp3", label = "[extension mp3]" },
	}
	for i = 1, table.getn(extensionFiles) do
		local item = extensionFiles[i]
		if soundProbeSchedule(session, delay, item.path, item.label) then
			scheduled = scheduled + 1
		end
		delay = delay + 1
	end
	D.Log("  playback sequence: " .. scheduled .. " file(s) scheduled")

	D.Log("  PlaySoundFile return probe: read the return values on the first [curated] line")

	if type(PlaySound) == "function" then
		local ok, err = pcall(PlaySound, "RaidWarning")
		D.Log("  PlaySound(\"RaidWarning\"): " .. (ok and "call returned cleanly" or ("ERROR " .. tostring(err))))
	else
		D.Log("  PlaySound(\"RaidWarning\"): PlaySound absent")
	end

	if type(LoadAddOn) == "function" then
		local ok, result, reason = pcall(LoadAddOn, "Blizzard_CombatText")
		D.Log(string.format("  LoadAddOn(Blizzard_CombatText): call=%s return=%s reason=%s CombatText_AddMessage=%s COMBAT_TEXT_SCROLL_FUNCTION=%s",
			tostring(ok and true or false), tostring(result), tostring(reason),
			type(CombatText_AddMessage), type(COMBAT_TEXT_SCROLL_FUNCTION)))
	else
		D.Log("  LoadAddOn(Blizzard_CombatText): LoadAddOn absent")
	end

	if type(C_VoiceChat) == "table" and type(C_VoiceChat.GetTtsVoices) == "function" then
		local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
		if ok and type(voices) == "table" then
			D.Log("  C_VoiceChat.GetTtsVoices: " .. table.getn(voices) .. " voice(s)")
			for i = 1, table.getn(voices) do
				D.Log(string.format("    voice %d: id=%s name=%s", i, tostring(voices[i].voiceID), tostring(voices[i].name)))
			end
		else
			D.Log("  C_VoiceChat.GetTtsVoices: " .. (ok and ("returned " .. type(voices)) or ("ERROR " .. tostring(voices))))
		end
	else
		D.Log("  C_VoiceChat.GetTtsVoices: unavailable")
	end

	if UIErrorsFrame and type(UIErrorsFrame.AddMessage) == "function" then
		local ok, err = pcall(function()
			UIErrorsFrame:AddMessage("[soundprobe] UIErrorsFrame", 0.2, 1, 0.2)
		end)
		D.Log("  UIErrorsFrame:AddMessage(msg, r, g, b): " .. (ok and "call returned cleanly" or ("ERROR " .. tostring(err))))
	else
		D.Log("  UIErrorsFrame:AddMessage(msg, r, g, b): unavailable")
	end

	if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
		local ok, err = pcall(function()
			DEFAULT_CHAT_FRAME:AddMessage("[soundprobe] DEFAULT_CHAT_FRAME", 0.2, 0.8, 1)
		end)
		D.Log("  DEFAULT_CHAT_FRAME:AddMessage(msg, r, g, b): " .. (ok and "call returned cleanly" or ("ERROR " .. tostring(err))))
	else
		D.Log("  DEFAULT_CHAT_FRAME:AddMessage(msg, r, g, b): unavailable")
	end

	D.Log("  listen for the 18 curated MPQ files, then wav, ogg, and mp3 in that order")
	D.Log("--- end soundprobe ---")
end

-- ---------------------------------------------------------------------------
-- /wa wa2probe -- can this client inflate what WeakAuras2 exports?
--
-- WeakAuras2 ships raw deflate (LibDeflate's CompressDeflate): no zlib header,
-- no checksum, and therefore no magic bytes to auto-detect from. The method has
-- to be passed to DecompressString explicitly, and the negative test here is the
-- load-bearing one -- it proves that omitting it actually fails on this client
-- rather than being harmlessly redundant. The zlib cases are controls: they are
-- the path ImportExport.lua already takes, so a failure there means the probe
-- itself is wrong, not the client.
-- ---------------------------------------------------------------------------

local function wa2Try(fn, a, b)
	if type(fn) ~= "function" then return nil, "absent" end
	local ok, result = pcall(fn, a, b)
	if not ok then return nil, tostring(result) end
	return result
end

local function wa2Yesno(v)
	if v then return "yes" end
	return "NO"
end

function D.Wa2Probe()
	D.Log("--- wa2probe ---")
	local E = C_EncodingUtil
	if type(E) ~= "table" then
		D.Log("C_EncodingUtil: ABSENT")
		D.Log("VERDICT: NO-GO -- no compression API, WeakAuras2 import is impossible")
		D.Log("--- end wa2probe ---")
		return
	end

	D.Log("CompressString=" .. type(E.CompressString)
		.. " DecompressString=" .. type(E.DecompressString))

	local enum = Enum and Enum.CompressionMethod
	local deflate = enum and enum.Deflate
	local zlib = enum and enum.Zlib
	D.Log("Enum.CompressionMethod: " .. (enum and ("Deflate=" .. tostring(deflate)
		.. " Zlib=" .. tostring(zlib)) or "ABSENT (assuming Deflate=0, Zlib=1)"))
	local RAW = deflate or 0
	local ZLIB = zlib or 1

	-- Repetitive so compression is measurable, with a NUL and bytes above 0x7F
	-- so the round trip proves the API is 8-bit clean rather than string-safe.
	local sample = string.rep("weakauras", 20)
		.. string.char(0) .. string.char(127) .. string.char(128) .. string.char(255)
		.. string.rep("aura", 10)
	D.Log("sample: " .. string.len(sample) .. " bytes, includes NUL and >0x7F")

	local rawBlob, rawErr = wa2Try(E.CompressString, sample, RAW)
	if not rawBlob then
		D.Log("CompressString(s, Deflate): FAILED -- " .. tostring(rawErr))
		D.Log("VERDICT: NO-GO -- cannot produce raw deflate")
		D.Log("--- end wa2probe ---")
		return
	end
	D.Log("CompressString(s, Deflate): " .. string.len(rawBlob) .. " bytes"
		.. "  first2=" .. string.byte(rawBlob, 1) .. "," .. string.byte(rawBlob, 2))

	local rawBack = wa2Try(E.DecompressString, rawBlob, RAW)
	local rawOk = rawBack == sample
	D.Log("round trip, explicit Deflate: " .. wa2Yesno(rawOk))

	-- The negative test. A raw deflate payload has no magic bytes, so the
	-- two-argument-less call should NOT be able to read it.
	local sniffed, sniffErr = wa2Try(E.DecompressString, rawBlob)
	local sniffFailed = (sniffed ~= sample)
	D.Log("round trip, method OMITTED: " .. (sniffFailed and "refused (correct)" or "SUCCEEDED -- unexpected")
		.. (sniffErr and ("  [" .. string.sub(tostring(sniffErr), 1, 40) .. "]") or ""))

	-- Controls: the zlib path ImportExport.lua already relies on.
	local zBlob = wa2Try(E.CompressString, sample, ZLIB)
	local zBack = zBlob and wa2Try(E.DecompressString, zBlob, ZLIB)
	local zSniff = zBlob and wa2Try(E.DecompressString, zBlob)
	D.Log("control, zlib explicit: " .. wa2Yesno(zBack == sample)
		.. "   zlib auto-detected: " .. wa2Yesno(zSniff == sample))

	if rawOk and sniffFailed then
		D.Log("VERDICT: GO -- raw deflate round-trips, and the method argument is required")
	elseif rawOk then
		D.Log("VERDICT: GO, with a caveat -- raw deflate round-trips, but omitting the")
		D.Log("  method also worked. Pass it anyway; do not rely on auto-detection.")
	else
		D.Log("VERDICT: NO-GO -- raw deflate does not round-trip on this client")
	end
	D.Log("--- end wa2probe ---")
end

-- ---------------------------------------------------------------------------
-- /wa wa2 <string> -- run a WeakAuras export string through WA.WA2Decode and
-- report what came out. The chat edit box caps input at 255 characters, so a
-- full wago string cannot be pasted here; the usable subjects are short strings
-- and the refusal paths.
-- ---------------------------------------------------------------------------

function D.Wa2(text)
	if not text or text == "" then
		D.Log("[wa2] usage: /wa wa2 <!WA:2! string> (chat caps the paste at 255 characters)")
		return
	end

	local bytes, reason = WA.WA2Decode(text)
	if not bytes then
		D.Log("[wa2] refused: " .. tostring(reason))
		return
	end

	local payload, payloadReason = WA.WA2Deserialize(bytes)
	if type(payload) ~= "table" or payload.m ~= "d" or type(payload.d) ~= "table"
		or type(payload.d.regionType) ~= "string" then
		D.Log("[wa2] " .. string.len(bytes) .. " bytes, but the payload is not aura-shaped"
			.. (payloadReason and (" [" .. tostring(payloadReason) .. "]") or ""))
		return
	end

	local head = {}
	for i = 1, math.min(16, string.len(bytes)) do
		table.insert(head, string.format("%02X", string.byte(bytes, i)))
	end
	D.Log("[wa2] " .. string.len(bytes) .. " bytes  id=" .. tostring(payload.d.id)
		.. "  regionType=" .. payload.d.regionType .. "  head=" .. table.concat(head, " "))
end

-- ---------------------------------------------------------------------------
-- /wa texprobe -- the Texture questions no headless harness can answer.
--
-- The log records capability read-backs and the frame puts the visual tests
-- beside labels that say exactly what to compare. The client is the authority
-- for arbitrary-angle rotation, out-of-range texcoords, rect modification and
-- desaturation; the mock cannot model any of those results.
-- ---------------------------------------------------------------------------

local texProbeFrame
local TEXPROBE_ART = "Interface\\AddOns\\WeakestAuras\\textures\\shapes\\arrows_target.tga"
local TEXPROBE_COLOR_ART = "Interface\\Icons\\Spell_Nature_LightningShield"

local function texProbeLabel(parent, text, point, relative, relPoint, x, y)
	local label = parent:CreateFontString(nil, "OVERLAY")
	label:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
	label:SetJustifyH("CENTER")
	label:SetText(text)
	label:SetPoint(point, relative, relPoint, x, y)
	return label
end

local function texProbeBox(parent, x, y)
	local box = CreateFrame("Frame", nil, parent)
	box:SetWidth(96); box:SetHeight(96)
	box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	box:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
	box:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
	return box
end

local function texProbeTexture(box, rotation)
	local texture = box:CreateTexture(nil, "ARTWORK")
	texture:SetAllPoints(box)
	texture:SetTexture(TEXPROBE_ART)
	if rotation then
		local angle = math.pi * (135 - rotation) / 180
		local vx = math.cos(angle) / math.sqrt(2)
		local vy = math.sin(angle) / math.sqrt(2)
		local ulx, uly = 0.5 + vx, 0.5 - vy
		local llx, lly = 0.5 - vy, 0.5 - vx
		local urx, ury = 0.5 + vy, 0.5 + vx
		local lrx, lry = 0.5 - vx, 0.5 + vy
		texture:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
	else
		texture:SetTexCoord(0, 0, 0, 1, 1, 0, 1, 1)
	end
	return texture
end

local function texProbeCall(texture, method, a, b, c, d)
	local fn = texture and texture[method]
	if not fn then return false, "ABSENT" end
	return pcall(fn, texture, a, b, c, d)
end

function D.TexProbe()
	D.Log("--- texprobe ---")

	if not texProbeFrame then
		texProbeFrame = CreateFrame("Frame", nil, UIParent)
		texProbeFrame:SetWidth(620); texProbeFrame:SetHeight(300)
		texProbeFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
		texProbeFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
		texProbeFrame:SetBackdropColor(0, 0, 0, 0.8)
		texProbeLabel(texProbeFrame, "Texture probe: compare each sample with its label", "TOP", texProbeFrame, "TOP", 0, -10)

		local rotated = texProbeBox(texProbeFrame, 18, -34)
		texProbeTexture(rotated, 30)
		texProbeLabel(texProbeFrame, "30 deg rotation\n(inside-box / sqrt2)", "TOP", rotated, "BOTTOM", 0, -4)

		local normal = texProbeBox(texProbeFrame, 128, -34)
		texProbeTexture(normal)
		texProbeLabel(texProbeFrame, "0 deg reference", "TOP", normal, "BOTTOM", 0, -4)

		local outside = texProbeBox(texProbeFrame, 238, -34)
		local outsideTexture = texProbeTexture(outside)
		outsideTexture:SetTexCoord(-0.25, -0.25, -0.25, 1.25, 1.25, -0.25, 1.25, 1.25)
		texProbeLabel(texProbeFrame, "out-of-range\n(-.25 to 1.25)", "TOP", outside, "BOTTOM", 0, -4)

		local rectOn = texProbeBox(texProbeFrame, 348, -34)
		local rectOnTexture = texProbeTexture(rectOn)
		texProbeCall(rectOnTexture, "SetTexCoordModifiesRect", true)
		rectOnTexture:SetTexCoord(0, 0, 0, 1, 0.5, 0, 0.5, 1)
		texProbeLabel(texProbeFrame, "half texcoord\nrect setting ON", "TOP", rectOn, "BOTTOM", 0, -4)

		local rectOff = texProbeBox(texProbeFrame, 458, -34)
		local rectOffTexture = texProbeTexture(rectOff)
		texProbeCall(rectOffTexture, "SetTexCoordModifiesRect", false)
		rectOffTexture:SetTexCoord(0, 0, 0, 1, 0.5, 0, 0.5, 1)
		texProbeLabel(texProbeFrame, "half texcoord\nrect setting OFF", "TOP", rectOff, "BOTTOM", 0, -4)

		local regular = texProbeBox(texProbeFrame, 183, -174)
		local regularTexture = texProbeTexture(regular)
		regularTexture:SetTexture(TEXPROBE_COLOR_ART)
		texProbeLabel(texProbeFrame, "colored normal", "TOP", regular, "BOTTOM", 0, -4)

		local desaturated = texProbeBox(texProbeFrame, 293, -174)
		local desaturatedTexture = texProbeTexture(desaturated)
		desaturatedTexture:SetTexture(TEXPROBE_COLOR_ART)
		local desatOK, desatReturn = texProbeCall(desaturatedTexture, "SetDesaturated", true)
		texProbeLabel(texProbeFrame, "SetDesaturated(true)", "TOP", desaturated, "BOTTOM", 0, -4)

		texProbeFrame._texProbe = {
			regular = regular, desatOK = desatOK, desatReturn = desatReturn,
		}
	end
	texProbeFrame:Show()

	local p = texProbeFrame._texProbe
	D.Log("  art: " .. TEXPROBE_ART)
	D.Log("  desaturation comparison art: " .. TEXPROBE_COLOR_ART)
	D.Log("  rotation sample: 30 degrees with the sqrt2-safe 8-argument SetTexCoord -- compare with 0 degree reference")
	D.Log("  out-of-range sample: transparent margin, edge smear, or tiled art?")

	local scratch = p.regular:CreateTexture(nil, "ARTWORK")
	local getOK, defaultValue = texProbeCall(scratch, "GetTexCoordModifiesRect")
	D.Log("  GetTexCoordModifiesRect default: " .. (getOK and tostring(defaultValue) or tostring(defaultValue)))
	local setOnOK = texProbeCall(scratch, "SetTexCoordModifiesRect", true)
	local setOffOK = texProbeCall(scratch, "SetTexCoordModifiesRect", false)
	D.Log("  SetTexCoordModifiesRect calls: on=" .. tostring(setOnOK) .. " off=" .. tostring(setOffOK)
		.. " -- compare the ON/OFF sample box widths")

	local vertexOK, vertexReturn = texProbeCall(scratch, "SetVertexOffset", 0, 0)
	D.Log("  SetVertexOffset: " .. (vertexOK and ("PRESENT (return " .. tostring(vertexReturn) .. ")") or "ABSENT"))
	D.Log("  SetRotation: " .. ((scratch.SetRotation and "PRESENT") or "ABSENT"))
	D.Log("  SetDesaturated(true): " .. (p.desatOK and "call accepted" or "ABSENT/FAILED")
		.. " (return " .. tostring(p.desatReturn) .. ") -- compare normal and desaturated samples")
	D.Log("  visual answers: rotate 30 degrees; margin behavior; whether ON changes the half-width box; whether art greys")
	D.Log("--- end texprobe ---")
end

-- ---------------------------------------------------------------------------
-- /wa codeprobe -- checks the EditBox behavior needed by the code editor:
-- engine behaviour a syntax-highlighting code editor rests on, none of which
-- raw color escapes, indexing, caret movement, and sentinel round-trips.
--
-- Half of this is unavoidably a visual test -- whether a colour code *renders*
-- as colour, and where a selection actually lands, are things only an eye can
-- answer -- so the frame parks itself on screen with the steps that need
-- clicking, and only the machine-checkable parts go to the log.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- /wa textprobe -- the FontString questions no headless harness can answer.
--
-- Every answer this reports is already recorded in design/client/gotchas.md; it
-- stays a command so a client patch can be re-tested in one keystroke rather
-- than re-argued.
--
-- The inline texture escape is the one that decided a feature. An engine that
-- does not honour |T...|t prints the texture path as text instead, which is
-- machine-checkable without an eye because the two outcomes have wildly
-- different string widths -- an icon is about one line wide, the literal path is
-- thirty-odd characters. Four escape forms are measured, since a client could
-- honour the sized form and not the auto-sized one; this one honours none. The
-- SimpleHTML and message-frame sections then ask whether any *other* text widget
-- has an inline-image path. None does.
--
-- Then the two Text-region unknowns (does GetHeight track wrapped text -- it
-- does, wrapping included) and the font list's own read-backs.
-- ---------------------------------------------------------------------------

local textProbeFrame
local TEXTPROBE_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

function D.TextProbe()
	D.Log("--- textprobe ---")

	if not textProbeFrame then
		textProbeFrame = CreateFrame("Frame", nil, UIParent)
		textProbeFrame:SetWidth(320); textProbeFrame:SetHeight(90)
		textProbeFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
		textProbeFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
		textProbeFrame:SetBackdropColor(0, 0, 0, 0.7)
		textProbeFrame.lines = {}
		for i = 1, 4 do
			local fs = textProbeFrame:CreateFontString(nil, "OVERLAY")
			fs:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
			fs:SetJustifyH("LEFT")
			fs:SetPoint("TOPLEFT", 8, -6 - (i - 1) * 20)
			textProbeFrame.lines[i] = fs
		end
	end
	textProbeFrame:Show()

	-- A scratch string with no size of its own, so GetStringWidth reports what
	-- the engine actually laid out rather than a width we imposed.
	local scratch = textProbeFrame:CreateFontString(nil, "OVERLAY")
	scratch:SetFont("Fonts\\FRIZQT__.TTF", 12, "")

	scratch:SetText("M")
	local emWidth = scratch:GetStringWidth() or 0
	D.Log(string.format("  reference: one 12px 'M' is %.1fpx wide", emWidth))

	local forms = {
		{ name = "auto  |T<path>:0|t", text = "|T" .. TEXTPROBE_ICON .. ":0|t" },
		{ name = "sized |T<path>:14|t", text = "|T" .. TEXTPROBE_ICON .. ":14|t" },
		{ name = "h:w   |T<path>:14:14|t", text = "|T" .. TEXTPROBE_ICON .. ":14:14|t" },
		{ name = "offs  |T<path>:14:14:0:0|t", text = "|T" .. TEXTPROBE_ICON .. ":14:14:0:0|t" },
	}
	local anyRendered = false
	for i = 1, table.getn(forms) do
		scratch:SetText(forms[i].text)
		local w = scratch:GetStringWidth() or 0
		-- An icon occupies roughly one line; the literal path is 35+ characters,
		-- so the gap between the two outcomes is an order of magnitude.
		local rendered = w > 0 and w < emWidth * 4
		if rendered then anyRendered = true end
		D.Log(string.format("  escape %s -> %.1fpx  %s", forms[i].name, w,
			rendered and "RENDERS AS ICON" or "printed as text"))
		if textProbeFrame.lines[i] then
			textProbeFrame.lines[i]:SetText(forms[i].name .. "  " .. forms[i].text)
		end
	end
	D.Log("  verdict: inline texture escapes " ..
		(anyRendered and "WORK in a FontString here -- which contradicts the recorded answer"
		 or "do not work in a FontString here (the recorded answer)"))
	D.Log("  ICON_LIST = " .. type(ICON_LIST) .. ", ICON_TAG_LIST = " .. type(ICON_TAG_LIST))

	-- Height. Upstream's auto-width text region measures GetStringHeight, which
	-- this client does not have; whether GetHeight stands in for it decides
	-- whether an auto-sized text region is possible at all.
	scratch:SetText("one line")
	local h1 = scratch:GetHeight() or 0
	scratch:SetText("a\nb\nc")
	local h3 = scratch:GetHeight() or 0
	D.Log(string.format("  GetHeight: 1 line = %.1f, 3 lines = %.1f -- %s", h1, h3,
		(h3 > h1 * 2) and "tracks the rendered text" or "does NOT track line count"))

	scratch:SetWidth(120)
	scratch:SetText("a long enough string that it has to wrap across several lines at this width")
	local hWrap = scratch:GetHeight() or 0
	D.Log(string.format("  GetHeight at width 120 with wrapping text = %.1f -- %s", hWrap,
		(hWrap > h1 * 1.5) and "sees the wrap" or "does NOT see the wrap"))
	scratch:SetWidth(0)

	-- The font list and the flag combinations, read back the way textCore does.
	local core = WA.textCore
	if core then
		for i = 1, table.getn(core.FONTS) do
			local f = core.FONTS[i]
			scratch:SetFont(f.path, 12, "")
			D.Log("  font " .. f.name .. " -> " .. (scratch:GetFont() and "loads" or "REFUSED"))
		end
		scratch:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
		for i = 1, table.getn(core.FLAGS) do
			local flags = core.FLAGS[i]
			local applied = (flags == "None") and "" or flags
			scratch:SetFont("Fonts\\FRIZQT__.TTF", 12, applied)
			D.Log("  flags " .. flags .. " -> " .. (scratch:GetFont() and "accepted" or "REFUSED"))
		end
		scratch:SetFont("Fonts\\FRIZQT__.TTF", 12, "")
	end

	-- The two text widgets nothing in this addon uses. A FontString having no
	-- escape parser does not prove the engine has none, and these are the only
	-- other places an icon could sit inside a run of text.
	--
	-- SimpleHTML is the interesting one: on later clients it takes <img src=...>,
	-- which is a real inline-image path rather than an escape. It builds its
	-- content out of child regions, so whether the tag was honoured is readable
	-- without an eye -- an honoured <img> has to produce a Texture region.
	local function regionKinds(f)
		local counts = {}
		if not f or not f.GetNumRegions then return counts end
		local n = f:GetNumRegions() or 0
		local regions = { f:GetRegions() }
		for i = 1, n do
			local r = regions[i]
			if r and r.GetObjectType then
				local t = r:GetObjectType()
				counts[t] = (counts[t] or 0) + 1
			end
		end
		return counts
	end
	local function describe(counts)
		local parts = {}
		for kind, n in pairs(counts) do table.insert(parts, kind .. "x" .. n) end
		if table.getn(parts) == 0 then return "no regions" end
		table.sort(parts)
		return table.concat(parts, " ")
	end

	local madeHtml, html = pcall(CreateFrame, "SimpleHTML", nil, UIParent)
	if not madeHtml or not html then
		D.Log("  SimpleHTML: CreateFrame refused the type -- not available here")
	else
		html:SetWidth(300); html:SetHeight(40)
		html:SetPoint("TOP", textProbeFrame, "BOTTOM", 0, -8)
		-- SimpleHTML draws nothing until its element fonts are set, and the
		-- per-element signature is not confirmed here, so try both shapes.
		pcall(html.SetFontObject, html, "p", GameFontHighlight)
		pcall(html.SetFontObject, html, GameFontHighlight)
		pcall(html.SetFont, html, "p", "Fonts\\FRIZQT__.TTF", 12, "")

		local okPlain = pcall(html.SetText, html, "<html><body><p>plain text</p></body></html>")
		local before = regionKinds(html)
		local okImg = pcall(html.SetText, html,
			"<html><body><p><img src=\"" .. TEXTPROBE_ICON .. "\" width=\"16\" height=\"16\"/>after</p></body></html>")
		local after = regionKinds(html)
		D.Log("  SimpleHTML SetText: plain=" .. tostring(okPlain) .. " img=" .. tostring(okImg))
		D.Log("  SimpleHTML regions plain    -> " .. describe(before))
		D.Log("  SimpleHTML regions with img -> " .. describe(after))
		D.Log("  verdict: <img> " ..
			(((after.Texture or 0) > (before.Texture or 0)) and "CREATES A TEXTURE -- inline images are possible"
			 or "adds no texture -- the tag is not honoured"))
	end

	local madeMsg, msg = pcall(CreateFrame, "MessageFrame", nil, UIParent)
	if not madeMsg or not msg then
		D.Log("  MessageFrame: CreateFrame refused the type")
	else
		msg:SetWidth(300); msg:SetHeight(20)
		msg:SetPoint("TOP", textProbeFrame, "BOTTOM", 0, -56)
		pcall(msg.SetFontObject, msg, GameFontHighlight)
		local plainKinds, escKinds
		pcall(msg.AddMessage, msg, "plain")
		plainKinds = regionKinds(msg)
		pcall(msg.AddMessage, msg, "|T" .. TEXTPROBE_ICON .. ":0|t")
		escKinds = regionKinds(msg)
		D.Log("  MessageFrame regions plain  -> " .. describe(plainKinds))
		D.Log("  MessageFrame regions escape -> " .. describe(escKinds))
	end

	-- The chat frame is a ScrollingMessageFrame and is the one widget Blizzard
	-- would have needed an escape parser for. Straight to the user's own chat,
	-- since that is the honest test of it.
	DEFAULT_CHAT_FRAME:AddMessage("WA textprobe -- chat escape test: [|T" .. TEXTPROBE_ICON
		.. ":0|t] <- an icon between the brackets, or a path?")

	D.Log("  a chat line was printed: if it shows an icon between the brackets, a")
	D.Log("  ScrollingMessageFrame honours escapes even though a FontString does not.")
	D.Log("  panels are up under CENTER,0,-160: the escape forms, then SimpleHTML, then")
	D.Log("  the MessageFrame. Report what each one reads as.")
	D.Log("--- end textprobe ---")
end

-- pfUI's copy, used only as a test subject: it is a vendored monospace TTF
-- already on this client, so it answers "can SetFont load one at all" without
-- committing to vendoring our own before the answer is known.
local PROBE_FONT = "Interface\\AddOns\\pfUI\\fonts\\RobotoMono.ttf"

local codeProbeFrame, codeProbeEdit, codeProbeMeasure

-- The Q-INDEX/Q-ARROW subject. Raw byte offsets into "|cffff0000abc|rdef":
-- the escape is 0..9, "abc" 10..12, "|r" 13..14, "def" 15..17, end 18.
local PROBE_TEXT = "|cffff0000abc|rdef"

-- Confirmed in-game: a \1 survives Insert -> GetText intact, so the 1-byte
-- control character is the sentinel rather than upstream's 3-byte U+E000.
local SENTINEL = "\1"

-- Reads the caret as a raw byte offset. This client has no GetCursorPosition
-- (ClassicAPI TODO #96), so the position is recovered by inserting a byte the
	-- text cannot contain and finding it -- the same trick the caret
-- save/restore rests on, which this therefore also proves out. Destructive:
-- restoring the text resets the caret, so each read needs the key presses
-- redone.
local function probeReadCaret()
	local before = codeProbeEdit:GetText() or ""
	codeProbeEdit:Insert(SENTINEL)
	local at = string.find(codeProbeEdit:GetText() or "", SENTINEL, 1, true)
	codeProbeEdit:SetText(before)
	return at and (at - 1)
end

-- From the end of PROBE_TEXT, four Lefts land on raw 12 if the engine steps
-- over the |r escape as one unit, and on raw 14 if it walks through it byte by
-- byte (three presses to cross two invisible bytes -- the UX failure that kills
-- live colorizing).
local function probeCaretVerdict(at)
	if at == 12 or at == 13 then
		return "stepped OVER the escape -- Q-ARROW PASSES, live colorizing is viable"
	elseif at == 14 then
		return "stopped INSIDE the |r escape -- Q-ARROW FAILS, caret handling needs revision"
	elseif at == 15 then
		return "just before 'd' -- that is only 3 Lefts; redo with 4"
	elseif at == 18 then
		return "still at the end -- the arrow presses did not register"
	end
	return "unexpected; click at the very end, press Left exactly 4 times, then Tab"
end

local function codeProbeBuild()
	if codeProbeFrame then return end

	codeProbeFrame = CreateFrame("Frame", "WA_CodeProbeFrame", UIParent)
	codeProbeFrame:SetWidth(420); codeProbeFrame:SetHeight(200)
	codeProbeFrame:SetPoint("CENTER", UIParent, "CENTER", -260, 0)
	codeProbeFrame:SetBackdrop(WA.Widgets.PANEL_BACKDROP)
	codeProbeFrame:SetBackdropColor(0, 0, 0, 1)
	codeProbeFrame:SetFrameStrata("DIALOG")
	codeProbeFrame:SetToplevel(true)
	codeProbeFrame:SetMovable(true)
	codeProbeFrame:EnableMouse(true)
	codeProbeFrame:RegisterForDrag("LeftButton")
	codeProbeFrame:SetScript("OnDragStart", function() codeProbeFrame:StartMoving() end)
	codeProbeFrame:SetScript("OnDragStop", function() codeProbeFrame:StopMovingOrSizing() end)

	local title = codeProbeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", 0, -12)
	title:SetText("Code editor probe")
	title:SetTextColor(1, 0.82, 0)

	local close = CreateFrame("Button", nil, codeProbeFrame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() codeProbeFrame:Hide() end)

	-- A real multi-line box, matching what NewCodeEditBox would decorate: the
	-- answers must come from the same widget shape the editor will use.
	codeProbeEdit = CreateFrame("EditBox", "WA_CodeProbeEdit", codeProbeFrame)
	codeProbeEdit:SetMultiLine(true)
	codeProbeEdit:SetAutoFocus(false)
	codeProbeEdit:SetFontObject(GameFontHighlightSmall)
	codeProbeEdit:SetTextInsets(4, 4, 4, 4)
	codeProbeEdit:SetPoint("TOPLEFT", 14, -36)
	codeProbeEdit:SetWidth(392); codeProbeEdit:SetHeight(60)
	-- Colorizing multiplies the buffer, so an editor must lift both limits or
	-- the user's code is silently truncated. Lift them here too, or a long
	-- probe string would answer the wrong question.
	codeProbeEdit:SetMaxBytes(0)
	codeProbeEdit:SetMaxLetters(0)
	codeProbeEdit:SetScript("OnEscapePressed", function() codeProbeEdit:ClearFocus() end)
	-- Tab, not a button: clicking anything else risks moving focus, and a
	-- refocused EditBox may reset its caret -- which would silently corrupt the
	-- one measurement this is here to take.
	codeProbeEdit:SetScript("OnTabPressed", function()
		local at = probeReadCaret()
		if not at then
			D.Log("  [Q-ARROW] caret read FAILED -- sentinel did not survive Insert")
			return
		end
		D.Log("  [Q-ARROW] caret at raw byte " .. at .. " -- " .. probeCaretVerdict(at))
	end)

	local bg = CreateFrame("Frame", nil, codeProbeFrame)
	bg:SetPoint("TOPLEFT", codeProbeEdit, "TOPLEFT", -4, 4)
	bg:SetPoint("BOTTOMRIGHT", codeProbeEdit, "BOTTOMRIGHT", 4, -4)
	bg:SetBackdrop(WA.Widgets.EDITBOX_BACKDROP)
	bg:SetBackdropColor(0, 0, 0, 0.7)
	bg:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

	local hint = codeProbeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hint:SetPoint("TOPLEFT", 14, -104)
	hint:SetPoint("RIGHT", -14, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText("Q-INDEX: click a button, see which run highlights.\n"
		.. "Q-ARROW: click at the very END of the text, press Left 4 times,\n"
		.. "then press TAB -- the caret offset and verdict go to the log.\n"
		.. "(Each Tab read restores the text, so redo the presses to re-measure.)")
	hint:SetTextColor(0.8, 0.8, 0.8)

	-- The Q-INDEX pair. Raw bytes of "|cffff0000abc|rdef": the escape is 0..9,
	-- "abc" 10..12, "|r" 13..14, "def" 15..17. Visible text is "abcdef", so
	-- "def" is 3..5 there. Whichever button lights up "def" names the indexing.
	local b1 = WA.Widgets.button(codeProbeFrame, "HighlightText(15,18)", function()
		codeProbeEdit:SetText(PROBE_TEXT)
		codeProbeEdit:SetFocus()
		codeProbeEdit:HighlightText(15, 18)
		D.Log("  [Q-INDEX] HighlightText(15,18) -- if 'def' is selected, indices are RAW BYTES")
	end)
	b1:SetWidth(150)
	b1:SetPoint("BOTTOMLEFT", 14, 14)

	local b2 = WA.Widgets.button(codeProbeFrame, "HighlightText(3,6)", function()
		codeProbeEdit:SetText(PROBE_TEXT)
		codeProbeEdit:SetFocus()
		codeProbeEdit:HighlightText(3, 6)
		D.Log("  [Q-INDEX] HighlightText(3,6) -- if 'def' is selected, indices are VISIBLE CHARS")
	end)
	b2:SetWidth(150)
	b2:SetPoint("LEFT", b1, "RIGHT", 8, 0)
end

-- Inserts `s` at the caret and reports whether it survives a GetText()
-- round-trip -- the sentinel the caret save/restore relies on.
local function probeSentinel(label, s, wantByte)
	codeProbeEdit:SetText("")
	codeProbeEdit:SetFocus()
	local ok, err = pcall(function() codeProbeEdit:Insert(s) end)
	if not ok then
		D.Log("  [Q-SENTINEL] " .. label .. ": Insert errored -- " .. tostring(err))
		return
	end
	local got = codeProbeEdit:GetText() or ""
	local found = nil
	for i = 1, string.len(got) do
		if string.byte(got, i) == wantByte then found = i; break end
	end
	D.Log("  [Q-SENTINEL] " .. label .. ": GetText len " .. string.len(got)
		.. ", byte " .. wantByte .. (found and (" found at " .. found) or " NOT FOUND"))
	codeProbeEdit:SetText("")
	codeProbeEdit:ClearFocus()
end

function D.CodeProbe()
	D.Log("--- code editor probe ---")
	codeProbeBuild()
	codeProbeFrame:Show()

	-- Does GetText hand back the raw escapes, or the rendered text? Everything
	-- else assumes the former: an editor that reads back stripped text would
	-- lose the user's own literal pipes.
	local src = "|cffff0000red|r plain"
	codeProbeEdit:SetText(src)
	local got = codeProbeEdit:GetText() or ""
	D.Log("  [round-trip] set " .. string.len(src) .. " bytes, GetText returned " .. string.len(got)
		.. " (raw = " .. string.len(src) .. ", stripped would be 9)")
	D.Log("  [round-trip] identical: " .. (got == src and "YES" or "NO -- got \"" .. got .. "\""))
	D.Log("  ^^ LOOK AT THE BOX: 'red' should be red with no visible |cffff0000.")

	probeSentinel("\\1 (ASCII control)", "\1", 1)
	-- U+E000 in UTF-8; upstream's own sentinel, kept as the fallback if the
	-- control byte is eaten.
	probeSentinel("U+E000", "\238\128\128", 238)

	-- Restore the Q-INDEX subject so the two buttons act on the same text the
	-- hint describes.
	codeProbeEdit:SetText(PROBE_TEXT)

	-- Which text-height reading this client offers. GetStringHeight is a 3.3.5
	-- method and is absent here -- calling it errors, which is exactly how the
	-- multiline box's text measuring first broke. A FontString sizes its own
	-- region to its text, so GetHeight is the one that works.
	if not codeProbeMeasure then
		codeProbeMeasure = codeProbeFrame:CreateFontString(nil, "BACKGROUND", "GameFontHighlightSmall")
		codeProbeMeasure:SetPoint("BOTTOMLEFT", codeProbeFrame, "BOTTOMLEFT", 14, 40)
		codeProbeMeasure:SetAlpha(0)
		codeProbeMeasure:SetJustifyH("LEFT")
	end
	codeProbeMeasure:SetWidth(200)
	codeProbeMeasure:SetText("one\ntwo\nthree")
	D.Log("  [measure] FontString:GetStringHeight = "
		.. (codeProbeMeasure.GetStringHeight and "present" or "ABSENT")
		.. ", GetHeight over 3 lines = "
		.. tostring(codeProbeMeasure.GetHeight and codeProbeMeasure:GetHeight() or "ABSENT"))

	local ok, err = pcall(function() codeProbeEdit:SetFont(PROBE_FONT, 12, "") end)
	D.Log("  [Q-FONT] SetFont(RobotoMono, 12): " .. (ok and "no error" or ("FAILED -- " .. tostring(err))))
	if ok then
		local f, sz = codeProbeEdit:GetFont()
		D.Log("  [Q-FONT] GetFont now: " .. tostring(f) .. " @ " .. tostring(sz)
			.. " -- if this is not RobotoMono the call was a silent no-op")
	end

	-- Settled 2026-08-02 on this client; the buttons stay so another build can be
	-- re-checked rather than assumed.
	D.Log("  [Q-INDEX] answered: RAW BYTES. The two buttons re-check it.")
	D.Log("  [Q-ARROW] OPEN: click at the very END of the box, press Left 4 times, then TAB.")
	D.Log("  live colorizing: WeakestAurasDB.codeEditorLive = "
		.. tostring(WeakestAurasDB and WeakestAurasDB.codeEditorLive)
		.. " (nil = on, the default; toggle with /wa codelive)")
	D.Log("--- end code probe ---")
end

-- Live colouring is on unless turned off here. Unset means on, so the toggle
-- resolves the default before negating it -- `not nil` would read as "it was
-- off" and leave the setting where it started.
function D.CodeLive()
	if not WeakestAurasDB then D.Log("no saved variables yet"); return end
	local on = WeakestAurasDB.codeEditorLive
	if on == nil then on = true end
	WeakestAurasDB.codeEditorLive = not on
	D.Log("live code colouring: " .. (WeakestAurasDB.codeEditorLive and "ON" or "OFF")
		.. " -- reopen the options tab to apply.")
	if WA.RefreshOptions then WA.RefreshOptions() end
end

-- Point size of the code boxes' fixed-width face.
function D.CodeFont(rest)
	if not WeakestAurasDB then D.Log("no saved variables yet"); return end
	local n = tonumber(rest)
	if n and n >= 6 and n <= 16 then
		WeakestAurasDB.codeEditorFontSize = n
	elseif rest and rest ~= "" then
		D.Log("usage: /wa codefont <6-16>")
		return
	end
	D.Log("code font size: "
		.. tostring(WeakestAurasDB.codeEditorFontSize or WA.Widgets.CODE_FONT_SIZE)
		.. " -- reopen the options tab to apply.")
	if WA.RefreshOptions then WA.RefreshOptions() end
end

-- Spaces per indent level for Tab in a code box; "tabs" switches to hard tabs.
function D.CodeTab(rest)
	if not WeakestAurasDB then D.Log("no saved variables yet"); return end
	local arg = string.lower(rest or "")
	if arg == "tabs" then
		WeakestAurasDB.codeEditorTabWidth = false
	else
		local n = tonumber(arg)
		if n and n >= 1 and n <= 8 then
			WeakestAurasDB.codeEditorTabWidth = n
		elseif arg ~= "" then
			D.Log("usage: /wa codetab <1-8|tabs>")
			return
		end
	end
	local cur = WeakestAurasDB.codeEditorTabWidth
	if cur == nil then cur = 2 end
	D.Log("code indent width: " .. (cur == false and "hard tabs" or (tostring(cur) .. " spaces"))
		.. " -- reopen the options tab to apply.")
	if WA.RefreshOptions then WA.RefreshOptions() end
end

-- ---------------------------------------------------------------------------
-- /wa commprobe -- the server-side unknowns behind sharing auras through chat,
-- none of which a type check can answer: whether SendAddonMessage's WHISPER
-- channel delivers on this realm (every neighbouring addon only ever uses
-- RAID/PARTY/GUILD), what the byte cap really is, what send rate survives, and
-- whether a link type of our own renders, is clickable, and reaches SetItemRef.
-- ---------------------------------------------------------------------------

local COMM_PREFIX = "WKA"

-- Ladder bodies are cut from the base64 alphabet a real payload is made of, so
-- a byte this chat system mangles surfaces here rather than mid-transfer.
local COMM_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local commFrame, commRefHooked
local commSent, commOrder = {}, {}

local function commBody(n)
	local out, alen = {}, string.len(COMM_ALPHABET)
	for i = 1, n do
		local k = math.mod(i - 1, alen) + 1
		table.insert(out, string.sub(COMM_ALPHABET, k, k))
	end
	return table.concat(out)
end

-- Logs every arrival as it lands rather than only tallying at the end: if the
-- realm reorders, delays or drops a chunk, the ordering is itself the finding.
local function commOnEvent()
	if event ~= "CHAT_MSG_ADDON" or arg1 ~= COMM_PREFIX then return end
	local msg, channel, sender = arg2 or "", arg3, arg4
	local _, _, tag, body = string.find(msg, "^([^:]+):(.*)$")
	if not tag then
		D.Log("  [recv] unparseable from " .. tostring(sender) .. " (" .. tostring(channel)
			.. "), " .. string.len(msg) .. "B: " .. string.sub(msg, 1, 40))
		return
	end

	local rec = commSent[tag]
	local got = string.len(body)
	local note
	if not rec then
		note = "no record of sending this tag"
	elseif got ~= rec.bodyLen then
		note = "TRUNCATED/PADDED -- sent " .. rec.bodyLen .. "B body, got " .. got .. "B"
	elseif body ~= commBody(got) then
		note = "CORRUPT -- length right, bytes differ"
	else
		note = "intact"
		rec.ok = true
	end
	if rec then rec.arrived = true end

	D.Log("  [recv] " .. tag .. " from " .. tostring(sender) .. " via " .. tostring(channel)
		.. ", msg " .. string.len(msg) .. "B: " .. note)
end

local function commEnsureListener()
	if commFrame then return end
	commFrame = CreateFrame("Frame")
	commFrame:RegisterEvent("CHAT_MSG_ADDON")
	commFrame:SetScript("OnEvent", commOnEvent)
	-- Some servers drop addon traffic on prefixes nobody registered. Absent on
	-- vanilla, so its absence is a result and not a failure.
	if type(RegisterAddonMessagePrefix) == "function" then
		pcall(RegisterAddonMessagePrefix, COMM_PREFIX)
	end
end

-- ChatThrottleLib's v13/v14 global hook is `Hook_SendAddonMessage(prefix, text,
-- chattype)` -- three parameters, so it drops the whisper target and the client
-- rejects the call as an unknown chat type. Several addons vendor a copy (aux,
-- DPSMate), and whichever loads last owns the global, so a whisper here has to
-- go to the function CTL saved rather than through the global. Its own v15
-- rewrite neither hooks the global nor keeps that field, hence the fallback.
local function commRawSender()
	if ChatThrottleLib and type(ChatThrottleLib.ORIG_SendAddonMessage) == "function" then
		return ChatThrottleLib.ORIG_SendAddonMessage, "CTL.ORIG_SendAddonMessage"
	end
	return SendAddonMessage, "global SendAddonMessage (no ORIG saved)"
end

local function commSend(tag, bodyLen, channel, target, raw)
	local msg = tag .. ":" .. commBody(bodyLen)
	local rec = { bodyLen = bodyLen, wire = string.len(msg), channel = channel }
	commSent[tag] = rec
	table.insert(commOrder, tag)
	local fn = raw and commRawSender() or SendAddonMessage
	local ok, err = pcall(fn, COMM_PREFIX, msg, channel, target)
	if not ok then
		rec.sendFailed = true
		D.Log("  [send] " .. tag .. " (" .. channel .. (raw and ", raw" or ", hooked") .. ", "
			.. rec.wire .. "B) ERRORED -- " .. tostring(err))
	end
	return ok
end

local function commReport(header)
	D.Log(header)
	for i = 1, table.getn(commOrder) do
		local tag = commOrder[i]
		local rec = commSent[tag]
		local state
		if rec.sendFailed then state = "send errored"
		elseif rec.ok then state = "OK"
		elseif rec.arrived then state = "arrived MANGLED"
		else state = "NEVER ARRIVED" end
		D.Log("    " .. tag .. " (" .. rec.channel .. ", " .. rec.wire .. "B on the wire): " .. state)
	end
end

-- Our own link type, end to end: rendered into a chat frame, clicked by hand,
-- caught here. Wrap-and-forward because this client's SetItemRef cannot be
-- hooked securely, and because pfUI replaces the same global -- logging the
-- function identity is how the composition question gets answered.
local function commHookSetItemRef()
	if commRefHooked then return end
	commRefHooked = true
	local orig = SetItemRef
	SetItemRef = function(link, text, button)
		local _, _, sender, name = string.find(link or "", "^weakestauras:([^:]+):(.*)$")
		if sender then
			D.Log("  [link] SetItemRef REACHED -- sender=\"" .. sender .. "\" name=\"" .. name
				.. "\" button=" .. tostring(button))
			return
		end
		if orig then return orig(link, text, button) end
	end
end

function D.CommProbe(rest)
	local _, _, sub, tail = string.find(rest or "", "^(%S*)%s*(.-)$")
	if string.lower(sub or "") == "throttle" then return D.CommThrottle(tail) end

	commSent, commOrder = {}, {}
	commEnsureListener()
	D.Log("--- comm probe ---")

	local names = {
		"SendAddonMessage", "RegisterAddonMessagePrefix", "SetItemRef",
		"ChatFrame_AddMessageEventFilter", "GetCurrentKeyBoardFocus",
	}
	for i = 1, table.getn(names) do
		D.Log("  [api] " .. names[i] .. " = " .. type(getglobal(names[i])))
	end
	D.Log("  [api] NUM_CHAT_WINDOWS = " .. tostring(NUM_CHAT_WINDOWS)
		.. ", ChatFrameEditBox = " .. type(ChatFrameEditBox)
		.. (ChatFrameEditBox and (" (Insert=" .. type(ChatFrameEditBox.Insert)
			.. " IsVisible=" .. type(ChatFrameEditBox.IsVisible)
			.. " Show=" .. type(ChatFrameEditBox.Show) .. ")") or ""))
	D.Log("  [api] pfUI = " .. type(pfUI) .. ", pfUI chat module = "
		.. ((pfUI and pfUI.chat) and "loaded" or "not loaded"))
	D.Log("  [api] SetItemRef identity before our wrap: " .. tostring(SetItemRef))

	-- Whether AddMessage is already someone else's wrapper decides whether the
	-- incoming-rewrite hook composes or clobbers.
	local shared = 0
	for i = 1, (NUM_CHAT_WINDOWS or 0) do
		local cf = getglobal("ChatFrame" .. i)
		if cf and cf.AddMessage then
			if cf.AddMessage ~= ChatFrame1.AddMessage then shared = shared + 1 end
		end
	end
	D.Log("  [api] chat frames with an AddMessage differing from ChatFrame1's: " .. shared
		.. " (nonzero means at least one is individually wrapped)")

	commHookSetItemRef()
	DEFAULT_CHAT_FRAME:AddMessage(
		"|Hweakestauras:Probe:Test Aura|h|cff8800ff[Probe - Test Aura]|h|r"
		.. " <- CLICK THIS. Coloured and clickable = the link type works.")
	D.Log("  [link] wrapper installed, sample line printed to the default chat frame.")
	D.Log("  ^^ CLICK IT, and shift-click it too. Then run this again with pfUI's chat module toggled.")

	local _, rawWhich = commRawSender()
	D.Log("  [ctl] ChatThrottleLib = " .. type(ChatThrottleLib)
		.. (ChatThrottleLib and (" v" .. tostring(ChatThrottleLib.version)
			.. ", ORIG_SendAddonMessage = " .. type(ChatThrottleLib.ORIG_SendAddonMessage)) or ""))
	D.Log("  [ctl] raw whisper attempts go through " .. rawWhich)

	-- Sent through the hooked global and through the saved original both, so a
	-- refusal separates "this realm has no whisper channel" from "a third-party
	-- hook ate the target argument".
	local me = UnitName("player")
	commSend("S001", 60, "WHISPER", me)
	commSend("R001", 60, "WHISPER", me, true)
	if tail and tail ~= "" then commSend("R002", 60, "WHISPER", tail, true) end

	local inGuild = IsInGuild and IsInGuild()
	local inParty = GetNumPartyMembers and GetNumPartyMembers() > 0
	commSend("G001", 60, "GUILD")
	if inParty then
		commSend("P001", 60, "PARTY")
	else
		D.Log("  [send] PARTY skipped -- not in a party, so silence would prove nothing.")
	end

	-- The cap is nominally 255 for prefix\tmessage, but nominal is exactly what
	-- this is here to check. Ridden over whichever channel is known to deliver,
	-- so the answer doesn't depend on the whisper question resolving first.
	local ladderChan, ladderTarget, ladderRaw
	if inGuild then ladderChan = "GUILD"
	elseif inParty then ladderChan = "PARTY"
	else ladderChan, ladderTarget, ladderRaw = "WHISPER", me, true end
	D.Log("  [send] byte ladder rides " .. ladderChan)
	local ladder = { 180, 200, 220, 240, 250 }
	for i = 1, table.getn(ladder) do
		local n = ladder[i]
		commSend("L" .. n, n - 5, ladderChan, ladderTarget, ladderRaw)
	end

	D.Log("  [send] " .. table.getn(commOrder) .. " messages away; tally in 10s.")
	C_Timer.After(10, function()
		commReport("  --- comm probe tally ---")
		D.Log("  S001 dead but R001 alive = a hooked global ate the target, not the realm.")
		D.Log("  Both dead = no whisper channel here, and sharing takes the group-channel fallback.")
		D.Log("  Then: /wa commprobe throttle [channel] [rate] [seconds]")
		D.Log("--- end comm probe ---")
	end)
end

-- Deliberately opt-in and separate: this is the one probe that can get the
-- character disconnected for addon spam, so it never runs as part of the sweep
-- above and it starts gentle.
function D.CommThrottle(rest)
	local _, _, chan, rateStr, secsStr = string.find(rest or "", "^(%S*)%s*(%S*)%s*(%S*)$")
	chan = string.upper(chan or "")
	if chan == "" then chan = "WHISPER" end
	local rate = tonumber(rateStr) or 4
	local secs = tonumber(secsStr) or 5
	if rate < 1 then rate = 1 elseif rate > 20 then rate = 20 end
	if secs < 1 then secs = 1 elseif secs > 10 then secs = 10 end

	local total = rate * secs
	commSent, commOrder = {}, {}
	commEnsureListener()
	D.Log("--- comm throttle: " .. total .. " messages at " .. rate .. "/sec over "
		.. secs .. "s on " .. chan .. " ---")
	D.Log("  A disconnect here IS the answer. Step the rate up only after a clean run.")

	local me = UnitName("player")
	local sent = 0
	local ticker
	ticker = C_Timer.NewTicker(1 / rate, function()
		sent = sent + 1
		local isWhisper = (chan == "WHISPER")
		commSend("T" .. sent, 95, chan, isWhisper and me or nil, isWhisper)
		if sent >= total and ticker and ticker.Cancel then ticker:Cancel() end
	end)

	C_Timer.After(secs + 6, function()
		local arrived = 0
		for i = 1, table.getn(commOrder) do
			if commSent[commOrder[i]].ok then arrived = arrived + 1 end
		end
		D.Log("  [throttle] " .. arrived .. " of " .. table.getn(commOrder)
			.. " sent messages came back intact at " .. rate .. "/sec.")
		if arrived < table.getn(commOrder) then
			commReport("  --- which ones ---")
		end
		D.Log("--- end comm throttle ---")
	end)
end

-- ---------------------------------------------------------------------------
-- /wa ver [version] -- what this client believes its own version is, and, with
-- an argument, a beacon injected as though a peer had sent it. The update notice
-- is otherwise unreachable without a second account running a build that does
-- not exist yet. The outcome is reported because most claims are *meant* to be
-- ignored -- equal, already beaten, unparseable, or too far ahead to believe.
-- ---------------------------------------------------------------------------

function D.Version(rest)
	local C = WA.Comm
	D.Log("--- version ---")
	D.Log("  GetAddOnMetadata = " .. type(GetAddOnMetadata))
	D.Log("  WA.version = " .. tostring(WA.version)
		.. " (parses as " .. tostring(WA.ParseVersion(WA.version)) .. ")")
	D.Log("  highest claim heard this session = " .. tostring(C.latestSeenVersion))
	D.Log("  updateNotify = " .. tostring(WA.Options().updateNotify))
	if not rest or rest == "" then
		D.Log("  /wa ver <version> feeds a beacon as if a peer had sent it")
		D.Log("--- end version ---")
		return
	end

	local before = C.latestSeenVersion
	C.FeedBeacon(rest)
	if C.latestSeenVersion ~= before then
		D.Log("  fed " .. rest .. " -- believed")
	elseif not WA.ParseVersion(rest) then
		D.Log("  fed " .. rest .. " -- dropped: not x.y or x.y.z with each part under 1000")
	else
		D.Log("  fed " .. rest .. " -- ignored: not newer than " .. tostring(WA.version)
			.. ", not higher than " .. tostring(before) .. ", or more than one major ahead")
	end
	D.Log("--- end version ---")
end

-- A Trigger State Updater's clones and the hide timers holding them, side by
-- side. The two disagree exactly when a clone is going away for a reason other
-- than its own deadline: a state with no armed record is being removed by
-- something else, and a record whose armedDelay does not match the deadline the
-- aura asked for is the timer being given the wrong length.
function D.Tsu(id)
	if not id or id == "" then
		D.Log("[tsu] usage: /wa tsu <aura id>")
		return
	end
	local ts = WA.GetDisplayTriggerState and WA.GetDisplayTriggerState(id)
	if not ts then
		D.Log(string.format("[tsu] no triggerState for %q", id))
		return
	end
	local now = GetTime()
	local armed = {}
	if WA.ForEachStateTimer then
		WA.ForEachStateTimer(id, function(triggernum, cloneId, record)
			armed[triggernum .. "\001" .. tostring(cloneId)] = record
		end)
	end
	D.Log(string.format("--- tsu %q at t=%.2f ---", id, now))
	for triggernum = 1, ts.numTriggers do
		local allstates = ts[triggernum]
		if allstates then
			for cloneId, state in pairs(allstates) do
				local record = armed[triggernum .. "\001" .. tostring(cloneId)]
				D.Log(string.format(
					"  [%d] %q show=%s autoHide=%s paused=%s expiration=%s (in %s) remaining=%s",
					triggernum, tostring(cloneId), tostring(state.show), tostring(state.autoHide),
					tostring(state.paused), tostring(state.expirationTime),
					state.expirationTime and string.format("%.2f", state.expirationTime - now) or "n/a",
					tostring(state.remaining)))
				if record and record.handle then
					D.Log(string.format(
						"        timer armed %.2f ago for %.2f -> fires in %.2f",
						now - (record.armedAt or now), record.armedDelay or -1,
						(record.armedAt or now) + (record.armedDelay or 0) - now))
				else
					D.Log("        timer: NONE ARMED")
				end
			end
		end
	end
	D.Log("--- end tsu ---")
end

-- Logs every arm/fire/cancel of a state-owned hide timer. A clone vanishing
-- with no "fire" line ahead of it was removed by something other than its own
-- timer, which is the distinction /wa tsu can only sample.
function D.ToggleTsuTrace()
	if WA.OnStateTimer then
		WA.OnStateTimer = nil
		D.Log("[tsu] timer trace off")
		return
	end
	WA.OnStateTimer = function(what, id, triggernum, cloneId, seconds)
		D.Log(string.format("[tsu] %s %s[%s] clone %q %.2fs (t=%.2f)",
			what, tostring(id), tostring(triggernum), tostring(cloneId),
			tonumber(seconds) or -1, GetTime()))
		-- A cancel is the interesting one: it means something took the timer away
		-- rather than the deadline arriving, and the only thing that identifies
		-- *what* is the caller. Guarded because the debug library's presence on
		-- this client is not something to assume.
		if what == "cancel" and debug and debug.traceback then
			local ok, trace = pcall(debug.traceback, "", 2)
			if ok and trace then
				local n = 0
				for line in string.gfind(trace, "[^\n]+") do
					n = n + 1
					if n > 6 then break end
					D.Log("        " .. line)
				end
			end
		end
	end
	D.Log("[tsu] timer trace on -- /wa tsutrace again to stop")
end

-- ---------------------------------------------------------------------------
-- Slash dispatch. Called from OptionsFrame.lua's /wa handler whenever the
-- command has an argument; a bare /wa still opens the options window.
-- ---------------------------------------------------------------------------

function D.HandleSlash(msg)
	local _, _, cmd, rest = string.find(msg, "^(%S+)%s*(.-)$")
	cmd = string.lower(cmd or "")

	if cmd == "dump" then
		local _, _, unit, filter = string.find(rest, "^(%S*)%s*(%S*)$")
		D.Dump(unit, filter)
	elseif cmd == "watch" then
		D.ToggleWatch(rest)
	elseif cmd == "events" then
		D.ToggleEventLog(rest)
	elseif cmd == "auraprobe" then
		D.AuraProbe(rest)
	elseif cmd == "overflow" then
		D.Overflow(rest)
	elseif cmd == "timers" then
		D.Timers()
	elseif cmd == "linkprobe" then
		D.LinkProbe()
	elseif cmd == "commprobe" then
		D.CommProbe(rest)
	elseif cmd == "cdtest" then
		D.CooldownTest()
	elseif cmd == "swipetest" then
		D.SwipeTest(rest)
	elseif cmd == "swipenudge" then
		D.SwipeNudge(rest)
	elseif cmd == "track" then
		D.Track(rest)
	elseif cmd == "states" then
		D.States(rest)
	elseif cmd == "tsu" then
		D.Tsu(rest)
	elseif cmd == "tsutrace" then
		D.ToggleTsuTrace()
	elseif cmd == "conditions" then
		D.Conditions(rest)
	elseif cmd == "gen" then
		D.Gen(rest)
	elseif cmd == "load" then
		D.Load(rest)
	elseif cmd == "probe" then
		D.Probe()
	elseif cmd == "soundprobe" then
		D.SoundProbe()
	elseif cmd == "gcd" then
		D.Gcd()
	elseif cmd == "cdprobe" then
		D.CdProbe(rest)
	elseif cmd == "ver" then
		D.Version(rest)
	elseif cmd == "codeprobe" then
		D.CodeProbe()
	elseif cmd == "textprobe" then
		D.TextProbe()
	elseif cmd == "texprobe" then
		D.TexProbe()
	elseif cmd == "wa2probe" then
		D.Wa2Probe()
	elseif cmd == "wa2" then
		D.Wa2(rest)
	elseif cmd == "codelive" then
		D.CodeLive()
	elseif cmd == "codetab" then
		D.CodeTab(rest)
	elseif cmd == "codefont" then
		D.CodeFont(rest)
	elseif cmd == "rows" then
		D.Rows()
	elseif cmd == "configtest" then
		D.ConfigTest()
	elseif cmd == "libs" then
		D.Libs()
	elseif cmd == "addons" then
		D.Addons()
	elseif cmd == "export" then
		if WA.ShowExport then WA.ShowExport(rest) end
	elseif cmd == "import" then
		if WA.ShowImport then WA.ShowImport() end
	elseif cmd == "clear" then
		D.Clear()
	elseif cmd == "show" then
		D.Show()
	elseif cmd == "hide" then
		ensureFrame()
		frame:Hide()
	else
		D.Log("[debug] unknown command \"" .. cmd .. "\". Available: dump [unit] [filter], watch [unit], events [EVENT ...], auraprobe [unit|all], overflow [unit], timers, linkprobe, commprobe [charname|throttle [channel] [rate] [secs]], cdtest, swipetest [sizes/WxH...], swipenudge <k> [yflat], track <spellName>, states <id>, conditions <id>, gen <id>, load <id>, probe, soundprobe, gcd, cdprobe <spell>, ver [version], codeprobe, textprobe, texprobe, wa2probe, wa2 <string>, codelive, codetab <1-8|tabs>, codefont <6-16>, rows, configtest, libs, addons, export <id>, import, clear, show, hide")
	end
end
