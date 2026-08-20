-- WeakestAuras -- action dispatch and compiled custom action functions.
-- Upstream section refs (§7, §13, §16) point at design/architecture/weakauras2-reference.md

if WeakestAuras.disabled then return end

local WA = WeakestAuras

WA.customActionsFunctions = {}

WA.send_chat_message_types = {
	WHISPER = "Whisper", SAY = "Say", EMOTE = "Emote", YELL = "Yell",
	PARTY = "Party", GUILD = "Guild", OFFICER = "Officer", RAID = "Raid",
	SMARTRAID = "BG > Raid > Party > Say", RAID_WARNING = "Raid Warning",
	COMBAT = "Blizzard Combat Text", PRINT = "Chat Frame", ERROR = "Error Frame",
	TTS = "Text-to-speech",
}

WA.sound_types = {
	[" custom"] = "Custom Sound File",
	[" KitID"] = "Sound by Kit Name",
	["Sound\\interface\\RaidWarning.wav"] = "Raid Warning",
	["Sound\\interface\\levelup2.wav"] = "Ready Check",
	["Sound\\interface\\iQuestComplete.wav"] = "Quest Complete",
	["Sound\\interface\\iTellMessage.wav"] = "Whisper",
	["Sound\\Spells\\LevelUp.wav"] = "Level Up",
	["Sound\\Spells\\ReputationLevelUp.wav"] = "Reputation Up",
	["Sound\\Spells\\PVPThroughQueue.wav"] = "Battleground Queue",
	["Sound\\Spells\\ShaysBell.wav"] = "Shay's Bell",
	["Sound\\Doodad\\BellTollNightElf.wav"] = "Bell Toll (Night Elf)",
	["Sound\\Doodad\\BellTollAlliance.wav"] = "Bell Toll (Alliance)",
	["Sound\\Doodad\\BellTollHorde.wav"] = "Bell Toll (Horde)",
	["Sound\\Doodad\\BellTollTribal.wav"] = "Bell Toll (Tribal)",
	["Sound\\Doodad\\DwarfHorn.wav"] = "Dwarf Horn",
	["Sound\\Doodad\\G_GongTroll01.wav"] = "Troll Gong",
	["Sound\\Doodad\\LightHouseFogHorn.wav"] = "Fog Horn",
	["Sound\\Doodad\\HornGoober.wav"] = "Horn",
	["Sound\\interface\\AuctionWindowOpen.wav"] = "Auction Window",
	["Sound\\Interface\\igQuestFailed.wav"] = "Quest Failed",
}

