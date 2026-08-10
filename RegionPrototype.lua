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

local function subRegionAnchorValue(parentData, subData, key, fallback)
	local value = subData[key]
	if value ~= nil then return value end
	return fallback
end

function proto.GetSubRegionAnchorTarget(parent, key)
	if parent.GetSubAnchorTarget then
		return parent:GetSubAnchorTarget(key)
	end
	return parent
end

function proto.GetSubRegionAnchorPoint(key, fallback)
	if not key or key == "region" or key == "bar" or key == "icon" or key == "fg" or key == "bg" or key == "SPARK" then
		return fallback or "CENTER"
	end
	local point = string.gsub(key, "^ICON_", "")
	point = string.gsub(point, "^INNER_", "")
	point = string.gsub(point, "^OUTER_", "")
	return point
end

function proto.GetSubRegionAnchors(parentData, mode)
	local spec = WA.RegionSpecFor(parentData)
	local anchors = spec and spec.getSubRegionAnchors and spec.getSubRegionAnchors(parentData) or {}
	local copy = { region = { display = "Whole region", point = true, area = true } }
	for key, anchor in pairs(anchors) do copy[key] = anchor end
	anchors = copy
	local values, labels = {}, {}
	for key, anchor in pairs(anchors) do
		if anchor[mode] then
			table.insert(values, key)
			labels[key] = anchor.display or key
		end
	end
	table.sort(values)
	return values, labels
end

function proto.AnchorSubRegion(frame, parent, subData, defaults)
	defaults = defaults or {}
	local mode = defaults.areaOnly and "area" or (subData.anchor_mode or defaults.mode or "point")
	local targetKey
	local targetPoint
	local selfPoint
	local xOffset
	local yOffset
	if mode == "area" then
		targetKey = subRegionAnchorValue(parent, subData, "anchor_area", defaults.areaTarget or "region")
		xOffset = subRegionAnchorValue(parent, subData, "anchorXOffset", subData.border_offset or defaults.x or 0)
		yOffset = subRegionAnchorValue(parent, subData, "anchorYOffset", subData.border_offset or defaults.y or 0)
	else
		targetKey = subRegionAnchorValue(parent, subData, "anchor_target", defaults.target or "region")
		if subData.anchor_point then
			targetPoint = subData.anchor_point
		elseif subData.anchor_target then
			targetPoint = proto.GetSubRegionAnchorPoint(targetKey, defaults.anchorPoint)
		else
			targetPoint = subRegionAnchorValue(parent, subData, "anchor_point", subData.text_anchorPoint or defaults.anchorPoint or "CENTER")
		end
		selfPoint = subRegionAnchorValue(parent, subData, "self_point", defaults.selfPoint or targetPoint or "CENTER")
		xOffset = subRegionAnchorValue(parent, subData, "anchorXOffset", defaults.x or 0)
		yOffset = subRegionAnchorValue(parent, subData, "anchorYOffset", defaults.y or 0)
	end

	local target = proto.GetSubRegionAnchorTarget(parent, targetKey)
	if not target then target = parent end
	frame:ClearAllPoints()
	if mode == "area" then
		frame:SetPoint("TOPLEFT", target, "TOPLEFT", -xOffset, yOffset)
		frame:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", xOffset, -yOffset)
	else
		frame:SetPoint(selfPoint or "CENTER", target, targetPoint or "CENTER", xOffset, yOffset)
	end
end

