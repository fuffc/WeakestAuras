-- WeakestAuras -- opt-in runtime profiler behind /wa prof: per-site wall time
-- and allocation, the session's churn and the collections it caused. Mirrors
-- the idea of WA2's Profiling.lua, scaled to a handful of measured sites.
--
-- Costs nothing until started: the inline WA.ProfBegin/ProfEnd hooks are one
-- flag test each, and the dispatch wrappers and the frame sampler exist only
-- while running. Nothing here persists -- a reload always comes back with
-- profiling off.

if WeakestAuras.disabled then return end

local WA = WeakestAuras

WA.Profiling = {}
local P = WA.Profiling

-- Millisecond clock. debugprofilestop advances within a frame; GetTime advances
-- once per frame, so the fallback can only resolve costs that span frames and
-- the report names which clock it is on.
local hiRes = type(debugprofilestop) == "function"
local clock
if hiRes then
	clock = debugprofilestop
else
	clock = function() return GetTime() * 1000 end
end

local active = false
local stats = {} -- key -> { n, total, max, depth, start, mem, kb, gcs }
local startedAt = nil -- GetTime() of the current run, nil while stopped
local runSeconds = 0 -- accumulated across earlier start/stop spans

-- Memory figures are gcinfo() KB: the whole client's heap, every addon's.
-- siteKB is the part of churnKB allocated while some measured site was open.
local churnKB, siteKB = 0, 0
local lastMem, lastTick = nil, nil
local open, openMem = 0, 0 -- measured sites on the stack; heap when the outermost opened
-- The worst collection's frame and the heap either side of it; the heap after
-- it is the live size.
local gcCount, gcWorstMs, gcPeakKB, gcAfterKB, worstFrameMs = 0, 0, 0, 0, 0

-- The heap also shrinks outside a collection, when a table rehashes smaller,
-- but by a few KB. A collection frees at least half of what it walks.
local GC_MIN_DROP_KB = 256

local function out(msg)
	if WA.Debug and WA.Debug.Log then
		WA.Debug.Log(msg)
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WeakestAuras|r " .. msg)
	end
end

local function stat(key)
	local s = stats[key]
	if not s then
		s = { n = 0, total = 0, max = 0, depth = 0, start = 0, mem = 0, kb = 0, gcs = 0 }
		stats[key] = s
	end
	return s
end

-- The two inline hooks. The depth counter makes a re-entrant site accrue once,
-- from the outermost pair.
--
-- A site's KB is the heap's growth across it in gcinfo's whole-KB steps. One
-- call that allocates 100 bytes reads 0 or 1, but over many calls the steps
-- crossed add up to the true total. A heap that shrank by a collection's worth
-- means one ran inside the site; that call's allocation is lost and the
-- collection counted.
function WA.ProfBegin(key)
	if not active then return end
	local s = stat(key)
	local mem = gcinfo()
	if s.depth == 0 then
		s.start = clock()
		s.mem = mem
	end
	if open == 0 then openMem = mem end
	s.depth = s.depth + 1
	open = open + 1
end

function WA.ProfEnd(key)
	if not active then return end
	local s = stats[key]
	if not s or s.depth == 0 then return end
	local mem = gcinfo()
	s.depth = s.depth - 1
	if s.depth == 0 then
		local elapsed = clock() - s.start
		s.n = s.n + 1
		s.total = s.total + elapsed
		if elapsed > s.max then s.max = elapsed end
		if mem >= s.mem then
			s.kb = s.kb + (mem - s.mem)
		elseif s.mem - mem >= GC_MIN_DROP_KB then
			s.gcs = s.gcs + 1
		end
	end
	open = open - 1
	if open == 0 and mem >= openMem then siteKB = siteKB + (mem - openMem) end
end

-- Prefix-cached keys so the wrappers do not themselves allocate a string per
-- call -- that garbage would show up in the very churn number being measured.
local eventKeys, displayKeys, callKeys = {}, {}, {}
local function cachedKey(cache, prefix, name)
	local key = cache[name]
	if not key then
		key = prefix .. tostring(name)
		cache[name] = key
	end
	return key
end