-- The bundled set, under sounds\ and sounds\powerauras\. Paths and labels are
-- upstream's LibSharedMedia registrations (WA2 Types.lua) carried over verbatim,
-- because WA2Import matches an incoming path against these to land it on our
-- copy -- a renamed file or a renamed label would break that lookup silently.
-- Upstream's "Cartoon Hop" is not here: it registers a name whose file WA2 does
-- not actually ship, which is exactly the dead reference this table avoids.
local BUNDLED_SOUNDS = {
	["Interface\\AddOns\\WeakestAuras\\sounds\\AcousticGuitar.ogg"] = "Acoustic Guitar",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\aggro.ogg"] = "Aggro",
	["Interface\\AddOns\\WeakestAuras\\sounds\\AirHorn.ogg"] = "Air Horn",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Applause.ogg"] = "Applause",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\Arrow_Swoosh.ogg"] = "Arrow Swoosh",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\bam.ogg"] = "Bam",
	["Interface\\AddOns\\WeakestAuras\\sounds\\BananaPeelSlip.ogg"] = "Banana Peel Slip",
	["Interface\\AddOns\\WeakestAuras\\sounds\\BatmanPunch.ogg"] = "Batman Punch",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\bigkiss.ogg"] = "Big Kiss",
	["Interface\\AddOns\\WeakestAuras\\sounds\\BikeHorn.ogg"] = "Bike Horn",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\BITE.ogg"] = "Bite",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Blast.ogg"] = "Blast",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Bleat.ogg"] = "Bleat",
	["Interface\\AddOns\\WeakestAuras\\sounds\\BoxingArenaSound.ogg"] = "Boxing Arena Gong",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Brass.mp3"] = "Brass",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\burp4.ogg"] = "Burp",
	["Interface\\AddOns\\WeakestAuras\\sounds\\CartoonVoiceBaritone.ogg"] = "Cartoon Voice Baritone",
	["Interface\\AddOns\\WeakestAuras\\sounds\\CartoonWalking.ogg"] = "Cartoon Walking",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\cat2.ogg"] = "Cat",
	["Interface\\AddOns\\WeakestAuras\\sounds\\CatMeow2.ogg"] = "Cat Meow",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\chant2.ogg"] = "Chant Major 2nd",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\chant4.ogg"] = "Chant Minor 3rd",
	["Interface\\AddOns\\WeakestAuras\\sounds\\ChickenAlarm.ogg"] = "Chicken Alarm",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\chimes.ogg"] = "Chimes",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\cookie.ogg"] = "Cookie Monster",
	["Interface\\AddOns\\WeakestAuras\\sounds\\CowMooing.ogg"] = "Cow Mooing",
	["Interface\\AddOns\\WeakestAuras\\sounds\\DoubleWhoosh.ogg"] = "Double Whoosh",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Drums.ogg"] = "Drums",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\ESPARK1.ogg"] = "Electrical Spark",
	["Interface\\AddOns\\WeakestAuras\\sounds\\ErrorBeep.ogg"] = "Error Beep",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\Fireball.ogg"] = "Fireball",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\Gasp.ogg"] = "Gasp",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Glass.mp3"] = "Glass",
	["Interface\\AddOns\\WeakestAuras\\sounds\\GoatBleating.ogg"] = "Goat Bleeting",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\shot.ogg"] = "Gunshot",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\heartbeat.ogg"] = "Heartbeat",
	["Interface\\AddOns\\WeakestAuras\\sounds\\HeartbeatSingle.ogg"] = "Heartbeat Single",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\hic3.ogg"] = "Hiccup",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\huh_1.ogg"] = "Huh?",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\hurricane.ogg"] = "Hurricane",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\hyena.ogg"] = "Hyena",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\kaching.ogg"] = "Kaching",
	["Interface\\AddOns\\WeakestAuras\\sounds\\KittenMeow.ogg"] = "Kitten Meow",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\moan.ogg"] = "Moan",
	["Interface\\AddOns\\WeakestAuras\\sounds\\OhNo.ogg"] = "Oh No",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\panther1.ogg"] = "Panther",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\phone.ogg"] = "Phone",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\bear_polar.ogg"] = "Polar Bear",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\PUNCH.ogg"] = "Punch",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\rainroof.ogg"] = "Rain",
	["Interface\\AddOns\\WeakestAuras\\sounds\\RingingPhone.ogg"] = "Ringing Phone",
	["Interface\\AddOns\\WeakestAuras\\sounds\\RoaringLion.ogg"] = "Roaring Lion",
	["Interface\\AddOns\\WeakestAuras\\sounds\\RobotBlip.ogg"] = "Robot Blip",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\rocket.ogg"] = "Rocket",
	["Interface\\AddOns\\WeakestAuras\\sounds\\RoosterChickenCalls.ogg"] = "Rooster Chicken Call",
	["Interface\\AddOns\\WeakestAuras\\sounds\\SharpPunch.ogg"] = "Sharp Punch",
	["Interface\\AddOns\\WeakestAuras\\sounds\\SheepBleat.ogg"] = "Sheep Blerping",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\shipswhistle.ogg"] = "Ship's Whistle",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Shotgun.ogg"] = "Shotgun",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\snakeatt.ogg"] = "Snake Attack",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\sneeze.ogg"] = "Sneeze",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\sonar.ogg"] = "Sonar",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\splash.ogg"] = "Splash",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\Squeakypig.ogg"] = "Squeaky Toy",
	["Interface\\AddOns\\WeakestAuras\\sounds\\SqueakyToyShort.ogg"] = "Squeaky Toy Short",
	["Interface\\AddOns\\WeakestAuras\\sounds\\SquishFart.ogg"] = "Squish Fart",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\swordecho.ogg"] = "Sword Ring",
	["Interface\\AddOns\\WeakestAuras\\sounds\\SynthChord.ogg"] = "Synth Chord",
	["Interface\\AddOns\\WeakestAuras\\sounds\\TadaFanfare.ogg"] = "Tada Fanfare",
	["Interface\\AddOns\\WeakestAuras\\sounds\\TempleBellHuge.ogg"] = "Temple Bell",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\throwknife.ogg"] = "Throwing Knife",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\thunder.ogg"] = "Thunder",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Torch.ogg"] = "Torch",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Adds.ogg"] = "Voice: Adds",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Boss.ogg"] = "Voice: Boss",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Circle.ogg"] = "Voice: Circle",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Cross.ogg"] = "Voice: Cross",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Diamond.ogg"] = "Voice: Diamond",
	["Interface\\AddOns\\WeakestAuras\\sounds\\DontRelease.ogg"] = "Voice: Don't Release",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Empowered.ogg"] = "Voice: Empowered",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Focus.ogg"] = "Voice: Focus",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Idiot.ogg"] = "Voice: Idiot",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Left.ogg"] = "Voice: Left",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Moon.ogg"] = "Voice: Moon",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Next.ogg"] = "Voice: Next",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Portal.ogg"] = "Voice: Portal",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Protected.ogg"] = "Voice: Protected",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Release.ogg"] = "Voice: Release",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Right.ogg"] = "Voice: Right",
	["Interface\\AddOns\\WeakestAuras\\sounds\\RunAway.ogg"] = "Voice: Run Away",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Skull.ogg"] = "Voice: Skull",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Spread.ogg"] = "Voice: Spread",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Square.ogg"] = "Voice: Square",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Stack.ogg"] = "Voice: Stack",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Star.ogg"] = "Voice: Star",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Switch.ogg"] = "Voice: Switch",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Taunt.ogg"] = "Voice: Taunt",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Triangle.ogg"] = "Voice: Triangle",
	["Interface\\AddOns\\WeakestAuras\\sounds\\WarningSiren.ogg"] = "Warning Siren",
	["Interface\\AddOns\\WeakestAuras\\sounds\\WaterDrop.ogg"] = "Water Drop",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\wlaugh.ogg"] = "Wicked Female Laugh",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\wickedmalelaugh1.ogg"] = "Wicked Male Laugh",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\wilhelm.ogg"] = "Wilhelm Scream",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\wolf5.ogg"] = "Wolf Howl",
	["Interface\\AddOns\\WeakestAuras\\sounds\\Xylophone.ogg"] = "Xylophone",
	["Interface\\AddOns\\WeakestAuras\\sounds\\powerauras\\yeehaw.ogg"] = "Yeehaw",
}
WA.bundled_sound_types = BUNDLED_SOUNDS
for path, label in pairs(BUNDLED_SOUNDS) do WA.sound_types[path] = label end

