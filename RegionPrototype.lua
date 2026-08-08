-- WeakestAuras -- the shared region base every region type mixes in at create
-- time. Mirrors WA2's RegionPrototype (§7).
-- Upstream section refs (§N) point at design/architecture/weakauras2-reference.md

if WeakestAuras.disabled then return end

local WA = WeakestAuras
WA.regionPrototype = {}
local proto = WA.regionPrototype

-- Parses an adjusted-min/max field: absolute ("12") or relative ("20%").
-- Returns exactly one of (absolute, relPercent) non-nil, or both nil for an
-- empty or unparseable value -- user input must never error here.
local function ParseAdjust(v)
	if not v or v == "" then return nil, nil end
	local index = string.find(v, "%% *$")
	if index then
		local percent = tonumber(string.sub(v, 1, index - 1))
		if not percent then return nil, nil end
		return nil, percent / 100
	end
	return tonumber(v), nil
end

-- A tiny subscribable object -- the per-region event bus subregions subscribe
-- to (§8). Port of the idea, not upstream's file. Notifies with up to three
-- payload args, which covers "Update"(state, states) and the parameterless
-- lifecycle events (PreShow/PreHide/FrameTick).
local function CreateSubscribers()
	local obj = { subs = {} }
	function obj:AddSubscriber(event, fn)
		self.subs[event] = self.subs[event] or {}
		table.insert(self.subs[event], fn)
	end
	function obj:Notify(event, a, b, c)
		local list = self.subs[event]
		if not list then return end
		for i = 1, table.getn(list) do list[i](a, b, c) end
	end
	-- Takes the same function object AddSubscriber was given. A region whose text
	-- a condition can replace has to be able to leave the FrameTick bus again, not
	-- only join it.
	function obj:RemoveSubscriber(event, fn)
		local list = self.subs[event]
		if not list or not fn then return end
		for i = table.getn(list), 1, -1 do
			if list[i] == fn then table.remove(list, i) end
		end
	end
	-- Dropped and rebuilt on every modifyFinish so a re-config's stale closures
	-- (pointing at replaced sub-region instances) never keep firing.
	function obj:Clear() self.subs = {} end
	return obj
end

-- One shared OnUpdate driving the FrameTick bus (§7 FrameTick): only regions
-- with a %p text subscribe, and only while shown, so a display with no per-frame
-- text costs nothing. RegionPrototype owns the set; Expand/Collapse and
-- modifyFinish move regions in/out of it.
local frameTickRegions = {}
local tickFrame = CreateFrame("Frame")
tickFrame:SetScript("OnUpdate", function()
	for region in pairs(frameTickRegions) do
		region.subRegionEvents:Notify("FrameTick")
	end
end)
function proto.RegisterForFrameTick(region) frameTickRegions[region] = true end
function proto.UnregisterForFrameTick(region) frameTickRegions[region] = nil end
function proto.CountFrameTick()
	local n = 0
	for _ in pairs(frameTickRegions) do n = n + 1 end
	return n
end

