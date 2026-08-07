-- WeakestAuras -- the addon-channel transport behind sharing a display through
-- chat: a paced send queue, chunked transfers, and the guards that keep a
-- stranger's traffic from costing anything. Mirrors WA2's Transmission.lua (§13)
-- minus its Lua-source payloads, which this format cannot carry.
--
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md

if WeakestAuras.disabled then return end

local WA = WeakestAuras

WA.Comm = {}
local C = WA.Comm

local PREFIX = "WKA"

-- Leads every message so the format can change without a new client's traffic
-- being misread by an old one -- a mismatch is dropped, not guessed at. The
-- request carries the asker's version too, which is the hook a future revision
-- would use to answer an older peer in the dialect it speaks.
local WIRE_VERSION = "1"

-- A 250-byte message plus "WKA\t" is 254 of the client's nominal 255, and 250
-- was confirmed to arrive byte-intact.
local MAX_MSG = 250

-- This client has no WHISPER addon channel -- it refuses the call outright,
-- through ChatThrottleLib and through the unhooked original both -- so every
-- message rides a shared channel and carries its intended recipient. Everyone
-- else on the channel drops it on the name test below.
-- The ceiling on a claimed transfer size and on what we will put through a
-- shared channel for one share. Buffers grow with chunks that actually arrive
-- and never preallocate `total` slots, so this bounds patience rather than
-- memory: a bogus `total` costs whatever the sender really sends, capped again
-- by the buffer TTL.
local MAX_CHUNKS = 999
local BUFFER_TTL = 30
local MAX_SENDERS = 5
local LINK_WINDOW = 300
local REQUEST_TIMEOUT = 15
-- Only used when ChatThrottleLib is absent. Derived from the numbers that
-- library has been tuned to for years rather than guessed: it holds vanilla
-- realms to 800 bytes/sec sustained and bills each message its length plus ~40
-- bytes of overhead, so a full-size message costs ~300 and 800/300 is under
-- three a second.
local SEND_INTERVAL = 0.4

-- Auras offered to chat, id -> GetTime(). A request is answered only for one
-- linked inside LINK_WINDOW, or anyone could pull any display off us by
-- guessing its name.
C.linked = {}

-- Requests we made, sender -> { name, at }. Data arriving from anyone absent
-- here is discarded before it reaches a buffer: "never push" binds our sender,
-- not a hostile one, and without this anyone could open an import dialog on our
-- screen and make us spend memory buffering it.
local outbound = {}

local inbox = {}
local queue = {}
local ticker, sweeper
local nextSid = 0

local function me()
	return UnitName("player")
end