local MESSAGE_TYPES = { "WHISPER", "SAY", "EMOTE", "YELL", "PARTY", "GUILD", "OFFICER", "RAID", "SMARTRAID", "RAID_WARNING", "COMBAT", "PRINT", "ERROR", "TTS" }
local MESSAGE_LABELS = WA.send_chat_message_types

local ACTION_SPECS = {
	{ key = "init", block = "init", field = "custom", enabled = "do_custom", body = true },
	{ key = "load", block = "init", field = "customOnLoad", enabled = "do_custom_load", body = true },
	{ key = "unload", block = "init", field = "customOnUnload", enabled = "do_custom_unload", body = true },
	{ key = "start", block = "start", field = "custom", enabled = "do_custom", body = true },
	{ key = "finish", block = "finish", field = "custom", enabled = "do_custom", body = true },
	{ key = "start_message", block = "start", field = "message_custom", enabled = "do_message" },
	{ key = "finish_message", block = "finish", field = "message_custom", enabled = "do_message" },
}

local function sourceFor(data, spec)
	local actions = data.actions and data.actions[spec.block]
	if not actions or not actions[spec.enabled] then return nil end
	local source = actions[spec.field]
	if type(source) ~= "string" or source == "" then return nil end
	return source
end

local function hasSound(options)
	if options.sound == " custom" then return options.sound_path and options.sound_path ~= "" end
	if options.sound == " KitID" then return options.sound_kit_id and options.sound_kit_id ~= "" end
	return options.sound and options.sound ~= ""