function proto.SubRegionAnchorFields(parentData, subData, defaults)
	defaults = defaults or {}
	local fields = {}
	local modeField = {
			type = "select", name = "Anchor mode", key = "anchor_mode",
			values = { "point", "area" },
			labels = { point = "Point", area = "Area" },
			get = function() return subData.anchor_mode or defaults.mode or "point" end,
			set = function(v)
				subData.anchor_mode = v
				WA.Add(parentData, true)
				WA.RefreshOptions()
			end,
	}

	local mode = defaults.areaOnly and "area" or (subData.anchor_mode or defaults.mode or "point")
	if mode == "area" then
		if not defaults.areaOnly then table.insert(fields, modeField) end
		local values, labels = proto.GetSubRegionAnchors(parentData, "area")
		table.insert(fields, {
			type = "select", name = "Area", key = "anchor_area", values = values, labels = labels,
			get = function() return subData.anchor_area or defaults.areaTarget or "region" end,
			set = function(v) subData.anchor_area = v; WA.Add(parentData, true) end,
		})
	else
		local values, labels = proto.GetSubRegionAnchors(parentData, "point")
		local targetField = {
			type = "select", name = "Target", key = "anchor_target", values = values, labels = labels,
			get = function() return subData.anchor_target or defaults.target or "region" end,
			set = function(v)
				subData.anchor_target = v
				local point = proto.GetSubRegionAnchorPoint(v)
				subData.anchor_point, subData.self_point = point, point
				WA.Add(parentData, true)
			end,
		}
		table.insert(fields, {
			type = "anchorlayout", grid = {
				type = "anchorgrid", name = "Anchor", key = "self_point",
				values = proto.anchorGridPoints, width = 100, height = 50,
				get = function() return subData.self_point or defaults.selfPoint or "CENTER" end,
				set = function(v)
					subData.anchor_point, subData.self_point = v, v
					WA.Add(parentData, true)
				end,
			},
			sideFields = { modeField, targetField },
		})
	end

	table.insert(fields, {
		type = "range", name = mode == "area" and "Extra width" or "X", key = "anchorXOffset", half = true,
		min = -200, max = 200, step = 1,
		get = function() return subData.anchorXOffset or defaults.x or 0 end,
		set = function(v) subData.anchorXOffset = v; WA.Add(parentData, true) end,
	})
	table.insert(fields, {
		type = "range", name = mode == "area" and "Extra height" or "Y", key = "anchorYOffset", half = true,
		min = -200, max = 200, step = 1, half = true,
		get = function() return subData.anchorYOffset or defaults.y or 0 end,
		set = function(v) subData.anchorYOffset = v; WA.Add(parentData, true) end,
	})
	return fields
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

-- Separate from AddProperties: only progress region types (icon, progressbar,
-- progresstexture) have adjusted min/max to condition on, so this isn't folded
-- into the universal set a future non-progress region type would also inherit.
function proto.AddProgressProperties(properties)
	properties.adjustedMin = { display = "Minimum Progress", setter = "SetAdjustedMin", type = "string" }
	properties.adjustedMax = { display = "Maximum Progress", setter = "SetAdjustedMax", type = "string" }
	return properties
end