-- Once a frame while running. Churn is the heap's upward movement. A heap a
-- collection's worth lower than last frame's means one ran in between, and the
-- clock difference is that whole frame -- pause included, wherever in the frame
-- it landed.
local function sample()
	local now, mem = clock(), gcinfo()
	local frameMs = lastTick and now - lastTick or 0
	lastTick = now
	if lastMem then
		if mem >= lastMem then churnKB = churnKB + (mem - lastMem) end
		if lastMem - mem >= GC_MIN_DROP_KB then
			gcCount = gcCount + 1
			if frameMs > gcWorstMs then
				gcWorstMs, gcPeakKB, gcAfterKB = frameMs, lastMem, mem
			end
		elseif frameMs > worstFrameMs then
			worstFrameMs = frameMs
		end
	end
	lastMem = mem
	-- Every Begin/End pair runs inside one call, so nothing is open between
	-- frames unless a site raised before its ProfEnd. Left open, that site
	-- would never record again and siteKB would stop at the leak.
	if open ~= 0 then
		open = 0
		for _, s in pairs(stats) do s.depth = 0 end
	end
end
P.Sample = sample -- the harness has no frame loop to drive the sampler

local sampler = CreateFrame("Frame")
sampler:Hide()
sampler:SetScript("OnUpdate", sample)

-- Dispatch wrappers, installed at Start and removed at Stop. Keys nest: an
-- event's time includes the displays it re-combined and the user code it ran.
local origScanEvents, origUpdatedTriggerState, origSafecall
local origScanForLoads, origPollUnitTokens