end

local function playSound(options)
	if not hasSound(options) or type(PlaySoundFile) ~= "function" then return end
	local path = options.sound
	if path == " custom" then path = options.sound_path end
	if path == " KitID" then
		if PlaySound then pcall(PlaySound, options.sound_kit_id) end
	else
		pcall(PlaySoundFile, path)
	end
end

function WA.SoundRepeatStop(region)
	if region.soundRepeatTicker and region.soundRepeatTicker.Cancel then
		region.soundRepeatTicker:Cancel()
	end
	region.soundRepeatTicker = nil
end

function WA.SoundPlay(region, options)
	if not options or WA.optionsOpen or WA.forced[region.id] or WA.SquelchingActions() then return end
	WA.SoundRepeatStop(region)
	playSound(options)
	local loop = options.do_loop or options.sound_type == "Loop"
	if loop and tonumber(options.sound_repeat) and options.sound_repeat > 0
		and C_Timer and C_Timer.NewTicker then
		region.soundRepeatTicker = C_Timer.NewTicker(options.sound_repeat, function()
			if not region.toShow then WA.SoundRepeatStop(region); return end
			playSound(options)
		end)
	end
end

local lastSoundPreviewTime
function WA.PreviewSound(value, isKit)
	if lastSoundPreviewTime == GetTime() then return end
	lastSoundPreviewTime = GetTime()
	if isKit then
		if PlaySound then pcall(PlaySound, value) end
	elseif value and value ~= "" then
		if PlaySoundFile then pcall(PlaySoundFile, value) end
	end
end

function WA.SendChat(region, options)
	if not options or WA.optionsOpen or WA.SquelchingActions() then return end
	WA.HandleChatAction(options.message_type, options.message, options.message_dest,
		options.message_dest_isunit, options.r, options.g, options.b, region, nil, nil, nil)
end

local function startGlowOn(region, frame, options)
	region.activeExternalGlows = region.activeExternalGlows or {}
	local glow = region.activeExternalGlows[frame]
	if not glow then
		glow = WA.CreateExternalGlow and WA.CreateExternalGlow(frame)
		region.activeExternalGlows[frame] = glow
	end
	if glow and glow.StartGlow then glow:StartGlow(options) end
end

local function stopGlowOn(region, frame)
	if not frame or not region.activeExternalGlows then return end
	local glow = region.activeExternalGlows[frame]
	if glow and glow.StopGlow then glow:StopGlow() end
	region.activeExternalGlows[frame] = nil
end

-- A glow the user aimed at a unit rather than at a named frame (§16). Both
-- targets are recycled -- a nameplate to whatever creature the engine next
-- needs one for, a unit frame to whatever the token points at -- so a lit glow
-- has to follow its unit or go out. Left alone it becomes a glow on a stranger,
-- which is worse than no feature. Keyed by region because one region glows one
-- unit at a time; the entry outlives a missing frame so the glow returns with
-- the plate.
local unitGlowMonitor = {}
local unitGlowWatching

local function glowUnitFrame(frameType, unit)
	if not unit then return nil end
	if frameType == "NAMEPLATE" then
		return WA.GetUnitNameplate and WA.GetUnitNameplate(unit) or nil
	end
	return WA.GetUnitFrame and WA.GetUnitFrame(unit) or nil
end

-- Re-resolves every monitored glow, on every wake the unit watcher has: the
-- token moved, a plate was recycled, or a frame that was missing turned up.
local function refreshUnitGlows()
	for region, entry in pairs(unitGlowMonitor) do
		local frame = glowUnitFrame(entry.frameType, region.state and region.state.unit)
		if frame ~= entry.frame then
			stopGlowOn(region, entry.frame)
			entry.frame = frame
			if frame then startGlowOn(region, frame, entry.options) end
		end
	end
end

local function ensureUnitGlowWatch()
	if unitGlowWatching or not WA.RegisterUnitWatchCallback then return end
	unitGlowWatching = true
	WA.RegisterUnitWatchCallback(refreshUnitGlows)
end