-- The nine anchor tokens every region's self/anchor point picks from.
proto.anchorPoints = { "CENTER", "TOP", "BOTTOM", "LEFT", "RIGHT",
	"TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
proto.anchorGridPoints = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT",
	"BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }

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

local ANCHOR_FRAME_TYPES = { "SCREEN", "UIPARENT", "SELECTFRAME", "MOUSE", "NAMEPLATE", "UNITFRAME", "CUSTOM" }
local ANCHOR_FRAME_LABELS = {
	SCREEN = "Screen / group",
	UIPARENT = "UIParent",
	SELECTFRAME = "Selected frame",
	MOUSE = "Mouse",
	NAMEPLATE = "Nameplate",
	UNITFRAME = "Unit frame",
	CUSTOM = "Custom",
}
local ANCHOR_FRAME_VALUES = { "SCREEN", "UIPARENT", "SELECTFRAME", "MOUSE", "NAMEPLATE", "UNITFRAME", "CUSTOM" }

local hiddenFrames
local pendingAnchorRetries = {}
local anchorRetryScheduled
local mouseAnchorFrame
local optionsNameplateAnchorFrame
local mouseAnchorMarker
local nameplateAnchorMarker
local dynamicAnchorWatcher
local nameplateFor

local function moveMouseAnchor()
	local x, y = GetCursorPosition()
	local scale = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
	if not scale or scale == 0 then scale = 1 end
	mouseAnchorFrame:ClearAllPoints()
	mouseAnchorFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
end

local function hiddenAnchorFrame()
	if not hiddenFrames then
		hiddenFrames = CreateFrame("Frame", "WeakestAurasHiddenFrames", UIParent)
		hiddenFrames:SetWidth(1)
		hiddenFrames:SetHeight(1)
		hiddenFrames:Hide()
		WA.HiddenFrames = hiddenFrames
	end
	return hiddenFrames
end

local function createMouseAnchorFrame()
	if mouseAnchorFrame then return mouseAnchorFrame end
	mouseAnchorFrame = CreateFrame("Frame", "WeakestAurasMouseAnchor", UIParent)
	mouseAnchorFrame:SetWidth(1)
	mouseAnchorFrame:SetHeight(1)
	mouseAnchorFrame:Hide()
	mouseAnchorMarker = CreateFrame("Frame", nil, mouseAnchorFrame)
	mouseAnchorMarker:SetWidth(92)
	mouseAnchorMarker:SetHeight(28)
	mouseAnchorMarker:SetPoint("CENTER", mouseAnchorFrame, "CENTER")
	mouseAnchorMarker:SetFrameStrata("TOOLTIP")
	mouseAnchorMarker:SetBackdrop({
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 10,
		insets = { left = 0, right = 0, top = 0, bottom = 0 },
	})
	mouseAnchorMarker:SetBackdropBorderColor(1, 0.82, 0, 1)
	local label = mouseAnchorMarker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("TOP", mouseAnchorMarker, "BOTTOM", 0, -2)
	label:SetJustifyH("CENTER")
	label:SetText("Mouse Anchor")
	if label.SetTextColor then label:SetTextColor(1, 0.82, 0, 1) end
	mouseAnchorFrame.mouseAnchorLabel = label
	mouseAnchorMarker:Hide()
	mouseAnchorFrame:SetScript("OnUpdate", function()
		if WA.optionsOpen then return end
		moveMouseAnchor()
	end)
	mouseAnchorFrame:Show()
	return mouseAnchorFrame
end

local function xPositionNextToOptions()
	local panel = getglobal("WeakestAurasOptions")
	local screenWidth = GetScreenWidth and GetScreenWidth() or 1920
	if not panel or not panel.GetLeft or not panel.GetRight then return screenWidth / 2 end
	local left, right = panel:GetLeft(), panel:GetRight()
	if not left or not right then return screenWidth / 2 end
	local center = (left + right) / 2
	if center > screenWidth / 2 then
		if left > 400 then return left - 200 end
		return left / 2
	end
	if screenWidth - right > 400 then return right + 200 end
	return (screenWidth + right) / 2
end

local function positionMouseAnchor()
	if not mouseAnchorFrame or not WA.optionsOpen then return end
	local panel = getglobal("WeakestAurasOptions")
	local top = panel and panel.GetTop and panel:GetTop()
	local bottom = panel and panel.GetBottom and panel:GetBottom()
	local y = (top and bottom and (top + bottom) / 2) or (GetScreenHeight() / 2)
	local x = xPositionNextToOptions()
	mouseAnchorFrame:ClearAllPoints()
	mouseAnchorFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
end

local function createOptionsNameplateAnchorFrame()
	if optionsNameplateAnchorFrame then return optionsNameplateAnchorFrame end
	optionsNameplateAnchorFrame = CreateFrame("Frame", "WeakestAurasNameplateAnchor", UIParent)
	optionsNameplateAnchorFrame:SetWidth(200)
	optionsNameplateAnchorFrame:SetHeight(40)
	optionsNameplateAnchorFrame:SetFrameStrata("TOOLTIP")
	optionsNameplateAnchorFrame:SetBackdrop({
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 0, right = 0, top = 0, bottom = 0 },
	})
	optionsNameplateAnchorFrame:SetBackdropBorderColor(0, 1, 0, 1)
	nameplateAnchorMarker = optionsNameplateAnchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	nameplateAnchorMarker:SetPoint("CENTER", optionsNameplateAnchorFrame, "CENTER")
	nameplateAnchorMarker:SetJustifyH("CENTER")
	nameplateAnchorMarker:SetText("Nameplate Anchor")
	if nameplateAnchorMarker.SetTextColor then nameplateAnchorMarker:SetTextColor(0, 1, 0, 1) end
	optionsNameplateAnchorFrame:Hide()
	return optionsNameplateAnchorFrame