-- Mixed into a region frame by each region type's create(), after its own
-- frames are built.
function proto.create(region)
	region.xOffset, region.yOffset = 0, 0
	region.xOffsetAnim, region.yOffsetAnim = 0, 0
	region.xOffsetRelative, region.yOffsetRelative = 0, 0
	region.selfPoint = "CENTER"
	region.anchorFrame = UIParent
	region.anchorPoint = "CENTER"
	region.regionAlpha = 1
	region.animAlpha = nil
	region.toShow = false
	region.state = nil
	region.states = {}
	region.subRegionEvents = CreateSubscribers()

	-- Effective position composes config + animation + relative(condition)
	-- offsets, so those three never fight over SetPoint (§7). Anim/relative
	-- slots stay zero until animations/conditions exist, but the composition is
	-- built now to prevent that bug class later.
	function region:UpdatePosition()
		local x = (self.xOffset or 0) + (self.xOffsetAnim or 0) + (self.xOffsetRelative or 0)
		local y = (self.yOffset or 0) + (self.yOffsetAnim or 0) + (self.yOffsetRelative or 0)
		self:ClearAllPoints()
		self:SetPoint(self.selfPoint, self.anchorFrame or UIParent, self.anchorPoint, x, y)
	end

	function region:SetAnchor(selfPoint, anchorFrame, anchorPoint)
		self.selfPoint = selfPoint or "CENTER"
		self.anchorFrame = anchorFrame or UIParent
		self.anchorPoint = anchorPoint or "CENTER"
		self:UpdatePosition()
	end
	function region:SetOffset(x, y) self.xOffset, self.yOffset = x, y; self:UpdatePosition() end
	function region:SetOffsetAnim(x, y) self.xOffsetAnim, self.yOffsetAnim = x, y; self:UpdatePosition() end
	function region:SetXOffsetRelative(x) self.xOffsetRelative = x; self:UpdatePosition() end
	function region:SetYOffsetRelative(y) self.yOffsetRelative = y; self:UpdatePosition() end

	function region:SetRegionAlpha(a)
		self.regionAlpha = a
		self:SetAlpha(a * (self.animAlpha or 1))
	end
	function region:GetRegionAlpha() return self.regionAlpha or 1 end
	function region:SetAnimAlpha(a)
		self.animAlpha = a
		self:SetAlpha((self.regionAlpha or 1) * (a or 1))
	end

	-- Deliberately named the same as data.adjustedMin/Max (a string on the data
	-- table) -- upstream's convention.
	function region:SetAdjustedMin(v)
		self.adjustedMin, self.adjustedMinRelPercent = ParseAdjust(v)
		proto.UpdateProgress(self)
	end
	function region:SetAdjustedMax(v)
		self.adjustedMax, self.adjustedMaxRelPercent = ParseAdjust(v)
		proto.UpdateProgress(self)
	end

	-- -1 automatic (region.state), 0 manual (region.progressSourceManualValue/
	-- Total), N > 0 trigger N's state (region.states[N]).
	function region:SetProgressSource(v)
		self.progressSource = v
		proto.UpdateProgress(self)
	end

	-- The value range applyStatic/applyTimed last clamped to (post adjusted-
	-- min/max), not the raw state -- a threshold sub-region reads this rather
	-- than re-deriving it from data. 0/0 before the first UpdateProgress.
	function region:GetMinMaxProgress()
		return self.minProgress or 0, self.maxProgress or 0
	end

	-- toShow guards keep repeated Expand/Collapse idempotent (the state machine
	-- may re-apply a shown state many times). Actions/animations hook these
	-- later without another refactor (§7).
	function region:Expand()
		if self.toShow then return end
		self.toShow = true
		self.subRegionEvents:Notify("PreShow")
		self:Show()
		if self._hasFrameTick then proto.RegisterForFrameTick(self) end
	end
	function region:Collapse()
		if not self.toShow then return end
		self.toShow = false
		self.subRegionEvents:Notify("PreHide")
		proto.UnregisterForFrameTick(self)
		self:Hide()
	end

	-- The two custom-text update modes are different *call counts*, not
	-- "throttled or not" (WA2 Text.lua). `event` runs the function once per state
	-- update and ignores the throttle entirely -- that is what `force` means
	-- here. `update` runs it on FrameTick, and there the throttle is the
	-- difference between a feature and a frame-rate bug.
	--
	-- Every region type's own Update must call this with force before it (or its
	-- sub-regions) resolve a placeholder: StateMachine runs region:Update ahead
	-- of the sub-region bus, so a refresh at the top of Update is what makes the
	-- values every subtext then reads cost exactly one run.
	function region:RefreshCustomText(force)
		if not self.customTextFunc then return end
		if not force then
			local last = self.lastCustomTextUpdate
			if last and last + (self.customTextThrottle or 0) >= GetTime() then return end
		end
		self.customValues = WA.RunCustomTextFunc(self, self.customTextFunc)
		self.lastCustomTextUpdate = GetTime()
	end

	-- One stable function object, so modifyFinish's rebuild can put the same one
	-- back rather than accumulating closures.
	region.customTextTick = function() region:RefreshCustomText() end
end

-- ---------------------------------------------------------------------------
-- %c custom text (§9)
-- ---------------------------------------------------------------------------

-- The function belongs to the *aura*, not to whatever renders it: upstream
-- compiles data.customText once and every text of the display indexes the same
-- result array, so five subtexts sharing %c1..%c5 cost one run per state update
-- rather than five. It lives on the region for that reason -- an icon has no
-- text of its own, every icon text being a sub-region, so machinery kept on the
-- text region left %c unavailable everywhere it is most wanted.