-- A named glow target, which is either a global frame or another display -- the
-- same two spellings the SELECTFRAME anchor takes, because upstream's frame
-- selector writes one field for both and an imported glow can carry either.
local function namedGlowFrame(name)
	if type(name) ~= "string" or name == "" then return nil end
	local _, _, id = string.find(name, "^" .. WA.ANCHOR_AURA_PREFIX .. "(.+)$")
	if id then return WA.PeekRegion(id, "") end
	return getglobal(name)
end

function WA.GlowExternal(region, options)
	if not region or not options or not options.glow_frame_type then return end
	local frameType = options.glow_frame_type
	local unitAimed = frameType == "UNITFRAME" or frameType == "NAMEPLATE"
	local frame = region
	if frameType == "FRAMESELECTOR" and options.glow_frame then
		frame = namedGlowFrame(options.glow_frame)
	elseif unitAimed then
		frame = glowUnitFrame(frameType, region.state and region.state.unit)
	end
	if options.glow_action == "hide" then
		local entry = unitAimed and unitGlowMonitor[region]
		if entry then
			-- The lit frame, not the one the token resolves to now: the unit may
			-- have moved since, and the glow is on the frame it was started on.
			frame = entry.frame
			unitGlowMonitor[region] = nil
		end
		stopGlowOn(region, frame)
		return
	end
	if unitAimed then
		unitGlowMonitor[region] = { frameType = frameType, options = options, frame = frame }
		ensureUnitGlowWatch()
	end
	if not frame then return end
	startGlowOn(region, frame, options)
end

function WA.StopExternalGlows(region)
	unitGlowMonitor[region] = nil
	for frame, glow in pairs(region.activeExternalGlows or {}) do
		if glow.StopGlow then glow:StopGlow() end
		region.activeExternalGlows[frame] = nil
	end
end

function WA.CompileActions(data)
	if not data or WA.IsGroup(data) then return end
	local id = data.id
	local cache = WA.customActionsFunctions[id] or {}
	local sources = cache.sources or {}
	cache.sources = sources
	WA.customActionsFunctions[id] = cache
	for i = 1, table.getn(ACTION_SPECS) do
		local spec = ACTION_SPECS[i]
		local source = sourceFor(data, spec)
		if sources[spec.key] ~= source then
			sources[spec.key] = source
			cache[spec.key] = nil
			WA.ClearAuraEnv(data.id)
			if source then
				cache[spec.key] = WA.LoadFunction(source, id .. ": " .. spec.key, spec.body and true or false)
			end
		end
	end
end

function WA.ClearActionFunctions(id)
	WA.customActionsFunctions[id] = nil
end

function WA.RenameActionFunctions(oldId, newId)
	WA.customActionsFunctions[newId] = WA.customActionsFunctions[oldId]
	WA.customActionsFunctions[oldId] = nil
end

function WA.RunActionCode(data, key, region)
	local cache = WA.customActionsFunctions[data.id]
	local fn = cache and cache[key]
	if not fn then return end
	if region then
		return WA.RunAuraFunc(region, data.id .. ": " .. key, fn)
	end
	return WA.RunAuraFunc(data.id, data.id .. ": " .. key, fn)
end

-- Whether this aura will make a noise, and how: four keyed warnings recomputed
-- from `data` on every WA.Add, since that is when any of the four fields can have
-- changed. Neither severity is a fault -- they exist so a user hunting a stray
-- sound can find which aura is making it, and they pair with the login squelch
-- (WA.SquelchingActions): the strip says which aura, the squelch buys time to fix
-- it. Both fold under a `warning` or an `error`, which is what their rank means.
--
-- A condition change is matched on its property *name*, as upstream does, not on
-- the resolved type: `sound` and `chat` are injected once per region type by
-- proto.AddProperties and are never sub-region properties, so nothing prefixes
-- them.
function WA.UpdateSoundWarnings(data)
	if not data or not data.uid or not WA.UpdateWarning then return end
	local uid = data.uid
	local actions = data.actions or {}
	local start, finish = actions.start or {}, actions.finish or {}

	local soundCondition, ttsCondition
	local conditions = data.conditions or {}
	for i = 1, table.getn(conditions) do
		local changes = conditions[i].changes or {}
		for c = 1, table.getn(changes) do
			local change = changes[c]
			if change.property == "sound" then
				soundCondition = true
			elseif change.property == "chat" and type(change.value) == "table"
				and change.value.message_type == "TTS" then
				ttsCondition = true
			end
		end
	end

	WA.UpdateWarning(uid, "sound_action",
		(start.do_sound or finish.do_sound) and "sound" or nil,
		"This aura plays a sound via an action.")
	WA.UpdateWarning(uid, "sound_condition", soundCondition and "sound" or nil,
		"This aura plays a sound via a condition.")
	WA.UpdateWarning(uid, "tts_action",
		((start.do_message and start.message_type == "TTS")
			or (finish.do_message and finish.message_type == "TTS")) and "tts" or nil,
		"This aura speaks via an action.")
	WA.UpdateWarning(uid, "tts_condition", ttsCondition and "tts" or nil,
		"This aura speaks via a condition.")