local function log(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WeakestAuras|r " .. msg, 1, 1, 1)
end

-- The narrowest channel that reaches a name. A transfer is everyone's traffic
-- here, and a five-aura group is ~25 chunks; putting that through a whole guild
-- to serve one requester standing next to us is what this avoids.
local function channelFor(name)
	local n = GetNumRaidMembers and GetNumRaidMembers() or 0
	for i = 1, n do
		if UnitName("raid" .. i) == name then return "RAID" end
	end
	n = GetNumPartyMembers and GetNumPartyMembers() or 0
	for i = 1, n do
		if UnitName("party" .. i) == name then return "PARTY" end
	end
	if IsInGuild and IsInGuild() then return "GUILD" end
	return nil
end

-- ChatThrottleLib v13/v14 replaces the global with a three-parameter hook that
-- drops SendAddonMessage's target. Harmless while nothing whispers, but the
-- saved original is the honest function to hold, and several addons vendor a
-- copy so the global cannot be trusted to be the client's.
local function rawSend(prefix, msg, channel, target)
	local fn = SendAddonMessage
	if ChatThrottleLib and type(ChatThrottleLib.ORIG_SendAddonMessage) == "function" then
		fn = ChatThrottleLib.ORIG_SendAddonMessage
	end
	return fn(prefix, msg, channel, target)
end

local function drain()
	local item = table.remove(queue, 1)
	if not item then
		if ticker and ticker.Cancel then ticker:Cancel() end
		ticker = nil
		return
	end
	WA.safecall("Comm.send", rawSend, PREFIX, item.msg, item.channel)
end

-- ChatThrottleLib models the realm's rate limiter far better than any fixed
-- interval, and decisively it is the only thing that can account for *other*
-- addons' traffic -- a private ticker cannot see a raid-frame sync eating the
-- same budget. Its burst allowance also means a small share leaves at once
-- instead of being paced out for no reason. Ours is bulk traffic and says so;
-- one queue name keeps a transfer's chunks in order. Its v15 rewrite ignores
-- priority and queue name, which costs nothing here.
local function throttleLib()
	if ChatThrottleLib and type(ChatThrottleLib.SendAddonMessage) == "function" then
		return ChatThrottleLib
	end
end

local function enqueue(msg, channel)
	local lib = throttleLib()
	if lib then
		lib:SendAddonMessage("BULK", PREFIX, msg, channel, nil, PREFIX)
		return
	end
	table.insert(queue, { msg = msg, channel = channel })
	if not ticker then
		-- Started when the queue fills and cancelled when it drains, rather than
		-- one permanent ticker spinning against an empty table.
		ticker = C_Timer.NewTicker(SEND_INTERVAL, function() WA.safecall("Comm.drain", drain) end)
	end
end

local function send(op, to, sid, seq, total, payload, channel)
	channel = channel or channelFor(to)
	if not channel then return false end
	enqueue(WIRE_VERSION .. ":" .. op .. ":" .. to .. ":" .. sid .. ":"
		.. seq .. ":" .. total .. ":" .. payload, channel)
	return true
end

local function sweep()
	local now = GetTime()
	local live = false
	for name, buf in pairs(inbox) do
		if (now - buf.last) > BUFFER_TTL then inbox[name] = nil else live = true end
	end
	for name, req in pairs(outbound) do
		if (now - req.at) > REQUEST_TIMEOUT then
			outbound[name] = nil
			log("No answer from " .. name .. " -- they may not have WeakestAuras.")
		else
			live = true
		end
	end
	if not live and sweeper and sweeper.Cancel then
		sweeper:Cancel()
		sweeper = nil
	end
end

-- Armed only while a request or a transfer is outstanding, so an idle session
-- carries no ticker at all.
local function armSweep()
	if sweeper then return end
	sweeper = C_Timer.NewTicker(5, function() WA.safecall("Comm.sweep", sweep) end)
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

-- Marks an aura as offered. Stage-2/3 link insertion calls this; forgetting the
-- stamp yields a link everyone can see and nobody can use.
function C.MarkLinked(id)
	C.linked[id] = GetTime()
end

function C.Request(from, name)
	if not WA.hasImportExport then
		log("Import/export is unavailable on this client.")
		return false
	end
	local channel = channelFor(from)
	if not channel then
		log("You share no party, raid or guild channel with " .. from .. ", so the request cannot reach them.")
		return false
	end
	outbound[from] = { name = name, at = GetTime() }
	armSweep()
	send("r", from, 0, 1, 1, name, channel)
	log("Requesting \"" .. name .. "\" from " .. from .. "...")
	return true
end

local function answer(to, name)
	local linkedAt = C.linked[name]
	if not linkedAt or (GetTime() - linkedAt) > LINK_WINDOW then
		send("e", to, 0, 1, 1, "no")
		return
	end
	local blob = WA.ExportRaw(name)
	if not blob then
		send("e", to, 0, 1, 1, "dne")
		return
	end

	nextSid = math.mod(nextSid + 1, 100)
	local sid = nextSid

	-- Sliced against each message's own header rather than a fixed chunk size:
	-- the recipient name is part of the header and varies by up to 11 bytes.
	-- seq and total are reserved at their widest so a slice sized for chunk 1
	-- still fits at chunk 100.
	local header = string.len(WIRE_VERSION .. ":d:" .. to .. ":" .. sid .. ":999:999:")
	local room = MAX_MSG - header
	local len = string.len(blob)
	local total = math.ceil(len / room)
	if total > MAX_CHUNKS then
		send("e", to, 0, 1, 1, "big")
		return
	end
	for i = 1, total do
		send("d", to, sid, i, total, string.sub(blob, (i - 1) * room + 1, i * room))
	end
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

local function evictOldest()
	local oldestName, oldestAt
	for name, buf in pairs(inbox) do
		if not oldestAt or buf.last < oldestAt then oldestName, oldestAt = name, buf.last end
	end
	if oldestName then inbox[oldestName] = nil end
end

local function complete(from, name, blob)
	if C.OnPayload then
		C.OnPayload(from, name, blob)
		return
	end
	log(from .. " sent you \"" .. name .. "\". Import it from the options window.")
	C.lastReceived = { from = from, name = name, blob = blob }
end

local function onData(from, sid, seq, total, payload)
	local req = outbound[from]
	if not req then return end
	if total < 1 or total > MAX_CHUNKS or seq < 1 or seq > total then return end

	local buf = inbox[from]
	-- A differing sid replaces the buffer outright, so two overlapping transfers
	-- from one sender can never interleave into one string.
	if not buf or buf.sid ~= sid then
		local count = 0
		for _ in pairs(inbox) do count = count + 1 end
		if count >= MAX_SENDERS and not buf then evictOldest() end
		-- The progress clock starts at the transfer, not at the first report, so
		-- a transfer that finishes inside one interval stays silent instead of
		-- emitting a single "1/N" that never updates and reads as a stall.
		buf = { sid = sid, parts = {}, total = total, got = 0, toldAt = GetTime() }
		inbox[from] = buf
		armSweep()
	end
	-- Both clocks move on every chunk: a group transfer outruns REQUEST_TIMEOUT
	-- otherwise, and the sweep would drop the request out from under a transfer
	-- that is arriving perfectly well.
	buf.last = GetTime()
	req.at = buf.last

	if not buf.parts[seq] then
		buf.parts[seq] = payload
		buf.got = buf.got + 1
	end
	if buf.got < buf.total then
		-- Throttled, because a group is ~25 chunks and a line each would bury the
		-- chat window the transfer is being watched in.
		if buf.total > 1 and (buf.last - (buf.toldAt or 0)) >= 2 then
			buf.toldAt = buf.last
			log("Receiving \"" .. req.name .. "\" from " .. from
				.. "... " .. buf.got .. "/" .. buf.total)
		end
		return
	end

	local ordered = {}
	for i = 1, buf.total do
		if not buf.parts[i] then return end
		table.insert(ordered, buf.parts[i])
	end
	inbox[from] = nil
	outbound[from] = nil
	complete(from, req.name, table.concat(ordered))
end

local function onError(from, code)
	local req = outbound[from]
	if not req then return end
	outbound[from] = nil
	if code == "dne" then
		log(from .. " no longer has an aura called \"" .. req.name .. "\".")
	elseif code == "big" then
		log("\"" .. req.name .. "\" is too large to send through chat.")
	else
		log(from .. " did not share that aura.")
	end
end

-- ---------------------------------------------------------------------------
-- The version beacon. There is no HTTP on this client, so the only thing that
-- can know a newer release exists is another player running it: this is peer
-- gossip, not a version check. A beacon is addressed to nobody, which is what
-- lets a client that predates the op ignore one silently -- dispatch's recipient
-- test drops it there, while here op "v" is handled before that test.
-- ---------------------------------------------------------------------------

-- Lua's generator starts from a fixed seed, so an unseeded math.random would
-- hand every client in the guild the same "jitter" -- precisely the
-- simultaneous burst the jitter exists to prevent. Seeded from the client's own
-- uptime rather than the wall clock, since a server restart logs a guild in at
-- the same second but not at the same uptime.
math.randomseed(GetTime() * 1000)

-- Speaking is what makes this expensive if got wrong, and a guild of 200 is the
-- design case: the login broadcast is spread, and an answer is both spread and
-- rate-limited per channel.
local BEACON_LOGIN_MIN, BEACON_LOGIN_MAX = 5, 15
local ANSWER_MIN, ANSWER_MAX = 1, 10
local ANSWER_THROTTLE = 60

-- What a beacon may ride. arg3 is a stranger's distribution string, and an
-- unrecognised one would otherwise be handed straight back to SendAddonMessage.
local BEACON_CHANNELS = { GUILD = true, RAID = true, PARTY = true }

-- The highest claim heard this session, and never persisted: pfUI stores its
-- equivalent in saved variables, so one lie poisons that install until somebody
-- edits the file. Held in memory, a lie costs one chat line and is gone at
-- /reload -- and a notice that comes back every login until you actually update
-- is the behaviour we want anyway.
C.latestSeen = nil
C.latestSeenVersion = nil

local answerPending = {}
local answerLast = {}
local loginBeaconDone = false
local groupSize = 0

-- Tenths of a second: a guild logging in together spreads across a hundred
-- slots rather than the eleven whole ones math.random(5, 15) would give.
local function jitter(lo, hi)
	return math.random(lo * 10, hi * 10) / 10
end

local function groupChannel()
	if (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 then return "RAID" end
	if (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0 then return "PARTY" end
	return nil
end

local function currentGroupSize()
	local n = GetNumRaidMembers and GetNumRaidMembers() or 0
	if n > 0 then return n end
	return GetNumPartyMembers and GetNumPartyMembers() or 0
end

local function beacon(channel)
	if not WA.version or not channel then return end
	send("v", "", 0, 1, 1, WA.version, channel)
end

-- Answering only a beacon older than ours is the design. pfUI never answers, so
-- a newcomer to a settled guild learns nothing until somebody else happens to
-- log in; DoiteAuras answers every beacon it hears, which in a large guild is a
-- message per member per login. Downward-only, jittered and throttled means a
-- peer on an old build hears exactly one reply and a room where everyone is
-- current stays silent.
local function scheduleAnswer(channel)
	if not BEACON_CHANNELS[channel or ""] or answerPending[channel] then return end
	local last = answerLast[channel]
	if last and (GetTime() - last) < ANSWER_THROTTLE then return end
	-- C_Timer.After hands back no handle on this client, so the pending slot's
	-- identity is the cancel: clearing it turns the callback into a no-op. The
	-- throttle is stamped when the message actually leaves, not here, or a
	-- cancelled answer would suppress the next real one.
	local slot = {}
	answerPending[channel] = slot
	C_Timer.After(jitter(ANSWER_MIN, ANSWER_MAX), function()
		if answerPending[channel] ~= slot then return end
		answerPending[channel] = nil
		answerLast[channel] = GetTime()
		WA.safecall("Comm.beacon", beacon, channel)
	end)
end

local notified = false

-- One line, once per session. The peer who told us is never named: it is noise,
-- and attribution is what a false claim wants. Once per session rather than once
-- ever is also the behaviour we want -- the line comes back every login until
-- you actually update.
local function notify(claimed)
	if notified then return end
	-- Silences the line, deliberately not the beacon: that is ~20 bytes at login,
	-- and it is what makes the feature work for everyone else.
	if WA.Options().updateNotify == false then return end
	notified = true
	log(claimed .. " is available -- you have " .. WA.version .. ".")
	DEFAULT_CHAT_FRAME:AddMessage(
		"|cff888888https://github.com/fuffc/WeakestAuras/releases"
		.. "  (or: git pull in your AddOns folder)|r", 1, 1, 1)
end

local function onBeacon(channel, claimed)
	local mine = WA.ParseVersion(WA.version)
	local theirs = WA.ParseVersion(claimed)
	if not mine or not theirs then return end

	if theirs < mine then
		scheduleAnswer(channel)
		return
	end
	-- Someone at or above our version has spoken on this channel, so a pending
	-- answer of ours would tell the room nothing it has not just heard.
	answerPending[channel or ""] = nil
	if theirs == mine then return end

	-- A claim is unauthenticated, and more than one major ahead is refused rather
	-- than believed: telling a whole guild it is years behind is otherwise the
	-- cheapest lie available.
	if math.floor(theirs / 1000000) > math.floor(mine / 1000000) + 1 then return end
	if C.latestSeen and theirs <= C.latestSeen then return end
	C.latestSeen, C.latestSeenVersion = theirs, claimed
	notify(claimed)
end

-- PLAYER_ENTERING_WORLD fires on every loading screen, not only at login, so the
-- once-per-session broadcast is guarded by a flag rather than by the event.
local function onBeaconEvent(e)
	if not WA.version then return end
	if e == "PLAYER_ENTERING_WORLD" then
		groupSize = currentGroupSize()
		if loginBeaconDone then return end
		loginBeaconDone = true
		C_Timer.After(jitter(BEACON_LOGIN_MIN, BEACON_LOGIN_MAX), function()
			if IsInGuild and IsInGuild() then WA.safecall("Comm.beacon", beacon, "GUILD") end
			WA.safecall("Comm.beacon", beacon, groupChannel())
		end)
		return
	end
	-- Only a group that grew. Somebody leaving, or the roster merely changing,
	-- tells nobody anything they have not already heard.
	local n = currentGroupSize()
	if n > groupSize then WA.safecall("Comm.beacon", beacon, groupChannel()) end
	groupSize = n
end

local function dispatch(from, msg, channel)
	local _, _, ver, op, to, sid, seq, total, payload =
		string.find(msg, "^(%d+):(%a):([^:]*):(%d+):(%d+):(%d+):(.*)$")
	if not ver or ver ~= WIRE_VERSION then return end

	-- Before the recipient test, not after: a beacon carries an empty `to`, so
	-- that test would drop every one of them. It is also what makes the op
	-- invisible to a client that predates it -- no wire bump, no compat shim.
	if op == "v" then return onBeacon(channel, payload) end

	if to ~= me() then return end

	if op == "r" then
		answer(from, payload)
	elseif op == "d" then
		onData(from, tonumber(sid), tonumber(seq), tonumber(total), payload)
	elseif op == "e" then
		onError(from, payload)
	end
end

-- Behind /wa ver: feeds a beacon through the receive path exactly as a peer's
-- would arrive. Without it, seeing the notice at all needs a second account
-- running a build that does not exist yet.
function C.FeedBeacon(version, channel)
	dispatch("Peer", WIRE_VERSION .. ":v::0:1:1:" .. tostring(version), channel or "GUILD")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
frame:SetScript("OnEvent", function()
	if event ~= "CHAT_MSG_ADDON" then
		WA.safecall("Comm.beaconEvent", onBeaconEvent, event)
		return
	end
	if arg1 ~= PREFIX then return end
	local from = arg4
	if not from or from == me() then return end
	-- The distribution rides along because an answer has to go back to the
	-- channel the beacon came from, and RAID and PARTY are not the same one.
	WA.safecall("Comm.recv", dispatch, from, arg2 or "", arg3)
end)

-- ---------------------------------------------------------------------------
-- The chat link. Nothing but plain text ever leaves this client: the server
-- carries "[WeakestAuras: Sender - Name]" and every receiving client rewrites
-- that into a clickable link locally. Mirrors upstream, and it is what makes a
-- link work for people whose client never heard of this addon -- they simply
-- see the text.
-- ---------------------------------------------------------------------------

local LINK_TAG = "[WeakestAuras: "

local function plainLink(sender, name)
	return LINK_TAG .. sender .. " - " .. name .. "]"
end

local function stripColour(s)
	s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
	s = string.gsub(s, "|r", "")
	return s
end

local function insertToEditBox(text)
	local box = ChatFrameEditBox
	if not box then return false end
	if not box:IsVisible() then box:Show() end
	box:Insert(text)
	return true
end

-- Offers an aura and puts the text in the chat editbox. The stamp and the
-- insertion belong together: text without the stamp is a link everyone can see
-- and nobody can redeem.
function C.LinkAura(id)
	if not WeakestAurasDB.displays[id] then return false end
	if not WA.hasImportExport then
		log("Import/export is unavailable on this client, so auras cannot be shared.")
		return false
	end
	-- The incoming rewrite has to end the name at some bracket, and it takes the
	-- first one after the tag so that ordinary chat following a link survives.
	-- A name carrying its own "]" would therefore arrive truncated; refusing to
	-- make the link at all beats minting one that resolves to the wrong aura.
	if string.find(id, "]", 1, true) then
		log("\"" .. id .. "\" cannot be linked -- rename it without a \"]\" first.")
		return false
	end
	if not insertToEditBox(plainLink(me(), id)) then return false end
	C.MarkLinked(id)
	return true
end

-- Rewrites the first tag in a chat line into a clickable link. Span-based
-- rather than a gsub over a rebuilt string, so colour codes anywhere in the
-- line and ordinary text on either side of the tag both survive untouched.
local function rewrite(text)
	local s = string.find(text, LINK_TAG, 1, true)
	if not s then return text end
	local e = string.find(text, "]", s + string.len(LINK_TAG), true)
	if not e then return text end

	local inner = string.sub(text, s + string.len(LINK_TAG), e - 1)
	local _, _, sender, name = string.find(inner, "^([^%s]+) %- (.+)$")
	if not sender then return text end
	sender, name = stripColour(sender), stripColour(name)
	if sender == "" or name == "" then return text end

	-- Both fields live in the link, not only in the display text, so the click
	-- handler never has to parse colour-coded text back apart. The name goes
	-- last because it may contain a colon and the sender may not.
	local link = "|Hweakestauras:" .. sender .. ":" .. name .. "|h|cff8800ff["
		.. sender .. " - " .. name .. "]|h|r"
	return string.sub(text, 1, s - 1) .. link .. string.sub(text, e + 1)
end

-- pfUI wraps each chat frame's AddMessage individually -- six of seven differ
-- from ChatFrame1's on a live client -- so every frame is wrapped here rather
-- than one shared function. Wrap-and-forward with a sentinel of our own, which
-- composes with pfUI's identical hook in either load order.
local function hookChatFrames()
	for i = 1, (NUM_CHAT_WINDOWS or 0) do
		local cf = getglobal("ChatFrame" .. i)
		if cf and cf.AddMessage and not cf.weakestAurasAddMessage then
			local orig = cf.AddMessage
			cf.weakestAurasAddMessage = orig
			cf.AddMessage = function(self, text, r, g, b, id)
				-- AddMessage carries combat-log spam; the plain-text test gates
				-- all pattern work.
				if type(text) == "string" and string.find(text, LINK_TAG, 1, true) then
					local ok, out = WA.safecall("Comm.rewrite", rewrite, text)
					if ok and type(out) == "string" then text = out end
				end
				return orig(self, text, r, g, b, id)
			end
		end
	end
end

local function onLinkClick(link)
	if type(link) ~= "string" then return false end
	local _, _, sender, name = string.find(link, "^weakestauras:([^:]+):(.+)$")
	if not sender then return false end

	-- Shift-click passes a link along rather than redeeming it.
	if IsShiftKeyDown() then
		insertToEditBox(plainLink(sender, name))
		return true
	end
	if sender == me() then
		log("\"" .. name .. "\" is your own aura.")
		return true
	end
	C.Request(sender, name)
	return true
end

-- This client cannot hook SetItemRef securely, so the global is replaced and
-- tail-calls through for anything that is not ours -- the idiom ClassicAPI's
-- trade-link handler and pfUI's url handler both use.
local origSetItemRef = SetItemRef
function SetItemRef(link, text, button)
	local ok, handled = WA.safecall("Comm.link", onLinkClick, link)
	if ok and handled then return end
	if origSetItemRef then return origSetItemRef(link, text, button) end
end

hookChatFrames()