-- The default function, seeded into a fresh field and restored by the editor's
-- Reset -- an emptied box is otherwise unrecoverable without remembering the
-- signature. Arguments are WA.RunCustomTextFunc's, and every return is a %c:
-- the first is %c or %c1, the second %c2, and so on.
local CUSTOM_TEXT_DEFAULT = [[function(expirationTime, duration, progress, dur, name, icon, stacks)
	return ""
end]]

-- Upstream defaults the throttle to 0, which in `update` mode is the custom
-- function running on every frame. A default that costs frame rate is not a
-- default. Resolved here rather than seeded into each region type's `defaults`,
-- so the number is written once -- `or` catches only nil, so a user who
-- deliberately chooses 0 still gets 0.
local CUSTOM_TEXT_THROTTLE = 0.2

-- Every string this aura might render: the region's own displayText, each
-- subtext's text_text, and anything a condition swaps into either. The compile
-- and the options gate both ask this, so the two cannot disagree -- an aura
-- whose only %c arrives through a condition would otherwise compile a function
-- it offers no editor to write (WA2's hideCustomTextOption walks conditions for
-- the same reason).
function proto.TextStrings(data)
	local texts = {}
	if data.displayText then table.insert(texts, data.displayText) end
	local subs = data.subRegions or {}
	for i = 1, table.getn(subs) do
		local sub = subs[i]
		if sub.type == "subtext" and sub.text_text then table.insert(texts, sub.text_text) end
	end
	local conditions = data.conditions or {}
	for i = 1, table.getn(conditions) do
		local changes = conditions[i].changes or {}
		for c = 1, table.getn(changes) do
			local change = changes[c]
			-- "displayText" on the region itself, "sub.<n>.text_text" on a subtext.
			if type(change.value) == "string" and change.property
				and (change.property == "displayText"
					or string.find(change.property, "%.text_text$")) then
				table.insert(texts, change.value)
			end
		end
	end
	return texts
end

function proto.WantsCustomText(data)
	return WA.ContainsCustomPlaceHolder(proto.TextStrings(data))
end

-- Compiles data.customText onto the region, memoized on the source it came
-- from. modify is not the cold path it looks like: a `range` field's `set` calls
-- WA.Add, NewSlider's onChange fires on every step of a drag, and modify runs
-- each time -- so dragging a slider on an aura using %c would otherwise be one
-- loadstring per frame. The key has to be the source rather than a dirty flag: a
-- `set` writing the same text back (which a drag does to every *other* field)
-- must compare equal. Memoizing the whole attempt, failure included, is also
-- what keeps a broken function from reporting once per frame of that drag.
local function applyCustomText(region, data)
	region.customValues = nil
	region.lastCustomTextUpdate = nil
	region.customTextMode = data.customTextUpdate or "event"
	region.customTextThrottle = data.customTextUpdateThrottle or CUSTOM_TEXT_THROTTLE

	local source = data.customText
	if source == "" then source = nil end
	if not source or not proto.WantsCustomText(data) then
		region.customTextFunc, region.customTextSource = nil, nil
	elseif region.customTextSource ~= source then
		region.customTextSource = source
		region.customTextFunc = WA.LoadFunction(source, tostring(data.id) .. ": custom text")
		-- The source changed, so whatever the old code left in aura_env belongs to
		-- code that no longer exists.
		WA.ClearAuraEnv(data.id)
	end
end