end

function WA.SquelchingActions()
	local untilTime = WA.actionSquelchUntil
	return untilTime and GetTime() < untilTime or false
end

local actionEventFrame = CreateFrame("Frame")
actionEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
actionEventFrame:SetScript("OnEvent", function()
	local seconds = tonumber(WA.Options().login_squelch_time)
	if seconds == nil then seconds = 10 end
	WA.actionSquelchUntil = GetTime() + seconds
end)

local function actionFormatGet(action, key, default)
	local value = action["message_format_" .. key]
	if value == nil then return default end
	return value
end

local function actionFormatSet(data, action, key, value)
	action["message_format_" .. key] = value
	WA.Add(data)
end

local function messageCustomNeeded(action)
	return WA.ContainsCustomPlaceHolder(action.message)
		or (action.message_type == "WHISPER" and WA.ContainsCustomPlaceHolder(action.message_dest))
end

local function messageFields(fields, data, action, when, condition)
	local prefix = "actions:" .. when .. ":"
	if not condition then
		table.insert(fields, { type = "toggle", name = "Chat Message", key = "do_message",
			get = function() return action.do_message and true or false end,
			set = function(v) action.do_message = v and true or false; WA.Add(data); WA.RefreshOptions() end })
	end
	table.insert(fields, { type = "select", name = "Message Type", key = "message_type", values = MESSAGE_TYPES, labels = MESSAGE_LABELS,
		get = function() return action.message_type or "PRINT" end,
		set = function(v) action.message_type = v; WA.Add(data); WA.RefreshOptions() end })
	table.insert(fields, { type = "input", name = "Message", key = "message",
		get = function() return action.message end,
		set = function(v) action.message = v; WA.SetDefaultFormatters(v, function(k, d) return actionFormatGet(action, k, d) end,
			function(k, x) actionFormatSet(data, action, k, x) end, data); WA.Add(data); WA.RefreshOptions() end })
	if action.message_type == "WHISPER" then
		table.insert(fields, { type = "input", name = "Send To", key = "message_dest",
			get = function() return action.message_dest end,
			set = function(v) action.message_dest = v; WA.Add(data); WA.RefreshOptions() end })
		table.insert(fields, { type = "toggle", name = "Is Unit", key = "message_dest_isunit",
			get = function() return action.message_dest_isunit and true or false end,
			set = function(v) action.message_dest_isunit = v and true or false; WA.Add(data) end })
	end
	if action.message_type == "PRINT" or action.message_type == "ERROR" or action.message_type == "COMBAT" then
		-- One field writing action.r/g/b as a unit, so the key is a coined name
		-- rather than any one of the three properties.
		table.insert(fields, { type = "color", name = "Color", key = "message_color",
			get = function() return { action.r or 1, action.g or 1, action.b or 1, 1 } end,
			set = function(v) action.r, action.g, action.b = v[1], v[2], v[3]; WA.Add(data) end })
	end
	if action.do_message and messageCustomNeeded(action) then
		table.insert(fields, { type = "code", height = 80, name = "Message Custom Code", key = "message_custom",
			get = function() return action.message_custom end,
			set = function(v) action.message_custom = v; WA.Add(data) end })
	end
	if action.message and action.message ~= "" then
		local formatFields = WA.FormatOptionFields(action.message,
			function(k, d) return actionFormatGet(action, k, d) end,
			function(k, v) actionFormatSet(data, action, k, v) end, data, prefix .. "message_format_")
		for i = 1, table.getn(formatFields) do table.insert(fields, formatFields[i]) end
	end