end

local function positionNameplateAnchor()
	if not optionsNameplateAnchorFrame or not WA.optionsOpen then return end
	local panel = getglobal("WeakestAurasOptions")
	local top = panel and panel.GetTop and panel:GetTop()
	local bottom = panel and panel.GetBottom and panel:GetBottom()
	local x = panel and panel.GetLeft and panel:GetLeft() or (GetScreenWidth() / 2)
	local right = panel and panel.GetRight and panel:GetRight()
	local width = optionsNameplateAnchorFrame:GetWidth() or 200
	local height = optionsNameplateAnchorFrame:GetHeight() or 40
	local y = (top and bottom and bottom - 24 - height / 2) or (GetScreenHeight() / 2)
	if right and x then x = (x + right) / 2 end
	optionsNameplateAnchorFrame:ClearAllPoints()
	optionsNameplateAnchorFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
end

local function queueAnchorRetry(data)
	if not data or not data.id then return end
	pendingAnchorRetries[data.id] = true
	if anchorRetryScheduled then return end
	anchorRetryScheduled = true
	C_Timer.After(1, function()
		anchorRetryScheduled = nil
		local retry = pendingAnchorRetries
		pendingAnchorRetries = {}
		for id in pairs(retry) do
			local d = WeakestAurasDB.displays[id]
			local region = d and WA.PeekRegion(id, "")
			if d and region then proto.ApplyPosition(region, d) end
		end
	end)
end

function WA.GetAnchorAuraID(data)
	if not data or data.anchorFrameType ~= "SELECTFRAME" then return nil end
	local ref = data.anchorFrameFrame
	if not ref or ref == "" then return nil end
	local _, _, id = string.find(ref, "^WeakestAuras:(.+)$")
	if id then return id end
	if WeakestAurasDB.displays[ref] then return ref end
	return nil
end

local function anchorReference(data)
	local id = WA.GetAnchorAuraID(data)
	if id then return WA.PeekRegion(id, "") end
	local ref = data.anchorFrameFrame
	if not ref or ref == "" then return nil end
	return getglobal(ref)
end

local function unitForRegion(region)
	local state = region and region.state
	if not state then return nil, nil end
	return state.unit or state.unitId, state.guid or state.guidUnit
end

nameplateFor = function(unit, guid)
	if not C_NamePlate then return nil end
	if unit and C_NamePlate.GetNamePlateForUnit then
		local frame = C_NamePlate.GetNamePlateForUnit(unit)
		if frame then return frame end
	end
	if C_NamePlate.GetNamePlateForGUID then
		if not guid and unit and UnitGUID then guid = UnitGUID(unit) end
		if guid then return C_NamePlate.GetNamePlateForGUID(guid) end
	end
	return nil
end