-- The Custom Text block -- the code editor, the update mode, and the throttle
-- that only decides anything in per-frame mode. One block per *aura* rather than
-- one per text, since that is what the function is: rendered once on the Display
-- tab (OptionsFrame's appendDisplayEffectsOptions) rather than inside each
-- subtext's own section, which would put N identical editors on one page --
-- upstream shows one subtext at a time and can afford to repeat them.
-- Empty until something in the aura's text actually references %c, which is also
-- how the connection between %c and this block is taught.
function proto.CustomTextOptionFields(data)
	if not proto.WantsCustomText(data) then return {} end
	local fields = {
		{ type = "header", name = "Custom Text" },
		{
			type = "code", name = "Custom Text Function", key = "customText", height = 160,
			-- Raw, not `or ""`: nil is what tells the renderer this has never been
			-- configured and should open at the default below.
			get = function() return data.customText end,
			set = function(v) data.customText = v; WA.Add(data, true) end,
			default = CUSTOM_TEXT_DEFAULT,
			-- Asked of the compiler for its wrapper rather than spelling one here:
			-- two spellings drift, and the symptom is an error line number silently
			-- off by one.
			validate = function(txt)
				return WA.Widgets.LuaSyntaxError(WA.WrapFunctionSource(txt), "custom text")
			end,
		},
		{
			type = "select", name = "Update on", key = "customTextUpdate",
			values = { "event", "update" },
			labels = { event = "Every state change", update = "Every frame" },
			get = function() return data.customTextUpdate or "event" end,
			set = function(v)
				data.customTextUpdate = v
				WA.Add(data, true)
				-- Repaints the tab: the throttle below decides nothing outside the
				-- per-frame mode.
				WA.RefreshOptions()
			end,
		},
	}
	if data.customTextUpdate == "update" then
		table.insert(fields, {
			type = "range", name = "Throttle (seconds)", key = "customTextUpdateThrottle",
			min = 0, max = 2, step = 0.05,
			get = function() return data.customTextUpdateThrottle or CUSTOM_TEXT_THROTTLE end,
			set = function(v) data.customTextUpdateThrottle = v; WA.Add(data, true) end,
		})
	end
	return fields
end

-- Rebuilds a region's sub-region instances from data.subRegions and re-wires
-- their event subscriptions (§8). Called at the end of each region type's
-- modify, so config edits, a new state, and a regionType switch all funnel
-- through one place. No pooling yet (acquire = create, release = hide), but
-- instances are reused in place by index+type across edits so a slider drag
-- doesn't leak a FontString per tick. Pooling proper is deferred with clones.
function proto.modifyFinish(region, data)
	region.subRegionEvents:Clear()
	applyCustomText(region, data)
	-- Ahead of every sub-region's own subscription, because subscribers fire in
	-- the order they were added: a subtext resolving %c on a frame tick has to
	-- read a value refreshed on *this* frame rather than the previous one.
	if region.customTextFunc and region.customTextMode == "update" then
		region.subRegionEvents:AddSubscriber("FrameTick", region.customTextTick)
	end
	region.subRegions = region.subRegions or {}
	local list = data.subRegions or {}
	local n = table.getn(list)
	for i = 1, n do
		local subData = list[i]
		local spec = WA.subRegionTypes[subData.type]
		-- A subregion whose type doesn't support this display's region type
		-- (e.g. a glow left on a display switched icon->bar) is hidden rather
		-- than built, so the instance survives a switch back without erroring.
		if spec and (not spec.supports or spec.supports(data.regionType)) then
			local inst = region.subRegions[i]
			if not inst or inst.subType ~= subData.type then
				if inst and inst.Hide then inst:Hide() end
				inst = spec.create(region)
				inst.subType = subData.type
				region.subRegions[i] = inst
			end
			if inst.Show then inst:Show() end
			spec.modify(region, inst, data, subData)
		else
			local inst = region.subRegions[i]
			if inst and inst.Hide then inst:Hide() end
		end
	end
	-- Hide instances left over from a shorter config (kept for later reuse).
	for i = n + 1, table.getn(region.subRegions) do
		local inst = region.subRegions[i]
		if inst and inst.Hide then inst:Hide() end
	end

	proto.RefreshFrameTick(region)
end

-- Re-derives whether anything on this region wants a per-frame repaint and moves
-- it in or out of the shared tick set. Separate from modifyFinish because a
-- condition can swap a region's whole text after the fact: a string that gains a
-- %p has to start ticking without a re-modify, and one that loses it has to stop.
function proto.RefreshFrameTick(region)
	local ft = region.subRegionEvents.subs["FrameTick"]
	region._hasFrameTick = (ft and table.getn(ft) > 0) or false
	if region:IsShown() then
		if region._hasFrameTick then proto.RegisterForFrameTick(region)
		else proto.UnregisterForFrameTick(region) end
	end
end

-- The adjusted-min/max arithmetic (region:SetAdjustedMin/Max, both a raw
-- number or nil plus a relative-percent fallback), shared by every progress
-- source below -- automatic, manual and per-trigger all clamp the same way.
local function applyStatic(region, value, total)
	value = value or 0
	total = total or 0
	local adjustMin
	if region.adjustedMin then adjustMin = region.adjustedMin
	elseif region.adjustedMinRelPercent then adjustMin = region.adjustedMinRelPercent * total
	else adjustMin = 0 end
	local max
	if region.adjustedMax then max = region.adjustedMax
	elseif region.adjustedMaxRelPercent then max = region.adjustedMaxRelPercent * total
	else max = total end
	region.minProgress, region.maxProgress = adjustMin, max
	region.value = value - adjustMin
	region.total = max - adjustMin
	if region.UpdateValue then region:UpdateValue() end
end

local function applyTimed(region, duration, expirationTime)
	duration = duration or 0
	expirationTime = expirationTime or 0
	local adjustMin
	if region.adjustedMin then adjustMin = region.adjustedMin
	elseif region.adjustedMinRelPercent then adjustMin = region.adjustedMinRelPercent * duration
	else adjustMin = 0 end
	local max
	if duration == 0 then max = 0
	elseif region.adjustedMax then max = region.adjustedMax
	elseif region.adjustedMaxRelPercent then max = region.adjustedMaxRelPercent * duration
	else max = duration end
	region.minProgress, region.maxProgress = adjustMin, max
	region.duration = max - adjustMin
	region.expirationTime = expirationTime - adjustMin
	if region.UpdateTime then region:UpdateTime() end
end

-- Shared progress resolver (§7 UpdateProgressFrom). region.progressSource
-- picks which table drives the fill: -1 automatic (region.state, the active
-- trigger), 0 manual (region.progressSourceManualValue/Total), N > 0 trigger
-- N's state (region.states[N], filled by every apply regardless of which
-- trigger is active -- StateMachine.lua's ApplyStatesToRegions).
function proto.UpdateProgress(region)
	local source = region.progressSource or -1
	if source == 0 then
		local value = region.progressSourceManualValue
		if type(value) ~= "number" then value = 0 end
		local total = region.progressSourceManualTotal
		if type(total) ~= "number" then total = 100 end
		applyStatic(region, value, total)
		return
	end
	local state
	if source > 0 then state = region.states and region.states[source]
	else state = region.state end
	-- A region's *visibility* is driven by the active trigger, not by its
	-- progress source -- when the chosen trigger has no state, the display
	-- isn't shown at all, so there's nothing to clear here. Inventing a
	-- cleared/zeroed fill for a hidden region would be dead work at best and
	-- a flash of "0%" at worst if it's ever shown before this trigger fires.
	if not state then return end
	if state.progressType == "timed" then
		applyTimed(region, state.duration, state.expirationTime)
	else
		applyStatic(region, state.value, state.total)
	end
end

-- Native cooldown swipe (the radial spiral). The one place the client-specific
-- construction and the scale compensation live, so region types just call these
-- three. On this client the swipe is a 3D Model inheriting CooldownFrameTemplate
-- -- CreateFrame("Cooldown", ...) throws "Unknown frame type" here (Debug.lua's
-- /wa cdtest), the vanilla technique CooldownTracker also uses. pcall-guarded: a
-- client missing the template gets a nil swipe and every helper below no-ops, so
-- callers never branch on availability.
--
-- It's a square 3D asset -- confirmed in-game that neither non-uniform
-- stretching (Frame:SetScale has never taken separate x/y factors on any WoW
-- client) nor a ScrollFrame-clipped oversized-and-centered version reads
-- right, so this sticks to what's actually confirmed working: always a
-- SQUARE swipe, sized to the SMALLER of width/height (never overflows) and
-- centered in the region. For a non-square icon this leaves a gap on the
-- longer axis rather than covering it -- an accepted tradeoff, not solved.
function proto.CreateSwipe(parent)
	local ok, swipe = pcall(CreateFrame, "Model", nil, parent, "CooldownFrameTemplate")
	if not ok or not swipe then return nil end
	swipe:Hide()
	return swipe
end

-- The Model is authored for a 36-unit frame (confirmed against pfUI's own
-- working Model+CooldownFrameTemplate swipe, modules/cooldown.lua's
-- SetCooldown -- size/32 left a visible sliver of the icon at the edges), so
-- it underfills and sits bottom-left unless its frame is scaled size/36. The
-- two-corner anchor is the centered-square placement (dw/dh account for a
-- non-square parent) plus the empirical alignment nudge (this Model's
-- rendered content sits very slightly left/down of its scaled frame bounds)
-- both expressed at once. Tunable live via Debug.lua's /wa swipenudge (no
-- /reload needed -- plain table fields, re-read by SizeSwipe on every call).
-- swipeNudgeK is a proportional coefficient (nudge = swipeNudgeK * size);
-- swipeYFlat is a flat additional vertical offset that empirically does NOT
-- scale with size the same way. Values below tuned in-game across
-- 16/32/64/128px via /wa swipetest -- clean at 32-128px; 16px still shows a
-- hairline gap and wasn't worth chasing further (tabled, not fixed -- revisit
-- with /wa swipetest 16 if a future icon skin actually ships that small).
proto.swipeNudgeK = 0.0625
proto.swipeYFlat = -0.25