end

function WA.ActionMessageFields(fields, data, action, when, condition)
	messageFields(fields, data, action, when, condition)
end

local function soundFields(fields, data, action, condition)
	local previews = {}
	for key in pairs(WA.sound_types) do
		if key ~= " custom" and key ~= " KitID" then previews[key] = true end
	end
	if condition then
		table.insert(fields, { type = "select", name = "Sound Type", key = "sound_type", values = { "Play", "Loop" },
			get = function() return action.sound_type or "Play" end,
			set = function(v) action.sound_type = v; WA.Add(data); WA.RefreshOptions() end })
	else
		table.insert(fields, { type = "toggle", name = "Play Sound", key = "do_sound",
			get = function() return action.do_sound and true or false end,
			set = function(v) action.do_sound = v and true or false; WA.Add(data); WA.RefreshOptions() end })
		table.insert(fields, { type = "toggle", name = "Loop", key = "do_loop",
			get = function() return action.do_loop and true or false end,
			set = function(v) action.do_loop = v and true or false; WA.Add(data); WA.RefreshOptions() end })
	end
	if (condition and action.sound_type == "Loop") or (not condition and action.do_loop) then
		table.insert(fields, { type = "range", name = "Repeat After", key = "sound_repeat", min = 0.1, max = 60, step = 0.1,
			get = function() return action.sound_repeat or 1 end,
			set = function(v) action.sound_repeat = v; WA.Add(data) end })
	end
	table.insert(fields, { type = "select", name = "Sound", key = "sound", values = WA.SoundValues, labels = WA.sound_types,
		previews = previews, onPreview = function(v) if v ~= " custom" and v ~= " KitID" then WA.PreviewSound(v) end end,
		get = function() return action.sound or "" end,
		set = function(v) action.sound = v; WA.Add(data); WA.RefreshOptions() end })
	if action.sound == " custom" then
		table.insert(fields, { type = "input", name = "Sound File Path", key = "sound_path",
			get = function() return action.sound_path end,
			set = function(v) action.sound_path = v; WA.PreviewSound(v); WA.Add(data) end })
	elseif action.sound == " KitID" then
		table.insert(fields, { type = "input", name = "Sound Kit Name", key = "sound_kit_id",
			get = function() return action.sound_kit_id end,
			set = function(v) action.sound_kit_id = v; WA.PreviewSound(v, true); WA.Add(data) end })
	end
end

-- Ordered by *label*, not by path: the list is long enough to need scrolling and
-- a path sort would group it by folder, scattering the names the reader is
-- actually scanning for. The two pseudo-entries keep their leading space and are
-- pinned to the top rather than sorted in among the real files.
WA.SoundValues = {}
for key in pairs(WA.sound_types) do table.insert(WA.SoundValues, key) end
table.sort(WA.SoundValues, function(a, b)
	local pinnedA, pinnedB = string.sub(a, 1, 1) == " ", string.sub(b, 1, 1) == " "
	if pinnedA ~= pinnedB then return pinnedA end
	return WA.sound_types[a] < WA.sound_types[b]
end)

function WA.ActionSoundFields(fields, data, action, condition)
	soundFields(fields, data, action, condition)
end

function WA.PerformActions(data, when, region)
	if not data or WA.optionsOpen or WA.forced[data.id] then return end
	local actions = data.actions and data.actions[when]
	if not actions then return end
	if not WA.SquelchingActions() and actions.do_message and actions.message_type and actions.message then
		local cache = WA.customActionsFunctions[data.id]
		local customValues
		local customFn = cache and cache[when .. "_message"]
		if customFn then
			local ok, values = WA.RunAuraFuncPacked(region, data.id .. ": " .. when .. " message", customFn)
			if ok then customValues = values end
		end
		WA.HandleChatAction(actions.message_type, actions.message, actions.message_dest,
			actions.message_dest_isunit, actions.r, actions.g, actions.b, region,
			customValues, when, region[when .. "Formatters"])
	end
	if actions.do_sound then WA.SoundPlay(region, actions) end
	if actions.do_custom and actions.custom then
		local cache = WA.customActionsFunctions[data.id]
		local fn = cache and cache[when]
		if fn then region:RunCode(fn) end
	end
	-- Deliberately outside the squelch above, as upstream's is: a glow is a state
	-- the aura leaves behind rather than a notification, so suppressing it at
	-- login would leave the display lit with nothing to put it out.
	if actions.do_glow then WA.GlowExternal(region, actions) end
	-- The escape hatch for a glow whose own "hide" never runs -- a show aimed at
	-- a frame the aura no longer resolves, most often. Finish only: on show there
	-- is nothing yet to clear.
	if when == "finish" and actions.hide_all_glows then WA.StopExternalGlows(region) end