function WA.GetUnitFrame(unit)
	if not unit then return nil end
	local pf = _G and _G.pfUI
	local pfuf = pf and pf.uf
	local probes = {
		player = function() return pfuf and pfuf.player or getglobal("PlayerFrame") end,
		target = function() return pfuf and pfuf.target or getglobal("TargetFrame") end,
		targettarget = function() return pfuf and pfuf.targettarget or getglobal("TargetTargetFrame") end,
		focus = function() return pfuf and pfuf.focus or getglobal("FocusFrame") end,
		focustarget = function() return pfuf and pfuf.focustarget or getglobal("FocusTargetFrame") end,
		pet = function() return pfuf and pfuf.pet or getglobal("PetFrame") end,
		pettarget = function() return pfuf and pfuf.pettarget or getglobal("PetTargetFrame") end,
	}
	local probe = probes[unit]
	if probe then return probe() end
	local _, _, n = string.find(unit, "^party(%d+)$")
	if n then return pfuf and pfuf.group and pfuf.group[tonumber(n)]
		or getglobal("PartyMemberFrame" .. tostring(n)) end
	local _, _, raid = string.find(unit, "^raid(%d+)$")
	if raid and pfuf and pfuf.raid then return pfuf.raid[tonumber(raid)] end
	local _, _, nameplate = string.find(unit, "^nameplate(%d+)$")
	if nameplate then return nameplateFor(unit) end
	return nil