function proto.SizeSwipe(swipe, width, height)
	if not swipe then return end
	width = width or 32
	height = height or width
	local size = math.min(width, height)
	swipe:SetScale(size / 36)
	swipe:ClearAllPoints()
	local dw, dh = (width - size) / 2, (height - size) / 2
	local nudge = proto.swipeNudgeK * size
	local testY = proto.swipeYFlat
	swipe:SetPoint("TOPLEFT", swipe:GetParent(), "TOPLEFT", dw, -dh + nudge + testY)
	swipe:SetPoint("BOTTOMRIGHT", swipe:GetParent(), "BOTTOMRIGHT", -dw + nudge, dh + testY)
end

-- Arm the swipe from a timed state, or clear+hide it when duration <= 0.
-- CooldownFrame_SetTimer wants the *start* time, so back it out of expiration.
function proto.ArmSwipe(swipe, expirationTime, duration)
	if not swipe then return end
	if duration and duration > 0 then
		swipe:Show()
		CooldownFrame_SetTimer(swipe, (expirationTime or 0) - duration, duration, 1)
	else
		CooldownFrame_SetTimer(swipe, 0, 0, 0)
		swipe:Hide()
	end
end

-- Frame levels inside a region, relative to the region's own. A child frame's
-- draw layers all sit above its parent's, so anything a region type builds as a
-- child (a progress bar, the icon's cooldown swipe) would otherwise cover text
-- or a border created on the region. Region types keep their internals below
-- SUB_LEVEL; subregions sit at or above it, ordered among themselves.
proto.SUB_LEVEL = 5

-- Area-anchors a subregion frame over the whole parent region (border/glow
-- cover the region rather than self-anchoring to one point the way subtext
-- does, §8 anchor_area). inset grows(+)/shrinks(-) the covered rect.
function proto.AnchorArea(region, parent, inset)
	inset = inset or 0
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", parent, "TOPLEFT", -inset, inset)
	region:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", inset, -inset)
end

-- Injects the universal conditionable properties into a region type's registry
-- (§7 AddProperties). Lives beside the setters it names so the two stay honest.
function proto.AddProperties(properties)
	properties.alpha = { display = "Alpha", setter = "SetRegionAlpha", type = "number", min = 0, max = 1, step = 0.05 }
	-- These are *relative* deltas only conditions set (no data.<key> backing
	-- them), so their restored base is an explicit 0, not data[key] (§7).
	properties.xOffsetRelative = { display = "X Offset", setter = "SetXOffsetRelative", type = "number", min = -200, max = 200, step = 1, base = 0 }
	properties.yOffsetRelative = { display = "Y Offset", setter = "SetYOffsetRelative", type = "number", min = -200, max = 200, step = 1, base = 0 }
	return properties
end

-- Separate from AddProperties: only the two progress region types (icon,
-- progressbar) have adjusted min/max to condition on, so this isn't folded
-- into the universal set a future non-progress region type would also inherit.
function proto.AddProgressProperties(properties)
	properties.adjustedMin = { display = "Minimum Progress", setter = "SetAdjustedMin", type = "string" }
	properties.adjustedMax = { display = "Maximum Progress", setter = "SetAdjustedMax", type = "string" }
	return properties
end

-- The nine anchor tokens every region's self/anchor point picks from.
proto.anchorPoints = { "CENTER", "TOP", "BOTTOM", "LEFT", "RIGHT",
	"TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }

-- Upstream's frame_strata_types (WA2 Types.lua): 1-based, where 1 is
-- "Inherited" rather than a real strata. Shared by the Frame strata select
-- (labels) and ApplyFrameStrata (lookup) so the two can't disagree.
local FRAME_STRATA_NAMES = {
	[1] = "Inherited",
	[2] = "BACKGROUND",
	[3] = "LOW",
	[4] = "MEDIUM",
	[5] = "HIGH",
	[6] = "DIALOG",
	[7] = "FULLSCREEN",
	[8] = "FULLSCREEN_DIALOG",
	[9] = "TOOLTIP",
}
local FRAME_STRATA_VALUES = { 1, 2, 3, 4, 5, 6, 7, 8, 9 }

local function FrameStrataField(data)
	return {
		type = "select", name = "Frame strata", key = "frameStrata",
		values = FRAME_STRATA_VALUES,
		labels = FRAME_STRATA_NAMES,
		get = function() return data.frameStrata or 1 end,
		set = function(v) data.frameStrata = v; WA.Add(data, true) end,
	}
end

-- Applies a region's saved strata (1 = inherit from parent, 2..9 = a real
-- FRAME_STRATA_NAMES entry). Call after ApplyPosition, whose SetParent can
-- itself reset the frame's strata.
function proto.ApplyFrameStrata(region, data)
	local strata = data.frameStrata
	if not strata or strata == 1 then
		local parent = region:GetParent() or UIParent
		region:SetFrameStrata(parent:GetFrameStrata())
	else
		region:SetFrameStrata(FRAME_STRATA_NAMES[strata])
	end
end

-- Resolves a display's anchor frame and applies its saved anchor tuple. The one
-- place anchor-frame selection lives.
--   * Grouped child (data.parent is a group): SetParent + anchor to the group
--     frame's CENTER, so the group's scale cascades and moving/dragging the
--     group carries its children. xOffset/yOffset are CENTER-relative and
--     data.anchorPoint is ignored -- the group case is always center-relative
--     (WA2's Group.lua getRect reads xOffset/yOffset as such).
--   * Top-level (SCREEN): anchor selfPoint to UIParent at data.anchorPoint.
-- Ensuring the group frame here (WA.GetRegion) means a child applied before its
-- group still resolves -- the group is created on demand.
function proto.ApplyPosition(region, data)
	local parentId = data.parent
	local pdata = parentId and WeakestAurasDB.displays[parentId]
	if pdata and WA.IsGroup(pdata) then
		local groupFrame = WA.GetRegion(parentId, "")
		if groupFrame then
			region:SetParent(groupFrame)
			if pdata.regionType == "dynamicgroup" then
				-- The grower (Regions.lua layoutDynamicGroup) owns the real
				-- offset; anchor to CENTER as a baseline until it runs.
				region:SetAnchor("CENTER", groupFrame, "CENTER")
				region:SetOffset(0, 0)
			else
				region:SetAnchor(data.selfPoint or "CENTER", groupFrame, "CENTER")
				region:SetOffset(data.xOffset or 0, data.yOffset or 0)
			end
			return
		end
	end
	region:SetParent(UIParent)
	region:SetAnchor(data.selfPoint or "CENTER", UIParent, data.anchorPoint or "CENTER")
	region:SetOffset(data.xOffset or 0, data.yOffset or 0)
end

-- The Display-tab Position section, shared by every non-group region type so a
-- new region kind gets drag-compatible positioning for free. Appended to a
-- type's options() field array (Regions.lua). Position edits are pure-visual,
-- so they ride the WA.Add(data, true) fast-path like the size sliders.
function proto.PositionOptions(data)
	-- A dynamicgroup arranges its children automatically, so manual position is
	-- meaningless for them -- show a note instead of dead sliders.
	-- A dynamic group's child still has its own strata even though the group
	-- owns its position (matches upstream: frameStrata carries no
	-- IsParentDynamicGroup hidden check in CommonOptions.lua).
	local pdata = data.parent and WeakestAurasDB.displays[data.parent]
	if pdata and pdata.regionType == "dynamicgroup" then
		return {
			{ type = "header", name = "Position (set by dynamic group)" },
			FrameStrataField(data),
		}
	end
	return {
		{ type = "header", name = "Position" },
		{
			type = "select", name = "Anchor", key = "selfPoint", half = true,
			values = proto.anchorPoints,
			get = function() return data.selfPoint end,
			set = function(v) data.selfPoint = v; WA.Add(data, true) end,
		},
		{
			type = "select", name = "To screen point", key = "anchorPoint", half = true,
			values = proto.anchorPoints,
			get = function() return data.anchorPoint end,
			set = function(v) data.anchorPoint = v; WA.Add(data, true) end,
		},
		{
			type = "range", name = "X", key = "xOffset", min = -400, max = 400, step = 1, half = true,
			get = function() return data.xOffset end,
			set = function(v) data.xOffset = v; WA.Add(data, true) end,
		},
		{
			type = "range", name = "Y", key = "yOffset", min = -400, max = 400, step = 1, half = true,
			get = function() return data.yOffset end,
			set = function(v) data.yOffset = v; WA.Add(data, true) end,
		},
		FrameStrataField(data),
	}
end

-- Re-applies a region's progress source and adjusted min/max from data at
-- modify time. Passing "" for a disabled bound (rather than its last-set
-- string) keeps a toggled-off bound from leaking a stale clamp. The manual
-- value/total are plain fields, not setters -- nothing conditions on them
-- individually, so there's no repaint to drive.
function proto.ApplyProgressConfig(region, data)
	region.progressSourceManualValue = data.progressSourceManualValue
	region.progressSourceManualTotal = data.progressSourceManualTotal
	region:SetProgressSource(data.progressSource or -1)
	region:SetAdjustedMin(data.useAdjustededMin and data.adjustedMin or "")
	region:SetAdjustedMax(data.useAdjustededMax and data.adjustedMax or "")
end

-- The Progress Settings section, shared by icon and progressbar (both drive
-- their fill/swipe through proto.UpdateProgress). Appended to a type's
-- options() field array (Regions.lua). Pure-visual, so it rides the
-- WA.Add(data, true) fast-path like Position/Size.
function proto.ProgressOptions(data)
	local sourceValues = { -1 }
	local sourceLabels = { [-1] = "Automatic (active trigger)" }
	local triggerCount = data.triggers and table.getn(data.triggers) or 0
	for i = 1, triggerCount do
		table.insert(sourceValues, i)
		sourceLabels[i] = "Trigger " .. i
	end
	table.insert(sourceValues, 0)
	sourceLabels[0] = "Manual"

	local fields = {
		{ type = "header", name = "Progress" },
		{
			type = "select", name = "Progress source", key = "progressSource",
			values = sourceValues,
			labels = sourceLabels,
			get = function() return data.progressSource or -1 end,
			set = function(v)
				data.progressSource = v
				WA.Add(data, true)
				-- The manual value/total fields appear and disappear with this pick.
				WA.RefreshOptions()
			end,
		},
	}
	if data.progressSource == 0 then
		table.insert(fields, {
			type = "input", name = "Value", key = "progressSourceManualValue",
			get = function() return data.progressSourceManualValue end,
			set = function(v)
				data.progressSourceManualValue = tonumber(v) or data.progressSourceManualValue
				WA.Add(data, true)
			end,
		})
		table.insert(fields, {
			type = "input", name = "Total", key = "progressSourceManualTotal",
			get = function() return data.progressSourceManualTotal end,
			set = function(v)
				data.progressSourceManualTotal = tonumber(v) or data.progressSourceManualTotal
				WA.Add(data, true)
			end,
		})
	end
	table.insert(fields, {
		type = "toggle", name = "Set minimum progress", key = "useAdjustededMin",
		get = function() return data.useAdjustededMin end,
		set = function(v)
			data.useAdjustededMin = v
			if not v then data.adjustedMin = "" end
			WA.Add(data, true)
			WA.RefreshOptions()
		end,
	})
	if data.useAdjustededMin then
		table.insert(fields, {
			type = "input", name = "Minimum", key = "adjustedMin",
			get = function() return data.adjustedMin end,
			set = function(v) data.adjustedMin = v; WA.Add(data, true) end,
		})
	end
	table.insert(fields, {
		type = "toggle", name = "Set maximum progress", key = "useAdjustededMax",
		get = function() return data.useAdjustededMax end,
		set = function(v)
			data.useAdjustededMax = v
			if not v then data.adjustedMax = "" end
			WA.Add(data, true)
			WA.RefreshOptions()
		end,
	})
	if data.useAdjustededMax then
		table.insert(fields, {
			type = "input", name = "Maximum", key = "adjustedMax",
			get = function() return data.adjustedMax end,
			set = function(v) data.adjustedMax = v; WA.Add(data, true) end,
		})
	end
	return fields
end