end

local function runInitIfNeeded(id, env)
	if env._waActionInit then return end
	env._waActionInit = true
	local cache = WA.customActionsFunctions[id]
	if cache and cache.init then
		WA.RunAuraFunc(id, id .. ": init", cache.init)
	end
end

local originalActivateAuraEnv = WA.ActivateAuraEnv
function WA.ActivateAuraEnv(id, cloneId, state, states)
	local env = originalActivateAuraEnv(id, cloneId, state, states)
	if id and env then runInitIfNeeded(id, env) end
	return env
end

function WA.HandleChatAction(messageType, message, messageDest, messageDestIsUnit, r, g, b,
	region, customValues, when, formatters)
	if not message then return end
	message = WA.ReplacePlaceHolders(message, region, formatters, customValues)
	if messageType == "PRINT" then
		if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
			pcall(DEFAULT_CHAT_FRAME.AddMessage, DEFAULT_CHAT_FRAME, message, r or 1, g or 1, b or 1)
		end
	elseif messageType == "ERROR" then
		if UIErrorsFrame and UIErrorsFrame.AddMessage then
			pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, message, r or 1, g or 1, b or 1)
		end
	elseif messageType == "COMBAT" then
		if not CombatText_AddMessage and LoadAddOn then pcall(LoadAddOn, "Blizzard_CombatText") end
		if CombatText_AddMessage then
			pcall(CombatText_AddMessage, message, COMBAT_TEXT_SCROLL_FUNCTION, r or 1, g or 1, b or 1)
		end
	elseif messageType == "TTS" then
		if C_VoiceChat and C_VoiceChat.SpeakText and C_TTSSettings and C_TTSSettings.GetSpeechVoiceID then
			pcall(C_VoiceChat.SpeakText, C_TTSSettings.GetSpeechVoiceID(), message)
		end
	else
		if messageType == "WHISPER" and messageDest then
			messageDest = WA.ReplacePlaceHolders(messageDest, region, formatters, customValues)
			if messageDestIsUnit and UnitName then messageDest = UnitName(messageDest) end
			pcall(SendChatMessage, message, "WHISPER", nil, messageDest)
		elseif messageType == "SMARTRAID" then
			local channel = "SAY"
			if GetNumRaidMembers and GetNumRaidMembers() > 0 then channel = "RAID"
			elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then channel = "PARTY" end
			pcall(SendChatMessage, message, channel)
		else
			pcall(SendChatMessage, message, messageType)
		end
	end
end

local function noAction()
end

local function addRegionMethods(region)
	function region:RunCode(fn)
		if fn and not WA.optionsOpen and not WA.forced[self.id] then
			return WA.RunAuraFunc(self, self.id .. ": custom action", fn)
		end
	end
	region.SoundPlay = function(self, options) WA.SoundPlay(self, options) end
	region.SoundRepeatStop = function(self) WA.SoundRepeatStop(self) end
	region.SendChat = function(self, options) WA.SendChat(self, options) end
	region.GlowExternal = function(self, options) WA.GlowExternal(self, options) end
	region.StopExternalGlows = function(self) WA.StopExternalGlows(self) end
end

WA.AttachActionMethods = addRegionMethods

function WA.RunActionCodeForLoad(data, key)
	local cache = WA.customActionsFunctions[data.id]
	local fn = cache and cache[key]
	if fn then return WA.RunAuraFunc(data.id, data.id .. ": " .. key, fn) end
end