local function install()
	origScanEvents = WA.ScanEvents
	WA.ScanEvents = function(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		local key = cachedKey(eventKeys, "event: ", event)
		WA.ProfBegin(key)
		origScanEvents(event, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		WA.ProfEnd(key)
	end
	origUpdatedTriggerState = WA.UpdatedTriggerState
	WA.UpdatedTriggerState = function(id)
		local key = cachedKey(displayKeys, "display: ", id)
		WA.ProfBegin(key)
		origUpdatedTriggerState(id)
		WA.ProfEnd(key)
	end
	origSafecall = WA.safecall
	WA.safecall = function(errTag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
		local key = cachedKey(callKeys, "call: ", errTag)
		WA.ProfBegin(key)
		local ok, res = origSafecall(errTag, fn, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
		WA.ProfEnd(key)
		return ok, res
	end
	origScanForLoads = WA.ScanForLoads
	WA.ScanForLoads = function()
		WA.ProfBegin("load scan")
		origScanForLoads()
		WA.ProfEnd("load scan")
	end
	origPollUnitTokens = WA.PollUnitTokens
	WA.PollUnitTokens = function()
		WA.ProfBegin("unit poll")
		origPollUnitTokens()
		WA.ProfEnd("unit poll")
	end
end

local function uninstall()
	if origScanEvents then WA.ScanEvents = origScanEvents; origScanEvents = nil end
	if origUpdatedTriggerState then
		WA.UpdatedTriggerState = origUpdatedTriggerState
		origUpdatedTriggerState = nil
	end
	if origSafecall then WA.safecall = origSafecall; origSafecall = nil end
	if origScanForLoads then WA.ScanForLoads = origScanForLoads; origScanForLoads = nil end
	if origPollUnitTokens then WA.PollUnitTokens = origPollUnitTokens; origPollUnitTokens = nil end
end

function P.Start()
	if active then out("[prof] already running") return end
	active = true
	startedAt = GetTime()
	lastMem, lastTick, open = nil, nil, 0
	for _, s in pairs(stats) do s.depth = 0 end
	sampler:Show()
	install()
	out("[prof] started (clock: " .. (hiRes and "debugprofilestop" or "GetTime, frame resolution") .. ")")
end

function P.Stop()
	if not active then out("[prof] not running") return end
	active = false
	uninstall()
	sampler:Hide()
	runSeconds = runSeconds + (GetTime() - startedAt)
	startedAt = nil
	out("[prof] stopped; /wa prof report to see results, /wa prof reset to clear")
end

function P.Reset()
	stats = {}
	churnKB, siteKB, lastMem, lastTick, open = 0, 0, nil, nil, 0
	gcCount, gcWorstMs, gcPeakKB, gcAfterKB, worstFrameMs = 0, 0, 0, 0, 0
	runSeconds = 0
	if active then startedAt = GetTime() end
	out("[prof] counters reset")
end

-- Read-only view of the session totals, for the harness.
function P.Totals()
	return churnKB, siteKB, gcCount, gcWorstMs, gcPeakKB, gcAfterKB, worstFrameMs
end

function P.SiteKB(key)
	local s = stats[key]
	return s and s.kb, s and s.gcs
end

-- `args` is "[n] [kb]": how many rows, and whether to rank them by allocation
-- instead of time.
function P.Report(args)
	args = tostring(args or "")
	local limit = tonumber(string.match(args, "%d+")) or 20
	local byKB = string.find(args, "kb", 1, true) ~= nil
	local elapsed = runSeconds
	if active and startedAt then elapsed = elapsed + (GetTime() - startedAt) end
	if elapsed <= 0 then
		out("[prof] nothing recorded; /wa prof start, play a while, then /wa prof report")
		return
	end
	local minutes = elapsed / 60

	local rows = {}
	for key, s in pairs(stats) do
		if s.n > 0 then table.insert(rows, { key = key, s = s }) end
	end
	if byKB then
		table.sort(rows, function(a, b) return a.s.kb > b.s.kb end)
	else
		table.sort(rows, function(a, b) return a.s.total > b.s.total end)
	end

	out(string.format("[prof] %s%.0fs profiled, clock %s",
		active and "running, " or "", elapsed,
		hiRes and "debugprofilestop" or "GetTime (frame resolution)"))
	out(string.format("[prof] client churn %.0f KB (%.0f KB/min), of which inside WeakestAuras sites %.0f KB (%.0f%%)",
		churnKB, churnKB / minutes, siteKB, churnKB > 0 and 100 * siteKB / churnKB or 0))
	local heapKB, thresholdKB = gcinfo()
	local nextGC = ""
	if thresholdKB and churnKB > 0 then
		nextGC = string.format(", next collection in ~%.1f min at this churn",
			(thresholdKB - heapKB) / (churnKB / minutes))
	end
	out(string.format("[prof] heap %.0f KB, collects at %s KB%s",
		heapKB, thresholdKB and string.format("%.0f", thresholdKB) or "?", nextGC))
	if gcCount > 0 then
		out(string.format("[prof] %d collection%s seen: worst frame with one %.0f ms (heap %.0f KB before it, %.0f KB live after); worst frame without %.0f ms",
			gcCount, gcCount == 1 and "" or "s", gcWorstMs, gcPeakKB, gcAfterKB, worstFrameMs))
	else
		out(string.format("[prof] no collection seen; worst frame %.0f ms", worstFrameMs))
	end
	out("[prof] keys nest: an event's time and KB include the displays and code it drove")
	out("[prof]   total ms |  ms/min |  calls |  max ms |     KB | site")
	local n = #rows
	if n > limit then n = limit end
	for i = 1, n do
		local s = rows[i].s
		out(string.format("[prof] %10.1f | %7.1f | %6d | %7.2f | %6d | %s%s",
			s.total, s.total / minutes, s.n, s.max, s.kb, rows[i].key,
			s.gcs > 0 and (" (collection inside x" .. s.gcs .. ")") or ""))
	end
	if #rows > n then
		out("[prof] ... " .. (#rows - n) .. " more; /wa prof report " .. #rows .. (byKB and " kb" or ""))
	end
end

function P.Command(rest)
	local _, _, sub, arg = string.find(rest or "", "^(%S*)%s*(.-)$")
	sub = string.lower(sub or "")
	if sub == "start" or sub == "on" then
		P.Start()
	elseif sub == "stop" or sub == "off" then
		P.Stop()
	elseif sub == "reset" then
		P.Reset()
	elseif sub == "report" or sub == "" then
		P.Report(arg)
	else
		out("[prof] usage: /wa prof start | stop | report [n] [kb] | reset")
	end
end

-- Read-only accessor for the harness.
function P.IsActive()
	return active
end