end

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
-- place anchor-frame selection lives (§16). An unresolved target parks the
-- region on a hidden singleton and schedules one shared retry.
--   * Grouped child (data.parent is a group): SetParent + anchor to the group
--     frame's CENTER, so the group's scale cascades and moving/dragging the
--     group carries its children. xOffset/yOffset are CENTER-relative and
--     data.anchorPoint is ignored -- the group case is always center-relative
--     (WA2's Group.lua getRect reads xOffset/yOffset as such).
--   * Top-level (SCREEN): anchor selfPoint to UIParent at data.anchorPoint.
-- Ensuring the group frame here (WA.GetRegion) means a child applied before its
-- group still resolves -- the group is created on demand.
function proto.ResolveAnchor(region, data)
	local frameType = data.anchorFrameType or "SCREEN"
	local parentId = data.parent
	local pdata = parentId and WeakestAurasDB.displays[parentId]
	if frameType == "SCREEN" and pdata and WA.IsGroup(pdata) then
		local groupFrame = WA.GetRegion(parentId, "")
		if groupFrame then return groupFrame, "CENTER", true end
	end
	if frameType == "SCREEN" or frameType == "UIPARENT" then
		return UIParent, data.anchorPoint or "CENTER", true
	elseif frameType == "SELECTFRAME" then
		local frame = anchorReference(data)
		if frame then return frame, data.anchorPoint or "CENTER", data.anchorFrameParent ~= false end
		queueAnchorRetry(data)
		return hiddenAnchorFrame(), data.anchorPoint or "CENTER", true
	elseif frameType == "MOUSE" then
		local frame = createMouseAnchorFrame()
		if WA.optionsOpen then
			positionMouseAnchor()
			if mouseAnchorMarker then mouseAnchorMarker:Show() end
			return frame, "CENTER", true
		end
		return frame, "CENTER", false
	elseif frameType == "NAMEPLATE" then
		if WA.optionsOpen then
			local frame = createOptionsNameplateAnchorFrame()
			positionNameplateAnchor()
			frame:Show()
			if nameplateAnchorMarker then nameplateAnchorMarker:Show() end
			return frame, data.anchorPoint or "CENTER", true
		end
		local unit, guid = unitForRegion(region)
		local frame = nameplateFor(unit, guid)
		if frame then return frame, data.anchorPoint or "CENTER", data.anchorFrameParent ~= false end
		queueAnchorRetry(data)
		return hiddenAnchorFrame(), data.anchorPoint or "CENTER", true
	elseif frameType == "UNITFRAME" then
		local unit = unitForRegion(region)
		local frame = WA.GetUnitFrame(unit)
		if frame then return frame, data.anchorPoint or "CENTER", data.anchorFrameParent ~= false end
		queueAnchorRetry(data)
		if WA.optionsOpen then return UIParent, data.anchorPoint or "CENTER", true end
		return hiddenAnchorFrame(), data.anchorPoint or "CENTER", true
	elseif frameType == "CUSTOM" and data.customAnchor then
		local fn = region.customAnchorFunc
		if not fn then
			fn = WA.LoadFunction(data.customAnchor, tostring(data.id) .. ": custom anchor")
			region.customAnchorFunc = fn
		end
		if fn then
			local ok, frame = WA.RunAuraFunc(data.id, data.id .. ": custom anchor", fn)
			if ok and frame then return frame, data.anchorPoint or "CENTER", data.anchorFrameParent ~= false end
		end
		return hiddenAnchorFrame(), data.anchorPoint or "CENTER", true
	end
	return UIParent, data.anchorPoint or "CENTER", data.anchorFrameParent ~= false
end

function proto.ReanchorDynamic(frameType)
	if not WA.ForEachRegion then return end
	WA.ForEachRegion(function(region)
		local data = WeakestAurasDB.displays[region.id]
		if data and (not frameType or data.anchorFrameType == frameType) then
			if data.anchorFrameType == "MOUSE" or data.anchorFrameType == "NAMEPLATE"
				or data.anchorFrameType == "UNITFRAME" then
				proto.ApplyPosition(region, data)
				proto.ApplyFrameStrata(region, data)
			end
		end
	end)
	proto.SyncOptionsAnchorMarkers()
end

function proto.SyncOptionsAnchorMarkers()
	if not WA.optionsOpen then
		if mouseAnchorMarker then mouseAnchorMarker:Hide() end
		if nameplateAnchorMarker then nameplateAnchorMarker:Hide() end
		if optionsNameplateAnchorFrame then optionsNameplateAnchorFrame:Hide() end
		return
	end
	local mouseVisible, nameplateVisible = false, false
	if WA.ForEachRegion then
		WA.ForEachRegion(function(region)
			local data = WeakestAurasDB.displays[region.id]
			if data and region.IsShown and region:IsShown() then
				if data.anchorFrameType == "MOUSE" then mouseVisible = true end
				if data.anchorFrameType == "NAMEPLATE" then nameplateVisible = true end
			end
		end)
	end
	if mouseAnchorMarker then
		if mouseVisible then mouseAnchorMarker:Show() else mouseAnchorMarker:Hide() end
	end
	if optionsNameplateAnchorFrame then
		if nameplateVisible then optionsNameplateAnchorFrame:Show() else optionsNameplateAnchorFrame:Hide() end
	end
	if nameplateAnchorMarker then
		if nameplateVisible then nameplateAnchorMarker:Show() else nameplateAnchorMarker:Hide() end
	end
end

function proto.SetOptionsAnchors(open)
	if open then
		createMouseAnchorFrame()
		createOptionsNameplateAnchorFrame()
		positionMouseAnchor()
		positionNameplateAnchor()
		optionsNameplateAnchorFrame:Hide()
		if mouseAnchorMarker then mouseAnchorMarker:Hide() end
		proto.ReanchorDynamic("MOUSE")
		proto.ReanchorDynamic("NAMEPLATE")
		proto.SyncOptionsAnchorMarkers()
	else
		if mouseAnchorFrame then
			mouseAnchorFrame:SetScript("OnUpdate", function()
				moveMouseAnchor()
			end)
		end
		if optionsNameplateAnchorFrame then optionsNameplateAnchorFrame:Hide() end
		if mouseAnchorMarker then mouseAnchorMarker:Hide() end
		if nameplateAnchorMarker then nameplateAnchorMarker:Hide() end
		proto.ReanchorDynamic("MOUSE")
		proto.ReanchorDynamic("NAMEPLATE")
	end
end

dynamicAnchorWatcher = CreateFrame("Frame")
dynamicAnchorWatcher:RegisterEvent("NAME_PLATE_UNIT_ADDED")
dynamicAnchorWatcher:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
dynamicAnchorWatcher:RegisterEvent("PLAYER_TARGET_CHANGED")
dynamicAnchorWatcher:RegisterEvent("PLAYER_FOCUS_CHANGED")
dynamicAnchorWatcher:RegisterEvent("PARTY_MEMBERS_CHANGED")
dynamicAnchorWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
dynamicAnchorWatcher:SetScript("OnEvent", function()
	if event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
		proto.ReanchorDynamic("NAMEPLATE")
	else
		proto.ReanchorDynamic("UNITFRAME")
	end
end)

function proto.ApplyPosition(region, data)
	local anchorFrame, anchorPoint, setParent = proto.ResolveAnchor(region, data)
	local parentId = data.parent
	local pdata = parentId and WeakestAurasDB.displays[parentId]
	if setParent then region:SetParent(anchorFrame) else region:SetParent(UIParent) end
	if pdata and WA.IsGroup(pdata) and data.anchorFrameType == "SCREEN" then
		if pdata.regionType == "dynamicgroup" then
			region:SetAnchor("CENTER", anchorFrame, "CENTER")
			region:SetOffset(0, 0)
		else
			region:SetAnchor(data.selfPoint or "CENTER", anchorFrame, anchorPoint)
			region:SetOffset(data.xOffset or 0, data.yOffset or 0)
		end
		return
	end
	if data.anchorFrameType == "MOUSE" then anchorPoint = "CENTER" end
	if pdata and WA.IsGroup(pdata) and data.anchorFrameType == "SCREEN" then anchorPoint = "CENTER" end
	region:SetAnchor(data.selfPoint or "CENTER", anchorFrame, anchorPoint)
	region:SetOffset(data.xOffset or 0, data.yOffset or 0)
	if WA.optionsOpen then proto.SyncOptionsAnchorMarkers() end
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
	local fields = {
		{ type = "header", name = "Position" },
		{
			type = "select", name = "Anchored to", key = "anchorFrameType",
			values = ANCHOR_FRAME_VALUES, labels = ANCHOR_FRAME_LABELS,
			get = function() return data.anchorFrameType or "SCREEN" end,
			set = function(v)
				data.anchorFrameType = v
				WA.Add(data, true)
				WA.RefreshOptions()
			end,
		},
		{
			type = "anchorgrid", name = "Anchor", key = "selfPoint", half = true,
			width = 100, height = 50,
			values = proto.anchorGridPoints,
			get = function() return data.selfPoint end,
			set = function(v) data.selfPoint = v; WA.Add(data, true) end,
		},
		{
			type = "anchorgrid", name = (data.anchorFrameType == "SELECTFRAME" and "To frame point")
				or (data.anchorFrameType == "UIPARENT" and "To UIParent point")
				or (data.anchorFrameType == "MOUSE" and "To mouse point")
				or (data.anchorFrameType == "NAMEPLATE" and "To nameplate point")
				or (data.anchorFrameType == "UNITFRAME" and "To unit frame point")
				or "To screen point", key = "anchorPoint", half = true,
			width = 100, height = 50,
			values = proto.anchorGridPoints,
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
	if data.anchorFrameType ~= "SCREEN" and data.anchorFrameType ~= "UIPARENT" then
		table.insert(fields, 3, {
			type = "toggle", name = "Set parent to anchor", key = "anchorFrameParent",
			get = function() return data.anchorFrameParent ~= false end,
			set = function(v) data.anchorFrameParent = v; WA.Add(data, true) end,
		})
	end
	if data.anchorFrameType == "SELECTFRAME" then
		table.insert(fields, 4, {
			type = "input", name = "Frame or aura ID", key = "anchorFrameFrame",
			get = function() return data.anchorFrameFrame end,
			set = function(v) data.anchorFrameFrame = v; WA.Add(data, true) end,
		})
		table.insert(fields, 5, {
			type = "button", name = "Choose frame", width = 140,
			onClick = function()
				WA.StartFrameChooser(data, function(value)
					data.anchorFrameFrame = value
					WA.Add(data, true)
					WA.RefreshOptions()
				end)
			end,
		})
	end
	return fields
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
