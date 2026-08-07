-- WeakestAuras -- in-game probes and verification commands for the runtime
-- engine. Registers /wa probe, states, libs, addons, gen, load, conditions,
-- codeprobe, and cdtest.

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
-- /wa codeprobe -- checks the EditBox behavior needed by the code editor:
-- engine behaviour a syntax-highlighting code editor rests on, none of which
-- raw color escapes, indexing, caret movement, and sentinel round-trips.
--
-- Half of this is unavoidably a visual test -- whether a colour code *renders*
-- as colour, and where a selection actually lands, are things only an eye can
-- answer -- so the frame parks itself on screen with the steps that need
-- clicking, and only the machine-checkable parts go to the log.
-- ---------------------------------------------------------------------------

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
		.. " (toggle with /wa codelive)")
	D.Log("--- end code probe ---")
end

-- Live colouring is off by default: it recolours the box under the caret while
-- typing, which is the part of the code editor that leans hardest on engine
-- behaviour, so it stays opt-in until it has real use behind it.
function D.CodeLive()
	if not WeakestAurasDB then D.Log("no saved variables yet"); return end
	WeakestAurasDB.codeEditorLive = not WeakestAurasDB.codeEditorLive
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
	elseif cmd == "timers" then
		D.Timers()
	elseif cmd == "linkprobe" then
		D.LinkProbe()
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
	elseif cmd == "conditions" then
		D.Conditions(rest)
	elseif cmd == "gen" then
		D.Gen(rest)
	elseif cmd == "load" then
		D.Load(rest)
	elseif cmd == "probe" then
		D.Probe()
	elseif cmd == "codeprobe" then
		D.CodeProbe()
	elseif cmd == "codelive" then
		D.CodeLive()
	elseif cmd == "codetab" then
		D.CodeTab(rest)
	elseif cmd == "codefont" then
		D.CodeFont(rest)
	elseif cmd == "rows" then
		D.Rows()
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
		D.Log("[debug] unknown command \"" .. cmd .. "\". Available: dump [unit] [filter], watch [unit], events [EVENT ...], timers, linkprobe, cdtest, swipetest [sizes/WxH...], swipenudge <k> [yflat], track <spellName>, states <id>, conditions <id>, gen <id>, load <id>, probe, codeprobe, codelive, codetab <1-8|tabs>, codefont <6-16>, rows, libs, addons, export <id>, import, clear, show, hide")
	end
end
